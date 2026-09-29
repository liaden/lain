# What the discovery work means for lain's code

Written 2026-09-28, from `research-media-qa-tiers.md`, the two spikes, `model-probes/REPORT-0.32.12.md`,
`UPGRADE-ollama-0.34.4.md` and `NOTE-thp-and-offload.md`. Nothing here is committed; the two small fixes
already written sit on branch `local-models-quick-wins`.

## The one idea underneath most of it

**Ollama's failure mode is silence.** Six independent findings are the same shape — HTTP 200,
`done_reason: "stop"`, empty `content` or empty `tool_calls`, and a plausible-looking turn that contains
nothing:

| observed | cause |
|---|---|
| `format` + `tools` → confident fabricated JSON, no tool call | upstream #13750, unfixed on 0.34.4 |
| qwen3-coder → `<function=…>` as prose, 50% of calls | upstream #18530, parser gap |
| lfm2.5 on 0.34.4 → `<think>` inside `content`, 0% QA accuracy | no upstream issue; template regression |
| qwen3:4b / ornith / north-mini → budget consumed thinking, empty answer | upstream #17978 |
| `eval_count 40` against 1.5k characters of thinking (0.32.12) | upstream #17274, fixed in 0.34.4 |
| trailing content dropped at end of stream | upstream #18009 |

lain currently trusts these fields. **A blank answer must become a typed outcome, never a verdict, never a
pass, and never an empty turn that flows on as if the model had spoken.** That single rule touches the
provider, the oracle, and the QA ladder, and it is the highest-value change in this document.

## 1. Land what is already written (small, parked on `local-models-quick-wins`)

- **`Ollama::Encoding` refuses `format` + `tools`** (`07a5e161`). Re-verified on 0.34.4: still silently drops
  the call. Includes the one fixture that used the pair deliberately.
- **Three cloud context-window rows** (`8d2ce30a`): `glm-5.3`, `glm-5.3-flash`, `deepseek-v4.1-flash`, all
  1M, off the 8,192 guess.

## 2. New cards the discovery forces

### 2.1 A blank or unparsed reply is a typed outcome (the rule above)
- `Provider::Ollama::Decoding`: a turn with no content, no tool calls and no thinking is not a normal
  `end_turn`. Surface it — `done_reason: "length"` especially — so callers can branch. Today it decodes to a
  blank assistant turn.
- `Oracle::Model`: `UndecodableAnswer` already raises, but the *cause* is unclassified. Distinguish "the
  model was cut off" (retryable with a bigger budget or `think: false`) from "it answered nonsense".
- QA ladder: "could not parse" is a finding of its own, never a pass. The spike already refuses a finding
  without evidence; this is the same discipline one level up.

### 2.2 The oracle's budget is wrong for a thinking model
`Oracle::Model::DEFAULT_MAX_TOKENS = 1024`, thinking left ON, against qwen3:4b, which spends 3.9k–8k
characters thinking. The live spec fails on BOTH ollama builds for this reason — pre-existing, not a
regression. Options, cheapest first: send `think: false` on the ollama oracle path; raise the ceiling;
retry once on an empty answer with a larger budget. Also seen: a schema-valid `"confidence": 90` where the
spec asserts 0.0–1.0 — schema validity is not range validity, so the answer needs a range check.

### 2.3 Per-model capabilities, read rather than assumed
`/api/show` reports `capabilities` (`completion`, `tools`, `thinking`, `vision`) and, since 0.34.3, a
`thinking` block with available levels. **Nothing in `lib/` consumes `capabilities` today** — the recorded
cassette pins it as a fixture only. Needed by:
- the image work: never offer `screenshot` to a model without `vision` (a non-vision model returns HTTP 400
  for image data, and the spike already found this);
- the QA ladder: pick a thinking level rather than guess (mind upstream #18632 — `high`/`max` silently run
  the default on qwen3.8).

### 2.4 Residency-aware scheduling (new dimension, entirely from the probes)
Measured on this box: ~21.2 GiB usable VRAM; a 30B reload costs **~16–20 s**, and the reload also throws away
the prefix cache, which is worth about as much again (20.4 s cold vs 0.5 s warm on an 11k prompt).
- **No two large models are ever co-resident.** laguna 19.3, north 18.0, qwen3-coder 18.3, qwen3.8 16.5 GiB.
  Only some large+small pairs fit (qwen3.8 + gemma4 = 20.0 ✓; north + qwen3:4b = 21.9 ✗).
- **`EpicDriver::Run`'s `WIDTH = 2` buys nothing on a local-only fleet**, and can cost ~20 s per alternation
  if the two actors want different models. Width should be a function of where the model runs.
- **Batch by model, not by task.** The QA spike's breadth-first ladder (one swap per rung) is right; the epic
  gate should group every issue needing the same reviewer into one pass.
- **`keep_alive` should be lain's to set**: `-1` to pin a small always-resident utility model, `0` to release
  a large one the moment its batch ends. Ollama's 5-minute default silently unloads between phases.

