# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # One non-negative Integer COUNT, never content: `Data` freezes the record
      # but not its members, so a Hash of leaked bytes would otherwise pass.
      class CommandRedacted < Declarative::Carrier
        attribute :tool_use_id, :lain_interned
        attribute :regions
        attribute :prior, default: 0
        validates :regions, :prior, numericality: { only_integer: true, greater_than_or_equal_to: 0,
                                                    message: "must be a non-negative Integer, got %<value>s" }
      end
    end

    # A `bash` result with spans masked: how many, and how many placeholders it
    # already held, never which bytes. `prior` defaults to 0 so a record
    # journaled before it existed still reads.
    CommandRedacted = Data.define(:tool_use_id, :regions, :prior) do
      include Journalable

      def initialize(tool_use_id:, regions:, prior: 0)
        settled = Carriers::CommandRedacted.settle!(tool_use_id:, regions:, prior:)

        super(**settled, regions: settled[:regions].to_i, prior: settled[:prior].to_i)
      end
    end
  end
end
