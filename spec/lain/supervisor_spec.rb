# frozen_string_literal: true

require "async"
require "async/queue"
require "json"
require "tmpdir"

# OM-6 core: the orchestration reactor ABOVE the Agent. Actor#launch spawns its
# fiber on Async::Task.current, and Agent#ask's per-call Sync owns any fiber a
# tool dispatch spawns -- so until now actors were programmatic-only, launched
# by a caller holding its own reactor. The Supervisor IS that caller as an
# object: it owns a long-lived reactor task actors launch under, keeps the
# registry a HUD or a graceful drain enumerates, and is the presence that
# unrefuses the model-dispatched :actor (see subagent_spec).
RSpec.describe Lain::Supervisor do
  let(:store) { Lain::Store.new }
  let(:log) { Lain::Tools::Subagent::Log.new }
  let(:parent_timeline) do
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                  .commit(role: :assistant, content: [{ "type" => "text", "text" => "yo" }])
  end

  def actor_tool(*responses, journal: Lain::Channel::Null.instance)
    Lain::Tools::Subagent.new(
      provider: Lain::Provider::Mock.new(responses:),
      context_factory: -> { Lain::Context.new(model: "child", max_tokens: 128) },
      toolset: Lain::Toolset.new([EchoTool.new]),
      policy: Lain::Tool::SpawnPolicy.new(prefix: :fresh, posture: :schema, only: []),
      parent: parent_timeline, journal:, mode: :actor, log:
    )
  end

  # A child provider that announces entry and parks; a :raise release fails
  # the in-flight call instead of answering it -- deterministic sequencing for
  # every "mid-turn" window below (the W3 review probes' idiom).
  before do
    stub_const("SupervisorParkProvider", Class.new(Lain::Provider::Mock) do
      def initialize(entered:, release:, **rest)
        super(**rest)
        @entered = entered
        @release = release
      end

      def complete(request)
        @entered.enqueue(true)
        raise Lain::Error, "provider failure injected mid-turn" if @release.dequeue == :raise

        super
      end
    end)
  end

  def parking_tool(entered:, release:, journal: Lain::Channel::Null.instance)
    Lain::Tools::Subagent.new(
      provider: SupervisorParkProvider.new(entered:, release:, responses: [text_response("late")]),
      context_factory: -> { Lain::Context.new(model: "child", max_tokens: 128) },
      toolset: Lain::Toolset.new([EchoTool.new]),
      policy: Lain::Tool::SpawnPolicy.new(prefix: :fresh, posture: :schema, only: []),
      parent: parent_timeline, journal:, mode: :actor, log:
    )
  end

  # ---- Scenario: the reactor task outlives the launching scope ---------------

  describe "owning the reactor" do
    it "keeps an adopted actor alive past the launching task, and ends it under #stop" do
      Sync do |task|
        supervisor = described_class.new.run(task)
        tool = actor_tool(text_response("actor ready"))

        actor = nil
        task.async { actor = supervisor.adopt(role: "researcher") { tool.launch_actor("go") } }.wait

        # The launching task has finished, but the actor's fiber persists under
        # the supervisor's own task: still settleable, still tellable.
        expect(actor.settle).to eq(actor)
        expect(actor).not_to be_dead
        actor.tell("still with me?")

        supervisor.stop
        expect(actor).to be_stopped
      end
    end

    it "refuses to adopt before #run -- there is no reactor task to own the fiber" do
      supervisor = described_class.new

      expect { supervisor.adopt(role: "researcher") { raise "never launched" } }
        .to raise_error(described_class::NotRunning, /run/)
    end

    # One reactor per Supervisor's LIFE, enforced (review NIT g2): re-arming a
    # stopped supervisor would carry the first life's dead registry rows into
    # the second -- build another Supervisor instead.
    it "answers running? across its lifecycle, and refuses a second #run -- even after #stop" do
      supervisor = described_class.new
      expect(supervisor.running?).to be(false)

      # The trailing `ensure supervisor.stop` (here and below): a failed
      # expectation must FAIL the example, not hang the reactor on the parked
      # supervisor task -- #stop is idempotent, so the happy path pays nothing.
      Sync do |task|
        supervisor.run(task)
        expect(supervisor.running?).to be(true)
        expect { supervisor.run(task) }.to raise_error(described_class::AlreadyRunning)
        supervisor.stop
        expect { supervisor.run(task) }.to raise_error(described_class::AlreadyRunning)
      ensure
        supervisor.stop
      end

      expect(supervisor.running?).to be(false)
    end

    # FIX 2 (review): registration must happen INSIDE the adopted task. The
    # append used to run on the CALLER's fiber after `.wait` -- a launch block
    # that awaits plus an adopter cancelled in that window left a live actor
    # the registry never heard of: invisible to the HUD, skipped by the drain,
    # torn down by #stop without a farewell.
    it "registers inside the adopted task: a cancelled adopter cannot orphan a live actor" do
      journal = Lain::Channel.new
      launched = nil
      Sync do |task|
        supervisor = described_class.new.run(task)
        gate = Async::Queue.new
        adopter = task.async do
          supervisor.adopt(role: "ghost-no-more") do
            launched = actor_tool(text_response("ready"), journal:).launch_actor("go")
            gate.dequeue # any real await in a launch opens this window
            launched
          end
        end
        adopter.stop        # the adopting caller dies mid-spawn
        gate.enqueue(:go)   # the launch completes under the supervisor's task
        task.yield          # enqueue only SCHEDULES the adopted fiber; let it run
        launched.settle

        expect(supervisor.map(&:role)).to eq(["ghost-no-more"])
        supervisor.stop
        expect(launched).to be_stopped
      ensure
        supervisor&.stop
      end

      farewell = journal.drain.grep(Lain::Telemetry::Message).find { |m| m.payload["lifecycle"] == "stopped" }
      expect(farewell).not_to be_nil
    end
  end

  # ---- Scenario: actor registry is queryable (AC2) ---------------------------

  describe "the registry" do
    it "enumerates adoptions with role, state, address, and head digest" do
      Sync do |task|
        supervisor = described_class.new.run(task)
        tool = actor_tool(text_response("one"), text_response("two"))
        researcher = supervisor.adopt(role: "researcher") { tool.launch_actor("first") }
        scout = supervisor.adopt(role: "scout") { tool.launch_actor("second") }
        [researcher, scout].each(&:settle)

        expect(supervisor.map(&:role)).to eq(%w[researcher scout])
        expect(supervisor.map(&:state)).to eq(%i[running running])
        expect(supervisor.map(&:address)).to eq([researcher.address, scout.address])
        expect(supervisor.map(&:head_digest))
          .to eq([researcher.timeline.head_digest, scout.timeline.head_digest])
        expect(supervisor.map(&:head_digest)).to all(be_a(String))
        supervisor.stop
      end
    end

    it "derives state from the actor's own predicates: stopped and failed read as such" do
      Sync do |task|
        supervisor = described_class.new.run(task)
        healthy = supervisor.adopt(role: "healthy") { actor_tool(text_response("ok")).launch_actor("go") }
        # Zero scripted responses: the Mock provider raises on the child's first call.
        doomed = supervisor.adopt(role: "doomed") { actor_tool.launch_actor("go") }
        healthy.settle
        expect { doomed.settle }.to raise_error(Lain::Error)
        healthy.stop

        expect(supervisor.map(&:state)).to eq(%i[stopped failed])
        supervisor.stop
      end
    end

    # The Shutdown drain duck: draining awaits QUIESCENCE. A dead actor
    # (stopped, or failed its turn) is already quiescent -- re-raising its
    # captured failure would tear down the very drain closing the session.
    it "settles live registrations and skips dead ones without re-raising" do
      Sync do |task|
        supervisor = described_class.new.run(task)
        live = supervisor.adopt(role: "live") { actor_tool(text_response("ok")).launch_actor("go") }
        dead = supervisor.adopt(role: "dead") { actor_tool.launch_actor("go") }
        expect { dead.settle }.to raise_error(Lain::Error)

        expect { supervisor.each(&:settle) }.not_to raise_error
        expect(live).not_to be_dead
        supervisor.stop
      end
    end

    # FIX 1 (review BLOCKER): the dead-skip alone was check-then-wait -- an
    # actor LIVE at the check that fails DURING the await re-raised out of
    # Shutdown#drain's each(&:settle), killed the coordinator fiber, and
    # close(:exit) was never journaled. Registration#settle must absorb the
    # mid-drain failure; it stays loud for direct callers, because
    # Actor#settle re-raises the captured failure on every call.
    it "absorbs a failure landing DURING a settle: the drain survives, direct settle stays loud" do
      Sync do |task|
        supervisor = described_class.new.run(task)
        entered = Async::Queue.new
        release = Async::Queue.new
        actor = supervisor.adopt(role: "flaky") { parking_tool(entered:, release:).launch_actor("go") }
        entered.dequeue # the actor is provably mid-turn: live at the dead? check

        drain = task.async { supervisor.each(&:settle) }
        release.enqueue(:raise) # the in-flight turn now fails, under the parked settle

        expect { drain.wait }.not_to raise_error
        expect(supervisor.map(&:state)).to eq([:failed])
        expect { actor.settle }.to raise_error(Lain::Error, /injected/)
      ensure
        supervisor&.stop
      end
    end
  end

  # ---- FIX 3 (review): the drain is bounded by the grace window --------------
  #
  # Grace used to bound only the countdown: once draining, a hung actor wedged
  # wait_responses forever and a queued sigquit sat unread behind the blocked
  # coordinator fiber. {Supervisor#drain} is the bounded view Conductor hands
  # Shutdown's `actors:` -- one settle for the whole fleet, capped by the
  # window, journaling a timeout instead of silently dropping it.
  describe "the bounded drain" do
    it "caps a hung fleet at the window and journals drain_timed_out with the fleet's roles" do
      journal = Lain::Channel.new
      Sync do |task|
        supervisor = described_class.new(journal:).run(task)
        entered = Async::Queue.new
        release = Async::Queue.new
        supervisor.adopt(role: "hung") { parking_tool(entered:, release:).launch_actor("go") }
        entered.dequeue # provably mid-turn; nothing will ever release it

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        supervisor.drain(within: 0.05).each(&:settle)

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
        timeout = journal.drain.find { |r| r.to_journal["type"] == "drain_timed_out" }
        expect(timeout).not_to be_nil
        expect(timeout.to_journal["roles"]).to eq(["hung"])
        expect(timeout.to_journal["within"]).to eq(0.05)
      ensure
        supervisor&.stop
      end
    end

    it "settles a healthy fleet without journaling a timeout" do
      journal = Lain::Channel.new
      Sync do |task|
        supervisor = described_class.new(journal:).run(task)
        actor = supervisor.adopt(role: "prompt") { actor_tool(text_response("ok")).launch_actor("go") }

        supervisor.drain(within: 5).each(&:settle)

        expect(actor).not_to be_dead
        expect(journal.drain.select { |r| r.to_journal["type"] == "drain_timed_out" }).to be_empty
      ensure
        supervisor&.stop
      end
    end
  end

  # ---- Scenario: the render seam receives per-turn snapshots (AC3) -----------

  describe Lain::Supervisor::TurnMailbox do
    let(:recipient) { Lain::Event::ChainWriter.correlation_of(parent_timeline) }
    let(:seam) { described_class.new(source: Lain::Context::Mailbox::Source.new(recipient:, log:)) }

    def note(text)
      lineage = Lain::Tools::Subagent::Lineage.new(
        policy: Lain::Tool::SpawnPolicy.new(prefix: :fresh, posture: :schema, only: []), log:
      )
      lineage.note(parent_timeline, from: "actor", to: recipient, text:, causal_parents: [])
    end

    # The wiring the exe's chat will use: the seam rides the Agent's mailbox:
    # slot AND the tail of its Context pipeline -- one object, both ducks.
    def seam_context
      klass = Class.new(Lain::Context)
      stage = seam
      klass.define_singleton_method(:pipeline) { |workspace| Lain::Context.pipeline(workspace) >> stage }
      klass.new(model: "parent", max_tokens: 128)
    end

    def seam_agent(provider)
      Lain::Agent.new(provider:, toolset: Lain::Toolset.new([]),
                      context: seam_context, timeline: parent_timeline, mailbox: seam)
    end

    def mailbox_text(request)
      request.messages.last["content"].filter_map { |block| block["text"] }.join("\n")
    end

    # The recorded OM-6 residual (chunk-fixes T6): a Mailbox combinator binds
    # its snapshot at pipeline construction, so turn 2 would re-fold turn 1's
    # stale snapshot and never see what arrived in between.
    it "folds each turn's OWN frozen snapshot -- no stale pipeline-construction binding" do
      provider = Lain::Provider::Mock.new(responses: [text_response("turn one"), text_response("turn two")])
      agent = seam_agent(provider)

      first_note = note("before turn one")
      agent.ask("first")
      second_note = note("between turns")
      agent.ask("second")

      first_request, second_request = provider.requests
      expect(mailbox_text(first_request)).to include("before turn one")
      expect(mailbox_text(second_request)).to include("between turns")
      expect(mailbox_text(second_request)).not_to include("before turn one")

      # Render/commit agreement rides the same per-turn snapshot: each
      # assistant commit consumed exactly the digests its own render folded.
      turns = agent.timeline.to_a
      expect(turns[3].causal_parents).to eq([first_note.digest])
      expect(turns[5].causal_parents).to eq([second_note.digest])
    end

    it "is the identity stage before any capture -- an empty pending set folds nothing" do
      messages = [{ "role" => "user", "content" => [{ "type" => "text", "text" => "hi" }] }]
      expect(seam.call(messages)).to eq(messages)
    end
  end

  # ---- Scenario: actor lifecycle is journaled in the state-feed shape (AC5) --

  describe "actor lifecycle journaling" do
    def journaled_lifecycle(journal)
      actor = nil
      Sync do |task|
        supervisor = described_class.new.run(task)
        actor = supervisor.adopt(role: "researcher") { actor_tool(text_response("ready"), journal:).launch_actor("go") }
        actor.settle
        actor.tell("nudge")
        actor.stop
        supervisor.stop
      end
      actor
    end

    # FIX 4 (review): lifecycle transitions carry a machine-readable
    # body-level "lifecycle" discriminator (launched/settled/stopped) --
    # events are content-addressed, so the marker lands NOW, not after
    # recorded journals exist. A tell is conversation, not a transition, and
    # its absence of the key is what distinguishes it.
    it "journals launch, settle, tell, and stop -- transitions carry the lifecycle discriminator, tells do not" do
      journal = Lain::Channel.new
      actor = journaled_lifecycle(journal)

      events = journal.drain.grep(Lain::Telemetry::Message)
      expect(events.map(&:kind)).to eq(%i[spawn message message message])

      spawn, reply, tell, farewell = events
      expect(spawn.digest).to eq(actor.address)
      expect(spawn.payload["lifecycle"]).to eq("launched")
      expect(reply.from).to eq(actor.address)
      expect(reply.to).to eq(Lain::Event::ChainWriter.correlation_of(parent_timeline))
      expect(reply.payload["lifecycle"]).to eq("settled")
      expect(tell.payload).to eq({ "text" => "nudge" })
      expect(farewell.from).to eq(actor.address)
      expect(farewell.payload).to eq({ "text" => "actor stopped", "lifecycle" => "stopped" })
    end

    it "feeds I1's fleet field with no StatusFeed changes: the :spawn lands, the messages pass through inertly" do
      journal = Lain::Channel.new
      actor = journaled_lifecycle(journal)

      Dir.mktmpdir("supervisor-spec") do |dir|
        path = File.join(dir, "state.json")
        feed = Lain::StatusFeed.new(path:)
        journal.drain.each { |event| feed << event }

        published = JSON.parse(File.read(path))
        expect(published["fleet"]).to eq([actor.address])
        expect(published["inbox_count"]).to eq(0)
      end
    end
  end

  # ---- The Conductor hands the registry to Shutdown's drain ------------------

  describe "Conductor wiring" do
    around do |example|
      saved = Lain::CLI::Signals::MAP.keys.to_h { |name| [name, Signal.trap(name, "DEFAULT")] }
      example.run
    ensure
      saved.each { |name, handler| Signal.trap(name, handler) }
    end

    let(:chronicle) do
      Class.new do
        def initialize = @reasons = []
        attr_reader :reasons

        def catch_up(_timeline) = self
        def interrupted(**) = self
        def close(reason:) = tap { @reasons << reason }
      end.new
    end

    # render_countdown hands the coordinator out through a queue, so the driver
    # can send :wait_responses the moment the grace window provably renders.
    let(:tty) do
      Class.new do
        def initialize = @coordinators = Async::Queue.new
        attr_reader :coordinators

        def render_countdown(options:, **) = tap { @coordinators.enqueue(options[:coordinator]) }
        def stop_countdown = self
      end.new
    end

    before do
      stub_const("ParkProvider", Class.new(Lain::Provider::Mock) do
        def initialize(entered:, release:, **rest)
          super(**rest)
          @entered = entered
          @release = release
        end

        def complete(request)
          @entered.enqueue(true)
          @release.dequeue
          super
        end
      end)
    end

    def drain_driver(task, entered:, release:)
      task.async do
        entered.dequeue
        Process.kill("INT", Process.pid)
        tty.coordinators.dequeue.signal(:wait_responses)
        release.enqueue(true)
      end
    end

    # Conductor asks the supervisor for its BOUNDED drain view (FIX 3), with
    # the ask's own grace as the window -- the fake records the handoff.
    it "wait_responses settles the supervisor's bounded drain view, capped by grace" do
      settled = []
      windows = []
      registration = Object.new
      registration.define_singleton_method(:settle) { settled << :actor }
      supervisor = Object.new
      supervisor.define_singleton_method(:drain) do |within:|
        windows << within
        [registration]
      end
      conductor = Lain::CLI::Conductor.new(
        tty:, chronicle:, signals: Lain::CLI::Signals.new.install,
        grace: 60, clock: -> { 1000.0 }, tick: 0.005, supervisor:
      )
      entered = Async::Queue.new
      release = Async::Queue.new
      agent = Lain::Agent.new(provider: ParkProvider.new(entered:, release:, responses: [text_response]),
                              toolset: Lain::Toolset.new([]),
                              context: Lain::Context.new(model: "m", max_tokens: 64))

      outcome = nil
      Sync do |task|
        driver = drain_driver(task, entered:, release:)
        outcome = conductor.supervise(task, -> { agent.timeline }) { agent.ask("hi") }
        driver.wait
      end

      expect(settled).to eq([:actor])
      expect(windows).to eq([60])
      expect(outcome.closed?).to be(true)
      expect(chronicle.reasons).to eq([:exit])
    end
  end

  # ---- The no-supervisor default -------------------------------------------

  describe Lain::Supervisor::Null do
    it "answers the whole duck: not running, an empty registry, an empty drain view, adoption refused loudly" do
      expect(described_class.running?).to be(false)
      expect(described_class.to_a).to eq([])
      expect(described_class.drain(within: 60)).to eq([])
      expect { described_class.adopt(role: "researcher") { nil } }
        .to raise_error(Lain::Supervisor::NotRunning)
    end
  end
end
