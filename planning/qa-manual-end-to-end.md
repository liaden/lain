# Manual end-to-end QA — moved

This document was split into [`planning/qa/`](qa/) after round 4 (2026-08-18), because one
1,000-line file had become both a standing method and a growing pile of subject-specific acts, and
the two are read at different times.

- The standing method — toolchain, sandbox isolation, the approval gate, driving the cockpit and
  nvim, what to record — is [`qa/method.md`](qa/method.md).
- Bringing up the model server is [`qa/bench.md`](qa/bench.md).
- The acts became **scenarios**, one per question, in [`qa/scenarios/`](qa/scenarios/). Start at
  [`qa/README.md`](qa/README.md), which says which to pick.
- The bowling oracles moved to [`qa/oracles/bowling.rb`](qa/oracles/bowling.rb).

A round is now driven by the `manual-qa` skill (`.claude/skills/manual-qa/`), which takes one of
those scenarios as its input.
