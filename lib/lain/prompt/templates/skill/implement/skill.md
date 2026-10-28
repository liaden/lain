---
description: Implement 1 plan card test first in the current checkout, then hand back. Use as `@dev/implement <card>`; takes a card id and the plan path.
---
# implement

Implement the card that follows the command. Read the card and the plan's shared-files section first, and the repo's own rules file.

1. **Write the failing spec first.** Put it in the spec files the card names, run it by path, and keep the red run: the command and its summary line. A red made by reverting finished code does not count.
2. **Write the code** until the spec passes, and keep the passing run.
3. **Run what the change touches.** Run every spec that names a class or symbol you changed, then the repo's lint on your files. Run the change itself once, not only a syntax check.
4. **Never run the suite while another run holds the lock.** Check the repo's rules for where the lock lives.
5. **Commit lib and spec together** in the same commit, leaf first. A commit runs the checkout's hooks and the suite's wall, so allow for the wait. Never pass `--no-verify`, never run `git reset --hard`, and never run `git stash`; if a hook fails, fix the cause and commit again.
6. **Name the paths you stage.** Run `git add` on each path, never on a glob or a diff listing, because other work may sit uncommitted beside yours.
7. **Write the handback file** the caller names: files changed, the red run, the passing run, lint result, surprises. Answer in under 10 lines and give its path.

Stop and report instead of working around a stop condition in the card, or any surprise that contradicts it. Touch only the files the card lists, and name any other change the card needs.
