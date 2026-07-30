# Compaction tiers, pinned history, and isolation invocation

status: done
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman · Aaron Patterson (Ruby roster, `create-plan/references/rosters.md`)

## Intent

Three coupled deliverables on top of the compaction pipeline that landed 2026-07-25
(`chunk-live-wiring.md`). **(A)** Make the summarizer a *tier* rather than a hardcoded local
model: selectable provider/model, journalled spend, and a **custom deterministic tier** —
user-supplied summarizer classes answering `suitable?(result)` and `compact(result)`, so rspec
output, rails logs, a psql result, and a coverage report are four objects each claiming only what
it can actually compress, consulted before any model call. **(B)** Let a human **pin** history the
compactor may not touch, with `/goal` objectives auto-pinned. **(C)** Make the isolation
backends — built and spec'd in `chunk-orchestration-arms-isolation.md`, reachable from nothing —
invocable from both `lain chat` and the bench, with a worker's commits preserved to a private ref
and handed back to the parent checkout when the worker completes — and, when that conflicts, the
orchestrator spawning a resolver over a fresh root so its own context stays clean.

Satisfies ROADMAP:225-234 (the decider-locus tiers and OR-6's "shared protected-pins policy")
and folds in follow-ups 13 and 14 from `chunk-live-wiring.md:1077-1090`. It does **not** satisfy
ROADMAP:583-585 (pane cwd = the agent's worktree): D2 wires the backend into `Supervisor`, but
nothing here makes a tmux pane's cwd the worktree, and the `role@branch` pane title that line
asks for is unachievable as built, since the worktree is detached and has no branch.

## Grounding

Verified **2026-07-25** by three parallel `Explore` passes against `main` at `ad72d5d`. Code is
source of truth; where a doc disagreed, the code won and the disagreement is recorded.

**The summarizer tier is hardcoded and unjournalled.**
- `lib/lain/cli/backend.rb:280-284` — `#summary_oracle` builds
  `Oracle::Model.new(definition: Oracle::Summarize.definition, provider: Provider::Ollama.new(api_base:), model: Provider::Ollama::DEFAULT_MODEL)`.
  It is **not** wrapped in `Oracle::Recorded::Journaling`, so eager summary Q&A produces no
  `Telemetry::OracleAnswer` on the live chat path. A paid tier would spend with no record.
  `max_tokens` falls through to `Oracle::Model::DEFAULT_MAX_TOKENS` (1024).
- `Oracle::Definition#digest` (`oracle/definition.rb:58`) folds `tier.to_s` under a `"tier"` key,
  so a new tier value is automatically a new oracle address and any existing `Recorded` journal
  misses **loudly** (`Recorded::Unrecorded`, `recorded.rb:30`). Pinned by `oracle_spec.rb:78`.
- `Backend::COMPACTION_PRICES` (`backend.rb:74`) is a zero-fallback `PriceBook`. It prices
  `Telemetry::Compaction`'s `cost_saved`/`cost_spent`, which are annotations on a decision made
  on **bytes**; it does not price the summarizer's own spend. Summarizer spend rides
  `Telemetry::OracleAnswer#usage` (`telemetry.rb:706`) — which is why A1 must journal.

**The summarizer duck is constrained by shareability, and that decides where custom tiers live.**
- `Context::Compact#initialize(threshold:, keep_last:, summarizer:, protected_patterns: ProtectedPatterns::NONE)`
  (`context/compact.rb:40`). The `summarizer:` duck is `#call(Array<Hash>) -> non-empty String`,
  pure, and on the live path must be `Ractor.shareable?` — `Compaction::Scheduler::COMPOSE`
  (`scheduler.rb:143`) wraps the composed pipeline in `Ractor.make_shareable`, pinned by
  `scheduler_spec.rb:154-164` and `source_spec.rb:335-353`.
- **Decision: custom summarizers are objects at the eager tier, not summarizers on `Context::Compact`.**
  The decisive reason is **interface shape**. A custom summarizer answers `suitable?(result)` and
  `compact(result)` about **one tool result**; `Context::Compact`'s `summarizer:` answers
  `#call(Array<Hash>) -> String` about the **whole dropped span**. Those are different questions,
  and "is this rspec output / a psql result / a coverage report" is only answerable per result.
  The eager tier is already per-result, already keyed by source digest, and already off the render
  path.
  Shareability is a corroborating constraint rather than the argument, and the honest version is
  narrower than it first appears — measured on ruby-4.0.5, a **frozen instance holding no state is
  `Ractor.shareable?`; one holding a Proc is not**. So a well-behaved custom summarizer *could*
  survive `Scheduler::COMPOSE`, but nothing makes user code well-behaved, and the failure would
  land as a `Ractor::IsolationError` on the first compacting turn of a live chat rather than in a
  spec. That is the same class of live-path failure `chunk-live-wiring.md`'s A8 fixed, and
  follow-up 11 there records `Oracle::Heuristic` as already non-shareable for holding a
  `@predicate` Proc.

**A tool result block does not carry the tool's name.** `ToolRunner#result_block`
(`agent/tool_runner.rb:189-200`) builds exactly four keys: `"type"`, `"tool_use_id"`, `"content"`,
`"is_error"`. The name exists only upstream, at `tool_runner.rb:186` and `:206`
(`tool_use.fetch("name")`), and on the `Effect::ToolCall`. `Summarizing::Observer#observe`
(`effect/handler/summarizing.rb:55-57`) receives only that block. So a summarizer that decides
suitability by tool name needs the name **threaded down**, and A3 owns that change. (Found by the
plan's own panel review; the first draft asserted the name was already available and would have
sent a sub-agent looking for a key that does not exist.)

**`Kernel.load` reopens a same-named class, so subclass diffing cannot be the discovery
mechanism.** Measured on ruby-4.0.5: loading a second file that declares `class Foo < Base`
reopens the first `Foo` — `Base.subclasses` does not grow, and the diff is empty. A second
`Catalog.load` in one process (two specs over one fixture dir, `/fork`, `--resume`) produces an
empty diff for a catalog that loaded fine the first time. `Class#subclasses` is also
**direct-only**: `Base > Mid > Leaf` reports `[Mid]`, so a user file with an intermediate base
hides the real summarizer while still passing an "exactly one" check. A2 therefore uses the
`Services::Builder` DSL shape instead, which has neither problem.

**Session state does not survive `--resume` unless it is replayed.**
`SessionRecord::Replay#session` (`session_record/replay.rb:48-53`) rebuilds exactly two things
from three record types (`session_read`, `todo_snapshot`, `memory_root`, `:26-28`).
`Session::Journaled#record_write` (`session.rb:334-337`) **forwards without journalling**, and its
own comment says a replayed session rebuilds with an empty write-set because persistence is a
later ticket. So `record_read`/`read?` is the pair to mirror and `record_write`/`written?` is not:
mirroring the latter yields pins that silently vanish on resume. B1 owns a new replayed record
type and a new `Replay` branch.

**The worktree is deliberately detached, and its commits are deliberately unreachable after
reclaim.** `worktree.rb:16-30` argues both at length: `add --detach` (`:126`) rather than a bare
add, because a bare add leaks a branch per cycle **and** a re-acquire after a crash would check
out that leaked tip, "bleeding a crashed worker's committed state into its successor and defeating
isolation on exactly the crash-restart path". And: "UNCOMMITTED WORK IS SCRATCH… the ONE thing
release must never do is leave the checkout on disk, because a leaked worktree silently defeats
the next acquire." `#remove` (`:143-151`) is `git worktree remove --force`, and `#reap` (`:155-160`)
force-removes any leftover **before the next add**. Consequences D4 must respect: there is no ref
to merge unless one is created; leaving a conflicted worktree on disk does not preserve it,
because the next acquire of that worker id reaps it; and `Lease#release` marks released *before*
running its action (`lease.rb:45-51`), so a raising release strands the path in `@leased`.
**D4's design follows from this**: capture the worker's HEAD into a ref under a private namespace
*before* reclaim, so the work survives the worktree either way.

**Pins: the mechanism exists, is wired off, and turning it on has a pre-ruling attached.**
- `Context::ProtectedPatterns` (`context/protected_patterns.rb`) is the only protect mechanism.
  `#initialize(patterns = [])` is **positional**; `#protects?(text)` (`:34`) takes a **String**;
  `#coerce` (`:45`) treats a Regexp as-is and anything else as an escaped literal substring.
  `NONE` is assigned at `Context` scope (`:51`). Four consumers accept `protected_patterns:`:
  `Compact` (`:40`), `Prune` (`prune.rb:43`), `DedupeToolCalls` (`dedupe_tool_calls.rb:18`),
  `PurgeFailedInputs` (`purge_failed_inputs.rb:34`). **No production site passes anything but
  `NONE`** — `compaction/source.rb:328` passes it explicitly, citing the ruling.
- **The binding pre-ruling** (`chunk-live-wiring.md:189-203`, 2026-07-25): *"If a later chunk
  wants protected patterns live, `Head` must become protected-aware in the same change — A5 left
  a characterization example pinning today's behavior so this cannot re-hide."* That example is
  `spec/lain/compaction/head_spec.rb:132` ("names the whole candidate span, protected survivors
  included"). B2 is that change; updating that spec is **mandatory**, not incidental.
  Rationale for the original ruling was cost on the hot path: `Head#bytesize` is consulted every
  turn, `Compact`'s partition only on compacting turns.
- **`meta` is invisible to compaction.** Both projections drop it:
  `compaction/source.rb:204` and `head.rb:34` build `{"role" => turn.role, "content" => turn.content}`.
  A `meta`-based pin marker would never be seen. The only `meta` key used anywhere is
  `"spawned_from"`.
- **`Session` is the right home.** `Source#context_for(base:, timeline:, usage:, session:)`
  (`source.rb:170`) **already receives the session**, and `Session` already has the exact
  precedent shape: `record_read`/`read?` (`session.rb:88,94`), `record_write`/`written?`
  (`:104,110`), with `Session::Journaled` (`:296`) as the journalling decorator and
  `Session::Null` (`:225`) as the no-op. Pins ride that seam, not `Event#meta`.
- No `pin`/`pinned`/`important`/`sticky`/`no_summarize` concept exists anywhere in `lib/`.

**The shrink floor can swallow a pin-heavy history.** `Source#shrinks?` (`source.rb:269`) is
strict — byte-neutral is declined and journalled `would_not_shrink`. Pinning enough messages can
flip a compacting turn into a permanent defer. Pinned at the 366/367-byte crossover by
`source_spec.rb:528-542`.

**The empty-summarizable trap is already handled.** `Compact#call` calls the summarizer with `[]`
when protection exempts everything; `SummarySnapshot::NOTHING` (`summary_snapshot.rb:60`) exists
for it, pinned by `summary_snapshot_spec.rb:302` — the one spec that exercises `Compact` with a
real `ProtectedPatterns` and a real `SummarySnapshot` together.

**Isolation is complete, spec'd, and reachable from nothing.**
- The seam is `acquire(worker_id) -> Lease`; `Lease` (`isolation/lease.rb:22`) carries
  `worker_env` and an idempotent-loud `release` that marks released **before** running the action.
- Backends: `Null` (`null.rb:13`), `Worktree(root:, repo_root: Dir.pwd, paths:, shell_out_factory:)`
  (`worktree.rb:83`). Decorators over any `#acquire` duck:
  `DbIndex(services:, inner: Null.new, ...)` (`db_index.rb:98`),
  `Compose(services:, inner: Null.new, ...)` (`compose.rb:183`),
  `Journal(backend:, journal:)` (`journal.rb:36`). They stack, but **no spec stacks them** — every
  decorator spec passes `inner: Null.new`, and `grep Worktree` over both decorator specs is empty.
- **One wire to cut:** `lib/lain/cli/wiring.rb:88` — `@supervisor = Lain::Supervisor.new(journal: channel)`.
  That is the only place a non-Null backend can reach the running fleet. Everything downstream
  already honors one: `Supervisor#adopt` acquires at `supervisor.rb:109`, hands `lease.worker_env`
  to the launch block at `:166`, releases on launch failure at `:171` and on `#stop` at `:142`.
- **Only actor-mode subagents lease.** `Subagent#adopt_actor` (`tools/subagent.rb:243`) receives
  the `worker_env`; one-shot spawns route to `spawn_one_shot` (`:225-230`) and never touch the
  supervisor, and `Skill::RoleSpawn#call` (`skill/role_spawn.rb:53`) uses the one-shot path. So a
  `@role/skill` line never leases today. **Scope consequence:** `--isolation` affects actor-mode
  subagents only; D2 states this in its help text rather than silently under-delivering.
- **There is no name->backend resolver anywhere.** D1 is new code, as is any `Worktree(root:)`
  path policy and the `Services.load` call. `Isolation::Journal`'s own doc (`journal.rb:30-31`)
  warns it must wrap **exactly once, nearest the concrete backend**.
- **`Worktree#release_path` runs `git worktree remove --force`** (`worktree.rb:132-137`), which
  destroys uncommitted work. Any merge-back must therefore happen **before** release, not in the
  `on_release` action. This is the ordering constraint behind D4.
- `Arm::NoIsolation` (`arm.rb:23-35`) is a module whose `Lease#worker_env` is **`nil`**, not a
  `WorkerEnv` — deliberately, to avoid depending on the Isolation unit. Do not treat it as a
  backend. `Arm::Driver#initialize(arms, tasks:, spawn_seam:, grader:, isolation: NoIsolation)`
  (`arm/driver.rb:39`) threads it to every arm at `:66`.
- `.lain/services.rb` **has no production caller today**; `Services.load` is exercised only by
  `spec/lain/isolation/services_spec.rb`. D1 is its first caller.

**The user-Ruby-from-`.lain/` precedent.** `Isolation::Services::Builder.build(source, path)`
(`isolation/services/builder.rb:35-39`) is `instance_eval(source, path, 1)` — passing `path` and
line `1` so **backtraces point into the user's file**. Fixed verb list `VERBS = %i[postgres redis compose]`
(`:16`), each verb returning its frozen declaration, with `method_missing` raising
`Builder::Unknown` naming the known verbs (`:53-56`) and `Builder::Duplicate` for collisions
(`:69-92`). A2 copies this shape exactly. The only other `eval` in `lib/` is `Command::Ruby`.

**`/meta`'s discipline.** `Command::Meta` (`cli/command/meta.rb`) spawns the read-only
`meta_harness` role (`role/catalog.rb:32`, `only: %i[read_file list_files glob grep]`), writes
`.lain/meta/<slug>.rb` with a GENERATED header, and **never executes** what it wrote; `/meta run`
is a separate verb guarded by `SLUG = /\A[a-z0-9-]+\z/` (`:32`). A4 reuses that generate-then-review
split verbatim.

**Docs vs code, resolved.** `ROADMAP.md:800-815` still calls the live-wiring chunk "Planned"
while `chunk-live-wiring.md:3` says `status: done`. Code won; the ROADMAP line is corrected by
this plan's index entry.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `exe/lain`,
  `lib/lain/cli/command.rb`, `lib/lain/oracle.rb`, `lib/lain/context.rb` (the
  `REQUIRES`/combinator index), `lib/lain/role/catalog.rb`, `lain.gemspec`, `.rubocop.yml`,
  `spec/spec_helper.rb`, `spec/support/tags.rb`.
  **`exe/lain` is orchestrator-owned this chunk** because D2, D3, and A1 all add
  `method_option` lines, and **`lib/lain/role/catalog.rb`** because A4 and D5 each add one role;
  cards hand back the one-line diff and never edit either file.
- **`lib/lain/telemetry.rb` is orchestrator-owned.** B1, D4, and C2 each add or amend one record.
  They are in different waves so they cannot collide, but the record and its `Guards::` entry are
  handed back as a diff, following the same discipline `chunk-live-wiring.md:132-141` used.
- **`Metrics/ClassLength` headroom, measured 2026-07-25** (`Max: 110`). Cards editing these must
  extract a collaborator rather than loosen the cop, and must report the class length they leave
  behind:

  | Class | Now | Cards touching it |
  |---|---|---|
  | `CLI::Wiring` | 108 | D2 |
  | `CLI::Backend` | 96 | C1, A1, A3 (three waves, 14 lines of headroom) |
  | `Compaction::Source` | 93 | B2, C1 |
  | `Command::Meta` | 81 | A4 |
  | `Session` | 75 | B1 |

  `CLI::Backend` is the one to watch: it was 46 before the last chunk. A1 adds a method; if the
  three cards together would cross 110, the extraction is A1's (a `Backend::Summarizer` collaborator
  owning tier construction), not a later card's emergency.
- **Deviation 1 (execution, 2026-07-25): agent worktrees fork stale.** Every `isolation: worktree`
  agent forks at `fddc8e3` — 16 commits behind `main` at `ad72d5d` — where `Compaction::Source`,
  `ContextWindow`, and `Backend#compaction_source` do not yet exist (baseline 4082 examples, not
  4328). Caught by C1's first pass, which escalated rather than working around it. Every
  implementer's brief now opens with one permitted git command, `git merge --ff-only main`, before
  any other work; the "never run git" rule holds for everything after it.
- **Deviation 2 (ruling, 2026-07-25): C1's Files list is widened by two call sites.** Making
  `window_tokens` a `Need#check` parameter breaks `Need.new`'s other callers, none of which the
  card listed: `lib/lain/bench/plan_sweep/driver.rb:121` (and its `#check` at `:144`) and
  `spec/lain/tools/todo_write_spec.rb:176`. This is mechanical signature follow-through, not scope
  creep, so C1 owns both rather than leaving a broken build for a later card.
- **Note (execution): the in-worktree baseline is 4323 examples, not 4328.**
  `spec/lain/gherkin_spec.rb:248` globs `planning/specs/*.md`, and the five chunk plan docs are
  untracked — they exist in Joel's checkout and not in any agent worktree. The 5-example gap is
  that glob, nothing else. Use **4323** as the worktree baseline.
- **Deviation 4 (ruling, 2026-07-25): C1 also edits `spec/lain/cli/backend_spec.rb`.** That file's
  blank-`--model` example pinned the `ContextWindow::UnknownModel` raise at *construction*, which
  is precisely what Deviation 3 relocates to the first render. Rewriting it to assert the raise on
  `context_for` is inside Deviation 3's blast radius, not new scope.
- **Deviation 5 (execution): A2 edited `lib/lain.rb` itself.** Without the require line
  `require "lain"` never defines the constant and *every* spec errors at load, so the green gate
  is unverifiable without it. The diff is one additive line; the orchestrator re-applies it. Same
  reasoning was pre-authorized for B1 and D1.
- **Deviation 6 (correction, 2026-07-25): D1's shared file is `lib/lain/cli.rb`, not `lib/lain.rb`.**
  The card named the wrong index. `lib/lain.rb:56` carries only `require_relative "lain/cli"`; every
  `cli/*` entry lives in `lib/lain/cli.rb`, which is that subtree's index. Verified. D1 put its
  require there and left `lib/lain.rb` untouched — correct per the Requires policy. **Add
  `lib/lain/cli.rb` to the orchestrator-owned shared-file list** (D2 does not add a require, but a
  later card might).
- **Deviation 7 (ruling, 2026-07-25): B3 pins at the driver, and its AC1 is reworded.**
  B3's escalation trigger fired, correctly and with proof. The objective's turn digest is **never**
  knowable when `/goal` runs: `/goal` is a registry command, `Repl#dispatch` short-circuits before
  `@agent.ask`, so it commits **no turn at all** — it only flips `GoalDriver`'s in-memory delegate.
  The objective becomes a turn strictly later, when `Repl#next_text` polls the driver and feeds
  `Run#drive`'s "Standing goal: …" prompt back as a typed line. Verified empirically against a real
  `Agent` + `Provider::Mock`: the head digest is byte-identical before and after `/goal`, naming the
  *previous topic's* assistant turn. A naive head-digest pin would permanently protect prior noise
  while leaving the objective elidable — the exact B2 inversion. On a fresh session `head_digest` is
  `nil` and B1 refuses loudly, so `/goal` as a first line would crash rather than mis-pin.
  **Ruling: option A — the driver pins the objective's turn once that turn exists.** Both files it
  needs are already in B3's Files list. Consequent amendments: **AC1 is reworded** from "setting a
  goal pins the objective" to "the objective's turn is pinned once it enters the timeline", and
  `spec/lain/cli/goal_driver_spec.rb` **is added to B3's Files**. AC2 and AC3 stand unchanged.
  Rejected: pinning at the ask boundary (needs `repl.rb`, out of scope — recorded as a follow-up if
  the first-ask window proves unacceptable), and treating the auto-pin as unnecessary because
  `Run#prompt` re-sends the objective each iteration (true while the goal is *active*, but AC2 is
  precisely about surviving `/goal off`, so the pin still earns its place).
- **Deviation 8 (user ruling, 2026-07-25): D3's `exe/lain` line has no attachment point; deferred.**
  D3 escalated that there is no `bench` subcommand running arms, and it is right — verified
  independently: `exe/lain`'s bench exposes only `variance`, `record`, `plan-sweep`, `sweep`, and
  `Arm::Driver` has **no production caller anywhere** (its own spec, plus a doc mention in
  `bench/arm_sweep/report.rb` stating it deliberately does *not* subclass it). The card's grounding
  verified that `Arm::Driver` threads `isolation:` to every arm, but not that anything constructs a
  Driver. `Bench::ArmSweep` runs arms without the Driver (per-task graders vs one grader), so it is
  not the attachment point either.
  **Joel's ruling: defer.** D3 ships `Bench::CLI#arm_report` as the seam; a `lain bench arms`
  subcommand plus its `exe/lain` option becomes its own follow-up card (ticket 7 below).
  **Consequences, recorded so they do not silently drop:** manual passes **5 and 6 are deferred**
  with it — the bench half of deliverable (C) is spec-reachable only this chunk — and **D5's arm
  changes likewise land reachable from specs alone** until that card. `lain chat --isolation
  worktree` (D2, manual pass 7) is unaffected and remains the live path.
- **Deviation 9 (finding, 2026-07-25): `--isolation` is inert on the chat path too; manual pass 7
  is also not runnable.** The same grounding gap as Deviation 8, in the other half of deliverable
  (C). The plan verified that *only actor-mode subagents lease* and that `Supervisor#adopt` hands
  `lease.worker_env` to the launch block — both true — but not that anything **constructs an
  actor-mode subagent** on the chat path. Verified independently: `Wiring#research_subagent`
  (`wiring.rb:169`) and `Skill::RoleSpawn#build_subagent` (`role_spawn.rb:60`) are the only chat
  construction sites and **neither passes `mode:`**, so both default to `:one_shot`; `@mode` is
  fixed at construction, not a model-settable input. The only other `adopt` caller,
  `Supervisor::Restart`, has **zero callers** outside its own file. So no chat-reachable path calls
  `supervisor.adopt`, and D2's ACs are proven only through a hand-driven `adopt`.
  **Consequence: manual pass 7 is not runnable either.** All three isolation manual passes (5, 6,
  7) are deferred, and the whole of deliverable (C) lands this chunk as a seam ahead of its
  consumer. D2's `exe/lain` help text must say what is true rather than promise reachable
  behavior — the orchestrator owns that line and writes it honestly. Recorded as ticket 13.
- **Deviation 3 (ruling, 2026-07-25): a blank model may raise on the render path.**
  `ContextWindow#window_tokens` raises `UnknownModel` for a nil/blank model by design
  (`context_window.rb:98-107`), and C1 moves that call from startup to per-turn. Raising later but
  still loudly is correct doctrine — a blank `Context#model` is a wiring bug, and the existing
  comment at `backend.rb:239` already says so. C1 pins it with a spec rather than rescuing it.

## Open decisions

None gating any card. Four rulings recorded so they are not relitigated:

- **A custom summarizer is a class with `suitable?(result)` and `compact(result)`, mounted at the
  eager tier** (user, this interview). Not a Proc and not a matcher/transform pair held apart: the
  two questions belong to one object because the answer to "can I compress this" and "how" are the
  same knowledge. Rspec output, rails logs, a psql result, and a coverage report are four objects,
  each suitable only some of the time. A card that finds itself injecting one into
  `Context::Compact` has taken a wrong turn — stop and escalate.
- **Pins live on `Session`, not on `Event#meta`.** Both compaction projections drop `meta`
  (`source.rb:204`, `head.rb:34`), and `Source#context_for` already receives `session:`. Using
  `meta` would require changing two projections and would put retention policy inside the
  content address.
- **The `name:verb` modifier grammar is deferred** (user, this interview). `/pin` and `/unpin`
  ship as ordinary commands this chunk; extending `Skill::Invocation`'s grammar
  (`skill/invocation.rb:66-76`) so `/goal:pin` attaches a pin to another command's message is a
  designed-but-deferred ticket, recorded below, because every command would then have to
  understand the namespace.
- **The span summarizer is deferred** (user, this interview). Collapsing a back-and-forth *span*
  of conversational turns is a different shape from summarizing one immutable tool result: the
  eager tier's cache key is the result's source digest, which cannot go stale, whereas a span's
  boundaries move every turn. Design note and ticket below; not built here.

## Waves

```
Wave 1: A2, B1, C1, D1                (no unmet deps)
Wave 2: A1 (←C1), B2 (←B1), B3 (←B1), B4 (←B1), D2 (←D1), D3 (←D1), D4 (←D1)
Wave 3: A3 (←A1,A2), A4 (←A2), C2 (←C1), D5 (←D4)
```

Critical path: **C1 → A1 → A3** (three cards; ties with D1 → D4 → D5, which is the same length
but lower risk per card).

## Tasks

### A1 — Make the summary oracle a selectable, journalled tier          [wave 2] [risk: medium]

**Depends on:** C1
**Files:** `lib/lain/cli/backend.rb` (modify `#summary_oracle`, add `#summarizer_provider`),
`spec/lain/cli/backend_spec.rb` (modify)
**Reuse:** `Backend#provider`'s existing `PROVIDERS`/`UnknownProvider` resolution
(`backend.rb:36,110,219`) — the summarizer's provider name must resolve through the **same**
validated set, not a second copy; `Oracle::Recorded::Journaling` (`oracle/recorded.rb:92-139`)
for the journalling wrap; `Backend#knob` (`:252`) for flag defaults.
**Shared-file wiring:** `exe/lain` — three `method_option` lines on `chat`:
`:summarizer_provider` (string, default `"ollama"`), `:summarizer_model` (string),
`:summarizer_max_tokens` (numeric, default `Oracle::Model::DEFAULT_MAX_TOKENS`).

**Acceptance criteria:**

```gherkin
Scenario: the summarizer defaults to today's local tier
  Given a Backend built with no summarizer flags
  When the summary oracle is constructed
  Then its provider is a Provider::Ollama and its model is Provider::Ollama::DEFAULT_MODEL

Scenario: the summarizer can be pointed at a paid model independently of the chat model
  Given a Backend built with --provider ollama and --summarizer-provider anthropic
  When the summary oracle and the chat provider are both constructed
  Then the chat provider is a Provider::Ollama and the summary oracle's provider is an Anthropic one

Scenario: summarizer spend lands on the record
  Given a Backend with a journal wired
  When the summary oracle answers one question
  Then a Telemetry::OracleAnswer record is journalled carrying the model and a non-empty usage

Scenario: an unknown summarizer provider is refused by name
  Given a Backend built with --summarizer-provider notreal
  When the summary oracle is constructed
  Then Lain::UnknownProvider is raised naming the valid set

Scenario: the summarizer's token ceiling is settable and defaults
  Given a Backend built with no summarizer flags
  When the summary oracle is constructed
  Then its max_tokens is Oracle::Model::DEFAULT_MAX_TOKENS
  And a Backend built with --summarizer-max-tokens 256 constructs one with that ceiling
```
→ spec file: `spec/lain/cli/backend_spec.rb`

**Escalation triggers:**
- `backend_spec.rb:313` asserts the `Summarizing::Observer` is built over **the one** `Eager`, and
  `:328` that the source is built once per run. If wrapping the oracle in `Journaling` makes
  either fail, the wrap is in the wrong place — it belongs inside `#summary_oracle`, beneath
  `#eager`'s memoization. Stop rather than relaxing those.
- `Oracle::Recorded::Journaling` double-records if stacked (`recorded.rb:92-100`). If any existing
  path already wraps this oracle, stop — mount exactly one, outermost.
- If a paid summarizer makes `Telemetry::Compaction`'s `cost_spent` look wrong, that is C2's
  territory, not this card's. Do not touch `COMPACTION_PRICES` here.

### A2 — Load user summarizers from `.lain/summarizers.rb`          [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/summarizer.rb` (create), `lib/lain/summarizer/base.rb` (create),
`lib/lain/summarizer/result.rb` (create), `lib/lain/summarizer/builder.rb` (create),
`spec/lain/summarizer/base_spec.rb` (create), `spec/lain/summarizer/builder_spec.rb` (create)
**Reuse:** `Isolation::Services` + `Services::Builder`
(`isolation/services.rb:20-41`, `isolation/services/builder.rb:14-96`) is the pattern to copy:
`Builder.build(source, path)` → `instance_eval(source, path, 1)` so **backtraces point into the
user's file**, a fixed verb list, `method_missing` → loud `Unknown` naming the known verbs
(`:53-56`), duplicate name → loud `Duplicate` (`:69-74`), absent file → an empty frozen
`Enumerable` collection, never an error (`services.rb:28-31`).

The shape, decided in Open decisions and re-grounded after the panel:

- `Summarizer::Result = Data.define(:tool_name, :text)`, frozen — what both methods receive. It
  carries the tool name **and** the text because some kinds are distinguishable by tool and some
  only by content (a coverage report and a build log are both `bash`). A3 supplies the name.
- `Summarizer::Base` declares `suitable?(result) -> Boolean` and `compact(result) -> String`, each
  raising `NotImplementedError` naming the summarizer, in the shape `Arm#run` uses
  (`arm.rb:109-112`).
- **Discovery is a DSL verb, not class-constant discovery.** One `summarizer "<name>" do … end`
  verb per declaration; the block is `class_eval`'d into a fresh anonymous `Class.new(Base)`, so
  the user writes the two methods as ordinary methods and every load produces a distinct class
  object. `Kernel.load` + `Class#subclasses` diffing was the first draft's mechanism and **is
  measurably broken** — see Grounding: a second load of a same-named class reopens it and the
  diff comes back empty.

**Shared-file wiring:** `lib/lain.rb` — one `require` line for the `summarizer` unit, anywhere
before `oracle` (`lain.rb:54`), which A3 needs.

**Acceptance criteria:**

```gherkin
Scenario: an absent file is an empty catalog, not an error
  Given a project root with no .lain/summarizers.rb
  When the catalog is loaded
  Then it is empty and no error is raised

Scenario: a declared summarizer answers for what it is suitable for
  Given a .lain/summarizers.rb declaring a summarizer suitable for coverage output
  When the catalog is loaded
  Then it holds one summarizer
  And that summarizer is suitable for a coverage result and not for an unrelated one

Scenario: the catalog returns the suitable summarizer for a result
  Given a catalog declaring a coverage summarizer and an rspec summarizer
  When it is asked for a summarizer for an rspec result
  Then the rspec one is returned

Scenario: declaration order decides between two suitable summarizers
  Given a catalog declaring two summarizers both suitable for the same result
  When it is asked for a summarizer for that result
  Then the first declared one is returned

Scenario: an unsuitable result gets no summarizer
  Given the same catalog
  When it is asked for a summarizer for an unrelated result
  Then nothing is returned

Scenario: loading the same catalog twice yields equivalent, independent summarizers
  Given a .lain/summarizers.rb declaring one summarizer
  When the catalog is loaded twice in one process
  Then both loads succeed and both hold a summarizer suitable for the same result

Scenario: a summarizer implementing nothing refuses loudly
  Given a summarizer declared with an empty block
  When it is asked whether it is suitable
  Then NotImplementedError is raised naming that summarizer

Scenario: a typo'd verb fails loudly naming the known verbs
  Given a .lain/summarizers.rb calling an undeclared verb
  When the catalog is loaded
  Then Summarizer::Builder::Unknown is raised naming the valid verbs

Scenario: a duplicate summarizer name is refused
  Given a .lain/summarizers.rb declaring the same name twice
  When the catalog is loaded
  Then Summarizer::Builder::Duplicate is raised naming the collision

Scenario: a raise inside a user summarizer names the user's file
  Given a .lain/summarizers.rb whose compact raises
  When that summarizer is asked to compact
  Then the raised error's backtrace names .lain/summarizers.rb
```
→ spec file: `spec/lain/summarizer/builder_spec.rb`, `spec/lain/summarizer/base_spec.rb`

**Escalation triggers:**
- A summarizer is **pure and synchronous**: text in, text out. If a declaration appears to need a
  provider, a model, or any IO, stop — that is A1's tier, and this tier's whole value is costing
  no tokens and no latency.
- Do not reach for `Kernel.load` + `Class#subclasses`, an `inherited` hook, or a global mutable
  registry. The first is measurably broken on reload (Grounding), and the other two make load
  order observable, so a spec's throwaway declaration leaks into the next example.
- Do **not** load the catalog at `require` time. `Skill::Catalog.load(root:)` and
  `Services.load(root:)` both take an explicit root; match that or specs cannot use a tmpdir.
- If "first declared wins" feels arbitrary while implementing, stop rather than inventing a
  scoring rule — declaration order is the user's lever, and a score is a second thing to explain.

### A3 — Consult custom summarizers before the model tier          [wave 3] [risk: high]

**Depends on:** A1, A2
**Files:** `lib/lain/oracle/routed_summarizer.rb` (create), `lib/lain/cli/backend.rb` (modify
`#summary_oracle` to wrap), `lib/lain/effect/handler/summarizing.rb` (modify — accept and pass the
tool name), `lib/lain/agent/tool_runner.rb` (modify — supply the tool name to the observer),
`spec/lain/oracle/routed_summarizer_spec.rb` (create), `spec/lain/cli/backend_spec.rb` (modify)
**Reuse:** `Oracle::Heuristic` (`oracle/heuristic.rb:11-29`) is the existing deterministic tier and
answers the same `#ask(inputs) -> Promise` / `#model` / `#usage` trio the model tier does — a
matched custom summarizer should answer **through** it rather than inventing a fourth tier shape.
`Oracle::Summarize::SCHEMA` (`summarize.rb:22`) is the answer shape both tiers must produce, and
`Compaction::SummarySnapshot.take` reads `.summary` off it (`summary_snapshot.rb:135`).
`Oracle::Eager::DEFAULT_SLOT` (`eager.rb:31`) names the input slot.

**The tool name is not where the first draft said it was.** `ToolRunner#result_block`
(`agent/tool_runner.rb:189-200`) emits four keys and none is the name; the name lives at
`tool_runner.rb:186`/`:206` as `tool_use.fetch("name")`. `Summarizing::Observer#observe`
(`summarizing.rb:55-57`) sees only the block. So this card threads the name from `ToolRunner` to
the observer and builds A2's `Summarizer::Result` there. Do **not** add the name to the wire block
itself — that block is the `tool_result` sent to the provider, and gate 4 pins its shape.

**Nesting order, which must be stated because getting it wrong raises.**
`Recorded::Journaling` (`recorded.rb:92-139`) defines neither `#model` nor `#usage` and calls
`@inner.model`/`@inner.usage` when journalling. A1 wraps the model tier in `Journaling`; this card
wraps that in `RoutedSummarizer`. The order is **`RoutedSummarizer` outermost**, so a custom answer
never reaches `Journaling` at all and a fallen-through answer is journalled exactly once by the
inner wrap. `RoutedSummarizer` must still answer `#model` and `#usage` honestly for a custom
answer — `nil` and `{}`, as `Heuristic` does (`heuristic.rb:27-28`).
**Shared-file wiring:** `lib/lain/oracle.rb` — one `require_relative` for `routed_summarizer`,
after `summarize` and before `eager`.

**Acceptance criteria:**

```gherkin
Scenario: a suitable custom summarizer answers without a provider call
  Given a routed summarizer over a catalog holding a coverage summarizer and a recording model tier
  When it is asked to summarize a coverage result
  Then the answer's summary is the custom summarizer's output
  And the model tier received no call

Scenario: an unsuitable result falls through to the model tier
  Given the same routed summarizer
  When it is asked to summarize an unrelated result
  Then the model tier answered it

Scenario: a custom summarizer that raises falls through rather than losing the summary
  Given a catalog whose suitable summarizer raises on compact
  When the routed summarizer is asked
  Then the model tier answered it

Scenario: a custom summarizer returning blank is refused loudly
  Given a catalog whose suitable summarizer returns an empty string
  When the routed summarizer is asked
  Then Oracle::InvalidAnswer is raised

Scenario: the tool name reaches suitability
  Given a catalog whose summarizer is suitable only for results from one tool
  When results from that tool and another carry identical text
  Then only the first is answered by the custom summarizer

Scenario: a custom answer is not journalled as an oracle call
  Given a routed summarizer over a journalling model tier
  When a suitable result is answered by the custom summarizer
  Then no Telemetry::OracleAnswer is journalled
  And the routed summarizer reports no model and empty usage

Scenario: a fallen-through answer is journalled exactly once
  Given the same routed summarizer
  When an unsuitable result falls through to the model tier
  Then exactly one Telemetry::OracleAnswer is journalled

Scenario: the eager tier holds a custom summary under the source digest
  Given an Eager over a routed summarizer, inside a reactor
  When a suitable tool result is fired and the task is awaited
  Then #held for that source digest returns the custom summary
```
→ spec file: `spec/lain/oracle/routed_summarizer_spec.rb`

**Escalation triggers:**
- `Oracle::Definition#digest` folds `tier:` (`definition.rb:58`), so a routed tier answering under
  a **new** tier symbol changes the oracle address and every existing `Recorded` journal misses
  loudly (`Recorded::Unrecorded`). Decide the tier symbol deliberately and say why in a comment;
  if `spec/lain/oracle/recorded_spec.rb` starts failing, that is this trigger firing.
- `oracle/summarize_spec.rb` pins that `:model` and `:heuristic` address separately. If routing
  requires collapsing those addresses, stop.
- `Summarizing::Observer#observe` reads **String** wire keys (`block["content"]`,
  `block["is_error"]`, `summarizing.rb:63-67`) and is recorded as follow-up 8 in
  `chunk-live-wiring.md` for silently no-op'ing on a Symbol-keyed caller. This card changes that
  method's signature. Do not fix follow-up 8 here, but do not widen the silent no-op either: an
  observer that receives no tool name must fail loudly rather than treat it as "matches nothing".
- `ToolRunner#result_block` is on the parallel-dispatch path (`tool_runner.rb:189`), called inside
  the gathered fiber. If threading the name requires reshaping `#dispatch`'s return or the
  gather's arity, stop — `spec/lain/agent/tool_runner_spec.rb` pins both the overlap within a safe
  run and sequential-equivalence across a barrier, and neither may move for a summarizer.
- If a custom summarizer's output reaches `Context::Compact` as anything other than a String
  already frozen into a `SummarySnapshot`, stop — that is the boundary the Open decision draws.

### A4 — Let `/meta` author a custom summarizer for review          [wave 3] [risk: low]

**Depends on:** A2
**Files:** `lib/lain/cli/command/meta.rb` (modify — add the `summarizer` verb),
`spec/lain/cli/command/meta_spec.rb` (modify)
**Reuse:** `Command::Meta#generate`/`#compose`/`#header` (`cli/command/meta.rb:62-128`) — the
generate-then-review split, the GENERATED header, `#slugify` (`:138`), and the `SLUG` charset
guard (`:32`) are all reused verbatim. `Role::Catalog` (`role/catalog.rb:32`) is where the
read-only role is declared, mirroring `meta_harness`'s `only: %i[read_file list_files glob grep]`.
**Shared-file wiring:** `lib/lain/role/catalog.rb` — one entry declaring a read-only
`meta_summarizer` role, `only: %i[read_file list_files glob grep]`.

**Acceptance criteria:**

```gherkin
Scenario: /meta summarizer writes a reviewable class file and runs nothing
  Given a meta command over a stub role spawn returning a summarizer class body
  When "/meta summarizer collapse coverage reports" is dispatched
  Then a file is written under .lain/summarizers/ carrying the GENERATED review header
  And that file defines exactly one Summarizer::Base subclass
  And nothing is executed and no tmux window is opened

Scenario: the generated file names its origin prompt and head digest
  Given the same command
  When the file is written
  Then its header carries the origin prompt and the session's head digest

Scenario: an empty prompt returns usage
  Given the meta command
  When "/meta summarizer" is dispatched with no prompt
  Then the usage line is returned and no file is written
```
→ spec file: `spec/lain/cli/command/meta_spec.rb`

**Escalation triggers:**
- `/meta run <slug>` executes `.lain/meta/*.rb` in a tmux window. A generated **summarizer** must
  never become executable that way — it is loaded by A2's catalog after human review, not run as
  a script. If the two paths start sharing a directory or a run verb, stop.
- If adding a verb to `Meta#call` pushes the class past a `Metrics/*` limit, extract the verb as
  its own object rather than loosening the cop (CLAUDE.md).

### B1 — Record pinned turns on the Session          [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/session.rb` (modify), `lib/lain/session_record/replay.rb` (modify),
`lib/lain/cli/command/pin.rb` (create), `lib/lain/cli/command/unpin.rb` (create),
`spec/lain/session_pins_spec.rb` (create), `spec/lain/cli/command/pin_spec.rb` (create)
**Reuse:** `Session#record_read`/`#read?` (`session.rb:88,94`) is the pair to mirror — **not**
`#record_write`/`#written?`. Both look alike, but only the read-set is journalled and replayed:
`Session::Journaled#record_write` (`session.rb:334-337`) forwards *without* journalling and says
so in its own comment ("a replayed session rebuilds with an empty write-set… W4's ticket"), while
`SessionRecord::Replay#session` (`session_record/replay.rb:48-53`) rebuilds the read-set from a
`session_read` record. A pin that mirrors the write-set silently vanishes on `--resume`.
Mirror `record_read` end to end: the `Session::Journaled` write (`session.rb:296+`), the
`Session::Null` no-op (`:225+`), the record type, and the `Replay` branch.
`Command::Registry` + `Command::Env`
(`cli/command/registry.rb`, `cli/command/env.rb`) for the command shape — every command is
`call(args, env)` returning rendered text, never output. `Command::Rewind` (`cli/command/rewind.rb`)
already resolves `[N|digest]` arguments against the timeline; reuse its resolution, do not
re-derive it.
**Shared-file wiring:** `lib/lain/cli/command.rb` — two `require_relative` lines;
`lib/lain/cli/command/surface.rb` — two entries in the `builtins` list (`surface.rb:92-94`);
`lib/lain/telemetry.rb` — one `Telemetry` record for a pin, with its `Guards::` entry.

**Acceptance criteria:**

```gherkin
Scenario: a pinned digest is remembered and reported
  Given a session with nothing pinned
  When the digest of a turn is pinned
  Then the session reports that digest as pinned and lists it among its pinned digests

Scenario: unpinning removes it
  Given a session with one pinned digest
  When that digest is unpinned
  Then the session no longer reports it as pinned

Scenario: the Null session answers honestly rather than raising
  Given Session::Null
  When it is asked whether any digest is pinned
  Then it answers false and offers no pinned digests

Scenario: a pin is journalled with the digest it names
  Given a journalled session
  When a digest is pinned
  Then a pin record is journalled naming that digest

Scenario: pins survive a resume
  Given a recorded session in which one digest was pinned and another was pinned then unpinned
  When that session is replayed
  Then the rebuilt session reports the first digest as pinned and the second as not

Scenario: a replay of a session with no pins rebuilds with none
  Given a recorded session that never pinned anything
  When it is replayed
  Then the rebuilt session offers no pinned digests and nothing raises

Scenario: /pin with no argument pins the last assistant turn
  Given a repl env whose agent has a committed assistant turn
  When "/pin" is dispatched
  Then that turn's digest is pinned and the reply names it

Scenario: /pin with a digest prefix pins that turn
  Given a repl env with a recorded history
  When "/pin <prefix>" is dispatched
  Then the turn matching that prefix is pinned

Scenario: /pin with an unmatched prefix refuses loudly
  Given a repl env with a recorded history
  When "/pin deadbeef" is dispatched for a digest that does not exist
  Then the reply says so and nothing is pinned
```
→ spec file: `spec/lain/session_pins_spec.rb`, `spec/lain/cli/command/pin_spec.rb`

**Escalation triggers:**
- A pin must survive `--resume`, and that is **not free**: it needs a new journalled record type
  and a new branch in `SessionRecord::Replay` (`replay.rb:26-28` lists the three types replayed
  today). If making that work seems to require writing to `Event#meta` or adding an `Event` kind,
  stop — the Open decision rules pins onto `Session`.
- **Unpin must replay too.** A pin followed by an unpin has to rebuild as *not pinned*, so the
  record stream is an ordered log rather than a set of pin events. If the chosen record shape
  cannot express a retraction, stop before writing the `Replay` branch.
- `Session` is at 75 of 110 on `Metrics/ClassLength` (measured; see the Orchestrator contract), so
  there is real headroom. Extract a `Session::Pins` collaborator only if the cop actually trips —
  do not pre-extract on suspicion.
- Do **not** touch `Compaction::Head`, `Context::Compact`, or `Source` in this card. Making pins
  actually protect anything is B2, and the two cards must not both edit `compaction/`.

### B2 — Make `Head` and `Compact` honor pins together          [wave 2] [risk: high]

**Depends on:** B1
**Files:** `lib/lain/context/pinned_messages.rb` (create),
`lib/lain/compaction/head.rb` (modify), `lib/lain/compaction/source.rb` (modify),
`lib/lain/context/compact.rb` (modify — partition before the threshold gate),
`spec/lain/compaction/head_spec.rb` (modify), `spec/lain/compaction/source_spec.rb` (modify),
`spec/lain/context/pinned_messages_spec.rb` (create)
**Reuse:** `Context::ProtectedPatterns#protects?(text)` (`protected_patterns.rb:34`) is the duck
the new object satisfies — a String in, a Boolean out — so **the four consumers' signatures do not
change**.

**The design is deliberately asymmetric, and the first draft got this wrong.** A pin is recorded
as a **turn digest** (B1). A turn's content address is *not* the bytes of its projected message —
the projection is `{"role" => …, "content" => …}` (`head.rb:34`, `source.rb:204`) while the digest
also folds `meta` and `causal_parents`. So:

- **`Head` filters on the turn.** `Head.from_timeline` (`head.rb:33`) already iterates turns, and a
  turn answers `#digest`. Excluding pinned turns there is a set-membership test with **no hashing
  on the every-turn hot path** — which is what the original ruling's cost argument was protecting.
- **`Compact` filters on the text.** It only ever sees projections, so `Source` builds
  `Context::PinnedMessages` from the pinned turns' *projected dumps* and hands it in as the
  `protected_patterns:` duck. `Source` is the one object holding both the timeline and the session,
  so it is the only place that mapping can correctly be made.

`Compaction::Head.from_timeline` and `Source#projection` must be given the same pin set or they
disagree by construction — the exact failure `Head` was written to delete.
**Shared-file wiring:** `lib/lain/context.rb` — one require line for `pinned_messages`, placed
with the other combinator-adjacent requires **before** `Context::REQUIRES` evaluates.

**Acceptance criteria:**

```gherkin
Scenario: a pinned message survives a compaction verbatim
  Given a history long enough to compact with one middle turn pinned
  When the compacting pipeline renders
  Then the pinned turn appears verbatim in the output ahead of the summary message

Scenario: the candidate head excludes pinned messages
  Given the same history
  When the Head is built with the same pin policy
  Then its messages exclude the pinned turn and its bytesize counts only the rest

Scenario: Head and Compact agree on what is droppable
  Given any history, keep_last, and pin set
  When the Head's message list and the messages Compact actually removes are compared
  Then they are equal

Scenario: pinning everything droppable declines the compaction rather than emitting an empty summary
  Given a history whose every droppable message is pinned
  When the pipeline renders
  Then the render is byte-identical to the uncompacted one

Scenario: a pin-shrunk head that no longer saves bytes is journalled as not shrinking
  Given a history where a non-byte detector fired and pins leave nothing worth removing
  When the pipeline renders
  Then the decision is journalled as not shrinking

Scenario: Compact's own threshold measures the same set the Head measured
  Given a history with one pinned message and a threshold between the pinned and unpinned sizes
  When Compact runs
  Then its threshold decision is made on the unpinned bytes, matching the Head's bytesize

Scenario: no pins behaves exactly as today
  Given a history with no pins
  When the Head is built
  Then it names the whole candidate span as it does today
```
→ spec file: `spec/lain/compaction/head_spec.rb`, `spec/lain/context/pinned_messages_spec.rb`

**Escalation triggers:**
- **`spec/lain/compaction/head_spec.rb:132` is a deliberate characterization example** placed by
  `chunk-live-wiring.md`'s A5 to make exactly this change visible. It asserts the Head names the
  whole candidate span *including protected survivors*. Updating it is required and expected —
  but if you find yourself deleting it rather than replacing it with the agreement property
  above, stop.
- `source.rb:328` passes `ProtectedPatterns::NONE` with a comment calling it "the ruling of
  2026-07-25, not a default left unset". That comment must be rewritten to record the new
  ruling, not silently dropped.
- `Source#shrinks?` is strict (`source.rb:269`), pinned at the 366/367-byte crossover by
  `source_spec.rb:528-546`. If pins push a history to byte-neutral, the turn defers. That is
  correct, but if it makes an existing shrink-floor example fail, stop and confirm the crossover
  was not silently moved.
- **A digest is not a dump.** Pins are turn digests; `protects?` receives the canonical dump of a
  *projected message*. Deriving one from the other by hashing the wrong bytes produces a matcher
  that is well-formed and misses **every** lookup, silently and permanently — the same species of
  failure `SummarySnapshot`'s "ALWAYS BUILD ONE WITH `.take`" comment warns about
  (`summary_snapshot.rb:118-131`), where `#hits`/`#misses` report 0/0 indistinguishably from an
  empty run. If `PinnedMessages` ends up built anywhere other than `Source` — the one object
  holding both the timeline and the session — stop.
- `Head#bytesize` runs **every turn** while `Compact`'s partition runs only on compacting turns
  (the original ruling's cost argument). The design above keeps the hot path hash-free by
  filtering `Head` on turn digests. If the implementation instead adds a per-message
  `Canonical.dump` to `Head`, stop: a deferring turn already costs ~1.47 ms (live-wiring
  follow-up 16), and that is a budget question for the orchestrator, not a footnote.
- `Compact#call` thresholds on the **full** dropped set at `:53` and only partitions at `:56-58`.
  Left as-is, `Head` and `Compact` would gate on different byte counts. Moving the partition above
  the gate is in scope and listed under Files; if that reordering breaks
  `spec/lain/context/compact_spec.rb`'s "summarizer receives exactly `messages[0..-2]`" example,
  stop — that example encodes the old contract and its replacement needs confirming.

### B3 — Auto-pin a `/goal` objective          [wave 2] [risk: low]

**Depends on:** B1
**Files:** `lib/lain/cli/command/goal.rb` (modify), `lib/lain/cli/goal_driver.rb` (modify),
`spec/lain/cli/command/goal_spec.rb` (modify)
**Reuse:** B1's session pin seam; `Command::Goal#call`/`#confirm` (`cli/command/goal.rb:26-44`)
already reads driver state back before confirming, and `GoalDriver::Null` is the honest no-op —
auto-pinning must degrade the same way rather than raising in a session with no driver.
**Shared-file wiring:** none.

**Acceptance criteria:**

```gherkin
Scenario: setting a goal pins the objective
  Given a live goal driver and a session
  When "/goal ship the parser" is dispatched
  Then the turn carrying that objective is pinned

Scenario: clearing the goal leaves the pin in place
  Given a session with a goal set and its objective pinned
  When "/goal off" is dispatched
  Then the objective remains pinned

Scenario: a session with no live driver does not pin and says so
  Given GoalDriver::Null
  When "/goal ship the parser" is dispatched
  Then the existing unavailable message is returned and nothing is pinned
```
→ spec file: `spec/lain/cli/command/goal_spec.rb`

**Escalation triggers:**
- If the objective's turn digest is not knowable at the time `/goal` runs (the command dispatches
  before the model turn commits), stop and escalate — pinning the wrong digest is worse than not
  pinning, and the fix may be to pin at the driver's first re-prompt instead.

### B4 — Pin from the Neovim timeline buffer          [wave 2] [risk: low]

**Depends on:** B1
**Files:** `lib/lain/frontend/neovim/runtime.lua` (modify),
`lib/lain/frontend/neovim/buffers.rb` (modify), `spec/lain/frontend/neovim_spec.rb` (modify)
**Reuse:** the `lain://inbox` answer gesture is the exact precedent — `runtime.lua:589-600` binds
`r` and `<CR>` on an inbox item to prompt and submit via `:LainReply`. Mirror that with a
normal-mode binding on `lain://timeline` that pins the turn under the cursor.

**The line does not currently identify its turn.** `Buffers#turn_line` renders
`"#{turn.role}: #{preview(...)}"` (`buffers.rb:110-112`) — one flat line per turn, **no folds and
no digest**. So this card must also keep a line-number → digest index alongside the rendered
lines. The mapping is not reliably positional: the `Store::MissingObject` rescue
(`buffers.rb:105-107`) replaces the entire list with a single `[timeline unavailable: …]` line, in
which case there is nothing to pin.
**Shared-file wiring:** none.

**Acceptance criteria:**

```gherkin
Scenario: pinning from the timeline buffer pins that turn
  Given an attached Neovim frontend showing a timeline of three turns
  When the pin binding fires with the cursor on the second turn
  Then that turn's digest is pinned

Scenario: a pinned turn is marked in the timeline rendering
  Given a timeline with the second turn pinned
  When the timeline buffer re-renders
  Then the second turn's line carries a pin marker and the others do not

Scenario: every rendered turn line maps to its own digest
  Given a timeline of three turns
  When the timeline buffer renders
  Then each line's index resolves to that turn's digest

Scenario: an unavailable timeline offers nothing to pin
  Given a timeline whose store cannot resolve the chain
  When the pin binding fires
  Then nothing is pinned and the failure is reported
```
→ spec file: `spec/lain/frontend/neovim_spec.rb`

**Escalation triggers:**
- `plugin/nvim/` owns only the socket convention and `:LainStart`; **all buffer and RPC logic
  stays in the gem** (`plugin/nvim/README.md`). If this card starts adding buffer logic to the
  plugin directory, stop.
- The `:nvim`-tagged specs need `LAIN_NVIM=1` and a real `nvim` (`spec/support/tags.rb:78`). If
  the only way to pin this behavior is an opt-in-gated spec, say so — a card whose ACs cannot run
  in the default suite needs the orchestrator to know.

### C1 — Derive the compaction window from the live model each turn          [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/compaction/need.rb` (modify), `lib/lain/compaction/source.rb` (modify),
`lib/lain/cli/backend.rb` (modify `#compaction_source`),
`spec/lain/compaction/need_spec.rb` (modify), `spec/lain/compaction/source_spec.rb` (modify)
**Reuse:** `ContextWindow.default.window_tokens(model)` (`backend.rb:244`) is already the lookup,
and it deliberately degrades to a conservative fallback rather than raising for models no
Anthropic-shaped table carries. `Source#context_for(base:, ...)` (`source.rb:170`) receives the
live `base` Context every turn, and `Context#model` is its reader — that is where the live model
comes from. `Need#check` (`need.rb:114`) is the call site.
**Shared-file wiring:** none.

**Acceptance criteria:**

```gherkin
Scenario: the window follows a mid-session model switch
  Given a Source built while the model was one with a small window
  When a turn renders with a Context naming a model with a much larger window
  Then the approaching-window signal is evaluated against the larger window

Scenario: a small-window model still fires approaching-window
  Given a Source and a Context naming a small-window model
  When used tokens exceed that model's ratio threshold
  Then the approaching-window signal fires

Scenario: an unknown model falls back conservatively rather than raising
  Given a Context naming a model absent from the window table
  When a turn renders
  Then the conservative fallback window is used and nothing raises

Scenario: the byte threshold is unaffected by the model
  Given any model
  When droppable bytes exceed the threshold
  Then the token-threshold signal fires as it does today
```
→ spec file: `spec/lain/compaction/need_spec.rb`, `spec/lain/compaction/source_spec.rb`

**Escalation triggers:**
- `Need` is frozen at construction (`need.rb:105`) and `need_spec.rb` pins that it and **every
  detector** are `Ractor.shareable?`. If per-turn window derivation means `Need` stops being
  frozen or shareable, stop — the fix is to pass the window into `#check`, not to make `Need`
  mutable.
- `Need#check`'s `State` is a `Data.define` (`need.rb:24`); `need_spec.rb` notes that adding a
  signal means adding a `State` field. Threading a window through is a **parameter** change, not
  a new signal — if a fifth signal appears, that is scope creep.
- `backend_spec.rb:343-374` pins `Rebound` on a differing second `pipeline_source` call. If the
  window stops being a construction-time argument, confirm that spec still means something.

### C2 — Refuse to quote compaction costs across a model switch          [wave 3] [risk: medium]

**Depends on:** C1
**Files:** `lib/lain/compaction/scheduler.rb` (modify),
`spec/lain/compaction/journaling_spec.rb` (modify),
`spec/lain/compaction/scheduler_spec.rb` (modify)
**Reuse:** `Scheduler#accounting` (`scheduler.rb:167-197`) is where `cost_saved`/`cost_spent` are
computed, already zeroing `cost_spent` on `:cold` and on a nil model. `Telemetry::Compaction`
(`telemetry.rb:807`) already carries the `model` the figures were priced against — A8 put it
there precisely so a mismatch is *visible*; this card makes it *correct*.
`PriceBook`'s refusal to price an unlisted model (`price_book.rb:48-50`) is the doctrine to
follow: a figure that cannot be stood behind is not emitted.
**Shared-file wiring:** `lib/lain/telemetry.rb` — amend `Guards::Compaction` so the cost fields
may be absent, and keep `cache_state` and `trigger` required as they are today.

**Acceptance criteria:**

```gherkin
Scenario: a compaction priced against the model that ran quotes real figures
  Given a scheduler whose priced model matches the model in force
  When a forced-warm compaction runs
  Then cost_saved and cost_spent are non-zero and the record names that model

Scenario: a compaction whose priced model no longer matches quotes nothing
  Given a run started on one model and switched to another
  When a compaction runs
  Then the journalled cost figures are absent rather than fabricated
  And the record still names the model the compaction actually ran under

Scenario: the decision itself is unaffected by pricing
  Given any pricing outcome
  When the scheduler evaluates
  Then the compact-or-defer decision is byte-identical to the unpriced one
```
→ spec file: `spec/lain/compaction/journaling_spec.rb`

**Escalation triggers:**
- `Guards::Compaction` (`telemetry.rb:737`) requires a non-empty `trigger` and a `cache_state` in
  `%i[warm cold forced]`. If "absent figures" means changing the record's required fields, that
  is a guard change and every existing journalling example must be re-read before it lands.
- `journaling_spec.rb` pins cost pricing for forced / cold / nil-model. If the honest-cost rule
  makes the nil-model example ambiguous, stop — nil-model and switched-model are different
  states and must journal differently.

### D1 — Resolve an isolation backend from options          [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/cli/isolation_backend.rb` (create),
`spec/lain/cli/isolation_backend_spec.rb` (create)
**Reuse:** `CLI::Backend#provider_name` (`backend.rb:218-225`) is the established shape for a
validated name → object resolution with a loud `UnknownProvider` naming the valid set; copy that
shape for backends. `Isolation::Services.load(root:)` (`isolation/services.rb:28`) is its first
production caller. `Isolation::Journal` must wrap **exactly once, nearest the concrete backend**
(`isolation/journal.rb:30-31`). `Paths#runtime_dir` / `Paths#project_hash` (`paths.rb:151,164`)
for the worktree root policy.
**Shared-file wiring:** `lib/lain.rb` — one require line for the new CLI unit, with the other
`cli/` entries.

**Acceptance criteria:**

```gherkin
Scenario: the default is the shared-process backend
  Given no isolation option
  When a backend is resolved
  Then it is an Isolation::Null

Scenario: worktree resolves to a worktree backend under a per-project root
  Given the worktree option
  When a backend is resolved
  Then it is an Isolation::Worktree whose root is derived from the project, not the cwd

Scenario: declared services decorate the resolved backend
  Given a project declaring a postgres service and the worktree option
  When a backend is resolved
  Then the resolved backend provisions that service over a worktree lease

Scenario: no declared services adds no decorator
  Given a project with no .lain/services.rb and the worktree option
  When a backend is resolved
  Then the resolved backend is the worktree one with no service decorator

Scenario: journalling wraps exactly once
  Given any resolved backend with a journal
  When a lease is acquired and released
  Then exactly one acquired and one released record are journalled

Scenario: an unknown backend name is refused naming the valid set
  Given an unrecognized isolation option
  When a backend is resolved
  Then a Lain::Error is raised naming the valid backends
```
→ spec file: `spec/lain/cli/isolation_backend_spec.rb`

**Escalation triggers:**
- The decorators' docs claim they layer over `Worktree`, but **no spec stacks them** — every
  existing decorator spec passes `inner: Null.new`. This card is the first real stack. If
  `Compose#acquire` returning the inner `Lease` **object itself** when no compose service is
  declared (`compose.rb:205`) breaks the stack's release chain, stop and report it.
- `Isolation::Worktree` needs a real git repo; if the resolver is asked for a worktree backend
  outside one, it must refuse by name rather than producing a backend that fails at acquire time.
- Do not wire this into `Wiring` or the bench here — D2 and D3 own those, and three cards editing
  one file is the seam being wrong.

### D2 — Wire isolation into the chat fleet          [wave 2] [risk: medium]

**Depends on:** D1
**Files:** `lib/lain/cli/wiring.rb` (modify — one construction site),
`spec/lain/cli/wiring_spec.rb` (modify)
**Reuse:** `wiring.rb:88` — `@supervisor = Lain::Supervisor.new(journal: channel)` is **the** wire;
`Supervisor#initialize(journal:, isolation: Isolation::Null.new)` (`supervisor.rb:44`) already
accepts the keyword and everything downstream honors it unchanged. `--auto-approve`
(`wiring.rb:131`) is the established pattern for a flag read directly at its construction site.
**Shared-file wiring:** `exe/lain` — one `method_option :isolation` line on `chat`, string,
default `"none"`, whose help text states that it applies to **actor-mode subagents**.

**Acceptance criteria:**

```gherkin
Scenario: chat defaults to the shared process
  Given a chat wired with no isolation option
  When the supervisor is built
  Then it holds a Null isolation backend

Scenario: the selected backend reaches the supervisor
  Given a chat wired with the worktree isolation option
  When the supervisor is built
  Then it holds the resolved worktree backend

Scenario: an adopted actor runs under the leased working directory
  Given a supervisor holding a backend that leases a distinct cwd
  When an actor-mode subagent is adopted
  Then the child's session resolves paths against the leased cwd, not the chat's

Scenario: a bad isolation name refuses before the session opens
  Given a chat wired with an unrecognized isolation option
  When wiring runs
  Then a Lain::Error is raised and no journal file is orphaned
```
→ spec file: `spec/lain/cli/wiring_spec.rb`

**Escalation triggers:**
- **One-shot subagents and `@role/skill` lines never lease today** (`tools/subagent.rb:225-230`
  is `#perform`, routing to the one-shot body at `:254-265`;
  `skill/role_spawn.rb:53`). This card must not change that — making one-shots lease is a
  separate design question about lease lifetime for a call that returns a String. If a spec
  seems to require it, stop.
- `wiring.rb:76` builds the main chat `Session` with `WorkerEnv.default` — the **main agent is
  never leased**, by design (the user's own edits stay in the user's tree). If this card starts
  leasing the main agent, stop: that was ruled out in the interview.
- `CLI::Wiring` is at 108 of 110 on `Metrics/ClassLength` (measured 2026-07-25; see the
  Orchestrator contract). A one-line addition plus its comment may trip it. Extract a collaborator; do not loosen the cop.

### D3 — Wire isolation into the bench arm driver          [wave 2] [risk: low]

**Depends on:** D1
**Files:** `lib/lain/bench/cli.rb` (modify), `spec/lain/bench/cli_spec.rb` (modify)
**Reuse:** `Arm::Driver#initialize(arms, tasks:, spawn_seam:, grader:, isolation: NoIsolation)`
(`arm/driver.rb:39`) already accepts and threads the backend to every arm (`:66`). D1's resolver
produces it.
**Shared-file wiring:** `exe/lain` — one `method_option :isolation` line on the `bench` subcommand
that runs arms.

**Acceptance criteria:**

```gherkin
Scenario: the arm driver defaults to no isolation
  Given a bench arm run with no isolation option
  When the driver is built
  Then it holds Arm::NoIsolation

Scenario: the selected backend reaches every arm
  Given a bench arm run with the worktree isolation option
  When the driver runs two arms
  Then each arm acquired a lease from the resolved backend
```
→ spec file: `spec/lain/bench/cli_spec.rb`

**Escalation triggers:**
- `Arm::NoIsolation::Lease#worker_env` is **`nil`**, not a `WorkerEnv` (`arm.rb:28`), deliberately,
  so the Arm unit need not depend on the Isolation unit. If threading a real backend requires
  changing that, stop — a real backend's lease already carries a real `WorkerEnv`, and the two
  paths must stay distinguishable.

### D4 — Hand a worker's commits back to the parent checkout          [wave 2] [risk: high]

**Depends on:** D1
**Files:** `lib/lain/isolation/worktree/handback.rb` (create),
`spec/lain/isolation/worktree_handback_spec.rb` (create)
**Reuse:** `Worktree`'s own git invocation shape — `GIT_CONTEXT_SCRUB` (`worktree.rb:56-59`)
applied on every call exactly as `#git` does at `:163`, and `Refused` + `.from_git` (`:68-71`) as
the error shape. `Lease#worker_env.cwd` names the worktree to hand back from.

**This is an object the orchestrator calls, not a hook on release.** The first draft hooked
`Lease#release`, which was wrong: `Lease#release` marks released *before* running its action
(`lease.rb:48-49`), a raise there strands the path in `@leased`, and for chat actors release only
happens inside `Supervisor#stop`'s loop (`supervisor.rb:141-144`) with `@task.stop` on the next
line. Handback is instead a plain operation with no lifecycle opinions, invoked by whoever owns
the worker (D5). Releasing stays exactly as it is today.

**Ref-first, because reclaim destroys.** `worktree.rb:16-30` argues for detached HEAD and against
leaving a checkout on disk: a bare `add` leaks a branch that a re-acquire would check out,
*"bleeding a crashed worker's committed state into its successor"*, and *"the ONE thing release
must never do is leave the checkout on disk"* — `#reap` (`:155-160`) force-removes any leftover
before the next add. So:

1. Capture the worktree's `HEAD`; if it has not moved from the commit it was added at, there is
   nothing to hand back.
2. Write it to `refs/lain/worker/<worker_id>`. Outside `refs/heads/`, so it is **not a branch** and
   `worktree add --detach` cannot check it out — the leaked-branch failure does not recur — but the
   commits survive reclaim.
3. Merge into the parent checkout only if that checkout is clean.
4. On conflict: leave the merge in progress **or** abort, per `#outcome` below, and report. Never
   raise past the caller.

Uncommitted worker changes stay scratch, as the class doc says. This card makes *committed* work
survivable and reports what happened; it never spawns and never removes a worktree.

`Handback::Outcome` names one of: `nothing_to_do`, `merged`, `conflicted` (carrying the conflicted
paths and the ref), `declined` (parent dirty, carrying the ref).

**Shared-file wiring:** `lib/lain/telemetry.rb` — one record for the handback outcome, carrying the
worker key, the outcome, and the ref. Never a path outside the repo and never a `WorkerEnv`.

**Acceptance criteria:**

```gherkin
Scenario: a worker's commit is preserved as a ref
  Given a worktree with one commit on its detached head
  When handback runs
  Then that commit is reachable from a lain worker ref outside refs/heads

Scenario: a clean parent receives the merge
  Given a worktree with one commit and a clean parent checkout
  When handback runs
  Then the commit is reachable from the parent checkout's head
  And the outcome is merged

Scenario: a conflict is reported with its paths and its ref
  Given a worktree whose commit conflicts with the parent checkout
  When handback runs
  Then the outcome is conflicted, naming the conflicting paths and the ref
  And nothing is raised

Scenario: a dirty parent is never merged into
  Given a worktree with one commit and a parent checkout with uncommitted changes
  When handback runs
  Then no merge is attempted, the parent is untouched, and the outcome is declined

Scenario: an unmoved worktree hands nothing back
  Given a worktree with no new commits
  When handback runs
  Then no ref is written, no merge is attempted, and the outcome is nothing-to-do

Scenario: handback never removes the worktree
  Given any of the above
  When handback runs
  Then the worktree is still on disk and still registered with git

Scenario: a git failure is reported, not raised
  Given a worktree whose ref write fails
  When handback runs
  Then the failure is reported as an outcome and nothing propagates to the caller
```
→ spec file: `spec/lain/isolation/worktree_handback_spec.rb`

**Escalation triggers:**
- **Do not touch `Lease#release`, `Worktree#release_path`, or `#remove`.** Reclaim stays exactly as
  it is; `worktree_spec.rb:192,202,212` pin that release removes from disk and from git, forces a
  dirty tree, and is idempotent-loud, and all three must stay true. If handback seems to need a
  release hook, stop — that was the first draft's mistake.
- The ref namespace must not be under `refs/heads/`. If `git worktree add --detach` starts checking
  out a previous worker's tip, the namespace is wrong and the crash-restart isolation
  `worktree.rb:16-30` protects has been broken.
- **Never raise past the caller.** D5 invokes this from inside a gathered fiber and from an
  orchestrator's completion path; a raise there would take out the worker's own result.
- If a conflicted merge must be left in progress for D5 to resolve, say so explicitly in the
  outcome — a half-merged parent checkout that nobody is told about is worse than an abort.

### D5 — Spawn a resolver from the orchestrator when a handback conflicts          [wave 3] [risk: high]

**Depends on:** D4
**Files:** `lib/lain/isolation/worker_handoff.rb` (create),
`lib/lain/arm/orchestrator_worker.rb` (modify), `lib/lain/arm/single_thread.rb` (modify),
`lib/lain/arm/dual_ledger.rb` (modify), `lib/lain/arm/adaptive_router.rb` (modify),
`spec/lain/isolation/worker_handoff_spec.rb` (create),
`spec/lain/arm/orchestrator_worker_spec.rb` (modify)
**Reuse:** `Skill::RoleSpawn#call(role_name, context_mode, prompt)` (`skill/role_spawn.rb:53`) is
the spawn seam and takes a context mode — `:fresh` gives the child its own root, which is what
keeps the conflict transcript out of the orchestrator's context. `Arm#work`'s
`ensure lease&.release` (`arm/orchestrator_worker.rb:82-89`, and the same shape at
`single_thread.rb:50`, `dual_ledger.rb:59`, `adaptive_router.rb:76`) is **already** the
worker-completion point, mid-run, inside a live `Sync`/`Async` — handback and any resolver spawn
go there, immediately before the release.

**Why no command and no prompt is needed.** The four arms release per worker while the reactor is
live and the orchestrator is awaiting, so the orchestrator can hand back and, on conflict, spawn a
resolver in place. That is the whole flow: worker finishes → handback → conflicted → spawn
`merge_resolver` over a fresh root → it resolves → release.

**The resolver holds no tier-3 tool.** `Handback` (D4) owns every git invocation; the resolver only
**edits the conflicted files** in the parent checkout. So its attenuation is
`read_file`/`edit_file`/`write_file`/`grep` and **not `bash`**, which means it never hits the
approval gate (`tools/bash.rb:69` is where tier-3 gating lives; `Tool#requires_approval?` at
`tool.rb:115-125` is false by default). That is what makes an unattended spawn safe: no approval
surface is required, so nothing can hang waiting for a human.

**Shared-file wiring:** `lib/lain/role/catalog.rb` — one entry declaring the `merge_resolver` role
with the attenuation above.

**Acceptance criteria:**

```gherkin
Scenario: a clean handback spawns nothing
  Given a worker whose handback merges cleanly
  When the worker completes
  Then no resolver is spawned and the lease is released

Scenario: a conflicted handback spawns a resolver over a fresh root
  Given a worker whose handback conflicts
  When the worker completes
  Then a merge_resolver child is spawned over a fresh root
  And the orchestrator's own timeline gains only the resolver's result, not the conflict transcript

Scenario: the resolver is told which files conflict and which ref holds the work
  Given a conflicted handback naming two paths and a ref
  When the resolver is spawned
  Then its prompt names both paths and that ref

Scenario: the resolver holds no shell capability
  Given the merge_resolver role
  When its spawn policy is read
  Then it carries file-editing capabilities and does not carry bash

Scenario: a resolved conflict reports what it changed
  Given a resolver that settles the conflict
  When it finishes
  Then the worker's result names the files it resolved

Scenario: an unresolved conflict is reported, not swallowed
  Given a resolver that cannot settle the conflict
  When it finishes
  Then the worker's result says the conflict stands, naming the ref that still holds the work

Scenario: the lease is released whatever the resolver did
  Given a conflicted handback and a resolver that raises
  When the worker completes
  Then the lease is still released and the worktree is reclaimed
```
→ spec file: `spec/lain/isolation/worker_handoff_spec.rb`

**Escalation triggers:**
- **The release must still happen.** `work`'s `ensure lease&.release` is what reclaims the
  worktree; inserting handback and a spawn ahead of it must not let either escape the `ensure`.
  If a resolver raise can skip the release, the worktree leaks and `worktree.rb:16-30` calls that
  the failure that "silently defeats the next acquire".
- The resolver must **not** acquire an isolation lease of its own. `Worktree#acquire` refuses an
  already-leased path (`worktree.rb:100-111`) and that refusal is correct.
- **Chat-path actors are out of scope for this card.** A `Supervisor`-adopted actor holds its lease
  until `Supervisor#stop` (`supervisor.rb:141-144`), and `Actor#settle` (`subagent/actor.rb:93`)
  awaits only the *initial* turn, so it is not a completion signal. Wiring handback into the chat
  fleet needs a per-actor completion seam that does not exist yet — it is a recorded follow-up, not
  this card. If a spec seems to require it, stop.
- If the resolver needs a shell to finish the merge, stop rather than granting `bash`. That would
  reintroduce the approval gate on an unattended path, and it means the git/edit split between D4
  and this card is drawn in the wrong place.

## Outcome (2026-07-25)

All 15 cards landed on `main`, `79d27ee..2e828a6`, one commit each, leaf-first. Suite **4679
examples, 0 failures, 2 pending** (baseline 4328). Every card was panel-reviewed; **11 of 15 needed
a fix round**, and four needed two.

Integration checks: **1, 2, 3, 5, 6 green.** Check **4 (`LAIN_SERVICES=1`) is blocked on
infrastructure, not on this chunk** — `db_index_spec.rb:211` fails with
`connection to server on socket "/tmp/.s.PGSQL.5432" failed`, i.e. no running postgres. Verified
pre-existing: `git log ad72d5d..HEAD -- spec/lain/isolation/db_index_spec.rb lib/lain/isolation/db_index.rb`
is **empty**. D1 predicted this and its panel confirmed it independently. The `:services` guard
checks `command -v createdb` only, which is ticket 15.

**What review caught that a green suite could not** — the recurring shape was *a passing test
exercising a path the real system never takes*:

- A2: a top-level `return` in the user's DSL file silently emptied the catalog (`nil.freeze`
  *succeeds*), surfacing much later as `NoMethodError` naming lain's internals. Then the fix's own
  `COMPLETED = :completed` sentinel proved forgeable by `return :completed`; identity (`.equal?`)
  closed it, and a user-defined `#==` proved even `Object.new` insufficient by value comparison.
- B1: `/pin 3` pinned whatever digest began with `3` and **reported success** — 40/40 across 20
  timelines.
- B2: the card's own mandated mechanism was wrong. Filtering `Head` on turn digests over-reports
  the droppable span by **41%** against what `Compact` removes, because digests and projections
  are not in bijection on an ordinary timeline of repeated tool results.
- D1: a failed `Compose` acquire stranded a real git checkout — invisible until D1 became the first
  code to stack a decorator over a real `Worktree`. Its own partition fix was invisible too:
  reverting it left 4337 examples, 0 failures.
- A3: `NotImplementedError < ScriptError`, so `rescue StandardError` missed the most likely real
  failure (a half-written `.lain/summarizers.rb`); the spec used `raise("…")`, a `RuntimeError`.
- A4: the role template asks for a fenced code block and nothing stripped the fence, so **22 of 44**
  generated files were `SyntaxError`. The spec fixture was fence-free.
- D5: `Async::Cancel`/`Interrupt` are `< Exception`, so a sibling worker's cancellation stranded
  Joel's own checkout mid-merge — then the same defect one level down in `#restore`.
- Vacuous tests found by mutation: C1's required keyword, D3's AC1 (the arm re-declared the
  Driver's default), D5's fixture lease (not idempotent, hiding a double-release), B3's two
  load-bearing orderings, A4's fence-free fixture, D5's `RecordingResolver` (absolute paths where
  production emits relative).

**`rescue StandardError` was narrower than the invariant it guarded three separate times**
(A3, D5 round 1, D5 round 2). Worth a repo-level note, not three tickets.

**Class-length ledger, measured on `main` after the chunk:** `Handback` **110/110** (at the limit —
the next change extracts first), `CLI::Backend` 108, `CLI::Wiring` 109, `Command::Meta` 108,
`Compaction::Source` 101, `Session` 95. Five classes now sit within two lines of the cap.

## Closeout (2026-07-26)

**The `exe/lain` flag lines never landed.** Every card's "Shared-file wiring" was handed back as a
diff for the orchestrator to apply (per the contract at line 196), and the four `method_option`
lines A1 and D2 owned — `--isolation`, `--summarizer-provider`, `--summarizer-model`,
`--summarizer-max-tokens` — were not among the ones re-applied. Consequence: `Wiring#fleet_isolation`
read `options[:isolation]` and `Backend` read `knob(:summarizer_provider, …)` against a hash where
those keys could never appear, so **deliverables (A) and (C) were unreachable from the command
line** and manual passes 1 and 2 could not run either — a wider gap than Deviations 8 and 9, which
had already deferred passes 5, 6, and 7.

It was silent in both directions, which is why 4679 green examples said nothing. Thor never calls
`check_unknown_options!`, so `lain chat --isolation worktree` was not refused — it ran the whole
session on `Isolation::Null`. And every reader falls through to a default (`knob`, `||`, `fetch`), so
an absent flag is indistinguishable from an operator not passing one. Each card's own specs built
`Backend` and `Wiring` from plain option hashes, which is exactly the shape that cannot see this.

**The guard is on the source, not on a list.** `spec/lain/cli/chat_flags_spec.rb` parses every file
under `lib/lain/cli/` with Prism, collects the option keys actually read (`options[:x]`,
`@options.fetch(:x, …)`, `knob(:x, …)`), and fails naming the file and line when one is declared by
no `LainCLI` command. A hand-maintained manifest of expected flags would be the same class of
artifact that just drifted. Reads whose key is not a literal are a hole in the guard, so the one
that exists (`%i[temperature seed]`, read by key) is pinned with its reason and a new one fails.
Mutation-checked: deleting the four declarations fails 11 of 17 examples.

`LainCLI` crossed `Metrics/ClassLength` (119/110) once the flags were added, so the compaction band —
the four `--compact*` knobs plus the three summarizer flags, seven flags that only make sense read
together — extracted to a nested `CompactionFlags` module. Nested rather than top-level because
`Style/OneClassPerFile` forbids a second top-level constant, and nesting is free: measured,
`Metrics/ClassLength` does not count a nested module's body. It stays in the exe because lib does not
depend on Thor, and a lib object calling `method_option` would make it.

**Docs.** The chunk shipped 21 lines of `docs/commands.md` (`/pin`, `/unpin`, `/meta summarizer`) and
never touched the README, which by then contradicted the code in four places: the summarizer "always
goes to a local Ollama model, never to the chat's provider" (A1), "two tiers" (A2/A3 made three), the
`PriceBook` paragraph describing zeros where C2 now emits absent figures, and `.lain/services.rb`
described as reachable by no CLI flag (D1). Now corrected, along with the flag rows, an isolation
section stating its real reach (Deviations 8 and 9, and ticket 6's missing handback), the
one-concurrent-isolated-run precondition (ticket 9), and the `.lain/summarizers.rb` /
`.lain/summarizers/` entries. Suite **4696 examples, 0 failures, 2 pending**.

**Still owed:** manual passes 1, 2, 3, and 4 (now runnable), and passes 5, 6, and 7 remain deferred
behind tickets 7, 13, and 6.

## Integration checks

After the last wave:

1. `bundle exec rake` (compile, full suite, rubocop) green.
2. `cargo test && cargo clippy --all-targets -- -D warnings` green.
3. `pre-commit run --all-files` green.
4. `bundle exec rspec --tag services` with `LAIN_SERVICES=1`, docker and postgres available —
   the D1 stack is the first code to layer a decorator over `Worktree`, and the existing
   `:services` examples only ever used `inner: Null.new`.
5. Confirm `spec/lain/compaction/head_spec.rb` no longer contains the old characterization
   example's assertion, and that the Head/Compact agreement property replaced it.
6. Grep the journal of a real run for a credential: the isolation decorators inject service URLs
   into the leased `WorkerEnv`, and B1's pin records and D4's conflict records are new journal
   writers. Neither may carry a URL or a worker env.

**Manual passes owed to Joel** (named so they do not silently drop):

1. A long chat with `--summarizer-provider anthropic --summarizer-model` a Haiku-class id:
   confirm summaries land, confirm `Telemetry::OracleAnswer` records carry real usage, and read
   the total off `lain bench variance` or the Ledger.
2. A `.lain/summarizers.rb` declaring a real transform against a real repeating tool result in
   your own workflow (a coverage report or a build log), confirming the model tier is not called
   for it.
3. `/pin` a turn, cross the compaction threshold, and confirm the pinned turn is still verbatim
   in `lain://request` after the compacting turn.
4. `/goal` something, cross the threshold, confirm the objective survived.
5. **DEFERRED with Deviation 8 — not runnable this chunk.** `lain bench` with `--isolation worktree` over an arm that fans out, with one worker committing:
   confirm the commit reaches your checkout, a `refs/lain/worker/*` ref exists, and no worktree
   leaks. This is the path the chunk actually wires end to end.
6. **DEFERRED with Deviation 8 — rides on pass 5's path.** The same with a deliberate conflict in a worker's commit, confirming the resolver spawns
   unattended (no approval prompt), resolves the files, and that the orchestrator's own context
   does not fill with the conflict transcript.
7. `lain chat --isolation worktree`, spawn an actor subagent that commits, exit cleanly: confirm
   the worktree is reclaimed and no worktree leaks. **Handback does not run on this path** (see
   follow-up 6) — the point of the pass is that isolation itself is sound in chat.

## Follow-up tickets designed here, deliberately not built

1. **The `name:verb` modifier grammar.** `Skill::Invocation` (`skill/invocation.rb:66-76`) parses
   `/skill`, `@role[/skill]`, `@role/skill`. A `name:verb` namespace would let one message both
   do a thing and pin it (`/goal:pin ship the parser`). Deferred because every command would then
   have to understand the namespace, and the parser is shared with skill dispatch — it wants its
   own card and its own review.
2. **The span summarizer.** Collapsing a back-and-forth *span* of conversational turns, run in an
   agent's own context where the span is already the last thing read and therefore cheap. Distinct
   from the eager tier: the eager key is a tool result's **source digest**, immutable and never
   stale, whereas a span's boundaries move every turn, so its cache key, its invalidation, and its
   interaction with pins (a pinned turn inside a collapsed span) are all unsolved. Note that
   `Compact` already re-emits protected survivors **ahead of** the summary message
   (`context/compact.rb:56-62`), which is the shape a span summarizer would have to respect.
3. **Per-child compaction sources.** Inherited from `chunk-live-wiring.md` follow-up 1 and
   untouched here: subagents still get `PipelineSource::Null`, and a research subagent grinding
   tool results remains the most likely thing to blow a window. A2/A3's custom tiers make this
   worse, not better, because a child now has cheap summarization available and no source to use it.
4. **`Eager#fire` consumes the digest before spawning** (`chunk-live-wiring.md` follow-up 7,
   `eager.rb:65-72`). A reaped fire permanently spends the digest, so identical content re-read
   later in the session can never be summarized. A3 routes more traffic through `#fire`, which
   raises the odds of hitting it.
5. **`Need` taking a `Compaction::Head`** (`chunk-live-wiring.md` follow-up 5). C1 threads a
   window through `#check`; the redundant `Canonical.dump` passes remain, and B2 may add one more
   on the hot path.
7. **A `lain bench arms` subcommand** (Deviation 8, Joel's ruling 2026-07-25). `Arm::Driver` has no
   production caller; `Bench::CLI#arm_report` (D3) is now the seam waiting for one. The card owns
   arm selection, the task file, grader wiring, and the `exe/lain --isolation` option D3 could not
   attach. Until it lands, `--isolation` on the bench is spec-reachable only, and manual passes 5
   and 6 cannot run. Note `Bench::ArmSweep` is *not* the home: it runs arms with per-task graders
   rather than the Driver's single-grader suite.
8. **Move the `DbIndex`/`Compose` service partition into the decorators** (D1 review). `DbIndex`
   provisions every declaration handed to it while `Compose` greps its own, so the resolver
   currently partitions by `respond_to?(:provision)` — two seams for one question, with the
   resolver owning knowledge that belongs to the decorators. Landed with a spec that fails when the
   partition is reverted, so the ticket cannot rot silently.
9. **A per-run discriminator, or an accepted constraint, for concurrent isolated runs** (D1 review).
   The worktree root is repo-keyed, so two concurrent `lain chat --isolation worktree` in one repo
   reap each other's *live* checkouts (worker ids restart at 1 per process). Documented as a
   precondition rather than fixed, deliberately: a per-run root would leak a *crashed* run's
   leftovers forever, since reap-before-add is what clears them today. Which failure is worse is the
   card's question.
10. **`Session#record_read(nil)` silently records the cwd.** `normalize` routes through
   `File.expand_path`, and `File.expand_path("")` returns `Dir.pwd`, so `record_read(nil)` records
   the project root and `read?(nil)` then answers `true`. Verified live on `main`. Pre-existing, on
   the edit-before-read **safety** contract — a session can believe it read a file it never touched.
   B1's pin writers guard against this shape; the read-set does not.
11. **`Builder#method_missing` blames the user's file for lain's own typos** (A2 review). A mistyped
   *internal* helper on `Summarizer::Builder` surfaces as `Unknown: unknown verb :… in
   .lain/summarizers.rb`. `Isolation::Services::Builder` has the identical exposure. The honest fix
   is structural — eval into a thin facade forwarding only `VERBS` — and must land in both builders
   at once or they diverge.
12. **Deep-freeze user summarizer instances** (A2 review). The Builder's freeze is shallow: it stops
   `@memo ||=` but not `@seen << x` on an array a user's own `initialize` assigned. Acceptance test
   already exists and is exact: `Ractor.shareable?(summarizer)` is **false** for a leaky instance and
   **true** for a clean one, while `frozen?` is true for both — which is why `frozen?` is the wrong
   bar. `base.rb` and `builder.rb` now say so honestly rather than over-claiming.
6. **A per-actor completion seam for the chat fleet.** D4/D5 give the *arms* handback at worker
   completion, because all four release per worker mid-run inside a live reactor
   (`arm/orchestrator_worker.rb:88` and siblings). A `Supervisor`-adopted chat actor has no
   equivalent: its lease is held until `Supervisor#stop` (`supervisor.rb:141-144`), and
   `Actor#settle` (`subagent/actor.rb:93`) awaits only the *initial* turn, while `dead?` (`:125`)
   is the terminal predicate. So `lain chat --isolation worktree` isolates workers but never hands
   their commits back. Closing it means either releasing the lease when an actor goes `dead?`, or
   an explicit orchestrator-side "this worker is done" step — a real design question about lease
   lifetime for a long-lived actor, which is why it is a ticket and not a card here.
