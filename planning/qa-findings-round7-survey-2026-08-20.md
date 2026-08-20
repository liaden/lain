# QA round 7 (survey supplement) — 2026-08-20

**Scope:** `cockpit-surfaces.md` **§4 (the review flow)** and **§4b (notes on a survey, on a tree you
control)** — the two sections `/survey` owns and which rounds 4, 5, 6 and 7 all skipped. §4b had
never been driven by anyone. Nothing else in the scenario file was driven.

**Sandbox:** `~/tmp/lain-qa-survey-2026-08-20`, tmux `-L lain-qa-survey-2026-08-20` (separate from
round 7's), left in place as evidence. nvim **v0.12.4** (so the 0.11+ `'messagesopt'` leg of the
refusal rail is live and the `:messages`-holds-the-unfolded-sentence check applies). Model
`qwen3-coder:30b` via the `/mnt/nvme` ollama, `OLLAMA_CONTEXT_LENGTH=32768`, `OLLAMA_KEEP_ALIVE=5m`,
`OLLAMA_NUM_PARALLEL` unset. `LAIN_DESKTOP=0` verified in all three panes' `/proc/<pid>/environ`.
**Not one model call was spent** — the only act that would have (§4b's thread question) is refused
before any provider is reached (F32), so the whole round is RPC and free.

## Summary

The **mechanics** of §4 and §4b are in good shape and several of them are genuinely impressive: the
banner is byte-for-byte what §4 predicts; every one of §4's five mark/verdict refusals fires with the
exact sentence written down, unmarked row and all; `:LainReviewVerdict approve` both acknowledges
*and* journals `review_verdict` with its `changeset_digest`; the T5 refusal rail folded a 60-line
refusal onto one fitted line with no `-- More --` and the whole 60 lines in `:messages`; and §4b's
**central check passed** — four notes placed at lines 5, 9, 2, 3 arrived in the journal in exactly
that PLACEMENT order, not positional order, with `drifted` present on every one.

What is new is that **round 4's F22 shape is alive in two more places**, and both are reached by
following §4b's own instructions. `:LainNoteDone` over an unsaved review buffer, and the thread
pane's `:w` with nothing new typed, each answer with an excellent sentence delivered as a Lua
`error` — `stack traceback:` and a blocking `Press ENTER` modal that takes the nvim RPC down with
it (measured: two `nvim --server` calls timed out at 120s each). §4 says T16 fixed `:LainNoteDone`'s
delivery; it fixed the leg that talks to Ruby and not the leg that refuses before it.

Beyond that, §4b's model half is **unreachable in any shipped path** — nothing in `lib/` ever
constructs a `Review::Docent` — and the successful note handback is completely silent, which is the
same defect shape `Review::Surface.acknowledge` was written to remove one rail over.

| id | sev | what |
|---|---|---|
| **F30** | **HIGH** | `:LainNoteDone` over an unsaved review buffer refuses with a `stack traceback:` and a `Press ENTER` modal that blocks the nvim RPC — `settled()` is called outside the `pcall` T16 added |
| **F31** | **MED-HIGH** | the thread pane's `BufWriteCmd` refusals are `error()`d, same traceback + modal + RPC lockup; §4b's own "second `:w` refuses" check is what reaches it |
| F32 | MEDIUM | no code path in `lib/` ever wires a `Review::Docent`, so every thread question is refused before a provider is reached — §4b's whole model half is unreachable (feature gap) |
| F33 | MEDIUM | a successful `:LainNoteDone` acknowledges nothing anywhere and erases its own markers; an empty one is a silent no-op where §4b requires it to say so |
| F34 | MEDIUM | `<CR>` lands focus in the NEW window, which is the real editable file — and `x`, the mark key the banner teaches, deletes a character there |
| F35 | LOW | `blocker` cannot block anything: `Verdict::Policy#admit!` is never handed the annotations, and `approve` settled over an unresolved blocker (feature gap) |
| F36 | LOW | the partial-verdict refusal's remedy names `Lain::Review::Verdict::Policy::Permissive.new`, which no cockpit gesture or `/survey` flag can reach |
| F37 | LOW | `/survey <absolute path>` outside the project root names every row relative to the ROOT, producing sidebar rows that wrap across two lines and cannot be read |
| F38 | LOW | the mark acknowledgement names a truncated content hash rather than the row; a multi-unit row emits one per unit and only the last survives on the message line |
| F39 | LOW | a row with no hunks reads `[ ]` forever, including on a review that has already been approved |

## What §4 and §4b asked for, and what happened

Every line here was measured this round; nothing is inferred.

| check (§) | verdict | evidence |
|---|---|---|
| banner text (§4) | **PASS** | byte-identical: `walk it in lain://review; <CR> opens a row, :LainNote annotates, :LainReviewVerdict approve hands it back` |
| `<CR>` opens sidebar\|OLD\|NEW, focus in NEW (§4) | **PASS** (with F34) | `tabpagebuflist()` → `lain://review` \| `lain://review/OLD/lib/counter.rb` \| `<abs>/lib/counter.rb`; `winnr()` = 3 |
| `x` on an opened row redraws and acknowledges (§4) | **PASS** | `[ ] lib/counter.rb` → `[x] lib/counter.rb`; `lain: unit-content-v1:f2236a996be3... is now reviewed` |
| `x` on an unopened row refuses by name (§4) | **PASS** | `lain: lain://review line 3 names lib/greeter.rb, which nothing has read -- open it with <CR> first` |
| `x` on a hunkless row refuses cleanly (§4) | **PASS** | `lain: no hunk on lain://review line 2 -- nothing on that row can be marked` |
| `approve` over a partial changeset refuses, naming file + remedy (§4) | **PASS** (with F36) | names `lib/greeter.rb`, `lib/version.rb` and the remedy; 225-char sentence fitted to one line, unfolded in `:messages`, `blocking = false` |
| `approve` over a full changeset acknowledges AND journals (§4) | **PASS** | `lain: this review is settled: approve` **and** `{"type":"review_verdict","verdict":"approve","changeset_digest":"survey-corpus-v1:a9f98391…"}` |
| no `stack traceback:` on the §4 rails | **PASS** | `execute('messages')` grep count 0 across every §4 refusal |
| two-line refusal folds, does not page (§4) | **PASS** | displays `lain: aaa / bbb`; `:messages` holds both lines unfolded; `mode = n` |
| 60-line refusal does not raise `-- More --` (§4) | **PASS** | one fitted line `lain: 1 / 2 / … / 60`; `mode = n`, never `rm`; all 60 lines in `:messages` |
| stale rendering stamp is refused (§4) | **PASS**, driven over RPC | `lain_view_generation = 999` → `lain: lain://review never issued rendering 999 -- press again on a drawn row`; `v:null` → `lain: this gesture carries no rendering stamp -- render lain://review first` |
| `/survey <abs path>` opens four rows (§4b) | **PASS** (with F37) | `cumulative scope: 4 files`; rows `Gemfile`, `README.md`, `bin/tally`, `lib/tally.rb` |
| a row opens NON-empty — §4b's stated finding condition (§4b) | **PASS** | `lib/tally.rb` row opened an 11-line buffer at the right absolute path; **no empty row occurred** |
| OLD window empty on a corpus (§4b) | **PASS**, expected | `lain://review/OLD/…` linecount 1, `buftype=nofile`, `nomodifiable`; diff filler drawn beside NEW |
| `<leader>Ln` pre-fills and LEAVES THE CMDLINE OPEN (§4b) | **PASS** | `nvim_get_mode()` → `{'blocking': v:false, 'mode': 'c'}`, `getcmdtype()` `:`, `getcmdline()` `LainNote note ` |
| marker is right-aligned, words not in the margin (§4b) | **PASS** | extmark ns 6: `virt_text_pos: 'right_align'`, `virt_text: [['● note', 'Comment']]`; confirmed visually in `capture-pane` |
| `<leader>Lq` → `● question`, `<leader>Lb` → `● blocker` (§4b) | **PASS** | ns-6 extmarks: line 2 `● blocker`, line 3 `● note`, line 5 `● note`, line 9 `● question` |
| **payload arrives in PLACEMENT order 5, 9, 2, 3 (§4b)** | **PASS** | four `annotation_placed` records at `12:45:25.985 / .993 / 26.001 / .007`, lines **5, 9, 2, 3** in that order |
| `drifted` present, not dropped (§4b) | **PASS** | `"drifted": false` on all five `annotation_placed` records |
| a second `<leader>LN` sends nothing | **PASS** | journal 15 → 15 |
| …**and says so** (§4b) | **FAIL** | F33 — nothing on the message line, nothing in `:messages`, nothing in chat |
| the question reaches the docent (§4b) | **UNREACHABLE** | F32 — `lain: no docent is wired to this review -- nothing was asked and nothing spent` |
| a second `:w` with nothing new refuses in words (§4b) | **PASS in words, FAIL in delivery** | F31 — correct sentence, arriving with a traceback and a modal |
| text typed after the refusal still sends (§4b) | **PASS** | the watermark advanced past the first question; `And what about unicode?` was picked up and delivered on the next `:w` |

---

## F30 — `:LainNoteDone` refuses an unsaved buffer by raising, so the human gets a traceback and a locked editor  (HIGH)

**What is wrong.** `:LainNoteDone` (`<leader>LN`) called with a modified review buffer refuses
correctly and then delivers that refusal as an uncaught Lua `error`, which nvim wraps in
`stack traceback:` and a `Press ENTER or type command to continue` modal. The modal blocks the nvim
RPC as well as the keyboard, so the documented recovery paths (`nv.sh`, reading `lain://approval`,
`:LainApprove`) are all unavailable exactly when a refusal is on screen.

**Mechanism.** `lib/lain/frontend/neovim/runtime/48_annotate.lua:415-423`:

```lua
define("LainNoteDone", function()
  local payload = review_notes.settled()              -- 416: OUTSIDE the pcall
  local taken, refusal = pcall(vim.rpcrequest, chan, "lain_command", "review_notes", { payload })
  if not taken then
    _G.__lain.review_refused(refusal)                 -- 419: T16's fix, one line too late
    return
  end
  review_notes.forget()
end)
```

`settled()` (`:264`) calls `assert_saved()` (`:266`), which raises at `48_annotate.lua:253-254`.
T16's `pcall` covers only the `vim.rpcrequest`, so **the refusal that fires first is the one that is
not caught**.

**Evidence that rules out the innocent explanation.** This is not "any refusal on this rail is
raised" and it is not an nvim-version degrade. The *sibling* refusal on the same command, one line
down, arrives perfectly: when Ruby refuses a batch the message reaches `_G.__lain.review_refused`
and prints as a clean `lain: ` line with no traceback (measured this round on the neighbouring
thread rail's `no docent` refusal, same `review_refused` channel, `mode = n` throughout). And the
whole §4 refusal battery on `:LainReviewVerdict` / the sidebar came back with a `stack traceback:`
grep count of **0**. It is specifically the pre-RPC leg.

**Measured cost.** Two consecutive `nvim --server … --remote-expr` calls returned nothing and were
killed at the 120s and 150s marks; the pane (readable while blocked) held the traceback and
`Press ENTER`. Sending `Enter` to the nvim pane cleared it, the RPC recovered, and — correctly —
every note and every marker was still in place, so nothing was lost but the human's time.

**Reproduction.**

```bash
# in a cockpit with a survey open and a row opened with <CR>
$QA/nv.sh send ':3wincmd w<CR>'          # the NEW window
$QA/nv.sh send '9G'; $QA/nv.sh send '\Lq'; $QA/nv.sh send 'why?<CR>'
$QA/nv.sh send 'ggO# added<Esc>'          # modify the buffer -- see F34, this is trivially easy
$QA/nv.sh send '\LN'                      # HANGS; read the pane with tmux instead
tmux -L "$QA_SOCK" capture-pane -p -t "$NVPANE" | tail -8
```

Captured verbatim (`$QA/records/notedone-traceback.txt`):

```
Lua :command callback: lain: save /…/tally/lib/tally.rb before settling its notes -- an unsaved
edit would be measured as the changeset drifting under your notes, which it did not
stack traceback:
        [C]: in function 'error'
        [string "<nvim>"]:2087: in function 'assert_saved'
        [string "<nvim>"]:2100: in function 'settled'
        [string "<nvim>"]:2250: in function <[string "<nvim>"]:2249>
Press ENTER or type command to continue
```

**Fix shape.** Move `settled()` inside the protected call, or wrap it in its own:

```lua
local ok, payload = pcall(review_notes.settled)
if not ok then _G.__lain.review_refused(payload); return end
```

`assert_saved`'s job is to *stop the settle*, and returning early does that just as well as raising —
nothing here needs `:w` to fail, because `:LainNoteDone` is not a write. What would pin it: an
example asserting that a modified review buffer routes through `_G.__lain.review_refused` and that
`execute('messages')` afterwards contains no `stack traceback:`. The existing specs check the
sentence, which is why this survived.

---

## F31 — the thread pane's `:w` refusals are raised too, with the same modal  (MED-HIGH)

**What is wrong.** Both refusals in the thread pane's `BufWriteCmd` are `error()`s, so a `:w` with
nothing new typed — which is §4b's own documented check — produces a traceback and a blocking modal.

**Mechanism.** `lib/lain/frontend/neovim/runtime/51_thread.lua:604-617`, two sites:

```lua
    if question == nil then
      error("lain: nothing has been typed under the conversation, so there is no question to ask -- " ..
        "write it below the last message and :w again", 0)          -- 610-611
    end
    local ok, err = pcall(vim.rpcrequest, chan, "lain_command", "review_ask", …)
    if not ok then
      error("lain: the question was NOT sent and your text is untouched: " .. tostring(err), 0)  -- 616
    end
```

**Evidence, and the part that makes this arguable rather than obvious.** The module's own comment at
`51_thread.lua:595-599` states the constraint deliberately: *"the rpcrequest goes first and
'modified' is cleared only once it returns, so a question that reached nobody leaves the buffer dirty
with the human's words in it and `:w` FAILS"*. To make `:w` fail you must raise. So `:616` has a real
reason. **`:610` does not** — that branch is reached only when nothing was typed, and this round
measured `&modified` as **0** at that moment, so there is nothing in the buffer to preserve and
nothing for a failed write to protect. It is paying F22's whole price for an invariant it does not
need.

Ruling out the near explanation: this is not the same code path as F30 and not the same fix. The
clean sibling on this very rail proves the channel works here — `lain: no docent is wired to this
review -- nothing was asked and nothing spent` (that is Ruby's refusal, returned rather than raised)
printed on the message line with `mode = n` and no traceback, on the same buffer, seconds apart.

**Reproduction.**

```bash
$QA/nv.sh send '5G'; $QA/nv.sh send '\Lt'      # thread pane on an anchored line
$QA/nv.sh send 'GoIs downcasing correct here?<Esc>'; $QA/nv.sh send ':w<CR>'   # first :w -- clean
$QA/nv.sh send ':w<CR>'                         # second :w, nothing new -- HANGS the RPC
tmux -L "$QA_SOCK" capture-pane -p -t "$NVPANE" | tail -8
```

```
Error in BufWriteCmd Autocommands for "lain://thread/*":
Lua callback: lain: nothing has been typed under the conversation, so there is no question to ask --
 write it below the last message and :w again
stack traceback:
        [C]: in function 'error'
        [string "<nvim>"]:3248: in function <[string "<nvim>"]:3245>
Press ENTER or type command to continue
```

**Fix shape.** `:610` → `_G.__lain.review_refused(...)` then `return`; the write succeeds, which is
correct, because an unmodified buffer written is a no-op. `:616` keeps its raise or, better, refuses
cleanly and sets `vim.bo[ev.buf].modified = true` by hand so the human's words stay dirty without
nvim's wrapper getting involved. Pin with an example asserting no `stack traceback:` in `:messages`
after a nothing-typed `:w`, and one asserting the buffer is still `modified` after a send failure.

---

## F32 — nothing wires a docent, so §4b's model half cannot run at all  (MEDIUM, feature gap)

**What is wrong.** A thread question written into `lain://thread/<id>` and `:w`-ritten is refused
with `lain: no docent is wired to this review -- nothing was asked and nothing spent`, in every
shipped path. §4b's "The thread, and the question that reaches the model" section — the one part of
that section costed as a model call — is unreachable.

**Mechanism.** `Review::Handover#initialize` defaults `docent:` to `Unattended`
(`lib/lain/review/handover.rb:243`), and no caller overrides it. `lib/lain/cli/command/review.rb:239`
says so in as many words: *"No `baton:` and no `docent:`: … **no wiring in this tree constructs a
`Review::Docent`** — so `ask` answers `Review::Handover::Unattended`'s sentence rather than a
silence."* `Command::Survey` follows `Command::Review` in this. The refusal string is
`handover.rb:120`.

**Evidence.** `grep -rn "Docent" lib/` finds the class, its `NOT_WIRED` constant
(`review/docent.rb:208`), the `docent:` keyword default, and that comment — and **zero
constructions**. So this is a documented not-yet-wired seam, not a regression and not a `/survey`
asymmetry.

**Reproduction.** `\Lt` on any anchored line, type below the conversation, `:w`. Refusal is clean and
immediate; no provider call is made (journal unchanged, `ollama ps` never went warm — the whole
round spent zero model calls).

**What this is really a finding about.** §4b is written as though the docent exists, so a future
round will re-derive this. Either the scenario needs a line saying the thread's model half is
pending, or the chunk that wires a docent needs to name §4b as its acceptance driver. Until then the
thread pane is a note viewer with a write gesture that always refuses.

---

## F33 — a note handback acknowledges nothing, and an empty one is silent  (MEDIUM, UX)

**What is wrong.** Two halves of the same gap.

1. A **successful** `:LainNoteDone` says nothing anywhere — not on the message line, not in
   `:messages`, not in the chat pane — while simultaneously **erasing the `● note` / `● blocker`
   markers** the human placed. Four notes went to the journal and the only observable effect on
   screen was that the human's annotations vanished.
2. An **empty** `:LainNoteDone` is a silent no-op. §4b requires "a second `<leader>LN` sends
   **nothing** rather than filing the notes twice, **and says so**". It sends nothing (journal
   15 → 15, confirmed) and does not say so.

**Mechanism.** `48_annotate.lua:422` calls `review_notes.forget()` and returns with no echo on the
success path. On the Ruby side an empty batch is legal and produces nothing —
`lib/lain/frontend/neovim/rpc_thread.rb:594-601`:

```ruby
def self.notes(args)
  return flat(args) unless args.is_a?(Array)
  batch = args.first
  return unbatched(batch) unless batch.is_a?(Array)
  refused_batch(batch) || batch.lazy.map { |note| yield(normalized(note)) }.find(&:itself)
end
```

For `batch == []` both `refused_batch` and the `find` answer `nil`, so nothing is refused, nothing is
yielded, and the lua half reads that as "taken". `unbatched`'s own message (`:610-612`) confirms an
empty batch is deliberately legal — *"even when there is one of them or none"* — so the silence is
the absence of an acknowledgement, not a mis-shaped payload.

**Evidence that this is the known defect shape and not a taste question.**
`lib/lain/review/surface.rb:66` records the identical failure on the neighbouring rail and why it was
fixed: *"`:LainReviewVerdict approve` journaled correctly and acknowledged nothing"*. That rail now
answers `lain: this review is settled: approve` (verified this round). `Surface.acknowledge` exists;
the note rail does not call it.

**Reproduction.** Place any note, `\LN`, then read `execute('messages')` and both panes — nothing new
in any of the three. Press `\LN` again — journal unchanged, still nothing said.

**Fix shape.** Echo through `_G.__lain.review_refused`'s channel on success too (it is the message
rail, not only the refusal rail), e.g. `lain: 4 notes handed back` / `lain: no notes to hand back`.
Pin it the way the verdict rail is pinned: an example asserting the inlet was posted to, not only
that the journal grew.

---

## F34 — `<CR>` lands the cursor in the real file, where the mark key deletes text  (MEDIUM, UX)

**What is wrong.** The two gestures the banner teaches are `<CR>` to open a row and `x` to mark it.
`<CR>` moves focus to the **NEW** window, which holds the real file with `buftype = ""` and
`modifiable = 1`. `x` there is vim's delete-character, and it silently edits the human's source.

**Measured.** `<CR>` on `lib/greeter.rb`, then `x` without moving:

```
line1 before=[# frozen_string_literal: true]  after=[ frozen_string_literal: true]
&modified = 1
```

`u` restored it; the file on disk was untouched because nothing wrote it. But the change survives
until the buffer is closed or written, and a human who has just been taught that `:w` is how the
thread pane works (§4b) is a plausible `:w`-presser.

**Mechanism, and why this is a UX finding rather than a defect.** It is deliberate and well argued.
`lib/lain/frontend/neovim/runtime/47_diff.lua:8-11`: *"THE NEW SIDE IS THE FILE, not a copy of it.
`buftype = ""` is what makes the language server and treesitter attach … A `nofile` copy would
present identically in every other respect and silently lose all of it."* `:188` sets
`buftype = ""` whenever the path is readable. The OLD side is correctly `nofile` + `nomodifiable`
(verified). So the code is doing what it means to; the hazard is the *composition* of that decision
with focus landing there and with `x` being the mark key.

**This also corrects the scenario.** `cockpit-surfaces.md` §4 states: *"focus lands in NEW, where `x`
silently does nothing because the buffer is `nomodifiable`"*. That is false, and it is the kind of
false that keeps a driver from noticing — a future round told `x` is inert there will not check.

**Fix shape (pick one, they are not equivalent).** Bind `x` in the stamped NEW buffer to the mark
gesture (so the key the banner teaches does the thing the banner says, everywhere in the review);
or land focus in the sidebar after `<CR>` rather than in NEW; or leave both and say so in the banner.
The first is the only one that removes the trap rather than documenting it.

---

## F35 — a `blocker` cannot block a verdict  (LOW, feature gap)

`Review::Vocabulary` (`lib/lain/review/vocabulary.rb:73`) says *"`blocker` is the one a verdict
policy can read"*, and §4b leans on that: *"it is the only kind a verdict policy reads, and a
`blocker` that arrived as a `note` is the silent failure the kind-is-required rule exists to
prevent."* No shipped policy reads it.

**Mechanism.** `Verdict::Policy#admit!(verdict, changeset:, marks:)`
(`lib/lain/review/verdict/policy.rb:35`) is never handed the annotations. The only two subclasses are
`EveryHunk` (`:56`) and `Permissive` (`:106`), and neither could consult a blocker if it wanted to.

**Measured, not inferred.** Placed a `blocker` on `lib/tally.rb:2` (`no frozen_string_literal`),
journaled as `"kind": "blocker"`; marked all four rows; ran `:LainReviewVerdict approve`. It settled:
`lain: this review is settled: approve`, `{"type":"review_verdict","verdict":"approve",
"changeset_digest":"survey-corpus-v1:3ef7e189…"}`. No mention of the blocker anywhere.

So the *kind* is carried faithfully end to end — which is the half that has specs — and nothing reads
it. Worth stating because §4b's wording implies a check that cannot currently fail.

---

## F36 — the partial-verdict refusal's remedy is not reachable from the cockpit  (LOW, UX)

The refusal is otherwise exemplary — it names every unreviewed file and what to do:

```
lain: approve is refused over a changeset that is not fully reviewed: lib/greeter.rb is unreviewed,
lib/version.rb is unreviewed -- mark every hunk, or open the session with
Lain::Review::Verdict::Policy::Permissive.new if this run means to judge regardless
```

The first remedy is actionable. The second names a Ruby constructor to a human holding an editor.
`/survey`'s flag set is `--scope` and `--unbounded` only (`lib/lain/cli/command/survey.rb:65,71,77`),
`/review`'s likewise, so there is no gesture, flag or command that reaches `Permissive` from a
running cockpit — it is reachable only by editing wiring code.

Note this is also the sentence that makes the rail's width handling matter: at 225 characters against
a `v:echospace` of 88 it is the one refusal in the whole round that actually needed folding, and the
rail handled it (one fitted line, full text in `:messages`, `blocking = false`).

**Fix shape.** Either add `/survey … --permissive` (and `/review`), or drop the second clause and say
what a human can do — the class name is a debugging aid dressed as advice.

---

## F37 — an out-of-root survey names rows relative to the project root  (LOW, UX)

`/survey /abs/path/outside/the/project` works — four rows, all opening correctly — but every row is
named relative to the chat's project root:

```
[ ] ../tmp/tmp.bGWkpm1dHb/tally/Gemfile
[ ] ../tmp/tmp.bGWkpm1dHb/tally/README.md
[ ] ../tmp/tmp.bGWkpm1dHb/tally/bin/tally
[ ] ../tmp/tmp.bGWkpm1dHb/tally/lib/tally.rb
```

In the review tab's ~40-column sidebar each of those wraps onto two display lines, so the rows read
as eight ragged half-names. The same relative spelling reaches the journal
(`"path": "../tmp/tmp.bGWkpm1dHb/tally/lib/tally.rb"`), which makes an `annotation_placed` record
un-resolvable without knowing which root it was written from.

**Explicitly NOT the failure §4b warned about.** §4b predicts that a row named from the wrong root
"opens an empty buffer for a file that exists", and calls that the finding. **It did not happen** —
`<CR>` opened the 11-line file at the correct absolute path every time. The naming is cosmetic in the
sidebar and a portability question in the journal, not a resolution bug.

**Fix shape.** Name a row relative to the SURVEYED root when the surveyed tree is not under the
project root (the header already prints the absolute path once), and journal an absolute `path` or
a root-plus-relative pair.

---

## F38 — the mark acknowledgement names a content hash, and a multi-unit row emits several  (LOW, UX)

`x` on a row acknowledges `lain: unit-content-v1:f2236a996be3... is now reviewed`. The human just
pressed a key on a row that says `lib/counter.rb` and is answered with twelve hex digits.

A row whose file partitions into more than one unit emits **one message per unit**, of which only the
last is visible on the message line — so the visible acknowledgement for a two-unit row names the
*second* unit and there is no indication a first one existed. Measured: `lib/counter.rb` (16 lines,
2 units) produced two messages and two `hunk_marked` records 6ms apart; `lib/version.rb` (5 lines)
and `lib/greeter.rb` (9 lines) produced one each.

`Surface::Neovim::MARKED` is `"%<hunk_key>s is now %<state>s"`
(`lib/lain/review/surface/neovim.rb:204`), posted per key from `#mark` (`:306`) as `#marked_at`
(`:383`) maps over `resolved.hunk_keys`. The comment at `:207` says the figures "lead with what is
now TRUE of the row", which is the right instinct applied to the wrong noun — the row is the file.

**Fix shape.** One message per gesture naming the row and the count: `lain: lib/counter.rb is now
reviewed (2 hunks)`. `PARTLY_MARKED` (`:214`) already has exactly this shape for the partial case.

---

## F39 — a hunkless row stays `[ ]` on an approved review  (LOW, UX)

`lib/empty.rb` (0 bytes, no hunks) reads `[ ]` in the sidebar before, during and after
`:LainReviewVerdict approve` succeeded over the changeset. So a settled, approved review renders with
a row that says unreviewed, and `x` on that row correctly refuses (`no hunk on lain://review line 2`)
— there is no gesture that changes it.

**Mechanism, and it is documented.** `Marks#state_of` → `tri_state(0, 0)`, and `Marks`'s comment at
`lib/lain/review/marks.rb:203-205` states the rule: *"An empty batch answers `:unreviewed`, which is
`Session::MarkedChangeset::HUNKLESS`'s rule reached rather than restated"*. So the verdict is right
to ignore it (approve settled, as it must) and the marker is right by the stated rule. What is
missing is a fourth marker: `STATE_MARKERS` (`review_view.rb:151`) has `[x]`/`[~]`/`[ ]` and no
"nothing to review here". **Fix shape:** a `[-]` for hunkless rows, or leave the box off entirely.

---

## Withdrawn — nearly filed, and disproved

Each of these looked like a defect for at least one measurement. Recording them so the next round
does not re-file them.

- **"one `x` produced TWO `is now reviewed` messages."** Not a duplicate emit. `lib/counter.rb`
  genuinely partitions into two units at cumulative scope; the journal holds two distinct
  `hunk_marked` records with different `hunk_key`s 6ms apart, and single-unit files
  (`version.rb`, `greeter.rb`) produce exactly one each. The row correctly redrew to `[x]` once.
  What survives is the UX half, filed as F38.
- **"a gesture from a stale `lain_view_generation` is honoured."** Setting the sidebar's stamp from
  8 to 7 and pressing `x` marked the row — which is correct: `ReviewView::Renderings` keeps
  `HELD = 16` renderings resolvable (`review_view.rb:206`), so generation 7 was still a rendering
  the view had issued. The refusals fire where they should: an **unissued** generation (999) and a
  **missing** stamp (`v:null`) both refuse by name. "Stale by one" is the wrong probe for this
  check; §4's step should say *unissued*, not *stale*.
- **"`drifted: false` is wrong on a note whose line moved."** Placed a note on line 9, inserted two
  lines above it, saved, settled: the payload reported `"line": 11, "drifted": false` with
  `anchor_text` still the `sort_by` line. That is the documented semantics —
  `48_annotate.lua:17-24`: drift is *"read the line the mark NOW names and compare it, as text, with
  what that line said when the note was placed"*, and telling "moved" from "changed" is explicitly
  deferred to the drift-model spike. Worth knowing that `(side, revision, path, line)` alone does
  not locate the code once the buffer has moved under the note — `revision` names the survey-time
  revision while `line` is the current row — but the tuple is not claimed to, and `anchor_text` is
  what closes it.
- **"the sidebar row name is wrong so the row will open empty."** §4b's predicted failure. Measured
  four times; it never happened. What is left is F37, which is legibility, not resolution.

## Model behaviour

**None observed, because none was reachable.** Zero model calls were spent this round: the only act
that would have made one (§4b's thread question) is refused at `Handover::Unattended` before any
provider is touched (F32). `ollama ps` never went warm. No `<function=` text, no MODEL-1 restart, no
iteration ceiling.

Worth recording for the next round's budgeting: **§4 and §4b are almost entirely free.** Everything
except the thread question is RPC and journal reads, and §4b's own cost note ("run the note checks
even when the bench has no model up") is correct — with F32 outstanding it is true of the *whole*
section, not just the part above the thread.

## Process notes

- **Isolation held.** `find ~/.local/state/lain -newermt '2026-08-20T12:35:29Z'` → **0**, against
  positive controls of **286** (`-newermt '2026-08-19'`) and **30**
  (`-newermt '2026-08-20T00:00:00Z'`) on the same tree, so the zero is a measurement and not a
  spelling accident. `~/.lain` absent throughout. `$QA/project/.lain/` holds `state.json` and **no
  `config.toml`** — nothing wrote a durable pre-approval, which is expected since no approval was
  ever raised. `dunstctl count displayed` / `waiting` both 0 at close-out. tmux server killed; no
  stray `exe/lain` or sandbox `nvim` processes remain.
- **`method.md`'s env-verification one-liner is easy to mistype into a vacuous pass.** Writing the
  grep as `'^(XDG_|TMPDIR)='` instead of `'^(XDG_|TMPDIR)'` anchors the `=` to the alternation and
  matches **no** `XDG_*` variable at all — it printed only `TMPDIR` and `LAIN_DESKTOP` and read
  exactly like the documented "PANE_ENV forwards `LAIN_*` and nothing else" failure. The sandbox was
  fine. Same family as the `find -newermt` traps already recorded; keep the doc's spelling literally.
- **Panes are 100 columns here, not the 110 `cockpit-surfaces.md` §4 records**, and `v:echospace` is
  **88**, not 98. The table in §4 is a measurement of one bench, not a constant — the 225-character
  partial-verdict refusal still exceeded it, so the conclusion holds, but the numbers should be read
  as an example.
- **A blocking modal really does take the RPC down, exactly as §4 says.** Measured twice this round
  (F30, F31) at the full 120s timeout. `tmux capture-pane` read the pane fine while blocked, and
  `send-keys Enter` to the nvim pane cleared it both times. The documented recovery works; budget for
  it.
- **`nv.sh msgs` splits on backslashes**, so a refusal containing a Windows-ish path or an escaped
  character will come back re-wrapped. Reading `execute('messages')` raw is safer when the exact
  bytes matter.

## What was not reached

- **`:LainReviewDone`** — the third rail named in §4's delivery discussion. §4 and §4b do not ask for
  it directly and it was not driven; given F30 and F31 both live one rail over, it is the first thing
  the next round should check.
- **A git-backed changeset review (`/review`).** Everything here is the **corpus** source: no base,
  `old_start/old_count` fixed at `0,0`, OLD window empty by construction. Whether the same gestures
  behave over a real diff — where OLD has content, hunks are real, and `drifted` can fire against a
  moving base — is untouched by this round and by every previous one.
- **The note keys' stamp-withdrawal behaviour** (§4b's "`<leader>Ln` does nothing in the NEW window /
  the keys are removed on purpose"). Confirmed present (`\Ln \Lq \Lb \LN \Lt` all bound buffer-local
  in a stamped NEW buffer) but the removal-on-withdrawal half was not driven.
- **Notes as diagnostics.** `vim.diagnostic.get()` on the NEW buffer returned **0** after four notes
  were placed and settled; `Review::Projection::Diagnostics` maps kinds to `HINT`/`WARN`/`ERROR`
  (`projection/diagnostics.rb:56`) but nothing this round populated it. Whether that projection is
  for docent findings only, or should also carry the human's own notes, is an open question neither
  scenario section asks.
