# The Rust `Timeline`/`Store` parity gap

> Grounding for the wiring chunk ROADMAP item 23 files. Every claim below was read out of the
> code or run against the built `lib/lain/lain.so`; `file:line` is given for each. Line numbers
> are as of `cc76ea4`. Written 2026-07-29 alongside
> `planning/reviews/2026-07-29-simplification-review.md` §10.2, which found the gap; this doc is
> the method-by-method version.

## The question is not optionality

`lib/lain.rb:77` requires the compiled extension **unconditionally** — `require "lain/lain"`,
with no rescue and no feature flag. Delete `lib/lain/lain.so` and the whole library fails to
load; there is no degraded mode. So "is the extension present" was never the question. The
question is **which implementation a caller gets**, and that is a design decision about a seam,
not a build-time capability check.

That framing matters because it rules out the shape a reader might expect — a `Timeline.for(...)`
that probes for Rust and falls back. There is nothing to fall back *from*. What a wiring decision
has to produce is a named seam that both implementations satisfy, and a rule for who chooses.

Today no such seam exists. `Timeline` is constructed directly at **16 sites across 12 files**:

| File | Lines |
|---|---|
| `lib/lain/agent.rb` | 88 |
| `lib/lain/arm/orchestrator_worker.rb` | 63, 132 |
| `lib/lain/bench/decider_sweep/arms.rb` | 141 |
| `lib/lain/bench/live_replay.rb` | 76 |
| `lib/lain/bench/plan_sweep/driver.rb` | 103, 113, 135 |
| `lib/lain/bench/session/loader.rb` | 171 |
| `lib/lain/compaction/derivation.rb` | 124 |
| `lib/lain/compaction/derivation_audit.rb` | 318 |
| `lib/lain/frontend/neovim/buffers.rb` | 119 |
| `lib/lain/frontend/neovim/inbox_view.rb` | 99 |
| `lib/lain/plan/seam_policy.rb` | 43 |
| `lib/lain/tool/spawn_policy.rb` | 72, 151 |

(Three further mentions are prose in comments and are excluded: `consolidation.rb:112`,
`algebra/meet_semilattice.rb:28`, `cli/improve.rb:181`.) The split is **twelve `Timeline.empty`
to four `Timeline.new(head_digest:, store:)`** — the four `.new` sites being
`compaction/derivation_audit.rb:318`, `plan/seam_policy.rb:43`, `frontend/neovim/buffers.rb:119`,
and `frontend/neovim/inbox_view.rb:99`. Eleven of the twelve `.empty` calls pass `store:`; the
twelfth, `bench/plan_sweep/driver.rb:135`, is bare `Timeline.empty` and mints its own Store.

A swap has to reach all sixteen, which is why the ruling for the current chunk (ROADMAP item 20)
is that the bindings stay unwired: naming the seam is its own piece of work.

## What agrees today

Worth stating first, because it is the part that makes the port a port rather than a rewrite.

- **Digests match.** The same `(role, content)` committed onto an empty timeline yields a
  byte-identical `head_digest` from `Lain::Timeline` and `Lain::Ext::Timeline` — run against the
  built `.so`. `Canonical` already depends on Rust for hashing (`canonical.rb:60` calls
  `Ext.blake3_hex`), so this is the one place production and the shadow implementation already
  meet.
- **Both are `Ractor.shareable?`.** `Ractor.shareable?` is `true` for a `Lain::Event` and for a
  `Lain::Ext::Turn` alike — the `frozen_shareable` promise in `ext/lain/src/lib.rs:783` holds in
  practice, which is the acceptance test `ext/lain/CLAUDE.md` sets for the port.
- **The law suites are shared.** `spec/lain/rust/timeline_spec.rb` runs the same
  `meet_semilattice` and `regular` groups `spec/lain/timeline_spec.rb` does, unchanged.

## Ruby ↔ `Lain::Ext`, method by method

### `Timeline`

`Lain::Timeline.instance_methods(false)` against `Lain::Ext::Timeline.instance_methods(false)`:

| Method | Ruby | Ext | Note |
|---|---|---|---|
| `.empty(store:)` | ✅ | ✅ | the only *own* class method on either (`methods(false)` → `[:empty]`). Ruby's singleton also carries `meet_semilattice` / `not_a_meet_semilattice`, extended in from `Algebra::MeetSemilattice::ClassMethods`; Ext has no such declaration |
| `#commit` | `(role:, content:, meta: {}, causal_parents: [])` — `timeline.rb:66` | `(role:, content:, meta:)` — `lib.rs:1150-1155` | **gap, see below** |
| `#head` / `#head_digest` / `#store` | ✅ | ✅ | |
| `#fork` / `#checkout` / `#rewind` | ✅ | ✅ | |
| `#ancestors` | Enumerator **or block** — `timeline.rb:96-105`, `yield` at `:102` | Array only — `lib.rs:1280` | **gap, see below** |
| `#to_a` / `#ancestor_digests` / `#length` | ✅ | ✅ | Ext returns Arrays, Ruby returns Arrays built off the Enumerator |
| `#include?` / `#ancestor_of?` / `#empty?` | ✅ | ✅ | |
| `#meet` / `#&` | ✅ | ✅ | the semilattice both suites prove |
| `#diverge_at` | ✅ | ✅ | |
| `#==` / `#eql?` / `#hash` / `#inspect` / `#to_s` | ✅ | ✅ | |
| `#causal_meets` | ✅ | ❌ | the set-valued TL-3 primitive |
| `#dominator_meet` | ✅ | ❌ | the checkpoint primitive TL-3 added |
| `#correlation` | ✅ | ❌ | Ext stamps a correlation internally (`lib.rs:1162`) but exposes no reader on the Timeline |

`Lain::Timeline` also carries four nested units with no Ext counterpart: `CausalAncestry`,
`Dominators`, `CrossStore`, `ClassMethods`.

### `Store`

Both expose exactly `put`, `fetch`, `key?`, `size`. The agreement is in the names only.

| | Ruby (`lib/lain/store.rb`) | Ext (`ext/lain/src/lib.rs`) |
|---|---|---|
| `#put` argument | any object answering the edge ducks — `store.rb:33`, `#parent_edges` at `:70` | `&Turn`, statically — `lib.rs:1007` |
| Validated edges | `parent`, `render_parent`, **`payload_digest`**, `causal_parents` — `store.rb:71-75` | `parent` and `causal_parents` only; `payload_digest` deliberately absent — `lib.rs:174-177` |
| Lock | `Monitor` (reentrant) — `store.rb:20` | `std::sync::Mutex` (not reentrant) — `lib.rs:958` |
| Objects per turn | **2** (payload then envelope) — `timeline.rb:72-73` | **1** (payload inline) — `lib.rs:1171` |

### `Event` ↔ `Ext::Turn`

`Ext::Turn` answers `kind`, `role`, `content`, `meta`, `parent`, `render_parent`,
`causal_parents`, `correlation`, `payload`, `payload_digest`, `digest`, `root?`. `Lain::Event`
answers all of those plus `from`, `to`, `body`, and `carried_payload`.

The deeper gap is that `Event::KINDS` is `%i[turn spawn message snapshot]` while the only
constructor `Ext::Turn` exposes builds `kind == :turn` — the **Symbol**, on both sides
(`lib.rs:828` calls `EventData::turn`; verified `t.head.kind.inspect` → `:turn`, a `Symbol`).
`spawn`, `message`, and `snapshot` events — which `Event::ChainWriter` writes and which the
mailbox, subagent lineage, and Workspace snapshot paths all depend on — have no Ext
representation at all.

## The four gaps, in the order they would bite

### 1. `Ext::Store#put` is monomorphic; production stores seven kinds

`Ext::Store::put` takes `turn: &Turn` (`lib.rs:1007`), so magnus refuses anything else at the
boundary. Verified: `store.put("x")` raises `TypeError: no implicit conversion of String into
Lain::Ext::Turn`.

The Ruby `Store` is duck-typed on purpose — `store.rb:70`'s `#parent_edges` asks
`respond_to?` for each edge — and production puts **six kinds other than `Event`** into one:

| Kind | Defined | Put at |
|---|---|---|
| `Event::Payload` | `lib/lain/event/payload.rb:17` | `timeline.rb:72`, `event/chain_writer.rb:71`, `bench/session/message_replay.rb:50` |
| `Workspace::Snapshot::Blob` | `lib/lain/workspace/snapshot.rb:60` | `workspace/snapshot.rb:145`, `supervisor/restart.rb:146` |
| `Plan::Closure` | `lib/lain/plan/closure.rb:44` | `plan/closure.rb:154` |
| `Plan::Supersession` | `lib/lain/plan/seam_policy.rb:74` | `plan/fork_per_step.rb:82` |
| `Memory::Item` | `lib/lain/memory/item.rb:12` | `memory/index.rb:78` |
| `Memory::Index::Node` | `lib/lain/memory/index.rb:30` | `memory/index.rb:80` |

