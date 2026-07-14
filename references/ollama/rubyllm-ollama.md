# RubyLLM's Ollama provider — an OpenAI-subclass shim

> ⚠️ **LLM-generated** (Claude, 2026-07-14) — synthesis is Claude's; every code excerpt is
> verbatim from `crmne/ruby_llm` tag `1.16.0` (the version vendored, Anthropic-only, at
> `lib/lain/provider/http/` in this repo — see `lib/lain/provider/http/VENDOR.md`), retrieved
> 2026-07-14 via `https://raw.githubusercontent.com/crmne/ruby_llm/1.16.0/...`.

## The headline finding

**RubyLLM's `Ollama` provider never speaks Ollama's native `/api/chat`.** It subclasses `OpenAI`
and talks exclusively to Ollama's **OpenAI-compatible** surface (`/v1/...`, conventionally
`http://localhost:11434/v1`). This is the concrete justification for T15's decision to build a
*native* `Provider::Ollama` instead of reusing/adapting this shim: everything documented in
`api-chat.md` — `done_reason`'s real enum, `prompt_eval_count`/`eval_count`, native `think`
levels, `keep_alive`, NDJSON framing — is invisible to RubyLLM's Ollama integration. It inherits
OpenAI's SSE framing, OpenAI's `finish_reason` vocabulary, and OpenAI's token-usage fields
instead, because that's the wire format it's actually on.

