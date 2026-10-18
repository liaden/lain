# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # One non-negative Integer COUNT, never content: `Data` freezes the record
      # but not its members, so a Hash of leaked bytes would otherwise pass.
      class CommandRedacted < Declarative::Carrier
        attribute :regions
        validates :regions, numericality: { only_integer: true, greater_than_or_equal_to: 0,
                                            message: "must be a non-negative Integer, got %<value>s" }
      end
    end

    # A `bash` result with spans masked: how many, never which bytes.
    CommandRedacted = Data.define(:tool_use_id, :regions) do
      include Journalable

      def initialize(tool_use_id:, regions:)
        Carriers::CommandRedacted.check!(regions:)

        super(tool_use_id: -tool_use_id.to_s, regions: regions.to_i)
      end
    end
  end
end
