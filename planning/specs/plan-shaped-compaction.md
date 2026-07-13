# Spec — Plan-shaped compaction

> Status: `[exp]`, specced 2026-07-13 (interview same day). Upgrades `cache-aware-compaction.md`'s
> "plan-step completion" from a *trigger* to a *schedule*: compaction seams are *plan content*,
> pre-committed where the plan already knows the work's shape. Companion to
> `cache-aware-compaction.md` (the reactive policy, which remains the fallback + safety net),
> `cache-economics.md` (CE-2 measures the churn; CE-4 supplies the fork machinery's economics),
> `orchestration-model.md` (OM-2 fork mechanics), `grader-from-gherkin.md` (per-step acceptance
> criteria feed closure records), and `oracles.md` (optional tiers for closure notes). Unit IDs
> `PC-<n>`.

## The idea

Reactive compaction has to guess what matters from an undifferentiated history. An implementation
plan already knows: step boundaries are semantic seams where intra-step churn (exploration, failed
attempts, tool noise) stops mattering and only the outcome carries forward. So:

1. **Seams are declared in the plan**, ahead of execution, where the author can see and question
   them.
2. **Work-per-chunk is estimated in the plan**, which turns compact/don't-compact into a
   computable expected-value decision: a rewrite costs one cache write of the new shorter prefix;
   it pays back as (tokens removed) × (turns remaining in the chunk that would have re-read them).
   The second factor is exactly what a plan estimates and reactive compaction can never know.
3. **The execution shape at a seam is a policy, not a doctrine** (interview decision): different
   shapes win in different use cases, so the shapes are swappable and the bench proves out the
   orchestration style rather than asserting it.

## Seams are plan content (interview: explicit, author-editable)

A seam is an explicit marker in the plan artifact — proposed by the planner by default, but
**materialized in the plan so the author can question it**: insert one where the planner missed a
boundary, or *remove* one where consecutive steps are strongly related and share working context
(the author's judgment that step N+1 needs step N's churn, not just its closure). This rides the
plan-iteration review loop (M4 fold-in: plans as templates with annotation slots, diff-driven
review) — a seam is exactly the kind of thing a reviewer strikes out.

Each chunk (the span between seams) carries a **size annotation** (S/M/L or estimated turns).
Estimation source (interview decision): **author/planner annotations first, Journal-calibrated
later** — once the Journal accumulates measured tokens-and-turns per completed chunk, the
calibration replaces guesswork with data (annotated-S chunks measured at a median of N turns, …),
and drift between annotation and measurement is itself a journaled, reportable signal.

## Execution shapes at a seam (interview: swappable, all testable)

| Shape | Mechanism | Cache profile | Wins when |
|---|---|---|---|
| **linear + rewrite** | one timeline; at the seam, `Compact` rewrites the closed chunk into its closure record | one message-tier rewrite per seam; prefix shrinks | chunks share lots of live context; simplicity |
| **fork-per-step** | mainline holds plan + closure records only; each chunk executes in a fork inheriting the mainline prefix; fork dies at the seam, closure record **appends** to mainline | mainline is never rewritten — appends don't invalidate; each fork reads the mainline at ~0.1× | chunks are independent; long plans (mainline stays small forever) |
| **hybrids / variations** | e.g. fork-per-step but fold selected artifacts (not just the record) back; or linear with rewrite only at every k-th seam | between the two | to be found on the bench |

The shape is a **policy object selected per plan (possibly per seam)** — the same posture as
CE-4's spawn prefix strategies, and fork-per-step *is* CE-4's fork-worker applied sequentially to
one agent's own plan. `Timeline#fork` being O(1) and `Context#render` purity make every shape
cheap to implement and byte-reproducible to compare.

## Step-closure records

The unit of "what survives the seam" — typed, content-addressed, and **mostly deterministic**
(no API cost, no LLM latency for the bulk of it):

| Field | Source |
|---|---|
| step id, title, status | the plan |
| acceptance criteria + pass/fail | grader-from-gherkin (GG) per-step graders |
| files touched, diff digests | Workspace Timeline / tool metadata |
| test results | tool results (deterministic extraction) |
| elided-span digests | the chunk's turns remain in the Store; the record points at them (attested — nothing is lost, only un-rendered) |
| `notes_for_future_steps` (optional, small) | the only field that may need a model; tierable per `oracles.md` (heuristic: empty · ollama · haiku · inline) |

Because the record is derived from content-addressed sources, the compaction is **attestable**:
every claim in the record traces to a digest, and the attested-context grader can verify it. An
LLM summary of the whole chunk (the classic compactor) becomes the *comparison arm*, not the
default.

**Monotonicity rule** (inherited from the deterministic-condensers discussion): seam decisions are
frozen at the seam — a closed chunk's rendering never changes retroactively, so the prefix bytes
of closed chunks are stable regardless of what later steps do. This is what makes seam density
cheap: more seams never means more churn, only more (small) records.

## Failure and backtrack

A failed step still closes: the record carries `status: failed` + the error evidence digests —
that is *more* valuable to future steps than the churn was (cf. DCP's purge-failed-keep-error, at
plan granularity). Reopening a chunk (the plan was wrong, step N must be redone) is a **new fork
from the mainline** whose closure record supersedes the old one by reference — never a rewrite of
the closed record. In linear shape, reopening forces a reactive-compaction-style rewrite; journal
it as such (this asymmetry is itself a bench observable favoring fork-per-step under churny plans).

## Units

- **PC-1 — Seams + size annotations in the plan artifact.** Planner proposes a seam per step by
  default; the artifact materializes them; the author inserts/removes in review. *Needs:* the plan
  artifact (M4 plan-iteration fold-in); GG-1 for step structure. **Acceptance:** a plan renders
  with visible seams + sizes; removing a seam merges chunks; the executed schedule matches the
  reviewed plan exactly.
- **PC-2 — Step-closure records.** Typed, content-addressed, derived per the table above;
  `notes_for_future_steps` tierable via OR-1. *Needs:* Workspace/tool metadata; GG per-step
  graders; Store. **Acceptance:** a record is produced at each seam with zero LLM calls in the
  deterministic tier; every field traces to a digest; the attested-context grader verifies one.
- **PC-3 — Execution shape as a policy.** `linear+rewrite` and `fork-per-step` behind one seam-
  handling interface, selected per plan; hybrids expressible. *Needs:* `Timeline#fork` (built),
  `Compact` (3c-2.3), OM-2 mechanics. **Acceptance:** the same plan executes under both shapes;
  mainline digests under fork-per-step show zero rewrites (CE-2 chain flat except appends);
  switching shape requires no plan change.
- **PC-4 — The seam EV decision.** At each seam, compute rewrite-cost vs. estimated payback from
  the chunk annotation (calibrated by Journal history when available); the linear shape uses it to
  decide rewrite-now vs. defer-to-next-seam; fork shape uses it to validate seam density.
  *Needs:* PC-1, CAC-2 (provider cache profile), CE-6 (prices). **Acceptance:** the decision and
  its inputs are journaled; a deliberately mis-sized annotation produces a visible
  estimate-vs-actual delta in the report.
- **PC-5 — Journal calibration.** Measured turns/tokens per completed chunk accumulate per size
  class; estimates are reported against actuals; calibration feeds PC-4. *Needs:* PC-2, M2
  Journal, `Agent::Accounting`. **Acceptance:** after N sessions the report shows per-class
  distributions; PC-4 consumes the calibrated figure when present.
- **PC-6 — The shape × density sweep.** One fixed multi-step plan; shapes (linear / fork / hybrid)
  × seam densities (every step / author-thinned / none = reactive baseline), scored
  grader × tokens × cache-write × wall-clock. *Needs:* PC-1..4, CE-2, `Compare`.
  **Acceptance:** a `Compare` report answers "which shape, at which density, for this task class"
  as distributions; the reactive baseline (no seams, `cache-aware-compaction.md` alone) is an arm.
- **PC-7 — Eager unit summaries (interview addition, 2026-07-13).** As each large tool result
  lands, fire an **ollama one-shot concurrently with the main workflow** (an oracle call on its
  own fiber — the main loop never waits) to summarize it; hold the summary as a content-addressed
  artifact **keyed by the source result's digest**. Unit-level keying is the load-bearing choice:
  the source is immutable, so a unit summary *never goes stale* (unlike CAC-5's head-digest-keyed
  whole-history hold, which invalidates on every new turn). At the seam, compaction assembles
  held summaries + the deterministic record fields — no big blocking summarization call, no
  1-minute stall. Originals stay in the Store untouched (double-checking is free: the summary
  artifact carries its source digest, so the attested-context grader can verify any summary
  against its source). Prompt bytes change **only at the seam** when summaries are applied —
  eager preparation has zero cache impact. Default tier is **local-only** (speculative work that
  may never be needed is acceptable when it's free and PHI-safe; a haiku eager tier costs real
  money per maybe-unused summary — a swept choice, not a default). Oracle rules apply: journaled
  Q&A (OR-2), replay substitutes recorded summaries. *Needs:* OR-1/OR-2, M3b ollama arm, OM-0
  (fibers). **Acceptance:** a large tool result triggers exactly one background summarization
  keyed by its digest; repeated renders reuse it; seam-time compaction with all units held makes
  zero LLM calls; the main loop's turn latency is unchanged with eager summarization on vs off.

## Relationship to other work

- **`cache-aware-compaction.md`** — remains the *reactive* layer: between seams, the hard-cap
  safety net still forces compaction if a chunk blows past the window (mis-estimated chunks
  happen); prepare-once-apply-on-resume applies to seam work too. CAC-1's plan-step *trigger* is
  subsumed by PC-1's *schedule* when a plan exists; CAC stands alone when none does.
- **`cache-economics.md`** — CE-2's digest chain is how PC-3/PC-6 *prove* the zero-churn claim;
  CE-4 supplies the fork economics; CE-6 prices the EV decision.
- **`oracles.md`** — only `notes_for_future_steps`, plan-time size estimation, and PC-7's eager
  unit summaries touch a model; all are tiered oracle questions with heuristic floors, and PC-7
  defaults to the local tier.
- **`grader-from-gherkin.md`** — per-step acceptance criteria are both the closure record's spine
  and the per-chunk grader for PC-6.

## Open questions

- **Per-plan or per-seam shape?** Selecting the shape per seam (fork this independent chunk,
  stay linear through these coupled ones) is strictly more expressive and the author already
  edits seams — but it multiplies the policy surface. Start per-plan; promote if the sweep shows
  mixed plans want it.
- **What does the fork see?** Fork-per-step inherits the mainline (plan + records). Does it also
  get the *previous* chunk's fork tail (warm continuation) or only its record (clean room)? Likely
  the author's seam-removal answers this — a removed seam = shared context — but the default
  needs picking.
- **Mainline growth bound.** Closure records are small but not zero; a 200-step plan's mainline
  still grows. Records-of-records (a chapter seam) is the natural recursion — defer until a real
  plan hits it.
- **Estimation units.** S/M/L classes vs. raw turn counts: classes are easier to author and
  calibrate, turns are what the EV formula wants. Leaning classes-with-calibrated-medians.
