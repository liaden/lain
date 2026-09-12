# Chunk — undo reachability (what the modes chunk left)

status: landed 2026-09-11. Carded into `chunk-implement-epic.md` and executed there, so what
follows is the record of what was owed rather than a draft to plan from. Every `file:line` below
is from the 2026-09-11 audit and has since moved.

`/undo` is registered and reverts exactly the undone turn's own paths. The redesign that got it
there is the one departure worth reading: a snapshot is a **delta**, not a whole workspace, so
undo walks the `git diff-tree` rows between that turn's before-tree and after-tree and restores
path by path. It refuses by name rather than guess when a path has no earlier record, and offers
`/undo skip` to take the rest. The whole-workspace restore, and so `restart.rb`, is unchanged.

The five smaller items owed alongside it also landed: the in-process snapshot log, the snapshot
scope rebinding on a `/mode` flip, a resolved toolset digest on `Telemetry::ModeSwitch`, the
`SignoffQueue::Decision` guard (fixed for roughly 58 untyped validators, not the ~30 estimated
below), and the prompt's mode indicator, which now reaches `RunState` from the switchboard.

**Deferred, and the one case `/undo` still refuses:** recording a file's pre-image before its
first write under the `write_set` scope.

## Intent

`chunk-modes-approval-undo.md` landed 22 of 23 cards on 2026-08-02. What it did not land is the
half that makes `auto` defensible: **reversibility**. `ShadowGit` exists and works, `/undo` does
not, and nothing on the chat path can read a snapshot back. This chunk is that remainder, plus
the two smaller things the same audit found shipped but unwired.

The safety argument for `/mode auto` is "whatever it does can be undone". Today that argument
has nothing behind it, and `/mode auto` is four characters away.

## What is owed

1. **An in-process snapshot log a projection can fold.** The real blocker. `Workspace::Restore`
   needs a `projection:`, and on the chat path `:snapshot` events reach the Store and become
   unreachable: no `render_parent`, no forward enumerator on `Store`, and `Agent` builds
   `Workspace::Snapshot.new` with every default, so the `observer:` seam goes unused. The only
   `Event::Projection` construction outside a mailbox is `supervisor/restart.rb`, over a
   *supervisor recording*.
2. **Bind the snapshot scope on a posture flip** (the modes chunk's release gate 3).
   `switchboard.rb:314-316` says `snapshot_scope` is deliberately not bound and the rung is
   owed; `Agent` needs a replaceable `snapshot_writer:` slot for it.
3. **`/undo`** -- the modes chunk's T14 as written, once 1 and 2 exist. Registered through
   `cli/command/surface.rb`, which is where commands are actually registered.
4. **A resolved-toolset digest on `Telemetry::ModeSwitch`** (release gate 1). The record carries
   posture and layer names only (`telemetry/switches.rb:42-47`), and `Grader::ToolSteering`
   takes the declared tools from the session header alone (`grader/tool_steering.rb:116-126`),
   so a graded run that changed posture is scored against tools the agent was never shown.
5. **The `SignoffQueue::Decision` guard.** Untyped attributes validated by `inclusion:` pass an
   empty Array, because ActiveModel's clusivity check uses `all?` on an Array value
   (`signoff_queue.rb:94-103`). **Not reproduced on 2026-09-11 -- reproduce before carding.** The
   fix is typed attributes or `validates_each`; the same shape sits on roughly 30 untyped
   `Guard` attributes, so the card owns an audit, not one line.
6. **Wire the prompt's mode indicator.** The modes chunk counted T7 as landed, but `wiring.rb:274`
   builds `RunState` with no `mode:`, and `prompt_composer.rb:327-330` still reads "nil until the
   mode ladder is wired into a live chat". One line plus a spec on the production construction.

## Decide before carding

- **Does the scribe wiring owed in `workspace/snapshot.rb` produce an in-process readable log, or
  only a durable record?** That debt is about persistence (a replay-restart restoring from
  journalled blobs). Item 1 is about reachability inside one live process -- `/undo` has to see a
  snapshot taken thirty seconds ago. The answer decides whether item 1 rides on that wiring or
  is its own card, and it settles the log's lifetime and memory bound.
- **Is `ShadowGit` the scope for every posture, or only for `auto`?** Nothing has measured it,
  because it has never run on the chat path.
- **Should the shell exclusion set ship non-empty by default?** Left open by
  `chunk-shell-term-approval.md`.

## Already settled elsewhere

- Release gate 2 (the escalation ladder was a pass-through) is closed: triage wired in
  `9ca19cc6`, one shared verdict in `e92a97d6`, fully-safe pipelines auto-approved in `bb55485d`,
  rules from `Project::Consent`.
- `--yolo` was deleted by `chunk-qa-round10-one-gate-one-record.md`, so the modes chunk's
  "`--yolo` still means auto" scenario is void.

## Manual passes this unblocks

The modes chunk's own manual checks for `/undo` -- restore after tool writes, and restore after a
`bash` command that created and deleted files no lain tool touched, with `git status` unchanged --
cannot run until items 1-3 land.
