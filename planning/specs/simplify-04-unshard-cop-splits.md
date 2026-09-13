# Simplify 04 — fold back the collaborators a counter asked for

status: done
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

Thirty-one files in `lib/` reopen their own class mid-file, and sixty-one comments across fifty-one
files name a `Metrics/*` cop as the reason code is shaped as it is. Several of those extractions say
outright that they bought nothing — one records that promoting a class to its own file *"bought ~1
line against the thirty-four it occupies in a reader's scroll"*. With the limits raised in
simplify-01, the reason is gone and the collaborators can go home.

This plan folds back only the extractions whose stated justification was a counter. Where an
extraction has a real second responsibility, it stays, and the card says so.

Delivers: `cli/wiring/` from eight files to three; `cli/up/`'s two spec-less children folded in;
`epic_driver/`'s empty index removed and its 852 lines collapsed; the four epic commands merged; ten
REPL command classes in one file; the approval micro-objects folded into `Gate`;
`Agent::Collaborators` and `Instrumentation` back in `Agent`; `Session::Journaled` back in `Session`;
the two Ollama deployments as one value; `ask_human`'s two shards folded; and `Supervisor::Retirement`
and `Subagent::Leases` moved to the subsystems they belong to.

## Grounding

Verified 2026-09-12 against the working tree at `d2bb133c`. `code` is non-blank, non-comment.

**The idiom, and its own admissions.** The stock sentence originates at `frontend/tty.rb:371-373` —
*"Reopened rather than nested in TTY's own class body — the shutdown.rb idiom, which keeps each body
within Metrics/ClassLength instead of loosening it"* — and thirteen files carry a variant.
`cli/wiring.rb:22-36` is a fifteen-line confession naming the extraction order and recording that
`Wiring` *"has spent five extractions reaching"* its budget. `cli/wiring/agent_build.rb:132-138`
states the mechanism for whoever hits it next: *"a NESTED class or module costs the enclosing class
only ONE line toward the cop, which is what makes {Wiring::Askers}' shape the in-file escape hatch."*
`cli/command/surface.rb:8` is blunter: *"(the Metrics trip said so: extract, do not loosen)"*.

**`cli/wiring/` — eight files, 375 code lines, and three of them have no spec of their own:**

| file | code | defs | own spec | production construction |
|---|---|---|---|---|
| `agent_build.rb` | 45 | 6 | yes (566) | `wiring.rb:303`, `:350` |
| `askers.rb` | 41 | 6 | **none** | `wiring.rb:316` |
| `base_tools.rb` | 18 | 1 | yes (98) | `wiring/toolset_build.rb:346` |
| `board_build.rb` | 69 | 11 | yes (675) | `wiring.rb:419`, `:438` |
| `epic_seat.rb` | 23 | 3 | yes (61) | `wiring.rb:383` |
| `handback.rb` | 32 | 5 | yes (57) | `wiring.rb:377` |
| `run_state.rb` | 15 | 1 | **none** | `wiring.rb:165` |
| `toolset_build.rb` | 132 | 28 | yes (1043) | `wiring.rb:350` |

Six of the eight are constructed **only from `wiring.rb`**. `toolset_build.rb` has three further
callers in `cli/epic_driver/factory.rb` (`:247`, `:254`, `:261`) and `askers.rb` holds live
`Async::Queue` state — those two stay. `wiring_spec.rb` is 2,529 lines and the `wiring/` subtree specs
add ~2,500 more: **5,029 spec lines for 513 code lines, 9.8:1.**

**`cli/up/` — three files, none with its own spec.** `cockpit.rb` 51 code (constructed at
`up.rb:574`), `hud.rb` 37 (`up.rb:571`, plus a constant read at `up.rb:563`), `pane_command.rb` 35
(reached through `up.rb:140`'s forwarding shim, but with **four external callers**:
`cli/fleet_windows.rb:393`, `cli/command/btw.rb:53`, `cli/command/fork.rb:128`). `up_spec.rb:646-650`
states the policy: *"Cockpit's and Hud's do — they are Up's children, exercised through the
parent."* So `Hud` and `Cockpit` fold in; `PaneCommand` is the opposite case and should be
**promoted** to `Lain::CLI::PaneCommand`, with `up.rb:140`'s shim deleted.

**`cli/epic_driver/` — an index with an empty module body.** `epic_driver.rb` is 16 lines: a
`module EpicDriver; end` and five requires. `EpicDriver::Seams` is defined in `factory.rb:24`, not
there. Sizes: `factory.rb` 203 code / **55 defs**, `run.rb` 177 / 34, `issue_actor.rb` 146 / 23,
`plan_subject.rb` 76 / 13, `issue_tests.rb` 64 / 9. `Run` has **exactly one** production caller,
`factory.rb:190`, and its eight injected collaborators all come from that one method.
`plan_subject.rb` has a second caller outside the subtree — `arm/plan_only.rb:137`.

Metrics-cop comments here: `factory.rb:15`, `:128`, `:329`; `issue_actor.rb:163`; `run.rb:285`,
`:355`. Three of those are the "within Metrics/ClassLength instead of loosening it" sentence.

**This is not a duplicate of `CLI::Wiring`.** `factory.rb:145-164` builds a genuinely different
`Isolation::Worktree` and `Supervisor::Retirement`, because an epic's worktrees cut from
`epic/<slug>` and retire by anchoring without merging. It stays its own root.

**The four epic commands repeat one constructor.** `epic.rb` 182 code / 40 defs, `epic_graph.rb` 69,
`epic_land.rb` 93, `epic_finish.rb` 96, `epic_submit.rb` 229, `epic_submit/adjudication.rb` 73.
`CLI::Epic` is constructed at **nine** sites, of which `epic_graph.rb:69`, `epic_submit.rb:340`,
`epic_land.rb:37`, `epic_finish.rb:64` are siblings building one *just to reach `resolve_slug`*. Each
of `epic_graph`/`epic_land`/`epic_finish` has exactly one caller, an `exe/lain` line (`:369`/`:376`/
`:383`, `:416`, `:424`). `adjudication.rb` has one caller, `epic_submit.rb:369-370`. **No
Metrics-cop comment in any of these six** — this fold is justified by the duplicated constructor, not
by a counter.

**`cli/command/` — ten classes at or under 30 code lines.** `quit.rb` 12 (4 defs, **no spec**),
`sessions.rb` 13, `inbox.rb` 16, `unpin.rb` 18 (**no spec**), `model.rb` 19, `approve.rb` 26,
`env.rb` 26, `implement_epic.rb` 28, `help.rb` 29, `keep.rb` 30 (**no spec**). Every one is
constructed in `command/surface.rb` (`#builtins` `:132-136`, `#registry` `:116-122`). The four
Metrics-cop comments in the directory are all in `surface.rb` (`:8`, `:99`, `:129`, `:140`) — two of
them noting `#builtins` and `#epic_commands` sit **at** `Metrics/AbcSize`'s limit, which is why a new
command "founds a group".

**Keep `Registry`** (`command/registry.rb`, 49 code): `Collision` (`:18`), `Bound` currying (`:73`)
and per-command error attribution (`:91-97`) are real policy, not a `case/when`.

**The approval micro-objects.** `gate/adjudicator/outcome.rb` is **46 raw / 23 code for two classes**
(`Outcome` and `Deferral`) constructed at two adjacent lines, `adjudicator.rb:263-264`.
`adjudicator/decided.rb` 35 code (one caller, `:151`), `adjudicator/evidence.rb` 44 (three,
`:216`/`:231`/`:233`). **None of the three has a mirrored spec** — coverage is in
`adjudicator_spec.rb` alone. `gate/policies.rb` 83 code is a **four-entry catalog with four bespoke
error classes** (`Unknown`, `MissingSeam`, `UnusableSeam`, `UnknownSeam`); `gate/policy.rb` 91 is
built only through that catalog (`:126`, `:130`, `:134`, `:143`). `rule_chain.rb` 67 has one caller
(`escalation.rb:314`); `policy_switch.rb` 42 has one (`switchboard.rb:300`); `composed_term.rb`
**356 raw / 79 code — a 3.5:1 prose ratio** — has one (`board_build.rb:106`).

**`Agent::Collaborators` cites the cop in its first comment.** `collaborators.rb:18` — *"Metrics/ClassLength
the moment the rule landed inside it."* 82 code lines, constructed at `agent.rb:295-296`, with
`Collaborators::OMITTED` read at `agent.rb:144-147`. `agent/instrumentation.rb` 56 code has three
callers — `cli/tool_guard.rb:31`, `cli/chronicle.rb:114`, `:117` — so it is **not** a pure Agent
shard and the card must treat the two differently.

**`Session::Journaled` is eleven one-line pass-throughs.** Lines 494-636 of `session.rb` (639 total).
**One** production construction: `cli/chronicle.rb:197`. Of its twenty methods, **eleven are pure
one-line forwards** (`:550`, `:553`, `:556`, `:559`, `:573`, `:576`, `:603`, `:606`, `:616`, `:619`,
`:624`); three more forward-and-return-`self`; five forward and journal. `session_concurrency_spec.rb`
is named in its class comment at `:509` as the pin for its fiber-safety claim.

