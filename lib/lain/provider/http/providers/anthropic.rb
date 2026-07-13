# frozen_string_literal: true

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/providers/anthropic.rb.
# Changed: RubyLLM:: -> Lain::Provider::HTTP::.
#
# Leak site 7 (anthropic.rb:7-12): upstream includes six modules --
# Chat, Embeddings, Media, Models, Streaming, Tools -- plus a
# `class << self; def capabilities; Anthropic::Capabilities; end; end`.
# Only Chat, Streaming, and Tools are vendored. Dropping Embeddings, Media,
# and Models (and the `capabilities` override that required `Models`) is
# what keeps `Attachment`/`marcel`/the model registry out of this slice in
# one move -- see docs/porting-providers.md for the full trace.
#
# The class shell below is declared BEFORE requiring anthropic/{chat,
# streaming,tools}, and only reopened after. Upstream relies on zeitwerk:
# referencing `Providers::Anthropic` autoloads this file first, so by the
# time `Anthropic::Chat` is autoloaded it is reopening a class that already
# has `Provider` as its superclass. Without zeitwerk, requiring the
# submodules before `class Anthropic < Provider` existed would define a
# bare `class Anthropic` (superclass Object) three times over, and then
# restating `< Provider` afterward would raise "superclass mismatch". One
# `module Lain` nesting is kept open around both halves (rather than two
# top-level `module Lain...end` blocks) so Style/OneClassPerFile sees one
# top-level definition, matching every other file in this slice.
module Lain
  class Provider
    module HTTP
      # Namespace for wire-protocol implementations, one per backend. Only
      # Anthropic is vendored in this slice.
      module Providers
        # Anthropic Claude API integration: payload rendering, streaming
        # chunk parsing, and tool-call formatting. Chat/completion only --
        # no embeddings, no media, no model registry (leak site 7).
        class Anthropic < Provider
        end

        require_relative "anthropic/chat"
        require_relative "anthropic/streaming"
        require_relative "anthropic/tools"

        # Reopened once Chat/Streaming/Tools exist, to mix them in.
        class Anthropic
          include Anthropic::Chat
          include Anthropic::Streaming
          include Anthropic::Tools

          def api_base
            @config.anthropic_api_base || "https://api.anthropic.com"
          end

          def headers
            {
              "x-api-key" => @config.anthropic_api_key,
              "anthropic-version" => "2023-06-01"
            }
          end

          class << self
            def configuration_options
              %i[anthropic_api_key anthropic_api_base]
            end

            def configuration_requirements
              %i[anthropic_api_key]
            end
          end
        end
      end
    end
  end
end

Lain::Provider::HTTP::Provider.register(:anthropic, Lain::Provider::HTTP::Providers::Anthropic)
