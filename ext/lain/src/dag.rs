//! Pure ancestry queries over a content-addressed store.
//!
//! The Store maps a digest to its [`TurnData`]; walking parent pointers through
//! that map is all `ancestors`, `meet`, and `ancestor_of?` need. Keeping these
//! as plain functions over an `rpds` map -- no `magnus` -- means the whole
//! meet-semilattice can be unit-tested without an embedded Ruby VM, and the FFI
//! layer performs each walk ENTIRELY in Rust, crossing the boundary once with a
//! batched result rather than once per node.

use crate::turn::TurnData;
use rpds::HashTrieMapSync;
use std::collections::HashSet;
use std::sync::Arc;

/// The content-addressed object map. A persistent HAMT, so a `fork` shares the
/// whole prefix and a shared prefix is stored once.
pub type StoreMap = HashTrieMapSync<String, Arc<TurnData>>;

/// The `Arc`-shared nodes from `head` up to the root, head first. A digest that
/// is not in the map ends the walk (a valid Timeline never dangles, so this only
/// guards against a corrupt chain). One pass, so callers get the whole chain in
/// a single locked read.
pub fn ancestor_arcs(map: &StoreMap, head: Option<&str>) -> Vec<Arc<TurnData>> {
    let mut out = Vec::new();
    let mut cursor = head.map(str::to_string);
    while let Some(digest) = cursor.take() {
        if let Some(turn) = map.get(&digest) {
            cursor = turn.parent.clone();
            out.push(Arc::clone(turn));
        }
    }
    out
}

/// The digests from `head` to the root, head first.
pub fn ancestor_digests(map: &StoreMap, head: Option<&str>) -> Vec<String> {
    ancestor_arcs(map, head)
        .iter()
        .map(|turn| turn.digest.clone())
        .collect()
}

/// The parent digest of `digest`, or `None` if it is a root or absent. Used by
/// `rewind` to step back without materializing the whole chain.
pub fn parent_of(map: &StoreMap, digest: &str) -> Option<String> {
    map.get(digest).and_then(|turn| turn.parent.clone())
}

/// The greatest common ancestor digest of two heads, or `None` when they share
/// no history. Total: two chains that never meet return `None`, the bottom
/// element. Walks `b` head-first and returns the first digest also on `a`,
/// matching `Timeline#meet` exactly.
pub fn meet(map: &StoreMap, a_head: Option<&str>, b_head: Option<&str>) -> Option<String> {
    let mine: HashSet<String> = ancestor_digests(map, a_head).into_iter().collect();
    ancestor_digests(map, b_head)
        .into_iter()
        .find(|digest| mine.contains(digest))
}

/// Whether the Timeline headed at `ancestor` is an ancestor of the one headed at
/// `descendant`. The empty Timeline (`None`) is below everything; otherwise the
/// descendant's chain must include the ancestor's head.
pub fn ancestor_of(map: &StoreMap, ancestor: Option<&str>, descendant: Option<&str>) -> bool {
    match ancestor {
        None => true,
        Some(head) => ancestor_arcs(map, descendant)
            .iter()
            .any(|turn| turn.digest.as_str() == head),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::canonical::{build_object, Canon};

    fn text(body: &str) -> Canon {
        Canon::Array(vec![Canon::Object(
            build_object(vec![("text".to_string(), Canon::Str(body.to_string()))]).unwrap(),
        )])
    }

    // Commit `body` onto `parent`, returning (new map, new head digest).
    fn commit(map: &StoreMap, parent: Option<&str>, body: &str) -> (StoreMap, String) {
        let turn = TurnData::new(
            "user".to_string(),
            text(body),
            parent.map(str::to_string),
            Canon::Object(vec![]),
        );
        let digest = turn.digest.clone();
        (map.insert(digest.clone(), turn), digest)
    }

    // base(a -> b); left branches (l1 -> l2); right branches (r1).
    fn forest() -> (StoreMap, String, String, String) {
        let map = StoreMap::new_sync();
        let (map, a) = commit(&map, None, "a");
        let (map, b) = commit(&map, Some(&a), "b");
        let (map, l1) = commit(&map, Some(&b), "l1");
        let (map, left) = commit(&map, Some(&l1), "l2");
        let (map, right) = commit(&map, Some(&b), "r1");
        (map, b, left, right)
    }

    #[test]
    fn walks_ancestors_head_first() {
        let map = StoreMap::new_sync();
        let (map, a) = commit(&map, None, "a");
        let (map, b) = commit(&map, Some(&a), "b");
        assert_eq!(ancestor_digests(&map, Some(&b)), vec![b.clone(), a.clone()]);
    }

    #[test]
    fn empty_head_has_no_ancestors() {
        assert!(ancestor_digests(&StoreMap::new_sync(), None).is_empty());
    }

    #[test]
    fn meet_is_the_greatest_common_ancestor() {
        let (map, base, left, right) = forest();
        assert_eq!(meet(&map, Some(&left), Some(&right)), Some(base));
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
        assert_eq!(meet(&map, Some(&left), Some(&other)), None);
    }

    #[test]
    fn ancestor_of_is_a_prefix_relation() {
        let (map, base, left, _right) = forest();
        assert!(ancestor_of(&map, Some(&base), Some(&left)));
        assert!(!ancestor_of(&map, Some(&left), Some(&base)));
    }

    #[test]
    fn empty_is_below_everything() {
        let (map, _base, left, _right) = forest();
        assert!(ancestor_of(&map, None, Some(&left)));
    }

    #[test]
    fn parent_of_steps_back_one_and_stops_at_the_root() {
        let map = StoreMap::new_sync();
        let (map, a) = commit(&map, None, "a");
        let (map, b) = commit(&map, Some(&a), "b");
        assert_eq!(parent_of(&map, &b), Some(a.clone()));
        assert_eq!(parent_of(&map, &a), None);
        assert_eq!(parent_of(&map, "blake3:absent"), None);
    }
}
