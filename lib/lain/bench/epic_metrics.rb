# frozen_string_literal: true

module Lain
  module Bench
    # Pure folds over one epic run's own journal: what walking the ladder
    # actually cost, read back after the fact rather than measured live.
    #
    # `bench` loads before `epic`, `arm` and `grader` (`lib.rb`'s manifest), so
    # this file names no constant from any of the three at class-body time --
    # every fold below reads a raw journal Hash by its string `type` tag, the
    # same seam {Journal.records} exists for, rather than the Data class that
    # produced it.
    class EpicMetrics
      ISSUE_TRANSITION = "issue_transition"
      SUPERSESSION_RECORD = "supersession_record"
      # `approval` loads ahead of `bench`, so the one place this tag is declared
      # is nameable here -- unlike the two above it.
      GATE_DECISION = Approval::SignoffQueue::JOURNAL_TYPE

      # The one status a transition must have LEFT for it to count as rework:
      # settled work an issue moved back out of, whether a later gate reopened
      # it or a human walked it back by hand.
      DONE = "done"

      # @param entries [Enumerable<Hash, String>] the {Journal.records} duck
      # @return [EpicMetrics]
      def self.from_journal(entries)
        # Materialized ONCE: both folds below walk the same entries by TYPE,
        # and the duck this class accepts includes a one-shot IO enumerator
        # (`File.foreach`), which a second pass over would read as empty.
        records = entries.to_a
        new(rework: fold_rework(records), round_trips: fold_round_trips(records))
      end

      # Rework has two sources, both journaled elsewhere in the pipeline and
      # folded here rather than re-derived: an issue transition OUT of `done`
      # (a human, or a later gate, reopened settled work), keyed by the SAME
      # `(epic_slug, issue_id)` pair {#round_trips} keys on -- issue ids are
      # epic-scoped free text (`Epic::Issue`'s id rules demand no global
      # uniqueness), so a bare `issue_id` key would sum two different epics'
      # same-named issue into one number belonging to neither. The second
      # source is a plan step {Telemetry::SupersessionRecord} names as
      # superseded (`Plan::ForkPerStep`'s reopen); that record carries no
      # epic_slug at all (it names a plan STEP, not an epic issue), so it
      # folds under a NIL epic scope rather than guessing one -- a caller
      # reads it back with `#rework(epic_slug: nil, issue_id: step_id)`, and
      # because every transition-derived key carries a REAL epic_slug, the
      # unscoped bucket can never collide with one.
      def self.fold_rework(records)
        fold_transitions_out_of_done(records).merge(fold_supersessions(records)) { |_key, left, right| left + right }
      end
      private_class_method :fold_rework

      def self.fold_transitions_out_of_done(records)
        Journal.records(records, type: ISSUE_TRANSITION)
               .select { |record| record["from_status"] == DONE }
               .each_with_object(Hash.new(0)) do |record, memo|
                 memo[[record["epic_slug"].to_s, record["issue_id"].to_s]] += 1
               end
      end
      private_class_method :fold_transitions_out_of_done

      def self.fold_supersessions(records)
        Journal.records(records, type: SUPERSESSION_RECORD)
               .each_with_object(Hash.new(0)) { |record, memo| memo[[nil, record["step_id"].to_s]] += 1 }
      end
      private_class_method :fold_supersessions

      # A round-trip is one journaled gate decision, whichever way it went --
      # a denial sending an artifact back for revision is exactly the friction
      # this counts, and an approval closes the loop the denial opened.
      #
      # Keyed on `(epic_slug, stage, issue_id)`: `issue_id` is nil for every
      # decision journaled today (an epic-wide stage's own honest answer,
      # "no issue") and for `research`/`epic_plan`, which stay epic-wide even
      # once a later card makes `issue_plan`/`implementation` issue-scoped and
      # starts journaling the field.
      def self.fold_round_trips(records)
        Journal.records(records, type: GATE_DECISION)
               .each_with_object(Hash.new(0)) do |record, memo|
                 memo[[record["epic_slug"].to_s, record["stage"].to_s, record["issue_id"]&.to_s]] += 1
               end
      end
      private_class_method :fold_round_trips

      # @param rework [Hash] a frozen `[epic_slug, issue_id]` Array (the
      #   epic_slug is nil for a supersession's unscoped `step_id`) mapped to
      #   its rework count
      # @param round_trips [Hash] a frozen `[epic_slug, stage, issue_id]`
      #   Array (issue_id nil for an epic-wide decision) mapped to its
      #   gate-decision count
      def initialize(rework:, round_trips:)
        @rework = rework.freeze
        @round_trips = round_trips.freeze
      end

      # @param epic_slug [#to_s, nil] nil reads a supersession's unscoped
      #   `step_id` bucket -- see {.fold_rework}
      # @param issue_id [#to_s] an issue's own id, or a plan step's `step_id`
      #   when `epic_slug` is nil
      # @return [Integer] 0 for an issue with no rework at all
      def rework(epic_slug:, issue_id:) = @rework.fetch([epic_slug&.to_s, issue_id.to_s], 0)

      # @param epic_slug [#to_s]
      # @param stage [#to_s]
      # @param issue_id [#to_s, nil] nil reads an epic-wide decision (every
      #   decision journaled today, and `research`/`epic_plan` always)
      # @return [Integer] 0 when this (epic, stage, issue) never gated anything
      def round_trips(epic_slug:, stage:, issue_id: nil)
        @round_trips.fetch([epic_slug.to_s, stage.to_s, issue_id&.to_s], 0)
      end
    end
  end
end
