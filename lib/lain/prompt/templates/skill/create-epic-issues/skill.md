---
description: Walk an approved epic.md and write one self-contained issues/<id>.md per issue — description, Gherkin acceptance criteria, references, and links — so an implementer needs nothing but that file. Use after the epic_plan gate has approved the graph.
slots:
  - conventions
---
# create-epic-issues

Write up every issue the approved `epic.md` declares, one file each. The property that matters:
**an implementer opening `issues/<id>.md` needs nothing else** — not this conversation, not
`research.md`, not the epic. If the file only makes sense next to the epic, it is not done.

You are writing issues, not implementing them and not changing the graph. If the walk shows the
graph is wrong, stop and say so — restructuring is `iterate-epic`.

<%= render("conventions") %>

## Phase 1 — Walk the approved graph

Read `epic.md` back through the epic home (`Epic::Home.resolve`) and work from the parsed graph
rather than from the file's text. The graph is what answers the questions the write-up needs:

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

`issues/<id>.md` is prose, not epic-markdown: the grammar governs `epic.md` only, so this file
is yours to structure. Structure it like this:

````text
# <id> — <title>

## What and why

Enough context to start cold. What the issue is for, what it touches, and what
about the current code makes it necessary. Name files by path.

## Acceptance criteria

```gherkin
Scenario: <the observable behaviour, from outside the object>
  Given <the starting state>
  When <the action>
  Then <what an observer can check>
```

## References

Paths, specs, and docs the implementer should not have to re-find, each with a
line on why it matters here.

## Links

Blocks: <ids this finishes before>
Blocked by: <ids that must finish first — derived from the graph, stated here for the reader>
Related: <ids worth knowing about>
Discovered from: <the id this grew out of, if any>
````

Write acceptance criteria as Gherkin, one scenario per behaviour, each observable from
*outside* the object — behaviour, not structure. If the epic already carries criteria for the
issue, carry them across verbatim rather than paraphrasing; the epic's copy is the one that was
signed off. Add the scenarios the epic left implicit.

`Blocked by:` appears here and is refused in `epic.md`, and the difference is the whole point:
in the epic it would be a second source of truth for a relation the graph already derives,
while here it is a rendering of that derivation for a human who has only this file. Derive it,
never invent it.

## Phase 3 — Check each file cold

Before you gate anything, read one file back as if you had never seen the epic. If you have to
reach for anything outside it to know where to start, that file is not self-contained yet — fix
it rather than noting it.

Then check the set: every issue in the graph has a file, no file names an issue the graph does
not hold, and every id in a link line resolves.

## Phase 4 — Request the issue_plan gate

Submit the issue write-ups at the `issue_plan` stage. Under `interactive` a human answers;
under `hands_off` it approves itself audibly; under `deferred` it refuses now and parks the
question for a human to sign off later — the refusal is journaled as a real denial, and **no
evidence is gathered and no model is asked** on the way.

`issue_plan` sits behind two earlier stages, so its gates cannot open while this epic's
`research` or `epic_plan` sign-offs are still parked. Drain them with `lain epic queue` and
`lain epic approve DIGEST` / `lain epic deny DIGEST`. `lain epic status [SLUG]` prints where
the epic currently stands.
