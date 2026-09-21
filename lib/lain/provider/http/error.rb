# frozen_string_literal: true

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/error.rb.
# Changed: RubyLLM:: -> Lain::Provider::HTTP::. Dropped UnsupportedAttachmentError
# (leak site 10 -- image/audio APIs are out of scope; see VENDOR.md).
#
# Upstream keeps the whole family in this one file and reaches them through
# eager loading. Here each sibling sits at the path its own name implies, so
# {ErrorMiddleware}'s status table -- which names six of them while its class
# body runs -- resolves whatever order the loader arrives in, rather than
# because this file happens to sort first.

module Lain
  class Provider
    module HTTP
      # Wraps API errors from the wire into a consistent, provider-neutral shape.
      class Error < StandardError
        attr_reader :response

        def initialize(response = nil, message = nil)
          if response.is_a?(String)
            message = response
            response = nil
          end

          @response = response
          super(message || response&.body)
        end
      end
    end
  end
end
