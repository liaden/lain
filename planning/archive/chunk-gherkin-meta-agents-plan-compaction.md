# Grader-from-Gherkin, meta-agents, and plan-shaped compaction

status: done (landed 2026-07-21, 20/20 cards + 2 sequenced addenda; integration checks green: 3647 examples/0 failures, rubocop 650 files clean, cargo test+clippy+deny clean, pre-commit all-files passed)
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman · Aaron Patterson (Ruby
roster, `create-plan/references/rosters.md`)

> Panel-reviewed 2026-07-21 (verdict REVISE, all findings applied): M4 re-seamed onto
> `Queue#each`/@parked observation (arrivals-consuming would steal pendings from the human
> surface); P2 journals a closure pointer and the telemetry-serialization schedule gained a
> sixth wave (one telemetry.rb edit per wave: G5→P2→G2→P4); unit-index ownership
> (`gherkin.rb`, `plan.rb`, `grader.rb`) moved to orchestrator wiring, fixing a wave-4
> collision; P3's SeamPolicy contract now covers both state effects (timeline AND render
> pipeline) with the driver seam decided up front and agent live-wiring recorded as a named
> follow-up; G4's adapter writes JSON to a file, not stdout; M2's refusal message names the
> refused tool and the cross-process append discipline is pinned.

## Intent

Three streams that turn plans into graders and the harness into its own student. **(G)**
Grader-from-Gherkin (`planning/specs/grader-from-gherkin.md` GG-1..5): a typed, content-
addressed Gherkin IR, a fail-closed human approval gate, test generation via the
`test_engineer` role, and `Grader::Fixture` over the *user's* test framework. **(M)** Four
meta-agents (ROADMAP:354-357 + interview 2026-07-21): the **court-clerk** consolidation pass
(memories from completed subagent timelines), the **friction-observer** (helps the lain
*user* tune knobs — offline report over the Journal), the **harness-improver** (captures
"make lain better" notes while the lain *dev* dogfoods lain on another codebase; NDJSON under
XDG state + a CLI reader), and the **auto-approver** (an agent standing in for the human on
the existing approval-surface seam, opt-in, fully attributed). **(P)** Plan-shaped compaction
(`planning/specs/plan-shaped-compaction.md` PC-1..7): seams as plan content, deterministic
step-closure records, linear-vs-fork execution shapes, the seam EV decision, and eager unit
summaries — closed by the shape × density sweep. Two owed follow-ups land first as
prerequisites (F1 `cache_profile`, F2 `LockedBinding` string slots).

Interview decisions (2026-07-21): observers are **offline-first** (the auto-approver is the
one deliberately-live exception — it rides the existing multi-surface approval seam);
harness-improver notes go to **XDG state + a CLI reader**; the GG-1 gate is **fail-closed**,
with the auto-approver as the future unattended mode (this chunk builds it as an approval
surface; enabling it for GG approvals is wiring, not new architecture).

## Grounding

Verified against code on **2026-07-21** by three parallel `Explore` passes (grader/Gherkin
seams; meta-agent seams; compaction/plan seams), spot-re-verified by panel review same day.
Code is source of truth. Findings this plan is built on:

- **Grader contract:** `Grade = Data.define(:score, :pass, :why)` (`grader.rb:19`), `why`
  mandatory. `Grader::Fixture` = yielded builder of `check` predicates, raising predicate =
  failed check (`grader/fixture.rb:22-84`). `Grader::Rubric` drives a Provider one-shot
  (`rubric.rb:65-81`). The verification decorator exists (`Grader::Verified`,
  `verified.rb:30-74`); `Telemetry::Verdict` (telemetry.rb — the ONLY grader journal record;
  **a plain Grade is not journaled**, the GG-5 gap).
- **Nothing shells a test framework today** — no rspec/pytest/jest execution anywhere in
  `lib/`; `Grader::Fixture` is in-process predicates. The file-shaped fixture template is
  `ArmTasks#build_grader` (`bench/arm_tasks.rb:170-178`) consumed via `ArmSweep::GraderAdapter`
  (`arm_sweep.rb:148-152`). Isolation + `WorkerEnv` machinery for a suite run exists
  (`isolation/worktree.rb:47`, `worker_env.rb:29`).
- **The Gherkin pipeline is ~60% prose already:** `create-plan` skill emits Gherkin ACs
  (`prompt/templates/skill/create-plan/skill.md:40-43`), `execute-plan` demands red-first
  (`execute-plan/skill.md:37`), `test_engineer` role exists with `bash`
  (`role/catalog.rb:23-24`), `Skill::RoleSpawn#call` spawns a persona'd one-shot
  (`role_spawn.rb:53-67`). **No typed IR exists** — Gherkin lives only as text; the reusable
  typed substrate is `Tool::Input` (schema-dual, `input.rb:81-110`) and the content-addressed
  `Oracle::Definition` pattern (`oracle/definition.rb:20-60`).
- **Approval seams:** `ask_human` emits Q as a `:message` event and returns a Promise without
  awaiting (`tools/ask_human.rb:87-93`); `#reply` resolves (`:104-114`). `Approval::Queue` is
  the fail-closed multi-surface queue — `Pending#decide` first-answer-wins (`queue.rb:68-77`),
  timeout = deny signed by the clock (`queue.rb:164-168`), every decision journals
  `approval_decision` with surface/verdict/latency (`queue.rb:88-92`). **The human TTY
  surface consumes `queue.dequeue` (single-delivery, `frontend/approval_policy.rb:48`); a
  SECOND surface must observe via `Queue#each` over `@parked` (`queue.rb:129-136`, offered
  for exactly this)** — an arrivals-consuming second surface would steal pendings from the
  human. First-answer-wins makes the `#each` race safe.
- **Meta-agent substrate:** court-clerk exists ONLY as a role (`role/catalog.rb:29`,
  `only: read_file list_files memory_read memory_write`; persona template shipped);
  friction-observer entirely absent. The offline analysis objects exist and are reused, not
  reinvented: `Grader::ToolCallIndex` (`tool_call_index.rb:23`), `Grader::FrustrationRepair`
  (`:rephrase_loop` signals walked through causal lineage, `frustration_repair.rb:47-139`),
  `Grader::ToolSteering` (`tool_steering.rb:28-45`), `Bench::Rewrites`. `Journal.records`
  is the lazy reader (`journal.rb:102-105`). Memory writes go `memory_write → Recorder →
  JournalMemoryRoot` (`tools/memory_write.rb:48-51`) gated by `RefuseSecretWrites`, which
  guards the **exact string "memory_write" only** (`refuse_secret_writes.rb:26-29`) and
  **hardcodes that name in its refusal message** (`refuse_secret_writes.rb:111-113`) — a
  second writer tool needs both the guard-set and the message parameterized. Its `oracle:`
  seam defaults to NullOracle (`:58-70`); `Oracle::MemorySave::Gate` exists but is
  deliberately unwired (over-refusal follow-up) — **this chunk does not wire it**.
- **No durable analysis sink exists:** every bench/compare surface returns a String
  (output discipline); the only durable writers are the session Journal and
  `.lain/state.json`. `Paths#state_home` exists; improvements need a new accessor. The
  Journal's Monitor+sync write discipline (`journal.rb:120-143`) serializes fibers in ONE
  process — a cross-process shared file needs `O_APPEND` single-`write` lines kept small.
- **Compaction:** `Context::Compact` is a pure combinator, byte-threshold, injected
  summarizer (`context/compact.rb:30-62`); it does NOT record elided digests. The
  `Compaction::Scheduler` (T17-T21) exists but is **not live-wired** (no production caller;
  grep of `agent.rb`/`agent/` clean); its injection seam is `Context.new(pipeline:)`
  (`context.rb:95,139-143` — Context is frozen, pipeline fixed at construction, so per-turn
  pipeline choice means per-turn Context construction) + `Scheduler#pipeline`
  (`scheduler.rb:118-160`); decisions journal `Telemetry::Compaction`. `Compaction::Need`
  has a `PlanStepCompletion` detector relaying `Session#plan_step_completed?`
  (`need.rb:86-89`, `session.rb:144-165`).
- **Plan/todo state:** `TodoWrite::Item` is flat `{content, status}` — no id, no seams
  (`todo_write.rb:34`); Session retains the list **in memory for this run only**, never on
  the Timeline, deliberately not resurrected on fork/replay (`session.rb:11-17,322-334`).
  **A plan that must survive fork-per-step cannot ride Session** — the structured-value-
  through-Workspace template is `Arm::LedgerState` (`arm/ledger_state.rb:21-75`,
  `#to_reminder`), and the Store accepts non-turn structured events (`Workspace::Snapshot`
  precedent, `workspace/snapshot.rb:108-118`). **The Store is in-memory per process** — a
  record that must survive the session needs a journaled pointer.
