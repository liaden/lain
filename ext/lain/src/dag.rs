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

/// The `Arc`-shared nodes from `head` up to the root, head first. A digest that
/// is not in the map is a corrupt chain and returns `Err(DanglingDigest)` naming
/// it, rather than silently truncating the walk. One pass, so callers get the
/// whole chain in a single locked read.
pub fn ancestor_turns(
    map: &StoreMap,
    head: Option<&Digest>,
) -> Result<Vec<Arc<EventData>>, DanglingDigest> {
    let mut out = Vec::new();
    let mut cursor = head.cloned();
    while let Some(digest) = cursor.take() {
        let turn = map
            .get(&digest)
            .ok_or_else(|| DanglingDigest(digest.clone()))?;
        cursor = turn.render_parent.clone();
        out.push(Arc::clone(turn));
    }
    Ok(out)
}

/// The digests from `head` to the root, head first.
pub fn ancestor_digests(
    map: &StoreMap,
    head: Option<&Digest>,
) -> Result<Vec<Digest>, DanglingDigest> {
    Ok(ancestor_turns(map, head)?
        .iter()
        .map(|turn| turn.digest.clone())
        .collect())
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
    let mine: HashSet<Digest> = ancestor_digests(map, a_head)?.into_iter().collect();
    Ok(ancestor_digests(map, b_head)?
        .into_iter()
        .find(|digest| mine.contains(digest)))
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
        Some(head) => Ok(ancestor_turns(map, descendant)?
            .iter()
            .any(|turn| &turn.digest == head)),
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
