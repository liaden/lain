# frozen_string_literal: true

require "timeout"

# The per-ask supervision conductor. It co-locates the run task, a
# {Lain::CLI::Shutdown} coordinator, and the countdown ticker in ONE reactor (so
# Budget#interrupt stops a task on its own reactor -- never cross-thread), routes
# OS signals to that coordinator for the ask's duration, drives the TTY countdown,
# and reports whether the session closed. Its own {#close} is the guarded closer
# both the coordinator and chat's normal-exit ensure share.
#
# Driven with REAL signals delivered to self (the SIGUSR2 idiom): a parking
# provider makes the reactor provably inside a model call, and an injected clock
# makes grace expiry synchronous, so no example races a real 60s window.
RSpec.describe Lain::CLI::Conductor do
  let(:toolset) { Lain::Toolset.new([EchoTool.new]) }
  let(:context) { Lain::Context.new(model: "claude-opus-4-8", max_tokens: 1024) }

  # Records the session-record calls in order, so an example can pin the
  # catch_up -> interrupted -> close ordering a later amendment fixed.
  let(:chronicle) do
    Class.new do
      def initialize = @events = []
      attr_reader :events

      def catch_up(_timeline) = tap { @events << :catch_up }
      def interrupted(head:, reason:) = tap { @events << [:interrupted, head, reason] }
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

      # Whether a line editor still holds the terminal, which the countdown
      # waits out; a spec that draws nothing leaves it false.
      attr_accessor :drawn

      def prompt_drawn? = drawn || false
    end.new
  end

  # Where the conductor's reads take their lines from.
  let(:rail) { Lain::Frontend::InputRail.new }

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

  def build_conductor(grace:, clock:, signals:, tick: 0.005, run_clock: Lain::RunClock.new)
    described_class.new(tty:, chronicle:, signals:, rail:, grace:, clock:, tick:, budget: Lain::Agent::Budget.new,
                        run_clock:)
  end

  # A human at the rail, on a thread of their own because an idle prompt is read
  # with no reactor under it: each line typed at the next prompt published, and
  # a nil the stream ending there.
  def human_typing(*lines)
    Thread.new do
      lines.each do |text|
        sleep(0.002) until rail.published.generation.positive?
        prompt = rail.published
        rail << typed(text, prompt)
        sleep(0.002) while rail.open?(prompt)
      end
    end
  end

  def typed(text, prompt)
    return Lain::Frontend::InputRail::Eof.new if text.nil?

    Lain::Frontend::InputRail::Line.new(text:, generation: prompt.generation)
  end

  # Waits, on the reactor, for a prompt of `kind` and types `text` at it.
  def typed_at(task, kind, text)
    pumped_until(task, reason: "a #{kind} prompt published") { rail.published.kind == kind }
    rail << Lain::Frontend::InputRail::Line.new(text:, generation: rail.published.generation)
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
      expect(chronicle.events)
        .to eq([:catch_up, [:interrupted, head, :grace_expired], %i[close grace_expired]])
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
      expect(chronicle.events)
        .to eq([:catch_up, [:interrupted, head, :interrupted], %i[close interrupted]])
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

  # A producer on the rail -- an input pane, one day -- has no process to send
  # an OS signal from, so its signal is routed exactly where the traps are.
  describe "a signal put on the input rail during an ask" do
    it "reaches the coordinator as the OS signal would, and nothing once the ask settles" do
      entered = Async::Queue.new
      release = Async::Queue.new
      agent = build_agent(entered:, release:, responses: [text_response])
      conductor = build_conductor(grace: 60, clock: -> { 1000.0 }, signals: Lain::CLI::Signals.new)
      armed = nil

      Sync do |task|
        driver = task.async do
          entered.dequeue
          rail << Lain::Frontend::InputRail::Signal.new(name: :sigint)
          pumped_until(task, reason: "the countdown armed") { conductor.counting_down? }
          armed = true
          rail << Lain::Frontend::InputRail::Signal.new(name: :cancel)
          release.enqueue(true)
        end
        conductor.supervise(task, -> { agent.timeline }) { agent.ask("hi") }
        driver.wait
      end
      rail << Lain::Frontend::InputRail::Signal.new(name: :sigint)

      expect([armed, conductor.closed?]).to eq([true, false])
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
      # Nothing feeds the rail, so the read waits as it would on a human who
      # types nothing; the breaker raises the reader out of that wait.
      killer = Thread.new do
        sleep(0.002) until rail.published.generation.positive?
        Process.kill("TERM", Process.pid)
      end
      line = conductor.read_prompt("you> ")
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
      human_typing("hello")

      expect(conductor.read_prompt("you> ")).to eq("hello")
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
      human_typing("hi")
      line = :unset

      expect { line = conductor.read_prompt("you> ") }.not_to raise_error

      expect(line).to be_nil
      expect(conductor).to be_closed
      expect(chronicle.events).to eq([%i[close exit]])
    end
  end

  # Conductor is the one place a user prompt is answered, so #read_prompt
  # is the run clock's one write site -- a signal-ended (Break) or EOF (nil)
  # prompt is NOT user input and must not record.
  describe "the run clock's one write site" do
    def build_with_run_clock(run_clock:, signals: Lain::CLI::Signals.new)
      build_conductor(grace: 60, clock: clock_returning(1000.0), signals:, run_clock:)
    end

    it "records input when a real line is read" do
      run_clock = instance_double(Lain::RunClock, record_input: nil)
      conductor = build_with_run_clock(run_clock:)
      human_typing("hello")

      conductor.read_prompt("you> ")

      expect(run_clock).to have_received(:record_input)
    end

    it "does not record on a nil (EOF) return" do
      run_clock = instance_double(Lain::RunClock, record_input: nil)
      conductor = build_with_run_clock(run_clock:)
      human_typing(nil)

      conductor.read_prompt("you> ")

      expect(run_clock).not_to have_received(:record_input)
    end

    it "does not record when the prompt breaks on a signal (PromptBreaker::Break)" do
      run_clock = instance_double(Lain::RunClock, record_input: nil)
      signals = Lain::CLI::Signals.new.install
      conductor = build_with_run_clock(run_clock:, signals:)
      killer = Thread.new do
        sleep(0.002) until rail.published.generation.positive?
        Process.kill("TERM", Process.pid)
      end

      conductor.read_prompt("you> ")
      killer.join

      expect(run_clock).not_to have_received(:record_input)
    ensure
      signals.uninstall
    end

    it "answering a prompt resets a REAL RunClock's idle measure (the AC, end to end)" do
      now = 1000.0
      run_clock = Lain::RunClock.new(clock: -> { now })
      conductor = build_with_run_clock(run_clock:)
      human_typing("hello")

      conductor.read_prompt("you> ")
      now = 1030.0

      expect(run_clock.idle).to eq(30.0)
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

    # MEASURED, not deduced: `PromptBreaker` delivers with `Thread#raise`, and
    # under a fiber scheduler that lands at the SCHEDULER's checkpoint rather
    # than inside the fiber sitting in the prompt read. On async 2.42.0 the
    # Break surfaced at `Repl#run`'s `Sync` boundary -- past `#read_prompt`'s
    # rescue entirely -- so `lain chat` died OF SIGNAL 2 with a backtrace where
    # it meant to exit 0, and `lain up`'s `remain-on-exit failed` then held the
    # corpse: a chat pane that would not go away, and a tmux session that would
    # not either.
    #
    # A Break exists only while a breaker is routed, so one arriving ANYWHERE
    # means "the human interrupted an idle prompt". Where it lands is a
    # scheduler detail that has already changed once.
    it "closes cleanly on a Break that surfaced above #read_prompt, rather than propagating" do
      conductor = build_conductor(grace: 60, clock: clock_returning(1000.0), signals: Lain::CLI::Signals.new)
      answer = :unset

      expect { answer = conductor.guard { raise Lain::CLI::PromptBreaker::Break, :sigint } }.not_to raise_error

      expect(answer).to be_nil
      expect(conductor).to be_closed
      expect(chronicle.events).to eq([%i[close exit]])
    end

    # The two rescues cannot double-close, which is what makes rescuing in both
    # places safe rather than merely redundant.
    it "does not write a second session_closed when #read_prompt already closed" do
      conductor = build_conductor(grace: 60, clock: clock_returning(1000.0), signals: Lain::CLI::Signals.new)
      conductor.close(reason: :exit)

      conductor.guard { raise Lain::CLI::PromptBreaker::Break, :sigint }

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

  # A signal closes the session record DURING the conversation, and the fleet is
  # only stopped later, as the conversation's own scope unwinds. Every farewell
  # writes -- a lease release, a crashed row's reap, an actor's last message -- so
  # the fleet has to be stopped while the record is still open.
  describe "a signal close with an adopted fleet" do
    let(:session_io) { StringIO.new }
    let(:session_file) { Lain::Journal.new(io: session_io) }
    let(:chronicle) do
      Lain::CLI::Chronicle.new(journal: session_file).start(context:, toolset:)
    end
    let(:supervisor) do
      Lain::Supervisor.new(journal: session_file,
                           isolation: Lain::Isolation::Journal.new(backend: Lain::Isolation::Null.new,
                                                                   journal: session_file))
    end
    let(:worker_class) do
      Class.new do
        attr_reader :session

        def initialize(worker_env)
          @session = Lain::Session.new(worker_env:)
          @stopped = false
        end

        def settle = self

        def stop = tap { @stopped = true }

        def stopped? = @stopped

        def dead? = @stopped
      end
    end

    def types = session_io.string.each_line.map { |line| JSON.parse(line)["type"] }

    # The conversation scope's own stop, as a chat unwinds after the signal. A
    # raise is answered rather than propagated, and the reactor's children are
    # cancelled with it: a raise leaving a Sync that still has a live child task
    # hangs the Sync, and a red run should report, not hang.
    def unwind(supervisor, task)
      supervisor.stop
      nil
    rescue StandardError => e
      task.children&.each(&:stop)
      e
    end

    it "writes the fleet's lease release before the record closes, and leaves no supervisor task running" do
      entered = Async::Queue.new
      agent = build_agent(entered:, release: Async::Queue.new, responses: [text_response])
      signals = Lain::CLI::Signals.new.install
      conductor = described_class.new(tty:, chronicle:, signals:, grace: 60, clock: clock_returning(1000.0),
                                      tick: 0.005, supervisor:)
      unwound = nil

      Sync do |task|
        supervisor.run(task)
        supervisor.adopt(role: "researcher") { |worker_env| worker_class.new(worker_env) }
        supervise_and_signal(agent:, conductor:, entered:, os_name: "QUIT")
      ensure
        unwound = unwind(supervisor, task)
      end

      expect(unwound).to be_nil
      expect(supervisor).not_to be_running
      expect(types.grep(/\A(isolation_lease|session_closed)\z/))
        .to eq(%w[isolation_lease isolation_lease session_closed])
    ensure
      signals.uninstall
    end

    # A farewell can raise -- a worktree release git refuses -- and the record
    # must still close, or a clean quit reads as a torn run.
    it "still closes the record when stopping the fleet raises, and lets the raise through" do
      refusing = Object.new
      refusing.define_singleton_method(:stop) { raise Lain::Error, "git worktree remove refused" }
      conductor = described_class.new(tty:, chronicle:, signals: Lain::CLI::Signals.new, grace: 60,
                                      clock: clock_returning(1000.0), supervisor: refusing)

      expect { conductor.close(reason: :exit) }.to raise_error(Lain::Error, /refused/)
      expect(types).to include("session_closed")
    end
  end

  # FB (interrupt-readline UX fix): while an ask_human reply is outstanding, Reline
  # owns stdin -- so the countdown ticker must NEITHER render its status line NOR
  # make its non-blocking key read (which would otherwise STEAL a keystroke out of
  # the operator's typed answer, e.g. an 'r' silently firing :wait_responses). The
  # The countdown owns the terminal while it runs -- its status line and its
  # key read -- so it draws only once no line editor holds the terminal. What
  # makes that moment come is the reads themselves stepping aside (below).
  describe "the countdown ticker and a drawn prompt" do
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

    it "renders nothing while a prompt is drawn, then from the next tick once it has gone" do
      tty.drawn = true
      ticker = Lain::CLI::Conductor::CountdownTicker.new(tty:, tick: 0.001)

      Sync do |task|
        runner = task.async { ticker.run(grace_shutdown, task) }
        task.sleep(0.02) # many ticks elapse with the editor still holding the terminal
        expect(tty.renders).to be_empty
        tty.drawn = false
        expect(tty.rendered.dequeue).to eq(1060.0)
        runner.stop
      end
    end

    it "does not read (steal) a keystroke while a prompt is drawn" do
      key_input = key_reader("ready")
      coordinator = grace_coordinator
      terminal = real_tty(input: key_input)
      ticker = Lain::CLI::Conductor::CountdownTicker.new(tty: terminal, tick: 0.001)

      Sync do |task|
        drawn = task.async { terminal.drawing(-> { true }) { task.sleep(0.05) } }
        runner = task.async { ticker.run(coordinator, task) }
        task.sleep(0.02)
        runner.stop
        drawn.stop
      end

      expect(key_input.reads).to eq(0)
      expect(coordinator.signals).to be_empty
      expect(key_input.remaining).to eq("ready")
    end

    # The theft waiting prevents, pinned as a characterization: a tick with no
    # prompt drawn reads the answer's first byte ('r') and fires :wait_responses.
    it "characterizes the theft: a tick beside nothing drawn takes the leading 'r'" do
      key_input = key_reader("ready")
      coordinator = grace_coordinator
      ticker = Lain::CLI::Conductor::CountdownTicker.new(tty: real_tty(input: key_input), tick: 0.001)

      Sync do |task|
        runner = task.async { ticker.run(coordinator, task) }
        task.sleep(0.02)
        runner.stop
      end

      expect(coordinator.signals).to include(:wait_responses)
      expect(key_input.remaining).not_to eq("ready")
    end
  end

  # A Ctrl-C at `human>` opens the countdown, and the countdown needs the
  # terminal the prompt holds. So an open answer or command read STEPS ASIDE:
  # its prompt is withdrawn while the countdown runs -- whatever was half typed
  # there is gone -- and it is published again, empty, once the countdown is
  # cancelled.
  describe "a read open when the countdown starts" do
    def signalled_grace(task, conductor)
      Process.kill("TERM", Process.pid) # arm grace; the constant clock never expires it
      pumped_until(task, reason: "the countdown armed") { conductor.counting_down? }
    end

    it "withdraws its prompt so the countdown draws, and asks again once the countdown is cancelled" do
      entered = Async::Queue.new
      release = Async::Queue.new
      agent = build_agent(entered:, release:, responses: [text_response])
      signals = Lain::CLI::Signals.new.install
      conductor = build_conductor(grace: 60, clock: -> { 1000.0 }, signals:)
      answer = withdrawn = nil

      Sync do |task|
        question = task.async { conductor.read_reply("human> ") }
        driver = task.async do
          entered.dequeue
          pumped_until(task, reason: "human> published") { rail.published.kind == :human }
          signalled_grace(task, conductor)
          task.with_timeout(2) { tty.rendered.dequeue }
          pumped_until(task, reason: "the read stepped aside") { rail.published.kind.nil? }
          withdrawn = rail.published.kind
          rail << Lain::Frontend::InputRail::Signal.new(name: :cancel)
          typed_at(task, :human, "postgres")
          answer = question.wait
          release.enqueue(true)
        end
        conductor.supervise(task, -> { agent.timeline }) { agent.ask("hi") }
        driver.wait
      end

      expect([withdrawn, answer]).to eq([nil, "postgres"])
    ensure
      signals.uninstall
    end

    it "does the same for the chat's command read" do
      entered = Async::Queue.new
      release = Async::Queue.new
      agent = build_agent(entered:, release:, responses: [text_response])
      signals = Lain::CLI::Signals.new.install
      conductor = build_conductor(grace: 60, clock: -> { 1000.0 }, signals:)
      line = withdrawn = nil

      Sync do |task|
        command = task.async { conductor.read_command("command> ") }
        driver = task.async do
          entered.dequeue
          pumped_until(task, reason: "command> published") { rail.published.kind == :command }
          signalled_grace(task, conductor)
          task.with_timeout(2) { tty.rendered.dequeue }
          pumped_until(task, reason: "the read stepped aside") { rail.published.kind.nil? }
          withdrawn = rail.published.kind
          rail << Lain::Frontend::InputRail::Signal.new(name: :cancel)
          typed_at(task, :command, "/approve")
          line = command.wait
          release.enqueue(true)
        end
        conductor.supervise(task, -> { agent.timeline }) { agent.ask("hi") }
        driver.wait
      end

      expect([withdrawn, line]).to eq([nil, "/approve"])
    ensure
      signals.uninstall
    end
  end

  # An answer can take the terminal from an idle `you>` (a parked call's
  # `[y/N]`), and a Ctrl-C there is a Ctrl-C at a question: the countdown opens
  # and the question steps aside, as at `human>`, rather than the prompt being
  # broken and the chat closed. At `you>` itself it still breaks the prompt.
  describe "a signal while an answer stands in front of an idle you>" do
    it "opens the countdown, and a cancel gives the answer's prompt back" do
      signals = Lain::CLI::Signals.new.install
      conductor = build_conductor(grace: 60, clock: -> { 1000.0 }, signals:)
      rail.attach(Struct.new(:none) do
        def sweep = nil
        def untouched?(_prompt) = true
      end.new(nil))
      answer = line = nil

      Sync do |task|
        you = task.async { line = conductor.read_prompt("you> ") }
        pumped_until(task, reason: "you> published") { rail.published.kind == :you }
        asked = Class.new(String) { def kind = :approval }.new("[y/N] ")
        approval = task.async { answer = conductor.read_reply(asked) }
        pumped_until(task, reason: "the [y/N] preempted you>") { rail.published.kind == :approval }
        Process.kill("INT", Process.pid)
        pumped_until(task, reason: "the countdown armed") { conductor.counting_down? }
        task.with_timeout(2) { tty.rendered.dequeue }
        pumped_until(task, reason: "the [y/N] stepped aside") { rail.published.kind.nil? }
        rail << Lain::Frontend::InputRail::Signal.new(name: :cancel)
        typed_at(task, :approval, "n")
        approval.wait
        typed_at(task, :you, "hello")
        you.wait
      end

      expect([answer, line, conductor.closed?]).to eq(["n", "hello", false])
    ensure
      signals.uninstall
    end
  end

  # A Ctrl-C is never lost. The trap records the signal and the prompt
  # generation it arrived at; a fiber routes it against what is drawn when it is
  # handled. A Break raised into a `you>` read that is at that instant being
  # stopped for a prompt taking the terminal is absorbed by that stop, so the
  # delivery is confirmed and an absorbed one goes to the countdown instead.
  describe "a signal whose Break is absorbed" do
    it "reaches the countdown rather than being lost" do
      # A breaker that absorbs the Break, as a stop of the read it is raised into does.
      absorbed = []
      inert = Class.new do
        def initialize(absorbed) = @absorbed = absorbed
        def signal(name) = @absorbed << name
        def dispose = nil
      end.new(absorbed)
      allow(Lain::CLI::PromptBreaker).to receive(:new).and_return(inert)
      conductor = build_conductor(grace: 60, clock: -> { 1000.0 }, signals: Lain::CLI::Signals.new)

      Sync do |task|
        you = task.async { conductor.read_prompt("you> ") }
        pumped_until(task, reason: "you> published") { rail.published.kind == :you }
        rail << Lain::Frontend::InputRail::Signal.new(name: :sigint)
        pumped_until(task, reason: "the countdown armed", timeout: 10) { conductor.counting_down? }

        expect(absorbed).to eq([:sigint])
        you.stop
      end
    end
  end

  # A countdown that expires closes the session, and the reads it moved aside
  # must not come back: a `[y/N]` drawn after the close is a question on a
  # screen the chat has finished with, and nobody is left to answer it.
  describe "a read once the session has closed" do
    it "draws no prompt, and waits to be stopped with the surface it belongs to" do
      conductor = build_conductor(grace: 60, clock: clock_returning(1000.0), signals: Lain::CLI::Signals.new)
      conductor.close(reason: :exit)

      Sync do |task|
        reply = task.async { conductor.read_reply("[y/N] ") }
        settle_for(task, 0.15)

        expect(rail.published.kind).to be_nil
        reply.stop
      end
    end
  end

  # The ticker asks the terminal whether a prompt is drawn on every tick. A
  # terminal that cannot answer used to kill the ticker inside Async with one
  # warning, and the countdown then never drew for that ask.
  describe "a terminal the countdown cannot ask" do
    it "is refused when the conductor is built, by the message it lacks" do
      mute = Class.new do
        def render_countdown(**) = nil
        def stop_countdown = nil
      end.new

      expect { described_class.new(tty: mute, chronicle:, signals: Lain::CLI::Signals.new) }
        .to raise_error(ArgumentError, /prompt_drawn\?/)
    end
  end

  # Whether the chat is waiting at `you>` for its next line -- what a cockpit's
  # `command>` asks, since a command can be typed at `you>` itself.
  describe "#prompting?" do
    it "is true only while you> is being read" do
      conductor = build_conductor(grace: 60, clock: clock_returning(1000.0), signals: Lain::CLI::Signals.new)
      during = nil
      watcher = Thread.new do
        sleep(0.002) until rail.published.kind == :you
        during = conductor.prompting?
        rail << typed("hi", rail.published)
      end

      before = conductor.prompting?
      conductor.read_prompt("you> ")
      watcher.join

      expect([before, during, conductor.prompting?]).to eq([false, true, false])
    end
  end

  # Whether the grace countdown is running for the ask this conductor is
  # supervising -- what a reader open beside the run asks, so it can get out of
  # the countdown's way rather than swallow its keys.
  describe "#counting_down?" do
    it "is false with no ask supervised" do
      expect(build_conductor(grace: 60, clock: -> { 1000.0 }, signals: Lain::CLI::Signals.new))
        .not_to be_counting_down
    end

    it "is true once a signal arms the grace window, and false again once the ask settles" do
      entered = Async::Queue.new
      release = Async::Queue.new
      agent = build_agent(entered:, release:, responses: [text_response])
      signals = Lain::CLI::Signals.new.install
      conductor = build_conductor(grace: 60, clock: -> { 1000.0 }, signals:)
      before_signal = during_grace = nil

      Sync do |task|
        driver = task.async do
          entered.dequeue
          before_signal = conductor.counting_down?
          Process.kill("TERM", Process.pid)
          pumped_until(task, reason: "the countdown armed") { conductor.counting_down? }
          during_grace = conductor.counting_down?
          release.enqueue(true)
        end
        conductor.supervise(task, -> { agent.timeline }) { agent.ask("hi") }
        driver.wait
      end

      expect([before_signal, during_grace, conductor.counting_down?]).to eq([false, true, false])
    ensure
      signals.uninstall
    end
  end

  # The expiry-during-reply path (the PTY probe is the evidence for the
  # terminal-restore half). A run parks inside the model call while a reply is
  # outstanding at human>; a SIGTERM arms grace, the jumped clock expires it, and
  # the coordinator interrupts the run and closes grace_expired, with the reply's
  # prompt withdrawn out of the countdown's way.
  describe "grace expiry while a reply is outstanding at human>" do
    it "still interrupts the run and closes grace_expired, the reply stepped aside" do
      entered = Async::Queue.new
      release = Async::Queue.new
      agent = build_agent(entered:, release:, responses: [text_response])
      signals = Lain::CLI::Signals.new.install
      conductor = build_conductor(grace: 60, clock: clock_returning(1000.0, 1061.0), signals:)
      outcome = nil

      Sync do |task|
        replier = task.async { conductor.read_reply("human> ") }
        driver = task.async do
          entered.dequeue # the run is provably inside the model call
          pumped_until(task, reason: "the reply parked") { rail.published.kind == :human }
          Process.kill("TERM", Process.pid) # arm grace; the jumped clock expires it
        end
        outcome = conductor.supervise(task, -> { agent.timeline }) { agent.ask("hi") }
        replier.stop
        driver.wait
      end

      expect(outcome.closed?).to be(true)
      expect(chronicle.events.last).to eq(%i[close grace_expired])
      expect(rail.published.kind).to be_nil
    ensure
      signals.uninstall
    end
  end
end
