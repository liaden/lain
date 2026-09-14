# Simplify 09 — orders are types, laws live with their subject, and an operation gets a name

status: in-progress
commit-mode: orchestrator-commits
language: ruby, with one rust card (T2)
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson; Edward Kmett and Philip Wadler join for T1–T4; Raph Levien, Andrew Gallant, Frank McSherry and Ashley Williams review T2

Supersedes `simplify-09-operations-as-objects.md` (dropped 2026-09-13). Rebuilt 2026-09-14 from
`research-orders-as-types-and-simplification.md` and two exploratory spikes, on the human's four
rulings recorded there: delete the registry and hold laws per subject; retire the Ruby dominance and
causal implementations; land the Rust trait with the orders exposed to Ruby; revive the three
handler-and-pipeline cards the old plan carried.

## Intent

Lain says which of its operations are which algebraic structures through a runtime registry that
classes file into at load and one spec sweeps. That machinery is ~740 `lib/` and ~2,900 `spec/` lines
for 20 claims, it is the one thing blocking `simplify-11`'s Zeitwerk move, and it puts the claim in a
different artifact from its proof. This plan puts each proof beside its subject, makes the DAG's
*orders* the named things (`Dag::RenderAncestry` in Ruby, three zero-sized types behind a sealed
trait in Rust) with the Timeline as an element, and deletes the operations nothing calls rather than
porting their laws. Then it applies the same idea one level up: the tool-call chain becomes one
inspectable `Middleware::Stack` with two interpreters at the end and one builder for parent and
child, and the context pipeline gets a name so a run can select it and a session record can say
which one rendered.

Delivers: no `Lain::Algebra`; every live algebraic operation's laws running in its own spec; the
render order as a stateless `Dag::RenderAncestry`; dominance and causal ancestry implemented once,
in Rust, with the bindings' specs standing on fixtures rather than a Ruby oracle; `Effect::Handler`
as two interpreters with every decorator a middleware; one tool-stack builder; `--context-pipeline`
with a catalog, a journal field and spawn inheritance; and the docs and two downstream plans
corrected for all of it.

## Grounding

Verified 2026-09-14 against `main` @ `9368e249` by four read-only passes over `lib/`, `spec/`,
`ext/`, `docs/` and `planning/`. Two spikes (`.claude/worktrees/agent-ad39e9a42aa2c1453` Ruby,
`.claude/worktrees/agent-a0d26dfa274768340` Rust) proved feasibility but were cut from `b1927ce7`,
340 commits behind; their diffs are reuse hints and **none of their line numbers or counts are
trusted below**.

**The registry, at HEAD.** `lib/lain.rb:35` requires it; `:141-160` reopens `Lain::Ext::Timeline`
to file three claims for a class nothing in `lib/` constructs; `:166` seals. Twenty declaration and
refutation sites in `lib/` (T3 lists them). Non-declaring readers in `lib/`: **none** —
`Compaction::DerivationAudit` is gone (simplify-03) and `Algebra::Pure#pure?` has no `lib/` caller.
`bin/spec-census --check` is **already red** on `main` (`assertions: 185 > 184`; `lib_reach: 76` at
its ceiling); seven of the 76 `lib_reach` entries are algebra verbs that vanish with the directory.

**Which declared operations production calls** (outside the declaring class): `Context::Combinator#>>`
(4 sites), `Usage#+` (`ledger.rb:54,76`, `event/projection.rb:89`), `Compaction::Strategy::Base#|`
(`cli/compaction_strategy.rb:169`), `IntervalPartition#meet` (`compaction/strategy/composed.rb:124`),
`Toolset#only` (4 sites), the elementwise and pure strategies' `#blocks`/`#call` (the pipelines).
**None:** `Middleware::Base#>>` (and so `Middleware::Composed`; every production stack is a
`Middleware::Stack`, and `cli/wiring.rb:539-541` says why), `Strategy::Replacement#+` (folded by hand
in `replacement.rb:35-56`, verify), `Timeline#meet`/`#&`/`#diverge_at`/`#dominator_meet`/`#causal_meets`
(eight **spec** callers of `#meet` outside `timeline_spec.rb`; zero in `lib/`).

**The three meets.** `timeline.rb:144-155` (`meet`, `&`), `:164` (`diverge_at`), `:178`
(`causal_meets`), `:215-217` (`dominator_meet`); `CausalAncestry` `:267-318`; `Dominators` `:320-362`
with `Tree` `:365-455`; `CrossStore` `:28`, raised `:260-264`. Rust has all three as plain functions:
`dag.rs:213` `meet`, `:236` `ancestor_of`; `graph.rs:101` `dominator_meet`, `:124` `dominates`, `:158`
`causal_meets` (over `petgraph`). No trait or ZST algebra exists in the crate; laws are eight hand-written
`#[test]`s (`dag.rs:405-467`, `graph.rs:685-750`) behind banners (`dag.rs:390-403`, `graph.rs:654-683`).
`ext/lain/CLAUDE.md:138-142` permits a trait exactly when "a production Rust function is generic over
the structure". The Rust spike's clippy run enforced that rule as dead-code errors until the FFI
became generic — which is the consumer.

**Rust bindings' specs use Ruby as their oracle** for dominance and causal:
`spec/lain/rust/dominator_meet_spec.rb` (`Lain::Timeline::Dominators.new` `:156`, byte-identical
refusal `:140,:186`), `causal_meets_spec.rb` (`:11-19`, message parity `:172-175`). `timeline_spec.rb`
includes the shared law group at `:243` and `:325` against `Ext::Timeline` directly — the Rust side was
never dependent on the sweep. `MeetSemilatticePopulations` lives at
`spec/support/shared_examples/meet_semilattice.rb:78-118`.

**The handler family.** Seven classes: `Live`, `Mock`, `Recorded` interpret; `Gate`, `Sensitivity`,
`Summarizing`, `Tools::Subagent::RefusingHandler` decorate. Production constructs `Live` (6 sites),
`Gate` and `Sensitivity` (`switchboard.rb:214-217`, `subagent.rb:1213-1219`), `RefusingHandler`
(`subagent.rb:1183`, reachable only under the `:handler_union` posture, which nothing in `lib/` or
`exe/` selects). **`Mock`, `Recorded` and the `Summarizing` decorator have zero production
construction.** `Recorded.from_journal` (`recorded.rb:29`) reads a top-level `type: "tool_result"`
record no writer in `lib/` emits, so it always builds `{}`. The live thing under the `Summarizing`
name is `Summarizing::Observer`, mounted at `cli/backend.rb:348` and read at
`agent/tool_runner.rb:30-31`, `oracle/routed_summarizer.rb:51,:172`, `compaction/summary_snapshot.rb`.
The two mechanisms meet at `agent/tool_runner.rb:455`; the tool is resolved twice (`gate.rb:111` via
`tool_named`, `live.rb:65` via `@toolset.fetch`) and `tool_runner.rb:390` walks `tool_named` a third
time for `parallel_safe?`. The secret middlewares already read the effect from env and never hold a
tool (`refuse_secret_writes.rb:92`, `redact_secret_reads.rb:189`, `withhold_secret_paths.rb:200`).
The tool-phase stack is built by `cli/tool_guard.rb:82-87` (`#layered`), **not** `board_build.rb`.
`CLI::Wiring::AgentBuild` does not exist; the parent `Agent.new` is inline at `cli/wiring.rb:482-489`
and passes `snapshot_slot:`; the child's `spawn_agent` (`subagent.rb:1133-1141`) does not. `Seam` has 14
members (`subagent.rb:755-756`), built at `cli/wiring/toolset_build.rb:328-338` and `cli/epic_submit.rb:556`.

**The context pipeline.** `context.rb:39-41` is the one hardcoded composition; `:48` `REQUIRES` is a
load-time snapshot of it; `:75-79` already says never to read the constant. No production
`Context.new` passes `pipeline:` (`cli/backend.rb:235`, `role.rb:62`, `tool/spawn_policy.rb:196`,
`bench/session/loader.rb:22` — the last drops a recorded pipeline on reload, which
`bench/variance.rb:83` notes). `compaction/source.rb:589` swaps per turn via `with_pipeline`, and
`:305-311` states the defect: the scheduler "is handed a pipeline and cannot name the policy".
Five combinators have never been constructed anywhere in `lib/`: `Prune`, `DedupeToolCalls`,
`PurgeFailedInputs`, `TailInjection`, `MessageEnvelope`. The only non-default pipeline in the tree is
`bench/plan_sweep/driver.rb:40`'s `BASE_PIPELINE`, a `->(workspace)` provider. Precedent to copy:
`cli/compaction_strategy.rb` (`STRATEGIES` `:107`, `SEPARATOR` `:111`, fold `:169`, refusals
`:191,:222,:240`) and `exe/lain:833-836` with the no-default rationale at `:818-831`.
`SessionRecord.header` (`session_record.rb:43-49`) writes `type`, `context_class`, `model`,
`max_tokens`, `system`, `stream`, `extra`, `head`, `tools`, `reminders`, optional `resumed_from`;
`context_class` reads `"Lain::Context"` in every real run. `pipeline` is already three words in this
codebase (plan step pipeline, shell pipeline, context pipeline), so the flag is `--context-pipeline`.

**Algebra-adjacent, checked and not carded.** `Mode::Posture#attenuate` already delegates to
`Toolset#only` (`mode/posture.rb:15,:74`) — one attenuation, not two. `Capability::DegradedSet`
records what a *provider* withheld and carries no operation; not a duplicate. `Ledger`'s folds seed
`Usage.zero` by hand (`ledger.rb:54,76`); fine as they are. Six Null Objects behave as identities and
claim nothing (`PinnedMessages::NONE`, `ProtectedPatterns::NONE`, `Mailbox::Null`,
`PipelineSource::Null`, `Channel::Null`, `Posture::Permits::All`); no action.

