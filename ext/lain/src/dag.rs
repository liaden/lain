//! Pure ancestry queries over a content-addressed store.
//!
//! The Store maps a digest to its [`EventData`]; walking render-parent pointers
//! through that map is all `ancestors`, `meet`, and `ancestor_of?` need. Every
//! walk here follows the SINGLE render edge -- the first-parent chain -- and is
//! unchanged by the envelope re-port: `causal_parents` never participates
//! (causal projections stay Ruby-only until a bench shows them hot). Keeping
//! these as plain functions over an `rpds` map -- no `magnus` -- is what lets
//! the structure below be proven without an embedded Ruby VM, and lets the FFI
//! layer perform each walk ENTIRELY in Rust, crossing the boundary once with a
//! batched result rather than once per node.
//!
//! **There is one walk, and it is an iterator.** Every function here folds over
//! the private `walk`, which pulls one node at a time; nothing builds a `Vec`
//! it does not hand back. That is what makes a bounded question cost a bounded
//! walk -- `includes`, `ancestor_of`, and `meet`'s find side stop AT the answer
//! rather than after the chain -- and it is the Rust half of the same change
//! `Lain::Timeline` took in Ruby, where `#ancestors` yields rather than
//! materializes (root `CLAUDE.md`, "Enumerable and Enumerator are the good
//! abstractions").
//!
//! # The structure, and exactly which laws are proven where
//!
//! **Structure:** the heads over one Store form a MEET-SEMILATTICE ordered by
//! render ancestry -- `a <= b` when a is an ancestor of b ([`ancestor_of`]).
//! **Operation:** [`meet`], the greatest common ancestor. **Bottom:** the empty
//! head, `None`, which is what makes `meet` total for two heads sharing no
//! history. That is the whole claim; this module implements no join, and there
//! is no dominator meet or causal meet here (those stay Ruby-only, and adding
//! them is a port decision under the root `CLAUDE.md`'s five rules, not a
//! documentation one).
//!
//! **Four laws, and no fifth:** idempotent, commutative, associative, and "a
//! meet sits below both operands". Each has a `#[test]` in this file's `tests`
//! module named for it, and the list is the same one
//! `spec/support/shared_examples/meet_semilattice.rb` asserts -- that file is
//! the authority on which laws exist, so the two layers cannot come to disagree
//! about what a law IS.
//!
//! **Two suites, two different claims.** `cargo test` proves the Rust
//! ALGORITHM here obeys those four laws, at a layer the Ruby suite cannot
//! reach. `spec/lain/rust/*` proves the Rust BINDING agrees with Ruby, by
//! running the shared groups unchanged, and it is the SOLE authority on that
//! cross-implementation claim -- no test in this file compares against a Ruby
//! value. Read one as "the algorithm is a meet-semilattice" and the other as
//! "the port is faithful"; neither substitutes for the other.

use crate::digest::Digest;
use crate::event::EventData;
use rpds::HashTrieMapSync;
use std::collections::HashSet;
use std::sync::Arc;

/// The content-addressed object map. A persistent HAMT, so a `fork` shares the
/// whole prefix and a shared prefix is stored once. Keyed by [`Digest`], not a
/// bare `String`, so a walk cannot be handed an arbitrary string as an address.
pub type StoreMap = HashTrieMapSync<Digest, Arc<EventData>>;

/// A walk referenced a digest that is not in the map. A well-formed Timeline
/// never dangles, so this is corruption, NOT the ordinary end of a chain --
/// reaching a root is `parent == None`, a valid stop this type never conflates
/// with an absent digest. The FFI layer turns it into `Store::MissingObject`.
///
/// Hand-rolled `Display`/`Error` (no `thiserror`) whose message is byte-equal to
/// Ruby `Store#fetch` (`lib/lain/store.rb`): `{:?}` escapes a plain digest, and
/// one containing a double-quote, exactly as Ruby's `String#inspect` does.
/// Out of scope for byte-parity: control characters AND Ruby's interpolation
/// guards (`#{`, `#@`, `#$`, which `String#inspect` escapes to `\#{` etc. and
/// `{:?}` leaves bare) -- the escape styles genuinely differ there; both
/// implementations still raise.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DanglingDigest(pub Digest);

