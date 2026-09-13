# Simplify 03 — delete what nothing reaches, and move the test-only collaborators out of lib

status: done
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

A reachability audit over a scope-resolved constant graph found a set of units that nothing in `lib/`
or `exe/` constructs, and a second set that only specs construct — the latter sitting in production
constructors as keyword-argument defaults the code itself calls unsanctioned. This plan deletes the
first set, relocates the second to `spec/support`, and fixes the enumeration that was supposed to
track the first and missed six of them.

Delivers: two capabilities the repo's own deletability spec already certifies as removable; six dead
files; `Lain::Notify`; `core_exec`; two spec-only middlewares; a spec-only schema validator and an
uncalled method; the unused half of the tool contract vocabulary; `DerivationAudit`; Bedrock; eight
test-only Nulls out of `lib/`; and seven phantom YARD links.

## Grounding

Verified 2026-09-12 against the working tree at `d2bb133c`. Code lines are non-blank, non-comment.

**The repo ships a machine-checked deletability map.** `spec/lain/review/deletability_spec.rb` (493
lines, tagged `:seam`) holds `DeletionMap::CAPABILITIES` at `:74-211` — seven rows, each naming its
constants, files, consumers, edit sites and the capabilities it *forces*. `BootWithout` (`:295-328`)
makes a hardlinked `cp -al` copy of the tree, drops the named require lines, and boots it. Three rows
have **`consumers: []`**: `diagnostics`, `prefill`, and `epic_gate` (which owns no files and is
marked `untestable`).

`diagnostics` carries `forces: %w[prefill]`, and the reason is mechanical: `review/prefill.rb` reads
`Projection::Diagnostics` in its **class body** at `:230`, `:233` and `:238`, so removing diagnostics
alone leaves the tree unbootable. `deletability_spec.rb:483-491` is the negative control asserting
exactly that.

Two caveats the map states about itself. Its `edits` lists are checked **for staleness only, never for
completeness** (`:157-173`). And `BootWithout#drop_lines` (`:322-327`) drops only whole verbatim
lines, which is why every `edits` marker is a full `require_relative` line.

**The four dead files, each verified to have zero non-comment references outside itself and outside
`spec/`:**

| file | raw / code | require line | spec (raw) |
|---|---|---|---|
| `review/delta.rb` | 461 / 152 | `review.rb:21` | `review/delta_spec.rb` (578) |
| `review/annotations.rb` | 81 / 24 | `review.rb:30` | `review/annotations_spec.rb` (193) |
| `review/placement.rb` | 77 / 29 | `review.rb:19` | `review/placement_spec.rb` (70) |
| `approval/gate/recorded_policy.rb` | 95 / 33 | `approval/gate.rb:409` | `recorded_policy_spec.rb` (202) |

Three of these defeat a naive grep, which is why the audit needed a resolved graph: `Review::Delta` is
distinct from `Epic::Intake::Delta` (`epic/intake/delta.rb:63`); `Review::Annotations` is distinct from
`Epic::Review::Annotations` (loaded at `epic.rb:17`), which is the live one; and `Review::Placement`
collides with three unrelated `Placement` values in `cli/tmux_surface.rb:54`,
`forge/local_landing.rb:334` and `test_layout/guard.rb:71`.

`Review::Annotations` was also **extracted and then bypassed**: `AnnotationPlaced.new` is built
directly at `review/session.rb:373` and `review/session/replay.rb:171`, never through
`annotations.rb:62`.

**`arm/adaptive_router.rb` and `oracle/router.rb` are unreachable but NOT in this plan.** They are a
pair — router's only reference anywhere is `adaptive_router.rb:37`'s
`definition: Oracle::Router.definition` keyword default — and `ARCHITECTURE.md:858` claims *"Four arms
ship (`arm/{single_thread,orchestrator_worker,dual_ledger,adaptive_router}.rb`)"* while `exe/lain:568`
says "the three orchestration arms". Five lines in `Bench::LiveArms.build` would make the doc true and
63 code lines reachable, so **simplify-08 owns that decision**, exactly as it owns `Toolset::Disclosure`.
Deleting them here would settle by default a question that plan exists to ask.

**`Lain::Notify` is one 651-line file, not a subtree.** `lib/lain/notify/` does not exist. Internal
structure: `class Notify` `:52`, `class << self` `:129`, `Dispatch` `:480`, `Withdrawals` `:544`,
`Onscreen` `:568`, `Null` `:645`. Required at `lib/lain.rb:76`; spec is 1,321 lines. Six references:
one real factory call at `cli/wiring.rb:190` (`Lain::Notify.for(desktop:, journal:)`) and four
`Notify::Null.new` keyword defaults (`cli/epic_mount.rb:165`, `cli/repl.rb:29`,
`cli/wiring/askers.rb:33`, `tools/request_review.rb:193`). It is also excluded from
`ThreadSafety/NewThread` at `.rubocop.yml:301`.

**`core_exec` has a reference a constant sweep cannot see.** `tools/core_exec.rb` is 148 / 55,
required at `tools.rb:24`, spec 295 lines. One constant reference — `bin/demo-core:59` — plus **four
tool-NAME string sites**: `sensitivity/policy.rb:78` (`"core_exec" => "cwd"`),
`approval/escalation.rb:399` (`COMMAND_TOOLS = %w[bash core_exec]`), `friction/report.rb:32`
(`TIER_3_TOOL_NAMES = %w[bash core_exec]`), and a comment at `approval/composed_term.rb:105`.
Spec-side: `spec/support/tool_registry.rb:63`, `spec/tool_bounds_discipline_spec.rb:292`.
`Exec::Core` itself stays — `grep` has its own daemon path.

**Two middlewares are inline, not files.** `lib/lain/middleware/logging.rb` and
`middleware/timeout.rb` **do not exist**. `Middleware::Logging` is `middleware.rb:169-197`
(`DEFAULT_FORMATTER` at `:176-178`) and `Middleware::Timeout` is `:207-257` (`Exceeded < Error` `:210`,
`DEADLINE_KEY` `:213`, a `declare` block `:219-230`, `#call` `:243-256`). Neither has a production
consumer; both are constructed only in `spec/lain/middleware_spec.rb` (`:107`, `:130`). So deleting
them is an **edit to a shared file**, and the deletability-map idiom of "one row, one verbatim require
line" does not transfer.

`Timeout` is additionally cited **as a testing precedent** by comment in three lib files
(`frontend/tty.rb:63`, `frontend/neovim/compose.rb:103`, `cli/shutdown.rb:70`) and two specs
(`frontend/neovim/compose_spec.rb:281`, `cli/shutdown_spec.rb:77`). Its own doc concedes it *"does
NOT preempt"*.

**A validator with one caller, and a method with none.** `Tool::SchemaValidator` is
`tool.rb:295-395`, inside the reopened `Tool` half, and its docstring `:293-294` says it lives there
*"so the validator's size is measured on its own"*. Exactly one caller: `tool.rb:197`, reached only
when `input_model` is falsy (`:195` returns early otherwise). **Zero references in `spec/`.**
`Tool#dig` (`:175-180`) has **zero callers anywhere** — the only receiverless `dig(` in the repo is
`SchemaValidator`'s own private duplicate at `:383-388`. The two bodies are byte-identical.

**Half the contract vocabulary is unused.** In `tool/contracts.rb`: `.ensures` `:52-58`,
`.postconditions` `:67-69`, `.own_postconditions` `:76-78`, `#check_postconditions!` `:180-185`.
`.ensures` has **zero `lib/` callers** — all four call sites are specs (`tool_spec.rb:174`,
`contracts_spec.rb:17`, `:55`, `:133`). The precondition mirror is live: `.requires` has five `lib/`
declarations (`edit_file.rb:55,72,79`, `write_file.rb:47,59`) and `#check_preconditions!` is called
from `tool.rb:134`. **`Tool::ContractViolation` must survive** — `tool.rb:28`, raised at
`contracts.rb:188`, with **29 `raise_error` assertions across 7 spec files**, and
`effect/handler/live.rb:78-80` special-cases it in a comment.

**`DerivationAudit` has zero callers** and pulls runtime `Algebra.registry` reads onto the live
compaction path: `derivation_audit.rb` 319 / 116, required at `compaction.rb:13`, spec 498 lines, plus
`derivation_audit/{edge,diagnosis,finding}.rb` (84/38, 47/19, 108/54) required from its own `:317-319`.
It reads the registry at `:277` (`declares?`) and `:283` (`refutations`) — **the registry's only
non-declaring reader in `lib/`**. `Compaction::Derivation` (310 lines) **is** live and stays.

