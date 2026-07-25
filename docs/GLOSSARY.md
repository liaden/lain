# Glossary

The math and CS vocabulary that [`README.md`](../README.md) and [`ARCHITECTURE.md`](../ARCHITECTURE.md)
use without defining. Each entry gives the general definition first, then what the concept is doing
in this codebase specifically.

## Algebra and order theory

### Monoid

> A set with an associative binary operation and an identity element.
> ([Wikipedia](https://en.wikipedia.org/wiki/Monoid))

Three things in lain are monoids, and each one is property-tested against the same shared example group
in `spec/support/shared_examples/monoid.rb`. `Middleware` composes with `Composable#>>`, and
`Middleware::Identity` is the pass-through that leaves a stack unchanged. `Usage` adds token counts
and is additionally commutative, so the order you fold a session's turns in cannot change the total.
The `Context` combinator chain composes with the same `>>`.

The laws matter operationally. If `Context` composition were not associative, the prompt you get
would depend on how you bracketed the combinators, which is the class of bug that ordinary
example-based tests miss.

### Free monoid

> The monoid whose elements are all finite sequences of elements from a set, with concatenation as
> the operation. ([Wikipedia](https://en.wikipedia.org/wiki/Free_monoid))

Because `Context` composition is associative, a strategy is determined by the *sequence* of
combinators and not by how they are bracketed. The space of strategies is therefore the free monoid
on the combinator set, which is what makes it enumerable: the bench can sweep it instead of running
a hand-written menu of named strategies.

### Endomorphism

> A homomorphism from a mathematical object to itself.
> ([Wikipedia](https://en.wikipedia.org/wiki/Endomorphism))

Every `Context` combinator maps a message list to a message list. Prune, Compact, CacheBreakpoints,
Reminder, and the rest all share that shape, which is what lets them compose in any order and form
the monoid above. A combinator that returned something other than a message list would break the
composition.

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

### Regular type

> A type whose equality, copying, and assignment behave consistently with one another, so that
> copies are indistinguishable and equal values stay equal. From Stepanov's *Elements of Programming*.

`spec/support/shared_examples/regular.rb` holds lain to this for its value objects. It is why
`Timeline#==` is defined as naming the same head digest, and why `Turn`/`Event` values are deeply
frozen. The mechanical statement of "no reachable mutable state" is `Ractor.shareable?(event)`
staying `true`, and there is a spec for it.

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

### Anti-corruption layer

> A translation layer between subsystems that do not share semantics, so one subsystem's model does
> not leak into the other's design. From Evans, *Domain-Driven Design*.
> ([Microsoft Learn](https://learn.microsoft.com/en-us/azure/architecture/patterns/anti-corruption-layer))

`Lain::Request` and `Lain::Response` are provider-neutral, and every provider translates to and from
them. This is what makes cross-provider comparison honest rather than a comparison of 2 different
wire vocabularies. It is also why `ruby_llm`'s `Message` was rejected: it joins text blocks and keeps
only the first thinking signature, so the original content array cannot be recovered.

### Object capability, attenuation

> A security model where holding an unforgeable reference to an object *is* the authorization to use
> it. Attenuation is deriving a weaker reference from a stronger one.
> ([Wikipedia](https://en.wikipedia.org/wiki/Object-capability_model))

Tools are capabilities, not permissions. A subagent holds what it was handed, attenuated at
construction with `toolset.only(:read_file, :grep)`. There is no permission layer to consult, so the
answer to "what can this subagent do" is 1 line of code you can read rather than a policy you have
to audit. `Role` packages an attenuation with a prompt slot and a spawn posture.

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
`monoid.rb`, `meet_semilattice.rb`, `regular.rb`, `store_laws.rb`, `canonical_laws.rb`,
`memory_index_laws.rb`, and `provider_parity.rb`. This is also the acceptance test for any Rust port.
A Rust `Timeline` has to pass the same unchanged law suites as the Ruby one, which is how a port is
known to be a swap rather than a rewrite.

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
