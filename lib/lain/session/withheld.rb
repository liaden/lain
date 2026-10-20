# frozen_string_literal: true

module Lain
  class Session
    # The sources the model saw masked: one add-only set over every kind, so a
    # resumed session refuses a rewrite of any of them from one fold.
    class Withheld
      # `kind` is a closed set and `key` a value, so a new kind is one constructor.
      Source = Data.define(:kind, :key) do
        def self.file(path) = new(kind: :file, key: path)

        def self.memory(id) = new(kind: :memory, key: id)

        def initialize(kind:, key:)
          kind = kind.to_s.to_sym
          raise ArgumentError, "kind must be one of #{KINDS.inspect}, got #{kind.inspect}" unless KINDS.include?(kind)

          super(kind:, key: -key.to_s)
        end
      end

      KINDS = %i[file memory].freeze

      def initialize = @sources = Set.new

      # @param source [Source]
      # @return [self]
      def record(source)
        @sources << source
        self
      end

      # @param source [Source]
      # @return [Boolean]
      def withheld?(source) = @sources.include?(source)

      # @param kind [Symbol]
      # @return [Array<String>] the keys withheld of that kind
      def keys(kind) = @sources.select { _1.kind == kind }.map(&:key)
    end
  end
end