**Docs that the code will falsify** are enumerated on T8. `ARCHITECTURE.md:364-365` (`#middleware_app`)
and `:671-672` (`build_agent`) are already stale today.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lib/lain/cli.rb` (require
  block `:17-69`), `lib/lain/middleware.rb` (require block `:163-171` only), `exe/lain`,
  `.rubocop.yml`, `spec/spec_helper.rb`, `lain.gemspec`, `ext/lain/Cargo.toml`.
- **`ARCHITECTURE.md`, `docs/GLOSSARY.md` and `ROADMAP.md` are T8's files.** No other card edits
  them; a card that falsifies a sentence hands the correction to T8 in its report. This is what keeps
  the plan clear of `simplify-08`, which also edits `ARCHITECTURE.md`.
- `spec/lain/rust/*_spec.rb` belong to T4 (existing files) and T2 (one new file). T1 may only reroute
  a `Lain::Timeline#meet`/`#diverge_at` call in them and nothing else.
- `simplify-08` and `simplify-10` are in progress. Known overlaps: `spec/lain/tools/subagent_spec.rb`
  (10 modifies it; here only T1 touches it, for one `.meet` reroute at `:299`), `lib/lain/bench/spawn_seam.rb`
  (08; T6's builder must not become its third caller without saying so), `lib/lain/bench/sweep.rb`
  (08; T7 counts one `Context::Recall.new` there and does not edit it).
- The `bin/spec-census --check` ratchet is red on `main` before this plan starts. No card raises a
  ceiling; T3 lowers `lib_reach` and reports the new count in its commit message.

## Open decisions

- **`Dag::RenderAncestry.meet` and `.diverge_at` have no production caller after T1**, exactly as
  `Timeline#meet` had none before. Cache-break localisation is specified (`ARCHITECTURE.md:141-208`)
  and unwired; this plan moves the operation and does not wire it. A consumer is a bench feature
  (a `diverge_at` report in the dry-replay diff), not a naming one. T1 records this on its card.
- **`Lain::Ext::Dag::*` is unreachable from production until the store flips.** Every `Ext::Timeline`
  binding already has zero production callers; T2 adds a Ruby-visible order surface on the same
  footing and routes the *existing* bindings through the trait. Wiring is `simplify-13`'s (its T10/T11),
  amended by T9 here.
- **The `:handler_union` spawn posture is unselectable from any `lain` command.** `RefusingHandler`
  is therefore reachable only through specs. This plan keeps it and moves it to `Middleware` (T5); a
  posture is a study axis and giving it a door is `simplify-08`'s shape, not deletion.
- **`Effect::Handler` keeps its name** after T5 leaves it two interpreters. `Effect::Interpreter`
  would be truer and touches every construction site; not worth a rename in this plan.
- **The pipeline is recorded in the header only.** The compaction swap is a composition over the
  base, not a catalog word, and the scheduler already journals the collapse strategy that names it
  (`scheduler.rb:194,:260`). A turn-level field would be either a made-up spelling or a duplicate.
- **Zeitwerk (`simplify-11`) becomes unblocked by T3** and is not run here.

## Waves

Wave 1: T1, T2, T5
Wave 2: T3 (←T1), T4 (←T1), T7
Wave 3: T6 (←T5)
Wave 4: T8 (←T1–T7), T9 (←T1–T7)
Critical path: T5 → T6 → T8

T7 has no dependency but sits in wave 2 because it and T1 both edit
`spec/lain/tool/spawn_policy_spec.rb`. T3 and T4 both follow T1 because the algebra directory cannot
be deleted while `timeline.rb` includes a module from it, and `timeline.rb`'s declarations cannot go
while the sweep still expects their generators — T1 removes both together.

## Tasks

### T1 — Make the render order a type and take every declaration off `Timeline`   [wave 1] [risk: high] ✅ landed `62aa555d`

**Depends on:** none
**Files:** create `lib/lain/dag.rb`, `lib/lain/dag/render_ancestry.rb`,
`spec/lain/dag/render_ancestry_spec.rb`; modify `lib/lain/timeline.rb`,
`spec/lain/timeline_spec.rb`, `spec/support/algebra_generators.rb` (remove the five Timeline and
Ext::Timeline entries and the `Timelines` module), `spec/lain/actor_spec.rb:77,85`,
`spec/lain/tools/subagent_spec.rb:299`, `spec/lain/tools/subagent_sibling_template_spec.rb:257-258`,
`spec/lain/tool/spawn_policy_spec.rb:41,108`, `spec/lain/bench/speculative_spec.rb:55`, and any
`Lain::Timeline#meet` reroute in `spec/lain/rust/timeline_spec.rb`
**Reuse:** the spike's `lib/lain/dag/render_ancestry.rb` in
`.claude/worktrees/agent-ad39e9a42aa2c1453` is the shape (stateless `module_function`, `meet`,
`diverge_at`, `below?`, `Dag.same_store!`); `spec/lain/timeline_spec.rb:156-229` is the existing
law run and cost examples to move, and `:188-212` already includes the shared group directly
**Shared-file wiring:** `lib/lain.rb`: add `require_relative "lain/dag"` immediately before
`require_relative "lain/timeline"`; delete the `module Ext / class Timeline` block at `:141-160`
**Reachable from:** deferred: cache-break localisation is specified and unwired, so
`Dag::RenderAncestry.meet` has the same zero production callers `Timeline#meet` had — recorded in
Open decisions. What *is* on the production path is `Timeline#ancestor_of?`, which stays on
`Timeline` and which `RenderAncestry.below?` delegates to.

`Lain::Dag::RenderAncestry` is a stateless module: `meet(a, b)` (Timelines in, Timeline out),
`diverge_at(a, b)`, `below?(a, b)`. `Dag::CrossStore < Error` and `Dag.same_store!` are the one
refusal, and `Timeline::CrossStore = Dag::CrossStore` keeps every existing by-name assertion true.
`Timeline` loses `#meet`, `#&`, `#diverge_at`, `include Algebra::MeetSemilattice`, and **all four
declaration lines** (`:26`, `:159`, `:185-190`, `:225`). `#causal_meets`, `#dominator_meet`,
`CausalAncestry` and `Dominators` **stay in this card** — undeclared — and T4 retires them; splitting
it this way is what lets T3 and T4 run in parallel.

The laws for the render meet run in `spec/lain/dag/render_ancestry_spec.rb` through
`include_examples "a meet semilattice under ancestry"` with `meet:` and `ancestor_of:` lambdas
naming the module, over the same forest `timeline_spec.rb:188-212` builds today. The
`"the declared algebra"` block (`timeline_spec.rb:527-548`) is deleted: it asserted registry
contents.

**Acceptance criteria**

```gherkin
Scenario: the render meet of two heads sharing a prefix is the last shared commit
  Given two timelines over one store that diverged after a common prefix
  When the render order's meet is taken
  Then it is the last shared commit

Scenario: the render meet is total at the bottom
  Given a timeline and the empty timeline over the same store
  When their render meet is taken
  Then the empty timeline comes back

Scenario: the render order obeys the four semilattice laws
  Given a random forest over one store
  When the shared law group runs against the render order
  Then it is idempotent, commutative, associative, and orders a meet below both operands

Scenario: heads from two stores are refused by name
  Given timelines backed by different stores
  When their render meet is attempted
  Then it is refused, and the refusal is the same class Timeline named before

Scenario: divergence is still localisable
  Given a timeline forked and both branches extended
  When the render order is asked where they diverged
  Then the last shared event is named

Scenario: a timeline no longer answers a meet of its own
  Given a timeline
  When it is asked for a meet
  Then it does not respond to that message
```
→ spec files: `spec/lain/dag/render_ancestry_spec.rb` (AC 1–5), `spec/lain/timeline_spec.rb` (AC 6)

**Escalation triggers**
- `spec/lain/rust/timeline_spec.rb:93-104` and `:170-178` compare against `Lain::Timeline`. If any
  of those comparisons is a `#meet`, reroute it to `Dag::RenderAncestry.meet` and nothing more; if
  the file needs any other edit, stop — it is T4's.
- The shared group's default knobs are `a.meet(b)` and `m.ancestor_of?(a)`
  (`spec/support/shared_examples/meet_semilattice.rb:32-34`). After this card those defaults fit
  `Ext::Timeline` and `IntervalPartition` only. Do not change the defaults; pass `meet:` explicitly and
  note the footgun in the new spec's header.
- `spec/algebra_laws_spec.rb` is still live in this wave. Removing the Timeline declarations without
  removing their generator entries fails its "none orphaned" example by name; removing the entries
  without the declarations fails "none missing". Both edits land in this card or neither does.
- `.rubocop.yml:179` names `lib/lain/timeline.rb` as the comment-density exemplar. If the file's
  shape after this card no longer supports that, report it; do not edit `.rubocop.yml`.
- `bin/spec-census` `lib_reach` counts `Timeline#diverge_at` today; a public `Dag::RenderAncestry`
  method with no `lib/` caller counts the same way. The ratchet is `<=`, so this card may not raise
  the figure. If it would, make `diverge_at` private to the module until a caller exists and say so.

### T2 — The three orders as zero-sized types behind a sealed trait, and the FFI generic over them   [wave 1] [risk: medium] ✅ landed `98085764`

**Depends on:** none
**Files:** create `ext/lain/src/algebra.rs`, `spec/lain/rust/dag_spec.rb`; modify
`ext/lain/src/dag.rs`, `ext/lain/src/graph.rs`, `ext/lain/src/lib.rs`, `ext/lain/CLAUDE.md`
**Reuse:** the spike's `ext/lain/src/algebra.rs` in `.claude/worktrees/agent-a0d26dfa274768340`
compiles clean on its base and is the design: `mod sealed { pub trait Proven {} }`,
`trait MeetSemilattice: sealed::Proven { type Ctx; type Elem; fn meet; fn below }` (the spike's
`const BOTTOM: &str` and its emptiness assert are dropped — the bottom is `None` by the `Elem` type,
and a docstring constant proves nothing; the associated types stay because `simplify-13`'s store
flip is exactly a change of `Ctx`),
`trait MaximalLowerBounds`, ZSTs `RenderAncestry`, `Dominance`, `CausalAncestry`, and
`declare_meet_semilattice!(Order, tests: name, population: path)` emitting the `Proven` impl, and the four law tests in one expansion. Populations:
`dag.rs:306-328` `law_population` and `graph.rs:417-455` `law_population` (make `mod tests` and both
`pub(crate)`)
**Shared-file wiring:** none (`ext/lain/Cargo.toml` is untouched — no dev-dependency is added)
**Reachable from:** every `Lain::Ext::Timeline#meet`, `#dominator_meet`, `#ancestor_of?`,
`#dominates?` and `#causal_meets` call (`lib.rs:1538-1644`) routes through the trait after this card,
so the trait is on the path of the binding; the binding itself has no production caller until the
store flips (Open decisions, and `simplify-13`'s T10/T11 as amended by T9)

Two generic FFI methods, `meet_via::<S>` and `below_via::<S>` bounded on
`MeetSemilattice<Ctx = StoreMap, Elem = Option<Digest>>`, replace the bodies of the five existing
bindings with one-line delegations; `ensure_same_store` (`lib.rs:1752`) runs **before** delegation so
`causal_meets_spec.rb:172-175`'s byte-identical refusal text is untouched. `use crate::graph` leaves
the FFI module. New Ruby-visible classes under `Lain::Ext::Dag` — `RenderAncestry`, `Dominance`,
`CausalAncestry` — with singleton methods `meet(a, b)` / `below?(a, b)` / `meets(a, b)` over
`Ext::Timeline` operands, registered beside `lib.rs:1966`.

**The eight hand-written law tests go** (`dag.rs:405-467`, `graph.rs:685-750`) with their banners
(`dag.rs:390-403`, `graph.rs:654-683`), because the macro emits the same four laws over the same
populations. Every non-law test stays, and
`graph.rs:636`'s `the_law_population_carries_a_pair_with_no_shared_history` must still see
`law_population`.

**`ext/lain/CLAUDE.md` is edited, not reversed.** `:138-142` is *satisfied*: `meet_via`/`below_via`
is a production function generic over the structure — cite it. `:129-136` ("inherits the Ruby
declaration") loses its premise once T3 lands and is rewritten to: the four law *names* stay pinned
to `spec/support/shared_examples/meet_semilattice.rb`'s, and that is the whole cross-language
contract. The `:146-149` table stands.

**Acceptance criteria**

```gherkin
Scenario: a type cannot claim the semilattice without its laws
  Given a type implementing the trait by hand, outside the macro and outside the algebra module
  When the crate is compiled
  Then compilation fails naming the private supertrait

Scenario: the set-valued order is not a semilattice by type
  Given a function generic over the semilattice trait
  When it is instantiated at the causal order
  Then compilation fails

Scenario: both semilattice orders pass the four laws from one expansion
  When the crate's tests run
  Then the render order and the dominance order each report four law tests
  And no hand-written copy of those laws remains in the crate

Scenario: the criss-cross witness exhibits the refutation
  Given a three-way criss-cross fan-in
  When the causal order's lower bounds are taken
  Then more than one maximal lower bound comes back

Scenario: the bindings answer as before through the trait
  Given a store of Rust timelines with shared and disjoint history
  When each existing timeline binding is called
  Then its answer is unchanged, including the cross-store refusal text

Scenario: Ruby can name the order and hand it two elements
  Given two Rust timelines over one store
  When the render order's meet is asked for from Ruby
  Then it equals what the timeline binding answers
```
→ spec files: none for AC 1–4 (compile-time and `cargo test`; AC 1 and AC 2 are checked by
temporarily adding the offending item and recording the `E0277` text in the commit message — a
**one-shot verification, not regression-held**: the crate has no doctest target and no `trybuild`,
and adding either is out of scope. The seal holds against every module *outside* `algebra.rs`; a
hand `impl sealed::Proven` inside that file compiles, which is why AC 1 says "outside");
`spec/lain/rust/dag_spec.rb` (AC 5, AC 6)

**Escalation triggers**
- `cargo test` never compiles `mod ffi`. Run `cargo clippy --all-targets -- -D warnings` before
  believing green; the spike's first clippy run rejected the trait as dead code until the FFI used it.
- If clippy still reports `MaximalLowerBounds` or `CausalAncestry` unused after the reroute,
  `causal_meets` did not go through the type — fix the route, never `#[allow(dead_code)]`.
- `spec/lain/rust/dominator_meet_spec.rb:140,:186` and `causal_meets_spec.rb:172-175` pin the
  refusal text byte-for-byte against Ruby. If the reroute changes one character, stop.
- State the expected `cargo test -p lain` count in the commit: `main` has 227; eight deleted,
  eight generated, plus the hand-written witness and generic-reads tests. The spike's arithmetic
  predicts 230; a different number needs a sentence.
- The scoped `#[deny(clippy::missing_docs_in_private_items)]` goes on `mod algebra;` like
  `dag`/`digest`/`graph`; every private item in the new module needs a doc comment.

### T3 — Delete the registry; a live operation's laws move to its subject, a dead operation goes   [wave 2] [risk: medium] ✅ landed `7a1d4602`

**Depends on:** T1
**Files:** delete `lib/lain/algebra.rb`, `lib/lain/algebra/` (6 files), `spec/algebra_laws_spec.rb`,
`spec/lain/algebra_spec.rb`, `spec/support/algebra_generators.rb`; modify `lib/lain/usage.rb:64,:102`,
`lib/lain/toolset.rb:22,:115`, `lib/lain/middleware.rb:20-42,:48,:73,:79,:88` (class body only — `Stack` includes `Composable` at `:88`),
`lib/lain/context/base.rb:23,:64`, `lib/lain/context/dedupe_tool_calls.rb:27,:101`,
`lib/lain/context/purge_failed_inputs.rb:103-106`, `lib/lain/interval_partition.rb:24,:311`,
`lib/lain/compaction/strategy/base.rb:85,:203`, `strategy/elide.rb:56-57,:83-84`,
`strategy/elide_tool_observations.rb:55`, `strategy/identity.rb:23,:32`,
`strategy/replacement.rb:98,:173`, `strategy/summarizing.rb:247-256`,
`strategy/summarize_conversation.rb:90-93`; modify `spec/lain/usage_spec.rb:167`,
`spec/lain/toolset_spec.rb:177,:199,:261-263`, `spec/lain/middleware_spec.rb`,
`spec/lain/context/base_spec.rb:40-44`, `spec/lain/context/dedupe_tool_calls_spec.rb:98`,
`spec/lain/context/purge_failed_inputs_spec.rb:116,:124-126`, `spec/lain/interval_partition_spec.rb`,
`spec/lain/compaction/strategy_spec.rb` (heaviest: `:6,:37-47,:65,:79,:94-95,:108,:147,:176,:259-267,:278,:317,:327,:337`),
`spec/lain/compaction/strategy/{composed,elide,elide_tool_observations,summarizing,summarize_conversation}_spec.rb`,
`spec/lain/compaction/derivation_spec.rb:61`, `spec/lain/question/document_spec.rb:197`,
`spec/lain/tools/parallel_commutation_spec.rb:181`, `spec/support/prop_check_setup.rb:3,:40`
(comment-only), `spec/support/shared_examples/{monoid,pure,attenuation,elementwise,monoid_homomorphism}.rb`
(headers cite the sweep; the `AlgebraLaws::*` battery modules inside `pure.rb`, `attenuation.rb`
and `elementwise.rb` **stay** — they are what a witness example runs)
**Reuse:** the spike's per-subject `include_examples` blocks and witness examples in
`.claude/worktrees/agent-ad39e9a42aa2c1453` (its `spec/lain/context/purge_failed_inputs_spec.rb`,
`compaction/strategy/summarizing_spec.rb`, `usage_spec.rb`, `toolset_spec.rb`,
`interval_partition_spec.rb`); the generator bodies in `spec/support/algebra_generators.rb`
(`Combinators`, `Usages`, `Spans`, `strategy_claims`, `middleware_claims`, `toolset_claims`,
`partition_claims`) are the populations to inline into the subject specs
**Shared-file wiring:** `lib/lain.rb`: delete `:35-36` (the require and its comment) and
`:162-166` (the seal and its comment); `.rubocop.yml`: delete `:323` and `:335`, reword the prose
at `:78`, `:257-260`, `:458-460`
**Reachable from:** every subject stays constructed where it is; nothing new is built. AC 6 drives
the one production fold that carries laws, `cli/compaction_strategy.rb:169`, through
`CLI::CompactionStrategy.resolve`

**The rule this card applies, per operation.** If the operation has a production caller, its laws
move into its subject's spec as `include_examples` with the population inlined and the evidence
(`identity:`, `analysis:`, `dual:`) at the call site. If it has none, **the operation is deleted**,
not ported: `Middleware::Composable#>>`, `Middleware::Composed` and the monoid claim go
(`Middleware::Identity` has no `lib/` reader — the only hit is a comment at `context/base.rb:14` —
and goes; `Middleware::Base` stays, every production middleware subclasses it);
`Strategy::Replacement#+` (`replacement.rb:49-56`) is called nowhere in `lib/` — `:35-48`'s `Vetted`
is the operation, not a caller — and goes with the privates only it used. `Middleware::Stack` is the composition mechanism and `cli/wiring.rb:539-541` already says
why.

`Algebra::Elementwise` stops generating code: `DedupeToolCalls#call` and `Elide#blocks` are written
by hand as the one-line `flat_map` each is. `Algebra::Pure#pure?` goes with its spec sites
(`strategy_spec.rb:259,:261`, `elide_spec.rb:128`, `elide_tool_observations_spec.rb:178`,
`summarizing_spec.rb:229`). Each of the four refutations becomes an ordinary example in the
subject's spec whose description is the recorded reason and whose body **exhibits** it
(`PurgeFailedInputs`: two equal messages take two images by position; `Summarizing`: one block
versus two-in-halves, and not `Ractor.shareable?`; `SummarizeConversation`: the same purity witness).

**Acceptance criteria**

```gherkin
Scenario: every live algebraic operation still runs its laws
  Given the suite
  When it runs
  Then the combinator composition, usage addition, strategy union,
       partition meet, and toolset attenuation each run their shared law group from their own spec

Scenario: a refutation is exhibited, not asserted
  Given a span whose first and last messages are equal
  When the purge combinator maps it
  Then the two equal messages receive different images
  And the elementwise battery reports the functional law failed and no law raised

Scenario: the generated whole-span maps are written by hand and unchanged
  Given a span with a stale tool use
  When the dedupe combinator runs
  Then its output is byte-identical to before the change

Scenario: nothing in lib names the algebra
  When lib is searched for the algebra namespace
  Then no file references it

Scenario: an operation with no caller is gone
  Given a middleware
  When it is asked to compose with another by the operator
  Then it does not respond to that message

Scenario: the one production fold over strategies still composes
  Given two compaction strategy names joined by the separator
  When the strategy is resolved on the real command path
  Then one composed strategy comes back and its union is commutative
```
→ spec files: each subject's own spec (AC 1, AC 3), `spec/lain/context/purge_failed_inputs_spec.rb`
(AC 2), `spec/output_discipline_spec.rb`-style enumeration is **not** added for AC 4 — it is a grep
recorded in the commit message; `spec/lain/middleware_spec.rb` (AC 5),
`spec/lain/cli/compaction_strategy_spec.rb` (AC 6)

**Escalation triggers**
- The spike found four operations whose **only** law run was the sweep (`Strategy::Identity`
  purity, `Replacement#+`, `Strategy::Base#|`, `IntervalPartition#meet`). Each needs a written
  group here; if one turns out to have no population that can be built without the registry's
  `Algebra.later` deferral, report the shape rather than inventing a unit.
- `spec/lain/compaction/strategy_spec.rb:37-47` injects `Algebra::Registry.new` to test per-registry
  behaviour. Those examples test the registry, not the strategy; delete them, do not port them.
- `strategy_spec.rb:255-269` pins that elementwise-ness reads off the module and purity off the
  registry. After this card both read off nothing. Replace the contrast with the two witness
  examples; do not keep a spec that asserts a mechanism that no longer exists.
- `bin/spec-census --check` is red before this card. Record `lib_reach` before and after in the
  commit; do not touch `CEILINGS` (`bin/spec-census:1039`).
- `spec/value_object_shareability_spec.rb:10-11` asserts class counts (`> 250`, ratio `> 0.75`).
  Modules are not classes so the count should be neutral; if it moves, report the numbers.
- `elementwise.rb:107-112`'s message, quoted in `ARCHITECTURE.md:1079`, is gone — hand T8 the
  sentence.

### T4 — Retire the Ruby dominance and causal implementations; the Rust bindings' specs stand on fixtures   [wave 2] [risk: medium] ✅ landed `047c55d6`

**Depends on:** T1, T2
**Files:** modify `lib/lain/timeline.rb` (delete `#causal_meets` `:178`, `#dominator_meet`
`:215-217`, `CausalAncestry` `:267-318`, `Dominators` and `Tree` `:320-455`),
`spec/lain/timeline_spec.rb` (delete `:239-301`, `:311-520`, `:554-564`), `spec/lain/rust/timeline_spec.rb`,
`spec/lain/rust/dominator_meet_spec.rb`, `spec/lain/rust/causal_meets_spec.rb`,
`spec/support/shared_examples/meet_semilattice.rb` (only if `MeetSemilatticePopulations` needs a
Rust-only shape), `docs/rust-bindings.md:30-32`
**Reuse:** `spec/lain/rust/timeline_spec.rb:260-325` already runs the dominance laws against
`Ext::Timeline#dominator_meet` with `dominates?` injected over `MeetSemilatticePopulations.union_graph`;
`graph.rs:458-636`'s named fixtures (deepest common dominator, stronger-than-reachability, causal
edges participate, every maximal lower bound) are the expected answers to transcribe into Ruby
fixtures; `planning/dominator-meet-research-2026-07.md` for the checkpoint shapes
**Shared-file wiring:** none
**Reachable from:** nothing constructs either implementation in production today; after this card
the only implementation is Rust and it is reached through `Ext::Timeline` and `Ext::Dag::Dominance`
/ `Ext::Dag::CausalAncestry` (T2), still spec-only until the store flips — Open decisions

`spec/lain/rust/dominator_meet_spec.rb` and `causal_meets_spec.rb` today diff every answer against
`Lain::Timeline`. With the Ruby implementation gone they assert **known answers over named
fixtures** — the checkpoint shape, the quiet-branch shape, the three-way criss-cross, the
no-shared-history pair — plus the shared law group with `dominates?` injected, and the criss-cross
witness (more than one maximal lower bound). Expected answers are named **structurally** — the
fixture's own timeline for that event — never as digest literals. The cross-store refusal is
asserted against the Rust class's own message, not Ruby's. The spec header says where the
*independent* check lives: the law run's `dominates?` comes from the same implementation as the
meet, which is self-consistent, and the discriminating fixtures are `graph.rs:458-636` at the
algorithm layer.

`docs/rust-bindings.md` rule 5 ("the same property tests must pass unchanged against both
implementations") is edited to say: **where both implementations exist**; an operation implemented
only in Rust is held to the shared law group and to fixtures whose expected answers are written
down, not derived from a second implementation.

**Acceptance criteria**

```gherkin
Scenario: the dominance meet is the checkpoint
  Given a parent branch, a spawned child anchored mid-branch, and the parent advanced past the anchor
  When the Rust dominance meet of the two heads is taken
  Then it equals the fixture's anchor timeline, named by the event it was built from

Scenario: the dominance order obeys the four laws over a union graph
  Given a random union graph of Rust timelines
  When the shared law group runs with dominance as the order
  Then all four laws hold

Scenario: the causal order answers every maximal lower bound
  Given a three-way criss-cross fan-in
  When the Rust causal lower bounds are taken
  Then more than one comes back, in digest order

Scenario: cross-store operands are refused by the Rust class
  Given Rust timelines over different stores
  When a dominance meet is attempted
  Then the Rust cross-store error is raised

Scenario: a Ruby timeline no longer answers dominance or causal questions
  Given a Ruby timeline
  When it is asked for a dominator meet or causal meets
  Then it does not respond to either message
```
→ spec files: `spec/lain/rust/dominator_meet_spec.rb` (AC 1, AC 2, AC 4), `spec/lain/rust/causal_meets_spec.rb`
(AC 3), `spec/lain/timeline_spec.rb` (AC 5)

**Escalation triggers**
- **A fixture's expected answer must be written before the Ruby oracle is deleted**, by running the
  Ruby implementation once and recording the digest-level answer in the spec. If an answer cannot
  be stated in terms a reader can check by hand (which event, by body text), the fixture is too big.
- `spec/lain/rust/timeline_spec.rb:260-324` builds its dominator knobs with `Timeline::Dominators`
  or with `Ext::Timeline#dominates?` — read which. If Ruby, rebuild on the Rust predicate; the law
  run must not silently lose its `ancestor_of:` injection and fall back to render ancestry.
- `ARCHITECTURE.md:189-206` specifies `dominator_meet` as the safe-compaction checkpoint. This card
  deletes the Ruby implementation of a specified, unbuilt feature; the spec's prose must say the Rust
  one is the implementation and hand T8 the sentence.
- `.rubocop.yml:179`'s comment-density exemplar is `timeline.rb`; this card removes ~190 lines of
  it. Report the new prose:code ratio; do not edit `.rubocop.yml`.

### T5 — Split `Effect::Handler`: two interpreters stay, every decorator becomes a middleware, the dead ones go   [wave 1] [risk: high] ✅ landed `75b26bc8`

**Depends on:** none
**Files:** modify `lib/lain/effect/handler.rb` (drop `inner:`, `handles?`/`perform` triad, `to_app`,
`UnhandledEffect`'s chain-walk, `tool_named`; the require block `:77-82` shrinks to `live` and
`mock`), `lib/lain/effect/handler/live.rb`, `effect/handler/mock.rb`; delete
`effect/handler/recorded.rb`, `effect/handler/summarizing.rb` (the decorator),
`effect/handler/gate.rb`, `effect/handler/sensitivity.rb`, `lib/lain/tools/subagent/refusing_handler.rb`;
create `lib/lain/middleware/gate.rb`, `middleware/sensitivity.rb`, `middleware/refuse_unpermitted.rb`,
and a home for the live Observer (`lib/lain/compaction/summary_observer.rb` as
`Compaction::SummaryObserver`, or the card's better name — it feeds `compaction/summary_snapshot.rb`);
modify `lib/lain/agent/tool_runner.rb:30-31,:390,:446-456`, `lib/lain/middleware/env.rb:16-22`,
`lib/lain/cli/switchboard.rb:213-219`, `lib/lain/tools/subagent.rb:1133-1141,:1180-1185,:1213-1219`
and its tail require, **the six `Live.new` sites**: `lib/lain/cli/wiring.rb:482-489`,
`lib/lain/agent.rb:399`, `lib/lain/consolidation.rb:95`, `lib/lain/cli/improve.rb:176`,
`lib/lain/tools/subagent.rb:1181,:1184`; `lib/lain/cli/backend.rb:348`,
`lib/lain/oracle/routed_summarizer.rb:51,:172`; specs:
`spec/lain/effect/handler_spec.rb`, move `spec/lain/effect/handler/gate_spec.rb` and
`sensitivity_spec.rb` to `spec/lain/middleware/`, delete `spec/lain/effect/handler/recorded_spec.rb`,
modify `spec/lain/cli/switchboard_spec.rb:380`, `spec/lain/tools/subagent_gate_spec.rb`,
`spec/lain/middleware_spec.rb`, `spec/lain/compaction/summary_snapshot_spec.rb:59`,
`spec/lain/cli/backend_spec.rb:1159`
**Reuse:** `Middleware::RefuseSecretWrites` (`refuse_secret_writes.rb:92-93`) is the precedent for a
middleware that short-circuits with a `Tool::Result` in env; `Middleware::Env` carries `effect`,
`context`, `result`; `Middleware::Stack#to_a` is the inspectable order
**Shared-file wiring:** `lib/lain/middleware.rb:163-171`: add `require_relative "middleware/gate"`,
`"middleware/sensitivity"`, `"middleware/refuse_unpermitted"` in alphabetical position
**Reachable from:** `ToolRunner#dispatch` (`agent/tool_runner.rb:446-456`) on every tool call.
**This card wires the moved layers into the production stack itself**: at `cli/wiring.rb:482-489`
the chat path's tool middleware becomes the guard stack with `Switchboard#gate`'s two layers
appended and `handler:` becomes the bare `Live`; `spawn_agent` (`subagent.rb:1133-1141`) does the
same with `ChildBuilder#gated`'s layers. T6 then moves that assembly into one builder. AC 1 and AC 2
drive the stack the switchboard path builds

**Verbs terminate; adverbs decorate.** `Live` and `Mock` interpret: one `call(env) -> Tool::Result`.
`Gate`, `Sensitivity` and `RefusingHandler` wrap, maybe short-circuit, else pass downstream — which is
a middleware, and the three secret middlewares already do the same job on the result side. They
move; the delegation triad, `to_app`, and both chain-walks go. **`Recorded` is deleted**: it reads a
journal record nothing writes, so it has never replayed anything; `Mock` is the deterministic double
`CLAUDE.md` names and stays. **The `Summarizing` decorator is deleted**; the Observer under its name
is the production mount (`backend.rb:348`) and moves to its own constant, five readers updated.

**Answering `gate.rb:18-20`.** `ToolRunner` already holds the toolset and refuses a foreign one
(`tool_runner.rb:193-200`). `#dispatch` resolves the tool **once** and puts it in the env as `tool:`;
`Middleware::Gate` judges `env[:tool]` and `Live` interprets `env[:tool]`, so authorization and
possession read one object by construction — stronger than a chain-walk. `Live` loses `toolset:`
at all six construction sites; `tool_runner.rb:390`'s `parallel_safe?` walk reads `@toolset`
directly. Three things the card states rather than discovers: (i) `Middleware::Env` is a functional
hash wrapper (`env.rb:33-49`) so `tool:` threads through the guard middlewares untouched, but
`env.rb:16-22` pins the per-phase key contract and names the spec that enumerates the keys — both
gain `:tool`; (ii) the `env → env.merge(result: interpreter.call(env))` adapter that `to_app` used to
be lives in `ToolRunner#dispatch`, nowhere else; (iii) under the `:handler_union` posture the runner's
`@toolset` is the **union** (`subagent.rb:1136,:1184`) while the model sees the rendered subset — the
gate judges against the union, as `Gate` does today, and `subagent_gate_spec.rb` proves it.

**Order is a security posture, not tidiness.** The four guard middlewares run **outermost** today and
the `Sensitivity → Gate → Live` chain is the terminal, so a secret write is refused before a human is
ever asked (`subagent.rb:1198-1201` states the rule). The moved layers append **after** the guards:
`[RefuseSecretWrites, RedactSecretReads, WithholdSecretPaths, GuardTestLayout, Sensitivity, Gate] → interpreter`.

**Acceptance criteria**

```gherkin
Scenario: a denied effect is refused before it is interpreted
  Given a stack built by the switchboard whose policy denies a tool
  When that tool's effect is dispatched
  Then it is refused
  And the interpreter did not run

Scenario: an allowed effect reaches the interpreter
  Given a stack built by the switchboard whose policy allows a tool
  When that tool's effect is dispatched
  Then the interpreter ran and its result came back

Scenario: the gate and the interpreter judge the same tool
  Given a toolset holding one tool and a gate that records what it judged
  When that tool's effect is dispatched
  Then the tool the gate judged is the very object the interpreter ran

Scenario: an effect naming no tool is refused by name
  Given a stack whose toolset lacks the named tool
  When the effect is dispatched
  Then it is refused, naming the tool

Scenario: a masked read still parks and masks
  Given the tool guard's real stack over a file matching a secret pattern
  When it is read
  Then the read is parked for a decision and the content reaching the model is masked

Scenario: the stack's order is inspectable and the guards still run first
  Given a stack built on the chat path
  When its members are listed
  Then the four guard middlewares precede sensitivity, sensitivity precedes the gate, and the interpreter is last

Scenario: a contract violation's message reaches the user unchanged
  Given a tool that violates its contract
  When its effect is dispatched
  Then the result is an error carrying the violation's own message
```
→ spec files: `spec/lain/cli/switchboard_spec.rb` (AC 1, AC 2, AC 6), `spec/lain/effect/handler_spec.rb`
(AC 3, AC 4, AC 7), `spec/lain/middleware/redact_secret_reads_spec.rb` (AC 5, existing — must stay
green, it is the secret boundary)

**Escalation triggers**
- **AC 3 is the card's gate**, `gate.rb:18-20` restated. If resolving the tool once in `#dispatch`
  cannot serve both gate and interpreter, stop; the chain-walk exists for a reason.
- `sensitivity_spec.rb:291-298` describes "when the policy's answer changes between handles? and
  perform" — the nil-branch at `sensitivity.rb:70-78` exists only because `handles?`/`perform`
  could straddle a board change. With one `call`, the straddle is unrepresentable; delete that
  describe rather than porting it, and say so.
- `handler_spec.rb:78,:101,:110` pin `Tool::ContractViolation`'s message reaching the user (the
  prose at `live.rb:69-84`; the `@toolset.fetch` it replaces is `live.rb:65`). AC 7 keeps that; if the layer that catches it moves, the message a user
  sees changes — stop.
- The Observer has five readers by name (Grounding). Rename once, in one commit, with every reader;
  a half-renamed namespace is worse than either name.
- `ARCHITECTURE.md:329-334`, `:337-338` (names Mock **and** Recorded as replay handlers), `:364-365`,
  `:671-672`, `:413` are falsified by this card — hand T8 the list; do not edit.
- **Do not edit `spec/lain/tools/subagent_spec.rb`** (T1 has it this wave); this card's subagent
  assertions go in `subagent_gate_spec.rb`.

### T6 — One builder for the tool stack, parent and child   [wave 3] [risk: high] ✅ landed `3ab0c175`

**Depends on:** T5
**Files:** modify `lib/lain/cli/tool_guard.rb:72-87`, `lib/lain/cli/switchboard.rb` (delete `#gate`
`:213-219` and `denial` `:235-243` if unreferenced), `lib/lain/tools/subagent.rb` (`Seam` `:755-756`
and defaults `:792`; delete `#gated`; `spawn_agent` `:1133-1141`; `GENERIC_DENIAL` `:407`),
`lib/lain/cli/wiring/toolset_build.rb:326-338`, `lib/lain/cli/wiring.rb:482-489` (re-edited
after T5), `lib/lain/cli/epic_submit.rb:556`; specs `spec/lain/cli/tool_guard_spec.rb`,
`spec/lain/cli/switchboard_spec.rb`, `spec/lain/tools/subagent_gate_spec.rb`
**Reuse:** `ToolGuard#layered` (`tool_guard.rb:82-87`) already assembles the four result-side
middlewares for both `#working` and `#child_stack`; after T5 the gate and sensitivity layers are
middlewares of the same kind, so the guard is the builder. `Seam#tool_middleware` already carries a
guard builder to the child (`subagent.rb:1138`)
**Shared-file wiring:** none
**Reachable from:** `cli/wiring.rb:532` (`ToolGuard.stack(chronicle, board)`) on the chat path and
`Tools::Subagent#call` → `spawn_agent` on the spawn path; AC 3 drives a real spawn through
`Switchboard` and compares the two stacks

`Switchboard#gate` and `ChildBuilder#gated` build the same `Sensitivity → Gate → inner` chain from
the same four ingredients, differing in `denial` (method versus thunk) and keyword order. After T5
both chains are middleware layers appended by hand at the two construction sites, and
`ToolGuard#layered` already builds the rest of the stack for both paths. So the gate and
sensitivity layers join `#layered`, the hand appends at `wiring.rb:482-489` and `spawn_agent` go, the `Seam` loses `gate_policy`,
`sensitivity` and `denial` (three of fourteen members — `tool_middleware` already carries the
builder), and there is one place an agent's tool stack is assembled.

**Acceptance criteria**

```gherkin
Scenario: a child is gated by the same policy as its parent
  Given a parent whose policy denies a tool
  When it spawns a child
  Then the child's stack denies that tool

Scenario: a child's denial names the child
  Given a parent and a spawned child
  When each refuses the same tool
  Then the child's refusal names the child

Scenario: parent and child stacks come from one builder
  Given a spawn on the real path
  When the parent's stack and the child's are listed
  Then both have the same layer order and both were built by the tool guard

Scenario: a seam with no stack builder is refused
  When a spawn seam is built without a tool middleware builder
  Then construction is refused
```
→ spec file: `spec/lain/tools/subagent_gate_spec.rb` (AC 1–4)

**Escalation triggers**
- `denial` is a thunk on the subagent side and a method on the switchboard side. If the builder
  cannot take one shape without a conditional, one of the two is wrong — find which before adding a
  branch.
- `wiring.rb:487` passes `snapshot_slot:`; `spawn_agent` does not. If unifying makes a subagent
  acquire a snapshot slot it never had, that is a behaviour change with a real cost — report, do
  not accept.
- `Bench::SpawnSeam` (`bench/spawn_seam.rb:119`) builds an `Agent` and calls itself "a DIFFERENT
  duck". `simplify-08` is editing that file. If this card's builder would become its third caller,
  stop and coordinate.
- `cli/epic_submit.rb:556` builds a `Seam` for the epic path with its own ingredients. If the epic
  path's gate differs from chat's on purpose, the "one builder" takes a policy argument; if by
  accident, say so — do not silently unify a security posture.

### T7 — Name the context pipeline: a resolver, a flag, a journal field, inheritance at spawn and on replay   [wave 2] [risk: medium] ✅ landed `87115b97`

**Depends on:** none
**Files:** create `lib/lain/cli/context_pipeline.rb`, `spec/lain/cli/context_pipeline_spec.rb`;
modify `lib/lain/context.rb:37-48,:75-112` (`pipeline_name`, carried by `#with` `:98`, `#with_model`
and `#with_pipeline` `:110-112`), `lib/lain/cli/backend.rb:235-236`, `lib/lain/session_record.rb:43-49`,
`lib/lain/session_record/scribe.rb:150`, `lib/lain/bench/session.rb:207` (the second header writer),
`lib/lain/role.rb:62-66`, `lib/lain/tool/spawn_policy.rb:196-200`, `lib/lain/bench/session/loader.rb:22`; specs
`spec/lain/session_record_spec.rb`, `spec/lain/tool/spawn_policy_spec.rb`, `spec/lain/role_spec.rb`,
`spec/lain/bench/session/loader_spec.rb`
**Reuse:** copy `lib/lain/cli/compaction_strategy.rb` closely — one authority constant (`:107`),
help derived from it, `+` composition (`:111`, `:169`), loud refusal on a typo (`:191,:222,:240`);
`exe/lain:818-836`'s no-default rationale; `Compare::Posture` (`compare/posture.rb:34,81,104-107`)
for name↔object coercion; `bench/plan_sweep/driver.rb:40`'s `BASE_PIPELINE` as the first
non-default catalog entry and the `->(workspace)` precedent
**Shared-file wiring:** `lib/lain/cli.rb`: `require_relative "cli/context_pipeline"` next to
`cli/compaction_strategy` at `:23`; `exe/lain`: a `method_option :context_pipeline` on `chat` beside
`:833-836`, **with no `default:`**, and a comment citing `:818-831`'s reason
**Reachable from:** `Backend#context` (`cli/backend.rb:235`) builds the `Context` every chat turn
renders through; AC 2 launches through `CLI::ChatLaunch` with the flag and AC 3 reads the header it
wrote

Three parts. **A name and a resolver:** `CLI::ContextPipeline` with `PIPELINES` as the authority —
`default` (`Reminder >> CacheBreakpoints`), `cache-breakpoints`, `prune`, `dedupe-tool-calls`,
`purge-failed-inputs`, `tail-injection` if it is a stage — composed with `+`; combinators that need
a collaborator (`Recall`, `Compact`, `Mailbox`, `PinnedMessages`) are not words and the card says so.
**Threading:** `Role#child_context` and `Tool::SpawnPolicy#child_context` pass the parent's
pipeline; `Bench::Session::Loader` re-resolves the recorded name instead of rendering the default.
**`Context::REQUIRES` goes**: `:75-79` already rules that every reader asks the effective pipeline.
**The record:** the `Context` carries `pipeline_name` (resolved at construction, propagated by every
copying constructor, so `Switchboard#graft`'s `with_model` cannot drop it), `SessionRecord::Scribe`
reads it off the context it already receives, and `SessionRecord.header` gains `context_pipeline`.
**Header only.** The per-turn compaction swap is a *composition* (`scheduler.rb:239`,
`prepared.rb:130`: `compact >> the base`), not a catalog word, and the scheduler already journals
the collapse strategy that names it (`scheduler.rb:194,:260`) — so the turn record is left alone.

**Acceptance criteria**

```gherkin
Scenario: no flag renders the default pipeline
  Given a chat launched without the flag
  When its context is built
  Then it renders the reminder and the cache breakpoints, byte-identical to before

Scenario: a named pipeline renders the request
  Given a chat launched with a pipeline named on the command line
  When a request is rendered
  Then that pipeline rendered it

Scenario: the session record names the pipeline
  Given a chat launched with a named pipeline
  When its session record header is read
  Then it names that pipeline

Scenario: a child inherits its parent's pipeline
  Given a parent whose pipeline is named
  When it spawns a child
  Then the child renders through the same pipeline

Scenario: a reloaded session renders under its recorded pipeline
  Given a session recorded under a named pipeline
  When it is reloaded for replay
  Then it renders under that pipeline, not the default

Scenario: an unknown name is refused, listing what exists
  Given a pipeline name that does not exist
  When a chat is launched
  Then it is refused and the refusal lists the pipelines that exist
  And the refusal has the same shape as the compaction strategy flag's

Scenario: a never-run combinator can be named and renders
  Given a pipeline naming the prune combinator
  When a request is rendered
  Then it renders without error
```
→ spec files: `spec/lain/cli/context_pipeline_spec.rb` (AC 1, AC 2, AC 6, AC 7),
`spec/lain/session_record_spec.rb` (AC 3), `spec/lain/tool/spawn_policy_spec.rb` and
`spec/lain/role_spec.rb` (AC 4), `spec/lain/bench/session/loader_spec.rb` (AC 5)

**Escalation triggers**
- **AC 7 is a discovery.** Five combinators have never run. If naming one raises, that is its first
  execution — report what broke, do not fix it inside this card.
- `Context#render` is pure and purity is the cache constraint. Resolve names at construction, never
  at render; a resolver that reads anything at render time fails `ARCHITECTURE.md:209`'s rule.
- `lain up` re-execs `chat`. If `cli/up.rb` does not forward unknown chat options, the flag is
  reachable from `lain chat` and not from `lain up` — say which, and do not widen `up` here.
- `Bench::Session` writes a second header of the same shape (`bench/session.rb:207`) and reads it
  at `:131-136`. Both writers gain the field (it is in Files); a header the loader cannot read back
  is worse than none. `simplify-08` is editing `bench/`; if it has touched `session.rb`, coordinate.
- Every `Context` copy must carry `pipeline_name`. `#with` at `:98` already carries `pipeline:`;
  if any `with_*` rebuilds through `Context.new` without it, the flag is silently dropped on the
  chat path at `switchboard.rb:200`'s graft — AC 3 through the real launch is what catches it.
- `MessageEnvelope` may be a wrapper rather than a stage. If it does not compose under `>>`, leave
  it out of the catalog and say so.
- `exe/lain`'s option must have **no default** (`:822`): a default makes the unset control arm
  unreachable, which is the mistake that comment exists to prevent.

### T8 — Rewrite the documentation the code now falsifies   [wave 4] [risk: low]

**Depends on:** T1, T2, T3, T4, T5, T6, T7
**Files:** modify `ARCHITECTURE.md` (`:141-208` the DAG and three meets; `:325-342` handlers and
middleware; `:364-365`; `:413`; `:416-424`; `:671-672`; `:917-1274` the algebra section whole, incl.
the mermaid at `:1006-1010` and the four-step checklist at `:1251-1264`; `:1035`), `docs/GLOSSARY.md`
(`:7-239` algebra and order theory, `:295-310` dominator, `:460-518` attenuation, `:589-622`
property-based testing), `ROADMAP.md` (`:109`, `:204-210`, `:363-372`, `:857`, `:880`, `:951-966`,
`:1173`, `:1204-1229`), `planning/qa/scenarios/` for `--context-pipeline` and any changed refusal
sentence from T5
**Reuse:** each card's report lists the sentences it falsified; `docs/rust-bindings.md` and
`ext/lain/CLAUDE.md` were edited by T4 and T2 and are not touched here
**Shared-file wiring:** none
**Reachable from:** every agent session reads these before editing; there is no runtime path, which
is why the card exists at all rather than being folded into each change

Write what replaced each thing, not that it is gone: laws live in the subject's spec, the render
order is `Dag::RenderAncestry`, dominance and causal ancestry are Rust, the tool chain is one stack
with two interpreters, the pipeline has a name. The "how to add a claim" checklist becomes "how to
hold an operation to a law": write the `include_examples` in its spec with a population.

**Acceptance criteria**

```gherkin
Scenario: no document describes the registry as present
  When ARCHITECTURE, the glossary and the roadmap are read
  Then none says a registry, a sweep or a seal exists

Scenario: the three meets are described where they live
  When the DAG section is read
  Then the render order is named as a Ruby module and the other two as Rust types
  And the checkpoint primitive is named as unwired

Scenario: the handler section matches the code
  When the effects section is read
  Then it names two interpreters, the middleware stack, and no deterministic-replay handler that reads a record nobody writes

Scenario: the QA scenarios enumerate the new flag
  When the QA scenario index is read
  Then a scenario launches a chat with a named context pipeline and reads its header back
```
→ spec file: none — prose, verified by reading; these **must not become specs** (simplify-10's T12
removes exactly that class)

**Escalation triggers**
- `simplify-08` edits `ARCHITECTURE.md`. Rebase this card's line ranges on the day it runs; the
  numbers above are 2026-09-14's.
- If a sentence a card falsified is not in that card's report, grep for the class name rather than
  trusting the list above; `Effect::Handler::Recorded` and `Algebra::` are the two to sweep for.
- `docs/GLOSSARY.md`'s algebra entries are teaching prose, not code description. Trim what the code
  no longer motivates; do not delete a definition a remaining law group still uses.

### T9 — Amend the two downstream plans this one changes   [wave 4] [risk: low]

**Depends on:** T1, T2, T3, T4, T5, T6, T7
**Files:** modify `planning/specs/simplify-13-rust-port.md`, `planning/specs/simplify-12-ask.md`,
`planning/specs/simplify-09-operations-as-objects.md` (one superseded-by line under its status),
`planning/README.md:65`
**Reuse:** the review in the section **Downstream plan amendments** below is the content; this card
applies it as dated notes in each plan's own voice
**Shared-file wiring:** none
**Reachable from:** the next `/execute-plan` of either plan reads its own doc first; there is no
runtime path

**Acceptance criteria**

```gherkin
Scenario: the Rust port plan no longer waits on a dropped card
  When simplify-13's prerequisites and T10 are read
  Then neither names simplify-09's T4 and both name Dag::RenderAncestry as the seam

Scenario: the Rust port plan knows its trait already exists
  When simplify-13's T2 and T3 are read
  Then T2 is scoped to replacing hand populations with generated strategies
  And T3's first rule edit is marked done by reference

Scenario: the ask plan names the gate where it now lives
  When simplify-12's grounding is read
  Then mechanism one names Middleware::Gate and its T5 cites this plan's stack as landed

Scenario: the old plan points here
  When the superseded plan is opened
  Then its first lines name this plan
```
→ spec file: none — prose

**Escalation triggers**
- If `simplify-13` or `simplify-12` has been edited since 2026-09-14, apply the amendment to the
  current text; do not paste this plan's paragraphs over a newer ruling.
- `simplify-14` is declined and nothing here touches the review surface; **make no edit to it**. If
  a reader would look for one, the absence is recorded in this plan instead.

## Downstream plan amendments

Reviewed 2026-09-14 against the three plans that have not run. T9 applies these.

**`simplify-13-rust-port.md`.**
- Orchestrator contract `:222-225`: drop "simplify-09's T4 should have landed"; the seam for the
  *meets* is the name `Dag::RenderAncestry` (T1 here), repointed to `Ext::Dag::RenderAncestry` at the
  flip. The seam for *construction* (21 `Timeline.new`, ~20 `Store.new`) is still 13's T10
  `Dag::Factory`; its `:906-910` Reuse paragraph is rewritten accordingly and `lib/lain/dag.rb`
  exists after T1 here.
- **T2 is largely done by T2 here**: the sealed supertrait, the ZSTs, the macro and the four law
  bodies exist, over hand-built populations. 13's T1 (proptest strategies, `DagPlan`) stands as an
  upgrade; 13's T2 shrinks to "point the macro's `population:` at the generated strategy and delete
  the hand populations". Its compile-fail ACs are checked the way T2 here checks them unless 13
  chooses to add `trybuild`.
- **T3's three rule edits**: rule one (`ext/lain/CLAUDE.md:138-142`) is *satisfied* by the generic
  FFI, not reversed — T2 here already edited `:129-136`; rule two (`:119`, Ruby not deleted) still
  inverts under 13; rule three (`docs/rust-bindings.md` rule 5) was already narrowed by T4 here to
  "where both implementations exist" and 13 narrows it further to the corpus.
- **T4's refutation macro is unnecessary**: `CausalAncestry` is refuted by type (it does not
  implement `MeetSemilattice`) and its witness test exists. The eight order laws remain net-new and
  stand.
- **G7 is closed** (no Ruby declaration exists to mirror). **G8 shrinks** to the construction seam.
- **T8's corpus must carry dominance and causal vectors.** After T4 here, Ruby is no longer their
  oracle; until 13's T8 lands they are held only by `cargo test` and by the hand fixtures in
  `spec/lain/rust/{dominator_meet,causal_meets}_spec.rb`. T11's trigger about those two specs
  "naming Ruby as their oracle" is already moot.
- **T13's deletion list** gains `lib/lain/dag/render_ancestry.rb` (repointed, not deleted, if the
  Ruby-facing name is kept as a constant alias to `Ext::Dag::RenderAncestry`) and loses
  `timeline.rb`'s dominance and causal classes (already gone).

**`simplify-12-ask.md`.**
- Grounding "the nine": mechanism (1) is `Middleware::Gate` + `Approval::Queue` after T5 here, and
  the two chains it cites at `cli/switchboard.rb:216` and `tools/subagent.rb:1445` are one builder
  in `CLI::ToolGuard` after T6. 12's T5 ("the escalation ladder as a middleware stack") gets its
  premise for free: the tool stack is already one ordered `Middleware::Stack` with the gate in it.
- The panel's objection stands and is answerable: reframe as **two** primitives, `Gate`
  (authorization: verdict, fail-closed, on the secret boundary) and `Ask` (enquiry: free text, a
  stalled turn). T1 and T2 of 12 are unaffected except that any prose naming
  `Effect::Handler::Gate` names `Middleware::Gate`.
- Re-ground before running: 12's grounding commit is `d2bb133c`, which is not an ancestor of HEAD.
- Record the human's 2026-09-14 direction (see Execution log): asking the end user and
  agent-to-agent communication are to be modelled as `Context::Mailbox` messages (events), and
  `Mailbox` is today only ever `Mailbox::Null`. 12's register is the natural place to decide
  whether its entries are mailbox messages.

**`simplify-14-nvim-descope.md`.** Declined; nothing in this plan touches the review surface, the
nvim runtime, or the rails table. `--context-pipeline` is a `chat` option and is invisible to the
editor. No amendment.

## Integration checks

After the last wave:

- `bundle exec rake pspec` green, **with the example count recorded** and the arithmetic written:
  T1, T3, T4 and T5 all move or delete examples. Confirm
  `pgrep -cf 'mise/installs/ruby/[0-9.]*/bin/parallel_rspec'` reads 0 before trusting a red run.
