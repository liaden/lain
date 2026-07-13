# Spec — Oracles (cheap one-shot deciders)

> Status: `[exp]`, specced 2026-07-13. Formalizes the M3b ollama fold-in's "meta-tasks"
> (TODO 31–33) into one seam. Companion to `orchestration-model.md` (OM-4 — `ask_human` is the
> same shape), `cache-economics.md` (CE-4/CE-5/CE-6 constrain where decisions may land), and
> `cache-aware-compaction.md` (the first consumer). DCP review (2026-07-13, see § Decider locus)
> contributed the model-self-directed arm and two mechanical combinators. Unit IDs `OR-<n>`.

## The concept

An **oracle** is a promise-shaped answer source for a small, typed question that influences
harness behavior — *not* conversation content. The orchestration spec already defines the shape:
`ask_human` emits a question, returns a promise, and the agent blocks only when the answer is
actually needed; the human is "a capability-gated, high-latency agent whose replies are just
events in the log." An oracle generalizes that seam across latency/cost tiers:

| Answer source | Latency | Cost | Use |
|---|---|---|---|
| **heuristic** (regex, threshold, code) | ~0 | 0 | the baseline every oracle must beat |
| **ollama** (local model) | ~100–500ms | 0, PHI-safe | private meta-tasks (medical corpus) |
| **haiku** | 1 network RTT | ~$1/MTok on tiny prompts | judgment above a 7B's ceiling |
| **inline** (ask the main model in-conversation) | 0 extra calls | opus tokens + **context pollution** | the pollution baseline |
| **human** (`ask_human`, OM-4) | minutes–hours | attention | the existing top tier |

One seam, five tiers. The point of the bottom four is exactly the user framing: decisions that are
**cheap, dynamic, and never rendered into the long-running conversation** — the main context stays
unpolluted and the main cache prefix stays untouched.

## Two placement rules (from `cache-economics.md`)

1. **Tail-or-nothing.** An oracle's output may gate an *action* (compact now? save this memory?
   escalate?) touching no prompt bytes, or inject content **after the last cache breakpoint**
   (the Workspace sent-not-stored pattern). It must never vary bytes in the prefix — a per-turn
   decision interpolated early is the "conditional system sections" silent invalidator.
