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

      # Reline claims every other control key's default, so a "C-<letter>" works only where no keymap holds it.
      # Keys lain binds itself, read from the constants that bind them so the two cannot drift.
      def self.held
        { Frontend::Completion::KEY => "completion", CLI::ComposedPrompt::KEY => "compose" }
      end
      private_class_method :held

      ACCEPTED = '"S-Tab", the key that works today (every "C-<letter>" is held by the line editor or by lain)'

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
        settings.each { |key, value| check!(key, value, path:, declared: table.key?(key)) }
        new(**settings.transform_keys(&:to_sym))
      end

      # @return [Keys] every key at its default
      def self.empty = from(nil, path: nil)

      def self.check!(key, value, path:, declared:)
        raise Refusal.new("#{key} must be #{ACCEPTED}, got #{value.inspect}", path:, table: TABLE, key:, value:) unless
          value.is_a?(String) && Frontend::LineEditor::Registry.name?(value)

        return unless declared

        holder = holder_of(value)
        raise Refusal.new("#{key} #{value} is lain's #{holder} key", path:, table: TABLE, key:, value:) if holder

        claim = Frontend::LineEditor.claim_on(value)
        raise Refusal.new("#{key} #{value} is held by #{claim}", path:, table: TABLE, key:, value:) if claim
      end
      private_class_method :check!

      def self.holder_of(value)
        held.find { |name, _| Frontend::LineEditor.keystroke(name) == Frontend::LineEditor.keystroke(value) }&.last
      end
      private_class_method :holder_of
    end
  end
end
