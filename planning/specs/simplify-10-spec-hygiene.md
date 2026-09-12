# Simplify 10 — put specs at their subjects, tag the real resources, and own each sentence once

status: draft
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

The suite is 150,715 code lines against 49,165 in `lib/`, and the obvious conclusion is wrong. Measured,
it runs **6.24 code lines per example, 1.65 expectations per example, and a median of 1.17 examples per
branch-point** in the subject — there is no pool of structural waste to drain, and realistic recovery is
**8-10%, not 50%**. Three plausible hypotheses came back empirically dead.

What is actually wrong is narrower and fixable: three files hold twelve-plus subjects each and one of
them sets the wall-clock floor; the `:seam` tag has grown fourfold in five weeks and 84% of the examples
carrying it touch no real resource; 291 internals reach-ins block the merges other plans want; one guard
spends 6.49 seconds and cannot fail; and 61.7% of `raise_error` assertions pin a message, so every copy
edit is a spec edit.

Delivers: the mis-attributed files split to mirror paths; `:seam` applied per example; a report-only
guard moved to `bin/`; one headless-editor harness; one shared tree index; the confirmed clone clusters
as tables; a core-graph factory; the async ceremony hoisted; and message wording owned once.

## Grounding

Verified 2026-09-12 against the working tree at `d2bb133c`. `code` is non-blank, non-comment.

**Where the 150,715 lines physically sit:**

| | lines | share |
|---|---|---|
| inside `it`/`specify` blocks | 101,428 | **69.0%** |
| helper `def`s | 21,656 | 14.7% |
| `describe`/`context` scaffolding, one-line `let`s | 19,230 | 13.1% |
| `let`/`before`/`around` bodies | 4,580 | 3.1% |

**Three hypotheses to stop spending effort on.** Copy-paste parameterization is **2,573 raw lines
(1.7%)** even relaxing the clone threshold to pairs. Per-file setup boilerplate is **403 lines** (the
`nvim` harness across 22 files) plus 317 in cross-file identical helper `def`s — and CLAUDE.md's
no-internal-requires rule does **not** cause it, because `spec/support` is eager-loaded and globally
included, so the seam exists and is underused. Cross-file prose duplication is **19 lib literals pinned
in ≥2 spec files** (118 pin-pairs).

**The worst per-file ratios are mis-attribution.** **46 spec files carry more than one top-level
`RSpec.describe`, totalling 17,253 code lines.** `thread_view_spec.rb` is not 1,126 lines testing 38 —
it is three top-level describes, 1,657 of them testing `runtime/51_thread.lua` (258 code lines) plus a
92-line spec of `thread_view.rb` at a healthy 2.4:1. Same shape for `telemetry_spec.rb` (an index spec
for a 27-file subtree) and `wiring_spec.rb` (the real unit is `wiring.rb` + `wiring/*` = 1,846 lines,
not 138).

**And `lib/**/*.lua` has no mirror convention at all.** 2,056 code lines of Lua are driven by 37 spec
files totalling 20,229 lines — **9.84:1** — every line charged against Ruby in the headline ratio.

**One file is simultaneously the worst mis-attribution and the wall-clock floor.**
`spec/lain/frontend/neovim_runtime_spec.rb` (note: **not** under `spec/lain/frontend/neovim/`) is
**3,588 lines, 101 examples**, with exactly **one** top-level `RSpec.describe` at `:23` and **18
second-level describes**, each targeting a different Lua module: `99_attach` (`:116`), `20_buffers`
(`:199`), `45_views` (`:234`, `:267`), `70_inbox` (`:300`), `62_approval` (`:337`, `:488`),
`runtime.lua` (`:793`, `:1021`), `65_review`/`41_layout` (`:1145`, `:1344`, `:2624`), `55_compose`
(`:1716`), `60_question` (`:2021`), `10_folds`/`05_records` (`:2270`), `30_commands` (`:2454`),
`52_note_compose` (`:3056`), `47_diff` (`:2624`).

Its `around` hook (`:24-41`) spawns `nvim --headless` **per example** — and **five of those spawns are
pure waste**: `:908`, `:925`, `:952`, `:965`, `:986` only read `protocol_history` and a file, never
touching the editor. At **22.7s against a 23.4s floor**, this file is why `--tag '~seam'` barely helps.

**Splitting it obeys the anti-sharding rule rather than violating it.**
`docs/spec-suite-performance.md` forbids carving up a legitimate single-subject spec to game the packer.
This is twelve-plus subjects wearing one filename, and the mirror rule is what puts them right. The
floor falls as a side effect, not as the goal.

**`:seam` has grown fourfold and 84% of it is mis-tagged.** CLAUDE.md:60 says 2.5% of examples. Today:
**3,483 examples (21.4%) across 109-113 files and 37,602 code lines (25.6%)**, and git shows
**26 → 73 → 112 files in five weeks**. **66 files tag the *top-level* describe**, so every example
inherits it. In those 66, only **15.4%** of example bodies touch a real resource. `spec/lain/seams/`
alone — the directory the doc actually describes — is 1.34%. Against the runtime log, seam is
**345.3s of 508.2s contended = 68%**.

**Exact-message assertions: 2,162 of 3,505 `raise_error` calls (61.7%) carry a message matcher**, and
3,940 assertions pin prose overall. Since cross-file duplication is low, the cure is **ownership, not
deduplication**: a catalog keyed by symbol, where unit specs assert the key and **one** catalog spec
asserts the wording. `refusal_width_discipline_spec.rb` already mechanically owns refusal *shape*, so
this completes a pattern the repo started.

**291 internals reach-ins** — 124 `send(:`, 167 `instance_variable_get` — plus 16 `.ordered`. Ranked by
which merge each blocks:

1. **`wiring_spec.rb` — 33 sites.** `instance_variable_get(:@switchboard)` at `:327`, `:540`, `:793`,
   `:1594`, `:1737`, `:1755`; `send(:switchboard)` at `:2272`; `send(:toolset_build).send(:seam)` at
   `:2436`; fourteen private-ivar identity assertions. Blocks simplify-04's T1.
