# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"

# A prompt that does not fit its context, over the wiring a live chat really
# builds: a real {Lain::CLI::Backend} resolving the run's window book from
# `/api/ps`, the real {Lain::Provider::Ollama} encoding and error mapping, the
# model phase {Lain::CLI::Wiring} composes, a real {Lain::Agent} with its real
# compaction source, a real session journal and a real {Lain::StatusFeed} on the
# tee. Only the socket is stubbed, and the bodies it answers with are ollama
# 0.32.12's own.
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
    Lain::CLI::Chronicle.new(journal: Lain::CLI::JournalTee.new(Lain::Journal.new(io: journal_io), feed),
                             journal_path: "over-window-seam.ndjson")
  end
  let(:chat_bodies) { [] }

  let(:backend) do
    provider = Lain::Provider::Ollama.new(config: zero_retry_config)
    Class.new(Lain::CLI::Backend) do
      define_method(:provider) { |**| provider }
    end.new({ provider: "ollama", model:, max_tokens: 64, compact_keep: 2 })
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

  def chat
    wiring = Lain::CLI::Wiring.new(options: { grace: 5 }, chronicle:,
                                   status_feed: instance_double(Lain::StatusFeed, bind_store: nil))
    recorder, session = wiring.run_state(nil)
    agent = wiring.wire_agent(channel: Lain::Channel.new, recorder:, session:, backend:)
    [agent, Lain::CLI::Repl::Ask.new(agent:, tty: nil, chronicle:)]
  end

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
      end.new({ provider: "ollama", model:, max_tokens: 64 })
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

    it "sends an ordinary request with nothing added but that one key, and records no pressure" do
      _, ask = chat

      ask.attempt("hello")

      expect(chat_bodies.first.keys).to contain_exactly("model", "messages", "stream", "tools", "truncate")
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
  end
end
