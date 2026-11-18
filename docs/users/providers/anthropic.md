# Anthropic

Anthropic is the default provider. `Provider::Anthropic` runs on lain's own HTTP transport (vendored
Faraday and SSE under `lib/lain/provider/http/`); the official SDK is not a runtime dependency.

Capabilities: `streaming`, `prompt_caching`, `strict_tools`, `thinking`, `parallel_tool_use`, `token_counting`.

## Setup

```bash
export ANTHROPIC_API_KEY=sk-...
lain                              # --provider anthropic is the default
lain --model claude-opus-4-8      # DEFAULT_MODEL, so this is redundant
```

`CLI::Backend` refuses before construction when the key is unset, as
`Backend::MissingAPIKey`. The SDK's own eager check raises
`Provider::HTTP::ConfigurationError`, which is not a `Lain::Error` and would reach you as a raw
backtrace naming an internal collaborator, so the check runs earlier and you get a clean
error.

## Prompt caching

`cache_profile` is `CacheProfile::ANTHROPIC`. `Context::CacheBreakpoints` declares
`requires :prompt_caching`, so it is live here and degrades on Ollama.

Anthropic's minimum cacheable prefix is 4096 tokens. A short system prompt silently will not
cache, with no error and no warning on the wire. If cache-hit numbers look wrong on a small
project, check the prefix length before anything else.

`Canonical`'s sorted-key serialization keeps the tools block byte-stable across runs. The cached
prefix is `tools → system → messages`, so a tool-schema reordering cannot break the cache by accident.

## Rate limits and retry

`RATE_LIMIT_RESET_HEADER` is `anthropic-ratelimit-tokens-reset`. Anthropic returns several
`anthropic-ratelimit-*-reset` headers as RFC3339 timestamps; the tokens one is the default
because token limits bind first on large agentic prompts.

This header is not yet confirmed against a live 429. A wrong header here would throttle ordinary
conversations.

`RESET_HEADER_PARSER` handles both formats faraday-retry needs: a bare number is seconds,
anything else is an RFC3339 timestamp converted to seconds-from-now, never negative.

## The vendored transport

`lib/lain/provider/http/` is a slice of `ruby_llm`'s HTTP layer: the Faraday connection stack,
the SSE engine, and error mapping. MIT, © 2025 Carmine Paolino. It is namespace-rewritten
and stripped of its lossy `Message` and `Content` model, which `Lain::Response` replaced.

`lib/lain/provider/http/VENDOR.md` maps each vendored file to its upstream path and records what
changed. The porting trace and the reasons for vendoring are in
[`docs/devs/porting-providers.md`](../../devs/porting-providers.md).

## Debugging

`LAIN_STREAM_DEBUG` dumps raw SSE frames as they arrive. Use it when a stop reason or a
content-block shape does not match what the accumulator produced.
