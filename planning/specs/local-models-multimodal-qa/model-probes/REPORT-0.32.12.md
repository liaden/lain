# Local model probes — COMPLETE (9 of 9 models, 2026-09-25)

All nine models ran. `qwen3:4b` and `lfm2.5` were probed on 2026-09-22; the remaining seven on
2026-09-25 after an out-of-memory kill interrupted the first attempt (`ornith`'s 38 partial rows were
dropped before the rerun — backup in `raw.bak-partial/`). `nemotron-3.5-lightning:30b` was skipped on
purpose: it does not fit in VRAM.

**Read the caveats at the bottom before quoting any number.** These are synthetic single-turn tasks with
n=4 (n=3 for qwen3.8), keyword-scored, on one box.

## Headline

- **`qwen3.8:27b` is the strongest reviewer measured, and it is not close**: 100% recall and 100%
  precision on the planted code bugs, all 3 plan defects every run, 100% tool fidelity. It is also the
  slowest to first token (25.5 s load, 702 tok/s prefill) and it **crashed the runner twice**.
- **`laguna-xs-2.1` is the best value**: 81% recall at 93% precision on code review, 3/3 plan defects,
  100% QA accuracy, for ~1.6k tokens and 14 s per review against qwen3.8's 25 s — but it is a *reviewer*,
  not the implementer it was pulled as (72% tool fidelity).
- **`ornith-1.5:9b` is the vision model to use**: 20/20 defect pages flagged AND correctly named, 0 false
  alarms on clean pages, 4.3 s mean. `gemma4:e4b` named 8/20. `muse-glimmer:30b` matched ornith on
  defects but cried wolf on 3/8 clean pages.
- **`qwen3-coder:30b` cannot be handed tools as configured**: 47% of its calls arrive as
  `<function=read_file>` *text*, not a tool call. That is a chat-template/parser mismatch in this
  ollama build, not a capability gap — and it is silent.
- **Three models produced no review at all at a 6,144-token cap** (qwen3:4b, ornith, north-mini-code):
  100% of the budget went to thinking. Retested at 12,288 the three split: qwen3:4b answers every time
  and is simply **bad at code review** (6% recall, 1.5 false alarms); ornith and north-mini-code still
  hit the cap on 3 of 4 runs. So "ran out of room" hid a weak reviewer in one case and an unbounded one
  in the other two — raising the cap is worth it for qwen3:4b and wasted on the others.
- **A vision model with no image will confabulate.** In wire check (c), ornith invented a plausible
  heading and number when the image was withheld. `gemma4:e4b` instead refused and asked for the
  content. Any image path needs a delivery check that does not depend on the model noticing.

## Method

- Every call goes to native `/api/chat` with `stream:false` and
  `options {num_batch:2048, num_ctx:16384, num_predict:6144}`, plus one residency check at 32768.
  Each call snapshots `/api/ps` before and after. Raw records are in `raw/<probe>.jsonl`, scored detail
  in `scored/*.json`, tables in `scored/tables.md`.
- n = 4 per item: temperature 0.6 with seeds 11, 22, 33, plus one greedy run at temperature 0.
  `qwen3.8:27b` ran n=3 with a 12,288-token cap, because it thinks at high effort by default.
- Fixtures in `fixtures/`: 8 tool tasks over awkward paths; a 152-line diff with 4 planted bugs and 6
  distractors; a 72-line plan with 3 planted defects; 8 QA items (4 pass, 4 subtly fail); 7 Chromium
  screenshots (5 planted UI defects, 2 clean) plus a contact sheet.
- Scoring is automatic keyword/line-window matching, hand-checked for qwen3:4b and for every
  tool-fidelity failure below.

## Speed / residency (num_ctx 16384, num_batch 2048)

