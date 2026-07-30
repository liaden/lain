# Orchestration arms & the worker isolation backend

status: done (landed 2026-07-19, 13/13 cards, commits c76fbb9..b03c312; integration checks green — full suite 3279 examples/0 failures, cargo test+clippy clean, pre-commit --all-files clean)

## Close-out (2026-07-19)

**Manual passes owed (human):** the plan's dogfood pass — Worktree backend + `bench arm-sweep`
live over B0's suite; DbIndex end-to-end with a throwaway pg+redis (`LAIN_SERVICES=1`); confirm no
worktree/DB/compose stack leaks after a full run and after a supervised kill+restart — and the
credential-safety Journal grep.

**Follow-up tickets accumulated from panel rounds:**
- `Telemetry::OracleAnswer` needs a child correlator before a true multi-child routed fan-out (B10).
- `Subagent#fan_out` returns text only (no head digests), so OrchestratorWorker bypasses it and B9's
  stagger goes unexercised by the arm; fan-out children are cache-cold by construction (fresh-root vs
  sibling-template tension) — one cache-economics ticket (B8/B9).
- `Ledger` causal-edge walk could replace labeled re-attribution (design note on `Arm::Run`, B7/B8).
- Real-concurrency Store commit race unexercised under `Provider::Mock` (B8).
- Crashed-worker worktrees persist until supervisor `#stop` (new worker_id per restart defeats
  same-id reap) — periodic reap sweep (B5).
- DualLedger default stall heuristic blind spot: ever-changing non-answers never stall — smarter
  injected detector (B11).
- DbIndex: an inner-release raise masks the aggregated service error (message-loss only, B3).
- Stagger still hangs if sibling 1 stalls AFTER stream-start (pre-existing documented gap);
  `bin/demo-fanout` not yet rewired to `Subagent#fan_out` (B9).
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman · Aaron Patterson (Ruby roster, `create-plan/references/rosters.md`)

## Intent

Two coupled deliverables that together let the bench *compare orchestration strategies on real
multi-service projects*. **(A)** An **Arm** seam — orchestration topology as a swappable, bench-scored
strategy object (single-thread control, orchestrator-worker+synthesis, dual-ledger, adaptive-router)
— which does not exist today (only per-*child* `SpawnPolicy` does). **(B)** A **worker isolation
backend** — each parallel worker gets an isolated environment (git worktree for code + isolated
stateful services: Postgres via `createdb`, Redis via DB-index, or a docker-compose stack per worker)
injected via environment variables, with a **lease** re-acquired on supervisor restart. Satisfies
ROADMAP's orchestration axis (`orchestration-experiments.md`, "build the comparison before the
fleet") and the isolation-as-swappable-backend fold-in (ROADMAP:391, `hn-agent-landscape-2026-07.md`
#6). This chunk has **no prior spec** — the design is decided here in Grounding and encoded in the
cards.

## Grounding

Verified against code on **2026-07-18** by parallel `Explore` passes. Code is source of truth.
Design decisions and the seams they rest on:

- **No orchestration-topology abstraction exists.** `SpawnPolicy = Data.define(:prefix, :posture,
  :only)` (`tool/spawn_policy.rb:30`) answers "what is *this one child*" (cache-prefix + attenuation
  axes) — not "single-thread vs fan-out-and-synthesize". The agent loop (`agent.rb:101`, `#ask` →
  `Sync { run_loop }`) drives one linear Timeline. **Decision:** an `Arm` is a new object
  `Arm#run(task, spawn_seam:, isolation:, grader:) → Run` composing existing primitives, scored by
  `Compare::Run.from_timeline` (`compare.rb:31`). The **single-thread control arm wraps `Agent#ask`**;
  richer arms compose `Subagent`/`ChildBuilder` (`tools/subagent.rb:302`), `Skill::RoleSpawn`,
  `Supervisor`, `Stagger`. Arms take an **injected isolation backend** (default Null) so the arm
  theme and isolation theme decouple.
- **No fan-out/fan-in synthesis pass exists.** The substrate does: `Event` carries multi-parent
  `causal_parents` (`event.rb:37`, "a synthesis event names the N results it folded") and
  `Timeline#meet` handles criss-cross fan-in (`timeline.rb:145`) — but nothing writes a synthesis
  event. The orchestrator-worker arm (B8) writes the first one.
- **Cache-sibling fan-out is un-wired.** `PrefixStrategy::SiblingTemplate` (`spawn_policy.rb:107`),
  `Provider::StreamStartedSignal` (`provider/stream_started_signal.rb`), and `Subagent::Stagger`
  (`subagent/stagger.rb:50`) all exist, but `on_stream_started` is **not plumbed through
  `Agent`/`Subagent`** (grep-confirmed: it appears only in `stagger.rb` + the provider signal), and
  `Stagger` is referenced only in `bin/demo-fanout`. B9 does the one-time plumbing; `stagger.rb:22`
  names this as its own pending wiring.