- `cargo test -p lain`, `cargo clippy --all-targets -- -D warnings`, `cargo doc --no-deps`,
  `cargo fmt -- --check`, `cargo deny check` all clean; the test count recorded against `main`'s 227.
- `bundle exec rubocop` clean with no new `rubocop:disable`; `bin/spec-census --check` output
  recorded before and after (it is red before; `lib_reach` must be lower after, `assertions` no
  higher).
- `grep -rn 'Algebra' lib/ exe/` returns nothing; `grep -rn 'Effect::Handler::Recorded\|handles?\|to_app' lib/`
  returns nothing.
- Focused algebra run: `bundle exec rspec spec/lain/dag spec/lain/rust spec/lain/usage_spec.rb spec/lain/toolset_spec.rb spec/lain/interval_partition_spec.rb spec/lain/compaction/strategy_spec.rb spec/lain/context`.
- Focused chain run: `bundle exec rspec spec/lain/effect spec/lain/middleware spec/lain/cli/tool_guard_spec.rb spec/lain/cli/switchboard_spec.rb spec/lain/tools/subagent_gate_spec.rb`.
- **Read one session record header** written by `lain chat --context-pipeline prune`; the field is
  present and names `prune`. Then one turn record after a compaction in a session with the default
  pipeline; the swapped name is present or the fallback is recorded as decided.
