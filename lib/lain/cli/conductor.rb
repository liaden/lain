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
    # run in flight has nothing to interrupt.
    #
    # {#close} is the guarded closer the coordinator's `closer:` duck resolves to
    # AND the one chat's normal-exit ensure calls, so a signal-driven close and a
    # `close(:exit)` never both write session_closed. On an interrupt reason it
    # preserves {Repl}'s catch_up -> run_interrupted -> session_closed order,
    # which the signal path would otherwise skip.
    class Conductor
      # `response` is nil when the run was interrupted before it committed one;
      # `closed` is the repl loop's exit signal.
      Outcome = Data.define(:response, :closed) do
        def closed? = closed
      end

      # The reasons that also owe a run_interrupted record before session_closed;
      # `:exit` does not. Every member is in BOTH
      # {Telemetry::SessionClosed::REASONS} and {Telemetry::RunInterrupted::REASONS},
      # which is what lets {#close} spend one reason on both records.
      INTERRUPT_REASONS = %i[interrupted grace_expired].freeze

      DEFAULT_TICK = 1.0

      # A conductor over a fresh {Signals} installer it also owns, so the exe
      # carries neither the installer nor its lifecycle (see {#guard}).
      def self.open(tty:, chronicle:, grace: Shutdown::GRACE_DEFAULT, supervisor: Supervisor::Null,
                    run_clock: RunClock.new)
        new(tty:, chronicle:, signals: Signals.new, grace:, supervisor:, run_clock:)
      end

      # `supervisor:` answers `#drain(within:)` with an Enumerable of
      # {Shutdown}'s `#settle` drain duck; {Supervisor::Null} by default.
      #
      # `run_clock:` defaults to a fresh private {RunClock} so a caller that does
      # not care pays nothing. Production wants ONE shared instance injected here
      # AND handed to whatever else reads it or feeds it compaction events, never
      # a second Conductor-local clock the reader could drift from.
      def initialize(tty:, chronicle:, signals:, grace: Shutdown::GRACE_DEFAULT,
                     budget: Agent::Budget.new, supervisor: Supervisor::Null, run_clock: RunClock.new,
                     clock: RunClock::MONOTONIC, tick: DEFAULT_TICK)
        @tty = tty
        @chronicle = chronicle
        @signals = signals
        @grace = grace
        @budget = budget
        @supervisor = supervisor
        @run_clock = run_clock
        @clock = clock
        @ticker = CountdownTicker.new(tty:, tick:, suppressed: -> { @reply_outstanding })
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
        run = task.async(&block)
        shutdown = build_shutdown(run)
        coordinator, ticker_task = start_shutdown(task, shutdown)
        response = run.wait
        settle(shutdown, coordinator)
        Outcome.new(response:, closed: shutdown.state == :closed)
      ensure
        teardown(shutdown, coordinator, ticker_task)
      end

      # Read a line at an idle prompt, routing prompt-time signals to a
      # {PromptBreaker} that raises the reader out of Reline's blocking read --
      # there is no run to interrupt while idle, so a terminating signal instead
      # breaks the prompt and closes the session. Reline's own ensure has restored
      # the terminal by the time the {PromptBreaker::Break} lands.
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
      # @param tty [#prompt]
      # @param text [String] the prompt string, passed through to
      #   {#read_breakable} unchanged
      # @return [String, nil] the line, or nil at EOF or on a signal-close
      def read_prompt(tty, text)
        line = read_breakable(tty, text)
        @run_clock.record_input if line
        line
      rescue PromptBreaker::Break
        close(reason: :exit)
        nil
      end

      # Read an ask_human reply through the conductor so it KNOWS Reline owns
      # stdin for the span. Unlike {#read_prompt} there IS a run in flight, so
      # signals stay routed at the coordinator and the grace clock keeps running;
      # an expiry interrupts the run while {Repl::LineScope#serve}'s ensure stops
      # the replier fiber parked here, and Reline's own ensure restores the
      # terminal on that fiber-stop (PTY-probed), so no breaker is needed.
      #
      # What DOES change: the countdown ticker is suppressed. It would otherwise
      # smear its status line against Reline's echo and STEAL a keystroke out of
      # the operator's answer with its non-blocking key read -- an 'r' silently
      # firing wait_responses. The flag is conductor-owned (single writer, this
      # fiber) and read each tick, so the countdown reappears on the next tick
      # once the reply returns.
      def read_reply(tty, text)
        @reply_outstanding = true
        @ticker.stop
        tty.prompt(text)
      ensure
        @reply_outstanding = false
      end

      # The coordinator's `closer:` duck AND chat's normal-exit closer. Guarded so
      # only the first close writes: a signal that closed the session mid-ask
      # means the ensure's `close(:exit)` is a no-op.
      #
      # The reason reaches BOTH records: this object is the only place that knows
      # whether the human interrupted or the grace window expired, and a
      # run_interrupted written without it said a run stopped while staying silent
      # about which stop it was.
      #
      # @param reason [Symbol] one of {Telemetry::SessionClosed::REASONS}
      def close(reason:)
        return self if @closed

        @closed = true
        catch_up
        @chronicle.interrupted(head: @timeline.call.head_digest, reason:) if INTERRUPT_REASONS.include?(reason)
        @chronicle.close(reason:)
        self
      end

      def closed? = @closed

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

      # The ticker's suppressed thunk reads @reply_outstanding at tick time, so
      # seeding after the ticker is constructed is safe.
      def seed_ask_state
        @timeline = nil
        @closed = false
        @reply_outstanding = false
      end

      # No rescue here on purpose -- a Break, during the read OR during this
      # ensure's dispose, surfaces to {#read_prompt}'s rescue.
      def read_breakable(tty, text)
        breaker = PromptBreaker.new(main: Thread.current)
        @signals.route(breaker)
        tty.prompt(text)
      ensure
        @signals.route(Signals::NULL)
        breaker.dispose
      end

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
        @signals.route(shutdown)
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
        @signals.route(Signals::NULL)
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

      # Renders the TTY's grace-window UI from the coordinator's state on a fixed
      # cadence. Poll-driven, not transition-driven (see
      # {Conductor#build_shutdown}), so ONE cadence serves render and erase.
      class CountdownTicker
        # @param tty [#render_countdown, #stop_countdown] the terminal surface the
        #   countdown renders to and erases from ({Frontend::TTY})
        # @param tick [Numeric] the poll cadence, in seconds
        # @param suppressed [#call] -> Boolean, true while an ask_human reply owns
        #   stdin ({Conductor#read_reply}); a suppressed tick renders nothing and
        #   reads no key. Defaults to never-suppressed.
        def initialize(tty:, tick:, suppressed: -> { false })
          @tty = tty
          @tick = tick
          @suppressed = suppressed
        end

        # The `loop` needs no break: `Async::Task#stop` unwinds it when
        # {Conductor#teardown} stops the fiber.
        def run(shutdown, task)
          loop do
            tick(shutdown)
            task.sleep(@tick)
          end
        end

        # Called each non-grace tick AND once from {Conductor#teardown}, so no
        # render outlives the window. Idempotent ({Frontend::TTY#stop_countdown}).
        def stop = @tty.stop_countdown

        private

        # A suppressed tick touches nothing, not even the erase: Reline owns the
        # terminal for the reply span, and the status line was already erased at
        # {Conductor#read_reply} entry.
        def tick(shutdown)
          return if @suppressed.call

          if shutdown.state == :grace
            @tty.render_countdown(deadline: shutdown.deadline, options: { coordinator: shutdown })
          else
            stop
          end
        end
      end
    end
  end
end
