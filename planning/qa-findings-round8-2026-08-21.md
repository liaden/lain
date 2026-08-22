# QA round 8 — 2026-08-21

## Summary

**Five scenarios driven, one dropped, one owed.** `session-and-window`, `rust-cli` (including its
deliberate unhappy path and recovery), `bench-arms` and `failure-injection` (§1, §2, §3, §8, §9, §10,
§11a/b/c) all completed. `cockpit-surfaces` was piggybacked on the `rust-cli` subject and covered
§1, §2, §3, §4, §5 (partly), §5b, §6, §7 and §8. **`bowling-ruby` and `rails-blog` were both driven in a
second pass**, at the user's request, after the first pass had missed one and deferred the other —
see "Second pass" below. So round 8 is the **first round to drive all seven scenarios**, and the
first ever to reach compaction at scale.

**The headline is a real approval-surface defect with a controlled comparison, and a live
`provider_wait` record.** F40: once the first parked approval of an ask is answered from the
editor, the chat pane never renders a prompt for any later gated call in that same ask — 11 pendings
answered at nvim produced **1** rendered prompt; 8 pendings answered at the terminal produced **8**.
Separately, `provider_wait` fired in a real session for the first time
(`waited_seconds: 38.894, in_flight: 1`), which both confirms round 7's F28 fix reaching production
**and** puts a number on round 6's F26 starvation — the eager summarizer took the only slot and the
wait is now in the record instead of being invisible.

**Round 7's F29 fix holds, F27 stays withdrawn, F34 and F38 are confirmed fixed, and `:LainReviewDone`
— the README's #1 named gap — passes cleanly.** Four new defects (one MED-HIGH, one MEDIUM, three
UX/LOW), one model finding that contradicts a claim in `method.md`, and four process defects.

| id | sev | what |
|---|---|---|
| **F40** | **MED-HIGH** | after the first pending of an ask is answered from a NON-TTY surface, `ApprovalPolicy#watch` stays parked on its orphaned `tty.prompt` read and no later gated call in that ask ever renders a `[y/N]` prompt in the chat pane |
| **F41** | **MEDIUM** | `ask_human` at stdin EOF journals a `message` record `from: "human"` with `payload: {"answer": ""}` — a human answer nobody gave, indistinguishable from an empty Enter; measured cost, 25 burned iterations |
| F42 | MEDIUM (UX) | `lain://approval` closes the pending row's fold at rest and opens only the key-hints trailer, so the one visible line is a summary truncated to `...` and the command being approved is hidden |
| F43 | LOW (UX) | the blank trailer in `lain://approval` becomes its own closed one-line fold with an EMPTY `foldtext()`, which nvim pads with the `fold:` fillchar — a blank separator renders as a full-width bar of `·` |
| F44 | LOW (UX) | `set_approval` opens the approval window when rows appear and has no close path, so after the first gated call of a session the layout permanently carries a window reading `(no approvals pending)` |
| **F45** | **HIGH** | every `bash` tool call inherits `BUNDLE_GEMFILE` pointing at **lain's own Gemfile** (set in-process by `bundler/setup`, so invisible in `/proc/<pid>/environ`), forcing every child Ruby in the user's project into lain's bundle — `rails`, `rake`, `rspec` and `bundle` all break |
| **F46** | **HIGH** | the per-ask iteration ceiling commits an assistant `tool_use` turn and interrupts before its `tool_result`, leaving a permanently orphaned `tool_use`: compaction is disabled for the rest of the session, occupancy pins at 100%, and the session becomes **unforkable and unresumable** |
| F47 | MEDIUM (UX) | nothing renders that compaction has stopped — `derivation_refused.consecutive` is written and never read in `lib/`, `since_compaction: 201` sits unrendered in `state.json`, and the HUD says only `ctx 100%` |
| F48 | LOW | the torn-head refusal says `cannot resume …` even when the door was `--fork` |
| F49 | MEDIUM | `lain friction`'s `cache_waste` is **vacuous against ollama** for the same reason it is against a mock — ollama has no prompt caching at all — yet `rails-blog.md` §5 calls this "the only scenario that can exercise it honestly" |
| MODEL-2 | model | a literal `<function=` malformed tool call on a **clean** transcript — contradicts `method.md`'s "contaminated transcript" claim; **measured at roughly half of first turns (3 of 6)** on an identical prompt |
| P4–P7 | process | `lain sessions`' last field is not the head digest when a damage note is appended; `method.md`'s `human>` recipe cannot exercise §7's idle-elision check; `cockpit-surfaces.md` §4's mark-acknowledgement text is stale; `pgrep -f` self-match (6th round running) |

---

## Bench and conditions

ollama 0.32.12 (`/mnt/nvme/opt/ollama-0.32.12`, confirmed via `/proc/<pid>/exe`; a pre-existing
server started 07:38 this round reused), qwen3-coder:30b, `OLLAMA_CONTEXT_LENGTH=32768`,
`KEEP_ALIVE=5m`, KV `q8_0`, Vulkan, `OLLAMA_FLASH_ATTENTION=1`.
**n_slots = 1 / `-np 1`**, read from the runner's own argv via `pgrep -P <serve-pid>`, alongside
`-c 32768 -b 512 -ub 512` — so every contention reading here is in scope rather than void.

ruby 4.0.6, nvim **0.12.4**, cargo 1.99.0-nightly, **tmux 3.7b**, server at 220x50 (verified with
`show-options -g default-size` before every launch).