| model | load_s (first req) | prefill tok/s (cold prefix, ~7.6k tok) | decode tok/s (512-tok gen) | decode tok/s across all probe requests (mean / min) | VRAM @16k | VRAM @32k | contended |
|---|---|---|---|---|---|---|---|
| qwen3:4b | 7.1 | 3207 / 3213 | 161.4 | 141.5 / 94.2 | 3.9/3.9 GiB | 5.1/5.1 GiB | 4/5 |
| lfm2.5 | 7.6 | 6971 / 7535 | 133.2 | 129.8 / 115.6 | 5.2/5.2 GiB | 5.3/5.3 GiB | 0/5 |
| ornith-1.5:9b | 8.0 | 2682 / 2689 | 101.8 | 100.0 / 96.0 | 5.7/5.7 GiB | 6.0/6.0 GiB | 0/5 |
| gemma4:e4b | 11.4 | 3095 / 3311 | 102.4 | 96.0 / 92.9 | 3.5/3.5 GiB | 3.5/3.5 GiB | 0/5 |
| qwen3-coder:30b | 24.0 | 2302 / 2332 | 107.6 | 109.1 / 98.5 | 18.3/18.3 GiB | 19.2/19.2 GiB | 0/5 |
| laguna-xs-2.1 | 20.4 | 2732 / 2772 | 133.5 | 120.8 / 114.9 | 19.3/19.3 GiB | 19.3/19.3 GiB | 0/5 |
| north-mini-code-1.0 | 19.5 | 2114 / 2152 | 127.1 | 113.3 / 63.1 | 18.0/18.0 GiB | 18.1/18.1 GiB | 0/5 |
| muse-glimmer:30b | 21.5 | 813 / 811 | 39.5 | 37.4 / 37.1 | 15.9/15.9 GiB | 15.9/15.9 GiB | 0/5 |
| qwen3.8:27b | 25.5 | 702 / 717 | 66.1 | 85.9 / 58.6 | 16.5/16.5 GiB | 16.6/16.6 GiB | 0/5 |

## Tool-call fidelity (8 tasks x n runs)

| model | n | tool called | valid args | right tool | exact path/cmd | edit old_string verbatim (2 tasks) | all-correct rate | worst task (all-correct over its runs) | mean eval tok | mean wall s | max wall s |
|---|---|---|---|---|---|---|---|---|---|---|---|
| qwen3:4b | 32 | 100% | 100% | 100% | 100% | 8/8 | 100% | read_v2 4/4 | 687 | 5.4 | 26.5 |
| lfm2.5 | 32 | 100% | 100% | 100% | 94% | 8/8 | 94% | read_v3draft 2/4 | 319 | 2.9 | 11.0 |
| ornith-1.5:9b | 32 | 100% | 100% | 75% | 69% | 4/8 | 69% | run_deploy 0/4 | 74 | 1.1 | 1.6 |
| qwen3-coder:30b | 32 | 53% | 53% | 53% | 53% | 8/8 | 53% | read_v2 0/4 | 49 | 0.7 | 1.5 |
| laguna-xs-2.1 | 32 | 100% | 100% | 72% | 72% | 3/8 | 72% | run_deploy 0/4 | 84 | 0.9 | 1.8 |
| north-mini-code-1.0 | 32 | 100% | 100% | 75% | 75% | 3/8 | 72% | edit_typo_tabs 1/4 | 134 | 1.6 | 4.2 |
| qwen3.8:27b | 24 | 100% | 100% | 100% | 100% | 6/6 | 100% | read_v2 3/3 | 82 | 1.7 | 2.9 |

## Planted-defect code review (4 planted bugs; n runs)

| model | n | parsed | TP mean (worst) /4 | recall | FP mean (worst) | precision | bugs found per run | eval tok mean (max) | think share | wall s mean (max) | truncated |
|---|---|---|---|---|---|---|---|---|---|---|---|
| qwen3:4b | 4 | 0/4 | - | - | - | - | - | 6144 | 100% | 66 | 4 |
| lfm2.5 | 4 | 4/4 | 1.00 (1) | 25% | 1.50 (2) | 40% | BUG3; BUG3; BUG3; BUG3 | 4915 (5472) | 97% | 42 (48) | 0 |
| ornith-1.5:9b | 4 | 0/4 | - | - | - | - | - | 6144 | 100% | 65 | 4 |
| qwen3-coder:30b | 4 | 4/4 | 1.75 (0) | 44% | 0.75 (1) | 70% | BUG3,BUG4; BUG3,BUG4; BUG1,BUG3,BUG4; - | 174 (227) | 0% | 2 (3) | 0 |
| laguna-xs-2.1 | 4 | 4/4 | 3.25 (3) | 81% | 0.25 (1) | 93% | BUG1,BUG2,BUG3,BUG4; BUG1,BUG2,BUG4; BUG1,BUG3,BUG4; BUG1,BUG3,BUG4 | 1610 (2547) | 88% | 14 (22) | 0 |
| north-mini-code-1.0 | 4 | 0/4 | - | - | - | - | - | 6144 | 100% | 98 | 4 |
| qwen3.8:27b | 3 | 3/3 | 4.00 (4) | 100% | 0.00 (0) | 100% | BUG1,BUG2,BUG3,BUG4; BUG1,BUG2,BUG3,BUG4; BUG1,BUG2,BUG3,BUG4 | 1802 (2193) | 80% | 25 (32) | 0 |

