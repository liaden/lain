# Ollama `/api/chat` — native API reference

> ⚠️ **LLM-generated** (Claude, 2026-07-14) — synthesis and organization are Claude's; every
> factual claim below is either a verbatim excerpt (cited) or a claim traced to a specific
> file/line in the `ollama/ollama` repo at `main` as of 2026-07-14. Where a claim rests on
> inference rather than an explicit doc statement, it is marked **inferred**.

Sources (all retrieved 2026-07-14, `ollama/ollama@main`):

- `docs/api.md` — https://github.com/ollama/ollama/blob/main/docs/api.md (legacy single-page
  reference; still live, still the most complete curl-by-curl walkthrough)
- `docs/openapi.yaml` — https://github.com/ollama/ollama/blob/main/docs/openapi.yaml
  (**authoritative** — formal schema; used to resolve every ambiguity below)
- `docs/capabilities/tool-calling.mdx` —
  https://github.com/ollama/ollama/blob/main/docs/capabilities/tool-calling.mdx
- `docs/capabilities/thinking.mdx` —
  https://github.com/ollama/ollama/blob/main/docs/capabilities/thinking.mdx
- `docs/api/streaming.mdx` — https://github.com/ollama/ollama/blob/main/docs/api/streaming.mdx
- `docs/faq.mdx` — https://github.com/ollama/ollama/blob/main/docs/faq.mdx
- `llm/server.go` — https://github.com/ollama/ollama/blob/main/llm/server.go (Go source —
  the `DoneReason` enum; ground truth beneath the docs)
- `server/routes.go` — https://github.com/ollama/ollama/blob/main/server/routes.go
- `api/types.go` — https://github.com/ollama/ollama/blob/main/api/types.go

The docs are mid-migration: `docs/api.md` is a legacy monolith, `docs/capabilities/*.mdx` and
`docs/api/*.mdx` are a newer Mintlify-style split. Both are live; where they disagree, this file
says so and prefers the OpenAPI schema and the Go source.

---

## Endpoint and request shape

`POST /api/chat` — "Generate the next chat message in a conversation between a user and an
assistant." (`openapi.yaml`)

Request fields, per `docs/api.md` and `openapi.yaml`:

| Field | Required | Notes |
|---|---|---|
| `model` | yes | model name |
| `messages` | yes | chat history array |
| `tools` | no | list of tool definitions, OpenAI-function-shaped |
| `format` | no | `"json"` or a JSON Schema, for structured output |
| `options` | no | see Options below |
| `stream` | no | default **`true`** |
| `keep_alive` | no | default `"5m"` |
| `think` | no | boolean or level string, thinking models only |

## Message object

```
{
  "role": "system" | "user" | "assistant" | "tool",
  "content": "...",
  "thinking": "...",       // thinking models only, reasoning trace
  "images": [...],         // base64-encoded, optional
  "tool_calls": [...],     // optional, on assistant messages
  "tool_name": "..."       // on role:"tool" messages, names which tool produced this result
}
```

**No `tool_call_id` field.** Unlike OpenAI (`tool_call_id`) and Anthropic (`tool_use_id`),
Ollama's native wire format correlates a `role: "tool"` result message back to a call by
**`tool_name`** only — position/name, not an opaque id. This is a real interop gap Lain's
`Provider::Ollama` will have to bridge: if two parallel tool calls invoke the *same* tool name,
native Ollama gives no wire-level way to disambiguate which result answers which call. (Verified
against both the `docs/capabilities/tool-calling.mdx` round-trip example and the `openapi.yaml`
`Message` schema — neither has an id field on tool-role messages.)

## Tools and tool_calls

Tool definition (request):

```json
{
  "type": "function",
  "function": {
    "name": "get_temperature",
    "description": "Get the current temperature for a city",
    "parameters": { "type": "object", "required": ["city"], "properties": { "city": {"type": "string"} } }
  }
}
```

Tool call, as it appears in a **response** (`docs/api.md`, retrieved 2026-07-14, live example):

