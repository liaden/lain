# frozen_string_literal: true

module Lain
  module Bench
    # The experiment engine (design decision D3): n recordings of ONE task,
    # reported along three axes in one String.
    #
    # 1. Determinism -- each recording, dry-replayed under its own Context,
    #    must re-render byte-identical to what was actually sent. Divergence
    #    here is either the harness leaking state into a render or a
    #    custom-pipeline recording that {Session.load} rebuilds as the default
    #    Context; the line says which, via {Session::Recording#context_class}.
    # 2. Divergence -- where each recording's actually-sent baseline first
    #    parts ways from the first recording's, named to the model call and
    #    the changed cache_payload fields. This is the MODEL'S variance,
    #    measured on recorded bytes, never re-derived.
    # 3. Distribution -- {Compare}'s token/cost table across the recordings,
    #    because a single pair of runs is noise.
    #
    # Recordings are an Array, auto-named "1".."n": they are repeated samples
    # of one task, not named experimental arms, so ordinals carry all the
    # meaning there is -- caller-chosen names belong to Compare's cross-arm
    # use, not here. Steps print 1-based ("model call 2"), translated from
    # StepDiff's 0-based index at this formatting boundary, so the experimenter
    # never does off-by-one arithmetic against the 1-based ordinals.
    #
    # Compare AND the determinism diffs are built eagerly: mismatched degraded
    # sets ({Capability::Guard}) and a recording that cannot replay (an orphan
    # request_sent tripping DryReplay's 1:1 guard) both refuse at
    # construction, before any report text exists.
    class Variance
      # @param recordings [Array<Session::Recording>] n >= 2 recordings of one task
      # @param price_book [Lain::PriceBook] how each recording's usage becomes dollars
      # @raise [ArgumentError] on fewer than two recordings, or on a recording
      #   whose baseline cannot line up 1:1 with its model calls
      # @raise [Capability::Guard::Mismatch] when the recordings degraded different sets
      def initialize(recordings:, price_book: PriceBook.default)
        @recordings = Array(recordings).freeze
        raise ArgumentError, "variance needs at least two recordings; one run is not an experiment" if
          @recordings.size < 2

        @price_book = price_book
        @compare = build_compare
        @diffs = @recordings.map { |recording| recording.dry_replay.diff(recording.context) }.freeze
      end

      # The three-section report. Returned as a String -- never printed.
      #
      # @return [String]
      def report
        [header, determinism_section, divergence_section, distribution_section].join("\n\n")
      end

      private

      def header
        "Variance — #{@recordings.size} recordings"
      end

      def named
        @recordings.each_with_index.map { |recording, index| [(index + 1).to_s, recording] }
      end

      def determinism_section
        lines = named.zip(@diffs).map { |(name, recording), diff| determinism_line(name, recording, diff) }
        ["== Determinism (self dry-replay; divergence = harness leak or custom-pipeline recording) ==",
         *lines].join("\n")
      end

      def determinism_line(name, recording, diff)
        return "#{name}: byte-identical" if diff.identical?

        "#{name}: DIVERGED (#{diverged_detail(recording, diff)})"
      end

      def diverged_detail(recording, diff)
        step = diff.steps.find { |candidate| !candidate.identical? }
        detail = "model call #{step.index + 1}: #{step.changed_fields.join(", ")}"
        return detail unless custom_pipeline?(recording)

        "#{detail}; recorded under #{recording.context_class}; reload renders the default pipeline"
      end

      # The header's recorded class vs the class Session.load actually rebuilt:
      # unequal means the divergence is the stated format limit, not a leak.
      def custom_pipeline?(recording)
        recording.context_class != recording.context.class.name
      end

      def divergence_section
        lines = named.drop(1).map { |name, recording| divergence_line(name, recording.baseline) }
        ["== Divergence (vs recording 1) ==", *lines].join("\n")
      end

      def divergence_line(name, baseline)
        "#{name}: #{Divergence.new(@recordings.first.baseline, baseline).describe}"
      end

      def distribution_section
        ["== Distribution ==", @compare.report].join("\n")
      end

      def build_compare
        Compare.new(named.map do |name, recording|
          Compare::Run.from_timeline(
            name: name, timeline: recording.timeline,
            ledger: Ledger.new(index: recording.ledger_index, price_book: @price_book),
            degraded: recording.degraded
          )
        end)
      end

      # One candidate baseline held against the reference's: the first model
      # call whose request digest differs, the fields that changed there, and
      # a call-count note when the runs took different numbers of model calls
      # (comparison then covers only the shorter length). "Cache-identical"
      # is the honest claim: digests hash the cache_payload, so transport
      # fields (stream, extra) are outside the comparison by design.
      class Divergence
        def initialize(reference, candidate)
          @reference = reference
          @candidate = candidate
          @step = (0...shared).find { |index| reference.fetch(index).digest != candidate.fetch(index).digest }
        end

        def describe
          [count_note, verdict].compact.join("; ")
        end

        private

        attr_reader :reference, :candidate, :step

        def shared
          [reference.size, candidate.size].min
        end

        def count_note
          return nil if candidate.size == reference.size

          "#{candidate.size} model calls vs reference #{reference.size}"
        end

        def verdict
          return diverged unless step.nil?
          return "cache-identical to reference" if candidate.size == reference.size

          "cache-identical over the shared #{shared} model calls"
        end

        # StepDiff is DryReplay's recorded-vs-replayed comparator, reused here
        # for reference-vs-candidate: both are "name the cache_payload fields
        # whose canonical bytes differ", and one comparator means the two
        # sections cannot disagree about what counts as a difference. Only
        # #changed_fields is consumed; the recorded/replayed members keep
        # their DryReplay meaning.
        def diverged
          fields = StepDiff.build(step, reference.fetch(step), candidate.fetch(step)).changed_fields
          "first divergence at model call #{step + 1} (#{fields.join(", ")})"
        end
      end
      private_constant :Divergence
    end
  end
end
