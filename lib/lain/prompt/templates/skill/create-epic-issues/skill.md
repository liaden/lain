---
description: Walk an approved epic.md and write one issues/<id>.md per issue — prose, added Gherkin scenarios, and references — so an implementer needs nothing but that issue's view, which lain renders from the file and the graph. Use after the epic_plan gate has approved the graph.
slots:
  - conventions
---
# create-epic-issues

Write up every issue the approved `epic.md` declares, one file each. The property that matters:
**an implementer reading the issue's view needs nothing else** — not this conversation, not
`research.md`, not the rest of the epic. If the view only makes sense next to the epic, it is not done.

You are writing issues, not implementing them and not changing the graph. If the walk shows the
graph is wrong, stop and say so — restructuring is `iterate-epic`.

<%= render("conventions") %>

## Phase 1 — Walk the approved graph

Read `epic.md` with `read_file` at `<%= epic_home %>/<slug>/epic.md` (`<%= epic_home %>` is this
project's epic home) and work from the parsed graph rather than from the file's text. The graph is what answers the questions the write-up needs:

- **The issue's own fields** — id, title, description, status, and whatever acceptance criteria
  the epic already carries.
- **What it blocks**, and — derived, never authored — **what blocks it**. Ask the graph;
  `Blocked by:` is not a line anyone writes.
- **Related issues**, which are context rather than order.
- **Provenance**, which may name an issue the graph no longer holds. That is not a dangling
  reference: a split removes the issue its parts grew out of, and the id is history. Say so
  in the file rather than dropping it.

Take ids from the graph verbatim. The filename is `issues/<id>.md`, and the id is re-checked as
a filesystem name on the way out: `/\A[a-z0-9][a-z0-9-]*\z/` — lowercase letters, digits and
dashes, opening with a letter or a digit.

That check **refuses**; it does not reassure. It is stricter than the markdown grammar, which
reserves only backticks and line breaks, so `epic.md` will carry `Export_Schema` quite happily
and round-trip it — and the write here is where it dies, as a `MalformedName`. An id reaching
you is therefore *not* known to be a legal filename.

When one fails, fix it in the epic through `iterate-epic` and come back. Do not quietly
transform it into something writable: the file and the graph would stop naming the same issue,
and every link line pointing at it would go stale.

## Phase 2 — Write each issue file

`issues/<id>.md` is only the authored half of the issue. lain renders the rest every time the issue
is read: the `# <id> -- <title>` header, the issue's description from `epic.md` and the scenarios it
carries for the issue, both verbatim, and the Links (`Blocks:`, `Blocked by:`, `Related:`,
`Discovered from:`, `Subject:`, `Level:`) from the graph. So an edge edited in the graph shows in
the view with no file rewritten, and the epic's signed-off scenarios cannot drift from a copy.

Write the file with the `epic_write` tool (`artifact` is `issue`, `issue` is the id), which lands
it at `<%= epic_home %>/<slug>/issues/<id>.md`. Structure it like this:

````text
## What and why

Enough context to start cold. What the issue is for, what it touches, and what
about the current code makes it necessary. Name files by path.

## Acceptance criteria

```gherkin
Scenario: <a behaviour the epic left implicit, observable from outside the object>
  Given <the starting state>
  When <the action>
  Then <what an observer can check>
```

## References

Paths, specs, and docs the implementer should not have to re-find, each with a
line on why it matters here.
````

Do not restate the epic's description: it was signed off at the epic gate and the view already opens
with it, so your prose starts where it stops. Prose may take any `##` sections you like;
`## Acceptance criteria` and `## References` are the two names lain places in the view, after the
epic's scenarios and before the Links. Every added scenario goes under `## Acceptance criteria`;
a gherkin fence anywhere else is refused.

Write the added scenarios as Gherkin, one per behaviour, each observable from *outside* the
object — behaviour, not structure. Add only what the epic left implicit: lain renders the epic's
own scenarios above yours, and `epic_write` refuses a file that restates one of them by name.
It refuses a link line too, naming the graph as its source: change an edge in the graph, never
in this file. A `# ` header or a `## Links` heading is refused the same way, since the view
renders both.

## Phase 3 — Check each view cold

Before you gate anything, read each issue's view back with `lain epic show issues/<id>` (run it
with `bash`), as if you had never seen the epic. That is the view an implementer will read: your
file plus what lain renders around it. If you have to reach for anything outside it to know where
to start, that issue is not self-contained yet — fix the file rather than noting it.

