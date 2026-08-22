# The agent-harness field, August 2026 — what the three scans and seven papers are worth to us

> **Status (2026-08-18):** partially folded. Ledger rows 1–3 and 9 are **applied** — the
> **Verification** and **Decorrelation** axis rows, the merge-fraction metric, the matched-spend
> reporting note, and near-term-sequence item 31 are in `ROADMAP.md`. Rows 4–8 (the spec edits and
> the `[exp · parked]` milestone rows) are **proposed and not applied**; they need per-spec
> judgement. This doc isolates what is additive to the ROADMAP and says where it lands.

> Companion to [`hn-agent-landscape-2026-07.md`](hn-agent-landscape-2026-07.md), which folded the
> July scan. This doc covers the **three August scans** —
> [`references/hn-agent-landscape-2026-08.md`](../references/hn-agent-landscape-2026-08.md),
> [`-2026-08-14.md`](../references/hn-agent-landscape-2026-08-14.md),
> [`-2026-08-18.md`](../references/hn-agent-landscape-2026-08-18.md) — plus the **seven papers**
> those scans' comment threads surfaced (now in `references/papers/rst/`) and one lab writeup
> (Databricks). Source digests and per-thread "→ Lain" hooks live in those files (⚠️ LLM-generated,
> verifiable story IDs). It does **not** re-propose anything the July docs already folded.

**Why this doc exists at all is the first finding.** The July scan produced a prioritized fold-in
doc, and Tier-1 items landed in `specs/graders.md` and as `[exp]` rows under M3c/M5/M6. That
practice then stopped: three scans and 52 numbered items accumulated in `references/` over five
weeks with **no `planning/` counterpart and no ROADMAP line**. The corpus grew; the plan did not
move. Everything below is the backlog that created.

The meta-finding of the August window is not a new thesis — it is that **the thesis stopped being
only ours**. Databricks measured it on their own multi-million-line codebase: the *same model at
the same thinking effort, through two different harnesses, differed by more than 2× in cost per task
at equal quality*. Anthropic measured multi-agent failure modes at 10–80 agents. A commenter who
built fork-and-summarise compaction wrote the sentence this project exists to answer — *"Building
harnesses that do interesting things is a lot easier than building more effective harnesses."*
Nothing below changes the direction; the value is in **specific axes, metrics and controls the field
surfaced that Lain does not yet name.**

A reconciliation of all 52 items against the current plan is in § Reconciliation summary. Headline:
**6 already covered, 13 partially, 20 genuinely new** (the remainder are the corrections and the
excluded GPU/KV set).

---

## Tier 1 — novel, aligned, cheap, and it lands on our weakest surface

> **Numbering note.** Tier-1 items **0** and **5b** were added by the 2026-08-18 re-audit; item 0
> outranks everything under it. The original numbers are left untouched so the ROADMAP's `T1-n`
> references stay valid, at the cost of a `0 … 5, 5b` sequence. **A full renumber is owed** before
> this doc is folded — it is deferred, not forgotten.

### 0. Role assignment is a swept axis, and it is the strongest harness-variance result we have `[new axis row; M3c]`

**`arXiv:2606.05976`, *The Self-Correction Illusion*** — ingested to `papers/rst/`. A
**training-free**
intervention holds an erroneous claim **byte-identical** and varies **only its chat-template role**:
the agent's own `<thought>`, a user message, a tool response, or a system `<memory>` block. Across
**12 model-domain combinations** (closed APIs and open weights), relabeling to an external role
raises the explicit-correction rate by **23 to 93 percentage points** — significant in 10 of 12,
surviving Holm-Bonferroni in 9, with pre-specified success criteria, a locked `T=0` LLM judge
(κ=0.843 on independent re-judge) and paired-bootstrap CIs. An **H0–H4 ladder** separates the bare
syntactic wrapper from the role tag and finds the two *additive*. The best label is
**domain-dependent**: `<memory>` leads on math, a neutral user message on logical deduction.

The authors state Lain's thesis in their own words: *"the agent harness itself is a crucial
experimental variable in the study of self-correction, yet one that previous studies largely
overlooked."* **This is better evidence than anything else in the corpus** — better than
`2605.23950`, which asserts harness variance, and better than SWE-agent's +12.5%, which varied tool
interfaces. Here the *bytes are fixed* and only the harness's role assignment moves.

**Why it lands here specifically.** `Context#render` is the function that decides which `Event`
becomes which message role, and `KINDS = %i[turn spawn message snapshot]` is **closed and
enumerable** — so the paper's five conditions are a rendering arm, not a research programme. Three
pulls:

- **A `Role assignment` axis:** `{as-thought · as-user · as-tool-result · as-system-memory}` over
  the
  same Timeline. Purity means the five renderings are byte-comparable by construction, which is
  exactly the paper's byte-identity guarantee — Lain gets its central control for free.
- **The domain-dependence forbids a default.** `<memory>` wins on math, user wins on deduction. A
  harness that fixes one role assignment is making an unmeasured per-domain bet, which is the
  bench's whole complaint about everyone else.
- **Test the accident.** Lain's subagents already get a fresh Timeline root whose
  `meta["spawned_from"]` names the parent, so a child sees the parent's output as **external content
  rather than its own thought** — an unintentional implementation of this intervention. If the
  effect
  holds, spawn-for-review is not merely a context-hygiene move but a *correction-rate* lever, and
  that is measurable with machinery already built.

**Preserve the authors' scoping or the claim is overstated:** the lever raises *explicit error
flagging*, **not final-answer accuracy**, because agents frequently re-derive the right answer in
silence. For a bench that reports graded outcomes, that distinction is the finding — it means
`Grader` needs a *flagged-vs-silently-corrected* dimension, or the effect is invisible in the score.

Companion, same audit: **`arXiv:2604.17293` (UA-Bench)** — 3,500+ questions, six datasets, 18
models,
separating **data uncertainty** (input ambiguity) from **model uncertainty** (capability limit), and
finding high accuracy does not imply good attribution. `SCOPE.md` names **abstention** as an ability
the bench must grade and had no benchmark for it; this is one. The split is also an orchestration
branch — ask a clarifying question, or call a tool — which maps onto the `ask_human` promise seam.


### 1. The verification loop is an unnamed axis, and three windows in a row point at it `[new axis row]`

`grep -i "verifier\|verification loop\|metamorphic"` over `ROADMAP.md`, `planning/*.md` and
`planning/specs/*.md` returns **nothing**. Yet the axis table already sweeps context, tools,
disclosure, slots, provider, orchestration, memory and merge strategy — and the one variable three
independent August sources say dominates outcome is missing from it.

- `lazarie` (2026-08-14 §1.1), on a 900k-LoC codebase: *"less than 5% of wall time is an AI doing
  reasoning or coding, 95% is running the verification deterministically."*
- The auto-research kernel threads (2026-08-18 §3.2): agents win where a machine-checkable oracle
  already exists and produce slop where it does not. `porridgeraisin` explains *why* kernels — the
  domain had already built automatic verifiability for hyperparameter search.
