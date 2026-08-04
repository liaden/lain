# Spec layout roots + naming guard

**Status:** planned 2026-08-04, not implemented. Two decisions deferred.

Two changes that compose: split `spec/` into per-level roots (`unit/`, `seam/`, `integration/`),
each mirroring `lib/`; then guard the mirror mechanically at pre-commit.

## Why

Three motivations. The second is what prompted this; the third is what the roots buy on their own.

**Navigability.** The mirror is what makes `rspec spec/unit/lain/review/source/local_branch_spec.rb`
the obvious answer to "run the tests for the file I am editing". It degrades silently — nothing
fails when a spec drifts from its subject, so the drift is found only by the next person who guesses
the path and gets nothing.

**Resisting a specific failure mode.** `parallel_tests` packs whole FILES into worker groups, so the
longest single file is a hard floor on wall time (measured 2026-08-04: 18.69 s of a ~19 s wall).
Splitting a slow spec into arbitrary siblings is then a tempting way to make the suite *look* faster
while the work stays the same and the convention degrades.

The rule's force is the 1:1 tie to `lib/`: **you cannot split `foo_spec.rb` into
`foo_extra_spec.rb` unless `lib/.../foo_extra.rb` exists.** Splitting specs requires splitting the
implementation, which is a design act with its own review rather than a packing trick. That turns
"split the file" into "extract a collaborator", which is what `CLAUDE.md` already asks for when an
object is missing.

**Level membership becomes structural.** Today a spec is a seam because its `RSpec.describe` line
carries `:seam`. A seam that forgets the tag is *invisible* — it runs in the default inner loop,
silently costing seconds, and nothing detects it. Under roots, level is a property of location: a
seam in the wrong place is misplaced, not mislabelled.

## The roots

```
spec/unit/lain/**          fast, doubled collaborators; the default inner loop
spec/seam/lain/**          real components, real local resources (git, nvim, the extension)
spec/seam/crosscutting/**  seams belonging to no single subject (today's spec/lain/seams/)
spec/integration/lain/**   live API, costs money, opt-in
spec/guards/**             whole-tree invariants: output discipline, docs naming, algebra laws
spec/spikes/**             throwaway
spec/fixtures/**           unchanged
```

Each of `unit/`, `seam/`, `integration/` mirrors `lib/` beneath its root. That is the whole point —
it is why the split costs nothing in navigability:

| Want | Command |
|---|---|
| Inner loop | `rspec spec/unit` |
| The file I am editing | `rspec spec/unit/lain/review/source/local_branch_spec.rb` |
| Everything about one subject | `rspec spec/*/lain/review/source/local_branch_spec.rb` |
| The slow ones, deliberately | `rspec spec/seam` |

`--tag '~seam'` stops being needed for the inner loop. Keep the tags anyway: they are what
`spec_helper` uses to exclude `:api_integration` and `:core` by default, and belt-and-braces costs
nothing. But **location becomes the source of truth** and the tag becomes a derived assertion — which
is itself checkable (see rule 4).

This supersedes the `CLAUDE.md` line "a seam with an obvious subject stays at its mirror path and
carries the tag". It still sits at its mirror path; the path now starts at `spec/seam/`.

## Measured baseline (2026-08-04, 487 spec files)

| Category | Count | |
|---|---|---|
| Tagged `:seam` / `:api_integration` / `:core` / `:live` | 19 | move to their roots |
| **Exact mirror + constant describe** | **364** | the convention, working |
| **Flat suffixed siblings** | **58** | what the guard is for |
| String describe | 44 | mixed: whole-tree guards, and drift |
| Constant with no `.rb` at the mirror path | 30 | mostly legitimate, see exemptions |

The 58 are shapes like `neovim_request_spec.rb`, `anthropic_parity_spec.rb`,
`gate_regression_spec.rb` — each describing a constant whose mirror path is a *different* file that
also exists.

Some are plain drift, worth fixing on their own merits regardless of this plan:

- `spec/lain/context_spec.rb` describes `Lain::Workspace`
- `spec/lain/approval_spec.rb` describes `Lain::Approval::Queue`
- `spec/lain/friction_spec.rb` describes `Lain::Friction::Report`
- `spec/lain/oracle_spec.rb` describes `Lain::Oracle::Definition`
- `spec/lain/plan_spec.rb` describes `Lain::Plan::Document`

## The rule

For each spec under `spec/{unit,seam,integration}/lain/**`:

1. The top-level `RSpec.describe` argument is a **constant**, not a string.
2. That constant is **defined in the file at the mirror path** — `spec/unit/lain/a/b_spec.rb` →
   `lib/lain/a/b.rb`.
3. That lib file **exists**.
4. Any level tag present agrees with the root (`:seam` only under `spec/seam/`, and so on).

Rule 2 is deliberately "defined in the mirrored file", not "named by the mirrored path".
`spec/unit/lain/epic/records_spec.rb` describing `Lain::Epic::IssueTransition` is correct — the
constant lives in `records.rb`, and the spec mirrors the **file**. A constant-equals-path rule would
flag that and ~30 like it.

Rule 4 is what the roots make possible, and it closes the invisible-seam hole in both directions.

### Direction matters

Derive **constant → path**, never path → constant. No acronyms are configured for
`ActiveSupport::Inflector` here, so `"CLI".underscore.camelize` yields `Cli`, and a path→constant
check produces false positives across every `Lain::CLI::*`, `Lain::Provider::HTTP::*` and
`Frontend::TTY` spec. `"Lain::CLI::Backend".underscore` → `lain/cli/backend` is exact and needs no
acronym table.

