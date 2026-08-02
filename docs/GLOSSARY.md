# Glossary

The math and CS vocabulary that [`README.md`](../README.md) and [`ARCHITECTURE.md`](../ARCHITECTURE.md)
use without defining. Each entry gives the general definition first, then what the concept is doing
in this codebase specifically.

## Algebra and order theory

### Monoid

> A set with an associative binary operation and an identity element.
> ([Wikipedia](https://en.wikipedia.org/wiki/Monoid))

Five operations in lain are monoids, and each one is property-tested against the same shared example
group in `spec/support/shared_examples/monoid.rb`. `Middleware` composes with `Composable#>>`, and
`Middleware::Identity` is the pass-through that leaves a stack unchanged. The `Context` combinator
chain composes with the same `>>`. `Usage` adds token counts and is additionally commutative, so the
order you fold a session's turns in cannot change the total.
`Compaction::Strategy::Replacement` concatenates content blocks with `+` over `DROP` (see
[free monoid](#free-monoid)). `Compaction::Strategy::Base#|` composes two strategies over one span
with `Strategy::Identity` as its unit, and is commutative too, because the derivation folds ranges in
ascending index order whichever operand was written first.

The laws matter operationally. If `Context` composition were not associative, the prompt you get
would depend on how you bracketed the combinators, which is the class of bug that ordinary
example-based tests miss.

### Free monoid

> The monoid whose elements are all finite sequences of elements from a set, with concatenation as
> the operation. ([Wikipedia](https://en.wikipedia.org/wiki/Free_monoid))

Because `Context` composition is associative, a strategy *description* is determined by its
sequence of combinators and not by how they are bracketed, so the descriptions form the free
monoid on the combinator set. Distinct descriptions can name the same strategy (composing with the
identity; pruning twice), so the strategy space proper is that monoid's image under evaluation,
but descriptions are what is enumerable: the bench sweeps words over a fixed generator list
instead of running a hand-written menu of named strategies.

There is a second instance one level down. A compaction strategy's `#blocks` maps a span of messages
into the free monoid on **content blocks** — concatenation, with the empty block list as `ε`. The
image of that unit is `Compaction::Strategy::DROP`, and `Replacement` declares itself a monoid over
it — `monoid on: :+, identity: Algebra.later { DROP }`, deferred because the unit is defined below the
declaration — so `spec/support/shared_examples/monoid.rb` holds it to the same identity and
associativity laws it holds `Middleware` to. That declaration is why a range whose collapse answers
`DROP` contributes no replacement event at all rather than an empty one: vanishing *is* what a unit
does, and `Strategy::Base#collapse` reads an empty block list as `DROP` rather than as a blank
message the provider would reject.

### Monoid homomorphism

> A map between monoids that preserves the operation and the identity: `f(a · b) = f(a) · f(b)` and
> `f(e) = e'`. ([Wikipedia](https://en.wikipedia.org/wiki/Monoid#Monoid_homomorphisms))

Both halves are checked by `spec/support/shared_examples/monoid_homomorphism.rb`: "maps the empty
span to the unit" and "maps a concatenation of spans to the concatenation of their collapses".
`Compaction::Strategy::Elide` is held to it; `Compaction::Strategy::Summarizing` is held to the
group's *negative* reading, because summarizing a concatenation is not the concatenation of
summaries.

The universal property of the free monoid is what makes this the same condition as being
**elementwise**. A map out of a free monoid is determined by its action on generators, so a
span-collapse that is a homomorphism is exactly one that is a per-message map concatenated — and
conversely. That equivalence is why `Algebra::Elementwise` is *structure* rather than convention:
`elementwise on: :blocks, each: :attested` **generates** the whole-span method as
`span.flat_map { attested(_1) }`, so an includer cannot be non-homomorphic through that door, and
`is_a?(Elementwise)` is the classification with no separate label to drift from it. Recording the
negative therefore means *not* including the module and filing the refutation directly with
`Algebra.registry.refute` — `Elementwise.not_elementwise` raises `Algebra::Contradiction` on an
includer, on purpose.

`spec/algebra_laws_spec.rb` sweeps the registry, so every declaration runs the shared group and every
refutation runs a battery, and a refutation confirmed by an *error* rather than by a failing law is
itself a failure. The scoping is worth knowing: the plain law above is false on purpose for a
combinator declared `given:` an analysis of the whole span (splitting the span splits the analysis),
so that family is judged by the conditional law in `elementwise.rb` instead.

### Endomorphism

> A homomorphism from a mathematical object to itself.
> ([Wikipedia](https://en.wikipedia.org/wiki/Endomorphism))

Every `Context` combinator maps a message list to a message list. Prune, Compact, CacheBreakpoints,
Reminder, and the rest all share that shape, which is what lets them compose in any order and form
the monoid above. A combinator that returned something other than a message list would break the
composition.

A compaction `Strategy` is deliberately **not** one. A bare `#call(messages) -> messages` would lose
the preimage — which source turns each replacement stands for — so the seam answers a `Replacement`
and the derivation records the preimage as `causal_parents`. See [Fiber](#fiber-preimage).

### Functor

> A structure-preserving map between categories: it sends objects to objects and arrows to arrows,
> preserving identities and composition. Over two partial orders, that is simply a monotone map —
> `a <= b` implies `f(a) <= f(b)`. ([Wikipedia](https://en.wikipedia.org/wiki/Functor))

lain's instructive instance is a **negative**, and it is asserted rather than merely noted.
Timelines are partially ordered by prefix, and compaction is a map from a timeline to a derived one,
so the obvious guess is that the map is monotone: extend the source by a turn and the derived chain
should extend too. It does not. `T1 <= T2` does not imply `derive(T1) <= derive(T2)`, for two
independent reasons — `Event#payload` folds `render_parent`, so a retained turn re-committed under a
different parent chain gets a *different* digest, and the `keep_last` window slides, so a later
derivation collapses a different span. `spec/lain/compaction/derivation_spec.rb` ("is not a functor
on the prefix order: T1 <= T2 does not imply derive(T1) <= derive(T2)") and
`spec/lain/compaction/source_spec.rb` ("is not a functor on the prefix order") each pin it, the
second through the live `Compaction::Source`.

The wrong model those two exist to prevent is "**derivation is incremental**" — that a compacting
turn extends the previous derived chain, sharing its prefix, the way the session timeline extends
itself. A reader who assumes it writes a `Derivation#extend`, which would have to hold the last
derived head, which is the state the non-recursive ruling exists to avoid. So there is no `#extend`,
every compacting turn derives fully, and the specs go red if someone "fixes" it. Failed structural
sharing and failed functoriality are the same fact stated twice; what makes full re-derivation
affordable is that the derived chain is bounded by `keep_last`, not by history length
(`spec/lain/compaction/derivation_spec.rb` pins 21 events and 22 store objects at 50, 200 and 800
source turns alike).

### Fiber (preimage)

> The fiber of a map `f` over a point `y` is `f⁻¹(y)`, the set of inputs that map to it. The fibers
> partition the domain. ([Wikipedia](https://en.wikipedia.org/wiki/Fiber_(mathematics)))

A replacement event's `causal_parents` is exactly the fiber of the collapse: the set of source turns
that map to it. Nothing else needs storing. There is no side table of "what became what", because the
derived chain *is* the mapping, read backwards along its causal edges — which is what lets
`Compaction::DerivationAudit` re-derive an edge and compare, and what would be lost if the strategy
seam were a bare endomorphism on message arrays.

This works because `Timeline#to_a` follows `render_parent` only, so a fan-in on `causal_parents`
never drags the subsumed turns back into the render, and `Ledger#unique_turns` walks render ancestry,
so it never double-counts their tokens. A retained turn's causal set is stored **empty**: its fiber
is the singleton recoverable from the event itself, so only the replacements' fibers need recording,
and replacements' fibers plus retained turns still cover the source span exactly once. `Arm::Synthesis` is the older
writer of the same shape, and both share its discipline: a causal parent the `Store` has not seen
raises rather than being quietly dropped, so a fiber is never silently incomplete.

### Interval partition

> A partition of a totally ordered set into contiguous blocks. Choosing one is choosing where to cut:
> for `n` elements there are `n-1` gaps, each independently a cut or not, so the interval partitions
> form a Boolean lattice of size `2^(n-1)` ordered by refinement.
> ([Wikipedia](https://en.wikipedia.org/wiki/Partition_of_an_interval))

`Lain::IntervalPartition` (`lib/lain/interval_partition.rb`) is the value: a frozen
`(owner, span, ranges)` triple that cannot be held in an invalid state, because **seven** conditions
are checked at construction and each is refused on its own terms — a proposal that is not an `Array`
at all, a member that is not a `Range`, endpoints that are not Integer message indices, an empty
range, one outside the span, two out of ascending order, and two that overlap. The order of the
checks is deliberate: ranges out of order would *also* trip the overlap check, so being told about an
overlap when the fault is the ordering sends a reader to the wrong line. The refusals run against the
proposal **as proposed**, before the ranges are normalized to their canonical inclusive spelling, so
a message never quotes ranges its author did not write. `owner` and the constructor's `provenance`
are diagnosis only and no part of identity: two partitions of one span into the same intervals are
the same partition, whoever asked for them.

What a compaction strategy answers from `#ranges` is one of these over the collapsible span, with the
gaps between the ranges retained verbatim. The conditions are **well-formedness**, not style, because
the derivation folds the ranges straight into writes — one replacement per range, retained turns in
the gaps — with no per-index membership test to catch a bad answer.
`spec/lain/interval_partition_spec.rb` pins each refusal on the value itself, and
`spec/lain/compaction/strategy_spec.rb` and `spec/lain/compaction/derivation_spec.rb` keep pinning
them from the seat where the damage was felt.

The value sits at lib level rather than inside `Compaction::Strategy` because it has three callers
and only one of them is a strategy:

- `Strategy::Base#ranges` validates whatever the `#propose_ranges` hook answered (`.of`), and a
  refusal cites that hook by name.
- `Source::Derived::PinCuts` builds the runs a set of cut points leaves (`.covering`). This is what
  makes a **pin a cut point rather than a shield**: the span splits into one sub-span per contiguous
  run of unpinned messages, so the pinned turn falls in no range at all and the derivation retains
  it, in position, between the two replacements either side. That is `keep_last + 3` rendered
  messages where the old projection gave `keep_last + 2`, pinned in
  `spec/lain/compaction/source_spec.rb`.
- `Compaction::Strategy::Composed` asks two proposals for their common refinement.

`Agent::ToolRunner#contiguous_runs` (`lib/lain/agent/tool_runner.rb`) builds the same shape and is
deliberately **not** adopted: its `chunk_while` runs over tool_use objects and their parallel-safety
answers, not over indices, so routing it through the value would be change for symmetry's sake. Its
`chunk_while` makes well-formedness structural anyway — the runs are *generated* rather than
proposed and checked, which is the same door-closing move `Algebra::Elementwise` makes when it
generates a whole-span map out of a per-message one.

The **refinement meet** is now built, and it is the pairwise *intersection* of the two operands'
ranges, not the union of their cut points. These partitions are partial — a gap is a stretch no range
claims — so a cut-point reading fills the gaps and proposes a collapse neither operand asked for,
which also costs the operation the two properties it exists for: meeting with the uncut partition
stops answering the other operand, and the result stops refining its own operands. Under the
refinement order `#refines?` names, the intersection is the greatest lower bound. The class declares
`meet_semilattice on: :meet, bottom: "the empty partition, per span"`, and the law sweep proves it
over an **exhaustive** population: all 34 partial interval partitions of `0..3`, with the bottom, the
uncut span and two gapped partitions placed last so the battery's witnesses are the four that bend
the laws hardest (`AlgebraGenerators::Partitions` in `spec/support/algebra_generators.rb`).

`Compaction::Strategy::Composed` (`elide | summarize`) is the consumer that made the extraction pay:
two strategies compose only over **disjoint** stretches, which is exactly "their meet is empty", and
an overlap refuses naming both owners and the indices they both claimed
(`spec/lain/compaction/strategy/composed_spec.rb`).

### Idempotence

> An operation that can be applied multiple times without changing the result beyond the first
> application. ([Wikipedia](https://en.wikipedia.org/wiki/Idempotence))

One of the 3 laws checked by `spec/support/shared_examples/meet_semilattice.rb`, alongside
commutativity and associativity. `timeline.meet(timeline)` must return the same timeline.

### Meet-semilattice

> A partially ordered set in which any 2 elements have a greatest lower bound, called their meet.
> ([Wikipedia](https://en.wikipedia.org/wiki/Semilattice))

`Timeline#dominator_meet` is a genuine meet-semilattice, because a node's dominators are totally
ordered and so the deepest common dominator is unique. `Timeline#meet` over render edges is one too.
`Timeline#causal_meets` is deliberately **not**: the causal DAG admits no unique greatest lower
bound, so it returns the set of maximal common ancestors instead of a single element, the way
`git merge-base` does.

Knowing which of the 3 you are holding matters, because only the semilattice ones obey the laws that
`meet_semilattice.rb` checks.

`Lain::IntervalPartition#meet` is the third **declared** instance and the only one outside
`Timeline`: the common refinement of two partitions of one span, greatest under the refinement order
`#refines?` names (see [interval partition](#interval-partition)). Its bottom is recorded as prose
rather than as a value, exactly as `Timeline`'s two are — a partition carries its span, so "the empty
partition" is a different value for every span, which makes the bottom a fact about the structure
rather than a member of it.

### Regular type

> A type whose equality, copying, and assignment behave consistently with one another, so that
> copies are indistinguishable and equal values stay equal. From Stepanov's *Elements of Programming*.

`spec/support/shared_examples/regular.rb` holds lain to this for its value objects. It is why
`Timeline#==` is defined as naming the same head digest, and why `Event` values are deeply frozen.
The mechanical statement of "no reachable mutable state" is `Ractor.shareable?(event)` staying
`true`, and there is a spec for it.

## Graphs and hashing

### Directed acyclic graph (DAG)

> A directed graph with no directed cycles.
> ([Wikipedia](https://en.wikipedia.org/wiki/Directed_acyclic_graph))

The conversation history is one. Acyclicity is not enforced by a check, it falls out of content
addressing: an event's digest covers its parent's digest, so an event can only ever name digests
that already existed. That is also why the dominator algorithm below needs only 1 topological pass.

### Merkle tree

> A tree in which every leaf is labelled with the hash of a data block, and every non-leaf node is
> labelled with the hash of its children's labels.
> ([Wikipedia](https://en.wikipedia.org/wiki/Merkle_tree))

`Event` plus `Store` plus `Timeline` form a Merkle DAG, the generalization of this to multiple
parents. Comparing 2 histories is comparing 2 digests, and branches automatically share storage for
their common prefix. This is due to directionality of the edges: each node
points further back in history.

**Note:** It is persistent, append-only DAG; not copy-on-write, and the difference is worth keeping straight. Copy-on-write
is a way of *simulating* immutability over a structure that really is mutable: there is one logical
object, and a write copies the nodes it touches, in a CoW B-tree every node on the path up to the root,
so existing readers keep seeing the old version. Here nothing is copied because nothing is ever
overwritten. `Store#put` is `||=` over a digest key, so storing the same event twice is a no-op;
`Timeline#commit` leaves the receiver alone and returns a new Timeline naming a new event whose parent
is the old head; `Timeline#fork` is literally `self`, because a frozen value nobody can write to needs
no copy to be safe to share. Ancestors are shared by naming the same digests, not by lazy copying, and
growth happens at the head rather than by rebuilding a path to a root. See
[persistent data structure](#persistent-data-structure-structural-sharing): the place lain would
genuinely be copy-on-write is the latent HAMT binding, since a persistent map does path-copy its spine
on update.

### Content-addressable storage

> Storing information so it can be retrieved based on its content rather than its name or location.
> ([Wikipedia](https://en.wikipedia.org/wiki/Content-addressable_storage))

`Store` is an append-only map from digest to event. The digest is a derived name, so equal content
has equal names and deduplication needs no special-casing. It is also what makes token accounting
correct: aggregating over the set of unique reachable digests cannot double-count a shared prefix,
where naive summation along a branched timeline would.

### BLAKE3

> A cryptographic hash function that is faster than MD5, SHA-1, SHA-2, SHA-3, and BLAKE2, and is
> internally a Merkle tree, which is what makes it parallelizable.
> ([BLAKE3](https://github.com/BLAKE3-team/BLAKE3))

`Canonical` serializes deterministically (sorted keys, stable array order) and hashes the result
with BLAKE3. Those bytes serve 2 invariants at once: event identity, and prompt-cache stability,
since an unstable serialization would break the cache prefix without changing meaning.

### Dominator, immediate dominator, dominator tree

> Node `d` dominates node `n` if every path from the entry node to `n` passes through `d`. The
> immediate dominator is the unique strict dominator closest to `n`, and the dominator tree links
> each node to its immediate dominator.
> ([Wikipedia](https://en.wikipedia.org/wiki/Dominator_(graph_theory)))

This is the structure behind `Timeline#dominator_meet`, the checkpoint primitive. The deepest common
dominator of 2 heads is the latest event every path to both must pass through, which makes it the
latest point no in-flight branch can bypass, and therefore the safe place to synchronize or compact.

`Timeline::Dominators::Tree` implements Cooper, Harvey, and Kennedy's algorithm: immediate dominators
by intersect-walks over a topological rank, after which any meet is a nearest-common-ancestor query.
Their iterative worklist collapses to a single sweep here because the union graph is acyclic.
([A Simple, Fast Dominance Algorithm](https://www.cs.tufts.edu/~nr/cs257/archive/keith-cooper/dom14.pdf))

### Topological order

> A linear ordering of a directed acyclic graph's vertices such that every edge points forward in the
> ordering. ([Wikipedia](https://en.wikipedia.org/wiki/Topological_sorting))

`Timeline::Dominators::Tree` ranks nodes this way (via Kahn's algorithm from a virtual root) so that
every predecessor is processed before its successors. Any topological rank serves, because an
immediate dominator is always a proper ancestor and so always has a strictly smaller rank.

## Data structures

### Persistent data structure, structural sharing

> A data structure that preserves its previous version when modified, so operations yield new
> versions rather than updating in place. Versions share the unchanged parts of their representation
> rather than copying them.
> ([Wikipedia](https://en.wikipedia.org/wiki/Persistent_data_structure))

The argument for binding Rust at all. Ruby's `Hash#dup` is O(n), so a speculative branch that
snapshots state pays a full copy, where a persistent map forks in O(1) with the untouched structure
shared between versions. That asymptotic gap is what earns an FFI boundary. Speed alone does not,
which is why the Timeline ships as pure Ruby first behind the same interface.

### HAMT (hash array mapped trie)

> A trie indexed by successive slices of a key's hash, giving near-constant-time lookup and insert
> with cheap structural sharing between versions.
> ([Ideal Hash Trees, Bagwell](https://lampwww.epfl.ch/papers/idealhashtrees.pdf))

The concrete persistent map lain would bind (`im` or `rpds`) once speculative branching needs to
snapshot the store. Latent today: the current O(1) `fork` comes from the `(head_digest, store)`
handle plus content addressing, not from a HAMT.

### BM25, recall@k

> BM25 is a probabilistic ranking function scoring a document against a query by term frequency,
> inverse document frequency, and document length. Recall@k is the fraction of the relevant
> documents that appear in the top k results.
> ([The Probabilistic Relevance Framework: BM25 and Beyond](https://www.staff.city.ac.uk/~sbrp622/papers/foundations_bm25_review.pdf))

`Lain::Ext::Bm25` wraps the `bm25` crate in-process, since it is pure in-memory data-structure work
with no I/O. It is deterministic on purpose (fxhash, no parallelism feature), and equal-score ties
break by build-batch insertion order. `lain bench sweep` scores retrieval by recall@k over a gold
corpus, and `Grader::Recall` is the grader behind it.

## Program structure

### Pure function

> A routine where identical inputs always produce identical outputs, with no side effects.
> ([Wikipedia](https://en.wikipedia.org/wiki/Pure_function))

`Context#render` is `(Timeline, Toolset, Workspace) -> Request` with no `Time.now`, no session ids,
and no `Dir.pwd`. Prompt caching imposes exactly the same constraint on the encoded request, so
purity and cache-hit-ability are 1 requirement rather than 2. It is also what makes dry replay
possible: re-rendering a recorded timeline under a different strategy is free and byte-diffable.

### Null object pattern

> An object implementing the expected interface with neutral behavior, so callers need no nil checks.
> ([Wikipedia](https://en.wikipedia.org/wiki/Null_object_pattern))

`Sink::Null` sends bytes nowhere, `Channel::Null` accepts and discards events, `Supervisor::Null` is
the wired-nothing default, and `Isolation::Null` leases the shared process environment. Each removes
a `if sink` guard that would otherwise be repeated at every call site. A nil check repeated 3 times
is an object waiting to be named.

### Chain of responsibility

> A behavioral pattern where each handler either processes a request or passes it to the next handler
> in the chain. ([Wikipedia](https://en.wikipedia.org/wiki/Chain-of-responsibility_pattern))

`Effect::Handler` composes by decoration: each holds an optional `inner` and delegates whatever it
does not handle. `Gate` is the clearest case, since it handles approval and delegates dispatch, and
holds no `Toolset` of its own so that gating and dispatch can never disagree about what a tool name
resolves to. `Middleware::Composed` is the same shape one layer up.

Read algebraically, a handler chain is a **left-biased** union of partial interpreters, with the base
`Handler` — which handles nothing and only delegates — as its identity. `#call` asks `handles?`
outermost-first, so 2 handlers claiming the same effect resolve to the outermost, silently. No chain
in the tree has that overlap today, at 3 effect kinds; naming the bias is what keeps a later reader
from discovering it by debugging. `planning/tool-use-algebra.md` B7 records the fix if the effect
vocabulary grows: a routing table keyed by kind, which is the same posture the `Algebra` registry
takes toward clobbering a claim.

### Anti-corruption layer

> A translation layer between subsystems that do not share semantics, so one subsystem's model does
> not leak into the other's design. From Evans, *Domain-Driven Design*.
> ([Microsoft Learn](https://learn.microsoft.com/en-us/azure/architecture/patterns/anti-corruption-layer))

`Lain::Request` and `Lain::Response` are provider-neutral, and every provider translates to and from
them. This is what makes cross-provider comparison honest rather than a comparison of 2 different
wire vocabularies. It is also why `ruby_llm`'s `Message` was rejected: it joins text blocks and keeps
only the first thinking signature, so the original content array cannot be recovered.

### Lens

> In functional programming, a lens is a first-class accessor into a structure: a getter and a setter
> that compose, so reading a nested field is a value rather than a path respelled at every call site.
> ([Profunctor optics, Pickering, Gibbons and Wu](https://arxiv.org/abs/1703.10857))

lain's are read-only and deliberately shallow, and the rule is stated in
`context/message_envelope.rb`'s header: **the string-keyed shape is the pipeline primitive, and a
value is a lens onto it**. Four classes are one pattern.

| Lens | Over | File |
|---|---|---|
| `Middleware::Env` | one middleware environment | `lib/lain/middleware/env.rb` |
| `Context::MessageEnvelope` | one canonical message hash | `lib/lain/context/message_envelope.rb` |
| `Response::ToolUse` | one `tool_use` block | `lib/lain/response/tool_use.rb` |
| `Tool::ResultBlock` | one `tool_result` block | `lib/lain/tool/result_block.rb` |

All four share the same core: an idempotent `.wrap`, a frozen instance, named readers that are
`fetch`es so an absent key raises where it is read, a delegated `#to_json`, and a `#to_h` that hands
back **the original object by identity** — which is what makes "no committed digest moves because a
caller wrapped" provable rather than hoped for. The 2 block lenses go further than the 2 whole-value
ones, because they sit closer to model-supplied bytes: `new` is private, so wrapping a lens cannot
nest one and `#to_h` cannot answer a lens where `Canonical` was promised a Hash; `.wrap` refuses a
non-Hash by class rather than letting it fail 3 different ways downstream; and a `KeyError` quotes a
length-capped `inspect`, since a `read_file`-shaped block would otherwise put a whole file into an
exception message and from there into the logs. Both keep a Hash-duck `#[]`/`#fetch` ramp for callers
still reading raw keys.

`Tool::ResultBlock.of` is the write side, and the sole builder of a string-keyed `tool_result` block
in `lib/`. Two correctness gates become constructor invariants there rather than lines in a
dispatcher: a block without a `tool_use_id` is unbuildable, and `is_error` is read off the
`Tool::Result` and never inferred from the shape of the content. Specs:
`spec/lain/response/tool_use_spec.rb` and `spec/lain/tool/result_block_spec.rb`, with
`spec/lain/agent/tool_runner_spec.rb` passing unchanged on either side of the migration.

The hash stays the identity-bearing form for a reason that was measured rather than assumed. A `Hash`
subclass survives construction, comparison, `Canonical.dump` and `Ractor.shareable?` — and then
`Canonical.normalize` rebuilds plain hashes, so the subclass is erased at the first commit; a `Data`
block cannot enter the `Store` at all, because `normalize` raises `UnsupportedType` on any non-Hash.
That door being shut in both directions is what makes a view the safe move.

`JSON` is the door it does not shut, so every lens delegates `#to_json`. Inherited, a lens serializes
as the `to_s` of its own object header: *valid* JSON carrying a debug string, which the NDJSON
[Journal](#ndjson) accepts in silence where a raise would be caught, and `Tool::ResultBlock` sits one
hop from the Journal's `JSON.generate`.

Adoption is partial on purpose. `Context::DedupeToolCalls`, `Context::PurgeFailedInputs`,
`Grader::ToolCallIndex` and `Plan::Closure` read through the lenses. `Event::Projection` does not,
and its comment says why: 2 of the 3 `tool_result` blocks in its own spec fixtures carry no
`is_error`, because a causal walk has never needed to ask, so a `fetch` reader would raise on the
project's own test data. The `fetch` readers are sound exactly where `ResultBlock.of` built the
block — blocks a projection *observes* were not built here.

### Object capability, attenuation

> A security model where holding an unforgeable reference to an object *is* the authorization to use
> it. Attenuation is deriving a weaker reference from a stronger one.
> ([Wikipedia](https://en.wikipedia.org/wiki/Object-capability_model))

Tools are capabilities, not permissions. A subagent holds what it was handed, attenuated at
construction with `toolset.only(:read_file, :grep)`. There is no permission layer to consult, so the
answer to "what can this subagent do" is 1 line of code you can read rather than a policy you have
to audit. `Role` packages an attenuation with a prompt slot and a spawn posture.

Attenuation is also a registered structure (`lib/lain/algebra/attenuation.rb`), declared on `Toolset`
as `attenuation on: :only, dual: :except`. The dual rides on one claim instead of being a second
declaration, because `except(x)` *is* `only(names - x)` and that equation is one of the laws; a
typo'd `dual:` is refused at load by the same `answers?` check the operation gets. 7 laws run from
`spec/support/shared_examples/attenuation.rb`: idempotence, composition inside the request, duality,
identity, monotonicity, and 2 **raises** — chaining `except` over the same names, and attenuating
outside the previous request. The partiality is the structure, so the raises are first-class laws
rather than edge cases; without them the operation would look total and the no-join reading would
rest on nothing.

**Monotonicity is stated against the request, not against the receiver**, and that is where the
security value is. Bounding a result by the receiver's names certifies nearly nothing, since `only`
fetches out of the receiver's own index and can fail only by inventing a tool. The law is
`observed(only(s, r)) ⊆ r`, probed with the **dropped** names as well as the kept ones. A `Toolset`
honest in `#names`, `#each`, `#to_schema` and `#digest` and lying in `#include?` and `#fetch` — the
2 messages `Effect::Handler::Live` authorizes and dispatches with — passed every other law while a
dropped tool executed end to end. `spec/lain/toolset_spec.rb` holds that set and runs it through the
real handler; the escape is now a spec. The rendered schema's names are inside `observed`, so a
dropped capability cannot come back through `#to_schema` either; the stronger reading of that —
attenuating then rendering equals rendering then filtering, entry for entry — is not pinned.

There is deliberately **no join**, and no `not_a_join_semilattice` refutation either, since a
structure with no positive declarer anywhere fails the registry's own "named consumer" bar. A join
would let a holder recover a capability it had dropped. Union exists only at construction, below the
trust boundary, where `Tools::Subagent#child_union` assembles a child's set out of tools the parent
already holds. The claim is scoped to the **model-facing surface** — the rendered schema, plus that
`#include?`/`#fetch` pair — and is not a claim about the Ruby object graph:
`only(:subagent).fetch("subagent").attenuates_from` hands back the whole un-attenuated union, and a
spec pins both halves so neither reading drifts.

The laws needed an equality, and `Toolset`'s is the canonical schema bytes: `#digest` is
`Canonical.digest(to_schema)`, computed eagerly in `#initialize` because the object freezes itself on
the next line. It is *schema* equality and not behavioral equality — 2 tools with identical schemas
and completely different `#perform` bodies compare equal — which is exactly the equality prompt
caching already lives by. The guard is `instance_of?` where `ContentAddressed` and
`Capability::DegradedSet` write `is_a?`; the divergence is on purpose (`is_a?` plus a class-embedding
`hash` is an `==`/`hash` contract violation waiting for the first subclass) and converging the other
two is owed.

One reading the postures break: **under `:handler_union` the rendered schema does not determine the
capability set.** Two children with different `only` sets render byte-identical tools blocks, which
is the point, since sibling cache sharing is what CE-4 measures, and
`Subagent::RefusingHandler` is what refuses a disallowed call, journaling a `"refused"` record. Under
`:schema` the name is simply absent from the rendered tools and `Toolset#fetch` raises with nothing
journaled. That is the *only* designed divergence:
`spec/lain/tools/subagent_posture_equivalence_spec.rb` pins the 2 postures as extensionally equal
over every allowed call.

### Total function

> A function defined for every input in its domain.
> ([Wikipedia](https://en.wikipedia.org/wiki/Partial_function))

The agent is a `state_machines` machine whose states make `stop_reason` handling total: refusals,
token exhaustion, paused turns, and context-window-exceeded are transitions rather than branches
someone might forget to write. The provider enum is non-exhaustive, so there is always an `else`.
`docs/agent-state-machine.md` is generated from the machine by a spec that fails the build on drift.

## Concurrency

### Fiber, thread, Ractor, GVL

> A fiber is a cooperatively scheduled unit of execution, yielding control at explicit suspension
> points. Ruby's Global VM Lock (GVL) permits only 1 thread to execute Ruby code at a time. A Ractor
> is an isolated execution context that can run truly in parallel, at the cost of only being able to
> share deeply immutable objects.

lain's concurrency posture is `async` fibers, and `Supervisor` owns the reactor task that outlives
any single `Agent#ask`, because a `mode: :actor` subagent spawns its fiber on whatever task is
current at launch. `Ractor.shareable?` doubles as the mechanical test that a value object has no
reachable mutable state. Driving an async runtime from inside an FFI call while holding the GVL is
the footgun that keeps `ext/lain` pure and synchronous. The full argument is in
[`concurrency.md`](concurrency.md).

## Formats and protocols

### NDJSON

> Newline-delimited JSON: one JSON value per line, for streaming.
> ([Specification](https://github.com/ndjson/ndjson-spec))

The `Journal` format, and the reason for lain's output discipline. One stray `puts` interleaved into
the stream makes `JSON.parse` fail on that line and corrupts the experiment record, so
`spec/output_discipline_spec.rb` parses the AST of every file in `lib/` and fails on
`puts`/`print`/`warn`/`$stdout`/`$stderr` outside the frontend. The Rust side denies
`clippy::print_stdout` and `clippy::print_stderr` at the crate root for the same reason.

### Write-ahead log (WAL)

> Recording a change to a durable log before applying it, so a crash can be recovered from the log.
> ([Wikipedia](https://en.wikipedia.org/wiki/Write-ahead_logging))

`Provider::ResponseWal` frames each round trip's raw wire bytes between an RS-delimited header and
terminator. If the process dies mid-turn, `SessionRecord::Salvage` re-parses exactly what the
provider sent, so a response you already paid for is not lost. `Paths.wal_for` derives the `.wal`
path from the session file, so writer and reader cannot name different files.

### MessagePack-RPC

> RPC over MessagePack, a binary serialization format that is more compact and faster to parse than
> JSON. ([MessagePack](https://msgpack.org/))

The transport for both out-of-process boundaries, which is why they look symmetric in the topology
diagram. `Frontend::Neovim` injects its whole runtime into a bare `nvim --listen` over it, and
`crates/lain-core` speaks it over a Unix socket. `Core::Client` runs 1 reader-loop fiber demuxing an
`msgid -> Promise` map, because completions arrive out of order.

### CloudEvents

> A CNCF specification for describing event data in a common envelope across systems.
> ([cloudevents.io](https://cloudevents.io/))

`Lain::Event` is shaped after it, with a closed `KINDS` set of `turn spawn message snapshot`. The
closed set is the point: an unknown kind fails loudly rather than being silently ignored.

## Method

### Property-based testing

> Testing that a property holds across many generated inputs, rather than asserting an output for
> specific inputs.

lain states its laws as RSpec shared example groups and runs them against every implementation:
`monoid.rb`, `meet_semilattice.rb`, `elementwise.rb`, `pure.rb`, `attenuation.rb`,
`monoid_homomorphism.rb`, `regular.rb`, `store_laws.rb`, `canonical_laws.rb`, `memory_index_laws.rb`,
and `provider_parity.rb`. This is also the acceptance test for any Rust port. A Rust `Timeline` has to
pass the same unchanged law suites as the Ruby one, which is how a port is known to be a swap rather
than a rewrite.

`monoid_homomorphism.rb` is the first group whose **negative** form is asserted too. It ships two
readings of one law set from one object — "a monoid homomorphism" and "not a monoid homomorphism" —
because two transcriptions of a law drift, and a drifted negative stops recording anything while
staying green. The negative exists for maintenance: non-compositionality is *intended* for a
model-backed collapse, and without an example saying so a later reader tidies it toward a shape it
cannot have. Its failure message names the witness pair, so a negative that has quietly become true
says which spans stopped distinguishing it.

The same posture runs one level up. `Lain::Algebra` records structures as declarations in `lib/`,
beside the operations they are about, and `spec/algebra_laws_spec.rb` sweeps that registry rather
than a hand-kept list: a declaration with no generator fails, a generator for a claim nobody makes
fails, and a *refutation* is confirmed only by a law that genuinely fails — one that raises instead
proves nothing and fails the sweep.

The registry **seals** once `lib/lain.rb` has loaded every unit, so a claim is something a class body
makes and never something a running process does: any declaration verb against the global registry
afterwards raises `Algebra::Sealed`, and `sealed?` *is* `frozen?` so the two cannot come to disagree.
Specs go on declaring into injected registries exactly as before. The latch sits on the verbs and not
only on `Registry#declare`, which is not belt and braces: `Algebra::Elementwise` generates its
whole-span method *before* it files its claim, so a registry-only latch would refuse the declaration,
file nothing, and leave a working generated method on the class — silent past the raise.

### CRDT, causal stability

> A conflict-free replicated data type merges concurrent updates without coordination. Causal
> stability is knowing that no further events can arrive before a given point.
> ([crdt.tech](https://crdt.tech/))

`Timeline#dominator_meet` inherits the standard causal-stability caveat: 1 quiet participant stalls
the frontier. A subagent branch that has spawned but not folded back pins the answer at or before its
spawn point however far the parent advances. This is documented rather than fixed, and the
operational mitigation is an actor's explicit stop.

### Distribution, variance

> A distribution describes how a metric's values are spread across repeated runs. Variance measures
> that spread.

`Compare` folds n runs into a per-metric distribution and raises on fewer than 2, with the message
"one run is not a distribution". A single A/B tells you nothing about whether an observed difference
is the tactic or the noise, which is why the bench reports distributions and `lain bench variance`
exists at all. Score is only reportable when every run in the comparison was graded.
