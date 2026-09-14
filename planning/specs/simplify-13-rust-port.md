# Simplify 13 — prove the Rust obeys the laws, then delete the Ruby that was proving it

status: draft
commit-mode: orchestrator-commits
language: rust (with Ruby at the boundary and for the corpus generator)
panel: Raph Levien, Andrew Gallant, Frank McSherry, Ashley Williams; Edward Kmett and Philip Wadler join for T2 and T4; Jeremy Evans and Sandi Metz for the Ruby deletions

## Intent

`Ext::Turn`, `Ext::Timeline`, `Ext::Store` and `Ext.canonical_dump` have **zero production callers** —
roughly 6,300 Rust lines shadowing 1,020 Ruby lines that do all the work, kept in agreement by ~1,744
lines of parity spec. The reason is written down: `docs/rust-bindings.md` rule 5 and
`ext/lain/CLAUDE.md:119` **require** the Ruby to stay, because the property tests must pass against both
implementations.

But a differential test proves **agreement, not correctness** — if both sides share a wrong assumption it
passes green forever. And the laws exist only as Ruby: there is no property-testing crate in either Cargo
manifest. So the path to deleting the Ruby is to *upgrade the verification*, not to revert the port.

This plan states the laws natively in Rust, freezes Ruby's answers as reviewable data before deleting it,
measures whether the tests actually constrain the implementation, then finishes the port.

Delivers: every algebraic law as a `proptest` property; a sealed trait no type can claim the algebra
without; a five-file conformance corpus generated from Ruby; a `cargo-mutants` kill-rate gate; G1, G3, G5,
G6 and G8 closed; and the Ruby `Timeline`/`Store`/`Event` deleted. **Net ≈ −148 code lines** — the port is
roughly line-neutral, and that is not the point.

## Grounding

Verified 2026-09-12 against the working tree at `d2bb133c`. `code` is non-blank, non-comment.

**The core modules ARE in the `cargo test` build.** `ext/lain/src/lib.rs:39-52` declares
`mod canonical; mod dag; mod digest; mod event; mod graph;` with **no `#[cfg]` gate** — only
`#[deny(clippy::missing_docs_in_private_items)]` attributes on three of them. **Only `mod ffi` is gated**
(`:337`, `#[cfg(not(test))]`). The pure helpers `descend` (`:139`), `classify_num` (`:169`),
`validate_put` (`:237`), `put_into` (`:270`) and `rewind_to` (`~:310`) all sit **above** `:337` and are in
the test build too.

So properties and mutants run natively over the algorithms. **The `#[cfg(not(test))]` hazard applies only
to the boundary — which is exactly where both silent divergences live.** That asymmetry drives T12.

**Tooling inventory.** No `proptest`, `quickcheck`, `arbitrary` or `rand` in `Cargo.lock`;
**`ext/lain/Cargo.toml` has no `[dev-dependencies]` section at all**; `cargo-mutants`, `cargo-fuzz` and
`cargo-kani` all absent from PATH. `bootsnap 1.24.6` and `prop_check 1.0.2` **are** in the bundle.

**Corrected census.** `ext/lain/src` **3,120 code** (36% `#[cfg(test)]`, not 45%);
`crates/lain-core/src` **884**. And `planning/rust-parity-gap.md` is **~40% stale**, written 2026-07-29:
`commit(causal_parents:)`, `causal_meets`, `dominator_meet` and the lock-across-Ruby hazard are all
closed, and its `file:line` references have drifted.

**The laws, and which port.**

| group | laws | subject | portable? |
|---|---|---|---|
| `meet_semilattice.rb` (60 code) | 4 — idempotent, commutative, associative, meet-below-both | `#meet` **and** `#dominator_meet`, declared twice | **all 4, both operators** |
| `store_laws.rb` (18) | 2 — re-put is a no-op; structurally-equal content is one object | `Store#put` | **yes** |
| `regular.rb` (37) | 6 | `Event`, `Timeline` | **5 of 6** |
| `canonical_laws.rb` (89) | 16 examples, 2 property-based | `Canonical.dump` | **12 of 16** |
| `memory_index_laws.rb` | retrieval contract | `Memory::Manifest`/`Bm25` — **search scoring, not the Store** | **out of scope; do not conflate** |
| `monoid.rb`, `elementwise.rb` | — | Middleware, `Usage#+`, combinators | **out of scope** |

**Four canonical laws and one Regular law do not port — and that is a better outcome than porting them.**
Symbol-vs-String key collapse, mixed-spelling-per-key collapse, invalid-UTF-8 `String` refusal,
arbitrary-`Object` refusal, and "not equal to a non-member type". In each case **the illegal input is
unrepresentable in Rust**: `Canon` has no Symbol variant, `Canon::Str` holds a `String` which is UTF-8 by
type, and `PartialEq` is homogeneous. The bug class is gone rather than tested — but it is then checkable
only at the boundary, so those stay in `spec/lain/rust/canonical_spec.rb`.

**Eight order laws are asserted nowhere today, on either side.** Reflexivity, antisymmetry and transitivity
for the two orders, plus bottom-below-everything. `dag.rs` has only `ancestor_of_is_a_prefix_relation` and
`empty_is_below_everything`, which are weaker. Adding them is **net new verification** and is legitimate
only once the Rust registry, not the Ruby group, is the authority — which is T3's doc edit.

**The generator must be correct by construction, never by rejection**, or shrinking is useless:

    enum Op { Root, Extend { on }, FanIn { on, folds }, Spawn { anchor } }

`Vec<(Op, Canon)>` where every index is drawn as a raw `u16` and **interpreted modulo the population
length at the moment the op is applied**. Every program is well-formed with no `prop_filter`, so proptest
can delete ops and shrink bodies and every intermediate candidate stays valid. Bounds mirror
`MeetSemilatticePopulations.union_graph`: 1-4 roots, 0-40 ops, 0-3 folds per fan-in, `Canon` depth ≤ 4
with ≤ 5 children.

The yielded fixture must contain `None` (the bottom) **and** a head from a second, **disjoint** map, **by
construction** — Ruby gets this by hand (`population << commit(empty, "stranger")`); Rust must get it
structurally or the meet is never exercised at its bottom.

`proptest = { version = "1", default-features = false, features = ["std", "bit-set"] }` — dropping
`fork`/`timeout` drops `rusty-fork` and `wait-timeout`. Transitive set is `bit-set`, `bit-vec`, `rand`,
`rand_chacha`, `rand_xorshift`, `regex-syntax`, `unarray`, `num-traits`, `ppv-lite86`: **all MIT/Apache-2.0,
all inside `deny.toml`'s allow list (`:14-26`)**, none on the `[bans]` terminal-owner list, and the version
must be pinned because `wildcards = "deny"`.

**The written rule this plan reverses, and it must be edited rather than quietly violated.**
`ext/lain/CLAUDE.md` says: *"do not reach for a `trait Monoid` or `trait MeetSemilattice` to 'make it
official'… a trait written solely so tests can call it is indirection with a law attached, and it invites
a second, drifting declaration of the same laws"* — and *"the Ruby shared example group is the authority
on which laws exist."* Both are **correct given their premise**, and the premise is that Ruby exists.

**The sealed trait is strictly stronger than the sealed Ruby registry.** Ruby's
`Lain::Algebra.registry.seal` (`lib/lain.rb:146`) plus `spec/algebra_laws_spec.rb`'s sweep catches a
declaration-without-a-generator at *spec time*. A private supertrait — `mod sealed { pub trait Proven {} }`
— that only the macro implements catches declaration-without-laws at **compile time** (`E0277`), and closes
the inverse leak too, because the two are the same expansion. **No `inventory`/`linkme` crate is needed and
none should be added.**

**The refutation becomes a type error.** Ruby needs a three-outcome battery for
`not_a_meet_semilattice on: :causal_meets` because running it naively dies of `NoMethodError`. In Rust
`causal_meets` returns `Vec<Digest>` while `MeetSemilattice::meet` returns `Self::Elem`, so **it cannot be
handed to the macro**. A `declare_not_meet_semilattice!(..., because:, witness:)` still earns its place,
emitting one test that the witness yields **more than one** maximal lower bound — the "EXHIBIT what the
reason says" obligation `spec/algebra_laws_spec.rb` imposes.

**The corpus has a precedent in this crate.** `ext/lain/src/event.rs:550-655` already embeds hardcoded
Ruby-computed digest vectors in `#[test]`s (`correlated_envelope_digest_matches_the_ruby_vector`,
`payload_digest_matches_the_ruby_vector_for_every_kind`). The corpus is that practice, **generated rather
than transcribed**.

**And the strongest single argument for it.** `canonical.rs`'s module doc records that **Ruby's float
formatting is not re-derivable in Rust** — neither `Float#to_s` nor `ryu` nor JCS matches
`JSON.generate` — so the FFI reader captures Ruby's rendered text at call time and `Canon::Num` emits it
verbatim. **Rust's float bytes are correct today only because Ruby is in the loop at runtime.** The corpus
is the first artifact that freezes that as reviewable data rather than borrowing it live.

**`cargo-mutants` is clean here, and CLAUDE.md's warning does not apply.** `CLAUDE.md:258-261` says
mutation harnesses lie because same-size mutants collide with **bootsnap's `(mtime-seconds, size)` cache
key**. Bootsnap is a Ruby ISeq/YAML bytecode cache loaded from `spec/bootsnap_setup.rb`; cargo fingerprints
by content hash, and `cargo-mutants` copies the tree into a scratch build directory per mutant. **The
collision class does not exist.** And there is **no `mutant` gem in the project at all** — the recorded trap
is about a harness never installed. What *does* carry over is the scoring discipline: score on the count
**equalling a captured baseline**, because `unviable` is an *unrun* mutant, not a surviving one.

