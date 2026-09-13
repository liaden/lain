# Staleness audit — `simplify-10-spec-hygiene.md`

Audited 2026-09-13 against `main` at `d4a7a1ea`. Read-only; no plan or source file was modified.

**Why this audit exists.** The plan's Grounding says *"Verified 2026-09-12 against the working tree at
`d2bb133c`"*. `d2bb133c` is **not an ancestor of `d4a7a1ea`** — history diverged, and HEAD carries 327
commits that `d2bb133c` lacks while `d2bb133c` carries 238 that HEAD lacks. simplify-01, -04, -05, -06
and -07 all landed in that window (`status: done`). This plan is almost entirely measured figures, so
every one was re-measured.

**How things were measured.** Static counts by `grep`/Ruby over the tree. Example counts by
`bundle exec rspec --dry-run` (no example bodies run; total, `--tag seam`, `--tag '~seam'`, `--tag nvim`).
Two narrow single-file timed runs were judged essential and are flagged where used:
`spec/spec_discipline_spec.rb` and `spec/lain/frontend/neovim_runtime_spec.rb`. **`rake pspec` was not
run** — other agents are working in this tree and CLAUDE.md is explicit that a concurrent run is not
evidence. Every claim below that would need a full parallel wall is marked UNVERIFIED rather than guessed.

---

## Headline: the suite's example arithmetic

| | plan (`d2bb133c`) | measured (`d4a7a1ea`) | |
|---|---|---|---|
| total examples (default tiers) | — | **17,837** | matches `CLAUDE.md` |
| `spec/**/*.rb` code lines | 150,715 | **149,154** | −1.0% |
| `lib/**/*.rb` code lines | 49,165 | **47,635** | −3.1% |
| `:seam` examples | 3,483 (21.4%) | **1,489 (8.35%)** | see below |
| non-`:seam` examples | — | **16,348** | 1,489 + 16,348 = 17,837 ✓ |
| `:nvim` examples | 101 (one file) | **522** suite-wide | `:nvim` runs by default |

**The 21.4% seam figure was never right — it is a methodological error, not drift.** A static
`it`/`specify` grep across the 115 files that contain the string `:seam` anywhere yields **3,580 examples
/ 38,738 code lines**, which is where the plan's *"3,483 examples (21.4%) … 37,602 code lines (25.6%)"*
came from. That count charges every example in a file to `:seam` because one example somewhere in it
carries the tag, and it counts `it "…"` inside heredoc fixtures. The runtime answer from the dry-run is
**1,489**, and the two partial dry-runs sum exactly to the total, so the number is sound.

This changes T2's case materially but does not destroy it: `CLAUDE.md:177` still documents **2.5%**, so
the tag is **3.3× over its documentation**, not 8.6×.

**The tag did not grow in the divergence window.** Files containing `:seam`: 114 at `d2bb133c` → **115**
at HEAD. Top-level describes carrying it: 67 → **66** (across **65** files; one file carries two). The
*"26 → 73 → 112 files in five weeks"* growth story is historical and did not continue.

---

## Per-card verdicts

| card | verdict | drift | recommended card edit |
|---|---|---|---|
| **T1** split `neovim_runtime_spec.rb` | **ADJUST** | structure verified, module map stale, one sub-claim dead | re-map the 18 describes; delete the "five wasteful spawns" paragraph; drop the simplify-14 dependency |
| **T2** tag real resources | **ADJUST** | premise halved: 8.35%, not 21.4% | restate the grounding; keep the card, weaken the urgency |
| **T3** move the guard to `bin/` | **ADJUST** | 41 ex / 5.05s, not 61 / 6.49s; phantom is 184 | restate the three figures; premise otherwise verified |
| **T4** one headless-editor harness | **ADJUST** | 21 sites / 20 files; `SocketTmpdir` now has 1 user | correct the counts; "none of the 23 uses it" is now false |
| **T5** shared tree index | **DEAD as scoped** | 28 files → ~4 real globbers; 21 non-discipline → ~1 | close, or re-ground from scratch |
| **T6** table-loop clone clusters | **ADJUST** | one of three named `up_spec` clusters is gone | re-derive the clusters; keep the wave-3 T1 dependency |
| **T7** core-graph factory | **VALID** | every figure within 2% | ship as written |
| **T8** hoist async ceremony | **VALID** | 489/77 vs 505/78 | update two numbers; name the heaviest files |
| **T9** delete helper specs & unshared groups | **VALID** | 25 groups not 26; one group renamed out, one new one in | swap two group names |
| **T10** retire migration guards | **ADJUST** | headline exhibit survives at a new line | update `:108-121` → `:109-123` |
| **T11** own each refusal sentence once | **ADJUST** | 58.9% not 61.7%; **simplify-06's T5 already landed** | rewrite Reuse — the edit window it planned to share is closed |
| **T12** stop specs reading source text | **DEAD as written** | all three named scrapes are gone; 6 unnamed ones exist | close, or rewrite around the real six |

