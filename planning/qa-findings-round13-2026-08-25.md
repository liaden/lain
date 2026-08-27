# QA round 13 — 2026-08-25

## Summary

The **full round plus every other scenario in one context**, at the user's explicit instruction —
which overrode README's "owned rounds get their own invocation" convention and, for the first time,
put `rails-blog` in the same context as the core five.

The headline is positive: **compaction at scale fired, and was measured end to end for the first
time in this bench's history.** `rails-blog` §0/§1 — the path rounds 3 and 4 both failed to reach,
that rounds 11 and 12 slipped, and that README calls "the least-exercised path in the whole QA
suite" — produced 5 real compactions out of 38 decisions, halving the span each time, under exactly
the composed strategy the flags asked for. That required installing Rails 8.1.3.1 into the sandbox,
and **P15/P9 held**: `Gemfile.lock` was byte-identical before and after.

Two HIGH defects are new. **F73** — a second concurrent `lain up` cockpit deadlocks its nvim on an
E325 swap-file modal, killing the editor half including the approval surface. **F74** — the
`stalled_stream` detector kills healthy turns: 5 occurrences across 2 sessions against a server
exonerated by four independent measurements, and the mechanism is a case the code itself flags as
"UNWANTED and not designed away".

Confirmed working, with evidence: F29's `/inbox`-drain fix, F16's retry ordinals, F17's timeline
freeze, round 2's compaction-rewrite F-series, the round-4 "every view dark" UTF-8 crash, T6's
window re-resolution, and this chunk's own `run_tokens` accounting claim.

Not reached: the paid halves of `prompt-slots-and-roles` §6 and `ollama-cloud-arm` (§5+), plus four
scenarios entirely. Named in "What was not reached", not buried.

| id | sev | what |
|---|---|---|
| **F73** | **HIGH** | a second concurrent `lain up` deadlocks its nvim on an E325 swap modal — the editor half, including `lain://approval`, is dead |
| **F74** | **HIGH** | `stalled_stream` kills healthy turns (5×) on a server measured healthy four ways; the code flags this landing site as unwanted |
| F75 | MEDIUM | two lain processes in one project dir share one status feed; the HUD showed a foreign session's `run_tokens`/occupancy |
| F76 | LOW | `lain://approval` hard-wraps the command mid-token, so a substring read of that buffer can miss |
| F77 | LOW | `lain://inbox` and `lain://approval` fold oppositely at rest, undocumented |
| P19 | process | 3,325 dead tmux sockets in `/tmp/tmux-1000` accumulated in ~28h; tmux does not unlink on `kill-server` |
| P20 | process | `session-and-window` §4 and `method.md` P11 still name the retired `.lain/state.json` |
| P21 | process | `prompt-slots-and-roles` §1's instrument (`slot_fills`) is bench-only; a plain chat writes zero |
| P22 | process | `epic-tier` §0's stated epic layout does not match the parser; a hand-written epic yields zero issues silently |
| P23 | process | the `pkill -f` self-kill trap fired for the **eighth** recorded time |

## Round-11/12 defects and standing claims re-checked

| id | verdict | evidence |
|---|---|---|
| F29 (`/inbox` drain swallows the next command) | **FIXED, holding** | at a real parked `human>`: `/status`, `/inbox`, `/status`-after-`/inbox`, `/nonsense` — journal 126 and `message` records 4, unchanged across all four; prose then recorded as `from="human" payload={"answer"=>…}` (4→7) |
| F16 (retry ordinals `1,2,3,3`) | **FIXED** | `attempt 1,2,3` then `attempt 4, giving up` — give-up names a *higher* ordinal |
| F17 (`lain://timeline` freezes after first ask) | **FIXED** | 1→6 on a multi-line reply, 6→8 on the next ask, `turn_usage=4`, zero contract-break markers |
| round-2 F-series (one crossing rewritten 3×) | **ABSENT** | 5 compactions at distinct timestamps, distinct `source_head`/`derived_head`, distinct byte ranges = 5 separate crossings |
| round-4 "invalid UTF-8 leaves every view dark" | **FIXED** | invalid bytes planted in `AGENTS.md` **and** `.lain/prompt.toml`; all seven buffers still primed |
| T6 (window resolved once and memoized) | **ABSENT** | 8192 `guessed` → 32768 `probed` inside one session |
| F26 (concurrent unjournaled oracle starves the turn) | **not the cause here** | `oracle_answer=0`, `provider_wait=0` in the stalling session — see F74 |
| round-9's `num_batch` re-keys the runner | **CONFIRMED, opposite direction** | round 9 went 512→2048; I went 2048→absent and the runner reloaded to `-b 512` with a new pid |
| P9/P15 (`GEM_HOME` re-locks `Gemfile.lock`) | **HELD** | md5 `f51222770364686a2cb61b9845368b05` identical before and after installing Rails into `$QA/gems` |