**Bedrock.** `provider/bedrock.rb` 119 / 49 (require `provider.rb:144`),
`provider/bedrock/transport.rb` 44 / 19, `provider/http/providers/bedrock.rb` 50 / 28 (require
`provider/http.rb:25`, self-registering at its own `:50`). Two `lib/` references:
`cli/backend.rb:179` and `:457`. Specs: `bedrock_spec.rb` (230), `bedrock_parity_spec.rb` (14),
`bedrock_reference_spec.rb` (179), `spec/support/provider_oracles/bedrock_reference.rb` (150).
Deleting `provider/http/providers/bedrock.rb` also removes `Registry.resolve`'s **only two references
anywhere** (`spec/lain/provider/http/providers/bedrock_spec.rb:16`, `:22`).

**`HTTP::Provider::Registry`**: `provider/http/provider/registry.rb`, 36 lines, mixed in at
`provider.rb:49`. `#providers` `:19-21` — zero `lib/` callers, four spec. `#resolve` `:30-32` — zero
`lib/` callers, two spec. **`#register` `:25-28` is live** with two production callers
(`providers/bedrock.rb:50`, `providers/anthropic.rb:74`) because it populates
`Configuration.register_provider_options`. Nothing resolves a provider by slug at runtime —
`cli/backend.rb:179` uses a literal `case`.

**`spec/output_discipline_spec.rb`** is 145 lines. `OutputDiscipline.violations` (`:104-111`) globs
**only `lib/**/*.rb`**, skipping `EXEMPT_PREFIXES = ["lain/frontend/"]` (`:26`), and its
**`ALLOWLIST` at `:32` is empty** — so it currently passes with zero exemptions. It parses with
`Ripper.sexp`.

**`Telemetry::Guards` does not exist.** No `guards.rb`, no `module Guards` anywhere. Eight phantom
YARD links in seven `lib/` files: `middleware/redact_secret_reads.rb:184`,
`provider/admission.rb:480`, `mode/switch.rb:43`, `approval/policy_switch.rb:50`,
`review/records/corpus_extended.rb:31`, `session.rb:324`, `compaction/derivation_audit.rb:28`,
`session_record/replay.rb:145`; plus one in `spec/lain/approval/policy_switch_spec.rb:107`. The real
homes are `Telemetry::Carriers` (`telemetry.rb:39`) and the flat files. One of the eight is in
`derivation_audit.rb`, which this plan deletes — so seven remain.

**The eight test-only collaborators, and the correction that matters.** Most are **production keyword
defaults**, so the move is "delete the default and pass explicitly", not a relocation:

| thing | defined | kwarg default? | `lib/` refs | `spec/` refs |
|---|---|---|---|---|
| `Subagent::NoAskers` | `tools/subagent.rb:452-470` | **yes**, `:1024` | 4 (def, inspect, default, one comment) | 4 (1 assertion) |
| `ToolsetBuild::NoSwitchboard` | `cli/wiring/toolset_build.rb:114-142` | **yes**, `:267` | 5 | 8 (2 assertions, both negative) |
| `Wiring::Askers.unwired` | `cli/wiring/askers.rb:32-34` | **yes**, `:267` | 3 | 1 |
| `AskHuman::Directory::Null` | `tools/ask_human/directory.rb:200-203` | no | **0** | 1 |
| `TmuxSurface#session` | `cli/tmux_surface.rb:196-201` | n/a | **0** | 2 |
| `WindowState#survived` | `cli/tmux_surface.rb:66-68` | n/a | field written at `:141`,`:144`; **read nowhere** | 7 |
| `Subagent`'s `@last_*` + `#remember` | `tools/subagent.rb:71`, `:267-271` | n/a | no reader | **44** |
| `RequestReview::NoNotes` | `tools/request_review.rb:164-166` | **yes**, `:193` | 2 (def, default) | **0** |

`subagent.rb:445-446` documents `NoAskers` as *"NOT a sanctioned production state"*;
`toolset_build.rb:105-107` says the same of `NoSwitchboard`; `askers.rb:27-31` of `unwired`. And
`subagent.rb:265-266` calls `#remember` *"The ONE place the `@last_*` ivars are set, all at once with
no yield between"* — while `subagent_concurrency_spec.rb:245` records a real past race on
`@last_child`. Its own comment names the replacement: *"an actor's record rides its events instead."*

**`spec/support` is 3,647 code lines in 64 files** (not the 8,663 raw), organized as one file per
suite concern — VCR, WebMock, watchdog, tags — plus 4 matchers, 20 shared examples, 2 provider
oracles. **There is no home for doubles or Nulls.** `spec/spec_helper.rb:40` globs
`support/**/*.rb` recursively, so a new subdirectory needs no manifest edit.

**Four specs test spec helpers**: `support_matchers_spec.rb` (171),
`support_vsock_availability_spec.rb` (310), `support_watchdog_spec.rb` (112),
`support_store_fetch_count_spec.rb` (106).

**Where docs and code disagreed.** `ARCHITECTURE.md:858` on four arms (three ship);
`ARCHITECTURE.md:338-339` cites `Handler::Recorded` as a deterministic-replay handler while its
`from_journal` reads a `type: "tool_result"` record **nothing in `lib/` writes** — noted here but out
of scope, since it is not on the deletion list. Both are corrected by the cards that touch them.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lib/lain/review.rb`,
  `lib/lain/tools.rb`, `lib/lain/arm.rb`, `lib/lain/oracle.rb`, `lib/lain/compaction.rb`,
  `lib/lain/provider.rb`, `lib/lain/provider/http.rb`, `lib/lain/approval/gate.rb`,
  `lain.gemspec`, `.rubocop.yml`, `spec/spec_helper.rb`, `spec/support/tool_registry.rb`.
- Every card here hands back one or more `require_relative` removals. They are one-line diffs and
  several land in the same index file (`review.rb` takes four), so the orchestrator batches them per
  commit rather than per card — **but each removal must land in the same commit as the file it
  loads**, per CLAUDE.md's committing rule, or the suite loads a deleted constant.
- **`lib/lain/middleware.rb` is task scope for T5, not wiring.** The two middlewares are inline in it.
- This plan assumes **simplify-01 has landed** only for T9, which creates `spec/support/nulls/` and
  would otherwise fight the spec-mirror rule. The other cards are independent of 01.

## Open decisions

- **`Toolset::Disclosure`, `tool_search` and `DisclosureSweep` are deliberately NOT in this plan.**
  They are unreachable today, but simplify-08 owns the decision of whether to wire
  `bench disclosure-sweep` instead — deleting them here would settle by default a question that plan
  exists to ask. Recorded so their absence reads as intent.
- **`arm/adaptive_router.rb`, `oracle/router.rb`, `Arm::Ladder` and `oracle/prune_scoring.rb` are all
  deferred to simplify-08.** The first pair could be **wired** in five lines rather than deleted. `Ladder` has
  three consumers (`arm/epic.rb:115`, `one_shot.rb:48`, `plan_only.rb:73`, each `def rungs`), and
  `prune_scoring` has two in `bench/decider_sweep/arms.rb:108`, `:110` — so both are tied to whether
  the bench arms get wired.
- **Whether `Middleware::Timeout`'s testing precedent survives its deletion.** T5 keeps the three lib
  comments that cite it as an idiom, rewritten to name the idiom rather than the class. If the panel
  would rather keep the class for that reason, T5 shrinks to `Logging` alone.

## Execution log

**Base:** `main` at `a4cc9f22`. `origin/main` is 195 commits behind — worktrees are cut from
`HEAD` by hand, never from `origin/main`.

**Staleness re-check, 2026-09-12, `d2bb133c..a4cc9f22` (17 commits).** `lib/` moved in 29 files;
nothing this plan deletes was touched. Every deletion target, require line and spec file named
above still exists at the path given. Drift and corrections:

- **T12's "five confirmed-dead constants" claim is false, and was false at grounding.**
  `compaction/source.rb`, `provider/response_wal.rb`, `compaction/need.rb` and
  `strategy/composed.rb` are byte-identical to `d2bb133c`, and all five constants have live
  construction sites in their own files: `IdleGap` at `source.rb:364`, `Scheduling` at `:365`,
  `StreamingFrame` at `response_wal.rb:267`, `Manual` in `need.rb:121`'s `DETECTORS` and again at
  `:130`, `Untagged` raised at `composed.rb:145`. Three are `private_constant`, which is most
  likely what the audit mistook for unreachable. **T12 shrinks to the registry half** —
  `#providers` and `#resolve` — and the five constants stay.
- **T3 has a site the grounding missed.** `cli/up/pane_command.rb:59` `CONSENT_ENV = %w[LAIN_DESKTOP]`
  is real code, with a 25-line comment above it explaining why desktop consent is a second list;
  `up_spec` pins `PANE_ENV` against `exe/lain`. Four further comment references:
  `approval/escalation.rb:557`, `frontend/neovim/approval_view.rb:17`, `exe/lain:1044`,
  `cli/epic_mount.rb:147`.
- **T4 has a fifth name-string site:** `effect/handler/sensitivity.rb:16` names `core_exec` in a
  comment beside `write_file`/`edit_file`/`bash`.
