# Scenario: the cockpit surfaces (nvim + tmux)

**Round 26 is the re-check** for the round 25 fixes stated in §0 checks 9, 16 and the `--no-nvim` approval lapse line (b25-3, b25-5, b25-8: a bare `lain input` with no chat, call-led timeout lines, Ctrl-C over a draft).

**Why this one exists:** round 4 found **four** of its seven defects here — a frozen timeline, an
approval that never renders, a refusal delivered as a Lua traceback, and a view with no placeholder.
The surfaces are where lain's state becomes something a human can act on, and they have the least
automated coverage of anything in the system: a spec can assert a buffer's *content*, but only a
driver can notice that the buffer disagrees with the pane beside it.

**What it exercises:** `Frontend::Neovim` and its `Surfaces`/`Buffers`/`JournalView`/`RequestBuffer`
projections, the review flow (`/survey` → `<CR>` → `x` → `:LainReviewVerdict`), the **note rail** on
a survey of a dummy app the round writes itself (§4b — kinds, placement order, the keys, the
thread), the approval and question surfaces (the chat's one-line arrival notes and its `command>`
reader, `/approve`, `/inbox`, `lain://approval`, `:LainApprove`, `lain://inbox`, `:LainReply`), the
RPC transport's one-line-per-record contract, and the prompt composer's HUD segments.

**There is no desktop notifier any more, for any OS.** `Lain::Notify`, `--desktop` and
`LAIN_DESKTOP` were deleted in `c40ab419` (2026-09-12); round 17 proved the negative (a parked
gated call with `dunstify` on `PATH` raised nothing). Every passage here that used to drive it is
gone, and a round that finds a notification on screen has found something else.

**All four of round 4's surface defects were fixed in the 2026-08-18 chunk, and every one of them
was fixed somewhere other than where it appeared** — the frozen timeline in the RPC transport, the
unrendered approval in the (since deleted) desktop notifier, the traceback in a Lua return path, the
missing placeholder in a view's `initial`. So each section below now carries *what wrong looks
like* for the new mechanism, not just the old symptom: a symptom-only check can pass while the fix
has been reverted into a different failure.

**Cost:** cheap in model calls — most checks are RPC reads. **Piggyback it on whatever subject
scenario is already running** rather than driving a session just for it.

**Needs:** a live cockpit (`lain up`, nvim attached). Drive everything over RPC per `method.md`.

---

## 0 — Three panes, and the one the human types in

**The cockpit is three panes since round 18**, and a round that reads it as two will look for the
prompt in the wrong place. `lain up` cuts an `nvim --listen` pane, splits the `chat` pane beside
it, and splits an **input pane** beneath the chat pane. `lain up --no-nvim` drops the editor only:
the chat is still a transcript over an input pane. Each pane's tmux id is recorded as a
**session** user option, so address panes by those rather than by "whichever pane is active" —
and note the pane *count* answers nothing, since a chat over its input pane is two panes and so
is a cockpit whose human split a shell into it:

```bash
for o in @lain_editor_pane @lain_chat_pane @lain_input_pane; do
  printf '%s=%s\n' "$o" "$(tmux -L "$QA_SOCK" show-options -v -t lain-qa "$o")"
done
tmux -L "$QA_SOCK" list-panes -t lain-qa:chat -F '#{pane_id} #{pane_height} #{pane_current_command}'
```

`@lain_editor_pane` is recorded as the **empty string** under `--no-nvim`, or when the cockpit
degraded for want of the binary — recorded rather than left unset, so a window lain built says
"no editor" and only a window lain did not build says nothing at all.

Checks:

1. **Three panes exist**, and `lain up --no-nvim` in a second session gives two.
2. **The input pane is seated at a floor, not a fixed height.** It starts at 6 rows. Grow it
   (`tmux -L "$QA_SOCK" resize-pane -t <input> -y 12`) and it **stays** at 12 across a later layout change;
   shrink it below 6 and the next `window-layout-changed` puts it back to 6. In a window shorter
   than 13 rows the hook stands aside rather than squeezing the transcript away — check that by
   resizing the client small and confirming the transcript still has rows. **Detach and
   reattach**, which is the case the hook exists for: tmux hands a window's rows out afresh on
   every attach and takes them off the bottom pane first, and a 24-row terminal was measured
   leaving the input pane at ONE row with the HUD gone. The hook is on
   `window-layout-changed` and deliberately not `client-resized`, which fires before tmux's own
   redistribution. `lain up` re-arms it on a session it did not build this time, so an operator
   who upgrades with a cockpit open gets the floor without killing the session — worth checking
   once against a session started by an older binary.

   **The repro is a squeeze AND a restore, not just the squeeze, and the HUD must come back with
   no ask running and no key pressed.** Shrink the window below 13 rows, then grow it back: the
   pane comes back at or above its floor, and **not necessarily at the height the human had grown it to** (round 23
   re-drove this: grown to 12, shrunk to 6, the restore to a 50-row window left it at 20 rows, because the hook is a
   minimum and tmux hands out the rest). So the check is "at or above the floor", never "back to the grown height". The HUD row has to be repainted on that geometry
   settling by itself, with nobody typing and nothing dispatching. And an **idle** pane must
   repaint nothing at all while sitting still — a poll that redraws on the clock rather than on a
   real geometry edge is the regression this guards against, so measure bytes, not eyeballing:

   ```bash
   tmux -L "$QA_SOCK" pipe-pane -t <input> -o "cat >> $QA/records/idle-input-pane-$$.raw"   # ~10s with nothing happening
   wc -c "$QA/records/idle-input-pane-$$.raw"                                  # must read 0
   ```

   **Automated by** `spec/e2e/cockpit_approval_spec.rb`, "shows a fleet line above a you> line in an input pane at its floor height": a 24-row cockpit seats the input pane at its floor or above, with the fleet line above `you>`. **Still needs a human:** growing and shrinking the pane, the squeeze and restore, detach and reattach, the short-window stand-aside, the re-arm over an older binary's session, and the idle byte count.

3. **The HUD is in the input pane, above the prompt, and it refreshes with no keypress.** Start
   an ask that runs for a while, type a few characters into the input pane without submitting,
   and watch the header change under your draft. That is the whole reason for the split: the
   chat pane is a scrolling transcript and cannot hold a live line.
4. **The header carries the top of the fleet tree under the HUD.** Spawn two subagents and
   watch rows appear beneath the HUD line, each indented two spaces and nested a further two
   per level, in the shape `role  state  Nt  task`:

   ```
   ❄ fleet:2 inbox:0
     dev  running  2t  port the parser
       test_engineer  running  0t  write the specs
   ```

   **Two rows, then `+N more`.** Spawn a third and the last header line must read `  +1 more`
   rather than a third row — the pane is six rows and the HUD, the rows, the `+N more` and the
   prompt all have to fit, with a countdown still needing somewhere to draw.
   [`lain://status`](#1--every-view-is-alive-and-says-what-it-awaits) is where the whole tree is
   read, and §1 drives it.

   **Which two rows: running first, then the newest ended, and a child never shows without its
   parent** (round 20's B-4: the header took the first two rows of an arrival-ordered tree, so the
   newest failure sat under `+1 more`). Drive both shapes and read the header, not the tree:
   with **3 ended children, the newest failed, none running**, the two rows are the newest two and the
   last line is `  +1 more`, so the failure is on screen. With **1 running parent that has 1 running
   child, plus 2 ended siblings**, the rows are the parent and its child. **Catches B-4 returning:** an
   old success on screen with the newest `failed` row hidden under `+N more`. **A finished judge is not an ended
   row.** Under `auto`, let the judge look at 10 calls so 10 `auto_approver` children finish after a researcher
   has: the ended rows still show the researcher and none shows an `auto_approver`. A judge that is running is
   shown while it runs (it ends within 30 seconds, so look during a slow call).
5. **The header carries NO age, and that is the check.** Leave the pane untouched with a child
   running and watch it for a minute: the header must not change, and the pane must not redraw.
   An age column here would make the frame differ from itself once a second — measured at seven
   redraws in eight seconds in a real six-row pane — so the age lives in `lain://status` only.
   A header that ticks is the regression, not a feature.
6. **A long task line cannot wrap the pane.** Both surfaces clamp a drawn row to 80 terminal
   columns — the *whole* line, its lead and indent included, measured by grapheme cluster rather
   than by character — and an over-long one ends in `…`. Ask for a subagent whose prompt opens
   with a long line of CJK, 96 characters of which draw 214 columns, and confirm the row still
   occupies exactly one pane row. **Measure it rather than eyeballing it**: a lead added outside
   the clamp once put a header line at 82 columns, which looks right until the terminal is
   exactly 80 wide and it wraps. Check the same row in `lain://status` too — the clamp is
   shared, so a row that fits one surface and not the other is a finding.
7. **A task line cannot repaint the surface.** It is a model's words drawn on a terminal, so
   every cell of every row is scrubbed: newlines and tabs become spaces, then whole ANSI escape
   sequences are removed, then the control and format characters. Ask for a subagent whose task
   begins `clean\e[1A\e[2KPWNED` (send the real escape bytes) and confirm the row draws
   `cleanPWNED` — both sequences gone **whole**, with no `[1A` or `[2K` left behind as visible
   junk, and **the HUD line above it untouched**. That exact task was measured putting its own
   words on the HUD line before the scrub landed: `\e[1A` walks the cursor up a row and `\e[2K`
   erases it. A bidi override (`U+202E`) in a task must likewise not reorder the row around it,
   and a tab inside one must become a space rather than vanish — deleting it would join two
   words.
8. **Every prompt is answered in the input pane** — `you>`, `[y/N]`, `human>`, the countdown.
   Nothing is typed into the chat pane.
   **The chat pane says your side back (2026-10-09 trial fixes).** A line read at `you>` is echoed there as
   `HH:MM:SS you> <text>`, and an answered question set as `HH:MM:SS answered the agent's questions` with one indented line per answer
   (cut at 120 columns). A line typed while a model call or tool runs, with nothing asking, is echoed as `HH:MM:SS note for the agent: <text>` and
   is a note, not a held prompt. A line typed at a parked `[y/N]`, `human>` or `command>` is never a note. `greenfield-epic.md` §3.6 and
   §3.7 drive these.
9. **The pane is an ordinary command.** Kill it (`tmux -L "$QA_SOCK" kill-pane -t <input>`) and the chat stays
   alive; `lain input --name <session>` in a new pane, started in the project directory, reconnects to the same socket and is redrawn
   with the current prompt and HUD, not left blank until something changes. Started from a directory where no chat listens on the derived socket, a bare `lain input` says `no chat is listening on <socket>; input pane not adopted` and does not take the cockpit's input slot (round 25, b25-3, fixed). The socket is
   `$XDG_RUNTIME_DIR/lain/input-<project-hash>-<session>.sock` (`lain up` passes the tmux session
   name, so two cockpits on one project do not collide) and it carries **no pid**, because both
   panes derive it before either process exists. A second `lain input` on the same socket is
   *accepted*, not refused — panes are clients — so what to check there is that a line typed in
   either one reaches the chat exactly once. The refusal lives on the other side: a second
   **chat** trying to bind a socket a live chat already holds is refused by name rather than
   stealing it, while a stale file left by a dead chat is rebound.
10. **`:LainStart` exists under a config that resets `runtimepath`** (2026-10-08 trial: a lazy.nvim
    default, `performance.rtp.reset = true`, drops the `--cmd` rtp entry, and the cockpit's nvim came up
    with no `:LainStart` and said nothing). The sandbox redirects `XDG_CONFIG_HOME`, so put the
    config where the sandboxed nvim reads it, then start the cockpit:

    ```bash
    mkdir -p "$XDG_CONFIG_HOME/nvim"
    printf 'vim.opt.runtimepath = { vim.env.VIMRUNTIME }\n' > "$XDG_CONFIG_HOME/nvim/init.lua"
    lain up    # then, once the editor pane is up:
    nvim --server "$S" --remote-expr "exists(':LainStart')"     # must read 2
    nvim --server "$S" --remote-expr "execute('messages')" | tail -3   # ends with the attached line (§3)
    ```

    Repeat once with the file removed (a clean config) and the layout must open the same way.
    *Wrong looks like:* `0` from `exists`, or a cockpit whose nvim pane stays an empty buffer while the
    chat says it attached. The case where the plugin directory itself is missing (nvim prints
    `lain: the nvim plugin is not at <path>, so :LainStart is unavailable`, and `lain up` warns first)
    needs an install without `plugin/nvim`; it is not driven here, and `spec/plugin/nvim_plugin_spec.rb`
    holds it.
11. **The session has mouse on and the server has extended keys on, and the user's globals did not move.**
    Record `tmux -L "$QA_SOCK" show-options -g mouse` before `lain up`, then after:

    ```bash
    tmux -L "$QA_SOCK" show-options -t lain-qa mouse          # on
    tmux -L "$QA_SOCK" show-options -s extended-keys       # on
    tmux -L "$QA_SOCK" show-options -g mouse               # unchanged from the recorded value
    ```

    The option is necessary but not sufficient for Shift+Enter (check 12): the line editor also writes `\e[>4;1m` when a
    prompt read opens and `\e[>4;0m` when it ends. A first `lain up` against a fresh server prints a warning saying it set the server option
    `extended-keys` (server-wide, not per session); a server already on `always` is left on `always`
    with no warning. With mouse on, the wheel over the chat pane scrolls its history, and **native text
    selection needs Shift-drag** (tmux owns the plain drag). Record that last sentence as expected, not
    as a finding.
12. **Shift+Enter and Backspace at every prompt.** At `you>` in the input pane, type `ab`, send Shift+Enter
    (`tmux -L "$QA_SOCK" send-keys -t <input> S-Enter`; if your tmux does not translate it, send the bytes
    `\e[13;2u`, and `\e[27;2;13~` for the xterm modifyOtherKeys form), type `cd` and press Enter: the
    one submitted line is `ab` newline `cd`, and a plain Enter submits. Read it back from the journal: the user turn's `content` text block (`method.md`'s turn reduction prints `role/text`) holds `ab\ncd`. Type `ab`, Shift+Enter, then
    Backspace: the buffer is `ab` on one line again. Repeat at `command>` (park an approval, §5; **round 23 KEY-1, fixed**: Shift+Enter used to submit there and at `you>` unless tmux `extended-keys` was `always`, because nothing asked the terminal for the key, and now every prompt read does, `command>` included) and, in a
    `--no-nvim` chat, at `human>`. The hint row `Shift+Enter or Alt+Enter for a new line` is drawn once
    per `you>` prompt, not at the other two. Check the reset too: after the chat exits, a plain shell in the same tmux pane gets `\r` for Enter (`cat -v`, then Enter, shows `^M`). Alt+Enter does the same as Shift+Enter (**round 23, fixed in the line editor**: it also inserts a newline in vi command mode, after `/mode +vi` and Escape; before, `ESC CR` submitted the half-typed line there, `cd` became a held prompt and the pane kept drawing `ab` and `^[`). Do it once from a
    real keyboard, since a synthesized sequence only proves the binding.
    *Wrong looks like:* Shift+Enter submitting a half-typed line, or Backspace at the start of an empty
    second line doing nothing.
    *Observation, not a check:* after Alt+b or Alt+f the next typed character was not inserted in the one
    real pty that was tried, with or without the new bindings. Record whether it still happens.