A Store swap is therefore not a Timeline-only change. Either the Ext store grows a generic
content-addressed node type, or the two stores stay separate objects and the seam is drawn at
`Timeline` with the other six kinds staying in a Ruby store — which then has to be reconciled
with `Ledger` aggregating over unique reachable digests across whatever store holds them.

### 2. `Ext::Timeline#commit` has no `causal_parents:`

`lib.rs:1151-1155` declares required `role`/`content` and optional `meta`, and `lib.rs:1169`
hard-codes `Vec::new()` for the causal set. Verified: passing the keyword raises
`ArgumentError: unknown keyword: :causal_parents` — **loudly**, which is the good failure mode.

Four `lib/` sites pass it literally, and a fifth splats it in:

- `lib/lain/agent.rb:279` — `causal_parents: inbox.folded`, the mailbox fold that marks messages
  consumed. This one is the chat path.
- `lib/lain/compaction/derivation.rb:190` — `Event#onto`, how a derived replacement event names
  the source events it subsumes. This is the shipped compaction design.
- `lib/lain/arm/synthesis.rb:55` — the fan-out arm's synthesis turn.
- `lib/lain/bench/session/chain_fold.rb:80-81` — replaying a recorded session's cited parents.
- `lib/lain/agent.rb:362` splats `@tool_runner.delivery(...)`, which returns
  `{ content:, causal_parents: answered_questions }` (`agent/tool_runner.rb:99`).

Nothing about the second lineage works without this keyword: the derived chain *is* a chain of
`causal_parents` edges.

### 3. Payload is inline in Ext, out-of-line in Ruby

Ruby's `Timeline#commit` puts two objects — the payload, then the envelope naming it
(`timeline.rb:72-73`), and the ordering is required because `payload_digest` is a validated Store
edge. The Ext store carries the payload inline with the envelope, which `lib.rs:174-177` states
as the reason `validate_put` has no `payload_digest` arm.

This is observable, and the same test in both suites pins the two answers:

- `spec/lain/timeline_spec.rb:150` — four turns across a fork, `expect(store.size).to eq(8)`
- `spec/lain/rust/timeline_spec.rb:77` — the same four turns, `expect(store.size).to eq(4)`

Verified live: one commit onto an empty timeline leaves `size == 2` in Ruby and `size == 1` in
Ext. Any consumer that reasons about store size — `supervisor/restart.rb`'s sidecar re-put,
`compaction/derivation_audit_spec.rb:442-449`'s growth assertions — reads a different number
after a swap.

### 4. `Ledger`'s block-form `#ancestors` would silently no-op

`lib/lain/ledger.rb:117` is `timeline.ancestors { |turn| acc[turn.digest] ||= turn }`. Ruby's
`Timeline#ancestors` (`timeline.rb:96-105`) yields at `:102` when given a block and returns an
Enumerator when not (`:97`). `Ext::Timeline#ancestors` (`lib.rs:1280-1285`) builds and returns an `RArray`
and never yields.

Verified: with a one-turn Ext timeline, `t.ancestors { |x| acc << x }` leaves `acc` empty and
returns an Array. **This is the one gap that fails quietly** — `Ledger` would price every
timeline at zero, with no exception and no warning, and the bench's whole cost column would read
as free. The other three raise.

## What this implies for the chunk

1. **The seam has to be named before an implementation is chosen.** Sixteen construction sites,
   no factory. That is the first card, and it is Ruby work with no Rust in it.
2. **`causal_parents:` and the block-form `#ancestors` are hard prerequisites**, not polish —
   the first because the shipped compaction design is built on causal edges, the second because
   its absence is silent.
3. **The Store question is separable from the Timeline question.** Six other kinds live in a
   production Store, and a Timeline-only seam can be drawn without answering what happens to
   them — but the answer has to be written down, because `Ledger` aggregates across stores.
4. **Rule 2 of `CLAUDE.md`'s five is still weak here.** `ext/lain/Cargo.toml` says the HAMT's
   structural sharing is latent, and the current O(1) `fork` comes from the handle plus content
   addressing, not from the persistent map. What Rust buys today is a constant factor (one locked
   read and one batched Array, against n `Monitor#synchronize` and two Arrays per walk). The
   honest trigger for rule 2 is speculative branching with per-branch snapshots — which is a
   ROADMAP item, not a thing this chunk delivers. A wiring chunk should say so rather than
   quoting a benchmark as the reason.
5. **The lock-across-Ruby hazard should land first.** `2026-07-29-simplification-review.md` §10.1
   item 6 found ten sites where the extension calls into Ruby while holding the `Store` mutex,
   in a crate whose `Mutex` is not reentrant. Wiring makes that reachable from production.
