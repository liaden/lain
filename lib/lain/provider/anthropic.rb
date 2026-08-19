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
      # #admitted, over #resolved_endpoint and #queue_for_capacity? below.
      include Admitted

      DEFAULT_MODEL = "claude-opus-4-8"
      CAPABILITIES = %i[streaming prompt_caching strict_tools thinking parallel_tool_use].freeze

      # The endpoint a bare construction resolves to, and so the {Admission} key
      # it contends on. It restates the literal inside the vendored
      # {Provider::HTTP::Providers::Anthropic#api_base}, which has no constant to
      # borrow -- unlike {Ollama::Transport::DEFAULT_API_BASE}, which this
      # class's counterpart reuses directly.
      #
      # A RESTATEMENT IS A DRIFT HAZARD, so it is pinned rather than trusted:
      # `admission_spec.rb` asserts a real {Transport} over an empty config
      # resolves exactly this string. Two providers agreeing on a key neither of
      # them dials would satisfy every other example in that file while gating
      # nothing, which is the failure the pin exists to make loud.
      DEFAULT_API_BASE = "https://api.anthropic.com"

      # @param transport [#sync_post, #stream] injected in specs; a real
      #   {Transport} over the vendored connection otherwise.
      # @param config [Provider::HTTP::Configuration, nil] injected in specs; otherwise built by
      #   {#build_config}, which sets the 600s/2-retry envelope matching the old SDK client and
      #   wires `retry_block` to `@retries`.
      # @param channel [Lain::Channel] where retry and stream_started (CE-5) events land
      # @param sink [Lain::Sink] where the transport's debug/log lines go
      # @param spool [#open_frame] where the raw response bytes are teed; the Null
      #   spool by default, so no WAL file exists unless a session opts in
      # @param api_key [String, nil] falls back to `ANTHROPIC_API_KEY`; ignored when `config:`
      #   is given directly
      # @param api_base [String, nil] overrides `anthropic_api_base`; ignored when `config:` is
      #   given directly
      # @param queue [Boolean] whether this provider may WAIT for {Admission} to
      #   free a slot -- see {Provider::Ollama#initialize}, which documents the
      #   keyword and why it belongs to the caller rather than to a round trip.
      #   It is a no-op against the hosted default, which resolves NOT LOCAL and
      #   so takes {Admission::Null}; it starts mattering the moment `api_base:`
      #   points at a loopback proxy, and carrying it here rather than only on
      #   the local arm is what keeps the two providers one shape.
      def initialize(transport: nil, config: nil, channel: Channel::Null.instance, sink: Sink::Null.new,
                     spool: Spool::Null.new, api_key: nil, api_base: nil, queue: true)
        super()
        @queue = queue
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
      #
      # {Admission} wraps the WHOLE of this, for the reasons
      # {Provider::Ollama#complete} sets out at length: it is the one boundary
      # every round trip crosses, the stall clock arms below it, and the
      # compaction oracle awaits above it. Against the hosted default the gate is
      # {Admission::Null} and this costs a Hash lookup -- concurrent subagents
      # must not serialise on one hosted endpoint -- but the seam is here so an
      # `api_base:` aimed at a loopback proxy is gated like any other local
      # server, rather than by which class happened to build the client.
      def complete(request, on_stream_started: nil)
        admitted { wrapping_errors { build_response(dispatch(request, on_stream_started)) } }
      end

      private

      # {Admitted}'s two collaborators. The endpoint is read off the same
      # Configuration {Transport#api_base} reads, with the same fallback -- see
      # {DEFAULT_API_BASE} for why that fallback is restated and how the
      # restatement is pinned.
      def queue_for_capacity? = @queue

      def resolved_endpoint = @config.anthropic_api_base || DEFAULT_API_BASE

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
