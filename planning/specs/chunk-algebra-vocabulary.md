# The algebra vocabulary, and the properties lain already maintains

status: done
commit-mode: orchestrator-commits
language: ruby (A5 is rust)
panel: Ruby roster for A1–A4 — Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman ·
Aaron Patterson. **A5 is a Rust card and takes the Rust roster** — Raph Levien · Andrew Gallant ·
Frank McSherry · Ashley Williams. Both from `create-plan/references/rosters.md`.

## Intent

Lain already maintains real algebraic structure — a monoid on `Context::Combinator`, a commutative
monoid on `Usage`, a meet-semilattice on two of `Timeline`'s three meet-ish operations — and each is
evidenced *only* by how some method happens to behave plus an `include_examples` call in a spec file.
Nothing in `lib/` says so. A reader of `usage.rb` has to notice the shape and go hunting for the
proof, and a reader of `timeline.rb` cannot tell that `#causal_meets` is deliberately **not** a
semilattice.

This chunk gives those properties a concrete home. **A1** names them as modules in `lib/`, following
`Lain::ContentAddressed` — the existing precedent for a property module that is `include`d, stateless,
documented in its own right, and separately spec'd. **A3** declares them where the structures live.
**A2** makes the declarations load-bearing by refusing any claim that has no means of proof, so a
declaration is an obligation rather than a comment. **A4** applies the vocabulary to existing code:
`DedupeToolCalls` and `PurgeFailedInputs` both already analyze-then-map, and naming that factoring
makes their analysis inspectable and their output traceable to its input. **A5** does the Rust half —
`ext/lain/src/dag.rs` claims a meet-semilattice in a module doc and tests half its laws.

Two things this chunk deliberately does **not** do. It defines no structure without a named consumer
(no group, ring, functor, or category), and it declares only the three structures whose law groups
already run — `Regular`, `Store`'s idempotent `put`, and `Canonical`'s determinism are real and are
follow-ups, because each needs a generator under A2's contract. It also adds **no algebra traits to
Rust**: A5 records why in `ext/lain/CLAUDE.md`.

**Downstream consumer.** `planning/specs/chunk-derived-context-timeline.md` requires this chunk's
`Algebra::Elementwise` and `Algebra::Pure` (its T3). Land this one first.

## Grounding

Verified **2026-07-27** against `main` at `5665f14`, by exploration passes plus direct measurement.
Code is source of truth; where a doc disagreed, the code won and the disagreement is recorded.

### G1 — What lain maintains, and where the only evidence lives

| Structure | Operation | Identity / bottom | Evidence today |
|---|---|---|---|
| Monoid | `Context::Combinator#>>` | `Context::Identity` (`context/base.rb:64`) | `spec/lain/context/base_spec.rb:26-33` calls `include_examples "a monoid"` |
| Commutative monoid | `Usage#+` (`usage.rb:33`) | `Usage::ZERO` (`usage.rb:70`) | a law-group call in `usage_spec.rb` |
| Meet-semilattice | `Timeline#meet`, `#dominator_meet` | the empty Timeline | `spec/lain/timeline_spec.rb:204`, `:469` |
| **Not** a semilattice | `Timeline#causal_meets` | — | prose only, in `timeline.rb:143-152` |

In every row the *only* machine-checked statement lives in `spec/`. Nothing in `lib/` declares any of
it. The last row is the sharpest case: a criss-cross fan-in leaves incomparable maximal common
ancestors, so there is no unique greatest lower bound — a fact recorded in a comment and nowhere else.

`spec/support/shared_examples/` holds the law groups this chunk reuses **unchanged**: `monoid.rb`
(parameterized on `operation:`/`identity:`/`generator:`/`equal:`, with `:24-41` explaining why those
are built at the call site), `meet_semilattice.rb` (four laws — idempotent `:39`, commutative `:45`,
associative `:52`, meet-below-both `:61`), `regular.rb`, `store_laws.rb`, `canonical_laws.rb`,
`memory_index_laws.rb`, `provider_parity.rb`. `docs/GLOSSARY.md:315-325` calls these "the acceptance
test for any Rust port".

### G2 — `Lain::ContentAddressed` is the precedent to copy

`lib/lain/content_addressed.rb` is already what A1 generalizes: a module in `lib/` naming a property,
`include`d by the values that have it, **stateless by design** so that including it "cannot disturb an
includer's deep freeze or its Ractor shareability" (`:10-12`, pinned by
`spec/lain/content_addressed_spec.rb:57`), carrying its reasoning and its two deliberate refusals in
its own doc comment. It loads at `lain.rb:14`, beside `Freezable` at `:16` — so lain already has a
small vocabulary of property modules and a place to put another.

### G3 — The two-phase combinators already have the shape A4 names

`dedupe_tool_calls.rb:24-27` is `stale_ids = stale_tool_use_ids(messages)` then
`messages.filter_map { without_stale(_1, stale_ids) }`. `purge_failed_inputs.rb:43-50` is
`failed_ids = failed_tool_use_ids(messages)` then a per-message purge. Both analyze the whole list,
then act per message — so neither is *unconditionally* elementwise, which is why their composition
order matters, and both already have everything needed to report what they dropped and why. Neither
does. Both are **unwired in production** (no production caller for `Prune`, `DedupeToolCalls`, or
`PurgeFailedInputs`), so A4 is a refactor with no live blast radius.

`DedupeToolCalls#without_stale` **drops the whole message** when its content empties
(`dedupe_tool_calls.rb:64`), so the per-message map is `M -> [M]`, not `M -> M`. A1's vocabulary owes
that shape.

### G4 — The Rust side claims more than it tests

`ext/lain/src/dag.rs:9` claims "the whole **meet-semilattice** can be unit-tested without an embedded
Ruby VM." Of its 12 tests, `meet_is_commutative` covers commutativity and
`meet_is_the_greatest_common_ancestor` plus `empty_is_below_everything` between them cover
meet-below-both. **Idempotence and associativity are absent** — 2 of the 4 laws the Ruby group
defines. No Rust test asserts `Store::put` idempotence either; only the Ruby parity spec does
(`spec/lain/rust/store_spec.rb:27`). The crate root carries only
`#![deny(clippy::print_stdout, clippy::print_stderr)]` — `missing_docs` is not enforced.

`ext/lain` defines **zero traits of its own** (only std impls plus `Tokenizer` from the bm25 crate),
and `dag.rs:96` has `meet` as a free function. `Ext::Timeline` has `meet` and `diverge_at` but **no
`dominator_meet` and no `causal_meets`**, so A3's two most interesting declarations have no Rust
counterpart. `Ext::{Turn,Store,Timeline}` are referenced only from `spec/lain/rust/*`; nothing in
`lib/` touches them, and `Ext.blake3_hex` is the crate's only production dependency
(`canonical.rb:60`).

