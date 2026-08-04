//! Ancestry queries over the UNION of an event's two parent edges.
//!
//! [`crate::dag`] answers the render questions -- `ancestors`, `meet`,
//! `ancestor_of?` -- and every walk there follows the single render edge. That
//! is the right shape for the operator it implements, and deliberately so: the
//! render meet is the greatest common ancestor of the prompt history, and a
//! causal edge is not prompt history. This module is for the questions that
//! edge DOES answer -- which turn a fold's inputs both flow through, which
//! events an event causally descends from -- over a graph whose edges are
//! `[render_parent, *causal_parents]` rather than `render_parent` alone.
//!
//! It exists as a separate module rather than more functions in `dag` because
//! the two disagree about what an edge is, and that disagreement is the whole
//! point: they implement different operators over different graphs, not one
//! operator with a widened definition. Ruby carries the same split --
//! `Timeline#meet` walks render parents while `Timeline::CausalAncestry` and
//! `Timeline::Tree` walk the union -- and it is a ruling, not an accident.
//!
//! The graph itself comes from `petgraph` (see this crate's `Cargo.toml`),
//! whose `algo::dominators::simple_fast` is the same published
//! Cooper/Harvey/Kennedy dominance algorithm the Ruby side hand-rolls.
//! Everything here is plain Rust over a store map -- no `magnus`, no embedded
//! Ruby VM -- for the reason `dag` states: the structure can then be proven by
//! `cargo test`, and the FFI layer crosses the boundary once with a batched
//! result rather than once per node.
//!
//! **Which suite proves what, when this module carries a claim.** `cargo test`
//! proves the Rust ALGORITHM obeys a law. `spec/lain/rust/*` proves the Rust
//! BINDING agrees with Ruby, by running the shared example groups unchanged,
//! and it is the sole authority on that cross-implementation claim -- no test
//! in this file compares against a Ruby value. `dag`'s module doc states the
//! same split once for the render structure; this module inherits it.
//!
//! # The structure, and exactly which laws are proven where
//!
//! **Structure:** the heads over one Store form a MEET-SEMILATTICE ordered by
//! DOMINANCE over the union graph -- `a <= b` when every path from the virtual
//! root to b passes through a ([`dominates`]). That order is a DIFFERENT one
//! from `dag`'s render ancestry and is strictly stronger, which is why the
//! semilattice claim is per operation and not per module.
//! **Operation:** [`dominator_meet`], the deepest common dominator -- the
//! latest event no in-flight branch can bypass. **Bottom:** the virtual root,
//! reported as `None`, which is also what either head being `None` (the empty
//! Timeline) answers. The bottom therefore ABSORBS, and that is what makes the
//! operation total over heads sharing no history.
//!
//! **Four laws, and no fifth:** idempotent, commutative, associative, and "a
//! meet sits below both operands" -- below in the DOMINANCE order, which is the
//! predicate `spec/support/algebra_generators.rb` injects for exactly this
//! reason. Each has a `#[test]` below named for it, and the list is the same
//! one `spec/support/shared_examples/meet_semilattice.rb` asserts -- that file
//! is the authority on which laws exist, so the two layers cannot come to
//! disagree about what a law IS.
//!
//! **[`causal_meets`] makes NO semilattice claim, and that is a ruling rather
//! than an omission.** The causal ancestry order has no unique greatest lower
//! bound: a criss-cross fan-in leaves incomparable maximal common ancestors, so
//! the operator answers the SET of them (git merge-base's shape) and a
//! set-valued operator is not a meet. Ruby states it as a first-class negative
//! (`Timeline`'s `not_a_meet_semilattice on: :causal_meets`); no law test below
//! names this function, and adding one would be asserting a structure both
//! layers deny.
//!
//! **Every query is scoped to the closure of the PAIR it is asked about**, as
//! [`UnionGraph::scoped`] explains -- not to the whole store. That is Ruby's
//! shape (`Tree.new(@store, key)`) and it is a correctness-preserving scope,
//! not just a cheaper one.
//!
//! **What reaches the shipped artifact, precisely -- because the stub this file
//! replaced was careful about it and the answer has only half changed.**
//! [`dominator_meet`], [`dominates`] and [`causal_meets`] are ordinary items
//! rather than `#[cfg(test)]`, so the RELEASE profile now compiles and
//! typechecks this module against petgraph: a green `rake compile` is at last
//! evidence that this code builds outside `--cfg test` and that the pinned
//! dependency resolves there. It is still NOT evidence that any of it runs.
//! Nothing calls these functions yet, so no `lain::graph` or petgraph symbol
//! survives into `lib/lain/lain.so` -- verified with `nm`, which finds zero.
//! The card that binds them onto `Ext::Timeline` is their first caller; the
//! three per-function `dead_code` allows below are the marker to delete when it
//! lands, and they sit on the entry points rather than on the module so that
//! every helper here stays covered by the lint in the meantime.

