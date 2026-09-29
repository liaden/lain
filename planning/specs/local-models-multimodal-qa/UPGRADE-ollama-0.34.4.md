# Ollama 0.32.12 → 0.34.4, measured 2026-09-26

Both builds are installed side by side and share the model store:

| | path | env script |
|---|---|---|
| old | `/mnt/nvme/opt/ollama-0.32.12` (keeps `rocm_v7_2`) | `/mnt/nvme/opt/ollama-env-0.32.12.sh` |
| new | `/mnt/nvme/opt/ollama-0.34.4` (vulkan + cuda, **no rocm**) | `/mnt/nvme/opt/ollama-env.sh` (the default) |

Switching is one file: source the other env script and restart `ollama serve`. There is no systemd unit on
this box — that is why `sudo systemctl start ollama` fails. Note `~/.local/opt/ollama/bin/ollama` is a stale
**0.32.1** client; the env script's `PATH` is what selects the right build.

## The headline: 0.34.4 is ~25% FASTER at prefill — and a first measurement said the opposite

**Corrected 2026-09-26.** The first 0.34.4 speed runs showed prefill roughly halving, and that was reported
as a regression. It was **GPU contention**: a game was running on the card during those runs. Re-measured
back to back on an idle GPU, with the same harness, same flags and the same two models:

| idle GPU | metric | 0.32.12 | 0.34.4 |
|---|---|---|---|
| qwen3:4b | prefill tok/s | 3,169 / 3,173 | **3,958 / 3,983** (+25%) |
| qwen3:4b | decode tok/s | 150.8 | 150.2 (level) |
| qwen3:4b | load s | 4.4 | 4.3 |
| laguna-xs-2.1 | prefill tok/s | 2,733 / 2,775 | **3,467 / 3,525** (+27%) |
| laguna-xs-2.1 | decode tok/s | 126.8 | 129.2 (level) |
| laguna-xs-2.1 | load s | 21.0 | 27.5 (slower to load) |

The contended figures, kept for the record: qwen3:4b prefill 1,721 / 1,576 / 1,644 / 1,627 and decode
~135 — a ~60% prefill loss and ~11% decode loss purely from sharing the GPU.

**Two lessons, both worth more than the upgrade itself:**

1. **A background GPU consumer can look exactly like a build regression**, and it survived two "independent"
   repeat runs because the contention persisted across them. Repetition proves stability, not validity.
2. **The probe harness has no guard for this.** It records `contended` for *another ollama model* only —
   nothing sees a game, a compositor or a browser on the card. Any future probe run should sample
   `/sys/class/drm/card1/device/gpu_busy_percent` before and during, and refuse to score a run that started
   above a few percent. Until then, "was anything else using the GPU?" is a question the raw rows cannot
   answer. **The 0.32.12 tables in `REPORT-0.32.12.md` inherit this weakness**: nothing rules out contention
   during them either, and same-build decode moved 150.8 vs 161.4 between two days, about ±7%.

`num_batch` is still honoured on both builds (`-b 2048 -ub 2048` appears in both launch lines when the
request asks), so the flag policy is unchanged. Separately, ollama launches `llama-server` with **`-b 1024`**
when no `num_batch` is sent, not the `-b 512` that `docs/providers/ollama.md` and `DEBUGGING_OLLAMA.md`
describe — the documented default is stale on both builds, though the "always send 2048" policy stands.

## What the upgrade fixes