2. **`supervisor_spec.rb`** — 14 examples asserting exact ordered call logs across `Isolation#acquire` /
   `WorkerHandoff#surrender` / `Lease#release`. Blocks simplify-04's T11.
3. **`subagent_spec.rb`** — a 170-line isolated `Seam` group where **14 of 18 examples lose their
   subject** on a Seam→Subagent merge; plus `send(:gated)` and `@inner`/`@sensitivity` chain assertions.
4. **`human_replies_spec.rb`** — `:855` and `:862` stub the **private** `classify`; `:857` and `:864`
   reach private `typed`/`answerable` via `send`. `:843-847` concedes the branch is unreachable by
   design. It pins three private method *names*.
5. **`review_view_spec.rb:147-150`** — `private_method_defined?` asserted over `SCOPE_ROWS.values`;
   `:633` asserts an ivar's *absence*, `:793` a method's absence.

**One of them is earned and must survive.** `wiring_spec.rb:2453-2470` explains why it uses `equal?`
and not `eq` — *identity* is the claim, one object at two seams — and names the regression it guards:
`ToolsetBuild` and `BoardBuild` each calling `Shell::Verdict.new`, restoring a double parse **with a
green suite**. It also records that `eq` catches it today only by coincidence of two unrelated classes
inheriting `Object#==`.

**Specs that regex-scrape source text are a distinct class, and one blocks the prose sweep.**
`inbox_view_spec.rb:979` and `approval_view_spec.rb:621` scrape a Lua local's exact spelling.
`up_spec.rb:882-887` reads `lib/lain/cli/up/pane_command.rb`, extracts the comment block above
`CONSENT_ENV`, and asserts `reason.lines.count > 3` **and** that it mentions "Notify" and
"EnvDefaults" — **a spec enforcing a minimum comment length.**

**One guard cannot fail.** `spec/spec_discipline_spec.rb` is **835 code lines / 61 examples / 6.49s**,
and `:78-82` says so: *"A guard that FAILS the suite on day one would need an allowlist sized to that
count, which is a disabled guard wearing a spec's name — so this spec prints the report and passes."*
Its stated follow-up is to become a real guard once the count is down. `bin/comment-census` is the
established home for a worklist.

**28 files re-enumerate the repo's own `lib/` tree** — **9,271 code lines (6.2% of the suite)**,
**50.4s of 508.2s = 9.9% of example time**. Split: 21 non-discipline (7,020 code lines, in scope here)
and 7 discipline (2,251). `lib/**/*.rb` is re-globbed and re-read by **at least 11 separate specs** —
~8,200 file opens, ~7,500 full Ripper/Prism parses — while the same pre-commit hook runs **one cached
RuboCop pass** over the same 1,543 files. `docs/spec-suite-performance.md` already solved this shape for
git with `SeedRepo`/`DivergedRepo`: build once per process and share.

**699 lines of specs test spec helpers**: `support_matchers_spec.rb` (171),
`support_vsock_availability_spec.rb` (310), `support_watchdog_spec.rb` (112),
`support_store_fetch_count_spec.rb` (106).

**Shared-example sprawl: 26 groups, 3,862 lines.** *"an elementwise map"* (138 lines) has **zero
`it_behaves_like` callers**. Eleven more have 1-2: *"an attenuation"* (263 lines, **1** use),
*"a pure operation"* (145, **1**), *"an exec boundary matching bash"* (135, 2), *"an ollama
deployment"* (139, 2), *"a monoid homomorphism"* (110, 2). A shared example with one caller is
indirection with no reuse.

**`spec/support` is 3,647 code lines in 64 files** (not 8,663 raw), loaded in every one of the 12
workers via `spec_helper.rb:40`'s recursive glob — but at 3,647 code lines that is noise against
`require "lain"`'s own 701K objects, so relocation is for **ownership, not load cost**.

**505 `Sync do` sites across 78 files.** These can be **hoisted, not dropped**: a raise out of a `Sync`
with a parked child hangs the run and reports "0 failures" — the same silent-truncation failure mode
CLAUDE.md warns about for `SystemExit`.

**4,042 `Lain::*.new(` sites.** `Journal` appears in 133 files, `Toolset` 112, `Context` 103, and **85
files hand-build 3+ core classes**. `subagent_spec.rb` already has `build_subagent` and spells the graph
out 27 times anyway, purely to vary one member — and it already forwards `**seam`, so part of this is
just *using* what exists.

**168 examples are migration-era guards** pinning completed refactors; `telemetry_spec.rb:108-121`
re-implements the old `gsub` it replaced.

**23 sites spawn a headless editor in 5 variants, and none uses the helper written for it** —
`spec/support/socket_tmpdir.rb` exists and is unused by them.

**What must not be cut.** The `:seam` tier's existence: `approval_view_spec.rb:769` argues over 55 lines
that folds are only observable in a live window and records that **a mutation survived a source-grep**;
`review_view_spec.rb:886-894` shows `before(:context)` was **measured and correctly rejected** (a spawn
is 5-6ms; the 29ms was the whole hook, not the spawn). Those files earned their cost.

**Where docs and code disagreed.** CLAUDE.md:60's 2.5% seam figure was accurate on 2026-08-05 at 26
files; it is now 21.4%. **The measurement wins**, and simplify-01's T7 corrects the prose.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `spec/spec_helper.rb`, `spec/support/tags.rb`,
  `Rakefile`, `.rubocop.yml`, `lib/lain.rb`.
- **`spec/support/` additions need no manifest edit** — `spec_helper.rb:40` globs `support/**/*.rb`
  recursively. But `webmock/rspec` is required from `spec_helper` itself (`:16-19`) because the glob's
  alphabetical order matters, and `support/watchdog` is required out of band at `:33` because `around`
  hooks nest in definition order. **Anything a new support file must load before or after needs the
  orchestrator**, not a card.
