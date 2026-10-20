# frozen_string_literal: true

module Lain
  class Compare
    CompactionTally = Data.define(:summary_misses, :prepared, :applied, :cost_delta)

    # What one run's journal says about compaction, in the 3 figures {Compare} folds across runs.
    # summary_misses is the sum of compaction_decision.summary_misses: every range the strategy was
    # asked for, a size-declined or failed ask included, which is why the column is named for the
    # record and not for "calls". cost_delta is a {Cost}: unpriced when any compaction record quotes no
    # figures, and none when there is no compaction record at all, so a run that never compacted is not
    # read as a measured 0.
    class CompactionTally
      # Reopened rather than defined in the Data block: a constant there lands on the enclosing module.
      NONE = new(summary_misses: 0, prepared: 0, applied: 0, cost_delta: Cost::NONE)

      # @param records [Enumerable<Hash>] 1 run's journal records
      # @return [CompactionTally]
      def self.from_records(records)
        by_type = records.group_by { |record| record["type"].to_s }
        new(summary_misses: by_type.fetch("compaction_decision", []).sum { |r| r["summary_misses"].to_i },
            prepared: by_type.fetch("compaction_prepared", []).size,
            applied: by_type.fetch("compaction_applied", []).size,
            cost_delta: cost_delta_of(by_type.fetch("compaction", [])))
      end

      def self.cost_delta_of(compactions)
        Cost.sum(compactions.map { |r| delta_of(r) })
      end
      private_class_method :cost_delta_of

      def self.delta_of(record)
        return Cost::Unpriced.new(reason: "a compaction record quotes no figures") unless record["cost_saved"]

        Cost::Priced.new(amount: BigDecimal(record["cost_saved"]) - BigDecimal(record["cost_spent"]))
      end
      private_class_method :delta_of

      # Over-counts by 1 when a restart precedes the first render through a prepared cut.
      def unapplied = prepared - applied
    end
  end
end
