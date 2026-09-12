# Simplify 11 — retire the manifest that every new unit has to edit

status: draft — **do not run in this series**; see Open decisions
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

`lib/lain.rb` is the most-churned file in the repository — **82 commits in nine weeks for 99 code
lines of pure require list** — because CLAUDE.md's centralized-requires rule makes it a serialization
point every new unit must edit. That rule also forces a committing constraint, has caused at least one
merge to trip a cop neither branch crossed, and is **directly producing duplication**: one view cannot
read a sibling's constant because the manifest loads it first, so the constant is written twice in
Ruby and a third time in Lua.

Zeitwerk is already in the bundle and only 17 of 749 files need an inflection. This plan replaces the
manifest with a loader, deletes 24 index files, and removes the rules the manifest existed to support.

Delivers: **−748 `require_relative` lines and −24 files**; `lib/lain.rb` from 99 code lines to ~40; the
commit-ordering rule gone from CLAUDE.md; and four documented load-order workarounds in the bench
removed.

## Grounding

Verified 2026-09-12 against the working tree at `d2bb133c`. `code` is non-blank, non-comment.

**The churn, stated honestly.** `lib/lain.rb`: **82 commits, 99 code lines, +199/−53** — the highest churn
of any file in `lib/`, for a file containing no logic. `lib/lain/cli.rb` is **#4 at 42 commits**, also a
pure require list.

An earlier draft compared 82 against `tools/subagent.rb`'s 35 and called it 2.3×. That was the wrong
comparison: `lib/lain/cli/wiring.rb` is **#2 at 55** and holds real behaviour. **The honest figure is 82 vs
55 — 1.5×** — and a good deal of `lain.rb`'s churn is "a new unit shipped", which is churn you want
recorded somewhere.

**What the rule costs beyond churn.** Three things, each documented in the repo:

1. **It forces a committing constraint.** CLAUDE.md's *"a new lib file, its index/manifest line, and its
   spec land in the SAME commit"* exists because pre-commit stashes unstaged tracked changes, so an
   unstaged manifest edit is stashed to `HEAD` while untracked specs still run and the spec's constant
   does not resolve.
2. **It has already caused a merge failure.** `.rubocop.yml:153-159` records two branches independently
   growing `Wiring` to exactly 110 and the merge tripping a ceiling **neither branch crossed**.
3. **It produces duplication.** `frontend/neovim/inbox_view.rb:83-87`, verbatim: *"Spelled here rather
   than read off `{ApprovalView::INDENT}` because `neovim.rb`'s manifest loads this file FIRST, so a
   constant reference would resolve before that class exists."* The same indent is then encoded a third
   time as `runtime/05_records.lua:26`'s `CONTINUATION`.

**Four more load-order workarounds, all in the bench, all self-documenting.** `bench` is required at
`lib/lain.rb:89` and `arm` at `:102`, thirteen entries later, **because `bench/session` is needed
early** — and that inversion forces:

- `bench/live_arms.rb:9-11` — `LiveArms` must be a module-with-builder rather than a constant map.
- `bench/live_arms.rb:70-80` — `Seams` defaults `grading:` and `layout:` to **nil** rather than to the
  objects they stand for, because *"`bench` loads BEFORE `arm` and `grader`, so a default naming either
  here would be a boot-time NameError."*
- `bench/altitude.rb:24-28` — `METRICS` may name no constant at class-body time.
- `compare.rb:214-217` — pins `compare` before `bench`.

**Feasibility.** **Zeitwerk 2.8.2 is already in `Gemfile.lock`**, transitively via ActiveSupport. Of 749
files in `lib/`, only **17 have a real name mismatch**: 2 acronyms (`CLI`, `TTY` — two inflector lines),
`version.rb`, and ~13 grouped-value files where one file defines several constants
(`telemetry/switches.rb`, `review/records.rb`, `epic/records.rb`), handled by `loader.ignore` plus an
explicit require. **24 files are pure index files that delete outright.**