Then check the set: every issue in the graph has a file, and no file names an issue the graph does
not hold.

## Phase 4 — Request the issue_plan gate

Review before you gate. For each wave, call `epic_review` with `stage` `issue_plan`, `slug` the epic's
slug and `wave` the wave's number: fresh read-only reviewers read that wave's issue files beside
`epic.md` and return findings ending in a verdict. Fix what they raise, then pass that wave's verdict line,
verbatim, as `review` on the `epic_submit` call for the wave: the human's question shows it as your quote.

Before you call `epic_submit`, tell the user that the gate waits <%= gate_window %> seconds for an answer
and that a reply of `deny: <reason>` sends the reason back to you.

Submit the write-ups wave by wave with the `epic_submit` tool: `stage` is `issue_plan`, `slug` is the
epic's slug, and `wave` is the wave's number: wave 1 holds the issues nothing blocks, and each later
wave the issues whose blockers sit in earlier waves, the numbering the user sees in
`lain epic status <slug>`. One
question asks about every issue in the wave, and each issue is still approved or denied on its own.
The human may answer `approve` for the whole wave, `deny: <reason>` to deny all of it, or
`deny <id>: <reason>` to deny only the issues named; the result names each issue's outcome. Fix a
denied issue's file and submit its wave again: only the issues without a standing approval are asked.
To submit one issue alone, pass `issue` (its id) instead of `wave`. The stage gates each
issue's work, so it names the issues: the tool refuses an issue_plan submit that names no issue and
no wave.

**An issue's acceptance criteria are approved together with its plan, in this one gate.** They
are not signed off separately and there is no later criteria gate: the `issue_plan` digest covers
the issue's whole rendered view, so editing the criteria — or the `Subject:` line — reopens this
gate rather than slipping past an approval that was given for different words.

The line the implementation step cannot start without lives in `epic.md`, on the issue's own
section, not in a file of its own:

````text
Subject: lib/exporter/stream.rb
Level: unit
````

`Subject:` names the one source file this issue's generated failing tests mirror, relative to the
project root; `Level:` is optional and picks the level root. A missing, duplicated or out-of-root
subject is **refused by name** — the red step places a test by mirroring a source file, and an
issue on its own names none.

Under `interactive` a human answers;
under `hands_off` it approves itself audibly; under `deferred` it refuses now and parks the
question for a human to sign off later — the refusal is journaled as a real denial, no spike
runs and **no model is asked** on the way.

Under `adjudicated` the gate tries to answer itself first: a read-only spike gathers evidence
about the issue set, journals it under its own content address, and a second model is asked for
a one-word verdict on it. A bare APPROVE or DENY settles the gate; anything less certain still
refuses and parks for a human, with that evidence attached to the parked item — or, when the
spike itself came back empty, the reason it did rather than evidence. Expect it to park; the
spike is there to make the morning review cheaper, not to sign off for you.

`epic_submit` cannot run an adjudicated stage in the chat: it refuses, and an adjudicated stage
cannot be submitted from the chat at all. When it refuses, relay the shell command the refusal names
(`lain epic submit issue_plan <slug>` with `--wave N` or `--issue <id>`, whichever you submitted) to
the user and stop. The policy descriptions above are
background for the user, not something you run. An interactive gate the user leaves unanswered
reads as no answer, and nothing advanced. A `--btw` chat cannot submit at all.

`issue_plan` sits behind two earlier stages, so its gates cannot open while this epic's
`research` or `epic_plan` sign-offs are still parked. Ask the user to drain them with
`lain epic queue` and `lain epic approve DIGEST` / `lain epic deny DIGEST`; the user can run
`lain epic status [SLUG]` to see where the epic currently stands.

## Where the epic goes after you

Writing the issues up is the last authoring step. What follows is not yours to drive, and knowing
the shape of it is what keeps an issue file honest about what an implementer will be handed:

- **`/implement-epic`** works the approved issues to the epic's own branch, one actor per issue in
  its own worktree, landing them serially. It reads exactly what you wrote here.
- **`lain epic finish`** is run by the user: it takes an epic whose every issue is done to `main`
  as one pull request. For a project with no remote, tell the user to run
  `lain epic finish --local`, which merges the finished epic into the default branch locally.

So an issue that only makes sense next to this conversation will reach an actor that does not have
it. That is the property Phase 3 is checking for.
