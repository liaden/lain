# frozen_string_literal: true

module Lain
  module Shell
    # The one table of git subcommands that only read. A subcommand absent
    # here is not read-only, which is the safe answer for every one nobody
    # listed. The facets are independent: `read_only` is the gate for the rest.
    #
    # - `tree_free`: prints no file contents from the working tree
    # - `history_only`: reaches only the object database the output mask was read from
    module GitReads
      FACETS = %i[read_only tree_free history_only].freeze
      TABLE = {
        "log" => %i[read_only history_only],
        "show" => %i[read_only history_only],
        "diff" => %i[read_only],
        "grep" => %i[read_only],
        "blame" => %i[read_only],
        "cat-file" => %i[read_only],
        "status" => %i[read_only tree_free],
        "ls-files" => %i[read_only tree_free history_only],
        "ls-tree" => %i[read_only tree_free history_only],
        "rev-parse" => %i[read_only tree_free history_only],
        "shortlog" => %i[read_only tree_free history_only],
        "merge-base" => %i[read_only tree_free history_only],
        "describe" => %i[read_only history_only],
        "rev-list" => %i[read_only history_only],
        "for-each-ref" => %i[read_only]
      }.each_value(&:freeze).freeze

      # @param subcommand [String, nil]
      # @param facet [Symbol] one of {FACETS}
      # @return [Boolean]
      def self.facet?(subcommand, facet)
        raise ArgumentError, "unknown facet #{facet.inspect}" unless FACETS.include?(facet)

        TABLE.fetch(subcommand, []).include?(facet)
      end
    end
  end
end