## Plan review (3 planted plan defects; n runs)

| model | n | parsed | found mean (worst) /3 | per-defect hits D1/D2/D3 | false alarms mean (worst) | eval tok mean (max) | think share | wall s mean (max) |
|---|---|---|---|---|---|---|---|---|
| qwen3:4b | 4 | 2/4 | 2.50 (2) | 2/1/2 of 2 | 0.00 (0) | 6038 (6144) | 99% | 53 (55) |
| lfm2.5 | 4 | 4/4 | 1.50 (1) | 2/0/4 of 4 | 0.75 (2) | 3790 (5164) | 96% | 30 (42) |
| ornith-1.5:9b | 4 | 2/4 | 3.00 (3) | 2/2/2 of 2 | 0.00 (0) | 5146 (6144) | 97% | 52 (62) |
| qwen3-coder:30b | 4 | 4/4 | 2.75 (2) | 4/3/4 of 4 | 1.75 (3) | 240 (327) | 0% | 2 (3) |
| laguna-xs-2.1 | 4 | 4/4 | 3.00 (3) | 4/4/4 of 4 | 0.25 (1) | 2196 (3314) | 92% | 19 (28) |
| north-mini-code-1.0 | 4 | 0/4 | - | - | - | 6144 | 99% | 91 |
| qwen3.8:27b | 3 | 3/3 | 3.00 (3) | 3/3/3 of 3 | 0.00 (0) | 1761 (2122) | 81% | 23 (28) |

## QA AC verification (8 items: 4 pass, 4 subtle fail; n runs each)

| model | n | accuracy | accuracy greedy (t0) | worst item acc | unsure rate | items unanimous across runs | unanimous-and-wrong items | wrong verdict on a TRUE-FAIL item (missed violation) | eval tok mean | wall s mean (max) |
|---|---|---|---|---|---|---|---|---|---|---|
| qwen3:4b | 32 | 84% | 7/8 | 0% | 0% | 7/8 | q6_sort_bad | 0/16 | 2177 | 17.8 (54.1) |
| lfm2.5 | 32 | 78% | 7/8 | 0% | 3% | 7/8 | q6_sort_bad | 6/16 | 490 | 4.0 (7.1) |
| ornith-1.5:9b | 32 | 97% | 7/8 | 75% | 0% | 7/8 | - | 0/16 | 846 | 9.0 (63.8) |
| qwen3-coder:30b | 32 | 88% | 7/8 | 0% | 0% | 8/8 | q6_sort_bad | 4/16 | 67 | 0.9 (1.1) |
| laguna-xs-2.1 | 32 | 100% | 8/8 | 100% | 0% | 8/8 | - | 0/16 | 594 | 5.1 (20.3) |
| north-mini-code-1.0 | 32 | 100% | 8/8 | 100% | 0% | 8/8 | - | 0/16 | 610 | 5.6 (14.6) |
| qwen3.8:27b | 24 | 96% | 8/8 | 67% | 0% | 7/8 | - | 0/12 | 438 | 6.9 (30.0) |

## Vision / screenshot QA (7 pages: 5 planted defects, 2 clean; n runs each)