- This plan assumes **simplify-01's spec-mirror relaxation has landed** for T1 — splitting to mirror
  paths for Lua modules needs a convention for what a Lua module's mirror path *is*, and the current
  rule does not describe one.
- **simplify-14 runs before T1.** 14's T1 removes four whole groups from `neovim_runtime_spec.rb` —
  the file T1 splits into per-module files. Splitting first means creating spec files for Lua modules
  that are about to be deleted, and then deleting them. This is an ordering constraint on **T1 only**;
  the rest of this plan is independent of 14.
- **T2 and T5 must not run in the same wave as another plan's large spec edit.** Both touch many files
  shallowly, and a merge conflict across 66 files is worse than a serialized wait.

## Open decisions

- **What a Lua module's mirror path is.** T1 splits `neovim_runtime_spec.rb` into per-module files, and
  `lib/lain/frontend/neovim/runtime/45_views.lua` has no established spec path. The card proposes
  `spec/lain/frontend/neovim/runtime/45_views_spec.rb` and notes that the numeric prefix — which is the
  load order — then appears in a spec filename, which is either honest or ugly. Panel decides.
- **Whether `spec_discipline_spec.rb` becomes a `bin/` script or a real guard.** T3 moves it to `bin/`
  because it cannot fail today. Its own comment says the intent was always to make it a guard once the
  count drops. Moving it is reversible; making it a guard now would need a 183-entry allowlist, which is
  a disabled guard wearing a spec's name.
- **How far T11 goes.** 2,162 message matchers is too many to convert in one plan. The card establishes
  the catalog and converts the refusal families simplify-06's T5 is already collapsing, then reports the
  remainder as a standing worklist.

## Waves

Wave 1: T3, T4, T9, T12
Wave 2: T1, T2, T5
Wave 3: T6 (←T1), T7, T8, T10, T11
Critical path: T4 → T1 → T2

T12 is in wave 1 deliberately: the source-scraping specs block simplify-01's prose work and simplify-04's
comment cleanup, so they should clear early. **T6 moved to wave 3 because it edits
`spec/lain/frontend/neovim/review_view_spec.rb`, which T1 splits into three files** — T6 would be editing
a path that no longer exists.

## Tasks

### T1 — Put twelve-plus subjects at twelve-plus mirror paths   [wave 2] [risk: medium]

**Depends on:** T4
**Files:** split `spec/lain/frontend/neovim_runtime_spec.rb` into per-module files under
`spec/lain/frontend/neovim/runtime/`; split `spec/lain/frontend/neovim/review_view_spec.rb` and
`spec/lain/frontend/neovim/thread_view_spec.rb`; modify `spec/lain/telemetry_spec.rb`
**Reuse:** T4's shared `HeadlessEditor` support module — each split file needs the harness, and five
variants across 23 sites is what makes splitting expensive today
**Shared-file wiring:** none
**Reachable from:** these are specs; the "production path" check is that the same behaviours are still
asserted. AC 4 is that the total example count is unchanged.

`neovim_runtime_spec.rb` is 3,588 lines / 101 examples with **one** top-level describe and **18**
second-level ones, each targeting a different Lua module. Splitting it to mirror paths is what the
anti-sharding rule *wants* — it forbids carving up a single-subject spec, and this is twelve-plus
subjects in one filename.

**Delete the five wasteful spawns while here.** `:908`, `:925`, `:952`, `:965` and `:986` only read
`protocol_history` and a file — they never touch the editor, so they should not be in a file whose
`around` hook spawns one per example.

`review_view_spec.rb` (1,660 lines) holds four subjects and three harnesses; `thread_view_spec.rb`
(1,657+92) is really a spec of `runtime/51_thread.lua` plus a small one of `thread_view.rb`.
`telemetry_spec.rb` is an index spec for a 27-file subtree.

**The wall-clock floor falls as a side effect.** At 22.7s against a 23.4s floor,
`neovim_runtime_spec.rb` is why `--tag '~seam'` barely helps — but that is the consequence, not the
goal, and the card should not optimize the split for the packer.

**Acceptance criteria**

```gherkin
Scenario: each Lua module's behaviour is asserted at its own mirror path
  When the spec files under the runtime spec directory are listed
  Then each corresponds to one runtime Lua module

Scenario: the editor behaviours still hold
  Given a live editor
  When each split spec runs
  Then every behaviour previously asserted still passes

Scenario: a spec that touches no editor spawns none
  Given the specs that only read a protocol history
  When they run
  Then no editor was spawned

Scenario: no behaviour was lost in the split
  When the example count across the split files is compared with the original
  Then it is the same or greater
```
→ spec files: the split files themselves; AC 4 is verified by counting and recorded in the commit message

**Escalation triggers**
- The `around` hook (`:24-41`) spawns and reaps `nvim` **per example**, with a `Timeout.timeout(10)`
  waiting for the socket. If splitting multiplies process startup — 18 files each paying their own
  `before(:suite)` — the wall could get **worse**. Measure before and after; `review_view_spec.rb:886-894`
  records that `before(:context)` was already measured and rejected, so do not reach for it.
- The single top-level describe is `RSpec.describe Lain::Frontend::Neovim, :nvim`. Splitting means each
  file names a Lua module as its subject — which is not a Ruby constant. Decide what `described_class`
  is, or whether these become `RSpec.describe "45_views.lua"` string-subject files, and say so.
- `spec/support/tags.rb:127` declares `:nvim`. Every split file needs it; a file that silently loses the
  tag will try to spawn an editor in an environment that excluded it.
- If two of the 18 describes share a `let` or a helper, splitting duplicates it. That is T4's job to
  absorb — if T4 has not landed, **stop**, because five harness variants will become eighteen.

### T2 — Tag the real resources, not the files that contain them   [wave 2] [risk: medium]

