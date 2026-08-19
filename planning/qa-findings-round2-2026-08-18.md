# Manual QA round 2 — 2026-08-18

Sandbox: `~/tmp/lain-qa-2026-08-18`. tmux server `-L lain-qa`, 220x50. ollama 0.32.12
from `/mnt/nvme/opt/ollama-env.sh`, model `qwen3-coder:30b`. Machine load 1.21 at Act 0
(the 99%-CPU process is the known `mempalace mine`, not an orphan spinner).

## Act 1 — cold start and the window denominator

### Regressions from round 1: all fixed

| check | result |
|---|---|
| `--num-ctx 0` / `-5` | refuses by name (`--num-ctx must be positive, got 0`), exit 1, no backtrace |
| cold, no flag | `window=8192 provenance="guessed" signals=[]` — F3's fix in force |
| cold + `--num-ctx 32768` | honest 32768, no server involved; HUD `ctx 13%` |
| warm (resident) | `window=262144 provenance="probed"`; HUD 2%, `state.json` 0.016551, journal 262144 — **all three readers agree** |
| `capability_degraded` | exactly one journal line, nothing on screen (documented, follow-up #7) |
| T11 wire | `--num-batch 2048 --num-ctx 32768` → `extra={"num_batch"=>2048,"num_ctx"=>32768}`; neither set → `extra={}`, no `options` key |

### F8 (NEW, medium) — an operator's `--num-ctx` is tagged `probed` and can over-claim the window

`WindowBook#served` is `[num_ctx, provider.context_window_tokens(model)].compact.min`
(`lib/lain/cli/backend/window_book.rb:176`). With nothing resident the provider answers
nil, `.compact` drops it, and the operator's `--num-ctx` becomes the whole book — tagged
`ContextWindow::PROBED`, whose own docstring says it means "the server said so, about the
runner resident right now" (`context_window.rb:133`). No server was asked.

**Reproduction** (nothing resident):

    lain chat --provider ollama --model qwen3-coder:30b --num-ctx 999999

- ollama serves `n_ctx_slot = 262144` (clamped to trained length)
- lain journals `window=999999 provenance="probed"`; `state.json` occupancy 0.004339
- HUD reads `ctx 0%` on a turn that is really 1.7% of the served window — **3.8x under-report**

This is F3's mirror image and the direction `window_book.rb:161-169` itself ranks as worse:
an over-estimated window means `Compaction::Need::ApproachingWindow` never fires at all.
The book is memoized at launch, so it never self-corrects once the runner is resident.

`--num-ctx 262144` (at trained length) is honest — ollama does honour a per-request `num_ctx`
above `OLLAMA_CONTEXT_LENGTH`, up to trained. So the defect is only above trained length,
which is exactly where an operator has no way to know the ceiling.

Suggested fix: an unverified operator value is not a measurement. Either give it its own
provenance below `PROBED`, or re-probe once the runner is resident and adopt the smaller.

### F9 (NEW, medium) — the HUD reads `idle` for the whole prefill, and the plan's retry advice then duplicates turns

The status line shows `qwen3-coder:30b idle 0s` for the entire prompt-evaluation phase, while
`ollama-serve.log` shows the slot actively prefilling. The plan's driving rule — *"send, capture,
and retry until the status leaves `idle`"* (`qa-manual-end-to-end.md`) — is therefore actively
harmful: it reads a busy turn as an unsubmitted one.

**Measured:** one intended prompt in `act1a`, driven by that rule (1 Enter + 3 retries), produced
**4 `turn` records, 4 `request_sent`, 4 `compaction_decision`** in the session journal. Every
later act in this run sent exactly one Enter and got exactly one turn.

So the round-1 note "one Enter is not reliably one submit" is most likely this same defect read
from the other side. **The plan's rule must be replaced**: poll the *journal* or the model server
for turn start, never the status line.

## Act 2 — `/create-plan`, subagents, and a session-killing crash

### F2's fix confirmed

The researcher subagent called `web_search` and got:

    web_search: no search backend is configured for "bowling game implementation in ruby";
    searching is unavailable this session -- use another source instead of re...

That is exactly what commit 6c3fffec was for. Round 1's "indistinguishable from a real backend
returning []" is gone.

### Approval gate, spawn confinement, `/inbox` — all correct

- The researcher spawn's toolset is `only: ["read_file","list_files","web_fetch","web_search"]`.
  A `bash` call arrived at the approval surface from the PARENT, not the child — confinement holds.
- `/inbox` renders a parked `ask_human` correctly while the prompt sits at `human>`, and answering
  it resumes the child.
- Answering `y` (not "always") wrote **no** `.lain/config.toml`. Approval persistence stays opt-in.

### F10 (NEW, HIGH) — a stalled-stream timeout kills the whole chat session, and a subagent is enough to trigger it

**This is a regression introduced by this round's own T12 fix** (commit cc9161a9).

During `/create-plan`, with a researcher subagent live (`fleet 2`), the chat died:

    Lain::Provider::HTTP::Streaming::StalledStreamError: stalled stream: no bytes for 30.2s,
    past the 30s stream_stall_timeout, with the connection still open
      from lib/lain/cli/repl.rb:90:in 'Lain::CLI::Repl#run'
      ...
    Pane is dead (status 1)

**The server was healthy.** `ollama-serve.log` for the same window:

    04:35:07  [GIN] 200 | 15.7s   POST /api/chat        <- previous request finishes
    04:35:34  llama-server started in 26.86 seconds     <- reload #1
    04:35:46  [GIN] 200 | 55.2s   POST /api/chat        <- the OTHER actor's request
    04:36:14  llama-server started in 27.12 seconds     <- reload #2
    04:36:17  [GIN] 500 | 1m9s    POST /api/chat        <- lain aborts; srv stop: cancel task

The crashed request began at 04:35:08 and lived 69s. It spent that time **waiting for the slot**:
`OLLAMA_NUM_PARALLEL:1`, `n_slots = 1`. The parent and the researcher subagent both stream from
one slot, so one waits — silently, past the 30s grace, while ollama additionally tears down and
reloads the runner twice.

**Two separable defects:**

1. **The grace does not account for lain's own concurrency.** The chunk spec's Open Decisions
   argued 30s on the premise that *"once tokens are flowing, a 30s gap from a token-streaming
   server means the stream is dead"*. On a single-slot local server that premise fails whenever
   lain spawns a subagent — the second stream's silence is queue wait, not death. The spec said
   *"T12 escalates only if measurement contradicts this."* This is that measurement.

2. **`StalledStreamError` is unhandled and takes the process down.** It propagates from
   `Repl#run` straight out through `Thor` to `<main>`, printing a raw backtrace and exiting 1.
   The operator loses the session, not just the turn. Act 8 expects a *clean refusal* for a dead
   endpoint; this is the opposite, and it is worse than the >400s hang F7a replaced, because a
   hang is recoverable with Ctrl-C and this is not.

**Verified NOT the cause** (so a fix does not go here): the stall clock is correctly *not* armed
during prompt evaluation. A deliberate 27s runner reload under `LAIN_STREAM_STALL_TIMEOUT=5`
completed normally — `StallClock#receiving` starts the monitor on the first chunk, as documented.

**Margins are thin even when it works.** Successful single-actor runs with a reload measured
**31.07s** and **33.33s** total request time. Normal operation sits right at the threshold.

**Reproduction:** run `/create-plan` (or anything spawning a subagent) against ollama with
`OLLAMA_NUM_PARALLEL=1`. It crashed on the first attempt here. Journal integrity survives — 96
records, 0 unparseable, `session_closed` written — so this is loud at the terminal and clean on disk.

### F11 (NEW, low/medium) — `list_files` on an empty directory returns `""`, and the model reads it as failure

`ListFiles#perform` ends `Tool::Result.ok(entries(path, input.recursive).join("\n"))`
(`lib/lain/tools/list_files.rb:47`), so an empty directory is `ok("")`.

This is the same shape F2 was just fixed for — an empty success indistinguishable from a failure —
in the neighbour that did not get the fix. The cost is in the journal: given empty `lib/` and
`spec/`, the researcher made **four** `list_files` calls, one bogus
`web_fetch("http://localhost:3000/lib")`, and then escalated to the human with *"I'm having
difficulty accessing the file structure."* Its own tool description promises an error only for
missing/unreadable paths, so the model has no way to read `""` as "this directory is empty".

`list_files({"path":""})` does refuse properly:
`Lain::Tool::InvalidInput: invalid input for list_files: Path can't be blank`.

### F12 (NEW, low) — the approval prompt does not name the requesting actor

The surface renders `approve bash({...})? [y/N]` and journals
`approval_pending {"requester":"agent", ...}`. With `fleet 2` on the status line and a subagent
that has just been asking questions, the operator cannot tell parent from child. The plan's own
standing rule is that the gate is only worth having if it is read; who is asking is part of what
is being judged.

## Act 4 — the review surface (`/survey ./lib`)

### F4 fixed, end to end

The survey banner now reads:

    surveying .../project/lib at cumulative scope: 2 files
    walk it in lain://review; <CR> opens a row, :LainNote annotates,
    :LainReviewVerdict approve hands it back

Round 1's banner named `:LainReviewDone`, whose guard could never pass for a survey. The named
command now works: `:LainReviewVerdict approve` journals
`review_verdict {"verdict":"approve","changeset_digest":"survey-corpus-v1:86cb8473..."}`.
`65_review.lua:117` additionally gives `:LainReviewDone` a refusal that points at the right command.

### F5 fixed

The mark acknowledgement is one short line: `lain: unit-content-v1:4ef3df7bd3c8... is now reviewed`.

### Round-1 gesture fixes confirmed

- **Row redraw after a gesture** (d34c72bb): `[ ] lib/bowling.rb` became `[x] lib/bowling.rb`
  immediately on `x`, for both rows.
- **Read registration** (1637c3b6): marking a row nothing has opened is refused, by name and with
  the remedy — `lain://review line 2 names lib/scorecard.rb, which nothing has read -- open it
  with <CR> first`.

### F13 (NEW, medium) — the hand-back is silent

`:LainReviewVerdict approve` prints **nothing** in nvim and **nothing** in the chat pane. The
verdict is journaled correctly, but the human has no way to tell it landed without reading the
NDJSON. Every lesser gesture in this surface acknowledges itself (`... is now reviewed`); the one
terminal gesture does not.

This matters because it is F4's successor risk. F4 was "the banner named a command that cannot
work". An operator who types the now-correct command and sees no response reads that the same way
— as failure — and the plan's Act 4 has no step that would distinguish them.

### Minor observations

- A double-press on one row journals **two identical `hunk_marked` records** (same `hunk_key`,
  same `state`). Idempotent in effect, duplicated in the record.
- F5's shortened message names a **digest prefix**, not a path. What a human can act on is the
  path, and it is the row redraw — not the message — that supplies it. The commit's stated intent
  ("shorten to what a human can act on") is only half met.
- The plan's step "press `x` inside the redraw window and confirm the stale-stamp refusal
  self-corrects" **could not be provoked by hand** — back-to-back presses both landed. The redraw
  is now prompt enough that this step needs to be driven through the RPC with a stale generation
  number, or dropped.

## Act 8 — destructive probes

### F6 fixed

Tearing an actual `turn` record in half (line 91 of a 96-line journal) now shows at rest:

    20260818T082823-1604957.ndjson  2026-08-18T08:28:23  12 turns  closed  blake3:c04637b6cb11  1 line unparsed

Round 1 reported the same 12-turns-under-the-same-head with **nothing** saying why. The
`1 line unparsed` suffix is the fix (commit d8078ad4), and it preserves `Journal.records`'
skip-unparseable contract while making the loss legible.

Forking the damaged session at its advertised head refuses precisely:

    cannot fork 20260818T082823-1604957.ndjson: turn record 6 (user) cites a causal parent this
    fold never landed: no object "blake3:00a3bce7..." in store: putting "blake3:d519c081..."
    would dangle

Session named, record index and role named, both digests named, exit 1, no backtrace. Both halves
of "invisible at rest but unforgeable on use" now hold — and the first half is no longer invisible.

### Follow-up #1 is fixed further than documented

The plan says to expect a **raw `Store::MissingObject`** from `--resume`, because follow-up #1 was
fixed "for `--fork` only". It is not raw any more:

    cannot resume 20260818T082823-1604957.ndjson: turn record 6 (user) cites a causal parent ...

Same precise refusal, exit 1, no backtrace. **The plan's expectation is stale in the good
direction** and should be updated, or the next round will file a passing case as a surprise.

### F14 (NEW, HIGH) — a scheme-less `--api-base` crashes with a third-party backtrace

The plan names this as "the mistake a human actually makes". It is not handled:

    lain chat --provider ollama --api-base 'localhost:11434' --prompt 'hello'

    faraday-2.14.3/lib/faraday/connection.rb:481:in 'Faraday::Connection#build_exclusive_url':
    undefined method 'end_with?' for nil (NoMethodError)
          if url && !base.path.end_with?('/')

The chat dies on the first turn with a Faraday backtrace and no mention of `--api-base`.

The cause is a gap in an assumption `window_book.rb:143-147` writes down explicitly — that
*"`--api-base "not a url"` raises `URI::InvalidURIError` ... so it escapes before any probe is
sent."* `localhost:11434` **is** a valid URI (scheme `localhost`, opaque `11434`), so it passes
construction and only fails once Faraday asks for a path that is nil. The check needs to be
"http/https scheme, and a host", not "URI.parse succeeds".

### F15 (NEW, HIGH) — an unroutable `--api-base` hangs indefinitely with a blank screen

    lain chat --provider ollama --api-base http://10.255.255.1:11434 --prompt 'hello'

**Still running with a completely blank screen after 10 minutes.** The plan expects "the ~2 s probe
timeout, then a clean refusal". Instead: `request_timeout` is 300 s and `max_retries` is 3
(`provider/http/configuration.rb:72,95`) with `:post` retryable, so the ceiling is ~20 minutes of
silence.

**This is F7a reproducing in the connect case.** T12's stall timeout only arms once bytes flow
(`StallClock#receiving` starts the monitor on the first chunk), so a connection that never
completes is not covered by it at all. The measured symptom is identical to the one F7a
described — ">400 s with zero output" — and the fix did not reach it.

Note the launch-time probe *does* fall back cleanly in ~4 s; it is only the turn that hangs.

## Act 3 — the wedge (`@researcher[/critique] <path>`)

**The wedge works.** Typed literally as `@researcher[/critique] ./lib/bowling.rb`, it produced the
full documented shape:

- a fresh-context spawn (`fleet 1` on the status line)
- the arrival note: `? researcher Can you provide the official rules ... (/inbox here, or the
  inbox buffer in nvim)`
- the `human>` prompt
- answers taken, twice, each resuming the child
- a return to `you>`

Round 1's worst defect lived here. It does not reproduce.

**Causal lineage is intact.** The session journal carries 14 `child_turn` records and 6 `message`
records; of 8 `causal_parents` references, **0 are unresolved**.

### F16 (NEW, low) — a wedge-only session has no forkable head

The plan's Act 3 ends "then **fork the session**, which is what proves it." That step is
unreachable as written. A session whose only activity was a wedge spawn journals **no `turn`
records at all** — only `child_turn` — so:

    20260818T090440-1636386.ndjson  2026-08-18T09:04:40  0 turns  closed  -

`lain sessions` shows no head digest, and forking at a `child_turn` digest refuses:

    no turn matching "cda862750c22" recorded in 20260818T090440-1636386.ndjson   (exit 1)

The refusal is clean and honest, so this is a coverage gap rather than a fault: the child's
lineage can only be verified by reading the NDJSON, which is the one thing the fork step existed
to avoid. Either take an ordinary turn before the wedge (a plan fix), or let a fork resolve a
child digest (a lain change).

## Act 5 — the bench: refusals verified, arms run attempted

Both documented refusals are present and well-worded:

- `LAIN_PROVIDER=ollama lain bench arms <fixture>` still refuses with
  `ANTHROPIC_API_KEY is not set; --provider anthropic needs it to build a client` — confirming
  `--provider`'s literal `"anthropic"` default does **not** read `EnvDefaults`. Still true,
  still a trap worth keeping in the plan.
- `--journal` without `--isolation` refuses with the remedy named:
  `--journal records the isolation leases a run takes, and nothing leases without --isolation:
  drop --journal, or add --isolation none|worktree`

### The arms run completed — all three conjoined checks pass

`lain bench arms spec/fixtures/arms/tasks.yml --provider ollama --model qwen3-coder:30b`,
3 arms x 8 tasks, 157 live `/api/chat` requests, all 200:

| arm | grade mean | median | total tokens mean | wall mean | wall median |
|---|---|---|---|---|---|
| single-thread | 0.812 | 1.000 | 235.4 | 5.074 | 1.405 |
| orchestrator-worker | 0.812 | 1.000 | 442.6 | 1.636 | 1.485 |
| dual-ledger | **0.938** | 1.000 | **3487.9** | 14.725 | 14.430 |

1. **Mean grade materially above the 0.0625 floor** — 0.812/0.812/0.938. ✓
2. **Non-zero beyond `fix-off-by-one-loop`** — medians of 1.000 across 8 tasks. ✓
3. **Non-zero spend row for every arm** — 235.4 / 442.6 / 3487.9. ✓

**Follow-up #15 does not reproduce**: no arm shows a 1.000 grade beside a collapsed spend row.

Two readings worth keeping:
- **single-thread's mean wall-time is an artefact.** 5.07s mean against a 1.40s median — one
  29.84s outlier carries it. The two cheap arms are indistinguishable by median (1.405 vs 1.485).
- **dual-ledger buys +0.126 grade for 8-15x the tokens** and 10x the wall-time. That is the
  cost/benefit the plan says nothing currently records.

**F10 did not fire during the bench.** The orchestrator arm's requests are short (1-3 s each), so
no stream ever goes 30 s silent. That is consistent with F10's mechanism, not evidence against it.

## Act 7 — NOT COVERED, and the reason is a finding

The plan's Act 7 grades **the model's** scorer and **the model's** specs. Neither exists: Act 2
looped through three `ask_human` round trips without writing a file and then died to F10, and
Act 3's wedge produced a bowling encyclopedia article rather than a critique. `lib/bowling.rb` and
`lib/scorecard.rb` were seeded **by the driver** so Act 4 had something to survey.

So Act 7's question — "the plumbing can work perfectly and still produce something not worth
having" — is unanswered this round. What was verified instead is the **instrument**: a driver-owned
five-oracle spec (`records/oracles_spec.rb`, reusable) passes 5/5 against the seeded scorer,
including the two oracles the plan warns are load-bearing (the open-frame case and the tenth-frame
case).

## Act 6 — record integrity

Checked incidentally throughout, and it holds:

- Every journal in the run parses. The Act 2 session **survived its own crash**: 96 records,
  0 unparseable, `session_closed` written.
- No `journal_error` records anywhere.
- Occupancy reconciles across all three readers in every Act 1 case (HUD `ctx N%`,
  `state.json` `occupancy`, journal `window_tokens`).
- Compaction decisions carry their denominator **and now their provenance** (T9).
- Causal integrity: the wedge session's 8 `causal_parents` references all resolve.