**The two Ollama deployments share no code.** `deployment.rb` is 41 raw / **10 code** — a pure
`module Deployment` plus two requires. `local.rb` 32 code, `cloud.rb` 88. Both answer the identical
eleven-message interface. `cloud.rb` carries **measured credential hygiene that must survive**:
`SURROUNDING_SPACE` (`:83-89`, NBSP-aware because a key copied from the settings page can be
non-breaking space only and pass `strip.empty?`), `UNUSABLE_IN_HEADER` enforcement (`:283-290`,
`:301-307`, CRLF rejection), and a redaction triple at `:256-273` — `#inspect`, `#instance_variables`
minus `@headers`, `#pretty_print` — written because **super_diff 0.19.0 walks instance variables and
rendered a live Bearer token into a CI log**. A known gap is stated at `:54-61`: `#to_h` and
`#deconstruct_keys` are not redacted.

**`ask_human`'s shards.** `holding.rb` is **43 raw / 8 code** and `:12` says it was extracted *"for
Metrics/ClassLength rather than loosening a cap to fit one more delegation"* — it is two one-line
delegations to `@outstanding`, included once at `ask_human.rb:760`. `notifying.rb` 17 code is a
subclass whose only job is overriding `#ask` to call `@notify` — but `AskHuman` **already takes
`notify:`** (`ask_human.rb:670`) and already dispatches through it at `:841`; one caller,
`wiring/askers.rb:95`. `unattended.rb` 20 code is a **real behavioural variant** with three callers
(`askers.rb:93`, `switchboard.rb:335`, `subagent.rb:464`) and its own spec — borderline.

**`supervisor.rb` reopens `Supervisor` five times and `Retirement` three.** 873 lines. Judged on
code: ~118 supervision, **124 `Retirement`** (`:526-623`, `:625-745` including `Anchor` at
`:648-744`, `:747-760`), 37 `Registration` (`:387-458`), 18 Null/Retain, 20 telemetry, 15 `Drain`
(`:813-827`), **17 `TurnMailbox`** (`:846-867`). `:377-379` states the rule. `Retirement::Anchor`
shells to git at `:660` and builds `Isolation::Worktree::Handback::Outcome` at `:743` — it is worktree
handback, and it is more code than the Supervisor. `TurnMailbox` is a `Context::Combinator` with no
`lib/` reference outside its own file.

**`Subagent::Leases` is isolation-domain code inside a tool.** `subagent.rb` is 1,461 lines, reopened
at `:37` and `:385`. `Leases` spans `:784-966` — `Held` (`:788-801`), `Lane` (`:803`, reopened
`:814-833`), `InPlace` (`:848-874`) — owning two `Monitor`s and an ordinal sequence, wrapping
`Isolation::Null`/`WorkerHandoff`/`SelfSync`/`WorkerId`, with three consumers **outside** the tool:
`toolset_build.rb:379`, `:464`, `:466` and `skill/role_spawn.rb:70`. Meanwhile
`lib/lain/isolation/lease.rb` and `lease_lock.rb` already exist, and `isolation/worker_id.rb:12`
points back at the tool.

**Correction to an earlier assumption:** `TurnFeed` is **not** in `subagent.rb`. It is
`lib/lain/tools/subagent/turn_feed.rb`, 70 lines, with its own spec (89 lines), constructed at
`subagent.rb:1240`.

**The spec cost of all this.** Folding a class breaks specs that reach into it. **291 internals
reach-ins exist across the suite** — 124 `send(:`, 167 `instance_variable_get` — and
`wiring_spec.rb` alone holds **33**: `instance_variable_get(:@switchboard)` at `:327`, `:540`, `:793`,
`:1594`, `:1737`, `:1755`; `send(:switchboard)` at `:2272`; `send(:toolset_build).send(:seam)` at
`:2436`; plus fourteen private-ivar identity assertions. `supervisor_spec.rb` has 14 examples
asserting exact ordered call logs. `subagent_spec.rb` has a 170-line isolated `Seam` group of which
14 of 18 examples lose their subject on a merge.

**One of those is earned and must survive.** `wiring_spec.rb:2453-2470` explains why it uses `equal?`
and not `eq` — *identity* is the claim, one object at two seams — and names the real regression it
guards: `ToolsetBuild` and `BoardBuild` each calling `Shell::Verdict.new`, restoring a double parse
**with a green suite**. It also records that `eq` catches it today only by coincidence of two
unrelated classes inheriting `Object#==`.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lib/lain/cli.rb`,
  `lib/lain/cli/command.rb`, `lib/lain/cli/epic_driver.rb`, `lib/lain/tools.rb`,
  `lib/lain/provider/ollama.rb`'s require block, `lain.gemspec`, `.rubocop.yml`,
  `spec/spec_helper.rb`.
- **Every card here deletes require lines and several delete an index file entirely.** T3 removes
  `lib/lain/cli/epic_driver.rb`; T7 removes `provider/ollama/deployment.rb`. Those are index removals,
  handed back as wiring diffs, and each must land in the same commit as the files it stopped loading.
- **This plan requires simplify-01 to have landed** for the cards that genuinely need it — but the
  claim as first written, that *every* card produces a class larger than `Metrics/ClassLength: 125`
  permits, is **false and was never measured**. Measured with the cop's own counter, the merged
  `CLI::Epic` is **115** and `CLI::EpicSubmit` is **99**: neither trips even the old limit, so that
  card never depended on 01 at all. Re-check per card rather than assuming.

  **And the cop cannot see the shape these folds produce.** `Metrics/ClassLength` subtracts nested
  class bodies entirely: a class of 750 body lines, 600 of them in three nested classes, reports
  **zero offenses at `Max: 300`**. The four-way epic merge this plan asked for measures 242 against
  428 source lines and would have passed in silence. The plan's own Grounding already quotes the
  mechanism from `cli/wiring/agent_build.rb` — *"a NESTED class or module costs the enclosing class
  only ONE line toward the cop… the in-file escape hatch"* — it simply never carried the consequence
  into this contract.

  The consequence binds every card here: **a card's "stop if the fold exceeds the raised limit"
  trigger is not a reliable detector.** A fold that produces a god class out of nested classes trips
  nothing. `Lint/DuplicateMethods` is the cop that actually caught the epic merge, by finding two
  private methods wanting one name. Judge the result by reading it, not by whether rubocop is quiet.
- **T2 runs after simplify-07's T6.** T2 deletes `lib/lain/cli/up/hud.rb`; 07's T6 first strips its
  7-line `JQ_FILTER` and `JQ_MISSING_WARNING` by publishing a pre-rendered `hud` field. Running T2
  first does not break 07 — it relocates its target mid-plan, which is worse, because the jq filter is
  pinned byte-for-byte against the shell script by `spec/plugin/tmux_plugin_spec.rb:40-41` and that
  spec does not care which file the Ruby copy lives in.
- **This plan requires simplify-01's spec-mirror relaxation.** Folding `hud.rb` into `up.rb` leaves
  `up.rb` with one spec covering three former subjects, which the current rule forbids.
- `.rubocop.yml`'s `Style/Documentation` `AllowedConstants` list shrinks as classes stop being
  reopened. simplify-01's T2 does that pass; **cards here report entries that become removable rather
  than editing the list**, so two plans do not fight over one file.

## Open decisions

- **`ask_human/unattended.rb` is borderline and the card says so.** It is a real behavioural variant
  (`#perform → Result.error(@text)`) with three callers and its own spec. T8 folds `holding` and
  `notifying` and **leaves `unattended` alone**, noting that folding it to
  `AskHuman.new(refuses: text)` would save ~14 code lines and is defensible either way. The panel
  decides; nothing is gated on it.
- **Whether `Agent::Instrumentation` folds.** It has three callers, two outside `Agent`
  (`cli/tool_guard.rb:31`, `cli/chronicle.rb:114`), so T9 folds **`Collaborators` only** and reports
  `Instrumentation` as a genuine collaborator. If the panel disagrees, T9 grows.

## Waves

Wave 1: T1, T2, T5, T7, T8, T10
Wave 2: T3 (←T1), T4, T6, T9
Wave 3: T11
Wave 4: T12 (←T11)
Critical path: T1 → T11 → T12

T3 follows T1 because `epic_driver/factory.rb` constructs `ToolsetBuild`, which T1 touches. T4, T6 and
T9 are in wave 2 only to keep the wave-1 diff reviewable — they have no logical dependency.

**T11 sits alone in wave 3 because it collides with three other cards on the repo's two busiest wiring
files**: `lib/lain/cli/wiring.rb` with T1 and T9, and `lib/lain/cli/epic_driver/factory.rb` with T3. It
is a move, so a conflict there does not fail loudly — it silently drops half an extraction. T12 follows
T11 because T11's move changes what `toolset_build.rb` requires.

## Tasks

