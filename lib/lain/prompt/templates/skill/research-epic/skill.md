---
description: Open an epic by interviewing the user for intent, then grounding that intent against the code, and write research.md into the epic home for the research gate. Use when starting a new epic, before anything is planned or decomposed.
slots:
  - conventions
---
# research-epic

Produce `research.md`: what this epic is for, what the code already does about it, and what is
still open. You are not decomposing here and you are not writing code — `plan-epic` reads what
you produce and cuts the issues.

<%= render("conventions") %>

## Phase 1 — Interview FIRST

Unlike `create-plan`, this skill asks before it reads. Intent is not recoverable from a
codebase: no amount of grounding tells you which of three defensible scopes the user wants, or
what they will consider done. So your first act is a short round of questions, asked
proactively rather than waited for.

Ask what only the user can answer:

- What is the epic FOR — the outcome, stated as something a person can observe.
- What is explicitly out of scope, and what is merely not-yet.
- What already exists that this must not break.
- What "done" looks like, concretely enough to become acceptance criteria later.
- Which constraints are fixed (a deadline, a dependency, an interface someone else owns).

Ask few questions and ask them together. Do not ask what Phase 2 could verify.

## Phase 2 — Ground the answers against the code

Now read. Fan out parallel `researcher` sub-agents (`@researcher[/skill]` for a fresh-context
probe) over every seam the answers named: the files, the utilities worth reusing, the specs
that pin current behaviour.

Record where the user's picture and the code disagree. Each disagreement is either a question
worth one more round or an open question `research.md` carries forward — never something you
quietly resolve on your own.

## Phase 3 — Write research.md

Reach the epic home through `Epic::Home.resolve` rather than building a path by hand: it is the
only door — the constructor is private — and it checks the slug, which matches
`/\A[a-z0-9][a-z0-9-]*\z/`: lowercase letters, digits and dashes, opening with a letter or a
digit. Resolving is otherwise pure, and creates nothing; the directories arrive on the first
write, and that is also where a path escaping the home is refused.

An epic home holds exactly four kinds of artifact: `research.md`, `epic.md`, `issues/<id>.md`,
`plans/<id>.md`. By default it lives under XDG state, so an epic never shows up in
`git status`; a project opts in-repo with `[epics] home = "repo"` in `.lain/config.toml`, which
puts it at `.lain/epics/<slug>/` where a team can review it in a pull request.

Nothing else belongs in `research.md`. In particular there is no status field: an issue's live
status is the Journal fold, not a file, so nothing in this directory can disagree with the run
that produced it.

Structure it so `plan-epic` can decompose from it alone:

- **Intent** — the outcome, in the user's terms, and the scope boundary they drew.
- **What the code does today** — per seam, with file paths, and what each is already good for.
- **What is missing** — the gap between the two, which is the material the issues get cut from.
- **Open questions** — everything unsettled, each one named rather than averaged away.
- **References** — the paths, specs, and docs a later reader should not have to re-find.

## Phase 4 — Request the research gate

Submit `research.md` to the gate at the `research` stage. What happens next is the session's
gate policy, not your choice:

- `interactive` — a human answers.
- `hands_off` — approved immediately, and audibly: the decision still lands in the Journal
  attributed to the policy that gave itself the answer.
- `deferred` — refuses now and parks the question for a human to sign off later. The refusal is
  a real, journaled denial: deferring is not a soft yes, and nothing about it opens a gate.
  What parks is the artifact's address and its question — **no evidence is gathered and no
  model is asked.** A reviewer coming to it later reads the question and goes and looks.

Parked sign-offs are drained with `lain epic queue`, then `lain epic approve DIGEST` or
`lain epic deny DIGEST`. Tell the user this is where their epic now sits.

Stop after the gate. An approved `research.md` is this skill's whole deliverable.
