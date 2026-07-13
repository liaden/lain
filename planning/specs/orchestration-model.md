# Spec — Orchestration model (M5)

> Status: `[exp]`, specced. The load-bearing M5 design: how subagents, the human, roles, and the
> concurrency model fit together. Companion to `ROADMAP.md` (M5), `remaining-work.md` (5-0, 5-1),
> `orchestration-experiments.md` (the arms this machinery enables), and `crdt-exploration.md`
> (shared-artifact editing). Unit IDs `OM-<n>`.

## The one idea everything hangs on: event sourcing

State is **never mutated**; it is a **projection (fold) over an append-only, content-addressed event
log**. Lain is *already* this — turns are events, the `Store` is the log, and `Context#render` is a
projection. M5 extends the same model to orchestration:

- **Agents emit attributed events** (messages, spawns, tool calls, results) into the content-addressed
  Store — one log, extended from "conversation turns" to "all orchestration events."
- **A mailbox is a projection** — the events addressed to a recipient, folded. Not a live mutable
  queue; a *view* over the log (the same relationship as `Context#render` to the Timeline, and
  OpenHands' `View` to its event store).
- **Supervision / restart is replay** — rebuild a crashed agent's state by folding its events to the
  last content-addressed checkpoint.

This is why the industry (OpenHands' event store, the orchestration-trace papers) converges here, and
why it unifies the pieces that otherwise look separate: the Timeline, the Journal, memory, the
Workspace Timeline, the CRDT op-log, and now orchestration are **all the same event-sourced substrate
with different projections.** `Context#render` is the read-side; the Store is the write-side (a CQRS
shape). Keep this in mind for every unit below.

## Concurrency substrate: fibers (decided)

Commit to **fibers via `Async`** (the socketry ecosystem — `async`, `async-io`, `async-container`,
etc.; https://github.com/socketry is the reference toolkit). Consequences the design assumes:

- **Single-thread reactor → the `Store` needs no lock.** (The M1 `Monitor` stays as a cheap guard;
  it's correct and costs nothing.)
- **`Async::Task#stop` is real structured cancellation** — load-bearing for a loop bounded by
  `max_iterations`, cost ceilings, and user interrupts (`Thread#kill` can't do this safely).
- **Promises/futures are natural** — an awaited value blocks the *fiber*, not the reactor (see
  `ask_human`).
- **Known risk (spike first, 5-0.1):** `Mixlib::ShellOut` blocks on `IO.select`/`Process.waitpid2`;
  if the Async scheduler doesn't hook them, one `bash` stalls the reactor. **Fallback:** offload
  shellouts to a thread. Prove this before building on it.

## Two subagent modes, both event consumers

| Mode | Shape | Renders into parent? | Use |
|---|---|---|---|
| **one-shot** (`:fresh` / `:inherit`) | fresh-root, attenuated, **final-result-only** into the parent Timeline (gate-2, within-turn) | only the final `tool_result` | fan-out work; the existing 5-1 model |
| **long-lived actor** (`:actor`) | supervised fiber + **mailbox projection**; persists across turns; exchanges messages | selectively, via messages the parent chooses to fold in | ongoing collaboration; the message-DAG |

Both write events to the same Store; they differ only in lifecycle and how much of their event stream
the parent projects into its prompt. **Lifecycle is one of two spawn axes:** *prefix strategy* —
whose cache prefix the child's rendered bytes share (fresh-root | fork-the-parent | sibling-template)
— is orthogonal and carries real money (`planning/specs/cache-economics.md` CE-4). The `:fresh` /
`:inherit` hint above is that axis half-named; make it a policy object at the spawn seam so
fork-worker and cache-sibling fan-out are arms, not rewrites. **The crux to hold:** one-shot subagents commit within a turn
boundary (gate 2); a long-lived actor emits events *continuously*, but those events live in the Store
**attributed** and do **not** all render into the parent's prompt — the parent folds in only the
messages it chooses, at its turn boundaries. The turn-boundary invariant survives because rendering is
a projection, not the log itself.

## `ask_human` is a promise

`ask_human(question)` emits an outbound event to the human's inbox and **returns a pending promise**.
The agent keeps working; **awaiting the promise blocks only if it's still unresolved when the answer
is actually needed** (the user's framing). This gives both modes from one mechanism:

- **Synchronous gate** falls out when the agent awaits immediately.
- **Async continue** falls out when the agent proceeds (or speculatively branches, 3c-5.6) and awaits
  later.

Fiber-friendly: awaiting a promise parks the fiber, not the reactor. The human is a capability-gated,
high-latency agent whose replies are just events in the log.

## Role catalog

Roles are **attenuated subagents + a role prompt-slot** — a three-way join of subagent attenuation
(5-1.2), role slots (PS-3, `.lain/slots/role/<name>.md`), and (for the test-engineer) the
grader pipeline (GG-2).

- **Ship a built-in catalog:** dev, test-engineer (authors Gherkin → graders, GG-2), reviewers
  (SRE/perf, DBA/migrations, security/devops — dovetails the `security-review` skill), researcher,
  court-clerk (writes memory), friction-observer (lain-dev; parked).
- **User-overridable now** via `.lain/slots/role/<name>.md` (behavior) — the lain user tunes how a
  role behaves; the lain dev does the same when dogfooding.
- **User-defined roles: a longer-term goal** — declare a new role's toolset + slot from scratch.

## Supervision & restart

OTP-style: a supervisor fiber restarts a crashed agent by **replaying its events to the last
content-addressed checkpoint** (Store for conversation, Workspace Timeline for files). This is the
same machinery as resume-as-replay (M2) — one mechanism, two triggers (crash, resume).

## Units

- **OM-0 — Adopt fibers.** Spike `Async` × `Mixlib::ShellOut` (5-0.1); offload shellouts to a thread
  if `IO.select` isn't hooked. *Builds on:* 5-0. **Acceptance:** the loop runs under `Async` with
  structured cancellation on `max_iterations`/cost/interrupt; the shellout decision is recorded in
  `docs/concurrency.md`.
- **OM-1 — The Store as the orchestration event log.** Extend the content-addressed Store to hold
  attributed orchestration events (message, spawn, result); a mailbox is a projection filtered to a
  recipient. **Acceptance:** an agent→agent message is an attributed event; a mailbox projection
  returns exactly the events for a recipient; replaying an agent's events reconstructs its state.
- **OM-2 — One-shot subagent** (the existing 5-1) as an event consumer. *Cross-ref:* 5-1.1–5-1.4.
  **Acceptance:** unchanged from 5-1 — fresh-root, attenuated, final-result-only, within-turn.
- **OM-3 — Long-lived actor subagent** (`context: :actor`). Supervised fiber + mailbox projection;
  persists across turns. *Needs:* OM-0, OM-1. **Acceptance:** an actor retains state across turns; its
  mailbox is a projection (not a mutable queue); `child.meet(parent)` semantics still hold; its events
  don't all render into the parent prompt.
- **OM-4 — `ask_human` as a promise.** Returns a pending future; await blocks only if unresolved.
  *Needs:* OM-0; integrates with 3c-5.6. **Acceptance:** the agent continues after `ask_human`;
  awaiting an unresolved promise parks the fiber; a reply resolves it; sync-gate and async-continue
  both fall out with no extra API.
- **OM-5 — Role catalog.** Built-in attenuated-subagent roles + `.lain/slots/role/<name>.md`
  overrides; the test-engineer produces graders. *Needs:* 5-1.2, PS-3, GG-2. **Acceptance:** a built-in
  role spawns with its attenuated toolset + role slot; an override changes only that role. *(User-defined
  roles: deferred.)*
- **OM-6 — Supervision & replay-restart.** A supervisor fiber restarts a crashed agent by replaying
  events to the last checkpoint. *Needs:* OM-1, Workspace Timeline (M4), M2 resume. **Acceptance:** a
  killed actor restarts from its last content-addressed checkpoint; the same code path serves M2
  session resume.

## Interdependency map

```
5-0 concurrency (fibers/Async) ──► OM-0 ──► OM-3 actor ──► OM-4 ask_human promise
                                        └──► OM-6 supervision ──► [Workspace Timeline M4] + [M2 resume]
Store (event log) ── OM-1 ──► mailboxes (projections) ──► message-DAG ──► [speculative branching 3c-5.6]
5-1 subagent ── OM-2 one-shot ─┐
PS-3 role slots ───────────────┤──► OM-5 role catalog ──► test-engineer ──► GG-2 grader ──► [Grader::Fixture 3c-5.3]
GG-2 grader pipeline ──────────┘
6-1 exec boundary ──► code-mode roles (5-4.3)
OM-1/OM-2/OM-3 (the machinery) ──► orchestration arms (lain-dev experiments, Compare)
```

## Audience

The **machinery** (subagents, actors, roles, mailboxes, `ask_human`) is **lain-user-facing** — it's
how the user gets work done with a team on their project. The **arms comparison** (single-thread vs.
orchestrator-worker vs. dual-ledger vs. …) is **lain-dev-facing** — a bench experiment over that
machinery. Same substrate, two purposes.

## Open questions

- **Mailbox projection cost.** Filtering a growing log per recipient needs an index — a Rust roaring
  bitmap keyed on recipient (the plan's `roaring` binding) or a `petgraph` causal index. Per-turn
  projection must stay cheap.
- **Actor lifecycle / GC.** When is a long-lived actor archived? (Event-sourced → archival is a
  tombstone event, never a delete.)
- **Gate-2 vs. continuous actor events.** One-shot commits within a turn; an actor emits continuously.
  The invariant holds because rendering is a projection — but the *policy* for which actor messages
  the parent folds in, and when, needs pinning (likely a Context combinator over the mailbox).
- **Event schema.** What is the minimal attributed-event shape (kind, from, to, payload-digest, causal
  parents) that serves messages, spawns, and results uniformly? This is the schema the whole model
  rests on — design it once, carefully.
- **Attenuation ↔ position-0 (OM-5 × cache).** Tools render at position 0 of the prompt, so per-role
  *schemas* give every role a different byte-0 prefix — forfeiting all sibling cache sharing
  (CE-4's sibling-template arm). Options: schema-level attenuation (model sees only its tools; cache
  pays) vs Handler-level enforcement over a union schema (cache shares; the model can *attempt*
  disallowed tools and be refused — enforcement was always the Handler's anyway, since tools are
  capabilities). Benchable: behavioral benefit of schema attenuation vs its measured cache-write
  cost. Decide before OM-5 code exists. See `cache-economics.md` open questions.
- **Fan-out staggering.** Cache entries become probe-able only when the writer starts streaming, so
  simultaneous sibling spawns all pay full prefill. The orchestrator needs the Provider's
  `stream_started` Channel signal (CE-5) to release sibling 1, await first token, then release the
  rest. A scheduling policy over the spawn seam, not a Store event.
