# How lain merges its own workers' work

status: landed 2026-09-11, through `specs/chunk-implement-epic.md`. All three of the 2026-09-11
        rulings are implemented: a worker branches from a working branch rather than the parent's
        HEAD, it rebases itself and verifies every patch survived before it hands back, and
        worktrees, leases and anchors are reaped by `lain worktrees gc`. Read the sections below
        as the reasoning behind the code, not as a proposal.
        **One spelling here is wrong:** git has no `--conflict=zdiff3` flag. Lain passes
        `-c merge.conflictStyle=zdiff3` and `-X diff-algorithm=histogram`, which keeps the
        argument of the "on lain's command line, not in git config" section intact.
written: 2026-08-02
grounding: verified against git 2.43.0 in throwaway repos on 2026-08-02; every claim
           below marked VERIFIED was executed, not recalled. Code citations re-read
           against the tree on 2026-09-11.

## The problem, stated once

A lain fleet spawns N workers into isolated worktrees. Their work has to come back. Today
`Isolation::Worktree::Handback` runs one merge per worker (`handback.rb:461`,
`@parent.run("merge", "--no-edit", ref)`) and `Isolation::WorkerHandoff` spawns a
`merge_resolver` role when that merge conflicts. Both are per worker, one at a time.

That is correct and it is not cheap. Two costs, and the second is the larger one:

1. **Correlated conflicts are paid N times.** Sibling workers conflict on the same files for
   the same reason -- a shared manifest, a registry list, an index. N workers touching one
   manifest produce N instances of *one* conflict, and a resolver seeing them one hunk at a
   time is guessing N times at a whole nobody showed it.
2. **The verification is paid N times.** In this repo the gate is the full suite against the
   merged tree. That is the expensive step, not the merge and not the resolver.

The ruling that frames all of it (Joel, 2026-08-02): **a worker's commits are never
optional.** If the work was worth planning it is worth merging, so the default is to spend
whatever it takes -- deterministic first, tokens when deterministic will not do it. `Retain`
is for the crash cases (OOM, a segfault like the 4.0.5 cvar bug, kernel panic, power loss),
where the honest answer is to anchor the work and leave it recoverable, not to discard it.

## What the code does today (re-read 2026-09-11)

- **A worker branches from whatever the parent checkout has checked out, at acquire time.**
  `Worktree#add` runs `git -C <repo_root> worktree add --detach <path>` with no commit-ish
  (`worktree.rb:122-123`, `:158`), so the checkout is the parent's `HEAD` at that instant. It is
  not hardwired to `main` -- but nothing names a working branch either: a fleet launched from
  `main` branches every worker from `main`, and a worker acquired early never sees a sibling
  that landed after it.
- **Handback merges into the parent checkout's current branch**, ref first: the worker's `HEAD`
  is anchored to `refs/lain/worker/<slug>-<fingerprint>` by compare-and-swap `update-ref`
  (`handback.rb:90`, `:270`), then `git merge --no-edit <ref>` runs in the parent
  (`handback.rb:461`) with no strategy flags. A conflict leaves the parent mid-merge on purpose.
- **`WorkerHandoff#reclaim`** is that handback plus a `merge_resolver` spawn on conflict;
  **`#surrender`** anchors and spawns nothing, for the unwinding path
  (`worker_handoff.rb:237`, `:245`).
- **Chat wires neither.** `Supervisor` defaults to `handoff: Retain` (`supervisor.rb:45`), whose
  `surrender` answers `Report.nothing` and keeps the crashed worker's worktree until `#stop`
  (`supervisor.rb:337-348`). No chat hands work back yet (epic wiring chunk, T20 deferred).
- **Nothing is ever garbage-collected past a lease.** Release force-removes the worktree
  (`worktree.rb:139`) and a stale one is reaped before the next acquire of the same worker id
  (`worktree.rb:152`), but no code deletes a `refs/lain/worker/*` anchor, a promotion branch
  under `refs/heads/epic/<slug>/<issue>` (`forge/promotion.rb:93`), or a retained worktree.
  They accumulate forever.
- **There is no `[isolation]` config table.** `.lain/config.toml` knows `approval`, `epics`,
  `sensitivity`, `shell` and `interactive` (`config.rb`). And there is no scheduler anywhere in
  lain: `lain up` and `Lain::Notify` poll only while a session is live, and `crates/lain-core` is
  an exec RPC daemon, not a timer.

