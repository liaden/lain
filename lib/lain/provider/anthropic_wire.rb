# frozen_string_literal: true

require "json"
require "time"

module Lain
  class Provider
    # {AnthropicEncoding}'s counterpart on the wire side, shared by the two
    # backends that speak the Anthropic Messages API over the vendored Faraday
    # transport: {Provider::Anthropic} (api.anthropic.com) and
    # {Provider::Bedrock} (Mantle, which speaks the plain Messages API).
    #
    # The split between the two modules is the split between the neutral kwargs
    # and the actual bytes. `AnthropicEncoding#encode` produces the SDK's
    # `system_:` kwargs, so the dry differential can byte-compare it against the
    # official-SDK oracle; that is also why the wire rewrite does NOT live there
    # -- the oracles include `AnthropicEncoding` and must keep seeing kwargs.
    # This module owns everything past that line: the wire BODY (`system_` ->
    # `system`, the top-level `stream` flag the SDK expressed by method choice),
    # the wire RESPONSE (assembled blocks -> a neutral {Lain::Response}), and
    # the retry backoff both endpoints' rate-limit headers demand.
    #
    # It deliberately does NOT own `#complete` or `#dispatch`. Those diverge for
    # real reasons -- Anthropic threads a WAL frame and CE-5's
    # `on_stream_started` through its round trip, Bedrock neither -- and a
    # shared `#complete` would have to reconcile which error arms each backend
    # rescues. Those arms are the loud part; they stay written out, per backend,
    # where a missing one is visible.
    module AnthropicWire
      # Which reset header feeds faraday-retry's backoff. Both endpoints return
      # several `anthropic-ratelimit-*-reset` headers as RFC3339 timestamps;
      # token limits bind first on large agentic prompts, so the tokens reset is
      # the default until a live 429 confirms otherwise.
      #
      # This was written out twice, and both copies named the SAME header --
      # verified before collapsing them, because reconciling a behavioural
      # difference would have been a decision rather than a refactor. One
      # constant now, so the two cannot drift while the open question is open.
      # Confirming it against a live 429 remains a named follow-up: Backend
      # hands this transport live default `--journal` chat traffic and
      # `--provider bedrock` is the work account's default, so a wrong header
      # throttles (or fails to throttle) ordinary conversations, not just
      # `bench record` runs.
      RATE_LIMIT_RESET_HEADER = "anthropic-ratelimit-tokens-reset"

      NUMERIC_SECONDS = /\A\d+(\.\d+)?\z/

      # faraday-retry's default header parser understands only seconds or an
      # RFC2822 date. The reset headers are RFC3339 and `retry-after` is plain
      # seconds, so one parser must handle both: a bare number is seconds,
      # anything else is a timestamp turned into seconds-from-now (never
      # negative). nil for anything unparseable, which is faraday-retry's own
      # signal to fall back to its schedule rather than raise inside the retry.
      RESET_HEADER_PARSER = lambda do |value|
        string = value.to_s
        return if string.empty?
        return string.to_f if string.match?(NUMERIC_SECONDS)

        [Time.iso8601(string) - Time.now, 0.0].max
      rescue ArgumentError
        nil
      end

      private

      # Both backends' `#build_config` differ in credentials and envelope; the
      # backoff policy is the part they share.
      def apply_rate_limit_backoff(config)
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

      # The FULL, ordered block list with every extended-thinking signature
      # intact (gate 1) -- never the SDK's or RubyLLM's flattened text.
      def build_response(assembled)
        Response.new(id: assembled.id, model: assembled.model,
                     content: normalize_tool_inputs(assembled.content),
                     stop_reason: assembled.stop_reason,
                     usage: Usage.from_anthropic_wire(assembled.usage), raw: assembled)
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
    end
  end
end