| model | n | parsed | defect pages flagged fail | ...and named the right defect | clean pages false alarm | per-page right-defect (v2 overlap/v3 trunc/v4 text/v5 contrast/v7 table) | eval tok mean | prompt tok (image) | wall s mean (max) |
|---|---|---|---|---|---|---|---|---|---|
| ornith-1.5:9b | 28 | 28/28 | 20/20 | 20/20 | 0/8 | 4/4 4/4 4/4 4/4 4/4 | 324 | 1166 | 4.3 (12.1) |
| gemma4:e4b | 28 | 28/28 | 12/20 | 8/20 | 0/8 | 0/4 4/4 4/4 0/4 0/4 | 508 | 446 | 6.1 (8.0) |
| muse-glimmer:30b | 28 | 27/28 | 19/20 | 19/20 | 3/8 | 3/4 4/4 4/4 4/4 4/4 | 434 | 1460 | 12.8 (22.1) |
| qwen3.8:27b | 21 | 20/21 | 14/15 | 14/15 | 2/6 | 3/3 3/3 2/3 3/3 3/3 | 298 | 1111 | 6.9 (29.8) |

## Requests timed while another model was resident

- qwen3:4b: 1 requests with (another model appeared during the request) also resident
- qwen3:4b: 55 requests with gemma4:e4b also resident

## Budget retest at num_predict=12288 (the three models that answered nothing at 6144)

### code review (was 0/4 answered at 6144)

| model | n | parsed | found mean (worst) | recall | false alarms mean (worst) | eval tok mean (max) | wall s mean (max) | hit the 12288 cap |
|---|---|---|---|---|---|---|---|---|
| qwen3:4b | 4 | 4/4 | 0.25 (0) of 4 | 6% | 1.50 (2) | 7732 (8645) | 87 (103) | 0/4 |
| ornith-1.5:9b | 4 | 1/4 | 2.00 (2) of 4 | 50% | 0.00 (0) | 11405 (12288) | 125 (140) | 3/4 |
| north-mini-code-1.0 | 4 | 0/4 | - | - | - | 9754 (12288) | 194 (294) | 3/4 |

### plan review (was 0/4 answered at 6144)

| model | n | parsed | found mean (worst) | recall | false alarms mean (worst) | eval tok mean (max) | wall s mean (max) | hit the 12288 cap |
|---|---|---|---|---|---|---|---|---|
| qwen3:4b | 4 | 4/4 | 2.25 (2) of 3 | 75% | 0.00 (0) | 7692 (9394) | 79 (102) | 0/4 |
| ornith-1.5:9b | 4 | 1/4 | 3.00 (3) of 3 | 100% | 0.00 (0) | 11020 (12288) | 124 (142) | 3/4 |
| north-mini-code-1.0 | 4 | 1/4 | 3.00 (3) of 3 | 100% | 0.00 (0) | 10393 (12288) | 186 (230) | 3/4 |

**Reading it.** The 6,144-cap tables above score these three as "0/4 parsed", which is honest about what a
caller would have received but says nothing about judgement. With the cap doubled:

- **qwen3:4b**: answers 4/4 on both tasks, but finds **0.25 of 4 planted bugs (6% recall) with 1.5 false
  alarms per run** on code review, against a respectable 2.25 of 3 plan defects and zero false alarms.
  The budget was hiding a weak code reviewer, not a good one. Its plan-review showing is real.
- **ornith-1.5:9b**: 1 of 4 answered on each task even at 12,288 (2 of 4 bugs, 3 of 3 plan defects when
  it did answer, no false alarms). It does not converge; it is a vision model.
- **north-mini-code-1.0**: still 0 of 4 on code review at 12,288, and 1 of 4 on plan review (3 of 3 when
  it answered). Its 100% QA accuracy at ~600 tokens is the thing to use it for.

**Consequence for the ladder**: `done_reason: "length"` is a genuine escalation signal, but it must escalate
**to a different model**, not to the same model with a bigger budget. Only qwen3:4b converted extra budget
into an answer, and that answer was poor. A per-rung token ceiling doubles as a per-model fitness test.

## What the tool-fidelity numbers actually mean

Every failure was hand-inspected. They fall into three kinds, and only one of them is the model being bad:

1. **`qwen3-coder:30b`: the call never became a call.** 15 of 32 answers contained
   `<function=read_file> <parameter=path> lib/widgets/frobnicator_v2.rb </parameter> </function>` as
   plain text, with `tool_calls: null`. The intent and the path were right every time. This is the
   model's native call syntax not being parsed into ollama's tool-call shape — a template mismatch,
   and a **silent** one: lain would see an assistant text turn and no effect. Worth a separate check of
   the modelfile/template before judging the model.
