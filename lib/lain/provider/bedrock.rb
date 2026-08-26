# frozen_string_literal: true

require_relative "bedrock/transport"

module Lain
  class Provider
    # The SHIPPED Bedrock provider: Lain's own HTTP transport over the Mantle
    # endpoint. It is to {Provider::BedrockReference} exactly what
    # {Provider::Anthropic} is to {Provider::AnthropicReference} -- same
    # {AnthropicEncoding}, same block-preserving reassembly, so `#encode` is
    # byte-identical to the oracle and the response keeps the FULL, ordered block
    # list with every extended-thinking signature intact.
    #
    # Mantle speaks the plain Anthropic Messages API over SSE, so
    # {Anthropic::StreamAssembler} and {Anthropic::RetryTap} are reused by
    # explicit reference. Promoting them to a shared namespace is OWED --
    # {Provider::Ollama::RetryTap} is a third arm of largely this shape -- and
    # deliberately deferred rather than forgotten. What is NOT shared is
    # {Anthropic::Transport}, bound by inheritance to the direct-Anthropic
    # backend.
    #
    # == What Bedrock deliberately does not have
    #
    # No `spool:`: there is no Bedrock response WAL, so nothing can be salvaged
    # from a crash on this arm. The {Anthropic::RetryTap} it borrows is nil-safe
    # about the missing frame, so the attempt-boundary rule arrives the day a
    # spool lands.
    #
    # No `on_stream_started`, so a stagger scheduler cannot pace this arm --
    # #complete takes no such keyword rather than accepting and ignoring one.
    #
    # No timeout/retry envelope of its own: HTTP::Configuration's vendored
    # ruby_llm defaults stand, because Mantle has no documented client default
    # to mirror.
    class Bedrock < Provider
      include AnthropicEncoding
      include AnthropicWire
      include ErrorWrapping.under(Lain::Error)

      # Bedrock model ids carry the `anthropic.` vendor prefix; PriceBook's
      # family-substring matching resolves them unchanged.
      DEFAULT_MODEL = "anthropic.claude-opus-4-8"
      # No :strict_tools -- Mantle 400s on the tools' `strict` field. Must
      # mirror {Provider::BedrockReference::CAPABILITIES}, which the dry
      # differential proves.
      CAPABILITIES = %i[streaming prompt_caching thinking parallel_tool_use].freeze

      # @param transport [#sync_post, #stream] injected in specs; a real
      #   {Transport} over the vendored connection otherwise.
      # @param config [Provider::HTTP::Configuration, nil] injected in specs; otherwise built by
      #   {#build_config} from `api_key:`/`region:`/`api_base:`, leaving HTTP::Configuration's
      #   vendored 300s/3-retry envelope in place (Mantle has no documented client default to
      #   mirror).
      # @param channel [Lain::Channel] where retry events are journaled
      # @param sink [Lain::Sink] where the transport's debug/log lines go
      # @param api_key [String, nil] the bearer token; falls back to
      #   `AWS_BEARER_TOKEN_BEDROCK`
      # @param api_base [String, nil] overrides `bedrock_api_base`; ignored when `config:` is
      #   given directly
      # @param region [String, nil] the Mantle region; falls back to `AWS_REGION`
      def initialize(transport: nil, config: nil, channel: Channel::Null.instance, sink: Sink::Null.new,
                     api_key: nil, api_base: nil, region: nil)
        super()
        # Spool::Null because this arm has no WAL (see the class comment); the
        # tap's frame rotation is a no-op without one, its journaling is not.
        @retries = Anthropic::RetryTap.new(spool: Spool::Null.new, channel:)
        @config = config || build_config(api_key:, api_base:, region:)
        @transport = transport || Transport.new(@config, sink:)
      end

      def capabilities = CAPABILITIES

      # Mantle speaks the plain Anthropic Messages API -- same cache
      # economics as the direct oracle.
      def cache_profile = CacheProfile::ANTHROPIC

      # One round trip into a neutral Response. Streaming by default (Context
      # renders `stream: true`); both paths converge on the full block list and
      # parsed tool inputs.
      def complete(request)
        wrapping_errors { build_response(dispatch(request)) }
      end

      private

      # Env fallbacks live here, at the provider layer, not in Configuration:
      # the vendored config deliberately has no ENV defaults for provider options
      # (mirrors Anthropic#build_config's ENV.fetch). The Mantle client's own
      # precedence is `AWS_BEARER_TOKEN_BEDROCK` then `AWS_REGION`.
      def build_config(api_key:, api_base:, region:)
        config = Provider::HTTP::Configuration.new
        config.bedrock_api_key = api_key || ENV.fetch("AWS_BEARER_TOKEN_BEDROCK", nil)
        config.bedrock_region = region || ENV.fetch("AWS_REGION", nil)
        config.bedrock_api_base = api_base unless api_base.nil?
        config.retry_block = @retries.retry_block
        config.exhausted_retries_block = @retries.exhausted_block
        apply_rate_limit_backoff(config)
      end

      def dispatch(request)
        payload = wire_payload(request)
        request.stream ? stream_dispatch(payload) : sync_dispatch(payload)
      end

      def stream_dispatch(payload)
        assembler = Anthropic::StreamAssembler.new
        @transport.stream(payload) { |data| assembler.add(data) }
        assembler.result
      end

      def sync_dispatch(payload)
        body = @transport.sync_post(payload).body || {}
        Anthropic::StreamAssembler::Assembled.new(id: body["id"], model: body["model"],
                                                  stop_reason: body["stop_reason"],
                                                  content: body["content"] || [], usage: body["usage"] || {})
      end
    end
  end
end