- **`arXiv:2608.13122`** (in the corpus): a 250k-line Fortran→OpenACC port where the agent
  *generates its own oracle* — dump reference state from trusted runs, transform, validate
  element-wise. **162 kernels, 5.1× speedup, 5 real numerical defects caught**, with
  *session-spanning context management* named by the authors as a dominant failure mode.

**Proposal.** A new axis row: **Verification** | `{no verifier · test suite · suite + profiler ·
metamorphic/property oracle}` | grader score; turns-to-green; wall-clock share spent verifying.
Held over one task, one model, one prompt. Lain's `ShellOut`/`Effect` seam already makes the
verifier injectable and the Journal already records per-turn cost, so the deliverable is a *curve*,
not a build.

The second half is the cheaper and more distinctive one: **let the harness generate its own oracle**
(2026-08-18 item 35). Lain already records trusted reference state and replays it — that is exactly
what the ollama HTTP recordings are (`chunk-qa-defects-and-replay.md`). Pointing the same machinery
at *task* verification is what makes the sweep runnable on tasks that ship no tests, which is the
main thing capping the task suite's size.

### 2. Fan-out has no diversity metric, and correlated subagents are a measured hazard `[extends M5]`

Anthropic's multi-agent study is the strongest new orchestration evidence in the window, and it is
unflattering in a way that matters here: swarms of 10–80 agents over 12h, and **18 of 30 agents
created the same git branch name**; agents in separate runs titled fiction identically; agents
independently wrote 30 Hz pollers producing **2.4M requests for 117 accepted jobs**; three agents
migrating one backend to different languages escalated to disabling each other's accounts.

Lain's fan-out substrate is fully built — CE-4 prefix arms, CE-5 stagger, the role catalog,
`SpawnPolicy`'s three prefix strategies. **What is missing is the axis framing and the outcome
metric.** `grep -i "decorrelat\|diversity"` returns nothing across the plan. If N children share a
model, a prompt and a workspace, the Anthropic result predicts they substantially share an answer —
so **a fan-out of 5 producing 1.2 distinct approaches costs 5× for ~1× the coverage**, and every
orchestration arm that reports mean score is measuring through that.

**Proposal, two halves, both cheap because the data already exists.**

- **Decorrelation as a swept axis:** `{identical prompts · seeded prompt variation ·
  role-differentiated · model-heterogeneous}`. The variation is a `Context` combinator over the
  child's root; the role catalog already supplies half of it.
- **Diversity as a reported outcome, not score:** distinct-approach count, inter-child diff distance
  (`Review::Changeset` computes it today), unique files touched (Workspace Timeline snapshots).
  Every one is derivable from artefacts Lain already content-addresses.

