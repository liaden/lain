---
description: Build an orchestrator-ready TDD plan (task cards, Gherkin acceptance criteria, dependency waves, escalation triggers), grounded in the actual code state. Use when asked to plan a roadmap chunk or feature for parallel sub-agent execution. /execute-plan runs the result.
slots:
  - conventions
---
# create-plan

Produce a plan a fresh session running `/execute-plan` can implement without this
conversation's context. The plan is the deliverable: do not write implementation code.
Defer to the repo's CLAUDE.md and any design plan it names for principles, style, and
toolchain; this scaffold encodes **process**, not principles.

<%= render("conventions") %>

## Phase 1: Ground BEFORE you plan

Never plan from docs alone. Plans drift from code, and the drift is exactly where sub-agents
get lost, so verify the code state first: grounding precedes planning, always.

- Read the repo's CLAUDE.md and every ROADMAP / planning doc it references.
- Fan out parallel `researcher` sub-agents (`@researcher[/skill]` for a fresh-context probe)
  to verify the *actual* state of every seam the work touches: the files, the utilities worth
  reusing, the specs that pin current behaviour.
- Note where docs and code disagree: each becomes an interview question or an escalation
  trigger on a card.

## Phase 2: Settle backwards compatibility

List every surface the plan touches: public APIs, CLI flags, config files, stored data,
serialized formats. Gather evidence for each by lookup, not by asking: gemspec or
`Cargo.toml` version and `publish` flag, git tags, the changelog, consumers found by grep,
migrations, serialized structs. Give each surface a verdict:

- Outside consumers or stored data exist: **must keep**.
- None, and the surface is unpublished or internal: **free to break**.
- Evidence unclear or conflicting: ask the user in Phase 3.

If breaking a must-keep surface would remove a card, an abstraction layer, or about 20% of
the plan, report the trade (what keeping costs, what breaking allows, who is affected, the
migration) before cutting cards. The user decides. Record every verdict in the plan's
Compatibility section.

## Phase 3: Interview only what the code cannot answer

Ask the user only about decisions no amount of reading settles: policy choices, doc
locations, scope boundaries, granularity. Never ask what Phase 1 could have verified. Confirm
the review panel roster here if the repo has not pinned one.

## Phase 4: Decompose into task cards

One card = one implementing sub-agent = one coherent responsibility. If the title needs
"and", cut it in two. For each card state:

- **Id, title and risk**: `### T<id>: <imperative title> [risk: low|medium|high]`.
- **Depends on**: card ids, or none.
- **Files**: the exact create/modify paths that are the card's scope.
- **Reuse**: the existing seams and classes to build on, by path.
- **Shared-file wiring**: the one-line diffs the orchestrator applies, or none.
- **Reachable from**: the production site that constructs this work. A require line or a
  keyword argument with a null default does not count; say "deferred" and why if it is.
- **Acceptance criteria in Gherkin**: Given / When / Then, each observable from *outside*
  the object (behaviour, not structure). The test-engineer step turns these into failing
  specs first (red), then implementation makes them green; name the spec files in the card,
  do not improvise them later.
- **Escalation triggers**: card-specific surprises that mean STOP (e.g. "an existing spec
  asserts X raises before Y: this card reorders that"). Generic triggers are a lint failure.
  Write them under the heading **Stop and report if:**.

Then build the dependency DAG, assign waves (maximal antichains), mark the critical path, and
give each card a risk (low / medium / high): risk drives review depth and model choice at
execution time.

Cut the seams against lain's real roles so `/execute-plan` can bind each card to one: `dev`
implements, `test_engineer` authors the red specs, `researcher` grounds, `reviewer_sre` /
`reviewer_security` / `reviewer_dba` staff the panel, `court_clerk` writes the record. A card
delegates to a role with `@role/skill` (the subagent inherits the session) or `@role[/skill]`
(fresh context). Two composition mechanisms differ and should not be conflated: render-time
`includes:` inlines another skill's scaffold into this one *before* the agent runs, while the
`run_skill` tool is a *runtime continuation*: the agent calls it mid-run and receives the
named skill's rendered scaffold-and-args back as its next tool result to act on. A plan that
names a role outside `Role::Catalog` fails loudly at spawn: name only real ones.

Decomposition heuristics (the repo's principles applied one level up):

- A card whose sketch would trip a `Metrics/*` limit is hiding a missing collaborator: split
  it into two cards.
- The same nil-guard or conditional in two cards is a Null Object waiting to be its own card,
  sequenced before both.
- A card that cannot state its Gherkin without naming another card's internals is coupled to
  it: merge them or re-cut the seam.
- Flag **orchestrator-owned shared files** (the gemspec, `.rubocop.yml`, `spec/spec_helper.rb`,
  and whatever else the repo loads or lints through one place). Cards touch these only via one-line wiring diffs
  handed back to the orchestrator, never as card scope.

## Phase 5: Spike when it lowers risk

When a card rests on an unverified assumption about a library, a performance limit or an
API, test it before planning around it: make a throwaway worktree under an ignored
directory (`git check-ignore -v tmp/` must print a rule), give a spike agent the question
and the worktree's absolute path, then remove the worktree and branch. Record the question,
result and evidence in the plan's Spike findings. A card whose stop condition says
something cannot be measured needs a spike first.

## Phase 6: Lint, then panel review

Lint the draft before anyone else sees it, and fix every failure:

- Every card has an id, an imperative title, a risk and all the fields above.
- Every criterion names a spec file and describes behaviour, not structure.
- Files and Reuse use exact paths that exist at the grounding commit.
- Every spec outside Files that names a symbol the card changes is listed, or the card
  says why it stays green (grep the spec tree).
- Stop conditions are specific to the card; every reader one names is in scope.
- Every runtime premise was probed, not read.
- The dependency graph matches every `Depends on` and has no cycle; no two cards that can
  run at once share a file; no card lists a shared file under Files.
- Every capability has a card whose Reachable from names a production construction site,
  and at least one criterion per capability runs without an injected double.
- Grounding has a date, a commit and the files checked; every spike has its result.
- No em dashes; digits for numbers.

Then run the panel review.

Spawn one review sub-agent embodying the full panel for the plan's language. A leased review
sub-agent works in its own checkout, cut from the committed tip, so commit the plan draft before
it can read it and name it relative to the child's working directory, or put the plan's text in
the brief. It reviews the *plan*, not code: wrong seams, missing escalation triggers, cards too coupled to parallelize,
ACs that don't pin behaviour, reuse the grounding pass missed. Findings ranked BLOCKER /
SHOULD-FIX / NIT. Fix BLOCKERs and substantive SHOULD-FIXes before presenting; list what the
panel changed.

## Phase 7: Emit and commit

- Write the plan where the project's conventions name (the conventions section above), as `<slug>.md`.
- Add a one-line index entry in the roadmap/index doc pointing at it.
- Commit the plan and the index entry together, with a message that stands alone and
  names no card.
- Tell the user the plan runs with `/execute-plan <path to the plan>`.