**Both heavy tools are rejected, with reasons.** `cargo-fuzz` needs nightly and
**`ext/lain/CLAUDE.md:47` is the crate's first hard rule** — *"Stable channel only. No `#![feature]`. A
subagent has already shipped `#![feature]` here and it does not build."* Also the proposed
`dump → parse → dump` property **does not exist**: `canonical.rs` has `dump` and `digest` and **no
parser**; the reader lives in the `#[cfg(not(test))]` FFI layer over Ruby values, so fuzzing a round trip
means first writing a parser — a new surface that can drift from Ruby. `cargo-kani` must reason through an
`rpds` HAMT of `Arc<EventData>` and through `blake3`'s SIMD paths, and the one overflow-shaped hazard is
already closed by construction with a written argument (`rewind_to`'s `digest.is_some()` bound exists
because `rewind(2**62)` would hold the Store mutex for ~71 years).

**The gaps, corrected.** Closed already: `commit(causal_parents:)`, `causal_meets`, `dominator_meet`, the
lock-across-Ruby hazard. Open:

- **G1** `Ext::Store#put` is monomorphic (`lib.rs:1179` takes `&Turn`) while **six non-Event kinds enter a
  production Store at eight sites**: `Event::Payload` (`timeline.rb:78`, `event/chain_writer.rb:64`,
  `bench/session/message_replay.rb:217`), `Workspace::Snapshot::Blob` (`workspace/snapshot.rb:154`,
  `supervisor/restart.rb:145`), `Plan::Closure` (`plan/closure.rb:155`), `Plan::Supersession`
  (`plan/fork_per_step.rb:76`), `Memory::Item` and `Memory::Index::Node` (`memory/index.rb:78`, `:80`).
- **G3** payload inline in Ext, out-of-line in Ruby. Pinned on **both** sides:
  `spec/lain/rust/timeline_spec.rb:165` expects `store.size == 4` where `spec/lain/timeline_spec.rb:150`
  expects **8**.
- **G4** the block-form `#ancestors` — **simplify-02's T4 owns this**, and it is the only *silently* wrong
  divergence.
- **G5** only `:turn` is constructible over FFI. `event.rs:104-135` holds the full closed `Kind` enum with
  per-kind digest vectors pinned at `:620-650`, and `EventData::new` (`:240`) is generic over a payload —
  but the only FFI constructor is `Turn.new` (`lib.rs:1905`), hard-coding `EventData::turn`.
  `spawn`/`message`/`snapshot` are written by `Event::ChainWriter#put` (`event/chain_writer.rb:59`), which
  the mailbox (`ask_human.rb:976`), subagent lineage (`lineage.rb:146`) and Workspace snapshots
  (`snapshot.rb:104`) all depend on.
- **G6** `Ext::Turn` lacks `from`, `to`, `body`, `carried_payload`. `carried_payload` is what makes Ruby's
  `commit` one digest pass rather than two (`timeline.rb:74-77`).
- **G7** the algebra declaration — **simplify-02's T5 owns this**.
  > **2026-09-14, amended.** G7 is closed. `simplify-09-orders-as-types.md` deleted `Lain::Algebra`
  > whole (`lib/lain/algebra/` no longer exists, and `lib/` has no reference to `Lain::Algebra`) —
  > there is no Ruby declaration left to mirror, load-time or otherwise.
- **G8** the seam. The stale doc counted 16 sites; today it is **21 live `Timeline.new` sites across 19
  files** plus ~20 bare `Store.new`.
  > **2026-09-14, amended.** G8 shrinks rather than closes. `simplify-09-orders-as-types.md`'s T1
  > moved the render meet off `Timeline` and into a stateless `Dag::RenderAncestry` module, which is
  > a seam for that one operation but constructs nothing — the 21 `Timeline.new`/~20 `Store.new`
  > sites T10 below routes through `Dag::Factory` are unaffected by it. What remains for G8 is
  > exactly T10's construction seam.

**G1's design is decided by a constraint, not a preference.** `Workspace::Snapshot::Blob` does **not** use
`Canonical.digest` — `workspace/snapshot.rb:59`:

    @digest = -"#{Canonical::DIGEST_ALGORITHM}:#{Ext.blake3_hex("blob #{@bytes.bytesize}\0".b + @bytes)}"

a git-style header over **raw binary**, with `:44-45` saying the header *"domain-separates blob digests
from the JSON-canonical digests"* and that Canonical *"would refuse arbitrary file content."* Arbitrary
binary is not valid UTF-8, so **a Blob cannot be a `Canon` at all** — any design routing every store member
through the canonicalizer is wrong on arrival. The other four non-Event kinds **do** share one shape
(`digest = Canonical.digest(payload_hash)`, edges ⊆ `{parent}`), verified at `memory/item.rb:53-62`,
`memory/index.rb:30-52`, `plan/closure.rb:135-165`, `plan/seam_policy.rb:70-84`.

**Rule 4 holds, and this is the part to get right.** The boundary is crossed **once per put**: one
recursive descent reads the object into a `Canon` inside a single FFI call, then digest, validate and
insert all Rust-side. That is **fewer** crossings than Ruby's `Store#put`, which does four `respond_to?`
probes plus a `Canonical.digest`. Only the two kinds actually **fetched** grow a reader —
`Memory::Item.from_payload` and `Memory::Index::Node.from_payload` (`memory/index.rb:95`, `:106`, `:115`),
~7 Ruby lines each; `Plan::Closure` and `Plan::Supersession` are put and **never fetched**
(`plan/closure.rb:154`, `plan/fork_per_step.rb:82`).

**An `Opaque<Value>` arm is rejected.** It is simpler and it costs the property `lib.rs:1128` states —
*"Holds no Ruby reference, so no `mark`"*. A `mark` would have to walk the whole map from a GC callback,
taking the `Mutex`; that is safe today only because nothing in this crate releases the GVL, and it would
break silently the first time a put wanted `without_gvl`.

**Free enforcement worth naming:** the `Canon` arm recomputes the digest Rust-side and compares it to the
Ruby object's own `#digest`, raising on mismatch — a **per-put differential assertion running in
production** while `Canonical` still exists in Ruby, costing nothing because the digest is computed anyway.

**What the deletion actually removes.** `timeline.rb` 222, `store.rb` 42, `event.rb` 95,
`event/payload.rb` 21 = **380 deleted**; `timeline_spec.rb` 474, `store_spec.rb` 130, `event_spec.rb` 235
= **839 deleted**. And **two units are rehomed, not deleted**: `event/projection.rb` (63) is a pure fold
over an event log needing only `kind`/`to`/`causal_parents`/`digest`, and `event/chain_writer.rb` (28) is
a writer plus observer seam. **Counting them as deleted would overstate the win by ~91 lib + ~284 spec
lines.**

**`Canonical` must NOT be deleted.** `Memory::Item`, `Memory::Index::Node`, `Plan::Closure` and
`Plan::Supersession` all depend on `Canonical.normalize` — it is the freeze/shape gate their
`Ractor.shareable?` rests on. The narrower move, its own decision: keep `normalize`, route `dump`/`digest`
to `Ext.canonical_dump`/`canonical_digest` (~−5 lines, and `JSON.generate` leaves the digest path).

**Where docs and code disagreed, and which won.** `planning/rust-parity-gap.md` is ~40% stale — **the code
wins**, and T3 retires the doc. `docs/rust-bindings.md` rule 5 and `ext/lain/CLAUDE.md:119` currently
*require* the duplication — **T3 replaces them**, and that is a reviewable policy change, not an
implementation detail.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `ext/lain/Cargo.toml`,
  `Cargo.toml`, `deny.toml`, `Rakefile`, `.pre-commit-config.yaml`, `lain.gemspec`,
  `spec/spec_helper.rb`.
- **T3's doc edits are task scope and are the review-critical commit**: `ext/lain/CLAUDE.md`,
  `docs/rust-bindings.md`, `planning/rust-parity-gap.md`, `ROADMAP.md`.
- **Prerequisites.** simplify-03's **T7** (it deletes `DerivationAudit` and the store-size assertions in its spec, which T7 here would otherwise have to reconcile), simplify-02's **T4** (block-form `#ancestors` — G4, the silent one) and **T5** (the
  algebra declaration — G7) must have landed.
  > **2026-09-14, amended.** `simplify-09-operations-as-objects.md` (the plan this once cited as
  > "T4") was dropped whole on 2026-09-13 and rebuilt as `simplify-09-orders-as-types.md`; this
  > plan no longer waits on a card that does not exist. The seam it was waiting for **has landed**
  > under a different name: `lib/lain.rb` requires `lib/lain/dag.rb`, and `Lain::Dag::RenderAncestry`
  > (a module, not the store-bound object this bullet used to expect) already holds `.meet`,
  > `.diverge_at` and `.below?` over a `Timeline` pair. G8 is not "largely removed" — it is closed
  > for the render meet specifically; T10's factory is still the seam for construction, and its own
  > note below says what remains.
- **Nothing may be deleted before T8's corpus commit is green.** That is the plan's hard gate.
- `rake rust:mutants` is a **chunk-boundary** gate, not a pre-commit hook. `pre-commit` already runs four
  cargo commands; a multi-minute mutation sweep there would be abandoned within a day, and an abandoned
  gate is worse than an honest chunk-level one.