**Depends on:** none
**Files:** modify the 66 spec files that tag their top-level describe `:seam`
**Reuse:** `spec/lain/seams/` is the directory for seams belonging to no single subject, and it is
already correctly scoped at 1.34% of examples — it is the model
**Shared-file wiring:** none
**Reachable from:** the tag decides what `--tag '~seam'` excludes; AC 3 measures the inner loop it is
supposed to serve

**66 files tag the top-level describe**, so every example inherits `:seam`, and in those files only
**15.4%** of example bodies touch a real resource. The tag has grown **26 → 73 → 112 files in five
weeks** and now covers 21.4% of examples against a documented 2.5%.

Move the tag to the examples that actually drive git, an editor, a multiplexer, a live fd or the
compiled extension. **Per-file judgment, not a sweep** — some examples rely on a shared `before` that
does the real work, and those are seams even though their bodies look pure.

**Acceptance criteria**

```gherkin
Scenario: an example that drives a real resource carries the tag
  Given an example that runs git against a real repository
  When its metadata is read
  Then it is tagged as a seam

Scenario: an example that drives nothing real does not
  Given an example asserting a pure function's result
  When its metadata is read
  Then it is not tagged as a seam

Scenario: the inner loop excludes the resource-driving examples
  When the suite runs excluding seams
  Then no example that drives a real resource ran

Scenario: the seam tier still covers every real resource
  Given the full suite
  When the seam-tagged examples are listed
  Then every real-resource driver in the suite is among them

Scenario: no example was lost to a broken metadata block
  Given the example count captured before the re-tagging
  When the full suite runs after it
  Then the count equals the captured one
  And the seam-tagged count plus the seam-excluded count equals it
```
→ spec file: none — this is metadata. **AC 5 is the one mechanical check on this card**, and it exists
because the other four are judgments a reader has to agree with and none of them can go red on its own.
Capture `bundle exec rake pspec`'s example count **before** touching any file, record it in the card's
notes, and compare after. Per `CLAUDE.md:65-66` `parallel_tests` reports only the examples that
survived, so a mistyped `:seam` on a `describe` line drops a whole file and still prints a pass — which
is precisely the failure this card is most likely to cause and the only one an arithmetic identity will
catch. The two partial counts summing to the total is the second half: it fails if a tag edit made a
file's metadata unparseable rather than merely wrong.

AC 1-4 are recorded in the commit message as the judgment they are.

**Escalation triggers**
- **Some examples are seams by inheritance from a shared `before`.** An example whose body looks pure
  but whose `before` clones a repository is a seam. Read the setup, not just the body — and if a file's
  `before(:each)` does real work for every example, the top-level tag was **correct** and that file
  stays as it is.
- `--tag '~seam'` is documented as the inner loop (CLAUDE.md:176-178). It is **near-useless for
  `pspec`** today because `neovim_runtime_spec.rb` alone is 22.7s against a 23.4s floor. If T1 has not
  landed, re-tagging will not visibly help — do not conclude the card failed.
- **Do not reduce the tier.** `approval_view_spec.rb:769` argues over 55 lines that folds are only
  observable in a live window and records that **a mutation survived a source-grep**. An example like
  that must keep its tag even if its body looks like a string comparison.
- Example counts are the check. If the full-suite count changes at all, a tag edit broke a file's
  metadata block — per CLAUDE.md:65-66 a silently-skipped example presents as a pass.

### T3 — Move the guard that cannot fail to `bin/`   [wave 1] [risk: low]

**Depends on:** none
**Files:** create `bin/spec-census` (or extend `bin/comment-census`); delete
`spec/spec_discipline_spec.rb`; modify `CLAUDE.md` if it names the spec
**Reuse:** `bin/comment-census` is the established precedent — CLAUDE.md calls it *"the worklist"* and it
does exactly this job for comments
**Shared-file wiring:** none
**Reachable from:** the script is run on demand; AC 2 is that the suite's wall time drops by its
measured cost

`spec/spec_discipline_spec.rb` is **835 code lines, 61 examples, 6.49s**, and `:78-82` states that it
*"prints the report and passes"* by design, because a real guard would need an allowlist sized to 183
entries — *"a disabled guard wearing a spec's name."* Its own stated follow-up is to become a guard once
the count is down.

It also **poisons the parallel packer**: it writes advisory lines through
`RSpec.configuration.reporter.message` into the file `--out` redirects (`Rakefile:31`), so
`tmp/parallel_runtime_rspec.log` contains `spec discipline: 183 flagged example(s)`, which the knapsack
packer parses as a **183-second phantom entry**.

**Acceptance criteria**

```gherkin
Scenario: the report is still available on demand
  When the census script runs
  Then it reports the flagged examples and their count

Scenario: the suite no longer spends time on a report
  When the suite runs
  Then no example produces a report-only pass

Scenario: the runtime log holds no census report
  When the parallel runtime log is read
  Then no entry is a discipline report
  And every entry that names a spec file gives it a duration
```
→ spec file: none — a script and a deletion. AC 3 is verified by reading the log after one `pspec`.

**AC 3 was unpassable as first written** ("every entry names a spec file and a duration"). Measured
against `tmp/parallel_runtime_rspec.log` at `d2bb133c`: **37 of 736 lines** do not have that shape, and
none of them is this card's doing — one `Run options: exclude {...}` line per worker from RSpec itself,
plus four `Skipping :<tag> specs...` lines per worker written by `spec/support/tags.rb`. Twelve workers,
five lines each, minus the workers that print fewer. The card cannot make them go away and should not
try, so the criterion is narrowed to what it actually owns: the report this plan is removing is no
longer in there.

**Escalation triggers**
- The script must **fail** with a non-zero status when asked to gate (a `--check` flag), even if nobody
  gates on it yet. A script that only ever prints is the same defect in a new location.
- `Rakefile:29-31` chooses `--group-by runtime` only when the log exists. If the log has been poisoned
  for a while, the current packing may be **worse than filesize packing** — measure one `pspec` with the
  cleaned log and report whether the wall changed.
