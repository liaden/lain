# frozen_string_literal: true

module Lain
  class Config
    Todos = Data.define(:file)

    # The `todos` table: which file in the project root holds the chores.
    class Todos
      TABLE = "`todos`"
      DEFAULT = "TODOS.md"
      KEYS = %w[file].freeze

      # @param table [Hash{String=>Object}, nil]
      # @param path [String, nil] the config file and line to name
      # @return [Todos]
      # @raise [Refusal] for an unknown key, or a file that is not a bare name
      def self.from(table, path:)
        table = {} if table.nil?
        raise Refusal.not_a_table(table, path:, table: TABLE) unless table.is_a?(Hash)

        unknown = table.keys - KEYS
        raise Refusal.unknown_keys(unknown, known: KEYS, path:, table: TABLE) unless unknown.empty?

        file = table.fetch("file", DEFAULT)
        unless bare?(file)
          raise Refusal.new("file must be a bare file name, got #{file.inspect}", path:, table: TABLE, key: "file",
                                                                                  value: file)
        end

        new(file: -file)
      end

      # @return [Todos] the default file
      def self.empty = from(nil, path: nil)

      def self.bare?(file)
        file.is_a?(String) && !file.empty? && file == File.basename(file) && !%w[. ..].include?(file)
      end
      private_class_method :bare?
    end
  end
end
