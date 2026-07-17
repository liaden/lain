//! Pure ancestry queries over a content-addressed store.
//!
//! The Store maps a digest to its [`EventData`]; walking render-parent pointers
//! through that map is all `ancestors`, `meet`, and `ancestor_of?` need. Every
//! walk here follows the SINGLE render edge -- the first-parent chain -- and is
//! unchanged by the envelope re-port: `causal_parents` never participates
//! (causal projections stay Ruby-only until a bench shows them hot). Keeping
//! these as plain functions over an `rpds` map -- no `magnus` -- means the whole
//! meet-semilattice can be unit-tested without an embedded Ruby VM, and the FFI
//! layer performs each walk ENTIRELY in Rust, crossing the boundary once with a
//! batched result rather than once per node.

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

    #[test]
    fn meet_is_commutative() {
        let (map, _base, left, right) = forest();
        assert_eq!(
            meet(&map, Some(&left), Some(&right)),
            meet(&map, Some(&right), Some(&left))
        );
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
