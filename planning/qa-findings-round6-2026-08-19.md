# QA round 6 — 2026-08-19

## Summary

**All seven scenarios were opened; five completed, one (`bowling-ruby`) completed on a compressed
path, and one (`rails-blog.md`) was deliberately not run — see "What was not reached".** Every
round-5 defect re-checked behaves differently, and all of them better, including the HIGH one.

**Two new defects, one UX finding, one feature gap, four process defects in the bench's own
method, and three withdrawn suspicions.**

| id | sev | what |
|---|---|---|
| **F26** | **HIGH** | an unjournaled concurrent oracle call starves the main turn on a 1-slot server; the loser waits 35–65s with zero bytes and is torn down by the 30s `stream_stall_timeout` on a perfectly healthy server |
| **F27** | **MED-HIGH** | at the `human>` prompt every session command except `/inbox` is silently delivered to the subagent as a prose answer — no refusal, and the operator's escape hatch is gone exactly when a looping subagent creates the need for one |
| UX9 | LOW | a model-facing tool refusal carries a Ruby class name (`Lain::Tool::ContractViolation: precondition failed for edit_file:`) in front of the sentence written for the model |
| FG1 | gap | `lain chat --prompt` exits **0** when the turn fails outright, so no script can tell a completed ask from a dead endpoint |

**The through-line is contention and the surfaces around a fleet.** F26 and F27 are both about what
happens once a *second* actor exists — a second model call, or a second party at the prompt. The
approval and refusal surfaces that produced rounds 4 and 5's findings are, this round, clean.

**Compaction at scale was reached — by accident, and on occupancy.** Six `compaction` records fired
this round with `trigger: ["token_threshold"]`, 335–360 KB of canonical bytes collapsing to
14–26 KB. Round 5 saw one, triggered by `plan_step_completion`; this is the first time any round has
seen the occupancy path execute, and it is the first evidence for it outside specs. It does **not**
discharge `rails-blog.md` §1, which asks additional questions about strategy composition.

---

Bench: ollama 0.32.12 (`/mnt/nvme/opt/ollama-0.32.12`), qwen3-coder:30b,
`OLLAMA_CONTEXT_LENGTH=32768`, `KEEP_ALIVE=5m`, KV `q8_0`, Vulkan.
**n_slots = 1 / OLLAMA_NUM_PARALLEL = 1**, read from the runner's own argv (`-np 1`) via
`pgrep -P <serve-pid>` rather than the serve log — the server was a pre-existing 1d05h process this
round reused; its `environ` and `/proc/<pid>/exe` were verified to be the `/mnt/nvme` install first.
`-c 32768 -b 512 -ub 512` in the same argv confirms `bench.md`'s reason for `LAIN_NUM_BATCH`.
**Cold load of qwen3-coder:30b measured 27.2s** (round 5 recorded 29.6s).
ruby 4.0.6, nvim **0.12.4** (so `'messagesopt'` is available and `:messages` holds the unfolded
refusal), tmux 3.7b, cargo 1.99.0-nightly, `dunstify` at `/usr/bin/dunstify`, dunst running with
`idle_threshold = 120` confirmed in `dunstrc`.
Machine at round start: load 1.13, `mempalace mine` at 99.6% CPU throughout (the known contaminant),
no orphan spinners, no `parallel_rspec`, no `pre-commit`.
Sandbox: `~/tmp/lain-qa-round6-2026-08-19`, XDG redirected, `tmux -L lain-qa-round6-2026-08-19`.
All three panes verified carrying sandbox `XDG_*` and `TMPDIR` before act 1, and again after the
second cockpit launch.

**Desktop decision.** Everything in this round ran under `LAIN_DESKTOP=0` **except one named act**:
`cockpit-surfaces.md` §5, the approval-notifier regression, which requires the notifier on to test
anything. That act raised 5 notifications; all 5 were withdrawn or closed, and the desktop was
verified at `displayed=0, waiting=0` at close-out.

