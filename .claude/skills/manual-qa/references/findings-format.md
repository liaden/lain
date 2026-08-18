# Writing a finding

One file per round: `planning/qa-findings-round<N>-<date>.md`. It is read twice — once by whoever
writes the fix chunk, and once by the next QA round deciding what to re-check — so it has to carry
**evidence, not narrative**.

## Shape

Lead with a summary the reader can act on without scrolling:

```markdown
# QA round <N> — <date>

## Summary

<one paragraph: what was confirmed fixed, what is new, what could not be reached>

| id | sev | what |
|---|---|---|
| **F21** | **HIGH** | the iteration ceiling is per-SESSION, so every chat dies silently after 25 model calls |
| F17 | MED-HIGH | `lain://timeline` freezes after the first ask and never updates again |

## Round-<N-1> defects re-checked

| id | verdict | evidence |
|---|---|---|
| F8 | FIXED | `--num-ctx 999999` refuses at construction naming flag/value/max 262144, exit 1 |
```

Then one section per finding, then model behaviour, then the process notes.

## A finding

Six things, and the middle two are what make it usable:

1. **An id and a severity.** HIGH = session-killer, data loss, or silent wrong answer.
   MEDIUM = a real defect with a workaround. LOW = cosmetic but wrong.
2. **One sentence of what is wrong**, in the codebase's own vocabulary.
3. **The mechanism**, named at a file and line where you have one. `Agent#seed_run_state` is called
   from `initialize`, so `@iterations` never resets — not "the counter seems to persist".
4. **The evidence that rules out the nearest innocent explanation.** This is the part reviewers
   trust. "Not the drain thread dying: `lain://request` updates live on the same `Surfaces#post`
   path" is worth more than three paragraphs of description.
5. **A reproduction** someone else can run, with the commands.
6. **A fix shape**, if one is obvious — and say what would *pin* it, since the fix lands as a card
   with acceptance criteria.

## Three categories, all worth filing

- **Defect** — it does the wrong thing.
- **UX finding** — it does the right thing obtusely. A refusal delivered as a stack traceback, a
  view with no placeholder while every sibling has one, a message that contradicts the screen next
  to it. File these; they are real work items, and round 4's most-repeated defect shape
  ("lain's refusals are well-written and then delivered as crashes") only became visible once three
  of them were written down together.
- **Feature gap** — the round reached for something that does not exist. Say what you reached for.

Keep **model behaviour** in its own section, clearly not a lain defect, so the next round does not
re-derive it — and only file a model behaviour as a provider bug with a clean reproduction that
isolates the trigger.

## Rules

- **Withdraw findings in the file, not silently.** If you nearly filed something and the mechanism
  disproved it, that is worth a line — it stops the next round re-filing it.
- **Never write "could not reproduce" as a pass.** Write inconclusive, and say what would settle it.
- **Say what you could not reach, and why.** A path missed by two consecutive rounds is itself a
  finding about the plan.
- **Cross-check every number against a second reader** before quoting it. Journal, `state.json` and
  the HUD should agree; when they do, say so — agreement across three readers is a result.
