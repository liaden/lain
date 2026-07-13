# frozen_string_literal: true

require_relative "../canonical"

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
    module AnthropicEncoding
      # `cache_control` in Anthropic's only currently offered flavor. Named once
      # so the emitted marker is a single shared, frozen object.
      EPHEMERAL = { "type" => "ephemeral" }.freeze

      # The neutral key a Context uses to mark a block for caching. It is not a
      # wire field, so it must be stripped from every emitted payload.
      CACHE_MARKER = "cache"

      # The exact kwargs Hash the SDK would receive. Pure and deterministic: no
      # network, no clock, no ordering that depends on how the Request's Hashes
      # were built. `stream` is intentionally NOT a key here -- the SDK encodes
      # streaming by *which method* you call (`create` vs `stream`), and the wire
      # payload carries it as a top-level field the caller adds later.
      def encode(request)
        params = { model: request.model, max_tokens: request.max_tokens,
                   messages: encode_messages(request.messages),
                   system_: request.system && encode_system(request.system),
                   tools: (encode_tools(request.tools) unless request.tools.empty?),
                   thinking: request.reasoning }
        # #extra is the provider-specific escape hatch (temperature, tool_choice,
        # ...); symbol keys so it lands on the SDK param model's named fields.
        params.compact.merge(request.extra.transform_keys(&:to_sym))
      end

      private

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
        Canonical.normalize(tools).map { |tool| translate_block(tool) }
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
      # simply removed. Non-Hash blocks (a bare String) pass through untouched.
      def translate_block(block)
        return block unless block.is_a?(Hash) && block.key?(CACHE_MARKER)

        cached = block[CACHE_MARKER]
        stripped = block.reject { |key, _| key == CACHE_MARKER }
        cached ? stripped.merge("cache_control" => EPHEMERAL) : stripped
      end
    end
  end
end
