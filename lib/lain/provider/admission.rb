# frozen_string_literal: true

# A sibling `admission/` directory makes this file that subtree's index, so it
# requires its own children. Both sit here by CONVENTION, not by constraint:
# neither reopens {Admission} nor resolves its constants at load time, so `lain`
# loads with these at either end of the file. Probed, not assumed.
require_relative "admission/endpoint"
require_relative "admission/journal"

module Lain
  class Provider
    # A provider's CAPACITY, as one object: at most `width` callers inside one
    # RESOLVED ENDPOINT at a time.
    #
    # F26 is the absent concept this fills. Nothing owned capacity, so the
    # harness put two requests on a one-slot local server and then read the
    # silence it had caused itself as a dead stream. Admission wraps
    # {Provider#complete} and nothing below it: `#complete` encloses the whole
    # stream, and the stall clock arms on the FIRST TICK rather than at send
    # (`http/streaming/faraday_handlers.rb:397`), so a request waiting here has
    # no clock installed at all and cannot time out while it queues.
    #
    # == The key is the resolved endpoint, not the flag
    #
    # There is one `--api-base` for every tier (`exe/lain:416`), so
    # `--provider anthropic --summarizer-provider ollama` gives `api_base == nil`
    # on BOTH sides -- a key of "api_base" would serialise a hosted turn behind a
    # local summary. Each provider resolves its own endpoint, and that string is
    # the key. It is also why {.for} exists rather than injection:
    # {Oracle::SecretRead.tier} constructs its provider bare and takes no seam,
    # deliberately (`oracle/secret_read.rb:19-38`), so admission has to be
    # reachable without one.
    #
    # == Why this is hand-rolled and not an Async::Semaphore
    #
    # Because `Provider#complete` is reached from TWO OS threads. On the `--nvim`
    # path `cli/repl.rb:135` wires a real {CLI::ResendBridge}, whose dispatch
    # runs on `frontend/neovim.rb:351`'s resend-worker thread and reaches
    # `resend_bridge.rb:156`'s `@agent.run` -- and {Agent#run} is `Sync { }`,
    # which spins up a SECOND reactor when there is none to join. Meanwhile the
    # eager oracle, the span summarizer and the window probes run on the
    # conductor's. `Agent#dispatch_lock` excludes a concurrent `#ask` and none of
    # those.
    #
    # `Async::Semaphore` is single-reactor by construction: `@count` is
    # unsynchronised, and `FiberNode#resume` calls `Fiber.scheduler.resume` on
    # the RELEASING thread's scheduler. Measured, all three at once: the
    # `FiberError: fiber called across threads` lands in the releasing fiber --
    # the agent's turn, killed by an unrelated resend -- the waiting thread is
    # still parked after a 5s join, wedging `resend_loop`'s blocking-pop
    # consumer, and `#release` decrements before it resumes, so the gate is left
    # at zero with a waiter still queued and SILENTLY STOPS GATING. The last
    # example in the spec is that measurement, kept.
    #
    # So: a Mutex-guarded counter, which is correct across threads, and a poll
    # that sleeps between attempts. `ConditionVariable#wait` is deliberately NOT
    # used -- it blocks the whole reactor thread, which is the failure
    # `cli/repl/approval_surfaces.rb:56-62` records, where a thread-blocking read
    # froze the reactor so the approval queue's fail-closed timer could never
    # fire. A plain `Kernel#sleep` is the opposite: under a fiber scheduler it is
    # hooked (`Async::Scheduler#kernel_sleep`) and yields the fiber, so sibling
    # fibers keep running (measured: 20 ticks of a 10ms ticker across one 200ms
    # sleep), and off a reactor it blocks only the calling thread. That is why
    # this file requires no ASYNC machinery at all: it is correct on and off a
    # reactor, which a gate reached from two of them has to be. Note
    # the precise claim: yielding rather than blocking is a property of ASYNC's
    # scheduler, which implements `kernel_sleep`. Any other fiber scheduler that
    # did not would block the thread here, and nothing in this file enforces
    # that it does.
    #
    # == There is no fairness, and that is worth stating
    #
    # Waiters are not queued: each polls independently, so whoever happens to
    # look when a slot frees takes it. A caller arriving LATE can therefore be
    # served ahead of one already waiting -- measured, two waiters arriving 150ms
    # later beat four already queued. Silence would read as FIFO, so: it is not.
    # Starvation is improbable at real arrival rates (the deadline bounds any one
    # caller's exposure, and a saturated endpoint is the pathology admission
    # exists to report rather than to schedule around), but a bench that cares
    # about causal order should not have to discover this from the source.
    class Admission
      # No slot came free inside the acquire deadline. Named for the ENDPOINT,
      # because the interesting fact is which server is saturated.
      class Busy < Error; end

      # {#try_enter}'s answer when the endpoint is busy. A sentinel rather than
      # nil, because nil is a legitimate thing for an admitted block to return
      # and a caller must be able to tell "refused" from "ran, gave nothing".
      REFUSED = :"lain.admission.refused"

      # One in flight per LOCAL endpoint. Not probed: reading a server's real
      # parallelism is a provider-specific probe on a path that must stay
      # synchronous, and 1 is correct for every local server this bench runs.
      #
      # Read the qualifier as load-bearing. The justification has always been a
      # LOCAL-SERVER one, and F26 is a one-slot local server being handed two
      # requests; applying the same 1 to a hosted endpoint would serialise
      # concurrent SUBAGENTS, which run at once over the ONE shared
      # `Subagent::Seam` provider `cli/wiring.rb:475` -> `toolset_build.rb:316`
      # builds for every child. (One provider, N concurrent callers, one endpoint
      # key -- the sharing does not soften the argument, since the gate keys on
      # the server rather than on the client.) That is a
      # throughput regression nobody asked for, and it is the same harm as
      # serialising a hosted turn behind a local summary -- the case the
      # endpoint key already exists to prevent -- merely wearing the hosted
      # endpoint's own face. So {.build} applies this width only where
      # {.local?} holds, and hands everything else the unbounded {Null}.
      #
      # == What this costs a LOCAL subagent fan-out, which is a real cost
      #
      # Local children no longer overlap: N siblings over one ollama now queue,
      # each against its own {DEFAULT_DEADLINE} acquire clock. So a fan-out that
      # used to run slow can now RAISE {Busy} at sibling N -- a behaviour change,
      # not merely a slowdown, and the thing to recognise if a `Busy` turns up
      # under a wide local spawn.
      #
      # Two of the three places that can meet it already contain it: the render
      # path rescues {Lain::Error} (`compaction/strategy/summarizing.rb:213`) and
      # {Oracle::Eager} contains anything a fire raises inside its task boundary.
      # A SUBAGENT'S OWN TURN IS NEITHER. It has no such rescue, so the refusal
      # surfaces as that child's failure. That is the honest trade -- the
      # alternative is the overlap F26 is about -- but it is why the deadline is
      # 300s rather than something a busy fan-out would trip casually, and why
      # {ENV_KEY} exists.
      DEFAULT_WIDTH = 1

      # Between polls for a free slot. {Approval::QueueSurface::DEFAULT_POLL_INTERVAL}'s
      # value and its reason -- the sleep is a scheduler yield, not a wall-clock
      # stall -- reused rather than restated, as {Notify::POLL_INTERVAL} does.
      POLL_INTERVAL = Approval::QueueSurface::DEFAULT_POLL_INTERVAL

      # The longest a caller waits for a slot before being refused by name.
      #
      # One `request_timeout` (`provider/http/configuration.rb:73`), which is the
      # longest a legitimate holder's single attempt can take -- so a wait longer
      # than this means the holder is retrying or wedged rather than working. It
      # has to be bounded at all because the holder's own ceiling is ~20 minutes,
      # not 300s: faraday-retry sits INSIDE the connection with `:post` in its
      # retry methods, so one hung endpoint holds for four `request_timeout`s
      # (`connection/middleware_stack.rb:64-70`).
      DEFAULT_DEADLINE = 300.0

      # What a caller that never queued reports. Exactly zero rather than a
      # measured epsilon: the wait IS the time spent polling, so a caller
      # admitted on its first attempt waited none, and T3's journal can tell
      # "did not queue" from "queued briefly" without picking a threshold.
      #
      # THE DISTINCTION IS EXACT; THE MAGNITUDE IS NOT. A reported wait is
      # quantised to {POLL_INTERVAL}, because a waiter only learns the slot is
      # free when it next wakes -- measured 0.0501s reported against a ~0.040s
      # true queue. So a non-zero reading is never below one interval and
      # over-reports by up to one, and anything consuming it (T3's journal) must
      # present it as "queued, at ~50ms resolution" rather than as a measurement.
      # Shortening the interval would trade that error against poll churn; it is
      # not a bug to fix here.
      NO_WAIT = 0.0

      # `0` selects the Null arm; a positive `N` sets the width. Either way it
      # overrides the locality rule in BOTH directions -- `0` unbounds a local
      # endpoint, `N` gates a hosted one -- so it is also how a hosted endpoint
      # gets a ceiling when someone wants one. The env-only shape (no CLI flag)
      # is `provider/http/configuration.rb:127-131`'s.
      #
      # It is a PROCESS-START switch, not a rescue. {.for} memoises per endpoint
      # and pins whatever the env said at that endpoint's first resolution, so
      # exporting `0` cannot free a session that is already wedged -- it governs
      # the next process. Calling it an "escape hatch" (as an earlier draft of
      # this comment did) reads as mid-session recovery it cannot perform.
      ENV_KEY = "LAIN_PROVIDER_CONCURRENCY"

      # One admission per resolved endpoint, process-wide. The Mutex is what
      # makes that safe: the registry is reached from both threads named in this
      # class's header, and `Hash#[]=` across threads is not safe. It is NOT a
      # `Ractor.shareable?` concern -- `spec/value_object_shareability_spec.rb`
      # sweeps Data/Struct VALUE objects, and a mutable registry is not one.
      #
      # It is never evicted, and that is deliberate rather than a leak: the key
      # set is the endpoints one process talks to, which is a handful, and an
      # admission that vanished under a live holder would stop gating exactly
      # when it mattered. {.reset!} is the one way to clear it.
      #
      # Class-level ivars rather than constants because this state is MEANT to
      # mutate, and `Style/MutableConstant` is right to say a constant should
      # not: taking its `.freeze` autocorrect would break the memoisation below.
      # The disable is the same argument one cop further on -- the hazard
      # `ThreadSafety/MutableClassInstanceVariable` names is real and is answered
      # by the lock on the very next line, which the cop cannot see. Every read
      # and write of `@registry` goes through it.
      @registry = {} # rubocop:disable ThreadSafety/MutableClassInstanceVariable
      @registry_lock = Mutex.new

      # @return [String] the resolved endpoint this gate governs
      attr_reader :endpoint
      # @return [Integer] how many callers may be inside at once
      attr_reader :width
      # @return [Float] the acquire deadline, in seconds
      attr_reader :deadline
      # The granularity of every wait this gate reports, since a waiter learns a
      # slot is free only when it next wakes. Readable so an observer can
      # describe the gate it is wrapping instead of assuming {POLL_INTERVAL} --
      # a decorator that guessed would report a resolution the gate does not run
      # at. A reader and never a writer: the interval is fixed at construction.
      # @return [Float] seconds between attempts while waiting
      attr_reader :poll_interval

      # The admission for one resolved endpoint, built once and shared.
      #
      # KEYED ON {.canonical}, NOT ON THE STRING IT WAS HANDED, and that is what
      # makes the whole object work rather than a nicety. A raw-string key
      # defeats {DEFAULT_WIDTH}'s own argument -- that every loopback spelling
      # must count local *because they are one server* -- by handing each
      # spelling its own slot. Measured before it was fixed: a chat provider on
      # `--api-base http://127.0.0.1:11434` and the BARE `Provider::Ollama.new`
      # that {Oracle::SecretRead.tier} constructs (the one site that can never
      # take an injected gate, and the reason admission lives in the provider at
      # all) overlapped two round trips on one ollama. F26, still live, through
      # the exact construction sites this card exists to cover.
      #
      # @param endpoint [String] the endpoint the provider resolved for itself
      # @return [Admission, Admission::Null]
      def self.for(endpoint:)
        key = canonical(endpoint)
        @registry_lock.synchronize { @registry[key] ||= build(key) }
      end

      # The SERVER identity `endpoint` names, delegated to {Endpoint.canonical}.
      # @param endpoint [String]
      # @return [String]
      def self.canonical(endpoint) = Endpoint.canonical(endpoint)

      # Forget every memoised admission, so the next {.for} rebuilds from the
      # env. The registry pins {ENV_KEY} at an endpoint's FIRST resolution, so
      # without this there is no way to re-read it -- which made a spec mint a
      # random endpoint per example to dodge leakage, a fixture working around a
      # missing affordance.
      #
      # It does NOT free a wedged session: existing holders keep the admission
      # they entered, and a rebuilt gate simply does not know about them. It is
      # for re-reading configuration, not for recovery.
      #
      # Nor is it per-example hygiene, which is the other thing it looks like
      # from a spec. The registry is process-global, so a suite that overlaps two
      # round trips on one LOCAL endpoint meets a real gate -- see
      # `spec/lain/provider/ollama_spec.rb`'s `without_admission`, which pairs a
      # reset with {ENV_KEY} to ask for the off switch and resets again on the
      # way out. Reaching for a blanket reset between every example would hide
      # that coupling rather than state it, and would quietly widen this method's
      # meaning; it is deliberately not done.
      # @return [void]
      def self.reset!
        @registry_lock.synchronize { @registry = {} }
        nil
      end

      # Three-way, and the ORDER is the policy: an explicit {ENV_KEY} wins in
      # BOTH directions -- `0` unbounds a local endpoint, a positive `N` gates a
      # hosted one -- and only an unset variable lets {.local?} decide. An
      # operator who has said a number has said it about this process, not about
      # this half of it.
      #
      # @return [Admission, Admission::Null] Null when the off switch is set, or
      #   when the endpoint is not local and nothing overrode that
      def self.build(endpoint)
        configured = width_from_env
        return new(endpoint:, width: configured) if configured&.positive?
        return Null.new(endpoint:) unless configured.nil?

        local?(endpoint) ? new(endpoint:, width: DEFAULT_WIDTH) : Null.new(endpoint:)
      end
      private_class_method :build

      # Whether `endpoint` is a server on this machine, delegated to
      # {Endpoint.local?} -- which is also where BOTH directions of
      # misclassification are spelled out, and they are not symmetric.
      # @param endpoint [String]
      # @return [Boolean]
      def self.local?(endpoint) = Endpoint.local?(endpoint)

      # Loud on a typo, per the house rule that unknown values fail rather than
      # degrade: a misspelt width that silently meant 1 would look exactly like
      # admission working.
      #
      # FORMAT AND DOMAIN ARE BOTH CHECKED, and the second is the one that bites.
      # `-1` parses fine and then makes `@count < @width` false with NOTHING in
      # flight, so every caller polls the whole deadline and raises {Busy} -- and
      # `-1` is exactly what someone reaches for meaning "no limit", so the
      # failure mode is a hung session produced by trying to turn admission OFF.
      # `0` is the way to do that, and it is the only non-positive value that
      # means anything here.
      #
      # UNSET ANSWERS nil, NOT {DEFAULT_WIDTH}, and the distinction is what makes
      # the locality rule expressible: {.build} has to tell "the operator asked
      # for 1" from "nobody said", because the first gates a hosted endpoint and
      # the second does not.
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
      # The deadline bounds the WAIT and never the block. That separation is the
      # whole point and is easy to lose by wrapping both in one timeout: a round
      # trip is legitimately minutes on a local model -- prompt evaluation is
      # silence, which is why `request_timeout` stays at 300s
      # (`provider/http/configuration.rb:86-90`) -- so a timeout around the block
      # would cancel healthy generations. Only the poll loop watches the clock.
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
      # produced the text never waits on it (`oracle/eager.rb:45-47`), so a busy
      # endpoint means the summary is SKIPPED, which {Compaction::SummarySnapshot}
      # already reads as an ordinary miss. Queueing instead would be the worse
      # degradation -- a fire reaped at teardown burns its digest for the session.
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
      # no caller writes `if admission`. Selected by `LAIN_PROVIDER_CONCURRENCY=0`
      # at process start, it restores exactly the pre-F26 behaviour: every caller
      # straight through, no queue, no deadline.
      #
      # It still COUNTS, though, and that is the difference between doing nothing
      # and lying. {Sink::Null} returns a real byte count for bytes it discards;
      # this returns the callers really inside it, because T3's journal reads
      # {#in_flight} and a flat zero would report an idle endpoint under load.
      # Gating is what it declines to do -- not bookkeeping.
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
        # claiming a granularity this arm does not have. Nothing journals it --
        # this arm never queues, so it never emits a record -- and
        # {Telemetry::Guards::ProviderWait} would rightly refuse a zero
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
