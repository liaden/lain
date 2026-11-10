# frozen_string_literal: true

module Lain
  class Sensitivity
    module Regions
      # Every shape in 1 Rust scan of the bytes. A shape the scan reports over its backtrack limit
      # comes back with no matches at all, so {RubyScanner} rescans that shape alone: a limit never
      # under-masks.
      class RustScanner
        # @return [RustScanner] the one production scanner; it compiles nothing until it first scans
        def self.default = DEFAULT

        # @param bytes [String] BINARY
        # @return [Array<Array(String, Integer, Integer, Hash{String => Array(Integer, Integer)})>]
        #   rows as {RubyScanner#scan} returns them
        def scan(bytes)
          scan = RustShapes.compiled.scan(bytes)
          names = RustShapes.names
          rows = scan.matches.map { |index, start, finish, groups| [names.fetch(index), start, finish, groups] }
          limited = scan.limited
          return rows if limited.empty?

          rows + RubyScanner.new(RustShapes::SHAPES.slice(*limited.map { names.fetch(_1) })).scan(bytes)
        end

        DEFAULT = new
      end
    end
  end
end