- **Fork machinery:** `Timeline#fork` is O(1) identity over the shared Store; the
  fork-score-keep template is `Bench::Speculative` (`speculative.rb:40-57`);
  `#diverge_at`/`#dominator_meet` localize divergence (`timeline.rb:128-182`). CE-2's
  rolling `Request#prefix_digests` chain (`request.rb:104-139`) + `Bench::Rewrites` is how
  fork-per-step's zero-rewrite claim is PROVEN.
- **Oracles are synchronous today** — Promises pre-resolve before `#ask` returns (no
  rejection channel); N calls overlap only if the caller spawns tasks
  (`oracle/definition.rb:46-56`, `oracle/recorded.rb` `TODO(async-tier)`). PC-7's concurrent
  fire path is unbuilt. Replay substitution is keyed `(oracle_digest, question)` via
  `Telemetry::OracleAnswer` (`recorded.rb:47-81`). `Provider::Ollama` (qwen3:4b,
  NO_CACHING_PROFILE) is the local one-shot arm (`provider/ollama.rb:32-102`).
- **Two live hazards, fixed here as F-cards:** (F1) `Provider` base has NO `cache_profile`;
  only Anthropic + Ollama implement it; Bedrock/BedrockRaw/AnthropicRaw/Mock would
  `NoMethodError`; Anthropic's is a fixed Opus-family constant with a follow-up to relocate
  `MINIMUM_CACHEABLE_TOKENS` (`anthropic.rb:41-64,103`) — note `CACHE_PROFILE` references
  SpawnPolicy's constant at class-body load time, so the relocated unit must load before
  `tool/` and `provider/` in the manifest, with SpawnPolicy becoming the re-export. (F2)
  `Prompt::LockedBinding` hands raw slot values to `ERB.new` — an Integer slot crashes
  opaquely (`locked_binding.rb:43-56`, `definition.rb:32-34`); the owed loud-failure fix.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only):
  - `lib/lain.rb` — manifest lines for new units (`gherkin`, `friction`, `improvement`,
    `plan`, `cache_profile`), placed per load-order (the `cache_profile` unit loads before
    `tool/` and `provider/` — F1's constant relocation).
  - **Unit indexes** `lib/lain/gherkin.rb`, `lib/lain/plan.rb`, `lib/lain/grader.rb`,
    `lib/lain/oracle.rb`, `lib/lain/effect/handler.rb`, `lib/lain/tools.rb` — created by
    their FIRST card in the same commit as the unit (the standard new-file+index rule: G1
    creates `gherkin.rb`, P1 creates `plan.rb`), then **subsequent same-unit index-line
    additions are orchestrator wiring, never card Files** (this is what keeps P3/P5 and
    G2/G3 out of same-wave file conflicts).
  - `lib/lain/telemetry.rb` — **exactly one card per wave may edit it**: G5 (wave 2), P2
    (wave 3), G2 (wave 4), P4 (wave 5). Those cards list it under Files deliberately; no
    other card touches it. This serialization is what forces the six-wave shape.
  - `lib/lain/role/catalog.rb` — role additions serialized: M4 (wave 2), M6 (wave 3).
  - `exe/lain` / `lib/lain/cli.rb` — new subcommand mounts are one-line orchestrator wiring;
    the subcommand *classes* are card scope under `lib/lain/cli/`.
  - `lain.gemspec`, `.rubocop.yml`, `spec/spec_helper.rb`, `CLAUDE.md` — untouched expected.
- Deviations from the default process:
  - Worktree staleness: every wave ≥2 brief must instruct `git merge main` before building
    (the known `isolation: worktree` session-start-fork trap).

## Open decisions

None gating. Deliberately out of scope, recorded so no card grows them: wiring
`Oracle::MemorySave::Gate` live (blocked on the over-refusal recalibration follow-up);
GEPA/experiment-proposal automation (parked); the auto-approver answering GG approvals **by
default** (it ships opt-in only); per-seam (vs per-plan) execution-shape selection (spec's
open question — start per-plan, promote if PC-6 shows mixed plans want it). **Named
follow-up, not a card:** live-wiring `Plan::Runner`/`Compaction::Scheduler` into the agent
loop's per-turn Context construction — this chunk drives the shapes through the bench-style
runner (P3); the `agent.rb` mount is a deliberate later change with its own review.

## Waves

Wave 1: F1, F2, G1, G4, M1   (no unmet deps)
Wave 2: G3 (←G1), G5 (←G1,G4), M2 (←M1), M4, M5, P1 (←G1)
Wave 3: M3 (←M2), M6 (←M1,M2), P2 (←P1,G5,F2), P7 (←F2)
Wave 4: G2 (←G1), P3 (←P1,P2), P5 (←P2)
Wave 5: P4 (←F1,P1)
Wave 6: P6 (←P3,P4,P5)
Critical path: G1 → G5 → P2 → P3 → P6 (P4's wave-5 slot is telemetry-serialization-forced,
not dependency-forced; it joins the path at P6)

## Tasks

### F1 — Give Provider a cache_profile contract          [wave 1] [risk: low] ✅ LANDED d35fa2a (stale-fork reconciliation: main already had the hash constants; promoted into CacheProfile with #[]/#== compat so StatusFeed/Cold unchanged)

**Depends on:** none
**Files:** `lib/lain/provider.rb`, `lib/lain/provider/mock.rb`,
`lib/lain/provider/anthropic_raw.rb`, `lib/lain/provider/bedrock.rb`,
`lib/lain/provider/bedrock_raw.rb`, `lib/lain/provider/anthropic.rb`,
`lib/lain/tool/spawn_policy.rb` (re-export only), `lib/lain/cache_profile.rb` (create),
`spec/lain/cache_profile_spec.rb` (create)
**Reuse:** `Provider::Anthropic::CACHE_PROFILE` (`anthropic.rb:58-64`) and
`Provider::Ollama::NO_CACHING_PROFILE` (`ollama.rb:57-63`) as the two existing shapes;
`SpawnPolicy::SiblingTemplate::MINIMUM_CACHEABLE_TOKENS` (the constant to relocate).
**Shared-file wiring:** `lib/lain.rb` manifest line for `cache_profile`, placed BEFORE
`tool/` and `provider/` (Anthropic's class body reads the constant at load time)
(orchestrator).

Promote the profile to a first-class value (`Lain::CacheProfile` — ttl, min_prefix_tokens,
write/read multipliers, tiered_invalidation), declare `#cache_profile` on the Provider base
(abstract, raises with the subclass name like `#capabilities`), implement it on all six
providers (Raw/Bedrock share Anthropic's; Mock gets NO_CACHING by default with an injectable
override for scheduler specs), and relocate `MINIMUM_CACHEABLE_TOKENS` into the neutral
home; `SpawnPolicy::SiblingTemplate` re-exports it so existing references resolve. Closes
the owed follow-up; P4 consumes it.

**Acceptance criteria:**

```gherkin
Scenario: every shipped provider answers cache_profile
  Given each of Anthropic, AnthropicRaw, Bedrock, BedrockRaw, Ollama, Mock
  When cache_profile is called
  Then a CacheProfile value returns, and the base class raises NotImplementedError naming the subclass
```
→ spec file: `spec/lain/cache_profile_spec.rb`

```gherkin
Scenario: the minimum-cacheable constant has one home
  Given the relocated constant
  When SiblingTemplate and Anthropic's profile reference it
  Then both read the same object and the old constant path still resolves
```
→ spec file: `spec/lain/cache_profile_spec.rb`

**Escalation triggers:**
- `spec/lain/status_feed_spec.rb` pins `DEFAULT_CACHE_PROFILE` hash-shape access
  (`status_feed.rb:69,125` uses `[:ttl]`) — if unifying forces a StatusFeed behavior change,
  stop; the HUD contract is interface-owned.
- If any existing spec constructs Mock and calls a scheduler path expecting NO profile,
  reconcile rather than silently defaulting to Anthropic numbers.

### F2 — LockedBinding fails loudly on non-String slot values          [wave 1] [risk: low] ✅ LANDED 7fcfdf8 (panel: APPROVE-WITH-FIXES mechanical — NonStringSlot moved to prompt.rb taxonomy home)

**Depends on:** none
**Files:** `lib/lain/prompt/locked_binding.rb`, `spec/lain/prompt/locked_binding_spec.rb`
**Reuse:** the error-taxonomy convention (named refusal beside its owner —
`Prompt::ImpureSlot` is the sibling); the T6 call-site stringify precedent (PruneScoring's
caller stringifies — correct and unchanged).
**Shared-file wiring:** none

`LockedBinding#render` raises a named `Prompt::NonStringSlot` (naming the slot and the value's
class) when `@resolve` returns a non-String, instead of the opaque `ERB.new(Integer)` crash.
No coercion — callers stringify deliberately (loud failure doctrine). Closes the owed
follow-up; P7's digest/byte-count slots depend on the loud error.

**Acceptance criteria:**

```gherkin
Scenario: an Integer slot value names itself
  Given an oracle template whose resolver returns 5 for slot "age_turns"
  When render is called
  Then Prompt::NonStringSlot raises with a message naming "age_turns" and Integer
```
→ spec file: `spec/lain/prompt/locked_binding_spec.rb`

**Escalation triggers:**
- If any existing template spec passes non-String values TODAY and relies on ERB stringifying
  them downstream (grep oracle/prompt specs first), stop — that's a behavior change beyond a
  loud error and the call sites need the fix instead.

### G1 — Gherkin::Criteria, the typed content-addressed IR          [wave 1] [risk: medium] ✅ LANDED 3394574 (panel REQUEST-CHANGES round: unclosed/decorated/empty fences + colon-token typos now raise; typo-fold and pre-fence-marker pinned as deliberate; follow-up F-2: gherkin fence nested inside another code fence still parses)

**Depends on:** none
**Files:** `lib/lain/gherkin.rb` (create — becomes the unit index when G2/G3 add siblings),
`spec/lain/gherkin_spec.rb` (create)
**Reuse:** `Canonical` for the digest; `Data.define` deep-freeze idiom (`Ractor.shareable?`
spec'd); the fenced ```gherkin block format `create-plan` already emits
(`prompt/templates/skill/create-plan/skill.md:40`); `Oracle::Definition#digest` as the
content-addressing precedent (`oracle/definition.rb:58-60`).
**Shared-file wiring:** `lib/lain.rb` manifest line (orchestrator).

`Gherkin::Scenario` (name + ordered clauses, each `Given|When|Then|And` + text) and
`Gherkin::Criteria` (scenario list + `#digest` over canonical bytes). Parse from markdown
fenced ```gherkin blocks (the format already in plan docs and skill scaffolds); a malformed
block raises naming the line. Each scenario carries `mechanical:` (default true); the author
flags a rubric scenario with a `# rubric` comment **on its own line immediately preceding
the `Scenario:` line** — the one pinned marker grammar; a `# rubric` anywhere else in the
block is an error naming the line (no silent placement ambiguity).

**Acceptance criteria:**

```gherkin
Scenario: round-trip from a plan doc block
  Given a markdown string with two fenced gherkin blocks, one preceded by a # rubric line
  When Gherkin::Criteria.parse runs
  Then two scenarios materialize with ordered clauses and a stable digest
  And the flagged scenario is mechanical: false
  And parsing the same text twice yields the same digest
```
→ spec file: `spec/lain/gherkin_spec.rb`

```gherkin
Scenario: values are deeply frozen
  Given a parsed Criteria
  Then Ractor.shareable? is true for it and every scenario
```
→ spec file: `spec/lain/gherkin_spec.rb`

**Escalation triggers:**
- If real plan docs in `planning/specs/` contain gherkin blocks this parser rejects (run it
  over the corpus as a smoke check), stop and reconcile the grammar before shipping a parser
  that can't read the house format.

### G4 — Grader::TestHarness — the project test-run fixture          [wave 1] [risk: high] ✅ LANDED d64f683 (panel probes added: injectable timeout + named Timeout error, load-crash detail from rspec's JSON messages array; follow-up: size error count from errors_outside_of_examples_count, not messages.size)

**Depends on:** none
**Files:** `lib/lain/grader/test_harness.rb` (create),
`lib/lain/grader/test_harness/adapter.rb` (create),
`spec/lain/grader/test_harness_spec.rb` (create),
`spec/fixtures/projects/rspec_mini/` (create — a 3-example fixture project)
**Reuse:** `Grader::Fixture`'s Grade contract (`grader/fixture.rb:38-54`);
`Mixlib::ShellOut` + `WorkerEnv` cwd/env threading (the Isolation backends' pattern,
`isolation/worktree.rb`, `db_index.rb:99`); `ArmTasks#build_grader` as the fixture-shape
template (`arm_tasks.rb:170-178`); the DbIndex env-probe lesson (scrub inherited
framework env — `BUNDLE_*`, `RUBYOPT`, `RSPEC_*` — via WorkerEnv explicit-nil; the
env-pollution bug class recurred three times in the isolation chunk).
**Shared-file wiring:** `lib/lain/grader.rb` index line (orchestrator).

GG-3. An `Adapter` duck — `command(out_path:)` returns the argv that writes the machine-
readable result **to a file** (rspec: `--format json --out <out_path>`; a child project's
own stdout warnings/deprecations therefore never corrupt the parse), and
`parse(out_document, exit_status) → {passed:, failed:, errors:}` reads that document.
`Adapter::Rspec` first; detection probes the project root (Gemfile+spec/ → rspec;
`package.json` w/ jest → jest; `pyproject.toml`/`pytest.ini` → pytest) and **raises loudly
on ambiguity or no match** — explicit adapter injection always wins. `TestHarness#grade`
runs the suite via ShellOut under the subject's `WorkerEnv` (cwd = the workspace/worktree
under test), maps pass/fail counts to a `Grade` (score = passed/total, why = failure names).
Jest/pytest adapters are follow-ups; the duck is the deliverable — a second in-repo adapter
(`Adapter::Command`, explicit argv + out-file regex) proves the seam without a second
runtime.

**Acceptance criteria:**

```gherkin
Scenario: an rspec fixture project grades deterministically
  Given the rspec_mini fixture project with 2 passing and 1 failing example
  When TestHarness grades a WorkerEnv pointed at it
  Then the Grade scores 2/3, does not pass, and why names the failing example
  And a fixture project that prints deprecation noise to stdout grades identically
```
→ spec file: `spec/lain/grader/test_harness_spec.rb`

```gherkin
Scenario: detection is loud, injection wins
  Given a directory matching no framework probe
  When TestHarness is built without an explicit adapter
  Then a named detection error raises listing what was probed
  And building with adapter: Adapter::Command succeeds against the same directory
```
→ spec file: `spec/lain/grader/test_harness_spec.rb`

**Escalation triggers:**
- The fixture project's rspec run must NOT inherit the host suite's bundler context —
  if `BUNDLE_GEMFILE` leaks despite the explicit-nil scrub, stop before papering over.
- If nested-rspec-in-rspec proves flaky under the fiber scheduler, stop — running the
  fixture via plain ShellOut process (no Async involvement) is the fallback, but confirm
  before restructuring.

### M1 — Friction::Report — knob guidance over a session Journal          [wave 1] [risk: low] ✅ LANDED c64b425 (+03cf45b exe LiveViews/render extraction — the friction mount tripped ClassLength; follow-up: if the mechanical floor feels empty on real journals, that's a recorded gap, not a license to wire the oracle)

**Depends on:** none
**Files:** `lib/lain/friction.rb` (create), `lib/lain/friction/report.rb` (create),
`lib/lain/cli/friction.rb` (create), `spec/lain/friction_spec.rb` (create)
**Reuse:** `Grader::FrustrationRepair` (`frustration_repair.rb:47`), `Grader::ToolSteering`
(`tool_steering.rb:28`), `Grader::ToolCallIndex` (`tool_call_index.rb:23`),
`Bench::Rewrites`; `Journal.records` lazy reader (`journal.rb:102`); the report-as-String
output discipline (`bench/cli.rb:52-65` precedent); `CLI::Sessions`' path resolution
(`cli/sessions.rb:27`).
**Shared-file wiring:** `lib/lain.rb` manifest line; `exe/lain` subcommand mount
(orchestrator, one line).

The friction-observer's deterministic core, for the lain **user**: fold the existing analysis
graders over one session Journal and render a knob-guidance report — each signal mapped to
the knob that addresses it by a declarative table in the class (e.g. `:rephrase_loop` on a
tier-3 tool → "consider the approval queue timeout / a structured tool instead of bash";
steering flag → "rewrite that tool's description; see the disclosure sweep"; high
cache-rewrite count → "compaction scheduling knobs"). Pure function of the Journal: no model
call, byte-identical across runs. `lain friction <session>` prints via the frontend.

**Acceptance criteria:**

```gherkin
Scenario: a frustrating session yields targeted guidance
  Given a fixture Journal containing a rephrase loop on bash and a steering flag on grep
  When Friction::Report renders
  Then the report names both signals with their turn digests and maps each to its knob line
  And rendering twice yields identical bytes
```
→ spec file: `spec/lain/friction_spec.rb`

```gherkin
Scenario: a clean session says so
  Given a fixture Journal with no signals
  When the report renders
  Then it states no friction found and lists the analyzers that ran
```
→ spec file: `spec/lain/friction_spec.rb`

**Escalation triggers:**
- `FrustrationRepair`'s fuzzy tier sits behind a Null-default `oracle:` — this card must NOT
  wire a live oracle into it (interview: deterministic core only). If the mechanical floor
  alone yields an empty-feeling report on real fixtures, record that as a follow-up, don't
  reach for the model.

### G3 — Test generation glue: approved Gherkin → test_engineer          [wave 2] [risk: low] ✅ LANDED 40d2c3c (panel round added NothingMechanical loud refusal for all-rubric criteria)

**Depends on:** G1
**Files:** `lib/lain/prompt/templates/skill/gherkin-tests/skill.md` (create),
`lib/lain/gherkin/test_generation.rb` (create),
`spec/lain/gherkin/test_generation_spec.rb` (create)
**Reuse:** `Skill::RoleSpawn#call` (`role_spawn.rb:53`); the `test_engineer` role + persona
(`role/catalog.rb:23`, `prompt/templates/role/test-engineer.md`); the skill-directory
convention (`skill/catalog.rb:44-60` — drop a directory, no code change); `Provider::Mock`
for the spec.
**Shared-file wiring:** `lib/lain/gherkin.rb` index line (orchestrator).

GG-2. `Gherkin::TestGeneration#call(criteria, framework:)` renders the `gherkin-tests` skill
scaffold (scenarios inlined, framework named, red-first contract stated) and dispatches it
through `RoleSpawn` to `test_engineer` in fresh-context mode; returns the child's result +
the criteria digest (wrapping RoleSpawn's return — never editing `role_spawn.rb`, a file
this wave does not own). Scenarios flagged `mechanical: false` are excluded from the prompt
and returned as a `rubric_scenarios` list for G2's routing (GG-4's split, recorded not
improvised). No framework detection here — the caller passes `framework:` (G4 owns
detection).

**Acceptance criteria:**

```gherkin
Scenario: the scaffold reaches the test-engineer with the criteria digest
  Given approved Criteria with one mechanical and one rubric-flagged scenario
  When TestGeneration runs against a Mock provider
  Then the spawned prompt contains the mechanical scenario and the framework name
  And the rubric-flagged scenario is absent from the prompt and present in rubric_scenarios
  And the returned record carries the criteria digest
```
→ spec file: `spec/lain/gherkin/test_generation_spec.rb`

**Escalation triggers:**
- If `RoleSpawn`'s one-shot result shape can't be wrapped without modifying `role_spawn.rb`,
  stop — wrap, don't edit; that file is not this wave's to change.

### G5 — Journal the Grade: attestation records          [wave 2] [risk: low] ✅ LANDED 4d909c7 (panel blocker: subject digests resolve loudly — callable/#digest/String — never from inspect output)

**Depends on:** G1, G4
**Files:** `lib/lain/telemetry.rb` (this wave's one telemetry edit),
`lib/lain/grader/journaling.rb` (create), `spec/lain/grader/journaling_spec.rb` (create)
**Reuse:** `Telemetry::Verdict` as the pattern; `Grader::Verified`'s decorate-and-journal
idiom (`verified.rb:61-74`); `Journalable` concern.
**Shared-file wiring:** `lib/lain/grader.rb` index line (orchestrator).

GG-5. `Telemetry::GradeRecord` (grader class, score, pass, why, subject digest, and an
optional `criteria_digest`) + `Grader::Journaling`, a decorator over any `#grade` duck that
journals the Grade and passes it through unchanged. `TestHarness` results graded against a
Gherkin digest journal with it; `DryReplay`-side reads recover "which criteria was this run
graded against" from the record.

**Acceptance criteria:**

```gherkin
Scenario: a grade lands in the journal with its criteria digest
  Given a TestHarness wrapped in Grader::Journaling with a criteria digest
  When it grades a subject
  Then the returned Grade is unchanged and one grade_record journals with score, subject digest, and criteria digest
```
→ spec file: `spec/lain/grader/journaling_spec.rb`

```gherkin
Scenario: replay recovers the attestation
  Given a Journal containing a grade_record
  When records are read with type "grade_record"
  Then the criteria digest and grader class round-trip
```
→ spec file: `spec/lain/grader/journaling_spec.rb`

**Escalation triggers:**
- `Compare::Run.from_timeline` reads `grade&.score` (`compare.rb:29-34`) — if journaling
  requires changing that call shape, stop; Compare's surface is bench-owned and other sweeps
  pin it.

### M2 — The improvements sink: Paths, record, guarded write tool          [wave 2] [risk: low] ✅ LANDED 5285894 (improvement_write pinned on the barrier side of the parallel partition, reason documented; 4096/4097 line-budget boundary spec'd)

**Depends on:** M1
**Files:** `lib/lain/paths.rb`, `lib/lain/improvement.rb` (create),
`lib/lain/tools/improvement_write.rb` (create),
`lib/lain/middleware/refuse_secret_writes.rb`, `spec/lain/improvement_spec.rb` (create),
`spec/lain/middleware/refuse_secret_writes_spec.rb`
**Reuse:** `Paths#state_home` + `ensure_dir` (`paths.rb:45,80-85`);
`Telemetry::Journalable`; `Tools::MemoryWrite` as the tool template
(`tools/memory_write.rb:16-51`).
**Shared-file wiring:** `lib/lain.rb` manifest line; `lib/lain/tools.rb` index line
(orchestrator).

Interview decision: XDG state + CLI reader. `Paths#improvements_path` →
`$XDG_STATE_HOME/lain/improvements.ndjson` (one cross-project file; each record carries
`project_hash` + session id). **Cross-process append discipline** (the Journal's Monitor
serializes only fibers in one process): the file opens `O_APPEND`, each record is one
`write` call, and records are kept small (a size guard on the note field) so line-atomicity
holds across concurrent dogfood sessions in different repos. `Improvement` record: note,
kind (knob/bug/missing-feature/doc), evidence digests, project_hash, session, at.
`Tools::ImprovementWrite` (tier 1, schema via `Tool::Input`) appends one record. **Guard
generalization:** `RefuseSecretWrites`' `GUARDED_TOOL` becomes a frozen Set
`GUARDED_TOOLS = {"memory_write", "improvement_write"}`, and the refusal message is
**parameterized to name the refused tool** (today it hardcodes "memory_write refused",
`refuse_secret_writes.rb:111-113`) — same patterns, same refusal telemetry shape.

**Acceptance criteria:**

```gherkin
Scenario: an improvement lands durably under XDG state
  Given a Paths with XDG_STATE_HOME pointed at a tempdir
  When improvement_write runs with a note and evidence digests
  Then one NDJSON line appends under <tempdir>/lain/improvements.ndjson carrying project_hash and session
```
→ spec file: `spec/lain/improvement_spec.rb`

```gherkin
Scenario: the secret guard covers the second writer and names it
  Given an improvement_write whose note contains an AKIA credential
  When it dispatches through RefuseSecretWrites
  Then the write is refused with the same telemetry shape memory_write refusals produce
  And the refusal message the model sees names improvement_write, not memory_write
  And memory_write refusals are unchanged
```
→ spec file: `spec/lain/middleware/refuse_secret_writes_spec.rb`

**Escalation triggers:**
- `refuse_secret_writes_spec` pins the single-tool guard today — extending to a Set must not
  change the journaled refusal shape; if it does, stop (replay readers may key on it).
- If a note under the size guard still exceeds conservative pipe-atomicity bounds when
  serialized (evidence-digest lists grow), stop and split the record shape rather than
  hoping.

### M4 — The auto-approver: an agent as an approval surface          [wave 2] [risk: medium] ✅ LANDED 988283e (panel: strict one-token verdict grammar, error results always defer, decided-mid-sweep spawns skipped; follow-up: @adjudicated seen-set grows unbounded over a long watch)

**Depends on:** none
**Files:** `lib/lain/approval/auto_surface.rb` (create), `lib/lain/role/catalog.rb`,
`lib/lain/prompt/templates/role/auto-approver.md` (create),
`spec/lain/approval/auto_surface_spec.rb` (create)
**Reuse:** **`Approval::Queue#each` over `@parked` (`queue.rb:129-136`) — the seam the queue
explicitly offers a second surface.** NOT `dequeue`/arrivals: the human TTY surface consumes
`queue.dequeue` (`frontend/approval_policy.rb:48`), and a second consumer would steal
pendings the human then never sees. `Pending#decide` first-answer-wins (`queue.rb:68-77`)
makes the `#each` race safe; `approval_decision` journaling with `surface:`
(`queue.rb:88-92`); `Skill::RoleSpawn` (`role_spawn.rb:53`); `Provider::Mock` for specs.
**Shared-file wiring:** none (exe/lain opt-in flag wiring is a later enablement, not this
card).

Interview addition (2026-07-21): the auto-mode "human" is a meta-agent. `Approval::
AutoSurface` runs as a sibling fiber that **observes `queue.each`** (polling the parked
set; never dequeuing): for each undecided `Pending`, it spawns the `auto_approver` role
one-shot with the effect's tool name, input, and context rendered into the persona scaffold,
parses an approve/deny/defer answer, and calls `pending.approve/deny` **only** on a
confident verdict — `defer` (and any unparseable answer, which MUST parse toward defer,
never approve) leaves the pending for the human surface or the fail-closed timeout. The
surface name is the plan-pinned constant `"auto_approver"`; every decision it makes journals
with it, so a transcript can never confuse it with the human. Add the `auto_approver` role
(read-only toolset: `read_file list_files glob grep`) + persona template stating the
deny-when-unsure doctrine. **Opt-in only**: nothing constructs it by default; enabling it
for GG-1 approvals or tier-3 tools is explicit wiring at the call site.

**Acceptance criteria:**

```gherkin
Scenario: an approval is attributed to the auto surface while the human surface still sees arrivals
  Given a queue with a human surface consuming dequeue and an AutoSurface observing each
  And a pending tier-3 effect whose auto role answers approve before the human acts
  Then the effect proceeds, the approval_decision journals surface "auto_approver",
  And the human surface still received the arrival notification
```
→ spec file: `spec/lain/approval/auto_surface_spec.rb`

```gherkin
Scenario: defer leaves the human in charge
  Given a pending whose role answer is defer, and another whose answer is unparseable
  When the surface processes them and the timeout then expires
  Then both pendings resolve as the clock's denial, not the auto surface's
```
→ spec file: `spec/lain/approval/auto_surface_spec.rb`

```gherkin
Scenario: racing the human is safe
  Given a pending decided by the human surface first
  When the auto surface answers afterwards
  Then the first decision stands and no second approval_decision journals for it
```
→ spec file: `spec/lain/approval/auto_surface_spec.rb`

**Escalation triggers:**
- `Pending#decide` is single-shot first-answer-wins — if the race spec reveals a second
  journal write today (a latent queue bug), stop and report; the fix belongs to the queue,
  not this card.
- If `Queue#each` enumeration during concurrent park/settle mutates under the fiber (Array
  mutation mid-each), stop — the enumeration contract is queue-owned; do not snapshot-copy
  around it silently.

### M5 — Court-clerk consolidation pass          [wave 2] [risk: medium] ✅ LANDED 4be6d66 + 002e573 (guard proven live in the child chain; exe mount via CLI::Consolidate.from_options; follow-up: pass an opened Journal so clerk WriteRefused/MemoryRoot land durably)

**Depends on:** none
**Files:** `lib/lain/consolidation.rb` (create), `lib/lain/cli/consolidate.rb` (create),
`spec/lain/consolidation_spec.rb` (create)
**Reuse:** the `court_clerk` role + persona (already shipped, `role/catalog.rb:29`,
`prompt/templates/role/court-clerk.md`); `Skill::RoleSpawn` (`role_spawn.rb:53`);
`Journal.records` + turn records' `spawned_from` meta; `memory_write`'s guarded path
(`tools/memory_write.rb`, `refuse_secret_writes.rb`); `Provider::Mock`.
**Shared-file wiring:** `lib/lain.rb` manifest line; `exe/lain` subcommand mount
(orchestrator).

Offline-first (interview): `Consolidation#call(journal_entries)` walks completed subagent
lineages (turns whose meta carries `spawned_from`, grouped by root), renders each lineage's
transcript summary into the court-clerk scaffold, and spawns the role one-shot per lineage
— **fresh-root** (the clerk reads the record, never inherits the parent's prompt). The
clerk writes memories through its attenuated `memory_write`; **`Consolidation` constructs
its own dispatch chain with `RefuseSecretWrites` mounted** (the guard does not come free
from RoleSpawn — state it, build it, spec it). NullOracle stays, per Open decisions.
`lain consolidate <session>` runs it on demand; `--dry-run` prints what would be spawned.
Memory roots advance via the existing `JournalMemoryRoot` pairing.

**Acceptance criteria:**

```gherkin
Scenario: each completed lineage gets one clerk pass
  Given a fixture Journal with two subagent lineages and a Mock provider scripting one memory_write each
  When Consolidation runs
  Then two clerk spawns occur, two memories land in the index, and each memory's evidence names its lineage root
```
→ spec file: `spec/lain/consolidation_spec.rb`

```gherkin
Scenario: the secret guard still gates the clerk
  Given a clerk whose scripted memory_write contains a PEM block
  When Consolidation runs
  Then the write refuses with the standard telemetry and the pass continues to the next lineage
```
→ spec file: `spec/lain/consolidation_spec.rb`

**Escalation triggers:**
- The parent→child link is correlation-grain only (the edge-grain provenance question was
  left open by design, 2026-07-17) — if lineage grouping proves ambiguous on real journals
  because of it, stop and surface; do not invent a causal edge here.
- If the clerk's spawn policy resolves to anything but fresh-root by default, check
  `Role#spawn_policy` before proceeding — inheriting the parent prompt would be a silent
  contamination of the record-reading premise.

### P1 — Plan::Document — steps, seams, sizes as a structured value          [wave 2] [risk: medium] ✅ LANDED 3d9f807 (panel round: MalformedStep construction rejection closes silent digest divergence; Step in its own sibling file per Metrics doctrine)

**Depends on:** G1
**Files:** `lib/lain/plan.rb` (create — becomes the unit index when P2/P3/P4/P5 add
siblings), `lib/lain/plan/document.rb` (create), `spec/lain/plan_spec.rb` (create)
**Reuse:** `Arm::LedgerState` as the structured-value-through-Workspace template
(`arm/ledger_state.rb:21-75` — `#to_reminder`, value-swap advance); `Workspace#with`/
`#to_blocks` (`workspace.rb:67-85`); `Canonical` digests; `Gherkin::Criteria` digests (G1)
for per-step criteria references.
**Shared-file wiring:** `lib/lain.rb` manifest line (orchestrator).

PC-1. `Plan::Step` (id, title, size class S/M/L, status, optional criteria digest) and
`Plan::Document` (ordered steps + seam markers between them; a removed seam merges adjacent
chunks). Deeply frozen; every mutation returns a new value (`#advance(step_id, status:)`,
`#insert_seam`/`#remove_seam`). Renders two ways: `#to_reminder` (the Workspace tail — the
live working view) and `#to_markdown` (the author-editable artifact with visible seams +
sizes, parseable back — round-trip is the author-review loop). Store-borne by digest so it
survives fork/replay (Session deliberately cannot carry it — grounding).

**Acceptance criteria:**

```gherkin
Scenario: seams are author-editable and merging works
  Given a document with three steps and seams after each
  When remove_seam runs between steps 2 and 3
  Then the chunks enumerate as [step1] and [step2, step3] and the markdown shows exactly one seam
```
→ spec file: `spec/lain/plan_spec.rb`

```gherkin
Scenario: markdown round-trips
  Given a document rendered to markdown
  When parsed back
  Then the digest matches the original
```
→ spec file: `spec/lain/plan_spec.rb`

**Escalation triggers:**
- If `Workspace` reminders being strings forces `to_reminder` to lose structure the seam
  handler (P3) needs, stop — the fix may be a structured reminder slot on Workspace, which
  is a shared-seam change the orchestrator must sanction.

### M3 — lain improvements: the cross-project reader          [wave 3] [risk: low] ✅ LANDED 7a4ebca (torn-tail tolerance pinned; follow-up: a mistyped --project/--kind filter renders like an empty file)

**Depends on:** M2
**Files:** `lib/lain/cli/improvements.rb` (create),
`spec/lain/cli/improvements_spec.rb` (create)
**Reuse:** `Improvement` records + `Paths#improvements_path` (M2); `Journal.records`-style
lazy NDJSON reading; report-as-String discipline (`bench/cli.rb` precedent).
**Shared-file wiring:** `exe/lain` subcommand mount (orchestrator).

`lain improvements [--project <hash-or-path>] [--kind knob|bug|missing-feature|doc]` renders
the accumulated notes grouped by project then kind, each with its evidence digests and
session pointer — the lain-dev's dogfood queue, readable from any repo. Returns a String;
the frontend prints.

**Acceptance criteria:**

```gherkin
Scenario: notes group across projects
  Given an improvements file with records from two project hashes
  When the report renders unfiltered
  Then both projects appear as sections with their notes and evidence digests
  And filtering by one project omits the other
```
→ spec file: `spec/lain/cli/improvements_spec.rb`

```gherkin
Scenario: before any dogfooding, the report is friendly
  Given no improvements file exists under the injected Paths
  When the report renders
  Then it states that no improvements are recorded yet and names the file path it looked for
  And an empty existing file renders the same way
```
→ spec file: `spec/lain/cli/improvements_spec.rb`

**Escalation triggers:**
- If M2's sink format gained a header line or version marker after this card was briefed,
  reconcile with M2's author via the orchestrator rather than special-casing the parse here.

### M6 — The harness-improver pass          [wave 3] [risk: medium] ✅ LANDED bc510e5 (guard proven live; follow-ups: shared CLI::SessionSelector to dedupe the triplicated resolve, one-write-per-finding guidance duplicated template+scaffold)

**Depends on:** M1, M2
**Files:** `lib/lain/role/catalog.rb`, `lib/lain/prompt/templates/role/harness-improver.md`
(create), `lib/lain/cli/improve.rb` (create), `spec/lain/cli/improve_spec.rb` (create)
**Reuse:** `Friction::Report` (M1) as the evidence input; `improvement_write` + guard (M2);
`Skill::RoleSpawn` (`role_spawn.rb:53`); `Provider::Mock`.
**Shared-file wiring:** `exe/lain` subcommand mount (orchestrator).

The lain-dev's dogfood observer (interview: offline-first). Add the `harness_improver` role
(`only: read_file list_files glob grep improvement_write`) + persona (audience: the lain
DEV; "you observe this session's harness behavior and record what would make lain itself
better — knobs that were missing, tools that fought the model, docs that lied — one
improvement_write per finding, each citing evidence digests"). `lain improve <session>`
renders the Friction::Report + session digest summary into the scaffold and spawns the role
one-shot; its writes land in the M2 sink. Distinct from M1 by audience: M1 tells the *user*
which existing knobs to turn; M6 tells the *dev* what lain should grow.

**Acceptance criteria:**

```gherkin
Scenario: a dogfood pass records improver notes
  Given a fixture Journal and a Mock provider scripting two improvement_writes
  When lain improve runs
  Then two improvement records land carrying this project's hash and the session id
  And the spawned prompt contains the friction report's signal lines
```
→ spec file: `spec/lain/cli/improve_spec.rb`

```gherkin
Scenario: the improver cannot write memories
  Given the harness_improver role
  When its toolset is attenuated
  Then memory_write is absent and improvement_write is present
```
→ spec file: `spec/lain/cli/improve_spec.rb`

**Escalation triggers:**
- role/catalog.rb was edited by M4 in wave 2 — merge main before building (worktree
  staleness trap); if the catalog shape changed under you, reconcile, don't re-cut.

### P2 — Step-closure records, Store-borne and journal-pointed          [wave 3] [risk: medium] ✅ LANDED d8a8c72 (panel blocker: ChunkRangeOutOfBounds — absolute in-bounds ranges only, end-overflow no longer clamps; NOTE FOR P3: whole-timeline spans must be `(0...length)`, `(0..-1)`/`(0..)` raise by design)

**Depends on:** P1, G5, F2
**Files:** `lib/lain/plan/closure.rb` (create), `lib/lain/telemetry.rb` (this wave's one
telemetry edit), `spec/lain/plan/closure_spec.rb` (create)
**Reuse:** `Workspace::Snapshot` blob digests + `Projection#workspace_at`
(`workspace/snapshot.rb:108-118`, `event/projection.rb:68`); `Telemetry::GradeRecord` (G5)
for criteria pass/fail; `Timeline#ancestors` for the elided-span digest walk (Compact does
not keep the association — computed here from the chunk's turn range); `Oracle::Definition`
tiering for `notes_for_future_steps` (heuristic floor = empty; slots stringified per F2);
`Store#put` for the content-addressed record; `Telemetry::MemoryRoot`'s
Store-pointer-in-the-Journal precedent.
**Shared-file wiring:** `lib/lain/plan.rb` index line (orchestrator).

PC-2. `Plan::Closure.build(step:, timeline:, chunk_range:, grade:, snapshot:)` derives the
record from content-addressed sources: step id/title/status from the plan; criteria
pass/fail from the Grade; files + blob digests from the snapshot at the seam; elided-span
digests = the chunk's turn digests (they stay in the Store — attested, un-rendered);
`notes_for_future_steps` empty at the deterministic tier. `status: failed` closures carry
the error evidence digests (purge-failed-keep-error at plan granularity). The record is a
frozen value `put` into the Store — **and because the Store is in-memory per process, every
closure also journals a `Telemetry::ClosureRecord` pointer** (closure digest, step id, plan
digest, chunk turn-range digests) so P5's calibration and any later session can find it from
the Journal alone. That pointer is this wave's telemetry.rb edit.

**Acceptance criteria:**

```gherkin
Scenario: a closure derives with zero model calls
  Given a completed chunk with a grade, a snapshot, and its turn range
  When Closure.build runs at the deterministic tier
  Then every field traces to a digest, no provider is touched, and the record round-trips from the Store by digest
```
→ spec file: `spec/lain/plan/closure_spec.rb`

```gherkin
Scenario: the journal can find every closure
  Given two closures built in a session
  When the journal's closure_record entries are read
  Then each names its closure digest, step id, and plan digest
```
→ spec file: `spec/lain/plan/closure_spec.rb`

```gherkin
Scenario: a failed step closes richer, not poorer
  Given a chunk whose grade failed with two error result blocks
  When the closure builds
  Then status is failed and the evidence digests name both error blocks
```
→ spec file: `spec/lain/plan/closure_spec.rb`

**Escalation triggers:**
- `Workspace::Snapshot` covers only the structured write-set (bash writes are an honest gap,
  `snapshot.rb:18-27`) — the closure must carry that scope note verbatim, not imply full
  coverage; if a spec wants bash coverage, stop (that's the W4 persistence follow-up, not
  this card).

### P7 — Eager unit summaries on their own fibers          [wave 3] [risk: medium] ✅ LANDED 41eccf1 (panel blocker: no-reactor fire now degrades to a miss, digest unconsumed; sanctioned deviation: fire spawns from the Summarizing decorator, not ToolRunner post-dispatch — revisit at P3 live-wiring; follow-ups: @fired/@held unbounded growth, fire's task return is spec-only)

**Depends on:** F2
**Files:** `lib/lain/oracle/eager.rb` (create), `lib/lain/effect/handler/summarizing.rb`
(create), `spec/lain/oracle/eager_spec.rb` (create)
**Reuse:** the caller-spawns concurrency contract (`oracle/definition.rb:46-50`,
`recorded.rb` TODO(async-tier)); `Oracle::Model` over `Provider::Ollama`
(`oracle/model.rb:41`, `provider/ollama.rb:32`); `Telemetry::OracleAnswer` + `Oracle::
Recorded` replay keying (`recorded.rb:47-81`); the Handler decorator idiom
(`Effect::Handler::Recorded`, `Gate` as templates); `Async::Task#async` for the fire.
**Shared-file wiring:** `lib/lain/oracle.rb` + `lib/lain/effect/handler.rb` index lines
(orchestrator).

PC-7. `Oracle::Eager` holds summaries keyed by **source digest** (immutable source → never
stale): `#fire(digest, text)` spawns the oracle call on its own task and returns
immediately; `#held(digest)` answers a completed summary or nil (never blocks); all Q&A
journal via the existing `OracleAnswer` path so replay substitutes recorded summaries.
`Handler::Summarizing` decorates the live handler; **the fire mounts at ToolRunner
post-dispatch** (pre-decided: the handler chain stays plain synchronous Ruby by the 5-0.2
spike decision — the decorator observes results, the spawn happens where the reactor is
already in scope). Results above a byte threshold fire eagerly, attributed, default tier
local-only (an injected oracle — Ollama in live use, Mock in specs). **A failed fire dies
with its task**: it journals nothing, holds nothing, and never surfaces at the reactor or
breaks the turn (oracles have no rejection channel — the task boundary is the containment).
Seam-time assembly (P3) consumes `#held`; a miss falls back to the deterministic record
alone — never a blocking summarize call.

**Acceptance criteria:**

```gherkin
Scenario: firing never blocks the turn
  Given a Summarizing handler over a slow Mock oracle
  When a large tool result dispatches
  Then the tool result returns before the summary resolves and exactly one fire occurs for its digest
```
→ spec file: `spec/lain/oracle/eager_spec.rb`

```gherkin
Scenario: a failed fire is contained
  Given an oracle that raises on ask
  When a large tool result fires it
  Then the turn completes normally, held(digest) is nil, and no oracle_answer journals
```
→ spec file: `spec/lain/oracle/eager_spec.rb`

```gherkin
Scenario: summaries key by source digest and replay
  Given a fired summary journaled as an oracle_answer
  When a Recorded tier replays the session
  Then held(digest) yields the recorded summary with no live call
```
→ spec file: `spec/lain/oracle/eager_spec.rb`

```gherkin
Scenario: a repeat result is a cache hit, not a second fire
  Given the same result content dispatched twice
  Then only one oracle call ever fires for that digest
```
→ spec file: `spec/lain/oracle/eager_spec.rb`

**Escalation triggers:**
- The agent's cancel-boundary invariant (stop lands only between whole commits,
  `docs/concurrency.md:318-356`) — if an in-flight eager fire at stop time raises out of the
  reactor instead of dying quietly with its task, stop; cancellation semantics are
  doctrine-owned.
- If the ToolRunner post-dispatch mount can't see result bytes without widening the
  ToolRunner's surface, stop before adding a parameter other cards' waves depend on.

### G2 — The GG-1 approval gate, fail-closed, attributed          [wave 4] [risk: medium] ✅ LANDED 9d8848d (registry pinned monotonic add-only, journal is the audit record; follow-ups: registry-rebuild-from-journal, human-reply→Answer grammar at the GG enablement wiring)

**Depends on:** G1
**Files:** `lib/lain/telemetry.rb` (this wave's one telemetry edit),
`lib/lain/gherkin/approval.rb` (create), `spec/lain/gherkin/approval_spec.rb` (create)
**Reuse:** `ask_human`'s promise + reply seam (`tools/ask_human.rb:87-114`); the fail-closed
posture and latency fields of `approval_decision` (`queue.rb:88-92,164-168`); the
plan-pinned surface constant `"auto_approver"` (M4 — a naming convention, not a code
dependency; this card's wave placement is telemetry-serialization-forced);
`Gherkin::Criteria#digest` (G1).
**Shared-file wiring:** `lib/lain/gherkin.rb` index line (orchestrator).

GG-1. `Gherkin::Approval#call(criteria, asker:)` renders the scenarios, asks via the
injected `ask_human` duck, and blocks on the promise with a timeout → **deny** (fail-closed,
signed by the clock). The verdict journals as `Telemetry::GherkinApproval` (criteria digest,
approved, answered_by, latency). `answered_by` distinguishes the human surface from an
auto-approver reply — the M4 surface can answer these exactly as it answers queue pendings,
opt-in at the call site. Downstream (G3's generation, P2's closure records) must check
`approved` before consuming a criteria digest; the spec pins the refusal path.

**Acceptance criteria:**

```gherkin
Scenario: approval is content-addressed and attributed
  Given criteria and an asker scripted to approve
  When the gate runs
  Then a gherkin_approval journals with the criteria digest, approved true, and answered_by the surface name
```
→ spec file: `spec/lain/gherkin/approval_spec.rb`

```gherkin
Scenario: silence denies
  Given an asker that never replies and a short timeout
  When the gate runs
  Then the result is denial, answered_by "timeout", and generation refuses to run against that digest
```
→ spec file: `spec/lain/gherkin/approval_spec.rb`

```gherkin
Scenario: edited criteria invalidate a prior approval
  Given an approved criteria digest and a criteria with one changed clause
  When generation is attempted with the changed criteria
  Then it refuses, naming the unapproved digest
```
→ spec file: `spec/lain/gherkin/approval_spec.rb`

**Escalation triggers:**
- `ask_human`'s Q&A are `:message` Store events — if attaching attribution requires a new
  meta key on those events, verify replay (`DryReplay` substitution of recorded replies)
  ignores unknown meta rather than diverging; if it diverges, stop.

### P3 — Execution shapes behind one continuation contract          [wave 4] [risk: high] ✅ LANDED 335cc1e (Continuation carries a head digest for shareability; linear accumulates all closed closures after panel round; supersession journal pointer landed 539efbc; follow-ups: at_seam fires on final-chunk close, multi-step chunks mainline only the terminal closure)

**Depends on:** P1, P2
**Files:** `lib/lain/plan/runner.rb` (create), `lib/lain/plan/seam_policy.rb` (create),
`lib/lain/plan/linear_rewrite.rb` (create), `lib/lain/plan/fork_per_step.rb` (create),
`spec/lain/plan/seam_policy_spec.rb` (create)
**Reuse:** `Context::Compact` + `Context.new(pipeline:)` (`context.rb:95,139-143`) for the
linear shape's render side; `Timeline#fork` + `Bench::Speculative`'s fork template
(`speculative.rb:40-57`) and closure appends via `Timeline#commit` for fork-per-step;
`Request#prefix_digests` (`request.rb:136`) as the churn proof; `Provider::Mock`
end-to-end; `Compaction::Scheduler`'s policy-object posture as the design precedent.
**Shared-file wiring:** `lib/lain/plan.rb` index line (orchestrator).

PC-3, with the panel's contract fix. **The two shapes have different state effects — the
contract says so instead of hiding it.** A seam policy answers
`at_seam(state, closure) → Plan::Continuation` where `Continuation = (timeline, pipeline)`:
the mainline Timeline to continue on AND the render pipeline for subsequent turns.
`ForkPerStep` acts on the timeline half (fork dies, closure digest commits to the mainline;
pipeline unchanged); `LinearRewrite` acts on the pipeline half (subsequent turns render
through a Compact-shaped pipeline whose summarizer is the closure's deterministic rendering;
timeline linear). **The driver is decided now, not discovered:** `Plan::Runner`, a
bench-style driver that owns per-turn Context construction (`Context.new(pipeline:
continuation.pipeline)` per turn) and seam detection from the `Plan::Document` — the same
built-for-the-bench posture as `Arm` and `Scheduler`. Live `agent.rb` wiring is the named
follow-up in Open decisions, NOT this card. Collaborators are declared and injected:
LinearRewrite takes a pipeline factory; ForkPerStep takes the store-backed timeline;
Runner takes both policies, the document, and the agent-step callable. Reopening a step is
a new fork whose closure supersedes by reference (never a rewrite of the closed record).
The same fixture plan runs under both shapes with Mock; switching shape changes zero plan
content.

**Acceptance criteria:**

```gherkin
Scenario: fork-per-step never rewrites the mainline
  Given a three-step fixture plan run by Plan::Runner under ForkPerStep with journaled requests
  When the prefix-digest chains are compared across seams
  Then every mainline chain is append-only (no rewrite) and each fork inherits the mainline prefix
```
→ spec file: `spec/lain/plan/seam_policy_spec.rb`

```gherkin
Scenario: the same plan runs under both shapes unchanged
  Given one Plan::Document
  When Plan::Runner executes it under LinearRewrite and under ForkPerStep
  Then both produce closure records for every step with equal step ids and grades
  And the plan document bytes are identical before each run
```
→ spec file: `spec/lain/plan/seam_policy_spec.rb`

```gherkin
Scenario: linear's rewrite is visible where fork's is absent
  Given the same plan under both shapes
  When each run's prefix chains are compared at the second seam
  Then LinearRewrite shows exactly one prefix rewrite and ForkPerStep shows none
```
→ spec file: `spec/lain/plan/seam_policy_spec.rb`

```gherkin
Scenario: reopening supersedes by reference
  Given a closed step whose closure exists
  When the step reopens and closes again under ForkPerStep
  Then the new closure names the superseded closure's digest and the old record is unchanged in the Store
```
→ spec file: `spec/lain/plan/seam_policy_spec.rb`

**Escalation triggers:**
- If `Continuation`'s two halves turn out to be insufficient for a hybrid shape (e.g.
  fold-selected-artifacts needs a third effect), stop — widen the contract deliberately,
  don't grow an options hash.
- If fork-per-step's "fork dies at the seam" collides with Budget/cancellation semantics
  (a stopped fork mid-chunk), stop and reconcile with the cancel-boundary doctrine.

### P5 — Journal calibration of size classes          [wave 4] [risk: low] ✅ LANDED 9f09128 (+fe90263 size addendum; panel blocker: stored-side size normalization — Symbol sizes folded invisibly; follow-up: drift table orders by journal insertion, not class)

> ⚠️ ESCALATED + RESOLVED (orchestrator, 2026-07-21): no journaled record carried the size
> class — `ClosureRecord` lacked `size`, and Plan::Document is never journaled, so the
> "journal alone" premise was unimplementable. Decision: extend `Plan::Closure` +
> `Telemetry::ClosureRecord` with `size` (derived from `step.size` in `Closure.build`),
> landed as a follow-on telemetry edit sequenced AFTER G2's wave-4 slot (preserving the
> one-edit-per-wave serialization); Calibration reads size nil-tolerantly (pre-migration
> lines fold as unclassed). P5 resumes after the addendum lands.

**Depends on:** P2
**Files:** `lib/lain/plan/calibration.rb` (create),
`spec/lain/plan/calibration_spec.rb` (create)
**Reuse:** `Telemetry::ClosureRecord` journal pointers (P2) for chunk boundaries;
`Telemetry::TurnUsage` records for tokens; `Journal.records` lazy reads; the distribution
rendering idiom of `Compare::Distribution`.
**Shared-file wiring:** `lib/lain/plan.rb` index line (orchestrator).

PC-5. Fold journals: for each closed chunk (from `closure_record` entries — the journal
pointer P2 writes, so calibration works across sessions and processes), measure turns +
tokens over the chunk's turn range; accumulate per size class; report medians and spread per
class; expose `#median_turns(size_class)` for P4's `calibration:` input.
Estimate-vs-actual drift per session is part of the report (the journaled, reportable
signal the spec names).

**Acceptance criteria:**

```gherkin
Scenario: classes calibrate from history
  Given journals containing six closure_record entries across S and M classes
  When Calibration folds them
  Then per-class turn and token distributions render and median_turns answers for each class
  And a class with no history answers nil (annotation fallback)
```
→ spec file: `spec/lain/plan/calibration_spec.rb`

**Escalation triggers:**
- If `closure_record` entries lack any field this fold needs (e.g. the chunk turn-range
  isn't recoverable), reconcile with P2 via the orchestrator — do not scan the Store, which
  does not survive the process.

### P4 — The seam EV decision          [wave 5] [risk: medium]

**Depends on:** F1, P1
**Files:** `lib/lain/telemetry.rb` (this wave's one telemetry edit),
`lib/lain/plan/seam_decision.rb` (create), `spec/lain/plan/seam_decision_spec.rb` (create)
**Reuse:** `Compaction::Scheduler`'s evaluate/accounting split (`scheduler.rb:92-98,167-193`)
as the policy-object template; `CacheProfile` (F1) + `PriceBook` for the cost side;
`Plan::Step` size classes (P1) for the payback side; `Calibration#median_turns` (P5) when
present; `Telemetry::Compaction`'s decimal-string cost convention.
**Shared-file wiring:** `lib/lain/plan.rb` index line (orchestrator).

PC-4. `Plan::SeamDecision#call(chunk:, profile:, prices:, calibration: nil)` computes
rewrite-cost (one cache write of the shorter prefix, priced via profile + PriceBook) vs
payback (tokens removed × estimated turns remaining from the size class — calibrated median
when supplied, annotation default otherwise) and answers rewrite-now / defer.
The decision and BOTH sides' inputs journal as `Telemetry::SeamDecision`. The linear shape
consults it at each seam; fork-per-step journals it as seam-density validation only.

**Acceptance criteria:**

```gherkin
Scenario: the decision and its inputs are auditable
  Given a chunk whose annotation says L and a profile with known prices
  When the decision runs
  Then a seam_decision journals carrying rewrite cost, payback estimate, the size class, and the verdict
```
→ spec file: `spec/lain/plan/seam_decision_spec.rb`

```gherkin
Scenario: a mis-sized annotation is visible, not silent
  Given a chunk annotated S that actually consumed 4x the S median
  When the decision report renders after the run
  Then the estimate-vs-actual delta is shown for that chunk
```
→ spec file: `spec/lain/plan/seam_decision_spec.rb`

**Escalation triggers:**
- If the EV inputs need live `cache_read_input_tokens == 0` confirmation (the CAC cold
  signal) beyond what `StatusFeed`/Usage already expose, stop — new provider-signal plumbing
  is out of this card's scope.

### P6 — The shape × density sweep          [wave 6] [risk: high] ✅ LANDED 262e806 (panel verified measurement honesty: columns derived not hardcoded, baseline can win, byte-identical across processes; fix round: empty plans and incomplete runs refuse loudly; follow-up: named reactive collaborator to make the equivalence auditable in one object)

**Depends on:** P3, P4, P5
**Files:** `lib/lain/bench/plan_sweep.rb` (create),
`spec/lain/bench/plan_sweep_spec.rb` (create),
`spec/fixtures/plans/` (create — one fixed multi-step fixture plan + scripted runs)
**Reuse:** `Bench::ArmSweep`'s sweep + honest-ABSENT reporting shape (`bench/arm_sweep.rb`);
`Compare` distributions (`compare.rb`); `Bench::Rewrites` for the cache-write column;
`ArmTasks`-style gold-file graders for the per-chunk score (NOT G4 — no live suite runs in
the sweep; deterministic fixtures only); `Provider::Mock` scripting; `Plan::Runner` (P3).
**Shared-file wiring:** `lib/lain/bench.rb` index line; `lib/lain/bench/cli.rb` subcommand
(orchestrator wiring for the mount, card scope for the class).

PC-6. One fixed multi-step fixture plan; arms = shapes (linear / fork-per-step) × seam
densities (every step / author-thinned / none = reactive `cache-aware-compaction` baseline);
scored grader × tokens × cache-write × wall-clock, distributions over n scripted runs;
wall-clock honestly ABSENT under replay (the arm-sweep precedent). The report answers "which
shape, at which density, for this task class" — and the reactive baseline is a first-class
arm so plan-shaped compaction has to *beat* something to claim anything.

**Acceptance criteria:**

```gherkin
Scenario: the sweep ranks shapes honestly
  Given the fixture plan and scripted runs for all six arms
  When the sweep renders
  Then every arm reports grader, tokens, and cache-write distributions, wall-clock reads ABSENT under replay,
  And the reactive baseline appears as an arm, not a footnote
```
→ spec file: `spec/lain/bench/plan_sweep_spec.rb`

```gherkin
Scenario: byte-identical reruns
  Given the same fixtures
  When the sweep runs twice
  Then the two reports are byte-identical
```
→ spec file: `spec/lain/bench/plan_sweep_spec.rb`

**Escalation triggers:**
- If fork-per-step under Mock cannot exercise the prefix-chain append-only proof (because
  Mock never populates cache fields), the cache-write column must derive from
  `Bench::Rewrites` over the journaled chains, not from Usage — if neither works, stop; do
  not fabricate the column.

## Integration checks

- `bundle exec rspec` — full suite green; no new pendings beyond the known set.
- `bundle exec rubocop` — clean, no `Metrics/*` loosening; new units follow the
  no-internal-requires-in-leaves rule (manifest/index lines only).
- `cargo test && cargo clippy --all-targets -- -D warnings` — unregressed (no Rust in this
  plan; the check guards accidents).
- `pre-commit run --all-files` — all hooks pass.
- Output-discipline spec green (new CLI classes return Strings; only the frontend prints).
- `Ractor.shareable?` pinned for every new value object (Gherkin, Plan, Closure,
  Improvement, CacheProfile, Continuation).
- **Manual pass (Joel):** run `lain friction` and `lain improve` over a real dogfood session
  journal from this repo, then `lain improvements` — confirm the notes are readable, evidence
  digests resolve, and nothing secret-shaped landed in the improvements file.
- **Manual pass (Joel):** author a tiny real plan with seams via P1's markdown, execute a
  two-step run under each shape with Mock scripting, and read the P6 report — confirm the
  seam edits you make in the markdown survive round-trip into the executed schedule.
- **Manual pass (Joel):** one live session with `AutoSurface` enabled beside the TTY
  surface — confirm the human still sees arrivals, auto decisions read as
  `surface: auto_approver` in the journal, and defer genuinely waits for you.