**Machine at round start: NOT quiet, and it is recorded rather than smoothed over.** Load average
2.67; a `mempalace mine` over this very repo pinned a core at **99.2% for 35m46s**; **11 `nvim`
processes** live from other worktrees; one unrelated `tmux -L ctrlc2-…` orphan from another agent's
`ctrlc` work, 1d01h old, left untouched. No `parallel_rspec`, no `pre-commit`. **No timing claim in
this document is a claim about an idle box**, and the two that matter (§2's connect timeouts and
`bench arms`' wall-time) were each taken twice.

Sandbox: `~/tmp/lain-qa-round8-2026-08-21`, XDG redirected, `tmux -L lain-qa-round8-2026-08-21`.
All three panes verified carrying sandbox `XDG_*` **and** `TMPDIR` before act 1 — the positive
control held (four `XDG_*` lines plus `TMPDIR` per pane, not the one-line `TMPDIR`-only shape
`method.md` warns is a mistyped pattern). `~/.lain` absent throughout (still at `~/.lain.bak`).
**No `.lain/config.toml` was ever written** — no durable pre-approval was created by any act.

**Desktop decision: the notifier was OFF for the entire round except ONE named act.**
`LAIN_DESKTOP=0` exported before `tmux new-session` and verified **per pane**
(`/proc/<pid>/environ` count of 1 in all three panes) on every muted launch. The muted portion is
backed by its negative: `dunstctl count displayed` and `waiting` both **0** after acts containing
20 gated calls, and approvals are raised `-u critical` so any that fired would still have been on
screen. The one live act is named in §5 below; it raised exactly one notification, which was
withdrawn on answering elsewhere, and the desktop finished at `0/0`.

**Close-out negative PASSES and is not vacuous.** `find ~/.local/state/lain -newermt
'2026-08-21T12:24:40Z'` → **0**, against a positive control of **348** (`-newermt '2026-08-19'`) over
a tree of 8018 files. The `Z` was kept and the control was run beside it, per P1.

---

## Round-7 defects re-checked

| id | verdict | evidence |
|---|---|---|
| **F29** (`/inbox`'s drain swallows a `/command`) | **FIXED** | Driven per `cockpit-surfaces.md` §5b against a live parked `researcher` question. `/status` at bare `human>` → rendered, journal **579 → 579**, `inbox 1` still. `/inbox` → rendered the question document. `/status` **immediately after** → rendered, journal **579 → 579**, question still parked. Only 2 `message` records existed at that point (the spawn and the question); no `payload={"answer" => "/status"}` anywhere. |
| **F27** (`human>` swallows session commands) | **STAYS WITHDRAWN** | Same run as above; `/status` dispatched normally at `human>` with the journal unchanged. |
| **F28** (capacity-gate telemetry unreachable from production) | **FIXED — and observed firing for the first time in a QA round** | One `provider_wait` record in the main cockpit journal: `{"kind":"waited","endpoint":"http://localhost:11434","waited_seconds":38.894,"resolution_seconds":0.05,"in_flight":1}`. See "F26, measured" below. |
| **F34** (`<CR>` lands focus in the real file) | **FIXED** | After `<CR>` on the review row the tab held three windows (`lain://review │ lain://review/OLD/src/main.rs │ …/project/src/main.rs`) and `bufname()` in the focused window was **`lain://review`** — focus taken to the sidebar, not followed into NEW. |
| **F38** (mark acknowledgement names a content hash) | **FIXED** | `x` on an opened row acknowledged **`lain: marked reviewed: 6 hunk(s) of src/main.rs`** — one message, naming the row. (This is why `cockpit-surfaces.md` §4's expected text is now stale — see **P6**; the message is the fix, not a regression.) |
| **F30 residue** (`51_thread.lua:639` still raises) | **NOT DRIVEN** | The thread pane was not opened this round — §4b was not reached at all. Round 7's instruction to re-file against that leg is **still owed**. |
| **F18** (a pending approval the chat pane never drew) | **REPRODUCED, with a mechanism** — see **F40** | 20 approvals parked this round. Under editor answering, 10 of 11 in one ask rendered nothing in the pane. |
| **FG1** (`--prompt` exits 0 on a failed turn) | **still true of `--prompt`; the redirection onto `--non-interactive` WORKS** | `--prompt` against `10.255.255.1` exhausted four attempts and exited **0** (26s). The new flag was driven per round 7's instruction and passed every leg: no `--prompt` → refuses by name; blackhole → **exit 1** in 26s; happy path → exit 0 in 3s; a gated `bash` → `is_error: true`, `no approval is possible for tool "bash": this session was started with --non-interactive, so no human is attached and nothing can approve a gated call. This is not somebody answering no -- retrying will fail the same way`, and **no `message` record and no parked Q event** in the journal. |
| **UX5** (`compaction` byte fields under token names) | **FIXED, at volume** | 20 `compaction` records this round, every one carrying `bytes_before`/`bytes_after`. |
| **UX8** (17-significant-figure backoff) | **FIXED** | Four independent renders: `0.13s/0.21s/0.42s`, `0.11s/0.25s/0.44s`, `0.12s/0.22s/0.43s`. No long tails. |
| **UX4** (`lain://approval` absent at rest) | **FIXED — but the window half has an over-correction after use.** See **F44** | At attach the buffer exists holding `(no approvals pending)`. It takes no window *until* a pending parks; it then never gives the window back. |

---

## F26, measured — the starvation is real, and it is now in the record

Not a new defect; the closing of an open question rounds 6 and 7 both left. Round 6 filed F26 (an
unjournaled concurrent oracle call starving the turn on a one-slot server); round 7 could not
reproduce the starvation and found instead that the gate's telemetry had no construction site (F28).

**Both halves resolved this round, in one record.** During the §9 windowed-read act a `grep` returned
200 capped matches, which tripped the eager summarizer. The journal carries:

```json
{"type":"oracle_answer", ..., "model":"qwen3-coder:30b", "wall_clock":38.90811104502063}
{"type":"provider_wait","kind":"waited","endpoint":"http://localhost:11434",
 "waited_seconds":38.894,"resolution_seconds":0.05,"in_flight":1}
```

Read together: the summarizer held the single slot for 38.9s, and the request behind it waited
**38.894s** with **one** request in flight. That is F26's exact mechanism, at F26's scale, on a
server whose `-np 1` was read from its own argv. What has changed is that it is **journaled** rather
than presenting as "the model seems slow" — which is what F28's fix bought, and it is the first time
a QA round has seen `provider_wait` at all. **Zero `stalled stream` and zero `run_interrupted`
across the whole round**, so the wait was absorbed rather than crossing a stall timeout.

---

## F40 — after an approval is answered in the editor, the chat pane goes silent for the rest of the ask  *(MED-HIGH, new)*

**What is wrong.** `Frontend::ApprovalPolicy#watch` is `loop { answered(queue.dequeue) }`, and
`#answered` → `#decide` → `@reader.call(...)` → `CLI::Conductor#read_reply` → `tty.prompt(text)`,
which **blocks reading stdin and has no cancellation when the pending is decided by another
surface**. So the moment a human answers the first pending through `:LainApprove`, the TTY surface
is parked forever on a prompt for a call that is already settled, never returns to `queue.dequeue`,
and never draws another `[y/N]` line. The fiber is only released when
`Repl::LineScope#serve`'s ensure stops the surfaces at the END of the line — so the pane recovers at
the next prompt, and the whole of the current ask is silent.

**Mechanism, at the line.** `lib/lain/frontend/approval_policy.rb` — `#watch` (the `loop`), `#decide`
(`@reader.call`); `lib/lain/cli/conductor.rb:154` `#read_reply`;
`lib/lain/cli/repl/approval_surfaces.rb` `#watch` (the fibers, stopped by the line's ensure).

**The evidence that rules out the innocent explanations.**

- *Not a dead render thread, and not the editor winning a race.* The run kept working throughout:
  the journal grew 19 lines per approval, `lain://approval`, `lain://journal`, `lain://timeline` and
  `lain://request` all stayed live, and the tools ran.
- *Not "the prompt scrolled away".* Captured at the moment: the chat pane's **entire** contents were
  **8 lines** (`capture-pane -p -S -200`, alt-screen so no scrollback), cursor at row 8, and
  `.lain/state.json` read `approvals_pending: 1` with `idle: 194`. A parked gate with nothing on
  screen asking for it.
- **The controlled comparison, which is what makes this a mechanism rather than a symptom.**
  In one ask, 11 pendings were answered through `:LainApprove`: `approval_decision` records show
  **11 × `surface: "nvim"`, 0 × `"tty"`**, and exactly **one** `agent asks: approve …? [y/N]` line
  was ever drawn. In the *next* ask, the first pending was answered by typing `y` **at the chat
  pane**, and the surface immediately drew the second prompt — then **8 consecutive pendings all
  rendered**, one after another, with no gap.

**Reproduction.**

```bash
lain up --socket $SOCK --session lain-qa $QA/project -- --provider ollama --model qwen3-coder:30b
# drive an ask that makes several gated bash calls in one turn, e.g.
#   "Create a Rust CLI at src/main.rs ... then add #[test] functions ..."
# answer the FIRST pending through the editor:
nvim --server "$S" --remote-send ':LainApprove<CR>'
# then wait for the next pending and read the pane:
tmux -L $SOCK capture-pane -p -S -200 -t <chat>     # no second `agent asks:` line ever appears
ruby -rjson -e 'p JSON.parse(File.read(".lain/state.json"))["approvals_pending"]'   # 1
# control: answer the first one by sending `y` to the chat pane instead -> every later
# pending renders normally.
```

**Why it matters more than it looks.** `:LainApprove` is documented as the *recovery* path for an
unrendered approval; here **using it is what removes the primary surface**. A human watching the
chat pane sees a session that has gone quiet with no question on it, and the only way back is the
editor they may not be looking at. On `--no-nvim` there is no competing surface, so nothing catches
this — which is exactly the two-real-components seam this bench exists for.

**Fix shape.** The TTY surface needs its read to be interruptible when the pending it is asking
about reports `decided?` — either park on the pending's own resolution alongside the terminal read
and take whichever completes, or have the queue signal its waiters on decide so `#answered` can
abandon a settled prompt and loop. **What would pin it:** a spec with two surfaces over one queue
where surface B decides pending 1 and surface A must still be handed pending 2 — the current
`approval_policy_spec` cannot fail, because a single-surface test never leaves an orphaned read.

---

## F41 — `ask_human` at stdin EOF journals a human answer nobody gave  *(MEDIUM, new)*

**What is wrong.** With stdin at EOF (`lain chat --prompt X < /dev/null`, which is the "cheap
vehicle" most scenarios in this bench use), a model call to `ask_human` returns an empty
`tool_result` with `is_error: false`, and the journal gains a `message` record attributed to the
human:

```json
{"type":"message","from":"blake3:ae2b…","to":"human","payload":{"asked_by":"lain","question":"How can I assist you today? …"}}
{"type":"message","from":"human","to":"blake3:ae2b…","payload":{"answer":""},"causal_parents":["blake3:d285…"]}
```

**The empty string itself is deliberate and documented** — `CLI::HumanReplies::Reply#read`'s comment
says so: *"`.to_s` is load-bearing: EOF returns nil, and an empty answer is honest where
`Tool::Result.ok(nil)` would raise."* The finding is not the empty string. It is that **EOF and a
human pressing Enter on an empty line produce byte-identical records**, so the experiment record
carries a human utterance in a session where no human was attached at all. On a study bench whose
whole premise is an unforgeable record, that is a provenance hole, and it is the same class of thing
`ApprovalPolicy::FAULT_SURFACE` exists to prevent on the approval side — a machine's answer must not
be signed as a person's.

**Measured cost.** Given an empty answer, the model looped 24 identical no-op `todo_write` calls and
spent the entire ceiling: **25 `request_sent`, 25 `turn_usage`, 51 `turn` records** for the prompt
`hi`. The ceiling then fired correctly (`error: loop ran 25 iterations, ceiling is 25`) and the
session survived, which is T14 working.

**Reproduction.**

```bash
cd $QA/project
lain chat --provider ollama --model qwen3-coder:30b --prompt 'hi' < /dev/null
ruby -rjson -e 'File.foreach(ARGV[0]){|l| r=JSON.parse(l) rescue next; next unless r["type"]=="message"
  puts r["payload"].inspect}' "$(ls -t $XDG_STATE_HOME/lain/sessions/*/*.ndjson | head -1)"
# -> {"answer" => ""} from="human"
```

**Fix shape.** Give EOF its own name on the way out, the way the approval queue does. Either a
distinct surface/attribution on the `message` record (`from: "eof"` / an `unattended: true` field),
or — better — refuse the call the way `--non-interactive` already refuses it, with the sentence that
flag already ships (`no human is attached … retrying will fail the same way`), which would also stop
the loop instead of feeding it. **What would pin it:** a spec asserting that a `Reply#for` at EOF
produces a record distinguishable from one produced by a typed empty line.

**Note the contrast, which is the argument for the fix shape:** `--non-interactive` gets this
exactly right today. It refuses `ask_human` by name and writes **no Q event at all**, so nothing is
left parked in the record. The plain-EOF path is the one that forges.

---

## F42 — `lain://approval` hides the command it is asking about  *(MEDIUM, UX, new)*

**What is wrong.** With one approval parked, the buffer is five lines: a truncated summary (line 1,
ending `...`), the full command as indented continuation lines (2–3), a blank trailer (4), and the
key hints (5). At rest the item's fold is **CLOSED** and the hints' fold is **OPEN**, so the only
thing on screen for the record is the truncated summary — and for a long command that summary is a
path prefix. Measured, with the approval window at ~50 columns, the human saw:

```
agent  bash({"command" => "cd /home/tara/tmp/lain-
··················································
-- y approve, n deny  (:LainApprove / :LainDeny)
```

The command was `cd …/project && rustc --version`. Neither `rustc` nor `--version` is on screen.

**Mechanism.** `runtime/10_folds.lua`'s `open_at_rest(buf)` returns `1` only when
`vim.b[buf].lain_view == QUESTION`; every other view gets `nvim_buf_line_count(buf)`, and
`default_folds` closes everything then re-opens the fold holding **the last line**. For
`lain://approval` the last line is the key-hints trailer. The comment on that very function draws
the distinction it needs — *"A LOG's live record is its LAST … A FORM's is its FIRST"* — and applies
it to `lain://question` only. `lain://approval` is the other form.

**Evidence, over RPC (`$QA/nv.sh fold`):**

```
line 1: level=1 closed=1  closedend=3     <- the item, CLOSED onto its truncated summary
line 4: level=1 closed=4  closedend=4     <- the blank trailer, its own closed fold (F43)
line 5: level=1 closed=-1 closedend=-1    <- the hints, OPEN
```

After `zR` the full command is on screen — so nothing is missing from the buffer, only from the
default rendering. **This is scoped:** a short command (`echo HELLO_QA`) fits line 1 and reads fine;
the failure needs a command long enough for the Ruby side to truncate at ~100 chars, which is any
`bash` call carrying an absolute sandbox path — i.e. most of them.

**Fix shape.** Add `APPROVAL` beside `QUESTION` in `open_at_rest`, so the pending row opens at rest
and the trailer stays closed. **What would pin it:** the existing `approval_view_spec` cannot see
this — fold state is window-local and no buffer assertion reaches it — so the pin belongs with the
`foldclosed()` recipe `method.md` already documents.

---

## F43 — an empty foldtext renders as a full-width bar of dots  *(LOW, UX, new)*

**What is wrong.** The blank trailer line in `lain://approval` answers `spanning_record` true, so it
becomes its own one-line fold; `default_folds` closes it; `_G.__lain.foldtext()` returns
`vim.fn.getline(v:foldstart)`, which for a blank line is `""`; and nvim pads a closed fold with an
empty text using the `fold:` fillchar, default `·`. A blank separator is therefore rendered as a
solid `··················································` bar across the window.

**`runtime/05_records.lua`'s comment claims otherwise, and that claim is what this finding
overturns**: *"A one-line fold displays as its own text (10_folds' foldtext), so a trailer loses
nothing by getting one."* True for a non-empty trailer; false for the blank one, which loses a blank
row and gains a bar. The blank answering `true` is correct and should stay — the trailer rule it
serves is measured and right. Only the render is wrong.

**Evidence.** `getline(4)` is `''`; `foldclosed(4) == 4`; `tmux capture-pane -p` of the nvim pane at
that moment shows the dotted row between the summary and the hints; after `zR` the same line renders
as an ordinary blank. Reproduced independently on a second, short-command approval in the notifier
act (`foldclosed(2) == 2`, same shape).

**Fix shape.** In `foldtext()`, return `" "` (or the trailer's own blank) when the summary line is
empty, so a one-line fold over a blank stays a blank. One line, no behaviour change elsewhere.
**What would pin it:** an assertion that `foldtext()` never returns the empty string.

---

## F44 — the approval window opens and never closes  *(LOW, UX, new)*

**What is wrong.** `runtime/62_approval.lua`'s `set_approval(lines, gen, rows)` opens a window when
`rows > 0 and shown == nil`. There is no corresponding close when `rows` returns to 0. So the first
gated call of a session permanently costs the review tab a window, which thereafter reads
`(no approvals pending)`.

**Evidence.** At attach, tab2 held four windows (`journal │ timeline │ inbox │ request`) — round 7's
UX4 verdict, reproduced. After the first approval it held **five**, and it still held five at the end
of the session with `approvals_pending: 0` and the buffer back to its placeholder. The function's own
comment (*"an emptied list never opens a window on nothing"*) is true and is about a different case.

**Fix shape.** Close the window in `set_approval` when `rows == 0` and a window is shown, mirroring
the open. Worth stating the tension: a human who split that window themselves should not have it
taken away, so the close should be conditional on lain having opened it.

---

## What passed, with the evidence worth keeping

**`session-and-window` — clean end to end.**

- §1: all nine launch-level refusals fired **by name, exit 1, zero backtrace frames**, including
  `--num-ctx 999999 is above the model's trained maximum of 262144 …` taken with residency verified
  **COLD** first, and `--num-ctx 262144` accepted (reaches the REPL, exit 0).
- §2: **26s** at the default connect timeout, **8s** at `LAIN_CONNECT_TIMEOUT=1`. Ordinals
  `1, 2, 3, 4` with the give-up line naming a **higher** ordinal than the last retrying line — F16's
  regression absent. Backoffs rendered to two places. **Attribution measured, not inferred:**
  `$QA/pathcount.rb` logged `2 × GET /api/ps` + `4 × POST /api/chat` against 4 rendered ordinals —
  four attempts, no hidden retries.
- §3: **the window re-resolves mid-session.** Turn 1 cold → `window=8192 prov="guessed" sig=[]`;
  turn 2 warm → `window=32768 used=4807 prov="probed"`. The T6 regression is absent.
- §4: **three readers agree.** HUD `ctx 50%`, `.lain/state.json` `occupancy 0.4959…` → 50%, journal
  `used=16174 window=32768` → 49% (the decision precedes the turn it decides for).
  `compaction_decision.used_tokens` equals the prior `turn_usage.usage.input_tokens` **exactly**
  (4807/4807, 15998/15998, 16174/16174).
- §5: exactly **one** `capability_degraded` line, matching the documented JSON, and nothing on screen.
- §6: `LAIN_NUM_BATCH=2048` → `extra={"num_batch" => 2048}` on the `session` record and on every
  `request_sent`; `env -u LAIN_NUM_BATCH` → `extra={}` on the session and on all 25 `request_sent`.
- §7: all six `--compact-strategy` cases correct, including the part-vs-whole wording
  (`unknown part "" in --compact-strategy "elide-tools+"`, naming both), the full four-name list, and
  `elide+summarizing` **launching** as designed.
- §8: `PriceBook.default` per MTok — opus **5/25/6.25/0.5**, sonnet 3/15/3.75/0.3, haiku 1/5/1.25/0.1;
  `cache_creation` exactly 1.25× input and `cache_read` exactly 0.1× on every row. `claude-fable-5`
  and `claude-mythos-5` raise by name. `Price.members` is the four documented names.
  `ProxyBytes::BYTES_PER_TOKEN` = 4. `bin/lint-price-freshness` exits 0 silently; the injected-clock
  stale branch reports 203 days; and the **deleted-marker** case fails correctly with
  `no "Reviewed YYYY-MM-DD" marker found near the price table` — driven with the abort-if-the-gsub-
  matched-nothing guard the scenario demands.

**`rust-cli` — complete, including the unhappy path.** `cargo build` and `cargo test` green
(4 passed), and the behavioural oracle exact: `printf 'the cat the dog the\n' | wordfreq -n 2` →
`the 3` / `cat 1`. The driver then broke it (`fn main(x: i32)`), the model read the `E0580`
diagnostic out of a tool result and restored `fn main()`; build and tests green again.
**30 tool results, `maxlen` 2894 bytes, zero containing an ESC byte** — cargo's colour did not
corrupt the transcript. `lain://journal` populated with real `[call_… stdout]` lines and no stuck
placeholder above them. No bound tripped; no `stalled stream`; no `run_interrupted`.

*One thing worth a note rather than a finding:* a `bash` call exiting **1** comes back with
`is_error: false` and the status inside the body (`exit status: 1 --- stdout --- …`). Zero
`is_error` results existed in the whole `rust-cli` session despite a failing compile. The model read
it correctly, so this is recorded as observed behaviour, not filed.

**`cockpit-surfaces`.**

- §1: all **seven** buffers primed and live; `lain://approval` at `(no approvals pending)`;
  `lain://journal` holding real output with no stuck placeholder.
- §2/§6: **the multi-line-reply freeze does not reproduce.** Two asks whose replies were
  deliberately multi-line: `timeline` 66 → 68 → 70, `request` 1446 → 1464 → 1482, `turn_usage`
  33 → 35. `lain://journal` correctly unchanged (no tools ran). **Zero** one-line-per-record
  contract markers anywhere in the timeline.
- §3: `:messages` holds `not attached yet` and then `attached -- layout opened`, **in that order**.
- §4: `x` on an unopened row refused by name
  (`lain: lain://review line 1 names src/main.rs, which nothing has read -- open it with <CR> first`),
  row left unmarked. `<CR>` opened three windows with focus in the sidebar (F34). `x` marked `[x]`
  and acknowledged (F38). `:LainReviewVerdict approve` acknowledged **and** journalled
  `{"type":"review_verdict","verdict":"approve","changeset_digest":"survey-corpus-v1:1daed6ff…"}`.
- **`:LainReviewDone` — the README's #1 named gap — PASSES.** It refuses cleanly:
  `lain: :LainReviewDone needs an open EPIC review, and this buffer is not one -- a changeset review
  or a survey hands back with :LainReviewVerdict {verdict} instead`. **Zero `stack traceback:`**,
  `nvim_get_mode()` → `{'blocking': v:false, 'mode': 'n'}`, journal unchanged.
- **All three axes of the refusal rail hold.** `v:echospace` measured at **88** here (not the 98 the
  scenario records for a 110-column pane — this pane was narrower). The 161-character
  `:LainReviewDone` refusal displayed as one **middle-elided** line
  (`lain: :LainReviewDone needs an open EPIC  ...  with :LainReviewVerdict {verdict} instead`) with
  the full sentence in `:messages`. A two-line refusal: not blocking, both lines unfolded in
  `:messages`. A **60-line** refusal: `mode` `n`, neither `r` nor `rm`.
- §5b: F29's fix confirmed (above), plus two refusals worth quoting —
  `error: /inbox is the drain you are already in -- type the reply` and
  `error: /nonsense is not a registered command -- nothing ran, and nothing was answered. If you
  meant it as text, start the line with a space`. The prose control passed: the answer landed as
  `from: "human"` and the researcher completed and reported back to its parent.
- §7: HUD/state.json/journal agreement recorded above; `idle` present at `you>`.
- §8: **the fold surface works and is per-row independent** — the recipe `method.md` carried as
  pending "once T9/T12 land" now runs. It is what produced F42 and F43.

**`bench-arms` — clean, and the two-round-old wall-time mystery is settled.**

```
Arm driver — 3 arms over 8 tasks
  fixture:   spec/fixtures/arms/tasks.yml
  model:     qwen3-coder:30b
  isolation: unset — Arm::NoIsolation leased nothing
```

All four header lines correct, no credential and no base URL anywhere in the report. Grades
0.812 / 0.812 / 0.938; tokens 224.5 / 445.0 / 3492.6 — **all three conjoined checks pass**, and no
arm's grade is faked on a collapsed ledger. The cost section refused **as a section**:
`not priced — no price for model "qwen3-coder:30b"; configure a fallback to degrade`, with score,
tokens and wall-time all still rendered. No `StalledStreamError`. Both refusals correct:
`--journal` without `--isolation`, and the default `anthropic` provider on a missing key.

**The wall-time outlier is a first-load cost, not an anomaly.** Round 4 recorded `single-thread`
max 29.6s against a 1.39s median and left it unexplained; this round reproduced it (**27.47s** vs
median 1.39s) and then **re-ran the identical suite immediately, warm**:

| run | single-thread mean | median | max |
|---|---|---|---|
| cold-ish (first) | 4.6452 | 1.3894 | **27.4689** |
| warm (immediate repeat) | 1.5075 | 1.3824 | **2.3951** |

The outlier is the first request of the run paying the runner load, matching `bench.md`'s ~27s
figure. **`cockpit-surfaces`/`bench-arms` should stop calling it unexplained.**

**A second number re-verified while there:** both arm runs sent `num_batch: 2048` against a runner
whose argv reads `-b 512`, and the runner did **not** reload across either — residency stayed
`qwen3-coder:30b ctx=32768` throughout. So on ollama 0.32.12 `num_batch` does not re-key the runner
the way `--num-ctx` does. Round 6's 30.9s→9.3s reading was about a hand-rolled `curl` probe and
should not be generalised to lain's own launches.

**`failure-injection` §§1, 2, 3, 8, 9, 10, 11.**

- §1: **391 lines, 0 unparseable**, no `journal_error`, occupancy reconciles exactly.
- §2: the torn `turn` gave **69 turns vs the good copy's 70, under the same head
  `blake3:803aa7b4e807`, plus `1 line unparsed`** — invisible at rest, exactly as documented. Then
  unforgeable on use, from three doors, each **exit 1 with zero backtrace frames**:
  `cannot fork TORN-turn.ndjson: turn record 3 (user) recorded as blake3:d914f3a6… re-commits to
  blake3:b228abef…; its content no longer matches its content address`; the same with a
  `cannot resume` prefix; and `bench variance` prefixing the path. A bad digest prefix refused with
  `no turn matching "blake3:deadbeefdeadbeef" recorded in GOOD-copy.ndjson`.
- §3: a dangling `causal_parents` and a `null` inside one both refused as `Corrupt` with
  `turn record 2 (user) cites a causal parent this fold never landed: no object "blake3:d285…" in
  store: putting "blake3:26db…" would dangle` — **neither leaked `Store::MissingObject` nor a bare
  `ArgumentError`**, which were the two old escapes. *Honest caveat:* damaging a `message` record's
  edges surfaced on the **turn** that cited it, so the message-indexed sentence
  (`message record N (<label>) …`) was **not reached**, and the null-specific path was masked by the
  same re-digest. Not a pass on those two shapes — see "What was not reached".
- §8: live ceilings read through `/ruby` from the process under test —
  `[262144, 1048576, 131072, 500]` and `Glob::BOUND` 500, all exact. **Both refusing shapes are
  correctly different**, which is the design this check exists for:
  `big.txt is 3000000 bytes, over the ceiling of 262144 -- instead, read part of it with read_file's
  offset and limit, or outline it …` versus
  `mid.rb is 300000 bytes, over the ceiling of 262144 -- instead, read it with read_file's offset and
  limit (a window covering the whole file counts as a complete read, so edit_file still accepts it),
  or outline it …`. Both name the size, the ceiling and a narrower action; both name the **resolved
  absolute path** (UX10's fix).
- §9: `[false, true]` after a partial window and `[true, false]` after a full-cover one — the
  deadlock guard's state transition, both directions. The `edit_file` refusal in between named the
  file and the situation, not a loop:
  `precondition failed for edit_file: only a window of …/mid.rb was read this session -- an
  offset/limit read showed you part of the file, so editing it would clobber lines you never saw.
  Read it again with no offset and no limit, or with a window covering the whole file, then edit`.
  A windowed read result also carries its own in-band disclosure
  (`… window only: lines 1-1; the rest of the file was not read, so edit_file will refuse it`).
- §10: `[4096, 262144]` — the two summarizer gates remain independent.
- §11a: the pre-flight refuses with **no session created at all** — missing key
  (`ANTHROPIC_API_KEY is not set; --provider anthropic needs it to build a client -- looked for in
  the environment this pre-flight ran in, which is not the one a tmux server started elsewhere hands
  its panes; export it here, or start that server from a shell that has it`) and `--num-ctx 0`, both
  exit 1, `has-session` failing, zero backtrace frames. **No `could not pre-flight` warning
  appeared**, so this measured the pre-flight path and not the corpse path.
- §11b: all three checks. `lain up` did not attach and said why; the session **survived** with the
  dead pane in it (`pane_dead 1`, `pane_dead_status 127`); and the causal first line survived the
  tmux banner — `zsh:1: no such file or directory: ./exe/lain` printed **above**
  `Pane is dead (status 127, …)`, so the `-S -` is still in place.
- §11c: `remain-on-exit failed` (tmux 3.7b).

**The named notifier act.** One act ran with the notifier live (`LAIN_DESKTOP` unset before
`new-session`, verified at 0 matches per pane; `dunstify` and `dunstctl` both on `PATH`). A single
gated `bash` raised one notification — `summary="approve bash?"`, `body` the command input,
`urgency=CRITICAL`, `appname="lain"` — and answering it through `:LainApprove` (a **different**
surface) withdrew it: `displayed` **1 → 0 within 1 second**, well inside the 50ms sweep's promise.
*Nearly filed and withdrawn:* the body arrives HTML-escaped (`&quot;`), which looks like noise until
you check the human's `~/.config/dunst/dunstrc`, which is `markup = full` — so it renders correctly.
Checked rather than assumed.

**Compaction, incidentally, at volume.** 20 `compaction` records fired across the round without any
scenario asking for them — **16 `trigger: ["plan_step_completion"]`** and **4
`trigger: ["token_threshold"]`**, the largest collapsing **695,211 → 332,439 bytes**. All carry
`bytes_before`/`bytes_after` and `cost_saved`/`cost_spent` of `"0.0"` beside the local model, which is
the documented honest zero. **This is still not `rails-blog.md` §1** — nothing here says a *composed*
strategy does what its name says — but it is more evidence that the occupancy path runs end to end
than any previous round has had.

---

## Second pass — `rails-blog` and `bowling-ruby`

Driven after the first pass, at the user's request, in the same context. The separate-context rule
for `rails-blog` exists to stop budget starvation; that reason did not bind here (about 2% of context
spent when the pass began), and it is recorded so the exception is visible rather than quiet.

**`rails` was absent on this box** — which is part of why this scenario had never run in eight
rounds. It was installed into a sandbox-local `GEM_HOME` (~4 min, 32 gems, disposable with the
sandbox, never touching the operator's own gems) rather than substituting a smaller app, which the
scenario forbids. The full measured recipe, including the `PANE_ENV` trap that makes a `GEM_HOME`
exported in the wrong shell silently invisible to the chat pane, is now in `rails-blog.md`'s
**Needs** section.

### Compaction at scale — reached for the first time in this bench's history

Rounds 3, 4, 5, 6 and 7 all failed to reach this. It is the single least-exercised path in the
system and every claim about the two content-selective strategies has until now rested on specs
alone.

Driven with `--compact-strategy elide-tools+summarize-conversation --summarizer-provider ollama`, per
§0. **11 compactions fired**, across both triggers:

| trigger | n | bytes_before → bytes_after |
|---|---|---|
| `plan_step_completion` | 4 | 97,654 → 33,647 … 103,962 → 38,792 |
| `approaching_window` | 7 | 111,047 → 44,084 … 126,462 → 43,778 |

**Occupancy actually falls, every time**, which is §1's central question:

```
83% -> 59%    90% -> 70%    95% -> 72%    98% -> 73%
98% -> 72%    97% -> 73%   100% -> 70%   100% -> 71%
```

- **No `Overlap` raise across 11 compactions.** The composed pair partitioned the span cleanly every
  time — the complement property T7's shared predicate exists to guarantee, confirmed in production
  rather than in a spec, and the check nothing else in this bench can make.
- **One rewrite per crossing**, not round 2's three: every `compacted=true` decision is followed by a
  `compacted=false` one at the lower occupancy.
- **§0's paid-and-discarded shape did NOT occur.** `would_not_shrink` was `false` on every decision
  and `compaction => 11` against `oracle_answer => 1` — the opposite of the null this act produces
  when the scenario is too small.
- **The summarize half barely fired**, and correctly so: `summary_hits`/`summary_misses` were **0**
  throughout and there was exactly **one** `oracle_answer` across 11 compactions. The transcript is
  tool-dominated, so almost every message went to the elide half; §1 says an `oracle_answer` for a
  single-message run would be a defect, and none occurred.
- `cost_saved`/`cost_spent` are `0.0` beside the local model — the documented honest zero.

**A calibration note for §2 that matters more than it looks: the volume that drove this was turn
COUNT, not result SIZE.** The largest single tool result in the whole session was **4,713 bytes**
(`rails new`), the total across 114 tool results was **40,306 bytes**, and **zero** results disclosed
a cap. §2 is written expecting `rails new` to emit "an enormous `bash` result"; under `--minimal` it
does not, and no bound came close to firing even in the scenario built to fire them. So §2's premise
is still unreached, while §1's was reached anyway — worth separating in the scenario, because a
future round could read "compaction fired" as evidence that §2 was exercised too.

### F45 — every `bash` call is forced into lain's own bundle  *(HIGH, new)*

**What is wrong.** The `bash` tool inherits `BUNDLE_GEMFILE=/home/tara/dev/lain/Gemfile` and
`RUBYOPT=-r…/bundler/setup` from the lain process, so **every Ruby subprocess the agent runs inside
the user's project resolves against lain's own bundle.** `rails new` dies with:

    can't find executable rails for gem railties. railties is not currently included in the bundle,
    perhaps you meant to add it to your Gemfile? (Gem::Exception)

**Why the standard sandbox gate cannot see it.** Neither variable appears in
`/proc/<pid>/environ` — `bundler/setup` sets them *in-process*, after exec — so the per-pane
environment check every round runs comes back clean. They are only visible from inside the running
process:

```bash
$QA/drive.sh '/ruby [ENV["BUNDLE_GEMFILE"], ENV["RUBYOPT"], ENV["GEM_HOME"]]' 6 40 >/dev/null
$QA/peek.sh 5
# -> ["/home/tara/dev/lain/Gemfile", "-r…/bundler/setup", "…/gems"]
```

**Which variable is load-bearing, isolated by control** — this is the evidence that rules out the
innocent reading (that `rails` was simply mis-installed):

| control | env | result |
|---|---|---|
| A | neither var | **exit 0** |
| B | `BUNDLE_GEMFILE` + `RUBYOPT` | **exit 1**, byte-identical to the agent's error |
| C | `RUBYOPT` alone | **exit 0** |

So `BUNDLE_GEMFILE` is the cause and `RUBYOPT` alone is harmless.

**Blast radius.** Any bundler-managed Ruby project that is not lain: `rails`, `rake`, `rspec`,
`bundle install` all resolve against the wrong Gemfile. It also leaks the absolute path of lain's own
checkout into every child process the agent runs — a path outside the project root, in a harness
whose `Project` splits root from cwd precisely to bound authority. For the QA bench specifically it
punches through the sandbox: the XDG redirection is undone for Ruby subprocesses, which reach into
`/home/tara/dev/lain`.

**Reproduction.** Any `lain up` on a Ruby project with its own Gemfile; ask the model to run `rake`
or `rails` or `rspec`. Or directly: the control table above.

**Fix shape.** The `bash` tool should scrub the bundler variables from the child environment —
`BUNDLE_GEMFILE`, `BUNDLE_BIN_PATH`, `BUNDLE_PATH`, `RUBYOPT`, `RUBYLIB` — the same way
`method.md` already records scrubbing `GIT_INDEX_FILE`/`GIT_DIR`/`GIT_WORK_TREE` for git, and for the
identical reason: a harness's own tooling environment must not be inherited by the commands it runs
on someone else's tree. CLAUDE.md's `pre-commit` trap is this defect one layer over. **What would pin
it:** a seam spec that runs `env` through the `bash` tool and asserts no `BUNDLE_*`/`RUBYOPT` reaches
the child.

*Driver note: unblocked for the rest of the pass by wrapping the `rails` binstub in
`env -u BUNDLE_GEMFILE`. A PATH shim could not be made to win — mise's PATH reconstruction dedupes
and preserved an older relative order — so the wrapper replaced the binstub in place.*

### F46 — the iteration ceiling permanently breaks compaction, fork and resume  *(HIGH, new)*

**What is wrong.** When the per-ask iteration ceiling fires, it commits the assistant's `tool_use`
turn and interrupts before any `tool_result` is appended. The timeline is then left holding a
`tool_use` that is **never answered**, permanently. Measured, four milliseconds apart:

```
14:58:25.850202Z  turn role=assistant   tool_use call_f4eu93ak (bash)   <- no tool_result, ever
14:58:25.854746Z  run_interrupted
```

Journal-wide: `tool_use` blocks for `call_f4eu93ak` = **1**, `tool_result` blocks = **0**.

**Three consequences, all confirmed in the same session.**

1. **Compaction is dead for the rest of the session.** From `14:59:35Z` on, every derivation is
   refused — correctly — because the chain would be invalid:

       derivation_refused: … derives a chain the Messages API would reject:
       the tool_use "call_f4eu93ak" in messages[28] is never answered      consecutive: 1
       … messages[26] …                                                    consecutive: 2
       … messages[24] …                                                    consecutive: 3

   The message index walks *down* as the conversation grows, so the orphan drifts toward the cut
   and is refused again each time.
2. **Occupancy pins at the ceiling.** The last decisions read `used=32592/32758/32386` against a
   32768 window — 99–100% — with `signals: ["approaching_window"]` firing on every turn,
   `compacted: false`, and `since_compaction: 201`.
3. **The session becomes unforkable AND unresumable.** Both doors refuse:

       cannot resume <session>: its head is an assistant tool_use turn still awaiting tool results
       (the run stopped mid-tool); fabricating results would falsify the record -- re-ask the
       question in a new session

**The evidence that rules out the innocent explanation.** Every component here is individually
correct, and that is the point. The ceiling is T14 working as designed (round 8 confirmed it renders
its line and the session survives). The derivation guard is doing exactly the right thing — its own
comment argues carefully for refusing rather than raising, and the resume refusal explicitly declines
to fabricate. **The defect is the combination**, and it is invisible from inside either component's
specs: two real components with specs on both sides, which is this bench's whole premise.

Note the guard's premise is inverted here. `derived.rb`'s comment reasons about "a history that is
perfectly legal" being awkward for a strategy. This history is *not* legal — and it was made illegal
by lain's own ceiling, not by the model and not by the strategy. Nothing repairs it.

**Reproduction.** Drive any long tool-heavy ask until one ask hits 25 iterations while a `bash` call
is in flight (`rails-blog`'s middle acts do this reliably — five `run_interrupted` records in one
session). Then:

```bash
ruby -rjson -e 'File.foreach(ARGV[0]){|l| r=JSON.parse(l) rescue next
  puts JSON.pretty_generate(r) if r["type"]=="derivation_refused"}' "$JOURNAL"
lain chat --resume "$SESSION"      # refuses; so does --fork
```

**Fix shape.** The ceiling should append a synthetic `tool_result` for every `tool_use` it tears —
an interruption notice, marked as such — before committing the interrupt. The Messages API requires
the pairing, the model would learn why its call went unanswered, and both compaction and
fork/resume would keep working. Writing an *honest* refusal result is not the fabrication the resume
path rightly declines: fabricating a *tool's output* falsifies the record, while recording "this call
was cancelled by the iteration ceiling" is the record. **What would pin it:** a spec asserting that
after a ceiling interrupt no `tool_use` in the timeline lacks a matching `tool_result`.

### F47 — nothing tells the human compaction has stopped  *(MEDIUM, UX, new)*

The state F46 produces is entirely legible **in the NDJSON** and nowhere else. `derivation_refused`
carries a `consecutive` streak whose stated purpose is exactly this distinction — from
`derived.rb`'s own comment: *"a bench arm reads `consecutive` rising and knows the difference between
one awkward turn and a session that has stopped."* But `@consecutive` is written and **never read
anywhere in `lib/`**; no surface projects it. `.lain/state.json` carries `since_compaction: 201`,
which is the number that would say it, and nothing renders that either. The HUD shows `ctx 100%` —
truthful, and reads as "the context is full", not "compaction died 200 turns ago and this session can
no longer be resumed".

**Fix shape.** The HUD already elides segments that have nothing to say; a `compaction stalled`
segment (or a one-time rendered notice at, say, `consecutive == 3`) is the cheap version. The
stronger version is that the session should say so at the moment it becomes unresumable, because
that is the moment the human's options narrow to one.

### F48 — a torn head refuses with the wrong door's verb  *(LOW, new)*

`lain chat --fork SESSION@DIGEST` on a session whose head is an unanswered `tool_use` prints
`cannot resume <session>: …`. `failure-injection.md` §2/§3 assert `cannot fork <session>:` for that
door, and round 7 recorded the two prefixes as correctly distinct. This one refusal path always says
`cannot resume`. Cosmetic, but it is the kind of thing a damaged-journal probe matches on.

### F49 — `cache_waste` is vacuous against a local model  *(MEDIUM, new — and a correction to the scenario)*

`rails-blog.md` §5 says this is "the only scenario that can exercise it honestly", warning that
`Provider::Mock` reports all-zero cache fields so a mock-backed reading passes while asserting
nothing. **An ollama-backed reading is vacuous for exactly the same reason**: ollama has no prompt
caching at all — lain journals `capability_degraded {"capability":"prompt_caching"}` once per session
saying so, and every `turn_usage` in this 116-call session carried
`cache_creation_input_tokens: 0, cache_read_input_tokens: 0`. The report duly says:

    cache_waste: none -- no prefix break was re-billed; 0 tokens served from cache over 116 priced
    main-agent call(s), saving $0.000000; dollar figures exclude qwen3-coder:30b -- no price recorded

Structurally that is a **pass** on all four of §5's honesty checks: the clean-session sentence
appears rather than the section being omitted, what the cache bought is reported beside what it
wasted, the unpriced model is disclosed rather than printing a confident `$0.00`, and the report
carries no message content and no paths (checked by eye — digests, tool names and counts only). But
it is a pass over a zero, and **§5 cannot be exercised honestly by any ollama-driven scenario.** It
needs a real Anthropic session; no scenario in this bench currently provides one.

**One real UX problem visible in the same output**, independent of the vacuity: two lines apart, the
report says `cache_rewrites: 4 prefix rewrites detected` and then `cache_waste: none -- no prefix
break was re-billed`. Both are true (rewrites happened; nothing was re-billed because nothing was
cached) but read together they contradict each other, and nothing on the page reconciles them. The
`/model`-switch check §5 also asks for was not driven.

### The rest of `rails-blog`

- **Definition of done PASSES**, driver-run rather than model-claimed: `bin/rails test` → **7 runs,
  11 assertions, 0 failures, 0 errors, 0 skips**, with one test file per feature
  (`posts_controller_test.rb`, `comments_controller_test.rb`, `tags_controller_test.rb`,
  `comment_test.rb`, `tag_test.rb`) and all three routes resolving. The scenario says this is
  "deliberately more than a 3B-active MoE will finish"; it finished. 100 files, 904K.
- **§3, the gate under volume: 42 pendings, 41 decisions, every one at `surface: "tty"`, no wedge.**
  That is a clean confirmation of F40 from the other side — the prompts kept rendering *because* the
  pass answered at the terminal throughout, which was a deliberate workaround for F40 and is worth
  knowing shaped how this scenario had to be driven.
- `.lain/config.toml` was never written in any project — no durable pre-approval was created.
- **§4, session lifetime:** 116 `turn_usage`, 5 `run_interrupted` (the ceiling), and the session kept
  answering after every one of them — T14 holding, five times over.

### `bowling-ruby`

- **§1 `/create-plan` did NOT fail the way round 4 recorded**, and that is a change worth naming.
  Round 4 watched it burn the whole ceiling without writing a file. This round it spawned a real
  fleet (`fleet 3`, 15 `child_turn`, 7 `message` records), asked one clarifying question through
  `ask_human`, and — once answered — wrote `planning/specs/bowling.md`.
- **§7's `idle`-elision check PASSES, and the recipe matters** — this closes **P5** properly. At the
  `human>` prompt of a *`/create-plan` fleet* the HUD read `qwen3-coder:30b ctx 22% fleet 3` with the
  `idle` segment **absent**, because the parent is dispatching. At the `human>` prompt of an
  `@researcher[…]` spawn in the *same session* it read `ctx 44% fleet 5 idle 6s` — present, because
  there the parent really is idle. Both cases measured side by side; the check is drivable, just not
  by the recipe `method.md` gives.
- **§3 grading, and why the driver owns the oracle.** After the plan act the model reported *"All
  requirements have been met and the implementation follows standard ten-pin bowling rules as
  specified."* `lib/bowling.rb` was still the empty module the round seeded: **0/5 oracles**, five
  identical `NoMethodError`s. One directive follow-up naming the omission produced a real
  implementation: **5/5 oracles pass**, including oracle 4 (the load-bearing 133) and oracle 5 (the
  tenth frame at 30, not 60). Recorded as MODEL behaviour, not a lain defect — but it is the
  cleanest demonstration yet of why §3 exists.
- **§2's F23 regression step PASSES, with a valid control pair.** The spawned session (12 `message`,
  22 `child_turn`, 21 causal refs of which **9 point at `message` records**, **0 unresolved** against
  113 recorded digests) forked **exit 0** and resumed **exit 0**. The old refusal sentence appears
  nowhere. Control — a session with `message=0, child_turn=0, turn=2` — also forked and resumed
  exit 0. The pair is what makes this a result rather than a null.
  *(A first control attempt used the `rails-blog` session and failed; that was **F46**, not F23 —
  its head was a torn `tool_use`. Recorded because the two refusals are easy to confuse and the
  first reading looked like F23 returning.)*

## Model behaviour — not lain defects

**MODEL-2 — a malformed tool call on a CLEAN transcript, at roughly a 50% rate.** The standing note
says of the literal `<function=` failure: *"the trigger is a contaminated transcript, not payload
length — the same prompt that failed twice in a poisoned session succeeded immediately in a fresh
one."* The first pass reproduced it on a session whose entire history was **two trivial one-word
exchanges** (`ping`, `pong`): the first substantive ask emitted `<function=…>` and `</tool_call>` as
assistant **text**, wrote no file, ended the turn — and a restart plus the identical prompt succeeded.

**The second pass turned that into a rate**, because `rails-blog`'s directive prompt hit it twice
more and the repeat was cheap (66–96s per attempt, fresh session each time, prompt byte-identical):

| attempt | transcript | result |
|---|---|---|
| rust-cli #1 | clean (2 trivial turns) | **malformed** |
| rust-cli #2 | clean (fresh session) | ok |
| rails #1 | clean (fresh session) | **malformed** |
| rails #2 | clean (fresh session) | ok — 14 real tool calls |
| rails #3 | clean (fresh session) | **malformed** |
| rails #4 | clean (fresh session) | ok — ran to completion |

**3 of 6, on identical prompts from identical clean states.** So it is stochastic, not
contamination-driven, and **a fresh session is not protection — it is another roll.** The restart
rule still stands (a poisoned transcript never recovers), but its stated cause is wrong and its
implied reassurance is too. Small sample; stated as roughly half rather than as a rate.

**The harness-side gap this exposes** (feature gap, and the round reached for it): when the model
emits a tool call as prose, lain renders the text and ends the turn with no detection and no hint.
At a ~50% first-turn rate on this model, a driver spends half its launches discovering the failure by
eye. A check for a literal `<function=`/`</tool_call>` in committed assistant text — surfaced as a
line, or retried once — would turn a silent write-off into something the human or the loop can act
on.

Also observed, all consistent with the standing notes:

- **It will not emit a bare `edit_file`.** Four attempts to drive §9 step 5 (edit permitted after a
  full-cover window), including one instructing "do exactly two tool calls and nothing else", each
  produced a fresh `read_file` (which re-partialises the read set) or a `grep` instead. This is what
  left §9 step 5 undriven — see below.
- **It burns iterations on nothing when given nothing.** `--prompt hi` at EOF: `ask_human`, then 24
  identical no-op `todo_write` calls to the ceiling (see F41).
- **It hallucinates the medium.** The spawned `researcher` critiquing a Rust file reported on "the
  provided HTML content".

---

## Process defects in the bench's own method

**P4 — `lain sessions`' last field is not the head digest when a damage note is appended.** The
documented §2 recipe reads the advertised head off that row; `awk '{print $NF}'` on a torn session
returns the literal word **`unparsed`** (from the trailing `1 line unparsed`), and the fork probe
then refuses with `no turn matching "unparsed" …` — which is a *correct* refusal of a *bogus* input
and reads exactly like a pass on the wrong door. Caught here because the digest looked wrong; the
`--fork` door had to be re-driven. Use `grep -oE 'blake3:[0-9a-f]+'`, not `$NF`.

**P5 — `method.md`'s recipe for reaching `human>` cannot exercise §7's idle-elision check.** §7
requires that at *"the `human>` prompt of a parked `ask_human`"* the `idle` segment be **absent**,
because a dispatch is in flight. The only recipe the method gives for reaching that prompt is
`@researcher[/critique] <path>` — a **subagent's** question. `PromptComposer#idle` elides on
`@agent.dispatching?`, which reads the **parent's** dispatch lock; with the child holding the
question the parent is genuinely idle, so the HUD correctly read
`qwen3-coder:30b ctx 50% fleet 1 idle 5s`. **Nearly filed as a defect and withdrawn on the code
read.** §7 needs to say *whose* dispatch, and needs a recipe that parks the **parent's own**
`ask_human`.

**P6 — `cockpit-surfaces.md` §4's expected mark acknowledgement is stale.** It still expects
`lain: unit-content-v1:<key>… is now reviewed`; F38's fix (round 7) changed it to
`lain: marked reviewed: 6 hunk(s) of src/main.rs`. A driver following §4 literally would file the
fix as a regression.

**P7 — `pgrep -f` self-match, sixth round running.** `pgrep -fa 'exe/lain'` at close-out matched the
agent shell's own command line, which contained the pattern. Non-destructive this time. The reliable
close-out check used instead: iterate `pgrep -x ruby` and test each `/proc/<pid>/cwd` against the
sandbox path.

**P8 — the driver's approval deny-list let a command out of the sandbox, and this is a gate failure,
not a scripting slip.** `method.md` says to refuse anything reaching outside the sandbox and names
`$HOME`, `~/.config`, `~/.ssh`, `/etc`. The second pass's approval loop encoded exactly that list —
and had no entry for **`/tmp`**, which is outside the sandbox exactly as much as `$HOME` is. It
auto-approved `cd /tmp && mkdir test_blog && cd test_blog && rails new . --minimal`, which created a
directory outside the sandbox. Damage was nil (the inner `rails new` failed too, leaving an empty
directory, since removed) but it should have been impossible: **the human at the gate approved a
command they had a rule against.** The list was widened, and the *next* occurrence of the identical
command was correctly denied — so the fix is verified rather than asserted. The lesson for the method
is that an enumerated deny-list is the wrong shape for "outside the sandbox": the sandbox path is
known, so the rule should be an allow-list against `$QA`, and `method.md`'s enumeration invites
exactly this hole.

**P9 — the QA sandbox's `GEM_HOME` reached `exe/lain`, and bundler silently re-locked the repo.**
Found on 2026-08-21 while taking a suite baseline, hours after the round ended: `Gemfile.lock` in the
working tree had been rewritten — `activemodel`/`activesupport` `8.1.3` → `8.1.3.1`, plus `parser`,
`rubocop` and `rubocop-performance` bumps, 104 insertions and 105 deletions. Nobody edited it.

The mechanism: the second pass installed Rails into a sandbox-local `GEM_HOME` and baked that into
`$QA/env.sh` so the chat pane would inherit it. `exe/lain:28-32` then does
`ENV["BUNDLE_GEMFILE"] ||= <lain's own Gemfile>` followed by `require "bundler/setup"` — so **every**
`lain` invocation from that sandbox resolved *lain's own bundle* against a gem path that now carried
a newer `activesupport` satisfying `~> 8.0`, and bundler re-locked to it. Silently, with no output,
on a command that was doing something else entirely.

This is adjacent to **F45** and points the other way. F45 is lain's environment leaking *out* into the
child; this is the sandbox's environment leaking *in* to lain, through the same `BUNDLE_GEMFILE` pin.
Both come from `exe/lain` treating the ambient gem environment as its own.

Consequences worth naming, because none of them announced itself:
- `rake pspec` then failed to start at all (`Could not find activemodel-8.1.3.1 ... in locally
  installed gems`) — a bundler resolution error, not a test failure, and one that reads like a broken
  toolchain rather than like a modified file.
- The lockfile change would have been committed by the next `git add -A`, silently upgrading the
  project's pinned dependencies as a side effect of a QA run.
- Restored with `git checkout -- Gemfile.lock`; the suite is green at **14,926 examples, 0 failures,
  15 pending** (37s, `LAIN_SPEC_WORKERS=12`).

**For the method:** never put a `GEM_HOME` on a path `exe/lain` will inherit. If a scenario needs
gems the project does not have, they belong somewhere the lain process cannot resolve against — and
whatever the arrangement, **`git status` on the repo is part of QA close-out**, not just
`find ~/.local/state/lain`. The round-8 close-out verified the sandbox negative and never looked at
the working tree it was launched from.

**One process note that is not a defect:** three `lain chat` launches inside one `$(...)` command
substitution appeared to take ~100s each; measured individually with output redirected to a file
they take **1.0s**. The slowness was the agent shell's capture, not lain. Recorded so the next round
does not chase it.

---

## Withdrawn — nearly filed, disproved by the mechanism

- **"the chat pane stopped rendering entirely after the first tool stream"** — the pane was 8 lines
  for several minutes with the journal growing, which looked like a dead render path. It was not:
  everything appeared later, and the real defect is narrower and is **F40** (approval prompts only).
  Filing the broad version would have sent a fix chunk at the wrong component.
- **"the HUD reads 59% when occupancy is 15%"** — observed at the turn-2 prompt. That is turn 1's
  real `used_tokens` (4807) over the still-guessed window (8192), i.e. honest at the moment it was
  printed, and it corrects to 15% as soon as the window resolves. Documented cold-start behaviour.
- **"approval notifications arrive HTML-escaped"** — the user's dunstrc is `markup = full`, so they
  render. Checked before filing.
- **"the `idle` segment fails to elide at `human>`"** — see **P5**; the parent really is idle.

---

## What was not reached, and why

- **`bowling-ruby` was MISSED in the first pass, and calling it a decision would have been
  generous.** An earlier draft of this document said it was dropped because `rust-cli` served as the
  subject host for `cockpit-surfaces`, "which is what README's ordering allows". **That is not what
  README says.** The full-round sequence is five steps — `session-and-window` → `rust-cli` → *a
  subject with `cockpit-surfaces` piggybacked* → `bench-arms` → `failure-injection` — where
  `rust-cli` is the smoke test and the *subjects* are `bowling-ruby` and `rails-blog`. Collapsing
  steps 2 and 3 deleted the subject slot, and it was not decided at the time: the cockpit went up
  before `cockpit-surfaces.md` had been read in full, and the justification was written afterwards.

  **It was the SECOND consecutive round to make that exact substitution** — round 6 drove the
  scenario and scored 5/5 oracles; round 7 dropped it saying "the `rust-cli` crate served as this
  round's subject"; round 8 repeated it without noticing. The cause is structural rather than
  budgetary: `rust-cli` leaves a working crate behind, so the slot *looks* filled, and the sequence
  names it immediately before the subject slot. README already predicted this shape one level in
  ("the cheaper one always won"); a guard against the one-level-out version is now in README.

  **Both scenarios were then driven in the second pass** (above), so round 8 is the first round to
  cover all seven. The gap is recorded rather than deleted because the *mechanism* that produced it
  is what the next round needs to know about.

- **`cockpit-surfaces` §4b (notes on a survey) — not driven at all.** The whole note rail — kinds,
  the placement-ORDER check that section exists for, the keys, the thread pane — was skipped for
  budget. **Consequently round 7's explicit instruction to re-file against `51_thread.lua:639` (the
  surviving raise, F30's residue) is still owed**, and it is the highest-value single item for round
  9.
- **`cockpit-surfaces` §5's "three notifications at once" property — not driven**, and the stated
  reason is inherited rather than re-verified: round 6 measured that `qwen3-coder:30b` does not emit
  parallel tool calls, so two pendings never coexist. This round saw **20 approvals, never more than
  one parked at a time**, which is consistent with that but is not an independent test of it. The
  single-pending raise and the **withdrawal** were both driven and passed. Settling the "all at once"
  half still needs the seeded multi-pending fixture round 6 asked for.
- **`cockpit-surfaces` §5's `--no-nvim` comparison — not driven.** F40 makes this more interesting
  than it was: the plain path has only one surface, so it should be *immune* to F40 and is the
  control that would confirm the mechanism from the other side.
- **`failure-injection` §12 (the concurrency proxy) — not driven** as a section. It is partly
  answered anyway: the `provider_wait` record above is the measurement §12 exists to take, arriving
  from lain's own telemetry rather than from `$QA/proxy.rb`.
- **`failure-injection` §3's supervisor door — not reached.** No supervised restart was constructible
  in the sandbox. Stated as untested rather than passed, per the scenario's own instruction.
- **`failure-injection` §3's message-indexed refusal and the null-specific path — not isolated.**
  Both damage shapes re-digested the `message` record and surfaced on the citing **turn** first. A
  probe that damages `causal_parents` *without* changing the record's own digest is what would reach
  them.
- **`failure-injection` §9 step 5 (edit permitted after a full-cover window) — INCONCLUSIVE, not a
  pass.** The read-set assertion `[true, false]` passed, which is the deadlock guard's state; the
  *delivery* was never driven because the model would not issue a bare `edit_file` (MODEL, above).
  What would settle it: a `/ruby` reachable assertion, or a seeded transcript that forces the call.
- **`failure-injection` §8's `bash` output bound and §10's upper bound — not driven.** No tool result
  this round came near 128 KiB (max 2894 bytes) and no `web_fetch` was made.
- **`rails-blog` §2's premise — unbounded tool output — was NOT reached even in the scenario built
  for it.** Largest single tool result 4,713 bytes, 40,306 bytes total across 114 results, **zero**
  caps disclosed. `rails new --minimal` does not emit the "enormous" result §2 assumes. The
  compaction in §1 was driven by turn COUNT, not result SIZE, and the two must not be conflated.
- **`rails-blog` §5's `/model` mid-session switch — not driven**, so the "model switches counted, not
  charged" line was never exercised. And per **F49** the whole `cache_waste` reading is vacuous
  against a local model, so §5 needs a priced-provider session that no scenario currently supplies.
- **`--isolation worktree` — still untouched**, as `rails-blog.md` itself notes. A Rails tree is the
  obvious host and now exists in the sandbox.
- **`rails-blog` §1's deliberate `elide+summarizing` `Overlap` raise — not driven.** The scenario
  invites driving it once, here, since this is the only act that reaches a compacting turn; the pass
  spent its compacting turns on the complement pair instead.
- **`session-and-window` §7's `--compact-strategy nonesuch` through `lain up`** was masked by the
  API-key refusal firing first (the probe omitted `--provider ollama`). The refusal itself was
  verified through `lain chat`; the `lain up` path for that specific flag was not.

---

## Folded back into the method

Applied to `planning/qa/` in the same pass as this document:

1. `method.md` — the `<function=` note now records a contaminated transcript as **a** trigger, not
   **the** trigger, with this round's clean-transcript reproduction (MODEL-2).
2. `method.md` — the `human>` recipe now warns that a `@role` spawn parks the **child's** question,
   so the parent is legitimately idle and §7's elision check is not reachable that way (P5).
3. `failure-injection.md` §2 — read the advertised head with `grep -oE 'blake3:[0-9a-f]+'`, never
   `$NF`, because a damage note occupies the last field (P4).
4. `cockpit-surfaces.md` §4 — the expected mark acknowledgement updated to F38's shipped text (P6).
5. `bench-arms.md` — the wall-time outlier is no longer "unexplained"; it is first-load cost, with
   the warm-repeat measurement that settles it, plus the `num_batch`-does-not-reload reading.
6. `rails-blog.md` **Needs** — the whole measured recipe for standing up the Rails toolchain, since
   its absence is part of why this scenario had never run: the sandbox-local `GEM_HOME`, the
   `PANE_ENV` trap that makes it invisible to the chat pane if exported in the wrong shell, the
   native-gem and `node`/`yarn` dependencies, and the two timings (`rails new --minimal` 19s, 80
   files at `--skip-bundle`).
7. `README.md` — the subject-slot guard: five steps, `rust-cli` is not a subject, `cockpit-surfaces`
   piggybacks on the SUBJECT, and the subject is chosen before the cockpit goes up (see "What was
   not reached").
8. `README.md` coverage notes — `rails-blog` and `bowling-ruby` now record when they were last
   driven, and `rails-blog` records that §1 was first reached on 2026-08-21 while §2 still has not
   been.

**Still owed to the method and not done here:** `method.md`'s "refuse anything reaching outside the
sandbox" should become an allow-list against `$QA` rather than an enumeration of forbidden prefixes
(**P8**), and `rails-blog.md` §2 should say that turn count and result size are different volumes and
that only the first was reached.
