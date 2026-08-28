# QA round 16 — 2026-08-28

**Scope:** a **scoped verification round**, not a full round. The user asked for the round-15 chunk's
integration checks 5, 6, 7, 8 and 11 (`planning/specs/chunk-qa-round15-what-nothing-retires.md`).
Every other scenario is accounted for in the coverage table with its reason.

**Bench:** ollama `qwen3-coder:30b`, local. Sandbox `~/tmp/lain-qa-round16`, tag `round16`, left in
place as evidence. Round start `2026-08-28T14:26:01Z`.

**Desktop: every act ran with `LAIN_DESKTOP=0`**, verified per pane out of `/proc/<pid>/environ`
(all three panes reported `1`). No act needed the notifier. Proved by the negative at close-out:
`dunstctl count displayed` **0** and `waiting` **0**, and approvals are `-u critical` so any that
fired would still be on screen.

---

## Summary

| # | what | verdict |
|---|---|---|
| F84 | `--windows` opens no tmux window for a spawn, silently | **DEFECT — high** |
| F85 | `drive.sh`/`peek.sh` cannot see a `lain chat` that is not the pane's foreground command | **DEFECT (bench) — medium** |
| F86 | `/introspect` calls the window size "unreported" while compaction has it probed | **UX — low** |
| F87 | the compaction report is labelled `stderr` on an operator-facing line | **UX — low** |
| P35 | the close-out `git status` gate cries wolf under sandbox env; round 9's warning names the wrong variable | **process — medium** |
| — | **check 5** — a relayed subagent question retires from all four inbox readers | **FIXED, confirmed** |
| — | **check 6** — a finished spawn leaves the fleet | **FIXED, confirmed** |
| — | **check 7** — the operator is told the context is full and uncompactable | **FIXED, confirmed** |
| — | check 8 | **partly confirmed** — scripts pass, `--windows` is F84 |
| — | check 11 | **partly driven** — see coverage |

---

## Confirmed fixed

### Check 5 — F81 retires, on both the relayed question and the control

Round 15's baseline was `/inbox` correct and **the other three readers reading 3**. All four now
agree at zero, for a **relayed subagent** question and for the parent's own `ask_human` control in
the same session.

