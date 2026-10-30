# frozen_string_literal: true

module Lain
  class Config
    # The opening every config table shares: nil is an empty table, anything
    # but a Hash is refused, and a key the table does not know is refused.
    module Table
      # @param table [Hash{String=>Object}, nil]
      # @param path [String, nil] the config file and line to name
      # @param name [String] the table's name as the refusal prints it
      # @param keys [Array<String>, nil] the known keys; nil leaves them open
      # @return [Hash{String=>Object}]
      # @raise [Refusal] for a non-table, or a key outside `keys`
      def self.read(table, path:, name:, keys:)
        table = {} if table.nil?
        raise Refusal.not_a_table(table, path:, table: name) unless table.is_a?(Hash)

        unknown = keys ? table.keys - keys : []
        raise Refusal.unknown_keys(unknown, known: keys, path:, table: name) unless unknown.empty?

        table
      end
    end
  end
end
