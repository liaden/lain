# frozen_string_literal: true

module Lain
  class Provider
    # The neutral-Request -> Anthropic-kwargs encoding, shared by both Anthropic
    # backends so it cannot drift between them.
    #
    # The SDK oracle and the forked HTTP transport must send byte-identical
    # payloads -- the point of the dry differential `raw.encode(req) ==
    # sdk.encode(req)`, which VCR structurally cannot prove because cassettes
    # match on method+URI and not body. One implementation included in both
    # makes the equality true by construction, which is why the encoder lives
    # here and not inside the SDK class.
    #
    # The output uses the SDK's `system_:` keyword (trailing underscore),
    # because the dry-diff compares against the SDK's kwargs. {AnthropicWire}
    # rewrites it to the wire `system` key on the way out.
    #
    # The encoder consults the includer's `#supports?` for capability-gated
    # wire fields (today: tools' `strict`), so an includer must be a Provider
    # or supply that duck.
    module AnthropicEncoding
      # Anthropic accepts at most this many cache_control breakpoints per
      # request; a fifth is a hard 400 at the wire. The default pipeline budgets
      # itself under the cap, but a non-default one could exceed it -- and this
      # Anthropic-specific limit does not belong in the neutral Request, so the
      # encoder that emits Anthropic bytes is where it is enforced.
      CACHE_LIMIT = 4

      # `cache_control` in Anthropic's only currently offered flavor. Named once
      # so the emitted marker is a single shared, frozen object.
      EPHEMERAL = { "type" => "ephemeral" }.freeze

      # The neutral key a Context uses to mark a block for caching. It is not a
      # wire field, so it must be stripped from every emitted payload.
      CACHE_MARKER = "cache"

      # The neutral key a Request uses to carry a forced typed-answer format on
      # #extra. The same string as Ollama::Encoding::STRUCTURED_OUTPUT_KEY,
      # defined separately because these are two leaf files carrying no internal
      # requires of each other. Anthropic has no native "format" concept, so it
      # reads only the "tool" half and forces tool_choice at that name. Never a
      # wire field, so #encode must strip it or an unknown param leaks to the
      # SDK.
      STRUCTURED_OUTPUT_KEY = "structured_output"

      # The raw escape-hatch key a caller may put on #extra to force tool_choice
      # directly. Named here only so #check_tool_choice_conflict! can see it
      # collide with STRUCTURED_OUTPUT_KEY; otherwise it is simply forwarded.
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

        # `extra` can carry a raw `tool_choice` AND a structured_output marker,
        # which also forces tool_choice. #encode merges structured_fields BEFORE
        # the generic extra forward, so an unchecked raw `tool_choice` would win
        # silently: no error, just a forced structured answer quietly not being
        # forced.
        raise Error,
              "extra carries both a raw #{TOOL_CHOICE_KEY.inspect} and a #{STRUCTURED_OUTPUT_KEY.inspect} " \
              "marker, which also forces tool_choice -- remove one"
      end

      # A Request with no structured-answer format contributes nothing, which is
      # what keeps #encode byte-identical to before the feature existed.
      #
      # A marker carrying no "tool" counts as absent: half a marker is what a
      # caller with only the other half builds, and an {Oracle::Model} is
      # exactly that caller -- an answer schema and no tools at all. `name: nil`
      # is a payload the API rejects, so it must never be emitted.
      def structured_fields(extra)
        format = extra[STRUCTURED_OUTPUT_KEY]
        tool = format && format["tool"]
        return {} unless tool

        { tool_choice: { type: "tool", name: tool } }
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

        # More cache breakpoints than Anthropic will accept, caught at encode time
        # with a message naming the count instead of a cryptic wire 400.
        raise Error,
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
      # feature masks stay the single authority. A strict-tools-refusing validator
      # rejects the field as an unknown input ("tools.0.custom.strict: Extra
      # inputs are not permitted", a live 400), and masking it here keeps one
      # shared encoder instead of forking a second one the dry differential
      # would then have to prove per platform.
      def mask_strict(tool)
        return tool if supports?(:strict_tools) || !tool.is_a?(Hash)

        tool.except("strict")
      end

      # Pure translation: a block's neutral marker becomes cache_control
      # wherever the Context layer placed it. This module adds no placement of
      # its own.
      #
      # An image block needs no translation at all -- the neutral block wears
      # Anthropic's own shape, which is why that shape was chosen -- but an
      # ADDRESS is refused here rather than passed through. Anthropic would
      # answer a `source.type` it does not know with a 400 naming neither the
      # picture nor what failed to resolve it; {Attachment::Reference} names
      # both. The check is recursive because {#translate_block} is not: a
      # tool_result's content nests, and that is where a tool's picture arrives.
      def encode_messages(messages)
        Attachment::Reference.refuse_unresolved!(messages)
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
