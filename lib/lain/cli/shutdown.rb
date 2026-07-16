# frozen_string_literal: true

require "async"
require "active_support/core_ext/module/delegation"

module Lain
  module CLI
    # The graceful-shutdown coordinator: it owns the run task's handle and the
    # policy that decides WHEN a Ctrl-C (or a supervising UI) actually halts the
    # run. The state machine is `running -> grace(deadline) -> draining ->
    # closed`; a terminating signal opens a grace window instead of interrupting
    # at once, so an in-flight model call gets a chance to finish (or the user a
    # chance to change their mind) before the run is stopped.
    #
    # Signals arrive through {Ingress}, the self-pipe (see its comment for the
    # trap-safety reasoning); this class is pure policy over the symbols the
    # ingress yields.
    #
    # == `actors:` and `on_transition:` are unwired in production
    #
    # Both seams are fully built and spec'd, but {CLI::Conductor#build_shutdown}
    # -- the only production caller -- passes neither. Today `#drain`
    # (`wait_responses`) settles ZERO actors (only the run task's own `#wait`),
    # and `#enter` notifies nobody on a state change (T21/T22 chose poll-driven
    # rendering over transition-driven). See each param doc below for who is
    # expected to wire it.
    #
    # == Interrupting through Budget
    #
    # On expiry, a promote, or a sigquit the run is stopped via
    # {Agent::Budget#interrupt} -- `Async::Task#stop`, structured cancellation
    # that raises `Async::Stop` only at a scheduler yield point, so the Agent's
    # own `defer_stop` shield lets the commit+journal atom complete and the
    # Timeline is only ever left BETWEEN whole commits (see docs/concurrency.md's
    # worked supervisor, which this is the production caller for). The task must
    # be the `task.async` wrapper HOSTING the run, never the run's own fiber.
    class Shutdown
      STATES = %i[running grace draining closed].freeze

      # The wire protocol: one distinct byte per input a trap (or a UI) may
      # send, each a frozen single-byte literal. `expired` and `retired` are
      # deliberately absent: nobody writes them -- one is synthesized from the
      # reactor timeout, the other from the pipe closing.
      BYTES = {
        sigint: "\x01", sigterm: "\x02", sigquit: "\x03",
        cancel: "\x04", extend: "\x05", wait_responses: "\x06", promote: "\x07"
      }.freeze

      DECODE = BYTES.invert.freeze

      # Which policy method each input drives. `sigint`/`sigterm` request a
      # graceful window (or promote if one is already counting down);
      # `sigquit`/`promote` interrupt at once; `expired` is the internal
      # timeout, `retired` the internal closed-ingress terminator.
      HANDLERS = {
        sigint: :request_grace, sigterm: :request_grace,
        sigquit: :interrupt_now, promote: :interrupt_now,
        cancel: :cancel, extend: :extend_deadline,
        wait_responses: :drain, expired: :expire, retired: :retire
      }.freeze

      GRACE_DEFAULT = 60

      attr_reader :state, :deadline

      delegate :signal, :dispose, :disposed?, to: :@ingress

      # @param run_task [#stop, #wait] the `task.async` handle hosting the run
      # @param closer [#close] journals the session's end; `close(reason:)` with
      #   a {Telemetry::SessionClosed::REASONS} value ({CLI::Chronicle} satisfies it)
      # @param budget [#interrupt] the interrupt seam; {Agent::Budget} by default
      # @param clock [#call] monotonic time source, injectable for tests (the
      #   {Middleware::Timeout} seam)
      # @param grace [Numeric] seconds the countdown runs before expiry
      # @param actors [Enumerable<#settle>] long-lived children to settle on a
      #   graceful drain (T3 makes `settle` safe); none by default. UNWIRED in
      #   production -- {CLI::Conductor#build_shutdown} passes no actors, so
      #   `#drain` settles nothing beyond the run task itself today. OM-6 is
      #   expected to wire the actor registry here.
      # @param on_transition [#call] notified `(state, deadline)` after each
      #   transition -- the seam T21's countdown UI renders on. UNWIRED in
      #   production -- {CLI::Conductor#build_shutdown} passes the default
      #   no-op, because T21/T22 built the countdown as poll-driven
      #   ({CLI::Conductor::CountdownTicker}) instead. A future event-driven UI
      #   is the expected caller.
      def initialize(run_task:, closer:, budget: Agent::Budget.new,
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     grace: GRACE_DEFAULT, actors: [].freeze, on_transition: ->(_state, _deadline) {})
        raise ArgumentError, "grace must be a positive Numeric, got #{grace.inspect}" unless positive?(grace)

        @run_task = run_task
        @closer = closer
        @budget = budget
        @clock = clock
        @grace = grace
        @actors = actors
        @on_transition = on_transition
        seed_policy
      end

      # Run the coordinator fiber: park on the pipe (bounded by the grace
      # deadline while counting down), dispatch each input, until the session
      # closes -- or until the ingress itself closes ({#dispose}, in ANY order
      # relative to this fiber), which is clean retirement, never a crash: the
      # owner tearing the pipe down is a statement that no input will ever
      # arrive, not an event to journal. Blocks the calling fiber -- T22 spawns
      # it as `task.async`.
      def coordinate
        handle(await_input) until finished?
        self
      end

      private

      # A fresh coordinator is idle in :running with no window open, listening
      # on a new pipe.
      def seed_policy
        @ingress = Ingress.new
        @state = :running
        @deadline = nil
        @retired = false
      end

      def closed? = @state == :closed
      def counting_down? = @state == :grace
      def finished? = closed? || @retired

      # Park for the next input. While counting down the wait is bounded by the
      # remaining grace: a byte arriving first is the input, the deadline passing
      # first synthesizes `:expired`. An already-past deadline (the injected
      # clock jumped) short-circuits, so expiry needs no reactor timer to test.
      def await_input
        return @ingress.read unless counting_down?

        remaining = @deadline - @clock.call
        return :expired unless remaining.positive?

        @ingress.read_before(remaining)
      end

      def handle(input) = __send__(HANDLERS.fetch(input))

      # A terminating signal during a countdown promotes to an immediate
      # interrupt (the AC's "second sigint"); from running it opens the window.
      def request_grace
        counting_down? ? interrupt_now : arm_grace
      end

      def arm_grace
        @deadline = @clock.call + @grace
        enter(:grace)
      end

      def cancel
        disarm if counting_down?
      end

      def disarm
        @deadline = nil
        enter(:running)
      end

      # Re-arm from now, staying in grace: the window slides out and the UI
      # re-renders on the fresh deadline.
      def extend_deadline
        arm_grace if counting_down?
      end

      def interrupt_now = force_stop(:interrupted)
      def expire = force_stop(:grace_expired)

      # The ingress closed under us: end the fiber without touching the closer
      # -- retirement is nobody-will-ever-signal, not a session outcome.
      def retire
        @retired = true
      end

      # Stop the run through Budget, let the cancellation settle, then close. The
      # Agent's `defer_stop` holds the stop off its commit+journal atom, so the
      # wait returns on a whole Timeline, never a torn one. The deadline dies
      # BEFORE :draining is announced: a T21 renderer sees state and deadline
      # through the same notification, and a draining that still carried the
      # grace deadline would render a countdown for a window that no longer
      # exists.
      def force_stop(reason)
        @deadline = nil
        enter(:draining)
        @budget.interrupt(@run_task)
        @run_task.wait
        finish(reason)
      end

      # wait_responses: let the in-flight work finish rather than cancel it --
      # the run's own #wait, then each actor's #settle -- and close as a clean
      # exit. Same dead-deadline rule as {#force_stop}: a drain requested
      # mid-countdown abandons the window before announcing.
      def drain
        @deadline = nil
        enter(:draining)
        @run_task.wait
        @actors.each(&:settle)
        finish(:exit)
      end

      def finish(reason)
        @closer.close(reason:)
        enter(:closed)
      end

      def enter(state)
        @state = state
        @on_transition.call(@state, @deadline)
      end

      def positive?(seconds) = seconds.is_a?(Numeric) && seconds.positive?
    end

    # Reopened rather than nested in the policy's own class body -- the
    # telemetry.rb idiom: the ingress is its own responsibility, and the split
    # keeps each body within Metrics/ClassLength instead of loosening it.
    class Shutdown
      # The self-pipe: the signal-safe ingress the policy machine reads from.
      #
      # Ruby defers Signal.trap bodies to safe VM checkpoints -- they do NOT run
      # in C's async-signal context, so allocation and GC are safe inside one.
      # What is still forbidden in a trap body is anything that can BLOCK or
      # that touches fiber machinery: a Mutex another fiber on this same thread
      # holds is a self-deadlock (the holder cannot run until the trap
      # returns), a `Thread::Queue` unblocked from trap context on the reactor
      # thread is version-sensitive (panel S5), and no fiber may be resumed or
      # yielded from a trap. The invariant {#signal} keeps is therefore: no
      # locks, no Thread::Queue, no fiber operations -- one nonblocking
      # `write(2)` of a byte to a pipe. The coordinator's fiber parks on the
      # pipe's read end; under async's fiber scheduler that park is
      # reactor-native (`IO#read` yields through the `io_wait` hook), so it
      # costs nothing while idle and wakes the instant a byte lands. This is
      # the {Frontend::Neovim::RpcThread} wake-pipe trick (`rpc_thread.rb`),
      # moved onto a fiber.
      class Ingress
        def initialize
          @read, @write = IO.pipe
        end

        # The trap-side write: one nonblocking `write(2)` of a pre-frozen byte
        # -- no locks, no Thread::Queue, no fiber ops (see the class comment
        # for why that, and not zero allocation, is the trap-safety invariant;
        # this call does allocate its kwargs, which deferred traps make safe).
        #
        # `exception: false` on a FULL pipe: the write returns a symbol and the
        # byte is dropped. Accepted, with eyes open about what it can drop --
        # not only a redundant duplicate but a DISTINCT input behind a
        # heterogeneous flood (a cancel behind 64KiB of queued sigints would be
        # lost). Accepted because the coordinator drains the pipe continuously,
        # one byte per dispatch, so a backlog anywhere near the ~64KiB capacity
        # means the coordinator is long dead, not busy -- and 64KiB of pending
        # sigints has already promoted the shutdown many times over.
        #
        # Safe to call from a real Signal.trap, with one ordering asterisk:
        # after {#dispose} the pipe is closed and the write raises IOError
        # instead of returning -- rescued here to a plain nil, so a trap that
        # fires in the teardown race window still never raises. T22 removes
        # traps BEFORE disposing; this rescue is the belt under that ordering,
        # not a license to skip it.
        def signal(name)
          @write.write_nonblock(BYTES.fetch(name), exception: false)
        rescue IOError
          nil
        end

        # A closed ingress reads as retirement, whichever way it closes: EOF
        # (the write end went first) is a nil byte, a mid-park {#dispose} of
        # the read end raises IOError -- both mean no input will ever arrive
        # again.
        def read
          byte = @read.read(1)
          byte.nil? ? :retired : DECODE.fetch(byte)
        rescue IOError
          :retired
        end

        # {#read}, bounded: the deadline passing before a byte lands is the
        # policy's `:expired` input.
        def read_before(remaining)
          Async::Task.current.with_timeout(remaining) { read }
        rescue Async::TimeoutError
          :expired
        end

        # Close the pipe fds. Explicit, not folded into the coordinator's exit,
        # so the teardown order is the OWNER's choice: disposing under a parked
        # coordinator wakes its read with IOError, which {#read} folds into
        # retirement. T22 still removes the traps first -- see {#signal}'s
        # ordering asterisk.
        def dispose
          [@read, @write].each { |io| io.close unless io.closed? }
          self
        end

        def disposed? = @read.closed? && @write.closed?
      end
    end
  end
end
