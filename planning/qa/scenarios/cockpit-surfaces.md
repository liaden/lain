# Scenario: the cockpit surfaces (nvim + tmux)

**Why this one exists:** round 4 found **four** of its seven defects here — a frozen timeline, an
approval that never renders, a refusal delivered as a Lua traceback, and a view with no placeholder.
The surfaces are where lain's state becomes something a human can act on, and they have the least
automated coverage of anything in the system: a spec can assert a buffer's *content*, but only a
driver can notice that the buffer disagrees with the pane beside it.

**What it exercises:** `Frontend::Neovim` and its `Surfaces`/`Buffers`/`JournalView`/`RequestBuffer`
projections, the review flow (`/survey` → `<CR>` → `x` → `:LainReviewVerdict`), the **note rail** on
a survey of a dummy app the round writes itself (§4b — kinds, placement order, the keys, the
thread), the approval surfaces (chat prompt, `lain://approval`, `:LainApprove`, and the desktop
notifier that shares their queue), the RPC transport's one-line-per-record contract, and the prompt
composer's HUD segments.

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

**The primed set is seven buffers, and it is not the same as the set of `lain://` names.** At attach
`Surfaces#prime` creates `journal timeline workspace diff inbox request approval`. `lain://review`
is **not** among them — nothing renders it until a `/survey` runs — so iterating it here reads as a
missing buffer every time and teaches a driver to ignore the one check this section is:

```bash
S=$XDG_RUNTIME_DIR/lain/nvim-<hash>.sock
nvim --server "$S" --remote-expr "join(map(getbufinfo({'buflisted':0}), {_,b -> b.name.' ('.b.linecount.')'}), '\n')"
for b in journal timeline workspace diff inbox request approval; do
  echo "== lain://$b =="; nvim --server "$S" --remote-expr "join(getbufline(bufnr('lain://$b'), 1, 5), '\n')"
done
```

Expected placeholders: `(no reminders)`, `(no questions pending)`, `(no approvals pending)`,
`(no requests yet)`, and — since T18 — **`(no streamed tool output yet)`** for `lain://journal`,
which was the one view priming to a bare empty line. An empty `lain://journal` at rest is now the
regression, not the status quo.

**`lain://approval` is the newest of the seven and the reason this loop was corrected.** It used to
be absent until the first pending parked, which made "the buffer is not there" and "there is nothing
pending" indistinguishable — and `method.md`'s rule about reading it before answering a blind
approval depended on telling them apart. It is now primed at attach holding `(no approvals pending)`,
and because the runtime opens its window only when it has rows, **priming it takes no window**:
`getbufinfo` must find it while the tab layout is unchanged. A `lain://approval` window on screen at
rest is the over-correction to watch for.

It is also deliberately *not* in the runtime's `LainAttach` buffers payload — the runtime creates it
itself — so a config iterating that payload still sees six names. Six there and seven here is
correct, not a discrepancy.

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

**Record the nvim version beside this result, because one axis of the fix needs 0.11.** The rail
suppresses the hit-enter prompt by swapping `'messagesopt'`'s `hit-enter` item for `wait:0` while it
writes the unfolded sentence to `:messages`, and `'messagesopt'` arrived in nvim **0.11**. It is
asked for rather than assumed (`vim.fn.exists("&messagesopt")`) — reading `vim.o.messagesopt` on an
older editor does not return nil, it **raises** `Unknown option`, out of a callback where nvim
appends the very `stack traceback:` this rail exists to keep off a human's screen.

So on nvim 0.10 the rail **degrades rather than errors**: it echoes the fitted line *with* history
instead of recording the unfolded original beside it. What that costs is the untruncated tail in
`:messages`, and nothing else — no paging, no traceback, and `:messages` still holds what the human
was shown. Two consequences for driving this section:

- the no-paging and no-traceback checks apply on **every** supported nvim, and a failure of either
  is a finding regardless of version;
- the "**the full sentence survives in `:messages`**" check applies only on **0.11+**. On 0.10 the
  truncated form in `:messages` is the documented degrade, not a regression — so `nvim --version`
  belongs in the record, or that reading cannot be interpreted.

Every refusal lain itself ships is inside the 80-column bar
(`spec/refusal_width_discipline_spec.rb`), so the degrade is reachable in practice only through a
sentence carrying an unbounded interpolated field — a quoted `Lain::Error#message`, a path, a
docent's exception. Which is exactly what the `:LainReviewVerdict` partial refusal below is.

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
nvim --server "$S" --remote-send '<CR>'                 # opens sidebar | OLD | NEW
```

**The OLD window is empty and that is correct here** — a corpus has no base (`old_start`/`old_count`
are fixed at `0,0`, every line carries its `+`), so there is nothing to diff against. Note it and
move on; it is §4b's expected state, not a defect. Whether it should be *drawn* that way is a
separate question and a separate finding.

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

## 5 — The approval surfaces must agree

Force a turn with **three** gated `bash` calls, the first producing streamed stdout (`echo HELLO`,
`echo WORLD`, `echo AGAIN` is enough). Two is the historical minimum — it is what reproduced the
wedge — but three is what the notifier checks below need, and one turn can serve both. Compare all
the surfaces for the *second* call:

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
second call, and held it for `dunstify`'s blocking 300s window.

**Two separate things have since been fixed there, and a driver needs both in mind.** The notifier
sweeps the parked set and **never consumes** it (T15) — that is what unwedged the second prompt. And
the sweep no longer **blocks**: it used to spawn one shellout and immediately park the fiber on
`Thread::Queue#pop`, so element *N+1* was unreachable until element *N*'s `dunstify` exited, which
is why "it notifies every approval" was true of the design and false of the code. The shellout thread
now only runs the command and pushes its result; the sweep drains finished results and applies each
verdict itself, on the reactor fiber. So **every parked approval raises its own notification at
once**.

