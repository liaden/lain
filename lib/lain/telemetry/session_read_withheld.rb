# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # Each withheld round is a `[head, call id]` pair: the head a nil or a
      # String, the call id a String -- the key a read's round is found by.
      class SessionReadWithheld < Declarative::Carrier
        attribute :rounds
        validate :rounds_name_head_and_call

        private

        def rounds_name_head_and_call
          return if rounds.is_a?(Array) && !rounds.empty? && rounds.all? { |round| round?(round) }

          errors.add(:rounds, "must be a non-empty list of [head, call id] pairs, got #{rounds.inspect}")
        end

        def round?(round)
          round.is_a?(Array) && round.size == 2 && (round.first.nil? || round.first.is_a?(String)) &&
            round.last.is_a?(String)
        end
      end
    end

    # The rounds {Session#on_chain} withheld because no turn delivered them:
    # a marker, carrying no bytes and no path, that lets {SessionRecord::Replay}
    # withhold the same rounds at the same point in the record rather than bind
    # them to a later delivery from the same head. Written only when a round
    # really was left open, which an ordinary run never does. Emitted by
    # {Session} as it records, never by the Agent or a tool.
    SessionReadWithheld = Data.define(:rounds) do
      include Journalable

      def initialize(rounds:) = super(**Carriers::SessionReadWithheld.settle!(rounds:))
    end
  end
end