- **Manual, human:** one `lain chat` with a tool denied by policy, confirming the refusal arrives
  before any interpreter ran and the message is the one the QA scenario names; one `/mode plan` flip
  confirming the posture still attenuates. The tool stack is the security boundary and its specs use
  doubles at several layers.
- **Manual, human:** one spawn from a chat launched with a named pipeline, confirming the child's
  first request rendered through it (its session record says so).
- Update `planning/qa/scenarios/` (T8) and confirm `planning/README.md:65` points at this plan (T9).

## Execution log

- **2026-09-14, start.** Lands on `main` @ `9368e249` (the grounding commit, so no staleness).
  `origin/main` is `b1927ce7`, 340 behind — never a base. Baselines on that head: `rake pspec`
  17,945 examples / 0 failures / 13 pending; `cargo test -p lain` 227; `bin/spec-census --check`
  red at `assertions: 185 > 184`, `lib_reach: 76`. Worktrees cut from `HEAD` under `tmp/worktrees/`.
- **Collisions the card lists do not name**: T5 and T7 both edit `lib/lain/cli/backend.rb`
  (`:348` and `:235`); T3 and T5 both edit `spec/lain/middleware_spec.rb`. T3 and T7 wait on T5
  for those files as well as on their stated dependencies.
- **T1 escalation, resolved by the orchestrator.** `lib_reach` rose 76 → 79: the deleted
  declarations were the only `lib/` mentions of `not_a_meet_semilattice`, `causal_meets` and
  `dominator_meet`, which T3 and T4 delete. Making `diverge_at` private reaches only 78, so it was
  not done. Accepted as transient; T3 and T4 together must land it below 76. Also found:
  `Timeline#ancestor_of?` has no `lib/` caller at HEAD either (the card's "Reachable from" overstated
  it); the sweep had six Timeline generator entries, not five.