**That claim is backed by a negative, not by the export, and the distinction matters** — a trial run
on 2026-08-19 established that `LAIN_DESKTOP` is **not** in `PaneCommand::PANE_ENV`, so exporting it
in the shell that runs `lain up` does nothing; only the shell that starts the tmux *server* mutes a
pane. This round's launches did export it before `tmux new-session`, but the load-bearing evidence is
the measurement: **`dunstctl count displayed` and `waiting` were both 0** immediately before the
named act, *after* a full `rust-cli` pass containing roughly six human-answered gated `bash` calls.
Approvals are raised `-u critical` and never auto-expire, so had the notifier been live in those
sessions the popups would still have been on screen. They were not. (The docs have since been
corrected to make this a required gate rather than an assumption.)

**Negative check PASSES and is not vacuous:** `~/.local/state/lain` exists and holds **95 files**;
its newest file is `2026-08-19 08:23:53`, which predates round start (`2026-08-19T13:42:35Z`) by
5h19m; `find ~/.local/state/lain -newermt '2026-08-19T13:42:35Z'` returns **0 files**. `~/.lain`
absent throughout (it remains parked at `~/.lain.bak`).

## Round-5 defects re-checked — every one better

| id | verdict | evidence |
|---|---|---|
| **F23** (message-bearing session can be neither forked NOR resumed) | **FIXED** | Built the exact shape via `@researcher[/critique] src/main.rs` — `message: 4`, `child_turn: 14`, `causal_parents: 7`. `--fork <session>@<head>` → **exit 0**, reaches `you>`. `--resume` → **exit 0**, with an honest `was not gracefully closed; resuming from its last verified turn`. Zero backtrace frames on both. |
| F24 (notifier single-flight; keeps displaying a decided command) | **withdrawal FIXED and verified; "all at once" NOT REACHABLE** | Answering at the chat prompt withdraws the popup: `echo HELLO`'s notification moved to `dunstctl history` (id `374138371`, above the 1,000,000 replace-id floor) while the count stayed at 1 because the *next* pending was raised in the same ~40 ms. Verified on the **deny** path too (`echo RED` → history, displayed one is the fresh `echo GREEN`, matching `lain://approval`). `displayed=0` at turn end, twice. **The "three parked approvals raise three notifications at once" property was not reached** — see "What was not reached". |
| F25 (T16 hit-enter residual fires in ordinary use and blocks nvim RPC) | **not reproduced** | ~15 `nvim --server` RPC calls across the round, several issued immediately after a rendered refusal (tool-bound refusals, the `edit_file` precondition refusal, two approval denials); **none blocked or timed out**. Not driven with its own specific trigger, so this is "did not reproduce", not "proven fixed". |
| UX4 (`lain://approval` never primed, absent at rest) | **FIXED** | At attach, before any gating: all 8 `lain://` buffers exist and `lain://approval` holds `(no approvals pending)`. |
| UX5 (`compaction.tokens_before/after` are bytes under token names) | **FIXED** | All six `compaction` records this round carry **`bytes_before` / `bytes_after`**. `cost_saved`/`cost_spent` read `"0.0"` beside the local model — the documented honest zero, not a free compaction. |
| UX6 (`lain up` dead-pane banner eats the first line) | **FIXED** | The corpse report's body begins `zsh:1: no such file or directory: ./exe` — the causal first line survived, i.e. `PaneCorpse#held` is reading `-S -` scrollback. |
| UX7 (single-line file gets advice it cannot act on) | **FIXED, and correctly scoped** | `one.json` (1,200,003 B, newline-free, over `WINDOW_BOUND`) → `take a byte range with bash ('head -c 100000 PATH' …) -- one line alone is over the ceiling`. `mid.json` (300,003 B, newline-free, **under** `WINDOW_BOUND`) → still the full-cover advice. The fix did not over-reach; the control is what proves it. |
| UX8 (retry backoff at 17 significant figures) | **FIXED** | Two arms of the blackhole probe rendered `0.13s / 0.2s / 0.41s` and `0.1s / 0.22s / 0.45s`. No long decimal tails. |

Also re-confirmed: **T6** (window re-resolves mid-session), **T12** (`bench arms` attribution header
and cost degradation), **T18** (retry ordinals), **F16** (give-up names a higher ordinal), **F17**
(`lain://timeline` moves), **T1** (price table), and the `lain up` whole-server-death class.

