# frozen_string_literal: true

module Lain
  class Sensitivity
    # The environment values a command's output is masked for wherever they
    # recur, because no detector stands behind them.
    class Literals
      # Higher than the floor {Rows::Row} seeks a recurrence at, because an
      # environment value has no detector behind it: a 6 or 7 byte value such
      # as "staging" recurs in ordinary output, and the placeholders would
      # spell it back out.
      FLOOR = 8

      # @param child_env [Exec::ChildEnv] the environment a child would inherit
      # @param lent [Hash] the worker's environment; a child gets whatever its
      #   caller lends, whatever the name
      def initialize(child_env:, lent: {})
        @child_env = child_env
        @lent = lent
      end

      # @return [Array<String>] the unique secret-named values of at least {FLOOR} bytes
      def to_a
        [@child_env.environment, @lent].flat_map(&:to_a).filter_map do |name, value|
          value if Exec::ChildEnv::SECRET.match?(name) && value.to_s.bytesize >= FLOOR
        end.uniq.freeze
      end
    end
  end
end