Confirmed independently by an open issue against the gem itself:
[crmne/ruby_llm#581 — "Ollama provider works only with OpenAI compatible endpoint"](https://github.com/crmne/ruby_llm/issues/581).

## Full source of `lib/ruby_llm/providers/ollama.rb`

```ruby
module RubyLLM
  module Providers
    # Ollama API integration.
    class Ollama < OpenAI
      include Ollama::Chat
      include Ollama::Media
      include Ollama::Models

      def api_base
        @config.ollama_api_base
      end

      def headers
        return {} unless @config.ollama_api_key

        { 'Authorization' => "Bearer #{@config.ollama_api_key}" }
      end

      class << self
        def configuration_options
          %i[ollama_api_base ollama_api_key]
        end

        def configuration_requirements
          %i[ollama_api_base]
        end

        def local?
          true
        end

        def capabilities
          Ollama::Capabilities
        end
      end
    end
  end
end
```

That is the **entire class body**. Everything else — request building, streaming, tool-call
parsing, error handling, temperature normalization, model listing shape — is inherited from
`OpenAI` untouched. Ollama overrides exactly three things: where to send requests
(`api_base`/`headers`), and three small modules (`Chat`, `Media`, `Models`).

**No default `api_base`.** `configuration_options` registers `ollama_api_base` with no default
value (`Configuration.option(key, default = nil)`); the gem's own setup docs
(`docs/_getting_started/configuration.md`) tell users to set it explicitly:

```ruby
config.ollama_api_base = 'http://localhost:11434/v1'   # note the /v1 — OpenAI-compat path
config.ollama_api_key = ENV['OLLAMA_API_KEY']           # optional, for authenticated/remote Ollama
```

## What it maps

- **Message shape** — `Ollama::Chat#format_messages` builds the OpenAI-style
  `{role, content, tool_calls, tool_call_id}` hash per message (reusing OpenAI's
  `format_thinking` for the reasoning-content field), then formats content via
  `Ollama::Media#format_content` (which extends `OpenAI::Media`, adding only a `Content::Raw`
  passthrough and JSON-stringifying bare Hash/Array content).
- **Tool-choice/parallel-control capability gating** — `Ollama::Capabilities` hardcodes both
  `supports_tool_choice?` and `supports_tool_parallel_control?` to `false`, regardless of model —
  i.e. RubyLLM never sends OpenAI's `tool_choice` or parallel-tool-call knobs to an Ollama
  backend, even though the OpenAI-compat request builder supports them for real OpenAI.
- **Model listing** — `Ollama::Models#models_url` returns `'models'` (relative to `api_base`),
  so it lists models via `GET {ollama_api_base}/models` (the OpenAI-compat models endpoint) and
  parses the OpenAI `{data: [...]}` shape — **not** Ollama's native `GET /api/tags`.
- **Streaming** — inherited wholesale from `OpenAI::Streaming`. `build_chunk` reads
  `data.dig('choices', 0, 'delta')`, i.e. OpenAI's SSE choice/delta shape, and the base
  `lib/ruby_llm/streaming.rb` parses each frame by stripping a **`data: ` prefix**
  (`chunk.split("\n")[1].delete_prefix('data: ')`, `handle_sse`) — confirmed SSE, the opposite
  framing from native `/api/chat`'s NDJSON (see `api-chat.md`).
- **Tool-call argument accumulation during streaming** — `OpenAI::Streaming#build_chunk` calls
  `parse_tool_calls(delta['tool_calls'], parse_arguments: false)`, i.e. it keeps `arguments` as
  a raw string fragment to be concatenated across chunks and parsed once complete — the OpenAI
  incremental-JSON-string streaming idiom. This has **no bearing on native Ollama**, where
  `tool_calls[].function.arguments` arrives as a complete parsed object even mid-stream (per
  `api-chat.md`) — a different accumulation problem entirely, which a native `Provider::Ollama`
  must solve itself.
- **Temperature normalization** — inherited `OpenAI::Temperature.normalize`, which special-cases
  OpenAI's `o*`/`gpt-5*` reasoning models (forces `temperature: 1.0`) and `-search` models
  (drops `temperature` entirely). None of these apply to Ollama-hosted models, but the code path
  runs unconditionally — **inferred** to be a no-op for Ollama model-id strings (they won't match
  `/^(o\d|gpt-5)/` or contain `-search`), but worth flagging as inherited behavior that was never
  written with Ollama in mind.

## What it ignores

- **`done_reason`, `prompt_eval_count`/`eval_count`, `total_duration`/`load_duration`** — none of
  these exist on the OpenAI-compat wire shape RubyLLM reads; it reads OpenAI's `usage` object
  (`prompt_tokens`/`completion_tokens`) and OpenAI's `finish_reason` instead. Whatever Ollama's
  OpenAI-compat endpoint maps its native metrics *into* on that surface (not verified here — the
  card marks this out of scope; the OpenAI-compat doc doesn't show a full response example) is
  what RubyLLM actually sees, if anything.
- **Native `think` levels** (`low`/`medium`/`high`/`max`) — from RubyLLM's own thinking guide
  (`docs/_core_features/thinking.md`, verbatim): *"Ollama and GPUStack local-model thinking
  controls vary by backend and model. RubyLLM does not translate them; pass backend params
  explicitly with `with_params`."* And: *"Anthropic and Ollama integrations currently do not
  report thinking token counts."* RubyLLM has no first-class `think:` mapping for Ollama at all —
  it's an escape-hatch-only feature here.
- **`keep_alive`** — no configuration surface in the gem; not reachable through RubyLLM's chat
  API (OpenAI's wire format has no equivalent concept).
- **`num_ctx` and the rest of the native `options` object** — RubyLLM speaks OpenAI's flat
  request shape (`temperature`, `max_tokens`, etc. at the top level); Ollama-native tuning knobs
  like `num_ctx`, `num_gpu`, `mirostat`, `repeat_last_n` have no mapping. `with_params` is the
  only escape hatch (**inferred** from the thinking-guide quote above, which names it as the
  general mechanism for backend-specific knobs).
- **`tool_name`-keyed tool results** — RubyLLM formats tool-result messages the OpenAI way
  (`tool_call_id`-correlated), which Ollama's OpenAI-compat endpoint must itself translate to/from
  native `tool_name`-correlation server-side; RubyLLM never touches that translation.

## Why this matters for T15

The Provider seam contract (`lib/lain/provider.rb`) is `capabilities` / `encode(request)` /
`complete(request)`, one round trip, no loop. A native `Provider::Ollama` gets to be *simpler*
than this shim in one respect (no OpenAI-compatibility-layer indirection to reason about) and
*harder* in another (it must directly own: NDJSON line framing, deriving `:tool_use` from
`tool_calls` presence rather than trusting `done_reason`, and the `tool_name`-not-`tool_call_id`
correlation problem for parallel tool calls). None of that is inherited for free from this gem —
confirmed by reading its actual source, not assumed from its README.
