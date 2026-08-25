# Pairing session: `/survey` over lain itself, on the cloud arm — 2026-08-25

**Shape:** you drive the review; I sit beside it reading state. Not a `manual-qa` round — that
skill owns a procedure where the driver *is* the agent, and here the human is. What it borrows
from `planning/qa/` is the discipline (`method.md`) and two scenarios' checks
(`cockpit-surfaces.md` §4/§4b, `ollama-cloud-arm.md` §1–§5); what it does not borrow is the
sandbox, because the subject is **this repository, with your uncommitted work in it**.

That last clause is the whole risk budget. §1 is about nothing else.

## Order of operations — the scenario runs FIRST, and not by you

`/survey` had no scenario of its own; its coverage was scattered across `cockpit-surfaces.md` §4 and
§4b, and the parts nobody had driven were the parts nobody owned. There is one now:
**[`planning/qa/scenarios/survey.md`](qa/scenarios/survey.md)**, registered in the QA README and in
the regression gate.

**Run it before this session, agent-driven, on the LOCAL arm** — `/manual-qa survey`. It is cheap,
it spends no quota, and its §1–§6 are exactly the refusal paths a human should not be discovering by
hand at the same time as they are trying to read code. Fix what it finds, then pair.

The split is deliberate and worth stating so neither document drifts into the other:

| | `qa/scenarios/survey.md` | this session |
|---|---|---|
| driver | the agent, from the skill | you, at the keyboard |
| provider | **local** `qwen3-coder:30b` | **`ollama-cloud`** |
| subject tree | lain's `lib/` for scale, a planted tree for §4 | lain's `lib/`, for real |
| what it answers | does the command refuse honestly, admit correctly, and reach a model at all | is a survey of this size **worth doing** — and does the cloud arm hold up under one |
| output | findings | **your review notes**, plus findings |

So the cloud arm is only here. The scenario stays free and stays runnable after every chunk;
this session is the one that spends.

---

## 0 — What `/survey` already has, and what it does not

Asked because it changes what this session is worth. It is not a first drive; it is a first drive
of the three things that were always deferred.

| | driven? | where |
|---|---|---|
| `/survey` mechanics — banner, `<CR>` three-window split, `x` marks and its three refusals, `:LainReviewVerdict` approve + `review_verdict` journalling | **yes, thoroughly** | round 7 survey supplement (2026-08-20) §4; re-checked rounds 8, 9. Every check PASSed. |
| The note rail — `<leader>Ln`/`Lq`/`Lb`, right-aligned markers, **placement order** on `:LainNoteDone` | **once** | round 7 supplement §4b, the section's only drive ever. Its central check (placement order 5, 9, 2, 3) passed; it produced F30, F33. |
| The **docent thread pane** (`<leader>Lt`) — *the only part of a survey that spends a model call* | **never, end to end** | round 7 hit F32 (nothing in `lib/` wired a `Docent`) and was refused before a provider. F32 was since fixed at 2 of 3 sites. Rounds 8, 9 and 10 each **dropped** the thread pane; `planning/qa/README.md` and round 10's coverage table call it **"3rd round owed"**. |
| `/survey` against a tree of **real size** | **never** | every drive so far was a 3–4 file dummy app (`tally`, `counter`/`greeter`/`version`). See §2 — lain's own `lib/` is an order of magnitude past both ceilings, and the refusal that fires there has never been read by a human on a tree it actually fired on. |
| `--provider ollama-cloud`, anything | **never** | the scenario was written 2026-08-24 (`a0c857d0`), round 10 closed 2026-08-23. |

So three axes are new at once, which is the argument for the ordering in §3–§5 rather than
opening a survey and seeing what happens.

---

## 1 — The rules that keep your work

Two different things can be lost here and they have nothing to do with each other.

### 1a. Your source files

**The NEW window in a review split is the real file, and it is modifiable.** `47_diff.lua:188`
sets `buftype` to `""` when the file is readable, precisely so LSP and treesitter attach. `x` —
the key the survey banner teaches — is vim's delete-character there. Round 7 filed this as F34
and the fix moved *focus*, not modifiability.

- **Mark only from window 1.** `:1wincmd w` first, every time. If you are unsure which window
  you are in, ask me and I will read `bufname()` over the RPC rather than guessing from the pane.