- **T8's `--provider` enum is not in `exe/lain`.** Six `exe/lain` sites interpolate
  `Lain::CLI::Backend::PROVIDERS` (`backend.rb:51`), which is T8's own file — so that wiring line
  needs no orchestrator edit. `provider.rb:134` also names `Provider::BedrockReference` in a comment.
- **Line drift only:** `.rubocop.yml` `:301`→`:341`, `:340`→`:382`, `:214`→`:260`;
  `sensitivity/policy.rb:78`→`:82`; `cli/backend.rb:179`→`:183`, `:457`→`:465`.
  `CLAUDE.md:146` is unchanged.
- **Dependencies resolved:** simplify-01 and simplify-02 are `done`, so T9 may create
  `spec/support/nulls/` and T10 owns the `CLAUDE.md` citation fix outright. simplify-14 is still
  `draft`, so **T13 takes the cheap option** — add rows, do not replace the map with a sweep.


**Baselines at `060bd46a`**, for the Integration checks' arithmetic:

- `bundle exec rspec --dry-run` (default-excluded tiers off): **18,013 examples**, 1 pending.
- Examples in the spec files this plan deletes wholesale: prefill 70, diagnostics 15, delta 40,
  annotations 17, placement 10, recorded_policy 13, notify 60, desktop_discipline 3, core_exec 4,
  derivation_audit 34, bedrock 11, bedrock_parity 16, bedrock_reference 9, http/providers/bedrock 6,
  output_discipline 3 — **311 total**. Cards that edit a surviving spec file move the count further.
- `yard-lint` whole-tree **cannot be run from the repo root while this chunk is in flight**: the
  card worktrees live at `tmp/worktrees/` inside the project and yard-lint globs them, so it parses
  a sibling card's half-deleted files and dies on `Errno::ENOENT`. Run it inside a single worktree,
  or after the worktrees are retired.


**Findings from execution, as cards land:**

- **T2 deletes three files, not four. `lib/lain/review/annotations.rb` stays.** The Grounding's
  "zero non-comment references outside itself and outside `spec/`" excluded specs by fiat, and a
  spec is where its only consumer lives: `spec/lain/frontend/neovim/annotate_spec.rb:272` calls
  `Lain::Review::Annotations.settle` as the subject under test, driven through a real nvim
  harness, and `frontend/neovim/runtime/48_annotate.lua:148` names the module as the wire
  contract for the payload. The class is bypassed in `lib/` — `review/session.rb:373` and
  `session/replay.rb:171` build `AnnotationPlaced.new` directly — but that makes it a
  test-only-collaborator question of T9's shape, not a deletion. `review.rb:30`'s require stays.
- **`spec/lain/epic/intake/delta_spec.rb` does not exist.** T2's AC 3 named it; the live epic
  intake delta coverage is in `spec/lain/epic/intake_spec.rb`.
- **T6 lands two of its three removals. `Tool::SchemaValidator` stays.** The Grounding's
  "24 of 25 tools declare an `input_model`, and the 25th is nullary" undercounted: there are 26,
  and `lib/lain/bench/variance_fixtures.rb:34-41`'s `DosingLookup` is a live `lib/` tool with no
  `input_model` and a *required* raw-schema field, driven through a real `Agent#ask`. Its comment
  at `:29-33` says the raw schema is deliberate — byte-stability must not couple to
  `Tool::Input`'s JSON-Schema generator — so converting it would break the committed-fixture byte
  identity it exists to protect. "Zero spec references" was also a constant-name grep:
  `tool_spec.rb`'s `describe "input validation"` is six examples that *are* the validator's spec,
  reached through `#call`. Card AC 2 does not land. `Tool#dig` and the whole postcondition half
  did land.
- **The `Composable`/`Composed`/`Identity` trio and `monoid on: :>>` are KEPT** — panel ruling,
  no follow-up card. They are spec-only in the sense T5 reported, but that was judged not to be the
  test: `Composable` is what makes "a stack is itself a middleware" true rather than coincidental,
  `Identity` is the Null Object the style rule mandates over an `if middleware` guard and nine spec
  files seed with it, and deleting it takes the property test that makes the monoid law *checked*.
  CLAUDE.md's "a property-tested monoid" and ARCHITECTURE.md would both become false — trading one
  stale citation for two.
- **T1 owns the two executed rows in `deletability_spec.rb`, not T13.** A map row certifying a
  capability as removable is a claim about files that must still exist, so it has to change in the
  same commit as the deletion or the tree is red. T1 removes the `diagnostics` and `prefill` rows
  and re-points the negative control at another row with a non-empty `forces:`; T13 keeps all
  additive work.
- **T4 grew from five name-string sites to eighteen**, twelve of them YARD `{Tools::CoreExec}`
  links in the exec seam's own files. And `core_exec_spec.rb` held the only `:vsock` block driving
  a real attached daemon end to end, so no spec exercises the vsock transport after that card.
- **T10 does NOT delete `spec/output_discipline_spec.rb`. Panel ruling, matching the
  implementer's own recommendation.** The card's premise — that the Journal's own fd already
  provides the guard's stated justification — is true but incomplete. The fd closes the
  record-corruption path (verified by mutation: pointing `journal.rb:53` at `$stderr`, or splitting
  the write outside the Monitor, both redden the new specs). It does not close the **cockpit**
  path: `frontend/tty.rb` takes the alternate screen and drives Reline, so a `warn` from `lib/`
  lands on fd 2 in that surface, unguarded and invisible to CI. The clinching evidence is that
  `provider/http/logging/sink_logger.rb` exists *because* the guard forced someone to shim a gem
  defaulting to `$stdout` — the rule doing work no scan can score. Cost is 0.997s against a
  MAX-over-files wall, and the empty `ALLOWLIST` means 718 files at 100% compliance: a guard
  working, not a dormant one. "Narrow it to the Journal's own writers" is not a real option —
  `journal.rb` contains no terminal write, so a scan scoped to it asserts nothing.
  **The card shrinks to a correction:** rewrite the spec's header to name the cockpit rather than
  the NDJSON record, keep the three new journal/sink specs that pin the fd guarantee, fix
  `CLAUDE.md:146` and `docs/GLOSSARY.md:554` (both state the false model), and correct
  `spec/lain/tools/subagent/stagger_spec.rb:136-140`, which asserts stray stderr would interleave
  into the NDJSON — it cannot. The deletion would have orphaned 33 citation lines across 29 files,
  none of which go red.
- **T7's lost store-growth assertion is coverage of the deleted object**, not of compaction:
  general store-growth-on-success and no-growth-on-refusal both survive in
  `spec/lain/compaction/derivation_spec.rb`. Nothing needs to move.

**Landed on `main`, in order:** `7e95b507` T2, `b19ddf6f` T7, `7550c0f4` T11, `7ee4d091` T6,
`5755fc3a` T10, `eef0a314` T5. Each was panel-reviewed, took a fix round, and went in green
through the hook's full suite.

**A known flake tripped a landing once and is not a regression:** `neovim_runtime_spec`'s
`carries the wrapped command unwrapped, with the rendered lines unchanged`, documented in
`docs/toolchain-traps.md` (added 2026-08-28) as failing in isolation while passing under the whole
suite, with the note that a `pspec` will trip it occasionally too. It passed on the retry with no
change to the tree.

## Waves

Wave 1: T1, T2, T3, T4, T5, T6, T7, T8, T10, T11, T12
Wave 2: T9 (←T1..T8, for a clean tree), T13 (←T1, T2)
Critical path: T1 → T13

Wave 1 is wide because these are independent deletions in different subsystems. T9 follows the
deletions so it relocates Nulls belonging to code that still exists. T13 follows T1 and T2 because it
records what they did.

## Tasks

### T1 — Execute the two certified deletability rows   [wave 1] [risk: low]

**Depends on:** none
**Files:** delete `lib/lain/review/prefill.rb`, `review/prefill/finding.rb`,
`review/prefill/sidecar.rb`, `review/projection/diagnostics.rb`,
`lib/lain/frontend/neovim/runtime/49_diagnostics.lua`,
`spec/lain/review/prefill_spec.rb`, `spec/lain/review/projection/diagnostics_spec.rb`;
modify `lib/lain/frontend/neovim.rb`, `lib/lain/prompt/templates/skill/critique/skill.md`;
delete `lib/lain/prompt/templates/skill/critique/sidecar.md`
**Reuse:** `spec/lain/review/deletability_spec.rb`'s `diagnostics` and `prefill` rows already name
every file and edit site; `BootWithout` (`:295-328`) is the existing proof harness
**Shared-file wiring:** remove `require_relative "review/projection/diagnostics"` and
`require_relative "review/prefill"` from `lib/lain/review.rb` (`:47` and `:51`)
**Reachable from:** deliberately **deferred — nothing constructs either capability today**; that is
the premise, certified by `deletability_spec.rb`'s `consumers: []` on both rows. Recorded in Open
decisions as intent rather than oversight. AC 4 asserts the tree boots without them, which is the
production-path check available for a capability with no production path.