13. **The chat pane writes to normal scrollback, and the history stays reachable.** With an input
    pane attached the chat pane does not enter the alternate screen. Take 3 or 4 turns, then:

    ```bash
    tmux -L "$QA_SOCK" capture-pane -p -t <chat> -S -200 | wc -l      # more lines than the pane has rows
    ```

    and scroll with the mouse wheel. To see the control sequence itself, `tmux -L "$QA_SOCK" pipe-pane -t <chat> -o
    "cat >> $QA/records/chat-$$.raw"` before a restart of the chat, then `grep -c $'\e\\[?1049h'` on it
    must read 0. A plain `lain chat` with no input pane **does** use the alternate screen, so the
    same grep there reads 1 or more, and that is correct.
    *Wrong looks like:* `capture-pane` returning only the visible screen, a wheel that does nothing, or
    history that vanishes when the chat exits. An older version of this scenario expected the
    alternate screen in the cockpit chat; it no longer holds.
14. **Prose wraps at word boundaries, after a resize.** `tmux -L "$QA_SOCK" resize-pane -t <chat> -x 60`, then take a
    turn whose answer is a long paragraph, and make the model print a line that has leading
    indentation. No word is split across 2 rows except one longer than the pane, a wrapped
    indented line keeps its indent on the continuation, and growing the pane back wraps the next turn
    at the new width. A line inside a fenced code block is **not** wrapped (the terminal does it).
    Tool output chunks are not word-wrapped either, since breaking them would add newlines the command did not
    write. In a non-tty capture (`tmux -L "$QA_SOCK" pipe-pane` output read as a file, or `lain chat < /dev/null`
    piped to a file) nothing is wrapped.
    *Wrong looks like:* `configur` on one row and `ation` on the next, or a code line cut mid-token.
15. **The header redraws when its row count changes, and a draft is never clobbered.** With a child
    running and nothing typed, spawn a subagent so the fleet grows by a row: the header goes from 1 row to 2 in
    place, and exactly 2 header rows are on screen (count them with `capture-pane -p -t <input>`, not by
    eye). When the fleet shrinks back, exactly 1 header row is on screen and no stale row is left under it. Then
    type `abc` without sending it and change the fleet again: `abc` stays on the input row and is what Enter
    sends, and the new header is drawn whole at the next prompt. A header drawn twice, or a stale fleet row
    left on screen, is the finding.