2. **`laguna-xs-2.1`, `north-mini-code-1.0`, `ornith-1.5:9b`: read-before-run, scored as wrong.** On
   `run_deploy` ("Run the prod deploy script with --dry-run") all three called `read_file` on
   `scripts/deploy-prod_2.sh` instead of `run_command`. In an agent loop that is **the cautious and
   arguably correct move** — look at the prod script before executing it. The rubric wants the
   single expected call, so it scores 0. Read their 72–75% as "72–75% single-step obedience", not
   "25% wrong".
3. **Genuine misses**: north-mini-code got one `edit_file` `old_string` wrong (the tab-indented
   fixture), and ornith used a wrong path on `run_spec` twice.

qwen3:4b (32/32) and qwen3.8:27b (24/24) were exact on every task, awkward paths included.

## Wire checks

**(a) `format` + `tools` in one request: no error, `format` silently wins, tools ignored.** On qwen3:4b,
both runs returned `tool_calls: null` and schema-valid JSON containing a **fabricated** file line at
confidence 0.95. **This is now guarded in lain** (branch `local-models-quick-wins`): `Ollama::Encoding`
refuses the pair by name.

**(b) With `format` on, `eval_count` looked like it EXCLUDED thinking tokens — but the likelier cause is an
upstream bug.** One format+think request reported `eval_count 40` / `eval_duration 382 ms` against
`total_duration 4,985 ms` and ~1,563 characters of thinking. Upstream
[ollama#17274](https://github.com/ollama/ollama/issues/17274) (open, reproduced on 0.34.0, cause located in
the tool-call parser on `main`) describes generated tokens being **silently discarded** on a parse failure,
reporting exactly **40 completion tokens** with empty content — the same number. So the honest reading is
"tokens were generated and thrown away", not "thinking is excluded from the count". Either way a cost meter
built on `eval_count` under-reports; re-measure on 0.34.4 before building on it.

**(c) `images` on a `role:"tool"` message: CONFIRMED on two models.** The fixture page shows
"Monthly Report — August 2026" and Churned 211, while the prompt's surrounding text says September, so
only a model that really saw the image can answer "August / 211".

| model | image on the tool message | no-image control | image on a following user message |
|---|---|---|---|
| ornith-1.5:9b | "August 2026", 211 — correct | **confabulated**: "Churn Analysis", 873; "Customer Churn Analysis", 1,000 | correct |
| gemma4:e4b | "August 2026", 211 — correct | **refused**: "[Please provide the actual heading text…] I cannot visually see the attached screenshot" | correct |

So the tool-result path works, which is what the image spike's `screenshot` tool depends on. The control
is the finding worth carrying: **ornith invents a plausible answer when the image is missing**, at the
same confident tone as when it is present. A dropped or mis-encoded image is therefore invisible in the
answer, and the QA ladder's media rung must verify delivery itself (echo the digest, or plant a known
token in the page) rather than trust the reply to notice.

## Stability and cost notes

- **`qwen3.8:27b` crashed the ollama runner twice** in 81 requests: `model runner has unexpectedly
  stopped` and `unexpected EOF`, both around the 12k-token cap at 16.5 GiB resident. Anything that
  depends on it needs a retry path, and the crash is not visible as a normal `done_reason`.
- **VRAM**: the 30B-class models sit at 15.9–19.3 GiB at ctx 16k and barely move at 32k
  (laguna-xs 19.3 → 19.3, north-mini 18.0 → 18.1). Only one of them fits at a time against ~22.5 GiB
  usable, which is what makes a ladder that swaps models *per rung* rather than per item the only
  affordable shape.
- **Load costs**: 7–11 s for the small models, 19.5–25.5 s for the 30B class. A rung that swaps models
  four times pays that four times.
- **Prefill is where the big models hurt**: muse-glimmer 813 tok/s and qwen3.8 702 tok/s against
  lfm2.5's 6,971. On a long review prompt that difference dominates wall time.
