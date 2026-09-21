# Simplify 11 — retire the manifest that every new unit has to edit

status: in-progress — the 2026-09-13 ruling ("runs after simplify-08 and simplify-10 land, alone")
was **re-decided by the human on 2026-09-20** once the gate's premise was measured false. See the
Execution log.
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Execution log

**Executed 2026-09-20**, base ref `main` @ `76d872ed`. **`origin/main` is `b1927ce7`, 442 commits
behind HEAD** — every worktree is cut from `HEAD` explicitly, never from `origin/main`.

**The sequencing gate was re-decided, on evidence.** The 2026-09-13 ruling deferred this plan until
simplify-08 and simplify-10 had landed. Both were audited card-by-card against the tree on 2026-09-20
and **neither had**: 08 is 4 of 9 (T1–T4 landed; T5–T9 not), 10 is 4 of 12 plus one card closed by
ruling and one dropped (T1, T3, T4, T7 landed; T2, T6, T8, T10, T11, T12 untouched). The commit history
shows why: the nine card commits form one contiguous block from `cb27ae5d` (09-13 19:35) to `2f79c971`
(09-14 06:44), and at 09-14 09:43 `9b2ac4e7` pivots the work to simplify-09-orders-as-types. **Both
plans were abandoned mid-flight, not completed.**

**The gate's stated reason does not hold, so the human lifted it.** The reason was concurrency —
*"any other plan in flight will conflict on almost every file it touches."* Nothing is in flight: the
outstanding cards are unstarted, so there is no branch to rebase across 746 files. The ordering argument
runs the other way, and it is this plan's own thesis: 08's T6 (`arm/catalog.rb`), 08's T7
(`compare/sheet.rb`, `compare/metric.rb`) and 10's T11 (`lib/lain/refusals.rb`) each create a new lib
file, which under the manifest means a new manifest line this plan then deletes. Running this plan first
makes those cards smaller.

**simplify-08's T9 is decided: WIRE.** (human, 2026-09-20.) It was never reached during 08's run, so the
question had never actually been put. The altitude cluster is kept and given a door; `Grader::LeaseHarness`
— the only ground-truth outcome metric in the repo — stays reachable. **Consequence for T4: it does NOT
shrink.** `lib/lain/bench/live_arms.rb` and `lib/lain/bench/altitude.rb` both survive, so all four
workarounds are in scope, as the card's original text has them. 08's own wiring work lands later, on the
post-Zeitwerk tree.

**What is moot, and it is the registry half of T2.** `simplify-09-orders-as-types` (`7a1d4602`) deleted
`Lain::Algebra`, its registry, its seal and `spec/algebra_laws_spec.rb`. Verified absent on 2026-09-20:
`lib/lain/algebra.rb`, `lib/lain/algebra/`, `spec/algebra_laws_spec.rb`. `lib/lain.rb` holds no `.seal`
call. So T2's AC 5 and AC 6, its two seal escalation triggers, and the third Integration check have **no
referent** and are struck rather than re-scoped. `spec/value_object_shareability_spec.rb`'s sweep is
untouched and remains the real load-completeness canary.

**T4's fifth item is confirmed delivered.** `Fold::INDENT` (`lib/lain/frontend/neovim/fold.rb:29`) is the
one Ruby spelling, read by `inbox_view.rb:85` and `approval_view.rb:96`. T4 verifies that leaf under
autoloading rather than re-doing it.

**Grounding re-measured 2026-09-20; every headline figure had drifted.** `lib/` holds **746** `.rb` files
and **746** `require_relative` lines, not 749/748. `lib/lain.rb` is **101 code lines, 86 requires**, not 99.
There are **21** pure index files, not 24. Zeitwerk **2.8.2** is confirmed resolved in `Gemfile.lock`
(transitively, via ActiveSupport) — that claim holds.

**T1's `ignore` list is materially larger than the plan's estimate, which its own escalation trigger
asked to be told.** Deriving the expected constant from each path and checking whether the file defines
it yields **26 mismatches**, of which 9 are pure index files that T3 *deletes* (Zeitwerk supplies the
namespace) and **17 are permanent `ignore` + explicit require**, against the plan's "~13":

    cli/command/small.rb   context/base.rb        epic/records.rb        forge/landing/run.rb
    frontend/reline.rb     live.rb                review/records.rb      review/vocabulary.rb
    silent.rb              version.rb
    telemetry/{secret_boundary,session_lifecycle,session_state,stream_signals,switches,test_layout,turn_stream}.rb

Three are worse-shaped than "grouped values": `live.rb` defines only the **method** `Lain.live` and no
constant at all; `silent.rb` defines `SILENT`; `context/base.rb` defines `Combinator`/`Identity`/`Composed`
and nothing named `Base`. Seven sit in `telemetry/` — but only 7 of that directory's 33 files, so there is
no wholesale-ignore shortcut. **And the plan never counted the non-Ruby tree**: ~20 directories under
`lib/` hold 68 non-`.rb` files (`prompt/templates/**`, `structural/queries/**`, `bench/corpus`, the Lua
under `frontend/neovim/runtime`) which also want `ignore` entries. The 2 acronym inflections (`CLI`, `TTY`)
are confirmed as the only ones.

