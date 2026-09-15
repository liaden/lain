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
    # {Frontend::InputRail} goes wherever an OS signal would.
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

      # The shutdown there is while no ask is supervised: nothing is counting down.
      module Unsupervised
        def self.state = :running
      end

      # A conductor over a fresh {Signals} installer it also owns, so the exe
      # carries neither the installer nor its lifecycle (see {#guard}).
      def self.open(tty:, chronicle:, rail:, grace: Shutdown::GRACE_DEFAULT, supervisor: Supervisor::Null,
                    run_clock: RunClock.new)
        new(tty:, chronicle:, signals: Signals.new, rail:, grace:, supervisor:, run_clock:)
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
      def initialize(tty:, chronicle:, signals:, rail: Frontend::InputRail.new, grace: Shutdown::GRACE_DEFAULT,
                     budget: Agent::Budget.new, supervisor: Supervisor::Null, run_clock: RunClock.new,
                     clock: RunClock::MONOTONIC, tick: DEFAULT_TICK)
        @tty = tty
        @chronicle = chronicle
        @signals = signals
        @rail = rail
        @grace = grace
        @budget = budget
        @supervisor = supervisor
        @run_clock = run_clock
        @clock = clock
        @ticker = CountdownTicker.new(tty:, tick:, suppressed: -> { @replies_outstanding.positive? })
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
        shutdown = @shutdown = build_shutdown(run)
        coordinator, ticker_task = start_shutdown(task, shutdown)
        response = run.wait
        settle(shutdown, coordinator)
        Outcome.new(response:, closed: shutdown.state == :closed)
      ensure
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
      # @param _tty [Object] the caller's name for where it reads; the line comes
      #   off the rail whichever terminal that is
      # @param text [String] the prompt string, published unchanged
      # @return [String, nil] the line, or nil at EOF or on a signal-close
      def read_prompt(_tty, text)
        line = read_breakable(text)
        @run_clock.record_input if line
        line
      rescue PromptBreaker::Break
        close(reason: :exit)
        nil
      end

      # Read an ask_human reply or a `[y/N]` through the conductor so it KNOWS a
      # prompt is drawn for the span. Unlike {#read_prompt} there IS a run in
      # flight, so signals stay routed at the coordinator and the grace clock
      # keeps running; an expiry interrupts the run while
      # {Repl::LineScope#serve}'s ensure stops the replier fiber parked here,
      # which withdraws its prompt from the rail, so no breaker is needed.
      #
      # What DOES change: the countdown ticker is suppressed. It would otherwise
      # smear its status line against Reline's echo and STEAL a keystroke out of
      # the operator's answer with its non-blocking key read -- an 'r' silently
      # firing wait_responses. It reappears on the next tick once the last read
      # has finished -- a COUNT, since a `human>` and a `[y/N]` can be open
      # together.
      #
      # The prompt is an ANSWER on the rail: what the human typed before it was
      # drawn is held, never taken as the answer to it.
      def read_reply(_tty, text) = owning_stdin { @rail.read(answer_kind(text), text) }

      # The chat's `command>` read, which answers nothing: what the human typed
      # ahead of it is read AT it, because a `/approve` typed a moment before
      # the call parked is what they reached for. Every read that can answer
      # -- the `[y/N]` that `/approve` asks included -- goes through
      # {#read_reply}.
      def read_command(_tty, text) = owning_stdin { @rail.read(:command, text) }

      # A line the human typed that was neither a command nor an answer, kept for
      # `you>` and said to be ({Frontend::InputRail#hold}).
      def hold(line) = @rail.hold(line)

      # The oldest held line, or nil.
      def take_held = @rail.take_held

      # What was typed while no prompt was drawn -- a standing goal drives turns
      # with none open -- held before the next turn is driven.
      def gather_typed_ahead = @rail.gather

      # Whether the grace countdown is running for the ask being supervised.
      # A reader open beside the run asks, so it can close and let the
      # countdown draw and read its keys: an open read suppresses both.
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

      # The ticker's suppressed thunk reads @replies_outstanding at tick time, so
      # seeding after the ticker is constructed is safe.
      def seed_ask_state
        @timeline = nil
        @closed = false
        @replies_outstanding = 0
        @shutdown = Unsupervised
      end

      def owning_stdin
        @replies_outstanding += 1
        @ticker.stop
        yield
      ensure
        @replies_outstanding -= 1
      end

      # No rescue here on purpose -- a Break, during the read OR during this
      # ensure's dispose, surfaces to {#read_prompt}'s rescue.
      def read_breakable(text)
        breaker = PromptBreaker.new(main: Thread.current)
        route(breaker)
        @rail.read(:you, text)
      ensure
        route(Signals::NULL)
        breaker.dispose
      end

      def route(sink)
        @signals.route(sink)
        @rail.route(sink)
      end

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
        # @param suppressed [#call] -> Boolean, true while any reply owns
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
