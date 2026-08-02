# Execution notes: epic wiring, review intake, and serial landing

Plan: `planning/specs/chunk-epic-wiring-intake-landing.md`

## 2026-07-30 — Codex recovery

- The plan was already marked `in-progress` when Codex resumed it.
- The main worktree contains pre-existing user changes and untracked artifacts; they are
  outside this execution's scope and must be preserved.
- Surviving Claude worktrees found: T13, T15, T17, and T18 under `.claude/wave2/`.
- Recent filesystem activity exists in those worktrees, especially T13, T15, and T18 around
  09:07–09:11. Their branch tips are behind `main`, but their uncommitted files contain the
  likely interrupted handoffs.
- Initial resume order: inspect handbacks/reviews, validate each card in isolation, then land
  leaf work in dependency order. Do not discard or reset any worktree.

### Validation pass

- T13 targeted supervisor suite: 29 examples, 0 failures. The handback's shared wiring question
  remains for the orchestrator; the card's implementation itself is green.
- T15 targeted review suite: 40 examples, 0 failures. Its handback includes the required
  `epic.rb` wiring as reverted orchestrator-owned work plus a supporting `Intake::Delta` change.
- T17 and T18 targeted suites initially failed during spec load because their surviving
  worktrees intentionally reverted shared `forge.rb` require lines. This is an integration
  setup failure, not yet an implementation verdict; validate them after supplying the wiring
  in the orchestrator tree.

## Execution observations

This section records orchestration issues and skill improvements as they are discovered.


- T13 had an apparent production wiring blocker, but plan ruling `f08a004` deliberately defers
  the `WorkerHandoff` call site. The seam lands with `Supervisor::Retain`; CLI wiring remains a
  follow-up with resolver and cost decisions.
- T17 was already on `main`, but independent review found its claimed invariant enforced only by
  `Gh::Answer`, not by the public duck-typed `Forge::Outcome` boundary. The orchestrator added
  wire-level validation and regression coverage. Review claims must be checked at the public boundary.
- T15 overlapped later graph-revision additions in `epic/records.rb`. A three-way union merge
  initially omitted shared `end` delimiters; syntax validation caught it before tests, and the
  merged file was repaired while preserving both record families.
- T17 and T18 worktrees intentionally reverted shared manifest wiring, so isolated specs failed at
  load time until the orchestrator applied the planned require lines. Treat reverted wiring as an
  integration obligation, not an implementation failure.

- Second-pass review of T15 found two defects in the first landing: `to_i` accepted fractional or
  garbage wire generations, and replay allowed an open claim after its close record. Both are now
  rejected at `ReviewClaim` and `Review::Replay`, with adversarial specs; focused review/record/graph
  validation is 116 examples, 0 failures.
- This confirms a process improvement for the skill: after a panel fix round, run a fresh adversarial
  review against the final file state, not just the original handback and mutation artifacts.
## 2026-07-30 — Wave 3 recovery
- T24 isolation was unavailable to its agent; the orchestrator completed it locally within the no-force and no-cascade boundary.
- T24 focused specs pass: approval precedes intent, the chain journals through existing executors, and DIRTY merge state stops before pr_merge.
- T16 returned an incomplete temporary-copy handback; after review and cleanup, its focused suite passes: 54 examples, 0 failures.
- T16 leaves HumanReplies bind_review as a seam for the dependent wiring wave; it is not yet composed through Repl/Wiring.
- Skill lesson: an unavailable worktree must produce an explicitly non-integrable handback, and temporary-copy edits require a review and cleanup pass before copying.
- Wave 3 committed as 08a8a8b; the full pre-commit hook passed with zero spec failures. The hook used grouped parallel suites, so its per-process counts are not additive.
- Wave 4 triage: T25 is blocked on an unspecified CLI source for implementation digest and SHA, plus a missing Reconcile world adapter; no behavior was invented.
- T22 initially stopped because its new spec directory was absent; this is being retried as a normal directory creation, not treated as a design blocker.
- T22 completed in 10bb2cb; focused annotation/review/frontend suite passed 78 examples, and its scoped lint passed. T25 remains blocked on the plan contract for digest/SHA sourcing and the Reconcile world adapter.
