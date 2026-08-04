# frozen_string_literal: true

require "fileutils"

require "async"
require "async/queue"
require "json"
require "mixlib/shellout"
require "stringio"
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

    it "feeds the fleet field with no StatusFeed changes: the :spawn lands, the messages pass through inertly" do
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

  # ---- Scenario: isolation lease lifecycle (B5) ------------------------------
  #
  # A worker leases an isolated WorkerEnv on adopt, its tools run under that
  # leased cwd/env, and the lease is released on #stop. The default backend is
  # the shared-process Null, so a supervisor with no isolation wired is
  # unchanged; a recording backend here proves the acquire/release flow and the
  # WorkerEnv reaching the child's tools.

  describe "isolation lease lifecycle" do
    # RecordingIsolation is the Isolation duck: it hands out real
    # {Isolation::Lease}s over a fixed WorkerEnv and records every acquire and
    # release by worker key, so a spec asserts the lifecycle without a git
    # checkout (the real Worktree backend is B2's, tested there). EnvProbe's
    # child tool records the WorkerEnv its Session lends it -- the honest "the
    # worker's tools ran under its leased WorkerEnv" assertion.
    before do
      stub_const("RecordingIsolation", Class.new do
        attr_reader :acquired, :released

        def initialize(env)
          @env = env
          @acquired = []
          @released = []
        end

        def acquire(worker_id)
          @acquired << worker_id
          recorder = self
          Lain::Isolation::Lease.new(worker_env: @env, on_release: -> { recorder.released << worker_id })
        end
      end)

      stub_const("EnvProbe", Class.new(Lain::Tool) do
        define_method(:initialize) do |sink|
          super()
          @sink = sink
        end
        def name = "env_probe"
        def description = "records the worker env its session lends it"
        def input_schema = { type: :object, properties: {}, required: [] }

        def perform(_input, invocation)
          @sink << session_of(invocation).worker_env
          Lain::Tool::Result.ok("probed")
        end
      end)
    end

    # The child's first turn calls the probe, then settles.
    def probing_actor_tool(collector)
      Lain::Tools::Subagent.new(
        provider: Lain::Provider::Mock.new(responses: [tool_response(%w[p env_probe] << {}), text_response("done")]),
        context_factory: -> { Lain::Context.new(model: "child", max_tokens: 128) },
        toolset: Lain::Toolset.new([EnvProbe.new(collector)]),
        policy: Lain::Tool::SpawnPolicy.new(prefix: :fresh, posture: :schema, only: []),
        parent: parent_timeline, journal: Lain::Channel::Null.instance, mode: :actor, log:
      )
    end

    let(:leased_env) { Lain::WorkerEnv.new(cwd: "/leased/checkout", env: { "DATABASE_URL" => "postgres://worker" }) }

    it "acquires a lease on adopt, runs the worker's tools under its WorkerEnv, and releases on stop" do
      backend = RecordingIsolation.new(leased_env)
      seen = []
      Sync do |task|
        supervisor = described_class.new(isolation: backend).run(task)
        tool = probing_actor_tool(seen)

        actor = supervisor.adopt(role: "worker") { |worker_env| tool.launch_actor("go", worker_env:) }
        actor.settle

        expect(backend.acquired.size).to eq(1)      # a lease was acquired on adopt
        expect(seen).to eq([leased_env])            # the child's tool ran under it
        expect(backend.released).to be_empty        # not released while alive
        supervisor.stop
      end
      expect(backend.released.size).to eq(1)        # released on teardown
    end

    it "releases a distinct lease per adopted worker on stop" do
      backend = RecordingIsolation.new(leased_env)
      Sync do |task|
        supervisor = described_class.new(isolation: backend).run(task)
        supervisor.adopt(role: "a") { actor_tool(text_response("ok")).launch_actor("go") }.settle
        supervisor.adopt(role: "b") { actor_tool(text_response("ok")).launch_actor("go") }.settle

        expect(backend.acquired.size).to eq(2)
        expect(backend.acquired.uniq.size).to eq(2) # distinct worker keys, so worktree paths never collide
        supervisor.stop
      end
      expect(backend.released.size).to eq(2)
    end

    # The escalation trigger's other half: a launch that raises AFTER the lease
    # was acquired must not leak the provisioned resource.
    it "releases the lease when the launch fails, leaking nothing" do
      backend = RecordingIsolation.new(leased_env)
      Sync do |task|
        supervisor = described_class.new(isolation: backend).run(task)

        expect { supervisor.adopt(role: "doomed") { raise Lain::Error, "launch blew up" } }
          .to raise_error(Lain::Error, /blew up/)

        expect(backend.acquired.size).to eq(1)
        expect(backend.released.size).to eq(1)      # reclaimed on the failed adoption
        expect(supervisor.to_a).to be_empty         # nothing registered
        supervisor.stop
      end
    end

    # The cancellation window (panel fix): a lease acquired, then the adopted
    # task CANCELLED mid-launch. Async::Stop is an Exception, not a
    # StandardError, so a `rescue StandardError` would miss it and strand an
    # orphan worktree invisible to #stop -- the reclaim must ride `ensure`.
    it "releases the lease when the adopted task is cancelled after acquire, registering nothing" do
      backend = RecordingIsolation.new(leased_env)
      Sync do |task|
        supervisor = described_class.new(isolation: backend).run(task)
        acquired = Async::Queue.new
        adopter = task.async do
          supervisor.adopt(role: "cancelled") do |_worker_env|
            acquired.enqueue(:go)    # the lease is provably acquired; we are now IN launch
            Async::Queue.new.dequeue # park forever -- only cancellation ends this
          end
        rescue Async::Stop
          # the adopted task was cancelled mid-launch; adopt's own await re-raises
          # it here, and this task exits cleanly so adopter.wait does not re-raise.
        end
        acquired.dequeue             # provably past the acquire, inside the launch
        supervisor.stop              # cancels the in-flight adopted task mid-launch
        adopter.wait

        expect(backend.acquired.size).to eq(1)
        expect(backend.released.size).to eq(1) # reclaimed on cancellation, not stranded
        expect(supervisor.to_a).to be_empty # nothing registered
      end
    end

    # The default backend is the shared-process Null: release is a no-op, so one
    # worker's exit never tears down state a still-running sibling shares.
    it "defaults to the Null backend -- the child runs under the process WorkerEnv, release is a no-op" do
      seen = []
      Sync do |task|
        supervisor = described_class.new.run(task) # no isolation wired
        tool = probing_actor_tool(seen)

        supervisor.adopt(role: "worker") { |worker_env| tool.launch_actor("go", worker_env:) }.settle

        expect(seen.first.cwd).to eq(Dir.pwd) # WorkerEnv.default, exactly as before the seam
        expect { supervisor.stop }.not_to raise_error
      end
    end
  end

  # ---- Scenario: a crashed worker's checkout is reaped, its commits are not --
  #
  # {Supervisor::Restart} replays a dead worker under a NEW worker_id, so nothing
  # ever reclaims the dead one's lease and a multi-day epic run accumulates one
  # orphan worktree per crash. Reclaiming it with a bare `lease.release` would be
  # worse: {Isolation::Worktree} reclaims a --detach'ed checkout with --force, so
  # the instant it is released an unanchored commit is unreachable -- and a
  # crashed worker is exactly the one holding commits nothing else has. The reap
  # therefore runs through {Isolation::WorkerHandoff#surrender}: anchor under
  # refs/lain/worker/, then release, spawning no resolver.

  describe "reaping a crashed worker" do
    # ONE log for both collaborators, because what this scenario is about is
    # ORDER: the surrender lands before the release under it, and both land
    # before the replacement's acquire.
    before do
      stub_const("LoggingIsolation", Class.new do
        def initialize(env, log)
          @env = env
          @log = log
        end

        def acquire(worker_id)
          @log << [:acquire, worker_id]
          log = @log
          Lain::Isolation::Lease.new(worker_env: @env, on_release: -> { log << [:release, worker_id] })
        end
      end)

      # The WorkerHandoff duck, recording. It keeps the real object's own
      # exactly-once guard -- Report.nothing over an already-released lease --
      # so a spec sees exactly the surrenders the real collaborator would
      # perform, and never a phantom repeat of one already given up.
      stub_const("RecordingHandoff", Class.new do
        def initialize(log)
          @log = log
        end

        def surrender(lease, worker_id:)
          return Lain::Isolation::WorkerHandoff::Report.nothing if lease.nil? || lease.released?

          @log << [:surrender, worker_id]
          lease.release
          Lain::Isolation::WorkerHandoff::Report.nothing
        end
      end)

      # An actor duck that answers ONLY #stop -- all {Supervisor#stop} ever owed
      # of a registration's actor before the reap started asking #failed? about
      # every row on the way out. {CLI::Wiring}'s own spec stand-in is exactly
      # this shape, which is how the widened duck stayed invisible.
      stub_const("StopOnlyWorker", Class.new do
        def initialize(log)
          @log = log
        end

        def stop
          @log << %i[farewell minimal]
          self
        end
      end)

      # A handoff outside its own documented contract: {Isolation::WorkerHandoff}
      # answers a Report on every StandardError path, and this one raises
      # instead. It is the injected-collaborator case the totality note names.
      stub_const("ExplodingHandoff", Class.new do
        def surrender(_lease, worker_id:)
          raise Lain::Error, "handoff exploded for #{worker_id}"
        end
      end)

      # A handoff that SUSPENDS before it does anything, which is what a
      # fiber-aware one would do (the real one blocks the whole reactor inside
      # Mixlib::ShellOut, which is what makes the concurrent-reap race benign by
      # accident rather than by construction). The sleep is NOT zero and that is
      # measured: a zero-duration timer is already due when the adopting task
      # parks on its `.wait`, so the reactor resumes this reap to completion
      # before the second adoption ever starts -- and the overlap under test
      # never happens.
      stub_const("SuspendingHandoff", Class.new do
        def initialize(log)
          @log = log
        end

        def surrender(lease, worker_id:)
          return Lain::Isolation::WorkerHandoff::Report.nothing if lease.nil? || lease.released?

          Async::Task.current.sleep(0.02)
          @log << worker_id
          lease.release
          Lain::Isolation::WorkerHandoff::Report.nothing
        end
      end)
    end

    # A handback that CONFLICTS and then refuses to unwind, so the parent stays
    # mid-merge. Driven through the REAL {Isolation::WorkerHandoff} -- whose
    # initializer stays open for a substituted handback -- so the STRANDED
    # Report under test is one the collaborator actually produces, not one the
    # spec invented.
    let(:stranding_handoff) do
      handback = Class.new do
        def call(_lease, worker_id:) = mid_merge(:conflicted, worker_id)

        def abandon(ref, worker_id: ref) = mid_merge(:failed, worker_id)

        private

        def mid_merge(kind, worker_id)
          Lain::Isolation::Worktree::Handback::Outcome.new(
            kind:, worker_key: worker_id, ref: "refs/lain/worker/#{worker_id}",
            paths: ["notes.md"], parent_state: :merging
          )
        end
      end.new
      Lain::Isolation::WorkerHandoff.new(handback:, repo_root: Dir.pwd)
    end

    let(:shared_env) { Lain::WorkerEnv.new(cwd: "/leased/checkout", env: {}) }

    # An adopted worker whose actor dies AFTER the adoption returned: it parks
    # mid-turn and the :raise release fails the in-flight call, leaving it
    # dead-but-not-stopped -- the registry's :failed.
    #
    # A born-dead actor (a Mock with zero responses) will NOT do here, and that
    # is measured: its fiber starts eagerly and fails before the registration
    # lands, so it is already :failed inside its own adoption -- and a reap that
    # ran one line too LATE, after the acquire it is supposed to precede, still
    # produced the right log. This fixture is what tells the two apart.
    #
    # @return [WorkerEnv] the leased environment the crashed worker held
    def crash(supervisor, role: "worker")
      entered = Async::Queue.new
      release = Async::Queue.new
      env, doomed = parked(supervisor, role, entered:, release:)
      entered.dequeue         # provably mid-turn: the adoption is long over
      release.enqueue(:raise) # ... and NOW it dies
      expect { doomed.settle }.to raise_error(Lain::Error, /injected/)
      env
    end

    # @return [Array(WorkerEnv, Tools::Subagent::Actor)] the leased environment
    #   and the actor parked in its first turn
    def parked(supervisor, role, entered:, release:)
      env = nil
      actor = supervisor.adopt(role:) do |worker_env|
        env = worker_env
        parking_tool(entered:, release:).launch_actor("go")
      end
      [env, actor]
    end

    # @return [WorkerEnv] the leased environment the settled worker runs under
    def healthy(supervisor, role: "worker")
      env = nil
      supervisor.adopt(role:) do |worker_env|
        env = worker_env
        actor_tool(text_response("ok")).launch_actor("go")
      end.settle
      env
    end

    it "surrenders the dead worker's lease before the replacement acquires -- ref first, then release" do
      log = []
      Sync do |task|
        supervisor = described_class.new(isolation: LoggingIsolation.new(shared_env, log),
                                         handoff: RecordingHandoff.new(log)).run(task)
        crash(supervisor)
        healthy(supervisor)

        expect(log).to eq([[:acquire, "worker-1"], [:surrender, "worker-1"],
                           [:release, "worker-1"], [:acquire, "worker-2"]])
        # The dead row stays in the registry: it is the honest history of the
        # first life (Restart's own "Identity" note), reaped but not erased.
        expect(supervisor.map(&:state)).to eq(%i[failed running])
        supervisor.stop
      end
    end

    # The panel's first probe: the reap is not a first-crash special case.
    it "surrenders a SECOND crash too, and re-surrenders no lease it already gave up" do
      log = []
      Sync do |task|
        supervisor = described_class.new(isolation: LoggingIsolation.new(shared_env, log),
                                         handoff: RecordingHandoff.new(log)).run(task)
        crash(supervisor)
        crash(supervisor)
        healthy(supervisor)

        expect(log).to eq([[:acquire, "worker-1"], [:surrender, "worker-1"], [:release, "worker-1"],
                           [:acquire, "worker-2"], [:surrender, "worker-2"], [:release, "worker-2"],
                           [:acquire, "worker-3"]])
        supervisor.stop
      end
    end

    it "leaves a LIVE worker's lease alone -- only the crashed row is reaped" do
      log = []
      Sync do |task|
        supervisor = described_class.new(isolation: LoggingIsolation.new(shared_env, log),
                                         handoff: RecordingHandoff.new(log)).run(task)
        healthy(supervisor, role: "alive")
        crash(supervisor, role: "doomed")
        healthy(supervisor, role: "replacement")

        expect(log.select { |entry| entry.first == :surrender }).to eq([[:surrender, "doomed-2"]])
        supervisor.stop
      end
      expect(log.last(2)).to eq([[:release, "alive-1"], [:release, "replacement-3"]])
    end

    # The default is RETAINING, not the release-only WorkerHandoff::Null: with
    # no handoff wired there is nothing that can anchor, and a bare release of a
    # crashed worker's checkout is the one thing this card exists to prevent. An
    # idle worktree until #stop is the cost; the worker's commits are not.
    it "retains a crashed worker's lease when no handoff is wired -- #stop is what reclaims it" do
      log = []
      Sync do |task|
        supervisor = described_class.new(isolation: LoggingIsolation.new(shared_env, log)).run(task)
        crash(supervisor)
        healthy(supervisor)

        expect(log).to eq([[:acquire, "worker-1"], [:acquire, "worker-2"]])
        supervisor.stop
      end
      expect(log.last(2)).to eq([[:release, "worker-1"], [:release, "worker-2"]])
    end

    # ---- #stop is the OTHER place that holds the handoff --------------------
    #
    # The reap on the adoption path only fires when a LATER adoption happens. A
    # supervised fleet shutting down is the likeliest path a crashed worker's
    # lease is ever given up on, and there #stop held @handoff and bare-released
    # anyway -- destroying the force-removed checkout that was the only copy of
    # the worker's commits. The card's headline guarantee, on the likelier path.

    it "surrenders a crashed row at #stop, and bare-releases only the live ones" do
      log = []
      Sync do |task|
        supervisor = described_class.new(isolation: LoggingIsolation.new(shared_env, log),
                                         handoff: RecordingHandoff.new(log)).run(task)
        healthy(supervisor, role: "alive")
        crash(supervisor, role: "doomed")

        supervisor.stop
      end
      expect(log).to eq([[:acquire, "alive-1"], [:acquire, "doomed-2"],
                         [:release, "alive-1"], [:surrender, "doomed-2"], [:release, "doomed-2"]])
    end

    # #stop is what makes an actor `stopped?`, and a stopped row no longer reads
    # :failed -- so the crashed/live question must be asked BEFORE the farewell.
    # Asking after it makes every reap at teardown silently vanish, which is the
    # bug above wearing a different hat.
    it "reads the crashed row's state BEFORE the farewell that would hide it" do
      log = []
      Sync do |task|
        supervisor = described_class.new(isolation: LoggingIsolation.new(shared_env, log),
                                         handoff: RecordingHandoff.new(log)).run(task)
        crashed = crash(supervisor)
        expect(crashed).to eq(shared_env)

        supervisor.stop

        expect(supervisor.map(&:state)).to eq([:stopped]) # the farewell landed too
      end
      expect(log).to eq([[:acquire, "worker-1"], [:surrender, "worker-1"], [:release, "worker-1"]])
    end

    # A lease the handoff DECLINED to take (the Retain default) is still given
    # up at teardown: retaining it is a running-fleet posture, and #stop's job is
    # that nothing lain provisioned is left standing.
    it "still releases a retained crashed lease at #stop when no handoff is wired" do
      log = []
      Sync do |task|
        supervisor = described_class.new(isolation: LoggingIsolation.new(shared_env, log)).run(task)
        crash(supervisor)

        supervisor.stop
      end
      expect(log).to eq([[:acquire, "worker-1"], [:release, "worker-1"]])
    end

    # The reap's DECISION widens the duck #stop demands of an actor: `failed?`
    # asks `stopped?` and `dead?`, which a stand-in owing only `#stop` cannot
    # answer. That raise climbs out of #stop's `each` -- and #stop is what every
    # reactor-owning caller runs from its own `ensure`, where a raise during
    # teardown leaves the root task never completing and the process HANGS in
    # epoll instead of failing. So the decision belongs inside the same
    # tolerance the surrender has.
    #
    # BOUNDED deliberately: a regression here must report, not stall, and an
    # unbounded example would reproduce the hang in the suite rather than name
    # it. The window is the assertion.
    it "tears down a row whose actor cannot answer the reap predicates, without wedging #stop" do
      journal = []
      log = []
      Sync do |task|
        supervisor = described_class.new(journal:, isolation: LoggingIsolation.new(shared_env, log),
                                         handoff: RecordingHandoff.new(log)).run(task)
        supervisor.adopt(role: "minimal") { StopOnlyWorker.new(log) }

        bounded(task) { supervisor.stop }
      end
      expect(log).to eq([[:acquire, "minimal-1"], %i[farewell minimal], [:release, "minimal-1"]])
      # "I cannot tell whether this row crashed" is not "it crashed": a healthy
      # worker must not be surrendered, and must not be recorded as a failed reap.
      expect(journal.grep(described_class::WorkerReaped)).to be_empty
    end

    # Anything that escapes a `Sync` block -- a raise, or a failed expectation --
    # leaves the supervisor's parked reactor task parked, because a #stop that
    # raised never reached its own `@task.stop`. Sync's teardown then waits on
    # that child forever, in epoll, with nothing runnable, and the example HANGS
    # instead of failing. That shape is what let this class of bug through twice:
    # a truncated run reports the examples that SURVIVED as a pass. Both halves
    # are the bound -- the window catches a stall inside the block, and
    # cancelling the leftover children catches the one after it.
    def bounded(task, &block)
      task.with_timeout(2, &block)
    ensure
      task.children&.each(&:stop)
    end

    # ---- the Report the reap gets back --------------------------------------

    # WorkerHandoff::STRANDED is the one state whose remedy is a person running
    # `git merge --abort`: a parent left mid-merge DECLINES every later handback,
    # forever, with `<<<<<<<` markers standing in a real working tree. The Report
    # is the only place it is ever named, so discarding the Report makes it
    # discoverable only when the next handback mysteriously declines.
    it "journals the reap's Report, carrying a STRANDED parent onto the record" do
      journal = []
      Sync do |task|
        supervisor = described_class.new(journal:, isolation: LoggingIsolation.new(shared_env, []),
                                         handoff: stranding_handoff).run(task)
        crash(supervisor)
        healthy(supervisor)
        supervisor.stop
      end
      reaped = journal.grep(described_class::WorkerReaped)
      expect(reaped.map(&:worker_key)).to eq(["worker-1"])
      expect(reaped.first).to have_attributes(role: "worker", kind: :failed, stranded: true,
                                              ref: "refs/lain/worker/worker-1")
      expect(reaped.first.summary).to include("git merge --abort")
      expect(reaped.first.to_journal["type"]).to eq("worker_reaped")
    end

    # The reap runs over every failed row at every adoption, and an
    # already-surrendered lease answers :nothing_to_do -- journaling that would
    # put one noise line per adoption into the experiment record.
    it "journals nothing for a reap with nothing to report" do
      journal = []
      Sync do |task|
        supervisor = described_class.new(journal:, isolation: LoggingIsolation.new(shared_env, []),
                                         handoff: RecordingHandoff.new([])).run(task)
        crash(supervisor)
        healthy(supervisor)
        healthy(supervisor)
        supervisor.stop
      end
      expect(journal.grep(described_class::WorkerReaped)).to be_empty
    end

    # ---- a handoff outside its own contract ---------------------------------
    #
    # {Isolation::WorkerHandoff#surrender} promises a Report on every
    # StandardError path, but `handoff` is INJECTED and the doc never demanded
    # totality. A reap's failure belongs to the reap: it must not refuse an
    # unrelated adoption, and it must not wedge the fleet's teardown.

    it "survives a handoff that RAISES: the replacement is adopted and the raise is journalled" do
      journal = []
      log = []
      Sync do |task|
        supervisor = described_class.new(journal:, isolation: LoggingIsolation.new(shared_env, log),
                                         handoff: ExplodingHandoff.new).run(task)
        crash(supervisor)

        # Bounded: an intolerant reap does not fail this example, it HANGS it --
        # the raise escapes the Sync and strands the parked reactor task.
        bounded(task) do
          expect { healthy(supervisor) }.not_to raise_error
          expect { supervisor.stop }.not_to raise_error
        end
      end
      expect(journal.grep(described_class::WorkerReaped).map(&:summary))
        .to eq(["Lain::Error: handoff exploded for worker-1"])
      # The surrender failed, so the lease was never given up -- #stop's own
      # release is what keeps a broken handoff from leaking the checkout too.
      expect(log).to include([:release, "worker-1"])
    end

    # ONE journalled failure, not one per adoption: the reap is claimed, and a
    # claim is not handed back on failure. One attempt then say it is
    # {Isolation::WorkerHandoff}'s own posture on a refusal it cannot retry.
    it "attempts a raising handoff exactly once, however many adoptions follow" do
      journal = []
      Sync do |task|
        supervisor = described_class.new(journal:, isolation: LoggingIsolation.new(shared_env, []),
                                         handoff: ExplodingHandoff.new).run(task)
        crash(supervisor)
        bounded(task) do
          healthy(supervisor)
          healthy(supervisor)
          supervisor.stop
        end
      end
      expect(journal.grep(described_class::WorkerReaped).size).to eq(1)
    end

    # ---- the concurrent-reap race -------------------------------------------

    # Two adoptions in flight over one crashed row. The real WorkerHandoff's own
    # exactly-once guard (Report.nothing over an already-released lease) is
    # check-then-act, and holds only because Mixlib::ShellOut blocks the whole
    # reactor -- an accident of that collaborator, not a property of this loop.
    # The claim is taken synchronously, so a fiber-aware handoff is safe too.
    it "reaps a crashed row exactly once across two concurrent adoptions" do
      surrenders = []
      Sync do |task|
        supervisor = described_class.new(isolation: LoggingIsolation.new(shared_env, []),
                                         handoff: SuspendingHandoff.new(surrenders)).run(task)
        crash(supervisor)

        [task.async { healthy(supervisor, role: "a") },
         task.async { healthy(supervisor, role: "b") }].each(&:wait)
        supervisor.stop
      end
      expect(surrenders).to eq(["worker-1"])
    end

    # The card's own scenario, driven through the object it names: a Restart
    # replays the dead worker under a new worker_id, and reaches the reap
    # because it adopts through {Supervisor#adopt} like every other adoption.
    it "reaps the worker a Restart replaces, and the replacement holds the fresh lease" do
      log = []
      record = killed_session_record
      Sync do |task|
        supervisor = described_class.new(isolation: LoggingIsolation.new(shared_env, log),
                                         handoff: RecordingHandoff.new(log)).run(task)
        crash(supervisor, role: "researcher")
        restart(record, supervisor:)

        expect(log).to eq([[:acquire, "researcher-1"], [:surrender, "researcher-1"],
                           [:release, "researcher-1"], [:acquire, "researcher-2"]])
        expect(supervisor.map(&:role)).to eq(%w[researcher researcher])
        supervisor.stop
      end
    end

    # A minimal open session record: a Scribe writes its header at construction
    # and catch_up appends the committed turn, which is everything the Loader's
    # verified re-commit needs. No tools and no snapshot, so the restart
    # restores no workspace -- what is under test here is the ADOPTION.
    def killed_session_record
      io = StringIO.new
      scribe = Lain::SessionRecord::Scribe.new(journal: Lain::Journal.new(io:), context: restart_context,
                                               toolset: Lain::Toolset.new([]))
      agent = restart_agent([text_response("worked")], Lain::Timeline.empty(store:))
      agent.ask("do the thing")
      scribe.catch_up(agent.timeline)
      io.string.each_line
    end

    def restart_context = Lain::Context.new(model: "actor", max_tokens: 128)

    def restart_agent(responses, timeline)
      Lain::Agent.new(provider: Lain::Provider::Mock.new(responses:), toolset: Lain::Toolset.new([]),
                      context: restart_context, timeline:)
    end

    def restart(record, supervisor:)
      Lain::Supervisor::Restart.new(entries: record, supervisor:, journal: Lain::Channel::Null.instance)
                               .call(role: "researcher") { |recording| restart_agent([], recording.timeline) }
    end

    # The AC's observable claims, against the real backend and the real
    # handback. Operates on a THROWAWAY repo it creates itself (git init in a
    # mktmpdir), never the lain repo it runs in -- worktree_spec.rb's posture,
    # and the reason this stays in the default suite: git is always present.
    describe "against a real worktree backend" do
      around do |example|
        Dir.mktmpdir("lain-repo") do |repo|
          Dir.mktmpdir("lain-worktrees") do |worktrees|
            @repo_root = File.realpath(repo)
            @worktrees = File.realpath(worktrees)
            init_repo(@repo_root)
            example.run
          end
        end
      end

      let(:handback_journal) { [] }
      let(:backend) { Lain::Isolation::Worktree.new(repo_root: @repo_root, root: @worktrees) }
      let(:handoff) { Lain::Isolation::WorkerHandoff.over(repo_root: @repo_root, journal: handback_journal) }

      # The spec's OWN git calls scrub the git-context env, so building and
      # inspecting the throwaway repo is hermetic under an ambient GIT_*-polluted
      # env (a pre-commit hook) exactly as the subject is.
      def run_git(dir, *args)
        shell = Mixlib::ShellOut.new("git", "-C", dir, *args,
                                     environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
        shell.run_command.error!
        shell.stdout
      end

      # Copied, not rebuilt: five git subprocesses per example for a directory that
      # is identical every time (see {SeedRepo}). A method, not a constant --
      # a constant inside a top-level `RSpec.describe do ... end` lands on Object,
      # where a second spec file spelling the same name silently clobbers it.
      def init_repo(dir) = FileUtils.cp_r("#{SeedRepo.at(seed_files)}/.", dir)

      def seed_files = { "seed.txt" => "seed\n" }

      def commit_work(dir)
        File.write(File.join(dir, "worker.txt"), "the crashed worker's only copy\n")
        run_git(dir, "add", "-A")
        run_git(dir, "commit", "-q", "-m", "worker work")
        run_git(dir, "rev-parse", "HEAD").strip
      end

      def anchored_commits = run_git(@repo_root, "for-each-ref", "--format=%(objectname)", "refs/lain/worker/").split

      def worktree_paths = run_git(@repo_root, "worktree", "list").lines

      it "reaps the dead worker's checkout, keeps its commit on refs/lain/worker/, " \
         "and gives the replacement a fresh lease" do
        Sync do |task|
          supervisor = described_class.new(isolation: backend, handoff:).run(task)
          crashed = crash(supervisor)
          commit = commit_work(crashed.cwd)

          replacement = healthy(supervisor)

          expect(Dir.exist?(crashed.cwd)).to be(false)   # the orphan worktree is gone
          expect(anchored_commits).to include(commit)    # and the work it held is not
          expect(replacement.cwd).not_to eq(crashed.cwd)
          expect(Dir.exist?(replacement.cwd)).to be(true)
          supervisor.stop
        end
      end

      # THE blocker probe, against real git: a crash, a commit, and a shutdown
      # with no later adoption to reap it. #stop force-removes a --detach'ed
      # checkout, so a bare release here is the worker's commits gone -- and a
      # supervised fleet shutting down is the most likely path there is.
      it "surrenders a crashed worker at #stop, keeping its commits when no adoption follows" do
        commit = nil
        Sync do |task|
          supervisor = described_class.new(isolation: backend, handoff:).run(task)
          crashed = crash(supervisor)
          commit = commit_work(crashed.cwd)

          supervisor.stop

          expect(Dir.exist?(crashed.cwd)).to be(false)  # the checkout is reclaimed
        end
        expect(anchored_commits).to include(commit)     # and the work it held is not lost
        # Anchored FIRST, then offered: the ref is what survives the release, and
        # a clean parent takes the merge on top of it.
        expect(handback_journal.map(&:outcome)).to eq([:merged])
      end

      it "leaves no lain-owned worktree standing after #stop" do
        Sync do |task|
          supervisor = described_class.new(isolation: backend, handoff:).run(task)
          commit_work(crash(supervisor).cwd)
          healthy(supervisor)

          supervisor.stop
        end

        expect(worktree_paths.size).to eq(1) # the parent checkout, and nothing else
        expect(Dir.children(@worktrees)).to be_empty
      end

      # The panel's second probe: a crash with nothing to hand back must still
      # give the lease up cleanly. The parent already contains the worktree's
      # HEAD, so the handback is :nothing_to_do -- never a :failed outcome left
      # behind in the record for someone to chase.
      it "releases a crashed worker that committed NOTHING cleanly, anchoring no ref" do
        Sync do |task|
          supervisor = described_class.new(isolation: backend, handoff:).run(task)
          crashed = crash(supervisor)

          healthy(supervisor)

          expect(Dir.exist?(crashed.cwd)).to be(false)
          expect(handback_journal.map(&:outcome)).to eq([:nothing_to_do])
          expect(anchored_commits).to be_empty
          supervisor.stop
        end
      end
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
