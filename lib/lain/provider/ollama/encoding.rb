# frozen_string_literal: true

module Lain
  class Provider
    class Ollama < Provider
      # The neutral-Request -> Ollama `/api/chat` payload encoding.
      #
      # Unlike {AnthropicEncoding} this mixin has no SDK oracle to stay
      # byte-identical with, so #encode IS the wire payload. The payload is
      # REBUILT field by field rather than transformed in place, and that
      # reconstruction is what keeps every neutral marker off the wire: only
      # known fields are ever copied out, so `"cache"` and
      # `Workspace::WORKSPACE_MARKER` never have a field to land in. There is no
      # `translate_block`-style strip because there is nothing to strip FROM.
      module Encoding
        # Ollama's native wire carries no tool-call id: a tool_result correlates
        # to its call by `tool_name` alone, so the name must be recovered from
        # the prior tool_use block Lain minted an id for.
        TOOL_USE = "tool_use"
        TOOL_RESULT = "tool_result"

        # The `Request#extra` keys the sampler honors, matching Ollama's
        # `options` object.
        #
        # `num_batch` is the one with a measured cost behind it: ollama starts
        # llama-server with `-b 512`, overriding llama.cpp's own default of
        # 2048, and exposes no server-side setting to undo it -- the request is
        # the ONLY place it can be corrected. Measured on this box at 1.31x
        # prefill (docs/providers/ollama.md, "Serving performance").
        #
        # `temperature`, `seed` and `num_ctx` are strictly opt-in: defaulting
        # one on would be a wire change for a caller that asked for nothing,
        # so their resolution belongs at the CLI, where an operator's flag is.
        # `num_batch` is the one exception -- {Lain::CLI::Backend::DEFAULT_NUM_BATCH}
        # sends it on every ollama chat, flag or not, because the cost above is
        # paid whether or not anyone asked for it. The generation cap is a third
        # case again and deliberately NOT one of these -- see {#encode_options}
        # -- so `options` itself is no longer opt-in either. {KEEP_ALIVE_KEY} is
        # opt-in like the first group but lives outside `options` on the wire,
        # so membership here would send it where ollama defines no such field.
        SAMPLER_KEYS = %w[temperature seed num_batch num_ctx].freeze

        # `think` requests the reasoning trace onto `message.thinking` (qwen3
        # emits it only when this is set -- references/ollama/api-chat.md). It
        # is deliberately NOT a SAMPLER_KEY: Ollama's schema keeps `think` a
        # top-level sibling of `stream`/`tools`, not a member of `options`.
        THINK_KEY = "think"

        # How long ollama keeps the runner loaded. {THINK_KEY}'s shape, for
        # {THINK_KEY}'s reason. Forwarded with its JSON TYPE intact and
        # converted NEITHER way: `-1` and `"-1"` are a pin and an HTTP 400, and
        # {Lain::CLI::Backend} is the one place that decides which a flag
        # becomes (docs/providers/ollama.md, "Serving performance").
        KEEP_ALIVE_KEY = "keep_alive"

        # extra key => wire key, for the fields that ride #extra verbatim.
        FLAG_FIELDS = { THINK_KEY => :think, KEEP_ALIVE_KEY => :keep_alive }.freeze

        # The neutral key a Request uses to carry a forced typed-answer format
        # on #extra, so a Request without it stays byte-identical to before the
        # feature existed. Ollama's native `format` wants the marker's schema
        # half alone, having no tool-forcing concept; {AnthropicEncoding} reads
        # the "tool" half instead.
        STRUCTURED_OUTPUT_KEY = "structured_output"

        # The exact `/api/chat` body. Pure and deterministic: no clock, no
        # ordering that depends on how the Request's Hashes were built. Ollama's
        # wire default for `stream` is `true`, so the flag is always sent
        # explicitly.
        #
        # `truncate: false` on every request, because ollama's default is to
        # CUT a prompt that does not fit and evaluate the rest in silence: from
        # the front when the last message alone overflows (reporting exactly
        # `num_ctx/2 + 2` tokens), and by dropping whole older messages
        # otherwise, reporting a count that looks honest. Either way the system
        # prompt and the tool schemas can be what went, and nothing in the reply
        # says so. Asked not to, 0.32.12 refuses with HTTP 400 naming the exact
        # prompt count and the context it loaded, on the streaming and the
        # non-streaming path alike -- see {Ollama#window_exceeded}.
        def encode(request)
          { model: request.model, messages: encode_messages(request), stream: request.stream, truncate: false }
            .merge(optional_fields(request))
        end

        private

        # An empty `tools` renders as an ABSENT key, and each flag appears only
        # when Request#extra asked for it. `options` keeps no such company: it
        # carries the generation cap, which every Request has, so it is built
        # unconditionally rather than filtered for emptiness it cannot reach.
        def optional_fields(request)
          tools = encode_tools(request.tools)
          fields = tools.empty? ? {} : { tools: }
          flags = extra_flag_fields(request.extra)
          refuse_format_with_tools!(fields, flags)
          fields.merge(options: encode_options(request)).merge(flags)
        end

        def extra_flag_fields(extra)
          fields = FLAG_FIELDS.select { |key, _| extra.key?(key) }.to_h { |key, field| [field, extra[key]] }
          format = structured_format(extra)
          fields[:format] = format unless format.nil?
          fields
        end

        # 0.32.12 accepts both fields and answers without an error: probed on
        # qwen3:4b, `format` won silently -- no tool call, a confident JSON
        # answer fabricated in its place. Research saw the pair work with
        # thinking on, but one rule has not held across models, so the pair is
        # refused by name rather than trusted to a flag.
        def refuse_format_with_tools!(fields, flags)
          return unless fields.key?(:tools) && flags.key?(:format)

          raise Error, "a structured_output format and tools in one Ollama request: the " \
                       "constrained decoder silently suppresses the tool call -- send one or the other"
        end

        # Ollama's `format` wants the raw JSON schema, not a tool wrapper. A
        # nil marker and a marker missing "schema" both resolve to nil, which
        # #extra_flag_fields omits: the real API rejects a literal
        # `format: null`, so this must never emit one.
        def structured_format(extra)
          marker = extra[STRUCTURED_OUTPUT_KEY]
          marker && marker["schema"]
        end

        def encode_messages(request)
          system = encode_system(request.system)
          # A running id -> tool_name map. A tool_use turn precedes its
          # tool_result turn, so walking in order means the name is known by the
          # time a result must name its call on the wire.
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

        # role:"tool" messages carry `tool_name`, never an id. When two parallel
        # calls hit the SAME tool the wire cannot disambiguate their results -- a
        # documented Ollama gap, not a bug here; Lain's own tool_use_id keeps the
        # loop unambiguous regardless.
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

        # Ollama's `options` object: the opt-in sampler knobs, over a generation
        # cap that is not one. `num_predict` is how ollama spells `max_tokens`,
        # every Request declares one, and this arm was the one that sent it
        # nowhere -- so a Thinking finetune deliberated until it chose to stop,
        # bounded by nothing the caller had asked for. It seeds the object
        # rather than joining SAMPLER_KEYS because it answers to no flag:
        # {CLI::Backend#sampler_extra} reads that list and keys on `extra.key?`,
        # which a cap living on the Request itself can never satisfy.
        #
        # One consequence worth stating: a `num_predict` written into
        # Request#extra reaches the wire nowhere. It is not a sampler key, so
        # the loop below never copies it, and the seed here is the Request's own
        # ceiling -- which is the single source for the bound on purpose, since
        # two places to write it is two answers to "what bounded this turn".
        def encode_options(request)
          SAMPLER_KEYS.each_with_object({ num_predict: request.max_tokens }) do |key, options|
            options[key.to_sym] = request.extra[key] if request.extra.key?(key)
          end
        end

        # Flattened to the plain text Ollama's `content` field wants; non-text
        # blocks ride their own fields and contribute nothing.
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
