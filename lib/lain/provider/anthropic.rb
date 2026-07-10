# frozen_string_literal: true

require "json"
require "anthropic"

require_relative "../provider"
require_relative "../response"
require_relative "../usage"
require_relative "../canonical"
require_relative "anthropic_encoding"

module Lain
  class Provider
    # The reference provider, on the official `anthropic` gem (net/http, no
    # Faraday). This is where Lain's neutral vocabulary is reconciled with the
    # one wire format we treat as canonical; RubyLLM is measured against it.
    #
    # == Why the streaming path is the default, and what it costs
    #
    # Agentic turns want a large `max_tokens`, which exceeds the SDK's
    # non-streaming ceiling, so {#complete} streams unless a Request opts out.
    # Streaming buys one sharp asymmetry we have to pay for here rather than
    # leaking upward: with raw-hash tool schemas (ours), the SDK never coerces a
    # `tool_use` block's `input` -- it hands back the raw JSON *String* it
    # accumulated. Non-streaming `create` returns it already parsed. Correctness
    # gate 5 forbids anything above the Provider from string-matching serialized
    # JSON, so {#complete} parses that String itself and both paths emerge
    # identical: a Response whose `tool_use` inputs are parsed Hashes.
    class Anthropic < Provider
      include AnthropicEncoding

      # A short prompt will not cache (Opus 4.8's minimum cacheable prefix is
      # 4096 tokens), but that is silent rather than an error, so the default is
      # generous enough to be worth caching when the caller does not say.
      DEFAULT_MODEL = "claude-opus-4-8"

      # Only what this provider can actually demonstrate. Notably absent:
      # server-side compaction and context editing live on the Beta message
      # family, which this class deliberately does not target.
      CAPABILITIES = %i[streaming prompt_caching strict_tools thinking parallel_tool_use].freeze

      # Wraps every `Anthropic::Errors::*` so nothing above the Provider ever
      # rescues an SDK class. The original is preserved as `#cause` (Ruby sets it
      # automatically when we re-raise inside the rescue), so a caller that wants
      # the wire details can still reach them without depending on the SDK type.
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

      # @param client [Anthropic::Client, nil] injected in specs; a real client
      #   reading ANTHROPIC_API_KEY from the environment otherwise.
      def initialize(client: nil, **client_options)
        super()
        @client = client || ::Anthropic::Client.new(**client_options)
      end

      def capabilities = CAPABILITIES

      # #encode is supplied by {AnthropicEncoding}, shared verbatim with
      # {AnthropicRaw} so the two backends cannot drift apart on the wire.

      # One round trip into a neutral Response. Streaming by default; both paths
      # converge on parsed tool inputs and the FULL block list (text, thinking,
      # tool_use), because dropping thinking or tool_use blocks corrupts the very
      # next turn (correctness gate 1).
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
      # Hash rather than trusting `#to_h`, because the tool_use case must reparse
      # a streamed String input; Canonical.normalize downstream stringifies the
      # keys, which is intended.
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
