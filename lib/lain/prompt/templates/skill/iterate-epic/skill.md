---
description: Restructure an existing epic.md — split an issue, merge two, or add one discovered mid-flight — carrying provenance, and re-emit it through the grammar for a fresh epic_plan gate. Use when the shape of an epic turns out to be wrong.
slots:
  - conventions
---
# iterate-epic

An epic's shape is a guess until work starts. This skill is how that guess is corrected without
losing the history of why. You are restructuring the issue graph, not implementing anything and
not re-planning the epic from scratch.

<%= render("conventions") %>

## Phase 1 — Read the current epic

Read `epic.md` back through the epic home (`Epic::Home.resolve`). Read it, do not assume it:
statuses have moved since it was written, and the graph you are editing is the one on disk.

Note what the graph derives rather than stores — which issues are `ready`, what the waves look
like, what blocks what. That is usually where the wrong shape shows up.

## Phase 2 — Apply exactly one kind of change at a time

Three operations, and each one keeps every third party pointing at something the graph still
holds:

- **Split** an issue into parts. Every part inherits the original's outbound edges, and every
  edge anywhere that named the original comes to name every part — so whoever waited on the
  whole now waits on all of it. **Every part's provenance is set to the split issue, even if
  the part declared its own**: the split is the reason the part exists, and that is not
  overridable.
- **Merge** two issues into one. The result inherits both their edge sets on top of its own,
  minus the self-references the rewrite would otherwise create. Provenance is whatever the
  merged issue declares — a merge has two parents and provenance holds one, so the choice is
  yours to make explicitly rather than have guessed for you.
- **Add** an issue discovered mid-flight. Nothing is removed; the caller may name the
  provenance, and if it does not, the issue's own declared provenance stands.

Never edit the graph by rewriting `epic.md` by hand when one of the three applies. The
operations do the edge rewrite; a hand edit is where a dangling edge comes from, and the error
it eventually raises blames the author rather than the edit.

### Abandoning an issue does not unblock what it blocked

The one trap in this skill, because it fails silently. `ready` means pending with every blocker
**done**, and `abandoned` is not `done`. So marking a blocker `[!]` leaves everything behind it
blocked forever: nothing raises, nothing warns, the dependent simply never becomes ready and
the wave it sits in never opens.

Unblocking is an **edge edit**, not a status change. Abandoning an issue is two steps: mark it
`[!]`, and then drop the dependents from **its own** `Blocks:` line — that line is the abandoned
issue's outbound edge, and deleting the whole line is right when it named nothing else. None of
the three operations does this for you; editing the link line is the correct hand edit, and it
is the only one.

Afterwards, re-read the graph and check that whatever you meant to free is actually `ready`.

Here is a split, before and after. Before — one streaming issue blocking the subcommand:

````markdown
### [~] `export-stream` Stream records to disk as they land

Writes each record as the session produces it rather than buffering the whole transcript.

Blocks: `export-subcommand`

### [ ] `export-subcommand` Expose the exporter as a subcommand

The user-facing door. One directory argument.
````

After splitting it into a buffer and a drain:

````markdown
### [~] `export-stream-buffer` Size the write buffer from the record rate

The buffer the writer drains into. Sized from the observed record rate, not guessed.

Blocks: `export-subcommand`
Discovered from: `export-stream`

### [ ] `export-stream-writer` Drain the buffer to disk without blocking the session

The drain loop. Runs behind the session so a slow disk never stalls a turn.

Blocks: `export-subcommand`
Discovered from: `export-stream`

### [ ] `export-subcommand` Expose the exporter as a subcommand

The user-facing door. One directory argument.
````

Read what the rewrite did: both parts carry the inherited `` Blocks: `export-subcommand` ``
line, both carry `` Discovered from: `export-stream` `` — the split id, not anything they
declared — and `export-stream` itself is gone. Its id still appears, as provenance.
`Discovered from:` is the one link kind allowed to name an issue the graph no longer holds,
and this is exactly why.

## Phase 3 — Re-emit through the grammar

Write the epic back through the epic home, which renders the graph rather than patching the
file. That render is the honesty check: an issue the grammar cannot write back verbatim is
refused by name, and nothing is silently reinterpreted.

Two things it will do that are correct and may still surprise you:

- Issues come back **sorted by id**, not in your edit order.
- **Preamble prose above the first heading is dropped.** It was never part of the epic. If
  something up there mattered, it belongs in an issue description or in `research.md`.

If the render refuses, fix the value it names — do not soften the document to get past it.
A refusal before the write means the previous `epic.md` is untouched, which is what you want
when you are mid-review.

## Phase 4 — Re-request the epic_plan gate

A restructured epic is a new artifact with a new digest, so it needs a fresh sign-off at the
`epic_plan` stage. An earlier approval was of a different graph.

If the gate reports the stage is blocked, this epic still has parked sign-offs at an earlier
stage; drain them with `lain epic queue` and `lain epic approve DIGEST` / `lain epic deny
DIGEST`. Say plainly what changed and why, so the reviewer is signing off on the delta rather
than re-reading the whole epic.
