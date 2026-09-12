# Simplify 01 — the rules and the loop: raise the limits, fix the citations, stop paying twice

status: done
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

Every other plan in this series is blocked on two rules and one default. `Metrics/ClassLength: 125`
with `MethodLength` at RuboCop's bare default of 10 has manufactured 31 self-reopening files and 61
comments explaining which cop shaped the code; the one-spec-file-per-code-file rule means every class
merge also needs a spec merge; and `LAIN_SPEC_WORKERS` is exported nowhere, so the whole suite runs
at the worker count the performance doc names as the worst measured. This plan lifts those, fixes
five dangling citations to a design document that does not exist, and stops CI running the full suite
twice per push.

Delivers: new `Metrics/*` limits with an SRP-based rule replacing "never loosen"; a spec-mirror rule
that permits a merge; `LAIN_SPEC_WORKERS=12` in force; one suite run per CI push instead of two; a
working `commit-msg` hook; a shared Cargo target directory; 49 landed chunk docs archived; and
CLAUDE.md's stale figures corrected.

## Grounding

Verified 2026-09-12 against the working tree at `d2bb133c`.

**What `.rubocop.yml` actually configures.** Exactly **four** `Metrics/*` cops, and there is no
`.rubocop_todo.yml` (asserted at `.rubocop.yml:1-3`):

| lines | cop | keys |
|---|---|---|
| 119-123 | `Metrics/BlockLength` | `Exclude: [spec/**/*_spec.rb, spec/support/**/*.rb, *.gemspec]` |
| 133-135 | `Metrics/ModuleLength` | `Exclude: [spec/**/*_spec.rb]` |
| 143-144 | `Metrics/ParameterLists` | `CountKeywordArgs: false` |
| 160-161 | `Metrics/ClassLength` | `Max: 125` |

So `MethodLength` (10), `AbcSize` (17), `CyclomaticComplexity` (7) and `PerceivedComplexity` (8) all
run at RuboCop defaults. `ClassLength`'s rationale at `:146-159` records it was already raised
**110 → 125 on 2026-08-28**, citing `planning/specs/chunk-review-missing-objects.md` — so raising it
is a precedent this plan follows, not one it sets. `Layout/LineLength: Max: 120` at `:137-138`.

**What the limits produced.** **31 files in `lib/` reopen their own class or module mid-file.** The
worst are `review/docent.rb` (six halves at :84, :475, :608, :703, :811, :904), `supervisor.rb`
(five `Supervisor` halves plus three `Retirement` halves), and `supervisor/restart.rb` (four each).
`lib/lain/timeline.rb` — CLAUDE.md's own comment-density exemplar — has three (:22, :267, :320).

The idiom is a stock sentence, originated in `frontend/tty.rb:371-373` and then cited by name:
*"Reopened rather than nested in TTY's own class body -- the shutdown.rb idiom, which keeps each body
within Metrics/ClassLength instead of loosening it."* Thirteen files carry a variant.
`timeline.rb:36-41` gives a different and sharper reason: an inline referential-integrity clause is
*"enough to push this class through `Metrics/ClassLength`, whose only honest fix would be extracting a
collaborator that has no separate responsibility."*

**61 comment lines across 51 files** name a `Metrics/*` cop as the reason code is shaped as it is.
Two name CLAUDE.md as the rule's source: `tools/ast_search.rb:231` (*"CLAUDE.md: extract a
collaborator, never loosen a..."*) and `compaction/source.rb:166` (*"which CLAUDE.md answers with an
extraction"*).

**The splitting broke YARD — but the `AllowedConstants` list is not the evidence, and an earlier draft of
this plan got that wrong.** `.rubocop.yml:48-69` says the 33 entries exist for the **`Data.define` reopen
trap** — `Foo = Data.define(...)` then `class Foo` for the constants a `Data.define` block cannot hold —
and that a comment on the reopen is impossible because *"YARD attaches it to the same namespace and keeps
the LAST docstring… That was the live defect this list exists to have fixed."* The list is further curated
for a second reason: *"Only names that appear ONCE in `lib/` are listed: a reopened class whose bare name
recurs (Input, Report, Decision, Outcome, Entry, Call, Reply) would blind the cop repo-wide."*

The three classes split **for `Metrics/ClassLength`** — `Tool::Input`, `Tools::Subagent`,
`Frontend::Completion` — carry a same-line `# rubocop:disable Style/Documentation` **instead of a list
entry**, and are explicitly not in it.

**So raising `ClassLength` removes the reason for zero of the 33 entries.** A card to prune them would
have had nothing to prune and would have passed trivially. The pruning that *is* available belongs to
simplify-04 and simplify-07, where classes actually stop being reopened, and those plans **report**
removable entries rather than editing the list — see their Integration checks.