---

## New defects

### F26 — HIGH — a concurrent oracle call starves the main turn on a one-slot server, and the stall timeout kills it

**What is wrong.** Lain issues a second `/api/chat` request (the oracle, consulted about a tool
result) ~25 ms after the main turn's request. With `OLLAMA_NUM_PARALLEL=1` the server serializes
them, the main turn waits with **zero bytes** for 35–65 seconds, and the 30 s
`stream_stall_timeout` tears it down — on a completely healthy server. The human sees
`error: stalled stream: no bytes for 30.8s, past the 30s stream_stall_timeout, with the connection
still open` and the ask is `run_interrupted`.

This is round 3's **F10** class (`bench.md` records it as the reason `n_slots` is a precondition),
still live, and now measured rather than inferred.

**Mechanism, measured.** A logging pass-through proxy on `127.0.0.1:21434` recorded start /
first-byte / end per upstream request (`$QA/proxy.rb`, kept in the sandbox):

```
115.453 req#9  START             <- journaled request_sent 14:03:36.857 (the main turn)
115.478 req#10 START             <- 25ms later; NOT journaled (the oracle)
116.504 req#10 FIRST-BYTE        <- the oracle takes the slot
117.615 req#10 END
118.547 req#11 START
151.262 req#9  FIRST-BYTE        <- the main turn waited 35.8 SECONDS for its first byte
152.614 req#9  END
183.318 req#11 FIRST-BYTE        <- and this one waited 64.8 SECONDS
```

Request-to-record mapping is by inter-arrival gap and is exact: journal gaps
`2.378 / 1.364 / 1.624 / 1.417 / 3.070 / 65.812` against proxy gaps
`2.379 / 1.363 / 1.625 / 1.392 / 0.025 / 3.069 / 65.812` — **8 `/api/chat` requests through the
proxy against 7 journaled `request_sent`**, the extra being the 25 ms straggler. The
`oracle_answer` record lands at `14:04:14.649`, i.e. at req#9's first byte.

**Evidence ruling out the nearest innocent explanations.**

- **Not prefill.** A 36,622-byte *uncached* prompt (freshly generated, no prefix cache can cover it)
  completed end-to-end in **9.3 s**. An earlier 30.9 s figure of mine was an artifact — see the
  withdrawal note P8.
- **Not the stall clock arming too early.** `FaradayHandlers`' class doc says the clock "ARMS ON THE
  FIRST TICK and not before". Tested directly with a proxy that holds the first response byte for
  **40 s**: the request completed in 42.6 s and answered normally, **no stall**. So the clock behaves
  as documented, and the tear-down is genuine mid-stream/queued silence.
- **Not a one-off.** Two independent tear-downs in two different sessions:
  `no bytes for 30.8s` (14:57 UTC 13:57) and `no bytes for 30.6s`.
- **Not a sick server.** `ollama ps` resident throughout; the oracle's own call answered in ~1.0 s.

**Two things follow, and the second is arguably the worse one.**

1. The timeout (30 s, `LAIN_STREAM_STALL_TIMEOUT`) is **below the wait its own concurrency
   produces** (35.8 s, 64.8 s measured).
2. **The contention is invisible in the journal.** The oracle's model call writes no `request_sent`,
   so a reader has exactly one `request_sent` followed by a `run_interrupted` and no way to see the
   second in-flight request. Every diagnosis of this without a proxy is guesswork.

**Reproduction**
1. `n_slots = 1` (`pgrep -P $(pgrep -f 'ollama serve') | head -1`, then read `-np` from its cmdline).
2. Put a logging proxy in front of `:11434` and launch with `--api-base http://127.0.0.1:21434`.
3. Drive a turn whose tool result is large enough to consult the oracle (`cargo test` on a crate
   that fails to compile is reliable; `cargo build 2>&1 | head -40` also does it).
4. Read the proxy log for two `START`s within ~50 ms and a `FIRST-BYTE` more than 30 s after one of
   them; read the chat pane for `stalled stream`.

