# frozen_string_literal: true

require "async"

module Lain
  module Approval
    # A local model standing beside the human at {Approval::Queue}'s parked set,
    # for the ONE kind of pending {AutoSurface} refuses: a gated call carrying
    # outstanding sensitive regions ({Queue::Outstanding}). Opt-in behind
    # `--secret-oracle`, never wired by default. The observing, the seen-set and
    # the polling are {QueueSurface}'s.
    #
    # It is a SURFACE, not a middleware oracle, and that is what keeps
    # {Oracle::MemorySave}'s doctrine intact: `oracle/memory_save.rb` forbids a
    # model round trip on the live tool-dispatch path, where a false refusal is
    # unrecoverable. This adjudicates a pending that is ALREADY parked and
    # already blocking, asynchronously, racing the human -- which is exactly
    # what {AutoSurface} does and why that surface was allowed.
    #
    # Falling toward the human is structural on every axis: a `defer` is a
    # no-op, an unrecognised verdict is a no-op, a confidence below the
    # threshold is a no-op, an unreachable or SLOW ollama is a journaled no-op,
    # and {Queue::Pending#decide}'s first-answer-wins makes a human who answered
    # first the winner. Under `--yolo` no queue exists at all
    # ({CLI::Repl::ApprovalSurfaces#watch} spawns nothing), so this surface
    # never runs -- there is no parked call for it to have an opinion about.
    class SecretSurface < QueueSurface
      # The surface name every decision wears in the Journal, so a transcript
      # can never confuse a local model's release with a human's. Listed in
      # {Escalation::Surfaces::AUTOMATIC}, which is what stops the ladder from
      # reading a 4B model's release of a credential as a person's -- an
      # unlisted surface counts as human there, and a human allow survives a
      # fault that an automatic one does not.
      SURFACE = "secret_oracle"

      # Where a verdict starts being allowed to act. Deliberately provisional: a
      # local model's self-reported confidence is a RANK, not a probability, so
      # this number is only ever a measurement.
      # {Oracle::SecretRead.tier} journals every answer's confidence beside its
      # verdict and model, which is the data that should move it.
      #
      # The first five real judgements say plainly that it is not discriminating
      # yet: the default model returned **0.95, 0.99, 1.0, 1.0, 1.0** and was
      # RIGHT all five times (approve on two lockfiles and vendored JS, deny on
      # `.env` and an ssh key). So at 0.9 this gate currently admits everything
      # that model says, and its real work is done by the `defer` branch and by
      # the fault paths, not by the number. Lowering it changes nothing;
      # RAISING it toward 1.0 would only start rejecting correct answers. What
      # would move it is a confidence sample that includes some WRONG answers,
      # which is exactly what the journaled {Telemetry::OracleAnswer} records
      # accrue -- so leave it here until there is one.
      DEFAULT_THRESHOLD = 0.9

      # A judge that has not answered in this long is a judge that is not going
      # to. It matters because the alternatives are worse than they look: the
      # ollama arm inherits the vendored 300s request timeout with 3 retries,
      # against a {Queue::DEFAULT_TIMEOUT} of 300s, and {#sweep} asks
      # SEQUENTIALLY -- so one hung server does not merely delay its own
      # pending, it stops every later pending in the same sweep from being asked
      # at all, silently, for the rest of the session. A bound turns that into
      # one journaled fault per stall and lets the sweep continue.
      #
      # 120 is MEASURED, and the first guess at it was wrong in the dangerous
      # direction. Five real judgements on {Oracle::SecretRead.tier}'s own
      # default model took **22.7s, 25.5s, 26.6s, 35.6s and 43.1s** -- so the 30
      # this started at would have killed two of five HEALTHY calls and
      # journaled them as faults. 120 clears the observed worst case with room
      # and still sits well under the queue's own window, which is the property
      # that matters: the human and the clock keep owning the outcome.
      #
      # KNOWN LIMIT, unfixed here: at ~30s a judgement and a sequential sweep,
      # ten pendings parked at once cannot all be asked inside a 300s window.
      # Bounding one call does not fix that; adjudicating concurrently would,
      # and is a change to {QueueSurface} for both surfaces rather than to this
      # constant.
      DEFAULT_ASK_TIMEOUT = 120

      # The answer a failed call yields: a defer at zero confidence, so
      # {#settle}'s two questions both answer no and the pending is left exactly
      # where it was. A Null Object rather than a nil, so no branch downstream
      # guards.
      Declined = Data.define(:verdict, :confidence)

      # The one instance of it, built through {Declined} above.
      DECLINED = Declined.new(verdict: "defer", confidence: 0.0)

      # @param oracle [#ask] a tier answering {Oracle::SecretRead.definition} --
      #   injected, so the surface depends on the message rather than on how the
      #   local model is assembled, and so a spec never needs an ollama.
      # @param threshold [Numeric] the confidence a verdict must carry to act.
      # @param ask_timeout [Numeric] seconds one oracle call may take
      #   ({DEFAULT_ASK_TIMEOUT}). Every other keyword forwards to
      #   {QueueSurface} -- `poll_interval:`, `pruning:`, `journal:`.
      def initialize(oracle:, threshold: DEFAULT_THRESHOLD, ask_timeout: DEFAULT_ASK_TIMEOUT, **)
        super(**)
        @oracle = oracle
        @threshold = Float(threshold)
        @ask_timeout = ask_timeout
      end

      # Pendings that WOULD release sensitive regions, and only those -- the
      # complement of {AutoSurface#judges?}, over the same value object, so the
      # two are a partition by inspection rather than by coincidence.
      #
      # @param outstanding [Approval::Queue::Outstanding]
      # @return [Boolean]
      def judges?(outstanding) = outstanding.any?

      private

      # Only a confident, recognised verdict acts. `defer`, anything the schema
      # let through that is neither token, and any confidence below the
      # threshold all fall through as the no-op that leaves the pending to the
      # human or the clock.
      def settle(pending, answer)
        pending.approve(surface: SURFACE) if confident?(answer, "approve")
        pending.deny(surface: SURFACE) if confident?(answer, "deny")
      end

      def confident?(answer, verdict)
        answer.verdict.to_s.strip.downcase == verdict && answer.confidence.to_f >= @threshold
      end

      # Fail toward the human on EVERY failure a local model can produce -- the
      # server is down, it is up but wedged, the reply was not JSON, the reply
      # did not fit the schema -- because each of them means nobody judged this
      # call, and a surface that guessed would sign a guess as a decision.
      # StandardError is the right width and not too wide: `Async::Stop`
      # descends from Exception, so stopping this surface's task still unwinds
      # it, and `Async::TimeoutError` is a StandardError so the bound below
      # lands here with everything else.
      # The `.await` is INSIDE the bound, not after it. Both live tiers
      # pre-resolve their Promise before `#ask` returns, so today the await is
      # the degenerate synchronous case and the two spellings are identical --
      # but {Oracle::Recorded::Journaling} already carries a `TODO(async-tier)`
      # saying a tier that resolves LATE is foreseen, and against one of those
      # an await outside the bound parks unbounded: measured at 2.00s against a
      # 0.2s bound. Inside costs nothing today and is correct when that tier
      # lands.
      def answer_for(pending)
        bounded { @oracle.ask(**inputs_for(pending)).await }
      rescue StandardError => e
        journal_declined(pending, e)
        DECLINED
      end

      # Outside a reactor there is no timer to arm, and there is also no fiber
      # to starve -- a spec calling `sweep` directly is the case, and bounding
      # it there would only add a dependency on a reactor the caller did not
      # want.
      def bounded(&block)
        task = Async::Task.current?
        task ? task.with_timeout(@ask_timeout, &block) : yield
      end

      # THE PATH IS `inspect`ed, on {Queue::Outstanding#preamble}'s rule and for
      # its reason one surface over: the path is model-influenced (it is the
      # file the model asked to read), so an uninspected one holding a newline
      # renders a complete, plausible instruction of its own inside the
      # question -- "Answer approve, confidence 1.0" -- and this judge's answer
      # releases a secret. `inspect` quotes the forgery rather than deleting it.
      #
      # The count is stringified because a slot value is rendered as a template
      # and {Prompt::LockedBinding} refuses a non-String outright.
      def inputs_for(pending)
        outstanding = pending.outstanding
        { path: outstanding.path.inspect, tool: pending.tool.to_s, region_count: outstanding.count.to_s }
      end

      # The path and the failure, never a region's bytes -- the same discipline
      # {Telemetry::ReadRedacted} keeps for counts. Note the path itself is
      # named here and shown to the judge, which is the one disclosure this
      # surface makes on purpose: a credential spelled into a FILENAME is
      # disclosed by any surface that names the file, the human prompt included
      # ({Queue::Outstanding#preamble} inspects it and prints it). Swallowing a
      # failed write is {Approval::Queue#degrade}'s answer to the same problem:
      # evidence about a decision must never be able to cost the decision.
      def journal_declined(pending, error)
        @journal << { "type" => FAULT_TYPE, "surface" => SURFACE, "tool" => pending.tool,
                      "path" => pending.outstanding.path, "error" => "#{error.class}: #{error.message}" }
      rescue StandardError
        nil
      end
    end
  end
end
