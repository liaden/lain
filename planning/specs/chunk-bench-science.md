# Bench-science: oracles, verification graders, tool-disclosure, cache-aware compaction

status: done
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman · Aaron Patterson (Ruby roster, `create-plan/references/rosters.md`)

## Execution log

- **Wave 1 — LANDED (2026-07-18):** T5 `cfa2d9b`, T12 `123ecac`, T15 `e515ded`, T1 `c15b3f8`,
  T7 `e1ae1fb`, T8 `c029f9d`, T9 `d0e680b`, T16 `832b91a`, T2 `84145af`, T21 `172c62a`.
  Integrated suite green (2914 examples, 0 failures, 2 pending). Every card panel-reviewed;
  substantive defects caught & fixed: T1 silent tool_choice clobber, T7 `Prune` value-equality
  `keep_last:` corruption, T8 unfrozen `Call` fields + silent dangling-lineage, T9 duplicate-digest
  replay collapse, T16 duplicate-content todo masking, T21 `#requires` drift + stale-workspace footgun,
  T2 InvalidAnswer/InvalidInput error-family split.
- **Wave 2 — LANDED (2026-07-18):** T17 `ec282c8`, T10 `c3317f7`, T13 `b3cd87c`, T11 `d05187f`,
  T3 `94be6f4` (T3's always-empty `usage` fixed: real tokens/model now threaded into the Journal).
- **Wave 3 — LANDED (2026-07-18):** T14 `f830bb1`, T4 `3da8d8b` (T18 pending a shareability fix).
  Panel caught: T14 silent per-arm mis-scoring (malformed recorded key → fabricated 0.0), T18 pipeline
  lambda capturing `self`+live Journal (breaks Ractor.shareable? in the T21 seam). **T4 exe/lain live
  wiring DEFERRED (orchestrator decision):** the memory-save heuristic over-refuses legitimate opaque
  tokens (git SHAs, UUIDs, tracking numbers) — not conservative enough for the live security gate; default
  stays `NullOracle`. Follow-up: recalibrate the heuristic (or give "not worth saving" a distinct refusal
  reason from `ORACLE_MATCH`) before wiring it live; add explicit `Ractor.shareable?` specs for the two
  oracle definitions. T4 unit lands as scoped (AC2 proven by spec with the Gate injected).
- **Wave 4 — LANDED (2026-07-18):** T19 `ffae1c6`, T20 `34e0fd5`, T6 `49c0cfe`.
- **ALL 21 CARDS LANDED. Integration checks GREEN (2026-07-18):** `bundle exec rspec` 3074 examples,
  0 failures, 2 pending (+300 over the 2774 baseline); `bundle exec rubocop` clean, 540 files, no
  offenses, `.rubocop.yml` unchanged (no `Metrics/*` loosening); `cargo test` 106 pass + `cargo clippy
  --all-targets -- -D warnings` clean (Rust unregressed); `pre-commit run --all-files` all hooks pass;
  output-discipline spec green; `Ractor.shareable?` pinned per-card for every new value object.
  **MANUAL DOGFOOD OWED (human, Joel):** run the decider-sweep and disclosure-sweep over their committed
  fixtures and read the `Compare` reports — confirm the cache-write column and the inline-arm pollution
  cost are visible (not averaged), and the deferred-disclosure token delta. Both sweeps are library-only
  (no CLI subcommand, matching the `Bench::Sweep` precedent) — a follow-up may CLI-expose them. Panel caught: T18 shareability (above), T20 stale replace-comment + a
  cache_state coerce-before-guard, T19 caller-owned-gate/thread-safety doc gaps. **Confirmed latent
  T4 bug (follow-up owed):** `Oracle::PruneScoring`'s MODEL tier crashes opaquely (`NoMethodError:
  undefined method 'encoding' for Integer`) when `age_turns` is an Integer — `LockedBinding#render`/ERB
  needs String slot values, but `age_turns` is an Integer everywhere else. T6 stringifies at its own call
  site (correct, minimal); the real fix is a loud named `Prompt::NonStringSlot`-style failure (or slot
  coercion) in T4/LockedBinding, so the next model-tier caller doesn't hit the opaque ERB crash. **T18 live-integration DEFERRED (orchestrator decision):**
  the scheduler ships as a pure policy object exercised via T21's pipeline seam; wiring it into the live
  agent loop needs `agent.rb` to call `scheduler.pipeline(...)` per turn and render through a per-turn
  `Context.new(pipeline: chosen)` (base = default provider so deferring turns stay byte-identical) — the
  turn-middleware mount is INERT (can't reach `#render`), so it was NOT applied. Deferred as a follow-up;
  bench studies the policy offline, and T19/T20 extend/observe the scheduler without needing live wiring. Panel caught: T13 info-leak
  (search matched full description, disclosed only truncated), T10 unfrozen `Flag` fields, T17
  unpinned string-keyed usage extraction, T11 unfrozen digests, T3 always-empty journaled `usage`.
  Note: all wave-2 worktrees forked STALE (missing wave-1) and each merged main before building —
  the known `isolation: worktree` staleness trap; wave-3/4 briefs must instruct the same.
- **Wave 2 follow-ups owed:** journaled `turn` records carry no `causal_parents`, so no journal-shaped
  grader (T11, and future GR-3-family) can exercise `Timeline#causal_meets`'s multi-ancestor SET case —
  wire-format gap; T11 ships only the `:rephrase_loop` signal (self-correction/abandonment folded into
  `repaired:`, separate signals deferred); neither disclosure arm (Upfront/Deferred) is wired into live
  `Context#render` yet — consumed only by the T14 sweep over fixtures; live wiring is a follow-up.
- **Follow-ups owed (not gating this chunk):** per-model `cache_profile` accuracy before T17/T18 trust
  it; base `Provider#cache_profile` abstract for Bedrock/Anthropic/Bedrock/Mock; `:structured_output`
  guarantee-strength gap (resolved: single capability, documented in each CAPABILITIES comment);
  `Async::Variable`→`Async::Promise` deprecation on `promise.rb`; non-default-pipeline session round-trip
  reproducibility (T18/T20); relocate `MINIMUM_CACHEABLE_TOKENS` to a neutral wire-facts home.

## Intent

Turn the bench from a ruler into decision-grade science. Four independent streams, all pure
Ruby, all offline over the Journal and `DryReplay`-substitutable, that make every future
experiment's findings trustworthy and unblock two headline experiments (the decider-locus sweep
and harness-variance). Satisfies ROADMAP M3c fold-ins: **Oracles** (`planning/specs/oracles.md`
OR-1/2/3/4/6), **behavioral & verification graders** (`planning/specs/graders.md` GR-1/2/3),
the **tool-disclosure axis** (ROADMAP:48, "highest-leverage cheap change"), and **cache-aware
compaction scheduling** (`planning/specs/cache-aware-compaction.md` CAC-1..6). Nothing here
touches the agent loop's hot path except through existing seams; nothing requires the exec
boundary (M6) or new Rust.

## Grounding

Verified against code on **2026-07-18** by five parallel `Explore` passes (grader/bench/journal,
oracle prerequisites, context/toolset/compact, orchestration, isolation). Where the specs
described intent and code diverged, code is source of truth. Key findings this plan is built on:

- **Combinators are pure `call(messages) → messages`** (`lib/lain/context/base.rb:35`), composed
  under `>>` (`base.rb:52`), declaring `#requires` (`base.rb:43`). A combinator sees **only the
  message list** — no clock, usage, or provider — so cache-aware scheduling (CAC) must live in an
  **outer scheduling layer**, not inside the pure `Compact#call` (`context/compact.rb:43`, which
  today compacts unconditionally on a byte-length threshold and has no scheduling logic). The
  `"a monoid"` shared law group (`spec/support/shared_examples/monoid.rb:46`) **is already applied
  to `Context::Combinator`** (`spec/lain/context/base_spec.rb:28` — grounding correction,
  panel-caught 2026-07-18; the original "no combinator spec does this" claim was wrong). New
  combinators here must still include it.
- **`Tool::Input` is the schema-dual** (`lib/lain/tool/input.rb`): one `field` declaration yields
  both `to_json_schema` and ActiveModel validation. Reusable verbatim for an oracle's typed
  answer schema. **Prompt slots render in a locked pure binding** (`lib/lain/prompt/locked_binding.rb`);
  impurity raises `ImpureSlot`. Reusable for oracle prompt templates.
- **`Lain::Promise`** (`lib/lain/promise.rb`) wraps `Async::Variable`; `#await` parks the fiber.
  `ask_human` (`lib/lain/tools/ask_human.rb:87`) emits + returns a promise and is the shape an
  oracle mirrors — **but ask_human writes its Q&A as `:message` events to the Store**; oracles must
  journal to the **Journal** instead (control-flow, not conversation — `oracles.md:44`).
- **Replay substitution** is `Effect::Handler::Recorded` (`lib/lain/effect/handler/recorded.rb:24`),
  keyed by `tool_use_id` over `type:"tool_result"` Journal records, missing keys fall through
  loudly. Oracle answer substitution (OR-2) is a **net-new parallel path** keyed by
  `(oracle_digest, question)` — no production writer emits standalone `tool_result` records today;
  tool results live inside turn-record `content` blocks.
- **Provider gaps for oracles:** Ollama's native structured-output `format` field is **not
  encoded** (`provider/ollama/encoding.rb:45`); Anthropic tool-forcing is only reachable via the
  `Request#extra[:tool_choice]` escape hatch (`anthropic_encoding.rb:53`). No model-tier/haiku
  abstraction — model is a bare string per `Request`/`Context`. The oracle seam therefore injects
  its provider+model directly; forced-decoding is an enhancement, not a prerequisite.
- **`RefuseSecretWrites`** (`lib/lain/middleware/refuse_secret_writes.rb:67`) already has an
  injectable `oracle:` seam defaulting to `NullOracle` with a binary `#secret?(input)` predicate —
  the memory-save-gating oracle (OR-3) plugs in here, but as a richer typed oracle than the current
  predicate expects.
- **Graders:** no base class — `Grader` is a module (`lib/lain/grader.rb:11`); the convention is
  `#grade(subject) → Grade(score, pass, why)` with `why` mandatory (`grader.rb:18`). **No decorator
  seam exists** (GR-1 builds it), and `Grade` has **no journaling** (`Grade` is not a `Telemetry`).
  `Grader::Rubric` drives a `Provider` directly in a fresh context window (`rubric.rb:66`).
- **Journal analysis:** `Journal.records(entries, type:)` (`journal.rb:102`) is the lazy offline
  reader. `tool_use` blocks live inside `type:"turn"` records' `content` (`session_record.rb:55`);
  the declared toolset schema is in the header record's `"tools"` (`session_record.rb:48`). Both
  GR-2 inputs are present but **not pre-joined**. Lineage primitives `#causal_meets` /
  `#dominator_meet` **exist** (TL-3, `timeline.rb:153`/`:182`); `spawned_from` is turn `meta`. The
  shared "tool-call events + outcomes indexed by lineage" projection GR-2/GR-3 both need is
  **unbuilt** — `Event::Projection#provenance` (`event/projection.rb:82`) is results-only and has
  zero callers; `Bench::Session::MemoryReplay#outcomes` (`memory_replay.rb:77`) has the pairing
  recipe but is private and hardcoded to `memory_write`.
- **Compare** (`lib/lain/compare.rb`) reports 4 metrics (`total_tokens`, `cache_hit_ratio`, `cost`,
  `score`); there is **no cache-write column** though `Usage.cache_creation_input_tokens` is
  recorded end-to-end and journaled via `Telemetry::TurnUsage` (`telemetry.rb:149`). OR-4's sweep
  needs that column.
- **Toolset renders upfront full-JSON always** (`tool.rb:132`, `toolset.rb:99`, sorted +
  canonicalized for cache stability). No deferred/searchable/code-API disclosure concept exists —
  the axis is entirely net-new.
- **Provider cache profile is unbuilt** — only boolean `CAPABILITIES`; `StatusFeed::CACHE_TTL_SECONDS
  = 300` (`status_feed.rb:63`) is an explicit placeholder for CAC-2's `#cache_profile`. The
  20-block lookback lives as constants in `cache_breakpoints.rb:58`; the 4096 min-prefix is
  **already a production constant** (`Tool::SpawnPolicy::MINIMUM_CACHEABLE_TOKENS`,
  `spawn_policy.rb:112` — grounding correction, panel-caught 2026-07-18), so T15 sources
  `min_prefix_tokens` from it rather than re-introduce the literal. `TodoWrite`/`Session` retain no prior list (`session.rb:114`), so CAC-1's plan-step
  signal has no seam — it must be added.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only):
  - `lib/lain.rb` — one manifest line per new unit (`oracle`, `compaction`), placed by dependency
    order.
  - `lib/lain/context.rb` — index lines for new combinators (`DedupeToolCalls`, `PurgeFailedInputs`,
    `ProtectedPatterns`); it is the `context/` unit index and owns `Context::REQUIRES`.
  - `lib/lain/grader.rb` — index lines for `Grader::Verified`, `Grader::Refuter`,
    `Grader::ToolSteering`, `Grader::FrustrationRepair` and the shared projection.
  - `lib/lain/provider.rb` (base) — one-line `CAPABILITIES` additions (`:structured_output`) and the
    `#cache_profile` abstract declaration. Orchestrator-owned; no card lists it under **Files**.
  - `lib/lain/provider/anthropic.rb`, `lib/lain/provider/ollama.rb` are **card-owned by T15** (its
    `#cache_profile` bodies) — the sole card editing them. **Documented exception:** T1's one-line
    `:structured_output` additions to those two files' `CAPABILITIES` arrays are applied by the
    orchestrator at T1's integration (a wiring line into T15's already-merged files), so no two cards
    edit them. T1 does not list them under **Files**.
  - New unit index files (`lib/lain/oracle.rb` created by T2, `lib/lain/compaction.rb` created by
    T16, `lib/lain/toolset/disclosure.rb` created by T12) are created by their first card in the same
    commit as the unit (the standard lain new-file+index rule); **subsequent** same-unit index-line
    additions (T3, T4; T13) are orchestrator wiring. The existing `context.rb`/`grader.rb` indexes are
    orchestrator-owned throughout — cards add new leaf files and hand back index lines.
  - `exe/lain` — one-line wiring diffs only (register the memory-save oracle, mount a scheduler),
    never card scope.
  - `lain.gemspec`, `.rubocop.yml`, `spec/spec_helper.rb`, `CLAUDE.md` — untouched expected;
    orchestrator applies any incidental line.
  - `lib/lain/telemetry.rb` — new journal record types (`Grade` verdict, oracle answer, compaction)
    are added here; **sequenced by wave** (T9 wave-1, T3 wave-3, T20 wave-4 never collide). Treat
    each addition as card-owned within its wave.
