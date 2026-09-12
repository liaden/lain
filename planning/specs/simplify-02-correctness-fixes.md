# Simplify 02 — one classifier per run, one guard chain, and three silent divergences closed

status: done
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

The simplification audit turned up defects while looking for cruft, and they should not wait behind a
refactor. Two are live: the secret boundary compiles its rules table three independent times and a
`/survey` can classify against a different one than the gate holds, and one consolidation pass runs
one of four tool guards. Three are latent but silent — the kind that return a wrong answer rather than
raising. This plan closes all of them and moves one architectural invariant onto the constructor that
actually carries it.

Delivers: exactly one `Sensitivity` classifier per run, with `sensitivity:` required rather than
defaulted; both detached passes on the same four-guard stack; `Backend.new` opening no sockets; a
block-form `Ext::Timeline#ancestors`; `Ext::Timeline` declared in the algebra registry; and seven
error classes reachable by `exe/lain`'s renderer.

## Grounding

Verified 2026-09-12 against the working tree at `d2bb133c`.

**The secret boundary's guarantee is on the wrong constructor.** `ARCHITECTURE.md:498` claims that a
gate refusing a path while the listing that found it enumerates the same path is *"unrepresentable
rather than merely untested"*, because `Policy` holds the only `Filter.new`. The literal claim is
true — `sensitivity/policy.rb:120` is the only one. But `Filter` is downstream of `Sensitivity`, and
there are **five `Lain::Sensitivity.new` sites** in `lib/` fed by **three independent
`Config.sensitivity` parses**:

| site | table source |
|---|---|
| `cli/wiring/board_build.rb:187-189` (`.classifier`) | the table hoisted once at `:77` |
| `cli/wiring/board_build.rb:287` (`Classifiers#initialize`, eager) | the same hoisted table |
| `cli/wiring/board_build.rb:295` (`Classifiers#call`, per-cwd) | the same hoisted table |
| `cli/command/survey.rb:271-274` | **a second** `Config.sensitivity(root: @root)` at `:273` |
| `cli/survey.rb:136-138` | **a third** `Config.sensitivity(root: cwd)` at `:137` |

`board_build.rb:71-86` does the right thing and says why: *"Compiled ONCE and handed to both readers…
a second call would parse the same file twice and tell the operator the same thing twice for one
broken config."* The leak is that `/survey` is a fourth reader nobody threaded it to.

**The injection seam exists and production forgets it.** `cli/command/survey.rb:108-118` accepts
`sensitivity: nil`, and the only construction site is `cli/command/surface.rb:154-157`:

    Survey.new(root: @root, cwd: @cwd, outbox:, ledger: @ledger)

No `sensitivity:`. The docstring **four lines above the omission** (`command/survey.rb:95-99`) warns
about exactly this shape for a different collaborator: *"REQUIRED, no default and no Null: a
defaulted one lets a forgotten injection become a SECOND ledger whose releases nobody ever sees."*
The ledger is threaded; the classifier is not.

**The divergence needs no adversary.** `write_file` is tier-1 and `Sensitivity::Policy::PATH_FIELDS`
does not gate writes to `.lain/config.toml`. Session starts and the gate holds
`denied = ["secrets/*"]`; a turn edits the config; `/survey .` re-parses and walks with the new
table. The listing now enumerates a path the gate still refuses. A human editing config in another
pane produces the same state.

**Two aggravations.** `cli/survey.rb:137` passes a **cwd where `root:` is required** —
`config.rb:110-113` says so explicitly and names `spec/lain/project/root_defaults_spec.rb` as the
guard that *"caught this"*. It did not catch this one. So `lain survey open PATH` from any
subdirectory resolves `<cwd>/.lain/config.toml`, finds nothing, and silently classifies with
`Rules.empty`. And the degradation postures differ: `board_build.rb` rescues `Config::Malformed` at
`:132-137`, `:154-159` and `:225-230`, reporting through `notice` (`SILENT` at `:32`) and degrading;
`grep -n 'rescue' lib/lain/cli/command/survey.rb` returns **nothing**, so a malformed config the
board tolerated with a notice makes `/survey` raise mid-chat.

**`spec/lain/project/root_defaults_spec.rb` is a 544-line Ripper discipline spec** whose premise
(`:6-18`) is that the ~38 existing `root: Dir.pwd` defaults in `lib/` **stay** and a thirty-ninth
reddens. Its allowlist is `RootDefaultDiscipline::ALLOWED` at `:98`. It catches `Dir.pwd`,
`Dir.getwd`, `Pathname.pwd`, `FileUtils.pwd`, one-arg `File.expand_path(".")`, `ENV["PWD"]`, on
`def`, `def self.`, lambdas and blocks. **Changing `cli/survey.rb`'s `cwd: Dir.pwd` default
interacts with it directly.**

**One consolidation pass runs one guard of four.** The path is `lib/lain/consolidation.rb` (not
`cli/consolidation.rb`). At `:111`:

    def guard_stack = Middleware::Stack.new([Middleware::RefuseSecretWrites.new(journal: @journal)])

