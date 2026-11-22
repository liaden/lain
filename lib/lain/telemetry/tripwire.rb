# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # The evidence is copied deeply frozen; the score is the ledger's own Integer.
      class Tripwire < Declarative::Carrier
        attribute :requester, :lain_interned
        attribute :signal, :lain_interned
        attribute :weight, :lain_interned
        attribute :score
        attribute :stop, :lain_interned
        attribute :evidence
      end
    end

    # One signal the tripwire counted against a requester: its `weight`, the
    # requester's `score` over the ledger's window, and `stop`, which is
    # `would_stop` once that score passes the hard stop and `none` before. Observe-only, so a
    # `would_stop` stopped nothing. `evidence` is every signal counted against
    # the requester so far, oldest first, which is what a human reads before
    # lifting a stop.
    #
    # Inside this module `Tripwire` names this record, so the ledger is
    # `::Lain::Tripwire` here.
    Tripwire = Data.define(:requester, :signal, :weight, :score, :stop, :evidence) do
      include Journalable

      # @param requester [String] who the call belonged to, `unknown` when no record named one
      # @param signal [String]
      # @param weight [String]
      # @param score [Integer]
      # @param stop [String]
      # @param evidence [Array<Hash{String=>Object}>]
      def initialize(requester:, signal:, weight:, score:, stop:, evidence:)
        super(**Carriers::Tripwire.settle!(requester:, signal:, weight:, score:, stop:, evidence:))
      end
    end
  end
end