- **The Agent IS a state machine.** `Agent include LoopMachine` (`agent.rb:31`); `LoopMachine`
  (`agent/loop_machine.rb`) has states/events + a `before_transition` announce hook
  (`announce_transition`). The dual-ledger arm's stall→replan is a new state+event on this machine
  (`orchestration-experiments.md:55`).
- **Workspace holds only free-form reminder strings** (`workspace.rb:51`), rendered sent-not-stored at
  the request tail via `#with`/`#to_blocks`. **Decision:** the dual-ledger Task/Progress ledger is a
  structured value carried through the same `#with` mechanics — Workspace's render path already does
  what's needed; only the ledger structure is new. (`Lain::Ledger` is the *cost* ledger — unrelated.)
- **Supervision/restart exist.** `Supervisor` (`supervisor.rb`) is a reactor above the Agent with an
  adoption registry; `Supervisor::Restart#call` (`supervisor/restart.rb:93`) replays events to a
  checkpoint + restores workspace blobs + re-adopts — **no LLM calls**. **There is no resource-lease
  concept** — `Registration` holds only `role` + `actor`. B5 hooks lease acquire/release/re-acquire
  here.
- **Isolation plumbing is almost entirely absent.** `Bash#build_shell_out` (`bash.rb:78`) passes only
  `cwd:` (model-supplied) + `timeout` + live sinks — **never `environment:`** — so children inherit
  Lain's full ENV. File tools (`read_file`/`write_file`/`edit_file`) use raw `File.read/write` against
  the process CWD (`read_file.rb:36` etc.); `glob`/`grep` take a model-supplied base `path`. **No
  worktree, docker, postgres, redis, `DATABASE_URL`/`REDIS_URL` code exists anywhere** in `lib/`,
  `exe/`, `bin/` (grep-confirmed — only planning prose). **Decision:** introduce a `WorkerEnv`
  (`{cwd, env}`) carried on the **Session/context** (not by widening the `Tool::Invocation` Data
  shape); tools read cwd+env from the context they already receive (`Invocation.context` is the
  Session, `invocation.rb:16`). Default `WorkerEnv` = process `ENV` + `Dir.pwd` → **byte-identical
  current behavior**. The one env-injection seam that exists — `Paths#initialize(env:)`
  (`paths.rb:39`) with `project_hash` (`paths.rb:56`) as a ready per-worker key — is reused; the
  `Bash#shell_out_factory` and `Workspace::Snapshot(root:)` (`snapshot.rb:86`) hooks are reused.
  Env-var injection keeps secrets host-side and digests credential-free (fits "Workspace is sent,
  not stored").
- **Concurrency is fibers via `Async`** (`docs/concurrency.md`); structured cancellation is
  `Async::Task#stop` / `Budget#interrupt` (`agent/budget.rb:55`). Worktree-parallel workers get real
  wall-clock parallelism; service collisions (ports/DBs) are what the isolation strategies prevent.
- **Cross-plan dependency:** the adaptive-router arm (B10, OR-5) needs the **oracle seam** built in
  `chunk-bench-science.md` (T2/T3). This plan executes *after* that one, so the seam exists; B10 is
  the only card with a cross-plan edge.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only):
  - `lib/lain.rb` — manifest lines for new units (`worker_env`, `isolation`, `arm`).
  - `lib/lain/isolation.rb`, `lib/lain/arm.rb` — unit indexes **created by their first card** (B2, B7)
    in the same commit as the unit (the standard lain new-file+index rule), so B2/B7 list them under
    **Files**; **subsequent** same-unit index-line additions (B3/B4/B5/B6; B8/B10/B11) are orchestrator
    wiring and are not card **Files**. `lib/lain/oracle.rb` already exists (from the bench-science
    chunk); B10's `oracle/router` index line is orchestrator wiring.
  - `exe/lain` — one-line wiring diffs only: construct the default `WorkerEnv`, thread it into the
    session, mount an isolation backend when configured. Never card scope.
  - `lib/lain/telemetry.rb` — the isolation lease/allocation Journal record (B6) — sole telemetry
    edit in this plan.
  - `lain.gemspec`, `.rubocop.yml`, `spec/spec_helper.rb`, `CLAUDE.md` — untouched expected.
- Deviations from the default process:
  - **`exe/lain` control-flow exception:** B9 threads `on_stream_started` through the real
    `Agent`/`Subagent` dispatch — it may touch `agent.rb`/`subagent.rb` substantively (not one-line
    wiring), and it is the **only** card doing so, so there is no collision. It lists those files
    under **Files** deliberately.
  - **External-service cards (B3, B4) are `:integration`-tagged** — they shell to `createdb`/`redis`/
    `docker compose`, excluded from the default suite, run only in an environment that provides them.

## Open decisions

