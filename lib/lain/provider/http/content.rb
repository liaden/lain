# frozen_string_literal: true

# Vendored from ruby_llm 1.16.0 (2cf34b9), lib/ruby_llm/content.rb.
# Changed: RubyLLM:: -> Lain::Provider::HTTP::.
#
# Leak site 9 (content.rb:41,44,47 -- Attachment): the entire attachment
# branch is gone. Upstream Content wraps text plus an array of image/pdf/text
# Attachments; we do not vendor Attachment (or `marcel`, which it needs to
# sniff MIME types), so Content here is text-only, exactly as the porting
# brief specifies. The `transport` branch replaces Content outright with
# `Lain::Response`'s content-block array; this class only has to hold
# together long enough for the vendored `chat.rb`/`tools.rb` payload
# rendering to run and be spec'd against the SDK oracle.

module Lain
  class Provider
    module HTTP
      # Text content sent to or received from the model. No attachments --
      # see the file header.
      class Content
        attr_reader :text

        def initialize(text = nil)
          raise ArgumentError, "Content text cannot be nil" if text.nil?

          @text = text
        end

        def format
          @text
        end

        def empty?
          @text.nil? || (@text.respond_to?(:empty?) && @text.empty?)
        end

        def to_h
          { text: @text }
        end
      end

      class Content
        # A provider-specific payload that should bypass our formatting and go
        # straight to the wire as-is.
        class Raw
          attr_reader :value

          def initialize(value)
            raise ArgumentError, "Raw content payload cannot be nil" if value.nil?

            @value = value
          end

          def format
            @value
          end

          def to_h
            @value
          end
        end
      end
    end
  end
end
