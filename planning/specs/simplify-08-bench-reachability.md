# Simplify 08 — make the bench measure the harness, and give its experiments doors

status: in-progress
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

CLAUDE.md's first line says the bench is the deliverable and that the harness, not the model, sets the
score. Measured against the code, the bench runs with **no tools, no context strategy and no
compaction** — both agent-construction sites pass `Toolset.new([])` and neither passes
`instrumentation:` — and grades by parsing assistant prose for `FILE/END` blocks. So every number the
bench has produced measures the model.

Separately, 25% of the bench is reachable from no command, the grader's score never reaches the
Journal, and three written, spec'd and fixtured experiments have no `desc` block — one of them a
`Bench::CLI` method that only needs a door, two of them standalone classes that need a CLI method written
in front of them first.

This plan is mostly **wiring, not deletion**. Three lines make the score observable; five make a fourth
arm runnable; three subcommands decide whether ~3,500 lines of epic cluster are bench substrate or an
unreachable product.

Delivers: the grade on the experiment record; a real toolset and instrumentation on the bench path; a
fourth orchestration arm; an active comparability guard; three new subcommands; a project-extensible arm
roster; one report presenter; and a decision on every orphaned arm.

## Execution log

**Executed 2026-09-13**, base ref `main` @ `d4a7a1ea`.

**The Grounding's `d2bb133c` is not an ancestor of HEAD.** History diverged: HEAD carries 327 commits and
693 files that commit does not have. So nothing below inherits its authority from the 2026-09-12
verification — the plan was **re-verified empirically on 2026-09-13** and every figure in this document is
the re-measured one. The audit is at `planning/specs/staleness-08.md`.

**What landed in the window.** simplify-01, -03, -04, -05, -06 and -07 are all `status: done`, which
settles three of this plan's interlocks on its own: T7's *"assumes simplify-01 has landed"* is satisfied;
T8's *"confirm ownership with 03"* is moot, because 03 deleted none of the seven units it deferred; and
T9's handoff to simplify-04 is now a correction filed against a landed plan rather than a live one.

**What drifted, and what did not.** The plan aged better than the divergence implied — `bench/cli.rb` is
still exactly 480 lines with every method at the line named, every fixture is present at the byte size
quoted, and all three `require_relative` lines T8 removes are exact. What moved is mechanical:
**`ARCHITECTURE.md` is +27 lines throughout** (`:858`→`:885`, `:1008`→`:1035`, `:886`→`:913`,
`:875-880`→`:904`) and **`exe/lain` is +1** (`:568`→`:569`, `class Bench < Thor` `:510`→`:511`), plus
per-card refs in `grader/journaling.rb`, `compare/posture.rb`, `bench/altitude.rb`, `bench/decider_sweep.rb`
and `arm/epic.rb`. All are renumbered in place below.

**One whole new file no card named.** simplify-03 landed `spec/lain/review/deletability_spec.rb` (709
lines) — a machine-checked orphan map that pins the *unreachability* of four of the units this plan wires
or retires. Wiring is what makes its rows false, so T3, T5 and T8 each edit it. It is now a shared file in
the Orchestrator contract and named in those three cards' Files lists.

**Three sub-claims died and are corrected in place**: T2's `cli/wiring/base_tools.rb` path, T5's gemspec
escalation trigger, and T7's *"`Arm::Run#compare_run` has no caller"* — the last is moved to Open
decisions, because its premise is affirmatively false rather than merely stale.

## Grounding

Verified 2026-09-12 against the working tree at `d2bb133c`, and **re-verified 2026-09-13 against
`d4a7a1ea`** — see the Execution log. `code` is non-blank, non-comment.

**The harness is switched off on the bench path.** Two agent-construction sites:

    bench/cli/run_recorder.rb:59-62
      Agent.new(provider: @provider, toolset: Toolset.new([]), context: @context,
                journal: Memory::JournalMemoryRoot.new(journal:, recorder:),
                model_middleware: Stack.new([JournalRequests.new(journal:)]),
                tool_middleware: Stack.new([RefuseSecretWrites.new(journal:)]))

    bench/spawn_seam.rb:80-84
      def initialize(backend:, provider: nil, toolset: Toolset.new([]), system: nil)
    bench/spawn_seam.rb:119-123
      Agent.new(provider: @provider, toolset: @toolset, context: @context, journal:, ...)

**Empty toolset in both, and `instrumentation:` in neither** — so `PipelineSource::Null`. Note the
asymmetry: `RunRecorder` wires three middleware stacks and a `JournalMemoryRoot`; `SpawnSeam` wires
none. `SpawnSeam` also documents a dropped `spawned_from:` keyword at `:100-104`.

**Two more bench paths carry the same empty toolset**, on code this plan opens:
`bench/arm_sweep/recordings.rb:82` (the replay path T5 gives a door to) and `bench/plan_sweep/driver.rb:87`
(`bench plan-sweep`, already doored). They are **deliberately** empty — both replay recorded trajectories,
where a live tool call would make the replay non-deterministic. T2's AC 4 names them so the exemption is a
ruling rather than an omission.

Grading on the `arms` path runs through `ArmSweep.trajectory`, which concatenates **assistant text** and
parses it for `FILE/END` blocks; `exe/lain:585` says the default system prompt exists to teach that
format.

**The score never reaches the Journal.** `grader/journaling.rb` (66 lines) is the decorator that would
put it there — `#grade` `:36-42` calls the inner grader then pushes `Telemetry::GradeRecord.from(...)`.
It has **zero consumers**. `Telemetry::GradeRecord` has no reader. (The other `Journaling` classes in the
tree — `Oracle::Recorded::Journaling`, `Arm::DualLedger::Journaling` — are different classes.)

**The wiring point is one line.** `arm/driver.rb:152-153`:

    def distributions_for(arm)
      runs = @tasks.map { |task| arm.run(task, spawn_seam: @spawn_seam, isolation: @isolation, grader: @grader) }
      METRICS.transform_values { |spec| fold(runs, spec) }
    end

`@grader` (set at `:130`) is passed **verbatim**. Decorating it with
`Journaling.new(inner: grader, journal:)` is the whole change. Note `Arm::Instrument`
(`arm/instrument.rb`, 68 lines) touches **no grader at all** — it owns clock and price only
(`#timed` `:45-49`, `#price` `:58`), so it is not the insertion point despite the name.

**`exe/lain` declares five bench subcommands and only five.** `class Bench < Thor` at `:511-674`:
`variance` `:519-520`, `record` `:522-557`, `plan-sweep` `:559-562`, `sweep` `:564-567`,
`arms` `:569-636` (plus `no_commands` `:638-673`). Registered at `:691-693`, and the `desc` string
itself enumerates only those five.

**Three `Bench::CLI` methods have no door.** `bench/cli.rb` is 480 lines:

| line | method | reachable from argv? |
|---|---|---|
| `:40` | `variance_report` | yes, `exe/lain:520` |
| `:56` | `sweep_report` | yes, `:567` |
| **`:65`** | **`arm_sweep_report`** | **no caller anywhere** — not `exe/lain`, not any spec |
| `:74` | `plan_sweep_report` | yes, `:562` |
| `:120` | `arm_report` | library only |
| `:165` | `arms_report` | yes, `:629` |
| **`:216`** | **`altitude_report`** | **no argv caller**; spec-only (`cli_spec.rb:333`, `:409-410`, `:432`, `:445`, `:456`, `:463`) |
| `:258` | `record` | yes, `:554` |

Plus `Bench::DeciderSweep` and `Bench::DisclosureSweep`, neither reachable — and **neither is a
`Bench::CLI` method**. Both are standalone classes with their own `#report`, so T5 writes two new CLI
methods rather than adding three `desc` blocks to methods that already exist.

**And the fixtures for all of them are already committed:**
`spec/fixtures/arms/tasks.yml` (5,156B), `spec/fixtures/bench/arm_sweep/{recordings,stall,unknown_prompt}.yml`,
`spec/fixtures/altitude/tasks.yml` plus `epic/demo/` and four `subjects/` trees,
`spec/fixtures/bench/decider/cases.yml` (6,226B), `spec/fixtures/bench/disclosure/tasks.yml` (4,585B).
Spec line counts: `arm_sweep_spec.rb` 206, `altitude_spec.rb` 540, `decider_sweep_spec.rb` 170,
`disclosure_sweep_spec.rb` 104.

