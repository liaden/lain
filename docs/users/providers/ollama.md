# Ollama

`--provider ollama` runs lain's chat on a model served by Ollama: free, local, and with no API key.
It talks to Ollama's native `/api/chat` with streaming. The same provider also reaches Ollama Cloud
(`--provider ollama-cloud`, see the [provider overview](README.md)).

The provider itself is documented in `lib/lain/provider/ollama.rb`; the wire
format and its quirks are distilled in `references/ollama/`. This file is the
operational how-to: install, run, what the provider can and cannot do, and how to tune the server.

## Install and pull the model

```bash
# 1. Install Ollama (https://ollama.com/download), then start the server:
ollama serve            # serves http://localhost:11434 by default

# 2. Pull the default model the provider targets:
ollama pull qwen3:4b
```

`qwen3:4b` is `Provider::Ollama::DEFAULT_MODEL`, the current best small
tool-calling model for a free local run. If `4b` will not emit tool calls
reliably for your prompts, use the bigger sibling `qwen3:8b`.

## Driving it from the CLI

```bash
exe/lain --provider ollama                       # defaults to qwen3:4b
exe/lain --provider ollama --temperature 0 --seed 42
exe/lain --provider ollama --model qwen3:8b
exe/lain --provider ollama --api-base http://otherhost:11434
```

