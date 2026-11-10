# frozen_string_literal: true

module Lain
  class Sensitivity
    module Regions
      # Every shape in 1 Rust scan of the bytes. What a shape could not finish comes back as a span it
      # over-masks, so a limit never under-masks and nothing is rescanned in Ruby.
      class RustScanner
        NO_GROUPS = {}.freeze
        private_constant :NO_GROUPS

        # @return [RustScanner] the one production scanner; it compiles nothing until it first scans
        def self.default = DEFAULT

        # @param bytes [String] BINARY
        # @return [Array<Array(String, Integer, Integer, Hash{String => Array(Integer, Integer)})>]
        #   rows of [shape name, start, finish, groups], then 1 row for each over-masked span, with no
        #   groups and a 5th element, true
        def scan(bytes)
          scan = RustShapes.compiled.scan(bytes)
          names = RustShapes.names
          scan.matches.map { |index, start, finish, groups| [names.fetch(index), start, finish, groups] } +
            scan.over_masked.map { |index, start, finish| [names.fetch(index), start, finish, NO_GROUPS, true] }
        end

        DEFAULT = new
      end
    end
  end
end