### T1's panel review restructured the plan (2026-09-20)

T1 landed APPROVE-WITH-FIXES. Its measurements are real (boot +13.4 ms by the implementer, +3.3 ms on
the panel's independent re-measure; `pspec` unchanged at 95 s) but **neither can authorise T2**: with the
manifest still live, `eager_load` loads no file, so both are the cost of *walking* the tree and both are
a floor. **Nothing short of building T2 produces T2's number**, and the Open decision should say that
rather than cite +1.6%.

**T1's escalation was falsified, and the method is why.** It enumerated load-time breakage by registering
autoloads and then requiring every file **in manifest order** — which defines each constant before the
referencing file loads, so the method structurally cannot observe the failures it was looking for. A
manifest-free probe finds at least four sites, in this order:

1. `lib/lain/agent.rb:67` — `::Lain::StopReason`, defined by `response.rb`, which maps to
   `Lain::Response`; no autoload is ever registered for it.
2. `lib/lain/bench.rb` — `Zeitwerk::NameError: expected file lain/bench.rb to define constant
   Lain::Bench, but didn't`. **A pure index file**, resolving today only because the manifest defined
   the namespace from its children first.
3. `lib/lain/config/epics.rb:78` — `Gates.empty` in a default argument. **Irrecoverable**; the explicit
   require does not clear it. A real cycle, and enumeration stops here.
4. `lib/lain/arm/ladder.rb:21` — the originally claimed "only" site, never reached.

**Three structural consequences, and the first changes the waves.**

- **T3 is a PREREQUISITE of T2, not its wave-mate.** Finding 2 is the proof: an index file whose body is
  only requires defines no constant, so under a manifest-free loader it raises. The 21 index files must
  go *with* the manifest, in one change. The Waves section below is wrong as written.
- ~~**The manifest was HIDING a real cycle.**~~ **RETRACTED 2026-09-20 by the T2a spike — there is no
  cycle.** `config/gates.rb` defines `Config::Epics::Gates`, so the file is simply in the wrong place:
  `git mv config/gates.rb config/epics/gates.rb` dissolves the failure *and* its `ignore` entry. The
  earlier probe called it irrecoverable because it reached for an explicit require, **which is the move
  that manufactures the cycle**. CLAUDE.md's cycle justification is therefore neither confirmed nor
  inverted by this plan, and T5 must not claim it is. What the episode does show is the spike's real
  structural finding, below: an `ignore` entry is not a neutral accommodation — it can create the very
  defect it appears to work around.
- **The tail is unmeasured.** **293 constants across 101 files are orphans** — no prefix of the constant
  path maps to the file defining it. Under eager loading most are latent, because every file loads
  regardless; the live hazard is only references made at **class-body/load time**, which is the set
  enumeration is blocked on.

**Ruling (human, 2026-09-20): spike the worklist before deleting anything.** A bounded investigation —
manifest-free eager load, fix each load-time failure as it surfaces (the `config/epics` cycle included),
repeat until it completes clean — whose output is the true worklist, a real count, and T2's actual boot
and `pspec` numbers. T2 is re-planned against that, not against an estimate.

### T2a — the worklist spike, and what it changes (2026-09-20)

A manifest-free tree was built and **it boots**: zero `require_relative` under `lib/`, `eager_load` kept,
no shim. The suite runs **20,475 examples against a 20,475 baseline — nothing silently vanished**, which
is the failure this whole exercise exists to avoid. Thirteen examples fail, and every one of them is a
spec that *pins the manifest itself* (three `require "lain/context/base"` in specs, three rows in
`review/deletability_spec` naming index files, `thread_view_spec` asserting a literal `require_relative`
line, `config/gates_spec`, and `zeitwerk_spec`'s own orphan exemplar).

**The honest measurement, at last.** Boot `0.87 s → 0.90 s`, **+3%, a wash**; per-worker spec load time
**improves**, 2.97 s → 2.16 s. Prior figures were taken with both mechanisms live and were only a floor.
**The plan cannot be sold on speed — it is not faster.**

**The worklist is 13 sites, not 4**: 3 one-line root-qualifications, 8 mechanical file moves or splits,
**2 needing real thought**. The reason nobody had the number is that the earlier probe enumerated one
boot at a time; an enumerator that reports the whole remaining list in a single 2-second run is what
unstuck it.

**Two hazards nobody anticipated, and the second is the serious one.**

1. **The compiled extension's magnus init calls `Lain.const_get("Error")` at load**, so `loader.setup`
   must run *before* `require "lain/lain"`. An ordering constraint Zeitwerk does not remove, merely moves.
2. **`declarative/types.rb` registers `:lain_canonical` with ActiveModel as a top-level side effect.**
   No constant reference can ever trigger its autoload, so **Zeitwerk is structurally blind to it**. This
   is exactly the class CLAUDE.md's own trap names — a file depending on load *order* rather than on a
   constant being defined — and it is the one shape autoloading cannot represent at all.

**T3 is reversed: keep the index files, do not delete them.** Deletion boots, but an implicit namespace
is a bare `Module` with nowhere to put a unit-level constant (`Epic::STAGES`) or a docstring — and **5 of
9 carry the only prose describing their namespace**, `provider/http.rb`'s ruby_llm fork provenance among
them. The card's premise that they are "pure indexes" is false for most of them.

**The structural finding, which is the one to carry forward.** The `ignore` list does not delete the
manifest — **it hides it**. An ignored file needs a hand-written require, and that require's position
relative to `eager_load` is load-bearing, with real members on both sides. Fourteen ignores remain and
they **work by construction, not by proof**. The `config/gates.rb` episode is the proof of the danger: an
`ignore` entry manufactured a failure that looked irrecoverable and was in fact a misplaced file.

**Recommendation from the spike, and it re-shapes the remaining work into two cards.**

- **Card A — make every file name its own constant, driving `ignore` entries to 0.** Renames, moves and
  splits, landing **with the manifest still in place**, green at every step and stoppable anywhere. It is
  the whole risk, taken in safe increments, and it has standalone value: a tree where path and constant
  agree is better under the manifest too.
- **Card B — the sweep.** Once A is done, deleting the manifest is small.

This supersedes the `T2+T3 as one card` shape recorded above.

## Simplification ledger

Kept per card, because this plan's headline (*"−748 `require_relative` lines and −24 files"*) counts
only what is removed. Zeitwerk **adds back** an `ignore` entry and an explicit require per mismatched
file — the "manifest in miniature" its own escalation trigger names — so the honest figure is the net,
and the honest risk metric is the `ignore` list's size. Baseline measured 2026-09-20 at `76d872ed`.

| | baseline | after T1 | A1–A3 | **Card A done** | after B |
|---|---|---|---|---|---|
| `lib/**/*.rb` files | 746 | 746 | 762 | **791** | |
| `lib/` code lines | 54,997 | 55,025 | 55,102 | 55,272 | |
| `require_relative` in `lib/` | 746 | 746 | 762 | **790** | |
| external `require "…"` in `lib/` | 302 | 303 | 304 | 304 | |
| `lib/lain.rb` code lines | 101 | 129 | 124 | **109** | |
| `CLAUDE.md` lines | 304 | 304 | 307 | 323 | |
| **`ignore` entries (files)** | 0 | 17 | 12 | **0** | |
| **`ignore` entries (dirs)** | 0 | 1 | 0 | **0** | |
| explicit requires kept | 0 | 18 | 12 | **0** | |
| orphan constants *(see below)* | — | 294 | 278 | **296** | |
| `require "lain"` boot | 835 ms | 848 ms | | | |
| `pspec` wall @ 12 workers | 95 s | 95 s | ~99 s | ~105 s | |
| example count | 20,470 | 20,475 | 20,475 | **20,495** | |

**Card A is done, and the table says what it cost.** The `ignore` list is empty — the hidden manifest
is gone — and `lib/lain.rb` is down to 109 code lines from a peak of 129. Everything else moved the
wrong way, by design: **+45 files and +44 `require_relative` lines**, because splitting a file so it
names its constant creates files and each needs a manifest line while the manifest still stands.

**The orphan count rose, 278 → 296, exactly as predicted.** That is the row behaving as the note below
says it must: removing an `ignore` entry *adds* that file to the sweep. A fall here would have meant
something was wrong with the measurement, not with the tree.

**The directory ignore is gone**, which matters more than the count suggests: a directory entry hid a
whole subtree from the loader, so `review/records/` could have grown new unmapped files indefinitely
without the sweep noticing. Twelve file entries remain, all in `telemetry/` bar four.

T1 is additive by design, so every removal row is flat and only the cost rows move. That is the card
working as specified, not a null result: it buys the `ignore` list as a **measured** 18 rather than the
plan's estimated "~13", and it buys both cost rows before anything is deleted.

**Card A moves the headline metric the WRONG WAY, and that is correct.** `lib/` went 746 → 759 files and
`require_relative` 746 → 759 with it, because splitting a file for its constant creates files and each
one needs a manifest line while the manifest still stands. **Card A grows the manifest so that Card B can
delete it.** Anyone reading this table mid-flight should expect the require count to keep climbing until
B lands, and should judge Card A on `ignore entries` alone.

The `external require` 303 → 304 is A1's `require "active_model"` in `declarative.rb`, which is exactly
what CLAUDE.md's leaf-requires rule prescribes. The `CLAUDE.md` 304 → 307 is not this plan's doing — it
is the corrected quiet-box gate, filed while here.

Two rows are to be read adversarially. **`external require` must not move**: CLAUDE.md's rule that
gem/stdlib requires live in the leaf files that use them is correct and untouched by this plan, so a
change there is usually a card exceeding its scope. It moved 302 → 303 at T1, and that one is
**legitimate** — `require "zeitwerk"` in `lib/lain.rb`, which is exactly what the rule prescribes. Any
further movement is not. **`example count` must not drop**: no card here deletes an example, and a drop
means a file stopped loading and its specs silently vanished — precisely the failure autoloading makes
possible. The +8 at T1 is `spec/zeitwerk_spec.rb`.

**`orphan constants` does NOT measure this plan's progress, and the row is kept only to stop anyone
reading it that way.** It was added on 2026-09-20 as the row Card A drives; that was wrong, and a panel
probe settled it. `ZeitwerkMapping.orphans` **rejects ignored files before comparing paths**, so a
constant inside an ignored file was never counted in the first place. Removing an `ignore` entry
therefore *adds* that file to the sweep: the count is **monotone non-decreasing** under exactly the work
this plan does, and it will **rise** as Card A succeeds. Measured — re-adding A3's three entries returns
exactly 294, and un-ignoring any survivor raises it (`epic/records.rb` +27, `frontend/reline.rb` +19,
`telemetry/turn_stream.rb` +19, `live.rb` +0).

So the falls recorded against A1 and A2 (−10 and −6) did not come from their `ignore` removals at all.
They came from **relocating constants** into files whose paths name them, which is a different and
smaller part of each card. Read the row as "constants whose loaded, non-ignored file does not name
them", never as a burn-down.

**The gauge that cannot be gamed is `ignore entries`.** An entry is in the list or it is not, and the
list is the hidden manifest this plan exists to remove.

**Two CLAUDE.md figures are stale, found by baselining.** It states the suite as *"51s at 12 workers,
17,837 examples, 2026-09-13"*. Measured 2026-09-20 on this box: **95 s and 20,470 examples** — the suite
grew 15% and the wall nearly doubled inside a week. **T5 edits CLAUDE.md and should correct both**, since
the plan's own premise is that a document's ledger shifts under it.

The net is what settles whether this plan was worth running: `−746 require_relative` and `−21` files
against `+(ignore entries + explicit requires + loader config)` in `lib/lain.rb`, plus whatever the
eager load costs on every boot and 12× on every suite run.

## Intent

`lib/lain.rb` is the most-churned file in the repository — **82 commits in nine weeks for 99 code
lines of pure require list** — because CLAUDE.md's centralized-requires rule makes it a serialization
point every new unit must edit. That rule also forces a committing constraint, has caused at least one
merge to trip a cop neither branch crossed, and **was directly producing duplication**: one view could not
read a sibling's constant because the manifest loads it first, so the constant was written twice in Ruby
and a third time in Lua. **That last one is fixed as of 2026-09-13** — simplify-07's T7 extracted
`Fold::INDENT` as a leaf loaded before both consumers, which is what CLAUDE.md's own requires rule
prescribes, so the plan's strongest concrete deliverable has been delivered by other means. What remains
is churn, a committing constraint, and a merge hazard.

Zeitwerk is already in the bundle and only 17 of 749 files need an inflection. This plan replaces the
manifest with a loader, deletes 24 index files, and removes the rules the manifest existed to support.

Delivers: **−748 `require_relative` lines and −24 files**; `lib/lain.rb` from 99 code lines to ~40; the
commit-ordering rule gone from CLAUDE.md; and the documented load-order workarounds in the bench removed
— **as many of the four as simplify-08's T9 leaves standing**, since three of them sit in the altitude
cluster T9 decides on. The fifth item, the `inbox_view` duplication, is **already gone**: simplify-07's T7
removed it without Zeitwerk. See Open decisions.

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

> **2026-09-14, amended — the blocker is gone.** `simplify-09-orders-as-types.md` deleted the
> registry, the seal, the sweep, and `spec/support/algebra_generators.rb` whole (`7a1d4602`):
> `lib/lain/algebra.rb` and its siblings under `lib/lain/algebra/` no longer exist, `lib/lain.rb`
> has no `.seal` call and no reference to `Lain::Algebra`, and `spec/algebra_laws_spec.rb` /
> `spec/lain/algebra_spec.rb` are both deleted. Every law that registry swept now runs inline in
> its own subject's spec (`spec/lain/toolset_spec.rb`, `spec/lain/interval_partition_spec.rb`,
> `spec/lain/usage_spec.rb`, `spec/lain/compaction/strategy_spec.rb`, and others), with no
> process-wide sealed state and therefore no load-order dependency for Zeitwerk to break. The
> autoload hazard this whole section documents — a seal at require time closing an **empty**
> registry under lazy class-body evaluation — cannot occur, because there is no registry left to
> seal. Everything below through T2's registry-close design (the eager-load-vs-seal-on-first-read
> choice, the count-preservation check, the empty-registry guard) is **moot as written** and needs
> re-scoping to whatever T2 actually still has to do once the registry half of its job no longer
> exists; `spec/value_object_shareability_spec.rb`'s 267-class sweep is unaffected and still real.