`--temperature` and `--seed` ride `Request#extra` into Ollama's `options` object;
`--temperature 0` is the most repeatable setting (see [Determinism](#determinism)). `--api-base` overrides the localhost
default. Local Ollama needs no API key. The library reads no environment variable for the server
address: the base is the `--api-base` flag or the `Provider::Ollama.new(api_base:)` argument.

## Capabilities

`streaming`, `thinking`, `structured_output`. `cache_profile` is
`CacheProfile::NO_CACHING`.

Ollama has no `prompt_caching` and no `strict_tools`, so it is the provider that
most often triggers a capability degrade. A `Context::CacheBreakpoints` combinator
declares `requires :prompt_caching`, so under `:degrade` it no-ops here and the
degradation lands in the Journal; under `:strict` it raises.

## Ollama can power compaction, on any provider

The eager tool-result summarizer follows the chat's provider by default, so a Claude chat
summarizes on Claude and an Ollama chat on Ollama. Beside a Claude chat,
`--summarizer-provider ollama` sends summaries to a local Ollama model: a summary fires once
per large tool result, off the turn's critical path, and paying frontier-model tokens to
compress a tool result can cost more than resending it.

`ollama serve` and `ollama pull qwen3:4b` are worth running for that. Without them, a local
summarizer fails inside `Oracle::Eager`'s task boundary, nothing raises, and the
compacting turn renders an elision line instead of a summary. See the
[README](../compaction.md) for the 3 tiers.

`--summarizer-provider` and `--summarizer-model` point that tier anywhere, independently of
`--provider`. `--api-base` moves whichever of the 2 is on Ollama.

## Serving performance

The variables above configure lain; they say nothing about how fast the server answers.
That is measured in [`docs/devs/debugging-ollama.md`](../../devs/debugging-ollama.md), and ollama's own
defaults are wrong for this workload. The figures below come from the development machine (an RX 7900 XTX);
the KV-cache and ROCm-vs-Vulkan figures were measured on ollama 0.32.12 and the rest on 0.34.4.

### num_batch

`num_batch` needs no flag any more. With no `num_batch` in the request, ollama launches
llama-server at `-b 1024`, probed directly off the launch line on both 0.32.12 and 0.34.4. Either value
undercuts llama.cpp's own default of 2048, and no server-side setting raises it.

So `Lain::CLI::Backend` sends 2048 on every ollama chat, whether or not `--num-batch`
(`$LAIN_NUM_BATCH`) was typed. The flag and the env var override that default.

`--num-ctx` (`$LAIN_NUM_CTX`) for context length is the one knob that stays opt-in: unset, it
never reaches the request, while `num_batch` and the generation cap (`num_predict`) always do.

Both runner knobs belong to the run profile, which every model-calling command declares. They are
recorded in the session header beside the provider and the api base, and re-used by `--resume`,
`--fork`, `/fork` and `/btw`, so a forked session runs the runner the original ran.

On the RX 7900 XTX, the `ollama` default `num_batch` measured as costing up to 3x decode and 8x
prefill (`qwen3-coder:30b` prefill: 340 to 2,222 tok/s, 6.5x, going from `num_batch=512` to
`2048`). The effect depends strongly on the model (1.1x to 2.7x on decode across 4 models), and a
second measurement found 1.31x on the same model. The 2 figures are unreconciled, so quote neither as
the number; the dated entries in the developer notes hold both. Prefill is what a turn carrying a large
`tool_result` pays, so you feel it either way.

### keep_alive

`keep_alive` is residency, and it is the one knob whose wire type matters. Ollama unloads a
model 5 minutes after its last request. `--keep-alive` overrides that: `-1` pins it resident, `0`
releases it the moment the turn is answered, and `5m` or `90s` is a duration.

Pinning avoids a reload, and a reload costs twice. Loading a 30B model takes 16 to 20 s on the development machine,
and the reload discards the prefix cache, worth about as much again (20.4 s cold against
0.5 s warm on an 11k prompt). With about 21.2 GiB usable, no 2 models of 16 GiB or more are
co-resident, so pinning one is also a decision not to run another.

Three facts about `keep_alive` cannot be guessed from the field. All were probed against 0.34.4
on the development machine:

1. A string is parsed by Go's `time.ParseDuration`, which demands a unit. `"-1"` is
   `HTTP 400 {"error":"time: missing unit in duration \"-1\""}`. The number `-1` means
   forever, and `"-1s"` is the string that works. `"0"` is the one unitless string Go accepts.
   So `Lain::CLI::Backend` coerces: an integer spelling reaches the wire as a JSON number, a
   duration travels as the String it was, and anything else is refused by name before the request
   is built, so it never 400s mid-turn.
2. A request that carries no `keep_alive` does not disturb an existing pin. The runner keeps
   its stored duration and re-stamps the expiry from it; only a request that carries the
   field changes it. A summarizer or secret-read tier sharing the chat's runner therefore does
   not need to repeat the chat's `keep_alive`. `num_batch` and `num_ctx` differ: they key the
   runner by identity and reload it when they differ.
3. The pin outlives the lain process. It is server state: after lain exits, `/api/ps` still
   reports the model resident until something releases it. For a 30B that is about 18 GiB of
   VRAM held indefinitely. `ollama stop <model>`, or any request with `keep_alive: 0`, releases it.

### KV cache type and GPU backend

- The KV cache type trades context for speed. `q8_0` gives about 64k usable context and `f16`
  about 32k, but at 32k `f16` is 13% faster. Pick by the context the task needs.
- Use Vulkan on the development machine (an RX 7900 XTX). It decodes about 30% faster than ROCm and starts reliably, where ROCm
  cannot bring some models up at all.

## Two context numbers

Ollama publishes 2 different context lengths, and only one is a denominator. `Provider::Ollama`
keeps them behind 2 separate methods, `#context_window_tokens` and `#trained_context_tokens`,
because mixing them up is a silent 8x error.

- **`/api/show`'s `model_info.<arch>.context_length`** is the GGUF's trained maximum:
  262,144 for `qwen3-coder:30b`. It is always available and is never a denominator. Divide
  occupancy by it and occupancy under-reports 8x, so compaction never fires, which is worse than
  the crash compaction exists to prevent. Its one legitimate use is refusing a `--num-ctx`
  no runner could ever serve.
- `/api/ps`'s per-runner `context_length` is what the loaded runner is actually serving:
  `min(trained, OLLAMA_CONTEXT_LENGTH, per-request num_ctx)`, which is 32,768 on the development machine. Only `/api/ps` states the served figure, so `nil` (no
  resident runner, or an unreachable server) is the ordinary answer and leaves
  `ContextWindow`'s conservative fallback in charge.
- An over-window 400's `n_ctx` is the same served figure, stated by the runner that just
  refused a prompt against it. `Middleware::ResolveWindow` adopts it as an authoritative window
  (`WindowBook::Live#vouch`), which also corrects a book that probed a stale, smaller runner
  before the request reloaded it.

  The turn stack cannot see the refused request, but `Middleware::RequestBudget` in the model
  phase can. The refusal it re-raises names the refused request's model, and the vouch lands on
  that model, so a refusal after a `/model` switch leaves the run's `--model` with the answer it
  had.

A caller that sends `num_ctx` owns the `min`. Ollama reloads a runner whose `NumCtx` differs
from the request's (`sched.go`'s `needsReload`). A runner left at 32,768 by `ollama run`, by a
sibling session, or by an earlier turn reports 32,768, while the very next request, carrying an
explicit `num_ctx` of 8,192, is served 8,192. The provider cannot see the request, so the
caller must take the minimum of the reported window and its own flag.

### What the probe costs

The window is asked of `/api/ps` once per agent-loop iteration while it is still a guess. Against a local
server that costs about a millisecond, and with the server down it fails just as fast.

A host that never answers is the case that costs: `--api-base http://10.255.255.1:11434` waits the
full 2 s probe timeout per ask. The budget is therefore charged by what a probe cost. A probe slower
than 50 ms (`WindowBook::Lookup::COSTLY_SECONDS`) spends one of `WindowBook::Live::REASK_LIMIT`
re-asks, so a slow or silent host is probed at most `1 + REASK_LIMIT` times per session. A fast "nothing
resident" or a refused connection is not charged and is re-asked, because the runner can load on any later turn.

A window that is still a guess is marked on both surfaces that show occupancy: the HUD reads
`ctx:~61%` and the prompt line `ctx ~61%`, from the state feed's `window_guessed` field.

The measurements and the probe-result types are in
[`docs/devs/debugging-ollama.md`](../../devs/debugging-ollama.md#window-probe-cost).

## Determinism

`seed` plus `temperature: 0` is the documented recipe for repeatable output, and it is necessary but not
provably sufficient (`references/ollama/api-chat.md`, "Determinism" section):

- At `temperature: 0` the sampler is greedy (always the top logit), so the `seed`
  is a no-op. Repeatability comes from greedy decoding.
- GPU floating-point non-associativity and the batch size a request lands in (shaped
  by concurrent load) can perturb the argmax token even under greedy decoding.
- First-run-after-load divergence (Ollama issue #5321): the first completion
  after a model loads can differ from runs 2 onward, which are stable among themselves.

Treat `temperature: 0` as high-probability, same-machine, same-build, warm-load reproducibility, and never as a
mathematical guarantee. Ollama Cloud output varies between runs even at `temperature 0`
with a fixed seed; see the [provider overview](README.md).