used at `:95` as `tool_middleware:`. Its twin `cli/improve.rb:196` is
`ToolGuard.detached(journal: @journal).call(WorkerEnv.default)`, used at `:177`, with the rationale at
`:21-25`: *"the guard is self-built … so it runs the stack a detached run builds for itself."*
`ToolGuard.layered` (`cli/tool_guard.rb:81-87`) is the four-guard stack:
`RefuseSecretWrites`, `RedactSecretReads`, `WithholdSecretPaths`, `GuardTestLayout`.
`ToolGuard`'s public entry points are `stack` `:59`, `child_stack` `:72`, `working` `:76`,
`layered` `:81`, `detached` `:103`.

**`Backend.new` opens sockets, breaking a rule documented one line away.**
`cli/backend.rb:127-139` calls `num_ctx` from `#initialize` at `:138`; `#num_ctx` (`:274`) reaches
`backend/num_ctx.rb:74-83`'s `trained_maximum`, which calls
`@backend.provider.trained_context_tokens(@backend.model)` — a live probe, taken whenever
`@options[:num_ctx]` is truthy (`num_ctx.rb:62` short-circuits on `@value &&`). Meanwhile
`cli/chat_launch.rb:119-124` states the preflight rule: *"It opens no record … **It asks no server
anything**, because an unreachable `--api-base` fails at TURN level and refusing it here would stop
the cockpit opening for a model server that is merely down."* `#preflight` (`:112-150`) reaches
`Backend.new` through `#constructed` at `:134`.

**The `#ancestors` divergence is silent and prices every timeline at zero.**
`ext/lain/src/lib.rs:1456-1466` defines `fn ancestors(...) -> Result<RArray, Error>` and `:1945`
registers it `method!(Timeline::ancestors, 0)` — **arity 0, no block**. `lib/lain/timeline.rb:101-111`
yields when given a block and returns `enum_for` otherwise. `lib/lain/ledger.rb:105-111` is the one
block-passing caller:

    timeline.ancestors { |turn| acc[turn.digest] ||= turn }

Against an `Ext::Timeline` the block is ignored, the returned Array discarded, `acc` stays `{}`, and
the bench's whole cost column reads free with no exception. The other nine `lib/` callers use
Enumerator or Array forms and survive against an Array — `timeline.rb:114`, `:119`, `:152`,
`tools/subagent/turn_feed.rb:60`, `cli/command/pin.rb:68`, `cli/command/rewind.rb:112`,
`cli/goal_driver.rb:274`, `session_record/scribe.rb:111`, `:329` — though they lose laziness, against
CLAUDE.md's own `Enumerator::Lazy` rule.

**The algebra declaration is the second silent divergence.** `lib/lain/timeline.rb:26` carries
`include Algebra::MeetSemilattice` with three per-operator declarations at `:159` (`:meet`), `:185`
(`not_a_meet_semilattice on: :causal_meets`) and `:225` (`:dominator_meet`). The registry is sealed
at `lib/lain.rb:146`, the **last statement in the file**, and `spec/algebra_laws_spec.rb` sweeps it.
`Ext::Timeline` declares nothing, so swapping it in loses the entry with nothing failing.

**Seven error classes escape `exe/lain`'s renderer.** `class X < StandardError` in `lib/`, excluding
vendored `provider/http/`: `error.rb:4` (`Lain::Error` itself — the root, stays),
`declarative.rb:57`, `middleware/guard_test_layout.rb:128`, `shell/pipeline.rb:74`,
`tools/web_fetch.rb:387`, `:392`, `frontend/reline.rb:81`. None of the six descends from
`Lain::Error`, so none is caught by `exe/lain`'s four `rescue Lain::Error` sites (`:81-85`, `:90-96`,
`:1071-1078`, `:1150-1157`). All six are rescued internally today, so this is latent.
`project/resolver.rb:469-470` documents the correct pattern: it renames its own `SystemCallError`s to
`Project::Unresolvable` *"so `exe/lain`'s `rescue Lain::Error` still catches them"*.

