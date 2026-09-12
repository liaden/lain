# Test layout roots + mirror guard — for the project lain is working on

**Status:** landed 2026-09-11, through `chunk-implement-epic.md`. This is a **harness feature**,
not a rule about lain's own `spec/` tree, and lain's own specs stay governed by `CLAUDE.md`.

Two things about what shipped differ from the draft below, and the code wins. **Enforcement is
opt-in:** a target project with no `[tests]` table gets `TestLayout::None`, which refuses nothing
and journals that it was absent — a detected preset would impose level roots on a project that
never declared them and refuse its existing flat specs as stray. And the mirror is computed
**relative to a declared source root**, with the path a refusal names read out of a Prism index of
where the constant is defined, which retires the acronym problem the ACs below work around.

The first draft (2026-08-04) was written against lain's own specs, and our local development
rules stay in `CLAUDE.md`, which this does not change. The facts from that draft that are only
about our repo moved to [`../notes/lain-spec-mirror-drift.md`](../notes/lain-spec-mirror-drift.md).

When lain does TDD in someone else's project, it should know that project's test layout and hold
its own writes to it. That means level roots (unit / seam / integration, each mirroring the source
tree) and a mechanical guard that keeps the mirror.

## Why

Each of these reasons holds for any project, not just ours.

**Navigability.** The mirror makes "run the tests for the file I am editing" answerable by a path,
for the human and for an agent choosing what to run after an edit. It degrades silently: nothing
fails when a test drifts from its subject. An agent writing tests at speed is the fastest drifter
there is.

**It resists one specific failure mode.** File-packing parallel runners (`parallel_tests`,
`pytest-xdist --dist loadfile`) make the longest single file a floor on wall time. Splitting a slow
test file into arbitrary siblings makes a suite *look* faster while the work stays the same. An
agent told to speed the suite up will find that move. Tying tests 1:1 to source means **you cannot
split `foo_spec.rb` into `foo_extra_spec.rb` unless `foo_extra.rb` exists**. "Split the file" then
becomes "extract a collaborator", which is a design act with its own review.

**Level membership becomes structural.** When a tag marks level, a seam test that forgets its tag
is invisible. It runs in the fast inner loop, and nothing notices. With roots, level is a property
of location, and a misplaced file can be detected.

## The layout, as project data

The layout is **data a project declares**, not code lain ships per language. For an RSpec project:

```
spec/unit/**         fast, collaborators doubled; the default inner loop
spec/seam/**         real components, real local resources
spec/integration/**  external services; opt-in
spec/support/**, spec/fixtures/**   exempt
```

Each level root mirrors the source root beneath it. For each language the mapping needs:

- **a source root and suffix:** `lib/` + `.rb`, `src/` + `.py`, `src/` + `.rs`
- **a test-file rule:** `_spec.rb`, `_test.rb` (minitest, under `test/`), `test_*.py` (pytest),
  `tests/*.rs`
- **the level roots and the exempt paths**

**Rust does not fit the file-mirror shape.** Unit tests are inline `#[cfg(test)]` modules and
`tests/` is integration by definition. The mapping must be able to say "unit level is inline; no
file to mirror".

## The rule (the Ruby case, as the worked example)

For each test file under a mirrored level root:

1. The top-level `describe` argument is a **constant**, not a string.
2. That constant is **defined in the file at the mirror path**:
   `spec/unit/app/models/order_spec.rb` → `app/models/order.rb`.
3. That source file **exists**.
4. Any level tag present agrees with the root.

Rule 2 says "defined in the mirrored file", not "named by the mirrored path". The spec mirrors the
**file**. A constant-equals-path rule false-flags every file that defines more than one constant.

**Derive constant → path, never path → constant.** Without a configured acronym table,
`"CLI".underscore.camelize` yields `Cli`, so a path → constant check false-flags every acronym
namespace. `"App::CLI::Backend".underscore` → `app/cli/backend` is exact and needs no table. Other
languages need the same direction check (a Python module path is already the name, which is why
the rule belongs in the mapping, not in the guard).

**Exemptions are paths, never file contents:** support, fixtures, whole-tree checks that describe
an invariant rather than a class, and throwaway spikes. With roots, no exemption needs to parse a
file.

## Questions the harness framing raises

1. **Where the layout is declared.** `.lain/config.toml` is read by `Config.load`
   (`lib/lain/config.rb:81`). It understands `[epics]`, `[approval]`, `[sensitivity]` and `[shell]`,
   and tolerates any other top-level table (`config.rb:16-20`). A `[tests]` table reading into one
   small class is the house shape (`Sensitivity::Rules`, `Shell::Exclusions`). Whether it is read by
   `.load` or by a separate reader depends on how loud a typo must be; `config.rb:26-29` records
   that choice for the other two.
