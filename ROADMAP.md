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
| **Tool design (ACI)** | terse vs. verbose vs. guardrailed feedback; tier 1/2/3; **tolerant/repair · prereq-enforced · phase-narrowed** | correct-call rate; recovery-from-error; **compounding accuracy over N steps** |
| **Tool disclosure** | upfront-JSON vs. deferred/searchable vs. code-API | tokens; correct-call rate |
| **Prompt slots** | base template vs. user-filled holes (persona · domain framing · output contract) | correct-call rate; grader; cache-hit |
| **Provider / model** | Anthropic vs. OpenAI-compatible vs. local (ollama) vs. Bedrock (work key — `planning/specs/bedrock-provider.md`) | grader score; cost; latency |
| **Orchestration** | single-thread · orchestrator-worker · **fork-worker** · **cache-sibling fan-out** · dual-ledger · handoff · LATS · MoA · adaptive router · **shared-artifact (CRDT)** · **control-flow-as-code (coded FSM vs prompt-ReAct)** | grader; tokens (~15× risk); cache-write; context-loss events; **loop-depth / no-progress** |
| **Memory / retrieval** | Manifest · BM25 · Hybrid · Vector · Graph · temporal-KG · content-addressed versioning · structural · **lineage/outcome-ranked (Journal-native)** | recall@k; tokens on recall; abstention |
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
  same shared law groups passing against **both** impls.
  **✅ Done:** `planning/specs/rust-findings-resolution.md` — resolved the 2026-07-15 `ext/lain`
  findings (loud walks on corrupt chains, idiomatic errors via thiserror, FFI naming/dedup,
  Digest/Role domain types, edition 2024). (Stale "Planned" marker fixed 2026-07-17 — the plan
  doc itself has read `status: done` since before this chunk.)
- **M4-2 — the Neovim frontend.** `[built]` (2026-07-15, `chunk-spine-agents-sweep-nvim.md`):
  journal-subscribing `Frontend::Neovim` skeleton, read-only `lain://timeline`/`workspace`/`diff`
  projections, and editable `lain://request` + `:LainResend` (a resend journals as
  `request_resent`, never mistakable for a real dispatch). Provider round-trip of an edited
  request remains later `[exp]` work.

