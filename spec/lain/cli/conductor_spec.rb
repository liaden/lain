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
end
