# QA round 5 — 2026-08-18

## Summary

**All seven scenarios were opened; five completed, one completed on its lain-side seams
with the model failing its own half, and one (`rails-blog.md`) was not reached.** Every
round-4 defect re-checked behaves differently, and all of them better — including both
session-killers.

**Three new defects, five UX findings, four process defects in the bench's own method.**

| id | sev | what |
|---|---|---|
| **F23** | **HIGH** | a session carrying `message` records as causal parents can be neither forked NOR resumed — permanently stranded, while `lain sessions` reports it healthy |
| F24 | MED | the desktop notifier is single-flight: it blocks up to 300s on the first pending approval, so only the first of N is ever notified, and it keeps displaying an already-decided command |
| F25 | MED | the T16 hit-enter residual fires in ORDINARY cockpit use, not just a resized window — and it blocks the nvim RPC entirely |
| UX4 | MED | `lain://approval` is never primed, so it does not exist at rest despite `ApprovalView::EMPTY` being defined |
| UX5 | LOW-MED | `compaction.tokens_before/after` is a byte-length proxy sitting beside provider token counts under near-identical names; against the window it reads 80% where every other reader says 32% |
| UX6 | LOW-MED | the `lain up` dead-pane banner always eats the FIRST line of a refusal — the line naming the cause |
| UX7 | LOW | a single-line file gets advice it cannot act on; the correct long-line refusal only arrives on the second attempt |
| UX8 | LOW | retry backoff renders 17 significant figures (`retrying in 0.14368744774438316s`) |

Plus four defects in the QA method itself (P1–P4), two of which silently void probes, and
three model failure modes (M1–M3), all previously documented and all reproduced.

**The through-line in F24/F25/UX4 is the approval and refusal SURFACES again** — the same
area that produced four of round 4's seven. Round 4's card was "lain's refusals are
well-written and then delivered as crashes"; that is fixed. The round-5 card is narrower:
**the refusals are now well-written and well-delivered, but the surfaces that carry them
are single-flight, unprimed, or sized wrong.**

**Compaction at scale was reached only incidentally.** A real compaction fired during
`rust-cli.md` — the first any QA round has recorded — triggered by `plan_step_completion`
rather than by occupancy. That is not `rails-blog.md` §1 and does not discharge it, but it
is the first evidence in this bench that the path executes end to end.

---

Bench: ollama 0.32.12 (/mnt/nvme), qwen3-coder:30b, OLLAMA_CONTEXT_LENGTH=32768,
KEEP_ALIVE=5m, KV q8_0, Vulkan, LAIN_NUM_BATCH=2048.
**n_slots=1 / OLLAMA_NUM_PARALLEL=1**, read from the runner's own argv (`-np 1`) rather
than the serve log, because the server was a pre-existing 12h-old process this round reused
rather than restarted; its environ was verified to be the correct /mnt/nvme install first.
`-b 512 -ub 512` in the same argv confirms bench.md's reason for LAIN_NUM_BATCH.
Cold load of qwen3-coder:30b measured **29.6s**.
Machine at round start: load 1.32, `mempalace mine` at 98.5% CPU throughout (the known
contaminant), no orphan spinners, no parallel_rspec, no pre-commit.
cargo 1.99.0-nightly, tmux 3.7b, dunstify at /usr/bin/dunstify (all three preconditions met).
Sandbox: `~/tmp/lain-qa-round5-2026-08-18`, XDG redirected, `tmux -L lain-qa-round5-2026-08-18`.
All three panes verified carrying sandbox `XDG_*` and `TMPDIR` before act 1.

**Negative check PASSES and is not vacuous:** `~/.local/state/lain` exists and holds 95
files; its newest file predates round start by 4 minutes; `find ~/.local/state/lain
-newermt '2026-08-18 22:26:05'` returns **0 files**. `~/.lain` absent throughout.

## Round-4 defects re-checked — every one better

