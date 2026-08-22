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
   every naive binding; a per-node FFI call in a DAG walk loses to plain Ruby.
5. **It survives the same tests.** `Timeline` ships as pure Ruby first, and the `Regular` /
   `MeetSemilattice` property tests must pass unchanged against **both** implementations. That
   is how we know a port is correct, and it is why the Ruby version is not deleted.

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
> mechanically, and `Ractor.shareable?(event)` must stay `true`. Porting `Event` or `Timeline` to a
> Rust-backed `TypedData` object will break that spec unless shareability is established
> deliberately. Treat the spec as the acceptance test for the port, not as an obstacle to it.
