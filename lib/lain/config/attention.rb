# frozen_string_literal: true

module Lain
  class Config
    Attention = Data.define(:delay)

    # The `attention` table of the user's config.rb: how long a blocked or
    # finished chat waits before it asks for the person. Only the user's file
    # may declare it, because how soon to be interrupted is a property of the
    # person, not of a project.
    class Attention
      TABLE = "`attention`"
      DEFAULTS = { "delay" => 30 }.freeze
      KEYS = DEFAULTS.keys.freeze

      # @param table [Hash{String=>Object}, nil]
      # @param path [String, nil] the config file and line to name
      # @return [Attention]
      # @raise [Refusal] for an unknown key, or a delay that is not a number of seconds from 0 up
      def self.from(table, path:)
        table = Table.read(table, path:, name: TABLE, keys: KEYS)
        delay = DEFAULTS.merge(table).fetch("delay")
        unless delay.is_a?(Numeric) && delay.real? && delay.finite? && delay >= 0
          raise Refusal.new("delay must be a finite number of seconds, 0 or more, got #{delay.inspect}",
                            path:, table: TABLE, key: "delay", value: delay)
        end

        new(delay:)
      end

      # @return [Attention] the delay at its default
      def self.empty = from(nil, path: nil)
    end
  end
end