- **For T9 (simplify-13 amendment), from the Rust review.** `Ext::Timeline#diverge_at`
  (`lib.rs`) still calls `dag::meet` directly rather than through the trait, and
  `Ext::Dag::RenderAncestry` is a class with no `diverge_at`, while the Ruby `Dag::RenderAncestry` is
  a module that has one. The store flip's repoint to `Ext::Dag::RenderAncestry` needs both.
- **T2 landed** as `98085764` (`cargo test` 231). Review caught a law suite that could not see a
  not-greatest meet or an order relating everything; one generic `below ⇔ meet == a` test now does.
  First commit attempt died on `grep::probe_hazards::probe_regular_file_swapped_for_a_fifo_between_stat_and_open`
  in `crates/lain-core` under load from concurrent agents (untouched by this card; 5/5 green alone).
  Its own comment says the stat/open window is real and a hit parks a thread — a genuine race,
  surfaced as a load-sensitive flake, not recorded in `docs/toolchain-traps.md`. Reported, not fixed.
- **T1 landed** as `62aa555d`. `rake pspec` with T1 on T2: 17,934 examples (T2's 17,967 − 33 moved
  or deleted), one red in `spec/lain/cli/up_spec.rb`'s real-tmux nvim-cockpit example while another
  worktree's suite ran; 128/128 alone. Review caught that the four shared laws never check
  *greatest*; a local greatest-lower-bound law in the render-order spec now does.
