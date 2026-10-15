# frozen_string_literal: true

module Lain
  class Config
    Keys = Data.define(:approval_cycle)

    # The `keys` table of the user's config.rb: which key does what at the
    # prompt. Only the user's file may declare it, because a key is a property
    # of the person's terminal, not of a project.
    class Keys
      TABLE = "`keys`"
      DEFAULTS = { "approval_cycle" => "S-Tab" }.freeze
      KEYS = DEFAULTS.keys.freeze

      ACCEPTED = '"C-<letter>" such as "C-x", or "S-Tab"'

      # @param table [Hash{String=>Object}, nil]
      # @param path [String, nil] the config file and line to name
      # @return [Keys]
      # @raise [Refusal] for an unknown key, or a name the line editor cannot bind
      def self.from(table, path:)
        table = {} if table.nil?
        raise Refusal.not_a_table(table, path:, table: TABLE) unless table.is_a?(Hash)

        unknown = table.keys - KEYS
        raise Refusal.unknown_keys(unknown, known: KEYS, path:, table: TABLE) unless unknown.empty?

        settings = DEFAULTS.merge(table)
        settings.each { |key, value| check!(key, value, path:) }
        new(**settings.transform_keys(&:to_sym))
      end

      # @return [Keys] every key at its default
      def self.empty = from(nil, path: nil)

      def self.check!(key, value, path:)
        return if value.is_a?(String) && Frontend::LineEditor::Registry.name?(value)

        raise Refusal.new("#{key} must be #{ACCEPTED}, got #{value.inspect}", path:, table: TABLE, key:, value:)
      end
      private_class_method :check!
    end
  end
end