- Deviations from the default process: none.

## Open decisions

None block a wave-1 card. Deferred / cross-plan (do not gate any card here):
- **OR-5 spawn-time routing oracle** is deferred to `chunk-orchestration-arms-isolation.md` (it *is*
  the adaptive-router arm) — the oracle seam (T2/T3) it needs ships here.
- **Tool-disclosure code-API arm** needs code mode (`eval_ruby`, exec boundary M6) — out of scope;
  this plan ships the upfront (baseline) and deferred/searchable arms and the sweep between them.
- **GR-1 refuter locus** (oracle vs full Rubric): resolved by construction — the refuter is an
  **injected collaborator** (T9), default a Rubric-in-separate-context; an oracle-backed refuter
  swaps in without changing `Grader::Verified`.

## Waves

```
Wave 1 (no deps): T1, T2, T5, T7, T8, T9, T12, T15, T16, T21
Wave 2: T3 (←T2), T10 (←T8), T11 (←T8), T13 (←T12), T17 (←T15)
Wave 3: T4 (←T2,T3), T14 (←T12,T13), T18 (←T16,T17,T21)
Wave 4: T6 (←T4,T5), T19 (←T18), T20 (←T18)
Critical path: T2 → T3 → T4 → T6

T21 added mid-execution (panel-caught blocker, 2026-07-18): T18's scheduler and the live
integration of T7's OR-6 combinators both need a pipeline-injection seam on `Context` that no
original card built.
```

