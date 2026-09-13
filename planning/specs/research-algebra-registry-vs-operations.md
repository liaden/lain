# Research — does `Algebra::Registry` need to exist, or is it a workaround for operations not being objects?

Read-only research pass, 2026-09-13, against `main` @ `d4a7a1ea`. Nothing in `lib/`, `spec/`,
`ext/` or `planning/` was changed, and `simplify-09-operations-as-objects.md` was not edited.

Commissioned to settle whether `planning/specs/simplify-09-operations-as-objects.md`'s two algebra
cards — **T3** (trim the registry's production surface, drop the `not_a_*` verbs) and **T4** (promote
`Timeline`'s private store-bound inner classes into `Dag::RenderMeet` / `Dag::DominanceMeet` /
`Dag::CausalMeets`) — are pointing in the right direction. The framing offered was the Rust
zero-sized-type analogy: *if an operation were an object, could module inclusion plus `is_a?` carry
the algebraic claim the way a trait impl on a ZST carries it, making the registry unnecessary?*

## Method

Every figure below was re-derived at HEAD. The live registry was enumerated with one
`ruby -Ilib -rlain` load after the seal; everything else is `grep` over `lib/`, `exe/`, `spec/`,
`ext/` and `crates/`. **No `rake pspec` was run** (other agents are in this tree; CLAUDE.md is
explicit that a concurrent red run is not evidence), and no narrow `rspec` was needed — nothing here
turned on a test outcome. `planning/specs/staleness-09.md` was read; where I rely on it I re-verified
independently, and I found two things it did not.

---

## 0. The answer, up front

**The registry is not a workaround for operations not being objects. It is doing five jobs, and
reified operation objects do exactly one of them — and do that one *worse* than the current
arrangement, because `include` is unchecked at load where `Registry#refuse_unanswered` is not.**

The ZST analogy is real but it points somewhere other than where the plan took it. What makes
`impl MeetSemilattice for RenderMeet` strong in Rust is **not** that the operation is a type. It is
that simplify-13's sealed-supertrait design (`planning/specs/simplify-13-rust-port.md:354-360`) makes
*the declaration and the law tests one macro expansion*, so neither can exist without the other. The
Ruby move that corresponds to that already exists in this codebase and is documented as the
exception: `Algebra::Elementwise` generates the operation and files its claim in one verb
(`lib/lain/algebra/elementwise.rb:92-105`), which is why `elementwise.rb:46-58` says
`is_a?(Elementwise)` *is* the classification there. Note what `Elementwise` did **not** do: it still
files a registry declaration at `:104`, because the law sweep still needs a population to enumerate.

And so:

- **T3 is dead in both halves.** Removal 1 cannot pass its own AC (§3). Removal 2 contradicts a
  landed, written ruling in this tree that the negative verbs' *whole job* is to be called by a spec
  (`spec/spec_discipline_spec.rb:964-969`). See §5.
- **T4 should not run as written.** Its "Reachable from" is false, its "gates simplify-13" is false,
  its "swapping for a Rust-backed one is a line in a catalog" is false, and two of its three stated
  benefits shrink to a rename and a law-group change that would bend the Rust differential oracle.
  See §4.
- **T1, T2 and T5 are genuinely independent of all of this** and can proceed on their own staleness
  corrections. See §6.

Headline: **drop 09's algebra half; keep the registry; re-title 09 to the thesis its remaining three
cards actually share.**

---

## 1. What the registry is actually buying

Measured, at HEAD, by loading the sealed registry:

```
total entries: 24   declarations: 18   refutations: 6
by structure (declarations): meet_semilattice 5 · monoid 5 · pure 3 ·
                             commutative_monoid 2 · elementwise 2 · attenuation 1
refutations (all six):
  Lain::Context::PurgeFailedInputs                  #call          !elementwise
  Lain::Compaction::Strategy::Summarizing           #blocks        !elementwise
  Lain::Compaction::Strategy::Summarizing           #blocks        !pure
  Lain::Compaction::Strategy::SummarizeConversation #blocks        !pure
  Lain::Timeline                                    #causal_meets  !meet_semilattice
  Lain::Ext::Timeline                               #causal_meets  !meet_semilattice
```

This confirms `staleness-09.md`'s recount and contradicts 09's Grounding (`:92-93`: *"24 claims …
and 5 refutations"*, with a per-structure breakdown — elementwise 7, monoid 4, pure 4, attenuation 2
— that matches nothing measurable). 09 counted 24 *entries* and called them *claims*.