## Exemptions

| Exemption | Why |
|---|---|
| `spec/guards/**` | Invariants over the tree, not over a class. A string describe is the honest description. |
| `spec/seam/crosscutting/**` | Seams belonging to no single subject; no constant to mirror. |
| `spec/{unit,seam}/lain/rust/**` | `Lain::Ext::*` is defined in the compiled extension. No `.rb` for rule 3 to find. |
| `spec/spikes/**` | Throwaway by construction. |

Note these are all **path** exemptions now. With roots, no exemption needs to parse a file.

## Deferred decision 1: the 58

Three options; the middle has a direct precedent here.

1. **Staged files only.** Exactly the `yard-lint` hook's answer to the same problem — its comment
   records 58 pre-existing cases and uses `--staged` to "hold new work to the standard from today
   and let the backlog be cleared on its own terms". Catches nothing in untouched files.
2. **Whole tree + allowlist.** Every spec checked, the 58 in a visible file that shrinks. Costs a
   curated todo list; makes the debt legible.
3. **Whole tree, fix all 58 first.** Cleanest end state, largest blast radius.

Option 3 is more attractive than it was: the root migration already moves every spec file, so
fixing the 58 rides along in a change that is touching them anyway. Doing it separately means
touching them twice.

## Deferred decision 2: migration mechanics

487 files move. Mechanical, but it touches things that name `spec/`:

- `.rspec`, `spec/spec_helper.rb` (`--require spec_helper` resolution)
- `Rakefile` — `parallel_rspec spec` becomes per-root, and the runtime log path
- `tmp/parallel_runtime_rspec.log` — invalidated; first run after the move re-levels
- `.pre-commit-config.yaml`, CI paths
- `CLAUDE.md` Testing section, and the `spec/lain/seams/` reference

Use `git mv` so blame survives. Land the move as one commit touching nothing else, so the diff is
reviewable as a pure rename — then the guard, then the 58.

An open sub-question: whether `parallel_rspec` should pack the roots **separately**. Seams are 2.5%
of examples but a large share of wall time; packing them in their own group would stop a seam from
landing in the same worker as the longest unit file. Worth measuring after the move, not assumed.

## Implementation shape

`bin/lint-spec-naming`, following `bin/lint-commit-msg`: plain Ruby, no gem load beyond
`active_support/core_ext/string/inflections`, no network. A `local` pre-commit hook with
`types: [ruby]`.

A script rather than a spec under `spec/guards/`, despite that being the house pattern for
mechanical guards — those check invariants with no legacy backlog, so they run whole-tree
unconditionally. This one needs staged-vs-whole-tree as a flag, which is a script concern. If
deferred decision 1 lands on option 3, that reason evaporates and it should be
`spec/guards/spec_layout_spec.rb` instead, for consistency with `docs_naming_spec.rb`.

### Acceptance criteria

```gherkin
Scenario: a unit spec at the mirror path passes
  Given lib/lain/foo/bar.rb defines Lain::Foo::Bar
  And spec/unit/lain/foo/bar_spec.rb describes Lain::Foo::Bar
  When the guard runs
  Then it exits 0

Scenario: a split sibling is rejected
  Given spec/unit/lain/foo/bar_spec.rb already exists
  And spec/unit/lain/foo/bar_extra_spec.rb describes Lain::Foo::Bar
  And lib/lain/foo/bar_extra.rb does not exist
  When the guard runs
  Then it exits non-zero, naming the file and the path it should occupy

Scenario: a constant defined in a differently-named file is accepted
  Given lib/lain/epic/records.rb defines Lain::Epic::IssueTransition
  And spec/unit/lain/epic/records_spec.rb describes Lain::Epic::IssueTransition
  When the guard runs
  Then it exits 0

Scenario: acronym namespaces are not false positives
  Given spec/unit/lain/cli/backend_spec.rb describes Lain::CLI::Backend
  When the guard runs
  Then it exits 0

Scenario: a seam under the unit root is rejected
  Given spec/unit/lain/review/source/local_branch_spec.rb carries :seam
  When the guard runs
  Then it exits non-zero, naming spec/seam/ as the correct root

Scenario: a seam at its mirror path under the seam root passes
  Given lib/lain/review/source/local_branch.rb defines Lain::Review::Source::LocalBranch
  And spec/seam/lain/review/source/local_branch_spec.rb describes it, :seam
  When the guard runs
  Then it exits 0

Scenario: a whole-tree guard keeps its string describe
  Given spec/guards/output_discipline_spec.rb describes "the output discipline"
  When the guard runs
  Then it is not checked
```

## What this does not catch

A session can still split a seam into siblings **if it also splits `lib/`** — the rule requires a
real implementation file, not that the split be wise. That is the intended boundary: the guard makes
the cheap move impossible and leaves the expensive-but-legitimate one available, where normal review
applies.

It also does not catch a spec that mirrors correctly but tests the wrong thing. Nothing mechanical
will.

## Related

- `spec/docs_naming_spec.rb` — same idea one level up: enforce on the artifact, not in a paragraph.
- `.pre-commit-config.yaml` `yard-lint` hook — the `--staged` precedent and its reasoning.
- Suite timing measurements 2026-08-04 — the file-packing floor this protects against gaming, and
  the n=10 worker finding.
