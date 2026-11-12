# Scenario: notifications

**What it exercises:** the `notify` mode layer (lighter `BELL`), `Frontend::TTY::Bell` and `TTY::Notifier`, the
`ask_settled` record and the dim stamped line it draws, the editor's echo of a settled ask, and `Notices::Feed`, the
`notify-feed` program that `lain todos drain` also uses. Since 2026-11-11 it also exercises `AgentStates::Notices`: the
desktop and feed notice that waits for an agent to stay blocked or finished, skips a window the human is looking at, and
honours `quiet` (§7 to §9).

**Status:** written 2026-10-29 from the code at HEAD (`69e8dc60`: `frontend/tty.rb` (`Bell`, `render`),
`frontend/tty/notifier.rb`, `frontend/decorators/ask_settled.rb`, `telemetry/ask_settled.rb`, `cli/repl/ask.rb`,
`notices.rb`, `notices/feed.rb`, `frontend/neovim/surfaces.rb`, `runtime/66_notice.lua`). Nothing here has been driven.
Every "Expect" is a prediction read off the code, so a mismatch is either a defect or a stale line in this file, and
the round says which.

**Rewritten 2026-11-11 (`5100c953`) for the agent-state tracker.** A chat with a journal or `--nvim`, which is every cockpit,
now has a tracker, and its notifier is split in two. The in-pane half (the bell and the tmux message) still fires on each
ring at once. The out-of-band half (the desktop sequence and the `notify-feed` entry) no longer fires on a ring. It fires
from `AgentStates::Notices`, once an agent has stayed blocked or finished-and-unseen for `attention delay:` seconds
(30 by default), and not at all when the human is at the chat's window. §1 and §2 below say which half you are reading.
Only `lain chat --no-journal --no-nvim` has no tracker, and it keeps the old behaviour of everything at once.

**It supersedes two older sentences.** `repl-commands.md` §1 and `cockpit-surfaces.md` §5 say the layer rings the bell and
tmux's message "and nothing else", with no desktop notifier behind it. Since the notifier landed the layer also writes a
terminal escape sequence and runs `notify-feed`. Each of those files carries a pointer here. The bell and tmux halves
they describe are unchanged, so keep driving them there.

**The phone's `ntfy` notice** (`remote ntfy:`, an item waiting 60 s) is a different channel with its own scenario, `remote-phone.md` §5; this file covers the bell, tmux, the desktop notifier and the feed only.

**The question it answers:** does a human who walked away hear about a finished ask or a parked question exactly once,
through every channel the environment offers, and nothing when the layer is down? A note carries model-written text, so
the second question is whether a secret or a control byte in it ever reaches a terminal, tmux or the feed.

**Cost:** cheap. 3 short asks on a local model, one of them an `ask_human`. No spend.

