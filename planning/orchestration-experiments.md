# Orchestration experiments — swappable arms for the bench

> Exploratory. Potential ideas, not committed scope. Companion to `research-scan-2026-07.md`.
>
> The 2026 literature converges on one point: **orchestration is conditional, and the real
> deliverable is a decision boundary** — "for *this* task class, use strategy X." Three independent
> sources assert that boundary from the outside; almost nobody can draw it cleanly, because it
> requires holding the task fixed and varying one orchestration dimension at a time, scored over
> distributions, replayably. That is exactly what Lain's bench is for. The first orchestration
> deliverable should therefore be a *comparison*, not a fleet.

## Why orchestration is cheap to sweep here

These arms are cheap in Lain because the substrate already exists:

| Primitive | What it buys orchestration |
|---|---|
| O(1) `fork` + content-addressed Store | best-of-N, tree search, speculative branches share the prefix |
| `meet` / `diverge_at` | a divergence between two runs localizes to the turn that caused it |
| `Grader` + `Compare` (distributions) | verifiers, aggregators, and strategy A/B are the same machinery |
| Worktrees | real parallel isolation for coding tasks; each agent commits on its own branch |
| Capabilities, attenuated at construction | a "specialist agent" is just `toolset.only(...)` — no policy engine |
| Workspace, **sent not stored** | task/progress ledgers ride the request without accreting per turn |
| Subagent fresh root + `meta.spawned_from` | context isolation is the default, not a bolt-on |

## The arms

Each is a swappable strategy; all are scored against the same task suite and the single-threaded
control.