### T1 — Fold six single-caller wiring shards back into `Wiring`   [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/cli/wiring.rb`; delete `lib/lain/cli/wiring/agent_build.rb`,
`wiring/base_tools.rb`, `wiring/epic_seat.rb`, `wiring/handback.rb`, `wiring/run_state.rb`, and the
module-function half of `wiring/board_build.rb`; delete
`spec/lain/cli/wiring/{agent_build,base_tools,epic_seat,handback}_spec.rb`; modify
`spec/lain/cli/wiring_spec.rb`, `spec/lain/cli/wiring/board_build_spec.rb`
**Reuse:** `wiring.rb:22-36` already names the extraction order and the budget each bought — it
becomes the record of why they came back. `BoardBuild::Classifiers` (`board_build.rb:263-297`) holds
per-cwd state and stays a class.
**Shared-file wiring:** remove five `require_relative` lines from `lib/lain/cli/wiring.rb`'s require
block (the file is task scope, but the requires are at its foot and the orchestrator applies them with
the deletions)
**Reachable from:** `CLI::Wiring` is constructed from `CLI::ChatLaunch#constructed`
(`chat_launch.rb:134`) on the live chat path; AC 1 drives a full wiring build through `ChatLaunch`
rather than constructing `Wiring` directly

Fold the six whose only production caller is `wiring.rb`: `agent_build` (`:303`, `:350`),
`base_tools` (via `toolset_build.rb:346`), `epic_seat` (`:383`), `handback` (`:377`), `run_state`
(`:165`), and `board_build`'s eight module functions (`:419`, `:438`).

**Keep as files:** `toolset_build.rb` (three external callers in `epic_driver/factory.rb`) and
`askers.rb` (live `Async::Queue` state). **Keep `Handback`'s `Data`** — fold only `Handback.for`.

