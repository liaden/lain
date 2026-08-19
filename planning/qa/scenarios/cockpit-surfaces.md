# Scenario: the cockpit surfaces (nvim + tmux)

**Why this one exists:** round 4 found **four** of its seven defects here — a frozen timeline, an
approval that never renders, a refusal delivered as a Lua traceback, and a view with no placeholder.
The surfaces are where lain's state becomes something a human can act on, and they have the least
automated coverage of anything in the system: a spec can assert a buffer's *content*, but only a
driver can notice that the buffer disagrees with the pane beside it.

**What it exercises:** `Frontend::Neovim` and its `Surfaces`/`Buffers`/`JournalView`/`RequestBuffer`
projections, the review flow (`/survey` → `<CR>` → `x` → `:LainReviewVerdict`), the approval
surfaces (chat prompt, `lain://approval`, `:LainApprove`, and the desktop notifier that shares their
queue), the RPC transport's one-line-per-record contract, and the prompt composer's HUD segments.

**All four of round 4's surface defects were fixed in the 2026-08-18 chunk, and every one of them
was fixed somewhere other than where it appeared** — the frozen timeline in the RPC transport, the
unrendered approval in the desktop notifier, the traceback in a Lua return path, the missing
placeholder in a view's `initial`. So each section below now carries *what wrong looks like* for the
new mechanism, not just the old symptom: a symptom-only check can pass while the fix has been
reverted into a different failure.

**Cost:** cheap in model calls — most checks are RPC reads. **Piggyback it on whatever subject
scenario is already running** rather than driving a session just for it.

**Needs:** a live cockpit (`lain up`, nvim attached). Drive everything over RPC per `method.md`.

---

## 1 — Every view is alive, and says what it awaits

`Surfaces#prime`'s own docstring states the principle: prime every view so "an idle session that
shows no buffers reads as 'broken' (the first manual verification pass stumbled exactly there)".

```bash
S=$XDG_RUNTIME_DIR/lain/nvim-<hash>.sock
nvim --server "$S" --remote-expr "join(map(getbufinfo({'buflisted':0}), {_,b -> b.name.' ('.b.linecount.')'}), '\n')"
for b in journal timeline workspace inbox approval diff review; do
  echo "== lain://$b =="; nvim --server "$S" --remote-expr "join(getbufline(bufnr('lain://$b'), 1, 5), '\n')"
done
```

Expected placeholders: `(no reminders)`, `(no questions pending)`, `(no approvals pending)`,
`(no requests yet)`, and — since T18 — **`(no streamed tool output yet)`** for `lain://journal`,
which was the one view priming to a bare empty line. An empty `lain://journal` at rest is now the
regression, not the status quo.

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
for b in timeline request diff journal; do
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

Expected banner: `walk it in lain://review; <CR> opens a row, :LainNote annotates,
:LainReviewVerdict approve hands it back`.

Then, over RPC, verifying focus at every step:

```bash
nvim --server "$S" --remote-send ':tabnext 3<CR>'    # the review tab
nvim --server "$S" --remote-send ':1wincmd w<CR>'    # the sidebar
nvim --server "$S" --remote-expr 'bufname()'         # MUST print lain://review
nvim --server "$S" --remote-send '2G'
nvim --server "$S" --remote-send '<CR>'              # opens sidebar | OLD | NEW
```

After `<CR>` the tab holds **three** windows and **focus lands in NEW**, where `x` silently does
nothing because the buffer is `nomodifiable`. Go back to window 1 before every gesture.

Check, in order:

- `x` on an opened row redraws `[ ]` → `[x]` **and** acknowledges: `lain: unit-content-v1:<key>… is now reviewed`.
- `x` on a row nothing has opened refuses **by name** and leaves the row unmarked:
  `lain: lain://review line 3 names lib/version.rb, which nothing has read -- open it with <CR> first`.
- `x` on a row with no hunks (an empty file) refuses cleanly:
  `lain: no hunk on lain://review line 1 -- nothing on that row can be marked`.
- `:LainReviewVerdict approve` over a **partially** reviewed changeset refuses, naming the
  unreviewed file and the remedy.
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

An earlier edition of this section said `method.md` "sizes the QA server at 220x50 precisely so
this does not fire", and concluded that a blocking read here meant the window had been resized.
**That premise was wrong: nvim never gets 220 columns.** Measured round 5, on a correctly-sized
bench with no resize, and the row that binds is the one in bold:

