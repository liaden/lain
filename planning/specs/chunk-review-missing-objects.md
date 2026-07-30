# Chunk B: review fixes — missing objects and duplication

status: **done** (2026-07-29, `30e82b4..3e8502e`; all 17 cards landed, one commit each, every one
panel-reviewed — T35 was intentionally vacant and T37 dissolved before execution)

## Staleness check against post-A main (2026-07-29, 30e82b4)

Held exactly: T21's migration surface (**37** spec files, **68** `Agent.new`, **66** passing
`provider:`); T30's two `#decimal` copies still at `:936` and `:1321`; `env_spec.rb` still absent
(T26 creates it); T29's three `File.join(Dir.pwd, ".lain", ...)` literals; both Arm
`DEFAULT_CLOCK`s (`single_thread.rb:15`, `adaptive_router.rb:36`); `run_clock.rb:48`'s inline
default; every T36 deletion target present.

Absorbed line-number drift: `child_seam_kwargs` `:83-87` → **`:89-92`**;
`Approval::Gate::MONOTONIC` `:241` → **`:187`**; `Approval::Queue::MONOTONIC` is the constant at
**`:41`** (`:103` was its use as an `initialize` default); `prepared.rb` duck site `:161` →
**`:168`**.

**Material, and T32 must absorb both before it starts:**

1. **`Scheduler` now has its own private `pipeline_for(decision, base)`** at `scheduler.rb:245`,
   which is a *different method with the same name* as `Context#pipeline_for`. The duck-check
   T32 was told to hoist has moved to `scheduler.rb:234`. So "promote `Context#pipeline_for`"
   now has a name collision to resolve, not just call sites to adopt.
2. **Chunk A's T17 added a second duck-check of the same shape** — `Context#substituting?`
   (`context.rb:234-235`), which tests `respond_to?(:reads_messages?)`. It is deliberately
   tolerant, because the pipeline duck is published and a bench user's combinator will not
   implement a predicate it has never heard of. Any shared resolver T32 builds should cover
   this pattern too, or state why it does not.

**Also material for T23:** T15 changed `toolset_build.rb:82` to
`RoleSpawn.new(toolset: base, slots: backend.slots, **child_seam_kwargs)`. The card says
"toolset stays a SEPARATE parameter"; there are now **two** separate parameters, and `slots` is
exactly what the prerequisite's snapshot object would absorb — which is why T23 moves to wave 2.
commit-mode: orchestrator-commits
language: ruby
panel: Torvalds, Evans, Metz, Schneeman, Patterson (one review agent embodies all)

## Intent

Second of two chunks landing `planning/reviews/2026-07-29-simplification-review.md`: the
missing value objects behind the long parameter lists (§4), the duplication extractions (§5),
and the test cleanup (§6). Split out of the combined plan by panel ruling (B6) at the
review's own section boundary. Card IDs continue from Chunk A (T21–T38; T35 is
**intentionally vacant** — its Thor-options work was deferred to a future plan; T37 was
**dissolved in panel fixes** — its arm_sweep_spec half moved into T31 and its two
ivar-seam fixes ride with T22 and T23, which own those spec files).

## Grounding

Inherited from the 2026-07-29 review + panel spot-checks against `d0c7a3b` — **but Chunk A
lands first, so every line number here must be re-verified against post-A main before a card
starts** (the execute-plan staleness check is not optional for this chunk). Panel-verified
facts that shape cards:

- **68 `Agent.new` call sites across 37 spec files; 66 pass `provider:`** — T21's real
  migration surface (the review doc's "~40" undercounted).
- `arm.rb:11-15` states the design constraint T24 must not break: "a base that grows every
  child's knobs stops being a seam." The shared substrate is an injected collaborator, not
  base-class hoisting.
- `toolset_build.rb:83-87`'s `child_seam_kwargs` has **six** members; `toolset` is passed
  separately at both call sites (`:78`, `:99-100`) because each child attenuates over a
  different base, and `subagent.rb:395` builds a fresh `Toolset` per child. T23's seam is
  six members; toolset stays a separate parameter (decision recorded, not accidental).
- There is no single wall clock: `journal.rb:108` returns an ISO8601 **String** (the NDJSON
  timestamp), `epic_queue.rb:64` a utc **Time**, `status_feed.rb:213`/`inbox_view.rb:46`/
  `compaction/source.rb:142` local `Time.now`. T33 is **monotonic-only**; no `WALL`
  constant exists in this plan. `lib/lain/run_clock.rb` is the repo's existing clock object
  and the constant's home (a second `Lain::Clock` unit would reproduce the four-Gates
  naming problem the review itself filed).
- Of the five monotonic named constants, the two `Arm::*::DEFAULT_CLOCK`s are deleted by
  T24; the residual for T33 is `Approval::Queue::MONOTONIC` (queue.rb:103),
  `Approval::Gate::MONOTONIC` (gate.rb:241), `Gherkin::Approval::MONOTONIC` (handled by
  T32, which owns that file), the six inline lambdas, and `frontend/neovim/compose.rb:218,229`'s
  two direct calls that bypass injection.
- The two `#decimal` copies in telemetry.rb **differ**: `:936-940` nil-guards, `:1321-1323`
  does not. `Telemetry.fixed_point` must pick one behavior — the guarded choice turns the
  unguarded site's `NoMethodError` into a nil in the NDJSON record (a behavior change T30
  must decide, not stumble into). The reopening preamble is "reopening Telemetry a Nth
  time…" (15 occurrences), not the phrasing the review paraphrased.
- The pipeline duck-check's existing name is `Context#pipeline_for` (context.rb:191); the
  four duplicate sites are context.rb:194, scheduler.rb:189, linear_rewrite.rb:128,
  prepared.rb:161.