use crate::dag::{DanglingDigest, StoreMap};
use crate::digest::Digest;
use crate::event::EventData;
use petgraph::algo::dominators::{Dominators, simple_fast};
use petgraph::graph::{DiGraph, NodeIndex};
use std::collections::{HashMap, HashSet};

/// The deepest common dominator of two heads, or `None` where the meet climbs
/// all the way to the virtual root -- which includes either head being `None`,
/// because the empty Timeline is the bottom element and absorbs.
///
/// This is the MEET of the dominance meet-semilattice (see the module doc), and
/// it is **idempotent, commutative, and associative**, sitting below both
/// operands under [`dominates`]. Proven by `cargo test` against this function
/// over a union-graph population that includes a disconnected pair; that the
/// Ruby-facing binding obeys the same four is a separate claim owned by
/// `spec/lain/rust/*`.
// The FFI binding is a later card, so this has no caller outside the tests
// yet. Placed on the three ENTRY POINTS only, never on the module: an allowed
// item is still a live dead-code root, so every helper below stays covered and
// one orphaned by a later edit is still reported. Delete these three attributes
// in the commit that adds the first caller.
#[cfg_attr(
    not(test),
    allow(
        dead_code,
        reason = "the card that exposes this to Ruby is its first caller"
    )
)]
pub fn dominator_meet(
    map: &StoreMap,
    a_head: Option<&Digest>,
    b_head: Option<&Digest>,
) -> Result<Option<Digest>, DanglingDigest> {
    match (a_head, b_head) {
        // The bottom absorbs. Answered before the graph is built, exactly as
        // Ruby's `Dominators#meet` returns early on a nil head, so an empty
        // Timeline costs no closure at all.
        (Some(a), Some(b)) => Ok(UnionGraph::scoped(map, &[a, b])?.deepest_common_dominator(a, b)),
        _ => Ok(None),
    }
}

/// Whether every virtual-root path to `node` passes through `dominator` --
/// Ruby `Dominators#dominates?`. Reflexive; `None`, the empty Timeline's head,
/// sits below everything and above only itself.
///
/// This is the ORDER (`a <= b`) the meet-semilattice is taken over, so it is
/// half of what "a meet sits below both operands" even means. It is strictly
/// STRONGER than `dag::ancestor_of`: reachability asks whether SOME path
/// arrives, dominance whether EVERY one does, so a fan-in has render ancestors
/// that dominate nothing.
// See `dominator_meet` on why this attribute is here and when to delete it.
#[cfg_attr(
    not(test),
    allow(
        dead_code,
        reason = "the card that exposes this to Ruby is its first caller"
    )
)]
pub fn dominates(
    map: &StoreMap,
    dominator: Option<&Digest>,
    node: Option<&Digest>,
) -> Result<bool, DanglingDigest> {
    match (dominator, node) {
        (None, _) => Ok(true),
        (Some(_), None) => Ok(false),
        (Some(dominator), Some(node)) => {
            // Scoped to BOTH, as Ruby is: a dominator that is not an ancestor
            // is still in the closure, and simply not on `node`'s chain.
            let scoped = UnionGraph::scoped(map, &[dominator, node])?;
            let wanted = scoped.index_of(dominator);
            let relation = scoped.relation();
            Ok(scoped
                .chain(&relation, node)
                .any(|candidate| candidate == wanted))
        }
    }
}