- **Collision ruling revised at T1's landing.** T3 (with T5 on `spec/lain/middleware_spec.rb`) and
  T7 (with T5 on `lib/lain/cli/backend.rb`) start now rather than wait: the shared hunks are disjoint
  (Composable/Composed examples vs. T5's handler examples; `:235` vs `:348`), landing is serialized
  through `git apply --3way`, and whichever lands second reruns its specs on the merged tree.
- **T5 handed back** with 92 files against a card of ~30: the extra `lib/` edits are YARD links to
  the moved classes, plus `Toolset::Unheld` / `Tool#held?` (so an unheld name is refused by name
  rather than put to a human) and a root-qualified `::Lain::Sensitivity` in two secret middlewares.
  `spec/lain/tools/subagent_spec.rb` needed 14 examples ported (they named `Handler::Gate`
  constants); applied as a deliberate scope expansion once T1 had landed. The orchestrator
  rebased the worktree onto `62aa555d` before review. New overlaps with T3 (in flight):
  `lib/lain/toolset.rb` (tail require vs `:22,:115`), `spec/lain/toolset_spec.rb`,
  `spec/lain/tools/parallel_commutation_spec.rb`. The integration grep `to_app` matches
  `auto_approve`; the check needs `\bto_app\b`. `exe/lain:39`'s comment names
  `Effect::Handler::Gate` and is fixed at landing.
- **T5 review: REQUEST-CHANGES.** The panel's parity probe (real switchboard, guard stack, policy
  and queue, run on both trees) found the one thing the second tool lookup had been for: resolving
  the tool once, before the gate parks on a human, let a `/mode plan` flip during the wait end in
  the call running; HEAD refused it. 15 of 16 scenarios were otherwise byte-identical. For T8's
  list, beyond the three docs: `docs/concurrency.md:227-256`, `docs/toolchain-traps.md:172-173`
  (T5 edits both).
