# Spec — Cache economics

> Status: `[exp]`, specced 2026-07-13 — except **CE-1, which is a bug fix in built code** and goes
> in the near-term sequence. Grounded in `references/prompt-caching-mechanics.md` (the resolution
> mental model; ⚠️ LLM-generated, provenance noted there) and
> `planning/hn-harness-overhead-2026-07.md` (Tier-1 items #1–#3, #5–#6). Companion to
> `cache-aware-compaction.md` (the compaction-side policy), `orchestration-model.md` (OM-2/OM-3/OM-5),
> and `event-schema.md` (which this spec deliberately does *not* extend). Unit IDs `CE-<n>`.

## The premise

Anthropic's cache memoizes prefill KV-state keyed by `(model, org, exact prefix bytes)`; the three
input usage fields are a **partition of the prompt by where resolution landed** — read (0.1×) /
written (1.25×, 2× at 1-hour TTL) / discarded (1×). Two consequences drive every unit below:

1. **Cache-write, not cache-hit, is where money leaks.** A harness can hit 90% and still bleed on
   re-writing the other 10% at the premium (the HN article's real finding: 53,839 vs 1,003
   cache-creation tokens on identical tasks). `cache_hit_ratio` alone hides this.
2. **Whose prefix a request shares is a layout decision**, and for sub-agents it is a *strategy*
   (parent's / siblings' / nobody's) that lain currently fixes by architectural assertion.

## CE-1 — Breakpoint budget: cap at 4, one layer owns placement `[bug]`

Anthropic rejects requests with more than **4** `cache_control` blocks. Today nothing caps the
count, and **two layers place breakpoints without seeing each other's marks**:

- `Context::CacheBreakpoints` marks the last block + one every ~15 blocks — unbounded on a long
  timeline.
- `AnthropicEncoding#with_stride_breakpoint` independently adds `cache_control` every 15 absolute
  blocks, with a comment deferring the cap to "a Context-layer concern" that the Context layer
  doesn't implement. The combinator's own comment says it is "the relocated body" of the old
  Context method — the encoder stride is a leftover.

A session long enough to accumulate >4 markers 400s. Fix in two moves:

1. **Encoder becomes pure translation.** Delete `with_stride_breakpoint`; `AnthropicEncoding`
   renders `"cache" => true` and adds nothing of its own. Placement is policy; the Provider
   translates.
2. **`CacheBreakpoints` takes the whole budget.** Parameterize `cap:` (default 4) and account for
   the system-block marker (`Context#cache_marked_system` spends 1 of the 4, leaving 3 for
   messages). Placement is **tail-clustered**: keep the last block plus the most recent
   intermediates within budget; *drop the oldest*. Dropping old markers is safe — on a miss the
   write at the earliest retained marker covers the entire prefix before it; the cost of dropping
   is only partial-hit granularity, which makes exact placement a sweepable parameter, not a
   correctness question.

**Acceptance:** a rendered `Request` never carries more than `cap` neutral markers across
system + messages; `AnthropicEncoding` emits `cache_control` only where a neutral marker is; the
raw-vs-SDK dry differential still passes; a spec renders a >100-block timeline and counts ≤4.

## CE-2 — Request digest chain: rewrite attribution mirrors `diverge_at`

The HN Tier-1 metric is cache-**write** attribution: count prefix rewrites and their **depth**, and
name the turn that broke the prefix. `Request#cache_prefix` (tools+system) bisects at one boundary
only. Extend `Request` with a **per-breakpoint digest chain**: `Canonical.digest` of the canonical
bytes up to each neutral marker, in order — a small vector of digests, computed from bytes lain
already renders.

The Journal records the chain per model call (alongside the usage it will record for
`Agent::Accounting`). Then, entirely offline:

- **rewrite event** = consecutive calls whose chains differ before the tail;
- **rewrite depth** = index of the longest-common-prefix of the two chains;
- **attribution** = the turn whose bytes sit at that index.

This is `diverge_at` recreated at the request level — the Timeline's Merkle structure mirrored over
the breakpoint-partitioned prompt — and it extends `Canonical`'s "one function, two invariants" to
its natural end. Nothing in the HN thread could attribute a rewrite; the article could only observe
the bill.

**Acceptance:** `Request#prefix_digests` returns one digest per marker, deterministic for identical
inputs; the Journal carries the chain per call; a bench projection over a recorded session reports
rewrite count + depth and names the breaking turn; `Compare` can surface `cache_write_tokens`
per arm.

## CE-3 — Byte-identical prelude is an invariant with a spec

`Canonical` claims cache stability as its second invariant; it has never had a test. Add the spec
from the HN doc: render the same `(Timeline, Toolset, Workspace)` **twice, in two processes**, and
assert byte-identical `Request` bytes (and equal `prefix_digests`). A few lines, and it forecloses
the entire silent-invalidator failure mode the article documents.

**Acceptance:** a spec spawns a subprocess, renders the same committed fixture in both, and asserts
equal canonical bytes; it fails loudly if any `Time.now` / unsorted-key / per-process value leaks
into the render path.

## CE-4 — Spawn prefix strategy is an axis, not an architectural constant

The plan fixes **fresh-root** ("Subagents get a fresh Timeline root"). The caching model says there
are three cache-sharing regimes, and the HN thread argues about exactly this, at length, with no
data:

| Strategy | Cache relation | Buys | Costs |
|---|---|---|---|
| **fresh-root** | shares nobody's prefix | context isolation, no pollution | full bootstrap per child |
| **fork** | shares the **parent's** prefix (reads it at 0.1×) | warm prefix, zero re-discovery | pollution/distraction |
| **sibling-template** | children share a template prefix **with each other** (1 write + N−1 reads) | isolation *and* amortized bootstrap | layout constraints (below) |

This axis is **orthogonal to OM-2/OM-3's lifecycle axis** (one-shot vs actor): spawn strategy is
`(one-shot | actor) × (fresh-root | fork | sibling-template)`. OM-2 already hints at it
(`:fresh` / `:inherit`); make it a named, injected policy at the spawn seam so **fork-worker** and
**cache-sibling fan-out** become orchestration arms, not rewrites. Everything needed is cheap:
`Timeline#fork` is O(1) and `Context#render` purity makes a forked child's prefix byte-reproducible
by construction.

Sibling-template layout constraints (from the caching model):

- the shared template must clear the **minimum cacheable prefix** (4096 tokens on the Opus tier) —
  a shared prefix clears a floor that N small individual preludes might not;
- per-child content (task, role fill) must land **after** the template's breakpoint;
- **toolset attenuation is the hard case** — see the open question below.

**Acceptance:** spawn strategy is a policy object selected per spawn; the three strategies render
through the same `Context` seam; a `Compare` run over a fixed fan-out task reports
grader × tokens × cache-write per strategy. Whatever it says, it is a publishable result — and it
settles a question the architecture currently answers by assertion.

## CE-5 — First-token signal for stagger scheduling

A cache entry becomes probe-able only when the writing request's response **begins streaming**.
Fan out N siblings simultaneously and all N pay full prefill; the fix is to release sibling 1,
await its *first streamed token*, then release the rest. Lain owns the loop, so this scheduling
is ours — but it needs a signal: the Provider emits an attributed **`stream_started`** event on
the **Channel** when the first token of a response arrives.

Deliberately **not** a Store event: the event-schema's closed kind set
(`:turn · :spawn · :message · :snapshot`) records durable history; `stream_started` is a transient
scheduling signal, which is exactly what the Channel is for. No change to `event-schema.md`.

**Acceptance:** both Anthropic backends emit `stream_started` at first token; an orchestration
policy can await it; a staggered fan-out fixture shows 1 write + N−1 reads where the unstaggered
control shows N writes.

## CE-6 — The cost model prices what actually varies

Three gaps, all in `PriceBook`/bench scoring:

1. **`Price` has one `cache_creation` rate** — correct while `EPHEMERAL` (5-min TTL) is the only
   flavor lain emits; comparing 1-hour-TTL strategies needs the 2× write rate as a second field (or
   a `Price` per TTL). Do this when a TTL arm exists, not before.
2. **`DEFAULTS` are stale** — `opus => 15/75` is Opus-4.1-era (Opus 4.8 lists $5/$25; write $6.25,
   read $0.50); `haiku => 0.8/4` is Haiku 3.5 (4.5 lists $1/$5). Sonnet matches. One-line edits,
   version-controlled, exactly as the file intends.
3. **Wall-clock is a cost dimension** (HN Tier-2 #6: at $0.016/sec, latency exceeded API cost 20×
   on fast models). Add a configurable $/sec to bench scoring so arms that trade latency for tokens
   (fan-out, repair round-trips, exhaustive exploration) stop scoring as free. A scoring concern in
   `Compare`, not a `Usage` field.

**Acceptance:** defaults match current list prices with the source dated in a comment; `Compare`
can report dollars = token-cost + $/sec × wall-clock when configured.

## CE-7 — `lain bench prelude`: the decomposition, with no proxy

The article needed mitmproxy and a calibration subtraction; lain needs a function call. Emit the
prelude broken down by component — system prompt · tool schemas · slots · memory · workspace — in
exact tokens plus share-of-window, straight out of `Context#render`. The **pipeline combinators are
the attribution unit**: each stage reports its contribution (render with/without a stage and diff,
or tag provenance per stage). Deliberately *not* a `prelude`/`payload` split in `Request` — the
digest chain (CE-2) already names the stability boundaries; don't add a second representation.

Follow-on (HN Tier-2 #8, not a unit yet): a budget lint that warns when a slot / toolset / MCP-like
component crosses a configured share of the window, priced **per request**.

**Acceptance:** `lain bench prelude` (or `Bench::Prelude`) prints the component table for a
committed fixture at zero API cost; numbers sum to the rendered prompt's token count.

## Interdependency map

```
CE-1 cap fix (bug) ────────────► unblocks honest long-session runs (everything below)
CE-2 digest chain ──► Journal ──► rewrite count/depth/attribution ──► Compare cache-write column
CE-3 prelude invariant spec ───► guards CE-2/CE-4 layouts against silent invalidators
CE-4 spawn axis ──► OM-2/OM-3 (lifecycle × prefix) ──► fork-worker + cache-sibling arms
                └──► open question: attenuation at schema vs Handler (OM-5, position-0)
CE-5 stream_started (Channel) ──► stagger policy ──► CE-4 sibling arm measured fairly
CE-6 price model ──► Compare dollars column honest (TTL write rate · fresh defaults · $/sec)
CE-7 prelude decomposition ──► budget lint; the credible version of the HN study
```

## Open questions

- **Attenuation ↔ position-0.** Roles are attenuated subagents, but tools render at position 0 —
  per-role schemas give every role a different byte-0 prefix and forfeit all sibling sharing.
  Schema-level attenuation (model sees less; cache pays) vs Handler-level enforcement over a union
  schema (cache shares; model can *attempt* disallowed tools and be refused). Itself benchable:
  does schema attenuation's behavioral benefit exceed its measured cache cost? Owned jointly with
  OM-5; recorded in `orchestration-model.md` open questions.
- **Placement policy shape.** Tail-clustered is the safe default (CE-1); whether an *adaptive*
  policy (marker density following turn size, or TTL-aware placement per
  `cache-aware-compaction.md`'s measured `Provider#cache_profile`) beats it is a sweep, not a
  design argument.
- **Chain cost.** `prefix_digests` re-hashes the prefix per marker (≤4 hashes of shared bytes);
  if profiling ever shows it hot, blake3's incremental hasher makes it one pass — a note for the
  `ext/lain` port, not a Ruby concern.
