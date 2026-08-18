# QA round 4 — 2026-08-18

## Summary

**Every round-3 defect re-checked behaves differently, and all of them better.** F8, F11,
F12, F13, F14, F15 and the T4/T6/T11 contracts are confirmed fixed with evidence below.
Two round-3 fixes were verified in the exact scenario that generated them (F9 at a parked
`ask_human`, and again on a torn turn).

**Seven new findings, two of them session-killers.**

| id | sev | what |
|---|---|---|
| **F18** | **HIGH** | a second approval in one turn never renders AND is never read; on `--no-nvim` the session is permanently wedged |
| **F21** | **HIGH** | the 25-iteration ceiling is per-SESSION, not per-ask, so every chat dies silently after 25 model calls |
| F17 | MED-HIGH | `lain://timeline` freezes after the first ask and never updates again |
| F22 | MED | `:LainReviewVerdict` refusal arrives as a Lua error + traceback + blocking modal |
| F20 | MED | the budget refusal arrives as an Async "unhandled exception" + 27-frame backtrace |
| F16 | LOW | the give-up retry line under-reports the attempt count by one (4 attempts rendered as "attempt 3") |
| F19 | LOW | `inbox_count` disagrees with the inbox buffer (unconfirmed) |

Plus three UX findings (UX1-3), one QA-doc defect (QA-DOC-1), and a cleanly reproduced
model failure mode (MODEL-1).

**The through-line in F18/F20/F22: lain's refusals are well-written and then delivered as
crashes.** The text names the condition, the file, and the remedy; the delivery is a
traceback, a modal, or nothing at all. That is one card, not three.

Acts 5, 6 and 8 pass outright. Act 7 graded the model's scorer at **4/5 oracles** -- the
plumbing worked and the artifact is wrong, which is the separation Act 7 exists to make.

**Still not reached: compaction at scale.** Round 3 missed it to F10; round 4 missed it to
F21's session ceiling. It remains the least-exercised path in the plan.

---

Bench: ollama 0.32.12 (/mnt/nvme), qwen3-coder:30b, OLLAMA_CONTEXT_LENGTH=32768,
KEEP_ALIVE=5m, LAIN_NUM_BATCH=2048, **n_slots=1 / OLLAMA_NUM_PARALLEL=1** (F10 precondition live).
Machine quiet at Act 0: load 0.36, no orphan spinners.
Sandbox: ~/tmp/lain-qa-2026-08-18-r4, XDG redirected, tmux -L lain-qa4, shim on PATH.

## Round-3 defects re-checked

| id | verdict | evidence |
|---|---|---|
| F8 `--num-ctx` over trained max | FIXED | `--num-ctx 999999` refuses at construction naming flag/value/max 262144, exit 1, nothing resident (so /api/show supplied it). `0` and `-5` refuse "must be positive". |
| F14 scheme-less `--api-base` | FIXED | all five shapes refuse by name, exit 1, no backtrace: `localhost:11434`, `http://`, `http:///x`, `not a uri at all`, `""`. |
| F15 connect hang | FIXED | blackhole 10.255.255.1: 26s (was >10min, ceiling ~20min). `LAIN_CONNECT_TIMEOUT=1` -> 8s, so the knob is live. |
| T4 retries rendered live | FIXED | `[retry] attempt N, retrying in Xs -- Faraday::ConnectionFailed` appears on screen, not journal-only. |

## New findings

### F16 — the give-up retry line under-reports the attempt count by one (LOW)

`Provider::{Ollama,Anthropic}::RetryTap#exhausted_block` pushes `attempt: options.max`,
but `options.max` is the number of RETRIES, not the ordinal of the attempt that just failed.

Rendered: `attempt 1, retrying / attempt 2, retrying / attempt 3, retrying / attempt 3, giving up`.
Measured: a counting TCP listener saw 6 connections = 2 launch probes + 4 turn attempts.
So the 4th and final attempt is never named, "attempt 3" appears twice, and an operator
reading the screen concludes 3 attempts were made when 4 were.

Repro: counting listener on 21434 (accept, SO_LINGER 0, close, count), then
`lain chat --provider ollama --api-base http://127.0.0.1:21434 --prompt 'say hi' </dev/null`.

