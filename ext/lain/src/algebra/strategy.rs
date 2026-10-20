//! Generated graphs for the semilattice laws.
//!
//! A [`DagPlan`] is a program, not a graph: every index is a raw `u16` read
//! modulo the population built so far, so no generated value is ever invalid
//! and a shrink never needs a filter to stay valid.

use super::{MeetSemilattice, RenderAncestry, sealed};
use crate::dag::{DanglingDigest, StoreMap};
use crate::digest::Digest;
use crate::graph::tests::commit;
use proptest::collection::vec;
use proptest::option;
use proptest::prelude::*;

/// Most operations a generated program holds; enough for fan-ins and disjoint
/// components while keeping the pair-scoped dominance graphs cheap.
const MAX_OPS: usize = 14;

/// One commit: the render parent, the causal parents, and a body that keeps
/// otherwise identical commits apart. `None` parent is a fresh root.
#[derive(Debug, Clone)]
pub(super) struct Op {
    /// Index into the nodes built so far; `None` starts a new root.
    parent: Option<u16>,
    causal: Vec<u16>,
    /// Distinguishes this commit's digest.
    body: u8,
}

impl Op {
    pub(super) fn root(body: u8) -> Self {
        Op {
            parent: None,
            causal: Vec::new(),
            body,
        }
    }
}

/// A program and the heads to read after running it.
#[derive(Debug, Clone)]
pub(super) struct DagPlan {
    pub(super) ops: Vec<Op>,
    /// Indices into every node built; `None` is the empty head.
    pub(super) heads: Vec<Option<u16>>,
}

/// An index read modulo the population, or `None` when nothing exists yet.
fn pick(population: &[Digest], index: u16) -> Option<&Digest> {
    population
        .len()
        .checked_sub(1)
        .map(|_| &population[usize::from(index) % population.len()])
}

impl DagPlan {
    /// Runs the program, returning the store and the named heads.
    pub(super) fn build(&self) -> (StoreMap, Vec<Option<Digest>>) {
        let mut map = StoreMap::new_sync();
        let mut population: Vec<Digest> = Vec::new();
        for (step, op) in self.ops.iter().enumerate() {
            let parent = op
                .parent
                .and_then(|index| pick(&population, index))
                .cloned();
            let causal: Vec<Digest> = op
                .causal
                .iter()
                .filter_map(|index| pick(&population, *index))
                .cloned()
                .collect();
            let causal_refs: Vec<&Digest> = causal.iter().collect();
            let (grown, digest) = commit(
                &map,
                parent.as_ref(),
                &causal_refs,
                &format!("{step}:{}", op.body),
            );
            map = grown;
            population.push(digest);
        }
        let heads = self
            .heads
            .iter()
            .map(|head| head.and_then(|index| pick(&population, index)).cloned())
            .collect();
        (map, heads)
    }
}

pub(super) fn plan() -> impl Strategy<Value = DagPlan> {
    let op = (
        option::of(any::<u16>()),
        vec(any::<u16>(), 0..3),
        any::<u8>(),
    )
        .prop_map(|(parent, causal, body)| Op {
            parent,
            causal,
            body,
        });
    (vec(op, 0..=MAX_OPS), vec(option::of(any::<u16>()), 3..=3))
        .prop_map(|(ops, heads)| DagPlan { ops, heads })
}

/// Every digest an event names, and every head, is in the store.
pub(super) fn is_well_formed(map: &StoreMap, heads: &[Option<Digest>]) -> bool {
    let named_by_events = map.values().all(|event| {
        event
            .render_parent
            .iter()
            .chain(&event.causal_parents)
            .all(|digest| map.contains_key(digest))
    });
    named_by_events
        && heads
            .iter()
            .flatten()
            .all(|digest| map.contains_key(digest))
}

/// A render meet that forgets `a ^ a == a`, so a law check has something to
/// catch and shrink.
pub(super) struct BrokenMeet;

impl sealed::Proven for BrokenMeet {}

impl MeetSemilattice for BrokenMeet {
    type Ctx = StoreMap;
    type Elem = Option<Digest>;

    fn meet(
        ctx: &StoreMap,
        a: &Option<Digest>,
        b: &Option<Digest>,
    ) -> Result<Option<Digest>, DanglingDigest> {
        if a == b {
            Ok(None)
        } else {
            RenderAncestry::meet(ctx, a, b)
        }
    }

    fn below(
        ctx: &StoreMap,
        m: &Option<Digest>,
        a: &Option<Digest>,
    ) -> Result<bool, DanglingDigest> {
        RenderAncestry::below(ctx, m, a)
    }
}

