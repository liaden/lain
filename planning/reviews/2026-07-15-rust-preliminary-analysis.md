# Preliminary analysis: `ext/lain` through the 2026-07-14 review themes

Analysis only — nothing fixed here. The lens is Joel's review themes as settled by the
code-review/Ollama/test-infra plan (equality convention, loud failure, validate-then-freeze,
`to_s`/`inspect` split, primitive obsession, thread-safety of shared state, WHY comments,
iterator idiom), translated into Rust: `PartialEq`/`Eq`/`Hash` agreement, `Result` vs silent
fallback, newtypes vs stringly-typed boundaries, `Display` vs `Debug`, lock discipline.

Surface: `ext/lain` only (2,196 lines across `lib.rs`, `canonical.rs`, `turn.rs`, `dag.rs`,
`bm25.rs`, `Cargo.toml`). `crates/lain-core` does not exist yet.

Overall: this crate is in very good shape — the shareability discipline, the pure/FFI test
split, batched boundary crossings, and the WHY-comment density are all exactly what the root
CLAUDE.md asks for. The findings below are one real divergence, a small family of
loud-failure inversions in "unreachable" arms, and R.*-shaped deferrals.

## Findings — fix-worthy

- **F.1 — `dag::ancestor_arcs` silently truncates a corrupt chain; Ruby raises.**
  (`dag.rs:23-33`; loud-failure theme, and the port-parity rule.) A dangling parent digest
  ends the walk with no error — the comment says it "only guards against a corrupt chain",
  but that is precisely the case that must be LOUD. Ruby's walk goes through `Store#fetch`
  (`timeline.rb:85`), which raises `Store::MissingObject` on the same corruption, so the two
  implementations genuinely diverge — and the `Regular`/`MeetSemilattice` property tests
  cannot catch it because they only generate valid chains. Worse than the missing error:
  `meet` over a truncated chain can return a **wrong answer** (`None`, or a shallower
  common ancestor) instead of failing — a silently-wrong semilattice on a corrupt store,
  which `diverge_at`'s cache-break localization would then trust. Fix shape: the walk
  returns `Result<Vec<Arc<TurnData>>, DanglingDigest>`; the FFI layer maps it to
  `Store::MissingObject` like `fetch` does. Touches `ancestors`/`to_a`/`length`/`include?`/
  `ancestor_digests`/`meet`/`ancestor_of?`/`diverge_at`; a spec on the Ruby side pinning
  both implementations against a hand-corrupted store closes the gap the property tests
  leave.

- **F.2 — `num_to_ruby` falls back to `NaN`/`nil` in its "unreachable" arms.**
  (`lib.rs:442-453`; loud-failure theme — the same shape as the rejected
  `rescue NoMethodError`.) A `Canon::Num` whose text does not parse silently becomes
  `Float::NAN`; a bignum that fails `to_i` silently becomes `nil` inside reconstructed
  content. The comment says the fallbacks are unreachable for reader-produced text — then
  they should be loud, not lossy: return `Result` and raise, exactly the argument the T5
  WHY comment makes about swallowing errors inside a broken collaborator.

- **F.3 — `init`'s `Lain::Error` lookup falls back to `StandardError` silently.**
  (`lib.rs:1068-1072`.) The comment states `Lain::Error` "is required before this extension
  loads" — the manifest guarantees it. So the `unwrap_or_else` arm can only fire when that
  contract is broken, and when it fires, every `Lain::Ext` error class silently re-parents
  to `StandardError` — a rescue-surface change with no signal. Let the lookup failure
  propagate (init fails loudly on a load-order regression), or write the WHY that justifies
  tolerating it.

- **F.4 — `Timeline#fork` returns `self` with no WHY at the site.** (`lib.rs:774-776`;
  WHY-comment theme.) It is the single most surprising method in the file — "fork" that
  returns the receiver — and it is correct only because handles are immutable and diverge
  at `commit`. The section banner explains the handle design; the method itself says
  nothing. One sentence at the site.

- **F.5 — `rewind` re-locks the store once per step.** (`lib.rs:812-815`.) `dag.rs`'s own
  doc sells "the whole chain in a single locked read"; `rewind` takes the mutex inside the
  loop instead. Correct today (append-only map, each read consistent) but inconsistent with
  the crate's stated lock discipline and trivially fixable: bind `store.locked()` once
  before the loop.

## Findings — R.*-shaped deferrals

