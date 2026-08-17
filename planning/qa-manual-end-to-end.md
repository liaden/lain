# Manual end-to-end QA — the recurring bench run

A living document. Round 1 (2026-08-15) produced eleven defects, all of them green in the suite,
and became `specs/chunk-poc-integration-fixes.md`. This is the procedure that found them, written
down so the next round starts from a method rather than from memory.

**The premise: every defect this has found so far lived in a seam that had specs on both sides.**
A manual run is not a slower unit test. It is the only thing that drives two real components
against each other with a human in the middle, and that is where this codebase's defects live.

---

## Toolchain

CLAUDE.md's `~/.rubies` path is unusable on this box and the working environment lives in `.envrc`,
which is machine-local and globally gitignored — so a reader of this plan alone will not find it:

```bash
eval "$(mise env -s bash ruby@4.0.6)"
export LD_LIBRARY_PATH=/home/linuxbrew/.linuxbrew/lib
```

**Override `.envrc`'s `TMPDIR` with the run's own sandbox**, or the QA run and the spec suite share
a tmp tree.

---

## Standing rules

### The approval gate is the point, not the paperwork

A local model requests tool calls on a real machine. Whoever drives is the gate, and the gate is
only worth having if it is read rather than skimmed:

1. **Read every command for what it would do if a path resolved somewhere unexpected**, not for
   whether it contains a scary word.
2. **Refuse anything reaching outside the sandbox** — `$HOME`, `~/.config`, `~/.ssh`, `/etc`, git
   history, another checkout. Record the refusal; a model that asks is a finding.
3. **A convincing rationale for a destructive command is a worse sign, not a better one.**
4. **Start at `accept_edits`, which is already the default.** The four postures are `plan` (reads
   only, `deny_all`), `manual` (everything, `queue`), `accept_edits` (everything, `queue`,
   `shadow_git`), `auto` (`approve_all`). Confirm with `/mode`, which reports posture *and* active
   layers. Never `/yolo` or `/mode +auto_approve`; `/mode !` resets to the floor. Note that
   `accept_edits`'s lighter is deliberately the empty string, so its prompt is byte-identical to one
   with no mode support at all — you cannot tell the posture by looking.
5. **Answering "always" writes durable state.** `Approval::Remembered` persists a pre-approval into
   `.lain/config.toml`. Check that file between acts; a non-empty approvals table is itself a
   finding about the gate, because every later act inherits it silently.

### Isolation: XDG is necessary and NOT sufficient

`Lain::Paths` resolves durable locations from an injected environment and `xdg_dir` appends `lain`,
so four exports redirect a **directly invoked** `lain` command:

```bash
QA=~/tmp/lain-qa-<date>
export XDG_CONFIG_HOME="$QA/xdg/config"   # -> $QA/xdg/config/lain
export XDG_STATE_HOME="$QA/xdg/state"     # -> $QA/xdg/state/lain/sessions/<project_hash>
export XDG_CACHE_HOME="$QA/xdg/cache"
export XDG_RUNTIME_DIR="$QA/xdg/runtime"  # -> $QA/xdg/runtime/lain   (nvim + lain-core sockets)
chmod 700 "$QA/xdg/runtime"
```

**That is not enough for the cockpit, which is most of this plan.** `lain up` runs in tmux panes,
and **tmux hands a pane the SERVER's environment, not the client's** — measured, and recorded in
`cli/up/pane_command.rb`'s own comment. `PANE_ENV` is an explicit allowlist of eleven names, all
`LAIN_*`: no `XDG_*`, no `HOME`, no `TMPDIR`. A pane on a pre-existing server reads them as **empty**,
and `Paths#present` treats a non-absolute value as unset, so it falls back to the real `~/.local/state`.
Session journals, Reline history, consent records and shadow-git snapshots all land in the
operator's real state. `lain up --socket` is unset by default, so the cockpit otherwise uses the
operator's own tmux server.

So the isolation recipe has three parts, and the second is not optional:

```bash
# 1. give the run its own tmux server, started FROM the exported shell.
#    A fresh server inherits the launching client's environment; a pre-existing one does not,
#    which is why the kill-server is part of the recipe rather than hygiene.
tmux -L lain-qa kill-server 2>/dev/null
lain up --socket lain-qa --session lain-qa <project>

# 2. VERIFY before Act 1 -- this rule applied to itself. Abort if any pane disagrees.
tmux -L lain-qa list-panes -a -F '#{pane_pid}' | while read p; do
  tr '\0' '\n' < /proc/$p/environ | grep -E '^(XDG_|TMPDIR)'
done
```

