# Research — orders as types, no registry, and where the rest of the weight is

Read-only research pass with two exploratory spikes, 2026-09-14, against `main` @ `9368e249`.
Nothing on `main` was changed. The spikes live in two uncommitted worktrees (named in §4) and
**both worktrees were cut from `b1927ce7` (2026-08-25, 340 commits behind HEAD)** by the agent
harness, not by choice. Their findings are feasibility evidence and their line counts are
indicative; re-derive any number before quoting it against HEAD.

Commissioned after `simplify-09` was dropped and `research-algebra-registry-vs-operations.md`
concluded the registry earns its place *today*. The human's standing direction is to move away from
the `Registry`, to express algebras as *types* the way a Rust zero-sized type does, to move work to
Rust under a separate plan, and to simplify the whole application — with no production users and
no backward-compatibility obligation.

---

## 0. The answer, up front

1. **Delete the Ruby registry and put each subject's laws in that subject's spec.** The spike did
   it: net **≈ −917 `lib/` and −1,811 `spec/` lines**, suite green, and the four cases that had
   *only* ever been proven through the sweep got their own law runs written. What is lost is the
   load-time typo check and the "declare it and it is swept" guarantee — both worth less than the
   ~3,700 lines and the Zeitwerk blocker they cost, for one developer on a study bench.

2. **The three meets become three ORDER types, and the Timeline is an element.** In Ruby now:
   `Dag::RenderAncestry`, `Dag::Dominance`, `Dag::CausalAncestry`, stateless modules answering
   `meet(a, b)` / `below?(a, b)` over Timelines, with `CausalAncestry` answering `meets` and
   *not* being a semilattice by type rather than by refutation entry. In Rust now: the same three
   as ZSTs behind a sealed `MeetSemilattice` trait, with the FFI generic over the order — the
   Rust spike found that generic FFI method is the *production consumer* that makes the trait
   earn its place under `ext/lain/CLAUDE.md`'s own rule. The names are the seam: when the store
   flips to Rust under the separate plan, `Dag::RenderAncestry` is one constant to repoint, not 21
   `Timeline.new` sites.

3. **The algebra was never where the weight is.** The whole apparatus is ~3,700 lines of 200,000.
   The census puts the real mass in: nine ask/approve mechanisms (~10k lib / 25k spec), the epic
   tier plus its own second agent factory (~6.5k), five wiring layers (~5.3k), telemetry records
   emitted and never read (~2k), and three summarizers, two secret mechanisms, two ledgers, twelve
   catalogs. §5 ranks them. One correction to the census's own headline: the bench cluster is the
   **deliverable**, not a deletion target; what competes with it for weight is the agent-product
   surface built around it.

---

## 1. Measured, at HEAD

Code lines are non-blank, non-comment unless marked raw.

| | files | lines |
|---|---|---|
| `lib/` | 716 | 47,755 |
| `spec/` | 723 | 149,618 (3.1 : 1 against lib) |
| `exe/lain` | 1 | 525 |
| `ext/lain` (Rust) | 12 | 9,131 raw |
| `crates/lain-core` | — | 3,996 raw |

**The algebra apparatus, whole:** `lib/lain/algebra.rb` 315 raw + `algebra/*.rb` 425 = **740 lib**;
`spec/algebra_laws_spec.rb` 352 + `spec/lain/algebra_spec.rb` 1,085 + `spec/support/algebra_generators.rb`
709 + five algebra shared-example groups 787 = **2,933 spec**. Four to one. It carries 20 claims and
6 refutations.

**Which declared operations production actually calls** (outside the declaring class, in `lib/`/`exe/`):

