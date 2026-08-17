# Manual end-to-end QA — the recurring bench run

A living document. Round 1 (2026-08-15) produced eleven defects, all of them green in the suite,
and became `specs/chunk-poc-integration-fixes.md`. This is the procedure that found them, written
down so the next round starts from a method rather than from memory.

**The premise: every defect this has found so far lived in a seam that had specs on both sides.**
A manual run is not a slower unit test. It is the only thing that drives two real components
against each other with a human in the middle, and that is where this codebase's defects live.

---

## Standing rules

### The approval gate is the point, not the paperwork

A local model requests tool calls on a real machine. Whoever drives is the gate, and the gate is
only worth having if it is read rather than skimmed:

1. **Read every command for what it would do if a path resolved somewhere unexpected**, not for
   whether it contains a scary word. `rm -rf $DIR` is fine; `rm -rf $DIR/` where `$DIR` might be
   empty is not.
2. **Refuse anything reaching outside the sandbox** — `$HOME`, `~/.config`, `~/.ssh`, `/etc`, git
   history, another checkout. Record the refusal; a model that asks is a finding.
3. **A convincing rationale for a destructive command is a worse sign, not a better one.**
4. **No blanket pre-approval, no `--dangerously-*`.** If a posture makes the run unworkable, that
   is the finding. The point is to learn what the gate feels like.

### Isolate through XDG, not through hope

`Lain::Paths` resolves every durable location from an **injected environment**, and `xdg_dir`
appends `lain` to each. So four exports give a completely separate lain installation, with nothing
shared with the operator's real config or state:

```bash
QA=~/tmp/lain-qa-<date>
export XDG_CONFIG_HOME="$QA/xdg/config"   # -> $QA/xdg/config/lain
export XDG_STATE_HOME="$QA/xdg/state"     # -> $QA/xdg/state/lain/sessions/<project_hash>
export XDG_CACHE_HOME="$QA/xdg/cache"
export XDG_RUNTIME_DIR="$QA/xdg/runtime"  # -> $QA/xdg/runtime/lain  (sockets)
```

This is better than a throwaway directory alone, for three reasons: the operator's real state
cannot be read *or* written; the whole configuration is inspectable in one tree afterwards; and
session journals land somewhere obvious instead of under `~/.local/state`.

Two things to know. `Paths#home` also reads the injected `HOME`, so a run can go further and
substitute that too — heavier, and only worth it when testing the secret boundary, which
classifies against home. And `project_hash` is `sha256(realpath)[0,12]`, kernel-resolved, so a
symlinked sandbox path names a different session directory than the editor serves.

### Configure explicitly, so the run is reproducible

A project's `.lain/` may carry `config.toml`, `summarizers.rb` and `state.json`; `prompt.toml`,
`slots/`, `skills/`, `epics/` and `meta/` are resolved by their own owners. Write the config the
run intends rather than inheriting whatever is lying around — and **declare a summarizer**, which
is the one user-extensible hook on the turn path and therefore worth exercising deliberately.
(`services.rb` is isolation backends — docker compose, pg, redis — not request middleware.)

### Record before you interpret

Per act: the session journal path, `.lain/state.json`, the timeline head. A finding without a
reproduction is an anecdote.

---

## The subject: bowling scoring

Small enough to finish; genuinely non-trivial. Strikes and spares look ahead one and two rolls, the
tenth frame breaks its own rule, and a perfect game is 300 rather than 30 x 10. It has a real
red-green-refactor shape, a natural rspec surface, and an output a human can **judge** — so
`/critique` has something to bite on.

A hello-world gem tests the plumbing. This tests whether the plumbing produces work worth having,
which is the harder and more useful question for a study bench.

If the model cannot get there in a few honest attempts, drop to a simpler fixture rather than
abandoning the run: the orchestration flow is the subject under test, and a model that cannot solve
bowling still exercises every seam.

---

## Model selection

Pick for capability at the task first, throughput second, and **read `DEBUGGING_OLLAMA.md` before
choosing** — it records which local models fail badly rather than cleanly. As of 2026-08-17 that
rules out `nemotron-3.5-lightning:30b`, which does not fit and hangs silently for 40 minutes.

`qwen3-coder:30b` is the standing choice: the only coding-tuned option locally, and a 30B MoE with
3B active, so it decodes roughly 2x and prefills roughly 4x faster than the dense 27B alternative.

---

## The acts

Ordered so that what is already known is confirmed early and cheaply, leaving time for what is not.

### Act 1 — cold start, and the limitations we shipped knowingly

Confirm the **documented** failure shape before hunting new ones. Three things are known partial:

- **Occupancy is honest only once a runner is resident.** Launch cold and expect the fallback
  denominator for the whole session; launch warm and expect all three surfaces — prompt line,
  `state.json`, journaled compaction decision — to agree on the served window. *Disagreement between
  them is the real failure;* a uniformly wrong number is the known one.
- **A mark pressed inside the redraw window is refused**, with a sentence that reads as though the
  file was never opened. Pressing again works.
- **`--compact-strategy=summarizing` cannot reach the free tier at all.**

Also: `capability_degraded` should appear **once per session**, not once per turn and not never.

### Act 2 — `/create-plan`

Exercises context assembly, compaction, the summarizer tiers and skill dispatch. Watch for
`UndecodableAnswer` from the summarizer, whether the summarizer model stays the chat's (a fall to a
small local model evicts the resident one and costs ~11x), and whether a declared summarizer is
consulted for small tool results.

### Act 3 — `/execute-plan`

The act that found the worst defect in round 1.

- A `@role[/skill]` line whose subagent calls `ask_human` must print the arrival note, take an
  answer, and return to the prompt. Round 1: it hung silently.
- A gated tool **inside** a spawn must reach the approval surface, and `/inbox` must still work.
- Child turns must be journaled and every `causal_parents` digest must resolve — then **fork the
  session**, which is what proves it.

### Act 4 — review the result

`/survey ./lib`, `<CR>`, `x`, approve. Round 1 failed at the first gesture. Test a subdirectory
survey specifically — the project-root case behaves differently and hid the defect.

### Act 5 — the bench

`lain bench arms` with **no** `--system` must score non-zero. Confirm the dual-ledger arm settles on
its ledger rather than its grader, and that its terminal state distinguishes a dried-up ledger from
a ceiling.

### Act 6 — record integrity

Every journal line parses; no `journal_error`; occupancy reconciles against `input_tokens` and the
served window; compaction decisions carry their denominator.

### Act 7 — `/critique` the output

Is the scorer correct — perfect game 300, all-spares-with-a-5 150, gutter game 0? Are the specs
meaningful or vacuous? Does the code read like something a person would keep? **The plumbing can
work perfectly and still produce something not worth having**, and only this act can tell.

### Act 8 — infrastructure failures, LAST

Held to the end deliberately, so a broken machine cannot contaminate the main pass: kill the model
server mid-turn; point `--api-base` at a black hole; Ctrl-C during a parked `ask_human` (**known
uncovered** — signals are routed only around an ordinary turn's ask); corrupt a journal line; fill
the context until compaction fires for real.

---

## What success means

Not "nothing went wrong."

Success is: **every defect the previous round found behaves differently now**, every knowingly-partial
fix fails the way its documentation says rather than some worse way, and every new defect is recorded
with a reproduction rather than a description.

A run that finds nothing new did not push hard enough. Round 1 found eleven defects behind a green
suite of ten thousand examples.