**The spec-mirror rule is not its own bullet.** It is a sub-clause of the `LAIN_SPEC_WORKERS` bullet,
`CLAUDE.md:59-63`, and the relevant sentence is line 61: *"never shard a spec to game the packer —
one spec file per code file at the mirrored path."* Editing it means editing that bullet, not
deleting a paragraph.

**The worker default.** `Rakefile:76-81` reads `LAIN_SPEC_WORKERS` and otherwise returns
`[physical_cores - 1, 1].max`. The variable is exported in **no** file — not `.envrc`, not
`.github/workflows/main.yml`. `docs/spec-suite-performance.md` names `physical - 1` as the worst
count tried.

**CI runs the suite twice.** `.github/workflows/main.yml` has two jobs. `build` (:11-37) ends at
`:36-37` with `run: bundle exec rake`, and `Rakefile:126` is
`task default: %i[compile spec rubocop]` — **serial** `spec` via `RSpec::Core::RakeTask` at
`Rakefile:6`. `lint` (:39-65) ends at `:65` with `pre-commit/action@v3.0.1`, whose `ruby-checks`
hook (`.pre-commit-config.yaml:72-77`) runs `bundle exec rake compile check`, and `Rakefile:97` is
`multitask check: %i[pspec rubocop]` — the **parallel** suite plus whole-repo RuboCop. Both jobs
install nvim and tmux from tarball via `./.github/actions/spec-binaries`.

**The commit-msg hook has never run.** `.pre-commit-config.yaml:4` declares
`default_install_hook_types: [pre-commit, commit-msg]` and `:112-117` declares `lint-commit-msg`
with `stages: [commit-msg]`, but there is no `.git/hooks/commit-msg`. The config's own comment
(`:110-114`) predicts this: an existing checkout needs one `pre-commit install` re-run. CI does not
cover it either — `pre-commit/action` defaults to `--hook-stage pre-commit`.

**Two staged-only hook precedents exist.** `yard-lint` (`.pre-commit-config.yaml:92-97`) uses a
`--staged` flag with `pass_filenames: false`, and its rationale (`:79-91`) is exactly the argument a
new density check needs: *"58 duplicate-namespace cases predate this hook, and gating every commit on
clearing them first would block work that has nothing to do with them."* `gherkin-docs`
(`:104-108`) achieves the same via `files:` plus default `pass_filenames`. Note CI runs
`pre-commit` over `--all-files`, so a `--staged` hook is effectively per-file-scoped there too.

**No Cargo configuration at all.** There is no `.cargo/config.toml` anywhere in the repo and no
`.cargo/` directory. The root `Cargo.toml` is **7 lines** with `[workspace]`, `members` and
`resolver` — no `[profile]` section. `lib/lain/core/child.rb:23` hardcodes
`BINARY = File.expand_path("../../../target/debug/lain-core", __dir__)`, which pins both the layout
and the Cargo profile.

**The missing design plan, cited five times.** `~/.claude/plans/jiggly-greeting-avalanche.md` does
not exist; the plans directory holds `jolly-greeting-bonbon.md` among eleven files. Citations:
`CLAUDE.md:7`, `ROADMAP.md:10`, `ROADMAP.md:1801`, `planning/remaining-work.md:3`, and
**`planning/README.md:4`**, which calls it "the source of truth".

**`rake spec:flakes` cannot pass.** `Rakefile:49-52` defines it;
`docs/toolchain-traps.md:325-334` records that it *"currently exits 1 on EVERY invocation, and it is
the harness, not the suite"* — its own `$HOME`/`XDG_*` rewriting collides with six examples that
assert on `$HOME`. It is still advertised at `CLAUDE.md:40`.

**A spec reads CLAUDE.md, and this is the plan's main hazard.**
`spec/lain/comment_census_spec.rb:261-282` compares `bin/comment-census`'s `SCAN_PATHS` against a
scope sentence parsed out of the prose. The regex is `bin/comment-census:543`:

    SCOPE_SENTENCE = /^\s*-\s+\*\*Scope\*\*.*?: (?<paths>.+)$/

