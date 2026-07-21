# frozen_string_literal: true

module Lain
  module Plan
    # PC-5: folds `closure_record` journal pointers ({Plan::Closure#record},
    # P2) into per-size-class turn/token distributions. The pointer is P2's
    # Store-pointer-in-the-Journal move, so this fold works from the Journal
    # ALONE, across sessions and processes -- the Store that held the actual
    # {Plan::Closure} values never survives the process that built them.
    # `#median_turns(size_class)` is the one method P4's `calibration:` input
    # calls; `#render` is the human-reportable fold, including the drift
    # between a chunk's OWN measurement and its class's calibrated median --
    # `plan-shaped-compaction.md`'s "annotated-S chunks measured at a median of
    # N turns, and drift between annotation and measurement is itself a
    # journaled, reportable signal."
    #
    # Tokens join onto {Telemetry::TurnUsage} exactly the way {Ledger} prices a
    # Timeline -- {Ledger::Index.from_journal} folds `turn_usage` records into
    # digest => payments -- except keyed off the closure's OWN
    # `chunk_turn_digests` rather than a live Timeline's reachability walk: a
    # closure already attests which turns its chunk spent, so no Timeline (and
    # no Store) is needed to price them.
    #
    # A `closure_record` line missing `size` (a pre-migration journal, or a
    # hand-built fixture predating the field) folds UNCLASSED rather than
    # raising: {Telemetry::ClosureRecord}'s Guard demands `size` for anything
    # CONSTRUCTED as one, but a Journal reader sees raw parsed Hashes, and
    # history a migration cannot rewrite is real. Unclassed chunks are excluded
    # from every per-class distribution and counted, never silently dropped.
    class Calibration
      # One closed chunk's measurements, folded from one closure_record (+ its
      # turn_usage join). `size` is nil for an unclassed line.
      Chunk = Data.define(:step_id, :size, :turns, :tokens)

      # @param entries [Enumerable<Hash, String>] the {Journal.records} duck --
      #   parsed Hashes or raw NDJSON line Strings
      # @return [Calibration]
      def self.fold(entries)
        new(entries)
      end

      def initialize(entries)
        entries = entries.to_a.freeze
        usage_index = Ledger::Index.from_journal(entries)
        @chunks = Journal.records(entries, type: "closure_record")
                         .map { |record| chunk_from(record, usage_index) }.to_a.freeze
      end

      # @param size_class [String, Symbol] one of {Step::SIZES}
      # @return [Float, Integer, nil] the median turn count measured for
      #   `size_class`, or nil when no closed chunk of that class has landed
      #   yet -- P4's annotation-only fallback.
      def median_turns(size_class)
        turns_distribution(size_class)&.median
      end

      # @return [Float, Integer, nil] the median total-token count.
      def median_tokens(size_class)
        tokens_distribution(size_class)&.median
      end

      # @return [Compare::Distribution, nil]
      def turns_distribution(size_class)
        distribution(size_class, &:turns)
      end

      # @return [Compare::Distribution, nil]
      def tokens_distribution(size_class)
        distribution(size_class, &:tokens)
      end

      # @return [Integer] closures whose size class could not be recovered
      #   from the Journal.
      def unclassed_count
        @chunks.count { |chunk| chunk.size.nil? }
      end

      # @return [String] a scannable report: each class's turn/token
      #   distribution, per-chunk drift against its own class's median, and
      #   the unclassed count, named rather than hidden. Never printed here
      #   (output discipline).
      def render
        [class_table, "", drift_table, "", unclassed_line].join("\n")
      end

      private

      # `size` is normalized to a String (or nil) here, not trusted from the
      # record: a Journal reader mostly sees JSON-round-tripped Hashes where a
      # Symbol could never survive, but nothing stops a live in-process caller
      # from handing `Telemetry::ClosureRecord#to_journal`'s Hash straight to
      # `.fold` -- the Guard only checks `size`'s PRESENCE, not its type. An
      # un-normalized Symbol would compare unequal to every String size_class
      # callers pass, so the chunk would silently fold into NEITHER its class
      # NOR the unclassed count. A digest with no `turn_usage` entry at all
      # contributes zero tokens -- the same "un-instrumented turns are free"
      # reading {Ledger#usage_of} gives a digest the Journal never priced.
      def chunk_from(record, usage_index)
        digests = record.fetch("chunk_turn_digests")
        tokens = digests.sum { |digest| usage_index.entries_for(digest).sum { |entry| entry.usage.total_tokens } }
        Chunk.new(step_id: record.fetch("step_id"), size: record["size"]&.to_s, turns: digests.length, tokens:)
      end

      def classes
        @chunks.filter_map(&:size).uniq.sort
      end

      def distribution(size_class, &reader)
        values = @chunks.select { |chunk| chunk.size == size_class.to_s }.map(&reader)
        values.empty? ? nil : Compare::Distribution.new(values)
      end

      def class_table
        rows = classes.map do |size|
          turns = turns_distribution(size)
          tokens = tokens_distribution(size)
          [size, turns.n.to_s, format("%.1f", turns.median), format("%.1f", tokens.median),
           format("%.1f", tokens.mean)]
        end
        Compare::Table.new(headers: %w[class n median_turns median_tokens mean_tokens], rows:).to_s
      end

      def drift_table
        rows = @chunks.filter_map { |chunk| drift_row(chunk) }
        return "no classed chunks to measure drift against" if rows.empty?

        Compare::Table.new(headers: %w[step class turns class_median drift], rows:).to_s
      end

      def drift_row(chunk)
        return nil if chunk.size.nil?

        median = median_turns(chunk.size)
        [chunk.step_id, chunk.size, chunk.turns.to_s, format("%.1f", median), format("%+.1f", chunk.turns - median)]
      end

      def unclassed_line
        "unclassed closures (no size recoverable from the Journal): #{unclassed_count}"
      end
    end
  end
end