- **The `eval_count` anomaly is gone.** On 0.32.12 a `format` + thinking request reported `eval_count 40`
  against ~1.5k characters of thinking. On 0.34.4 the same probe reports **679** with 1,563 thinking
  characters — thinking is now counted. This removes the "cost meter under-counts 10–100x" hazard and
  supports the reading that the old number was upstream
  [#17274](https://github.com/ollama/ollama/issues/17274)'s silent discard, not a deliberate exclusion.
- **`/api/show` now advertises thinking controls**: `"thinking": {"values": [true], "default": true}` on
  qwen3:4b. This is the per-model capability the QA ladder would rather read than guess (0.34.3).

## What the upgrade does NOT fix

- **`format` + `tools` still silently drops the tool call.** Re-ran wire check (a) on 0.34.4: `tool_calls:
  null`, no error, and a confident fabricated answer that even narrates "from the file content read by the
  tool call". Upstream [#13750](https://github.com/ollama/ollama/issues/13750) is still open. **lain's
  refusal guard (branch `local-models-quick-wins`) is still required.**
- **`qwen3-coder:30b` still emits `<function=read_file> <parameter=path> … </parameter> </function>` as
  text**: 16/32 native tool calls on 0.34.4, the same 50% as on 0.32.12. This is the model's template in the
  ollama library, not the server version. Fix or replace the modelfile before using it with tools.

## Wire shapes lain depends on: all unchanged on 0.34.4

Checked against the four silent-degradation risks in the provider:

| read | on 0.34.4 |
|---|---|
| over-window 400 → `{"error": "{\"error\":{… \"type\":\"exceed_context_size_error\", \"n_prompt_tokens\":6011, \"n_ctx\":2048}}"}` | byte-identical shape, same doubly-encoded body |
| `truncate: false` honoured | yes — refuses; **without** it the server silently cut a 6,011-token prompt to 1,026 |
| `/api/ps` → `models[].context_length`, `models[].model` | both present (`context_length: 16384`, `model: "qwen3:4b"`) |
| `/api/show` → `model_info["general.architecture"]` + `<arch>.context_length`, 404 for unknown model | all present (`qwen3`, 262144), still 404 |

`capabilities` is still `["completion","tools","thinking"]` for qwen3:4b, so the recorded cassette's pinned
value would survive a re-record.

## Two live spec failures — pre-existing, NOT upgrade regressions

`LAIN_OLLAMA=1 bundle exec rspec --tag ollama` on 0.34.4: 7 examples, 2 failures.

1. `spec/lain/oracle/secret_read_spec.rb:240` — `UndecodableAnswer: unexpected end of input`.
2. `spec/integration/provider/ollama_spec.rb:106` — the live tool-call turn saw no `tool_use` block.

**Control: both also fail on 0.32.12** (the oracle one twice out of two, the tool-call one once out of two).
So the upgrade did not cause them. Mechanism found while probing:

- The oracle asks qwen3:4b with `Oracle::Model::DEFAULT_MAX_TOKENS = 1024` and thinking left ON. qwen3:4b
  spends 3,900–8,000 characters thinking before answering, so the ceiling is sometimes consumed before any
  `content` exists — the same "answer is in the thinking, missing from the content" failure the probes found
  on review and QA. An oracle over a thinking model wants `think: false` or a much larger ceiling.
- Separately, one probe returned a schema-valid `"confidence": 90` where the spec asserts 0.0–1.0. Schema
  validity is not range validity; the prompt or the schema should bound it.

Neither is caused by the version, but both are real and worth a card.

## Outcome

**Staying on 0.34.4** (the user's call, once contention explained the apparent regression): it is faster at
prefill, level at decode, fixes the token accounting, and adds the `/api/show` thinking field. No ROCm
experiment is needed — there is no regression to chase.

The full probe suite is being **re-measured on 0.34.4** so the tables describe the build actually in use. The
0.32.12 rows are preserved in `model-probes/raw-0.32.12/`, their tables in `model-probes/scored-0.32.12/`, and
the write-up in `model-probes/REPORT-0.32.12.md`.

Still open, and not version-related:
- lain's guard against `format` + `tools` (parked on `local-models-quick-wins`) is still required.
- `qwen3-coder:30b`'s template emits tool calls as text; fix or replace the modelfile.
- The oracle's 1,024-token ceiling over a thinking model, and the `confidence: 90` range bug.
- `docs/providers/ollama.md` and `DEBUGGING_OLLAMA.md` still describe 0.32.1/0.32.12 and a `-b 512` default.

## Measured comparison, 0.32.12 vs 0.34.4

8 of 9 models re-measured on 0.34.4 (2026-09-26; qwen3.8 is partial — speed, tools, review, plan done, QA
5 of 24 rows, vision missing — an out-of-memory kill stopped it). Old tables: `model-probes/scored-0.32.12/`.

### Speed (prefill tok/s, cold ~7.6k prefix)

| model | 0.32.12 | 0.34.4 | |
|---|---|---|---|
| qwen3:4b | 3,207 | 3,956 | +23% |
| lfm2.5 | 6,971 | 7,696 | +10% |
| qwen3-coder:30b | 2,302 | 3,141 | +36% |
| laguna-xs-2.1 | 2,732 | 3,369 | +23% |
| north-mini-code-1.0 | 2,114 | 2,915 | +38% |
| ornith-1.5:9b | 2,682 | 2,556 | -5% |
| muse-glimmer:30b | 813 | **158** | **-81%** |
| qwen3.8:27b | 702 | **196** | **-72%** |

**Corrected 2026-09-28.** Those last two rows were first blamed on memory pressure and marked "discard".
Re-measured alone on an idle GPU with 12 GiB free, they **reproduce** (muse 158/160, qwen3.8 196/193). It is
a real 0.34.4 regression, and it splits cleanly by architecture:

| improved on 0.34.4 | regressed on 0.34.4 |
|---|---|
| qwen3-coder:30b (moe, 128 experts) +36% | qwen3.8:27b (**dense**, 27.3B) **-72%** |
| north-mini-code-1.0 (cohere2moe, 128) +38% | muse-glimmer:30b (**dense**, 27.9B) **-81%** |
| laguna-xs-2.1 (laguna, 256) +23% | |
| qwen3:4b (dense but small) +23%, lfm2.5 +10% | |

Every MoE model gained; the only two large DENSE models lost ~4x. Small models were unaffected or gained, so
it is size-and-density, not density alone — consistent with a llama.cpp/Vulkan change in the dense matmul
path. Decode moved much less (qwen3.8 66 -> 56, muse 39.5 -> 39.0).

**Why it matters more than the percentages suggest:** `qwen3.8:27b` is the best reviewer measured AND (now
confirmed) the cleanest vision model. At 196 tok/s a 7.6k-token review prompt spends ~39 s in prefill alone,
against ~11 s on 0.32.12 — on the single most expensive rung of the QA ladder.

### The one real regression: 0.34.4 stops parsing lfm2.5's reasoning

| lfm2.5 | 0.32.12 | 0.34.4 |
|---|---|---|
| QA AC accuracy | 78% | **0%** (8/8 items unanimous-and-wrong) |
| code reviews parsed | 4/4 | **0/4** |
| thinking extracted | 96–97% of tokens | **0 characters** |

```
0.32.12  content: {"verdict": "pass", "evidence": "The curl command returned HTTP 422 ..."}
0.34.4   content: <think>\nWe need to decide if acceptance criterion is satisfied. ...
```

The reasoning now arrives as literal `<think>` text INSIDE `content`, so no answer parses. The model did not
get worse; its output stopped being separated. **lfm2.5 is unusable on 0.34.4 until its template/parser is
fixed** — and nothing errored.

### Quality elsewhere: stable

qwen3.8 code review 4/4 bugs and 0 false alarms on both builds; laguna-xs 3.25/4 with precision 93% → 100%;
qwen3-coder recall 44% → 56%; laguna and north QA 100% on both; qwen3-coder tool calls 53% → 50% (still
emitting XML text). Two shifts worth watching: **ornith's vision false alarms went 0/8 → 4/8 clean pages**
(it still named all 20 real defects), and gemma4 improved 8/20 → 10/20 named.

## Upstream issue map (searched 2026-09-28; recorded here, nothing filed or commented)

Every finding below already has an OPEN upstream issue except the last two.

| finding | issue |
|---|---|
| qwen3-coder emits `<function=…>` as text, `tool_calls` empty | [#18530](https://github.com/ollama/ollama/issues/18530) — our exact symptom incl. the orphan `</tool_call>`; [#17353](https://github.com/ollama/ollama/issues/17353) closed as its duplicate; [#18421](https://github.com/ollama/ollama/issues/18421) is a sibling parser bug |
| a thinking model burns `num_predict` and emits no `content` | [#17978](https://github.com/ollama/ollama/issues/17978) — matches our review/QA truncations AND lain's `Oracle::SecretRead` failure |
| `format` + `tools` silently drops the tool call | [#13750](https://github.com/ollama/ollama/issues/13750) — still open, self-hosted only, hence lain's guard |
| `eval_count 40` with content discarded (0.32.12) | [#17274](https://github.com/ollama/ollama/issues/17274) — same number; fixed for us by 0.34.4 |
| `think:false` moves reasoning into `content` | [#10964](https://github.com/ollama/ollama/issues/10964) |
| gemma4 hallucinating audio transcription with thinking on | [#16584](https://github.com/ollama/ollama/issues/16584) — corroborates the audio research |
| trailing content dropped at end of stream | [#18009](https://github.com/ollama/ollama/issues/18009) — `thinking.Parser` never flushes |
| qwen3.8 `think: "high"`/`"max"` silently run the default | [#18632](https://github.com/ollama/ollama/issues/18632) — read `/api/show` thinking levels with care |
| 0.34.4 runner can wedge until unload | [#18685](https://github.com/ollama/ollama/issues/18685) — near our qwen3.8 instability (ours crashed) |
| **lfm2.5 reasoning unparsed on 0.34.4** | **no upstream issue found** |
| **qwen3.8 runner holding 7.5 GiB host RAM** | **no match** (nearest [#18620](https://github.com/ollama/ollama/issues/18620) is Apple/MLX only) |

**The pattern is the lesson.** Ollama's failure mode for a parse problem is *silence*: empty `content`, empty
`tool_calls`, `finish_reason: "stop"`, HTTP 200. Six separate findings here are the same shape. A QA ladder
that trusts a field it did not verify will score a parse failure as a model verdict — so lain should check
that a structured reply actually parsed, and treat "parsed nothing" as its own outcome, never as a pass.
