# Research scan — external ideas worth pulling in (2026-07)

> A survey of open-source harnesses, recent papers, and HN threads, filtered for what is
> *additive* to `jiggly-greeting-avalanche.md`. Lain's plan is already unusually complete: it
> covers subagents, dry/live replay, graders, content-addressed memory, code mode, prompt-cache
> stability, and worktree orchestration. So this memo does **not** re-pitch those. It records the
> deltas — ideas the plan does not yet have, and external *evidence* that sharpens ideas it does.
>
> Each item is tagged with the seam it lands on and the milestone it fits. Ranked by leverage for
> the bench's actual thesis: *make strategies swappable, observable, and comparable.*

---

## The meta-finding: the literature now agrees the harness is the variable

Three 2026 papers independently argue that agent scores swing with the **scaffold**, not the
model — the same model posts very different numbers under two harnesses because the harness
controls how tools are exposed, how errors surface, and how many retries are allowed. "Stop
Comparing LLM Agents Without Disclosing the Harness," "Harness-Bench," and a paper measuring
"harness-induced belief divergence" all land on the same point.

This is Lain's founding thesis, now externally validated — and it suggests a *contribution*, not
just a design. Lain is unusually well-positioned to **quantify harness-induced variance**: it has
byte-diffable dry replay, swappable Context/Provider/Toolset seams, and distributional `Compare`.
Almost nobody can hold the task fixed and vary one scaffold dimension at a time. That is exactly
what "disclose the harness" asks for and cannot currently deliver. Worth framing an early
experiment (and possibly a writeup) around it.

