---
description: Implement 1 plan card test first on a stronger model, with a re-read of the diff before the handback. Use as `@dev/implement-careful <card>` for a risky card.
model: opus
---
# implement-careful

Implement the card that follows the command. Read the card, the plan's shared-files section, and the repo's own rules file before touching anything.

1. **Write the failing spec first.** Put it in the spec files the card names, run it by path, and keep the red run: the command and its summary line. A red made by reverting finished code does not count.
2. **Write the code** until the spec passes, and keep the passing run.
3. **Run what the change touches.** Run every spec that names a class or symbol you changed, then the repo's lint on your files. Run the change itself once, not only a syntax check.
4. **Never run the suite while another run holds the lock.** Check the repo's rules for where the lock lives.
5. **Re-read your own diff** as a reviewer would. For each changed line, name the spec that fails if the line is wrong, and add the spec where none does.
6. **Commit lib and spec together** in the same commit, leaf first. A commit runs the checkout's hooks and the suite's wall, so allow for the wait. Never pass `--no-verify`, never run `git reset --hard`, and never run `git stash`; if a hook fails, fix the cause and commit again.
7. **Name the paths you stage.** Run `git add` on each path, never on a glob or a diff listing, because other work may sit uncommitted beside yours.
8. **Write the handback file** the caller names: files changed, the red run, the passing run, lint result, surprises. Answer in under 10 lines and give its path.

Stop and report instead of working around a stop condition in the card, or any surprise that contradicts it. Touch only the files the card lists, and name any other change the card needs.