**The rule's stated benefit, and its replacement.** CLAUDE.md argues *"that one ordered list is where a
circular dependency has to show itself, because scattered `require` hides cycles behind idempotent early
returns."* That is true and the replacement must be at least as strong: `loader.eager_load` in one spec
loads every constant and raises on a cycle — which catches the same thing without requiring a human to
maintain a topological order by hand.

**The blocker, and it is real.** `lib/lain.rb:146` is `Lain::Algebra.registry.seal`, the **last
statement in the file**, and `:141-145` states the property: *"Every claim lain makes about its own
algebra has now been filed by the class body that makes it, so the process-wide registry closes."*

**Under Zeitwerk, class bodies do not run until a constant is referenced.** So a seal at require time
would close an **empty** registry, and `spec/algebra_laws_spec.rb` would sweep nothing while passing.
Filed today: 24 claims and 5 refutations. This is the one place the manifest is doing real work that
autoloading cannot replicate, and the plan must answer it explicitly rather than discovering it at T2.

Two further load-time facts in the same file: `:120-135` requires `lain/lain` (the compiled extension)
and **re-raises `LoadError`** with a build instruction, because there is no degraded mode —
`canonical.rb:56` calls `Ext.blake3_hex` and `Canonical.digest` is on every Event path. And `:139-140`
is a bare `module Lain; end` re-open carrying the project's one-line purpose statement.

**Two specs depend on load-time completeness.** `spec/algebra_laws_spec.rb` sweeps the sealed registry.
`spec/value_object_shareability_spec.rb` is **25 lines** and sweeps **267 value classes** asserting
`Ractor.shareable?` — an enumeration that only works if every class is loaded.

**And the empty-registry guard already exists.** `spec/algebra_laws_spec.rb:225-229`:

    # An empty registry would satisfy every "all declarations are covered"
    # phrasing vacuously, which is the one way this whole file could go green
    # while proving nothing.
    it "makes at least one claim" do
      expect(registry.to_a).not_to be_empty
    end

