# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A landing batch must name the branch it landed on and the desk and outcome
      # it reached.
      class LandingBatch < Declarative::Carrier
        attribute :branch, :lain_interned
        attribute :desk
        attribute :verifier, default: nil
        attribute :worker_keys
        attribute :landed
        attribute :ejected
        attribute :declined
        attribute :verifies
        attribute :rebuilds
        attribute :verify_wall_s
        attribute :queue_wait_s
        attribute :outcome
        attribute :flagged, default: -> { {} }
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
    # `flagged` maps the key of each landed worker whose change raised flags to
    # them; a worker that raised none is absent.
    LandingBatch = Data.define(:branch, :desk, :verifier, :worker_keys, :landed, :ejected, :declined,
                               :verifies, :rebuilds, :verify_wall_s, :queue_wait_s, :outcome, :flagged) do
      include Journalable

      def initialize(branch:, desk:, verifier:, worker_keys:, landed:, ejected:, declined:, verifies:, rebuilds:,
                     verify_wall_s:, queue_wait_s:, outcome:, flagged: {})
        super(**Carriers::LandingBatch.settle!(
          branch:, desk: desk&.to_sym, outcome: outcome&.to_sym, verifier: verifier&.then { -_1.to_s },
          worker_keys: names(worker_keys), landed: names(landed),
          ejected: names(ejected), declined: names(declined),
          verifies: Integer(verifies), rebuilds: Integer(rebuilds), verify_wall_s: Float(verify_wall_s),
          queue_wait_s: waits(queue_wait_s),
          flagged: flags(flagged)
        ))
      end

      private

      def names(list) = list.map { -_1.to_s }

      def flags(flagged) = flagged.to_h { |key, list| [key.to_s, names(list)] }

      def waits(queue_wait_s) = queue_wait_s.to_h { |key, wait| [key.to_s, Float(wait)] }
    end
  end
end
