# Prompt caching — server-side mechanics, pricing, and sub-agent economics

A mental model of how Anthropic's prompt cache resolves requests, why the pricing table
looks the way it does, and what each design point implies for Lain. Written 2026-07-13.

> ⚠️ **LLM-generated** (Claude, 2026-07-13) — not an external source. Pricing, limits,
> TTLs, and usage-field semantics come from the Claude API docs as of that date. The
> server-side resolution model (KV-tensor memoization, longest-prefix probing) is
> *inferred* from documented behavior — a mental model consistent with the observable
> facts, not a published architecture.

---

## What is actually cached

The server stores the model's **KV cache** — the attention key/value tensors — for a
prefix of tokens, not the text itself. Prefill (processing the input) computes attention
state for every token; because attention is causal, token N's state is a pure function of
tokens 1..N and the model weights. Two consequences:

1. **Byte-identical prefix ⇒ identical computation ⇒ reusable state.** The server can load
   a stored snapshot for tokens 1..N and start computing at N+1.
2. **Only prefixes are cacheable, ever.** A change at byte 500 changes the attention state
   of every later token. There is no caching a middle chunk and no diffing. Prefix
   stability is math, not product policy.

Corollaries: switching models invalidates everything (different weights ⇒ different
tensors); `tools` render at **position 0** (before `system`, before `messages`), so any
toolset change re-prefills the world.

## Breakpoints

`cache_control: {type: "ephemeral"}` on a content block means *"after prefilling up to and
including this block, take a snapshot."* The cache key is effectively
`hash(model, org, bytes[0..breakpoint])` — org-scoped, whole-prefix. No breakpoint, no
snapshot, no reuse, however repetitive the prompts.

- Max **4 breakpoints per request** (per request — see sub-agents below).
- A breakpoint on the last system block caches tools + system together.
- Render order: `tools` → `system` → `messages`.

## Resolution, hand-wavy server pseudocode

1. Render the request to canonical bytes.
2. Probe the request's breakpoints **longest prefix first**; first hit wins.
3. With a hit covering tokens 1..N:
   - **1..N** → loaded from snapshot → `cache_read_input_tokens` @ 0.1×.
   - **N+1 .. last breakpoint** → prefilled fresh, new snapshots written →
     `cache_creation_input_tokens` @ 1.25× (5-min TTL) / 2× (1-hour TTL).
   - **after the last breakpoint** → prefilled fresh, not snapshotted →
     `input_tokens` @ 1×.
4. No hit: everything up to the last breakpoint is a write; the tail is plain input.

The three usage fields are a **partition of the prompt by where resolution landed**:
read / written / discarded. `input_tokens` alone says nothing about prompt size —
total prompt = the sum of all three (Lain: `Usage#total_input_tokens`).

Read and write compose in one request: turn 5 reads turn 4's snapshot and writes a longer
one. Each turn pays full-ish price only for its own increment — a warm cache turns the
O(n²) resend bill of an agent loop into ~O(n) full-price tokens plus cheap reads.

**20-block lookback:** a breakpoint walks back at most 20 content blocks to find the prior
snapshot. One turn appending 30 tool-result blocks jumps past it and silently misses.
Fix: intermediate breakpoints every ~15 blocks in long turns.

## Why the pricing and limits look the way they do

Seen as a tensor store, none of it is arbitrary:

| Fact | Reason |
|---|---|
| Writes 1.25× (2× @ 1h TTL) | KV tensors are tens of KB *per token*; storage + I/O on top of the prefill you were paying anyway. The 1h premium buys occupancy. |
| Reads 0.1×, not free | Rehydrating the snapshot into a serving node isn't free, just far cheaper than recomputing. |
| TTL, refreshed on read | Eviction policy on expensive storage, not persistence. |
| Minimum cacheable prefix (4096 tokens Opus tier; model-dependent) | Below it, snapshot overhead exceeds the prefill saved; the server silently declines — no error, just `cache_creation_input_tokens: 0`. |
| Max 4 breakpoints | Each is a stored snapshot; the cap bounds storage per request. |
| Concurrent identical requests all miss | A snapshot becomes probe-able only when the writer's response starts streaming; parallel racers all pay full prefill. |

