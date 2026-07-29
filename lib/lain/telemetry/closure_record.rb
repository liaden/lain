# frozen_string_literal: true

module Lain
  module Telemetry
    module Guards
      # A closure pointer must name the closure it points at, the step it
      # closed, the plan that step belongs to, and the step's S/M/L size class
      # (P5 calibrates seam placement over size from the Journal alone).
      class ClosureRecord < Guard
        attribute :closure_digest
        attribute :step_id
        attribute :plan_digest
        attribute :size
        validates :closure_digest, presence: { message: "must name the closure in the Store, got nil" }
        validates :step_id, presence: { message: "must name the step it closed, got nil" }
        validates :plan_digest, presence: { message: "must name the plan the step belongs to, got nil" }
        validates :size, presence: { message: "must name the step's size class, got nil" }
      end
    end

    # The Journal-resident pointer to one {Plan::Closure}: `closure_digest`
    # addresses the frozen record in the Store, `step_id` and `plan_digest` are
    # the join keys a report groups closures by, `size` is the step's S/M/L
    # class (carried so P5 calibrates seam placement over size from the Journal
    # alone -- Plan::Document is never journaled, so this pointer is the only
    # place size survives), and `chunk_turn_digests` names the elided span the
    # closure attests -- the same digests the closure's own `elided_digests`
    # hold, carried here so a Journal reader localizes the chunk without
    # fetching the closure. Deeply frozen (interned digests, frozen array) so
    # the record stays Ractor-shareable.
    #
    # Emitted by {Plan::Closure#record}, the same pairing {MemoryRoot} makes: a
    # {Plan::Closure} is put into the in-memory Store by its content address, and
    # this record journals that address so a later process -- P5's calibration, a
    # resumed session -- recovers the closure from the Journal alone, the Store
    # having died with its process.
    ClosureRecord = Data.define(:closure_digest, :step_id, :plan_digest, :size, :chunk_turn_digests) do
      include Journalable

      def initialize(closure_digest:, step_id:, plan_digest:, size:, chunk_turn_digests:)
        Guards::ClosureRecord.check!(closure_digest:, step_id:, plan_digest:, size:)

        super(
          closure_digest: closure_digest.dup.freeze,
          step_id: step_id.dup.freeze,
          plan_digest: plan_digest.dup.freeze,
          size: size.dup.freeze,
          chunk_turn_digests: chunk_turn_digests.map { |digest| -digest.to_s }.freeze
        )
      end
    end
  end
end
