# Anthropic

The default provider, and the only one with two implementations on the same seam.

| | `Provider::AnthropicRaw` | `Provider::Anthropic` |
|---|---|---|
| Transport | vendored Faraday + SSE (`lib/lain/provider/http/`) | the official `anthropic` gem (`net/http`, `connection_pool`) |
| Role | the default path for `lain chat` and `lain bench record` | the correctness oracle |
| Capabilities | `streaming`, `prompt_caching`, `strict_tools`, `thinking`, `parallel_tool_use` | the same 5, plus `structured_output` |

Both share `AnthropicEncoding`, so `#encode` produces byte-identical kwargs and the dry
differential proves it. The SDK is retired only once the vendored path has held: the byte-diff
must match and one live differential run must produce an identical `Lain::Response`.

## Setup

```bash
export ANTHROPIC_API_KEY=sk-...
lain                              # --provider anthropic is the default
lain --model claude-opus-4-8      # DEFAULT_MODEL, so this is redundant
```

`CLI::Backend` refuses before construction when the key is unset, as
`Backend::MissingAPIKey`. The SDK's own eager check raises
`Provider::HTTP::ConfigurationError`, which is not a `Lain::Error` and would reach you as a raw
backtrace naming an internal collaborator, so the check happens earlier and lands as a clean
error instead.

## Prompt caching

`cache_profile` is `CacheProfile::ANTHROPIC`. `Context::CacheBreakpoints` declares
`requires :prompt_caching`, so it is live here and degrades on Ollama.

**Anthropic's minimum cacheable prefix is 4096 tokens.** A short system prompt silently will not
cache, with no error and no warning on the wire. If cache-hit numbers look wrong on a small
project, check the prefix length before anything else.

`Canonical`'s sorted-key serialization is what keeps the tools block byte-stable across runs, so
the cached prefix is `tools → system → messages` and a tool-schema reordering cannot break the
cache by accident.

## Rate limits and retry

`RATE_LIMIT_RESET_HEADER` is `anthropic-ratelimit-tokens-reset`. Anthropic returns several
`anthropic-ratelimit-*-reset` headers as RFC3339 timestamps; the tokens one is the default
because token limits bind first on large agentic prompts.

**This is not yet confirmed against a live 429.** It used to be a contained risk when
`AnthropicRaw` was bench-only, but it now carries live default chat traffic, so a wrong header
here throttles ordinary conversations. Confirming it is a named follow-up ticket.

`RESET_HEADER_PARSER` handles both formats faraday-retry needs: a bare number is seconds,
anything else is an RFC3339 timestamp converted to seconds-from-now, never negative.

## Wire traps

Each of these cost real debugging. They are verified, not remembered.

- The stream accumulator is **`accumulated_message`**, not `get_final_message`. The stream is
  single-pass and `accumulated_message` mutates its snapshot.
- On the **streaming** path with raw-hash tool schemas, `tool_use.input` arrives as a raw JSON
  **String**. `Provider::AnthropicRaw` parses it, and nothing above the Provider may ever see it
  unparsed.
- The system keyword is `system_:`, with a trailing underscore. `#encode` returns that form so
  the dry-diff can compare against the oracle; `#complete` rewrites it to the wire `system` and
  adds the top-level `stream` flag. Those are the only 2 places the neutral kwargs and the actual
  JSON body differ.
- A content block's `.type` is a **Symbol**, not a String.
- `:model_context_window_exceeded` and `:compaction` are **Beta-only** stop reasons. The non-beta
  enum is `:end_turn :max_tokens :stop_sequence :tool_use :pause_turn :refusal`, and it is
  non-exhaustive. Always have an `else`.

## The vendored transport

`lib/lain/provider/http/` is a slice of `ruby_llm`'s HTTP layer: the Faraday connection stack,
the SSE stream accumulator, and error mapping. MIT, © 2025 Carmine Paolino, namespace-rewritten
and stripped of the lossy `Message` and `Content` model in favor of `Lain::Response`.

`lib/lain/provider/http/VENDOR.md` maps each vendored file to its upstream path and records what
changed. The full porting trace, including the 11 leak sites and the 4 wire protocols across
`ruby_llm`'s 13 providers, is in [`../porting-providers.md`](../porting-providers.md).

### Why vendored, rather than depending on `ruby_llm`

`ruby_llm` is not a dependency of any kind. There is no `Lain::Provider::RubyLLM`, and there never
will be. This reverses an earlier plan (own the loop on the official SDK, keep `ruby_llm` behind a
provider seam) after 3 findings:

- **Auth is neutral.** The API supports exactly 2 auth methods, a Console `x-api-key` and Workload
  Identity Federation. Claude Code's subscription OAuth is, per Anthropic's credential-use policy,
  exclusive to Claude Code and claude.ai. A Console key is required either way, so the gem buys
  nothing on the auth axis.
- **The loop is in the wrong place to be useful.** `RubyLLM::Provider#complete` is already a
  stateless single-shot; `Chat#complete` owns the loop above it. That is the correct seam, and
  Lain never touches `Chat`.
- **Their message model is lossy for this project.** `parse_completion_response` joins every text
  block into one String, joins every thinking block, and keeps only the *first* thinking block's
  signature, destroying the original content array. Lain must commit the full block list, and
  extended-thinking signatures must be echoed back verbatim.

## Debugging

`LAIN_STREAM_DEBUG` dumps raw SSE frames as they arrive. Useful when a stop reason or a
content-block shape does not match what the accumulator produced.

The `:integration` specs hit the live API and cost money. They run only with both:

```bash
LAIN_INTEGRATION=1 ANTHROPIC_API_KEY=sk-... bundle exec rspec
```
