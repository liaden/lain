# Vendored: ruby_llm HTTP transport

This directory forks a slice of [ruby_llm](https://github.com/crmne/ruby_llm)
**1.16.0**, commit `2cf34b9264a5d6cd4ea7868c6989232b2bedf2c1`, © 2025 Carmine
Paolino, **MIT** (see `LICENSE` in this directory — the full text, unmodified,
per the license's own condition).

Every file below carries its own provenance header naming the exact upstream
path and what changed. This file is the map; `docs/porting-providers.md` (at
the repo root) is the reasoning, written so the next provider (openai,
gemini, ...) can be ported the same way without rediscovering it.

## Why fork instead of depend

`Lain::Request`/`Lain::Response` are content-addressed, provider-neutral
value objects (see `lib/lain/request.rb`, `lib/lain/response.rb`); the
Timeline is a lossless Merkle DAG that must retain every content block —
text, thinking, and tool_use — verbatim. `ruby_llm`'s own `Message`/`Content`
flatten all text blocks into one String, join all thinking blocks, and keep
only the *first* thinking block's signature. That is a real information
loss Lain's correctness gates cannot tolerate, and no configuration option
undoes it. Forking the four files below it that make the HTTP round trip
(`provider.rb`, `connection.rb`, `stream_accumulator.rb`, the Anthropic wire
format) and taking ownership of the response mapping is cheaper and more
honest than fighting the gem's own abstraction. See the plan
(`~/.claude/plans/jiggly-greeting-avalanche.md`, "Transport: fork RubyLLM's
HTTP layer") for the full argument, including why the Anthropic official SDK
is kept as a correctness oracle rather than the primary path.

## Scope: Anthropic only

Taken: `provider.rb`, `connection.rb`, `configuration.rb`,
`stream_accumulator.rb`, `error.rb`, `error_middleware.rb`, `chunk.rb`,
`tool_call.rb`, `utils.rb`, `message.rb`, `content.rb`,
`providers/anthropic.rb`, `providers/anthropic/{chat,streaming,tools}.rb`.

Also taken, not in the original file list but required transitively for the
above to load and behave correctly (see `docs/porting-providers.md` for why
each was missing from the brief): `thinking.rb`, `tokens.rb`. `models.rb`'s
five streaming-usage-extraction methods were folded into
`providers/anthropic/streaming.rb` rather than resurrecting a `Models` file
— see that file's header.

**Not taken, and not planned for this branch:** `models.rb`, `models.json`
(1.4MB of pricing tables — cost accounting is `Lain::Usage`), `capabilities.rb`,
`anthropic/{capabilities,models,embeddings,media}.rb`, `attachment.rb`,
`streaming.rb` (the base SSE engine — needs the `event_stream_parser` gem,
which is not a Lain dependency; see `provider.rb`'s header), and every
provider besides Anthropic (openai, gemini, bedrock, azure, deepseek,
gpustack, mistral, ollama, openrouter, perplexity, vertexai, xai).

## Structure

```
http.rb                              # require-order loader; the subject every spec requires
http/
  LICENSE                            # upstream MIT license, verbatim
  VENDOR.md                          # this file
  error.rb
  error_middleware.rb
  configuration.rb
  logging/sink_logger.rb             # NEW: Sink-backed Logger duck (leak sites 1/2)
  connection.rb
  connection/middleware_stack.rb     # split out: Metrics/ClassLength
  utils.rb
  tokens.rb                          # not in the original file list; required transitively
  thinking.rb                        # not in the original file list; required transitively
  tool_call.rb
  content.rb
  message.rb
  chunk.rb
  stream_accumulator.rb
  stream_accumulator/
    think_tag_scanner.rb             # split out: Metrics/ClassLength
    tool_call_accumulator.rb         # split out: Metrics/ClassLength
  provider.rb
  provider/
    registry.rb                      # split out: Metrics/ClassLength
    error_body.rb                    # split out: Metrics/ClassLength
  providers/
    anthropic.rb
    anthropic/
      chat.rb                        # payload assembly
      chat/
        message_formatting.rb        # split out: Metrics/ModuleLength
        thinking_payload.rb          # split out: Metrics/ModuleLength
        response_parsing.rb          # split out: Metrics/ModuleLength
      streaming.rb
      tools.rb
```

Files under `connection/`, `provider/`, `stream_accumulator/`, and
`providers/anthropic/chat/` are **new code, not ports** — each says so in
its own header. They exist solely so the ported classes/modules clear this
project's default `Metrics/ClassLength`/`Metrics/ModuleLength` without
loosening either cop (forbidden by `CLAUDE.md`). Each extraction is a real,
separate responsibility (a think-tag scanner, a tool-call-fragment
accumulator, a provider registry, ...), not a mechanical line-count dodge —
see each file's header for the specific reasoning.

## The eleven leak sites

Resolved as directed by the porting brief; each is named in the relevant
file's provenance header, plus one further site the brief didn't enumerate
(`Configuration#log_regexp_timeout=`'s `RubyLLM.logger.warn` call — see
`configuration.rb`). Full trace: `docs/porting-providers.md`.

## What still doesn't work

`Provider#complete`'s streaming path (block given) calls `stream_response`,
which does not exist in this branch — the base `RubyLLM::Streaming` module
that would supply it needs the `event_stream_parser` gem (MIT, already
installed in this environment's gemset but **not** a declared Lain
dependency). The synchronous path, and everything the vendored unit specs
exercise, is unaffected. See `provider.rb`'s header and
`docs/porting-providers.md` for the exact gap and what adding the gem would
unblock.