**`board_build.rb` does not fold, and the instruction to fold "its eight module functions" while
keeping `BoardBuild::Classifiers` was incoherent.** `Classifiers` is nested *inside* `module
BoardBuild` and is named from outside as `Lain::CLI::Wiring::BoardBuild::Classifiers` at three
sites, so obeying that instruction yields a file called `board_build.rb` holding a module called
`BoardBuild` that builds no board. Three further reasons it stays, found while executing: the file
names no `Metrics/*` cop, so the plan's Intent — fold back only extractions whose stated
justification was a counter — does not reach it; its class comment states a real second
responsibility (consent rules GRANT, sensitivity rules RESTRICT, and *"the resemblance is a
trap"*); and `.for`/`.rules`/`.policy` have four callers in two unrelated spec files outside
`lib/`, which private methods on `Wiring` cannot serve. This card's own fourth escalation trigger
already said to leave it alone for a different reason. 8 files → 3 is reached without it.

Two stale claims to delete while here: `wiring.rb:22` and `agent_build.rb:135` both cite a "110-line
budget" that `.rubocop.yml:161` has said 125 since 2026-08-28, and simplify-01 raises again.
`wiring.rb:459-482` is **24 comment lines of ABC arithmetic** justifying a six-line method split.

**Acceptance criteria**

```gherkin
Scenario: a chat launch builds a complete object graph
  Given a chat launched the way the CLI launches one
  When its wiring is built
  Then an agent, a toolset, a board and a chronicle are all present

Scenario: the gate and the tool see one shell verdict
  Given a wiring built for a project with shell exclusions
  When the gate's verdict and the toolset's verdict are compared
  Then they are the same object

Scenario: a resumed run restores its state
  Given a session record to resume from
  When the wiring is built for it
  Then the run state reports it was resumed

Scenario: an epic seat is mounted when a config declares epics
  Given a project config declaring an epics home
  When the wiring is built
  Then an epic seat is present
```
→ spec file: `spec/lain/cli/wiring_spec.rb`, with AC 1 in `spec/lain/cli/chat_launch_spec.rb`

**Escalation triggers**
- **`wiring_spec.rb:2453-2470` is earned and must survive.** It asserts object *identity* with
  `equal?` because one `Shell::Verdict` reaching two seams is the claim, and it names the regression
  it guards: `ToolsetBuild` and `BoardBuild` each calling `Shell::Verdict.new`, restoring a double
  parse with a green suite. It also records that `eq` catches this today only by coincidence. Preserve
  what it asserts; if the fold makes identity untestable, **stop** — that is the fold breaking a real
  invariant, not a stale spec.
- **33 internals reach-ins in `wiring_spec.rb`** (`instance_variable_get(:@switchboard)` at `:327`,
  `:540`, `:793`, `:1594`, `:1737`, `:1755`; `send(:switchboard)` at `:2272`;
  `send(:toolset_build).send(:seam)` at `:2436`, plus fourteen ivar identity assertions). Expect ~25
  examples to break with no behaviour change. Rewrite them against behaviour where you can; where an
  example exists only to pin topology, **report it** rather than deleting it silently.
- `wiring.rb` currently sits near its cop budget by design. If the fold produces a class that exceeds
  even simplify-01's raised `ClassLength`, stop — that is evidence `Wiring` holds two responsibilities
  and the answer is a different cut, not a bigger number.
- `board_build.rb` is simplify-02's T1 scope (the `Sensitivity` threading). If both plans are in
  flight, sequence after 02's T1 or the two edits collide on the same method.

### T2 — Fold `Up`'s two spec-less children in, and promote the one with callers   [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `lib/lain/cli/up.rb`; delete `lib/lain/cli/up/hud.rb`, `up/cockpit.rb`;
move `lib/lain/cli/up/pane_command.rb` → `lib/lain/cli/pane_command.rb`;
modify `lib/lain/cli/fleet_windows.rb`, `lib/lain/cli/command/btw.rb`,
`lib/lain/cli/command/fork.rb`, `spec/lain/cli/up_spec.rb`; create
`spec/lain/cli/pane_command_spec.rb`
**Reuse:** `up_spec.rb:646-650` already states the policy this card follows — *"they are Up's
children, exercised through the parent"*
**Shared-file wiring:** remove the three `require_relative` lines from `lib/lain/cli/up.rb`; add
`require_relative "cli/pane_command"` to `lib/lain/cli.rb` at its alphabetical position
**Reachable from:** `PaneCommand` is reached from `CLI::FleetWindows#spawn` (`fleet_windows.rb:393`)
and two REPL commands; AC 3 drives it through `fleet_windows`, not through `Up`

Two opposite moves. `Hud` (37 code) and `Cockpit` (51) have **no specs of their own** and no callers
outside `up.rb` — they fold in, and `Cockpit#cwd` has no reader anywhere, so it goes.
`PaneCommand` (35 code) has **four callers outside `up.rb`** and is reached through a pure forwarding
shim at `up.rb:140` — it is promoted out, and the shim is deleted.

While promoting: `PaneCommand::PANE_ENV` (`:25-29`) is a **hand-maintained list of env names held
against `exe/lain` by a drift spec**, with 30 lines of comment explaining the arrangement.
**Report** whether `CLI::EnvDefaults` could own that registry so `exe/lain` declares flags *from* it
and `PANE_ENV` reads its names — do not do it here; it is a second responsibility and a separate card.

**Acceptance criteria**

```gherkin
Scenario: a cockpit opens with a status line
  Given a tmux session and a project
  When the cockpit is opened
  Then a chat pane and a status line are present

Scenario: the status line reports fleet and inbox counts
  Given a state file holding a fleet of two and an inbox of three
  When the status line is rendered
  Then it names both counts

Scenario: a fleet window spawns with the pane command
  Given a fleet window request
  When it is spawned
  Then the command it runs carries the project's environment

Scenario: the pane command carries every environment name the CLI declares
  When the pane command's environment names are compared with the CLI's flags
  Then every declared flag is represented
```
→ spec files: `spec/lain/cli/up_spec.rb` (AC 1, AC 2), `spec/lain/cli/pane_command_spec.rb` (AC 3,
AC 4 — the drift assertion moves here with the class)

**Escalation triggers**
- `up.rb:563` reads `Hud::DEFAULT_INTERVAL` as a **constructor default**. Folding `Hud` in means that
  constant moves; if the default is evaluated before the constant is defined, it is a load-order
  failure that presents as `NameError` at boot, not at call time.
- `up_spec.rb` is 2,442 lines and covers three subjects. After this card it covers one class with
  three former children folded in — which is *more* correct under simplify-01's relaxed mirror rule,
  but only if that has landed. Confirm before starting.
- `pane_command.rb`'s drift spec holds `PANE_ENV` against `exe/lain`. If moving the file breaks the
  spec's path assumptions, fix the spec — but if it breaks the **drift check itself**, stop: that
  check is the only thing keeping the env list honest, and a tmux pane inheriting the wrong PATH is a
  documented trap (`CLAUDE.md:245-247`).

### T3 — Collapse `epic_driver/` and delete its empty index   [wave 2] [risk: high]

**Depends on:** T1
**Files:** modify `lib/lain/cli/epic_driver/factory.rb`; delete `lib/lain/cli/epic_driver.rb`,
`epic_driver/run.rb`, `epic_driver/issue_tests.rb`; modify `epic_driver/issue_actor.rb`,
`epic_driver/plan_subject.rb`; modify `spec/lain/cli/epic_driver/factory_spec.rb`,
`spec/lain/cli/epic_driver/run_spec.rb`, `spec/lain/cli/epic_driver/issue_tests_spec.rb`
**Reuse:** `factory.rb:24`'s `Seams` already holds what `Run` needs; `factory.rb:145-164`'s distinct
`Isolation::Worktree` and `Supervisor::Retirement` construction is the reason this subtree exists and
must be preserved
**Shared-file wiring:** remove `require_relative "cli/epic_driver"` from `lib/lain/cli.rb:38`, and
fold its five requires into whichever file survives as the subtree's entry
**Reachable from:** `CLI::Command::Surface:95` calls `epic.driver(root:, library:, chronicle:)`,
which reaches `Factory.for` (`factory.rb:35`); AC 1 drives an epic through that path

`epic_driver.rb` is 16 lines with an **empty module body** — the namespace it declares is populated
from `factory.rb:24`. `Run` (177 code, 34 defs) has exactly one production caller,
`factory.rb:190`, which supplies all eight of its injected collaborators. `IssueTests` (64 code) has
one, `factory.rb:254`.

Fold `Run` and `IssueTests` into `Factory`. **Keep `issue_actor.rb`** (146 code, its own
responsibility — an actor's lifecycle) and **`plan_subject.rb`** (76 code, with a caller outside the
subtree at `arm/plan_only.rb:137`).

Drops with the fold: `Run`'s `actors:` and `config:` keywords, its `Ungraded` Null, and the two
`# Reopened rather than nested mid-body` splits at `factory.rb:329` and `issue_actor.rb:163` that
exist only for the cop. `factory.rb` has **55 defs**; after absorbing `Run` it will be the largest
class in the plan, and that is the point — but if it exceeds simplify-01's raised limit, escalate.

**Acceptance criteria**

```gherkin
Scenario: an epic runs its issues to completion
  Given an epic with two issues whose tests exist
  When the driver runs it
  Then both issues are attempted
  And progress is reported for each

Scenario: an issue whose tests are missing is refused before an actor is spawned
  Given an epic issue with no failing test
  When the driver reaches it
  Then it is refused
  And no actor was spawned

Scenario: an epic's worktrees cut from the epic branch
  Given an epic with a slug
  When a worker is leased
  Then its worktree is cut from that epic's branch

Scenario: a driver is mountable from the command surface
  Given a project config declaring an epics home
  When the command surface builds its epic commands
  Then a driver is available
```
→ spec files: `spec/lain/cli/epic_driver/factory_spec.rb` (AC 1-3),
`spec/lain/cli/command/surface_spec.rb` (AC 4)

**Escalation triggers**
- `factory.rb:145-164` builds a **different** `Isolation::Worktree` and `Supervisor::Retirement` than
  `CLI::Wiring` does, because an epic retires by anchoring without merging. If the fold tempts sharing
  those with `Wiring`, **stop** — that is a behaviour change disguised as deduplication.
- `run_spec.rb` is 623 lines against 177 code lines. Folding `Run` means those examples now target
  `Factory`. If more than a handful reach into `Run`'s privates, report the count; `epic_driver`'s
  specs were not audited for reach-ins and the 291 repo-wide total suggests some are here.
- `epic/` is simplify-08's neighbourhood (`Arm::Epic`) and simplify-02 touches nothing here, but
  **`Supervisor::Retirement` is T11's scope**. If T11 has moved it, `factory.rb:145-164` references a
  moved constant — sequence accordingly or expect a `NameError`.
- `plan_subject.rb`'s external caller is `arm/plan_only.rb:137`, and simplify-08 may **retire**
  `plan_only.rb`. If it has, `plan_subject.rb` loses its reason to stay a file. Report rather than
  folding it opportunistically.

### T4 — Merge the four epic commands that repeat one constructor   [wave 2] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/cli/epic.rb`; delete `lib/lain/cli/epic_graph.rb`,
`cli/epic_land.rb`, `cli/epic_finish.rb`, `cli/epic_submit/adjudication.rb`; modify
`lib/lain/cli/epic_submit.rb`, `exe/lain`; delete
`spec/lain/cli/{epic_graph,epic_land,epic_finish}_spec.rb`,
`spec/lain/cli/epic_submit/adjudication_spec.rb`; modify `spec/lain/cli/epic_spec.rb`,
`spec/lain/cli/epic_submit_spec.rb`
**Reuse:** `CLI::Epic#resolve_slug` is what three of the four build an `Epic` **just to reach** —
after the merge it is a private method call
**Shared-file wiring:** remove three `require_relative` lines from `lib/lain/cli.rb` (`epic_graph`
at `:34`, `epic_land` at `:37`, `epic_finish` at `:39`). **The fourth is not in `cli.rb`** — it is
the last line of `lib/lain/cli/epic_submit.rb`, which requires its own `epic_submit/adjudication`.
**Reachable from:** each merged command keeps its `exe/lain` entry point — `:369`/`:376`/`:383`
(graph), `:416` (land), `:424` (finish); AC 1-3 each drive one through `exe/lain`

Four files, one constructor. `epic_graph.rb:69`, `epic_land.rb:37`, `epic_finish.rb:64` and
`epic_submit.rb:340` each construct a `CLI::Epic`, and three of those do it only for `resolve_slug`.
Each of graph/land/finish has exactly one caller, an `exe/lain` line.

`adjudication.rb` (73 code) has one caller, `epic_submit.rb:369-370`, and folds into `EpicSubmit`.

`epic_submit.rb` itself is 229 code lines and **stays its own file** — it has a second caller
(`epic_driver/factory.rb:302`) and a genuinely separate responsibility (wire-format submission).

**No Metrics-cop comment justifies any of these six.** This fold is justified by the duplicated
constructor alone, which makes it the cleanest card in the plan and the one most likely to be
uncontroversial.

**Acceptance criteria**

```gherkin
Scenario: an epic's graph renders as mermaid
  Given an epic with three issues and two dependencies
  When its graph is requested
  Then a mermaid diagram naming all three issues comes back

Scenario: an issue lands onto the epic branch
  Given an epic issue whose work is committed in a worker
  When it is landed
  Then its commits are on the epic branch

Scenario: finishing an epic opens one submission
  Given an epic whose issues have all landed
  When it is finished
  Then one submission is opened for the epic

Scenario: a slug is resolved once per command
  Given an ambiguous epic slug
  When a graph is requested for it
  Then the ambiguity is reported
  And it is reported once
```
→ spec files: `spec/lain/cli/epic_spec.rb` (AC 1, AC 4). **AC 2 and AC 3 are routed wrongly here**:
`epic_submit_spec.rb` contains zero references to land or finish and could not cover them. They
belong to `spec/lain/cli/epic_land_spec.rb` and `spec/lain/cli/epic_finish_spec.rb`.

**Escalation triggers**
- `CLI::Epic` is constructed at **nine** sites. Four are the siblings this card merges; the other five
  (`exe/lain:364`, `epic_mount.rb:107`, `epic_queue.rb:129`, `epic_driver/factory.rb:293`,
  `wiring/epic_seat.rb:53`) are real callers. If merging changes `Epic`'s constructor signature, all
  five need checking — count them before changing it.
- `epic.rb` has **40 defs** in 182 code lines and will absorb three more commands. If the result reads
  as three unrelated command bodies in one class, the merge is wrong and the honest cut is a shared
  `resolve_slug` collaborator instead. Report that rather than shipping a god class.
- `epic_land.rb:137` defines `def submit = EpicSubmit.new(...)`. Folding `epic_land` moves that; if
  `EpicSubmit`'s construction then happens in two places, the fold has created the duplication it was
  meant to remove.

### T5 — Put the ten smallest REPL commands in one file   [wave 1] [risk: low]

**Depends on:** none
**Files:** create `lib/lain/cli/command/small.rb` (or fold into `lib/lain/cli/command.rb` — the card
chooses and says why); delete `lib/lain/cli/command/{quit,sessions,inbox,unpin,model,approve,env,implement_epic,help,keep}.rb`;
modify `lib/lain/cli/command/surface.rb`; delete the six corresponding spec files that exist
**Reuse:** `CLI::Command::Registry` (`command/registry.rb`, 49 code) **stays** — `Collision` (`:18`),
`Bound` currying (`:73`) and per-command error attribution (`:91-97`) are real policy
**Shared-file wiring:** replace ten `require_relative` lines in `lib/lain/cli/command.rb` with one
**Reachable from:** every command is constructed in `CLI::Command::Surface#builtins`
(`command/surface.rb:132-136`); AC 1 drives each through a surface built the way the REPL builds one

Ten classes at or under 30 code lines, each carrying `module`/`class` scaffolding plus a
`require_relative`: `quit` 12, `sessions` 13, `inbox` 16, `unpin` 18, `model` 19, `approve` 26,
`env` 26, `implement_epic` 28, `help` 29, `keep` 30. Three have **no spec at all** (`quit`, `unpin`,
`keep`).

`/sessions` is 13 code lines of argument parsing around the one-line call `lain sessions` makes
directly — worth noting in the commit message as the clearest case.

**Keep the nine large commands standalone**: `survey` 118, `meta` 118, `review` 101, `undo` 93,
`fork` 86, `rewind` 73, `introspect` 59, `pin` 55, `btw` 54, plus `review_submit` 37 and `status` 34
if the card judges them over the line — say where the line is.

**Acceptance criteria**

```gherkin
Scenario: every built-in command is registered
  Given a command surface built the way the REPL builds one
  When its command names are listed
  Then each of the ten merged commands is present

Scenario: a merged command still reports its usage
  When help is asked for the model command
  Then its usage line is shown

Scenario: two commands claiming one name are refused
  Given two commands registered under the same name
  When the registry is built
  Then it refuses, naming the collision

Scenario: a command's failure is attributed to it
  Given a command that raises
  When it is invoked through the registry
  Then the error names that command
```
→ spec file: `spec/lain/cli/command/surface_spec.rb` (AC 1, AC 2),
`spec/lain/cli/command/registry_spec.rb` (AC 3, AC 4 — existing, must stay green)

**Escalation triggers**
- `command/surface.rb:129` and `:140` both note that `#builtins` and `#epic_commands` sit **at**
  `Metrics/AbcSize`'s limit. Merging ten classes does not change those methods' complexity, but if
  the card is tempted to also restructure them, stop — that is a different card.
- The three commands with no spec (`quit`, `unpin`, `keep`) gain coverage by AC 1 for the first time.
  If AC 1 reveals one of them is broken, that is a real finding and it belongs in its own commit, not
  buried in a fold.
- If `command/small.rb` exceeds simplify-01's raised `ModuleLength`, the grouping is wrong. Split by
  *kind* — session commands, approval commands — rather than by size, and say so.

### T6 — Fold the approval micro-objects into `Gate`   [wave 2] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/approval/gate/adjudicator.rb`, `lib/lain/approval/gate.rb`,
`lib/lain/approval/escalation.rb`, `lib/lain/cli/switchboard.rb`,
`lib/lain/cli/wiring/board_build.rb`; delete
`lib/lain/approval/gate/adjudicator/{outcome,decided,evidence}.rb`,
`lib/lain/approval/{rule_chain,policy_switch,composed_term}.rb`; modify
`lib/lain/approval/gate/policies.rb`, `lib/lain/approval/gate/policy.rb`; delete
`spec/lain/approval/{rule_chain,policy_switch,composed_term}_spec.rb`
**Reuse:** `Approval::Gate::Adjudicator` already holds the decision logic these three shards serve;
`Gate::Policies`' catalog (`:126-143`) already constructs all four policies
**Shared-file wiring:** remove the require lines for the six deleted files from
`lib/lain/approval/gate.rb` and `lib/lain/approval.rb`
**Reachable from:** `Approval::Gate` is constructed at `cli/epic_driver/factory.rb:195` and
`cli/epic_submit.rb:459`; `PolicySwitch` at `cli/switchboard.rb:300`; `ComposedTerm` at
`cli/wiring/board_build.rb:106`. AC 1 drives a gate decision through `epic_submit`'s construction.

Six folds, each with one or two callers:

- `adjudicator/outcome.rb` — **46 raw lines for two classes** to avoid one branch, constructed at two
  adjacent lines (`adjudicator.rb:263-264`). **No mirrored spec.**
- `adjudicator/decided.rb` (one caller, `:151`) and `adjudicator/evidence.rb` (three, `:216`/`:231`/
  `:233`) — neither has a mirrored spec either.
- `rule_chain.rb` → `Escalation` (one caller, `escalation.rb:314`).
- `policy_switch.rb` → `Switchboard` (one caller, `switchboard.rb:300`).
- `composed_term.rb` → `BoardBuild` (one caller, `board_build.rb:106`). At **356 raw / 79 code** it is
  the worst prose ratio in the plan, ~3.5:1.

Also collapse `gate/policies.rb`'s **four bespoke error classes** (`Unknown`, `MissingSeam`,
`UnusableSeam`, `UnknownSeam`) for a four-entry catalog into one refusal carrying which entry and why.
`gate/policy.rb` (91 code) is built only through that catalog and folds with it.

