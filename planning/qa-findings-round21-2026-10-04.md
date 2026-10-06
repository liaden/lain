# QA round 21, 2026-10-04

## Summary

A full round over **all eighteen** scenarios in `planning/qa/scenarios/`, driven in nine contexts:
eight forks (`a` to `h`, each with its own sandbox and tmux socket, **at most 4 running at once**, the
cap the round-20 fix plan set) and this context, which drove the `bench-arms` refusals early and its
live runs alone at the end. **Every scenario was driven; none was dropped whole.** Sections not driven
are named in the coverage table with a checked reason. The spine was not sequenced: `session-and-window`,
`rust-cli`, the subject and `rails-blog` ran concurrently in wave 1, taken for wall-clock as in round 20.
No OOM this round (load stayed under 3, `dmesg` clean).

**Round 20's fix plan mostly holds.** All three round-20 HIGHs that were lain's are fixed on their
routes: N1/D-1/H-2 (the symlink read, every row with a control, under `ask`, `auto`, `plan` and a
worktree worker), RB-1 (5 handoffs, each carrying the previous document whole), and BA-1 (`bench arms` now reports: exit 0, every table, no leaked
worktree, and no journal on a refused run). F133/D-2, RB-2, RB-3, E-1's route, E-2, E-3 (SIGHUP), A-1 (`/goal off`
in a cockpit), A-2/B-6 (prose tool call or `max_tokens` now said), A-3, B-1, B-2, B-3, C-1 in the cockpit,
G-3 (docent `/stop`), H-1's listed names, H-3 and F23 are all confirmed fixed.

**New this round: one HIGH that a round-20 fix caused, and the old pattern of the same class one route
past each fix.**

- **B-1 (HIGH):** closing any `lain input` pane ends the chat. Round 20's HUP-as-TERM fix (`692101b6`)
  is trapped inside the pane, and the pane forwards it to the chat as a signal frame.
- **Fh-1 (HIGH):** RB-1 one route over. The handoff summarizer is never shown human turns kept verbatim
  below the newest held cut, but the handoff replaces them. A directive vanished, the document invented
  "use PostgreSQL", and the model built the app on PostgreSQL.
- **A-2/H-2 (MED-HIGH, found by two forks):** `s` at the countdown does not stop a running `bash`
  command on either arm. The side effect lands after the stop, and `tool_cancelled` lists it as `running`.
- **A-1, C-1, H-1, E-1 (MED-HIGH):** `/stop` is lost after an nvim-answered approval; a stopped question
  in a plain chat leaves a stale `human>` that swallows the next prompt; `password.txt` (singular) and 7
  more names release with nobody asked; the consolidate clerk rewrites other lineages' items under its
  own spawn.

