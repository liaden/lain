# frozen_string_literal: true

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/tool_call.rb, verbatim
# apart from RubyLLM:: -> Lain::Provider::HTTP::.

module Lain
  class Provider
    module HTTP
      # One function call the model asked for, as parsed off the wire (or
      # accumulated across streamed fragments -- see StreamAccumulator).
      class ToolCall
        attr_reader :id, :name, :arguments
        attr_accessor :thought_signature

        def initialize(id:, name:, arguments: {}, thought_signature: nil)
          @id = id
          @name = name
          @arguments = arguments
          @thought_signature = thought_signature
        end

        def to_h
          { id: @id, name: @name, arguments: @arguments, thought_signature: @thought_signature }.compact
        end
      end
    end
  end
end