**Acceptance criteria**

```gherkin
Scenario: an adjudicated gate approves on a recorded verdict
  Given a gate whose policy is adjudicated
  And a recorded approval for the subject
  When the gate is asked
  Then it approves

Scenario: an unknown policy name is refused by name
  Given a config naming a policy that does not exist
  When the policies catalog is built
  Then it refuses, naming the unknown policy
  And it lists the policies that exist

Scenario: a deferred decision is not an approval
  Given a gate whose policy defers
  When the gate is asked
  Then the effect is not approved
  And the deferral is recorded

Scenario: a rule chain still decides in declaration order
  Given two escalation rules, the first matching
  When an effect is judged
  Then the first rule's verdict is used
```
→ spec files: `spec/lain/approval/gate/adjudicator_spec.rb` (AC 1, AC 3),
`spec/lain/approval/gate/policies_spec.rb` (AC 2), `spec/lain/approval/escalation_spec.rb` (AC 4)

**Escalation triggers**
- `gate.rb:201` collapses the approve/deny/defer triad to a **Boolean**, which is *why*
  `adjudicator.rb:259-266` must re-encode "defer" as deny plus a policy string. If the fold makes that
  re-encoding removable, that is a **behaviour** improvement and belongs in its own commit with its
  own ACs — do not smuggle it into a fold.
- `escalation.rb:581-582` infers **authority from a surface's string**, a latent defect its own comment
  names. Folding `rule_chain` brings that code closer; do not fix it here, report it. simplify-09
  owns the verdict vocabulary.
- `composed_term.rb` is 79 code lines under 277 lines of prose. Folding it means deciding what prose
  survives. Prune it in the same commit rather than moving 277 lines into `BoardBuild` — but keep
  anything naming a measurement.
- The three `adjudicator/` shards have **no mirrored specs**, so folding them breaks nothing and tests
  nothing. Confirm `adjudicator_spec.rb` actually covers their behaviour before deleting the files; if
  it does not, the fold has silently reduced coverage.

### T7 — One Ollama deployment value, with the credential hygiene intact   [wave 1] [risk: high]

**Depends on:** none
**Files:** create `lib/lain/provider/ollama/deployment.rb` as a `Data.define` (replacing the
namespace); delete `lib/lain/provider/ollama/deployment/local.rb`, `deployment/cloud.rb`; modify
`lib/lain/provider/ollama.rb`, `lib/lain/cli/backend/ollama_tier.rb`; merge
`spec/lain/provider/ollama/deployment/{local,cloud}_spec.rb` into one
**Reuse:** `spec/support/shared_examples/ollama_deployment.rb` already asserts the eleven-message
interface both arms answer — it becomes the one value's spec
**Shared-file wiring:** replace two `require_relative` lines in `lib/lain/provider/ollama.rb:10`'s
region with one
**Reachable from:** `Deployment::Local` is a keyword default at `provider/ollama.rb:211` and
`Deployment::Cloud` is constructed at `:132`; `ollama_tier.rb:209` builds a Cloud for its credential
probe. AC 1 and AC 2 each drive a provider built through `CLI::Backend`.

`deployment.rb` is 41 raw / **10 code** — a pure namespace plus two requires. `local.rb` (32 code) and
`cloud.rb` (88) answer the **identical eleven-message interface over identical wire bytes**; only
hosted-ness and a credential vary. One `Data.define` with `.local` and `.cloud(api_key:)`
constructors replaces all three files.

**Four behaviours in `cloud.rb` are measured and must survive verbatim in intent:**

1. `SURROUNDING_SPACE` (`:83-89`) — Unicode-aware trim, because `String#strip` leaves U+00A0 and a key
   copied from the settings page can be non-breaking space only, pass a `strip.empty?` check, and
   reach the wire as a bare `Bearer`.
2. CRLF rejection (`:283-290`, `:301-307`) — an HTTP header value cannot carry a line break, and a key
   from a soft-wrapped page or a CRLF file carries one invisibly.
3. The **redaction triple** (`:256-273`) — `#inspect`, `#instance_variables` minus `@headers`, and
   `#pretty_print`. The comment records why all three: **super_diff 0.19.0 walks instance variables**
   and rendered `@headers={"Authorization" => "Bearer <live key>"}` into a CI log. Overriding
   `#inspect` alone is not enough.
4. The **known gap** at `:54-61` — `#to_h` and `#deconstruct_keys` are not redacted. A `Data.define`
   makes both of those *more* prominent, since `Data` gives them for free. **This is the card's main
   risk** and AC 4 exists for it.

**Acceptance criteria**

```gherkin
Scenario: a local deployment needs no credential
  Given a provider flag naming local ollama
  When a backend is constructed
  Then it is ready without an api key

Scenario: a cloud deployment refuses a key that is only whitespace
  Given an api key consisting of a non-breaking space
  When a cloud deployment is built
  Then it is refused
  And the refusal does not quote the key

Scenario: a key carrying a line break is refused as unusable in a header
  Given an api key with a trailing carriage return and newline
  When a cloud deployment is built
  Then it is refused, saying a header value cannot carry a line break

Scenario: no printer or walker reveals the credential
  Given a cloud deployment holding a key
  When it is inspected, pretty-printed, converted to a hash, and deconstructed
  Then none of the four results contains the key
```
→ spec file: `spec/lain/provider/ollama/deployment_spec.rb`, which `include_examples` the existing
shared group

**Escalation triggers**
- **AC 4 extends the current guarantee.** `cloud.rb:54-61` states `#to_h` and `#deconstruct_keys` are
  *not* redacted today, and a `Data.define` supplies both. If they cannot be redacted without giving
  up `Data`'s value semantics, **stop** — a credential leaking through `to_h` is worse than two files.
- `super_diff` is why the walker override exists. After the merge, run one spec that **fails
  deliberately** with a cloud deployment as its subject and read the failure output for the key. A
  passing suite proves nothing about this.
- `ollama_tier.rb:209`'s `probe_credential` builds a Cloud purely for its refusal. If the merged
  value's constructor refuses differently, that probe's message changes — and it is user-facing.