**Correction to a house claim:** `ext/lain` is **not** under the `#![forbid(unsafe_code)]` rule.
`crates/lain-core/src/main.rs:13` carries it; `ext/lain/src/lib.rs` does not, and holds ~7 `unsafe`
blocks, all FFI-boundary calls in magnus's own unsafe API (`value.classname()`, `bytes.as_slice()`,
key access) plus `libc::dup` + `File::from_raw_fd` for the journal fd the Rust tracing layer shares.
None is removable. A5 must not "fix" this.

### G5 — Naming drift in the living docs

`Lain::Turn` was **deleted** (`61f7e81`); the unit is `Lain::Event`, kind-tagged `:turn`, with
`KINDS = %i[turn spawn message snapshot]` (`event.rb:27`), and `spec/lain/event_spec.rb:16` asserts no
`Lain::Turn` constant remains. **CLAUDE.md and `~/.claude/plans/jiggly-greeting-avalanche.md` still
say `Turn`.** Not this chunk's to fix — the downstream chunk's docs card owns it — but an implementer
reading either doc for orientation should know.

### F8 — The algebra the seam already has, and how to make it structural

Not decoration: each reading below either becomes a law the suite checks or explains a rule the
plan already asserts flatly.

**`#collapse` maps into the free monoid on messages, and `DROP` is its unit.** The derived chain is
the ordered concatenation of per-range images; emitting nothing is `ε`. `docs/GLOSSARY.md:24-32`
already carries a *Free monoid* entry, currently about combinator sequences — this is a second
instance of the same structure, one level down.

**A strategy is a monoid homomorphism iff it is elementwise.** By the universal property of the
free monoid, a homomorphism out of it is determined by an arbitrary function on generators. So
`collapse(A ++ B) == collapse(A) ++ collapse(B)` holds exactly when `collapse` is a per-message map.
That is not a coincidence to test around — it is a base class:

| | elementwise (elide) | not (summarize) |
|---|---|---|
| Where the boundary falls | irrelevant | load-bearing |
| Reproducibility | free, byte-identical | must be remembered, not recomputed |
| Needs a content-address key | no | yes — hence `Oracle::Recorded` |
| Safe under hierarchical composition | yes | drifts |

**Purity is a second, genuinely orthogonal axis.** Define it precisely: a strategy is *pure* when
`#collapse` is a total function of the span alone — no oracle, no session, no injected state. It is
independent of elementwise-ness, and the 2x2 is fully populated, with two cells already present in
the codebase in another form:

| | pure | not pure |
|---|---|---|
| **elementwise** | `Strategy::Elide` (T7) | per-message model summarization — the shape `Oracle::Eager` already has, keyed per tool result |
| **not elementwise** | whole-span deterministic shapes: keep-first-and-last, a message tally | the model span summarizer (T6); the plan-step collapse (follow-up 2), which reads plan state |

The two axes are not redundant, because they **gate different guards**: `Elementwise` gates
**recursion safety** (follow-up 1 refuses anything else), while `Pure` gates **whether the journalled
edge alone suffices to re-derive** — a pure strategy needs no oracle replay, a non-pure one is
re-derivable only because `Oracle::Recorded` replays its answers. The same audit failure therefore
has two different diagnoses depending on the cell, which is T8's business.

Ruby cannot enforce purity, but it has a **mechanical proxy this repo already spec's**: a pure
strategy holds no collaborators, so it constructs with no arguments and is `Ractor.shareable?`; one
holding a live oracle is not. `CLAUDE.md` calls shareability "the mechanical statement of 'no
reachable mutable state'", and `spec/support/matchers/be_ractor_shareable.rb` is the matcher.

Every "why" in the right-hand column is a decision the plan reaches empirically elsewhere. The
mandated recorded oracle (T6) is the price of not being a homomorphism; the deferred hierarchical
derivation (follow-up 1) is the same fact seen from the other side.

**The derivation is not a functor on the prefix order — and that is F5 restated exactly.** Take
timelines ordered by `ancestor_of?` (`timeline.rb:119`). `T₁ ≤ T₂` does **not** imply
`derive(T₁) ≤ derive(T₂)`: `render_parent` sits inside the digest (`event.rb:100`), so re-parenting
a retained turn changes its address, and the sliding `keep_last` window shares no prefix. The
failure of structural sharing *is* the failure of functoriality. This also bounds the ROADMAP's
Context-as-IVM framing honestly: the view is incrementally maintainable at the level of **messages**
and not at the level of **events and addresses**.

**`causal_parents` is the fiber of the collapse.** A replacement event's causal set is the preimage
of that event — the derivation is a function carrying its own fiber structure, which is why T8 can
audit it and why the pre/post mapping needs no separate storage. It is also the precise reason
`Strategy` must not be a `#call(messages) -> messages` endomorphism, a rule the plan states flatly
elsewhere: a bare endomorphism loses the preimage.

**`#ranges` returns an interval partition, so its contract is a lattice fact, not a style rule.**
Non-overlapping ascending contiguous ranges over a span are exactly a choice of cut points among the
`n-1` gaps, ordered by refinement — the Boolean lattice `2^(n-1)`. A pin therefore does not "protect"
a range so much as **add a cut point**, which is why pins produce N ranges rather than one, and why
T3's three range-validation ACs (inside the span, non-overlapping, ascending) are the well-formedness
conditions of an interval partition rather than arbitrary checks.

