# Ollama reference corpus — Lain study bench

Built for T1 (plan: `planning/specs/code-review-ollama-test-infra.md`), grounding T15
(`Provider::Ollama`, native API) and T17 (its streaming path). Every synthesized file here
carries the ⚠️ LLM-generated header; verbatim excerpts inside them cite their source URL and a
2026-07-14 retrieval date.

## Files

### [api-chat.md](api-chat.md) ⚠️ LLM-generated
The primary reference: Ollama's native `POST /api/chat` — message shape, `tools`/`tool_calls`,
the `options` object (`temperature`, `seed`, `num_ctx`, and the rest), `think`, `keep_alive`,
`done_reason`'s real (2-value) enum traced to the Go source, `prompt_eval_count`/`eval_count`,
streaming framing, and the `seed`+`temperature:0` determinism recipe with its documented limits.
**This is the file T15/T17 should read first.**

### [openai-compat.md](openai-compat.md) ⚠️ LLM-generated
Brief, deliberately thin — Ollama's *parallel* OpenAI-compatible surface (`/v1/...`), included
only to sharpen the contrast: SSE vs NDJSON, `finish_reason` vs `done_reason`, `usage` vs
`eval_count`, `tool_call_id` vs `tool_name`-only correlation. Explains why T15 chose the native
path.

### [rubyllm-ollama.md](rubyllm-ollama.md) ⚠️ LLM-generated
Reads `crmne/ruby_llm`'s actual `Ollama < OpenAI` provider source (tag `1.16.0`, the version
vendored — Anthropic-only — at `lib/lain/provider/http/` in this repo). Headline finding:
**RubyLLM's Ollama integration never touches native `/api/chat`** — it's a 30-line subclass of
the OpenAI provider that only overrides `api_base`/`headers` and three small formatting modules;
everything else (SSE streaming, `finish_reason`, tool-call `id`s, temperature normalization
tuned for OpenAI's o*/gpt-5 models) is inherited from `OpenAI` untouched. Documents what it maps
and what it silently ignores (native `think` levels, `keep_alive`, `num_ctx`, the metrics
fields) — the concrete justification for building native instead of adapting this shim.

---

## Load-bearing belief verdicts

Required by T1's acceptance criteria — T15's implementer should be able to read this table alone
and know where they stand. Full citations are in `api-chat.md`.

| # | Belief | Verdict | Evidence |
|---|---|---|---|
| (a) | Streamed `/api/chat` responses are NDJSON lines, not SSE | **CONFIRMED** | `docs/api/streaming.mdx`, verbatim: *"provided in the newline-delimited JSON format (i.e. the `application/x-ndjson` content type)"*. Independently confirmed by `docs/openapi.yaml`'s formal media-type declaration (`application/x-ndjson`, 5 occurrences). No `data:`/SSE framing anywhere in the native docs or OpenAPI schema. |
| (b) | `tool_calls[].function.arguments` arrives as a **parsed object**, not a JSON string | **CONFIRMED** | Live response example in `docs/api.md`: `"arguments": {"city": "Tokyo"}` (object literal, not a string). Formally pinned by `docs/openapi.yaml`'s `ToolCall` schema: `arguments: {type: object, description: "JSON object of arguments to pass to the function"}`. |
| (c) | `done_reason` stays `"stop"` on tool-call turns, so `:tool_use` must be derived from the presence of `tool_calls` | **CONFIRMED, and sharper than stated** | The live tool-call example in `docs/api.md` shows `"tool_calls": [...], "done_reason": "stop"` together. Traced to the Go source (`llm/server.go`): `DoneReason` is a **closed 3-value enum** — `DoneReasonStop → "stop"`, `DoneReasonLength → "length"`, `DoneReasonConnectionClosed → ""` (default arm, empty string). There is no tool-call-specific value at all, unlike OpenAI's `finish_reason: "tool_calls"` or Anthropic's `stop_reason: "tool_use"`. `("load"/"unload"` are separate string literals `server/routes.go` sets only on empty-prompt preload/unload requests — never on a real completion.) |
| (d) | `seed` + `temperature: 0` is the determinism recipe, and it has known limits | **CONFIRMED as the recipe; limits are real and documented in the wild, not in Ollama's own docs** | The recipe itself is implied throughout `docs/api.md`'s options and is the standard local-inference practice. Ollama's docs do **not** claim it's airtight. Two GitHub issues corroborate concrete failures: [#586](https://github.com/ollama/ollama/issues/586) (closed) and [#5321](https://github.com/ollama/ollama/issues/5321) (open, retrieved 2026-07-14) — first-run-after-load divergence even with fixed seed/temperature/num_ctx; runs are stable among themselves after that. Root causes are general to any local GPU inference (floating-point non-associativity, batch-size-dependent kernel paths, seed being a no-op once temperature is already 0 and decoding is greedy) — not something a client-side fix resolves. Practical guidance for T15/T17: treat determinism as *high-probability within one warm environment*, not a mathematical guarantee. |

**No escalation triggers fired.** Belief (a) held (NDJSON, not SSE) — T17's streaming design can
proceed as planned. RubyLLM 1.16.0's Ollama integration has not materially diverged from
Ollama's current API in a way that matters to T15, because RubyLLM's integration was never
built against native `/api/chat` in the first place (see `rubyllm-ollama.md`) — there is nothing
for it to have drifted *from*, on the native surface. The one thing worth flagging as a
surprise, not an escalation: native `/api/chat` has **no `tool_call_id`/`tool_use_id` equivalent**
(correlation is by `tool_name` only) — a real design constraint for T15 mapping into Lain's
`Effect`/tool-result model when a turn issues two parallel calls to the same tool.
