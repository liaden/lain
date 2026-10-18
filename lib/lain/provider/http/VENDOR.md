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
undoes it. Forking the four files below it that made the HTTP round trip
(at the time: `provider.rb`, `connection.rb`, `stream_accumulator.rb`, the
Anthropic wire format) and taking ownership of the response mapping was
cheaper and more honest than fighting the gem's own abstraction. See `ARCHITECTURE.md`'s Provider
boundary section for why the Anthropic official SDK stays mounted as a
correctness oracle rather than the primary path once the fork lands.

## Scope: Anthropic only

Taken: `provider.rb`, `connection.rb`, `configuration.rb`, `error.rb`,
`error_middleware.rb`, `providers/anthropic.rb`, and the base SSE engine
`streaming.rb` (`RubyLLM::Streaming`, at the top of `lib/ruby_llm/`, NOT under
`providers/`), which needs the `event_stream_parser` gem. The engine has since
grown Lain's own `post_stream`/`flush_stream`, which the non-vendored
transports depend on -- see **Streaming** below before re-vendoring it.

The vendored `Message`/`Content`/`Chunk`/`ToolCall` model, `StreamAccumulator`,
`Provider#complete` and the Anthropic `chat`/`tools` mixins are gone: nothing
in lain ran them. The Anthropic stream hooks (`stream_url`,
`parse_streaming_error`) live in `providers/anthropic.rb` itself.

**Not taken, and not planned for this branch:** `models.rb`, `models.json`
(1.4MB of pricing tables — cost accounting is `Lain::Usage`), `capabilities.rb`,
`anthropic/{capabilities,models,embeddings,media}.rb`, `attachment.rb`, and
every provider besides Anthropic (openai, gemini, bedrock, azure, deepseek,
gpustack, mistral, ollama, openrouter, perplexity, vertexai, xai).

## Structure

```
http/
  LICENSE                            # upstream MIT license, verbatim
  VENDOR.md                          # this file
  error.rb                           # and one file per status-mapped subclass
  error_middleware.rb
  configuration.rb
  logging/sink_logger.rb             # NEW: Sink-backed Logger duck (leak sites 1/2)
  connection.rb
  connection/middleware_stack.rb     # split out: Metrics/ClassLength
  streaming.rb                       # base SSE engine; not in the original file list
  streaming/
    error_handling.rb                # split out: Metrics/ModuleLength (separate responsibility)
    faraday_handlers.rb              # split out: Metrics/ModuleLength (on_data proc + StallClock)
  provider.rb
  provider/
    error_body.rb                    # split out: Metrics/ClassLength
  providers/
    anthropic.rb
```

Files under `connection/`, `provider/` and `streaming/` are **new code, not
ports** -- each says so in its own header. They exist solely so the ported
classes/modules clear this project's default `Metrics/ClassLength`/
`Metrics/ModuleLength` without loosening either cop (forbidden by `CLAUDE.md`).
Each extraction is a real, separate responsibility (an error-body parser, a
streaming error handler, ...), not a mechanical line-count dodge -- see each
file's header for the specific reasoning.

## The eleven leak sites

Resolved as directed by the porting brief; each is named in the relevant
file's provenance header, plus one further site the brief didn't enumerate
(`Configuration#log_regexp_timeout=`'s `RubyLLM.logger.warn` call — see
`configuration.rb`). Full trace: `docs/porting-providers.md`.

## Streaming

The base SSE engine (`streaming.rb`, mixed into `Provider`) drives Faraday's
`on_data` and parses the event stream through `event_stream_parser` (MIT, a
declared dependency). `spec/lain/provider/http/streaming_spec.rb` proves it
end-to-end against a WebMock-delivered event stream, including the error-event
path (an `overloaded_error` raises `OverloadedError` through
`Streaming::ErrorHandling` and Anthropic's own `parse_streaming_error`).

`Anthropic::Transport#stream` (outside this directory) posts its own request
and installs its own `on_data` handler. It reaches the vendored engine through `Streaming#post_stream`, which assigns
the handler and then runs `flush_stream` -- a blank line fed to the parser once
the body is read, because the SSE spec discards an event that never got its
terminating blank line, and a discarded `event: error` is an overload recorded
as a successful empty turn. Both methods are Lain's, not upstream's: a
re-vendor that drops them reintroduces that swallow in that transport with
nothing failing in this directory. `streaming.rb`'s header lists all three
Lain-side additions.