**Under Zeitwerk, class bodies do not run until a constant is referenced.** So a seal at require time
would close an **empty** registry, and `spec/algebra_laws_spec.rb` would sweep nothing while passing.
Filed at the time of writing: 24 claims and 5 refutations; re-measured 2026-09-13 it is roughly **18
declarations and 6 refutations**, with `lib/lain.rb:141-162` now mirroring the three Timeline claims onto
`Lain::Ext::Timeline`. **The count moves — read the registry, never this number.** The argument does not
move: this is the one place the manifest is doing real work that autoloading cannot replicate, and the
plan must answer it explicitly rather than discovering it at T2.

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
  depend on every class being loaded: the algebra seal (~18 declarations), the shareability sweep (267 classes),
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
- **Scheduled 2026-09-13: after 08 and 10, alone.** The human's ruling is that **simplify-08 and
  simplify-10 run now and this plan runs afterwards, once both have landed**, in a window of its own.
  That is the same constraint the Orchestrator contract already states (*"Run this plan alone"*) and the
  same one the bullet above reaches (*"if it runs, it runs last, alone"*) — the ruling settles **when**,
  not whether. The sequencing is not administrative: T2 deletes 748 require lines across 749 files, so
  any plan in flight conflicts on almost every file it touches, and a rebase across 749 files is not a
  rebase.
