# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

# A prompt that does not fit its context, over the wiring a live chat really
# builds: a real {Lain::CLI::Backend} resolving the run's window book from
# `/api/ps`, the real {Lain::Provider::Ollama} encoding and error mapping, the
# model phase {Lain::CLI::Wiring} composes, a real {Lain::Agent} with its real
# compaction source, a real session journal and a real {Lain::StatusFeed} joined
# to it the way `ChatLaunch#open_chronicle` joins one, through
# {Lain::CLI::LiveViews}. Only the socket is stubbed, and the bodies it answers
# with are ollama 0.32.12's own.
#
# The defect it closes, from round 17: a 330 KB request went to a 32,768-token
# runner, which cut it from the front to 16,386 tokens -- dropping the system
# prompt and every tool schema -- and reported that count. Lain journaled it as
# occupancy, 50% and then 16%, nothing warned, and the model's next turn was a
# tool call written out as prose because it no longer had tools. Ollama also
# drops whole OLDER messages when one of those is what overflows, reporting an
# honest-looking count, so no reading of its reply can be trusted to reveal a
# cut. What can be trusted is asking it not to cut: it then refuses with the
# exact prompt count and the context it loaded.
RSpec.describe "a prompt that does not fit the served context", :seam do
  let(:model) { "qwen3:4b" }
  let(:context_length) { 8192 }
  let(:journal_io) { StringIO.new }
  let(:feed) do
    Lain::StatusFeed.new(path: File.join(@dir, "state.json"), context_window: backend.context_window)
  end
  let(:chronicle) do
    Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io), journal_path: "over-window-seam.ndjson")
                        .tap { |opened| Lain::CLI::LiveViews.new(options: {}, chronicle: opened, status_feed: feed) }
  end
  let(:chat_bodies) { [] }

  let(:backend) do
    provider = Lain::Provider::Ollama.new(config: zero_retry_config)
    Class.new(Lain::CLI::Backend) do
      define_method(:provider) { |**| provider }
    end.new({ provider: "ollama", model:, max_tokens: 64, compact_keep: 2 }, root: Dir.pwd)
  end

  around do |example|
    Dir.mktmpdir("over-window-seam") do |dir|
      @dir = dir
      example.run
    end
  end

  # The runner is resident at `context_length`, so the book is PROBED -- the
  # window a gate may act on.
  before do
    stub_request(:get, %r{/api/ps}).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: JSON.generate("models" => [{ "name" => model, "model" => model, "context_length" => context_length }])
    )
    stub_request(:post, %r{/api/chat}).to_return { |request| answer(JSON.parse(request.body)) }
  end

  # What ollama answers: a refusal for the prompt marked as too big, a streamed
  # reply for anything else, billing about a token per four bytes of it.
  def answer(body)
    chat_bodies << body
    text = JSON.generate(body["messages"])
    return refusal(prompt_tokens: 9_000) if text.include?("DOES-NOT-FIT")

    reply = { "model" => model, "message" => { "role" => "assistant", "content" => "settled" }, "done" => true,
              "done_reason" => "stop", "prompt_eval_count" => text.bytesize / 4, "eval_count" => 1 }
    { status: 200, headers: { "Content-Type" => "application/x-ndjson" }, body: "#{JSON.generate(reply)}\n" }
  end

  def refusal(prompt_tokens:)
    inner = { "error" => { "code" => 400, "type" => "exceed_context_size_error", "n_prompt_tokens" => prompt_tokens,
                           "n_ctx" => context_length,
                           "message" => "request (#{prompt_tokens} tokens) exceeds the available context " \
                                        "size (#{context_length} tokens), try increasing it" } }
    { status: 400, headers: { "Content-Type" => "application/json" },
      body: JSON.generate("error" => JSON.generate(inner)) }
  end

  def chat(tty: nil)
    wiring = Lain::CLI::Wiring.new(options: { grace: 5 }, chronicle:,
                                   status_feed: instance_double(Lain::StatusFeed, bind_store: nil))
    recorder, session = wiring.run_state(nil)
    agent = wiring.wire_agent(channel: Lain::Channel.new, recorder:, session:, backend:)
    feed.bind_store(agent.timeline.store)
    [agent, Lain::CLI::Repl::Ask.new(agent:, tty:, chronicle:)]
  end

  # The command a human types, over the same chronicle, so the move lands in
  # the record the feed rides as well as on the Agent.
  def rewind(agent, count)
    Lain::CLI::Command::Rewind.new.call(count.to_s, build_command_env(agent:, chronicle:))
  end

  def tty = @tty ||= instance_double(Lain::Frontend::TTY, render_error: nil, render_warning: nil)

  def published = JSON.parse(File.read(File.join(@dir, "state.json")))

  def journaled(type)
    journal_io.string.each_line.map { |line| JSON.parse(line) }.select { |record| record["type"] == type }
  end

  def prose(label, bytes) = "#{label} #{"the quick brown fox jumped over the lazy dog. " * (bytes / 46)}"

  # With the default twenty kept messages a short session has no head at all,
  # so the refusal must not send a human after compaction.
  describe "the refusal over a history with nothing to drop" do
    let(:backend) do
      provider = Lain::Provider::Ollama.new(config: zero_retry_config)
      Class.new(Lain::CLI::Backend) do
        define_method(:provider) { |**| provider }
      end.new({ provider: "ollama", model:, max_tokens: 64 }, root: Dir.pwd)
    end

    it "leads with /rewind, says the prompt was withdrawn, and names no compaction" do
      _, ask = chat
      ask.attempt("hello")

      refusal = ask.attempt("DOES-NOT-FIT")

      expect(journaled("compaction_decision").last).to include("nothing_droppable" => true)
      expect(refusal.message).to include("9000", "8192", "withdrawn", "/rewind", "/unpin")
      expect(refusal.message).not_to include("compaction")
    end
  end

  # A refusal after a tool round in the same ask leaves the prompt where it
  # was -- the round ran, and its results are what the refused request carried
  # -- so the words must not say it was taken back.
  describe "a refusal after a tool round" do
    # Nothing droppable, the one refusal whose words have ever named a
    # withdrawal.
    let(:backend) do
      provider = Lain::Provider::Ollama.new(config: zero_retry_config)
      Class.new(Lain::CLI::Backend) do
        define_method(:provider) { |**| provider }
      end.new({ provider: "ollama", model:, max_tokens: 64 }, root: Dir.pwd)
    end

    def answer(body)
      chat_bodies << body
      return refusal(prompt_tokens: 9_000) if body["messages"].any? { |message| message["role"] == "tool" }

      call = { "function" => { "name" => "session_usage", "arguments" => {} } }
      reply = { "model" => model, "message" => { "role" => "assistant", "content" => "", "tool_calls" => [call] },
                "done" => true, "done_reason" => "stop", "prompt_eval_count" => 100, "eval_count" => 1 }
      { status: 200, headers: { "Content-Type" => "application/x-ndjson" }, body: "#{JSON.generate(reply)}\n" }
    end

    it "does not say the prompt was withdrawn" do
      agent, ask = chat

      refusal = ask.attempt("look, then answer")

      expect(refusal).to be_a(Lain::Middleware::RequestBudget::OverWindow)
      expect(agent.timeline.to_a.map(&:role)).to eq(%w[user assistant user])
      expect(refusal.message).to include("9000")
      expect(refusal.message).not_to include("withdrawn")
    end
  end

  # Transport failures over the same wiring. faraday-retry surfaces only the
  # last attempt, so what decides the prompt's fate is whether ANY attempt can
  # have written a byte.
  describe "a transport failure" do
    def refuse_connections = stub_request(:post, %r{/api/chat}).to_raise(Errno::ECONNREFUSED)

    it "withdraws a prompt whose every attempt was refused a connection, and records it as transport" do
      agent, ask = chat(tty:)
      ask.attempt("hello")
      head = agent.timeline.head_digest
      refuse_connections

      ask.settle(ask.attempt("never sent"))

      expect(agent.timeline.head_digest).to eq(head)
      expect(journaled("run_interrupted").last).to include("reason" => "transport", "head" => head)
    end

    it "keeps a prompt the connection was reset under, and folds it into the next one" do
      agent, ask = chat(tty:)
      ask.attempt("hello")
      stub_request(:post, %r{/api/chat}).to_raise(Errno::ECONNRESET)
      ask.settle(ask.attempt("cut off"))
      expect(agent.timeline.head.content.first["text"]).to eq("cut off")
      stub_request(:post, %r{/api/chat}).to_return { |request| answer(JSON.parse(request.body)) }

      expect(ask.attempt("next").text).to eq("settled")

      expect(agent.timeline.to_a.map(&:role)).to eq(%w[user assistant user assistant])
      expect(agent.timeline.to_a[2].content.map { |block| block["text"] }).to eq(["cut off", "next"])
      expect(journaled("rewound")).not_to be_empty
      expect(tty).to have_received(:render_warning).with(/carries it too/)
    end
  end

  describe "the refusal" do
    it "reaches no model, carries the provider's exact numbers, and leaves the session answering" do
      agent, ask = chat
      ask.attempt("hello")
      head = agent.timeline.head_digest

      refusal = ask.attempt("DOES-NOT-FIT")

      expect(refusal).to be_a(Lain::Middleware::RequestBudget::OverWindow)
      expect(refusal.message).to include("9000", "8192", "compaction", "/rewind", "/unpin", "narrower")
      expect(journaled("window_pressure"))
        .to contain_exactly(include("kind" => "over_window", "source" => "ollama", "prompt_tokens" => 9_000,
                                    "window_tokens" => 8192, "request_digest" => be_a(String)))
      expect(agent.timeline.head_digest).to eq(head)

      expect(ask.attempt("ping").text).to eq("settled")
      expect(agent.timeline.to_a.map(&:role)).to eq(%w[user assistant user assistant])
    end
  end

  describe "what reaches ollama" do
    # With `truncate: false` on every request ollama either evaluates the whole
    # prompt or refuses it, so there is no truncated reading left to believe.
    it "asks it, on every request, to refuse rather than cut" do
      _, ask = chat
      ask.attempt("hello")
      ask.attempt("DOES-NOT-FIT")
      ask.attempt("ping")

      expect(chat_bodies.size).to eq(3)
      expect(chat_bodies.map { |body| body["truncate"] }).to all(be(false))
    end

    # `options` is the runner knobs and nothing else -- the generation cap the
    # CLI always sends, plus the batch size it defaults on the ollama arm. Every
    # ollama request carries both, so their presence says nothing about this
    # machinery; what the example pins is that the refusal path added no field
    # of its own.
    it "sends an ordinary request with nothing added but that one key, and records no pressure" do
      _, ask = chat

      ask.attempt("hello")

      expect(chat_bodies.first.keys)
        .to contain_exactly("model", "messages", "stream", "tools", "truncate", "options")
      expect(chat_bodies.first["options"].keys).to contain_exactly("num_predict", "num_batch")
      expect(journaled("window_pressure")).to be_empty
    end
  end

  # The reading a refusal leaves is the provider's exact count, so the
  # approaching-window signal compaction measures is armed by the very turn
  # that could not be sent -- where a refusal yielding no reading left it
  # measuring the last answered turn, and every later prompt was refused.
  describe "the next render" do
    it "compacts against the refused prompt's exact count" do
      _, ask = chat
      ask.attempt(prose("FIRST-MARKER", 12_000))
      ask.attempt(prose("SECOND-MARKER", 12_000))
      ask.attempt("DOES-NOT-FIT")

      expect(ask.attempt("ping").text).to eq("settled")

      decisions = journaled("compaction_decision")
      expect(decisions.last).to include("compacted" => true, "used_tokens" => 9_000,
                                        "signals" => include("approaching_window"))
      expect(JSON.generate(chat_bodies.last["messages"])).not_to include("FIRST-MARKER")
    end

    # The prompt line reads the Agent and the cockpit's HUD reads the feed on
    # the tee; both have to be told about the refused count, or they disagree
    # about the one context that just overflowed.
    it "is measured the same by the Agent and by the status feed" do
      agent, ask = chat
      ask.attempt("hello")
      ask.attempt("DOES-NOT-FIT")

      expect(feed.state["occupancy"]).to eq(agent.occupancy)
      expect(agent.occupancy).to eq(9_000.fdiv(context_length))
    end

    it "is measured the same by the Agent and by the status feed after a rewind past it" do
      agent, ask = chat
      ask.attempt("hello")
      ask.attempt("again")
      ask.attempt("DOES-NOT-FIT")

      rewind(agent, 2)

      expect(agent.occupancy).to be_nil
      expect(feed.state["occupancy"]).to eq(agent.occupancy)
    end

    # What the tmux HUD prints is the published file, and the rewind reaches it
    # through the session record's own write, before any later model call.
    it "clears the published HUD figure at the rewind, before the next response" do
      agent, ask = chat
      ask.attempt("hello")
      ask.attempt("again")
      expect(published["occupancy"]).to be_a(Float)
      requests = chat_bodies.size

      rewind(agent, 1)

      expect(published["occupancy"]).to be_nil
      expect(published["hud"]).not_to match(/ctx:~?\d+%/)
      expect(chat_bodies.size).to eq(requests)
    end

    # A withdrawn prompt leaves the turn below it at the head, and the refused
    # count is still the best reading of that chain plus the next prompt.
    it "is still believed by both after the withdrawal, with no rewind" do
      agent, ask = chat
      ask.attempt("hello")
      ask.attempt("DOES-NOT-FIT")

      expect(agent.occupancy).to eq(9_000.fdiv(context_length))
      expect(feed.state["occupancy"]).to eq(agent.occupancy)
    end
  end

  # Nothing is resident, so the window is a guess until a refusal names the
  # context the server loaded. The refusal record reaches the feed before that
  # vouch; the `run_interrupted` the chat writes when the ask stops is the
  # first record after it.
  describe "an over-window refusal over a guessed window" do
    before do
      stub_request(:get, %r{/api/ps}).to_return(
        status: 200, headers: { "Content-Type" => "application/json" }, body: JSON.generate("models" => [])
      )
    end

    it "drops the published guess mark when the stopped ask is recorded, before any later model call" do
      _, ask = chat(tty:)
      ask.attempt("hello")
      expect(published["window_guessed"]).to be(true)

      ask.settle(ask.attempt("DOES-NOT-FIT"))

      expect(journaled("run_interrupted").last).to include("reason" => "over_window")
      expect(published["window_guessed"]).to be(false)
      expect(published["hud"]).to match(/ ctx:\d+% /)
      expect(chat_bodies.size).to eq(2)
    end
  end

  # A count refused on a 32k runner describes a chain a rewind has since cut
  # back; believed there, it fires the window signal and compacts a history a
  # fraction of the window's size.
  describe "a rewind past a refused turn" do
    let(:context_length) { 32_768 }

    def answer(body)
      chat_bodies << body
      return refusal(prompt_tokens: 33_000) if JSON.generate(body["messages"]).include?("DOES-NOT-FIT")

      super
    end

    it "does not fire the approaching-window signal on the refused count" do
      agent, ask = chat
      ask.attempt("hello")
      ask.attempt("again")
      ask.attempt("DOES-NOT-FIT")
      rewind(agent, 2)

      expect(ask.attempt("ping").text).to eq("settled")

      expect(journaled("compaction_decision").last).to include("used_tokens" => nil, "compacted" => false)
      expect(journaled("compaction_decision").last["signals"]).not_to include("approaching_window")
    end
  end

  # An ask refused whole is withdrawn, and the next ask renders the same chain
  # plus its own prompt. A cut committed on the refused render must still hold
  # there, or every stuck ask retreats the cut and commits it again.
  describe "a stuck ask" do
    it "commits its cut once across two refused and withdrawn asks" do
      _, ask = chat
      ask.attempt(prose("FIRST-MARKER", 12_000))
      ask.attempt(prose("SECOND-MARKER", 12_000))
      ask.attempt("DOES-NOT-FIT")

      2.times { |attempt| ask.attempt("DOES-NOT-FIT, attempt #{attempt}") }

      cuts = journaled("compaction_cut")
      expect(journaled("compaction_decision").map { |record| record["compacted"] }).to include(true)
      expect(cuts.size).to eq(1)
      expect(JSON.generate(chat_bodies.last["messages"])).not_to include("FIRST-MARKER")
    end
  end
end
