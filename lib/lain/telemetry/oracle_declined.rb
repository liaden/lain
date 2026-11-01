# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # Separate from {OracleFailed} because a decline carries a stated reason,
      # not a broken class.
      class OracleDeclined < Declarative::Carrier
        attribute :tier
        attribute :oracle_digest
        attribute :reason, :lain_interned
        validates :tier, presence: { message: "must name the oracle's tier, got nil" }
        validates :oracle_digest, presence: { message: "must name the oracle that declined, got nil" }
        validates :reason, presence: { message: "must say why it declined, got nil" }
      end
    end

    # One oracle call that was turned away before it ran (the local model's slot
    # was taken), journaled by {Oracle::Recorded::Journaling}. A capacity skip is
    # not a failure, so it must not read as an {OracleFailed}. Never an answer:
    # replay still misses through {Oracle::Recorded::Unrecorded}.
    OracleDeclined = Data.define(:tier, :oracle_digest, :reason) do
      include Journalable

      def initialize(tier:, oracle_digest:, reason:)
        super(**Carriers::OracleDeclined.settle!(tier: tier&.to_sym, oracle_digest:, reason:))
      end
    end
  end
end
