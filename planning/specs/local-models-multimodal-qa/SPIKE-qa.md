# Spike: a QA role, skill, `/qa` step and epic QA gate

Exploratory, uncommitted. 2026-09-22.

## Where the code is (read this first)

- This worktree was cut from a **stale pre-rewrite ref**: branch `worktree-agent-aade4c3e4923eb2bc`
  at `b1927ce7` (2026-08-25). That ref is not an ancestor of `main`: main's history was rewritten, and
  main is `ec396926`, 488 commits ahead. The stale tree predates Zeitwerk (677 `require_relative`s,
  no `cli/epic_driver/`, `Role` without `unattended`), so almost none of the seam map applied to it.
- Moving this worktree to `main` (`reset --hard`, `switch`) was **denied by the permission
  classifier**, so I did not build here. I exported `main`'s tree (`git archive main`, read-only) into
  my scratchpad, built and tested there, and produced a patch.
- **Deliverable: `spike-qa.patch`** in this worktree root, a unified diff against **main `ec396926`**
  covering 40 files: 22 lib/template files and 18 spec files. It dry-runs clean on a pristine copy of
  main's tree. To apply it to a checkout of main, run `patch -p1 < spike-qa.patch`. The files are
  created with `diff -N`, so `patch` is the safe tool here, not `git apply`.
- Nothing is committed. As a side effect I created a branch `qa-spike-base`, which points at `main`
  and is harmless. Delete it with `git branch -D qa-spike-base`.
- **Against main, the seam map held**, with one naming drift: role templates are
  `prompt/templates/role/<name>.md` with underscores (e.g. `diff_critic.md`), not hyphens.

## Files built (paths relative to repo root, against main)