## Where a worker branches from

**Ruling (Joel, 2026-09-11): every worker branches from the HEAD of the working feature branch
-- the integration branch the plan or epic is building -- and never from `main`.** Branching
each worker off `main` makes every worker re-derive the same integration against a base its
siblings have already moved past, so conflicts accumulate with the number of waves. That is not
hypothetical: it is exactly what a `/execute-plan` orchestrator did when its worktrees kept
branching from `main`.

The code is one step away and it is not a safe default as it stands, because "whatever the
parent has checked out" is only right if the parent happens to be standing on the working
branch. **Required change:** `Worktree#acquire` takes the base explicitly --
`worktree add --detach <path> <base>`, where `<base>` is the working branch's current tip, read
at acquire time and journaled on the lease -- and refuses rather than falling back to the
parent's `HEAD` when no base is named. A later wave acquires from the tip *after* the earlier
wave landed, which is what makes the next section's fast-forward reachable at all.

## A worker brings itself current before it hands back

**Ruling (Joel, 2026-09-11): the worker, not the orchestrator, is the first resolver of its own
conflicts.** Before handback, a worker rebases onto the working branch's *current* tip (or
merges it in, where rewriting its history would lose something worth keeping) and settles
whatever conflicts that raises -- with its own context of what it changed and why, which is
precisely the context a resolver spawned afterwards lacks. Done well, its handback is a
fast-forward and costs the orchestrator nothing.

The strategy rulings below apply to the worker's rebase exactly as to the parent's merge: lain
passes `--conflict=zdiff3` and the diff-algorithm choice on the command line, and journals them.

**Costs, stated honestly.**

- The target moves. A worker that rebased onto tip T hands back while a sibling lands T+1, so
  "it was current when it finished" is not "it fast-forwards now". Landing is **serial**, so
  this is detected rather than raced: each handback re-probes against the tip it is landing
  onto, a worker that no longer fast-forwards is either sent back to rebase once more or falls
  into the batch below, and nothing merges against a tip it was not probed against.
- A worker's self-resolution is still unverified. It ran its own card's specs, not the
  combined tree's suite, so the single suite gate below stays the real verification.
- It spends the worker's tokens, not the orchestrator's. That is the point -- the worker's
  context already holds the change -- but it is a cost the bench should see, so the rebase and
  its conflict count are journaled on the handback.

## What git can actually do

**VERIFIED: octopus is an all-or-nothing detector, not a partial merger.** `git merge w1 w2 w3`
with any conflicting head fails wholesale -- `"Automated merge did not work. Should not be
doing an octopus."` -- and merges *nothing*. It is useless as a way to land the clean subset,
and excellent as a single cheap question: does this whole wave integrate?

**VERIFIED: one merge commit with N parents CAN carry a resolved tree.** Git's commit object
does not care how the tree was produced:

```bash
TREE=$(git write-tree)                       # after resolving, however you resolved
OCTO=$(git commit-tree "$TREE" -p main -p w1 -p w2 -p w3 -m "...")
```

That produced a commit with four parents whose tree held the aggregate resolution. Two honest
costs: nothing ever tested that combination, and per-worker bisect granularity is gone. A
reader of `git log --graph` also sees a clean 4-way merge that git itself would have refused.

**VERIFIED: `merge=union` resolves append-shaped conflicts outright.** Two branches each
appending a different line at the same place merged clean, keeping both.

**`git merge-tree --write-tree`** (present in 2.43) is the right partition probe: it merges
without touching the working tree or the index and reports conflicts. Better than octopus for
"does this integrate", because it answers per pair without changing anything.

**`rerere`** is the best fit for the correlated-conflict case, because recurring conflicts are
exactly what it is for. Its cache lives in `.git/rr-cache`, shared across all worktrees of the
repo, so a resolution made once is replayed for every later wave and every re-merge.

## The shape to build

Not octopus. **Workers settle their own conflicts first; then partition deterministically,
batch the resolver over what is left, verify once.**

0. Each worker branched from the working branch's tip and rebased onto its current tip before
   handing back (the two sections above). Most workers arrive as fast-forwards; this step is
   what keeps the rest of the list short.
1. Probe each worker ref, **in landing order**, with `merge-tree --write-tree` against the tip
   it would land on. A fast-forward or a clean merge costs nothing.