- `provider/ollama.rb:96` reads `Deployment::Local::CAPABILITIES` as a **constant**. A `Data.define`
  cannot hold a per-arm constant the same way; if the capabilities differ between arms, they are not
  one value and this card is wrong. Check before starting.

### T8 — Fold `ask_human`'s two cop-driven shards   [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `lib/lain/tools/ask_human.rb`, `lib/lain/cli/wiring/askers.rb`; delete
`lib/lain/tools/ask_human/holding.rb`, `ask_human/notifying.rb`
**Reuse:** `AskHuman` **already takes `notify:`** (`ask_human.rb:670`) and already dispatches through
it at `:841` — `Notifying` is a subclass overriding `#ask` to do what the parent can already do
**Shared-file wiring:** remove two `require_relative` lines from `lib/lain/tools/ask_human.rb`
(`:6` and `:993`)
**Reachable from:** `AskHuman::Notifying` is constructed at `cli/wiring/askers.rb:95`; after the fold
that site constructs `AskHuman` with a `notify:`. AC 2 drives it through `Askers`.

`holding.rb` is **43 raw / 8 code** and its own comment at `:12` says it exists *"for
Metrics/ClassLength rather than loosening a cap to fit one more delegation"* — two one-line delegations
to `@outstanding`, included once at `ask_human.rb:760`. With the limit raised the stated reason is
gone.

`notifying.rb` is 17 code lines whose only job is overriding `#ask` to add `@notify.call(question)`.
Folding is one added line at the one call site.

**`unattended.rb` is deliberately left alone** — see Open decisions. It is a real behavioural variant
with three callers and its own spec.

**Note:** if simplify-03's T3 has deleted `Lain::Notify`, `askers.rb:33`'s `Notify::Null.new` default
is already gone and this card's call-site edit is smaller. Check which order they landed in.

**Acceptance criteria**

```gherkin
Scenario: an ask notifies when a notifier is wired
  Given an ask_human built with a notifier
  When a question is asked
  Then the notifier is called with that question

Scenario: an ask built the production way notifies
  Given askers built the way the wiring builds them
  When a question is asked
  Then the run's notifier receives it

Scenario: an ask with no notifier still parks the question
  Given an ask_human built with no notifier
  When a question is asked
  Then it is parked
  And no error is raised

Scenario: an answer settles exactly one waiting ask
  Given two questions parked under different digests
  When one is answered
  Then that one settles
  And the other is still parked
```
→ spec files: `spec/lain/tools/ask_human_spec.rb` (AC 1, AC 3, AC 4),
`spec/lain/cli/wiring/askers_spec.rb` (AC 2)

**Escalation triggers**
- `holding.rb` is a **module included** at `ask_human.rb:760`, not a class. If any spec includes it
  independently to test the delegations in isolation, those examples lose their subject — report them.
- `AskHuman` is already a large class and `ask_human.rb:684` carries a Metrics-cop comment. If folding
  eight lines pushes it past simplify-01's raised limit, that is evidence `AskHuman` holds two
  responsibilities — escalate rather than re-extracting.
- If `Notifying`'s `#ask` override differs from the parent's `notify:` dispatch in *when* it fires
  (before parking versus after), folding changes observable ordering. Read both paths before
  assuming they are equivalent.

### T9 — Fold `Agent::Collaborators` back into `Agent`   [wave 2] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/agent.rb`; delete `lib/lain/agent/collaborators.rb`,
`spec/lain/agent/collaborators_spec.rb`; modify `lib/lain/cli/wiring.rb`,
`spec/lain/agent_spec.rb`
**Reuse:** `CLI::Wiring` already assembles most of what `Collaborators` re-assembles — the fold moves
ingredient assembly to the one place that has the ingredients
**Shared-file wiring:** remove `require_relative "agent/collaborators"` from `lib/lain/agent.rb`'s
require block
**Reachable from:** `Agent.new` is called from `CLI::Wiring::AgentBuild.build` (after T1, from
`Wiring` directly) and from `Tools::Subagent#spawn_agent` (`subagent.rb:1362-1370`); AC 1 drives a
real agent through `ChatLaunch`

`collaborators.rb:18` cites the cop by name: *"Metrics/ClassLength the moment the rule landed inside
it."* 82 code lines, constructed at `agent.rb:295-296`, with `Collaborators::OMITTED` read at
`agent.rb:144-147`. Folding kills `INGREDIENTS`, `KEYWORDS`, `OMITTED`, two `refuse_explicit_nil`
calls, `refuse_double_wiring`, and a 60-line constructor docstring.

**`Agent::Instrumentation` stays** — three callers, two of them outside `Agent`
(`cli/tool_guard.rb:31`, `cli/chronicle.rb:114`, `:117`). It is a genuine collaborator, not a shard.
Say so in the commit message so the asymmetry reads as a decision.

`refuse_foreign_toolset` should move to `ToolRunner` rather than being deleted — it is a real rule and
`ToolRunner` is where a toolset is used.

**Acceptance criteria**

```gherkin
Scenario: an agent takes a turn with its wired collaborators
  Given an agent built the way a chat launch builds one
  When it takes one turn
  Then the provider was called
  And the turn landed on the timeline

Scenario: constructing an agent with an explicit nil collaborator is refused
  When an agent is constructed with a nil provider
  Then construction is refused

Scenario: a toolset foreign to the agent's own is refused
  Given an agent with one toolset
  When a tool from a different toolset is dispatched
  Then it is refused

Scenario: instrumentation is still reachable from the tool guard
  When the tool guard builds its instrumentation
  Then it comes back
```
→ spec files: `spec/lain/agent_spec.rb` (AC 1-3), `spec/lain/cli/tool_guard_spec.rb` (AC 4)

**Escalation triggers**
- `Collaborators::OMITTED` is read from `agent.rb:144-147`, i.e. the parent already reaches into the
  shard's constant. If that read is in a **class body**, folding changes evaluation order — check
  before moving.
- `Agent` has 126 code lines today and absorbs 82. If the result exceeds simplify-01's limit, stop:
  `Agent`'s own docstring claims one responsibility (own the loop), and a class that cannot hold its
  own ingredients is telling you the ingredients belong to `Wiring`.
- `Tools::Subagent#spawn_agent` (`subagent.rb:1362-1370`) constructs an `Agent` with a **different**
  set of collaborators than `AgentBuild.build` — notably no `snapshot_slot:`. If folding makes that
  asymmetry a refusal rather than an omission, a subagent stops spawning. Read both call sites.

### T10 — Fold `Session::Journaled`'s eleven pass-throughs into `Session`   [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/session.rb`, `lib/lain/cli/chronicle.rb`; modify
`spec/lain/session_spec.rb`, `spec/lain/session_pins_spec.rb`
**Reuse:** `Channel::Null.instance` is the existing no-journal default used throughout `lib/`
**Shared-file wiring:** none
**Reachable from:** `Session::Journaled.new` has exactly one production site,
`cli/chronicle.rb:197`; after the fold `Chronicle` constructs a `Session` with a `journal:`. AC 1
drives it through `Chronicle`.

`Journaled` is `session.rb:494-636` — twenty methods of which **eleven are pure one-line forwards**
(`:550`, `:553`, `:556`, `:559`, `:573`, `:576`, `:603`, `:606`, `:616`, `:619`, `:624`), three
forward and return `self`, and five forward and journal. Give `Session` a `journal:` defaulting to
`Channel::Null.instance` and delete the decorator. `Session::Null` (nine production sites) stays but
collapses.

**Acceptance criteria**

```gherkin
Scenario: a read is recorded once and journaled once
  Given a session with a journal
  When a file is read twice
  Then the session reports it read
  And the journal holds one read record

Scenario: a session with no journal still tracks reads
  Given a session with no journal
  When a file is read
  Then the session reports it read

Scenario: a pin is journaled when it is taken
  Given a session with a journal
  When a digest is pinned
  Then the journal holds a pin record

Scenario: concurrent readers see a consistent session
  Given a session with a journal
  When two fibers record reads of different paths concurrently
  Then both reads are reported
  And the journal holds both records
```
→ spec files: `spec/lain/session_spec.rb` (AC 1-3), `spec/lain/session_concurrency_spec.rb` (AC 4)

**Escalation triggers**
- `session.rb:509` names `spec/lain/session_concurrency_spec.rb` as **the pin for `Journaled`'s
  fiber-safety claim**. Folding moves that claim onto `Session`. If the concurrency spec's subject
  changes and it still passes, confirm it is actually exercising the new shape — a concurrency spec
  that passes against the wrong subject proves nothing.
- `record_read(path, complete: true)` (`:524`) journals **on transition** — only when the read state
  changes. That conditional is the reason the decorator is not a pure forward. Preserve it exactly; a
  journal record per read rather than per transition would multiply the experiment record.
- `session.rb` is 639 lines and `Journaled` is 143 of them. The fold shrinks the file; if it does not,
  something was duplicated rather than merged.

### T11 — Move `Supervisor::Retirement` to worktree handback, and delete `TurnMailbox`   [wave 3] [risk: high]