- **Two things landed in the window that weaken the case without changing the decision.**
  - **simplify-07's T7 has shipped, and with it T4's fifth item.** The panel called
    `inbox_view.rb:83-87`'s respelling of `ApprovalView::INDENT` this plan's *strongest concrete
    deliverable*. It is gone: `Fold::INDENT` is now the one Ruby spelling, read by
    `lib/lain/frontend/neovim/inbox_view.rb:84` and `approval_view.rb:96`, by exactly the mechanism
    CLAUDE.md's requires rule already prescribes — a leaf loaded before both consumers. **T4 shrinks to
    confirming that leaf is still the right shape under autoloading**, which is what its own text
    anticipated. What is left of the case is 748 require lines, a 1.5× churn ratio, and four bench
    awkwardnesses.
  - **Three of those four bench workarounds sit in files simplify-08's T9 may retire.**
    `live_arms.rb:9-11`, `live_arms.rb:70-80` and `altitude.rb:24-28` are all in the altitude cluster T9
    decides on; only `compare.rb:214-217` is certainly outside it. **So T4 cannot be finalised until 08's
    T9 decision is known** — which the new sequencing guarantees, since 08 lands first. If T9 retires the
    cluster, T4 is one workaround and a verification, and the panel should be asked again whether that
    is a plan.
