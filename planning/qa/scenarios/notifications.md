# Scenario: notifications

**What it exercises:** the `notify` mode layer (lighter `BELL`), `Frontend::TTY::Bell` and `TTY::Notifier`, the
`ask_settled` record and the dim stamped line it draws, the editor's echo of a settled ask, and `Notices::Feed`, the
`notify-feed` program that `lain todos drain` also uses.

**Status:** written 2026-10-29 from the code at HEAD (`69e8dc60`: `frontend/tty.rb` (`Bell`, `render`),
`frontend/tty/notifier.rb`, `frontend/decorators/ask_settled.rb`, `telemetry/ask_settled.rb`, `cli/repl/ask.rb`,
`notices.rb`, `notices/feed.rb`, `frontend/neovim/surfaces.rb`, `runtime/66_notice.lua`). Nothing here has been driven.
Every "Expect" is a prediction read off the code, so a mismatch is either a defect or a stale line in this file, and
the round says which.

**It supersedes two older sentences.** `repl-commands.md` §1 and `cockpit-surfaces.md` §5 say the layer rings the bell and
tmux's message "and nothing else", with no desktop notifier behind it. Since the notifier landed the layer also writes a
terminal escape sequence and runs `notify-feed`. Each of those files carries a pointer here. The bell and tmux halves
they describe are unchanged, so keep driving them there.

**The phone's `ntfy` notice** (`remote ntfy:`, an item waiting 60 s) is a different channel with its own scenario, `remote-phone.md` §5; this file covers the bell, tmux, the desktop notifier and the feed only.

**The question it answers:** does a human who walked away hear about a finished ask or a parked question exactly once,
through every channel the environment offers, and nothing when the layer is down? A note carries model-written text, so
the second question is whether a secret or a control byte in it ever reaches a terminal, tmux or the feed.

**Cost:** cheap. 3 short asks on a local model, one of them an `ask_human`. No spend.

**Needs:** `../bench.md` up, tmux, nvim for §5. A stand-in `notify-feed` (below). Read `../method.md` first, build the
sandbox with `.claude/skills/manual-qa/scripts/qa-sandbox.sh`, and start each Bash call that touches files with
`: "${QA:?}"`. Read bytes off a `pipe-pane` capture of the chat pane, never by eye or ear (`cockpit-surfaces.md` §5).

---

## 0: The instruments

```bash
mkdir -p $QA/shim
cat > $QA/shim/notify-feed <<'EOF'
#!/bin/sh
{ printf 'argv:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\nbody: '; cat; printf '\n--\n'; } >> "$QA/feed.log"
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

## 1: The layer down says nothing

With no layer, ask "Reply with the word ok. No tools."

- The chat pane draws one dim stamped line, `HH:MM:SS ask settled: end_turn after 1 turn in 3.2s` (the numbers are the
  ask's). The line is drawn whatever the layer.
- `pane.bytes` holds no `\a`, no `ESC ]9;`, no `ESC ]99;`, no `ESC ]777;`. `tmux.log` has no `display-message`. `feed.log` has
  no record. Check the three with `grep -c`, and read the control run as the pass: a stand-in that never ran proves nothing,
  so run §2 before believing a clean §1.
- The journal holds an `ask_settled` record after the last `turn` record, with `head` (that turn's digest), `stop_reason`
  `end_turn`, `turns` 1 and a `seconds` that matches the line. `ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue
  next; puts l if %w[turn ask_settled run_interrupted].include?(r["type"])}' $S | tail -3`.

## 2: The layer up rings every channel, in order

`/mode +notify`, then the same ask. One settle is one ring:

1. one `\a` in `pane.bytes` (the bell, first);
2. one desktop sequence, chosen by the environment the chat started in (below);
3. one `display-message` line in `tmux.log` (inside tmux only), carrying the note text, `ask settled: end_turn after 1
   turn in 3.2s`;
4. one record in `feed.log`: argv `[lain] [<project basename>]`, body `ask settled: end_turn after 1 turn in 3.2s`. The
   program is found on `PATH` by name; the body arrives on stdin, never in argv.

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
| an ask that fails (stop the model mid-answer with `/stop`) | the `run_interrupted` record, no `ask_settled`, and no ring from the settle path |
| a refused ask (a prompt over the window) | no `ask_settled`; the refusal prints as an error and does not ring |

An ask that ends on `max_tokens` or another failed stop reason is a failure, not a settle: check what the journal and the pane
show for a stop at `--max-tokens 8`, and record it (the code says a response with a `failure` is said as an error and
`ask_settled` is written only on the success branch).

## 4: The feed's failure domains

Each step of a ring is its own failure domain: a note is already on the screen when it rings, so no step may cost the
render or a later step.

| Do | Expect |
|---|---|
| a `notify-feed` that exits 1 | the ask completes, the pane shows nothing about it (the notifier's feed has a null notes sink here), later rings still run |
| a `notify-feed` that sleeps 30 | the render and the next prompt are not held more than about 2 seconds; the feed is killed at its 2 second timeout |
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
- **Length.** Positive control: the journal's `ask_human` input is 600 characters, and a ring exists. A 600-character question reaches the sequence, `display-message` and feed as at most 200 characters. The cut
  follows the mask, so a secret straddling character 200 cannot leave a stub that no mask recognises; plant it at
  character 195.

## What this scenario cannot answer

- **Whether a desktop shows the notification.** The capture proves the bytes lain wrote, not that iTerm, kitty or a
  desktop daemon drew them, nor that tmux forwarded the passthrough.
- **Whether the bell is wanted at 3 in the morning.** The layer is off by default and nothing says when it should be on.
- **A `--prompt` one-shot's settle.** The record is written from the interactive ask path; run a `--prompt --non-interactive`
  chat and record whether it journals `ask_settled` and rings, since no card says it should.