impl std::fmt::Display for DanglingDigest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // `{:?}` on a `Digest` renders exactly as it did on the former `String`
        // field -- `Digest`'s hand-written `Debug` delegates to the inner
        // `String`'s -- so this message stays byte-equal to Ruby `Store#fetch`.
        write!(f, "no object {:?} in store", self.0)
    }
}

impl std::error::Error for DanglingDigest {}

/// The one walk. Yields the `Arc`-shared nodes from `head` up to the root, head
/// first, PULLED ONE AT A TIME -- every ancestry query below is a fold over
/// this iterator, and it is what lets the short-circuiting ones ([`includes`],
/// [`ancestor_of`], and `meet`'s find side) stop AT the answer instead of
/// materializing a `Vec<Arc<EventData>>` the length of the chain first.
///
/// Fallible per step: a digest the map does not hold yields
/// `Err(DanglingDigest)` and ends the walk (the cursor is already taken), so
/// the iterator fuses itself and no fold can step past corruption into an
/// answer computed over a truncated chain. Reaching a root -- `render_parent ==
/// None` -- is the other, ordinary stop, and the two stay distinct.
///
/// **The cursor BORROWS.** `render_parent` is an `Option<Digest>` living in a
/// node the map owns and the walk holds borrowed throughout, so stepping is a
/// pointer move: `cursor = turn.render_parent.as_ref()`. Cloning it instead
/// would allocate a `String` per node -- measured at 5000 allocations over a
/// 5000-node chain, against 0 for `length` and 12 for `ancestor_turns` as
/// written -- which would have left the per-node cost exactly where it was
/// while only the `Vec` went away. Both halves of "no materializing" are the
/// point. `'a` covers the map and the head together; that is ONE lifetime, and
/// an earlier revision's claim that borrowing here would need two was simply
/// wrong -- do not let it stop you.
///
/// Private on purpose: the FFI layer crosses the boundary once with a batched
/// answer (see the module doc), so it consumes the named functions below and
/// never the walk itself.
fn walk<'a>(
    map: &'a StoreMap,
    head: Option<&'a Digest>,
) -> impl Iterator<Item = Result<Arc<EventData>, DanglingDigest>> + 'a {
    let mut cursor = head;
    std::iter::from_fn(move || {
        let digest = cursor.take()?;
        match map.get(digest) {
            None => Some(Err(DanglingDigest(digest.clone()))),
            Some(turn) => {
                cursor = turn.render_parent.as_ref();
                Some(Ok(Arc::clone(turn)))
            }
        }
    })
}

/// The first digest on `head`'s chain that `wanted` accepts, or `None` when
/// none does. THE short-circuiting primitive, shared by [`includes`] (hence
/// [`ancestor_of`]) and by [`meet`]'s find side, so one implementation carries
/// the stopping rule and one test proves it. `find_map` pulls the walk only as
/// far as the first acceptance, so an answer one hop from the head costs one
/// node rather than the whole chain. A dangle reached BEFORE the answer still
/// raises: stopping early must never turn corruption into a quiet `None`.
fn find_ancestor(
    map: &StoreMap,
    head: Option<&Digest>,
    mut wanted: impl FnMut(&Digest) -> bool,
) -> Result<Option<Digest>, DanglingDigest> {
    walk(map, head)
        .find_map(|step| match step {
            Err(dangling) => Some(Err(dangling)),
            Ok(turn) => wanted(&turn.digest).then(|| Ok(turn.digest.clone())),
        })
        .transpose()
}