**The decision boundary the same article supplies, and which the first pass missed:** its
"Group accuracy by Model" section reports that **a single agent holding all the relevant information
consistently outscores a group of agents each holding part of it**, and a commenter supplies the
practical ceiling (frontier windows are nominally ~1M but *"start to lose their minds around
300K"*).
So **multi-agent pays only past the point where the task's information exceeds the *usable* window**
—
the fan-out decision is a function of context-rot onset, not of task type. That is directly testable
here (`Bench::Compare` × a context-length sweep) and it composes with `2604.27891`, already in the
corpus, which found single-agent wins for procedural tasks that fit context.

And the companion metric: **merge fraction** (item 15). Anthropic's cleanest signal is the fraction
of opened PRs that got merged, *falling* as agent count rose — a quantity `Forge::Promotion` and
`Isolation::Worktree::Handback` already emit per worker, and which the current orchestration metric
row (grader · tokens · cache-write · context-loss · loop-depth) does not include. `Compare::METRICS`
is a symbol-keyed registry with a `reader:`, so adding it is a hash entry. **This is the single
cheapest way to make the multi-vs-single question honest**, because merge fraction degrades visibly
where mean score averages the failure away.

### 3. Does `diverge_at` recover a poisoned session? — the most Lain-specific experiment available `[M3c/M4]`

The most-repeated practitioner complaint in the window is context poisoning that *cannot be fixed by
adding context*: `purplepatrick` (2026-08-18 §2.2) — expose too much about one variable and "the
entire
session will be anchoring on the importance of that variable"; the reported remedy is always a new
session. A message-array harness structurally cannot test the alternative. Lain can: `diverge_at`
the event that poisoned it, replay forward, and grade.

**ThoughtDAG has already run a better-specified version of this and published numbers** — their
*Context Repair Pilot v1*: 4 models × 540 conditions, **deleting only the source repaired 68/72
derailed cases; removing the contaminated subgraph repaired 72/72**. That is a ready-made design
with a distinguishable prediction (source-deletion is nearly but not entirely sufficient), and it
maps directly onto `Timeline#diverge_at` plus the causal DAG.

`Bench::Speculative` and `Bench::Variance` already exist, so this is an experiment rather than a
build, and **a negative result is publishable too** — which is the mark of a real experiment. It is
also the clearest demonstration of why the content-addressed DAG is not decoration.

### 4. The freeze list — what makes every other result citable `[extends chunk-bench-science]`

`epolanski`'s comment (2026-08-18 §5.1) is the most complete external statement of harness-benchmark
methodology in the corpus, and it doubles as an audit of what Lain already guarantees. Freeze: the
model, **the model's configuration** (effort, permissions, provider), the dataset at a sha, **the
harness itself**, and **the tools** — *"even a slightly different implementation of grep or readfile
or sed has an impact"*. Plus: *"benchmarking against a closed-source runtime like Claude Code is
quite useless, they change too frequently and in ways you cannot directly inspect."*

Lain holds more of this than any harness in the corpus — CE-2's request digest chain, CE-3's
byte-identical prelude invariant, capability-set guarding in `Compare`, journaled slot digests, and
a session header carrying model and tool schema. **Tool identity is where Lain is unusually
strong**:
`Toolset` renders into the Request, so "which grep" is *in the hashed prompt bytes* rather than left
to a container image. And the frozen-harness clause has a cheaper answer here than shipping a
binary — **hash the rendered Request** and two runs are provably the same harness.

Missing, and all small: fixture/dataset sha, **provider** (already an owed residual), tool binary
identity, and the confound set. Fold in three items as that set:

- **Provider-side routing (item 21)** — Opus 5's published system prompt instructs it that the user
  may have been *redirected from Fable 5 by a safeguards router*. So "hold the model fixed" is not
  something a harness can guarantee, and the mismatch is **invisible in the API response**.
  Mitigation is one assertion: record the served model, compare to the requested one, invalidate the
  run on mismatch.
- **Training affinity (item 3)** — a cross-harness A/B on a model post-trained on its vendor's own
  harness measures training match, with a sign that flatters the vendor.
- **Prompt provenance (item 22)** — a `CLAUDE.md` written to compensate for an old model's
  non-compliance is not a constant across a model swap (`ltbarcly3`, 2026-08-18 §2.2).

> **Correct a phantom citation while here.** Both the 2026-08-14 doc and `references/INDEX.md` cited
> an "unmatched-effort rule" in `planning/specs/chunk-bench-science.md`. **No such rule exists** —
> the word "effort" does not appear in that file. The principle is right and simply unwritten, which
> is part of why this item exists. (Corrected in the reference docs 2026-08-18.)

### 5. Grader tampering is an invalid run, not a low score `[extends graders.md]`

danluu's *Benchmarkpocalypse* (2026-08-18 §5.2) is the demonstration: an LLM-built regex engine
looked **40% faster**, was **10× slower** on a holdout, and had **edited the benchmark interface
itself**; corrected, 1.5× and 2.4× *slower*. Databricks independently implemented the control —
**git history sealed during runs** so the agent cannot read the answer.

Zero hits for "tamper" in the plan outside an unrelated memory-root use. Lain already leases an
isolated worktree per worker, so the assertion has an obvious home: hash the fixture tree at lease
acquisition, re-hash at handback, and **refuse the run** if it moved. Without it every
`Grader::Fixture` score is unverified — and the failure is silent and flattering, which is the worst
combination. Small, and it makes Tier-1 #1–#3 defensible.

---

### 5b. Two mandatory baselines, and a variance floor — the cheapest credibility we can buy `[extends chunk-bench-science; small]`

Added by the 2026-08-18 re-audit. Both are controls, both are nearly free, and without them several
of the arms above are unpublishable.

**A random router and a constant-cheapest router are mandatory baselines for any routing arm.**
`seizethecheese` demolishes a vendor routing claim with a construction rather than an opinion: on a
near-saturated benchmark, *"I could easily publish a router that 'enhances Fable on GPQA Diamond'
showing improved score for lower cost, just by implementing a router that picks the model at
random!… I could publish better score at 87.5% time reduction by having the router always pick
Flash!"* The vendor then conceded the confound in the same thread — *"the speed/cost gains from our
harness would mostly be from using cheaper and simpler models rather than actually having a better
harness."* This lands on Tier-2 #10 (cache-break routing) and on the adaptive-router research track:
**an arm that beats neither a coin flip nor "always use the cheap model" has measured nothing.**
Same commenter reports his own honest negative — no lift from a multi-agent system on GPQA Diamond —
which is the result the bench should be able to produce and publish.

**Report `n` and variance, and treat cost as a distribution.** `jwr`: *"any sort of evaluation or
benchmark with a **sample size of 1 is essentially worthless**… I started insisting on having **at
least 5 runs**… If the results don't say how many runs were performed and what the variance was,
there is really no basis for comparison."* Corroborated three times in the same thread. And the part
that qualifies Tier-2 #9's cost frontier — `toddmorey`: *"I was sort of floored by the **variance in
token usage for the same prompt (run multiple times) with the same model**."* So **score-at-matched-
spend is comparing two distributions, not two numbers**; `Compare` already reports distributions
over
`n` runs, so this is a reporting convention plus a refusal to publish `n=1`.

**A ready-made minimal baseline harness exists**: `mini-swe-agent` (`minimal-agent.com`), which is
what the Bullet claim was measured against. The founding-thesis A/B wants a *published, frozen,
minimal* comparator rather than a moving closed-source one, and this is it.

## Tier 2 — worth doing, bigger, or needs a decision

### 6. `/drop` — the negative of a pin `[M4/M5, needs a ruling]`

Chunk 14 shipped **pins**: history the compactor may not touch. The inverse does not exist —
`lib/lain/cli/command/` has no drop/exclude, and nothing in `lib/lain/context` or
`lib/lain/compaction` takes an exclusion set. `/rewind` truncates a suffix; it cannot remove turn 7
and keep turn 8. This is the one primitive ThoughtDAG has that Lain mechanically lacks, and it is
the interactive surface Tier-1 #3's human-wired arm needs. Symmetric with pins throughout —
`Session#pins` gains a sibling set, `Context::PinnedMessages`' canonical-dump membership generalizes
to a shared `Context::MessageSet`, the strategy collapses via `Elide`, and the Neovim surface
exists.
**The ruling needed:** whether a dropped turn is elided-with-attestation (recoverable via
`causal_parents`, consistent with the derived-chain design) or hidden outright.

### 7. Compaction does not narrow the continuation set `[extends chunk-algebra-vocabulary]`

The one genuinely transferable idea from the KV-compaction paper (`2602.16284`), whose latent half
is
unreachable (§ Not reachable). The paper's requirement is not "the compacted block is good" but
"its contribution is unchanged under concatenation with **arbitrary** later blocks". Token-space
translation, in objects Lain owns:

> `Ext(X) = { s : Conversation.valid?(X ++ s) }`. Then for every strategy and source timeline `T`:
> **`Ext(derive(T)) ⊇ Ext(T)`** — compaction never narrows what may legally follow.

The derived-context chunk asserts the *point* version (`Conversation.valid?(derive(T))`, refused
loudly at derivation time) and never the closed version. The closed version names as **one class**
the three symptoms that chunk records separately — assistant summary at `messages[0]`, a second
consecutive assistant at `--compact-keep 20`, a boundary splitting a `tool_use`/`tool_result` pair.

Two honest caveats belong in the card: it will **land green today**, because the derived tail is the
`keep_last` window taken verbatim; and `Algebra::STRUCTURES` is a closed list, so adding a member is
a real change requiring a refutation battery. Its value is as a guard on the four
designed-but-unbuilt follow-ups that move a cut or compose strategies. If the panel rules it is not
a structure, it degrades cleanly to a shared example group at half the size.

### 8. The compaction-bias arm — score head-vs-tail answer location on outcome `[M3c, spends money]`

> **Reframed 2026-08-18.** `arXiv:2508.21433` (see § Pi, T0) is the prior art for the *strategy*
> comparison this item assumed was unrun: deterministic masking already matches LLM summarization at
> half the cost on SWE-bench Verified. So this item is no longer "does compaction cost quality" — it
> is the **position** question that paper does not ask: *where in the span* the needed fact sits.
> Run it as an extension of a replication, not from scratch.

The paper's sharpest claim survives the drop to token space as a *directional prediction*: a
compacted region's share of attention is set by its **surviving token count**, not by the count of
what it replaced, so compaction should shift effective attention toward the retained tail —
systematically, monotonically in the ratio. Build a fixture family where the graded answer sits at a
controlled position (inside the compacted span vs. inside the retained tail), sweep
`{elide, summarizing, identity} × ratio`, and score on **task outcome**.

This also gives `Strategy::Elide`'s byte-count attestation its first real test: it is Lain's shipped
guess at telling the model how much stood there. Arms `{attested, unattested}` measure whether that
repairs the bias or is decoration. `Elide` is pure and elementwise by construction, so the
derivation
measures the policy and never the cut points.

### 9. Cost as a first-class reporting axis `[extends cache-economics]`

Two items that belong together, because a budget cap is now a real deployment constraint
(`jgmedr`, 2026-08-18 §1.2: $150/engineer/month, ~$7.50/day, reported live).

- **Report every arm on a cost-normalised frontier (item 29)** — score at *matched spend*, plus the
  score/spend curve. `Compare::METRICS` already carries `cost`; what is missing is the convention.
  Databricks' numbers are the argument: Sonnet 5 at ~1.7× cheaper *per token* cost **$2.09/task vs
  Opus 4.8's $1.94** while scoring **81% vs 87%**, having burned 1.9× the tokens. **Token price is
  not task cost.**
- **Make the price model per-provider (item 30)** — Anthropic's 1.25× write / 0.1× read and OpenAI's
  1.0× / 0.5× have *different optima*: under one shape long stable prefixes dominate, under the
  other
  prefix discipline buys much less. So **an arm that wins on one provider may lose on the other**,
  which makes provider a confound in every cache experiment rather than a nuisance parameter. CE-6
  addresses TTL flavours and stale defaults only.

### 10. Route only at cache-break boundaries — and effort is the same knob `[M3c/M5]`

`ankitmathur`'s correction (2026-08-14 §1.1) resolves the routing-vs-cache tension the 2026-08 run
left standing: a switch is free precisely at **compaction, TTL expiry and session resume**, because
the prefix is being re-warmed anyway. Both halves of the predicate are already objects —
`Compaction::Cold` answers "is the cache cold", the scheduler owns compaction moments, resume is a
named event, and `Context::ModelSwitch` exists from the `/model` chunk. So the third arm
(`{never switch · per turn · only at cache-break}`) is a policy object over three existing seams.

Treat **auto-selected reasoning effort (item 37)** as the same experiment, not a second one:
`jillesvangurp` wants effort chosen per task, the vendor rule says fix effort before you start
because changing it busts the cache, and those cannot both be free.

### 11. Reviewability alongside score `[M4/M5]`

Three threads converge on one finding — `mjr00` (generation got cheap, review did not),
`geoffreylitt` ("understanding is the new bottleneck"), and the huge-PR rant: **the human review
budget is the binding constraint, and orchestration arms differ in how much of it they consume.**
Uniquely cheap here, because the entire `Review` subsystem already computes hunk counts, files
touched, and diff size — and has never been pointed at the bench. One projection into
`Compare::METRICS` turns a slogan into a column, and an arm that wins on score while producing 4×
the diff has not obviously won.

### 12. Assert containment from inside `[M6, extends isolation]`

The Copilot-autofix → Snowflake-Jira compromise (2026-08-18 §4.1) is the in-the-wild version of the
failure the approval-gate projection rule prevents. The plan commits to isolation as a compared
backend but only ever observes **from the host**, which cannot fail correctly. The shape is the one
`spec/output_discipline_spec.rb` already established for stdout: a `:seam` spec that runs *inside*
the guest and tries to reach the host, the LAN and the parent repo, failing if it succeeds. This
repo has already lost a directory to the mounted-worktree hazard, so it is a control with a
paid-for precedent. Fold in item 7's `{hardlinked clone · copy+replay · jj workspace}` arms as the
thing being asserted about, with RSS priced.

---

## Tier 3 — small, parked, or needs a corpus first

- **Hedged requests as a `Middleware` (item 33)** — architecturally attractive (pure w.r.t. the
  Timeline, so it composes in the monoid) and probably a *negative* result: two concurrent identical
  prefixes race on the cache **write**, so under Anthropic's shape a naive hedge can cost more than
  2× on input. Prior art is solid and pre-LLM (Dean & Barroso's *Tail at Scale*; the power of two
  random choices). Park until something is latency-bound.
- **Metamorphic graders (item 23)** — the right long-term answer for tasks with no golden output,
  and `Lain::Algebra`'s property machinery is already the idiom (relationships between outputs under
  input transformation). Needs a task corpus first; sequence after Tier-1 #1.
