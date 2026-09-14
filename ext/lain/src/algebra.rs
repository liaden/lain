//! The orders over one Store, each as a TYPE, with a head as an element of it.
//!
//! `dag` and `graph` hold the operations as plain functions -- `dag::meet` over
//! render ancestry, `graph::dominator_meet` over dominance, `graph::causal_meets`
//! over causal ancestry. This module names the three orders those functions
//! compute in. [`RenderAncestry`] and [`Dominance`] are zero-sized types
//! implementing [`MeetSemilattice`]; [`CausalAncestry`] implements
//! [`MaximalLowerBounds`] instead, so "not a semilattice" is a fact the compiler
//! holds: there is no `impl MeetSemilattice for CausalAncestry`, and a function
//! generic over the trait cannot be instantiated at it.
//!
//! **The consumer.** `ffi`'s `Timeline::meet_via` and `Timeline::below_via` are
//! production functions generic over [`MeetSemilattice`]. Every Ruby-facing
//! `Ext::Timeline#meet`, `#ancestor_of?`, `#dominator_meet` and `#dominates?` is
//! one of those two at one of two types, and `Ext::Dag::RenderAncestry` and
//! `Ext::Dag::Dominance` register the same two functions under the order's own
//! name. That is the "production function generic over the structure"
//! `ext/lain/CLAUDE.md` asks of any algebra trait before it may exist.
//!
//! **Declaration and proof are one expansion.** [`MeetSemilattice`] has a
//! private supertrait, `sealed::Proven`, and only [`declare_meet_semilattice!`]
//! writes its impl -- in the same expansion that emits the `#[cfg(test)]`
//! module carrying the four laws. An `impl MeetSemilattice` outside this file
//! cannot name the supertrait, so it cannot compile; a type cannot claim the
//! structure without the laws being stated over it. What the seal does NOT do
//! is run them: outside `--cfg test` only the marker exists. And it binds every
//! module but this one -- a hand-written `impl sealed::Proven` here compiles,
//! which is why the macro is the only impl this file contains.
//!
//! **Four laws, and no fifth:** idempotent, commutative, associative, and "a
//! meet sits below both operands", named to match
//! `spec/support/shared_examples/meet_semilattice.rb`. Those names are the whole
//! cross-language contract. `cargo test` proves the ALGORITHM obeys them;
//! `spec/lain/rust/*` alone proves the BINDING answers as specified, and no
//! test here compares against a Ruby value.
//!
//! **The bottom is `None`, by the element type.** Both semilattice orders take
//! `Option<Digest>`, and the empty head is below everything in each; what the
//! empty head MEANS differs (the empty Timeline under render ancestry, the
//! unnameable virtual root under dominance), and that is prose on the types
//! below rather than a value either could check.

use crate::dag::{self, DanglingDigest, StoreMap};
use crate::digest::Digest;
use crate::graph;

/// The seal. A private module holding a public trait: nothing outside this file
/// can name `Proven`, so nothing outside it can satisfy [`MeetSemilattice`]'s
/// supertrait bound.
mod sealed {
    /// "The four law tests are declared over this type." Written only by
    /// `declare_meet_semilattice!`.
    pub trait Proven {}
}

/// A meet-semilattice: a partial order `below` in which every pair has a
/// greatest lower bound `meet`, the bottom element making `meet` total.
///
/// The implementing type is the ORDER and carries no data. `Ctx` is what an
/// element is read against and `Elem` is what is ordered. They are associated
/// types rather than fixed ones because the store an element is read against is
/// expected to change shape, and that change should be a change of `Ctx` alone.
/// Both operations are fallible because a head can dangle, and corruption is
/// never read as an answer.
pub trait MeetSemilattice: sealed::Proven {
    /// What an element is read against.
    type Ctx;
    /// What is ordered.
    type Elem;

    /// The greatest lower bound of `a` and `b`.
    fn meet(ctx: &Self::Ctx, a: &Self::Elem, b: &Self::Elem) -> Result<Self::Elem, DanglingDigest>;

    /// Whether `m <= a` in this order.
    fn below(ctx: &Self::Ctx, m: &Self::Elem, a: &Self::Elem) -> Result<bool, DanglingDigest>;
}

/// An order with common lower bounds but no unique greatest one: `meets`
/// answers the SET of maximal lower bounds, git merge-base's shape. Neither a
/// subtrait nor a supertrait of [`MeetSemilattice`] -- the two are different
/// claims, and an order makes one or the other.
pub trait MaximalLowerBounds {
    /// What an element is read against.
    type Ctx;
    /// What is ordered.
    type Elem;

    /// Every common lower bound of `a` and `b` that no other common lower bound
    /// sits above, in digest order -- the one canonical order incomparable
    /// elements admit.
    fn meets(
        ctx: &Self::Ctx,
        a: &Self::Elem,
        b: &Self::Elem,
    ) -> Result<Vec<Digest>, DanglingDigest>;
}