Fix shape: `attempt: options.max + 1` in both taps, or carry the real attempt ordinal.
A spec asserting the exhausted line names a HIGHER number than the last retrying line pins it.

### F17 — `lain://timeline` freezes after the first model call (MEDIUM-HIGH)

The cockpit's timeline view renders once and never again. It sat at **2 lines**
(`user: List the files... / assistant: (tool_use)`) for an entire 12-turn session.

`TimelineView#update` fires on `Telemetry::TurnUsage` and renders
`Timeline.new(head_digest: event.digest, store: @store).to_a`. The journal shows **12
`turn_usage` records with 12 distinct, advancing digests**, so the events are produced;
only the first one's chain is ever on screen.

Not the drain thread dying: `lain://request` and `lain://diff` update live off
`Telemetry::RequestSent` on the SAME `Surfaces#post` path. Sampled at 1s across a turn,
`request` moved 762 -> 780 -> 798 while `timeline` stayed at 2.

Not a store miss either: a miss renders `[timeline unavailable: <digest> not in store]`
(1 line), and we see real content.

**Reproduced in two independent sessions**, and the freeze point varies:

| session | asks driven | assistant turns / `turn_usage` | timeline lines | shows |
|---|---|---|---|---|
| 1 | 9 | 25 | 2 | first ask, mid-tool-use |
| 2 | 5 | 7 | 4 | first ask, complete |

So it renders during the FIRST ask and then never updates again, whatever state it
happened to reach. Every later ask is absent.

Repro: any cockpit session, two or more asks, then
`nvim --server <sock> --remote-expr "getbufinfo('lain://timeline')[0].linecount"`.

Mechanism not determined -- the events are produced and the drain thread is demonstrably
alive, so the fix card should start by instrumenting `Surfaces#post` to log which event
classes actually arrive.

Impact: the timeline is the cockpit's view of the Merkle DAG and the surface the `p` pin
and `]]`/`[[` record-boundary gestures resolve through, so those gestures address a stale
chain. Act 4's review flow and any forking gesture read from here.

## UX findings (not defects, but obtuse)

### UX1 — nvim keeps saying "not attached yet" after it has attached

The nvim pane's message line reads
`lain: not attached yet -- layout opens when 'lain chat --nvim' attaches`
for the whole session, while `lain://request` is visibly live in the split beside it.
The message is never cleared once attach succeeds, so the one line of prose on screen
contradicts the buffers next to it. A reader's first conclusion is "the cockpit is broken".

### UX2 — `lain://journal` is the one view with no placeholder, so "empty" reads as "broken"

`Surfaces#prime`'s own docstring gives the principle: prime every view so
"an idle session that shows no buffers reads as 'broken' (the first manual verification
pass stumbled exactly there)". Every sibling honours it -- `(no reminders)`,
`(no questions pending)`, `(no approvals pending)`, `(no requests yet)`. `JournalView#initial`
alone returns `[""]`.

Compounding it, the buffer is named `lain://journal` but renders ONLY
`Telemetry::ToolOutput` (streamed tool bytes) -- not the session journal, which is a rich
NDJSON file on disk. A 12-turn session with tool calls left it completely empty, because
none of the tools used streamed output.

Suggested: prime it to `(no streamed tool output yet)`, and consider naming it
`lain://tool-output` -- "journal" already means the NDJSON record everywhere else in the
system, and this is not it.

### F18 — a second approval in the same turn never renders in the CHAT pane (HIGH)

The first gated call of a turn renders normally:
`agent asks: approve bash({"command" => "... && git status"})? [y/N]`

The next one, arriving after the first tool's streamed output was written to the pane,
renders **nothing at all**. The chat pane's last line stays the previous tool's stdout
while the run is parked waiting for y/N. Measured: 90+ seconds parked with no prompt.

It is genuinely pending, not lost -- three other surfaces agree:

* journal: `approval_pending requester="agent" tool="bash" tool_use_id="call_z5rr10k9"`
* `.lain/state.json`: `approvals_pending=1`
* `lain://approval` in nvim: renders the full command plus
  `-- y approve, n deny  (:LainApprove / :LainDeny)`

