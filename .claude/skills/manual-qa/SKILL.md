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

**Enumerate `planning/qa/scenarios/` — never work from a remembered list, a count, or a list written
into any document, this one included.** Do it first, every round:

```bash
ls planning/qa/scenarios/
```

**That listing is the authority on the SET.** Any count written down goes stale the day somebody adds
a scenario, and a round working from a stale one silently stops covering the new file — which has
already happened here more than once, in both directions.

**A scenario in neither README's tiers nor your round is one somebody added and nobody
scheduled: say so.**

**With no scope named, the round drives EVERY scenario in that listing.** Not a tier, not a subset.
README's tiers are **ordering and budgeting** — what to drive first, what piggybacks on what, which
scenarios bring up their own subject — and they are **not a filter that drops scenarios**. Read
README for the reasoning; this is the shape:

| tier | what it means |
|---|---|
| **the spine, first** | `session-and-window` → `rust-cli` → **a SUBJECT with `cockpit-surfaces` piggybacked** → `bench-arms` → `failure-injection`. Everything else reads better once the loop is known good. |
| **own-subject, sequenced after** | `secret-boundary`, `changeset-review`, `subagents-and-backends`, `memory-and-dogfood`, `rails-blog` — each gets its **own bring-up and its own subject tree inside this round**. They are sequenced rather than interleaved because each half-builds a precondition the others trip over. |
| **cheap deterministic, anywhere** | `failure-injection`, `session-and-window`, `repl-commands`, `epic-tier`, `survey`, `prompt-slots-and-roles`, `shell-terms`, `shell-term-approval` — also the standalone regression gate when the USER scopes the round to one. README says which to cut first if it will not fit (`epic-tier`), and which sections of `survey` and `shell-term-approval` to cut before the whole file. |

**README is the authority on that set, and this table is a mirror that has drifted before.** It
lost `shell-terms` for a while — the one scenario in the directory that has never been driven, so
a scoped gate read from here dropped precisely the file most owed a run. Read the roster out of
README rather than out of this row, and if the two disagree, README wins and this row is the bug.

Two traps in the spine, both of which have already cost a round: `rust-cli` is the smoke test and is
**not** a subject — the subjects are `bowling-ruby` and `rails-blog` — and `cockpit-surfaces`
piggybacks on the **subject** session, not on the smoke test. Rounds 7 and 8 collapsed those two
steps and neither noticed.

**There is no such thing as a scenario that "needs a second invocation".** That convention is what
caused scenarios to slip round after round while the documents read as though they were covered:
round 9 named `secret-boundary` as owed and it slipped anyway, `rails-blog` slipped for three rounds
the same way, and round 13 settled it by driving everything in one context and reaching
`rails-blog`'s compaction act for the first time in the bench's history. An own-subject scenario
gets its own bring-up and its own tree **within this round** — start those early enough that they are
not what the budget runs out on.

**Dropping a scenario is a DECISION you name in the findings, with its reason** — never a default and
never silent. That includes `bowling-ruby`, `rails-blog`, and anything you ran out of budget for.
A scenario skipped by convention stops being a gap anyone can see. If a scenario appears in the
listing but in none of README's tiers, that is one somebody added and nobody placed: drive it anyway,
and say so.

If the user named a scenario, use that. If they asked for a regression gate after a chunk, that is
the cheap deterministic set above, and README says which to cut first if it will not fit — **that
licence belongs to the scoped gate alone and never to a full round.**

Do not block on the question: state the plan in one or two lines with its rough cost, and start.

## Phase 2 — Bring up the bench, and prove the sandbox

```bash
bash .claude/skills/manual-qa/scripts/qa-sandbox.sh          # builds $QA and its helpers
```

Then, following `planning/qa/bench.md`: start or confirm the model server, record
`OLLAMA_NUM_PARALLEL` and `n_slots`, and record residency.

**Three gates, and a failure in any of them stops the round rather than being worked around:**