16. **While a child runs and the pane is idle, typing goes into a draft the pane keeps.** Start an ask that runs
    for 20 seconds or more, with no prompt parked. Type `abc` at the input row. The characters stay on the input
    row, and a header redraw (spawn a child so the row count changes) leaves `abc` where it was and redraws
    the header above it. Then each of these:
    - **Ctrl-C discards the draft.** (Round 25, b25-8, fixed by T16.) Ctrl-C over a draft clears it and sends nothing:
      no signal frame reaches the chat, so no close countdown opens and the ask keeps running. The input row is
      empty. A second Ctrl-C with nothing typed is the ordinary interrupt (`--grace`, the countdown above); answer
      that countdown with `c` if you drive it. Round 26 re-checks both halves.
    - **Tab goes into the draft** as a tab character; it does not trigger completion or move focus.
    - **Ctrl-Z** in a cockpit input pane does not stop the process (it is exec'd with no shell, so there is no `fg`);
      check only that the pane keeps working.
    - **Ctrl-C over a line typed at a drawn `you>` and at `command>`:** the line must clear and nothing be forwarded.
      Round 26 found both end the cockpit (b26-1); only a draft typed while no prompt is drawn clears safely.
    - **A pasted multi-line draft is sent as one line.** Paste 3 lines in one go, then press Enter: the chat receives
      one line holding all 3, not 3 prompts. A bracketed paste and a plain one both do this.
    - **A very long line is sent whole.** A draft of more than 4,095 bytes arrives complete, with no cut and no
      notice.
    Read the journal for the sent lines, not the screen. A character typed in this state that is echoed by the
    terminal instead of drawn by the pane (the draft shows twice), or a draft lost on a redraw, is the finding.

**Three round-22 behaviours of the input pane, each a quick look.** The pane redraws its header only where
it is: after an answered `[y/N]` nothing is written over the echoed answer, and the next prompt draws the
header whole. `lain input` takes over the cockpit's input-pane slot, deriving the session from `TMUX_PANE`
(not from `--name`, which defaults to `chat`), so a second pane started by hand adopts the recorded slot of
**its own** cockpit. And a long line typed while an ask is running is sent whole: a line of more than 4,095
bytes (the terminal's canonical limit, which used to cut it and hold it with a notice) reaches the chat in full
with no 4095-byte cut and no notice, and a 200-byte line mid-ask is held as typeahead as before.

**Stopping an ask, and keeping the session.** Two gestures, one outcome:

- `/stop` typed at whatever prompt the run parked on — it is lifted off the input rail before the
  command registry sees it, so it works from a `[y/N]` or a `human>` and not only from `you>`.
- Ctrl-C, then `s` at the countdown. (`c` cancels the countdown, `w` extends it, `r` waits for
  responses.) There is no idle countdown: a Ctrl-C at an idle `you>` **ends the chat**
  (`docs/commands.md`, the `--grace` row). The countdown is for a run in flight, or for a
  `[y/N]` that took the terminal from an idle `you>`.

**Drive the countdown from a prompt that already had a read open** — a Ctrl-C at a parked
`[y/N]` is exactly that shape, and it is where the pane's countdown used to misbehave. The
window now takes the terminal from the line editor before it switches the mode, waiting a
bounded couple of seconds for the open read to unwind; without that, the editor put the mode it
found back a moment later and every offered key echoed and was read as a **line** instead of
firing. So: park an approval, Ctrl-C, and confirm a single `s` stops the ask with **no echo and
no Enter** needed. If the editor will not let go in time the window degrades rather than dying,
and says so — a sentence telling you a key may be swallowed or arrive as text, and to press it
again. That sentence appearing routinely is a finding; the keys silently doing nothing is the
older one.

And the countdown must take back the row it draws on rather than appending to whatever the
editor left: a header printed after a `you> ` once rendered as `you> ❄ fleet:4 inbox:0` on one
line and cost the pane a row of its six. Read the pane, not just the journal.

Either one must leave the prompt at `you>` **in the same session**: the journal gains a
`run_interrupted` with `"reason": "stopped"` and **no** `session_closed`, and the next thing you
ask runs on the same chain. With nothing running, `/stop` answers *"no ask is running -- /stop at
the prompt it parks on, or s at a countdown"* and changes nothing.

**Automated by** `spec/e2e/stop_while_busy_spec.rb`, "stops an ask parked on an approval when /stop is typed, without running the call or closing the session" and "consumes the question when an ask parked on it is stopped": `/stop` typed in the input pane at a parked approval, and at a parked question, journals `run_interrupted` with `reason: stopped` and brings `you>` back; at the approval it also writes no `session_closed` and runs nothing. **Still needs a human:** no `session_closed` after a stop at a parked question, Ctrl-C and `s` at the countdown (no echo, no Enter), the degraded-window sentence, the countdown taking back its row, `/stop` with nothing running, and the next ask running on the same chain.

**That is no longer the whole story once Supervisor-adopted actors are running at `you>`.** An
adopted actor is a sibling of every ask, not a captive of one, so it keeps running with nothing
parked at `you>` to answer for it: `/stop` typed there now reads the fleet and, if it finds any
running, stops each by hand and answers `no ask was running, but stopped <role> (<worker_id>)`
(joined by commas for more than one). A **one-shot** child, a docent above all, is now reached too (round 20's G-3, which found `/stop`
answering `no ask is running` beside a running docent): the `Supervisor` tracks one-shot children, so
`/stop` at `you>` beside a docent answering a thread answers `no ask was running, but stopped <role>
(<worker_id>)`, the docent's task stops, and its completion record is journaled. **Catches G-3
returning:** the plain `"no ask is running"` sentence while `lain://status` shows the docent running.
`survey.md` drives the docent half; check here only that a **closing** session (`/quit` with a docent
running) journals the docent's completion **before** `session_closed`.

**A line typed while an ask is in flight reaches the chat at once** (round 20's C-2 and A-1: the input
pane stopped drawing while nothing was published, so a typed `/stop` sat as terminal typeahead and only
arrived at the next `you>`). Start an ask that will run for 20 seconds or more, type `/stop` and Enter in the
**input pane** while it runs, and read the journal: `run_interrupted` with `reason: stopped` lands before
the ask would have finished. Then type `hello` and Enter mid-ask: it is not lost and not doubled, and is
the next prompt exactly once. **Catches C-2 returning:** `/stop` acting only after the ask ended.

**Automated by** `spec/e2e/stop_while_busy_spec.rb`, "reaches the chat at once, before a model that never answers is released" and "holds lines typed mid-ask and sends them once each, in order, as the next prompts": a stand-in that holds the model open replaces the 20-second ask, and the journal and the requests it saw carry both checks. Nothing in this paragraph needs a human.

**What wrong looks like:** a `session_closed` record beside the stop; the prompt coming back as a
fresh session; `/stop` answered by the model as prose (the rail did not intercept it, which is
correct only when no ask was running); or a `run_interrupted` with no `reason`, or with
`interrupted` where the human pressed `s`.

## 1 — Every view is alive, and says what it awaits

`Surfaces#prime`'s own docstring states the principle: prime every view so "an idle session that
shows no buffers reads as 'broken' (the first manual verification pass stumbled exactly there)".

**The primed set is eight buffers, and it is not the same as the set of `lain://` names.** At attach
`Surfaces#prime` creates `journal timeline workspace diff inbox request status approval`.
`lain://review` is **not** among them — nothing renders it until a `/survey` runs — so iterating it
here reads as a missing buffer every time and teaches a driver to ignore the one check this section
is:

```bash
S=$XDG_RUNTIME_DIR/lain/nvim-<hash>.sock
nvim --server "$S" --remote-expr "join(map(getbufinfo({'buflisted':0}), {_,b -> b.name.' ('.b.linecount.')'}), '\n')"
for b in journal timeline workspace diff inbox request status approval; do
  echo "== lain://$b =="; nvim --server "$S" --remote-expr "join(getbufline(bufnr('lain://$b'), 1, 5), '\n')"
done
```

Expected placeholders, all eight. Seven of them were measured round 9; **`lain://status` has
still never been driven here**, so record what it actually holds rather than confirming the row
below — and note that round 18 changed what its fleet half draws (below).
**Note `diff` is plural and `request` is singular** — that is not a typo here, and a driver grepping
for one string across both will miss:

| buffer | at rest |
|---|---|
| `lain://journal` | `(no streamed tool output yet)` — since T18; a bare empty line is the regression |
| `lain://timeline` | `(no turns yet)` |
| `lain://workspace` | `(no reminders)` |
| `lain://diff` | `(no requests yet)` — plural |
| `lain://inbox` | `(no questions pending)` |
| `lain://request` | `(no request yet)` — singular |
| `lain://status` | `# lain status` / `no epic is mounted -- start the chat with --epic SLUG to see one here`, then `## fleet` / `(nothing running)` |
| `lain://approval` | `(no approvals pending)` |

**`lain://status` primes in every chat, epic or not, and that is the point.** The `no epic is mounted` row is for a project
with no epic in its epic home. If the home holds exactly one (the model's own `epic_write` can make one mid-round), a chat
started with no `--epic` mounts it on its own and the buffer reads `# epic \`<slug>\`` with its issues instead, so clear the
home or name a different one before checking the placeholder. Its epic half is a
Null (`StatusView::Unmounted`) that answers with the sentence above, so a chat outside an epic gets
a buffer explaining how to get one rather than no buffer at all — the same reasoning that put
`lain://approval` in this loop. Both halves are always drawn: the epic lines, a blank, then the
fleet listing. A `lain://status` that is **absent** in a non-epic chat is the regression, and it is
the one this section would previously have called correct. It is created by the runtime with
filetype `markdown` (the only read-only markdown buffer — it carries a mermaid fence) and takes no
window of its own.

**`lain://approval` is the newest of the eight and the reason this loop was corrected.** It used to
be absent until the first pending parked, which made "the buffer is not there" and "there is nothing
pending" indistinguishable — and `method.md`'s rule about reading it before answering a blind
approval depended on telling them apart. It is now primed at attach holding `(no approvals pending)`,
and because the runtime opens its window only when it has rows, **priming it takes no window**:
`getbufinfo` must find it while the tab layout is unchanged. A `lain://approval` window on screen at
rest is the over-correction to watch for.

It is also deliberately *not* in the runtime's `LainAttach` buffers payload — the runtime creates it
itself — so a config iterating that payload sees seven names (`00_constants.lua`'s `BUFFERS`, which
`lain://status` **is** in). Seven there and eight here is correct, not a discrepancy.

**Dynamic buffers are not in the eight, and a count taken later reads higher.** `lain://epic/<slug>/<doc>` is created when
the chat first writes an epic document (2026-10-09 trial fixes), like `lain://review/OLD/<path>`, so it is absent from this
loop at attach and `getbufinfo` lists one more per document written afterwards. That is an addition, not a stray buffer. It
is read-only, markdown, opens in a split below without taking focus, and a closed window stays closed on a later write
(`greenfield-epic.md` §7.13 drives it).

### `lain://status`'s fleet half is a tree, and it is the only surface that renders the whole one

Round 18 replaced the bare digest listing under `## fleet`. What is drawn now is a **nested
markdown list**, one row per child, indented under the parent it was spawned from:

```
## fleet

- dev  running  2t  3m  port the parser
  - test_engineer  running  0t  1m  write the specs
```

Six things to drive, in one session with a subagent that itself spawns:

1. **A grandchild is nested.** Ask for a subagent that spawns a subagent, and confirm the third
   row is indented two levels. The parent edge is the head a child reports, not anything in the
   `:spawn` record, so this is the check that the two-record fold actually places branches.
2. **No digest is drawn.** A row names the role, the state, the turn count, the age and the task
   — not the spawn address. That is deliberate: the address is what
   [`lain watch`](../../../docs/commands.md#lain-watch) takes, and seventy columns of it is not
   what a human reads a fleet for. A digest back in a row is a regression.
3. **The turn count moves while the child works**, without the row being rewritten from scratch:
   the dispatch record carries the role and the task, each later one carries only the turns and
   the head, and a reader folds them by spawn. A row that loses its task line on the child's
   second turn is that fold taking a nil it should have ignored.
4. **`lain://status` shows the AGE and the input pane's header does not.** Read both at once
   with a child running. This is not an inconsistency to file — the pane's header is the frame
   the chat publishes and an age would cost it a redraw a second (§0), while nvim rewrites the
   whole buffer anyway. Both rows must otherwise be **identical in their columns**, because both
   are drawn from the same row object; a column present in one and missing from the other is
   the real finding.
5. **An ended child stays visible, and does not accumulate for ever.** A child that failed or
   was stopped keeps its row, with its state reading `failed` or `stopped` rather than
   `running` — vanishing from the surface that was watching it is the thing this exists to
   prevent. But only the most recent handful of ended rows are kept; a long session's whole
   spawn history in the struct would be a growing write every turn.
6. **The spawn record is byte-identical to before.** This is the ruling the whole tree rests on:
   nothing about the fleet view was added to the `:spawn` body, because its digest is an address
   bench arms join on and `lain watch` follows. Compare a `:spawn` body's keys against what
   `subagents-and-backends.md` §2 documents — `task`, `prefix`, `posture`, `only`,
   `spawned_from` — and confirm no role, task line or worker key joined them. The fleet's own
   facts ride in separate `child_progress` records:

   ```bash
   ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next
     next unless r["type"]=="child_progress"
     puts [r["spawn"][0,12], r["role"], r["turns"], r["head"].to_s[0,12], r["task_line"]].join("\t")}' "$LAIN_QA_JOURNAL"
   ```

   The first record for a spawn carries the role and the task line; the rest carry only the turn
   count and the head. A `worker` key is on the record's shape but **nothing renders it yet**,
   and the in-place lease mints none, so expect it nil — its absence from both surfaces is
   correct, not a gap.

That view is still named misleadingly: it renders `Telemetry::ToolOutput` (streamed tool bytes)
only, never the NDJSON session journal, and a rename was proposed rather than taken because
`:h lain-runtime-commands` documents the name. Confirm it populates the moment a streaming tool runs
and reverts to nothing-new otherwise — **and specifically that the placeholder does not get stuck as
a permanent first line once real output starts appending under it.** The append path decides
replace-vs-append off a buffer-local flag rather than off the buffer's text, precisely so it cannot;
a `(no streamed tool output yet)` line sitting above real `cargo` output is that going wrong.

## 2 — Staleness: which views actually track the session

The cheap probe, run before and after a turn:

```bash
for b in timeline request diff journal status; do
  printf '%s=%s ' "$b" "$(nvim --server "$S" --remote-expr "getbufinfo('lain://$b')[0].linecount")"
done; echo
```

Drive **two or more separate asks**, not one. Round 4's F17 is precisely a view that renders during
the first ask and then never updates again — invisible if you only ever look after one prompt.

Cross-check against the journal, which is the ground truth:

```bash
ruby -rjson -e 'n=0; ARGF.each_line{|l| r=JSON.parse(l) rescue next; n+=1 if r["type"]=="turn_usage"}; puts "turn_usage=#{n}"' "$JOURNAL"
```

`lain://timeline` renders on `Telemetry::TurnUsage`; `lain://request` and `lain://diff` on
`Telemetry::RequestSent`. If one moves and the other does not while both event types are being
journaled, that is the finding — and it is not the drain thread dying, because a dead drain stops
all of them.

**`lain://status` is the one view that redraws on nothing.** It refolds on four types —
`Telemetry::TurnUsage`, `Epic::IssueTransition`, `Epic::StageTransition`, `Approval::GateDecision` —
and updates its fleet half on any `:spawn` or `:message` kind, but `StatusView#update` **returns nil
when the composed text is unchanged**, so a refold that found no movement posts nothing. A flat
linecount across two asks is therefore correct here and a finding everywhere else in this loop:
judge it by whether the buffer moves when the *epic* moves, not when a turn does. Drive it from
§11 of `epic-tier.md` — a `/implement-epic` run walking an issue from pending to `in_flight` to
`done` is the trigger that must show. Two failures to tell apart: a view that never redraws (the
refold predicate missing a type) and one that redraws every turn with identical text (the nil-return
lost, which reinstates the 141 ms full refold this design exists to avoid).

## 3 — The attach message

The nvim pane's message line reads `lain: not attached yet -- layout opens when 'lain chat --nvim'
attaches` at startup. Since T18 a successful attach **supersedes** it:

    lain: attached -- layout opened

Read `:messages`, not just the pane — the notice is a `vim.notify`, and the message line holds only
the last one:

```bash
nvim --server "$S" --remote-expr "execute('messages')" | tail -4
```

Expected: the `not attached yet` line, then the `attached` line under it, in that order. **What
wrong looks like:** `not attached yet` as the *last* message while `lain://request` is live in the
window beside it. A surface contradicting the buffers next to it is the first thing a reader
concludes the cockpit is broken from — and note the failure is one-directional, so a driver who
only ever looks after attach will see a correct-looking screen either way. Look at the order.

## 4 — The review flow

`/survey ./lib` — a **subdirectory** survey specifically; the project-root case behaves differently
and is what hid an earlier defect.

Expected banner: `walk it in lain://review; <CR> opens a row beside you, <C-w>l reaches
the file where :LainNote annotates, :LainReviewVerdict approve hands it back`.

The walk is named in the banner because `<CR>` lands the cursor in the **sidebar**, not in the
file -- and `:LainNote` reads the current buffer, so from the sidebar it correctly refuses.

**The motion count depends on the SOURCE, and the banner adapts -- round 14 measured both.** A
**changeset** has an old side, so the slots are sidebar, OLD, NEW: three windows, and the banner
says `<C-w>l<C-w>l` because a single motion reaches only the history side. A **survey** has no old
side (`changeset-review.md` says so in its own opening), so the slots are sidebar, NEW: two windows,
and the banner correctly says one `<C-w>l`. This section's own example is `/survey ./lib`, so
following it literally over a survey counts one window too many. Read the banner the run printed and
`winnr("$")`, rather than either number quoted here. **A re-survey while a previous thread window
is still open prints one more**: the old thread window stays open (round 22's B-10), so close it
(`:only` on the review tab, or `:close` on the thread window) before reading `winnr("$")`, or read
the count against the windows you can see.

Then, over RPC, verifying focus at every step:

```bash
nvim --server "$S" --remote-send ':tabnext 3<CR>'    # the review tab
nvim --server "$S" --remote-send ':1wincmd w<CR>'    # the sidebar
nvim --server "$S" --remote-expr 'bufname()'         # MUST print lain://review
nvim --server "$S" --remote-send '2G'
nvim --server "$S" --remote-send '<CR>'              # opens sidebar | NEW -- a survey has no old side
nvim --server "$S" --remote-expr 'winnr("$")'        # MUST print 2, not 3 -- on a FIRST survey
```

After `<CR>` the tab holds **two** windows, sidebar and NEW, because this round is a survey:
`Source::Corpus#sides` (`review/source/corpus.rb:320`) never claims the old slot, so `47_diff.lua`
builds no OLD window for it (`sided = review_panes.holds("old")` at `:722` is false here, which
leaves `old_win` `nil` and hands `pair` the one-element `{ new_win }` at `:733-744`). **Focus is
TAKEN to the sidebar** (T10, round-7 fix for F34), even from another tab — it does not follow the
cursor into NEW. **The NEW window is modifiable**, not a `nomodifiable` copy: `47_diff.lua:188` sets
its `buftype` conditionally (`filereadable(absolute) == 1 and "" or "nowrite"`) — `""` when
reviewing a live file, so LSP and treesitter attach, or `nowrite` when the file was deleted, which
blocks `:w` but not editing. Either way `x` there is vim's delete-character and will edit the
human's source, not mark the row. Stay on window 1 to press `x`.

Check, in order:

- `x` on an opened row redraws `[ ]` → `[x]` **and** acknowledges, naming the ROW rather than a
  content hash: `lain: marked reviewed: 6 hunk(s) of src/main.rs`. (The older
  `lain: unit-content-v1:<key>… is now reviewed` is what round 7's F38 fixed — one message per row
  instead of one per unit, of which only the last survived the message line. A driver still expecting
  the digest form will file the fix as a regression; verified live, round 8.)
- `x` on a row nothing has opened refuses **by name** and leaves the row unmarked:
  `lain: lain://review line 3 names lib/version.rb, which nothing has read -- open it with <CR> first`.
- `x` on a row with no hunks (an empty file) refuses cleanly:
  `lain: no hunk on lain://review line 1 -- nothing on that row can be marked`.
- `:LainReviewVerdict approve` over a **partially** reviewed changeset refuses, naming the
  unreviewed file and the remedy.

**If you drove §4b first, the verdict refuses over the BLOCKER instead, and that is not a
regression.** Round 9 hit this and it is worth knowing before you file: a `blocker` note is the one
kind a verdict policy reads, so with one placed the refusal is about the blocker rather than about
unreviewed files, and it is shorter than the 225-character partial refusal quoted below:

    lain: approve is refused over 1 blocker nobody has answered: ../tally/lib/tally.rb:2 (new)
    -- answer each one with a note on that same line, which is what resolves it

Prefer driving it this way round when you can: it is the only end-to-end demonstration that
§4b's `blocker` kind actually reaches the policy, rather than merely being journalled with the
right `kind`. Answering it with a note on the same line resolves it and the approve then lands, so
the pair is one check, not two. Mark every row reviewed **as well** if you want the partial-refusal
wording itself — both refusals exist and they are different sentences.
- **`:LainReviewVerdict approve` over a blocker drawn but not handed back refuses, naming it** (round 20's
  B-2: approve settled over an un-handed-back blocker, because the verdict policy reads only journaled
  `annotation_placed`). Place a blocker with `<leader>Lb` and do **not** press `<leader>LN`, then run
  `:LainReviewVerdict approve`. **PASS:** `lain: blocker not handed back -- :LainNoteDone first: <file>:<line>`
  and **no `review_verdict` journaled**; after `<leader>LN` the same approve is sent. **Catches B-2
  returning:** a `review_verdict` record for a review whose blocker exists only in the buffer.
- `:LainReviewVerdict approve` over a fully reviewed one acknowledges — `lain: this review is
  settled: approve` — **and** journals `review_verdict` with its `changeset_digest`. Check both;
  a version of this shipped that journalled correctly and said nothing.

**Note how each refusal is DELIVERED, not just what it says.** Round 4's F22 is a refusal with
excellent text arriving as a Lua error plus a stack traceback plus a blocking `Press ENTER` modal,
while a sibling refusal in the same feature arrived as a clean `lain:` line. Read `:messages` — a
modal-delivered refusal scrolls away and `capture-pane` will not show it:

```bash
nvim --server "$S" --remote-expr "execute('messages')"
```

**T16 fixed the delivery at the two sites that lacked it** — `:LainReviewVerdict` (partially
reviewed changeset) and `:LainNoteDone` — by answering through the same refusal channel
`:LainReviewDone` already used and *returning* rather than re-raising. So drive both and check
three things, in this order:

1. the sentence is there, prefixed `lain: `, and names the file and the remedy;
2. **no `stack traceback:` anywhere in `:messages`** — that is the whole regression signal;
3. the editor is not blocked: `nvim --server "$S" --remote-expr "nvim_get_mode()"` must not report
   `blocking = true`.

**The residual was exact and measured, and it is NOT avoided by the bench's sizing -- round 5
corrected that.** T5 has since made the rail itself width-aware, so step 3 above is now a real
assertion rather than a known-failing one: `_G.__lain.review_refused` records the whole sentence in
`:messages` and displays one line that fits. **A `blocking = true` here is now a finding, not a
residual.**

**Three axes, not one**, and the two beyond width are what to remember when driving this by hand.
A refusal can outgrow the message area by CELLS (too wide for one line), by BREAKS (`nvim_echo`
renders a newline as a line break, so a 53-cell two-liner paged just as reliably as a 225-character
sentence), or by HEIGHT (more lines than the editor has rows). The first two raise the hit-enter
prompt; the third raises `-- More --`, which reports `mode = "rm"` and is a *different* prompt under
a *different* option, so a check that only looks for the first will miss it.

All three are reachable the same way: `CLI::HumanReplies` puts a rescued exception's message straight
onto this rail, and a Ruby `ScriptError#message` is five lines. The rail folds breaks onto one
displayed line (` / ` between them) before measuring cells, and suppresses both prompts while it
writes the unfolded original to `:messages`. **So drive a multi-line and a TALL refusal too**, not
only a long one:

```bash
nvim --server "$S" --remote-expr "luaeval('_G.__lain.review_refused(\"a\nb\")')"
nvim --server "$S" --remote-expr "nvim_get_mode()"     # must not report blocking = true
nvim --server "$S" --remote-expr "execute('messages')" # must hold BOTH lines, unfolded

# the tall one -- more lines than the pane has rows, so `-- More --` would fire
nvim --server "$S" --remote-expr \
  "luaeval('_G.__lain.review_refused(table.concat(vim.fn.range(1, 60), \"\\n\"))')"
nvim --server "$S" --remote-expr "nvim_get_mode()"     # must report neither "r" nor "rm"
```

If `nvim_get_mode` ever reports `mode = "rm"` here, read the pane with tmux (it works while
blocked) and note that Enter may not clear it -- at 60 lines in a 20-row pane, twenty `<CR>`s
did not.

**nvim 0.11 is the stated minimum, so all three checks apply unconditionally — and a truncated
`:messages` is a regression, not a documented degrade.** The rail suppresses the hit-enter prompt by
swapping `'messagesopt'`'s `hit-enter` item for `wait:0` while it writes the unfolded sentence to
`:messages`, and `'messagesopt'` arrived in **0.11**. The old version probe
(`vim.fn.exists("&messagesopt")`) and its 0.10 degrade are both gone; `README.md` states the
requirement instead. Record `nvim --version` anyway — an editor below the minimum makes every
reading in this file untrustworthy, not just this one.

Every refusal lain itself ships is inside the 80-column bar
(`spec/refusal_width_discipline_spec.rb`), so the folding path is reachable in practice only through
a sentence carrying an unbounded interpolated field — a quoted `Lain::Error#message`, a path, a
docent's exception. Which is exactly what the `:LainReviewVerdict` partial refusal below is.

**`v:echospace`, not `&columns`, is the ceiling — and nvim never gets the tmux server's width.**
'showcmd' reserves eleven cells plus one in the last screen line, so the pane width minus twelve is
what binds. Measured twice, on two different pane splits, and the formula holds:

| | round 5 | round 9 |
|---|---|---|
| tmux server / window — **nvim never gets this** | 220 | 220 |
| the nvim pane (`lain up` splits it with chat) | 110 | 100 |
| **the message area, `v:echospace` — this is what binds** | **98** | **88** |
| the review tab's three windows — `nvim_echo` never reads a window | 40 / 32 / 36 | — |

Below that width a message is echoed and nothing happens; above it, before T5, the modal fired every
time. Sizing policy is not the mechanism: a short refusal (`lain: no hunk on lain://review line 1
...`) never blocked at either width, while round 9's 158-character blocker refusal was middle-elided
to fit with the full sentence kept in `:messages`.

**And the modal blocks the RPC, not just the keyboard** -- which is why it was worth fixing, and is
the recovery to know if one ever fires again. `nvim --server "$S" --remote-expr "execute('messages')"`
HANGS while the prompt is up (round 5 measured a full 2-minute timeout), so the documented recovery
paths -- reading `lain://approval`, driving `:LainApprove` -- are unavailable exactly when a refusal
is on screen. Read the pane with tmux instead, which works while blocked, and clear it by sending
Enter to the nvim PANE:

```bash
tmux -L "$QA_SOCK" capture-pane -p -t "$NVPANE" | grep -v '^$' | tail -4   # reads while blocked
tmux -L "$QA_SOCK" send-keys -t "$NVPANE" Enter                            # dismisses it
```

A traceback, by contrast, is always a finding.

**The stale-stamp step can no longer be driven by hand.** Back-to-back `x` presses both land; the
redraw is prompt enough that the window is unreachable from tmux. Drive it through the RPC with a
stale `lain_view_generation`, or drop the step — do not record "could not reproduce" as a pass.

## 4b — Notes on a survey, on a tree you control

**Why this is separate from §4, and why it is not `./lib`.** §4 surveys lain's own subtree, which is
right for what it asks — refusals, marks, the verdict — and wrong for this: a note is anchored to
`(side, revision, path, line)` and its whole worth is that the anchor still names the same code when
it comes back. Against a tree that changes under you, "the note landed on line 12" is not a check
anybody can repeat. So this section owns a **dummy app** small enough to state in full, and the
assertions are exact line numbers and exact text.

**It is also the only place the note rail is driven at all.** §4 mentions `:LainNote` in the banner
and `:LainNoteDone` in the delivery check, and never places one. Everything below — the kinds, the
placement ORDER, the keys, the thread — has specs on both sides and no driver.

### The subject

Four files, no build step, no dependencies. Write it fresh per round, outside the project, so
nothing in it is a fixture another scenario has already moved:

```bash
APP="$(mktemp -d)/tally"; mkdir -p "$APP/lib" "$APP/bin"
cat > "$APP/lib/tally.rb" <<'RB'
class Tally
  def initialize = @counts = Hash.new(0)

  def add(word)
    @counts[word.downcase] += 1
  end

  def top(n = 3)
    @counts.sort_by { |word, count| [-count, word] }.first(n)
  end
end
RB
printf 'require_relative "../lib/tally"
' > "$APP/bin/tally"
printf '# tally

Counts words.
' > "$APP/README.md"
printf 'source "https://rubygems.org"
' > "$APP/Gemfile"
```

`lib/tally.rb` is 11 lines and every one of them is addressable, which is the point: an anchor
assertion here is a line number a reader can check against this document.

### Driving it

`/survey <app>` from the chat pane — an ABSOLUTE path, so this exercises the case `/survey .` does
not: `named_from:` is the chat's cwd, not the surveyed tree, and a row named from the wrong root
opens an empty buffer for a file that exists. **A row that opens empty is the finding**, not a
missing file.

Expected: four files at cumulative scope, and the banner naming `lain://review`.

Then, from the sidebar (window 1 of the review tab, per §4's focus discipline):

```bash
nvim --server "$S" --remote-send ':1wincmd w<CR>'
nvim --server "$S" --remote-expr 'search("tally.rb")'   # the row, by name, never by line
nvim --server "$S" --remote-send '<CR>'                 # opens sidebar | NEW -- a survey has no old side
nvim --server "$S" --remote-expr 'winnr("$")'           # MUST print 2 -- read this and the banner
                                                         # above, not a fixed motion count
```

**There is no OLD window here, not an empty one — this is §4's two-window case, not its three.** A
corpus's every row is a fixed `old_start`/`old_count` of `0,0` (`review/source/corpus.rb:35,88-89`),
so there is nothing to diff against, and `Source::Corpus#sides` (`:320`) never claims the old slot in
the first place. `47_diff.lua` only ever builds a window for a slot the round asked for
(`sided = review_panes.holds("old")` at `:722`; a `nil` `old_win` and the one-element `pair` at
`:733-744` — the identical mechanism §4 measures), so there is nothing sitting empty beside the
sidebar to note and move past. Sidebar and NEW are the whole tab.

### The checks

Place notes from the NEW side, with the cursor on a stated line, and check the anchor that comes
back — not just that something came back:

- `<leader>Ln` on line 5 (`@counts[word.downcase] += 1`) pre-fills `:LainNote note ` on the cmdline
  and **leaves it open**. The cmdline is the assertion: `nvim_get_mode()` reports `c`. A key that
  fired the command outright would have filed an empty note, which `:LainNote` refuses — so a pass
  here looks like a refusal and is not one.
- Finish it (`downcase loses the original`, `<CR>`). An inline marker `● note` appears
  **right-aligned**, and the words are NOT in the margin.
- `<leader>Lq` on line 9 (`sort_by`), text `is the tie-break intentional?` — marker reads
  `● question`.
- `<leader>Lb` on line 2, text `no frozen_string_literal` — marker reads `● blocker`. Check this
  kind specifically: it is the only one a verdict policy reads, and a `blocker` that arrived as a
  `note` is the silent failure the kind-is-required rule exists to prevent.
- **Then place a fourth on line 3, and hand back.** `<leader>LN` (`:LainNoteDone`). The payload must
  arrive in **PLACEMENT** order — 5, 9, 2, 3 — and not in positional order (2, 3, 5, 9). Positional
  is what `nvim_buf_get_extmarks` answers natively; it is tidy, plausible and wrong, and no
  assertion about a note's *content* would catch it. **This is the check this section exists for.**
- A second `<leader>LN` sends **nothing** rather than filing the notes twice, and says so.
- **A settled review leaves no notes behind** (round 20's B-1: the markers survived `approve`, so the
  next survey of the file redrew them and `\LN` journaled them again, 4 notes placed and 7 journaled).
  Place 3 notes, hand them back, `:LainReviewVerdict approve`, then survey the same file again and place
  **one** note and hand it back. **PASS:** the second review's `\LN` sends exactly one, no note mark from
  the first review is drawn (`nvim_buf_get_extmarks` over the note namespace answers 1), and

  ```bash
  ruby -rjson -e 'n=0; ARGF.each_line{|l| r=JSON.parse(l) rescue next; n+=1 if r["type"]=="annotation_placed"}; puts n' "$JOURNAL"
  ```

  prints **4** for the whole session (3, then 1), never 7 or 8. **Catches B-1 returning:** a count above
  the number of notes the human actually placed.

### The thread, and the question that reaches the model

`<leader>Lt` on an anchored line opens the thread pane. Type a question below the conversation and
`:w`:

- the question reaches the docent and the answer renders **in the thread pane**, not in the chat;
- a second `:w` with nothing new typed refuses in words — the watermark advanced, so an identical
  question is not sent twice (which would be a second docent spawn and a second provider call);
- text typed *after* the answer still sends.

**Cost note:** this is the one part of §4b that spends a model call. Everything above is RPC and
free. Run the note checks even when the bench has no model up.

### What wrong looks like

| Symptom | Where it actually is |
|---|---|
| a note comes back on the line it was placed, but `drifted` is absent from the payload | a nil value drops its key from a Lua table entirely, and `AnnotationPlaced` gives `drifted` no default — the hole is refused rather than journaled as "did not drift" |
| notes arrive in line order | the per-buffer store went back to a `[buf][id]` map; `pairs` has no order at all |
| `<leader>Ln` does nothing in the NEW window | the keys bind off the review STAMP, not a buffer name. If the stamp was withdrawn (you moved to another file and back) the keys are removed on purpose — reopen the row from the sidebar |
| the refusal arrives with `stack traceback:` | §4's delivery rule, one rail over |

## 5 — The approval surfaces must agree, and in a cockpit nvim is where they are answered

**The human's ruling, landed 2026-09-14: nvim-first.** With an editor attached, the chat pane
**opens no `[y/N]` reader and no reader whose line can become an answer**. It announces a parked
call in one line, turns its prompt into a **command-only** `command>` reader, and leaves the answer
to `lain://approval` (`:LainApprove` / `:LainDeny`) or to a `/approve` typed on purpose. Round 17's
three chat-pane defects — the ghost `human>` (F101), typeahead signed as a human denial (F102) and
the live-looking stale `[y/N]` (F106) — are gone **in the cockpit** by construction, because the
reader they raced no longer exists there. The plain `--no-nvim` chat keeps its inline prompt, with
guards; the last part of this section drives it.

**Run this section under `--approval ask`.** A launched chat is `auto`, where the judge may answer
the call before any surface sees it. Force a gated call that no rule approves — `echo hello` is
enough, since `echo` is not on `ComposedTerm`'s allowlist (`shell-terms.md` §4). **`ls -la` no
longer parks:** `ls` joined the shell rule's allowlist, so in the project root it runs with no
surface asked, and every transcript below that parks `ls -la` is a record from before that change.
Compare the surfaces:

| surface | check |
|---|---|
| chat pane | **one** arrival line naming the requester, the call and both answer routes, and **no** `[y/N]` |
| chat pane | the prompt becomes `command>`; a `/`-command runs there, prose does not answer anything |
| `lain://approval` | the `y approve, n deny` affordance, and the full command — read from `b:lain_approval_calls`, **not** from the rendered rows, which are elided and wrapped on purpose (see *Reading a long command back*, below) |
| the status feed (`$XDG_STATE_HOME/lain/status/<hash>/state.json`, **not** `.lain/state.json` since round 13) | `approvals_pending` |
| journal | `approval_pending` with `requester` |
| journal | the `escalation` ladder — see below; it is the surface that says WHICH surface answered |

**Automated by** `spec/e2e/cockpit_approval_spec.rb`, "runs the call in the project and journals an nvim approval", "clears the approval buffer and shows the model's final reply in the chat pane", "does not run the call and journals an nvim denial" and "tells the model the approval was denied": a gated `bash` call parks with `approvals_pending` in the status feed, `:LainApprove` runs it and `:LainDeny` does not, each journals 1 `approval_decision` with `surface: nvim`, and `lain://approval` goes back to `(no approvals pending)`. **Still needs a human:** the arrival line and the absent `[y/N]`, the `command>` table, the bell, 3 calls at once, the `escalation` and pairing reads, the requester name, the plain-chat guards and the long-command read below.

Driven against the built binary 2026-09-14 (`main` at `70c0782f`, a `lain up` cockpit over a
scratch git tree, local `qwen3-coder:30b`), verbatim from the chat pane:

    ! agent asks to run bash({"command" => "ls -la"})  -- answer in lain://approval, or /approve
    command>

and `b:lain_approval_calls` held `bash({"command" => "ls -la"})`. Then, at that `command>`:

| typed | pane | journal |
|---|---|---|
| `yes please` | `HH:MM:SS held as your next prompt: yes please`, then a second line `that does not answer the approval: /approve answers it` (with a question parked it reads `that does not answer the question: /inbox lists it, and :LainReply answers it`) | **no** `approval_decision`; after the line settled, `yes please` was committed as the next user turn |
| `/approve` | `agent asks: approve bash({"command" => "ls -la"})? [y/N]` — `/approve` owns the terminal for its line; the `[y/N]` is drawn in the input pane (round 25) | — |
| `y` (at that prompt) | the dispatching line continues | `approval_decision surface=tty verdict=approve`, then `escalation rung=surfaces … (tty)` |

**What wrong looks like:** a `[y/N]` drawn in the cockpit chat pane without `/approve`; an
`approval_decision` from `tty` that nobody typed `/approve` for; a prose line at `command>` that
vanishes instead of being held (the held line must survive to `you>`, including across a Ctrl-C of
the dispatching line); or an arrival line printed twice for one parked call (a call is announced
once, however many lines it outlives). **Nothing is dropped by not reading it inline**: the parked
call stays in the queue, so `/approve`, `lain://approval` and the journal all still see it.

**A `/`-line typed at a drawn `[y/N]` is never a decision** — at the one `/approve` draws in a
cockpit, and at every inline one in a `--no-nvim` chat. It is held for `you>` and the same prompt is
drawn again, empty; round 17 typed `/goal off` at a drawn approval, the call was denied, and the goal
ran on. *Driven 2026-09-14* in a `--no-nvim` chat (the same prompt class `/approve` draws):

    agent asks: approve bash({"command" => "ls -la"})? [y/N] /status
    held as your next prompt: /status
    agent asks: approve bash({"command" => "ls -la"})? [y/N]

no `approval_decision` until the window closed, and the held `/status` ran at the next `you>`. A
`/`-line recorded as a `tty` denial is round 17's shape back. Driven round 26: held, the prompt redrawn, no decision.
When `/approve` drew the `[y/N]` and it times out, the lapse is said twice in the chat pane (round 26, b26-2). A held paste in `--no-nvim` is drawn onto the `[y/N]` row, so a `y` shows at an approval nobody gave (b26-4).

**The `notify` layer rings the terminal on an arrival, and nothing else runs.** Its lighter is
`BELL`. While it stands, a question, approval or review arrival writes **one** BEL byte (`\a`) to
the chat pane and, inside `$TMUX`, runs `tmux display-message` with the arrival line (scrubbed,
200 characters at most, on a 2 s timeout that never blocks the render). There is no desktop
notifier behind it. Read the bell off a `pipe-pane` capture of the chat pane rather than by ear, and
the message off a `tmux` wrapper on the chat's `PATH` that logs its arguments (a detached test
server has no client to show it on). *Driven 2026-09-14* in a `--no-nvim` chat inside tmux with
`/mode +notify` (recorded 2026-09-14 as `accept_edits: no layers active -> accept_edits: notify
(BELL)`; a mode reads `checkout ask: notify (BELL)` since round 18), for the parent's
own `ask_human`:

- the pane stream carried `? agent What is your favourite colour?  -- answer in lain://inbox, or
  /inbox` followed by exactly one `\a`;
- the wrapper logged `display-message ? agent What is your favourite colour?  -- answer in
  lain://inbox, or /inbox`.

**And an inline `[y/N]` does not ring.** In the same kind of chat, with the layer up, a parked
`ls -la` drew its `[y/N]` and wrote no BEL and ran no `display-message` (driven 2026-09-14): the
approval bell rides the one-line approval ARRIVAL, which only a cockpit draws. So check the approval
bell in the cockpit, the `! <requester> asks to run …` line followed by one `\a`, plus one
`display-message <arrival line>` (driven in round 22: 1 BEL and 1 display-message), and record the plain chat's silent `[y/N]` as the current shape rather than as a
pass. With the layer down, an arrival must write no BEL and run no `tmux` command at all.

**Now drive three gated calls in one turn.** The house model **does emit parallel tool calls** now
— round 17 saw six `tool_use` blocks in one message when it asked for one per turn, and two
`subagent` calls in one message, but **`bash` is an unsafe tool, and the runner treats each
unsafe call as a barrier that runs alone** (`agent/tool_runner.rb`, `ToolRunner#run`). So three
parallel `bash` calls park ONE AT A TIME, and three rows at once is unreachable with `bash`
(round 22). Ask for `echo one`, `echo two` and `echo three` as three calls in one message and check what is
reachable: one arrival line and one row in `lain://approval`, and answering it releases the next,
in wire order. Three rows at once needs gated calls that are all parallel-safe, so name that
vehicle before claiming the shape. **Queued approvals are announced**: each call parked behind
the drawn one gets its own line (`Intake#enter`), and an approval's clock starts when its row is
drawn, not when it was parked. Round 22 saw "nothing announces" once; that was a draw-order
observation, not a missing announcement.

**The `escalation` records are the sixth surface, and the only one that says WHICH surface
answered.** Round 9 used them to settle round 8's F40 in a way no pane capture could: every gated
call journals a triage → rules → surfaces ladder, and the final rung names the answering surface.
So a round can prove which surface decided each call — nvim, or a `/approve` typed on purpose —
from the record rather than from a screenshot:

```bash
ruby -rjson -e 'ARGF.each_line{|l| r=JSON.parse(l) rescue next
  next unless r["type"]=="escalation" && r["rung"]=="surfaces"
  puts [r["tool_use_id"], r["verdict"], r["reason"], r["authority"]].join(" ")}' "$LAIN_QA_JOURNAL"
# -> call_i56e1vrp allow a surface approved this call (nvim) human
# -> call_dpm11x9y allow a surface approved this call (tty)  human
```

Check the `approval_pending` and `approval_decision` COUNTS match too — round 9 read **12 and 12**,
both surfaces represented, no pending left unanswered. That is the shape F40's
eleven-pendings-to-one-prompt violated, and it is cheaper to read than the panes.

**Pair them by `tool_use_id`, and within an id by order.** Both records carry the field, so a
decision names the call it settled rather than leaving a reader to guess from timing. One call
can park **twice** — at the path gate, and again at the release of a masked region — so an id
with two pendings and two decisions is correct, and the pairing inside that id is positional:
first pending with first decision. Counting alone cannot tell that apart from two unrelated
calls, which is why the field is there:

```bash
ruby -rjson -e 'seen=Hash.new{|h,k| h[k]=[]}; ARGF.each_line{|l| r=JSON.parse(l) rescue next
  next unless %w[approval_pending approval_decision].include?(r["type"])
  seen[r["tool_use_id"]] << r["type"]}
  seen.each { |id, kinds| puts "#{id} #{kinds.join(" ")}" }' "$LAIN_QA_JOURNAL"
```

Every id must read `approval_pending approval_decision` (twice over for a gated-and-released
read), in that order. A decision with no pending before it, or a pending with no id at all, is a
finding. A pending carrying `"humans_only": true` is the withheld-output case
(`shell-term-approval.md`): it may only be settled by a person, so a decision on it from
`surface=auto` is a finding too.

Both the arrival line and the `[y/N]` must **name the requester** (`agent` / `researcher` /
`subagent`) — with `fleet 2` on the status line you otherwise cannot tell a parent from its child.
The whole prompt, as `/approve` draws it in a cockpit and as the plain chat draws it inline:

    <requester> asks: approve <tool>(<input>)? [y/N]

### The deadline, the reason, the held notice and the stamps *(2026-10-08 trial fixes)*

The trial's first `bash` call auto-denied after 300 seconds with no surface having shown it, and a deny
gave the model nothing to read. Make the wait short so each check is quick: write `approval timeout: 30` in
`.lain/config.rb`, run `lain trust --yes`, relaunch. (`approval timeout:` takes a number of seconds above 0;
`0`, a negative number and a non-number refuse at load. Without the line the window is 300 seconds, and
the displayed figure is `5:00`.) Park `echo hello` and read each surface:

| surface | what it says |
|---|---|
| plain chat prompt (`--no-nvim`) | `HH:MM:SS agent asks (auto-denies in 0:30): approve bash(...)? [y/N]` |
| cockpit chat arrival note | starts with `HH:MM:SS` and ends `; auto-denies in 0:30` |
| nvim `lain://approval` row | `agent  <call>  0:30 left, denies at HH:MM:SS`; the sensitive-region warning, if any, stays ahead of the call, and a long call cuts the deadline from the first line (it stays in the folded item beneath) |

1. **The nvim figure is a snapshot.** `0:30 left` does not tick (it is re-rendered only when the parked set
   moves), so do not file a countdown that sits still. The `denies at` clock time is fixed and is the
   figure to check against `date +%T`.
2. **A lapse is said once on every surface.** Let it run out. The chat pane gets one line,
   `HH:MM:SS ... denied after 0:30 with no answer` (the cockpit form also names the call: `! agent asks to
   run bash(...)  -- denied after 0:30 with no answer`), the nvim buffer gets one `! agent  bash(...)  --
   denied after ...` line after its rows in the one rendering that drops the call, and the model's tool
   result is an error carrying the same sentence: `approval denied for tool "bash": denied after 0:30 with no
   answer` (**round 23 B23-2, fixed**; the bare `approval denied for tool "bash"` is a human's `n`, so a lapse that
   reads that way has lost its sentence). In a `--no-nvim` chat the timeout line is led by the call and starts with `HH:MM:SS`:
   `HH:MM:SS -- agent asks to run bash(...): denied after 0:30 with no answer` (round 25, b25-5, fixed), so with 2 parked calls it says which
   lapsed. A call closed because its requester was stopped (`/stop` over a parked call) reads `closed: its requester was stopped`, never
   `decided by abandoned`. **Wrong looks like:** the lapse said twice, said
   on one surface only, or the old wording `decided by timeout: denied`.
3. **A deny can carry a reason, and the model reads it.** Park another call and answer with a reason:
   at a plain `[y/N]`, `n stay inside the project` (also `no, ...`, `n: ...`); at nvim, `:LainDeny stay
   inside the project`. Since round 23 a `[y/N]` takes only a verdict (guard 4 below), so `n stay inside the project`
   is a reasoned no and `stay inside the project` alone is prose, held for `you>`. The tool result the model sees is `approval denied for tool "bash": stay inside the
   project`, the journal's `approval_decision` holds `"reason"`, and the surface is `tty` or `nvim`. The
   `n` key with no text, a bare `n` or a bare `:LainDeny` sends a plain deny: today's sentence and
   **no** `reason` key. Control characters in the words (a newline, an ESC) become spaces, and words that are
   all blank count as no reason.
   **Wrong looks like:** a bare `approval denied for tool "bash"` after a typed reason, so the model
   retries the same call.
4. **The held notice says why and where to answer.** With an approval parked, type `yes please` at
   `command>`: the line is held for `you>` (stamped), followed by `that does not answer the approval:
   /approve answers it`. With a question parked (`ask_human`, §5b) the second line is `that does not answer
   the question: /inbox lists it, and :LainReply answers it`. Neither line answers anything.
5. **Status lines carry the time they happened.** The held line, the approval arrival, a dropped
   prompt and the closing line of a decided one each start with `HH:MM:SS`; the drawn `[y/N]` is stamped at
   the moment it is drawn, which is later than its arrival when another prompt was ahead of it. Assistant
   prose is not stamped. **B23-1 (approval timestamps) was fixed in round 26**: the arrival reads `HH:MM:SS ! agent asks ...` and the lapse `HH:MM:SS ... denied after 0:30 with no answer`. A question arrival's tmux bell message is also not stamped (only the printed line is);
   record it if you see otherwise.
6. **The question buffer says where answers go.** Open a question (`ask_human` with an options question and
   a free-text one) in `lain://question`. A virtual row `answer here, indented 2 spaces` shows under a
   question with no answer yet; a line you type at column 0 (not a rendered row) is highlighted as an
   error; an indented line under the question clears both. Write an answer **inside** a rendered question
   body and `:w`: the refusal reads `... renders its body verbatim and reads only your answer, so write
   answers below the whole question, after a blank line, indented 2 spaces, not inside it (expected ...,
   got ...)`. **Wrong looks like:** the old refusal that said only that the line cannot be edited.
   Known limit: a typed line identical to a rendered one is not flagged, only the surplus copy is.
   **Round 23 j-8 and j-9, fixed.** A ticked option (`- [x]`) is not flagged as a bad indent (it was, on all 13 of
   them). And a refused write never blocks nvim: a stray line, an untouched buffer (`:w` says nothing has been typed and
   `:w!` submits it as it stands) or a compose that could not reach lain is answered on the review rail, the buffer
   stays modified, and no hit-enter prompt appears. Check by running `nvim --server "$S" --remote-expr 1` right after
   the refused `:w`: it answers at once. **Wrong looks like:** a Lua traceback in the message, or that command hanging
   until a key reaches the nvim pane.
   **After the last set (2026-10-09 trial fixes).** Answer the only pending set with `:w`. The buffer's first line becomes
   `answered at HH:MM; your answers went to the agent`, it is read-only, its window closes (a window that is its tabpage's
   last stays), nothing else opens, and `:buffer lain://question` shows the answers. With 2 sets pending, answering the
   first opens the second and the banner waits for the last. **Wrong looks like:** the answered document left on screen and
   writable, so a second `:w` is refused. The chat pane shows the stamped `answered the agent's questions` echo.
7. **`/help` is columns.** Names in one aligned column, headings styled, descriptions wrapped under their
   own column; at 60 columns a long name pushes its description to the next row.

### The plain chat keeps its inline prompt, with three guards

**Run this on `--no-nvim` too.** There is no second surface there, round 4 found a permanent wedge
there, and it is the one path where the chat still reads a `[y/N]` itself. Since 2026-09-14 that
read is guarded three ways, and each guard is a check:

1. **Typeahead is never an answer, and never lost.** Just before a `[y/N]` or `human>` read opens,
   the terminal's buffered input is drained. A **complete** line is held for `you>`; a trailing
   **partial** line is shown back and dropped from this prompt. Driven 2026-09-14 in a `--no-nvim`
   chat: `yes please` and Enter typed while the turn dispatched, then `ls -la` parked, and the pane
   read

       yes please
       held as your next prompt: yes please
       agent asks: approve bash({"command" => "ls -la"})? [y/N]

   with **no** `approval_decision` until a human typed at the prompt. The partial case was driven in
   the same session — a `y` typed with no Enter, then drained when the next read (a `human>`) opened:
   `discarded: y -- finish that line and it is held as your next prompt`. Round 17's F102 was
   exactly such a line becoming a `tty` denial 19 ms after the prompt appeared. **What the guard
   does not do:** a line typed while a `[y/N]` is already drawn is read by it, as it should be — the
   drain runs only as a read opens, so the driver's own "do not type at a live prompt" rule
   (`method.md`) still binds.
2. **A prompt decided elsewhere is closed in words.** When the timeout, `--secret-oracle` or
   another surface decides the pending the TTY is reading, the read stops and the prompt line ends
   with `-- decided by <surface>: <verdict>`; **a lapse of the clock is the exception and says
   `denied after M:SS with no answer` instead** (2026-10-08: the old `decided by timeout: denied` told
   nobody how long the wait was). *Driven 2026-09-14* by leaving `ls -la` parked for the
   300 s window, before that wording changed: the prompt line became

       agent asks: approve bash({"command" => "ls -la"})? [y/N] -- decided by timeout: denied

   and today it ends `denied after 5:00 with no answer`. Either way the journal reads `approval_decision
   surface=timeout verdict=deny timed_out=true latency=300.0…`. A `n` typed after that line is not an approval decision — round 17's F106 turned
   it into a chat prompt under a prompt that still looked live.
3. **The closing line ends the drawn prompt row first** (round 20's B-3: the timeout verdict
   was printed on the chat fiber while Reline still owned the `[y/N]` row, so the next streamed text
   glued onto it, `deniedI apologize`). Leave a `[y/N]` parked until the timeout decides it while the model
   goes on to stream text, then read the raw pane: the output holds the verdict (`denied after M:SS with no
   answer`, which now starts with an `HH:MM:SS` stamp)
   **followed by a line break** before the model's next words, and the `[y/N]` row itself is still in the
   scrollback (`tmux -L "$QA_SOCK" capture-pane -p -S -50`). **Catches B-3 returning:** the verdict and the model's first
   word on one line, or a `[y/N]` row that was overwritten.
4. **A `[y/N]` takes only a verdict** (round 22's F-5: a paste during a `[y/N]` was read as "no" and
   discarded; **round 22's fix never landed and round 23 B23-11 landed it**, so a round that ticked this box
   from the older scenario text ticked a behaviour that did not exist). The grammar: `y`, `yes`, `n`, `no`,
   `nope`, `nah`, in any case and with trailing punctuation (`yes!`, `no.`), an empty line, or `n <reason>` (also
   `no, ...`, `n: ...`). Anything else, including a pasted block of several lines whatever its first line says,
   leaves the approval open and is held as the next prompt, and one line says `a y or n answers the approval`.
   Paste `please also fix the tests` at a parked `[y/N]` and check the call is still parked, no `approval_decision`
   is journaled, and the line comes back at `you>`. Then paste `y` newline `rm -rf x` as one block: still
   parked, held whole. A `/command` is held as well (`/goal off` is meant for the chat). The input pane's reader
   is stubbed in the spec, so this one needs a human in a live pane.
5. **A question answered elsewhere retires.** A subagent question settled by another surface is
   retired rather than re-queued, so no `human>` is drawn on the next dispatched lines. *(Prediction,
   not yet driven: round 17's F101 ghost was three `human>` prompts drawn mid-dispatch after an nvim
   answer.)*

### Reading a long command back: the rows are cut on purpose

**Two shapes on this buffer look like truncation and are not.** Both are the design, and neither
is a finding. **Do not re-file either.**

- **The summary row ends in `...`.** An item that overruns 96 columns is drawn as a *cut prefix*
  over a foldable body carrying the whole row beneath it —
  `summary[0, WIDTH - ELISION.length] + ELISION` at
  `lib/lain/frontend/neovim/approval_view.rb:433`, with `ELISION = "..."` at `:87`. So every long
  call shows a trailing `...` on its first line. That is a fold, not a loss: open the fold (§8) and
  the rest is directly below it.
- **The body below it splits mid-token.** `BODY = /.{1,#{WIDTH - INDENT.length}}/m` (`:105`,
  indented with two spaces by `#body_for` at `:443`) cuts on the column and never on a word
  boundary. That is deliberate: the bytes on screen are the bytes a `y` releases, so a
  word-boundary wrap would move spaces and show the human something other than what runs. Rounds
  13, 14 and 15 each filed this split (round 15 quoted `bundle install` / `--quiet` across the
  break) as F76, and each time the wrap was the design rather than the defect.

What *was* the defect is that a reader could not get the command back: joining the rendered lines
leaves the two-space indent lodged mid-token, so a substring match against the original command
misses. That is fixed, and the fix is a second publication rather than a change to what is drawn.
Ruby computes one unwrapped string per **parked call** — `calls = parked.map { |pending|
call_of(pending) }` at `approval_view.rb:407` — and ships it beside the row count from
`#posted` (`approval_view.rb:385`) through `RpcThread#set_approval`
(`lib/lain/frontend/neovim/rpc_thread.rb:444-445`). The runtime stamps both onto the buffer:
`b:lain_approval_calls` and `b:lain_approval_call_index` at
`lib/lain/frontend/neovim/runtime/62_approval.lua:156-157`. **Read those. Never the rendered
text.**

```bash
# every parked call, uncut, one per line
nvim --server "$S" --remote-expr \
  "join(getbufvar(bufnr('lain://approval'), 'lain_approval_calls', []), \"\n\")"
# -> bash({"command" => "cd /path && bundle install --quiet"})

# how many rows are ANSWERABLE -- the bound on N below
nvim --server "$S" --remote-expr "getbufvar(bufnr('lain://approval'), 'lain_approval_rows', 0)"

# the call a given ROW belongs to; N is the 1-based buffer line
nvim --server "$S" --remote-expr \
  "getbufvar(bufnr('lain://approval'),'lain_approval_calls',[])[getbufvar(bufnr('lain://approval'),'lain_approval_call_index',[])[N-1] - 1]"
```

**N must be `<= b:lain_approval_rows`.** The buffer holds two lines past the last answerable row —
a blank and the `-- y approve, n deny` hint — and `call_index` is rows-shaped, so a driver who
counts lines rather than reading the row count and asks for one line too many gets
`E684: List index out of range` rather than an answer. Read `b:lain_approval_rows` first; it is
the same count the runtime's keymaps are inert outside.

**The `, []` and `, 0` defaults are load-bearing, and the reason is the failure mode below.**
Without them, `join(getbufvar(…), "\n")` against an *unset* variable answers `E714: List required`
and exits 2. That error is a true signal — it is exactly the "absent while rows is positive" case
— but a bare error reads to a driver as a broken recipe, and the round is then spent on the
recipe instead of on the finding. With the default, absence prints **empty**, which compares
directly against the row count and reads as data. If you do run the bare form, treat `E714` as the
finding, not as your own mistake.

`call_index` is **1-based**, because the lua side indexes `calls` with it directly, while
vimscript's `getbufvar` hands back a 0-based List — which is where the `[N-1]` and the trailing
`- 1` come from. From lua the same read is `calls[call_index[N]]` with no arithmetic at all; that
is what the live-nvim example does -- `carries the wrapped command unwrapped, with the rendered
lines unchanged`, in `spec/lain/frontend/neovim/runtime/62_approval_spec.rb` -- which asserts in one
breath that the rendered lines still do **not** contain the command and that
`b:lain_approval_calls` does. (By NAME, not by line: it was cited as a line number in
`neovim_runtime_spec.rb` until that file was split per runtime lua module on 2026-09-14, and the
number would have been wrong within days regardless.)

Two things to know before matching on the result:

- **It is the whole call, not the bare command.** An entry is `<tool>(<input>.inspect)`
  (`approval_view.rb:445`), so a command containing `"` or `\` comes back escaped the way Ruby
  inspects it. A plain shell command matches literally; anything quote-heavy, compare against the
  inspected form.
- **One entry per parked call, never one per row.** A 200-character command wrapping into three
  rows still yields a single entry — which is the whole reason the row → call map exists. Two
  parked calls give two entries, in queue order.

**What a real finding looks like here**, as opposed to an elided or wrapped row: `b:lain_approval_calls`
absent or empty while `b:lain_approval_rows` is positive; an entry that does not carry the command
in full; or a `b:lain_approval_call_index` whose length disagrees with `b:lain_approval_rows`.

### A stopped ask takes its question with it

Round 20's C-1: an ask parked on `ask_human` that the human stopped left its row in `lain://inbox` and
`inbox:N` in the HUD for good, because a stop commits no turn and nothing retired the question. Drive it in
a cockpit: ask the model something it can only answer by calling `ask_human`, wait for the row, then `/stop`
(or Ctrl-C). **PASS**, all four: the journal holds a `questions_consumed` record naming that question's
digest, the HUD reads `inbox:0`, `lain://inbox` has no row, and `/inbox` offers nothing. An **answered**
question retires exactly **once** for the parent, so count `questions_consumed` records naming it:
1, not 2. **For a child's question the count is 2 today** (round 22's B-5: `ask_human` and the
scribe each journal one, one digest); record that as the current shape, not as a pass. **Catches C-1
returning:** any of the four surfaces still showing the question after the ask ended.

**Automated by** `spec/e2e/stop_while_busy_spec.rb`, "consumes the question when an ask parked on it is stopped": after `/stop` the journal holds a `questions_consumed` with 1 digest, the status feed's `inbox_count` is 0 and `lain://inbox` has no row. **Still needs a human:** that the digest is the parked question's, the HUD's `inbox:0` read off the pane, `/inbox` offering nothing, Ctrl-C as the stop, and the answered question retiring once.

### The second queue consumer is gone, and the notifier with it

**Retired, recorded so a driver who remembers it knows it was lifted on purpose.** Round 4's wedge
on a second gated call was never stdin ownership — it was a **second consumer** of the approval
queue: the desktop notifier re-parked immediately, took the second call ahead of the TTY and held it
for `dunstify`'s blocking 300 s window. That notifier was deleted in `c40ab419` (2026-09-12), and
with it `--desktop`, `LAIN_DESKTOP`, the `dunstify -r`/`-C` replace-and-withdraw correlation and the
`dunstctl count displayed` check this section used to drive. There is nothing to withdraw and no
popup to count; `spec/approval_consumer_discipline_spec.rb` pins exactly one approval consumer.

What survives of the old section is the journal shape to watch for: a surface that dies mid-read
journals a **`tty_fault`** rather than signing a denial as though a person typed `n`. A `denied`
decision with no human at the keyboard is still the shape to look for.

## 5b — Command dispatch at the `human>` prompt, and inside `/inbox`'s own drain

**Superseded in round 7: F27 is WITHDRAWN, replaced by the narrower F29, which this chunk fixes.** Round 6
filed this section as "only `/inbox` is honoured at `human>`; every other command is silently
delivered to the subagent as the answer." Round 7 re-tested it and it does not reproduce: a plain
`human>` prompt dispatches through the same command registry `you>` uses —
`Wiring#build_repl` binds it (`wiring.rb:460`) and `Reply#typed` dispatches through it
(`human_replies.rb`). **Do not drive this section as a reproduction of that table** — it
is not a defect. The real trap is narrower and lives one command later: `/inbox` opens its own
drain, and `Reply#drained` (`human_replies.rb`) used to read with no registry of its own,
so the *very next line typed* — even a registered `/command` — was swallowed as the answer to the
parked question rather than dispatched. The round-7 chunk gives the drain the same classification the
outer prompt uses. Drive this section to confirm that fix holds, not to re-file the withdrawn finding.

**Drive the table below in a `--no-nvim` chat: since 2026-09-14 a cockpit has no `human>` read.**
With an editor attached, a parked question is announced in one line and the chat reads `command>`,
the same command-only reader §5 drives — a `/`-command runs, prose is held for `you>` and never
becomes the answer, and the answer goes through `lain://inbox` or a deliberate `/inbox`. Driven
2026-09-14 in a `lain up` cockpit, with the parent's own `ask_human` parked:

    ? agent What is your favourite colour?  -- answer in lain://inbox, or /inbox
    qwen3-coder:30b ctx 17%
    command>

`:LainReply blue` on the row in `lain://inbox` journaled the answer (`message` payload
`{"answer" => "blue"}`), the turn continued, and the chat came back to `you>` with no prompt drawn in
between. **What wrong looks like in the cockpit:** a prose line at `command>` recorded as the answer,
or a `human>` drawn in the chat pane at all. In the cockpit, steps 2–5 below are driven inside
`/inbox`'s own drain, which owns the terminal for its line; step 1's `/status` is typed at
`command>`. *(Driven in round 22: `/inbox` typed at `command>` in a cockpit passes.)*

**Automated by** `spec/e2e/cockpit_question_spec.rb`, "lists the parked question in lain://inbox and counts it in state.json", "journals the human's answer to the child's question", "leaves inbox_count and fleet at 0 and lain://inbox with no open question" and "reports none open in the chat pane when /inbox is typed in the input pane": a skill child on a second model parks a question, `:LainReply` on its `lain://inbox` row journals the answer, `state.json`, `lain://inbox` and `/inbox` come back empty, and `/inbox` typed at `you>` afterwards answers `(no questions pending)` in the chat pane. **Still needs a human:** the HUD's `inbox:N` read off the pane, no `human>` drawn in the chat pane at all, the arrival line, a prose line at `command>` held rather than taken as the answer, the prediction above, and the whole `--no-nvim` table below.

Spawn a subagent (`method.md`, "Making a session with `message` and `child_turn` records") and wait
for the prompt to become `human>`. Then, at that prompt, in order:

| step | input | expected |
|---|---|---|
| 1 | `/status` | renders status, exactly as at `you>` — journal unchanged, question still parked (confirms F27 stays withdrawn) |
| 2 | `/inbox` | renders the parked question and its reply affordance — opens the drain |
| 3 | `/status` (the line right after `/inbox`) | status renders, and is **not** recorded as an answer — the drain now classifies like the outer prompt; before that, this exact line silently became the reply |
| 4 | `/nonsense` (an unregistered `/word`, still inside the drain) | refused **by name**, naming the unknown command — never sent to the subagent as prose |
| 5 | ordinary prose | recorded as the answer to the parked question |

> ⚠️ **The bare prompt and the drain deliberately disagree about an UNREGISTERED word, and a driver
> who does not know that will re-file the withdrawn finding.** Step 1's registry dispatch is true of
> *registered* commands only: at a plain `human>` prompt, outside any drain, an unregistered `/word`
> is still delivered to the subagent as the answer — `Reply#typed` routes an unmatched line to
> `[line, item]` on purpose. Only **inside the drain** is it refused (step 4). So trying `/nonsense`
> at step 1 shows F27's exact signature and is NOT a defect. The asymmetry is deliberate and the
> reason is recorded beside the code.
>
> The same classification bites step 5: `prose?` is `Skill::Invocation.parse(...).inline?`, so a
> reply that merely *opens* with a slash — `/tmp is fine` — is classified as a command attempt and
> refused inside the drain rather than answered. Pick prose that does not start with `/`, or the
> control fails for a reason that is not the drain.

Read the journal, not the pane, for the fact of the matter:

```bash
ruby -rjson -e 'File.foreach(ARGV[0]){|l| r=JSON.parse(l) rescue next; next unless r["type"]=="message"
  puts "#{r["ts"]} from=#{r["from"].inspect} payload=#{r["payload"].to_s[0,120]}"}' "$LAIN_QA_JOURNAL"
```

**What wrong looks like now.** A `payload={"answer" => "/status"}` (or any registered command's own
text) record at step 3 or 4 means that fix regressed — the drain is back to swallowing a command as
content, F29's exact shape. A step-4 line with no refusal on the pane and no `message` record at all
is the "unregistered word forwarded silently" variant of the same failure — check both surfaces, not
just one, before calling step 4 a pass. Step 5 is the control: prose must still reach the subagent as
its answer, or the drain has stopped answering questions at all, which is a different defect.

## 6 — `lain://timeline` follows the session, and a bad row says so

**Two asks do not reproduce the round-4 freeze, and that was tried three ways including a real
cockpit** — so a scenario written as "drive two asks and compare linecounts" (which §2 above is, and
should stay) can pass while the defect is fully present. **The trigger is a newline.**

`nvim_buf_set_lines` refuses any item containing a newline, and refuses **all-or-nothing**; the
render rides `nvim_exec_lua` as a *notify*, so nvim discards the error and nobody hears it; and the
runtime writes from the first differing line, so the offending line can never enter the buffer and
the prefix can never advance past it. `TimelineView` joined a turn's text blocks verbatim, and real
model prose is multi-line — so the buffer froze at the first multi-line reply and stayed frozen,
permanently rather than intermittently, while every sibling view stayed live.

Drive it accordingly:

```bash
# ask for something the model MUST answer in more than one line
$QA/drive.sh 'List three Ruby standard library modules, one per line, with a one-line description each.'
nvim --server "$S" --remote-expr "getbufinfo('lain://timeline')[0].linecount"
$QA/drive.sh 'Now name a fourth.'
nvim --server "$S" --remote-expr "getbufinfo('lain://timeline')[0].linecount"
```

The count must move after the multi-line reply, and again after the next ask. Cross-check against
`turn_usage` in the journal, which is what the view renders on.

Then check the other half — **a row that breaks the one-line-per-record contract is now refused in
place, by name, instead of taking the whole write down**:

    [lain://timeline line 4: a rendering broke the one-line-per-record contract]

That marker appearing is a **view-level defect worth filing** (some projection is still emitting
multi-line rows), but it is the *good* failure: the buffer keeps its line count, the gestures that
resolve a cursor through it still address the right record, and the render thread survives. The bad
failure is silence — a frozen buffer with no marker in it. On every live path the marker should be
unreachable; if you see one, say which view produced it.

**One more thing this took down, and it is cheap to check at attach:** an invalid-UTF-8 reminder in
the workspace used to raise inside `Surfaces#prime` and leave **every** view dark, with nothing
rescuing it. Drop a byte sequence that is not valid UTF-8 into a reminder or a manifest path in the
sandbox project, restart the cockpit, and confirm all eight `lain://` buffers still prime.

**`lain://status` carries its own copy of that defense, so it is worth the same byte sequence.** Its
fold scrubs an error message before splitting it, because `String#split` raises on invalid UTF-8 and
that fold runs on the same sole drain thread — a raise there takes every view dark again by a
different route. Point a chat at an epic whose `epic.md` holds invalid UTF-8: the buffer must draw
`# epic status unavailable` with the error class and the scrubbed message indented under it, and the
other seven must be untouched. A dark cockpit is the regression; so is a `lain://status` that draws
the failure once and never retries, since the next trigger is supposed to fold again.

## 7 — The HUD segments

The prompt line is composed by `PromptComposer` and printed **into** the pane — it is a point-in-time
snapshot in scrollback, not a live widget, so a value that does not tick is not by itself a defect.

What is worth checking:

- At `you>` between turns the HUD reads `❄ fleet:N inbox:N ctx:N% run:<tokens>`, plus `ASK`, `model:Ns`,
  `tool:x` and `approve:N` when they apply. It carries no model name and no `idle Ns`: a bullet or sample below that
  says `<model> ctx N% idle Ns` is stale (round 25).
- At the prompt of a parked `ask_human` — `human>` in a `--no-nvim` chat, `command>` in a cockpit
  (§5b): the HUD must show no in-flight slot that has ended, and no `idle` (it no longer exists). Driven
  2026-09-14 in a cockpit: `qwen3-coder:30b ctx 17%` above `command>` (the old shape).
- **No prompt is drawn mid-dispatch after a question was answered elsewhere.** Round 17's F101 drew
  `<model> ctx 80% idle 0s` / `human>` on every later ask after an nvim answer; a surface now retires
  a question settled on another one. In a cockpit there is no `human>` to draw; in a `--no-nvim`
  chat answer a subagent's question from a second surface and watch the next three asks.
  *(Prediction, not yet driven in the plain chat.)*
- After a **torn** turn (a provider error, a budget refusal): `idle` must come **back**. A version
  of this fix read `Agent#state` and left the machine parked at `:awaiting_model`, suppressing the
  reading for the rest of the session — silence that is just as dishonest.
- `ctx N%` must agree with the status feed's `occupancy` (`$XDG_STATE_HOME/lain/status/<hash>/state.json`,
  not `.lain/state.json` since round 13) and the journal's `compaction_decision`.
- **A model call or a tool in flight shows in the HUD** (2026-10-08: a 30 second model call read the same as
  idle). The HUD file (`state.json`) and the input pane header carry ` model` while a model call is
  outstanding (the live reading in the chat adds the seconds, ` model:12s`), and ` tool:grep` (several
  names comma-joined) from the moment the model asks for tools until their results are committed. Idle
  at `you>` carries neither. Ask for something that runs `grep` and `read_file` and watch the HUD row once a second
  with `tmux -L "$QA_SOCK" capture-pane -p -t <input>`. The published file does not tick: it is rewritten on a transition, so
  a file that reads ` model` bare and a live reading with seconds are the same state. **Round 23 HUD-1 and
  HUD-2, fixed.** The tool names come from the committed turn, so a parked call reads `"in_flight":{"kind":"tool","tools":["bash"]}`
  and `tool:bash` (2 calls in one reply: both, comma-joined; a child's tool call never reaches the parent's HUD), where
  before `tools` was `[]` on every park and run. A run that is interrupted clears the slot: `/stop` mid model call,
  Ctrl-C then `s`, `s` at a parked `ask_human`, and a transport failure each leave `in_flight` null and the idle `you>`
  free of `model:Ns` and `tool:`; before, `model:34s` counted up at an idle prompt. **Wrong looks like:**
  a segment that outlives its call, an empty `tool:` segment, or a header redrawing more than once a second
  during a fast tool loop (measure with the idle-pane byte count from §0 check 2 and a `pipe-pane` over
  the loop; the redraw rate was not measured on the card, so record the number).
- **Round 23 HUD-3, fixed: the pane redraws the HUD in place, over an empty editor only.** At an idle `you>` a header change
  with the same row count rewrites the header rows where they are: watch `capture-pane -p -S -200` over 5 changes and count 1
  header row, not 5, with the prompt line intact. After an answered line the first idle tick prints the header once below the
  echo and later changes rewrite it in place, so the in-flight segment and `fleet:N` now move during a typed ask (they froze
  for 68 s before). At a published prompt (a parked `[y/N]` or `command>`) the HUD holds still while the human has typed anything,
  wrapped draft or not, and catches up at the next prompt. A header of another row count (a spawn adds a fleet row,
  a child ends and one goes) is not left stale: with nothing typed the pane takes back the old rows and draws the
  new header whole at once, so the screen holds exactly the new count of header rows; with a draft typed at such a
  prompt the draft stays and the new header is drawn at the next prompt. While a child runs and the pane is idle, a
  draft survives a row-count change (§0 check 16). A resize waits for the next whole draw. **Wrong looks like:**
  stacked header rows, a stale fleet row, a draft or cursor disturbed by a redraw, or a HUD frozen for a whole ask
  with an empty editor.
- **`fleet:N` is an observation, not a check.** The trial read `fleet:0` after 2 one-shot subagents ran. The
  fix card found the count correct end to end (the spawn is journaled and published in one synchronous call) and
  could not reproduce it. While a one-shot child runs, record what `fleet:` reads and the clock time, and
  again after it completes. A reading of 0 while a child is running is a new finding with a timestamp;
  a matching reading is recorded and closes nothing.
- **The layer lighters, all three of which now mean something** (round 17's F104 found them lighters
  and nothing else). Each is checked against the behaviour it names, not just its letters:
  - `AA` is **gone** with the `auto_approve` layer. `lain chat --auto-approve` must be refused by Thor
    as an unknown switch, and `+auto_approve` as an unknown layer. Approval has lighters of its own
    (below).
  - `GOAL` stands exactly while a goal drives. *Driven 2026-09-14*: `/goal <objective>` journaled
    `mode_switch … to_layers: ["goal"] surface: goal`, `/mode` typed mid-drive answered
    `accept_edits: goal (GOAL)` (now `checkout auto: goal (GOAL)` in a launched chat), and `/goal off` journaled the
    matching `from_layers: ["goal"], to_layers: []`. `/mode +goal` with no goal refuses
    (`repl-commands.md` §1).
  - `VI` switches the line editor at the next read. *Driven 2026-09-14* in a tmux pane: the prompt
    after `/mode +vi` read `qwen3-coder:30b VI idle 0s` over `[ins]you>`, `Escape` made it
    `[cmd]you>`, and `/mode -vi` gave back a plain `you>`. In a cockpit this is the **input
    pane's** prompt, not the chat pane's (§0).
  - `BELL` rings on arrivals (§5).
  - `PLAN`, `ASK` and `BYPASS` are the **axis** lighters, not layers, and they sit before the colon:
    `plan (PLAN) ask (ASK): no layers active`. `checkout` and `auto` carry an empty lighter on
    purpose, so a launched chat's prompt shows neither: do not read their absence as missing support.
    `--approval ask` must show `ASK` from the first prompt, and `--approval bypass` `BYPASS`.
  - **The approval key and `:LainMode` move the lighter at once.** Press Shift+Tab: `ASK` appears (or
    disappears) in the HUD within one refresh, in the input pane (even mid-run, with no prompt open) and, at a plain
    chat's prompt, in its redrawn header, and the status feed's mode agrees. `:LainMode ask` redraws an idle header at once. `:LainMode bypass` in nvim shows `BYPASS`; `:LainMode nosuch` refuses
    in the editor and changes nothing.

## 8 — Fold state on the approval and inbox rows

**This is the RPC half of integration check 7's real-terminal pass** ("park two approvals and
confirm by eye that each row folds open to its full command and closed to its summary — and that
`y` on a continuation line answers that item"). `lain://timeline`, `lain://inbox`, `lain://journal`
and `lain://question` are already fold-eligible (`RECORD_START` in `runtime/05_records.lua` names
them, and `runtime/10_folds.lua` installs an expr fold per record — see the comment there for why
folds are wired before buffers, not after). `lain://approval` is not, as of this writing — driving
this section against it is exactly what T9/T12 are meant to add, and this section is the recipe a
round should run once they land, not a claim that they already have.

**A text read cannot answer this.** `getbufline` and `getbufinfo(...).linecount` return the same
lines whether a row's fold is open or shut — folding is a window-rendering decision, not a change to
the buffer's content — so a driver relying on the buffer probes elsewhere in this file (§1, §2) would
read a folded and an unfolded approval list as identical. `method.md`'s "What a text read cannot
verify" section has the two primitives and a worked measurement; use them here:

```bash
nvim --server "$S" --remote-send ':tabnext N<CR>'    # wherever lain://approval (or lain://inbox) lives
nvim --server "$S" --remote-expr 'bufname()'          # VERIFY before every gesture, as always
nvim --server "$S" --remote-expr "foldlevel(<row's first line>)"
nvim --server "$S" --remote-expr "foldclosed(<row's first line>)"     # the row's own line if closed, else -1
nvim --server "$S" --remote-expr "foldclosedend(<row's first line>)"  # how far the summary is hiding
```

`$QA/nv.sh fold <lnum>` wraps all three against the current window.

Drive it against **two parked approvals**, matching the integration check's own wording. **This is
drivable now**: round 17 found the house model emits parallel tool calls, so two pendings coexist
without a fixture.

1. Force two gated calls so two rows exist in `lain://approval` (§5's three-call recipe works;
   answer one to leave two, or just read both before answering either). Two rows at once is still unreached with this model, which serialises even parallel-safe reads. Drive it with a scripted vehicle (a replayed or stand-in provider turn carrying 3 parallel gated calls), not the live model.
2. **This step's expectation was a prediction, and round 9 measured the opposite -- the RECORD row
   is OPEN at rest and the TRAILER is what folds closed.** Measured against two separate pendings,
   identically:

   ```
   line 1: level=1 closed=-1 closedend=-1     <- row summary   (OPEN)
   line 2: level=1 closed=-1 closedend=-1     <- full command  (OPEN)
   line 3: level=1 closed=-1 closedend=-1     <- full command  (OPEN)
   line 4: level=1 closed=4  closedend=4      <- blank separator, its OWN closed fold
   line 5: level=1 closed=5  closedend=5      <- affordance,      its OWN closed fold
   ```

   That is the good direction for round 8's F42 (the command is visible, not hidden behind a
   truncated summary) and it leaves F43's mechanism in place on the trailer, where the affordance
   line renders with the `fold:` fillchar appended: `-- y approve, n deny  (:LainApprove /
   :LainDeny)··`. Filed as round 9's F52. Drive this step as "what folds, and does it make sense
   that it folds", not as an assertion that the row is closed.
3. Open one row (`<CR>`, or whatever gesture T9 wires): its `foldclosed` must flip to `-1` and the
   full command must now be on screen — check both eye (the pane) and RPC (`getbufline` between
   `foldclosed()` and `foldclosedend()` before the open, `getline` after).
4. The **other** row's fold must be untouched — `foldclosed` still equals its own first line. Opening
   one row opening or closing its neighbour is the regression this check exists to catch (folds are
   per-window state, not a single shared cursor, so nothing in the mechanism should couple them —
   but a render that re-applies `default_folds` on every poll, rather than only at install per
   `runtime/10_folds.lua`'s comment, would do exactly this).
5. **The continuation-line case, named directly in the integration check:** with a row open, move
   the cursor onto one of its *detail* lines (not the summary line) and answer it (`y`/`:LainApprove`
   per §5, whatever T9 lands). It must resolve the same call the summary line names, not refuse for
   "nothing on that row" and not silently answer the neighbouring row. `submit_approval`'s existing
   guard (`vim.api.nvim_buf_get_name(buf)`) is a buffer check, not a row check — verify a continuation
   line resolves through the SAME line-to-call mapping `RECORD_START`-based rows use elsewhere
   (§4's `x` refusal — "nothing on that row" — is the sibling failure mode to watch for if a
   continuation line is not recognised as belonging to its row's call).

Record `nvim --version` beside the result — `runtime/10_folds.lua`'s `foldminlines = 0` write is what
makes a single-line row (no continuation lines at all, e.g. an inbox item before T12 adds detail
lines) fold at all; a single-line row on a build that skipped that write folds open regardless of
`foldlevel`, which would read as "row won't close" and is a different bug than a row that closes but
won't reopen.
