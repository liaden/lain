# frozen_string_literal: true

require "json"
require "time"

require_relative "bedrock_raw/transport"

module Lain
  class Provider
    # The forked Bedrock provider: Lain's own HTTP transport over the Mantle
    # endpoint instead of the official SDK's `BedrockMantleClient`. It is to
    # {Provider::Bedrock} exactly what {Provider::AnthropicRaw} is to
    # {Provider::Anthropic} -- same {AnthropicEncoding}, same block-preserving
    # reassembly, so `#encode` is byte-identical to the oracle (the dry
    # differential proves it) and the response keeps the FULL, ordered block list
    # with every extended-thinking signature intact (gate 1).
    #
    # Mantle speaks the plain Anthropic Messages API over SSE, so the streaming
    # parse is Anthropic-shaped: this reuses {AnthropicRaw::StreamAssembler} by
    # explicit reference rather than promoting it to a shared namespace (a third
    # raw arm is what would earn that move, not the second). What it does NOT
    # share is {AnthropicRaw::Transport}, which is bound by inheritance to the
    # direct-Anthropic backend; see {Transport}.
    class BedrockRaw < Provider
      include AnthropicEncoding

      # Bedrock model ids carry the `anthropic.` vendor prefix; PriceBook's
      # family-substring matching resolves them unchanged.
      DEFAULT_MODEL = "anthropic.claude-opus-4-8"
      CAPABILITIES = %i[streaming prompt_caching strict_tools thinking parallel_tool_use].freeze

      # Mantle returns the same `anthropic-ratelimit-*-reset` headers as the
      # direct API; token limits bind first on large agentic prompts, so the
      # tokens reset feeds faraday-retry's backoff until a live 429 says otherwise.
      RATE_LIMIT_RESET_HEADER = "anthropic-ratelimit-tokens-reset"

      NUMERIC_SECONDS = /\A\d+(\.\d+)?\z/

      # faraday-retry's default header parser understands only seconds or an
      # RFC2822 date. The reset headers are RFC3339 and `retry-after` is plain
      # seconds, so one parser must handle both: a bare number is seconds,
      # anything else is a timestamp turned into seconds-from-now (never negative).
      RESET_HEADER_PARSER = lambda do |value|
        string = value.to_s
        return if string.empty?
        return string.to_f if string.match?(NUMERIC_SECONDS)

        [Time.iso8601(string) - Time.now, 0.0].max
      rescue ArgumentError
        nil
      end

      # Wraps a vendored transport error so nothing above the Provider rescues a
      # Provider::HTTP class. The original is preserved as `#cause`.
      class APIError < Lain::Error; end

      # A non-2xx response; `#status` is lifted out so callers branch on it
      # without unwrapping `#cause`.
      class APIStatusError < APIError
        attr_reader :status

        def initialize(message = nil, status: nil)
          super(message)
          @status = status
        end
      end

      # @param transport [#sync_post, #stream] injected in specs; a real
      #   {Transport} over the vendored connection otherwise.
      # @param channel [Lain::Channel] where retry events are journaled
      # @param sink [Lain::Sink] where the transport's debug/log lines go
      # @param api_key [String, nil] the bearer token; falls back to
      #   `AWS_BEARER_TOKEN_BEDROCK`
      # @param region [String, nil] the Mantle region; falls back to `AWS_REGION`
      def initialize(transport: nil, config: nil, channel: Channel::Null.instance, sink: Sink::Null.new,
                     api_key: nil, api_base: nil, region: nil)
        super()
        @channel = channel
        @config = config || build_config(api_key:, api_base:, region:)
        @transport = transport || Transport.new(@config, sink:)
      end

      def capabilities = CAPABILITIES

      # One round trip into a neutral Response. Streaming by default (Context
      # renders `stream: true`); both paths converge on the full block list and
      # parsed tool inputs.
      def complete(request)
        build_response(dispatch(request))
      rescue Provider::HTTP::Error => e
        raise wrap_error(e)
      end

      private

      # Env fallbacks live here, at the provider layer, not in Configuration:
      # the vendored config deliberately has no ENV defaults for provider options
      # (mirrors AnthropicRaw#build_config's ENV.fetch). The Mantle client's own
      # precedence is `AWS_BEARER_TOKEN_BEDROCK` then `AWS_REGION`.
      def build_config(api_key:, api_base:, region:)
        config = Provider::HTTP::Configuration.new
        config.bedrock_api_key = api_key || ENV.fetch("AWS_BEARER_TOKEN_BEDROCK", nil)
        config.bedrock_region = region || ENV.fetch("AWS_REGION", nil)
        config.bedrock_api_base = api_base unless api_base.nil?
        config.retry_block = retry_journal
        config.exhausted_retries_block = exhausted_journal
        config.rate_limit_reset_header = RATE_LIMIT_RESET_HEADER
        config.header_parser_block = RESET_HEADER_PARSER
        config
      end

      # The wire body: encode's `system_` kwarg becomes `system`, and `stream` is
      # added as the top-level field the SDK expressed by method choice instead.
      def wire_payload(request)
        payload = encode(request)
        payload[:system] = payload.delete(:system_) if payload.key?(:system_)
        payload[:stream] = request.stream
        payload
      end

      def dispatch(request)
        payload = wire_payload(request)
        request.stream ? stream_dispatch(payload) : sync_dispatch(payload)
      end

      def stream_dispatch(payload)
        assembler = AnthropicRaw::StreamAssembler.new
        @transport.stream(payload) { |data| assembler.add(data) }
        assembler.result
      end

      def sync_dispatch(payload)
        body = @transport.sync_post(payload).body || {}
        AnthropicRaw::StreamAssembler::Assembled.new(id: body["id"], model: body["model"],
                                                     stop_reason: body["stop_reason"],
                                                     content: body["content"] || [], usage: body["usage"] || {})
      end

      def build_response(assembled)
        Response.new(id: assembled.id, model: assembled.model,
                     content: normalize_tool_inputs(assembled.content),
                     stop_reason: assembled.stop_reason, usage: build_usage(assembled.usage), raw: assembled)
      end

      def normalize_tool_inputs(content)
        content.map { |block| normalize_tool_input(block) }
      end

      # Belt-and-suspenders on the Response#tool_uses contract: the streaming
      # assembler already parses tool inputs and the sync body arrives parsed, but
      # a String must never reach the Timeline.
      def normalize_tool_input(block)
        return block unless block.is_a?(Hash) && block["type"] == "tool_use" && block["input"].is_a?(String)

        block.merge("input" => JSON.parse(block["input"]))
      end

      def build_usage(usage)
        Usage.new(input_tokens: usage["input_tokens"], output_tokens: usage["output_tokens"],
                  cache_creation_input_tokens: usage["cache_creation_input_tokens"],
                  cache_read_input_tokens: usage["cache_read_input_tokens"])
      end

      def wrap_error(error)
        status = error.response.respond_to?(:status) ? error.response.status : nil
        status ? APIStatusError.new(error.message, status:) : APIError.new(error.message)
      end

      def retry_journal
        channel = @channel
        lambda do |env:, retry_count:, exception:, will_retry_in:, **|
          channel.push(Event::ProviderRetry.new(attempt: retry_count + 1, will_retry_in:,
                                                status: env[:status], reason: exception.class.name))
        end
      end

      def exhausted_journal
        channel = @channel
        lambda do |env:, exception:, options:|
          channel.push(Event::ProviderRetry.new(attempt: options.max, will_retry_in: nil,
                                                status: env[:status], reason: exception.class.name))
        end
      end
    end
  end
end
