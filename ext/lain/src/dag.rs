//! Pure ancestry queries over a content-addressed store.
//!
//! The Store maps a digest to its [`EventData`]; walking render-parent pointers
//! through that map is all `ancestors`, `meet`, and `ancestor_of?` need. Every
//! walk here follows the SINGLE render edge -- the first-parent chain -- and is
//! unchanged by the envelope re-port: `causal_parents` never participates (the
//! union-graph orders live in [`crate::graph`]). Keeping these as plain
//! functions over an `rpds` map -- no `magnus` -- is what lets
//! the structure below be proven without an embedded Ruby VM, and lets the FFI
//! layer perform each walk ENTIRELY in Rust, crossing the boundary once with a
//! batched result rather than once per node.
//!
//! **There is one walk, and it is an iterator.** Every function here folds over
//! the private `walk`, which pulls one node at a time; nothing builds a `Vec`
//! it does not hand back. That is what makes a bounded question cost a bounded
//! walk -- `includes`, `ancestor_of`, and `meet`'s find side stop AT the answer
//! rather than after the chain -- and it is the Rust half of the change the
//! Ruby `Lain::Timeline` took before its deletion, where `#ancestors` yields
//! rather than materializes (root `CLAUDE.md`, "Enumerable and Enumerator are
//! the good abstractions").
//!
//! # The structure, and exactly which laws are proven where
//!
//! **Structure:** the heads over one Store form a MEET-SEMILATTICE ordered by
//! render ancestry -- `a <= b` when a is an ancestor of b ([`ancestor_of`]).
//! **Operation:** [`meet`], the greatest common ancestor. **Bottom:** the empty
//! head, `None`, which is what makes `meet` total for two heads sharing no
//! history. That is the whole claim; this module implements no join, and the
//! dominator meet and causal bounds are `graph`'s, over a different edge set.
//! The order itself is named as a type, `algebra::RenderAncestry`, which
//! delegates to the two functions here.
//!
//! **Four laws, and no fifth:** idempotent, commutative, associative, and "a
//! meet sits below both operands". They are not written in this file: the
//! `algebra` module's `declare_meet_semilattice!` emits them as
//! `algebra::render_ancestry_laws`, over this file's `tests::law_population`,
//! in the same expansion that lets `RenderAncestry` claim the structure at all.
//! Their names are the ones `spec/support/shared_examples/meet_semilattice.rb`
//! uses, so the two layers cannot come to disagree about what a law IS.
//!
//! **Two suites, two different claims.** `cargo test` proves the Rust
//! ALGORITHM here obeys those four laws, at a layer the Ruby suite cannot
//! reach. `spec/lain/rust/*` proves the Rust BINDING obeys the same laws, by
//! running the shared groups unchanged, and the frozen corpus
//! (`ext/lain/corpus/dag.ndjson`, read by `corpus.rs`) holds what the deleted
//! Ruby answered -- no test in this file compares against a Ruby value. Read
//! one as "the algorithm is a meet-semilattice" and the others as "the port is
//! faithful"; neither substitutes for the other.

use crate::canonical::{self, Canon};
use crate::digest::Digest;
use crate::event::{EventData, PayloadData};
use rpds::HashTrieMapSync;
use std::collections::HashSet;
use std::sync::Arc;

/// The content-addressed event map every walk reads. A persistent HAMT, so a
/// `fork` shares the whole prefix and a shared prefix is stored once. Keyed by
/// [`Digest`], not a bare `String`, so a walk cannot be handed an arbitrary
/// string as an address.
pub type StoreMap = HashTrieMapSync<Digest, Arc<EventData>>;

/// Every member of a Store that is not an event, keyed the same way. Never
/// holds a [`NodeData::Event`]; [`Objects::with`] is what routes.
pub type MemberMap = HashTrieMapSync<Digest, NodeData>;

/// One object a Store holds, by what the crate can give back for it: it keeps
/// no Ruby reference, so a fetch answers the arm, never the original object.
#[derive(Debug, Clone)]
pub enum NodeData {
    /// An envelope of any kind, always carrying its payload once stored.
    Event(Arc<EventData>),
    /// An envelope's out-of-line body.
    Payload(Arc<PayloadData>),
    /// Raw bytes under a tagged header, the scheme `ContentAddressed::Blob` uses.
    Blob(Arc<BlobData>),
    /// Any other value addressed by its canonical tree.
    Canon(Arc<CanonData>),
}