| id | sev | what |
|---|---|---|
| **B-1** | **HIGH** | killing any `lain input` pane (even a second client) ends the chat in ~2 s; the pane forwards its own HUP |
| **Fh-1** | **HIGH** | a handoff replaces human turns kept below the newest held cut without showing them to the summarizer; the directive is lost and the document invents requirements |
| A-2 / H-2 | MED-HIGH | `s` at the countdown does not kill a running `bash` (string and term arm); side effects land after the stop |
| A-1 | MED-HIGH | after an approval answered in nvim, lines typed in the input pane (`/stop` included) do not reach the chat until the ask ends |
| C-1 | MED-HIGH | plain chat: stopping a parked `ask_human` leaves its `human>` read open; the next prompt is held unseen or thrown away |
| H-1 | MED-HIGH | `ComposedTerm` approves `cat password.txt` (and `credentials`, `.s3cfg`, `.boto`, `.dockercfg`, `secret.txt`, `token.txt`, `api_key.txt`) holding a low-entropy secret |
| E-1 | MED-HIGH | the consolidate clerk sees the whole manifest, rewrites the human's and other lineages' items under new ids, and stamps them with its own spawn |
| C-2 | MEDIUM | an over-window request mid-ask retries only through a handoff; when ordinary compaction could make room the ask is lost |
| C-3 | MEDIUM | a tool call cut by `max_tokens` (`<tool_call>\n<function=…`) is committed as assistant text with no `malformed_response` |
| Fh-2 | MEDIUM | every tool result reaches the handoff as `[result …, N bytes, elided]`, so a red test run reads as green in the state document |
| Fh-5 | MEDIUM | under `elide-tools+summarize-conversation` the per-result summarizer still runs on each large result, unused (`summary_hits: 0`), once stalling the loop 14.6 s |
| E-2 | MEDIUM | `/rewind N` can land on a user prompt behind a side-effecting call; the next line folds into it and the call runs again |
| E-3 | MEDIUM | Fm-2 not fixed: a prose tool call at the consolidate clerk is detected and then printed as the result, exit 0 |
| E-4 | MEDIUM | `lain improve` at the iteration ceiling exits 1 with only the ceiling line after storing 20 notes |
| G-1 | MED-HIGH | `/implement-epic`: the test engineer is told to write the mirror of `Subject:`, and the layout guard refuses that exact path when the constant lives in another file; neither issue could finish |
| M-1 | MEDIUM | `bench arms` grades a task its arm ended on a detected `malformed_response` as an ordinary wrong answer: 16 of run 2's 8 cells' stops were prose tool calls, and the report and every `grade_record` read like model mistakes |
| B-2 | MEDIUM (UX) | the input pane header is frozen for a whole ask (`fleet:0` for 4 min while a child ran) |
| G-2 | MEDIUM | round 20's G-2 half fixed: a thread on a masked file finds its hunk, but the brief prints the raw line beside the masked hunk, and the docent answered about the wrong line |
| G-3 | MEDIUM | a question re-asked with byte-identical text has the same digest, so it is already "consumed": inbox, HUD and `/status` read 0 while the chat announces it |
| G-4 | MEDIUM | round 20's G-4 by its own criterion: a retried issue journals the same `:spawn` digest as its failed attempt (the status buffer is now live) |
| the rest | LOW to LOW-MED | itemised under "Per-context findings" |

## Round-20 defects re-checked