/// The common causal ancestors of two heads that are not ancestors of another
/// common one -- git merge-base's maximal lower bounds, as digests in digest
/// order, which is the one canonical order incomparable elements admit.
///
/// **Not a meet**, and the module doc says why at length: the answer's
/// cardinality routinely exceeds one, so there is no greatest among them to
/// derive. Do not give this function a law test.
///
/// **It does not inherit [`dominator_meet`]'s cost story, and a caller must not
/// assume it does.** "Scoped to the pair" there means a graph over the pair's
/// closure; here there is no graph at all, but the two closures are taken WHOLE
/// -- this is linear in both heads' full ancestry, every time, with no early
/// stop. Ruby's `CausalAncestry#meets` has exactly the same shape.
// See `dominator_meet` on why this attribute is here and when to delete it.
#[cfg_attr(
    not(test),
    allow(
        dead_code,
        reason = "the card that exposes this to Ruby is its first caller"
    )
)]
pub fn causal_meets(
    map: &StoreMap,
    a_head: Option<&Digest>,
    b_head: Option<&Digest>,
) -> Result<Vec<Digest>, DanglingDigest> {
    // A `None` head contributes no seeds and so no closure, which is what keeps
    // this total rather than a special case.
    let mine: HashSet<Digest> = closure(map, &Vec::from_iter(a_head))?.into_iter().collect();
    let common: Vec<Digest> = closure(map, &Vec::from_iter(b_head))?
        .into_iter()
        .filter(|digest| mine.contains(digest))
        .collect();
    let mut answer = maximal(map, &common)?;
    answer.sort();
    Ok(answer)
}

/// The union-graph parents of an event: its render edge and its causal set
/// together, which is the one place this module's definition of an edge lives.
fn parent_edges(event: &EventData) -> impl Iterator<Item = &Digest> {
    event
        .render_parent
        .iter()
        .chain(event.causal_parents.iter())
}

/// The reflexive-transitive closure of `seeds` over [`parent_edges`], seeds
/// included, in the order first reached. Iterative with an explicit frontier
/// for the reason Ruby's is: causal chains reach thousands of events deep and a
/// recursive walk would carry that on the stack.
///
/// A digest the map does not hold is `Err(DanglingDigest)` naming it -- the
/// same corruption/root distinction `dag` draws, and the reason a query over an
/// unrelated dangling event raises rather than answering over a truncated
/// graph.
fn closure(map: &StoreMap, seeds: &[&Digest]) -> Result<Vec<Digest>, DanglingDigest> {
    let mut reached: HashSet<Digest> = HashSet::new();
    let mut order: Vec<Digest> = Vec::new();
    let mut frontier: Vec<Digest> = seeds.iter().map(|digest| (*digest).clone()).collect();
    while let Some(digest) = frontier.pop() {
        if reached.insert(digest.clone()) {
            let event = map
                .get(&digest)
                .ok_or_else(|| DanglingDigest(digest.clone()))?;
            frontier.extend(parent_edges(event).cloned());
            order.push(digest);
        }
    }
    Ok(order)
}

/// The members of `candidates` no other member sits above. A member is
/// non-maximal exactly when it is reachable from another member's parents, so
/// ONE closure over all those parents finds every non-maximal member at once,
/// instead of a walk per candidate pair.
///
/// That closure is wider than it needs to be, and knowingly so: called from
/// [`causal_meets`], every candidate is a COMMON ancestor, and a parent of a
/// common ancestor is itself common -- so `covered` can only ever be a subset
/// of `candidates`, and walking past them buys nothing. Kept because it is the
/// shape Ruby's `CausalAncestry#maximal` has and because the function then
/// answers correctly for any candidate set rather than only for that one
/// caller's. If a bench ever shows this hot, the fix is to stop the closure at
/// the candidate set, not to change what it answers.
fn maximal(map: &StoreMap, candidates: &[Digest]) -> Result<Vec<Digest>, DanglingDigest> {
    let events: Vec<&EventData> = candidates
        .iter()
        .map(|digest| {
            map.get(digest)
                .map(AsRef::as_ref)
                .ok_or_else(|| DanglingDigest(digest.clone()))
        })
        .collect::<Result<_, _>>()?;
    let parents: Vec<&Digest> = events
        .iter()
        .flat_map(|event| parent_edges(event))
        .collect();
    let covered: HashSet<Digest> = closure(map, &parents)?.into_iter().collect();
    Ok(candidates
        .iter()
        .filter(|digest| !covered.contains(*digest))
        .cloned()
        .collect())
}