Driven: one ordinary turn; then a spawn whose child called `ask_human` ("What colour would you like
to paint the shed?"); the prompt parked at `human>`; answered as prose.

Before answering — all four listed it:

| reader | before | after |
|---|---|---|
| `/inbox` (repl) | `researcher 1m  What colour…` | prompt returns to `you>` |
| `inbox_count` (`state.json`) | `1` | **`0`** |
| `lain://inbox` (nvim) | `researcher  0s  What colour…` | **`(no questions pending)`** |
| `:LainReply` | a listed row | **`lain: that line names no question set -- answer from a listed row`** |

The fourth is the one that mattered: it refuses **because nothing is listed**, not because a listed
row is stale — the distinction check 5 was written to force.

**Control** (parent's own `ask_human`, same session): identical — `inbox_count 0`,
`(no questions pending)`, same refusal.

**T1's record is live in the journal:** `"type":"questions_consumed"` appears in the session file.

### Check 6 — F83 retires

`state.json` went `fleet: ["blake3:d53d8e62…"]` → **`fleet: []`** when the child finished, and the
HUD line lost its segment entirely (`qwen3-coder:30b ctx 16% idle 2m` — no `fleet`), which is the
zero-elision. Round 15 read `fleet 3`.

**T6 confirmed in production.** The completion record carries both fields:

```
message  lifecycle=stopped  result?=True  causal=['blake3:adec1d050f8', 'blake3:d53d8e62667']
SPAWN    digest=blake3:d53d8e62667f78df3
```

— the `causal_parents` join T8's `Fleet#completed` retires on. And `lain watch` renders the mark:
`[blake3:12d65a755e64 message] (stopped) The human has replied…` — the operator-facing change T6's
review pinned in `watch_spec.rb`.

### Check 7 — F82 speaks

Reproduced rails-blog's shape in a fresh session with `--num-ctx 32768` and one `read_file` of a
114,666-byte file. The decision record reached F82's exact state:

```
{'compacted': False, 'signals': ['approaching_window'], 'head_bytes': 2,
 'nothing_droppable': True, 'window_tokens': 32768, 'used_tokens': 30408}
```

and **the pane said so**:

```
[lain:compaction stderr] compaction is warranted (approaching_window) and nothing is droppable --
every earlier turn is either inside keep_last or pinned. 30408/32768 tokens; unpin a turn, lower
--compact-keep, or start a new session
```

Round 15's evidence was silence in precisely this state.

**T4's narrowing and latch both confirmed live.** The two decisions *before* this one had
`nothing_droppable: True` but `signals: []` (occupancy 5202/32768) and correctly said **nothing** —
the over-firing the review caught is gone. And the turn *after* also had
`signals: ['approaching_window'], nothing_droppable: True` at 30438/32768, yet the report appears
**exactly once** in the pane. Edge-triggered, as specified.

**A timing note worth keeping:** the decision is written at turn *start*, so the turn that fills the
window records the *previous* occupancy. The report necessarily lands on the **next** turn. A round
that drives one big read and stops will see nothing and wrongly call it unfixed.

### T14, verified against the live surface

`/help` lists **21** commands, matching `surface_spec.rb`'s literal roster exactly, `/introspect`
among them. `/introspect` reports every field T14 documented. `/mode !` from `accept_edits` with two
layers → `plan (PLAN): no layers active` in one move, never raising the posture to `auto`.

### T12, re-measured

`bundle exec rspec spec/lain/frontend/neovim/diff_mode_spec.rb -e "a round that presents one side"`
— 11 examples, 0 failures, against real headless nvim. Pins a survey's review tab at
`%w[sidebar new]` and a changeset's at `%w[sidebar old new]`, which is the ruling T12 made over a
contradicting §4b.

---

## Defects

### F84 — `--windows` opens no tmux window for a spawn, and says nothing — HIGH

**Reproduction.** Inside tmux, `lain up --socket <s> --session <n> <proj> -- --provider ollama
--model qwen3-coder:30b --windows`. Spawn a subagent. Poll `tmux list-windows`.

**Observed.** Across **two** separate spawns, and polled every 5s for 120s across one of them, no
window was ever created. Windows stayed `zsh chat` throughout, and none appeared at teardown either
(polled 48s after `/quit`, which did close the chat pane).

**Every innocent explanation ruled out, by measurement:**

- the flag is real and declared — `lain help chat` documents `--windows` ("Open a tmux window
  running `lain watch` per subagent spawn (needs $TMUX and the session journal…)");
- it reached the process — the chat's `/proc/<pid>/cmdline` ends `--model qwen3-coder:30b --windows`;
- `$TMUX` is set in the chat pane (`TMUX=/tmp/tmux-1000/lain-qa-round16,1282085,1`);
- the journal is on (default), so `refuse_windows_without_journal!` did not fire, and it raises
  loudly rather than degrading;
- the cap is not it — `CAP_PER_TURN = 4`, two spawns, and **no `windows_capped` record** in the
  journal (record types enumerated);
- the window's command works and *stays running* — `lain watch <spawn-digest>` from the project cwd
  tails correctly, and a fleet window would inherit that cwd (`pane_current_path` is the project).

**Probable mechanism, read but not instrumented.** `Pump::DEFAULT_SPAWNER` is
`Async::Task.current?&.async(transient: true, &pump)` (`cli/fleet_windows.rb:77-79`). Outside a
reactor task `Async::Task.current?` is `nil`, the `&.` short-circuits, and `ensure_task` leaves
`@task` nil — so nothing drains the queue. The only production `drain_pending` is at teardown
(`chat_launch.rb:104`). That fits everything above **except** that teardown produced no window
either, so the account is incomplete and I am naming it as a hypothesis, not a cause.

**Why it is high.** The flag is accepted, both documented preconditions are met, and the feature
does nothing with no error, no record and no degraded-capability notice. `FleetWindows` is also the
one consumer T7 was written to serve, so the card's production path is unexercised in practice.

### F85 — the driver cannot see a `lain chat` that is not the pane's foreground command — MEDIUM (bench)

`drive.sh` and `peek.sh` resolve candidates with
`list-panes -a -F '#{pane_id} #{pane_current_command}' | grep -w ruby`. A second `lain chat` started
under a wrapper (`sh -c "lain chat …; read"`) has `pane_current_command=zsh`, so it is **not a
candidate**, no ambiguity is detected, and the send goes silently to the other pane.

**Reproduction, and it bit this round.** With two live chats (`%2` cockpit, `%5` wrapped), `drive.sh`
sent a probe string and it landed in the **cockpit**:

```
%0 cmd=zsh   %1 cmd=nvim   %2 cmd=ruby   %5 cmd=zsh
what drive.sh greps for ->  %2 ruby
pane pid 1283235 IS a lain chat
pane pid 1294831 has a lain chat CHILD (invisible to pane_current_command)
```

`%2: 1` — the cockpit received text intended for `%5`.

This is round 15's original hazard (a prompt intended for a probe adding a turn to the subject
session), which T10 closed for the *matching-command* case only. The refusal now gives false
confidence: a driver reasonably reads "it refuses on ambiguity" as "it cannot mis-aim". Resolve on
the pane's **process tree** (any descendant matching `exe/lain chat`) rather than on
`pane_current_command`, or state the limit in `method.md`.

### F86 — two surfaces disagree about whether the window size is known — LOW (UX)

`/introspect` prints *"occupancy 92.9% at the last model response, of a window whose size is
**unreported** below"*, and lists `window` under `unreported`. On the same session the compaction
record carries `window_tokens: 32768, provenance: "probed"` — lain measured it. Two operator-facing
surfaces give different answers to "do we know the window size".

### F87 — the compaction report is labelled `stderr` — LOW (UX)

The line renders as `[lain:compaction stderr] compaction is warranted …`. The content is right and
actionable; the `stderr` label reads as a leaked diagnostic channel rather than a deliberate report,
on the one message T4 added specifically for an operator.

---

## Process

### P35 — the close-out gate cried wolf, and the standing warning names the wrong variable — MEDIUM

**This is a re-occurrence of round 9's P16, not a new hazard**, and the honest version is that the
warning was already in `method.md:137` and I walked into it anyway. But it is worth filing, because
the warning names the wrong mechanism.

`SKILL.md` Phase 6 says to run `git -C "$LAIN_REPO" status --porcelain` and compare against a
baseline. Run after sourcing the sandbox `env.sh` — the natural way, since every other close-out
step needs `$LAIN_REPO` and `$QA` — it sets `XDG_CONFIG_HOME` into the sandbox. Git resolves its
global ignore as `$XDG_CONFIG_HOME/git/ignore` **first**, falling back to `$HOME/.config/git/ignore`
only if that is unset, so every globally-ignored file reports as untracked.

`method.md:137` warned about this but attributed it to **a redirected HOME** ("which secret-boundary
REQUIRES") — a case that arises in one scenario. The variable that actually breaks it is
`XDG_CONFIG_HOME`, which `qa-sandbox.sh` redirects on **every** round, with HOME untouched. A reader
checking "am I redirecting HOME? no" concludes the warning does not apply, which is what happened
here. This round produced six phantom entries (`.envrc`, `.claude/settings.local.json`, and
four more) and read as a **failed sandbox gate**. Re-run with the real `XDG_CONFIG_HOME` it is
byte-identical to the baseline.

The gate is exactly the one that must not cry wolf. **Folded into `method.md` in this round**: the
comment now names `XDG_CONFIG_HOME` as the variable git actually resolves first, gives
`env -u XDG_CONFIG_HOME git -C "$LAIN_REPO" status --porcelain` as the one-line form, and says to
take the baseline and the reading under the same env either way.

---

## Coverage

The directory listing is the authority: **18 scenarios**, enumerated at Phase 1.

| scenario | driven | reason if not |
|---|---|---|
| `repl-commands` | **yes**, partly | §1 command surface, `/introspect`, `/mode !` reset — the parts T14 edited |
| `cockpit-surfaces` | **yes**, partly | approval/inbox surfaces via `lain://inbox`, `:LainReply`; survey window count re-measured by seam spec instead of a cockpit drive |
| `subagents-and-backends` | **yes**, partly | one-shot spawn, relay, retirement — checks 5 and 6 |
| `rails-blog` | **yes**, partly | §1 compaction reproduction only (check 7); the blog build itself not driven |
| `failure-injection` | **no** | budget. T13's §1b rewrite needs a severing proxy and two full stream runs; its central claim was verified by the landed spec instead |
| `session-and-window` | **no** | budget |
| `epic-tier` | **no** | budget |
| `survey` | **no** | budget; T12's ruling re-measured via `diff_mode_spec.rb` instead |
| `prompt-slots-and-roles` | **no** | budget |
| `bowling-ruby` | **no** | budget; not in this round's scope |
| `bench-arms` | **no** | budget; not in scope |
| `changeset-review` | **no** | budget; not in scope |
| `memory-and-dogfood` | **no** | budget; not in scope |
| `rust-cli` | **no** | budget; not in scope |
| `secret-boundary` | **no** | budget; not in scope |
| `shell-terms` | **no** | budget. **Still never driven** — the one scenario in the directory with zero rounds against it |
| `shell-term-approval` | **no** | budget; not in scope |
| `ollama-cloud-arm` | **no** | budget; not in scope. Needs a key, which is a separate question from this round's |

**Every "no" above is budget, not capability.** All of these run against the local ollama bench that
was up and warm for this entire round. Check 11's regression gate is therefore **not discharged**;
what was driven is the subset that exercises this chunk's own edits.

---

## Negatives

| check | result |
|---|---|
| `find ~/.local/state/lain -newermt '2026-08-28T14:26:01Z'` | **0** (control at an earlier date: **9513**) |
| `git status --porcelain` vs baseline (real `XDG_CONFIG_HOME`) | **identical** |
| `ls -d $LAIN_REPO/.lain` | **absent** |
| `dunstctl count displayed` / `waiting` | **0 / 0** |
| stray `exe/lain` / round nvim after teardown | **none** |