- `spec/lain/cli/command/env_spec.rb` does **not** exist — T26 creates it (same commit as
  the lib change, per CLAUDE.md's spec-grouping rule).
- The `:nvim` specs are excluded **by filter** when nvim is absent (`spec/support/tags.rb:92-95`)
  — a card touching neovim files can go green having executed zero relevant examples.

Interview constraints carried over: seam deletions stay punted (extractions touching
triage-pending files — `Prepared`, `Adjudicator` — apply mechanically but yield if a triage
ruling lands mid-chunk); no new caches beyond what Chunk A justified.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `exe/lain`,
  `lain.gemspec`, `.rubocop.yml`, `spec/spec_helper.rb`, `.rspec`, `Rakefile`.
- **Wave rebase rule:** every wave's worktrees fork from post-previous-wave `main`
  (consecutive waves edit `agent.rb`, `consolidation.rb`, `toolset_build.rb`, the arm specs).
- Deferred (do NOT build): Thor-options `CLI::Flags` (T35's vacancy), `HashEnvelope`,
  vendored `provider/http` middle-man cleanup, sweep doors, seam deletions.

## Open decisions

None — triage-pending files are handled by escalation triggers, not gates.

## Prerequisite from Chunk A (do this before wave 1)

**Name the `(catalog:, slots:)` pair.** Chunk A's T15 threaded one `Skill::Catalog` and one
`Prompt::Slots` through the session instead of loading them 2 and 3 times, and the pair now
passes verbatim through `Surface.new` → `ReplMiddleware.build` → `.renderer` →
`ToolsetBuild#run_skill`. That repeated parameter list is the state of an object nobody has
named yet, which is the same tell `wiring.rb`'s own comment cites as the reason `ToolsetBuild`
was extracted. T15 extracted `#assemble_surface` to keep `Metrics/AbcSize` honest, but that
silences the cop rather than answering it.

**Correction, staleness check 2026-07-29: this is NOT a wave-1 gate, and the note that said so
was wrong.** It claimed T21 and T27 "land in these classes and hit the ceiling on line one".
They do not: T21's files are `agent.rb` plus its spec, T27's are `bench/cli.rb` and
`bench/spawn_seam.rb`. Neither touches `Wiring` or `Backend`, and `rubocop --only
Metrics/ClassLength` over `agent.rb`, `bench/cli.rb`, `wiring.rb`, `backend.rb` and
`telemetry.rb` reports **no offenses** on post-A main. The ceiling is real for a future card in
`Wiring`/`Backend` (107 and 109 of 110), but nothing in this chunk is blocked on it.

So the extraction runs as an ordinary wave-1 card on its own merits — Metz's finding stands, a
repeated parameter list is still an unnamed object — and **T23 moves to wave 2**, because the two
collide on `toolset_build.rb`.

The shape the panel recommends: one `.lain/` snapshot object holding both, loaded by
ChatLaunch. It deletes `Wiring#catalog` (about 9 lines), collapses two keywords to one at
every call site, and ends the split where `Wiring` owns the catalog while `Backend` owns the
slots. Do it first and T21/T27 get headroom instead of an immediate escalation.

## Waves

Wave 1: T40, T21, T24, T25, T26, T27, T28, T29, T30, T32, T34, T36, T38
Wave 2: T22 (←T21), T23 (←T40), T31, T33 (←T25)
Critical path: T21 → T22
(T35 intentionally vacant; T37 dissolved — see Intent.)

**T40** is the `(catalog:, slots:)` extraction described above, given a card ID so it can be
tracked and reviewed like any other. **T23 moved to wave 2** because it and T40 both edit
`toolset_build.rb`, and T40 changes the very parameter list T23's seam is cut from.

### Status — 11 of 17 cards on main (updated as cards move)

Landed, in merge order: `b98671c` T36 · `d839c82` T26 · `194c877` T38 · `b0fe3ec` T30 ·
`7879011` T34 · `cdeff0c` T29 · `029410d` T25 · `6624005` T40 · `1afe79b` T24 · `113c340` T32 ·
`7c25502` T28. Every one gated on a full serial suite, whole-repo `rubocop`, and
`pre-commit run --all-files` before the commit.

| Card | State |
|---|---|
| T36 | ✅ merged — APPROVE first pass, the only one. 15 mutations, all caught, incl. one needing `rake compile` |
| T26 | ✅ merged — found a real bug: `Rewind` was correct only by statement order, one reorder from journal corruption |
| T38 | ✅ merged — `await_parked` failed open, silently cutting mutation 14's kill rate 8/8 → 6/8 |
| T30 | ✅ merged — 1660 lines → 98 + 18 files; `fixed_point`'s two callers both pinned |
| T34 | ✅ merged — a `compose_abandoned` no-op took 300s (`Compose::GRACE`) to fail; now milliseconds |
| T29 | ✅ merged — its 3 new examples all survived reverting the call sites; grep scan → Ripper AST |
| T25 | ✅ merged — **the chunk's worst find**: inverting *or* deleting `exe/lain`'s `--dry-run` branch left all 6724 examples green |
| T40 | ✅ merged — declined the recommended owner for `Backend`; ratified. Its placement-proof example didn't prove it |
| T24 | ✅ merged — argument evaluation had reversed drain/grade, repricing 3 arms 120→7120; span + phases restored |
| T32 | ✅ merged — the "four-door" sweep was three doors and one hollow row; Head's call was unreachable |
| T28 | ✅ merged — two live holes closed (bare `Faraday::ConnectionFailed` escaping); its own mutation found a 12th |
| T21 | re-review — digest divergence fixed by refusing; `Agent` at 109/110 `ClassLength` |
| T27 | fix round — REQUEST-CHANGES; two survivors held under cold-cache re-verification |
| T22 | blocked on T21 |
| T23 | wave 2, implementing |
| T31 | wave 2, implementing |
| T33 | wave 2, implementing |

**The recurring finding — every panel, without exception: a test that passes when the behaviour
it names is reverted.** T25's was the worst (the one branch choosing between spending money and
printing a plan). T29's three new examples all survived reverting the call sites they existed to
protect. T24's `Instrument` had its only claim untested because every shipped clock was a
*call-count* clock, so a `#timed` starting after the block measured identically. T40's example
whose comment states the card's central proof asserted `eq` between two renders of an unchanging
tree. Mutation is the only thing that surfaces this class, and it is now the panel's first
instruction.

⚠️ **Mutation testing in this repo needs a cleared bootsnap cache.** `spec/bootsnap_setup.rb`
keys compiled iseq on **(path, size, mtime-seconds)**, so a byte-size-preserving mutation — a
reordering, an inverted condition, an equal-length constant — applied and reverted inside one
second is served **stale bytecode while `git diff` reads clean**, manufacturing a false survivor.
One panel's entire first pass was invalidated by this and redone with `rm -rf tmp/cache/bootsnap`
per run; a second caught its own silently-unapplied mutation the same way. Filed as its own
ticket, because it affects anyone measuring this repo, not just this chunk.

**Flakes seen during the chunk, all confirmed pre-existing** (each reproduced on `30e82b4` or
shown byte-identical to base): `cli/up_spec.rb:115` and `:175` (real tmux + nvim cockpit),
`plugin/tmux_plugin_spec.rb:252` (HUD warmth under 7-way parallel load — it failed one commit
gate and passed on retry with no change), and `frontend/neovim/buffers_spec.rb:291`. None
belongs to a card in this chunk.

## Tasks

### T21 — Agent accepts its collaborators   [wave 1] [risk: high]

**Depends on:** none
**Files:** lib/lain/agent.rb, spec/lain/agent_spec.rb (additions only)
**Reuse:** `Agent::ModelCaller`, `Agent::ToolRunner`, `Agent::Accounting` — already-extracted objects (constructed internally at agent.rb:214-219,223-224); the Null-Object default posture `handler:` already uses
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: collaborators inject directly
  Given a ModelCaller, ToolRunner, and Accounting constructed by the caller
  When Agent.new(model_caller:, tool_runner:, accounting:, ...) is constructed
  Then the agent uses them, and no provider:/middleware/journal: keyword is required
```
→ spec file: `spec/lain/agent_spec.rb`

```gherkin
Scenario: every existing construction keeps working
  Given the 68 Agent.new call sites across 37 spec files (66 passing provider:)
  When the suite runs
  Then all pass unchanged — the legacy keywords remain and default-build the collaborators exactly as today
```
→ existing spec files (no edits): the 37 files, incl. `spec/support/shared_examples/provider_parity.rb`

Additive only this chunk: both construction styles are valid; passing both a collaborator
and its legacy ingredients is an ArgumentError (loud, at construction). Deprecating the
legacy keywords is a future plan's call.

**Escalation triggers:**
- `wire_callers`/`seed_run_state` thread state between the collaborators the grounding didn't show (e.g. ToolRunner needs the toolset instance Agent mutates) — stop; the boundary may genuinely be where it is for a reason.
- The both-styles ArgumentError fires in any of the 68 existing sites — a caller already passes an overlapping pair; stop and list them.

### T22 — Agent::Instrumentation value object   [wave 2] [risk: medium]

**Depends on:** T21
**Files:** lib/lain/agent.rb, lib/lain/cli/compaction_mount.rb, lib/lain/cli/chronicle.rb, lib/lain/cli/wiring.rb, lib/lain/cli/tool_guard.rb, spec/lain/agent_spec.rb, spec/lain/cli/compaction_mount_spec.rb, spec/lain/cli/chronicle_spec.rb
**Reuse:** the two existing Hash reifications (`CompactionMount#agent_kwargs`, `Chronicle#telemetry_kwargs`) name the clump's members; `Data.define` + all-Null defaults + `#with` per the house pattern
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: instrumentation travels as one value
  Given Agent::Instrumentation = Data.define(journal, model_middleware, tool_middleware, turn_middleware, tool_observer, transition_listener, pipeline_source) with Null defaults
  When CompactionMount, Chronicle, Wiring, and ToolGuard hand instrumentation to Agent
  Then the .fetch(:journal){Null} / .slice(:journal) / .merge(journal:) Hash-poking sites are replaced by readers and #with, and Agent#initialize takes one instrumentation: keyword
```
→ spec files: `spec/lain/agent_spec.rb`, `spec/lain/cli/compaction_mount_spec.rb`, `spec/lain/cli/chronicle_spec.rb`

Fold in (owns these spec files this wave): `Chronicle`'s five hand-written scribe forwards
become `delegate :catch_up, :rewound, :interrupted, to: :scribe`; and
`compaction_mount_spec.rb:33-38`'s three-deep `instance_variable_get` chain
(`pipeline_source` → `@derived` → `@strategy` → `@sink`) is replaced with a narrow seam or
an observable channel-event assertion in the style of its own sibling examples.

**Escalation triggers:**
- A member of the clump is consumed at a site the grounding didn't list (grep `telemetry_kwargs|agent_kwargs` first) — stop and extend the list before cutting.
- The ivar-seam replacement wants a public reader on `Source` — a `protected`-with-comment reader is the ceiling for a test seam; stop if that's not enough.

### T23 — Spawn::Seam value object   [wave 1] [risk: medium]

**Depends on:** none (T15 landed in Chunk A)
**Files:** lib/lain/tools/subagent.rb, lib/lain/skill/role_spawn.rb, lib/lain/cli/wiring/toolset_build.rb, spec/lain/tools/subagent_spec.rb, spec/lain/skill/role_spawn_spec.rb, spec/lain/cli/wiring/toolset_build_spec.rb
**Reuse:** `ToolsetBuild#child_seam_kwargs` (toolset_build.rb:83-87) names the members; its comment at :9-12 states the principle
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: the child-spawn collaborators travel as one seam
  Given Spawn::Seam = Data.define(provider, context_factory, parent, journal, supervisor, observer) — SIX members, matching child_seam_kwargs — with Null defaults for the last three
  When Tools::Subagent, RoleSpawn, and ChildBuilder take seam: (toolset stays a SEPARATE parameter — each child attenuates over a different base and subagent.rb:395 builds a fresh Toolset per child; this is a recorded decision, not an omission)
  Then RoleSpawn stores the seam and its per-call work is role selection only, and adding a seam member is a one-place change
```
→ spec files: `spec/lain/tools/subagent_spec.rb`, `spec/lain/skill/role_spawn_spec.rb`, `spec/lain/cli/wiring/toolset_build_spec.rb`

The sibling-template probe specs (P1-P2, P4-P11, P13-P14) must stay green — they pin
byte-level prefix behavior that must survive the refactor. Fold in (owns this spec file):
`toolset_build_spec.rb:34-40`'s two-deep `instance_variable_get` reach-through is replaced
with a narrow seam or observable assertion.

**Escalation triggers:**
- `Subagent`'s frozen/Ractor probes assert ivar shapes the seam object changes — stop; deep-freeze discipline must hold for the seam value too.

### T24 — One arm substrate: an injected Instrument, one lease bracket   [wave 1] [risk: medium]

**Depends on:** none
**Files:** lib/lain/arm.rb, lib/lain/arm/single_thread.rb, lib/lain/arm/adaptive_router.rb, lib/lain/arm/dual_ledger.rb, lib/lain/arm/orchestrator_worker.rb, matching specs under spec/lain/arm/
**Reuse:** the four byte-identical `timed` copies define the semantics; **constraint: `arm.rb:11-15` — "a base that grows every child's knobs stops being a seam." The substrate is an INJECTED collaborator, not base-class hoisting.**
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: elapsed and cost are measured by one injected instrument
  Given Arm::Instrument = Data.define(clock, price_book) with #timed { } → [elapsed, result] and #price(journal), injected into each arm (instrument: keyword with a shared default)
  When each arm runs
  Then the four timed copies and three Ledger.from_journal lines collapse onto Instrument, the mutable-capture workaround (state = nil; timed { state = ... }) disappears, AdaptiveRouter::DEFAULT_CLOCK is gone, and each arm's Run.new assembly stays in the arm (one line via the instrument's return pair) — NOT a base-class template method over the result shape
```
→ spec files: `spec/lain/arm/single_thread_spec.rb`, `adaptive_router_spec.rb`, `dual_ledger_spec.rb`, `orchestrator_worker_spec.rb`

```gherkin
Scenario: the lease bracket lives once
  Given Arm#leased(isolation:) { } on the base owning acquire/reclaim/ensure-surrender
  When the three duplicated brackets collapse onto it
  Then every spec pinning lease/reclaim call sequencing stays green
```
→ the same arm spec files

Fold in the review's arm-spec cleanups (owns these files): delete
`adaptive_router_spec.rb:122` (guessed method-name negative), `ledger_state_spec.rb:25-27`
(Data.define equality), fix `driver_spec.rb:47-53` (regex near arm names instead of parsing
Compare::Table columns), shrink `driver_spec.rb:34-36`. Refactor
`orchestrator_worker.rb:106`'s evaluation-order-dependent argument packing into two named
locals (`result`, `report`), keeping the design-rationale comment.

**Escalation triggers:**
- Any spec pins exact call *sequencing* on the lease/reclaim bracket in a way `#leased` changes — stop and list them; sequencing is bench contract.
- The Instrument default wants a home before T33 lands (`RunClock::MONOTONIC` doesn't exist yet in this wave) — default to the existing `SingleThread::DEFAULT_CLOCK` lambda inline and leave a one-line note for T33; do not create a clock unit here.

### T25 — One journal-pass command shape: shared resolver, Null provider, honest dry-run   [wave 1] [risk: medium]

**Depends on:** none
**Files:** lib/lain/cli/consolidate.rb, lib/lain/cli/improve.rb, lib/lain/cli/friction.rb, lib/lain/consolidation.rb, new lib/lain/cli/session_file.rb, new lib/lain/provider/unreachable.rb, spec/lain/friction_spec.rb, spec/lain/cli/improve_spec.rb, spec/lain/cli/consolidate_spec.rb, spec/lain/consolidation_spec.rb
**Reuse:** `cli/session_journals.rb`'s class comment argues for exactly this consolidation and names these files; `Sink::Null` as the Null-Object exemplar; `Command::Surface`'s "loud ArgumentError at construction" doctrine (surface.rb:24-28)
**Shared-file wiring:** `lib/lain/cli.rb` index gains `session_file` (one line, between
`cli/session_journals` and `cli/friction`); **`lib/lain/provider.rb`** — not `lib/lain.rb` —
gains `require_relative "provider/unreachable"` after `provider/mock` (one line). ⚠️ This plan
originally said `lib/lain.rb`; that was wrong, and the implementer corrected it. `lain.rb`
requires whole *units*, and `provider.rb` is the `provider/` subtree's index, so a new provider
is that index's business. See CLAUDE.md's Requires section.

**Acceptance criteria:**

```gherkin
Scenario: one resolver, one error
  Given the three byte-identical resolve/dir/SessionNotFound sets
  When Friction, Improve, and Consolidate resolve a selector
  Then they share CLI::SessionFile.resolve (three-candidate lookup) and one SessionNotFound, and the specs asserting per-class errors (friction_spec.rb:156, improve_spec.rb:169) are updated to the shared type
```
→ spec files: `spec/lain/friction_spec.rb`, `spec/lain/cli/improve_spec.rb`, `spec/lain/cli/consolidate_spec.rb`

```gherkin
Scenario: dry-run is a Null provider, not four nils
  Given a --dry-run invocation
  When Consolidation/Improve are constructed
  Then every collaborator keyword is required (loud at construction), the provider is Provider::Unreachable (raises "assembled for --dry-run" if #complete is ever called), Consolidation#require! is deleted, and #report / #dry_report are separate methods with no boolean flag
```
→ spec files: `spec/lain/consolidation_spec.rb`, `spec/lain/cli/improve_spec.rb`

**Escalation triggers:**
- `SessionJournals` turns out to be the better home than a new `SessionFile` (its comment claims ownership of discovery) — deciding between them is fine; stop only if merging changes `epic`/`epic_queue`'s existing adoption behavior.
- Any exe-level flow passes `dry_run:` through a layer this card doesn't touch (grep exe/lain first) — stop and map it.

### T26 — Env answers what commands actually ask   [wave 1] [risk: low]

**Depends on:** none
**Files:** lib/lain/cli/command/env.rb, lib/lain/cli/command/btw.rb, lib/lain/cli/command/meta.rb, lib/lain/cli/command/fork.rb, lib/lain/cli/command/pin.rb, lib/lain/cli/command/unpin.rb, lib/lain/cli/command/rewind.rb, lib/lain/cli/command/keep.rb, lib/lain/cli/inspection_binding.rb, new spec/lain/cli/command/env_spec.rb, existing command specs
**Reuse:** Env's own doc ("the one value a command reads its collaborators through", env.rb:6-14)
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: commands stop reaching through Env
  Given Env gains #head_digest, #timeline, #journal_path, and #checkpoint (= chronicle.catch_up(agent.timeline))
  When the nine chain sites and three duplicated catch_up protocols are collapsed
  Then no command file contains env.agent.timeline or env.chronicle.journal_path, and every command spec stays green
```
→ spec files: the existing command specs; reader examples in **new** `spec/lain/cli/command/env_spec.rb` (does not exist today — lands in the same commit as the env.rb change, per CLAUDE.md's spec-grouping rule)

**Escalation triggers:**
- A command uses `env.agent` for something beyond timeline/session access (grep each site first) — those stay; this card only collapses the listed chains.

### T27 — Bench takes a Backend, not six loose flags   [wave 1] [risk: medium]

**Depends on:** none
**Files:** lib/lain/bench/cli.rb, lib/lain/bench/spawn_seam.rb, spec/lain/bench/cli_spec.rb, spec/lain/bench/spawn_seam_spec.rb
**Reuse:** the chat path's existing `Backend.new(options)` single-argument style (chat_launch.rb:45)
**Shared-file wiring:** exe/lain — the Thor layer builds the Backend from its declared flags and passes `backend:` (orchestrator applies; watch arms_command_spec.rb:215/:226/:234's mechanical flag checks)

**Acceptance criteria:**

```gherkin
Scenario: one Backend flows in
  Given Bench::CLI#record (11→6 params) and SpawnSeam (9→4) take backend:
  When record/arms run
  Then the provider_name-vs-provider distinction commentary at bench/cli.rb:177-187 is deleted because the distinction no longer exists, and arms_command_spec's flag-coverage examples stay green
```
→ spec files: `spec/lain/bench/cli_spec.rb`, `spec/lain/bench/arms_command_spec.rb`

**Escalation triggers:**
- `arms_command_spec.rb:215/:226/:234` fail because a flag is now consumed by the Backend build instead of read literally — the MAPS registration may need updating; that spec is the door contract, change it only by its own rules.

### T28 — One provider family, not four copies   [wave 1] [risk: high]

**Depends on:** none
**Files:** lib/lain/provider/anthropic.rb, lib/lain/provider/bedrock.rb, lib/lain/provider/ollama.rb, lib/lain/embedder/ollama.rb, lib/lain/usage.rb, lib/lain/session_record/salvage.rb, new lib/lain/provider/http/error_wrapping.rb (or sibling), matching specs
**Reuse:** `AnthropicEncoding` — the existing shared-module precedent these classes already include; `RetryTap` (Anthropic's) for Bedrock; CLAUDE.md's blessing of ActiveSupport::Concern; the Usage class reopens after its Data.define block (the Request::SYSTEM_PREFIX trap precedent)
**Shared-file wiring:** one require line in the provider index for the new module

**Acceptance criteria:**

```gherkin
Scenario: error wrapping is declared once, constants stay per-class
  Given an ErrorWrapping concern whose included-block defines APIError/APIStatusError scoped to the includer (base error class declared per class)
  When all four classes include it
  Then specs rescuing by nested identity (described_class::APIError, Lain::Embedder::Ollama::APIError, ...) pass unchanged
```
→ existing spec files: `spec/lain/provider/anthropic_spec.rb`, `bedrock_spec.rb`, `ollama_spec.rb`, `spec/lain/embedder/ollama_spec.rb`

```gherkin
Scenario: the Anthropic wire shape is decoded once
  Given Usage.from_anthropic_wire(hash)
  When Anthropic, Bedrock, and SessionRecord::Salvage build usage
  Then all three call it, and the response-side duplicates (reset-header parser, wire_payload, build_response, normalize_tool_input) live in one shared module with Bedrock adopting RetryTap
```
→ spec files: the provider specs + salvage's spec

Ollama's divergences (no `channel:` → no retry journaling; no timeout envelope) become
explicit overrides or get a `# deliberately absent:` comment — never silent.

**Escalation triggers:**
- The "which rate-limit header governs backoff" open question (both files' comments) turns out to have diverged between the copies already — stop; reconciling behavior is a decision, not a refactor.
- Byte-level parity specs (`provider_parity` shared examples) fail on any extraction — the wire bytes are contract; stop.

### T29 — One .lain/ locator, one DSL-catalog base   [wave 1] [risk: medium]

**Depends on:** none (T4 landed up.rb's version fix in Chunk A)
**Files:** lib/lain/paths.rb, lib/lain/summarizer.rb (loader half), lib/lain/isolation/services.rb, lib/lain/status_feed.rb, lib/lain/cli/up.rb, lib/lain/frontend/tty.rb, matching specs
**Reuse:** `Paths` as "the one naming authority" (ARCHITECTURE.md:593); the two byte-identical loaders name each other's shape; `wiring.rb:145-149` already flags the coming project-root flag as the reason one locator must exist
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: .lain/state.json has one resolver
  Given a ProjectDir locator (or Paths sub-object) owning .lain/ resolution
  When status_feed, up, and tty need the state path
  Then the three File.join(Dir.pwd, ".lain", "state.json") literals are gone and the plugin scripts' paths are documented as the remaining consumers (same convention, changed in lockstep)
```
→ spec files: `spec/lain/paths_spec.rb`, `spec/lain/status_feed_spec.rb`, `spec/lain/cli/up_spec.rb`

```gherkin
Scenario: the two DSL loaders share one base
  Given a DslCatalog base owning DSL_PATH/self.load/exist-guard/Builder-dispatch/frozen-Enumerable/Null-empty
  When Summarizer and Isolation::Services load
  Then both are subclass-thin and their existing specs pass unchanged
```
→ spec files: the summarizer and isolation/services specs

**Escalation triggers:**
- `up.rb:258`'s comment says the duplication is deliberate ("so I1 and I2 do not need to depend on each other's private path helper") — the locator must not reintroduce that coupling; if it would, stop and present the shape.

### T30 — Split telemetry.rb into the index convention   [wave 1] [risk: medium]

**Depends on:** none
**Files:** lib/lain/telemetry.rb (becomes the index), new lib/lain/telemetry/*.rb (one record+guard per file), spec/lain/telemetry_spec.rb (should need no change except the fixed_point decision — verify)
**Reuse:** the index+directory convention every other multi-unit namespace follows (effect/handler.rb, gherkin.rb); zero cross-block references (grep-verified 2026-07-29)
**Shared-file wiring:** none (telemetry.rb remains the unit lain.rb requires; it becomes its own subtree index)

**Acceptance criteria:**

```gherkin
Scenario: mechanical split
  Given telemetry.rb keeps Journalable, Guard, and the module doc as the index
  When each record group moves to lib/lain/telemetry/<name>.rb
  Then the full suite passes with no spec edits, and the ~15 "reopening Telemetry a Nth time" preambles (16 Metrics/ModuleLength mentions) are gone
```
→ existing spec file: `spec/lain/telemetry_spec.rb`

```gherkin
Scenario: one fixed-point formatter, with the nil decision made deliberately
  Given the two #decimal copies DIFFER (telemetry.rb:936-940 nil-guards; :1321-1323 does not — a nil at the second site is a NoMethodError today)
  When Telemetry.fixed_point replaces both
  Then the card DECIDES the nil behavior (recommended: nil-tolerant, documented), a new example pins the "F"-format rule, and if the decision changes the unguarded site's failure mode the change is stated in the commit message — this half of the card is NOT "zero behavior change"
```
→ spec file: `spec/lain/telemetry_spec.rb`

**Escalation triggers:**
- Any cross-block reference emerges during the move (the grep said zero — trust but verify per file) — stop and map it; extraction order would then matter.
- Load-order NameError from lain.rb — fix inside telemetry.rb's index, never by editing lain.rb.

### T31 — Compare::Run carries metrics; one report fold   [wave 2] [risk: high]

**Depends on:** none (wave 2 so T36's compare_spec deletions land first)
**Files:** lib/lain/compare.rb, lib/lain/bench/sweep.rb, lib/lain/bench/arm_sweep/report.rb, lib/lain/bench/plan_sweep/report.rb, lib/lain/bench/decider_sweep.rb, spec/lain/compare_spec.rb, spec/lain/bench/arm_sweep_spec.rb, spec/lain/bench/plan_sweep_spec.rb, spec/lain/bench/decider_sweep_spec.rb, the sweep spec
**Reuse:** the four class comments that each explain why they could NOT reuse Compare — they specify the requirement; `Compare::Distribution` and `Compare::Table` (already shared) stay as-is
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: a sweep is an axis definition, not a report implementation
  Given Compare::Run widened to (name, metrics: Hash<Symbol, Numeric>, degraded:) with usage/cost/score as named builders, and Compare#report(order:, sections:)
  When sweep, arm_sweep, plan_sweep, and decider_sweep render
  Then each defines arms + metric extractors and delegates the fold, report strings stay byte-compatible where specs pin content, BigDecimal/Integer types survive the metrics Hash (never coerced to Float), and the ~330 lines of hand-rolled folds are gone
```
→ the spec files above

```gherkin
Scenario: arm_sweep's ordering is really asserted (absorbed from dissolved T37)
  Given arm_sweep_spec.rb:104-109's empty each_with_index loop that asserts nothing
  When this card rewrites the fold AND its spec
  Then a per-section ordering assertion actually fails on reorder, and the "titled sections" examples anchor with /^#{metric}\n/
```
→ spec file: `spec/lain/bench/arm_sweep_spec.rb` (this card owns it — the anchors are written against the NEW fold, not before it)

DisclosureSweep is left untouched (pending the seam triage); note its fold as the remaining
copy in a comment.

**Escalation triggers:**
- Existing specs pin report strings at a byte level the shared fold cannot reproduce — if the pin is layout-incidental, rewrite the spec to pin content; if it is a bench-record contract, stop.
- A Float appears anywhere BigDecimal/Integer flowed before — stop; type preservation is the reason a stats gem was rejected.

### T32 — Extraction batch A: compaction and context seams   [wave 1] [risk: medium]

**Depends on:** none (T17 landed in Chunk A — re-verify head.rb/source.rb line numbers post-A)
**Files:** lib/lain/compaction/head.rb, lib/lain/compaction/boundary.rb, lib/lain/compaction/source.rb, lib/lain/compaction.rb, lib/lain/context.rb, lib/lain/plan/linear_rewrite.rb, lib/lain/compaction/scheduler.rb, lib/lain/compaction/prepared.rb, lib/lain/compaction/strategy/elide.rb, lib/lain/compaction/strategy/identity.rb, lib/lain/gherkin.rb, lib/lain/gherkin/approval.rb, lib/lain/gherkin/test_generation.rb, matching specs
**Reuse:** `Freezable` (lib/lain/freezable.rb) — already exists, already used by Workspace; Boundary's own comment admitting the validated duplication; **the existing pipeline duck-check lives as `Context#pipeline_for` (context.rb:191)** — the extraction promotes/shares IT (e.g. `Context.resolve_pipeline` as a module-function wrapper), it does not invent a parallel mechanism
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: keep_last validation lives once
  Given Compaction.validate_keep_last
  When Head, Boundary, and Source#validated_keep_last call it
  Then the throwaway Head.new(messages: [], keep_last:) hack in Source is gone and the rule cannot drift
```
→ spec files: `spec/lain/compaction/head_spec.rb`, `boundary_spec.rb`, `source_spec.rb`

```gherkin
Scenario: the remaining batch lands mechanically
  Given the shared pipeline resolver (hoisted from Context#pipeline_for, adopted at context.rb:194, scheduler.rb:189, linear_rewrite.rb:128, prepared.rb:161), Gherkin scenario rendering on the value (two render_scenario copies), prepend Freezable replacing the two hand-rolled strategy initializers, and gherkin/approval.rb's MONOTONIC swapped to RunClock::MONOTONIC (this card owns that file; the constant is T33's but referencing it cross-wave is fine — T33 lands wave 2, so use the existing inline lambda here and leave a one-line note if ordering bites)
  When each extraction lands
  Then every existing spec in the touched areas passes unchanged
```
→ existing spec files in spec/lain/compaction/, spec/lain/context/, spec/lain/gherkin/

**Escalation triggers:**
- `Compaction::Prepared` is a triage-pending deletion candidate — apply the extraction mechanically, but if a triage ruling lands mid-chunk, drop that site rather than blocking.

### T33 — One monotonic clock default   [wave 2] [risk: high]

**Depends on:** T25
**Files:** lib/lain/run_clock.rb, lib/lain/approval/queue.rb, lib/lain/approval/gate.rb, lib/lain/middleware.rb, lib/lain/frontend/tty.rb, lib/lain/cli/conductor.rb, lib/lain/oracle/recorded.rb, lib/lain/cli/shutdown.rb, lib/lain/frontend/neovim/compose.rb, plus the T32/T24 leftovers' one-line notes, matching specs
**Reuse:** **`Lain::RunClock` (run_clock.rb) is the repo's existing clock object — the constant lives THERE (`RunClock::MONOTONIC`)**; a new `Lain::Clock` unit would reproduce the four-Gates naming problem the review filed. Monotonic ONLY — there is no single wall clock (journal.rb:108 returns an ISO8601 String, epic_queue.rb:64 a utc Time, three sites local Time.now); no `WALL` constant in this plan.
**Shared-file wiring:** none (run_clock.rb is already in the manifest)

**Acceptance criteria:**

```gherkin
Scenario: every monotonic default reads one constant
  Given RunClock::MONOTONIC
  When the residual sites adopt it — Approval::Queue::MONOTONIC, Approval::Gate::MONOTONIC, the six inline signature lambdas, and RunClock's own hard-coded default (the two Arm constants are already gone via T24; gherkin/approval.rb is T32's)
  Then Process.clock_gettime(Process::CLOCK_MONOTONIC) appears in lib/ only in run_clock.rb, and frontend/neovim/compose.rb:218,229 take the injection like their siblings instead of calling directly
```
→ spec files: the touched areas' existing specs; a new example in the run_clock spec pinning the constant

**Escalation triggers:**
- `compose.rb`'s two direct calls turn out to need wall-adjacent semantics (they time a compose session) — verify they are truly monotonic-elapsed before swapping; stop if not.
- The `:nvim` specs are filter-excluded when nvim is absent (tags.rb:92-95) — this card touches compose.rb, so the implementer MUST report the :nvim example count from their run; zero executed :nvim examples means the card is NOT verified — run on a box with nvim or escalate.

### T34 — RpcThread listens to one object   [wave 1] [risk: low]

**Depends on:** none
**Files:** lib/lain/frontend/neovim/rpc_thread.rb, lib/lain/frontend/neovim.rb (build_rpc), matching specs
**Reuse:** the existing comment at rpc_thread.rb:203-207 (its two-methods-not-verb-argument argument supports methods on one object); `Sink::Null` as the Null shape
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: editor events arrive on a listener
  Given RpcThread::Listener with #died, #resend(lines), #compose_written(lines, gen), #compose_abandoned(gen), plus Listener::Null
  When RpcThread (8→5 params) and Router take one listener
  Then the four hand-defaulted lambdas are gone and every existing neovim spec passes
```
→ spec files: the existing specs under `spec/lain/frontend/neovim/`

**Escalation triggers:**
- The `:nvim` specs are filter-excluded when nvim is absent — report the :nvim example count from the verification run; zero executed means NOT verified (run with nvim present or escalate).
- Any caller passes a *subset* of the four callbacks with distinct semantics for "absent" vs "no-op" — the Null must preserve that distinction or stop.

### T35 — (intentionally vacant — Thor-options CLI::Flags deferred to a future plan)

### T36 — Delete the audited low-value tests   [wave 1] [risk: low]

**Depends on:** none
**Files:** spec/lain/middleware/env_spec.rb, spec/lain/event_spec.rb, spec/lain/rust/timeline_spec.rb, spec/lain/tools/subagent_sibling_template_probes_spec.rb, spec/lain/agent/accounting_spec.rb, spec/lain/agent/loop_machine_spec.rb, spec/lain/oracle/prune_scoring_spec.rb, spec/lain/oracle/router_spec.rb, spec/lain/oracle/summarize_spec.rb, spec/lain/agent/request_override_spec.rb, spec/lain/agent/pipeline_source_spec.rb, spec/lain/improvement_spec.rb, spec/lain/compare_spec.rb, spec/lain/bench/variance_spec.rb, spec/lain/bench/speculative_spec.rb, spec/lain/bench/dry_replay_spec.rb, spec/lain/cli/backend_spec.rb, spec/lain/memory/item_spec.rb, spec/lain/frontend/prompt_composer_degradation_spec.rb
**Reuse:** the review doc §6's table — each deletion's justification; deletions folded into other cards (arm specs → T24, patterns_spec → Chunk A's T2) are NOT here
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: each deletion removes a duplicate or tautology, never coverage
  Given the §6 deletion table
  When each listed example is deleted (backend_spec:174 shrunk to a smoke check; request_override's stress test shrunk to ~20 iterations)
  Then the suite passes, and for each deletion the surviving example named in §6 as covering the same claim still exists and passes
```
→ the files above (deletions only)

**Escalation triggers:**
- A deletion target has drifted since d0c7a3b (Chunk A landed between) — re-verify the §6 justification against the current example; if it changed substantively, skip and note.

### T38 — Close the two audited coverage gaps   [wave 1] [risk: medium]

**Depends on:** none
**Files:** new spec/lain/core/child_spec.rb, new spec/lain/cli/repl/approval_surfaces_spec.rb
**Reuse:** `client_spec.rb`'s fake_daemon/tempdir/Paths scaffolding (extract into a shared helper if cleaner); the `:core` tag discipline (spec/support/tags.rb:131); the existing approval-prompt specs as the collaborator-shape reference
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: Core::Child's failure branches are exercised
  Given a stand-in binary that never accepts, one that exits before accepting, an externally-killed pid, and a double reap
  When child_spec runs (tagged :core)
  Then Unreachable, Died (raise_if_dead_on_arrival), the Errno::ESRCH rescue in #term, and #reap's memoized idempotency are each pinned
```
→ spec file: `spec/lain/core/child_spec.rb`

```gherkin
Scenario: ApprovalSurfaces' three-fiber fan-out is exercised
  Given a Repl constructed with live (non-nil) approvals:, notifier:, and auto_surface: doubles
  When #watch runs
  Then the multi-surface spawn and splat-compaction logic is pinned by observable effects on the doubles
```
→ spec file: `spec/lain/cli/repl/approval_surfaces_spec.rb`

**Escalation triggers:**
- Exercising ApprovalSurfaces requires a full provider/context-factory setup the doubles can't fake — stop and propose the minimal seam rather than building a heavyweight fixture.
- child_spec turns out to need behavior changes in Child to be testable — this card writes specs only; stop.

## Outcome (2026-07-29)

All 17 cards landed on `main`, one commit each, in merge order:

`b98671c` T36 · `d839c82` T26 · `194c877` T38 · `b0fe3ec` T30 · `7879011` T34 · `cdeff0c` T29 ·
`029410d` T25 · `6624005` T40 · `1afe79b` T24 · `113c340` T32 · `7c25502` T28 · `da20240` T21 ·
`0c214f4` T27 · `d89f867` T31 · `2ced329` T23 · `9cc3797` T33 · `3e8502e` T22

**Integration checks, all green at `3e8502e`:** full serial suite **7029 examples, 0 failures,
2 pending** (pre-chunk 6710 in this working tree, so **+319 net**, including T36's deliberate −21);
`rubocop` **942 files, no offenses** with `.rubocop.yml` untouched and **no `.rubocop_todo.yml`** —
it was deleted in `0afd058`, and per the standing instruction every new-cop offense in this chunk
was fixed in code, never deferred; `--tag nvim` **97/0** with nvim present, so not vacuous;
`--tag core` **40/0**; `cargo test` **277** across five targets with `clippy -D warnings`,
`fmt --check` and `cargo deny` clean (no card touched Rust); `pre-commit run --all-files` green.

### Verdicts

**16 of 17 cards needed a fix round.** One APPROVE on first pass (T36), fifteen
APPROVE-WITH-FIXES, one REQUEST-CHANGES (T27). Five cards took a second review pass. Chunk A's
figure was 17 of 21, so the rate is unchanged — the panel is not finding less as the codebase
improves.

### Every single review found a test that passes while its subject is broken

This is the defect class the chunk existed to remove, and it appeared in all seventeen reviews.
The specimens worth remembering:

- **T25** — inverting *or* deleting the `--dry-run` ternary in `exe/lain` left all 6724 examples
  green, on the one branch that decides between spending real money and printing a plan. The card's
  own `Provider::Unreachable` cannot catch it: on the wrong branch the real provider is already
  wired.
- **T22** — `cli_spec.rb:145` asserted `@turn_middleware.to_a == []` and survived the ivar being
  **deleted**, because `nil.to_a` is `[]`. Absence and emptiness were indistinguishable.
- **T24** — `Arm::Instrument`'s central claim was untestable, because every shipped clock was a
  *call-count* clock (`-> { ticks += 0.25 }`): a `#timed` that starts its clock **after** the block
  measures identically, so no assertion could tell. Fixed with a clock the block advances; T33 then
  generalised it to a *scripted* clock that raises on over-read.
- **T29** — all three new examples survived reverting the call sites they existed to protect, and
  the lib-wide grep scan caught **1 of 6** spellings while firing on prose. Now a Ripper walk.
- **T40** — the example whose comment states the card's central proof asserted `eq` between two
  renders of an unchanging tree.
- **T31** — six hand-rolled mean/median transpositions, one at a time against the whole serial
  suite: **all six green**. That silent-mislabel hazard, not a line count, is what justifies
  `Compare::ArmFold`.
- **T22 again** — `Wiring#goal_journal`, a line the card itself rewrote, had **no assertion
  anywhere**: mutating it passed the entire 6849-example suite.

Two measurements of how weak a spec file can be while green: **35 of 40** `wiring_spec` examples are
insensitive to the reporting value reaching the Agent, and `Chronicle#catch_up` returning `self` was
documented (and leaned on by an orchestrator ruling) but unpinned.

### Declines and corrections — the mechanism/outcome rule held again

Chunk A found that **an AC naming a *mechanism* was wrong every time it appeared, while an AC naming
an *outcome* was not.** That repeated exactly:

- **T40** declined the recommended owner (`ChatLaunch` → `Backend`) and was ratified; the panel
  supplied the decisive argument the card had missed — two of the five `Backend` sites were T27's
  files in the same wave, so compliance would have been a collision, not merely a worse shape.
- **T23** declined the AC's namespace (`Spawn::Seam` → `Tools::Subagent::Seam`) and was ratified:
  the AC was **internally inconsistent**, forbidding shared-file wiring while a top-level module
  requires a `lain.rb` line. `Bench::SpawnSeam` is also a different duck (a factory), so the AC's
  name would have recreated the four-`Gate`s defect the review filed.
- **T31** declined the AC's mechanism and delivered its outcome; ratified on all four claims. It
  also found the AC's "~330 lines of hand-rolled folds" was **~9× off** (41 real lines).
- **T25** corrected *this plan's own* wiring instruction: `provider/unreachable` belongs in
  `provider.rb`, the subtree index, not `lain.rb`, which requires whole units.
- **T21** corrected the card's "68 sites" to 66 — `grep -r` had skipped a spec file as **binary**
  while it held a real `Agent.new`.
- **T30** corrected the card's claimed error class (`ArgumentError` from `BigDecimal("")`, not
  `NoMethodError`, because `nil.to_s` is `""`).
- **T27's panel** corrected the *implementer's* own claim: `Backend` is at **109, not 106**, because
  reopening a class in a sibling file splits `ClassLength`'s count. The extraction is still right
  (a naive inline guard measured 116 against Max 110) — but justified by the object, never by the
  number it makes the cop report.

### Behaviour changes a green suite hid, and one debt repaid

- **T26** — `Rewind` was correct only by *statement order*: `#checkpoint` re-read the live timeline
  and happened to run before `agent.rewind`. Nothing held it there. One reorder from journal
  corruption; now `catch_up(from)`, with `Rewind` confirmed the only command that moves the timeline.
- **T24** — left-to-right argument evaluation in `Run.new` reversed drain-before-grade, repricing
  three arms from 120 to 7120 tokens, and dual-ledger's `elapsed` silently lost its `:planner_build`
  phase. Both restored: narrowing what the bench measures is a methodology change owing its own card.
- **T21** — the injected constructor committed a *different turn digest* than the legacy one, because
  `ToolRunner`'s toolset defaulted to empty while the Agent renders its own to the model. Refused
  rather than substituted, so the coupling is visible.
- **T28** — `Bedrock` and `Embedder::Ollama` had no `Faraday::Error` arm, so exhausted retries
  re-raised a bare `Faraday::ConnectionFailed` nothing above rescues. Both closed; the four
  now-identical rescue blocks collapsed behind a drift guard, since keeping them apart could only
  hide the next one to go missing.
- **T21 → T22** — T21 left `Agent` at **109/110** on `ClassLength`, accepted only on condition that
  T22 repay it. T22 did: **105/110**, verified line-by-line, with the reduction coming from moving
  the clump out rather than densifying `Agent`.
- **T23** — `bin/demo-skills` had been **red on main since `6624005`** (T40's `Skill::Library`), and
  no gate noticed because nothing runs `bin/`. Repaired here; the coverage gap is R.13.

### Follow-ups filed

Cross-cutting, in `planning/remaining-work.md`: **R.9** (seven remaining `.lain/` composers),
**R.10** (`Composed#reads_messages?` tolerant only one level deep — inherited from T17),
**R.11** (the four real-tmux/nvim flakes, and why a false RED corrupts a mutation table),
**R.12** (mutation testing needs a cleared bootsnap cache, an exactly-once pattern assertion, and a
timeout where a wedge scores as *not* detected), **R.13** (six of nine `bin/` scripts are executed
by nothing).

Per-card, recorded in each hand-back under `.claude/worktrees/` at merge time and copied out before
those trees were retired:

- **Highest value:** a **positive seam census** — "no seam has a private clock". T33's negative AST
  scan is silent by construction on a seam whose *default* is a wall clock, and three such mutations
  survive today at `Middleware::Timeout`, `Frontend::TTY` and `Compose`. Closing it needs a
  per-seam default assertion; `Arm::Instrument` is the shape it generalises.
- **A journal that does not answer `#record` deadlocks** rather than failing (found by two panels
  independently, as 110s wedges). Related and already fixed in passing: `supervisor.stop` sat
  outside an `ensure` inside `Sync do` in `subagent_spec`, so **any** failure in that file hung
  forever — two mutations that looked like stalls were reporting 44 and 37 real failures behind it.
- `wiring_spec`'s **35-of-40** insensitivity; `Ollama` journals **zero** retries while three fire
  (`RetryTap` makes it ~3 lines, and the Journal is the experiment record); `Compose::GRACE = 300`
  plus un-timed `settle` makes a broken compose hand-off *slow* rather than loud; `Bench::ArmTasks`
  answers a non-mapping fixture with a raw `NoMethodError` and a 22-line backtrace, and
  `arms_report` parses the suite *before* resolving the provider, so that is what a mistyped path
  hits first.
- Smaller: migrate the ten loose-keyword spawn call sites and delete the `**spawn_over` splat;
  `Compare`'s two remaining fold copies (`driver.rb:82`, `disclosure_sweep.rb:200`) plus a
  `DisclosureSweep` heading pin; a record-view object owning timeline+journal_path+checkpoint if a
  third consumer appears; `connect_budget:` as a *coverage-placement* change (it is 88% of
  `child_spec`'s runtime and would let four examples leave `:core`); glob `git ls-files` so the
  example count stops depending on untracked files; `Ractor.make_shareable` for `Arm::Instrument`
  (a Proc is not the boundary — capturing is); a `clock:` seam for `Core::Child`; rename
  `Telemetry::OracleAnswer#wall_clock`, which holds monotonic elapsed seconds; `Backend`'s
  unknown-key silence; `Listener::Null` should use the documented `.instance` idiom, and nothing
  guards that `Null` overrides every `Listener` method.

### Manual passes still owed (Joel — no agent can do these)

1. **From chunk A, now more meaningful:** one `lain up` smoke pass confirming the panes come up on
   4.0.6 — T4 changed the PATH derivation to `File.dirname(RbConfig.ruby)` and the machine's ruby was
   rebuilt mid-session, so this now tests something real.
2. **From chunk A:** one `lain bench plan-sweep` determinism check after T3.
3. **From this chunk:** one `lain bench arms` / `plan-sweep` report reading after T31 — the rendered
   report *is* the experiment record. Report bytes were diffed identical across all eight artifacts,
   so this is a read-through for sense, not a hunt for a diff.

## Integration checks

- `bundle exec rake compile && bundle exec rspec` — example count vs a pre-chunk serial run
  (net down from T36; new examples from T21/T26/T38 etc.).

  **Two different correct baselines exist at `30e82b4`, and the difference is exactly 10.**
  Measured 2026-07-29, real serial runs:

  - **A worktree (tracked files only): 6700 examples, 0 failures, 2 pending.** This is the
    number every card must be compared against, because every card is built in a worktree.
  - **This checkout: 6710, 0 failures, 2 pending** — 10 higher, and not a discrepancy to chase.
    `spec/docs_naming_spec.rb` and `spec/lain/gherkin_spec.rb` generate one example per doc file
    they find **on disk**, and this working tree carries ~15 untracked planning/reference docs
    (including this plan). Those two files alone are 70 examples here against 60 in a worktree.
    Committing these docs raises main's count by that amount, with no card responsible for it.

  So: judge a card against **6700**, and expect main to sit 10 above whatever the cards sum to
  until the planning docs land. Wave-1 agents reported 6700, 6710, 6712, 6713 as "baseline" or
  "green" without saying which tree they measured, which is why this note exists.

  One more count hazard, independent of the above: `spec/support/tags.rb` gates `:nvim` on
  `system("nvim", "--version")` at load time, and that is a **filter, not a skip** — a run whose
  PATH omits `/home/linuxbrew/.linuxbrew/bin` silently loses **97 examples** and still reports
  "0 failures" (`LAIN_NVIM=0` here: 6613). A count is only evidence if `command -v nvim` is
  stated alongside it.
- `bundle exec rubocop` clean with no config changes.
- `bundle exec rake core:build && bundle exec rspec --tag core` (T38's child_spec).
- A run on a box **with nvim present**, reporting the `:nvim` example count (T33/T34 touch
  neovim files; the filter exclusion makes an nvim-less run vacuous for them).
- `pre-commit run --all-files` before each orchestrator commit; commit in dependency order.
- **Manual (Joel):** one `lain bench arms`/`plan-sweep` report reading after T31 — the
  rendered report is the experiment record; eyeball that sections, ordering, and numbers
  read as before.