## Open decisions

- **Whether to finish the port at all.** This plan is line-neutral (**≈ −148**). Its case is a verification
  layer that does not exist plus the removal of a second implementation of the system's identity function —
  not a line count. If the panel judges the current differential arrangement worth its cost, **T1-T4 and T8
  still stand on their own** as better verification, and T5-T14 do not have to follow.
- **Eager or lazy on `Canonical`.** The narrower move — keep `normalize`, route `dump`/`digest` to Ext — is
  its own decision with its own gate and is **not** part of the deletion sequence. Recorded so it is not
  done by accident.
- **What the corpus's float coverage means.** It freezes a **sample** of Ruby's float rendering, not a
  proof. `MANIFEST.json` must say so and name the `json` gem version it sampled. If `Canonical.dump` ever
  goes fully Rust-side, that sample becomes the only specification of Ruby's float format.

## Waves

Wave 1: T1, T3
Wave 2: T2 (←T1)
Wave 3: T4 (←T1, T2), T5 (←T2)
Wave 4: T6 (←T5)
Wave 5: T7
Wave 6: T8
Wave 7: T9, T10
Wave 8: T11
Wave 9: T12
Wave 10: T13
Wave 11: T14
Critical path: T1 → T2 → T4 → T6 → T7 → T8 → T10 → T11 → T12 → T13 → T14

**T1, T2 and T4 are in three waves deliberately, and the boundaries are ownership of one file.** T1 owns
the **generators only**; T2's macro owns the four `proptest!` blocks it emits; T4 owns the eight order
laws and the refutation macro. All three write `ext/lain/src/dag.rs` and `ext/lain/src/algebra.rs`, so an
earlier draft that ran T2 and T4 together had two cards writing law bodies into one file. **T5 and T6 are
split for the same reason** — both register FFI methods in `ext/lain/src/lib.rs`.

Waves 6 onward are narrow by necessity: T8 is a hard gate, T11 is the flip, and nothing after it is
reversible in one commit unless each step lands alone.

## Tasks

### T1 — Generators, and the laws as native properties   [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `ext/lain/Cargo.toml`; create `ext/lain/src/algebra/strategy.rs`; modify
`ext/lain/src/dag.rs`, `ext/lain/src/graph.rs`
**Reuse:** `spec/support/shared_examples/meet_semilattice.rb`'s `MeetSemilatticePopulations.union_graph`
is the population shape to mirror
**Shared-file wiring:** a `[dev-dependencies]` section in `ext/lain/Cargo.toml` (the file has none), and a
`deny.toml` check that the transitive set stays inside the allow list
**Reachable from:** properties run under `cargo test` over `dag`/`graph`, which **are** in the test build
(`lib.rs:39-52`, no `#[cfg]`); AC 4 is the shrinker working, which is what makes a failure actionable

`DagPlan` yields `Vec<(Op, Canon)>` where every index is a raw `u16` **interpreted modulo the population
length at the moment the op is applied** — so every program is well-formed with **no `prop_filter`**, and
proptest can delete ops and shrink bodies with every candidate still valid.

The fixture must contain `None` (the bottom) **and** a head from a **disjoint** second map, **by
construction**. Ruby adds the stranger by hand; Rust must get it structurally or the meet is never
exercised at its bottom.

**This card writes no law bodies.** T2's macro emits them, named as the Ruby examples are named — that
naming discipline is what keeps the two layers from disagreeing about what a law *is*. T1's deliverable is
the strategies plus whatever the existing hand-populated tests need to keep passing until T2 replaces them.

**Acceptance criteria**

```gherkin
Scenario: a generated program always yields a well-formed graph
  Given ten thousand generated programs
  When each is applied
  Then every one produced a valid store

Scenario: the meet is idempotent, commutative and associative
  Given generated graphs and head pairs
  When the render meet is taken
  Then all three laws hold

Scenario: a meet sits below both its operands
  Given generated graphs and head pairs
  When the render meet is taken
  Then it is an ancestor of both

Scenario: a violated law shrinks to a minimal counterexample
  Given a deliberately broken meet
  When the property runs
  Then the reported counterexample has the fewest operations that still fails

Scenario: the bottom and a disjoint head are always in the population
  Given any generated fixture
  When its heads are inspected
  Then the empty head is present
  And at least one head from a disjoint store is present
```
→ spec file: none — these are `#[cfg(test)]` properties in `dag.rs` and `graph.rs`, run by `cargo test`.
Their Ruby counterparts in `spec/lain/rust/` stay and are **not** duplicated here.

**Escalation triggers**
- **If any generator needs `prop_filter`, stop and redesign.** A rejection-based generator makes shrinking
  useless, and an unshrinkable counterexample over a 40-op DAG is not actionable.
- The transitive dependency set must stay inside `deny.toml`'s allow list (`:14-26`) with **pinned**
  versions — `wildcards = "deny"`. If `default-features = false` does not drop `rusty-fork` and
  `wait-timeout`, report the real set before committing.
- `cargo test` compiles `dag`/`graph`/`event`/`canonical` but **never `mod ffi`**. If a property needs
  anything from the FFI layer, it is testing the boundary and belongs in `spec/lain/rust/`, not here.
- A property that runs thousands of cases per law adds to `cargo test`'s wall, which `pre-commit` runs on
  every Rust commit. **Measure it**; if it is material, cap the case count in the default profile and run
  the full count at the chunk gate.

### T2 — A sealed trait the macro is the only key to   [wave 2] [risk: high]

**Depends on:** T1
**Files:** create `ext/lain/src/algebra.rs`; modify `ext/lain/src/dag.rs`, `graph.rs`, `lib.rs`
**Reuse:** `lib/lain/algebra/meet_semilattice.rb`'s four laws and its `refuse_unnamed_bottom` load-time
raise are what this mirrors; `spec/algebra_laws_spec.rb`'s three-outcome battery is what becomes a type
error
**Shared-file wiring:** `mod algebra;` in `lib.rs`, with the scoped
`#[deny(clippy::missing_docs_in_private_items)]` that `ext/lain/CLAUDE.md` requires of any module carrying
a law
**Reachable from:** the trait is implemented by the DAG's two meet operations; AC 1 is a compile-time
check, which is the strongest form available

> **2026-09-14, amended — this card is largely done.** `simplify-09-orders-as-types.md`'s T2 landed
> (`98085764`, `cargo test -p lain` at 231) and wrote exactly this: `ext/lain/src/algebra.rs` holds
> `mod sealed { pub trait Proven {} }`, `pub trait MeetSemilattice: sealed::Proven`, the
> `declare_meet_semilattice!` macro, and `CausalAncestry`'s `MaximalLowerBounds` impl in place of a
> `MeetSemilattice` one, with the witness test
> `causal_ancestry_answers_more_than_one_maximal_lower_bound` (`algebra.rs:282-301`) already
> exhibiting what the refutation's reason claims. Sitting beside the four named law bodies, one more
> generic function was added on review because none of the four checked *greatest*:
> `below_is_exactly_where_the_meet_answers_the_lower_operand_in_both_orders`
> (`algebra.rs:350-368`) asserts the order-theoretic identity `a below b iff meet(a, b) == a` over
> both semilattice orders — its own comment calls it "characterization rather than a fifth law
> because the Ruby group names four," so the Ruby-named contract stays exactly four laws.
> **This card's remaining scope is T1's half of the bargain**: point `declare_meet_semilattice!`'s
> populations at T1's generated strategies and delete the hand-built ones — the trait, the seal, the
> four law bodies and the added characterization do not need to be written again. Its compile-fail
> ACs (AC 1, AC 2, AC 4) are unverified by any harness at `98085764` — no
> `trybuild` dependency exists — so they stand exactly as this card already asks, unless a
> `trybuild` addition is chosen here.

**This card owns the four `proptest!` law bodies.** T1 owns the generators and writes no law bodies; the
macro emits them. Two cards writing properties into one file is what an earlier draft had.

    mod sealed { pub trait Proven {} }
    pub trait MeetSemilattice: sealed::Proven {
        type Elem; type Ctx;
        fn meet(ctx: &Self::Ctx, a: &Self::Elem, b: &Self::Elem) -> Self::Elem;
        fn below(ctx: &Self::Ctx, m: &Self::Elem, a: &Self::Elem) -> bool;
        const BOTTOM: &'static str;
    }

`declare_meet_semilattice!` emits, in **one** token stream: the `sealed::Proven` impl (the only route to
it), a `const _: () = assert!(!BOTTOM.is_empty())` — the compile-time analogue of Ruby's load-time
`refuse_unnamed_bottom` — and a `#[cfg(test)] mod` holding exactly four `proptest!` blocks.

**Stronger than the Ruby registry in two ways.** Ruby catches declaration-without-laws at *spec* time; this
catches it at **compile** time (`E0277`). And it closes the inverse leak — laws present, declaration absent
— because the two are the same expansion. **No runtime registry, no `inventory`/`linkme`.**

Also `declare_partial_order!` for the **eight order laws nothing currently asserts**, and
`declare_not_meet_semilattice!(CausalMeets, because:, witness:)` for the refutation — preserving the reason
prose verbatim from `lib/lain/timeline.rb:186-191`.

**Acceptance criteria**

