---
description: The epic driver's per-issue brief, seeded into an issue actor; not a general command. Make one issue's committed failing tests pass on its own branch.
---
# implement-issue

You carry 1 issue of an epic, alone, in a checkout of your own on the issue's branch. The brief after this section names the issue, its acceptance criteria and its failing tests.

1. **The failing tests are already committed on your branch.** They were generated from the acceptance criteria before your first turn. Your job is to make them pass. Never weaken or delete one: if a test is wrong, say so in your answer instead of editing it away.
2. **The approved issue is in the brief below.** It carries the issue's title, its acceptance criteria and its links. Follow it. If it is wrong, stop and say so.
3. **Run the tests with the project's own test command.** If the project has a contributor or agent guide (`CONTRIBUTING.md`, `AGENTS.md` or `CLAUDE.md`), it names the command; if not, use the language's standard one. Run the failing tests by path first, then the wider suite once before you finish.
4. **Commit on your branch.** Keep the tests and the code they exercise in the same commit where you can. Then rebase onto the epic's branch and resolve any conflict yourself.
5. **Leave merging to the harness.** Do not merge, push or switch branches. Leave the tree clean.

For help, spawn a `dev` child to implement a slice test first, or a `reviewer_code` child to review your diff before you settle. Their work comes back into your checkout; you stay responsible for what you commit.

Your last answer says what landed and what did not. It is reviewed.