2. **Detection versus declaration.** `Grader::TestHarness::Adapter.detect`
   (`grader/test_harness/adapter.rb:63`) probes for rspec, jest and pytest, and only rspec actually
   runs (`:48`). Defaults per framework could come from detection, with the table as the override.
   The same question is open in `grader-from-gherkin.md:77`.
3. **Where lain enforces it.** Candidates:
   - A tool-phase middleware that refuses or redirects a `write_file`/`edit_file` creating a test
     file at a path the rule rejects, the way `RefuseSecretWrites` refuses before the write
     (`middleware/refuse_secret_writes.rb:8-13`). A refusal should name the path the file should
     occupy, so the model can fix itself.
   - A check at a gate or at land, over the whole diff.
   - Both: the middleware for new files, and the gate for the backlog.
4. **Generated tests must land at the right path.** `Gherkin::TestGeneration` names the framework
   in the prompt and leaves detection to the caller (`gherkin/test_generation.rb:14-16`). The
   `gherkin-tests` skill prompt says nothing about where a test file goes. Generated tests should be
   placed by the same rule the guard checks, and the prompt should say the path rather than hope.
5. **Level feeds the test run.** `Grader::TestHarness` runs one command
   (`test_harness.rb:89`, `adapter.rb:91-92`). Grading a unit-level acceptance criterion should run
   the unit root, not everything. That needs a root argument to reach the adapter's command.
6. **Mixed-level files.** A file holding both unit and seam examples is common, and in lain's own
   repo it is 32 files. Choose one: split it into two files (breaks "one test file per source
   file"), let a file carry a level per example (the tag again, which roots were meant to replace),
   or say that a file's level is its slowest example.
7. **The backlog.** A target project will already have drift. Choose one:
   1. **Staged files only:** holds new work to the rule and leaves old drift alone.
   2. **Whole tree plus an allowlist:** makes the debt visible, and the list shrinks as it is paid.
   3. **Whole tree, fix first:** cleanest, largest blast radius, and a big unrequested diff in
      someone else's repo.

   For a harness working in someone else's repo, option 1 is the likely default and option 2 an
   opt-in.

## Acceptance criteria (against a fixture project)

```gherkin
Scenario: a unit test at the mirror path passes
  Given a fixture project declaring the rspec layout with source root "app"
  And app/models/order.rb defines Order
  And spec/unit/models/order_spec.rb describes Order
  When the guard runs
  Then it passes

Scenario: a split sibling is refused, naming the right path
  Given spec/unit/models/order_spec.rb already exists
  And the agent writes spec/unit/models/order_extra_spec.rb describing Order
  And app/models/order_extra.rb does not exist
  When the write reaches the tool phase
  Then it is refused
  And the refusal names spec/unit/models/order_spec.rb

Scenario: a constant defined in a differently-named file is accepted
  Given app/models/records.rb defines OrderTransition
  And spec/unit/models/records_spec.rb describes OrderTransition
  When the guard runs
  Then it passes

Scenario: acronym namespaces are not false positives
  Given app/cli/backend.rb defines CLI::Backend
  And spec/unit/cli/backend_spec.rb describes CLI::Backend
  When the guard runs
  Then it passes

Scenario: a seam under the unit root is refused
  Given spec/unit/models/order_spec.rb carries :seam
  When the guard runs
  Then it fails, naming spec/seam/ as the correct root

Scenario: a generated test lands where the guard accepts it
  Given approved criteria for Order at the unit level
  When tests are generated for them
  Then the generated file is at spec/unit/models/order_spec.rb

Scenario: a project with no declared layout is not guarded
  Given a fixture project with no [tests] table and no detectable framework
  When the agent writes any test file
  Then the guard does not refuse it
  And the session journal records that no layout was in force
```

## What this does not catch

A session can still split a test into siblings **if it also splits the source**. The rule requires
a real source file, not that the split be wise. That is the intended boundary: the cheap move is
impossible, and the expensive but legitimate one stays available where review applies.

It also does not catch a test that mirrors correctly but tests the wrong thing. Nothing mechanical
will.

## Related

- `planning/specs/grader-from-gherkin.md`: generation and running in the user's framework.
- `lib/lain/grader/test_harness/adapter.rb`: framework detection and the one command it runs.
- `lib/lain/middleware/refuse_secret_writes.rb`: a tool-phase write refusal, the enforcement shape.
- `lib/lain/config.rb`: where a `[tests]` table would be read.