The eighteen declaration sites in `lib/` are: `lain.rb:149`, `:150`, `:153`; `toolset.rb:115`;
`middleware.rb:73`; `interval_partition.rb:311`; `usage.rb:102`; `timeline.rb:159`, `:185`, `:225`;
`context/dedupe_tool_calls.rb:101`; `context/base.rb:64`;
`compaction/strategy/elide_tool_observations.rb:55`; `strategy/replacement.rb:173`;
`strategy/base.rb:203`; `strategy/identity.rb:32`; `strategy/elide.rb:83`, `:84`. Four further
refutations are filed by the direct route: `context/purge_failed_inputs.rb:103`,
`compaction/strategy/summarizing.rb:247` and `:253`, `compaction/strategy/summarize_conversation.rb:90`.

### The five jobs

| # | job | where | would reified operation objects do it? |
|---|---|---|---|
| J1 | **Load-time well-formedness refusal** | `algebra.rb:232` unknown, `:243` unwrapped identity, `:251` unanswered, `:258` unexplained, `:273` conflict; plus `meet_semilattice.rb:55` unnamed bottom and `attenuation.rb:68` unanswered dual | **No — strictly worse.** `include` checks nothing. |
| J2 | **An enumerable population for the law sweep** | `algebra.rb:149/151/153`; `spec/algebra_laws_spec.rb:221-222` | **No — it is the hard blocker.** See §2. |
| J3 | **Evidence carriage** (identity, bottom, analysis, dual, `implied_by`) | `algebra.rb` `Declaration`; folded into the law run at `spec/algebra_laws_spec.rb:136-138, 160-168` | **Partly, and one case breaks.** |
| J4 | **Per-operation granularity** | `algebra.rb:15-24` | **Yes, for the two-meets-and-a-non-meet case — and only that case.** |
| J5 | **Refutations as positive obligations** | six entries; `spec/algebra_laws_spec.rb:313-350` | **No, and this is the one reification structurally cannot express.** |

Two more jobs that the plan treats as incidental and are not:

| # | job | where | reified? |
|---|---|---|---|
| J6 | **The seal** — "a claim is a load-time move, not a runtime mutation of a global a whole suite reads" | `algebra.rb:198`, called at `lib/lain.rb:166` | **Moot, not solved.** With no collection there is nothing to seal *and* nothing to sweep. |
| J7 | **Carrying a claim about a class defined in Rust** | `lib/lain.rb:141-162` | **No.** `Lain::Ext::Timeline` is a magnus `TypedData` class. It can be reopened and given the verbs; it cannot become a Ruby operation object. |

### J1 in detail — this is the Rust impl-completeness check, in Ruby

`Registry#refuse_unanswered` (`algebra.rb:251-256`) raises `Algebra::Unanswered` if the subject does
not answer the operation, checking private methods too (`algebra.rb:98-100`). That is the load-time
Ruby analogue of "an `impl` must define the trait's methods or it will not compile." `Attenuation`
extends it to the dual (`attenuation.rb:68-73`) and `MeetSemilattice` adds the non-empty-bottom check
(`meet_semilattice.rb:55-61`).

`include Algebra::MeetSemilattice` alone checks **nothing**. Every module says so in its own words —
`monoid.rb:13-15`, `commutative_monoid.rb:23-24`, `meet_semilattice.rb:20-22`, `attenuation.rb:43-45`,
`pure.rb:26-27`: *"`is_a?` is not the classification; the registry is."* Making `is_a?` the
classification therefore **deletes five load-time refusals and replaces them with nothing**. An
operation object that includes `MeetSemilattice` and has a typo'd `#call` would classify as a
semilattice until a law ran. Today the load raises, naming the method.

### J3 in detail — one evidence case reification cannot carry

`identity` could become a method on an operation object; that is exactly what Rust does with an
associated `const`. `analysis` likewise. But:

- **`bottom:` is prose on purpose** and is *designed to be unusable as data*
  (`meet_semilattice.rb:24-35`): there is no one empty Timeline, so a stored bottom would raise
  `CrossStore` against every real operand, and the declaration records a description a reader can
  use and a law group cannot wire in wrongly. A "bottom" method on an operation object would be a
  value, which is the mistake `refuse_unnamed_bottom` exists to refuse.
- **`dual:` is one claim about two operations.** `attenuation.rb:16-25` argues explicitly that
  `only` and `except` must not be two declarations, because `except(x) == only(names - x)` *is* one
  of the laws and a reader who deleted one would leave a coherent-looking half-claim standing. One
  operation object per operation splits exactly that claim in two. **`Toolset`'s attenuation is a
  counter-example to the reification thesis, not covered by it.**

### J4 in detail — is the Timeline really the only case `is_a?` cannot express?

The plan asserts `Timeline` is *the* motivating case. Checked: **`Lain::Timeline` and
`Lain::Ext::Timeline` are the only subjects in the registry with more than one declared operation.**
So on the narrowest reading the plan is right.

But that reading understates how often per-operation granularity is load-bearing, because
`is_a?(Monoid)` tells you a class has *some* monoid and never *which method*:

- `Middleware::Base` includes `Monoid` (`middleware.rb:48`) and declares `>>` (`:73`). `#call` is
  not a monoid operation. `is_a?` cannot say that.