/// Heads ordered by render ancestry: `a <= b` when a's head is on b's
/// first-parent chain. The bottom, `None`, is the empty Timeline.
pub struct RenderAncestry;

impl MeetSemilattice for RenderAncestry {
    type Ctx = StoreMap;
    type Elem = Option<Digest>;

    fn meet(
        ctx: &StoreMap,
        a: &Option<Digest>,
        b: &Option<Digest>,
    ) -> Result<Option<Digest>, DanglingDigest> {
        dag::meet(ctx, a.as_ref(), b.as_ref())
    }

    fn below(
        ctx: &StoreMap,
        m: &Option<Digest>,
        a: &Option<Digest>,
    ) -> Result<bool, DanglingDigest> {
        dag::ancestor_of(ctx, m.as_ref(), a.as_ref())
    }
}

/// Heads ordered by dominance over the union of both parent edges: `a <= b`
/// when every virtual-root path to b passes through a. Strictly stronger than
/// [`RenderAncestry`]. The bottom, `None`, stands for the virtual root, which
/// has no digest to name it by.
pub struct Dominance;

impl MeetSemilattice for Dominance {
    type Ctx = StoreMap;
    type Elem = Option<Digest>;

    fn meet(
        ctx: &StoreMap,
        a: &Option<Digest>,
        b: &Option<Digest>,
    ) -> Result<Option<Digest>, DanglingDigest> {
        graph::dominator_meet(ctx, a.as_ref(), b.as_ref())
    }

    fn below(
        ctx: &StoreMap,
        m: &Option<Digest>,
        a: &Option<Digest>,
    ) -> Result<bool, DanglingDigest> {
        graph::dominates(ctx, m.as_ref(), a.as_ref())
    }
}

/// Heads ordered by reachability over both parent edges. A criss-cross fan-in
/// leaves incomparable maximal common ancestors, so there is no greatest lower
/// bound in general: this type implements [`MaximalLowerBounds`] and not
/// [`MeetSemilattice`], and that absence is the refutation.
pub struct CausalAncestry;

impl MaximalLowerBounds for CausalAncestry {
    type Ctx = StoreMap;
    type Elem = Option<Digest>;

    fn meets(
        ctx: &StoreMap,
        a: &Option<Digest>,
        b: &Option<Digest>,
    ) -> Result<Vec<Digest>, DanglingDigest> {
        graph::causal_meets(ctx, a.as_ref(), b.as_ref())
    }
}

/// Declares `$order` a meet-semilattice in one expansion: the `sealed::Proven`
/// impl its `MeetSemilattice` impl needs to compile, and a `#[cfg(test)]` module
/// `$tests` running the four laws exhaustively over `$population`, a function
/// answering `(Ctx, Vec<Elem>)`.
///
/// The `impl MeetSemilattice` itself stays hand-written, so the delegation reads
/// as ordinary code; what the macro removes is the possibility of writing that
/// impl without the laws.
macro_rules! declare_meet_semilattice {
    ($order:ident, tests: $tests:ident, population: $population:path) => {
        impl sealed::Proven for $order {}

        #[cfg(test)]
        mod $tests {
            use super::*;

            /// The population the laws run over: every pair and every triple.
            fn population() -> (
                <$order as MeetSemilattice>::Ctx,
                Vec<<$order as MeetSemilattice>::Elem>,
            ) {
                $population()
            }

            #[test]
            fn meet_is_idempotent() {
                let (ctx, heads) = population();
                for a in &heads {
                    assert_eq!(
                        <$order as MeetSemilattice>::meet(&ctx, a, a),
                        Ok(a.clone()),
                        "idempotence failed for {a:?}"
                    );
                }
            }

            #[test]
            fn meet_is_commutative() {
                let (ctx, heads) = population();
                for a in &heads {
                    for b in &heads {
                        assert_eq!(
                            <$order as MeetSemilattice>::meet(&ctx, a, b),
                            <$order as MeetSemilattice>::meet(&ctx, b, a),
                            "commutativity failed for {a:?} and {b:?}"
                        );
                    }
                }
            }

            #[test]
            fn meet_is_associative() {
                let (ctx, heads) = population();
                for a in &heads {
                    for b in &heads {
                        let ab = <$order as MeetSemilattice>::meet(&ctx, a, b)
                            .expect("the population is well-formed");
                        for c in &heads {
                            let bc = <$order as MeetSemilattice>::meet(&ctx, b, c)
                                .expect("the population is well-formed");
                            assert_eq!(
                                <$order as MeetSemilattice>::meet(&ctx, &ab, c),
                                <$order as MeetSemilattice>::meet(&ctx, a, &bc),
                                "associativity failed for {a:?}, {b:?}, {c:?}"
                            );
                        }
                    }
                }
            }

            #[test]
            fn meet_orders_below_both_operands() {
                let (ctx, heads) = population();
                for a in &heads {
                    for b in &heads {
                        let m = <$order as MeetSemilattice>::meet(&ctx, a, b)
                            .expect("the population is well-formed");
                        assert_eq!(
                            <$order as MeetSemilattice>::below(&ctx, &m, a),
                            Ok(true),
                            "{m:?} is not below {a:?}"
                        );
                        assert_eq!(
                            <$order as MeetSemilattice>::below(&ctx, &m, b),
                            Ok(true),
                            "{m:?} is not below {b:?}"
                        );
                    }
                }
            }
        }
    };
}