| operation | production caller | verdict |
|---|---|---|
| `Context::Combinator#>>` | `context.rb:40`, `plan/linear_rewrite.rb:119`, `compaction/prepared.rb:130`, `compaction/scheduler.rb:239` | live |
| `Usage#+` | `ledger.rb:54,76`, `event/projection.rb:89` | live |
| `Compaction::Strategy::Base#\|` | `cli/compaction_strategy.rb:169` | live |
| `IntervalPartition#meet` | `compaction/strategy/composed.rb:124` | live — **the only live meet** |
| `Toolset#only` (attenuation) | `role.rb:23`, `mode/posture.rb:74`, `tool/spawn_policy.rb:65`, `tools/subagent.rb:1088` | live |
| the elementwise / pure strategies' `#blocks`, `#call` | the render and compaction pipelines | live |
| `Middleware::Base#>>` | none | spec-only |
| `Strategy::Replacement#+` | none outside its file | spec-only |
| `Timeline#meet`, `#dominator_meet`, `#causal_meets`, `#diverge_at` | none (eight **spec** call sites for `#meet`) | spec-only |
| `Lain::Ext::Timeline` × 3 | none | spec-only |

So the three-meet story — a hand-rolled Cooper/Harvey/Kennedy dominator tree and a causal closure in
Ruby (~150 lines), *and* the same three over `petgraph` in Rust, *and* property tests for both in two
languages, *and* six registry entries — has **no production consumer**. `ARCHITECTURE.md:189-206`
specifies `dominator_meet` as the safe-compaction checkpoint; nothing has been built on it.

**The Rust DAG is a shadow.** `Ext::Store`, `Ext::Timeline`, `Ext::Turn` appear in zero `lib/` or
`exe/` files. Production uses five bindings only: `blake3_hex`, `TreeSitter`, `AstGrep`, `Fuzzy`,
`Prompt`, `Bm25`. The `Ext::Timeline` reopen at `lib/lain.rb:144-163` exists solely to file registry
entries for a class nothing constructs outside `spec/lain/rust/`.

**The registry is the Zeitwerk blocker.** `simplify-11` (`:80-92`) names `Algebra.registry.seal` as
"the one place the manifest is doing real work that autoloading cannot replicate". Remove the seal
and that plan's stated payoff — **−748 `require_relative` lines, −24 index files, `lib/lain.rb`
99 → ~40** — is unblocked. `lib/lain.rb` is the most-churned file in the repo (82 commits in nine
weeks for a require list).

**No trait-based or ZST algebra exists in Rust today.** The only ZST-as-policy in the crate is
`bm25.rs`'s `SurfaceTokenizer`. Laws are plain `#[test]` functions under a comment fence
(`dag.rs:391-410`, `graph.rs:654-683`), and `ext/lain/CLAUDE.md:138-142` rules *against* a trait
"written solely so tests can call it".

---

## 2. What "algebra as a type" should mean here

The prior research note found the right thing and stopped one step short. Rust's strength is not
that the operation is a type; it is that **declaration and proof are one artifact** (the macro).
Taken seriously, that says two things about the Ruby side:

- The *proof* belongs next to the *subject*, in its spec, as `include_examples` with the population
  beside it. That is the one-artifact shape Ruby can actually offer. A sweep that finds claims by
  walking a global is the *opposite* of one artifact — it is two artifacts kept in sync by a third.
- The *order* is the thing with a name. A Timeline is `(head, store)`, an element. "Which order?"
  is a type, not a method-name suffix.

### The Ruby shape (built in the spike)

```ruby
module Lain
  module Dag
    module RenderAncestry
      module_function

      def meet(one, other)
        Dag.same_store!(one, other)
        mine = one.ancestor_digests.to_h { |digest| [digest, true] }
        common = other.ancestors.find { |turn| mine.key?(turn.digest) }
        one.checkout(common&.digest)
      end

      def diverge_at(one, other) = meet(one, other).head

      def below?(one, other) = one.ancestor_of?(other)
    end
  end
end
```

`Dag::Dominance.meet(a, b, dominators:)` / `.below?` carries the memoised `Dominators` and `Tree`
moved verbatim; `Dag::CausalAncestry.meets(a, b)` / `.below?` carries the old
`Timeline::CausalAncestry`. `Dag::CrossStore` is the one refusal, raised by `Dag.same_store!`; the
Rust side keeps its byte-identical message. `Timeline` loses the three meets and `diverge_at` and
keeps `commit`/`fork`/`checkout`/`ancestors`/`ancestor_of?`.