/// The `Arc`-shared nodes from `head` up to the root, head first. A digest that
/// is not in the map is a corrupt chain and returns `Err(DanglingDigest)` naming
/// it, rather than silently truncating the walk. One pass, so callers get the
/// whole chain in a single locked read. The `Vec` is deliberate: a caller
/// asking for every node has already said it wants them all, and `collect`
/// into a `Result` still stops the walk at the first dangle.
pub fn ancestor_turns(
    map: &StoreMap,
    head: Option<&Digest>,
) -> Result<Vec<Arc<EventData>>, DanglingDigest> {
    walk(map, head).collect()
}

/// The digests from `head` to the root, head first.
pub fn ancestor_digests(
    map: &StoreMap,
    head: Option<&Digest>,
) -> Result<Vec<Digest>, DanglingDigest> {
    walk(map, head)
        .map(|step| step.map(|turn| turn.digest.clone()))
        .collect()
}

/// How many nodes the chain from `head` holds -- Ruby `Timeline#length`. Folds
/// the count over the walk, so asking for a number never allocates a `Vec` of
/// every `Arc` on the chain to then throw away.
pub fn length(map: &StoreMap, head: Option<&Digest>) -> Result<usize, DanglingDigest> {
    walk(map, head).try_fold(0, |count, step| step.map(|_turn| count + 1))
}

/// Whether `needle` is on the chain from `head` -- Ruby `Timeline#include?`.
/// Stops at the hit (see [`find_ancestor`]), so membership near the head is
/// answered in a couple of node reads however long the chain behind it is.
pub fn includes(
    map: &StoreMap,
    head: Option<&Digest>,
    needle: &Digest,
) -> Result<bool, DanglingDigest> {
    Ok(find_ancestor(map, head, |digest| digest == needle)?.is_some())
}

/// The parent digest of `digest`. `Ok(None)` is a root (a valid stop); an absent
/// digest is `Err(DanglingDigest)` -- corruption, kept distinct from the root so
/// `rewind` can absorb past `None` yet still raise on a dangle. Used by `rewind`
/// to step back without materializing the whole chain.
pub fn parent_of(map: &StoreMap, digest: &Digest) -> Result<Option<Digest>, DanglingDigest> {
    map.get(digest)
        .map(|turn| turn.render_parent.clone())
        .ok_or_else(|| DanglingDigest(digest.clone()))
}

/// The greatest common ancestor digest of two heads, or `None` when they share
/// no history. Total over well-formed chains: two that never meet return `None`,
/// the bottom element. A dangle in either chain is `Err(DanglingDigest)` -- never
/// a wrong answer computed over a truncated chain. Walks `b` head-first and
/// returns the first digest also on `a`, matching `Timeline#meet` exactly.
///
/// This is the MEET of the ancestry meet-semilattice (see the module doc), and
/// it is **idempotent, commutative, and associative**, with `None` as the
/// bottom element -- laws, not incidental behaviour. Proven by `cargo test`
/// against this function, over every pair and triple of a generated forest
/// (`tests::meet_is_idempotent`, `meet_is_commutative`, `meet_is_associative`,
/// `meet_orders_below_both_operands`). That the Ruby-facing `Ext::Timeline#meet`
/// binding obeys the same four is proven separately, and only, by
/// `spec/lain/rust/timeline_spec.rb` running the shared group unchanged.
pub fn meet(
    map: &StoreMap,
    a_head: Option<&Digest>,
    b_head: Option<&Digest>,
) -> Result<Option<Digest>, DanglingDigest> {
    // The `a` side is the whole chain by necessity -- a membership test needs
    // its set built before the first question -- exactly as Ruby
    // `Timeline#meet` builds `mine`. Only the `b` side can stop early, and
    // [`find_ancestor`] is where it does.
    let mine: HashSet<Digest> = ancestor_digests(map, a_head)?.into_iter().collect();
    find_ancestor(map, b_head, |digest| mine.contains(digest))
}