3. **The standing consequence: `PANE_ENV` forwards `LAIN_*` and nothing else.** Anything else the run
   depends on must be exported into the shell that *starts the tmux server*, and a variable changed
   mid-run does not reach a pane at all. This is why `LAIN_NUM_BATCH=2048` is the right lever for
   batch size rather than `--num-batch` — it is in `PANE_ENV` and survives.

Two more, both verified:

- `XDG_RUNTIME_DIR` relocates the **nvim and lain-core** sockets. It does **not** relocate the tmux
  server socket, which lives under `TMUX_TMPDIR` or `/tmp/tmux-<uid>` and ignores XDG entirely —
  `-L` is the lever there.
- Three sites read the real process `HOME` directly (`project/resolver.rb`, `exe/lain`,
  `cli/isolation_backend.rb`). None escapes a sandbox that is itself under `$HOME`. No constant
  anywhere captures `HOME`/`XDG_*`/`TMPDIR`/`Dir.pwd` at require time, so a late export is still
  seen.
- **Check `~/.lain` does not exist before Act 1.** A stray `~/.lain/state.json` makes every directory
  under `$HOME` resolve `$HOME` as the project root, which silently invalidates a sandbox living
  there. It is currently at `~/.lain.bak`.

### Record before you interpret

Per act, with literal spellings, because the premise of the section is reproducibility:

- **Session journal:** `$XDG_STATE_HOME/lain/sessions/<project_hash>/<UTC-timestamp>-<pid>.ndjson`.
  Compute the hash ahead of the act:
  `ruby -rdigest -e 'puts Digest::SHA256.hexdigest(File.realpath(ARGV[0]))[0,12]' <dir>`
  (kernel-resolved, so a symlinked sandbox names a different directory than the editor serves).
- **`.lain/state.json`**, and **`.lain/config.toml`** for the approval-persistence check.
- **`tmux -L lain-qa capture-pane -p -t <pane>` for BOTH panes** at the moment of a finding.
- **`ollama ps`** — residency is a precondition for Act 1's whole reading and is not recoverable
  after the fact.

---

## Driving the cockpit

The whole run goes through tmux and nvim, so these mechanics are part of the plan, not background.

- **`lain up` execs `tmux attach`** — it replaces the process. In a non-interactive shell it fails
  with "open terminal failed: not a terminal" *after* the session was already created, so the exit
  status is not the signal. Check `tmux -L lain-qa has-session -t lain-qa`.
- **Address the panes explicitly.** The cockpit is one window split into an nvim pane and a chat
  pane sharing one socket and one cwd:
  `tmux -L lain-qa list-panes -a -F '#{pane_id} #{pane_current_command}'`.
- **Typing at `you>` and gesturing in nvim are different things.**
  - Chat: `send-keys -t <chat> -l '<text>'` then `send-keys -t <chat> Enter`. **`-l` is required** —
    without it a leading `/` or `@`, and any `;`, are eaten by tmux's own key parser, and every
    skill invocation in this plan starts with one.
  - nvim: `<CR>` is `send-keys -t <nvim> Enter`; `x` is `send-keys -t <nvim> x` — a normal-mode
    command in that pane, a literal character in the other.
- **Read back** with `capture-pane -p`. **Readiness is polling that output for the `you>` prompt,
  never a fixed sleep.**

---

## The subject: bowling scoring

Small enough to finish; genuinely non-trivial. Strikes and spares look ahead one and two rolls, the
tenth frame breaks its own rule, and a perfect game is 300 rather than 30 x 10.

**Definition of done: five oracles pass, under a spec file the DRIVER writes**, not the model's own.
The model's specs are Act 7's subject, not the grading instrument — grading a model's work with the
model's own tests is the vacuity this whole chunk existed to prune.

| game | score |
|---|---|
| all gutters | 0 |
| perfect (12 strikes) | 300 |
| all spares, 5 first ball | 150 |
| `1,4 4,5 6,4 5,5 10 0,1 7,3 6,4 10 2,8,6` | **133** |
| nine open frames then `10,10,10` in the tenth | **30** for the tenth, not 60 |

**The first three are not sufficient and must not be used alone.** A scorer that adds the
next-two-rolls bonus to *every* frame — open frames included — scores 0, 300 and 150 correctly and
is wrong on every game containing an open frame. The fourth oracle is the one that catches it; the
fifth pins the tenth-frame rule specifically.

If the model cannot get there, **the trigger is mechanical**: three consecutive turns producing
neither a spec file nor a scorer file, or any single turn over ten minutes. Drop to a named simpler
fixture — FizzBuzz with a spec — rather than redesigning mid-run.