- **Service-declaration format — DECIDED 2026-07-19 (human):** a Ruby DSL, `.lain/services.rb`,
  modeled on the existing middleware-registration idiom (user-registered code is already a Lain
  concept). Rationale: the DSL also gives users a seam to write their own isolation logic. Design
  constraints: treat the DSL surface as deliberate, stable-ish API guarantees (no consumers yet, so
  iteration is fine); declarations evaluate to deeply-frozen value objects (functional core), with
  side effects confined to lease time (imperative shell). Security stance is Rails-like — a
  framework serving its user, not defending against them; the Tool::Input "shape, not safety" note
  applies in spirit.
- **Compose project-name / port-publish convention — DECIDED 2026-07-19 (human):** discovery via the
  compose `port` subcommand, namespaced `-p lain_<project_hash>`. Dogfood it through the DSL: a
  declared service should express its own port-discovery (defaulting to `docker compose port`), so
  B4's mechanism is a DSL-provided API rather than a hard-coded special case. If the DSL cannot
  support this cleanly, fall back to a static `.lain/services.yml` — escalate before falling back.
- Do **not** start B10 until `chunk-bench-science.md`'s oracle seam (T2/T3) has landed on `main`.

## Waves

```
Wave 1 (no deps): B0, B1, B7, B9
Wave 2: B2 (←B1), B8 (←B7,B9), B10 (←B7, +cross-plan oracle seam), B11 (←B7)
Wave 3: B3 (←B2), B4 (←B2), B5 (←B1,B2), B6 (←B2), B12 (←B8,B11)
Critical path: B7 → B8 → B12   (arms)   ‖   B1 → B2 → B5   (isolation)
```

## Tasks

### B0 — Coding-task fixture suite for arm comparison               [wave 1] [risk: medium] ✅ landed c76fbb9 (panel: APPROVE-WITH-FIXES, 4 fixes applied)

**Depends on:** none
**Files:** `spec/fixtures/arms/*` (task inputs + gold), `lib/lain/bench/arm_tasks.rb`, `spec/lain/bench/arm_tasks_spec.rb`
**Reuse:** `Grader::Fixture` (deterministic pass/fail), the existing bench fixture conventions (`spec/fixtures/bench/*`).
**Shared-file wiring:** none.

A small suite of graded coding tasks spanning the pre-registered boundary: procedural/single-thread-
friendly tasks and genuinely-independent-parallel tasks (`orchestration-experiments.md:72`). Feeds B12.

**Acceptance criteria:**

```gherkin
Scenario: Each fixture task grades deterministically
  Given an arm-comparison fixture task and a recorded trajectory
  When Grader::Fixture scores it
  Then it returns a deterministic pass/fail with a populated why
```
→ spec file: `spec/lain/bench/arm_tasks_spec.rb`

**Escalation triggers:**
- A task's grader needs the live API to judge — keep the floor deterministic (`Grader::Fixture`); if
  a task only scores via `Rubric`, mark it `:live` and confirm it isn't on the default path.

### B1 — WorkerEnv on the session/context + tool consumption         [wave 1] [risk: high] ✅ landed bea984b (panel: APPROVE-WITH-FIXES → re-review APPROVE; env is override-not-confinement, per-key nil-scrub spec'd, grep label byte-identical restored)

**Depends on:** none
**Files:** `lib/lain/worker_env.rb`, `lib/lain/session.rb`, `lib/lain/tools/bash.rb`, `lib/lain/tools/read_file.rb`, `lib/lain/tools/write_file.rb`, `lib/lain/tools/edit_file.rb`, `lib/lain/tools/glob.rb`, `lib/lain/tools/grep.rb`, `spec/lain/worker_env_spec.rb`, `spec/lain/tools/bash_spec.rb`, `spec/lain/tools/read_file_spec.rb`
**Reuse:** `Bash#shell_out_factory` + `build_shell_out` (`bash.rb:78`), `Invocation.context` (the Session, `invocation.rb:16`), `Paths#initialize(env:)` (`paths.rb:39`), `session_of(invocation)` (already used by tools).
**Shared-file wiring:** orchestrator adds the `worker_env` manifest line to `lib/lain.rb` and constructs a default `WorkerEnv` in `exe/lain`, threading it into the session (one line).

`WorkerEnv = { cwd, env }` (deeply frozen, `Ractor.shareable?`). Carried on the Session; tools read it
from the context they already receive: `Bash` passes `environment:` to ShellOut and resolves `cwd`;
file tools resolve relative paths against `worker_env.cwd`. **Default `WorkerEnv` = process `ENV` +
`Dir.pwd`, so current behavior is byte-identical** — a run with no isolation is unchanged.

**Acceptance criteria:**

```gherkin
Scenario: The default WorkerEnv preserves current behavior
  Given a session with the default WorkerEnv
  When bash and read_file run
  Then bash inherits the process env and cwd, and read_file resolves against Dir.pwd, exactly as today

Scenario: An injected WorkerEnv isolates env and cwd
  Given a session whose WorkerEnv carries a custom cwd and DATABASE_URL
  When bash runs a command and read_file reads a relative path
  Then the command sees the custom env and cwd and the read resolves under that cwd
```
→ spec files: `spec/lain/worker_env_spec.rb`, `spec/lain/tools/{bash,read_file}_spec.rb`