**The bench — the deliverable — now exists.** For the first time the project can *compare strategies*:
`DryReplay` re-renders a recorded Timeline byte-identically under one `Context` and yields a
deterministic diff under another, and `Compare` reports distributions over `n` runs (refusing to
compare mismatched capability-degraded sets). The remaining committed work — the key-gated **P**
cleanup and the **M4-2/M5/M6** bands — is inventoried with acceptance criteria in
[`planning/remaining-work.md`](planning/remaining-work.md); this ROADMAP layers the research- and
TODO-driven `[exp]` ideas on top and sequences them. Suite: **2513 examples, 0 failures, 1
pending** (a `:desktop`-tagged real-dunstify test, excluded by default — the four Ruby↔Rust
digest-parity pendings were un-parked by S2's T25 re-port, zero incidental pendings remain);
RuboCop clean at default metrics; `cargo test` **86/0** (post
chunk-meet-supervision-fanout-interface, 2026-07-17).

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

- **`[exp]` The parallel spec run fails silently when a worker is killed.** Observed 2026-07-28:
  `rake pspec` reported `4523 examples, 0 failures` where a serial `rspec` reported `5518` — the
  OOM killer took a worker and `parallel_tests` exited non-zero **without naming the ~1000
  examples that never ran**. It reads as a broken commit; it is a starved machine. Three commits
  in one session were blocked by this, plus two runs that surfaced as Ruby crash dumps in
  unrelated specs (`improvement_spec`, `derivation_audit_spec`) rather than as failures.
  Mitigated for now by `Rakefile#spec_workers` — one fewer worker than physical cores, overridable
  with `LAIN_SPEC_WORKERS`. **Not fixed:** a dead worker should fail *loudly and specifically*.
  Worth having the hook compare the reported example count against a recorded floor, so a
  vanished worker is an error naming itself rather than a mystery. Context from the same box:
  each worker loads the whole suite (ActiveSupport + the compiled extension + fixture corpora),
  and `mempalace` was resident at 3.7 GB with `rust-analyzer` at 1.2 GB of 15.9 GB total.

### M3b — transport fork `[built]`
- Vendor the RubyLLM slice into `lib/lain/provider/http/` with provenance; their 5 non-VCR unit specs
  must pass unchanged; bootstrap their anthropic cassettes.
- Mutate red-green: `parse_completion_response` stops flattening; `Message`/`Content` → `Lain::Response`;
  retry journaling; Faraday logger → `Sink`. Differential-test `AnthropicRaw` vs. the SDK oracle.
- Adopt `state_machines` for the Agent (illegal transitions checked; `before_transition` → Journal).
- **Fold-in:** add a **local-model provider arm** (ollama) to the provider axis `[exp]` — cheap,
  private meta-tasks (memory-save gating, query sanitization, prune-scoring, and local **autocomplete /
  interactive prompting**) that keep PHI off the wire (TODO 31–33). The **harness-variance experiment** can run as soon as this + M2 + M3a exist. These meta-tasks are now formalized as the
  **oracle seam** — `planning/specs/oracles.md` (OR-1). **✅ Done:**
  `planning/specs/code-review-ollama-test-infra.md` — native-API `Provider::Ollama` (qwen3
  default, temp-0/seeded determinism arm), resolution of the 2026-07-14 code-review comments,
  and the matcher/test-infrastructure upgrade. (Stale "Planned" marker fixed 2026-07-17 — the
  plan doc itself has read `status: done` since before this chunk.)

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
  - **Behavioral & verification graders** (HN scan, `planning/hn-agent-landscape-2026-07.md` #1): a
    **two-pass verification wrapper** (a refutation pass filters false positives — a generic decorator
    over any rubric grader, reusable bench-wide), a **tool-steering detector** (declared
    description vs observed selection frequency), and a **frustration/repair grader** that walks a
    behavioral signal back through the DAG to the turn that caused it (attribution only our
    content-addressed lineage can do). All offline over the Journal, all `DryReplay`-substitutable.
    **Spec:** `planning/specs/graders.md`. `[exp]`
  - **Tool-call repair + guardrail stack** (HN 48883275 §4 + Forge id=48192383): the repair middleware
    (`tolerant` / `tolerant-and-tattling`) composed as a *sequence* — validate → rescue-parse →
    **prereq/step-enforce** → nudge-retry — each a `Middleware` in the monoid; scored by **compounding
    accuracy over N steps** on a **local 8B** (where the lift is visible), and a **per-phase toolset
    narrowing** guard (attenuation made dynamic mid-run). Shape, never safety — never reachable by a
    validator that sounds like a security control. `[exp]`
  - **DSL / grammar-constrained tool interfaces** (HN scan #5): GBNF grammar-constrained decoding as
    a local-model Provider variant (mask illegal tokens, no retry) vs post-hoc `Tool::Input`
    validate+retry; the ast-grep catalog exposed as a DSL-shaped tool; a per-tool declared-effects
    catalog (Jacquard effect rows = `Tool::Input` extended from shape to capability). Watch the
    validator-green-but-non-functional trap — score a non-functional check, not just "it parses."
    `[exp · parked]`
  - **Per-effect external-$ budget + recursive subagent ceiling** (HN scan #7, the DN42 bankruptcy):
    extend CE-6's cost model with a **tool-side external-cost** dimension (egress/instance $, invisible
    to a token cap) and a **per-lineage spawn ceiling** that hard-stops mid-run before a bill lands.
    `[exp · parked]`
  - **DELEGATE-52-style corruption fixture** (HN scan Tier-3): a long-workflow document-edit fixture
    (their naive `read_file`/`write_file` harness corrupted ~25% — *exactly what we vary*); A/B naive
    vs structured edit tools, beside the "Hey" fixture. `[exp · parked]`
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
  - **The Workspace Timeline** — **✅ landed 2026-07-17** (write side `b2b1051`, restore `03ef086`):
    a second content-addressed DAG of file snapshots (`:snapshot` events) paired with the
    conversation DAG — independent rewind of files vs. conversation. From Cline. The
    `Handler::Approving` coupling (cheap rollback makes `--yolo` safe) remains open, `[exp]`.
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
  - **Spatial "where did the agent work" replay overlay** (HN scan Tier-3, Mindwalk): the Workspace
    Timeline already records which files each Effect touched — a spatial change-density overlay over
    the codebase is a *query over existing data*, not new instrumentation; an off-track detector for
    comparing orchestration tactics. See `planning/interface-integration.md`. `[exp · parked]`

### M5 — orchestration, memory, code mode `[planned]` (orchestration core `[built]` 2026-07-15)
- `Tool::Subagent` (async, attenuated, supervised). `Tool::Todo`. `Memory` (content-addressed,
  `Manifest` + `Bm25`), `Context::Recall` after the last cache breakpoint. **✅ Done (2026-07-15):**
  `planning/specs/memory-read-path.md` — the 5-3.1/5-3.2 close-out (manifest + `memory_read`
  wired into the live session, replay-side memory roots, Bm25 root-keyed cache). Server-side context editing
  as a comparison arm. Structured `edit_file` (`str_replace` + read-before-write). Choose the
  concurrency model. **Code mode** — `eval_ruby` against a persistent binding.
- **✅ Landed 2026-07-15** (`planning/specs/chunk-spine-agents-sweep-nvim.md`): fibers adopted in
  the agent loop (`Async` + a `Sync` bridge for non-reactor callers, structured cancellation —
  5-0.2/5-0.3); the `Lain::Event` envelope + Turn collapse (TL-1/TL-2) and the projections
  (TL-4 — mailbox/workspace_at/provenance/unique-usage); `Tool::Subagent` one-shot + actor +
  within-turn concurrency (5-1.1–5-1.4); `ask_human` as a promise (OM-4); and the role catalog
  on prompt slots (OM-5/PS-3). **Two cards deliberately stayed off main, awaiting a human
  decision** (see ROADMAP § Near-term sequence item 8): TL-3 (`meet`/`diverge_at` generalized
  over the causal DAG — the projection `causal_meets` vs a redefinition of `meet`) and TL-5
  (the Rust re-port, blocked on TL-3). **✅ Both ruled and landed 2026-07-17** — see item 10
  below: TL-3 ruled enriched (a) (render meet byte-unchanged, set-valued `causal_meets`, new
  `dominator_meet` checkpoint primitive); TL-5 landed as the T25 Rust re-port, un-parking all
  four digest-parity pendings. **Remaining M5 tail:** grader-from-Gherkin; the edge-grain
  provenance question for OM-1/OM-6 (today's parent→child `tool_result` link stays
  correlation-grain only, no causal edge — the 2026-07-17 chunk left this open by design).
- **✅ Landed 2026-07-17** (`planning/specs/chunk-meet-supervision-fanout-interface.md`): the
  Workspace Timeline write side + OM-6 supervisor reactor (actors become model-dispatchable, a
  queryable registry) with replay-restart (`bin/demo-supervision`); the sibling-template prefix
  arm (CE-4) + `stream_started` and stagger scheduling (CE-5, `bin/demo-fanout`); role→spawn
  glue (`Context#cache_marked` risk spent knowingly) and the `Embedder` model-id reader closed
  as RES4/RES3.
- **Fold-ins:**
  - **Event-sourced orchestration** (TODO 27–30): fibers (`Async` / socketry); the Store is the event
    log and mailboxes are projections over it; `ask_human` returns a **promise** (continue working,
    block only when the answer is actually needed); **one-shot *and* long-lived actor** subagent modes;
    supervision = replay-to-checkpoint (the same machinery as M2 resume). A whole team's run is
    forkable/replayable — you can *substitute a model for the human* from recorded replies for offline
    evaluation. **Spec:** `planning/specs/orchestration-model.md`. `[exp]`
  - **Supervision trees + checkpoint restart** (TODO 27 + 3) — **✅ landed 2026-07-17** (`b315b60`
    reactor, `fe9de76` replay-restart flagship, `bin/demo-supervision` ships): the orchestrator is
    a supervisor; a crashed subagent restarts from its last content-addressed checkpoint
    (Workspace Timeline).
  - **Meta-agents that study the harness** (TODO 94–100): the **court-clerk** (records memories from
    subagent timelines = the "dreams"/consolidation pattern, auditable because content-addressed) and
    the **friction-observer** (watches the Journal for harness friction, emits *experiment proposals*
    into the GEPA loop → a **self-improving harness**) `[exp]`.
  - **Spawn prefix strategy as an axis** (CE-4 — **✅ landed 2026-07-17**, `5b077c9`): fresh-root |
    fork-the-parent | sibling-template is a policy object at the spawn seam, **orthogonal to** the
    one-shot/actor lifecycle axis — the sibling-template arm now ships alongside fresh-root/
    inherit, preserving cache-sharing via `AttenuationPosture :handler_union`. Enables
    **fork-worker** (the HN thread's unresolved argument, answerable only by a bench — still
    open, `[exp]`) and **cache-sibling fan-out** (1 template write + N−1 reads via `stream_started`
    on the Channel + stagger scheduling — CE-5 **✅ landed 2026-07-17**, `b2967b9`/`738f83e`,
    `bin/demo-fanout` ships).
  - **Orchestration arms** (see `planning/orchestration-experiments.md`): single-thread ·
    orchestrator-worker · fork-worker · cache-sibling fan-out · dual-ledger (Magentic-One) · handoff ·
    LATS · MoA · adaptive router · shared-artifact (CRDT). Build the *comparison* before the fleet;
    each worker is worktree-isolated, and where tests collide (ports, DBs) they get a container or a
    separate DB schema (TODO 71–73).
  - **Code mode subsumes bash pipelines**, and **handles to out-of-context data** let the agent
    orchestrate computations over corpora it never loads (the medical-corpus unlock; smolagents'
    `PythonExecutor` ABC + state-dict-with-subagents-as-callables is the reference) `[exp]`.
  - **Control-flow-as-code vs prompt-driven loop as an axis** (HN scan #3, "Agents need control flow,
    not more prompts" + loopcraft): a coded state machine vs a prompt-driven ReAct loop over the
    **same Toolset** — measures how much loop reliability is control-flow vs prompt with tools held
    fixed (Lain owns the loop, so this is a first-class swept axis, not a hack). Emits per-iteration
    loop-depth / repeated-tool / no-progress Journal events. See
    `planning/hn-agent-landscape-2026-07.md` #3 + `orchestration-experiments.md`. `[exp]`
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
  - **Isolation as a swappable backend; egress as an observable Effect; credential brokering**
    (HN scan #6): microVM / container / bwrap as a *compared* knob (not just an exec seam); every
    allowed/denied network attempt an attributed Journal event; secrets stay host-side and proxied,
    never entering the sandbox (fits "Workspace is sent, not stored", keeps digests credential-free).
    Field lesson: the sandbox is the easy 10%, the policy engine + credential brokering the 90%.
    `[exp · parked]`
  - **Smaller parked arms** (HN scan Tier-3): **summary-inheritance** as a third CE-4 spawn-prefix
    strategy (fresh-root / fork / summary); the **DOWN/UP-loop** framing (loopcraft) as a lens over
    the four middleware phases + the human-loop-as-blocking-Middleware. `[exp · parked]`

### M6 — Rust round two & the retrieval sweep `[planned]` (retrieval sweep `[built]` 2026-07-15)
- Exec-boundary hardening and parallel tools remain `[planned]`; the **one Rust-implemented `Tool`**
  shipped as structural code search (two Rust bindings + five tools) — see the landed note below.
  **✅ Landed 2026-07-15** (`planning/specs/chunk-spine-agents-sweep-nvim.md`): `Memory::Vector`
  (exact cosine in pure Ruby over an `Embedder` seam — `Embedder::Ollama`/`nomic-embed-text`,
  `Embedder::Static` for determinism; usearch declined by the five-rule binding test at bench
  scale), `Memory::Hybrid` (RRF k=60), `Memory::Graph` (pure-Ruby wikilink N-hop; petgraph
  declined by the same test), and `lain bench sweep -k 5` — deterministic five-arm recall@k +
  tokens-on-recall over committed fixture embeddings, zero network, byte-identical across runs.
  Measured: vector .667, graph .438, bm25 = hybrid = manifest .333 — **hybrid did not beat
  vector** on this corpus (RRF dilution when one arm dominates), reported honestly rather than
  gamed; the corpus/fusion question is a follow-up, not a re-run.
- **✅ Landed 2026-07-18** (`planning/specs/structural-code-search.md`): the **structural** retrieval
  arm and M6's outstanding *one Rust-implemented `Tool`*. Two `ext/lain` bindings — `Ext::AstGrep`
  (ast-grep metavariable matcher) and `Ext::TreeSitter` (raw tree-sitter queries), both stateless,
  deeply-frozen, exact-pinned — behind five read-only tools: `ast_search` (structural code search),
  the `ast_dump`/`test_pattern` inspect pair (the model self-corrects a silently under-matching
  pattern), `code_outline`, and `file_symbols` (role-tagged symbol table from lain's own MIT
  tree-sitter queries). Degrades identically across typed/untyped code — the dependable modality
  where the graph layer (SCIP) is lossy. Pattern library seeded from `~/.zsh/ag_helpers`.
  **Deferred:** the role-catalog `only`-set wiring (the tools live in `base_tools`; attenuated role
  access is a follow-up because it must regenerate byte-identical prompt-cache tool-block specs), and
  `file_symbols` for **python** (ruby/typescript/rust shipped). Follow-ups in the spec: `method_call`
  over-report, paren-less `def`, grammar trim.
- **Structural memory** vs. structural code *search* above: the former recalls by trajectory *shape*
  (a fifth modality), the latter matches code by AST shape. Distinct.
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
  - **Journal-native retrieval, ranked by lineage/outcome** (HN scan #4: deja-vu + zby's four-field
    taxonomy): index the Journal itself as the memory corpus (the turns we already own,
    content-addressed), with **index-time secret redaction**; rank hits by **successful `spawned_from`
    lineage/outcome**, not just lexical score, so an abandoned branch's close text loses to a
    proven turn — a hybrid BM25+lineage arm no flat verbatim index can express. zby's four-field
    record (substrate · form · lineage · authority) is an axis-set for the sweep; "storage ≠
    activation" is "capabilities not permissions" for memory. See
    `planning/hn-agent-landscape-2026-07.md` #4. `[exp]`
  - **Local-model fidelity + tiny tool-callers** (HN scan Tier-3): treat chat-template / tool-call
    fidelity as a *named measured variable* on the ollama arm (where small models silently break); a
    **26M distilled tool-caller** as a candidate Provider variant ("tool-calling is
    retrieval-and-assembly, not reasoning"); **in-process vs out-of-process inference overhead** as a
    measured trade-off (LibArgus argues the opposite of our exec split for the inference hot loop).
    `[exp · parked]`

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

**Window topology — tmux-native** `[shipped]` (TODO 7–16). The 2026-07-11 survey that settled
on tmux-native placement, with the desktop-config findings kept as a historical record, lives in
[`planning/interface-integration.md`](planning/interface-integration.md).
- ✅ `lain up` creates (idempotently) or reattaches to a `lain` tmux session — a `chat` window
  plus a session-scoped status HUD (`Lain::CLI::Up`, `plugin/tmux`). The `lain` process **owns
  the loop**; the chat window is `Frontend::TTY`. iTerm2's `tmux -CC` renders the same session
  natively on macOS — one mechanism, both platforms.
- ✅ `lain up --nvim` splits the window into an `nvim --listen` pane and a `chat` pane, both
  pinned to one cwd and one **deterministic socket** (`$XDG_RUNTIME_DIR/lain/nvim-<hash>.sock`,
  or `.lain/nvim.sock` when the project carries `.lain/`) so the editor and the chat that
  attaches to it cannot diverge. Lain prefers **attaching to the already-running editor** and
  spawns its own only as fallback (`plugin/nvim` owns the socket convention). `--nvim` without
  an `nvim` binary degrades to the plain chat window with a named warning.
- ✅ **Subagents get their own windows** — tmux-native, programmatic (`split-window`/`new-window`
  ids lain can track and kill), survivable across detach. `chat --windows` opens a read-only
  `lain watch` viewer window per spawn; `/fork` opens a window on the forked H-lineage. Per-pane
  session-scoped options (`lain up`) keep the global `tmux.conf` untouched.
- **Pane cwd = the agent's worktree** (TODO 71–73) `[exp]`: `Isolation::Worktree` already leases
  a per-worker checkout; wiring `split-window -c <worktree>` + a `role@branch` title so
  switching panes *is* switching isolated checkouts is the remaining step.
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
  a kitty block) or ghostty. Knock-ons: the default terminal and its `--class` spawn flags. On macOS,
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
  escalations (TODO 74–80) are inbox items with an urgency field, not interrupts. **✅ The inbox
  half landed 2026-07-17** (`d0a3960`): `lain://inbox` + `:LainReply`, the TTY `/inbox` drain
  command, dunst arrival notifications (`d42cb44`), and the tmux status-line flag/count
  (`9b9ecd2`). Orchestrator escalations with an urgency field remain `[exp]`.

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
  *visible at the moment of typing* is the point. **✅ Landed 2026-07-17**: `StatusFeed` + tee
  (`86a2be0`), TTY prompt warmth (`66fd148`), `lain up` tmux HUD (`9b9ecd2`) — the nvim lualine
  enrichment remains `[exp]`.
- **Time-travel as editor motion**: in `lain://timeline`, cursor motion over a turn re-renders
  `lain://request`/`lain://diff` at that digest — scrubbing the session; `:LainFork` at the cursor
  opens a speculative branch. The human UI for `fork_and_try`/`rewind_to`/`diverge_at`; only a
  content-addressed timeline can do this.
- **Approvals in editor idioms**: the pending tier-3 queue as a list buffer (`<CR>` approve, `dd`
  deny, visual-select batch) and `dunstify --action` approve/deny buttons on notifications — both
  are views over `Handler::Approving`'s queue, no new authority. **✅ Landed 2026-07-17**: the
  queue behind `Handler::Gate` (`ab9a644`) and the dunstify approve/deny buttons (`d42cb44`); the
  editor list-buffer view over the same queue remains `[exp]`.
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

**XDG conformance** `[landed]` (added 2026-07-11; landed 2026-07-16 via
chunk-fixes-xdg-resume-signals: `Lain::Paths` resolver, journal + reline history under
`$XDG_STATE_HOME/lain/`, session discovery directory-derived, `/tmp/lain` runtime fallback;
relative/blank `$XDG_*`/`$HOME` treated as unset per spec)
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
> traps, every one of which the design had to bend around: writes **flush only on the loop's next read** (never
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
8. **✅ Chunk done (2026-07-15)** — the event spine, the M5 orchestration band, the M6 retrieval
   sweep, and the Neovim frontend, landed together (`planning/specs/chunk-spine-agents-sweep-nvim.md`):
   the `Lain::Event` envelope + Turn collapse (TL-1/TL-2), projections (TL-4), fibers adopted in
   the agent loop (5-0.2/5-0.3), `Tool::Subagent` one-shot + actor + within-turn concurrency
   (5-1.1–5-1.4), `ask_human` as a promise (OM-4), the role catalog on prompt slots (OM-5/PS-3),
   `Memory::Vector`/`Hybrid`/`Graph` + the gold-corpus sweep (`lain bench sweep -k 5`, 6-2.1–6-2.4),
   and `Frontend::Neovim` (4-2.1–4-2.3). **Two cards awaited a human decision and stayed off main:**
   TL-3 (`meet`/`diverge_at` generalized over the causal DAG — the projection `causal_meets` vs a
   redefinition of `meet`) and TL-5 (the Rust re-port, blocked on TL-3). **✅ Both ruled and
   landed 2026-07-17** — see item 10 below. **Remaining M5 tail (as of 2026-07-15):**
   OM-6 supervision (needs the Workspace Timeline), grader-from-Gherkin, the sibling-template
   prefix arm + `stream_started` (CE-5); plus new follow-ups from the plan doc: role→spawn glue
   (a seam-marked role bulk risks a 5-mark Anthropic 400 — spend the mark knowingly), an
   `Embedder` model-id reader, and the edge-grain provenance question for OM-1/OM-6. **All but
   the edge-grain provenance question landed 2026-07-17 too** — see item 10.
9. **Landed (2026-07-16)** — the 2026-07-16 review's blocker + majors, XDG conformance
   (§ Interface & UX), durable chat sessions + `--resume` (incl. SIGKILL/power-loss via a
   response WAL with resume-time salvage), and graceful-exit signals with a grace countdown:
   `planning/specs/chunk-fixes-xdg-resume-signals.md` — all 22 cards on main. Resume-after-
   crash is now a property (M2): chat journals a loadable session by default, the Loader
   reads open sessions and resume chains, salvage recovers paid-for responses without
   re-spending. Residuals recorded in the plan doc: OM-6 render-side snapshot seam, the
   interactive countdown at an idle prompt, provider field in the session header,
   always-AnthropicRaw-for-chat convergence, streamed-4xx retry coercion, live-429
   rate-limit-header confirmation.

---

10. **✅ Built (2026-07-17)** — `planning/specs/chunk-meet-supervision-fanout-interface.md`, all
   22 task cards landed, one commit each: the TL-3 ruling (enriched (a): render meet unchanged ·
   set-valued `causal_meets` · a new `dominator_meet` checkpoint primitive — research:
   `planning/dominator-meet-research-2026-07.md`) + the T25 Rust re-port un-parking the four
   digest-parity pendings; R.1–R.5 and the recorded residuals; the Workspace Timeline write side
   + OM-6 supervision with replay-restart (`bin/demo-supervision`); CE-4 sibling-template + CE-5
   `stream_started` + stagger (`bin/demo-fanout`); and the interface band (state feed + tmux HUD
   via `lain up`, queue-backed approvals with dunstify actions, the `lain://inbox` surface,
   buffer ergonomics). Record: the plan spec above and
   `planning/dominator-meet-research-2026-07.md`.

11. **Planned (2026-07-21, panel-reviewed)** — two independent chunks authored via
   `/create-plan`, executable in either order: `planning/specs/chunk-parallel-tools-core-skeleton.md`
   (M6: parallel tool execution widened past `Subagent` with barrier semantics + the
   `crates/lain-core` msgpack-RPC exec skeleton, `forbid(unsafe_code)`, confinement
   explicitly out of scope) and `planning/specs/chunk-gherkin-meta-agents-plan-compaction.md`
   (grader-from-Gherkin GG-1..5; the four meta-agents — court-clerk consolidation,
   friction-observer, harness-improver with the XDG improvements sink, and the auto-approver
   as an attributed approval surface; plan-shaped compaction PC-1..7 closed by the
   shape × density sweep; plus the owed `cache_profile` and `NonStringSlot` fixes as
   prerequisite cards).

12. **Planned (2026-07-23, panel-reviewed)** — `planning/specs/chunk-ui-ux-tmux-nvim.md`:
   the UI/UX chunk — in-repo tmux + Neovim plugins, the `you>` command registry
   (/help /status /sessions /inbox /approve /yolo /model /rewind /fork /btw /quit /goal
   /ruby /meta), session forking with ephemeral journal-and-reap, the M4-2 provider
   round-trip of an edited `lain://request`, auto-approver wiring (`--auto-approve`),
   read-only per-subagent tmux windows (`lain watch`), `lain up` flag passthrough +
   `--nvim` cockpit, ARCHITECTURE.md, and the README/xmonad cleanup.

13. **Planned (2026-07-25, panel-reviewed)** — `planning/specs/chunk-live-wiring.md`: the
   live-wiring chunk, closing the gap between five chunks of landed bench machinery and a chat
   session that uses almost none of it. Per-turn `Context` construction on the Agent
   (`PipelineSource`) with `Compaction::Scheduler`/`Need`/`Cold` **on by default**, backed by a
   frozen per-turn summary snapshot and eager summaries fired from the agent loop's long-lived
   reactor (not the reaping gather task); a per-model context-window book; the secret-write guard
   finally journaled, its oracle declines separated from credential-pattern hits, the memory-save
   heuristic recalibrated off unbroken-token shape, and `Oracle::MemorySave::Gate` wired live;
   plus two leaf gaps — four tools that ignore `worker_env.cwd`, and `causal_parents` dropped
   from journaled turn records (writer **and** the digest-verifying reader). Ruled out during
   planning with citations: `Plan::Runner` live wiring (a second execution mode, not wiring) and
   the tool-disclosure arms. **✅ Landed 2026-07-25** (`fddc8e3..56a7815`, 15 commits).

14. **Planned (2026-07-25, panel-reviewed)** —
   `planning/specs/chunk-compaction-tiers-pins-isolation.md`: compaction tiers, pinned history,
   and isolation invocation. The summarizer becomes a *tier* (selectable provider/model, spend
   journaled through `Telemetry::OracleAnswer`, and a **custom deterministic tier** of user
   summarizer classes answering `suitable?`/`compact` from `.lain/summarizers.rb`, consulted
   before any model call); a human can **pin** history the compactor may not touch, with `/goal`
   objectives auto-pinned, which discharges the binding pre-ruling that `Compaction::Head` must
   become protected-aware in the same change; and the isolation backends built in chunk 11 become
   invocable from both `lain chat` and the bench, with a worker's commits preserved to a private
   ref before its worktree is reclaimed and conflicts resolved by a forked subagent. Folds in
   live-wiring follow-ups 13 and 14 (per-turn `Need` from the live model, and a compaction cost
   record that refuses to quote figures it cannot stand behind). Ruled out during planning with
   citations: the `name:verb` command-modifier grammar, and the conversational **span**
   summarizer (distinct from the per-result eager tier — a span's boundaries move every turn, so
   its cache key and invalidation are unsolved).
   **✅ Landed 2026-07-25** (`ad72d5d..2e828a6`, 15 commits), with two scope corrections found
   during execution and recorded as tickets rather than quietly dropped: **isolation reached no
   consumer** — the bench has no `arms` subcommand to attach `--isolation` to (Deviation 8, spec
   ticket 7) and nothing on the chat path constructs an actor-mode subagent (Deviation 9, spec
   ticket 13), so deliverable (C) landed as a wired seam ahead of both callers; and the chat fleet
   has no per-actor completion seam, so chat isolates workers without handing their commits back
   (spec ticket 6). Closed out **2026-07-26**: the four `exe/lain` flags the chunk's own cards
   assigned to the orchestrator (`--isolation`, `--summarizer-provider`, `--summarizer-model`,
   `--summarizer-max-tokens`) had never landed, so tiers A and C were unreachable from the command
   line; `spec/lain/cli/chat_flags_spec.rb` now parses the CLI subtree and fails when a flag the
   code reads is declared by no command, and the README, `docs/commands.md`, and
   `docs/providers/ollama.md` describe three summarizer tiers, pins, and isolation's real reach.

15. **Planned (2026-07-27, panel-reviewed)** —
   `planning/specs/chunk-algebra-vocabulary.md`: the algebra vocabulary. Lain already maintains a
   monoid (`Context::Combinator#>>`), a commutative monoid (`Usage#+`), and a meet-semilattice on two
   of `Timeline`'s three meet-ish operations — and every one of those facts is evidenced only by how a
   method behaves plus an `include_examples` call in a spec, with nothing in `lib/` saying so. This
   chunk names the properties as modules (following `Lain::ContentAddressed`), declares them
   **per-operation** where the structures live (so `#causal_meets` can be declared *not* a
   semilattice, with its reason), and makes the declarations do real work via a registry-driven law
   sweep that refuses any claim with no means of proof and proves every refutation by asserting the
   law actually fails. Applies the same vocabulary to existing code: `DedupeToolCalls` and
   `PurgeFailedInputs` already analyze-then-map, and naming that factoring makes their analysis
   inspectable and their output traceable to its input. Closes a Rust gap too — `ext/lain/src/dag.rs`
   claims a meet-semilattice in its module doc and tests 2 of the 4 laws. Ruled out with citations:
   algebra traits in Rust (no production caller, and a second Rust-native parity suite would fork the
   differential oracle), and declaring `Regular` / `Store` idempotence / `Canonical` determinism (each
   needs a generator under the sweep's contract).

16. **Planned (2026-07-27, panel-reviewed)** —
   `planning/specs/chunk-derived-context-timeline.md` (**requires chunk 15**): the derived context timeline. Compaction
   stops being a render-time projection and becomes a **second lineage** — a derived `Timeline` in
   the same content-addressed Store whose replacement events name the source events they subsume
   via `causal_parents`, so the session timeline stays the lossless record while the derived chain
   is what the provider sees. Promotes the Context-as-IVM lens (this file, above) from
   implementation guidance to a materialized, addressable, diffable artifact, and discharges
   `chunk-compaction-tiers-pins-isolation.md` follow-up 2 (the deferred span summarizer): its
   "a span's boundaries move every turn, so its cache key is unsolved" objection is answered by a
   derived chain having a content address. Carries a **pluggable strategy seam** — model
   summarization through a replayable oracle, and a deterministic zero-cost elision — because
   collapsing a span by asking a model, dropping it, and marking a finished plan step are three
   policies over one span and should be swappable like every other axis. Also fixes a correctness
   bug the planning probes found: the shipped compacting render is **Anthropic-invalid** at every
   `keep_last` (the assistant summary lands at `messages[0]`, the default `--compact-keep 20` adds
   a second consecutive assistant, and the boundary splits `tool_use`/`tool_result` pairs), which
   nothing downstream normalizes and no spec pinned. Ruled out during planning with citations:
   hierarchical/recursive derivation, the plan-step strategy, exchange-level reordering, and
   retiring `Context::Compact`.

17. **Planned (2026-07-28, panel-reviewed)** —
   `planning/specs/chunk-chat-ux-and-ui-fixes.md`, grounded by
   `planning/chat-ux-research-2026-07.md`: the chat-window UX chunk, plus the four defects a live
   `lain up --nvim` run against the ollama arm surfaced. The defects: `lain://journal` can never
   fill (tool output rides the TTY channel, the editor's channel sits behind the tee, nothing
   bridges them); `lain up --nvim`'s `:LainStart` guard no-ops **silently** when the shipped plugin
   is not on the runtimepath; `Approval::Queue#admit` emits nothing, so no surface — HUD, editor,
   or bell — can report a blocked approval; and a zero-byte session file (the designed-in artifact
   of `Journal.open` preceding the header write) **breaks bare `--resume`** and makes `lain watch`
   poll forever. The UX: a starship-compatible prompt formatter in `ext/lain` (the grammar is
   1,712 bytes, four productions — starship itself is unlinkable, `mod modules` is private), the
   six metrics a prompt needs (**none** published today — context occupancy's ratio is computed
   inside `Need::ApproachingWindow#fired?` and discarded as a boolean), a `Theme` of named style
   tokens over the nine literal Pastel calls, a command render API so `/status` can be more than a
   String wrapped in cyan, Reline vi-mode + multiline, `C-g`→Neovim compose returning on `:wq`,
   and `/`+`@` completion over a `nucleo-matcher` binding — Reline's own completion being
   prefix-only and hard-coded. Ruled out during research with citations: shelling out to starship
   (four traps, and no config layering), `skim` as a library (installs a global allocator from its
   library crate), a full firenvim-style UI embed (~600–1000 lines, and UI-attaching to the user's
   nvim collapses their editor to the smallest client), and a ticking TTY status line (revisits the
   2026-07-11 tmux-primary ruling; the seam is left, the behaviour is not built).

18. **Planned (2026-07-28, panel-reviewed)** —
   `planning/specs/chunk-vsock-exec-transport.md`, grounded by
   `references/firecracker-microvm-isolation.md` and two executed spikes: the **vsock-native exec
   transport**. `lain-core` learns to listen on `AF_VSOCK`, and `Core::Client` learns to take an
   injected transport, so the exec boundary can cross a hypervisor without a protocol change.
   Deliberately **backend-agnostic**: the guest-side listener is identical for Firecracker,
   libkrun, QEMU/KVM, and Cloud Hypervisor, so the chunk commits to no hypervisor and defers the
   libkrun-vs-Firecracker decision. Two spikes already de-risked the central claim — an unmodified
   `Core::Client` runs the boundary through a faked Firecracker `CONNECT`/`OK` handshake (6/6) and
   over real `AF_VSOCK` via `vsock_loopback`, which **autoloads unprivileged** so the whole chunk
   runs on hardware with no `/dev/kvm` (this desktop's SVM is off in BIOS). Static musl `lain-core`
   is 1.2 MB stripped, ~2.5% of Firecracker's rootfs budget. Panel review reversed three first-draft
   decisions: the "every transport's `#stop` must EOF the wire" contract clause was an accident of
   statement ordering in `Client#stop` promoted to an obligation — the client now collapses its own
   read side instead; `Client#pid` is deleted rather than widened to nil (its only readers are two
   specs that `Process.kill`); and the Rust generalization is larger than claimed, since
   `serve_connection` and both `Sink`/`Stream` aliases are hard-typed to `UnixStream` and the orphan
   rule forbids the off-the-shelf `tokio_util::net::Listener`. Ruled out during planning: a
   Firecracker-specific transport (six proven lines, but no consumer until a hypervisor is chosen,
   and the research favours libkrun for its virtio-fs and TSI) — `Child` *spawning* and
   `Transport::Vsock` *attaching* already exercise the contract in both shapes.
   **✅ Landed 2026-07-28** (`048f935`, `c338bf3`, `1c8734e`, `0e07a5f`, `8fa9058`, `f844d6c`). The
   same `Tools::Bash`-vs-`Tools::CoreExec` differential that pins the Unix path now passes across
   the vsock boundary, and `--tag vsock` is 19 examples that **skip rather than fail** where the
   kernel or the binary is missing. **The plan's premise was wrong in one respect and it changed
   the work:** the two spikes it rests on do not exist — no commit, no branch, no dangling object,
   no stash — so their results survive only as prose in
   `references/firecracker-microvm-isolation.md` §6, and T6 was re-rated from medium to high risk
   as the chunk's *only* end-to-end proof rather than a wiring exercise. Four grounding facts were
   re-measured and corrected in flight: `VMADDR_PORT_ANY` is `0xFFFFFFFF`, **not 0** (port 0 and
   everything under 1024 raise `EACCES`); `connect(2)` to a dead vsock port **succeeds** 4 runs in
   5 on `vsock_loopback`, so nothing detects "nothing is listening" at connect time and
   `ECONNREFUSED` never fires; `CID_HOST` and `CID_LOCAL` are indistinguishable against a live
   listener; and the kernel **reuses** a just-freed ephemeral port. The panel's most valuable
   catches were all of one kind — green tests not testing their subject: the daemon's readiness
   file **outlived the daemon that wrote it**, so a reused tracing path handed a reader a dead
   daemon's port (undetectable, because connect succeeds); the port write was not atomic, and every
   prefix of a 10-digit port parses cleanly, so a torn read yields a *wrong port* rather than an
   error; and T6's first draft had six of seven examples that would have passed identically over a
   Unix socket.

19. **Planned (2026-07-28, panel-reviewed)** —
   `planning/specs/chunk-bench-arms-subcommand.md`: a **live door for the arm comparison**. Split
   out of chunk 18 during panel review — zero shared files, zero dependency edges, and unlike the
   transport work it spends real API money and carries a human-gated manual pass. `Bench::CLI#arm_report`
   has been fully implemented and spec-tested since the orchestration chunk but is reachable from no
   Thor subcommand, so the arm comparison can only be run by specs. Narrows (does **not** close)
   ROADMAP Deviation 8: the chat half was closed by the 2026-07-26 `--isolation` follow-up, and
   `Bench::CLI#arm_sweep_report` remains a second doorless report. Grounding corrected a claim the
   first draft made and acted on — `lib/` *does* construct a spawn seam
   (`bench/arm_sweep/recordings.rb:80`), and `ArmTasks` + `ArmSweep` supply the tasks, graders, and
   arms the entry point assembles. The sharp edge the plan exists to avoid: `--isolation` must carry
   **no Thor `default:`** — copying `chat`'s declaration would make `options[:isolation]` never nil
   and silently collapse the unset-vs-`"none"` distinction `#arm_isolation` documents and
   `spec/lain/bench/cli_spec.rb:223` pins.
   **✅ Landed 2026-07-28** (`ea9b0eb`, `30ff8de`, `16fc6be`). `lain bench arms FIXTURE` exists,
   declares that it spends real API money, and refuses an unknown backend naming the advertised
   set before any arm runs. **Deviation 8 is narrowed, not closed** — `#arm_sweep_report` is still
   doorless. Three things the panel caught that the specs had not: the orchestrator-worker arm was
   **structurally inert** — built without a `decompose:`, so the default line-splitter met the
   fixture's folded YAML scalars and every task decomposed to exactly one subtask, meaning the four
   `category: parallel` tasks could not test the hypothesis they exist for, and the report rendered
   a clean null result (orchestrator tokens were byte-identical to the control at a flat `100.0`;
   after the fix, `mean 212.5 / max 300`). The per-task grader dispatched by **matching prompt
   text**, and `ArmTasks` enforces unique ids but not unique prompts, so two tasks sharing a prompt
   both graded against the first one's gold and scored a false `1.000` — now refused loudly, though
   the underlying seam (`Arm::Driver` takes `tasks: Array<String>` and discards identity) wants a
   real per-task identifier. And the lease journal was first written to **stderr**, violating
   `journal.rb:23`'s "NEVER stderr" and interleaving Thor's own error output into the NDJSON — now
   an explicit `--journal PATH` through `Journal.open`, which is what makes the manual pass's
   "confirm the lease telemetry" step meaningful at all.

20. **Planned (2026-07-29, panel-reviewed)** —
   `planning/specs/chunk-review-correctness-cost.md`: **chunk A of the simplification-review
   fixes** (`planning/reviews/2026-07-29-simplification-review.md`). The shipped defects (split-
   chunk streaming crash, `gsub` backreference interpolation reachable from model input, PlanSweep
   silently dropping `system:`, `lain up` re-execing every pane on the forbidden ruby-4.0.5,
   `AstGrep.dump`'s measured 75 MB-from-10 KB quadratic blowup), the verified performance fixes
   (`Scribe#catch_up` O(n²)-per-session, one-walk-one-dump on the Derived render path, Slots/
   Catalog load-once-render-once, `Toolset#to_schema`), the Rust safety/idiom work that is also a
   wiring prerequisite (recursion bounds, mutex-vs-Ruby discipline, the `NO_COLOR`-via-feature
   trim, one `read_text` encoding policy), a `Tools::Grep` lain-core RPC, and the record-keeping
   card (T39) that writes the epic-tier entry, the Rust parity gap (`planning/rust-parity-gap.md`),
   and the unwired-seam triage item. Memoization is constrained by ruling: restructure over cache,
   stated key-space/bound/consistency, "not worth it" is an allowed verdict (T19). The Rust
   dag/canonical/event bindings stay **unwired** — wiring is the follow-up chunk this plan's T39
   files.

21. **Planned (2026-07-29, panel-reviewed)** —
   `planning/specs/chunk-review-missing-objects.md`: **chunk B, runs after chunk A lands** (its
   grounding line numbers assume A's diffs). The missing value objects behind the long parameter
   lists (`Agent` accepting its already-extracted collaborators instead of six pass-through
   ingredients, `Agent::Instrumentation`, the six-member `Spawn::Seam`, the injected
   `Arm::Instrument` — constrained by `arm.rb`'s own "a base that grows every child's knobs stops
   being a seam"), the duplication extractions (provider family error/usage/response modules, the
   three byte-identical session resolvers, `RunClock::MONOTONIC` as the one monotonic default —
   monotonic only, there is no single wall clock), the `telemetry.rb` index split, `Compare::Run`
   widened to a `metrics:` hash collapsing five hand-rolled sweep folds, and the audited
   low-value-test deletions plus the two coverage gaps (`Core::Child`, `Repl::ApprovalSurfaces`).

22. **Built (2026-07-28) — the epic tier, ahead of its own approval gate.** Twelve commits, all
   on 2026-07-28, earliest `3053e49` and latest `3d16d55`
   (`git log --oneline 3053e49^..3d16d55 -- lib/lain/epic.rb lib/lain/epic lib/lain/cli/epic.rb
   lib/lain/cli/epic_queue.rb lib/lain/approval` — the plain `3053e49..3d16d55` range is 41
   commits and excludes `3053e49` itself, so it is not the thing to cite). They landed a
   content-addressed issue graph and the sign-off machinery over it: `Epic::Issue` (an issue value that cannot be addressed until it parses, carrying the
   unit's `STORED_STATUSES` and grammar), `Epic::Graph` (blocking / related / discovered-from
   edges and the queries that schedule them), `Epic::Stage`, `Epic::Document` (the markdown an
   author edits, and the digest it must preserve), `Epic::Records`, `Epic::Progress` (runtime
   truth is the journal, folded over the document), `Epic::Home` (where an epic's artifacts live
   and what may name them); plus `Approval::Gate` with `Gate::Policy` and `Gate::Adjudicator`
   (fail-closed over any artifact digest, and a deferred gate that tries to answer itself before
   parking), `Approval::SignoffQueue`, and the CLI doors `lain epic status|queue|approve|deny`
   (`exe/lain:89-100`). Measured: `lib/lain/epic.rb` + `lib/lain/epic/` 1,837 lines,
   `cli/epic.rb` 441, `cli/epic_queue.rb` 353, the sign-off half of `approval/` 1,347 — **3,978
   lines, 6.6% of `lib/`**.
   **It waits on a review that has not happened.** Its grounding doc,
   `planning/epic-orchestration.md:3`, still reads "Status: **draft — awaiting Joel's review**
   (gate 1 of the very flow it describes)", and its own next step is "`/critique`, then
   `/create-plan` for the first chunk" — neither of which ran. The open decisions that review
   owes a ruling on are recorded there: the bench-native altitude axis, deferred gates,
   default-outside artifacts, and not over-fitting work's PR process. A quarter of what shipped
   is also unwired — `Approval::Gate` + `Gate::Policy` + `Gate::Adjudicator` (+ `Evidence`,
   `Outcome`) is 1,051 lines whose only non-comment references in `lib/`+`exe/` are its own
   files, so the epic CLI does not call it either (see item 24). Until this entry has a ruling
   behind it, no single-implementation seam in the repo can be defended as "committed
   direction", which is why the record comes first
   (`planning/reviews/2026-07-29-simplification-review.md` §1.2).

23. **Next chunk — the Rust `Timeline`/`Store` parity gap, and the wiring decision.** Grounding:
   `planning/rust-parity-gap.md` (method-by-method Ruby↔`Lain::Ext`, written against the code,
   `file:line` throughout). `lib/lain.rb:77` requires the compiled extension **unconditionally**,
   so the question was never "is the extension present" — it is *which implementation a caller
   gets*, which makes this a design decision rather than an optionality problem. The gap is
   wider than "not wired": `Ext::Store#put` is monomorphic (`ext/lain/src/lib.rs:1007` takes
   `&Turn`) while the production `Store` holds six other duck-typed kinds; `Ext::Timeline#commit`
   accepts no `causal_parents:` (`lib.rs:1150-1155`, hard-coded `Vec::new()` at `:1169`) while
   four `lib/` sites pass one and a fifth splats it in; the Ext store carries an event's payload
   inline where Ruby stores two objects per turn, which the same shared-prefix spec pins at 8
   (`spec/lain/timeline_spec.rb:150`) and 4 (`spec/lain/rust/timeline_spec.rb:77`); and
   `Ext::Timeline#ancestors` returns an Array with no block form, so `Ledger`'s
   `timeline.ancestors { … }` (`ledger.rb:117`) would silently accumulate nothing. Ruby's
   `causal_meets`, `dominator_meet`, and `correlation` have no Ext counterpart at all. **Ruled
   this chunk (item 20): the dag/canonical/event bindings stay unwired.** Timeline construction
   is scattered across **16 sites in 12 files** with no factory to swap, so a wiring decision has
   to name a seam before it can name an implementation.

24. **Triage — the 30 unwired seams (the review's count; ~4,300 lines with zero production
   callers).** Inventory and per-unit line counts:
   `planning/reviews/2026-07-29-simplification-review.md` §1.1 — **re-measure before acting on
   the total**: its `compaction/prepared.rb` row says 230 where `wc -l` says 167, so the 4,353
   figure has at least one bad summand and the per-unit numbers are what to trust after a
   `wc -l`. **Confirm
   each is still needed before wiring or deleting** — this is a review item, not a build item,
   and the answer per unit is a door, a deletion, or a dated reason to keep it dark. The two
   shapes it splits into: **doors for roadmapped seams** — the sweeps are the clearest case, with
   `Bench::CLI#arm_sweep_report` (`bench/cli.rb:66`) fully implemented and reachable from no Thor
   subcommand (item 19 narrowed Deviation 8 and left this half open), and `Bench::DeciderSweep`
   (422 lines, which this file calls "the headline experiment" at § M5, above) and `Bench::DisclosureSweep`
   (332 lines with `Toolset::Disclosure` and `Tools::ToolSearch`) having no `Bench::CLI` method
   at all, so neither runs without throwaway Ruby. And **deletion candidates where a ruling
   already went the other way** — chunk 13 ruled the tool-disclosure arms out during planning and
   the machinery shipped anyway, and `Compaction::Prepared` (**167** lines by `wc -l`; the review's
   §1.1 table says 230, which does not reproduce) was built to pair with
   `Context::Compact` and was orphaned by chunk 16's migration to the derived chain; the specs
   and git history are the record either way. Also owed: a lint spec that fails a `lib/` class
   with zero `lib/`+`exe/` references and no explicit marker, so the inventory cannot silently
   regrow — `planning/specs/chunk-derived-context-timeline.md:171`'s F7 catalogue tracked nine of
   these and the count roughly doubled since.

25. **Planned (2026-07-29, panel-reviewed)** —
   `planning/specs/chunk-tool-algebra-lenses-partition.md`: the tool-use algebra chunk, from
   `planning/tool-use-algebra.md`. Four streams: the law suites the tool layer relies on but
   never proves (the exchange law behind `parallel_safe?`, posture equivalence over allowed
   calls, Toolset value equality + attenuation laws with the no-join security reading); the
   block lenses (`Response::ToolUse`, `Tool::ResultBlock` — the Env/MessageEnvelope `.wrap`
   pattern, ruled over a Hash subclass after a spike showed `Canonical.normalize` erases
   subclasses and raises on `Data`); `Lain::IntervalPartition` extracted from
   `Compaction::Strategy::Base` **plus the refinement meet and `Strategy::Composed`**
   (un-deferring derived-context follow-up 3 — Joel: building it proves the extraction); and
   the algebra registry's own follow-ups 0/0b/11 (Middleware monoid declaration, verb latch,
   `Registry#seal`). **Sequenced strictly after chunk 21's review-fixes chunk B lands** — its
   T21/T23/T32 touch the same files; re-verify all anchors against post-B main.

26. **Planned (2026-07-30, panel-reviewed)** —
   `planning/specs/chunk-epic-wiring-intake-landing.md`: wire the landed epic domain and
   close the loop item 22 left open. Three streams, 25 cards: gate wiring (Submission
   artifacts answering the gate duck, per-stage policy from `[epics.gates]`, transition
   writers the Progress fold has been waiting for, registry rebuilt from the journal,
   `Policy::Adjudicated` so deferred gates spike before parking); review intake (ownership
   baton — `Epic::Review` promise-per-generation, shadow-copy diff as journaled events,
   `:LainReviewDone`, extmark annotations landing as `annotation` records); external state
   (Forge intent/outcome records with a Salvage-shaped reconcile, anchor-only handback,
   `Forge::Gh` executor pair, branch promotion, serial landing resumable after a crash,
   `lain epic land [--resume]`). Rulings recorded: extmark side-channel over in-text
   markers; serial landing first, stack cascade deferred to its own chunk (GitHub docs
   confirm every merge-button method rewrites SHAs); repo-mode gitignore stays as-is.
   Panel: ruby roster plus the standing algebra seats (Kmett, Milewski, Wadler, Elliott,
   Matsakis), APPROVE-WITH-FIXES applied. Refreshes `planning/epic-orchestration.md` (T12)
   against the 2026-07-30 critique (`.critique-epic-orchestration.md`).
   **26 of 27 cards landed as of 2026-08-02** (T26, the prose review baseline, was split out
   of T23 during execution; T27 was added when T23's "registration line" turned out to be a
   card). **T20 is deferred by ruling** — nothing constructs a chat actor or holds a
   `WorkerHandoff`, so there is nothing to hand back yet. **T23 landed as `c803437`**:
   `Tools::RequestReview`, the reader that finally makes `annotation` records non-write-only,
   via a journal decorator between `Review` and the journal rather than by widening
   `Token#resolve`. Its panel found a wedge worth naming — a raise between `Review#open` and
   the settle left the baton held *and journaled*, so a restarted lain refused every write to
   that epic with no user-reachable escape. The release line ruled on is **whether the human
   has been told**; before that the baton comes back, from `await` onward the human genuinely
   holds the file. Two second-order findings came out of the same seam and generalize past
   this card: `Async::Stop` descends from `Exception`, so `rescue StandardError` around an
   awaiting fiber has a hole in it, and an `ensure` that raises *replaces* what it was
   cleaning up after. **T27 wires the tool into a chat** — `wiring.rb` had zero `Epic::`
   references, so registering it forced the unanswered question of where a chat's epic slug
   comes from.
   **The 2026-07-30 resume was reviewed and repaired on 2026-08-02.** Thirteen cards had
   landed in five commits with no commit bodies, written without isolation, TDD, or a panel;
   three panels returned REQUEST-CHANGES on all of it. What they found is recorded in the
   plan doc, and the headline items are worth carrying here because each is a *class* of
   defect this bench should be able to name: a spec that called `Thor.start` inside an
   example **silently truncated the whole suite** for five commits (1160 examples, 0
   failures, nonzero exit, where 7728 was the truth — the count is the tell, never the
   failure list); `Forge::Landing` **discarded the promotion's verdict** and would merge a
   branch standing at a stranger's commit as the issue's approved work; the annotation seam
   and `:LainReviewDone` had **never once worked** while carrying green specs on both sides
   of them; `Supervisor#stop` **lost a crashed worker's commits**; and two `Metrics/*`
   suppressions stood where CLAUDE.md forbids them outright. T24 was rebuilt from its card
   by a TDD sub-agent (`Plan`/`Step`/`Evidence`, nine mutations red); the rest took targeted
   fix passes. The five commits were then rewritten as one commit per card with real bodies
   — `backup/codex-range-pre-rewrite` and `backup/pre-history-rewrite` keep the originals.

27. **Planned (2026-07-30, panel-reviewed)** —
   `planning/specs/chunk-question-sets-and-the-answer-document.md`: `ask_human` becomes a
   **question set** — one tool call carrying several questions, each a markdown body with a
   closed option list, answered as a folded markdown document the human edits in place (tick a
   checkbox, indented prose beneath an option for why, `:w` to submit). 17 cards. The document is
   the artifact and the surfaces are ways of opening it: a new `acwrite` `lain://question` buffer
   modelled on `lain://compose`, `<CR>` from the inbox to open a set, autoload-the-next on
   submit; the TTY always answers, in free text, and only its pointer text changes when an editor
   is attached. Widens `Tool::Input` with array and nested-object fields (migrating `TodoWrite`
   off its hand-written schema — two callers, and it closes the schema/validation drift that
   file's header claims not to have), and reverses one capability policy on purpose: subagents
   may now ask the human, which is what puts several sets in the inbox at once. Grounding found
   **five** defects where the draft listed three; the two it added are aliasing bugs on
   `@last_question` (the A event's causal parent, and the delivery commit's retired digest) —
   the second retires the wrong question, which presents as a haunted inbox rather than a stale
   digest. Rulings recorded: the parser is handed the set it parses, so a fenced diff or mermaid
   block is skipped by literal match rather than by a fence tracker (`Epic::Document` *refuses*
   fences and could not be copied here); the question buffer holds exactly one set, which makes
   `RequestBuffer`'s clobber defect unreachable rather than defended; `x` ticks on an option line
   and is vim's `x` everywhere else; submitting is never blocked and an unanswered question says
   so; no answer timeout, deregistration riding the supervisor lease. Panel: ruby roster,
   REQUEST-CHANGES → all seven blockers applied.

28. **Planned (2026-08-02) — how lain merges its own workers' work.**
   `planning/merge-conflict-handling.md`. Today `Worktree::Handback` merges one worker at a time
   (`handback.rb:486`) and `WorkerHandoff` spawns a `merge_resolver` per conflict. Both costs are
   paid N times, and the larger one is not the resolver — it is the full-suite gate against each
   merged tree. The founding ruling (Joel): **a worker's commits are never optional.** Work worth
   planning is worth merging, so deterministic first and tokens when deterministic will not do it;
   `Retain` is for the crash cases (OOM, the 4.0.5 cvar segfault, kernel panic, power loss), where
   the honest answer is to anchor and leave recoverable rather than discard.
   **Shape: partition, batch the resolver, verify once** — probe each worker ref with
   `git merge-tree --write-tree`, land the clean subset sequentially onto an integration ref
   (journaling each `Outcome`, so per-worker attribution survives one suite run), spawn ONE
   resolver over the aggregate conflict set, then gate on a single suite run. Sibling conflicts
   are *correlated* — N workers touching one manifest produce N instances of one conflict — so
   the aggregate is both cheaper and better-posed than N hunks in isolation. Explicitly **not**
   octopus: verified on git 2.43, it refuses wholesale on any conflict and merges nothing. A
   single N-parent commit carrying a resolved tree is still available via `git commit-tree` (also
   verified, 4 parents), at the cost of a combination nothing tested and lost bisect.
   **Ruling: merge tuning is lain's CLI flags, never ambient git config.** `-X patience` /
   `--diff-algorithm=histogram` (Myers misaligns list-shaped files and invents conflicts that are
   not semantic) and `--conflict=zdiff3` (markers carrying the merge BASE, so a resolver sees what
   each side changed rather than two final states) are passed by lain and journaled with the
   intent. Git config is machine state: it governs whoever is working in the checkout, says
   nothing about the lain loop, and would make lain's behaviour unreproducible on a machine
   nobody has configured.
   **`.gitattributes merge=union` is a knob `Lain::Friction` proposes, never applies.** M1's
   observer is for the lain USER and folds a session Journal with no model call; handback outcomes
   already name conflicted paths, so "which paths conflict repeatedly, across how many distinct
   workers, by ADDITION rather than by edits to shared lines" is answerable from existing records.
   It must propose with evidence because union is wrong for ordered files, and this repo holds the
   exemplar: `lib/lain.rb` is a topological load-order manifest, so union keeps both requires in
   the wrong ORDER and the symptom is a load-time `NameError` out of a merge git called clean.
   **The custom LLM merge driver is its own card** — `.gitattributes` routing a path to a driver
   git invokes only for files that actually conflict, scoped to one file with its base, composing
   with `rerere` and per-path `union`, and working for rebase and cherry-pick too. Its costs are
   real: an unbounded provider round trip inside `git merge` is the footgun `WorkerHandoff`
   already names when it refuses to spawn while unwinding, so it needs a deadline and a loud
   deterministic fallback; and a driver sees one file and no suite, so the suite gate stays the
   real verification.

---

## Map of the documents

- **Architecture & why:** `~/.claude/plans/jiggly-greeting-avalanche.md` (approved).
- **Remaining committed work** (task-level units, acceptance criteria, dependency map):
  `planning/remaining-work.md`.
- **Exploratory ideas:** `planning/` — `research-scan-2026-07.md` (survey + prioritization),
  `hn-harness-overhead-2026-07.md` (the field's cache/overhead argument, Tier-1 items folded into
  `specs/cache-economics.md`), `hn-agent-landscape-2026-07.md` (broader HN scan — graders,
  guardrail stack, control-flow axis, Journal-native retrieval; Tier-1 → `specs/graders.md` + M3c/M5/M6
  fold-ins), `orchestration-experiments.md`, `first-class-concepts.md`, `crdt-exploration.md`,
  `merge-conflict-handling.md` (how lain merges its own workers' work — item 28).
- **Grounding sources:** `references/` — `INDEX.md`, `SCOPE.md`, `memory-and-retrieval.md`,
  `oss-inspiration.md`, 15 papers in `papers/rst/`, reference impls in `repos/`.
- **Origin brainstorm:** `TODO.md` — the raw idea list this ROADMAP reconciles.