/// One union graph, scoped to the closure of the PAIR a query names.
///
/// Scoping is not merely cheaper than a whole-store graph, it is the same
/// answer: the closure is ancestor-closed, so every virtual-root path to either
/// head lies entirely inside it and no node's dominators can change. What a
/// wider graph would add is nodes off both paths, which contribute no path and
/// no dominance. Ruby scopes identically (`Tree.new(@store, key)`), and the
/// asymptotic difference is the point -- a store holds every event ever
/// committed, while a pair's closure holds only the two chains being compared.
///
/// The memo Ruby hangs off its `Dominators` collaborator has no equivalent
/// here: these are pure functions and a query object holding a mutable cache is
/// a separate decision, taken where the Ruby-facing binding lives.
struct UnionGraph {
    /// The flow graph -- edges run PARENT to CHILD, the direction dominance
    /// flows, which is the reverse of the ancestry direction `dag` walks.
    /// A node's weight is its digest, or `None` for the virtual root.
    graph: DiGraph<Option<Digest>, ()>,
    /// The virtual root, spanning the closure's forest roots. A modelling
    /// artifact with no digest, mirroring Ruby `Tree::ROOT`: it is what makes
    /// dominance total over a forest, and callers see `None` where a walk
    /// reaches it -- it must never leave this module.
    root: NodeIndex,
    /// Digest to node index, so a query can enter the graph at a head.
    nodes: HashMap<Digest, NodeIndex>,
}

impl UnionGraph {
    /// Build the flow graph over the closure of `seeds`.
    fn scoped(map: &StoreMap, seeds: &[&Digest]) -> Result<Self, DanglingDigest> {
        let reachable = closure(map, seeds)?;
        let mut graph = DiGraph::with_capacity(reachable.len() + 1, reachable.len() + 1);
        let root = graph.add_node(None);
        let nodes: HashMap<Digest, NodeIndex> = reachable
            .iter()
            .map(|digest| (digest.clone(), graph.add_node(Some(digest.clone()))))
            .collect();

        for digest in &reachable {
            let event = map
                .get(digest)
                .ok_or_else(|| DanglingDigest(digest.clone()))?;
            let child = nodes[digest];
            // Deduped because a render parent may also be named causally, and
            // a parallel edge would say the same thing twice.
            let mut seen: HashSet<&Digest> = HashSet::new();
            for parent in parent_edges(event).filter(|parent| seen.insert(parent)) {
                graph.add_edge(nodes[parent], child, ());
            }
            // No parent edges at all makes this a forest root, and the virtual
            // root is what spans them -- the modelling step that turns a forest
            // into the single-entry flow graph `simple_fast` requires.
            if seen.is_empty() {
                graph.add_edge(root, child, ());
            }
        }
        Ok(Self { graph, root, nodes })
    }

    /// The index of a digest the closure was seeded with. Infallible by
    /// construction: a seed is in its own closure.
    fn index_of(&self, digest: &Digest) -> NodeIndex {
        self.nodes[digest]
    }

    /// The dominance relation over the whole scoped graph -- Cooper/Harvey/
    /// Kennedy, run once. Held by the caller rather than recomputed per chain,
    /// because `simple_fast` solves for EVERY node in one pass and a meet asks
    /// about two.
    fn relation(&self) -> Dominators<NodeIndex> {
        simple_fast(&self.graph, self.root)
    }