**Escalation triggers:**
- An existing tool spec pins `File.read(path)` against the process CWD or asserts ShellOut receives no
  `environment:` — the default WorkerEnv must make those byte-identical; if a spec asserts the
  *absence* of an `environment:` key, update it deliberately, don't silently change the contract.
- Threading WorkerEnv widens `Tool::Invocation`'s Data shape — DON'T; carry it on the Session/context
  per the decision, or STOP if the Session can't reach a tool that needs it.

### B7 — The Arm strategy seam + single-thread control + driver      [wave 1] [risk: high] ✅ landed e356720 (panel: APPROVE-WITH-FIXES; Run reachability contract pinned, spawn_seam widened to `call(journal:, **spawn_opts)`)

**Depends on:** none
**Files:** `lib/lain/arm.rb`, `lib/lain/arm/single_thread.rb`, `lib/lain/arm/driver.rb`, `spec/lain/arm_spec.rb`, `spec/lain/arm/single_thread_spec.rb`, `spec/lain/arm/driver_spec.rb`
**Reuse:** `Agent#ask` (the control arm), `Compare::Run.from_timeline` (`compare.rb:31`), `Bench::Sweep` report shape, an injected isolation backend (default a Null that returns the process WorkerEnv).
**Shared-file wiring:** orchestrator adds the `arm` manifest line to `lib/lain.rb`.

`Arm#run(task, spawn_seam:, isolation:, grader:) → Run` where `Run` is a graded Timeline. `SingleThread`
wraps `Agent#ask` on one linear Timeline (the control every other arm must beat). `Arm::Driver` runs N
arms over a task suite and reports distributions via `Compare`.

**Acceptance criteria:**

```gherkin
Scenario: The single-thread control arm produces a graded run
  Given a task and a grader
  When the SingleThread arm runs it
  Then it returns a Run whose Timeline is scored by Compare::Run.from_timeline

Scenario: The driver reports arms distributionally
  Given two arms over a task suite of n>=2 runs
  When the driver runs them
  Then it reports grader, tokens, and wall-time distributions per arm
```
→ spec files: `spec/lain/arm_spec.rb`, `spec/lain/arm/{single_thread,driver}_spec.rb`