matched against **CLAUDE.md:130** and then `scan(/`([^`]+)`/)`. It breaks if that line's bullet
marker or bolding changes, the colon moves, the three backticked paths are reordered, a fourth
backticked token is added anywhere on the line, or the bullet is split across two lines.

**Where docs and code disagreed, and which won.** CLAUDE.md:115-116 claims `lib/` at 68,713 prose /
44,873 code (1.53:1) and 520 of 709 files; `bin/comment-census` reports 61,518 / 51,296 (1.20:1) and
471 of 773. **The census wins** — it is the tool the rule points at. CLAUDE.md:43 says two opt-in
tiers are excluded by default; eight are. CLAUDE.md:33 quotes `rake pspec` at 21-27s; the balanced
floor at 12 workers is ~42s and the slowest single file is 23.4s, and since the wall is a MAX the
documented figure is now arithmetically unreachable.

## Orchestrator contract (plan-specific only)

- **This plan's scope IS the shared files.** `.rubocop.yml`, `CLAUDE.md`, `Rakefile`,
  `.pre-commit-config.yaml`, `.github/workflows/main.yml`, `.envrc` and a new `.cargo/config.toml`
  are normally orchestrator-owned wiring; here they are task scope. Cards name them under **Files**
  deliberately, and the usual "wiring diffs only" rule is suspended for this plan alone.
- Because of that, **no two cards in this plan may touch the same shared file in the same wave** —
  the wave assignment below enforces it, and it is the reason T1 and T6 are in different waves
  despite having no logical dependency.
- `lib/lain.rb` and `lain.gemspec` remain orchestrator-owned as usual; no card here needs them.
- **Do not run `rake spec:flakes`** at any point, including to check T5's removal. It cannot pass.

## Open decisions

- **The new `Metrics` numbers are a proposal, not a measurement.** T1 sets `ClassLength: 300`,
  `MethodLength: 25`, `AbcSize: 30`, `Cyclomatic: 12`, `Perceived: 14`, derived from the observed
  distribution (p90 file = 133 code lines, max 453). The human reviews these before T1 lands. No
  card is gated on the outcome — a different set of numbers changes T1's diff and nothing else.
- **Whether to add a comment-density check now.** T7 corrects CLAUDE.md's stale figures but does
  **not** add `bin/comment-census --check-density`, because the prose sweep that would make such a
  gate passable is not in this plan. Deliberately deferred; the rule text T7 writes says the cap is
  coming rather than pretending it is enforced.

## Waves

Wave 1: T1, T3, T8
Wave 2: T4 (←T3), T5, T6
Wave 3: T7 (←T1, T5)
Critical path: T1 → T7

**T1 lands alone, in its own commit, and nine other plans unblock on that commit rather than on this
plan.** T1 is one file and raises the `Metrics/*` limits; everything else here is unrelated housekeeping,
and holding 04/05/06/07/09/10/12 behind the archive move and the CI fix would be waiting for nothing.

T4 follows T3 because both edit `.github/workflows/main.yml` and T4's whole subject is the job T3
reconfigures. T7 is last because it rewrites the CLAUDE.md prose describing what T1 and T5 changed;
writing it first would document a state that does not exist yet.

## Tasks

### T1 — Raise the Metrics limits and replace "never loosen" with an SRP test   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `.rubocop.yml`
**Reuse:** `.rubocop.yml:146-159` is the precedent — the same file already records a reasoned
110 → 125 `ClassLength` raise with a linked justification; follow that comment's shape.
`:140-142`'s `ParameterLists` entry is the model for "config encoding a reasoned policy".
**Shared-file wiring:** none (see the Orchestrator contract — `.rubocop.yml` is this card's scope)
**Reachable from:** `bundle exec rubocop`, run by `Rakefile:97`'s `check` and by
`.pre-commit-config.yaml:72-77`; AC 1 and AC 3 are observable from that command

Add explicit `Max:` values for `ClassLength`, `ModuleLength`, `MethodLength`, `AbcSize`,
`CyclomaticComplexity` and `PerceivedComplexity`, each with a one-line reason naming the
distribution it was derived from. Keep `ParameterLists: CountKeywordArgs: false` and the three
existing `Exclude` lists untouched.

This card does **not** un-split any class — that is plans 04 and 07. It only removes the reason the
splits existed, and it must leave the suite and RuboCop green on the tree as it stands.

**Acceptance criteria**

```gherkin
Scenario: the configuration states a limit for every Metrics cop the project relies on
  When rubocop's resolved configuration is inspected
  Then Metrics/ClassLength, ModuleLength, MethodLength, AbcSize, CyclomaticComplexity
       and PerceivedComplexity each have an explicit Max
  And each carries a comment naming why that number

Scenario: the existing tree still passes
  When rubocop runs over the whole repository
  Then it reports no offenses

Scenario: a class between the old and new limits is accepted
  Given a Ruby file defining one class of 200 code lines
  When rubocop inspects it
  Then no Metrics/ClassLength offense is reported

Scenario: a method beyond the new limit is still refused
  Given a Ruby file defining one method of 40 lines
  When rubocop inspects it
  Then a Metrics/MethodLength offense is reported
```
→ spec file: none. This card's ACs are verified by running `bundle exec rubocop` and by two
throwaway fixtures under the scratchpad, not committed. **RuboCop configuration has no spec in this
repo and this card must not invent one** — `spec/lain/comment_census_spec.rb` is the only spec that
reads project config, and it reads CLAUDE.md, not `.rubocop.yml`.

**Escalation triggers**
- If raising a limit causes RuboCop to report a **new** offense of a different cop, stop and report it.
  Do **not** reach for `Style/Documentation`'s `AllowedConstants` list: its 33 entries exist for the
  `Data.define` reopen trap and for bare-name recurrence, **not** for `ClassLength` (`.rubocop.yml:48-69`),
  so nothing this card does makes one removable.
- `.rubocop.yml:207-214` and `:448-449` argue that CLAUDE.md's Metrics rule is *about `lib/`
  objects* and therefore does not govern `RSpec/ExampleLength` or `RSpec/NestedGroups`. If the new
  rule text would make either of those arguments false, stop — the argument is load-bearing for two
  existing config decisions.
- If any file in `lib/` currently sits **above** one of the proposed new limits, stop and report it.
  The measured maximum is 453 code lines in one file, so `ClassLength: 300` should hold — but a
  module or a method could exceed its proposed number, and discovering that during T1 changes the
  number rather than the file.

### T3 — Put the suite on its measured worker count   [wave 1] [risk: low]

**Depends on:** none
**Files:** `.envrc`, `.github/workflows/main.yml`
**Reuse:** `Rakefile:76-81` already reads the variable and needs no change; `.envrc` already exports
`TMPDIR`, `LD_LIBRARY_PATH` and the Ruby pin, so this is one more line in an established list
**Shared-file wiring:** none
**Reachable from:** `bundle exec rake pspec`, via `Rakefile:77`'s
`ENV.fetch("LAIN_SPEC_WORKERS", "")`; AC 1 is observable by running the suite

`.envrc` covers an interactive shell that has `cd`'d in. CI needs it separately because
`.envrc` is **globally gitignored** (`~/.config/git/ignore:30`) and therefore absent from a fresh
checkout — which is also why a worktree gets none of the other three exports, a fact T8 addresses
and this card must not assume away.

**Acceptance criteria**

```gherkin
Scenario: the parallel suite runs at the measured optimum
  Given an interactive shell in the repository
  When the parallel suite is invoked
  Then it runs with twelve workers

Scenario: an explicit override still wins
  Given LAIN_SPEC_WORKERS set to 4
  When the parallel suite is invoked
  Then it runs with four workers

Scenario: CI runs at the same count as a developer
  When the workflow's environment is read
  Then it sets the same worker count as .envrc
```
→ spec file: none — this is environment configuration. Verified by the worker count
`parallel_rspec` prints, and by `Rakefile:77`'s existing behavior.

**Escalation triggers**
- `docs/spec-suite-performance.md` names 12 as measured **on this box**. If CI's runner has fewer
  cores than the local machine, 12 may be wrong there — check the runner's core count before
  setting the same number in both places, and if they differ, set CI's from its own cores and say so.
- If the suite at 12 workers produces a **lower example count** than at 7, stop immediately. Per
  CLAUDE.md:65-66 `parallel_tests` reports only surviving examples, so a dead worker or an OOM kill
  looks like a pass. The count is the check, not the failure count.
- `TMPDIR` is shared mutable state between concurrent agents. Before trusting any red result from a
  worker-count change, confirm `pgrep -cf 'mise/installs/ruby/[0-9.]*/bin/parallel_rspec'` reads 0.

### T4 — Stop CI running the whole suite twice   [wave 2] [risk: low]

**Depends on:** T3
**Files:** `Rakefile`, `.github/workflows/main.yml`
**Reuse:** `Rakefile:97`'s `multitask check: %i[pspec rubocop]` is already the parallel path; the
`default` task just needs to point at the same thing
**Shared-file wiring:** none
**Reachable from:** both `.github/workflows/main.yml` jobs, and `bundle exec rake` locally

`Rakefile:126` becomes `task default: %i[compile pspec rubocop]`, and the `lint` job gains
`SKIP=ruby-checks` so `pre-commit/action` does not run `rake compile check` a second time. Keep both
jobs — `lint` still covers the cargo hooks, shellcheck, `yard-lint` and `gherkin-docs`, none of
which `build` runs.

Note `RSpec::Core::RakeTask.new(:spec)` at `Rakefile:6` stays: `rake spec` remains available as the
serial run, it just stops being what `default` means.

**Acceptance criteria**

```gherkin
Scenario: the default task runs the suite in parallel
  When the default rake task is invoked
  Then the parallel suite runs
  And the serial suite does not

Scenario: the serial suite is still reachable by name
  When the spec rake task is invoked by name
  Then the serial suite runs

Scenario: a CI push runs the suite once
  When the workflow definition is read
  Then exactly one job runs a Ruby test suite
  And the lint job skips the ruby-checks hook
```
→ spec file: none — CI and rake configuration.

**Escalation triggers**
- `.pre-commit-config.yaml:65-71` argues the `ruby-checks` hook exists so compile and the suite
  overlap inside **one** hook, because pre-commit runs hooks serially. If `SKIP=ruby-checks` in CI
  means `rake compile` never runs in the `lint` job and a cargo hook needs the compiled extension,
  stop — the two jobs' dependencies are not as separable as they look.
- If `pre-commit/action@v3.0.1` does not honour a `SKIP` environment variable, do not work around it
  by deleting the hook. Report it; the alternative is a `--hook-stage` change and that is a
  different decision.

### T5 — Retire `rake spec:flakes`, which exits 1 on every invocation   [wave 2] [risk: low]

**Depends on:** none
**Files:** `Rakefile`, `docs/spec-suite-performance.md`, `docs/toolchain-traps.md`;
delete `bin/spec-flakes`
**Reuse:** `docs/toolchain-traps.md:325-334` already contains the diagnosis and becomes the
historical note
**Shared-file wiring:** none
**Reachable from:** `bundle exec rake -T` no longer lists it; AC 1 is observable there

Remove the task (`Rakefile:49-52`) and the 458-line script. Keep the trap entry in
`docs/toolchain-traps.md` as a record of *why* it went, rewritten in the past tense — deleting the
diagnosis along with the tool is how this gets rebuilt with the same defect. `CLAUDE.md:40`'s line
goes in T7, which owns that file.

Also clean `tmp/flakes` (29M) if present; it is gitignored, so this is housekeeping, not a change.

**Acceptance criteria**

```gherkin
Scenario: the broken task is gone
  When rake's task list is read
  Then no spec:flakes task is listed

Scenario: the reason survives
  When the toolchain traps document is read
  Then it records that the flake harness rewrote HOME and XDG paths per fork
  And that this collided with six examples asserting on HOME

Scenario: the performance document no longer points at a missing script
  When the spec-suite performance document is read
  Then it names no bin/spec-flakes
```
→ spec file: none — task and documentation removal.

**Escalation triggers**
- If `bin/spec-flakes` turns out to be referenced by anything other than `Rakefile:49-52` and the
  two docs — a CI workflow, a `.claude/` skill, another `bin/` script — stop and report the caller.
- If the six colliding examples can be identified and the collision is a **spec** defect rather than
  a harness one, that changes the verdict from "retire" to "fix". Report it rather than deciding;
  `docs/toolchain-traps.md:325-334` asserts it is the harness, and contradicting a recorded
  measurement needs the human.

### T6 — Install the hook that has never run, and share one Cargo target directory   [wave 2] [risk: medium]

**Depends on:** none
**Files:** create `.cargo/config.toml`; modify `lib/lain/core/child.rb`,
`spec/lain/core/child_spec.rb`
**Reuse:** `.pre-commit-config.yaml:4` already declares `default_install_hook_types`, so the hook
needs installing rather than configuring; `Paths::NVIM_PLUGIN_ROOT` (`lib/lain/paths.rb:166`) is the
existing precedent for a `__dir__`-relative shipped-asset path, and its comment already says
`Core::Child::BINARY` is "located the same way"
**Shared-file wiring:** none
**Reachable from:** `Core::Child::BINARY` is read when the daemon is spawned, reached from
`Core::Client.start`; AC 3 drives the binary lookup with the environment variable set

Two things, both about a fresh worktree paying for the build twice:

**The hook.** Run `pre-commit install` so `.git/hooks/commit-msg` exists and `bin/lint-commit-msg`
(108 lines) starts running. Note the installed `.git/hooks/pre-commit` currently hardcodes
`INSTALL_PYTHON=/home/joel/.local/...`, a path that no longer exists and survives only via a
`command -v pre-commit` fallback; re-running the installer fixes that too. Since `.git/hooks` is not
tracked, this card's *deliverable* is a documented step plus whatever tracked change makes it
unnecessary next time — not a file diff.

**The target directory.** A **tracked** `.cargo/config.toml` setting `build.target-dir`, because
`.envrc` is globally gitignored and never reaches a worktree. Then `child.rb:23` must consult
`CARGO_TARGET_DIR` (or the configured dir) before falling back to its hardcoded
`../../../target/debug/lain-core`, or every `:core`-tagged spec breaks the moment the target moves.

**Acceptance criteria**

```gherkin
Scenario: a commit message is linted
  Given the hooks are installed
  When a commit is made with a message the linter rejects
  Then the commit is refused
  And the linter's reason is shown

Scenario: two worktrees share one build directory
  Given a Cargo configuration naming a shared target directory
  When the extension is built from a linked worktree
  Then the artifacts land in the shared directory
  And a second worktree's build reuses them

Scenario: the daemon binary is found in the shared directory
  Given CARGO_TARGET_DIR names a directory holding a built lain-core
  When the daemon's binary path is resolved
  Then it resolves inside that directory

Scenario: the fallback still works with no Cargo configuration
  Given no CARGO_TARGET_DIR and no Cargo configuration
  When the daemon's binary path is resolved
  Then it resolves under the repository's own target directory
```
→ spec file: `spec/lain/core/child_spec.rb` (AC 3 and AC 4). AC 1 and AC 2 are verified by hand and
recorded in the commit message — they are git and Cargo behavior, not library behavior.

**Escalation triggers**
- `child.rb:23` hardcodes the **`debug` profile**, not just the directory. If making the directory
  configurable tempts a profile change too, stop — `:core`-tagged specs and `rake core:build`
  (`Rakefile:105-110`, `cargo build -p lain-core`) both assume debug, and changing that is a
  separate decision.
- Concurrent worktrees sharing one target directory contend on Cargo's build lock. That is blocking,
  not corrupting — but if a `:core` spec starts timing out where it did not before, stop and report
  rather than raising the timeout.
- If `pre-commit install` would overwrite a hook containing local modifications, stop. Print the
  existing hook and ask before replacing it.

### T7 — Rewrite the rules CLAUDE.md states, and correct its figures   [wave 3] [risk: high]

**Depends on:** T1, T5
**Files:** `CLAUDE.md`
**Reuse:** `bin/comment-census` is the authority for every density figure this card writes — run it
rather than computing anything by hand
**Shared-file wiring:** none
**Reachable from:** every agent session reads CLAUDE.md; `spec/lain/comment_census_spec.rb:267`
reads it mechanically, and AC 4 is that spec staying green

Five edits:

1. **The Metrics rule (`:73-75`)** becomes an SRP test rather than a prohibition: *a tripped limit is
   a smoke alarm, not a specification; ask whether the object holds one responsibility; if it does,
   raise the limit and say why in the commit; if it holds two, extract the second. The test is SRP,
   not the line count.* It should name the evidence — 31 self-reopening files, 61 comments citing a
   cop, and `timeline.rb` among them — and say that merging those back is the preferred direction.
2. **The spec-mirror sub-clause (`:61`)** becomes "one spec file per public entry point", keeping the
   anti-sharding sentence around it intact, since that sentence is about the packer and stays true.
3. **`rake spec:flakes` (`:40`)** is removed from the suite-command block.
4. **The comment-census figures (`:115-116`)** are replaced with what the census reports, and the
   exemplar sentence is kept — `timeline.rb` at 0.82 prose:code with a 24-line longest block is a
   measurement, not a stale figure.
5. **The opt-in tiers line (`:43`)** says "both" and there are eight. Correct the count and name
   them, or point at `spec/support/tags.rb`.

**Acceptance criteria**

```gherkin
Scenario: the Metrics rule states a test an author can apply
  When CLAUDE.md's RuboCop section is read
  Then it says a tripped limit asks whether the object holds one responsibility
  And it does not forbid raising a limit

Scenario: the spec rule permits a merge
  When CLAUDE.md's testing guidance is read
  Then it asks for one spec file per public entry point
  And it still forbids sharding a spec to game the packer

Scenario: no suite command listed is broken
  When CLAUDE.md's suite commands are read
  Then every command listed can be run
  And spec:flakes is not among them

Scenario: the comment census spec still reads the scope sentence
  When the comment census spec runs
  Then it finds the documented scope
  And that scope equals the checker's scan paths
```
→ spec file: `spec/lain/comment_census_spec.rb` (AC 4 — existing, must stay green). AC 1-3 are prose
assertions verified by reading; they are not specs and must not become specs.

**Escalation triggers**
- **The hazard that makes this card high risk.** `bin/comment-census:543`'s `SCOPE_SENTENCE` regex
  parses **CLAUDE.md:130** — the `- **Scope**` bullet — and
  `spec/lain/comment_census_spec.rb:267-271` compares the result against `SCAN_PATHS`. It breaks if
  that line's bullet marker or bolding changes, the colon moves, the three backticked paths are
  reordered, a **fourth** backticked token appears anywhere on that line, or the bullet wraps to two
  lines. This card edits other parts of CLAUDE.md; if any edit reflows or renumbers that line, run
  `bundle exec rspec spec/lain/comment_census_spec.rb` before continuing.
- `lib/lain/tools/ast_search.rb:231` and `lib/lain/compaction/source.rb:166` quote the old Metrics
  rule *by name* in code comments. Changing the rule makes those two comments describe a policy that
  no longer exists. Do not edit them in this card — report them, so the plan that touches those
  files fixes the comment alongside the code.
- If the census's own figures have moved since this plan was written (2026-09-12: 61,518 prose /
  51,296 code, 471 of 773 files), write what the census says now and note the date. Do not copy the
  numbers from this plan.
