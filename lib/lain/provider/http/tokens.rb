# frozen_string_literal: true

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/tokens.rb. Changed:
# RubyLLM:: -> Lain::Provider::HTTP::, and the `reasoning` spelling of thinking
# (the kwarg and the three alias readers) is deleted, since every builder here
# speaks `thinking`. Not in the porting brief's
# file list, but Message#initialize and StreamAccumulator#to_message both
# build one -- see docs/porting-providers.md.

module Lain
  class Provider
    module HTTP
      # Token usage for one response, in the vendored provider's own vocabulary.
      # `Lain::Usage` is the neutral value object; the `transport` branch maps
      # into it. This is closure `Message`/`Chunk` need to exist at all.
      class Tokens
        attr_reader :input, :output, :cached, :cache_creation, :thinking

        def initialize(input: nil, output: nil, cached: nil, cache_creation: nil, thinking: nil)
          @input = input
          @output = output
          @cached = cached
          @cache_creation = cache_creation
          @thinking = thinking
        end

        def self.build(input: nil, output: nil, cached: nil, cache_creation: nil, thinking: nil)
          return nil if [input, output, cached, cache_creation, thinking].all?(&:nil?)

          new(input:, output:, cached:, cache_creation:, thinking:)
        end

        def to_h
          {
            input_tokens: input,
            output_tokens: output,
            cached_tokens: cached,
            cache_creation_tokens: cache_creation,
            thinking_tokens: thinking
          }.compact
        end
      end
    end
  end
end