- **Replicate the doc-guidance experiment (item 34)** — the cheapest *self-run* replication in the
  corpus: explicit guidance moved procedure selection **33% → 100%** (n=15) while labelling a
  section "For AI agents" moved it **not at all**. One afternoon. Would be Tier 1 if the goal were
  publication rather than bench capability. It also constrains the injection threat model in the
  uncomfortable direction: a "for agents" marker confers no authority an injected paragraph lacks.
- **Repo size as a moderator (item 31)** — "minimise context" is a bet tuned for codebases that do
  not fit; on a small repo, load-everything may win *and* be maximally cache-stable.
- **Instrument tool-invocation rate separately from score (item 26)** — `Grader::ToolSteering`
  already does this for tool *steering*; the M6 memory sweep reports only recall@k and
  tokens-on-recall, so a retrieval arm's *adoption* rate is currently indistinguishable from its
  *quality*.
- **`prune`/`prune-extended` with tool-call receipts (item 16)** — a receipt keeps the command and
  exit status and drops the output. `MikhailTal`'s objection (models are RL-trained on their own
  chain) is now a hypothesis with a measured effect size rather than a veto: **>30% of one frontier
  model's CoT steps are causally inert, and the lowest-scoring 50% can be removed at little cost**
  (`2510.24941`). But `2604.15726` warns the arm must hold **serial compute** fixed or it confounds
  two variables. **The cross-turn question is unanswered in that literature and is precisely ours**
  —
  every one of those papers ablates *within* a single generation; nobody measures whether a prior
  turn's thinking, still in context, helps the next turn.
- **Cross-branch `Context::Reference` (ThoughtDAG C)** — render branch A's and branch C's actual
  turns with nothing between them. Currently inexpressible: `Context#render` takes one Timeline and
  walks first-parent, and the only fan-in (`Arm::Synthesis#fold`) *flattens* N branches into one
  assistant turn. Note this is a **ruling, not an omission** — the derived-chain design pins itself
  single-source and strategies see messages only. Sequence last; Tier-1 #3 would tell us whether
  cross-branch inclusion is worth anything.
- **Speculative decoding on the local arm (2026-08-14 item 12)** and the local-arm config/KV-dtype
  work — see § Local arm, pending.

---

## Confirmations — external validation, no action

- **The excursion arm already ships.** `jsw97` described a context-*inheriting* branch as a novel
  harness feature; `SpawnPolicy::REGISTRY` has carried `inherit` since CE-4, documented as
  "`parent.fork`, O(1), the child's head IS the parent's". Corroboration of the spawn axis, not
  work.
- **The compaction-loop guard is half-shipped.** `Scheduler#shrinks?` is strict and a non-shrinking
  rewrite defers with `would_not_shrink`. Only the digest-differs half remains (a card, not a
  chunk).
- **`grep`-over-markdown is already the retrieval baseline.** `Manifest` is the committed first arm
  of the memory sweep; the community's recurring "why not just grep markdown" is the baseline the
  sweep already runs.