---

### T1 — Put twelve-plus subjects at twelve-plus mirror paths — **ADJUST**

**Files** — all four still exist:

| path | plan | measured |
|---|---|---|
| `spec/lain/frontend/neovim_runtime_spec.rb` | 3,588 lines, 101 ex | **3,612 raw / 2,204 code, 102 ex** |
| `spec/lain/frontend/neovim/review_view_spec.rb` | 1,660 lines, 4 subjects | **1,660 raw / 965 code, 4 top-level describes** |
| `spec/lain/frontend/neovim/thread_view_spec.rb` | 1,657 + 92 | **1,976 raw / 1,126 code, 3 top-level describes** |
| `spec/lain/telemetry_spec.rb` | index spec | **976 raw / 697 code** |

**Verified.** One top-level `RSpec.describe Lain::Frontend::Neovim, :nvim` at `:23`; **exactly 18**
second-level describes; the `around` hook spawning `nvim --headless` per example at `:24-41`. Timed
single-file run: **102 examples in 22.52s** — the plan's *"22.7s"* holds to within 1%.

**The 23.4s wall-clock floor is UNVERIFIED** (it needs a `pspec` run, which was out of bounds). The claim
is plausible given 22.52s measured, but should be re-measured before the card is accepted.

**DRIFTED — the module map.** Every line number in the Grounding has moved, and one describe is new.
Current structure, with the Lua module each cites:

```
  116- 198   83 raw   65 code   3 ex  "user autocmds get a stable surface"                 (99_attach)
  199- 233   35        25       2 ex  "richer highlighting"                                (20_buffers)
  234- 266   33        21       1 ex  "workspace view has a lua-side home"                 (45_views)
  267- 302   36        19       1 ex  "status view has a lua-side home"                    (45_views)
  303- 366   64        34       1 ex  "the rail table's one lua dispatch"          <-- NEW (simplify-07 T3)
  367- 403   37        22       1 ex  "the inbox's open gesture, end to end"               (70_inbox)
  404- 554  151        90       6 ex  "answering a parked approval in the editor"          (62_approval)
  555- 852  298       182       2 ex  "the repl's own wiring puts a parked approval ..."   (62_approval, runtime.lua)
  853-1044  192        90       9 ex  "the runtime digest"                                 (runtime.lua)
 1045-1168  124        77       6 ex  "one lain per editor"                                (runtime.lua)
 1169-1367  199        89       5 ex  "the review round trip"                     <-- 14   (65_review, 46_sidebar, 30_commands)
 1368-1739  372       204      10 ex  "the refusal rail's width"                  <-- 14   (65_review)
 1740-2044  305       205      11 ex  "the compose round trip"                             (55_compose)
 2045-2293  249       174       9 ex  "the question round trip"                            (60_question)
 2294-2477  184       111       8 ex  "folds"                                              (10_folds, 05_records, 51_thread)
 2478-2647  170        92       5 ex  "a user command that refuses"                        (30_commands, 65_review, 47_diff)
 2648-3079  432       266      10 ex  "a review that survives the tabpage"        <-- 14   (47_diff, 41_layout)
 3080-3612  533       362      12 ex  "a long note grown in a pane"               <-- 14   (52_note_compose)
```

