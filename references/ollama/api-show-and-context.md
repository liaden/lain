# Ollama `/api/show`, `/api/ps`, and "how big is the context, really?"

> ⚠️ **LLM-generated** (Claude, 2026-08-17) — synthesis and organization are Claude's; every
> factual claim below is traced to a specific file/line in the `ollama/ollama` repo at `main`
> as of 2026-08-17, or to a measurement in this repo. Claims resting on inference rather than
> an explicit doc statement are marked **inferred**.

Sources (retrieved 2026-08-17, `ollama/ollama@main`):

- `api/types.go` — https://github.com/ollama/ollama/blob/main/api/types.go
  (`ShowRequest`/`ShowResponse`/`ProcessModelResponse` — **authoritative** for the wire shape)
- `server/routes.go` — https://github.com/ollama/ollama/blob/main/server/routes.go
  (`ShowHandler`/`GetModelInfo`, the `/api/ps` handler, the VRAM-tier default)
- `server/sched.go` — https://github.com/ollama/ollama/blob/main/server/sched.go
  (`effectiveContext`, where a runner's real context is decided and recorded)
- `docs/api.md` — https://github.com/ollama/ollama/blob/main/docs/api.md
- `DEBUGGING_OLLAMA.md` (this repo) — the 2026-07-16 serving-stack notes for this box

Written for T9 (`Provider#context_window_tokens`), because the obvious endpoint is the wrong
one and nothing in the docs says so.

---

## The headline: there are TWO context numbers and they are not interchangeable

| | what it is | where it lives | example (`qwen3-coder:30b`) |
|---|---|---|---|
| **trained** | the maximum the weights were trained for, read out of the GGUF metadata | `/api/show` → `model_info["<arch>.context_length"]` | 262,144 |
| **served** | what the loaded runner will actually accept | `/api/ps` → `context_length` | 32,768 on this box |

served = `min(trained, OLLAMA_CONTEXT_LENGTH or the VRAM-tier default, per-request options.num_ctx)`.

Use the trained number as an occupancy denominator and occupancy under-reports by the ratio
between them — **8x** for the pair above. Compaction then never fires and nothing errors.
`lib/lain/context_window.rb:74-77` ranks that failure as worse than the crash it replaces, so
the rule for any consumer is: **under-estimate when unsure; never over-estimate.**

## `POST /api/show`

Request (`api/types.go`, `ShowRequest`): `model`, plus optional `system`, `template`,
`verbose`, `options` (and the deprecated `name`).

Response (`api/types.go`, `ShowResponse`) — every field is `omitempty` except `model_info`:

```
license, modelfile, parameters, template, system, renderer, parser,
details{parent_model, format, family, families, parameter_size, quantization_level},
messages[], remote_model, remote_host,
model_info{}, projector_info{}, tensors[], capabilities[], modified_at, requires
```

Two fields look like they might answer "how big is the window here". Neither does:

- **`model_info`** is the GGUF KV table, handed back nearly verbatim:
  `GetModelInfo` does `resp.ModelInfo = kvData` after deleting only `general.name` and
  `tokenizer.chat_template` (`routes.go`, in `GetModelInfo`). So
  `model_info["<arch>.context_length"]` is a property of the FILE. It is the same number
  whether the server is capped at 4,096 or uncapped, and the same number whether or not the
  model is loaded at all. (The one place `routes.go` *writes* a `context_length` into
  `model_info` itself is the remote/cloud-model branch, from `m.Config.ContextLen` — also a
  model property, not a server setting.)
- **`parameters`** is the Modelfile's `PARAMETER` lines, rendered from `m.Options`
  (`fmt.Sprintf("%-*s %#v", 30, k, v)` over the model's own options). If the *model* bakes in
  a `num_ctx`, it appears here; `OLLAMA_CONTEXT_LENGTH` and the server's VRAM-tier default
  never do. Note it is a formatted **string**, not an object — parsing it means splitting
  30-column-padded lines.

`capabilities` (`completion`, `tools`, `vision`, `thinking`, `insert`, `embedding`, …) is the
genuinely useful part of `/api/show` for a provider: it is the honest source for whether a
model can be asked to `think` or handed `tools`. That is a different card.

**So: `/api/show` cannot answer the served-window question, for any model, ever.**

## `GET /api/ps` — the only endpoint that states the served figure

`docs/api.md` is **stale here**: its `/api/ps` example shows only
`name, model, size, digest, details, expires_at, size_vram`. The Go source has one more field,
and it is the one that matters (`api/types.go`, `ProcessModelResponse`):

```go
type ProcessModelResponse struct {
	Name          string       `json:"name"`
	Model         string       `json:"model"`
	Size          int64        `json:"size"`
	Digest        string       `json:"digest"`
	Details       ModelDetails `json:"details,omitempty"`
	ExpiresAt     time.Time    `json:"expires_at"`
	SizeVRAM      int64        `json:"size_vram"`
	ContextLength int          `json:"context_length"`
}
```

The handler fills it from the scheduler's record of the loaded runner
(`ContextLength: v.contextLength` in the `/api/ps` handler; `lm.contextLength =
r.llama.ContextLength()` in `sched.go`). This is the number `ollama ps`'s CONTEXT column
prints — the same column `DEBUGGING_OLLAMA.md`'s 2026-07-16 entry used to catch a silent
truncation at 4,096.

It is already clamped to the trained ceiling on the way in, so a consumer does **not** need to
`min` it against `/api/show` (`sched.go`):

```go
func effectiveContext(numCtx, trainCtx int) int {
	if trainCtx > 0 && numCtx > trainCtx {
		return trainCtx
	}
	return numCtx
}
```

**Its limit — and it is a real one: `/api/ps` lists only models that are RESIDENT.** Ollama
fixes a runner's context at load time, so before the first request there is no served window
to report; an idle model unloads at `keep_alive` (default 5m) and disappears from the listing
again. An empty listing is not "no cap", it is "not decided yet".

Name matching: entries are printed under `model.ParseName(...).DisplayShortest()`, so an
untagged request (`qwen3`) matches an entry printed as `qwen3:latest`. The handler assigns
**both** `name` and `model` from that same `displayName`, so match on `model` alone — the second
key carries no extra information, and on a body where the two disagree (i.e. not ollama's)
reading it hands back another model's window.

### The stale-runner trap: this figure must be `min`'d with any explicit `num_ctx`

`/api/ps` reports the window of the runner resident **now**, and ollama reloads a runner whose
`NumCtx` differs from the incoming request's (`sched.go`'s `needsReload` compares `NumCtx`). So:

1. `ollama run qwen3-coder:30b` — or a sibling session, or an earlier turn — leaves a runner
   resident at 32,768.
2. A client reads `/api/ps` and gets **32,768**.
3. The same client sends its next request with `options.num_ctx: 8192`.
4. Ollama reloads the runner at **8,192**, and serves that.

The client is now dividing occupancy by a window 4x larger than the one in force — the forbidden
direction, reached through the very endpoint that exists to prevent it. **Any caller that sends
`num_ctx` (an operator `--num-ctx`, `Request#extra["num_ctx"]`) owns the `min` between its own
value and this one.** The provider method cannot see the request, so it cannot take that `min`
for you.

The same mechanism is why the answer must **not** be memoized across turns: a cached reading turns
a momentary disagreement into a permanent one. The lookup is ~0.3 ms (below), so per-turn is
affordable.

## Where the cap comes from when nobody asked for one

`OLLAMA_CONTEXT_LENGTH` is not the only default. If it is unset, `routes.go` picks a default
`num_ctx` from total VRAM at server startup:

| total VRAM | default `num_ctx` |
|---|---|
| ≥ 47 GiB | 262,144 |
| ≥ 23 GiB | 32,768 |
| otherwise | 4,096 |

(The thresholds are deliberately 47/23 rather than 48/24 to absorb reporting slop.) This box
sets `OLLAMA_CONTEXT_LENGTH=32768` explicitly (`DEBUGGING_OLLAMA.md`), which with `q8_0` KV +
flash-attention fits an 8 GiB card at 100% GPU. **None of these three numbers is discoverable
over the API** — not from `/api/show`, not from `/api/version`, not from anywhere. Only their
*consequence*, once a runner exists, shows up in `/api/ps`.

## Verdict, for anyone wiring a context window

1. **`/api/ps` `context_length`, if the model is resident.** That is the served window, already
   clamped to the trained ceiling. Answer it.
2. **Otherwise nil.** Not the trained `context_length`, not a VRAM guess, not
   `OLLAMA_CONTEXT_LENGTH` read out of this process's own env (the server may be on another
   host, and `Provider::Ollama` supports `api_base:`). nil leaves
   `ContextWindow::CONSERVATIVE_FALLBACK` in charge, which errs toward compacting early, and
   leaves an operator override as the way to state a number nobody can discover.
3. **`min` it with any `num_ctx` you are about to send** — see the stale-runner trap above.
4. **Treat a non-Integer `context_length` as absent.** Upstream declares it a Go `int`; Ruby's
   `Integer()` would read the string `"0x40000"` as 262,144, which is exactly the over-estimate
   this whole file is about. Type-check, do not coerce.

`Provider::Ollama#context_window_tokens` implements exactly this.

## Measured cost of the lookup (2026-08-17, this box)

Timed end-to-end through the vendored Faraday stack over loopback, 30 samples each.

| case | min | median | p90 | max |
|---|---|---|---|---|
| server up, model resident | 0.25 ms | **0.27 ms** | 0.52 ms | 16.9 ms |
| server down | 0.2 ms | **0.2 ms** | — | 16.5 ms |

The failure path is the one that constrains a caller, and it is a **retry-budget** decision, not
an inherent cost. The same `GET /api/ps` against a dead port, timed over both connections in one
process (10 samples each):

| budget | min | median | max |
|---|---|---|---|
| completion path (1 attempt + 3 retries, backoff) | 757 ms | **790 ms** | 849 ms |
| probe (1 attempt) | 0.3 ms | **0.3 ms** | 1.7 ms |

A server that is UP but 500s costs the same 790 ms on the completion budget, because both
`Faraday::ConnectionFailed` and `ServerError` are in the vendored `retry_exceptions` — four
attempts with backoff, on the render path, for a number the caller has a fallback for.

`Provider::Ollama::Transport` therefore gives the probe its own budget — one attempt, 2 s timeout
(`PROBE_TIMEOUT_SECONDS`) — over the same middleware stack, which is what brings the down case to
0.3 ms. The completion path keeps its three retries. Anyone adding a second metadata endpoint here
should reuse `probe_connection` rather than `connection`, for the same reason.

The max column is GC/scheduler noise on a loaded box, not a tail of the request itself.