- If any of the 61 examples asserts something real alongside the report, that assertion must survive.
  Read them; a report-only spec that grew a real check is the likeliest surprise.

### T4 — One headless-editor harness   [wave 1] [risk: low]

**Depends on:** none
**Files:** create `spec/support/headless_editor.rb`; modify the 23 sites in ~22 spec files that spawn
one
**Reuse:** **`spec/support/socket_tmpdir.rb` already exists and none of the 23 uses it** — that helper
was written for exactly this and is the starting point
**Shared-file wiring:** none — `spec_helper.rb:40`'s glob picks it up. But if it must load **before**
`support/watchdog` (`spec_helper.rb:33`), that ordering is the orchestrator's.
**Reachable from:** it is test infrastructure; AC 3 is that every editor-driving spec still passes

23 sites, **five variants** of the same spawn-wait-reap dance, none using the `SocketTmpdir` helper
written for it. The `around` hook at `neovim_runtime_spec.rb:24-41` is the most complete — it spawns
`nvim --headless --clean -n --listen <socket>`, waits with a 10-second timeout for the socket to appear,
and reaps with `TERM` plus `Process.wait`, rescuing `Errno::ESRCH, Errno::ECHILD`.

This card is **sequenced before T1** because splitting one file into eighteen would otherwise turn five
harness variants into eighteen.

**Acceptance criteria**

```gherkin
Scenario: a spec gets an editor and gives it back
  Given a spec using the harness
  When the example completes
  Then no editor process remains

Scenario: a spec whose example raises still reaps its editor
  Given a spec using the harness whose example raises
  When the example fails
  Then no editor process remains

Scenario: every editor-driving spec still passes
  When the editor-tagged specs run
  Then all pass

Scenario: a socket path is unique per example
  Given two examples using the harness concurrently
  Then each used a different socket path
```
→ spec file: none for the harness itself — per T9's rule, a helper is exercised by the specs that use it.
AC 1, AC 2 and AC 4 are properties the harness must have and are verified by the editor specs passing
under parallel workers.

**Escalation triggers**
- AC 4 matters because **`TMPDIR` is shared mutable state between concurrent agents** (CLAUDE.md:55-58)
  and 12 workers run in parallel. A socket path built from `Process.pid` alone collides across workers;
  the existing hook uses `pid` **plus** `rand(1_000_000)`.
- If a spec's editor must survive **across** examples, the harness needs a scope beyond `around(:each)`
  — and `review_view_spec.rb:886-894` records that `before(:context)` was measured and rejected. Do not
  add a context-scoped mode without repeating that measurement.
- A leaked `nvim` process is invisible until the box runs out of memory. The session this plan was
  written in lost a desktop to an OOM; **AC 2 is not optional**.

### T5 — One shared tree index for the twenty-one scanners   [wave 2] [risk: medium]

**Depends on:** none
**Files:** create `spec/support/tree_index.rb`; modify the 21 non-discipline spec files that
re-enumerate `lib/`
**Reuse:** `docs/spec-suite-performance.md` already solved this shape for git with
`SeedRepo`/`DivergedRepo` — build once per process and share. `spec/support/seed_repo.rb` is the working
precedent.
**Shared-file wiring:** none
**Reachable from:** test infrastructure; AC 2 is the measured time saving

**28 files re-enumerate the repo's own `lib/` tree** — 9,271 code lines, **50.4s of 508.2s = 9.9% of
example time**. `lib/**/*.rb` is re-globbed and re-read by **at least 11 separate specs**: roughly 8,200
file opens and 7,500 full Ripper/Prism parses — while the same pre-commit hook runs **one cached RuboCop
pass** over the same 1,543 files.

Scope: the **21 non-discipline** files (7,020 code lines). The 7 discipline specs are out of scope
because several are candidates for becoming RuboCop cops, which is a different decision.

One memoized index — paths, contents with whole-line comments stripped, and a parsed AST per file, built
once per process.

**Acceptance criteria**

```gherkin
Scenario: the tree is read once per process
  Given a suite run
  When the index's read count is inspected
  Then each library file was read once

Scenario: the scanning specs are measurably faster
  Given the scanning specs
  When they run through the shared index
  Then their total time is lower than before

Scenario: every scanning spec still reports the same findings
  Given the scanning specs before and after
  When each runs
  Then each reports the same violations

Scenario: the index is frozen
  When the index is asked for its contents
  Then the returned collections cannot be mutated
```
→ spec file: none for the index — a helper is exercised by its users. AC 1, AC 2 and AC 3 are recorded
measurements; AC 4 is a property the users depend on.

**Escalation triggers**
- **The scanners do not all strip comments the same way.** `deletability_spec.rb`'s `CODE` (`:255-258`)
  strips only whole-line comments (`/^\s*#/` or `/^\s*--/`), while others may strip trailing ones. A
  shared index must offer **both** views, or a scanner silently changes what it sees — and AC 3 is what
  catches that.
- Some scanners parse with `Ripper.sexp` and some with Prism. If the index caches one, the others still
  parse — report which and how many, because a half-shared index that still parses 7,000 files buys
  little.
- The index is built per **process**, and `pspec` runs 12. So the saving is per worker, not global;
  state the arithmetic rather than implying a 50.4s saving.
- A frozen index shared across examples is a correctness improvement, but if any scanner **mutates** what
  it reads (normalizing in place), freezing will break it loudly — which is the desired outcome, but
  expect it.

### T6 — Table-loop the confirmed clone clusters   [wave 3] [risk: low]

**Depends on:** T1
**Files:** modify `spec/lain/cli/up_spec.rb`, `spec/lain/cli/human_replies_spec.rb`,
`spec/lain/frontend/neovim/review_view_spec.rb`
**Reuse:** RSpec's `where`-style iteration over a table of `[input, expected]` pairs; no new helper
**Shared-file wiring:** none
**Reachable from:** specs; AC 3 is that the same inputs are still covered

