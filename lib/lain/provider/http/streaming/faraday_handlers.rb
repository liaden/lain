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
        # The clock reaches a handler through a thread variable rather than an
        # argument, and that is forced twice over: the transports that call
        # {FaradayHandlers.build} (`Ollama::Transport#install_on_data`,
        # `Streaming#build_on_data_handler`) never see a Configuration, and
        # Faraday 1's `on_data` proc is handed no `env` to carry one on.
        #
        # ⚠️ THE LOAD-BEARING ASSUMPTION, enforced by nothing: **the Faraday
        # adapter dispatches `on_data` on the thread that called it.** True of
        # `:net_http`, which is the default and every provider's actual adapter
        # -- but `faraday_adapter` is a configuration OPTION, and an adapter
        # that ran the body callback on a thread of its own would make
        # {.current} answer {Null} on every chunk. Stall protection would then
        # be silently OFF with a green suite, which is the worst failure a
        # safety feature can have. The follow-up card is an explicit ambient
        # context whose absence at tick time is loud; until it lands, an adapter
        # change must be read against this paragraph.
        #
        # The stop/fire race is BOUNDED, not eliminated, and the difference
        # matters. `Thread#raise` is asynchronous: {#fire} queues the interrupt
        # while holding the mutex, so a monitor that expires in the instant
        # before the block returns delivers into a request that has already
        # finished. What the shared mutex guarantees is only that the target is
        # at-or-before {#stop}'s acquisition when the interrupt is issued -- so
        # it lands inside {#watch}'s teardown, where it is discarded, rather
        # than escaping to surface later as a stall on a stream that completed.
        #
        # Which leaves exactly THREE places the async raise can land, and that
        # enumeration is a property of the design rather than an observation
        # about it. {#stalled?} short-circuits on the suspension count, and that
        # count is written and read under the same mutex, so the monitor is
        # structurally incapable of firing while the caller holds a chunk. The
        # three are: blocked in the socket read (intended -- the stall is real);
        # blocked on the mutex in {#suspend}, which drops the chunk that just
        # arrived (also correct: the grace had already expired before it landed);
        # and blocked on the mutex in {#stop}, which {#unwatch} discards. Before
        # the delivery became a suspended REGION the exception could land
        # anywhere the request thread happened to be, the consumer's own code
        # included.
        class StallClock
          # Where {#watch} parks the clock for the `on_data` proc to find.
          VARIABLE = :lain_stall_clock

          # Named threads, and named per CLOCK: a survivor in a watchdog dump is
          # useless if every clock thread in the process shares one name, and the
          # request thread alone is not enough -- under `rake pspec` a worker is
          # one process with one main thread, so every sequential request on it
          # would collide again. The name carries both: which request thread, and
          # which of that thread's streams. Matching
          # {StreamingUpstream::THREAD_PREFIX}, which embeds its port for exactly
          # this reason -- so match on the prefix, never on equality.
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

          class << self
            # Runs the block with a clock installed for the calling thread, or
            # plainly when `grace` is nil -- the disable path.
            def watching(grace, &block)
              return yield if grace.nil?

              new(grace).watch(&block)
            end

            # The clock watching the calling thread's stream, or the Null one.
            def current = Thread.current.thread_variable_get(VARIABLE) || Null
          end

          # @param grace [Numeric] seconds of silence between chunks that mean
          #   the stream is dead. Kept as written rather than coerced, so the
          #   message prints the number the operator set;
          #   `Configuration#stream_stall_timeout=` is what guarantees it is a
          #   positive Numeric, and refuses anything else where a human is
          #   looking.
          # @param target [Thread] the thread blocked reading the body, which is
          #   the one the error has to surface in
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
          end

          # Installs this clock for the block, and takes it back down whatever
          # the block does -- including when the monitor itself is what ended it.
          def watch
            displaced = Thread.current.thread_variable_get(VARIABLE)
            Thread.current.thread_variable_set(VARIABLE, self)
            yield
          ensure
            unwatch(displaced)
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

          # The teardown, and both of its layers are load-bearing.
          #
          # The RESCUE is why a completed stream cannot be reported as a stalled
          # one. By the time {#stop} runs the block has either returned -- every
          # byte arrived, so there was no stall -- or raised something the caller
          # is already carrying and would rather see. A REAL stall never arrives
          # here: it is raised while the request thread is still blocked in the
          # socket read, and propagates out of {#watch}'s `yield`.
          #
          # The ENSURE restores the thread variable even when the teardown is
          # what raised, which it can: {#stop} blocks on the mutex a firing
          # monitor holds, and blocking is an interrupt-delivery point, so the
          # race lands exactly there. Without it the restore is skipped and this
          # clock leaks into the thread variable for the life of the thread --
          # breaking the invariant that no active {#watch} means {.current} is
          # {Null}, which `Streaming#flush_stream` depends on when it calls
          # `on_data` after `connection.post` has already returned.
          def unwatch(displaced)
            stop
          rescue StalledStreamError
            nil # the race, not a stall -- see above
          ensure
            Thread.current.thread_variable_set(VARIABLE, displaced)
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
          def stop
            @mutex.synchronize { @state = :finished }
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
              Thread.current.name = "#{THREAD_PREFIX} #{@target.object_id}.#{object_id}"
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
            @target.raise(StalledStreamError.new(stall_message))
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
