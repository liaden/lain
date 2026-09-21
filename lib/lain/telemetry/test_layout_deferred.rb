# frozen_string_literal: true

module Lain
  module Telemetry
    # A test written before the class it describes, and let through for that
    # reason. The record is how a reader finds the ones whose class never came,
    # before the land-time check refuses them.
    TestLayoutDeferred = Data.define(:tool_use_id, :tool, :path, :reason) do
      include Journalable

      def initialize(tool_use_id:, tool:, path:, reason:)
        super(tool_use_id: tool_use_id.to_s.dup.freeze, tool: tool.to_s.dup.freeze, path: path.to_s.dup.freeze,
              reason: reason.to_s.dup.freeze)
      end
    end
  end
end