**`LiveArms.build` threads no grading.** `bench/live_arms.rb:117-125` returns three arms with a shared
`Arm::Instrument`, and passes **no `grading:`** — so `bench arms` arms cannot journal a grade.
`.altitude` `:93-99` does (`seams.grading || Arm::OneShot::PASS_THROUGH`).

`Seams` (`:70-80`) defaults `grading:` and `layout:` to **nil rather than to the objects they stand
for**, with the reason stated: *"`bench` loads BEFORE `arm` and `grader`, so a default naming either
here would be a boot-time NameError."* That is one of four documented load-order workarounds the
`bench/session` → `SessionRecord` merge would remove.

**`AdaptiveRouter` is 63 code lines behind five.** `arm/adaptive_router.rb` (31 code) honours the full
`#run(task, spawn_seam:, isolation:, grader:)` seam and `Oracle::Router.heuristic` (32 code) already
exists to drive it. One line in `LiveArms.build` makes it a fourth arm. Meanwhile
`ARCHITECTURE.md:885` claims *"Four arms ship"* and `exe/lain:569` says *"the three orchestration
arms"* — **the CLI is honest and the doc is not.** simplify-03 defers these two to this plan for
exactly this reason.

**simplify-03 did not delete them; it pinned them.** `spec/lain/review/deletability_spec.rb`'s
`adaptive_router` row asserts that **no file outside the row names `AdaptiveRouter` or `Oracle::Router` in
code**, and pins the literal `arm/{single_thread,orchestrator_worker,dual_ledger,adaptive_router}.rb`
marker into `ARCHITECTURE.md` (`:307`). Wiring the arm is what makes that row red. T3 owns the edit.

**`Arm::Epic` accepts and ignores three of four seam arguments.** `arm/epic.rb:134`:

    def run(task, spawn_seam: nil, grader: nil, isolation: NoIsolation, grading: nil) # rubocop:disable Lint/UnusedMethodArgument

with `:121-133` documenting that `spawn_seam`, `grader` and `grading` *"are accepted and unused, because
this topology's agents are spawned by the driver's own issue actors and graded there."* An arm that
discards three quarters of the seam is not on the seam.

**`Compare::Posture`'s guard cannot fire.** `compare/posture.rb:117`'s `.from_journal` is unreached, and
**no caller anywhere passes `posture:`** — so `Compare#guard_postures!` (`compare.rb:156-157`) is
permanently in its UNRECORDED branch. The guard that would stop you comparing a plan-mode run against
an auto-mode run can never fire. Note the guard uses `combination(2)` (`:157`), not `each_cons(2)`, and
`:153-155` argues why: posture agreement is not transitive.

**Five metric registries in three incompatible shapes, at three visibilities.** `Compare::METRICS`
(`compare.rb:95-102`) is **public** and uses `{label:, reader:, fmt:}`. `Arm::Driver::METRICS`
(`arm/driver.rb:40-49`) is **explicitly `private_constant`** (`driver.rb:50`), while
`ArmSweep::Report::METRICS` (`:20-25`), `PlanSweep::Report::METRICS` (`:15-19`) and `Altitude::METRICS`
(`altitude.rb:71-92`) are merely module-scoped — all four use `{of:, fmt:}`, and Altitude adds a third
key, `needs:`, with lambda `of:`s. So the collapse T7 proposes crosses **one public constant, one
deliberately sealed one, and three that are neither** — `private_constant` is a stated intent to keep
`Arm::Driver`'s registry out of any shared interface, and the card must honour it or argue it away.
`arm/driver.rb:22-28` already books this as a roadmap item and **sizes it with a stale count of "four"**.

**Visibility, not call-site count, predicted the clone.** `Compare::ArmFold` is constructed **six
times** (`compare.rb:198`, `sweep.rb:255`, `plan_sweep/report.rb:61`, `altitude.rb:231`,
`decider_sweep.rb:141`, `arm_sweep/report.rb:82`), so the shared fold *was* extracted and *is* adopted.
But `#titled` is **`private`** (`arm_fold.rb:83`, after `private` at `:76`), so three reports
hand-rolled it: `altitude.rb:215`, `decider_sweep.rb:128`, `arm/driver.rb:243`. The **public**
`Compare::Table` (39 lines) was rewritten by nobody.

`#pluralize` exists **three times, byte-identically**: `arm_sweep/report.rb:107`,
`plan_sweep/report.rb:84`, `altitude.rb:151`. **Eight** bespoke `#header` methods render the same sentence
shape — `sweep.rb:247`, `plan_sweep/report.rb:79`, `altitude.rb:142`, `arm_sweep/report.rb:100`,
`decider_sweep.rb:113`, `arm/driver.rb:197`, and the two an earlier count missed, **`bench/variance.rb:54`
and `bench/disclosure_sweep.rb:168`** — and **only two of them carry attribution**
(`arm/driver.rb:197-202`, `altitude.rb:142-148`) while `driver.rb:192-196` states the rule the other six
break: *"an unattributable bench report is a weak experiment record."* `Altitude#header` also **takes an
argument**, unlike every sibling.

`Arm::Driver` does not use `ArmFold` at all — it reimplements the pairing with `Measured` (`:67-74`),
`Unpriced` (`:82-85`) and `Unmeasured` (`:96-100`), duplicating `ArmFold#row` and `#absent_row`, and
`#table` (`:243`) duplicating `#titled`.

**`DslCatalog` is the roster mechanism, already proven twice.** `lib/lain/dsl_catalog.rb` is **50
lines**; a subclass names exactly two things — a public `DSL_PATH` constant and
`def self.builder = Builder` resolved at call time. Users: `Summarizer::Catalog` (`summarizer.rb:33-57`,
reading a project-level `.lain/summarizers.rb`) and `Isolation::Services`
(`isolation/services.rb:16-24`). `.load` treats an absent file as an **empty** catalog by design, and
the instance is frozen at both levels — *"a session-fixed SNAPSHOT, not a mutable registry."*

**`Arm::Run` carries a bridge no production code crosses — and it is not dead.** `arm.rb:60`'s
`Run = Data.define(:arm, :timeline, :grade, :elapsed, :ledger)` has `#compare_run` at `:63-65`, the bridge
between `Arm::Run` and `Compare::Run`. No `lib/` caller converts: `Arm::Driver` never does, and
`Arm::Epic::Outcome#compare_run` only forwards. But **six spec sites call it** — `spec/lain/arm_spec.rb:45`,
`arm/single_thread_spec.rb:52`, `:84`, `arm/dual_ledger_spec.rb:101`, `arm/orchestrator_worker_spec.rb:147`,
`:155` — and `spec/lain/arm/driver_spec.rb:136` carries a comment saying so in as many words:
*"`#compare_run`, which the Driver never calls."* The tree already knows and keeps it deliberately. It is a
tested public interface with no production consumer, which is a **different finding** from dead code and
gets its own entry in Open decisions rather than a deletion in T7.

**Where docs and code disagreed, and which won.** `ARCHITECTURE.md:885` on four arms — **the CLI wins**
until T3 makes the doc true. `ARCHITECTURE.md:41` claims `crates/lain-core` serves *"the bench
exec-comparison arm"* and there are **zero** `CoreExec`/`Core::Client` references in `bench/` or
`arm/` — noted; wiring that arm is simplify-13's option, not this plan's.
`ARCHITECTURE.md:1035` claims *"`lain bench sweep` walks the words mechanically"* over combinator
generators — `bench sweep` is the retrieval recall@k eval and no command enumerates combinator words.
That claim is **false and this plan does not make it true**. **T3 corrects the sentence**, since it is
already the card that opens `ARCHITECTURE.md` to make `:885`'s four-arm claim true, and a plan that
notices a false claim and leaves it standing has chosen to keep it. simplify-09's T5 reaches the same
conclusion from the other side (*"making it true is a bench feature, not a naming one"*) and defers to
this card — so **exactly one card owns it**, rather than two plans each recording that it is somebody
else's.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lib/lain/bench.rb`,
  `lib/lain/arm.rb`, `lib/lain/oracle.rb`, `exe/lain`, `lain.gemspec`, `.rubocop.yml`,
  **`spec/lain/review/deletability_spec.rb`**.
- **`exe/lain` is unusually contended here.** T3, T5 and T6 each add to the `Bench < Thor` block
  (`:511-674`). The wave assignment keeps them apart; the orchestrator applies each as a wiring diff to
  that one block.