**The `rm .git` trap has prose and no guard.** `docs/toolchain-traps.md:154-161` and
`CLAUDE.md:252-253` warn that a copied linked worktree drives git against the original's admin dir.
Meanwhile the code deliberately accepts a pointer file: `project/resolver.rb:61-67`'s `GIT_ENTRY`
comment says *"this is only ever tested with `exist?`"*, used at `:438-446` and `:456-465`. And
`isolation/worktree/registry.rb:172-209` follows the pointer, checks bidirectionally via `names?`
(`:198-203`, comparing through `Project::Resolver.spellings`), then on failure falls through to
`#scanned` (`:192-196`) → `#common_dir` (`:207-209`), which runs
`git rev-parse --path-format=absolute --git-common-dir` **through the pointer into the original
repo** and returns `""` rather than raising.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lain.gemspec`,
  `.rubocop.yml`, `spec/spec_helper.rb`.
- **T5 needs a line in `lib/lain.rb` before the seal at `:146`.** That is a wiring diff the
  orchestrator applies, and its *position* is load-bearing: after `require "lain/lain"` (`:120`) so
  the Rust class exists, before `Lain::Algebra.registry.seal` (`:146`) so the declaration is
  accepted. A card cannot place it.
- This plan is independent of simplify-01 and may run beside it, with one exception: **T1 and T6
  produce no new class**, so neither needs the raised Metrics limits. If either grows a collaborator
  during implementation, escalate rather than splitting a class to fit the current cap.

## Open decisions

- **None gating a card.** T5 is optional by design — `spec/algebra_laws_spec.rb`'s own doc says a
  declaration *"is what makes the laws RUN HERE, never a precondition for running them anywhere
  else"*. It is included because the registry going quiet unnoticed is the "stale enumeration"
  failure the project already dislikes, and because simplify-13 depends on it. If the human declines
  it, drop T5 and the plan stands.

## Waves

Wave 1: T1, T2, T3, T4, T6, T7
Wave 2: T5 (←T4)
Critical path: T4 → T5

Wave 1 is wide because these defects are independent — different files, different subsystems, no
shared state. T5 follows T4 only because both touch the Rust Timeline surface and landing them
together in one wave would put two cards on `ext/lain/src/lib.rs`.

## Tasks

### T1 — One classifier per run, threaded rather than defaulted   [wave 1] [risk: high]

**Depends on:** none
**Files:** modify `lib/lain/cli/command/surface.rb`, `lib/lain/cli/command/survey.rb`,
`lib/lain/cli/survey.rb`, `lib/lain/cli/wiring/board_build.rb`;
modify `spec/lain/cli/command/surface_spec.rb`, `spec/lain/cli/command/survey_spec.rb`,
`spec/lain/cli/survey_spec.rb`
**Reuse:** `BoardBuild.classifier` (`board_build.rb:187-189`) already builds the one classifier from
the hoisted table — thread *it*, do not build another. `BoardBuild::Classifiers` (`:287`, `:295`)
is the existing per-cwd re-anchoring seam and stays. `command/survey.rb:95-99`'s ledger docstring is
the argument to copy for why `sensitivity:` becomes required.
**Shared-file wiring:** none
**Reachable from:** `CLI::Command::Surface#review_commands` (`command/surface.rb:154-157`)
constructs `Survey` on the live REPL path; AC 3 drives a `/survey` through a surface assembled the
way `CLI::Wiring` assembles it, not through a hand-built `Survey`

Three changes, in this order:

1. Thread the board's classifier into `command/surface.rb:156`'s `Survey.new(...)`.
2. Make `sensitivity:` **required** on `CLI::Command::Survey` and delete the `classifier` fallback at
   `command/survey.rb:271-274`.
3. Give `cli/survey.rb` a resolved `Project` instead of a bare `cwd:`, so the table comes from
   `project.root` and the anchor from `project.cwd`.

Change (3) is where the risk sits, because of `root_defaults_spec.rb`. Do not add a
`root: Dir.pwd` default to satisfy it — take a `project:` and let the caller resolve.

**Acceptance criteria**

```gherkin
Scenario: the gate and the listing agree after the config changes mid-session
  Given a project config denying "secrets/*"
  And a chat session whose board compiled that table at startup
  When a turn rewrites the config to deny nothing
  And a survey then lists the project
  Then the survey withholds the same paths the gate still refuses

Scenario: a survey cannot be built without a classifier
  When a survey command is constructed with no sensitivity
  Then construction is refused

Scenario: the REPL's own survey uses the board's classifier
  Given a command surface assembled the way the wiring assembles it
  When its survey command is asked for its classifier
  Then it is the same object the board's gate holds

Scenario: a standalone survey from a subdirectory honours the project's rules
  Given a project at some root denying "secrets/*"
  And a working directory two levels below that root
  When a standalone survey opens a path under "secrets/"
  Then it is withheld

Scenario: a malformed config degrades rather than raising mid-chat
  Given a project config that does not parse
  When a survey runs
  Then it reports a notice
  And it classifies with the built-in rules
```
→ spec files: `spec/lain/cli/command/survey_spec.rb` (AC 2), `spec/lain/cli/command/surface_spec.rb`
(AC 3), `spec/lain/cli/survey_spec.rb` (AC 4, AC 5), and AC 1 as a `:seam` example in
`spec/lain/seams/` — it spans the board, a tool write and a survey, so it belongs to no single
subject.

**Escalation triggers**
- **`spec/lain/project/root_defaults_spec.rb` (544 lines, Ripper) will fail** if change (3)
  introduces any cwd-reading keyword default, and its allowlist at `:98` counts duplicate labels. If
  the honest fix needs an allowlist entry, stop — that spec's premise is that the existing ~38 stay
  and a new one reddens, so adding one is a decision, not an implementation detail.
- `spec/lain/seams/survey_subdirectory_spec.rb` exists and exercises exactly the subdirectory case
  AC 4 describes. Read it before writing AC 4 — if it already asserts the *current* (broken)
  behavior, that assertion is the thing to change and the change must be called out.
- `board_build.rb:295`'s `Classifiers#call` rescues `StandardError` and falls back to the eager
  `@session` classifier (`:296-297`). If threading makes that rescue reachable from `/survey` where
  it was not before, stop — a silent fallback on the survey path would reintroduce the divergence in
  a new shape.
- If making `sensitivity:` required breaks a spec that constructs `Survey` directly, that spec is
  telling you how many places build one. Report the count before changing them; more than three
  suggests the seam is wrong.
- `ARCHITECTURE.md:498` must be corrected in this card — the invariant is now "one `Sensitivity.new`
  per run", not "one `Filter.new` in `lib/`". Leaving the old claim is worse than the old code.

