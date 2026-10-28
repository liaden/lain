# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # Head and stop reason journal as strings, the form a replayed record holds.
      class AskSettled < Declarative::Carrier
        attribute :head, :lain_interned
        attribute :stop_reason, :lain_interned
        attribute :turns
        attribute :seconds
      end
    end

    # A human's prompt ran to a response the harness accepts. Distinct from
    # {RunInterrupted}, which is the other way an ask ends: the pair lets a
    # reader tell a finished ask from a torn one without inferring it from the
    # turn records.
    #
    # @!attribute [r] head
    #   @return [String] the digest of the last turn the ask committed
    # @!attribute [r] stop_reason
    #   @return [String] why the model stopped
    # @!attribute [r] turns
    #   @return [Integer] model round trips the ask took
    # @!attribute [r] seconds
    #   @return [Float] wall time from the prompt to the settled reply
    AskSettled = Data.define(:head, :stop_reason, :turns, :seconds) do
      include Journalable

      def initialize(head:, stop_reason:, turns:, seconds:)
        super(**Carriers::AskSettled.settle!(head:, stop_reason:, turns:, seconds:))
      end
    end
  end
end
