# Scenario: the cockpit surfaces (nvim + tmux)

**Why this one exists:** round 4 found **four** of its seven defects here — a frozen timeline, an
approval that never renders, a refusal delivered as a Lua traceback, and a view with no placeholder.
The surfaces are where lain's state becomes something a human can act on, and they have the least
automated coverage of anything in the system: a spec can assert a buffer's *content*, but only a
driver can notice that the buffer disagrees with the pane beside it.

**What it exercises:** `Frontend::Neovim` and its `Surfaces`/`Buffers`/`JournalView`/`RequestBuffer`
projections, the review flow (`/survey` → `<CR>` → `x` → `:LainReviewVerdict`), the approval
surfaces (chat prompt, `lain://approval`, `:LainApprove`), and the prompt composer's HUD segments.

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
`(no requests yet)`. **`lain://journal` is the one view that primes to an empty line**, and it is
also named misleadingly — it renders `Telemetry::ToolOutput` (streamed tool bytes) only, never the
NDJSON session journal. Confirm it populates the moment a streaming tool runs, and stays empty
otherwise.

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
attaches` until something clears it. Confirm whether it is still on screen *after* attach has
demonstrably succeeded (i.e. while `lain://request` is live beside it). A message that contradicts
the buffers next to it is the first thing a reader concludes the cockpit is broken from.

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
with `fleet 2` on the status line you otherwise cannot tell a parent from its child.

**Run this on `--no-nvim` too.** In the cockpit `:LainApprove` is a recovery path; on plain
`lain chat` there is no second surface, and round 4 found that neither `y` nor `/approve` was
consumed — a permanent wedge. The plain path is where this defect is fatal.

## 6 — The HUD segments

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
