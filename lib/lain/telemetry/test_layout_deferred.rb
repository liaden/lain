# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # Every field is a short name or path, interned.
      class TestLayoutDeferred < Declarative::Carrier
        attribute :tool_use_id, :lain_interned
        attribute :tool, :lain_interned
        attribute :path, :lain_interned
        attribute :reason, :lain_interned
      end
    end

    # A test written before the class it describes, and let through for that
    # reason. The record is how a reader finds the ones whose class never came,
    # before the land-time check refuses them.
    TestLayoutDeferred = Data.define(:tool_use_id, :tool, :path, :reason) do
      include Journalable

      def initialize(tool_use_id:, tool:, path:, reason:)
        super(**Carriers::TestLayoutDeferred.settle!(tool_use_id:, tool:, path:, reason:))
      end
    end
  end
end
