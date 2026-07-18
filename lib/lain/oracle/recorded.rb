# frozen_string_literal: true

module Lain
  module Oracle
    # Deterministic replay for the oracle tier: substitutes a journaled answer
    # instead of asking a model. The same "recorded is a replay of a real
    # interpretation" shape as {Effect::Handler::Recorded} (which keys a TOOL
    # call's outcome on `tool_use_id`) and {Grader::Refuter::Recorded} (which
    # keys a FINDING's verdict on its content digest) -- here keyed on
    # `(oracle_digest, question)`, so a substituted answer is exactly the one
    # THIS oracle gave THIS question.
    #
    # It is a tier, answering the same `#ask -> Promise` message {Model} and
    # {Heuristic} do, bound to one {Definition}: the definition renders the
    # question (the second half of the key), owns the `oracle_digest` (the
    # first), and re-validates the recorded attributes through its schema on the
    # way back out -- so a caller cannot tell a replayed answer from a live one.
    #
    # CRUCIALLY, a miss RAISES {Unrecorded} -- it does NOT fall through to a live
    # model the way {Effect::Handler::Recorded} falls through to its `inner`.
    # Re-asking a model on replay would silently spend tokens and, worse, could
    # return a DIFFERENT answer than the recording, making the replay a lie. Two
    # staleness paths both surface loudly here: a changed oracle SCHEMA gives the
    # definition a different `oracle_digest`, so its recordings are keyed under an
    # address this tier never looks up -> {Unrecorded}; and if a recording for
    # the right digest somehow no longer fits the schema, {Definition#answer}
    # raises {InvalidAnswer} as it rebuilds it.
    class Recorded
      # No journaled answer names this `(oracle_digest, question)`.
      class Unrecorded < Error; end

      # Build from journaled records, keeping only the answers this definition's
      # oracle produced (its `oracle_digest`) and grouping them by question.
      #
      # Two identical questions to a model oracle can yield DIFFERENT answers (a
      # model is not a pure function), so a question is NOT a unique key the way a
      # `tool_use_id` is. Collapsing same-question lines into one would silently
      # discard every occurrence but the last and hand a replay the wrong answer;
      # each question therefore keys a QUEUE consumed FIFO, the same order the
      # calls were journaled in -- exactly {Grader::Refuter::Recorded}'s handling
      # of same-digest verdicts.
      #
      # @param entries [Enumerable<Hash, String>] the {Journal.records} duck --
      #   parsed Hashes or raw NDJSON line Strings
      # @param definition [Oracle::Definition] the oracle whose answers to replay
      # @return [Recorded]
      def self.from_journal(entries, definition:)
        digest = definition.digest
        answers = Journal.records(entries, type: "oracle_answer")
                         .select { |record| record["oracle_digest"] == digest }
                         .group_by { |record| Canonical.normalize(record.fetch("question")) }
        new(definition:, answers:)
      end

      # @param definition [Oracle::Definition] renders the question, owns the
      #   digest, and re-validates each recorded answer through its schema
      # @param answers [Hash{String=>Array<Hash>}] normalized question => its
      #   journaled OracleAnswer records, oldest first
      def initialize(definition:, answers:)
        @definition = definition
        @answers = answers.transform_values(&:dup)
      end

      # Substitute the next recorded answer for this question, verbatim -- no
      # provider call. The recorded attributes go back through {Definition#answer},
      # so the returned Promise is the same pre-resolved, schema-validated one the
      # live tiers hand back.
      #
      # @param inputs [Hash] the question's slot values
      # @return [Lain::Promise] resolving to the validated typed answer
      # @raise [Unrecorded] no (further) journaled answer names this
      #   `(oracle_digest, question)`
      def ask(inputs = {})
        question = Canonical.normalize(@definition.render(inputs))
        queue = @answers[question]
        if queue.nil? || queue.empty?
          raise Unrecorded, "no recorded oracle answer for #{@definition.digest.inspect} question #{question.inspect}"
        end

        @definition.answer(queue.shift.fetch("answer"))
      end

      # Records every oracle call as a {Telemetry::OracleAnswer} before returning
      # it, so {Recorded.from_journal} can replay the run later with no model
      # call. The record half of the record/replay pair -- the decoration idiom
      # {Grader::Verified} uses for verdicts, one tier over: wrap a live tier,
      # journal what it answered, hand its answer straight back untouched.
      #
      # It is itself a tier (answers `#ask -> Promise`), so it drops in wherever a
      # {Model} or {Heuristic} would, and stacking two of them would double-record
      # -- put exactly one, outermost.
      class Journaling
        # @param inner [#ask, #model, #usage] the live tier to record ({Model},
        #   {Heuristic}, or any tier answering that trio) -- the model and usage
        #   are read OFF the tier after it answers, never passed in alongside, so
        #   the journaled cost cannot drift from the tier that actually paid it
        # @param definition [Oracle::Definition] renders the journaled question
        #   and owns the `oracle_digest` the replay keys on -- the SAME definition
        #   `inner` is built over
        # @param journal [#<<] where {Telemetry::OracleAnswer} records land; the
        #   Null channel by default, so no caller guards `if journal` (the same
        #   default {Grader::Verified} and {Middleware::JournalRequests} use)
        # @param clock [#call] monotonic seconds source, injectable so a spec can
        #   pin `wall_clock` deterministically
        def initialize(inner:, definition:, journal: Channel::Null::INSTANCE,
                       clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          @inner = inner
          @definition = definition
          @journal = journal
          @clock = clock
        end

        # Ask the inner tier, journal its answer WITH the tier's own model and
        # token usage, return the SAME Promise. Reading `inner.usage`/`inner.model`
        # right after the call is what puts a model oracle's real spend into the
        # Journal, where the bench's cost accounting reads it.
        #
        # The answer is read via `#await` only to journal its attributes.
        # TODO(async-tier): both live tiers pre-resolve their Promise before
        # `#ask` returns (their own docs), so this await is the degenerate
        # synchronous case {Promise#await} falls out of -- it never parks a fiber
        # and needs no reactor. A future tier that resolves asynchronously would
        # park here; when one lands, journal from a resolution callback instead of
        # awaiting inline.
        #
        # @param inputs [Hash] the question's slot values
        # @return [Lain::Promise] the inner tier's own Promise, unchanged
        def ask(inputs = {})
          question = @definition.render(inputs)
          started = @clock.call
          promise = @inner.ask(inputs)
          typed = promise.await
          @journal << Telemetry::OracleAnswer.new(
            oracle_digest: @definition.digest, question:, answer: typed.to_h,
            model: @inner.model, usage: @inner.usage, wall_clock: @clock.call - started
          )
          promise
        end
      end
    end
  end
end