### T2 — Give the consolidation pass the same four guards as its twin   [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/consolidation.rb`, `spec/lain/consolidation_spec.rb`
**Reuse:** `CLI::ToolGuard.detached(journal:)` (`cli/tool_guard.rb:103`) is exactly this — a stack a
detached run builds for itself — and `cli/improve.rb:196` is the working precedent, with its
rationale at `improve.rb:21-25`
**Shared-file wiring:** none
**Reachable from:** `Consolidation`'s agent construction at `consolidation.rb:95` passes
`tool_middleware:`; AC 3 drives a consolidation pass built the way `CLI::Consolidate` builds one

`consolidation.rb:111`'s one-guard stack becomes `ToolGuard.detached`. Note the journal asymmetry
documented at `:108-110` and the reason for a tool-phase guard at `:88-89` — both stay true, they
just apply to four guards instead of one.

**Acceptance criteria**

```gherkin
Scenario: a consolidation pass refuses a write to a denied path
  Given a consolidation pass over a project denying "secrets/*"
  When the model writes to "secrets/key.pem"
  Then the write is refused

Scenario: a consolidation pass masks a read of a denied path
  Given the same project
  When the model reads "secrets/key.pem"
  Then the content is masked

Scenario: a consolidation pass withholds a denied path from a listing
  Given the same project holding one denied and one permitted file
  When the model lists the directory
  Then only the permitted file appears

Scenario: the two detached passes build the same guard stack
  When a consolidation pass and an improve pass are each asked for their tool middleware
  Then both stacks hold the same guard classes in the same order
```
→ spec file: `spec/lain/consolidation_spec.rb`

**Escalation triggers**
- `ToolGuard.detached` takes only `journal:`, while `ToolGuard.layered` takes `inputs` and `roots`.
  If `detached` turns out to supply a *weaker* `GuardTestLayout` than the chat path does, say so —
  the goal is parity with `improve`, not with chat, and the difference should be recorded rather than
  quietly accepted.
- `Middleware::GuardTestLayout` raises `Unjudged` (`guard_test_layout.rb:128`), rescued at `:118` in
  the same file. It is one of T6's seven `StandardError` classes. If adding this guard to
  consolidation makes `Unjudged` escape where nothing rescues it, stop and sequence after T6.
- `consolidation.rb` reopens its own class (`:23` and `:126`). Do not un-reopen it here — that is
  simplify-04's scope.

### T3 — Make flag resolution resolve flags and open no sockets   [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/cli/backend.rb`, `lib/lain/cli/backend/num_ctx.rb`,
`lib/lain/cli/chat_launch.rb`; modify `spec/lain/cli/backend_spec.rb`,
`spec/lain/cli/chat_launch_spec.rb`
**Reuse:** `Backend#num_ctx` is already memoized (`backend.rb:274`) — keep the memo and move only
*when* it is forced. `chat_launch.rb:119-124` states the rule this card restores, and
`Backend::SpanSummarizer.resolve` is named there as the pattern that already avoids a live round trip
**Shared-file wiring:** none
**Reachable from:** `CLI::ChatLaunch#preflight` (`chat_launch.rb:112-150`) → `#constructed` (`:134`)
→ `Backend.new`; AC 1 drives preflight with an unreachable `--api-base`

`backend.rb:138` drops its `num_ctx` call. The refusal `NumCtx` exists for must still fire — just at
the first turn rather than at construction — so this card must name where that is and prove the
refusal still happens (AC 3).

**Acceptance criteria**

```gherkin
Scenario: preflight opens no socket
  Given an api-base pointing at a port nothing listens on
  When the chat launch preflight runs
  Then it completes without a connection attempt

Scenario: constructing a backend opens no socket
  Given an api-base pointing at a port nothing listens on
  When a backend is constructed
  Then no connection is attempted

Scenario: an unservable context window is still refused
  Given a num-ctx above what the model was trained for
  When the first turn is taken
  Then it is refused, naming the trained maximum

Scenario: the refusal is still reported once
  Given the same unservable num-ctx
  When two turns are attempted
  Then the probe was made once
```
→ spec files: `spec/lain/cli/chat_launch_spec.rb` (AC 1), `spec/lain/cli/backend_spec.rb`
(AC 2-4)

**Escalation triggers**
- `backend.rb:127-139`'s `#initialize` deliberately forces four other things for their refusals
  (`summarizer_name`, `summarizer_max_tokens`, both `ollama_tier` arms) and the comment at `:129-135`
  explains why — including that it evaluates `#api_base` on the way in "so that flag stays validated
  for EVERY provider". **Only the `num_ctx` call moves.** If removing it also removes `#api_base`
  validation, stop.
- `num_ctx.rb:270-273` records that the refusal is memoized because *"{NumCtx}'s second refusal costs
  a round trip"*. If deferring it means the probe now happens on a hot path per turn, stop — that is
  a performance regression traded for a rule.
- `lain up` opens a cockpit pane. `backend.rb:129-135` says the summarizer flags refuse at
  construction so *"`lain up` cannot open a pane that dies at the first compaction."* If moving
  `num_ctx` later means a pane can now open and die at the first turn, that is the same class of
  defect in a new place — stop and report.

