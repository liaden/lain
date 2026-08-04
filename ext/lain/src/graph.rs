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
//! **No structure is claimed here yet.** The operators are not implemented, so
//! this module asserts no law -- read the absence as "not yet", not as "the
//! union graph has no algebra". Whatever lands must name its structure, its
//! operation, its bottom, and the list of laws it inherits from
//! `spec/support/shared_examples/meet_semilattice.rb`, which stays the
//! authority on which laws exist.
//!
//! **What the wiring below does and does NOT establish.** Every item here is
//! `#[cfg(test)]` today, so outside the test profile this module expands to
//! nothing: `petgraph` is referenced only from test code, no byte of either
//! reaches the shipped `cdylib`, and a green `rake compile` therefore says
//! nothing about this module or that dependency. What IS established is
//! narrower and still worth having -- the module sits in the build graph rather
//! than being an orphaned file, `cargo test` compiles it, the scoped doc-lint
//! deny is live over it, and petgraph resolves and links at the pinned version
//! with the dominance entry point below reachable and behaving. The release
//! profile begins exercising any of that only when the first non-test item
//! lands here.

#[cfg(test)]
mod tests {
    /// Not a property of this codebase: a build-wiring check, and the reason
    /// this module is declared before it has any content. A Rust module absent
    /// from the build graph is never compiled and `cargo test` reports green
    /// having never seen it, so this test is what makes the module's presence
    /// -- and petgraph's, resolved and linkable at the exact pinned version --
    /// an observed fact rather than a Cargo.toml line nobody has exercised.
    /// It proves that of the TEST profile only; see the module doc on what the
    /// shipped artifact does not yet establish. It stands outside any law
    /// banner and should be deleted the moment a real test here subsumes it.
    #[test]
    fn the_pinned_dominance_algorithm_is_reachable() {
        let mut graph = petgraph::graph::DiGraph::<(), ()>::new();
        let root = graph.add_node(());
        let child = graph.add_node(());
        graph.add_edge(root, child, ());

        let dominators = petgraph::algo::dominators::simple_fast(&graph, root);

        assert_eq!(dominators.immediate_dominator(child), Some(root));
    }
}
