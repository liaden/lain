# frozen_string_literal: true

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/tokens.rb, verbatim
# apart from RubyLLM:: -> Lain::Provider::HTTP::. Not in the porting brief's
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

        def initialize(input: nil, output: nil, cached: nil, cache_creation: nil, thinking: nil, reasoning: nil)
          @input = input
          @output = output
          @cached = cached
          @cache_creation = cache_creation
          @thinking = thinking || reasoning
        end

        def self.build(input: nil, output: nil, cached: nil, cache_creation: nil, thinking: nil, reasoning: nil)
          return nil if [input, output, cached, cache_creation, thinking, reasoning].all?(&:nil?)

          new(input:, output:, cached:, cache_creation:, thinking:, reasoning:)
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

        def reasoning
          thinking
        end

        def cache_read
          cached
        end

        def cache_write
          cache_creation
        end
      end
    end
  end
end