**A failure to produce a usable plan in Act 2 is a MODEL finding, not a lain finding.** Bowling is
well-represented in training data and a 3B-active MoE will likely manage the code; the harder ask is
pointing that model at `/create-plan` and `/execute-plan`, which are multi-step orchestration
scaffolds. If it cannot, hand-write a plan file and continue — the seams Acts 3–6 exist to test
still need driving.

---

## Act 0 — bring the bench up

`ollama` is not running by default, and **there are two installs on this box.** The one
`DEBUGGING_OLLAMA.md`'s 2026-07 fix block points at (`~/.local/opt/ollama`) uses `~/.ollama/models`,
which holds only `gemma4`, `nomic-embed-text` and `qwen3` — **not** the model this plan names.

```bash
. /mnt/nvme/opt/ollama-env.sh && ollama serve &
curl -s localhost:11434/api/tags | grep -q qwen3-coder:30b || abort
```

That env file sets `OLLAMA_CONTEXT_LENGTH=32768` — the number Act 1's occupancy expectation is
written against — and `OLLAMA_KEEP_ALIVE=5m`, which is what makes "cold" the default state after any
five-minute pause.

Also export `LAIN_NUM_BATCH=2048` into the server-starting shell. This box's own serving notes say
never to omit it: ollama passes `-b 512`, overriding llama.cpp's 2048, at up to 8× prefill on Vulkan
(with the 6.5×-vs-1.31× discrepancy recorded as unreconciled in `DEBUGGING_OLLAMA.md`).

**Model:** `qwen3-coder:30b` — the only coding-tuned model present, and a 30B MoE with 3B active, so
~2× decode and ~3.9× prefill against the dense `qwen3.8:27b`. `nemotron-3.5-lightning:30b` is ruled
out: 23.68 GiB against ~22.5 usable, reports `offloaded 54/54`, then **no log output for 40 minutes**.

---

## Act 1 — cold start, and the limitations we shipped knowingly

**This is two sessions, two journals, two `state.json` lifetimes.** Say which is which in the record.

Controlling residency: `ollama ps` reports it, `ollama run qwen3-coder:30b ""` makes it resident,
`ollama stop qwen3-coder:30b` evicts it, and `OLLAMA_KEEP_ALIVE=5m` self-evicts.

- **Cold** (nothing resident): expect the fallback denominator for the whole session. The book is
  resolved once at launch and memoized.
- **Warm** (resident first): expect prompt line, `state.json` and the journaled compaction decision
  to **agree** on the served window. *Disagreement between them is the real failure;* a uniformly
  wrong number is the known one.
- **Cold with `--num-ctx 32768`** — the case the previous draft missed, and the more interesting
  one. `--num-ctx` alone resolves a served window **with no server involved**, so this should give an
  honest denominator with nothing resident. It is the operator lever T9's card names and it is
  otherwise untested.
- **`--num-ctx 0`** must refuse by name, not backtrace.
- **`capability_degraded`:** count the lines in the session journal, expect **exactly one**, and
  expect **nothing on screen** — nothing renders it (follow-up #7), so a driver watching the display
  will otherwise file a false defect.
- **T11 on the wire:** launch once with `--num-batch 2048 --num-ctx 32768` and confirm the journal's
  request carries `options.num_batch` and `options.num_ctx`; launch once with neither and confirm
  **no `options` key at all**. That asymmetry is the card's own contract.

## Act 2 — `/create-plan`, and compaction at scale

Exercises context assembly, the summarizer tiers and skill dispatch. Watch for `UndecodableAnswer`
from the summarizer; whether the summarizer model stays the chat's (a fall to a small local model
evicts the resident one, measured at ~11×); and whether a declared summarizer is consulted for small
tool results.

**Declaring a summarizer has a step that is easy to miss and silently voids this act.** `/meta
summarizer …` writes `.lain/summarizers/<slug>.rb`, and **nothing loads that directory** — the
catalog's only path is the single file `.lain/summarizers.rb`. `/meta`'s own advice string says so.
Skip the copy and the free tier never fires, and T4 looks unfixed.

**Also here, moved out of Act 8:** fill the context until compaction fires for real. This is the only
step that drives the compaction path at scale, and it is not an infrastructure failure — it does not
belong behind the destructive probes.

## Act 3 — `/execute-plan`, and the wedge

The act that found the worst defect in round 1.

**Precondition:** Act 2 produced a plan document. Record where it landed and how this act names it.

- **The wedge needs the right grammar.** `Skill::Invocation` parses `/skill` as *inline* and
  `@role[/skill]` as a *fresh-context spawn*, and **only the second reproduces it.** Type literally
  `@researcher[/critique] <path>`. An inline `/execute-plan` does not exercise this.
  Expect the arrival note, a `human>` prompt, an answer taken, and a return to `you>`.