- **simplify-09 was dropped entirely on 2026-09-13, and T2's counts are stale independently of that.**
  T2's fourth-from-last escalation trigger warns that simplify-09's T3 and T4 would change the registry
  counts in AC 5. **That trigger is void** — 09 is not running. But AC 5's *"twenty-four claims and five
  refutations"* is stale anyway: measured today the registry holds roughly **18 declarations and 6
  refutations**, and `lib/lain.rb:141-162` now mirrors the three Timeline claims onto
  `Lain::Ext::Timeline`. **The card must read the registry rather than copy any number from this plan** —
  and it must not treat the seal as incidental while doing so; `planning/specs/research-algebra-registry-vs-operations.md`
  is the record of why the registry and its close are load-bearing.

## Waves

**Superseded 2026-09-20 by T1's panel review — see the Execution log.** The original reading was:

    Wave 1: T1
    Wave 2: T2, T3
    Wave 3: T4, T5
    Critical path: T1 → T2 → T4

It is wrong in one structural way: **T2 and T3 cannot be independent cards.** A pure index file defines
no constant, so removing the manifest while the index files stand raises `Zeitwerk::NameError` on the
first one loaded. They are one change to one load sequence, exactly as the seal once was. The schedule
as executed:

    Wave 1:  T1                      [landed 2026-09-20, 203085a9 / f5b277b9]
    Wave 1b: T2a — the worklist spike [done 2026-09-20, findings above]
    Wave 2:  Card A — every file names its own constant; ignores -> 0.
                      Lands WITH the manifest in place, green at every step.
    Wave 3:  Card B — delete the manifest. Small, once A is done.
    Wave 4:  T4, T5
    Critical path: T1 → T2a → A → B → T4

**T3 is struck**, not rescheduled: the spike found the index files must be kept. Its deletions were
premised on their being pure indexes, and most are not.

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