### T4 — Give `Ext::Timeline#ancestors` a block form   [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `ext/lain/src/lib.rs`; modify `spec/lain/rust/timeline_spec.rb`; create a `:seam`
example in `spec/lain/seams/`
**Reuse:** `lib/lain/timeline.rb:101-111` is the behavior to match exactly — yield per node, return
an Enumerator when no block. `magnus::block::block_given?` is the mechanism.
**Shared-file wiring:** none
**Reachable from:** `Lain::Ledger#unique_turns` (`ledger.rb:109`) is the caller whose silence this
fixes; AC 2 drives a real `Ledger` over an `Ext::Timeline`

Keep arity 0 — the method takes no *arguments*. Materialize the walk, **drop the mutex guard**, then
yield: `lib.rs:1456-1460` records that every walk reads `store.locked()` in a statement of its own
because a chained expression keeps the guard alive across a Ruby call. Yielding inside the walk would
call into Ruby while holding a non-reentrant lock, which is precisely that hazard. The consequence,
which must be written down: **the block form cannot be lazy**, and matching Ruby's laziness would
need a per-node FFI call, which `docs/rust-bindings.md` rule 4 forbids.

**Acceptance criteria**

```gherkin
Scenario: a block receives every ancestor, head first
  Given a Rust-backed timeline of three commits
  When ancestors is called with a block
  Then the block receives three turns
  And the first is the head

Scenario: a ledger prices a Rust-backed timeline
  Given a Rust-backed timeline whose turns carry usage
  When a ledger prices it
  Then the total is greater than zero

Scenario: no block returns an enumerator
  Given a Rust-backed timeline of three commits
  When ancestors is called with no block
  Then an enumerator comes back
  And taking two from it yields two turns

Scenario: the Ruby and Rust timelines answer the same block the same way
  Given the same three commits in a Ruby timeline and a Rust-backed one
  When each is walked with a block collecting digests
  Then the two collections are equal
```
→ spec files: `spec/lain/rust/timeline_spec.rb` (AC 1, 3, 4), and AC 2 as a `:seam` example driving a
real `Ledger`

**Escalation triggers**
- If the only way to yield is to hold `store.locked()` across the call, **stop**. `lib.rs:1456-1460`
  documents that hazard as already-fixed at ten sites, and reintroducing it at one is worse than the
  missing block form.
- `spec/lain/rust/timeline_spec.rb:165` asserts `store.size == 4` where `spec/lain/timeline_spec.rb:150`
  expects 8 — a deliberate payload-inline divergence (simplify-13's G3). If this card's changes touch
  that assertion, stop; it is not this card's to reconcile.
- `cargo test` never compiles `mod ffi` (`ext/lain/CLAUDE.md`), so a Rust-side test cannot cover this
  at all. The RSpec examples are the only coverage, and they need `rake compile`. If they pass
  without a rebuild, the build is stale — check before believing green.

### T5 — Declare `Ext::Timeline` in the algebra registry   [wave 2] [risk: low]

**Depends on:** T4
**Files:** modify `spec/support/algebra_generators.rb`; modify `spec/algebra_laws_spec.rb` if its
sweep needs a generator entry
**Reuse:** `lib/lain/timeline.rb:26`, `:159`, `:185`, `:225` are the four declarations to mirror,
including the refutation's reason prose verbatim. `spec/support/algebra_generators.rb` already holds
the populations the law groups draw from.
**Shared-file wiring:** `Lain::Ext::Timeline` is reopened in `lib/lain.rb` after
`require "lain/lain"` (`:120`) and **before** `Lain::Algebra.registry.seal` (`:146`), adding
`include Algebra::MeetSemilattice`, the two `meet_semilattice on:` lines and the
`not_a_meet_semilattice on: :causal_meets` line. **simplify-09's T3 may respell this**: it drops the six
`not_a_*` verbs in favour of calling `Algebra.registry.refute` directly, and if it lands after this card
the refutation added here is converted with the other two rather than left as the last caller of a deleted
verb. Write it in today's vocabulary; 09 owns the translation. The orchestrator applies that block; its position is
load-bearing in both directions.
**Reachable from:** `spec/algebra_laws_spec.rb` walks `Lain::Algebra.registry`, which
`lib/lain.rb:146` seals; AC 1 is that sweep finding the new entry

`spec/algebra_laws_spec.rb`'s own doc records that a declaration *"is never a precondition for
running them anywhere else — a Rust-backed Timeline cannot carry a Ruby concern and must not have
to."* So this is deliberate belt-and-braces: the reason to do it is that after simplify-13 deletes the
Ruby Timeline, the registry would otherwise lose its `meet_semilattice` entries with nobody noticing.

**Acceptance criteria**

```gherkin
Scenario: the registry names the Rust timeline's two lawful meets
  When the algebra registry is enumerated
  Then it holds a meet_semilattice claim for the Rust timeline's meet
  And one for its dominator_meet

Scenario: the registry records the refutation with its reason
  When the registry's refutations are enumerated
  Then causal_meets on the Rust timeline is refuted
  And its reason names incomparable maximal common ancestors

Scenario: the laws run against the Rust timeline and pass
  When the algebra law sweep runs
  Then the Rust timeline's two meets satisfy idempotence, commutativity and associativity
  And each meet sits below both its operands

Scenario: a declaration after the seal is still refused
  Given the registry is sealed
  When a further claim is filed
  Then it is refused
```
→ spec file: `spec/algebra_laws_spec.rb` (existing sweep; AC 4 already exists and must stay green)

**Escalation triggers**
- The declaration must go **after** `require "lain/lain"` and **before** the seal. If `lib/lain.rb`'s
  structure makes that impossible without reordering the file, stop — the seal being the last
  statement is stated as a property (`lain.rb:141-145`).
- `meet_semilattice on:` requires a named `bottom:`, and `Algebra::MeetSemilattice.refuse_unnamed_bottom`
  raises at load time without one. The Ruby bottoms are prose (*"the empty Timeline, per store"*)
  because a bottom is store-relative. Use the same prose; do not invent a value.
- If the law sweep needs a *generator* for `Ext::Timeline` and building one requires a store the
  generator cannot make cheaply, stop and report. A generator that mints a fresh store per example
  is the shape `spec/algebra_laws_spec.rb:163` already warns about for Timeline.

### T6 — Root six error classes where the renderer can reach them   [wave 1] [risk: low]

**Depends on:** none
**Files:** modify `lib/lain/declarative.rb`, `lib/lain/middleware/guard_test_layout.rb`,
`lib/lain/shell/pipeline.rb`, `lib/lain/tools/web_fetch.rb`, `lib/lain/frontend/reline.rb`;
modify `lib/lain/isolation/worker_id.rb`, `lib/lain/declarative/types.rb`
**Reuse:** `project/resolver.rb:469-470` is the stated pattern — rename an alien error to a
`Lain::Error` descendant *"so `exe/lain`'s `rescue Lain::Error` still catches them"*
**Shared-file wiring:** none
**Reachable from:** `exe/lain`'s four `rescue Lain::Error` sites (`:81-85`, `:90-96`, `:1071-1078`,
`:1150-1157`); AC 1 drives a command whose failure is one of the six