An earlier draft of T2 called that guard *"new and the registry half's real deliverable"*. It is neither.
This is **good news for the plan's safety** — a Zeitwerk-induced empty registry reddens rather than passing
green — and **bad news for the plan's confidence**, since its most emphasised card was arguing for
something already built. Note also that `Registry#seal` **is** `freeze` (`algebra.rb:205`, "The freeze IS
the seal") over a process global, so an "empty sealed registry" cannot be constructed without the injected
registry seam at `algebra.rb:306`, which that draft never mentioned.

**Where docs and code disagreed.** CLAUDE.md's requires rule describes a discipline the code follows
exactly — there is no drift here. What there is instead is a rule whose *costs* are recorded in five
separate places (`.rubocop.yml:153-159`, `inbox_view.rb:83-87`, and the three bench comments) while the
rule itself records only its benefit. This plan does not claim the rule was wrong when written; it claims
the ledger has shifted.

## Orchestrator contract (plan-specific only)

- **This plan's scope is almost entirely shared files.** `lib/lain.rb`, `lib/lain/cli.rb`, the 22 other
  index files, `lain.gemspec`, `.rubocop.yml`, `spec/spec_helper.rb` and `CLAUDE.md` are normally
  orchestrator-owned; here they are task scope. The usual "wiring diffs only" rule is suspended, and the
  wave assignment prevents two cards touching one of them at once.
- **Run this plan alone.** It deletes 748 lines spread across every file in `lib/`. Any other plan in
  flight will conflict on almost every file it touches, and a rebase across 749 files is not a rebase.
  Sequence it in a window of its own.
- **The registry's close is part of T2, not a card of its own.** `lib/lain.rb:146` is the manifest's last
  statement, so removing the manifest and deciding when the registry closes are one change to one load
  sequence.

## Open decisions

- **Eager-load or lazy?** T1 proposes `loader.eager_load` unconditionally, because three separate things
  depend on every class being loaded: the algebra seal (24 claims), the shareability sweep (267 classes),
  and the 28 specs that enumerate `lib/`. Eager loading gives up Zeitwerk's lazy benefit and adds boot
  time to every `lain` invocation and every one of the 12 spec workers. **Measure it in T1 and report the
  number before T2 commits to it.** If the cost is material, the alternative is eager-loading only in
  specs and sealing the registry lazily on first read — which is a weaker guarantee and needs the panel.
- **Whether this plan runs at all — and the panel's answer was no, not in this series.** Its strongest
  concrete deliverable is the duplication at `frontend/neovim/inbox_view.rb:83-87`, and **simplify-07's T7
  removes that without Zeitwerk**, by the mechanism CLAUDE.md's own requires rule already prescribes: a leaf
  loaded before both consumers. T4 below concedes it. Subtract that and the case is 748 require lines, a
  1.5× churn ratio, and four bench awkwardnesses of which three sit in files simplify-08 may delete —
  against a load-order rewrite across 749 files, an eager-load cost paid 12× per suite run, an `ignore` list
  whose size is *"an estimate"*, and the seal. **If it runs, it runs last, alone, after 12/13/14, with T1's
  measurement reported before T2 is authorised.**
- **Whether `CLAUDE.md`'s requires rule is replaced or deleted.** T6 replaces it with a Zeitwerk-shaped
  rule (naming conventions, where an inflection goes, what `ignore` is for). Deleting it outright would
  leave nothing saying how a new file is found.

## Waves

Wave 1: T1
Wave 2: T2, T3
Wave 3: T4, T5
Critical path: T1 → T2 → T4

T2 owns the registry's close as well as the manifest's removal, because the manifest's **last statement**
is the seal — they are one change to one load sequence, and splitting them would leave the registry either
empty or double-sealed.

## Tasks

### T1 — Stand the loader up beside the manifest, and measure it   [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain.rb` (add the loader, keep every existing require), `lain.gemspec`;
create `spec/zeitwerk_spec.rb`
**Reuse:** Zeitwerk 2.8.2 is already resolved in `Gemfile.lock` via ActiveSupport — this makes the
dependency explicit in the gemspec rather than adding one
**Shared-file wiring:** none — `lib/lain.rb` is task scope for this plan
**Reachable from:** `require "lain"` is the entry point for `exe/lain` and every spec; AC 1 asserts both
loading paths agree, which is the only check that matters while both exist

Add the loader with its inflections and `ignore` list, `eager_load` it, and **keep every existing
`require_relative`**. Zeitwerk's `eager_load` over an already-loaded tree is a no-op, so the two coexist
and the diff is additive and revertible.

Then **measure**: boot time for `require "lain"` before and after, and the `pspec` wall at 12 workers
before and after. Eager loading 749 files is not free, and `require "lain"` already allocates ~701K
objects.

The 17 mismatches: 2 acronym inflections (`CLI`, `TTY`), `version.rb`, and ~13 grouped-value files that
define more than one constant — those go in `loader.ignore` with an explicit require each, and the card
should list them by name rather than by count.

**Acceptance criteria**

```gherkin
Scenario: every constant the manifest loads, the loader also finds
  Given the loader configured with its inflections and ignores
  When it is eager-loaded over the tree
  Then every constant the manifest defines is defined

Scenario: a file whose name does not match its constant is named explicitly
  When the loader's ignore list is read
  Then every grouped-value file is listed
  And each has an explicit require

Scenario: an acronym resolves
  When the CLI and TTY constants are asked for
  Then both resolve

Scenario: a circular dependency is reported
  Given a deliberately circular pair of files
  When the loader is eager-loaded
  Then it raises, naming both
```
→ spec file: `spec/zeitwerk_spec.rb`

**Escalation triggers**
- **Report the two measurements before anyone proceeds to T2.** If eager-loading adds materially to boot
  — paid once per `lain` invocation and once per spec worker, so 12× on every `pspec` — the plan's shape
  changes and the Open decision reopens.
- `lib/lain.rb:120-135` requires the **compiled extension** and re-raises `LoadError` with a build
  instruction. Zeitwerk must not try to autoload `Lain::Ext`; it is a C extension, not a Ruby file. Add
  it to `ignore` and confirm the `LoadError` message still reaches a user with no built `.so`.
- The 13 grouped-value files are an estimate. If the real number is materially higher, the inflection
  story is worse than it looks — each one is a permanent `ignore` entry plus a permanent explicit
  require, which is the manifest coming back in miniature. Report the true list.
- `.rubocop.yml` has 33 `Style/Documentation` `AllowedConstants` entries and several files reopen their
  own class. Zeitwerk expects **one constant per file path**; a file defining `Foo` and reopening it is
  fine, but a file defining `Foo` and `Bar` is not. Cross-check against the 31 self-reopening files.

### T2 — Replace the manifest, registry close included   [wave 2] [risk: high]

**Depends on:** T1
**Files:** modify `lib/lain.rb`; delete 748 `require_relative` lines across `lib/`
**Reuse:** T1's loader, already proven equivalent by its AC 1
**Shared-file wiring:** none — task scope
**Reachable from:** `require "lain"`; AC 1 is that every CLI command still loads, which is the production
check for a load-order change

Remove the manifest and the 748 scattered internal requires. `lib/lain.rb` goes from 99 code lines to
~40: the loader, its inflections and ignores, the extension require with its `LoadError` re-raise
(`:120-135`), the bare `module Lain` purpose statement (`:139-140`), and T5's registry close.

**External gem and stdlib requires stay in the leaf files that use them** — CLAUDE.md's rule that those
document real dependencies is correct and unaffected.

**And the registry's close comes with it, because it is the manifest's last statement.**
`lib/lain.rb:146` is `Lain::Algebra.registry.seal`, resting on the property stated at `:141-145`: *"Every
claim lain makes about its own algebra has now been filed by the class body that makes it."* **Under
Zeitwerk, class bodies do not run until a constant is referenced** — so a seal at require time closes an
**empty** registry and `spec/algebra_laws_spec.rb` sweeps nothing **while passing**. Two shapes, and the
card must pick one and justify it:

1. **Eager-load, then seal.** Keeps the property exactly as stated; costs the eager load T1 measured, on
   every invocation.
2. **Seal on first read.** The registry closes when something first walks it. Weaker — a declaration filed
   after an unrelated read is refused for a reason nobody can see — and it turns a load-time refusal into a
   runtime one.

The Open decisions favour (1) if T1's measurement permits. **Whichever is chosen, the count is the
check**: 24 claims (elementwise 7, meet_semilattice 5, monoid 4, pure 4, attenuation 2,
commutative_monoid 2) and 5 refutations.

**Acceptance criteria**

```gherkin
Scenario: every command loads
  When each top-level command is invoked with a help flag
  Then none fails to load

Scenario: no internal require remains
  When the library is searched for internal relative requires
  Then only the deliberately ignored files have one

Scenario: a fresh process resolves a deeply nested constant
  Given a fresh process that has only required the library
  When a deeply nested constant is referenced
  Then it resolves

Scenario: the shareability sweep still sees every value class
  When the value-object shareability spec runs
  Then it examines the same number of classes as before

Scenario: the sealed registry holds every claim
  When the registry is enumerated after load
  Then it holds twenty-four claims and five refutations

Scenario: an empty registry is still refused
  Given the law sweep
  When it runs against a registry holding no claims
  Then it fails, saying no claim was made
```
→ spec files: `spec/zeitwerk_spec.rb` (AC 2, AC 3), `spec/value_object_shareability_spec.rb` (AC 4 —
existing, and the count is the check), `spec/algebra_laws_spec.rb` (AC 5, and **AC 6 is new and is the
registry half's real deliverable**), plus a CLI spec for AC 1

**Escalation triggers**
- **`spec/value_object_shareability_spec.rb` is 25 lines sweeping 267 value classes.** If eager loading
  is not in force when it runs, it will sweep fewer and **still pass** — the classic silent-enumeration
  failure. AC 4 compares the count, and the count is the only thing that catches it.
- **The 28 specs that enumerate `lib/`** (9,271 code lines) read files from disk rather than constants, so
  most are unaffected. But any that enumerate **loaded constants** rather than paths will see a different
  set. Check `spec/journalable_surface_spec.rb` and the other registry sweeps specifically.
- Deleting 748 lines across 749 files touches almost every file in `lib/`. **Any other plan in flight
  will conflict.** Confirm nothing else is open before starting.
- **AC 6 is a guard that already exists** (`spec/algebra_laws_spec.rb:229`) and this card must not claim
  credit for it. Its job is to confirm the guard still *fires* under autoloading — which is the one thing
  Zeitwerk could break about it. Note `Registry#seal` is `freeze` over a process global, so exercising the
  empty case needs the injected-registry seam at `algebra.rb:306`.
- **If the seal cannot be made to work under autoloading in either shape, stop the whole plan.** The
  registry is how 24 algebraic claims are held to their laws, and no amount of require-line deletion is
  worth losing it silently.
- simplify-09's T3 trims the registry's production surface and its T4 moves three of the five
  `meet_semilattice` claims onto operation objects. If 09 has landed, **the expected counts in AC 5 are
  different** — read the registry rather than copying numbers from this plan.
- If a file turns out to depend on load *order* rather than on a constant being defined — a monkey-patch,
  a `Module#prepend`, an `ActiveSupport::Concern` whose `included` hook must run before something else —
  autoloading will not preserve it. `active_support/core_ext` is one known case: CLAUDE.md records that
  it raises unless `require "active_support"` comes first, and that is an **external** require, so it
  stays in `lib/lain.rb` explicitly.

### T3 — Delete the twenty-four index files   [wave 2] [risk: medium]

**Depends on:** T1
**Files:** delete `lib/lain/cli.rb` and the 23 other pure index files; modify any file that referenced
one as a namespace declaration
**Reuse:** Zeitwerk defines an implicit namespace for a directory with no matching file, so
`lib/lain/cli/` alone gives `Lain::CLI` — the index file's namespace declaration is redundant
**Shared-file wiring:** none — task scope
**Reachable from:** every namespace these files declare; AC 2 asserts each still resolves

Twenty-four files whose whole content is a `module X; end` plus requires. Zeitwerk supplies the namespace
from the directory.

**Two are not purely indexes and need reading first.** `lib/lain/cli/epic_driver.rb` is 16 lines with an
**empty module body** and five requires — simplify-04's T3 deletes it, so coordinate. And several index
files carry a **docstring** that is the only documentation of the namespace; Zeitwerk's implicit namespace
has nowhere to put one, so either the docstring moves to a representative class or the file survives as a
documentation-only namespace declaration. **Say which for each of the 24.**

**Acceptance criteria**

```gherkin
Scenario: every namespace still resolves
  Given a fresh process that has only required the library
  When each former index namespace is referenced
  Then it resolves

Scenario: a namespace's documentation survives
  When the documentation is generated
  Then every former index namespace has a description

Scenario: no index file remains that only requires
  When the library's files are searched for a body of nothing but requires
  Then none is found
```
→ spec files: `spec/zeitwerk_spec.rb` (AC 1, AC 3); AC 2 verified by `bundle exec yard-lint` over the
whole tree

**Escalation triggers**
- `.pre-commit-config.yaml:92-97`'s `yard-lint` runs `--staged` only, so a documentation defect this card
  introduces across 24 files **will not be caught at commit time**. Run it whole-tree.
- An implicit namespace is a plain `Module`. If any of the 24 declares a namespace that is a **class**, or
  that includes something, or that defines a constant alongside the requires, it is not a pure index —
  leave it and say so.
- simplify-04's T3 also deletes `cli/epic_driver.rb`. If both plans are open, one of them will find the
  file gone; that is harmless but should be noted rather than treated as a surprise.

### T4 — Remove the load-order workarounds the manifest forced   [wave 3] [risk: medium]

**Depends on:** T2
**Files:** modify `lib/lain/bench/live_arms.rb`, `lib/lain/bench/altitude.rb`,
`lib/lain/compare.rb`, `lib/lain/frontend/neovim/inbox_view.rb`; modify the corresponding spec files
**Reuse:** the four workarounds each name their own cause in a comment, so each comment becomes the
record of why it went
**Shared-file wiring:** none
**Reachable from:** `LiveArms.build` is on the `bench arms` path; `inbox_view` renders on the live editor
path. AC 1 drives `bench arms`; AC 3 drives the editor.

Four workarounds whose stated reason is gone:

- `live_arms.rb:9-11` — `LiveArms` can become a constant map rather than a module-with-builder.
- `live_arms.rb:70-80` — `Seams` can default `grading:` and `layout:` to the objects they stand for,
  rather than to `nil` resolved in a method body.
- `altitude.rb:24-28` — `METRICS` can name constants at class-body time.
- `compare.rb:214-217` — the pin of `compare` before `bench` goes.

And the fifth, which is the most valuable because it removes a **duplication** rather than an awkwardness:
`inbox_view.rb:83-87` can read `ApprovalView::INDENT` instead of respelling it. **But simplify-07's T7
may already have solved this** by extracting a shared fold leaf — if so, this card confirms the leaf is
still the right shape under autoloading and does nothing else.

**Acceptance criteria**

```gherkin
Scenario: the arms comparison still runs
  Given an arms fixture
  When the arms report is built
  Then it runs and reports

Scenario: an arm seam's defaults name real objects
  When a seam is built with no grading
  Then its grading is the pass-through, not nothing

Scenario: the two views agree on one indent
  Given the approval view and the inbox view
  When each folds a long row
  Then both indent by the same prefix
  And that prefix has one definition in the library

Scenario: no comment claims a load-order constraint that no longer exists
  When the library is searched for comments citing manifest load order
  Then none remains
```
→ spec files: `spec/lain/bench/live_arms_spec.rb` (AC 1, AC 2),
`spec/lain/frontend/neovim/inbox_view_spec.rb` (AC 3); AC 4 is a search recorded in the commit message

**Escalation triggers**
- `Seams`' nil defaults may have acquired a **second** reason since they were written — a nil `grading:`
  might now mean "do not grade" rather than "resolve later". Read `LiveArms.altitude` (`:93-99`), which
  does `seams.grading || Arm::OneShot::PASS_THROUGH`; if nil is meaningful there, the default cannot
  simply become the object.
- simplify-08 may have retired `altitude.rb` entirely. If it has, that workaround is already gone and
  this card shrinks.
- simplify-07's T7 may own the `INDENT` fix. **Do not do it twice** — if the shared leaf exists, this
  card only verifies it.
- A constant map at class-body time is evaluated at **load** time under eager loading. If `LiveArms` as a
  constant map would construct three arms (and therefore an `Arm::Instrument`, and therefore a
  `PriceBook`) at require time, that is worse than the builder. Check what the map would eagerly build.

### T5 — Rewrite the rules the manifest supported   [wave 3] [risk: medium]

**Depends on:** T2
**Files:** modify `CLAUDE.md`
**Reuse:** simplify-01's T7 already rewrote the Metrics and spec-mirror rules in this file — follow its
shape, and check whether it has landed so the two edits do not collide
**Shared-file wiring:** none — task scope
**Reachable from:** every agent session reads CLAUDE.md, and `spec/lain/comment_census_spec.rb` reads it
**mechanically**; AC 4 is that spec staying green

Three edits:

1. **The requires rule** becomes a Zeitwerk-shaped rule: how a constant is found from a path, where an
   inflection goes, what `ignore` is for, and that external gem/stdlib requires still live in the leaf
   files that use them. Keep the rule's *original* insight — that a cycle must be visible — and name
   `loader.eager_load` in a spec as where it is now visible.
2. **The committing constraint** — *"a new lib file, its index/manifest line, and its spec land in the
   SAME commit"* — goes. It existed only because an unstaged manifest edit is stashed to `HEAD` while
   untracked specs run. With no manifest there is no such edit.
3. **The load-order trap** — *"a load-time `NameError` means the entry is too early"* — is replaced by
   whatever T1's `ignore` story actually requires.

**Acceptance criteria**

```gherkin
Scenario: the rule says how a new file is found
  When the requires guidance is read
  Then it explains how a constant is resolved from a path
  And it says where an inflection is declared

Scenario: the cycle guarantee is still stated
  When the requires guidance is read
  Then it names where a circular dependency is caught

Scenario: no rule describes a manifest that does not exist
  When the committing guidance is read
  Then it names no manifest line

Scenario: the comment census spec still reads its scope sentence
  When the comment census spec runs
  Then it finds the documented scope
```
→ spec file: `spec/lain/comment_census_spec.rb` (AC 4 — existing, must stay green). AC 1-3 are prose
assertions verified by reading and **must not become specs**.

**Escalation triggers**
- **`bin/comment-census:543`'s `SCOPE_SENTENCE` regex parses `CLAUDE.md:130`** — the `- **Scope**` bullet
  — and `spec/lain/comment_census_spec.rb:267-271` compares the result against `SCAN_PATHS`. It breaks if
  that line's bullet marker or bolding changes, the colon moves, the three backticked paths are
  reordered, a **fourth** backticked token appears on that line, or the bullet wraps. This card edits
  other sections; if an edit reflows that line, run the spec before continuing.
- simplify-01's T7 edits the same file. If both are open, they will conflict — sequence them, and prefer
  01 first since its edits are to sections this card does not touch.
- CLAUDE.md line numbers are cited throughout the other thirteen plan documents. If this card's edits
  shift them, **say so in the commit message** — a stale citation in a sibling plan is the exact failure
  `planning/README.md:4` already demonstrates with a missing design document.

## Integration checks

After the last wave:

- `bundle exec rake pspec` green, **with the example count recorded**. No card here deletes an example, so
  the count must be **unchanged**. A drop means a file stopped loading and its specs silently vanished —
  which is precisely the failure autoloading makes possible.
- **`bundle exec rspec spec/value_object_shareability_spec.rb` with its class count recorded.** 25 lines
  sweeping 267 classes; a lower count passes silently and is the canary for an incomplete load.
- **`bundle exec rspec spec/algebra_laws_spec.rb` with its claim count recorded.** Same reasoning, and
  T5's AC 4 is the guard.
- `bundle exec rubocop` clean, and confirm the `Style/Documentation` `AllowedConstants` list did not need
  to grow — T3 deletes namespace declarations, and an implicit namespace with no docstring is a
  `Style/Documentation` offence waiting to happen.
- `bundle exec yard-lint` **whole-tree**, compared against baseline. T3 removes 24 docstring homes and the
  hook's `--staged` mode cannot see it.
- **Boot time, recorded twice.** `require "lain"` alone, and `pspec` at 12 workers. T1 measures it; this
  is where the measurement is confirmed against the finished state. Eager loading 749 files is paid 12
  times per suite run.
- **A fresh clone, `bundle install && bundle exec rake compile`, then one `lain chat --help`.** The
  extension require and its `LoadError` message are load-order-sensitive and this plan rewrites the file
  they live in.
- `for cmd in $(lain help | grep -oE '^\s+lain [a-z-]+' ...); do lain $cmd --help; done` — 748 deleted
  requires, and a missing constant surfaces as a command that will not load.
- **Manual, human:** read the rewritten CLAUDE.md requires section. It is prose other agents follow
  literally, and this plan's whole premise is that a rule's ledger shifted — the replacement should say so
  rather than pretending the old rule was wrong.
