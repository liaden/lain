# `planning/qa/` — the manual QA bench

**Manual QA is not a slower unit test.** It is the only thing that drives two real components
against each other with a human at the approval gate, and every defect it has found so far lived
in a seam that had specs on **both** sides. Round 1 found eleven behind a green suite of ten
thousand examples; round 4 found seven more, two of them session-killers.

These documents are the **inputs to the `manual-qa` skill** (`.claude/skills/manual-qa/`). The skill
owns the procedure and the driver scripts; these own the method and the scenarios.

## Layout

| Doc | What it is |
|---|---|
| [`method.md`](method.md) | **The standing method.** Toolchain, sandbox isolation (and why XDG alone is not enough), the approval-gate discipline, driving the cockpit, the journal-quiet rule, driving nvim over RPC, what to record, and the local model's known failure modes. Scenario-independent; read once per round. |
| [`bench.md`](bench.md) | Bringing up the model server: which of the two ollama installs, the residency controls, `n_slots`/`OLLAMA_NUM_PARALLEL` as a recorded precondition, and why `--num-ctx` alignment avoids a 27s reload. |
| [`oracles/bowling.rb`](oracles/bowling.rb) | The driver's grading instrument for the bowling subject. Grades `Bowling.score(rolls)`. Never the model's own specs. |

## Scenarios

Pick by the question being asked, not by coverage. Each states its own cost and preconditions.

| Scenario | The question it answers | Cost |
|---|---|---|
| [`session-and-window.md`](scenarios/session-and-window.md) | Is the bench **honest before a model is asked** — served window, `provenance`, occupancy, the launch-level refusals, the `options` asymmetry, **which prices it will quote and which collapse strategy it resolved**? Mostly needs no model call. | cheap |
| [`rust-cli.md`](scenarios/rust-cli.md) | Does the loop work **end to end**, on a non-Ruby toolchain, with a real compile-error unhappy path? The smoke test. | cheap |
| [`cockpit-surfaces.md`](scenarios/cockpit-surfaces.md) | Do the nvim/tmux surfaces tell the truth — review flow, buffer staleness, the approval surfaces and the notifier that shares their queue, the live timeline, how a refusal is *delivered*? **Four of round 4's seven defects were here, and every fix landed somewhere other than where the symptom was.** | cheap, piggybacks |
| [`failure-injection.md`](scenarios/failure-injection.md) | Is the record **unforgeable**, does every failure path refuse by name, and do the **tool bounds, the windowed-read contract and the summarizer's ceilings** hold? The deterministic half needs no model at all. The standalone regression gate. | minutes |
| [`bowling-ruby.md`](scenarios/bowling-ruby.md) | Does the **authoring loop** produce something worth having — plan, execute, critique, graded against driver-owned oracles? | 1–3 sessions |
| [`bench-arms.md`](scenarios/bench-arms.md) | Does the arm driver produce numbers that are not artifacts, **say what produced them, and refuse a price it cannot stand behind**? | ~5 min |
| [`rails-blog.md`](scenarios/rails-blog.md) | **Context economics at scale** — the composed compaction strategy firing for real, unbounded tool output, the gate under volume, and what a broken cache cost in dollars. The only scenario that reaches any of these. | expensive |

**A suggested full round:** `session-and-window` → `rust-cli` → one subject (`bowling-ruby` or
`rails-blog`) with `cockpit-surfaces` piggybacked → `bench-arms` → `failure-injection`.

**A suggested regression gate after a chunk lands:** `failure-injection` + `session-and-window`.
Both are cheap, deterministic, and cover the paths most chunks touch. As of 2026-08-18 that pair
also covers **most of a chunk that was mostly not about the cockpit at all** — the price table and
its lint, `--compact-strategy` resolution, both tool-bound shapes, the `edit_file` refusal
vocabulary, the summarizer's ceilings, the per-ask iteration ceiling and the `lain up`
crash-on-start case. That is deliberate: **a check that only runs in an expensive scenario mostly
does not run**, so anything deterministic belongs in the cheap pair even when the feature it guards
is expensive.

The corollary is the one thing the pair cannot do: **nothing deterministic can tell you a
compaction strategy works**, because a compaction needs volume that a cheap scenario cannot
manufacture. `rails-blog.md` §0 is the only place that act lives, and it carries a precondition
(tool results of real size) without which it silently measures nothing while paying for a model
call per turn.

## Findings

Written per round, kept in `planning/` alongside the chunk specs that discharge them:

- [`../qa-findings-round4-2026-08-18.md`](../qa-findings-round4-2026-08-18.md) — round 4
- [`../qa-findings-round2-2026-08-18.md`](../qa-findings-round2-2026-08-18.md) — rounds 2–3
- [`../qa-findings-research-2026-08.md`](../qa-findings-research-2026-08.md) — the research pass

## The two rules that outrank everything else here

1. **Success is not "nothing went wrong."** It is: every defect the previous round found behaves
   *differently* now, every knowingly-partial fix fails the way its documentation says rather than
   some worse way, and every new defect is recorded with a **reproduction** rather than a
   description. **A round that finds nothing new did not push hard enough.**
2. **A fix can make the failure mode worse.** *Differently* is not the same as *better* — record
   which. One round turned a >400s silent hang into a hard crash of the whole session.

## Known gaps — what no scenario covers

Worth stating plainly, because "every defect behaves differently now" reads as coverage:

- **The plain, non-cockpit path.** Almost every scenario runs under `lain up --nvim`. The REPL/stdin
  concerns exist on a bare `lain chat` too — and round 4 found that the approval surface is *worse*
  there, with no `:LainApprove` to recover through. `cockpit-surfaces.md` §5 now forces one
  `--no-nvim` comparison; nothing else does.
- **`--resume`**, except the one probe in `failure-injection.md`.
- **The secret boundary** — `Sensitivity::Policy` and the two middlewares get zero manual coverage,
  despite CLAUDE.md calling the three-place split forced. This is the largest untested surface here.
- **Isolation backends** — no scenario runs `--isolation worktree`, which is where the real-`git`
  seams live. `rails-blog.md` is the natural host if one is written.
- **Cost and latency.** Nothing records wall-clock or tokens per act, so "the plumbing works" and
  "the plumbing is usable" are not separated. One wiring mistake once cost 84.0s against 7.5s and
  nothing here would catch the same class again.
- **Compaction at scale** — reachable only from `rails-blog.md`, and not yet reached by any round.
  The obstacle that stopped rounds 3 and 4 (a per-session iteration ceiling) is gone since T14, so
  what remains is only volume and patience. Until a round actually reaches it, **every claim about
  the two content-selective strategies rests on specs alone**, and `--compact-strategy` is checked
  no further than name resolution.
- **A tripped tool bound leaves no journal record.** The bounds are checkable, but only through the
  `tool_result` text — so nothing here can answer "did a bound fire during ordinary use", which is
  the question that would say whether a ceiling is set too low.
