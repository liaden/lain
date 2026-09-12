# frozen_string_literal: true

require_relative "anthropic/retry_tap"
require_relative "anthropic/stream_assembler"
require_relative "anthropic/transport"

module Lain
  class Provider
    # The forked provider: Lain's own HTTP transport instead of the official SDK.
    #
    # It shares {AnthropicEncoding} with {Provider::AnthropicReference}, so
    # `#encode` produces byte-identical kwargs (the dry differential proves it).
    # What it does NOT share is the SDK's -- or RubyLLM's -- response model:
    # both flatten the content array, and this returns a {Lain::Response}
    # carrying the FULL, ordered block list with every extended-thinking
    # signature intact.
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
      # Also where RATE_LIMIT_RESET_HEADER and RESET_HEADER_PARSER live;
      # constant lookup walks ancestors, so `Anthropic::RATE_LIMIT_RESET_HEADER`
      # still resolves.
      include AnthropicWire
      # APIError / APIStatusError, nested here and rooted at Lain::Error, and
      # UNRELATED to {Provider::AnthropicReference::APIError}: same name, same
      # shape, no shared ancestor besides {Lain::Error}. Do not assume `rescue
      # Anthropic::APIError` catches an SDK-oracle failure, or vice versa --
      # a caller wanting either must handle both explicitly.
      include ErrorWrapping.under(Lain::Error)
      include StreamStartedSignal
      include Admitted

      DEFAULT_MODEL = "claude-opus-4-8"
      CAPABILITIES = %i[streaming prompt_caching strict_tools thinking parallel_tool_use].freeze

      # The {Admission} key a bare construction contends on. It RESTATES the
      # literal inside the vendored {Provider::HTTP::Providers::Anthropic#api_base},
      # which has no constant to borrow, so it is pinned by spec rather than
      # trusted: two providers agreeing on a key neither of them dials would
      # satisfy every other admission example while gating nothing.
      DEFAULT_API_BASE = "https://api.anthropic.com"

      # @param transport [#sync_post, #stream] injected in specs; a real
      #   {Transport} over the vendored connection otherwise.
      # @param config [Provider::HTTP::Configuration, nil] injected in specs; otherwise built by
      #   {#build_config}, which sets the 600s/2-retry envelope matching the old SDK client and
      #   wires `retry_block` to `@retries`.
      # @param channel [Lain::Channel] where retry and stream_started events land
      # @param sink [Lain::Sink] where the transport's debug/log lines go
      # @param spool [#open_frame] where the raw response bytes are teed; the Null
      #   spool by default, so no WAL file exists unless a session opts in
      # @param api_key [String, nil] falls back to `ANTHROPIC_API_KEY`; ignored when `config:`
      #   is given directly
      # @param api_base [String, nil] overrides `anthropic_api_base`; ignored when `config:` is
      #   given directly
      # @param queue [Boolean] whether this provider may WAIT for {Admission} to
      #   free a slot -- see {Provider::Ollama#initialize}. A no-op against the
      #   hosted default, which resolves NOT LOCAL and takes {Admission::Null};
      #   it starts mattering the moment `api_base:` points at a loopback proxy.
      # @param journal [#<<] where a {Telemetry::ProviderWait} lands when this
      #   provider QUEUES for capacity -- see {Provider::Ollama#initialize} for
      #   why this is not `channel:`.
      def initialize(transport: nil, config: nil, channel: Channel::Null.instance, sink: Sink::Null.new,
                     spool: Spool::Null.new, api_key: nil, api_base: nil, queue: true,
                     journal: Channel::Null::INSTANCE)
        super()
        @queue = queue
        @journal = journal
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
      # parsed tool inputs. `on_stream_started` is the stream-started signal --
      # see {StreamStartedSignal} -- never called on the non-streaming path.
      #
      # {Admission} wraps the WHOLE of this, for the reasons
      # {Provider::Ollama#complete} sets out. Against the hosted default the gate
      # is {Admission::Null} and this costs a Hash lookup -- concurrent
      # subagents must not serialise on one hosted endpoint -- but the seam is
      # here so an `api_base:` aimed at a loopback proxy is gated like any other
      # local server, rather than by which class happened to build the client.
      def complete(request, on_stream_started: nil)
        admitted { wrapping_errors { build_response(dispatch(request, on_stream_started)) } }
      end

      private

      # {Admitted}'s collaborators. The endpoint is read off the same
      # Configuration {Transport#api_base} reads, with the same fallback. The
      # journal is the session's record, not `@channel`: one is what a human
      # watches, the other is what a round of QA reads back.
      def queue_for_capacity? = @queue

      def wait_journal = @journal

      def resolved_endpoint = @config.anthropic_api_base || DEFAULT_API_BASE

      def build_config(api_key:, api_base:)
        config = Provider::HTTP::Configuration.new
        config.anthropic_api_key = api_key || ENV.fetch("ANTHROPIC_API_KEY", nil)
        config.anthropic_api_base = api_base unless api_base.nil?
        # HTTP::Configuration's own 300/3 are vendored ruby_llm generic
        # defaults, not Anthropic's. This transport sits where the SDK client
        # (600s, 2 retries) used to, so the effective envelope must match those
        # rather than silently trade timeout/retry budget for a WAL. Set HERE
        # and not on Configuration's default, so Ollama is
        # untouched.
        config.request_timeout = 600
        config.max_retries = 2
        config.retry_block = @retries.retry_block
        config.exhausted_retries_block = @retries.exhausted_block
        apply_rate_limit_backoff(config)
      end

      # The Provider owns frame opening because it computes the digest. The
      # frame is threaded onto the request context so a retry rotates THIS
      # request's frame rather than concatenating two attempts into one --
      # reentrant across parallel subagents sharing one Provider.
      def dispatch(request, on_stream_started)
        payload = wire_payload(request)
        frame = @retries.open_frame(request_digest: request.digest)
        request.stream ? stream_dispatch(payload, frame, request, on_stream_started) : sync_dispatch(payload, frame)
      end

      # The FIRST data chunk is always the response's own `message_start`,
      # ahead of any `content_block_start`, so signalling before handing it to
      # the assembler is signalling before any content_block event -- no need to
      # inspect `data["type"]`. `signaled` covers the whole round trip rather
      # than one attempt: a retry is still the SAME logical request, and a
      # stagger scheduler awaiting `request.digest` wants exactly one signal.
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