- A gated tool **inside** a spawn must reach the approval surface, and `/inbox` must still work.
- Child turns must be journaled and every `causal_parents` digest must resolve — then **fork the
  session**, which is what proves it.

## Act 4 — review the result

**Precondition:** files under `./lib` of the QA project, which only Act 3 can have produced. If Act 3
produced nothing, **seed a file by hand rather than skipping** — T14/T15/T19 are three of the nineteen
cards and this act is their only manual coverage.

`/survey ./lib` (a **subdirectory** survey specifically — the project-root case behaves differently
and is what hid the defect), then `<CR>`, then `x`, then approve. Then deliberately press `x` inside
the redraw window and confirm the stale-stamp refusal self-corrects on a second press.

## Act 5 — the bench

**Precondition: the chat is closed.** A second model on one GPU evicts the first, which is T12's
whole measurement (84.0s against 7.5s).

```bash
lain bench arms spec/fixtures/arms/tasks.yml --provider ollama --model qwen3-coder:30b
```

`--provider` defaults to the literal `"anthropic"` rather than through `EnvDefaults`, so `.envrc`'s
`LAIN_PROVIDER` does **not** reach it and the command refuses on a missing key. `--isolation` unset
is not `none`, and `--journal` without `--isolation` refuses.

**"Non-zero" is not a usable oracle** — the suite floor is already **0.0625**, because a task with
`contains:` + `excludes:` gold has its `excludes` half pass vacuously against an absent file
(follow-up #3), and a totally collapsed orchestrator arm still reads **1.000** on the grade row
because the grade is computed on the orchestrator's own timeline (follow-up #15). Use three
conjoined checks:

1. mean grade **materially above 0.0625**;
2. non-zero on at least one task **other than** `fix-off-by-one-loop`;
3. a **non-zero spend/token row for every arm** — the only row a collapsed arm cannot fake.

A 1.000 grade beside a collapsed spend row is follow-up #15 reproducing, not a pass.

Also confirm the dual-ledger arm settles on its ledger rather than its grader, and that its terminal
state distinguishes a dried-up ledger from a ceiling.

## Act 6 — record integrity

Every journal line parses; no `journal_error`; occupancy reconciles against `input_tokens` and the
served window; compaction decisions carry their denominator.

## Act 7 — `/critique` the output

Is the scorer correct against all five oracles? Are the model's own specs meaningful or vacuous?
Does the code read like something a person would keep? **The plumbing can work perfectly and still
produce something not worth having**, and only this act can tell.

## Act 8 — destructive probes, LAST

Held to the end so a broken machine cannot contaminate the main pass:

- Kill the model server mid-turn.
- `--api-base` at a black hole (expect the ~2 s probe timeout, then a clean refusal).
- **Ctrl-C during a parked `ask_human`** — known uncovered; signals are routed to a null handler
  outside an ordinary turn's ask, so either the process dies outright or the ask stays parked. Both
  are the documented gap; **the actual check is that the session journal still parses afterwards.**
- **A dangling causal edge, which no other act reaches.** Truncate a session journal after a
  `message` record whose `causal_parents` names a digest carried only by a later `turn` record, then
  `lain chat --fork <session>`: expect a refusal naming the session *and* the missing digest, exit
  non-zero, no backtrace. Then `--resume` the same session and expect the **raw** `Store::MissingObject`
  — follow-up #1, fixed for `--fork` only. Confirming it here means it is not later mistaken for new.
- A corrupted journal line.

---

## What this plan does NOT test

Worth stating, because "every defect behaves differently now" reads as coverage:

- **The plain, non-cockpit path.** Every act runs under `lain up --nvim`; the wedge is a REPL/stdin
  concern that exists on a bare `lain chat` too.
- **`--resume`**, except the one probe in Act 8.
- **The secret boundary** — `Sensitivity::Policy` and the two middlewares get zero manual coverage,
  despite CLAUDE.md calling the three-place split forced.
- **Isolation backends** — no act runs `--isolation worktree`, which is where the real-`git` seams
  live.
- **Cost and latency.** Nothing records wall-clock or tokens per act, so "the plumbing works" and
  "the plumbing is usable" are not separated. One wiring mistake in the last chunk cost 84.0s against
  7.5s, and nothing here would catch the same class again.

---

## What success means

Not "nothing went wrong."

Success is: **every defect the previous round found behaves differently now**, every knowingly-partial
fix fails the way its documentation says rather than some worse way, and every new defect is recorded
with a reproduction rather than a description.

A run that finds nothing new did not push hard enough. Round 1 found eleven defects behind a green
suite of ten thousand examples.
