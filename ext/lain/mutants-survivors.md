# Mutation sweep: survivors and timeouts

Baseline: 259 mutants over `canonical.rs`, `event.rs`, `digest.rs`, `dag.rs`, `graph.rs`, `nogvl.rs`,
`bm25.rs` and `toml_table.rs`: 194 caught, 59 unviable, 4 missed, 2 timeouts counted as killed. The
address and graph modules, the GVL helper and the BM25 index have no survivors; `dag.rs` and
`graph.rs` kill 100% of the mutants that build. The gate compares each file's killed, unviable and
missed counts to `mutants-baseline.txt`.

| File | Caught | Unviable | Timeout | Missed |
|---|---|---|---|---|
| `canonical.rs` | 20 | 3 | 1 | 0 |
| `event.rs` | 34 | 7 | 0 | 0 |
| `digest.rs` | 9 | 1 | 0 | 0 |
| `dag.rs` | 40 | 11 | 1 | 0 |
| `graph.rs` | 19 | 6 | 0 | 0 |
| `nogvl.rs` | 33 | 28 | 0 | 0 |
| `bm25.rs` | 37 | 1 | 0 | 0 |
| `toml_table.rs` | 2 | 2 | 0 | 4 |

## Survivors

Only `toml_table.rs` has any: 4 missed mutants, each replacing an `ffi` function body with an empty
success (`parse_toml`, `table_to_ruby`, `setting_to_ruby` and `define`). That code is compiled only
into the Ruby extension, so `cargo test` never builds it and the Ruby specs are what kill them. The
misses are permanent and the baseline records them. Every other file has none.

## Timeouts (scored as killed)

A mutated `dump`, `digest` or `Digest` display makes the property tests fail on every generated
case, and proptest then shrinks each failure for minutes. They fail, but whether a run reports
caught or timeout depends on machine load. The recorded sweep, at a 300 second limit, timed out on
`canonical.rs` `digest` with `"xyzzy".into()` and on `dag.rs` `ancestor_of` with `Ok(false)`. The gate adds
timeouts to caught, so the split cannot flake it.

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