impl NodeData {
    /// The address the store keys this object by.
    pub fn digest(&self) -> &Digest {
        match self {
            NodeData::Event(event) => &event.digest,
            NodeData::Payload(payload) => &payload.digest,
            NodeData::Blob(blob) => &blob.digest,
            NodeData::Canon(canon) => &canon.digest,
        }
    }

    /// The digests this object needs the store to hold already, each with the
    /// map it must be in, in the order the deleted Ruby `Store#parent_edges`
    /// checked them:
    /// the render edge, the payload edge, then the causal set.
    pub fn edges(&self) -> Vec<(&Digest, Arm)> {
        match self {
            NodeData::Event(event) => event
                .render_parent
                .iter()
                .map(|parent| (parent, Arm::Event))
                .chain(std::iter::once((&event.payload_digest, Arm::Member)))
                .chain(
                    event
                        .causal_parents
                        .iter()
                        .map(|parent| (parent, Arm::Event)),
                )
                .collect(),
            NodeData::Canon(canon) => canon
                .parent
                .iter()
                .map(|parent| (parent, Arm::Member))
                .collect(),
            NodeData::Payload(_) | NodeData::Blob(_) => Vec::new(),
        }
    }
}

/// Which of a Store's 2 maps an edge must land in. A render or causal edge is
/// walked, so it must name an event; anything else names a member.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Arm {
    /// The event map every walk reads.
    Event,
    /// The map of everything else.
    Member,
}

impl Arm {
    /// The word a refusal names the missing thing by.
    pub fn noun(self) -> &'static str {
        match self {
            Arm::Event => "event",
            Arm::Member => "member",
        }
    }
}

/// Bytes addressed git's way: blake3 over `"<tag> <length>\0"` and then the
/// bytes, so no byte string can spell a canonical dump's address.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlobData {
    /// The raw bytes, in no encoding.
    pub bytes: Vec<u8>,
    /// The tagged-header address.
    pub digest: Digest,
}

impl BlobData {
    /// Address `bytes` under `tag`, as `ContentAddressed::Blob#initialize` does.
    pub fn new(tag: &str, bytes: Vec<u8>) -> Self {
        let mut hasher = blake3::Hasher::new();
        hasher.update(format!("{tag} {}\0", bytes.len()).as_bytes());
        hasher.update(&bytes);
        let digest = Digest::from(format!("blake3:{}", hasher.finalize().to_hex()));
        Self { bytes, digest }
    }
}

/// A value addressed by its canonical tree, the digest recomputed here from
/// the tree rather than taken on trust.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CanonData {
    /// The canonical tree that was hashed.
    pub tree: Canon,
    /// `canonical::digest` over `tree`.
    pub digest: Digest,
    /// The store edge the tree names, if any; see [`CanonData::new`].
    pub parent: Option<Digest>,
}

impl CanonData {
    /// Address `tree` the way `Canonical.digest` does, and read its edge: the
    /// top-level `"parent"` digest. The deleted Ruby Store read a `#parent` edge
    /// off any member that had one, and `Memory::Index::Node` is the only canonical
    /// member that does; its key is inside its address, so it cannot be renamed
    /// out from under this reader.
    pub fn new(tree: Canon) -> Self {
        let digest = Digest::from(canonical::digest(&tree));
        let parent = match &tree {
            Canon::Object(pairs) => pairs.iter().find_map(|(key, value)| match value {
                Canon::Str(text) if key == "parent" => Some(Digest::from(text.clone())),
                _ => None,
            }),
            _ => None,
        };
        Self {
            tree,
            digest,
            parent,
        }
    }
}

/// The whole of one Store: the events every walk reads, and every other member
/// beside them. Two maps, one keyspace -- every question here asks both -- so
/// the walks, and `graph`'s orders over the same map, stay monomorphic.
#[derive(Debug, Clone)]
pub struct Objects {
    /// Envelopes, each carrying its payload.
    pub events: StoreMap,
    /// Everything else.
    pub members: MemberMap,
}

