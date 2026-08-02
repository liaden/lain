# How lain merges its own workers' work

status: planned, not started
written: 2026-08-02
grounding: verified against git 2.43.0 in throwaway repos on 2026-08-02; every claim
           below marked VERIFIED was executed, not recalled

## The problem, stated once

A lain fleet spawns N workers into isolated worktrees. Their work has to come back. Today
`Isolation::Worktree::Handback` runs one merge per worker (`handback.rb:486`,
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

Not octopus. **Partition deterministically, batch the resolver, verify once.**

1. Probe each worker ref with `merge-tree --write-tree`. Clean ones cost nothing.
2. Merge the clean subset sequentially onto an integration ref, journaling each handback
   `Outcome` as it lands, so per-worker attribution survives in the record even though the
   suite runs once.
3. Collect the conflicted subset and spawn **one** `merge_resolver` over the aggregate. The
   resolver must be given the intended ORDER, not just the hunks: merging A then B means B
   integrated against A, and a resolution that satisfies each pair need not satisfy the whole.
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

So `handback.rb:486` grows explicit, injected options rather than inheriting them:

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

## Open questions

- Does the batch resolver get the whole conflict set in one prompt, or one prompt per file with
  a shared preamble naming the others? The first is cheaper and sees the whole; the second is
  smaller per call and matches the merge-driver shape.
- Where does the integration ref live? `refs/lain/integration/<wave>` alongside
  `refs/lain/worker/<worker>` is the obvious answer and inherits that namespace's reasoning
  (invisible to `git branch`, so no leaked-branch bleed).
- Does a batched merge need its own record kind, or is a collection of `Report`s plus the
  integration ref enough to reconstruct what happened?