```json
{
  "message": {
    "role": "assistant",
    "content": "",
    "tool_calls": [
      { "function": { "name": "get_weather", "arguments": { "city": "Tokyo" } } }
    ]
  },
  "done_reason": "stop",
  "done": true,
  ...
}
```

The formal `openapi.yaml` `ToolCall` schema (line ~225) has **only** `function.name` and
`function.arguments` (`type: object`) — no `id`, no `index`, no top-level `type`. This is the
authoritative shape for what the server *emits*.

**Doc inconsistency, flagged:** `docs/capabilities/tool-calling.mdx`'s round-trip example shows
an assistant message being *echoed back* into the next request's `messages` array with
`"type": "function"` and `"function": {"index": 0, "name": ..., "arguments": ...}` — extra
fields not in the OpenAPI schema. This is echoing input the client constructed, not necessarily
what the server emits on the wire; treat the OpenAPI schema (name + arguments only) as ground
truth for what to *parse*, and be tolerant of extra fields on write.

## Options object

Enumerated in `docs/api.md`'s valid-parameters listing (not formally exhaustive in
`openapi.yaml`, which types `options` as a free-form object):

```
num_keep, seed, num_predict, draft_num_predict, top_k, top_p, min_p, typical_p,
repeat_last_n, temperature, repeat_penalty, presence_penalty, frequency_penalty,
penalize_newline, stop, numa, num_ctx, num_batch, num_gpu, main_gpu, use_mmap, num_thread
```

Relevant to Lain:

- `temperature` — float, sampler randomness.
- `seed` — integer, sampler seed (see determinism section below).
- `num_ctx` — context window size in tokens. Default **4096** (`docs/faq.mdx`: "By default,
  Ollama uses a context window size of 4096 tokens."), overridable per-request via
  `options.num_ctx`, or server-wide via `OLLAMA_CONTEXT_LENGTH`.

## `think`

`docs/capabilities/thinking.mdx`: "Set the `think` field on chat or generate requests. Most
models accept booleans (`true`/`false`) or levels (`low`, `medium`, `high`, `max`)"; GPT-OSS
models "expect one of `low`, `medium`, or `high`". Reasoning trace comes back as
`message.thinking` (chat endpoint) separate from `message.content`. Streaming interleaves
`thinking` chunks before `content` chunks; the doc's guidance is to buffer both until `done`.
Out of scope for T15 per the plan's Open Decisions (qwen3 emits `message.thinking` under
`think: true`) — noted here for T15's follow-up `R.*` entry.

## `keep_alive`

"Controls how long the model will stay loaded into memory following the request." Default
`"5m"`. Setting `keep_alive: 0` with an empty `messages`/prompt array unloads the model
immediately — this is also how the special `done_reason: "unload"` / `"load"` responses arise
(see below; these are **not** completion outcomes).

## Response shape, `done`, `done_reason`

Non-streaming example (`docs/api.md`):

```json
{
  "model": "llama3.2",
  "created_at": "2023-12-12T14:13:43.416799Z",
  "message": { "role": "assistant", "content": "Hello! How are you today?" },
  "done": true,
  "total_duration": 5191566416,
  "load_duration": 2154458,
  "prompt_eval_count": 26,
  "prompt_eval_duration": 383809000,
  "eval_count": 298,
  "eval_duration": 4799921000
}
```

`prompt_eval_count` = input tokens, `eval_count` = output tokens generated; the `*_duration`
fields are nanoseconds (`total_duration`, `load_duration`, `prompt_eval_duration`,
`eval_duration`).

**`done_reason` is a plain string, not a documented enum** in the OpenAPI schema (`type:
string`). Ground truth is the Go source, `llm/server.go`:

```go
type DoneReason int

const (
	DoneReasonStop DoneReason = iota
	DoneReasonLength
	DoneReasonConnectionClosed
)

func (d DoneReason) String() string {
	switch d {
	case DoneReasonLength:
		return "length"
	case DoneReasonStop:
		return "stop"
	default:
		return ""
	}
}
```

