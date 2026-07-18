# frozen_string_literal: true

module Lain
  class Provider
    # The neutral-Request -> Anthropic-kwargs encoding, shared by both Anthropic
    # backends so it cannot drift between them.
    #
    # {Provider::Anthropic} (the SDK oracle) and {Provider::AnthropicRaw} (the
    # forked HTTP transport) must send byte-identical payloads -- that is the
    # whole point of the dry differential `raw.encode(req) == sdk.encode(req)`,
    # which VCR structurally cannot prove because cassettes match on method+URI,
    # not body. One implementation, included in both, makes the equality true by
    # construction and keeps it true when the SDK oracle is eventually retired:
    # the encoder lives here, not inside the SDK class.
    #
    # The output uses the SDK's `system_:` keyword (trailing underscore), because
    # the dry-diff compares against the SDK's kwargs. {AnthropicRaw} rewrites that
    # to the wire `system` key on the way out; see its `#complete`.
    #
    # The encoder consults the includer's `#supports?` for capability-gated
    # wire fields (today: tools' `strict`), so an includer must be a Provider
    # or supply that duck.
    module AnthropicEncoding
      # Anthropic accepts at most this many cache_control breakpoints per
      # request; a fifth is a hard 400 at the wire. The default pipeline
      # (Context::CacheBreakpoints) budgets itself under this cap, but a
      # non-default pipeline could exceed it -- and this Anthropic-specific
      # limit does not belong in the neutral Request. So the encoder, which is
      # the anti-corruption layer that actually emits Anthropic bytes, is where
      # the ceiling is enforced.
      CACHE_LIMIT = 4

      # More cache breakpoints than Anthropic will accept, caught at encode
      # time with a named error instead of a cryptic wire 400. Defined here,
      # beside the encoder, because the limit is the encoder's concern.
      class TooManyCacheMarkers < Error; end

      # `extra` can carry a raw `tool_choice` (the pre-existing escape-hatch
      # forwarding path) AND a structured_output marker, which also wants to
      # force tool_choice. #encode merges structured_fields BEFORE the
      # generic extra forward, so an unchecked raw `tool_choice` would win
      # silently -- the caller would see no error, just their forced
      # structured answer quietly not being forced. Same shape as
      # TooManyCacheMarkers: refuse at encode time with a named error rather
      # than let one silently clobber the other.
      class ConflictingToolChoice < Error; end

      # `cache_control` in Anthropic's only currently offered flavor. Named once
      # so the emitted marker is a single shared, frozen object.
      EPHEMERAL = { "type" => "ephemeral" }.freeze

      # The neutral key a Context uses to mark a block for caching. It is not a
      # wire field, so it must be stripped from every emitted payload.
      CACHE_MARKER = "cache"

      # T1: the neutral key a Request uses to carry a forced typed-answer
      # format on #extra (see Ollama::Encoding::STRUCTURED_OUTPUT_KEY, the
      # same string, defined separately -- these are two leaf files that
      # carry no internal requires of each other). The value is
      # `{"schema" => <json schema>, "tool" => <name>}`; Anthropic has no
      # native "format" concept, so it reads only "tool" and forces
      # tool_choice at that name instead -- the schema half is Ollama's.
      # Never a wire field itself, so #encode must strip it the same way it
      # strips CACHE_MARKER, or an unknown param would leak to the SDK.
      STRUCTURED_OUTPUT_KEY = "structured_output"

      # The pre-existing raw escape-hatch key a caller may already put on
      # #extra to force tool_choice directly (see "forwards provider-specific
      # params from #extra as symbol keys" in the spec). Named here only so
      # #check_tool_choice_conflict! can detect it colliding with
      # STRUCTURED_OUTPUT_KEY -- this module has no opinion on raw tool_choice
      # otherwise, it just forwards it.
      TOOL_CHOICE_KEY = "tool_choice"

      # The exact kwargs Hash the SDK would receive. Pure and deterministic: no
      # network, no clock, no ordering that depends on how the Request's Hashes
      # were built. `stream` is intentionally NOT a key here -- the SDK encodes
      # streaming by *which method* you call (`create` vs `stream`), and the wire
      # payload carries it as a top-level field the caller adds later.
      def encode(request)
        check_cache_budget!(request)
        check_tool_choice_conflict!(request.extra)
        # #extra is the provider-specific escape hatch (temperature, tool_choice,
        # ...); symbol keys so it lands on the SDK param model's named fields.
        # STRUCTURED_OUTPUT_KEY is neutral, not a wire field -- it is consulted
        # for #structured_fields below, then excluded so it never rides along
        # into the SDK params as an unrecognized key.
        base_params(request).compact
                            .merge(structured_fields(request.extra))
                            .merge(request.extra.except(STRUCTURED_OUTPUT_KEY).transform_keys(&:to_sym))
      end

      private

      # Both keys forcing tool_choice at once is not a merge order the
      # caller chose deliberately -- it is two independent features writing
      # to the same wire field. Refuse loudly rather than let #encode's merge
      # order silently decide a winner.
      def check_tool_choice_conflict!(extra)
        return unless extra.key?(STRUCTURED_OUTPUT_KEY) && extra.key?(TOOL_CHOICE_KEY)

        raise ConflictingToolChoice,
              "extra carries both a raw #{TOOL_CHOICE_KEY.inspect} and a #{STRUCTURED_OUTPUT_KEY.inspect} " \
              "marker, which also forces tool_choice -- remove one"
      end

      # A Request with no structured-answer format contributes nothing here,
      # which is what keeps #encode byte-identical to before this feature
      # existed. When present, Anthropic has no server-side schema-forcing
      # concept (unlike Ollama's `format`), so the schema half is ignored and
      # only the named tool is forced via tool_choice.
      def structured_fields(extra)
        format = extra[STRUCTURED_OUTPUT_KEY]
        return {} unless format

        { tool_choice: { type: "tool", name: format["tool"] } }
      end

      def base_params(request)
        { model: request.model, max_tokens: request.max_tokens,
          messages: encode_messages(request.messages),
          system_: request.system && encode_system(request.system),
          tools: (encode_tools(request.tools) unless request.tools.empty?),
          thinking: request.reasoning }
      end

      # Anthropic caps cache_control breakpoints per request; count the neutral
      # markers across tools, system, and messages -- the three prefix regions
      # a breakpoint can land in -- and refuse before emitting a payload the
      # wire would 400.
      def check_cache_budget!(request)
        count = [request.tools, request.system, request.messages].sum { |part| count_markers(part) }
        return if count <= CACHE_LIMIT

        raise TooManyCacheMarkers,
              "request carries #{count} cache breakpoints; Anthropic accepts at most #{CACHE_LIMIT}"
      end

      def count_markers(value)
        case value
        when Hash then (value[CACHE_MARKER] == true ? 1 : 0) + value.values.sum { |v| count_markers(v) }
        when Array then value.sum { |v| count_markers(v) }
        else 0
        end
      end

      def encode_system(system)
        # A plain String system prompt carries no cache marker; only the block
        # form can be tagged.
        return system if system.is_a?(String)

        system.map { |block| translate_block(block) }
      end

      def encode_tools(tools)
        # Already Canonical-normalized by the Request, but re-normalizing is
        # idempotent and states the cache-stability contract at the seam that
        # actually emits bytes. Tool blocks may also carry the neutral marker.
        Canonical.normalize(tools).map { |tool| translate_block(mask_strict(tool)) }
      end

      # `strict` reaches the wire only when the including backend claims
      # :strict_tools -- asked via the includer's own #supports?, so the
      # feature masks stay the single authority. Bedrock's Mantle validator
      # rejects the field as an unknown input ("tools.0.custom.strict: Extra
      # inputs are not permitted", a live 400), and masking it here keeps one
      # shared encoder instead of forking a second one the dry differential
      # would then have to prove per platform.
      def mask_strict(tool)
        return tool if supports?(:strict_tools) || !tool.is_a?(Hash)

        tool.except("strict")
      end

      # Pure translation: every block's neutral marker, wherever
      # Context::CacheBreakpoints placed it, becomes cache_control. This
      # module adds no placement of its own -- the budget and the tail-
      # clustering are entirely the Context layer's policy (CE-1).
      def encode_messages(messages)
        messages.map do |message|
          { "role" => message["role"], "content" => encode_content(message["content"]) }
        end
      end

      def encode_content(content)
        return content unless content.is_a?(Array)

        content.map { |block| translate_block(block) }
      end

      # Translate Lain's neutral cache marker into Anthropic's wire field and
      # strip the marker itself, which is not a wire field. A falsy marker is
      # simply removed. {Workspace::WORKSPACE_MARKER} is the same kind of
      # neutral key -- structural provenance, never a wire field -- so it is
      # always stripped too, independent of whether the block also carries a
      # cache marker (CacheBreakpoints can mark the workspace tail's own last
      # block). Non-Hash blocks (a bare String) pass through untouched.
      def translate_block(block)
        return block unless block.is_a?(Hash)
        return block unless block.key?(CACHE_MARKER) || block.key?(Workspace::WORKSPACE_MARKER)

        cached = block[CACHE_MARKER]
        stripped = block.except(CACHE_MARKER, Workspace::WORKSPACE_MARKER)
        cached ? stripped.merge("cache_control" => EPHEMERAL) : stripped
      end
    end
  end
end
