# frozen_string_literal: true

require "async"

module Lain
  module CLI
    # The per-ask supervision glue between {Signals}, {Shutdown}, and the TTY's
    # countdown, lifted out of the thin exe the way {Backend} and {Chronicle}
    # were: the exe wires collaborators; this object owns the ask's shutdown
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
    # run in flight has nothing to interrupt (the parked-prompt path is the exe's,
    # not this object's).
    #
    # {#close} is the guarded closer the coordinator's `closer:` duck resolves to
    # AND the one chat's normal-exit ensure calls, so a signal-driven close and a
    # `close(:exit)` never both write session_closed. On an interrupt reason it
    # preserves {Repl}'s catch_up -> run_interrupted -> session_closed order (the
    # B5 amendment), which the signal path would otherwise skip.
    class Conductor
      # What the caller reads back from {#supervise}: the ask's response (nil when
      # the run was interrupted before it committed one) and whether the session
      # was closed (the repl loop's exit signal).
      Outcome = Data.define(:response, :closed) do
        def closed? = closed
      end

      # The reasons that also owe a run_interrupted record before session_closed.
      # `:exit` (a clean quit or a wait_responses drain) does not.
      INTERRUPT_REASONS = %i[interrupted grace_expired].freeze

      DEFAULT_TICK = 1.0

      # The one factory the exe calls: a conductor over a fresh {Signals}
      # installer it also owns, so the exe carries neither the installer nor its
      # lifecycle (see {#guard}).
      def self.open(tty:, chronicle:, grace: Shutdown::GRACE_DEFAULT)
        new(tty:, chronicle:, signals: Signals.new, grace:)
      end

      def initialize(tty:, chronicle:, signals:, grace: Shutdown::GRACE_DEFAULT,
                     budget: Agent::Budget.new,
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, tick: DEFAULT_TICK)
        @tty = tty
        @chronicle = chronicle
        @signals = signals
        @grace = grace
        @budget = budget
        @clock = clock
        @timeline = nil
        @closed = false
        @ticker = CountdownTicker.new(tty:, tick:)
      end

      # Supervise one ask. `timeline` is a thunk to the agent's live Timeline --
      # the closer catches it up and anchors an interrupt from it. Yields nothing;
      # the block performs the ask and its value becomes {Outcome#response}.
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

      # Read a line at an idle prompt, but route prompt-time signals to a
      # {PromptBreaker} that raises the reader out of Reline's blocking read --
      # there is no run to interrupt while idle, so a terminating signal instead
      # breaks the prompt and closes the session. Reline's own ensure has restored
      # the terminal by the time the {PromptBreaker::Break} lands; the caller sees
      # the closed session through {#closed?}.
      #
      # The cleanup (route NULL + dispose) lives in {#read_breakable}'s OWN ensure,
      # deliberately WITHOUT a rescue there, so a Break that races the dispose's
      # `@thread.join` -- landing during teardown rather than during the read --
      # propagates OUT of that method (past its ensure) into THIS method's rescue,
      # and still closes cleanly. It never escapes as a stderr backtrace + nonzero
      # exit at an intended shutdown (the AC: a raise landing outside readline must
      # not kill the process). Folding the ensure into a flat
      # `def...rescue...ensure` here would NOT cover the ensure's own raise.
      #
      # The close reason is `:exit`: signal-at-idle is recorded as :exit because
      # the reason enum ({Telemetry::SessionClosed::REASONS}) has no signal reason
      # -- least-wrong of the three, since nothing was interrupted (no run,
      # therefore no run_interrupted; an idle SIGTERM is the operator's "quit").
      # Growing the enum is a deliberate follow-up, not this card.
      #
      # @param tty [#prompt]
      # @return [String, nil] the line, or nil at EOF or on a signal-close
      def read_prompt(tty, text)
        read_breakable(tty, text)
      rescue PromptBreaker::Break
        close(reason: :exit)
        nil
      end

      # The coordinator's `closer:` duck AND chat's normal-exit closer. Guarded so
      # only the first close writes: a signal that closed the session mid-ask
      # means the ensure's `close(:exit)` is a no-op.
      #
      # @param reason [Symbol] one of {Telemetry::SessionClosed::REASONS}
      def close(reason:)
        return self if @closed

        @closed = true
        catch_up
        @chronicle.interrupted(head: @timeline.call.head_digest) if INTERRUPT_REASONS.include?(reason)
        @chronicle.close(reason:)
        self
      end

      def closed? = @closed

      # Install the OS signal traps for the block, then restore them -- even on a
      # raise. Traps come off AFTER the block returns, by which point every
      # per-ask coordinator pipe and prompt breaker is already disposed, so
      # nothing races a torn-down pipe.
      #
      # Delegates to {Signals#guarding} on the ALREADY-INJECTED @signals rather
      # than reimplementing install/yield/ensure-uninstall (there is exactly one
      # such implementation) or calling the {Signals.guarding} class method
      # (which would construct a fresh instance and discard this one's routing
      # state -- {#start_shutdown} and {#teardown} both call {Signals#route} on
      # THIS @signals across the ask).
      def guard(&block)
        @signals.guarding(&block)
      end

      private

      # The break-able read: route prompt-time signals at the breaker, read, and
      # ALWAYS undo the routing + dispose the breaker. No rescue here on purpose --
      # a Break (during the read OR during this ensure's dispose) surfaces to
      # {#read_prompt}'s rescue.
      def read_breakable(tty, text)
        breaker = PromptBreaker.new(main: Thread.current)
        @signals.route(breaker)
        tty.prompt(text)
      ensure
        @signals.route(Signals::NULL)
        breaker.dispose
      end

      # on_transition is left as Shutdown's no-op: the countdown is POLL-driven
      # ({CountdownTicker}), not transition-driven, so a cancel's status-line
      # clear lands on the next tick -- an up-to-@tick (1s) latency, accepted as
      # the price of one cadence for both the render and the clear.
      #
      # actors: is also left at Shutdown's default (none) -- deliberately: there
      # is no actor registry to hand it yet. OM-6 is the follow-up that wires
      # one in; until then `#drain` settles only the run task.
      def build_shutdown(run)
        Shutdown.new(run_task: run, closer: self, budget: @budget, clock: @clock, grace: @grace)
      end

      # Route signals at the coordinator, then spawn it and the countdown ticker
      # as siblings of the run. Returned as a pair so {#supervise}'s ensure can
      # tear both down even if this raises (they are nil then).
      def start_shutdown(task, shutdown)
        @signals.route(shutdown)
        [task.async { shutdown.coordinate }, task.async { @ticker.run(shutdown, task) }]
      end

      # The run has returned. When a terminating signal has closed (or is closing)
      # the session, let the coordinator finish its close; otherwise the ask ended
      # with no such signal, so retire the parked coordinator via its pipe.
      def settle(shutdown, coordinator)
        shutdown.dispose unless closing?(shutdown)
        coordinator.wait
      end

      def closing?(shutdown) = %i[draining closed].include?(shutdown.state)

      # Route signals away FIRST (no new input to a coordinator about to retire),
      # stop the ticker fiber so no render outlives the window, erase the status
      # line, then dispose the pipe and stop the coordinator fiber -- the per-ask
      # analogue of the session teardown's "restore traps before dispose".
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

    # Reopened rather than nested in Conductor's own class body -- the shutdown.rb
    # idiom: the ticker is its own responsibility (driving the TTY countdown from
    # the coordinator's state), and the split keeps each body within
    # Metrics/ClassLength instead of loosening it.
    class Conductor
      # The countdown ticker: renders the TTY's grace-window UI from the
      # coordinator's state on a fixed cadence. Poll-driven, not transition-driven
      # (see {Conductor#build_shutdown}), so ONE cadence serves both the render and
      # the erase.
      class CountdownTicker
        def initialize(tty:, tick:)
          @tty = tty
          @tick = tick
        end

        # One tick per @tick until the fiber is stopped: render the grace window
        # while the coordinator counts down (the countdown reads its own keys and
        # feeds them back to the coordinator -- T21), erase it otherwise. The
        # `loop` needs no break because `Async::Task#stop` unwinds it when
        # {Conductor#teardown} stops the fiber.
        def run(shutdown, task)
          loop do
            tick(shutdown)
            task.sleep(@tick)
          end
        end

        # Erase the status line: called each non-grace tick AND once from
        # {Conductor#teardown}, so no render outlives the window. Idempotent
        # ({Frontend::TTY#stop_countdown}).
        def stop = @tty.stop_countdown

        private

        def tick(shutdown)
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