2. Land the clean subset sequentially onto the integration ref, re-probing each against the tip
   the previous one produced, and journaling each handback `Outcome` as it lands, so per-worker
   attribution survives in the record even though the suite runs once. A worker whose clean
   probe goes stale mid-sequence drops to step 3, or goes back to its worker for one more
   rebase if it is still alive.
3. Collect the conflicted subset -- only what the workers could not or did not settle -- and
   spawn **one** `merge_resolver` over the aggregate. The resolver must be given the intended
   ORDER, not just the hunks: merging A then B means B integrated against A, and a resolution
   that satisfies each pair need not satisfy the whole. The orchestrator is the fallback here,
   never the default.
4. Run the suite once against the combined tree. That run is the gate.

`Isolation::WorkerHandoff::Report` already has the vocabulary for this
(`nothing_to_do / merged / resolved / conflicted / declined / failed`), so a batch result is a
collection of Reports rather than a new record type. The batching collaborator sits ABOVE
`#reclaim`, which stays per-lease.

## Strategy options belong on lain's command line, not in git config

**Ruling (Joel, 2026-08-02).** The merge tuning lain uses must be flags lain passes to its own
merge invocation, never ambient git configuration.

The reason is that git config is machine state. Setting `diff.algorithm` or
`merge.conflictStyle` in `~/.gitconfig` or `.git/config` changes how *whoever is working on
this repo* experiences merges -- today that is Claude and its subagents -- and says nothing
about how **the lain loop** behaves when it is the one merging. Those are different systems
that happen to share a checkout. lain's behaviour has to be legible from lain's own code and
reproducible on a machine whose git config nobody has touched.

