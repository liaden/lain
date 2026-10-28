# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A usage record must name the turn it paid for and why the model stopped.
      class TurnUsage < Declarative::Carrier
        attribute :digest
        attribute :model, default: nil
        attribute :stop_reason
        attribute :usage, :lain_canonical
        attribute :spawn, default: nil
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
    #
    # `spawn` names the spawn a child's payment was made under, and is nil for
    # the run's own. A reader pairing a payment with the parent's request must
    # skip a child's, which can bill the parent's own model. The key is left out
    # of the run's own record, so its bytes are what they always were.
    TurnUsage = Data.define(:digest, :model, :stop_reason, :usage, :spawn) do
      include Journalable

      def initialize(digest:, model:, stop_reason:, usage:, spawn: nil)
        super(**Carriers::TurnUsage.settle!(digest:, model: model&.to_s, stop_reason: stop_reason&.to_sym, usage:,
                                            spawn: spawn&.then { -_1.to_s }))
      end

      def to_journal = spawn ? super : super.except("spawn")
    end
  end
end