**Needs:** `../bench.md` up, tmux, nvim for §5. A stand-in `notify-feed` (below). §7 to §9 need a user config
(`attention delay: 5` in the sandbox's `$XDG_CONFIG_HOME/lain/config.rb`, then `lain trust --user`) so a notice falls due in
seconds, and §8 needs a tmux client attached to the cockpit. Read `../method.md` first, build the
sandbox with `.claude/skills/manual-qa/scripts/qa-sandbox.sh`, and start each Bash call that touches files with
`: "${QA:?}"`. Read bytes off a `pipe-pane` capture of the chat pane, never by eye or ear (`cockpit-surfaces.md` §5).

---

## 0: The instruments

```bash
mkdir -p $QA/shim
cat > $QA/shim/notify-feed <<'EOF'
#!/bin/sh
{ printf '%s argv:' "$(date +%s)"; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\nbody: '; cat; printf '\n--\n'; } >> "$QA/feed.log"
EOF
chmod +x $QA/shim/notify-feed
cat > $QA/shim/tmux <<'EOF'
#!/bin/sh
echo "tmux $*" >> "$QA/tmux.log"; exec /usr/bin/tmux "$@"
EOF
chmod +x $QA/shim/tmux
```

Put `$QA/shim` first on the chat's `PATH`. The `tmux` wrapper logs its arguments, because a detached test server has no
client to show a message on. Capture the chat pane's bytes with `tmux pipe-pane -o -t <chat pane> "cat >> $QA/pane.bytes"`.
The terminal kind comes from the environment the chat starts in, so launch with the variables each section names, and
relaunch to change them.

Launch `lain up $QA/proj -- --provider ollama --model qwen3-coder:30b` from a tmux session, then in the input pane
`/mode`, which reads `checkout auto` with no layer. Raise the layer with `/mode +notify`: the lighter reads `BELL`.

## 1: The layer down says nothing at the moment of the ask

With no layer, ask "Reply with the word ok. No tools." and read the three logs within 20 seconds of the settle, which is
before any delayed notice can fall due (default delay 30, or the 5 you set).

- The chat pane draws one dim stamped line, `HH:MM:SS ask settled: end_turn after 1 turn in 3.2s` (the numbers are the
  ask's), below the model's reply, never above it: the line is announced only once the reply is on screen. The line is
  drawn whatever the layer. A line above the reply is the defect.
- `pane.bytes` holds no `\a`, no `ESC ]9;`, no `ESC ]99;`, no `ESC ]777;`. `tmux.log` has no `display-message`. `feed.log` has
  no record. Check the three with `grep -c`, and read the control run as the pass: a stand-in that never ran proves nothing,
  so run §2 before believing a clean §1.
- The journal holds an `ask_settled` record after the last `turn` record, with `head` (that turn's digest), `stop_reason`
  `end_turn`, `turns` 1 and a `seconds` that matches the line. `ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue
  next; puts l if %w[turn ask_settled run_interrupted].include?(r["type"])}' $S | tail -3`.

**What changed, and the unhappy half of this section.** The layer being down silences the bell and the tmux message. It
does not silence the delayed notice: the finished ask leaves `main` done and unseen, so once the delay passes with nobody at
the window, `feed.log` gains `[lain] [<project>]` with body `done: main`, and `pane.bytes` gains one desktop sequence, with
no `notify` layer up. That is the intended shape (only `quiet` silences it, §9), so a record in `feed.log` at second 31 is
the pass and a record at second 2 is the old behaviour back. The earlier version of this section said `feed.log` stays empty
for the whole round, and a driver who still believes it will file the delayed record as a defect.

## 2: The layer up rings the in-pane channels at once; the other two wait

`/mode +notify`, then the same ask. One settle is one ring, and a ring is now two halves.

**The in-pane half, at the moment of the settle:**

1. one `\a` in `pane.bytes` (the bell, first);
2. one `display-message` line in `tmux.log` (inside tmux only), carrying the note text, `ask settled: end_turn after 1
   turn in 3.2s`.

**The out-of-band half is not there yet.** Within 20 seconds of the settle `pane.bytes` holds no desktop sequence and
`feed.log` holds no record. That is the pass for a chat with a tracker, and it is the check the old section could not make.

**After the delay, with nobody at the window** (a detached tmux server has no client, which counts as nobody):

3. one desktop sequence, chosen by the environment the chat started in (below), whose text is `done: main`, not the ask-settled
   sentence;
4. one record in `feed.log`: argv `[lain] [<project basename>]`, body `done: main`. The program is found on `PATH` by name; the
   body arrives on stdin, never in argv.

Two notes about one settled ask is correct: the ring's sentence and the notice's sentence differ on purpose, and each fires
once. Count them. A second desktop sequence or a second feed record for the same settle is a defect.

**The unhappy half: a chat with no tracker keeps every channel at once.** Run `lain chat --no-journal --no-nvim` in a tmux
pane (no cockpit has this shape, because a cockpit always carries nvim). Under `/mode +notify` the same ask rings all 4
channels within a second, in the old order (bell, desktop sequence, tmux message, feed), with the sentence `ask settled: ...`
in all 4, and no delayed record follows 30 seconds later. This is the control that shows the delay is the tracker's doing and
not a slow `notify-feed`.

**The sequence by terminal** (the title is the project's directory name). A pane inherits the tmux server's environment and
tmux sets `TERM_PROGRAM=tmux` itself (measured on tmux 3.7b), so an `iTerm.app` value cannot reach a pane through the
launching shell. Start the chat in the pane as `env TERM_PROGRAM=iTerm.app lain chat ...` for that row. `KITTY_WINDOW_ID`
passes through if it is exported before the tmux server starts (kill the server between rows). The same rule puts
`$QA/shim` on the chat's `PATH`: export it before the server starts.


| Environment | Bytes in `pane.bytes` |
|---|---|
| `TERM_PROGRAM=iTerm.app` | `ESC ] 9 ; <text> BEL` |
| `KITTY_WINDOW_ID=1` (and not iTerm) | `ESC ] 99 ; ; <text> ESC \` |
| neither | `ESC ] 777 ; notify ; <title> ; <text> BEL` |
| any of the above, plus `$TMUX` set (always so in a cockpit) | the same bytes wrapped as `ESC P tmux ; <sequence with every ESC doubled> ESC \` |

Check with `od -c` on the slice. Read the wrap against the real environment: a cockpit is always inside tmux, so the
bare forms need `TMUX=` unset in the chat's own environment, which a cockpit cannot do, so say how you drove them (a
plain `lain chat --no-nvim` in a pane with `TMUX` removed with `env -u TMUX`). Passthrough also needs `set -g
allow-passthrough on`; the capture shows what lain wrote, not what tmux forwarded, and that is the claim.

**A semicolon in the title or text becomes a space** in the sequence only (it would end an OSC field early). The
`display-message` and the feed body keep the original text. Launch from a directory named `a;b` to see it.

**The ring is one write.** Run an ask that streams a long answer, and check that every `ESC ]` in `pane.bytes` is followed
by its terminator with no other byte between them. The sequence goes through the countdown's writer lock, so a status
tick or a streamed chunk cannot interleave with it; a split sequence prints raw text onto the screen.

## 3: What else rings

Under the layer, the same bell and notifier fire for the arrivals that summon a human, not only for a settled ask:

| Trigger | Expect |
|---|---|
| the model calls `ask_human` | the arrival line `? agent <question>  -- answer in lain://inbox, or /inbox`, then one ring whose note is that line |
| a parked call in a cockpit (`/mode ask`, `git status --short`) | the `! <requester> asks to run ...` line, then one ring |
| a review's "a file is waiting" line | one ring |
| a plain `--no-nvim` chat's inline `[y/N]` | no ring (not an arrival line); this is the shape `cockpit-surfaces.md` §5 records, so record it again |
| an ask you stop yourself (`/stop`, or Ctrl-C then `s`) | the `run_interrupted` record, no `ask_settled`, and no ring: a stop the human made is silent, and so is the delayed notice (the agent goes back to idle, not done) |
| an ask that fails for a reason that is not yours (the provider errors out, or `--max-tokens 8` ends it on `max_tokens`) | the error line, a `run_interrupted` record, no `ask_settled`, and one ring whose note is `ask failed: <reason>`; the delayed notice then reads `failed: main (<reason>)`, not `done: main` |
| a refused ask (a prompt over the window) | no `ask_settled`; the refusal prints as an error and does not ring |

**A wait on the human also starts a delayed notice**, separate from the arrival ring in the table. If an `ask_human` or a parked
call stays open past the delay with nobody at the window, `feed.log` gains one `blocked: <what>` record and `pane.bytes` one
sequence, where `<what>` is the wait's own summary and not the arrival line. Answering inside the delay sends neither (§7).

An ask that ends on `max_tokens` or another failed stop reason is a failure, not a settle: with `--max-tokens 8` the pane shows
the error, the journal holds `run_interrupted` and no `ask_settled`, and the bell, tmux message and (after the delay, with nobody
at the window) the desktop sequence and feed record all carry the failure, so a human who walked away still hears of it. A
failure that rings nothing, or one that is announced as `done: main`, is the finding. Wording to record: the delayed note reads
`failed: main (max_tokens)`.

## 4: The feed's failure domains

Each step of a ring is its own failure domain: a note is already on the screen when it rings, so no step may cost the
render or a later step.

| Do | Expect |
|---|---|
| a `notify-feed` that exits 1 | the ask completes, later rings still run, and the chat's warning line names it once with its path, `<path> exited 1`, however many notes follow (a second failing note says nothing more). A chat with no tracker and `lain todos drain` name it the same way, the drain on its own output |
| a RubyGems binstub named `notify-feed` ahead of the real one on `PATH` | the real feed is found: the search skips a file carrying the line `This file was generated by RubyGems.`, wherever it sits, so a real `notify-feed` in a distro ruby's `/usr/bin` is still reached. Put a stub that carries that line first on `PATH` and confirm `feed.log` gets the record from the later one |
| a `notify-feed` that sleeps 30 | the render and the next prompt are not held more than about 2 seconds; the feed is killed at its 2 second timeout |
| a `notify-feed` that sleeps 30, in the delayed path (§7) | the notice's loop gives up at the 2 second timeout, the prompt is not held, and the next notice still arrives; a single failing notice must not stop later ones. Record what the pane shows (the loop swallows the fault, so it should show nothing) |
| no `notify-feed` on `PATH` | no record, no error, no message: the feed is a null object |
| a `tmux` that hangs | the bell and the sequence are already written; the prompt returns |
| `lain todos drain` (see `todos-drain.md`) | calls the same program, `notify-feed lain <chore text>`, body on stdin, once per chore after its line is written |

`notify-feed` is looked up by name on `PATH` only; there is no flag or env override for a path in the chat. Say that it
is the user's own script (`~/dev/junk-drawer/morning-feed` is its consumer) and do not run the real one in a round.

## 5: The editor's echo

In a cockpit the editor also hears of a settled ask, as a quiet echo that must never raise hit-enter.

- After each settled ask the message area reads `lain: done in 3s, 2 turns` (the seconds rounded, `1 turn` singular). It is
  posted whether or not the layer is up, because it is a view of the same event, not a ring.
- Read the cmdline with `nvim_exec2("messages", {output=true})` and the mode with `nvim_get_mode()`: the mode is not
  `r` or `rm`, and nothing blocks the next keypress. The echo is in the Normal highlight, not the warning colour.
- A sentence longer than the message area is cut with an ellipsis and is not recorded in `:messages`; a short one is.
  Narrow the nvim pane to 30 columns and settle an ask to see both cases.
- An ask that is interrupted or refused echoes nothing.

## 6: What a note may carry

A note's text is model-written for a question arrival and fixed-format for a settle, so only arrivals can hold a secret or
a control byte. The notifier masks before it cuts, scrubs control characters and cuts at 200 characters.

- **Secret.** Launch with `OLLAMA_API_KEY=abc123lowentropyvalue` in the environment (the session-secret check of
  `secret-boundary.md` §4f). Under the layer ask the model to call `ask_human` with the text `is abc123lowentropyvalue the
  right key`. **Positive control:** the journal must hold an `ask_human` `tool_use` whose input contains that exact text, or the same sentence with the value as `<redacted:N>` if the journal masked it; if
  the model paraphrased it, the "0 hits" below pass vacuously and the step is voided, not passed. Also check that
  `pane.bytes`, `tmux.log` and `feed.log` hold a ring for this arrival at all (a ring with nothing in it proves nothing). The pane's arrival line is masked by the existing surface. The point here is the notifier: the desktop
  sequence, the `display-message` and the feed body each hold `<redacted:1>`-style text and 0 hits of the value, because the
  mask is built from the secrets known at that moment, read afresh per note.
- **Control bytes.** A raw `ESC` or newline in a question becomes a space in all 3 outputs, so an `ESC ] 0 ; ...` payload cannot
  retitle the terminal. A live ollama model's tool-call parser breaks on a raw ESC (round 28), so the model never delivers
  one. Name a scripted vehicle (a stub provider) or the check is not run, and say which.
- **The delayed half arrives late.** The desktop sequence and the feed body for an arrival come from the notice after the
  delay, so wait it out (or set `attention delay: 5`) before counting hits; a count taken at second 2 finds nothing and passes
  vacuously. The notice text is `blocked: <the wait's summary>`, masked and cut the same way.
- **Length.** Positive control: the journal's `ask_human` input is 600 characters, and a ring exists. A 600-character question reaches the sequence, `display-message` and feed as at most 200 characters. The cut
  follows the mask, so a secret straddling character 200 cannot leave a stub that no mask recognises; plant it at
  character 195.

## 7: A notice waits for the delay, and a wait settled inside it sends nothing

**Setup.** `attention delay: 5` in the user config, trusted. `$QA/shim` first on `PATH`, the `notify-feed` stand-in logging
a timestamp (§0), a cockpit launched detached so nobody is at the window. No `notify` layer: §1 says the delayed notice does
not need it.

**Happy path 1, a parked approval.** `/mode ask`, then ask for a `bash` call (`git status --short`) and leave it parked.
Expect no desktop sequence and no feed record for 5 seconds after the park line, then exactly one of each: the feed record is
argv `[lain] [<project basename>]`, body `blocked: <the call's summary>`, and the sequence text is the same sentence. Wait 30
more seconds: no second record, because a notice falls due once per episode. Approve it. Expect no record for the approval
itself.

**Happy path 2, a finished child.** Ask for one subagent task and leave the window unattended past the delay: body
`done: <the child's role>` (its spawn digest when the spawn names no role, or `main` for the main chat's own finish). Each finished agent has its own
episode, so 2 children finishing together give 2 records.

**Unhappy path 1, settled inside the delay.** Park a call and approve it within 3 seconds. Expect no record and no sequence,
ever. The focus probe must not run either: with the tmux shim logging, no `display-message` carrying
`#{window_active}` appears during the whole round (the probe asks `display-message -p -t <chat pane> '#{window_active}
#{session_attached}'`, so grep for `window_active`). A probe in this log means the delay is probing early.

**Unhappy path 2, a wait that comes back.** Park a call, wait 4 seconds, approve it, and park a second one at once. Expect the
clock to restart: the record arrives about 5 seconds after the SECOND park, not after the first.

**Unhappy path 3, the delay is the user's alone.** Put `attention delay: 5` in `$QA/proj/.lain/config.rb` instead and start
the chat. Expect a refusal naming that file, the line and the user's `config.rb`. Then `attention delay: -1`, `attention
delay: "soon"` and `attention dealy: 5` in the user file: each is refused naming the key and the value. The chat must not
start with a silently defaulted delay.

**Wrong looks like:** a record at second 0 (the old behaviour), a record for a wait the human answered, 2 records for one
episode, or a probe of the window before any notice fell due.

## 8: A window the human is looking at is skipped, and the done count clears

**Setup.** As §7, plus a tmux client attached to the cockpit with the chat's window selected. The cockpit's chat pane is not
the active pane (`lain up` selects the input pane), so what is tested is the WINDOW. Attach a real client from a pty (an outer
`tmux -L outer` pane running `tmux -L "$QA_SOCK" attach`). A control-mode client (`tmux -C attach` held open on a fifo) may also
count as attached; if it does not, say so and use the pty. Check the premise first:
`tmux -L "$QA_SOCK" display-message -p -t <chat pane> '#{window_active} #{session_attached}'` must read `1 1` (or a higher count).

**Happy path, at the window.** Let `main` finish an ask and stay at the window past the delay. Expect no feed record and no
sequence, and the HUD's `done:1` (§10) gone after the delay, because the notice marked the agent seen instead of sending.

**Unhappy path 1, another window.** `tmux select-window` to a second window of the same session. Finish another ask and wait
the delay. Expect the record and the sequence, and `done:1` stays until the next ask starts.

**Unhappy path 2, detach.** `tmux detach-client`. `session_attached` reads 0, so the same finish sends. A tmux that cannot be
asked (move the `tmux` shim aside so it exits 1) must read as not focused, so the notice goes out: the safe side of not
knowing is ringing.

**Unhappy path 3, inside herdr.** The focus question changes with where the chat runs. See `herdr.md` §6, which needs both
tmux and herdr to say focused before a cockpit's notice is skipped.

**Wrong looks like:** a notice sent while the client sits on the chat's window, a silent notice when the client is on another
window, or a `done:1` that never clears when the human was present.

## 9: `quiet` silences every out-of-band notice

`/mode +quiet` (lighter `QUIET`) in the cockpit, then repeat §7's happy paths 1 and 2 unattended.

- **Happy path (quiet holds).** Past the delay, `feed.log` and `pane.bytes` gain nothing, for a blocked call and for a finish.
  The in-pane half is quiet too: a wait on the human normally rings the bell without the `notify` layer, and `quiet` turns
  that off, so `pane.bytes` has no `\a` either.
- **Unhappy path (quiet lifted mid-wait).** Park a call under `quiet`, wait past the delay (nothing arrives), then
  `/mode -quiet`. Predicted: the notice was already due and dropped when it fell due, so lifting `quiet` later sends nothing
  for that episode, and the next episode notifies normally. This follows the code (`quiet` is checked when a notice falls due
  and the episode is forgotten either way), so record what the round sees rather than assuming it.
- **Control.** `/mode -quiet` and repeat: the record arrives. A silent run with no control proves nothing.
- **The immediate bell stays immediate.** With `notify` up and `quiet` down, a ring still produces the bell and the tmux
  message within a second even though the desktop half waits. A ring that waits for the delay has moved the whole notifier
  behind it.

## What this scenario cannot answer

- **Whether a desktop shows the notification.** The capture proves the bytes lain wrote, not that iTerm, kitty or a
  desktop daemon drew them, nor that tmux forwarded the passthrough.
- **Whether 30 seconds is the right delay.** The default is a ruling, not a measurement. §7 shortens it to 5 so a round can
  observe the delay at all.
- **Whether the bell is wanted at 3 in the morning.** The layer is off by default and nothing says when it should be on.
- **A `--prompt` one-shot's settle.** The record is written from the interactive ask path; run a `--prompt --non-interactive`
  chat and record whether it journals `ask_settled` and rings, since no card says it should.
