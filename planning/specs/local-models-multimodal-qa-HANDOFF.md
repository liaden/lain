# Handoff: local models, multimodal input, QA role — exploration of 2026-09-22

Status: **exploration paused mid-flight** (user away). Nothing is committed. This doc is the resume point;
artifacts live in `planning/specs/local-models-multimodal-qa/` (copied out of a session scratchpad that
will not survive).

## What the user decided (authoritative)

- **Models pulled** onto the local ollama (0.32.12; latest upstream is 0.34.2 — not upgraded):
  `lfm2.5`, `laguna-xs-2.1`, `north-mini-code-1.0`, `ornith-1.5:9b`. Already present: `qwen3.8:27b`,
  `qwen3:4b`, `qwen3-coder:30b`, `gemma4:e4b`, `muse-glimmer:30b`. `laguna-s-2.1` is **out** — 96 GB at
  q4 against 24 GB VRAM + 15 GB RAM.
- `/api/show` says **`ornith-1.5:9b` has tools + thinking + vision** (the library page said vision only).
- **Role split accepted**: fast MoE implementers (laguna-xs, north-mini-code, qwen3-coder) with a
  stronger or different-family reviewer (dense `qwen3.8:27b`); plan review is the best local-review fit
  (one-shot, reload cost paid once). Weak reviewers' false positives cost more than they save.
- **QA reports, never fixes.**
- **QA tiers are about LLM cost, not deterministic checks** — tests/lint/build are the git hooks' job.
  Tiers order LLM work cheapest-first to maximise defects found per wall-time and per token/dollar,
  with explicit, recorded escalation rules (the cheap-model-is-slower-to-find tension is the reason).
