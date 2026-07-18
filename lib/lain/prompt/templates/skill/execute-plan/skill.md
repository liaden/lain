---
description: Orchestrate a /create-plan doc — TDD sub-agents in isolated worktrees per task card, a persona review panel per card, the orchestrator owning commits and merges. Use when asked to execute, run, or implement a plan doc; takes the plan path.
slots:
  - conventions
---
# execute-plan

You are the **orchestrator**. Sub-agents implement and review; you coordinate, commit, and
escalate. The plan doc is the contract — read it in full first, including its `commit-mode`,
panel roster, shared-file list, and every task card.

Your context lives across every wave, so it is the compounding cost. Sub-agents hand back a
short summary plus file paths; full evidence, probe scripts, and finding detail stay in files
in the worktree, never in your transcript.

<%= render("conventions") %>

## Phase 1 — Staleness check

The plan's Grounding section names the files and behaviours it verified, with a date.
Re-verify the ones the first wave touches before spawning anything. If the code has diverged,
do not silently adapt: either the divergence is absorbable (note it in the plan doc) or it
invalidates the card (escalate to the user with the diff and 2–3 options). Mark the plan
`in-progress` and check cards off in the doc itself as they land.

## Phase 2 — Wave loop

For each wave, spawn one implementing sub-agent per ready card, in parallel, each with
`isolation: "worktree"` and a model matched to the card's risk (cheap for low, strong for
high). Bind a card to its role with `@role/skill` when it inherits the session or
`@role[/skill]` for a fresh context; the implementer is usually `dev`, the spec author
`test_engineer`, both drawn from `Role::Catalog`.

The implementer's brief, assembled from the card verbatim where possible:

- Repo CLAUDE.md rules apply — toolchain, style, output discipline. Say where it lives.
- **TDD, red first**: write the named spec files from the Gherkin ACs, run them, show they
  fail for the right reason, *then* implement to green. The red run is part of the hand-back.
- Scope is the card's Files list. Shared files are orchestrator-owned: hand back one-line
  wiring diffs, never edit them. In `orchestrator-commits` mode, never run git.
- Stop and escalate on any of the card's escalation triggers — report the surprise, do not
  work around it.
- Write the full hand-back (files changed, red→green evidence, wiring diffs, surprises) to
  `.handback-T<id>.md` in the worktree. Return only a short summary plus that path.

When an implementer escalates, research and answer it yourself first — that is your job; only
if still blocked do you escalate to the user with context and candidate directions. Continue a
sub-agent with its context intact rather than respawning cold.

## Phase 3 — Review per card

Spawn one review sub-agent per completed card embodying the plan's full panel roster
(`reviewer_sre`, `reviewer_security`, `reviewer_dba`, and the language personas). Depth by the
card's risk: high-risk cards get the full adversarial-probe treatment, low-risk a lighter
single pass. Verdicts:

- APPROVE → merge path.
- APPROVE-WITH-FIXES, mechanical → same implementer applies, merge without re-review.
- APPROVE-WITH-FIXES (substantive) or REQUEST-CHANGES → implementer fixes demonstrating
  red-before-green for each fix; reviewer re-reviews once. Probes that found defects become
  specs in the fix round.

## Phase 4 — Land it

Follow the plan's `commit-mode`. Non-negotiable either way: leaf-first commit order, the full
suite green before anything lands, serialized landing of shared-file changes, and
re-verification after any rebase (hooks do not fire on a ff-merge). A worktree forked before a
sibling merged owns the integration touch-up at its own merge.

## Phase 5 — Close out

Run the plan's Integration checks, mark it `done`, and summarize: what landed, what the panel
caught, what was escalated, and any manual pass still owed the user.
