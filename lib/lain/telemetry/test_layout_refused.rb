# frozen_string_literal: true

module Lain
  module Telemetry
    module Carriers
      # A layout refusal names the file it refused and the rule that refused
      # it, so a reader can set policy per rule without parsing the prose. The
      # rules are the guard's own published list, {TestLayout::Guard::REFUSING}.
      class TestLayoutRefused < Declarative::Carrier
        NAMED = {
          path: "must name the refused path"
        }.freeze

        attribute :tool_use_id, :lain_interned
        attribute :tool, :lain_interned
        attribute :path, :lain_interned
        attribute :rule
        attribute :expected
        attribute :reason, :lain_interned
        validates :path, presence: { message: "must name the refused path, got nil" }
        validates :rule, inclusion: { in: TestLayout::Guard::REFUSING,
                                      message: "must be a rule the test layout guard refuses under, got %<value>s" }

        validate :names_are_not_blank

        private

        # The interning cast turns false, [] and {} into present Strings, so blankness is judged on the raw value.
        def names_are_not_blank
          NAMED.each do |name, text|
            raw = @attributes[name.to_s].value_before_type_cast
            errors.add(name, "#{text}, got #{raw.inspect}") if raw.blank? && !errors.include?(name)
          end
        end
      end
    end

    # A write the test layout refused, so nothing was written. `expected` is
    # the path the layout would accept the same content at, or nil where the
    # guard could name none.
    TestLayoutRefused = Data.define(:tool_use_id, :tool, :path, :rule, :expected, :reason) do
      include Journalable

      def initialize(tool_use_id:, tool:, path:, rule:, expected:, reason:)
        super(**Carriers::TestLayoutRefused.settle!(tool_use_id:, tool:, path:, rule:,
                                                    expected: expected && -expected.to_s, reason:))
      end
    end
  end
end
