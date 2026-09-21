# frozen_string_literal: true

module Lain
  class Provider
    module HTTP
      # Namespace for wire-protocol implementations, one per backend. Only
      # Anthropic is vendored in this slice.
      module Providers
        # Anthropic Claude API integration: payload rendering, streaming
        # chunk parsing, and tool-call formatting. Chat/completion only --
        # no embeddings, no media, no model registry.
        #
        # Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/providers/anthropic.rb.
        # Changed: RubyLLM:: -> Lain::Provider::HTTP::.
        #
        # Upstream includes six modules -- Chat, Embeddings, Media, Models,
        # Streaming, Tools -- plus a `class << self; def capabilities;
        # Anthropic::Capabilities; end; end`. Only Chat, Streaming, and Tools
        # are vendored. Dropping Embeddings, Media, and Models (and the
        # `capabilities` override that required `Models`) is what keeps
        # `Attachment`/`marcel`/the model registry out of this slice in one
        # move -- see docs/porting-providers.md for the full trace.
        #
        # This file names NONE of the three: each of `anthropic/{chat,
        # streaming,tools}.rb` mixes itself in as it loads. Including them from
        # here instead is a cycle -- the three reopen this class, so whichever
        # of them the loader reaches first would find this file's `include`
        # waiting on a require already in flight. The methods below are the
        # class's own and win over a mixin regardless of the order the three
        # arrive in, and the three share no method name.
        #
        # `eager_load` is what makes that safe, and it is the ONLY thing.
        # Reached lazily -- this file autoloaded on its own, its siblings not
        # yet read -- this class is a wire protocol with no payload assembly:
        # `render_payload` simply absent, a NoMethodError on a request path
        # rather than a NameError at boot. `lib/lain.rb` eager loads and says
        # why; `spec/.../providers/anthropic_spec.rb` pins the completeness
        # that guarantee buys, deriving the expected mixins from the directory
        # so a fourth file added here and never included is a red spec.
        class Anthropic < Provider
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