So the chat pane is the ONE surface that drops it, and it is the surface the operator is
looking at. The failure mode is nasty in both directions: wait forever, or type `y` at a
prompt whose command you cannot read. This QA run only recovered the command by reading
`lain://approval` over nvim RPC.

Severity is raised by `lain up --no-nvim` and plain `lain chat` being supported paths --
there the chat pane is the ONLY approval surface, and this would be unrecoverable.

**It is not merely unrendered -- the chat pane never READS for it.** Typing `y` + Enter
did nothing: journal flat at 183 lines for 60s, the `y` merely echoed by the terminal on
its own line, and the process sat in `io_cqring_wait`. So the run is wedged from the chat
side, not just quiet.

**Only the nvim gesture can recover it.** `:LainApprove` over RPC resolved it immediately:
journal 183 -> 189, `approvals_pending` 1 -> 0, and the tool ran
(`[call_z5rr10k9 stdout] ./spec/spec_helper.rb`).

Repro: any turn where the model makes two gated bash calls, the first producing streamed
stdout. Suspect the ToolOutput pane write racing/clobbering the prompt redraw AND the
approval read, since the first approval (no prior streamed output in that turn) is fine.

**Verified on the plain path, where it is UNRECOVERABLE.** Ran
`lain chat --provider ollama --model qwen3-coder:30b --prompt '...bash twice...'` in a bare
tmux window with no nvim:

* first approval renders and is answerable: `agent asks: approve bash({"command" => "echo HELLO"})? [y/N] y`
* the tool runs: `[call_6q59oc6m stdout] HELLO`
* `approval_pending agent bash call_xhqo8ep7` is journaled at 15:41:07
* **the pane renders nothing further, and stays that way**
* `y` -> echoed, not consumed, journal flat at 15 lines
* `/approve` -> echoed, not consumed, journal still 15 lines

So on `lain chat` there is no second surface and no escape: the session is permanently
wedged with an approval that can never be answered. In the cockpit `:LainApprove` saves you;
here nothing does.

**Severity: this is a session-killer on the default non-cockpit path, and it needs only two
gated tool calls in one turn to trigger.** Same class as round 1's worst defect.

### F19 — `inbox_count` disagrees with the inbox buffer (LOW, unconfirmed)

`.lain/state.json` read `inbox_count=1` while `lain://inbox` rendered
`(no questions pending)` and the one `ask_human` of the session had already been answered.
Not chased further; noted so a later round can decide whether `inbox_count` counts
answered questions, counts approvals, or is simply stale.

### F20 — a designed budget refusal is rendered as an unhandled crash (MEDIUM, UX)

`Lain::Agent::Budget::Exceeded` is the iteration ceiling working correctly, and lain's own
one-line rendering is exactly right:

    error: loop ran 25 iterations, ceiling is 25

But it is preceded by ~30 lines of Async noise the operator reads first:

    0.00s warn: Async::Task [oid=0x780] ... Task may have ended with unhandled exception.
          | Lain::Agent::Budget::Exceeded: loop ran 25 iterations, ceiling is 25
          | → lib/lain/agent/budget.rb:31 ... (27 more frames, incl. async gem internals)

Three problems, in order of importance:

1. **"Task may have ended with unhandled exception" is false.** It IS handled --
   `CLI::Repl#respond` catches it and renders the clean line right after. The operator is
   told a crash happened when a policy limit was enforced.
2. **A policy refusal should not carry a backtrace.** Every other refusal this round
   produced was a clean named line (`--num-ctx ...`, `--api-base ...`, `grep: no matches`).
   This one is the outlier.
3. **It is uncontrolled output.** The warn comes from the Async gem writing directly,
   outside lain's `Sink`. CLAUDE.md's output-discipline rule exists precisely because
   stray writes interleave into NDJSON; the journal survived here only because it is a
   separate fd.

Fix shape: the Budget::Exceeded path should stop the task without letting it terminate the
Async::Task as an exception (or install a task-level handler), so the clean line is the
only thing rendered.