**Depends on:** none
**Files:** modify `lib/lain/supervisor.rb`; create
`lib/lain/isolation/worktree/handback/retirement.rb`; modify
`lib/lain/isolation/worktree/handback.rb`, `lib/lain/cli/epic_driver/factory.rb`,
`lib/lain/cli/wiring.rb`; delete `Supervisor::TurnMailbox` (`supervisor.rb:846-867`); modify
`spec/lain/supervisor_spec.rb`; create
`spec/lain/isolation/worktree/handback/retirement_spec.rb`
**Reuse:** `Isolation::Worktree::Handback::Outcome` is what `Retirement::Anchor` already builds
(`supervisor.rb:743`), so the destination already holds the vocabulary
**Shared-file wiring:** add `require_relative "worktree/handback/retirement"` to
`lib/lain/isolation/worktree/handback.rb`
**Reachable from:** `Retirement` is constructed from `CLI::Wiring` and
`cli/epic_driver/factory.rb:145-164`; AC 1 drives a worker retirement through the chat path

Judged on code lines, `supervisor.rb` is 349 and **`Retirement` is 124 of them** — `:526-623`,
`:625-745` (with `Anchor` at `:648-744`), `:747-760`. It shells out to git at `:660` and builds
`Isolation::Worktree::Handback::Outcome` at `:743`. It is worktree handback, and it is more code than
the supervision it lives inside.

`TurnMailbox` (`:846-867`, 17 code) is a `Context::Combinator` with **no `lib/` reference outside its
own file** — constructed only in specs. Delete it.

This is a **relocation**, not a rewrite: the same class, the same behaviour, a different home. Say so,
and keep the diff a move so `git log --follow` works.

**Acceptance criteria**

```gherkin
Scenario: a retired worker's commits are handed back
  Given a worker with commits in its worktree
  When it is retired
  Then its commits are reachable from the parent branch

Scenario: a worker retiring twice is refused
  Given a worker already retired
  When it is retired again
  Then it is refused

Scenario: an epic's worker retires by anchoring without merging
  Given an epic worker with commits
  When it is retired
  Then an anchor names its commits
  And no merge was made

Scenario: the supervisor still registers and drains its workers
  Given a supervisor with two workers
  When it drains
  Then both are accounted for
```
→ spec files: `spec/lain/isolation/worktree/handback/retirement_spec.rb` (AC 1-3),
`spec/lain/supervisor_spec.rb` (AC 4)

**Escalation triggers**
- **`supervisor_spec.rb` has 14 examples asserting exact ordered call logs** across
  `Isolation#acquire` / `WorkerHandoff#surrender` / `Lease#release`. A relocation should not change
  ordering — if any of those 14 fails, the move changed behaviour and must stop.
- `cli/epic_driver/factory.rb:145-164` builds a **different** `Retirement` than `Wiring` does
  (anchoring without merging). Both must keep working, and T3 folds that same file. If both cards are
  in flight, they collide — sequence T11 before T3 or expect a `NameError`.
- `isolation/worker_id.rb:12` points back at the tool subtree in a comment. After T11 and T12 the
  isolation subtree owns both leases and retirement; that comment becomes wrong. Fix it here.
- `Retirement::Anchor` shells to git. `pre-commit` exports `GIT_INDEX_FILE` into every hook
  (CLAUDE.md:249-250), so a spec that shells without scrubbing passes every normal run and fails at
  commit time. `isolation/worktree/registry.rb:213-215`'s `GIT_CONTEXT_SCRUB` is the existing answer —
  confirm the moved code uses it.

### T12 — Move `Subagent::Leases` into the isolation subtree   [wave 4] [risk: high]

**Depends on:** T11
**Files:** modify `lib/lain/tools/subagent.rb`; create `lib/lain/isolation/leases.rb`; modify
`lib/lain/isolation.rb`, `lib/lain/cli/wiring/toolset_build.rb`, `lib/lain/skill/role_spawn.rb`,
`lib/lain/isolation/worker_id.rb`; modify `spec/lain/tools/subagent_spec.rb`; create
`spec/lain/isolation/leases_spec.rb`
**Reuse:** `lib/lain/isolation/lease.rb` and `lease_lock.rb` already exist — the destination has the
vocabulary and the neighbours
**Shared-file wiring:** add `require_relative "isolation/leases"` to `lib/lain/isolation.rb`; remove
the `Leases` region's requires from `lib/lain/tools/subagent.rb`
**Reachable from:** `Leases` has three consumers **outside** the tool —
`cli/wiring/toolset_build.rb:379`, `:464`, `:466` and `skill/role_spawn.rb:70`; AC 1 drives a lease
through `toolset_build`

`Leases` spans `subagent.rb:784-966` — `Held` (`:788-801`), `Lane` (`:803`, reopened `:814-833`),
`InPlace` (`:848-874`) — 76 code lines owning **two `Monitor`s** and an ordinal sequence, and wrapping
`Isolation::Null`, `WorkerHandoff`, `SelfSync` and `WorkerId`. It is isolation-domain code living
inside a tool file, and it has more consumers outside the tool than in it.

A relocation, like T11. Keep the diff a move.

**Acceptance criteria**

```gherkin
Scenario: a lease is granted and released once
  Given a lease pool with one lane
  When a worker acquires and releases a lease
  Then the lane is free again

Scenario: two workers in one lane are serialized
  Given a lease pool with one lane
  When two workers acquire concurrently
  Then the second waits for the first

Scenario: a lease not reclaimed is reported
  Given a worker holding a lease that is never released
  When the pool is drained
  Then it reports the unreclaimed lease

Scenario: a role spawn takes a lease from the pool
  Given a role spawn requesting isolation
  When it spawns
  Then the worker holds a lease from the pool
```
→ spec files: `spec/lain/isolation/leases_spec.rb` (AC 1-3), `spec/lain/skill/role_spawn_spec.rb`
(AC 4)

**Escalation triggers**
- `Leases` owns **two `Monitor`s**. A relocation must not change lock acquisition order, and
  `spec/lain/tools/subagent_concurrency_spec.rb` is the pin. If it fails, the move changed ordering —
  stop.
- `subagent.rb`'s `Seam` has **14 members** (`:998-999`), several of which `Leases` reads. If moving
  `Leases` means the `Seam` must be passed into the isolation subtree, that is a dependency inversion
  — report it rather than importing a tool's value object into `isolation/`.
- `isolation/worker_id.rb:12` comments that `WorkerId` points back at the tool. After this card the
  pointer is backwards; fix it, and if `WorkerId` turns out to belong to the tool rather than to
  isolation, say so — that would make this card wrong in the opposite direction.
- `Leases::LeaseNotReclaimed` (`subagent.rb:748-754`) is defined **outside** the `Leases` region. Move
  it with the class, and check whether anything rescues it by its old path.

## Integration checks

After the last wave:

- `bundle exec rake pspec` green, **with the example count recorded and compared**. This plan deletes
  roughly a dozen spec files while rewriting ~40 examples in place, so the count moves in both
  directions — write the arithmetic out. A silent drop is how a dead worker hides.
- `bundle exec rubocop` clean, **with no new `rubocop:disable` and with at least some of the 61
  cop-citing comments removed**. If a card folded a class and left its "keeps each body within
  Metrics/ClassLength" comment in place, the comment now lies.
- **Report which `.rubocop.yml` `Style/Documentation` `AllowedConstants` entries became removable.**
  Do not edit the list — simplify-01's T2 owns it — but the list is the measure of this plan's effect
  and the report is how 01's T2 knows what to remove.
- `bundle exec rspec spec/lain/supervisor_spec.rb spec/lain/tools/subagent_concurrency_spec.rb spec/lain/session_concurrency_spec.rb`
  as a focused concurrency run — T10, T11 and T12 each move code that holds a lock or a Monitor, and
  those three specs are the pins.
- `bundle exec rspec spec/lain/provider/ollama --tag ~ollama` plus one deliberate failure with a cloud
  deployment as the subject, reading the output for a leaked key. T7's AC 4 cannot be trusted from a
  green suite alone.
- `for cmd in epic epic-graph epic-land epic-finish up; do lain $cmd --help; done` — T2, T3 and T4 all
  move command entry points, and a broken require surfaces as a command that will not load.
- **Manual, human:** one `lain up` cockpit opened and closed, confirming T2's fold left the status
  line and pane lifecycle intact. `up_spec.rb` covers three former subjects and a tmux pane inherits
  the spec runner's PATH, which CLAUDE.md:245-247 records as having hidden a status-127 failure for
  the life of a feature.
- **Manual, human:** one epic driven end to end through `/implement-epic`, since T3 and T4 between
  them rewrite the epic command surface and `planning/qa/scenarios/` has scenarios for it.
- Update `planning/qa/scenarios/` for any changed command name or refusal sentence.

## Execution log

**Base ref:** `main` at `b2f75202`. Every worktree is cut from that HEAD by hand, never by
`isolation: "worktree"` (which forks from `origin/main`, 270 commits behind).

**Grounding staleness.** The Grounding section was verified at `d2bb133c`; `main` is 270 commits
ahead of it, almost all of them simplify-01/-02/-03 landings. Line citations in the cards are
therefore approximate. Each implementer re-verifies its own card's cited `file:line` claims before
writing anything and reports drift: absorbable if the behavior is unchanged, escalated if the card's
premise no longer holds.

**Prerequisites checked at start:** simplify-01 `done`, simplify-02 `done` — both required by this
plan. simplify-03 was `in-progress` with twelve of thirteen cards landed; its last card touches
`tools/subagent.rb`, `cli/wiring/toolset_build.rb`, `cli/wiring/askers.rb`,
`tools/request_review.rb` and `cli/epic_submit/adjudication.rb`, so no card touching those was
started until it landed.

