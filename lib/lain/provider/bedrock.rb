# frozen_string_literal: true

require "json"
require "anthropic"

module Lain
  class Provider
    # Anthropic models via AWS Bedrock's Mantle endpoint, on the official SDK's
    # `BedrockMantleClient` -- the correctness oracle for the Bedrock arm, as
    # {Provider::Anthropic} is for the direct one. Mantle speaks the plain
    # Anthropic Messages API over SSE (model in the body, ordinary streaming),
    # so {AnthropicEncoding} is shared verbatim and only the client, the
    # `anthropic.`-prefixed model ids, and the endpoint differ.
    #
    # Bearer/API-key mode only: `api_key:` (or `AWS_BEARER_TOKEN_BEDROCK`) sends
    # `Authorization: Bearer` and never signs with SigV4. The SDK still requires
    # `aws-sdk-core` eagerly at client construction -- before it branches on
    # auth mode -- which is the sole reason that gem is a dependency.
    class Bedrock < Provider
      include AnthropicEncoding

      # Bedrock model ids carry the `anthropic.` vendor prefix; PriceBook's
      # family-substring matching resolves them unchanged.
      DEFAULT_MODEL = "anthropic.claude-opus-4-8"

      # Bedrock's own feature mask, and it has now earned its divergence from
      # Provider::Anthropic's: Mantle's request validator rejects the tools'
      # `strict` field outright ("tools.0.custom.strict: Extra inputs are not
      # permitted", a live 400), so :strict_tools is deliberately absent and
      # {AnthropicEncoding#mask_strict} keeps the field off the wire.
      CAPABILITIES = %i[streaming prompt_caching thinking parallel_tool_use].freeze

      # Wraps every `Anthropic::Errors::*` so nothing above the Provider ever
      # rescues an SDK class; the original survives as `#cause`.
      class APIError < Lain::Error; end

      # A non-2xx response. `#status` is the HTTP status Integer, lifted out of
      # the SDK error so callers can branch on it without unwrapping `#cause`.
      class APIStatusError < APIError
        attr_reader :status

        def initialize(message = nil, status: nil)
          super(message)
          @status = status
        end
      end

      # @param client [Anthropic::BedrockMantleClient, nil] injected in specs;
      #   a real Mantle client otherwise (bearer token and region from
      #   `api_key:`/`aws_region:` or their env defaults).
      def initialize(client: nil, **client_options)
        super()
        @client = client || ::Anthropic::BedrockMantleClient.new(**client_options)
      end

      def capabilities = CAPABILITIES

      # Mantle speaks the plain Anthropic Messages API -- same cache
      # economics as the direct oracle.
      def cache_profile = CacheProfile::ANTHROPIC

      # #encode is supplied by {AnthropicEncoding}, shared with the other
      # Anthropic-shaped backends so they cannot drift apart on the wire.

      # One round trip into a neutral Response. Streaming by default; both paths
      # converge on parsed tool inputs and the FULL block list (text, thinking,
      # tool_use), because dropping thinking or tool_use blocks corrupts the
      # very next turn (correctness gate 1).
      def complete(request)
        build_response(dispatch(request))
      rescue ::Anthropic::Errors::APIStatusError => e
        raise APIStatusError.new(e.message, status: e.status)
      rescue ::Anthropic::Errors::Error => e
        raise APIError, e.message
      end

      private

      def dispatch(request)
        params = encode(request)
        return @client.messages.create(params) unless request.stream

        # The stream is single-pass and `accumulated_message` drains it exactly
        # once, mutating its snapshot in place; consume it once only.
        @client.messages.stream(params).accumulated_message
      end

      def build_response(message)
        Response.new(
          id: message.id,
          model: message.model,
          content: message.content.map { |block| encode_block(block) },
          stop_reason: message.stop_reason,
          usage: build_usage(message.usage),
          raw: message
        )
      end

      # Block `.type` is a Symbol on responses. We rebuild each block as a plain
      # Hash rather than trusting `#to_h`, because the tool_use case must
      # reparse a streamed String input; Canonical.normalize downstream
      # stringifies the keys, which is intended.
      def encode_block(block)
        case block.type
        when :text then { "type" => "text", "text" => block.text }
        when :thinking then { "type" => "thinking", "thinking" => block.thinking, "signature" => block.signature }
        when :redacted_thinking then { "type" => "redacted_thinking", "data" => block.data }
        when :tool_use then encode_tool_use(block)
        # Unknown block types survive as their raw payload rather than being
        # dropped; the enums are non-exhaustive by contract.
        else block.to_h
        end
      end

      def encode_tool_use(block)
        { "type" => "tool_use", "id" => block.id, "name" => block.name, "input" => parse_input(block.input) }
      end

      # The streaming trap, resolved: raw-hash tools yield `input` as a JSON
      # String; `create` yields a parsed Hash. Parse only the former.
      def parse_input(input)
        input.is_a?(String) ? JSON.parse(input, symbolize_names: false) : input
      end

      def build_usage(usage)
        Usage.new(
          input_tokens: usage.input_tokens,
          output_tokens: usage.output_tokens,
          cache_creation_input_tokens: usage.cache_creation_input_tokens,
          cache_read_input_tokens: usage.cache_read_input_tokens
        )
      end
    end
  end
end
