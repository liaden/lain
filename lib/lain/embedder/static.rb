# frozen_string_literal: true

module Lain
  class Embedder
    # A deterministic, offline embedder: each text becomes a term-frequency
    # vector over a fixed vocabulary. It is a pure function of (vocabulary, text),
    # so the same text always yields byte-identical Floats -- which is exactly
    # what a memory-retrieval sweep needs as a determinism oracle, and why it is
    # the PHI-free bench arm (nothing leaves the process, no model to leak into).
    #
    # The vector's dimension is the vocabulary size, so every vector this
    # embedder returns is equal-length by construction. Out-of-vocabulary tokens
    # are ignored rather than hashed into a bucket -- a fixed, inspectable basis
    # is worth more here than coverage.
    class Static < Embedder
      TOKEN = /[a-z0-9]+/

      # @param vocabulary [Array<String>] the fixed basis; de-duplicated (a
      #   repeated term must not inflate the dimension) with first-seen order kept
      #   so the vector's axes are stable and readable.
      def initialize(vocabulary:)
        super()
        @vocabulary = vocabulary.map(&:to_s).uniq.freeze
      end

      def embed(texts)
        raise Error, "embed takes an Array of texts, got #{texts.class}" unless texts.is_a?(Array)

        texts.map { |text| vectorize(text) }
      end

      private

      def vectorize(text)
        counts = tokenize(text).tally
        @vocabulary.map { |term| counts.fetch(term, 0).to_f }
      end

      def tokenize(text)
        text.to_s.downcase.scan(TOKEN)
      end
    end
  end
end