**Fix shape.** Three candidates, and they are not exclusive: journal the oracle's request so the
contention is legible at all; serialise lain-side against a provider that declares one slot (or make
concurrency a function of the served `n_slots`); and make the stall grace account for time spent
queued rather than time since the request was written. What would pin it: a spec driving two
concurrent asks against a one-slot fake provider and asserting the main ask is not interrupted.

### F27 — MED-HIGH — at the `human>` prompt, every session command except `/inbox` is delivered to the subagent as prose

**What is wrong.** Once a subagent parks a question, the prompt becomes `human>`. There, `/inbox` is
honoured — but `/ruby`, `/mode` and `/status` are **not**: they are silently packaged as the human's
answer and sent to the subagent. Nothing refuses, nothing warns, and the pane shows only the typed
line.

**Evidence, from the journal — this is verbatim, not paraphrase.**

```
14:28:53.909764  from="human" to="blake3:d6d2f12e…"
                 payload={"answer" => "/ruby Lain::Tools::ListFiles.instance_methods(false).sort"}
14:29:31.408501  from="human" to="blake3:d6d2f12e…"
                 payload={"answer" => "The human answered the whole set in prose rather than by
                          selection.\n\nQuestions asked: `question`\n\nReply:\n> /rub…"}
```

`/mode` and `/status` reproduce identically. `/inbox` at the same prompt rendered the inbox and its
`type a reply -- ticking boxes is the nvim buffer` hint, so the registry *is* reachable there for at
least one name — this is a gap in which names, not an absent dispatcher.

**Evidence ruling out the innocent explanation.** Not "commands are simply disabled at `human>`":
`/inbox` works there. Not a rendering loss: the command text is present in the journal as a
delivered `message` payload, so it was routed, not dropped.

**Why it matters beyond ergonomics.** Three things:
- It contradicts the codebase's own stated premise — CLAUDE.md rejects `StringInquirer` precisely
  because "this state machine's premise is that unknown values fail loudly". This fails silently.
- It **contaminates the experiment record**, which on a study bench is the product: operator
  commands enter a subagent's context as if they were content.
- It removes the escape hatch exactly when it is needed. The session that produced this was a
  subagent looping on clarifying questions (model behaviour M2); the human's way to inspect or
  change posture is unreachable for as long as the loop continues.

**Reproduction**
1. `lain up <dir> -- --provider ollama --model qwen3-coder:30b`
2. `@researcher[/critique] <some file>` — wait for the prompt to become `human>`.
3. Type `/ruby 1+1`. Nothing renders; the subagent answers as though you replied in prose.
4. `ruby -rjson -e '…' <journal>` filtering `type=="message"` shows the command as an `answer`.

**Fix shape.** Consult the command registry at the `human>` prompt as at `you>`, and — for whatever
is deliberately not available there — refuse by name rather than forwarding. What would pin it: a
spec driving a parked `ask_human` and asserting a `/`-prefixed line is either dispatched or refused,
never enqueued as a reply.

---

## UX findings

### UX9 — LOW — a Ruby class name rides in front of a refusal written for the model

`edit_file`'s window refusal arrives as:

```
Lain::Tool::ContractViolation: precondition failed for edit_file: only a window of path was read
this session -- an offset/limit read showed you part of the file, so editing it would clobber lines
you never saw. Read it again with no offset and no limit, or with a window covering the whole file,
then edit
```

The sentence after the colon is exactly the one `failure-injection.md` §9 specifies and is good. The
`Lain::Tool::ContractViolation: precondition failed for edit_file:` prefix is internal vocabulary in
a string whose only reader is the model — the same class of noise the refusal-surface work has been
removing elsewhere. Not a defect: the advice is intact and actionable.

## Feature gap

### FG1 — `lain chat --prompt` cannot report failure through its exit status

The blackhole probe exhausts four attempts, renders `error: Failed to open TCP connection to
10.255.255.1:11434 …`, and **exits 0**. Same for the connection-refused case against a dead proxy.

This is *consistent* with the design — `--prompt` is `first_prompt`, a seed for the first read of
`Repl#converse`, not a batch mode, and a human who sees an error then hits Ctrl-D has exited
cleanly. It is filed as a gap rather than a defect for that reason. But it means no script or CI
step can distinguish "the ask completed" from "nothing reached the model", which is the shape
several probes in these scenarios would otherwise use.

