# Simplify 10 — put specs at their subjects, tag the real resources, and own each sentence once

status: in-progress
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

The suite is 149,154 code lines against 47,635 in `lib/`, and the obvious conclusion is wrong. Measured,
it runs **6.24 code lines per example, 1.65 expectations per example, and a median of 1.17 examples per
branch-point** in the subject — there is no pool of structural waste to drain, and realistic recovery is
**8-10%, not 50%**. Three plausible hypotheses came back empirically dead.

What is actually wrong is narrower and fixable: three files hold twelve-plus subjects each and one of
them sets the wall-clock floor; the `:seam` tag covers **8.35%** of examples against a documented 2.5% and
84% of the examples carrying it touch no real resource; **325** internals reach-ins block the merges other
plans want; one guard spends 5.05 seconds and cannot fail; and **58.9%** of `raise_error` assertions pin a
message, so every copy edit is a spec edit.

Delivers: the mis-attributed files split to mirror paths; `:seam` applied per example; a report-only
guard moved to `bin/`; one headless-editor harness; the confirmed clone clusters as tables; a core-graph
factory; the async ceremony hoisted; message wording owned once; and the source-scraping specs turned
back into behavioural ones.

## Execution log

**Executed 2026-09-13**, base ref `main` @ `d4a7a1ea`.

**The Grounding's `d2bb133c` is not an ancestor of HEAD.** History diverged: HEAD carries 327 commits and
693 files that commit does not have, and simplify-01, -04, -05, -06 and -07 all landed in the window. This
plan is almost entirely measured figures, so **every one was re-measured on 2026-09-13** and the numbers
below are the re-measured ones. The audit is at `planning/specs/staleness-10.md`.

**Two cards were ruled on by the human and are settled here.**

- **T5 is DROPPED.** Its premise evaporated: ~6 spec files glob `lib/**` today rather than 28, one of
  those only inside heredoc fixtures, and `spec/repo_as_fixture_spec.rb` landed in the window as a
  mechanical guard *against* the pattern. See Open decisions for the re-measurement.
- **T12 is RETARGETED, not dropped.** All three specs it named are gone, but six *other* source-scraping
  specs exist — which is exactly what the card's own *"if a fourth turns up, report it, because the
  pattern is spreading"* trigger anticipated. The card keeps its intent and changes its subjects.

**One methodology finding, not a drift.** The plan's headline *"3,483 examples (21.4%)"* for `:seam` was a
static over-count and was never reproducible; the measured figure is **1,489 of 17,837 = 8.35%**. It
matters to T2's urgency, not to T2's case.

**One ordering constraint is void.** The human declined simplify-14 on 2026-09-13, so *"simplify-14 runs
before T1"* is removed from the Orchestrator contract — see there for the citation.

## Grounding

Verified 2026-09-12 against the working tree at `d2bb133c`, and **re-measured 2026-09-13 against
`d4a7a1ea`** — see the Execution log. `code` is non-blank, non-comment.

**The suite's arithmetic, re-measured.** 17,837 examples (matching `CLAUDE.md`), `spec/**/*.rb` at
**149,154** code lines and `lib/**/*.rb` at **47,635** — the ratios below are unchanged in shape.

**Where the lines physically sit** (proportions measured at `d2bb133c`'s 150,715; the shape is unchanged
at 149,154):

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
`RSpec.describe`** — verified exactly at 46, now totalling **18,793 code lines** (+8.9%).
`thread_view_spec.rb` is not 1,126 lines testing 38 — it is three top-level describes, most of them
testing `runtime/51_thread.lua` (258 code lines) plus a small spec of `thread_view.rb` at a healthy 2.4:1.
Same shape for `telemetry_spec.rb` (an index spec for a 27-file subtree) and for the wiring spec — whose
**path moved**: `spec/lain/cli/wiring_spec.rb` (1,979 code lines, 4 describes) over `lib/lain/cli/wiring.rb`
plus `cli/wiring/*`, with `spec/lain/cli/wiring/{board_build,askers,toolset_build}_spec.rb` already
alongside it. simplify-04 did that move; **there is no `spec/lain/wiring_spec.rb`.** The largest of the 46:

```
1979 code  4 describes  spec/lain/cli/wiring_spec.rb
1344       2            spec/lain/cli/human_replies_spec.rb
1126       3            spec/lain/frontend/neovim/thread_view_spec.rb
1121       4            spec/lain/cli/up_spec.rb
1067       2            spec/lain/frontend/neovim/inbox_view_spec.rb
 965       4            spec/lain/frontend/neovim/review_view_spec.rb
 749       9            spec/lain/frontend/neovim/rpc_thread_spec.rb
 721       2            spec/lain/frontend/neovim/diff_mode_spec.rb
```

**And `lib/**/*.lua` has no mirror convention at all.** 2,056 code lines of Lua are driven by 37 spec
files totalling 20,229 lines — **9.84:1** — every line charged against Ruby in the headline ratio.

