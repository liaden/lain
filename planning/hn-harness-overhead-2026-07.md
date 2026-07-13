# Harness overhead in the wild — what HN 48883275 is worth to us (2026-07)

> **Folded in (2026-07-13):** Tier-1 #1–#3/#5 and Tier-2 #6/#8 are now specced as
> `planning/specs/cache-economics.md` (CE-1..CE-7, cross-read with
> `references/prompt-caching-mechanics.md`) and sequenced in `ROADMAP.md`; the attenuation/position-0
> and staggering questions landed in `planning/specs/orchestration-model.md` § Open questions.
> Tier-2 #9 (DCP) folded later the same day: the repo was reviewed and landed in
> `planning/specs/oracles.md` — the `compress` tool as the model-self-directed arm of the
> decider-locus sweep (OR-4), the dedupe/purge-failed mechanics + protected pins as OR-6.
> Tier-1 #4 (repair middleware), Tier-2 #7 ("Hey" fixture), and #10 (model as role capability)
> remain unfolded — pull them when their milestone opens.

> Source: ["Claude Code sends 33k tokens before reading the prompt; OpenCode sends
> 7k"](https://systima.ai/blog/claude-code-vs-opencode-token-overhead) — 673 points, 349 comments.
> Read as a *natural experiment in the thing Lain benches*: several thousand practitioners arguing,
> with partial data, about exactly the axes in the ROADMAP table. Most of the thread is confirmation.
> This document isolates what is **additive**.

## The meta-finding: they ran our experiment badly, and got hammered for it

Systima put a logging proxy between two harnesses and the model, diffed the first request, and
published the size. The top-voted critique (PUSH_AX) is the one that matters:

> This is like saying contractor (A) asked for $33,000 to undertake the work and contractor (B) asked
> for $7,000. Are we measuring and caring about the right thing?

They had no grader, so "identical correctness" was an eyeball. They measured at a **proxy**, so their
own gateway's 6.2k envelope had to be *calibrated out* — and the thread ate them alive for it. They
pinned a stale model to save money. They later added a repro repo and a quality section under
pressure.

Every one of those failures is a design constraint Lain already satisfies: `Context#render` is
**pure**, so the prelude is computable exactly with no proxy and no envelope to subtract; the Journal
*is* the experiment record; graders exist precisely so "same correctness" is not an eyeball; fixtures
are committed and deterministic. **The negative space of this article is a spec for our bench.** That
is the headline: we can publish the study they could not, and the thread is the evidence that people
want it.

Two things follow. First, the reproduction is cheap and the audience is proven. Second — and this is
the discipline the thread teaches — **prelude size is an anti-metric.** Reporting tokens without a
grader is what got them dismissed. Lain scores grader × tokens, never tokens alone; say so out loud
in the bench's own README so we do not drift into the same trap.

---

## Tier 1 — novel, aligned, and cheap for us

### 1. Cache *stability* is a metric, and it is the article's real finding

Buried under the 33k headline: on identical tasks Claude Code wrote **53,839 cache-creation tokens**
to OpenCode's **1,003**, and mid-session re-wrote prefixes up to **85,686 tokens** at the 1.25×
write premium. OpenCode kept **byte-identical prefixes across sessions**.

That is not a cache-*hit-rate* story, it is a **cache-write** story, and cache-hit rate hides it: a
harness can hit 90% and still bleed money re-writing the 10%. We currently track `cache_hit`. Add:

- **`cache_write_tokens` per session**, and
- **prefix-rewrite events** — count and *depth* (how far back the break was).

We are unusually equipped here. `Canonical` gives deterministic bytes and `diverge_at` **localizes a
cache break** — so Lain can not only count rewrites but *attribute* each one to the turn that broke
the prefix. Nobody else in the thread can do that; they can only observe the bill.

**Also worth a spec:** byte-identical prelude across sessions is an *invariant we can assert*, not a
property we hope for. `Canonical` already claims "one function, two invariants" (turn hashing +
cache stability) — this is the second invariant finally getting a test. A spec that renders the same
`(Timeline, Toolset, Workspace)` twice in two processes and asserts identical bytes is a few lines
and it forecloses the entire failure mode the article documents.

### 2. Fork-the-parent as an orchestration arm — and it argues with our own default

The thread's best idea (sgc, and gwerbin already doing it by hand in OpenCode):

> instead of spawning subagents to implement, **fork the main context** to write each part. Then use
> one last fork to verify. That way you keep reusing the same context without polluting your main
> context.

This lands directly on a design decision we have already made and written down:

> Subagents get a **fresh** Timeline root whose `meta["spawned_from"]` names the parent's head.

Fresh-root buys **context isolation** (the child never inherits the parent's prompt, so no pollution,
no distraction). It costs a **full bootstrap** — the child pays for its own prelude and re-reads
whatever it needs. Fork buys a **warm prefix** (cache-read, not cache-write) and zero re-discovery. It
costs pollution.

The thread cannot resolve this — it *argues* about it, at length, with no data:

| Claim | Who | Evidence |
|---|---|---|
| Subagent fan-out cost 121k → **513k** tokens (4.2×) | the article | one run, no grader |
| "Every subagent sends the same ~30k system prompt" | `a_c` | asserted |
| "The shared prompts are all cached, it's a cache read" | `mips_avatar` | asserted |
| "Cache is usually not shared between agents" | `ricardobeat` | asserted |
| "The subagent only returns the result, the parent doesn't consume its transcript" | `shaism` | asked, unanswered |
| Fan-out of 7 / 102 / 415 subagents blew the budget | `mcv`, `brianwawok`, `vinnymac` | anecdote |

**This is a question with a real answer that a bench can produce and a forum cannot.** Add
**fork-worker** as a named arm alongside orchestrator-worker, hold the task fixed, and report
grader × tokens × cache-write. Our `fork` is O(1) and content-addressed; we are the cheapest place in
the world to run this experiment. Whatever it says, it is a publishable result and it settles a
question our own architecture currently answers by assertion.

### 3. Cache-sibling preludes for fan-out

If we keep fresh-root subagents, the bootstrap tax is real and it is the single biggest lever in the
thread. But it is not inherent — it is a *layout* problem. Render every subagent's prelude as a
**shared, byte-identical prefix + a differing suffix** (role, task, attenuated toolset). Then a
fan-out of 7 pays **one** cache write and six cache **reads**, instead of seven writes.

This is only available to a harness whose prompt assembly is a pure, deterministic function of
sorted-key canonical bytes — which is to say, it is available to us and not to a harness that
string-builds its system prompt. It also interacts with the 4096-token minimum cacheable prefix
(a *shared* prefix clears the floor that seven small individual ones might not).

Prerequisite: it must survive the role-catalog design, where subagents are **attenuated** subagents
(capabilities, not permissions) — attenuation must therefore live in the **suffix**, never the prefix.
That is a constraint on the toolset renderer, and it is worth writing down before the code exists.

### 4. Tool-call repair as a middleware arm (ACI)

The strongest *practical* thread content, and it is all ACI:

- **`pi-tool-guard`** — corrects key-name synonyms (`old_str` → `oldText`), wraps a bare top-level
  edit in the `edits` array the schema wanted.
- **`pi-smart-edit`** — whitespace-tolerant matching (Qwen adds a fifth space to a four-space indent).
- **`arjie`** — a programmatic repair step on failure; on repair, the harness reports *the error, the
  repaired call, and the result* back to the model. Tool-call failures then decline over time.

Lain has the seam for this already and it is almost embarrassing how well it fits: `Middleware` is a
Rack-idiom **monoid** (property-tested), and `Tool::Input` is ActiveModel — so aliasing, coercion, and
shape-repair are *exactly* what an ActiveModel layer does. A `Middleware::Repair` is a small object
and it becomes an **arm on the existing tool-design axis** (terse / verbose / guardrailed → add
*tolerant*, and *tolerant-and-tattling*, which is arjie's variant where the repair is narrated back).

Metrics we already want: correct-call rate, recovery-from-error, wasted round trips.

⚠️ **Guard against the obvious mistake.** `Tool::Input` validations check **shape, not safety** —
there is a comment at the top of `lib/lain/tool/input.rb` saying exactly this. A repair middleware is
a *shape* accommodation. It must never be reachable by a validator that sounds like a security
control, or we will have quietly built a coercion layer that repairs its way around a check.

**Free negative result, recorded before we build it:** hashline-edit tools *failed* in the field —
"they confused the model and it still failed to edit correctly… Qwen kept thinking that the hashline
prefixes were part of the source," and line removals invalidated the rest of the file, forcing
re-reads. Meanwhile `dirac` (below) claims hash-anchored edits are its headline win. **Contradictory
field reports on an ACI choice is the ideal bench question** — hold the task, sweep the edit tool.

### 5. `lain bench prelude` — the exact decomposition, with no proxy

The article needed mitmproxy and a calibration subtraction. We need a function call. Emit the prelude
broken down by component — system prompt · tool schemas · slots · memory · workspace — in exact
tokens, plus each component's share of the window, straight out of `Context#render`.

Field numbers to calibrate against, all from the thread: tool schemas dominate both harnesses (CC
ships 27 tools / 99,778 chars vs OpenCode 10 / 20,856); a **72KB instruction file cost ~20k tokens
per request**; **five MCP servers cost 4,900–6,967 tokens per request**; users report `/context`
preludes from 15.8k to 33k depending only on what they enabled.

This is a bench command *and* a user-facing feature (see Tier 2), and it is the artifact that makes
our version of the study credible where theirs was not.

---

## Tier 2 — worth doing, smaller or needs a decision

### 6. Dollarize latency, not just tokens

Quesma's "true cost of saying hi" (14 models, 210 trials) found the cost driver was **waiting time,
not tokens** — at $0.016/sec of user waiting, latency exceeded API cost by **20×** on fast models.
Our ROADMAP tracks latency only on the provider axis. Promote **wall-clock-as-cost** to a
cross-cutting bench metric with a configurable $/sec; otherwise every arm that trades latency for
tokens (fan-out, exhaustive exploration, repair round-trips) scores as free when it is not.

### 7. Add a degenerate-prompt fixture: "Hey"

Same source, and it is a *wonderful* bench task because it discriminates violently. On the prompt
`Hi` against a 3-commit repo: 2 tool calls (GPT-5.5) to **49** (Sonnet), 24 on average — with Sonnet
auditing files, running the app, and making an **unsolicited commit**. Haiku and MiniMax *failed* 3/5
runs in exploration loops. A clear task (`commit`) was uniformly cheap (5–10 calls): **the greeting is
harder than the job.**

Our fixtures test whether the harness does the work. This tests whether it knows *not to*. It costs
nothing to add and it will separate the arms.

### 8. A budget lint on the things that multiply

Directly from the field numbers in #5: warn when a slot, a toolset, or an MCP server crosses a
configured share of the window, and attribute the cost **per request** (which is where the 72KB
`CLAUDE.md` turns into 20k tokens × every turn). `iamflimflam1` in the thread: *"A lot of people will
just add as many tools as they can think of. I don't think it's obvious that this costs money."*
Make it obvious. Cheap, user-facing, and it falls straight out of #5.

### 9. Dynamic Context Pruning — as an arm, and as a cautionary tale

[`opencode-dynamic-context-pruning`](https://github.com/Opencode-DCP/opencode-dynamic-context-pruning)
exposes a `compress` tool the *model itself* calls to summarize stale spans, dedupes repeated
identical tool calls keeping only the newest output, and purges failed tool inputs after N turns
(keeping the error text). Reported cache-hit impact: ~85% with, ~90% without.

Two of those three are mechanical and cheap (dedupe-by-identical-args; purge-failed-inputs-keep-error)
and both are natural Timeline projections. The `compress`-as-a-tool idea is a genuine design choice —
*the model decides what to prune* — and belongs as a context arm.

But note what the thread said about its cousin (`verdverm` on Sleev): *"They focused on token
reduction without any real evals for capability impacts… definitely will bust your cache."* **That is
the exact failure our bench exists to prevent.** A pruning arm that reports tokens and not grader
score is not a result. Take the mechanism, take the warning, and score it properly.

### 10. Model is a per-subagent capability, never silently inherited

Claude Code changed its Explore agent to **inherit the session model (capped at Opus)** where it used
to be always-Haiku ([changelog 2.1.198](https://code.claude.com/docs/en/changelog#2-1-198)), and the
thread is full of people discovering this via their bill. Practitioners' fix is always explicit
tiering (`hgoel`: *"assign these tasks to 2 Sonnet, 2 Opus and 1 Fable subagent"*).

We already have an **adaptive router** arm. The design rule this suggests is smaller and separate:
in the role catalog, **model is part of the capability**, defaulted explicitly at the role, and never
silently inherited from the parent. Inheritance is exactly the kind of default whose cost is invisible
until it is a bill.

---

## Confirmations — external validation, no action

These need nothing from us but are worth citing when the bench writes itself up:

- **Compaction summaries invalidate the cache** (`tmalsburg2`: *"you consume less tokens but more
  expensive tokens"*; `dymk`: *"only once per compaction"*). That is precisely the trade-off
  `specs/cache-aware-compaction.md` is built around; the thread validates the premise and the
  soft-defer + hard-cap shape.
- **Cache TTL drifts and is undocumented** (5-min vs 1-hour, different on subscription endpoints,
  [silently changed](https://www.reddit.com/r/ClaudeAI/comments/1sk3m12/followup_anthropic_quietly_switched_the_default/)).
  CAC-2 already models this as a **measured** `Provider#cache_profile` rather than a constant, and
  CAC-3 confirms cold via `cache_read_input_tokens == 0`. Correct call; keep it.
- **Progressive tool disclosure** is now standard practice across harnesses (`mh-`) — our tool
  disclosure axis (upfront-JSON vs deferred/searchable vs code-API) is aimed at the right target.
- **Idle → compact when cold** (TODO.md) is what the thread's cost-conscious users do by hand.
- **Harness quality dominates prompt size** — `GodelNumbering`: *"It is not the raw prompt size that
  matters… What matters even more is tooling quality. Bad/buggy tooling causes a lot more roundtrips
  that wipes out all gains from initial greedy approach."* This is the thesis, stated by a stranger.

## Adjacent work to read (not to adopt)

- [`dirac`](https://github.com/dirac-run/dirac) — **7 agents × 8 real refactoring tasks** (Transformers,
  VSCode, Django), with **published diffs in `/evals`**. Claims 8/8 at $0.18/task, 2.8× cheaper, on
  hash-anchored edits + AST-native transforms + multi-file batching. Self-admittedly non-neutral, but
  it is the closest thing to a competing bench with public traces, and its task set is a candidate
  fixture source. Its central claim (hash-anchoring wins) is contradicted by field reports in the same
  thread — see #4.
- [`minimal-agent.com`](https://minimal-agent.com/), [`maki.sh`](https://maki.sh),
  [pi's system prompt](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/system-prompt.ts)
  (~1k tokens) — the low end of the prelude spectrum; useful as the floor when we plot prelude vs.
  grader score.

## Deliberately excluded

The tokenomics fight (is Anthropic token-maxxing on purpose?) is most of the thread by volume and
none of it by value — it is unfalsifiable from outside, it changes nothing we would build, and the
only defensible response to it is a bench. Which is the point.