Both rows go **together**: `diagnostics` carries `forces: %w[prefill]` because `prefill.rb` reads
`Projection::Diagnostics` in its class body at `:230`, `:233`, `:238`.

Two edit sites the map names that a comment-stripping sweep cannot see:
`frontend/neovim.rb:59-60` mentions `__lain.set_review_diagnostics` in the **protocol-history
comment**, and the Lua module is globbed by `runtime_loader.rb:151` rather than required, so its
removal is a file deletion with no require line.

`prefill.rb` is itself an index — its `:316-317` require its two subtree files — which is the one
case `deletability_spec.rb:415-418` was written to allow.

**Acceptance criteria**

```gherkin
Scenario: the tree boots with both capabilities removed
  Given the deletion map's diagnostics and prefill rows
  When the tree is booted without them
  Then it loads

Scenario: removing diagnostics alone is still refused
  Given only the diagnostics row removed
  When the tree is booted
  Then it fails, naming Diagnostics

Scenario: the injected editor runtime no longer offers the diagnostics rail
  Given a live editor with the runtime injected
  When its lain functions are listed
  Then no review-diagnostics function is present

Scenario: a review still opens and settles
  Given a changeset
  When a review is opened and settled
  Then its verdict is reported
```
→ spec file: `spec/lain/review/deletability_spec.rb` (AC 1, AC 2 — both already exist and must stay
green), `spec/lain/frontend/neovim_runtime_spec.rb` (AC 3), `spec/lain/review/session_spec.rb` (AC 4)

**Escalation triggers**
- `deletability_spec.rb`'s `edits` lists are checked **for staleness only, never for completeness**
  (`:157-173`). If the boot succeeds but some *other* file references a deleted constant in a
  non-require position, the map did not promise to catch it — grep before trusting green.
- `runtime_loader.rb:170-178`'s `refuse_collisions` enforces that two runtime modules cannot share a
  load position. Deleting `49_diagnostics.lua` leaves a gap in the `NN_` sequence; if anything asserts
  the sequence is contiguous, stop.
- The critique skill template references a sidecar. If deleting `sidecar.md` changes a prompt the
  model reads, that is a product change — report the diff rather than assuming it is mechanical.

### T2 — Delete four files nothing references   [wave 1] [risk: low]

**Depends on:** none
**Files:** delete `lib/lain/review/delta.rb`, `review/annotations.rb`, `review/placement.rb`,
`lib/lain/approval/gate/recorded_policy.rb` and their four spec files
**Reuse:** nothing — this is removal. The verification method is a scope-resolved reference check,
not a leaf-name grep, for the reason below.
**Shared-file wiring:** remove `require_relative` at `lib/lain/review.rb:19`, `:21`, `:30` and
`lib/lain/approval/gate.rb:409`
**Reachable from:** deliberately **deferred — none of the four is constructed anywhere**; that is the
finding. Recorded in Open decisions. AC 1 is the production-path check that survives: the suite and
every CLI command still work.

**Three of these defeat a leaf-name grep and the card must not use one.** `Review::Delta` is not
`Epic::Intake::Delta`; `Review::Annotations` is not `Epic::Review::Annotations` (the live one);
`Review::Placement` collides with three unrelated `Placement` values. Resolve each reference to its
qualified path before concluding.

`Review::Annotations` was extracted then bypassed — `AnnotationPlaced.new` is built directly at
`review/session.rb:373` and `session/replay.rb:171`. Note that in the commit message: the class was
dead because its callers stopped using it, not because the feature went.

**Acceptance criteria**

```gherkin
Scenario: every CLI command still runs
  Given the six files deleted
  When each top-level command is invoked with no arguments
  Then none fails to load

Scenario: the live annotation path is untouched
  Given an epic review with an annotation
  When the annotation is resolved against the file on disk
  Then its drift is reported

Scenario: the epic intake delta still reports a mismatch
  Given a written epic document and a diverged copy on disk
  When the delta is computed
  Then it reports the mismatch
```
→ spec files: `spec/lain/epic/review_spec.rb` (AC 2), `spec/lain/epic/intake/delta_spec.rb` (AC 3),
`spec/lain/cli_spec.rb` or the existing command-surface spec (AC 1)

**Escalation triggers**
- If any of the six has a reference through `const_get`, a string, or a YAML/JSON fixture naming the
  class, a constant sweep will not see it. Check `spec/fixtures/` and the `.lain/` templates before
  deleting — `core_exec` in T4 is the proof that name-strings hide references.
- `Gate::Policies`' catalog (`approval/gate/policies.rb:126-143`) builds four policies by name.
  `RecordedPolicy` is **not** registered there, which is why it is dead — but confirm that before
  deleting, because a policy reachable only by config name would not appear in a constant graph.
- If a fifth unreachable file turns up in the same neighbourhood, **do not add it to this card**.
  Report it — the `adaptive_router` case is the precedent: an unreachable unit may be a wiring decision
  rather than a deletion, and simplify-08 is where those are made.

### T3 — Delete `Lain::Notify`   [wave 1] [risk: low]

**Depends on:** none
**Files:** delete `lib/lain/notify.rb`, `spec/lain/notify_spec.rb`,
`spec/desktop_discipline_spec.rb`; modify `lib/lain/cli/wiring.rb`, `lib/lain/cli/epic_mount.rb`,
`lib/lain/cli/repl.rb`, `lib/lain/cli/wiring/askers.rb`, `lib/lain/tools/request_review.rb`
**Reuse:** the four `Notify::Null.new` defaults are replaced by dropping the keyword entirely — the
collaborator's absence is the new default, not a different Null
**Shared-file wiring:** remove `require_relative "lain/notify"` from `lib/lain.rb:76`; remove the
`ThreadSafety/NewThread` exclusion at `.rubocop.yml:301`; remove the `--desktop` flag declaration
from `exe/lain`.
**`.rubocop.yml` and `exe/lain` are orchestrator-owned here** — T3, T8 and T10 each need a line in one of
them, and an earlier draft listed them under **Files**, which the lint forbids and which would have put
three wave-1 cards on one file.
**Reachable from:** the one production construction is `CLI::Wiring:190`
(`Lain::Notify.for(desktop:, journal:)`); AC 1 asserts a chat assembles without it, driven through
`CLI::Wiring` rather than a double

`Notify` is a third approval surface alongside the TTY prompt and `auto_approver` — 170 code lines
plus a 1,321-line spec, carrying `Dispatch` (thread-per-shellout), `Withdrawals`, and an `Onscreen`
registry with a `HANDLE_ID_FLOOR` id space chosen to avoid dunst's close-reason codes. Its own
comment at `:47-51` records that `#decide` has no caller in `lib/` or `exe/`.

`spec/desktop_discipline_spec.rb` exists because agents once fired **nine real notifications onto a
working human's desktop** (2026-08-05). That guard goes with the thing it guards — say so in the
commit message, because the incident is the reason the file existed.

**Acceptance criteria**

```gherkin
Scenario: a chat assembles with no desktop surface
  Given a chat wired the way the CLI wires one
  When its approval surfaces are listed
  Then the terminal surface is present
  And no desktop surface is present

Scenario: a parked approval still reaches the human
  Given a chat with an approval parked
  When the terminal surface is drained
  Then the approval is presented

Scenario: the desktop flag is gone
  When the CLI's chat options are listed
  Then no desktop option is offered

Scenario: an approval is still journaled when it settles
  Given a parked approval
  When it is answered
  Then the journal holds its decision
```
→ spec files: `spec/lain/cli/wiring_spec.rb` (AC 1), `spec/lain/cli/switchboard_spec.rb` (AC 2, AC 4),
`spec/lain/cli_spec.rb` (AC 3)

**Escalation triggers**
- `spec/approval_consumer_discipline_spec.rb` exists because `Notify` once **took** the approval
  queue, leaving `--no-nvim` with no approval surface. That guard is about the queue having a consumer
  and must stay — if deleting `Notify` makes it fail, the queue's remaining consumer is not what the
  guard expects, and that is a real finding.
- `planning/remote-surface-research-2026-08.md` names `Lain::Notify` as **the template** for a phone
  frontend. Deleting it discards that template. Report it; the research doc should be annotated
  rather than silently invalidated.
- Its own comment claims *"decision latency IS the experiment record"*. Confirm nothing reads approval
  latency before accepting that claim as dead — if something does, the latency plumbing is separable
  from the desktop surface.

### T4 — Delete `core_exec`, including the four name-string sites   [wave 1] [risk: medium]