What I reached for: a one-shot `lain ask` (or `--prompt --exit-status`) whose status reflects the
ask.

**Ruled 2026-08-19: deliberately not fixed in code.** `--prompt` stays a REPL seed —
`lib/lain/cli/repl.rb:55-58`'s `converse` reads `first_prompt || prompt.read` once, then resumes
`next_text`/`prompt.read` exactly as an unseeded chat does, so nothing downstream of that first
read distinguishes a seeded ask from a typed one, and Ctrl-D after a rendered error is the same
clean exit either way. It is not a batch mode, so `$?` from `lain chat --prompt` was never load-
bearing for a completed-vs-failed distinction; only a **launch-level** refusal (a `Lain::Error`
raised during construction, mapped `Thor::Error` at `exe/lain:845-846` inside the `chat` method,
`:843-847`) exits nonzero, and that split does not change. The non-interactive case alone does not
justify new CLI surface. **Reopen only with a named consumer** — a script or CI step that actually
needs the outcome of a `--prompt` ask from a shell exit code, rather than from the rendered text or
the journal it already has today.

---

## Model behaviour — not lain defects

- **M1 reproduced.** A literal `<function=run_skill> <parameter=name> … </function> </tool_call>`
  appeared as assistant text in a `lain://timeline` row. Session was restarted per `method.md`.
  Notably the *next* turn still answered correctly, so the poisoning is not always immediate — the
  restart rule is still right, but "never recovers" may be too strong.
- **M2 reproduced, repeatedly and expensively.** `qwen3-coder:30b` loops on clarifying questions
  rather than acting. After one denied approval it abandoned the task and asked three consecutive
  rounds of clarifying questions; as a subagent it asked the human four questions in a row without
  ever reading a file. This is what made F27 both discoverable and costly.
- **M3 (new spelling of a known weakness): it does not emit parallel tool calls.** Asked explicitly,
  twice, for three `bash` calls as three `tool_use` blocks in one message, it emitted them strictly
  one per turn. This is what blocked F24's "all at once" check — see below.
- It hallucinated `cd /workspace` as the crate directory on a session whose cwd was correct and
  whose project root had been named on the command line. Refused at the gate, correctly.

---

## What was not reached, and why

Stated plainly, because a path missed by consecutive rounds is itself a finding about the plan.

- **`rails-blog.md` — OWED, not dropped.** It is the third consecutive round to end without it, and
  the shared cause across rounds 4, 5 and 6 is structural rather than a judgement made each time:
  one driver context carried every scenario, so the expensive one competed for budget with the cheap
  ones and lost every time. **That has been fixed in the plan rather than in this round's excuse** —
  `README.md` and the skill now give any `expensive` scenario its own round in its own context, so
  its position in the ordering is irrelevant and it can no longer be starved by the others.
  Reordering was considered and rejected: it only moves which scenario starves.

  Two things still to carry into that separate round. **F26 is a direct impediment** — `rails-blog`
  needs large tool results, large tool results are what summon the oracle, and the oracle is what
  produces the 35–65 s starvation that tears turns down; driving compaction-at-scale against a
  one-slot server before F26 lands would measure the stall, not the strategy, so **F26 should land
  first**. And **the ground has shifted in the good direction**: six occupancy-triggered compactions
  fired incidentally this round (see Summary), so that round starts from "does the *composed
  strategy* do what its name says" rather than "does this path execute at all".
- **F24's "every parked approval raises its own notification at once"** — not reachable with this
  model. The property needs ≥2 pendings simultaneously; `qwen3-coder:30b` never produced two (M3
  above). The single-pending path and the withdrawal path are both verified. **To settle this a
  future round needs either a model that does parallel tool use, or a seeded/fake multi-pending
  fixture** — this is worth building, because F24 was a round-5 MEDIUM and half of it remains
  unverified.
- **The supervisor door of `failure-injection.md` §3** (`cannot restart "<role>" from its session
  record:`) — not driven. Reaching it needs a supervised restart whose replay reads a damaged
  journal, and I found no cheap way to force one from the sandbox. The scenario explicitly says to
  say so rather than mark it passed. The other three doors all pass.
