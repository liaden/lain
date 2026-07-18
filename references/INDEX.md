# References Index — Lain study bench

Every resource here, and **what it gives Lain** (not what it says). Each entry ends with the
design decision, experiment, or milestone it informs. See `SCOPE.md` for the questions and
`planning/` for the ideas these ground.

---

## Synthesis documents

### [memory-and-retrieval.md](memory-and-retrieval.md)
Five memory benchmarks + Zep + a code-level read of MemPalace, synthesized for Lain's M6 sweep.

**What's inside:**
- **Five gradeable memory abilities** (2410.10813) — extraction, multi-session, temporal, knowledge-updates, abstention. The taxonomy Lain's memory grader should measure.
- **MemPalace code findings** (repo) — AAAK symbolic index dialect, "signal-not-gate" retrieval, bitemporal SQLite KG, query sanitizer. Borrowable designs the README omits.
- **Temporal knowledge graphs** (2501.13956, MemPalace `knowledge_graph.py`) — bitemporal `valid_from/valid_to`; the explicit-validity alternative to compare against Lain's content-addressed versioning.

**Useful for:** M6 retrieval-strategy sweep; the `Manifest` index design; the "content-addressing wins on knowledge-updates" experiment.

### [prompt-caching-mechanics.md](prompt-caching-mechanics.md) ⚠️ LLM-generated
How Anthropic's server-side prompt cache resolves requests (KV-tensor memoization keyed by
exact prefix bytes), why the pricing table follows from that, and the sub-agent economics.
**Not an external source** — Claude-written synthesis (2026-07-13); pricing/limits from the
API docs, the resolution model inferred from documented behavior.