So a real **completion**'s `done_reason` is one of exactly `"stop"` (normal end, including
tool-call turns — see below), `"length"` (hit `num_predict`/context budget), or `""` (empty
string — connection closed mid-generation, the default arm). **There is no `"tool_calls"` or
similar value** — nothing like OpenAI's `finish_reason: "tool_calls"` or Anthropic's
`stop_reason: "tool_use"` exists in this enum.

Separately, `server/routes.go` sets `DoneReason: "load"` and `DoneReason: "unload"` as raw
string literals on the special preload/unload requests (empty-prompt requests used to warm or
evict a model) — these are not part of the `DoneReason` Go enum above and never appear on a
completion that actually generated content.

## Streaming framing

**Confirmed NDJSON, not SSE**, at two independent levels:

1. Doc statement (`docs/api/streaming.mdx`, verbatim): *"These responses are provided in the
   newline-delimited JSON format (i.e. the `application/x-ndjson` content type)."* Setting
   `{"stream": false}` switches the response to plain `application/json`.
2. Formal schema (`docs/openapi.yaml`): the `/api/chat` streaming response media type is
   declared literally as `application/x-ndjson` (five occurrences across `/api/generate`,
   `/api/chat`, and other streaming endpoints).

Each line is a complete, independently-parseable JSON object — no `data: ` prefix, no `event:`
framing, no `[DONE]` sentinel. The stream is simply `\n`-joined JSON objects, the last one
carrying `"done": true` plus the full metrics block. This is unlike Anthropic's SSE and
unlike OpenAI's SSE (`data: {...}\n\n`, terminated by `data: [DONE]`) — both of which Lain's
existing `AnthropicRaw` transport already parses. **T17's streaming path needs its own NDJSON
line-reader, not a reuse of the SSE parser.**

## Determinism: `seed` + `temperature: 0`

This is the documented recipe (used throughout `docs/api.md`'s reproducibility guidance and
implied by `options.seed`/`options.temperature`), but Ollama's own docs do not claim it is
airtight, and community reports back that up:

- [github.com/ollama/ollama/issues/586](https://github.com/ollama/ollama/issues/586) (opened
  2023-09-25, closed) — `/api/generate` with a fixed seed and `temperature: 0` reported as not
  fully deterministic.
- [github.com/ollama/ollama/issues/5321](https://github.com/ollama/ollama/issues/5321) (open,
  retrieved 2026-07-14) — Llama 3 output differs between the *first* run after a model load and
  subsequent runs, even with fixed `seed`/`temperature: 0`/`num_ctx`; runs 2+ are stable and
  reproducible among themselves.

**Known limits** (general LLM-inference facts, applicable to any local runtime including
Ollama's llama.cpp-family backends, not Ollama-specific bugs):

- `seed` only affects the *sampler*; at `temperature: 0` the sampler is greedy (always picks the
  top logit) and the seed is a no-op — determinism at `temperature: 0` comes from greedy decoding
  itself, not from the seed.
- Floating-point non-associativity: GPU kernels sum in a non-fixed order, so identical greedy
  decoding can still diverge by tiny numerical differences that cascade into a different argmax
  token, especially across different batch sizes, GPU models, or driver versions.
- The batch size a request lands in (shaped by concurrent server load) changes which numerical
  code path runs, which can perturb results even prompt-to-prompt on the same machine.

**Practical implication for T15/T17 (bench arm design):** `seed` + `temperature: 0` is necessary
but not provably sufficient for the "determinism oracle" framing — treat it as *high-probability*
reproducibility, verified empirically per-environment (same GPU/CPU, same Ollama build, model
freshly loaded), not as a mathematical guarantee. A same-process/same-load-generation comparison
is markedly more reliable than a first-run one, per issue #5321.

---

## Load-bearing belief verdicts

See `INDEX.md` for the consolidated table; the citations for each verdict live in the sections
above.
