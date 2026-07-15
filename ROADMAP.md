# Lain — ROADMAP

> Lain is an agent harness built as a **study bench**. The agent is the vehicle; the bench is the
> deliverable. Everything here optimizes for making context strategies, tool designs, orchestration
> tactics, and memory/retrieval **swappable, observable, and comparable** — so we can *prove* which
> choice moved the correct-call rate, and transfer that intuition to medical-literature tool-call
> work where correctness cannot be eyeballed.
>
> **Sources of truth.** The approved architecture and its *why* live in
> `~/.claude/plans/jiggly-greeting-avalanche.md`. Exploratory ideas live in `planning/`; grounding
> sources in `references/`. This ROADMAP organizes them into a sequenced plan and folds in the
> 2026 research scan and the TODO.md brainstorm.
>
> **Tags.** `[built]` shipped · `[planned]` committed direction · `[exp]` exploratory / to be
> validated on the bench itself.

---

## Two audiences: the lain dev and the lain user

Lain serves two distinct people, and nearly every item below belongs primarily to one of them:

- **The lain dev** builds and studies the harness. Their *project is Lain itself*; the **bench**
  (M3c — `DryReplay`, graders, `Compare`, the swept axes, the parked GEPA / self-improving loop) is
  *their* cockpit. It measures the harness and is not shipped in the user's hot path.
- **The lain user** is a developer using Lain to work on *some other* codebase (ultimately
  medical-literature tooling). To them Lain is a coding agent: tools, memory, code mode, the
  interface, prompt slots, and graders-as-TDD-gate are *their* features. `.lain/` lives in *their*
  repo; the test harness a grader runs is *their* framework (rspec / pytest / jest / …).

**Lain dogfoods:** the lain dev develops Lain *with* Lain, so the user-facing features are exercised
on the harness's own codebase (its rspec suite, `.lain/slots/` in this repo). The two audiences
converge there — which is how the dev keeps the user's experience honest. Where a spec says "the
project," it means the **lain user's** project unless it is explicitly about building the harness.
Graders are dual-use: for the user they gate task completion; for the dev they score a strategy arm.

## The organizing idea: one seam, many swept axes

`Context#render(timeline, toolset, workspace) → Request` is a **pure** function. Tool design,
context management, and orchestration are three views of it; the provider is a fourth. The bench
holds a task fixed and sweeps **one axis at a time**, scoring distributions over `n` runs. Every
milestone exists to make an axis swappable and measured.

| Axis | Arms to compare | Primary metric |
|---|---|---|
| **Context** | prune / compact / recall placement / IVM combinators / cache-aware compaction / breakpoint placement | grader score vs. tokens; cache-hit; **cache-write** |
| **Tool design (ACI)** | terse vs. verbose vs. guardrailed feedback; tier 1/2/3 | correct-call rate; recovery-from-error |
| **Tool disclosure** | upfront-JSON vs. deferred/searchable vs. code-API | tokens; correct-call rate |
| **Prompt slots** | base template vs. user-filled holes (persona · domain framing · output contract) | correct-call rate; grader; cache-hit |
| **Provider / model** | Anthropic vs. OpenAI-compatible vs. local (ollama) | grader score; cost; latency |
| **Orchestration** | single-thread · orchestrator-worker · **fork-worker** · **cache-sibling fan-out** · dual-ledger · handoff · LATS · MoA · adaptive router · **shared-artifact (CRDT)** | grader; tokens (~15× risk); cache-write; context-loss events |
| **Memory / retrieval** | Manifest · BM25 · Hybrid · Vector · Graph · temporal-KG · content-addressed versioning · structural | recall@k; tokens on recall; abstention |
| **Merge strategy** (concurrent edits) | git 3-way vs. CRDT auto-converge | final grader score; conflict/thrash |

**The bench's first experiment is on itself:** the 2026 literature ("the harness, not the model,
sets the score") is exactly Lain's thesis. Quantifying **harness-induced variance** with byte-diff
replay is a near-term headline result — it needs only measurement + replay (M2 + M3a), not the full
bench.

---

## Event sourcing is the storage spine

If the pure `Context#render` seam above is the **read side**, event sourcing is the **write side** —
and it is what makes the later milestones cohere. State is never mutated; it is a projection over an
**append-only, content-addressed event log.** Lain already is this (turns are events, the `Store` is
the log, `#render` is a projection), and nearly every remaining piece is the same substrate with a
different projection:

| Piece | Event log | Projection / fold |
|---|---|---|
| Timeline | the `Store` (turns) | `Context#render` → the prompt |
| Journal (M2) | NDJSON, append-only | cost/usage reports; resume-as-replay |
| Memory (M5/M6) | content-addressed index | recall (`Hit#why`); "as-of turn N" |
| Orchestration (M5) | attributed events in the `Store` | mailboxes (per-recipient views) |
| Workspace Timeline (M4) | file snapshots | the workspace at a turn; `diverge_at` |
| CRDT collab (M4) | the op-log | the converged document |

Consequences that recur below: **supervision/restart and session-resume are the same "replay to a
checkpoint"**; **compaction, IVM, and mailboxes are all views over a log, never destructive edits**;
and OpenHands' event-store-plus-derived-`View` (`references/oss-inspiration.md`) is external proof the
shape works at scale. This is the through-line for the M5 orchestration model
(`planning/specs/orchestration-model.md`); its foundational **event schema** — a CloudEvents-shaped
envelope + typed payload, direct addressing, a closed kind set, and git-style render (single-parent) +
causal (multi-parent) edges — is in `planning/specs/event-schema.md`, and the log-and-projections
structure it realizes (the 4 kinds, `meet`/`diverge_at` over the DAG, the Rust port) is in
`planning/specs/timeline.md`.

---

## Status