- CLAUDE.md line-number references appear throughout these plan documents. If this card's edits shift
  line numbers that a *later* plan's Grounding cites, say so in the commit message — a stale citation
  in a sibling plan is the failure mode `planning/README.md:4` already demonstrates.

### T8 — Archive the landed chunk documents and fix five dangling citations   [wave 1] [risk: low]

**Depends on:** none
**Files:** `git mv planning/specs/chunk-*.md planning/archive/`; modify `planning/README.md`,
`ROADMAP.md`, `planning/remaining-work.md`; modify whichever two specs read a chunk doc as a fixture
**Reuse:** `planning/README.md`'s existing `| [`specs/foo.md`](specs/foo.md) | description |` table
is the index format; the archive move keeps it and points the surviving rows at their new paths
**Shared-file wiring:** none
**Reachable from:** `planning/README.md` is the index a reader enters through; AC 1 is observable
there

**49 landed chunk documents, 63,344 lines** — larger than all the code in `lib/` — move to
`planning/archive/`. The project's own rule (`planning/README.md:24-28`) already says a round's
findings are deleted once discharged because git history is the archive; this applies the same
reasoning to landed plans without deleting them.

Two specs read a chunk doc as a fixture and must be repointed:
`spec/lain/review/deletability_spec.rb:434-462` reads
`planning/specs/chunk-review-surface.md`'s `## Deletion map` section, and
`.pre-commit-config.yaml:104-108`'s `gherkin-docs` hook has `files: '^planning/specs/.*\.md$'`.
**Leave the hook's pattern alone** — new plan docs still land in `planning/specs/`, so it stays
correct; only the moved files leave its scope, which is the intent.