| id | verdict | evidence |
|---|---|---|
| **F18** (2nd approval never renders; `--no-nvim` wedge) | **FIXED, both paths** | SEVEN gated `bash` calls in one `rust-cli` turn, every one rendered its own prompt and every `y` was consumed. Re-driven on plain `lain chat --no-nvim`: `echo HELLO` then `echo WORLD` both prompted, both consumed, both ran. `approval_decision` records carry `surface:"tty"`, `verdict`, `timed_out:false`, `latency`. `tty_fault=0`. |
| **F21** (ceiling per-SESSION, silent death) | **FIXED** | `turn_usage=38` in one rust session and `=23` in bowling, with answers still arriving and `run_interrupted=0`. When a single ask DID exhaust it, the pane rendered `error: loop ran 25 iterations, ceiling is 25` and returned to a live `you>`. All three of failure-injection §7's checks pass. |
| F17 (frozen `lain://timeline`) | **FIXED** | Driven with the real trigger (a multi-line reply), not the two-asks probe: buffer moved 4 → 8 → 10, multi-line prose flattened to one row, **zero** `one-line-per-record` markers. |
| F22 (verdict refusal as Lua traceback + modal) | **traceback FIXED; modal residual WORSE than documented** | No `stack traceback:` anywhere in `:messages` across five refusals. The hit-enter modal still fires — see **F25**. |
| F20 (budget refusal as Async backtrace) | **FIXED** | Every launch refusal measured this round: exit 1, **zero** `in '` backtrace frames, one line. 19 distinct refusals checked. |
| F16 (give-up under-reports by one) | **FIXED** | Renders `1, 2, 3, 4`; give-up names a HIGHER ordinal than the last retry. Counting listener + timestamps prove 4 rendered ordinals == 4 real model-call attempts (the 2 extra accepts are window probes, grouped 1.98s/2.01s vs the retry backoffs at 2.02–2.82s). |
| F19 (`inbox_count` disagreement) | not re-driven | inbox was exercised but the specific disagreement was not probed. |

Also re-confirmed fixed: **T6** (window re-resolves mid-session), **T18** (`lain://journal`
placeholder, and the attach-message supersede), **T15** (notifier sweeps instead of
consuming), **T1** (price table), **T12** (bench-arms attribution header and cost
degradation), and the **2026-08-06 `lain up` whole-server death**.

---

## New defects

### F23 — HIGH — a session with `message` causal parents cannot be forked OR resumed

A session in which a subagent message becomes a causal parent is **permanently stranded**:
both continuation paths refuse, and nothing about the session looks wrong until you try.

```
$ lain sessions
20260818T233214-2694924.ndjson  2026-08-18T23:32:14  51 turns  open  blake3:01f23e4ad01f

$ lain chat --fork '20260818T233214-2694924.ndjson@blake3:01f23e4ad01f'
cannot fork ...: turn record 26 (user) cites a causal parent this fold never landed:
no object "blake3:6efd2c62..." in store: putting "blake3:1845d569..." would dangle

$ lain chat --resume 20260818T233214-2694924.ndjson
cannot resume ...: <the identical message>
```

**Why this is not corruption.** Every `causal_parents` digest in that journal resolves
against a digest the journal itself records — scanned mechanically: 102 recorded digests, 9
causal refs (7 unique), **0 unresolved**. The cited object `blake3:6efd2c62…` is present, as
a `type=message`, `kind="message"` record carrying `from`/`to`/`payload`/`correlation`. The
**fold** simply never lands `message` records in the store before validating the `turn` that
cites one.

**Control, and it is clean.** The `rust-cli` session — digest-bearing types
`request_sent`/`turn_usage`/`turn`/`changeset_opened`, and **no `message` records** — forks
at its head with **exit 0**.

**The fork point does not matter.** Forking at a digest recorded *before* the first
`message` record (line 95 of 199) fails with the byte-identical error, because the fold
replays the whole journal before selecting the fork point. There is no reachable fork point.

**Reproduction**
1. Run a session until the model spawns a subagent that messages (`@researcher[/critique] <path>`
   is the reliable grammar; `child_turn` and `message` records appear).
2. `lain sessions` — the session reports healthy, N turns, a valid head.
3. `lain chat --fork '<session>@<any recorded digest>'` → refuses as above.
4. `lain chat --resume <session>` → same refusal.
5. Repeat against a session with no `message` records → forks, exit 0.

