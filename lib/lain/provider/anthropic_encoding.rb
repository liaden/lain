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

      # Every key a block may carry inside lain that is not a wire field.
      NEUTRAL_KEYS = [CACHE_MARKER, Workspace::WORKSPACE_MARKER, Compaction::Recap::MARKER].freeze
      private_constant :NEUTRAL_KEYS

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

      # A request the model's API would 400 on, refused before the wire. Ids resolve to a
      # row through Rows.
      class Rejected < Lain::Error; end

      # Sampling parameters the model refuses at any value under anthropic-version
      # 2023-06-01, which is what lain sends. From 2026-10-21 every model refuses them, so
      # a version bump makes these tables universal instead of per model.
      SAMPLING_REFUSED = %w[claude-fable-5 claude-fable-5-1 claude-mythos-5-1 claude-opus-5-5 claude-opus-5
                            claude-opus-4-8 claude-opus-4-7 claude-sonnet-5].freeze

      # Refused only off the default: a temperature other than 1, or any top_p or top_k.
      SAMPLING_NON_DEFAULT = %w[claude-sonnet-5-5 claude-haiku-5-5].freeze

      # Never an Anthropic parameter, whatever the model.
      UNKNOWN_KEYS = %w[seed].freeze

      SAMPLING_KEYS = %w[temperature top_p top_k].freeze

      # Models whose API 400s on a forced tool_choice (any or tool).
      NO_FORCED_TOOL_CHOICE = %w[claude-opus-5-5 claude-sonnet-5-5 claude-fable-5-1 claude-mythos-5-1].freeze

      # Models that always think, so `thinking: {type: disabled}` is a 400.
      ALWAYS_THINKING = %w[claude-opus-5-5 claude-sonnet-5-5 claude-fable-5 claude-fable-5-1 claude-mythos-5-1].freeze

      # Models that refuse disabled thinking only at these efforts.
      THINKING_REQUIRED_AT = %w[xhigh max].freeze
      THINKING_REQUIRED_AT_EFFORT = %w[claude-opus-5 claude-haiku-5-5].freeze

      EFFORTS = %w[low medium high xhigh max].freeze

      # The efforts a model takes. Every model is listed because an id
      # no key names has no row and passes unchecked.
      EFFORT_LEVELS = {
        "claude-3-haiku" => [], "claude-3-sonnet" => [], "claude-3-opus" => [], "claude-3-5-sonnet" => [],
        "claude-3-5-haiku" => [], "claude-3-7-sonnet" => [], "claude-haiku-4-5" => [], "claude-sonnet-4-5" => [],
        "claude-opus-4-1" => [], "claude-opus-4-0" => [], "claude-sonnet-4-0" => [],
        "claude-opus-4" => [], "claude-sonnet-4" => [],
        "claude-opus-4-5" => %w[low medium high],
        "claude-opus-4-6" => %w[low medium high max], "claude-sonnet-4-6" => %w[low medium high max],
        **%w[claude-opus-4-7 claude-opus-4-8 claude-opus-5 claude-opus-5-5 claude-sonnet-5 claude-sonnet-5-5
             claude-haiku-5-5 claude-fable-5 claude-fable-5-1 claude-mythos-5-1].to_h { [_1, EFFORTS] }
      }.freeze

      # Resolves a model id to the longest row key it names. Plain containment would let
      # "claude-opus-4" claim "claude-opus-4-10", so a key must end the id or be followed
      # by a date, a vertex "@", a bedrock "-v" or ":" -- and an id no key names has no row.
      class Rows
        BOUNDARY = "(?=\\z|-\\d{8}|-latest|@|-v|:)"
        private_constant :BOUNDARY

        def initialize(keys)
          @patterns = keys.to_h { |key| [key, /#{Regexp.escape(key)}#{BOUNDARY}/] }.freeze
          freeze
        end

        # @return [String, nil]
        def key_for(model) = @patterns.select { |_, pattern| pattern.match?(model) }.keys.max_by(&:length)
      end
      private_constant :Rows

      SAMPLING_TABLE = Rows.new(SAMPLING_REFUSED + SAMPLING_NON_DEFAULT)
      THINKING_TABLE = Rows.new(ALWAYS_THINKING + THINKING_REQUIRED_AT_EFFORT)
      EFFORT_TABLE = Rows.new(EFFORT_LEVELS.keys)
      FORCING_TABLE = Rows.new(NO_FORCED_TOOL_CHOICE)
      private_constant :SAMPLING_TABLE, :THINKING_TABLE, :EFFORT_TABLE, :FORCING_TABLE

      FORCING_CHOICES = %w[any tool].freeze
      private_constant :FORCING_CHOICES

      # The keys of `extra` this model would 400 on, for a caller to drop before it asks.
      #
      # @param model [String]
      # @param extra [Hash] sampler keys, String or Symbol
      # @return [Array<String>]
      def self.refused_sampling(model, extra)
        given = extra.select { |key, _| (SAMPLING_KEYS + UNKNOWN_KEYS).include?(key.to_s) }.transform_keys(&:to_s)
        row = SAMPLING_TABLE.key_for(model)
        given.keys.select do |key|
          UNKNOWN_KEYS.include?(key) || sampling_refused?(row, key, given[key])
        end
      end

      def self.sampling_refused?(row, key, value)
        return true if SAMPLING_REFUSED.include?(row)

        SAMPLING_NON_DEFAULT.include?(row) && !(key == "temperature" && value == 1)
      end
      private_class_method :sampling_refused?

      # @return [Boolean] whether the model takes this effort level
      def self.effort_accepted?(model, effort)
        row = EFFORT_TABLE.key_for(model)
        row.nil? || EFFORT_LEVELS.fetch(row).include?(effort)
      end

      # The exact kwargs Hash the SDK would receive. Pure and deterministic: no
      # network, no clock, no ordering that depends on how the Request's Hashes
      # were built. `stream` is intentionally NOT a key here -- the SDK encodes
      # streaming by *which method* you call (`create` vs `stream`), and the wire
      # payload carries it as a top-level field the caller adds later.
      def encode(request)
        check_cache_budget!(request)
        check_rejected!(request)
        check_tool_choice_conflict!(request.extra)
        # #extra is the provider-specific escape hatch (temperature, tool_choice,
        # ...); symbol keys so it lands on the SDK param model's named fields.
        # STRUCTURED_OUTPUT_KEY is neutral, not a wire field -- it is consulted
        # for #structured_fields below, then excluded so it never rides along
        # into the SDK params as an unrecognized key.
        base_params(request).compact
                            .merge(structured_fields(request.extra))
                            .merge(request.extra.except(STRUCTURED_OUTPUT_KEY).transform_keys(&:to_sym))
                            .merge(effort_fields(request))
      end

      private

      def check_rejected!(request)
        check_sampling!(request)
        check_forced_tool_choice!(request)
        check_thinking!(request)
        check_effort!(request)
      end

      def check_sampling!(request)
        key = AnthropicEncoding.refused_sampling(request.model, request.extra).first
        return unless key
        raise Rejected, "seed is not an Anthropic parameter" if UNKNOWN_KEYS.include?(key)

        raise Rejected, "#{request.model} answers #{key} with a 400 under this API version"
      end

      def check_forced_tool_choice!(request)
        return unless forces_tool?(request.extra)

        model = FORCING_TABLE.key_for(request.model)
        return unless model

        raise Rejected, "#{model} answers a forced tool_choice with a 400; use auto with a strict tool " \
                        "or a structured answer"
      end

      def forces_tool?(extra)
        choice = extra[TOOL_CHOICE_KEY]
        structured = extra[STRUCTURED_OUTPUT_KEY]
        return true if structured && structured["tool"]

        choice.is_a?(Hash) && FORCING_CHOICES.include?(choice["type"] || choice[:type])
      end

      def check_thinking!(request)
        reasoning = request.reasoning
        return unless reasoning.is_a?(Hash) && (reasoning["type"] || reasoning[:type]).to_s == "disabled"

        row = THINKING_TABLE.key_for(request.model)
        return unless thinking_forced?(row, request.effort)

        hint = row == "claude-sonnet-5-5" ? ' (use {"type":"between_tools"} to limit it)' : ""
        raise Rejected, "#{row} cannot disable thinking#{" at effort #{request.effort}" if request.effort}#{hint}"
      end

      def thinking_forced?(row, effort)
        ALWAYS_THINKING.include?(row) ||
          (THINKING_REQUIRED_AT_EFFORT.include?(row) && THINKING_REQUIRED_AT.include?(effort))
      end

      def check_effort!(request)
        return if request.effort.nil? || AnthropicEncoding.effort_accepted?(request.model, request.effort)

        raise Rejected, "#{request.model} does not take effort #{request.effort}; it answers with a 400"
      end

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

      # Merged over any raw `output_config` in extra, so the two never replace each other.
      def effort_fields(request)
        return {} unless request.effort

        { output_config: raw_output_config(request.extra).transform_keys(&:to_sym).merge(effort: request.effort) }
      end

      def raw_output_config(extra)
        raw = extra.fetch("output_config", {})
        return raw if raw.is_a?(Hash)

        raise Error, "extra carries an output_config of #{raw.class}, which an effort cannot join; it must be a Hash"
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
      # simply removed. {Workspace::WORKSPACE_MARKER} and {Compaction::Recap::MARKER}
      # are the same kind of neutral key -- structural provenance, never a wire
      # field -- so they are always stripped too, independent of whether the
      # block also carries a cache marker (CacheBreakpoints can mark the last
      # block of either). Non-Hash blocks (a bare String) pass through untouched.
      def translate_block(block)
        return block unless block.is_a?(Hash)
        return block unless NEUTRAL_KEYS.any? { |key| block.key?(key) }

        cached = block[CACHE_MARKER]
        stripped = block.except(*NEUTRAL_KEYS)
        cached ? stripped.merge("cache_control" => EPHEMERAL) : stripped
      end
    end
  end
end