- **`spec/lain/review/deletability_spec.rb` is the second contended file, and it is new.** simplify-03
  landed it (709 lines) as a machine-checked map of what each deferred unit would cost to delete, and its
  examples assert that every unit it lists is still unreferenced and that every path it names still
  exists. **This plan's whole job is making those assertions false.** Three cards edit it, each a
  different row:

  | card | row | what the edit is |
  |---|---|---|
  | **T3** | `adaptive_router` | **removed**, not amended — once the arm is wired it is not a deletable capability, so `KEYS` (`:332`) drops `adaptive_router` and the `ARCHITECTURE.md` marker the row pins (`:307`) must survive on the doc side or go with the row |
  | **T5** | `disclosure_sweep`, `tool_search` | the `files:` paths follow the `git mv` out of `spec/fixtures/`; wiring the sweep gives `ToolSearch` its first caller, so its row's no-reference assertion goes |
  | **T8** | `prune_scoring`, `ladder` | **neither has a row** — see T8; either add them in the established shape or record that these two are removed by hand |

  T3 is wave 1 and T5 is wave 3, so they cannot collide, but the file is orchestrator-owned exactly as
  `lib/lain.rb` is: **wiring diffs only, applied by the orchestrator, never merged by a worker.**
- **Fixtures move from `spec/fixtures/` into `lib/lain/bench/`** in T5, because a subcommand an installed
  gem cannot run is not wired. That is a `git mv` plus a path constant, and the specs that read them
  from `spec/fixtures/` must follow.
- This plan assumes **simplify-01 has landed** for T7, which produces a presenter over the current
  `Metrics/ClassLength`. **It has** — simplify-01 is `status: done`, so this assumption is satisfied
  rather than pending.
- **simplify-03 defers seven units to this plan, and each one has a named owner here** — an earlier
  draft said "T3, T5 and T8 settle them" without saying which settles what, which is how a deferred unit
  becomes an orphan:

  | deferred unit | owner | how it is settled |
  |---|---|---|
  | `arm/adaptive_router.rb`, `oracle/router.rb` | **T3** | wired as the fourth arm, five lines |
  | `Toolset::Disclosure::Upfront`/`Deferred`, `Bench::DisclosureSweep` | **T5** | `disclosure-sweep` gets a door, which makes them reachable |
  | `Tools::ToolSearch` | **T5** | it is `Deferred`'s fetch mechanism, not an independent unit — it lives or dies with the disclosure arm |
  | `oracle/prune_scoring.rb` | **T5** | `decider-sweep` is its only consumer |
  | `Arm::Ladder` | **T8** | three `def rungs` callers, all inside the altitude cluster T8 prices |

  **Do not start 03's T2 expecting those files gone.** simplify-03 is now `status: done` and deleted
  **none** of the seven — it wrote `deletability_spec.rb` against them instead. So every ownership row
  above is live, and T8's "confirm ownership with 03" trigger is closed rather than pending.

## Open decisions

- **The altitude cluster: wire it or retire it.** T9 exists to force the choice and prices both. Wiring
  means building `LiveArms::Seams` — a ten-member value needing `CLI::EpicDriver::Factory`, a mount, a
  chronicle, a skill library and a toolset build — inside `exe/lain`, which `bench/cli.rb:190-195`
  documents as impossible there; realistically +120-180 lines plus relocating four fixture *projects*,
  and `bench/cli.rb:182` warns it *"SPENDS MORE THAN `bench arms` by a wide margin."* Retiring is −442
  lib / −630 spec. **The deciding argument is not cost**: `Arm::Epic` ignores three of four seam
  arguments, so it is a second bench grafted onto the arm vocabulary rather than an arm. T9 recommends
  retire and asks the human to confirm, because it also retires the repo's only ground-truth outcome
  metric (`Grader::LeaseHarness` runs a real suite in a real worktree).
- **`Grader::Rubric`, `Refuter` and `Verified` have zero consumers** (110 lib / 235 spec), while
  `ARCHITECTURE.md:904` and `grader.rb:4-7` both sell Fixture-vs-Rubric as *the* grading axis.
  Either add `--grader rubric` (+~20, making 110 reachable) or delete them and correct both docs.
  **T6 owns this and must land one of the two**, rather than leaving it as a decision no card executes —
  an earlier draft said "not gated on a card", which in this plan's own terms means three files stay
  unreachable while the plan whose subject is reachability ships green. T6 builds `--grader`; wiring
  `rubric` behind it is ~20 lines and is the recommended branch, because the axis the docs advertise
  becoming real is worth more than 345 lines saved.
- **Whether `bench record` should accept the strategy flags.** T2 gives the bench a real harness, at
  which point `--compact-strategy` on `bench record` becomes meaningful — but `CompactionFlags.declare`
  attaches to `chat` only. Out of scope here; recorded so the gap is visible.
- **`Arm::Run#compare_run` is a tested public interface with no production consumer — a finding for a
  later plan, not a deletion in this one.** An earlier draft had T7 delete it as dead code. It is not:
  `arm.rb:63-65` is called from **six spec sites across four files** (`spec/lain/arm_spec.rb:45`,
  `arm/single_thread_spec.rb:52`, `:84`, `arm/dual_ledger_spec.rb:101`,
  `arm/orchestrator_worker_spec.rb:147`, `:155`), and `spec/lain/arm/driver_spec.rb:136` comments
  *"`#compare_run`, which the Driver never calls"* — the tree noticed the gap and kept the bridge on
  purpose. Deleting it reddens ~6 examples in four files that are in no card's Files list, and it is
  unrelated to the presenter collapse T7 exists for. **The real question, for whoever picks it up:** is
  the `Arm::Run` → `Compare::Run` bridge the seam by which arm results should reach the comparison
  vocabulary — in which case `Arm::Driver` should cross it instead of reimplementing the pairing with
  `Measured`/`Unpriced`/`Unmeasured` — or is it a vestigial second path that its own specs are keeping
  alive? Either answer is a change to `Arm::Driver`, so it belongs with T7's subject and not inside it.
  Filed here so it survives this plan.

## Waves

Wave 1: T1, T3, T4
Wave 2: T2 (←T1)
Wave 3: T5 (←T2)
Wave 4: T7 (←T5), T9 (←T5)
Wave 5: T8 (←T5, T9)
Wave 6: T6 (←T5, T8, T9)
Critical path: T1 → T2 → T5 → T9 → T8 → T6

T2 is as early as its file lets it be, because **every number the other cards produce is meaningless
until it lands** — and it is wave 2 rather than wave 1 only because T1 rewrites `bench/cli.rb` under it.

**Three same-wave collisions were serialized here, and one of them the plan's own escalation trigger had
already asked for**: T1 and T2 both edit `bench/cli.rb`; T5 and T7 both edit `bench/decider_sweep.rb`;
and T6, T8 and T9 all edit `bench/live_arms.rb`, with T6 and T9 also sharing `bench/cli.rb`. **T9 now
precedes T8** — T8's trigger says "sequence T9's decision before this card", and the earlier assignment
put them in the same wave, which is the trigger firing on arrival. T6 is last because it is the only
card that has to read what all three of the others decided.

**The 2026-09-13 re-verification changed no wave.** The dependency graph as drawn is still correct against
the tree, and the three serialized same-wave collisions are still real. The grounding refresh the audit
asked for is applied **in place** rather than as a wave-0 commit, because an agent in an isolated worktree
reads this document and not the audit: every stale `ARCHITECTURE.md` and `exe/lain` reference below is
already renumbered. The one addition is `spec/lain/review/deletability_spec.rb`, a fourth shared file — see
the Orchestrator contract for which card owns which row.

## Tasks

### T1 — Put the grade on the experiment record   [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `lib/lain/arm/driver.rb`, `lib/lain/bench/cli.rb`;
modify `spec/lain/arm/driver_spec.rb`
**Reuse:** `Grader::Journaling` (`grader/journaling.rb`, 66 lines, spec 166) is written, spec'd and
unused — its `#grade` `:36-42` already does exactly this
**Shared-file wiring:** none
**Reachable from:** `Arm::Driver#distributions_for` (`arm/driver.rb:152-153`) is on the `bench arms`
path, reached from `exe/lain:629` → `Bench::CLI#arms_report` (`:165`); AC 1 drives `bench arms` end to
end and reads the journal