Six classes move from `StandardError` to `Lain::Error`. `error.rb:4`'s `Lain::Error` itself stays as
it is. Also drop the two needless root qualifications — `isolation/worker_id.rb:37` and
`declarative/types.rb:58` use `::Lain::Error` where neither namespace defines a shadowing `Error`, so
the qualification guards nothing.

`Declarative::DeclarationError` is the one to think about: it is a **programmer**-error root that
raises at declaration time, i.e. at load. Rooting it under `Lain::Error` makes it renderable, which
is arguably wrong for a load-time bug. Decide in the card and say which way and why.

**Acceptance criteria**

```gherkin
Scenario: a shell timeout reaches the user as a message, not a backtrace
  Given a command whose shell step exceeds its timeout
  When it is run through the CLI
  Then the failure is reported as a message

Scenario: every project error descends from the project's root
  When the project's error classes are enumerated
  Then each descends from the project's error root

Scenario: an internally rescued error still is
  Given a web fetch exceeding its byte cap
  When it runs
  Then it is handled inside the tool
  And no error escapes to the CLI

Scenario: the root qualification carries no meaning where no shadow exists
  When the two previously root-qualified classes are read
  Then neither namespace defines a shadowing error class
```
→ spec files: `spec/lain/error_taxonomy_spec.rb` (new, AC 2 and AC 4 — a small enumeration over
`Lain::Error.subclasses` and the classes named here), plus existing specs for AC 1 and AC 3

**Escalation triggers**
- `shell/pipeline.rb:74`'s `Timeout` is aliased as the `Exec::Timeout` contract at
  `lib/lain/exec.rb:48`, and `lib/lain/exec.rb:73` defines `Unenforced < Timeout`. Re-rooting the
  parent moves the child. If anything rescues `Timeout` expecting a `StandardError` that is *not* a
  `Lain::Error`, stop.
- `middleware/guard_test_layout.rb:128`'s `Unjudged` is `private_constant`. If re-rooting it makes it
  reachable by name from outside, that is a visibility change, not a taxonomy change — report it.
- If any of the six is rescued by a **bare `rescue`** or by `rescue StandardError` somewhere that
  *depends* on it not being a `Lain::Error` — an `exe/lain` path that should show a backtrace for a
  programmer error, say — stop and name the site.

### T7 — Refuse to run against a copied worktree's original repository   [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `spec/spec_helper.rb`; create `spec/worktree_identity_spec.rb`
**Reuse:** `isolation/worktree/registry.rb:198-203`'s `names?` is the check, already written —
invert it and make it loud. `Project::Resolver.spellings` (`registry.rb:205`) already absorbs symlink
spellings and `worktree.useRelativePaths`.
**Shared-file wiring:** `spec/spec_helper.rb` is orchestrator-owned; the guard is one `require` plus
one call, handed back as a wiring diff
**Reachable from:** the guard runs at suite boot from `spec/spec_helper.rb`, so every spec run
exercises it; AC 1 is that boot refusing

The trap: a copy of a linked worktree has a `.git` **pointer file** whose `gitdir` names the
*original*, so specs drive git against the original's admin dir — and one run deleted the copy.
The guard: if `.git` is a file and its `gitdir` does not resolve back to this tree, abort the run with
a sentence naming both paths.

