# Which capabilities earn a Rust binding

The placement rule and the crate layout live in `ARCHITECTURE.md` ("`ext/lain` vs
`crates/lain-core`"). This file is the *admission test*: what has to be true before any work
moves from Ruby into Rust at all. `CLAUDE.md` keeps the one-line rule; read this before
proposing a binding, and read `ext/lain/CLAUDE.md` before writing the code.

**Rust is here for its data model and for capabilities Ruby has no good answer to, not for
speed.** Ownership, cheap immutability, richer structures than Ruby's `Hash`/`Array`, and mature
crates with no Ruby equivalent are the reasons; a benchmark is how we *check* the reason, never
the reason itself. See `ext/lain/CLAUDE.md` before writing any Rust, and survey lib.rs/crates.io
before hand-rolling anything a crate already does well.

The placement rule is unchanged and is the one that actually binds: **anything async, I/O-bound,
or isolation-relevant lives out of process (`crates/lain-core`, msgpack-RPC over a Unix socket);
in-process work (`ext/lain`, magnus) must be pure, synchronous, and must not own the terminal.**
Driving an async runtime from inside an FFI call while holding the GVL is a known footgun, and an
"in-process sandbox" is not a sandbox. A crate that reaches for `isatty` or `NO_COLOR` owns the
terminal and fails this test — Ruby owns the stream, so colour arrives as a resolved argument.

Before binding, all five must hold. If any fails, keep it in Ruby.

1. **It is pure, synchronous work** — a data structure, a parser, a matcher — not IO, async, or
   confinement. Data structures are the original case, not the only one.
2. **Ruby's object model makes it asymptotically worse.** A persistent map with structural
   sharing forks in O(1); `Hash#dup` is O(n). That gap is the argument. "Rust is faster" is not.
3. **It is hot per-turn**, not per-session. Per-session work is never worth a boundary.
4. **The boundary is crossed in batches, not per element.** Conversion cost dominates almost
   every naive binding; a per-node FFI call in a DAG walk loses to plain Ruby. One walk is the
   exception: the block form of `Ext::Timeline#ancestors` crosses per node because its callers
   stop early, and its cursor lives in `Lain::Ext::Timeline::Walk`, an object Ruby's collector
   owns. `ext/lain/CLAUDE.md` says what a second exception would need.
5. **It is held to a frozen corpus and a mutation gate.** Until 2026-10-20 this rule read: "where
   both implementations exist the `Regular` / `MeetSemilattice` property tests must pass unchanged
   against both. That is how we know a port is correct, and it is why the Ruby version is not
   deleted." It was reversed when the Ruby `Event`, `Store` and `Timeline` were deleted, because
   "a differential test proves agreement, not correctness"
   (`planning/specs/simplify-13-rust-port.md`, 2026-09-12). A port now needs no second
   implementation. It needs the laws stated natively as `proptest` properties under the shared
   group's law names, the shared groups passing unchanged against the binding in
   `spec/lain/rust/*`, the old implementation's answers frozen first as a conformance corpus
   (`ext/lain/corpus/`, digests in `MANIFEST.json`, read by `cargo test` and by
   `spec/conformance_corpus_spec.rb`), and a `cargo-mutants` sweep whose killed, unviable and
   missed counts equal `ext/lain/mutants-baseline.txt` (`bundle exec rake rust:mutants`).
   Dominance and causal ancestry have lived only in Rust since 2026-09-14, by ruling: dominance
   is held to the shared law group, and both are held to fixtures whose expected answers are written down, plus a check
   read off the order's definition, which is all causal ancestry has, its Rust type implementing
   `MaximalLowerBounds` and never `MeetSemilattice`.

Structures that plausibly qualify, and what they buy:

| Structure | Crate | Why here |
|---|---|---|
| Persistent map / vector (HAMT, RRB) | `im` / `rpds` | Structural sharing *between versions* is what will make speculative `fork` cheap without polluting the shared Store. **Latent today** — the current O(1) `fork` comes from the handle + content-addressing, not the HAMT; the binding earns rule #2 once speculative branching snapshots the map (see `ext/lain/Cargo.toml`). |
| Content-addressed hashing | `blake3` | `Canonical` bytes → digest. One hash, two invariants. |
| Insertion-ordered map | `indexmap` | Deterministic iteration is exactly `Canonical.dump`'s sorted-key stability. |
| Interned digests | `lasso` | Digests are short, repeated, and compared constantly; interning turns comparison into an integer test. |
| Roaring bitmap | `roaring` | Usage must aggregate over **unique reachable digests** — a set problem. Naive summing over a branched Timeline double-counts the shared prefix. |
| Causal DAG | `petgraph` | `meet`, `diverge_at`, and `spawned_from` lineage are graph queries. |
| In-memory BM25 | `bm25` (crate) | **Shipped** (`Lain::Ext::Bm25`): pure in-memory data-structure work, so it lives in-process — unlike `tantivy`, which is disk-backed/I/O-shaped and stays out of process. Deterministic (fxhash, no parallelism feature); equal-score ties break by build-batch insertion order. |
| Vector / graph index | `tantivy`, `usearch`, `petgraph` | Memory retrieval (M6) — these are I/O-shaped, so they live **out** of process. |

> ⚠️ **A magnus-wrapped object is not `Ractor.shareable?` for free.** Deep immutability is spec'd
> mechanically, and `Ractor.shareable?(event)` must stay `true`. A Rust-backed `TypedData` object
> breaks that spec unless shareability is established deliberately, as `Ext::Event` establishes it
> with `frozen_shareable`. Treat the spec as the acceptance test for a port, not as an obstacle to it.
