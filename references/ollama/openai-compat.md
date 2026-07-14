# Ollama's OpenAI-compatible endpoint — brief, for contrast

> ⚠️ **LLM-generated** (Claude, 2026-07-14) — synthesis is Claude's; quotes are verbatim from
> `docs/api/openai-compatibility.mdx`, https://github.com/ollama/ollama/blob/main/docs/api/openai-compatibility.mdx,
> retrieved 2026-07-14.

This file exists only to sharpen the contrast with `api-chat.md` (the native path Lain uses) —
it is deliberately brief. `rubyllm-ollama.md` documents that RubyLLM's Ollama provider talks
*exclusively* to this surface, never to native `/api/chat`.

## What it is

"Ollama provides compatibility with parts of the OpenAI API to help connect existing
applications to Ollama." A second, parallel HTTP surface bolted onto the same server, at
`/v1/...` instead of `/api/...`.

Endpoints: `/v1/chat/completions`, `/v1/completions`, `/v1/models` (+ `/v1/models/{model}`),
`/v1/embeddings`, `/v1/images/generations` (experimental), `/v1/responses` (added v0.13.3).

## Support matrix (doc's own words)

Chat completions — supported: "Chat completions, Streaming, JSON mode, Reproducible outputs,
Vision, Tools, Reasoning/thinking control." Explicitly unsupported: `logprobs`, `tool_choice`,
`logit_bias`, `user`, `n`.

## The framing contrast that matters for T15/T17

This surface is a standard OpenAI Chat Completions emulation, which implies (by the nature of
"OpenAI compatible" — Ollama's own doc does not re-document the wire framing, since the point is
that existing OpenAI clients work unmodified):

- **SSE streaming** (`data: {...}\n\n`, `[DONE]` sentinel) — not NDJSON. This is corroborated
  directly, not just inferred: RubyLLM's `OpenAI::Streaming` module (inherited unmodified by its
  `Ollama` provider, which targets exactly this endpoint) parses frames by stripping a literal
  `data: ` prefix — see `rubyllm-ollama.md`.
  This is the opposite of native `/api/chat`'s confirmed `application/x-ndjson` framing
  (`api-chat.md`).
- **OpenAI's `finish_reason` vocabulary** (`"stop"`, `"length"`, `"tool_calls"`, ...) in place of
  native `done_reason`'s two-value enum (`api-chat.md`'s Go-source finding: `"stop"`/`"length"`
  only, nothing named after tool calls).
- **OpenAI's `usage` object** (`prompt_tokens`/`completion_tokens`) in place of native
  `prompt_eval_count`/`eval_count` and the nanosecond duration fields.
- Tool calls get an `id`, correlated via `tool_call_id` in the OpenAI convention — a real
  capability native `/api/chat` lacks (see `api-chat.md`'s no-`tool_call_id` finding).

**Why T15 doesn't use this surface:** it would buy OpenAI-shaped wire compatibility at the cost
of everything the plan wants from the native path — `done_reason`'s real semantics,
`prompt_eval_count`/`eval_count` cost accounting, `keep_alive` control, and NDJSON's simpler
framing over SSE's. The OpenAI-compat surface exists for drop-in client reuse, not for exposing
Ollama's actual behavior.