**One file is simultaneously the worst mis-attribution and the wall-clock floor.**
`spec/lain/frontend/neovim_runtime_spec.rb` (note: **not** under `spec/lain/frontend/neovim/`) is
**3,612 raw / 2,204 code lines, 102 examples**, with exactly **one** top-level `RSpec.describe` at `:23`
and **18 second-level describes**, each targeting a different Lua module. **Every line number in an
earlier draft of this list had moved, and one describe is new** (`"the rail table's one lua dispatch"`,
landed by `88c13d54` as simplify-07's T3), so the map is re-derived in full:

| lines | code | ex | describe | Lua module |
|---|---|---|---|---|
| `:116-198` | 65 | 3 | *"user autocmds get a stable surface"* | `99_attach` |
| `:199-233` | 25 | 2 | *"richer highlighting"* | `20_buffers` |
| `:234-266` | 21 | 1 | *"workspace view has a lua-side home"* | `45_views` |
| `:267-302` | 19 | 1 | *"status view has a lua-side home"* | `45_views` |
| `:303-366` | 34 | 1 | *"the rail table's one lua dispatch"* — **new** | `45_views` |
| `:367-403` | 22 | 1 | *"the inbox's open gesture, end to end"* | `70_inbox` |
| `:404-554` | 90 | 6 | *"answering a parked approval in the editor"* | `62_approval` |
| `:555-852` | 182 | 2 | *"the repl's own wiring puts a parked approval …"* | `62_approval`, `runtime.lua` |
| `:853-1044` | 90 | 9 | *"the runtime digest"* | `runtime.lua` |
| `:1045-1168` | 77 | 6 | *"one lain per editor"* | `runtime.lua` |
| `:1169-1367` | 89 | 5 | *"the review round trip"* | `65_review`, `46_sidebar`, `30_commands` |
| `:1368-1739` | 204 | 10 | *"the refusal rail's width"* | `65_review` |
| `:1740-2044` | 205 | 11 | *"the compose round trip"* | `55_compose` |
| `:2045-2293` | 174 | 9 | *"the question round trip"* | `60_question` |
| `:2294-2477` | 111 | 8 | *"folds"* | `10_folds`, `05_records`, `51_thread` |
| `:2478-2647` | 92 | 5 | *"a user command that refuses"* | `30_commands`, `65_review`, `47_diff` |
| `:2648-3079` | 266 | 10 | *"a review that survives the tabpage"* | `47_diff`, `41_layout` |
| `:3080-3612` | 362 | 12 | *"a long note grown in a pane"* | `52_note_compose` |

Its `around` hook (`:24-41`) spawns `nvim --headless` **per example**. A timed single-file run is
**102 examples in 22.52s**, so the 22.7s figure holds to within 1% and this file is why `--tag '~seam'`
barely helps. **The 23.4s wall-clock floor is UNVERIFIED** — it needs a `pspec` run, which the audit was
out of bounds for; re-measure it before accepting a card that claims the floor falls.

**The "five wasteful spawns" sub-claim is DEAD.** All nine examples in the `"the runtime digest"` group
(`:853-1044`) reference `@socket` and drive a real editor; no `protocol_history`-only example remains.

**Splitting it obeys the anti-sharding rule rather than violating it.**
`docs/spec-suite-performance.md` forbids carving up a legitimate single-subject spec to game the packer.
This is twelve-plus subjects wearing one filename, and the mirror rule is what puts them right. The
floor falls as a side effect, not as the goal.

**`:seam` is 3.3× its documentation, and 84% of it is mis-tagged.** `CLAUDE.md:177` says 2.5% of
examples. Measured by dry-run: **1,489 of 17,837 examples = 8.35%**, across **65 files** whose *top-level*
describe carries the tag (**66 occurrences**; one file carries two), out of 115 files containing the
string anywhere. Every example in those 65 inherits the tag, and in them only **15.4%** of example bodies
touch a real resource. `spec/lain/seams/` alone — the directory the doc actually describes, 29 files — is
1.34%. Against the runtime log, seam is **345.3s of 508.2s contended = 68%**.

**An earlier draft said 21.4%, and that figure was never right — it is a methodological error, not
drift.** A static `it`/`specify` grep across the 115 files that contain `:seam` *anywhere* yields 3,580
examples / 38,738 code lines, which is where *"3,483 examples (21.4%) … 37,602 code lines (25.6%)"* came
from. That count charges every example in a file to `:seam` because one example somewhere in it carries
the tag, and it counts `it "…"` inside heredoc fixtures. The dry-run's two partial counts sum exactly to
the total (1,489 + 16,348 = 17,837), so **8.35% is the number**. The same error shape is why T3's example
count and T5's scanner census were both wrong — a static scan of a file that embeds Ruby in heredocs
counts the fixture as the subject.

**The tag did not grow in the divergence window.** Files containing `:seam`: 114 → **115**. Top-level
describes carrying it: 67 → **66**. The *"26 → 73 → 112 files in five weeks"* growth story is historical
and did not continue; the case for T2 is the mis-tagging, not a trend.

**Exact-message assertions: 2,063 of 3,500 `raise_error` calls (58.9%) carry a message matcher.** The
*"3,940 assertions pin prose overall"* figure was not independently reproducible and is dropped. Since
cross-file duplication is low, the cure is **ownership, not deduplication**: a catalog keyed by symbol,
where unit specs assert the key and **one** catalog spec asserts the wording.
`spec/refusal_width_discipline_spec.rb` already mechanically owns refusal *shape*, so this completes a
pattern the repo started.

**325 internals reach-ins — the problem got WORSE in the window, not better.** 140 `send(:` (was 124),
185 `instance_variable_get` (was 167), plus 17 `.ordered` (was 16). Ranked by which merge each blocks,
re-measured, and **two of the five ranks were wrong**:

1. **`spec/lain/cli/wiring_spec.rb` — 51 sites** (was ranked 33). **The path moved**: there is no
   `spec/lain/wiring_spec.rb` and no `lib/lain/wiring.rb`; simplify-04 moved both under `cli/`, with
   `spec/lain/cli/wiring/{board_build,askers,toolset_build}_spec.rb` alongside. At 1,979 code lines over
   4 top-level describes it is still the biggest single blocker, and it blocks simplify-04's T1.
2. **`spec/lain/cli/backend_spec.rb` — 43 sites.** **Entirely absent from an earlier draft of this
   ranking**, and the real number two. Nothing in this plan yet says which merge it blocks; find out
   before T7 or T8 touches it.
3. **`subagent_spec.rb` — 14.** A 170-line isolated `Seam` group where **14 of 18 examples lose their
   subject** on a Seam→Subagent merge; plus `send(:gated)` and `@inner`/`@sensitivity` chain assertions.
4. **`human_replies_spec.rb` — 4.** `:855` and `:862` stub the **private** `classify`; `:857` and `:864`
   reach private `typed`/`answerable` via `send`. `:843-847` concedes the branch is unreachable by
   design. It pins three private method *names*.
5. **`supervisor_spec.rb` — 0, and 0 `.ordered`. DEAD.** It was ranked second on 14 ordered-call examples
   across `Isolation#acquire` / `WorkerHandoff#surrender` / `Lease#release`; none survives. Whatever
   blocked simplify-04's T11 there is gone.

`review_view_spec.rb`'s `private_method_defined?` assertion over `SCOPE_ROWS.values` **does** survive, at
`:144-149`, and `:633`/`:793` still assert absences — but it is **0** on `send`/ivar and so does not
belong in a list ranked by those. It is a source-shape assertion, which makes it T12's kind of problem,
not this list's.

**One reach-in is earned and must survive.** `wiring_spec.rb`'s `equal?`-not-`eq` identity argument
explains that *identity* is the claim — one object at two seams — and names the regression it guards:
`ToolsetBuild` and `BoardBuild` each calling `Shell::Verdict.new`, restoring a double parse **with a
green suite**. It also records that `eq` catches it today only by coincidence of two unrelated classes
inheriting `Object#==`. **Its line numbers did not survive the move** — an earlier draft said
`:2453-2470` — so **re-find it before any card touches that file**, because a cleanup that deletes it
deletes the reason with it.

**Specs that regex-scrape source text are a distinct class, and the three an earlier draft named are all
gone.** `CONSENT_ENV` no longer exists anywhere in `lib/` (removed by `c40ab419`), and
`spec/lain/cli/pane_command_spec.rb:184` now asserts it is *not* defined; `inbox_view_spec.rb:994` and
`approval_view_spec.rb:675` are prose comments rather than assertions, because **simplify-07's T7
collapsed the Lua/Ruby indent pin to one legitimate site** (`fold_spec.rb:56-59`, reading
`runtime/05_records.lua` — a genuine cross-language pin). **Six other scrapers exist**, none of them
previously named:

| site | what it reads |
|---|---|
| `spec/lain/sensitivity_spec.rb:593` | `lib/lain/sensitivity.rb` source |
| `spec/lain/sensitivity/ledger_spec.rb:120` | `lib/lain/sensitivity/ledger.rb` source |
| `spec/lain/approval/queue_spec.rb:598` | `lib/lain/approval/queue.rb` source |
| `spec/lain/survey/chunker/code_spec.rb:281,288,404` | `lib/lain/cli/command/goal.rb` and others |
| `spec/lain/frontend/neovim/thread_view_spec.rb:1962` | greps `lib/lain/frontend/neovim.rb` for `thread_view` |
| `spec/lain/frontend/neovim/review_view_spec.rb:524` | `runtime/41_layout.lua` source |

**One guard cannot fail.** `spec/spec_discipline_spec.rb` is **835 code lines** (exact) **/ 41 examples /
5.05s**, and `~:76-86` says so: *"A guard that FAILS the suite on day one would need an allowlist sized to
that count, which is a disabled guard wearing a spec's name — so this spec prints the report and passes."*
Its stated follow-up is to become a **ratchet** (`count <= <ceiling>`), not a hard failure.
`bin/comment-census` is the established home for a worklist.

**The `lib/`-tree scanner census does not survive re-measurement.** An earlier draft said *"28 files
re-enumerate the repo's own `lib/` tree — 9,271 code lines, 50.4s of 508.2s"*, split 21 non-discipline and
7 discipline. Measured, **four** spec files glob `lib/**/*` at runtime and one of those four only inside
heredoc fixtures; of the three real ones, one is a discipline spec. See Open decisions — this is what
dropped T5.

**699 lines of specs test spec helpers**: `support_matchers_spec.rb` (171),
`support_vsock_availability_spec.rb` (310), `support_watchdog_spec.rb` (112),
`support_store_fetch_count_spec.rb` (106) — all four exact.

**Shared-example sprawl: 25 groups.** *"an elementwise map"* (138 lines) has **zero `it_behaves_like`
callers**. The 1-2-caller tail: *"an attenuation"* (263 lines, **1** use), *"a pure operation"* (145,
**1**), *"a tier-1 read of any path that never raises"* (**1**), *"an ollama deployment"* (2),
*"a monoid homomorphism"* (2), *"a commutative monoid"* (2), *"a review changeset source"* (2),
*"canonical determinism"* (2), *"files a bound can size"* (2), *"not a monoid homomorphism"* (2). A shared
example with one caller is indirection with no reuse. **`"an exec boundary matching bash"` no longer
exists** — it was renamed `"an exec backend answering for a term"` (`exec_term_contract.rb:34`) and now
has **3** callers, so it leaves the list.

**`spec/support` is 3,647 code lines in 64 files** (not 8,663 raw) — **not re-derived on 2026-09-13**;
today it is 40 top-level files plus `matchers/`, `nulls/`, `provider_oracles/` and `shared_examples/`, and
the ownership argument below is unaffected either way. Loaded in every one of the 12 workers via
`spec_helper.rb:40`'s recursive glob — but at 3,647 code lines that is noise against
`require "lain"`'s own 701K objects, so relocation is for **ownership, not load cost**.

**489 `Sync do` sites across 77 files.** These can be **hoisted, not dropped**: a raise out of a `Sync`
with a parked child hangs the run and reports "0 failures" — the same silent-truncation failure mode
CLAUDE.md warns about for `SystemExit`.

**4,033 `Lain::*.new(` sites.** `Journal` appears in 134 files, and **83 files hand-build 3+ core
classes**. `subagent_spec.rb` already has `build_subagent` — **74 references** to it — and spells the
graph out anyway, purely to vary one member; it already forwards `**seam`, so part of this is just
*using* what exists.

**168 examples are migration-era guards** pinning completed refactors; `telemetry_spec.rb:109-123`
re-implements the old `gsub` it replaced. The 168 is **an estimate from a sampling pass, not an
enumeration**, and no mechanical proxy reproduces it — it stays flagged as an estimate.

**21 sites across 20 spec files spawn a headless editor in 5 variants.** `spec/support/socket_tmpdir.rb`
exists, is globally included (`socket_tmpdir.rb:51`), and has **one** user —
`spec/lain/frontend/neovim/diff_mode_spec.rb:59`'s `SocketTmpdir.persistent("lain-diff-spec")`. The
starting point is better than an earlier draft's *"none of the 23 uses it"* implied.

**What must not be cut.** The `:seam` tier's existence: `approval_view_spec.rb:769` argues over 55 lines
that folds are only observable in a live window and records that **a mutation survived a source-grep**;
`review_view_spec.rb:886-894` shows `before(:context)` was **measured and correctly rejected** (a spawn
is 5-6ms; the 29ms was the whole hook, not the spawn). Those files earned their cost.

**Where docs and code disagreed.** `CLAUDE.md:177`'s 2.5% seam figure was accurate on 2026-08-05 at 26
files; it is now **8.35%**. **The measurement wins** — and the correction has **not shipped**.
simplify-01 is `status: done` and its T7 landed the spec-mirror relaxation (`CLAUDE.md:60` now reads
*"one spec file per public entry point, at its mirrored path"*), but it never touched `:177`. T2 or a
follow-on still owns that edit, and the number it should carry is 8.35%.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `spec/spec_helper.rb`, `spec/support/tags.rb`,
  `Rakefile`, `.rubocop.yml`, `lib/lain.rb`.
- **`spec/support/` additions need no manifest edit** — `spec_helper.rb:40` globs `support/**/*.rb`
  recursively. But `webmock/rspec` is required from `spec_helper` itself (`:16-19`) because the glob's
  alphabetical order matters, and `support/watchdog` is required out of band at `:33` because `around`
  hooks nest in definition order. **Anything a new support file must load before or after needs the
  orchestrator**, not a card.
- This plan assumes **simplify-01's spec-mirror relaxation has landed** for T1 — splitting to mirror
  paths for Lua modules needs a convention for what a Lua module's mirror path *is*. **It has landed**:
  simplify-01 is `status: done` and `CLAUDE.md:60` now reads *"one spec file per public entry point, at
  its mirrored path."*
- **T1 is unblocked: simplify-14 was declined.** An earlier draft made simplify-14 run before T1, on the
  reasoning that 14's T1 deletes four whole groups from `neovim_runtime_spec.rb` and splitting first
  would mean creating spec files for Lua modules about to be deleted. **The human declined simplify-14 on
  2026-09-13**, and the decision is recorded at `planning/specs/simplify-07-frontend-dedup.md:833`, under
  *"The simplify-14 question, answered"*: *"14 is unlikely to run, so T3 goes ahead as written."*
  simplify-07 closed its chunk on that basis and `88c13d54` is in HEAD. **So T1 splits all 18 describes**,
  and no future reader should re-defer it on 14's account — the groups 14 would have deleted (1,536
  lines, 921 code, 37 of 102 examples) are staying. The reasoning was sound while 14 was live; it is
  simply no longer operative.