**Depends on:** none
**Files:** delete `lib/lain/tools/core_exec.rb`, `spec/lain/tools/core_exec_spec.rb`,
`spec/support/shared_examples/exec_boundary_parity.rb`; modify
`lib/lain/sensitivity/policy.rb`, `lib/lain/approval/escalation.rb`,
`lib/lain/friction/report.rb`, `lib/lain/approval/composed_term.rb`,
`lib/lain/cli/exec_backend.rb`, `spec/tool_bounds_discipline_spec.rb`; delete `bin/demo-core`
**Reuse:** `Tools::Bash` remains the only exec tool; `Exec::Core` and `crates/lain-core` **stay** —
`grep` has its own daemon path
**Shared-file wiring:** remove `require_relative "tools/core_exec"` from `lib/lain/tools.rb:24`;
remove the `CoreExec` entry from `spec/support/tool_registry.rb:63`
**Reachable from:** deliberately **deferred — `Tools::CoreExec.new` appears nowhere in `lib/` or
`exe/`**; the only constant reference is `bin/demo-core:59`, itself broken since
`Core::Client.start`'s signature changed 131 commits ago. AC 4 asserts the production toolset never
offered it.

**The four name-string sites are the point of this card.** A constant sweep sees only
`bin/demo-core:59`; the tool's *name* appears at `sensitivity/policy.rb:78`,
`approval/escalation.rb:399` (`COMMAND_TOOLS`), `friction/report.rb:32` (`TIER_3_TOOL_NAMES`), and in
a comment at `composed_term.rb:105`. Each is a table keyed by tool name, and each must lose its entry.

`spec/support/shared_examples/exec_boundary_parity.rb` (135 lines) is the bash↔daemon output-parity
witness. Deleting `core_exec` removes its subject. Say in the commit message that the parity claim
goes with it — `spec/lain/core/grep_parity_spec.rb` remains for the grep arm.

**Acceptance criteria**

```gherkin
Scenario: the production toolset offers one exec tool
  Given a toolset built the way the CLI builds one
  When its tool names are listed
  Then bash is present
  And core_exec is absent

Scenario: a shell command is still gated on its risk
  Given a command the approval rules treat as risky
  When it is proposed
  Then it is parked for approval

Scenario: the friction report still classifies shell usage
  Given a journal holding bash calls
  When the friction report is rendered
  Then it counts them

Scenario: the sensitivity policy still knows bash's path field
  Given a bash invocation with a cwd
  When the policy is asked which input carries its path
  Then it answers cwd
```
→ spec files: `spec/lain/cli/wiring/base_tools_spec.rb` (AC 1), `spec/lain/approval/escalation_spec.rb`
(AC 2), `spec/lain/friction/report_spec.rb` (AC 3), `spec/lain/sensitivity/policy_spec.rb` (AC 4)

**Escalation triggers**
- `approval/escalation.rb:399`'s `COMMAND_TOOLS` and `friction/report.rb:32`'s `TIER_3_TOOL_NAMES`
  are both **two-element arrays**. If either becomes a one-element array that some spec asserts the
  length of, that assertion is now about a different claim — report it rather than editing the number.
- `spec/tool_bounds_discipline_spec.rb:292` names `core_exec`. That spec exists because the
  bounded-tool list was prose in a planning doc and **went stale twice**. Removing an entry from it is
  correct; removing the *check* is not.
- `bin/demo-core` is already broken (`Core::Client.start(paths:)` vs `start(transport:)`). Deleting it
  is right, but confirm no `.claude/` skill or CI step invokes it first.
- If `Exec::Core` or `Core::Client` loses its last spec-side consumer when
  `exec_boundary_parity.rb` goes, say so. The daemon stays by ruling; it should not silently lose its
  coverage.

### T5 — Delete two spec-only middlewares from `middleware.rb`   [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `lib/lain/middleware.rb`, `spec/lain/middleware_spec.rb`,
`lib/lain/frontend/tty.rb`, `lib/lain/frontend/neovim/compose.rb`, `lib/lain/cli/shutdown.rb`,
`spec/lain/frontend/neovim/compose_spec.rb`, `spec/lain/cli/shutdown_spec.rb`
**Reuse:** `Middleware::Stack` is the only composition production uses and stays untouched
**Shared-file wiring:** none — `lib/lain/middleware.rb` is task scope here, since the two classes are
inline in it (`:169-197` and `:207-257`) rather than being separate files
**Reachable from:** deliberately **deferred — both are constructed only in
`spec/lain/middleware_spec.rb`** (`:107`, `:130`). AC 1 asserts the production stack's members.

`Timeout` is cited as a **testing idiom** by three lib comments (`frontend/tty.rb:63`,
`frontend/neovim/compose.rb:103`, `cli/shutdown.rb:70`) and two specs. Rewrite those five to name the
idiom — an injected clock — rather than the class. Do not delete the sentences; the idiom is real and
the citation is what rots.

Also consider the `Composable`/`Composed`/`Identity` trio and the `monoid on: :>>` declaration at
`middleware.rb:20-79`: production uses `Stack` exclusively. **Report** whether they are spec-only
rather than deleting them in this card — `Algebra::Monoid` has five other users, so the vocabulary
stays even if Middleware's participation in it does not, and that is a decision for the panel.

**Acceptance criteria**

```gherkin
Scenario: the production middleware stack holds only middlewares production uses
  Given a middleware stack built the way the CLI builds one
  When its members are listed
  Then no logging or timeout middleware is present

Scenario: the injected-clock idiom is still documented
  When the three files that cited the timeout middleware are read
  Then each explains the injected-clock seam
  And none names a class that no longer exists

Scenario: a middleware stack still composes left to right
  Given two middlewares in a stack
  When an effect passes through
  Then the first runs before the second
```
→ spec file: `spec/lain/middleware_spec.rb`

**Escalation triggers**
- `Middleware::Timeout`'s `declare` block (`:219-230`) registers a `Declarative::Carrier`. If deleting
  it removes the only `declare raising:` example in `middleware.rb` and something asserts the
  registry's size, stop.
- `DEADLINE_KEY = :deadline` (`:213`) may be read by `Middleware::Env`. Check before deleting — an env
  key with one writer and one reader across two files is exactly the shape a constant sweep gets right
  and a human skimming gets wrong.
- If the `Composable`/`Composed`/`Identity` trio turns out to have a production caller after all, that
  is a finding worth its own report, not a quiet keep.

### T6 — Delete the schema validator, the uncalled `dig`, and the unused half of the contract vocabulary   [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/tool.rb`, `lib/lain/tool/contracts.rb`,
`spec/lain/tool_spec.rb`, `spec/lain/tool/contracts_spec.rb`
**Reuse:** `Tool::Input`'s `input_model` path (`tool.rb:195`) is what every production tool already
takes — 24 of 25 declare one, and the 25th is nullary
**Shared-file wiring:** none — `lib/lain/tool.rb` is task scope
**Reachable from:** `Tool#call` (`tool.rb:132-142`) is on every tool invocation; AC 1 drives a real
tool through `#call` and AC 4 drives a precondition violation through it

Three removals:

1. **`Tool::SchemaValidator`** (`tool.rb:295-395`) — one caller at `:197`, reached only when
   `input_model` is falsy. Zero spec references. Removing it means `#validate_input!` (`:194-201`)
   requires an `input_model`, which every production tool has.