Three lines. `@grader` (`driver.rb:130`) is passed verbatim into `arm.run(..., grader: @grader)` at
`:153`; decorate it once at construction with `Journaling.new(inner: grader, journal:)`.

**The bench's headline metric currently never lands on the Journal.** `Telemetry::GradeRecord` has one
writer (`journaling.rb:38`) and that writer has no consumer.

`Arm::Instrument` is **not** the place, despite the name — it owns clock and price only
(`instrument.rb:45`, `:58`) and touches no grader.

**Acceptance criteria**

```gherkin
Scenario: a graded arm run writes its score to the journal
  Given an arm run over one task with a journal
  When the driver runs it
  Then the journal holds a grade record naming the score

Scenario: the grade record names its grader and its subject
  Given the same run
  When the grade record is read
  Then it names the grader class
  And it names the subject digest

Scenario: an ungraded run writes no grade record
  Given an arm run with no grader
  When the driver runs it
  Then the journal holds no grade record

Scenario: the reported score is unchanged by journaling
  Given two identical runs, one journaled and one not
  When both are graded
  Then both report the same score
```
→ spec file: `spec/lain/arm/driver_spec.rb`

**Escalation triggers**
- `Journaling#digest_for` (`:49-63`) resolves a subject digest via an injected callable, then
  `subject.digest`, then `Canonical.digest` for a String, then **raises `UndigestableSubject`**. If an
  arm's subject is none of those, wiring this makes a previously-working run raise. Check what
  `Arm::Run#timeline` hands the grader before assuming.
- `LiveArms.build` (`:117-125`) threads **no `grading:`** while `.altitude` (`:93-99`) does. If the
  journaling belongs on the `grading:` seam rather than on the driver's `@grader`, say so — the two are
  different insertion points and only one is on the `bench arms` path.
- `arm/driver.rb:40-49`'s `METRICS` reads `"grader score" => { of: :score }`, i.e. the score is already
  in the report. This card does not change the report; if it does, that is a separate concern.

### T2 — Give the bench a real harness   [wave 2] [risk: high]

**Depends on:** T1
**Files:** modify `lib/lain/bench/cli/run_recorder.rb`, `lib/lain/bench/spawn_seam.rb`,
`lib/lain/bench/cli.rb`; modify `spec/lain/bench/cli_spec.rb`,
`spec/lain/bench/spawn_seam_spec.rb`
**Reuse:** **`CLI::Wiring::BaseTools`** — a module at **`lib/lain/cli/wiring.rb:100`**, not a file of its
own; there is no `cli/wiring/base_tools.rb`. Production builds its toolset at
**`cli/wiring/toolset_build.rb:298`**, as
`Toolset.new(BaseTools.build(recorder, exec:, verdict:, journal:))` — the bench should build one the same
way rather than inventing a second list. `Agent::Instrumentation` is the existing seam for a pipeline
source.
**Shared-file wiring:** none
**Reachable from:** `RunRecorder` is reached from `exe/lain:554` (`bench record`) and `SpawnSeam` from
`:629` (`bench arms`); AC 1 and AC 2 each drive one of those commands

**This is the card the plan exists for.** Both sites construct an `Agent` with `Toolset.new([])` and
neither passes `instrumentation:`, so `PipelineSource::Null` applies. No bench run has ever executed
with tools, a context strategy, or compaction — which means the project's founding thesis, that the
harness sets the score, is untested by the thing built to test it.

Both sites take a real toolset and a real instrumentation. Note the existing asymmetry: `RunRecorder`
wires three middleware stacks plus a `JournalMemoryRoot`; `SpawnSeam` wires none. Make the asymmetry
deliberate or remove it, and say which.

**Two other bench paths carry `Toolset.new([])` and this card deliberately leaves them empty.**
`bench/arm_sweep/recordings.rb:82` and `bench/plan_sweep/driver.rb:87` are **replay** paths — they read a
recorded trajectory back rather than asking a model — and a tool a replayed agent could actually call is
exactly what would make the replay non-deterministic. So they keep an explicit empty toolset, and AC 4
names both so that the exemption is a ruling with a reason and not two sites the card missed. Note the
consequence: `arm_sweep/recordings.rb` is the path **T5 then opens to users**, so the first thing a reader
of `bench arm-sweep` meets is a toolless run — which is correct, and the commit message should say why.

**This card changes what every existing bench number means.** Say so in the commit message, and expect
recorded fixtures to become non-comparable with new runs — which is itself a finding worth recording
rather than papering over.

**Acceptance criteria**

```gherkin
Scenario: a recorded run has tools available
  Given a task file and a recorder
  When one run is recorded
  Then the request the provider saw declared tools

Scenario: an arm run has tools available
  Given an arms fixture
  When one arm runs
  Then the request the provider saw declared tools

Scenario: a recorded run renders through a context pipeline
  Given a recorder built with a pipeline
  When one run is recorded
  Then the journal records which pipeline rendered the request

Scenario: a run with no tools is still possible and named
  Given a recorder explicitly built with an empty toolset
  When one run is recorded
  Then the request declared no tools
  And the journal records that the toolset was empty

Scenario: the replay paths keep their empty toolset deliberately
  Given the arm-sweep recordings replay and the plan-sweep driver
  When each builds its agent
  Then each declares an empty toolset
  And each says in its own comment that replay determinism is why
```
→ spec files: `spec/lain/bench/cli_spec.rb` (AC 1, AC 3, AC 4),
`spec/lain/bench/spawn_seam_spec.rb` (AC 2); AC 5 is verified by reading
`bench/arm_sweep/recordings.rb:82` and `bench/plan_sweep/driver.rb:87`

**Escalation triggers**
- **Grading may break.** `ArmSweep.trajectory` grades by concatenating **assistant text** and parsing
  `FILE/END` blocks, and `exe/lain:585` says the default system prompt teaches that format. Give the
  model real tools and it will use `write_file` instead of emitting prose — **so every existing grader
  may score zero**. That is the defect being exposed, not a regression to work around: stop, report it,
  and let the human decide whether the grader or the prompt changes.
- Real tools mean real filesystem writes. `bench record` and `bench arms` **spend real money** and would
  now also touch disk. Confirm the isolation story (`bench/cli.rb:287-293` already refuses
  `--isolation` without `--journal`) covers a toolset that can write, before running anything live.
- `SpawnSeam:100-104` documents a **dropped `spawned_from:`** keyword. If passing instrumentation makes
  that drop observable — a child whose lineage is now recorded — that is a behaviour change worth its own
  AC.
- **This trigger has already fired.** `Toolset.new([])` *is* load-bearing for the two replay paths —
  `arm_sweep/recordings.rb:82` and `plan_sweep/driver.rb:87` — so they take an explicit empty toolset
  rather than the new default, and AC 5 pins that. What is still open: if a **third** site turns out to
  need one, report it, because two is the measured count and the ruling above is enumerated, not a policy.

### T3 — Wire the fourth arm the architecture already claims ships   [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `lib/lain/bench/live_arms.rb`, `ARCHITECTURE.md`, `exe/lain`;
modify `spec/lain/bench/live_arms_spec.rb`, **`spec/lain/review/deletability_spec.rb`**
**Reuse:** `Arm::AdaptiveRouter` (31 code) already honours the full `#run` seam, and
`Oracle::Router.heuristic` (32 code) already exists to drive it — this is five lines, not a feature
**Shared-file wiring:** none (`live_arms.rb` is task scope; `exe/lain:569`'s `desc` string is a wiring
diff). `spec/lain/review/deletability_spec.rb` is orchestrator-owned — see the contract.
**Also in scope: two false sentences in `ARCHITECTURE.md`.** `:885` claims four arms ship and becomes
true when this card lands. `:1035` claims `bench sweep` *"walks the words mechanically"* over combinator
generators, which no command does — that one is corrected, not made true, and the honest replacement says
what `bench sweep` actually is (the retrieval recall@k eval). simplify-09's T5 defers this sentence here.

**Reachable from:** `LiveArms.build` (`:117-125`) is called from `Bench::CLI#arms_report` (`:165`),
reached from `exe/lain:629`; AC 1 drives `bench arms` and reads the arm names

One line in `LiveArms.build` makes 63 code lines reachable and takes `bench arms` from three
orchestration topologies to four. **Highest ratio in the whole audit.**

