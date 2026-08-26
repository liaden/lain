# frozen_string_literal: true

module Lain
  module Oracle
    # Deterministic replay for the oracle tier: substitutes a journaled answer
    # instead of asking a model. The "recorded is a replay of a real
    # interpretation" shape {Effect::Handler::Recorded} and
    # {Grader::Refuter::Recorded} take, keyed here on `(oracle_digest, question)`
    # so a substituted answer is exactly the one THIS oracle gave THIS question.
    #
    # It is a tier bound to one {Definition}, which renders the question, owns the
    # digest, and re-validates the recorded attributes through its schema on the
    # way out -- so a caller cannot tell a replayed answer from a live one.
    #
    # CRUCIALLY, a miss RAISES {Unrecorded} rather than falling through to a live
    # model: re-asking would silently spend tokens and could return a DIFFERENT
    # answer than the recording, making the replay a lie. Both staleness paths
    # surface loudly -- a changed schema gives the definition a different
    # `oracle_digest` so its recordings sit at an address this tier never looks
    # up, and a recording that no longer fits the schema raises {InvalidAnswer} as
    # {Definition#answer} rebuilds it.
    class Recorded
      # No journaled answer names this `(oracle_digest, question)`.
      class Unrecorded < Error; end

      # Build from journaled records, keeping only this definition's oracle's
      # answers and grouping them by question.
      #
      # Two identical questions to a model oracle can yield DIFFERENT answers, so a
      # question is NOT a unique key the way a `tool_use_id` is. Collapsing
      # same-question lines would discard every occurrence but the last and hand a
      # replay the wrong answer, so each question keys a QUEUE consumed FIFO, in
      # journal order.
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

      # The next recorded answer for this question, verbatim -- no provider call.
      # It goes back through {Definition#answer}, so the Promise is the same
      # pre-resolved, schema-validated one the live tiers hand back.
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
      # it, so {Recorded.from_journal} can replay the run with no model call. The
      # record half of the pair: wrap a live tier, journal what it answered, hand
      # its answer straight back untouched.
      #
      # Itself a tier, so it drops in wherever a {Model} or {Heuristic} would --
      # and stacking two would double-record, so put exactly one, outermost.
      class Journaling
        # @param inner [#ask, #model, #usage] the live tier to record -- model and
        #   usage are read OFF it after it answers, never passed in alongside, so
        #   the journaled cost cannot drift from the tier that paid it
        # @param definition [Oracle::Definition] renders the journaled question and
        #   owns the `oracle_digest` the replay keys on -- the SAME definition
        #   `inner` is built over
        # @param journal [#<<] where {Telemetry::OracleAnswer} records land; the
        #   Null channel by default, so no caller guards `if journal`
        # @param clock [#call] monotonic seconds source, injectable so a spec can
        #   pin `wall_clock` deterministically
        def initialize(inner:, definition:, journal: Channel::Null::INSTANCE, clock: RunClock::MONOTONIC)
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
        # TODO(async-tier): both live tiers pre-resolve their Promise before `#ask`
        # returns, so this await is the degenerate synchronous case -- it never
        # parks a fiber and needs no reactor. A tier that resolved asynchronously
        # would park here; when one lands, journal from a resolution callback
        # instead of awaiting inline.
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