**Also confirms F9's torn-turn half.** The prompt drawn immediately after this torn turn
reads `qwen3-coder:30b ctx 25% idle 0s` -- idle came BACK. T10's comment says the earlier
`Agent#state` version would have left it parked in `:awaiting_model` and suppressed the
reading for the rest of the session. It does not.

## Model behaviour (not lain defects -- for the QA doc's own section)

* `qwen3-coder:30b` burned the **entire 25-iteration ceiling on `/create-plan` without
  writing a single file**. It looped: git status -> find/grep for test frameworks -> more
  listing. Round 3 saw the same shape (three `ask_human` round trips before any file).
  The plan's own escalation trigger is the right response; do not spend turns coaxing it.
* Confirms the standing note: pointing a 3B-active MoE at multi-step orchestration
  scaffolds (`/create-plan`, `/execute-plan`) is the part it cannot do. It writes bowling
  code fine (see Act 3).

### F21 — the iteration ceiling is per-SESSION, so every chat dies silently after 25 model calls (HIGH)

**The headline finding of round 4.**

`Agent#seed_run_state` sets `@iterations = 0`, and it is called from `Agent#initialize`
(agent.rb:183) -- **once per Agent**. `#ask` commits the user turn and calls `#run`, which
calls `run_loop`; nothing anywhere resets `@iterations` between asks. So the
`DEFAULT_MAX_ITERATIONS = 25` ceiling, documented as "the ceilings that bound an autonomous
loop" and rendered as "loop ran 25 iterations", is in fact a **whole-session budget across
every prompt the human ever types**.

Measured, not inferred: at the moment `Budget::Exceeded` fired this session had
**25 `turn_usage` records spread over 9 separate user prompts**. No single prompt ran
anywhere near 25 iterations; the longest was the `/create-plan` turn.

**The session does not die loudly -- it dies silently, and keeps looking alive.**
After the ceiling, every later prompt is:

* accepted at `you>` and committed to the Timeline as a `turn` record,
* immediately followed by `run_interrupted` (heads advance, so each is a fresh commit),
* answered with **nothing on screen at all** -- no error, no refusal, no echo,

while the HUD keeps rendering `qwen3-coder:30b ctx 25% idle 0s` and the `you>` prompt
keeps accepting input. Three prompts in a row vanished this way before the journal
revealed what was happening. An operator would conclude the model had stopped responding.

Repro: any session, drive ~25 model calls over as many prompts as you like, then type
anything. Compare `turn` and `run_interrupted` records in the journal.

Fix shape: reset `@iterations` per `#ask` (the counter that bounds ONE autonomous loop
should start at zero when a new loop starts), and separately decide whether a session-wide
ceiling is wanted -- if it is, it needs its own name, its own number, and a rendered
refusal. Whatever the answer, the post-ceiling state must not silently swallow prompts:
`run_interrupted` with nothing rendered is the part that turns a policy limit into a
mystery.

Related: F20 is the same event's rendering; this is its lifetime.

### QA-DOC-1 — the plan's subject prose and its own oracle file specify different APIs

`planning/qa-manual-end-to-end.md` describes the subject as
"class Bowling::Game exposing #roll(pins) and #score", but the committed grading
instrument `planning/qa-bowling-oracles.rb` calls **`Bowling.score(rolls)`** -- a module
function taking the whole roll array.

A driver who prompts from the prose gets `0/5 oracles pass` with five identical
`NoMethodError: undefined method 'score' for module Bowling`, which reads like a model
failure and is not one. Cost this round: one wasted model call plus the diagnosis.