So `handback.rb:461` (and the worker's own rebase) grows explicit, injected options rather
than inheriting them:

- `-X patience` or `-X histogram` (or `--diff-algorithm=`), selectable, because list-shaped
  files -- manifests, registries, tool rosters -- are exactly where Myers misaligns hunks and
  invents conflicts that are not semantic.
- `--conflict=zdiff3` on the merge itself, so conflict markers carry the MERGE BASE. This is a
  large quality win for a resolver specifically: with plain `merge` style it sees two final
  states and has to infer intent; with the base it sees what each side actually changed.
- whitespace tolerance (`-X ignore-space-change`, `-X renormalize`) where a repo wants it.

Defaults live in lain's config, not in git's, and every value is journaled with the intent so
the experiment record says which strategy produced which outcome. That is the bench
requirement, not a nicety: "the merge succeeded" is not a finding unless the record says under
what strategy.

## `.gitattributes` is a knob the FRICTION agent proposes

`merge=union` is worth a great deal here, and it is also the kind of thing nobody sets until
they have been hurt three times. That makes it `Lain::Friction`'s business, not a constant
someone hardcodes: M1's observer is for the lain USER and its whole job is "which existing
knob should you turn", against a folded session Journal with no model call.

The signal is already journaled. Handback outcomes name the conflicted paths (`Report#paths`
on a `:resolved`, the ref on every outcome that left work behind), so a fold over a project's
journals answers "which paths conflict repeatedly, across how many distinct workers" without
inventing new records. A path that conflicts across many workers, where the conflicting hunks
are ADDITIONS rather than edits to shared lines, is a union candidate and the report can say so
with its evidence attached.

**It must propose, never apply.** Union is wrong for ordered files, and this repo holds the
exemplar: `lib/lain.rb` is a topological load-order manifest, so union keeps both requires and
silently produces the wrong ORDER, whose symptom is a load-time `NameError` from a merge git
called clean. `spec/support/tool_registry.rb` and the `FALSE_TOOLS` roster are unordered and
are good candidates. The distinction is semantic and a human makes it -- which is exactly the
propose-with-evidence shape Friction already has.

## Custom merge driver: the LLM as a git merge driver

The most interesting option, and its own card. `.gitattributes` can route a path to an
arbitrary program:

```
lib/lain.rb  merge=lain-resolver
```

with the driver registered in config as a command receiving the base, ours, theirs and the
output path. Git then invokes the resolver **only for the files that actually conflict**,
inside the merge it is already running.

What that buys over the current spawn-after-the-fact shape:

- The resolver is scoped to ONE file with its base, which is a far smaller and better-posed
  problem than "the merge conflicted, here is a working tree".
- Non-conflicting files never reach a model at all -- git resolves them and the driver is
  never called.
- It composes with `rerere` (a resolution the driver produces is recorded and replayed) and
  with `union` (per path, whichever fits).
- It works for any git operation, not just handback: rebase, cherry-pick, stash pop.

What it costs, and why it is a card rather than a patch:

- A merge driver is a synchronous subprocess in the middle of a git operation. An unbounded
  provider round trip inside `git merge` is the same footgun `WorkerHandoff` already names when
  it refuses to spawn a resolver while unwinding. It needs a deadline and a deterministic
  fallback (leave the conflict standing) that is loud rather than silent.
- It runs with the ambient git config, so a driver configured in `.git/config` is machine
  state -- the same objection this document raises against strategy flags. It has to be
  installed deliberately by lain and named in the record, not assumed.
- The driver sees one file and no test suite. It cannot know whether its resolution builds.
  The suite gate above stays the real verification.

## Worktree garbage collection

**Ruling (Joel, 2026-09-11): a sane default, configurable, and cleanup happens as soon as the
work is safely somewhere else.** Three triggers:

1. **Folded into the working branch.** A worker's checkout is reclaimed the moment its work is
   an ancestor of the working branch -- the branch-off-a-branch case. Release already
   force-removes the worktree; what is new is that its `refs/lain/worker/*` anchor goes with it
   once `git merge-base --is-ancestor <anchor> <working-branch>` holds, since the anchor has
   nothing left to keep reachable.
2. **The working branch merged into `main`/`master`.** Once
   `git merge-base --is-ancestor <working-branch> <main>` holds, everything that existed to
   carry that branch's work is reaped: its remaining worker anchors, its
   `refs/heads/epic/<slug>/<issue>` promotion refs, any worktree still leased to it, and the
   working branch itself if lain created it.
3. **Retained work expires.** A retained or crashed worker's lease -- the `Retain` cases, where
   no handback ran -- is kept for **7 days by default**, then reaped. Configurable as
   `[isolation] retain_days = 7` in `.lain/config.toml`, a new table beside `approval` and
   `epics`; an integer day count rather than a duration string keeps it inside the TOML types
   `config.rb` already reads.

**GC respects the anchor-first rule, and must.** Uncommitted work in a worktree is scratch by
ruling (`worktree.rb:25`), so reaping a worktree loses nothing that was not already disposable
-- but *committed* work that is on no anchor would be lost with it. So a reap anchors before it
removes, exactly as `Handback` does, and deletes an anchor only when the ancestry test proves
the commits are reachable from the working branch or `main`. An expired retained lease is
reaped as a worktree; its anchor is deleted only if its commits are reachable, and otherwise
kept and reported rather than silently dropped -- "a worker's commits are never optional" still
holds after seven days.

**Triggers 2 and 3 run as a daily background task, not only lazily.** lain has no scheduler
today (see above), so the unit is an idempotent command -- `lain worktrees gc`, safe to run any
number of times -- and the cadence is a separate concern. Two candidate triggers, either of
which satisfies the ruling:

- a detached run kicked off by any `lain` launch when a last-run stamp under `state_home` is
  more than 24 hours old, which needs no daemon; or
- a systemd user timer (and a launchd agent, for macOS) that lain installs on request and that
  calls the same command, which covers a machine where lain is not launched every day.

Every reap is journaled -- what, why (which ancestry test or which expiry), and what was kept --
so a missing worktree is always explained by a record.

## Open questions

- Which daily trigger ships first: the stamp-gated launch run, or an installed timer?
- Does a worker that fails to fast-forward after its rebase go back to the same worker (if
  still live) for one more rebase, or straight to the batch resolver? The first spends that
  worker's context well; the second bounds the latency of a wave.
- Does the batch resolver get the whole conflict set in one prompt, or one prompt per file with
  a shared preamble naming the others? The first is cheaper and sees the whole; the second is
  smaller per call and matches the merge-driver shape.
- Where does the integration ref live? `refs/lain/integration/<wave>` alongside
  `refs/lain/worker/<worker>` is the obvious answer and inherits that namespace's reasoning
  (invisible to `git branch`, so no leaked-branch bleed).
- Does a batched merge need its own record kind, or is a collection of `Report`s plus the
  integration ref enough to reconstruct what happened?