**T2 is held behind simplify-07's T6**, per that plan's contract: T6 strips the jq filter and
`JQ_MISSING_WARNING` out of `cli/up/hud.rb` before T2 deletes the file, so the fold carries ~30
fewer lines into `up.rb`. The other order loses T6's work or forces it to be redone.

### Findings escalated for their own cards

**The session record is noisiest on the file masking protects.** Found while folding
`Session::Journaled`. After a masked read, `ReadSet#complete?` is mask-suppressed, so the
read/re-read transition never closes and every subsequent complete read of that path journals
another `session_read` line — four reads, four lines, where an unmasked path journals one.
Meanwhile `Middleware::RedactSecretReads` dedupes its own `read_redacted` line on that same
transition rule, so the two halves of one event now disagree about whether it happened once. The
current behaviour is inherited unchanged from the decorator and is pinned by an example so it
cannot drift further, with the docstring naming the cause and saying plainly that pinned is not
blessed. Fixing it is a behaviour change and belongs in its own card.

**A `have_attributes` matcher renders a live credential.** Found while merging the Ollama
deployment arms. On ruby 4.0.6 super_diff's `Data` builder is inert, so an `eq` failure walks
instance variables and renders nothing — but `have_attributes(api_key:)` goes through the public
reader and prints the key into the failure output. Reported as pre-existing rather than introduced
by the merge, and under verification by the panel. If it stands it is the same class of defect as
the CI-log leak the redaction triple was written for, and the redaction triple does not cover it.

**An injected `paths:` never reaches the sensitivity classifier.** Found while folding the wiring
shards, proven with an executable red: a `Wiring` built with `paths:` anchored at a temporary home
produces a board that does not see `~/.kube/config` under that home and does see it under the
process's real `$HOME`, because `Wiring#switchboard` never threads `@paths` into `BoardBuild`.
Pre-existing — the call is byte-identical at the chunk's base — and inert in production, since
`CLI::ChatLaunch` is the only construction path and never passes `paths:`. What it costs is spec
fidelity at the secret boundary: a path-boundary spec has to swap `$HOME` through the environment
rather than through the keyword the constructor advertises, which is the shape a future
green-but-wrong secret-boundary spec grows in. One-line thread plus a spec, **sequenced with
simplify-02's T1**, which owns that method. Medium urgency, its own card.

**The epic-driver spec mirror is broken, and simplify-01's relaxation does not cover it.** Folding
`run.rb` and `issue_tests.rb` into `factory.rb` leaves `spec/lain/cli/epic_driver/run_spec.rb` and
`issue_tests_spec.rb` at paths whose source files no longer exist. They stay there by orchestrator
ruling: merging them would make one 1,160-line spec, and the argument first offered for keeping them
apart — that a merged file would hurt the parallel packer — is measurably false, because the packer
groups by **runtime** and the three files total 13.2 seconds against a 60.3-second floor. The merge
is invisible to the wall either way, so the packer is not the reason.

The honest statement is the one worth recording: 01 relaxed "one spec per code file" to "one spec
per public entry point", which licenses one spec covering several subjects. It does not license a
spec whose mirrored path has no file. This is a real breakage of a stated rule, accepted knowingly
for readability, and it should be revisited by whoever next moves this subtree rather than
inherited as though the rule had covered it.


### The quarantined card collided with nothing, and its acceptance criterion was undrivable

T11 was put alone in its own wave because it shared `lib/lain/cli/wiring.rb` with two other cards,
and because **a move conflicts silently — it drops half an extraction rather than failing**. The
caution was sound and the isolation cost nothing, but the collision was not real: **`CLI::Wiring`
constructs no `Supervisor::Retirement` at all.** The chat path takes the `Retirement::Null` default,
and what `Wiring` builds is its own unrelated `Wiring::Handback` Data. The card's Files list and its
"Reachable from" line both name `wiring.rb`; it was correctly left untouched.

Two consequences for the card's own text, so the record does not read as an unmet criterion. Its
first acceptance criterion says to drive a worker retirement **through the chat path** — not
drivable, because that path is the Null. And it describes the outcome as the worker's commits
becoming **reachable from the parent branch**, which is merging, and retirement never merges. The
spec that landed asserts the opposite and correct thing: the parent's state is byte-identical and
the commit sits under the ref. The spec is right; the criterion was wrong.

**The length cop's blind spot, measured on the largest move in the plan.** `supervisor.rb` lost
**139 of 349 code lines — 40%** — and `Metrics/ClassLength` moved by **3**, from 174 to 171, because
`Retirement` (54), `Anchor` (58) and `TurnMailbox` (15) were nested bodies it subtracts entirely. A
card gated on "stop if the result exceeds the raised limit" would have seen nothing in either
direction. `supervisor.rb`'s own comment still claims the split "keeps every class body within
Metrics/ClassLength instead of loosening it"; the three remaining bodies total 171 against a limit of
300, so that sentence was already false before this card and is left for whoever next edits it.

**A deletion took two live regression tests with it.** Removing `TurnMailbox` removed the only
non-Null `Agent#mailbox:` implementation — no production site passes one, so the deletion is right —
but two examples pinning a real `Agent` invariant went with it, and the tree stayed green without
them. Proven rather than assumed: reintroducing the historical defect the code's own comments
describe, capturing the mailbox *after* the provider round trip instead of before, leaves 17,730
examples passing and not one spec notices. They were `Agent` tests wearing a `TurnMailbox`
describe-block; they are rehomed onto `Lain::Agent` in T11's own commit rather than deferred.

### What the length cop can actually be trusted for: nothing, in either direction

This plan is built on folding back extractions a `Metrics/*` counter caused, so the counter's
accuracy is load-bearing for every card in it. Four cards measured it directly, and the result is
that `Metrics/ClassLength` cannot be trusted to report whether a fold made a file bigger or smaller.

| what happened | code lines | the cop moved |
|---|---|---|
| a class merge built and rejected | +428 source | 310, correctly over 300 |
| 75 lines absorbed into an adjudicator | +75 | +27 |
| a retirement moved out of the supervisor | −139 of 349 | −3 |
| leases moved out of a subagent tool | −226 raw | **0** |
| four error one-liners replaced by one class | **+17** | **−15** |

**The blind spot is `class`-shaped.** The cop subtracts nested `class` bodies entirely and counts
everything else — a `Data.define` block counts in full, which is why the adjudicator's +75 showed as
+27 (the one `Data.define` was visible, the four nested classes were not). The last row is the one
worth remembering: replacing four `class X < Error; end` one-liners with a single nested `Refusal`
class **grew the file by 17 code lines and improved the cop's number by 20%**, because the
one-liners had no body to subtract and the replacement does.

So a card's "stop if the fold exceeds the raised limit" trigger is not a detector, and a quiet
rubocop is not evidence that a fold left a class coherent. `Lint/DuplicateMethods` is the cop with
teeth here — it is what caught the rejected merge, by finding three collisions on public methods.
Everything else is a read.

**And ten files assert a constraint that binds none of them.** The sentence "keeps each class body
within Metrics/ClassLength instead of loosening it" appears in ten `lib/` files. Every one was
measured against the limit of 300:

| supervisor | restart | subagent | reline | tty | prompt_composer | completion | conductor | human_replies | shutdown |
|---|---|---|---|---|---|---|---|---|---|
| 151 | 97 | 185 | 125 | 120 | 49 | 57 | 124 | 116 | 118 |

**Not one binds.** Several were already false before simplify-01 raised the limit; the rest became
false when it did, and nothing re-read them. This is the plan's own Intent arriving at its logical
end — it counted sixty-one comments naming a `Metrics/*` cop as the reason code is shaped as it is,
and the cards that folded two of those files found the sentence false in both. A sweep belongs to
this plan's successor: the sentence is a load-bearing claim about why a file is shaped the way it
is, repeated ten times, true nowhere.


### Close-out

**All twelve cards landed.** Three refused part of what they were asked, each on measurement rather
than judgment, and each refusal was upheld by its panel: the four-way epic merge (310 against a
limit of 300, three duplicate-method collisions on public methods, and a `supervisor` name covering
two different objects); `board_build` (names no cop, states a second responsibility, and has callers
outside `lib/` that private methods cannot serve); and three of the six approval folds (a second
production caller, a documented composable abstraction with a parallel loop already in its
destination, and one of only two `Rule` subclasses assembled beside its sibling).

**What the plan got wrong, and it is worth reading before writing the next one of these.** The
contract asserted that every card produces a class over the length limit — false, and never
measured. One card's "Reachable from" named a constructor that does not exist, making its first
acceptance criterion undrivable. Another card asked for an incoherent artifact: fold a module's
functions but keep its nested class, which yields a file named for a module that builds nothing. And
the quarantine that isolated the riskiest card existed for a file collision that was not real.

None of that made the plan a bad one. Every card still found the thing it was pointed at. But the
grounding was a reachability audit over a constant graph, and five of its claims did not survive
someone opening the file.

**The measurement that outlives this plan** is in the length-cop section above: the counter this
entire plan exists to unwind cannot report whether a fold made a file bigger or smaller, and ten
files explain their shape with a limit none of them approach. That sweep is the successor's.