**What's inside:**
- **The resolution model** — breakpoints as snapshot points, longest-prefix-wins probing, and the three usage fields as a read/written/discarded partition of the prompt.
- **Pricing as storage economics** — why writes are 1.25×/2×, reads 0.1×, the 4096-token minimum, the 4-breakpoint cap, and the concurrent-write race.
- **Sub-agent cache economics** — fork-style vs fresh-root (Lain's) vs sibling-template sharing; spawn staggering as an orchestration lever.
- **Lain mapping + two known gaps** — `Canonical`/`Context#render` purity as the cache invariant; stale `PriceBook::DEFAULTS` and the single `cache_creation` rate.

**Useful for:** cost accounting in the bench (`Usage`, `PriceBook`), the spawn-strategy
experiment axis (which prefix does a child share?), and reading `cache_hit_ratio` as the
silent-invalidator detector.

### [oss-inspiration.md](oss-inspiration.md)
Architecture/code-level design ideas from other OSS harnesses.

**What's inside:**
- **OpenHands ≈ Lain, in production** — event store + view-derived-from-store + condensation-as-marker + 9 pluggable condensers via registry. Validates the IVM framing and seeds the Context combinators.
- **Aider repo-map** (tree-sitter + PageRank) — a ranked context-selection *combinator* Lain lacks; generalizes to graph-ranked corpus retrieval.
- **SWE-agent ACI** (2405.15793) — +12.5% pass@1 from interface design alone, model fixed; the four ACI principles as a Tool-design rubric.
- **goose** (Rust) — per-session isolation to avoid lock contention; a reference for `lain-core`.

**Useful for:** the Context-combinator catalog (M3c), a repo-map/graph-rank retrieval arm, the Tool/ACI design rubric, and the M5 concurrency model.

### [hn-agent-landscape-2026-07.md](hn-agent-landscape-2026-07.md) ⚠️ LLM-generated
A dated HN scan (past 7 days + 90-day expansion) of LLM/agent discussion, reduced to *what each
thread gives Lain* — an experiment axis or external corroboration. Grouped by the SCOPE taxonomy;
story IDs/points/URLs are verifiable, the "→ Lain" readings are Claude's. **Not a primary source.**

**What's inside:**
- **Cache-thrash is the real cost, not prompt size** (Claude Code 54× cache-write vs OpenCode) —
  the highest-leverage bench experiment: a prefix-hash cache-thrash meter + a prefix-stability
  property test, both nearly free given `Context#render` purity.
- **The harness-variance A/B is the founding demo** (§10; grounded in `papers/rst/2605.23950`) —
  hold model + task fixed, vary only the Middleware stack / compaction, report the score delta.
  Comment-linked practitioner writeups (swyx's loopcraft, Fowler) echo it; the citable claim stays
  the peer-reviewed paper already in the corpus, not the inaccessible OpenAI posts (dropped, §10).
- **Guardrails as a Middleware monoid** (Forge: 8B 53%→99%) — each guardrail (validate, rescue-parse,
  prereq-enforce, nudge-retry) wraps the Effect::Handler; the highest-value small-model/Ollama study.
- **Transparent subagents beat encrypted ones** (Codex prompt-encryption contrast) — `spawned_from` +
  Journal *are* the plaintext audit companion the community asked OpenAI for; motivates the
  swappable-inheritance study.
- **Memory over the Journal natively** (deja-vu, zby's four-field taxonomy) — validates BM25-first;
  index turn *lineage/outcome*, not just text; a ready axis-set for the M6 sweep.
- **Cost is external, too** (DN42 bankruptcy, prod-DB deletion) — Budget must model per-effect
  tool-side cost + a recursive subagent ceiling; isolation is an engineering, not administrative,
  control.

**Useful for:** the §1 cache experiments, the harness-variance headline A/B (SCOPE Q1–Q2), the
Effect/Middleware guardrail sweep, the model-migration A/B harness, the M6 retrieval axes, and
`Agent::Budget` per-effect cost accounting. Comment-linked arXiv IDs are parked for SCOPE vetting.

---

## Reference implementations (`repos/`)

### [smolagents](repos/smolagents/) — HuggingFace
**Python CodeAct agent.** The canonical minimal code-mode implementation. Borrow: the
**`PythonExecutor` ABC** (local AST-interpreter vs. remote E2B/Docker sandbox behind one seam —
validates `ext/lain` vs. `lain-core`); the **persistent `state` dict** with **tools *and* subagents
injected as callables** (code-mode + "subagent is a tool" + handles, realized); the agent loop as a
**generator of steps**. Read `local_python_executor.py`, `agents.py`, `remote_executors.py`. See
`oss-inspiration.md`.

### [mempalace](repos/mempalace/) — MemPalace
**Local-first Python memory system (ChromaDB default, pluggable backends).** Verbatim storage +
symbolic index over it. Borrow: the **AAAK dialect** as a concrete `Manifest` index; **"closets
are a ranking signal, never a gate"** (aux index can only boost, never hide the direct-content
floor) — a retrieval-safety invariant that matches Lain's loud-failure ethos; the **bitemporal
knowledge graph**; and **`query_sanitizer.py`**, which fixes a real recall cliff (89.8% → 1.0%
when an agent prepends a 2000-char system prompt to a short query). Read `searcher.py`,
`dialect.py`, `knowledge_graph.py`, `query_sanitizer.py`, `layers.py`.

---

## Papers (`papers/`)

Grouped by topic; IDs link to converted text in `papers/rst/`.

### Harness evaluation & the thesis

| Source | Summary |
|---|---|
| [2605.23950](papers/rst/2605.23950.rst) | **Stop Comparing LLM Agents Without Disclosing the Harness:** the scaffold, not the model, often sets the score for long-horizon tasks. **Gives Lain:** external validation of the founding thesis, and the opening to *quantify* harness-induced variance (byte-diffable replay + swappable seams) — an early headline experiment. |
| [2604.03515](papers/rst/2604.03515.rst) | **Inside the Scaffold — a source-code taxonomy of coding-agent architectures:** reads many harnesses' source and names their components (context builder, tool registry, condenser, budget tracker, …); flags OpenHands' event store as most extensible. **Gives Lain:** a component vocabulary to check the architecture against, and a code-grounded reading list (see `oss-inspiration.md`). |

### Orchestration

| Source | Summary |
|---|---|
| [2411.04468](papers/rst/2411.04468.rst) | **Magentic-One:** orchestrator with an outer **Task Ledger** (facts/guesses/plan) + inner **Progress Ledger** (self-reflect, assign, **stall → replan**). **Gives Lain:** the most concrete orchestrator to steal — ledgers = Workspace (sent-not-stored), stall→replan = FSM transition. Dual-ledger arm (orchestration-experiments #3). |
| [2604.27891](papers/rst/2604.27891.rst) | **In-Context Prompting Obsoletes Agent Orchestration for Procedural Tasks:** single-agent wins for procedural tasks that fit context; orchestration keeps the edge only for genuinely parallel/specialist/context-binding work. **Gives Lain:** a pre-registered decision boundary to confirm/refute on coding tasks. |
| [2602.16873](papers/rst/2602.16873.rst) | **AdaptOrch:** task-adaptive selection among orchestration strategies (MoA, sequential, blender); in the "performance convergence" era, optimize cost not accuracy. **Gives Lain:** the learnable per-task router — the artifact the bench can *fit* from measured distributions. |
| [2310.04406](papers/rst/2310.04406.rst) | **LATS (Language Agent Tree Search):** MCTS + LM value function + reflection over agent trajectories; 92.7% pass@1 HumanEval. **Gives Lain:** the named upgrade to speculative branching — uniquely cheap here because `fork` is O(1) and graders exist. LATS arm (orchestration-experiments #5). |
| [2604.17557](papers/rst/2604.17557.rst) | **Causal-Temporal Event Graphs:** a formal model for recursive agent execution traces as causal event graphs. **Gives Lain:** the on-domain grounding for the event-sourcing spine and the event schema — agent runs *are* causal event DAGs (see `planning/specs/event-schema.md`). |

### Context engineering & code-mode

| Source | Summary |
|---|---|
| [2402.01030](papers/rst/2402.01030.rst) | **CodeAct — Executable Code Actions Elicit Better LLM Agents:** agents that emit Python and execute it beat JSON tool-calling on success rate and steps. **Gives Lain:** the reference grounding for code-mode and the "handles to out-of-context data" first-class concept. |
| [2405.15793](papers/rst/2405.15793.rst) | **SWE-agent — Agent-Computer Interfaces:** custom tool interfaces give +12.5% pass@1 on SWE-bench with the model fixed; four ACI principles (simple, compact, concise feedback, guardrails). **Gives Lain:** the citable evidence that "tool design *is* context," a Tool-tier design rubric, and a swept axis (feedback verbosity, guardrails on/off). |

*(Context-rot and disclosure evidence are lab writeups — see expert/community below and
`planning/first-class-concepts.md` for the IVM framing.)*

### Memory & retrieval

| Source | Summary |
|---|---|
| [2410.10813](papers/rst/2410.10813.rst) | **LongMemEval:** 500 questions over 5 memory abilities; ~30% accuracy drop across sessions; indexing/retrieval/reading framework. **Gives Lain:** the primary memory grader; targets `knowledge-updates` + `temporal-reasoning` where content-addressing should win. |
| [2402.17753](papers/rst/2402.17753.rst) | **LoCoMo:** very-long-term conversations (≈300 turns, up to 35 sessions) grounded on temporal event graphs. **Gives Lain:** a long-horizon memory arm; the temporal-event-graph generation idea for synthetic fixtures. |
| [2506.21605](papers/rst/2506.21605.rst) | **MemBench (ACL 2025):** factual vs. reflective memory × participation vs. observation; grades effectiveness/efficiency/**capacity**. **Gives Lain:** a memory grader that scores *cost*, not just recall — aligned with the token-cost headline metric. |
| [2511.10523](papers/rst/2511.10523.rst) | **ConvoMem:** 75,336 QA pairs; "your first 150 conversations don't need RAG." **Gives Lain:** the memory-vs-RAG boundary as a measurable question, and an explicit `abstention` category (know when it's not in memory). |
| [2501.13956](papers/rst/2501.13956.rst) | **Zep (Graphiti temporal KG):** +18.5% on LongMemEval, −90% latency vs. baseline; bitemporal validity. **Gives Lain:** the temporal-KG retrieval arm and a strong baseline for the knowledge-updates experiment. |

### Optimization

| Source | Summary |
|---|---|
| [2507.19457](papers/rst/2507.19457.rst) | **GEPA — Reflective Prompt Evolution:** mutate prompts using textual trace feedback + a Pareto frontier over instances; beats RL on several tasks. **Gives Lain:** turns the bench from a ruler into an optimizer — it needs exactly (metric, textual feedback, cheap eval) = (Grader, Journal, dry replay). |

---

## Expert / community knowledge (not in the literature)

> The defensible layer — practitioner knowledge and code findings no paper states.

- **The harness is the variable, but nobody quantifies it.** Multiple 2026 writeups + 2605.23950
  assert scaffold-dominates-model, yet no released harness holds the task fixed and varies one seam
  with byte-diffable replay. **For Lain:** this gap *is* the opening — the first experiment, not a
  feature.
- **READMEs under-report design; read the retrieval/context core.** MemPalace's most transferable
  ideas (AAAK dialect, signal-not-gate ranking, bitemporal KG, query sanitizer) are in code, not
  the README. **For Lain:** budget code introspection for every reference impl; treat READMEs as
  marketing.
- **Recall's *query* is an injection surface.** MemPalace `query_sanitizer.py`: an agent prepending
  a long system prompt to a short query collapses embedding recall 89.8% → 1.0%. **For Lain:** the
  plan says "recall must be pure"; add "the query must be clean" — a retrieval-safety concern the
  plan doesn't yet name.
- **Multi-agent burns ~15× tokens for ~90% gain only on decomposable tasks** (Anthropic) vs.
  **"don't build multi-agents"** (Cognition). **For Lain:** the disagreement is real and
  task-structural — build the *comparison* before the fleet.
- **Effective context is 50–65% of advertised; coherent input degrades attention *more* than
  shuffled** (Chroma Context Rot). **For Lain:** pruning is load-bearing earlier than intuition
  says; recall-at-tail is justified twice (cache + attention).
