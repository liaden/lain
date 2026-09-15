# Ollama

`Provider::Ollama` gives the bench a free, local, temperature-0 arm over Ollama's
native `/api/chat` (NDJSON streaming + non-streaming). It exists to be an
exploration target on the "Provider / model" axis and a *determinism oracle* for
tests — but read the [Determinism](#determinism-the-honest-version) section
before you trust the second half of that sentence.

The provider itself is documented in `lib/lain/provider/ollama.rb`; the wire
format and its quirks are distilled in `references/ollama/`. This file is only
the operational how-to.

## Capabilities

`streaming`, `thinking`, `structured_output`. `cache_profile` is
`CacheProfile::NO_CACHING`.

No `prompt_caching` and no `strict_tools`, which makes Ollama the provider that
most often triggers a capability degrade. A `Context::CacheBreakpoints` combinator
declares `requires :prompt_caching`, so under `:degrade` it no-ops here and the
degradation lands in the Journal; under `:strict` it raises. `Capability::Guard`
then refuses to compare an Ollama run against an Anthropic run whose degraded set
differs. That is the point: a context tactic that silently became a no-op would
otherwise make the comparison a lie.

## Ollama also powers compaction, on every provider

Even when you are chatting against Claude, the eager tool-result summarizer talks
to a local Ollama model. `CLI::Backend#summary_oracle` wires
`Provider::Ollama.new(api_base:)` at `DEFAULT_MODEL` unconditionally, never the
chat's own provider: a summary fires once per large tool result, off the turn's
critical path, and paying frontier-model tokens to compress a tool result would
cost more than resending it.

So `ollama serve` + `ollama pull qwen3:4b` is worth doing even if you never pass
`--provider ollama`. Without it, the fire fails inside `Oracle::Eager`'s task
boundary, nothing raises, and the compacting turn renders an elision line instead
of a summary. See the
[README](../../README.md#compaction-and-summarizer-tiers) for the three tiers.

Ollama is the summarizer's **default**, not its only home: `--summarizer-provider`
and `--summarizer-model` point that tier anywhere, independently of `--provider`.
`--api-base` moves whichever of the two is on Ollama.

## Install and pull the model

```bash
# 1. Install Ollama (https://ollama.com/download), then start the server:
ollama serve            # serves http://localhost:11434 by default

# 2. Pull the default model the provider targets:
ollama pull qwen3:4b
```

`qwen3:4b` is `Provider::Ollama::DEFAULT_MODEL` — the current best small
tool-calling model for a free local arm. A bigger sibling (`qwen3:8b`) is the
fallback if `4b` will not emit tool calls reliably for your prompts.

## Driving it from the CLI

```bash
exe/lain --provider ollama                       # defaults to qwen3:4b
exe/lain --provider ollama --temperature 0 --seed 42
exe/lain --provider ollama --model qwen3:8b
exe/lain --provider ollama --api-base http://otherhost:11434
```

`--temperature` and `--seed` ride `Request#extra` into Ollama's `options` object;
`--temperature 0` is the determinism recipe. `--api-base` overrides the localhost
default (Ollama is local, so there is no API key).

## Environment variables

| Var | Read by | Meaning |
|---|---|---|
| `LAIN_OLLAMA=1` | the test suite | Opt the `:ollama` integration specs in. Without it they are excluded and any localhost call is blocked (offline default). |
| `OLLAMA_API_BASE` | **the test suite only** | Point the `:ollama` specs at a non-default server. Threaded into both the reachability probe and `Provider::Ollama.new(api_base:)`. Defaults to `http://localhost:11434`. |

Note: **the library does not read `OLLAMA_API_BASE`.** `Provider::HTTP::Configuration`
has no env-var default for `ollama_api_base`; the base is a constructor argument
(`Provider::Ollama.new(api_base:)`) or the `exe/lain --api-base` flag. The env var
is a convenience for the specs, nothing more.

## Serving performance

The variables above configure *lain*; they say nothing about how fast the server answers.
That is measured in `DEBUGGING_OLLAMA.md` (2026-08-14 entry) and it matters more than it
looks, because **ollama's own defaults are wrong for this workload**:

- **Pass `num_batch` explicitly.** Ollama passes `-b 512` to llama-server, overriding
  llama.cpp's own default of 2048; there is no
  server-side setting for it. `exe/lain`'s `--num-batch` flag (`$LAIN_NUM_BATCH`) threads it into
  the request, alongside `--num-ctx` (`$LAIN_NUM_CTX`) for context length — both strictly
  opt-in: leave either unset and the payload carries no `options` key at all. On the RX 7900
  XTX, `DEBUGGING_OLLAMA.md`'s 2026-08-14 entry measured this costing up to **3x decode and 8x
  prefill** (`qwen3-coder:30b` prefill: 340 → 2,222 tok/s, 6.5x, going from `num_batch=512` to
  `2048`), strongly model-dependent (1.1x–2.7x on decode across four models). The 2026-08-15
  integration POC measured the *same* model on the *same* axis, on the *same* box and build, at
  **1,201/1,194 → 1,578/1,562 tok/s (1.31x)**, replicated with distinct prompts. Both are real
  measurements and **the gap between 6.5x and 1.31x is currently unreconciled** — see
  `DEBUGGING_OLLAMA.md`'s 2026-08-17 entry before quoting either figure as *the* number. Prefill
  is what a turn carrying a large `tool_result` pays, so it is the number the harness feels
  either way.
- **KV cache type trades context for speed.** `q8_0` gives ~64k usable context, `f16` ~32k —
  but at 32k `f16` is 13% *faster*. Pick by the context the task needs, not by habit.
- **Vulkan, not ROCm**, on this box: ~30% faster decode and it starts reliably, where ROCm
  cannot bring some models up at all.

`bin/bench-ollama-gpu` re-runs any of those measurements. Read the entry's
"How these were measured" section first — the prompt cache fabricates prefill rates, and
"offloaded N/N layers to GPU" does not mean the model is resident.

## Two context numbers, and only one is a denominator

Ollama publishes two different context lengths, and `Provider::Ollama` keeps them behind two
separate methods on purpose — `#context_window_tokens` and `#trained_context_tokens` — because
mistaking one for the other is a silent 8x error.

- **`/api/show`'s `model_info.<arch>.context_length`** is the GGUF's **trained maximum**:
  262,144 for `qwen3-coder:30b`. It is always available and is **never a denominator**. Divide
  occupancy by it and occupancy under-reports 8x, so compaction never fires — a worse failure
  than the crash compaction exists to prevent. Its one legitimate use is refusing a `--num-ctx`
  no runner could ever serve.
- **`/api/ps`'s per-runner `context_length`** is what the **loaded runner is actually serving**:
  `min(trained, OLLAMA_CONTEXT_LENGTH, per-request num_ctx)`, which is 32,768 on this box (see
  `DEBUGGING_OLLAMA.md`). `/api/ps` states the served figure or nobody does, so `nil` — no
  resident runner, or an unreachable server — is the **ordinary** answer and leaves
  `ContextWindow`'s conservative fallback in charge.
- **An over-window 400's `n_ctx`** is the same served figure, stated by the runner that just
  refused a prompt against it. `Middleware::ResolveWindow` adopts it as an authoritative window
  (`WindowBook::Live#vouch`), which also corrects a book that probed a stale, smaller runner
  before the request reloaded it. The turn stack cannot see the refused request, but
  `Middleware::RequestBudget` in the model phase can: the refusal it re-raises names the refused
  request's model, and the vouch lands on that model, so a refusal after a `/model` switch
  leaves the run's `--model` with the answer it had.

**A caller that sends `num_ctx` owns the `min`.** Ollama reloads a runner whose `NumCtx` differs
from the request's (`sched.go`'s `needsReload`), so a runner left at 32,768 by `ollama run`, by a
sibling session, or by an earlier turn reports 32,768 while the very next request — carrying an
explicit `num_ctx` of 8,192 — is served 8,192. The provider cannot see the request, so the
caller must take the minimum of the reported window and its own flag.

### What the probe costs

Measured 2026-08-17 on loopback: ~0.27 ms warm, ~0.3 ms with the server down. Cheap enough to
ask **per turn**, which is what staying correct across a reload requires — memoizing it is what
would make the stale-runner case above permanent rather than momentary.

The case that does bite is a **black-holed host**. `--api-base http://10.255.255.1:11434` spends
the full `Transport::PROBE_TIMEOUT_SECONDS`, measured **2,002 ms per call**, and
`Middleware::ResolveWindow` re-asks at the top of every agent-loop iteration for as long as the
window book stays a guess — measured at **+20 s on a ten-tool-call turn** before it was bounded.

So the budget is charged by what a probe **cost**, not by what it answered.
`CLI::Backend::WindowBook#lookup` times each `Provider#window_probe` on an injected monotonic clock,
and a probe slower than `WindowBook::Lookup::COSTLY_SECONDS` (50 ms) spends one of
`WindowBook::Live::REASK_LIMIT` re-asks. 50 ms is well above a local `/api/ps`, which answers or
refuses in about a millisecond, and well below what one agent-loop iteration can absorb. A timeout
always exceeds it, because `PROBE_TIMEOUT_SECONDS` is 2 s.

| host | typical probe | charged |
|---|---|---|
| local ollama, nothing resident | ~1 ms | no: re-asked every iteration while the book is a guess |
| ollama not started yet (`ECONNREFUSED`) | ~1 ms | no: learned once it starts |
| a slow remote or proxy, answering anything | 250 ms – 1.8 s | yes: at most `1 + REASK_LIMIT` probes per session |
| black-holed or silent host | 2 s timeout | yes: the same bound |

What the probe answered is still typed, for what it means rather than for what it costs:
`Provider::WindowProbe.resident(n)` when `/api/ps` names a runner for the model, `NONE_RESIDENT`
when the server answered without one (no runner, a non-2xx, a body that is not ollama's) or the arm
has no runners to ask, and `UNREACHABLE` when nothing answered — a refused connection or a timeout
(`Faraday::ConnectionFailed`/`TimeoutError` as the cause), or an `--api-base` no request can be
built for. Faraday gives a refusal and a connect timeout the same class, `ConnectionFailed`; their
own causes differ (`Errno::ECONNREFUSED` against `Net::OpenTimeout`), and so does their cost, which
is what the charge reads.

"Nothing resident" stays re-askable because the runner can load on any later turn — evicted by a
summarizer on another model, re-keyed by a sibling command — and a session launched during a
reload that stopped asking divided by 8,192 for its whole life while ollama served 32,768.

A window that is still a guess is marked on both surfaces that show occupancy: the HUD reads
`ctx:~61%` and the prompt line `ctx ~61%`, from the state feed's `window_guessed` field.

## Running the integration specs

The `:ollama` specs (`spec/integration/provider/ollama_spec.rb`) are gated exactly
like `:integration`: excluded by default, opted in with `LAIN_OLLAMA=1`. When the
server is down or `qwen3:4b` is not pulled they **skip with a message** rather than
fail — a missing local server is an environment gap, not a lain regression.

```bash
# Default run: :ollama excluded, localhost blocked (proven by the guard examples
# in spec/support/ollama_tag.rb):
bundle exec rspec

# Opt in (needs `ollama serve` + `ollama pull qwen3:4b`):
LAIN_OLLAMA=1 bundle exec rspec spec/integration/provider/ollama_spec.rb

# Point at a remote server:
LAIN_OLLAMA=1 OLLAMA_API_BASE=http://box:11434 bundle exec rspec \
  spec/integration/provider/ollama_spec.rb
```

Three layers run under `LAIN_OLLAMA=1`:

1. **Smoke** — a plain `/api/chat` round trip; asserts the Response contract holds
   (content blocks are string-keyed Hashes, `stop_reason` normalized to `:end_turn`,
   `usage` populated from `prompt_eval_count`/`eval_count`).
2. **Determinism probe** — one warm-up call, then N=3 seeded `temperature: 0` runs;
   asserts the three texts are identical. See below.
3. **End-to-end** — a real `Agent` over `Provider::Ollama` + `EchoTool`; one task
   drives a tool call, the result lands in one user turn (gate 2), the run settles
   (gates 4/5).

## Determinism: the honest version

`seed` + `temperature: 0` is the documented recipe, but it is **necessary, not
provably sufficient** (`references/ollama/api-chat.md`, "Determinism" section):

- At `temperature: 0` the sampler is greedy (always the top logit), so the `seed`
  is a no-op — determinism comes from greedy decoding, not the seed.
- GPU floating-point non-associativity and the batch size a request lands in (shaped
  by concurrent load) can perturb the argmax token even under greedy decoding.
- **First-run-after-load divergence** (Ollama issue #5321): the first completion
  after a model loads can differ from runs 2+, which are stable among themselves.

The probe is built to the *reliable* regime: it warms the model with one discarded
call, then measures three runs within that same warm load generation. If the three
still diverge on your hardware, that is a real finding — the spec pins whatever IS
true and this section must be updated to record it. **Do not treat `temperature: 0`
as a mathematical guarantee**; treat it as high-probability, same-machine,
same-build, warm-load reproducibility. A false determinism claim would poison every
bench conclusion built on this arm.

> **Rehearsed 2026-07-15** against a local server with `gemma4:e4b` (qwen3:4b was
> not pulled): warm-up + 3 measured `temperature: 0` seeded runs were all four
> byte-identical, and the tool-call E2E layer round-tripped (echo called, one
> tool_result user turn, run settled `done`). The probe's design holds live.
>
> **Measured with qwen3:4b on Joel's hardware:** _(to be filled in from the first
> live `LAIN_OLLAMA=1` run — record whether the three warm runs were identical,
> and if not, the weaker invariant that held.)_
