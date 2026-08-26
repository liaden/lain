# frozen_string_literal: true

module Lain
  module Grader
    # Judges ONE finding from a finding-producing grader: is it a genuine,
    # well-supported problem, or a false positive? {Verified} calls #refute on
    # every raw finding and keeps only the ones whose Grade passes.
    #
    # Built on {Rubric} rather than duplicating its machinery, so it inherits
    # the separate context window and the mandatory-`#why` contract. The one
    # thing it adds is a THRESHOLD: a bare Rubric's `#pass?` is unreliable for a
    # continuous judge, but a refutation genuinely IS binary -- a finding either
    # survives or it does not -- so this reads `#score` and rebuilds the Grade
    # with an explicit `pass:`.
    class Refuter
      DEFAULT_CRITERIA = <<~CRITERIA
        You are refuting a finding produced by an automated grader, checking it
        for false positives. Score how confident you are that the finding is
        TRUE and well-supported by its own stated evidence -- not whether it is
        important, just whether it actually holds.
      CRITERIA

      # Score at or above this and the finding survives.
      DEFAULT_THRESHOLD = 0.5

      # @param provider [Lain::Provider] the judge model's provider
      # @param model [String] the judge model
      # @param criteria [String] what makes a finding genuine, vs. a false positive
      # @param max_tokens [Integer] the judge's reply budget
      # @param threshold [Float] score at/above which a finding survives
      def initialize(provider:, model:, criteria: DEFAULT_CRITERIA, max_tokens: 512, threshold: DEFAULT_THRESHOLD)
        @rubric = Rubric.new(criteria:, provider:, model:, max_tokens:)
        @threshold = threshold
      end

      # @param finding [#to_s] one raw finding from a finding-producing grader
      # @return [Grade] `#pass?` is the survival verdict; `#score`/`#why` come
      #   straight from the underlying Rubric judgment
      def refute(finding)
        verdict = @rubric.grade(finding)
        Grade.new(score: verdict.score, why: verdict.why, pass: verdict.score >= @threshold)
      end

      # Replays journaled {Telemetry::Verdict} records instead of judging live,
      # keyed by the finding's OWN content digest, since a finding carries no id
      # of its own. A miss is a loud {Unrecorded}, never a silently invented
      # verdict.
      #
      # Two findings can share IDENTICAL text and there is nothing else to key
      # on, so a digest is NOT unique the way a `tool_use_id` is. A plain
      # digest => record Hash would silently discard every occurrence but the
      # last and hand every duplicate finding the WRONG verdict. Each digest
      # therefore keys a QUEUE consumed FIFO -- the order `Verified#grade` wrote
      # them in, since it journals each finding before moving to the next.
      class Recorded
        class Unrecorded < Lain::Error; end

        # Each `verdict` record becomes a replayable Grade queued under its
        # finding digest, so `Recorded.from_journal(File.foreach(path))`
        # reconstitutes a refuter straight from the record.
        #
        # @param entries [Enumerable<Hash, String>]
        # @return [Recorded]
        def self.from_journal(entries)
          verdicts = Journal.records(entries, type: "verdict").group_by { |record| record.fetch("digest") }
          new(verdicts:)
        end

        # @param verdicts [Hash{String=>Array<Hash>}] finding digest => its
        #   journaled Verdict records, oldest first
        def initialize(verdicts:)
          @verdicts = verdicts.transform_values(&:dup)
        end

        # @param finding [#to_s]
        # @return [Grade] the next recorded verdict for this digest, verbatim
        #   -- no model call
        # @raise [Unrecorded] no (further) journaled verdict names this
        #   finding's digest
        def refute(finding)
          digest = Canonical.digest(finding.to_s)
          queue = @verdicts[digest]
          raise Unrecorded, "no recorded verdict for finding digest #{digest.inspect}" if queue.nil? || queue.empty?

          record = queue.shift
          Grade.new(score: record.fetch("score"), why: record.fetch("why"), pass: record.fetch("survived"))
        end
      end
    end
  end
end