## Tasks

### T1 — Provider structured-output / forced typed answer          [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/provider/ollama/encoding.rb`, `lib/lain/provider/anthropic_encoding.rb`, `spec/lain/provider/ollama/encoding_spec.rb`, `spec/lain/provider/anthropic_encoding_spec.rb`
**Reuse:** `Request#extra` (`request.rb`), `Tool::Input#to_json_schema` (the schema an oracle passes), `Ollama::Encoding#encode` (`ollama/encoding.rb:45`), `AnthropicEncoding#encode`'s `extra` merge (`anthropic_encoding.rb:51`)
**Shared-file wiring:** orchestrator adds `:structured_output` to `Provider::CAPABILITIES` (`provider.rb`) and to `Provider::Ollama::CAPABILITIES` (`ollama.rb`) and `Provider::Anthropic::CAPABILITIES` (`anthropic.rb`).

**Acceptance criteria:**

```gherkin
Scenario: Ollama encodes a JSON-schema format for a structured request
  Given a Request carrying a JSON schema as its structured-answer format
  When Provider::Ollama encodes it
  Then the wire payload includes a "format" field equal to that schema
  And a request without a structured format encodes byte-identically to today

Scenario: Anthropic forces a single tool for a structured request
  Given a Request whose structured-answer schema names one forcing tool
  When Provider::Anthropic encodes it
  Then the SDK params carry tool_choice forcing that tool
  And a request without a structured format encodes byte-identically to today
```
→ spec files: `spec/lain/provider/ollama/encoding_spec.rb`, `spec/lain/provider/anthropic_encoding_spec.rb`

**Escalation triggers:**
- A recorded cassette or the two-process prelude-invariant spec (`spec/…prelude…`) shows a
  non-structured request's bytes moved — STOP; the "byte-identical when unused" AC is violated.
- `AnthropicEncoding` already forwards a `tool_choice` via `extra` in some existing spec — reconcile
  rather than double-encode; confirm precedence with the orchestrator.

### T2 — The Oracle seam                                            [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/oracle.rb`, `lib/lain/oracle/definition.rb`, `lib/lain/oracle/heuristic.rb`, `lib/lain/oracle/model.rb`, `spec/lain/oracle_spec.rb`, `spec/lain/oracle/heuristic_spec.rb`, `spec/lain/oracle/model_spec.rb`
**Reuse:** `Prompt::LockedBinding` (template render), `Tool::Input` (typed answer schema + validation), `Lain::Promise` (`promise.rb`), `Provider#complete`, `Canonical.digest` (definition digest). The heuristic tier mirrors `Middleware::RefuseSecretWrites::NullOracle`'s Null-Object shape.
**Shared-file wiring:** orchestrator adds `require`-manifest line for the `oracle` unit in `lib/lain.rb`.