- **T2's breadth is not a wave hazard — measured.** An earlier draft said T2 and T5 must not share a wave
  with another plan's large spec edit. Every spec file named in simplify-08 and simplify-09 was
  intersected against T2's 65 top-level-`:seam` files: **08 overlaps on exactly one file**
  (`spec/lain_spec.rb`, 54 code lines, one top-level `:seam` describe) and **09 on none**. One 54-line
  file is not a reason to serialize a wave, so this is a **note**, not a constraint: mention
  `spec/lain_spec.rb` to whoever runs 08 and move on. (T5 is dropped — see Open decisions; simplify-09 was
  dropped entirely on 2026-09-13, so only 08 runs alongside this plan.)
- **The real contention is internal, and it is `spec/lain/tools/subagent_spec.rb`.** **T7 and T8 must not
  share a wave.** T7 names the file explicitly (*"already has `build_subagent`"*), and it is T8's
  seventh-heaviest `Sync do` file (19 sites). At 3,023 raw / 1,871 code lines with 14 reach-ins it is one
  of the biggest spec files in the tree, and two cards editing it in one wave is a conflict the plan
  creates for itself — simplify-09 would have made it three-way, but 09 was dropped. See Waves.

## Open decisions

- **What a Lua module's mirror path is.** T1 splits `neovim_runtime_spec.rb` into per-module files, and
  `lib/lain/frontend/neovim/runtime/45_views.lua` has no established spec path. The card proposes
  `spec/lain/frontend/neovim/runtime/45_views_spec.rb` and notes that the numeric prefix — which is the
  load order — then appears in a spec filename, which is either honest or ugly. Panel decides.
- **Whether `spec_discipline_spec.rb` becomes a `bin/` script or a real guard.** T3 moves it to `bin/`
  because it cannot fail today. Its own comment says the intent was always to make it a **ratchet**
  (`count <= <ceiling>`) once the count drops — which is what the script's `--check` flag should
  implement. Moving it is reversible; making it a hard guard now would need a 184-entry allowlist, which
  is a disabled guard wearing a spec's name.
- **How far T11 goes.** 2,063 message matchers is too many to convert in one plan. The card establishes
  the catalog, picks its own scope, and reports the remainder as a standing worklist — it can no longer
  ride simplify-06's edit window, because that window has closed (see T11).
- **T5 is DROPPED, and the figure that justified it was a static over-count.** The card was built on
  *"28 files re-enumerate the repo's own `lib/` tree — 9,271 code lines (6.2% of the suite), 50.4s of
  508.2s = 9.9% of example time … split 21 non-discipline and 7 discipline."* Re-measured three ways:
  **(1)** specs whose *runtime* code globs `lib/**/*` — **four** files
  (`spec/error_taxonomy_discipline_spec.rb`, `spec/lain/frontend/neovim_spec.rb`,
  `spec/plugin/nvim_plugin_spec.rb`, `spec/repo_as_fixture_spec.rb`), and the last one's matches are
  **inside heredoc fixtures**, because it is a guard *against* the pattern, so it does not scan; of the
  three real ones one is a discipline spec, leaving **two** non-discipline lib-tree globbers. **(2)**
  Adding specs that read individual `lib/` files or parse with Prism/Ripper: ~14 files, ~8 of them
  discipline specs. **(3)** Any spec globbing any repo-ish path: 45 files — but that is dominated by
  tmpdir and fixture globs and is not what the card meant. **Nothing supports 21 non-discipline files.**
  The honest figure is two to six. The 50.4s time claim is separately UNVERIFIED and needs a `pspec` run.
  **And the pattern is now policed**: `spec/repo_as_fixture_spec.rb` (236 code lines) landed in the
  divergence window as a mechanical Prism guard forbidding *"an example — or a shared group carrying
  examples — brought into being by a scan of this repository's own tree"*, after a spec that globbed
  `planning/specs/*.md` minted one example per document and made adding a plan doc move the suite's
  example count. `spec/support/tree_index.rb` was never created. A shared index for twenty-one scanners
  that are not there is not a card; if the two real globbers ever become a cost, that is a fresh
  grounding, not this one.


