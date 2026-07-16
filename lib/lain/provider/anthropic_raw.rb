# frozen_string_literal: true

require "faraday"
require "json"
require "time"

require_relative "anthropic_raw/retry_tap"
require_relative "anthropic_raw/stream_assembler"
require_relative "anthropic_raw/transport"

module Lain
  class Provider
    # The forked provider: Lain's own HTTP transport instead of the official SDK.
    #
    # It shares {AnthropicEncoding} with {Provider::Anthropic}, so `#encode`
    # produces byte-identical kwargs (the dry differential proves it), and drives
    # the vendored Faraday/SSE stack through {Transport}. What it does NOT share is
    # the SDK's -- or RubyLLM's -- response model: both flatten the content array,
    # and this returns a {Lain::Response} carrying the FULL, ordered block list
    # with every extended-thinking signature intact (gate 1).
    #
    # == encode vs. the wire
    #
    # `#encode` returns the SDK's `system_:` kwargs so the dry-diff can compare it
    # against the oracle. {#complete} rewrites that one key to the wire `system`
    # and adds the top-level `stream` flag -- the only two places the neutral
    # kwargs and the actual JSON body differ.
    class AnthropicRaw < Provider
      include AnthropicEncoding

      DEFAULT_MODEL = "claude-opus-4-8"
      CAPABILITIES = %i[streaming prompt_caching strict_tools thinking parallel_tool_use].freeze

      # Which Anthropic rate-limit reset header feeds faraday-retry's backoff.
      # Anthropic returns several `anthropic-ratelimit-*-reset` headers as RFC3339
      # timestamps; the exact one to honor should be confirmed against a live 429
      # (see the plan's open questions) -- token limits bind first on large
      # agentic prompts, so the tokens reset is the default until then.
      #
      # T17w widens the stakes on this open question: this class used to be
      # bench-only (a money-gated, explicitly opt-in recording path), so an
      # unconfirmed backoff header was a contained risk. Backend now hands it
      # live default --journal chat traffic, so a wrong header here throttles
      # (or fails to throttle) ordinary conversations, not just `bench record`
      # runs. Still not confirmed against a live 429 -- that confirmation is a
      # named follow-up ticket, not something to chase in this fix round.
      RATE_LIMIT_RESET_HEADER = "anthropic-ratelimit-tokens-reset"

      NUMERIC_SECONDS = /\A\d+(\.\d+)?\z/

      # faraday-retry's default header parser understands only seconds or an
      # RFC2822 date. Anthropic's reset headers are RFC3339, and its `retry-after`
      # is plain seconds, so one parser must handle both: a bare number is seconds,
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
      #
      # UNRELATED to {Anthropic::APIError}: same name, same shape, no shared
      # ancestor besides {Lain::Error} -- verified nothing above the Provider
      # rescues either by name today (Backend can now hand chat either backend
      # depending on whether journaling is on, see T17w). A future caller that
      # wants to rescue "an Anthropic API error" regardless of which backend
      # produced it must handle both explicitly, or a shared marker module must
      # be introduced first -- do not assume `rescue AnthropicRaw::APIError`
      # catches an {Anthropic} (SDK) failure, or vice versa.
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
      # @param spool [#open_frame] where the raw response bytes are teed; the Null
      #   spool by default, so no WAL file exists unless a session opts in
      def initialize(transport: nil, config: nil, channel: Channel::Null.instance, sink: Sink::Null.new,
                     spool: Spool::Null.new, api_key: nil, api_base: nil)
        super()
        @retries = RetryTap.new(spool:, channel:)
        @config = config || build_config(api_key:, api_base:)
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
      rescue Faraday::Error => e
        # Exhausted retries re-raise the last connection-level failure
        # (ConnectionFailed, a timeout) as a bare Faraday class; nothing above
        # the Provider rescues a transport class, so it wraps like the rest.
        raise APIError, e.message
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

      # The Provider owns frame opening (it computes the digest) AND attempt
      # boundaries: the frame stays live inside {RetryTap} so a retry rotates it
      # rather than concatenating two attempts into one frame.
      def dispatch(request)
        payload = wire_payload(request)
        frame = @retries.open_frame(request_digest: request.digest)
        request.stream ? stream_dispatch(payload, frame) : sync_dispatch(payload, frame)
      ensure
        @retries.release
      end

      def stream_dispatch(payload, frame)
        assembler = StreamAssembler.new
        @transport.stream(payload, frame:) { |data| assembler.add(data) }
        assembler.result
      end

      def sync_dispatch(payload, frame)
        body = @transport.sync_post(payload, frame:).body || {}
        StreamAssembler::Assembled.new(id: body["id"], model: body["model"], stop_reason: body["stop_reason"],
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
    end
  end
end
