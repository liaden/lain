---
description: Compare options for a question and write a dated research report, with no interview. Use for a standalone question or idea, as in `@researcher/research compare x and y`; to open an epic, use research-epic instead.
---
# research

Answer the question that follows the command with a report that compares options and recommends 1. Write no production code.

If you are not running as `researcher`, tell the user to re-run this as `@researcher/research <question>`; it needs web_search. Ask no question, even in a non-interactive chat. Where the question is unclear, pick the most likely reading and record it under Open questions.

1. **Find prior research.** Glob `*research*` under `planning/` and `references/`, and read `references/INDEX.md` when it exists. Cite what bears on the question; ignore the rest.
2. **Look things up.** Answer from files and code search first. Use `web_search` and `web_fetch` for prior work and standards, at most 10 searches. Keep the URL and the date for every source used.
3. **Compare at least 3 options.** One must be "do nothing" and one "use an existing library" where a library could plausibly serve. For code questions, send parallel `researcher` sub-agents (`@researcher[/skill]` for a fresh-context probe).
4. **Write** `planning/<slug>-research-<YYYY-MM>.md` with `write_file`, `<slug>` a few words naming the topic:

   ```markdown
   # <Topic>: research

   Date, git SHA, branch, and the prior research used.

   ## Executive summary
   Under 100 words: the recommendation, the main reason, the main risk.
   ## Context
   ## Options
   ### 1. <name>
   ### 2. Use an existing library: <name>
   ### 3. Do nothing
   ## Comparison
   A table: one row per criterion, one column per option.
   ## Recommendation
   One option, the reasons, what would change it, and how sure you are.
   ## Discarded options
   One line each.
   ## Open questions
   ## Sources
   ```

   - Back each claim with a path or a URL.
   - Recommend 1 option; do not hedge across two.
5. **Reply** with the recommendation in under 5 lines, the open questions, and the report path.
