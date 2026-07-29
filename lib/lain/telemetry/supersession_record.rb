# frozen_string_literal: true

module Lain
  module Telemetry
    module Guards
      # A supersession pointer must name the record it points at, the step that
      # reopened, BOTH closure digests the succession connects, and the plan the
      # step belongs to -- the same join keys {ClosureRecord} carries, so a
      # reader groups reopens by step within a plan without fetching anything.
      class SupersessionRecord < Guard
        attribute :supersession_digest
        attribute :step_id
        attribute :superseded_digest
        attribute :superseding_digest
        attribute :plan_digest
        validates :supersession_digest, presence: { message: "must name the supersession in the Store, got nil" }
        validates :step_id, presence: { message: "must name the step that reopened, got nil" }
        validates :superseded_digest, presence: { message: "must name the superseded closure, got nil" }
        validates :superseding_digest, presence: { message: "must name the superseding closure, got nil" }
        validates :plan_digest, presence: { message: "must name the plan the step belongs to, got nil" }
      end
    end

    # The Journal-resident pointer to one {Plan::Supersession}:
    # `supersession_digest` addresses the frozen sibling in the Store, `step_id`
    # and `plan_digest` are the join keys a report groups reopens by, and
    # `superseded_digest`/`superseding_digest` are the two {Plan::Closure}
    # addresses the succession connects -- carried here so a Journal reader
    # recovers both closures without fetching the supersession. Deeply frozen
    # (interned digests) so the record stays Ractor-shareable.
    #
    # Emitted when a plan step REOPENS -- a fresh fork's {Plan::Closure}
    # superseding an earlier one -- by {Plan::ForkPerStep}, which puts a
    # {Plan::Supersession} into the in-memory Store and journals this pointer to
    # it, so a later process (a resumed session, a report reading the Journal)
    # recovers the reopen from the NDJSON alone. The same
    # Store-pointer-in-the-Journal move {ClosureRecord} makes, since the Store
    # dies with its process.
    SupersessionRecord = Data.define(:supersession_digest, :step_id, :superseded_digest,
                                     :superseding_digest, :plan_digest) do
      include Journalable

      def initialize(supersession_digest:, step_id:, superseded_digest:, superseding_digest:, plan_digest:)
        Guards::SupersessionRecord.check!(supersession_digest:, step_id:, superseded_digest:,
                                          superseding_digest:, plan_digest:)

        super(
          supersession_digest: supersession_digest.dup.freeze,
          step_id: step_id.dup.freeze,
          superseded_digest: superseded_digest.dup.freeze,
          superseding_digest: superseding_digest.dup.freeze,
          plan_digest: plan_digest.dup.freeze
        )
      end
    end
  end
end
