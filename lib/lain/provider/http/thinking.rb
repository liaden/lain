# frozen_string_literal: true

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/thinking.rb, verbatim
# apart from RubyLLM:: -> Lain::Provider::HTTP:: and dropping `#pretty_print`
# (a `pp`-integration nicety with no caller in this slice). Not in the
# porting brief's file list, but Message/Chunk/StreamAccumulator all build
# one -- see docs/porting-providers.md.

module Lain
  class Provider
    module HTTP
      # Extended-thinking output: text plus the signature Anthropic requires
      # echoed back verbatim on the next turn. `signature` survives here even
      # when `text` is redacted -- see the `Config` companion below for the
      # request-side toggle.
      class Thinking
        attr_reader :text, :signature

        def initialize(text: nil, signature: nil)
          @text = text
          @signature = signature
        end

        def self.build(text: nil, signature: nil)
          text = nil if text.is_a?(String) && text.empty?
          signature = nil if signature.is_a?(String) && signature.empty?

          return nil if text.nil? && signature.nil?

          new(text:, signature:)
        end
      end

      class Thinking
        # Normalized thinking config across providers: an effort level, a
        # token budget, or neither (disabled).
        class Config
          attr_reader :effort, :budget

          def initialize(effort: nil, budget: nil)
            @effort = effort.is_a?(Symbol) ? effort.to_s : effort
            @budget = budget
          end

          def enabled?
            !effort.nil? || !budget.nil?
          end
        end
      end
    end
  end
end
