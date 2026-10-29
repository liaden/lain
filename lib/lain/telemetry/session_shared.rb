# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A share with no url never happened, so a nil is refused rather than journaled as `""`.
      class SessionShared < Declarative::Carrier
        attribute :url, :lain_interned
        attribute :format, :lain_interned
        attribute :masked
        validates :url, presence: { message: "must name where the session was shared, got nil" }
      end
    end

    # The session's export left the machine as a secret gist. The bytes are the model's masked view,
    # so this records where they went and how many regions were already placeholders in them.
    #
    # @!attribute [r] url
    #   @return [String] the gist address gh answered
    # @!attribute [r] format
    #   @return [String] "html" or "jsonl"
    # @!attribute [r] masked
    #   @return [Integer] regions the shared document held as placeholders
    SessionShared = Data.define(:url, :format, :masked) do
      include Journalable

      def initialize(url:, format:, masked:) = super(**Carriers::SessionShared.settle!(url:, format:, masked:))
    end
  end
end