impl Objects {
    /// A store holding nothing.
    pub fn empty() -> Self {
        Self {
            events: StoreMap::new_sync(),
            members: MemberMap::new_sync(),
        }
    }

    /// Whether either map holds `digest`.
    pub fn contains(&self, digest: &Digest) -> bool {
        self.events.contains_key(digest) || self.members.contains_key(digest)
    }

    /// Whether the map `arm` names holds `digest`.
    pub fn holds(&self, digest: &Digest, arm: Arm) -> bool {
        match arm {
            Arm::Event => self.events.contains_key(digest),
            Arm::Member => self.members.contains_key(digest),
        }
    }

    /// The object at `digest`, whichever map holds it.
    pub fn get(&self, digest: &Digest) -> Option<NodeData> {
        match self.events.get(digest) {
            Some(event) => Some(NodeData::Event(Arc::clone(event))),
            None => self.members.get(digest).cloned(),
        }
    }

    /// The payload at `digest`, or `None` when the object there is not one.
    pub fn payload(&self, digest: &Digest) -> Option<&Arc<PayloadData>> {
        match self.members.get(digest)? {
            NodeData::Payload(payload) => Some(payload),
            _ => None,
        }
    }

    /// How many objects both maps hold.
    pub fn size(&self) -> usize {
        self.events.size() + self.members.size()
    }

    /// These objects with `node` added, in the map its arm belongs to.
    pub fn with(&self, node: NodeData) -> Self {
        match node {
            NodeData::Event(event) => Self {
                events: self.events.insert(event.digest.clone(), event),
                members: self.members.clone(),
            },
            member => Self {
                events: self.events.clone(),
                members: self.members.insert(member.digest().clone(), member),
            },
        }
    }
}

/// A walk referenced a digest that is not in the map. A well-formed Timeline
/// never dangles, so this is corruption, NOT the ordinary end of a chain --
/// reaching a root is `parent == None`, a valid stop this type never conflates
/// with an absent digest. The FFI layer turns it into `Store::MissingObject`.
///
/// Hand-rolled `Display`/`Error` (no `thiserror`) whose message is byte-equal to
/// the deleted Ruby `Store#fetch`'s, as `ext/lain/corpus/errors.ndjson` records
/// it: `{:?}` escapes a plain digest, and one containing a double-quote, exactly
/// as Ruby's `String#inspect` does. Out of scope for byte-parity: control
/// characters AND Ruby's interpolation guards (`#{`, `#@`, `#$`, which
/// `String#inspect` escapes to `\#{` etc. and `{:?}` leaves bare) -- the escape
/// styles genuinely differ there; both implementations raised.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DanglingDigest(pub Digest);

impl std::fmt::Display for DanglingDigest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // `{:?}` on a `Digest` renders exactly as it did on the former `String`
        // field -- `Digest`'s hand-written `Debug` delegates to the inner
        // `String`'s -- so this message stays byte-equal to the deleted Ruby
        // `Store#fetch`'s, as errors.ndjson records it.
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