```gherkin
Scenario: a type cannot claim the algebra without its laws
  Given a type implementing the trait without the macro
  When the crate is compiled
  Then compilation fails, naming the unimplemented private supertrait

Scenario: a declaration with an empty bottom is refused at compile time
  Given a declaration naming an empty bottom
  When the crate is compiled
  Then compilation fails

Scenario: both meet operators carry the declaration and pass
  When the law tests run
  Then the render meet and the dominance meet each satisfy four laws

Scenario: the set-valued operator cannot be declared
  Given the causal operator, which returns a collection
  When it is passed to the macro
  Then compilation fails on the type

Scenario: the refutation exhibits what its reason claims
  Given the criss-cross witness
  When the refutation test runs
  Then the witness yields more than one maximal lower bound
```
→ spec file: none — compile-time and `cargo test`. AC 1, AC 2 and AC 4 are **compile-fail** tests; if the
crate has no compile-fail harness, the card should say how they are checked (a `trybuild` dev-dependency is
the idiomatic answer and must clear `deny.toml`).

**Escalation triggers**
- **This card contradicts a written rule and must not do so silently.** `ext/lain/CLAUDE.md` says *"do not
  reach for a `trait MeetSemilattice`"* and *"the Ruby shared example group is the authority."* T3 edits
  both. **If T3 has not landed, stop** — shipping a trait against a standing rule is how the next reader
  concludes the rule is decorative.
- `#![deny(missing_docs)]` at the crate root covers **zero items** today because every module is private;
  the enforcing lint is `#[deny(clippy::missing_docs_in_private_items)]` scoped to `mod dag` and
  `mod digest`, and crate-wide *"would report 109 and stays off."* A new module carrying a law needs the
  scoped attribute — and then every private item in it needs a doc comment.
- Adding `trybuild` for compile-fail tests adds a dev-dependency tree. If it does not clear `deny.toml`,
  the compile-fail ACs need another mechanism — say which rather than dropping them.
- If the macro's expansion is hard to read, run it once through `cargo expand` and **put the expansion in
  the commit message**. The panel's review burden here is one expansion, and hiding it inside a macro is
  how a law suite ends up unread.

### T3 — Edit the three rules this plan reverses   [wave 1] [risk: high]

**Depends on:** none
**Files:** modify `ext/lain/CLAUDE.md`, `docs/rust-bindings.md`, `ROADMAP.md`; delete
`planning/rust-parity-gap.md`
**Reuse:** each rule already states its own justification, and each justification is what expires — quote
it and say why
**Shared-file wiring:** none
**Reachable from:** every agent session working on `ext/lain` reads these; there is no runtime path, and
that is why this card is high risk rather than low

**This is the review-critical commit of the plan.** Three rules invert:

1. **`ext/lain/CLAUDE.md`'s "do not reach for a `trait MeetSemilattice`"** — correct while a second,
   drifting declaration was possible; after the Ruby DAG goes, the Rust declaration is the *only* one.
   > **2026-09-14, amended — already satisfied, not to be reversed.** `simplify-09-orders-as-types.md`'s
   > T2 has already edited this exact rule (`ext/lain/CLAUDE.md:129-148` as it reads today; the
   > "do not reach for" sentence sits at `:138-142`), and the resolution was **satisfaction**, not
   > reversal: the section now reads "`MeetSemilattice` passed that test: `ffi`'s
   > `Timeline::meet_via::<S>` and `Timeline::below_via::<S>` are generic over it," which is the
   > condition the original rule itself named as the exception. There is nothing left here for this
   > card to invert; if the doc needs anything, it is a note that the second declaration this rule
   > warned about is now impossible rather than merely undesirable, once T13 deletes the Ruby DAG.
2. **`ext/lain/CLAUDE.md:119`'s "the Ruby version is not deleted when the Rust one lands"** — the doctrine
   that makes this plan impossible as written.
   > **2026-09-14, checked, unchanged.** Still reads exactly this at `:119` today. This inversion is
   > still this card's to make.
3. **`docs/rust-bindings.md` rule 5** — *"the property tests must pass unchanged against **both**
   implementations"* — replaced by the corpus rule plus the mutation gate.
   > **2026-09-14, amended — already narrowed once.** `simplify-09-orders-as-types.md`'s T4 has
   > already edited rule 5 (`docs/rust-bindings.md:30-38`): it no longer requires two
   > implementations unconditionally — "**where both implementations exist** the `Regular` /
   > `MeetSemilattice` property tests must pass unchanged against both" — and it already carves out
   > dominance and causal ancestry as Rust-only, held to fixtures rather than a second
   > implementation. This card's job narrows to replacing "where both implementations exist" (which
   > after T13 is never) with the corpus rule.

And **`planning/rust-parity-gap.md` is retired**: ~40% of it is stale (four gaps closed, line references
drifted), and a document titled "the parity gap" implies a debt someone intends to pay. What is still true
in it — the intended divergences — moves to `ext/lain/CLAUDE.md`.

`ROADMAP.md:113` marks M4-1 `[built]`; it needs the implicit wiring follow-on either scheduled or closed.

**Write down what replaces each rule, not just that it is gone.** The replacement is: properties state the
laws, a sealed trait enforces the declaration, a frozen corpus pins the answers, and a mutation score
measures whether the tests constrain the code.

**Acceptance criteria**

```gherkin
Scenario: the crate's guidance permits an algebra trait and says when
  When the crate's guidance is read
  Then it permits a law-carrying trait
  And it states the condition under which one earns its place

Scenario: the binding rules name the corpus as the oracle
  When the binding rules are read
  Then rule five names a frozen conformance corpus
  And it does not require two implementations

Scenario: no document describes a parity gap as outstanding work
  When the planning documents are listed
  Then none is titled as a parity gap

Scenario: the intended divergences are recorded where the crate's readers look
  When the crate's guidance is read
  Then it names each deliberate difference between the two implementations
```
→ spec file: none. These are prose assertions verified by reading, and **must not become specs** — a spec
asserting on documentation text is exactly the class simplify-10's T12 removes.

**Escalation triggers**
- **`ext/lain/CLAUDE.md`'s rules were correct when written.** The edit must say *the premise changed*, not
  *the rule was wrong* — otherwise the next reader learns that rules here are negotiable on taste.
- If `planning/rust-parity-gap.md` contains a measurement not recorded anywhere else, **move it before
  deleting the file**. Its stale half is references; its live half may include real numbers.
- `docs/rust-bindings.md`'s **five tests** are the admission criteria for any future binding. Rule 5
  changes; **rules 1-4 do not**, and rule 2 (Ruby asymptotically worse) is the one this plan's subject
  arguably fails — say so rather than quietly widening it.
- If the panel rejects the trait (T2), this card's first edit must not land. Sequence the panel review of
  T2 and T3 together.

### T4 — The eight order laws nothing asserts, and the refutation   [wave 3] [risk: medium]

**Depends on:** T1, T2
**Files:** modify `ext/lain/src/algebra.rs`, `ext/lain/src/dag.rs`, `ext/lain/src/graph.rs`
**Reuse:** T2's sealed-trait machinery and T1's `DagPlan`; `lib/lain/timeline.rb:186-191`'s refutation
reason prose is copied verbatim
**Shared-file wiring:** none
**Reachable from:** the declarations attach to the DAG's two orders and to the set-valued operator; AC 4 is
a compile-fail check, which is the strongest form available

**Reflexivity, antisymmetry, transitivity and bottom-below-everything are asserted nowhere today, on either
side.** `dag.rs` has only `ancestor_of_is_a_prefix_relation` and `empty_is_below_everything`, which are
weaker. `declare_partial_order!` adds **eight properties** — four laws across the ancestry order and the
dominance order — which is **net new verification**, not a port.

That is legitimate only because T3 has made the Rust registry the authority. Adding a fifth law to the
Ruby group would be "inventing a law", which `ext/lain/CLAUDE.md` forbids; declaring a **different
structure** — a partial order is not a semilattice — is not.

And `declare_not_meet_semilattice!(CausalMeets, because:, witness:)` emits one test that the criss-cross
witness yields **more than one** maximal lower bound — the "EXHIBIT what the reason says" obligation
`spec/algebra_laws_spec.rb` imposes on a refutation.

> **2026-09-14, amended — the refutation macro is unnecessary.** `simplify-09-orders-as-types.md`'s
> T2 already refuted `CausalAncestry` **by type**, not by a macro emitting a three-outcome battery:
> `ext/lain/src/algebra.rs` declares `pub trait MaximalLowerBounds` as `CausalAncestry`'s trait
> instead of `MeetSemilattice`, so there is no `impl MeetSemilattice for CausalAncestry` to negate
> and no `NoMethodError`-shaped battery to reproduce — the compiler already refuses the wrong shape
> for free. The witness test this paragraph asks for exists today, doing the same job:
> `causal_ancestry_answers_more_than_one_maximal_lower_bound` (`algebra.rs:282-301`) builds the
> criss-cross fan-in and asserts the three-element bound set. **`declare_not_meet_semilattice!` does
> not need writing.** The eight order laws above it are unaffected — nothing today asserts
> reflexivity, antisymmetry, transitivity or bottom-below-everything for either order, and they
> remain net-new verification for this card to add.

**Acceptance criteria**

```gherkin
Scenario: the ancestry order is reflexive, antisymmetric and transitive
  Given generated graphs and head triples
  When the order is tested
  Then all three laws hold

Scenario: the dominance order is reflexive, antisymmetric and transitive
  Given the same graphs
  When the dominance order is tested
  Then all three laws hold

Scenario: the bottom is below everything
  Given any generated graph
  When the empty head is compared with every other head
  Then it is below each

Scenario: a partial order cannot be declared without its laws
  Given a type implementing the order trait without the macro
  When the crate is compiled
  Then compilation fails

Scenario: the refutation exhibits what its reason claims
  Given the criss-cross witness
  When the refutation test runs
  Then the witness yields more than one maximal lower bound
```
→ spec file: none — `#[cfg(test)]` properties under `cargo test`, plus one compile-fail case for AC 4