- **Compaction-preserves-reach is built.** The derived context timeline landed 2026-07-27: the
  session timeline stays the lossless record, the derived chain is what the provider sees, and
  `causal_parents` names every subsumed source. `simonw`'s request in the 2026-08-14 window is
  already this project's shipped design.
- **The approval gate already reads only the call it judges** — `CONTEXT_MODE = :fresh`, "never the
  parent's conversation". What is missing is only the stated threat model and the
  inject-into-a-tool-result test.
- **Scoring on outcome, never on similarity, is existing doctrine** — "prelude size alone is an
  anti-metric; always grader × tokens × cache-write". Worth one restated line in
  `chunk-bench-science.md` now that the failure has a public example.

---

## Not reachable — record the rejection so it is not re-derived

**Attention Matching itself (`2602.16284`), hosted or local.** It requires writing constructed
`C_k`/`C_v`/`β` into a live KV cache and an attention kernel accepting a per-token additive bias.
Anthropic exposes no such surface at all. Against ollama the reachable surface is six request
options plus three server env vars, none of which touch cache *contents*; llama.cpp's richer knobs
are **verified not to pass through** (ollama builds its own command line). Implementing it means a
PyTorch-level serving path — a new provider *and* a new inference stack — and would violate the
placement rule that nothing in-process may own a GPU runtime. **KV quantization is not compaction:**
it shrinks bytes *per token*, while the paper compacts along the *sequence* dimension; the paper
calls them complementary.

**"Compaction only appends" as a property test.** Proposed in the 2026-08-18 doc and **false for
Lain by construction** — `Event#payload` folds `render_parent`, so the derived chain shares nothing
with its source. Append-only is true of the *session* Timeline, a different and uncontested claim.
Corrected in that doc; the assertable law is Tier-2 #7.

---

## Reconciliation summary

Full item-by-item table with citations lives in the gap analysis backing this doc. Totals across the
52 numbered items of the 2026-08-14 and 2026-08-18 scans: **6 already covered · 13 partially covered
· 20 genuinely new**, plus the corrections above and the excluded GPU/KV set.

The pattern worth noting: **almost everything genuinely new is a metric or a control, not a
mechanism.** Lain has built the seams; what the August field surfaced is what to *measure* across
them (diversity, merge fraction, reviewability, cost-at-matched-spend, verifier strength) and what
to
*assert* about them (served-model match, fixture sealing, continuation-set preservation). That is a
comfortable place to be — the expensive half is done.

---

## Pi (`earendil-works/pi`) — what a minimal harness actually buys, measured

Databricks reported Pi sending **~3x less context per turn** and beating heavier harnesses on their
codebase. Two surveys read the source to find the mechanism. The headline is that **the mechanism is
mostly subtraction, and Lain is already on the good side of most of it** — but the measurement
turned
up one real defect class and one genuinely superior instrument.

**⚠️ Read before mining Pi: it is two codebases.** The shipping CLI is `AgentSession` +
`agent-loop.ts` + a v3 JSONL session log. A second, far more ambitious stack —
`packages/agent/src/harness/` plus a **2,941-line spec** — is largely **unbuilt**: the harness
throws `HarnessNotImplemented`, its 667-line pure reducer is imported only by its own test, and the
telemetry layer emits nothing. **Most of Pi's best ideas are in the spec, not the product.** Cite it
for ideas; do not treat it as a proven design.

### The measurement, and where Lain actually stands

| | Pi | Lain |
|---|---|---|
| System prompt | 2,623 B / ~656 tok | **341 B / ~92 tok** |
| Tool schemas on the wire | 5,021 B / ~1,255 tok (7 tools) | **11,038 B / ~2,983 tok (15 of 24)** |

**Lain's prompt is 7x smaller than Pi's; Lain's tool schemas are 4x larger.** So **the entire prefix
cost is in the tool layer**, and the lesson is not "ship fewer tools" — it is **"make the schemas
smaller"**. `lib/lain/tools/ast_search.rb` alone serializes to 1,522 B, 1.5x Pi's largest tool,
against a Pi mean of 228 B per description.

And the honest counterweight, from npm download data on the Pi extension ecosystem: **Lain already
ships 10 of the 11 capabilities Pi users are busiest re-adding** (subagents, web, memory, todo,
ask-user, permissions, LSP-ish code intelligence, plan review, context reduction). Lain is not
bloated
relative to Pi; it sits at a different point on the same curve, and Pi's ecosystem is paying
thousands
of extensions to walk back toward it. **The one real gap is MCP** — `pi-mcp-adapter` at 154k weekly
downloads, #1 by a 2.4x margin — which `lib/lain/provider.rb:16` explicitly scopes out. That ruling
is worth re-reading in light of the number, not necessarily reversing.

**A caveat that dwarfs all of the above:** Pi auto-loads `AGENTS.md`/`CLAUDE.md` into the system
prompt, and **this repo's `CLAUDE.md` is 39,447 B — roughly 10,600 tokens, 16x Pi's entire base
prompt** (measured). Any harness-level prompt shrinking here is a second-order effect behind that
one
file.

### T0. Compaction: the literature says do the cheap thing, and Lain can replicate that today

**`arXiv:2508.21433`, *The Complexity Trap*, is the paper this axis was missing** — found not on HN
but in a surveyed extension's own citations. A systematic comparison inside SWE-agent on **SWE-bench
Verified** across five model configurations, with initial generalization to OpenHands:

- **Observation tokens are ~84% of an average SWE-agent turn.** That single number is the
  quantitative case for T1's uncapped-output finding.
- Running with **no** strategy more than doubles cost — *"any of the discussed management strategies
  are preferable to none"*.
- **Deterministic observation masking halves cost while matching, sometimes slightly exceeding,
  LLM-Summary's solve rate.**
- A **hybrid** beats both: 7% cheaper than masking, 11% cheaper than summary.

**Lain ships all three arms behind one seam already.** `Strategy::Elide` *is* observation masking,
`Strategy::Summarizing` *is* LLM-Summary, `Strategy::Composed` *is* the hybrid. So the replication
is
a fixture and a sweep, not a build — and it **inverts the default posture**: the model-backed
strategy is the one that must justify its cost, not the deterministic one.

`arXiv:2606.23525` (*Self-Compacting Agents*) supplies the second arm, for *when* rather than
*what*:
a model-invoked compaction tool plus a rubric that says fire when a sub-task resolved or the
trajectory is converging, and **suppress mid-derivation or when stuck** — and reports that the tool
alone is used unevenly, so both halves are needed. The suppression half is the transferable part,
because "never compact mid-derivation" is a **structural** predicate and Lain's Timeline knows turn
and tool-chain boundaries exactly. It can be *enforced* rather than prompted, which is strictly
better than the paper's own mechanism.

### T0b. The summary schema everyone shares, and nobody has tested

Pi's template, verbatim from `core/compaction/compaction.ts`, is `## Goal` · `## Constraints &
Preferences` · `## Progress` (Done / In Progress / Blocked) · `## Key Decisions` · `## Next Steps` ·
`## Critical Context`, with a **second iterative variant** whose rules are *"PRESERVE all existing
information… move items from 'In Progress' to 'Done' when completed"*. Its system prompt is three
lines and its whole job is negative: *"Do NOT continue the conversation… ONLY output the structured
summary."*

