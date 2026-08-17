# frozen_string_literal: true

require_relative "bedrock/transport"

module Lain
  class Provider
    # The SHIPPED Bedrock provider: Lain's own HTTP transport over the Mantle
    # endpoint, which is what `--provider bedrock` builds. It is to
    # {Provider::BedrockReference} exactly what {Provider::Anthropic} is to
    # {Provider::AnthropicReference} -- same {AnthropicEncoding}, same
    # block-preserving reassembly, so `#encode` is byte-identical to the oracle
    # (the dry differential proves it) and the response keeps the FULL, ordered
    # block list with every extended-thinking signature intact (gate 1).
    #
    # Mantle speaks the plain Anthropic Messages API over SSE, so the streaming
    # parse is Anthropic-shaped: this reuses {Anthropic::StreamAssembler} and
    # {Anthropic::RetryTap} by explicit reference rather than promoting them to a
    # shared namespace. The threshold that line named -- "a third such arm is
    # what would earn that move, not the second" -- HAS NOW BEEN CROSSED:
    # {Provider::Ollama::RetryTap} (T2/F7) is a third retry tap and is largely
    # this one's shape, differing only in having no spool to rotate. The
    # extraction is therefore OWED, and is deliberately deferred rather than
    # forgotten: T10 and T11 both build on retry and assembler behaviour, and
    # relocating the class while they are in flight buys a merge conflict on the
    # critical path for no behaviour change. What it does NOT share is
    # {Anthropic::Transport}, which is bound by inheritance to the
    # direct-Anthropic backend; see {Transport}.
    #
    # == What Bedrock deliberately does not have
    #
    # deliberately absent: a `spool:` -- there is no Bedrock response WAL, so
    # {Transport} threads no frame and nothing can be salvaged from a crash on
    # this arm. The {Anthropic::RetryTap} it borrows is nil-safe about the
    # missing frame, so adopting the tap costs nothing and means the day a spool
    # lands the attempt-boundary rule arrives with it.
    #
    # deliberately absent: `on_stream_started` (CE-5). {StreamStartedSignal} is
    # not included, so a stagger scheduler cannot pace this arm; #complete takes
    # no such keyword rather than accepting and ignoring one.
    #
    # deliberately absent: a timeout/retry envelope of its own. Unlike
    # {Anthropic#build_config}, this leaves HTTP::Configuration's vendored
    # ruby_llm defaults (300s, 3 retries) in place -- Mantle has no documented
    # client default to mirror.
    class Bedrock < Provider
      include AnthropicEncoding
      # The wire body, the wire response, and the rate-limit backoff -- shared
      # with {Provider::Anthropic}, which speaks the same Messages API.
      include AnthropicWire
      # APIError / APIStatusError, nested here and rooted at Lain::Error.
      include ErrorWrapping.under(Lain::Error)

      # Bedrock model ids carry the `anthropic.` vendor prefix; PriceBook's
      # family-substring matching resolves them unchanged.
      DEFAULT_MODEL = "anthropic.claude-opus-4-8"
      # No :strict_tools -- Mantle 400s on the tools' `strict` field; see
      # {Provider::BedrockReference::CAPABILITIES}, which this mask must mirror (the
      # dry differential proves both arms emit identical bytes).
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
      #
      # Both error arms come from {ErrorWrapping#wrapping_errors}. This backend
      # was missing the connection-level one while both siblings had it, which is
      # why the arms are no longer written out per backend.
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
