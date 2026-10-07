---
name: manual-qa
description: lain's inputs for the user-level manual-qa skill, which runs under this name and reads this file. Holds the sandbox script, the gates before act 1, and lain's close-out negatives. The procedure, scenario shape, and findings format live in ~/.claude/skills/manual-qa.
---

# Manual QA in lain

The procedure is the user-level `manual-qa` skill. `planning/qa/README.md` owns the
roster and its order, `planning/qa/method.md` owns the method, and `planning/qa/bench.md`
brings up the model server. This file repeats none of them.

## Bring-up

```bash
bash .claude/skills/manual-qa/scripts/qa-sandbox.sh [round-tag]   # builds $QA and its helpers
```

Re-running with the same tag reuses the sandbox. Then follow `bench.md`: start or confirm
the model server, record `OLLAMA_NUM_PARALLEL`, `n_slots`, and residency.

`ls $QA` lists the helpers; the script's section headers say what each does. They
implement the driving rules in `method.md`: send Enter once and poll the pinned journal,
read panes by what runs in them, drive nvim over RPC, answer a parked call by buffer.

## Gates before act 1

A failure in any of them stops the round.

1. `$QA/isolation.sh` exits 0: every cockpit pane carries all 5 sandbox variables. Never
   re-type the grep (`method.md`, Isolation).
2. `~/.lain` does not exist.
3. The machine is quiet: `uptime`, and no orphaned spinners from earlier agent work
   (`method.md`, Check the machine is quiet).

The desktop notifier is deleted (`method.md`, The desktop notifier is gone). A scenario
section that checks it is recorded as moot.

## Record per act

The journal path, `.lain/state.json`, `.lain/config.rb`, both panes captured at the
moment of a finding, and `ollama ps`.

Restart the session when a literal `<function=` appears in a transcript. Never restart
to dodge the iteration ceiling; it is per ask (`method.md`, Budget the round).

Keep model findings apart from lain findings (`method.md`, What the local model does
badly).

## Close-out negatives

Each with its positive control beside it (`method.md`, Isolation):

```bash
find ~/.local/state/lain -newermt "$(cat "$QA/records/round-start")"   # must print nothing
env -u XDG_CONFIG_HOME git -C "$LAIN_REPO" status --porcelain          # must match the baseline
ls -d "$LAIN_REPO"/.lain 2>/dev/null                                   # must print nothing
dunstctl count displayed; dunstctl count waiting                       # both 0
ss -ltnp                                                               # no port the round used
```

Leave `$QA` in place. It is evidence.
