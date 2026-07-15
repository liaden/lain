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
| [`specs/plan-shaped-compaction.md`](specs/plan-shaped-compaction.md) | Compaction seams as explicit, author-editable plan content with size estimates; mostly-deterministic step-closure records; execution shape (linear+rewrite vs fork-per-step) as a swept policy; the seam EV decision, Journal-calibrated. |

Cross-cutting themes:

- **The harness is the variable** — the 2026 literature independently validates Lain's founding
  thesis, and Lain is unusually equipped to *quantify* harness-induced variance. (research-scan)
- **Everything conditional wants a decision boundary** — orchestration and context strategy both
  resolve to "for this task class, use X," which a bench producing distributions can supply where
  the papers only assert it. (orchestration-experiments)
- **Content-addressed + pure + a coding shell** is the substrate that turns cognition itself into a
  replayable, structurally-shared value. (first-class-concepts)
