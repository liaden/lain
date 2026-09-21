# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A layout refusal names the file it refused and the rule that refused
      # it, so a reader can set policy per rule without parsing the prose. The
      # rules are the guard's own published list, {TestLayout::Guard::REFUSING}.
      class TestLayoutRefused < Declarative::Carrier
        attribute :path
        attribute :rule
        validates :path, presence: { message: "must name the refused path, got nil" }
        validates :rule, inclusion: { in: TestLayout::Guard::REFUSING,
                                      message: "must be a rule the test layout guard refuses under, got %<value>s" }
      end
    end

    # A write the test layout refused, so nothing was written. `expected` is
    # the path the layout would accept the same content at, or nil where the
    # guard could name none.
    TestLayoutRefused = Data.define(:tool_use_id, :tool, :path, :rule, :expected, :reason) do
      include Journalable

      def initialize(tool_use_id:, tool:, path:, rule:, expected:, reason:)
        Carriers::TestLayoutRefused.check!(path:, rule:)

        super(tool_use_id: tool_use_id.to_s.dup.freeze, tool: tool.to_s.dup.freeze, path: path.to_s.dup.freeze,
              rule:, expected: expected&.then { -_1.to_s }, reason: reason.to_s.dup.freeze)
      end
    end
  end
end