- **`<C-w>l<C-w>l` reaches NEW** (slots are sidebar | OLD | NEW). Editing there is legitimate and
  is one of the things this session is for — just never with the sidebar's vocabulary in your
  fingers.
- **Work on a branch.** `git switch -c survey/dogfood-2026-08-25` before the cockpit comes up, so
  an accidental edit is a diff you can read rather than an archaeology problem. I will snapshot
  `git status --porcelain` and `git stash list` at start and re-read them at each checkpoint.
- **Nothing else may be running.** `pgrep -cf 'mise/installs/ruby/[0-9.]*/bin/parallel_rspec'`
  must read 0 and `pgrep -f '[p]re-commit'` must be empty — pre-commit autostashes repo-wide, so
  a hook firing in another worktree will make your tree lie to you mid-review. I run this check
  before we start and before any commit.
- **Do not run the suite while a survey is open.** Two reasons that compound: the known trap
  (a read during a run can miss edits already on disk) and buffer staleness — a survey's rows
  are anchored to the bytes at walk time, so a `rake compile` or an autocorrect underneath it
  silently un-anchors every note.

`.lain/state.json` lands in the launch cwd (round 9's F50, unfixed) — harmless here, `/.lain/` is
in `.gitignore` already. Verified today.

### 1b. Your notes

A note is an **extmark** until you press `<leader>LN` (`:LainNoteDone`). It is not persisted
before that, no autosave reaches it, and a crash takes every unfiled note with it. Worse for a
pairing session: **a successful handback acknowledges nothing and erases its own markers**
(F33) — so a screen with no markers means either "filed" or "lost" and looks identical.

The rule that resolves it: **hand back per file, and I confirm from the journal, not the screen.**

The journal is the only store. There is no `/survey-submit`: a corpus has no pull request under
it, so `/review-submit` answers `Outbox::Nowhere` (and, per F56, does it in the local-branch's
wording, calling your survey a branch — expected, not a new defect).

```bash
# The chat's journal. This directory is EMPTY today — lain has never been chatted
# from its own root — so "newest file here" is unambiguous for the whole session.
J=$(ls -t ~/.local/state/lain/sessions/90e709ee23c9/*.ndjson | head -1)

# What you have actually filed, in placement order:
jq -c 'select(.type=="annotation_placed") | {kind,path,line,side,text,drifted}' "$J"

# The rest of the record:
jq -c 'select(.type|test("changeset_opened|hunk_marked|review_verdict"))' "$J"
```

`90e709ee23c9` is `sha256(realpath("/home/tara/dev/lain"))[0,12]`, computed today. If you launch
from a subdirectory the hash changes — I will re-derive it rather than reuse this one.

**At every checkpoint I will dump `annotation_placed` to
`planning/survey-notes-2026-08-25.md` outside the journal**, so your comments survive the journal
too. That file is the deliverable of the session; the findings doc is the by-product.

---

## 2 — The tree is too big, and that is the first finding

Bounds refuses past **300 files** or **30,000 rendered lines** (`review/bounds.rb:72,84`). Measured
today, over `git ls-files` (which is what `Survey::Walk` itself shells to, so these are the exact
numbers the walk will see):

| target | files | lines | verdict |
|---|---:|---:|---|
| `lib` | 742 | 161,963 | **refuses**, ~2.5x files and ~5.4x lines |
| `lib/lain/frontend` | 52 | 13,578 | fits |
| `lib/lain/review` | 45 | 10,722 | fits |
| `lib/lain/tools` | 33 | 7,481 | fits |
| `lib/lain/cli/command` | 23 | 2,717 | fits |
| `lib/lain/context` | 16 | 1,709 | fits |
| `lib/lain/agent` | 11 | 1,417 | fits |
| `lib/lain/survey` | 9 | 1,343 | fits |
| `lib/lain/provider/ollama` | 9 | 1,720 | fits |
| `lib/lain/sensitivity` | 5 | 1,026 | fits |

**Drive `/survey ./lib` first anyway, deliberately, and read the refusal** (the scenario's §2 owns
this check; if it has already run, you are confirming rather than discovering). `Bounds`'
`cumulative_advice` composes a sentence naming a narrower scope *only when that scope actually
fits* — code with a real argument behind it (`bounds.rb:44-57`) that no human has ever read
firing on a tree it was written for. What it says, and whether the scope it names is one
`/survey --scope` can accept, is check one. Costs nothing.

Then the ladder, smallest first, so a defect surfaces on nine files rather than fifty-two:

1. **`lib/lain/survey`** (9 files) — the subject reviewing itself. Small enough to read whole.
2. **`lib/lain/review`** (45 files) — the tier that owns the surface you are standing in.
3. **`lib/lain/frontend`** (52 files) — only if 1 and 2 stayed quiet; it is the largest that fits
   and the one most likely to find a ceiling behaviour at the margins.

`--unbounded` exists and lifts two of the three ceilings. **Do not reach for it before step 1
above has been read** — the refusal is the check, and lifting it first spends the only chance to
see it fire honestly.

One known-wrong thing to expect and not file twice: F37's residue. A row is drawn with its
leading `../` climb stripped, so a surveyed tree sharing a partial ancestor with the chat's cwd
draws `lib/greeter.rb` indistinguishably from a row inside the project. Surveying `./lib` from
the repo root avoids it entirely; an absolute path does not.

---

## 3 — Bring up the cloud arm (free half first)

`ollama-cloud-arm.md` §1–§4 cost **nothing** and are the launch-level refusals. Run them before
the cockpit, because a refusal that fires correctly at 3am is worth more than the survey and
because a broken key here otherwise surfaces as a chat pane that dies at attach.

`lain` is not on `PATH`. Per `method.md`: **launch by absolute path through a shim** — a relative
`bundle exec ./exe/lain up` leaves `$PROGRAM_NAME` relative and the chat pane exits 127. I will
write the shim to the scratchpad and hand you the path.

```bash
# §1 — three refusals, at construction, one clean line each, no backtrace.
# NOTE: .envrc exports OLLAMA_API_KEY, so `env -u` is required for the first one
# to test anything at all.
env -u OLLAMA_API_KEY LAIN_PREFLIGHT=1 <shim> chat --provider ollama-cloud
LAIN_PREFLIGHT=1 <shim> chat --provider ollama-cloud --api-base http://ollama.example
LAIN_PREFLIGHT=1 <shim> chat --provider ollama --summarizer-provider ollama-cloud \
                             --api-base http://127.0.0.1:11434
```

Check the *wording*, not the exit code: the missing-key line must name `OLLAMA_API_KEY`, where to
get one, **which flag asked for it**, and the tmux-environment hint; the plaintext line must say
why https is required in the arm's own terms; the third must name `--summarizer-provider`, not
`--provider`.

§2 (the key never reaches a host it did not choose) and §3 (the window resolves **128,000,
published, authoritative** — not 8,192 `guessed`) are the other two free checks. §3 matters for
this session specifically: a `guessed` denominator makes `Compaction::Source` decline
`:approaching_window` entirely, and a survey of fifty files is exactly the shape that would
otherwise need it.

**Then the cockpit.** `--provider` is a *chat* flag, so it goes after the separator:

```bash
<shim> up /home/tara/dev/lain -- --provider ollama-cloud
```

Default cloud model is `gpt-oss:20b-cloud` (`ollama_tier.rb:163`) — the smallest published cloud
tag and the one the arm was measured against. **Do not pass `--num-ctx`**: on the cloud arm it
drops window resolution back to `guessed` regardless of the table (a recorded asymmetry, not a
bug to file), which would undo §3.

Sizing, before any pane exists — at 80x24 nvim hits its hit-enter prompt and the RPC attach
deadlocks:

```bash
tmux new-session -d -s bootstrap -x 220 -y 50; sleep 0.5
tmux set-option -g default-size 220x50
tmux show-options -g default-size     # must print the value, not an error
```

---

## 4 — The session loop

The order is chosen so the free checks all land before the first token is spent, and so the
never-driven thread pane is reached with everything under it already known-good.

**Act 1 — the refusal (free).** `/survey ./lib`. Read the ceiling sentence. §2.

**Act 2 — open the real one (free).** `/survey ./lib/lain/survey`. Expect the banner naming
`lain://review` and 9 files at cumulative scope. I read the `changeset_opened` record and confirm
the file list matches `git ls-files` exactly — a listing short by one with no withholding note is
the silent narrowing the whole secret boundary exists against.

**Act 3 — read and mark (free).** This is the part that is actually a code review. `<CR>` from
the sidebar, read in NEW, `:1wincmd w` back, `x` to mark. I watch `hunk_marked` land per row.

**Act 4 — annotate (free).** `<leader>Ln` / `Lq` / `Lb` as you read. Place at least one
**`blocker`** — it is the only kind a verdict policy reads, and driving it is the only end-to-end
demonstration that the kind reaches the policy rather than merely being journalled correctly.
Hand back with `<leader>LN` **per file**; I confirm each batch from the journal in placement
order, since the screen will tell you nothing (F33).

**Act 5 — the thread pane (spends ~1 completion each).** `<leader>Lt` on an anchored line, type a
question below the conversation, `:w`. **This is the third round owed and the reason to do this
at all.** Three checks, in this order:

1. the answer renders **in the thread pane**, not in the chat;
2. a second `:w` with nothing new typed **refuses in words** — the `(anchor id, question text)`
   guard, whose whole purpose is that a duplicate is a duplicate provider call and real money;
3. text typed *after* the answer still sends.

Expect trouble at 2. Round 7 found the thread pane's `BufWriteCmd` refusals are `error()`d —
`stack traceback:`, a blocking `Press ENTER` modal, **and an nvim RPC that hangs until killed**
(F31, measured: two `nvim --server` calls timed out at 120s each). It was never re-driven, so we
do not know whether it is fixed. If the RPC goes dark, that is the finding and I will say so
rather than debugging the harness.

Budget: **under ten completions** for the whole session, per the scenario. Each thread question
is one spawn.

**Act 6 — the verdict (free).** `:LainReviewVerdict approve`. With a blocker unanswered it must
refuse *over the blocker*, not over unreviewed files. Answer the blocker with a note on the same
line; the approve then lands, acknowledges, and journals `review_verdict` with a
`survey-corpus-v1:` digest. Check both — a version shipped that journalled correctly and said
nothing.

**Act 7 — the WAL (free, reading only).** `ollama-cloud-arm.md` §5: a completed round trip leaves
**one frame marked complete carrying the response bytes**. An empty-but-complete frame is
invisible to a frame count; read the bytes. Failed attempts leaving empty aborted frames are the
retry envelope working.

---

## 5 — What I do while you read

I am not driving nvim. I am reading state and answering "is that expected", from:

```bash
tail -f "$J" | jq -c 'select(.type|test("annotation|hunk|verdict|changeset"))'
nvim --server "$S" --remote-expr "execute('messages')" | tail -20   # refusal delivery
nvim --server "$S" --remote-expr 'bufname()'                        # which window you are in
tmux list-panes -a -F '#{pane_width}x#{pane_height}'                # the cheapest RPC-hang cause
git status --porcelain                                              # your tree, at each checkpoint
```

Standing rules for me, this session:

- **I do not edit files in `lib/` while a survey is open.** If a fix is obvious I write it to the
  findings doc and we apply it after the round closes.
- **I do not run `rake pspec` while the cockpit is up** (§1a).
- **I do not commit anything without asking**, and never while a survey holds notes unfiled.
- A refusal with `stack traceback:` is **always** a finding, regardless of how good the sentence
  is. A refusal delivered as a clean `lain:` line is a pass even if the wording is poor — those
  are separate findings at separate severities.

## 6 — Output

- `planning/survey-notes-2026-08-25.md` — **your** comments, extracted from the journal, the thing
  §1b exists to protect.
- `planning/qa-findings-round11-survey-2026-08-25.md` — findings, in round 7's supplement format
  (id, severity, one line; then reproduction and mechanism). Numbering continues from **F66**.
- Two scenario updates this session can settle, if it gets that far: `cockpit-surfaces.md` §4b's
  thread pane stops being "owed", and `ollama-cloud-arm.md` gets its first driven record.

**It does not consume round 11's rotation slot.** Per `planning/qa/README.md` that slot is
`rails-blog`, which is still the only scenario driven zero times end to end. This is a supplement,
the way round 7's survey pass was.