**Escalation triggers**
- **Antisymmetry over a content-addressed DAG may be trivially true** (two heads below each other are the
  same digest). If the property cannot fail for any generated input, it is not testing anything — say so
  rather than keeping a vacuous law.
- If the ancestry order turns out **not** to be antisymmetric — because two distinct digests can each be an
  ancestor of the other through different edge kinds — that is a **finding about the data model**, not a
  bug in the property. Stop and report it.
- `dag.rs`'s existing `ancestor_of_is_a_prefix_relation` may be subsumed by transitivity, or may assert
  something stronger about *contiguity*. Read it before deleting it.
- Adding eight properties to `cargo test` adds to a wall `pre-commit` pays on every Rust commit. Measure,
  and cap the case count in the default profile if it is material.

### T5 — The missing `Ext::Turn` readers   [wave 3] [risk: medium]

**Depends on:** T2
**Files:** modify `ext/lain/src/lib.rs`; modify `spec/lain/rust/turn_spec.rb`
**Reuse:** `EventData` already holds `from`, `to`, `body` and the payload (`event.rs:180-200`) — this is
FFI surface, not algorithm
**Shared-file wiring:** registration lines in `lib.rs`'s `mod ffi` table
**Reachable from:** these readers are what `Event::Projection` and the Journal need; AC 4 drives a
projection over an `Ext::Turn`

G6: `from`, `to`, `body`, `carried_payload`, plus an `Ext::Payload` TypedData wrapper.
`carried_payload` is what makes Ruby's `commit` one digest pass rather than two (`timeline.rb:74-77`).

Also implement **`Detached` correctly**: a digests-only envelope must **raise** on `#role`, `#content` and
`#meta`, matching `event.rb:176-183` — **not answer nil**. A nil where Ruby raises is a silent divergence
of the kind this plan exists to eliminate.

**Acceptance criteria**

```gherkin
Scenario: a turn reports its envelope
  Given a Rust-backed turn with a sender and a recipient
  When it is asked
  Then it names both

Scenario: a turn carries its payload
  Given a turn committed with a payload
  When its carried payload is read
  Then the payload comes back

Scenario: a detached envelope refuses its body
  Given a digests-only envelope
  When its content is asked for
  Then it raises

Scenario: a projection folds a Rust-backed event log
  Given a log of Rust-backed turns
  When it is projected
  Then the projection matches the Ruby one over the same log
```
→ spec files: `spec/lain/rust/turn_spec.rb` (AC 1-3), `spec/lain/event/projection_spec.rb` (AC 4)

**Escalation triggers**
- `mod ffi` is `#[cfg(not(test))]`, so **`cargo test` cannot see any of this**. These ACs are RSpec-only
  and need `rake compile`; if they pass without a rebuild, the build is stale.
- **`Detached` raising rather than answering nil is the whole point of AC 3.** If magnus makes raising from
  a reader awkward, do not settle for nil — report it.
- `Ext::Payload` is a new TypedData type and therefore a new GC-visible object. `lib.rs:1128` states the
  crate *"holds no Ruby reference, so no `mark`"* — confirm a `Payload` wrapper does not break that.

### T6 — The other three event kinds over FFI   [wave 4] [risk: medium]

**Depends on:** T5
**Files:** modify `ext/lain/src/lib.rs`; modify `spec/lain/rust/event_spec.rb` (new or extended)
**Reuse:** `event.rs:104-135` already holds the **full closed `Kind` enum** with per-kind digest vectors
pinned at `:620-650`, and `EventData::new` (`:240`) is already generic over a payload. **This is pure FFI
surface work — the Rust half exists.**
**Shared-file wiring:** `Lain::Ext::Event` registration in `lib.rs`'s FFI table; keep
`Lain::Ext::Turn` as an alias for the remaining steps so nothing breaks mid-sequence
**Reachable from:** `Event::ChainWriter#put` (`event/chain_writer.rb:59`) writes these kinds, and the
mailbox (`ask_human.rb:976`), subagent lineage (`lineage.rb:146`) and Workspace snapshots
(`snapshot.rb:104`) depend on it; AC 4 drives a mailbox write

G5: `Ext::Event.new(kind:, from:, to:, payload_digest:, body:, carried_payload:, render_parent:,
causal_parents:, correlation:)`. Today the only FFI constructor is `Turn.new` (`lib.rs:1905`), hard-coding
`EventData::turn` — so three of the four `Event::KINDS` cannot be built at all.

**Acceptance criteria**

```gherkin
Scenario: every event kind can be built
  Given each of the four kinds
  When an event of that kind is built
  Then it is built

Scenario: a kind's digest matches its Ruby vector
  Given each kind and a fixed payload
  When its digest is computed
  Then it equals the recorded Ruby vector

Scenario: an unknown kind is refused
  When an event is built naming a kind that does not exist
  Then it is refused, listing the kinds

Scenario: a mailbox message is written and read back
  Given a mailbox write through the chain writer
  When the log is read
  Then the message is present with its recipient
```
→ spec files: `spec/lain/rust/event_spec.rb` (AC 1-3), `spec/lain/tools/ask_human_spec.rb` (AC 4)

**Escalation triggers**
- `event.rs:620-650` pins **per-kind digest vectors** already computed from Ruby. AC 2 must use those, not
  recompute them — recomputing from the Rust side would assert the code against itself.
- Keeping `Ext::Turn` as an alias means two names for one thing during the sequence. **Say when the alias
  goes** (T13) so it does not become permanent.
- If a kind's Ruby constructor applies a default the FFI does not, the two diverge silently on an omitted
  argument. Compare signatures field by field.

### T7 — Polymorphic store puts, and the payload's home   [wave 5] [risk: high]

**Depends on:** T5, T6
**Files:** modify `ext/lain/src/lib.rs`, `ext/lain/src/event.rs`, `dag.rs`; modify
`lib/lain/memory/index.rb`, `lib/lain/workspace/snapshot.rb`; modify
`spec/lain/rust/timeline_spec.rb`, `spec/lain/rust/store_spec.rb`
**Reuse:** `EventData`/`PayloadData` already exist; the four `Canonical.digest`-shaped kinds share one
verified shape (`memory/item.rb:53-62`, `memory/index.rb:30-52`, `plan/closure.rb:135-165`,
`plan/seam_policy.rb:70-84`)
**Shared-file wiring:** none
**Reachable from:** `Store#put` is on every commit path; AC 1 and AC 5 each drive a real put through
production code

**The hard step, and its design is decided by a constraint.**

    pub enum NodeData {
        Event(Arc<EventData>),
        Payload(Arc<PayloadData>),
        Blob(Arc<BlobData>),     // raw bytes, git-style header digest
        Canon(Arc<CanonNode>),   // { digest, canon, parent } — the other four kinds
    }

**The Blob arm is forced.** `workspace/snapshot.rb:59` digests a Blob as
`blake3("blob #{bytesize}\0" + bytes)` — a git-style header over **raw binary** — and `:44-45` says the
header *"domain-separates blob digests from the JSON-canonical digests"* and that Canonical *"would refuse
arbitrary file content."* Binary is not valid UTF-8, so a Blob **cannot** be a `Canon`.