- **§4 (severing proxy + `bench record`)**, **§6 (Ctrl-C during a parked `ask_human`)**, and
  **§10's live oversized-`web_fetch` half** — not driven. §10's two ceilings were verified as
  constants through `/ruby`.
- **`cockpit-surfaces` §§1–4, 6, 7** were only partially exercised (buffers-at-rest, the timeline,
  `lain://journal` population, `:LainDeny`); the review flow (§4) was not driven at all.
- **`--no-nvim` comparison** (`cockpit-surfaces` §5's second half) — not driven this round.

---

## What passed, in brief

Recorded so the next round knows what was actually checked rather than assumed.

- **`session-and-window.md`: all 8 sections pass.** Launch refusals (9/9, exit 1, zero frames);
  `--num-ctx 262144` accepted at the trained maximum with nothing resident; blackhole timing 26.0 s
  default / 8.0 s at `LAIN_CONNECT_TIMEOUT=1`; cold→warm window re-resolution
  **8192/`guessed` → 32768/`probed`**; **three readers agree** — `compaction_decision.used_tokens`
  4807 == the matching `turn_usage.usage.input_tokens` 4807, `state.json` occupancy
  **0.147247314453125** == 4825/32768 exactly, HUD `ctx 15%`; exactly one `capability_degraded`;
  `extra={"num_batch"=>2048}` with the knob and `extra={}` under `env -u`; all four
  `--compact-strategy` names listed in the refusal, part-vs-whole-value wording correct,
  `elide+summarizing` launches as designed; price table 5/25, 3/15, 1/5 with cache-creation exactly
  1.25× and cache-read exactly 0.1×, unpriced models raising by name, `BYTES_PER_TOKEN=4` — all four
  confirmed **through `/ruby` against the live process**, not only the checkout; the freshness lint
  passes fresh, refuses stale under an injected clock, and refuses a **removed** marker by name.
- **`rust-cli.md`: definition of done met.** The model wrote a 154-line `main.rs`, hit 8 real compile
  errors, and after one directive turn the crate **builds, `cargo test` passes 3/3**, and
  `printf 'the cat the dog the\n' | ./target/debug/wordfreq -n 2` prints exactly `the 3` / `cat 1`.
  Compile diagnostics reached the model intact with multi-line spans and no ANSI corruption;
  `lain://journal` held 40 lines of correctly attributed `[call_… stdout]` output.
- **`failure-injection.md`: §§1, 2, 3, 8, 9 (1–4), 10, 11a/b/c pass.** 19 journals, 353 lines,
  **0 unparseable**, no `journal_error`. A torn `turn` gives **17 turns vs 18 under the same head
  digest** plus `1 line unparsed`, then refuses on use from three doors naming index, role and both
  digests. Dangling and malformed (`null`) `causal_parents` both land as `Corrupt` from all three
  doors, with `message` records keeping **their own index space and their own sentence**
  (`message record 0 (message) cites a causal parent this replay never landed` /
  `records causal_parents as […]`) — never `Store::MissingObject`, never `ArgumentError`. Ceilings
  live: **`[262144, 1048576, 131072, 500]`**. Summarizer gates still independent: **`[4096, 262144]`**.
  Read-set transitions `[false,false] → [false,true] → [true,false]`, so the full-cover window
  completes the read and the deadlock guard holds.
- **`bench-arms.md`: all checks pass.** Header names the fixture passed, the model
  (`qwen3-coder:30b`), and `isolation: unset — Arm::NoIsolation leased nothing`; no credential or
  base URL anywhere. Grades 0.812 / 0.812 / 0.938 against a 0.0625 floor, each backed by a non-zero
  token row (218.5 / 439.2 / 3396.8) so no arm is faking a grade on its own timeline. Cost section
  degrades whole: `not priced — no price for model "qwen3-coder:30b"; configure a fallback to
  degrade`, with the other three tables intact. **No `StalledStreamError`** (requests 1.4–2.4 s, as
  the scenario predicts). No wall-time outlier this round — `single-thread` max 2.30 s against a
  1.47 s median, against round 4's 29.6 s vs 1.39 s.
- **`bowling-ruby.md`: 5/5 oracles on the first attempt**, including the load-bearing oracle 4
  (mixed with open frames = 133) and oracle 5 (tenth frame = 30). Graded with
  `planning/qa/oracles/bowling.rb`, which the model never saw.
- **Approval surfaces agree** (`cockpit-surfaces` §5): the pane prompt names the requester
  (`agent asks: approve bash({…})? [y/N]`), `lain://approval` holds the full command text and the
  `-- y approve, n deny  (:LainApprove / :LainDeny)` affordance, the journal carries
  `approval_pending`/`approval_decision` with `surface`, `verdict`, `timed_out:false` and `latency`,
  and `:LainDeny` over RPC records `surface:"nvim"`. **Zero `tty_fault`**, and no `denied` decision
  without a human at the keyboard.

---

## Withdrawn — nearly filed, disproved by the mechanism

Recorded so the next round does not re-file them.

- **"The price-freshness lint is a no-op when the marker is deleted."** My first probe stripped
  `reviewed-on`, which does not occur in the file; the marker is `Reviewed YYYY-MM-DD`. Removing the
  real marker fails correctly: `no "Reviewed YYYY-MM-DD" marker found near the price table`.
- **"The stall clock arms before the first byte."** Disproved by a proxy holding the first response
  byte 40 s: the request completed normally with no stall. The documented first-byte/inter-chunk
  split holds.
- **"`lain://timeline` is frozen."** The session was still pointed at a proxy I had just killed;
  every turn was failing with connection-refused, so there was nothing to render. Re-driven against
  the real endpoint the buffer moved **1 → 2 → 4**. This is the *second* consecutive round in which
  a "frozen timeline" reading turned out to be a driver artifact.

---

## Process defects in the bench's own method

- **P5 — `qa-sandbox.sh` still ships the unpinned-journal `drive.sh`.** `method.md` documents the
  fix (pin `LAIN_QA_JOURNAL`; round 5 built `drive2.sh` in its own sandbox) but it was never folded
  back into `.claude/skills/manual-qa/scripts/qa-sandbox.sh`, so every round re-creates it by hand.
  This round hit the hazard for real: nineteen journals were written, and `ls -t` pointed at a
  throwaway probe rather than the cockpit within minutes of act 1. **Fixed this round** — see below.
- **P6 — a driver that types while an approval is pending answers the approval.** `drive()`-style
  helpers send text then `Enter`; at a `[y/N]` prompt the `Enter` *is* the answer, and the default is
  **deny**. Cost one accidental denial this round, which then sent the model into M2's
  clarifying-question loop for three turns. `method.md`'s "send Enter ONCE" rule does not cover this.
- **P7 — the `pgrep -f` self-match trap bit four times** (orphan spinners, `pre-commit`, the ollama
  runner, and `bench arms`), each time reporting a process that was my own shell's command line.
  CLAUDE.md warns about it for `parallel_rspec`; it generalises to every `pgrep -f` in this method.
  `pgrep -P <parent-pid>` or matching `/proc/<pid>/exe` is the reliable form.
- **P8 — passing `num_batch` to `/api/generate` forces a runner reload, and I misread one as
  prefill.** A 33 KB prompt "took 30.9 s to first token"; it did not — supplying `num_batch: 2048`
  against a runner started with `-b 512` reloads the runner (~27 s), exactly the hazard `bench.md`
  records for `--num-ctx`. Re-measured without it: **9.3 s**. This nearly became a wrong diagnosis of
  F26. `method.md`'s "re-measure the number the doc gives you" earned its place again.

### Folded back into the method this round

- `.claude/skills/manual-qa/scripts/qa-sandbox.sh` now emits **`drive.sh` with the journal pinned**
  to `LAIN_QA_JOURNAL` (P5), **refuses to start if it is unset**, and **aborts rather than typing
  when an approval is pending** (P6).
- `planning/qa/method.md` gains the P6 rule, the P7 `pgrep` form, and the P8 reload caveat.