| id | verdict | evidence |
|---|---|---|
| D-1 / H-2 / N1 (`read_file` through an in-root symlink) | **FIXED** | `d`: 6 link rows with controls, denied target refused `protected`, gated target parks before a byte is read, under `ask`, `auto`, `plan` and a worktree worker; `h`: every link abstains at `ComposedTerm` |
| RB-1 (handoff decays the document) | **FIXED on its route**; Fh-1 is the class one route over | `f`: 5 handoffs, generations 2 to 5 carry the previous document whole |
| BA-1 (`bench arms` cannot report) | **report FIXED**, pre-spend half **FIXED**, leak **FIXED**; the ceiling cell **not reached live** | run 1: exit 0 in 572 s with header, 4 tables and the cost refusal, 32 of 32 `grade_record`s, `git worktree list` 1, `worktrees gc` nothing to reap or keep; 4 refusals exit 1 with no journal; no task hit the ceiling in 2 runs (see M-1) |
| D-2 / F133 (note journals masked text) | **FIXED** | `d`: `anchor_text` `API_KEY=<redacted:1>`, 0 `sk-live-` in the journal before `read_released` |
| H-1 (credential files not in the table) | FIXED for every listed name; class open (new H-1) | `h`: 17 of 17 netrc-content rows abstain; live `_netrc` refused |
| B-1 / B-2 / B-3 (notes, blocker, newline) | FIXED | `b` |
| A-1 (`/goal off` in a cockpit) | FIXED | `a`: held, then "stopped before its next iteration" |
| A-2 / I-2 / B-6 (prose tool call, `max_tokens`) | FIXED on the main chat path | `a`, `b`, `c`; C-3 is the truncated-envelope case it misses |
| A-3 (`/mode auto` refusal) | FIXED | `a`, `d`, `h` |
| RB-2 (`--resume` drops `compact_strategy`) | FIXED | `f`, `a` |
| RB-3 (lone-turn handoff) | FIXED | `f` |
| E-1 (clerk writes human ids) | FIXED on its route; class open (new E-1) | `e` |
| E-2 (provenance), E-3 (SIGHUP mid-spawn) | FIXED | `e`, `c` |
| E-5 (`improve` report) | FIXED on success, not on failure (E-4) | `e` |
| C-1 (stopped ask's inbox row) | FIXED in the cockpit; plain chat has the worse new C-1 | `b`, `c` |
| C-2 (`/stop` held until the ask ends) | FIXED in the plain chat; NOT on the post-approval route (A-1) | `c`, `a` |
| C-8 (second `lain up` on one project) | same failure, now said in a sentence | `c` |
| G-3 / Fv-3 (`/stop` on a running docent) | FIXED | `b` |
| H-3 (unparseable config) | FIXED | `h`: refuses untrusted, then refuses with `config.rb:2: syntax errors found`, exit 1, 0 session files |
| D-3 (`--secret-oracle` inert) | fixed in the code, not proven live | `d`: live needs `qwen3:4b`, which would evict the shared runner |
| F23 (fork/resume over messages) | FIXED | `b`: 22 `message`, 0 unresolved refs, with a control |
| F132 (`/btw` on Anthropic) | FIXED for `/btw` | `e` |
| Fr-2 (non-zero exit is `is_error: false`) | **WITHDRAWN** as documented design | `tools/bash.rb:271`; `a` and `c` independently |
| Fm-2 / N3 (clerk prose tool call) | NOT FIXED | E-3 |
| E-8 (deterministic 500 retried 4 times) | NOT FIXED | `e` (E-7) |
| B-4 (newest ended child) | partly: right rows, arrival order | `b` |
| D-5 (`x` marks a changeset row unopened), D-6 | unchanged | `d` |
| H-4, H-5, H-7, RB-4, C-3 (stderr line) | unchanged, out of scope by the fix plan's ruling | `h`, `f`, `c` |
| H-6 (`chmod 000` snapshot) | unchanged but now said (`snapshot_degraded`) | `h` |
| r20 A-4 (`closing in 60s` after `c`), r20 A-5 (Symbol array) | NOT FIXED | `a` |
| G-1 (`epic add` ids) | FIXED | `g`: 3 bad ids exit 1, `epic.md` unchanged |
| G-2 (anchors under a mask) | HALF FIXED | new G-2 |
| G-4 (status frozen during `/implement-epic`) | PARTLY: buffer live, spawn digest repeats | new G-4 |
| Fv-4 / r20 G-6 (two path bases) | NOT FIXED | G-9 |
| I-1 (retired `CLOUD_WINDOWS` rows) | FIXED | `g`: 19 keys, all 200 on `/api/show`, none above the weights' `context_length` |
| 410 and `max_tokens` on the cloud arm | FIXED | `g`: `Model retired: …` after 1 `request_sent`; `model hit max_tokens before finishing` |
| §3 cold-window row (round 20 inconclusive) | PASSES | `a`: 8192 guessed, then 32768 probed |
| §12 control 1 (round 20 inconclusive) | taken | `c`: 35 KB prefilled in 3.68 s, no reload |

## The HIGHs

### B-1: closing an input pane ends the chat

`692101b6` (round 20's T16) made HUP act like TERM in `signals.rb:25`. `lain input` runs under the same
traps, so `tmux kill-pane` delivers HUP to the pane, the trap catches it, and `InputPane#signal`
(`input_pane.rb:134-138`) forwards it to the chat as a signal frame. The chat closes with
`session_closed reason=exit` in about 2 s. **Control:** `kill -9` on the pane process (no trap runs) leaves
the chat alive, and a respawned pane reconnects and redraws `you>`. Reproduced twice, once on a second
client that had just delivered a line exactly once. **Repro:** `lain up`, then `tmux kill-pane -t
<input pane>`. **Fix shape:** the pane forwards only keyboard INT and QUIT, never its own HUP or TERM.
Pin it with a spec that a HUP to a connected `lain input` leaves the chat running.
Evidence: `~/tmp/lain-qa-2026-10-04-b/xdg/state/lain/sessions/eaad0da0d4b9/20261004T142353-645917*`.

### Fh-1: a handoff drops the human turns below the newest held cut

`held_cut.rb:322` (`uncollapsed`) passes on only messages at or above the newest cut, and `:301`
(`replacements`) carries only what the cuts collapsed. A turn kept verbatim below the cut is in neither,
but the handoff replaces everything from message 0. In plain chat (`rb1`) the directive was message 0 of
the refused prompt and had 0 hits in the summarizer input; generation 1 invented "use PostgreSQL" and the
model ran `rails new --database=postgresql`. In the cockpit, all 3 human asks had 0 hits in a 23 KB
summarizer input against a 39,907-byte budget, so this is not truncation for size. **Fix shape:** feed the
handoff every message in its range that no held collapse covers; pin with a spec that a lone first turn
survives into the summarizer's request. Evidence: `~/tmp/lain-qa-2026-10-04-f/records/`.

### Bench arms, driven by this context alone

Driven with the box to itself (load 0.43 at start, no other lain process), from an empty-commit
repository at `~/tmp/lain-qa-2026-10-04/arms-repo`, `--cheap-model qwen3:4b --num-ctx 32768`.

**Run 1, the shipped fixture (8 tasks, 4 arms): the report renders for the first time in 3 rounds.**
Exit 0 after 572 s. The header names the fixture path passed, `qwen3-coder:30b` and `worktree`, and no
credential or base URL. The three-check oracle holds: grade means 0.375, 0.646, 0.938 and 0.562, all far
above 0.0625; non-zero on tasks other than `fix-off-by-one-loop`; every arm has a non-zero token row
(mean 35,045, 84,920, 114,654 and 30,718). The cost section refuses whole (`not priced — no price for
model "qwen3-coder:30b"`) rather than printing 0. A new `cache write tokens` table reads `not measured`
in every cell, which is honest for ollama. 3 runner starts during the run, all `-b 2048` (the 30B and
the 4B swapping), and no `-b 512`. No stall record. After the run `git worktree list` is 1 line and
`lain worktrees gc` says "nothing to reap or keep": **BA-1's 28-worktree leak is fixed.**

**Run 2, a ceiling fixture (2 tasks, 4 arms): the ceiling was still not reached.** The fixture
(`records/tasks-ceiling.yml`) asks for 40 files with one tool call per reply and a read-back after each,
which should need about 80 calls. Every arm ended that task in 0.2 to 29 s. Exit 0, the report rendered.

### M-1: a malformed stop is graded as a wrong answer

Run 2 journaled 16 `malformed_response kind=prose_tool_call` records over its 8 cells (run 1: 3), for
example a `write_file` for `out/hello.txt` written as `<function=write_file>` prose. Each such cell
reads as an ordinary `0.0` with `why: … contains "hello" (did not hold)`, and the report has no cell
like the ceiling's `failed: ceiling (task N)`. **Mechanism:** `Arm::Driver#run_task`
(`lib/lain/arm/driver.rb:192-197`) rescues only `Agent::Budget::Exceeded`; nothing under `lib/lain/arm`
or `lib/lain/bench` reads `malformed` or the agent's failure reason, so a detected failure ends the
task as a normal completion. **Why it matters here:** the bench's deliverable is the comparison, and
`single-thread` scoring 0.000 on "write one file" in run 2 is the model's format, not the arm. This is
round 19's Fp-1 / round 20's A-2 class (a detected failure that the surface does not show) on the
bench path. **Repro:** `lain bench arms records/tasks-ceiling.yml …` as above, then count
`malformed_response` against the report. **Fix shape:** treat a malformed stop like the ceiling, a
named failed cell (`failed: malformed (task N)`) plus a `grade_record` whose `why` says so; pin it with
a driver spec whose provider returns a prose tool call. **The ceiling cell itself** stays driven only
by `spec/lain/arm/driver_spec.rb`'s "a task that hits the ceiling": on this model a malformed stop
arrives first, so a live drive needs M-1 fixed or a scripted provider.

## Per-context findings

Full text, repros and evidence paths are in each fork's `~/tmp/lain-qa-2026-10-04-<x>/records/fork-report.md`.

| ctx | scenarios | findings |
|---|---|---|
| a | session-and-window, rust-cli, repl-commands | A-1 MED-HIGH (input pane goes deaf after an nvim approval: it forwards an ungenerationed line only after an `unpublished` frame, `input_pane.rb:217/233/241`); A-2 MED-HIGH (`Shell::Pipeline::Run#collect`, `pipeline.rb:419-424`, kills the groups only on `Timeout`/`StandardError`, and `Async::Stop` is neither); A-3 LOW (`/meta summarizer` names `/meta run`); A-4 LOW UX (`--resume <absolute path>` refuses); A-5 LOW (`/fork` calls an approval "a question") |
| b | bowling-ruby (5/5), cockpit-surfaces | B-1 HIGH; B-2 MEDIUM UX (header frozen for an ask, documented at `input_pane.rb:33-39`, contradicts §0 checks 3-5); B-3 LOW-MED (survey thread anchors outlive a settled review, `51_thread.lua:64-69`); B-4 LOW-MED (docent brief names the hunk heading, not the line, `review/docent.rb:61-66`; it answered about line 3 when asked about 7) |
| c | failure-injection, prompt-slots-and-roles | C-1 MED-HIGH (`intake.rb:221` read not withdrawn on retire, `:174` never redraws `you>`); C-2 MEDIUM (`agent.rb:628` retries only on handoff, `compaction/source.rb:515`); C-3 MEDIUM (`decoding.rb:153` needs a closed envelope); C-4 LOW-MED (empty `LAIN_CONNECT_TIMEOUT` disables the timeout: 9 m 01 s, `configuration.rb:93/186`); C-5 LOW instrument (`session.read?` stale between asks); C-6 LOW (size refusal splices its hint as an "or") |
| d | secret-boundary, changeset-review | D-1 LOW-MED (changeset thread anchors carry into the next review of the same file, `47_diff.lua:221/608` against `51_thread.lua:67-69`; B-3's class); D-2 LOW UX (`read_file` on a loop or dangling link says `no such file`, `file_target.rb:41`); D-3 LOW UX (`/mode auto` final refusal says both "switch to /mode ask" and "no approval will lift this", `escalation.rb:633`); D-4 LOW (directory `exempt` refusal gives no `:N`); D-5 LOW (`--secret-oracle` help text stale); approval row shows the link name only (already a fix-plan follow-up) |
| e | subagents-and-backends, memory-and-dogfood | E-1 MED-HIGH (`consolidation.rb:124/143-145`, `Memory::Ownership.permit!` guards only chat items); E-2 MEDIUM (`cli/command/rewind.rb` refuses only an assistant `tool_use` landing, `agent.rb:355-360` folds the next line in); E-3 MEDIUM (`consolidation.rb:104-106` reads `.text` with no failure check); E-4 MEDIUM (`cli/improve.rb:208-210`); E-5 LOW-MED UX (`lain watch <typo>` silent until the session closes); E-6 LOW-MED gap (the consolidation journal names no lineage); E-7 LOW (r20 E-8); E-8 LOW (`memory_read` adds `author:` and returns 16,397 bytes against a 16,384 ceiling); E-9 LOW (a refused launch outside a repo still starts the daily `worktrees gc`) |
| f | rails-blog | Fh-1 HIGH; Fh-2 MEDIUM; Fh-5 MEDIUM; Fh-3 LOW-MED UX ("nothing is droppable … start a new session" after a handoff just made room); Fh-4 LOW-MED UX (the `--resume` keep notice is cleared by the screen and never journaled); Fh-6 LOW-MED UX (`elide+summarizing`: every later ask fails the same way and still commits the line); Fh-7 LOW UX (`--no-nvim` question says "ticking boxes is the nvim buffer") |
| g | survey, epic-tier, ollama-cloud-arm | G-1 MED-HIGH (control: re-planned as a new module `Shouter`, the guard journaled `test_layout_deferred` and the red commit landed); G-2 MEDIUM (`docent.rb:663` maps to masked numbering, `:881` prints `anchor.line` raw); G-3 MEDIUM (content-addressed question identity); G-4 MEDIUM; G-5 LOW-MED (`/stop` on a docent leaves `(thinking …)`, then says the session ended, `docent.rb:585-596`); G-6 LOW-MED (red step ignores `tests preset: :rspec` and probes for a framework, `factory.rb:1416`); G-7 LOW-MED (`lain epic land` suggests `git switch epic/demo`, which fails because lain's own `landings/<slug>` worktree holds it); G-8 LOW-MED (a failed evidence spike points at a `malformed_response` record that `Channel::Null` never keeps); G-9 LOW (Fv-4: two path bases, `tmp/t7/calc.rb` against `../../tmp/t7/calc.rb`); G-10 LOW UX (`epic status` says `epic_plan` while submit refuses "research not approved"); G-11 LOW UX (a stage-name typo is answered with `ANTHROPIC_API_KEY is not set` when any stage is adjudicated); G-12 LOW (`/review <branch>` and `/implement-epic` assume `main`) |
| h | shell-terms, shell-term-approval | H-1 MED-HIGH (`sensitivity.rb:574-580` lists `passwords.txt` only; `composed_term.rb:483` finds no region in a bare word; control: the same name with netrc content parks); H-2 MEDIUM (A-2 confirmed on both arms: `sleep 20 && touch z1.txt` created the file 9 s after `s`); H-3 LOW (4 stale scenario claims) |
| me | bench-arms | M-1 MEDIUM, below |

**Same class one route past each fix, again.** G-2 is round 20's G-2 at the brief instead of the hunk; Fh-1 is RB-1 at a second range; H-1 is round 20's H-1 one
name over; E-1 is round 20's E-1 on other lineages' items; D-1 and B-3 are round 20's B-1 at the thread
anchor layer instead of the note layer; C-1 is round 20's C-1 on the plain path; A-1 is round 20's C-2 on
the post-approval route. B-1 is new in kind: a fix (T16) that turned a silent hang into a lost session.

**Withdrawn on the mechanism:** Fr-2 (documented at `tools/bash.rb:271`, by `a` and `c`); `c`'s §11c
clean-exit check (the pane switches to `remain-on-exit failed` only once a client attaches); `e`'s
"SIGHUP 75 s late" (the HUP was sent later than recorded); `e`'s bm25 recall ceiling (r20 E-7: `bm25`
returns only scoring matches, so both lexical arms cap at 0.333 on this corpus); `h`'s "a human `n` and a
timeout journal the same reason" (`escalation.rb:686-712` tells them apart); `f`'s 84 lockfile checksums
parked as secrets (`ARCHITECTURE.md:887` names that trade).

## Model behaviour (not lain defects)

- A bare or unterminated `<tool_call>` / `<function=` in prose (`a`, `c`, `d`, `e` six times); one cockpit
  restart in `a`.
- Looping `todo_write` / `session_usage` to the 25-call ceiling (`a`, `c`, `h`), and `improve` looping on
  "nothing found" notes (`e`).
- Refusing from context after a denial, or calling `ask_human` instead of retrying (`b`, `d`, `h`).
- Claiming a green suite while it was red (`f`; Fh-2 is what let the state document agree), and claiming
  "All tests pass" with 2 failing specs (`b`, bowling).
- Ending every unfinishable `/goal` in iteration 1 with `GOAL_COMPLETE` (`a`), which leaves the cap and a
  mid-drive `:LainGoalOff` unreachable.
- `/critique` raised a false BLOCKER (`b`).

## Environment and process

**Box.** ollama 0.34.4 from `/mnt/nvme/opt`, already serving at round start (pid 252763, started
2026-10-03 16:52), `n_slots = 1`, `OLLAMA_NUM_PARALLEL:1`, runner `-b 2048 -c 32768`. Load stayed under 3
with 4 forks; no OOM. One runner re-key: `a`'s `session-and-window` §6 1024 row moved the shared runner
to `-b 1024` at 09:48:42 local until another fork's request restored it at 09:49:29 (P-a1 below).

**Process lessons**, to fold into `method.md`:

- **4 concurrent forks held** where 9 OOM'd. Keep the cap.
- **P-a1:** `session-and-window` §6's 1024 row should go to a capturing listener that does not forward,
  or it re-keys the shared runner.
- **A fork can run out of turns.** `g` stopped at its 200-turn limit mid `epic-tier` and had to be
  resumed. Give a fork at most 2 heavy scenarios, and have it write its report incrementally.
- `pkill -f` and `ps | grep '[x]' | xargs kill` both self-matched again (`f`). Look up the pid in one
  call and kill it in another.
- `$QA/sever.rb` (`c`: one proxy with pass, counts_absent, unterminated, hold, rst and gone modes) and
  `settle.sh` (round 20 `a`) are worth promoting into `qa-sandbox.sh`; `settle.sh` should accept
  `you> <carried text>`.
- `reply.sh` uses `bufwinid`, which only searches the current tab (`b`).
- In a plain chat, wait on journal records, not on a `you>`/`human>` last line: a stale `human>` fired the
  wait and lost a prompt (`c`).
- zsh `VAR=$x` with `x` empty exports an empty variable; that is how C-4 turned up. `unset` instead.
- `tmux new-window` without a target lands in the cockpit's session once `lain up` ran (`f`).
- Under a redirected HOME, `--exec docker` (podman) needs `HOME=/home/tara` on the chat's launch line (`h`).
- A deny helper matching `*[y/N]*` re-fires on the answered line; anchor it at line end (`h`).
- A one-shot child parked on `ask_human` holds its lease indefinitely: a cheap live lease for collision
  and SIGHUP tests (`e`).

**Process lessons are folded into `planning/qa/method.md` under "Round 21".** **Scenario corrections proposed by the forks** (not applied this round; each fork report lists them in
full): `cockpit-surfaces` §0 checks 2-5 and §5's three-rows shape; `failure-injection` §1b, §3, §6, §8,
§9, §10, §11c; `prompt-slots-and-roles` §4 (18 roles); `rails-blog` §1b, §2 (16 KiB caps); `secret-boundary`
§4, §4b, §5c, §7, the A-3 fixture; `changeset-review` §2, §6; `shell-term-approval` §3a (`capture:`), §5,
§7; `shell-terms` §6/§9 (no `shell_arm` for a refused call); `subagents-and-backends` §2 wording;
`repl-commands` `/introspect` text and §7's `GOAL_COMPLETE` confound.

## Coverage: all eighteen scenarios

| scenario | ctx | driven | not driven, and why |
|---|---|---|---|
| session-and-window | a | every section, §3's cold-window row cold for the first time since round 19 | §6 anthropic half: `ANTHROPIC_API_KEY` unset, `.envrc` exports 0 `ANTHROPIC*` |
| rust-cli | a | happy path, compile error, Ctrl-C, ceiling | two gated calls in one turn never occurred |
| cockpit-surfaces | b | §0 to §8 on the bowling session, both §5 postures | detach/reattach (no real terminal client); re-arm over an older binary; grandchild row (the researcher role has no spawn tool); bell and layer lighters, `--no-nvim` §5b table, guard 4 (budget); CJK and escape rows inconclusive from a live model, driven on the row object instead |
| failure-injection | c | §1 to §12, both §12 controls | §3 supervisor door (`Supervisor::Restart` has no caller in `lib/`); §8 `lain-core` arm (no core build); §10 upper bound unreachable (every tool capped at 16 KiB) |
| bowling-ruby | b | §1 to §3, oracle **5/5**, F23 fork/resume | `/meta summarizer` (budget) |
| bench-arms | me | the 4 pre-spend refusals; live run 1 (8 tasks, 4 arms); live run 2 (a ceiling fixture) | the variance and `failed.ndjson` set-aside path (budget) |
| rails-blog | f | §0 to §5, §1b sticky cut, `/rewind`, resume, 5 handoffs | §1b `collapse` cut not reached (decision record does not say whether one was offered); §5 `/model` switch (a second model would evict the shared runner); `/pin` in a held range (stated open decision) |
| repl-commands | a | §0 to §9 | §2 4-hex ambiguity (~300 turns) and a pin across a real compaction; §3b live-worker, symlink and directory refusals (budget); §4 `/keep` with actors (no chat actor path); §7 cap and mid-drive `:LainGoalOff` (the model ends every goal in iteration 1) |
| epic-tier | g | §0 to §9, §10a to §10e, §11 buffer, §12 land refusals, §13a, §13c | §1c checks 4 and 6, §10c width/Ctrl-C, §10d timeout leg, §11 cross-process catch-up (budget, after `g` hit its turn limit); §12 landing blocked by G-7; `finish` forge half by decision (`gh` is logged in to a real account); §13b inconclusive (the driver fast-forwarded `epic/demo` by hand) |
| secret-boundary | d | §0 to §5c, §7 | §6 live oracle: needs `qwen3:4b`, which would evict `qwen3-coder:30b` from a 24 GB card the other forks shared |
| changeset-review | d | §0 to §8 | §7 route to github.com not cut; per-child wall-clock not recorded; merged critique header inconclusive (scrolled out, in no record) |
| subagents-and-backends | e | §1 to §6 | actor mode, depth cap, nested third path, live-actor tail (no chat path); docker-daemon-stopped negative (podman has no daemon) |
| memory-and-dogfood | e | §1 to §6 | `StaleEmbeddings` (`bench sweep` has no `--model`); missing-corpus refusal (needs a file under the repo's `lib/` moved); legacy authorless row |
| ollama-cloud-arm | g | steps 1, 3, 4, 5 (2 paid completions) | step 2 inconclusive (bearer destination not captured); step 5 crash-recovery half (budget); step 6 by decision (burns quota) |
| survey | g | §1 to §7 | none; `lib` is now 904 files, 187,232 lines |
| prompt-slots-and-roles | c | §1 to §4b, §6 free half | §6 paid half (no Anthropic key, checked as above); §5 spec-covered by its own text |
| shell-terms | h | §0 to §8 | §9 paid half (no Anthropic key); a local stand-in is not a distribution |
| shell-term-approval | h | §0 to §3a, §4a, §5 to §8, §10, §11 | §7a ask path unreachable by design (the pre-check reads the same bytes); §4b belongs to secret-boundary |

Halves marked **Automated by** in `cockpit-surfaces`, `failure-injection`, `session-and-window`,
`repl-commands` and `memory-and-dogfood` were skipped and rest on `spec/e2e`.

**Close-out negatives**, taken at 16:05 UTC in a shell with `XDG_*` unset and `HOME=/home/tara`:

- `find /home/tara/.local/state/lain -newermt 2026-10-04T13:43:27Z` = **0**; positive control (`-newermt 2026-09-01`) = **1322**.
- `git status --porcelain`: the baseline ` M references/repos/smolagents` plus this file. Nothing else.
- `ls -d /home/tara/dev/lain/.lain` and `~/.lain`: neither exists.
- `dunstctl count displayed` / `waiting`: 0 / 0.
- No round tmux server is running (10 stale socket files, all "no server running"), no `exe/lain` or
  sandbox nvim process remains, nothing listens on 3000, 3010 or 21500-21599, and no `lain` container exists.
- Sandboxes `~/tmp/lain-qa-2026-10-04` and `-a` to `-h` are left in place as evidence. Fork `e` left
  one retained checkout on purpose (`retained/c32b6a70dd5b-3988c777`).