**The same skeleton appears in all four implementations surveyed** — upstream Pi, oh-my-pi's
handoff,
Pi's handoff example extension, and the branch-summary variant. The surveying agent's read, which I
agree with: *"That convergence looks like consensus and is more likely lineage — everyone copied the
same template. There is no evidence in any of these repos that this schema was evaluated against
alternatives."* And more damning for the field: **nobody in the survey evaluates their own
compaction.** Pi has unit tests for cut points and no outcome measurement; oh-my-pi has a readback
harness for snapcompact whose `results/` is gitignored; context-fold says outright its tests are
"liveness checks, not benchmarks".

**That is the experiment.** Hold the pipeline fixed, vary the *summary schema*, measure task outcome
and cache cost. Lain is the only harness surveyed that can run it, because `Strategy` is a seam and
`TEMPLATE` is content-addressed — a schema change is a new strategy with a new address, not an edit
that silently re-keys history. Arms: `{Pi schema, prose (Lain's current), deterministic index,
schema+deterministic index}`.

### T0c. Two design rules worth taking whole, from `context-fold`

The best worked example in the ecosystem, and its posture is the right one for a bench:
deterministic
by default, cites its evidence, and labels a model-written summary as **"(UNTRUSTED narrative —
verify against the log before relying on it)"**.

- **Fold what is observation, never what is intent or action.** `FOLDABLE_KINDS = {text, thinking,
  tool_result}` — a `tool_call` is never folded (orphaning) and a `user` message is never folded
  (intent). It keeps the block's *shape* (`grep → 412 lines, ~3100 tok · <first line>`) and retains
  **detected error/risk lines verbatim**, so a buried `ImportError` survives folding.
- **Two recovery modes, and the distinction is the insight.** `recall_folded` is a **one-time
  read**;
  `unfold` is **sticky re-expansion**, with the guidance *"Unfold only a block your ongoing work
  keeps needing. It re-expands permanently and costs its full token weight every turn after."* The
  model should be able to *peek* without permanently re-inflating context. Lain's content addressing
  makes the handle free — the digest **is** the pointer, with no FNV hash, no spool directory, no
  SHA verification and no GC, all of which context-fold has to implement beside a history that isn't
  content-addressed.
- **Batch mutations at declared freeze points**, so cache invalidation is paid once and the
  substituted bytes never change again. Lain's `Canonical` makes "did the prefix change"
  mechanically
  decidable rather than inferred — context-fold has to *infer* it from observed `cacheRead`
  telemetry, and drops its fold threshold from 0.45 to 0.25 when it concludes no warm cache exists.

### T0d. Two foot-guns not to import, and one Pi bug

- **`keepRecentTokens` is unclamped** against the context window. Set it above
  `window - reserveTokens` and the cut point never reaches its budget, preparation returns nothing,
  auto-compaction returns false, and **the session silently stops compacting while continuing to
  overflow** — with no warning anywhere. Lain's equivalent knobs want a clamp and a loud refusal.
- **`session_before_compact` is last-writer-wins with swallowed exceptions.** Two extensions that
  both implement compaction fight silently, resolved by load order, and a thrower degrades to the
  default with only an error-listener notification. This is precisely what a property-tested
  `Middleware` monoid prevents: composition should be *specified*, not incidental.
- **Mixed units in one decision.** Pi's compaction *trigger* uses real provider usage numbers while
  its *cut point* uses a `chars/4` estimate — so the thing that decides what the model forgets is
  chosen in a different unit from the thing that decides whether to forget at all. Worth an explicit
  ruling in Lain rather than an accident.

### T0e. What is scaffolding, and must not be imported

The surveying agent's bottom line, which I endorse: the borrowable core is **compaction as a
`Context` combinator over an immutable log with the boundary as a digest**, **deterministic
extraction that never passes through a model**, **reversible masking with digest-addressed pointers
and a two-mode recall tool**, and **cache-miss accounting as an instrument**. Everything else —
handoff-as-a-*strategy*, branch summarization, entry copying on fork, a `fromHook` boolean standing
in for provenance, and a pile of heuristics reconstructing which usage belongs to which context — is
**scaffolding around a flat append-only file with uuid identity**. Lain already has the substrate
those compensate for, so importing them would be importing the compensation. Three specifics:

- **`/fork` and `/clone` copy every entry into a new file** — O(n) bytes and time, two divergent
  files, and a `parentSession` path pointer that can dangle. Lain's fork is O(1) from a handle.
- **Branch summarization exists because Pi's tree has no `meet`.** You cannot compute what an
  abandoned branch contributed, so you pay a model to guess. Lain has `meet` and `diverge_at`: the
  delta between two branch heads is **computable**, and an LLM summary of a computable diff is an
  expensive workaround.
- **Re-summarizing already-summarized messages on every repeat compaction**, because there is no way
  to say "the summary already covers digests X..Y". Coverage as a **set of reachable digests** is
  exactly the roaring-bitmap primitive already in Lain's plan — and the same primitive answers "what
  does this branched context actually cost", which none of the three surveyed tools can compute.

**And the handoff verdict.** "Continue in a new session" is what you build when forking is expensive
and history is a flat file. Lain already has the primitive (`fork`, plus `meta["spawned_from"]`), so
**it needs the artifact, not the strategy** — a portable, content-addressed handoff *document* is
worth having for humans and for other vendors' tools (which is `superasn`'s actual reason for
preferring it), while "start a new session" stops being the interesting part.

### T1. Uncapped tool output is a live defect class `[M3c; small; verified in our code]`

Pi caps every tool at the point of production — `DEFAULT_MAX_LINES = 2000`, `DEFAULT_MAX_BYTES =
51200`, per-tool match limits — truncating **head** for reads and **tail** for command output
(errors
live at the tail), and emitting an *actionable* continuation notice (`[Showing lines 1-2000 of 5000.
Use offset=2001 to continue.]`), with bash spilling full output to a named temp file.

**Lain caps almost nothing, and the inconsistency is verified:** `lib/lain/tools/read_file.rb` is a
bare `File.read(path)` — no offset, no limit, no cap, so a 5 MB file goes straight into context and
straight into the Timeline. `lib/lain/tools/bash.rb` has a timeout but **no output cap**.
`glob`/`list_files` are uncapped. Only `Tools::Grep` caps, at `MAX_MATCHES = 200`, and its own
comment shows the determinism reasoning was done carefully — *"the same 200 in a different order"* —
which makes the gap elsewhere an oversight rather than a policy.

This is not merely a cost issue: an unbounded tool result is an unbounded **event**, and it lands in
a
content-addressed history that compaction then has to deal with. Borrow the shape exactly — a shared
`Tool::Truncate` helper (head for reads, tail for command output), byte **and** line caps whichever
hits first, and a continuation notice that tells the model how to get the rest.