---

## F73 — HIGH — a second concurrent cockpit deadlocks its nvim on a swap-file modal

**What is wrong.** Starting a second `lain up` cockpit while another is running leaves the second
cockpit's nvim sitting on nvim's `E325: ATTENTION` swap-file prompt. The modal blocks *before* nvim
serves RPC, so the entire editor half of that cockpit is unusable — `lain://approval` cannot be
read and `:LainApprove` cannot be sent, which is precisely the surface `method.md`'s approval
discipline depends on. The chat pane works normally, so the cockpit looks healthy.

**Mechanism.** `lib/lain/cli/up/cockpit.rb:105` — `SCRATCH_BUFFER = "file lain-cockpit://start"`.
The buffer is deliberately *named* (the docstring explains this at length: naming it is what trips
snacks.nvim's own "buffer has a name" guard). A named buffer gets a swapfile, and the name is a
constant with no project scoping, so the swap path is a constant too:
`$XDG_STATE_HOME/nvim/swap/lain-cockpit:%%start.swp`. Nothing in the pane command sets
`noswapfile` or `buftype=nofile`. Two cockpits on two *different* projects — different project
hashes, different nvim sockets — still collide on that one path.

**Evidence ruling out the innocent explanations.**
- Not pane geometry (the cheap explanation `method.md` names first): panes were 100x50, not 80x24.
- Not sandbox-specific: the real path is `~/.local/state/nvim/swap/`.
- Reproduced **twice** against the real product — once by accident, once deliberately.
- Control A (single cockpit, swap dir cleaned): RPC answers, layout draws, and a
  `lain-cockpit:%%start.swp` **is** created in normal operation.

**Reproduction.**
```bash
lain up --socket S --session a /path/to/projectA -- --provider ollama --model qwen3-coder:30b
lain up --socket S --session b /path/to/projectB -- --provider ollama --model qwen3-coder:30b
nvim --server "$XDG_RUNTIME_DIR/lain/nvim-<projectB-hash>.sock" --remote-expr '1+1'   # times out
tmux -L S capture-pane -p -t <B's nvim pane>    # E325: ATTENTION ... (STILL RUNNING)
```

**Recovery, such as it is.** None over RPC — it is deadlocked before serving. Answering `q` in the
pane by hand quits nvim outright, leaving a dead editor pane. Both `.swp` and `.swo` were observed.

**Fix shape.** Add `noswapfile` (or `buftype=nofile`) to the scratch buffer's `-c` sequence, or run
the pane's nvim with `-n`. **What would pin it:** two cockpits on two projects brought up
concurrently, asserting the second's `--remote-expr` answers.

**Honest residue.** A reduced repro — two TTY nvims with the same `:file` name and nothing else —
did **not** reproduce, so `:LainStart`/the shipped plugin participates in the failure. The
mechanism is identified but not fully isolated.

## F74 — HIGH — `stalled_stream` kills healthy turns

**What is wrong.** `error: stalled stream: no bytes for 31.0s, past the 30s stream_stall_timeout,
with the connection still open` is rendered to the user and the turn is abandoned
(`run_interrupted`, `reason: "stalled_stream"`), on a server that is not stalling.

**Frequency.** 5 occurrences across 2 sessions in ordinary use.
Session A: `request_sent=5`, `turn_usage=2`, `run_interrupted=3`.
Session B (driven through a logging proxy): `request_sent=12`, `turn_usage=10`, `run_interrupted=2`.
Timing on one: `request_sent` 00:28:37.628 → `run_interrupted` 00:29:14.309 = **36.7s**.

**Evidence ruling out the innocent explanations — the server, measured four ways on the same warm
resident runner (`-b 2048`, ctx 32768):**

| measurement | result |
|---|---|
| time-to-first-byte, small prompt, 3 runs | 0.26s / 0.28s / 0.51s |
| time-to-first-**content**, ~5000-token (lain-sized) prompt, 2 runs | 2.28s / 0.23s |
| long generation: 3,105 chunks over 40.7s | **max inter-chunk gap 0.04s**, median 0.011s, gaps>5s = 0 |
| logging pass-through proxy, in the very session that recorded 2 stalls | 13 upstream requests, first byte **0.33s–1.82s on every one** |

- Not a model reload: runner pid stable, age 3:44 at the stall, `-b 2048`, model resident.
- Not F26: `oracle_answer=0` and `provider_wait=0` in the stalling session — no concurrent
  unjournaled call to hold the one slot.

**Mechanism.** `lib/lain/provider/http/streaming/faraday_handlers.rb` enumerates the five places the
stall clock's async raise can land and flags **#5** as *"UNWANTED and is not designed away"* — the
request's own post-body code, still inside `#watch`'s `yield` after the last `#receiving` has
resumed: *"the clock gets no end-of-body signal, so it cannot tell the middleware stack unwinding
below `StallProtection` from upstream [silence]."* That matches the observed signature exactly:
"connection still open", a ~31s wall-clock fire, and no upstream slowness.

**So the finding is not a new mechanism** — it is the first evidence that documented case #5 fires
in **ordinary operation** on the local arm and destroys the turn.

**Reproduction.** Drive a `--provider ollama` session through several tool-calling turns against a
warm `qwen3-coder:30b`; watch for `run_interrupted reason=stalled_stream` while a proxy shows every
upstream request answering in about a second.

**Fix shape.** Give the clock an end-of-body signal so `#stop` can disarm before the request's
post-body code runs. **What would pin it:** a stream that completes normally while the consumer's
post-body code takes longer than the stall timeout, asserting no interrupt is delivered.

**Residue.** I could not instrument lain's own read loop, so the landing site is inferred from the
code's own enumeration plus the signature, not observed directly.

## F75 — MEDIUM — two lain processes in one project directory share one status feed

`StatusFeed` is keyed on the project hash, so a second lain process in the same directory overwrites
the first's `state.json`. The cockpit's HUD then displays a foreign session's numbers.

**Evidence.** After two cockpit turns, `run_tokens=10023` matched the cockpit's own journal
accounting exactly. Two non-interactive `lain chat` probes in the same directory then moved it to
`run_tokens=70304`, `occupancy=0.1991`, while the cockpit's journal still totalled 10023. One
further cockpit turn reclaimed it to `15062`, again matching journal accounting exactly.

**Why it is still a finding.** `project_dir.rb`'s docstring anticipates the multi-session case and
says *"the cockpit never hits it: `lain up` pins both panes to one cwd"*. That is false whenever any
**other** lain process runs in the same cwd — routine for a QA driver, and plausible for a user with
a second terminal. Self-corrects on the next turn, so severity is MEDIUM, not HIGH.

**Incidental result worth keeping:** this is also the verification of this chunk's own claim that
`run_tokens` "agrees with accounting" — it does, exactly, twice (10023 = 10023, 15062 = 15062).

## F76 — LOW — `lain://approval` hard-wraps the command mid-token

The approval buffer wraps the rendered command at pane width without regard to token boundaries, so
a call renders as `cargo buil` / `d`. It reassembles correctly when read as text, but a driver or
config grepping that buffer for a command substring can miss. `method.md` tells drivers to read this
exact buffer before answering a blind approval.

## F77 — LOW — `inbox` and `approval` fold oppositely at rest, undocumented

Measured on `lain://inbox` (nvim 0.12.4) with two parked questions: record rows are **closed** at
rest (lines 1–6 and 7–11), the blank separator is its own closed fold, and the affordance line is
**open**. Round 9 measured `lain://approval` the other way round — rows open, trailer closed.

Each arrangement suits its own buffer (you must read a command before approving it; you need the
affordance visible to answer an inbox item), so this is a documentation gap rather than a defect.
**Fold independence passes**: `zo` on row 1 flipped `closed=1 → -1` across its lines while row 2
stayed `closed=7 closedend=11`.

---

## Model behaviour (not lain defects)

- **`/create-plan` remains undriveable by `qwen3-coder:30b`.** Nine turns of
  `read_file`/`list_files`/`run_skill`, zero files written. Matches round 4. It did **not** hit the
  25-iteration ceiling (12 requests) and the session survived.
- **A polluted context costs real work.** The same bowling ask that burned ~20 turns without writing
  anything succeeded on the **first** directive prompt in a fresh session. Consistent with round 8's
  finding that a fresh session helps but is not protection.
- **`bowling-ruby` scored 3/5 oracles**, and the failure is on the load-bearing one. Gutters (0),
  perfect game (300) and the tenth-frame case (30) pass; all-spares wants 150 and got 100, mixed
  wants 133 and got 96 — the spare bonus is not added. The 2026-08-19 baseline was 5/5, but that is
  **not** a controlled comparison (different prompt, different session). The follow-up fix turn was
  itself killed by F74.
- **`rails-blog` did not reach its definition of done**, as the scenario predicts. It produced 74
  files, three models (`post.rb`, `comment.rb`, `tag.rb`) and six test files; `bin/rails test` fails
  at boot because the app was generated `--skip-bundle` and `db/migrate/` is empty. The scenario is
  explicit that finishing is not the measurement.
- No `<function=` poisoning was seen in any session this round.

## Process findings

- **P19 — 3,325 dead tmux sockets in `/tmp/tmux-1000`, accumulated in ~28 hours** (2,739
  `lain-spec-*`, ~500 `tmux-surface-spec-*`, 82 `fleet-windows-spec-*`; oldest 2026-08-24T15:00,
  newest 2026-08-25T19:12). **Zero were live.** The specs *do* call `kill-server` in teardown — I
  measured the control: tmux does **not** unlink its socket file on `kill-server`, so a dead
  `srw-rw----` remains. Cost is dirent/inode pressure, not disk (all 0 bytes). Fix shape: unlink the
  socket path in the same `after`/`ensure` that kills the server.
- **P20 — the QA corpus still names a retired path.** `session-and-window.md` §4 tells the driver to
  read `.lain/state.json` for `occupancy`; that file is retired. `project_dir.rb` documents the move
  to `$XDG_STATE_HOME/lain/status/<project_hash>/state.json` and ships a spec that fails any
  expression recomposing the old path. Consequently `method.md`'s third close-out check
  (`ls -d "$LAIN_REPO"/.lain`) now guards a *different* leak than its stated rationale — still worth
  keeping, because `config.toml`, slots, skills and epics all still live under `.lain/`.
- **P21 — `prompt-slots-and-roles` §1 is not executable as written.** It asks for exactly one
  `slot_fills` record; `slot_fills` exists only in `lib/lain/bench/` and is written by
  `Bench::CLI::RunRecorder`. A plain `lain chat` writes **zero**, so a driver following §1 either
  files a false defect or passes vacuously. The underlying feature is fine — the override lands
  verbatim in the `session` record's `system` field.
- **P22 — `epic-tier` §0's layout does not match the parser.** §0 describes
  `research.md`, `epic.md`, `issues/<id>.md`, `plans/<id>.md` and instructs the driver to hand-write
  it. `Epic::Document.parse_markdown` reads issues from `epic.md`'s own markdown grammar. A
  hand-authored `epic.md` with a non-empty `## Issues` section yielded **zero** issues silently, and
  `lain epic status` then reported `remaining: nothing -- every issue is done`. Two work items: fix
  §0's layout, and consider warning when a non-empty epic document parses to zero issues.
- **P23 — the `pkill -f` self-kill trap fired again, the eighth recorded time.**
  `pkill -u "$(id -u)" -f 'nvim.*lain-cockpit'` matched the issuing shell's own command line and
  killed it (exit 144). `method.md` is right that this is a standing hazard rather than an absorbed
  lesson. It also nearly cost the operator's own unrelated nvim.
- **P16 recurred and was recognised, not acted on.** A `git status` taken after sourcing the sandbox
  env showed four extra untracked entries (`.envrc`, `.local/`, `not/`, …) because the redirected
  `XDG_CONFIG_HOME` hides git's global ignore. The baseline taken *before* sourcing is the real one.
- **A killed cockpit leaves its nvim socket file behind**, so `nv.sh` correctly refuses on the
  ambiguous glob until it is removed by hand. Same family as P19.
- **Driver error, recorded:** my first mechanized approval gate treated *relative* paths
  (`bin/rails`, `app/views/tags`) as absolute and wrongly **denied two legitimate calls**. Fixed and
  self-tested (0 false positives on relative paths, 2 true positives on absolute). Those two denials
  were mine, not the model's.

## Withdrawn before filing

- **"`lain://timeline` and `lain://request` are frozen"** — withdrawn. They did not move across my
  second ask because that ask landed at a `human>` prompt with a `fleet 1` subagent parked and
  produced no top-level turn. Correct behaviour; my driving error.
- **"`bench arms` refusals exit 0"** — withdrawn. `$?` after a pipeline is `tail`'s status.
  Re-measured without the pipe: all three exit 1.
- **"`/inbox` drain swallowed the next line" (an F29 regression)** — **inconclusive, not a pass.**
  My first probe was invalid: the session was still dispatching when I typed, and the journal growth
  95→105 was an in-flight `run_skill` loop with continuous timestamps, not a response to `/inbox`.
  I then re-drove it properly against a genuine parked question and it **passed 5/5** (see the
  re-check table).

## What was not reached, and why

**Scenarios not driven at all** — four, all owned rounds, dropped because this context had already
absorbed the full round plus `rails-blog`:

- `secret-boundary` (discharged round 10, so the least costly to defer)
- `changeset-review`
- `subagents-and-backends`
- `memory-and-dogfood`

**Partially driven:**

- `failure-injection` — §1, §2, §8, §9 (partial) driven. §3–§7 and §10–§12 not reached. §9's
  refusal *texts* were verified through §8; its read-set state assertions
  (`session.read?`/`partially_read?` → `[false,true]` then `[true,false]`) were not driven.
- `epic-tier` — §1, §1b, §3 driven; §2 and §4–§9 not, blocked by P22.
- `cockpit-surfaces` — §1, §3, §5b, §6, §7, §8 driven; §4/§4b belong to `survey.md` by README's own
  stated boundary and were not driven here.
- `repl-commands` and `survey` — **not driven.** Both are regression-gate members. This is a gap.

**Paid steps deliberately not taken:**

- `prompt-slots-and-roles` §6 second half — **no `ANTHROPIC_API_KEY` in this environment.** The free
  half settled the byte count (364 bytes = ~91 est. tokens against a 4096-token floor); the **wire**
  behaviour is unsettled. Not conflated.
- `ollama-cloud-arm` §5 onward — steps 1–4 are free and were driven and pass. The metered steps
  spend the operator's subscription quota, and **I did not have explicit authorization to spend it**,
  so they were not run.

## Preconditions and the close-out negatives

- Machine gate **passed**: 92.9% instantaneous idle, and **zero orphaned spinners** — the first
  clean round after rounds 10, 11 and 12 were all contaminated. One contaminant present and named:
  `mempalace mine` held ~100% of one core throughout (the operator's own tool, not an orphan).
  **No absolute wall-clock claim in this round rests on an uncontended box.**
- `n_slots = 1`, `OLLAMA_NUM_PARALLEL:1` — the contention precondition holds.
- Sandbox gates: every pane reported `LAIN_DESKTOP=0`, 5/5 sandbox-scoped `XDG_*`+`TMPDIR`, and
  (for `rails-blog`) `GEM_HOME=1`. `~/.lain` absent throughout. Server sized 220x50.
- **Negative 1 — the sandbox held.** `find ~/.local/state/lain -newermt '2026-08-25T23:40:11Z'` → **0**,
  against positive controls of **1,188** (`-newermt '2026-08-19'`) and **7,006** (`-newermt '2026-08-01'`).
  The zero is evidence, not a spelling accident.
- **Negative 2 — the repo.** `git status --porcelain` matches the baseline taken before act 0 exactly
  (` M references/repos/smolagents`), in a shell that had **not** sourced the sandbox env.
  `Gemfile.lock` md5 identical despite a sandbox `GEM_HOME` reaching `exe/lain`.
- **Negative 3 — `.lain` in the checkout.** Absent. (Neither of the other two negatives can see this.)
- **Desktop.** No act ran with the notifier on, so nothing was raised and nothing needed closing.
  `dunstctl count history` unchanged at its baseline of 20. Two notifications were displayed at
  close-out and are **Claude Code's own** "Claude is waiting for your input", identified from dunst
  history — the operator's tooling, left untouched rather than swept up by a `close-all`.
- QA tmux server killed; no stray `lain`, cockpit-nvim, proxy or driver processes remain.
- Sandbox left in place at `~/tmp/lain-qa-round13-2026-08-25/` — it is the evidence.

## Scenario coverage

| scenario | driven | result |
|---|---|---|
| `session-and-window` | **all 8 sections** | PASS |
| `rust-cli` | both paths | PASS |
| `bowling-ruby` (subject) | §1 + fallback | 3/5 oracles; model finding |
| `cockpit-surfaces` (piggybacked on the subject) | §1,3,5b,6,7,8 | PASS |
| `bench-arms` | full | PASS |
| `rails-blog` | §0,§1,§2 | **compaction reached — first time ever** |
| `prompt-slots-and-roles` | §1–§4, §6 free half | PASS + P21 |
| `epic-tier` | §1,§1b,§3 | PASS + P22 |
| `failure-injection` | §1,§2,§8,§9(part) | PASS |
| `ollama-cloud-arm` | §1 (free) | PASS |
| `repl-commands` | — | **not driven** |
| `survey` | — | **not driven** |
| `secret-boundary` | — | not driven (owned) |
| `changeset-review` | — | not driven (owned) |
| `subagents-and-backends` | — | not driven (owned) |
| `memory-and-dogfood` | — | not driven (owned) |
