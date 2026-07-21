# frozen_string_literal: true

require "json"

require_relative "ollama/encoding"
require_relative "ollama/stream_assembler"
require_relative "ollama/transport"

module Lain
  class Provider
    # Ollama's native `/api/chat`, non-streaming. A free, local, temperature-0
    # bench arm -- a determinism oracle for tests and an exploration target on
    # the "Provider / model" axis.
    #
    # It is a neutral {Lain::Provider} (NOT the OpenAI-compat shim RubyLLM's
    # Ollama integration is): it encodes with {Ollama::Encoding} and drives the
    # vendored Faraday stack through {Transport}. The native path is chosen over
    # `/v1/...` because that OpenAI-compat surface is SSE + `finish_reason` +
    # `tool_call_id`, while the native one is NDJSON + `done_reason` +
    # tool_name-only correlation -- and mapping the native semantics honestly is
    # cheaper than adapting a shim tuned for OpenAI's models.
    #
    # == What the wire lacks, and how it is bridged
    #
    # Native `/api/chat` emits no tool-call id -- results correlate by
    # `tool_name` only. So a stable id is synthesized on decode (below), lives
    # purely on Lain's side, and {Ollama::Encoding} maps it back to a
    # `tool_name` when a tool_result returns to the wire. And `done_reason`'s
    # real enum is only "stop"/"length"/"" -- there is no "tool_calls" value --
    # so `:tool_use` is derived from the PRESENCE of tool_calls, not from
    # done_reason (both confirmed in references/ollama/).
    class Ollama < Provider
      include Encoding

      DEFAULT_MODEL = "qwen3:4b"

      # The NDJSON streaming path (below) makes :streaming honest. :thinking is
      # honest too (R5): `think` rides Request#extra onto its own top-level
      # wire field (Encoding#encode), and #decode_content already turns
      # `message.thinking` into a thinking block on both the sync and streamed
      # paths. :prompt_caching and :strict_tools stay off deliberately --
      # declaring one the native path cannot demonstrate would be a lying
      # capability in the one subsystem built to catch them, so the capability
      # policy's `:degrade` journals those gaps, which is the bench working as
      # designed.
      # `structured_output` here is grammar-CONSTRAINED decoding (the native `format`
      # field) -- a stronger guarantee than Anthropic's tool-forcing under the same
      # capability name. See Provider::Anthropic::CAPABILITIES.
      CAPABILITIES = %i[streaming thinking structured_output].freeze

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

      # @param transport [#sync_post] injected in specs; a real {Transport} over
      #   the vendored connection otherwise.
      # @param api_base [String, nil] overrides `ollama_api_base` (default
      #   http://localhost:11434); no api key -- Ollama is local.
      def initialize(transport: nil, config: nil, sink: Sink::Null.new, api_base: nil)
        super()
        @config = config || build_config(api_base:)
        @transport = transport || Transport.new(@config, sink:)
      end

      def capabilities = CAPABILITIES

      # No :prompt_caching capability, so no cache economics to report --
      # {CacheProfile::NO_CACHING} is the honest, flat-cost Null Object
      # answer, promoted off what used to be a per-provider
      # `NO_CACHING_PROFILE` Hash constant here (CAC-2/F1) into the neutral
      # {Lain::CacheProfile} home shared with every other provider.
      def cache_profile = CacheProfile::NO_CACHING

      # One round trip into a neutral Response. Streaming and non-streaming
      # converge on the same body Hash -- {StreamAssembler} reassembles the NDJSON
      # lines into the shape the non-streaming endpoint returns -- so both decode
      # through one #build_response (path parity).
      def complete(request)
        build_response(request.stream ? stream_body(request) : sync_body(request))
      rescue Provider::HTTP::Error => e
        raise wrap_error(e)
      end

      private

      def sync_body(request)
        @transport.sync_post(encode(request)).body || {}
      end

      # A corrupt NDJSON line is a wire-protocol violation, so it raises -- never
      # a silent skip (one torn line means the frame boundaries can no longer be
      # trusted). It is wrapped in APIError rather than escaping as a bare
      # JSON::ParserError for the same reason transport errors are: callers
      # rescue one provider-error family, and the original stays on `#cause`.
      def stream_body(request)
        assembler = StreamAssembler.new
        @transport.stream(encode(request)) { |chunk| assembler.feed(chunk) }
        assembler.result
      rescue JSON::ParserError => e
        raise APIError, "corrupt NDJSON line in stream: #{e.message}"
      end

      def build_config(api_base:)
        config = Provider::HTTP::Configuration.new
        config.ollama_api_base = api_base unless api_base.nil?
        config
      end

      def build_response(body)
        message = body["message"] || {}
        Response.new(id: nil, model: body["model"], content: decode_content(message),
                     stop_reason: decode_stop_reason(body, message), usage: build_usage(body), raw: body)
      end

      # Order mirrors what a mixed assistant turn carries: reasoning first, then
      # visible text, then the calls -- thinking and text ride their own message
      # fields, tool_calls its own array.
      def decode_content(message)
        blocks = []
        blocks << { "type" => "thinking", "thinking" => message["thinking"] } unless blank?(message["thinking"])
        blocks << { "type" => "text", "text" => message["content"] } unless blank?(message["content"])
        Array(message["tool_calls"]).each_with_index { |call, index| blocks << tool_use_block(call, index) }
        blocks
      end

      # Ollama has no tool-call id, so one is synthesized from the call's
      # position -- deterministic and unique within the response, which is all
      # ToolRunner's id-keyed result matching needs (a later turn reusing the
      # same synthetic id is harmless: Encoding resolves tool_name in message
      # order, so each result names the tool its own turn called). A wire-
      # provided id is honored if one is ever present (forward-compat, and how
      # the parity harness replays canned ids); synthesis is the fallback.
      def tool_use_block(call, index)
        function = call["function"] || {}
        { "type" => "tool_use", "id" => call["id"] || "ollama-tool-#{index}",
          "name" => function["name"], "input" => parse_arguments(function["arguments"]) }
      end

      # Belief (b): native `/api/chat` returns arguments as a parsed object. The
      # String branch is belt-and-suspenders on Response#tool_uses' Hash
      # contract -- a String must never reach the Timeline.
      def parse_arguments(arguments)
        return arguments unless arguments.is_a?(String)

        JSON.parse(arguments)
      end

      # Presence of tool_calls forces :tool_use -- done_reason stays "stop" on a
      # tool turn. Otherwise map the two enum values Ollama can express and let
      # StopReason.normalize close the open enum ("" -> :unknown, and any
      # load/unload edge string likewise), so gate 6 stays total.
      def decode_stop_reason(body, message)
        return StopReason::TOOL_USE unless Array(message["tool_calls"]).empty?

        case body["done_reason"]
        when "stop" then StopReason::END_TURN
        when "length" then StopReason::MAX_TOKENS
        else StopReason.normalize(body["done_reason"])
        end
      end

      def build_usage(body)
        Usage.new(input_tokens: body["prompt_eval_count"], output_tokens: body["eval_count"])
      end

      def blank?(value)
        value.nil? || value == ""
      end

      def wrap_error(error)
        status = error.response.respond_to?(:status) ? error.response.status : nil
        status ? APIStatusError.new(error.message, status:) : APIError.new(error.message)
      end
    end
  end
end