/// The four laws as properties over one generated plan.
pub(super) mod laws {
    use super::*;
    use proptest::test_runner::TestCaseError;

    type Verdict = Result<(), TestCaseError>;

    pub(in crate::algebra) fn idempotent<S>(plan: &DagPlan) -> Verdict
    where
        S: MeetSemilattice<Ctx = StoreMap, Elem = Option<Digest>>,
    {
        let (map, heads) = plan.build();
        for a in &heads {
            prop_assert_eq!(S::meet(&map, a, a), Ok(a.clone()));
        }
        Ok(())
    }

    pub(in crate::algebra) fn commutative<S>(plan: &DagPlan) -> Verdict
    where
        S: MeetSemilattice<Ctx = StoreMap, Elem = Option<Digest>>,
    {
        let (map, heads) = plan.build();
        for a in &heads {
            for b in &heads {
                prop_assert_eq!(S::meet(&map, a, b), S::meet(&map, b, a));
            }
        }
        Ok(())
    }

    pub(in crate::algebra) fn associative<S>(plan: &DagPlan) -> Verdict
    where
        S: MeetSemilattice<Ctx = StoreMap, Elem = Option<Digest>>,
    {
        let (map, heads) = plan.build();
        for a in &heads {
            for b in &heads {
                for c in &heads {
                    let ab = S::meet(&map, a, b).map_err(fail)?;
                    let bc = S::meet(&map, b, c).map_err(fail)?;
                    prop_assert_eq!(S::meet(&map, &ab, c), S::meet(&map, a, &bc));
                }
            }
        }
        Ok(())
    }

    pub(in crate::algebra) fn below_both<S>(plan: &DagPlan) -> Verdict
    where
        S: MeetSemilattice<Ctx = StoreMap, Elem = Option<Digest>>,
    {
        let (map, heads) = plan.build();
        for a in &heads {
            for b in &heads {
                let m = S::meet(&map, a, b).map_err(fail)?;
                prop_assert_eq!(S::below(&map, &m, a), Ok(true));
                prop_assert_eq!(S::below(&map, &m, b), Ok(true));
            }
        }
        Ok(())
    }

    /// A dangling digest in a generated store is a generator bug, not a law.
    fn fail(error: DanglingDigest) -> TestCaseError {
        TestCaseError::fail(format!("generated store dangled: {error:?}"))
    }
}

mod tests {
    use super::*;
    use proptest::strategy::ValueTree;
    use proptest::test_runner::{Config, TestError, TestRunner};

    proptest! {
        #![proptest_config(ProptestConfig { cases: 10_000, failure_persistence: None, ..ProptestConfig::default() })]

        #[test]
        fn a_generated_program_always_yields_a_well_formed_graph(plan in plan()) {
            let (map, heads) = plan.build();
            prop_assert!(is_well_formed(&map, &heads));
        }
    }

    #[test]
    fn a_plan_can_hold_a_disjoint_pair_and_the_empty_head() {
        let plan = DagPlan {
            ops: vec![Op::root(0), Op::root(1)],
            heads: vec![None, Some(0), Some(1)],
        };
        let (map, heads) = plan.build();
        assert_eq!(heads[0], None);
        assert_eq!(
            crate::dag::meet(&map, heads[1].as_ref(), heads[2].as_ref()),
            Ok(None)
        );
    }

    #[test]
    fn the_generator_reaches_the_empty_head_and_a_disjoint_pair() {
        let mut runner = TestRunner::deterministic();
        let (mut empty, mut disjoint) = (false, false);
        for _ in 0..500 {
            let plan = plan().new_tree(&mut runner).expect("a tree").current();
            let (map, heads) = plan.build();
            empty |= !plan.ops.is_empty() && plan.heads.iter().any(Option::is_none);
            for a in heads.iter().flatten() {
                for b in heads.iter().flatten() {
                    disjoint |= a != b && crate::dag::meet(&map, Some(a), Some(b)) == Ok(None);
                }
            }
        }
        assert!(empty, "no generated plan had an empty head");
        assert!(disjoint, "no generated plan had a disjoint pair");
    }

    #[test]
    fn a_violated_law_shrinks_to_the_fewest_operations_that_still_fail() {
        let mut runner = TestRunner::new(Config {
            failure_persistence: None,
            ..Config::default()
        });
        let outcome = runner.run(&plan(), |plan| laws::idempotent::<BrokenMeet>(&plan));
        match outcome {
            Err(TestError::Fail(_, minimal)) => assert_eq!(minimal.ops.len(), 1, "{minimal:?}"),
            other => panic!("the broken meet should have failed the property: {other:?}"),
        }
    }
}