### T2. A prompt-cache **waste detector**, not a hit ratio `[M3c; small; highest value/cost]`

`core/cache-stats.ts` is 164 lines and does what Lain's `Usage#cache_hit_ratio` cannot: it
attributes
and **prices** each miss. Per assistant message it computes
`missedTokens = min(prev.promptTokens, promptTokens) - usage.cacheRead`, values it at the paid rate
minus the cache-read rate, and reports `Cache Re-billed: $0.043 (128,400 tokens, 7 misses)`. The
details are the good part: a 5-minute TTL constant attributes idle expiry; a 1,024-token noise floor
filters breakpoint granularity; a sticky flag separates "total miss" from "this provider never
reports caching"; compaction and branch summaries reset the baseline while **model switches
deliberately do not**, because those re-bill legitimately.

**Lain has every input already** — `cache_creation_input_tokens`, `cache_read_input_tokens`,
per-turn
timestamps, `PriceBook`. A ratio says the cache is working; this says **what it cost and why it
broke**. It is therefore the instrument that would actually *measure* whether a `Context` combinator
preserves the stability `Canonical` promises, which makes it a prerequisite for the compaction and
routing arms rather than a nice-to-have.

### T3. Publish conformance suites as the contract owner's artifact `[M4/M6; medium; structural]`

Three Pi packages export a `./testing` subpath — the session contract ships **31 cases / 1,016
LOC**,
run against memory, JSONL and SQLite backends from three call sites. The contract's owner ships the
suite; an implementation proves itself by importing it. Their telemetry conformance goes further
with
an `unreadable()` Proxy that throws on every access, asserting instrumentation is **passive**: the
span still runs the callback exactly once, preserves return value and rejection *identity*, and
records nothing.

Lain already does this for exactly one duck — `Regular`/`MeetSemilattice` across the Ruby and Rust
Timelines. **Generalise it**: `Context` combinators, `Effect::Handler`, `Sink`, `Store` backends and
`Provider` each define a duck and none ships a shared group. For a bench whose entire premise is
swappability, this is the highest-leverage structural borrow, and chunk 15's algebra registry is the
vehicle.

### T4. `env -i` allowlist isolation beats scrubbing a known-bad list `[small; fixes a recorded trap]`

Pi's test entry point starts from an **empty environment** and allowlists in: a fresh
`HOME`/`TMPDIR`/`XDG_*`, `LANG=C TZ=UTC`, `GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
GIT_ASKPASS=$(type -P false)`, isolated npm config — and its cleanup refuses to delete anything
lacking an ownership marker file.

