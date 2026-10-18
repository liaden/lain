# frozen_string_literal: true

module Lain
  class Sensitivity
    # The environment values a command's output is masked for wherever they
    # recur, because no detector stands behind them.
    #
    # A passed variable lists only the regions {Regions.detect} finds in its
    # value, never the value whole: a DSN gives its password, which a pipeline
    # can cut out of the URL where the output detector no longer sees a URL,
    # while `RAILS_ENV=development` lists nothing and "development" stays legible.
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

      # @return [Array<String>] the unique secret-named values, and regions of
      #   passed values, of at least {FLOOR} bytes
      def to_a
        variables = [@child_env.environment, @lent].flat_map(&:to_a)
        (named(variables) + detected(variables)).select { _1.bytesize >= FLOOR }.uniq.freeze
      end

      private

      def named(variables) = variables.filter_map { |name, value| value.to_s if Exec::ChildEnv::SECRET.match?(name) }

      def detected(variables)
        variables.select { |name, _| @child_env.passes?(name) }
                 .flat_map { |_, value| Regions.detect(value.to_s).map(&:bytes) }
      end
    end
  end
end