- **T9's rule is disproven, and the disproof is the card's real output. Settled 2026-09-13; nothing
  is deleted.** The card rested on *"a helper is exercised by the specs that use it; a broken helper
  reddens them."* That is false for precisely the helpers it named, and it was tested rather than
  argued: **gutting `be_deeply_frozen` to always-pass left 203 user examples green** while only
  `support_matchers_spec.rb` reddened. A helper whose failure mode is **silent** — a matcher that
  always passes, a counter that under-counts, a watchdog that never fires — does not redden its
  users, so its users are not its coverage. `support_store_fetch_count_spec.rb:13-16` says so in its
  own header, and `SpecWatchdog::Starvation` never runs in a green suite at all. **The refined rule,
  which is worth more than the 699 lines:** a helper needs its own spec exactly when its breakage is
  quiet. That is the same family as `CLAUDE.md`'s "check the example COUNT, not just the failure
  count" and the mutation-harness trap.

  **The mutation figure is narrower than first written, and the correction matters more than the
  number.** The 203 green examples were **the four value-object specs sampled** (`event`, `store`,
  `context`, `timeline`), not the suite. `be_deeply_frozen` defines `match` and
  `failure_message_when_negated` but **no `match_when_negated`**, so `not_to be_deeply_frozen` negates
  `match` — and gutting `match` to always-true therefore reddens every negated site. There are eight,
  all running in a default suite (`approval/remembered_spec.rb:323`, `agent/instrumentation_spec.rb:72`,
  `review/lazy_file_spec.rb:253`, `cli/wiring_spec.rb:1141`, `tool/result_block_spec.rb:240`,
  `compaction/strategy/summarizing_spec.rb:231`, `compaction/source_spec.rb:1367`,
  `compaction/strategy/summarize_conversation_spec.rb:307`). The four sampled files happen to contain
  zero negated uses, which is why they stayed green — a property of the sample, not of the suite.

  **The rule still holds**, for the reason that survives the correction: a **positive**
  `to be_deeply_frozen` genuinely cannot tell, and the matcher's diagnostics, refusals and termination
  are covered by nothing but its own spec. What the correction kills is the stronger gloss that *no*
  user spec could catch the mutation. Eight could have caught this particular one.

- **The caller counts the card and this plan both published were wrong, and the method was wrong.**
  `spec/algebra_laws_spec.rb:280` is `include_examples AlgebraLaws::GROUPS.fetch(declaration.structure), config`
  — **dynamic dispatch, invisible to any grep for a literal `it_behaves_like "name"`**, which is how
  every count in this plan was produced. Re-derived: `"an elementwise map"` has **2** callers (not 0),
  `"a pure operation"` **4** (not 1), `"an attenuation"` **2** (not 1). All three clear the card's own
  two-caller threshold and stay. `spec/support/shared_examples/elementwise.rb` is additionally
  undeletable for a second reason: it also defines `AlgebraLaws::Elementwise` (`:61-63`), read by
  `algebra_laws_spec.rb:125` and `compaction/strategy_spec.rb:278` — moving it aside kills **122
  examples** with an `uninitialized constant`. **Any later card that counts spec references must
  resolve dynamic dispatch, not grep literals.** T6 and T10 both count; warn them.

  > **2026-09-14, amended.** `simplify-09-orders-as-types.md` deleted the registry this bullet's
  > dynamic dispatch ran through: `spec/algebra_laws_spec.rb` and `spec/lain/algebra_spec.rb` no
  > longer exist, `Lain::Algebra` has no `lib/` reference, and each live law now runs inline in its
  > subject's own spec (`7a1d4602`). The dynamic-dispatch undercounting this bullet warns about
  > cannot recur through that file, because the file is gone — but the general lesson stands for
  > whatever counts a card runs next. `spec/support/shared_examples/elementwise.rb` and the
  > `AlgebraLaws` module it uses are **not** part of what was deleted and are still live: `"an
  > elementwise map"` still has (at least) its two literal `include_examples` callers
  > (`spec/lain/context/dedupe_tool_calls_spec.rb`, `spec/lain/compaction/strategy/elide_spec.rb`),
  > confirmed by a direct grep rather than re-derived through the now-gone dynamic dispatch this
  > bullet had to work around. Re-count before trusting either number as still current.

- **A drifted guard found in passing, and it is T3's defect in another file.**
  `spec/support_vsock_availability_spec.rb:136-146` is a **byte-for-byte copy** of
  `spec/support/tags.rb:238-246` rather than a reference, and the two have **already drifted** —
  `tags.rb:241` now says *"the kernel's vsock_loopback transport is unavailable"* against the copy's
  *"vsock_loopback unavailable"*, so the spec's `include(...)` at `:193` passes against its own copy
  and would fail against the real sentence. It is a check that cannot fail, which is exactly what T3
  is moving to `bin/` in a different file. The spec is also the **only** caller of
  `VsockAvailability.available?` in a default run, and `:176-178` is the only assertion that the real
  config excludes `:vsock`. Fixing it means referencing `tags.rb` instead of copying it — a rewrite,
  not a deletion, and not this card. Filed here so it is not lost.

- **T3's packer-poisoning claim is FALSE, proved by experiment 2026-09-13.** The plan asserted the
  advisory lines written into `tmp/parallel_runtime_rspec.log` are parsed by the knapsack packer as a
  phantom multi-second entry, mis-packing every subsequent run. They are not. `parallel_tests`'
  `runtimes` does `rpartition(':')` and then `if tests.include?(test)`, so a line whose left side is
  not a known spec path is **discarded before it becomes an entry**. The implementer called `runtimes`
  directly on a log seeded with both advisory lines and confirmed no phantom key survives. There are
  also **two** such lines, not one — `lib reach:` goes unmentioned in this plan.

  The lines are still worth removing: writing prose into a machine-read file is the same hazard
  CLAUDE.md names for the Journal. But **no mis-pack has been happening**, the card's escalation
  trigger about filesize-vs-runtime packing is settled without a `pspec` run, and any wall change on
  cleanup is purely the 5.9s file leaving the packer's input.

