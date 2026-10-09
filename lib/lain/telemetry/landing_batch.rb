# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A landing batch must name the branch it landed on and the desk and outcome
      # it reached.
      class LandingBatch < Declarative::Carrier
        attribute :branch
        attribute :desk
        attribute :outcome
        validates :branch, presence: { message: "must name the branch the batch landed on, got nil" }
        validates :desk, inclusion: { in: %i[parent candidate],
                                      message: "must be one of parent/candidate, got %<value>s" }
        validates :outcome, inclusion: { in: %i[landed partial none],
                                         message: "must be one of landed/partial/none, got %<value>s" }
      end
    end

    # What one drained batch of the landing queue did. `worker_keys` are the worker
    # keys in queue order; `landed`, `ejected` and `declined` partition them by
    # what became of each. `queue_wait_s` maps each worker key to the seconds
    # it waited, and `verify_wall_s` is the wall spent verifying the batch.
    LandingBatch = Data.define(:branch, :desk, :verifier, :worker_keys, :landed, :ejected, :declined,
                               :verifies, :rebuilds, :verify_wall_s, :queue_wait_s, :outcome) do
      include Journalable

      def initialize(branch:, desk:, verifier:, worker_keys:, landed:, ejected:, declined:, verifies:, rebuilds:,
                     verify_wall_s:, queue_wait_s:, outcome:)
        desk = desk&.to_sym
        outcome = outcome&.to_sym
        Carriers::LandingBatch.check!(branch:, desk:, outcome:)

        super(branch: -branch.to_s, desk:, verifier: Freezable::Fields.pinned(verifier),
              worker_keys: Freezable::Fields.pinned_each(worker_keys), landed: Freezable::Fields.pinned_each(landed),
              ejected: Freezable::Fields.pinned_each(ejected), declined: Freezable::Fields.pinned_each(declined),
              verifies: Integer(verifies), rebuilds: Integer(rebuilds), verify_wall_s: Float(verify_wall_s),
              queue_wait_s: Ractor.make_shareable(queue_wait_s.to_h { |key, wait| [key.to_s, Float(wait)] }),
              outcome:)
      end
    end
  end
end