Three consequences for how this section is driven, and the third is new:

- **`--desktop` must be ON and `dunstify` must be on `PATH`, or the bug cannot reproduce.** It is on
  by default (`--no-desktop` silences one run, `LAIN_DESKTOP=0` a whole shell), but the sandbox's
  `PATH` is rebuilt by the shim — so check `command -v dunstify` before the act and **record the
  answer**. With no notifier there is only one consumer, the second prompt renders, and the check
  passes while asserting nothing. That is the most likely way this section produces a false green.
- **⚠️ The house model cannot produce this shape, and round 6 burned turns discovering that.**
  `qwen3-coder:30b` does **not** emit parallel tool calls: asked explicitly, twice, for three
  `bash` calls as three `tool_use` blocks in one message, it emitted them strictly one per turn, so
  two pendings never coexist and the check below asserts nothing. The single-pending path and the
  withdrawal path *are* drivable and were verified; **the "all at once" property was not, and
  remains an open half of F24.** Before spending turns here, check whether the model in use does
  parallel tool use at all — and if it does not, say so in the findings rather than reporting the
  section passed. Settling it properly needs a seeded multi-pending fixture or a model that batches;
  that fixture does not exist yet and is worth building.
- **Drive THREE gated calls in one turn, not two, and expect three notifications at once.** Two
  cannot tell "raises concurrently" from "raises the next one as soon as the first is answered" —
  the old behaviour would show a second popup the moment you answered the first, which looks
  identical to a pass if you only ever look at two. With three, all three must be on screen
  *together*, before any of them is answered. Answering one on the desktop must decide that call and
  leave the other two undecided.
- **Answering elsewhere must WITHDRAW the popup.** Answer one of the three at the chat prompt or
  through `:LainApprove` instead of on the desktop. That pending's notification must disappear on
  its own, and the other two must stay up:

      dunstctl count displayed     # 3 before, 2 shortly after the sibling answers

  The sweep runs every **50 ms** and closes a raised popup whose pending reports `decided?`, so the
  withdrawal lands about that long after the answer, not on the next turn. Correlation is a
  self-assigned replace id (`dunstify -r <id>`, allocated at or above 1,000,000 so it can never
  collide with the human's own notifications) and the close is `dunstify -C <id>` through the same
  binary — so a desktop with `dunstify` can always withdraw, with no dependency on `dunstctl` being
  installed.

**Why the withdrawal is load-bearing rather than a nicety, which is worth knowing before judging a
stale popup as cosmetic.** The queue's window is 300 s and this dunst is configured with
`idle_threshold = 120`, which **pauses expiry entirely** while nobody has touched the keyboard —
and an unanswered approval is, by construction, an idle desktop. So in the only case this surface
exists for, an un-withdrawn popup never expires at all, and once the shellout is reaped nothing left
in the system can close it. A popup still naming a command that was already decided is therefore a
real finding here, not a cosmetic one.

**And the degrade must hold.** A desktop where the close fails or closes nothing must leave the
surface exactly as it was — a stale popup is a worse UX, but a notifier that *raises* out of a
withdrawal is a session with no desktop approvals at all. Failures are journalled by the sweep, not
dropped; check the journal rather than assuming silence means success.

Also read the guard's own record: a notifier that dies mid-sweep now journals a **`tty_fault`**
rather than signing a denial as though a person typed `n`. A `denied` decision with no human at the
keyboard is the shape to watch for in the journal.

## 5b — Command dispatch at the `human>` prompt

**New in round 6 (F27), and uncovered before it.** Every other section here drives the `you>`
prompt; this one drives the *other* prompt, which appears whenever a subagent parks a question.

Spawn a subagent (`method.md`, "Making a session with `message` and `child_turn` records") and wait
for the prompt to become `human>`. Then, at that prompt:

| input | expected |
|---|---|
| `/inbox` | renders the parked question and its reply affordance |
| `/mode` | renders the posture, exactly as at `you>` |
| `/status` | renders status |
| `/ruby 1+1` | prints `2` |
| ordinary prose | delivered to the subagent as the answer |

**What round 6 actually found: only `/inbox` is honoured.** The rest are packaged as the human's
answer and shipped to the subagent, silently — no refusal, nothing rendered. The journal is where
this is unambiguous, so read it rather than the pane:

```bash
ruby -rjson -e 'File.foreach(ARGV[0]){|l| r=JSON.parse(l) rescue next; next unless r["type"]=="message"
  puts "#{r["ts"]} from=#{r["from"].inspect} payload=#{r["payload"].to_s[0,120]}"}' "$LAIN_QA_JOURNAL"
```

A `payload={"answer" => "/ruby …"}` line is the defect, reproduced. **A refusal naming the command
is an acceptable outcome too** — the requirement is that a command is either dispatched or refused,
never forwarded as content. Forwarding is what makes it a silent failure in a codebase whose stated
premise is that unknown values fail loudly, and what puts operator text into a subagent's context,
which on a study bench corrupts the record being studied.

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

Drive it against **two parked approvals**, matching the integration check's own wording:

1. Force two gated calls so two rows exist in `lain://approval` (§5's three-call recipe works;
   answer one to leave two, or just read both before answering either).
2. Before touching anything: both rows' first lines should read `foldclosed(<line>) == <line>`
   (closed, showing the one-line summary — `<requester> asks: approve <tool>(<input>)? [y/N]` per
   §5) and `foldclosedend(<line>)` should be past it (the full command and any other detail lines
   are hidden beneath).
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
