# Chunk — the epic loop closed: undo, worktree lifecycle, issue-scoped gates, test layout, the driver and its arms

status: in-progress
commit-mode: orchestrator-commits
language: ruby (with real Lua in the nvim runtime for T14)
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson; TJ DeVries joins
for T14 (the nvim buffer, on the round-11 precedent); Edward Kmett and Philip Wadler join for T6 (the
ladder term's laws)

## Intent

Every stream the 2026-09-11 docs pass left open, in one chunk, because they converge on one
observable outcome: **a human types `/implement-epic` in a chat and lain works an epic's approved
issues to a single PR against `main`** — each issue in an actor running lain's own `execute-plan`
skill, in a worktree cut from the epic's working branch, rebasing itself before it hands back,
landing serially, with the fleet and the issue graph live in a `lain://status` buffer. Around that
spine: `/undo` makes `/mode auto` defensible (ROADMAP item 42), worktrees and anchor refs stop
accumulating forever (item 28's rulings), a target project's test layout is enforced for the
parent *and* its children (item 43), and the decomposition-altitude arms measure where on that
ladder a task should enter (epic-orchestration §3.2, without the coverage grader). Sources:
`planning/specs/chunk-undo-reachability.md`, `planning/epic-orchestration.md` §3.8 and §3.12,
`planning/merge-conflict-handling.md`, `planning/specs/spec-naming-guard.md`.

## Grounding

Verified 2026-09-11 against `main` at `30e0f751` **plus the uncommitted 2026-09-11 docs pass**
(seven planning docs and ROADMAP; see the Orchestrator contract's pre-step). Seven read-only
grounding passes; every `file:line` below was read, none was run. Where a planning doc and the code
disagreed, **the code won**, and the plan says so on the card.

**Undo.** The chat Agent never receives a `snapshot_writer:` (`cli/wiring/agent_build.rb:46`), so
it runs `Agent`'s default `Workspace::Snapshot.new` (`agent.rb:148`): rooted at `Dir.pwd`, not
`project.root`, scope `WriteSet`, observer `ChainWriter::Null`. **Even the startup posture is
ignored** — the board seeds `accept_edits`, which declares `:shadow_git` (`mode/posture.rb:109-117`),
while the Agent runs `WriteSet`. `:snapshot` events reach only the in-memory Store, with no
`render_parent` and no Store enumerator (`store.rb:30-50`). The owed "scribe wiring"
(`workspace/snapshot.rb:13-21`) would yield **only a durable record**, never an in-process log, so
the in-process log is its own card (T10). `Projection#workspace_at` counts `:turn` events
(`event/projection.rb:58-63`), so `/undo` addresses a snapshot by its `causal_parents[0]` turn
digest, never by turn index. `ToolDelivery` captures the writer at construction (`agent.rb:315`),
so rebinding needs a slot, not an ivar. `Surface#builtins` sits exactly at `Metrics/AbcSize` 17.0
(`cli/command/surface.rb:111-114`) and `Env` is built at `surface.rb:86`. `Telemetry::ModeSwitch` is
`Data.define(:from, :to, :from_layers, :to_layers, :surface)` (`telemetry/switches.rb:113-126`);
`Grader::ToolSteering` reads declared tools only from the session header (`tool_steering.rb:121-133`).
`prompt_composer.rb:327-331` waits on a `mode:` that `wiring.rb:274` never passes. The
`SignoffQueue` Decision guard (`approval/signoff_queue.rb:94-104`) is an untyped `inclusion:`, and
ActiveModel 8.1.3's clusivity runs `all?` on an Array, so `[]` passes — **~58 such validators across
~35 files**, not the "~30" the draft said; `exclusion:` is the reverse hazard (`switches.rb:52-56`).

**Epic.** `lain epic submit` builds every stage's policy up front (`policies.rb:188-190`) with
`Deps.new(queue:, asker:, journal:)` (`epic_submit.rb:296-299`), so `adjudicated` raises
`MissingSeam` for any stage; a `role_spawn` exists only on the chat path (`toolset_build.rb:314-315`),
and `Improve.from_options` (`cli/improve.rb:112-115`) is the out-of-chat precedent. Stage advance is
**epic-wide** (`epic_submit.rb:193-198`) and one parked sign-off blocks every issue's implementation
gate (`epic/stage.rb:100`). Nothing writes `pending → in_flight`; the only issue transition written
is `in_flight → done` (`forge/landing/transition.rb:45`). `Scribe#graph_revised` (`scribe.rb:69`) has
no caller and no CLI edits the graph. `ID_RESERVED` lives at `epic/issue.rb:25`, `plan/step.rb:17`
and — with a zero-width extension — `question.rb:59`. **`Gherkin::Approval` and
`Gherkin::TestGeneration` are constructed nowhere in `lib/` or `exe/`**; the only reader of a
`gherkin_approval` record is its own spec. `Epic::STAGES = research epic_plan issue_plan
implementation` (`stage.rb:8`). **There is no working branch anywhere in `lib/`**; promotion pushes
remote `refs/heads/epic/<slug>/<issue>` (`forge/promotion.rb:93`) and landing targets
`BASE = "main"` (`forge/landing.rb:42`). The four epic skills mention only
`queue/approve/deny/status` — never `submit`, `land` or `request_review`.

**Worktrees.** `Worktree#add` runs `git worktree add --detach <path>` with no commit-ish
(`isolation/worktree.rb:122-123`); `handback.rb:26-35` and `worktree_spec.rb:103` currently *assert*
the parent's HEAD, and must be reworded, not violated. Handback merges with plain
`merge --no-edit` (`handback.rb:461`) and reports `:merged` whether or not it fast-forwarded.
**`git merge` has no `--conflict=zdiff3` flag** (checked on git 2.55): the strategy is
`-c merge.conflictStyle=zdiff3 … -X diff-algorithm=histogram`, still on lain's command line — the
doc's flag spelling loses. The chat Supervisor gets `handoff: Retain` (`supervisor.rb:45`,
`wiring.rb:188`); **no production path runs a real `#reclaim`**, and a one-shot child's lease ends in
a bare `release` (`tools/subagent.rb:685-690`), so **its commits are lost today**. Worktrees live on
tmpfs under `runtime_dir` (`isolation_backend.rb:156`), which cannot honour a 7-day retention. Lease
records carry no path, base or branch (`telemetry/isolation_lease.rb:37`). `Config.load` reads only
`epics` and `approval` (`config.rb:81-87`) and is called only by `cli/epic.rb:140` — **chat never
loads config**. No scheduler exists anywhere. `refs/lain/reviewed/*` (`review/delta.rb:348`) is also
lain-created and not this chunk's to reap.

**Test layout.** The production tool stack is `CLI::ToolGuard.stack` (`tool_guard.rb:23-27`),
mounted at `agent_build.rb:93`; **subagents get no tool middleware at all** (`agent_build.rb:68-77`
says so), which also means an ordinary-classified file's credential regions reach a child
**unmasked**. `RefuseSecretWrites` is a content guard on memory tools, not a path guard; the
path-aware shape to copy is `Sensitivity::Policy::PATH_FIELDS` (`sensitivity/policy.rb:65-71`) plus
`WithholdSecretPaths#base`. `TestHarness::Adapter.detect` builds only rspec
(`grader/test_harness/adapter.rb:51-78`); `Rspec#command` takes no paths (`:91-93`). Prism 1.9.0 is a
default gem already required at runtime (`prompt/locked_binding.rb:4`). `[sensitivity]`/`[shell]`
use separate **strict** readers because a restricting table must refuse a typo loudly
(`config.rb:93-98`); `[tests]` restricts writes, so it joins them. The spec doc's ACs contradict
their own Rule 2 on whether the mirror keeps the source root — this plan rules the mirror is
**relative to a declared source root** and the refusal's named path comes from a Prism index of
where the constant is defined, which retires the acronym problem rather than working around it.

**Driver.** Nothing constructs `mode: :actor`; `Actor#run` resolves `@ready` after its first turn
then parks forever (`tools/subagent/actor.rb:168-176`), but `Actor#settle` (`:95-102`) already *is*
the completion promise when the whole plan runs in that first `ask`. `Supervisor#adopt`'s signature
is pinned by OM-6 consumers (`chunk-epic-wiring-intake-landing.md:1012`). **No role may hold
`subagent`** (`role/catalog.rb:21-58`), children attenuate from a floor with no spawn
(`toolset_build.rb:324-340`), and depth defaults to 1 (`subagent.rb:59`). lain's `execute-plan` is
a prompt (`prompt/templates/skill/execute-plan/skill.md:28-52`) that tells its runner to spawn
implementers and reviewers — hence T13. `Agent::Budget` caps an `ask` at 25 iterations
(`agent/budget.rb:14-21`). A handback `Report` carries a ref, not the full SHA `Promotion` demands
(`forge/promotion.rb:147-155`).

**Status buffer.** No mermaid generation exists in `lib/`. `lain://workspace` is the exemplar
(`frontend/neovim/buffers.rb:19,282-288`); a new buffer needs `00_constants.lua` entries and a
`PROTOCOL` bump in **both** `frontend/neovim.rb:119` and `frontend/neovim/runtime.lua:70` (now
`"14"`). The frontend is never told the epic slug, and issue/stage/gate records are written by
*other processes*, so the buffer re-folds from disk on a trigger; a raise kills the drain thread
(`neovim.rb:460-465`).

**Arms.** No arm registry — adding one edits `LiveArms.build` (`bench/live_arms.rb:56-64`),
`ArmSweep::ARM_ORDER` (`bench/arm_sweep.rb:54`) and `exe/lain:529`. `HandsOff` already exists
(`approval/gate/policy.rb:115-153`); no recorded-answer policy does. `Arm::Driver::METRICS` omits
cache-write (`arm/driver.rb:29-35`) though `Compare::Run` has it. The plan-only arm is not runnable
today; offline replay cannot drive tool-using runs (so none is built — ruled).

**Toolchain.** `Metrics/ClassLength` Max is 125 (`.rubocop.yml:160-161`). The panel measured `Wiring`
112, `ChildBuilder` 110, `Handback` 110, `Repl` 109 and `Neovim` 104; `lib/lain.rb` loads
`config` :20, `question` :33, `workspace` :39, `worker_env` :42, `store` :58, `event` :59, `approval`
:68, `cli` :79, `gherkin` :85, `epic` :87, `forge` :88, `isolation` :94.

## Orchestrator contract (plan-specific only)

- **Pre-step: commit the 2026-09-11 docs pass first.** ROADMAP.md, planning/README.md and seven
  planning docs are modified or new in the working tree, and this plan's grounding cites them.
  Worktrees cut from `30e0f751` would open trees without them — the exact trap the round-14 chunk's
  execution log records. Commit, then record the base ref and the suite baseline (example COUNT,
  not just failures).
- **Shared files (orchestrator-owned, one-line wiring diffs only):** `lib/lain.rb`; the
  **require lines** of every unit index file (`lib/lain/{workspace,agent,isolation,telemetry,cli,epic,
  forge,gherkin,middleware,arm,bench,approval,grader}.rb`, `lib/lain/approval/gate.rb`,
  `lib/lain/cli/command.rb`, `lib/lain/frontend/neovim.rb`, and `lib/lain/cli/epic_driver.rb` once T15
  creates it); `exe/lain`; `lain.gemspec`; `Gemfile`; `.rubocop.yml`; `spec/spec_helper.rb`;
  `spec/support/**`. `config.rb` and `frontend/neovim.rb` carry real bodies that cards do edit — only
  their require lines are orchestrator-owned.
- **No backwards compatibility.** Nothing is production-facing: journal record shapes may widen and
  old CLI shapes (`lain epic land ISSUE SHA`'s per-issue PR) may be removed outright. The one thing
  that must survive is replay — existing journal fixtures and `DryReplay` specs stay green.
- **`:api_integration` is never run.** Every card is green offline; the live passes are the manual
  integration checks, run by the human.
- Panel seats per the header: TJ DeVries reviews T14; Kmett and Wadler review T6.

## Open decisions

None gate a card. Deferred by ruling (2026-09-11), recorded so they are decisions rather than
oversights:

- **Coverage grader and a research-requirement grammar** — ruled out of the altitude arms.
- **Offline, tool-aware replay of altitude runs** — ruled out; arms run live and cost money.
- **The stack cascade** (epic-orchestration §3.5) — only if serial landing proves too slow.
- **A custom LLM git merge driver; Friction proposing `merge=union`** — their own cards per
  `merge-conflict-handling.md`.
- **An installed systemd/launchd timer for GC** — the launch-gated daily run ships; a timer is later.
- **Actor mid-run steering** (`tell` processed after the first turn) — the driver needs only
  completion, which `settle` already gives.
- **`--png` via `mmdc`/`chafa`** — nothing in the repo references either; the buffer renders fences.
- **A test-layout allowlist mode and per-example level tags** — the guard checks only files being
  written or landed; a file's level is the root it sits in.
- **macOS** — kept portable where cheap, unverified (no test environment).

## Waves

```
Wave 1: T1  T2  T4  T5  T6
Wave 2: T3 (←T2)   T7 (←T1,T5)   T8 (←T5)   T9 (←T5)
Wave 3: T10 (←T1,T7)  T11 (←T3,T7,T8)  T12 (←T3,T7,T8)
Wave 4: T13 (←T7,T11)  T14 (←T4,T10)
Wave 5: T15 (←T3,T5,T8,T13)
Wave 6: T16 (←T3,T10,T12,T13,T14,T15)
Wave 7: T17 (←T6,T8,T16)
Wave 8: T18 (←T4,T9,T11,T12,T14,T16,T17)
```

Critical path (depth 8): **T5 → T7 → T11 → T13 → T15 → T16 → T17 → T18**. T2 → T3 → T11 and T1 → T7
feed the same spine.

The cards are deliberately large — one capability each, sized for one implementing sub-agent with
a full TDD loop. Several same-file edits are ordered by the waves:
- `cli/wiring.rb`: waves 1 (T1), 2 (T7), 3 (T10), 4 (T14) and 6 (T16).
- `tools/subagent.rb`: 2 (T7), 3 (T11), 4 (T13) and 5 (T15).
- `cli/wiring/toolset_build.rb`: 2 (T7), 3 (T11) and 4 (T13).
- `skill/role_spawn.rb`: 3 (T11) and 5 (T15).
- `cli/command/surface.rb` and `cli/command/env.rb`: 3 (T10) and 6 (T16).
- `config.rb`: 1 (T5) and 2 (T8).
- `approval/signoff_queue.rb`: T3 only.

No two same-wave cards share a file.

**A large card is several responsibilities in one hand-off, so its implementer works in the order
the card lists its parts, landing each part's specs red → green before starting the next.** Review
is per card, and the panel reads it part by part.

## Tasks

### T1 — Make a posture flip visible and honestly recorded   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/cli/wiring.rb`, `lib/lain/telemetry/switches.rb`, `lib/lain/mode/switch.rb`,
`lib/lain/cli/switchboard.rb`, `lib/lain/grader/tool_steering.rb`, `spec/lain/cli/wiring_spec.rb`,
`spec/lain/mode/switch_spec.rb`, `spec/lain/cli/switchboard_spec.rb`, `spec/lain/grader/tool_steering_spec.rb`
**Reuse:** `@switchboard.mode_switch` (a `BoundSwitch` delegating `posture`/`layers`);
`frontend/prompt_composer.rb:327-331,405-408`; `Toolset#digest` (`toolset.rb:34,40`); `BoundSwitch`
(`switchboard.rb:~389-395`)
**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring#prompt_renderer` (`wiring.rb:274`); `/mode` → `Env#mode_switch` →
`Mode::Switch#switch` → journal, on `lain chat`

Parts, in order:
1. **The prompt shows the posture.** Pass `mode: @switchboard.mode_switch` at `wiring.rb:274`; the
   modes chunk counted this landed, but it never rendered.
2. **The flip record carries the tools.** `ModeSwitch` gains the resolved toolset's digest and tool
   names, computed from the resolution the flip applied.
3. **Steering grades against that set.** `ToolSteering` takes each turn's declared set from the
   latest switch before it, falling back to the session header.

```gherkin
Scenario: a wired chat's prompt names its posture, and follows a flip
  Given a chat built by CLI::Wiring with the default posture
  When the prompt renders
  Then it shows accept_edits
  When the human runs /mode plan and the prompt renders again
  Then it shows plan

Scenario: a flip journals the tools the agent will now be shown
  Given a chat built by CLI::Wiring in accept_edits
  When the human runs /mode plan
  Then the mode_switch record carries the plan toolset's digest and names, without edit_file

Scenario: steering grades a post-flip turn against the post-flip set
  Given a journal whose header declares 20 tools and a later mode_switch declaring 13
  When tool steering grades a turn after the switch
  Then its declared set is the 13

Scenario: a journal with no switch grades as before
  Given a recorded journal fixture with no mode_switch
  When tool steering grades it
  Then the result equals the pre-card result
```
→ spec files: `spec/lain/cli/wiring_spec.rb`, `spec/lain/cli/switchboard_spec.rb`,
`spec/lain/grader/tool_steering_spec.rb`, `spec/lain/mode/switch_spec.rb`

**Escalation triggers:**
- `prompt_renderer` is reachable before `wire_agent` sets `@switchboard` on any path (today :136
  precedes :138) — stop rather than add a nil guard.
- A replay reader rejects `mode_switch` records with unknown fields — stop.
- The digest would be read after `@switch.switch` on any path — it must be the set the flip resolved.
- `Wiring` crosses `Metrics/ClassLength` (125): extract, never raise the limit.

### T2 — Close two input-shape holes, and put six drifted specs at their mirror paths   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/declarative/carrier.rb`,
`lib/lain/markdown_identifier.rb` (new), `lib/lain/epic/issue.rb`, `lib/lain/plan/step.rb`, `lib/lain/question.rb`,
`spec/lain/declarative/carrier_spec.rb`,
`spec/declarative_inclusion_discipline_spec.rb` (new, whole-tree), `spec/lain/markdown_identifier_spec.rb`,
`spec/lain/epic/issue_spec.rb`, `spec/lain/plan/step_spec.rb`, `spec/lain/question_spec.rb`;
relocations (every `→` target is a new file, made by `git mv`): `spec/lain/context_spec.rb`, `spec/lain/workspace_spec.rb`,
`spec/lain/approval_spec.rb` → `spec/lain/approval/queue_spec.rb`, `spec/lain/friction_spec.rb`,
`spec/lain/friction/report_spec.rb`, `spec/lain/cli/friction_spec.rb` (new),
`spec/lain/oracle_spec.rb` → `spec/lain/oracle/definition_spec.rb`,
`spec/lain/plan_spec.rb` → `spec/lain/plan/document_spec.rb`
**Reuse:** `Declarative::Carrier` (`declarative/carrier.rb:28-31`); the `output_discipline_spec.rb`
shape for a whole-tree meta spec; the exclusion note at `telemetry/switches.rb:52-56`; the three
`ID_RESERVED` constants and the comments naming their missing home (`epic/issue.rb:20-25`,
`question.rb:51-67`); `planning/notes/lain-spec-mirror-drift.md`
**Shared-file wiring:** `require_relative "lain/markdown_identifier"` in `lib/lain.rb` immediately
before `lain/question` (:33)
**Reachable from:** every `Carrier.check!` on the live journal path, including
`Approval::SignoffQueue.from_journal` → `#apply` (`signoff_queue.rb:228-248`), which T3 pins; `Epic::Issue`
parse (every `lain epic` command), `Plan::Step`, and `Question` (every `ask_human` question set). The
spec relocations build no capability.

Parts, in order:
1. **Scalar inclusion at the base.** An untyped attribute validated by `inclusion:` refuses any
   non-scalar before membership is tested. This fixes all ~58 sites at once, with a whole-tree meta
   spec so none regrows. T3 pins the SignoffQueue canary on its own file.
2. **One markdown-identifier rule.** One object owns backtick/CR/LF; `Question` declares its
   zero-width extension on it.
3. **Six specs at their mirror paths.** `git mv`, or merge into an existing mirror spec
   (`workspace_spec.rb`, `friction/report_spec.rb`); `context_spec.rb` keeps its `Lain::Context` half.

```gherkin
Scenario: an untyped inclusion attribute refuses Arrays and Hashes, exclusion keeps its meaning
  Given a Carrier subclass with an untyped inclusion attribute and an untyped exclusion attribute
  When they are checked with [], ["a"] and {"a" => 1}, and with scalars
  Then the non-scalars fail inclusion, and exclusion still refuses only its listed values

Scenario: no inclusion-validated untyped attribute in lib/ accepts an empty Array
  Given every Carrier subclass loaded by "lain"
  When each inclusion-validated untyped attribute is checked with []
  Then every one is invalid

Scenario: identifiers share one reserved rule, and only questions refuse zero-width characters
  Given an issue id, a plan step id and a question id each containing a backtick, and each containing U+200B
  When each is parsed
  Then all three refuse the backtick with the same message, and only the question id refuses U+200B

Scenario: the relocated specs lose nothing
  Given the suite's example count before the card
  When the relocation is applied
  Then every relocated spec's top-level constant is defined at its mirror path and the count is unchanged
```
→ spec files: `spec/lain/declarative/carrier_spec.rb`,
`spec/declarative_inclusion_discipline_spec.rb`, `spec/lain/markdown_identifier_spec.rb`,
`spec/lain/question_spec.rb`, `spec/lain/approval/queue_spec.rb`

**Escalation triggers:**
- Any of the ~58 attributes legitimately holds a list — stop and name it; that one gets a typed
  attribute, not an exemption.
- `tool/input.rb:147` generates validators dynamically: if the JSON Schema `Toolset#to_schema` emits for
  any tool moves, stop.
- A replay spec over a recorded journal fixture starts failing (a historical record carries an Array in
  an inclusion field) — stop and name it.
- `issue_spec.rb:341` pins the two constants equal, and a question refusal message (`question.rb:60-67`)
  is pinned byte-for-byte — keep both assertions' meaning; if you can't, stop.
- A duplicate spec pair holds contradictory examples, or the example count moves at all.

### T3 — Gate an issue's plan and criteria per issue, and wire `adjudicated`   [wave 2] [risk: high]

**Depends on:** T2
**Files:** `lib/lain/epic/stage.rb`, `lib/lain/epic/progress.rb`, `lib/lain/epic/submission.rb`,
`lib/lain/approval/signoff_queue.rb`, `lib/lain/approval/gate/policy.rb`, `spec/lain/approval/signoff_queue_spec.rb`,
`lib/lain/cli/epic_submit.rb`, `lib/lain/cli/epic_submit/adjudication.rb` (new), `lib/lain/approval/gate.rb`,
`lib/lain/gherkin/approval.rb` (delete), `lib/lain/telemetry/gherkin_approval.rb` (delete),
`spec/lain/gherkin/approval_spec.rb` (delete), `spec/lain/epic/stage_spec.rb`, `spec/lain/epic/progress_spec.rb`,
`spec/lain/epic/submission_spec.rb`, `spec/lain/cli/epic_submit_spec.rb`,
`spec/lain/cli/epic_submit/adjudication_spec.rb`, `spec/lain/approval/gate_spec.rb`,
`planning/qa/scenarios/epic-tier.md` (the §3 refusal note)
**Reuse:** `Scribe#issue_moved` (`scribe.rb:56`); `Verdict#advance` (`epic_submit.rb:191-198`);
`Stage#ensure_open!` (`stage.rb:100`); `Issue#criteria_digest` (`issue.rb:100`); `Artifacts#issue_plan`
(`epic_submit.rb:136-138`); `Policies::Deps` (`policies.rb:61-62`) and `Policy::Adjudicated` (`:140-146`);
`Skill::RoleSpawn`, `CLI::Backend`, and `Improve.from_options` (`cli/improve.rb:112-115`) as the
out-of-chat precedent
**Shared-file wiring:** `require_relative "epic_submit/adjudication"` in `lib/lain/cli.rb` after
`epic_submit`; remove `require_relative "gherkin/approval"` from `lib/lain/gherkin.rb` (:291); remove
the `GherkinApproval` registration from `lib/lain/telemetry.rb` (:82); `--provider`/`--model`
passthrough on `epic submit` in `exe/lain` (:380-381)
**Reachable from:** `lain epic submit STAGE SLUG [--issue ID]` → `CLI::EpicSubmit`; in-process from the
driver (T16)

Parts, in order:
1. **Issue-scoped stages.** `research` and `epic_plan` stay epic-wide. `issue_plan` and
   `implementation` are tracked per issue:
   - One issue's parked gate never blocks another's. `Stage#ensure_open!` → `queue.drained?`
     (`epic/stage.rb:101`) and the queue's `Partition` (`signoff_queue.rb:210`) take the issue, and the
     Null queue duck (`approval/gate/policy.rb:34`) widens with them.
   - Approving an issue's `issue_plan` writes that issue's `pending → in_flight`.
   - `Progress`'s slug checks (`progress.rb:247,263`) raise a `Lain::Error` naming both slugs.
2. **Criteria ride the issue plan.** The `issue_plan` artifact's digest composes the plan and the
   issue's criteria.
   - The gate decision carries `criteria_digest`, the join key `grader/journaling.rb:25` already uses.
   - No tests are written here; it is still planning.
   - `Gherkin::Approval` and its record are deleted. They were never constructed.
3. **Injected collaborators, and `adjudicated`.**
   - `EpicSubmit` accepts `asker:`, `journal:`, `role_spawn:` and `brief:`.
   - The CLI builds the adjudication pair lazily, only when some stage is configured `adjudicated`.
   - Correct the stale comment at `epic_submit_spec.rb:204` and the §3 note in `epic-tier.md`.

```gherkin
Scenario: a damaged decision line cannot drain a parked sign-off
  Given a SignoffQueue holding one parked issue-scoped sign-off
  When from_journal reads a gate_decision line whose "approved" is []
  Then the line is refused as malformed and the sign-off is still parked

Scenario: a parked issue does not block a sibling
  Given an epic past epic_plan, issue a's issue_plan parked and issue b's approved
  When implementation is submitted for issue b
  Then the implementation gate for b opens

Scenario: approving an issue's plan puts that issue in flight, and only it
  Given issues a and b both pending
  When "lain epic submit issue_plan demo --issue a" is approved
  Then issue a is in_flight, issue b is still pending, and a is not in the ready set

Scenario: approving an issue plan approves its criteria, and editing them reopens the gate
  Given a's issue_plan approved, then one criterion edited in issues/a.md
  When implementation is submitted for a
  Then the earlier gate_decision carried a's criteria_digest, and this submission is refused naming the un-approved issue_plan digest

Scenario: an adjudicated research gate decides and journals evidence
  Given [epics.gates] research = "adjudicated" and a clear research.md
  When "lain epic submit research demo" runs
  Then a gate_evidence record and a terminal gate_decision with policy adjudicated are journaled

Scenario: an ambiguous artifact parks, and unadjudicated stages build no backend
  Given a one-sentence ambiguous research.md under adjudicated, and separately every stage on interactive
  When each is submitted
  Then the first parks for the human and the second constructs no provider

Scenario: a journal for another epic is refused as a lain error
  Given a journal whose records name epic other
  When it is folded for epic demo
  Then a Lain::Error names both demo and other

Scenario: the old approval is gone
  Given the loaded "lain" library
  When Lain::Gherkin::Approval and Lain::Telemetry::GherkinApproval are referenced
  Then both are undefined
```
→ spec files: `spec/lain/approval/signoff_queue_spec.rb`, `spec/lain/cli/epic_submit_spec.rb`,
`spec/lain/epic/stage_spec.rb`,
`spec/lain/epic/progress_spec.rb`, `spec/lain/epic/submission_spec.rb`,
`spec/lain/cli/epic_submit/adjudication_spec.rb`, `spec/lain/approval/gate_spec.rb`

**Escalation triggers:**
- Giving `StageTransition` an issue field changes the digest of historical records — stop; derive
  per-issue state from the gate decisions instead.
- `Stage#ensure_open!` has a caller outside `epic_submit` that relies on the epic-wide rule — stop and
  list it.
- Folding an existing journal fixture changes an issue's status, or a fixture carries
  `gherkin_approval` records a replay reads — stop.
- `RoleSpawn` has no tool-middleware seam outside chat (`cli/improve.rb:28`). T11 (wave 3) routes the
  adjudicator child through the same guard as chat children, so build the adjudication pair so a guard
  stack can be passed in; if it can't be, stop.
- Lazy adjudication needs a change to `Policies.for_all`'s build-everything contract — stop.

### T4 — `lain epic` edits its graph and draws it as mermaid   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/epic/mermaid.rb` (new), `lib/lain/cli/epic.rb`, `lib/lain/cli/epic_graph.rb` (new),
`spec/lain/epic/mermaid_spec.rb`, `spec/lain/cli/epic_spec.rb`, `spec/lain/cli/epic_graph_spec.rb`
**Reuse:** `Epic::Progress` (`#status`, `#ready`, `#parked`); `Graph::EDGE_FIELDS` (`graph.rb:10`);
`Graph#add/split/merge` (`graph.rb:291-320`) with their `GraphFiber` block; `Scribe#graph_revised`
(`scribe.rb:69`); `Epic::Home#read_epic` (`home.rb:124`); the `Epic::Document` round-trip; the private
`Report`/`Journals` in `cli/epic.rb:186-192,263-438`
**Shared-file wiring:**
- `lib/lain/epic.rb`: `require_relative "epic/mermaid"` after `progress`.
- `lib/lain/cli.rb`: `require_relative "cli/epic_graph"`.
- `exe/lain`, `epic status` (:361-362): `method_option :mermaid, type: :boolean`.
- `exe/lain`, the `Epic < Thor` block: `add`, `split` and `merge` commands.

**Reachable from:** `lain epic status SLUG --mermaid` → `CLI::Epic#status`; `lain epic add|split|merge`
→ `CLI::EpicGraph`

Parts, in order:
1. **A mermaid view.** A pure renderer over `Progress`:
   - `flowchart TD`, with node ids sorted and prefixed.
   - `-->` for `blocks`; `-.-` for `related`, deduplicated; `discovered_from` only when its target is
     live.
   - A `classDef` per state: done, in_flight, pending, blocked (pending and not ready), abandoned.
   - `CLI::Epic` gains a public `progress(slug)` seam so T14 reuses the fold.
2. **The iterate-epic door.** `lain epic add|split|merge` applies the edit, journals the
   `graph_revision`, and writes `epic.md` back.

```gherkin
Scenario: the diagram is deterministic and drawn from the fold
  Given issue a done and blocking b, b pending and ready, c pending behind a pending blocker
  When status --mermaid renders twice
  Then both outputs are byte-identical, a is classed done, b pending, c blocked, and "a --> b" is an edge

Scenario: a keyword-shaped id is safe
  Given an issue whose id is "end"
  When status --mermaid renders
  Then the node id is prefixed and the label reads end

Scenario: a split is journaled and replayable
  Given an epic whose issue a has criteria
  When "lain epic split a --into a1,a2" runs
  Then epic.md lists a1 and a2 in place of a, and a graph_revision record replays through GraphFiber to the same graph

Scenario: an unknown issue is refused before anything is written
  Given an epic with no issue z
  When "lain epic split z --into z1,z2" runs
  Then it is refused naming z and epic.md is unchanged
```
→ spec files: `spec/lain/epic/mermaid_spec.rb`, `spec/lain/cli/epic_spec.rb`, `spec/lain/cli/epic_graph_spec.rb`

**Escalation triggers:**
- §3.8's "gated" class needs `Progress#parked` sign-offs to carry an issue id. If the mapping is not
  derivable from recorded fields, ship without the class and say so; do not infer it.
- Making `progress(slug)` public changes a spec pinning `Report` as a private constant — stop.
- Writing `epic.md` back changes bytes outside the edited issues (the `Epic::Document` digest contract)
  — stop.
- `Home.checked_name` rejects the ids a split produces (uppercase, follow-up 11) — stop and report.

### T5 — Cut workers from the working branch and merge them with lain's strategy   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/config.rb`, `lib/lain/config/isolation.rb` (new), `lib/lain/isolation/working_branch.rb`
(new), `lib/lain/isolation/merge_strategy.rb` (new), `lib/lain/isolation/worktree.rb`,
`lib/lain/isolation/worktree/handback.rb`, `lib/lain/cli/isolation_backend.rb`,
`lib/lain/telemetry/isolation_lease.rb`, `lib/lain/telemetry/handback.rb`, `spec/lain/config_spec.rb`,
`spec/lain/config/isolation_spec.rb`, `spec/lain/isolation/working_branch_spec.rb` (`:seam`),
`spec/lain/isolation/merge_strategy_spec.rb`, `spec/lain/isolation/worktree_spec.rb`,
`spec/lain/isolation/worktree_handback_spec.rb`, `spec/lain/cli/isolation_backend_spec.rb`,
`spec/lain/telemetry/isolation_lease_spec.rb`, `spec/lain/telemetry/handback_spec.rb`, `lib/lain/arm.rb`,
`lib/lain/arm/orchestrator_worker.rb`, `spec/lain/arm_spec.rb`, `spec/lain/arm/orchestrator_worker_spec.rb`
**Reuse:** the `Config::Epics` table pattern (`config/epics.rb`); `Config#initialize`/`==`/`hash`/`EMPTY`
(`config.rb:173-204`); `Handback::Checkout#run` (`handback.rb:237-241`); the Monitor-serialized reap+add
(`worktree.rb:98-109`); `Outcome` (`handback.rb:155,187`); `Paths#state_home` (`paths.rb:192`)
**Shared-file wiring:** `require_relative "config/isolation"` in `lib/lain/config.rb`;
`require_relative "isolation/working_branch"` and `"isolation/merge_strategy"` in `lib/lain/isolation.rb`
**Reachable from:** `CLI::IsolationBackend#resolve` → `Worktree.new(base:)` for `lain chat --isolation
worktree` (the Supervisor's `fleet_isolation`, `wiring.rb:254`, and one-shot leases); `Config.load` in
`cli/epic.rb:140` (chat loads it from T7); `WorkerHandoff#reclaim` → `Handback` (on the chat path from
T7; on the arms path today at `arm/orchestrator_worker.rb:109`)

Parts, in order:
1. **An `[isolation]` table**, read by `.load`, refusing unknown keys and bad values by name:
   - `retain_days = 7`
   - `rebase_retries = 1` (`0` disables worker self-sync)
   - `diff_algorithm = "histogram"`
   - `conflict_style = "zdiff3"`
2. **A named working branch.**
   - **Chat:** the named branch checked out at launch; refuse a detached HEAD, naming the fix.
   - **Epic:** local `epic/<slug>`, created from `main`'s tip if absent and never force-moved. It is
     marked lain-owned with `refs/lain/owned/heads/epic/<slug>`.
   - `#tip` is the full SHA from `rev-parse --verify refs/heads/<name>^{commit}`; a name never reaches
     `worktree add`.
3. **Base-pinned leases, on disk.** The base is a *backend construction* argument, so no other
   backend's `acquire` changes.
   - Each acquire reads the tip and runs `worktree add --detach <path> <sha>`.
   - A backend with no base refuses.
   - Worktrees move from tmpfs `runtime_dir` to `state_home/worktrees/<hash>`.
   - The lease record gains path, base SHA and branch.
   - `handback.rb:26-35` and `worktree_spec.rb:103` are reworded, not violated.
4. **lain's merge strategy.**
   - `MergeStrategy` renders `-c merge.conflictStyle=<style> merge --no-edit -X diff-algorithm=<alg>`;
     git has no `--conflict` flag on merge.
   - `Outcome` distinguishes `:fast_forwarded` from `:merged` and carries the landed commit's full SHA.
   - The handback record journals strategy, fast-forward and SHA.

```gherkin
Scenario: an absent [isolation] table yields the ruled defaults, and bad values are refused by name
  Given no [isolation] table, and separately retain_days = -1, and separately retian_days = 7
  When each config loads
  Then the first has retain_days 7, rebase_retries 1, histogram and zdiff3, and the others are refused naming the key and the file

Scenario: a chat's child starts at the working branch's tip, and a later lease sees a moved tip
  Given lain chat --isolation worktree launched on branch feat
  When a child is leased, a commit lands on feat, and a second child is leased
  Then the first HEAD was feat's old tip, the second is the new tip, and each lease record names feat and its SHA under state_home

Scenario: a detached HEAD, or no base, is refused
  Given a repo on a detached HEAD, and separately a Worktree backend built without a base
  When the working branch is resolved, and a lease is acquired
  Then each is refused, the first naming "git switch <branch>" as the fix

Scenario: an epic's branch is created once, from main, and marked owned
  Given a repo with no epic/demo branch
  When the epic working branch for demo is resolved twice
  Then epic/demo exists at main's tip, refs/lain/owned/heads/epic/demo exists, and the second resolve moved nothing

Scenario: a worker ahead of the parent fast-forwards, and says so
  Given a parent at commit P and a worker ref one commit ahead of P
  When the worker is handed back
  Then the outcome is fast_forwarded with the worker commit's full SHA and the record names the strategy

Scenario: conflict markers carry the merge base regardless of ambient git config
  Given a repo whose local git config sets merge.conflictStyle = merge, and a conflicting worker
  When the worker is handed back with the default strategy
  Then the conflicted file carries a zdiff3 base section
```
→ spec files: `spec/lain/config/isolation_spec.rb`, `spec/lain/cli/isolation_backend_spec.rb`,
`spec/lain/isolation/working_branch_spec.rb`, `spec/lain/isolation/worktree_spec.rb`,
`spec/lain/isolation/worktree_handback_spec.rb`, `spec/lain/isolation/merge_strategy_spec.rb`,
`spec/lain/telemetry/isolation_lease_spec.rb`, `spec/lain/telemetry/handback_spec.rb`

**Escalation triggers:**
- git cannot hold `refs/heads/epic/<slug>` beside `refs/heads/epic/<slug>/<issue>` (a D/F conflict). If
  a repo already carries per-issue refs from the old promotion model, refuse naming them; never delete
  them.
- The arms construct `Worktree` too (`arm.rb:150`, `arm/orchestrator_worker.rb:107`), and this card gives
  them `base: WorkingBranch.checked_out`. If that changes a bench result, stop.
- A new `Outcome` value breaks a consumer of `WorkerHandoff::Report` (`worker_handoff.rb:82,99`) or a
  Friction fold — stop and list the consumers.
- `Handback` crosses `ClassLength` 125: the strategy is its own object already, so extract.
- `Config#==`/`#hash` widening breaks an equality spec — stop.
- A fixture shells to git without scrubbing `GIT_INDEX_FILE` — fix the fixture, don't skip the spec.

### T6 — The altitude bench's building blocks: ladder, recorded answers, epic metrics   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/arm/ladder.rb` (new), `lib/lain/approval/gate/recorded_policy.rb` (new),
`lib/lain/bench/epic_metrics.rb` (new), `lib/lain/arm/driver.rb`, `spec/lain/arm/ladder_spec.rb`,
`spec/lain/approval/gate/recorded_policy_spec.rb`, `spec/lain/bench/epic_metrics_spec.rb`,
`spec/lain/arm/driver_spec.rb`
**Reuse:**
- `Epic::STAGES` (`stage.rb:8`).
- `Policies.for_all(config:, deps:)` and its `#gate_policy_for(stage)` duck (`policies.rb:188`).
- `StandingAnswer` and `HandsOff` (`gate/policy.rb:115-153`).
- The journal records the metrics fold over:
  - `IssueTransition` (`epic/records.rb:194`)
  - `SupersessionRecord` (`telemetry/supersession_record.rb:39`)
  - `gate_decision`
- `Compare::Run#cache_write_tokens` (`compare.rb:51,100`).

**Shared-file wiring:** `require_relative "arm/ladder"` in `lib/lain/arm.rb`;
`require_relative "gate/recorded_policy"` in `lib/lain/approval/gate.rb`;
`require_relative "bench/epic_metrics"` in `lib/lain/bench.rb`
**Reachable from:** `Arm::Driver` behind `lain bench arms` (the cache-write column); the ladder, the
recorded policy and the folds are constructed by the arms and `lain bench altitude` (T17)

Parts, in order:
1. **The ladder, as data.** A frozen Array of stage names — research → epic_plan → issue_plan →
   implementation → land. It is not a term algebra, because nothing here needs one.
   - Gate policy is an *evaluator parameter*, never part of the ladder.
   - The two properties are stated as ACs, not as `Lain::Algebra` declarations:
     - an arm's rungs are the suffix that starts at its entry rung;
     - for any two policy maps, an all-approve run *visits* the same stages.
   - Under denial the traces differ, and measuring that difference is what round-trips are for.
   - Arms are entry rungs:
     - one-shot enters at implementation, with no gates;
     - plan-only enters at issue_plan, with no epic;
     - epic-progressive and epic-hands-off enter at research and differ only in their policy map.
2. **A recorded-answer policy.**
   - It answers from recorded `gate_decision`s by artifact digest.
   - It journals `policy: "recorded"` and refuses loudly on an unrecorded digest.
   - It is kept out of `Policies::CATALOG`, so config can never select it.
3. **Epic metrics.** Pure folds over journal records:
   - **rework:** transitions out of `done`, plus supersessions.
   - **round-trips:** gate decisions per (epic, stage, issue).
   - `Arm::Driver::METRICS` gains cache-write, shown as *absent* rather than `0` when unmeasured.

```gherkin
Scenario: an arm's rungs are the suffix from its entry rung
  Given the ladder and an arm entering at issue_plan
  When its rungs are listed
  Then they are issue_plan, implementation, land in that order

Scenario: policy changes which answers come back, not which stages are visited
  Given epic-progressive and epic-hands-off over the same ladder, both run against an all-approve stub
  When the stages each visits are listed, and Policies.for_all is built over hands-off's map
  Then both visited the same stages in the same order, and every gated stage resolves to hands_off

Scenario: recorded answers replay, and an unrecorded digest is refused
  Given a recorded gate_decision approving digest D and none for E
  When the recorded policy decides D and then E
  Then D is approved with policy "recorded" and E is refused naming E

Scenario: config cannot name the recorded policy
  Given the policy catalog config validates against
  When "recorded" is looked up as a configurable policy name
  Then it is absent, so an [epics.gates] entry naming it is refused as unknown

Scenario: rework and round-trips fold from records
  Given issue a moved done→pending once, and two denials and one approval on its issue_plan
  When the metrics fold
  Then a has rework 1 and its issue_plan has 3 round-trips

Scenario: an unmeasured cache-write is absent, not zero
  Given offline recordings carrying only input and output usage
  When the arm report renders
  Then the cache-write column says it was not measured
```
→ spec files: `spec/lain/arm/ladder_spec.rb`, `spec/lain/approval/gate/recorded_policy_spec.rb`,
`spec/lain/bench/epic_metrics_spec.rb`, `spec/lain/arm/driver_spec.rb`

**Escalation triggers:**
- Modelling §3.2's "issues" rung needs a new `Epic::STAGES` member — stop; that is T3's territory.
- `bench` loads at `lib/lain.rb:82`, before `grader` (:84), `epic` (:87) and `arm` (:95).
  `bench/epic_metrics.rb` must not reference an `Epic::`, `Arm::` or `Grader::` constant at class-body
  time; a `KINDS = [Epic::IssueTransition]` constant raises `NameError`. If it can't avoid one, stop.
- `spec/lain/bench/arms_report_spec.rb` pins the report's columns byte-for-byte — stop and confirm the
  new layout.

### T7 — Hand a worker's commits back on the chat path, after it rebases itself   [wave 2] [risk: high]

**Depends on:** T1, T5
**Files:** `lib/lain/cli/wiring.rb`, `lib/lain/cli/wiring/toolset_build.rb`, `lib/lain/tools/subagent.rb`,
`lib/lain/isolation/self_sync.rb` (new), `spec/lain/cli/wiring_spec.rb`, `spec/lain/cli/wiring/toolset_build_spec.rb`, `spec/lain/tools/subagent_spec.rb`, `spec/lain/isolation/self_sync_spec.rb` (`:seam`),
`spec/lain/seams/one_shot_handback_spec.rb` (new, `:seam`)
**Reuse:** `WorkerHandoff.over(resolver:)` (`worker_handoff.rb:211-213`) with a `RoleSpawn`-backed
`merge_resolver`; `Config.load`; `MergeStrategy`, `WorkingBranch#tip` and `rebase_retries` (T5);
`Leases#hold`/`#reclaim` and the still-live child inside the hold block (`subagent.rb:246-249,668-690`).
`Leases` is built at `toolset_build.rb:305`, so that is where the handoff reaches it. For the resolver,
the late-bound thunk precedent `switchboard: -> { @switchboard }` (`wiring.rb:335`).
**Shared-file wiring:** `require_relative "isolation/self_sync"` in `lib/lain/isolation.rb`
**Reachable from:** `CLI::Wiring#wire_agent` → `Supervisor.new(handoff:)` (`wiring.rb:188`), and
`Tools::Subagent#run_child` → `Leases#hold` on `lain chat --isolation worktree`

Parts, in order:
1. **Handback on the chat path.**
   - Chat loads `.lain/config.toml`.
   - The Supervisor gets a real `WorkerHandoff` with the configured strategy.
   - The `merge_resolver` needs a `RoleSpawn`. That is built inside `ToolsetBuild` (`:315`) over a seam
     that takes the Supervisor, and the Supervisor is built first (`wiring.rb:188`, before `:190`). So
     the handoff's resolver dereferences a late-bound thunk, never the object itself.
   - A one-shot child's lease ends in `handoff.reclaim` instead of a bare release. **A worker's commits
     are never optional**, and this is the part that makes that true.
2. **The worker syncs itself first.** Between `child.ask` and reclaim, lain tries
   `git rebase <tip>` in the worktree with its strategy.
   - Conflicted: abort, then ask the still-live child to rebase and resolve, up to `rebase_retries`
     times. `0` skips straight to handback.
   - Each attempt and its conflict count ride the handback record.
   - A child without `bash` is not asked.
   - A dirty tree is not rebased.

```gherkin
Scenario: a one-shot child's commit comes back as a fast-forward after a clean self-rebase
  Given lain chat --isolation worktree on branch feat, wired by CLI::Wiring
  When a dev child commits c1 on base B while feat moved to T without overlap, and returns
  Then c1 is rebased onto T, feat contains it, and a handback record names fast_forward true

Scenario: a conflicting rebase goes back to the worker once, then to the resolver
  Given rebase_retries = 1 and a child whose rebase onto the tip conflicts twice
  When it returns
  Then lain asks the child once, journals the attempt with its conflict count, and spawns a merge_resolver

Scenario: zero retries disables self-sync
  Given rebase_retries = 0 and a conflicting child
  When it returns
  Then no rebase is asked for and the handback merges as before

Scenario: a dirty worktree is not rebased
  Given a child that left uncommitted changes in its worktree
  When it returns
  Then no rebase runs and the handback record says the tree was dirty

Scenario: a dirty parent checkout is reported, not clobbered
  Given uncommitted human edits the merge would touch
  When a child returns
  Then the work is anchored under refs/lain/worker and the refusal names the dirty files
```
→ spec files: `spec/lain/seams/one_shot_handback_spec.rb`, `spec/lain/isolation/self_sync_spec.rb`,
`spec/lain/cli/wiring_spec.rb`, `spec/lain/tools/subagent_spec.rb`

**Escalation triggers:**
- `WorkerHandoff` refuses to spawn while unwinding. A child that raised must `surrender`, not `reclaim`;
  if the hold block can't tell the two apart, stop.
- The follow-up ask re-enters a child `Agent::Budget` that is already spent — stop; don't raise the
  budget silently.
- `git rebase --continue` must run with `GIT_EDITOR=true`; if any path still opens an editor, stop.
- A rebase rewrites commits already anchored under `refs/lain/worker/*` — anchor first. If the anchor
  would then misjudge ancestry for GC (T9), stop and design the anchor move.
- `Wiring` crosses its `ClassLength` cap: extract the supervisor assembly into `cli/wiring/`.
- A thunk can't break the Supervisor ↔ RoleSpawn construction cycle without reordering `wire_agent` —
  stop and propose the order. Never construct a second RoleSpawn.

### T8 — Know a project's test layout, check a test file against it, and generate tests into it   [wave 2] [risk: high]

**Depends on:** T5
**Files:** `lib/lain/test_layout.rb` (new), `lib/lain/test_layout/mapping.rb` (new),
`lib/lain/test_layout/guard.rb` (new), `lib/lain/test_layout/constant_index.rb` (new), `lib/lain/config.rb`,
`lib/lain/grader/test_harness.rb`, `lib/lain/grader/test_harness/adapter.rb`, `lib/lain/gherkin/test_generation.rb`,
`lib/lain/prompt/templates/skill/gherkin-tests/skill.md`, `spec/lain/test_layout_spec.rb`,
`spec/lain/test_layout/mapping_spec.rb`, `spec/lain/test_layout/guard_spec.rb`,
`spec/lain/test_layout/constant_index_spec.rb`, `spec/lain/config_spec.rb`, `spec/lain/grader/test_harness_spec.rb`,
`spec/lain/gherkin/test_generation_spec.rb`, `spec/fixtures/projects/layout_mini/**` (new fixture project)
**Reuse:** the strict-reader pattern `Config.sensitivity(root:)`/`.shell_exclusions(root:)`
(`config.rb:93-162`); `Shell::Exclusions` as the table-class shape; Prism (`prompt/locked_binding.rb:4`;
`spec/spec_discipline_spec.rb:139` finds `RSpec.describe`); `Adapter::Command`'s argv lambda
(`test_harness.rb:130-140`); `TestGeneration#call` (`test_generation.rb:51-60`)
**Shared-file wiring:** `require_relative "lain/test_layout"` in `lib/lain.rb` after `lain/config` (:20);
the new index's own lines for `mapping`, `guard`, `constant_index`
**Reachable from:** `CLI::Wiring::BoardBuild` constructs the layout for the write-time guard (T11); the
land-time check (T12) and the issue test step (T15) construct the guard and `TestGeneration`

Parts, in order:
1. **The layout, as data.**
   - **Presets:**
     - rspec: `spec/{unit,seam,integration}`, `_spec.rb`
     - minitest: `test/…`, `_test.rb`
     - pytest: `test_*.py`
     - cargo: unit tests inline, `tests/` for integration
   - `[tests]` names the preset, the source roots (the mirror is relative to one), the level roots and
     the exempt paths.
   - It is read strictly, so a typo is refused. With no table the caller may pass a detected
     framework's preset; otherwise the layout is `TestLayout::None`, a Null Object.
2. **The guard.** For a test file under a mirrored level root:
   - the top-level describe is a constant;
   - that constant is *defined in* the mirrored source file (Prism index);
   - that file exists;
   - any level tag agrees with the root.

   A verdict names the path the file should occupy: look up where the constant is defined, then mirror
   that file, so no acronym table is needed. A file's level is the root it sits in. Non-Ruby presets
   check only that the mirror exists and the exemptions.
3. **Tests go where the layout says.**
   - `TestHarness#run(paths:)` runs one level root.
   - `TestGeneration` takes the layout, the subject file and the level. The prompt names the exact
     target path, and afterwards the call verifies the file is there.

```gherkin
Scenario: the rspec preset mirrors relative to a source root, and a typo is refused
  Given [tests] preset = "rspec" and source_roots = ["app"], and separately [tests] prest = "rspec"
  When each layout loads
  Then app/models/order.rb mirrors to spec/unit/models/order_spec.rb, and the second is refused naming prest

Scenario: no table and no framework guards nothing
  Given no [tests] table and no detected framework
  When the layout loads
  Then it is TestLayout::None

Scenario: a split sibling is refused, naming the right path
  Given layout_mini with app/models/order.rb defining Order and spec/unit/models/order_extra_spec.rb describing Order
  When the guard checks the sibling
  Then it fails naming spec/unit/models/order_spec.rb

Scenario: differently-named files and acronym namespaces pass
  Given app/models/records.rb defining OrderTransition and app/cli/backend.rb defining CLI::Backend, each with a mirrored spec
  When the guard checks both
  Then both pass

Scenario: a seam tag under the unit root fails, and an unparseable source is reported
  Given spec/unit/models/order_spec.rb tagged :seam, and app/models/broken.rb with a syntax error
  When the guard checks each
  Then the first names spec/seam/models/order_spec.rb and the second says the source could not be parsed

Scenario: a level root narrows the test run
  Given layout_mini with specs under spec/unit and spec/seam
  When the harness runs with paths ["spec/unit"]
  Then only spec/unit examples are counted

Scenario: generation names and verifies its target path
  Given the rspec layout and subject app/models/order.rb at the unit level, and a child that wrote elsewhere
  When test generation runs
  Then its prompt named spec/unit/models/order_spec.rb and the call reports that file missing
```
→ spec files: `spec/lain/test_layout_spec.rb`, `spec/lain/test_layout/mapping_spec.rb`,
`spec/lain/test_layout/guard_spec.rb`, `spec/lain/test_layout/constant_index_spec.rb`,
`spec/lain/grader/test_harness_spec.rb`, `spec/lain/gherkin/test_generation_spec.rb`, `spec/lain/config_spec.rb`

**Escalation triggers:**
- Detection needs `Grader::TestHarness::Adapter`, which loads at `lib/lain.rb:84`, after `config`. The
  layout takes a detected framework as an argument and never calls the adapter; if it can't, stop.
- A guard check exceeds 200 ms on lain's own `lib/` — index lazily by constant and cache per session; if
  it is still slow, stop and report.
- jest and pytest raise `Undetectable` (`adapter.rb:77-78`); don't implement them here.
- `spec/lain/skill/shipped_skills_spec.rb` pins more than the `gherkin-tests` template — stop.

### T9 — Reap worktrees and anchors whose work is safe elsewhere, daily   [wave 2] [risk: high]

**Depends on:** T5
**Files:** `lib/lain/isolation/gc.rb` (new), `lib/lain/telemetry/worktree_reap.rb` (new),
`lib/lain/cli/worktrees.rb` (new), `lib/lain/cli/gc_schedule.rb` (new), `lib/lain/cli/chat_launch.rb`,
`lib/lain/cli/up.rb`, `spec/lain/isolation/gc_spec.rb` (`:seam`), `spec/lain/telemetry/worktree_reap_spec.rb`,
`spec/lain/cli/worktrees_spec.rb`, `spec/lain/cli/gc_schedule_spec.rb`, `spec/lain/cli/chat_launch_spec.rb`,
`spec/lain/cli/up_spec.rb`
**Reuse:** `Handback#pin`'s anchor-first compare-and-swap (`handback.rb:270-272,423-435`);
`git worktree list --porcelain`; `merge-base --is-ancestor`; lease records and `refs/lain/owned/heads/*`
markers (T5); `Paths#state_home`; `Up.pane_command`'s binary-and-environment composition; the
`Epic < Thor` group as the subcommand exemplar
**Shared-file wiring:** `require_relative "isolation/gc"` in `lib/lain/isolation.rb`; the record's
registration in `lib/lain/telemetry.rb`; `require_relative "cli/worktrees"` and `"cli/gc_schedule"` in
`lib/lain/cli.rb`; a `Worktrees < Thor` group with `gc`, registered in `exe/lain` beside `epic`
(:636-637)
**Reachable from:** `lain worktrees gc`; `ChatLaunch#call` (`chat_launch.rb:85`) and `Up#call` (`up.rb:580`)
construct `GcSchedule` with the real process spawner

Parts, in order:
1. **The reaper.** It is idempotent, and it only ever touches paths under lain's worktree root and refs
   lain created.
   - An anchor whose commits are an ancestor of its working branch (folded) or of `main` (landed) is
     deleted.
   - A worktree that is folded or landed is removed.
   - A worktree older than `retain_days` is anchored first, then removed.
   - An expired worktree's anchor is kept, and reported, when nothing else reaches its commits.
   - A local working branch with an owned marker is deleted once it is an ancestor of `main`, marker
     with it.
   - Every reap and keep is journaled with its reason.
2. **The command and the daily run.**
   - `lain worktrees gc` prints what it reaped and kept.
   - Any `lain chat`/`lain up` launch reads a stamp under `state_home`. If it is older than 24 hours, the
     launch spawns one detached `lain worktrees gc`, logging under `state_home` and never to the
     terminal.

```gherkin
Scenario: a folded worker's anchor and worktree are reaped
  Given an anchor and a worktree whose HEAD is an ancestor of feat
  When gc runs
  Then both are gone and a record says folded into feat

Scenario: an expired worktree keeps its unreachable commits
  Given a worktree 8 days old holding a commit reachable from no branch
  When gc runs with retain_days 7
  Then the worktree is removed, an anchor keeps the commit, and a record says kept

Scenario: a merged epic branch is deleted only if lain created it
  Given epic/demo merged into main with an owned marker, and topic/x merged into main without one
  When gc runs
  Then epic/demo and its marker are deleted and topic/x is untouched

Scenario: running twice changes nothing the second time
  Given a repo gc has just run over
  When gc runs again
  Then nothing is reaped

Scenario: a stale stamp makes a real launch spawn one detached run
  Given ChatLaunch built as exe/lain builds it, and a stamp 25 hours old
  When lain chat launches
  Then exactly one detached gc process is spawned by the process spawner and the stamp is renewed

Scenario: a fresh stamp spawns nothing
  Given a stamp 2 hours old
  When lain up launches
  Then no gc process is spawned
```
→ spec files: `spec/lain/isolation/gc_spec.rb`, `spec/lain/telemetry/worktree_reap_spec.rb`,
`spec/lain/cli/chat_launch_spec.rb`, `spec/lain/cli/gc_schedule_spec.rb`, `spec/lain/cli/worktrees_spec.rb`,
`spec/lain/cli/up_spec.rb`

**Escalation triggers:**
- Any path would touch a worktree outside lain's root, delete a ref outside `refs/lain/` or an unmarked
  branch, or push to a remote — stop.
- A worktree is leased by a live process and liveness can't be told from recorded fields — stop.
- `spec/output_discipline_spec.rb` fails on the spawn's redirection — route it through a `Sink` or the
  frontend; never loosen the spec.
- The spawned command resolves `lain` from the launcher's `PATH`. That is the tmux-pane trap in
  CLAUDE.md, so compose the binary like `Up.pane_command`. Stop if a spec passes only because
  `bundle exec` put `lain` on `PATH`.

### T10 — Snapshots follow the posture into an in-process log, and `/undo` restores from it   [wave 3] [risk: high]

**Depends on:** T1, T7
**Files:** `lib/lain/workspace/snapshot_log.rb` (new), `lib/lain/workspace/restore.rb`,
`lib/lain/agent/snapshot_slot.rb` (new), `lib/lain/agent.rb`, `lib/lain/agent/tool_delivery.rb`,
`lib/lain/cli/wiring/agent_build.rb`, `lib/lain/cli/switchboard.rb`, `lib/lain/cli/command/undo.rb` (new),
`lib/lain/cli/command/surface.rb`, `lib/lain/cli/command/env.rb`, `lib/lain/cli/wiring.rb`,
`spec/lain/workspace/snapshot_log_spec.rb`, `spec/lain/workspace/restore_spec.rb`,
`spec/lain/agent/snapshot_slot_spec.rb`, `spec/lain/agent/tool_delivery_spec.rb`,
`spec/lain/cli/wiring/agent_build_spec.rb`, `spec/lain/cli/switchboard_spec.rb`,
`spec/lain/cli/command/undo_spec.rb`, `spec/lain/cli/command/surface_spec.rb`, `spec/lain/cli/command/env_spec.rb`
**Reuse:** the Snapshot `observer:` seam (`snapshot.rb:69-76`) and `ChainWriter#put` (`chain_writer.rb:59-67`);
`Restore`'s write-and-delete (`restore.rb:99-116`); `Mode::Resolution#snapshot_scope`
(`resolution.rb:29,74`); `Snapshot::Scope::REGISTRY` (`snapshot/scope.rb:55`); `Switchboard#apply`
(`:317-320`); `Command::Rewind` (refuse before anything moves, journal via the chronicle, then act);
`review_commands` in `surface.rb` as the extraction exemplar
**Shared-file wiring:** `require_relative "workspace/snapshot_log"` in `lib/lain/workspace.rb`;
`require_relative "agent/snapshot_slot"` in `lib/lain/agent.rb`; `require_relative "command/undo"` in
`lib/lain/cli/command.rb`; `spec/support/command_env.rb`: a default for the new `Env` member
**Reachable from:** `CLI::Wiring::AgentBuild#build` → `Agent.new(snapshot_slot:)`; `/mode` →
`Switchboard#apply`; `Command::Surface#registry` → `/undo` at the `you>` prompt of `lain chat`

Parts, in order:
1. **The in-process log.**
   - An observer records each `:snapshot` event keyed by the turn digest it cites (`causal_parents[0]`).
     It holds digests only, since the bytes already live in the Store.
   - It answers "the snapshot to restore to undo the most recent turn that changed files", walking
     further back on each call.
   - `Restore` can restore one recorded snapshot without a `Projection`.
2. **The writer follows the posture.**
   - A slot that `ToolDelivery` reads at each settle.
   - `AgentBuild` fills it with a `Snapshot` rooted at `project.root`, scoped by the board's resolved
     posture and observed by the log.
   - The slot is born in `AgentBuild`, which hands it to the Switchboard itself
     (`board.bind_snapshots(slot)`). That lets `Switchboard#apply` rebind it on a flip without this card
     touching `board_build.rb`, which is T11's in the same wave.
   - This also fixes the startup case: `accept_edits` declares `:shadow_git` but has always run
     `WriteSet`.
3. **`/undo`.**
   - It restores files only; `/rewind` owns the conversation.
   - Repeated `/undo` walks further back.
   - Under `write_set` it says only lain-written files were restored.
   - It joins an extracted command group, because `builtins` sits at `AbcSize` 17.0.

```gherkin
Scenario: the default posture's scope is in force from the first turn, rooted at the project
  Given a chat built by CLI::Wiring in accept_edits, launched from a project subdirectory
  When a bash tool call creates a file no lain tool wrote
  Then the next snapshot records it and its root is the project root

Scenario: a flip to plan rebinds to write_set
  Given the same chat
  When the human runs /mode plan and a later turn writes through write_file
  Then that turn's snapshot has scope write_set

Scenario: undo restores what the last writing turn changed and leaves the conversation alone
  Given a chat where turn C wrote a.rb through write_file and turn B wrote nothing
  When the human runs /undo
  Then a.rb has its pre-C bytes, an undo record names C, and the timeline head is unchanged

Scenario: repeated undo walks further back
  Given turns B and C both wrote files, and one /undo already taken
  When the human runs /undo again
  Then the workspace is restored to before B

Scenario: nothing to undo is said, not raised
  Given a fresh chat
  When the human runs /undo
  Then it says there is nothing to undo and nothing is journaled

Scenario: under write_set it says what it could not restore
  Given a chat in plan posture where a bash call created c.txt
  When the human runs /undo
  Then the reply says only lain-written files were restored
```
→ spec files: `spec/lain/cli/wiring/agent_build_spec.rb`, `spec/lain/cli/switchboard_spec.rb`,
`spec/lain/cli/command/undo_spec.rb`, `spec/lain/workspace/snapshot_log_spec.rb`,
`spec/lain/workspace/restore_spec.rb`, `spec/lain/agent/tool_delivery_spec.rb`,
`spec/lain/agent/snapshot_slot_spec.rb`, `spec/lain/cli/command/surface_spec.rb`, `spec/lain/cli/command/env_spec.rb`

**Escalation triggers:**
- One `ShadowGit` snapshot of lain's own tree costs more than one second — measure, report and stop; the
  default posture would pay it on every tool turn, and that is a policy call.
- `workspace` loads before `store` and `event` (`lib/lain.rb:39` vs `:58-59`). The log must not
  reference `Event` or `Store` at class-body time.
- A restore would delete a file the human created after the snapshot — stop; `/undo` never deletes what
  lain did not write.
- `/undo` while a tool call is parked or a worktree child is live should refuse by name. If that needs a
  new query on the Agent, stop and propose it.
- `supervisor/restart.rb:174`'s projection-based restore changes behaviour — stop.
- `Agent.new` trips `Metrics/ParameterLists`: replace `snapshot_writer:` rather than add beside it.
- `Wiring` (112/125), `Switchboard` or `Surface` crosses a `Metrics` cap — extract, never raise it.

### T11 — One tool guard for a parent and its children, and it enforces the test layout   [wave 3] [risk: high]

**Depends on:** T3, T7, T8
**Files:** `lib/lain/tools/subagent.rb`, `lib/lain/cli/wiring/toolset_build.rb`, `lib/lain/skill/role_spawn.rb`,
`lib/lain/cli/improve.rb`, `lib/lain/cli/epic_submit/adjudication.rb`, `spec/lain/skill/role_spawn_spec.rb`,
`spec/lain/cli/improve_spec.rb`, `spec/lain/cli/epic_submit/adjudication_spec.rb`,
`lib/lain/middleware/guard_test_layout.rb` (new), `lib/lain/cli/tool_guard.rb`, `lib/lain/cli/wiring/board_build.rb`,
`lib/lain/telemetry/test_layout.rb` (new), `spec/lain/tools/subagent_spec.rb`,
`spec/lain/cli/wiring/toolset_build_spec.rb`, `spec/lain/middleware/guard_test_layout_spec.rb`,
`spec/lain/cli/tool_guard_spec.rb`, `spec/lain/cli/wiring/board_build_spec.rb`, `spec/lain/telemetry/test_layout_spec.rb`,
`spec/lain/seams/child_tool_guard_spec.rb` (new, `:seam`)
**Reuse:** `CLI::ToolGuard.stack(chronicle, board)` (`tool_guard.rb:23-27`); `Subagent::Seam`
(`subagent.rb:727-728`); `spawn_seam`/`role_spawn_seam` (`toolset_build.rb:301-315`);
`Sensitivity::Policy::PATH_FIELDS` (`sensitivity/policy.rb:65-71`) and `WithholdSecretPaths#base`/`#at`
(`:310-322`); `RefuseSecretWrites`'s refusal shape (`:133-136`); `BoardBuild`'s `notice` seam
(`board_build.rb:37-45`); `TestLayout::Guard` (T8)
**Shared-file wiring:** `require_relative "middleware/guard_test_layout"` in `lib/lain/middleware.rb`; the
records' registration in `lib/lain/telemetry.rb`
**Reachable from:** `CLI::Wiring::ToolsetBuild#spawn_seam`/`#role_spawn_seam` → each child's `Agent.new`;
`CLI::Wiring::BoardBuild` → board layout → `CLI::ToolGuard.stack` (`agent_build.rb:93`)

Parts, in order:
1. **Children get the guard.** The seam carries the tool middleware as a **thunk over the board**,
   because the board is built after the toolset (`wiring.rb:190`, then `:194`), so the stack can't
   exist at seam time. Every `Seam.resolve` site passes it:
   - `subagent.rb:62`
   - `skill/role_spawn.rb:38`
   - `cli/improve.rb`
   - T3's `epic_submit/adjudication.rb`

   Out-of-chat callers build their own stack. This closes the documented gap: a child's reads were unmasked
   (`agent_build.rb:68-77`; T18 deletes that comment). The new seam member is **required, never
   defaulted** — a Null default is how production would go silently guardless.
2. **Write-time layout enforcement.**
   - `write_file` under a level root is checked against its full content; `edit_file` against the path
     rules.
   - A refusal names the right path, writes nothing, and journals `test_layout_refused`.
   - Under `TestLayout::None`, one `test_layout_absent` record per session.
   - A malformed `[tests]` table reaches the human as a notice, never a crash.

```gherkin
Scenario: a chat-wired child's read is masked like the parent's
  Given a chat built by CLI::Wiring over a project with an ordinary file holding an AWS key
  When the research subagent reads that file
  Then the region is masked in the child's tool result

Scenario: an out-of-chat child is guarded too
  Given lain epic submit with an adjudicated stage, over a project with an ordinary file holding an AWS key
  When the adjudicator child reads that file
  Then the region is masked

Scenario: one region ledger for the whole run
  Given a parent and a child that both read the same gated file
  When both reads are approved once
  Then one approval covers both

Scenario: a child's split sibling is refused, naming the right path
  Given a chat built by CLI::Wiring over layout_mini with the rspec layout
  When a dev child writes spec/unit/models/order_extra_spec.rb describing Order
  Then the tool result refuses it naming spec/unit/models/order_spec.rb and nothing is written

Scenario: a correct write passes untouched
  Given the same chat
  When the parent writes spec/unit/models/order_spec.rb describing Order
  Then the file is written

Scenario: no layout, no refusal, one record; a malformed table is a notice
  Given a project with no [tests] table and no detectable framework, and separately [tests] prest = "rspec"
  When the agent writes two test files, and when the second chat starts
  Then neither write is refused and one test_layout_absent is journaled, and the second chat tells the human the table was ignored
```
→ spec files: `spec/lain/seams/child_tool_guard_spec.rb`, `spec/lain/cli/wiring/board_build_spec.rb`,
`spec/lain/middleware/guard_test_layout_spec.rb`, `spec/lain/tools/subagent_spec.rb`,
`spec/lain/cli/wiring/toolset_build_spec.rb`, `spec/lain/cli/tool_guard_spec.rb`, `spec/lain/telemetry/test_layout_spec.rb`,
`spec/lain/cli/epic_submit/adjudication_spec.rb`, `spec/lain/skill/role_spawn_spec.rb`, `spec/lain/cli/improve_spec.rb`

**Escalation triggers:**
- The guard's chronicle would journal a child's tool events onto the parent's tee, so a child's turn
  could retire the parent's inbox question. That is the collision round 15 fixed (`scribe.rb:249-256`);
  stop and design the child's own chronicle leg first.
- `ToolGuard.stack(chronicle, board)` must stay two arguments. If the layout can't ride the board
  without pushing `BoardBuild` past its cap, extract first.
- A refused write is still reported to the model as a success — stop.
- The board thunk needs a `wiring.rb` edit, and `wiring.rb` is T10's this wave — stop and hand the
  orchestrator a one-line wiring diff.

### T12 — Land issues serially onto the epic branch, and finish an epic as one PR   [wave 3] [risk: high]

**Depends on:** T3, T7, T8
**Files:** `lib/lain/isolation/landing_queue.rb` (new), `lib/lain/forge/local_landing.rb` (new),
`lib/lain/cli/epic_land.rb`, `lib/lain/cli/epic_finish.rb` (new), `lib/lain/forge/landing.rb`,
`lib/lain/forge/promotion.rb`, `spec/lain/isolation/landing_queue_spec.rb` (`:seam`),
`spec/lain/forge/local_landing_spec.rb`, `spec/lain/cli/epic_land_spec.rb`, `spec/lain/cli/epic_finish_spec.rb`,
`spec/lain/forge/landing_spec.rb`, `spec/lain/forge/promotion_spec.rb`
**Reuse:** `Handback` with `MergeStrategy` and `WorkingBranch.epic` (T5); `git merge-tree --write-tree`;
`SelfSync` (T7) as the per-worker re-sync callback; `WorkerHandoff::Resolver` (`worker_handoff.rb:187-213`);
`Report` as the per-worker result; `Landing::Transition` (`forge/landing/transition.rb:45`); `EpicLand`'s
`--resume`; `Forge::Promotion`/`Landing`/`Gh` and the intent/outcome reconcile; `TestLayout::Guard` (T8)
**Shared-file wiring:**
- `lib/lain/isolation.rb`: `require_relative "isolation/landing_queue"`.
- `lib/lain/forge.rb`: `require_relative "forge/local_landing"`.
- `lib/lain/cli.rb`: `require_relative "cli/epic_finish"`.
- `exe/lain`: `land`'s arguments become `ISSUE_ID [SLUG]`, since the SHA now comes from the handback,
  and a `finish SLUG` command is added.

**Reachable from:** `lain epic land ISSUE [SLUG]` and `lain epic finish SLUG`; the driver (T16)

Parts, in order:
1. **The landing queue**, following `merge-conflict-handling.md` and the 2026-09-11 rulings:
   1. Probe each queued worker in landing order and land every fast-forward or clean merge,
      re-probing after each.
   2. **While more than one worker is waiting to land, don't ask a stale worker to re-sync.** Land
      everything that still integrates, then ask each stale worker once against the final tip, bounded
      by `rebase_retries`.
   3. Whatever still conflicts goes to **one** resolver, given the intended order.
   4. Verify once.
   Each landing journals its `Report`. The queue takes **anchored** worker refs and is the **only**
   thing that merges on the epic path; nothing reaches the working branch before its implementation
   gate.
2. **Local issue landing.** This replaces the per-issue promote-and-PR path (no back-compat).
   - Requires the issue's implementation gate approved over the worker's SHA.
   - Runs the layout guard over the files in the diff, which catches `bash`-written tests.
   - Lands through the queue onto `epic/<slug>` and writes `in_flight → done`.
   - Pushes nothing.
3. **`lain epic finish`.** Once every issue is done:
   - Promote `epic/<slug>` as one remote branch.
   - Open and merge one PR to `main`.
   - Delete the remote branch once merged, never forcing it.
   - The local branch is left for GC (T9).

```gherkin
Scenario: re-sync waits until the queue drains, and leftovers share one resolver
  Given w1, w2 and w3 queued, where w1 landing makes w3 stale and w3 still conflicts after its re-sync
  When the queue runs
  Then w2 lands before w3 is asked to re-sync, w3 is asked exactly once, one merge_resolver is spawned, and verification ran once

Scenario: the parent must be standing on the working branch
  Given a parent checkout on a different branch
  When the queue starts
  Then it refuses naming both branches

Scenario: an approved issue lands locally and is done
  Given issue a in_flight with an approved implementation gate over worker SHA S
  When "lain epic land a demo" runs
  Then epic/demo contains S, a is done, and nothing was pushed

Scenario: an unapproved issue, or a misplaced test in the diff, blocks the landing
  Given issue b with no approved implementation gate, and issue c whose diff adds spec/order_extra_spec.rb describing Order
  When each is landed
  Then b is refused naming the gate, c is refused listing the file and its right path, and epic/demo is unchanged

Scenario: a crash mid-landing resumes
  Given a landing interrupted after the merge and before the transition
  When "lain epic land a demo --resume" runs
  Then a is done and the merge is not repeated

Scenario: a finished epic becomes one PR, and an unfinished one is refused
  Given epic demo with every issue done, and separately epic other with issue b in_flight
  When "lain epic finish" runs for each against a fake forge
  Then demo's one PR to main is opened and merged and its remote branch deleted, and other is refused naming b
```
→ spec files: `spec/lain/isolation/landing_queue_spec.rb`, `spec/lain/cli/epic_land_spec.rb`,
`spec/lain/forge/local_landing_spec.rb`, `spec/lain/cli/epic_finish_spec.rb`, `spec/lain/forge/landing_spec.rb`,
`spec/lain/forge/promotion_spec.rb`

**Escalation triggers:**
- The doc verified `merge-tree --write-tree` on git 2.43, and this box has 2.55. Re-verify the parse; if
  the output differs, stop.
- `Forge::Reconcile`'s intent/outcome records assume a remote effect. If local landing needs a new intent
  kind to stay resumable, stop and propose it.
- `spec/lain/forge/landing_spec.rb:138` pins the per-issue PR path, which this card removes. If another
  caller still needs it, stop.
- "Already deleted by GitHub" counts as success for the remote-branch delete; any other forge answer —
  stop.

### T13 — Actors that can run a plan, and be retired when done   [wave 4] [risk: high]

**Depends on:** T7, T11
**Files:** `lib/lain/role/catalog.rb`, `lib/lain/cli/wiring/toolset_build.rb`, `lib/lain/tools/subagent.rb`,
`lib/lain/supervisor.rb`, `spec/lain/role/catalog_spec.rb`, `spec/lain/cli/wiring/toolset_build_spec.rb`,
`spec/lain/tools/subagent_spec.rb`, `spec/lain/supervisor_spec.rb`, `spec/lain/supervisor_reactor_spec.rb`
**Reuse:** `Role#attenuate` (`role.rb:23`); `descend`/`child_union` (`subagent.rb:154-157,1054-1057`);
`Agent::Budget` and `GoalDriver::Run`'s own cap (`cli/goal_driver.rb:150`) as precedent; `Actor#settle`
(`subagent/actor.rb:95-102`) as the completion promise; `SelfSync` (T7) and `WorkerHandoff#surrender`'s anchor-only shape (`worker_handoff.rb:245`); the
farewell's `stopped` lifecycle (`telemetry/spawn_lifecycle.rb:25-35`)
**Shared-file wiring:** none
**Reachable from:** `ToolsetBuild#epic_subagent` (this card), called by the epic driver factory in
`CLI::Wiring` (T16), is the only construction that grants the role; `Supervisor#retire` is called by the
driver (T16)

Parts, in order:
1. **`issue_orchestrator`.**
   - The role holds the dev tools plus `subagent` and `run_skill`.
   - It is granted only through an epic-scoped Subagent with max depth 2 and a descending Subagent in
     the child's union. Its own children (implementers, reviewers) cannot spawn.
   - It carries a 200-iteration budget, because a whole plan runs in one `ask`.
   - The ordinary chat floor is unchanged.
   - `ToolsetBuild#epic_subagent` constructs that depth-2 Subagent from the run's spawn seam (`spawn_seam`,
     `toolset_build.rb:301`). `RoleSpawn`'s `@seam` has no reader, so the seam comes from here, not
     through `RoleSpawn`.
2. **`Supervisor#retire(registration)`.**
   - Await settle, self-sync, then **anchor and release** (the `surrender` shape) and stop. It returns
     the `Report` with the anchored ref and full SHA.
   - Retirement never merges. On the epic path the landing queue (T12) is the only merge, and it runs
     after the implementation gate.
   - The farewell makes the fleet and windows read the actor as terminal.
   - Mark the row so `#stop` skips it.
   - `adopt`'s signature does not change.

```gherkin
Scenario: an issue orchestrator fans out exactly one level
  Given an epic Subagent granting issue_orchestrator
  When its child spawns a dev grandchild, and that grandchild tries to spawn
  Then the grandchild runs and the third level is refused with "subagent spawn depth exceeded"

Scenario: a chat-built toolset constructs the epic Subagent
  Given a chat built by CLI::Wiring
  When its toolset build is asked for the epic Subagent
  Then that Subagent grants issue_orchestrator at depth 2, and the chat's own research Subagent still does not

Scenario: an ordinary chat child still cannot spawn, and the orchestrator has room for a plan
  Given a chat built by CLI::Wiring, and an issue_orchestrator child
  When the research subagent tries to spawn, and the orchestrator's budget is read
  Then the spawn is refused, and the budget allows 200 iterations

Scenario: a settled actor's work lands and it leaves the fleet
  Given an adopted actor whose first turn committed in its worktree
  When it is retired
  Then its commits are anchored and the SHA returned, the parent checkout is unchanged, a farewell with lifecycle stopped is journaled, and the fleet no longer counts it

Scenario: stop does not retire twice, and a failed actor is surrendered
  Given one retired registration and one actor whose first turn raised
  When the second is retired and the supervisor stops
  Then the failed actor's work is anchored with no resolver, and no second handback or farewell is written for the first
```
→ spec files: `spec/lain/tools/subagent_spec.rb`, `spec/lain/role/catalog_spec.rb`,
`spec/lain/cli/wiring/toolset_build_spec.rb`, `spec/lain/supervisor_spec.rb`, `spec/lain/supervisor_reactor_spec.rb`

**Escalation triggers:**
- The role roll-call spec, or the capability layering at `toolset_build.rb:326-328`, refuses a role that
  names `subagent` — stop. The grant must come from the epic seam, never from the floor.
- `subagent_spec.rb:880` ("never raises a tighter ceiling"): the epic seam sets depth 2 at construction
  and never raises an inherited ceiling. If it can't, stop.
- `supervisor_reactor_spec.rb:~344` pins refusal text byte-for-byte; don't reword it.
- Restart (`supervisor/restart.rb:196-201`) would re-adopt a retired row — stop; retirement must survive
  replay.

### T14 — A live `lain://status` buffer: fleet, progress and the issue graph   [wave 4] [risk: medium]

**Depends on:** T4, T10
**Files:** `lib/lain/frontend/neovim/status_view.rb` (new), `lib/lain/frontend/neovim/buffers.rb`,
`lib/lain/frontend/neovim/surfaces.rb`, `lib/lain/frontend/neovim.rb`, `lib/lain/cli/repl.rb`,
`lib/lain/cli/wiring.rb`, `lib/lain/frontend/neovim/runtime/00_constants.lua`,
`lib/lain/frontend/neovim/runtime.lua`, `spec/lain/frontend/neovim/status_view_spec.rb`,
`spec/lain/frontend/neovim/surfaces_spec.rb`, `spec/lain/frontend/neovim_runtime_spec.rb` (`:nvim`),
`spec/lain/frontend/neovim_buffers_spec.rb` (`:nvim`)
**Reuse:** the `lain://workspace` view (`buffers.rb:19,282-288`) as the exemplar; `CLI::Epic#progress` and
`Epic::Mermaid` (T4); `StatusFeed::Fleet`; `EpicMount#slug` (`epic_mount.rb:128`)
**Shared-file wiring:** `require_relative "neovim/status_view"` in `lib/lain/frontend/neovim.rb`
**Reachable from:** `lain chat --epic SLUG` with an editor attached (`lain up --nvim`) →
`Repl#attach_editor` → `Neovim.new(epic:)` → `Surfaces`

- The epic slug is threaded Wiring → Repl → Neovim → Surfaces.
- The view re-folds from disk when an epic record or a turn arrives, and skips the redraw when nothing
  changed. Issue and gate records are written by other processes.
- Content: the fleet, the progress text, and a mermaid fence. The filetype is `markdown`, so
  `snacks.image` renders the fence.
- A fold error is drawn into the buffer, never raised.
- With no epic mounted, the buffer says so.
- `PROTOCOL` goes from `"14"` to `"15"` on both sides.

```gherkin
Scenario: the buffer shows the epic's graph and fleet
  Given a chat mounted on epic demo with an editor attached
  When the status buffer is primed
  Then it contains demo's progress, a mermaid fence of its issues, and the fleet

Scenario: a transition written by another process appears
  Given the buffer showing issue a pending
  When lain epic submit approves a's issue_plan from another process and a turn completes
  Then the buffer shows a in_flight

Scenario: a corrupt journal is drawn, not raised, and no epic says so
  Given a journal line that fails the fold, and separately a chat with no --epic
  When each buffer refreshes
  Then the first shows the error while the other views keep updating, and the second says no epic is mounted
```
→ spec files: `spec/lain/frontend/neovim/status_view_spec.rb`, `spec/lain/frontend/neovim/surfaces_spec.rb`,
`spec/lain/frontend/neovim_runtime_spec.rb`, `spec/lain/frontend/neovim_buffers_spec.rb`

**Escalation triggers:**
- A line containing `\n` reaches `RenderQueue#post_view`, which refuses it (`rpc_thread.rb:~291`); split
  the mermaid source per line.
- `spec/support/tags.rb` silently excludes `:nvim` where nvim is missing. Report the `:nvim` example count
  so a skip isn't read as a pass.
- A refresh over a realistic epic exceeds 100 ms — stop and propose a watermark.
- The view refreshes on the drain thread. Rescue every fold error inside `StatusView` and draw it; never
  let it reach `neovim.rb:460-465`'s thread-death rescue, which would take every view dark.
- `Wiring` (112/125), `Repl` (109/125) or `Neovim` (104/125) crosses its `Metrics/ClassLength` cap —
  extract, never raise it.

### T15 — Launch an issue as an actor running `execute-plan`, after its failing tests exist   [wave 5] [risk: high]

**Depends on:** T3, T5, T8, T13
**Files:** `lib/lain/skill/role_spawn.rb`, `lib/lain/tools/subagent.rb`, `lib/lain/cli/epic_driver.rb` (new
index), `lib/lain/cli/epic_driver/issue_tests.rb` (new), `lib/lain/cli/epic_driver/issue_actor.rb` (new),
`spec/lain/skill/role_spawn_spec.rb`, `spec/lain/tools/subagent_spec.rb`,
`spec/lain/cli/epic_driver/issue_tests_spec.rb`, `spec/lain/cli/epic_driver/issue_actor_spec.rb`
**Reuse:** `RoleSpawn#call` (`role_spawn.rb:48-50`); `Gherkin::TestGeneration` placed by the layout (T8);
`Supervisor#adopt(role:, worker_id:, &launch)` (`supervisor.rb:109`) with the block returning
`launch_actor(prompt, parent:, worker_env:)` (`subagent.rb:132-143`); `library.renderer.render("execute-plan")`;
`Epic::Home#plan(id)` (`home.rb:108`). The epic Supervisor (base-pinned on `epic/<slug>`) and the epic
Subagent are **injected**: T16's factory and T13's `epic_subagent` construct them
**Shared-file wiring:** `require_relative "cli/epic_driver"` in `lib/lain/cli.rb` after `epic_land`
**Reachable from:** the driver loop (T16) → `/implement-epic`

Parts, in order:
1. **Tests in a held worktree.** `RoleSpawn` accepts a `worker_env:` that bypasses `Leases#hold`
   (`subagent.rb:246-249`), so a `test_engineer` child runs in the issue's held worktree. `IssueTests` runs `TestGeneration` over the issue's approved criteria there
   and commits the failing tests as the TDD red step. This makes `Gherkin::TestGeneration` reachable for
   the first time.
2. **The issue actor.** In the adopted lease, run the test step, then launch an `issue_orchestrator`
   actor seeded with:
   - the rendered `execute-plan` skill;
   - the path to `plans/<id>.md`;
   - the approved criteria and the generated test paths;
   - the instruction to rebase onto the working branch before settling.

   Under `--windows`, each issue gets its own tmux window at no extra cost.

```gherkin
Scenario: tests are generated in the held worktree and fail
  Given an issue with two approved criteria and a lease over layout_mini
  When the issue test step runs
  Then the tests exist at the layout's paths in that worktree, are committed, and fail when run

Scenario: a held worktree is reused, not re-leased
  Given a RoleSpawn call with the issue's worker_env
  When the test_engineer child runs
  Then no second lease is acquired and the child's cwd is the held worktree

Scenario: a role spawn without a worker_env behaves as before
  Given a RoleSpawn call with no worker_env
  When a child runs
  Then its cwd is the session's

Scenario: an issue actor starts on the epic branch's tip, with its plan, after its tests
  Given epic demo with issue a's issue_plan approved
  When the issue actor for a launches
  Then its worktree HEAD descends from epic/demo's tip, the test step's commit precedes the first actor turn, its role is issue_orchestrator, and its prompt names plans/a.md and a's criteria

Scenario: an issue without an approved plan is not launched
  Given issue b whose issue_plan is parked
  When the issue actor for b is asked to launch
  Then it refuses naming b's issue_plan
```
→ spec files: `spec/lain/cli/epic_driver/issue_tests_spec.rb`, `spec/lain/cli/epic_driver/issue_actor_spec.rb`,
`spec/lain/skill/role_spawn_spec.rb`, `spec/lain/tools/subagent_spec.rb`

**Escalation triggers:**
- The generated tests pass on generation (nothing was red) — record it and stop; the criteria or the
  generation are wrong.
- The `adopt` block needs anything beyond the injected epic Supervisor's own isolation — stop. OM-6
  consumers pin `adopt`'s signature.
- The seeded prompt exceeds the provider window before the plan is read — stop and report the sizes.

### T16 — The epic driver, behind `/implement-epic`   [wave 6] [risk: high]

**Depends on:** T3, T10, T12, T13, T14, T15
**Files:** `lib/lain/cli/epic_driver/factory.rb` (new), `lib/lain/cli/epic_driver/run.rb` (new),
`lib/lain/cli/command/implement_epic.rb` (new), `lib/lain/cli/command/surface.rb`, `lib/lain/cli/command/env.rb`,
`lib/lain/cli/wiring.rb`, `spec/lain/cli/epic_driver/factory_spec.rb`, `spec/lain/cli/epic_driver/run_spec.rb`,
`spec/lain/cli/command/implement_epic_spec.rb`, `spec/lain/cli/command/surface_spec.rb`,
`spec/lain/cli/command/env_spec.rb`, `spec/lain/cli/wiring_spec.rb`
**Reuse:** `Progress.fold` + `#ready`; `IssueActor` (T15); `Supervisor#retire` (T13); in-process `EpicSubmit`
(T3) for the implementation gate over the produced SHA; the landing queue and `LocalLanding` (T12);
`Command::Surface`'s `supervisor:`/`role_spawn:` (`surface.rb:42-44`) and the command group T10 extracted;
`GoalDriver`'s interrupt and cap
**Shared-file wiring:** `require_relative "epic_driver/factory"` and `"epic_driver/run"` in
`lib/lain/cli/epic_driver.rb`; `spec/support/command_env.rb`: a default for the new `Env#epic_driver`;
`require_relative "command/implement_epic"` in `lib/lain/cli/command.rb`
**Reachable from:** `exe/lain` → `ChatLaunch` → `CLI::Wiring`, which builds `EpicDriver::Factory` from
`epic_mount` → `Wiring#assemble_surface` → `Env#epic_driver` → `/implement-epic` at the `you>` prompt of
`lain chat --epic SLUG`

**The factory** is built by `Wiring`, and only when an epic is mounted:
- It uses a **dedicated** Supervisor over `Worktree.new(base: WorkingBranch.epic(slug))`, never the chat's
  `fleet_isolation`. So the epic always isolates in worktrees, whatever `--isolation` says.
- It carries the chat's journal, the anchor-only retirement (T13), and `toolset_build.epic_subagent`
  (T13).
- `Env` gains `epic_driver`. With no epic mounted it is a refusing Null, never `nil`.

The loop:
1. Fold, and launch issue actors up to a width (default 2) for issues that:
   - are in flight with an approved plan,
   - have no live actor,
   - and have every blocker done.
2. As each actor settles: retire it (anchor, never merge), submit its implementation gate over the SHA
   retirement returned, and land it through the queue, which is the only merge.
3. Refold, so newly unblocked issues start.
4. Stop when nothing is runnable.

Issues waiting on an `issue_plan` are reported, not planned; the human plans them. The run has a
whole-run budget, and grading can hook in between settle and retire (for T17). `/implement-epic` runs
this for the mounted epic, reports issues as they land, honours the goal driver's interrupt, and refuses
by name when no `--epic` is mounted.

```gherkin
Scenario: a two-issue chain runs in dependency order from the chat
  Given a chat built by CLI::Wiring with --epic demo, where a blocks b, both issue_plans approved, and scripted actors
  When the human runs /implement-epic
  Then a lands on epic/demo before b's actor launches, b's worktree contains a's landed SHA, both end done, and the reply lists them

Scenario: nothing reaches the working branch before its gate
  Given an actor for issue a that settled with commit S, and a's implementation gate parked
  When the driver retires a
  Then S is anchored, epic/demo does not contain S, and the parent checkout is unchanged

Scenario: width bounds concurrency
  Given three independent runnable issues and width 2
  When the driver runs
  Then at most two actors are live at once

Scenario: an issue without an approved plan is reported and skipped
  Given issue c pending with a parked issue_plan
  When the driver runs
  Then c is reported as waiting on its plan and no actor launches for it

Scenario: the whole-run budget stops the loop cleanly
  Given a budget that allows one issue
  When the driver runs over two
  Then one lands and the run stops, naming the budget

Scenario: no epic mounted
  Given a chat with no --epic
  When the human runs /implement-epic
  Then it refuses naming --epic
```
→ spec files: `spec/lain/cli/epic_driver/run_spec.rb`, `spec/lain/cli/epic_driver/factory_spec.rb`,
`spec/lain/cli/command/implement_epic_spec.rb`, `spec/lain/cli/command/surface_spec.rb`,
`spec/lain/cli/command/env_spec.rb`, `spec/lain/cli/wiring_spec.rb`

**Escalation triggers:**
- The implementation gate is interactive and would park the loop. The driver must keep other issues
  moving; if the gate's asker blocks the reactor, stop.
- A settled actor produced no commit — don't submit an empty implementation. Report it and stop that
  issue.
- The command blocks the REPL with no interrupt — stop.
- `Wiring` crosses `Metrics/ClassLength` building the factory. The factory is its own object: extract
  more, never raise the cap.

### T17 — The four altitude arms, and `lain bench altitude`   [wave 7] [risk: high]

**Depends on:** T6, T8, T16
**Files:** `lib/lain/arm/one_shot.rb` (new), `lib/lain/arm/plan_only.rb` (new), `lib/lain/arm/epic.rb` (new),
`lib/lain/grader/lease_harness.rb` (new), `lib/lain/bench/altitude.rb` (new), `lib/lain/bench/live_arms.rb`,
`lib/lain/bench/arm_sweep.rb`, `lib/lain/bench/cli.rb`, `spec/lain/arm/one_shot_spec.rb`,
`spec/lain/arm/plan_only_spec.rb`, `spec/lain/arm/epic_spec.rb`, `spec/lain/grader/lease_harness_spec.rb`,
`spec/lain/bench/altitude_spec.rb`, `spec/lain/bench/live_arms_spec.rb`, `spec/lain/bench/arm_sweep_spec.rb`,
`spec/lain/bench/cli_spec.rb`, `spec/fixtures/altitude/**` (new: tasks on a size axis, each with a subject
project, per-issue criteria and an epic fixture)
**Reuse:** `Arm` (`arm.rb:60,125`) and `SingleThread` with a real toolset; `IssueActor` (T15) for plan-only;
the driver (T16) as the epic arms' body; `Arm::Ladder`, `RecordedPolicy`, `HandsOff` and `EpicMetrics` (T6);
`Grader::TestHarness#grade(worker_env)` and `#run(paths:)` (T8); `Arm::Driver` (needs at least two tasks,
`driver.rb:75`); `bench/cli.rb`'s cost warning (`:134-139`)
**Shared-file wiring:**
- `lib/lain/arm.rb`: `require_relative "arm/one_shot"`, `"arm/plan_only"` and `"arm/epic"`.
- `lib/lain/grader.rb`: `require_relative "grader/lease_harness"`.
- `lib/lain/bench.rb`: `require_relative "bench/altitude"`.
- `exe/lain`: an `altitude FIXTURE` command in the `Bench < Thor` block, and the "three arms" help text
  at :529 updated.

**Reachable from:** `LiveArms.build` → `lain bench arms`; `lain bench altitude FIXTURE`

Parts, in order:
1. **The lease grader.** It adapts the harness to the arm grader duck: bound to a lease's `worker_env`
   and a level root, rolled up per issue.
2. **The arms.**
   - One-shot enters at implementation, with no gates.
   - Plan-only runs create-plan, then execute-plan in an issue actor, with no epic.
   - The epic arm has two ladder entries:
     - progressive: the human's policy map, or replayed with `RecordedPolicy`;
     - hands-off: `HandsOff` at every gate.
3. **`lain bench altitude`.**
   - Runs the four arms over the fixture suite and reports, per task size, score, tokens, cache-write,
     wall time, rework and round-trips.
   - Warns that it spends real money before it starts.

```gherkin
Scenario: an arm's run is graded by the subject's own suite, before retirement
  Given a lease over a fixture subject with one failing and two passing unit examples
  When the lease harness grades the arm's timeline
  Then the grade is 2 of 3 for the unit root and the worktree still existed when graded

Scenario: one-shot has no gates, plan-only has no epic
  Given a task, a scripted provider and scripted actors
  When the one-shot and plan-only arms run
  Then the one-shot run journals no gate decision, and the plan-only run wrote a plan and ran it in an issue actor with no epic

Scenario: hands-off runs the whole ladder with no human, and progressive replays recorded answers
  Given an epic fixture, scripted actors and recorded gate decisions
  When the hands-off and progressive arms run
  Then every hands-off decision has policy hands_off, progressive's decisions match the recording, and both report rework and round-trips

Scenario: the altitude report compares arms per task size and warns first
  Given a two-task fixture and scripted arms
  When lain bench altitude runs
  Then the cost warning precedes the first arm, and the report has one row per arm per task size with every metric, unmeasured ones saying so
```
→ spec files: `spec/lain/grader/lease_harness_spec.rb`, `spec/lain/arm/one_shot_spec.rb`,
`spec/lain/arm/plan_only_spec.rb`, `spec/lain/arm/epic_spec.rb`, `spec/lain/bench/altitude_spec.rb`,
`spec/lain/bench/live_arms_spec.rb`, `spec/lain/bench/arm_sweep_spec.rb`, `spec/lain/bench/cli_spec.rb`

**Escalation triggers:**
- `SuiteGrader` matches runs to tasks by prompt text (`bench/cli.rb:385-417`). Give fixture tasks ids;
  if that needs `Arm::Driver`'s `tasks:` shape to change, stop.
- A report spec pins the old three-arm roster — stop.
- `bench/altitude.rb` loads with `bench` (`lib/lain.rb:82`), before `grader`, `epic` and `arm`, so it
  must not reference an `Epic::`, `Arm::` or `Grader::` constant at class-body time.
- Artifacts regenerated by a live arm are not byte-identical to the recorded ones, so every replay
  refuses — record the finding and stop; never fall back to approving.

### T18 — Teach the epic skills their doors, and document what the chunk made reachable   [wave 8] [risk: low]

**Depends on:** T4, T9, T11, T12, T14, T16, T17
**Files:** `lib/lain/prompt/templates/skill/research-epic/skill.md`,
`lib/lain/prompt/templates/skill/plan-epic/skill.md`,
`lib/lain/prompt/templates/skill/create-epic-issues/skill.md`,
`lib/lain/prompt/templates/skill/iterate-epic/skill.md`, `lib/lain/cli/wiring/agent_build.rb` (the stale
comment at :68-77 only), `spec/lain/skill/shipped_skills_spec.rb`, `spec/docs_naming_spec.rb`,
`docs/commands.md`, `README.md`, `planning/qa/scenarios/epic-tier.md`, `planning/merge-conflict-handling.md`,
`planning/specs/spec-naming-guard.md`, `planning/specs/chunk-undo-reachability.md`,
`planning/epic-orchestration.md`, `ROADMAP.md`
**Reuse:** the exact command spellings from `exe/lain`; `chat_flags_spec.rb` (every flag the code reads is
declared); ruling 7 (skills stay thin, the loop stays in `lib`)
**Shared-file wiring:** none
**Reachable from:** the skill library rendered by `lain chat` (`/research-epic` and the other epic
skills); the rest is documentation

Parts, in order:
1. **Skills.**
   - Each epic skill names the `lain epic submit` stage it ends at.
   - `iterate-epic` uses `lain epic split|merge|add` instead of re-emitting `epic.md`.
   - `create-epic-issues` says criteria are approved together with each issue's plan.
   - Skills point at `/implement-epic` and `lain epic finish`.
2. **Docs.** Document:
   - the commands: `/undo`, `/implement-epic`, `lain worktrees gc`, `lain epic add|split|merge|finish`,
     `lain epic status --mermaid`, `lain bench altitude`;
   - the `[isolation]` and `[tests]` tables;
   - the `lain://status` buffer;
   - the epic-tier scenario, rewritten for issue-scoped gates, local landing and the driver.

   Set the four source docs' status lines to what landed, and delete the stale "the guard does not reach
   subagents" comment.

```gherkin
Scenario: every epic skill names how its stage advances, and every command it names exists
  Given the four shipped epic skills, rendered
  When their "lain epic <verb>" mentions are collected
  Then each skill names the submit stage it ends at, and each verb is a registered command

Scenario: every new command and config key is documented
  Given the registered commands, the Thor subcommands, Config::Isolation and TestLayout
  When docs/commands.md is read
  Then each command added by this chunk appears with its flags, and every [isolation] and [tests] key appears with its default
```
→ spec files: `spec/lain/skill/shipped_skills_spec.rb`, `spec/docs_naming_spec.rb`

**Escalation triggers:**
- A skill would need to describe loop control (when to land, when to finish) to work. That belongs in the
  driver; stop.
- A behaviour the docs would describe didn't land as planned — document what exists, not the plan.

## Integration checks

1. **Suite, by count.** `bundle exec rake pspec`, with nothing else running per CLAUDE.md: 0 failures.
   The example COUNT must equal the pre-step baseline plus added minus deleted: T2's relocation is
   neutral, and T3 deletes one spec file. Record the `:nvim` and `:seam` counts separately.
2. `bundle exec rubocop` clean with **zero diff to `.rubocop.yml`**; `pre-commit run --all-files` green.
   No Rust is touched, so `cargo` isn't required unless a card does.
3. `DryReplay` over the recorded fixtures stays byte-identical. Record shapes widened in T1, T3 and T5.
4. **Manual — undo** (the modes chunk's owed checks), in a real cockpit:
   - In `accept_edits`, let a tool write files, then `/undo`: the files are restored.
   - Run a `bash` command that creates and deletes files no lain tool touched, then `/undo`: the tree is
     restored and `git status` is exactly as before.
   - Run `/mode plan`, then grade the journal: steering reports the post-flip set.
5. **Manual — worktrees**, on a feature branch with `--isolation worktree`:
   - A dev child's commit comes back as a fast-forward.
   - A conflicting sibling self-syncs, then reaches the resolver.
   - After merging to `main`, `lain worktrees gc` reaps the anchors.
   - A stale stamp makes the next launch spawn one detached run.
6. **Manual — epic end to end.** Drive `planning/qa/scenarios/epic-tier.md` as rewritten by T18 on a
   2–3 issue fixture epic against a local model. It has never been driven. Cover:
   - adjudicated research (§5d);
   - an issue-scoped `issue_plan` carrying criteria;
   - `/implement-epic` with `--windows`, and the `lain://status` buffer updating live with mermaid;
   - local landing;
   - `lain epic finish` against a throwaway GitHub repo.
7. **Manual — test layout**, on a target fixture project with `[tests] preset = "rspec"`:
   - A child's split-sibling write is refused, naming the right path.
   - A test file written by `bash` in the wrong place blocks `lain epic land`.
8. **Manual — altitude.** One `lain bench altitude` run on the smallest fixture. It costs real money;
   the human picks the model.

**What the consolidation trades:** 18 cards in 8 waves instead of 47 in 10. Each card is one capability
with its parts ordered, so a card review now covers several responsibilities at once, and most cards are
high risk. The critical path still runs through `tools/subagent.rb` four times (T7, T11, T13, T15), and
that file is the most likely to push back.

## What the panel changed (2026-09-11)

The Ruby roster, with TJ DeVries on T14 and Kmett and Wadler on T6, returned **REQUEST-CHANGES**. It
verified every grounding premise it spot-checked. Every finding below was applied.

**Blockers:**
- **B1 — the issue actor was never cut from `epic/<slug>`.** Traced from `exe/lain`, `/implement-epic`
  reached the chat's one Supervisor over `fleet_isolation`, and `Env` never carried the slug.
  - Fix: T16 builds a dedicated epic Supervisor over `Worktree.new(base: WorkingBranch.epic(slug))` in a
    factory `Wiring` owns, and exposes it as `Env#epic_driver`.
  - New ACs: b's worktree contains a's landed SHA; a parked gate keeps S off the branch.
- **B2 — retirement merged work before its implementation gate, and merged it twice.**
  - Fix: T13's `retire` anchors and releases (the `surrender` shape) and returns the SHA.
  - The landing queue (T12) is now the only merge on the epic path.
- **B3 — T2 and T3 both needed `signoff_queue.rb` in wave 1.**
  - Fix: T3 owns the queue, the `Partition` and the Null duck, and moved to wave 2 after T2.
  - The canary AC moved into T3.

**Should-fixes:**
- **S1 (T7):** added `toolset_build.rb` to T7, since `Leases` is built there, and resolved the resolver's
  construction cycle with a late-bound thunk.
- **S2 (T11):** the child guard is a board thunk; every `Seam.resolve` site is listed, and an out-of-chat
  AC was added.
- **S3 (T10):** the snapshot slot is born in `AgentBuild` and handed to the Switchboard, so T10 never
  touches T11's `board_build.rb`.
- **S4 (T6, T17):** added load-order triggers for `bench`.
- **S5 (T5):** added the arms' `Worktree` construction sites.
- **S6 (T6):** the ladder is a frozen Array. Its "laws" are two stated properties (suffix; visited
  stages equal on an all-approve run), not an algebra.
- **S7 (T13):** `ToolsetBuild#epic_subagent` constructs the depth-2 Subagent.

**Nits:**
- Metrics triggers on T10 and T14.
- The held-worktree no-second-lease AC on T15.
- `git mv` stated on T2.
- `StatusView` rescues its own folds (T14).
- A dirty-worktree scenario on T7.

## Execution log

- **2026-09-11, base.** Lands on `main`. Head `109a17e3`; `origin/main` is `b1927ce7`, 137 behind —
  never a base. The docs pre-step was already committed (`e74fd058`, `109a17e3`); `30e0f751..HEAD`
  touches only planning docs and ROADMAP, so the grounding holds as written.
- **Baseline suite:** `rake pspec` — **16788 examples, 0 failures, 14 pending**, 68 s wall (not the
  documented 21–27 s; nothing else was running).
- Worktrees are cut from the branch head into `tmp/worktrees/<card>`; each carries a copy of the
  compiled `lib/lain/lain.so` and its own `TMPDIR` under `~/tmp/lain/wt-<card>`.

Cards landed:
- **T2** `a3fbaa14`. Suite 16800 examples, 0 failures, 14 pending: T2 added 12 net, including the five duplicate workspace examples it deleted.
- **T1** `e038fc14`.
- **T4** `67fe1314`.
- **T6** `9aca31e9`. `RecordedPolicy` moved to `Approval::Gate::RecordedPolicy`, which answers the policy duck without subclassing `Policy`, because `shipped_skills_spec` pins `Policy.subclasses` as the configurable family.
- **T5** `b164b66b`. Merge flags `--ff --no-squash --commit --no-verify-signatures` are pinned; `landed` confirms the parent contains the worker; a handback declines when the parent is off the working branch; `base:` is required on `Handback` and `WorkerHandoff.over`; `Worktree#base` is forwarded by the lease decorators. Suite on main after it: **17006 examples, 0 failures, 14 pending**.
- **T3** `8f7fd7aa`. `Epic::InFlight` is the one rule that starts an issue, and both submit and the queue drain ask it. Approving an `issue_plan` from the wrong project refuses as `EpicQueue::OutsideProject`.
- **T8** `971f90ba`. `Verdict#rule` is machine-readable; `TestGeneration.new(renderer:, role_spawn:, guard:)`; enforcement is opt-in. The pre-commit example that failed, `neovim_runtime_spec`'s "parked approval … end to end", is the documented load flake, and passed alone.
- **T7** `9982c1d2`. One `WorkerHandoff` serves chat: SelfSync anchors first and checks each patch survives, handbacks run one at a time per parent, and the sync facts ride `Telemetry::Handback`. The pre-commit example that failed, `up_spec` "…one socket and one cwd", is the recorded load flake, and passed alone twice on T7's tree.
- **T9** `d4d424a5`. Suite 17114 examples, 0 failures, on T9's tree. Leases take a git worktree lock recording the owning process; gc claims a lock by renaming it, and acts only if the bytes are unchanged; `worktree.useRelativePaths` resolves; a stray claim file keeps the tree.
- **Follow-up** `6e7d07f9`: `Worktree#repo_root`, forwarded through the lease decorators. `Null#repo_root` searches from the root it was built with, and raises `NoRepository` when it has none. The chat handoff reads the backend's root, and no longer runs `rev-parse --show-toplevel`.
- **T12** `9f81a3c9`. Suite 17326 examples, 0 failures, on T12's tree. `Isolation::LandingQueue`, `Forge::LocalLanding`, `lain epic finish`, `Isolation::ParentLock` (shared with the chat handback). The pre-commit example that failed, the nvim parked-approval "wrapped command unwrapped", is the documented load flake, and passed alone. **Follow-up:** a merge whose handback record never reached the journal refuses both `land` and `--resume`, with no command to adopt it. It needs a way out, e.g. `lain epic land --adopt`.
- **T11** `5f2c1d6d`. Suite 17350 examples, 0 failures, on T11's tree. The spawn seam takes a required `tool_middleware:`, built by `ToolGuard.child_stack` or `ToolGuard.detached`; `ToolGuard::Inputs` rides the Switchboard; `WorkerEnv#checkout` comes from the lease. **T18 must delete** the stale "guard does not reach subagents" comment at `agent_build.rb:68`.
- **T10** `feba7cf9`. Suite 17392 examples, 0 failures, on T10's tree. `/undo` reverts the `diff-tree` rows between the per-turn tree pair; `/undo skip`; `SnapshotSlot`, rebound on a `/mode` flip that changes scope; `Revert`/`TreePair`/`Repository` extracted. Pre-commit failed on a YARD duplicate docstring for `SnapshotLog::Undo`, consolidated onto its reopen, and on the `annotate_spec` load flake.
- **T14** `229db3ce`. Suite 17676 examples, 0 failures, on T14's tree. `StatusView` and `CLI::Wiring::EpicSeat`; PROTOCOL 15, with `plugin/nvim/doc/lain.txt` updated to match; a fleet error is drawn, not raised. Pre-commit yard-lint failed twice, on `EpicSeat`'s `@option` tag and on two ```mermaid mentions in prose; both fixed.
- **T13** `ae6a5441`. Suite 17579 examples, 0 failures, on T13's tree. `ToolsetBuild#epic_subagent(isolation:, handoff:, lane:)`, `Supervisor#retire` (anchor-only, `Retirement::Anchor` compare-and-swap), `AlreadyRetired`/`AlreadyReleased`/`OutsideLease`, and the `issue_orchestrator` role. Pre-commit caught two yard issues, `WorkerHandoff#reclaim`'s tag order and a duplicate `Leases::Lane` docstring, both fixed, plus the vsock load flake.
- **T15** `591bf1dc`. Suite 17777 examples, 0 failures, on T15's tree. `IssueActor`, `IssueTests`, `PlanSubject`, `Leases::InPlace`, `WorkingBranch.owned`, and the `reviewer_code` role.
- **T16** `dd3b2a58`. Suite 17833 examples, 0 failures, on T16's tree. `EpicDriver::Factory`/`Run`, `/implement-epic`, `AskHuman#withdraw`, the driver's own landing checkout. **Small debt:** `Run#refused_before_merging?` lists refusal classes by hand, so a new one added later would wrongly advise `--resume`.
- **T17** `a32779d0`. Suite 17925 examples, 0 failures, on T17's tree. `LeaseHarness`, the four arms, `Bench::Altitude`, and the driver's grading seam. All four arms report a real score; the command that runs them is the deferred follow-up.

Load-sensitive examples. Each failed only while another agent's rspec was running, and passed when re-run on a quiet box:
- `Lain::Supervisor` actor reactor: "an actor's own captured Async::TimeoutError is not misread as the drain's bound".
- The `wire_marks <= 4` example in `role_prelude_wiring_spec` or `subagent_sibling_template_spec`.
- `Lain::CLI::Up` against a real tmux server: "--nvim cockpit splits the chat window into an nvim pane and a chat pane sharing one socket and one cwd".
- `lain.rb` without the compiled extension: "keeps Ruby's own LoadError message".

Rulings made during execution:
- **T6.** Rework folds on (epic, issue). Round-trips fold on (epic, stage, `issue_id`), with `issue_id`
  nil on a record that has none, so **T3 names the gate decision's issue field `issue_id`**. An
  unmeasured cache-write reads "not measured" in its own arm's cell, never for the whole column.
- **T1.** `toolset:` is required on `Mode::Switch#switch` and `Telemetry::ModeSwitch`, with the four
  fixture specs (status_feed, mode_state, compare, command/mode) updated. A `mode_switch` record
  written before T1 grades against the header.
- **T4.** Mermaid node ids are injective, and labels escape `& < > " #`. `epic.md` is written before
  the `graph_revision` is journaled, and that crash window is documented, not closed.
- **T2.** Carrier also overrides `validates_inclusion_of`. The duplicated examples in
  `workspace_spec.rb` are deleted, a deliberate reduction in the example count.
- **T5.** A fast-forward stays `kind: :merged` with a measured `fast_forward` field; no new Outcome
  kind. T5 takes `worker_handoff.rb` (`Report` carries `sha` and `fast_forward`; `.over` takes
  `strategy:`). The arms construct no `Worktree`; they get their base through `IsolationBackend`.
  **Open for T7 and T9:** release still deletes a worktree at once, so a *dirty* worker tree is lost
  on release and the `retain_days` retention has nothing to retain. T7 must not release a dirty tree
  it refused to rebase. A decorated lease (`DbIndex`, `Compose`) drops `Lease#origin`. The D/F ref
  conflict recurs **on the remote** for T12's `finish` if old per-issue branches survive there.
- **T9 (the liveness trigger fired), 2026-09-11.** Lain wrote no liveness record. The ruling:
  - Every worktree lease is added with `git worktree add --lock --reason "lain-lease pid= start= host="`.
    GC treats a lock whose host is this one, whose pid exists and whose start time matches as live.
    Any lock reason it can't read means keep.
  - Release keeps a *dirty* checkout, re-locked as `lain-retained since=`.
  - At expiry, GC anchors the committed HEAD, plus a temporary-index snapshot of any dirty state,
    under `refs/lain/worker/*` before it removes anything.
  - A marked `epic/<slug>` is deleted only when its tip differs from the marker's creation SHA, is
    an ancestor of `main`, and is checked out nowhere.
  - T9 takes `worktree.rb` and its spec. T7 must not touch release, and only journals that a tree
    was dirty.
- **Rulings from T3's review, for later cards:**
  - **T12:** `LocalLanding` must call the plan-approved check (`ensure_plan_approved!`) before it
    lands. An implementation parked before its plan was edited can still be approved from the queue.
  - **T11:** also takes `lib/lain/cli/epic_submit.rb`. Its `from_options` builds the adjudication pair
    and has to hand it a guard stack. The `**seam` bag in `epic_submit/adjudication.rb` becomes a
    named `tool_middleware:`.
  - **T3:** `RecordedPolicy`'s widening is done in T3 itself, not deferred. `InFlight` is
    at-least-once.
- **T8 rulings.**
  - The guard is pure: its `Verdict` carries a machine-readable `rule`. The callers set the policy.
    **T11's write-time middleware lets `:no_source` through**, with a journal note, because a test is
    written before its class. **T12's land-time check refuses `:no_source`.**
  - A test-named file outside every level root is refused as stray.
  - A refusal never names a path the guard itself refuses; a property spec holds this.
  - Mixed levels: a file's level is the root it sits in, and any example tagged for another level
    is refused.
- **T9 ruling, deferred:** anchors under `refs/lain/worker/*` that nothing reaches, the reaper's own
  included, are kept indefinitely. Expiring them waits for a later ruling. A lost worker commit
  costs more than the refs do.
- **Rulings from T7's review.**
  - Self-sync anchors the worker's original HEAD before any rebase, and verifies with `git cherry`
    that every patch survived.
  - Handbacks are serialized per parent checkout, through the resolver.
  - The sync facts ride `Telemetry::Handback`; the separate `worker_sync` record is dropped.
  - `MergeStrategy` pins `rerere.enabled=false`.
  - **Follow-up after T7 and T9 both land:** `Worktree#repo_root`, forwarded through
    `Journal`/`DbIndex`/`Compose`/`Null`, so the chat handoff stops deriving the root with
    `rev-parse --show-toplevel`. That derivation fails under `GIT_CEILING_DIRECTORIES`.
  - **For T13:** `Supervisor#adopt` hands an actor its raw lease environment. `retire`'s self-sync
    must run with the editorless environment the spawn lane uses.
- **Rulings from T9's review.**
  - gc re-reads a worktree's lock right before it acts, and acts only if the lock is byte-equal to
    the one it judged. It never unlocks a tree it judged unlocked.
  - A registration whose directory has vanished gets its HEAD anchored before it is pruned.
  - A failed dirty check counts as dirty.
  - Release anchors a clean checkout's unreached HEAD before it removes the checkout.
  - The snapshot records the index as a second parent. A tree holding a nested repository is kept,
    never removed. Ignored files are excluded, by design.
  - An epic branch being rebased in another worktree is kept.
  - gc runs take an `flock`.
  - A stray real stamp and log that gc wrote under `~/.local/state/lain/gc` during implementation
    were deleted. They had reaped nothing.
- **T8 re-review ruling: layout enforcement is opt-in.**
  - **T11's write-time middleware and T12's land-time check never pass `framework:`.** No `[tests]`
    table means `TestLayout::None`: no refusals, and one `test_layout_absent` record.
  - Detection only picks the harness command. A detected preset would impose `spec/{unit,seam,…}` on a
    project that never declared them, and refuse its existing flat specs as stray.
  - **For T15:** the issue test step refuses, naming `[tests]`, when the project declares no layout.
- **From T7's re-review, for later cards:**
  - **T12 and T16:** the handback lock is an in-process Monitor per `WorkerHandoff`. It does **not**
    serialize a `lain epic land` process against a live chat on the same parent checkout. The
    landing queue needs a lock across processes (an `flock` under the repo's git dir) when the two
    can run together.
  - The lock is held through the resolver, so `Supervisor#reap`/`#stop` waits for a resolver's
    model call.
  - Self-sync re-matches by authorship only commits that touched a conflicted path. An in-place
    gutting of a resolved commit is a documented limit.
- **T10 escalation, ruled 2026-09-11.** A ShadowGit snapshot is a delta: that turn's changes plus
  lain's writes. `Restore` treats a snapshot as the whole workspace, so undo as carded would delete
  files it should restore.
  - `/undo` reverts exactly the undone turn's delta, path by path. Each path gets the bytes of its
    latest earlier record; it is deleted if the baseline shows it was absent; and `/undo` refuses,
    naming the path, when that path has no earlier record. Paths outside the delta are never
    touched.
  - Under ShadowGit, one whole-tree baseline is taken before the first turn. It measured 0.48 s on
    lain's own tree.
  - The whole-workspace restore, and so `restart.rb`, is unchanged.
  - **Follow-up card:** record a file's bytes before its first write under `write_set`. Until then,
    undoing that first write refuses by name.
- **Rulings on T12's hand-back.**
  - The `implementation` artifact digest now composes the issue id, so an approval for one issue can
    never read as approval for another. That changes every implementation digest; no back-compat is
    owed.
  - One parent-checkout lock (an `flock` under the git common dir) is taken by both the landing queue
    and `WorkerHandoff`'s `one_at_a_time`.
  - The QA doc's old `lain epic land ISSUE SHA` is **T18's** to rewrite.
- **T11 escalation, ruled.**
  - T11 may make a minimal `switchboard.rb` edit, a `test_layout:` slot on `.for`/`new`, while T10
    owns the rest of that file. The orchestrator's three-way port resolves the overlap.
  - A worktree-isolated child's writes are checked against the root of the checkout they land in.
    The layout is repo-relative.
  - A child's `read_redacted` replaying as the parent's after `--resume` fails closed. It is a
    documented limit.
- **Orchestrator touch-up, after T10 lands:** `spec/spec_helper.rb` points `XDG_STATE_HOME` at a
  per-worker temp dir for the whole suite. Two cards this chunk (T9's stray gc and T10's shadow
  store) found specs writing into the real `~/.local/state`.
- **T11 review rulings.**
  - A child's checkout comes from its lease, never from finding a `.git` file on disk.
  - `Switchboard` holds one guard-inputs value, the duck `ToolGuard.stack` reads. The model switch
    goes back out of `#seed`, where it had moved only to satisfy MethodLength.
  - `UNGUARDED` moves to `spec/support/`.
  - Layout records are journaled only after the gate lets the write through.
  - **For T12:** an `edit_file` that changes a test's subject passes at write time and is caught at
    land time.
- **T10 review ruling, replacing the earlier baseline ruling.**
  - Every turn stages a before-tree at prime and an after-tree at settle. The pair is held in the
    in-process `SnapshotLog`; the `:snapshot` event and `restart.rb` are unchanged.
  - `/undo` reverts exactly the `git diff-tree` rows between the pair: adds, modifications,
    deletions and modes. It dirty-checks each path against the after-blob first, and refuses by name
    when a path fails.
  - Paths are normalized to UTF-8 in one place.
  - A refused `/undo` offers `/undo skip`.
  - A ShadowGit failure degrades that turn to `write_set`. Each session uses its own
    `GIT_INDEX_FILE`.
  - **Follow-ups:**
    - the cold first prime on large trees (3.86 s on 60k files);
    - the shadow store needs its own `gc`;
    - recording pre-images under `write_set`.
- **T12 review rulings.**
  - `nothing_to_do` counts as landed only when this issue's own merge is already journaled.
  - Finish steps settle on their action and their params, so a moved `epic/<slug>` tip is a new
    finish and a second PR.
  - A PR that is already `MERGED` reads as done.
  - Worker refs are required.
  - `ParentLock` names its holder.
  - `rebase_retries` is honoured as a count.
  - `BRANCH_DELETE` joins `Forge::ACTIONS`.
- **Toolchain trap found in this run.** CLAUDE.md's quiet check, `pgrep -f '[p]re-commit'`, matches any
  process whose command text holds the plain word, including another agent's background waiter.
  That left agents reading "busy" indefinitely.
  - The precise check is `pgrep -af '[p]re-commit (hook-impl|run)'`: a real hook runs as
    `pre-commit hook-impl …`.
  - **At close-out:** add this to `docs/toolchain-traps.md`, and propose the CLAUDE.md wording to the
    human.
- **T10 redesign departures, accepted.**
  - Chat A can write between chat B's prime and settle; B's `/undo` may then delete A's file. This is
    a documented limit, and the undo reply lists every deletion. **Follow-up:** coordinating across
    chats on one project.
  - A file the turn replaced with a directory is restored.
  - **Follow-ups:**
    - each session's first prime is cold, because every session has its own index;
    - the shadow store needs `gc` and pruning of dead session index files.
- **Follow-up from T10's re-review.** Planning `/undo` reads each changed blob with its own
  `git cat-file`: 45 s for a 2,005-path turn, with the REPL blocked. Use `cat-file --batch`, or compare
  blob ids computed in Ruby. This sits with the cold-prime and store-growth follow-ups.
- **Another load-sensitive example.** `annotate_spec` "a buffer that goes away drops the orphaned
  entry once it has settled it, so a reused bufnr inherits nothing" failed in T10's pre-commit run,
  then passed 3/3 alone on a quiet box.
- **T13 escalation, ruled. The issue orchestrator's children work inside the issue.**
  - Each issue actor's worktree is switched onto a lain-owned local branch, `lain/issue/<slug>/<id>`,
    marked under `refs/lain/owned/heads/`. GC reaps it once it reaches main.
  - The actor's children lease from a `Worktree` whose base is that branch, and hand back into the
    actor's checkout through a per-issue `WorkerHandoff` (`repo_root:` the actor's checkout, `base:`
    the issue branch). Nothing reaches the chat's checkout, and nothing reaches `epic/<slug>` before
    the issue's implementation gate.
  - **T13:** `ToolsetBuild#epic_subagent(isolation:, handoff:)`, both required.
  - **T15:** `IssueActor` creates the branch and builds that isolation and handoff.
  - **T16:** retirement anchors the tip of the issue branch.
  - A spec escaping its sandbox staged files in T13's worktree through an actor's commit tool; its
    index was reset. Specs now refuse to commit outside a temp directory.
- **T13: worker ids are unique per repository.** Every spawn lane counted from 1, and every worktree of
  a repo shares the `refs/lain/worker/<id>` anchors, so a second issue's handback could overwrite the
  first's. `epic_subagent` now also requires `lane:`, and the epic lane's worker ids carry it as a
  prefix. **T15** passes `issue.<slug>.<id>`.
- **T14's notes, for T16.**
  - The epic slug is threaded `Wiring#editor_seams` → `Repl#run(epic:)` → `Neovim.new(epic:)` →
    `Surfaces` → `Buffers` → `StatusView`, resolved once in the new `CLI::Wiring::EpicSeat`.
  - Build the driver factory from `epic_mount`, which is `epic_seat.mount`. Never call `EpicMount.for`
    twice: that would put a second review guard over one journal.
  - `Wiring#run` and `#build_toolset` each sit exactly at their AbcSize limit, and `Wiring` is at
    122/125, so extract before adding anything.
  - A `PROTOCOL` bump must also update `plugin/nvim/doc/lain.txt`.
  - **Follow-up:** `StatusView` takes 141 ms to refresh over 60k records; skip the re-fold when the
    session files haven't changed.
- **T13 review rulings, and what they leave for later cards.**
  - An adopted actor's `worker_id:` carries its issue lane; **T15 passes `issue.<slug>.<id>`**.
  - An anchor never moves to a commit that doesn't contain it: a compare-and-swap, refused loudly
    otherwise.
  - A lease HEAD already contained in `base.tip` retires as `nothing_to_do` with a nil SHA. **T16
    tests `report.sha.nil?`, never `kind`.**
  - A stopped actor is surrendered, not retired as settled.
  - A retired or released row raises.
  - `launch_actor` requires `worker_env:`, and `adopt` refuses an actor whose cwd isn't its lease's.
  - **For T15:** choose a role for the orchestrator's reviewing children (today every child is `dev`,
    with write tools). T15 also switches the actor's detached checkout onto its issue branch, which
    the issue handoff's target check requires.
  - **For T16:** `issue_orchestrator` is attended, so its tier-3 `bash` would park on the chat's
    approval gate during an unattended run. The driver has to decide the gate policy for actors.
- **From T13's re-review, for T15 and T16:** an actor's `worker_id:` carries its **attempt**, as in
  `issue.<slug>.<id>.<n>`. A retry under the same id is refused for as long as the first attempt's
  anchor stands, which is loud and loses nothing but blocks every retry. **T15** builds the id;
  **T16** increments `n` when it retries an issue. The anchor refusal is `kind: :failed` with a nil
  SHA, and **T16** stops that issue on it.
- **Another load-sensitive example:** `support_vsock_availability_spec` "VsockAvailability.available?
  leaks no descriptor across repeated probing". It failed in T13's pre-commit run and passed 2/2
  alone.
- **T15's subject gap, ruled: the issue's PLAN declares the subject.** `TestGeneration` places a test
  by mirroring a source file, and an `Epic::Issue` names none.
  - `plans/<id>.md` carries a `Subject:` line, and optionally `Level:`. The driver parses them.
  - Rejected: a field on the issue (it changes every issue digest for a fact that belongs to the
    plan), asking the model (a non-deterministic target path), and reading the criteria (Gherkin
    prose does not name files).
  - The `issue_plan` digest already covers the plan's content, so the subject is approved with the
    plan and editing it reopens the gate.
  - A missing, duplicated or out-of-root subject refuses by name; the path need not exist yet, since
    a test written before its class is the normal case.
  - **T18** documents the `Subject:` line in `plan-epic` and `create-epic-issues`.
  - **Follow-up:** an issue whose work spans several source files.
- **T15 review rulings.**
  - A declared subject must be canonical: no `..`, no `.`, no doubled or trailing slash, never
    absolute. Without that, the generated test is written outside the checkout.
  - `Isolation::WorkingBranch` gains a general owned-branch constructor, and both `epic/<slug>` and
    `lain/issue/<slug>/<id>` use it. An existing unmarked branch is refused, never moved or marked.
  - The children's lane carries the attempt, like the actor's own id.
  - A lent lease (`Leases::InPlace`) admits one dispatch at a time, by construction.
  - The reviewing children get a new read-only, network-free reviewer role, not `researcher`, which
    holds `web_fetch`/`web_search` but no `grep`/`glob`.
  - `--no-verify` on the red commit stays: the commit is red by design. **T18** surfaces it in the
    docs.
- **Orchestrator close-out:** `spec/lain/epic/mermaid_spec.rb:110` carries a `T4` ticket citation this
  chunk introduced in `67fe1314`. Clear it before the chunk closes.
- **T16 review rulings.** The panel reproduced four blockers over real git: one refusal discarded the
  whole run; the landing required the HUMAN's checkout to stand on `epic/<slug>`, so the ordinary
  case always failed; a `pending` issue stranded the run; and a timed-out gate left its question
  outstanding, killing the next issue's gate.
  - The driver lands in its own lain-owned worktree on `epic/<slug>`. The human's checkout is never
    switched.
  - Startable means `in_flight`. Approving the plan is the one writer of that transition; a pending
    issue is reported, never started.
  - A gate that times out or is denied withdraws its question, and at most one gate is outstanding.
  - The attempt is derived from the anchors already in the repository, so a retry launches instead of
    being refused.
  - Every per-issue refusal stops that issue, never the run.
  - **For T18:** `/implement-epic` interrupts on the conductor's `closed?` and sits outside the goal
    driver's cap.
- **T16 re-review.** All four blockers verified fixed. Two more went back: an interrupt during a gate
  wait left the question outstanding (the same defect through the new path), and every landing failure
  told the human to `--resume`, including refusals where nothing had merged.
  - **The lock deviation is right for a different reason than was recorded.** Nesting `ParentLock`
    does not deadlock, because `#hold` is re-entrant and only the outermost takes the flock. It is
    unnecessary because `ParentLock.for` resolves `--git-common-dir`, so the human's checkout and
    lain's landing worktree share one lock file and one object. **T18 documents that mechanism, not
    the other one.**
  - **Follow-up, a later chunk:** `Wiring` sits at 124/125 and `AskHuman` at 125/125, and
    `Tools::Holding` is a module coupled to its host's ivar, extracted to buy one line. The next card
    to touch either class has no headroom.
- **T17's two gaps, ruled.** The card handed back without `lain bench altitude` wired, and with the
  epic arm unable to grade through the real driver.
  - The driver's card promised that grading hooks in between settle and retire. T17 takes
    `epic_driver/factory.rb` and `run.rb` to add that one injected seam, defaulting to a Null.
  - `lain bench altitude` is assembled through the same `CLI::Wiring` path `lain chat --epic` uses,
    never rebuilt inside `bench`: an arm wired differently from production measures something else.
    If that needs a genuinely new construction path, T17 stops and reports the design rather than
    shipping a command that cannot run.
- **`lain bench altitude` is DEFERRED to a follow-up card, with its design.** T17 stopped at the
  escape hatch and named the blocker: `Wiring#assemble_surface` is private and reached only from
  `build_repl` ← `Wiring#run`, on the statement that starts the Repl on a TTY, while `toolset_build`
  and `epic_mount` are private and `command_env` reads a surface that is nil until that guard runs.
  Assembling the driver headlessly needs a new public `Wiring` seam plus a Null TTY and Conductor —
  a new construction path this chunk did not budget, in the file with one line of headroom left.
  - **The ruling:** defer rather than expand. An arm wired differently from production measures
    something else, and a second wiring is worse than no command.
  - **What landed instead:** the arms, the lease grader and `Bench::CLI#altitude_report` as library
    objects, spec'd and ready for whoever wires the command.
  - **Integration check 8 (a manual `lain bench altitude` run) is deferred with it.** The other seven
    checks stand.
  - **T18 documents what exists**, never the unwired command, and leaves `exe/lain`'s "three
    orchestration arms" text as it is, since it is still true.
- **T17's review, and a correction to the deferral's design.** The panel found the bench measuring the
  wrong thing: the fixture's subject project never reached the arm (`LeaseHarness` had no caller in
  `lib/`, and the arm ran in lain's own checkout), an epic arm that never ran scored 0.0, and the four
  arms were graded by three different mechanisms under one "score" column. All are in a fix round.
  - **The deferred command's design is SMALLER than first recorded.** `EpicDriver::Seams` is a public
    `Data` with a public `#driver`, and `ToolsetBuild` and `EpicMount.for` are already assembled
    headlessly in three specs. The follow-up needs a `Conductor::Null`, `grading:` threaded through
    `Seams#driver`, and a bench-side builder that differs per epic entry only by its gate policy.
    **`Wiring` is not touched, and needs no new public seam.**