This is a **spec-suite guard, not a library change.** `project/resolver.rb`'s deliberate
`exist?`-only check stays — it is correct for production, where a linked worktree is legitimate.

**Acceptance criteria**

```gherkin
Scenario: a tree whose git pointer names itself runs
  Given a repository whose .git resolves to its own admin directory
  When the suite boots
  Then it proceeds

Scenario: a copied linked worktree is refused
  Given a directory copied from a linked worktree, whose .git pointer names another tree
  When the suite boots
  Then it aborts
  And the message names both the pointer's target and this tree

Scenario: a primary checkout with a .git directory runs
  Given a repository whose .git is a directory
  When the suite boots
  Then it proceeds

Scenario: a relative-path pointer resolves correctly
  Given a linked worktree using relative paths in its .git pointer
  When the suite boots
  Then it proceeds
```
→ spec file: `spec/worktree_identity_spec.rb` (AC 2-4 over fixture trees), with AC 1 implicit in
every other spec run

**Escalation triggers**
- **Do not create a real copied worktree inside the repository to test this.** The trap is that such
  a copy drives git against the original, and `docs/toolchain-traps.md:154-161` records one run
  deleting the copy. Build the fixture as a bare directory with a hand-written `.git` **file** whose
  `gitdir:` line points elsewhere; never run `git worktree add` and `cp -a`.
- The guard runs at boot for every spec process, including all twelve `pspec` workers. If it shells
  to `git` twelve times, that is measurable startup cost — prefer reading the pointer file directly,
  and if a `git` call is unavoidable, say so and measure it.
- `pre-commit` exports `GIT_INDEX_FILE` into every hook (CLAUDE.md:249-250). If the guard shells to
  git without scrubbing the environment, it will pass every normal run and fail at commit time.
  `registry.rb:213-215`'s `GIT_CONTEXT_SCRUB` is the existing answer.
- If `Project::Resolver.spellings` is `private_class_method` or otherwise not reachable from
  `spec/`, stop rather than duplicating its logic — a second spelling-comparison is the drift this
  guard exists to catch.

## Integration checks

After the last wave:

- `bundle exec rake pspec` green, **with the example count recorded**. T1 and T6 add examples; the
  count must rise, and a fall means a worker died.
- `bundle exec rubocop` clean with no new `rubocop:disable`.
- `bundle exec rake compile` then `bundle exec rspec spec/lain/rust/` — T4 changes the extension, and
  a stale `.so` makes its specs pass for the wrong reason.
- `bundle exec rspec spec/lain/sensitivity spec/lain/middleware spec/lain/cli/tool_guard_spec.rb` as
  a focused boundary run for T1 and T2.
- `bundle exec rspec spec/lain/project/root_defaults_spec.rb` — T1 changes a constructor signature on
  the survey path and this spec is the Ripper guard over exactly that shape.
- `pre-commit run --all-files`, since T7 touches `spec/spec_helper.rb` and pre-commit exports
  `GIT_INDEX_FILE`.
- **Manual, human:** one `lain chat` session that (a) reads a denied path, (b) has the model rewrite
  `.lain/config.toml`, then (c) runs `/survey .` — the exact sequence T1 closes. No scenario in
  `planning/qa/scenarios/` covers it, and it is the one defect here whose failure is silent.
- **Manual, human:** `lain chat --api-base http://127.0.0.1:1` and confirm the cockpit opens rather
  than refusing at construction (T3), then confirm the first turn fails with a message naming the
  unreachable base.
- Update `planning/qa/scenarios/` for the survey-classifier path and the preflight change — closing a
  chunk includes updating that enumeration.

## Execution log

**Base branch: `main`.** Grounding re-verified 2026-09-12 at `d2bb133c`, which is `main`'s head and
the base every card's worktree is cut from. `origin/main` sits at `b1927ce7`, **178 commits behind**
— any worktree forked from the remote would open a tree missing this entire plan's premises, so
worktrees are cut by hand from `HEAD` and re-cut at the top of every wave as landings move it.

No card's grounding had drifted: the four `Metrics/*` cops, `Rakefile`'s worker default and `default`
task, the five `Sensitivity.new` sites, `consolidation.rb`'s one-guard stack, `Backend#initialize`'s
`num_ctx` call, `ancestors` at arity 0 with no block, and the six non-`Lain::Error` classes all read
exactly as documented.

### What landed

| card | commit | note |
|---|---|---|
| T4 | `6bf0baa3` | block form yields after the store guard drops; neither form is lazy |

**T2's ACs were mis-specified and the plan text is corrected above rather than the code bent to fit.**
`ToolGuard.detached` mounts four guards, of which two do anything for the clerk's toolset:
`RedactSecretReads` starts masking, and `RefuseSecretWrites` gains a contentlessness floor.
`WithholdSecretPaths` holds `Filter::Null` and `GuardTestLayout` guards only `write_file`/`edit_file`,
which the clerk does not hold — both are parity of shape, not new enforcement. The Intent line claims
a *stack*, and the stack is delivered.

**T3's third escalation trigger fired and the card lands anyway.** `lain up --num-ctx` above the
trained maximum no longer refuses on the operator's terminal; the pane opens and dies. The two
requirements are in direct conflict — a preflight that "asks no server anything" cannot check a
trained maximum — and the rule wins, because refusing at preflight stops the cockpit opening for a
server that is merely down. The death is loud: `remain-on-exit failed` plus `PaneCorpse` reading the
scrollback back.