**Stateless, not store-bound.** `simplify-09`'s T4 proposed `RenderMeet.new(store)`. The prior
research note was right that the faithful ZST analogue takes the store *through the elements*, and
the spike confirms it costs nothing: the store is on the Timeline.

**The refutation becomes a type distinction plus one exhibit.** `CausalAncestry` simply does not
answer `meet`; its spec has one example — *"answers more than one maximal lower bound over a
three-way criss-cross"* — and one more showing `checkout(meets.first)` and `.last` each fail
associativity. That is the whole "EXHIBIT what the reason says" obligation, without a battery
framework to carry it.

**Laws per subject, evidence at the call site:**

```ruby
# spec/lain/usage_spec.rb
include_examples "a commutative monoid", op: :+, identity: Lain::Usage::ZERO, population: -> { ... }
# spec/lain/dag/dominance_spec.rb
include_examples "a meet semilattice under ancestry",
                 population: -> { forest }, meet: ->(a, b) { Lain::Dag::Dominance.meet(a, b, dominators:) },
                 ancestor_of: ->(m, a) { Lain::Dag::Dominance.below?(m, a) }
```

The five shared-example groups stay exactly as they are; they *are* the laws, and
`spec/lain/rust/timeline_spec.rb` already includes them directly against `Ext::Timeline` today,
independently of the sweep — the Rust side was double-covered.

**`Elementwise` stops generating code.** Two subjects, two one-line `flat_map`s written by hand.
A template-method mixin bought nothing at two sites. **`Pure#pure?` goes** (no production caller).
The one production reader of purity the spike found — `Compaction::DerivationAudit#purity` at the
spike's older base; deleted on `main` by `simplify-03` — became a per-class `PURITY` constant, which
is the honest shape for "a fact the code reads": a constant, not a registry query.

### The Rust shape (built in the spike)

```rust
mod sealed { pub trait Proven {} }

pub trait MeetSemilattice: sealed::Proven {
    type Ctx; type Elem;
    const BOTTOM: &'static str;
    fn meet(ctx: &Self::Ctx, a: &Self::Elem, b: &Self::Elem) -> Result<Self::Elem, DanglingDigest>;
    fn below(ctx: &Self::Ctx, m: &Self::Elem, a: &Self::Elem) -> Result<bool, DanglingDigest>;
}
pub trait MaximalLowerBounds { type Ctx; type Elem; fn meets(..) -> Result<Vec<Digest>, DanglingDigest>; }

pub struct RenderAncestry;  impl MeetSemilattice for RenderAncestry { /* dag::meet, dag::ancestor_of */ }
pub struct Dominance;       impl MeetSemilattice for Dominance      { /* graph::dominator_meet, graph::dominates */ }
pub struct CausalAncestry;  impl MaximalLowerBounds for CausalAncestry { /* graph::causal_meets */ }

declare_meet_semilattice!(RenderAncestry, tests: render_ancestry_laws, population: crate::dag::tests::law_population);
declare_meet_semilattice!(Dominance,      tests: dominance_laws,       population: crate::graph::tests::law_population);
```

The macro emits, in one expansion, the `Proven` impl, `const _: () = assert!(!BOTTOM.is_empty())`,
and a `#[cfg(test)]` module with the four laws over the named population. Verified at the compiler:
a hand-written `impl MeetSemilattice for Rogue` is `E0277: Rogue: Proven is not satisfied`;
instantiating a `S: MeetSemilattice` generic at `CausalAncestry` is `E0277`. The refutation is a
type error.

