# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A usage record must name the turn it paid for and why the model stopped.
      class TurnUsage < Declarative::Carrier
        attribute :digest
        attribute :stop_reason
        validates :digest, presence: { message: "must name the committed turn, got nil" }
        validates :stop_reason, presence: { message: "must name why the model stopped, got nil" }
      end
    end

    # Token accounting for ONE model call, pinned to the assistant turn the call
    # was committed as. Every record is a payment: aggregating spend means
    # summing over RECORDS, full stop.
    #
    # `digest` is a JOIN KEY onto content, NOT a dedupe key for spend, and it is
    # not unique across records: rewind the Timeline, regenerate an identical
    # turn, and two records land here with the SAME digest, both genuinely paid
    # for. Deduplicating by digest would undercount every regenerated turn.
    # Unique-digest aggregation is the rule for CONTENT reachable from a
    # branched head, which is why usage lives here and not in `Turn#meta` -- the
    # digest must stay content-only.
    #
    # `usage` is held in canonical wire form so the event stays
    # Ractor-shareable; `model` is nil when the provider reported none.
    TurnUsage = Data.define(:digest, :model, :stop_reason, :usage) do
      include Journalable

      def initialize(digest:, model:, stop_reason:, usage:)
        Carriers::TurnUsage.check!(digest:, stop_reason:)

        super(
          digest: digest.dup.freeze,
          model: model&.to_s&.freeze,
          stop_reason: stop_reason.to_sym,
          usage: Canonical.normalize(usage)
        )
      end
    end
  end
end
