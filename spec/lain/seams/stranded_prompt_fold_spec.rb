# frozen_string_literal: true

require "json"
require "stringio"

# A prompt a failure after the wire left unanswered at the head is folded into
# the next ask: one user turn carrying both texts, cut from the stranded turn's
# parent. Over the wiring a live chat builds -- the real ollama provider and its
# error mapping, the Agent, {Lain::CLI::Repl::Ask}, a real Chronicle and Scribe --
# with the file read back by the real Loader, and salvage run over what a crash
# would leave. Only the socket is stubbed.
#
# The invariant the fold owes the record: at every point a process could die
# during a folded ask, the resumed chain still carries the stranded prompt's
# text -- as the stranded turn itself or inside the folded turn -- and salvage
# never commits an answer onto a head that lacks it.
RSpec.describe "a stranded prompt folded into the next ask", :seam do
  let(:model) { "qwen3:4b" }
  let(:journal_io) { StringIO.new }
  let(:chronicle) do
    Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: journal_io), journal_path: "fold-seam.ndjson")
  end
  let(:backend) do
    provider = Lain::Provider::Ollama.new(config: zero_retry_config)
    Class.new(Lain::CLI::Backend) do
      define_method(:provider) { |**| provider }
    end.new({ provider: "ollama", model:, max_tokens: 64 })
  end
  let(:warnings) { [] }
  let(:tty) do
    instance_double(Lain::Frontend::TTY, render_error: nil).tap do |double|
      allow(double).to receive(:render_warning) { |message| warnings << message }
    end
  end

  before do
    stub_request(:get, %r{/api/ps}).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: JSON.generate("models" => [{ "name" => model, "model" => model, "context_length" => 8192 }])
    )
    answering
  end

  def reply
    body = { "model" => model, "message" => { "role" => "assistant", "content" => "settled" }, "done" => true,
             "done_reason" => "stop", "prompt_eval_count" => 10, "eval_count" => 1 }
    { status: 200, headers: { "Content-Type" => "application/x-ndjson" }, body: "#{JSON.generate(body)}\n" }
  end

  def answering(&on_request)
    stub_request(:post, %r{/api/chat}).to_return do |_request|
      on_request&.call
      reply
    end
  end

  def cut = stub_request(:post, %r{/api/chat}).to_raise(Errno::ECONNRESET)
  def refused = stub_request(:post, %r{/api/chat}).to_raise(Errno::ECONNREFUSED)

  def chat
    wiring = Lain::CLI::Wiring.new(options: { grace: 5 }, chronicle:,
                                   status_feed: instance_double(Lain::StatusFeed, bind_store: nil))
    recorder, session = wiring.run_state(nil)
    agent = wiring.wire_agent(channel: Lain::Channel.new, recorder:, session:, backend:)
    [agent, Lain::CLI::Repl::Ask.new(agent:, tty:, chronicle:)]
  end

  # What the conversation does per line: attempt, settle, and catch the record up.
  def say(agent, ask, text)
    outcome = ask.settle(ask.attempt(text))
    chronicle.catch_up(agent.timeline)
    outcome
  end

  def records = journal_io.string.each_line.map { |line| JSON.parse(line) }
  def loaded(lines = journal_io.string) = Lain::Bench::Session::Loader.new(lines.each_line).timeline
  def texts(timeline) = timeline.to_a.flat_map { |turn| turn.content.filter_map { |block| block["text"] } }

  # A complete response frame for the file's last request, the one a crash
  # mid-request could leave in the response log.
  def salvaged(lines)
    entries = lines.each_line.to_a
    digest = entries.map { |line| JSON.parse(line) }.reverse.find { |record| record["type"] == "request_sent" }
    frame = Data.define(:request_digest, :bytes) do
      def complete? = true
      def corrupt? = false
    end.new(request_digest: digest.fetch("digest"), bytes: AnthropicSSE.body(text_response("recovered")))
    Lain::SessionRecord::Salvage.new(entries:, frames: [frame], timeline: loaded(lines)).call
  end

  describe "the record at every point a folded ask could die" do
    let(:crash_points) { {} }

    # One settled exchange, then a prompt a reset connection strands.
    def stranded_chat
      agent, ask = chat
      say(agent, ask, "hello")
      cut
      say(agent, ask, "stranded")
      [agent, ask]
    end

    def fold_watching_the_record(agent, ask)
      watch_the_retreat
      writes = watch_every_write
      answering { crash_points[:mid_request] = journal_io.string.dup }
      say(agent, ask, "folded")
      writes
    end

    def watch_the_retreat
      allow(chronicle).to receive(:replaced).and_wrap_original do |original, **arguments|
        crash_points[:before_the_retreat] ||= journal_io.string.dup
        original.call(**arguments).tap { crash_points[:after_the_retreat] ||= journal_io.string.dup }
      end
    end

    def watch_every_write
      [].tap do |writes|
        allow(journal_io).to receive(:write).and_wrap_original do |original, bytes|
          original.call(bytes).tap { writes << journal_io.string.dup }
        end
      end
    end

    it "carries the stranded text before the retreat, where the stranded turn is still the head" do
      agent, ask = stranded_chat
      fold_watching_the_record(agent, ask)

      expect(loaded(crash_points.fetch(:before_the_retreat)).head.content.map { |block| block["text"] })
        .to eq(["stranded"])
    end

    # The retreat and the folded turn land in ONE write, so there is no point
    # between them to die at: right after the retreat, the folded turn is
    # already the head.
    it "carries it right after the retreat, because the folded turn lands in the same write" do
      agent, ask = stranded_chat
      fold_watching_the_record(agent, ask)

      expect(loaded(crash_points.fetch(:after_the_retreat)).head.content.map { |block| block["text"] })
        .to eq(%w[stranded folded])
    end

    it "carries it after every single write the folded ask makes" do
      agent, ask = stranded_chat
      writes = fold_watching_the_record(agent, ask)

      expect(writes).not_to be_empty
      expect(writes.map { |snapshot| texts(loaded(snapshot)).include?("stranded") }).to all(be(true))
    end

    it "carries it mid-request, and salvage lands its answer on the folded turn" do
      agent, ask = stranded_chat
      fold_watching_the_record(agent, ask)
      mid_request = crash_points.fetch(:mid_request)

      expect(texts(loaded(mid_request))).to include("stranded", "folded")
      outcome = salvaged(mid_request)
      expect(outcome).to be_recovered
      expect(outcome.timeline.head.parent).to eq(loaded(mid_request).head_digest)
      expect(texts(outcome.timeline)).to include("stranded", "folded")
    end
  end

  # One write(2) cannot be cut at a record boundary by a process death, but a
  # write spanning pages can be cut between pages: the retreat whole, the
  # folded turn's line short. The retreat names the turn it precedes, and a
  # reader applies it only once that turn parsed too.
  it "resumes onto the stranded prompt when a kill tears the folded turn out of the retreat's write" do
    agent, ask = chat
    say(agent, ask, "hello")
    cut
    say(agent, ask, "stranded #{"s" * 6000}")
    before_fold = journal_io.string.dup
    stranded = agent.timeline.head_digest
    answering
    say(agent, ask, "folded")

    lines = journal_io.string.delete_prefix(before_fold).lines
    retreat_at = lines.index { |line| JSON.parse(line)["type"] == "rewound" }
    folded_line = lines[retreat_at + 1]
    expect(JSON.parse(lines[retreat_at])).to include("then" => JSON.parse(folded_line).fetch("digest"))
    torn = before_fold + lines[..retreat_at].join + folded_line[0, folded_line.bytesize / 2]

    expect(loaded(torn).head_digest).to eq(stranded)
  end

  # Repl builds one Ask per line, but nothing in Ask says so: a reused Ask must
  # not replay an earlier fold's retreat on a later ask that folded nothing.
  it "replays no earlier fold's retreat on a later, unfolded ask the Agent withdraws" do
    agent, ask = chat
    say(agent, ask, "hello")
    cut
    say(agent, ask, "stranded")
    answering
    say(agent, ask, "folded")
    refused

    say(agent, ask, "plain, refused before the wire")

    expect(loaded.head_digest).to eq(agent.timeline.head_digest)
  end

  it "folds a stranded root prompt, and the file replays to the live head" do
    agent, ask = chat
    cut
    say(agent, ask, "cut off")
    answering

    expect(say(agent, ask, "next")&.text).to eq("settled")

    expect(agent.timeline.to_a.first.content.map { |block| block["text"] }).to eq(["cut off", "next"])
    expect(records.reverse.find { |record| record["type"] == "rewound" }).to include("to" => nil)
    expect(loaded.head_digest).to eq(agent.timeline.head_digest)
  end

  # The folded turn is in the record before the request goes out; the Agent
  # withdraws it when nothing reached the wire, and the record follows it back
  # to the stranded head with no refusal from the scribe.
  it "puts the stranded head back in the record when a folded ask is refused before the wire" do
    agent, ask = chat
    say(agent, ask, "hello")
    cut
    say(agent, ask, "cut off")
    stranded = agent.timeline.head_digest
    refused

    say(agent, ask, "lost?")

    expect(agent.timeline.head_digest).to eq(stranded)
    expect(records.reverse.find { |record| record["type"] == "run_interrupted" })
      .to include("reason" => "transport", "head" => stranded)
    expect(loaded.head_digest).to eq(stranded)

    answering
    expect(say(agent, ask, "again")&.text).to eq("settled")
    expect(agent.timeline.to_a[2].content.map { |block| block["text"] }).to eq(["cut off", "again"])
    expect(loaded.head_digest).to eq(agent.timeline.head_digest)
  end

  # A /rewind onto a prompt that WAS answered leaves the same head shape, so
  # the next ask folds it too, and the notice says only what is true of both.
  it "folds after /rewind onto an answered prompt, with a notice that claims no failure" do
    agent, ask = chat
    say(agent, ask, "hello")
    say(agent, ask, "tell me a joke")
    env = Struct.new(:agent, :chronicle, :timeline).new(agent, chronicle, agent.timeline)
    allow(Lain::CLI::Command::InFlight).to receive(:dispatching?).and_return(false)
    Lain::CLI::Command::Rewind.new.call("1", env)

    say(agent, ask, "a different question")

    expect(agent.timeline.to_a[-2].content.map { |block| block["text"] })
      .to eq(["tell me a joke", "a different question"])
    expect(warnings).to contain_exactly(%r{no answer on this chain.*/rewind 1})
    expect(loaded.head_digest).to eq(agent.timeline.head_digest)
  end
end