/// Whether the Timeline headed at `ancestor` is an ancestor of the one headed at
/// `descendant`. The empty Timeline (`None`) is below everything; otherwise the
/// descendant's chain must include the ancestor's head -- and a dangle in that
/// chain raises rather than answering `false` over a truncated walk.
///
/// This is the ORDER (`a <= b`) the meet-semilattice is taken over, so it is
/// half of what "a meet sits below both operands" even means; `cargo test`'s
/// `tests::meet_orders_below_both_operands` proves [`meet`] against it, and
/// `spec/lain/rust/timeline_spec.rb` is what proves the binding agrees with
/// Ruby's `Timeline#ancestor_of?`.
pub fn ancestor_of(
    map: &StoreMap,
    ancestor: Option<&Digest>,
    descendant: Option<&Digest>,
) -> Result<bool, DanglingDigest> {
    match ancestor {
        None => Ok(true),
        Some(head) => includes(map, descendant, head),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::canonical::{Canon, build_object};
    use crate::event::Role;

    fn text(body: &str) -> Canon {
        Canon::Array(vec![Canon::Object(
            build_object(vec![("text".to_string(), Canon::Str(body.to_string()))]).unwrap(),
        )])
    }

    // A `Digest` from a literal -- the deliberate `Digest::from` the type change
    // forces where a corrupt/synthetic address is wanted (a bare `&str` no longer
    // stands in for a digest).
    fn digest(text: &str) -> Digest {
        Digest::from(text.to_string())
    }

    // Commit `body` onto `parent`, returning (new map, new head digest).
    fn commit(map: &StoreMap, parent: Option<&Digest>, body: &str) -> (StoreMap, Digest) {
        let turn = EventData::turn(
            Role::User,
            text(body),
            parent.cloned(),
            Canon::Object(vec![]),
            None,
            Vec::new(),
        );
        let digest = turn.digest.clone();
        (map.insert(digest.clone(), turn), digest)
    }

    // base(a -> b); left branches (l1 -> l2); right branches (r1).
    fn forest() -> (StoreMap, Digest, Digest, Digest) {
        let map = StoreMap::new_sync();
        let (map, a) = commit(&map, None, "a");
        let (map, b) = commit(&map, Some(&a), "b");
        let (map, l1) = commit(&map, Some(&b), "l1");
        let (map, left) = commit(&map, Some(&l1), "l2");
        let (map, right) = commit(&map, Some(&b), "r1");
        (map, b, left, right)
    }

    // The population the four laws run over: FOUR independent roots grown into
    // binary trees, plus `None`, the empty head -- 28 nodes, 29 heads. (Four,
    // not two: `frontier` is seeded with two `None`s and the first depth gives
    // each seed two children, so the first generation is already four roots.)
    // Deliberately wider than the hand-picked `forest()` shape above --
    // disjoint roots are what force a meet to bottom out at `None`, and the
    // bottom element is what makes the operation total. The laws then run over
    // EVERY pair and EVERY triple of these heads rather than a sample, because
    // an associativity bug hides exactly in the shape nobody thought to pick.
    // Deterministic: the same 29 heads every run, so a failure reproduces.
    //
    // Widening this is CUBIC in the head count -- associativity is exhaustive
    // over triples, so today's 29 heads are 24_389 of them (0.36s for the whole
    // suite). Another two levels of depth would be ~125 heads and ~1.9M
    // triples. Raise the loop bound only if you have checked what it costs.
    fn law_population() -> (StoreMap, Vec<Option<Digest>>) {
        let mut map = StoreMap::new_sync();
        let mut heads: Vec<Option<Digest>> = vec![None];
        let mut frontier: Vec<Option<Digest>> = vec![None, None];
        let mut label = 0;
        for _depth in 0..3 {
            let mut children = Vec::new();
            for parent in &frontier {
                for _branch in 0..2 {
                    label += 1;
                    let (grown, digest) = commit(&map, parent.as_ref(), &format!("n{label}"));
                    map = grown;
                    children.push(Some(digest.clone()));
                    heads.push(Some(digest));
                }
            }
            frontier = children;
        }
        (map, heads)
    }

    // A corrupt chain built the way a corrupt Store would be: a head node whose
    // parent digest was never inserted. Returns (map, head digest); the head is
    // present, its parent `blake3:absent` is not.
    fn corrupt() -> (StoreMap, Digest) {
        commit(
            &StoreMap::new_sync(),
            Some(&digest("blake3:absent")),
            "head",
        )
    }

    // A straight, well-formed chain of `length` nodes. Returns (map, head).
    fn chain(length: usize) -> (StoreMap, Digest) {
        let (map, digests) = grow(StoreMap::new_sync(), None, length);
        let head = digests[0].clone();
        (map, head)
    }

    // The same chain, but its deepest node's parent was never inserted -- so a
    // walk that runs off the end raises instead of stopping. That dangle is the
    // instrument the short-circuit tests read: an answer returned from ABOVE it
    // proves the walk never reached it. Returns the digests head-first, so a
    // test names a node by its distance from the head.
    fn dangling_chain(length: usize) -> (StoreMap, Vec<Digest>) {
        grow(StoreMap::new_sync(), Some(digest("blake3:absent")), length)
    }

    // `length` commits stacked on `parent`, returned head-first.
    fn grow(mut map: StoreMap, parent: Option<Digest>, length: usize) -> (StoreMap, Vec<Digest>) {
        let mut parent = parent;
        let mut digests = Vec::with_capacity(length);
        for step in 0..length {
            let (grown, node) = commit(&map, parent.as_ref(), &format!("n{step}"));
            map = grown;
            parent = Some(node.clone());
            digests.push(node);
        }
        digests.reverse();
        (map, digests)
    }

    #[test]
    fn walks_ancestors_head_first() {
        let map = StoreMap::new_sync();
        let (map, a) = commit(&map, None, "a");
        let (map, b) = commit(&map, Some(&a), "b");
        assert_eq!(
            ancestor_digests(&map, Some(&b)),
            Ok(vec![b.clone(), a.clone()])
        );
    }

    #[test]
    fn empty_head_has_no_ancestors() {
        assert_eq!(ancestor_digests(&StoreMap::new_sync(), None), Ok(vec![]));
    }

    #[test]
    fn meet_is_the_greatest_common_ancestor() {
        let (map, base, left, right) = forest();
        assert_eq!(meet(&map, Some(&left), Some(&right)), Ok(Some(base)));
    }

    // -------------------------------------------------------------------
    // The four semilattice laws.
    //
    // These are the SAME four the Ruby group asserts -- idempotent,
    // commutative, associative, and "a meet sits below both operands"
    // (`spec/support/shared_examples/meet_semilattice.rb`, which is the
    // authority on which laws exist; neither side asserts a law the other
    // does not). What they prove here is different from what they prove
    // there: this module proves the pure Rust ALGORITHM obeys them, at a
    // layer with no `magnus` and no Ruby VM. That the Rust BINDING agrees
    // with Ruby is a separate claim owned solely by `spec/lain/rust/*`,
    // which runs those shared groups unchanged -- no `cargo test` here
    // compares against a Ruby value.
    // -------------------------------------------------------------------

    #[test]
    fn meet_is_idempotent() {
        let (map, heads) = law_population();
        for a in &heads {
            assert_eq!(
                meet(&map, a.as_ref(), a.as_ref()),
                Ok(a.clone()),
                "idempotence failed for {a:?}"
            );
        }
    }

    #[test]
    fn meet_is_commutative() {
        let (map, heads) = law_population();
        for a in &heads {
            for b in &heads {
                assert_eq!(
                    meet(&map, a.as_ref(), b.as_ref()),
                    meet(&map, b.as_ref(), a.as_ref()),
                    "commutativity failed for {a:?} and {b:?}"
                );
            }
        }
    }

    #[test]
    fn meet_is_associative() {
        let (map, heads) = law_population();
        for a in &heads {
            for b in &heads {
                let ab = meet(&map, a.as_ref(), b.as_ref()).expect("the forest is well-formed");
                for c in &heads {
                    let bc = meet(&map, b.as_ref(), c.as_ref()).expect("the forest is well-formed");
                    assert_eq!(
                        meet(&map, ab.as_ref(), c.as_ref()),
                        meet(&map, a.as_ref(), bc.as_ref()),
                        "associativity failed for {a:?}, {b:?}, {c:?}"
                    );
                }
            }
        }
    }

    #[test]
    fn meet_orders_below_both_operands() {
        let (map, heads) = law_population();
        for a in &heads {
            for b in &heads {
                let m = meet(&map, a.as_ref(), b.as_ref()).expect("the forest is well-formed");
                assert_eq!(
                    ancestor_of(&map, m.as_ref(), a.as_ref()),
                    Ok(true),
                    "{m:?} is not below {a:?}"
                );
                assert_eq!(
                    ancestor_of(&map, m.as_ref(), b.as_ref()),
                    Ok(true),
                    "{m:?} is not below {b:?}"
                );
            }
        }
    }

    #[test]
    fn meet_is_none_when_no_shared_history() {
        let (map, _base, left, _right) = forest();
        let (map, other) = commit(&map, None, "unrelated");
        assert_eq!(meet(&map, Some(&left), Some(&other)), Ok(None));
    }

    #[test]
    fn ancestor_of_is_a_prefix_relation() {
        let (map, base, left, _right) = forest();
        assert_eq!(ancestor_of(&map, Some(&base), Some(&left)), Ok(true));
        assert_eq!(ancestor_of(&map, Some(&left), Some(&base)), Ok(false));
    }

    #[test]
    fn empty_is_below_everything() {
        let (map, _base, left, _right) = forest();
        assert_eq!(ancestor_of(&map, None, Some(&left)), Ok(true));
    }

    #[test]
    fn parent_of_steps_back_one_and_stops_at_the_root() {
        let map = StoreMap::new_sync();
        let (map, a) = commit(&map, None, "a");
        let (map, b) = commit(&map, Some(&a), "b");
        assert_eq!(parent_of(&map, &b), Ok(Some(a.clone())));
        assert_eq!(parent_of(&map, &a), Ok(None));
        // The bug this card fixes: an absent digest was conflated with a root.
        // It is now corruption, distinct from `Ok(None)`.
        assert_eq!(
            parent_of(&map, &digest("blake3:absent")),
            Err(DanglingDigest(digest("blake3:absent")))
        );
    }

    #[test]
    fn every_walk_reports_a_dangling_parent() {
        let (map, head) = corrupt();
        let dangling = DanglingDigest(digest("blake3:absent"));
        assert_eq!(ancestor_turns(&map, Some(&head)).unwrap_err(), dangling);
        assert_eq!(ancestor_digests(&map, Some(&head)), Err(dangling.clone()));
        assert_eq!(meet(&map, Some(&head), Some(&head)), Err(dangling.clone()));
        // A non-None ancestor forces the descendant chain to be walked; a `None`
        // ancestor short-circuits to `Ok(true)` and never touches the dangle.
        assert_eq!(
            ancestor_of(&map, Some(&digest("blake3:x")), Some(&head)),
            Err(dangling.clone())
        );
        assert_eq!(parent_of(&map, &digest("blake3:absent")), Err(dangling));
    }

    // -------------------------------------------------------------------
    // Characterization, NOT a law: the walk's COST shape.
    //
    // The fenced block above says what `meet` answers; these say what it
    // costs to answer. Short-circuiting is an implementation choice this
    // module owns -- `spec/support/shared_examples/meet_semilattice.rb`
    // declares no complexity law, and must never grow one from here.
    //
    // Two instruments, and only one of them discriminates on its own:
    //
    //   * `ancestor_queries_stop_at_the_answer` -- a chain that DANGLES past
    //     its root. Answering at depth 1 is possible only by stopping there.
    //     This is the primary evidence for the short-circuit claim.
    //   * `find_ancestor_visits_only_as_far_as_the_answer` -- counts predicate
    //     invocations, which is `find_ancestor`'s own loop, not an adapter's.
    //
    // A count taken with `.inspect(..).any(..)` over `walk` would prove
    // NOTHING: it measures `Iterator::any`'s early exit, which every iterator
    // has, so an eager `walk` that read the whole chain up front and handed
    // back `vec.into_iter()` would score identically. Review caught exactly
    // that; do not reintroduce it. The laziness of the READ is observable
    // only through allocation, which is what the next test does.
    // -------------------------------------------------------------------

    // Counts allocations on the CALLING thread, so a parallel test's traffic
    // never leaks into a reading. Const-initialized and `Drop`-free, so the
    // thread-local itself never allocates and cannot recurse into `alloc`;
    // reached through `try_with` because TLS teardown must not panic here.
    struct CountingAllocator;

    thread_local! {
        static ALLOCATIONS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
    }

    // SAFETY: both arms forward to `System`, which satisfies the GlobalAlloc
    // contract; the counter is a plain `Cell` read-modify-write on the calling
    // thread and allocates nothing itself, so it adds no reentrancy.
    unsafe impl std::alloc::GlobalAlloc for CountingAllocator {
        unsafe fn alloc(&self, layout: std::alloc::Layout) -> *mut u8 {
            ALLOCATIONS.try_with(|n| n.set(n.get() + 1)).ok();
            unsafe { std::alloc::System.alloc(layout) }
        }

        unsafe fn dealloc(&self, ptr: *mut u8, layout: std::alloc::Layout) {
            unsafe { std::alloc::System.dealloc(ptr, layout) }
        }
    }

    #[global_allocator]
    static COUNTING: CountingAllocator = CountingAllocator;

    // Allocations charged to `body`, on this thread.
    fn allocations(body: impl FnOnce()) -> usize {
        let before = ALLOCATIONS.with(std::cell::Cell::get);
        body();
        ALLOCATIONS.with(std::cell::Cell::get) - before
    }

    #[test]
    fn a_walk_allocates_nothing_per_node() {
        // The claim the iterator was written for, and the only instrument that
        // can see it. Two ways to fail it, both of which this catches:
        //
        //   * an eager `walk` that buffers every step into a `Vec` first --
        //     `length` then pays that Vec's growth (measured: 12);
        //   * an OWNED cursor (`cursor.clone_from(&turn.render_parent)`) --
        //     one `String` per node (measured: 5_000).
        //
        // Both were re-run as mutations and both fail here. Both PASSED the
        // `.inspect().any()` count this test replaced, which is why that one
        // is gone.
        let (map, head) = chain(5_000);

        let for_length = allocations(|| assert_eq!(length(&map, Some(&head)), Ok(5_000)));
        assert_eq!(
            for_length, 0,
            "length allocated {for_length} times over 5_000 nodes; the walk should allocate none"
        );

        // `ancestor_turns` hands back a `Vec`, so it pays that Vec's growth --
        // and nothing else. Bounded well under the node count: a per-node
        // allocation would put this in the thousands.
        let for_turns = allocations(|| {
            ancestor_turns(&map, Some(&head)).expect("well-formed chain");
        });
        assert!(
            for_turns < 40,
            "ancestor_turns allocated {for_turns} times; only the Vec's growth should"
        );
    }

    #[test]
    fn find_ancestor_visits_only_as_far_as_the_answer() {
        // `meet`'s find side, exercised the way `meet` drives it: the
        // predicate runs once per node `find_ancestor` VISITS, so this counts
        // the consumer's loop. It says nothing about when the walk READ those
        // nodes -- that is `a_walk_allocates_nothing_per_node`'s job -- but
        // the consumer's loop is what `meet` short-circuits, so it is the
        // right thing to count here.
        let (map, digests) = dangling_chain(10_000);
        let (head, target) = (digests[0].clone(), digests[1].clone());
        let mut visited = 0;
        let found = find_ancestor(&map, Some(&head), |digest| {
            visited += 1;
            *digest == target
        });
        assert_eq!(found, Ok(Some(target)));
        assert_eq!(
            visited, 2,
            "the find side visited {visited} of 10_000 nodes"
        );
    }

    #[test]
    fn ancestor_queries_stop_at_the_answer() {
        // The chain DANGLES past its root, so any walk that runs to the end
        // raises. Answering at depth 1 is only possible by stopping there --
        // the same observation as the counts above, made through the public
        // functions rather than the private walk.
        let (map, digests) = dangling_chain(10_000);
        let head = digests[0].clone();
        let target = digests[1].clone();
        assert_eq!(includes(&map, Some(&head), &target), Ok(true));
        assert_eq!(ancestor_of(&map, Some(&target), Some(&head)), Ok(true));
    }

    #[test]
    fn meet_answers_a_long_chain_at_its_first_common_digest() {
        // The a side is the whole chain by necessity (a membership test needs
        // its set built first), so only the b side can stop early. Here b is
        // one commit above a's head: the answer is b's second node.
        //
        // The STOPPING is proven one test up, not here -- `meet`'s find side
        // IS `find_ancestor`, and a dangle cannot be placed to observe it
        // through `meet` itself: everything b-exclusive sits ABOVE the answer
        // (visited first), and everything below is a's chain, which the set
        // build needs whole. This test pins the answer over that shape.
        let (map, head) = chain(10_000);
        let (map, above) = commit(&map, Some(&head), "above");
        assert_eq!(meet(&map, Some(&head), Some(&above)), Ok(Some(head)));
    }

    #[test]
    fn length_counts_the_chain_and_raises_on_a_dangle() {
        // Values only -- this passes against `ancestor_turns(..)?.len()` too.
        // That `length` materializes nothing is `a_walk_allocates_nothing_per_node`'s
        // claim, not this one's, and the name says so now.
        let (map, head) = chain(10_000);
        assert_eq!(length(&map, Some(&head)), Ok(10_000));
        assert_eq!(length(&StoreMap::new_sync(), None), Ok(0));
        let (corrupt_map, corrupt_head) = corrupt();
        assert_eq!(
            length(&corrupt_map, Some(&corrupt_head)),
            Err(DanglingDigest(digest("blake3:absent")))
        );
    }

    #[test]
    fn includes_is_false_for_a_digest_off_the_chain() {
        let (map, _base, left, right) = forest();
        assert_eq!(includes(&map, Some(&left), &left), Ok(true));
        assert_eq!(includes(&map, Some(&left), &right), Ok(false));
        assert_eq!(includes(&map, None, &digest("blake3:anything")), Ok(false));
    }

    #[test]
    fn dangling_message_matches_ruby_string_inspect() {
        // Ruby `Store#fetch`: `"no object #{digest.inspect} in store"`.
        assert_eq!(
            DanglingDigest(digest("blake3:absent")).to_string(),
            r#"no object "blake3:absent" in store"#
        );
        // A double-quote escapes the same in Rust `{:?}` and Ruby `String#inspect`.
        assert_eq!(
            DanglingDigest(digest(r#"blake3:a"b"#)).to_string(),
            r#"no object "blake3:a\"b" in store"#
        );
    }
}