Copy-paste parameterization is only 1.7% of the suite overall, so this card is deliberately narrow —
**only the confirmed clusters**: `up_spec`'s Hud group (12 → 1), its `.lain_exports` group (13 → 2) and
its argv group (16 → 1); `human_replies_spec`'s two groups (18 and 11);
`review_view_spec:959-1012` (8 → 1). Roughly 900 lines.

**Do not sweep for more.** The measurement says there is little, and a hunt would cost more than it
returns.

**Acceptance criteria**

```gherkin
Scenario: every input previously covered is still covered
  Given a converted group
  When it runs
  Then each of the original inputs is exercised

Scenario: a failing input names itself
  Given a converted group with one deliberately wrong expectation
  When it runs
  Then the failure names which input failed

Scenario: the example count reflects the table's rows
  When a converted group's examples are counted
  Then there is one per row
```
→ spec files: the three modified files

**Escalation triggers**
- A table loop that produces **one** example covering twelve inputs loses per-input failure attribution.
  AC 2 exists for that: generate one example per row, not one example iterating rows.
- If two clones differ in a way the table cannot express — a different `before`, an extra assertion —
  they are not clones. Leave them and say which.
- `RSpec/NestedGroups: Max: 4` is configured (`.rubocop.yml:448-449`) with a reason. A table loop inside
  three existing `context`s may trip it.

### T7 — A factory for the core object graph   [wave 3] [risk: medium]

**Depends on:** none
**Files:** create `spec/support/core_graph.rb`; modify the largest of the 85 spec files that hand-build
three or more core classes
**Reuse:** `spec/lain/tools/subagent_spec.rb` **already has `build_subagent`** and already forwards
`**seam` — part of this card is using what exists rather than writing it
**Shared-file wiring:** none
**Reachable from:** test infrastructure; AC 3 is that the specs using it still assert the same things

**4,042 `Lain::*.new(` sites.** `Journal` appears in 133 files, `Toolset` in 112, `Context` in 103, and
**85 files hand-build three or more core classes**. One factory with sensible defaults and keyword
overrides, so a spec varying one member does not respell the graph.

**Do not convert all 85.** Convert the largest few, measure the saving, and report the rest as a
standing worklist — a factory adopted by 10 files and ignored by 75 is worse than none, so the card
should say what would make adoption default.

**Acceptance criteria**

```gherkin
Scenario: a spec varying one collaborator states only that one
  Given a spec needing the core graph with a custom provider
  When it builds the graph through the factory
  Then only the provider is named

Scenario: the default graph is usable with no arguments
  When the factory is called with no arguments
  Then a complete graph comes back

Scenario: every converted spec still asserts what it did
  Given the converted specs before and after
  When each runs
  Then each passes with the same assertions

Scenario: the factory does not reach the network or the filesystem
  When the default graph is built
  Then no request was made and no file was written
```
→ spec file: none for the factory. AC 4 is a property its users depend on, asserted once in whichever
spec exercises the factory most directly.

**Escalation triggers**
- A factory with a **mutable shared default** is a cross-example leak. `DslCatalog`'s *"session-fixed
  SNAPSHOT, not a mutable registry"* is the shape to copy — freeze what is shared, build fresh what is
  not.
- `Journal` writes to a file. If the factory's default journal is a real one, 85 files' worth of specs
  start writing to disk. Default to `Channel::Null.instance` or an in-memory journal, and make the real
  one opt-in.
- If converting a spec changes **which** collaborator is a double, an example that was testing
  integration becomes a unit test or vice versa. That is a coverage change disguised as cleanup —
  report any case where the factory's default is more real, or less real, than what the spec had.

### T8 — Hoist the async ceremony   [wave 3] [risk: medium]

**Depends on:** none
**Files:** create `spec/support/supervised.rb`; modify the spec files with the heaviest `Sync do`
concentration
**Reuse:** the existing `Sync do` blocks are the behaviour; this is a wrapper, not a replacement
**Shared-file wiring:** none
**Reachable from:** test infrastructure; AC 2 is the property that must not be lost

**505 `Sync do` sites across 78 files.** A `supervised(**wiring) { ... }` helper hoists the ceremony —
but it **cannot be dropped**: a raise out of a `Sync` with a parked child **hangs the run and reports
"0 failures"**, the same silent-truncation failure mode CLAUDE.md warns about for `SystemExit`.

So the helper's job is not to remove the block but to make sure every one of them reaps its children and
surfaces its exception.

**Acceptance criteria**

```gherkin
Scenario: an example with a parked child completes
  Given an example that parks a fiber and then finishes
  When it runs
  Then it completes and the child is reaped

Scenario: an example that raises inside the reactor reports the failure
  Given an example that raises with a child parked
  When it runs
  Then it fails, naming the exception
  And it does not hang

Scenario: the suite reports a failure count, not a truncated pass
  Given a deliberately failing async example
  When the suite runs
  Then the failure count is one

Scenario: no fiber survives an example
  Given an example that spawns two fibers
  When it completes
  Then neither fiber is still alive
```
→ spec file: `spec/support_supervised_spec.rb` — **the exception to T9's rule**, and the card must say
why: this helper's whole value is behaviour under failure, which the specs using it cannot demonstrate
because they pass.

**Escalation triggers**
- **AC 3 is the card's reason to exist.** If a deliberately failing async example reports "0 failures",
  the helper has not solved the problem it was written for — stop and report, because that is the
  failure mode that makes a red suite look green.
- Converting a `Sync do` to a helper changes where the reactor is created. If any spec depends on the
  reactor **outliving** the example (a shared connection, say), the helper breaks it in a way that
  presents as a timeout rather than a failure.
- 505 sites is too many for one card. Convert the heaviest files, measure, and report the rest. Say
  explicitly that a partially-adopted helper leaves the hang risk in the unconverted files.

### T9 — Delete the specs that test spec helpers, and the shared examples nobody shares   [wave 1] [risk: low]

