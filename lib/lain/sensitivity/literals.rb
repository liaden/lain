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
    # A passed name matching {HINTED} also lists each token {Entropy.hinted?}
    # accepts, a bar the region detector would not lower for every value.
    class Literals
      # Higher than the floor {Rows::Row} seeks a recurrence at, because an
      # environment value has no detector behind it: a 6 or 7 byte value such
      # as "staging" recurs in ordinary output, and the placeholders would
      # spell it back out.
      FLOOR = 8

      # A name that says its value is a connection string, where a token too
      # short for the region detector's bar is still most likely a credential.
      # `CONN` is anchored so `CONNECTOR_NAME` is not taken for one.
      HINTED = /(?:_URL|_URI|_DSN)\z|DATABASE|CONN(?:ECTION)?(?:_|\z)/i
      # `sig=<token>` yields the token and not the key, and leaving `/` out
      # yields the key after `scheme://`. The padding is listed because it is
      # printed, but not measured, because it is not random.
      HINTED_TOKEN = /[A-Za-z0-9+_-]{#{Entropy::HINTED_LENGTH},}={0,2}/

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
                 .flat_map { |name, value| regions(value.to_s) + hinted(name, value.to_s) }
      end

      def regions(value) = Regions.detect(value).map(&:bytes)

      def hinted(name, value)
        return [] unless HINTED.match?(name)

        value.b.scan(HINTED_TOKEN).select { Entropy.hinted?(_1.delete_suffix("=").delete_suffix("=")) }
      end
    end
  end
end
