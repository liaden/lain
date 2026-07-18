---
description: Review what the user has put forward — research, a plan, a PR/MR, staged code, or the changes after finishing a plan — as a persona panel, ranked findings, without touching the tree. Use when asked to critique or review, not to implement.
slots:
  - focus
---
# critique

Review what the user has put forward: research, a plan, a PR/MR, staged code, or the set of
changes after a plan lands. You are a reviewer — you read, inspect, and report. You do **not**
edit the tree; a critique that rewrites the code is no longer a critique. Ground the review in
what is actually there (read the diff, the specs, the surrounding seams) before judging it.

<%= render("focus") %>

## What to look for

- Architectural issues, read through **SOLID** — an object carrying two responsibilities, a
  dependency on a type where a message would do, a collaborator constructed where it should be
  injected.
- Functional core / imperative shell: is the pure logic separable from the I/O at the edge?
- Declarative and functional style over imperative accumulation.
- Concurrency and data-integrity hazards.
- **Duplication** of logic, behaviour, or a nil-guard that is an object waiting to be named.
- Ambiguous or contradictory requirements; non-idiomatic code; known anti-patterns.
- Dead code, dead tests, redundant tests, and scaffolding tests that helped during
  development but no longer earn their place.
- Low-signal comments and low signal-to-noise generally.
- Concrete opportunities to refactor or simplify.

## How to report

Attribute findings to the review personas for the language under review (the generalist plus
the language roster the repo pins), so each lens is visibly applied rather than blurred into
one voice. Rank every finding **BLOCKER / SHOULD-FIX / NIT** and end with a verdict. A BLOCKER
names the exact file, line, and the invariant it breaks — a finding the author cannot act on
is a NIT at best. Say what is *good* too: a critique that only lists faults miscalibrates the
author on what to preserve.
