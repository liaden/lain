# Chunk — undo reachability (what the modes chunk left)

status: proposed 2026-09-11 -- requirements draft, not yet grounded or carded. Run `/create-plan`
over it; every `file:line` below comes from the 2026-09-11 audit and must be re-grounded first.

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