2. **`Tool#dig`** (`:175-180`) — zero callers anywhere. Its docstring says its precedence *"MATCHES
   {SchemaValidator#dig} on purpose"*, and both bodies are byte-identical.
3. **The postcondition half of `Contracts`** — `.ensures` `:52-58`, `.postconditions` `:67-69`,
   `.own_postconditions` `:76-78`, `#check_postconditions!` `:180-185`, and the `check_postconditions!`
   call at `tool.rb:140`. `.ensures` has zero `lib/` callers.

**Keep the precondition half and `ContractViolation`.** `.requires` has five live declarations,
`#check_preconditions!` runs at `tool.rb:134` so `#perform` cannot be reached with a violated
precondition, `contracts_along_ancestry` (`:163-168`) stops a subclass silently dropping
read-before-write, and `edit_file.rb:28-38` documents its three refusals' **ordering** as load-bearing.
`ContractViolation` has 29 `raise_error` assertions across 7 spec files and
`effect/handler/live.rb:78` special-cases it.

**Acceptance criteria**

```gherkin
Scenario: a tool with a declared input model still validates its input
  Given a tool declaring a required string field
  When it is called with that field missing
  Then it refuses, naming the field

Scenario: a tool without an input model is refused at declaration
  Given a tool class declaring no input model and taking arguments
  When it is called
  Then it raises, saying an input model is required

Scenario: a precondition still runs before perform
  Given a tool with a read-before-write precondition
  When it is called against an unread file
  Then it raises a contract violation
  And perform did not run

Scenario: a subclass cannot drop an inherited precondition
  Given a tool subclassing one with a precondition
  When it is called violating that precondition
  Then it raises a contract violation
```
→ spec files: `spec/lain/tool_spec.rb` (AC 1, AC 2), `spec/lain/tool/contracts_spec.rb` (AC 3, AC 4)

**Escalation triggers**
- `spec/lain/tool_spec.rb:174` and `contracts_spec.rb:17`, `:55`, `:133` are the four `.ensures` call
  sites. They are **specs of a feature being deleted**, so they go — but read each first: if any
  asserts something about `#call`'s *ordering* that only the postcondition check makes observable,
  that assertion needs to survive in a different shape.
- 16 spec files hand-roll `def input_schema` on doubles. If making `input_model` effectively mandatory
  breaks them, the count is the finding — report it before converting 16 files, because more than a
  handful suggests `SchemaValidator` has a role the grounding missed.
- `session_usage.rb` is nullary. Confirm a nullary tool still passes `#validate_input!` with no
  `input_model` before removing the fallback, or it becomes the one tool that cannot be called.

### T7 — Delete `DerivationAudit` and the registry's only runtime reader   [wave 1] [risk: low]

**Depends on:** none
**Files:** delete `lib/lain/compaction/derivation_audit.rb`, `derivation_audit/edge.rb`,
`derivation_audit/diagnosis.rb`, `derivation_audit/finding.rb`,
`spec/lain/compaction/derivation_audit_spec.rb`
**Reuse:** `Compaction::Derivation` (310 lines) is the live object and stays
**Shared-file wiring:** remove `require_relative "compaction/derivation_audit"` from
`lib/lain/compaction.rb:13`
**Reachable from:** deliberately **deferred — zero callers in `lib/` or `exe/`**. AC 1 asserts the
live compaction path still works, which is the production check that survives.

This also removes the **only non-declaring reader of `Algebra.registry` in `lib/`** — `:277`'s
`declares?` and `:283`'s `refutations`. After this card, the registry is filed-at-load and read only
by `spec/algebra_laws_spec.rb`, which means `Algebra::Registry`'s query API can lose its production
surface. **Report that; do not act on it here** — it is simplify-09's scope.

Deleting `derivation_audit.rb` also fixes one of T11's eight phantom `Telemetry::Guards` links for
free, leaving seven.

**Acceptance criteria**

```gherkin
Scenario: compaction still derives a replacement
  Given a timeline long enough to compact
  When compaction runs
  Then a derived replacement is committed

Scenario: the registry has no production reader
  When the algebra registry's query methods are searched for callers in the library
  Then none is found

Scenario: a compaction is still journaled
  Given a compaction that fires
  When the journal is read
  Then it holds the compaction record with its strategy
```
→ spec files: `spec/lain/compaction/derivation_spec.rb` (AC 1, AC 3). AC 2 is a reachability
assertion verified by grep and recorded in the commit message.

**Escalation triggers**
- `Compaction::Derivation` and `DerivationAudit` are adjacent names. Confirm which one
  `compaction.rb:13` loads and which one `compaction/source.rb` uses before deleting either.
- `derivation_audit_spec.rb:442-449` asserts `store.size` growth. Those assertions go with the spec —
  but if they are the **only** place store growth after a compaction is pinned, that is coverage
  lost, and it should move rather than vanish.
- `derivation_audit.rb:133`'s `unclaimed_purity` message quotes the registry's vocabulary. If any
  other file quotes that sentence, the phrasing is shared and its deletion is observable.

### T8 — Delete Bedrock   [wave 1] [risk: low]

**Depends on:** none
**Files:** delete `lib/lain/provider/bedrock.rb`, `provider/bedrock/transport.rb`,
`provider/http/providers/bedrock.rb`, `spec/lain/provider/bedrock_spec.rb`,
`spec/lain/provider/bedrock_parity_spec.rb`, `spec/lain/provider/bedrock_reference_spec.rb`,
`spec/support/provider_oracles/bedrock_reference.rb`,
`spec/lain/provider/http/providers/bedrock_spec.rb`, `docs/providers/bedrock.md`;
modify `lib/lain/cli/backend.rb`
**Reuse:** `CacheProfile::ANTHROPIC` and `PriceBook`'s `anthropic.` prefix match are shared and need
**no** edit — Bedrock reuses both
**Shared-file wiring:** remove `require_relative "provider/bedrock"` from
`lib/lain/provider.rb:144` and the Bedrock require from `lib/lain/provider/http.rb:25`; remove the
`RSpec/AnyInstance` exclusion at `.rubocop.yml:340`; remove the `bedrock` value from `--provider`'s
enum in `exe/lain`; remove the `Provider::BedrockRaw` mention from `lain.gemspec:60`
**Reachable from:** `CLI::Backend#provider` (`cli/backend.rb:179`) is the production construction
site and loses its `when "bedrock"` arm; AC 2 drives `--provider bedrock` through the real CLI and
expects a refusal naming the supported providers

Out of scope by standing ruling — the code was kept and marked "untested going forward". Two `lib/`
references: `cli/backend.rb:179` and `:457` (`Provider::Bedrock::DEFAULT_MODEL`). Collapsing `:179`'s
case from three arms to two also kills the `queue:`/`spool:`-not-forwarded special-casing.

Note `lain.gemspec:60` documents a `Provider::BedrockRaw` that **exists nowhere in the repo** — fix
that line here.

**Acceptance criteria**

```gherkin
Scenario: the supported providers are anthropic and the two ollama arms
  When the CLI's provider option is described
  Then bedrock is not among its values

Scenario: asking for bedrock is refused clearly
  Given a provider flag naming bedrock
  When a chat is launched
  Then it is refused
  And the refusal names the providers that are supported

Scenario: anthropic still resolves and reports its cache profile
  Given a provider flag naming anthropic
  When a backend is constructed
  Then its cache profile is the anthropic one

Scenario: the gemspec names no class that does not exist
  When the gemspec's description is read
  Then every class it names is defined
```
→ spec files: `spec/lain/cli/backend_spec.rb` (AC 1-3), `spec/lain_spec.rb` or the gemspec spec
(AC 4)

**Escalation triggers**
- Deleting `provider/http/providers/bedrock.rb` removes `Registry.resolve`'s **only two references
  anywhere**. T12 owns `resolve`'s deletion; if T12 has not run, leave `resolve` in place and let T12
  find it unreferenced. Do not delete it here.
- `provider/http/providers/bedrock.rb:50` self-registers at file bottom. If `Configuration`'s
  registered-options map is asserted to have a particular size, that assertion changes.
- `spec/support/shared_examples/provider_parity.rb` may take Bedrock as one of its arms. If deleting
  it leaves a shared group with one caller, report it — a shared example with one caller is
  indirection, and simplify-10 tracks that class of thing.

### T9 — Move the test-only collaborators out of `lib/`   [wave 2] [risk: medium]

**Depends on:** T1, T2, T3, T4, T5, T6, T7, T8
**Files:** create `spec/support/nulls/` (one file per relocated Null); modify
`lib/lain/tools/subagent.rb`, `lib/lain/cli/wiring/toolset_build.rb`,
`lib/lain/cli/wiring/askers.rb`, `lib/lain/tools/ask_human/directory.rb`,
`lib/lain/cli/tmux_surface.rb`, `lib/lain/tools/request_review.rb`, and the spec files that
construct them
**Reuse:** `Provider::Mock` and `Effect::Handler::Mock` are cited in CLAUDE.md as existing *because
specs needed them* — that is the endorsed pattern; the question this card settles is only **where**
they live. `spec/spec_helper.rb:40` globs `support/**/*.rb` recursively, so no manifest edit is needed.
**Shared-file wiring:** none — `spec/support/nulls/` needs no registration
**Reachable from:** each affected production constructor keeps its real collaborator required rather
than defaulted; AC 1 drives a subagent built the way `CLI::Wiring::ToolsetBuild` builds one, proving
the production path passes a real collaborator

**The move is mostly not a move.** Five of the eight are **keyword-argument defaults on production
constructors**, and `subagent.rb:445-446`, `toolset_build.rb:105-107` and `askers.rb:27-31` each
document theirs as *"NOT a sanctioned production state"*. So: delete the default, make the keyword
required, and pass the Null explicitly from `spec/support/nulls/`. That is better design either way —
it makes each spec's reliance visible.

Triage, which differs per item:

- **`NoAskers`, `NoSwitchboard`, `Askers.unwired`** — delete the default, relocate the object,
  pass explicitly (~13 construction sites between them).
- **`Directory::Null`** — zero `lib/` references; a straight relocation.
- **`TmuxSurface#session`** — called only from its own spec. **Dead: delete the method and its two
  examples.**
- **`WindowState#survived`** — *written* in production with real fail-closed logic at `:141` and
  `:144`, read nowhere. Not relocatable (it is a `Data` member). Either a caller consumes it or the
  field goes with its computation — **decide in the card and say which**.
- **`@last_spawn`/`@last_child`/`@last_message` + `#remember`** — cannot relocate an ivar. 44 spec
  references. `subagent.rb`'s own comment names the replacement: *"an actor's record rides its events
  instead"*, i.e. a journal-reading observer in `spec/support`. This is the largest piece of the card.
- **`NoNotes`** — zero references in `lib/` beyond its own definition and default, and **zero in
  `spec/`**. Genuinely dead: delete.

**Acceptance criteria**

```gherkin
Scenario: a subagent built the production way receives a real asker set
  Given a subagent seam built by the toolset build
  When its askers are inspected
  Then they are the run's own, wired to a real queue

Scenario: a subagent cannot be built without askers
  When a subagent seam is built with no askers
  Then construction is refused

Scenario: a spec observes a spawn through the journal
  Given a subagent spawning one child
  When the journal is read
  Then it records the spawn and the child's identity

Scenario: no production constructor defaults to a test-only collaborator
  When the library's constructors are searched for the relocated Nulls
  Then none is named as a default
```
→ spec files: `spec/lain/cli/wiring/toolset_build_spec.rb` (AC 1, AC 2),
`spec/lain/tools/subagent_spec.rb` (AC 3), and a small enumeration for AC 4 in
`spec/lib_null_defaults_spec.rb` (new)

**Escalation triggers**
- **44 spec references to the `@last_*` ivars** across seven spec files, and
  `subagent_concurrency_spec.rb:245` records a real past race on `@last_child`. If the journal-reading
  replacement cannot observe what those examples assert — particularly the concurrency one — stop.
  Half-migrating an observation channel is worse than leaving it.
- `spec/lain/cli/wiring/agent_build_spec.rb:495` and `:533` assert `not_to be(…NoSwitchboard)` —
  **negative** assertions about a default that is going away. They become vacuous rather than failing.
  Rewrite or delete them explicitly; a vacuously-passing spec is the failure mode
  `spec/spec_discipline_spec.rb` exists to report.
- Making a keyword required breaks every direct-construction spec. Count them first. If the count
  exceeds roughly fifteen, the seam is wrong and a factory in `spec/support` should come first.
- `askers.rb:32`'s `unwired` constructs `Notify::Null.new`, which **T3 deletes**. Sequence after T3
  (the wave does this) and expect `unwired` to need a different notifier or none.

### T10 — Delete the one discipline spec the Journal's own fd already enforces   [wave 1] [risk: medium]

**Depends on:** none
**Files:** delete `spec/output_discipline_spec.rb`; modify `CLAUDE.md`
**Reuse:** `Journal`'s own fd is the enforcement — `journal.rb:53` (`File.new(path, "ab")`), `:150`
(`sync = true`), `:162-165` (one `@io.write` under a `Monitor`)
**Shared-file wiring:** remove the `output_discipline_spec` citation from `.rubocop.yml:214`
**Reachable from:** `Journal` is constructed on the live chat path from `CLI::Chronicle`; AC 1 drives
a real journal and a stray `warn` through it

The rule's stated justification is that a stray write corrupts the NDJSON record. **That is already
guaranteed independently**: the Journal holds its own fd with `sync = true` and writes each record as
one call under a Monitor, so a `warn` from `lib/` goes to fd 2 and cannot interleave. The 145-line
Ripper walk guards a path the dedicated fd closes.

**Keep `Sink::IOAdapter` and `Sink::Null` both.** An earlier draft of this card also deleted `Sink::Null`
and the `sink:` injection "from everything that only ever needed `warn`". That was wrong twice over:
**`Sink::Null` has 46 references in `lib/`**, including `Provider::Anthropic#initialize`,
`HTTP::Logging::SinkLogger`, `StreamAccumulator` and `ToolCallAccumulator` — the whole provider streaming
chain, which does not only need `warn` — and **it is CLAUDE.md's named exemplar for the Null Object rule**
(*"`Sink::Null` is the exemplar — no caller ever writes `if sink`"*). Deleting the style guide's own
exemplar inside a deletion card is not how that question gets asked.

So this card deletes **one file**: the 145-line Ripper walk whose stated justification the Journal's own fd
already provides. It also fixes **`CLAUDE.md:146`**, which names that spec by path and would otherwise cite
a deleted file — a gap no other card owned.

What is lost, and must be said in the commit message: the **cockpit** guarantee. A stray `warn` will
scribble into the chat pane. That is cosmetic, not record corruption.

**The four `support_*_spec.rb` files are simplify-10's T9**, not this card's — that plan carries the better
escalation trigger, that `support_vsock_availability_spec.rb:136-146` is a byte-for-byte copy of
`tags.rb:238-246` so deleting it removes a (broken) check.

**Acceptance criteria**

```gherkin
Scenario: a stray warning cannot corrupt the journal
  Given a journal writing records to a file
  When a warning is emitted to standard error during a write
  Then every line of the journal file parses as JSON

Scenario: tool bytes keep their attribution
  Given a tool producing output through the sink adapter
  When the journal is read
  Then each chunk names the tool call it came from
  And names its stream

Scenario: two concurrent writers do not interleave a record
  Given two fibers writing records to one journal
  When both complete
  Then every line parses as JSON

Scenario: the rulebook names no deleted spec
  When CLAUDE.md's output-discipline section is read
  Then it names no spec file that does not exist
```
→ spec file: `spec/lain/journal_spec.rb` (AC 1, AC 3), `spec/lain/sink_spec.rb` (AC 2)

**Escalation triggers**
- `spec/output_discipline_spec.rb`'s `ALLOWLIST` at `:32` is **empty**, meaning `lib/` outside
  `lib/lain/frontend/` currently has zero terminal writes. Deleting the guard permits the first one.
  If the panel judges the cockpit guarantee worth keeping, the alternative is narrowing the spec to
  the Journal's own writers rather than deleting it — report that option rather than assuming.
- **Do not touch `Sink::Null` or `Sink::IOAdapter`.** 46 references and a named place in the style guide;
  if the injection burden is worth revisiting it needs its own plan and its own argument.
- `CLAUDE.md` is also edited by simplify-01's T7. If both are open, hand the one-line citation fix to T7
  rather than editing the file twice — and say which way it went.

### T11 — Fix seven phantom YARD links and rehome a misfiled reader   [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `lib/lain/middleware/redact_secret_reads.rb`, `lib/lain/provider/admission.rb`,
`lib/lain/mode/switch.rb`, `lib/lain/approval/policy_switch.rb`,
`lib/lain/review/records/corpus_extended.rb`, `lib/lain/session.rb`,
`lib/lain/session_record/replay.rb`, `spec/lain/approval/policy_switch_spec.rb`;
move `lib/lain/telemetry/spawn_lifecycle.rb` → `lib/lain/status_feed/spawn_lifecycle.rb`
**Reuse:** `Telemetry::Carriers` (`telemetry.rb:39`) is the real namespace; the flat
`telemetry/*.rb` files are the real homes
**Shared-file wiring:** move the `require_relative` for `spawn_lifecycle` from `telemetry.rb` to
`lib/lain/status_feed.rb`, where its consumers are
**Reachable from:** `SpawnLifecycle` is constructed at `status_feed/fleet.rb:67` and
`cli/fleet_windows.rb:418`; AC 3 drives a fleet view that reads a terminal spawn record

**`Telemetry::Guards` does not exist** — no `guards.rb`, no `module Guards` anywhere. Eight `{Telemetry::Guards::X}`
links resolve to nothing; one of the eight is in `derivation_audit.rb`, which T7 deletes, leaving
seven. Note `review/records/corpus_extended.rb:31` cites `{Telemetry::Guards::Switches}` and there is
**no `Switches` class either** — `switches.rb` defines `ModeSwitch`. So that one needs a real name
found, not just a namespace stripped.

`telemetry/spawn_lifecycle.rb` is a 111-line **reader** sitting in a directory of value objects. Its
two consumers are both in the status-feed/fleet area.

**Acceptance criteria**

```gherkin
Scenario: every documentation link resolves
  When the documentation is generated
  Then no link names an undefined namespace

Scenario: the mode switch's record is named correctly
  When the mode switch's documentation is read
  Then it names the class that records a mode flip
  And that class is defined

Scenario: a retired worker still leaves the fleet view
  Given a journal recording a worker's terminal spawn record
  When the fleet view is rendered
  Then that worker is absent
```
→ spec files: `spec/lain/status_feed/fleet_spec.rb` (AC 3), and AC 1 verified by
`bundle exec yard-lint` over the whole tree

**Escalation triggers**
- `corpus_extended.rb:31`'s `Switches` has no real counterpart. If the intended class cannot be
  determined from context, leave the link **removed rather than repointed** and say so — a wrong link
  is worse than none.
- `yard-lint` runs `--staged` in the hook (`.pre-commit-config.yaml:92-97`), so a whole-tree defect
  this card introduces will not be caught at commit time. Run it whole-tree before finishing.
- Moving `spawn_lifecycle.rb` changes its constant path from `Telemetry::SpawnLifecycle`. Eight spec
  files reference it. If the rename ripples further than those eight, stop and report — it may be
  cheaper to leave the file and fix only the links.

### T12 — Delete the provider resolver nothing resolves through, and five dead constants   [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `lib/lain/provider/http/provider/registry.rb`,
`spec/lain/provider/http/provider_spec.rb`, `lib/lain/compaction/source.rb`,
`lib/lain/provider/response_wal.rb`, `lib/lain/compaction/need.rb`,
`lib/lain/compaction/strategy/composed.rb`
**Reuse:** `cli/backend.rb:179`'s literal `case` is how a provider is actually chosen, and stays
**Shared-file wiring:** none
**Reachable from:** `Registry#register` stays live with two production callers
(`providers/anthropic.rb:74`, and `providers/bedrock.rb:50` until T8 removes it); AC 1 asserts
registration still populates the configuration options

**Delete the resolver, keep the registrar.** `#resolve` (`registry.rb:30-32`) and `#providers`
(`:19-21`) have zero `lib/` callers; `#register` (`:25-28`) populates
`Configuration.register_provider_options` and every `build_config` depends on it.

Five confirmed-dead constants: `compaction/source.rb:147` `IdleGap`, `:170` `Scheduling` (both with
zero spec references either), `provider/response_wal.rb:105` `StreamingFrame`,
`compaction/need.rb:105` `Manual`, `strategy/composed.rb:48` `Untagged`.

**Verify `Source::Derived::PinCuts` before touching anything near it** — it is load-bearing per
`ARCHITECTURE.md:1063`.

**Acceptance criteria**

```gherkin
Scenario: registering a provider still supplies its configuration options
  Given a provider class registering itself
  When the configuration's registered options are read
  Then that provider's options are present

Scenario: a provider is chosen by name without a registry lookup
  Given a provider flag naming anthropic
  When a backend resolves its provider
  Then an anthropic provider comes back

Scenario: compaction still schedules against a cold cache
  Given a prompt cache that has gone cold
  When compaction is considered
  Then it is permitted
```
→ spec files: `spec/lain/provider/http/provider_spec.rb` (AC 1), `spec/lain/cli/backend_spec.rb`
(AC 2), `spec/lain/compaction/source_spec.rb` (AC 3)

**Escalation triggers**
- `spec/lain/provider/http/provider_spec.rb:57`, `:68`, `:100`, `:114` all use `#providers` — four
  assertions about a method with no production caller. They go with it, but read them first: if any
  asserts a **property of every registered provider** (an `api_base` default, say), that is a real
  cross-provider invariant and needs to survive in another shape.
- If `PinCuts` appears in the same region as one of the five constants, stop and separate the edits.
  `ARCHITECTURE.md:1063` names it load-bearing and a neighbouring deletion is how such a thing gets
  taken out by accident.

### T13 — Add the rows the deletability map missed   [wave 2] [risk: low]

**Depends on:** T1, T2
**Files:** modify `spec/lain/review/deletability_spec.rb`
**Reuse:** the existing `Capability` schema (`:57-62`) and the seven rows as the template
**Shared-file wiring:** none
**Reachable from:** the map is read by its own spec, which boots the tree without each row; AC 1 is
that harness running over the new rows

The map is a 493-line machine-checked enumeration of what can be removed — and it **missed all six**
files T2 deleted. Per the project's own rule, a stale enumeration is worse than a missing one.

Two options, and the card must choose and say why: add rows for what T1 and T2 removed (keeping the
hand-maintained map honest), or **replace the hand-kept map with a sweep** that derives
zero-consumer units from a reference graph. The second is more work and removes the failure mode
permanently; the first is an hour. The grounding favours the sweep — the map's own `edits` lists are
already documented as checked for staleness but never completeness (`:157-173`), which is the same
gap one level up.

**Acceptance criteria**

```gherkin
Scenario: the map records every capability removed by this plan
  When the deletion map's keys are read
  Then each capability this plan removed is named

Scenario: a unit with no consumers is reported
  Given a library file no other library file references
  When the deletability check runs
  Then that file is reported as removable

Scenario: a unit with a consumer is not reported
  Given a library file another constructs
  When the deletability check runs
  Then that file is not reported as removable

Scenario: the negative control still holds
  Given a capability removed without one it forces
  When the tree is booted
  Then it fails, naming the missing constant
```
→ spec file: `spec/lain/review/deletability_spec.rb` (AC 4 already exists at `:483-491` and must stay
green)

**Escalation triggers**
- **Do not replace the map with a sweep while simplify-14 is undecided.** 14's T5 *executes* the
  `thread` and `docent` rows of this same map and edits `deletability_spec.rb` to do it; a sweep leaves
  it nothing to execute and silently drops the negative control at `:483-491` that 14's AC 1 depends
  on. If 14 has landed or been declined, the sweep option is open; if it is still pending, take the
  cheap option (add rows) and say why.
- A reference-graph sweep needs to resolve constants to qualified paths, not match leaf names — T2's
  three false-positive cases (`Delta`, `Annotations`, `Placement`) are the proof. If the sweep cannot
  do that, it will report live files as dead, which is worse than the current gap. Stop and report
  rather than shipping a sweep that over-reports.
- The spec is tagged `:seam` and uses `cp -al` hardlinked copies (`:300`). It requires `TMPDIR` on the
  same filesystem as the repo, and **7 examples fail with a bare `Command failed: cp`** when `TMPDIR`
  is unset — which reads exactly like a real defect. Confirm the environment before believing red.
- If the sweep would take more than a few seconds, it does not belong in the suite. `bin/` is the
  established home for a worklist tool (`bin/comment-census` is the precedent) — say so rather than
  adding a slow spec.

## Integration checks

After the last wave:

- `bundle exec rake pspec` green, **and the example count compared against the pre-plan baseline minus
  the examples this plan deletes with its spec files**. Write both numbers and the arithmetic in the
  final commit message. This plan deletes roughly 5,000 spec lines across a dozen files, so the count
  will drop a long way legitimately — which is exactly the condition under which a dead worker hides.
- `bundle exec rubocop` clean, with the `.rubocop.yml` exclusions for deleted files removed
  (`:301` for Notify, `:340` for the Bedrock spec, `:214`'s output-discipline citation).
- `bundle exec yard-lint` whole-tree, defect count compared against baseline — T11 is only judgeable
  whole-tree, and the hook's `--staged` mode will not see it.
- `bundle exec rspec spec/lain/review/deletability_spec.rb` after `rake core:build` if needed — it is
  `:seam`-tagged, uses hardlinked copies, and is the harness proving T1 and T13.
- `bundle exec rake compile && bundle exec rspec --tag core` — T4 removes `core_exec` while keeping
  `Exec::Core`, so the daemon's remaining coverage needs confirming.
- `for cmd in $(lain help | ...); do lain $cmd --help; done` or equivalent — eleven cards remove
  constants, and a broken `require` surfaces as a command that will not load.
- **Manual, human:** one `lain chat` session with an approval parked and answered at the terminal,
  confirming T3 left the approval path intact with one fewer surface. `spec/approval_consumer_discipline_spec.rb`
  exists because that path once lost its only consumer silently.
- Update `planning/qa/scenarios/` for the removed `--desktop` flag and the removed `bedrock` provider
  value — both are user-visible surface, and closing a chunk includes updating that enumeration.

### Close-out

All thirteen cards landed. The last one's panel returned APPROVE-WITH-FIXES with five mechanical
fixes, applied by the orchestrator because the implementer had already exited: the `askers`
paragraph was wedged inside the `tool_middleware` docstring and orphaned the sentence after it;
that paragraph described the default as gating nothing, which is `switchboard:`'s verb rather than
`askers`'; it recorded a construction-frame count nobody had measured; a YARD link named a
`::Spawner` constant that does not exist; and the new discipline spec scanned `lib/` only, leaving
`exe/lain`'s thousand lines of production wiring invisible to it.

**The frame count is now a measured number.** The implementer counted 41 across 8 files, the panel
re-measured independently with a wider sweep and got 45 across 10, and an enumeration of the spec
files that construct the seam agrees with 10. The comment records 45/10. A number in a comment that
nobody measured is exactly the defect the panel raised, so it is not recorded as a range or a
guess.

**The panel confirmed the card's own correction.** `epic_submit`'s adjudication really does build a
seam with no askers, and `lain epic submit` really does run out of chat — traced to `exe/lain`'s
only construction site, with a probe showing the refusal fires, carries the right wording, and
parks nothing. The source comment claiming this was never a sanctioned state was false, and its
deletion stands.

**One acceptance criterion did not land as written, and the tree should say so.** The card's second
scenario asks that a bare `Subagent::Seam` refuse construction without `askers:`. It does not; what
refuses is `CLI::Wiring::ToolsetBuild`, the only production constructor. That is a real guarantee at
the production boundary, but it is a different scenario from the one the Gherkin states, and it is
recorded here as superseded rather than quietly recast as a pass.

**Deferred from this chunk, for a later one:** two spec construction frames carry 164 of the 259
required-keyword failures, so a `spec/support` spawn factory would make `askers:` requirable far
more cheaply than the raw frame count suggests. That is the follow-up card.