**What there is not.** No adjunction and no retraction: nothing recovers the source from the derived
chain, and losslessness in lain is a *storage* property (the session timeline is still there), not an
algebraic one. And `causal_meets` stays a poset, not a lattice — it already lacked a unique greatest
lower bound on criss-cross fan-in (`timeline.rb:143-152`) and derived chains add more fan-in
elements. Render `meet` is untouched, because a derived root meets the source at the empty timeline.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb` (A1 adds one require line for
  the `algebra` unit, beside `content_addressed`/`freezable` at `:14-16`), `.rubocop.yml`,
  `spec/spec_helper.rb`, `spec/support/tags.rb`, `ROADMAP.md`.
- **`lib/lain/algebra.rb` is A1's own file**, created by it as that subtree's index. No other card in
  this chunk adds to it, so it never changes hands.
- **`Metrics/ClassLength` headroom, measured 2026-07-27** with the repo's own config: of the classes
  this chunk touches, none registers an offense — `Context::Combinator`, `Usage`, and `Timeline` are
  all well under the 110 cap, as are `DedupeToolCalls` and `PurgeFailedInputs`. A1's modules are new
  and small. So no card here is size-constrained; if one becomes so, extract rather than loosen.
- Every agent worktree forks from the session's start commit and may be **stale**. Each implementer's
  brief opens with one permitted git command, `git merge --ff-only main`, before any other work; the
  "never run git" rule holds for everything after it.
- **Baselines, measured 2026-07-27.** `spec/lain/gherkin_spec.rb:248` globs `planning/specs/*.md` and
  parses each plan's Gherkin, so the count depends on which untracked plan docs a checkout has:
  - committed tree at `5665f14`: **4696**
  - Joel's checkout with the untracked plan docs: **4698** (this chunk's doc adds one)
  - **an agent worktree: 4691** — no untracked plan docs. Use this one.

  A card reporting any other number has either changed behavior or is on a stale worktree; run
  `git merge --ff-only main` and re-count before diagnosing anything else.

## Open decisions

None gating any card. Three rulings recorded so they are not relitigated:

- **Every algebraic property lain maintains gets a concrete artifact in `lib/`, not just a spec
  group** (user, 2026-07-27). A structure evidenced only by how some method happens to behave is
  invisible to a reader of that method. `Lain::ContentAddressed` is the model. Declarations are
  **per-operation**, because `Timeline` has three meet-ish operations and only two obey the laws, so
  `include Algebra::MeetSemilattice` on the class would be a lie.
- **Properties are structural where they can be, and characterized by a negative where they cannot.**
  `Algebra::Elementwise` implements the whole-input map from the per-element one, so an includer
  *cannot* be non-homomorphic through that door and `is_a?` is the classification with no separate
  label to drift. Purity cannot be enforced by Ruby, so `Algebra::Pure` carries the *check* — an
  includer holds no collaborators, constructs with no arguments, and is `Ractor.shareable?`, which is
  this repo's existing mechanical proxy for "no reachable mutable state". Refutations get proven by
  A2 asserting the law actually fails.
- **No algebra traits in Rust, and A5 records why** (this interview). A trait pays when a function is
  generic over the structure and instantiated more than once; `dag.rs:96`'s `meet` is a free function
  with one implementor, and `Ext::{Turn,Store,Timeline}` have no production caller at all, so a trait
  hierarchy would be speculative generality that CLAUDE.md's five-rule gate rejects outright. The
  stronger reason: the Ruby law groups are the **differential oracle between implementations**
  (`spec/lain/rust/timeline_spec.rb:112` runs the same unchanged group against `Ext::Timeline`), and a
  second Rust-native *parity* suite would let the two answers drift. Completing Rust's *algorithm*
  tests is a different job at a different layer, and A5's doc comments must say which layer proves
  what. The trigger that would revisit this: a production Rust function generic over a structure, or
  the Rust `Timeline` moving onto the live path.

## Waves

```
Wave 1: A1, A5                (no unmet deps)
Wave 2: A3 (←A1), A4 (←A1)
Wave 3: A2 (←A1, A3)
```

> **Deviation from the planned two waves, decided by the orchestrator 2026-07-27.** The plan put A2
> in wave 2 beside A3, but the two are coupled more tightly than that allows: A2's contract is that
> *a declaration with no registered generator is a failure*, so a sweep is only meaningfully green
> once declarations exist. Run in parallel with A3, A2 would walk an **empty** registry in its own
> worktree — passing vacuously, with its generators as unreachable code and no honest red-before-green
> — and the coupling would surface only when A3 merged and A2's sweep started failing on classes it
> had never seen. Serializing costs one extra step and buys A2 a real subject.

Critical path: **A1 → A2** (two cards). A1 → A3 and A1 → A4 are the same length; A3 is the highest-risk
card because it touches `Timeline` and `Usage`, the two most heavily spec'd values in the repo. A5 is
independent of everything and could land first.

## Tasks

### A1 — Name lain's algebraic structures in `lib/`          [wave 1] [risk: medium] ✅ LANDED `d121116`

> **Landed 2026-07-27.** Panel: REQUEST-CHANGES → fix round → APPROVE. Two blockers, both aimed at
> downstream cards: `elementwise` called `define_method` *before* `registry.declare`, so the
> "refused at load" AC was structurally unreachable (a nonexistent `each:` helper was accepted
> silently and surfaced as a `NoMethodError` mid-turn inside `Context#render`); and the one doc
> example A3 would copy, `Context::Identity.new`, raises — `Identity` is a frozen *instance*.
> Orchestrator rulings on six design findings are recorded in the card body below where they changed
> the API. **Post-ruling API that wave 2 must use:** identities are `Algebra.later { ... }` (a bare
> `Proc` is refused `Unwrapped`); `bottom:` is a prose String, not a value; `commutative_monoid`
> files `[:monoid, :commutative_monoid]` implicitly, so an explicit `monoid` line beside it is a
> `Duplicate`; `elementwise` refuses to clobber a class's **own** method (`Occupied`) and must sit
> *below* the helpers it names; `not_elementwise` refuses an includer of `Elementwise`, with
> refute-without-including as the documented escape hatch.

**Depends on:** none
**Files:** `lib/lain/algebra.rb` (create), `lib/lain/algebra/monoid.rb` (create),
`lib/lain/algebra/commutative_monoid.rb` (create), `lib/lain/algebra/meet_semilattice.rb` (create),
`lib/lain/algebra/elementwise.rb` (create), `lib/lain/algebra/pure.rb` (create),
`spec/lain/algebra_spec.rb` (create)
**Shared-file wiring:** `lib/lain.rb` — one require line for the `algebra` unit, beside
`content_addressed` and `freezable` (`lain.rb:14-16`), which is where lain's other property modules
already load.
**Reuse:** **`Lain::ContentAddressed` (`content_addressed.rb`) is the precedent and the model.** It is
already exactly what this card generalizes: a module in `lib/` that names a property, is `include`d
by the values that have it, is stateless so it "cannot disturb an includer's deep freeze or its
Ractor shareability", carries the reasoning in its own doc comment, and is separately spec'd
(`spec/lain/content_addressed_spec.rb`). Match its posture line for line. For the declaration DSL,
`Isolation::Services::Builder` (`isolation/services/builder.rb:16`, `:53-56`) is the fixed-verb-list
shape with a loud `Unknown` naming the known verbs.

**Why this card exists.** Today "`Usage` is a commutative monoid" is evidenced by a `#+` method, a
`ZERO` constant, and an `include_examples "a monoid"` call in a spec file. Nothing in `lib/` says it.
A reader of `usage.rb` has to notice the shape and go looking for the proof. This card makes the
property a **declaration in the code that owns it**, so the structure is visible where the structure
lives rather than inferable from how an arbitrary method behaves.

**Declarations are per-operation, not per-class**, and this is load-bearing rather than fastidious:
`Timeline` has three meet-ish operations and only two are semilattices. `#meet` and `#dominator_meet`
obey the laws; `#causal_meets` explicitly does **not** — a criss-cross fan-in leaves incomparable
maximal common ancestors, so there is no unique greatest lower bound (`timeline.rb:143-152`).
`include Algebra::MeetSemilattice` on the class would therefore be a lie. The declaration names the
operation and its identity or bottom.

**Every concern also carries a refutation form.** Declaring that an operation is *not* a structure,
with a reason, is how the negative stays visible — the same maintenance argument behind this chunk's
negative property tests. A2 then proves both directions.

**Acceptance criteria:**

```gherkin
Scenario: a declared operation is discoverable from the registry
  Given a class declaring a monoid on one of its operations
  When the registry is asked what has been declared
  Then it names that class, that operation, and its identity

Scenario: a refutation is discoverable and carries its reason
  Given a class refuting a meet-semilattice on one of its operations
  When the registry is asked what has been refuted
  Then it names the class, the operation, and the stated reason

Scenario: two operations on one class are declared independently
  Given a class declaring a structure on two different operations
  When the registry is asked
  Then both appear, each with its own identity

Scenario: declaring a structure on an operation the class does not answer is refused at load
  Given a class declaring a monoid on a method it does not define
  When it is loaded
  Then it is refused loudly, naming the class and the missing operation

Scenario: a refutation with no reason is refused
  Given a class refuting a structure without stating why
  When it is loaded
  Then it is refused, because an unexplained negative is worse than none

Scenario: the same operation cannot be both declared and refuted
  Given a class declaring and refuting one structure on one operation
  When it is loaded
  Then it is refused, naming the contradiction

Scenario: including a property module disturbs neither freeze nor shareability
  Given a deeply frozen value class that includes each property module
  Then it remains deeply frozen and Ractor.shareable?

Scenario: the elementwise concern supplies the whole-span map from the per-element one
  Given a class including the elementwise concern and implementing only its per-element method
  When it is called with a multi-element input
  Then it answers the concatenation of the per-element results

Scenario: the pure concern requires an includer to hold no collaborators
  Given a class including the pure concern
  When it is constructed with no arguments and checked
  Then it succeeds and is Ractor.shareable?
```
→ spec file: `spec/lain/algebra_spec.rb`

**Escalation triggers:**
- **A marker that nothing reads is decoration.** A2 is what makes these declarations load-bearing,
  and this card must not ship without A2 being possible: if the registry cannot be enumerated from a
  spec, stop — the design is wrong.
- Do **not** put generators, sample values, or any test-only code in `lib/lain/algebra/`. A2 keeps
  those in `spec/support/`. `Isolation::Services`' DSL is the precedent for lib-side declaration with
  no test coupling.
- These modules must be stateless. `ContentAddressed`'s doc (`content_addressed.rb:10-12`) and
  `spec/lain/content_addressed_spec.rb:57` pin that including a property module cannot break a frozen
  includer's shareability. If a concern needs an ivar, stop.
- Do not define a structure with **no consumer in this chunk**. Group, ring, functor, and category are
  absent on purpose. The bar is a named consumer, not prior use: `Monoid`, `CommutativeMonoid`, and
  `MeetSemilattice` are consumed by A3; `Elementwise` by A4 and T7; `Pure` by T7. Anything else is the
  speculative generality this card is most likely to produce — and note the asymmetry that makes it
  tempting: A3 declares structures lain *already* maintains, while `Elementwise`/`Pure` describe ones
  it is about to. Both are fine; a fifth module with no consumer is not.

### A2 — Prove every declaration, and every refutation          [wave 3] [risk: medium] ✅ LANDED `b6866da`

> **Landed 2026-07-27.** Panel: APPROVE-WITH-FIXES → fix round → APPROVE. The keystone card, and the
> panel found the defect that would have hollowed out the chunk: **`concatenates?` was a tautology.**
> `Elementwise` *generates* `#call` as `span.flat_map { each(_1, analysis(span)) }`, and the law
> re-derived that same expression — no false branch, proven by building a fresh generated class that
> passed by construction. Both elementwise laws were `all?` over `spans`, so emptying the generator
> left the sweep at 30 examples / 0 failures, silently certifying. `functional?` meanwhile judged only
> `length_preserving` spans, excluding `restated_call` — the one span `DedupeToolCalls` rewrites. All
> three examples certifying that declaration asserted nothing about it.
>
> **Ruling:** `concatenates?` is unfalsifiable *by design* (the plan made `Elementwise` structural so
> `is_a?` is the classification), so it was demoted in the comment to a construction invariant rather
> than made falsifiable. **`functional?` became load-bearing** over a `repeated_rewrite` span
> `[m, answer, m]` — deliberately the shape of the refutation's witness. The result is the chunk's
> nicest property: **one law discriminates in both directions.** Two equal elements taking different
> images in one call is exactly what `PurgeFailedInputs` does and what `DedupeToolCalls` must not.
> Panel falsified it with a realistic bug (per-call state in `without_stale`) and the law failed by name.
>
> Also fixed: the battery/group name pin was one-directional (gutting `commutative?`/`below_both?` or
> deleting `idempotent?` all left the suite green); the `causal_meets` witness was reading-dependent
> (`.last`/`.max` held all four laws) and is now a three-way criss-cross failing under all four
> readings with nothing raising; and an `exhibits:` knob now asserts each refutation's *recorded
> reason* directly (`|causal_meets| == 3`) rather than merely asserting the reason string is present.
>
> **Documented limitation, accepted deliberately:** a trivially-true battery *body* under an unchanged
> law name still passes. The panel ruled the reasoning sound — where a `refutes:` rests on a law,
> `:fails` is demanded directly; elsewhere the shared group is the real assertion, and the
> cross-check exists to catch a battery grown too *strong*, whereas a gummed law is too weak. Written
> down in the file rather than hidden.

**Depends on:** A1
**Files:** `spec/algebra_laws_spec.rb` (create), `spec/support/algebra_generators.rb` (create)
**Shared-file wiring:** none
**Reuse:** the existing law groups **unchanged** — `spec/support/shared_examples/monoid.rb`,
`meet_semilattice.rb`, `regular.rb`. `monoid.rb:24-41` documents why `operation`/`generator`/`equal`
are built at the `include_examples` site rather than inside the group; honour that. For the
enumerate-and-enforce idiom, `spec/output_discipline_spec.rb` and `spec/lain/cli/chat_flags_spec.rb`
are the two precedents: a spec that walks the codebase and fails on a gap rather than trusting a list.

This is the card that stops A1's declarations from being decoration. It walks A1's registry and, for
every declaration, runs the matching law group; for every refutation, asserts the law **fails**. A
declaration with no registered generator is a failure, so **you cannot claim a structure without
supplying the means to prove it**.

The generators live here, in `spec/support/`, keyed by declaring class — never in `lib/`.

**Acceptance criteria:**

```gherkin
Scenario: every declared structure has its laws run against it
  Given the algebra registry as declared by production code
  When the law sweep runs
  Then each declared operation has the matching law group executed against it

Scenario: a declaration with no generator fails the sweep, naming what is missing
  Given a class declaring a structure with no generator registered for it
  When the sweep runs
  Then it fails, naming the class, the operation, and the absent generator

Scenario: a refutation is proven by the law actually failing
  Given a refuted operation
  When the sweep runs the law group against it
  Then the law does not hold, and the sweep reports the refutation as confirmed

Scenario: a refutation whose law unexpectedly holds is a failure, not a pass
  Given an operation refuted as not a semilattice that in fact obeys the laws
  When the sweep runs
  Then it fails, because the refutation is now wrong and the comment would mislead

Scenario: the sweep covers the whole registry with no hand-maintained list
  Given a newly declared structure added anywhere in lib
  When the sweep runs without being edited
  Then that declaration is included
```
→ spec file: `spec/algebra_laws_spec.rb`

**Escalation triggers:**
- The existing law groups must be used **unchanged**. `spec/lain/rust/*` runs the same groups against
  the Rust implementations, and `docs/GLOSSARY.md:315-325` calls that "the acceptance test for any
  Rust port". If proving a declaration requires editing `monoid.rb` or `meet_semilattice.rb`, stop —
  a changed group silently reinterprets every existing caller.
- Refuting a law by running a group and expecting failure is easy to write so loosely that it passes
  for the wrong reason (a raise, a nil, a typo'd operation name). The refutation must fail on the
  **law**, not on an error. If it cannot be made to fail specifically, stop.
- If the sweep needs `ObjectSpace` or a constant walk to find declarers, stop — A1's registry is the
  enumeration seam, and reaching around it means A1 is wrong.

### A3 — Declare the structures lain already maintains          [wave 2] [risk: high] ✅ LANDED `9a95095`

> **Landed 2026-07-27.** Panel: APPROVE-WITH-FIXES (all mechanical) → fixes → merged. The high-risk
> card turned out clean: zero deletions across all six files, no fourth structure, no ivars, and
> byte identity re-derived by the panel with its own independent fixture against both the worktree
> and `main` (request bytes, `cache_payload` bytes, `Request#digest`, all three turn digests, the
> `Usage` fold, every freeze flag).
>
> **The refutation was verified, not assumed.** The panel built the criss-cross fan-in and ran all
> four laws for real: 2 maximal common causal ancestors with neither an ancestor of the other, so no
> unique greatest lower bound. Idempotence fails; associativity and meet-below-both fail on type
> (`causal_meets` returns an `Array`, not a `Timeline`); **commutativity alone survives**. That is why
> the recorded reason names the *order* defect first and derives set-valuedness from it — "wrong
> return type" alone would have been an incomplete reason.
>
> **Two facts A2 must not trip over**, both found here: `registry.about(Prune)` is `[]` because the
> monoid is declared on `Context::Combinator` (which owns `#>>` and is overridden nowhere below), so
> a sweep keyed on exact class sees only the base. And **`Combinator.new` *is* the identity** — the
> base `#call` returns its argument — so a generator instantiating the declared subject alone folds
> only units and the monoid laws pass **vacuously**. A2 needs a subclass-flavored generator, as the
> three pre-existing call sites each hand-roll. `dominator_meet` also needs one injected `Dominators`
> across a run or it rebuilds the union-graph dominator tree per call.

**Depends on:** A1
**Files:** `lib/lain/context/base.rb` (modify), `lib/lain/usage.rb` (modify),
`lib/lain/timeline.rb` (modify), `spec/lain/context/base_spec.rb` (modify),
`spec/lain/usage_spec.rb` (modify), `spec/lain/timeline_spec.rb` (modify)
**Shared-file wiring:** none
**Reuse:** the declarations must match what the specs **already prove**, so the existing call sites
are the source of truth for each: `spec/lain/context/base_spec.rb:26-33`
(`include_examples "a monoid"` over `>>` with `Context::Identity`), `Usage#+` (`usage.rb:33`) with
`Usage::ZERO` (`:70`), and `spec/lain/timeline_spec.rb:204`/`:469` (the `MeetSemilattice` group over
render `meet` and over `dominator_meet`).

**Deliberately scoped to three structures.** Only those whose law groups already run, so this card
adds declarations and no new proof burden. `Regular`, `Store`'s idempotent `put`, and `Canonical`'s
determinism are all real and all follow-ups — declaring them means also deciding their generators,
which is A2's contract and a bigger job than it looks.

`Timeline` is the interesting one and the reason this card is high risk: **two declarations and one
refutation.** `#meet` and `#dominator_meet` are semilattices; `#causal_meets` is refuted, with
`timeline.rb:143-152`'s own reasoning as the stated reason.

**Acceptance criteria:**

```gherkin
Scenario: reading the combinator source tells you it is a monoid
  Given lib/lain/context/base.rb
  When a reader looks for its algebraic structure
  Then the class declares a monoid on its composition operator with the identity combinator

Scenario: reading Usage tells you it is a commutative monoid
  Given lib/lain/usage.rb
  When a reader looks for its algebraic structure
  Then the class declares a commutative monoid on addition with its zero

Scenario: the Timeline declares both of its semilattice operations
  Given lib/lain/timeline.rb
  When the registry is asked what the Timeline declares
  Then both the render meet and the dominator meet appear

Scenario: the Timeline refutes the causal meet, with its reason
  Given the same file
  When the registry is asked what the Timeline refutes
  Then the causal meet appears, and its reason names the criss-cross fan-in

Scenario: the declarations agree with what the suite already proved
  Given the law sweep and the pre-existing law-group call sites
  When both run
  Then no declaration contradicts a law group that already passed

Scenario: nothing about the declared objects behaves differently
  Given a run before and after the declarations
  When a rendered request and a usage total are compared
  Then they are byte-identical
```
→ spec file: `spec/lain/context/base_spec.rb`, `spec/lain/usage_spec.rb`,
`spec/lain/timeline_spec.rb`

**Escalation triggers:**
- **`Timeline` and `Usage` are the two most heavily spec'd values in the repo.** `timeline_spec.rb`
  is 614 lines and pins `Regular`, both `MeetSemilattice` populations, brute-force dominator
  agreement, and cross-store refusals; `Event`/`Timeline`/`Usage` are all pinned deeply frozen and
  `Ractor.shareable?`. A declaration that adds an ivar, a singleton, or a mutable registry entry to
  an instance will break shareability. If including a concern changes any of those specs, stop.
- The Rust parity specs (`spec/lain/rust/timeline_spec.rb:112`, `:129`) run the same law groups
  against `Lain::Ext::Timeline`, which **cannot** carry a Ruby concern. So a declaration must not
  become a precondition for running the laws, or the Rust suite breaks. If A2's sweep starts
  requiring a declaration that the Rust implementation cannot make, stop — that is the port
  acceptance rule (`ext/lain/CLAUDE.md`) being violated.
- Do not declare a fourth structure "while in there". `Regular` in particular looks free and is not:
  it applies to a dozen classes and each needs a generator.
- If `#causal_meets`'s refutation turns out to be *wrong* — the laws hold — stop and escalate. That
  would be a genuine discovery about the DAG, not a licence to delete the refutation.

### A4 — Make the two-phase combinators' factoring explicit          [wave 2] [risk: medium]

**Depends on:** A1
**Files:** `lib/lain/context/dedupe_tool_calls.rb` (modify),
`lib/lain/context/purge_failed_inputs.rb` (modify),
`spec/lain/context/dedupe_tool_calls_spec.rb` (modify),
`spec/lain/context/purge_failed_inputs_spec.rb` (modify)
**Shared-file wiring:** none
**Reuse:** both combinators already have the shape; this card names it rather than inventing it.
`dedupe_tool_calls.rb:24-27` is `stale_ids = stale_tool_use_ids(messages)` then
`messages.filter_map { without_stale(_1, stale_ids) }`; `purge_failed_inputs.rb:43-50` is
`failed_ids = failed_tool_use_ids(messages)` then a per-message purge. A1's elementwise concern is
the vocabulary for the second phase.

**This is the algebra applied to existing code, and it is the first card of the chunk for that
reason.** Both combinators are *elementwise once their analysis is fixed* — the unconditional
elementwise case (T7's elide) is the same shape with a trivial analysis. Naming the factoring buys
three things: it explains why these two are not unconditionally elementwise and therefore why
composition order matters; it makes the analysis an inspectable value instead of a local variable;
and because the second phase is per-message, every output message has a known preimage, so a future
caller can journal *what was dropped and why* — which neither can do today.

Behavior must not change. Both are unwired in production (F7), and their existing specs pin purity,
non-mutation, the monoid law, and `#requires`.

**Acceptance criteria:**

```gherkin
Scenario: the analysis phase is an inspectable value
  Given a message list containing a superseded tool call
  When the combinator is asked for its analysis of that list
  Then it answers the stale identifiers it would act on, without transforming anything

Scenario: the transform phase is elementwise in that analysis
  Given an analysis and a message list
  When each message is transformed against that fixed analysis
  Then the result equals what the whole-list call produces

Scenario: the combinator declares that it is elementwise only relative to its analysis
  Given each of the two combinators
  When the registry is asked
  Then each declares the conditional form and neither claims to be unconditionally elementwise

Scenario: every surviving message names the input it came from
  Given a list where one message is dropped and another rewritten
  When the transform runs
  Then each output message is traceable to exactly one input message

Scenario: behavior is unchanged for every existing case
  Given the pre-existing specs for both combinators
  When they run against the refactored objects
  Then all pass unmodified in their assertions

Scenario: purity and the monoid law still hold
  Given each refactored combinator
  When its existing purity and composition examples run
  Then the input is unmutated and composition still obeys the monoid law
```
→ spec file: `spec/lain/context/dedupe_tool_calls_spec.rb`,
`spec/lain/context/purge_failed_inputs_spec.rb`

**Escalation triggers:**
- **This card changes no behavior.** Both spec files pin purity, no-input-mutation, `#requires == []`,
  and the monoid law. If any existing assertion has to change to accommodate the factoring, the
  factoring is wrong — stop rather than editing the expectation.
- `DedupeToolCalls#without_stale` **drops the whole message** when its content empties
  (`dedupe_tool_calls.rb:64`), so the per-message map is `[M] -> [M]` and not `M -> M`. If the
  elementwise vocabulary cannot express a per-message map that returns zero or more messages, stop —
  T7's elide has the same requirement and A1 owes both.
- Do not wire either combinator into a production pipeline. They are unwired today and making them
  reachable is a separate decision with its own risk; this card is a refactor.
- Do not add journalling here. The card makes provenance *available*; emitting a record needs a
  Telemetry type and an owner, and that is a follow-up.

### A5 — Prove and document the Rust side's algebraic claims          [wave 1] [risk: medium] ✅ LANDED `0a31662`

> **Landed 2026-07-27.** Panel: APPROVE-WITH-FIXES → fix round → APPROVE. No law failed;
> `dag::meet` was already correct. The value was in the *evidence*: mutation testing (re-derived
> independently by the panel) shows that treating the empty head as an identity rather than a bottom
> element is caught by the two **newly added** laws only — all three pre-existing meet tests pass
> against that broken `meet`. Panel caught that `#![deny(missing_docs)]` was inert (every module
> private, zero items in scope), fixed by a scoped `clippy::missing_docs_in_private_items` on `dag`
> and `digest` — 0 offenses, zero doc-writing diff, and it demonstrably bites. `Store::put` was split
> into a pure `put_into` so its law was reachable from `cargo test`; behavior verified identical under
> an 8-thread contended race. `spec/` byte-unchanged throughout.

**Depends on:** none
**Files:** `ext/lain/src/dag.rs` (modify), `ext/lain/src/lib.rs` (modify — crate-root lint and the
`Store` law), `ext/lain/CLAUDE.md` (modify)
**Shared-file wiring:** none
**Reuse:** `spec/support/shared_examples/meet_semilattice.rb` is the **authority on which laws
exist** — 4 of them: idempotent (`:39`), commutative (`:45`), associative (`:52`), and meet-below-both
(`:61`). Do not invent a fifth or restate them differently; the Rust tests assert the same four so the
two layers cannot disagree about what the law *is*. `store_laws.rb:31,39` is the same authority for
`put` idempotence. `dag.rs`'s existing 12 tests are the style to match (plain `#[test]`, named for the
property, no framework).

**The gap, measured 2026-07-27.** `dag.rs:9` claims "the whole **meet-semilattice** can be
unit-tested without an embedded Ruby VM." The tests deliver about half of that: `meet_is_commutative`
covers commutativity, and `meet_is_the_greatest_common_ancestor` plus `empty_is_below_everything`
between them cover meet-below-both. **Idempotence and associativity are absent.** No Rust test asserts
`Store::put` idempotence either — only the Ruby parity spec does
(`spec/lain/rust/store_spec.rb:27`). And the crate root carries only
`#![deny(clippy::print_stdout, clippy::print_stderr)]`; `missing_docs` is not enforced.

**Two layers, two jobs — and the doc comments must say which is which.** This is what keeps the card
from forking the differential oracle:

- **`cargo test` proves the Rust *algorithm* obeys the laws**, at a layer the Ruby suite cannot
  reach: `dag.rs` is plain functions over an `rpds` map with no `magnus` and no VM, which
  `dag.rs:9` already gives as the reason those tests exist.
- **`spec/lain/rust/*` proves the Rust *binding* agrees with Ruby**, running the shared groups
  unchanged. That stays the sole authority on cross-implementation agreement.

Adding algorithm-level law tests is completing the first job. Asserting "Rust equals Ruby" inside
`cargo test` would be duplicating the second, and that is the drift this card must not create.

`ext/lain/CLAUDE.md` records the resulting rule so a future porter does not reach for
`trait Monoid`: **a ported structure inherits the Ruby declaration rather than making its own**, and
algebra traits wait until a production Rust function is generic over the structure. (Note for that
doc: `ext/lain` is **not** under the `#![forbid(unsafe_code)]` rule that `crates/lain-core/src/main.rs:13`
carries — its ~7 `unsafe` blocks are magnus and `libc::dup` FFI-boundary calls. That is pre-existing
and out of scope here; the doc should simply not imply otherwise.)

**Acceptance criteria:**

```gherkin
Scenario: the meet is proven idempotent in Rust
  Given a forest of content-addressed events
  When a head is met with itself
  Then the result is that head, across every generated case

Scenario: the meet is proven associative in Rust
  Given three heads from the same store
  When they are met in both bracketings
  Then both orders agree

Scenario: the four laws asserted in Rust are the same four the Ruby group asserts
  Given the shared meet-semilattice example group and the Rust test module
  When the law names are compared
  Then each Ruby law has a Rust counterpart and neither side asserts a law the other does not

Scenario: putting the same object twice is proven idempotent in Rust
  Given a store and one event
  When it is put twice
  Then the store holds one object and both puts answer the same digest

Scenario: the module doc claims no more than the tests cover
  Given the ancestry module's doc comment
  When it names the structure it implements
  Then every law it claims has a test in that module

Scenario: missing documentation fails the build
  Given the crate root
  When the crate is compiled
  Then missing documentation on a public item is a denied lint, and the crate compiles clean

Scenario: each documented item says which suite proves what
  Given a public item carrying an algebraic claim
  When its doc comment is read
  Then it names the structure, the operation, and whether the proof is the Rust test or the Ruby parity group

Scenario: no behavior changes
  Given the Ruby parity specs for the Rust Timeline and Store
  When they run against the modified crate
  Then they pass unmodified
```
→ spec file: `ext/lain/src/dag.rs` and `ext/lain/src/lib.rs` `#[cfg(test)]` modules (this card's
proofs are `cargo test`, not RSpec — the RSpec side is the *unchanged* parity suite, which
integration check 2 already runs)

**Escalation triggers:**
- **If a law fails, STOP.** An idempotence or associativity failure is a real defect in `dag::meet`,
  not a test to adjust — and the Ruby parity group would only have caught it if the binding happened
  to exercise that case. That is precisely why this card exists, and it is the most valuable thing it
  could find.
- Do not assert Ruby/Rust agreement in `cargo test`. `spec/lain/rust/*` owns that, using the shared
  groups unchanged, and `ext/lain/CLAUDE.md`'s port acceptance rule depends on there being exactly
  one such authority. If a Rust test wants a Ruby value to compare against, it belongs in RSpec.
- `#![deny(missing_docs)]` may light up a large number of existing public items. Count them first and
  report the number before writing anything: filler doc comments are worse than none, and if the count
  is large this becomes its own card rather than a silent 300-line diff.
- `Ext::Timeline` has **no** `dominator_meet` and **no** `causal_meets` (verified). So the two most
  interesting declarations from A3 have no Rust counterpart. Do not add those operations to Rust to
  give the doc comments something to say — that is a port decision gated by CLAUDE.md's five-rule
  test, not a documentation task.
- Do not touch the `unsafe` blocks or add `forbid(unsafe_code)` to `ext/lain`. They are FFI-boundary
  calls in magnus's own unsafe API; removing them is not possible and forbidding them would not
  compile.

## Integration checks

After the last wave:

1. `bundle exec rake` (compile, full suite, rubocop) green. Expect **> 4691** examples in a worktree.
2. `cargo test && cargo clippy --all-targets -- -D warnings` green. **A5 makes this load-bearing**: it
   adds the two missing meet-semilattice laws, the `Store` put-idempotence law, and
   `#![deny(missing_docs)]` at the crate root.
3. `pre-commit run --all-files` green.
4. Confirm the shared example groups in `spec/support/shared_examples/` are **byte-unchanged**. They
   are the differential oracle for the Rust port (`docs/GLOSSARY.md:315-325`); a modified group
   silently reinterprets every existing caller, including `spec/lain/rust/*`.
5. Confirm `spec/lain/rust/timeline_spec.rb` and `store_spec.rb` pass unmodified. A2's sweep must not
   make a declaration a *precondition* for running the laws — `Lain::Ext::Timeline` cannot carry a
   Ruby concern, and requiring one would break the port acceptance rule in `ext/lain/CLAUDE.md`.
6. ~~Confirm `Ractor.shareable?` still holds for `Event`, `Payload`, `Timeline`, and `Usage`.~~
   **CORRECTED 2026-07-27 during execution — the grounding was wrong here.** Measured on `main` at
   `5665f14`: `Ractor.shareable?(Timeline.empty)` is **`false`**, and always was — the handle holds a
   mutable `Store`. Further, *no* spec pins `Ractor.shareable?` on `Event`, `Usage`, or `Timeline`;
   what they pin is **deep freeze** (`usage_spec.rb:27`, `event_spec.rb:114`, `:202`), and
   `timeline_spec.rb` carries no shareability assertion at all (only `be_frozen` on a
   `causal_meets` result, `:225`). There is no `Payload` spec file. `Usage::ZERO` and
   `Context::Identity` *are* shareable.

   The A3 escalation trigger reading "`Event`/`Timeline`/`Usage` are all pinned deeply frozen and
   `Ractor.shareable?`" is therefore overstated. This **de-risks** A3 rather than invalidating it —
   nothing to preserve that was not already there. Corrected check: confirm `Event` and `Usage` stay
   **deeply frozen**, confirm `Usage::ZERO` and `Context::Identity` stay `Ractor.shareable?`, and do
   **not** assert `Timeline` shareability. A1's modules must still be stateless — that requirement
   stands on its own.
7. Report the `#![deny(missing_docs)]` offense count A5 found **before** it wrote any docs, so the
   size of that diff is a recorded decision rather than a surprise.

**Manual pass owed to Joel:** read `lib/lain/usage.rb` and `lib/lain/timeline.rb` cold and confirm the
declarations answer "what structure is this, on which operation, and what proves it" without leaving
the file. That is the whole point of the chunk, and it is the one thing no spec can check.

## Integration checks — RUN 2026-07-27, all green

1. ✅ `bundle exec rake` — compile, full suite, rubocop. **4820 examples, 0 failures, 2 pending**
   (chunk start 4780 in this checkout, +40 from A2's sweep). RuboCop 782 files, no offenses.
2. ✅ `cargo test` **112 / 16 / 1**, `cargo clippy --all-targets -- -D warnings` clean. A5 made this
   load-bearing: two added meet laws, the `Store` put-idempotence law, and the scoped doc deny.
3. ✅ `pre-commit run --all-files` — every hook Passed, including `cargo deny` and `cargo fmt`.
4. ✅ `spec/support/shared_examples/` — the **seven pre-existing groups are byte-unchanged** vs
   `5665f14`; the only delta is the new `elementwise.rb` (+110), an expansion approved during A2's fix
   round because a law group registered from inside a spec file is load-order dependent for future
   consumers.
5. ✅ `spec/lain/rust/` — **zero diff** vs `5665f14`. A declaration never became a precondition for
   running the laws, so the port acceptance rule in `ext/lain/CLAUDE.md` holds.
6. ✅ **(corrected — see the note under this heading)** `Usage` deeply frozen; `Usage::ZERO` and
   `Context::Identity` `Ractor.shareable?`; `Timeline.empty` still `false`, unasserted and un-"fixed".
   Registry carries 8 entries. The freeze/shareability/declaration specs: 250 examples, 0 failures.
7. ✅ **`#![deny(missing_docs)]` offense count measured before any docs were written: 0** — the lint
   only sees crate-root-reachable public items and every module in `ext/lain` is private. Verified
   live (adding a `pub` item yields 3 errors). `clippy::missing_docs_in_private_items` would be
   **109** (58 `lib.rs`, 22 `event.rs`, 14 `astgrep.rs`, 8 `canonical.rs`, 6 `treesitter.rs`, 1
   `bm25.rs`); that stays off and is follow-up 10. The enforcing lint landed **scoped** to `dag` and
   `digest` — both already at zero, so no doc-writing diff, and deleting a doc comment in either is
   now a hard error.

## Follow-ups designed here, deliberately not built

0. **Declare `Middleware#>>` as a monoid — the coverage is otherwise arbitrary.** Found by A3's panel,
   2026-07-27. The chunk's inclusion criterion is "only those whose law groups already run", and
   `Middleware#>>` meets it: `middleware_spec.rb`, `repl_middleware_spec.rb`,
   `agent_turn_middleware_spec.rb`, `middleware/skill_dispatch_spec.rb` and `middleware/env_spec.rb`
   all run `"a monoid"` against it. Yet `middleware.rb` says nothing while `usage.rb` now does. A3 was
   right to stay inside its three files; naming `Middleware` here makes the gap a schedule rather than
   an accident.
0b. **Latch the declaration verbs after the class body.** Found by A3's panel. `include
   Algebra::Monoid` leaves `monoid`/`not_a_monoid` public on the class forever, so
   `Lain::Timeline.meet_semilattice(on: :length, bottom: "x")` is callable at runtime from anywhere
   and mutates process-global state. Harmless today because nothing calls it, but the fix belongs in
   A1's modules — a latch, or `private_class_method` after the body. Related to follow-up 11
   (`Registry#seal`); the two are the same invariant seen from the declaring side and the registry
   side.
1. **Declare `Regular` — and note the sweep's coverage gap it leaves.** It applies to a dozen classes
   (`Event`, `Payload`, `Timeline`, `Digest`, …) and `spec/support/shared_examples/regular.rb` already
   runs against several. Left out because each declarer needs a generator under A2's contract, which
   is a bigger job than the declaration. **Sharpened by A2's panel, 2026-07-27:** `"a Regular value"`
   has **nine** consumers including *both* `spec/lain/rust/` specs, and there is no `:regular` in
   `Algebra::STRUCTURES` — so A2's sweep covers **3 of the 8** shared groups in the tree, and the one
   it cannot reach is precisely the one `docs/GLOSSARY.md:315-325` calls "the acceptance test for any
   Rust port". Adding `:regular` to the vocabulary is A1's file, not A2's.
2. **Declare `Store`'s idempotent `put` and `Canonical`'s determinism.** Both have law groups
   (`store_laws.rb`, `canonical_laws.rb`) and both are real; same generator cost as above.
3. **Algebra traits in Rust.** Gated on a production Rust function generic over a structure, or the
   Rust `Timeline` reaching the live path. A5 records the reasoning in `ext/lain/CLAUDE.md` so the
   next porter does not reach for `trait Monoid` and fork the parity oracle.
4. **Journal what a two-phase combinator dropped.** A4 makes provenance *available* — each output
   message traceable to one input — but emits no record. Doing so needs a `Telemetry` type and an
   owner, and neither combinator has a production caller yet.
5. **Wire `Prune` / `DedupeToolCalls` / `PurgeFailedInputs` into a production pipeline, or delete
   them.** All three are fully built, spec'd, and called by nothing. A4 improves two of them without
   answering that question.
6. **`Canonical.dump(...).bytesize` is not additive**, so the byte proxy is not a monoid homomorphism
   from message lists to integers. This is why the downstream chunk's shrink floor had to be *measured*
   at exactly 366/367 bytes and why an empty `Compaction::Head` measures 2 (the bytes of `"[]"`). Worth
   a `docs/GLOSSARY.md` line so the next reader does not try to derive it analytically.
7. **Usage aggregation is a homomorphism only on *disjoint* unions.** The design plan's warning that
   naive summing "double-counts the shared prefix" is exactly that statement, and it is why
   `Ledger#unique_turns` (`ledger.rb:115-119`) exists. It also flags the risk in
   `Event::Projection#reachable`, which *does* traverse causal edges transitively and so produces
   overlapping sets — the unsafe case. Two implementations of one rule.
8. **Pin state is not a join-semilattice.** Pins accumulate and retract, so the journal must be an
   ordered log rather than a set of pin events. Worth naming next to `docs/GLOSSARY.md`'s CRDT entry,
   which could otherwise be read as implying session state merges the way the Timeline does.
9. **Pin `Store::put`'s check/insert atomicity with a *contended* spec.** Found by A5's review panel,
   2026-07-27. `spec/lain/rust/store_spec.rb`'s "survives concurrent writers" writes 50 **distinct**
   turns from 5 threads, so it never contends the check/insert pair at all — yet `put_into`'s doc
   comment now claims "no TOCTOU window". A5's refactor does not weaken this (the panel's
   `probe-contended-put.rb` — 300 rounds, 8 threads racing the same turn, plus a chained parent/child
   race — passes), but nothing in the suite would notice if a future change broke it. Promote that
   probe into `spec/lain/rust/store_spec.rb`. Deliberately not done in A5, whose acceptance required
   `spec/` to stay byte-unchanged.
10. **Enforce doc coverage crate-wide in `ext/lain`.** `#![deny(missing_docs)]` at the crate root is
    inert here — every module is private, so it has zero items in scope. A5 lands
    `#[deny(clippy::missing_docs_in_private_items)]` scoped to the modules that are already clean
    (`dag`, `digest`), which bites where the algebraic claims live at zero doc-writing cost. Widening
    it to the rest of the crate is a **109-item** job, by file: 58 `lib.rs`, 22 `event.rs`, 14
    `astgrep.rs`, 8 `canonical.rs`, 6 `treesitter.rs`, 1 `bm25.rs` (measured 2026-07-27, confirmed by
    the panel). That is its own card, not a silent diff — which is exactly what A5's escalation
    trigger was protecting against.
11. **`Registry#seal`, to make "declarations happen at load" an invariant rather than a convention.**
    Found by A1's review panel, 2026-07-27. `Algebra.registry` is never frozen and stays writable at
    runtime, so a spec that forgets its injected `registry:` permanently retains an anonymous class in
    the process-wide one (probed: global grew 0→1, retained). `@registry ||= Registry.new` is also a
    non-atomic memo and `refuse_conflict` is check-then-act over a plain Array — both harmless while
    declaration is load-time-only, which is precisely the property a seal would enforce. Deferred from
    A1 only because calling it needs a **second** line in `lib/lain.rb`, and that file is
    orchestrator-owned and held to the one require line this chunk budgeted.