Then correct the doc: `ARCHITECTURE.md:885` claims *"Four arms ship
(`arm/{single_thread,orchestrator_worker,dual_ledger,adaptive_router}.rb`)"* — after this card it is
true. And `exe/lain:569`'s `desc` says *"the three orchestration arms"* — update it to four.

**simplify-03 defers these two files to this card.** If this plan is declined, 03's T2 should grow by two
files rather than leaving them unreachable.

**Third file, and it is the one nothing warned about.** simplify-03 landed
`spec/lain/review/deletability_spec.rb`, whose `adaptive_router` row asserts that **no file outside the
row names `AdaptiveRouter` or `Oracle::Router` in code**. Wiring `live_arms.rb` makes that assertion
false. The row is therefore **removed, not amended** — a wired arm is not a deletable capability — and
`KEYS` (`:332`) drops `adaptive_router` with it. Mind the one thing the row was also doing: its `edits:`
pin the literal `arm/{single_thread,orchestrator_worker,dual_ledger,adaptive_router}.rb` marker into
`ARCHITECTURE.md` (`:307`), which is the same sentence this card is making true. Either that marker
survives on the doc side unpinned, or it goes with the row — say which, because losing both silently is
how the four-arm claim drifts again.

**Acceptance criteria**

```gherkin
Scenario: the arms comparison runs four topologies
  Given an arms fixture
  When the arms report is built
  Then it names four arms
  And the adaptive router is among them

Scenario: the router chooses a topology per task
  Given two tasks of different shapes
  When the adaptive router runs each
  Then its choice is recorded per task

Scenario: the control arm is still first
  Given the arms report
  When its arms are listed in order
  Then single-thread is first

Scenario: the architecture document and the CLI agree on the count
  When the architecture document's arm list and the CLI's description are read
  Then both name four orchestration arms
```
→ spec file: `spec/lain/bench/live_arms_spec.rb` (AC 1-3); AC 4 is a documentation assertion verified by
reading, and `spec/lain/review/deletability_spec.rb` must be green with the `adaptive_router` row gone

**Escalation triggers**
- `LiveArms.build` shares **one `Arm::Instrument`** (`:121`) across its arms, with the comment at
  `:118-120` saying *"the comparison is only a comparison if the measuring is shared."* The fourth arm must take the
  same instrument, not build its own.
- `AdaptiveRouter` consumes `Oracle::Router`, whose `.definition` content-addresses template, schema and
  tier. If the oracle's digest differs from what any recorded fixture expects, the arm's answers will not
  replay — check before wiring, because a silently-unreplayable arm is worse than an unwired one.
- `Seams` (`live_arms.rb:70-80`) defaults `grading:` to **nil** because *"`bench` loads BEFORE `arm` and
  `grader`."* If the fourth arm needs a grading default, that load-order workaround bites — and the real
  fix is the `bench/session` → `SessionRecord` merge, which is not this card.
- If `bench arms` now costs 4/3 of what it did, say so. It spends real money per invocation.

### T4 — Let the comparability guard fire   [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `lib/lain/compare.rb`, `lib/lain/bench/variance.rb`, `lib/lain/arm.rb`;
modify `spec/lain/compare_spec.rb`; **create** `spec/lain/compare/posture_spec.rb`
**Reuse:** `Compare::Posture.from_journal` (`compare/posture.rb:117`) and `.guard!` (`:147`) are
written and unreached; `Compare#guard_postures!` (`compare.rb:156-157`) already calls them
**Shared-file wiring:** none
**Reachable from:** `Compare#report` is reached from `Bench::CLI#variance_report` (`:40`), i.e.
`exe/lain:520`; AC 1 drives `bench variance` over two journals recorded under different postures

**No caller anywhere passes `posture:`**, so `guard_postures!` is permanently in its UNRECORDED branch
and a 62-line guard can never fire. Thread the posture from the journal into `Compare::Run`.

Preserve the `combination(2)` choice at `compare.rb:157` — `:153-155` argues that posture agreement
is **not transitive**, so pairwise is correct and `each_cons(2)` would be wrong.

**`spec/lain/compare/posture_spec.rb` does not exist — this card creates it.** `spec/lain/compare/` holds
only `arm_fold_spec.rb` and `table_spec.rb`; `Posture`'s coverage currently lives inside
`spec/lain/compare_spec.rb` as a nested `describe Lain::Compare::Posture` at `:293`. CLAUDE.md wants one
spec file per public entry point at its mirrored path, so that coverage **moves** to the new file rather
than being duplicated into it — a `Posture` assertion left behind in `compare_spec.rb` is the same
sentence owned twice, which is the defect the mirror rule exists to prevent.

**Acceptance criteria**

```gherkin
Scenario: comparing two runs under different postures is refused
  Given one run recorded under plan mode and one under auto mode
  When they are compared
  Then it refuses, naming both postures

Scenario: comparing two runs under one posture proceeds
  Given two runs recorded under the same posture
  When they are compared
  Then the comparison is reported

Scenario: a run whose posture was not recorded is reported as unrecorded
  Given a journal with no posture record
  When it is compared with another
  Then the report says the posture was unrecorded

Scenario: three runs are checked pairwise, not in sequence
  Given three runs where the first and third disagree but neither disagrees with the second
  When they are compared
  Then it refuses
```
→ spec files: `spec/lain/compare_spec.rb` (AC 1, AC 2, AC 4),
`spec/lain/compare/posture_spec.rb` (AC 3)

**Escalation triggers**
- `Compare#guard_degraded!` (`compare.rb:146`) defaults `degraded:` to an **empty set**, so a caller
  who forgets to thread it gets a vacuous pass — the same defect this card fixes for posture. If the
  honest fix threads both, say so and widen the card rather than fixing one and leaving its twin.
- AC 4 exists because `combination(2)` versus `each_cons(2)` is the difference between catching and
  missing the first-versus-third case. If a test passes under both, it is not testing the distinction.
- `Compare::Run.from_timeline` (`compare.rb:39-42`) takes **live in-memory objects**, not a journal. If
  posture must come from a journal, `Compare` gains a second construction path — report that rather than
  giving `from_timeline` a posture it cannot know.

### T5 — Give three written experiments a door   [wave 3] [risk: medium]

**Depends on:** T2
**Files:** modify `exe/lain`, `lib/lain/bench/cli.rb`; `git mv` the four fixture sets from
`spec/fixtures/` into `lib/lain/bench/fixtures/`; modify `lib/lain/bench/arm_sweep.rb`,
`bench/decider_sweep.rb`, `bench/disclosure_sweep.rb`, and the four spec files that read those paths;
modify **`spec/lain/review/deletability_spec.rb`**
**Reuse:** `Bench::CLI#arm_sweep_report` (`:65`) already has the signature (`tasks_path:`,
`recordings_path:`); `DeciderSweep` and `DisclosureSweep` are both written and spec'd, each with its own
`#report`. `bench sweep` is the model — the one subcommand that is self-contained because it ships its
corpus under `lib/lain/bench/corpus/`.
**Shared-file wiring:** three `desc`/`method_option`/`def` groups added to `exe/lain`'s
`Bench < Thor` block (`:511-674`), and the registration `desc` at `:691-693` updated to name them.
`spec/lain/review/deletability_spec.rb` is orchestrator-owned — see the contract.
**Reachable from:** each new subcommand *is* the production path; AC 1-3 each invoke one through
`exe/lain`

Three subcommands: `arm-sweep`, `decider-sweep`, `disclosure-sweep`.

**But only ONE of the three methods exists.** `arm_sweep_report` is a `Bench::CLI` method (`:65`) that
needs nothing but a door. There is **no `decider_sweep_report` and no `disclosure_sweep_report`** —
`Bench::DeciderSweep` and `Bench::DisclosureSweep` are standalone classes carrying their own `#report`,
so this card **writes two new `Bench::CLI` methods** in front of them before it writes three `desc`
blocks. That is the difference between three wiring lines and two new library entry points, and it is
where the card's real risk sits: each new method is the first argv-shaped signature those classes have
ever had, and `Bench::CLI` is where the refusals (`Bench::CLI::Refusal`, the fixture-path resolution)
belong rather than in the sweep classes. All three are spec'd and have committed fixtures.