**T7 found a second instance of the `rm .git` trap.** A `cp -a` of a *submodule* leaves a `.git`
pointing into `.git/modules/<name>`, whose `core.worktree` still names the original checkout, so git
in the copy writes into the original's working tree. A legitimate submodule is accepted because its
admin names this checkout back; a copy answers with somebody else's path.

### Integration checks

Run at `f3be3975`, with six of seven cards landed.

- `bundle exec rake pspec` — **17,974 examples, 0 failures, 14 pendings**, against a pre-plan
  baseline of 17,942. The count rose, which is the direction that matters: `parallel_tests` reports
  only the examples that survived, so a fall is how a dead worker disguises itself as a pass.
- `bundle exec rubocop` — 1,567 files, no offenses, and **zero new `rubocop:disable`** anywhere in
  `lib/`, `spec/` or `exe/` across the whole range.
- `rake compile` then `spec/lain/rust/` — 259 examples, 0 failures on a freshly built `.so`, since a
  stale one makes those specs pass for the wrong reason.
- `spec/lain/sensitivity spec/lain/middleware spec/lain/cli/tool_guard_spec.rb` — 420 examples, 0
  failures.
- `spec/lain/project/root_defaults_spec.rb` — 38 examples, 0 failures, with **two allowlist entries
  removed and none added**.
- `bundle exec yard-lint lib/` — 3 defects, all in files this run never opened
  (`cli/epic_submit.rb`, `cli/wiring/board_build.rb`, `project/repository.rb`). Not a regression.

**`bundle exec rspec --tag core` is RED, and was red before this work started.** 42 examples, 7
failures, every one `Lain::Tools::CoreExec against the real daemon` raising
`tool_use_id must name the call this record is about, got nil` — a record validation, nothing to do
with the daemon binary. Verified by running the same tier at `289000e0` in a throwaway worktree:
**identical 7 failures**. This matters because simplify-01's T6 moved the binary path and this plan
names that tier as the check for it, so without the baseline comparison the failure reads as a
regression from a card that did not cause it.

**Two `git stash` entries predate this work** (2026-07-28 and 2026-08-09, the second from a prior
session's `worktree-agent-*`). Left untouched: the stash is shared between worktrees and popping
somebody else's entry is the hazard CLAUDE.md names.

### Closed

All seven cards landed. `ba413db6` (survey classifier), `f3be3975` (worktree identity guard),
`333caad7` (no socket at flag resolution), `402d15cf` (Rust timeline's algebra claims), `0da022e0`
(consolidation guards), `5c53cdba` (error taxonomy), `6bf0baa3` (`#ancestors` block form).

Final: **18,013 examples, 0 failures, 14 pendings**; `pre-commit run --all-files` green on every
hook; `bundle exec rubocop` clean over 1,568 files with zero new `rubocop:disable`.

**What the panel caught that a green suite did not.** T1's AC 5 degradation was unreachable from
`exe/lain`: `project: Resolver.default_project` is a *keyword default*, evaluated on entry to
`#initialize`, and the resolver parses every `.lain/config.toml` it walks — so `Config::Malformed`
escaped before the card's rescue could run, and the spec passed only because it injected a Project.
A spec and production believing different things about the secret boundary is the exact failure this
card was opened to close, reproduced one level up. The degradation was deleted rather than patched;
`exe/lain`'s `rescue Lain::Error` already renders the refusal without a backtrace.

**Two corrected pages had re-acquired false claims about the boundary.** `ARCHITECTURE.md` briefly
said `PATH_FIELDS` does not gate a `write_file` — it does (`policy.rb:75`), and the real reason a
turn can rewrite the config is that the path classifies *ordinary*. And the retracted "no second
filter can be constructed" claim survived at a fourth site, cited by a comment added in the same fix
round. Both are why the invariant is now stated as a discipline (`Filter.new` in exactly one place
in `lib/`) rather than an impossibility: `Filter` is a public constructor over anything answering
`#classify`, and `Policy` is now such a thing.

**T7 found a second door into the `rm .git` trap.** A `cp -a` of a *submodule* leaves an admin whose
`core.worktree` still names the original checkout, so git in the copy writes into the original's
working tree. The guard asks in both spellings, so a real submodule is accepted and a copied one
refused.

**T3's escalation resolved against the card.** `lain up --num-ctx` above the trained maximum no
longer refuses on the operator's terminal. The preflight rule and that refusal cannot both hold — the
check is a question to the server — and the rule wins, because refusing at preflight stops the
cockpit opening for a server that is merely down.

### Still owed

- **Manual, human:** one `lain chat` that reads a denied path, has the model rewrite
  `.lain/config.toml`, then runs `/survey .` — the sequence T1 closes, and the one defect here whose
  failure is silent. And `lain chat --api-base http://127.0.0.1:1`, confirming the cockpit opens and
  the first turn fails naming the unreachable base.
- **`planning/qa/scenarios/` is stale in two places.** `session-and-window.md` §1 heads its block
  "must refuse by name at construction" and lists `--num-ctx 999999`; that step still passes but now
  refuses at launch, so the header needs splitting. Nothing covers the survey-classifier path.