**Amended 2026-09-20, after the card landed (human ruling).** Two of the four scenarios above are no
longer specs, and the reason generalises: **a misconfigured loader needs no spec, because it stops
`require "lain"` and every example in the suite fails with it.** *"An acronym resolves"* and *"a circular
dependency is reported"* are both of that kind — the second doubly so, since it exercised Zeitwerk's own
cycle reporting rather than anything of lain's. Two further examples went with them for the same reason
(per-path constant resolution; an ignored file left unrequired), taking the file from 10 examples to 5
and 216 lines to 147, and removing its only `:seam`.

What stays is what **survives a green boot and is still wrong**: a constant no path names, findable only
because the file defining it is one the loader loads (the orphan invariant, which is what measured the
294); an ignore entry the loader never needed, which silently narrows it; and an entry naming a file that
is gone, which is inert. The dividing line — *can this guard fail independently of the app booting?* —
is the repo's own, and both precedents hold it: `spec/value_object_shareability_spec.rb` stays in the
suite, while simplify-10's T3 moved `spec_discipline_spec.rb` out to `bin/spec-census` as *"a disabled
guard wearing a spec's name."*

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
check**: whatever the registry holds before the loader is introduced must still be there after. At the
time of writing that was 24 declarations (elementwise 7, meet_semilattice 5, monoid 4, pure 4,
attenuation 2, commutative_monoid 2) and 5 refutations; on 2026-09-13 it is roughly 18 and 6. **Capture
the real numbers first and compare against those** — the comparison is the check, not the constants.

> **2026-09-14: moot.** `simplify-09-orders-as-types.md` deleted `Lain::Algebra`, its registry, its
> seal and `spec/algebra_laws_spec.rb` (`7a1d4602`); a law now runs as an `include_examples` in its
> subject's own spec and needs no load-time completeness. So the registry-close half of this card —
> both shapes above, the count check, AC 5, AC 6 and the two escalation triggers about the seal — has
> nothing left to act on. They are left in place for the next run of this plan to re-scope, not deleted
> here; the manifest removal and ACs 1–4 stand.

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
  Then it holds every declaration the registry held before the loader was introduced

Scenario: an empty registry is still refused
  Given the law sweep
  When it runs against a registry holding no claims
  Then it fails, saying no claim was made
