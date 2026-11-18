# Compaction internals

How a compacting turn derives a second timeline. The user-facing knobs are in
[docs/users/compaction.md](../users/compaction.md).

## Two lineages

Compaction does not rewrite the message array. Every compacting turn of every `lain chat`, flagged
or not, builds a **derived context timeline**: a second lineage of `Event`s, materialized in
the session's own content-addressed `Store`, whose replacement events name the source turns they
subsume via `causal_parents`. That derived chain's projection is substituted as the rendered
messages, and it is what the provider sees.

The session timeline stays the lossless record. Its head advances only by committed turns, and the
derivation never touches it. `Timeline#to_a` follows `render_parent` only, so a replacement can name
every digest it subsumes without the render walking the turns it replaced. `Ledger` aggregates
over render ancestry, so the causal fan-in double-counts no tokens.

Compaction thus becomes a comparable artifact: it has a content address and it is
diffable. One `context_derived` journal edge per derivation carries `source_head`, `derived_head`,
`strategy`, `spans`, `cut`, `moved` and `keep_last`. That is enough for `Compaction::DerivationAudit`
to re-derive the chain and skip diffing a copy of it.

Few edges are re-derivable, so check before you reach for the audit:

- It re-derives an unpinned `--compact-strategy elide` run. That run is deterministic, and the edge
  names a strategy you can hand it a builder for.
- It does not re-derive the un-flagged default. That edge names `Source::Derived::Held`, a
  `private_constant` whose collapse reads a per-turn `SummarySnapshot` that is never journalled, so
  nothing shipped can build it.
- `ContextDerived` carries no pin set, so a pinned run re-derives different ranges and the audit
  reports drift that nobody introduced.
- The audit is a library reader today, with no `lain` subcommand in front of it.

`--compact-strategy` selects which policy collapses a span. It does not decide whether the derivation
runs. Unset, the policy is the run's own eager tool-result tier: the tier-1 summaries, read back
through the per-turn `SummarySnapshot`. With nothing pinned it emits the same `user` message, with the
same text, that `Context::Compact` produced through that same snapshot, so moving the render onto the
derived chain did not retire the tool-result summarizer ladder. Naming a strategy substitutes an
operator-chosen policy instead.

The eager tier is the control arm, and the flag is the arm under test. The flag carries no Thor
default: a default would materialize the key, so the reader could never see that no strategy was
named, and nobody could select the control arm.

`Context::Compact` is still in the tree and is a bench-only combinator: nothing on the chat
render path composes it. Its 2 remaining production callers are `Bench::PlanSweep::Driver` and
`Plan::CompactRewrite`, and those are one caller under 2 names. The rewrite is built only by
`Plan::LinearRewrite`, which is built only by that same driver. It is an arm to compare against and
is not the shipped path.

Pins behave differently on the 2, so decide before you pin across a tool call:

| | `Context::Compact` (bench arm) | derived chain (every chat) |
|---|---|---|
| pinned `tool_use` whose answer is collapsed | ships the 400: the projection strands a `tool_result`, characterized in `spec/lain/context/compact_spec.rb` as a known defect | refuses: validates its own projection through `Context::Conversation`, raises `Derivation::Invalid`, renders the full uncompacted history, journals `derivation_refused`. The chain is judged from the pending writes, so a refusal touches neither the provider nor the `Store`. |
| placement of a pinned turn | one summary, with the pin kept in position around it | pins are cut points: one range per contiguous unpinned run, so the pin sits between 2 replacements, giving `keep_last + 3` messages where `Compact` gave `keep_last + 2` |

Refusing does not repair the history. A session pinned across a tool pair stops compacting for as long
as the pin stands, which the `consecutive` streak on `derivation_refused` makes visible. The real
repair is a decision about what a pin means (drag the counterpart along, or drop it with the pin),
and that is outside the compaction path.

## Cost of a turn

A derivation writes about 22 store objects, constant in history length: the derived
chain is bounded by `keep_last` plus the number of ranges, never by how long the session is. Time is
O(n), since it walks the chain and projects every message before it can find the span, but with a
much smaller constant than the projection it replaced, because it never `Canonical.dump`s the whole
history.

Measured on this branch at `keep_last: 20`, it crosses under that projection somewhere
between 100 and 150 messages (1.6 ms vs 1.0 ms at 100; 2.5 ms vs 10.2 ms at 800), with 22 objects at
every size.

A deferring turn (no signal, bad timing, an empty head) writes 0 store objects,
journals no edge, asks the strategy nothing, and returns the base `Context` itself. Two defers are not
free, and both are reached only after the strategy has been asked:

- a `refused` decision, where the derivation has already run and journalled its edge by the time the
  rewrite is measured and declined,
- a refusal, which under `--compact-strategy summarizing` has already paid a live model call for
  a summary it then throws away.

## Failure modes

| On the record | What it means |
|---|---|
| `derivation_refused` | This turn rendered uncompacted. One is an awkward history. |
| a rising `consecutive` on it | The session has stopped compacting. A deterministic strategy over a stable history refuses identically every turn, so the streak is the only thing that tells one awkward turn from 40. Under `--compact-strategy summarizing` it is also a running bill: the memo is keyed by span content address, so a session that keeps chatting asks for, and discards, a fresh summary every turn. Watch the `oracle_answer` records beside it. |
| `compaction_decision` with `refused: "inflates"` | The rewrite was declined because it would not have made the prompt strictly smaller. A byte-neutral rewrite is declined too, since it buys nothing and still breaks the cache prefix. |
| `compaction_decision` with `refused: "below_floor"` or `"cache_break_unpaid"` | The rewrite would have saved under 10% of its own size, or, on a warm cache with a live plan, less than the cache break costs over the plan's remaining requests. An approaching window or the hard cap skips both. |
| a `stderr` line attributed to `lain:compaction` | A `--compact-strategy summarizing` tier was unreachable, so that span was left uncollapsed. It costs the span and never the turn. The id is namespaced so a journal or nvim reader can filter it from real tool output. |

## Not built

Derivation is non-recursive: every chain is a function of the session timeline alone, never of a
previous derived chain, which keeps the derived head a pure content address of (source head,
strategy). There is no incremental extension and no `Derivation#extend`.

The derivation is not a functor on the prefix order (`T1 <= T2` does not imply
`derive(T1) <= derive(T2)`, because `Event#payload` folds `render_parent` and the `keep_last` window
slides), and a characterization spec fails if someone "fixes" that.

Hierarchical derivation, the deterministic plan-step collapse, exchange-level grouping, and retiring
`Context::Compact` are all designed and not built.
