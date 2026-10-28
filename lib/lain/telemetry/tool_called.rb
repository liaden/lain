# frozen_string_literal: true

module Lain
  module Telemetry
    # A tool call at one of its two edges, so the human sees what is running
    # while it runs and how it ended. `summary` is one masked line naming the
    # call's target, never file bytes. `phase` is `:start` or `:end`; `outcome`
    # and `seconds` are nil until the end.
    ToolCalled = Data.define(:tool_use_id, :tool, :summary, :phase, :outcome, :seconds) do
      include Journalable

      def initialize(tool_use_id:, tool:, summary:, phase:, outcome:, seconds:)
        super(tool_use_id: tool_use_id.to_s.dup.freeze, tool: tool.to_s.dup.freeze, summary: summary.to_s.dup.freeze,
              phase:, outcome: outcome && outcome.to_s.dup.freeze, seconds:)
      end
    end
  end
end