The count is still 18, but the plan's `:300 → 70_inbox` is now `:303 → the rail table's one lua dispatch`
(added by commit `88c13d54`, simplify-07's T3), and `70_inbox` moved to `:367`. **Re-derive the whole
map before splitting** — the card cannot be executed from the line numbers it carries.

**DEAD sub-claim — "delete the five wasteful spawns while here."** The plan says `:908`, `:925`, `:952`,
`:965`, `:986` *"only read `protocol_history` and a file, never touching the editor."* All nine examples
in the `"the runtime digest"` group (`853-1044`) reference `@socket` and drive a real editor. There is no
`protocol_history`-only example left in the file. **Delete this paragraph and the third acceptance
criterion** (*"a spec that touches no editor spawns none"*), which now has no subject.

**Escalation trigger already fired (partially).** *"If two of the 18 describes share a `let` or a helper,
splitting duplicates it"* — the file defines `all_views`, `ApprovalSeamSupport` and a shared `channel` let
at file scope, used across groups. T4 must land first, as the card says.

---

### T2 — Tag the real resources, not the files that contain them — **ADJUST**

**VERIFIED.** **65 files / 66 occurrences** tag a top-level `RSpec.describe` with `:seam` (plan:
*"109-113 files, 66 top-level"* — 115 files contain the tag anywhere, 66 top-level describes carry it).
`spec/lain/seams/` holds **29** spec files and is the correctly-scoped model the card names.

**DRIFTED — the headline.** `:seam` is **1,489 of 17,837 examples = 8.35%**, not 3,483 / 21.4%. See the
headline section above for why the plan's number was never reproducible. The 15.4% real-resource figure
inside the 66 files was not re-derived (it is a per-example judgment, not a count) and should be treated
as unverified.

**DRIFTED — the documented figure was not corrected.** The plan's Grounding says *"simplify-01's T7
corrects the prose."* simplify-01 is `status: done`, and its T7 **did** land the spec-mirror relaxation
(`CLAUDE.md:60` now reads *"one spec file per public entry point, at its mirrored path"*) — but
`CLAUDE.md:177` **still says 2.5%**. That correction did not ship. T2 or a follow-on still owns it, and
the number it should carry is now **8.35%**, not 21.4%.

**Recommended edit.** Keep the card. Restate: *"the tag covers 8.35% of examples against a documented
2.5%, and 65 files tag their top-level describe so every example in them inherits it."* The mechanical
AC 5 (example-count arithmetic) is the right guard and is unaffected. The escalation trigger about T1 not
having landed also stands: `neovim_runtime_spec.rb` at 22.52s is still the `--tag '~seam'` problem, and
it is `:nvim`-tagged, not `:seam`-tagged, so re-tagging seams will not touch it.

---

### T3 — Move the guard that cannot fail to `bin/` — **ADJUST**

**Files** — `spec/spec_discipline_spec.rb` exists.

**VERIFIED exactly: 835 code lines.** The plan's figure is dead-on. Raw lines grew to 1,469 (comments).

**DRIFTED — examples and time.** Timed single-file run: **41 examples in 5.05s**, not 61 / 6.49s. The
plan's 61 is a static `grep` over-count: the file embeds Ruby *fixtures* in heredocs that themselves
contain `it "…"` lines, so a naive scan sees 61 where RSpec loads 41.

**VERIFIED — the report-only design.** The comment block (`~:76-86`) still says *"a guard that FAILS the
suite on day one would need an allowlist sized to that count, which is a disabled guard wearing a spec's
name — so this spec prints the report and passes"*, and names the intended follow-up as a **ratchet**
(`count <= <ceiling>`), not a hard failure. The card should quote the ratchet, since that is what its
`--check` flag would implement.

**VERIFIED — the packer poisoning, with a new number.** `tmp/parallel_runtime_rspec.log` (753 lines,
written 2026-09-13 17:41) contains at line 570:

```
spec discipline: 184 flagged example(s) -- {sole_raise_error: 170, nested_expect: 14} (full listing: …)
```

A **184**-second phantom entry, not 183. `Rakefile:27-31` still chooses `--group-by runtime` only when
the log exists, so the mis-pack is live. 12 of the 753 lines mention "discipline".

**AC 3's narrowing still holds** — the log carries `Run options: exclude {…}` and `Skipping :<tag>
specs…` lines from RSpec and `spec/support/tags.rb` that this card cannot remove.

---

### T4 — One headless-editor harness — **ADJUST**

**DRIFTED — the counts.** **21 spawn sites across 20 spec files**, not 23 across ~22. The reference hook
at `neovim_runtime_spec.rb:24-41` is unchanged and is still the most complete variant (`nvim --headless
--clean -n --listen <socket>`, `Timeout.timeout(10)` on socket appearance, `TERM` + `Process.wait`
rescuing `Errno::ESRCH, Errno::ECHILD`, socket named from `Process.pid` **plus** `rand(1_000_000)`).

**DRIFTED — the Reuse claim is now false.** The card says *"`spec/support/socket_tmpdir.rb` already
exists and **none of the 23 uses it**."* It has one user:

```
spec/lain/frontend/neovim/diff_mode_spec.rb:59:  PROJECT = SocketTmpdir.persistent("lain-diff-spec")
```

`socket_tmpdir.rb:51` also does `RSpec.configure { |config| config.include SocketTmpdir }`, so it is
globally available. The card's starting point is better than it thinks; say so rather than "none".

Note `spec/lain/frontend/neovim/diff_mode_spec.rb` is one of the files simplify-14's T2 would delete —
irrelevant now that 14 is declined (below), but the harness card should not build around it either.

---

### T5 — One shared tree index for the twenty-one scanners — **DEAD as scoped**

**The Grounding is not reproducible.** The card is built on *"28 files re-enumerate the repo's own `lib/`
tree — 9,271 code lines (6.2% of the suite), 50.4s of 508.2s = 9.9% of example time … split 21
non-discipline and 7 discipline."*

Measured three ways, from strictest to most generous:

1. **Specs whose runtime code globs `lib/**/*`: four files.**
   `spec/error_taxonomy_discipline_spec.rb`, `spec/lain/frontend/neovim_spec.rb`,
   `spec/plugin/nvim_plugin_spec.rb`, `spec/repo_as_fixture_spec.rb` — and the last one's matches are
   **inside heredoc fixtures**, because it is a guard *against* the pattern, so it does not scan. Of the
   three real ones, one is a discipline spec. **Non-discipline lib-tree globbers: two.**
2. Adding specs that read individual `lib/` source files or parse with Prism/Ripper: ~14 files, of which
   ~8 are discipline specs (`output_discipline`, `refusal_width_discipline`, `reply_surface_discipline`,
   `provider_construction_discipline`, `approval_consumer_discipline`, `error_taxonomy_discipline`,
   `spec_discipline`, `repo_as_fixture`).
3. Loosest possible (any spec globbing any repo-ish path): 45 files, 18,880 code lines — but this is
   dominated by tmpdir and fixture globs and is not what the card means.

**Nothing supports "21 non-discipline files / 7,020 code lines."** The honest figure is **two to six**,
depending on whether reading three named source files counts as "re-enumerating the tree."

**And the pattern was actively policed in the divergence window.** `spec/repo_as_fixture_spec.rb` (236
code lines) landed on HEAD's side and is a mechanical Prism guard forbidding *"an example — or a shared
group carrying examples — brought into being by a scan of this repository's own tree."* Its own header
records the post-mortem: a spec globbed `planning/specs/*.md` and minted one example per document, so
adding a plan doc moved the suite's example count — the number `CLAUDE.md` tells readers to compare
against a serial run.

**`spec/support/tree_index.rb` does not exist**; `spec/support/seed_repo.rb` (the cited precedent) does.

**Recommendation: close T5, or re-ground it from zero.** As written it proposes a shared index for
twenty-one scanners that are not there. The 50.4s time claim is separately UNVERIFIED and cannot be
checked without a `pspec` run.

---

### T6 — Table-loop the confirmed clone clusters — **ADJUST**

**Files** — all three exist: `spec/lain/cli/up_spec.rb` (2,151 raw / 1,121 code, 4 top-level describes),
`spec/lain/cli/human_replies_spec.rb` (2,385 / 1,344, 2 top-level), `spec/lain/frontend/neovim/
review_view_spec.rb` (1,660 / 965, 4 top-level).

**DRIFTED — one of the three named `up_spec` clusters is gone.**

- *"its `.lain_exports` group (13 → 2)"* — **DEAD**. The string `lain_exports` does not appear anywhere
  in `up_spec.rb`.
- *"`up_spec`'s Hud group (12 → 1)"* — survives: `describe "Hud, printing the line the state feed
  published"` at `:1503`.
- *"its argv group (16 → 1)"* — **not a group**. There is no describe named for argv; argv assertions are
  scattered through `#attach_command` (`:470`) and `#launch_plan composition` (`:519`), with a comment at
  `:466` explaining that block is *"Pure argv construction — no shell-out at all."*

**DRIFTED — `review_view_spec:959-1012`.** The group is now `describe "rendering into the review
tabpage"` starting at `:958`.

**Needs re-derivation — `human_replies_spec`'s "two groups (18 and 11)".** The file now has 18
second-level describes and neither of the two clusters is identifiable from the card's description. The
card must name them by describe string, not by example count.

**The wave-3 placement still holds** — T6 edits `review_view_spec.rb`, which T1 splits.

---

### T7 — A factory for the core object graph — **VALID**

Every figure re-measures within 2%:

| | plan | measured |
|---|---|---|
| `Lain::*.new(` sites | 4,042 | **4,033** |
| files constructing `Journal` | 133 | **134** |
| files hand-building 3+ core classes | 85 | **83** |
| `spec/support/core_graph.rb` | to create | does not exist ✓ |
| `build_subagent` in `subagent_spec.rb` | exists, forwards `**seam` | **exists, 74 references** ✓ |

Heaviest builders: `supervisor/restart_spec.rb` (6 core classes), then `supervisor_spec.rb`,
`cli/command/rewind_spec.rb`, `cli/command/pin_spec.rb`, `cli/goal_driver_spec.rb`,
`cli/command/goal_spec.rb`, `cli/repl_spec.rb`, `cli/resend_bridge_spec.rb` (5 each). The card can name
these as its "largest few" instead of leaving the choice open.

Ship as written.

---

### T8 — Hoist the async ceremony — **VALID**

**DRIFTED slightly:** **489 `Sync do` sites across 77 files** (plan: 505 / 78). `spec/support/
supervised.rb` does not exist ✓.

The card says *"modify the spec files with the heaviest `Sync do` concentration"* without naming them.
Measured, they are:

```
57  spec/lain/supervisor_spec.rb          22  spec/lain/provider/admission_spec.rb
42  spec/lain/tools/ask_human_spec.rb     19  spec/lain/tools/subagent_spec.rb
38  spec/lain/cli/human_replies_spec.rb   16  spec/lain/oracle/eager_spec.rb
32  spec/lain/review/docent_spec.rb       13  spec/lain/supervisor/restart_spec.rb
25  spec/lain/approval/queue_spec.rb      13  spec/lain/supervisor_reactor_spec.rb
```

Name them in the card. Note `subagent_spec.rb` is also T7's target and is named by simplify-09 — see
collisions.

---

### T9 — Delete the specs that test spec helpers, and the shared examples nobody shares — **VALID**

**All four support specs exist at exactly the stated sizes:** `support_matchers_spec.rb` **171**,
`support_vsock_availability_spec.rb` **310**, `support_watchdog_spec.rb` **112**,
`support_store_fetch_count_spec.rb` **106** — 699 lines ✓.

**`spec/support/shared_examples/elementwise.rb` is 138 lines with zero `it_behaves_like` callers** ✓
exactly as stated.

**DRIFTED — 25 groups, not 26.** Full caller census:

```
 11  a Regular value                              2  a commutative monoid
  9  a monoid                                     2  a monoid homomorphism
  6  a class-tagged inspect                       2  a review changeset source
  6  a review surface                             2  an ollama deployment
  5  a Lain::Provider                             2  canonical determinism
  5  a memory search index                        2  files a bound can size
  5  a review journal record                      2  not a monoid homomorphism
  4  a meet semilattice under ancestry            1  a pure operation
  3  a content-addressed store                    1  a tier-1 read of any path that never raises
  3  a diff-bearing review changeset source       1  an attenuation
  3  a gh executor                                0  an elementwise map
  3  a survey chunker
  3  a tier-1 read that never raises
  3  an exec backend answering for a term
```

Against the card's list:
- *"an attenuation"* (263 lines, 1 use) ✓ — file is 263 lines exactly.
- *"a pure operation"* (145, 1) ✓ — file is 145 lines exactly.
- *"an ollama deployment"* (2) ✓, *"a monoid homomorphism"* (2) ✓.
- **`"an exec boundary matching bash"` no longer exists.** It was renamed
  **`"an exec backend answering for a term"`** (`exec_term_contract.rb:34`) and now has **3** callers —
  it leaves the 1-2-caller list entirely. Remove it from the card.
- **New 1-caller group the card does not name: `"a tier-1 read of any path that never raises"`**
  (`tier_one_read_contract.rb:100`). Its sibling `"a tier-1 read that never raises"` in the same file has
  3. Add it, or state why it is exempt.

**Keep-list verified:** `store_laws` (3), `meet_semilattice` (4), `regular` (11), `canonical_laws` (2) —
all two-plus ✓.

**One citation drifted.** The escalation trigger says `support_vsock_availability_spec.rb:136-146` is a
byte-for-byte copy of `tags.rb:238-246`. `spec/support/tags.rb:238` is now
`config.filter_run_excluding(:vsock)`; re-locate the copied region before relying on the line numbers.

---

### T10 — Retire the guards that pin completed migrations — **ADJUST**

**VERIFIED — the headline exhibit survives**, at `spec/lain/telemetry_spec.rb:109-123` (plan said
`:108-121`). It still re-implements the `gsub` it replaced:

```ruby
hand_rolled = name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
expect(name.underscore).to eq(expected).and eq(hand_rolled)
```

**The "168 examples" figure remains unenumerable** — as the card's own escalation trigger says, it is *"an
estimate from a sampling pass, not an enumeration."* No mechanical proxy reproduces it. The card is
correct to instruct working file-by-file and reporting the real count; leave the estimate flagged as an
estimate rather than restating it as a measurement.

---

### T11 — Own each refusal sentence once — **ADJUST**

**DRIFTED, mildly, on the ratio:** **2,063 of 3,500 `raise_error` calls carry a message matcher =
58.9%**, not 2,162 of 3,505 = 61.7%. The *"3,940 assertions pin prose overall"* figure was not
independently reproducible and should be dropped or re-derived.

**DRIFTED, materially, on Reuse — simplify-06's T5 has already landed.** The card's Reuse says
*"simplify-06's T5 is already collapsing 31 refusal classes into one — the same files, the same edit
window,"* and its third escalation trigger says *"prefer T5 first."* simplify-06 is `status: done`:
`lib/lain/config/refusal.rb` exists and `Config::Refusal` is referenced at **37** sites in `lib/`. The
collapse is finished. **The shared edit window is closed** — T11 can no longer ride it, and must pick its
own scope. The sequencing trigger is satisfied, not pending.

**Verified as still true:** `lib/lain/refusals.rb` does not exist ✓; the width guard exists at
`spec/refusal_width_discipline_spec.rb` (the card does not give a path — add it) ✓.

---

### T12 — Stop specs from reading source text — **DEAD as written**

**All three named scrapes are gone.**

1. **`up_spec.rb:882-887` — the headline, the spec enforcing a minimum comment length — has no subject
   left.** `CONSENT_ENV` does not exist anywhere in `lib/` (removed by commit `c40ab419`, *"delete
   Lain::Notify, and give request_review a way to tell the human"*). `spec/lain/cli/up_spec.rb` contains
   no `File.read` of `pane_command.rb`, no `reason.lines.count`, and no reference to the constant. The
   card's central exhibit, its AC 1 (*"no spec asserts on the length of a comment"*) and its AC 3 (*"the
   environment list's reason is still required"*) all now describe nothing.
2. **`inbox_view_spec.rb:979`** — gone. `:994` is now a **prose comment** referencing `Fold::INDENT`, not
   an assertion over source text.
3. **`approval_view_spec.rb:621`** — gone. `:675` is likewise a prose comment.

**simplify-07's T7 landed and did most of this card's AC 2.** `Fold::INDENT` is now the one Ruby
spelling — `lib/lain/frontend/neovim/inbox_view.rb:84` and `approval_view.rb:96` both read
`INDENT = Fold::INDENT` — and the cross-language pin survives at exactly **one** site, which is arguably
the shape the card wanted:

```
spec/lain/frontend/neovim/fold_spec.rb:56  def runtime_source(file) = File.read(File.join(…MODULES, file))
spec/lain/frontend/neovim/fold_spec.rb:59  pattern = runtime_source("05_records.lua")[/^local CONTINUATION = "\^([^"]*)"$/, 1]
```

**The card's own escalation trigger has already fired.** It says *"if a fourth source-scraping spec turns
up, add it — but report it, because three was the measured count and a fourth means the pattern is
spreading."* There are at least **six**, and none is one of the three the card names:

| site | what it reads |
|---|---|
| `spec/lain/sensitivity_spec.rb:593` | `lib/lain/sensitivity.rb` source |
| `spec/lain/sensitivity/ledger_spec.rb:120` | `lib/lain/sensitivity/ledger.rb` source |
| `spec/lain/approval/queue_spec.rb:598` | `lib/lain/approval/queue.rb` source |
| `spec/lain/survey/chunker/code_spec.rb:281,288,404` | `lib/lain/cli/command/goal.rb` and others |
| `spec/lain/frontend/neovim/thread_view_spec.rb:1962` | greps `lib/lain/frontend/neovim.rb` for `thread_view` |
| `spec/lain/frontend/neovim/review_view_spec.rb:524` | `runtime/41_layout.lua` source |
| `spec/lain/frontend/neovim/fold_spec.rb:56-59` | `runtime/05_records.lua` — the legitimate cross-language pin |

**Recommendation: close T12, or rewrite it around this table.** It cannot run as written, and it must
come **out of wave 1** — the plan puts it there *"deliberately: the source-scraping specs block
simplify-01's prose work and simplify-04's comment cleanup."* Both of those plans are `status: done`. The
blocker T12 exists to clear has already cleared itself.

---

## Other Grounding figures

**46 multi-top-level-describe files — VERIFIED exactly at 46.** Total code lines **18,793** (plan:
17,253, +8.9%). The largest:

```
1979 code  4 describes  spec/lain/cli/wiring_spec.rb          <-- MOVED, see below
1344       2            spec/lain/cli/human_replies_spec.rb
1126       3            spec/lain/frontend/neovim/thread_view_spec.rb
1121       4            spec/lain/cli/up_spec.rb
1067       2            spec/lain/frontend/neovim/inbox_view_spec.rb
 965       4            spec/lain/frontend/neovim/review_view_spec.rb
 749       9            spec/lain/frontend/neovim/rpc_thread_spec.rb
 721       2            spec/lain/frontend/neovim/diff_mode_spec.rb
```

**`wiring_spec.rb` moved and the plan's path is dead.** The Grounding names `wiring_spec.rb` (*"the real
unit is `wiring.rb` + `wiring/*` = 1,846 lines, not 138"*) and ranks it #1 for reach-ins. There is no
`spec/lain/wiring_spec.rb` and no `lib/lain/wiring.rb`. Both moved under `cli/`:
`spec/lain/cli/wiring_spec.rb` (1,979 code) with `spec/lain/cli/wiring/{board_build,askers,
toolset_build}_spec.rb` alongside. simplify-04 did this.

**291 internals reach-ins — DRIFTED UP to 325.** `send(:` **140** (plan 124), `instance_variable_get`
**185** (plan 167), `.ordered` **17** (plan 16). The reach-in problem got *worse*, not better, in the
divergence window.

**The ranked five are substantially wrong.** Measured `send(:` + `instance_variable_get` per file:

| plan rank | file | plan | measured |
|---|---|---|---|
| 1 | `wiring_spec.rb` | 33 | **51**, at `spec/lain/cli/wiring_spec.rb` |
| 2 | `supervisor_spec.rb` | 14 ordered-call examples | **0** reach-ins, **0** `.ordered` — **DEAD** |
| 3 | `subagent_spec.rb` | "a 170-line isolated Seam group" | **14** ✓ |
| 4 | `human_replies_spec.rb` | 4 named sites | **4** ✓ |
| 5 | `review_view_spec.rb` | `private_method_defined?` etc. | **0** send/ivar — mis-ranked |
| — | **`spec/lain/cli/backend_spec.rb`** | not mentioned | **43** — the real #2 |

`review_view_spec.rb`'s `private_method_defined?` assertion does survive, at `:144-149` (plan: `:147-150`)
over `SCOPE_ROWS.values`, but it is not a `send`/ivar reach-in and does not belong in a list ranked by
those. **`spec/lain/cli/backend_spec.rb` (43) is entirely absent from the plan** and is now the second-
biggest blocker by this measure.

**The one earned reach-in** — `wiring_spec.rb:2453-2470`'s `equal?`-not-`eq` identity argument — was not
re-located after the move; its line numbers are stale. It should be re-found before any card touches that
file.

**`spec/support` — 40 top-level files plus `matchers/`, `nulls/`, `provider_oracles/`,
`shared_examples/`.** The plan's *"3,647 code lines in 64 files"* was not re-derived; the ownership
argument it supports is unaffected either way.

---

## The simplify-14 question

**The constraint is void. The human declined simplify-14 on 2026-09-13, and the decision is recorded in a
sibling plan rather than in 14 itself.**

`planning/specs/simplify-07-frontend-dedup.md:833-840`, under the heading **"The simplify-14 question,
answered"**:

> **2026-09-13, by the human: 14 is unlikely to run, so T3 goes ahead as written.** The rails it tables
> include the seven the review surface uses; if 14 is ever revived it will delete a table rather than a
> scatter, which is the cheaper direction to discover.

simplify-07 then closed its chunk on that basis (*"T3 ran after the human declined simplify-14 on
2026-09-13, and it closed the chunk"*), and `88c13d54` is in HEAD. simplify-14's T1 groups were
**not** deleted and will not be.

**So: split anyway. T1 is unblocked.** Remove the *"simplify-14 runs before T1"* bullet from the
Orchestrator contract. The remaining dependency (T1 ← T4) stands.

**What the cost would have been, had 14 been live.** All four groups 14's T1 names are still present in
`neovim_runtime_spec.rb`, and they are not marginal:

| group | lines | code | examples |
|---|---|---|---|
| `"the review round trip"` (`:1169`) | 199 | 89 | 5 |
| `"the refusal rail's width"` (`:1368`) | 372 | 204 | 10 |
| `"a review that survives the tabpage"` (`:2648`) | 432 | 266 | 10 |
| `"a long note grown in a pane"` (`:3080`) | 533 | 362 | 12 |
| **total** | **1,536 (42.5% of the file)** | **921** | **37 of 102 (36.3%)** |

Two further groups touch modules 14 would delete without being named for deletion: `"a user command that
refuses"` (`:2478`, cites `65_review`, `46_sidebar`, `47_diff`) and `"folds"` (`:2294`, cites
`51_thread`). So the real blast radius was larger than four groups. **Deferring T1 would have been the
right call against a live 14** — the plan's ordering constraint was well-reasoned. It is simply no longer
operative.

**One loose end worth closing.** `planning/specs/simplify-14-nvim-descope.md` is still `status: draft`
with no note of the decline. Nothing in `ROADMAP.md` mentions it. A future orchestrator reading 10's
contract will look up 14, see `draft`, and defer T1 indefinitely. **Stamp 14 as declined**, or move the
decline note from 07 into 14 where it will be found.

---

## Cross-plan collisions

The plan warns: *"**T2 and T5 must not run in the same wave as another plan's large spec edit.** Both
touch many files shallowly, and a merge conflict across 66 files is worse than a serialized wait."*

**Measured, the risk is close to zero.** Every spec file named anywhere in simplify-08 and simplify-09
was intersected against T2's 65 top-level-`:seam` files and against T5's scanners:

| | files named | ∩ T2's 65 | ∩ T5's scanners |
|---|---|---|---|
| simplify-08 | 9 | **1** (`spec/lain_spec.rb`) | 0 |
| simplify-09 | 18 | **0** | 0 |

`spec/lain_spec.rb` is the sole overlap — **54 code lines**, one top-level `:seam` describe. That is not
a reason to serialize a wave.

**Per-file detail for 08 and 09's named specs:**

```
                                              toplevel_seam  any_seam  Sync do  reach-ins
spec/lain_spec.rb                        (08)       1            1         0         0
spec/lain/bench/cli_spec.rb              (08)       0            1         0         0
spec/lain/bench/live_arms_spec.rb        (08)       0            1         0         2
spec/lain/bench/spawn_seam_spec.rb       (08)       0            1         0         0
spec/lain/arm/driver_spec.rb             (08)       0            0         0         0
spec/lain/compare_spec.rb                (08)       0            0         0         0
spec/lain/tools/subagent_spec.rb         (09)       0            1        19        14   <-- the real collision
spec/lain/cli/switchboard_spec.rb        (09)       0            1         3         3
spec/lain/cli/tool_guard_spec.rb         (09)       0            1         2         0
spec/lain/tools/subagent_gate_spec.rb    (09)       0            0         2         0
spec/lain/session_record_spec.rb         (09)       0            2         0         0
(algebra, middleware, timeline, rust/*, spawn_policy, effect/handler: all zero on every axis)
```

**The real collision is not T2 or T5 — it is `spec/lain/tools/subagent_spec.rb`, contended three ways.**
simplify-09 names it; 10's **T7** names it explicitly (*"already has `build_subagent` … part of this card
is using what exists"*); and it is 10's **T8**'s seventh-heaviest `Sync do` file (19 sites). At 3,023 raw
/ 1,871 code lines with 14 reach-ins it is one of the biggest spec files in the tree. **T7 and T8 must
not share a wave with each other or with simplify-09's subagent work.** The plan's own wave 3 puts T7 and
T8 together — that is the collision to fix, and it is internal to this plan.

Secondary: 09's `spec/lain/cli/switchboard_spec.rb` has 3 `Sync do` and 3 reach-ins — light, but T8 could
touch it if it widens beyond the top ten.

**08 and 09 are themselves stale.** Five spec files they name do not exist:
`spec/lain/arm/catalog_spec.rb`, `spec/lain/compare/posture_spec.rb`, `spec/lain/compare/sheet_spec.rb`
(08); `spec/lain/cli/context_pipeline_spec.rb`, `spec/lain/dag/render_meet_spec.rb` (09). Both plans
need their own audit before they run alongside this one.

---

## Recommended wave changes

1. **Drop the simplify-14 bullet from the Orchestrator contract.** 14 was declined 2026-09-13. T1 splits
   all 18 groups. Stamp `simplify-14-nvim-descope.md` as declined so this does not get re-litigated.
2. **Remove T12 from wave 1 and close it** (or rewrite it around the six real scrapers in the table
   above). Its headline exhibit is gone, its AC 1 and AC 3 have no subject, and the two plans it was
   sequenced early to unblock — simplify-01 and simplify-04 — are both `done`.
3. **Remove T5 from wave 2 and close it** (or re-ground it). Two non-discipline specs glob `lib/`, not
   twenty-one, and `spec/repo_as_fixture_spec.rb` now guards against the pattern returning.
4. **Split T7 and T8 across waves.** Both target `spec/lain/tools/subagent_spec.rb`, which simplify-09
   also names. This is the plan's only serious contention and it is currently scheduled as a single wave.
5. **Drop the "T2/T5 must not share a wave with 08/09" constraint** to a one-line note about
   `spec/lain_spec.rb`. The measured overlap is one 54-line file.
6. **Resulting waves:**
   - Wave 1: T3, T4, T9
   - Wave 2: T1 (←T4), T2
   - Wave 3: T6 (←T1), T7, T10, T11
   - Wave 4: T8
   - Critical path: T4 → T1 → T6
7. **Re-ground before executing, in this order of urgency:** T1's 18-describe module map (every line
   number moved; one describe is new), T2's percentage (8.35%, not 21.4%), the five-ranked reach-in files
   (two are dead, one moved path, the real #2 is unnamed), T6's clone clusters (one of three is gone),
   T3's three figures (41 / 5.05s / 184).
8. **Integration checks that cannot be honoured as written.** The section asks for `pspec` walls before
   and after for T1, T2, T3 and T5. With T5 closed and T1's floor claim unverified, restate it as: record
   the wall before the plan, after T1, and after T3, and say which of the two time claims held. The
   example-count arithmetic (17,837 as the baseline) is sound and should be kept verbatim.