- **M0–M1 — housekeeping + the spine.** `[built]` `Canonical`, content-addressed `Timeline`
  (meet-semilattice property-tested), provider-neutral value objects, `Tool`/`Toolset`,
  `Effect`/`Handler`/`Middleware` monoid, `Provider`, pure `Context#render`,
  `Agent`/`Budget`/`ToolRunner`, `Channel`/`Sink`, `ext/lain` tracing.
- **M1b–M3b — hands, observability, test infra, transport fork.** `[built]`: tools
  (`read_file`/`list_files`/`bash`), `Handler::Approving` + TTY, the NDJSON `Journal` + cost
  accounting, `spec/support` + VCR, and the RubyLLM transport fork with `AnthropicRaw`.
- **M3c — the bench.** `[built]` (this session): `Lain::Algebra` shared law groups, the `Context`
  combinators under `>>`, the `turn`/`repl` middleware phases, `:strict`/`:degrade` capability
  guarding, and `Bench::DryReplay`/`LiveReplay` + `Grader::Fixture`/`Rubric` + `Compare` +
  speculative branching. The committed *core*; the `[exp]`/`[parked]` fold-ins below remain future work.
- **M4-1 — the Rust Timeline.** `[built]` (this session): `Canonical`/`Store`/`Turn`/`Timeline` ported
  to `ext/lain` as `frozen_shareable` `TypedData`, digests byte-identical to the Ruby reference, the
  same shared law groups passing against **both** impls. (M4-2, the Neovim frontend, remains `[planned]`.)
  **Planned:** `planning/specs/rust-findings-resolution.md` — resolve the 2026-07-15 `ext/lain`
  findings (loud walks on corrupt chains, idiomatic errors via thiserror, FFI naming/dedup,
  Digest/Role domain types, edition 2024).

**The bench — the deliverable — now exists.** For the first time the project can *compare strategies*:
`DryReplay` re-renders a recorded Timeline byte-identically under one `Context` and yields a
deterministic diff under another, and `Compare` reports distributions over `n` runs (refusing to
compare mismatched capability-degraded sets). The remaining committed work — the key-gated **P**
cleanup and the **M4-2/M5/M6** bands — is inventoried with acceptance criteria in
[`planning/remaining-work.md`](planning/remaining-work.md); this ROADMAP layers the research- and
TODO-driven `[exp]` ideas on top and sequences them. Suite: **1161 examples, 0 failures; `cargo test` 49** (post chunk-cache-memory-hands, 2026-07-13).

---

## Milestones

Each milestone lists committed deliverables, then the research- and TODO-driven additions folded in.

### M1b — the hands `[built]`
- `Tools::ReadFile`, `Tools::ListFiles` (tier 1, structured, no subprocess); `Tools::Bash` (tier 3,
  `Mixlib::ShellOut`, `live_stdout/stderr` attributed at source).
- `Handler::Approving` gating tier 3; `--yolo` to disable.
- `Frontend::TTY` on the alternate screen; `exe/lain` on Thor.
- README rewrite with topology + data-flow mermaid diagrams; `docs/concurrency.md`.
- **Fold-in:** design `Tools::Bash`'s feedback by SWE-agent **ACI principles** — concise-but-informative
  output, guardrails that hasten recovery `[exp]`. Note that the "bash-without-pipes / allowlist"
  frustration (TODO 55–59) is *resolved later* by code-mode (M5), where a pipeline is a Ruby
  expression of allowlisted capabilities, not a shell string. Tier-3 `bash` is the free-form baseline
  we measure against.
- **Fold-in:** `read_file`/`list_files` reach **ambient, untracked files**, not just git-tracked — a
  named frustration (TODO 113). Tools are capabilities over the *filesystem*, not over the git index.

### M2 — observability & durability `[built]`
- `Journal` as NDJSON on its own fd (never stderr), synchronous, lossless.
- Per-turn usage and dollar cost, **aggregated over unique digests**. `Handler::Recorded`. Channel
  split to drop-oldest for the frontend. Rust `tracing` spans merge into the same stream.
- **Prioritization:** token cost is the **80%-of-variance performance proxy** (Anthropic) — invest
  here; it de-risks every later experiment. *Measurement lands before the seams.*
- **Fold-in:**
  - **Resume-after-crash as a property, not a feature** (TODO 3): resume = replay the Journal to the
    last durable content-addressed digest `[exp]`.
  - **Semantic breakpoints as debug middleware** and a `wtf?` REPL groundwork (TODO 50–54) — hooks are
    middleware, so a breakpoint is a middleware that yields to a REPL `[exp]`. See "The DSL".

### M3a — test infrastructure `[built]`
- `spec/support` glob; VCR with safe defaults (network blocked, `record: :none`, `LAIN_RECORD=1` to
  record); cassettes under `spec/fixtures/vcr_cassettes/`; shared example groups for provider parity
  and monoid laws. Lands first — the transport fork is a test-driven port.

### M3b — transport fork `[built]`
- Vendor the RubyLLM slice into `lib/lain/provider/http/` with provenance; their 5 non-VCR unit specs
  must pass unchanged; bootstrap their anthropic cassettes.
- Mutate red-green: `parse_completion_response` stops flattening; `Message`/`Content` → `Lain::Response`;
  retry journaling; Faraday logger → `Sink`. Differential-test `AnthropicRaw` vs. the SDK oracle.
- Adopt `state_machines` for the Agent (illegal transitions checked; `before_transition` → Journal).
- **Fold-in:** add a **local-model provider arm** (ollama) to the provider axis `[exp]` — cheap,
  private meta-tasks (memory-save gating, query sanitization, prune-scoring, and local **autocomplete /
  interactive prompting**) that keep PHI off the wire (TODO 31–33). The **harness-variance experiment** can run as soon as this + M2 + M3a exist. These meta-tasks are now formalized as the
  **oracle seam** — `planning/specs/oracles.md` (OR-1). **Planned:**
  `planning/specs/code-review-ollama-test-infra.md` — native-API `Provider::Ollama` (qwen3
  default, temp-0/seeded determinism arm), resolution of the 2026-07-14 code-review comments,
  and the matcher/test-infrastructure upgrade.