**Depends on:** none
**Files:** delete `spec/support_matchers_spec.rb`, `spec/support_vsock_availability_spec.rb`,
`spec/support_watchdog_spec.rb`, `spec/support_store_fetch_count_spec.rb`,
`spec/support/shared_examples/elementwise.rb`; inline the 1-2-caller shared groups into their callers
**Reuse:** the specs that *use* each helper are its coverage — that is the rule this card applies
**Shared-file wiring:** none
**Reachable from:** specs; AC 1 is that the helpers still work, demonstrated by their users passing

**699 lines of specs test spec helpers.** A helper is exercised by the specs that use it; a broken helper
reddens them.

**`"an elementwise map"` (138 lines) has zero `it_behaves_like` callers.** Eleven more have 1-2:
*"an attenuation"* (263 lines, **1** use), *"a pure operation"* (145, **1**), *"an exec boundary matching
bash"* (135, 2), *"an ollama deployment"* (139, 2), *"a monoid homomorphism"* (110, 2). A shared example
with one caller is indirection with no reuse — inline it.

**Keep the law groups with two-plus callers.** `store_laws`, `meet_semilattice`, `regular`,
`canonical_laws` are differential across implementations and simplify-13 depends on them.

**Note the one exception this card creates:** T8's `supervised` helper *does* get its own spec, because
its value is behaviour under failure. Say so, so the rule reads as a rule with a stated exception rather
than as inconsistency.

**Acceptance criteria**

```gherkin
Scenario: every helper still works
  When the suite runs
  Then the specs using each helper pass

Scenario: no shared example group has fewer than two callers
  When the shared example groups are enumerated with their callers
  Then each has at least two

Scenario: the inlined assertions are still made
  Given a group inlined into its single caller
  When that spec runs
  Then the assertions the group made are still asserted
```
→ spec file: none — deletions and inlining. AC 2 is an enumeration recorded in the commit message.

**Escalation triggers**
- `support_vsock_availability_spec.rb` is **310 lines** — by far the largest of the four. If it asserts a
  refusal on bad input that no user-spec would trigger, that is real coverage of the helper's contract.
  Read it before deleting; that is the likeliest case where the rule is wrong.
- `spec/support_vsock_availability_spec.rb:136-146` is a **byte-for-byte copy** of `tags.rb:238-246`
  rather than a reference — so `tags.rb` can drift and it stays green. Deleting the spec removes a
  (broken) check; say so rather than implying nothing was lost.
- An inlined group's `include_examples` may be called with different arguments by its two callers. If
  inlining a 1-caller group is straightforward but a 2-caller group would need parameterizing, leave the
  2-caller ones alone — the threshold is the rule.

### T10 — Retire the guards that pin completed migrations   [wave 3] [risk: low]

**Depends on:** none
**Files:** modify `spec/lain/telemetry_spec.rb` and the other files holding the 168 migration-era
examples
**Reuse:** nothing — this is removal
**Shared-file wiring:** none
**Reachable from:** specs; AC 2 is that the behaviour they guarded is still asserted somewhere

**168 examples pin completed refactors.** `telemetry_spec.rb:108-121` **re-implements the old `gsub`** it
replaced, i.e. the spec carries a copy of the code it exists to say is gone.

An example asserting "the old shape is absent" earns its place only while the old shape could plausibly
return. Once the migration is committed and the old code deleted, the guard is pinning history.

**Acceptance criteria**

```gherkin
Scenario: the current behaviour is still asserted
  Given a retired migration guard
  When the subject's current behaviour is exercised
  Then it is asserted by a surviving example

Scenario: no spec re-implements code it asserts is gone
  When the suite is searched for a reimplementation of a replaced transformation
  Then none is found

Scenario: the example count drops by the retired guards
  When the suite's example count is compared with the baseline
  Then it dropped by the number retired
```
→ spec files: the modified files; AC 2 is a search recorded in the commit message

**Escalation triggers**
- A "migration-era" guard may be the **only** place a behaviour is asserted. Before deleting, confirm the
  current behaviour has its own example — if it does not, the guard is the coverage and must be rewritten
  rather than removed.
- 168 is an estimate from a sampling pass, not an enumeration. Work file-by-file and report the real
  count; do not delete to reach a number.

### T11 — Own each refusal sentence once   [wave 3] [risk: high]

**Depends on:** none
**Files:** create `lib/lain/refusals.rb` (or extend an existing catalog — the card chooses and says
why), `spec/lain/refusals_spec.rb`; modify the refusal families simplify-06's T5 collapses, and their
spec files
**Reuse:** `refusal_width_discipline_spec.rb` already mechanically owns refusal **shape**, so this
completes a started pattern. simplify-06's T5 is already collapsing 31 refusal classes into one — the
same files, the same edit window.
**Shared-file wiring:** a manifest line in `lib/lain.rb` if a new file
**Reachable from:** every refusal a user reads comes from here; AC 1 drives a real refusal through
`exe/lain`

**2,162 of 3,505 `raise_error` calls (61.7%) carry a message matcher**, and 3,940 assertions pin prose.
Since cross-file duplication is low (19 literals across ≥2 files), the problem is not duplication but
**ownership**: every copy edit to a sentence is a spec edit somewhere else.

> A catalog keyed by symbol. Unit specs assert the **key**; one catalog spec asserts the **wording**.

**Scope this card deliberately.** 2,162 matchers is too many for one plan. Convert the refusal families
simplify-06's T5 is already touching, establish the catalog and the pattern, then **report the remainder
as a standing worklist**. A catalog adopted by one subsystem and ignored by the rest is worse than none,
so the card must say what would make adoption default — probably a discipline check, which is its own
decision.

**Model-facing prose is a product decision and deserves a test.** It deserves **one**.

**Acceptance criteria**

