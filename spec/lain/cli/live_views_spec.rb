# frozen_string_literal: true

# The chronicle stand-in {Lain::CLI::LiveViews} wraps its tee onto: the REAL
# {Lain::CLI::JournalTee} over a recording journal leg, so what a spec reads
# back is the fan-out the run actually builds, with only the NDJSON file
# swapped for an in-memory list. A double would have let the tee's shape drift.
class LiveViewsSpecChronicle
  attr_reader :journal

  def initialize = @journal = RecordingChannel.new

  def wrap_tee(sink) = Lain::CLI::JournalTee.new(@journal, sink)
  def listen(_listener) = self
  def observe(_observer) = self
end

# A live-view leg that is neither closed nor healthy: the tee's review probe
# (see {Lain::CLI::JournalTee}) established that ONE broken sink must not cost
# the sinks after it their event, and the tool-output fan-out inherits that.
class LiveViewsSpecBrokenChannel
  def push(_event) = raise(IOError, "sink is gone")
  alias << push
end

# A second, differently-broken leg -- so "every cause is named" is an
# assertion about the report, not a coincidence of one error class.
class LiveViewsSpecOtherBrokenChannel
  def push(_event) = raise("the other leg is gone too")
  alias << push
end

RSpec.describe Lain::CLI::LiveViews do
  let(:chronicle) { LiveViewsSpecChronicle.new }
  let(:status_feed) { RecordingChannel.new }
  # The run's live Channel -- what Frontend::TTY drains. Recording rather than
  # a real SizedQueue, because nothing here drains it.
  let(:tty) { RecordingChannel.new }
  let(:socket) { "/tmp/lain-live-views-spec.sock" }
  let(:attached) { described_class.new(options: { nvim: socket }, chronicle:, status_feed:) }
  let(:headless) { described_class.new(options: { journal: true }, chronicle:, status_feed:) }
  let(:hello) { Lain::Telemetry::ToolOutput.new(tool_use_id: "tu_1", stream: :stdout, bytes: "hello\n") }

  describe "#views" do
    it "hands the Repl the editor's Channel, its socket, and the tee'd journal" do
      views = attached.views

      expect(views[:channel]).to be_a(Lain::Channel::DropOldest)
      expect(views[:socket_path]).to eq(socket)
      expect(views[:journal]).to be(attached.journal)
    end

    it "is nil when no editor is attached" do
      expect(headless.views).to be_nil
    end
  end

  # Streamed tool bytes are a VIEW, not a record: the durable copy already
  # rides the turn's tool_result (Tools::Bash.render_output), so this fan-out
  # reaches channels only and never the journal.
  describe ".tool_output" do
    # The escalation trigger the card names: Sink::IOAdapter#emit calls `push`,
    # and Channel aliases `<<` TO push, not the reverse -- a JournalTee dropped
    # in here would raise NoMethodError on the first byte of tool output.
    it "answers the producer's `push` duck, not only `<<`" do
      fan = described_class.tool_output(tty, attached.views)

      expect(fan).to respond_to(:push)
      expect(fan.push(hello)).to be(fan)
    end

    it "is the TTY Channel itself when no editor is attached, so a plain chat crosses nothing extra" do
      expect(described_class.tool_output(tty, headless.views)).to be(tty)
    end

    it "fans a streamed tool event onto the editor's Channel as well as the TTY's" do
      views = attached.views

      described_class.tool_output(tty, views).push(hello)

      expect(tty.events).to eq([hello])
      expect(views[:channel].drain).to eq([hello])
    end

    # The rendered half: the very event that reached the editor's Channel is
    # what the append-only lain://journal buffer turns into text.
    it "reaches the lain://journal buffer as an attributed line" do
      views = attached.views

      described_class.tool_output(tty, views).push(hello)

      lines = views[:channel].drain.flat_map { |event| Lain::Frontend::Neovim::JournalView.new.lines(event) }
      expect(lines).to eq(["[tu_1 stdout] hello"])
    end

    # The durable record is unchanged. ToolOutput is Journalable (it would
    # serialize as "tool_output"), so nothing but the wiring keeps it off the
    # NDJSON -- which is exactly what this asserts.
    it "never puts streamed bytes on the durable record" do
      described_class.tool_output(tty, attached.views).push(hello)

      expect(chronicle.journal.events).to be_empty
      expect(status_feed.events).to be_empty
    end

    # Quitting nvim closes its Channel (Frontend::Neovim's teardown
    # contract), and a dead viewer must never break a running tool.
    it "keeps the TTY leg landing after the editor quit and closed its Channel" do
      views = attached.views
      views[:channel].close

      expect { described_class.tool_output(tty, views).push(hello) }.not_to raise_error
      expect(tty.events).to eq([hello])
    end

    it "gives every channel its turn before a real failure surfaces" do
      fan = described_class::Fanout.new(LiveViewsSpecBrokenChannel.new, tty)

      expect { fan.push(hello) }.to raise_error(IOError, "sink is gone")
      expect(tty.events).to eq([hello])
    end

    # Review, Linus: a closed TTY leg is the one failure that must NOT be
    # swallowed. Swallowing it would make one failure have two behaviours
    # depending on an unrelated flag -- without --nvim the bare Channel raises
    # and Handler::Live's gate 3 turns it into an is_error tool_result, while
    # with --nvim the tool would report success though nobody saw the bytes.
    it "raises a closed TTY Channel's failure whether or not an editor is attached" do
      closed = Lain::Channel.new(capacity: 2).close

      expect { described_class.tool_output(closed, nil).push(hello) }.to raise_error(ClosedQueueError)
      expect { described_class.tool_output(closed, attached.views).push(hello) }.to raise_error(ClosedQueueError)
    end

    # The must-land distinction is about SWALLOWING, not about ordering: a
    # dying TTY leg still must not cost the editor its event.
    it "still reaches the editor when the TTY leg is the one that failed" do
      views = attached.views

      expect { described_class::Fanout.new(LiveViewsSpecBrokenChannel.new, views[:channel]).push(hello) }
        .to raise_error(IOError, "sink is gone")
      expect(views[:channel].drain).to eq([hello])
    end

    # Review, Jeremy Evans: raising only `failures.first` discards the other
    # causes, which is the exact loss {JournalTee::SinkFailures} was grown to
    # stop. The error class is reused rather than restated.
    it "names every failing leg, not just the first" do
      fan = described_class::Fanout.new(LiveViewsSpecBrokenChannel.new, LiveViewsSpecOtherBrokenChannel.new)

      expect { fan.push(hello) }.to raise_error(Lain::CLI::JournalTee::SinkFailures) { |error|
        expect(error.failures.map(&:message)).to eq(["sink is gone", "the other leg is gone too"])
        expect(error.message).to include("sink is gone", "the other leg is gone too")
      }
    end
  end

  # The production path of a one-shot subagent: Lineage writes through the
  # chronicle's observer, the scribe promotes the record onto the tee, and the
  # tee carries it to the real feed.
  describe "a one-shot subagent's lifecycle, through the real chronicle and feed" do
    let(:store) { Lain::Dag::Factory.store }
    let(:policy) { Lain::Tool::SpawnPolicy.new(prefix: :fresh, posture: :schema, only: []) }
    let(:real_chronicle) { Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: StringIO.new)) }
    let(:state_path) { File.join(Dir.mktmpdir, "state.json") }
    let(:feed) { Lain::StatusFeed.new(path: state_path) }
    let(:lineage) { Lain::Tools::Subagent::Lineage.new(policy:, observer: real_chronicle.observer) }
    let(:parent) { Lain::Dag::Factory.timeline(store:).commit(role: :user, content: [{ "type" => "text", "text" => "hi" }]) }
    let(:child) { Lain::Dag::Factory.timeline(store:).commit(role: :user, content: [{ "type" => "text", "text" => "task" }]) }

    def hud = JSON.parse(File.read(state_path)).fetch("hud")

    before do
      # Production order: the scribe takes its tee at start, so LiveViews must wrap it first.
      described_class.new(options: { journal: true }, chronicle: real_chronicle, status_feed: feed)
      real_chronicle.start(context: Lain::Context.new(model: "m", max_tokens: 10, system: "s"),
                           toolset: Lain::Toolset.new([]))
    end

    it "counts a spawned child as fleet:1 while it runs" do
      lineage.spawn(parent, prompt: "go")

      expect(hud).to include("fleet:1")
    end

    it "drops the count when the child's completion names a failure" do
      spawn = lineage.spawn(parent, prompt: "go")
      expect(hud).to include("fleet:1")

      lineage.ended(parent, spawn, child, lifecycle: Lain::StatusFeed::SpawnLifecycle::FAILED, error: "Boom")

      expect(hud).to include("fleet:0")
    end

    it "drops the count when the child answers" do
      spawn = lineage.spawn(parent, prompt: "go")
      expect(hud).to include("fleet:1")

      lineage.message(parent, spawn, child, Data.define(:text).new(text: "done"))

      expect(hud).to include("fleet:0")
    end
  end

  describe "an agent's transitions, through the real chronicle and feed" do
    let(:real_chronicle) { Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: StringIO.new)) }
    let(:state_path) { File.join(Dir.mktmpdir, "state.json") }
    let(:feed) { Lain::StatusFeed.new(path: state_path) }
    let(:listener) { real_chronicle.instrumentation.transition_listener }

    def hud = JSON.parse(File.read(state_path)).fetch("hud")

    before { described_class.new(options: { journal: true }, chronicle: real_chronicle, status_feed: feed) }

    it "shows a model segment while the agent awaits the model" do
      listener.on_transition(from: :awaiting_user, to: :awaiting_model, event: :dispatch)

      expect(hud).to include(" model ")
    end

    it "clears the segment once the agent awaits the user again" do
      listener.on_transition(from: :awaiting_user, to: :awaiting_model, event: :dispatch)
      listener.on_transition(from: :awaiting_model, to: :awaiting_user, event: :reopen)

      expect(hud).not_to include("model")
    end

    it "drops the model segment when the chronicle journals an interrupted run" do
      real_chronicle.start(context: Lain::Context.new(model: "m", max_tokens: 10, system: "s"),
                           toolset: Lain::Toolset.new([]))
      listener.on_transition(from: :awaiting_user, to: :awaiting_model, event: :dispatch)

      real_chronicle.interrupted(head: nil, reason: :stopped)

      expect(hud).not_to include("model")
    end

    it "leaves a chronicle nobody listened on with the Null listener" do
      expect(Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: StringIO.new)).instrumentation.transition_listener)
        .to be(Lain::Agent::TransitionListener::Null)
    end
  end

  describe "the tools in flight, through the real chronicle, tee, store and agent" do
    let(:real_chronicle) { Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io: StringIO.new)) }
    let(:state_path) { File.join(Dir.mktmpdir, "state.json") }
    let(:feed) { Lain::StatusFeed.new(path: state_path) }
    let(:seen) { [] }
    let(:state_reader) { -> { File.exist?(state_path) ? JSON.parse(File.read(state_path)) : {} } }

    # A tool that reports what the published state says while it is running,
    # which is when a parked call is on screen.
    def spying_tool(tool_name, seen, reader)
      Class.new(Lain::Tool) do
        define_method(:name) { tool_name }
        define_method(:description) { "spy" }
        define_method(:input_schema) { { type: :object, properties: {} } }
        define_method(:perform) do |_input, _context|
          seen << reader.call
          Lain::Tool::Result.ok("ok")
        end
      end.new
    end

    def attach_live_views
      @attach_live_views ||= described_class.new(options: { journal: true }, chronicle: real_chronicle,
                                                 status_feed: feed)
    end

    def agent_for(provider, *tools)
      attach_live_views
      agent = Lain::Agent.new(provider:, toolset: Lain::Toolset.new(tools),
                              context: Lain::Context.new(model: "m", max_tokens: 10, system: "s"),
                              instrumentation: real_chronicle.instrumentation)
      feed.bind_store(agent.timeline.store)
      agent
    end

    def replies(*responses) = Lain::Provider::Mock.new(responses:)

    def tool_reply(*names)
      Lain::Response.new(content: names.map do |n|
        { "type" => "tool_use", "id" => "tu_#{n}", "name" => n, "input" => {} }
      end,
                         stop_reason: :tool_use, usage: Lain::Usage.new(input_tokens: 1, output_tokens: 1))
    end

    def spawn_reply
      Lain::Response.new(content: [{ "type" => "tool_use", "id" => "tu_sub", "name" => "subagent",
                                     "input" => { "prompt" => "go" } }],
                         stop_reason: :tool_use, usage: Lain::Usage.new(input_tokens: 1, output_tokens: 1))
    end

    def done_reply
      Lain::Response.new(content: [{ "type" => "text", "text" => "done" }], stop_reason: :end_turn,
                         usage: Lain::Usage.new(input_tokens: 1, output_tokens: 1))
    end

    it "names a bash call in state.json and the HUD while the tool runs" do
      agent = agent_for(replies(tool_reply("bash"), done_reply), spying_tool("bash", seen, state_reader))

      agent.ask("go")

      expect(seen.first.fetch("in_flight")).to include("kind" => "tool", "tools" => ["bash"])
      expect(seen.first.fetch("hud")).to include("tool:bash")
    end

    it "names both calls of one reply" do
      agent = agent_for(replies(tool_reply("read_file", "grep"), done_reply),
                        spying_tool("read_file", seen, state_reader), spying_tool("grep", seen, state_reader))

      agent.ask("go")

      expect(seen.first.dig("in_flight", "tools")).to eq(%w[read_file grep])
    end

    it "never names a tool a child called, since the child's records do not reach the tee" do
      attach_live_views
      child_context = Lain::Context.new(model: "m", max_tokens: 10, system: "s")
      parent = nil
      seam = Lain::Tools::Subagent::Seam.new(provider: replies(tool_reply("grep"), done_reply),
                                             context_factory: -> { child_context }, parent: -> { parent.timeline },
                                             tool_middleware: ToolRegistry::UNGUARDED,
                                             telemetry: real_chronicle.instrumentation.journal)
      subagent = Lain::Tools::Subagent.new(
        seam:, toolset: Lain::Toolset.new([spying_tool("grep", seen, state_reader)]),
        policy: Lain::Tool::SpawnPolicy.new(prefix: :fresh, posture: :schema, only: %w[grep])
      )
      parent = agent_for(replies(spawn_reply, done_reply), subagent)

      parent.ask("go")

      expect(seen).not_to be_empty
      expect(seen.flat_map { |state| state.dig("in_flight", "tools").to_a }).to eq(["subagent"])
    end
  end
end
