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
      def to_a = floored(named(variables) + detected_values + hinted_tokens)

      # The regions the detector finds in passed values, which a request
      # leaving the machine is refused on. A hinted token is not among them:
      # the hinted bar is lowered for a connection-string name, and it admits
      # a bucket or host name as readily as a password.
      #
      # @return [Array<String>] frozen
      def detected_values = @detected_values ||= passed.flat_map { |_, value| regions(value.to_s) }.freeze

      private

      def variables = [@child_env.environment, @lent].flat_map(&:to_a)

      def floored(values) = values.select { _1.bytesize >= FLOOR }.uniq.freeze

      def named(variables) = variables.filter_map { |name, value| value.to_s if Exec::ChildEnv::SECRET.match?(name) }

      def passed = variables.select { |name, _| @child_env.passes?(name) }

      def hinted_tokens = passed.flat_map { |name, value| hinted(name, value.to_s) }

      # Every passed variable is read as hinted, so a digest-width value in one stays a secret.
      def regions(value) = Regions.detect(value, hinted: true).map(&:bytes)

      def hinted(name, value)
        return [] unless HINTED.match?(name)

        value.b.scan(HINTED_TOKEN).select { Entropy.hinted?(_1.delete_suffix("=").delete_suffix("=")) }
      end
    end
  end
end