### 2.5 Prompt-prefix stability is now a LOCAL performance invariant too
With one model resident, interleaving agents costs only the **divergent tail** — provided the shared prefix
is byte-identical (measured: a 5k shared system prefix survived an agent switch; 2.04 s versus 3.66 s cold).
This is the same constraint `Context#render`'s purity already enforces for Anthropic's prompt cache, so it is
a convergence, not a second mechanism — but it wants an audit: anything per-agent that renders EARLY in the
request (`Workspace` in particular) moves the first differing byte forward and re-prefills everything after
it. Open question worth answering before the QA chunk: where does `Workspace` land in the rendered order?

### 2.6 `num_batch` on the ollama path
Policy is "always send 2048", but it is opt-in through the run profile, and a runner was observed serving at
`-b 1024`. Ollama's own default is **1024** on both builds (not the `-b 512` the docs still claim), and the
measured gain is large on big prompts. Consider defaulting it for the ollama arm rather than leaving it to a
profile flag.

## 3. Changes to the QA spike's design, before it becomes a plan

The spike was designed before the models were measured. Four corrections:

1. **The cheap rung is not a 4B model — but for reliability, not for danger.** Verified across BOTH builds
   (n=32 per model): `laguna-xs-2.1` and `north-mini-code-1.0` score **32/32 on both**; `qwen3:4b` scores
   27/32 on both, and every one of its errors is an **unparsed** answer (5 on 0.32.12, 3 on 0.34.4), never a
   wrongly-passed violation. So a 4B rung is not unsafe, it is unreliable — and its failures are detectable,
   which is what makes them escalatable rather than silent.
2. **Two models wrongly PASS real violations, and they do it unanimously.** Corrected 2026-09-28 — an earlier
   draft of this list named qwen3:4b among them, which the rows do not support.

   | model | wrongly passed a true violation | 0.32.12 | 0.34.4 |
   |---|---|---|---|
   | `lfm2.5` | 6 of 16 | yes | (unparsed throughout, template broken) |
   | `qwen3-coder:30b` | **4 of 16, identical on both builds** | yes | yes |
   | laguna, north-mini, ornith, qwen3.8, qwen3:4b | 0 | — | — |

   On `q6_sort_bad` (a real violation) `lfm2.5` and `qwen3-coder` each answered "pass" on **4 of 4 runs** —
   confident, unanimous, not truncated. **Repeated sampling of one model is not independent evidence**, so
   `unanimous-pass` must mean agreement across *different* models, at least one of them from the strong tier.
   `qwen3-coder` must never hold a QA verdict: its 4-of-16 miss rate reproduces exactly across builds.

   **Scorer bug this exposed:** `analyze.py`'s "unanimous-and-wrong items" column counts an **unparsed**
   answer as a wrong verdict, which is how qwen3:4b got mislabelled here. That is the same conflation §2.1
   says to eliminate in lain — fix it in the harness too, or the next reader repeats my mistake.
3. **`done_reason: "length"` escalates to a DIFFERENT model**, never the same model with a bigger budget.
   Retested at 12,288 (on 0.32.12 only — **not yet re-verified on 0.34.4**): only qwen3:4b converted budget
   into an answer, and that answer found 6% of the bugs; ornith and north-mini still hit the cap on 3 of 4
   runs.
4. **The media rung must verify image delivery itself.** With the image withheld, ornith invented a heading
   and a number in the same confident tone; gemma4 refused. Echo a digest or plant a known token — never
   trust the model to notice a missing image.

Model selection, on current evidence (0.34.4): **qwen3.8:27b** is the strongest on every quality axis
measured — code review 4/4 with zero false alarms, plan review 3/3, QA 100%, and vision 15/15 named with
**0/6 false alarms** — and also the slowest to prefill and the only one that crashed a runner.
**laguna-xs-2.1** is the value pick. **ornith-1.5:9b** regressed on clean pages (0/8 → 4/8 false alarms on
0.34.4) and should not gate alone. **lfm2.5 is unusable on 0.34.4** and **qwen3-coder must not be handed
tools** until its template is fixed.

## 4. Docs that are now stale

- `docs/providers/ollama.md` and `DEBUGGING_OLLAMA.md`: the install is 0.34.4 (0.32.12 kept for rollback);
  the `-b 512` default is really 1024; add the dense-vs-MoE prefill split and the GPU-contention lesson.
- `lib/lain/provider/ollama/encoding.rb` and three spec comments cite "0.32.12" for behaviour re-verified on
  0.34.4 — the over-window 400 body and `truncate: false` are unchanged, so those comments only need their
  version updated, not their claims.

## 5. Suggested order

1. The two parked fixes (they are written and green).
2. §2.1 blank-reply rule + §2.2 oracle budget — smallest change with the largest correctness payoff, and it
   makes the two failing live specs pass for the right reason.
3. `/create-plan` for images (4 waves from `SPIKE-images.md`), including §2.3 vision capability.
4. `/create-plan` for QA (role, skill, `/qa`, epic gate), with the four §3 corrections folded in.
5. §2.4 residency scheduling — needs a decision on whether per-role model choice is its own chunk.
6. Docs.
