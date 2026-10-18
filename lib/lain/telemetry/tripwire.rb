# frozen_string_literal: true

module Lain
  module Telemetry
    # One signal the tripwire counted against a requester: its `weight`, the
    # requester's running `score`, and `stop`, which is `would_stop` once the
    # score passes the hard stop and `none` before. Observe-only, so a
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
        super(requester: -requester.to_s, signal: -signal.to_s, weight: -weight.to_s, score:, stop: -stop.to_s,
              evidence: Ractor.make_shareable(evidence.dup))
      end
    end
  end
end