Then fix the five citations of `~/.claude/plans/jiggly-greeting-avalanche.md`: `CLAUDE.md:7`,
`ROADMAP.md:10`, `ROADMAP.md:1801`, `planning/remaining-work.md:3`, `planning/README.md:4`.
`CLAUDE.md:7` is T7's file — **leave it to T7** and report the other four as done, so two cards do
not edit CLAUDE.md in the same wave.

**Acceptance criteria**

```gherkin
Scenario: only live plans remain in the specs directory
  When the planning specs directory is listed
  Then it holds no chunk document whose work has landed
  And every document it does hold describes unlanded work

Scenario: the index points at the archive
  When the planning index is read
  Then its rows resolve to files that exist

Scenario: the deletability spec still finds its fixture
  When the deletability spec runs
  Then it reads its deletion map from the path it names

Scenario: no document cites a design plan that does not exist
  When the roadmap and the remaining-work document are read
  Then neither names jiggly-greeting-avalanche
```
→ spec file: `spec/lain/review/deletability_spec.rb` (AC 3 — existing, must stay green).

**Escalation triggers**
- Deciding which of the 65 documents in `planning/specs/` have "landed" is a judgment call. Use each
  document's own `status:` line where it has one. **If a document has no status line, or says
  `in-progress`, leave it in place and list it** — do not infer from the git log.
