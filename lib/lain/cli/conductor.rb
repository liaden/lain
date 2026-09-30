# frozen_string_literal: true

require "async"

module Lain
  module CLI
    # The per-ask supervision glue between {Signals}, {Shutdown}, and the TTY's
    # countdown: the exe wires collaborators; this object owns the ask's shutdown
    # lifecycle.
    #
    # One ask is supervised by co-locating THREE fibers in the SAME reactor: the
    # run task hosting `@agent.ask`, the {Shutdown} coordinator parked on its
    # pipe, and the countdown ticker. Co-location is the load-bearing invariant --
    # {Agent::Budget#interrupt} is `Async::Task#stop`, and a task may only be
    # stopped from its own reactor thread, so the coordinator that stops the run
    # must live on the run's reactor, never a signal-handling side thread.
    #
    # For the ask's duration OS signals are {Signals#route}d to the coordinator;
    # between asks they route back to {Signals::NULL}, because a signal with no
    # run in flight has nothing to interrupt. A signal a producer puts on the
    # {Frontend::Intake} goes wherever an OS signal would.
    #
    # It is also the chat's door to that rail: every line the human types
    # reaches the chat through one of its three reads, and each takes the line
    # from the rail and from nowhere else.
    #
    # {#close} is the guarded closer the coordinator's `closer:` duck resolves to
    # AND the one chat's normal-exit ensure calls, so a signal-driven close and a
    # `close(:exit)` never both write session_closed. On an interrupt reason it
    # preserves {Repl}'s catch_up -> run_interrupted -> session_closed order,
    # which the signal path would otherwise skip.
    class Conductor
      # `response` is nil when the run was interrupted before it committed one,
      # and the {Lain::Stopped} cause when the ask was stopped -- a refusal the
      # repl says in one line, since a stop keeps the conversation and owes the
      # human a word about where their ask went. `closed` is the repl loop's
      # exit signal.
      Outcome = Data.define(:response, :closed) do
        def closed? = closed
      end

      # The reasons that also owe a run_interrupted record before session_closed;
      # `:exit` does not. Every member is in BOTH
      # {Telemetry::SessionClosed::REASONS} and {Telemetry::RunInterrupted::REASONS},
      # which is what lets {#close} spend one reason on both records.
      INTERRUPT_REASONS = %i[interrupted grace_expired].freeze

      DEFAULT_TICK = 1.0

      # How often an open read looks whether the countdown has started or ended.
      ASIDE_TICK = 0.05

      # What a read withdrawn for the countdown hands back, to be asked again.
      STEPPED_ASIDE = Object.new.freeze
      private_constant :STEPPED_ASIDE

      # The countdown keys an idle `you>` offers. Neither `r` nor `s`, for one
      # reason: both name a run, and at `you>` there is none. "respond then
      # exit" pressed there made the next typed line the thing being waited
      # for, and that line vanished with the session; "stop this ask" would
      # stop the read itself.
      IDLE_KEYS = { "c" => :cancel, "w" => :extend }.freeze

      # How long a Break gets to end the prompt it was raised into before the
      # signal is handed to the countdown instead.
      BREAK_GRACE = 0.5

      # The shutdown there is while no ask is supervised: nothing is counting down.
      module Unsupervised
        def self.state = :running
      end

      # What a countdown opened at `you>` closes the session with. Nothing was
      # interrupted there, so its expiry is the operator's quit, as an idle
      # SIGTERM is.
      IdleClose = Struct.new(:conductor) do
        def close(**) = conductor.close(reason: :exit)

        # A `you>` read is not an ask, so a stop reaches nothing here and the
        # read is left alone rather than cancelled out from under the human.
        def ask_in_flight? = false

        # The coordinator's duck is answered WHOLE, not down to what today's
        # routing happens to reach: the cost of a closer that answered only
        # part of it is a cancelled read and a dead coordinator fiber, which
        # is a prompt that never comes back.
        def stopped(_cause) = conductor.no_ask_running
      end

      # Signals arriving while `you>` is read, RECORDED in the trap and routed
      # on the reactor ({Conductor#routed_idle}).
      #
      # The decision is not the trap's to make: a signal delivered as a prompt
      # takes the terminal from `you>` read a screen that was already a
      # transition old, so it was sent to the prompt breaker and the Break
      # landed in the very read being stopped, where the stop absorbed it -- a
      # Ctrl-C that did nothing at all. The trap does what a trap can do: one
      # read of the rail's published generation and one nonblocking write of a
      # byte ({Shutdown::Ingress}, whose class comment holds the trap-safety
      # rules). A live fiber then routes each recorded signal against whatever
      # is drawn when it is handled.
      class IdleSignals
        # What the trap recorded: the input, and the prompt generation it
        # arrived at. A stale generation says the screen moved under it.
        Arrived = Data.define(:name, :generation)

        def initialize(rail:)
          @rail = rail
          @ingress = Shutdown::Ingress.new
          @generation = 0
        end

        # Trap context: two ivar reads, one ivar write, one nonblocking write.
        def signal(name)
          @generation = @rail.glimpse.generation
          @ingress.signal(name)
        end

        # Each recorded signal, until the ingress retires.
        def each(&block)
          Enumerator.produce { Arrived.new(name: @ingress.read, generation: @generation) }
                    .lazy.take_while { |arrived| arrived.name != :retired }.each(&block)
        end

        def dispose = @ingress.dispose

        # Nothing is supervised while `you>` is read, so a stop reaching this
        # recorder has no ask behind it.
        def ask_in_flight? = false
      end

      # A conductor over a fresh {Signals} installer it also owns, so the exe
      # carries neither the installer nor its lifecycle (see {#guard}).
      def self.open(tty:, chronicle:, rail:, grace: Shutdown::GRACE_DEFAULT, supervisor: Supervisor::Null,
                    run_clock: RunClock.new, countdown: RailCountdown::Unoffered)
        new(tty:, chronicle:, signals: Signals.new, rail:, grace:, supervisor:, run_clock:, countdown:)
      end

      # `supervisor:` answers `#drain(within:)` with an Enumerable of
      # {Shutdown}'s `#settle` drain duck, and `#stop`, which {#close} sends
      # before the record shuts; {Supervisor::Null} by default.
      #
      # `run_clock:` defaults to a fresh private {RunClock} so a caller that does
      # not care pays nothing. Production wants ONE shared instance injected here
      # AND handed to whatever else reads it or feeds it compaction events, never
      # a second Conductor-local clock the reader could drift from.
      #
      # `rail:` is where the human's lines come from; a fresh one with nothing
      # feeding it by default, for a conductor that supervises and never reads.
      def initialize(tty:, chronicle:, signals:, rail: Frontend::Intake.new, grace: Shutdown::GRACE_DEFAULT,
                     budget: Agent::Budget.new, supervisor: Supervisor::Null, run_clock: RunClock.new,
                     clock: RunClock::MONOTONIC, tick: DEFAULT_TICK, countdown: RailCountdown::Unoffered)
        @tty = tty
        @chronicle = chronicle
        @signals = signals
        @rail = rail
        @grace = grace
        @budget = budget
        @supervisor = supervisor
        @run_clock = run_clock
        @clock = clock
        @ticker = CountdownTicker.new(tty:, tick:)
        @countdown = countdown
        @idle_keys = IDLE_KEYS
        @rail.route(@signals)
        seed_ask_state
      end

      # `timeline` is a thunk to the agent's live Timeline -- the closer catches
      # it up and anchors an interrupt from it. The block performs the ask and
      # its value becomes {Outcome#response}.
      #
      # @param task [Async::Task] the reactor parent the three fibers spawn under
      # @param timeline [#call] -> Lain::Timeline
      # @return [Outcome]
      def supervise(task, timeline, &block)
        @timeline = timeline
        @stopped = nil
        @supervising = true
        run = task.async(&block)
        shutdown = @shutdown = build_shutdown(run)
        coordinator, ticker_task = start_shutdown(task, shutdown)
        response = run.wait
        settle(shutdown, coordinator)
        Outcome.new(response: @stopped || response, closed: shutdown.state == :closed)
      ensure
        @supervising = false
        teardown(shutdown, coordinator, ticker_task)
      end

      # Read a line at an idle prompt, routing prompt-time signals to a
      # {PromptBreaker} that raises the reader out of its wait on the rail --
      # there is no run to interrupt while idle, so a terminating signal instead
      # breaks the prompt and closes the session.
      #
      # The cleanup (route NULL + dispose) lives in {#read_breakable}'s OWN ensure
      # and deliberately WITHOUT a rescue there, so a Break that races the
      # dispose's `@thread.join` -- landing during teardown rather than during the
      # read -- propagates past that ensure into THIS method's rescue and still
      # closes cleanly, rather than escaping as a backtrace and a nonzero exit at
      # an intended shutdown. A flat `def...rescue...ensure` here would NOT cover
      # the ensure's own raise.
      #
      # The close reason is `:exit` because the reason enum
      # ({Telemetry::SessionClosed::REASONS}) has no signal reason, and nothing
      # was interrupted: an idle SIGTERM is the operator's "quit".
      #
      # A read line records {RunClock#record_input}, the clock's one write site.
      # EOF and a rescued Break are not the user answering anything, so neither
      # records.
      #
      # @param text [String] the prompt string, published unchanged
      # @return [String, nil] the line, or nil at EOF or on a signal-close
      def read_prompt(text)
        line = read_breakable(text)
        @run_clock.record_input if line
        line
      rescue PromptBreaker::Break
        close(reason: :exit)
        nil
      end

      # Read an ask_human reply or a `[y/N]`. Unlike {#read_prompt} there may be
      # a run in flight, so signals stay routed at the coordinator and the grace
      # clock keeps running.
      #
      # The countdown owns the terminal while it runs -- its status line and its
      # key read, where an 'r' typed as an answer would fire wait_responses -- so
      # this read STEPS ASIDE for it: the prompt is withdrawn once the countdown
      # starts, and whatever was half typed at it is gone, and it is published
      # again, empty, once the countdown is cancelled or the run drains. An
      # expiry never gives it back: the run is interrupted instead.
      #
      # The prompt is an ANSWER on the rail: what the human typed before it was
      # drawn is held, never taken as the answer to it.
      def read_reply(text) = aside_of_countdown(answer_kind(text), text)

      # The chat's `command>` read, which answers nothing: what the human typed
      # ahead of it is read AT it, because a `/approve` typed a moment before
      # the call parked is what they reached for. Every read that can answer
      # -- the `[y/N]` that `/approve` asks included -- goes through
      # {#read_reply}. It steps aside for the countdown as that read does.
      def read_command(text) = aside_of_countdown(:command, text)

      # Whether the chat is waiting at `you>` for its next line.
      def prompting? = @prompting

      # A line the human typed that was neither a command nor an answer, kept for
      # `you>` and said to be ({Frontend::Intake#hold}).
      def hold(line) = @rail.hold(line)

      # The oldest held line, or nil.
      def take_held = @rail.take_held

      # What was typed while no prompt was drawn -- a standing goal drives turns
      # with none open -- held before the next turn is driven.
      def gather_typed_ahead = @rail.gather

      # Whether the grace countdown is running for the ask being supervised.
      # A reader open beside the run asks, so it can get out of the countdown's
      # way rather than swallow its keys.
      def counting_down? = @shutdown.state == :grace

      # The coordinator's `closer:` duck AND chat's normal-exit closer. Guarded so
      # only the first close writes: a signal that closed the session mid-ask
      # means the ensure's `close(:exit)` is a no-op.
      #
      # The reason reaches BOTH records: this object is the only place that knows
      # whether the human interrupted or the grace window expired, and a
      # run_interrupted written without it said a run stopped while staying silent
      # about which stop it was.
      #
      # The fleet stops BEFORE the record closes. A signal closes the record
      # mid-conversation, and every farewell writes to it -- a lease release, a
      # crashed row's reap, an actor's last message -- so a fleet stopped later,
      # as the conversation unwinds, would write into a closed journal. A
      # supervisor already stopped answers at once, so the normal-exit order,
      # where the conversation stopped it first, is unchanged.
      #
      # @param reason [Symbol] one of {Telemetry::SessionClosed::REASONS}
      def close(reason:)
        return self if @closed

        @closed = true
        catch_up
        @chronicle.interrupted(head: @timeline.call.head_digest, reason:) if INTERRUPT_REASONS.include?(reason)
        stop_fleet_then_close(reason)
        self
      end

      def closed? = @closed

      # Whether an ask is in flight here at all -- which is only ever inside
      # {#supervise}. A slash command drives its own work in the repl's
      # dispatch, outside every supervision, and a `you>` read is between asks
      # by construction; a `/stop` typed at either must stay the line it is,
      # because the rail would otherwise lift it into a sink with no run
      # behind it and nobody would ever see it again.
      def ask_in_flight? = @supervising

      # What a stop with no ask behind it is told to the human as. One
      # spelling with the command that answers the same question at `you>`.
      def no_ask_running = @tty.render_warning(Command::Stop::NOTHING_RUNNING)

      # The coordinator's other record-keeping duck: the ask stopped and the
      # session did not. It anchors a run_interrupted exactly as {#close} does
      # on an interrupt reason, and writes NO session_closed -- the whole point
      # of the input is that the conversation goes back to `you>`. The cause is
      # kept for {#supervise}'s Outcome, so the ask answers with the refusal
      # rather than with a bare nil the repl would read as a breach.
      #
      # @param cause [Lain::Stopped] what the cancellation carried
      def stopped(cause)
        @stopped = cause
        catch_up
        @chronicle.interrupted(head: @timeline.call.head_digest, reason: Agent::StopReason.for(cause))
        self
      end

      # Install the OS signal traps for the block, then restore them -- even on a
      # raise. Traps come off AFTER the block returns, by which point every
      # per-ask coordinator pipe and prompt breaker is already disposed, so
      # nothing races a torn-down pipe.
      #
      # == The second Break rescue, and why {#read_prompt}'s is not enough
      #
      # {PromptBreaker} delivers with `Thread#raise`, and against a thread under a
      # fiber scheduler that is delivered at the SCHEDULER's next interrupt
      # checkpoint rather than inside the fiber -- measured on async 2.42.0, where
      # the Break surfaced at `Repl#run`'s `Sync` boundary with
      # `Async::Scheduler#handle_interrupt` atop the backtrace, sailing clean past
      # {#read_prompt}'s rescue. The process then died OF SIGNAL 2 with a Ruby
      # backtrace where it had meant to exit 0, so `lain up`'s `remain-on-exit
      # failed` held the corpse -- and a chat pane that will not go away is a tmux
      # session that will not go away either.
      #
      # Rescued here rather than relocating the delivery: a Break exists only
      # while {#read_breakable} has the breaker routed, so one arriving ANYWHERE
      # means the human interrupted an idle prompt, and where it lands is a
      # scheduler detail that has already changed once. {#close} is idempotent, so
      # the two rescues cannot double-close, and this is the outermost place that
      # still knows what a Break means.
      #
      # Delegates to {Signals#guarding} on the ALREADY-INJECTED @signals rather
      # than the {Signals.guarding} class method, which would construct a fresh
      # instance and discard this one's routing state -- {#start_shutdown} and
      # {#teardown} both call {Signals#route} on THIS @signals across the ask.
      def guard(&block)
        @signals.guarding(&block)
      rescue PromptBreaker::Break
        close(reason: :exit)
        nil
      end

      private

      # The close is unconditional: a farewell that raises -- a worktree release
      # git refuses -- still propagates, but after the record has closed, since
      # {#close} is already marked closed and nothing would close it later.
      def stop_fleet_then_close(reason)
        @supervisor.stop
      ensure
        @chronicle.close(reason:)
      end

      def seed_ask_state
        @timeline = nil
        @closed = false
        @prompting = false
        @stopped = nil
        @supervising = false
        @shutdown = Unsupervised
      end

      def aside_of_countdown(kind, text)
        Enumerator.produce { read_unless_counting_down(kind, text) }.lazy
                  .reject { |heard| heard.equal?(STEPPED_ASIDE) }.first
      end

      # The window is closed before the prompt is published again, so the line
      # editor never opens under the countdown's raw mode and has its own mode
      # put back from under it. A closed session never draws a prompt again: the
      # read waits to be stopped with the surface it belongs to, rather than
      # putting a `[y/N]` back on a screen the chat has finished with.
      def read_unless_counting_down(kind, text)
        park_while { counting_down? || closed? }
        @ticker.stop
        reading = Async::Task.current.async(finished: false) { @rail.read(kind, text) }
        watching = Async::Task.current.async { stepped_aside_for_countdown(reading) }
        heard = reading.wait
        reading.stopped? ? STEPPED_ASIDE : heard
      ensure
        watching&.stop
        reading&.stop
      end

      def stepped_aside_for_countdown(reading)
        park_while { !counting_down? }
        reading.stop
      end

      # Parks while the block holds, at most `within` seconds when one is given.
      def park_while(within = nil)
        deadline = within && (Async::Clock.now + within)
        Async::Task.current.sleep(ASIDE_TICK) while yield && (deadline.nil? || Async::Clock.now < deadline)
      end

      # No rescue here on purpose -- a Break, during the read OR during this
      # ensure's dispose, surfaces to {#read_prompt}'s rescue.
      def read_breakable(text)
        breaker = PromptBreaker.new(main: Thread.current)
        Sync { |task| read_you(task, text, breaker) }
      ensure
        route(Signals::NULL)
        breaker.dispose
      end

      # Every fiber is spawned through one barrier that exists before any of
      # them, because the breaker's Break is raised from another thread and can
      # land between a spawn and the local that names it. A fiber no local names
      # outlives this read, and one still looping keeps the chat's reactor, and
      # so the process, alive after the conversation has ended, with every later
      # signal routed nowhere.
      def read_you(task, text, breaker)
        idle = Async::Barrier.new(parent: task)
        read_idle(idle, text, breaker)
      ensure
        idle&.stop
      end

      # `you>` read as the run of a countdown of its own, which only a signal
      # arriving while an answer stands in front of `you>` ever opens
      # ({IdleSignals}). `you>` steps aside for that countdown too, or it would
      # take the terminal back the moment the answer stepped aside. Settled as
      # {#supervise} settles an ask, so an expiry closes the session before the
      # countdown's fibers are stopped.
      def read_idle(idle, text, breaker)
        @prompting = true
        # Recording FIRST, before a prompt exists to signal at: a signal arriving
        # while this is still being set up is kept in the ingress and routed when
        # the fiber below starts, rather than reaching a sink that is still NULL.
        recorder = IdleSignals.new(rail: @rail)
        route(recorder)
        reading = idle.async(finished: false) { aside_of_countdown(:you, text) }
        shutdown = @shutdown = idle_shutdown(reading)
        routing, coordinator, ticker_task = idle_fibers(idle, shutdown, recorder, breaker)
        reading.wait.tap { settle(shutdown, coordinator) }
      ensure
        @prompting = false
        reading&.stop
        recorder&.dispose
        routing&.stop
        teardown(shutdown, coordinator, ticker_task)
      end

      # The three fibers an idle `you>` needs beside its read -- the recorded
      # signals' routing, the coordinator, and the ticker -- and the rail's own
      # offering of the countdown they drive, which {#teardown} withdraws.
      def idle_fibers(idle, shutdown, recorder, breaker)
        @countdown.offering(shutdown, idle, keys: @idle_keys)
        [idle.async { routed_idle(recorder, shutdown, breaker) }, idle.async { shutdown.coordinate },
         idle.async { |ticking| @ticker.run(shutdown, ticking, bindings: @idle_keys) }]
      end

      def idle_shutdown(reading)
        Shutdown.new(run_task: reading, closer: IdleClose.new(self), budget: @budget, clock: @clock, grace: @grace)
      end

      # Each recorded signal, routed against what is drawn NOW: the prompt
      # breaker while `you>` itself is still the prompt the signal arrived at,
      # and otherwise the countdown, which is what a Ctrl-C means at any
      # question.
      def routed_idle(recorder, shutdown, breaker)
        recorder.each { |arrived| deliver_idle(arrived, shutdown, breaker) }
      end

      # A stop is the exception to that routing, and it is said rather than
      # delivered: whenever this prompt is drawn the conversation is between
      # asks -- the repl dispatches a line and the ask it starts completes
      # inside that dispatch -- so there is no run to stop, and handing the
      # input to the countdown's coordinator would stop the READ instead.
      #
      # A Break is delivered by `Thread#raise`, and one raised into a `you>` read
      # that is at that instant being stopped for a prompt taking the terminal is
      # absorbed by that stop. So the delivery is CONFIRMED: a Break that has not
      # ended the prompt hands its signal to the countdown instead, and no signal
      # is lost.
      def deliver_idle(arrived, shutdown, breaker)
        return no_ask_running if arrived.name == :stop
        return shutdown.signal(arrived.name) unless at_you?(arrived)

        breaker.signal(arrived.name)
        park_while(BREAK_GRACE) { at_you?(arrived) && !closed? }
        shutdown.signal(arrived.name) unless closed?
      end

      # Whether `you>` is still the prompt that signal arrived at.
      def at_you?(arrived)
        published = @rail.published
        published.kind == :you && published.generation == arrived.generation
      end

      # The rail was routed at THIS object's routing once, in {#initialize}, so
      # there is one place a signal's destination changes rather than two that
      # can disagree about it.
      def route(sink) = @signals.route(sink)

      # A prompt names its own kind when it has one ({Frontend::ApprovalPolicy::Asked});
      # otherwise it is a question's `human>`.
      def answer_kind(text) = text.respond_to?(:kind) ? text.kind : :human

      # on_transition is left as Shutdown's no-op: the countdown is POLL-driven
      # ({CountdownTicker}), so a cancel's status-line clear lands on the next
      # tick -- up to @tick (1s) late, the price of one cadence for both.
      #
      # The supervisor's drain view is BOUNDED, capped at the same grace window
      # the countdown uses, because an unbounded fleet settle would wedge the
      # coordinator fiber with the sigquit escape hatch queued unread behind it.
      # A settle that hits the cap is journaled (drain_timed_out), never silent.
      def build_shutdown(run)
        Shutdown.new(run_task: run, closer: self, budget: @budget, clock: @clock, grace: @grace,
                     actors: @supervisor.drain(within: @grace))
      end

      # Returned as a pair so {#supervise}'s ensure can tear both down even if
      # this raises (they are nil then).
      def start_shutdown(task, shutdown)
        route(shutdown)
        @countdown.offering(shutdown, task)
        [task.async { shutdown.coordinate }, task.async { @ticker.run(shutdown, task) }]
      end

      # When a terminating signal has closed or is closing the session, let the
      # coordinator finish; otherwise retire it through its pipe.
      def settle(shutdown, coordinator)
        shutdown.dispose unless closing?(shutdown)
        coordinator.wait
      end

      def closing?(shutdown) = %i[draining closed].include?(shutdown.state)

      # Ordered: signals away FIRST (no new input to a coordinator about to
      # retire), then the ticker so no render outlives the window, then the pipe
      # -- the per-ask analogue of "restore traps before dispose".
      def teardown(shutdown, coordinator, ticker_task)
        @shutdown = Unsupervised
        route(Signals::NULL)
        @countdown.withdraw
        ticker_task&.stop
        @ticker.stop
        shutdown&.dispose
        coordinator&.stop
      end

      def catch_up
        @chronicle.catch_up(@timeline.call) if @timeline
      end
    end

    class Conductor
      # Reopened rather than nested, the shutdown.rb idiom: the split keeps each
      # body within Metrics/ClassLength instead of loosening it.

      # The grace window as a PROMPT on the {Frontend::Intake}, for a chat
      # whose human is not at its terminal. {Frontend::TTY::Countdown} owns the
      # bottom line of the chat's own screen and reads its keys off the chat's
      # stdin; neither is any use when the human is in another pane, so the same
      # window is published as a `countdown` prompt and answered with a
      # {Frontend::Intake::Signal} -- which lands exactly where an OS signal
      # would, so {Shutdown} needs no second door.
      #
      # A prompt rather than a status line also makes the window OBEY the rail:
      # it takes its turn, the read it interrupts steps aside for it, and the
      # reads behind it are held until it closes.
      class RailCountdown
        DEFAULT_KEYS = { "c" => :cancel, "w" => :extend, "r" => :wait_responses, "s" => :stop }.freeze

        # How often the window's state is re-read. {Conductor::ASIDE_TICK}'s
        # cadence, for the same reason: a countdown the human cannot answer for
        # a whole second is a countdown they will not believe.
        TICK = 0.05

        # The chat whose human is at its own terminal, where the countdown is
        # the TTY's status line. Publishing a second one on the rail there would
        # open the line editor under the key reader's raw mode.
        module Unoffered
          def self.offering(_shutdown, _task, keys: nil) = keys
          def self.withdraw = nil
        end

        def initialize(rail:, clock: RunClock::MONOTONIC, tick: TICK)
          @rail = rail
          @clock = clock
          @tick = tick
          @task = nil
        end

        # Watch `shutdown` for the length of one supervision, drawing the window
        # whenever it is open.
        def offering(shutdown, task, keys: DEFAULT_KEYS)
          withdraw
          @task = task.async { watching(shutdown, keys) }
        end

        def withdraw
          @task&.stop
          @task = nil
        end

        private

        # The `loop` needs no break: {Conductor#teardown} stops the fiber.
        def watching(shutdown, keys)
          task = Async::Task.current
          loop { window(task, shutdown, keys) }
        end

        def window(task, shutdown, keys)
          park(task) { shutdown.state != :grace }
          drawing = task.async { drawn(shutdown, keys) }
          park(task) { shutdown.state == :grace }
          drawing.stop
        end

        def park(task)
          task.sleep(@tick) while yield
        end

        # A line typed at the countdown answers nothing -- the keys are signals
        # -- so it is held for the next `you>` rather than swallowed, and the
        # window is published again under a fresh generation.
        def drawn(shutdown, keys)
          Enumerator.produce { @rail.read(:countdown, offer(shutdown, keys), keys:) }
                    .lazy.take_while { |line| !line.nil? }.each { |line| @rail.hold(line) }
        end

        # {Frontend::TTY::Countdown}'s own words, so the two surfaces say one
        # thing. The remaining seconds are stamped when the window opens and do
        # not tick: a pane redraw costs the human's half-typed line, and the
        # deadline the number describes is the chat's to enforce either way.
        def offer(shutdown, keys)
          remaining = [(shutdown.deadline - @clock.call).ceil, 0].max
          labels = Frontend::TTY::Countdown::LABELS
          "closing in #{remaining}s -- #{keys.map { |key, act| "[#{key}] #{labels.fetch(act, act.to_s)}" }.join("  ")}"
        end
      end

      # Renders the TTY's grace-window UI from the coordinator's state on a fixed
      # cadence. Poll-driven, not transition-driven (see
      # {Conductor#build_shutdown}), so ONE cadence serves render and erase.
      class CountdownTicker
        # What the ticker sends the terminal. Checked when it is built: a
        # message missing there killed the ticker's task inside Async on its
        # first tick, and the countdown never drew, with one warning to say so.
        NEEDS = %i[render_countdown stop_countdown prompt_drawn?].freeze

        # @param tty [#render_countdown, #stop_countdown, #prompt_drawn?] the
        #   terminal surface the countdown renders to and erases from
        #   ({Frontend::TTY})
        # @param tick [Numeric] the poll cadence, in seconds
        def initialize(tty:, tick:)
          missing = NEEDS.reject { |message| tty.respond_to?(message) }
          raise ArgumentError, "the countdown's terminal does not answer #{missing.join(", ")}" unless missing.empty?

          @tty = tty
          @tick = tick
        end

        # The `loop` needs no break: `Async::Task#stop` unwinds it when
        # {Conductor#teardown} stops the fiber.
        #
        # @param shutdown [CLI::Shutdown] the coordinator this renders the state of
        # @param task [Async::Task] the fiber's own task, for its sleep
        # @param bindings [Hash, nil] the keys this countdown offers, or nil for
        #   the terminal's own default
        def run(shutdown, task, bindings: nil)
          loop do
            tick(shutdown, bindings)
            task.sleep(@tick)
          end
        end

        # Called each non-grace tick AND once from {Conductor#teardown}, so no
        # render outlives the window. Idempotent ({Frontend::TTY#stop_countdown}).
        def stop = @tty.stop_countdown

        private

        # A tick while a line editor still holds the terminal touches nothing,
        # not even the erase: a read that stepped aside is still unwinding, and
        # Reline puts its own terminal mode back as it goes.
        def tick(shutdown, bindings = nil)
          return if @tty.prompt_drawn?

          if shutdown.state == :grace
            @tty.render_countdown(deadline: shutdown.deadline,
                                  options: { coordinator: shutdown, **({ bindings: } if bindings).to_h })
          else
            stop
          end
        end
      end
    end
  end
end