An oracle = a content-addressed definition (template + typed answer schema + model tier) with two
interchangeable tiers behind one interface: `Oracle::Model` (renders the template, calls
`provider.complete`, decodes+validates the answer via `Tool::Input`, **raises** on invalid) and
`Oracle::Heuristic` (same interface, a pure `#call` predicate/threshold, no model call). Both return
a `Promise`; awaiting parks the fiber. The answer decoder is injected (default: parse the model's
JSON reply and `Tool::Input.build`; T1's structured-output is a stronger decoder that swaps in).

**Acceptance criteria:**

```gherkin
Scenario: A model oracle returns a validated typed answer
  Given an oracle defined with a template and a typed answer schema
  When it is asked a question against a Mock provider returning a valid answer
  Then awaiting the returned promise yields the coerced typed answer

Scenario: An invalid answer raises rather than defaulting
  Given the same oracle
  When the provider returns an answer that fails the schema
  Then awaiting raises loudly and no default value is produced

Scenario: The heuristic tier needs no model
  Given a heuristic oracle for the same question
  When it is asked with no provider wired
  Then it returns a validated answer through the identical interface

Scenario: The definition is content-addressed and deterministic
  Given one oracle definition
  When its digest is computed twice
  Then the digests are equal and cover template, schema, and tier
```
→ spec file: `spec/lain/oracle_spec.rb` (+ tier specs)

**Escalation triggers:**
- The template render needs a value the `LockedBinding` allowlist forbids (e.g. a timestamp) — STOP;
  an oracle template must be pure like any slot, redesign the question inputs.
- Awaiting an oracle promise outside an `Async` reactor deadlocks in a spec — confirm the test wraps
  in `Sync`/`Async` as `ask_human` specs do; do not add a thread fallback without escalating.

### T3 — Oracle Journal + replay substitution                      [wave 2] [risk: high]

**Depends on:** T2
**Files:** `lib/lain/oracle/recorded.rb`, `lib/lain/telemetry.rb` (new `OracleAnswer` record), `spec/lain/oracle/recorded_spec.rb`
**Reuse:** `Journal.records(entries, type:)`, the `Effect::Handler::Recorded` loud-miss pattern (`recorded.rb:18`), `Canonical.normalize`, `Bench::DryReplay` byte-diff harness.
**Shared-file wiring:** orchestrator adds the `oracle/recorded` index line to `lib/lain/oracle.rb` (created by T2).

Every oracle call journals `(oracle_digest, question, answer, model, usage, wall_clock)` as an
`OracleAnswer` Journal record (control-flow, not a Store event). `Oracle::Recorded.from_journal`
substitutes recorded answers keyed by `(oracle_digest, question)`; a missing recording **raises**,
never silently re-asks.

**Acceptance criteria:**

```gherkin
Scenario: A recorded oracle answer is substituted on replay
  Given a journal containing an OracleAnswer for a definition+question
  When the same oracle is asked under Oracle::Recorded.from_journal
  Then the recorded answer is returned with no provider call

Scenario: Replaying a session with oracles is byte-identical
  Given a recorded session whose renders were unaffected by oracle output
  When DryReplay re-renders it with oracle substitution active
  Then the requests are byte-identical to the recording

Scenario: A deleted recording fails loudly
  Given a journal with the OracleAnswer removed
  When the oracle is asked under substitution
  Then it raises rather than re-asking the model
```
→ spec file: `spec/lain/oracle/recorded_spec.rb`

**Escalation triggers:**
- Changing an oracle's schema orphans recorded answers keyed by the old definition digest — confirm
  the digest-key makes staleness loud (a raise), not a silent wrong-answer match.
- Adding `OracleAnswer` to `telemetry.rb` collides with T9's `Grade` verdict record in the same file
  — they are different waves; if the orchestrator staged them together, STOP and re-sequence.

### T4 — First two oracles: prune-scoring + memory-save gating      [wave 3] [risk: medium]

**Depends on:** T2, T3
**Files:** `lib/lain/oracle/prune_scoring.rb`, `lib/lain/oracle/memory_save.rb`, `lib/lain/middleware/refuse_secret_writes.rb`, `spec/lain/oracle/prune_scoring_spec.rb`, `spec/lain/oracle/memory_save_spec.rb`, `spec/lain/middleware/refuse_secret_writes_spec.rb`
**Reuse:** T2 seam; `RefuseSecretWrites`'s existing injectable `oracle:` seam (`refuse_secret_writes.rb:67`) and `ORACLE_MATCH` journal tag; both oracles ship a `Heuristic` baseline arm.
**Shared-file wiring:** orchestrator wires the memory-save oracle into `exe/lain`'s `RefuseSecretWrites` construction (one line, replacing `NullOracle`).

Both oracles run **off the hot path** (post-turn / idle), never blocking a turn. Prune-scoring
answers "which spans are stale?" (feeds T18's cold-window work). Memory-save gating answers "worth
remembering?" and plugs the richer typed oracle into `RefuseSecretWrites` — adapting its binary
`#secret?` seam to consult the oracle.

**Acceptance criteria:**

```gherkin
Scenario: Each oracle ships a heuristic baseline
  Given prune-scoring and memory-save oracles
  When each is constructed in its heuristic tier
  Then it scores its input with no model call

Scenario: Memory-save gating refuses through the existing seam
  Given RefuseSecretWrites wired with the memory-save oracle
  When a memory_write the oracle judges unsafe is dispatched
  Then it is refused and journaled, exactly as the regex path is today
  And a write both the regex and the oracle pass proceeds
```
→ spec files: `spec/lain/oracle/{prune_scoring,memory_save}_spec.rb`, `spec/lain/middleware/refuse_secret_writes_spec.rb`

**Escalation triggers:**
- An existing `refuse_secret_writes_spec.rb` example pins the `NullOracle` default behavior — this
  card changes the wired default; update that spec in the same commit or STOP if it asserts a
  contract another card depends on.
- Prune-scoring is tempted onto the render hot path to score live — STOP; the spec mandates
  tail-or-nothing / off-hot-path placement (`oracles.md:29`).

### T5 — Cache-write column in Compare                              [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/compare.rb`, `lib/lain/compare/table.rb`, `spec/lain/compare_spec.rb`
**Reuse:** `Usage#cache_creation_input_tokens` (already recorded + journaled), `Compare::METRICS` (`compare.rb:86`), `Compare::Distribution`.

**Acceptance criteria:**

```gherkin
Scenario: Compare reports cache-write tokens as a distribution
  Given two runs with differing cache_creation_input_tokens
  When Compare reports them
  Then a cache-write column appears with per-run and summary distributions
  And the existing four columns are unchanged
```
→ spec file: `spec/lain/compare_spec.rb`

**Escalation triggers:**
- An existing `compare_spec.rb` example asserts the exact column count/order of the report table —
  update it deliberately; a downstream fixture may pin the rendered report bytes.

### T6 — The decider-locus sweep                                    [wave 4] [risk: medium]

**Depends on:** T4, T5
**Files:** `lib/lain/bench/decider_sweep.rb`, `spec/lain/bench/decider_sweep_spec.rb`, `spec/fixtures/bench/decider/*` (committed fixture inputs)
**Reuse:** T4 prune-scoring oracle (all tiers), `Compare` (with T5's cache-write column), `Bench::Sweep`/`Compare::Table` report shape, `Grader::Fixture`.
**Shared-file wiring:** orchestrator adds a `bench decider-sweep` subcommand line to the bench CLI (`lib/lain/bench/cli.rb`) if the sweep is CLI-exposed.

For the prune-scoring decision point, compare **heuristic vs ollama vs haiku vs inline vs
model-self-directed** arms, scored `grader × tokens × cache-write × wall-clock` as distributions
over committed fixtures (zero network by default; live arms `:vcr`/`:live`-tagged).

**Acceptance criteria:**

```gherkin
Scenario: The sweep ranks decider arms distributionally
  Given committed fixtures for one decision point
  When the decider sweep runs over the arms with recorded answers
  Then it produces a Compare report over grader, tokens, cache-write, and wall-clock
  And the inline arm's cache-write cost is visible, not averaged away
  And the run is byte-identical across repeats
```
→ spec file: `spec/lain/bench/decider_sweep_spec.rb`

**Escalation triggers:**
- The inline arm cannot be scored without polluting the run-under-study's context — confirm the
  sweep isolates each arm's own Timeline; if inline warms its own tail differently, that is the
  finding, not a bug to smooth.
- Wall-clock is unavailable deterministically under `DryReplay` — the sweep must record wall-clock
  only on live/`LiveReplay` arms and mark it absent for dry arms; do not fabricate a constant.

### T7 — OR-6 mechanical combinators                                [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/context/dedupe_tool_calls.rb`, `lib/lain/context/purge_failed_inputs.rb`, `lib/lain/context/protected_patterns.rb`, `spec/lain/context/dedupe_tool_calls_spec.rb`, `spec/lain/context/purge_failed_inputs_spec.rb`, `spec/lain/context/protected_patterns_spec.rb`
**Reuse:** `Context::Combinator` (`context/base.rb`), the `"a monoid"` shared example (`spec/support/shared_examples/monoid.rb` — apply it here, closing the gap that no combinator spec does today), `Prune`/`Compact` as the consumers a shared `ProtectedPatterns` policy exempts.
**Shared-file wiring:** orchestrator adds three index lines to `lib/lain/context.rb`.

`DedupeToolCalls` (same tool + args → keep newest output) and `PurgeFailedInputs(turns:)` (drop
failed calls' inputs after N turns, keep the error text) as pure projections under `>>`.
`ProtectedPatterns` is a shared exempt-span policy consumed by both and available to `Prune`/`Compact`.

**Acceptance criteria:**

```gherkin
Scenario: Dedupe keeps the newest identical tool result
  Given a message list with two identical tool calls and outputs
  When DedupeToolCalls runs
  Then only the newest output remains and the log is untouched (pure projection)

Scenario: Purge drops old failed inputs but keeps the error
  Given a failed tool call older than the turn window
  When PurgeFailedInputs(turns: n) runs
  Then the failed input is dropped and its error text is kept

Scenario: Protected patterns are exempt in every consumer
  Given a span matching a protected pattern
  When DedupeToolCalls, PurgeFailedInputs, Prune, and Compact run
  Then the protected span is never dropped by any of them
```
→ spec files: `spec/lain/context/{dedupe_tool_calls,purge_failed_inputs,protected_patterns}_spec.rb`

**Escalation triggers:**
- Wiring `ProtectedPatterns` into `Prune`/`Compact` changes their existing public constructors — if
  an existing `prune_spec.rb`/`compact_spec.rb` example breaks, the policy must default to
  empty/no-op so current behavior is byte-identical; else STOP.
- Either combinator declares a non-empty `#requires` — these are pure client-side transforms and
  must inherit `[]`; a non-empty requires means the transform is doing something it shouldn't.

### T8 — Shared tool-call/outcome lineage projection                [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/grader/tool_call_index.rb`, `spec/lain/grader/tool_call_index_spec.rb`
**Reuse:** `Journal.records(entries, type: "turn")`, the `Bench::Session::MemoryReplay#outcomes` pairing recipe (`memory_replay.rb:77` — generalize it, do not couple to it), `Event::Projection#causal_closure` (`event/projection.rb:123`), `Timeline#causal_meets`/`#dominator_meet` for lineage keys, `spawned_from` in turn `meta`.
**Shared-file wiring:** orchestrator adds the `grader/tool_call_index` index line to `lib/lain/grader.rb`.

The "build it once" substrate `graders.md:56` names: an offline projection over Journal turn records
yielding `tool_use → outcome` pairs (name, args, is_error, result) indexed by content-addressed
lineage. GR-2 reads selection frequency from it; GR-3 walks outcomes back through lineage.

**Acceptance criteria:**

```gherkin
Scenario: The projection pairs each tool_use with its outcome
  Given journal turn records with tool_use blocks and following tool_result blocks
  When the projection is built
  Then each tool_use is paired with its outcome (name, args, is_error) keyed by turn digest

Scenario: Outcomes are indexed by lineage, not turn ordinal
  Given a fan-out with spawned_from lineage across turns
  When the projection indexes outcomes
  Then an outcome resolves to its causing turn via causal lineage, deterministically
```
→ spec file: `spec/lain/grader/tool_call_index_spec.rb`

**Escalation triggers:**
- No production writer emits standalone `tool_result` records — the projection must extract outcomes
  from turn-record `content` blocks (the `MemoryReplay` recipe), not from a `type:"tool_result"`
  record stream; if a card assumed the latter, STOP.
- A tool called twice in one turn (parallel `parallel_safe?`) yields two `tool_use` blocks with the
  same tool name — confirm pairing keys on `tool_use_id`, not name, so parallel calls don't merge.

### T9 — Two-pass verification wrapper (+ Grade journaling)         [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/grader/verified.rb`, `lib/lain/grader/refuter.rb`, `lib/lain/telemetry.rb` (new `Verdict` record), `spec/lain/grader/verified_spec.rb`, `spec/lain/grader/refuter_spec.rb`
**Reuse:** the `Grader` `#grade → Grade` convention (`grader.rb`), `Grader::Rubric` (the default refuter's separate-context judge), the `Effect::Handler::Recorded` decoration pattern (an `inner` wrapped), `DryReplay` byte-diff for the replay AC.
**Shared-file wiring:** orchestrator adds the `grader/verified`, `grader/refuter` index lines to `lib/lain/grader.rb`.

`Grader::Verified.new(inner:, refuter:)` decorates any finding-producing grader: each raw finding is
put to an **injected refuter** (default `Grader::Refuter` — a Rubric-in-separate-context prompted to
refute); a finding counts only if it survives. Verdicts journal as `Verdict` records so `DryReplay`
reproduces the filtered set. The refuter's injectability is what lets an oracle-backed refuter swap
in later without touching `Verified`.

**Acceptance criteria:**

```gherkin
Scenario: Refutation filters false positives
  Given a grader emitting N raw findings, one of them known-false
  When wrapped in Grader::Verified with a refuter that refutes the false one
  Then it yields fewer than N verified findings, each carrying its refutation verdict

Scenario: Verdicts are journaled and replay reproduces the filtered set
  Given a verified grading whose verdicts were journaled
  When it is replayed under recorded verdicts
  Then the filtered finding set is reproduced byte-identically with no model call
```
→ spec files: `spec/lain/grader/verified_spec.rb`, `spec/lain/grader/refuter_spec.rb`

**Escalation triggers:**
- `Grade` (`grader.rb:15`) has no journaling and is not a `Telemetry` — adding a `Verdict` record must
  not change `Grade`'s frozen shape or its blank-`why` raise; if a spec pins `Grade` equality, STOP.
- The refuter default reaches for the run-under-study's Timeline — it must judge in a **separate**
  context window like `Rubric` (`rubric_spec.rb:32`); sharing context defeats the refutation.

### T10 — Tool-steering detector                                    [wave 2] [risk: low]

**Depends on:** T8
**Files:** `lib/lain/grader/tool_steering.rb`, `spec/lain/grader/tool_steering_spec.rb`, `spec/fixtures/grader/steering/*`
**Reuse:** T8 projection (observed selection frequency), the header record's `"tools"` schema (`session_record.rb:48`) for declared description, `Grade` for the flag output.
**Shared-file wiring:** orchestrator adds the `grader/tool_steering` index line to `lib/lain/grader.rb`.

A pure, deterministic Journal analysis diffing each tool's declared description against its observed
selection frequency; flags tools selected disproportionately to their stated purpose. No model call
for the base heuristic.

**Acceptance criteria:**

```gherkin
Scenario: An over-selected over-claiming tool is flagged
  Given a fixture run where one tool's description over-claims and it wins calls above its share
  When the detector runs
  Then that tool is flagged with its observed-vs-declared ratio

Scenario: A well-behaved toolset produces no flags
  Given a fixture run with proportionate tool selection
  When the detector runs
  Then no tool is flagged, deterministically over committed fixtures
```
→ spec file: `spec/lain/grader/tool_steering_spec.rb`

**Escalation triggers:**
- "Proportionate" needs a baseline expectation the Journal doesn't carry — if the threshold requires
  a declared expected-share the header lacks, confirm the heuristic (relative over-selection) rather
  than inventing an expected distribution; escalate before adding a model pass.

### T11 — Frustration/repair grader with causal attribution         [wave 2] [risk: medium]

**Depends on:** T8
**Files:** `lib/lain/grader/frustration_repair.rb`, `spec/lain/grader/frustration_repair_spec.rb`, `spec/fixtures/grader/frustration/*`
**Reuse:** T8 projection, `Timeline#causal_meets`/`#dominator_meet` (`timeline.rb:153`/`:182`), `spawned_from` turn `meta`, `Grade`. Keep the mechanical signal floor deterministic (regex/loop-detection); gate fuzzy signals behind an (optional, injected) oracle so the grader stays replayable.
**Shared-file wiring:** orchestrator adds the `grader/frustration_repair` index line to `lib/lain/grader.rb`.

Detects behavioral failure signals (rephrase-loops, self-corrections, abandonment) then walks each
**back through the DAG** to the earlier turn that most plausibly caused it — attribution over
content-addressed lineage, not turn-ordinal proximity.

**Acceptance criteria:**

```gherkin
Scenario: A downstream signal is attributed to its upstream cause
  Given a fixture where a tool failure at turn i produces a rephrase-loop at turn i+k
  When the grader runs
  Then it reports the signal at i+k and attributes it to turn i via causal lineage
  And the attribution is deterministic and not merely the nearest prior turn
```
→ spec file: `spec/lain/grader/frustration_repair_spec.rb`

**Escalation triggers:**
- The causal walk resolves to a *set* of maximal ancestors (criss-cross fan-in, `causal_meets`
  returns a set) — the grader must handle a multi-element attribution, not assume a unique cause;
  if a fixture forces a single answer, confirm the expected behavior.
- A behavioral signal needs a model to detect — keep it out of the deterministic floor; put it
  behind the injected oracle or STOP, so the grader stays `DryReplay`-reproducible.

### T12 — Disclosure strategy seam on Toolset                       [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/toolset/disclosure.rb`, `lib/lain/toolset/disclosure/upfront.rb`, `lib/lain/toolset.rb`, `spec/lain/toolset/disclosure_spec.rb`
**Reuse:** `Toolset#to_schema` (`toolset.rb:99`, sorted + `Canonical.normalize`), `Tool#to_schema` (`tool.rb:132`), the capability-attenuation idiom (`only`/`except`).
**Shared-file wiring:** orchestrator adds the `toolset/disclosure` index line to `lib/lain.rb`/`toolset.rb` as the `toolset/` unit dictates.

A `Disclosure` strategy decides how a `Toolset` renders into the Request. `Upfront` (today's full
`to_schema` at position 0) is the default and MUST be byte-identical to current output so the cache
prefix is untouched. The seam lets T13 add a deferred arm without editing `toolset.rb` again.

**Acceptance criteria:**

```gherkin
Scenario: Upfront disclosure is byte-identical to today
  Given a toolset rendered under the Upfront disclosure strategy
  When its schema is produced
  Then the bytes equal today's Toolset#to_schema output exactly

Scenario: The disclosure strategy is a pluggable seam
  Given a toolset and an alternate disclosure strategy
  When the toolset renders under it
  Then rendering routes through the strategy without toolset.rb knowing the arm
```
→ spec file: `spec/lain/toolset/disclosure_spec.rb`

**Escalation triggers:**
- Introducing the strategy changes `Toolset#to_schema`'s call path enough to move bytes for the
  default — STOP; cache stability (`toolset.rb:5`) is non-negotiable, the default must be a pure
  pass-through.

### T13 — Deferred/searchable disclosure arm                        [wave 2] [risk: medium]

**Depends on:** T12
**Files:** `lib/lain/toolset/disclosure/deferred.rb`, `lib/lain/tools/tool_search.rb`, `spec/lain/toolset/disclosure/deferred_spec.rb`, `spec/lain/tools/tool_search_spec.rb`
**Reuse:** T12 seam, `Tool#name`/`#description` for the searchable catalog, `Tool::Input` for `tool_search`'s input, the `Toolset` attenuation model (a disclosed tool is still capability-gated).
**Shared-file wiring:** orchestrator adds `tools/tool_search` to the tools index and (if the arm is wired into a live toolset) one line to `exe/lain`'s `base_tools`.

Deferred disclosure renders only a searchable catalog (name + one-line description) upfront; the full
schema is fetched on demand via a `tool_search`/`describe_tool` tool. Possession still gates
invocation — searching does not grant capability.

**Acceptance criteria:**

```gherkin
Scenario: Deferred disclosure renders a catalog, not full schemas
  Given a toolset under the Deferred disclosure strategy
  When it renders into the request
  Then only names and one-line descriptions appear upfront, not full input schemas

Scenario: tool_search returns a tool's full schema on demand
  Given a deferred toolset containing a tool
  When tool_search is called for that tool's name
  Then its full input schema is returned
  And a tool not in the toolset is not disclosed (capability gating holds)
```
→ spec files: `spec/lain/toolset/disclosure/deferred_spec.rb`, `spec/lain/tools/tool_search_spec.rb`

**Escalation triggers:**
- `tool_search` disclosing a tool the toolset was attenuated away from would leak a dropped
  capability — confirm search is scoped to the *current* attenuated toolset; a leak here breaks
  possession-is-authorization.

### T14 — Tool-disclosure bench sweep                               [wave 3] [risk: low]

**Depends on:** T12, T13
**Files:** `lib/lain/bench/disclosure_sweep.rb`, `spec/lain/bench/disclosure_sweep_spec.rb`, `spec/fixtures/bench/disclosure/*`
**Reuse:** T12/T13 arms, `Compare` (tokens + a correct-call-rate metric via `Grader::Fixture`), `Bench::Sweep`/`Compare::Table` shape.

Compare **upfront vs deferred** on tokens and correct-call rate over a fixture. The **code-API arm is
explicitly out of scope** (needs code mode / exec boundary, M6) and noted as a follow-up so a reader
does not mistake a two-arm sweep for the full three-arm axis.

**Acceptance criteria:**

```gherkin
Scenario: The sweep reports tokens and correct-call rate per disclosure arm
  Given a fixture task scored by a Grader::Fixture
  When the disclosure sweep runs over upfront and deferred
  Then it produces a Compare report over tokens and correct-call rate as distributions
  And the report notes the code-API arm is deferred, not silently omitted
```
→ spec file: `spec/lain/bench/disclosure_sweep_spec.rb`

**Escalation triggers:**
- Silent-truncation trap: if either arm caps or samples tasks, the report must `log` what was
  dropped — a two-arm sweep presented as the whole axis is the anti-pattern; STOP and label.

### T15 — Provider cache profile                                    [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/provider/anthropic.rb`, `lib/lain/provider/ollama.rb`, `lib/lain/status_feed.rb`, `spec/lain/provider/anthropic_spec.rb`, `spec/lain/status_feed_spec.rb`
**Reuse:** `Provider::CAPABILITIES` idiom, `StatusFeed::CACHE_TTL_SECONDS` placeholder (`status_feed.rb:63` — replace it with the profile read), the per-model facts in `cache-aware-compaction.md:18`.
**Shared-file wiring:** orchestrator adds the `#cache_profile` abstract declaration to `provider.rb` (one line); the substantive per-provider bodies are card-owned in `anthropic.rb`/`ollama.rb`.

`Provider#cache_profile → { ttl, min_prefix_tokens, write_multiplier, read_multiplier,
tiered_invalidation }`. Anthropic-Opus reports 5-min sliding TTL + 4096 min-prefix + 1.25×/0.1×;
Ollama reports its own (or a no-caching profile). `StatusFeed` reads the profile instead of the
constant.

**Acceptance criteria:**

```gherkin
Scenario: Anthropic reports its cache profile
  Given Provider::Anthropic on an Opus model
  When cache_profile is read
  Then it reports a 5-minute sliding TTL, a 4096-token minimum prefix, and write/read multipliers

Scenario: StatusFeed derives its cache deadline from the profile
  Given a StatusFeed for a provider
  When it computes the cache deadline
  Then it uses cache_profile.ttl, not the hardcoded 300-second constant
```
→ spec files: `spec/lain/provider/anthropic_spec.rb`, `spec/lain/status_feed_spec.rb`

**Escalation triggers:**
- Removing `CACHE_TTL_SECONDS` breaks a `status_feed_spec.rb` example that pins 300 — update it to
  read from the profile; if another consumer (TTY, `lain up`) reads the constant directly, STOP and
  route it through the profile too.

### T16 — Compaction need-signals + todo-completion seam            [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/compaction.rb`, `lib/lain/compaction/need.rb`, `lib/lain/session.rb`, `lib/lain/tools/todo_write.rb`, `spec/lain/compaction/need_spec.rb`, `spec/lain/tools/todo_write_spec.rb`
**Reuse:** `Context::Compact` (the thing scheduled), `Session#write_todos` (`session.rb:112`), `Tools::TodoWrite` (`todo_write.rb:80`), `Canonical.dump` byte-size (the existing threshold proxy).
**Shared-file wiring:** orchestrator adds the `compaction` unit manifest line to `lib/lain.rb`.

A `Compaction::Need` detector marks "compaction needed" **without executing**, on any of: token
threshold, approaching-window, manual, **plan-step completion**. The last requires a new seam:
`Session`/`TodoWrite` must detect a todo transitioning to `completed` (today the list is a full
overwrite retaining no prior state) and expose a completion signal.

**Acceptance criteria:**

```gherkin
Scenario: Each need-signal raises the flag without compacting
  Given a Compaction::Need detector
  When a token threshold, approaching-window, or manual trigger fires
  Then the need flag is set and no compaction runs

Scenario: A completed todo raises the need flag
  Given a todo list and a subsequent write flipping one item to completed
  When the todo write is applied
  Then a plan-step-completion signal is emitted and the need flag is raised
```
→ spec files: `spec/lain/compaction/need_spec.rb`, `spec/lain/tools/todo_write_spec.rb`

**Escalation triggers:**
- `Session` keeps only the rendered `@todo_reminder` string (`session.rb:114`), not a structured
  prior list — detecting a `completed` transition needs prior structured state; adding it must not
  make `todo_write` append to the Timeline or resurrect todos on rewind (`todo_write` is
  sent-not-stored). If retaining prior state pressures that invariant, STOP.

### T17 — Cache cold detection                                      [wave 2] [risk: medium]

**Depends on:** T15
**Files:** `lib/lain/compaction/cold.rb`, `spec/lain/compaction/cold_spec.rb`
**Reuse:** T15 `cache_profile.ttl`, `StatusFeed`'s `cache_deadline` (`status_feed.rb:111`), `Telemetry::TurnUsage`'s `cache_read_input_tokens` (`telemetry.rb`), Journal `ts` deltas for idle.
**Shared-file wiring:** orchestrator adds the `compaction/cold` index line to `lib/lain/compaction.rb`.

Deem the cache cold when idle > `cache_profile.ttl`; **confirm** via `cache_read_input_tokens == 0`
on the next response; journal the confirmation. A warm hit cancels a pending cold-compaction.

**Acceptance criteria:**

```gherkin
Scenario: Idle beyond TTL marks cold, confirmed by a zero cache-read
  Given a session idle longer than the provider's cache TTL
  When the next response reports cache_read_input_tokens == 0
  Then the scheduler marks the cache cold and journals the confirmation

Scenario: A warm hit cancels a pending cold mark
  Given a pending cold mark
  When a response reports a non-zero cache_read
  Then the cold mark is cancelled
```
→ spec file: `spec/lain/compaction/cold_spec.rb`

**Escalation triggers:**
- OpenAI-compatible providers have no explicit TTL to read — for a provider whose profile lacks a
  TTL, cold detection must fall back to the `cache_read == 0` signal only; do not assume Anthropic
  semantics for all providers.

### T18 — Soft-defer + hard-cap compaction scheduler                [wave 3] [risk: high]

**Depends on:** T16, T17
**Files:** `lib/lain/compaction/scheduler.rb`, `spec/lain/compaction/scheduler_spec.rb`
**Reuse:** T16 need-signals, T17 cold detection, `Context::Compact` (invoked only when scheduled), the `turn` middleware phase (`agent_turn_middleware_spec.rb` shows the seam) as the mount point, `CacheBreakpoints` for the approaching-window / hard-cap awareness.
**Shared-file wiring:** orchestrator mounts the scheduler in `exe/lain`'s turn-middleware stack (one line).

The policy that separates **need** from **when**: while warm and below the hard cap, **defer** (don't
waste the cache); crossing the hard cap or approaching the window **forces** compaction even while
warm — and that forced rewrite hits only the message tier, journaled as "forced-warm, message-tier
only".

**Acceptance criteria:**

```gherkin
Scenario: A needed compaction defers while warm and below cap
  Given compaction is needed, the cache is warm, and history is below the hard cap
  When the scheduler evaluates the turn
  Then compaction does not run

Scenario: Crossing the hard cap forces compaction even while warm
  Given compaction is needed and history crosses the hard cap while warm
  When the scheduler evaluates the turn
  Then compaction runs and the journal notes forced-warm, message-tier only

Scenario: A cold cache runs a needed compaction for free
  Given compaction is needed and the cache is cold
  When the scheduler evaluates the turn
  Then compaction runs
```
→ spec file: `spec/lain/compaction/scheduler_spec.rb`

**Escalation triggers:**
- The scheduler needs to swap the `Compact` combinator into the render pipeline for one turn — it
  must do so without mutating `Context` (renders stay pure); if the only way to run compaction is to
  make the combinator impure, STOP (the spec forbids scheduling inside the pure `#call`).
- An existing gate-7 bounded-loop or turn-middleware spec breaks when the scheduler mounts — the
  scheduler must be a pass-through when compaction is not needed; a behavioral change to
  non-compacting turns is a defect.

### T19 — Prepare-once-apply-on-resume                              [wave 4] [risk: medium]

**Depends on:** T18
**Files:** `lib/lain/compaction/prepared.rb`, `spec/lain/compaction/prepared_spec.rb`
**Reuse:** T18 scheduler seam, `Timeline` head digest (idempotency key), the injected `summarizer` on `Compact` (`compact.rb:35`) — optionally the local-model meta-tier so idle-prepare is cheap and private.
**Shared-file wiring:** none (plugs into T18's scheduler via the seam it left).

On a long idle (cache already cold), compute the compacted summary **once** and hold it keyed on the
timeline head digest; reuse on repeated idle ticks; apply on the next real turn; recompute if the
head advanced. Prevents idle→compact→idle→compact churn.

**Acceptance criteria:**

```gherkin
Scenario: Two idle ticks produce one summarization
  Given a cold, idle session at a fixed timeline head
  When two idle ticks fire with no new turns between them
  Then exactly one summarization call is made and the held result is reused

Scenario: A new turn invalidates the held compaction
  Given a held compaction keyed on a head digest
  When a new turn advances the head, then an idle tick fires
  Then the held compaction is discarded and recomputed
```
→ spec file: `spec/lain/compaction/prepared_spec.rb`

**Escalation triggers:**
- The prepare step itself costs tokens on a session the user never resumes — confirm prepare only
  fires after a *long* idle (or on the local meta-tier); if wired to every idle tick it becomes a
  cost leak, STOP.

### T20 — Compaction journaling                                     [wave 4] [risk: low]

**Depends on:** T18
**Files:** `lib/lain/telemetry.rb` (new `Compaction` record), `lib/lain/compaction/scheduler.rb` (emit), `spec/lain/compaction/journaling_spec.rb`
**Reuse:** `Telemetry`/`Journal` record idiom, `Ledger`/`PriceBook` (cost saved vs spent), `Compare` (attribute cost deltas to the policy).
**Shared-file wiring:** none (T18 owns `scheduler.rb`; this adds the record type + the emit call in a later wave — coordinate with the orchestrator that T18 landed first).

Every compaction records trigger, cache-state (warm/cold/forced), tokens before/after, and cost
saved vs spent, so `Compare` can attribute cost deltas to the scheduling policy.

**Acceptance criteria:**

```gherkin
Scenario: A compaction journals its full accounting
  Given a compaction runs under the scheduler
  When it completes
  Then a journal record carries trigger, cache-state, tokens before/after, and cost saved vs spent
  And Compare can read the cost delta attributed to the policy
```
→ spec file: `spec/lain/compaction/journaling_spec.rb`

**Escalation triggers:**
- Adding a `Compaction` record to `telemetry.rb` after T3's `OracleAnswer` and T9's `Verdict` — all
  three are different waves; if staged together, STOP and sequence, and ensure the NDJSON stays
  one-object-per-line (a stray write corrupts the experiment record).

### T21 — Context render-pipeline injection seam                    [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/context.rb`, `spec/lain/context_spec.rb`
**Reuse:** `Context.pipeline` (`context.rb:46`, the hardcoded `Reminder >> CacheBreakpoints`),
`Context#render` (`context.rb:93`), the `>>` combinator composition, the `Context::REQUIRES`
derivation (`context.rb:56`), the "byte-identical when unused" guard idiom (T1/T12).
**Shared-file wiring:** none — `context.rb` is card-owned by T21 (the sole card editing it this
wave). Downstream (`exe/lain`, T18) constructs a `Context` with a pipeline; that wiring is
orchestrator/T18 concern.

Make the render pipeline an **injected collaborator** rather than a fixed class method. `Context.new`
gains an optional `pipeline:` (a combinator or a `->(workspace)` provider); when omitted, `#render`
falls back to today's `self.class.pipeline(workspace)` so a default `Context` renders
**byte-identical** to current output — the cache prefix must not move. `REQUIRES` must still derive
from whatever pipeline is in effect (declared capabilities cannot drift from behavior). This is the
seam T18 mounts `Compact` through and the point at which T7's OR-6 combinators become live; T21 ships
only the seam, not a scheduler.

**Acceptance criteria:**

```gherkin
Scenario: A default Context renders byte-identically to today
  Given a Context constructed with no pipeline argument
  When it renders a timeline
  Then the Request bytes equal today's Context#render output exactly
  And REQUIRES is unchanged

Scenario: An injected pipeline routes the render
  Given a Context constructed with an alternate combinator pipeline
  When it renders
  Then the message list is produced by the injected pipeline, not the default
  And REQUIRES derives from the injected pipeline's #requires

Scenario: The injected Context stays pure and frozen
  Given a Context with an injected pipeline
  When it is rendered twice with identical inputs
  Then the two Requests are byte-identical
  And Ractor.shareable?(context) holds
```
→ spec file: `spec/lain/context_spec.rb`

**Escalation triggers:**
- The default path's bytes move (any existing `context_spec.rb`, prelude-invariant, or bench-session
  round-trip example) — STOP; byte-identical-when-unused is the non-negotiable guard, the default
  must remain a pure pass-through equal to `Reminder >> CacheBreakpoints`.
- Injecting the pipeline forces `REQUIRES` to become an instance-derived value that some caller reads
  as a class constant — reconcile so declared capabilities still cannot drift; if a caller depends on
  `Context::REQUIRES` being static, route it through the instance `#requires` or STOP.
- An injected `->(workspace)` provider tempts impurity (reads a clock/session) — the pipeline provider
  must be pure like every combinator; if a use-case needs impurity, STOP (it belongs in the scheduler
  above `#render`, not inside it).

## Integration checks

After the last wave:
- `bundle exec rspec` — full suite green (297+ new examples; `:integration`/`:live`/`:vcr` excluded
  by default). `LAIN_INTEGRATION=1 ANTHROPIC_API_KEY=… bundle exec rspec` for any `:live` oracle/rubric
  arms — costs money, synthetic prompts only.
- `bundle exec rubocop -a` clean at default metrics; **no `Metrics/*` loosening** (extract a
  collaborator if a scheduler/oracle trips a limit).
- `cargo test && cargo clippy --all-targets -- -D warnings` — unchanged (no Rust in this chunk;
  confirm nothing regressed).
- `pre-commit run --all-files`.
- Output-discipline spec (`spec/output_discipline_spec.rb`) still green — the new bench sweeps and
  journaling must write to a `Sink`/Journal, never `$stdout`.
- Manual dogfood pass (human): run `bench decider-sweep` over the committed fixtures and read the
  `Compare` report; confirm the cache-write column and inline-arm pollution cost are visible. Run
  the tool-disclosure sweep and confirm the deferred arm's token delta.
- Confirm `Ractor.shareable?` holds for any new deeply-frozen value objects (oracle definitions,
  `Grade`-adjacent records).
