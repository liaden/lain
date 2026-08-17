# planning/

Exploratory idea space for Lain. **Not committed scope** — the approved, committed design lives in
`~/.claude/plans/jiggly-greeting-avalanche.md`, and the milestone table there is the source of truth.
These documents are representations of potential directions, each grounded in external evidence or a
concrete mechanism, to be pulled into the plan (or dropped) deliberately.

| Doc | What it is |
|---|---|
| [`research-scan-2026-07.md`](research-scan-2026-07.md) | Survey of OSS harnesses, papers, and HN, filtered to what is *additive* to the plan — plus a **Prioritization signals** section on what the literature says to re-weight. |
| [`hn-harness-overhead-2026-07.md`](hn-harness-overhead-2026-07.md) | Practitioner evidence on prelude size, **cache-write** cost, and the subagent bootstrap tax (HN 48883275). Yields a fork-worker arm, cache-sibling preludes, a tool-repair middleware, and the discipline that **prelude size is an anti-metric**. |
| [`orchestration-experiments.md`](orchestration-experiments.md) | Swappable orchestration *arms* for the bench (single-thread, orchestrator-worker, dual-ledger, handoff, LATS, MoA, adaptive router), with a proposed experiment order. |
| [`first-class-concepts.md`](first-class-concepts.md) | New *nouns* the Ruby+Rust substrate makes possible — context-as-IVM, content-addressed handles, git-for-its-mind, attested context, structural memory, self-crystallizing toolset, the Workspace Timeline. |
| [`crdt-exploration.md`](crdt-exploration.md) | Where CRDTs fit (and don't): the Timeline is already a CRDT; the real opening is **subagents co-editing one live file** (blackboard + awareness feed + op-log-as-journal). Also an orchestration arm, kept separate for emphasis. |

## Detailed specs (`specs/`)

Precision specs (acceptance-criteria style, like `remaining-work.md`) for individual `[exp]` items,
produced in the precision pass. Each is linked from its ROADMAP bullet.

| Spec | What it pins |
|---|---|
| [`specs/timeline.md`](specs/timeline.md) | The content-addressed event log + its projections (prompt, mailbox, workspace, provenance); the 4-kind list; the M4 Rust port. |
| [`specs/event-schema.md`](specs/event-schema.md) | The event envelope + git-style render/causal edges — the event-sourcing foundation. |
| [`specs/orchestration-model.md`](specs/orchestration-model.md) | Fibers (`Async`), event-sourced mailboxes, promise-`ask_human`, one-shot + actor subagents, role catalog, supervision-as-replay. |
| [`specs/prompt-slots.md`](specs/prompt-slots.md) | Markdown-partial holes at `.lain/slots/`, rendered in a locked pure binding. |
| [`specs/cache-aware-compaction.md`](specs/cache-aware-compaction.md) | Compact only when the prompt cache is cold; soft-defer + hard-cap. |
| [`specs/cache-economics.md`](specs/cache-economics.md) | Cache-**write** attribution (Request digest chain, rewrite depth), the breakpoint-cap bug fix, the spawn-prefix-strategy axis (fresh / fork / sibling), stagger scheduling, prelude decomposition, price-model honesty. |
| [`specs/grader-from-gherkin.md`](specs/grader-from-gherkin.md) | Gherkin as a transient IR → tests in the lain user's framework as the grader. |
| [`specs/oracles.md`](specs/oracles.md) | Cheap one-shot deciders (heuristic/ollama/haiku/inline/human) behind the `ask_human` promise seam — typed answers, journaled for replay, tail-or-nothing placement; the decider-locus sweep; DCP's mechanical combinators. |
| [`specs/bedrock-provider.md`](specs/bedrock-provider.md) | AWS Bedrock (Mantle) provider arm on the work bearer token: `Provider::Bedrock` SDK oracle + `Provider::BedrockRaw` on the forked transport, `:bedrock` tag gating, cassette hygiene. Panel-reviewed 2026-07-15. |
| [`specs/memory-read-path.md`](specs/memory-read-path.md) | The 5-3.1/5-3.2 close-out: manifest reminders + `memory_read` wired into the live session, `Session::Loader` replaying per-turn memory roots (recall-as-of-turn-N at the bench), root-keyed Bm25 build cache. Panel-reviewed 2026-07-15. |
| [`specs/chunk-meet-supervision-fanout-interface.md`](specs/chunk-meet-supervision-fanout-interface.md) | The 2026-07-17 chunk plan: TL-3 ruled (three operators; research in [`dominator-meet-research-2026-07.md`](dominator-meet-research-2026-07.md)) + T25 re-port, R.1–R.5 + residuals, Workspace Timeline + OM-6 supervision, CE-4/CE-5 fan-out, interface HUD/inbox/approvals. |
| [`specs/plan-shaped-compaction.md`](specs/plan-shaped-compaction.md) | Compaction seams as explicit, author-editable plan content with size estimates; mostly-deterministic step-closure records; execution shape (linear+rewrite vs fork-per-step) as a swept policy; the seam EV decision, Journal-calibrated. |
| [`specs/structural-code-search.md`](specs/structural-code-search.md) | **Shipped 2026-07-18.** ast-grep + tree-sitter structural search — two `ext/lain` bindings behind five read-only tools (`ast_search`, the `ast_dump`/`test_pattern` inspect pair, `code_outline`, `file_symbols`), catalog seeded from `ag_helpers`. The M6 *one Rust-implemented `Tool`*. Records the deferred role-catalog wiring + python `file_symbols` and the follow-ups. |
| [`specs/chunk-review-correctness-cost.md`](specs/chunk-review-correctness-cost.md) | **Chunk A of the 2026-07-29 simplification-review fixes** (panel-reviewed): the shipped defects, verified performance fixes (restructure-over-cache by ruling), Rust safety/idiom prerequisites, a `Tools::Grep` lain-core RPC, and the T39 record-keeping card (epic ROADMAP entry, `rust-parity-gap.md`, unwired-seam triage). ROADMAP item 20. |
| [`specs/chunk-review-missing-objects.md`](specs/chunk-review-missing-objects.md) | **Chunk B — runs after chunk A lands**: missing value objects (`Agent` collaborators, `Instrumentation`, `Spawn::Seam`, injected `Arm::Instrument`), the duplication extractions, `telemetry.rb` split, `Compare::Run` metrics widening, test deletions + the two coverage gaps. ROADMAP item 21. |
| [`specs/chunk-qa-defects-and-replay.md`](specs/chunk-qa-defects-and-replay.md) | **The 2026-08-17 manual-QA fixes plus a replay harness.** All seven findings F1–F7, two of which are *silent corruption of content-addressed history*: the Ollama assembler splices an abandoned HTTP attempt onto its retry, and the Anthropic one keeps orphaned block indices a retry never reopens (a half-finished `tool_use` becomes a phantom tool call). Also the 20-minute silent hang behind them (retry amplification, and Ollama journalling no retries at all — exactly as `ollama.rb:43-47` predicted), `web_fetch` dying on any non-ASCII page, compaction firing on a *provisional* window and rewriting history three times, and the survey advertising an epic-surface command it can never answer. Then the tests: ollama VCR cassettes at the HTTP boundary and a whole-run replay — plus a severable fake socket, because WebMock hands a body back as one chunk and so a cassette **cannot** catch the splice bugs. 15 cards, 4 waves; panel-reviewed 2026-08-17 (six blockers, all confirmed and fixed — see the plan's *What the panel changed*). Research in [`../qa-findings-research-2026-08.md`](../qa-findings-research-2026-08.md). |
| [`specs/chunk-poc-integration-fixes.md`](specs/chunk-poc-integration-fixes.md) | **The 2026-08-15 manual-POC fixes**, all eleven of which were GREEN in the suite: the chat REPL wedge (`HumanReplies#surfaces` has one caller, `Repl#respond`, so a human-typed skill spawn's `ask_human` parks forever) and the dangling causal parent it leaves; the free summarizer tier gated behind a 4096-byte model-cost threshold; the span tier unrouted; `Oracle::Model` never asking for structured output; `bench arms` scoring 0 with no default FILE/END system prompt; DualLedger settling on the *grader* (oracle leakage, 18× its controls' tokens); the 8192 context-window denominator; `num_batch`/`num_ctx` never sent; `capability_degraded` never emitted; survey rows resolved against the wrong root and never registering a read. Plus a vacuous-spec prune and **T18, a mechanical AST guard** against assertion shapes that cannot fail — because most of this suite is LLM-written. 18 cards, 4 waves. |

Cross-cutting themes:

- **The harness is the variable** — the 2026 literature independently validates Lain's founding
  thesis, and Lain is unusually equipped to *quantify* harness-induced variance. (research-scan)
- **Everything conditional wants a decision boundary** — orchestration and context strategy both
  resolve to "for this task class, use X," which a bench producing distributions can supply where
  the papers only assert it. (orchestration-experiments)
- **Content-addressed + pure + a coding shell** is the substrate that turns cognition itself into a
  replayable, structurally-shared value. (first-class-concepts)
