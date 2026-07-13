# Spec — Event schema

> Status: `[exp]`. The foundational schema the M5 orchestration model (and the event-sourcing spine)
> rests on. **All four schema decisions are made** (direct addressing · closed kinds ·
> generalize-`Turn`-into-`Event` · git-style two edges); remaining opens are sub-questions (exact kind
> list, `correlation` identity, projection indexing). Companion to
> `planning/specs/orchestration-model.md`. Grounded in event-sourcing practice (CloudEvents,
> causation/correlation) and a domain paper (arXiv 2604.17557, *Causal-Temporal Event Graphs for
> recursive agent execution traces*).

## Decided

- **Direct addressing.** An event carries `from → to` (a single recipient). A **mailbox is the
  projection `events where to == me`**; fan-out is N direct sends. No pub/sub topics.
- **Closed kind set (resolved to 4):** `:turn · :spawn · :message · :snapshot`, matched exhaustively
  with a **loud `else`** (per `CLAUDE.md`). The reasoning — why no `:result` / `:tool_*` /
  `:memory_write` — is in `planning/specs/timeline.md`.

## The envelope (CloudEvents-shaped)

An **Event = a common envelope + a kind-tagged, content-addressed payload** — the CloudEvents pattern
(a standardized envelope around domain data). Envelope fields:

| Field | Meaning |
|---|---|
| `digest` | content id (blake3 over `Canonical` bytes) — the event's identity |
| `kind` | the closed enum above |
| `from` / `to` | direct addressing (attribution generalizes `Turn`'s `role`) |
| `render_parent` | **single** parent — the prompt/sequence edge (fork 2) |
| `causal_parents` | **set** of parents — the causal edge (fork 2) |
| `correlation` | the session/workflow this event belongs to (groups a run) |
| `payload_digest` | content-addressed reference to the kind-specific payload |

The payload is kind-specific: a `:turn`'s payload is the full content-block list + role, so gate-1
("commit every block; echo thinking signatures") holds unchanged. Envelope is small and uniform;
payload is typed and referenced by digest (large results/snapshots never inline).

## Fork 1 (decided): generalize `Turn` into `Event`

**Decision: generalize.** A conversation turn becomes `Event(kind: :turn)`; the envelope's
`from` generalizes `Turn#role`, and the content-block list becomes the `:turn` payload. One primitive,
one content-addressing scheme, one `Ractor.shareable?` spec, one `Store` — the "everything is an
event" spine made literal, in exactly the CloudEvents envelope shape.

**Why it's safe to do to already-built code:** the plan's own discipline is the safety net —
*"`Timeline` ships as pure Ruby first; the property tests must pass unchanged."* So:

1. Define `Event`.
2. Prove `Turn ≅ Event(kind: :turn)` against the **existing** acceptance tests — the `Regular` and
   `MeetSemilattice` shared example groups, the **seven correctness gates**, and
   `Ractor.shareable?(event) == true`.
3. Only then collapse `Turn` into `Event`.

The tests are the oracle; the generalization is a refactor validated by green tests, not a rewrite.
**Sequence:** define the envelope now (M5 depends on it); do the collapse gated by the tests. Your gut
(generalize) is the more coherent long-term model and this is how to reach it without risking M1.

## Fork 2 (decided): two edges — the git model

**Decision: two distinct parent edges**, which is precisely git's model *and* what the plan
already half-encodes (`Turn#parent` renders; `meta["spawned_from"]` is causal lineage):

- **Render edge — `render_parent`, single (first-parent).** The prompt/message sequence the model
  sees. Stays single-parent so gate-2 (all tool_results in one linear user turn) and cache-prefix
  stability hold. The render projection is a **first-parent walk** — exactly `git log --first-parent`.
- **Causal edge — `causal_parents`, a set (multi-parent).** Generalizes `spawned_from` to first-class
  multi-parent causality: a synthesis event names the **N** subagent results it folded; a message names
  what caused it. This is git's multi-parent commit and the causal-log DAG (Gustafson).
- **`correlation`** groups a whole run (the event-sourcing correlation-id convention) ≈ the timeline
  root / `spawned_from` lineage.

**Deliberate, not automatic.** Unlike causal-log replicas (which auto-merge all concurrent heads on
every append), Lain's multi-parent edges are **deliberate** — an orchestrator *chooses* to fold N
results into a synthesis event. So the render chain stays clean and linear; the causal set is queried
for provenance, usage, and `meet`. This is the git posture (semantic, deliberate merges), not the
CRDT-auto-merge posture.

**Why safest *and* most powerful:** it preserves every linear-render invariant (gate-2, cache-prefix,
the O(1) first-parent walk) while making causality first-class — which is what the rest of the design
needs.

## What this unlocks (the interdependency payoff)

- **Mailboxes** = project `to == me` over the log (direct addressing).
- **Usage over unique reachable digests** (the plan's "don't double-count the shared prefix") = a fold
  over the **causal DAG's unique nodes** — the causal edge makes it correct by construction.
- **Attested context** = walk `causal_parents` back to a `:tool_result` (provenance is a graph query).
- **Supervision / resume** = replay `render_parent` + `causal_parents` to a checkpoint (one mechanism).
- **Speculative branching / `meet` / `diverge_at`** = operations over the causal DAG; the
  `MeetSemilattice` property tests generalize from a forest to a DAG (LCA is the meet).

## Open sub-questions

- ~~The exact closed **kind list**~~ — **resolved** in `planning/specs/timeline.md`: 4 kinds
  (`:turn · :spawn · :message · :snapshot`); `:snapshot` lives in the same `Store`.
- Is `correlation` the timeline-root digest, or a separate id?
- **Projection indexing.** `to == me` filtering and causal-reachability over a growing log need an
  index — a Rust **roaring** bitmap (per-recipient / per-correlation) or **petgraph** (the causal DAG).
  Ties to the plan's `roaring` / `petgraph` bindings; per-turn projection must stay cheap.
- Confirm **deliberate-only** merge semantics (no automatic concurrent-head merge).

## References (grounding)

- CloudEvents — the envelope-around-domain-data pattern.
- Arkency, *Correlation id and causation id in evented systems* — the causality-metadata convention.
- J. Gustafson, *Introduction to Causal Logs* — multi-parent causal DAGs vs. git first-parent.
- *Git as an event-sourced system* — commits-as-immutable-events; first-parent linear view.
- **arXiv 2604.17557**, *Causal-Temporal Event Graphs: A Formal Model for Recursive Agent Execution
  Traces* — the on-domain formal model; pulled into `references/papers/`.