**Escalation triggers:**
- The `Arm` interface starts leaking a specific topology's needs (a synthesis hook, a ledger) into the
  base — keep the seam minimal (`#run → Run`); topology specifics belong in the concrete arm, or the
  seam is at the wrong altitude (`SpawnPolicy`'s mistake to avoid).

### B9 — Cache-sibling fan-out wiring (plumb on_stream_started)      [wave 1] [risk: medium] ✅ landed bd33f6a (panel: APPROVE-WITH-FIXES; Mock observer isolation via StreamStartedSignal)

**Depends on:** none
**Files:** `lib/lain/agent.rb`, `lib/lain/tools/subagent.rb`, `lib/lain/tools/subagent/stagger.rb`, `spec/lain/tools/subagent/stagger_spec.rb`, `spec/lain/tools/subagent_spec.rb`
*(paths corrected 2026-07-19: Stagger lives under `tools/subagent/`, namespace `Lain::Tools::Subagent::Stagger`; `stagger_spec.rb` and `stagger_driver_spec.rb` already exist there)*
**Reuse:** `Provider::StreamStartedSignal` (`provider/stream_started_signal.rb`), `Subagent::Stagger` (`stagger.rb:50`), `PrefixStrategy::SiblingTemplate` (`spawn_policy.rb:107`). This closes `stagger.rb:22`'s named pending wiring.
**Shared-file wiring:** none (this card owns the `agent.rb`/`subagent.rb` dispatch touch — the sole substantive edit there, see Orchestrator contract).

Plumb an `on_stream_started` observer from a real subagent fan-out through the provider signal into
`Stagger`, so sibling 1 is released, its first token awaited, then the rest released — 1 template
write + N−1 reads instead of N full prefills.

**Acceptance criteria:**

```gherkin
Scenario: A staggered sibling fan-out releases on stream-start
  Given a fan-out of N sibling-template subagents through Stagger
  When sibling 1 begins streaming
  Then the remaining siblings are released and the journal records the stagger releases

Scenario: Stagger degrades safely if the first never streams
  Given the first sibling completes or raises without a stream-start signal
  When the gate evaluates
  Then the rest are released on that degrade path, journaled
```
→ spec files: `spec/lain/subagent/stagger_spec.rb`, `spec/lain/tools/subagent_spec.rb`

**Escalation triggers:**
- Plumbing `on_stream_started` through `agent.rb` changes the non-fan-out dispatch path — the signal
  must be inert (no behavior change) when no observer is wired; an existing agent-loop spec breaking
  means the plumb isn't transparent, STOP.

### B2 — Isolation backend abstraction + null & worktree strategies  [wave 2] [risk: high] ✅ landed 045be2a (panel: REQUEST-CHANGES → APPROVE; blockers fixed: detached-HEAD worktrees no branch leak, Monitor-serialized acquire, GIT_* env scrub found by the landing hook itself)

**Depends on:** B1
**Files:** `lib/lain/isolation.rb`, `lib/lain/isolation/lease.rb`, `lib/lain/isolation/null.rb`, `lib/lain/isolation/worktree.rb`, `spec/lain/isolation/null_spec.rb`, `spec/lain/isolation/worktree_spec.rb`
**Reuse:** `WorkerEnv` (B1), `Paths#project_hash` (per-worker key, `paths.rb:56`), `Mixlib::ShellOut` (via a factory, for `git worktree add/remove`), `Workspace::Snapshot(root:)` relocatable-root idiom.
**Shared-file wiring:** orchestrator adds the `isolation` manifest line to `lib/lain.rb`.

`Isolation#acquire(worker_id) → Lease` where `Lease` carries a `WorkerEnv` and a `#release`. `Null`
returns the shared process WorkerEnv (baseline; release is a no-op). `Worktree` runs `git worktree
add` under a per-worker path (cwd = the worktree), released with `git worktree remove`; a leftover
worktree is reaped, not silently leaked.

**Acceptance criteria:**

```gherkin
Scenario: The null backend leases the shared environment
  Given the Null isolation backend
  When a worker acquires a lease
  Then the lease's WorkerEnv is the process env and cwd, and release is a no-op

Scenario: The worktree backend leases an isolated checkout
  Given a git repo and the Worktree backend
  When a worker acquires a lease
  Then a git worktree exists at a per-worker path and the lease's cwd points there
  And releasing the lease removes the worktree
```
→ spec files: `spec/lain/isolation/{null,worktree}_spec.rb`

**Escalation triggers:**
- `git worktree add` from inside a worktree, or on a dirty tree, fails — the backend must surface the
  failure loudly (a lease is refused), never hand back a shared-cwd lease that silently defeats
  isolation. See the memory `worktree-forks-from-session-start`: worktrees fork from creation time.
- The worktree spec needs a real git repo — mark it appropriately and confirm it doesn't mutate the
  lain repo it runs in (operate in a tmp repo).

### B8 — Orchestrator-worker arm + synthesis pass                    [wave 2] [risk: high] ✅ landed 90aaf24 (panel: REQUEST-CHANGES → APPROVE; usage re-attribution labeled `reattributed`/`attributed_from`, arm.rb reachability contract rewritten to match reality; follow-ups: fan-out children cache-cold by construction, Subagent#fan_out returns text only, real-concurrency commit race unexercised under Mock)

**Depends on:** B7, B9
**Files:** `lib/lain/arm/orchestrator_worker.rb`, `lib/lain/arm/synthesis.rb`, `spec/lain/arm/orchestrator_worker_spec.rb`, `spec/lain/arm/synthesis_spec.rb`
**Reuse:** `Subagent`/`ChildBuilder` fan-out, `ToolRunner#gather` within-turn parallelism, B9's staggered sibling release, multi-parent `Event` (`event.rb:37`) + `Timeline#meet` (the synthesis writes the first multi-parent event), injected isolation (B2, default Null).
**Shared-file wiring:** orchestrator adds the two `arm/*` index lines to `lib/lain/arm.rb`.

Lead spawns N workers (worktree-isolated when a Worktree backend is injected), fans out, then a
**synthesis turn** folds the N results into one turn that writes a multi-parent causal event naming
the results it folded.

**Acceptance criteria:**

```gherkin
Scenario: Fan-out results are synthesized into one multi-parent event
  Given an orchestrator-worker arm over a task with N independent subtasks
  When the workers finish and the lead synthesizes
  Then a synthesis event names the N result events as causal parents
  And the arm returns a graded Run

Scenario: The arm runs under an injected isolation backend
  Given the arm with a Worktree isolation backend
  When it fans out workers
  Then each worker's tools operate under its own leased WorkerEnv
```
→ spec files: `spec/lain/arm/{orchestrator_worker,synthesis}_spec.rb`

**Escalation triggers:**
- Writing a multi-parent event through the Store trips referential integrity (`event.rb:13`) if a
  parent wasn't put — ensure all worker result events are committed before the synthesis event; a
  dangling causal parent must fail loud, not be dropped.
- A worker's failure should not silently vanish from the synthesis — a failed worker is a named
  input (`purge-failed` keeps the error), not an omission; confirm the synthesis sees it.

### B10 — Adaptive-router arm via spawn-time oracle (OR-5)           [wave 2] [risk: medium] ✅ landed 4572bb2 (panel: APPROVE; follow-up ticket: `Telemetry::OracleAnswer` needs a child correlator before a true multi-child routed fan-out — coordinate with B6/B12 or a later chunk)

**Depends on:** B7; **cross-plan:** the oracle seam (`chunk-bench-science.md` T2/T3) must be on `main`
**Files:** `lib/lain/arm/adaptive_router.rb`, `lib/lain/oracle/router.rb`, `spec/lain/arm/adaptive_router_spec.rb`, `spec/lain/oracle/router_spec.rb`
**Reuse:** the oracle seam (T2 `Oracle`, T3 journal/replay), `SpawnPolicy` (the child model/sibling-template the router picks), `Arm` seam (B7). Respects the birth-boundary rule by construction — the seam only exists at spawn.
**Shared-file wiring:** orchestrator adds the `oracle/router` + `arm/adaptive_router` index lines.

At spawn, a router oracle picks the child's model and/or sibling template from task features; each
routing decision journals; mid-session re-routing is structurally impossible.

**Acceptance criteria:**

```gherkin
Scenario: The router picks a child strategy at spawn and journals it
  Given a routed fan-out with an oracle-backed router
  When children are spawned
  Then each routing decision (model/template) is journaled at the spawn boundary

Scenario: Re-routing mid-session is structurally impossible
  Given a running child
  When one attempts to re-route it after spawn
  Then no seam exists to do so (the router is only reachable at spawn)
```
→ spec files: `spec/lain/arm/adaptive_router_spec.rb`, `spec/lain/oracle/router_spec.rb`

**Escalation triggers:**
- The oracle seam (T2/T3) is not yet on `main` — STOP; this card is gated on the bench-science chunk
  landing (Open decisions).
- Per-child model selection puts each child in a different cache namespace — confirm this is the
  intended cost (it's the arm's whole point), and that it's reported, not hidden.

### B11 — Dual-ledger arm (Task/Progress ledger + stall→replan FSM)   [wave 2] [risk: high] ✅ landed 0788f04 (panel: APPROVE-WITH-FIXES → APPROVE; default stall detector made honest — known blind spot documented: ever-changing non-answers never stall, `progress:` seam for smarter detectors)

**Depends on:** B7
**Files:** `lib/lain/arm/dual_ledger.rb`, `lib/lain/arm/ledger_state.rb`, `lib/lain/agent/loop_machine.rb`, `spec/lain/arm/dual_ledger_spec.rb`, `spec/lain/agent/loop_machine_spec.rb`
**Reuse:** `Workspace#with`/`#to_blocks` (the sent-not-stored ledger carrier), `LoopMachine` (`agent/loop_machine.rb`) + its `before_transition` `announce_transition` journal hook, `Arm` seam.
**Shared-file wiring:** orchestrator adds the two `arm/*` index lines to `lib/lain/arm.rb`.

A structured Task/Progress ledger (facts+plan / progress+next-subtask) carried in the Workspace;
stall detection (no progress for K steps) fires a **replan** as a new `LoopMachine` transition with a
`before_transition` Journal hook. Maps Magentic-One onto Lain (`orchestration-experiments.md:44`).

**Acceptance criteria:**

```gherkin
Scenario: The ledger rides the Workspace, sent-not-stored
  Given a dual-ledger arm mid-run
  When the request renders
  Then the Task/Progress ledger appears at the request tail and is never appended to the Timeline

Scenario: A stall fires a journaled replan transition
  Given no progress for K steps
  When the arm evaluates progress
  Then a replan transition fires on the LoopMachine and is journaled via before_transition
```
→ spec files: `spec/lain/arm/dual_ledger_spec.rb`, `spec/lain/agent/loop_machine_spec.rb`

**Escalation triggers:**
- Adding a `:stalled`/replan state to `LoopMachine` must not make an existing legal transition illegal
  — an existing `loop_machine_spec.rb`/gate spec asserting the current transition table breaking means
  the new state is mis-wired; STOP.
- The ledger structure tempts a per-turn Store append — it must ride the Workspace (`#with`), not
  accrete a stale copy per turn (the whole point of sent-not-stored).

### B3 — DB-index isolation strategy (Postgres createdb + Redis index) [wave 3] [risk: high] ✅ landed e5d1b51 (panel: REQUEST-CHANGES → APPROVE; leak blockers fixed — inner-lease rollback, independent teardown aggregation; dedicated `:services` spec tag; NIT recorded: inner-release raise masks aggregated service error, message-loss only)

**Depends on:** B2; **gated on** the service-declaration format (Open decisions)
**Files:** `lib/lain/isolation/db_index.rb`, `lib/lain/isolation/services/postgres.rb`, `lib/lain/isolation/services/redis.rb`, `spec/lain/isolation/db_index_spec.rb`
**Reuse:** B2 `Lease`/`WorkerEnv`, `Paths#project_hash` (DB-name key), `Mixlib::ShellOut` factory (for `createdb`/`dropdb`), the service-declaration file decided in Open decisions.
**Shared-file wiring:** orchestrator adds the `isolation/db_index` + `isolation/services/*` index lines.

For a project declaring Postgres/Redis, provision a per-worker Postgres DB (`createdb
lain_worker_<hash>`) and assign a Redis DB-index off the default; inject `DATABASE_URL`/`REDIS_URL`
into the lease's `WorkerEnv`; release with `dropdb` / index-release. Acts only when the services are
declared — otherwise degrades to a code-only lease.

**Acceptance criteria:**

```gherkin
Scenario: A declared Postgres service gets a per-worker DB
  Given a project declaring a Postgres service and the DbIndex backend
  When a worker acquires a lease
  Then a per-worker database is created and DATABASE_URL in the lease points at it
  And releasing the lease drops the database

Scenario: A declared Redis service gets a distinct DB-index
  Given a project declaring Redis
  When two workers acquire leases
  Then each lease's REDIS_URL selects a distinct Redis DB-index
```
→ spec file: `spec/lain/isolation/db_index_spec.rb` (`:integration`-tagged — needs pg/redis)

**Escalation triggers:**
- The service-declaration format is not yet decided with the human — STOP (Open decisions gate).
- `createdb` collides with a pre-existing DB of the same name — the strategy must refuse or
  uniquify loudly, never reuse a shared DB (that silently defeats isolation and can corrupt another
  worker's data).

### B4 — Compose-per-worker isolation strategy                       [wave 3] [risk: high] ✅ landed b03c312 (panel: REQUEST-CHANGES → APPROVE; ps-exitstatus blocker fixed — failed probe can no longer green-light `down -v` on a foreign stack; env_var duplicate guard across kinds; daemon snapshot pinned acquire→release)

**Depends on:** B2; **gated on** the compose project-name/port convention (Open decisions)
**Files:** `lib/lain/isolation/compose.rb`, `spec/lain/isolation/compose_spec.rb`
**Reuse:** B2 `Lease`/`WorkerEnv`, `Paths#project_hash` (compose `-p` project name), `Mixlib::ShellOut` factory (`docker compose up/down/port`).
**Shared-file wiring:** orchestrator adds the `isolation/compose` index line.

`docker compose -p lain_<project_hash> up` per worker; read back published ports and inject the
service URLs into the lease's `WorkerEnv`; release with `docker compose down -v`.

**Acceptance criteria:**

```gherkin
Scenario: A worker gets its own compose stack
  Given a project with a compose file and the Compose backend
  When a worker acquires a lease
  Then a namespaced compose stack is up and the lease's env points at its published ports
  And releasing the lease tears the stack down with its volumes
```
→ spec file: `spec/lain/isolation/compose_spec.rb` (`:integration`-tagged — needs docker)

**Escalation triggers:**
- The port-discovery mechanism (compose `port` vs declared mapping) is undecided — STOP (Open
  decisions gate).
- A failed `up` leaves a partial stack — release must be idempotent and reap partial stacks, or a
  crashed worker leaks containers/volumes.

### B5 — Isolation lease lifecycle in Supervisor/Restart             [wave 3] [risk: high] ✅ landed 61b5af8 (panel: APPROVE-WITH-FIXES; cancellation-window lease leak closed via registered-flag ensure; crash-lease retention documented; integration touch-up c4f445f deconflicted B6/B8 spec fakes; follow-up: crashed-worker worktrees persist until #stop — reap sweep ticket)

**Depends on:** B1, B2
**Files:** `lib/lain/supervisor.rb`, `lib/lain/supervisor/restart.rb`, `lib/lain/tools/subagent.rb`, `spec/lain/supervisor_spec.rb`, `spec/lain/supervisor/restart_spec.rb`
**Reuse:** `Supervisor#adopt`/`#stop` (`supervisor.rb:83`/`:116`), `Supervisor::Registration`, `Restart#call` (`restart.rb:93`), `ChildBuilder` DI (`subagent.rb:302`) — inject the lease so a child's tools run under its WorkerEnv.
**Shared-file wiring:** none (owns the supervisor/restart edits; independent of the strategy cards).

Acquire an isolation lease when a worker is adopted; release it on teardown (`#stop`/registration
end); **re-acquire on `Restart#call`** so a restarted worker regains an equivalent isolated
environment. Lease acquire/release is journaled (via B6's record).

**Acceptance criteria:**

```gherkin
Scenario: A worker's lease is acquired on adopt and released on stop
  Given a supervisor with an isolation backend
  When it adopts a worker and later stops
  Then the worker's tools ran under its leased WorkerEnv and the lease was released

Scenario: Restart re-acquires an equivalent lease
  Given a crashed worker with a released lease
  When Supervisor::Restart revives it
  Then a fresh equivalent lease is acquired and the revived worker runs under it
```
→ spec files: `spec/lain/supervisor_spec.rb`, `spec/lain/supervisor/restart_spec.rb`

**Escalation triggers:**
- `Restart#call` today makes **no** external calls (pure replay) — adding lease re-acquisition
  introduces side effects into the restart path; confirm a failed re-acquire fails the restart
  loudly rather than reviving a worker with a shared/leaked environment.
- Releasing a lease whose resources a still-running sibling shares (Null backend) must be a no-op —
  don't tear down shared state on one worker's exit.

### B6 — Lease/allocation as attributed Journal events               [wave 3] [risk: low] ✅ landed 21db524 (panel: APPROVE; two doc NITs applied at landing — no-phantom-acquired + wrap-once)

**Depends on:** B2
**Files:** `lib/lain/isolation/journal.rb`, `lib/lain/telemetry.rb` (new `IsolationLease` record), `spec/lain/isolation/journal_spec.rb`
**Reuse:** `Journal`/`Telemetry` record idiom, the `Sink` discipline (never `$stdout`), `Compare` (so lease/thrash cost is a reportable column later).
**Shared-file wiring:** none (sole telemetry.rb edit in this plan).

Every lease acquire/release (and service provision/teardown) is an attributed Journal event, so
isolation cost and thrash are observable and `Compare`-able — the discipline the isolation-as-Effect
fold-in wants (`hn-agent-landscape-2026-07.md` #6).

**Acceptance criteria:**

```gherkin
Scenario: Lease lifecycle is journaled
  Given an isolation backend acquiring and releasing a lease
  When the lifecycle runs
  Then acquire and release each emit an attributed IsolationLease journal record with the worker key
```
→ spec file: `spec/lain/isolation/journal_spec.rb`

**Escalation triggers:**
- A `DATABASE_URL`/`REDIS_URL` carrying a password would land in the Journal — the record must carry
  the worker key and service identity, **never the credential**; digests and journals stay
  credential-free (Workspace-is-sent-not-stored discipline). If a URL must be journaled, redact it.

### B12 — Arms bench sweep + arm-specific process metrics            [wave 3] [risk: medium] ✅ landed 48124ff (panel: APPROVE-WITH-FIXES; boundary reproduces — procedural OW 0.875/0.500-min with context-loss, parallel ties at 1.0; tie-disclosure + fidelity NOTEs added; wall-time honestly ABSENT under replay)

**Depends on:** B8, B11
**Files:** `lib/lain/bench/arm_sweep.rb`, `spec/lain/bench/arm_sweep_spec.rb`
**Reuse:** B0 fixture suite, the arms (B7 single-thread, B8 orchestrator-worker, B11 dual-ledger), `Compare` (grader × tokens × wall-time), context-loss detection (reuse `chunk-bench-science.md`'s frustration/lineage projection if landed; else a Journal heuristic), replans/stalls from B11's journaled transitions.
**Shared-file wiring:** orchestrator adds a `bench arm-sweep` subcommand line to `lib/lain/bench/cli.rb`.

Run the arms over B0's suite; report grader × tokens × wall-time × context-loss events ×
replans/stalls as distributions — the comparison the papers assert but rarely produce
(`orchestration-experiments.md:102`). Reproduces the "procedural → single-agent" boundary on tasks we
can judge.

**Acceptance criteria:**

```gherkin
Scenario: The sweep ranks arms with process metrics
  Given the arm fixture suite and recorded trajectories
  When the arm sweep runs over single-thread, orchestrator-worker, and dual-ledger
  Then it reports grader, tokens, wall-time, context-loss, and replans/stalls as distributions
  And single-thread is present as the control every arm is measured against
```
→ spec file: `spec/lain/bench/arm_sweep_spec.rb`

**Escalation triggers:**
- Wall-time is only meaningful under real parallelism (worktrees) — the sweep must record wall-time on
  live/parallel arms and mark it absent for dry replays, not fabricate it (same discipline as the
  decider sweep).
- Context-loss detection depends on the bench-science lineage projection — if that chunk's T8/T11
  didn't land, fall back to a documented Journal heuristic and `log` the reduced fidelity, don't
  silently drop the metric.

## Integration checks

After the last wave:
- `bundle exec rspec` — full suite green; `:integration`-tagged isolation specs (B3/B4) run only where
  pg/redis/docker are present. `LAIN_INTEGRATION=1 … rspec` in a provisioned environment for those.
- `bundle exec rubocop -a` clean at default metrics; no `Metrics/*` loosening (extract collaborators —
  arms and isolation strategies are natural objects).
- `cargo test && cargo clippy --all-targets -- -D warnings` — unchanged (no Rust this chunk).
- `pre-commit run --all-files`; `spec/output_discipline_spec.rb` green (arms/isolation/journal write to
  `Sink`/Journal, never `$stdout`).
- `Ractor.shareable?` holds for `WorkerEnv`, `Lease`, ledger-state, and any new value objects.
- **Manual dogfood pass (human):** with the Worktree backend, run the arm sweep over B0's suite and
  read the `Compare` report — confirm single-thread-vs-orchestrator-worker on a procedural task and a
  genuinely-parallel task, and that wall-time/context-loss/replan columns populate. Provision a
  throwaway pg+redis and exercise the DbIndex backend end-to-end (createdb → DATABASE_URL in a
  worker's bash → dropdb on release). Confirm no worktree/DB/compose stack is leaked after a full run
  and after a supervised kill+restart.
- **Credential-safety check (human):** grep a full run's Journal for any injected service URL
  password — must find none (B6 redaction).