- `think:false` does not stop qwen3:4b reasoning in plain chat; it moves it into `content`.
- The gemma4 runner seen during the first session was started with `-b 1024 --chat-template chatml`,
  neither ollama's 512 default nor lain's 2048. If that runner was lain's, its Ollama arm is not
  applying `num_batch` on that path — still worth checking separately.

## Role recommendations

Evidence-backed, with the caveats above. "Cost" is mean tokens and mean wall seconds per item.

| role | call | evidence | caveat |
|---|---|---|---|
| **cheap QA tier (t1)** | **`laguna-xs-2.1` or `north-mini-code-1.0`** — both 100% AC accuracy, 8/8 items unanimous across runs, ~600 tokens and ~5 s | QA table | 8 items only; both are ~19 GiB, so "cheap" is true in tokens, not in residency |
| **cheapest QA tier, small-model rung** | `ornith-1.5:9b` at 97% (846 tok, 9 s) beats qwen3:4b (84%) and lfm2.5 (78%, and it wrongly passed 6 of 16 real violations) | QA table | lfm2.5 is the fastest but the least safe; do not put it alone in front of a gate |
| **code reviewer** | **`qwen3.8:27b`** (4/4 bugs every run, zero false alarms) with **`laguna-xs-2.1`** as the cheaper first pass (3.25/4, 0.25 false alarms, half the wall time) | review table | qwen3-coder's 44% recall and 1.75 mean false alarms make it a poor reviewer despite being the "coder" model. No small model qualifies: qwen3:4b at a doubled budget finds 6% of the bugs, and ornith/north-mini-code do not converge at all |
| **plan reviewer** | **`laguna-xs-2.1`** (3/3 every run, 0.25 false alarms, 19 s) or qwen3.8 (3/3, 0 false alarms, 23 s) | plan table | qwen3-coder answers in 2 s but raises 1.75 false alarms per run — the expensive kind of cheap. qwen3:4b is a usable fallback *given 12k tokens* (2.25/3, no false alarms, ~80 s) |
| **implementer** | **unresolved, and not what these probes measure.** qwen3:4b and qwen3.8 were perfect on single-step calls; laguna/north/ornith lose points mostly to read-before-run | tools table | no multi-step loop, no long-context editing, no repo-scale navigation was tested |
| **vision QA** | **`ornith-1.5:9b`** — 20/20 named correctly, 0/8 false alarms, 4.3 s, 1,166 image prompt tokens | vision table | 5 planted defect types on 1280×800 pages; real UI defects are subtler |
| **escalation partner** | qwen3.8 as the different-family second opinion; note it is the only model that crashed the runner | all tables | 2 crashes in 81 requests |

### The ladder consequence

The QA spike's ladder assumed cheap-then-strong. The data supports it, with one correction: **the cheap
rung should be laguna-xs or north-mini-code, not a 4B model.** Both were perfect on the AC items at ~600
tokens, and the 4B/lfm2.5 tier buys little: lfm2.5 is fast but passed 6 of 16 real violations, which is
exactly the failure a gate cannot tolerate.

Two free escalation signals are confirmed:
- **`done_reason: length`** — on qwen3:4b every wrong QA answer was an unparsed one whose thinking had
  already reached the correct verdict. The retest sharpens this: escalate to a *different* model, since
  only qwen3:4b converted a bigger budget into an answer, and a weak one.
- **`q6_sort_bad` fooled qwen3:4b, lfm2.5 AND qwen3-coder unanimously** (all three called a
  `"%d %H:%M"` sort correct). Unanimity across *cheap* models is therefore NOT sufficient evidence to
  accept — it took laguna, north-mini or qwen3.8 to catch it. A "unanimous-pass accepts" rule must
  require at least one model from the strong tier, or it will pass this class of defect silently.

## What these probes cannot show

Synthetic single-turn tasks, not agentic loops. n=4 (3 for qwen3.8). Keyword and line-window scoring,
which can mis-score an oddly worded but correct finding — hence the hand-checks. One box, one ollama
build (0.32.12). Prefill figures are cold only in the speed probe; later repeats hit the prefix cache.
The planted defects and the scorer share an author. Tool fidelity is measured against a rubric that
counts a cautious `read_file` before a prod command as a failure.