**The fixtures must move.** They live under `spec/fixtures/`, which an installed gem does not ship, so a
subcommand reading them is not wired even with a door. `bench sweep` already does this correctly with
`lib/lain/bench/corpus/`. **Packaging needs no gemspec change:** `lain.gemspec:34-39` builds `spec.files`
from `git ls-files` minus a reject list (`bin/`, `Gemfile`, `.gitignore`, `.rspec`, `spec/`, `.github/`,
`.rubocop.yml`), so a YAML file committed under `lib/` ships automatically and AC 4 passes on the move
alone.

**The move reddens simplify-03's deletability map.** `spec/lain/review/deletability_spec.rb`'s
`disclosure_sweep` row lists `spec/fixtures/bench/disclosure/{tasks,malformed,malformed_tool,missing_recorded_arm}.yml`
in its `files:`, and the map's own examples assert that every path it names exists — so those entries
follow the `git mv`. The `tool_search` row goes further: wiring `disclosure-sweep` gives `ToolSearch` its
first caller, which is exactly what its no-reference assertion forbids.

**Two of these settle deferred questions.** `disclosure-sweep` is the **only** consumer of
`Toolset::Disclosure::Upfront`/`Deferred` (`bench/disclosure_sweep.rb:43`'s `ARMS`), which simplify-03
defers to this plan — wiring it keeps them; declining means 03 deletes them. `decider-sweep` is the
**only** place oracle tiers are compared against each other, which is the entire justification for the
`Heuristic`/`Model`/`Recorded` split, and its only consumer of `Oracle::PruneScoring`.

**`Tools::ToolSearch` rides on the first of those** and the card should say so in its commit message.
It is 49 code lines with 82 of spec and **no caller anywhere** — `lib/lain/tools.rb:27` requires it and
four comments reference it (`tool.rb:69`, `toolset/disclosure/deferred.rb:8`, `:11`, `:23`,
`bench/disclosure_sweep.rb:103`). Those comments are the reason it is not independently deletable: it is
the one-tool-at-a-time fetch a **deferred**-disclosure agent makes, so it is the other half of the arm
this subcommand runs. Wiring `disclosure-sweep` gives it its first caller; declining the arm is what
makes 03 free to delete it. Either way it is not a separate decision, and 03's Open decision should be
read as covering it.

**Note what `disclosure-sweep` will show.** `Toolset::Disclosure::Upfront#render` is literally
`toolset.to_schema` — the "upfront arm" is a no-op wrapper around what production already does
unconditionally, and `Context#render` calls `toolset.to_schema` directly (`context.rb:124`), so there is
**no `disclosure:` seam** to vary. Wiring the sweep makes the arm runnable; making it *meaningful* needs
a seam in `Context`, which is not this card. Say so rather than implying the axis is now comparable.

**Acceptance criteria**

```gherkin
Scenario: the arm sweep runs offline and deterministically
  Given no network access
  When the arm sweep subcommand is invoked
  Then a report is produced
  And invoking it twice produces the same report

Scenario: the decider sweep compares oracle tiers
  Given the decider fixture
  When the decider sweep subcommand is invoked
  Then the report names each oracle tier

Scenario: the disclosure sweep runs its two arms
  Given the disclosure fixture
  When the disclosure sweep subcommand is invoked
  Then the report names both disclosure arms

Scenario: every bench subcommand runs from an installed gem
  Given the gem's shipped files
  When each bench subcommand's fixture path is resolved
  Then each resolves inside the gem
```
→ spec files: `spec/lain/bench/{arm_sweep,decider_sweep,disclosure_sweep}_spec.rb` (AC 1-3),
`spec/lain_spec.rb` or the gemspec spec (AC 4), plus `spec/lain/review/deletability_spec.rb` green with
the repathed rows

**Escalation triggers**
- **`Bench::CLI#arm_sweep_report` has no caller anywhere, including specs.** So it is written but never
  executed. If invoking it raises, that is the first execution it has ever had — expect it, and report
  what broke rather than assuming the door is the only missing piece.
- **The gemspec trigger is struck**, not deferred: `lain.gemspec:34-39` is `git ls-files` minus a reject
  list rather than a `lib/**/*.rb` glob, so committed YAML under `lib/` ships with no gemspec edit. Left
  standing it would have sent an agent to re-investigate a settled question.
- `spec/fixtures/altitude/subjects/` holds four **project trees** with `Gemfile`s. If T9 retires
  altitude, those do not move; if it wires it, they must — sequence T9's decision before moving
  altitude's fixtures, and this card moves only the other three sets.
- `disclosure_sweep.rb` reads a bare `recorded:` YAML field with no replay object. If that shape cannot
  produce a deterministic run, the door exposes a half-built experiment — report it as a finding rather
  than fixing the fixture format here.

### T6 — A project-extensible arm roster and a `--grader` flag   [wave 6] [risk: medium]

**Depends on:** T5, T8, T9
**Files:** create `lib/lain/arm/catalog.rb`, `spec/lain/arm/catalog_spec.rb`; modify
`lib/lain/bench/live_arms.rb`, `lib/lain/bench/cli.rb`, `exe/lain`
**Reuse:** **`Lain::DslCatalog`** (`lib/lain/dsl_catalog.rb`, 50 lines) — a subclass names exactly two
things, a public `DSL_PATH` and `def self.builder = Builder`. `Summarizer::Catalog`
(`summarizer.rb:33-57`) is the working precedent for a project-level `.lain/*.rb` extending lain without
touching lain.
**Shared-file wiring:** `require_relative "arm/catalog"` in `lib/lain/arm.rb`; `--arms` and `--grader`
`method_option`s on the relevant `Bench < Thor` commands in `exe/lain`
**Reachable from:** `Arm::Catalog.load` is called from `Bench::CLI#arms_report` (`:165`) in place of the
hardcoded `LiveArms.build`; AC 1 drives `bench arms --arms` through `exe/lain`

Today every roster is a hardcoded literal in the sweep that owns it — `LiveArms.build:122-124`,
`DisclosureSweep::ARMS`, `DeciderSweep`'s string keys, `Sweep`'s five `#search` ducks,
`PlanSweep::Arm` values. **None is registrable.** So "comparable" currently means "somebody authored a
Ruby file for this comparison", which is why there are five sweep classes.

`Arm::Catalog < DslCatalog` plus `--arms a,b,c` and `--grader NAME` converts *edit `live_arms.rb` and
ship a new sweep class* into *write `.lain/arms.rb`*.

Keep `DslCatalog`'s two properties: an absent file is an **empty** catalog, never an error, and the
loaded catalog is **frozen at both levels** — a session-fixed snapshot, not a registry something can
register into after load.

**`--grader` settles the `Grader::Rubric` decision, and this card executes it** (see Open decisions).
Once the flag exists, wiring `Rubric`, `Refuter` and `Verified` behind `--grader rubric` is ~20 lines and
makes 110 unreachable lib lines reachable — which is what `ARCHITECTURE.md:904` and `grader.rb:4-7`
already claim is true. Recommended branch: **wire them.** If the card takes the other branch it deletes
all three and corrects both documents in the same commit; what it may not do is leave them as they are,
because then nothing in the series ever reaches them.

**Acceptance criteria**

```gherkin
Scenario: the default roster is the built-in arms
  Given no project arms file
  When the arms report is built
  Then the built-in arms run

Scenario: a project declares an extra arm
  Given a project arms file declaring one arm
  When the arms report is built
  Then that arm runs alongside the built-ins

Scenario: naming a subset runs only those arms
  Given a roster of four arms
  When two are named
  Then only those two run

Scenario: naming an arm that does not exist is refused
  Given a roster of four arms
  When an unknown arm is named
  Then it is refused
  And the refusal lists the arms that exist
```
→ spec file: `spec/lain/arm/catalog_spec.rb` (AC 1-4), with AC 3 also driven through
`spec/lain/bench/cli_spec.rb`

**Escalation triggers**
- `DslCatalog.load` takes `root:` explicitly and *"never read at require time"*. If `Arm::Catalog` needs
  a root at class-body time, it is not this shape — and `Seams`' load-order workaround
  (`live_arms.rb:70-80`) is the warning that `bench` loads before `arm`.
- A project-declared arm runs **arbitrary project code** inside the bench. `Isolation::Services` already
  accepts that for compose files, so the precedent exists — but say it out loud, because a bench that
  executes `.lain/arms.rb` is a different trust posture from one that does not.
- `--arms` naming a subset changes what the **control** is. `LiveArms.build:118`'s comment makes
  single-thread the control deliberately; a subset that omits it produces a comparison with no baseline.
  Refuse that, or warn.
- If `--grader` cannot name `Grader::Fixture` and `Grader::Recall` uniformly — one takes gold files, the
  other a corpus — the flag is two flags. Report rather than forcing one name.

### T7 — One report presenter, and attribution that cannot be omitted   [wave 4] [risk: medium]

**Depends on:** T5
**Files:** create `lib/lain/compare/sheet.rb`, `lib/lain/compare/metric.rb`,
`spec/lain/compare/sheet_spec.rb`; modify `lib/lain/compare.rb`,
`lib/lain/compare/arm_fold.rb`, `lib/lain/arm/driver.rb`,
`lib/lain/bench/arm_sweep/report.rb`, `bench/plan_sweep/report.rb`, `bench/altitude.rb`,
`bench/decider_sweep.rb`, `bench/sweep.rb`, **`lib/lain/bench/variance.rb`**,
**`lib/lain/bench/disclosure_sweep.rb`**
**Reuse:** `Compare::ArmFold` is already constructed **six times**, so the fold is adopted — this card
makes `#titled` public and adds the header. `Compare::Table` (39 lines) is already public and was
rewritten by nobody, which is the evidence for the approach.
**Shared-file wiring:** two manifest lines in `lib/lain/compare.rb`'s require block
**Reachable from:** every bench report renders through this; AC 1 drives `bench arms`' report and AC 3
`bench variance`'s

Three collapses:

1. **`#titled` becomes public.** It is `private` at `arm_fold.rb:83`, which is why `altitude.rb:215`,
   `decider_sweep.rb:128` and `arm/driver.rb:243` each hand-rolled it while nobody rewrote the public
   `Compare::Table`. **Visibility, not call-site count, predicted the clone** — that is the lesson and it
   belongs in the commit message.
2. **One `Compare::Sheet`** owning the report skeleton: header with **mandatory** attribution, notes,
   metric sections, absent-metric marking, per-case appendix. **Eight** bespoke `#header` methods
   collapse — `sweep.rb:247`, `plan_sweep/report.rb:79`, `altitude.rb:142`, `arm_sweep/report.rb:100`,
   `decider_sweep.rb:113`, `arm/driver.rb:197`, `variance.rb:54` and `disclosure_sweep.rb:168` — and the
   three byte-identical `#pluralize` copies go. Note `Altitude#header` **takes an argument** — that is a
   real difference and the presenter must accommodate it or Altitude keeps its own.
3. **One `Compare::Metric`** replacing five registries in three shapes: `Compare::METRICS`
   (`{label:, reader:, fmt:}`), and four in `{of:, fmt:}` of which Altitude's adds `needs:`.
   `arm/driver.rb:22-28` already books this with a stale count of "four".

   **The five are at three visibilities, and that decides how far the collapse can go.**
   `Compare::METRICS` is public; `Arm::Driver::METRICS` is **`private_constant`** (`driver.rb:50`), an
   explicit statement that it is not part of any shared interface; the other three are module-scoped and
   neither. So this is not "make five things one public thing" — `Arm::Driver` either keeps a sealed
   registry that *consumes* `Compare::Metric` without exporting it, or the card argues the seal away in
   its commit message. Silently promoting a `private_constant` to public is a public-interface change
   nobody asked for.

**Attribution is the correctness half.** `driver.rb:192-196` states the rule — *"an unattributable bench
report is a weak experiment record"* — and only two of eight reports follow it (`arm/driver.rb:197-202`
and `altitude.rb:142-148`). Making it a required constructor argument on `Sheet` means a report
**cannot** be built without naming its fixture and model.

