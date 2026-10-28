# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # `outcome` takes any text: {Tripwire::Ledger} compares it as a bare String.
      class TripwireStop < Declarative::Carrier
        attribute :requester, :lain_interned
        attribute :signal, :lain_interned
        attribute :outcome, :lain_interned
        attribute :unseeded
      end
    end

    TripwireStop = Data.define(:requester, :signal, :outcome, :unseeded)

    # A requester's score crossed the hard stop under the stop arm. `outcome`
    # is `stopped` or `all_stopped` when a seeded signal carried it there, and
    # `observe_only` when only unseeded ones did, which stops no one.
    # `unseeded` names the requester's signals that can never trip a stop.
    class TripwireStop
      include Journalable

      OBSERVE_ONLY = "observe_only"

      # @param requester [String]
      # @param signal [String] the one whose hit crossed the hard stop
      # @param outcome [String, Symbol]
      # @param unseeded [Array<String>]
      def initialize(requester:, signal:, outcome:, unseeded:)
        # Interned before settling: a frozen String is kept as it is, and a copy would not be shared.
        super(**Carriers::TripwireStop.settle!(requester:, signal:, outcome:, unseeded: unseeded.map { -_1.to_s }))
      end
    end
  end
end