```

**AC 5 and AC 6 are moot as written** (2026-09-14) — see the dated note under T2's registry close.

→ spec files: `spec/zeitwerk_spec.rb` (AC 2, AC 3), `spec/value_object_shareability_spec.rb` (AC 4 —
existing, and the count is the check), `spec/algebra_laws_spec.rb` (AC 5, and **AC 6 is new and is the
registry half's real deliverable** — 2026-09-14: this file no longer exists, deleted with the registry
by `7a1d4602`; AC 5 and AC 6 need a different home or drop with it), plus a CLI spec for AC 1

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
  (2026-09-14: moot — see the dated note under T2's registry close.)
- **If the seal cannot be made to work under autoloading in either shape, stop the whole plan.** The
  registry is how lain's algebraic claims are held to their laws, and no amount of require-line deletion is
  worth losing it silently. (2026-09-14: moot — see the dated note under T2's registry close.)
- **This trigger is void, and the counts were wrong anyway.** It warned that simplify-09's T3 and T4 would
  change the expected counts in AC 5; **simplify-09 was dropped entirely on 2026-09-13**. But AC 5's
  *"twenty-four claims and five refutations"* is stale on its own — measured, the registry holds roughly
  **18 declarations and 6 refutations**, and `lib/lain.rb:141-162` now mirrors the three Timeline claims
  onto `Lain::Ext::Timeline`. **Read the registry; copy no number from this plan.** And do not treat the
  seal as incidental while doing so — `planning/specs/research-algebra-registry-vs-operations.md` records
  why the registry and its close are load-bearing.
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

**Depends on:** T2, and on **simplify-08's T9 decision** being known
**Files:** modify `lib/lain/compare.rb` and — only if T9 kept them — `lib/lain/bench/live_arms.rb`,
`lib/lain/bench/altitude.rb`; verify `lib/lain/frontend/neovim/fold.rb`'s leaf under autoloading; modify
the corresponding spec files
**Reuse:** the four workarounds each name their own cause in a comment, so each comment becomes the
record of why it went
**Shared-file wiring:** none
**Reachable from:** `LiveArms.build` is on the `bench arms` path; `inbox_view` renders on the live editor
path. AC 1 drives `bench arms`; AC 3 drives the editor.

Four workarounds whose stated reason is gone — **and three of the four sit in files simplify-08's T9 may
retire**, so this card cannot be finalised until T9's decision on the altitude cluster is known:

- `live_arms.rb:9-11` — `LiveArms` can become a constant map rather than a module-with-builder. *(in T9's
  scope)*
- `live_arms.rb:70-80` — `Seams` can default `grading:` and `layout:` to the objects they stand for,
  rather than to `nil` resolved in a method body. *(in T9's scope)*
- `altitude.rb:24-28` — `METRICS` can name constants at class-body time. *(in T9's scope)*
- `compare.rb:214-217` — the pin of `compare` before `bench` goes. *(the one certainly outside it)*

**The fifth item is DONE, and it was the most valuable one.** `inbox_view.rb:83-87` respelling
`ApprovalView::INDENT` was the duplication the panel called this plan's strongest concrete deliverable.
**simplify-07's T7 landed and removed it** — `Fold::INDENT` is now the one Ruby spelling, read by
`lib/lain/frontend/neovim/inbox_view.rb:84` and `approval_view.rb:96` — by the mechanism CLAUDE.md's
requires rule already prescribes: a leaf loaded before both consumers, no Zeitwerk required. **So this
card shrinks to confirming that leaf is still the right shape under autoloading**, exactly as its own text
anticipated, plus whichever of the four workarounds T9 leaves standing.

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

### Card A — every file names its own constant   [wave 2] [risk: medium]

**Written 2026-09-20 from the T2a spike.** Replaces T2's first half and all of T3.

The goal is one sentence: **every file under `lib/` defines exactly the constant its path names, and
`LOADER_IGNORES` reaches zero.** Everything lands **with the manifest still in place**, so the tree is
green at every step and the card is stoppable anywhere — which is what makes a 120-file change safe.
Nothing here deletes a `require_relative`; that is Card B.

Each sub-card is a disjoint file tree and they run in parallel. All of them touch `lib/lain.rb`'s
manifest, which is the one shared file — **hand back those lines as a diff, do not merge them.**

- **A1 — the one-liners and the three small moves.** `loader.setup` above the extension require (magnus
  calls `Lain.const_get("Error")` at init); root-qualify `arm/ladder.rb:21`; name `Types` in
  `declarative.rb`. Then `config/gates.rb` → `config/epics/gates.rb` (it is `Config::Epics::Gates`; this
  is the whole of the reported "cycle"), `context/base.rb` → three files, and `StopReason` out of
  `response.rb`.
- **A2 — the Epic cluster.** `STORED_STATUSES`, `DERIVED_STATUSES`, `MalformedIssue` and `REVISION_OPS`
  move into `epic.rb`, the namespace file. Split `epic/records.rb` (220 code lines, ~18 record types).
- **A3 — the Review cluster.** `review/vocabulary.rb` merges into `review.rb` — it *is* the namespace's
  vocabulary, and `review.rb` is already a declaration file with a docstring, so the two join cleanly.
  `review/records/corpus_extended.rb` moves up a level. Split `review/records.rb` (136 lines, ~7 types).
- **A4 — the telemetry record groups.** Seven files, same shape:
  `{secret_boundary,session_lifecycle,session_state,stream_signals,switches,test_layout,turn_stream}.rb`.
- **A5 — the small five.** `cli/command/small.rb`, `forge/landing/run.rb`, `frontend/reline.rb` (defines
  `Frontend::LineEditor`), `live.rb` (defines only the method `Lain.live`, no constant at all),
  `silent.rb` (defines `SILENT`).
- **A6 — the enumerator, as a permanent guard.** The spike's `t2a-enumerate.rb` is the only thing that
  sees the fragility described below. It becomes a checked-in tool in the `bin/comment-census` /
  `bin/spec-census` tradition.

**The convention this establishes, and it must be written down or it will not hold.** An index file is
no longer a require list. It is **the namespace's docstring and the namespace's own constants** — which
is why T3's deletion is struck and why A2's four `Epic` constants move *into* `epic.rb` rather than
anywhere else. The codebase does not have this convention today. T5 writes it into CLAUDE.md.

**Why A6 is not optional.** Some constants resolve today **by alphabetical luck**: Zeitwerk's eager load
walks each directory in sorted order, so `epic/issue.rb` happens to precede `epic/records.rb`, and
`review/anchor.rb` happens to follow `review.rb`. **Rename a file and a latent orphan becomes a boot
failure**, with the error surfacing at an unrelated file. That fragility is invisible to the suite, to
`rubocop` and to a reader. Only the enumerator sees it.

**Acceptance criteria**

```gherkin
Scenario: a file defines the constant its path names
  Given the loader's expected constant for each managed path
  When the tree is eager-loaded
  Then each managed file defines the constant expected of it

Scenario: the ignore list is empty
  When the loader's ignore list is read
  Then it names nothing

Scenario: the manifest still loads the tree
  Given the manifest unchanged but for moved paths
  When the library is required
  Then every constant resolves as before

Scenario: a constant referenced at load time is reported before it breaks a boot
  Given a constant named at class-body time from a file no path implies
  When the enumerator runs
  Then it names that site