declare_meet_semilattice!(
    RenderAncestry,
    tests: render_ancestry_laws,
    population: crate::dag::tests::law_population
);

declare_meet_semilattice!(
    Dominance,
    tests: dominance_laws,
    population: crate::graph::tests::law_population
);

#[cfg(test)]
mod tests {
    // Characterization, not laws: what the types say about each other, and the
    // one refutation the compiler cannot run.
    use super::*;
    use crate::graph::tests::commit;

    #[test]
    fn causal_ancestry_answers_more_than_one_maximal_lower_bound() {
        // Two tips each render off one branch and causally fold the other two,
        // so x, y and z are all common ancestors and none sits above another.
        // Three rather than two because that is the width at which no
        // single-valued reading of the set is associative.
        let map = StoreMap::new_sync();
        let (map, root) = commit(&map, None, &[], "root");
        let (map, x) = commit(&map, Some(&root), &[], "x");
        let (map, y) = commit(&map, Some(&root), &[], "y");
        let (map, z) = commit(&map, Some(&root), &[], "z");
        let (map, tip_x) = commit(&map, Some(&x), &[&y, &z], "tip_x");
        let (map, tip_y) = commit(&map, Some(&y), &[&x, &z], "tip_y");

        let bounds = CausalAncestry::meets(&map, &Some(tip_x), &Some(tip_y))
            .expect("the witness is well-formed");
        let mut expected = vec![x, y, z];
        expected.sort();
        assert_eq!(bounds, expected);
    }

    #[test]
    fn a_function_generic_over_the_order_answers_per_type() {
        // A causal-only link is invisible to render ancestry and visible to
        // dominance, so one generic caller gets two answers from one pair --
        // the reason the orders are two types and not one type with a flag.
        fn meet_in<S: MeetSemilattice<Ctx = StoreMap, Elem = Option<Digest>>>(
            map: &StoreMap,
            a: &Option<Digest>,
            b: &Option<Digest>,
        ) -> Result<Option<Digest>, DanglingDigest> {
            S::meet(map, a, b)
        }
        let map = StoreMap::new_sync();
        let (map, shared) = commit(&map, None, &[], "shared");
        let (map, rendered) = commit(&map, Some(&shared), &[], "rendered");
        let (map, adopted) = commit(&map, None, &[&shared], "adopted");
        let (a, b) = (Some(rendered), Some(adopted));
        assert_eq!(meet_in::<RenderAncestry>(&map, &a, &b), Ok(None));
        assert_eq!(meet_in::<Dominance>(&map, &a, &b), Ok(Some(shared)));
    }

    /// Runs a check generic over the trait against each semilattice order, over
    /// that order's own law population. The orders are listed here and nowhere
    /// else in this module, so a third `declare_meet_semilattice!` has one line
    /// to add.
    macro_rules! on_both_semilattice_orders {
        ($check:ident) => {
            $check::<RenderAncestry>(dag::tests::law_population());
            $check::<Dominance>(graph::tests::law_population());
        };
    }

    #[test]
    fn the_empty_head_is_the_bottom_of_both_semilattice_orders() {
        // The bottom carries no constant to read; it is `None` by the element
        // type, and this is what holds each order to it over its own population.
        fn bottom_absorbs<S: MeetSemilattice<Ctx = StoreMap, Elem = Option<Digest>>>(
            (map, heads): (StoreMap, Vec<Option<Digest>>),
        ) {
            for head in &heads {
                assert_eq!(S::meet(&map, &None, head), Ok(None), "{head:?}");
                assert_eq!(S::below(&map, &None, head), Ok(true), "{head:?}");
            }
        }
        on_both_semilattice_orders!(bottom_absorbs);
    }

    #[test]
    fn below_is_exactly_where_the_meet_answers_the_lower_operand_in_both_orders() {
        // The four laws hold for a meet that is not the GREATEST lower bound
        // (answer `None` for any unequal pair) and for an order that relates
        // everything (`below` always true). What ties an impl's `meet` to its
        // own `below` is the order-theoretic identity `a <= b iff a ^ b == a`,
        // and it is characterization rather than a fifth law because the Ruby
        // group names four.
        fn below_agrees_with_meet<S: MeetSemilattice<Ctx = StoreMap, Elem = Option<Digest>>>(
            (map, heads): (StoreMap, Vec<Option<Digest>>),
        ) {
            for a in &heads {
                for b in &heads {
                    let m = S::meet(&map, a, b).expect("the population is well-formed");
                    assert_eq!(S::below(&map, a, b), Ok(m == *a), "{a:?} and {b:?}");
                }
            }
        }
        on_both_semilattice_orders!(below_agrees_with_meet);
    }
}