- **T3's subject was also mis-described, and the correction changes the arithmetic.** Only **2 of the
  41 examples** were report-only; the other 39 are ordinary unit tests of two Prism scanners costing
  0.02s in total. `--profile` puts **5.91s of 5.93s (99.7%)** in the two whole-tree examples, which is
  where the saving actually is. Both "report-only" examples additionally carried a real assertion
  (`listed == violations.size`, guarding the renderer against dropping an entry), and the file hid a
  live tree guard — `FixtureDiscipline`'s *"finds none in the real spec/fixtures"* reddens the day
  someone plants a collectible file in a fixture project. Neither was deletable; both were preserved.

  **So the suite grows rather than shrinks: the delta is +5, not −41** (−41 deleted, +44 for the
  script's own spec, +2 for the preserved fixture guard). Any later card comparing against a baseline
  must use **17,842**, not 17,796.

- **`bin/spec-census` gets no pre-commit hook, by decision.** `bin/comment-census` — the precedent the
  card cites — has neither a rake task nor a hook, and CLAUDE.md calls it *"the worklist"*. Parity is
  the right default, and gating on a ratchet is its own decision with its own cost. `--check` exists
  and provably exits non-zero, so the gate can be added the day someone wants it.

- **T3 moves comment mass out of every density check the repo has — a move, not a prune.** The
  deleted `spec/spec_discipline_spec.rb` was 842 code / 405 prose **inside** `bin/comment-census`'s
  documented scope (`lib/`, `spec/`, the runtime Lua). The replacement puts 344 / 44 back in scope and
  lands a 546-line script in `bin/`, which is outside that scope — and `comment-census` cannot read it
  regardless, since `language_for` keys on the file extension and `bin/spec-census` has none. So the
  next census reads roughly **361 fewer in-scope prose lines** because of this card, and the script's
  own 79-line module doc is measured by nothing. Nothing was gamed and the prose is load-bearing;
  recorded once so a later reader does not bank the delta as a prune.

- **After T3, the censuses no longer touch the real tree in any automated run.** The deleted spec
  walked all 791 spec files and all of `lib/` with Prism on every suite run, which incidentally proved
  the walk survived the actual tree. The 37 in-memory fixtures cover the scanner's API surface well,
  so the residual exposure is narrow — a Prism upgrade or a novel construct that crashes the walk now
  surfaces only when a human runs the script — and since the scan is report-only, a crash costs the
  report and nothing else. Known, accepted, not blocking.

## Waves

Wave 1: T3, T4, T9
Wave 2: T1 (←T4), T2
Wave 3: T6 (←T1), T7, T10, T11, T12
Wave 4: T8
Critical path: T4 → T1 → T6

**T5 is dropped** (see Open decisions) and leaves wave 2.

**T12 left wave 1.** It was there deliberately, to clear a blocker for simplify-01's prose work and
simplify-04's comment cleanup — and **both of those are `status: done`**, so the blocker cleared itself.
The card's original three subjects went with them; it is retargeted onto six others and can run any time.

**T8 moved to a wave of its own.** T7 and T8 both edit `spec/lain/tools/subagent_spec.rb` — the plan's
only serious contention, and it was scheduled as a single wave. Serializing is the whole fix.

**T6 stays in wave 3 because it edits `spec/lain/frontend/neovim/review_view_spec.rb`, which T1 splits** —
T6 would otherwise be editing a path that no longer exists.

**Re-ground before executing, in this order of urgency**: T1's 18-describe module map (every line number
moved, one describe is new — the map above is the re-derivation); T2's percentage (8.35%, not 21.4%); the
reach-in ranking (two of five ranks dead or mis-ranked, one path moved, the real #2 unnamed until now);
T6's clone clusters (one of three is gone); T3's three figures (41 / 5.05s / 184).

## Tasks

### T1 — Put twelve-plus subjects at twelve-plus mirror paths   [wave 2] [risk: medium]

**Depends on:** T4
**Files:** split `spec/lain/frontend/neovim_runtime_spec.rb` into per-module files under
`spec/lain/frontend/neovim/runtime/`; split `spec/lain/frontend/neovim/review_view_spec.rb` and
`spec/lain/frontend/neovim/thread_view_spec.rb`; modify `spec/lain/telemetry_spec.rb`
**Reuse:** T4's shared `HeadlessEditor` support module — each split file needs the harness, and five
variants across 21 sites is what makes splitting expensive today
**Shared-file wiring:** none
**Reachable from:** these are specs; the "production path" check is that the same behaviours are still
asserted. AC 4 is that the total example count is unchanged.

`neovim_runtime_spec.rb` is **3,612 raw / 2,204 code lines, 102 examples** with **one** top-level describe
and **18** second-level ones, each targeting a different Lua module. Splitting it to mirror paths is what
the anti-sharding rule *wants* — it forbids carving up a single-subject spec, and this is twelve-plus
subjects in one filename.

**Work from the Grounding's re-derived map, not from remembered line numbers.** Every line number an
earlier draft carried has moved, and one describe is new: *"the rail table's one lua dispatch"* at
`:303-366`, landed by `88c13d54` as simplify-07's T3 and citing `45_views`. The `70_inbox` group that used
to sit near `:300` is now at `:367`.

`review_view_spec.rb` (1,660 raw / 965 code, 4 top-level describes) holds four subjects and three
harnesses; `thread_view_spec.rb` (1,976 raw / 1,126 code, 3 top-level describes) is really a spec of
`runtime/51_thread.lua` plus a small one of `thread_view.rb`. `telemetry_spec.rb` (976 raw / 697 code) is
an index spec for a 27-file subtree.

**The wall-clock floor falls as a side effect.** At **22.52s** measured against a 23.4s floor,
`neovim_runtime_spec.rb` is why `--tag '~seam'` barely helps — but that is the consequence, not the
goal, and the card should not optimize the split for the packer. **The floor itself is UNVERIFIED**: it
needs a `pspec` wall, so measure it before claiming the card moved it.

**Acceptance criteria**

```gherkin
Scenario: each Lua module's behaviour is asserted at its own mirror path
  When the spec files under the runtime spec directory are listed
  Then each corresponds to one runtime Lua module

Scenario: the editor behaviours still hold
  Given a live editor
  When each split spec runs
  Then every behaviour previously asserted still passes

Scenario: no behaviour was lost in the split
  When the example count across the split files is compared with the original
  Then it is the same or greater
```
→ spec files: the split files themselves; AC 3 is verified by counting and recorded in the commit message

**An acceptance criterion was removed because its subject is gone.** An earlier draft carried *"a spec
that touches no editor spawns none"*, resting on five examples at `:908`, `:925`, `:952`, `:965` and
`:986` said to read only `protocol_history` and a file. **All nine examples in the `"the runtime digest"`
group (`:853-1044`) reference `@socket` and drive a real editor**, and no `protocol_history`-only example
remains in the file. There are no wasteful spawns to delete here.

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
- **This trigger has already fired.** *"If two of the 18 describes share a `let` or a helper, splitting
  duplicates it."* The file defines `all_views`, `ApprovalSeamSupport` and a shared `channel` let at file
  scope, used across groups. That is T4's job to absorb — if T4 has not landed, **stop**, because five
  harness variants will become eighteen.

### T2 — Tag the real resources, not the files that contain them   [wave 2] [risk: medium]

**Depends on:** none
**Files:** modify the **65** spec files that tag their top-level describe `:seam` (66 occurrences — one
file carries two); and `CLAUDE.md:177`, which still documents 2.5%
**Reuse:** `spec/lain/seams/` is the directory for seams belonging to no single subject — 29 files,
already correctly scoped at 1.34% of examples — it is the model
**Shared-file wiring:** none
**Reachable from:** the tag decides what `--tag '~seam'` excludes; AC 3 measures the inner loop it is
supposed to serve

**65 files tag the top-level describe**, so every example in them inherits `:seam`, and in those files
only **15.4%** of example bodies touch a real resource. The tag covers **8.35%** of examples against a
documented 2.5% — **3.3× its documentation, not 8.6×**.

**The urgency is lower than an earlier draft's; the case is not.** *"3,483 examples (21.4%)"* was a static
grep over the 115 files containing `:seam` anywhere, which charges every example in a file to the tag and
counts `it "…"` inside heredoc fixtures. The measured figure is 1,489 of 17,837. The tag also **stopped
growing**: 114 → 115 files in the divergence window, 67 → 66 top-level describes. So this card is about
**precision, not a runaway** — and precision is still worth having, because a tier that covers 3.3× what
it says it covers makes `--tag '~seam'` mean something other than what CLAUDE.md says it means. The 15.4%
real-resource figure inside the 65 files is a per-example judgment rather than a count and was **not**
re-derived; treat it as unverified and let the per-file reading produce the real number.

**`CLAUDE.md:177` still says 2.5%, and nothing has corrected it.** An earlier draft deferred that to
simplify-01's T7; 01 is `status: done` and its T7 landed the spec-mirror relaxation at `CLAUDE.md:60` but
never touched `:177`. This card owns the prose now, and the number it writes is whatever the re-tagging
leaves — measured, not the 8.35% it starts from.

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
  `pspec`** today because `neovim_runtime_spec.rb` alone is 22.52s against a 23.4s floor — and that file
  is **`:nvim`-tagged, not `:seam`-tagged**, so re-tagging seams will not touch it. If T1 has not landed,
  re-tagging will not visibly help — do not conclude the card failed.
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
measured cost (**5.05s**, not the 6.49s an earlier draft carried)

`spec/spec_discipline_spec.rb` is **835 code lines** (exact) **, 41 examples, 5.05s**, and `~:76-86`
states that it *"prints the report and passes"* by design, because a real guard would need an allowlist
sized to that count — *"a disabled guard wearing a spec's name."* Its own stated follow-up is to become a
**ratchet** — `count <= <ceiling>`, not a hard failure — once the count is down, and that is precisely
what the `--check` flag below should implement.

**The example count was an over-count of the same kind as T2's.** An earlier draft said 61 examples /
6.49s; a static `grep` sees 61 because the file embeds Ruby *fixtures* in heredocs that themselves contain
`it "…"` lines. RSpec loads **41**. The 835 code lines are exact.

It also **poisons the parallel packer**: it writes advisory lines through
`RSpec.configuration.reporter.message` into the file `--out` redirects (`Rakefile:31`), so
`tmp/parallel_runtime_rspec.log` carries, at `:570` of 753 lines:

    spec discipline: 184 flagged example(s) -- {sole_raise_error: 170, nested_expect: 14} (full listing: …)

which the knapsack packer parses as a **184-second phantom entry**. `Rakefile:27-31` still chooses
`--group-by runtime` only when the log exists, so the mis-pack is live.

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
against `tmp/parallel_runtime_rspec.log`: **37 of 736 lines** at `d2bb133c`, and the same shape at
`d4a7a1ea` (753 lines, 12 of them naming "discipline"), do not have that shape — and none of them is this
card's doing — one `Run options: exclude {...}` line per worker from RSpec itself,
plus four `Skipping :<tag> specs...` lines per worker written by `spec/support/tags.rb`. Twelve workers,
five lines each, minus the workers that print fewer. The card cannot make them go away and should not
try, so the criterion is narrowed to what it actually owns: the report this plan is removing is no
longer in there.

**Escalation triggers**
- The script must **fail** with a non-zero status when asked to gate (a `--check` flag), even if nobody
  gates on it yet. A script that only ever prints is the same defect in a new location. Implement the
  **ratchet** the spec's own comment names — `count <= <ceiling>`, seeded at 184 — rather than a hard
  zero, which is the shape that would need the allowlist.
- `Rakefile:29-31` chooses `--group-by runtime` only when the log exists. If the log has been poisoned
  for a while, the current packing may be **worse than filesize packing** — measure one `pspec` with the
  cleaned log and report whether the wall changed.
- If any of the 41 examples asserts something real alongside the report, that assertion must survive.
  Read them; a report-only spec that grew a real check is the likeliest surprise.

### T4 — One headless-editor harness   [wave 1] [risk: low]

**Depends on:** none
**Files:** create `spec/support/headless_editor.rb`; modify the **21 sites across 20 spec files** that
spawn one
**Reuse:** **`spec/support/socket_tmpdir.rb` already exists, is globally included
(`socket_tmpdir.rb:51`'s `config.include SocketTmpdir`), and has exactly one user** —
`spec/lain/frontend/neovim/diff_mode_spec.rb:59`'s `SocketTmpdir.persistent("lain-diff-spec")`. It was
written for exactly this and is the starting point; **an earlier draft said "none of the 23 uses it",
which understated what is already there.** One adopter is a precedent to extend, not a helper to justify
from scratch — read that call site before designing the interface.
**Shared-file wiring:** none — `spec_helper.rb:40`'s glob picks it up. But if it must load **before**
`support/watchdog` (`spec_helper.rb:33`), that ordering is the orchestrator's.
**Reachable from:** it is test infrastructure; AC 3 is that every editor-driving spec still passes

**21 sites across 20 spec files**, **five variants** of the same spawn-wait-reap dance, one of them using
the `SocketTmpdir` helper written for it. The `around` hook at `neovim_runtime_spec.rb:24-41` is unchanged
and still the most complete — it spawns `nvim --headless --clean -n --listen <socket>`, waits with a
10-second timeout for the socket to appear, and reaps with `TERM` plus `Process.wait`, rescuing
`Errno::ESRCH, Errno::ECHILD`, with the socket named from `Process.pid` **plus** `rand(1_000_000)`.

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

### T5 — DROPPED   [was wave 2]

**Dropped 2026-09-13.** The card proposed one shared tree index for twenty-one `lib/`-scanning specs.
Re-measured, **two non-discipline specs glob `lib/**/*` at runtime**, not twenty-one, and
`spec/repo_as_fixture_spec.rb` landed in the divergence window as a mechanical guard *against* the
pattern. The full re-measurement, and what would have to be true for the card to come back, is in **Open
decisions**. Nothing else in the plan depended on it.

### T6 — Table-loop the confirmed clone clusters   [wave 3] [risk: low]

**Depends on:** T1
**Files:** modify `spec/lain/cli/up_spec.rb`, `spec/lain/cli/human_replies_spec.rb`,
`spec/lain/frontend/neovim/review_view_spec.rb`
**Reuse:** RSpec's `where`-style iteration over a table of `[input, expected]` pairs; no new helper
**Shared-file wiring:** none
**Reachable from:** specs; AC 3 is that the same inputs are still covered

Copy-paste parameterization is only 1.7% of the suite overall, so this card is deliberately narrow —
**only the confirmed clusters**. Re-derived 2026-09-13, because two of the four an earlier draft named
were wrong:

- **`up_spec`'s Hud group — confirmed.** `describe "Hud, printing the line the state feed published"` at
  `:1503` (12 → 1).
- **`up_spec`'s `.lain_exports` group — GONE.** The string `lain_exports` does not appear anywhere in
  `spec/lain/cli/up_spec.rb`. There is nothing to table.
- **`up_spec`'s "argv group" — NOT A GROUP.** No describe is named for argv. The argv assertions are
  scattered through `#attach_command` (`:470`) and `#launch_plan composition` (`:519`), and `:466`
  comments that the block is *"Pure argv construction — no shell-out at all."* Scattered assertions
  across two describes are not a clone cluster; **either name a single describe or leave them.**
- **`review_view_spec` — confirmed, at a new line.** The group is `describe "rendering into the review
  tabpage"` starting at `:958` (8 → 1); an earlier draft cited `:959-1012`.
- **`human_replies_spec`'s "two groups (18 and 11)" — NEEDS RE-DERIVATION.** The file now has 18
  second-level describes and neither cluster is identifiable from an example count alone. **Name them by
  describe string before converting**, and if no two of the 18 are actually clones, say so and drop them
  from the card rather than forcing a table.

So the confirmed work is **two clusters**, not five, and the card's ~900-line estimate is the first thing
to re-measure.

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
**Reuse:** `spec/lain/tools/subagent_spec.rb` **already has `build_subagent`** — **74 references** to it —
and already forwards `**seam`; part of this card is using what exists rather than writing it
**Shared-file wiring:** none
**Reachable from:** test infrastructure; AC 3 is that the specs using it still assert the same things

**4,033 `Lain::*.new(` sites.** `Journal` appears in 134 files, and **83 files hand-build three or more
core classes**. One factory with sensible defaults and keyword overrides, so a spec varying one member
does not respell the graph.

**Do not convert all 83. Convert these**, measured as the heaviest builders — `supervisor/restart_spec.rb`
(6 core classes), then `supervisor_spec.rb`, `cli/command/rewind_spec.rb`, `cli/command/pin_spec.rb`,
`cli/goal_driver_spec.rb`, `cli/command/goal_spec.rb`, `cli/repl_spec.rb`, `cli/resend_bridge_spec.rb`
(5 each). Measure the saving and report the rest as a standing worklist — a factory adopted by 10 files
and ignored by 73 is worse than none, so the card should say what would make adoption default.

**`spec/lain/tools/subagent_spec.rb` is contended.** T8 also targets it (19 `Sync do` sites), so **T7 and
T8 do not share a wave** — see the Orchestrator contract.

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

### T8 — Hoist the async ceremony   [wave 4] [risk: medium]

**Depends on:** none (but **must not share a wave with T7** — both edit
`spec/lain/tools/subagent_spec.rb`)
**Files:** create `spec/support/supervised.rb`; modify the spec files with the heaviest `Sync do`
concentration, measured as:

```
57  spec/lain/supervisor_spec.rb          22  spec/lain/provider/admission_spec.rb
42  spec/lain/tools/ask_human_spec.rb     19  spec/lain/tools/subagent_spec.rb
38  spec/lain/cli/human_replies_spec.rb   16  spec/lain/oracle/eager_spec.rb
32  spec/lain/review/docent_spec.rb       13  spec/lain/supervisor/restart_spec.rb
25  spec/lain/approval/queue_spec.rb      13  spec/lain/supervisor_reactor_spec.rb
```
**Reuse:** the existing `Sync do` blocks are the behaviour; this is a wrapper, not a replacement
**Shared-file wiring:** none
**Reachable from:** test infrastructure; AC 2 is the property that must not be lost

**489 `Sync do` sites across 77 files.** A `supervised(**wiring) { ... }` helper hoists the ceremony —
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
- 489 sites is too many for one card. Convert the heaviest files, measure, and report the rest. Say
  explicitly that a partially-adopted helper leaves the hang risk in the unconverted files.
- **`spec/lain/tools/subagent_spec.rb` is T7's target too**, at 3,023 raw / 1,871 code lines with 14
  reach-ins. It is seventh on the list above; if serializing the waves is not enough, drop it from this
  card rather than editing it alongside T7.

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

**`"an elementwise map"` (138 lines) has zero `it_behaves_like` callers.** The 1-2-caller tail, re-counted
2026-09-13 across **25** groups (not 26): *"an attenuation"* (263 lines, **1** use — file is 263 lines
exactly), *"a pure operation"* (145, **1** — 145 exactly), **`"a tier-1 read of any path that never
raises"`** (`tier_one_read_contract.rb:100`, **1**), *"an ollama deployment"* (2), *"a monoid
homomorphism"* (2), and six more at 2. A shared example with one caller is indirection with no reuse —
inline it.

> **2026-09-14, amended — do not delete `elementwise.rb` or inline the law groups.** Since
> `simplify-09-orders-as-types.md` the law groups are included literally in their subjects' specs, and
> `ARCHITECTURE.md`'s algebra section now describes that as the design: `"an elementwise map"` has 2
> callers (`dedupe_tool_calls_spec.rb`, `elide_spec.rb`) and its battery 3 readers, and stays;
> `"an attenuation"` (1 literal caller, `toolset_spec.rb`, plus a direct battery read in the same
> file) and `"a pure operation"` (4 callers today) are law groups whose battery is also read by a
> negative example, and are exempt from the two-caller rule, because inlining one splits a law's
> positive and negative readings into two transcriptions. A new law group also starts with one caller
> (ARCHITECTURE's "How to hold an operation to a law", step 1), so the threshold cannot apply to law
> groups at all. As written, this card's file list and AC 2 would undo that; re-scope them to the
> non-law groups before running it.

**Two changes to the card's list.** `"an exec boundary matching bash"` **no longer exists**: it was
renamed `"an exec backend answering for a term"` (`exec_term_contract.rb:34`) and now has **3** callers,
so it leaves the list entirely. And `"a tier-1 read of any path that never raises"` is a **new** 1-caller
group the card did not name — note that its sibling `"a tier-1 read that never raises"` in the *same file*
has 3, so inlining one and keeping the other is the right answer only if a reader can tell them apart;
say which is which, or state why the 1-caller one is exempt.

**Keep the law groups with two-plus callers.** `store_laws` (3), `meet_semilattice` (4), `regular` (11),
`canonical_laws` (2) are differential across implementations and simplify-13 depends on them — all four
verified at two-plus.

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
- `spec/support_vsock_availability_spec.rb` holds a **byte-for-byte copy** of a region of
  `spec/support/tags.rb` rather than a reference — so `tags.rb` can drift and it stays green. Deleting the
  spec removes a (broken) check; say so rather than implying nothing was lost. **The line numbers have
  drifted**: `tags.rb:238` is now `config.filter_run_excluding(:vsock)`, so **re-locate the copied region
  before relying on `:136-146` / `:238-246`.**
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

**168 examples pin completed refactors.** The headline exhibit survives, at
`spec/lain/telemetry_spec.rb:109-123` (an earlier draft said `:108-121`) — it still **re-implements the
old `gsub`** it replaced, i.e. the spec carries a copy of the code it exists to say is gone:

```ruby
hand_rolled = name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
expect(name.underscore).to eq(expected).and eq(hand_rolled)
```

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
- 168 is an estimate from a sampling pass, not an enumeration, and **it stayed unenumerable on
  re-measurement** — no mechanical proxy reproduces it. Work file-by-file and report the real count; do
  not delete to reach a number, and do not restate the estimate as a measurement.

### T11 — Own each refusal sentence once   [wave 3] [risk: high]

**Depends on:** none
**Files:** create `lib/lain/refusals.rb` (or extend an existing catalog — the card chooses and says
why), `spec/lain/refusals_spec.rb`; modify a refusal family **this card picks**, and its spec files
**Reuse:** `spec/refusal_width_discipline_spec.rb` already mechanically owns refusal **shape**, so this
completes a started pattern.
**Shared-file wiring:** a manifest line in `lib/lain.rb` if a new file
**Reachable from:** every refusal a user reads comes from here; AC 1 drives a real refusal through
`exe/lain`

**2,063 of 3,500 `raise_error` calls (58.9%) carry a message matcher.** Since cross-file duplication is
low (19 literals across ≥2 files), the problem is not duplication but **ownership**: every copy edit to a
sentence is a spec edit somewhere else. (An earlier draft added *"3,940 assertions pin prose overall"*;
that figure was not independently reproducible and is dropped.)

> A catalog keyed by symbol. Unit specs assert the **key**; one catalog spec asserts the **wording**.

**The edit window this card planned to ride is CLOSED — simplify-06's T5 has already landed.** The card
was scoped to convert *"the refusal families simplify-06's T5 is already collapsing — the same files, the
same edit window"*, and its third escalation trigger said *"prefer T5 first."* simplify-06 is
`status: done`: `lib/lain/config/refusal.rb` exists and `Config::Refusal` is referenced at **37** sites in
`lib/`. The 31-class collapse is finished. **So the sequencing trigger is satisfied, not pending — and
this card must choose its own scope.** That is a real change in the card's shape: it no longer gets a
subsystem handed to it mid-edit, so it must name a refusal family, argue why that one first, and accept
that it is opening those files rather than joining someone already in them. The good news is the
precondition the trigger wanted: a catalog keyed by symbol **is** easier over one refusal class than over
31, and there is now one.

**Scope this card deliberately.** 2,063 matchers is too many for one plan. Establish the catalog and the
pattern over one family, then **report the remainder as a standing worklist**. A catalog adopted by one
subsystem and ignored by the rest is worse than none, so the card must say what would make adoption
default — probably a discipline check, which is its own decision.

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
- **This trigger is discharged.** It said to sequence against simplify-06's T5 and prefer T5 first.
  simplify-06 is `status: done` and `Config::Refusal` is live at 37 `lib/` sites, so there is no
  concurrent edit to sequence against — only a landed shape to build on.
- `spec/refusal_width_discipline_spec.rb` asserts refusal **width**. A catalog that concatenates a template
  and values could exceed it at runtime while every fixture passes — check that the width guard sees the
  rendered sentence, not the template.

### T12 — Stop specs from reading source text   [wave 3] [risk: low]

**Depends on:** none
**Files:** modify `spec/lain/sensitivity_spec.rb`, `spec/lain/sensitivity/ledger_spec.rb`,
`spec/lain/approval/queue_spec.rb`, `spec/lain/survey/chunker/code_spec.rb`,
`spec/lain/frontend/neovim/thread_view_spec.rb`, `spec/lain/frontend/neovim/review_view_spec.rb`
**Reuse:** the constants and behaviours these specs scrape are almost all reachable as **values** — a spec
can read a constant rather than the comment above it, and ask an object what it does rather than reading
how it does it
**Shared-file wiring:** none
**Reachable from:** specs; AC 1 is that the intent each spec had is still asserted

**This card was re-grounded on 2026-09-13, and its subjects changed completely.** It named three
scrapers; all three are discharged:

- **`up_spec.rb:882-887` — the headline, the spec enforcing a minimum comment length — has no subject
  left.** `CONSENT_ENV` does not exist anywhere in `lib/` (removed by `c40ab419`, *"delete Lain::Notify,
  and give request_review a way to tell the human"*), and `spec/lain/cli/pane_command_spec.rb:184` now
  asserts it is **not** defined. `up_spec.rb` reads no source and references no such constant.
- **`inbox_view_spec.rb:979` and `approval_view_spec.rb:621` — gone.** `:994` and `:675` are now prose
  comments, not assertions over source text, because **simplify-07's T7 landed** and did most of this
  card's second acceptance criterion: `Fold::INDENT` is the one Ruby spelling
  (`lib/lain/frontend/neovim/inbox_view.rb:84` and `approval_view.rb:96` both read `INDENT = Fold::INDENT`),
  and the cross-language pin survives at exactly **one** site, which is arguably the shape this card
  wanted:

      spec/lain/frontend/neovim/fold_spec.rb:56  def runtime_source(file) = File.read(File.join(…MODULES, file))
      spec/lain/frontend/neovim/fold_spec.rb:59  pattern = runtime_source("05_records.lua")[/^local CONTINUATION = "\^([^"]*)"$/, 1]

  **That one stays.** A Ruby constant and a Lua literal that must agree have no shared runtime, so
  reading the Lua is the only mechanism there is. It is the exception the card should name.

**The card's own escalation trigger fired, and this is what it found.** It said *"if a fourth
source-scraping spec turns up, add it — but report it, because three was the measured count and a fourth
means the pattern is spreading."* There are **six**, and none is one of the three the card named:

| site | what it reads | why it is the wrong shape |
|---|---|---|
| `spec/lain/sensitivity_spec.rb:593` | `lib/lain/sensitivity.rb` source | the classifier's behaviour is callable; ask it |
| `spec/lain/sensitivity/ledger_spec.rb:120` | `lib/lain/sensitivity/ledger.rb` source | same |
| `spec/lain/approval/queue_spec.rb:598` | `lib/lain/approval/queue.rb` source | same |
| `spec/lain/survey/chunker/code_spec.rb:281,288,404` | `lib/lain/cli/command/goal.rb` and others | uses a real source file as a **fixture** — legitimate input, but it pins that file's shape |
| `spec/lain/frontend/neovim/thread_view_spec.rb:1962` | greps `lib/lain/frontend/neovim.rb` for `thread_view` | a wiring assertion; the wiring is observable at runtime |
| `spec/lain/frontend/neovim/review_view_spec.rb:524` | `runtime/41_layout.lua` source | cross-language, but unlike `fold_spec` it is not pinning a shared literal |

So the pattern **is** spreading — it moved subsystems rather than growing in place. The intent is
unchanged: **a spec asserts behaviour, not source text.**

**Sequencing.** The card was in wave 1 *"deliberately: the source-scraping specs block simplify-01's prose
work and simplify-04's comment cleanup."* Both of those plans are `status: done`, so **the blocker it
existed to clear cleared itself** and the card carries no urgency. It moves to wave 3. Note it now edits
`review_view_spec.rb`, which T1 splits — which is the other reason it cannot stay in wave 1.

**Each spec had a real intent** — that a rule is documented, that a Ruby constant and a Lua pattern agree,
that a view is wired. Preserve the intent as a behavioural assertion, or move it to a discipline check
where source-reading is the point. **Do not simply delete**, and **do not convert `fold_spec.rb:56-59`**.

**Acceptance criteria**

```gherkin
Scenario: no spec asserts on the text of a lib source file
  When the suite is searched for reads of a lib source path outside a discipline spec
  Then only the cross-language literal pin remains

Scenario: the Ruby constant and the Lua pattern still agree
  Given the indent constant and the continuation pattern
  When they are compared
  Then they describe the same prefix

Scenario: each converted spec asserts the behaviour its scrape stood for
  Given a converted spec
  When it runs
  Then it exercises the object rather than reading the object's source

Scenario: shortening a comment does not fail the suite
  Given a comment shortened by one line
  When the suite runs
  Then it passes
```
→ spec files: the six modified files, plus whichever discipline spec receives any relocated intent (AC 1)

**Escalation triggers**
- **`fold_spec.rb:56-59` is the legitimate case and must survive.** A Ruby constant and a Lua literal that
  must agree share no runtime. If a conversion sweep catches it, the sweep is too wide — carve it out
  explicitly rather than by leaving it off a list.
- `survey/chunker/code_spec.rb` reads `lib/lain/cli/command/goal.rb` as a **chunker fixture**, which is a
  different thing from asserting on source text: the chunker's job is to read code. But it pins a real
  file's shape into an unrelated spec, so editing `goal.rb` can redden it. Decide whether it gets a
  committed fixture of its own and say which; that may be the whole fix for those three sites.
- `thread_view_spec.rb:1962` greps `lib/lain/frontend/neovim.rb` to assert wiring. If the wiring cannot be
  observed at runtime, the grep is standing in for a missing seam — report that rather than deleting the
  assertion, because the seam is the real finding.
- **If a seventh scraper turns up, report it.** Six is the measured count on 2026-09-13, and the first
  three the card named all vanished inside five weeks — this population turns over, so a census is worth
  more than a fix list.

## Integration checks

After the last wave:

- `bundle exec rake pspec` green, **with the example count recorded and the arithmetic written out**.
  The baseline is **17,837** and it is sound — keep it verbatim. T9, T10 and T1 all move the count, in
  both directions. A drop this plan cannot account for is a dead worker.
- **Measure the wall before and after.** With T5 dropped and T1's 23.4s floor UNVERIFIED, the two
  remaining time claims are T3's (removes a measured **5.05s**) and T1's (targets the floor). Record the
  actual `pspec` wall at 12 workers **before the plan, after T1, and after T3**, and say which of the two
  held. Do not restate the floor as measured until a `pspec` run has produced it.
- **Run with and without `--tag '~seam'` and record both counts and both walls.** T2's entire deliverable
  is that the difference becomes meaningful; today it barely is.
- `bundle exec rspec --tag nvim` — T1 and T4 both restructure how the editor is driven. `:nvim` is
  **522 examples suite-wide** and runs by default; 102 of them are `neovim_runtime_spec.rb`'s, and those
  spawn a real editor.
- `bundle exec rubocop` clean, and confirm `RSpec/NestedGroups` and `RSpec/ExampleLength` did not need
  loosening — T6's tables and T7's factory both push on those, and `.rubocop.yml:207-214` argues those
  two cops are deliberately about spec DSL rather than `lib/` objects.
- **Read `tmp/parallel_runtime_rspec.log` after one run** and confirm it holds only timings (T3's AC 3).
  A poisoned packer input silently mis-packs every subsequent run.
- **Confirm no `nvim` process survives the suite.** T4's AC 2 is the one whose failure mode is an OOM
  rather than a red spec.
- No `planning/qa/scenarios/` update is expected — this plan changes no user-visible behaviour. If any
  card finds itself changing one, that is a signal the card exceeded its scope.
