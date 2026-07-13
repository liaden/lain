# Corpus scope — Lain study bench

The questions this `references/` corpus must answer. Lain is an agent harness built as a
**study bench**: the deliverable is making context strategies, tool designs, orchestration
tactics, and memory/retrieval *swappable, observable, and comparable*. The corpus grounds the
`planning/` docs in primary sources and reference implementations, so design bets rest on
evidence, not vibes.

## Questions

### Harness evaluation & the founding thesis
- Is "the harness, not the model, determines the score" a defensible claim? What measures it?
- How do we quantify harness-induced variance when we hold the task fixed and vary one seam?

### Orchestration (see `planning/orchestration-experiments.md`)
- When does multi-agent orchestration beat a single-threaded agent, and when does it lose?
- What concrete orchestrator designs exist (ledgers, handoffs, tree search) and how do they map
  to Lain's O(1) fork, worktrees, and graders?
- Can the strategy be selected *per task* — a learnable router?

### Context engineering & code-mode (see `planning/first-class-concepts.md`)
- What is the measured cost of long context (context rot), and what does it imply for pruning?
- Does executing code beat emitting JSON tool calls, and by how much (tokens, accuracy)?
- How is context/tool *disclosure* (upfront vs. deferred vs. code-API) a swept axis?

### Memory & retrieval (see `planning/research-scan-2026-07.md`, item 3)
- What are the distinct memory abilities a bench must grade (extraction, multi-session, temporal,
  knowledge-updates, abstention)?
- Which public benchmarks can serve as memory graders?
- What retrieval architectures exist (verbatim + symbolic index, temporal KG, hybrid BM25+vector),
  and which fit Lain's content-addressed, PHI-constrained, cache-stable posture?
- Where should Lain's content-addressed/versioned memory *win* rather than merely claim elegance?

### Prompt / tool-description optimization
- Can the swept axes be *searched*, not just measured (reflective evolution)?

## Topic taxonomy

1. **harness-evaluation** — the thesis, benchmarks, harness-variance.
2. **orchestration** — single vs. multi, ledgers, tree search, adaptive routing.
3. **context-and-code-mode** — context rot, CodeAct, disclosure, IVM framing.
4. **memory-and-retrieval** — abilities, benchmarks, architectures, temporal KGs.
5. **optimization** — reflective prompt/tool-description evolution.

## Non-goals

- General LLM-training or fine-tuning literature.
- Framework tutorials without a transferable mechanism.
- Anything requiring cloud memory, telemetry, or sending PHI off-machine (violates Lain's
  constraints; catalog for contrast only).