| Arm | Source | Lain mapping | Primary metrics |
|---|---|---|---|
| **Single-threaded linear** (control) | [Cognition](https://cognition.com/blog/dont-build-multi-agents) | one Timeline, no spawn | baseline — every arm must beat this |
| **Orchestrator-worker** (fan-out/fan-in) | [Anthropic](https://www.anthropic.com/engineering/multi-agent-research-system) | lead + N worktree subagents, synthesis pass | tokens (≈15×), grader score, wall-time, context-loss events |
| **Dual-ledger orchestrator** | [Magentic-One](https://arxiv.org/html/2411.04468v1) | ledgers = Workspace; stall→replan = FSM transition | replans/task, stall-detection recall, progress-ledger accuracy |
| **Handoff / decentralized** | [OpenAI Agents SDK](https://developers.openai.com/api/docs/guides/agents) | subagent result = "hand control to agent X + context" | does framing survive handoffs? control-transfer count |
| **Tree search over trajectories (LATS)** | [LATS, ICML'24](https://arxiv.org/abs/2310.04406) | speculative branching + MCTS + LM value fn + reflection | pass@1 vs. fork budget; branches explored per solve |
| **Mixture-of-Agents / best-of-N + verifier** | [MoA (ICLR'25)](https://arxiv.org/pdf/2602.16873) · Multi-Agent Verification (COLM'25) | diverse forks; grader as verifier/aggregator | quality vs. N; verifier agreement rate |
| **Adaptive router** (meta) | [AdaptOrch](https://arxiv.org/pdf/2602.16873) | router picks arm per task from features + cost | can the bench *learn* the router? regret vs. oracle |
| **Shared-artifact editing** (CRDT) | Blackboard; **see [`crdt-exploration.md`](crdt-exploration.md)** | subagents co-edit one live file via CRDT + awareness feed + resolver | thrash count, time-to-convergent-correctness, context-loss events |

## The two highest-value specific steals

### Magentic-One's dual-ledger loop — the most concrete design to steal

It is an actual algorithm, not a topology. Two nested loops:

- **Outer / Task Ledger** — facts, educated guesses, and the plan.
- **Inner / Progress Ledger** — self-reflection on progress, and the next subtask assignment.
- **Stall detection → replan** — *if progress isn't made for enough steps, update the Task Ledger and
  produce a new plan.*

Maps almost perfectly onto Lain: the ledgers are **Workspace** content (sent-not-stored, so they
don't accrete a stale copy per turn), the stall→replan edge is a **state-machine transition** (the
M3b `state_machines` adoption can make it a legal/illegal transition with a `before_transition`
Journal hook), and every ledger update is a journaled event. This gives the "smarter orchestrator
that escalates deviations from the plan" in TODO.md a tested shape.

### LATS — the named upgrade path for speculative branching

The plan already says: *"beam search over agent behavior — rarely done because forking a conversation
is normally expensive. Here it is O(1)."* LATS is the research-grade version: MCTS
(selection/expansion/backpropagation) + an LM value function + reflection on failed branches fed into
the next expansion (92.7% pass@1 on HumanEval). Because Lain's fork is O(1) *and* it has graders,
LATS is uniquely cheap to build here when it is prohibitively expensive elsewhere. This is a genuine
"we can do what others can't" experiment, and it reuses the bench's forking wholesale.

## The decision-criteria papers — pre-registered hypotheses to confirm or refute

The most experiment-relevant work states the boundary Lain can *verify*:

- **"In-Context Prompting Obsoletes Agent Orchestration for Procedural Tasks"**
  ([arxiv](https://arxiv.org/pdf/2604.27891)) — single-agent wins when the task is procedural, the
  context holds the full spec, and there is no genuine parallelism; orchestration retains the edge
  only for *genuinely independent parallel work, specialist domains, context-limit-binding tasks, and
  heavy interdependencies.* A pre-registered hypothesis for the bench.
- **AdaptOrch** ([arxiv](https://arxiv.org/pdf/2602.16873)) — in the "performance convergence" era the
  winning artifact is a *router* that matches strategy to task and optimizes cost, not accuracy.
  Tailor-made for a bench whose headline metric is token cost; Lain can build the router from measured
  data rather than heuristics.
- **Practitioner prior worth testing, not assuming** — "hierarchical looks right on a whiteboard but
  flat dispatch with a clearer schema usually wins," and "start simple, instrument heavily, add
  complexity only where the data demands it" ([Beam](https://beam.ai/agentic-insights/multi-agent-orchestration-patterns-production)).
  Falsifiable with `Compare`.

Taxonomy anchor: centralized / decentralized / hierarchical + a dynamic-adaptive control axis
([Future Internet survey](https://doi.org/10.3390/fi18060326)).

## Proposed experiment order

1. **Reproduce the boundary.** Single-threaded control vs. orchestrator-worker on a coding-task suite,
   scored over distributions. Confirm or refute the "procedural → single-agent" hypothesis on tasks
   *we* can judge. This needs only M5 subagents + the bench.
2. **Dual-ledger arm.** Add the Task/Progress ledger loop; measure whether stall-detection + replan
   beats naive fan-out on interdependent tasks.
3. **LATS arm.** Turn speculative branching into MCTS-with-value-function; measure pass@1 against fork
   budget — the "O(1) fork earns its keep" experiment.
4. **Adaptive router.** Once several arms have per-task-class distributions, *fit* the router and
   measure its regret against the per-task oracle. This is the decision boundary the papers assert,
   produced empirically.

## What to measure (beyond grader score)

- **Token cost** — the 80%-of-variance predictor; the axis the bench exists to expose.
- **Context-loss events** — the Cognition failure ("subagent never saw the framing"), detectable in
  the Journal as a decision made without the lineage that should have informed it.
- **Wall-time under real parallelism** (worktrees), separated from token cost.
- **Replans / stalls** (dual-ledger), **branches explored / solve** (LATS), **verifier agreement**
  (MoA) — arm-specific process metrics.

## Open questions

- Does the "procedural → single-agent" boundary hold on *coding* tasks specifically, or only on the
  dialogue/workflow benchmarks the paper used?
- Is context-loss in delegation measurable cleanly, or only visible as a downstream grader drop?
- Can the adaptive router be *learned* from bench data, or does it need task features we can't extract
  cheaply?
- Which arms need real concurrency (M5 decision) vs. which are fine sequential-with-forks?