- `spec/lain/review/deletability_spec.rb` parses a specific `## Deletion map` **section heading**
  out of its fixture. If the moved file's content must change for the spec to keep finding it, stop:
  this card moves files and does not edit their contents.
- If `ROADMAP.md`'s two citations turn out to be load-bearing — naming a milestone table nothing else
  records — stop. Replacing a pointer with nothing loses the reference; the fix may be recovering
  the plan, which is outside this card.

## Integration checks

After the last wave:

- `bundle exec rake pspec` green, **and the example count recorded in the commit message**. No card
  here deletes an example, so the count must be unchanged from the pre-plan baseline. A drop means a
  worker died — per CLAUDE.md:65-66 that presents as a pass.
- `bundle exec rubocop` clean, with **no new `rubocop:disable` anywhere**. T1 exists to remove the
  need for those; adding one would invert the plan.
- `bundle exec yard-lint` over the **whole tree** (not `--staged`), with the defect count compared
  against the pre-plan count — a raised `ClassLength` must not have moved a docstring.
- `pre-commit run --all-files` green, and separately confirm `.git/hooks/commit-msg` now exists and
  that a deliberately bad commit message is refused.
- `bundle exec rake core:build && bundle exec rspec --tag core` after T6, since the daemon binary
  path moved.
- **Manual, human:** read the rewritten CLAUDE.md sections end to end. This plan's deliverable is
  partly prose that other agents will follow literally, and no spec can tell you whether a rule is
  clear. The five dangling citations are the evidence that unread documentation rots silently.
