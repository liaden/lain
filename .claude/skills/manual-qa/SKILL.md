---
name: manual-qa
description: Drive a manual end-to-end QA round against a real lain cockpit — tmux, nvim, and a live local model — from the scenarios in planning/qa/scenarios/. With no scope named it runs the FULL round over every scenario in that directory, in planning/qa/README.md's order. Use when asked to run manual QA, run a QA round, verify a chunk's fixes end to end, or exercise happy and unhappy paths against the real binary.
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

## Phase 1 — Scope, and say what you chose

**The inputs live in `planning/qa/`, and the scenario set is whatever `planning/qa/scenarios/*.md`
currently holds — enumerate that directory rather than working from a remembered list.** Scenarios
get added there, and a round that runs a hard-coded five silently stops covering the sixth.

**With no scope named, the default is the FULL round: every scenario in that directory.** Take
`planning/qa/README.md`'s ordering as the authority — as of 2026-08-19 that is `session-and-window`
→ `rust-cli` → a subject with `cockpit-surfaces` piggybacked → `bench-arms` → `failure-injection` —
and run **both** subjects (`bowling-ruby` and `rails-blog`) rather than picking one. `rails-blog` is
the expensive one, which is exactly why it is the one that never gets run: round 5 did not reach it
at all, so compaction at scale still has no manual evidence behind it.

If the user named a scenario, use that one. If they asked for a regression gate after a chunk,
README's cheap pair (`failure-injection` + `session-and-window`) is the answer, and README says why
that pair is worth more than its cost.

**Dropping a scenario from a full round is a decision, not a default** — name which and why, in the
findings, so the gap is legible rather than looking like coverage. Do not block on the question:
state the plan in one or two lines with its rough cost, and start.

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

**A fourth thing to settle before any act, because the sandbox does NOT cover it: the desktop.**
`--desktop` is ON by default for an interactive chat, and `qa-sandbox.sh` rebuilds `PATH` but still
ends it in `:$PATH` — so `/usr/bin/dunstify` stays reachable and a round fires **real notifications
onto the human's real screen**. That is not hypothetical: CLAUDE.md records nine of them landing on
a working human's display from agents' trees, which is why `desktop:` defaults to off everywhere the
caller does not own the human's attention. So decide, and say which: the acts that verify the
approval notifier run with it **on** and are named; every other act runs under `LAIN_DESKTOP=0`. A
round that cannot say which acts raised notifications is a round whose notifications nobody can
account for.

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
  recover through `:LainApprove`. Note the buffer now exists **at rest**, holding
  `(no approvals pending)` and taking no window, so its ABSENCE has flipped meaning: it used to be
  the ordinary state of a session that had never gated, and is now itself a defect.

Record per act as `method.md` says: journal path, `.lain/state.json`, `.lain/config.toml`, both
panes captured at the moment of a finding, `ollama ps`.

**The session ceiling no longer bounds the round, and that changed in both halves.** It used to be
that a session was spent after ~25 model calls and then silently swallowed prompts, so a round had
to be budgeted around it. The iteration ceiling is now per-ASK: a long single ask still stops at it
and says so, and the next prompt runs from zero. The silent swallow is gone with it. **So do not
restart between acts to dodge a limit that is not there** — and if you ever do see a prompt accepted
and answered with nothing at all, that is a finding worth the round, not a known cost of doing
business. Restart immediately if a literal `<function=` appears in a transcript — the model imitates
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
- **Re-measure the number the doc gives you.** A recorded measurement is evidence of what one
  machine did once, not a fact — including a measurement in these documents. The 2026-08-19 chunk
  overturned three of its own: the echo ceiling was `v:echospace` and not `&columns`; a
  "305-second" stale popup was really dunst suspending expiry after 120s idle, which makes it
  unbounded on precisely the idle desktop an unanswered approval creates; and a hand-counted twelve
  over-bar refusals was really eighteen. Each looked like a complete answer until someone measured
  again. If a step turns on a number, take the number yourself.
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
- **Clear the desktop, and verify that negative too.** If any act ran with the notifier on, close
  what it raised (`dunstctl close-all`) and confirm none survives. This is not tidiness: approvals
  are raised `-u critical`, which never auto-expires, and dunst suspends expiry entirely while
  nobody has touched the keyboard for 120s — which is exactly what an unattended round produces.
  Withdrawal only fires when another surface answers the pending, so a round that ends early leaves
  them up indefinitely on the human's screen, naming commands nobody is going to run.
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