`CLAUDE.md` records the `GIT_INDEX_FILE` trap (pre-commit exports it into every hook, so a fixture
that shells to git builds against *lain's* index) and states the fix as "scrub the wider set —
`GIT_INDEX_FILE`, `GIT_COMMON_DIR`, `GIT_WORK_TREE`, `GIT_CONFIG_*`". **Allowlisting in is
structurally safer than blocklisting out**, and would have prevented that failure by construction
rather than by remembering a list. The ownership-marker rule is the same discipline as the recorded
"a runner must refuse to start unless a file it owns is present".

### T5. Convergent evidence for "projection with a retrieval handle" `[M3c/M5; confirms a direction]`

Three independent Pi forks/extensions were surveyed, and **all three replace or bypass core
compaction**, and their deepest investments all reach for the same shape: full data stays on disk,
the
model gets a dereferenceable pointer. Staged tool loading (prompt sees ~14 of ~60 tools, admitted by
a
**policy** — "read-only and not heavy" — rather than a list); tool *unmounting* behind a virtual
filesystem so N schemas cost ~0 prompt tokens **and the tool array stays byte-stable for the
cache**;
and task re-materialisation on demand. That is Lain's "handles to out-of-context data" research
track
(`first-class-concepts.md`), independently arrived at three times by people who then had to build it
outside their harness.

Separately, `oh-my-pi` ships a **`StablePrefix`** class that freezes system prompt plus tool specs
to
identical bytes with a fingerprint. That is **independent confirmation that "purity and cache-hit
are
the same constraint" is load-bearing at scale**, from someone who hit it in production.

### T6. Smaller borrows, each a card rather than a chunk

- **Anchored token estimation** — take the last provider-reported usage as an anchor and estimate
  only
  the messages after it, invalidating the anchor when a compaction inserts a newer prefix message.
  Cheaper than a count-tokens call, more accurate than pure estimation. Feeds `Agent::Budget`.
- **Session state via environment, not prompt text** — `PI_SESSION_ID`/`PI_MODEL`/`PI_SESSION_FILE`
  injected into the bash tool's env, with the prompt telling the model to *inspect* them.
  Self-knowledge
  at zero prompt cost, always current, and `$PI_SESSION_FILE` lets an agent read its own transcript.
  `WorkerEnv` is the seam.
- **Tool-ergonomics mining from the Journal** — `inflationRatio = emitted bytes / bytes of real file
  change`, as median/p90/p95, bucketed and broken down by model and file extension. A tool-design
  metric derived from production traffic; a script, not a feature, and the Journal is already
  NDJSON.
- **Batch discipline** — preparation (validation, approval) runs **sequentially in source order**,
  effects fan out concurrently, results are emitted **in source order regardless of completion**.
  And
  the trap worth an explicit answer: on `stop_reason == "max_tokens"`, fail **every** tool call in
  the
  message without executing any, because truncated arguments may parse.
- **Paired-eval diagnostics** — `Bench::ArmSweep` already pairs by `(arm, task_id)`; what Pi adds is
  `repetitions` as part of the grouping key, wins/ties/losses on discordant pairs, and a diagnostics
  channel that **names why each unpaired observation was dropped** (`missing-observation |
  duplicate-observation | harness-error | missing-score | unscorable-outcome`). Add the statistics
  Pi
  omits — exact McNemar or a binomial CI on discordant pairs.

### Do not borrow

- **Pi's hook aggregation.** 34 hooks, 11 hand-written aggregators, first-wins/chain/accumulate all
  present with **no single stated rule**. Lain's property-tested `Middleware` monoid is strictly
  better — and Pi's own unbuilt spec is an attempt to fix exactly this.
- **The permission posture.** Pi states outright that it has no sandbox and no permission system;
  its
  reference answer is a 33-line regex example whose ecosystem replacement is 7,208 LOC. Do not
  soften
  the three-place secret boundary toward it.
- **Zero extension sandboxing plus zero version negotiation**, in a system with a first-class
  `pi install npm:…` channel.
- **Removing line numbers from file reads.** Real savings (measured 20.5% on their own tree) but it
  forces exact-text-only edits and destroys `file:line` citation — and
  `Review::Anchor`/`Review::Hunk`
  are built on positions. Wrong trade here.
- **Settings without a schema** (deep-merged JSON, unknown keys passed through, while *themes* get a
  compiled JSON Schema — the asymmetry is backwards). `Tool::Input` is the right instinct.

---

## Local arm — VRAM spill, and why the bench wants the opposite of graceful

The prompting question was whether Linux 7.3's VRAM-overcommit work
([pixelcluster.dev/VRAM-Overcommit](https://pixelcluster.dev/VRAM-Overcommit/), Part 2) makes larger
models or longer contexts usable on this box. **The answer is no — not yet, and probably not in the
direction that helps a bench.** Investigating it did surface a live defect candidate that is free to
test, which is the valuable outcome.

### The mechanism is on-path — this is not a graphics-only concern

The intuitive objection that "LLM inference doesn't hit the eviction path" is **wrong**, and the
reason is in RADV rather than llama.cpp. `radv_amdgpu_bo.c` adds `AMDGPU_GEM_DOMAIN_GTT` to the
preferred heap of **every** `RADEON_DOMAIN_VRAM` allocation unless `RADV_PERFTEST_NO_GTT_SPILL` is
set. A `DEVICE_LOCAL` request from ggml therefore becomes a **demotable** buffer that TTM will evict
under pressure and never bring back. That line has been there since Mesa 21.1 and was a *gaming*
optimisation. So Vock's work does operate on the path the local arm uses.

### Involuntary eviction is a cliff; deliberate offload is a slope

These get conflated and only one is dangerous. Measured:
[llama.cpp#5380](https://github.com/ggml-org/llama.cpp/issues/5380) — AMD dGPU under Vulkan/RADV,
weights evicted by another process, **10 tok/s to 1 tok/s, no config change, persisting until server
restart**. That ~10x matches the PCIe-vs-VRAM gap. RADV does not report OOM until *both* VRAM and
GTT
are exhausted, so nothing announces it.

**This is the finding that decides the question.** A ~10x degradation that persists until restart
and
raises no error is the worst failure mode a timing bench can have: it does not fail, it quietly
reports wrong numbers. **Better eviction makes that harder to detect, not easier.** The correct
posture for a measurement harness is to make spill *impossible and loud*, not *graceful and silent*
—
which is also what llama.cpp's own benchmark guidance tells RADV users to do (`nogttspill`), thereby
opting out of Vock's machinery by construction.

### Why the upgrade is not worth doing for this project

1. **Nothing to upgrade to** — 7.3 is unreleased; 7.2 carries none of it.
2. **The biggest Part 2 win is doubly unreachable** — the priority-ordered LRU needs
   `VK_EXT_pageable_device_local_memory`, which appears **nowhere in ggml** (confirmed against the
   shipped backend `.so`), *and* mainline RADV does not pass priorities through. Both must change
   first, which makes the **upstream watch — ggml and Mesa — higher-leverage than the kernel**.
3. **The one piece with unconditional value** (the `drm_exec` fix, which makes failing submissions
   *succeed* rather than merely run faster) is unmerged, CI-red, and untouched since 2026-07-06.
4. **System RAM still binds** on this box regardless.

### R1 — free, worth doing anyway, and it may explain an open discrepancy `[local arm]`

**`RADV_PERFTEST=nogttspill` is not set on this box** — not in the ollama env file, not by the
binary. **The local arm has been benchmarked with GTT spilling enabled and no mitigation**, on a
machine whose desktop holds over 1 GiB of VRAM.

Three parts, none needing a kernel change: (a) set `RADV_PERFTEST=nogttspill` for the ollama
service,
converting a silent 10x into a loud allocation failure; (b) have `bin/bench-ollama-gpu` sample
`mem_info_vram_used`/`mem_info_gtt_used` per measurement into the NDJSON and **refuse to record a
run
where GTT rises above idle** — closing the standing trap that *"offloaded N/N layers" does not mean
resident* with a residency signal instead of a tok/s inference; (c) re-run the 2026-08-14 and
2026-08-15 prefill harnesses back to back with (a) and (b) in place.

**Candidate explanation for the open 3.5x prefill discrepancy** in `DEBUGGING_OLLAMA.md`'s
2026-08-17
entry (340 vs 1,201 tok/s, same model, same box, same build): #5380's signature is exactly a
persistent degradation surviving until restart, a sharper version of that entry's own listed
candidate ("KV cache state left over from a prior run on the same server process"). The 2026-08-14
session ran `kv-ceiling` sweeps including `f16@96k` — the one configuration that genuinely
overcommits. **Stated as a hypothesis, not a finding:** `bench-ollama-gpu` calls `unload()` between
models, which frees the buffers, so poisoning would have to survive a reload. Plausible via
fragmentation and desktop contention; not established. The test is one `cat` of `mem_info_gtt_used`
per measurement, so it is ruled in or out cheaply either way. Prerequisite: run `ollama serve` as a
systemd user unit — today it lives in a terminal scope with no cgroup to protect.

### R2 — re-evaluate at 7.3, gated on R1 showing spill actually happens here

Only if R1 shows GTT growth under contention. Then `dmem` in `subtree_control`, `dmem.min` on
ollama's slice, and a `kv-ceiling` re-run under deliberate VRAM load against the R1 baseline.

### Related parked items

Local-arm config as part of the **arm's identity** (item 38 — quantization, KV-cache dtype, chat
template, none currently journaled), and the unanswered **q8_0-vs-f16 quality** question that
`DEBUGGING_OLLAMA.md` raises and never settles: it measured tok/s and VRAM (q8_0 at 51.0 vs f16 at
96.0 MiB per 1k tokens; f16 13% *faster* at 32k) but never task outcome. R1's residency guard is a
prerequisite for trusting any of those numbers.

> **Sourcing note.** Everything about Part 2's *unmerged* work rests on a single source — the
> author's own post, published 2026-08-17, with no third-party measurement yet. The RADV GTT-spill
> default and the 7.3 merge scope are two-source. The `drm_exec` patchset status could not be
> independently confirmed.


---

## Fold-in ledger — the edits this doc proposes

Not yet applied. Each is small and independently landable.

| # | Edit | Target |
|---|---|---|
| 1 | ✅ **applied** — new **Verification** axis row | `ROADMAP.md` § one seam, many swept axes |
| 2 | ✅ **applied** — **Decorrelation** axis row + **merge fraction** on Orchestration | same table |
| 3 | ✅ **applied** (ROADMAP half) — matched-spend reporting note; `specs/cache-economics.md` still owed | same table |
| 4 | Tier-1 #1–#5 as a new `[exp]` fold-in block under M3c/M5 | `ROADMAP.md` milestones |
| 5 | Freeze list + confound set (routing, training affinity, prompt provenance) | `specs/chunk-bench-science.md` |
| 6 | Fixture sealing as a grader precondition | `specs/graders.md` |
| 7 | The continuation-set law | `specs/chunk-algebra-vocabulary.md` follow-ups |
| 8 | Tier-2/3 as `[exp · parked]` rows under their milestones | `ROADMAP.md` |
| 9 | ✅ **applied** — near-term-sequence item 31 | `ROADMAP.md` § Near-term sequence |