1. Every cockpit pane's `/proc/<pid>/environ` shows the sandbox `XDG_*` and `TMPDIR`: **run
   `$QA/isolation.sh`, and never re-type the grep.** Round 18 had four contexts re-derive it and write
   four wrong spellings, each matching `TMPDIR` alone. The helper exits 1 unless every pane carries
   all five. Forks get the same helper in their own sandbox. A pane that really disagrees aborts.
2. `~/.lain` does not exist.
3. The machine is quiet (`uptime`, and check for orphaned spinners from earlier agent work).

**The desktop notifier no longer exists — there is no fourth gate.** `Lain::Notify` was deleted on
2026-09-12 (`c40ab419`), and with it `--desktop`, `LAIN_DESKTOP` and every dunst surface. Round 17
spent an act proving it by the negative: a cockpit started from a server with `LAIN_DESKTOP` unset
and `/usr/bin/dunstify` on `PATH` parked a gated call, and `dunstctl count displayed`/`waiting` read
**0/0**. A round that still exports `LAIN_DESKTOP=0` is harmless; a round that schedules notifier
checks (`cockpit-surfaces.md` §5's withdrawal half, `shell-terms.md` §5's `dunstctl` negative) is
testing a surface that is gone — record those sections as moot rather than passed. Take
`dunstctl count displayed` at close-out anyway: it is one command, and it is what would notice a
notifier coming back.

Also record the round's start time — you need it for the close-out negative check.

## Phase 3 — Run the scenarios

Follow each scenario's own steps, in the order Phase 1 settled. A scenario that brings up its own
subject gets that bring-up **here**, in this round — do not carry a previous scenario's tree into one
that specifies its own, and do not interleave two bring-ups. Four rules override any impulse to
improvise:

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
  **The same discipline applies to a CLAIM or a diagnosis, not only a number — round 7 (2026-08-20)
  overturned two this way: `cockpit-surfaces.md`'s NEW-window claim (F34) and the F27 diagnosis
  (`method.md` has both).** Re-verify a claim in these documents the same way you re-verify a number.
  **Round 9 (2026-08-23) overturned a third, and the shape is worth copying: it needed a CONTROL,
  not just a re-measurement.** `bench-arms.md` asserted "`num_batch` does not re-key the runner",
  from round 8 watching residency stay unchanged. Round 9 loaded a runner with ollama's own defaults
  (`-b 512`), sent ONE lain request carrying `LAIN_NUM_BATCH=2048`, and watched the runner reload —
  then **sent the identical request again**, against the now-matching runner, and watched it NOT
  reload. The second half is what makes it evidence rather than a coincidence: without it, "the
  runner reloaded" is equally consistent with "lain always reloads". **When you overturn a claim,
  ask what observation would look the same if the claim were true, and go take it.**
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

**And a coverage table over the full directory listing** — every scenario Phase 1 enumerated, with
what was driven and, for anything not driven, the reason. "Ran out of budget" is an acceptable
reason; omission is not. A round whose findings do not account for a scenario has made that scenario
invisible, which is the failure this bench has re-learned more times than any other.

**A reason of the form "it needs X" is a CLAIM, and you check it before writing it.** Budget and
wall-clock are self-evident; a capability is not. Round 14 wrote "not driven" against four scenarios
and was wrong about all four: three (`subagents-and-backends`, `memory-and-dogfood`, `rails-blog`)
run on the **local ollama bench that was already up and warm**, and the fourth
(`ollama-cloud-arm`) needed a key that was sitting in the repo's own `.envrc`. The driver had
conflated *"this scenario spends model calls"* with *"this scenario is out of reach"*. The user asked
one question and the second pass reached all four — including `rails-blog` §2, unreached in
**thirteen** rounds.

So before "not reached — needs X" goes in the table, do these three, and they cost seconds:

```bash
ls planning/qa/scenarios/<the one you are about to drop>.md   # what does it SAY it needs?
command grep -n 'Needs:' planning/qa/scenarios/*.md           # every scenario states its own preconditions
command grep -nE '^[[:space:]]*export[[:space:]]+[A-Z_]*(KEY|TOKEN)' .envrc   # names only -- never print a value
```