- Confirm one fresh `git worktree add` reaches a green `pspec` using only the documented steps. T6's
  value is entirely in that path, and `.envrc` being gitignored means the documented steps are the
  only steps.

## Execution log

**Base branch: `main`.** Grounding re-verified 2026-09-12 at `d2bb133c`, which is `main`'s head and
the base every card's worktree is cut from. `origin/main` sits at `b1927ce7`, **178 commits behind**
— any worktree forked from the remote would open a tree missing this entire plan's premises, so
worktrees are cut by hand from `HEAD` and re-cut at the top of every wave as landings move it.

No card's grounding had drifted: the four `Metrics/*` cops, `Rakefile`'s worker default and `default`
task, the five `Sensitivity.new` sites, `consolidation.rb`'s one-guard stack, `Backend#initialize`'s
`num_ctx` call, `ancestors` at arity 0 with no block, and the six non-`Lain::Error` classes all read
exactly as documented.

**Two Integration checks cited a `T2` that has no task card.** The Grounding section records why the
card went — raising `ClassLength` makes zero of `Style/Documentation`'s 33 `AllowedConstants` entries
removable, so the card would have had nothing to prune — but the checks below were never updated with
it. Both now stand on their own: the `rubocop:disable` check on T1, and the whole-tree `yard-lint`
check on the docstring hazard a raised `ClassLength` actually carries. A stale enumeration is worse
than a missing one.

