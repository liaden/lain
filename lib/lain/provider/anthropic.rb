# frozen_string_literal: true

require "json"
require "anthropic"

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
      include StreamStartedSignal

      # A short prompt will not cache (Opus 4.8's minimum cacheable prefix is
      # 4096 tokens), but that is silent rather than an error, so the default is
      # generous enough to be worth caching when the caller does not say.
      DEFAULT_MODEL = "claude-opus-4-8"

      # Only what this provider can actually demonstrate. Notably absent:
      # server-side compaction and context editing live on the Beta message
      # family, which this class deliberately does not target.
      # `structured_output` here means tool-FORCING (force one tool, its input schema
      # is the answer shape) -- a weaker guarantee than Ollama's grammar-constrained
      # decoding under the same capability name. Argument-schema conformance rides on
      # the model unless `strict_tools` is also engaged.
      CAPABILITIES = %i[streaming prompt_caching strict_tools thinking parallel_tool_use structured_output].freeze

      # Wraps every `Anthropic::Errors::*` so nothing above the Provider ever
      # rescues an SDK class. The original is preserved as `#cause` (Ruby sets it
      # automatically when we re-raise inside the rescue), so a caller that wants
      # the wire details can still reach them without depending on the SDK type.
      #
      # UNRELATED to {AnthropicRaw::APIError}: same name, same shape, no shared
      # ancestor besides {Lain::Error} -- verified nothing above the Provider
      # rescues either by name today (Backend can now hand chat either backend
      # depending on whether journaling is on, see T17w). A future caller that
      # wants to rescue "an Anthropic API error" regardless of which backend
      # produced it must handle both explicitly, or a shared marker module must
      # be introduced first -- do not assume `rescue Anthropic::APIError` catches
      # an {AnthropicRaw} failure, or vice versa.
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
      # @param channel [Lain::Channel] where CE-5's stream_started event lands
      def initialize(client: nil, channel: Channel::Null.instance, **client_options)
        super()
        @client = client || ::Anthropic::Client.new(**client_options)
        @channel = channel
      end

      def capabilities = CAPABILITIES

      # The oracle's cache economics -- every other Anthropic-shaped backend
      # (AnthropicRaw, Bedrock, BedrockRaw) answers with this exact object,
      # promoted off what used to be a per-provider `CACHE_PROFILE` Hash
      # constant here (CAC-2/F1) into {Lain::CacheProfile}, the neutral home.
      def cache_profile = CacheProfile::ANTHROPIC

      # #encode is supplied by {AnthropicEncoding}, shared verbatim with
      # {AnthropicRaw} so the two backends cannot drift apart on the wire.

      # One round trip into a neutral Response. Streaming by default; both paths
      # converge on parsed tool inputs and the FULL block list (text, thinking,
      # tool_use), because dropping thinking or tool_use blocks corrupts the very
      # next turn (correctness gate 1). `on_stream_started` is CE-5's signal --
      # see {StreamStartedSignal}.
      def complete(request, on_stream_started: nil)
        build_response(dispatch(request, on_stream_started))
      rescue ::Anthropic::Errors::APIStatusError => e
        raise APIStatusError.new(e.message, status: e.status)
      rescue ::Anthropic::Errors::Error => e
        raise APIError, e.message
      end

      private

      def dispatch(request, on_stream_started)
        params = encode(request)
        return @client.messages.create(params) unless request.stream

        stream_dispatch(@client.messages.stream(params), request, on_stream_started)
      end

      # The stream is single-pass: `MessageStream#each` drains the ONE
      # memoized Enumerator `accumulated_message` also drains via its own
      # `each {}` (see `MessageStream#until_done`), so this is that one pass,
      # driven by us instead of by `accumulated_message` -- not a second one.
      # The SDK's `fused_enum` guards its generator with a `fused` flag
      # closed over the Enumerator itself, so calling `#each` again (inside
      # `accumulated_message`, right after) is a documented-safe no-op that
      # just returns the snapshot our pass already built, then applies
      # `parse_content_blocks!` -- the ordinary, blessed way to finish. CE-5
      # needs to see the moment the first event arrives (`message_start`,
      # BEFORE any content_block event), and this is the only pass allowed,
      # so it is also where the signal has to fire.
      def stream_dispatch(stream, request, on_stream_started)
        stream.each_with_index do |_event, index|
          emit_stream_started(request, on_stream_started) if index.zero?
        end
        stream.accumulated_message
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
