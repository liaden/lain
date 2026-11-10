# frozen_string_literal: true

module Lain
  class Sensitivity
    module Regions
      # Each shape's own Onigmo pass over the bytes. The oracle {RustScanner} is held to, and its
      # fallback for a shape the Rust scan could not finish.
      class RubyScanner
        # @param shapes [Hash{String => Regexp}] by the names a row reports
        def initialize(shapes = RustShapes::SHAPES)
          @shapes = shapes
        end

        # Groups read as the Rust scan reports them: a shape with names reports each name that took
        # part, the last of a repeated one; a shape with none reports its numbered groups as "1", "2".
        #
        # @param bytes [String] BINARY
        # @return [Array<Array(String, Integer, Integer, Hash{String => Array(Integer, Integer)})>]
        #   shape name, start, end and groups, shape by shape in text order
        def scan(bytes)
          @shapes.flat_map do |name, shape|
            bytes.to_enum(:scan, shape).map { row(name, Regexp.last_match) }
          end
        end

        private

        def row(name, match) = [name, match.begin(0), match.end(0), groups(match)]

        def groups(match)
          keys = match.names.empty? ? (1...match.size).to_a : match.names.uniq
          keys.filter_map { |key| match.begin(key) && [key.to_s, [match.begin(key), match.end(key)]] }.to_h
        end
      end
    end
  end
end