| File | What it is |
|---|---|
| `lib/lain/qa.rb` | Namespace. Holds the closed sets: `SEVERITIES` (blocker/major/minor), `HOLDING`, `TIERS` t0–t3, `VERDICTS`, `RISKS`. |
| `lib/lain/qa/finding.rb` | `Finding` Data. Blank evidence or blank reproduction is **refused at construction**, so a finding cannot be an opinion. Has a wire form and `holds?`. |
| `lib/lain/qa/report.rb` | `Report`: findings, `tiers_run` and `escalations`. `parse` reads a fenced ```` ```qa-report ```` JSON block, and refuses an answer with no block rather than reading it as a pass. Also `passed?` and `to_markdown`. |
| `lib/lain/qa/answer.rb` | One rung's answer on one criterion, from ```` ```qa-answer ````. An unreadable reply becomes `unverified`, which is a reason to climb, not a crash. A fail with no reproduction yields **no finding**. |
| `lib/lain/qa/escalation.rb` | The escalation rules **as code**, ordered, first match wins. Each `Decision` names the rule that fired. |
| `lib/lain/qa/ladder.rb` | Lain owns the rung loop. It is **breadth-first by rung** so a single-GPU box pays one model swap per rung. Budgets are per rung. Unsettled criteria become minor findings. `[visual]` criteria go only to t3. |
| `lib/lain/qa/claim_check.rb` | t0 with no model: claimed-vs-performed paths. A card that names a file the diff never touched is major; a changed file no card names is minor. |
| `lib/lain/qa/plan_cards.rb` | Reads a create-plan doc: cards, `[risk: x]`, `**Files:**` and gherkin criteria. |
| `lib/lain/qa/changeset.rb` | Reads `base..HEAD` from git (a `:seam` spec covers it). |
| `lib/lain/qa/session_tiers.rb` | Default binding: t1 and t2 are the `qa` role on the session model; no t3. |
| `lib/lain/skill/role_spawn.rb` | **`RoleSpawn#tiered(provider:, model:)`**, the per-tier model plumbing (see below). |
| `lib/lain/role/catalog.rb`, `prompt/templates/role/qa.md` | The `qa` role: `only: read_file list_files glob grep bash`, `unattended: true`, and a framing that it reports and never fixes. |
| `prompt/templates/skill/qa/{skill.md,tiers.md}` | The QA skill: the ladder, the rules, stopping, screenshot gated on the tool, and the answer and report formats. `tiers` is a slot where a project states its model assignment. |
| `prompt/templates/skill/execute-plan/skill.md` | New **Phase 4½ — QA (optional)** between land and close-out. |
| `lib/lain/cli/command/qa.rb`, `surface.rb` | **`/qa PLAN --base REF`**. Runs t0 and then the ladder, and writes `.lain/qa/<plan>-<head12>.md`. The reply is `QA PASS/HOLD: n findings, k holding, rungs …, report at …`. |
| `lib/lain/epic/qa_checkpoint.rb` | Recognises a checkpoint by an id starting `qa-gate-`, and mints fix ids `qa-fix-<n>-<k>` that can never be read as checkpoints. |
| `lib/lain/cli/epic_driver/qa_gate.rb` | `QaGate`: a pass moves the checkpoint pending→done; a hold files each holding finding as an issue. Also `ClusterQa` (the criteria of the checkpoint's blockers) and the `Unaudited` Null. |
| `lib/lain/cli/epic_driver/factory.rb` | `Run` runs ready checkpoints **before** each fill, and refolds when one passes. `Result#audited` is added. The Factory wires the real `QaGate` against the landing checkout. |
| `lib/lain/cli/epic.rb` | `CLI::Epic#file(issue, slug)`: `add` for a fully built issue (edges and provenance included), through the same write-and-journal path. |

**Specs.** New files: `spec/lain/qa/*` (9 files), `spec/lain/cli/command/qa_spec.rb`,
`spec/lain/cli/epic_driver/qa_gate_spec.rb` and `spec/lain/epic/qa_checkpoint_spec.rb`. New
examples in existing files: `run_spec.rb` (4, checkpoint between clusters), `role_spawn_spec.rb`
(2), `shipped_skills_spec.rb` (3; these pin the skill's prose to `Escalation::RULES` and the fence
names), `epic_spec.rb` (1) and the roll calls in `role_spec.rb` and `surface_spec.rb`.

**Verification.** I ran targeted specs only. The last broad run was 1,827 examples, 0 failures,
across epic_driver, the command specs, skill, qa, epic, role, slots, zeitwerk_spec,
output_discipline and lain_spec. After the final ladder change I re-ran the 94 QA-related examples
and they were green. `rubocop` over the touched files is clean, and so is
`comment-census --check-tickets`. I did not run `rake pspec`.

## The tier ladder

Deterministic tests, lint and build are the hooks' job. The rungs are ordered by **LLM cost per
defect found**.

- **t0: structural, no model.** Claimed against performed: each card's `**Files:**` against
  `git diff --name-only base..head`. A named spec file that never appeared means the criteria never
  became anything that can fail. Holds as major. A changed path no card names is carried as minor.
- **t1: small model, k samples per criterion** (default 3). Each sample returns a verdict,
  confidence, `executed?`, evidence and a reproduction.
- **Escalation, first match wins, and the rule's name is recorded:**
  1. `executed-fail` → report. An exit status is not an opinion; this holds even at high risk.
  2. `risk-high` → escalate.
  3. `unverified` → escalate.
  4. `disagreement` → escalate.
  5. `unconfirmed-fail` → escalate. A weak model's inferred fail costs a fix round, which is more
     than a t2 call.
  6. `low-confidence` (mean below 0.7) → escalate.
  7. `unanimous-pass` → accept.
  8. `too-few-samples` / `t1-unavailable` → escalate.
- **t2: a strong reviewer or a different model family**, one ask per escalated criterion. A fail
  counts only with evidence and a reproduction; anything else is unsettled.
- **t3: media**, only for `[visual]` criteria, which skip t1 and t2. It uses the `screenshot` tool
  only if the child holds it; otherwise the criterion is unverified and a manual pass is owed.
- **Stopping.** Each rung has a per-pass ask budget (`/qa` defaults: t1 60, t2 12, t3 6). A spent
  or absent rung leaves the criterion **unsettled, which is a minor finding and never a pass**. A
  criterion t1 accepted is never re-checked.
- **Severity.** blocker = a high-risk criterion fails. major = a criterion fails or a claimed file is
  missing. minor = unsettled or out of scope. Only blocker and major hold.
- **Suggested binding on this box.** t1 lfm2.5 or qwen3:4b. t2 qwen3.8:27b: dense and stronger
  than the MoE implementers, and a different family from laguna and north. t3 gemma4:e4b, or
  qwen3.8 if it is already resident. Breadth-first ordering keeps swaps to one per rung, about 80 s
  each.

## Per-role model plumbing (finding)

Roles do not choose models, and they should not: a role is shaped by its capabilities, and the same
`qa` persona is both the cheap rung and the strong one. The smallest seam is
**`Skill::RoleSpawn#tiered(provider:, model:)`**, which is built:
`seam.with(provider:, context_factory: -> { factory.call.with_model(model) })`. Persona, guard, gate
and lineage are unchanged. The **caller** (the Ladder's tier map) picks the strength for each spawn.

**Not built:** a config table such as `[qa.tiers.t1] provider=… model=…`, resolved through
`CLI::Backend#provider(name:)`. That is the method `summarizer_provider` already uses. The table
would be read by the `Surface` or `Factory` that constructs the tiers map in place of
`Qa::SessionTiers`.

## Epic QA gate: the options

- **(a) A checkpoint node in the blocking graph. RECOMMENDED and prototyped.** A node like
  `qa-gate-1` is blocked by one cluster and blocks the next. A final `qa-gate-final` is blocked by
  every leaf. No new concept is needed:
  - It becomes ready exactly when the cluster lands.
  - A pass moves it pending→done, which releases the next cluster through the next fold.
  - A hold files fixes that **block the checkpoint**, so the next cluster stays held by edges
    alone, and the checkpoint re-runs on the next fold once the fixes land.
  - There is no digest churn, the epic.md round trip is unchanged, and `lain epic status` and the
    mermaid view get it for free.
  - Cost: the marker is an id prefix (a convention) rather than a typed field.
- **(b) A new Issue field or an epic-plan section naming checkpoints.** A typed field is the honest
  marker, but `Issue#canonical` always emits every key. A new member therefore **moves the digest of
  every issue in every existing epic** and of its graph revisions, and the document grammar needs a
  new line kind. It is worth it later if checkpoints grow parameters such as tiers or budgets.
- **(c) A new `Epic::STAGES` member.** Stages are an epic-wide linear pipeline, so a stage cannot
  sit *between* two clusters of one stage. It could only express "QA once at the end". Rejected.

**Where QA runs:** in-loop in `Run#drive`, before the fill, against lain's landing checkout.
**Failure:** the checkpoint is reported with QA's line. A QA that raises holds the checkpoint
("QA could not run"). With no QA wired, the `Unaudited` Null holds and never waves a checkpoint
through.

## How findings flow back (recommendation)

- **Epic:** file each **new issue** with `discovered_from` set to the checkpoint and blocking the
  checkpoint, via `Graph#add` and `CLI::Epic#file`, as a journaled `graph_revision`. A fix is
  work: it needs a plan, red tests, an implementer and a landing, and an issue already gets all of
  that.
- `Review` blocker annotations are for a human reviewing a diff. A refused implementation gate
  would block an issue that already landed. Neither fits.
- **Non-epic `/qa`:** the report file is the hand-back. execute-plan's Phase 4½ passes each holding
  finding verbatim to the card's implementer, and the reproduction becomes the red spec.

## Half-done / not built

- The screenshot tool and the t3 binding. The skill references `screenshot` gated on the tool
  being present. The role's `only:` must **not** name it until the tool exists, or the spawn fails.
- Config-driven tier binding (above). For now every rung uses the session model.
- The epic path skips t0: issues carry no `Files`. It could read each issue's plan subject.
- Risk in epics is always `medium`; issues carry no risk.
- A cap on re-runs of a failing checkpoint (for example, escalate to a human after N passes).
- `Ladder` takes `samples:` and `Escalation.new(samples:)` separately; they should be one value.
- No end-to-end seam spec of `Factory#run` with a real checkpoint. Only `Run` has one, over fakes.

## Open questions

1. **Read-only-on-source is a promise made by the checkout, not by `only:`.** `qa` holds `bash`,
   and bash writes. In the epic, QA currently runs in lain's **landing checkout**, where the queue
   merges. It should run in a detached, throwaway checkout of the epic tip, the way `diff_critic`
   gets one. I recommend making that the first card. The skill also tells QA that a dirty
   `git status` at the end is a finding against itself; nothing enforces that yet.
2. **`unattended: true` with `bash`.** The role spec's rationale says unattended means the role
   "may not PARK, on the approval gate or on a human". Unattended strips `ask_human`, but a
   `bash` call still parks at the gate under `ask` mode. Options: accept this (the epic
   implementation gate already parks); give QA a narrower non-gated `run_tests` tool; or require
   auto mode for QA.
3. Is an id-prefix marker acceptable, or should (b)'s typed field land now, before epics exist in
   the wild?
4. `[visual]` as a scenario-name prefix, or extend the Gherkin `# rubric` marker to
   `# rubric visual`? The grammar is closed, so the second option means a parser change.
5. Should `Review::VERDICTS` grow `hold` so a QA result can also appear on the review surface?
6. Should `/qa`'s default `--base` come from the plan doc? A plan could record the SHA its first
   wave branched from.

## Recommended /create-plan chunk

1. **Wave 1**, in parallel:
   - Land `Qa::{Finding,Report,Answer,Escalation}` and their specs (low risk).
   - Land `RoleSpawn#tiered` (low risk).
   - Land the `qa` role and template (low risk; pin the open-question-2 decision).
2. **Wave 2:**
   - `Qa::Ladder` (breadth-first, budgets) and `ClaimCheck`/`PlanCards` (medium risk).
   - A detached QA checkout: lend the spawn a throwaway worktree of the head, and check that
     `git status` is clean at the end (**high** risk: isolation).
3. **Wave 3:**
   - The `/qa` command, the execute-plan Phase 4½ and the `qa` skill (medium risk).
   - `[qa.tiers]` config through `Backend#provider(name:)` (medium risk).
4. **Wave 4:** the epic checkpoint: `Epic::QaCheckpoint`, `QaGate`, `Run#audited?`,
   `CLI::Epic#file`, the `plan-epic` skill teaching `qa-gate-*` nodes, and a Factory seam spec with
   a real checkpoint and a real landing (**high** risk).
5. **Wave 5**, when the image spike lands: the t3 media rung (bind a vision model, add `screenshot`
   to `only:`).

Every card's QA scenarios belong in `planning/qa/scenarios/`.
