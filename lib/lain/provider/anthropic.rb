# frozen_string_literal: true

require "json"
require "anthropic"

require_relative "../provider"
require_relative "../response"
require_relative "../usage"
require_relative "../canonical"

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
      # A short prompt will not cache (Opus 4.8's minimum cacheable prefix is
      # 4096 tokens), but that is silent rather than an error, so the default is
      # generous enough to be worth caching when the caller does not say.
      DEFAULT_MODEL = "claude-opus-4-8"

      # Anthropic's cache lookback only reaches ~20 content blocks back from a
      # breakpoint. A long agentic turn of tool_use/tool_result pairs sails past
      # that window, and the cached prefix silently shrinks to whatever sits
      # under the last breakpoint. Dropping an intermediate breakpoint every
      # STRIDE blocks keeps the window populated. (Anthropic caps *total*
      # breakpoints at four; keeping the count in bounds is a Context-layer
      # concern -- here we only guarantee the window is never starved.)
      CACHE_STRIDE = 15

      # `cache_control` in Anthropic's only currently offered flavor. Named once
      # so the emitted marker is a single shared, frozen object.
      EPHEMERAL = { "type" => "ephemeral" }.freeze

      # The neutral key a Context uses to mark a block for caching. It is not a
      # wire field, so it must be stripped from every emitted payload.
      CACHE_MARKER = "cache"

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

      # The exact kwargs Hash the SDK would receive. Pure and deterministic: no
      # network, no clock, no ordering that depends on how the Request's Hashes
      # were built. `stream` is intentionally NOT a key here -- the SDK encodes
      # streaming by *which method* you call (`create` vs `stream`), and passing
      # the wrong `stream:` value raises. {#complete} owns that choice.
      def encode(request)
        params = { model: request.model, max_tokens: request.max_tokens,
                   messages: encode_messages(request.messages),
                   system_: request.system && encode_system(request.system),
                   tools: (encode_tools(request.tools) unless request.tools.empty?),
                   thinking: request.reasoning }
        # #extra is the provider-specific escape hatch (temperature, tool_choice,
        # ...); symbol keys so it lands on the SDK param model's named fields.
        params.compact.merge(request.extra.transform_keys(&:to_sym))
      end

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

      def encode_system(system)
        # A plain String system prompt carries no cache marker; only the block
        # form can be tagged.
        return system if system.is_a?(String)

        system.map { |block| translate_block(block) }
      end

      def encode_tools(tools)
        # Already Canonical-normalized by the Request, but re-normalizing is
        # idempotent and states the cache-stability contract at the seam that
        # actually emits bytes. Tool blocks may also carry the neutral marker.
        Canonical.normalize(tools).map { |tool| translate_block(tool) }
      end

      # Walks every content block across all messages with one running counter,
      # so intermediate cache breakpoints land on absolute block positions rather
      # than resetting per message -- the lookback window does not care about
      # message boundaries.
      def encode_messages(messages)
        position = [0]
        messages.map do |message|
          { "role" => message["role"], "content" => encode_content(message["content"], position) }
        end
      end

      def encode_content(content, position)
        return content unless content.is_a?(Array)

        content.map do |block|
          position[0] += 1
          with_stride_breakpoint(translate_block(block), position[0])
        end
      end

      # Translate Lain's neutral cache marker into Anthropic's wire field and
      # strip the marker itself, which is not a wire field. A falsy marker is
      # simply removed. Non-Hash blocks (a bare String) pass through untouched.
      def translate_block(block)
        return block unless block.is_a?(Hash) && block.key?(CACHE_MARKER)

        cached = block[CACHE_MARKER]
        stripped = block.reject { |key, _| key == CACHE_MARKER }
        cached ? stripped.merge("cache_control" => EPHEMERAL) : stripped
      end

      def with_stride_breakpoint(block, position)
        return block unless block.is_a?(Hash)
        return block unless (position % CACHE_STRIDE).zero?
        return block if block.key?("cache_control")

        block.merge("cache_control" => EPHEMERAL)
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