**The finding that settles the CLAUDE.md rule.** `cargo clippy --all-targets` (no `cfg(test)`)
rejected the trait as dead code — the linter stating the rule. The way out was a real consumer:
two generic FFI methods, `Timeline::meet_via::<S>` and `below_via::<S>`, bounded on
`MeetSemilattice<Ctx = StoreMap, Elem = Option<Digest>>`, with `#meet`, `#dominator_meet`,
`#ancestor_of?`, `#dominates?` becoming one-line delegators. That generic *is* "a production
function generic over the structure". The rule at `ext/lain/CLAUDE.md:138-142` is satisfied,
not reversed — but the paragraph after it ("the Ruby shared example group is the authority") has
to change, because with the registry gone there is no Ruby declaration for a Rust type to inherit.
The four law names stay pinned to the Ruby group's names, which is what keeps the two lists from
drifting.

Eight hand-written law tests in `dag.rs` and `graph.rs` (~150 lines with banners) become exact
duplicates of the macro output and should go; the non-law characterisation tests
(`causal_edges_participate_in_the_dominator_meet`, `dominance_is_stronger_than_reachability`, the
allocation counts) are the discriminating ones and stay. A fourth order would cost one ZST, one
macro line, one delegator, one registration — against today's copied FFI method and 65-line law
block.

### What is genuinely lost, per the prior note's five jobs

| job | fate |
|---|---|
| J1 load-time refusal of a mis-declared operation | **lost.** A typo surfaces when the law runs, not at `require`. Same day, different minute. |
| J2 enumerable population for a sweep | **lost by design.** "Declare it and it is swept" becomes "write the `include_examples`". The spike found four operations whose *only* law run was the sweep (`Strategy::Identity` purity, `Replacement#+`, `Strategy::Base#\|`, `IntervalPartition#meet`) and wrote them. Nothing will flag the next one. |
| J3 evidence carriage | moot — `identity:`/`analysis:`/`dual:` sit beside the population that exercises them, which is where they read best. Prose bottoms were documentation, never data. |
| J4 per-operation granularity | kept trivially; the Dag orders are per operation by construction. |
| J5 refutations as positive obligations | **mostly lost.** Witnesses survive as examples; nothing enforces that a negative *has* one. |
| J6 the seal | moot, and its removal unblocks Zeitwerk. |
| J7 claims about a Rust class | moot — the Rust spec includes the group directly, as it already did. |

The trade is J1, J2 and J5's *enforcement* against ~3,700 lines, the Zeitwerk blocker, one
metaprogrammed method generator, and one process-global. For a solo study bench that is a good
trade; on a multi-team library it might not be. The bench's actual guarantee — the laws run — is
unchanged.

### Three shapes considered, and why this one

- **A. Registry-in-spec.** Delete `lib/lain/algebra`, keep the sweep, move the claims table into
  `algebra_generators.rb` next to the generators. Keeps J1/J2/J5 at spec time. Rejected: it keeps
  ~1,000 lines of sweep-and-battery machinery whose only remaining purpose is catching a missing
  `include_examples`, and it keeps the claim away from the subject.
- **B. No registry; per-subject laws; orders as modules (Ruby) and ZSTs (Rust).** Chosen. Above.
- **C. Orders as Rust ZSTs only, Ruby merely calls.** The right *end state*, blocked on the store:
  a Rust order needs a `StoreMap`, and production Timelines are over a Ruby `Store`. Do B now with
  the Rust ZSTs in place; C falls out of the store flip under the separate Rust plan, as three
  constants repointed.

### The question B does not answer, and the human should

`Dominance` and `CausalAncestry` have no consumer in either language. Two honest options:

- **Keep them as bench capability** — implemented, property-tested, waiting for the safe-compaction
  checkpoint `ARCHITECTURE.md:189-206` specifies. Cost: ~150 Ruby lines of hand-rolled dominators
  and closure plus their specs, kept in parity with `petgraph` in Rust.
- **Retire the Ruby implementations now** and let the Rust ones be *the* implementation, reachable
  only once the store is Rust. `Dag::RenderAncestry` stays in Ruby (cache-break localisation is
  its story). This is the smaller tree and it puts the unbuilt feature where it will be built.

