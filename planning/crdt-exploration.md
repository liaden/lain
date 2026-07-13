# CRDTs in Lain — where they fit, and the one place they open something new

> Exploratory. Not committed scope. Kept as its own doc because the interesting case — subagents
> co-editing a live shared file — is a *distinct third model*, not a variation on the existing
> orchestration arms. It is cross-referenced from `orchestration-experiments.md` (as the
> `:shared_artifact` arm) and touches `first-class-concepts.md` (blackboard-in-`lain-core`), but the
> reasoning lives here.

## The core intuition: it's the semilattice

CRDTs converge because their merge is a **join/meet-semilattice** — commutative, associative,
idempotent. Lain's Timeline is *already* property-tested as a meet-semilattice, is content-addressed,
and is append-only. That is not a coincidence: **Lain is already built on the algebra CRDTs use.**
The question is never "should we add CRDTs" in the abstract — it is "at which granularity does a
CRDT library give us something the content-addressed Merkle DAG doesn't already have."

## Granularity 1 — the Timeline: already a CRDT, don't touch it

A grow-only set of content-addressed turns keyed by digest **is the canonical state-based CRDT** (a
G-Set): merge is set union, and conflicts are impossible because turns are immutable and named by
content. So at the conversation granularity, a CRDT crate buys nothing — and would actively fight the
`Ractor.shareable?` deep-immutability invariant, since CRDT replicas are mutable, stateful,
tombstone-carrying objects. Automerge is the same idea made explicit ("git for a document",
hash-linked op history) — a *cousin* of the Timeline at a finer grain, not a replacement for it.

**Verdict: the Timeline stays pure Ruby / `ext/lain`, unchanged. The meet-semilattice already is
the CRDT.**

## Granularity 2 — file editing: three sub-cases