| | width | binds? |
|---|---|---|
| tmux server / window | 220 | no -- nvim never gets it |
| the nvim pane -- `lain up` splits the window with chat | 110 | it sets the one below |
| **the message area, `v:echospace` at that pane width** | **98** | **yes** |
| the review tab's three windows | 40 / 32 / 36 | **no** -- `nvim_echo` never reads a window |
| the `:LainReviewVerdict approve` partial refusal | 225 characters | |

`v:echospace` and not `&columns` is the exact ceiling: 'showcmd' reserves eleven cells plus one in
the last screen line, so 110 columns hold 98. Below that a message is echoed and nothing happens;
above it, before T5, the modal fired EVERY time. The contrast confirmed the mechanism is width and
not sizing policy: the short refusal (`lain: no hunk on lain://review line 1 ...`) never blocked.

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

## 5 — The approval surfaces must agree

Force a turn with **two** gated `bash` calls, the first producing streamed stdout (`echo HELLO`
then `echo WORLD` is enough). Then compare all four surfaces for the *second* call:

| surface | check |
|---|---|
| chat pane | does an `<requester> asks: approve …? [y/N]` prompt render at all? |
| chat pane | does typing `y` get **consumed**, or merely echoed? |
| `lain://approval` | does it hold the full command text and the `y approve, n deny` affordance? |
| `.lain/state.json` | `approvals_pending` |
| journal | `approval_pending` with `requester` |

The prompt must **name the requester** (`agent asks:` / `researcher asks:` / `subagent asks:`) —
with `fleet 2` on the status line you otherwise cannot tell a parent from its child. The whole line:

    <requester> asks: approve <tool>(<input>)? [y/N]

**Run this on `--no-nvim` too.** In the cockpit `:LainApprove` is a recovery path; on plain
`lain chat` there is no second surface, and round 4 found that neither `y` nor `/approve` was
consumed — a permanent wedge. The plain path is where this defect is fatal.

### The precondition that decides whether this test tests anything

**T15's cause was not stdin ownership** — three PTY probes ruled that out — **it was a second
consumer of the approval queue.** `Approval::Queue#dequeue` hands each arrival to exactly ONE
waiter. The TTY surface takes the first call and then *leaves the queue* to ask a human, while the
desktop notifier re-parks immediately — so the notifier sat ahead in the waiter FIFO, took the
second call, and held it for `dunstify`'s blocking 300s window. Streamed tool output between the two
calls only changed the timing. The notifier now *sweeps* the parked set and never consumes.

Two consequences for how this section is driven:

- **`--desktop` must be ON and `dunstify` must be on `PATH`, or the bug cannot reproduce.** It is on
  by default (`--no-desktop` silences one run, `LAIN_DESKTOP=0` a whole shell), but the sandbox's
  `PATH` is rebuilt by the shim — so check `command -v dunstify` before the act and **record the
  answer**. With no notifier there is only one consumer, the second prompt renders, and the check
  passes while asserting nothing. That is the most likely way this section produces a false green.
- **A desktop notification must still fire** for both calls. A fix that stopped the wedge by
  silencing notification would pass every check above and remove a feature; confirm two
  notifications, and confirm that answering one on the desktop still decides that call.

Also read the guard's own record: a notifier that dies mid-sweep now journals a **`tty_fault`**
rather than signing a denial as though a person typed `n`. A `denied` decision with no human at the
keyboard is the shape to watch for in the journal.

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
sandbox project, restart the cockpit, and confirm all seven `lain://` buffers still prime.

## 7 — The HUD segments

The prompt line is composed by `PromptComposer` and printed **into** the pane — it is a point-in-time
snapshot in scrollback, not a live widget, so a value that does not tick is not by itself a defect.

What is worth checking:

- At `you>` between turns: `<model> ctx N% idle Ns`.
- At the `human>` prompt of a parked `ask_human`: **the `idle` segment must be absent entirely**
  (a dispatch is in flight, so the segment has nothing to say and elides).
- After a **torn** turn (a provider error, a budget refusal): `idle` must come **back**. A version
  of this fix read `Agent#state` and left the machine parked at `:awaiting_model`, suppressing the
  reading for the rest of the session — silence that is just as dishonest.
- `ctx N%` must agree with `.lain/state.json` `occupancy` and the journal's `compaction_decision`.
