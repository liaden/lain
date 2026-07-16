# frozen_string_literal: true

require "timeout"

# T22: the per-ask supervision conductor. It co-locates the run task, a
# {Lain::CLI::Shutdown} coordinator, and the countdown ticker in ONE reactor (so
# Budget#interrupt stops a task on its own reactor -- never cross-thread), routes
# OS signals to that coordinator for the ask's duration, drives the TTY countdown,
# and reports whether the session closed. Its own {#close} is the guarded closer
# both the coordinator and chat's normal-exit ensure share.
#
# Driven with REAL signals delivered to self (the T20 SIGUSR2 idiom): a parking
# provider makes the reactor provably inside a model call, and an injected clock
# makes grace expiry synchronous, so no example races a real 60s window.
RSpec.describe Lain::CLI::Conductor do
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }

  # Records the session-record calls in order, so an example can pin the
  # catch_up -> interrupted -> close ordering the B5 amendment fixed.
  let(:chronicle) do
    Class.new do
      def initialize = @events = []
      attr_reader :events

      def catch_up(_timeline) = tap { @events << :catch_up }
      def interrupted(head:) = tap { @events << [:interrupted, head] }
      def close(reason:) = tap { @events << [:close, reason] }
    end.new
  end

  # The ticker's target. render_countdown pushes onto a queue so an example can
  # synchronize on "the countdown has rendered at least once" without a sleep.
  let(:tty) do
    Class.new do
      def initialize
        @renders = []
        @stops = 0
        @rendered = Async::Queue.new
      end
      attr_reader :renders, :stops, :rendered

      def render_countdown(deadline:, **)
        @renders << deadline
        @rendered.enqueue(deadline)
        self
      end

      def stop_countdown = tap { @stops += 1 }
    end.new
  end

  around do |example|
    saved = Lain::CLI::Signals::MAP.keys.to_h { |name| [name, Signal.trap(name, "DEFAULT")] }
    example.run
  ensure
    saved.each { |name, handler| Signal.trap(name, handler) }
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

  def clock_returning(*values)
    seq = values.dup
    -> { seq.size > 1 ? seq.shift : seq.first }
  end

  def build_agent(entered:, release:, responses:)
    Lain::Agent.new(provider: ParkProvider.new(entered:, release:, responses:), toolset:, context:)
  end

  def build_conductor(grace:, clock:, signals:, tick: 0.005)
    described_class.new(tty:, chronicle:, signals:, grace:, clock:, tick:, budget: Lain::Agent::Budget.new)
  end

  # Delivers `os_name` once the run is provably parked, then lets the supervised
  # ask settle. Returns the Outcome.
  def supervise_and_signal(agent:, conductor:, entered:, os_name:)
    outcome = nil
    Sync do |task|
      driver = task.async do
        entered.dequeue
        Process.kill(os_name, Process.pid)
      end
      outcome = conductor.supervise(task, -> { agent.timeline }) { agent.ask("hi") }
      driver.wait
    end
    outcome
  end

  describe "SIGTERM, grace expiry" do
    it "interrupts the run, closes grace_expired, and records catch_up->interrupted->close in order" do
      entered = Async::Queue.new
      release = Async::Queue.new
      agent = build_agent(entered:, release:, responses: [text_response])
      # arm reads 1000 -> deadline 1060; the next poll reads 1061 -> expired at once.
      signals = Lain::CLI::Signals.new.install
      conductor = build_conductor(grace: 60, clock: clock_returning(1000.0, 1061.0), signals:)

      outcome = supervise_and_signal(agent:, conductor:, entered:, os_name: "TERM")

      expect(outcome.closed?).to be(true)
      expect(outcome.response).to be_nil
      head = agent.timeline.head_digest
      expect(chronicle.events).to eq([:catch_up, [:interrupted, head], %i[close grace_expired]])
      expect(tty.stops).to be >= 1
    ensure
      signals.uninstall
    end
  end

  describe "SIGQUIT, immediate" do
    it "interrupts at once and closes interrupted, skipping the grace window" do
      entered = Async::Queue.new
      release = Async::Queue.new
      agent = build_agent(entered:, release:, responses: [text_response])
      signals = Lain::CLI::Signals.new.install
      conductor = build_conductor(grace: 60, clock: clock_returning(1000.0), signals:)

      outcome = supervise_and_signal(agent:, conductor:, entered:, os_name: "QUIT")

      expect(outcome.closed?).to be(true)
      head = agent.timeline.head_digest
      expect(chronicle.events).to eq([:catch_up, [:interrupted, head], %i[close interrupted]])
    ensure
      signals.uninstall
    end
  end

  describe "double SIGINT inside the window" do
    it "promotes to an immediate interrupt, closing interrupted" do
      entered = Async::Queue.new
      release = Async::Queue.new
      agent = build_agent(entered:, release:, responses: [text_response])
      signals = Lain::CLI::Signals.new.install
      # A constant clock: the window never expires on its own, so the SECOND
      # sigint (buffered in the pipe behind the first) is provably what promotes.
      conductor = build_conductor(grace: 60, clock: clock_returning(1000.0), signals:)
      outcome = nil

      Sync do |task|
        driver = task.async do
          entered.dequeue
          2.times { Process.kill("INT", Process.pid) }
        end
        outcome = conductor.supervise(task, -> { agent.timeline }) { agent.ask("hi") }
        driver.wait
      end

      expect(outcome.closed?).to be(true)
      expect(chronicle.events.last).to eq(%i[close interrupted])
    ensure
      signals.uninstall
    end
  end

  describe "a clean ask with no signal" do
    it "returns the response, does not close (chat's ensure owns :exit), and routes signals back to Null" do
      entered = Async::Queue.new
      release = Async::Queue.new
      agent = build_agent(entered:, release:, responses: [text_response])
      signals = Lain::CLI::Signals.new.install
      conductor = build_conductor(grace: 60, clock: clock_returning(1000.0), signals:)
      outcome = nil

      Sync do |task|
        driver = task.async do
          entered.dequeue
          release.enqueue(true)
        end
        outcome = conductor.supervise(task, -> { agent.timeline }) { agent.ask("hi") }
        driver.wait
      end

      expect(outcome.response).to be_a(Lain::Response)
      expect(outcome.closed?).to be(false)
      expect(chronicle.events).to be_empty
      # Routed back to Null: a signal now is dropped, not delivered to the retired coordinator.
      expect { Process.kill("TERM", Process.pid) }.not_to raise_error
    ensure
      signals.uninstall
    end
  end

  describe "the countdown ticker" do
    it "renders the grace window on the TTY while it is open, then stops it" do
      entered = Async::Queue.new
      release = Async::Queue.new
      agent = build_agent(entered:, release:, responses: [text_response])
      signals = Lain::CLI::Signals.new.install
      # A real, long window so it never expires mid-example; the run finishing is
      # what ends the ask, and the ticker renders throughout.
      conductor = build_conductor(grace: 60, clock: clock_returning(1000.0), signals:)

      Sync do |task|
        driver = task.async do
          entered.dequeue
          Process.kill("TERM", Process.pid) # arm grace
          tty.rendered.dequeue               # the countdown has rendered at least once
          release.enqueue(true)              # let the run finish -> ends the ask
        end
        conductor.supervise(task, -> { agent.timeline }) { agent.ask("hi") }
        driver.wait
      end

      expect(tty.renders).not_to be_empty
      expect(tty.renders).to all(eq(1060.0))
      expect(tty.stops).to be >= 1
    ensure
      signals.uninstall
    end
  end

  describe "read_prompt at an idle prompt" do
    it "breaks the prompt out on a signal and closes the session :exit, returning nil" do
      signals = Lain::CLI::Signals.new.install
      conductor = build_conductor(grace: 60, clock: clock_returning(1000.0), signals:)
      entered = Thread::Queue.new
      # A tty whose #prompt blocks the calling thread, standing in for Reline's
      # blocking read; the breaker raises the reader out of it.
      blocking_tty = Class.new do
        def initialize(entered) = @entered = entered

        def prompt(_text)
          @entered << true
          sleep
        end
      end.new(entered)

      killer = Thread.new do
        entered.pop
        Process.kill("TERM", Process.pid)
      end
      line = conductor.read_prompt(blocking_tty, "you> ")
      killer.join

      expect(line).to be_nil
      expect(conductor).to be_closed
      # No run was interrupted at an idle prompt: a clean session_closed, no
      # run_interrupted, no catch_up (no ask ever set a timeline).
      expect(chronicle.events).to eq([%i[close exit]])
    ensure
      signals.uninstall
    end

    it "returns the typed line and leaves the session open when no signal arrives" do
      signals = Lain::CLI::Signals.new
      conductor = build_conductor(grace: 60, clock: clock_returning(1000.0), signals:)
      plain_tty = Class.new do
        def prompt(_text) = "hello"
      end.new

      expect(conductor.read_prompt(plain_tty, "you> ")).to eq("hello")
      expect(conductor).not_to be_closed
      expect(chronicle.events).to be_empty
    end

    # The ensure-race the review panel flagged: a Break can surface not during
    # the read but during the cleanup's dispose->join. Stubbing dispose to raise
    # Break pins that the INNER begin/ensure feeds it to the OUTER rescue, so it
    # closes cleanly instead of escaping as a backtrace + nonzero exit.
    it "catches a Break raised during dispose and still closes cleanly, not propagating" do
      breaker = instance_double(Lain::CLI::PromptBreaker, signal: nil)
      allow(breaker).to receive(:dispose).and_raise(Lain::CLI::PromptBreaker::Break.new(:sigterm))
      allow(Lain::CLI::PromptBreaker).to receive(:new).and_return(breaker)
      conductor = build_conductor(grace: 60, clock: clock_returning(1000.0), signals: Lain::CLI::Signals.new)
      plain_tty = Class.new { def prompt(_text) = "hi" }.new
      line = :unset

      expect { line = conductor.read_prompt(plain_tty, "you> ") }.not_to raise_error

      expect(line).to be_nil
      expect(conductor).to be_closed
      expect(chronicle.events).to eq([%i[close exit]])
    end
  end

  describe "#guard" do
    it "installs traps for the block and restores the prior handlers after, even when the block raises" do
      sentinel = ->(_signo) {}
      Signal.trap("INT", sentinel)
      conductor = build_conductor(grace: 60, clock: clock_returning(1000.0), signals: Lain::CLI::Signals.new)

      expect { conductor.guard { raise "boom" } }.to raise_error("boom")

      # Trapping again returns the handler currently in force -- proof the
      # sentinel installed before #guard is back, via the same install/uninstall
      # path Signals.guarding uses (Conductor#guard delegates to it).
      expect(Signal.trap("INT", "DEFAULT")).to be(sentinel)
    end

    it "routes a real signal to the injected Signals instance while the block runs" do
      signals = Lain::CLI::Signals.new
      conductor = build_conductor(grace: 60, clock: clock_returning(1000.0), signals:)
      sink = Class.new do
        def initialize = @received = []
        attr_reader :received

        def signal(name) = @received << name
      end.new

      conductor.guard do
        signals.route(sink)
        Process.kill("INT", Process.pid)
        Timeout.timeout(2) { sleep(0.001) until sink.received.size == 1 }
      end

      expect(sink.received).to eq([:sigint])
    end
  end

  describe "the guarded closer" do
    it "writes session_closed once, so a signal-close and a later close(:exit) do not double up" do
      entered = Async::Queue.new
      release = Async::Queue.new
      agent = build_agent(entered:, release:, responses: [text_response])
      signals = Lain::CLI::Signals.new.install
      conductor = build_conductor(grace: 60, clock: clock_returning(1000.0, 1061.0), signals:)

      supervise_and_signal(agent:, conductor:, entered:, os_name: "TERM")
      conductor.close(reason: :exit) # chat's ensure -- must be a no-op now

      expect(chronicle.events.count { |e| e.is_a?(Array) && e.first == :close }).to eq(1)
      expect(conductor).to be_closed
    ensure
      signals.uninstall
    end

    it "on a plain exit (no ask ever supervised) closes without catch_up or interrupted" do
      conductor = build_conductor(grace: 60, clock: clock_returning(1000.0), signals: Lain::CLI::Signals.new)

      conductor.close(reason: :exit)

      expect(chronicle.events).to eq([%i[close exit]])
    end
  end

  # FB (interrupt-readline UX fix): while an ask_human reply is outstanding, Reline
  # owns stdin -- so the countdown ticker must NEITHER render its status line NOR
  # make its non-blocking key read (which would otherwise STEAL a keystroke out of
  # the operator's typed answer, e.g. an 'r' silently firing :wait_responses). The
  # grace clock still runs and a terminating signal still arms/expires/promotes;
  # only the ticker's render+read are suppressed, resuming from the next tick once
  # the reply returns. #read_reply is the seam that flips the conductor-owned
  # suppression flag (single writer, checked by the ticker each tick).
  describe "countdown suppression while a reply is outstanding" do
    def grace_shutdown(deadline: 1060.0)
      Struct.new(:state, :deadline).new(:grace, deadline)
    end

    # A tty-shaped input the countdown would read from: a real terminal duck
    # (tty?/raw!/console_mode) feeding successive bytes of `answer`, then EAGAIN.
    let(:key_reader_class) do
      Class.new do
        def initialize(answer)
          @bytes = answer.chars
          @reads = 0
        end
        attr_reader :reads

        def tty? = true
        def raw!(**) = nil
        def console_mode = :saved

        def console_mode=(_mode)
          nil
        end

        def read_nonblock(_size)
          @reads += 1
          @bytes.empty? ? raise(IO::EAGAINWaitReadable) : @bytes.shift
        end

        def remaining = @bytes.join
      end
    end

    def key_reader(answer) = key_reader_class.new(answer)

    def grace_coordinator
      Class.new do
        def initialize = @signals = []
        attr_reader :signals

        def state = :grace
        def deadline = 1060.0
        def signal(action) = @signals << action
      end.new
    end

    # A real Frontend::TTY over `input` so the stolen-keystroke path is the actual
    # Countdown#read_nonblock, not a stub -- output is a tty-presenting sink.
    def real_tty(input:)
      sink = Class.new do
        def tty? = true
        def print(*) = nil
        def puts(*) = nil
        def flush = nil
      end.new
      Lain::Frontend::TTY.new(channel: Lain::Channel.new, input:, output: sink,
                              pastel: Pastel.new(enabled: false),
                              history_path: File.join(Dir.mktmpdir, "history"), clock: -> { 1000.0 })
    end

    it "renders nothing while suppressed, then resumes from the next tick after release" do
      suppressed = true
      ticker = Lain::CLI::Conductor::CountdownTicker.new(tty:, tick: 0.001, suppressed: -> { suppressed })

      Sync do |task|
        runner = task.async { ticker.run(grace_shutdown, task) }
        task.sleep(0.02) # many ticks elapse, all suppressed
        expect(tty.renders).to be_empty
        suppressed = false
        expect(tty.rendered.dequeue).to eq(1060.0) # the very next tick renders
        runner.stop
      end
    end

    it "does not read (steal) a reply keystroke while suppressed" do
      key_input = key_reader("ready")
      coordinator = grace_coordinator
      ticker = Lain::CLI::Conductor::CountdownTicker.new(tty: real_tty(input: key_input),
                                                         tick: 0.001, suppressed: -> { true })

      Sync do |task|
        runner = task.async { ticker.run(coordinator, task) }
        task.sleep(0.02)
        runner.stop
      end

      expect(key_input.reads).to eq(0)
      expect(coordinator.signals).to be_empty
      expect(key_input.remaining).to eq("ready")
    end

    # The theft the suppression prevents, pinned as a characterization: an
    # UNsuppressed tick reads the answer's first byte ('r') and fires
    # :wait_responses -- exactly the seam #read_reply exists to close.
    it "characterizes the theft: an unsuppressed tick steals the leading 'r'" do
      key_input = key_reader("ready")
      coordinator = grace_coordinator
      ticker = Lain::CLI::Conductor::CountdownTicker.new(tty: real_tty(input: key_input),
                                                         tick: 0.001, suppressed: -> { false })

      Sync do |task|
        runner = task.async { ticker.run(coordinator, task) }
        task.sleep(0.02)
        runner.stop
      end

      expect(coordinator.signals).to include(:wait_responses)
      expect(key_input.remaining).not_to eq("ready")
    end
  end

  # The expiry-during-reply path (the PTY probe in the handback is the evidence
  # for the terminal-restore half; this pins the reason + suppression under the
  # supervised reactor). A run parks inside the model call while a reply is
  # outstanding at human>; a SIGTERM arms grace, the jumped clock expires it, and
  # the coordinator interrupts the run and closes grace_expired -- with the ticker
  # suppressed the whole window, so no status line ever smears over Reline.
  describe "grace expiry while a reply is outstanding at human>" do
    it "still interrupts the run and closes grace_expired, rendering no countdown" do
      entered = Async::Queue.new
      release = Async::Queue.new
      agent = build_agent(entered:, release:, responses: [text_response])
      signals = Lain::CLI::Signals.new.install
      conductor = build_conductor(grace: 60, clock: clock_returning(1000.0, 1061.0), signals:)
      reply_parked = Async::Queue.new
      blocking_tty = Class.new do
        def initialize(parked) = @parked = parked

        def prompt(_text)
          @parked.enqueue(true)
          sleep # park the replier as Reline's blocking read would
        end
      end.new(reply_parked)
      outcome = nil

      Sync do |task|
        replier = task.async { conductor.read_reply(blocking_tty, "human> ") }
        driver = task.async do
          entered.dequeue # the run is provably inside the model call
          reply_parked.dequeue # the reply is provably parked
          Process.kill("TERM", Process.pid) # arm grace; the jumped clock expires it
        end
        outcome = conductor.supervise(task, -> { agent.timeline }) { agent.ask("hi") }
        replier.stop
        driver.wait
      end

      expect(outcome.closed?).to be(true)
      expect(chronicle.events.last).to eq(%i[close grace_expired])
      expect(tty.renders).to be_empty
    ensure
      signals.uninstall
    end
  end
end
