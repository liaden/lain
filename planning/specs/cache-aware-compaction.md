# Spec — Cache-Aware Compaction

> Status: `[exp]`, specced. A **scheduling policy** on the `Compact` combinator (3c-2.3), not a new
> combinator. Companion to `ROADMAP.md` (M3c) and `remaining-work.md` (3c-2.3 `Compact`, 3c-2.4
> `CacheBreakpoints`). Unit IDs `CAC-<n>`.

## What it is

Compaction that fires **only when the prompt cache is already cold**, so the rewrite is free — you
were going to re-pay full input price on the next turn regardless. It separates two decisions that
are usually conflated: **whether** compaction is *needed* (a size/cost/structure signal) and **when**
it should *run* (a cache-timing policy).

## The caching facts this rests on (verified via the `claude-api` skill)

- **TTL is a sliding window refreshed on use.** Default **5 min**; optional **1 h** (`ttl: "1h"`).
  Each cache hit resets the timer; after the TTL elapses with no use the entry expires and the next
  request re-writes it. "Cache cold" = "time since last API call > the model's TTL."
- **Costs:** writes **1.25×** base input (5-min) / **2×** (1-h); reads **~0.1×** base input.
- **Minimum cacheable prefix is per-model:** Opus 4.8/4.7 **4096**, Fable 5 / Sonnet 4.6 **2048**,
  Sonnet 4.5 **1024**. Below it, nothing caches (silently).
- **Caching is tiered — `tools → system → messages`.** Compaction rewrites only the *messages*, so it
  invalidates **only the message cache tier**; the cached `tools`+`system` prefix survives. Compacting
  while warm costs a message-tier rewrite, *not* a full-prompt rebuild.
- **20-block lookback:** a breakpoint walks back ≤20 blocks; agentic turns blow past it. Compaction
  shrinks block count, which *helps* keep breakpoints findable (ties to 3c-2.4).
- **Per-provider:** OpenAI-compatible backends use automatic caching with different mechanics — so the
  cache profile must be a **Provider capability**, not a constant.

## Design (from the interview)

- **Need signals** (any triggers "compaction needed"): context-size / token threshold · approaching
  the model's context window · manual / on-demand · **plan-step or phase completion** — a finished
  plan step is a natural boundary whose detail can be summarized. *(Not* a cost-per-turn ceiling.)
- **Cold detection:** time-based — idle since the last API call > the provider's TTL — **confirmed**
  signal-based by `cache_read_input_tokens == 0` on the next response. Provider-parameterized.
- **Need but warm → soft-defer + hard cap:** while the cache is warm and history is below a hard
  ceiling, *defer* (don't waste the cache). Crossing the hard cap (approaching the window) forces
  compaction even while warm — and that forced rewrite hits only the message tier, so the penalty is
  bounded.
- **Proactive idle, but prepare-once-apply-on-resume:** on a long idle (cache already cold), *compute*
  the compacted summary once and **hold** it; do **not** send it until the session resumes. Guard
  against repeated idle ticks recomputing — the held compaction is idempotent, keyed on the timeline
  head digest; if the timeline advanced, recompute, else reuse. This avoids "idle → compact → idle →
  compact" churn.

## Units

- **CAC-1 — Need-signal detector on `Compact`.** Marks "compaction needed" (without executing) on any
  of: token threshold, approaching-window, manual, **plan-step completion** (via a Workspace/`Tool::Todo`
  hook, 5-2). *Builds on:* 3c-2.3. **Acceptance:** each signal sets the need flag without running
  compaction; a completed todo/plan-step raises it.
- **CAC-2 — Provider cache profile.** `Provider#cache_profile` → `{ttl, min_prefix_tokens,
  write_multiplier, read_multiplier, tiered_invalidation}`. *Builds on:* `Provider::CAPABILITIES`.
  **Acceptance:** Anthropic-Opus reports 5-min sliding TTL + 4096-token min; an OpenAI-compatible arm
  reports its own; the scheduler reads it rather than a constant.
- **CAC-3 — Cold detection.** Deem cold when idle > `cache_profile.ttl`; **confirm** via
  `cache_read_input_tokens == 0`. **Acceptance:** after idle > TTL the scheduler marks cold; a later
  response with `cache_read == 0` confirms and is journaled; a warm hit cancels a pending
  cold-compaction.
- **CAC-4 — Soft-defer + hard-cap policy.** Defer while warm and below the cap; force on cap /
  approaching-window even while warm. **Acceptance:** a needed compaction with a warm cache below the
  cap does not run; crossing the cap runs it and the journal notes "forced-warm, message-tier only."
- **CAC-5 — Prepare-once-apply-on-resume.** On idle-cold, compute the summary once, hold it keyed on
  the head digest; reuse on repeated idle ticks; apply on the next real turn; recompute if the head
  advanced. **Acceptance:** two idle ticks with no new turns produce exactly one summarization call;
  the held compaction applies on resume; a new turn between ticks invalidates and recomputes.
- **CAC-6 — Journaling.** Every compaction records trigger, cache-state (warm/cold/forced), tokens
  before/after, and cost saved vs. spent (via the M2 `Ledger`/`PriceBook`). **Acceptance:** the event
  carries all fields; `Compare` can attribute cost deltas to the policy.

## Relationship to other work

- **3c-2.3 `Compact`** — this is its scheduler; the summarization mechanism is 3c-2.3's.
- **3c-2.4 `CacheBreakpoints`** — supplies the cache-line/lookback awareness CAC-3 and the hard cap use.
- **PS-4 (prompt slots)** — the user's `.lain/slots/compaction.md` steers *how* the summary reads;
  this spec governs *when* it runs. Coordinate.
- **Server-side compaction (5-4.2)** — Anthropic's beta `compact-2026-01-12` is the **comparison arm**:
  cache-aware client-side compaction vs. server-side, measured by `Compare` (grader, tokens, cache-hit).
- **`plan-shaped-compaction.md`** — when a plan exists, its declared seams *schedule* compaction
  proactively (subsuming CAC-1's plan-step trigger); this spec remains the reactive layer between
  seams and the whole policy when no plan exists. The hard-cap safety net (CAC-4) still guards
  mis-estimated chunks.

## Open questions

- **Idle-prepare cost.** The prepare step is itself a summarization call that costs tokens; if the user
  never returns, it's wasted. Mitigate: only prepare after a *long* idle where a next turn is likely,
  or run the summary on the **local-model meta-tier** (ollama arm, M3b) so idle-prepare is cheap and
  private.
- **1-h TTL arm.** Is the 2× write premium ever worth the longer warm window for Lain's usage? A swept
  parameter, not a fixed choice.
- **Cross-provider cold semantics.** OpenAI-compatible automatic caching has no explicit TTL to read —
  fall back to time-based-only cold detection there, or rely solely on the `cache_read == 0` signal?