**G3 falls out of the same change.** `Timeline::commit` puts `NodeData::Payload` then `NodeData::Event`
(payload first, or the envelope's own put dangles — `timeline.rb:74-79`), and `validate_put` grows a
`payload_digest` arm **ordered after the render edge**, matching `store.rb:71-75`'s comment about which
message a dangling chain must pin. **`spec/lain/rust/timeline_spec.rb:165`'s `eq(4)` becomes `eq(8)`**,
agreeing with `spec/lain/timeline_spec.rb:150`, and `lib.rs:225-226`'s "payload inline" comment goes.

**Rule 4 is satisfied and must be shown to be.** One crossing per put — one recursive descent into a
`Canon`, then digest/validate/insert Rust-side — which is **fewer** than Ruby's four `respond_to?` probes.
Only `Memory::Item` and `Memory::Index::Node` are ever fetched and need `from_payload` readers (~7 Ruby
lines each); `Plan::Closure` and `Plan::Supersession` are put and never fetched.

**`Opaque<Value>` is rejected** for the reason at `lib.rs:1128`: the crate holds no Ruby reference and
therefore needs no `mark`, and a `mark` walking the map from a GC callback would take the `Mutex`.

**Free bonus to implement:** the `Canon` arm recomputes the digest Rust-side and compares it with the Ruby
object's own, raising on mismatch — a per-put differential assertion **running in production** while
`Canonical` still exists in Ruby.

**Acceptance criteria**

```gherkin
Scenario: every store member kind can be put and addressed
  Given one of each of the eight kinds that enter a store
  When each is put
  Then each is addressable by its digest

Scenario: raw binary is addressed by its own scheme
  Given a blob of bytes that are not valid UTF-8
  When it is put
  Then it is addressed
  And its digest differs from the canonical digest of the same bytes

Scenario: a payload and its envelope are two objects
  Given four turns each carrying a payload
  When the store's size is read
  Then it is eight

Scenario: a put naming an absent edge is refused
  Given a store and an event naming a parent that is absent
  When it is put
  Then it is refused, naming the missing parent

Scenario: a memory item survives a round trip
  Given a memory item put into the store
  When it is fetched
  Then it equals what was put

Scenario: a digest disagreement between the two sides is refused
  Given an object whose own digest does not match its content
  When it is put
  Then it is refused
```
→ spec files: `spec/lain/rust/store_spec.rb` (AC 1, AC 2, AC 4, AC 6),
`spec/lain/rust/timeline_spec.rb` (AC 3), `spec/lain/memory/index_spec.rb` (AC 5)

**Escalation triggers**
- **AC 3 flips a pinned assertion** (`rust/timeline_spec.rb:165`'s 4 → 8). Any other spec asserting a
  store size is now wrong too; `supervisor/restart.rb`'s sidecar re-put is the known one. **Note
  `compaction/derivation_audit_spec.rb:442-449` was also a store-size assertion and simplify-03's T7
  deletes it** along with `DerivationAudit` — so if 03 has landed it is not yours to fix, and if it has
  not, report the collision rather than editing a spec another plan removes.
- **If a generic arm would require reading edges back over FFI per object, stop.** That fails
  `docs/rust-bindings.md` rule 4 and would be slower than Ruby. The four-arm enum exists precisely to
  avoid it.
- If a fifth non-Event kind turns up that fits **neither** `Canon` nor `Blob`, the enum is incomplete and
  the design needs revisiting rather than a fifth arm added reflexively.
- AC 6's production-side digest check will **fire on any existing object whose digest is stale**. If it
  does, that is a real finding about Ruby's digest computation and must be reported, not suppressed.

### T8 — Freeze the corpus. Nothing may be deleted before this is green.   [wave 6] [risk: high]

**Depends on:** T7
**Files:** create `ext/lain/corpus/{canonical,event_digest,dag,store,errors}.ndjson`,
`ext/lain/corpus/MANIFEST.json`, `spec/conformance_corpus_spec.rb`; modify `Rakefile`;
create the five Rust readers in `ext/lain/src/`
**Reuse:** **`ext/lain/src/event.rs:550-655` already embeds hand-transcribed Ruby digest vectors** — this
is that practice, generated rather than transcribed. `PropCheck::Generators.real_float` (the bundle has
`prop_check 1.0.2`) generates the float vectors.
**Shared-file wiring:** a `conformance:corpus` task in the `Rakefile`
**Reachable from:** the readers run under `cargo test` with **no Ruby VM**, which is the layer
`ext/lain/CLAUDE.md` says the Ruby suite cannot reach; AC 5 is the Ruby-side re-derivation that makes the
corpus's provenance a checked claim

**This is the move that dissolves the objection.** Generate golden vectors **from the current Ruby, while
it still exists**, check them in, then delete the Ruby. The oracle survives as data that **cannot drift**.

Five NDJSON files under `ext/lain/corpus/`, consumed by `include_str!` so the crate stays I/O-free.
Inputs are a **tagged tree**, because NDJSON cannot carry a Ruby Symbol, invalid UTF-8, NaN or a
mixed-spelling Hash — which are exactly the inputs that matter:

    {"t":"obj","v":[[{"t":"sym","v":"a"},{"t":"num","v":"1"}],
                    [{"t":"str","v":"a"},{"t":"num","v":"2"}]]}
    {"t":"bytes","v":"ff"}   {"t":"nan"}   {"t":"inf","v":"-"}

| file | vectors | why this priority |
|---|---|---|
| `canonical.ndjson` | ~4,000 | a wrong answer is a **silently wrong address** for everything else |
| `event_digest.ndjson` | ~400 | same class; also pins the sorted-key lists `event.rs:566` asserts by hand |
| `dag.ndjson` | ~200 graphs, all pairs | **replaces `dominator_meet_spec.rb`/`causal_meets_spec.rb`'s live Ruby comparison** |
| `store.ndjson` | ~150 | where T7's 8-vs-4 store size is settled as data |
| `errors.ndjson` | ~40 | byte-exact Ruby messages for every refusal |

**The float vectors are the strongest reason this card exists.** `canonical.rs` records that Ruby's float
formatting is **not re-derivable in Rust** — neither `Float#to_s` nor `ryu` nor JCS matches
`JSON.generate` — so the FFI captures Ruby's rendered text at call time. Rust's float bytes are correct
today **only because Ruby is in the loop at runtime**. Generate from `real_float` at n=10,000 plus explicit
boundaries: subnormals, the `1e-5`/`1e16` exponent switchover, `-0.0`, `Float::MAX`/`MIN`.

`MANIFEST.json` carries the seed, a blake3 per file, the generating git SHA, the Ruby version and the
`json` gem version. `spec/conformance_corpus_spec.rb` does **two** things: checks every file against its
manifest digest (survives forever), and — **while the Ruby still exists** — re-derives every vector from
Ruby and asserts equality. That second half is what makes "the corpus came from a correct Ruby" a checked
claim rather than a remembered one, and it is **the last oracle deleted** (T14).

**Honest limit, and it must be written into the manifest:** the corpus is a *regression* oracle, not a
*discovery* one. It cannot grow a case it was not generated with. That is what T1's properties and T9's
mutants are for.

**Acceptance criteria**

```gherkin
Scenario: every canonical vector matches
  Given the canonical corpus
  When each input is dumped and digested in Rust
  Then each matches its recorded bytes and digest

Scenario: every refusal message matches byte for byte
  Given the errors corpus
  When each illegal input is attempted
  Then the refusal message matches exactly

Scenario: a corpus file edited by hand is refused
  Given a corpus file with one byte changed
  When the corpus spec runs
  Then it fails, naming the file and its expected digest

Scenario: regenerating the corpus with the recorded seed is reproducible
  Given the manifest's seed
  When the corpus is regenerated
  Then every file is byte-identical

Scenario: every vector is re-derivable from Ruby
  Given the corpus and the Ruby implementation
  When each vector is re-derived
  Then each matches
```
→ spec files: `spec/conformance_corpus_spec.rb` (AC 3, AC 4, AC 5); AC 1 and AC 2 are `#[cfg(test)]`
readers in Rust

**Escalation triggers**
- **AC 5 is the card's whole justification and it can only run while Ruby exists.** If it cannot be made to
  pass, the corpus's provenance is a remembered claim and **the deletion sequence must not proceed**.
- The tagged encoding must be **lossless** for Symbols, invalid UTF-8, NaN, `-0.0` and mixed-spelling
  Hashes. If any of those cannot round-trip, the corpus silently omits the inputs that matter most —
  test the encoder against each before generating 4,000 vectors.
- **The corpus data is not line-reviewable.** Review the *generator* and spot-check ~10 vectors; do not
  pretend a 4,000-line NDJSON diff was read. Say so in the commit message.
- Cap the whole corpus at ~2 MB so the test binary stays sane. If the float coverage alone exceeds that,
  reduce n and record the reduction in the manifest rather than silently sampling less.
- A regenerated vector that **changed** is a behaviour change and must be argued for in the commit message,
  never regenerated away.

### T9 — Mutants as the quantitative gate   [wave 7] [risk: medium]

**Depends on:** T8
**Files:** create `ext/lain/mutants-baseline.txt`, `ext/lain/mutants-survivors.md`; modify `Rakefile`
**Reuse:** CLAUDE.md's own scoring rule — *score on the count equalling the captured baseline* — applies
directly, because an `unviable` mutant is an **unrun** one, not a surviving one
**Shared-file wiring:** a `rust:mutants` task in the `Rakefile`
**Reachable from:** a chunk-boundary gate, not a hook; AC 1 is the gate itself

    cargo mutants -p lain --baseline=run \
      --file ext/lain/src/canonical.rs --file ext/lain/src/event.rs \
      --file ext/lain/src/digest.rs    --file ext/lain/src/dag.rs \
      --file ext/lain/src/graph.rs

Three required conditions:

1. **`caught + unviable + missed` EQUALS the checked-in baseline.**
2. **Zero survivors in `canonical.rs`, `event.rs`, `digest.rs`** — these compute addresses, and a survivor
   there is a silently-wrong-content-address risk. 100%, not 95%.
3. **≥95% of viable mutants killed in `dag.rs`/`graph.rs`, with every survivor enumerated with a written
   reason** in `mutants-survivors.md`. An enumerated, justified survivor (a `contains_key` fast path that
   is observationally equivalent, a `debug_assert`) is different in kind from one nobody looked at — the
   same principle as `bin/comment-census` reporting UNCLASSIFIED rather than sweeping.

**This is the measurement that replaces "Ruby agrees."** Rule 5 asserted a *relation between two
implementations* and said nothing about whether the tests constrain either. A mutation score says exactly
that, about one implementation, as a number.

**Acceptance criteria**

```gherkin
Scenario: the mutant count matches the baseline
  When the mutation sweep runs
  Then the total of caught, unviable and missed equals the recorded baseline

Scenario: no mutant survives in the address-computing modules
  When the mutation sweep runs
  Then the canonical, event and digest modules report no survivors

Scenario: every survivor elsewhere is named with a reason
  When the mutation sweep runs
  Then each surviving mutant appears in the survivors file with a written reason

Scenario: a deliberately weakened property lets a mutant through
  Given one law property removed
  When the sweep runs
  Then at least one mutant survives that did not before
```
→ spec file: none — a cargo tool and a rake task. AC 4 is the meta-check that the gate can fail, and it
should be run once by hand and recorded, not automated.

**Escalation triggers**
- **`CLAUDE.md:258-261`'s mutation warning is about the Ruby/bootsnap harness and does not apply** — but
  its *scoring discipline* does. If the count does not equal the baseline, some mutants did not build, and
  a sweep that reports "no survivors" over half the mutants is worse than none.
- A multi-minute sweep in `pre-commit` would be abandoned within a day. **Chunk-boundary only**, and say so
  in the task's description so nobody moves it.
- AC 4 is the only thing proving the gate is not vacuous. Run it once, record it, and if removing a
  property changes *nothing*, the property was not constraining anything.
- `cargo-mutants` must be installed. It is not on PATH today; adding a developer tool is a toolchain change
  worth naming in the commit, and CI needs it too or the gate is local-only.

### T10 — The seam, without switching   [wave 7] [risk: medium]

**Depends on:** T8
**Files:** create `lib/lain/dag/factory.rb`; modify `lib/lain/dag.rb` (the subtree index
`simplify-09-orders-as-types.md`'s T1 creates) to require it; modify the remaining
`Timeline.new`/`Store.new` call sites

**Name it `Dag::Factory`, not `Dag`.** `simplify-09-orders-as-types.md`'s T1 (landed, `62aa555d`) has
already made `lib/lain/dag.rb` the namespace's index and put the render meet at
`lib/lain/dag/render_ancestry.rb` — so a factory *called* `Dag` would still collide with the module
holding it. The index carries one manifest line in `lib/lain.rb` already; the factory gets a line
inside the index.
> **2026-09-14, amended.** "The three meets" overstates what landed: only the render order ported to
> Ruby, as a stateless `Dag::RenderAncestry` **module** (`.meet`, `.diverge_at`, `.below?`) with no
> state of its own to be "store-bound" — the plan's own Intent chose *not* to port dominance or
> causal ancestry into Ruby at all, so `lib/lain/timeline.rb` no longer defines `dominator_meet`,
> `causal_meets`, `Dominators` or `CausalAncestry` in any form; those exist only in
> `ext/lain/src/{graph,algebra}.rs`. `Dag::RenderAncestry` is therefore not itself the construction
> seam this card needs — it is a pure function over two already-constructed `Timeline`s, reached
> without going through `Timeline.new`/`Store.new` at all. What it repoints (see T11's escalation
> note below) is a *different* seam: `Ext::Timeline#diverge_at` (`lib.rs:1668-1695`) still calls
> `dag::meet` directly rather than through the trait, and the Rust-side singleton
> `Ext::Dag::RenderAncestry` (`lib.rs:2023`) is a plain class carrying `meet`/`below?` with **no
> `diverge_at`** — while the Ruby module this card's factory must eventually stand beside has all
> three. The store flip's repoint to `Ext::Dag::RenderAncestry` needs both fixed, and neither is
> this card's job to fix; it is named here so T11 does not discover it late.

**Reuse:** **`simplify-09-orders-as-types.md`'s T1 has already moved the render meet off `Timeline`**
into `Dag::RenderAncestry`; that is one seam handled, but not the construction seam below. This card
covers the 21+~20 sites, unchanged in count by that move.
**Shared-file wiring:** a manifest line in `lib/lain.rb`
**Reachable from:** every construction of a timeline or a store; AC 3 asserts no bare construction remains

Route the remaining sites through one factory, **with no switch**. `Lain::Timeline` stays the
implementation. Mechanical, zero behaviour change, suite green — the largest diff in the plan and the
shallowest read.

The stale doc counted 16 sites; today it is **21 live `Timeline.new` across 19 files** plus ~20 bare
`Store.new`. `simplify-09-orders-as-types.md` did not touch construction — it moved an operation, not
an object's home — so this count stands unchanged at `62aa555d`; verify it again at this card's start
rather than trusting either number.

**Acceptance criteria**

```gherkin
Scenario: every timeline comes from the factory
  When the library is searched for direct timeline construction
  Then only the factory constructs one

Scenario: every store comes from the factory
  When the library is searched for direct store construction
  Then only the factory constructs one

Scenario: behaviour is unchanged
  When the suite runs
  Then it passes with the same example count

Scenario: the factory answers which implementation it built
  When the factory is asked
  Then it names the Ruby implementation
```
→ spec file: `spec/lain/dag_spec.rb` (AC 1, AC 2, AC 4 — the first two as enumerations over `lib/`);
AC 3 is the suite

**Escalation triggers**
- 41 call sites across ~30 files is a wide, shallow diff. **Review it by `git diff --stat` plus a grep
  proving no bare construction remains**, not by reading 41 hunks.
- If a call site constructs a `Timeline` inside a **class body** or a constant, the factory must be loaded
  before it — a load-order failure presenting as `NameError` at boot.
- `Timeline.empty(store:)` and `Timeline.new(head_digest:, store:)` are two entry points. The factory needs
  both, and `lib.rs:1250` records that routing `Timeline::empty` through `scan_args` would **change the
  exact `ArgumentError` text** — so the Ruby factory must not change it either.

### T11 — Flip the factory   [wave 8] [risk: high]

**Depends on:** T10
**Files:** modify `lib/lain/dag.rb`; modify whatever the flip reveals
**Reuse:** the full Ruby DAG spec suite becomes the differential run **in reverse** — 1,123 spec code lines
now exercising Rust through the boundary
**Shared-file wiring:** none
**Reachable from:** everything; AC 1 is the suite green with the flip in force

**This is where the schedule actually lives, and it is unbudgetable by design.** Flip the factory to
`Ext`. `pspec` becomes the differential run in reverse, and **whatever fails is the real parity list**.

Expect fallout at: `store.size` assertions (T7 changed the semantics), `Ledger` pricing (simplify-02's T4
is the canary — if it reports zero, the block form did not land), `Event::Projection` over `Ext::Event`,
and `ChainWriter`.

**Gate: `pspec` green with the factory flipped AND `LAIN_DAG=ruby bundle exec rake pspec` still green.**
Keeping both runs green for exactly one chunk is what makes the flip revertible in one commit.

**Acceptance criteria**

```gherkin
Scenario: the suite passes against the Rust implementation
  Given the factory flipped to Rust
  When the suite runs
  Then it passes

Scenario: the suite still passes against the Ruby implementation
  Given the environment selecting Ruby
  When the suite runs
  Then it passes

Scenario: a ledger prices a timeline above zero
  Given a run with token usage
  When it is priced
  Then the total is greater than zero

Scenario: both implementations agree on every corpus vector
  Given the conformance corpus
  When each implementation answers
  Then both match
```
→ spec files: the whole suite (AC 1, AC 2), `spec/lain/ledger_spec.rb` (AC 3),
`spec/conformance_corpus_spec.rb` (AC 4)

**Escalation triggers**
- **AC 3 is the canary for the plan's worst failure mode.** `ledger.rb:109` passes a block to
  `#ancestors`; against an arity-0 Rust method the block is ignored and **every timeline prices at zero
  with no exception**. If AC 3 reports zero, simplify-02's T4 did not land or did not work — **stop**.
- Do not fix fallout in this card. **Record the parity list**, land the flip behind the environment switch,
  and fix each item in its own commit. A flip plus five fixes in one commit is unrevertible.
- If `LAIN_DAG=ruby` cannot keep the Ruby path green — because T7's store-size change is not conditional —
  the flip is not revertible and the gate is not met. Say so before proceeding.
- `spec/lain/rust/dominator_meet_spec.rb` and `causal_meets_spec.rb` name **Ruby as their oracle**. With
  the flip in force they compare Rust against Ruby in the other direction, which still works — but after
  T13 they must be rewritten against the corpus. Note it here; do it there.
  > **2026-09-14, amended — already moot.** `simplify-09-orders-as-types.md`'s T4 (landed, `047c55d6`)
  > deleted the Ruby `Dominators`/`CausalAncestry` implementations outright rather than leaving them
  > for this plan to retire, so neither spec names Ruby as an oracle any more: reading them today,
  > `dominator_meet_spec.rb`'s docstring already says "Rust is the only implementation of either" and
  > compares against fixtures small enough to check by hand plus the named vectors pinned in
  > `ext/lain/src/graph.rs`. This trigger cannot fire because its premise is gone before T11 starts —
  > there is no Ruby comparison direction to flip, in either direction. T13's job of rewriting the two
  > specs against T8's corpus stands regardless, since "fixtures small enough to check by hand" is a
  > weaker guarantee than a generated, checked-in corpus.

### T12 — Rehome the two units that are Ruby logic   [wave 9] [risk: medium]

**Depends on:** T11
**Files:** move `lib/lain/event/projection.rb` → `lib/lain/event_log/projection.rb`;
move `lib/lain/event/chain_writer.rb` → `lib/lain/event_log/chain_writer.rb`; move their specs;
modify every caller
**Reuse:** both already work over an event log's envelope fields, which `Ext::Event` (T6) supplies
**Shared-file wiring:** a new `lib/lain/event_log.rb` index, or entries in `lib/lain.rb`
**Reachable from:** `ChainWriter#put` is reached from the mailbox, subagent lineage and Workspace
snapshots; `Projection` from the Journal. AC 1 and AC 2 drive one each.

**These move; they do not vanish — and the accounting must say so.** `Event::Projection` (63 code) is a
pure fold over an event log needing only `kind`, `to`, `causal_parents` and `digest`.
`Event::ChainWriter` (28) is a writer plus observer seam, becoming ~24 lines over `Ext::Event`/`Ext::Store`.
Their specs (169 + 115 = 284) move with them.

**Counting them as deleted would overstate the win by ~91 lib + ~284 spec lines.** Say the real number.

**Acceptance criteria**

```gherkin
Scenario: a projection still folds a log
  Given a log with spawns and messages
  When it is projected
  Then the projection names both

Scenario: a chain writer still writes every kind
  Given each non-turn kind
  When it is written through the chain writer
  Then it is addressable in the store

Scenario: the mailbox still delivers
  Given a question written to the mailbox
  When the mailbox is read
  Then the question is present

Scenario: a subagent's lineage is still recorded
  Given a spawn
  When the lineage is read
  Then the child names its parent
```
→ spec files: the moved specs (AC 1, AC 2), `spec/lain/tools/ask_human_spec.rb` (AC 3),
`spec/lain/tools/subagent/lineage_spec.rb` (AC 4)

**Escalation triggers**
- Keep the diff a **move** so `git log --follow` works. A rewrite-in-place loses the history of a unit that
  is being preserved precisely because it has value.
- `ChainWriter` has a `Diverged` error (`turn_feed.rb:26` has one too — different class). If either is
  rescued by its old constant path, the move breaks a rescue silently.
- If `Projection` turns out to need something `Ext::Event` does not expose, **stop and add it in T5's
  shape** rather than keeping the Ruby `Event` alive for one reader.

### T13 — Delete the Ruby implementation   [wave 10] [risk: high]

**Depends on:** T11, T12
**Files:** delete `lib/lain/timeline.rb`, `lib/lain/store.rb`, `lib/lain/event.rb`,
`lib/lain/event/payload.rb`, `spec/lain/timeline_spec.rb`, `spec/lain/store_spec.rb`,
`spec/lain/event_spec.rb`; modify `lib/lain/dag.rb`; rewrite
`spec/lain/rust/dominator_meet_spec.rb` and `causal_meets_spec.rb` against the corpus
**Reuse:** the corpus (T8) is now the oracle those two specs used Ruby for
**Shared-file wiring:** remove the four `require_relative` lines from `lib/lain.rb`; drop the
`LAIN_DAG=ruby` switch and the `Ext::Turn` alias
**Reachable from:** everything the factory builds; AC 1 is the suite green with no Ruby DAG present

> **2026-09-14, amended — the deletion list changes on both ends.** It **gains**
> `lib/lain/dag/render_ancestry.rb`: `simplify-09-orders-as-types.md`'s T1 ported the render meet to
> Ruby as `Dag::RenderAncestry` (a stateless module — `.meet`, `.diverge_at`, `.below?` — over the
> `Ext`/Ruby `Timeline` boundary), so once the flip is permanent this module is either deleted with
> the rest or **repointed**, kept as a constant alias to `Ext::Dag::RenderAncestry`, if something
> still wants the Ruby-facing name. Either way it is this card's decision to make, and its own
> escalation trigger applies: `Ext::Dag::RenderAncestry` (`lib.rs:2023`, a plain class) has no
> `diverge_at` today while the Ruby module does, so a repoint needs that method added to the Rust
> singleton first, and `Ext::Timeline#diverge_at` (`lib.rs:1668-1695`) needs to call through the
> trait rather than `dag::meet` directly — otherwise the repoint routes some callers through the
> trait and one through a private shortcut, which is the exact silent-divergence shape this whole
> plan exists to close. It **loses** nothing new beyond what is already true: `timeline.rb`'s
> dominance and causal classes were never ported to Ruby by that plan (Intent says so explicitly),
> so "already gone" describes their absence from day one, not a deletion this card still has to do.

**380 code lines of implementation and 839 of spec.** The shared law groups —
`meet_semilattice.rb` (60), `store_laws.rb` (18), `regular.rb` (37), `canonical_laws.rb` (89) — **stay**,
reclassified from differential to **single-implementation conformance**, wired from `spec/lain/rust/*`.

**`spec/lain/rust/*` (790 spec code lines) is permanent**, reclassified from differential oracle to
**boundary conformance** — because no proptest property and no mutant ever compiles `mod ffi`, and both of
this plan's silent divergences lived there.

**Add the spec that closes that bug class**: enumerate `Lain::Ext::Timeline.instance_methods(false)` and
fail on any method with no example, since the registration table at `lib.rs:1900-1963` is exactly what no
Rust tool can see.

**Do NOT delete `Canonical`** — see Open decisions.

**Acceptance criteria**

```gherkin
Scenario: the suite passes with no Ruby data model present
  Given the Ruby timeline, store and event deleted
  When the suite runs
  Then it passes

Scenario: every binding has at least one example
  When the Rust timeline's own methods are enumerated
  Then each is exercised by at least one example

Scenario: the law groups still run against the surviving implementation
  When the law groups run
  Then each law is exercised

Scenario: the dominance and causal specs assert against frozen vectors
  When those two specs run
  Then each compares against a recorded vector rather than a second implementation
```
→ spec files: `spec/lain/rust/binding_coverage_spec.rb` (**new, AC 2 — the fix for the arity bug class**),
the relocated law groups (AC 3), the two rewritten specs (AC 4)

**Escalation triggers**
- **AC 2 is the plan's most important new spec.** `mod ffi` is invisible to `cargo test`, so the arity-0
  `ancestors` registration could only ever have been caught here. If it cannot enumerate the registration
  table, say so — that gap is permanent and must be written down.
- `Ractor.shareable?` cannot be replaced by `Send + Sync`. `ext/lain/CLAUDE.md` is explicit:
  `Mutex<T>`, `AtomicUsize` and `OnceLock` are all `Send + Sync` **and** interior-mutable and sail
  straight through. `spec/lain/rust/share_probe_spec.rb` and the `Ractor.shareable?` assertions in
  `turn_spec.rb` are irreplaceable — **keep them**.
- Exact exception **classes and ancestry** can only be checked from RSpec. The corpus carries message
  bytes; only a spec checks that the raise is `Lain::Ext::Store::MissingObject` descending from
  `Lain::Error`.
- `lib.rs:1250` records that routing `Timeline::empty` through `scan_args` would change the exact
  `ArgumentError` text. Ruby-observable arity and keyword wording are RSpec-only residuals.
- If anything still references `Lain::Timeline` after T10 and T11, **stop** — the factory did not cover
  it, and deleting the constant would be a `NameError` in production rather than in a spec.

### T14 — Delete the last oracle   [wave 11] [risk: low]

**Depends on:** T13
**Files:** modify `spec/conformance_corpus_spec.rb`
**Reuse:** the manifest-digest half of the spec, which survives forever
**Shared-file wiring:** none
**Reachable from:** the corpus spec runs in the suite; AC 1 is that the surviving half still fails on a
tampered file

Delete the Ruby re-derivation half of `spec/conformance_corpus_spec.rb` (~25 lines) — it cannot run once
the Ruby DAG is gone. **Keep the manifest-digest half**, which is what makes a corpus edit a loud diff
forever.

**Its own commit**, so the revert is one commit.

**Acceptance criteria**

```gherkin
Scenario: a tampered corpus file is still refused
  Given a corpus file with one byte changed
  When the corpus spec runs
  Then it fails, naming the file

Scenario: the corpus still verifies against the implementation
  Given the corpus
  When the Rust readers run
  Then every vector matches

Scenario: the manifest records that the Ruby oracle is retired
  When the manifest is read
  Then it names the commit at which re-derivation stopped being possible
```
→ spec file: `spec/conformance_corpus_spec.rb`

**Escalation triggers**
- Once this lands, **the corpus can never be regenerated from Ruby again**. AC 3 is not bookkeeping — it is
  the only record of what the vectors were derived from. If the manifest cannot carry it, put it in the
  commit message and say so.
- If the float vectors' provenance was never fully checked in T8's AC 5, **this card must not land**.
  Retiring an oracle whose output was never verified is the failure this whole plan was designed to avoid.

## Integration checks

After the last wave:

- `bundle exec rake pspec` green, **with the example count recorded and the arithmetic written out**. This
  plan deletes 839 spec lines, rehomes 284, and adds a binding-coverage spec.
- `cargo test && cargo clippy --all-targets -- -D warnings && cargo fmt -- --check && cargo deny check` —
  the full Rust gate, including `deny` because T1 adds a dependency tree.
- **`bundle exec rake rust:mutants` against the recorded baseline**, with the survivors file read. T9's
  gate is the measurement that replaced rule 5, and an unread survivors file makes it decorative.
- **`bundle exec rspec spec/conformance_corpus_spec.rb`** and the five Rust corpus readers.
- **`bundle exec rspec spec/lain/rust/`** — 790 spec lines, now the only layer touching the boundary.
- **`cargo test --release`** once, at the chunk gate, to catch anything surviving only because a
  `debug_assert` fires in the debug profile.
- **`bundle exec rspec spec/lain/ledger_spec.rb` and read the number.** A ledger pricing at zero is this
  plan's signature failure and it does not raise.
- **`bundle exec rspec spec/lain/rust/share_probe_spec.rb` and `spec/algebra_laws_spec.rb`** — the two
  guarantees Rust cannot take over.
- **Measure the suite wall before and after.** `spec/lain/timeline_spec.rb`'s law groups build ~30-commit
  union graphs per example, four laws × two operators × two implementations. **Do not promise a number** —
  `docs/spec-suite-performance.md`'s rule is profile first.
- **Manual, human:** read the T3 doc edits end to end, and read one `cargo expand` of a
  `declare_meet_semilattice!` invocation. Those are the ~250 judgment-bearing lines of this entire plan;
  everything else is skim-and-trust-the-gates.
- **Manual, human:** one `lain chat` session that commits several turns, then `/rewind`, then `/undo`. The
  DAG is the substrate for all three and a wrong answer there is a silently wrong content address.
