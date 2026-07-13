# Spec — Timeline (the event log and its projections)

> Status: `[exp]`. The core of the architecture: the content-addressed **event log** plus the
> **projections** over it. Realizes `event-schema.md` (envelope, two edges, kinds) against the built
> M1 `Turn`/`Store`/`Timeline`, and specifies the M4 Rust port (4-1). Companion to
> `orchestration-model.md`. Unit IDs `TL-<n>`.

## What the Timeline is

Under the event-sourcing spine, the Timeline is **an append-only, content-addressed DAG of `Event`s
(the `Store`) and the projections folded from it.** Every consumer — the prompt, a mailbox, the
workspace, memory recall, usage accounting — is a projection. There is **one `Store`**; the different
"timelines" (conversation, workspace, causal lineage) are different projections of the same log.

## Starting point — what M1 built

`Turn` / `Store` / `Timeline`: a content-addressed Merkle DAG; single-parent chain;
`commit`/`fork`/`checkout`/`rewind`/`meet`/`diverge_at`; meet-semilattice property-tested over a random
forest; `Ractor.shareable?(turn)` true. This is the pure-Ruby reference and the oracle for the Rust
port (4-1).

## The generalization (from `event-schema.md`, decided)

- `Turn` → `Event(kind: :turn)`, collapsed **test-gated** (Regular + MeetSemilattice + the seven gates
  + `Ractor.shareable?` are the acceptance tests).
- **Two parent edges:** `render_parent` (single, first-parent) + `causal_parents` (set, multi-parent).
- Closed kind list, resolved below.

## The closed kind list (RESOLVED — 4 kinds)

Principle: *a kind exists only when it is a first-class causal node not reducible to another.*

| kind | from → to | payload | on the render chain? |
|---|---|---|---|
| `:turn` | role / agent | the full content-block list (text · thinking · tool_use · tool_result) | **yes** — first-parent walk |
| `:spawn` | parent → child | child config (attenuated toolset, context-mode) | no |
| `:message` | agent ↔ agent (incl. `:human`) | content | no — projected to a mailbox |
| `:snapshot` | agent | workspace tree / delta digest | no — the Workspace Timeline |

Exhaustive match, **loud `else`** on any other value (`CLAUDE.md`).

**Deliberate omissions (the judgment calls):**

- **No `:result`.** A one-shot subagent's return is a `tool_result` block in the parent's next
  `:turn`, with `causal_parents = [the :spawn, the child's final :turn]`. The `:spawn` + causal edge
  already capture the return; a separate kind would duplicate it.
- **No `:tool_call` / `:tool_result`.** Tool execution is an `Effect` interpreted by a `Handler`; its
  *record* is a `tool_result` block inside a `:turn` (+ a Journal entry for cost/timing). Tool-level
  provenance comes from `tool_use_id` linkage within the block list, not from separate events.
- **No `:memory_write`.** Memory is its own content-addressed index (5-3); a `:turn` records the live
  **memory-root digest** so recall is pure/replayable. Memory writes are events in the *memory* log,
  not this one.
- **The human is a participant, not a kind.** `ask_human` is a `:message` to `:human`; the reply is a
  `:message` from `:human`. The human's inbox is the `:message` projection where `to == :human`.

## The projections (the payoff — everything is a fold over the log)

| Projection | Query over the log |
|---|---|
| the **prompt** | first-parent walk of `:turn` events → `Context#render` |
| a **mailbox** | `:message` events where `to == recipient` |
| the **workspace at turn N** | fold `:snapshot` events to N |
| **attested context / provenance** | walk `causal_parents` back to a `:tool_result` block |
| **usage over unique digests** | fold over unique reachable causal-DAG nodes (no double-count) |
| a subagent's **causal lineage** | `:spawn` edges + the child's correlation |

## Operations (generalized to the two-edge DAG)

- **`commit`** — append an `Event` (`render_parent` = current render head; `causal_parents` = its
  dependencies). Small envelope; payload by digest.
- **`fork`** — O(1) (share the prefix, new head). Serves one-shot subagents (`:spawn` + a fresh
  correlation), the `:inherit` mode, and speculative branching alike.
- **`checkout` / `rewind`** — move the render head along `render_parent` (first-parent).
- **`meet` / `diverge_at`** — over the **causal DAG** (LCA is the meet). `MeetSemilattice` generalizes
  from a forest to a DAG. `diverge_at` localizes **both** a cache break (render chain) and a workspace
  divergence (`:snapshot` projection).

## One Store, distinct from the Journal

- **One `Store`** holds all kinds — a content-addressed forest/DAG keyed by digest. The Workspace
  Timeline is `:snapshot` events in *this* Store, not a second store.
- **The Journal (M2) is separate, deliberately.** The `Store` is **state** (replayable render, causal
  provenance); the Journal is **observability** (cost, retries, degradations, `tracing` spans) — a
  separate append-only NDJSON stream. Some Journal content is a *projection* over `Store` events
  (per-turn usage = fold + `PriceBook`); some is *observation not in the Store* (a retry, a
  degradation). State vs. observation — two logs on purpose.

## Units

- **TL-1 — Define `Event` + the four kinds + the two edges** as pure Ruby, over the existing `Store`.
  **Acceptance:** `Ractor.shareable?(event)`; `Canonical` digest stable; exhaustive kind match with a
  loud `else`.
- **TL-2 — Prove `Turn ≅ Event(:turn)` and collapse.** **Acceptance:** the `Regular` +
  `MeetSemilattice` groups and the **seven gates** pass unchanged with `Turn` implemented as
  `Event(:turn)`; then `Turn` is removed.
- **TL-3 — Causal edge + generalized `meet`/`diverge_at` over the DAG.** *Builds on:* the existing
  meet-semilattice. **Acceptance:** `meet` returns the LCA over the causal DAG; fan-in (a synthesis
  event with N `causal_parents`) has a correct `meet` with each parent; property tests hold over a
  random **DAG** (not just a forest).
- **TL-4 — Projections.** `render` (first-parent), `mailbox(to)`, `workspace_at(n)`, `provenance`.
  **Acceptance:** each is a pure fold; a mailbox returns exactly its `:message`s; provenance reaches a
  `:tool_result`; usage over unique digests never double-counts a shared prefix.
- **TL-5 — Rust port (4-1).** Port to `ext/lain` (magnus, pure) with `im`/`rpds` (structural sharing),
  `blake3`, `indexmap`. **Acceptance:** TL-2/TL-3/TL-4 property tests + the seven gates +
  `Ractor.shareable?` pass against **both** the Ruby and Rust impls (the port's real acceptance test,
  4-1.3).

## Interdependencies

`event-schema.md` (the envelope this realizes) · `orchestration-model.md` (`:spawn`/`:message`,
mailboxes, supervision-as-replay) · Workspace Timeline = the `:snapshot` projection (first-class
concept #7) · memory (5-3) referenced by root digest from `:turn` · the Journal (M2, separate stream) ·
4-1 (Rust port). **Open sub-question carried:** projection indexing (Rust `roaring` per-recipient /
`petgraph` causal reachability) so mailbox + provenance folds stay cheap on a growing log.

## Audience

Architecture — serves both. The **lain user's** conversation, workspace, and subagents are
`:turn`/`:snapshot`/`:spawn` events; the **lain dev's** bench replays, forks, and diffs the same log.