```
→ spec files: `spec/zeitwerk_spec.rb` (the first two — the existing orphan sweep is the check, and its
`ignore`-list examples become assertions about an empty list); the third is the suite staying green;
the fourth is A6's own.

**Escalation triggers**
- **`epic/records.rb` and `review/records.rb` are the largest mechanical job in the exercise** (~25 new
  files between them) and they collide with the *"one spec file per public entry point"* rule. If
  splitting either forces a spec split that rule forbids, stop and report — that is a rule conflict, not
  a judgement call.
- **`live.rb` defines no constant at all.** It cannot be made to name one without inventing a namespace
  for a single method. If the honest answer is that it stays an `ignore`, say so — a list of one is a
  different argument from a list of fourteen.
- `frontend/reline.rb` defines `Frontend::LineEditor`. Renaming the file is the obvious fix; confirm
  nothing outside `lib/` names the path.
- **Do not delete a docstring to move a constant.** Five of nine index files carry the only prose for
  their namespace, `provider/http.rb`'s ruby_llm fork provenance among them.

### Card B — delete the manifest   [wave 3] [risk: high]

**Written 2026-09-20 from the T2a spike and A6's census.** Replaces T2's second half.

**Depends on:** Card A entire, because a manifest-free tree boots only once every path names its
constant. `LOADER_IGNORES` must read zero first: an ignored file needs a hand-written require, and
under no manifest there is nothing left to write it in.

Delete every `require_relative` under `lib/` — `lib/lain.rb`'s and each unit index's — and let the
loader do all of it. `eager_load` **stays**: 278 orphan constants are latent only because every file
loads regardless, and dropping it converts each one into a load-order dependency that boots clean and
raises in production from a method body.

**What survives in `lib/lain.rb`:** the loader with its inflections, the compiled-extension require and
its `LoadError` re-raise, the bare `module Lain` purpose statement, and whatever namespace members
Card A's A5 placed there. External gem and stdlib requires stay in the leaf files that use them —
CLAUDE.md's rule is correct and untouched.

**Index files are KEPT.** Only their `require_relative` lines go. T3's deletion is struck: an implicit
namespace is a bare `Module` with nowhere for a unit-level constant or a docstring, and five of nine
carry the only prose describing their namespace.

**The worklist is known, which is what makes this card tractable.** `bin/zeitwerk-census` (A6) boots a
scratch copy of `lib/` with every internal require stripped, under the loader alone, in **sorted and
reverse-sorted order** — two of the sites below are invisible in forward order, by alphabetical luck
alone. Run it first and work its output; do not rediscover this by bisecting one boot at a time, which
is how two earlier attempts stalled.

Seven load-time orphan references stood on 2026-09-20: `Epic::STAGES` from `arm/ladder.rb:24`
(A1 correctly removed the *shadow* there; the constant still lives in `epic/stage.rb`, which maps to
`Epic::Stage`), `Price` from `bench/decider_sweep.rb:70`, `Mode::LayerSet`, `Provider::HTTP`,
`Telemetry::SessionRead`, `Epic::MalformedDocument`, `Epic::MalformedGraph` — plus
`epic/submission.rb:18` reading `STAGES`, found by A2's panel. **Re-derive rather than trusting this
list**; Card A moved constants after it was taken.

**Acceptance criteria**

```gherkin
Scenario: the library loads with no internal require
  When the library is searched for internal relative requires
  Then none is found

Scenario: every command still loads
  When each top-level command is invoked with a help flag
  Then none fails to load

Scenario: the tree boots in either directory order
  Given the loader alone, with no manifest
  When the tree is eager-loaded in sorted and in reverse-sorted order
  Then both complete

Scenario: the shareability sweep still sees every value class
  When the value-object shareability spec runs
  Then it examines the same number of classes as before
```
→ spec files: `spec/zeitwerk_spec.rb`, `spec/value_object_shareability_spec.rb` (existing — **the count
is the check**), plus `bin/zeitwerk-census` run whole-tree

**Escalation triggers**
- **The example count is the canary and it must not drop.** `parallel_tests` reports only the examples
  that SURVIVED, so a file that stops loading takes its specs with it and still reads as a pass. Take a
  `--dry-run` count first; it is load-immune.
- **Do not drop `eager_load`** to make something pass. That is the one change that converts 278 latent
  orphans into live ones, and the failure would surface in production, not here.
- The compiled extension's magnus init calls `Lain.const_get("Error")`, so `loader.setup` must precede
  `require "lain/lain"`. Confirm the build instruction still reaches a reader with no `.so` — by hiding
  the artifact, not by reading the code.
- **This is the card that finally measures the thing.** Every boot and `pspec` figure so far was taken
  with both mechanisms live, so `eager_load` loaded nothing and the numbers are a floor. Record both
  here. The spike's one-off read was boot 0.87 s → 0.90 s and per-worker spec load 2.97 s → 2.16 s;
  **the plan cannot be sold on speed** and this card should say so plainly rather than quietly.

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
  T5's AC 4 is the guard. (2026-09-14: moot — see the dated note under T2's registry close.)
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
