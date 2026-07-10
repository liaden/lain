# frozen_string_literal: true

require_relative "message"

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/chunk.rb, verbatim
# apart from RubyLLM:: -> Lain::Provider::HTTP::.

module Lain
  class Provider
    module HTTP
      # One streamed fragment, shaped exactly like a Message so
      # StreamAccumulator can fold a sequence of these into one.
      class Chunk < Message
      end
    end
  end
end
