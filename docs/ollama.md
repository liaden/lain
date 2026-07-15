# Running the Ollama bench arm

`Provider::Ollama` gives the bench a free, local, temperature-0 arm over Ollama's
native `/api/chat` (NDJSON streaming + non-streaming). It exists to be an
exploration target on the "Provider / model" axis and a *determinism oracle* for
tests — but read the [Determinism](#determinism-the-honest-version) section
before you trust the second half of that sentence.

The provider itself is documented in `lib/lain/provider/ollama.rb`; the wire
format and its quirks are distilled in `references/ollama/`. This file is only
the operational how-to.

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