```gherkin
Scenario: a refusal names its key
  Given a refusal raised from the catalog
  When it is rescued
  Then it carries the key it was raised with

Scenario: a unit spec asserts the key, not the sentence
  Given a converted unit spec
  When it asserts a refusal
  Then it names the key
  And it does not match on the wording

Scenario: one spec owns every sentence
  When the catalog spec runs
  Then every key's wording is asserted

Scenario: a user still reads a sentence, not a key
  Given a command that refuses
  When it is run through the CLI
  Then the output is the sentence
```
→ spec files: `spec/lain/refusals_spec.rb` (AC 1, AC 3), the converted unit specs (AC 2), and an
existing CLI spec for AC 4

**Escalation triggers**
- **A key is not a sentence, and a user reads a sentence.** If the catalog makes a message harder to read
  at the raise site, the card has traded clarity for tidiness. `Sensitivity`'s refusals name a path and a
  rule; a bare key at the raise site would make that unreadable — in which case the catalog holds a
  **template** and the raise site supplies the values, which is a different design. Decide and say which.
- Converting a spec from `raise_error(Klass, /sentence/)` to `raise_error(Klass, key: :foo)` makes it
  assert **less** unless the catalog spec is complete. If any key's wording ends up asserted nowhere,
  coverage was lost — AC 3 is the guard and it must enumerate, not sample.
- simplify-06's T5 collapses 31 refusal classes. If both cards edit the same `raise` lines, sequence
  them — and prefer T5 first, since a catalog keyed by symbol is easier over one refusal class than over
  31.
- `refusal_width_discipline_spec.rb` asserts refusal **width**. A catalog that concatenates a template
  and values could exceed it at runtime while every fixture passes — check that the width guard sees the
  rendered sentence, not the template.

### T12 — Stop specs from reading source text   [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `spec/lain/cli/up_spec.rb`, `spec/lain/frontend/neovim/inbox_view_spec.rb`,
`spec/lain/frontend/neovim/approval_view_spec.rb`
**Reuse:** the constants and behaviours these specs scrape are all reachable as **values** — a spec can
read `PaneCommand::CONSENT_ENV` rather than the comment above it
**Shared-file wiring:** none
**Reachable from:** specs; AC 1 is that the intent each spec had is still asserted

Three specs assert on **source text** rather than behaviour, and one of them **enforces a minimum
comment length**:

    spec/lain/cli/up_spec.rb:882-887
      source = File.read(.../lib/lain/cli/up/pane_command.rb)
      reason = source[/((?:^\s*#.*\n)+)\s*CONSENT_ENV\s*=/, 1].to_s
      expect(reason.lines.count).to be > 3
      expect(reason).to include("Notify").and include("EnvDefaults")

`inbox_view_spec.rb:979` and `approval_view_spec.rb:621` scrape a Lua local's exact spelling.

**This card clears a blocker for two other plans.** simplify-01's prose work and simplify-04's comment
cleanup both shorten comments; with these specs in place, doing so fails in a way that looks like a real
defect.

**Each spec had a real intent** — that a list's reason is documented, that a Ruby constant and a Lua
pattern agree. Preserve the intent as a behavioural assertion, or move it to a discipline check where
source-reading is the point. Do not simply delete.

**Acceptance criteria**

```gherkin
Scenario: no spec asserts on the length of a comment
  When the suite is searched for assertions over comment text
  Then none is found

Scenario: the Ruby constant and the Lua pattern still agree
  Given the indent constant and the continuation pattern
  When they are compared
  Then they describe the same prefix

Scenario: the environment list's reason is still required
  Given the environment-name list
  When its documentation is checked
  Then the requirement is enforced where source-reading belongs

Scenario: shortening a comment does not fail the suite
  Given a comment shortened by one line
  When the suite runs
  Then it passes
```
→ spec files: the three modified files, plus whichever discipline spec receives the relocated intent
(AC 3)

**Escalation triggers**
- AC 2 is a **cross-language** agreement: `INDENT` in Ruby and `CONTINUATION` in
  `runtime/05_records.lua`. simplify-07's T7 consolidates the Ruby side to one spelling. If both cards
  are in flight, the assertion's subject moves — coordinate, and prefer T7 first so this card pins one
  Ruby spelling to the Lua rather than two.
- `up_spec.rb:882-887`'s intent is that a hand-maintained env list **explains itself**. That is a real
  concern — the list is held against `exe/lain` by a drift spec. If the intent cannot be expressed
  behaviourally, move it to a discipline spec rather than dropping it, and say that source-reading is
  legitimate *there* and not in a unit spec.
- If a fourth source-scraping spec turns up, add it — but report it, because three was the measured count
  and a fourth means the pattern is spreading.

## Integration checks

After the last wave:

- `bundle exec rake pspec` green, **with the example count recorded and the arithmetic written out**.
  T9, T10 and T1 all move the count, in both directions. A drop this plan cannot account for is a dead
  worker.
- **Measure the wall before and after.** T1, T2, T3 and T5 are all partly time claims — T3 removes a
  measured 6.49s, T5 targets 50.4s of scanning, T1 targets a 23.4s floor. Record the actual `pspec` wall
  at 12 workers before the plan and after each of those four, and say which claims held.
- **Run with and without `--tag '~seam'` and record both counts and both walls.** T2's entire deliverable
  is that the difference becomes meaningful; today it barely is.
- `bundle exec rspec --tag nvim` — T1 and T4 both restructure how the editor is driven, and 101 examples
  spawn a real one.
- `bundle exec rubocop` clean, and confirm `RSpec/NestedGroups` and `RSpec/ExampleLength` did not need
  loosening — T6's tables and T7's factory both push on those, and `.rubocop.yml:207-214` argues those
  two cops are deliberately about spec DSL rather than `lib/` objects.
- **Read `tmp/parallel_runtime_rspec.log` after one run** and confirm it holds only timings (T3's AC 3).
  A poisoned packer input silently mis-packs every subsequent run.
- **Confirm no `nvim` process survives the suite.** T4's AC 2 is the one whose failure mode is an OOM
  rather than a red spec.
- No `planning/qa/scenarios/` update is expected — this plan changes no user-visible behaviour. If any
  card finds itself changing one, that is a signal the card exceeded its scope.