    /// `digest`'s dominators, itself first and the virtual root last. Total by
    /// construction: every node in the closure is reachable from the virtual
    /// root, because a node with no parents gets an edge from it.
    fn chain<'a>(
        &self,
        relation: &'a Dominators<NodeIndex>,
        digest: &Digest,
    ) -> impl Iterator<Item = NodeIndex> + 'a {
        relation
            .dominators(self.index_of(digest))
            .expect("every closure node is reachable from the virtual root")
    }

    /// The deepest dominator the two heads share. Sound because a node's
    /// dominators are TOTALLY ORDERED -- they form a chain in the dominator
    /// tree -- so walking one head's chain deepest-first and stopping at the
    /// first member of the other's finds the unique nearest common ancestor,
    /// with no need to compare depths. `None` is the virtual root.
    fn deepest_common_dominator(&self, a_head: &Digest, b_head: &Digest) -> Option<Digest> {
        let relation = self.relation();
        let mine: HashSet<NodeIndex> = self.chain(&relation, a_head).collect();
        let deepest = self
            .chain(&relation, b_head)
            .find(|node| mine.contains(node))
            .expect("both chains end at the virtual root, so they always share it");
        self.graph[deepest].clone()
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

    // A `Digest` from a literal, for the synthetic addresses the scope test
    // needs -- a bare `&str` does not stand in for a digest.
    fn digest(text: &str) -> Digest {
        Digest::from(text.to_string())
    }

    // Commit `body` with BOTH edges: one render parent and any number of causal
    // parents. That second argument is the whole difference from `dag`'s
    // fixture, and every graph below is built out of it.
    fn commit(
        map: &StoreMap,
        parent: Option<&Digest>,
        causal: &[&Digest],
        body: &str,
    ) -> (StoreMap, Digest) {
        let event = EventData::turn(
            Role::User,
            text(body),
            parent.cloned(),
            Canon::Object(vec![]),
            None,
            causal.iter().map(|digest| (*digest).clone()).collect(),
        );
        let digest = event.digest.clone();
        (map.insert(digest.clone(), event), digest)
    }

    // The bottleneck shape: `a -> b`, b forks to `p` and `q`, and two tips each
    // render off one fork and causally fold the other. Every virtual-root path
    // to either tip runs through `b`, so `b` is the deepest common dominator --
    // while `p` and `q` are common CAUSAL ancestors that dominate neither tip,
    // which is what makes this one fixture answer two different questions.
    // Returns (map, b, p, q, tip_p, tip_q).
    fn bottleneck() -> (StoreMap, Digest, Digest, Digest, Digest, Digest) {
        let map = StoreMap::new_sync();
        let (map, a) = commit(&map, None, &[], "a");
        let (map, b) = commit(&map, Some(&a), &[], "b");
        let (map, p) = commit(&map, Some(&b), &[], "p");
        let (map, q) = commit(&map, Some(&b), &[], "q");
        let (map, tip_p) = commit(&map, Some(&p), &[&q], "tip_p");
        let (map, tip_q) = commit(&map, Some(&q), &[&p], "tip_q");
        (map, b, p, q, tip_p, tip_q)
    }

    // The population the four laws run over: one connected component carrying
    // every union-graph shape that matters -- render chains, a fresh render root
    // causally anchored mid-graph (the subagent spawn shape), and fan-ins whose
    // causal parents cross chains -- PLUS a second component that shares nothing
    // with it, PLUS `None`, the empty head.
    //
    // The stranger component is not decoration. Four laws over a fully-connected
    // population would go green while saying nothing about the bottom element,
    // and the bottom is what makes the operation total;
    // `the_law_population_carries_a_pair_with_no_shared_history` is the
    // mechanical guard that it stays present.
    //
    // Deterministic -- the same 17 heads every run, so a failure reproduces --
    // and deliberately bounded: associativity is exhaustive over triples, so
    // 17 heads are 4_913 of them, each building its own pair-scoped graph.
    // Grow this only after checking what it costs.
    fn law_population() -> (StoreMap, Vec<Option<Digest>>) {
        let map = StoreMap::new_sync();
        let (map, r0) = commit(&map, None, &[], "r0");
        let (map, r1) = commit(&map, Some(&r0), &[], "r1");
        let (map, r2) = commit(&map, Some(&r1), &[], "r2");
        let (map, r3) = commit(&map, Some(&r2), &[], "r3");
        let (map, b0) = commit(&map, Some(&r1), &[], "b0");
        let (map, b1) = commit(&map, Some(&b0), &[], "b1");
        let (map, c0) = commit(&map, Some(&r0), &[], "c0");
        let (map, c1) = commit(&map, Some(&c0), &[], "c1");
        let (map, s0) = commit(&map, None, &[&r2], "s0");
        let (map, s1) = commit(&map, Some(&s0), &[], "s1");
        let (map, f0) = commit(&map, Some(&r3), &[&b1, &s1], "f0");
        let (map, f1) = commit(&map, Some(&b1), &[&r3], "f1");
        let (map, f2) = commit(&map, Some(&s1), &[&b0, &r2], "f2");
        let (map, f3) = commit(&map, Some(&c1), &[&b0], "f3");
        let (map, x0) = commit(&map, None, &[], "x0");
        let (map, x1) = commit(&map, Some(&x0), &[], "x1");
        let heads = vec![
            None,
            Some(r0),
            Some(r1),
            Some(r2),
            Some(r3),
            Some(b0),
            Some(b1),
            Some(c0),
            Some(c1),
            Some(s0),
            Some(s1),
            Some(f0),
            Some(f1),
            Some(f2),
            Some(f3),
            Some(x0),
            Some(x1),
        ];
        (map, heads)
    }

    #[test]
    fn dominator_meet_is_the_deepest_common_dominator() {
        let (map, b, p, q, tip_p, tip_q) = bottleneck();
        assert_eq!(
            dominator_meet(&map, Some(&tip_p), Some(&tip_q)),
            Ok(Some(b)),
            "the bottleneck is the latest event both tips must pass through"
        );
        // Not the deepest COMMON ANCESTOR: p and q are both common ancestors of
        // the two tips and both sit strictly below the answer. That they are
        // ancestors WITHOUT being dominators is `dominance_is_stronger_than_reachability`'s
        // claim, not this test's.
        assert_ne!(
            dominator_meet(&map, Some(&tip_p), Some(&tip_q)),
            Ok(Some(p))
        );
        assert_ne!(
            dominator_meet(&map, Some(&tip_p), Some(&tip_q)),
            Ok(Some(q))
        );
    }

    #[test]
    fn dominance_is_stronger_than_reachability() {
        // THE order the whole semilattice claim is taken over, tested under its
        // own name because nothing else here can hold it: weaken `dominates` to
        // plain reachability and `dominator_meet_orders_below_both_operands`
        // goes green VACUOUSLY -- a meet that is merely a common ancestor
        // satisfies a merely-reachable predicate. That is the trap this card
        // was written to avoid, one level below where it was being watched for.
        //
        // `p` is a genuine union-graph ancestor of `tip_q` (through the causal
        // edge), so reachability says yes. It is not a DOMINATOR of `tip_q`,
        // because the render path through `q` bypasses it. Every assert below
        // is a place where the two predicates must disagree.
        let (map, b, p, q, tip_p, tip_q) = bottleneck();

        assert_eq!(
            causal_meets(&map, Some(&tip_q), Some(&p)),
            Ok(vec![p.clone()]),
            "p is reachable from tip_q over the union edges"
        );
        assert_eq!(
            dominates(&map, Some(&p), Some(&tip_q)),
            Ok(false),
            "reachable but bypassable: the render path through q never touches p"
        );
        assert_eq!(dominates(&map, Some(&q), Some(&tip_p)), Ok(false));

        // And it is not merely false everywhere -- the bottleneck DOES dominate
        // both tips, which is what stops a constant `false` from passing.
        assert_eq!(dominates(&map, Some(&b), Some(&tip_p)), Ok(true));
        assert_eq!(dominates(&map, Some(&b), Some(&tip_q)), Ok(true));
        // Reflexive, and the bottom sits below everything while nothing but the
        // bottom sits below it.
        assert_eq!(dominates(&map, Some(&tip_p), Some(&tip_p)), Ok(true));
        assert_eq!(dominates(&map, None, Some(&tip_p)), Ok(true));
        assert_eq!(dominates(&map, Some(&tip_p), None), Ok(false));
    }

    #[test]
    fn dominator_meet_is_none_for_heads_with_no_shared_history() {
        let (map, _b, _p, _q, tip_p, _tip_q) = bottleneck();
        let (map, stranger) = commit(&map, None, &[], "stranger");
        assert_eq!(
            dominator_meet(&map, Some(&tip_p), Some(&stranger)),
            Ok(None),
            "disjoint heads bottom out at the virtual root, which never leaves this module"
        );
        // The bottom absorbs from either side, which is what the empty Timeline
        // means on the Ruby side.
        assert_eq!(dominator_meet(&map, Some(&tip_p), None), Ok(None));
        assert_eq!(dominator_meet(&map, None, Some(&tip_p)), Ok(None));
    }

    #[test]
    fn causal_edges_participate_in_the_dominator_meet() {
        // DO NOT DELETE THIS TEST. It is the ONLY thing in this file standing
        // between a render-only implementation and a green suite, and that is
        // inherent rather than an oversight: the four laws hold over ANY DAG,
        // so they hold over the render forest too. Drop the causal set from
        // `parent_edges` and all four stay green -- verified as a mutation, by
        // this card and by its review independently. The law population's
        // causal edges (`s0`, `f0`-`f3`) widen the shapes the laws run over;
        // they do not discriminate, and only this test does.
        //
        // Two events joined ONLY by a causal edge: `adopted` is a fresh render
        // root, so `dag`'s render-only walk cannot see the shared event at all.
        let map = StoreMap::new_sync();
        let (map, shared) = commit(&map, None, &[], "shared");
        let (map, rendered) = commit(&map, Some(&shared), &[], "rendered");
        let (map, adopted) = commit(&map, None, &[&shared], "adopted");

        assert_eq!(
            dominator_meet(&map, Some(&rendered), Some(&adopted)),
            Ok(Some(shared.clone()))
        );
        assert_eq!(
            crate::dag::meet(&map, Some(&rendered), Some(&adopted)),
            Ok(None),
            "the render meet must NOT see the causal edge; if it does, the two operators have merged"
        );
    }

    #[test]
    fn causal_meets_answers_every_maximal_lower_bound() {
        // Two tips criss-crossing over p and q: neither p nor q is an ancestor
        // of the other, so both are maximal and both must be answered.
        let (map, _b, p, q, tip_p, tip_q) = bottleneck();
        let mut expected = vec![p, q];
        expected.sort();
        assert_eq!(causal_meets(&map, Some(&tip_p), Some(&tip_q)), Ok(expected));

        // And the count is not capped at two. Ruby's own witness is THREE-way
        // (`spec/support/algebra_generators.rb`'s `criss_cross`), because that
        // is the shape that refutes associativity under every single-valued
        // reading of the set -- which is the reason no law test below names
        // this function.
        let map = StoreMap::new_sync();
        let (map, root) = commit(&map, None, &[], "root");
        let (map, x) = commit(&map, Some(&root), &[], "x");
        let (map, y) = commit(&map, Some(&root), &[], "y");
        let (map, z) = commit(&map, Some(&root), &[], "z");
        let (map, tip_x) = commit(&map, Some(&x), &[&y, &z], "tip_x");
        let (map, tip_y) = commit(&map, Some(&y), &[&x, &z], "tip_y");
        let mut three = vec![x, y, z];
        three.sort();
        assert_eq!(causal_meets(&map, Some(&tip_x), Some(&tip_y)), Ok(three));

        // Total, like the meet: heads sharing no causal history answer nothing
        // rather than raising, and a `None` head contributes no closure at all.
        let (map, stranger) = commit(&map, None, &[], "stranger");
        assert_eq!(
            causal_meets(&map, Some(&tip_x), Some(&stranger)),
            Ok(vec![])
        );
        assert_eq!(causal_meets(&map, Some(&tip_x), None), Ok(vec![]));
    }

    #[test]
    fn a_dominator_meet_reads_only_the_ancestry_of_the_queried_pair() {
        // The instrument: every unrelated event in this store DANGLES -- its
        // render parent was never inserted. A query that touched them would
        // raise, so an `Ok` answer is proof it did not, and the node count says
        // exactly how much of the store the query did build.
        let map = StoreMap::new_sync();
        let (map, base) = commit(&map, None, &[], "base");
        let (map, left) = commit(&map, Some(&base), &[], "left");
        let (mut map, right) = commit(&map, Some(&base), &[], "right");
        let absent = digest("blake3:absent");
        let mut unrelated = Vec::new();
        for label in 0..500 {
            let (grown, node) = commit(&map, Some(&absent), &[], &format!("u{label}"));
            map = grown;
            unrelated.push(node);
        }

        assert_eq!(
            dominator_meet(&map, Some(&left), Some(&right)),
            Ok(Some(base))
        );
        assert_eq!(
            UnionGraph::scoped(&map, &[&left, &right])
                .expect("the queried pair is well-formed")
                .graph
                .node_count(),
            4,
            "base, left, right and the virtual root -- not the 503 events in the store"
        );
        // The instrument is live: asking about one of those events DOES raise,
        // so the `Ok` above is a real observation and not a store the walk
        // could have read harmlessly.
        assert_eq!(
            dominator_meet(&map, Some(&unrelated[0]), Some(&unrelated[1])),
            Err(DanglingDigest(absent))
        );
    }

    #[test]
    fn the_law_population_carries_a_pair_with_no_shared_history() {
        // A guard on the fixture, not a property of the code: four laws over a
        // fully-connected population would pass while proving nothing about the
        // bottom element. If a later edit connects the stranger component, this
        // fails and says so.
        let (map, heads) = law_population();
        let named: Vec<&Option<Digest>> = heads.iter().filter(|head| head.is_some()).collect();
        let disjoint = named
            .iter()
            .flat_map(|a| named.iter().map(move |b| (*a, *b)))
            .filter(|(a, b)| dominator_meet(&map, a.as_ref(), b.as_ref()) == Ok(None))
            .count();
        assert!(
            disjoint > 0,
            "the law population has no disconnected pair, so its bottom element is never reached"
        );
    }

    // -------------------------------------------------------------------
    // The four semilattice laws.
    //
    // These are the SAME four the Ruby group asserts -- idempotent,
    // commutative, associative, and "a meet sits below both operands"
    // (`spec/support/shared_examples/meet_semilattice.rb`, which is the
    // authority on which laws exist; neither side asserts a law the other
    // does not). `dag.rs` fences its four the same way, so the two modules
    // cannot drift about what a law IS.
    //
    // They are stated over `Option<Digest>` with `None` as the ABSORBING
    // bottom, because that is what Ruby's nil-to-empty-Timeline `checkout`
    // means -- and over a population that includes a pair with no shared
    // history, so the bottom is actually reached (guarded above).
    //
    // The order the fourth law is taken over is DOMINANCE, not render
    // ancestry -- `spec/support/algebra_generators.rb` injects
    // `dominators.dominates?` for exactly this reason, the render-ancestry
    // predicate being strictly weaker and making the law pass vacuously.
    //
    // What they prove here is different from what they prove in RSpec: this
    // module proves the pure Rust ALGORITHM obeys them, at a layer with no
    // `magnus` and no Ruby VM. That the Rust BINDING agrees with Ruby is a
    // separate claim owned solely by `spec/lain/rust/*` -- no `cargo test`
    // here compares against a Ruby value.
    //
    // `causal_meets` is deliberately ABSENT from this fence. It is set-valued
    // and Ruby declares it `not_a_meet_semilattice`; a law test on it would
    // assert a structure both layers deny.
    // -------------------------------------------------------------------

    #[test]
    fn dominator_meet_is_idempotent() {
        let (map, heads) = law_population();
        for a in &heads {
            assert_eq!(
                dominator_meet(&map, a.as_ref(), a.as_ref()),
                Ok(a.clone()),
                "idempotence failed for {a:?}"
            );
        }
    }

    #[test]
    fn dominator_meet_is_commutative() {
        let (map, heads) = law_population();
        for a in &heads {
            for b in &heads {
                assert_eq!(
                    dominator_meet(&map, a.as_ref(), b.as_ref()),
                    dominator_meet(&map, b.as_ref(), a.as_ref()),
                    "commutativity failed for {a:?} and {b:?}"
                );
            }
        }
    }

    #[test]
    fn dominator_meet_is_associative() {
        let (map, heads) = law_population();
        for a in &heads {
            for b in &heads {
                let ab = dominator_meet(&map, a.as_ref(), b.as_ref())
                    .expect("the population is well-formed");
                for c in &heads {
                    let bc = dominator_meet(&map, b.as_ref(), c.as_ref())
                        .expect("the population is well-formed");
                    assert_eq!(
                        dominator_meet(&map, ab.as_ref(), c.as_ref()),
                        dominator_meet(&map, a.as_ref(), bc.as_ref()),
                        "associativity failed for {a:?}, {b:?}, {c:?}"
                    );
                }
            }
        }
    }

    #[test]
    fn dominator_meet_orders_below_both_operands() {
        let (map, heads) = law_population();
        for a in &heads {
            for b in &heads {
                let m = dominator_meet(&map, a.as_ref(), b.as_ref())
                    .expect("the population is well-formed");
                assert_eq!(
                    dominates(&map, m.as_ref(), a.as_ref()),
                    Ok(true),
                    "{m:?} does not dominate {a:?}"
                );
                assert_eq!(
                    dominates(&map, m.as_ref(), b.as_ref()),
                    Ok(true),
                    "{m:?} does not dominate {b:?}"
                );
            }
        }
    }
}
