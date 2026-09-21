# frozen_string_literal: true

# This file is its subtree's index. Neither child reopens {Admission} nor
# resolves its constants at load time, so the position here is convention
# rather than constraint -- probed, not assumed.

module Lain
  class Provider
    # A provider's CAPACITY, as one object: at most `width` callers inside one
    # RESOLVED ENDPOINT at a time.
    #
    # The absent concept this fills: nothing owned capacity, so the harness put
    # two requests on a one-slot local server and then read the silence it had
    # caused itself as a dead stream. Admission wraps {Provider#complete} and
    # nothing below it: `#complete` encloses the whole stream and the stall
    # clock arms on the FIRST TICK rather than at send, so a request waiting
    # here has no clock installed and cannot time out while it queues.
    #
    # == The key is the resolved endpoint, not the flag
    #
    # There is one `--api-base` for every tier, so
    # `--provider anthropic --summarizer-provider ollama` gives `api_base == nil`
    # on BOTH sides -- a key of "api_base" would serialise a hosted turn behind a
    # local summary. Each provider resolves its own endpoint, and that string is
    # the key. It is also why {.for} exists rather than injection:
    # {Oracle::SecretRead.tier} constructs its provider bare and deliberately
    # takes no seam, so admission has to be reachable without one.
    #
    # == Why this is hand-rolled and not an Async::Semaphore
    #
    # Because `Provider#complete` is reached from TWO OS threads. On the
    # `--nvim` path {CLI::ResendBridge}'s dispatch runs on the resend-worker
    # thread and reaches `@agent.run` -- and {Agent#run} is `Sync { }`, which
    # spins up a SECOND reactor when there is none to join. Meanwhile the eager
    # oracle, the span summarizer and the window probes run on the conductor's.
    #
    # `Async::Semaphore` is single-reactor by construction: `@count` is
    # unsynchronised, and `FiberNode#resume` calls `Fiber.scheduler.resume` on
    # the RELEASING thread's scheduler. Measured, all three at once: the
    # `FiberError: fiber called across threads` lands in the releasing fiber --
    # the agent's turn, killed by an unrelated resend -- the waiting thread is
    # still parked after a 5s join, and `#release` decrements before it resumes,
    # so the gate is left at zero with a waiter still queued and SILENTLY STOPS
    # GATING. The last example in the spec is that measurement, kept.
    #
    # So: a Mutex-guarded counter, correct across threads, and a poll that
    # sleeps between attempts. `ConditionVariable#wait` is deliberately NOT used
    # -- it blocks the whole reactor thread, the failure that once froze the
    # reactor so the approval queue's fail-closed timer could never fire. A
    # plain `Kernel#sleep` is the opposite: under Async's scheduler it is hooked
    # and yields the fiber (measured: 20 ticks of a 10ms ticker across one 200ms
    # sleep), and off a reactor it blocks only the calling thread. So this file
    # needs no ASYNC machinery at all. The precise claim, though: yielding
    # rather than blocking is a property of ASYNC's scheduler, and nothing here
    # enforces that some other fiber scheduler implements `kernel_sleep`.
    #
    # == There is no fairness, and that is worth stating
    #
    # Waiters are not queued: each polls independently, so whoever happens to
    # look when a slot frees takes it. A caller arriving LATE can therefore be
    # served ahead of one already waiting -- measured, two waiters arriving
    # 150ms later beat four already queued. Silence would read as FIFO, so: it
    # is not. The deadline bounds any one caller's exposure, and a saturated
    # endpoint is the pathology admission exists to report rather than to
    # schedule around.
    class Admission
      # No slot came free inside the acquire deadline. Named for the ENDPOINT,
      # because the interesting fact is which server is saturated. Raised
      # before the round trip is dispatched at all, so nothing reached the wire.
      class Busy < Error
        include PreWire
      end

      # {#try_enter}'s answer when the endpoint is busy. A sentinel rather than
      # nil, because nil is a legitimate thing for an admitted block to return
      # and a caller must be able to tell "refused" from "ran, gave nothing".
      REFUSED = :"lain.admission.refused"

      # One in flight per LOCAL endpoint. Not probed: reading a server's real
      # parallelism is a provider-specific probe on a path that must stay
      # synchronous, and 1 is correct for every local server this bench runs.
      #
      # Read the LOCAL qualifier as load-bearing. Applying the same 1 to a
      # hosted endpoint would serialise concurrent SUBAGENTS, which run at once
      # over one shared provider -- a throughput regression, and the same harm
      # as serialising a hosted turn behind a local summary wearing the hosted
      # endpoint's face. So {.build} applies this width only where {.local?}
      # holds and hands everything else the unbounded {Null}.
      #
      # == What this costs a LOCAL subagent fan-out, which is a real cost
      #
      # Local children no longer overlap: N siblings over one ollama queue, each
      # against its own {DEFAULT_DEADLINE}. A fan-out that used to run slow can
      # now RAISE {Busy} at sibling N -- a behaviour change, not merely a
      # slowdown. The render path rescues {Lain::Error} and {Oracle::Eager}
      # contains what a fire raises, but A SUBAGENT'S OWN TURN IS NEITHER, so
      # the refusal surfaces as that child's failure. That is why the deadline
      # is 300s rather than something a busy fan-out would trip casually, and
      # why {ENV_KEY} exists.
      DEFAULT_WIDTH = 1

      # Between polls for a free slot. {Approval::QueueSurface::DEFAULT_POLL_INTERVAL}'s
      # value and its reason -- the sleep is a scheduler yield, not a wall-clock
      # stall -- reused rather than restated.
      POLL_INTERVAL = Approval::QueueSurface::DEFAULT_POLL_INTERVAL

      # The longest a caller waits for a slot before being refused by name.
      #
      # One `request_timeout`, the longest a legitimate holder's single attempt
      # can take -- so a longer wait means the holder is retrying or wedged
      # rather than working. It has to be bounded at all because the holder's
      # own ceiling is ~20 minutes, not 300s: faraday-retry sits INSIDE the
      # connection with `:post` in its retry methods, so one hung endpoint holds
      # for four `request_timeout`s.
      DEFAULT_DEADLINE = 300.0

      # What a caller that never queued reports. Exactly zero rather than a
      # measured epsilon: the wait IS the time spent polling, so a caller
      # admitted on its first attempt waited none, and the admission journal can
      # tell "did not queue" from "queued briefly" without picking a threshold.
      #
      # THE DISTINCTION IS EXACT; THE MAGNITUDE IS NOT. A reported wait is
      # quantised to {POLL_INTERVAL}, because a waiter only learns the slot is
      # free when it next wakes -- measured 0.0501s against a ~0.040s true
      # queue. So a consumer must present it as "queued, at ~50ms resolution"
      # rather than as a measurement.
      NO_WAIT = 0.0

      # `0` selects the Null arm; a positive `N` sets the width. Either way it
      # overrides the locality rule in BOTH directions -- `0` unbounds a local
      # endpoint, `N` gates a hosted one -- so it is also how a hosted endpoint
      # gets a ceiling when someone wants one. The env-only shape (no CLI flag)
      # is `provider/http/configuration.rb:127-131`'s.
      #
      # It is a PROCESS-START switch, not a rescue. {.for} memoises per endpoint
      # and pins whatever the env said at that endpoint's first resolution, so
      # exporting `0` cannot free a session that is already wedged.
      ENV_KEY = "LAIN_PROVIDER_CONCURRENCY"

      # One admission per resolved endpoint, process-wide, behind a Mutex: the
      # registry is reached from both threads named in this class's header.
      #
      # Never evicted, deliberately rather than as a leak: the key set is the
      # endpoints one process talks to, and an admission that vanished under a
      # live holder would stop gating exactly when it mattered. {.reset!} is the
      # one way to clear it.
      #
      # Class-level ivars rather than constants because this state is MEANT to
      # mutate; `Style/MutableConstant`'s `.freeze` autocorrect would break the
      # memoisation below. The disable answers the same way: the hazard
      # `ThreadSafety/MutableClassInstanceVariable` names is real and is closed
      # by the lock on the very next line, which the cop cannot see.
      @registry = {} # rubocop:disable ThreadSafety/MutableClassInstanceVariable
      @registry_lock = Mutex.new

      # @return [String] the resolved endpoint this gate governs
      attr_reader :endpoint
      # @return [Integer] how many callers may be inside at once
      attr_reader :width
      # @return [Float] the acquire deadline, in seconds
      attr_reader :deadline
      # Readable so an observer can describe the gate it wraps instead of
      # assuming {POLL_INTERVAL} -- a decorator that guessed would report a
      # resolution the gate does not run at.
      # @return [Float] seconds between attempts while waiting
      attr_reader :poll_interval

      # The admission for one resolved endpoint, built once and shared.
      #
      # KEYED ON {.canonical}, NOT ON THE STRING IT WAS HANDED. A raw-string key
      # defeats {DEFAULT_WIDTH}'s own argument -- that every loopback spelling
      # counts local *because they are one server* -- by handing each spelling
      # its own slot. Measured before it was fixed: a chat provider on
      # `--api-base http://127.0.0.1:11434` and the bare `Provider::Ollama.new`
      # that {Oracle::SecretRead.tier} constructs overlapped two round trips on
      # one ollama.
      #
      # == FIRST DECLARATION WINS -- among DECLARATIONS. SILENCE IS NOT ONE.
      #
      # A declared width is read at build time and PINNED BY THE MEMOISATION,
      # never folded into the key. So a second caller declaring a different
      # number for an endpoint that already has a REAL gate is handed the gate
      # that exists: a later declaration may not widen a gate other callers are
      # already inside.
      #
      # Silence pinning {Null} is not a widening to preserve, though, it is the
      # absence of a claim -- the first caller to resolve a hosted endpoint
      # WITHOUT a width would otherwise leave every later round trip in the
      # process unbounded against a plan that permits 3, with no error and
      # nothing journaled. So A DECLARATION REPLACES AN UNBOUNDED ENTRY THAT IS
      # IDLE, and nothing else; see {.supersedable?}.
      #
      # @param endpoint [String] the endpoint the provider resolved for itself
      # @param width [Integer, nil] what the caller knows its server's capacity
      #   to be, for a hosted endpoint {Endpoint.local?} cannot classify; nil
      #   when the caller does not know
      # @return [Admission, Admission::Null]
      # @raise [Error] when `width` is neither nil nor a positive Integer
      def self.for(endpoint:, width: nil)
        declared = declared_width(width, endpoint)
        key = canonical(endpoint)
        @registry_lock.synchronize do
          @registry[key] = build(key, declared) if supersedable?(@registry[key], declared)
          @registry[key]
        end
      end

      # Whether {.build} should run for this key at all. Four conditions, each
      # load-bearing.
      #
      # A WIDTH WAS DECLARED, because silence supersedes nothing.
      #
      # {ENV_KEY} SAID NOTHING -- an env-set arm is the operator's choice.
      # Without this clause the off switch's {Null} is supersedable FOREVER
      # ({.build} re-reads the env, answers another {Null}, which qualifies
      # again), so the gate is rebuilt on EVERY round trip. Measured before the
      # clause existed: 2000 resolutions, ~33 allocations each, every one
      # carrying a fresh Mutex.
      #
      # THE ENTRY IS UNBOUNDED AND IDLE. `width.finite?` asks the entry what it
      # IS rather than what class it is, keeping the two arms indistinguishable
      # to everyone but the factory. `in_flight.zero?` is the safety condition:
      # {Null} DOES hold callers -- it declines to gate them and counts them
      # exactly -- so replacing an OCCUPIED entry installs a gate whose count
      # starts at zero and admits a full declared width on top of those already
      # inside, measured at peak 6 against a declared 3.
      #
      # A WINDOW REMAINS, stated rather than denied. {#in_flight} is a snapshot
      # and {Admitted#admitted} resolves-then-enters in two steps, so a caller
      # handed the old entry can still enter it after the swap, invisible to the
      # new gate's count. One caller wide, closing when that round trip ends,
      # and only on an endpoint's first declaration. Closing it needs a gate
      # that can hand its occupants over, which is a different object.
      # @return [Boolean]
      def self.supersedable?(existing, declared)
        return true if existing.nil?

        !declared.nil? && width_from_env.nil? && !existing.width.finite? && existing.in_flight.zero?
      end
      private_class_method :supersedable?

      # CHECKED HERE, BEFORE THE REGISTRY AND BEFORE LOCALITY, and both are
      # load-bearing. Inside {.build} the check would be skipped whenever the
      # key was already memoised, making the refusal depend on what ran first;
      # and it would sit BELOW the locality branch, so a provider whose
      # `#admission_width` computed a bad value would raise against a cloud
      # endpoint and pass in silence against localhost.
      #
      # A String is the shape that will really arrive, since the cloud width is
      # configured from the environment and `ENV.fetch` answers Strings.
      # Unchecked it dies as `undefined method 'positive?' for an instance of
      # String`, from inside a gate the caller never mentioned. A Float is the
      # quieter one: `3.5` passes every check `0` fails and builds a gate 3.5
      # callers wide, which is not a capacity any server has.
      # @return [Integer, nil] nil when nothing was declared
      def self.declared_width(width, endpoint)
        return nil if width.nil?
        return width if width.is_a?(Integer) && width.positive?

        raise Error, "declared admission width #{width.inspect} for #{endpoint} is not an Integer >= 1 " \
                     "(a provider's #admission_width answers a positive Integer, or nil to let locality " \
                     "decide; #{ENV_KEY}=0 is how admission is disabled)"
      end
      private_class_method :declared_width

      # The SERVER identity `endpoint` names, delegated to {Endpoint.canonical}.
      # @param endpoint [String]
      # @return [String]
      def self.canonical(endpoint) = Endpoint.canonical(endpoint)

      # Forget every memoised admission, so the next {.for} rebuilds from the
      # env. The registry pins {ENV_KEY} at an endpoint's FIRST resolution, so
      # without this there is no way to re-read it.
      #
      # It does NOT free a wedged session: existing holders keep the admission
      # they entered, and a rebuilt gate does not know about them. Nor is it
      # per-example hygiene -- the registry is process-global, so a suite that
      # overlaps two round trips on one LOCAL endpoint meets a real gate, and a
      # blanket reset between examples would hide that coupling rather than
      # state it.
      # @return [void]
      def self.reset!
        @registry_lock.synchronize { @registry = {} }
        nil
      end

      # `env > declared > locality`, and the ORDER is the policy: an operator who
      # has said a number has said it about this process, not about half of it;
      # a caller that knows its own server's capacity is believed next; only
      # silence from both lets {.local?} decide.
      #
      # A LOCAL ENDPOINT IGNORES `declared`, DELIBERATELY. {DEFAULT_WIDTH} is
      # the answer to a one-slot local server handed two requests, and a caller
      # that could declare its way past it would re-open exactly that from
      # inside the process. So a declaration only ever reaches the arm locality
      # has no answer for -- hosted, where the alternative is the unbounded
      # {Null} -- and can therefore only ever TIGHTEN.
      #
      # @return [Admission, Admission::Null] Null when the off switch is set, or
      #   when the endpoint is neither local nor given a width and nothing overrode that
      def self.build(endpoint, declared)
        configured = width_from_env
        return new(endpoint:, width: configured) if configured&.positive?
        return Null.new(endpoint:) unless configured.nil?
        return new(endpoint:, width: DEFAULT_WIDTH) if local?(endpoint)

        declared.nil? ? Null.new(endpoint:) : new(endpoint:, width: declared)
      end
      private_class_method :build

      # Whether `endpoint` is a server on this machine, delegated to
      # {Endpoint.local?} -- which is also where BOTH directions of
      # misclassification are spelled out, and they are not symmetric.
      # @param endpoint [String]
      # @return [Boolean]
      def self.local?(endpoint) = Endpoint.local?(endpoint)

      # FORMAT AND DOMAIN ARE BOTH CHECKED, and the second is the one that
      # bites. `-1` parses fine and then makes `@count < @width` false with
      # NOTHING in flight, so every caller polls the whole deadline and raises
      # {Busy} -- and `-1` is exactly what someone reaches for meaning "no
      # limit", so the failure mode is a hung session produced by trying to turn
      # admission OFF. `0` is the way to do that.
      #
      # UNSET ANSWERS nil, NOT {DEFAULT_WIDTH}: {.build} has to tell "the
      # operator asked for 1" from "nobody said", because the first gates a
      # hosted endpoint and the second does not.
      # @return [Integer, nil] nil when the variable is unset or empty
      def self.width_from_env
        raw = ENV.fetch(ENV_KEY, nil)
        return nil if raw.nil? || raw.empty?

        parsed = Integer(raw)
        raise ArgumentError if parsed.negative?

        parsed
      rescue ArgumentError
        raise Error, "#{ENV_KEY}=#{raw.inspect} is not an integer >= 0 (0 disables admission, N sets the width)"
      end
      private_class_method :width_from_env

      # @param endpoint [String] the resolved endpoint, used as the key and named
      #   in a {Busy} refusal
      # @param width [Integer] callers allowed inside at once
      # @param deadline [Float] seconds a caller waits before being refused
      # @param poll_interval [Float] seconds between attempts while waiting
      # @param clock [#call] the monotonic reading the wait is measured against.
      #   {RunClock::MONOTONIC} is the house default and the ONE place in `lib/`
      #   that names the primitive -- `run_clock_spec.rb` pins that mechanically.
      def initialize(endpoint:, width: DEFAULT_WIDTH, deadline: DEFAULT_DEADLINE,
                     poll_interval: POLL_INTERVAL, clock: RunClock::MONOTONIC)
        raise Error, "width must be positive, got #{width.inspect} (#{ENV_KEY}=0 is how admission is disabled)" unless
          width.positive?

        @endpoint = endpoint
        @width = width
        @deadline = deadline
        @poll_interval = poll_interval
        @clock = clock
        @lock = Mutex.new
        @count = 0
      end

      # Enter, waiting up to {#deadline} for a slot.
      #
      # The deadline bounds the WAIT and never the block, and that is easy to
      # lose by wrapping both in one timeout: a round trip is legitimately
      # minutes on a local model, so a timeout around the block would cancel
      # healthy generations. Only the poll loop watches the clock.
      #
      # @yieldparam waited [Float] seconds spent queued; {NO_WAIT} if it never was
      # @return the block's value
      # @raise [Busy] when no slot came free inside the deadline
      def enter
        waited = wait_for_slot
        begin
          yield waited
        ensure
          release_slot
        end
      end

      # Enter only if a slot is free RIGHT NOW; never queue.
      #
      # The eager oracle's entry point: its contract is that the turn which
      # produced the text never waits on it, so a busy endpoint means the
      # summary is SKIPPED, which {Compaction::SummarySnapshot} already reads as
      # an ordinary miss. Queueing instead would be the worse degradation -- a
      # fire reaped at teardown burns its digest for the session.
      #
      # Test-and-set under the one Mutex, so this is atomic across threads too --
      # unlike a `blocking?` check followed by an acquire, which is only atomic
      # within a single reactor.
      #
      # @yieldparam waited [Float] always {NO_WAIT}; it did not queue
      # @return the block's value, or {REFUSED} without running the block
      def try_enter
        return REFUSED unless take_slot

        begin
          yield NO_WAIT
        ensure
          release_slot
        end
      end

      # @return [Integer] callers inside right now; a snapshot, not a reservation
      def in_flight = @lock.synchronize { @count }

      private

      # The uncontended path returns before reading the clock at all, which is
      # what makes {NO_WAIT} exact. Otherwise: attempt, and only on failure check
      # the deadline and sleep -- so a caller past its deadline is refused
      # immediately rather than sleeping first, and a slot freed mid-sleep is
      # taken on the next attempt. The sleep is clamped to what is left of the
      # deadline so waiting never overruns it by up to a poll interval.
      # @return [Float] seconds queued
      def wait_for_slot
        return NO_WAIT if take_slot

        started = now
        until take_slot
          remaining = @deadline - (now - started)
          raise Busy, refusal unless remaining.positive?

          sleep([@poll_interval, remaining].min)
        end
        now - started
      end

      # @return [Boolean] true when this caller took a slot
      def take_slot
        @lock.synchronize { (@count < @width).tap { |free| @count += 1 if free } }
      end

      def release_slot = @lock.synchronize { @count -= 1 }

      def now = @clock.call

      # The endpoint here is the CANONICAL one, which is not necessarily the
      # string the operator typed: `--api-base http://127.0.0.1:11434` refuses by
      # the name `http://localhost:11434`, a server they never named. The gate
      # cannot say their spelling back to them -- it keys on the server and by
      # design does not keep the several spellings that reached it -- so the
      # clause says the thing that resolves the confusion instead, at the moment
      # someone is already debugging a stall.
      def refusal
        "#{@endpoint} is busy: no slot for this request within #{@deadline}s " \
          "(width #{@width}, #{in_flight} in flight; one gate per server, whatever the spelling; " \
          "#{ENV_KEY}=0 disables admission)"
      end

      # Admission that admits everyone: the unbounded arm, selected by
      # `LAIN_PROVIDER_CONCURRENCY=0`.
      #
      # {Sink::Null}'s shape -- it satisfies the same duck and gates nothing, so
      # no caller writes `if admission`.
      #
      # It still COUNTS, though, and that is the difference between doing
      # nothing and lying: the admission journal reads {#in_flight}, and a flat
      # zero would report an idle endpoint under load. Gating is what it
      # declines to do, not bookkeeping.
      class Null
        # @return [String] the endpoint it declines to gate
        attr_reader :endpoint

        def initialize(endpoint:)
          @endpoint = endpoint
          @lock = Mutex.new
          @count = 0
        end

        # @return [Float] unbounded, and says so rather than naming a number
        def width = Float::INFINITY
        def deadline = Float::INFINITY

        # It never polls, so there is no interval to name. Zero rather than a
        # borrowed default: it completes the duck an observer reads without
        # claiming a granularity this arm does not have. Nothing journals it,
        # and {Telemetry::Carriers::ProviderWait} would rightly refuse a zero
        # resolution if one ever reached a record.
        # @return [Float]
        def poll_interval = NO_WAIT

        # @return [Integer] callers inside right now; honest, never gated
        def in_flight = @lock.synchronize { @count }

        # @yieldparam waited [Float] always {NO_WAIT}
        def enter(&block) = counted(&block)

        # Never refuses, so {REFUSED} is unreachable here.
        # @yieldparam waited [Float] always {NO_WAIT}
        def try_enter(&block) = counted(&block)

        private

        def counted
          @lock.synchronize { @count += 1 }
          begin
            yield NO_WAIT
          ensure
            @lock.synchronize { @count -= 1 }
          end
        end
      end
    end
  end
end
