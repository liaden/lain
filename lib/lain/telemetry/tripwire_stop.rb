# frozen_string_literal: true

module Lain
  module Telemetry
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
        super(requester: -requester.to_s, signal: -signal.to_s, outcome: -outcome.to_s,
              unseeded: Ractor.make_shareable(unseeded.map { -_1.to_s }))
      end
    end
  end
end
