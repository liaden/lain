# frozen_string_literal: true

require_relative "anthropic/retry_tap"
require_relative "anthropic/stream_assembler"
require_relative "anthropic/transport"

module Lain
  class Provider
    # The forked provider: Lain's own HTTP transport instead of the official SDK.
    #
    # It shares {AnthropicEncoding} with {Provider::AnthropicReference}, so `#encode`
    # produces byte-identical kwargs (the dry differential proves it), and drives
    # the vendored Faraday/SSE stack through {Transport}. What it does NOT share is
    # the SDK's -- or RubyLLM's -- response model: both flatten the content array,
    # and this returns a {Lain::Response} carrying the FULL, ordered block list
    # with every extended-thinking signature intact (gate 1).
    #
    # == encode vs. the wire
    #
    # `#encode` returns the SDK's `system_:` kwargs so the dry-diff can compare it
    # against the oracle. {AnthropicWire#wire_payload} rewrites that one key to
    # the wire `system` and adds the top-level `stream` flag -- the only two
    # places the neutral kwargs and the actual JSON body differ, which is why
    # they live on the far side of the encode/wire split rather than in
    # {AnthropicEncoding}, whose output the oracles must keep seeing as kwargs.
    class Anthropic < Provider
      include AnthropicEncoding
      # The wire body, the wire response, and the rate-limit backoff -- shared
      # with {Provider::Bedrock}, which speaks the same Messages API. That is
      # also where RATE_LIMIT_RESET_HEADER and RESET_HEADER_PARSER now live;
      # constant lookup walks ancestors, so `Anthropic::RATE_LIMIT_RESET_HEADER`
      # still resolves.
      include AnthropicWire
      # APIError / APIStatusError, nested here and rooted at Lain::Error.
      #
      # UNRELATED to {Provider::AnthropicReference::APIError}: same name, same
      # shape, no shared ancestor besides {Lain::Error} -- verified nothing
      # above the Provider rescues either by name today (Backend can hand chat
      # either backend depending on whether journaling is on, see T17w). A
      # caller wanting "an Anthropic API error" regardless of which backend
      # produced it must handle both explicitly, or a shared marker module must
      # be introduced first -- do not assume `rescue Anthropic::APIError`
      # catches an SDK-oracle failure, or vice versa.
      include ErrorWrapping.under(Lain::Error)
      include StreamStartedSignal

      DEFAULT_MODEL = "claude-opus-4-8"
      CAPABILITIES = %i[streaming prompt_caching strict_tools thinking parallel_tool_use].freeze

      # @param transport [#sync_post, #stream] injected in specs; a real
      #   {Transport} over the vendored connection otherwise.
      # @param channel [Lain::Channel] where retry and stream_started (CE-5) events land
      # @param sink [Lain::Sink] where the transport's debug/log lines go
      # @param spool [#open_frame] where the raw response bytes are teed; the Null
      #   spool by default, so no WAL file exists unless a session opts in
      def initialize(transport: nil, config: nil, channel: Channel::Null.instance, sink: Sink::Null.new,
                     spool: Spool::Null.new, api_key: nil, api_base: nil)
        super()
        @channel = channel
        @retries = RetryTap.new(spool:, channel:)
        @config = config || build_config(api_key:, api_base:)
        @transport = transport || Transport.new(@config, sink:)
      end

      def capabilities = CAPABILITIES

      # Same wire, same cache economics as the SDK oracle -- the dry
      # differential proves #encode is byte-identical, so this must not drift.
      def cache_profile = CacheProfile::ANTHROPIC

      # One round trip into a neutral Response. Streaming by default (Context
      # renders `stream: true`); both paths converge on the full block list and
      # parsed tool inputs. `on_stream_started` is CE-5's signal -- see
      # {StreamStartedSignal} -- never called on the non-streaming path.
      def complete(request, on_stream_started: nil)
        wrapping_errors { build_response(dispatch(request, on_stream_started)) }
      end

      private

      def build_config(api_key:, api_base:)
        config = Provider::HTTP::Configuration.new
        config.anthropic_api_key = api_key || ENV.fetch("ANTHROPIC_API_KEY", nil)
        config.anthropic_api_base = api_base unless api_base.nil?
        # HTTP::Configuration's own request_timeout/max_retries (300 / 3) are
        # vendored ruby_llm generic defaults, not Anthropic's -- T17w's fix round:
        # Backend now hands this transport live --journal chat traffic where the
        # SDK client (Anthropic::Client::DEFAULT_TIMEOUT_IN_SECONDS = 600,
        # DEFAULT_MAX_RETRIES = 2) used to sit, so the effective envelope must
        # match those, not silently trade timeout/retry budget for a WAL. Set
        # HERE, not on Configuration's own default, so Ollama/Bedrock (their own
        # constructors, their own Configuration) are untouched; bench's raw
        # provider inherits these too, which only tightens its fidelity.
        config.request_timeout = 600
        config.max_retries = 2
        config.retry_block = @retries.retry_block
        config.exhausted_retries_block = @retries.exhausted_block
        apply_rate_limit_backoff(config)
      end

      # The Provider owns frame opening (it computes the digest) AND attempt
      # boundaries: the frame is threaded onto the request context so a retry
      # rotates THIS request's frame rather than concatenating two attempts into
      # one -- reentrant across parallel subagents sharing one Provider (see
      # {RetryTap}).
      def dispatch(request, on_stream_started)
        payload = wire_payload(request)
        frame = @retries.open_frame(request_digest: request.digest)
        request.stream ? stream_dispatch(payload, frame, request, on_stream_started) : sync_dispatch(payload, frame)
      end

      # CE-5: the FIRST data chunk the transport hands back is always the
      # response's own first SSE event (`message_start`, ahead of any
      # `content_block_start`), so signaling before handing it to the
      # assembler is signaling before any content_block event -- no need to
      # inspect `data["type"]` here. `signaled` covers the whole round trip,
      # not just one attempt: a retry (see {RetryTap}) is still the SAME
      # logical request, and a stagger scheduler awaiting `request.digest`
      # wants exactly one signal for it, not one per attempt.
      def stream_dispatch(payload, frame, request, on_stream_started)
        assembler = StreamAssembler.new
        signaled = false
        @transport.stream(payload, frame:) do |data|
          unless signaled
            signaled = true
            emit_stream_started(request, on_stream_started)
          end
          assembler.add(data)
        end
        assembler.result
      end

      def sync_dispatch(payload, frame)
        body = @transport.sync_post(payload, frame:).body || {}
        StreamAssembler::Assembled.new(id: body["id"], model: body["model"], stop_reason: body["stop_reason"],
                                       content: body["content"] || [], usage: body["usage"] || {})
      end
    end
  end
end