/// The event `digest` names: one step of a walk, for the one FFI caller that
/// yields its walk a node at a time and so cannot hold [`walk`]'s borrow across
/// a yield. A digest the map does not hold is the same [`DanglingDigest`] the
/// walk raises.
pub fn node(map: &StoreMap, digest: &Digest) -> Result<Arc<EventData>, DanglingDigest> {
    map.get(digest)
        .map(Arc::clone)
        .ok_or_else(|| DanglingDigest(digest.clone()))
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

/// The turns after `after` up to `head`, root first, and whether the walk
/// reached `after`. A bound off the chain is never reached, so the walk runs to
/// the root and says so: the caller learns from this one walk whether a prefix
/// it holds may be extended.
pub fn turns_since(
    map: &StoreMap,
    head: Option<&Digest>,
    after: Option<&Digest>,
) -> Result<(Vec<Arc<EventData>>, bool), DanglingDigest> {
    let mut turns = Vec::new();
    let mut reached = false;
    for step in walk(map, head) {
        let turn = step?;
        reached = after == Some(&turn.digest);
        if reached {
            break;
        }
        turns.push(turn);
    }
    turns.reverse();
    Ok((turns, reached))
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

/// How many nodes the chain from `head` holds -- `Ext::Timeline#length`. Folds
/// the count over the walk, so asking for a number never allocates a `Vec` of
/// every `Arc` on the chain to then throw away.
pub fn length(map: &StoreMap, head: Option<&Digest>) -> Result<usize, DanglingDigest> {
    walk(map, head).try_fold(0, |count, step| step.map(|_turn| count + 1))
}

/// Whether `needle` is on the chain from `head` -- `Ext::Timeline#include?`.
/// Stops at the hit (see [`find_ancestor`]), so membership near the head is
/// answered in a couple of node reads however long the chain behind it is.
pub fn includes(
    map: &StoreMap,
    head: Option<&Digest>,
    needle: &Digest,
) -> Result<bool, DanglingDigest> {
    Ok(find_ancestor(map, head, |digest| digest == needle)?.is_some())
}

/// The `wanted` digests some turn on `head`'s chain names as a causal parent,
/// in the order the walk finds them, each once. Stops the moment every distinct
/// wanted digest is found, so a note a recent turn consumed costs a few node
/// reads rather than the whole chain; a dangle reached before that still raises.
pub fn consumed(
    map: &StoreMap,
    head: Option<&Digest>,
    wanted: &[Digest],
) -> Result<Vec<Digest>, DanglingDigest> {
    let mut remaining: HashSet<&Digest> = wanted.iter().collect();
    let mut found = Vec::new();
    let mut steps = walk(map, head);
    while !remaining.is_empty() {
        let Some(step) = steps.next() else { break };
        for parent in &step?.causal_parents {
            if remaining.remove(parent) {
                found.push(parent.clone());
            }
        }
    }
    Ok(found)
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
/// returns the first digest also on `a`, as the deleted Ruby `Timeline#meet` did.
///
/// This is the MEET of the ancestry meet-semilattice (see the module doc), and
/// it is **idempotent, commutative, and associative**, with `None` as the
/// bottom element -- laws, not incidental behaviour. Proven by `cargo test`
/// against this function through `algebra::RenderAncestry`, over every pair and
/// triple of a generated forest (`algebra::render_ancestry_laws`). That the
/// Ruby-facing `Ext::Timeline#meet` binding obeys the same four is proven
/// separately, and only, by `spec/lain/rust/timeline_spec.rb` running the
/// shared group unchanged.
pub fn meet(
    map: &StoreMap,
    a_head: Option<&Digest>,
    b_head: Option<&Digest>,
) -> Result<Option<Digest>, DanglingDigest> {
    // The `a` side is the whole chain by necessity -- a membership test needs
    // its set built before the first question -- exactly as the deleted Ruby
    // `Timeline#meet` built `mine`. Only the `b` side can stop early, and
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
/// `algebra::render_ancestry_laws::meet_orders_below_both_operands` proves
/// [`meet`] against it, and
/// `spec/lain/rust/timeline_spec.rb` is what holds the binding,
/// `Ext::Timeline#ancestor_of?`, to the same order.
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
pub(crate) mod tests {
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

    // a -> b -> c, as digests root first.
    fn three() -> (StoreMap, Vec<Digest>) {
        let (map, a) = commit(&StoreMap::new_sync(), None, "a");
        let (map, b) = commit(&map, Some(&a), "b");
        let (map, c) = commit(&map, Some(&b), "c");
        (map, vec![a, b, c])
    }

    fn since(
        map: &StoreMap,
        head: Option<&Digest>,
        after: Option<&Digest>,
    ) -> Result<(Vec<Digest>, bool), DanglingDigest> {
        turns_since(map, head, after).map(|(turns, reached)| {
            (
                turns.iter().map(|turn| turn.digest.clone()).collect(),
                reached,
            )
        })
    }

    #[test]
    fn no_bound_walks_the_whole_chain_root_first() {
        let (map, chain) = three();
        assert_eq!(
            since(&map, Some(&chain[2]), None),
            Ok((chain.clone(), false))
        );
    }

    #[test]
    fn an_ancestor_bounds_the_walk_to_the_turns_after_it() {
        let (map, chain) = three();
        assert_eq!(
            since(&map, Some(&chain[2]), Some(&chain[0])),
            Ok((chain[1..].to_vec(), true))
        );
    }

    #[test]
    fn the_head_itself_bounds_the_walk_to_nothing() {
        let (map, chain) = three();
        assert_eq!(
            since(&map, Some(&chain[2]), Some(&chain[2])),
            Ok((vec![], true))
        );
    }

    #[test]
    fn a_digest_off_the_chain_answers_the_whole_walk_unreached() {
        let (map, chain) = three();
        let elsewhere = Digest::from("blake3:elsewhere".to_string());
        assert_eq!(
            since(&map, Some(&chain[2]), Some(&elsewhere)),
            Ok((chain.clone(), false))
        );
    }

    #[test]
    fn an_empty_head_answers_nothing_unreached() {
        let (map, chain) = three();
        assert_eq!(since(&map, None, Some(&chain[0])), Ok((vec![], false)));
    }

    #[test]
    fn a_dangling_edge_stops_the_walk_since_a_bound() {
        let absent = Digest::from("blake3:absent".to_string());
        assert_eq!(
            since(&StoreMap::new_sync(), Some(&absent), None),
            Err(DanglingDigest(absent))
        );
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
    pub(crate) fn law_population() -> (StoreMap, Vec<Option<Digest>>) {
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
    fn node_answers_the_event_a_digest_names_and_refuses_an_absent_one() {
        let map = StoreMap::new_sync();
        let (map, a) = commit(&map, None, "a");
        let (map, b) = commit(&map, Some(&a), "b");
        let stepped = node(&map, &b).expect("b is stored");
        assert_eq!(
            (stepped.digest.clone(), stepped.render_parent.clone()),
            (b, Some(a))
        );
        assert_eq!(
            node(&map, &digest("blake3:absent")).unwrap_err(),
            DanglingDigest(digest("blake3:absent"))
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
    // The laws `algebra` emits say what `meet` answers; these say what it
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

    fn commit_naming(
        map: &StoreMap,
        parent: Option<&Digest>,
        causal: Vec<Digest>,
    ) -> (StoreMap, Digest) {
        let turn = EventData::turn(
            Role::User,
            text("names"),
            parent.cloned(),
            Canon::Object(vec![]),
            None,
            causal,
        );
        let digest = turn.digest.clone();
        (map.insert(digest.clone(), turn), digest)
    }

    #[test]
    fn consumed_answers_the_wanted_digests_a_turn_names() {
        let (map, base) = chain(5);
        let (note_a, note_b, note_c) = (digest("blake3:a"), digest("blake3:b"), digest("blake3:c"));
        let (map, mid) = commit_naming(&map, Some(&base), vec![note_b.clone()]);
        let (map, head) = commit_naming(&map, Some(&mid), vec![note_a.clone()]);
        let wanted = [note_a.clone(), note_b.clone(), note_c];
        assert_eq!(
            consumed(&map, Some(&head), &wanted),
            Ok(vec![note_a, note_b])
        );
        assert_eq!(consumed(&map, None, &wanted), Ok(vec![]));
    }

    #[test]
    fn consumed_stops_once_every_distinct_wanted_digest_is_found() {
        // The chain dangles past its root, so a walk that outlives the answer raises.
        let (map, digests) = dangling_chain(10_000);
        let note = digest("blake3:note");
        let (map, head) = commit_naming(&map, Some(&digests[0]), vec![note.clone()]);
        let twice = [note.clone(), note.clone()];
        assert_eq!(consumed(&map, Some(&head), &twice), Ok(vec![note.clone()]));
        assert_eq!(consumed(&map, Some(&head), &[]), Ok(vec![]));
        let unnamed = [note, digest("blake3:unnamed")];
        assert_eq!(
            consumed(&map, Some(&head), &unnamed),
            Err(DanglingDigest(digest("blake3:absent")))
        );
    }

    #[test]
    fn consumed_raises_on_a_dangle_before_the_wanted_digests_are_found() {
        let (map, head) = corrupt();
        assert_eq!(
            consumed(&map, Some(&head), &[digest("blake3:note")]),
            Err(DanglingDigest(digest("blake3:absent")))
        );
    }

    #[test]
    fn dangling_message_matches_ruby_string_inspect() {
        // The deleted Ruby `Store#fetch`, as errors.ndjson records it:
        // `"no object #{digest.inspect} in store"`.
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