### M3c — the bench: algebra, seams, graders `[built]` — *the center of gravity*
> **Committed core `[built]` (this session):** the combinators, all four phases, capability guarding,
> and the full `Bench`/`Grader`/`Compare` + speculative-branching surface. The fold-ins below remain
> `[exp]`/`[parked]`. ~~Known follow-up: `Agent::Accounting`~~ — **built**; usage is journaled per
> turn and `Ledger`/`Compare` price from the Journal, not `turn.meta`. CE-1/CE-2/CE-3 and
> `Bench::Rewrites` landed in chunk-cache-memory-hands (2026-07-13).
- `[built]` `Lain::Algebra` with property-tested laws. `Context` combinators composing under `>>`, each
  declaring `requires`. All four middleware phases (`model`/`tool`/`turn`/`repl`).
- `[built]` `Bench::DryReplay`, `LiveReplay`, `Grader::Fixture`, `Grader::Rubric`, `Compare` with
  distributions and capability-set guarding.
- **Fold-ins (this is where most new work lands):**
  - **Tool-disclosure axis** promoted here from M5 — pure `Context`/`Toolset` work, no exec boundary
    needed; likely the highest-leverage cheap change `[exp]`.
  - **GEPA-style optimizer** over tool descriptions / prompt slots — turns the bench from a ruler into
    a *search* (metric = grader, textual feedback = Journal, cheap eval = dry replay). **Parked** (a
    lain-dev tool; land the bench and run strategies by hand first — see the self-improving harness in
    `first-class-concepts.md`). `[exp · parked]`
  - **Cache-aware compaction scheduling** (TODO 4): a scheduling policy on `Compact` (3c-2.3) — run
    only when the cache is already cold (idle > the model's *sliding* TTL, confirmed by
    `cache_read_input_tokens == 0`), with soft-defer + hard-cap while warm, plan-step completion as a
    trigger, and prepare-once-apply-on-resume for idle. Compaction rewrites only the *message* cache
    tier, so the forced-warm penalty is bounded. **Spec:** `planning/specs/cache-aware-compaction.md`. `[exp]`
  - **Cache economics** (HN 48883275 + `references/prompt-caching-mechanics.md`): cache-**write**
    attribution via a per-breakpoint **Request digest chain** journaled per call (rewrite count +
    depth + the turn that broke the prefix — `diverge_at` at the request level, CE-2); the
    **byte-identical-prelude invariant spec** (two processes, same bytes — `Canonical`'s second
    invariant finally tested, CE-3); **`lain bench prelude`** — the exact prompt decomposition by
    pipeline stage, no proxy, plus the follow-on budget lint (CE-7); price-model honesty — fresh
    `DEFAULTS`, TTL-aware write rate when a TTL arm exists, wall-clock $/sec in `Compare` (CE-6).
    Prelude size alone is an anti-metric — always grader × tokens × cache-write.
    **Spec:** `planning/specs/cache-economics.md`. `[exp]` (CE-1, the breakpoint-cap **bug fix**, is
    in the near-term sequence, not here.)
  - **Plan-shaped compaction**: compaction seams as **explicit, author-editable plan content**
    with per-chunk size estimates (annotations first, Journal-calibrated later) — the seam
    schedule makes compact/don't-compact a computable EV decision (rewrite cost vs
    estimated-turns-remaining × tokens removed). Execution shape at a seam is a **swept policy**,
    not doctrine: linear+rewrite vs **fork-per-step** (append-only mainline of step-closure
    records — appends never invalidate, so zero mainline cache churn, provable via CE-2) vs
    hybrids. Closure records are mostly **deterministic** (step id, criteria pass/fail via GG,
    diff digests, elided-span digests — attested, nothing lost) and **eager unit summaries**
    (PC-7: ollama one-shots fired concurrently as large tool results land, keyed by source
    digest so they never go stale) make seam-time compaction an assembly step, not a 1-minute
    stall. `cache-aware-compaction.md` remains the reactive fallback + hard-cap safety net.
    **Spec:** `planning/specs/plan-shaped-compaction.md`. `[exp]`
  - **Oracles — cheap one-shot deciders** (haiku / ollama / heuristic behind the `ask_human`
    promise seam): typed, content-addressed micro-decisions (prune-scoring, memory-save gating,
    spawn-time routing) that never render into the main conversation — tail-or-nothing placement,
    structure only at spawn, every Q&A journaled so `DryReplay` substitutes recorded answers
    (the same machinery as recorded human replies). The **decider-locus sweep** (heuristic vs
    ollama vs haiku vs inline vs model-self-directed à la DCP's `compress` tool) is the headline
    experiment: "when does a cheap gating model beat a regex," scored grader × tokens ×
    cache-write × wall-clock. Also adopts DCP's mechanical combinators — dedupe-identical-calls,
    purge-failed-inputs-keep-error, shared protected-pins policy (OR-6).
    **Spec:** `planning/specs/oracles.md`. `[exp]`
  - **Context-as-IVM — a lens, not a unit:** treat the 3c-2 combinators as incremental view
    maintenance over the append-only log (implementation guidance for `Prune`/`Compact`/
    `CacheBreakpoints`/`Recall`, seeded by OpenHands' **nine condenser strategies**), not a separate
    deliverable. `[exp]`
  - **Attested-context combinator** + a grader that verifies every fact traces to a `tool_result`
    digest (hallucination becomes structurally detectable) `[exp]`.
  - **Start the memory sweep with `Manifest`** the moment the bench exists — no index, cache-stable.
  - **Pluggable prompt slots** — named holes the user fills with **markdown partials** (Rails-view-
    partial model) for durable, rarely-changed **freeform system-prompt adjustment** and **per-role
    behavior** (test-engineer / orchestrator). Fills live at `.lain/slots/<name>.md`, rendered via ERB
    in a **purity-enforcing locked binding** (impurity fails loudly), output content-addressed with
    slot digests journaled; rare mutation keeps them cache-safe in the prefix. CLI transparency now,
    Neovim-annotated in M4. **Spec:** `planning/specs/prompt-slots.md`. `[exp]`
  - **The experiment DSL** (RSpec/`factory_bot`-style) as the interface to `Bench`/`Compare` — a
    lain-dev tool, **parked** for now (design sketch in "The DSL" below); the bench works without it.
    `[exp · parked]`
  - **User-injectable middleware** (TODO 44): users add their own `model`/`tool`/`turn`/`repl`
    middleware into the stack via the DSL — a testable hook *is* middleware `[exp]`.
  - **Grader from Gherkin** (TODO 82–85): `/research` + `/plan` produce human-approved Given/When/Then
    acceptance criteria — a transient structured-English **IR**, not `.feature` files — that the
    test-engineer role (M5) turns into tests in the **lain user's** framework (rspec/pytest/jest/…);
    those tests *are* the `Grader::Fixture`. **Spec:** `planning/specs/grader-from-gherkin.md`. `[exp]`

### M4 — Rust timeline, Neovim, and time-travel `[planned]` (4-1 `[built]`)
- `[built]` (M4-1) Persistent Merkle DAG behind the existing interface; the same property tests pass
  unchanged, against **both** the Ruby and Rust impls. Cache-break localization. Speculative branching.
  In `ext/lain`, `frozen_shareable`, digests byte-identical to the Ruby reference.
- `[planned]` (M4-2) Neovim frontend with the **editable `lain://request` buffer** (edit it,
  `:LainResend`, watch what changes).
- **Fold-ins:**
  - **The Workspace Timeline** (Ruby-first, could precede M4): a second content-addressed DAG of file
    snapshots paired with the conversation DAG — independent rewind of files vs. conversation, and it
    couples to `Handler::Approving` (cheap rollback makes `--yolo` safe) `[exp]`. From Cline.
  - **Attention-following context** (TODO 17–21): the human's Neovim quickfix/marks/jump-history/
    registers as a live relevance signal (Aider-style ranking personalized to *live attention*).
    Editor state is **Workspace-shaped**: sent-not-stored, rendered after the last cache breakpoint
    (it changes every turn), snapshotted in ONE `nvim_exec_lua` batch, and journaled with the
    Request so `DryReplay` can reproduce the turn. A swept axis (none / quickfix-only / full /
    recency-scored), not a feature. Registers are a secret-leak surface: conservative allowlist,
    byte caps, opt-in. See `planning/interface-integration.md`. `[exp]`
  - **Plan-iteration as a diff-driven review + CRDT collab-buffer** (TODO 34–42): plans are templates
    with named **`COMMENT` annotation slots** the human fills — the plan-side twin of the prompt-slots
    arm — and the diff + those inline comments drive the next agent action; human and planner co-edit
    live `[exp]`. See `planning/crdt-exploration.md`.
  - **Aider's repo-map** (tree-sitter + PageRank) as a `Context` combinator `[exp]`.
  - **Full-prompt transparency** in the `lain://request` buffer: render the *whole* prompt with slot
    boundaries and **cache breakpoints annotated** (holes above the cache line = expensive to change;
    holes in the uncached tail = cheap), shown as a **diff against the base template**. Disclosing the
    harness, made visible — the inspection half of the prompt-slots arm. `[exp]`

### M5 — orchestration, memory, code mode `[planned]`
- `Tool::Subagent` (async, attenuated, supervised). `Tool::Todo`. `Memory` (content-addressed,
  `Manifest` + `Bm25`), `Context::Recall` after the last cache breakpoint. Server-side context editing
  as a comparison arm. Structured `edit_file` (`str_replace` + read-before-write). Choose the
  concurrency model. **Code mode** — `eval_ruby` against a persistent binding.
- **Fold-ins:**
  - **Event-sourced orchestration** (TODO 27–30): fibers (`Async` / socketry); the Store is the event
    log and mailboxes are projections over it; `ask_human` returns a **promise** (continue working,
    block only when the answer is actually needed); **one-shot *and* long-lived actor** subagent modes;
    supervision = replay-to-checkpoint (the same machinery as M2 resume). A whole team's run is
    forkable/replayable — you can *substitute a model for the human* from recorded replies for offline
    evaluation. **Spec:** `planning/specs/orchestration-model.md`. `[exp]`
  - **Supervision trees + checkpoint restart** (TODO 27 + 3): the orchestrator is a supervisor; a
    crashed subagent restarts from its last content-addressed checkpoint (Workspace Timeline) `[exp]`.
  - **Meta-agents that study the harness** (TODO 94–100): the **court-clerk** (records memories from
    subagent timelines = the "dreams"/consolidation pattern, auditable because content-addressed) and
    the **friction-observer** (watches the Journal for harness friction, emits *experiment proposals*
    into the GEPA loop → a **self-improving harness**) `[exp]`.
  - **Spawn prefix strategy as an axis** (CE-4): fresh-root | fork-the-parent | sibling-template is
    a policy object at the spawn seam, **orthogonal to** the one-shot/actor lifecycle axis — the
    current fresh-root rule becomes the default arm, not an architectural constant. Enables
    **fork-worker** (the HN thread's unresolved argument, answerable only by a bench) and
    **cache-sibling fan-out** (1 template write + N−1 reads; needs `stream_started` on the Channel
    for stagger scheduling, CE-5). The **attenuation ↔ position-0 decision** (per-role schemas
    forfeit sibling sharing; Handler-level enforcement over a union schema preserves it) must be
    made before OM-5 code exists — see both specs' open questions. `[exp]`
  - **Orchestration arms** (see `planning/orchestration-experiments.md`): single-thread ·
    orchestrator-worker · fork-worker · cache-sibling fan-out · dual-ledger (Magentic-One) · handoff ·
    LATS · MoA · adaptive router · shared-artifact (CRDT). Build the *comparison* before the fleet;
    each worker is worktree-isolated, and where tests collide (ports, DBs) they get a container or a
    separate DB schema (TODO 71–73).
  - **Code mode subsumes bash pipelines**, and **handles to out-of-context data** let the agent
    orchestrate computations over corpora it never loads (the medical-corpus unlock; smolagents'
    `PythonExecutor` ABC + state-dict-with-subagents-as-callables is the reference) `[exp]`.
  - **git-for-its-mind** tools (`fork_and_try`, `rewind_to`, `diff_branches`) `[exp]`; the
    **self-crystallizing toolset** (promote successful code-mode fragments to versioned capabilities,
    TODO 104) `[exp]`.
  - **Agent role catalog** — orchestration roles are **attenuated subagents** (capabilities, not
    config), each `toolset.only(...)` + a role prompt slot: a **dev**; a **test-engineer** authoring
    Gherkin acceptance criteria that become `Grader::Fixture`s (TODO 82–85); specialized **reviewers**
    — SRE/perf, DBA/migrations, security/devops, dovetailing the `security-review` skill (TODO 86–90);
    a **researcher** (TODO 60); plus the **court-clerk** and **friction-observer** above. The
    orchestrator fans out to, and merges, whichever roles the task structure calls for. **Built-in
    catalog + `.lain/slots/role/<name>.md` overrides (PS-3); user-defined roles are a longer-term
    goal.** See `planning/specs/orchestration-model.md`. `[exp]`

### M6 — Rust round two & the retrieval sweep `[planned]`
- Exec-boundary hardening, parallel tools, one Rust-implemented `Tool`. `Vector`, `Hybrid`, `Graph`,
  then **sweep all retrieval strategies** through the bench (recall@k, tokens on recall, cache-hit,
  grader) as distributions.
- **Fold-ins (grounded in `references/memory-and-retrieval.md`):**
  - Grade on **LongMemEval** abilities + **ConvoMem** abstention + **MemBench** capacity; the arms to
    beat are **Zep**'s and MemPalace's temporal KGs vs. Lain's content-addressed versioning on the
    `knowledge-updates` split.
  - Adopt MemPalace's borrowable designs: the **AAAK symbolic index** as `Manifest`, the
    **"signal-not-gate"** retrieval-safety invariant, the **query sanitizer** (a contaminated query is
    a silent recall cliff), candidate-local **BM25 reranking**.
  - **Structural memory** (`petgraph` subgraph-isomorphism): recall by trajectory *shape* — a fifth
    modality BM25/Vector/Hybrid/Graph can't express `[exp]`.
  - **git-blame as attested, causal context** (TODO 22–26): code carries its commit lineage; git log
    as a procedural-memory corpus; **commit summaries pre-computed and keyed by SHA** as a lazy,
    expand-on-demand context artifact for the planner/debugger `[exp]`.

---

## Research tracks — first-class concepts

Parallel to the milestones. These are *nouns* the substrate makes possible (see
`planning/first-class-concepts.md` and `planning/crdt-exploration.md`). Most can be de-risked in
Ruby before any Rust.

| Concept | Sparked by | Home | Ruby-first? |
|---|---|---|---|
| Context as **incremental view maintenance** | the monoid + persistent structures | M3c | ✅ |
| **Handles** to out-of-context data (code-mode) | code mode + `lain-core` | M5 | partly |
| **Workspace Timeline** (files as a 2nd DAG) | Cline checkpoints | M4 | ✅ |
| **git-for-its-mind** (fork/rewind as agent tools) | O(1) fork + TODO time-travel | M4/M5 | ✅ |
| **Attested context** (digest-chain provenance) | git-archaeology (TODO 22–26) | M3c/M5 | ✅ |
| **Structural memory** (recall by shape) | TODO archaeology + `petgraph` | M6 | partly |
| **Self-crystallizing toolset** | promote ad-hoc scripts (TODO 104) | M5 | ✅ |
| **Message-DAG orchestration** (human as agent) | TODO 27–30 | M5 | ✅ |
| **Self-improving harness** (friction-observer → GEPA) | TODO 96–100 | M3c→M6 | ✅ |
| **Cache-aware compaction** | TODO 4 | M3c | ✅ |
| **Cache economics** (write attribution · digest chain · spawn prefix axis) | HN 48883275 + caching mental model | M3c/M5 | ✅ |
| **Oracles** (one-shot deciders behind the `ask_human` promise seam) | TODO 31–33 + DCP review | M3c/M5 | ✅ |
| **Plan-shaped compaction** (seams as plan content · fork-per-step · eager unit summaries) | 2026-07-13 interview | M3c/M4/M5 | ✅ |
| **Shared-artifact editing** (CRDT blackboard) | TODO 27 + CRDT | M5/M4 | partly |

---

## The DSL — RSpec / factory_bot for the bench

> **Parked `[exp]` — a lain-dev tool.** This is a design sketch, not near-term scope; the bench (M3c)
> works without it. Kept here because it's the intended shape for defining experiments once the bench
> exists.

Ruby's DSL flexibility (block `instance_eval`, `method_missing`, trait builders) is the natural
interface to a study bench. `RSpec` and `factory_bot` are the models: **experiments read
declaratively, arms are traits, and the whole thing is diffable.** `[exp]`

An experiment is a swept axis with graded arms over distributions:

```ruby
Lain.experiment "tool description raises correct-call rate" do
  suite   :medical_extraction            # a Grader::Fixture
  runs    20                             # distributions, never single-run

  arm(:terse)   { toolset.describe(:search, TERSE) }
  arm(:verbose) { toolset.describe(:search, VERBOSE) }
  arm(:aci)     { toolset.describe(:search, ACI) }   # SWE-agent principles

  grade   :rubric, criteria: CRITERIA    # LLM judge in a separate context window
  compare :correct_call_rate, :tokens, :cache_hit
end
```

Toolsets and contexts are `factory_bot`-style factories with traits (capabilities attenuated by
trait, exactly as the plan wants):

```ruby
Lain.factory :toolset do
  tool :read_file
  tool :grep
  trait(:readonly)  { attenuate_to :read_file, :grep }
  trait(:with_bash) { tool :bash, tier: 3, gate: :approving }
end
```

Prompts are templates with named **holes** the user fills — a base layout, per-slot overrides, and the
whole thing content-addressed so `Compare` can diff two runs' prompts and refuse to compare across
different fills:

```ruby
Lain.prompt do
  slot :persona                          # Lain ships a default; the user overrides it
  slot :domain_framing, cache: :prefix   # above the cache line — expensive to change
  slot :output_contract, cache: :tail    # uncached suffix — cheap to change
  # holes render in a locked, pure binding: only content-addressed locals in scope
end
```

Orchestration topologies and hooks/middleware are declared the same way — which makes the TODO
"tool-call hooks are middleware, and middleware gets tested" (43–47) literal:

```ruby
Lain.orchestration :dual_ledger do        # Magentic-One arm
  lead    model: :opus
  workers 3, model: :sonnet, isolate: :worktree
  on_stall :replan
end

Lain.hook :model do |req, &downstream|    # a testable middleware
  break_here if req.cost > budget.ceiling  # semantic breakpoint → REPL
  downstream.(req)
end
```

And `wtf?` is the REPL primitive (TODO 52): print the current turn digest, cache status, spend, live
subagents, pending effects — then `fork` from the prompt to try a counterfactual. It's `rdbg` for the
agent loop, expressed in the same DSL.

> The payoff: an experiment definition *is* the record of what was swept. Because it's declarative and
> content-addressed alongside the run, `Compare` can refuse to compare two experiments whose swept
> axes or capability sets differ — no accidental apples-to-oranges.

---

## Interface & UX

Two frontends, one Journal — the agent knows about neither; both subscribe. TTY first (M1b), Neovim
next (M4). The window layer is a multiplexer concern; the editing surface is Neovim's; the transport is
the *same* msgpack-RPC that talks to `lain-core` — one idiom, two peers. The 2026-07-11 survey of the
actual desktop configs, the verified RPC probe, and the fleshed-out designs live in
`planning/interface-integration.md`.

**Window topology — xmonad / tmux / iTerm2** `[planned]` (TODO 7–16)
- The `lain` TTY process **owns the loop** and runs on the alternate screen (`smcup`/`rmcup`) so chat
  state stays separate from REPL scrollback — window 1.
- `nvim --listen` runs in its own window / pane, attached via `Neovim.attach_unix` — window 2. Lain
  prefers **attaching to the already-running editor** (a deterministic socket convention, e.g.
  `.lain/nvim.sock`) and spawns its own only as fallback — attention-following context needs the
  *real* editor.
- **Subagents get their own panes** — **decided (2026-07-11): tmux-native placement**, not
  xmonad-native. Panes/windows are programmatic (`split-window`, ids lain can track and kill),
  survive detach, tmux-resurrect can restore them, and iTerm2's `tmux -CC` renders the same session
  natively on macOS — one mechanism, both platforms. xmonad supplies the *outer* topology (chat
  monitor vs. editor monitor) with zero config changes. A `lain up` layout script sets per-session
  pane titles/options so the global tmux.conf is untouched. **Pane cwd = the agent's worktree**
  (TODO 71–73): spawn with `split-window -c <worktree>`, title `role@branch` — switching panes *is*
  switching isolated checkouts `[exp]`.
- **Idle detection is an interface signal** (TODO 4–6): the cache-aware compaction policy (M3c
  fold-in) needs to know "the human walked away" — tmux `client_activity`, `focus-events` (already
  on in the dotfiles), nvim `FocusLost`, and time-at-prompt are the sensors; the interface layer
  reports idleness, the `Compact` scheduling policy decides `[exp]`.
- **Segregate the prompting area from the Ruby REPL** (irb/pry/`rdbg`) — chat input and the live-Ruby
  console are distinct panes, never one interleaved stream.
- **Crash-resume ↔ tmux-resurrect**: design `lain chat --resume` idempotent-by-default so
  `@resurrect-processes 'lain'` revives the bench after a reboot (TODO 3) `[exp]`.

**Neovim buffer surface** `[exp]` (plan Interface §; TODO 41–42)
- `lain://timeline` (the DAG) · `lain://request` (**editable** — `:LainResend`) · `lain://workspace` ·
  `lain://diff`. The **cache-annotated full-prompt transparency view** (prompt-slots arm) renders here.
- Markdown-rendered planning docs with inline annotation → the diff-driven plan-iteration loop
  (`planning/crdt-exploration.md` for the co-editing substrate).
- **Mermaid renders inline via `snacks.image`, pending a terminal switch.** snacks.nvim (installed)
  converts ```mermaid``` blocks itself (`mmdc` + ImageMagick) and draws them in-buffer over the kitty
  graphics protocol, auto-enabling tmux passthrough — but official alacritty ships no graphics
  protocol, so this requires moving to kitty (leaned; reference implementation, zen-mode already has
  a kitty block) or ghostty. Knock-ons: `myTerminal` in xmonad.hs, `--class` spawn flags. On macOS,
  iTerm2 now implements the kitty protocol too — test with snacks' `SNACKS_*` detection override; if
  it holds, the Mac keeps `tmux -CC` *and* gets inline images.
  `markdown-preview.nvim` (bundles mermaid.js, scroll-synced) stays as the full-page review surface
  lain can trigger on `:LainPlan`. GitHub renders the same blocks once committed — one diagram
  source. Details: `planning/interface-integration.md` § Markdown & mermaid.

**Interactive debugging** `[exp]` (TODO 11, 53)
- `nvim-dap` over the interactive Ruby session; `rdbg --open` steps the agent loop from a third pane,
  whichever frontend is running. The dotfiles' dap config already has an attach-to-rdbg entry; align
  its transport (TCP port vs. rdbg's default unix socket) with how lain starts `rdbg`. `wtf?` (see
  the DSL) is the fast-path REPL introspection.

**Neovim-as-automation** `[exp]` (TODO 13–15, 48–49)
- Editor operations tier like any other capability. **Tier 1**: state snapshot, point-reads, and the
  inverse direction — lain *pushes* a quickfix list (`setqflist`) so "the 14 call sites I'm about to
  change" lands in the human's native review idiom. **Tier 2 allowlisted**: project-wide
  search-replace as `setqflist` + `cfdo s/…/… | update`, macro playback over a range, and **LSP
  through the user's already-running servers** (`vim.lsp.buf.rename`, references, diagnostics) —
  semantic refactors with zero lain-owned LSP processes. **Tier 3**: free-form `nvim_command` /
  `exec_lua` is shell-equivalent (`:!`, `system()` reachable) and gates like `Tools::Bash`.
- Coherence rules: when a buffer is loaded *and modified*, tool reads route through the buffer and
  writes go through buffer + `:update` (git checkpoints see disk); the agent never uses
  `nvim_input`/`feedkeys` (races the human) — only `nvim_buf_*` by id; one tool call = one undo block.

**The human is an actor — inbox, notifications, escalation** `[exp]` (TODO 29–30, 74–80, 101–103)
- The event-sourced orchestration fold-in (M5) already makes mailboxes projections over the Store and
  `ask_human` a promise; this is its **interface half**. The human's inbox is a queue they drain on
  their own schedule — never a modal prompt, since agents keep working until the answer is actually
  needed. Arrivals surface three ways, all from one notification middleware on the Channel: a dunst
  `notify-send` when the lain window is unfocused (an existing dotfile habit), a tmux status-line
  flag/count, and the queue itself rendered as `lain://inbox` (or a TTY view). Orchestrator
  escalations (TODO 74–80) are inbox items with an urgency field, not interrupts.

**Prompting-area autocomplete** `[exp]` (TODO 31)
- The ollama meta-task arm (M3b fold-in) names "local autocomplete / interactive prompting" but not
  its surface. Near-term: Reline's `completion_proc` (history, slot names, `@file` paths) — no ghost
  text in reline. The fuller answer is an nvim `buftype=prompt` buffer as an **alternate chat-input
  arm** — extmark ghost text works there, and the Frontend seam already makes input sources
  swappable.

**Line editors — one inputrc, four surfaces** (verified 2026-07-11)
- The chat prompt, irb, and rdbg are all **Reline**; the bash pane is GNU readline; all four read
  `~/.inputrc`. reline 0.6.3 supports the exact directives the dotfiles' *dropped* inputrc used
  (`editing-mode vi`, `show-mode-in-prompt`, vi mode strings) — restoring that one file makes every
  text-entry pane vi-mode with a visible mode indicator. `~/.editrc` is libedit = psql only.
  `Frontend::TTY#prompt` should adopt **`Reline.readmultiline`** (irb's own mechanism) — multiline
  input via termination block, demoting shift-enter/CSI-u to optional polish.
  Details: `planning/interface-integration.md` § Line editors.

**Approved interface experiments** `[exp]` (proposed & accepted 2026-07-11; feasibility notes with
verified machine checks in `planning/interface-integration.md` § Approved experiments)
- **One state feed, three renderers — tmux status primary**: cache warmth (last-request time vs.
  sliding TTL), fleet state, inbox count — published once by a Journal/Channel subscriber. The
  **tmux status line is the persistent HUD** (visible from every pane; session-scoped options so the
  global theme is untouched) with `monitor-bell` window flags; the TTY prompt shows a per-prompt
  snapshot (reline can't refresh mid-wait); an nvim lualine component reading `vim.g.lain_state` is
  optional enrichment, only visible when the editor pane is focused. Making cache economics
  *visible at the moment of typing* is the point.
- **Time-travel as editor motion**: in `lain://timeline`, cursor motion over a turn re-renders
  `lain://request`/`lain://diff` at that digest — scrubbing the session; `:LainFork` at the cursor
  opens a speculative branch. The human UI for `fork_and_try`/`rewind_to`/`diverge_at`; only a
  content-addressed timeline can do this.
- **Approvals in editor idioms**: the pending tier-3 queue as a list buffer (`<CR>` approve, `dd`
  deny, visual-select batch) and `dunstify --action` approve/deny buttons on notifications — both
  are views over `Handler::Approving`'s queue, no new authority.
- **Human attention as a Journal stream** (opt-in): journal focus changes, idle gaps, and
  interventions as attributed interface events — the friction-observer correlates "human stepped
  in" with what the harness was doing, and replay reconstructs what the human was watching.
  Privacy-sensitive: opt-in, loudly flagged in the Journal.
- **Bench reports through the same pipeline**: `Compare` emits markdown + mermaid rendered by the
  snacks.image inline path — the experiment record read in the surface you work in, and an
  immediate dogfood of the mermaid decision.

**Config isolation — whose init.lua** (decided 2026-07-11)
- The **human's editor** runs their full personal config, always; lain's footprint is
  injection-at-attach (`nvim_exec_lua` bootstraps `vim.g.lain_chan`, `:Lain*` commands, `lain://`
  autocmds from lua shipped **in the gem**) so nothing lain depends on lives in dotfiles and version
  skew is impossible. **Headless automation / bench-replayed** nvim spawns `--clean -u <gem's
  init.lua>` — deterministic, plugin-free, `NVIM_APPNAME` rejected (a parallel profile that still
  drifts). Injected commands are namespaced, idempotent on re-attach, and version-handshaked.

**XDG conformance** `[planned]` (added 2026-07-11)
- Lain the CLI is an XDG Base Directory citizen: user config in `$XDG_CONFIG_HOME/lain/`, caches in
  `$XDG_CACHE_HOME/lain/`, durable state (reline history, session index) in `$XDG_STATE_HOME/lain/`,
  sockets and other ephemera in `$XDG_RUNTIME_DIR/lain/` (the nvim socket convention already assumes
  this; fall back to `/tmp/lain` when unset). Project-scoped `.lain/` is like `.git/` — a project
  artifact, not an XDG concern. Nothing lain-related ever lands as a bare `$HOME` dotfile.

**Onboarding — interview the user** `[exp]` (TODO 107–109)
- A first-run interview elicits the user's habits, domain, and working preferences, and **populates
  the `persona` / preferences prompt slot** (the prompt-slots arm) — so personalization is a
  content-addressed slot, not scattered config, and it becomes a swept axis like any other. MemPalace's
  `onboarding.py` is a reference.

> ✅ **Verified 2026-07-11** (probe: `planning/rpc_direction_probe.rb`, nvim 0.12.3 + neovim gem
> 0.10.0): a `Neovim.attach_unix` client **can serve inbound `rpcrequest`** — no `jobstart` host
> needed. `session.run` surfaces `Message::Request`; answer via `session.respond(id, value)`. Gem
> traps, all load-bearing: writes **flush only on the loop's next read** (never
> respond-then-shutdown); `Message::Request` has no `#respond`; `session.run` blocks its thread; and
> `Session#main_thread_only` **raises off-thread**, so `Frontend::Neovim` owns ONE thread that both
> serves and sends, fed by an inbox queue (nested calls inside a callback ride the gem's
> Fiber-based `yielding_response`). Inbound handlers must enqueue-and-ack — a slow response freezes
> the *editor*.

---

## Near-term sequence

1. **✅ M1b–M3b — done**: hands, Journal + cost accounting, test infra, transport fork.
2. **✅ M3c — the bench — done** (this session): the `Context` combinators, the `turn`/`repl` phases,
   capability guarding, `DryReplay`/`Grader`/`Compare` + speculative branching. The thesis is unlocked.
3. **✅ M4-1 — the Rust Timeline — done** (this session): the persistent Merkle DAG in `ext/lain`, both
   impls green against the shared law groups.
4. **P — provisional cleanup** (needs a Console key): re-record the transport cassette, run the `:live`
   differential once, confirm the real rate-limit reset header. See `remaining-work.md` § P.
4b. **✅ Chunk done (2026-07-13)** — CE-1 (cap bug), CE-2 (`Request#prefix_digests` + journaled
   chain), CE-3 (two-process prelude invariant spec), `Bench::Rewrites` attribution, the memory
   write path (`Memory::Recorder`, `memory_write`, `JournalMemoryRoot`, `RefuseSecretWrites`),
   BM25 (`bm25` crate in `ext/lain` → `Memory::Bm25`) + `Context::Recall`, the session-state seam
   (`Session`, `edit_file` with the read-before-write contract, `todo_write`), and the 5-0.1
   concurrency spike (ShellOut **cooperates** with the fiber scheduler — idle-child measurement;
   5-0.3 must re-verify under stdout-flood). Cards, panel findings, and follow-ups:
   `planning/specs/chunk-cache-memory-hands.md`. (Subsumed the old items 5–6;
   `Agent::Accounting` had already landed pre-chunk. 3c-3.2, the repl middleware phase, turned
   out to be already built in `exe/lain`.)
7. **Early headline experiment** — quantify harness-induced variance (all prerequisites now built): a
   `DryReplay`/`Compare` sweep over the harness's own recorded sessions. The cache-write columns
   (CE-2) make this the study HN 48883275 could not produce: grader × tokens × cache-write, no proxy.
8. Then the critical path to the thesis: **memory (M5 · 5-3) → retrieval sweep (M6 · 6-2)**, alongside
   the M5 orchestration/code-mode band and M4-2 (Neovim) — sequence the rest around keeping that moving.

---

## Map of the documents

- **Architecture & why:** `~/.claude/plans/jiggly-greeting-avalanche.md` (approved).
- **Remaining committed work** (task-level units, acceptance criteria, dependency map):
  `planning/remaining-work.md`.
- **Exploratory ideas:** `planning/` — `research-scan-2026-07.md` (survey + prioritization),
  `hn-harness-overhead-2026-07.md` (the field's cache/overhead argument, Tier-1 items folded into
  `specs/cache-economics.md`), `orchestration-experiments.md`, `first-class-concepts.md`,
  `crdt-exploration.md`.
- **Grounding sources:** `references/` — `INDEX.md`, `SCOPE.md`, `memory-and-retrieval.md`,
  `oss-inspiration.md`, 14 papers in `papers/rst/`, reference impls in `repos/`.
- **Origin brainstorm:** `TODO.md` — the raw idea list this ROADMAP reconciles.
