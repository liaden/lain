# frozen_string_literal: true

# Split from streaming.rb -- see that file's header. Building the `on_data` proc
# Faraday calls is a distinct concern from the SSE parsing the engine does with
# the bytes once they arrive, and the split keeps `Streaming` under the default
# `Metrics/ModuleLength` without loosening the cop.
#
# {StallClock} and {StalledStreamError} are Lain's, not upstream's, and they
# live here because this file is the one place in the stack that learns a body
# byte arrived. A Faraday middleware cannot see an inter-chunk gap -- by the
# time its `call` returns the body is finished -- so the clock is split at the
# only line where each half is knowable: the middleware
# ({Connection::MiddlewareStack::StallProtection}) owns the request's SCOPE,
# and the `on_data` proc below owns the TICKS.

module Lain
  class Provider
    module HTTP
      module Streaming
        # Raised when a response body goes silent for longer than the configured
        # inter-chunk grace while the connection is still open.
        #
        # An {HTTP::Error}, and deliberately NOT `Faraday::TimeoutError`,
        # `Timeout::Error` or `Faraday::ConnectionFailed`: all three sit in
        # {Connection::MiddlewareStack#retry_exceptions} and `retry_options`
        # retries `:post`, so a stall raised as one of them would answer a 300s
        # hang with four of them instead of bounding it. `HTTP::Error` is the
        # vendored slice's transport-failure root, is not itself in that
        # allowlist, and is what every arm's `wrapping_errors` already turns
        # into its own `APIError` -- so a stalled summarizer degrades exactly
        # the way an unreachable one does, rather than escaping every `rescue`
        # in the codebase as a novel type.
        class StalledStreamError < HTTP::Error; end

        # Bounds the silence BETWEEN body chunks, which is the only thing that
        # tells a stalled stream from a slow one -- a shorter TOTAL timeout is
        # the wrong instrument, because a local model thinking for six minutes
        # is a real shape.
        #
        # It ARMS ON THE FIRST TICK and not before: until a byte has arrived the
        # only bound is `request_timeout`, so prompt evaluation keeps the budget
        # it has always had and only the mid-stream case is bounded.
        #
        # The clock reaches a handler through the REQUEST the bytes belong to --
        # {#watch} parks it in `env.request.context` under {KEY} and {.for} reads
        # it back -- so "whose clock is this chunk's" is answered by the bytes'
        # own request and by nothing about whoever is delivering them. Neither a
        # thread variable nor fiber storage can answer it, and the fiber slot's
        # failure was silent: an adapter running the body callback on a fiber of
        # its own answered {Null} on every chunk, leaving stall protection OFF
        # with a green suite.
        #
        # The stop/fire race is BOUNDED, not eliminated. Both deliveries are
        # asynchronous, so {#fire} queues an interrupt while holding the mutex
        # and a monitor that expires in the instant before the block returns is
        # aiming at a request that has already finished. What the shared mutex
        # guarantees is that a fire can only be ISSUED while `@state` is
        # `:waiting`, and {#stop} ends that state under the same mutex -- so
        # every interrupt still in flight when {#stop} returns is one {#stop}
        # read `:stalled` for on the way past. That is the whole disarm, and why
        # nothing here needs a token on the exception.
        #
        # An async raise can land in five places and only four are wanted; the
        # unwanted one is the request's own post-body code, still inside
        # {#watch}'s `yield`, which the clock cannot tell from upstream silence.
        # It is bounded by the grace rather than designed away, and it is
        # reachable deliberately -- so do not write a clock spec that assumes it
        # away.
        #
        # The full account -- the two wrong slots and what each measured, the
        # adapter assumption that retires, all five landing places, and what is
        # still owed -- is in docs/providers/stall-clock.md.
        class StallClock
          # A key in the FARADAY REQUEST CONTEXT -- the request's own carrier
          # rather than an ambient slot.
          KEY = :lain_stall_clock

          # Named per THREAD, FIBER and CLOCK, because no single id is enough:
          # the thread attributes a survivor in a watchdog dump to a request,
          # the fiber tells two SIBLING streams sharing a reactor thread apart,
          # and the clock's own id separates two SEQUENTIAL streams on one fiber
          # -- without which every clock thread in a `pspec` worker collides.
          # Match on the prefix, never on equality.
          THREAD_PREFIX = "lain stall clock"

          # AWS's stalled-stream detector checks once a second; a grace of a few
          # hundred milliseconds needs a finer cadence than its own budget, or
          # it cannot be observed at all.
          POLL_FRACTION = 10.0
          POLL_BOUNDS = (0.01..1.0)

          # The clock a stream has when protection is off: it just runs the
          # delivery, so no chunk handler ever asks whether the feature is on.
          module Null
            module_function

            def receiving = yield
          end

          # Where a fired monitor sends its error. Captured by {#watch} on the
          # request's own fiber, because the monitor thread has neither half of
          # it: `Fiber.scheduler` is nil there, and `Fiber#raise` from it is a
          # `FiberError: fiber called across threads` rather than the error it
          # was handed.
          module Delivery
            # `fiber_interrupt` (Ruby 3.4) and `kernel_sleep` are OPTIONAL
            # `Fiber::Scheduler` hooks -- no part of that interface is mandatory
            # -- so the question is never "is a scheduler installed" but "can
            # this one take a deferred interrupt".
            HOOKS = %i[fiber_interrupt kernel_sleep].freeze

            # The reactor case. `fiber_interrupt` is the standard hook for
            # exactly this and the only primitive that crosses a thread boundary
            # to reach a fiber.
            ToFiber = Data.define(:fiber, :scheduler) do
              def interrupt(error) = scheduler.fiber_interrupt(fiber, error)

              # One turn of the event loop, which is where a queued interrupt is
              # delivered. Taken only when {StallClock#stop} saw the monitor
              # fire, so the fiber is never parked here waiting for an interrupt
              # that is not coming.
              def collect = scheduler.kernel_sleep(0)
            end

            # No usable scheduler, so the request is a thread blocked in a socket
            # read and `Thread#raise` is what it always was. Nothing to collect:
            # the runtime delivers at the target's next checkpoint, and {#stop}'s
            # mutex acquisition is one.
            #
            # This is also the deliberate answer for a scheduler that lacks the
            # hooks. It lands badly on a reactor -- the raise reaches the whole
            # reactor thread rather than the one fiber -- but it still BOUNDS
            # the stall, and an unbounded stall with a green suite is the worse
            # of the two failures by this class's own standard.
            ToThread = Data.define(:thread) do
              def interrupt(error) = thread.raise(error)

              def collect = nil
            end

            # A clock that has been built but not yet watched has no request to
            # deliver to. It sends nowhere rather than being a nil for the
            # monitor thread to call `interrupt` on.
            module Null
              module_function

              def interrupt(_error) = nil

              def collect = nil
            end

            module_function

            # `nil` answers `respond_to?` false, so "no scheduler" needs no
            # branch of its own.
            def here(thread, scheduler: Fiber.scheduler)
              return ToThread.new(thread:) unless HOOKS.all? { |hook| scheduler.respond_to?(hook) }

              ToFiber.new(fiber: Fiber.current, scheduler:)
            end
          end

          class << self
            # Runs the block with a clock installed on `env`'s request, or
            # plainly when `grace` is nil -- the disable path.
            def watching(grace, env, &block)
              return yield if grace.nil?

              new(grace).watch(env, &block)
            end

            # The clock watching this env's stream, or the Null one.
            #
            # Every nil this navigates past is a REAL caller rather than
            # defensiveness, and both of them are `Streaming#flush_stream`, which
            # calls `on_data` once more after `connection.post` has returned: it
            # hands over `response.env`, nil until `Faraday::Response#finish`
            # runs, and on the ordinary path a finished env whose context
            # {#unwatch} has already emptied. Both answer {Null}, which is what
            # stops a post-body flush ticking a clock that has stopped.
            #
            # The leniency ends here. `v2_on_data` reads `env.status` unguarded a
            # line further down, so an unfinished response is still a loud
            # NoMethodError rather than a silent nothing.
            #
            # ⚠️ STILL OWED: an absent clock at tick time answers {Null} rather
            # than raising, so a stack assembled without
            # {Connection::MiddlewareStack::StallProtection} is unprotected
            # FOREVER and silently -- the failure mode this whole class exists
            # to answer, with a green suite.
            def for(env)
              request = env&.request
              request&.context&.fetch(KEY, nil) || Null
            end
          end

          # @param grace [Numeric] seconds of silence between chunks that mean
          #   the stream is dead. Kept as written rather than coerced, so the
          #   message prints the number the operator set;
          #   `Configuration#stream_stall_timeout=` is what guarantees it is a
          #   positive Numeric, and refuses anything else where a human is
          #   looking.
          # @param target [Thread] the thread blocked reading the body. It names
          #   the monitor, and it is where the error surfaces when no scheduler
          #   is installed -- with one, {Delivery} sends to the fiber instead.
          # @param clock [#call] monotonic seconds; the repo's one time source,
          #   taken as a default the way every other timing seam takes it
          def initialize(grace, target: Thread.current, clock: RunClock::MONOTONIC)
            @grace = grace
            @target = target
            @clock = clock
            @mutex = Mutex.new
            @state = :waiting
            # A COUNT, not a flag: a nested {#receiving} would un-suspend on the
            # inner `ensure` while the outer delivery was still running.
            # Unreachable on today's `on_data` path, and cheaper to make
            # impossible than to remember.
            @suspensions = 0
            @last = now
            @delivery = Delivery::Null
          end

          # Installs this clock on the request for the block, and takes it back
          # down whatever the block does -- including when the monitor itself is
          # what ended it.
          #
          # `env.request` is read WITHOUT a guard, unlike {.for}: this is the
          # middleware's env, which Faraday built and always populates, so a nil
          # here is a broken stack. A clock that quietly declined to install
          # would be stall protection silently off, which is the failure this
          # whole class is written against.
          #
          # The context is REPLACED rather than mutated. `Connection#build_request`
          # does `req.options = options.dup` and `Faraday::Options` does not
          # override `dup`, so that is Struct's SHALLOW dup and
          # `env.request.context` IS the connection's own `options.context`
          # object. Measured: an in-place `context[KEY] = self` writes onto the
          # connection, and every later request built from it starts life
          # holding an earlier one's finished clock. The simplification is the
          # trap here.
          #
          # The owner and the delivery are captured HERE and not in the
          # constructor, because this is the line that claims a request:
          # `Fiber.current` and `Fiber.scheduler` are only the right pair when
          # read on the fiber that is about to block reading the body.
          def watch(env)
            request = env.request
            displaced = request.context
            request.context = (displaced || {}).merge(KEY => self)
            @owner = Fiber.current
            @delivery = Delivery.here(@target)
            yield
          ensure
            unwatch(request, displaced)
          end

          # One body chunk arrived, and the consumer is about to be handed it.
          # The first call also starts the monitor, which is what keeps a silent
          # prompt evaluation on the request timeout.
          #
          # The clock is SUSPENDED for the duration of the block, because the
          # grace measures the UPSTREAM's silence and the consumer runs on this
          # same thread between two chunks arriving. Measured before this
          # existed: a body already sitting whole in the receive queue was
          # reported as "no bytes for 0.5s, with the connection still open"
          # purely because the caller slept inside `on_chunk`. Ticking only on
          # the way out would have fixed the NEXT gap and left that one, since
          # the consumer's own call can outlast the grace by itself -- so the
          # window is a region, not two instants. A consumer that blocks forever
          # therefore never trips this, which is right: that is a consumer bug,
          # not the upstream's silence to answer for.
          def receiving
            suspend
            yield
          ensure
            resume
          end

          private

          # The teardown, and all three of its layers are load-bearing.
          #
          # The COLLECT is what makes a deferred interrupt safe: a fire {#stop}
          # learns about is exactly a fire whose interrupt may not have been
          # delivered yet, so the fiber takes one turn of the event loop to
          # accept it HERE rather than in whatever it does next.
          #
          # The RESCUE is why the teardown cannot report a completed stream as a
          # stalled one. By the time {#stop} runs the block has either returned
          # or raised something the caller would rather see; a REAL stall never
          # arrives here, since it is raised while the request is still blocked
          # in the socket read and propagates out of {#watch}'s `yield`. The
          # boundary of that claim is the unwanted landing place -- an interrupt
          # arriving while post-body code is still inside the `yield` is ABOVE
          # this rescue.
          #
          # The ENSURE is a REMOVAL rather than a tidy-up.
          # `Faraday::Response#finish` keeps the very Env the stack ran on, so
          # `response.env.request.context` IS the hash this line writes to, and
          # `Streaming#flush_stream` calls `on_data` once more through it after
          # `connection.post` returns. A clock merely STOPPED and left behind
          # would be found by that flush and ticked, restarting its own monitor
          # against a request that no longer exists.
          #
          # It has to run even when the teardown is what raised, which it can
          # twice over: {#stop} blocks on the mutex a firing monitor holds, and
          # the collect is where a queued interrupt lands by construction.
          def unwatch(request, displaced)
            @delivery.collect if stop
          rescue StalledStreamError
            nil # the race, not a stall -- see above
          ensure
            # Safe navigation keeps a broken stack LOUD rather than masking it: a
            # nil request means {#watch}'s own `env.request` has already raised,
            # and a second NoMethodError from here would bury the first.
            request&.context = displaced
          end

          def suspend
            @mutex.synchronize do
              @last = now
              @suspensions += 1
              @monitor ||= start_monitor
            end
          end

          def resume
            @mutex.synchronize do
              @last = now
              @suspensions -= 1
            end
          end

          # The join is in an `ensure` because taking the mutex is where a
          # firing monitor's interrupt lands (see {#watch}) -- and a teardown
          # that skipped the join on the one path where the monitor is most
          # certainly alive would leave the thread to be collected rather than
          # reaped.
          #
          # @return [Boolean] whether the monitor fired. Read under the mutex
          #   that {#fire} issues its interrupt beneath, which is what makes it
          #   the exact question "may an interrupt still be in flight?".
          def stop
            @mutex.synchronize do
              fired = @state == :stalled
              @state = :finished
              fired
            end
          ensure
            @monitor&.join
          end

          # The one thread, argued for as `.rubocop.yml`'s census asks. A stalled
          # stream is defined by the ABSENCE of a callback, so nothing on the
          # request thread can notice it -- that thread is blocked in a socket
          # read, which is exactly the observation being made. Owned end to end:
          # started on the first byte, joined by {#stop} in {#watch}'s ensure,
          # touching no state outside this instance's mutex.
          def start_monitor
            Thread.new do
              Thread.current.name = "#{THREAD_PREFIX} #{@target.object_id}.#{@owner.object_id}.#{object_id}"
              Thread.current.report_on_exception = false
              sleep(poll_interval) while sweep
            end
          end

          # One look at the clock; answers whether to keep looking. Firing ends
          # the loop by moving the state off `:waiting`, so the error is raised
          # exactly once.
          def sweep
            @mutex.synchronize do
              fire if @state == :waiting && stalled?
              @state == :waiting
            end
          end

          def fire
            @state = :stalled
            @delivery.interrupt(StalledStreamError.new(stall_message))
          end

          # The suspension count first, and it short-circuits: while the consumer
          # holds the chunk there is no upstream silence to measure. Read under
          # the same mutex {#suspend} writes it under, which is what makes the
          # delivery window exception-free rather than merely narrow.
          def stalled? = @suspensions.zero? && idle > @grace

          def idle = now - @last

          def now = @clock.call

          # Wake often enough that the report lands a fraction past the grace
          # rather than a whole grace late, and never more often than that.
          def poll_interval = (@grace / POLL_FRACTION).clamp(POLL_BOUNDS)

          def stall_message
            "stalled stream: no bytes for #{format("%.1f", idle)}s, past the #{@grace}s " \
              "stream_stall_timeout, with the connection still open"
          end
        end

        # Builds the Faraday `on_data` proc.
        module FaradayHandlers
          module_function

          def build(on_chunk:, on_failed_response:)
            v2_on_data(on_chunk, on_failed_response)
          end

          # {StallClock#receiving} wraps the whole delivery -- the status branch
          # included on purpose, since a failed response's body is bytes too and
          # a slow error body is not a stall.
          #
          # The clock comes off the ENV, which is what makes this proc
          # indifferent to the fiber Faraday runs it on. A chunk therefore ticks
          # the clock of the request it arrived with, the empty end-of-body
          # chunk included: `stream_response` sends `on_data.call(+"", 0, self)`
          # when a body yielded nothing, so that one ARMS a clock that was never
          # armed. Decided rather than stumbled into, and harmless -- it lands
          # an instant before {StallClock#watch}'s ensure stops the clock, so no
          # grace can elapse behind it.
          #
          # `env.status`, not `env&.status`: this proc has TWO callers and only
          # one is Faraday, whose `stream_response` always passes a real env.
          # The second is Lain's own {Streaming#flush_stream}, which hands over
          # `response.env` -- nil until `#finish` runs -- and the deleted
          # safe-nav used to route that (nil != 200) to `on_failed_response`
          # instead of crashing. Production-safe today, since the net_http
          # adapter finishes the env before `connection.post` returns, and
          # pinned by a named spec so a future adapter that CAN reach it fails
          # by name rather than by bare crash.
          def v2_on_data(on_chunk, on_failed_response)
            proc do |chunk, _bytes, env|
              StallClock.for(env).receiving do
                if env.status == 200
                  on_chunk.call(chunk, env)
                else
                  on_failed_response.call(chunk, env)
                end
              end
            end
          end
        end
      end
    end
  end
end