Break-even: 5-min TTL pays for itself on the 2nd request (1.25 + 0.1 = 1.35× vs 2×);
1-hour TTL needs 3+ (2 + 0.2 = 2.2× vs 3×).

**Fan-out trick:** send one request, await its *first streamed token*, then fire the
remaining N−1 — they read what the first just wrote.

## Tools are prompt bytes

The `tools` array (name, description, JSON Schema — what `Tool::Input` generates) is
rendered into the prompt at position 0. Add/remove/reorder/re-serialize a tool and every
downstream snapshot keys differently — total invalidation. Anthropic's tool-search feature
*appends* discovered schemas rather than swapping the list, precisely to preserve the
prefix.

**Bench implication:** a study that varies the toolset per turn is also a study of cold
caches. Comparing tool designs without that confound requires a fixed per-session toolset,
or cost accounting that isolates the invalidation.

## Sub-agents

The 4-breakpoint limit is **per request**, so an agent tree doesn't share a budget — each
agent's requests carry their own four. The *cache* is shared org-wide, so what matters is
whose prefix a spawn's bytes match:

- **Fork-style** (child inherits parent context): probes hit the parent's snapshots; the
  shared prefix reads at 0.1×. Fragile — a cheaper model, one different tool, or a
  prepended "you are a sub-agent" line diverges at position 0 and the child is cold.
- **Fresh-root** (Lain's design): child bytes differ from the parent's from token one; the
  parent's cache is irrelevant — no penalty, no benefit. Each child warms its own cache
  across its own turns. `meta["spawned_from"]` is cache-safe lineage because meta is never
  rendered into the request.
- **Siblings**: children spawned from one template (same toolset + system prompt) share a
  prefix *with each other* — one 1.25× write, N−1 reads at 0.1×. Two caveats:
  1. the concurrency race above — stagger the first spawn or all N pay full prefill;
     Lain owns the loop, so the staggering is ours to implement and measure;
  2. per-child task content must land *after* the template's breakpoint — a task
     interpolated into the system prompt makes every child unique and the fleet shares
     nothing.

Spawn-strategy cache economics are therefore an experimental variable: **which prefix does
a spawn share (parent's / siblings' / nobody's), and does orchestration stagger the first
request?** Both show up directly in `cache_hit_ratio` per child, and fresh Timeline roots
keep child costs separable under unique-digest aggregation.

## Silent invalidators (audit list)

Anything that perturbs prefix bytes with no error, only a decaying `cache_hit_ratio`:

- timestamps / UUIDs / request IDs interpolated early in system or tools
- non-deterministic serialization (unsorted JSON keys, `Set` iteration) — `Canonical`'s
  sorted-key dump is the standing defense
- conditional system sections (every flag combination is a distinct prefix)
- per-user tool sets (nothing caches across users)
- model or toolset switches mid-session

## Lain mapping

| Lain piece | Caching role |
|---|---|
| `Canonical` | Deterministic bytes ⇒ stable cache keys. One function, two invariants (hashing + cache). |
| `Context#render` purity | Purity and cache-hit are the same constraint: same (Timeline, Toolset, Workspace) ⇒ same bytes. |
| `Usage` (`usage.rb`) | The four wire token classes; `total_input_tokens` sums the input partition. |
| `Usage#cache_hit_ratio` | First-class bench metric; a silent invalidator is a ratio decaying to zero with nothing erroring. |
| `PriceBook` (`price_book.rb`) | Four per-token `BigDecimal` rates; cache multipliers encoded relative to family input price. |
| `anthropic_encoding.rb` | Single `EPHEMERAL` flavor — assumes 5-min TTL throughout. |

Two known gaps (observed 2026-07-13, deliberately not yet changed):

1. **`PriceBook::DEFAULTS` are stale for current models** — `opus => 15/75` is
   Opus-4.1-era (Opus 4.8 is $5/$25; cache write $6.25, read $0.50); `haiku => 0.8/4` is
   Haiku 3.5 (Haiku 4.5 is $1/$5). Sonnet 3/15 matches. Defaults are documented as
   override-me, but bench runs against Opus/Haiku 4.5 on defaults overstate ~3× /
   understate ~20%.
2. **`Price` has a single `cache_creation` rate** — fine while `EPHEMERAL` is the only
   flavor; comparing 1-hour-TTL strategies would need the 2× write rate as a second field
   or a second `Price`.