**`Arm::Run#compare_run` is NOT deleted here.** An earlier draft had this card remove it as a callerless
bridge. It has six spec callers across four files and a comment at `spec/lain/arm/driver_spec.rb:136`
saying the Driver deliberately never calls it — see Open decisions, where the real question is filed for a
later plan. It is unrelated to the presenter collapse, and its four spec files are not in this card's
Files list.

**Acceptance criteria**

```gherkin
Scenario: a report cannot be built without attribution
  When a sheet is built with no fixture and no model
  Then it is refused

Scenario: every report names what produced it
  Given each bench report
  When its header is read
  Then it names the fixture and the model

Scenario: an absent metric is marked, not fabricated
  Given a run for which one metric was not measured
  When the report is rendered
  Then that cell says the metric was not measured

Scenario: two reports render one metric identically
  Given the same score in two different reports
  When both are rendered
  Then the score is formatted the same way
```
→ spec file: `spec/lain/compare/sheet_spec.rb` (AC 1, AC 3, AC 4), plus each report's own spec for AC 2

**Escalation triggers**
- `Arm::Driver` does **not** use `ArmFold` — it reimplements the pairing with `Measured`, `Unpriced` and
  `Unmeasured` (`:67-100`) plus its own `#table` (`:243`). Folding it in is the largest part of this card;
  if `Unpriced` encodes a distinction `ArmFold#absent_row` cannot make (a run that ran but could not be
  priced, versus one that did not run), **keep it** and say so — `ArmFold`'s documented contract is
  "mark absent, never fabricate", and losing the three-way distinction would be a regression.
- `Altitude::METRICS`' `needs:` key gates a metric on a field's presence. If `Compare::Metric` cannot
  express that, Altitude keeps its own registry — and if T9 retires altitude, the question disappears.
  Sequence accordingly.
- `Compare::METRICS` is **public** and its `{label:, reader:, fmt:}` shape may be read from outside
  `compare/`. Changing it is a public-interface change; grep before assuming it is internal.
- `decider_sweep.rb` has **no `METRICS`** — it delegates to `Compare.new(ranked_runs).report` and
  inherits `Compare::METRICS`. That is already the right shape; do not give it a registry to be
  consistent.

### T8 — Settle the three arm files the deletions deferred   [wave 5] [risk: low]

**Depends on:** T5, T9
**Files:** depends on the decision — either modify `lib/lain/bench/live_arms.rb` and `exe/lain`, or
delete `lib/lain/arm/ladder.rb`, `lib/lain/bench/speculative.rb`,
`lib/lain/oracle/prune_scoring.rb` and their spec files, plus the three `def rungs` in
`lib/lain/arm/{epic,one_shot,plan_only}.rb`
**Reuse:** whichever way it goes, the decision is already framed — T5's doors determine it
**Shared-file wiring:** remove `require_relative` at `lib/lain/arm.rb:162` (ladder),
`lib/lain/bench.rb:14` (speculative), `lib/lain/oracle.rb:9` (prune_scoring) **if retiring**; plus
whatever rows this card decides to add to **`spec/lain/review/deletability_spec.rb`** (orchestrator-owned)
**Reachable from:** if wired, each becomes reachable from its subcommand; if retired, the check is that
nothing broke. AC 1 covers both branches.

Three units simplify-03 deferred here, each settled by whether T5 built a door:

- **`Arm::Ladder`** (13 code) — its sole purpose is `#rungs` on OneShot/PlanOnly/Epic
  (`one_shot.rb:48`, `plan_only.rb:73`, `epic.rb:117`), and **`.rungs` has zero callers in `lib/` or
  `exe/`**. It is dead *inside* the orphan cluster. Retiring it deletes three `def rungs` and three
  `ENTRY` constants with it. **Retire regardless of T5** — a door for altitude would use the arms, not
  their rungs.
- **`Bench::Speculative`** (25 code) — beam search, no CLI, no arm, and presented at
  `ARCHITECTURE.md:913` as shipped. **Retire and correct the doc.**
- **`Oracle::PruneScoring`** (26 code) — consumed **only** by `DeciderSweep::Arms`
  (`bench/decider_sweep/arms.rb:108`, `:110`). If T5 wired `decider-sweep`, it is now reachable and
  stays. If T5 was declined, it goes with the sweep.

**These two have no removal map, unlike their five siblings.** simplify-03 gave four of its seven
deferred units machine-checked rows in `spec/lain/review/deletability_spec.rb`
(`disclosure`, `tool_search`, `disclosure_sweep`, `adaptive_router`) — but **`oracle/prune_scoring.rb` and
`Arm::Ladder` got none.** So this card's two retire-regardless items are precisely the two with no spec
telling it what edits a deletion entails. Either **add rows in the established shape** — cheap, and it
makes the deletion mechanically checked the way the others are — or say explicitly in the commit message
that these two were removed by hand and what was grepped instead. What this card may not do is delete
them as if a map had covered them.