**Grep for an `export`, not for the NAME.** The loose form (`grep -oE '[A-Z_]*(KEY|TOKEN)[A-Z_]*'`)
matches **comments**: round 15 got `ANTHROPIC_API_KEY` back out of a comment reading "This desktop
has no ANTHROPIC_API_KEY anywhere", so the check written to prevent a false *unreachable* produced a
false *reachable*. A name in a file is not a key. When it matters, test the variable:
`[ -n "${ANTHROPIC_API_KEY:-}" ]`.

**The default answer is the bench you already brought up.** Most scenarios in this directory say so
in their own `Needs:` line — README's own words are that the six added 2026-08-23 are "all driveable
against the **local** bench — ollama, `git`, `docker`, the filesystem — and none needs a remote
provider or a forge". A scenario that spends *local* model calls costs patience, not capability, and
patience is a budget reason you state as one.

**A genuine capability gap is provable and you prove it.** Round 14's one real gap was
`prompt-slots` §6's paid half: `ANTHROPIC_API_KEY` is on no shell and in no `.envrc` on that box, and
the findings say exactly that. Write the gap the way you would write a finding — with the check that
established it.

## Phase 6 — Close out

- Kill the QA tmux server; confirm no stray `lain` processes.
- **Verify the negative:** `find ~/.local/state/lain -newermt '<round start>'` must be empty. That
  is the proof the sandbox held, and it belongs in the findings. **Keep the `Z`, and always run the
  positive control beside it** (`-newermt '<some earlier date>'` must be > 0) — `find` here is `bfs`,
  and a mis-spelled timestamp returns 0 unconditionally. Round 9 read 0 against a control of 468.
- **Two MORE negatives, because the one above cannot see either of them.** Both have now cost a
  round (round 8's P9, round 9's P11), and both live outside `~/.local/state/lain`:

  ```bash
  git -C "$LAIN_REPO" status --porcelain   # must match the baseline you took BEFORE act 0
  ls -d "$LAIN_REPO"/.lain 2>/dev/null      # must print nothing
  ```

  The first catches a sandbox `GEM_HOME` reaching `exe/lain` and silently re-locking `Gemfile.lock`.
  The second catches `.lain/state.json` written into whatever cwd a probe ran from — which for an
  agent driving `session-and-window` §1/§2/§7 is usually the lain checkout itself. **`git status`
  cannot see that one**, because lain's own repo gitignores `/.lain/` (`.gitignore:22`), so it is
  invisible to both of the other checks at once. Take the `git status` baseline at the START of the
  round; you cannot reconstruct it afterwards.
- **Confirm the desktop is still silent** — `dunstctl count displayed` and `waiting` both 0. The
  notifier is deleted (see Phase 2), so a non-zero here means something raised notifications that
  nothing in lain should be able to raise.
- **Kill every listener and daemon an act started, by pid, and check the ports.** Round 17 left a
  `pathcount.rb` listening on :21436 after `kill %1` in a shell that did not own the job, and a
  prefix allow-list approved `bin/rails server -d`, which daemonised puma on :3000 outside tmux.
  `ss -ltnp` over the ports the round used is the check; `tmux kill-server` does not reach either.
- Leave the sandbox directory in place — it is the evidence.
- Fold anything the round taught the *process* back into `planning/qa/method.md` or the scenario,
  and say you did. A round that improves only the code and not the method will re-learn the same
  lesson next time.

Then summarize to the user: what was confirmed fixed, what is new ranked by severity, what could not
be reached and why.

## The three rules that outrank everything else

README states these at more length under the same idea; these are the operative forms.

1. **Success is not "nothing went wrong."** A round that finds nothing new did not push hard enough.
2. **A fix can make the failure mode worse.** When a previous defect behaves *differently*, record
   whether differently means *better* — one round turned a >400s silent hang into a hard crash.
3. **Report faithfully.** If a step was skipped, say so. If a probe was inconclusive, say
   inconclusive — never record "could not reproduce" as a pass.