I lean to the second: two implementations of an operation nobody calls is the definition of the
weight this pass was asked to find.

---

## 3. The spikes

### Ruby: delete the registry — `.claude/worktrees/agent-ad39e9a42aa2c1453`

| | examples | failures | wall |
|---|---|---|---|
| baseline at `b1927ce7` | 15,749 | 1 pre-existing (`review/deletability_spec.rb:469`) | 52s |
| after | 15,598 | 0 | 40s |

−151 examples, all accounted for (the registry's own unit tests, the sweep's coverage and
battery-pin examples, the per-subject "the declared algebra" readers) minus the new law groups.
Whole-tree rubocop clean. Diff: `lib/` +164/−615 across 18 tracked files, −787 in 7 deleted, +321 in
4 new; `spec/` +698/−907 across 31, −2,124 in 3 deleted, +522 in 3 new.

The first run had six failures from **eight spec sites** still calling `Timeline#meet` — the prior
note's "zero callers" was true of `lib/` and `exe/` only. Rerouted, green.

**Two surprises.** The registry had a production reader the prior note missed at that base
(`DerivationAudit#purity`, since deleted on `main`), and a latent footgun remains: the shared
group's default `meet: ->(a, b) { a.meet(b) }` now fits only `Ext::Timeline` and
`IntervalPartition`; Ruby Timeline consumers must pass `meet:`.

**Docs that would need rewriting:** `ARCHITECTURE.md` §"The algebra: laws as architecture" whole,
the three-meets passages, the attenuation and purity paragraphs; `docs/GLOSSARY.md` "Algebra and
order theory"; two `ROADMAP.md` lines; `.rubocop.yml` (done in the spike).

### Rust: orders as ZSTs — `.claude/worktrees/agent-a0d26dfa274768340`

`cargo test -p lain` 227 → 238; clippy, doc, fmt clean; stable only. `algebra.rs` 363 lines
(~150 doc); `lib.rs` +43/−28 with `use crate::graph` leaving the FFI module entirely; five
visibility tokens in `dag.rs`/`graph.rs`. The middle state the worktree is in — trait *and* the
eight duplicated law tests — is the worst of both and should not land as-is.

The agent's own verdict, which I share: the trait pays *because* the FFI became generic over it,
and pays more with each further order; if three is forever, it is marginal. The Ruby-visible gain
is the option of `Lain::Ext::Dag::RenderAncestry.meet(store, a, b)` (~15 lines), i.e. the order as
the receiver and the head as an argument — the human's framing, on the Rust side.

---

## 4. Sequencing against the separate Rust plan

The Rust plan is not in this tree; what is known is `simplify-13`'s gap list. Whatever it decides,
the order types only constrain it in one place:

1. **Now, Ruby (one plan, one wave):** B above. Registry gone, `Dag::*` orders, per-subject laws,
   `Elementwise` by hand, `Pure#pure?` gone, `Ext::Timeline` reopen gone. Unblocks Zeitwerk.
2. **Now, Rust (one card):** land `algebra.rs` + the generic FFI, delete the eight duplicated law
   tests and banners, edit the two `ext/lain/CLAUDE.md` paragraphs, expose `Ext::Dag::*`.
3. **With the store flip:** `Lain::Dag::RenderAncestry = Lain::Ext::Dag::RenderAncestry` (and the
   other two), delete the Ruby order implementations. Three constants, not 21 constructor sites.
   `simplify-13`'s G8 ("the seam") is answered by the names rather than by a `Dag::Factory`.

Nothing here touches G1 (polymorphic `Store#put`), G5/G6 (event kinds and readers over FFI), or
the canonical-float question; those are the Rust plan's.

---

## 5. Where the rest of the weight is

The census (subagent, method-and-constant reachability from `exe/lain`; numbers are raw lines).
**Read the first row as the deliverable, not a candidate**: CLAUDE.md is explicit that the bench is
the product and the agent is the vehicle. The question for every other row is whether the *vehicle*
needs it to be studied.

