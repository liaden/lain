# Mutation sweep: survivors and timeouts

Baseline: 148 mutants over `canonical.rs`, `event.rs`, `digest.rs`, `dag.rs` and `graph.rs`:
105 caught, 43 unviable, 0 missed, timeouts counted as killed. `dag.rs` and `graph.rs` kill 100% of
the mutants that build; the address modules have no survivors. The gate compares each file's killed,
unviable and missed counts to `mutants-baseline.txt`.

## Survivors

None.

## Timeouts (scored as killed)

A mutated `dump`, `digest` or `Digest` display makes the property tests fail on every generated
case, and proptest then shrinks each failure for minutes. They fail, but whether a run reports
caught or timeout depends on machine load (7 timeouts at the default 37 second limit, 3 at 300
seconds on the recorded sweep, 0 on the last full run). The baseline file keeps the recorded split
of 3 `canonical.rs` timeouts (`dump` with `"xyzzy".into()`, `digest` with `String::new()` and with
`"xyzzy".into()`), but the gate adds timeouts to caught, so the split cannot flake it.

## Killed by a test added for the sweep

- `event.rs` `EventData::root -> bool` with `true`: `a_child_with_a_render_parent_is_not_a_root`.

## Weakened property check

Run once by hand with a test marked `#[ignore]`, then restored.

- Removing `a_child_with_a_render_parent_is_not_a_root` lets `EventData::root -> bool` with `true`
  survive (1 missed, 2 caught); with the test restored it is caught.
- Removing the commutative, associative and below-both law properties (fixed and generated), then
  every law test in `algebra.rs`, left `dag.rs` and `graph.rs` at 48 caught, 25 unviable, 0 missed:
  their mutants are held by the named fixtures and the corpus, not by the laws. Ignoring 3 escape
  tests in `canonical.rs` also left 0 missed (21 caught, 3 unviable). The law properties kill no mutant that the
  fixtures and corpus miss. That is a finding about where the coverage lives, not a defect.