**Acceptance criteria**

```gherkin
Scenario: no arm advertises a rung ladder nothing reads
  When the arms are asked for their interfaces
  Then none exposes a rung ladder

Scenario: the architecture document names no unshipped speculative arm
  When the architecture document is read
  Then it names no speculative arm

Scenario: the oracle pruning heuristic is reachable or absent
  When the oracle's constants are enumerated
  Then the pruning heuristic is either reachable from a subcommand or not defined

Scenario: every remaining arm still runs
  Given the arms fixture
  When the arms report is built
  Then every arm in the roster produced a run
```
→ spec files: `spec/lain/bench/live_arms_spec.rb` (AC 1, AC 4), plus AC 2 verified by reading and AC 3 by
enumeration

**Escalation triggers**
- `Arm::Ladder` is referenced in **comments** at `bench/altitude.rb:8`, `bench/live_arms.rb:83` and
  `bench/cli.rb:179`. Those explain the altitude design; deleting the class without rewriting them leaves
  three comments describing a class that does not exist.
- If T9 wires altitude, `#rungs` acquires a caller and this card's first item inverts. **Sequence T9's
  decision before this card**, or make it conditional and say which branch was taken. **Already
  honoured** — T9 is wave 4 and this card is wave 5.
- **The ownership trigger is closed.** `oracle/prune_scoring.rb` was one of the units simplify-03
  deferred, and 03 is now `status: done` having deleted **none** of the seven. So T8 unambiguously owns
  it, and `Arm::Ladder` with it; there is no second claimant to confirm against.

### T9 — Decide the altitude cluster   [wave 4] [risk: medium]

**Depends on:** T5
**Files:** if retiring: delete `lib/lain/bench/altitude.rb`, `bench/altitude/suite.rb`,
`bench/altitude/subject.rb`, `lib/lain/arm/one_shot.rb`, `arm/plan_only.rb`, `arm/epic.rb`,
`lib/lain/bench/epic_metrics.rb`, `lib/lain/grader/lease_harness.rb`, their spec files, and
`spec/fixtures/altitude/`; modify `lib/lain/bench/cli.rb`, `lib/lain/bench/live_arms.rb`,
`ARCHITECTURE.md`, `ROADMAP.md`. If wiring: modify `exe/lain`, `lib/lain/bench/cli.rb`,
`lib/lain/bench/live_arms.rb` and move the fixtures.
**Reuse:** `Bench::CLI#altitude_report` (`:216`) already has the full signature and is spec'd at six
sites in `cli_spec.rb`
**Shared-file wiring:** either a `desc` block in `exe/lain`'s `Bench` class, or four
`require_relative` removals across `lib/lain/bench.rb` and `lib/lain/arm.rb`
**Reachable from:** if wired, `exe/lain`'s new `altitude` subcommand; if retired, the check is that
`bench arms` still runs. AC 1 covers both branches.

**The decision, with both prices.** Wiring means building `LiveArms::Seams` — a ten-member value needing
`CLI::EpicDriver::Factory`, a mount, a chronicle, a skill library and a toolset build — inside
`exe/lain`, which `bench/cli.rb:190-195` documents as impossible there. Realistically **+120-180 lines**
plus relocating four fixture *projects* (each with a `Gemfile`), and `bench/cli.rb:182` warns it
**"SPENDS MORE THAN `bench arms` by a wide margin."** Retiring is **−442 lib / −630 spec**.

**The deciding argument is not cost.** `arm/epic.rb:134` accepts and **ignores** `spawn_seam:`,
`grader:` and `grading:` under a `Lint/UnusedMethodArgument` disable, with `:121-133` explaining that
this topology's agents are spawned and graded by the driver's own issue actors. A nine-method `Outcome`
forwarder (`epic.rb:41-50`) wraps the `Run` it cannot build honestly. **An arm that discards three
quarters of the seam is not on the seam** — it is a second bench grafted onto the arm vocabulary.

**Recommendation: retire, and say what is lost.** `Grader::LeaseHarness` runs a real test suite in a
real worktree — **the only ground-truth outcome metric in the repo**. Everything else grades assistant
text. If the decomposition-crossover question matters, it deserves its own driver rather than an arm
that lies about its interface.

Note also that every bench commit since 2026-08-27 touches `altitude`, `arm/epic`, `arm/ladder`,
`epic_metrics` and `grader/lease_harness` — all landing doorless. That is the pattern the decision ends
either way.

**Acceptance criteria**

```gherkin
Scenario: the arms comparison is unaffected
  Given the arms fixture
  When the arms report is built
  Then it runs and reports

Scenario: the altitude experiment is reachable or absent
  When the bench subcommands are listed
  Then altitude is either among them or named nowhere in the documentation

Scenario: no document claims an experiment that cannot be run
  When the architecture document and the roadmap are read
  Then every bench experiment they name has a subcommand

Scenario: the ground-truth grader is reachable or its loss is recorded
  When the graders are enumerated
  Then the lease harness is either reachable or recorded as removed with its reason
```
→ spec files: `spec/lain/bench/live_arms_spec.rb` (AC 1), `spec/lain/bench/cli_spec.rb` (AC 2, AC 4);
AC 3 verified by reading

**Escalation triggers**
- **`spec/lain/bench/cli_spec.rb` calls `altitude_report` at six sites** (`:333`, `:409-410`, `:432`,
  `:445`, `:456`, `:463`). Retiring deletes those; if any of the six asserts something about the *arm
  seam* rather than about altitude, that assertion is coverage of `Arm` and must survive elsewhere.
- `arm/one_shot.rb` and `arm/plan_only.rb` are on the retire list, and `plan_only.rb:137` is still
  literally `Lain::CLI::EpicDriver::PlanSubject.read(...)` — the **external caller** simplify-04's T3
  relied on to justify keeping that file. **simplify-04 is `status: done`**, so this is no longer a
  handoff to a plan in flight; it is a **correction filed against a landed one**, and a correction with
  no destination evaporates. Where it goes: a line appended to
  `planning/specs/simplify-04-unshard-cop-splits.md`'s Open decisions naming this card as what removed 04's last external
  caller, **and** a `ROADMAP.md` entry alongside item 46's discharge — the plan doc so a reader of 04's
  reasoning finds the amendment, the roadmap so the follow-up is enumerated where follow-ups live.
  Record both in the commit message.
- `ROADMAP.md` item 46 — *"Follow-ups from the epic-loop chunk (2026-09-11)"* — says plainly at
  `:1774-1775` that *"nothing runs them from a command line."* Whichever way this goes, that item is
  discharged and should be marked so — an open roadmap item describing a settled decision is the
  stale-enumeration failure again.
- If the human chooses **wire**, `bench/cli.rb:190-195`'s claim that the seam cannot be built in
  `exe/lain` must be tested before committing to +180 lines. Build `Seams` in a spike first and report
  the real number.

## Integration checks

After the last wave:

- `bundle exec rake pspec` green, **with the example count recorded**. T8 and T9 may delete a great deal;
  write the arithmetic.
- `bundle exec rubocop` clean, **and `arm/epic.rb`'s `Lint/UnusedMethodArgument` disable gone** if T9
  retired it. That disable is the plan's best single piece of evidence and its removal is the proof.
- **`bundle exec rspec spec/lain/bench spec/lain/arm spec/lain/compare spec/lain/grader`** as a focused
  bench run.
- **Every bench subcommand invoked offline.** `lain bench sweep -k 5`, `lain bench variance <dir>`,
  `lain bench plan-sweep --plan ... --runs ...`, plus the three T5 added. `arm_sweep_report` has
  **never been executed by anything**, so its first run is here.
- **`lain bench arms` against a live model, once, with a journal** — and then read the journal for a
  `grade_record`. T1's whole deliverable is that record existing, and only a live run proves the wiring
  reaches it. This spends real money; budget for exactly one.
- **Read one bench report end to end.** T7 makes attribution mandatory and T2 changes what every number
  means. A report that renders is not a report that says something true.
- **Manual, human:** confirm with the T2 change in place that a bench run actually calls a tool — read the
  journal for a `tool_use`. If it does not, the harness is still off and the plan's premise is unmet.
- Update `planning/qa/scenarios/` — three new subcommands, a fourth arm, and possibly a retired
  experiment. `planning/qa/README.md` names which scenario answers which question, and this plan changes
  several answers.
