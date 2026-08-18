---
name: manual-qa
description: Drive a manual end-to-end QA round against a real lain cockpit — tmux, nvim, and a live local model — from a scenario in planning/qa/scenarios/. Use when asked to run manual QA, run a QA round, verify a chunk's fixes end to end, or exercise happy and unhappy paths against the real binary.
---

# Manual QA

You drive the whole round yourself: tmux for the panes, nvim over RPC for the editor, the journal
for ground truth. **You are also the human at the approval gate** — that is not paperwork, it is the
part of the system under test.

**The inputs are `planning/qa/`.** `method.md` is the standing procedure and `bench.md` brings up the
model server; both are scenario-independent, and this skill does not repeat them. Read the chosen
scenario in `planning/qa/scenarios/` and follow it.

**The premise:** every defect this has found lived in a seam that had specs on both sides. The suite
is ~14,000 examples and green; you are not looking for what it covers. You are looking for two real
components disagreeing with each other, and for the moments a human would be misled.

---

## Phase 1 — Choose, and say what you chose

Read `planning/qa/README.md` and pick by the question being asked, not by coverage. If the user
named a scenario, use it. If they asked for "a QA round" with no scope, propose the suggested full
round and start — do not block on the question.

State up front, in one or two lines: which scenarios, why, and the rough cost. Then go.

## Phase 2 — Bring up the bench, and prove the sandbox

```bash
bash .claude/skills/manual-qa/scripts/qa-sandbox.sh          # builds $QA and its helpers
```

Then, following `planning/qa/bench.md`: start or confirm the model server, record
`OLLAMA_NUM_PARALLEL` and `n_slots`, and record residency.

**Three gates, and a failure in any of them stops the round rather than being worked around:**

1. Every cockpit pane's `/proc/<pid>/environ` shows the sandbox `XDG_*` and `TMPDIR`. An *empty*
   result means re-check with `command grep` (under an agent shell `grep` is often a function) —
   it does not mean abort. A pane that really disagrees aborts.
2. `~/.lain` does not exist.
3. The machine is quiet (`uptime`, and check for orphaned spinners from earlier agent work).

Also record the round's start time — you need it for the close-out negative check.

## Phase 3 — Run the scenario

Follow the scenario's own steps. Four rules override any impulse to improvise:

- **Send Enter ONCE, then poll the journal.** Never retry on the status line. The old
  "retry until it leaves idle" rule turned one prompt into four journaled turns. `$QA/drive.sh`
  implements the correct wait.
- **Drive nvim over RPC** (`$QA/nv.sh`), verifying `bufname()` before every gesture. Do not send
  blind `C-w h` sequences at the pane.
- **Read the `lain://` buffers, not just `capture-pane`.** Where a buffer and the pane disagree,
  that disagreement is the finding.
- **Never approve a command you have not read.** If a gated call renders no prompt, read
  `lain://approval` over RPC first. An unrendered approval is itself a finding — record it and then
  recover through `:LainApprove`.

Record per act as `method.md` says: journal path, `.lain/state.json`, `.lain/config.toml`, both
panes captured at the moment of a finding, `ollama ps`.

**Budget the round around the harness's own limits.** A session is spent after ~25 model calls and
then silently swallows prompts; restart deliberately between acts rather than diagnosing a dead
session. Restart immediately if a literal `<function=` appears in a transcript — the model imitates
its own malformed call and never recovers, so everything measured after that is measuring a poisoned
context.

## Phase 4 — Verify the mechanism BEFORE you file

This is the phase that separates a finding from a false report, and it is where a round most easily
embarrasses itself.

- **Reproduce it, then explain it.** A finding needs a reproduction someone else can run, not a
  description of what you saw.
- **Read the code that produces the behaviour before naming a cause.** Round 4 nearly filed "the HUD
  freezes" before finding that the line is printed into the pane by `PromptComposer` once per prompt
  — a snapshot, not a widget, and not a defect. It was withdrawn on that reading.
- **Check whether the behaviour is documented scope.** Round 4 nearly filed an empty
  `lain://journal` before finding a docstring saying it renders `ToolOutput` only. That became a
  *UX* finding instead, which is the right category.
- **Prefer a measurement to an inference.** A counting TCP listener turned "how many retries" from a
  suspicion into a number.
- **Separate MODEL findings from LAIN findings.** The local model failing to drive `/create-plan` is
  not a defect in lain. Record it under model behaviour so the next round does not re-derive it.

## Phase 5 — Write the findings

One file, `planning/qa-findings-round<N>-<date>.md`, following
`references/findings-format.md`. Lead with a summary table; every finding carries a severity, a
reproduction, and the evidence that distinguishes it from the nearest innocent explanation.

**Findings are not only errors.** Three categories, all worth filing:

- **Defects** — it does the wrong thing.
- **UX findings** — it does the right thing *obtusely*: a refusal delivered as a crash, a view with
  no placeholder, a message that contradicts the screen beside it. These are real work items.
- **Feature gaps** — the run wanted something that does not exist. Say what you reached for.

Also record, deliberately: **which of the previous round's defects behave differently now**, and for
each, whether differently means better. A fix that turned a hang into a crash is a finding.

## Phase 6 — Close out

- Kill the QA tmux server; confirm no stray `lain` processes.
- **Verify the negative:** `find ~/.local/state/lain -newermt '<round start>'` must be empty. That
  is the proof the sandbox held, and it belongs in the findings.
- Leave the sandbox directory in place — it is the evidence.
- Fold anything the round taught the *process* back into `planning/qa/method.md` or the scenario,
  and say you did. A round that improves only the code and not the method will re-learn the same
  lesson next time.

Then summarize to the user: what was confirmed fixed, what is new ranked by severity, what could not
be reached and why.

## The two rules that outrank everything else

1. **Success is not "nothing went wrong."** A round that finds nothing new did not push hard enough.
2. **Report faithfully.** If a step was skipped, say so. If a probe was inconclusive, say
   inconclusive — do not record "could not reproduce" as a pass.
