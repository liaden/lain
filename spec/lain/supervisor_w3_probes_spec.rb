# frozen_string_literal: true

require "async"
require "async/queue"
require "json"
require "tmpdir"

# W3 REVIEW PROBES (adversarial; leave in worktree). Each block names the AC or
# claim it tries to falsify and the persona that owns the finding. Probes that
# DOCUMENT a gap assert current behavior and say FINDING in the comment -- the
# probe stays green so the file is runnable evidence, and the review carries
# the ranked finding.
RSpec.describe "W3 probes: Supervisor reactor (OM-6 core)" do
  let(:store) { Lain::Store.new }
  let(:log) { Lain::Tools::Subagent::Log.new }
  let(:parent_timeline) do
    Lain::Timeline.empty(store:)
                  .commit(role: :user, content: [{ "type" => "text", "text" => "hi" }])
                  .commit(role: :assistant, content: [{ "type" => "text", "text" => "yo" }])
  end
  let(:invocation) { Lain::Tool::Invocation.new(context: Lain::Session::Null.instance) }

  # A provider that announces entry on one queue and parks on another; a
  # :raise release fails the call instead of answering it. Deterministic
  # sequencing for every "mid-turn" window below.
  before do
    stub_const("W3ParkProvider", Class.new(Lain::Provider::Mock) do
      def initialize(entered:, release:, **rest)
        super(**rest)
        @entered = entered
        @release = release
      end

      def complete(request)
        @entered.enqueue(true)
        signal = @release.dequeue
        raise Lain::Error, "provider failure injected mid-turn" if signal == :raise
        # The fix-round probe: an actor whose CAPTURED failure is itself an
        # Async::TimeoutError (a user tool could raise one; no lib path does).
        raise Async::TimeoutError, "captured by the actor, not the drain" if signal == :timeout

        super
      end
    end)
  end

  def actor_tool(provider:, journal: Lain::Channel::Null.instance, supervisor: Lain::Supervisor::Null)
    Lain::Tools::Subagent.new(
      provider:, context_factory: -> { Lain::Context.new(model: "child", max_tokens: 128) },
      toolset: Lain::Toolset.new([EchoTool.new]),
      policy: Lain::Tool::SpawnPolicy.new(prefix: :fresh, posture: :schema, only: []),
      parent: parent_timeline, journal:, mode: :actor, log:, supervisor:
    )
  end

  def mock(*responses) = Lain::Provider::Mock.new(responses:)

  # FIX 4 landed the machine-readable discriminator this helper originally had
  # to fake with a prose match.
  def farewells(records)
    records.grep(Lain::Telemetry::Message).select { |m| m.payload["lifecycle"] == "stopped" }
  end

  # ---- (a) The wedge, half 1: parent ask killed while the actor is mid-turn --
  #
  # OM-6's point: the actor is a sibling of the ask, not its captive. Kill the
  # ask while the actor's first turn is parked at provider IO -- the actor must
  # stay registered, alive, and settleable.
  describe "the wedge" do
    it "PROBE(a1): the actor survives its parent ask being stopped mid-turn" do
      Sync do |task|
        supervisor = Lain::Supervisor.new.run(task)
        actor_entered = Async::Queue.new
        actor_release = Async::Queue.new
        tool = actor_tool(
          provider: W3ParkProvider.new(entered: actor_entered, release: actor_release,
                                       responses: [text_response("actor ready")]),
          supervisor:
        )
        parent_entered = Async::Queue.new
        parent_release = Async::Queue.new
        parent = Lain::Agent.new(
          provider: W3ParkProvider.new(entered: parent_entered, release: parent_release,
                                       responses: [tool_response(["a1", "subagent", { "prompt" => "go" }]),
                                                   text_response("never reached")]),
          toolset: Lain::Toolset.new([tool]),
          context: Lain::Context.new(model: "parent", max_tokens: 256),
          timeline: Lain::Timeline.empty(store:)
        )

        ask = task.async { parent.ask("spawn an actor") }
        parent_entered.dequeue          # ask reached provider call 1
        parent_release.enqueue(:go)     # tool_use returns; dispatch adopts the actor
        actor_entered.dequeue           # the actor is provably mid-turn
        parent_entered.dequeue          # the dispatch fully completed (ask parked on call 2)

        ask.stop                        # kill the parent's ask mid-spawn

        expect(supervisor.count).to eq(1)
        registration = supervisor.first
        expect(registration.state).to eq(:running)
        actor_release.enqueue(:go)      # the actor finishes its turn under the supervisor
        expect(registration.actor.settle).not_to be_dead
        supervisor.stop
        expect(registration.state).to eq(:stopped)
      end
    end

    # FIXED (was FINDING Linus, half 2): #adopt used to append the
    # Registration on the CALLING fiber, after `.wait` -- a launch that
    # awaited plus a cancelled adopter orphaned a live, unregistered actor.
    # Registration now happens inside the adopted task, so the ghost window
    # is gone: registered, drained, farewelled.
    it "PROBE(a2): killing the adopter between launch and registration no longer orphans the actor" do
      Sync do |task|
        supervisor = Lain::Supervisor.new.run(task)
        journal = Lain::Channel.new
        tool = actor_tool(provider: mock(text_response("ready")), journal:, supervisor:)
        gate = Async::Queue.new
        launched = nil

        adopter = task.async do
          supervisor.adopt(role: "ghost") do
            actor = tool.launch_actor("go")
            launched = actor
            gate.dequeue # any real await in a launch opens this window
            actor
          end
        end
        adopter.stop        # the adopting caller dies mid-spawn
        gate.enqueue(:go)   # the launch completes under the supervisor's task
        task.yield          # enqueue only SCHEDULES the adopted fiber; let it run
        launched.settle

        expect(launched).not_to be_dead                  # the actor SURVIVES (OM-6's point)...
        expect(supervisor.map(&:role)).to eq(["ghost"])  # ...and is REGISTERED

        supervisor.stop
        expect(launched).to be_stopped
        expect(farewells(journal.drain).size).to eq(1)   # ...with its farewell journaled
      ensure
        supervisor&.stop
      end
    end
  end

  # ---- (b) Registry Array semantics under an address collision --------------
  #
  # Two spawns of the same arm from the same head are byte-identical :spawn
  # events (ChainWriter has no nonce), so they SHARE one content digest ==
  # address. The Array keeps both (the Hash-drop fix). What remains collapsed
  # is everything ADDRESS-grain.
  it "PROBE(b): identical spawns share an address -- both enumerate, object routing works, attribution collapses" do
    journal = Lain::Channel.new
    twin_a = twin_b = nil
    Sync do |task|
      supervisor = Lain::Supervisor.new.run(task)
      tool = actor_tool(provider: mock(text_response("one"), text_response("two")), journal:, supervisor:)
      twin_a = supervisor.adopt(role: "twin-a") { tool.launch_actor("go") }
      twin_b = supervisor.adopt(role: "twin-b") { tool.launch_actor("go") }
      [twin_a, twin_b].each(&:settle)

      expect(twin_a.address).to eq(twin_b.address)  # the collision is real
      expect(supervisor.count).to eq(2)             # both enumerate (AC2 holds)

      twin_a.stop                                   # routing is by OBJECT -- stops only twin-a
      expect(supervisor.map(&:state)).to eq(%i[stopped running])
      twin_b.tell("still routable")                 # twin-b still tellable...

      supervisor.stop
    end

    records = journal.drain

    # FINDING (Linus/Schneeman): ...but tells and farewells are addressed by
    # the SHARED digest: twin-a's farewell is byte-attributable to twin-b,
    # and both actors fold one mailbox. Address-grain identity is ambiguous
    # by construction; only the in-process object handle disambiguates.
    expect(farewells(records).first.from).to eq(twin_b.address)

    # An unmodified StatusFeed shows ONE fleet entry for the TWO actors that
    # were adopted -- keyed by digest, the redelivery guard and the collision
    # are indistinguishable. The HUD undercounts a twinned fleet.
    Dir.mktmpdir("w3-probe-b") do |dir|
      path = File.join(dir, "state.json")
      feed = Lain::StatusFeed.new(path:)
      records.each { |record| feed << record }
      expect(JSON.parse(File.read(path))["fleet"]).to eq([twin_a.address])
    end
  end

  # ---- (c) TurnMailbox: render/commit agreement across the async window ------
  #
  # The one real yield inside a turn is the provider round trip (capture ->
  # render is a single synchronous stretch on the Agent's fiber). A message
  # landing THERE -- after render, before commit -- must stay out of both: the
  # committed causal_parents must equal exactly what the render folded.
  describe "TurnMailbox under a mid-turn message" do
    let(:recipient) { Lain::Event::ChainWriter.correlation_of(parent_timeline) }
    let(:seam) { Lain::Supervisor::TurnMailbox.new(source: Lain::Context::Mailbox::Source.new(recipient:, log:)) }

    def note(text)
      lineage = Lain::Tools::Subagent::Lineage.new(
        policy: Lain::Tool::SpawnPolicy.new(prefix: :fresh, posture: :schema, only: []), log:
      )
      lineage.note(parent_timeline, from: "actor", to: recipient, text:, causal_parents: [])
    end

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

    it "PROBE(c): a message landing between render and commit enters NEITHER, and the next turn folds it" do
      mid_note = nil
      inject = -> { mid_note ||= note("mid-turn arrival") }
      provider = Class.new(Lain::Provider::Mock) do
        define_method(:complete) do |request|
          response = super(request)
          inject.call
          response
        end
      end.new(responses: [text_response("turn one"), text_response("turn two")])
      agent = seam_agent(provider)

      pre_note = note("before the turn")
      agent.ask("first")
      agent.ask("second")

      first_request, second_request = provider.requests
      expect(mailbox_text(first_request)).to include("before the turn")
      expect(mailbox_text(first_request)).not_to include("mid-turn arrival")
      expect(mailbox_text(second_request)).to include("mid-turn arrival")

      turns = agent.timeline.to_a
      # Turn 1's commit consumed exactly its render's fold -- never the note
      # that arrived during the round trip; turn 2 consumed the straggler.
      expect(turns[3].causal_parents).to eq([pre_note.digest])
      expect(turns[5].causal_parents).to eq([mid_note.digest])
    end
  end

  # ---- (d) The REAL journaled lifecycle through an unmodified StatusFeed ----
  it "PROBE(d): :spawn lands the fleet entry; settle and stop pass through inertly -- stop never RETIRES the entry" do
    journal = Lain::Channel.new
    actor = nil
    Sync do |task|
      supervisor = Lain::Supervisor.new.run(task)
      actor = supervisor.adopt(role: "hud") do
        actor_tool(provider: mock(text_response("ready")), journal:).launch_actor("go")
      end
      actor.settle
      actor.stop
      supervisor.stop
    end

    records = journal.drain.grep(Lain::Telemetry::Message)
    expect(records.map(&:kind)).to eq(%i[spawn message message])

    Dir.mktmpdir("w3-probe-d") do |dir|
      path = File.join(dir, "state.json")
      feed = Lain::StatusFeed.new(path:)
      fleet_after_each = records.map do |record|
        feed << record
        JSON.parse(File.read(path))["fleet"]
      end
      # Appears at :spawn and (still) never retires: StatusFeed is unchanged
      # in this card BY DESIGN -- its "W3's lifecycle events will later enrich
      # this" comment is now TRUE rather than stale, because FIX 4 landed the
      # machine-readable body-level discriminator a later enrichment keys on
      # (launched/settled/stopped; tells carry none). Landing it now was the
      # cheap moment: events are content-addressed, so a later marker would
      # have changed digests under recorded journals.
      expect(fleet_after_each).to eq([[actor.address]] * 3)
      expect(records.first.payload["lifecycle"]).to eq("launched")
      farewell = records.last
      expect(farewell.kind).to eq(:message)
      expect(farewell.payload).to eq({ "text" => "actor stopped", "lifecycle" => "stopped" })
    end
  end

  # ---- (e) Refusal byte-identity against main (5b077c9) ---------------------
  it "PROBE(e): the unwired and not-running refusals are byte-identical to main's" do
    # Literal transcribed from `git show 5b077c9:lib/lain/tools/subagent.rb`
    # during review -- if this drifts, the AC4 byte-for-byte claim is broken.
    expected = "actor mode cannot be launched from a tool call: a long-lived actor needs " \
               "the OM-6 supervisor reactor; launch it programmatically via #launch_actor"

    unwired = actor_tool(provider: mock(text_response("unused")))
    result = unwired.call({ "prompt" => "go" }, invocation)
    expect(result).to be_error
    expect(result.content).to eq(expected)

    not_running = actor_tool(provider: mock(text_response("unused")), supervisor: Lain::Supervisor.new)
    expect(not_running.call({ "prompt" => "go" }, invocation).content).to eq(expected)
  end

  # ---- (f) Shutdown drain vs a hung / failing actor -------------------------
  describe "the drain" do
    let(:chronicle) do
      Class.new do
        def initialize = @reasons = []
        attr_reader :reasons

        def close(reason:) = tap { @reasons << reason }
      end.new
    end

    # FIXED (was FINDING Linus): grace used to bound only the countdown --
    # once draining, a hung actor wedged wait_responses forever with the
    # sigquit escape hatch queued unread behind the blocked coordinator.
    # Conductor now hands Shutdown the BOUNDED drain view
    # (`supervisor.drain(within: grace)`): a hung fleet costs at most the
    # window, the timeout is journaled (never silently dropped), and the
    # session still closes :exit. (run_task.wait remains unbounded --
    # pre-existing shape, out of W3's scope.)
    it "PROBE(f1): a hung actor no longer wedges wait_responses -- the bounded drain closes within the window" do
      journal = Lain::Channel.new
      Sync do |task|
        supervisor = Lain::Supervisor.new(journal:).run(task)
        entered = Async::Queue.new
        release = Async::Queue.new
        tool = actor_tool(provider: W3ParkProvider.new(entered:, release:, responses: [text_response("late")]),
                          supervisor:)
        supervisor.adopt(role: "hung") { tool.launch_actor("go") }
        entered.dequeue # the actor is provably mid-turn; nothing releases it

        run = task.async { :done }
        shutdown = Lain::CLI::Shutdown.new(run_task: run, closer: chronicle,
                                           actors: supervisor.drain(within: 0.05), grace: 0.05)
        coordinator = task.async { shutdown.coordinate }
        shutdown.signal(:wait_responses)

        coordinator.wait # completes on its own: the drain gave up at the bound
        expect(shutdown.state).to eq(:closed)
        expect(chronicle.reasons).to eq([:exit])
        timeout = journal.drain.find { |r| r.to_journal["type"] == "drain_timed_out" }
        expect(timeout.to_journal["roles"]).to eq(["hung"])
      ensure
        supervisor&.stop
        shutdown&.dispose
      end
    end

    # FIXED (was FINDING Linus, BLOCKER): Registration#settle's dead-skip was
    # check-then-wait -- an actor LIVE at the check that failed during the
    # await re-raised through `@actors.each(&:settle)` and killed the
    # coordinator: close(:exit) never journaled. The mid-drain failure is now
    # absorbed by Registration#settle (still loud for direct Actor#settle
    # callers, which re-raise the captured failure on every call).
    it "PROBE(f2): an actor failing DURING the drain no longer kills the coordinator -- the session closes :exit" do
      Sync do |task|
        supervisor = Lain::Supervisor.new.run(task)
        entered = Async::Queue.new
        release = Async::Queue.new
        tool = actor_tool(provider: W3ParkProvider.new(entered:, release:, responses: [text_response("never")]),
                          supervisor:)
        actor = supervisor.adopt(role: "doomed-late") { tool.launch_actor("go") }
        entered.dequeue

        run = task.async { :done }
        shutdown = Lain::CLI::Shutdown.new(run_task: run, closer: chronicle,
                                           actors: supervisor.drain(within: 1), grace: 1)
        coordinator = task.async { shutdown.coordinate }
        shutdown.signal(:wait_responses)
        sleep(0.05)                    # the drain has passed dead? and parked in settle
        expect(shutdown.state).to eq(:draining)

        release.enqueue(:raise)        # the in-flight turn now fails
        coordinator.wait
        expect(shutdown.state).to eq(:closed)
        expect(chronicle.reasons).to eq([:exit])
        expect(supervisor.map(&:state)).to eq([:failed])
        expect { actor.settle }.to raise_error(Lain::Error, /injected/)
      ensure
        supervisor&.stop
        shutdown&.dispose
      end
    end
  end

  # ---- (f, fix round) the FIX 1 x FIX 3 interaction at the parked settle ----
  describe "the bounded drain over a mixed fleet" do
    # The coordinator's hard case: actor 1 settles fast DURING the window,
    # actor 2 hangs. The fast one must be awaited to quiescence before the
    # bound expires on the hung one, and exactly one timeout journals.
    it "PROBE(f3): the fast actor settles cleanly, the hung one times out, ONE record journals" do
      journal = Lain::Channel.new
      Sync do |task|
        supervisor = Lain::Supervisor.new(journal:).run(task)
        fast_entered = Async::Queue.new
        fast_release = Async::Queue.new
        fast = supervisor.adopt(role: "fast") do
          actor_tool(provider: W3ParkProvider.new(entered: fast_entered, release: fast_release,
                                                  responses: [text_response("quick")]),
                     supervisor:).launch_actor("go")
        end
        hung_entered = Async::Queue.new
        hung = actor_tool(provider: W3ParkProvider.new(entered: hung_entered, release: Async::Queue.new,
                                                       responses: [text_response("never")]),
                          supervisor:)
        supervisor.adopt(role: "hung") { hung.launch_actor("go") }
        fast_entered.dequeue
        hung_entered.dequeue # both provably mid-turn

        drain = task.async { supervisor.drain(within: 0.2).each(&:settle) }
        fast_release.enqueue(:go) # the fast actor finishes inside the window
        drain.wait

        expect(fast).not_to be_dead # awaited to quiescence, not abandoned
        expect(supervisor.map(&:state)).to eq(%i[running running])
        timeouts = journal.drain.select { |r| r.to_journal["type"] == "drain_timed_out" }
        expect(timeouts.size).to eq(1)
        # Fleet-grain honesty, documented in DrainTimedOut's comment: the
        # record names the WHOLE fleet ("these were being drained when the
        # window closed"), including the actor that did settle -- which
        # registration was mid-settle is not knowable from outside the loop.
        expect(timeouts.first.to_journal["roles"]).to eq(%w[fast hung])
      ensure
        supervisor&.stop
      end
    end

    # FINDING (Jeremy, NIT -- documented gap, left green as evidence): the
    # TimeoutError pass-through keys on the exception CLASS, so an actor whose
    # own captured failure happens to be Async::TimeoutError (a user tool
    # could raise one; today no lib path leaves one in @failure during a
    # drain) is indistinguishable from the Drain's bound: Registration#settle
    # re-raises it, Drain journals a FALSE drain_timed_out long before the
    # window closes, and the rest of the fleet's settle loop is abandoned. A
    # dedicated exception (`with_timeout(@within, Drain::Expired)`) would make
    # the pass-through exact.
    it "PROBE(f4): an actor's own captured Async::TimeoutError is misread as the drain's bound" do
      journal = Lain::Channel.new
      Sync do |task|
        supervisor = Lain::Supervisor.new(journal:).run(task)
        entered = Async::Queue.new
        release = Async::Queue.new
        supervisor.adopt(role: "self-timed-out") do
          actor_tool(provider: W3ParkProvider.new(entered:, release:, responses: [text_response("never")]),
                     supervisor:).launch_actor("go")
        end
        entered.dequeue # live at the dead? check

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        drain = task.async { supervisor.drain(within: 60).each(&:settle) }
        release.enqueue(:timeout) # the actor's OWN failure is a TimeoutError

        expect { drain.wait }.not_to raise_error # the coordinator still survives...
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        expect(elapsed).to be < 1 # ...but a 60s window "expired" immediately:
        timeouts = journal.drain.select { |r| r.to_journal["type"] == "drain_timed_out" }
        expect(timeouts.size).to eq(1) # a false drain_timed_out, conflating actor failure with the bound
      ensure
        supervisor&.stop
      end
    end
  end

  # ---- (g) Supervisor stopped while actors live -----------------------------
  it "PROBE(g1): stop with an actor mid-turn farewells it, cancels cleanly, and the Sync returns (no orphans)" do
    journal = Lain::Channel.new
    actor = nil
    Sync do |task|
      supervisor = Lain::Supervisor.new.run(task)
      entered = Async::Queue.new
      release = Async::Queue.new
      tool = actor_tool(provider: W3ParkProvider.new(entered:, release:, responses: [text_response("late")]),
                        journal:, supervisor:)
      actor = supervisor.adopt(role: "busy") { tool.launch_actor("go") }
      entered.dequeue          # mid-turn

      supervisor.stop          # farewell first, then structured cancellation
      expect(actor).to be_stopped
      expect(supervisor.running?).to be(false)
    end
    # The Sync returning at all is the no-orphan proof; the farewell landed:
    expect(farewells(journal.drain).size).to eq(1)
  end

  # FIXED (was NIT Jeremy): the guard now enforces the comment -- one reactor
  # per Supervisor's LIFE. Run-after-stop refuses, so the first life's dead
  # rows can never leak into a second; build another Supervisor instead.
  it "PROBE(g2): run-after-stop refuses -- no second life, no lingering dead rows" do
    supervisor = Lain::Supervisor.new
    Sync do |task|
      supervisor.run(task)
      actor = supervisor.adopt(role: "first-life") do
        actor_tool(provider: mock(text_response("ok"))).launch_actor("go")
      end
      actor.settle
      supervisor.stop

      expect { supervisor.run(task) }.to raise_error(Lain::Supervisor::AlreadyRunning, /another Supervisor/)
      expect(supervisor.running?).to be(false)
    ensure
      supervisor.stop
    end
  end
end