Sources: [Stop Comparing LLM Agents Without Disclosing the Harness](https://arxiv.org/pdf/2605.23950) ·
[Harness-Bench](https://arxiv.org/html/2605.27922v1) ·
[Harness-Induced Belief Divergence](https://arxiv.org/html/2607.04528v1) ·
[Inside the Scaffold: a taxonomy of coding-agent architectures](https://arxiv.org/pdf/2604.03515)

---

## Tier 1 — high leverage, aligned with the thesis

### 1. Turn the swept axes into a *search*, not just a measurement — GEPA / DSPy

**Delta.** The plan *measures* which tool description or context strategy wins. GEPA (Reflective
Prompt Evolution) *searches* for the winner: it mutates prompts/tool-descriptions, scores each
candidate with a metric, reads back **textual feedback from the trace** (not just a scalar
reward), and keeps a **Pareto frontier over individual instances** rather than collapsing to one
average. The paper claims it beats RL-style optimization on several tasks.

**Why it fits Lain specifically.** GEPA needs exactly three things Lain already has:
- a metric → `Grader::Fixture` / `Grader::Rubric`
- per-instance textual feedback → the **Journal** is a trace of *why* a run failed
- cheap candidate evaluation → dry replay is free and deterministic; live replay gives
  distributions.

GEPA's "Pareto frontier over instances" is the principled version of the plan's
**speculative branching / beam search** — instead of "fork N, keep the best average," keep the
set that is best *somewhere*, which is how you avoid overfitting a tool description to one task.
This upgrades the bench from a ruler into an optimizer, and it targets the plan's headline claim
directly: *prove which tool description raised the correct-call rate — then let the bench find
it.*

**Lands on:** `Grader`, `Compare`, the Toolset/Context axes. **Milestone:** M3c (bench) →
sharpened at M6. Start with tool-description optimization on a `Grader::Fixture` task; it needs no
new infrastructure, only a candidate-generation loop over existing seams.

Sources: [GEPA paper](https://arxiv.org/pdf/2507.19457) · [gepa-ai/gepa](https://github.com/gepa-ai/gepa) ·
[MAS-PromptBench — when prompt-opt helps multi-agent systems](https://arxiv.org/pdf/2606.23664)

### 2. A new swept axis: *how tools are disclosed* — code-mode + progressive disclosure

**Delta.** The plan has "code mode" (`eval_ruby` against a persistent binding) as one M5 item.
2025–2026 turned this into a measured, load-bearing pattern with hard numbers, and revealed a
*second* dimension the plan doesn't name: **tool disclosure**.

Two findings, one axis:
- **Tools-as-code (CodeAct / "Code Mode").** Anthropic's "code execution with MCP" reports up to
  **98.7%** context reduction by exposing tools as a code API the model orchestrates in one
  execution step, with only the final result returning to context — intermediate results never
  hit the window. Cloudflare's "Code Mode" and Apple's CodeAct paper corroborate. This is the
  quantitative case for the plan's code mode, and the "intermediate results never enter context"
  property is *the same* property the plan already prizes in subagents.
- **Progressive tool disclosure.** Anthropic's Agent Skills (open standard as of 2025-12-18,
  adopted within weeks by OpenAI/Google/GitHub/Cursor) load a tool/skill's full definition
  *only when its one-line description matches the task* — `SKILL.md` frontmatter first, body on
  activation, bundled files on demand. This harness's own `ToolSearch` (deferred tool schemas) is
  the same idea. Dumping every tool's JSON schema upfront is a choice, not a law.

So "tool disclosure" becomes a **swept axis** the plan is missing: `all-upfront-JSON` vs.
`searchable/deferred` vs. `code-API`. Each renders a different `Request`; each is
grader-comparable; the token deltas are enormous. This slots cleanly into the plan's insight that
"a tool's result shape *is* context" — extended to "a tool's *definition* shape is context too."

**Lands on:** `Toolset`, `Context#render`. **Milestone:** M5 (code mode already lives here); add
disclosure as a Context combinator so it is swept, not hardcoded. Note the plan's tool *tiers*
(structured / pre-canned / free-form) are orthogonal to disclosure — a tier-1 tool can still be
disclosed three ways.

Sources: [Anthropic — code execution with MCP](https://www.anthropic.com/engineering/code-execution-with-mcp) ·
[Anthropic — Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills) ·
[Apple — CodeAct](https://machinelearning.apple.com/research/codeact) ·
[langgraph-codeact](https://github.com/langchain-ai/langgraph-codeact) ·
[Code Actions as Tools — Krasser](http://krasserm.github.io/2025/12/16/code-actions/)

### 3. A ready-made memory grader and a retrieval arm — LongMemEval + MemPalace

**Delta.** The M6 retrieval sweep (Manifest / BM25 / Vector / Hybrid / Graph) has no named grader
and no external baseline. Joel pointed to [LongMemEval (2410.10813)](https://arxiv.org/abs/2410.10813);
it supplies both.

- **LongMemEval as `Grader::Fixture` for memory.** 500 questions over five memory abilities:
  information extraction, **multi-session reasoning**, **temporal reasoning**, **knowledge
  updates**, and **abstention**. Two of these are exactly where Lain's design should *win rather
  than merely claim elegance*:
  - **Knowledge updates** — a superseded fact in Lain is a new root hash; the old value stays
    content-addressed and reachable. Vector-DB memory overwrites and loses the history. The bench
    can show this as a score, not a paragraph.
  - **Temporal reasoning** — the Journal records the live memory root *per turn*, so "what did I
    believe at turn N" is answerable by construction.
  - **Abstention** — medical synthesis must know when to say "not in memory." Worth a first-class
    metric, not an afterthought.
- **MemPalace as a retrieval arm.** Local-first, **verbatim** (no lossy summarization), structured
  scoping (wings→rooms→drawers), **zero-API** retrieval hitting 96.6% R@5 on LongMemEval. Its
  posture — verbatim, local, content-scoped, no cloud — is a near-exact match for the plan's PHI
  constraint (*"PHI must never leave the machine / enter the wire"*). Add it as a concrete arm in
  the sweep alongside BM25 and Hybrid; its structured-scope idea also generalizes the plan's
  `[[wikilink]]` Graph index.

**Lands on:** `Memory::Index`, `Grader::Fixture`. **Milestone:** M6. This is the most directly
transferable artifact in the project (medical recall) getting a public benchmark to sweep against.

Sources: [LongMemEval](https://arxiv.org/abs/2410.10813) · [MemPalace](https://github.com/MemPalace/mempalace) ·
[State of AI Agent Memory 2026 — mem0](https://mem0.ai/blog/state-of-ai-agent-memory-2026)

---

## Tier 2 — strong, needs a small new seam or an experiment

### 4. Make the multi-agent debate empirical (Cognition vs. Anthropic)

The industry's sharpest open question — Cognition's "Don't Build Multi-Agents" (single-threaded,
continuous context; the "Flappy Bird lost its art style in delegation" failure) versus Anthropic's
"90.2% improvement from orchestrator + 3–5 subagents." Nobody has settled it because it is settled
by *task structure*, not in general. **Lain can settle it per task**: hold the task fixed, run a
single-threaded linear agent against the orchestrator-with-worktrees the plan already builds, score
both with the grader over distributions. The "lost the framing" failure is a detectable
context-loss event in the Journal. Anthropic's concrete priors are testable: 1 agent for simple
fact-finding, 2–4 for comparison, 10+ for complex; "token usage explained 80% of performance
variance"; cost ~15× a single thread. This is a headline experiment, not a new subsystem — it
reuses M5 orchestration.

**Lands on:** orchestration + `Compare`. **Milestone:** M5, as the first orchestration experiment.

Sources: [Cognition — Don't Build Multi-Agents](https://cognition.com/blog/dont-build-multi-agents) ·
[Anthropic — multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system) ·
[LangChain — how and when to build multi-agent systems](https://www.langchain.com/blog/how-and-when-to-build-multi-agent-systems)

### 5. Context rot as a *measured quantity*, not a belief

Chroma's "Context Rot" study (18 frontier models incl. Claude 4): quality degrades as input grows
**even below the window**; "lost in the middle" costs 30+ points when the fact lands in positions
5–15 of 20; and — counterintuitively — *coherent* input degrades attention **more** than shuffled
input. RULER puts effective context at **50–65% of advertised**. Two consequences for Lain:
- The Prune/compaction combinators (M3c) get an empirical justification and a *metric*: plot
  grader-score against input tokens for a given Context strategy and watch it decay. That decay
  curve is a first-class bench output no one publishes per-strategy.
- Recall-at-the-tail (the plan places it there for **cache** reasons) gains a **second**
  independent reason: end-of-context attention. A position-aware combinator is now motivated
  twice.

**Lands on:** `Context` combinators, `Compare`. **Milestone:** M3c. Cheap — it's an analysis over
runs you already record.

Sources: [Chroma — Context Rot](https://www.trychroma.com/research/context-rot) ·
[ZenML LLMOps writeup](https://www.zenml.io/llmops-database/context-rot-evaluating-llm-performance-degradation-with-increasing-input-tokens)

### 6. Offline memory consolidation — "sleep-time compute" / "dreams"

TODO.md already gestures here ("summarize/compact after the cache is cold," "decide whether to
save a memory"). The named pattern: Letta's **sleep-time compute** (shift work off the
user-facing path into idle time) and Anthropic/Xiaomi **"dreams"** — take a memory store + 1–100
prior sessions and emit a *new* store with duplicates merged, stale/contradicted entries replaced,
and fresh insights surfaced. Lain's content-addressed memory makes this **auditable in a way a
vector DB cannot**: a dream is a batch re-index that bumps the root hash, so you can `diff` the
memory root before/after and replay any turn against the pre-dream snapshot. "Was this insight in
memory before the dream, or hallucinated by it?" becomes a content-address query. Also relevant:
MiMo's **rebuild injection** for the TODO's resume/auto-compact item — reconstruct a budgeted
prompt from task list + checkpoint + recent verbatim turns + memory indexes rather than rereading
everything.

**Lands on:** `Memory`, and the resume/compaction TODO items. **Milestone:** M6 (dreams);
resume/rebuild is nearer-term M2/M5.

Sources: [Letta sleep-time compute / "why agents dream"](https://kenhuangus.substack.com/p/why-ai-agents-are-starting-to-dream) ·
[Agents that run while I sleep — HN](https://news.ycombinator.com/item?id=47327559)

---

## Tier 3 — worth a decision, mind the tension

### 7. Speak Agent Client Protocol (ACP) for the editor frontend

Zed's ACP is an open JSON-RPC 2.0 standard for agent↔editor; by June 2026, ~50 agents and
multiple editors implement it, and Zed 1.0 ships parallel agents in one window. The plan's M4
Neovim work already speaks msgpack-RPC over a Unix socket — ACP is the same shape, standardized.
Implementing ACP would (a) make Lain's frontend a genuinely swappable seam, (b) get Zed and other
editors "for free," and (c) let others point *their* editor at Lain's bench.

**Tension to resolve, not paper over:** the plan's one irreplaceable interface bet is the
**editable `lain://request` buffer** ("edit it, `:LainResend`, watch what changes"). ACP may not
express that; it standardizes the *common* surface, which is exactly the surface Lain wants to go
*beyond*. Recommendation: evaluate ACP as the **baseline** frontend transport (wide reach, low
effort given the RPC is already planned), and keep the editable-request buffer as a Lain-specific
extension. Do not let ACP's lowest-common-denominator shape constrain the bench's differentiator.

**Lands on:** `Frontend`. **Milestone:** M4, as a transport option beside the Neovim plan.

Sources: [Zed — ACP](https://zed.dev/acp) · [ACP Registry is live](https://zed.dev/blog/acp-registry) ·
[ACP vs MCP — Morph](https://www.morphllm.com/agent-client-protocol)

### 8. Auto-compaction with structured handoff across context resets

OpenHarness / OpenHands ship **auto-compaction that preserves task state and channel logs across
compression**, enabling multi-day sessions. The harness-engineering literature frames the general
pattern cleanly: **context resets + structured handoff artifacts + phase gates** as a distinct
layer above prompt/context engineering. This is vocabulary and prior art for TODO.md's "resume
after crash" and "idle autocompact" items, and it maps onto seams Lain already has: the Workspace
(sent-not-stored todos survive a reset), the Journal (replayable), and content-addressed
checkpoints (a compaction is a new node, not a destructive edit). The distinctive Lain angle:
because compaction is a Context endomorphism and the pre-compaction Timeline is content-addressed,
a compaction strategy is itself a **swept, dry-replayable axis** — you can score "did this
compaction lose the thing the next turn needed?" against the full pre-compaction context.

**Lands on:** `Context` (compaction combinator), Workspace, resume. **Milestone:** M2 (record) →
M3c (sweep).

Sources: [awesome-harness-engineering](https://github.com/ai-boost/awesome-harness-engineering) ·
[HKUDS/OpenHarness](https://github.com/HKUDS/OpenHarness) ·
[Building AI coding agents for the terminal — scaffolding & context engineering](https://arxiv.org/html/2603.05344v1)

---

## Deliberately excluded (already in the plan, or low-fit)

- **Subagents, dry/live replay, LLM-as-judge, speculative branching, code mode, content-addressed
  memory, prompt-cache stability, worktree orchestration** — all already in
  `jiggly-greeting-avalanche.md`. External evidence for them is folded into the items above rather
  than re-pitched.
- **AGENTS.md** convention — Lain already has CLAUDE.md; no gain.
- **Generic vector-DB memory frameworks (mem0, cognee, Memori)** — the plan's content-addressed,
  replayable memory is a *stronger* substrate; these are worth reading for their retrieval eval
  numbers, not their architecture.
- **On-device / local-model agents** — interesting for the PHI/embedding-provider open question
  (a local embedding model keeps PHI off the wire), but that decision is already flagged in the
  plan's open questions.

---

## Prioritization signals — what the literature says to re-weight

The findings above don't overturn the milestone order in `jiggly-greeting-avalanche.md`; they mostly
*reinforce* it (measurement before seams, concurrency deferred). But four carry real ordering weight.

**Reinforces "measure first."** Anthropic's finding that *token usage alone explained 80% of
performance variance* means M2's cost accounting is not bookkeeping — it is the cheapest available
performance proxy. Do it thoroughly (aggregated over unique digests, retries made visible), because
it de-risks every later experiment.

**Promote tool-disclosure from M5 → M3c.** Code-mode's ~98.7% token reduction, multiplied by
"tokens predict 80% of performance," makes the *disclosure* axis (`upfront-JSON` / `deferred` /
`code-API`) plausibly the highest-leverage cheap change in the plan — and unlike code-*execution*,
it needs no Rust exec boundary. It is pure `Context`/`Toolset` work and belongs in the bench's first
swept axes.

**Start the memory sweep with `Manifest` as soon as the bench exists.** The plan calls memory "the
highest-value thing the bench ever measures" yet schedules the sweep at M6. `Manifest` needs no
index, no embeddings, and is cache-stable — so the sweep can *begin* the moment M3c lands, with the
two arms (Manifest, BM25) that require no new infrastructure. Don't wait for Vector to start
measuring the thing you care about most.

**After the bench, prefer the optimizer over the Rust port.** Once graders + replay exist, GEPA-style
search is thesis-delivery (it *finds* the winning tool description); the Rust `Timeline` port is
elegance/perf ("check the reason," per the Rust rule) and is not on the critical path to proving the
bench works. If forced to choose between M4's port and the optimizer, deliver the thesis first.

**Meta.** The "disclose the harness" experiment needs only M2 + M3a (measurement + replay), not the
full M3c — so the harness-variance study can run *earlier* than the milestone structure implies.

## Suggested next actions

1. **M3c:** prototype GEPA-style tool-description search over one `Grader::Fixture` task — it needs
   only a candidate loop over the existing bench (item 1).
2. **M3c:** add **tool disclosure** (`upfront-JSON` / `deferred` / `code-API`) as a Context axis and
   sweep the token/grader deltas (item 2).
3. **M6:** adopt **LongMemEval** as the memory grader and add **MemPalace** as a retrieval arm;
   target `knowledge-updates` + `temporal-reasoning` as where content-addressing should win (item 3).
4. **Early experiment:** frame a "disclose the harness" study that quantifies harness-induced
   variance — the thesis, made into a measured artifact (meta-finding + item 4).
