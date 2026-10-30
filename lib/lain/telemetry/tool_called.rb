# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A phase other than start or end would journal a value no reader can place, so it is refused.
      class ToolCalled < Declarative::Carrier
        attribute :tool_use_id, :lain_interned
        attribute :tool, :lain_interned
        attribute :summary, :lain_interned
        attribute :phase, :lain_interned
        attribute :outcome
        attribute :seconds
        validates :phase, inclusion: { in: %w[start end] }
      end
    end

    # A tool call at one of its two edges, so the human sees what is running
    # while it runs and how it ended. `summary` is one masked line naming the
    # call's target, never file bytes. `phase` is `"start"` or `"end"`; `outcome`
    # and `seconds` are nil until the end.
    ToolCalled = Data.define(:tool_use_id, :tool, :summary, :phase, :outcome, :seconds) do
      include Journalable

      def initialize(tool_use_id:, tool:, summary:, phase:, outcome:, seconds:)
        super(**Carriers::ToolCalled.settle!(tool_use_id:, tool:, summary:, phase:, outcome:, seconds:))
      end
    end
  end
end
