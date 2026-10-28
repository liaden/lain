---
description: Write a short handoff file so a fresh session can continue this work. Use at a clean stopping point, before the context is cleared, as in `/handoff finish the retry work`.
---
# handoff

Write a note a fresh session can resume from. Whatever follows the command is the argument: what the next session should do.

1. **Refuse if children are running.** If any subagent or background task is in flight, refuse and name them. They do not survive the end of this session. Offer to wait for them, and write nothing.
2. **Pick the location.** Use `tmp/` when `git check-ignore -v tmp/` prints a rule. Otherwise ask the user where the note may go; never write a handoff into a tracked directory.
3. **Write** `tmp/handoff-<date>-<slug>.md` with `write_file`, `<date>` as `YYYY-MM-DD` and `<slug>` a few words naming the work. Keep it under 400 words:

   ```markdown
   # Handoff: <topic>

   Date, repo, branch, SHA, uncommitted changes (yes or no).

   ## Goal
   ## Decisions made, and why
   ## Current state
   ## Next steps
   ## Files that matter
   ## Open questions
   ```

   - Record what the code and git history do not show: decisions, dead ends, and what the user said.
   - Give paths with line numbers. Paste no code.
   - If a plan is running, give its path; its execution log holds the card state.
   - The argument, if given, is the first item under Next steps.
4. **Print the resume prompt** for the user to paste into the new session:

   ```
   Read <absolute path to the handoff file> and continue from "Next steps". Do not re-ask the questions it lists as decided.
   ```