2. **Structure only at birth.** Toolset selection re-renders position 0; model selection is a
   different cache namespace. Oracles may decide both **only at spawn boundaries** (a router
   oracle choosing a child's model; a template oracle choosing the sibling toolset — CE-4), never
   mid-session.

## Determinism: journal the Q&A, replay from the record

A live oracle is a nondeterminism source that would poison `DryReplay`. The fix is the machinery
the ROADMAP already plans for the human tier ("substitute a model for the human from recorded
replies"): every oracle call journals `(oracle_digest, question, answer, model, usage, wall_clock)`;
replay substitutes recorded answers. Oracle answers are **control-flow, not conversation** — they
live in the Journal (like usage), not the Store; no pressure on the closed 4-kind event set. When a
decision does change rendered bytes, the effect is visible in the Request digest chain (CE-2)
anyway, so attribution comes free.

## Shape of an oracle

Declared, content-addressed, loud-failing:

- **A prompt template** — a slot-style partial (PS machinery), rendered in the same locked pure
  binding; the oracle definition digest covers template + schema + model tier.
- **A typed answer schema** — the `Tool::Input` dual (one declaration → JSON schema for the model
  *and* local validation); ollama's structured-output mode and Anthropic tool-forcing both consume
  it. An unparseable or invalid answer **raises** — an oracle that silently defaults is a policy
  bug wearing a trench coat. (Same shape-not-safety caveat as `tool/input.rb`: answer validation
  is shape validation, never a security control.)
- **A promise** — awaiting parks the fiber (OM-0), so hot-path oracles overlap with rendering or
  other work instead of serializing into the loop.

## Decider locus — the sweep the DCP review adds

[`opencode-dynamic-context-pruning`](https://github.com/Opencode-DCP/opencode-dynamic-context-pruning)
(reviewed 2026-07-13) answers "who decides what to prune" differently: it exposes a **`compress`
tool the main model itself calls**, with allow/ask/deny permission modes. That is a third locus of
decision, and it completes an axis:

| Locus | Mechanism | Cost shape |
|---|---|---|
| **policy** | static code/config decides | free, rigid |
| **oracle** | out-of-band one-shot decides | cheap call, zero main-context tokens |
| **model-self-directed** | the main model calls a decision tool | opus tokens, *pollutes context with the deciding* — but the model has the most context |

DCP's own numbers are the cautionary tale, honestly reported: cache-hit ~85% *with* vs ~90%
*without*, and no quality evals — "token reduction without evals for capability impacts" is the
exact failure this bench exists to prevent. Their mechanism is worth having as an *arm*; their
missing measurement is our result.

Also adopted from the DCP review (mechanical, not oracle-shaped — Context combinators, natural
Timeline projections): **dedupe-identical-tool-calls** (same tool + args → keep newest output) and
**purge-failed-tool-inputs** (drop failed calls' inputs after N turns, keep the error text). Their
**protected-patterns/pins** config (files/tools exempt from pruning) is a policy knob `Prune` and
`Compact` should share. Their honest README line — "pruning changes messages, which invalidates
cached prefixes from that point forward" — is external validation of the CE framing.

## Units

- **OR-1 — The Oracle seam.** Oracle = template + typed answer schema + model tier, content-
  addressed, invoked through the same promise shape as `ask_human` (OM-4). *Needs:* OM-0 (fibers)
  for non-blocking await; PS machinery for templates; the M3b ollama provider arm. **Acceptance:**
  an oracle definition renders deterministically; a call returns a validated typed answer or
  raises; awaiting parks the fiber; the heuristic tier implements the same interface with no
  model call.
- **OR-2 — Journal + replay substitution.** Every call journaled; `DryReplay`/`LiveReplay`
  substitute recorded answers; shared code path with recorded human replies. *Needs:* OR-1, the
  Journal. **Acceptance:** a replayed session with oracles renders byte-identically; deleting the
  recorded answer makes replay fail loudly, not silently re-ask.
- **OR-3 — First two oracles: prune-scoring and memory-save gating.** Both off the hot path.
  Prune-scoring feeds `cache-aware-compaction.md`'s cold-window work ("which spans are stale?");
  memory-save gating is the court-clerk's helper ("worth remembering?"). *Needs:* OR-1/OR-2;
  compaction spec; memory (5-3). **Acceptance:** each ships with its heuristic baseline arm; both
  run at idle/post-turn, never blocking a turn. *(A third early consumer lives in
  `plan-shaped-compaction.md` PC-7: the eager unit summarizer — local-tier, concurrent,
  keyed by source digest.)*
- **OR-4 — The decider sweep.** For one decision point (prune-scoring first), compare
  **heuristic vs ollama vs haiku vs inline vs model-self-directed** (the DCP `compress`-tool arm),
  scored grader × tokens × cache-write × wall-clock ($/sec, CE-6). *Needs:* OR-3, CE-2 (cache-write
  column), `Compare`. **Acceptance:** a `Compare` report over a fixed task answers "when does a
  cheap gating model beat a regex" as distributions; the inline arm quantifies what context
  pollution actually costs.
- **OR-5 — Spawn-time structural oracles.** The adaptive-router arm made dynamic: at spawn, an
  oracle picks the child's model and/or sibling template. Respects the birth-boundary rule by
  construction. *Needs:* OR-1/OR-2, CE-4 (spawn strategy seam), OM-2. **Acceptance:** a routed
  fan-out journals each routing decision; mid-session re-routing is structurally impossible
  (the seam only exists at spawn).
- **OR-6 — DCP mechanical combinators.** `Context::DedupeToolCalls` and
  `Context::PurgeFailedInputs(turns:)` as ordinary combinators under `>>`, with a shared
  protected-patterns policy across them and `Prune`/`Compact`. Not oracle-shaped; listed here
  because the review that produced them lives here. *Needs:* 3c combinator seam (built).
  **Acceptance:** both are pure projections (log untouched); both declare `requires`; protected
  patterns exempt matching spans in all consumers.

## Interdependency map

```
OM-4 ask_human (promise) ─┐
PS slots (templates) ─────┼──► OR-1 seam ──► OR-2 journal/replay ──► OR-3 first oracles ──► OR-4 decider sweep
M3b ollama provider ──────┘                                    └──► OR-5 spawn-time routing ──► CE-4 arms
Tool::Input (schema dual) ──► OR-1 typed answers
cache-aware-compaction ──► consumes OR-3 prune-scoring ──► OR-4 includes DCP compress-tool arm
3c combinators ──► OR-6 dedupe / purge-failed / protected pins
```

## Open questions

- **Budget accounting.** Do oracle calls draw from the main `Agent::Budget` or a separate
  meta-budget? A runaway oracle loop should trip *something*; folding it into the main budget
  muddies the arm comparison. Leaning: separate ceiling, same `Usage` monoid, reported as its own
  `Compare` column.
- **Answer schema evolution.** An oracle's recorded answers are replay inputs; changing the schema
  orphans them. Content-addressing the definition (template + schema) and keying recorded answers
  by definition digest makes staleness loud — confirm that's enough.
- **Hot-path latency ceiling.** OR-3's targets are deliberately off the hot path. Before any
  on-path oracle (repair triage, recall gating), set a wall-clock budget per call and measure
  under CE-6's $/sec — an oracle that saves 500 tokens and costs 800ms may be a net loss.
- **Inline-arm fairness.** The inline (ask-the-main-model) arm pollutes context *and* warms its
  own tail — its cache profile differs structurally. `Compare` must report cache-write alongside
  grader so the pollution cost is visible, not averaged away.
