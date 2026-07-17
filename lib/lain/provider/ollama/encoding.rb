# frozen_string_literal: true

module Lain
  class Provider
    class Ollama < Provider
      # The neutral-Request -> Ollama `/api/chat` payload encoding.
      #
      # Unlike {AnthropicEncoding}, this mixin has no SDK oracle to stay
      # byte-identical with, so #encode IS the wire payload -- there is no later
      # `system_:`-to-`system` rewrite. The payload is rebuilt field by field
      # rather than transformed in place, and that reconstruction is what keeps
      # every neutral marker off the wire: only known fields (a block's text,
      # a tool's name/description/schema) are ever copied out, so `"cache" =>
      # true` -- which Ollama has no prompt cache to honor -- and
      # `Workspace::WORKSPACE_MARKER` -- structural provenance, meaningful only
      # to Lain's own Recall -- simply never have a field to land in. There is
      # no `translate_block`-style strip here because there is nothing to
      # strip FROM: `text_of` only ever reads `block["text"]`. Surfacing a
      # missing capability (like prompt caching) is the policy's job
      # (`:degrade` journals it); the encoder's job is only to not leak a key.
      module Encoding
        # Ollama's native wire carries no tool-call id. When a tool_result is
        # sent back it correlates to its call by `tool_name` alone, so the name
        # must be recovered from the prior tool_use block that Lain minted an id
        # for. These are the keys involved on Lain's side.
        TOOL_USE = "tool_use"
        TOOL_RESULT = "tool_result"

        # The `Request#extra` keys the sampler honors, matching Ollama's
        # `options` object. Requests normalize extra to String keys; T18 is what
        # threads temperature/seed through here from the CLI.
        SAMPLER_KEYS = %w[temperature seed num_ctx].freeze

        # `think` requests the reasoning trace onto `message.thinking` (qwen3
        # emits it only when this is set -- references/ollama/api-chat.md). It
        # is deliberately NOT a SAMPLER_KEY: Ollama's schema keeps `think` a
        # top-level sibling of `stream`/`tools`, not a member of `options`.
        THINK_KEY = "think"

        # The exact `/api/chat` body. Pure and deterministic: no clock, no
        # ordering that depends on how the Request's Hashes were built. `stream`
        # carries `request.stream` (Request coerces it to a bool) -- Ollama's wire
        # default is `true`, so the flag is always sent explicitly; {Ollama#complete}
        # routes to the streaming or non-streaming transport on the same value.
        def encode(request)
          { model: request.model, messages: encode_messages(request), stream: request.stream }
            .merge(optional_fields(request))
        end

        private

        # The fields that only belong on the wire when the Request actually
        # carries them: an empty `tools`/`options` renders as an absent key
        # (matching what the non-cache-marker path already does), and `think`
        # is present only when Request#extra asked for it -- a Request with no
        # think extra must produce byte-identical bytes to before R5.
        def optional_fields(request)
          tools = encode_tools(request.tools)
          options = encode_options(request.extra)
          fields = {}
          fields[:tools] = tools unless tools.empty?
          fields[:options] = options unless options.empty?
          fields[:think] = request.extra[THINK_KEY] if request.extra.key?(THINK_KEY)
          fields
        end

        def encode_messages(request)
          system = encode_system(request.system)
          # A running id -> tool_name map: a tool_use turn precedes its
          # tool_result turn, so walking in order means the name is always known
          # by the time a result needs to name its call on the wire.
          conversation = request.messages.each_with_object(names: {}, out: system.dup) do |message, acc|
            acc[:out].concat(encode_message(message, acc[:names]))
          end
          conversation[:out]
        end

        def encode_system(system)
          return [] if system.nil?

          [{ role: "system", content: text_of(system) }]
        end

        def encode_message(message, names)
          blocks = message["content"]
          return [{ role: message["role"], content: blocks.to_s }] unless blocks.is_a?(Array)

          record_tool_names(blocks, names)
          results = blocks.select { |block| block_type(block) == TOOL_RESULT }
          return results.map { |block| tool_message(block, names) } unless results.empty?

          [assistant_or_user(message, blocks)]
        end

        # role:"tool" messages carry `tool_name`, never an id (the native wire's
        # only correlation handle). When two parallel calls hit the SAME tool the
        # wire cannot disambiguate their results -- a documented Ollama gap, not a
        # bug here; Lain's own tool_use_id keeps the loop unambiguous regardless.
        def tool_message(block, names)
          { role: "tool", tool_name: names[block["tool_use_id"]], content: text_of(block["content"]) }
        end

        def assistant_or_user(message, blocks)
          rebuilt = { role: message["role"], content: text_of(blocks) }
          calls = blocks.select { |block| block_type(block) == TOOL_USE }.map { |block| tool_call(block) }
          rebuilt[:tool_calls] = calls unless calls.empty?
          rebuilt
        end

        def tool_call(block)
          { function: { name: block["name"], arguments: block["input"] } }
        end

        def record_tool_names(blocks, names)
          blocks.each do |block|
            names[block["id"]] = block["name"] if block_type(block) == TOOL_USE
          end
        end

        # Anthropic-shaped `{name, description, input_schema}` (plus Lain's
        # `strict`, which native Ollama has no strict-tools mode for) becomes
        # `{type: "function", function: {name, description, parameters}}`.
        def encode_tools(tools)
          tools.map do |tool|
            { type: "function",
              function: { name: tool["name"], description: tool["description"], parameters: tool["input_schema"] } }
          end
        end

        def encode_options(extra)
          SAMPLER_KEYS.each_with_object({}) do |key, options|
            options[key.to_sym] = extra[key] if extra.key?(key)
          end
        end

        # A block list (or a bare String) flattened to the plain text Ollama's
        # `content` field wants; non-text blocks (thinking, tool_use) contribute
        # nothing here -- they ride their own fields.
        def text_of(value)
          return value if value.is_a?(String)
          return "" unless value.is_a?(Array)

          value.select { |block| block_type(block) == "text" }.map { |block| block["text"] }.join
        end

        def block_type(block)
          block["type"] if block.is_a?(Hash)
        end
      end
    end
  end
end