- **`/qa` is optional after `execute-plan`** (lain's plan-execution skill, `lib/lain/prompt/templates/skill/execute-plan/`)
  for a chonky non-epic issue. **In an epic, QA is mandatory**: the epic plan can place QA after
  clusters of issues land (before the next set), otherwise once after all issues.
- **QA knows screenshots (and maybe video) as tool use.**
- **Images: build. Audio: research only** — motivated by a future sideloaded Android app for answering
  the agent's questions by voice, and meeting-audio → notes → plan-creation input.
- **Exploration output** = a markdown findings doc + one or more worktrees of tried code.

## Thread status

### 1. Cloud model table — WRITTEN, parked on branch `local-models-quick-wins` (8d2ce30a)
Not on `main`: this is exploration, and the code lands only as part of a planned chunk.
`glm-5.3:cloud`, `glm-5.3-flash:cloud`, `deepseek-v4.1-flash:cloud` → `1_000_000`. `/api/show` reports a
trained 1,048,576 for all three (and for `glm-5.2`, whose published spec is 976K — so `/api/show` does not
settle a published-vs-trained split). It also reports **vision** on `glm-5.3-flash` and
`deepseek-v4.1-flash`, relevant to the image chunk's per-model vision check.

### 2. Research — DONE → `local-models-multimodal-qa/research-media-qa-tiers.md`
Headlines (verified against ollama v0.32.12 source + live probes):
- Ollama `images` (base64 array) is accepted on **any** role, including `role:"tool"`.
- **`format` + `tools` works only with thinking ON**; with thinking off it silently drops or corrupts
  the tool call. Ollama Cloud rejects `format`. → `Provider::Ollama` needs a guard (refuse the combo by
  name) — this is a live correctness gap in `:structured_output`, independent of everything else.
- Audio rides the same `images` array (WAV/MP3); `/v1/audio/transcriptions` is a chat prompt in
  disguise (no timestamps; hallucinated on a tone). Real STT: whisper.cpp (Vulkan/ROCm) or speaches
  (OpenAI-compatible). Standardise on the OpenAI audio API shape.
- Voice → plan: extract atomic facts with speaker + timestamps + code-verified verbatim quote; the plan
  cites fact IDs so dropped requirements are a set difference.
- VLM UI-defect detection needs a reference screenshot + defect taxonomy; pixel-diff first.
- Cascades: the escalation signal is what matters (disagreement across cheap models, self-inconsistency,
  unverifiable finding); stopping rule via capture-recapture over independent reviewers.
- HN comments on the candidate models: `local-models-multimodal-qa/hn-local-models-raw.txt`
  (summarised in the conversation: Laguna XS = strong but path-typo/tool-call complaints; North Mini
  Code ≈ Qwen3.6-35B-A3B class; LFM2.5 fast + good tool calling; an XTX user runs qwen3.8:27b daily).

### 3. Image spike — DONE → `local-models-multimodal-qa/SPIKE-images.md` + `spike-images.patch`
Works end to end on current `main`: gemma4:e4b called a new `screenshot` tool, got the PNG back in the
tool result, and read the page. 25 files, 569 targeted examples green, rubocop clean. **Uncommitted.**
- **The patch applies cleanly to `main` (ec396926)** with `git apply`. The spike's own worktree
  (`.claude/worktrees/agent-a1c1822ac0fe2992a`) was cut from a STALE base (b1927ce7, 2026-08-25, 488
  commits behind, pre-Zeitwerk) — do not build on it. A clean worktree of `main` exists at
  `.claude/worktrees/spike-images` (branch `spike-images`) for applying the patch.
- Key findings: inline base64 bloats `request_sent` 86× over 10 exchanges → **digest references on the
  Timeline, resolved by a request middleware after `JournalRequests`**; vision is **per model**
  (`/api/show` capabilities) — don't offer `screenshot` to a non-vision model, refuse new images loudly,
  degrade only history after a model switch; chromium CLI exits 0 on failed loads → the real tool needs
  CDP; `screenshot` is approval-gated (unbounded egress); image cost is pixels (tokens) vs bytes
  (journal) — the 16 KiB text ceiling is the wrong unit.
- Text-only assumptions to sweep (file:line list in the spike doc): summarizer, byte-based compaction
  trigger, stranded-prompt fold, nvim buffers.
- Proposed `/create-plan` chunk: 4 waves — value+storage, encoders+vision, text-only sweep, CDP tool.

### 4. QA spike — DONE → `local-models-multimodal-qa/SPIKE-qa.md` + `spike-qa.patch`
40 files against `main` ec396926; **apply with `patch -p1`** (new files are `diff -N`, not `git apply`).
Built against a `git archive` export of `main` (its worktree `agent-aade4c3e4923eb2bc` is stale-based
too). Targeted specs: 1,827 examples green at the last broad run, the 94 QA examples re-run after the
final change; rubocop + ticket census clean; no `pspec`. **Uncommitted.** It also left a branch
`qa-spike-base` pointing at `main` — `git branch -D qa-spike-base` if unwanted.
- Built: `qa` role + template (read-only + `bash`, unattended, report-only); `qa` skill with a
  `tiers` slot; `execute-plan` Phase 4½ (optional QA between land and close-out); `/qa PLAN --base REF`
  writing `.lain/qa/<plan>-<head12>.md`; `RoleSpawn#tiered(provider:, model:)` — the caller picks model
  strength per spawn, so roles still don't choose models.
- **Ladder, driven breadth-first** (one model swap per rung, not per AC): t0 claimed-vs-touched (no
  model) → t1 small model ×3 samples per AC → t2 strong/different-family on escalated ACs only → t3 media
  for `[visual]` ACs when `screenshot` exists. Named, recorded escalation rules: `executed-fail`
  reports without climbing; `risk-high`, `unverified`, `disagreement`, `unconfirmed-fail`,
  `low-confidence` climb; `unanimous-pass` accepts. Per-rung budgets; an AC nothing could settle is a
  minor finding, never a pass; a finding without evidence + reproduction is refused at construction.
- **Epic gate: a `qa-gate-*` checkpoint node in the existing blocking graph** — blocked by a cluster,
  blocking the next. `Run` runs ready checkpoints before launching more work; pass → done → next cluster
  released; hold → each blocking finding filed as a new issue via `Graph#add(discovered_from:)` that
  blocks the checkpoint, so QA re-runs after the fixes land. Rejected: a new Issue field (changes every
  existing issue's digest), a new `Epic::STAGES` member (can't sit between clusters of one stage).
- Not built: config-driven tier binding, the t3 screenshot binding, t0/risk for epic issues, a
  re-run cap, a Factory-level seam spec.
- Open (details in the doc): QA runs in the epic's landing checkout today → needs a detached throwaway
  checkout (**first card**); `unattended` + `bash` still parks at the gate in `ask` mode; id-prefix
  marker vs a typed field; `[visual]` as name prefix vs `# rubric visual`; grow `Review::VERDICTS`?;
  default `--base` from the plan doc.
- Proposed `/create-plan` chunk: 5 waves, ending with the t3 media rung once images land.

### 5. Local model probes — COMPLETE on 0.32.12; re-measure on 0.34.4 is 8 of 9 → `model-probes/REPORT.md`
**The box moved to ollama 0.34.4 on 2026-09-26** (0.32.12 kept installed; rollback is one env script — see
`local-models-multimodal-qa/UPGRADE-ollama-0.34.4.md` for the comparison, the lfm2.5 regression it caused,
and the upstream issue map). The 0.32.12 study below is still the reference for model selection.
Harness is direct `/api/chat` (not through lain): `run.py`, `wire.py`, `analyze.py`, `score-np12k.py`,
fixtures, raw JSONL, `scored/tables.md` + `scored/tables-np12k.md`, `REPORT.md`. All nine models ran; the
2026-09-22 out-of-memory kill and a session-end interruption were both restarted (`resume2.sh`,
`retest-budget.sh`). Measured on ollama **0.32.12**.
- **Reviewers**: `qwen3.8:27b` is the strongest (4/4 planted bugs every run, 0 false alarms, 3/3 plan
  defects, 100% tool fidelity) but the slowest to first token and it **crashed the runner twice in 81
  requests**. `laguna-xs-2.1` is the value pick (81% recall at 93% precision, 3/3 plan defects, 100% QA).
- **Vision**: `ornith-1.5:9b` flagged AND named 20/20 defect pages with 0/8 false alarms in 4.3 s.
  `gemma4:e4b` named 8/20; `muse-glimmer:30b` matched ornith but false-alarmed on 3/8 clean pages.
- **`qwen3-coder:30b` cannot be handed tools as configured**: 47% of calls arrive as `<function=read_file>`
  TEXT with `tool_calls: null` — a chat-template/parser mismatch, silent. Check its template before judging.
- **Budget retest (np=12288)**: only qwen3:4b converts extra budget into answers (and then finds 6% of the
  bugs); ornith and north-mini-code still hit the cap 3/4. So `done_reason: "length"` must escalate to a
  DIFFERENT model, never to the same model with more room.
- **Ladder corrections**: the cheap rung should be laguna-xs or north-mini-code (both 100% AC accuracy at
  ~600 tokens), NOT a 4B model — lfm2.5 wrongly passed 6/16 real violations. And `unanimous-pass` must
  include a strong-tier voice: `q6_sort_bad` fooled qwen3:4b, lfm2.5 AND qwen3-coder unanimously.
- **Wire**: (a) `format`+`tools` — `format` silently wins, tools ignored (guard parked on
  `local-models-quick-wins`; upstream [#13750](https://github.com/ollama/ollama/issues/13750) still OPEN).
  (b) the `eval_count 40` anomaly is probably upstream
  [#17274](https://github.com/ollama/ollama/issues/17274) (open, silent discard on a parse failure), not
  "thinking excluded from the count". (c) **CONFIRMED on two models**: `images` on a `role:"tool"` message
  is seen. Control finding: **ornith confabulates a plausible answer when the image is missing**, gemma4
  refuses — so the media rung must verify image delivery itself.

## Resume checklist

1. Read this doc, then the two SPIKE docs and the probe REPORT.
2. Decide the fate of the worktrees (`git worktree list`): every `agent-*` one is stale-based
   (b1927ce7) and its docs + patches are already copied here, so they can go. `spike-images` is a clean
   worktree of `main` for applying `spike-images.patch` (`git apply`); `spike-qa.patch` applies with
   `patch -p1`. Stray branch `qa-spike-base` (at `main`) can be deleted. Nothing here is committed —
   `planning/specs/local-models-multimodal-qa*` is untracked.
3. Two small fixes are written and parked on branch `local-models-quick-wins`, NOT on `main`: cloud rows
   (8d2ce30a) and `Ollama::Encoding` refusing `format`+`tools` (07a5e161). Both have specs and passed the
   hook. Cherry-pick them into whichever planned chunk claims them.
   The recorded-cassette spec's second turn was the one user of the pair — it wanted `format` to win,
   for a shaped final answer after the tool result — and now sends no tools on that turn. Probes (§5)
   relaunched via `resume.sh` on 2026-09-22.
4. `/create-plan` for images (the spike's 4-wave shape), then for QA (role + skill + `/qa` + epic gate).
   Images before QA's screenshot tier; the rest of QA does not depend on images.
5. Open questions still for the user: browser-only vs native GUI screenshots (spike built browser-only);
   whether per-role model choice (absent today — roles all use the chat's provider) is its own chunk.