**Severity.** `fork` is a headline capability (CLAUDE.md: "`fork` is O(1)") and `--resume`
is the ordinary way back into a session. Both are lost, silently, for exactly the sessions
that used the fleet. The refusal is well-formed (index, role, both digests, exit 1, zero
frames) but its vocabulary is the *damaged-session* vocabulary, so a reader will reasonably
suspect corruption that is not there.

### F24 — MED — the desktop notifier is single-flight and shows a decided command

`Notify#sweep` (`lib/lain/notify.rb:212`) selects every unraised pending and calls
`notify_about` → `decide` → `run(...)` on each **in series**, and `decide` blocks for the
whole of `dunstify`'s window. Its own docstring states this: *"The snapshot is materialized
before the first {#decide}, which blocks for the whole of dunstify's wait."* The notification
is issued as `dunstify -a lain -u critical -t 300000 -A approve,Approve -A deny,Deny`, so
the block is up to **300 seconds**.

Measured during `rust-cli`, three gated calls in one turn:

- call #1 at 18:42:51 → one `dunstify` pid 2665360, `Currently displayed: 1`. Correct.
- call #1 approved on the TTY at ~18:43.
- calls #2 and #3 arrived, prompted on the TTY, and were answered — **with no notification
  at all**.
- at 18:46, pid 2665360 was **still alive and still displaying call #1's command text**,
  while the pane was on call #3.

So the T15 fix is real — the notifier no longer *consumes* the queue, and the TTY prompt
renders (F18 fixed) — but the notification *feature* is degraded to one approval per 300s
window, and the desktop shows an already-decided command while a different one is pending.
`cockpit-surfaces.md` §5 names exactly this trap: *"A fix that stopped the wedge by silencing
notification would pass every check above and remove a feature."*

Not a safety hole: first answer wins, so clicking the stale notification is a no-op. It is a
misleading surface and a lost feature.

**Precondition recorded, per §5:** `dunstify` WAS on the chat pane's PATH (`/usr/bin`), so
this section tested something. A lain notification is visible in `dunstctl history`
(`[lain] lain asks …`), so the notifier is live, not inert.

### F25 — MED — the hit-enter residual fires in ordinary use, and blocks the RPC

`cockpit-surfaces.md` §4 records the modal as a measured residual that the bench's own
sizing avoids: *"`method.md` sizes the QA server at 220×50 precisely so this does not fire."*
**That premise is false in the cockpit.**

Measured, this round:

| | width |
|---|---|
| tmux server / window | 220 |
| **nvim pane** (`lain up` splits it with chat) | **110** |
| the `:LainReviewVerdict approve` partial refusal | **225 characters** |

**Corrected after grounding (2026-08-18, post-filing):** the first edition of this finding also
cited the review tab's window widths (40/32/36) as the constraint. That is wrong, and the repo
already knew it — `lib/lain/review/surface/neovim.rb:186-203` records, verified against a real
embedded UI, that `nvim_echo` writes the MESSAGE AREA (`&columns` wide, `&cmdheight` tall) and
**never reads the window**. The binding number is therefore the nvim PANE's 110 columns, not the
40-column sidebar. The finding stands unchanged — 225 characters at 110 columns still pages every
time — but the mechanism is `&columns`, and a fix aimed at window width would miss.

**The operational consequence is the part worth fixing:** the modal blocks the **nvim RPC**,
not just the keyboard. `nvim --server … --remote-expr "execute('messages')"` hung for the
full 2-minute timeout and only returned after `Enter` was sent to the pane through tmux. So
the documented recovery path — reading `lain://approval` or driving `:LainApprove` over RPC —
is unavailable exactly while a refusal is on screen.

The contrast is clean and confirms the mechanism: the *short* refusal
`lain: no hunk on lain://review line 1 -- nothing on that row can be marked` did **not**
block.

**What is genuinely fixed:** no `stack traceback:` in `:messages` after any refusal, and the
text is correct — `lain: approve is refused over a changeset that is not fully reviewed:
lib/empty.rb is unreviewed -- mark every hunk, or open the session with
Lain::Review::Verdict::Policy::Permissive.new if this run means to judge regardless`.

---

## UX findings

### UX4 — MED — `lain://approval` is never primed

At rest, `bufexists('lain://approval')` is **0**. The other six views prime correctly:
`lain://journal` `(no streamed tool output yet)` (the T18 fix, confirmed), `lain://timeline`
`(no turns yet)`, `lain://workspace` `(no reminders)`, `lain://inbox` `(no questions
pending)`, `lain://diff` `(no requests yet)`, `lain://request` `(no request yet)`.

`ApprovalView::EMPTY = ["(no approvals pending)"]` exists (`approval_view.rb:79`) but is
reachable only at `approval_view.rb:298`, during a render, once a pending has already
arrived. `Buffers#initial` (`buffers.rb:285`) returns only timeline/workspace/diff plus
inbox, and `Surfaces#prime` primes `@journal_view`, `@buffers` and `@request_buffer` — the
approval view is not among them.

The buffer springs into existence on the first approval (verified: `bufexists` → 1, holding
the full command text and the `-- y approve, n deny  (:LainApprove / :LainDeny)`
affordance), so nothing is functionally lost. But `Surfaces#prime`'s own docstring gives the
principle — *an idle session that shows no buffers reads as "broken"* — and this is the one
view that still does. It is the same shape as the `lain://journal` defect T18 fixed.

### UX5 — LOW-MED — two incompatible token units in one record stream

For the compaction that fired during `rust-cli`:

```json
{"type":"compaction","trigger":["plan_step_completion"],"cache_state":"cold",
 "tokens_before":26174,"tokens_after":21867,"cost_saved":"0.0","cost_spent":"0.0"}
```

while the `compaction_decision` for the same moment reads `window_tokens=32768`,
`used_tokens=10641`, and the HUD reads `ctx 33%`.

`tokens_before/window_tokens` = **80%**; every other reader says **32%**. This is documented
scope, not a bug — `telemetry/compaction.rb:50` says these are *"the SAME canonical-byte-length
proxy … one consistent unit across the compaction subsystem"*. But both figures are called
"tokens", they sit in the same NDJSON stream, and nothing in the record names the unit. The
bench's product is the comparison, so a figure that cannot be divided by the window sitting
next to one that can is a record-legibility defect.

`cost_saved`/`cost_spent` of `"0.0"` beside a local model is **correct and documented**
(`CLI::Backend::COMPACTION_PRICES` degrading to the zero fallback), not a free compaction.

### UX6 — LOW-MED — the dead-pane banner always eats the refusal's FIRST line

failure-injection §11 passes on its main claims: the tmux server **survives**
(`has-session` = 0), the chat pane is held `pane_dead=1 status=1`, and `remain-on-exit` reads
**`failed`**, not `on`, so a clean exit still closes the pane. tmux 3.7b, so the section is
meaningful rather than a no-op.

The residual is sharper than documented. §11 says one-line refusals are lost while
"two-plus-line refusals (a missing key prints several) survive". Measured:

| refusal | lines | what the pane retains |
|---|---|---|
| `ANTHROPIC_API_KEY is not set; --provider anthropic needs it to build a client` | **1** | nothing but the dead banner |
| Thor's `ERROR: "lain chat" was called with arguments […]` + `Usage: "lain chat"` | 2 | only `Usage: "lain chat"` |

So it is not "one-liners are lost and multi-liners survive" — **the first line is always
lost, and the first line is the one naming the cause.** A 2-line refusal degrades to a
`Usage:` line that tells the operator nothing.

Note also that the missing-key refusal is now exactly **one** line, so the very example §11
cites as its multi-line control is in fact the one-line case (see **P3**).

### UX7 — LOW — a one-line file is advised to use a window that cannot help

`read_file` on a 1.2 MB single-line JSON returns `big.txt`'s advice:

```
one.json is 1200003 bytes, over the ceiling of 262144 -- instead, read part of it with
read_file's offset and limit, or outline it with code_outline, file_symbols or ast_search,
or grep it for the lines you actually need
```

`offset`/`limit` count lines, and the file has one, so that advice cannot narrow anything.
`failure-injection.md` §8 expects the distinctive `one line alone is over the ceiling`
fragment here.

**It is milder than the scenario fears, and the difference matters.** Following the advice
produces the *correct* refusal on the second attempt:

```
the first 1048577 bytes of line 1 of one.json is 1048577 bytes, over the ceiling of
1048576 -- instead, take a byte range with bash (`head -c 100000 PATH`, …) -- one line
alone is over the ceiling, …
```

So this is **not** the infinite loop §8 exists to prevent — it costs exactly one wasted
round trip. The cause is a deliberate design choice: the whole-file refusal comes from
`self.too_large`, which decides from `File.size` **before opening** (§8's "the decision
precedes the read" check, which passes), and therefore cannot know the file's line
structure. `LONG_LINE_NARROWER` is reachable only from the windowed path.

**Bound of the defect, established while planning the fix:** it applies only to newline-free files
**larger than `WINDOW_BOUND` (1 MiB)**, which is what `one.json` (1 200 003 bytes) is. `LongLine` is
built against `WINDOW_BOUND.limit` (`read_file.rb:422`) and fires only above it, so a newline-free
file between 256 KiB and 1 MiB is genuinely served by the full-cover window it is offered — there the
current advice is correct. Any fix must not widen into that range.

### UX8 — LOW — retry backoff printed to 17 significant figures

```
[retry] attempt 1, retrying in 0.14368744774438316s -- Faraday::ConnectionFailed
```

`session-and-window.md` §2 writes the expected shape as `retrying in Xs`.

---

## Defects in the QA method itself

These voided or nearly voided probes in this round and belong in `method.md`.

**P1 — `drive.sh` picks the wrong journal, and then asserts nothing.** It selects
`ls -t …/*.ndjson | head -1`. Every scenario that runs a non-interactive probe
(session-and-window §1/§2/§6, failure-injection §5) creates journals *newer* than the
cockpit's, so from that point on `drive.sh` polls a file that will never move: it returns
after one quiet window having waited for nothing, and the driver then measures the cockpit
**before the render lands**. This produced a false "`lain://timeline` frozen at 4 lines"
reading — indistinguishable from round 4's F17 — which evaporated on re-measurement.
Fix used this round: `drive2.sh`, pinning `$LAIN_QA_JOURNAL`.

**P2 — the quiet window must exceed a model reload.** `OLLAMA_KEEP_ALIVE=5m` plus any pause
evicts the model; the reload is 27–40s of total journal silence (measured 29.6s cold). A
quiet window at or below that reads a reload as "done" and returns mid-turn. Twice this
round a "wedged session" was nothing but a reload plus an in-flight request 4–15s old. Use
≥60s, and before calling anything wedged check `request_sent` age against `date` and
`/api/ps` for a reloading runner.

**P3 — §11's multi-line control is stale.** It says "a missing key prints several" lines; in
this build that refusal is exactly one line. The section needs a genuinely multi-line
refusal named explicitly (Thor's unknown-flag error works).

**P4 — §4's 220×50 protection does not exist.** See **F25**: `lain up` gives nvim 110
columns, and the review tab's windows are 32–40. The sizing protects nothing about
`nvim_echo` paging.

---

## Model findings — all previously documented, all reproduced

- **M1 — clarifying-question loops.** Cost the entire `bowling-ruby` §1 act. Given an
  explicit *"Do NOT ask any clarifying questions"*, it asked one; answered, it spawned a
  `researcher` that asked another; answered again, a third. Two consecutive turns produced
  no file. Only a maximally directive *"Stop asking and act: use write_file …"* produced
  `lib/bowling.rb`.
- **M2 — literal tool-call syntax as prose.** Reproduced: `<parameter=path>`, `</function>`
  and `</tool_call>` appeared as pane text during `failure-injection` §9, immediately after a
  compaction. Session restarted per `method.md`; the fresh session was clean.
- **M3 — `run_skill` flailing.** After finishing the rust task it invoked lain's own skills
  (`execute-plan`, `gherkin-tests`, `critique`, `iterate-epic`, `plan-epic`), whose large
  documents became the tool results that the two expensive summarizer calls were spent on.
  **Not a sandbox escape** — every `bash` command stayed inside `$QA/rust`.

---

## Scenario results

### `session-and-window.md` — COMPLETE, all 8 sections pass
Detailed above and in `$QA/records/progress.md`. Highlights: 9 launch refusals exact with
zero backtrace frames; `--num-ctx 262144` accepted at the trained maximum; cold→warm
re-resolution `8192/guessed` → `32768/probed`; three readers agree exactly
(`occupancy 0.147247314453125` == 4825/32768, HUD `ctx 15%`); `capability_degraded` exactly
once; options asymmetry correct in both directions; all four `--compact-strategy` refusals
exact including the part-vs-whole wording; price table 5/25, 3/15, 1/5 with cache_creation
exactly 1.25× and cache_read exactly 0.1× on every row, read both from the checkout and live
through `/ruby`.

**One withdrawn probe.** The freshness lint appeared to pass with a deleted marker; the
probe was wrong (it `gsub`'d `reviewed-on`, but the marker is `Reviewed <date>`). Deleting
the real marker fails correctly with `no "Reviewed YYYY-MM-DD" marker found near the price
table`. Recorded because §8 explicitly asks for this check.

### `rust-cli.md` — COMPLETE, passes
Build green, `cargo test` 3 passed, behavioural oracle exact (`the 3` / `cat 1`). Both
unhappy paths driven: the model's own E0282, and the driver's injected E0580 — full rustc
diagnostics survived as tool results with multi-line spans and no ANSI corruption, and the
model recovered from both. Streamed output reached `lain://journal` and correctly **replaced**
the placeholder. Seven gated calls, seven prompts. No `StalledStreamError` on a cold cargo
build; the HUD elided `idle` mid-dispatch rather than lying.

**The first compaction any QA round has recorded** fired here — see UX5.

### `cockpit-surfaces.md` — COMPLETE except one clause
§1 six of seven views primed (UX4). §2 staleness passes (timeline 8→10, request 629→647,
diff 38→36). §3 attach message supersedes in the right order. §4 review flow passes on every
gesture: banner exact; `x` on an unopened row refuses by name and leaves it unmarked; `<CR>`
opens three windows with focus in NEW; `x` marks **and** acknowledges
(`lain: unit-content-v1:f40a099543c0… is now reviewed`); `x` on a no-hunk row refuses
cleanly; partial verdict refuses naming the file and the remedy; full verdict acknowledges
**and** journals `review_verdict` with `changeset_digest:
survey-corpus-v1:b6cde4d3…`. No traceback anywhere (F25 covers the modal). §5 passes on both
paths (F24 covers the notifier). §6 passes on the real newline trigger. §7 passes in all
three states: `<model> ctx N% idle Ns` at `you>`, **`idle` absent entirely** at a parked
`human>` (`qwen3-coder:30b ctx 27% fleet 1`), and `idle` **returning** afterwards.

**Not driven:** the stale-`lain_view_generation` step (§4 says drive it over RPC or drop it;
dropped, not recorded as a pass), and the invalid-UTF-8 prime clause in §6 — reminders are
journal-sourced and NDJSON cannot carry invalid UTF-8, so it is not reachable from outside
the library. It needs a library-level probe.

### `bench-arms.md` — COMPLETE, passes
All four header lines correct, including `isolation: unset — Arm::NoIsolation leased
nothing` and no credential or base URL anywhere. All three conjoined checks pass — means
0.812/0.812/0.938 against the 0.0625 vacuous floor, and non-zero token rows for every arm
(228.5/446.5/3158.4), so no collapsed arm is faking a grade. The cost column degrades exactly
as designed: `not priced — no price for model "qwen3-coder:30b"; configure a fallback to
degrade`, with the rest of the report intact and the whole SECTION refused rather than one
row. No `StalledStreamError`. Grades identical to round 4.

**Reproduced outlier:** `single-thread` wall-time max **28.68s** against a **1.42s** median —
20×. Round 4 saw 29.6s against 1.39s. Two rounds, same shape, still unexplained.
**Not verified:** that the dual-ledger arm settles on its ledger rather than its grader; the
summary report does not expose the terminal state.

### `failure-injection.md` — §§1–3, 7–11 complete; §§4–6 partial
§1: 398 lines, 0 unparseable, 0 `journal_error`, and **41 compaction decisions reconcile
against 41 `turn_usage` records with zero mismatches**. (Grounding correction: `used_tokens` is
`Usage#total_input_tokens` — the three-way sum of `input_tokens` + `cache_creation_input_tokens` +
`cache_read_input_tokens`, per `lib/lain/usage.rb:46-48` — not bare `input_tokens`. Against a local
model both cache fields are 0, so the round-5 reconciliation is unaffected; the distinction matters
on a real Anthropic session and the check should be written against the sum.) §2 and §3 pass exactly,
from both entry points, with index, role and both digests. §7 confirmed in all three parts.
§8 passes in both shapes — live ceilings `[262144, 1048576, 131072, 500]` read through
`/ruby`; the refusing shape's load-bearing distinction is correct (only `mid.rb` is offered a
full-cover window); the disclosing shape gives 500 rows + `... capped at 500 of 1200 paths`,
no trailer on a small directory, and byte-identical output across two runs, while
`grep`/`ast_search` correctly keep the older `capped at N matches` wording. §9 passes as a
sequence including the deadlock guard: `[false, true]` after a window, the exact
window-naming `edit_file` refusal (not the loop-generating "never read this session"),
`[true, false]` after a full-cover window, and `edit_file` then **permitted** past the
read-set guard — refused only on a distinct uniqueness precondition. §10's two gates read
`[4096, 262144]`, independent and not collapsed. §11 passes with UX6 as its residual.

**Partial:** §4 (severing proxy) and §6 (Ctrl-C at a parked `ask_human`) were not driven.
§5's unreachable-endpoint half was driven via `session-and-window` §2, including the counting
listener; the scheme-less-typo half passes at construction.

### `bowling-ruby.md` — lain seams complete; the model half failed as predicted
**5/5 oracles pass**, including the load-bearing oracle 4 (`133`) and the tenth-frame case
(`30`, not 60) — better than round 4's 4/5. §1 failed on the model (M1). §2's wedge grammar
works on lain's side: `@researcher[/critique] lib/bowling.rb` spawned a fresh context,
`fleet 2` appeared, the arrival note **named the requester**, a `human>` prompt was taken and
the answer consumed; `child_turn` 20→29 and `message` 6→10. Every `causal_parents` digest
resolves (0 unresolved of 7 unique) — the gap round 4 had, since its journals held none.
**Then the fork that is supposed to prove it refused — F23.**

§3's second half is answered plainly: **the model wrote no specs at all**, so the
"meaningful or vacuous?" question resolves to neither. The scorer is correct but verbose —
nested conditionals, a hand-rolled frame cursor, and an `ArgumentError` guard that duplicates
what the oracles already cover.

### `rails-blog.md` — NOT REACHED
No act of it was driven. Everything it uniquely covers therefore remains uncovered:
compaction at scale under `--compact-strategy elide-tools+summarize-conversation` and its
§0 precondition, unbounded tool-result volume, the gate under volume, `lain friction`'s
`cache_waste` analyzer, and the deliberate `elide+summarizing` `Overlap` raise. The
incidental compaction recorded in UX5 does **not** discharge §1: it was triggered by
`plan_step_completion` rather than occupancy, under the default strategy, on tool results far
too small to exercise the elide half's ~2 KB shrink threshold.

---

## What the round taught the method

Folded into `planning/qa/method.md` and the two scenarios (P1–P4 above): pin the journal
rather than taking the newest; size the quiet window above a model reload and check
`request_sent` age before calling anything wedged; §11 needs a real multi-line control; and
§4's 220×50 claim must be replaced with the measured 110/40/32/36.