| # | mass | what | evidence |
|---|---|---|---|
| — | 10,619 | `bench/`+`arm/`+`plan/`+`compare/`+`grader/`+`embedder/` | reached only from `lain bench`; **the deliverable** |
| 1 | ~10k lib / 25k spec | **nine ways to park and ask** (`simplify-12`) | panel declined *the form* because it conflated authorization (verdict, fail-closed, on the secret boundary) with enquiry (free text, stalls). The fix is **two** primitives, `Gate` and `Ask`, not one — that answers the objection and keeps nearly all of the deletion. Largest single lever in the tree. |
| 2 | ~6.5k | **epic tier**: `epic/` 4,121 + `cli/epic*` ~2,400 incl. `cli/epic_driver/factory.rb`, a *second* independent agent factory (924) with its own approval system | reached only by `lain epic`; `epic/mermaid`, `graph_fiber`, `intake`, `in_flight` have zero `lib/` consumers. Decide whether the study bench needs an epic product at all. `simplify-08` T9 is already asking. |
| 3 | 5,281 | **five wiring layers**: `cli/wiring.rb` + `wiring/*` + `switchboard` + `chat_launch` + `backend` + `epic_driver/factory` + `up` | one composition root is the shape; `wiring.rb:16-40` is a comment about a previous failed extraction |
| 4 | −748 / −24 files | **Zeitwerk** (`simplify-11`) | unblocked by §2 |
| 5 | ~2,000 / 20 files | `telemetry/` records emitted and never consumed | 20 of 26 files have no cross-subtree reference |
| 6 | ~2,450 / 19 files | `cli/` files with no reference outside `cli/` (`tmux_surface` 284 has no spec either) | list in the census |
| 7 | ~1,700 | `isolation/` back half (`gc`, `self_sync`, `landing_queue`, `working_branch`, two locks with no specs) | 0 refs outside `isolation/` |
| 8 | ~1,100 | `test_layout/` + its middleware + telemetry | serves one branch of `board_build.rb:163-175`; `constant_index.rb` has no lib or spec ref |
| 9 | — | **duplicate mechanisms**: three summarizers (`oracle/*`, `summarizer/*`, `compaction/strategy/summarizing`), two secret mechanisms (`sensitivity/` vs `middleware/{redact,withhold}`), two ledgers, twelve catalogs/registries with no shared abstraction, three config sources (TOML, env defaults, Thor defaults), four journal-replay stacks | each is a "one of these" card |
| 10 | 150k | `spec/` | `simplify-10` says hygiene recovers 8–10%; the rows above carry their specs with them, which is where the other 40% is |

**A pattern worth naming.** Rows 1, 2, 3 and 9 are the same defect at different scales: a
capability built twice for two surfaces (chat and epic; TTY and Neovim; Ruby and Rust) with the
duplication justified at the time by a seam that never got cut. The registry is the smallest
instance of it — one algebra, declared in Ruby, mirrored onto a Rust class, proved in both.

---

## 6. What the human decides

1. **B over A** — accept losing load-time refusal and the sweep's coverage guarantee for the
   deletion and the Zeitwerk unblock. (Recommended: yes.)
2. **Retire the Ruby `Dominance`/`CausalAncestry` implementations** now, leaving Rust as the
   sole implementation until the store flips — or keep both as bench capability. (Lean: retire.)
3. **Land the Rust trait** with the generic FFI and delete the duplicated law tests, editing the
   two `ext/lain/CLAUDE.md` paragraphs. (Recommended: yes, small.)
4. **Re-open `simplify-12` as two primitives**, `Gate` and `Ask`, after `approval/` is split
   (its T1) — the biggest lever, and the one the panel's objection actually points at.
5. **Whether the epic tier is in the study.** Everything in rows 2 and 3 turns on it.

Both spike worktrees are left in place, uncommitted, for reading. Neither should be merged as-is:
both are 340 commits behind and the Rust one is deliberately in a "trait plus duplicates" state.
