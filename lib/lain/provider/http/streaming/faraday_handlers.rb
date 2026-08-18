# frozen_string_literal: true

# Split from streaming.rb -- see that file's header. A real, separate module:
# Faraday's `on_data` callback arity differs between major versions
# (`|chunk, size|` on 1, `|chunk, bytes, env|` on 2), and picking the right
# proc shape is a distinct concern from the SSE parsing the engine does with
# the bytes once they arrive. Extracting it also keeps `Streaming` itself
# under the default `Metrics/ModuleLength` without loosening the cop. Vendored
# verbatim from upstream's nested `RubyLLM::Streaming::FaradayHandlers`.
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
        # retries `:post`, so a stall raised as one of them would answer F7a's
        # 300s hang with four of them instead of bounding it. `HTTP::Error` is
        # the vendored slice's transport-failure root, is not itself in that
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
        # It ARMS ON THE FIRST TICK and not before, which is the whole of the
        # first-byte/inter-chunk split: until a byte has arrived the only bound
        # is `request_timeout`, so prompt evaluation keeps the budget it has
        # always had, and only the mid-stream case F7a actually hit is bounded.
        #
        # The clock reaches a handler through {KEY} rather than through an
        # argument, and that is forced twice over: the transports that call
        # {FaradayHandlers.build} (`Ollama::Transport#install_on_data`,
        # `Streaming#build_on_data_handler`) never see a Configuration, and
        # Faraday 1's `on_data` proc is handed no `env` to carry one on.
        #
        # It belongs to the FIBER and not to the thread, and both halves of this
        # class turn on that. Lain streams a parent turn and a subagent turn as
        # sibling tasks on ONE reactor thread (`cli/repl.rb`'s `Sync`,
        # `agent/tool_runner.rb#gather`'s fan-out), so a thread variable gave two
        # live streams one slot to fight over: the second {#watch} displaced the
        # first, the first's chunks then ticked the second's clock, and the
        # displaced clock -- never ticked again -- fired against a stream that
        # was healthy. Fiber storage is per fiber and copy-on-write, so two
        # concurrent streams simply hold two clocks. That is also what re-argues
        # {#unwatch}'s restore for NON-LIFO completion, and it simplifies rather
        # than complicates: sibling tasks do not nest, and with a slot each there
        # is nothing for a sibling's teardown to put back.
        #
        # But the slot is INHERITED, and that is the half a reader will get
        # wrong. `Fiber[]` storage is copied into every fiber and thread born
        # under a live watch -- `Fiber.new`, `task.async`, `Thread.new` alike --
        # so a child holds its parent's clock without ever having watched it, and
        # `displaced` is NOT reliably nil even for a fiber's outermost watch.
        # Presence in the slot therefore proves nothing, and two things followed
        # from believing it did: a child streaming with protection off ticked the
        # parent's clock, because {.watching} with a nil grace neither installs
        # nor clears; and a child whose own watch ended restored the parent's
        # clock into its own storage, so {.current} answered a live clock exactly
        # where `Streaming#flush_stream` needs {Null}. {.current} asks
        # {#watching_here?} instead: a clock answers to the fiber that watched it
        # and to no other, which makes an inherited copy a stranger's and leaves
        # the restore free to put back whatever it found.
        #
        # ⚠️ THE LOAD-BEARING ASSUMPTION, enforced by nothing: **the Faraday
        # adapter dispatches `on_data` on the FIBER that called it.** True of
        # `:net_http`, which is the default and every provider's actual adapter
        # -- but `faraday_adapter` is a configuration OPTION, and an adapter that
        # ran the body callback on a fiber or a thread of its own would make
        # {.current} answer {Null} on every chunk. Stall protection would then be
        # silently OFF with a green suite, which is the worst failure a safety
        # feature can have.
        #
        # What NARROWS the assumption is the OWNERSHIP check in {.current}, not
        # the move to fiber storage -- and getting that attribution right is the
        # point of this paragraph, because it is what a future `faraday_adapter`
        # change gets read against. Under fiber scoping ALONE a child-fiber
        # adapter still worked: the child inherited the slot copy-on-write and
        # ticked its parent's clock, which for a body callback dispatched on a
        # child fiber is the right answer. Ownership takes that away, measured:
        # 0.4s of silence against a 0.15s grace, undetected. The trade was made
        # knowingly -- protection lost for a hypothetical adapter, in exchange
        # for the session kill this card exists to close, with `:net_http` the
        # only adapter anyone actually configures. Fiber storage delivers only
        # the AMBIENT half of the follow-up this paragraph used to point at; the
        # loud half is still owed, because an absent clock at tick time is still
        # a {Null} rather than an error.
        #
        # The stop/fire race is BOUNDED, not eliminated. BOTH deliveries are
        # asynchronous -- `Thread#raise` and `Fiber::Scheduler#fiber_interrupt`
        # alike -- so {#fire} queues an interrupt while holding the mutex and a
        # monitor that expires in the instant before the block returns is aiming
        # at a request that has already finished. What the shared mutex
        # guarantees is that a fire can only be ISSUED while `@state` is
        # `:waiting`, and {#stop} ends that state under the same mutex: so every
        # interrupt still in flight when {#stop} returns is one {#stop} knows
        # about, because it read `:stalled` on the way past. That is the whole
        # disarm, and it is why nothing here needs a token on the exception.
        #
        # Which leaves FIVE places the async raise can land, and only four of
        # them are wanted. {#stalled?} short-circuits on the suspension count,
        # written and read under the same mutex, so the monitor cannot fire while
        # the consumer holds a chunk -- which matters MORE under a reactor, where
        # the consumer's own code may yield to the event loop mid-chunk. The five
        # are:
        #
        # 1. blocked in the socket read -- intended, the stall is real;
        # 2. blocked on the mutex in {#suspend}, which drops the chunk that just
        #    arrived (also correct: the grace had already expired before it
        #    landed);
        # 3. blocked on the mutex, or on the monitor's join, in {#stop} -- which
        #    {#unwatch} discards;
        # 4. {Delivery::ToFiber#collect}, which closes the reactor's own hazard.
        #    `fiber_interrupt` is DEFERRED: the reactor delivers when it next
        #    resumes the fiber, and a queued interrupt cannot be recalled, so
        #    without this place a stream completing on the grace boundary would
        #    be interrupted in its NEXT tool call or its next turn. A completing
        #    stream that knows an interrupt is coming therefore spends one turn
        #    of the event loop taking delivery of it;
        # 5. ⚠️ the request's own post-body code, still inside {#watch}'s `yield`
        #    after the last {#receiving} has resumed. The suspension count does
        #    not cover it -- it guards only the region a chunk is being delivered
        #    in -- and neither does {#unwatch}, which has not been reached yet.
        #    This one is UNWANTED and is not designed away: the clock gets no
        #    end-of-body signal, so it cannot tell the middleware stack unwinding
        #    below {Connection::MiddlewareStack::StallProtection} from upstream
        #    silence, and it charges that tail the same grace it charges a gap.
        #    Bounded by the grace, therefore: at the shipped 30s the tail would
        #    have to run silent for 30s, which is why it has never been observed
        #    on a real stream. It is easy to reach deliberately -- a `Thread.pass`
        #    tail took it 140 times in 300 rounds at a twentieth-second grace and
        #    133 at a hundredth, in one run, and the rate wanders because it is a
        #    race -- so do not write a clock spec that assumes it away. On the
        #    reactor path it is closed anyway: the same tail completed 300 of 300
        #    under {Delivery::ToFiber}, because {#collect} takes delivery unless
        #    the tail reaches the event loop first. Closing it wants an
        #    end-of-body tick, which is a change to the split this file's header
        #    describes rather than a change to this class.
        #
        # Before the delivery became a suspended REGION the exception could land
        # anywhere the request happened to be, the consumer's own code included.
        class StallClock
          # Where {#watch} parks the clock for the `on_data` proc to find, in
          # FIBER storage -- see the class doc for why the thread cannot own it.
          KEY = :lain_stall_clock

          # Named threads, and named per FIBER and per CLOCK: a survivor in a
          # watchdog dump is useless if every clock thread in the process shares
          # one name, and no single id is enough. The thread attributes it to a
          # request; the fiber is what tells two SIBLING streams apart, since
          # they share a reactor thread and that is the whole subject of this
          # class; the clock's own id keeps two SEQUENTIAL streams on one fiber
          # apart -- and under `rake pspec` a worker is one process with one main
          # thread, so without it every clock thread in the worker collides.
          # Matching {StreamingUpstream::THREAD_PREFIX}, which embeds its port
          # for exactly this reason -- so match on the prefix, never on equality.
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
            # hooks. It lands badly on a reactor -- that is F10 -- but it still
            # BOUNDS the stall, and an unbounded stall with a green suite is the
            # worse of the two failures by this class's own standard.
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
            # Runs the block with a clock installed for the calling fiber, or
            # plainly when `grace` is nil -- the disable path.
            def watching(grace, &block)
              return yield if grace.nil?

              new(grace).watch(&block)
            end

            # The clock watching the calling fiber's stream, or the Null one.
            #
            # OWNERSHIP, not presence, and that is forced by the storage: fiber
            # storage is inherited copy-on-write by every fiber and thread born
            # under a live watch, so the slot can hold a clock this fiber never
            # watched. Ticking a stranger's clock resets a `@last` it knows
            # nothing about, which is how a real stall would be masked.
            def current
              clock = Fiber[KEY]
              clock&.watching_here? ? clock : Null
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

          # Installs this clock for the block, and takes it back down whatever
          # the block does -- including when the monitor itself is what ended it.
          #
          # The owner and the delivery are captured HERE and not in the
          # constructor, because this is the line that claims a request:
          # `Fiber.current` and `Fiber.scheduler` are only the right pair when
          # read on the fiber that is about to block reading the body.
          def watch
            displaced = Fiber[KEY]
            Fiber[KEY] = self
            @owner = Fiber.current
            @delivery = Delivery.here(@target)
            yield
          ensure
            unwatch(displaced)
          end

          # Whether the calling fiber is the one that watched this clock. Public
          # because {.current} is the only caller and it asks from outside the
          # instance -- see the ownership note there for why presence is not the
          # question.
          #
          # `@owner` is deliberately never cleared, and clearing it would look
          # like tidying and break the same-fiber NESTED case: the outer clock
          # has to keep answering true once the inner one has restored it.
          # Nothing leaks -- {.current} reads the slot first, so a finished clock
          # is unreachable through it, and `nil.equal?` answers false before the
          # first watch.
          def watching_here? = @owner.equal?(Fiber.current)

          # One body chunk arrived, and the consumer is about to be handed it.
          # The first call also starts the monitor, which is what keeps a silent
          # prompt evaluation on the request timeout.
          #
          # The clock is SUSPENDED for the duration of the block, because the
          # grace measures the UPSTREAM's silence and the consumer runs on this
          # same thread between two chunks arriving. Measured before this
          # existed: a body already sitting whole in the receive queue was
          # reported as "no bytes for 0.5s, with the connection still open"
          # purely because the caller slept inside `on_chunk`. The upstream had
          # finished; the message blamed it. Ticking only on the way out would
          # have fixed the NEXT gap and left that one, since the consumer's own
          # call can outlast the grace by itself -- so the window is a region,
          # not two instants. A consumer that blocks forever therefore never
          # trips this, which is right: that is a consumer bug, not a dead
          # stream, and it is not the upstream's silence to answer for.
          def receiving
            suspend
            yield
          ensure
            resume
          end

          private

          # The teardown, and all three of its layers are load-bearing.
          #
          # The COLLECT is what makes a deferred interrupt safe. {#stop} answers
          # whether the monitor fired, and a fire that {#stop} learns about is
          # exactly a fire whose interrupt may not have been delivered yet -- so
          # the fiber takes one turn of the event loop to accept it HERE, rather
          # than leaving it to land in whatever the fiber does next. Without a
          # reactor there is nothing to collect and this is a no-op.
          #
          # The RESCUE is why the TEARDOWN cannot report a completed stream as a
          # stalled one. By the time {#stop} runs the block has either returned
          # -- every byte arrived, so there was no stall -- or raised something
          # the caller is already carrying and would rather see. A REAL stall
          # never arrives here: it is raised while the request is still blocked
          # in the socket read, and propagates out of {#watch}'s `yield`.
          #
          # Note the boundary of that claim, which is landing place 5 in the
          # class doc: an interrupt that arrives while the request's own
          # post-body code is still inside the `yield` is ABOVE this rescue and
          # escapes as a stall on a stream that completed. The teardown is not
          # where that one can be caught.
          #
          # The ENSURE restores the storage even when the teardown is what
          # raised, which it can twice over: {#stop} blocks on the mutex a firing
          # monitor holds, and the collect is where a queued interrupt lands by
          # construction. Without it the restore is skipped and this clock leaks
          # into fiber storage for the life of the fiber -- breaking the
          # invariant that no active {#watch} means {.current} is {Null}, which
          # `Streaming#flush_stream` depends on when it calls `on_data` after
          # `connection.post` has already returned.
          def unwatch(displaced)
            @delivery.collect if stop
          rescue StalledStreamError
            nil # the race, not a stall -- see above
          ensure
            Fiber[KEY] = displaced
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
          # read, which is exactly the observation being made. It is owned end to
          # end: started on the first byte, joined by {#stop} in {#watch}'s
          # ensure, and it touches no state outside this instance's mutex.
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
          # holds the chunk there is no upstream silence to measure, and `now` is
          # not even asked for. Read under the same mutex {#suspend} writes it
          # under, which is what makes the delivery window exception-free rather
          # than merely narrow -- see the class doc.
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

        # Builds Faraday `on_data` procs for Faraday 1 vs 2.
        module FaradayHandlers
          module_function

          def build(faraday_v1:, on_chunk:, on_failed_response:)
            if faraday_v1
              v1_on_data(on_chunk)
            else
              v2_on_data(on_chunk, on_failed_response)
            end
          end

          # {StallClock#receiving} wraps the whole delivery -- including the
          # status branch on purpose, since a failed response's body is bytes
          # too and a slow error body is not a stall.
          def v1_on_data(on_chunk)
            proc do |chunk, _size|
              StallClock.current.receiving { on_chunk.call(chunk, nil) }
            end
          end

          def v2_on_data(on_chunk, on_failed_response)
            proc do |chunk, _bytes, env|
              StallClock.current.receiving do
                if env&.status == 200
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
