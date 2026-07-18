---
description: Build an orchestrator-ready TDD plan (task cards, Gherkin acceptance criteria, dependency waves, escalation triggers), grounded in the actual code state. Use when asked to plan a roadmap chunk or feature for parallel sub-agent execution. /execute-plan runs the result.
slots:
  - conventions
---
# create-plan

Produce a plan a fresh session running `/execute-plan` can implement without this
conversation's context. The plan is the deliverable — do not write implementation code.
Defer to the repo's CLAUDE.md and any design plan it names for principles, style, and
toolchain; this scaffold encodes **process**, not principles.

<%= render("conventions") %>

## Phase 1 — Ground BEFORE you plan

Never plan from docs alone. Plans drift from code, and the drift is exactly where sub-agents
get lost, so verify the code state first — grounding precedes planning, always.

- Read the repo's CLAUDE.md and every ROADMAP / planning doc it references.
- Fan out parallel `researcher` sub-agents (`@researcher[/skill]` for a fresh-context probe)
  to verify the *actual* state of every seam the work touches: the files, the utilities worth
  reusing, the specs that pin current behaviour.
- Note where docs and code disagree — each becomes an interview question or an escalation
  trigger on a card.

## Phase 2 — Interview only what the code cannot answer

Ask the user only about decisions no amount of reading settles: policy choices, doc
locations, scope boundaries, granularity. Never ask what Phase 1 could have verified. Confirm
the review panel roster here if the repo has not pinned one.

## Phase 3 — Decompose into task cards

One card = one implementing sub-agent = one coherent responsibility. If the title needs
"and", cut it in two. For each card state:

- **Files** — the exact create/modify paths that are the card's scope.
- **Reuse** — the existing seams and classes to build on, by path.
- **Acceptance criteria in Gherkin** — Given / When / Then, each observable from *outside*
  the object (behaviour, not structure). The test-engineer step turns these into failing
  specs first (red), then implementation makes them green; name the spec files in the card,
  do not improvise them later.
- **Escalation triggers** — card-specific surprises that mean STOP (e.g. "an existing spec
  asserts X raises before Y — this card reorders that"). Generic triggers are a lint failure.

Then build the dependency DAG, assign waves (maximal antichains), mark the critical path, and
give each card a risk (low / medium / high) — risk drives review depth and model choice at
execution time.

Cut the seams against lain's real roles so `/execute-plan` can bind each card to one: `dev`
implements, `test_engineer` authors the red specs, `researcher` grounds, `reviewer_sre` /
`reviewer_security` / `reviewer_dba` staff the panel, `court_clerk` writes the record. A card
delegates to a role with `@role/skill` (the subagent inherits the session) or `@role[/skill]`
(fresh context). Two composition mechanisms differ and should not be conflated: render-time
`includes:` inlines another skill's scaffold into this one *before* the agent runs, while the
`run_skill` tool is a *runtime continuation* — the agent calls it mid-run and receives the
named skill's rendered scaffold-and-args back as its next tool result to act on. A plan that
names a role outside `Role::Catalog` fails loudly at spawn — name only real ones.

Decomposition heuristics (the repo's principles applied one level up):

- A card whose sketch would trip a `Metrics/*` limit is hiding a missing collaborator — split
  it into two cards.
- The same nil-guard or conditional in two cards is a Null Object waiting to be its own card,
  sequenced before both.
- A card that cannot state its Gherkin without naming another card's internals is coupled to
  it — merge them or re-cut the seam.
- Flag **orchestrator-owned shared files** (the require manifest `lib/lain.rb`, the gemspec,
  `.rubocop.yml`, `spec/spec_helper.rb`). Cards touch these only via one-line wiring diffs
  handed back to the orchestrator, never as card scope.

## Phase 4 — Panel review of the plan

Spawn one review sub-agent embodying the full panel for the plan's language. It reviews the
*plan*, not code: wrong seams, missing escalation triggers, cards too coupled to parallelize,
ACs that don't pin behaviour, reuse the grounding pass missed. Findings ranked BLOCKER /
SHOULD-FIX / NIT. Fix BLOCKERs and substantive SHOULD-FIXes before presenting; list what the
panel changed.

## Phase 5 — Emit

- Write the plan to `planning/specs/<slug>.md` (lain's planning convention).
- Add a one-line index entry in the roadmap/index doc pointing at it.
- Tell the user the plan runs with `/execute-plan planning/specs/<slug>.md`.