- **F.6 — Digests are bare `String`s across every boundary.** (Primitive-obsession theme.)
  `read_optional_digest` accepts ANY string as a parent digest — garbage is hashed into the
  payload and becomes a dangling parent (feeding F.1); `parent_of(map, "blake3:absent")`
  compiles happily. A `Digest` newtype validating shape at the FFI boundary is the
  type-system version of validate-then-freeze, and it is where `lasso` interning (already
  in the root CLAUDE.md table) would later land. One card, both sides of the boundary.

- **F.7 — `role: String` + runtime check could be a two-variant enum.** (`turn.rs:14,74-80`;
  closed-vocabulary theme — the Rust analog of T8's case-over-closed-set WHY.) The runtime
  check is loud and its message matches the `Policy.for` voice, so this is taste, not a
  defect; an enum would just move the totality into the type system. Low priority.

- **F.8 — `Lain::Ext::Turn` and `Lain::Ext::Timeline` belong on R.4's list.** Both alias
  `inspect` to a debug-shaped `to_s` (`#<Lain::Ext::Turn …>`, `lib.rs:1093-1094,
  1127-1128`) — exactly the conflation R.4 catalogues for `Request`/`Turn`/`Toolset`/
  `Provider`/`Bm25`. Whatever card executes R.4 should sweep the ext too, under the same
  byte-risk caution (these strings may appear in error text).

## NITs

- `Canon` derives `PartialEq` but not `Eq` (`canonical.rs:29`) — `Num` is text, no floats
  anywhere in the enum, so `Eq` is free and `CanonError` already has it.
- The `unwrap_or(false)` on `qtrue`/`qfalse` `.equal()` checks (`lib.rs:258-260`) and
  `to_s`'s `unwrap_or(0)` length (`lib.rs:908-912`) are the same rescue-to-default family
  as F.2, in genuinely harmless positions (boolean identity checks cannot fail; display
  path). Note only for pattern-consistency if F.2 gets fixed.
- `include?`/`length` materialize the full `Vec<Arc<TurnData>>` to answer a scalar
  (`lib.rs:842-852`) — a walk without collecting answers both. Only matters if chains get
  long; the crossing is still batched.
- `ancestor_arcs`'s manual cursor loop could be `std::iter::successors` — the iterator
  idiom the Ruby side prefers via `Enumerator`. Taste; the loop is clear as written.

## Verified clean (no findings)

- **Equality convention**: `Turn` and `Timeline` implement `PartialEq`/`Eq`/`Hash` over the
  same key (digest, head) — agreement holds; Ruby-side `==`/`eql?`/`hash` route through
  `typed_data::IsEql`/`Hash`, whose same-class check is the `is_a?(self.class)` guard of
  Ruling 1. Rust `Timeline` equality (head-only) matches Ruby's exactly
  (`timeline.rb:133-140`). `Store` deliberately defines no `==` so cross-store checks fall
  back to object identity — WHY documented at `same_store`.
- **Ractor-shareability discipline**: `ShareProbe` canary retained with a real
  justification; `Turn`/`Bm25` are honestly `frozen_shareable` (no reachable Ruby object;
  the bm25 interior-mutability audit is pinned to the exact `=2.3.2` the manifest pins);
  `Timeline` marks its Store and is correctly NOT shareable, mirroring Ruby.
- **Output discipline**: crate-root `deny(print_stdout, print_stderr)`; the `dup(2)`
  invariant and the `write_all` override both carry the load-bearing WHYs and unit tests.
- **Thread safety**: single guard across check+insert in `Store::insert_arc`; poisoned-lock
  recovery in both `Store` and `SharedWriter` with the FFI-unwinding rationale written down.
- **Boundary batching**: every DAG walk crosses once with a built Array; bm25 builds and
  searches in single crossings; no per-node FFI anywhere.
- **Loud failure at the FFI edge**: named error classes (`InvalidRole`, `MissingObject`,
  `CrossStore`, `EmptyCorpus`, `DuplicateId`) looked up at raise time with `NameError`
  surfacing on lookup failure; `InvalidRole`'s message names the valid set in the
  `Policy.for` voice.
- **Test shape**: pure logic is magnus-free and covered (`canonical` byte-identity vectors,
  BLAKE3 official vectors including the multi-chunk boundary, semilattice laws, tokenizer
  determinism, tie-breaking, the dup-writer fd invariant); `Lain.hello` is not dead code —
  the journal-tracing seam spec drives it.
- **Cargo.toml**: no wildcards, `bm25` exact-pinned to match its audit, `rpds`'s latent
  structural-sharing status honestly documented rather than oversold.