- `Compaction::Strategy::Identity` includes `Pure` (`strategy/identity.rb:23`) and declares
  `:propose_ranges` (`:32`) — not `#call`, not `#blocks`.
- `Compaction::Strategy::Elide#blocks` carries **two** structures on one operation
  (`strategy/elide.rb:83-84`).
- `Toolset#only` carries the attenuation and names `#except` as its dual (`toolset.rb:115`).

So per-operation granularity is needed at essentially every claim site, and reification supplies it
only by making every operation its own class — which is far larger than three Timeline meets and
would split `Toolset`'s duality claim (above). **The plan's premise is narrowly true and broadly
misleading.**

### J5 in detail — the thing reification cannot do at all

Five of the six refutations are filed by classes that **do not include the module** —
`PurgeFailedInputs`, `Summarizing` (twice), `SummarizeConversation`. For those, `is_a?` *already*
answers "no", and answers it uselessly:

- it carries no **reason**, where `refuse_unexplained` (`algebra.rb:258-266`) makes one mandatory;
- it is not **enumerable**, so nothing can walk it;
- it gets no **battery**. `spec/algebra_laws_spec.rb:313-350` holds every refutation to four separate
  obligations: the named law must report `:fails` (`:325`), *no* law may raise (`:331` — "a negative
  confirmed by an error proves nothing"), the reason must be non-empty (`:335`), and a witness must
  **exhibit** the reason rather than merely state it (`:343-348`).

A refutation is a *positive obligation with executable evidence*. Absence of module inclusion is an
absence. **This is the single strongest argument that the registry is not a workaround**: the
codebase's negative claims have equal rank to its positive ones (`ARCHITECTURE.md:947-956`), and the
type system — Ruby's or Rust's — has no vocabulary for "this deliberately is not that, here is why,
and here is the witness."

Rust does not escape this either. simplify-13 concedes it: `declare_not_meet_semilattice!(CausalMeets,
because:, witness:)` still earns its place, *"emitting one test that the witness yields more than one
maximal lower bound — the 'EXHIBIT what the reason says' obligation `spec/algebra_laws_spec.rb`
imposes"* (`simplify-13:371-373`, `:503-506`). The refutation macro is a registry entry that happens
to expand into a test.

---

## 2. The ZST analogy, taken seriously

### What a Rust trait impl on a ZST actually guarantees

1. **Signature completeness, at compile time.** `impl MeetSemilattice for RenderMeet` will not
   compile unless `meet`, `below`, `Elem`, `Ctx` and `BOTTOM` are all supplied.
2. **Non-existence of the impl is a compile error at the use site**, so generic code can *require*
   the bound.
3. It guarantees **nothing about the laws**. Rust checks shapes, not algebra. simplify-13 knows
   this, which is why its trait carries `#[cfg(test)] mod` proptests emitted by the same macro
   (`simplify-13:362-366`).

### What simplify-13 adds on top, and why it is the interesting part

```rust
mod sealed { pub trait Proven {} }
pub trait MeetSemilattice: sealed::Proven {
    type Elem; type Ctx;
    fn meet(ctx: &Self::Ctx, a: &Self::Elem, b: &Self::Elem) -> Self::Elem;
    fn below(ctx: &Self::Ctx, m: &Self::Elem, a: &Self::Elem) -> bool;
    const BOTTOM: &'static str;
}
```
(`simplify-13:354-360`)

The private supertrait means only `declare_meet_semilattice!` can produce a conforming impl, and that
macro emits the `Proven` impl, a `const _: () = assert!(!BOTTOM.is_empty())` (the compile-time
analogue of `refuse_unnamed_bottom`) and four `proptest!` blocks **in one token stream**
(`:362-366`). The plan's own summary: *"Ruby catches declaration-without-laws at spec time; this
catches it at compile time, and closes the inverse leak too, because the two are the same
expansion."*

**That is the load-bearing mechanism, and it is not the ZST.** The strength comes from *declaration
and proof being one indivisible artifact*. The type is the hook; the macro is the guarantee.

### Three places the analogy breaks in Ruby

**(a) `include` is not `impl`.** Ruby has no signature check on inclusion. The current registry
*restores* that check with `refuse_unanswered`. Reification without a registry loses it.

**(b) Rust has no runtime impl enumeration either — so the law sweep has no population.** This is
decisive. `spec/algebra_laws_spec.rb:6-11` names its own options and rejects two of them by name:

> *"a marker nothing reads is decoration, and a marker read by a hand-maintained list in a spec is
> decoration with extra steps. So this file walks `Lain::Algebra.registry` itself and names no class
> and no operation of its own"*

and `algebra.rb:141-143`: *"populated at load time by the declarations in `lib/`, so a spec can walk
it directly — **no ObjectSpace sweep, no constant walk**."*

Remove the registry and the sweep must find the operation objects by one of: an `ObjectSpace` or
constant walk (rejected, and fragile under autoload); a hand-kept list in the spec (rejected, and
the exact drift the registry exists to prevent); or a `Module.included` hook that accumulates
includers into a collection — **which is the registry, minus the evidence fields, minus the five
load-time refusals, and minus the reasons.** Rust in the same position reaches for `inventory` or
`linkme`, i.e. a link-time registry; simplify-13 avoids needing one only because the macro can emit
the tests *at the declaration site*, which Ruby's `include` cannot.

**So: the law sweep's population requirement alone forces a registry to exist.** Reification changes
what is filed, never whether something is filed.

**(c) The Rust design does not bind the store, and 09/T4 does.** `fn meet(ctx: &Self::Ctx, a, b)`
takes the context **as a parameter**; `Ctx` is an associated *type* (which store type), not a bound
instance. The Rust `RenderMeet` would be a genuine ZST — no fields. 09/T4 proposes
`RenderMeet.new(store)`, a *store-bound instance*, which is a partial application of the Rust shape
and not the same design.

This matters twice over:

- The Rust signature has **exactly the same cross-store hazard** — two `Graph` values of one type are
  still confusable — so "the Rust trait design converges on binding the store" is not true. 09's
  *"Three independent lines converge on binding the store"* (`:120-124`) is **two** lines: the private
  inner classes, and the architectural argument. The Rust line converges on *reifying the operation*,
  which is a different claim.
- The faithful Ruby analogue of the ZST is a **frozen, stateless singleton** answering
  `call(store, head_a, head_b)` — not an object carrying a store. If the reification direction is
  ever taken, that is the shape to take, and it is *less* disruptive than T4's.

### Is the guarantee stronger, weaker, or differently shaped?

**Differently shaped, and net weaker in Ruby.** An operation object plus module inclusion gives:
a name that can appear in a catalog (real, and the genuine win); `is_a?` as a cheap classifier
(equivalent in strength to a registry lookup, both runtime); and nothing else. It gives up five
load-time refusals, the enumerable population, prose bottoms, the attenuation duality, and every
refutation.

---

## 3. Is `Algebra::Pure#pure?` a legitimate reader or an accident?

**Verified facts.**

- `pure.rb:58-60` is the sole production reader of `Registry#declares?`:
  `registry.declares?(subject: self.class, operation:, structure: :pure) && Ractor.shareable?(self)`.
- `#pure?` itself has **zero callers in `lib/` or `exe/`**. Its only callers are 12 spec sites across
  5 files: `spec/lain/algebra_spec.rb` (×7, at `:912`, `:913`, `:927`, `:942`, `:959`, `:979`, `:990`),
  `spec/lain/compaction/strategy_spec.rb:259` and `:261`,
  `spec/lain/compaction/strategy/elide_spec.rb:128`,
  `spec/lain/compaction/strategy/elide_tool_observations_spec.rb:178`, plus a naming assertion at
  `summarizing_spec.rb:229`.
- `git show d2bb133c:lib/lain/algebra/pure.rb` carries the identical lines. This is **not drift**:
  09's Grounding (`:80-85`) was wrong when written.
- The same error is in a **landed commit message**. `fdd4f750` ("delete `Compaction::DerivationAudit`")
  says *"Takes the only non-declaring reader of `Algebra.registry` in `lib/` with it, so the registry
  is now filed at load and queried only by `algebra_laws_spec`."* That sentence is false, and it is
  now in git history. Two independent artifacts carry the same mistake, which is why AC 1 read as
  achievable to two readers.

**Legitimate or accident?** Neither, exactly: it is a **legitimate design that lost its consumer**.

The design is argued, and argued well, at `pure.rb:17-24`: purity classifies an *operation*, so the
predicate must too, because a class may hold a pure `#call` and an impure `#reload` and an
object-level predicate could only ever give one answer for both. That is sound.

But the argument is **prospective, not observed**. No class in the tree today has two operations
differing in purity: `Strategy::Identity` declares `pure on: :propose_ranges` and nothing else;
`Elide` and `ElideToolObservations` each declare `pure on: :blocks` only. The realised case is
`Strategy::Elide#blocks` carrying `:elementwise` *and* `:pure` — one operation, two structures —
which module inclusion handles fine.

**Could the decision be made structurally?** Half of it already is, and it is the load-bearing half:
`Ractor.shareable?(self)` is what `CLAUDE.md` calls the mechanical statement of "no reachable mutable
state," and `pure.rb:29-42` explains that this is the half that catches the failure that actually
happens — a mutable collaborator quietly injected. `spec/lain/compaction/strategy_spec.rb:255-269`
("the two algebraic axes … answers them independently") pins the deliberate contrast: elementwise-ness
is read off the module, purity off the registry. So the codebase has *already* decided, in a spec,
that these two classification mechanisms coexist on purpose.

**Verdict for the plan:** `pure?` is the orphan of `fdd4f750`, not a hole in T3's reasoning to be
patched over. Deleting it is a defensible, separate card that must name its 12 spec sites and say
what replaces the recorded intent (`pure on: :blocks` declarations would then be swept-only). It is
not something T3 may do as a side effect of "trimming the registry," and T3's Files list, Intent and
escalation triggers name none of it.

---

## 4. Does T4 stand on its own?

### Four of its load-bearing claims are false at HEAD

**(a) "Reachable from" is false.** `Timeline#meet`, `#causal_meets`, `#dominator_meet` and
`#diverge_at` have **zero callers in `lib/` or `exe/`**. The only non-`timeline.rb` occurrences are
three comments (`request.rb:96`, `grader/frustration_repair.rb:34`, `bench/rewrites.rb:6`), two
comment lines in `algebra/meet_semilattice.rb`, and the two declaration lines at `lib/lain.rb:150`
and `:153`. The card's *"`Ledger#unique_turns` … and seven other `lib/` sites walk a timeline;
`Timeline#meet` is reached from the compaction and fork paths"* describes `#ancestors` call sites,
which the card's own escalation trigger forbids it from touching.

**(b) "This card gates simplify-13" is false.** simplify-13's Orchestrator contract (`:222-225`)
lists 03/T7 and 02/T4 + T5 as *"must have landed"* and 09/T4 as *"**should** have landed"*, and the
benefit named is **G8 only** — the 21-site `Timeline.new` / `Store.new` seam. G8 is consumed by 13's
**T12** (`Dag::Factory`, wave 9 of 11), and 13's own Open decisions (`:235-237`) say the plan may stop
after T4: *"T1-T4 and T8 still stand on their own … and T5-T14 do not have to follow."* 13's critical
path begins `T1 → T2 → T4`, all three of which write only `ext/lain/src/*.rs` and touch no Ruby
`Timeline`. 09 also cites a *"42-site factory"*; 13 measures **21 live `Timeline.new` sites across 19
files** (`:166-167`).

The one true dependency runs the other way and is trivial: 13's T12 says *"modify `lib/lain/dag.rb`
(the subtree index simplify-09's T4 creates)"* (`:903-904`). A subtree index is one file; 13's T12 can
create it.

**(c) "Swapping `Dag::RenderMeet` for a Rust-backed one is a line in a catalog" is false.** The
Rust-backed meet is `Lain::Ext::Timeline#meet` over **`Lain::Ext::Store`**
(`spec/lain/rust/timeline_spec.rb:10`, `:93`, `:232`). A Ruby `RenderMeet.new(store)` bound to a Ruby
`Lain::Store` cannot be handed an `Ext::Store`-backed head. The swappable seam is the **store
constructor** — which is precisely what 13's T12 `Dag::Factory` exists to build. T4 does not remove
that work; it renames part of the surface around it.

**(d) The three benefits shrink.**

- *"`CrossStore` becomes unrepresentable"* — the card itself already retracts this at `:504-521`
  ("a rename, not a deletion"). Verified: **8** by-name assertions (`spec/lain/timeline_spec.rb:185`,
  `:299`, `:350`; `spec/lain/rust/timeline_spec.rb:233`; `spec/lain/rust/store_spec.rb:120`;
  `spec/lain/rust/causal_meets_spec.rb:169`; `spec/lain/rust/dominator_meet_spec.rb:135`, `:176` —
  the card names seven and misses `rust/timeline_spec.rb:233`), **zero rescues anywhere**, and two
  further prose sites **inside `lib/`**: `lib/lain/algebra/meet_semilattice.rb:29` and `:54`. The Rust
  side keeps raising its own `Lain::Ext::Timeline::CrossStore` (`ext/lain/src/lib.rs:1762`, defined
  `:1967`) regardless.
- *"The bottom becomes a value, `nil`"* — only if the operation returns a **head digest** instead of a
  Timeline. `Timeline#meet` returns `checkout(common&.digest)`, a Timeline; the shared law group
  compares Timelines via `ancestor_of?`. Changing the return type changes
  `spec/support/shared_examples/meet_semilattice.rb`, and `spec/algebra_laws_spec.rb:22-28` warns in
  terms: those groups *are* the Rust differential oracle, *"so bending one to suit this sweep would
  silently bend that."* This is a real, unbudgeted cost the card does not price.
- *"`is_a?` becomes the classification … three of the registry's five `meet_semilattice` claims"* —
  the five are `Timeline`×2, `Ext::Timeline`×2, `IntervalPartition`×1. T4 converts the **two** Ruby
  Timeline ones. `Ext::Timeline`'s two stay on an element with `on:` keywords at `lib/lain.rb:141-162`
  — *"exactly the shape T4 argues is unnecessary"* — and the block's own *"must not drift from
  them"* comment loses its referent. T4 would break a mirroring invariant simplify-02's T5
  deliberately created, and the card is silent on the block's existence.

### The thesis is not applied to the one meet production actually calls

`IntervalPartition#meet` (`interval_partition.rb:248`, declared `:311`) is reached in production at
`lib/lain/compaction/strategy/composed.rb:124` — `.inject(:meet).validated`. It is the **only meet in
the codebase with a live caller**, it sits on a value that is equally "an element rather than the
lattice," and T4 does not touch it. A structural thesis applied to three dead operations and not to
the live one is a refactor looking for a subject.

### So what does the zero-caller finding argue?

Not deletion. Three reasons, and one of them is a written ruling in this tree:

1. **This codebase has already ruled on exactly this shape.** `spec/spec_discipline_spec.rb:953-957`
   heads its lib-reach report *"THIS IS A READING LIST, NOT A DELETE LIST"* and `:970-975` names
   *"documented algebra predicates — `Timeline#ancestor_of?`, `Timeline::Dominators#dominates?` are
   the DAG's public vocabulary"* as one of three families where narrowing is *"a defect, not a
   cleanup."* The three meets are the same family.
2. **They have real consumers, just not in `lib/`.** The law sweep, five `spec/lain/rust/*` files, and
   `spec/support/shared_examples/meet_semilattice.rb` as the Rust differential oracle. On a study
   bench, *verified capability that no production path has yet taken up* is a legitimate artifact —
   it is what the bench is for.
3. **`#dominator_meet` in particular is a designed-for capability with an unbuilt consumer.**
   `ARCHITECTURE.md:189-206` calls it "the checkpoint primitive … the latest point no in-flight
   branch can bypass, which is what makes it the synchronization/safe-compaction answer." Nothing
   calls it. **The honest finding is not "promote it to an operation object"; it is "the
   safe-compaction checkpoint is specified, implemented twice, property-tested, and unwired."** That
   is a ROADMAP item, and it is a better use of the discovery than a refactor.

**Verdict on T4: do not run it. Record the zero-caller finding and the unwired checkpoint as
findings.** If the store-bound-operation idea is still wanted afterwards, the place to decide its
shape is simplify-13's T2 panel review, when the Rust trait signature is settled — and by that
signature the Ruby analogue is a **stateless** singleton taking the store as a parameter, not
`RenderMeet.new(store)`.

---

## 5. A recommended rewrite of 09's algebra half

### Why T3 is dead in both halves

**Removal 1 (the production query surface) cannot pass its own AC.** AC 1 asserts *"the registry has
no production reader … none is found."* `Algebra::Pure#pure?` is one (§3), it is public, it is
exercised by 12 spec sites, and it appears nowhere in T3's Files, Intent or triggers. Achieving AC 1
requires a second, unscoped deletion.

Two further problems the card does not see:

- `refutations` **cannot be removed**: `spec/algebra_laws_spec.rb:261`, `:271` and `:313` read it,
  and it is a one-line `grep(Refutation)` (`algebra.rb:153`). Deleting it saves one line and pushes
  `grep(Lain::Algebra::Refutation)` into the sweep — complexity moved, not removed.
- `about` is read by `spec/lain/timeline_spec.rb:528` and `spec/lain/usage_spec.rb:167`, both of
  which pin that a class's claims are what `lib/` says they are.

**Removal 2 (drop the `not_a_*` verbs) contradicts a landed ruling.** `spec/spec_discipline_spec.rb:964-969`,
in the lib-reach report's own banner:

> *"THREE FAMILIES BELOW ARE LEGITIMATE AND DOMINATE THE LIST. Narrowing any of them is a defect,
> not a cleanup: **property-test law counterexamples — `Algebra::Monoid#not_a_monoid`,
> `Algebra::Pure#not_pure` and their siblings exist to be called by a spec; that is their whole
> job.**"*

Counted at HEAD: `not_a_monoid` 7 spec sites, `not_a_meet_semilattice` 5 spec + 2 lib,
`not_pure` 3 spec, `not_a_commutative_monoid` 2 spec, `not_an_attenuation` 2 spec,
`not_elementwise` 1 spec. **Twenty spec call sites**, which is exactly the job the banner describes.
T3's "twelve verbs support five entries" counts only `lib/` and reads a deliberately spec-facing
vocabulary as dead code. The verbs are also what the corresponding batteries in
`spec/lain/algebra_spec.rb` exercise to prove each refusal fires.

And the card's *"Shared-file wiring: none"* is false: dropping `not_a_meet_semilattice` forces an
edit to `lib/lain.rb:153`, an orchestrator-owned shared file.

### Four directions

**Direction A — Drop 09's algebra half entirely.** T3 and T4 leave the plan. 09 becomes a
three-card plan (T1, T2, T5) about handler/adverb separation and naming the context pipeline, which
is what its title's *"verbs terminate, adverbs decorate, and an operation gets a name"* actually
describes; the algebra cards were the part of that title that never fit.
*Cost:* none of the registry's minor smells get addressed — but on inspection there are almost none:
18 declarations, 6 refutations, 315 lines in `algebra.rb`, one 63-line module per structure, and
every surface has a reader. *Benefit:* every remaining card is grounded and executable, and the plan
stops carrying a thesis its evidence does not support.

**Direction B — A narrow, honest T3′ that only fixes what is actually wrong.** Keep `declares?`,
`refutations`, `about`, the verbs, the seal. Fix the *documentation* debt instead: `algebra.rb:15-24`
and `meet_semilattice.rb:12-22` both name `Timeline` as the motivating case in prose that has since
grown a Rust mirror (`lib/lain.rb:141-162`) those comments do not mention, and `elementwise.rb:107-112`'s
message sanctioning the direct `.refute` route is now taken by **four** sites, not three. This is
~20 lines of comment repair, zero risk, no shared-file edit, and it leaves the reader with an
accurate map. *Cost:* it is not a simplification and should not be sold as one.

**Direction C — Reify AND keep the registry (the synthesis), deferred.** Operation objects *and*
declarations, the way `Elementwise` already does it: the verb owns the operation and files the claim
in one move (`elementwise.rb:92-105`), so `is_a?` classifies *and* the sweep has a population. This is
the only direction the ZST analogy genuinely supports, and it is a larger chunk than 09 —
`Toolset`'s duality and the prose bottoms both need answers first. The right moment to decide is
**after simplify-13's T2 panel**, when the Rust trait signature is settled and the Ruby analogue can
be derived from it rather than guessed at. Note the shape that falls out is a **stateless** operation
singleton taking the store as a parameter, not `RenderMeet.new(store)`.

**Direction D — Run T3 and T4 as written.** Rejected. T3's AC 1 cannot pass; T3's Removal 2
contradicts `spec_discipline_spec.rb:964-969`; T4's Reachable-from, its gating claim and its catalog
claim are all false, and it would break the `Ext::Timeline` mirror invariant simplify-02 just built.

### Recommendation

**A, plus B as a small separate commit.** Drop T3 and T4 from 09. Re-title 09 to its remaining
thesis. File four findings for the ROADMAP / a later chunk rather than acting on them here:

1. `Algebra::Pure#pure?` has no production caller and is the orphan of `fdd4f750`; `fdd4f750`'s
   commit message is factually wrong about being "the only non-declaring reader." Decide in its own
   card whether `pure?` goes or gets a consumer.
2. `Timeline#meet`, `#causal_meets`, `#dominator_meet`, `#diverge_at` have no production caller.
   `#dominator_meet` in particular is `ARCHITECTURE.md:189-206`'s specified safe-compaction
   checkpoint primitive, implemented in Ruby *and* Rust, property-tested, and **unwired**. That is a
   feature gap, not a refactor target.
3. `IntervalPartition#meet` (`composed.rb:124`) is the only meet with a live production caller, and
   no plan in the series touches it.
4. The `Lain::Ext::Timeline` mirror (`lib/lain.rb:141-162`) is now the registry's most load-bearing
   job: it is the **only** mechanism by which a Rust-defined class carries a Ruby algebra claim, and
   `spec/algebra_laws_spec.rb:26-28` says in terms that *"a Rust-backed Timeline cannot carry a Ruby
   concern and must not have to."* The mirror does make it carry one (`lib/lain.rb:147`), for the
   verbs rather than for classification. That tension is worth a sentence in `ARCHITECTURE.md` and is
   directly relevant to simplify-13's T3 doc edits.

---

## 6. What this means for 09's other three cards

All three are **independent of the algebra question**. None touches `lib/lain/algebra/**`,
`spec/algebra_laws_spec.rb`, `spec/support/algebra_generators.rb`, `lib/lain/timeline.rb` or the
`Ext::Timeline` block. Verified by their declared Files lists and by the fact that no card among them
adds, removes or moves a declaration.

| card | independent of the algebra research? | safe to execute unchanged? |
|---|---|---|
| **T1 — split `Effect::Handler`** | **Yes.** `lib/lain/effect/**` files no algebra claim; moving four classes into `Middleware` inherits `Middleware::Base`'s monoid and files nothing new (the `Composed` precedent at `middleware.rb:70` means `registry.about(Composed)` answers `[]`). | **No — for staleness reasons only.** Its arithmetic (six handlers vs. seven classes), three line cites, and the `Summarizing` dead-decorator/live-Observer split all need `staleness-09.md`'s corrections first. Nothing here changes its premise. |
| **T2 — one handler-chain wiring** | **Yes.** No algebra surface anywhere on the spawn path. | **No — for staleness reasons only.** `CLI::Wiring::AgentBuild` does not exist, so AC 3 requires *writing* the builder against `lib/lain/cli/wiring.rb:485-488`, the parent's live chat path. Re-rate or re-scope per `staleness-09.md`. |
| **T5 — name the context pipeline** | **Yes**, with one note. `Context.pipeline` composes through `Context::Combinator#>>`, whose monoid claim is on `Base` (`context/base.rb:64`) and is unaffected by naming a composition — declaring a monoid on a *composite* is exactly what `middleware.rb:70`'s precedent says not to do. | **No — for staleness reasons only.** Construction counts, `Recall` (1 site, not 2), the `CompactionStrategy` precedent's line numbers and `SessionRecord.header`'s key set all drifted. |

**But the plan's one-thesis framing does need re-scoping.** 09's Intent claims all four cards "apply
that one idea in four places." With T3 and T4 removed, the remaining three share a narrower and
truer thesis: *an operation that has no name can be neither selected nor recorded.* T1 and T2 give
the handler chain one inspectable, ordered shape; T5 gives the context pipeline a name, a resolver
and a journal field. That is a coherent plan and it is the half of 09 that is grounded. Re-title, and
move the registry material to a research note (this one) rather than carrying a dropped thesis in
the Intent.

---

## 7. What is under-determined, and what would settle it

Two things genuinely are not settled by evidence available today.

**(a) Whether operation objects are the right long-term shape for the DAG at all.** The evidence says
they are not *needed* to replace the registry and are not *needed* by simplify-13. Whether they are
independently better Ruby is a design judgement. **What would settle it:** simplify-13's T2 landing.
Once the sealed trait exists with a concrete `fn meet(ctx: &Self::Ctx, a, b)` signature and the macro
that proves it, the Ruby analogue can be *derived* from a shipped design rather than anticipated —
and it will be a stateless singleton, not a store-bound instance.

**(b) Whether `pure?` should exist.** Its design argument is sound and prospective; its consumer is
gone. **What would settle it:** deciding whether anything will re-derive a compacted span from a
journalled edge alone. That was `DerivationAudit`'s job and `DerivationAudit` was deleted for having
no callers. If nothing will, `pure?` and the three `pure on:` declarations are sweep-only — still
legitimate under the bench mandate (a claim held to its laws is evidence), but the predicate is not.

Everything else in this document is determined, and where it contradicts
`simplify-09-operations-as-objects.md` the contradiction is shown with a file and a line.

---

## 8. The ruling this document produced

**2026-09-13, by the human:** simplify-09 is **dropped entirely** — not card by card, and including
T1, T2 and T5, which this document found independently sound. The standing direction is to
**consider moving away from the `Registry` in general, as a future rearchitecture**, rather than to
trim it in place.

That ambition and this document's §1 are not in conflict, but they are in tension, and the tension is
the useful part. §1 concludes the registry **earns its place today**: it is not scaffolding around
missing objects, it is Ruby's stand-in for a compile-time impl-completeness check. So a rearchitecture
that removes it does not get to treat it as dead weight — it has to answer, concretely:

1. **Who refuses an incomplete implementation, and when?** Five load-time refusals do it now
   (`algebra.rb:232`, `:243`, `:251`, `:258`, `:273`, `meet_semilattice.rb:55`, `attenuation.rb:68`).
   `include` checks nothing. Whatever replaces the registry has to refuse at least as loudly, and
   preferably as early — CLAUDE.md's standing preference for loud failure is what rejected
   `StringInquirer`, and it applies here with more force.
2. **How does the law sweep find its population?** `spec/algebra_laws_spec.rb:9-10` has already
   rejected `ObjectSpace`. A hand-maintained list is a manifest by another name. An `included` hook is
   a registry by another name. This is the load-bearing question, not the API surface.
3. **What happens to the evidence?** `identity:`, `bottom:`, `analysis:` and `dual:` are carried per
   declaration. Prose bottoms ("the empty Timeline, per store") and `Toolset`'s `dual:` — one claim
   about two operations (`attenuation.rb:16-25`) — actively resist reification into one object per
   operation.
4. **What holds `Lain::Ext::Timeline` to the Ruby claims?** `lib/lain.rb:141-162` mirrors all three
   Timeline declarations onto the Rust extension under a "must not drift" comment. The differential
   law groups are the only thing enforcing parity, and they read the registry.

**The better-founded lead is not reification, it is derivation.** §2 found that Rust's advantage is
not the zero-sized type but simplify-13's sealed supertrait, where the declaration and the proptests
that prove it are **one macro expansion**. Ruby already has one instance of that shape —
`Algebra::Elementwise` — and it still files a registry declaration (`elementwise.rb:104`). A
rearchitecture that made declaration and law-checking a single act, rather than two things kept in
sync by a sweep, would deliver what the ZST analogy was reaching for. **What would settle the design:
simplify-13's T2 landing**, per §7(a) — the Ruby analogue is then derived from a shipped trait rather
than anticipated ahead of one.