The oracle is authoritative (the plan says so: "Do not re-derive it, and do not let the
model near it"), so the PROSE should be corrected to name `Bowling.score(rolls)`.

### MODEL-1 — one malformed tool call poisons the rest of the session (reproduced cleanly)

Round 3 recorded "it emits tool calls as literal text" and said not to file it as a
provider bug without a cleaner reproduction. Here is one, and it identifies the mechanism:

* Contaminated session, prompt A (long file): assistant turn arrives as **text**
  `<function=write_file> <parameter=path> lib/bowling.rb </parameter> <parameter=co...`,
  never parsed as `tool_use`. No file.
* Same session, prompt B (explicitly "under 30 lines"): **same failure**. So it is not
  payload length.
* **Fresh session, prompt B verbatim: `write_file` parses correctly and writes 859 bytes.**

So the trigger is the transcript, not the request. Once one malformed call is committed to
the Timeline as assistant *text*, the model imitates its own bad example and every later
tool call degrades the same way. The session never recovers.

Still a model/parser issue rather than a lain defect -- but it has a harness-side
implication worth a card: an assistant turn whose text contains `<function=` /
`</tool_call>` is a detectable, self-reinforcing failure. A middleware could refuse to
commit it verbatim, re-prompt once, or strip the fragment, and turn a dead session into a
retried turn. Lain's losslessness is what faithfully preserves the poison.

## Act 7 — grading the model's scorer

**4/5 oracles pass.** The model produced plausible, idiomatic, WRONG code, and the
oracle set caught it exactly where the plan says it would.

    all gutters                        want   0  got   0  PASS
    perfect game                       want 300  got 300  PASS
    all spares, 5 first ball           want 150  got 150  PASS
    mixed with open frames             want 133  got 120  FAIL
    nine opens then 10,10,10 in tenth  want  30  got  30  PASS

The defect:

    def next_roll(frame)
      @rolls[frame + 1]      # the frame's OWN second roll
    end                      # should be @rolls[frame + 2]

A spare's bonus is the next frame's first roll, not the second roll of the spare's own
frame. Hand-traced, this yields exactly 120 on the mixed game (frames score
5,9,14,15,11,1,13,14,20,18), which matches the run.

**New, and worth adding to the plan's oracle notes: oracle 3 is DEGENERATE for spare
bonuses.** "all spares, 5 first ball" makes every roll a 5, so `rolls[frame+1]` and
`rolls[frame+2]` are the same number and this off-by-one is invisible. The plan already
warns that oracles 1-3 miss a bonus-on-every-frame scorer; this is a second, different
bug that oracle 3 structurally cannot see. Oracle 4 remains the load-bearing one.

Act 7's verdict on the round-trip: **the plumbing worked and the artifact is wrong.**
That is exactly the separation the act exists to make.

## Act 4 — the review flow

Confirmed working: F4's banner names the gesture
(`walk it in lain://review; <CR> opens a row, :LainNote annotates, :LainReviewVerdict
approve hands it back`); `<CR>` opens sidebar | OLD | NEW with focus landing in NEW exactly
as the plan documents; `x` redraws `[ ] -> [x]`; F5's acknowledgement renders
(`lain: unit-content-v1:94f0ca422121... is now reviewed`); and `x` on an unopened row
refuses by name and leaves the row unmarked:

    lain: lain://review line 3 names lib/version.rb, which nothing has read -- open it with <CR> first

### F22 — the nvim frontend delivers refusals two different ways, one of them a crash (MEDIUM, UX)

`:LainReviewVerdict approve` over a partially-reviewed changeset produces a **Lua error
with a stack traceback** and a blocking `Press ENTER or type command to continue` modal:

    Lua :command callback: approve is refused over a changeset that is not fully reviewed:
    lib/version.rb is unreviewed -- mark every hunk, or open the session with
    Lain::Review::Verdict::Policy::Permissive.new if this run means to judge regardless
    stack traceback:
    	[C]: in function 'error'
    	[string "<nvim>"]:1138: in function <[string "<nvim>"]:1135>

The refusal TEXT is excellent -- it names the file, the remedy, and the escape hatch. The
delivery is the defect, and it is inconsistent within the same feature: the `x`-on-unopened-row
refusal seconds earlier rendered as a clean `lain: ...` message line with no traceback and
no modal. Same subsystem, same class of condition, two deliveries.

Same family as F20 (budget ceiling rendered as an unhandled Async exception): **lain's
refusals are well-written and then surfaced as crashes.** Worth one card covering both,
since the rule is single: a refusal is not an error.

Minor, same message: it names a Ruby constant
(`Lain::Review::Verdict::Policy::Permissive.new`) at an nvim operator who has no Ruby
console in front of them. If the escape hatch has no editor-side spelling, say so.

### UX3 — one `x` emits six acknowledgements

A single `x` on `lib/bowling.rb` logged six `lain: unit-content-v1:... is now reviewed`
lines (one per hunk in the file). Only the last is visible in the message line; the rest
are only in `:messages`. Correct, but the row gesture is file-shaped while the
acknowledgement is hunk-shaped, so the count surprises. Consider one summary line
(`lib/bowling.rb: 6 hunks reviewed`) for a row-level gesture.

## Act 8 — destructive probes (all PASS)

**Torn `turn` record.** Halved record 16 of a 53-turn journal. `lain sessions` reported
`52 turns ... blake3:509231739724  1 line unparsed` -- one fewer turn, the SAME head
digest, and F6's `1 line unparsed` suffix. Forking at that advertised head:

    cannot fork <session>: turn record 3 (user) recorded as blake3:6dbf0c8b... re-commits
    to blake3:6aaa90f1...; its content no longer matches its content address

Exit 1, no backtrace. **Invisible at rest, unforgeable on use -- both halves hold.**

**Dangling causal edge.** Removed a turn that a later turn names as `parent` (these
journals carry `parent`, not `causal_parents` -- the latter needs subagent/message
records, which this run never produced; worth noting in the plan, since the probe as
written assumes them). Both entry points refuse cleanly and symmetrically:

    cannot fork <session>: turn record 0 (assistant) recorded as blake3:53f6b032... re-commits to blake3:465e9071...
    cannot resume <session>: turn record 0 (assistant) recorded as blake3:53f6b032... re-commits to blake3:465e9071...

Both exit 1. Follow-up #1's "fixed for `--fork` only" is confirmed **stale in the good
direction**: `--resume` is equally clean, and carries its own `cannot resume` prefix.

**Bad `--fork` digest prefix.** `no turn matching "closed" recorded in <session>` --
a clean refusal naming both the prefix and the session (found by accident when an `awk`
column slipped; kept because it is the exact refusal the plan wants for an unmatched
prefix).

## Notes for the QA process itself (for the next round's doc)

1. **Drive nvim over RPC, not tmux keys.** This is the single biggest process improvement
   of round 4. The plan's Act 4 advice ("repeat `C-w h` until `bufname()` prints
   lain://review"; "fifteen minutes of the 2026-08-18 run went into this") is superseded by:

   ```bash
   S=$XDG_RUNTIME_DIR/lain/nvim-<hash>.sock
   nvim --server "$S" --remote-expr "join(map(tabpagebuflist(), {_,b -> bufname(b)}), ' | ')"
   nvim --server "$S" --remote-send ':tabnext 3<CR>'   # the review tab
   nvim --server "$S" --remote-send ':1wincmd w<CR>'   # the sidebar, deterministically
   nvim --server "$S" --remote-expr 'bufname()'        # VERIFY before every gesture
   nvim --server "$S" --remote-send '2G'              # then 'x', '<CR>', etc.
   ```

   Act 4 went from the fiddliest act to the most reliable one, and every gesture is
   verifiable before and after. `--remote-expr "execute('messages')"` is how you read a
   refusal the message line has already scrolled past -- it is how F22 was found.

2. **Read the `lain://` buffers, not just `capture-pane`.** They are a richer evidence
   surface and they disagree with the pane, which is itself a finding generator. F18 was
   only diagnosable because `lain://approval` held the command the chat pane never drew.
   `getbufinfo('lain://X')[0].linecount` is the cheap staleness probe (it is what pinned F17).

3. **Budget QA around F21's 25-model-call session ceiling.** Until it is fixed, a session
   is spent after ~25 calls and then silently swallows prompts. Plan one act per session and
   restart deliberately; do not diagnose a dead session before checking the `turn_usage` count.

4. **Restart the session at the first literal `<function=` in a transcript** (MODEL-1).
   Once one malformed tool call is committed as assistant text the session never recovers,
   and every later act measures a poisoned context.

5. **A counting TCP listener is a cheap, deterministic instrument.** ~12 lines (accept,
   `SO_LINGER 0`, close, count to a file) turned "how many attempts did it really make"
   into a number, and that is what made F16 a finding rather than a suspicion. It
   generalises the plan's severing-proxy advice to any attempt/retry question.

6. **Verify isolation by reading `/proc/<pane_pid>/environ`, and verify the NEGATIVE too.**
   `find ~/.local/state/lain -newermt '<run start>'` returning empty is the proof that the
   sandbox held. Round 4's sandbox leaked nothing.

7. **The journal-quiet rule held perfectly.** Every act sent Enter once and polled the
   journal; no act produced a duplicated turn. Keep the rule as written.

8. **Oracle 3 is degenerate for spare bonuses** -- see Act 7. Worth a sentence in the
   oracle table so a future reader does not trust a 3/5 pass.

9. **The plan's prose and `qa-bowling-oracles.rb` disagree on the API** (QA-DOC-1). Fix the
   prose to say `Bowling.score(rolls)`.

## Act 5 — the bench (PASS)

`lain bench arms spec/fixtures/arms/tasks.yml --provider ollama --model qwen3-coder:30b`,
chat closed, model resident at 32768 so no reload. Completed in ~5 minutes.

    grader score          n   mean  median    min    max
    single-thread         8  0.812   1.000  0.000  1.000
    orchestrator-worker   8  0.812   1.000  0.000  1.000
    dual-ledger           8  0.938   1.000  0.500  1.000

    total tokens          n    mean  median     min     max
    single-thread         8   224.9   212.5   184.0   276.0
    orchestrator-worker   8   441.6   468.5   228.0   682.0
    dual-ledger           8  3283.6  3478.0  2375.0  3902.0

    wall-time (s)         n     mean   median     min      max
    single-thread         8   4.9076   1.3939  1.3484  29.5587
    orchestrator-worker   8   1.7243   1.7948  1.3887   2.1061
    dual-ledger           8  11.8415  12.0347  9.8971  13.5076

The plan's three conjoined checks:

1. **mean grade materially above the 0.0625 floor** -- 0.812/0.812/0.938. PASS.
2. **non-zero on more than one task** -- mean 0.812 over 8 tasks is ~6.5 of 8 scoring 1.000,
   so at least six tasks are non-zero. PASS.
3. **non-zero spend/token row for EVERY arm** -- 224.9 / 441.6 / 3283.6. PASS, and this is
   the one that matters: **follow-up #15 did not reproduce.** The orchestrator-worker arm's
   0.812 is backed by 441.6 real tokens, so it is not a collapsed arm faking a grade on its
   own timeline.

**F10 did not fire.** No `StalledStreamError` anywhere in the run, consistent with round 3's
reading: this arm's requests are 1.4-2.1s, so no stream goes 30s silent even against
single-slot ollama.

Note `single-thread`'s max wall-time of 29.6s against a 1.39s median -- one task took 20x
the median. Not chased; worth a look if the cost axis matters.

## Act 1 leftovers

**T11's `options` asymmetry is exactly as its card specifies.** Verified both halves:

* `LAIN_NUM_BATCH=2048` set, no `--num-ctx`: `session extra={"num_batch" => 2048}` and
  every `request_sent extra={"num_batch" => 2048}`.
* `env -u LAIN_NUM_BATCH`, no `--num-ctx`: `session extra={}`, `request_sent extra={}` --
  **no `options` key at all.**

**`capability_degraded`: exactly one line, nothing on screen** -- as the plan predicts.
`{"capability":"prompt_caching","requirer":"Lain::Context","provider":"Lain::Provider::Ollama"}`.

**Occupancy reconciles across all three readers.** Journal `compaction_decision
window=32768 used=4515` == `turn_usage usage.input_tokens=4515`; `.lain/state.json
occupancy=0.1351`; HUD `ctx 14%`. Occupancy rose monotonically 4380 -> 5370 over the session.

**Window provenance behaves as designed, and T6's per-turn re-resolution is visible:**
turn 1 cold `window=8192 provenance="guessed" signals=[]`; turn 2, model now resident,
`window=32768 provenance="probed"`. A guess never carried signals.
