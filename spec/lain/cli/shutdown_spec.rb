# frozen_string_literal: true

# T20: the shutdown coordinator. A fiber that parks on a self-pipe's read end
# (the async-signal-safe ingress a real Signal.trap writes one byte into -- T22
# installs those traps; this card owns the pipe + the parked reader), runs the
# policy `running -> grace(deadline) -> draining -> closed`, and interrupts the
# run through `Budget#interrupt` exactly as docs/concurrency.md's worked
# supervisor sketched. Cancellation is driven the same deterministic way
# spec/lain/agent_cancellation_spec.rb pins it: a provider that PARKS inside a
# model call on an internal queue, so the reactor is provably inside a model
# call -- no `sleep`, no timing race -- when the coordinator acts.
RSpec.describe Lain::CLI::Shutdown do
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }

  # Records what reason the session was closed with. The one method the
  # coordinator's closer duck owes ({Lain::CLI::Chronicle#close} satisfies it),
  # so a test double is three lines.
  let(:closer) do
    Class.new do
      def initialize = @reasons = []
      attr_reader :reasons

      def close(reason:)
        @reasons << reason
        self
      end
    end.new
  end

  # The coordinator announces each transition here (the seam T21's countdown UI
  # renders on). A buffered Async::Queue makes it the tests' synchronization
  # point: `transitions.dequeue` parks until the coordinator has actually
  # reached the next state, so no example polls or sleeps.
  let(:transitions) { Async::Queue.new }
  let(:on_transition) { ->(state, _deadline) { transitions.enqueue(state) } }

  # A Provider::Mock that parks inside `complete` on its `park_on`-th call: it
  # announces arrival on `entered`, then blocks on `release` -- a queue the TEST
  # holds, so an example decides whether the in-flight call ever completes
  # (wait_responses) or is cancelled mid-park (every interrupt path).
  before do
    stub_const("ControllableProvider", Class.new(Lain::Provider::Mock) do
      def initialize(park_on:, entered:, release:, **rest)
        super(**rest)
        @park_on = park_on
        @entered = entered
        @release = release
      end

      def complete(request)
        if call_count + 1 == @park_on
          @entered.enqueue(true)
          @release.dequeue
        end
        super
      end
    end)
  end

  # A journal that keeps every record, so a spec can prove the committed turn's
  # TurnUsage survived the interrupt (the commit+journal atom completed).
  def recording_journal
    Class.new do
      def initialize = @records = []
      attr_reader :records

      def <<(record)
        @records << record
        self
      end
    end.new
  end

  # A clock stub returning the given values in order, repeating the last one
  # forever after (the Middleware::Timeout testing idiom): robust to an extra
  # `@clock.call` the coordinator might make after the deadline check.
  def clock_returning(*values)
    seq = values.dup
    -> { seq.size > 1 ? seq.shift : seq.first }
  end

  def build_agent(park_on:, entered:, release:, responses:, journal: Lain::Channel::Null.instance)
    provider = ControllableProvider.new(park_on:, entered:, release:, responses:)
    Lain::Agent.new(provider:, toolset:, context:, journal:)
  end

  def build_coordinator(run_task:, agent:, clock:, grace: 60)
    described_class.new(run_task:, closer:, budget: agent.budget, clock:, grace:, on_transition:)
  end

  describe "sigterm starts a grace window; the clock passing the deadline interrupts" do
    it "interrupts the run, keeps the committed turn + its journal record, and closes grace_expired" do
      entered = Async::Queue.new
      release = Async::Queue.new
      journal = recording_journal
      # Park inside the SECOND model call, so [user, assistant(tool_use),
      # user(tool_result)] is committed and the first turn's TurnUsage is
      # journaled before the interrupt lands -- the atom the AC names.
      agent = build_agent(park_on: 2, entered:, release:, journal:,
                          responses: [tool_response(%w[tu_1 echo] << { "text" => "x" }), text_response])
      returned = :never_returned

      Sync do |task|
        run = task.async { returned = agent.ask("hi") }
        entered.dequeue
        shutdown = build_coordinator(run_task: run, agent:, clock: clock_returning(1000.0, 1061.0))
        coordinator = task.async { shutdown.coordinate }
        shutdown.signal(:sigterm)
        coordinator.wait
        shutdown.dispose
      end

      expect(returned).to eq(:never_returned)
      expect(closer.reasons).to eq(%i[grace_expired])
      expect(agent.timeline.to_a.map(&:role)).to eq(%w[user assistant user])
      expect(journal.records.size).to eq(1)
    end
  end

  describe "cancel aborts the shutdown" do
    it "returns to running, clears the deadline, and interrupts nothing" do
      entered = Async::Queue.new
      release = Async::Queue.new
      agent = build_agent(park_on: 1, entered:, release:, responses: [text_response])
      returned = :never_returned

      Sync do |task|
        run = task.async { returned = agent.ask("hi") }
        entered.dequeue
        shutdown = build_coordinator(run_task: run, agent:, clock: clock_returning(1000.0))
        coordinator = task.async { shutdown.coordinate }

        shutdown.signal(:sigint)
        expect(transitions.dequeue).to eq(:grace)
        shutdown.signal(:cancel)
        expect(transitions.dequeue).to eq(:running)

        expect(run.stopped?).to be(false)
        expect(shutdown.state).to eq(:running)
        expect(shutdown.deadline).to be_nil

        coordinator.stop
        run.stop
        shutdown.dispose
      end

      expect(closer.reasons).to be_empty
      expect(returned).to eq(:never_returned)
    end
  end

  describe "a second sigint promotes" do
    it "interrupts immediately with reason interrupted" do
      entered = Async::Queue.new
      release = Async::Queue.new
      agent = build_agent(park_on: 1, entered:, release:, responses: [text_response])
      returned = :never_returned

      Sync do |task|
        run = task.async { returned = agent.ask("hi") }
        entered.dequeue
        shutdown = build_coordinator(run_task: run, agent:, clock: clock_returning(1000.0))
        coordinator = task.async { shutdown.coordinate }

        shutdown.signal(:sigint)
        expect(transitions.dequeue).to eq(:grace)
        shutdown.signal(:sigint) # the second one promotes
        coordinator.wait
        shutdown.dispose
      end

      expect(returned).to eq(:never_returned)
      expect(closer.reasons).to eq(%i[interrupted])
    end
  end

  describe "wait-until-responses settles then closes" do
    it "lets the provider complete, commits the turn, closes exit, and never interrupts" do
      entered = Async::Queue.new
      release = Async::Queue.new
      journal = recording_journal
      agent = build_agent(park_on: 1, entered:, release:, journal:, responses: [text_response])
      returned = :never_returned

      Sync do |task|
        run = task.async { returned = agent.ask("hi") }
        entered.dequeue
        shutdown = build_coordinator(run_task: run, agent:, clock: clock_returning(1000.0))
        coordinator = task.async { shutdown.coordinate }

        shutdown.signal(:wait_responses) # -> draining: parks on the run's own #wait
        release.enqueue(true)            # the provider now completes the model call
        coordinator.wait
        shutdown.dispose
      end

      expect(returned).to be_a(Lain::Response)
      expect(returned.text).to eq("done")
      expect(closer.reasons).to eq(%i[exit])
      expect(agent.timeline.to_a.map(&:role)).to eq(%w[user assistant])
      expect(journal.records.size).to eq(1)
    end
  end

  describe "sigquit skips the countdown" do
    it "interrupts immediately, never arming grace, with the same closing journaling" do
      entered = Async::Queue.new
      release = Async::Queue.new
      agent = build_agent(park_on: 1, entered:, release:, responses: [text_response])
      returned = :never_returned

      Sync do |task|
        run = task.async { returned = agent.ask("hi") }
        entered.dequeue
        shutdown = build_coordinator(run_task: run, agent:, clock: clock_returning(1000.0))
        coordinator = task.async { shutdown.coordinate }

        shutdown.signal(:sigquit)
        # straight to draining -- grace was never entered
        expect(transitions.dequeue).to eq(:draining)
        expect(transitions.dequeue).to eq(:closed)
        coordinator.wait
        expect(shutdown.deadline).to be_nil
        shutdown.dispose
      end

      expect(returned).to eq(:never_returned)
      expect(closer.reasons).to eq(%i[interrupted])
    end
  end

  # Grace expiry when the deadline actually elapses on the reactor clock (not the
  # short-circuit the injected clock takes in the sigterm AC): a small real
  # window with no signal proves the fiber wakes on the reactor timer and treats
  # the timeout as expiry. Bounded tiny, so it is fast and not flaky.
  describe "the grace window elapsing in real time" do
    it "expires and interrupts when no input arrives before the deadline" do
      entered = Async::Queue.new
      release = Async::Queue.new
      agent = build_agent(park_on: 1, entered:, release:, responses: [text_response])
      returned = :never_returned

      Sync do |task|
        run = task.async { returned = agent.ask("hi") }
        entered.dequeue
        shutdown = build_coordinator(run_task: run, agent:, clock: clock_returning(1000.0), grace: 0.02)
        coordinator = task.async { shutdown.coordinate }
        shutdown.signal(:sigterm) # arms a 20ms window; nothing else arrives
        coordinator.wait
        shutdown.dispose
      end

      expect(returned).to eq(:never_returned)
      expect(closer.reasons).to eq(%i[grace_expired])
    end
  end

  describe "extend re-arms the window from NOW" do
    it "slides the deadline out from the current clock, staying in grace" do
      entered = Async::Queue.new
      release = Async::Queue.new
      agent = build_agent(park_on: 1, entered:, release:, responses: [text_response])

      Sync do |task|
        run = task.async { agent.ask("hi") }
        entered.dequeue
        # arm reads 1000 -> deadline 1060; extend reads 1030 -> deadline 1090.
        shutdown = build_coordinator(run_task: run, agent:, clock: clock_returning(1000.0, 1030.0))
        coordinator = task.async { shutdown.coordinate }

        shutdown.signal(:sigint)
        expect(transitions.dequeue).to eq(:grace)
        expect(shutdown.deadline).to eq(1060.0)

        shutdown.signal(:extend)
        expect(transitions.dequeue).to eq(:grace)
        expect(shutdown.deadline).to eq(1090.0)
        expect(shutdown.state).to eq(:grace)

        coordinator.stop
        run.stop
        shutdown.dispose
      end

      expect(closer.reasons).to be_empty
    end
  end

  describe "promote as its own input" do
    it "interrupts immediately even from running, reason interrupted" do
      entered = Async::Queue.new
      release = Async::Queue.new
      agent = build_agent(park_on: 1, entered:, release:, responses: [text_response])
      returned = :never_returned

      Sync do |task|
        run = task.async { returned = agent.ask("hi") }
        entered.dequeue
        shutdown = build_coordinator(run_task: run, agent:, clock: clock_returning(1000.0))
        coordinator = task.async { shutdown.coordinate }

        shutdown.signal(:promote)
        coordinator.wait
        shutdown.dispose
      end

      expect(returned).to eq(:never_returned)
      expect(closer.reasons).to eq(%i[interrupted])
    end
  end

  describe "a non-positive grace" do
    it "refuses zero and negative windows loudly at construction" do
      [0, -1, nil].each do |grace|
        expect do
          described_class.new(run_task: Object.new, closer:, budget: Lain::Agent::Budget.new, grace:)
        end.to raise_error(ArgumentError, /grace must be a positive Numeric/)
      end
    end
  end

  describe "wait-until-responses settles the long-lived actors" do
    it "settles each injected actor after the run's own wait, before closing" do
      entered = Async::Queue.new
      release = Async::Queue.new
      agent = build_agent(park_on: 1, entered:, release:, responses: [text_response])
      actor = Class.new do
        def initialize = @settled = false
        attr_reader :settled

        def settle
          @settled = true
          self
        end
      end.new

      Sync do |task|
        run = task.async { agent.ask("hi") }
        entered.dequeue
        shutdown = described_class.new(run_task: run, closer:, budget: agent.budget,
                                       clock: clock_returning(1000.0), actors: [actor],
                                       on_transition:)
        coordinator = task.async { shutdown.coordinate }

        shutdown.signal(:wait_responses)
        release.enqueue(true)
        coordinator.wait
        shutdown.dispose
      end

      expect(actor.settled).to be(true)
      expect(closer.reasons).to eq(%i[exit])
    end
  end

  # A T21 renderer sees state and deadline through the same notification; a
  # :draining carrying the by-then-dead grace deadline would render a countdown
  # for a window that no longer exists.
  describe "the draining notification's deadline" do
    it "is already nil when force_stop announces draining" do
      entered = Async::Queue.new
      release = Async::Queue.new
      agent = build_agent(park_on: 1, entered:, release:, responses: [text_response])
      announced = []

      Sync do |task|
        run = task.async { agent.ask("hi") }
        entered.dequeue
        shutdown = described_class.new(run_task: run, closer:, budget: agent.budget,
                                       clock: clock_returning(1000.0),
                                       on_transition: ->(state, deadline) { announced << [state, deadline] })
        coordinator = task.async { shutdown.coordinate }

        shutdown.signal(:sigint)
        shutdown.signal(:promote)
        coordinator.wait
        shutdown.dispose
      end

      expect(announced.map(&:first)).to eq(%i[grace draining closed])
      expect(announced.last(2)).to all(satisfy { |(_state, deadline)| deadline.nil? })
    end
  end

  # Dispose-safety in ANY order (panel #2): the ingress closing under a parked
  # coordinator is clean termination, never a crash -- the fiber ends without
  # fabricating a session_closed nobody caused.
  describe "dispose while the coordinator is parked" do
    it "ends the coordinator fiber cleanly, journaling nothing" do
      shutdown = nil
      Sync do |task|
        shutdown = described_class.new(run_task: Object.new, closer:,
                                       budget: Lain::Agent::Budget.new, on_transition:)
        # async is eager: the coordinator runs to its first await -- the pipe
        # park -- before this returns, so dispose provably lands on a parked read.
        coordinator = task.async { shutdown.coordinate }
        shutdown.dispose
        task.with_timeout(1) { coordinator.wait }
      end

      expect(closer.reasons).to be_empty
      expect(shutdown.state).to eq(:running)
    end
  end

  describe "clean-exit teardown (run completes, no signal ever)" do
    it "leaves no leaked fiber and no open pipe fds" do
      entered = Async::Queue.new
      release = Async::Queue.new
      agent = build_agent(park_on: 1, entered:, release:, responses: [text_response])
      shutdown = nil

      # Sync only returns once every child fiber is done, so this block
      # completing (bounded by the timeout) IS the no-leaked-fiber assertion.
      Sync do |task|
        run = task.async { agent.ask("hi") }
        entered.dequeue
        shutdown = build_coordinator(run_task: run, agent:, clock: clock_returning(1000.0))
        coordinator = task.async { shutdown.coordinate }

        release.enqueue(true)
        run.wait
        shutdown.dispose
        task.with_timeout(1) { coordinator.wait }
      end

      expect(closer.reasons).to be_empty
      expect(shutdown.disposed?).to be(true)
    end
  end

  describe "signal after dispose" do
    it "tolerates the closed pipe and returns instead of raising into a trap" do
      shutdown = described_class.new(run_task: Object.new, closer:, budget: Lain::Agent::Budget.new)
      shutdown.dispose

      expect { shutdown.signal(:sigint) }.not_to raise_error
    end
  end

  describe "the self-pipe byte protocol" do
    it "maps every accepted input to a distinct, frozen, single byte that round-trips" do
      bytes = described_class::BYTES

      expect(bytes.keys).to match_array(%i[sigint sigterm sigquit cancel extend wait_responses promote])
      expect(bytes.values).to all(satisfy { |byte| byte.bytesize == 1 && byte.frozen? })
      expect(bytes.values.uniq.size).to eq(bytes.size)
      expect(described_class::DECODE).to eq(bytes.invert)
    end

    it "signal writes without blocking or raising on a writable pipe (trap-safe)" do
      shutdown = described_class.new(run_task: Object.new, closer:, budget: Lain::Agent::Budget.new)

      expect { 100.times { shutdown.signal(:sigint) } }.not_to raise_error
      shutdown.dispose
    end
  end

  # The whole point of the self-pipe: a body running in a REAL signal trap may do
  # nothing but one async-signal-safe write, and it still drives the coordinator.
  # SIGUSR2 is saved/restored so the process is left as found. Deterministic --
  # coordinator.wait only returns once the trapped byte was decoded and acted on.
  describe "a real signal trap driving the ingress" do
    it "delivers the byte through the pipe and interrupts the run" do
      entered = Async::Queue.new
      release = Async::Queue.new
      agent = build_agent(park_on: 1, entered:, release:, responses: [text_response])
      returned = :never_returned
      previous = Signal.trap("USR2", "DEFAULT")

      begin
        Sync do |task|
          run = task.async { returned = agent.ask("hi") }
          entered.dequeue
          shutdown = build_coordinator(run_task: run, agent:, clock: clock_returning(1000.0))
          Signal.trap("USR2") { shutdown.signal(:sigquit) }
          coordinator = task.async { shutdown.coordinate }
          Process.kill("USR2", Process.pid)
          coordinator.wait
          shutdown.dispose
        end
      ensure
        Signal.trap("USR2", previous)
      end

      expect(returned).to eq(:never_returned)
      expect(closer.reasons).to eq(%i[interrupted])
    end
  end
end