- **Out of scope, found by the T5 panel, reported to the human:** on HEAD and after T5 alike,
  `write_file` to `~/.ssh/authorized_keys` is neither denied nor gated by the sensitivity table.
- **Follow-ups recorded from the T7 panel (not this plan's):** `--resume`/`--fork` do not inherit
  the recorded pipeline (resume inherits no launch flag today); `Context::Prune` can keep a
  `tool_result` whose `tool_use` it cut, which the Anthropic API likely rejects;
  `lain chat --compact-strategy typo` leaves a 19 KB session file behind.
- **T5 landed** as `75b26bc8`; `rake pspec` on the merged tree 17,936 / 0 failures (62aa555d's
  17,934 − 4 from `subagent_spec.rb`'s port + 6 from the fix rounds). Two fix rounds: the mode-flip
  regression (re-lookup at the interpreter end, identity-checked), then a stand-in for an unheld
  name swapped in after the gate. lib +589/−727, spec +1,550/−1,456. T6 cut from `75b26bc8`.
- **T3 review: REQUEST-CHANGES.** Two law runs the sweep had went nowhere: `IntervalPartition#meet`'s
  exhaustive check over its hardest partitions (a meet wrong on one ordered pair went red on 1 of 20
  seeds, always at HEAD), and the battery in Summarizing's elementwise refutation. The deletion is
  otherwise −160 examples, every one itemised. Worktree re-based onto `75b26bc8` by 3-way apply;
  one conflict, `lib/lain/toolset.rb`, handed to the implementer.
- **T4 landed** as `047c55d6` (17,915 on the merged tree). The orchestrator corrected `.rubocop.yml`'s
  tree counts (26 reopening files; 50 Metrics comments across 45 files — stale since `5a5b75e0`, not
  only by this card), `ext/lain/Cargo.toml`'s comment naming `Timeline::Tree`, and `CLAUDE.md`'s
  exemplar figures to `timeline.rb`'s measured 0.79 prose:code, longest block 16. The commit hook
  failed three times on load-induced flakes while review agents ran mutants (`HeadlessEditor`
  ignores-TERM, the nvim two-approval end-to-end, the lain-core fifo probe again); green at 8 workers.
- **T7 landed** as `87115b97` (17,954). Review follow-ups beyond the card, applied: a variance guard
  refusing recordings rendered by different stages, and refusal of a repeated stage.
- **T3 landed** as `7a1d4602` (17,798). Review caught two law runs that had moved nowhere
  (partition meet's exhaustive read, Summarizing's battery). `bin/spec-census --check` is **green**
  for the first time in this plan: assertions 184, `lib_reach` 68 against a ceiling of 76 (the
  census suggests lowering it; no card raises or lowers a ceiling).
- **Ledger after T1–T5, T7** (`9b2ac4e7..7a1d4602`): lib +1,024/−2,216 (−1,192), spec +3,323/−5,006
  (−1,683), ext +583/−337 (+246); 12 lib files deleted, 8 added.
- **Human direction, 2026-09-14, recorded mid-run (no card in this plan changes).** Asked whether the
  catalog combinators should join the default chat pipeline the way the tool guard stack always
  runs: no — `--context-pipeline` stays as it landed, as an override whose unset arm is the default.
  The preferred direction is a Ruby config file, `./config/lain/config.rb`, in which a user defines
  custom middleware and adds it to the chain for each area middleware runs in (provider HTTP calls,
  tool calls, compaction flows) — a follow-up plan, not this one. `Recall` and `Mailbox` are also
  unreachable from `lain chat` (only `bench/sweep.rb` builds a `Recall`; only `Mailbox::Null` is
  ever constructed); left alone here. `Mailbox` *should* become live: asking the end user a
  question and agent-to-agent communication are both to be modelled as mailboxes and sent messages
  (events) — a follow-up after this plan, and relevant to `simplify-12-ask.md` (T9 notes it there).
- **T6 review: APPROVE-WITH-FIXES.** 17/17 parity scenarios byte-identical to `7a1d4602` on the
  implementer's probe, 28 adversarial scenarios (nested spawn, handler_union, epic's approve-all,
  bench/improve/consolidation no-op layers, `snapshot_slot`) likewise. Accepted behaviour change: a
  child's refused-path record reaches the session journal; before, it was pushed onto the terminal
  channel, whose decorator returned nil for it, so it was dropped. Caught: the one builder no longer
  guaranteed a child's stack ends in the gate (an empty builder yields an ungated child). T6 edits
  `spec/lain/tools/subagent_spec.rb` (simplify-10 overlap; no simplify-10 work is in flight).
- **Out of scope, the same on `7a1d4602` before T6, reported to the human:** a child's toolset is fixed at
  spawn, so a `/mode plan` flip while a child's bash call is parked, then approved, still runs it —
  the mode-flip refusal restored in the handler split covers the parent only.
- **T6 landed** as `3ab0c175` (17,820). Fix round added `Middleware::Gate.closes!`: every stack
  `ToolGuard` builds, and whatever a seam's builder hands a child, must end Sensitivity → Gate or is
  refused before a tool runs. T8 and T9 start from `3ab0c175` plus this log.