### What landed

Baseline before the first landing: **17,942 examples, 0 failures, 14 pendings**, 61s at 12 workers
on `289000e0`.

| card | commit | note |
|---|---|---|
| T1 | `439a30d2` | ClassLength/ModuleLength 300, MethodLength 15, AbcSize 22, Cyclomatic 12, Perceived 12 |
| T3 | `c332c733` | CI sizes from `$(nproc)`; `.envrc`'s `LAIN_SPEC_WORKERS=12` applied by hand |
| T5 | `e0ea1b8e` | task and script gone; two traps recovered into `docs/toolchain-traps.md` |
| T8 | `f555919b` | 44 documents archived, 5 left; six citations repointed |
| —  | `9c82283a` | archive fallout: a fixture path and a `lib/` comment followed the move |

**The Metrics numbers are the human's, not the plan's proposal.** T1 shipped 300/300/25/30/12/14;
the panel replicated the measurement and argued two of those unblock nothing and cannot fire until
well past the observed worst. The human chose the tighter set above. The panel also found the
`AbcSize` entry's stated reason factually false — ABC being `sqrt(A²+B²+C²)`, a constructor with
twelve assignments scores 12.0, not near any limit — and that sentence was deleted rather than
rewritten.

**`.rubocop.yml` is not covered by the suite hook.** `ruby-checks` is `types_or: [ruby, rust]`, so a
commit staging only YAML or markdown never runs `pspec`. That is how `f555919b` landed red: T8 moved
a chunk document that `spec/lain/sensitivity/regions_spec.rb` reads as a fixture by hardcoded path —
one deliberately fake key in 1700 lines of prose, serving as the positive and negative control in a
single assertion. The plan's Grounding named two fixture consumers and this was not one of them.

### Closed

All seven cards landed. Final: `09b19a06` (CLAUDE.md), `6062beba` (CI once per push),
`cd75dd18` (shared build dir), `439a30d2` (Metrics limits), `f555919b`+`9c82283a` (archive),
`c332c733` (worker count), `e0ea1b8e` (flake hunter).

**The rewrite of CLAUDE.md's Metrics rule silently dropped the repo's only ban on an inline
`rubocop:disable`.** `lib/lain/provider/http/error_middleware.rb:9` records a real refactor made on
that sentence's authority — a ten-branch `case` became a lookup table rather than carry a disable —
and a sweep of `lib/`, `exe/` and `spec/` finds zero live inline Metrics disables. This plan's own
Integration checks demanded "no new `rubocop:disable` anywhere" while the rules file no longer said
it. Restored.

**CLAUDE.md's export block, addressed explicitly to non-interactive agents because `.envrc` never
reaches them, did not export `LAIN_SPEC_WORKERS`.** An agent following it verbatim ran at
`physical_cores - 1` — the worst measured count — while reading a timing figure taken at twelve.

**Ten comments naming the retired rule now have a named owner**, and 23 stock-sentence sites are
explicitly marked as needing none: each justifies a class reopen and dies with it when 04 and 07
merge the class back. `exe/lain` ×3, `provider/http/VENDOR.md:103`, `error_middleware.rb:9`,
`spec/lain/seams/capability_degraded_spec.rb:45` and `spec/lain/status_feed/publication_spec.rb:8`
sit in files no later plan opens.

**A hook gap this plan did not close.** `ruby-checks` is `types_or: [ruby, rust]`, so a commit
staging only markdown or YAML runs no suite at all. That is how `f555919b` landed red, and it means
`.rubocop.yml` and `CLAUDE.md` changes are unguarded. Worth a card in a later plan.