| Case | Verdict |
|---|---|
| One agent editing files | No CRDT. `str_replace` + read-before-write contract is enough. |
| Parallel subagents, **isolated** (today's worktree model) | Git handles it; its merge *conflicts are often desirable* (a semantic clash should surface, not silently auto-merge). CRDT here would only hide conflicts. |
| Parallel subagents **co-editing one live file** | **The interesting case.** See below — this is where a CRDT opens something new. |

## Granularity 3 — the centerpiece: collaborative shared-artifact editing

Subagents share **one live document** backed by a text CRDT; each edit propagates to all; agents
*observe each other's edits and resolve issues as they go*. This is the classic **Blackboard
architecture** (Hayes-Roth 1985; Hearsay-II): the file is the blackboard, the subagents are
knowledge sources, and a control component arbitrates. Nobody has built it for LLM coding agents on a
CRDT substrate, and it directly attacks Cognition's "the subagent never saw the framing" failure —
because here **the shared artifact *is* the shared context**, made literal and live. It is a third
model, sitting between:

- **single-thread** — one context, no parallelism (Cognition's recommendation), and
- **worktree-isolation** — parallel, blind, late batch merge (today's plan).

### The governing distinction: a CRDT converges *state*, not *correctness*

A CRDT guarantees every agent sees the same bytes; it does **not** guarantee the bytes are good. Two
agents inserting at the same anchor converge to a deterministic order that may still be interleaved
garbage. So a CRDT is **necessary but not sufficient** — the intelligence has to supply the
semantics. Two layers on top are mandatory:

1. **An awareness feed.** Each agent must be *notified* of peer edits (Yjs calls this the "awareness"
   protocol). This is Lain's existing **staleness ledger** (in the Workspace) promoted to real-time:
   "peer A just changed `foo()`'s signature." Ship it as **deltas (ops), not the whole file** — the
   CRDT op-log gives the deltas for free, and this is the IVM framing from `first-class-concepts.md`
   (maintain the view incrementally) recurring.
2. **A coordination protocol.** Without one, agents *thrash* — two of them fighting over the same
   lines. Options: intent-broadcasting / soft locks ("I'm editing region X", itself a tiny
   LWW-register CRDT), or a dedicated **resolver agent** (Magentic-One's progress-ledger role applied
   to a document). A raw CRDT with no coordination just gives you fast, conflict-free *garbage*.

### Why it fits Lain's architecture cleanly

- **The doc lives in `lain-core`, out of process.** It is mutable, shared, external state — exactly
  what "sent, not stored" pushes *out* of the immutable Timeline. It rides the same msgpack-RPC
  transport as Neovim. `ext/lain` and the Timeline stay untouched.
- **The CRDT op-log *is* a Journal, and that rescues determinism.** A naive worry — "live editing is
  timing-dependent, therefore un-replayable" — is dissolved by the CRDT itself: record every op with
  its causal (Lamport / vector) metadata into the Journal; replay re-applies them in causal order and
  **converges identically**. Automerge and Loro persist exactly this log. The nondeterministic
  session becomes deterministically replayable because the op-log is the record. The bench survives.
- **Turn boundaries reconcile by snapshotting.** Gate 2 wants all `tool_result`s for an assistant
  turn in one following user message; a continuous edit stream has no clean boundary. Fix:
  content-address a **snapshot of the CRDT state at each turn boundary** into the Store. Between
  snapshots, edits are `Effect`s; at the boundary, the doc's root hash enters the Timeline. History
  stays lossless; replay stays intact.
- **It is a new subagent mode.** Alongside `Tool::Subagent.new(context: :fresh | :inherit)`, add
  `:shared_artifact` — the subagent that co-edits rather than isolates. That is the cleanest slot in
  the existing design.

### Failure modes to design against (the honest part)

- **Stale intent.** The agent reasons over a context *snapshot*; by the time its edit lands, a peer
  changed the target. CRDTs *help here specifically* — they track **logical positions, not line
  numbers**, so an edit lands where its anchor moved to, not at a now-wrong line 12. But the
  *semantic* intent can still be void; the awareness feed must be tight enough that an agent re-plans
  when its target moves.
- **Thrashing.** Needs the coordination protocol above; measure it (edit-churn per region).
- **Token cost.** N agents re-reading a shared doc is expensive. The awareness feed must ship deltas,
  not full state — the op-log again.
- **Silent semantic merge.** The original objection doesn't vanish, it *relocates*: convergence is no
  longer silent (agents observe and resolve), but a resolver or intent protocol must exist or the
  agents auto-converge into plausible nonsense.

## The other genuine fit — human ↔ agent live buffers (M4)

The plan's editable `lain://request` buffer, and shared file buffers in Neovim, are CRDTs' home
turf: the human edits a buffer while the agent edits it, and a CRDT makes them converge live. Lain
already speaks msgpack-RPC to Neovim, so a CRDT-backed shared buffer is a natural M4 collaboration
surface. This is the least controversial CRDT use in Lain — real-time collaborative editing is
exactly what these structures were built for.

## Crates, and placement by the Rust 5-test rule

| Crate | Best for |
|---|---|
| **yrs** (y-crdt, Rust Yjs) | collaborative *text editing* + the Neovim awareness protocol; battle-tested |
| **automerge-rs** | JSON-like doc CRDT with rich history / time-travel — aligns with Lain's content-addressed, replayable ethos ("git for a doc") |
| **loro** | modern fast all-rounder (text, list, map, movable tree) — one crate for doc + structured state |
| **diamond-types / cola** (Eg-walker lineage) | state-of-the-art *text sequence* CRDTs, fast, good interleaving — the file-merge core |

**Placement:** a CRDT for shared docs is I/O- and coordination-shaped (it syncs with peers and with
Neovim), so by the plan's rule it lives **out of process in `lain-core`** (tokio, msgpack-RPC), *not*
in the pure-synchronous `ext/lain`. Pleasingly, it rides the same transport already planned for
Neovim. The Timeline's own CRDT-nature stays in `ext/lain`, pure and separate.

## As a bench axis

Three editing/orchestration models, one task suite, scored as distributions:

| Model | Parallelism | Shared context | Conflict handling |
|---|---|---|---|
| single-thread | none | full (one context) | n/a |
| worktree-isolation | yes | none until merge | git 3-way / lead, late |
| **shared-artifact (CRDT)** | yes | live via awareness feed | agents + resolver, continuous |

**Metrics beyond grader score:** tokens (awareness-feed overhead), **thrash count** (edit-churn per
region), **time-to-convergent-correctness**, and context-loss events (should be *lowest* here if the
thesis holds). The hypothesis worth testing: shared-artifact editing beats worktree-isolation on
tasks with *high interdependence* (where the late-merge model discovers conflicts too late) and loses
on *cleanly decomposable* tasks (where the awareness feed is pure overhead).

## Prior art (to pull into `references/` if we pursue this)

- **CRDTs, founding** — Shapiro, Preguiça, Baquero, Zawirski, "Conflict-free Replicated Data Types"
  (2011). The G-Set / semilattice framing the Timeline already embodies.
- **Text CRDTs** — RGA (Roh et al. 2011); YATA / Yjs; **Eg-walker** (Gentle & Kleppmann, 2024,
  implemented as `diamond-types`); Fugue (Weidner & Kleppmann, 2023) on interleaving anomalies.
- **JSON / document CRDT** — Automerge (Kleppmann & Beresford, "A Conflict-Free Replicated JSON
  Datatype", 2017).
- **Blackboard architecture** — Hayes-Roth (1985); Hearsay-II. The shared-artifact model's ancestor.
- **OT vs CRDT** — the operational-transform alternative and why CRDTs won for decentralized settings
  (worth a paragraph so we choose deliberately).

## Open questions

- Does shared-artifact editing actually reduce context-loss vs. worktree-isolation, or does the
  awareness feed just cost tokens? (The headline experiment.)
- Soft-lock / intent protocol vs. dedicated resolver agent — which coordination layer wins?
- Snapshot-at-turn-boundary granularity: every turn, or every N ops? What keeps replay cheap without
  bloating the Store?
- Does the awareness feed belong in-context (the model sees peer ops) or as a tool the agent polls?
  Push vs. pull, the same question the memory sweep asks.
- For medical synthesis specifically: is there *any* shared-artifact analog (co-authoring a
  structured review), or is this purely a coding-domain capability?
