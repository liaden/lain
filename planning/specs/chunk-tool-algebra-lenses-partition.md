# Tool-use algebra: laws, block lenses, and the shared interval partition

status: **in-progress** (2026-08-02; panel-reviewed 2026-07-29: REQUEST-CHANGES → both blockers
and all should-fixes applied — T2's driver corrected to back-to-back single-use responses, T10's
collapse dispatch designed via hook widening + owner-tagged ranges; chunk B landed at `3e8502e`)

## Staleness check, 2026-08-02 (main at `e31f9a5`)

**Spec re-baseline (the count this plan deliberately left blank): 7883 examples, 0 failures,
2 pending** — `bundle exec rspec` on `e31f9a5`, exit 0. Integration check 1's "strictly above"
is measured against 7883.

Chunk B landed at `3e8502e`, but main has advanced past it through the epic-wiring chunk.
Re-verified every wave-1 anchor. **Held exactly:** `toolset.rb` freeze-at-construction `:34`,
`#only` `:75`, `#except` `:86`, `to_schema` `:99`; `strategy/base.rb` `Partition` `:164`,
`private_constant` `:265`, `method_added` `:271`, the seven refusals `:186-250`, the builder
`:133`; `derivation.rb` `Plan#writes` `:318`; `source/derived.rb` `PinCuts#runs` `:274-276`;
`response.rb` `#tool_uses` `:70`; `middleware.rb` `class Base` `:50` / `Identity = Base.new`
`:75`; `context/base.rb:78` declaration shape; `algebra.rb` `STRUCTURES` `:48`, requires
`:264-268`, `@entries` `:144`, `@registry ||=` `:258`; `algebra_laws_spec.rb` `GROUPS` `:116`,
`BATTERIES` `:124`, `EVIDENCE` `:135`, `POPULATIONS` `:141`; `algebra_generators.rb`
`strategy_claims` `:34`, `observationally_equal` `:76`.

**Absorbed drift (no card invalidated):**

- `agent/tool_runner.rb` line numbers moved: `#run` `:83` (was ~`:76`), `#observe` `:164`,
  `#contiguous_runs` `:198`, `#gather` `:219`, `#result_block` `:237`, `DuplicateToolUse` raise
  `:160`. T4/T8/T9 re-anchor by method name, not line.
- **`Spawn::Seam` was never built** — chunk B's T23 left only a design comment at
  `subagent.rb:381`. T3's escalation trigger about it is moot; `build_subagent`
  (`subagent_spec.rb:26`) and `loop_driven` (`:41`) are unchanged.
- **`spec/support/shared_examples/` holds 12 groups, not seven** (integration check 4's count is
  stale; its *invariant* — byte-unchanged, only `attenuation.rb` added — stands).
- **`include_examples "a monoid"` appears at 8 sites, 4 of them Middleware's**
  (`middleware_spec.rb`, `repl_middleware_spec.rb`, `agent_turn_middleware_spec.rb`,
  `middleware/skill_dispatch_spec.rb`) — not five. T6's AC already anticipated the re-count.
  `spec/lain/middleware/env_spec.rb` still exists (chunk B's T36 did not delete it).
commit-mode: orchestrator-commits
language: ruby
panel: Torvalds, Evans, Metz, Schneeman, Patterson (one review agent embodies all)

## Intent

Execute the tool/tool-use half of `planning/tool-use-algebra.md` (2026-07-29): prove the laws
the tool layer already relies on (the exchange law behind `parallel_safe?`, posture
equivalence, Toolset attenuation), replace the raw block-hash hotspots with the house lens
pattern, extract the interval partition as one public value and build the refinement meet
that proves it, and close the algebra registry's own recorded follow-ups (0, 0b, 11 of
`chunk-algebra-vocabulary.md`). Four streams, one chunk, because they share the registry
machinery and the same review posture: laws are guards, lenses are views, and neither may
move a digest.

## Sequencing constraint (hard)

**This chunk starts only after `planning/specs/chunk-review-missing-objects.md` (chunk B)
fully lands** — both waves, per Joel's ruling 2026-07-29. Chunk B touches `agent.rb`
(T21/T22: `Agent.new` gains collaborator injection including `tool_runner:`),
`subagent.rb`/`toolset_build.rb` (T23: `Spawn::Seam`; T40: the `(catalog:, slots:)`
extraction, same file), and compaction/context files (T32). Every line number in this plan was verified at `30e82b4` (pre-chunk-B), so the
execute-plan staleness check is **not optional**: re-verify each card's anchors against
post-chunk-B main before it starts, and re-baseline the spec count before wave 1 (no count
is recorded here on purpose — one cannot be measured yet).

## Grounding

Verified 2026-07-29 against `30e82b4` by four exploration passes plus one executed spike
(a Hash-subclass wire block driven through Canonical/JSON/freeze/Ractor/Event; the script
was scratch and is deleted — its results are recorded in full below). Code won over docs in
one place: `docs/GLOSSARY.md` says the partition has five refusals; `strategy/base.rb`
implements **seven** (answerless and uncountable are the extras, each born of a real
caller-side failure).

**The spike, and the block-strategy ruling.** A `Hash` subclass passes everything at
construction (content-`==` both directions, `Canonical.dump`/`digest` byte-identical, JSON
identical, frozen + `Ractor.shareable?`, `case/when Hash`), but `Canonical.normalize`
rebuilds plain hashes (`canonical.rb:75,95`) so the subclass is erased at the first commit,
and `normalize` **raises** `UnsupportedType` on any non-Hash value, so a `Data` block cannot
enter the store at all. The store layer is closed in both directions. Joel's ruling
(2026-07-29, after seeing this): **the lens pattern** — the house's own, already built twice:

- `Middleware::Env` (`middleware/env.rb:31-51`): frozen plain class over `@hash`, idempotent
  `.wrap`, `#fetch`/`#[]`/`#merge`/`#to_h`, typed readers over `fetch`, wrapped exactly once
  at the `Stack#call` boundary (`middleware.rb:135`). Spec: `spec/lain/middleware/env_spec.rb`.
- `Context::MessageEnvelope` (`context/message_envelope.rb:16-52`): same idiom over one
  canonical message hash, `#to_h` returning the **original object by identity** so the digest
  cannot drift. Its header states the governing rule: the string-keyed shape *is* the
  pipeline primitive; this is only a lens onto it.

**Result flow.** `Tool::Result` is already a value (`tool.rb:221-251`) with ~10 consumption
sites; the flattening hotspot is `tool_runner.rb:230-241` (the only Result→wire conversion).
Six raise→error-Result conversion sites (`handler/live.rb:74,78`, `gate.rb:70`, `mock.rb:47`,
`recorded.rb:44`, `refusing_handler.rb:43`, `refuse_secret_writes.rb:170`). `Response#tool_uses`
blocks are always string-keyed post-`Canonical.normalize` (`response.rb:53,61-63,70-72`).
Non-provider block-hash surface ≈30 sites: `tool_runner.rb` (11), `grader/tool_call_index.rb`
(6), `context/conversation.rb` (6), `context/dedupe_tool_calls.rb` (5),
`context/purge_failed_inputs.rb` (5), `compaction/summary_snapshot.rb` (5),
`event/projection.rb:155-157`, `plan/closure.rb:130`, others small. The provider layer
(~24 sites) stays raw: it is the wire, and `http/providers/anthropic/tools.rb:39,55,70` is
the only legitimate symbol-key producer (outbound). `status_feed.rb:334`, `journal.rb:142`,
`epic/progress.rb:135` read journal-record `type`, not blocks — not part of any migration.

**Toolset.** No `==`/`eql?`/`hash` (Object identity). Equivalence today is mediated:
`Canonical.dump(to_schema)` (`toolset_spec.rb:79` + 4 sites) or `.names`. Identity-based
specs (`be(allowed)`, `be(union)` in `spawn_policy_spec.rb:239,256`; `equal(toolset_before)`
in `wiring_spec.rb:109`) pin that postures return the same object — value `==` must not
disturb them (`be`/`equal` use `equal?`, unaffected). Attenuation laws are NOT pinned today:
no idempotence, no composition, no duality, no identity cases; monotonicity partially
(`toolset_spec.rb:58`). The only posture-bearing seam is `Tools::Subagent`
(`subagent.rb:381-382,418,441-446`; union built by `#child_union` `:394-398`); bench seams
do not attenuate. The refuser is `Subagent::RefusingHandler`
(`subagent/refusing_handler.rb:24-44`, journals `"refused"`, answers `is_error`). The
posture-equivalence test pattern already exists: `subagent_spec.rb:161-180` scripts calls
under a posture via `Provider::Mock` (`mock_recording.rb:28,34` builders). **Design fact:**
the two postures deliberately diverge on disallowed calls (schema → the name is absent from
the rendered schema; handler_union → RefusingHandler refusal); equivalence holds over
allowed calls only.

**Exchange law.** No test anywhere runs two tools in both orders
(grep: `commut|order-independent|interleav` — zero). `parallel_safety_spec.rb` pins
membership (frozen TRUE_TOOLS/FALSE_TOOLS vs `ToolRegistry.shipped_names`) and the runner's
schedule; `:106-107` pins result *ordering*, the opposite claim. Instances come from
`ToolRegistry.build` (`spec/support/tool_registry.rb`). The natural commutation subjects are
the 7 FS-read tools (`read_file list_files glob grep ast_search code_outline file_symbols`)
plus 3 pure (`ast_dump test_pattern memory_read`); `subagent` is excluded (spawns);
`read_file` is the one member that mutates observable state (the Session read-set), so its
law must compare Session state too.

**Partition.** `Partition = Data.define(:strategy, :span, :ranges)` at
`compaction/strategy/base.rb:164`, `private_constant` `:265`, built only in `Base#ranges`
(`:132-134`), `#ranges`/`#collapse` sealed via `method_added` (`:271-278`). Seven refusals
(`:183-252`), order deliberate (`:156-163`), all `NotAPartition`. The fold is
`derivation.rb` `Plan#writes` (`:318-323`), exclusive-end aware (`:334`). Specs:
`strategy_spec.rb:202-237` (five), `derivation_spec.rb:488-512` (the other two),
`derivation_audit_spec.rb:385-395`, `source_spec.rb:869-905` (pins as cut points). Same
shape built independently: `Source::Derived::PinCuts#runs` (`source/derived.rb:273-278`,
chunk_while into ranges; deliberately double-validated `:261-264`),
`ToolRunner#contiguous_runs` (`tool_runner.rb:191-193`, no direct spec),
`Plan::Document#chunks` (`plan/document.rb:81-85`). The combination is designed-not-built:
`chunk-derived-context-timeline.md:1704` follow-up 3 — common refinement over the cut-point
lattice, "disjoint range-sets as a partial commutative monoid with Identity as unit",
motivating case "elide on tool spans, summarize on conversational ones".

**Registry.** Adding a structure = 9 steps: `STRUCTURES` (`algebra.rb:48`), a concern shaped
like `monoid.rb:28-40`, the require (`algebra.rb:264-268`), `GROUPS`
(`algebra_laws_spec.rb:116-122`), `BATTERIES` (`:124`, iff refutable), `EVIDENCE`
(`:135-136`), `POPULATIONS` (`:141`), a shared group in `spec/support/shared_examples/`, a
generator per (class, operation) in `algebra_generators.rb:19-27`. monoid/commutative_monoid
have **no battery** — refuting either fails the sweep's coverage example today. Generators:
one entry serves every claim on an operation; identity/operation/analysis come from the
registry, never the generator; vacuous-pass trap at `algebra_generators.rb:48-53` (draw
observable subclasses, not bare bases); the file is at `Metrics/MethodLength`'s limit
(`:30-33`) — the `strategy_claims` idiom (`:34-39`) is the overflow. Middleware's monoid is
proven at five identical `include_examples` sites with zero declaration in `lib/`
(follow-up 0); subject for the declaration is `Base` (`Identity = Base.new`,
`middleware.rb:75`); observational equality precedent `Combinators.observationally_equal`
(`algebra_generators.rb:76-79`). Follow-ups 0b/11 both open: verbs are public class methods
on every includer; `Registry` has no seal, `@entries` mutable, `@registry ||=` non-atomic.

## Execution log (orchestrator, 2026-08-02)

### Wave 1 — LANDED, 6/6. Suite 8052 / 0 failures / 2 pending (from 7883).

| Card | Verdict | Commit |
|---|---|---|
| T3 posture equivalence | APPROVE | `86b5eeb` |
| T6 Middleware monoid | APPROVE-WITH-FIXES (deferred to A-1) | `48d8712` |
| T4 ToolUse lens | APPROVE-WITH-FIXES (7 mechanical) | `8667a5b` |
| — lens `to_json` cleanup (orchestrator-owned) | — | `c864171` |
| T2 exchange law | APPROVE-WITH-FIXES → re-reviewed APPROVE | `5727706` |
| T5 IntervalPartition | REQUEST-CHANGES ×2 → APPROVE | `32ab223` |
| T1 Toolset equality | REQUEST-CHANGES → APPROVE | `61acbae` |

**Every card that received a deep review had a real defect found.** Four were serious enough
to have shipped behind a green suite:

1. **T1 had a failing spec.** `spec/lain/cli/wiring/toolset_build_spec.rb` hands `lib/` an
   `instance_double(Lain::Tool)` stubbing only `name`; the eager digest made `Toolset.new`
   call `#to_schema` on it. The implementer's 69-file sweep grepped for specs building a
   Toolset *inline* and structurally could not see one built by `lib/` from a spec-supplied
   member. **Lesson, now in every brief: when a change widens a construction contract, only a
   full-suite run enumerates the blast radius.**
2. **T5's refusal messages named ranges the author never wrote** — normalization ran before
   validation, so `[0...3, 1...4]` was reported as "0..2 and 1..3", and every production
   out-of-span refusal printed a respelled span (`derivation.rb:283` always asks
   `0...boundary.index`). The code carried a comment arguing this could not happen; the
   argument only covered malformed shapes.
3. **T2's read-set comparisons held vacuously.** Killing read observation outright
   (`Session#read?` → always false) left all 92 examples green: 36 of 45 compared `[] == []`.
4. **T6's law sweep passes under a left-absorbing operator** — see A-1.

**Process notes that changed how later waves are briefed:** run the full suite before
reporting green; a fresh worktree needs `bundle exec rake compile`; review agents must be
pointed at the implementer's worktree; and "I could not find a seam" is not "no seam exists"
— T5 reported the second while the first was true, and its panel produced the seam
(`const_get` bypasses `private_constant`, and `.covering` refuses from `PinCuts` given an
unbounded span).

### Waves 2–4 — LANDED. Chunk complete, 12/12.

| Card | Verdict | Commit |
|---|---|---|
| T7 attenuation algebra | REQUEST-CHANGES → APPROVE | `43b9d6c` |
| T8 ResultBlock lens | APPROVE-WITH-FIXES | `73cf692` |
| T9 lens adoption | APPROVE-WITH-FIXES | `b65ee1e` |
| T11 registry seal | APPROVE-WITH-FIXES | `71fbf1b` |
| T10 refinement meet | REQUEST-CHANGES → APPROVE | `8c622b2` |
| T12 vocabulary | — | (this commit's sibling) |

**The three findings worth remembering, all the same shape — a guarantee asserted in prose
that nothing enforced:**

1. **T7's monotonicity law certified a capability escape.** Stated against the *receiver*, it
   could only fail if attenuation invented a tool, so a `Toolset` honest in `names`, `each`,
   `to_schema`, `digest` and `==` — and lying in `#include?` and `#fetch`, the two messages
   `Effect::Handler::Live` authorizes with — passed **every law** while dispatching a dropped
   `bash` through the real handler. Fixed by stating it against the **request**: "a capability
   the attenuation dropped", not "one the receiver lacked". The escape is now a spec against
   the live handler. Both halves of the fix were necessary and neither sufficient.
2. **T10's `Composed` was unusable on the only production path.** `Source::Derived` wraps every
   operator-supplied strategy in `PinCuts`, which forwarded `#blocks` but not the new
   `#blocks_for` — invisible because the card's own end-to-end spec bypassed `Source`.
3. **T11's seal had to latch the verbs, not the registry**, because `Elementwise` generates its
   method *before* filing its claim: a registry-only latch refuses the declaration, files
   nothing, and leaves a **working** generated method on the class.

**Card text corrected at execution** (the code is right, the plan was wrong): T10's `#meet` AC
(intersection, not cut-point union — see the card) and T10's hook widening (`blocks_for`, since
`Elide#blocks` is generated with strict arity 1).

**Suite: 8052 → 8517.** Integration check 1's "strictly above the 7883 re-baseline" holds.

**Scope expansions, ruled by the orchestrator rather than escalated to Joel:**

- **T1 → `spec/lain/agent/tool_runner_spec.rb`.** The card's mandated eager digest makes
  `Toolset#initialize` call `#to_schema` on every member, where before it needed only `#name`.
  Four `Struct.new(:name)` fakes in that file had no `#to_schema` and broke. This is *not* the
  card's first escalation trigger (nothing relied on `==` being identity — those are fixture
  gaps), and the correction is precedented in-repo: `spec/lain/agent_spec.rb:858-864` already
  gives the identical hand-over fake a `#to_schema`. Restricted to the two fake-builder
  helpers; no assertion or example body touched. T8 (wave 2, same file) inherits the change.
- **T1 second behavior change, accepted:** `#to_schema` now returns the same memoized frozen
  Array per call rather than a fresh one. Every `lib/` consumer is read-only (`context.rb:162`,
  `session_record.rb:49`, `toolset/disclosure/upfront.rb:14`, `tools/tool_search.rb:72`, the
  bench recorders). **T7 must note:** a law asserting `to_schema` *object identity* across two
  calls would now pass vacuously.

**Follow-up tickets raised during execution (not in scope here):**

- **A-1. The monoid law generators are built through the operator they test.** Found by T6's
  panel via direct falsification, and it is a real hole in the bench's own proof machinery.
  `Middlewares.draw_from`, `Combinators.draw_from`, and `middleware_spec.rb:29-31`'s `compose`
  helper all build each population draw with `reduce(Identity, :>>)`. Make `>>` left-absorbing
  (return the receiver, discard the argument) and **the sweep stays green**: every draw
  collapses to bare `Identity`, so both monoid laws hold vacuously. This predates T6 — T6 was
  told to reuse `Combinators` as its model and did so faithfully, and the trap its own card
  named (bare-`Base`-instance populations) *is* correctly closed, verified by a second
  mutation that went RED. Fix is cross-cutting: construct monoid-law populations independently
  of the operator under test, across `Combinators`, `Middlewares`, and any future
  `draw_from`-shaped generator. **Not a gate on T6.** Note T7's and T10's generators do *not*
  have this shape — they draw from fixed pools rather than composing — so this chunk adds no
  new instances of it.
- **A-2. The lens pattern leaves `to_json` open, and it is not loud.** Found by T4's panel.
  `Canonical.normalize` refuses a lens with `UnsupportedType` — the closed door this chunk's
  grounding leans on — but `JSON` does not: `lens.to_json` yields `"\"#<Lain::…:0x…>\""`,
  *valid* JSON carrying a debug string. A journal line that parses but carries garbage is
  undetectable where a raise is not, and the Journal is the experiment record. **Ruled:**
  transparent delegation (`def to_json(*args) = @hash.to_json(*args)`), consistent with `#to_h`
  returning the hash by identity. Applied to `Response::ToolUse` in T4; **required of T8's
  `ResultBlock`, which is the one that actually sits a hop from `journal.rb`'s
  `JSON.generate`**; `Middleware::Env` and `Context::MessageEnvelope` share the hole and are
  fixed as an orchestrator-owned cleanup (neither file belongs to any card in either chunk).
- **A-4. Three definitions of one equality idea, and nothing says they differ.** Raised by T1's
  panel. `Lain::ContentAddressed` is the house convention (`Event`, `Event::Payload`,
  `Memory::Item`, `Memory::Index::Root`, `Plan::Closure`, `Plan::SeamPolicy`,
  `Workspace::Snapshot`); `Capability::DegradedSet` hand-rolls the trio while a comment claims
  it "mirrors" the module; `Toolset` (T1) now hand-rolls a third. **T1's is the correct one:**
  it guards with `instance_of?` where the other two use `is_a?`, and under `is_a?` plus a
  class-embedding `hash` the asymmetry both siblings write down as a caveat is a live
  `hash`/`eql?` contract violation waiting for the first subclass. **Ruled:** T1 keeps its
  semantics and documents the divergence rather than adopting the weaker guard. Converge
  `ContentAddressed` and `DegradedSet` onto `instance_of?` in a follow-up, then fold `Toolset`
  into the module.
- **A-5.** `Grader::Journaling#subject_digest` is a `respond_to?(:digest)` duck that `Toolset`
  now satisfies **by accident**, and `Bench::Session::RecordedToolset` (`bench/session.rb:81-89`)
  answers `#to_schema` but not `#digest` — so a replay can never assert `replayed == recorded`.
  "The same capability set" now has two representations and only one is comparable.
- **A-3.** `Lain::Session` exposes readers for `writes` and `pins` but **none for the
  read-set**. T2's fix makes this structural rather than incidental — its read-set anchor has
  to go through `read?` over a closed fixture. T2 had to ask `read?` over a closed fixture instead of comparing the set
  directly. A reader would make the order-independence claim direct rather than inferred.

**Process note for the remaining waves:** review agents must be pointed at the *implementer's*
worktree. A reviewer given its own `isolation: "worktree"` lands in a different tree and finds
git refuses to reach across, forcing content-hash workarounds. Spawn reviewers without
isolation and name the implementer's worktree path.

**Worktree note for every future card in both chunks:** a fresh worktree has no compiled
`lib/lain/lain.so`, so `bundle exec rake compile` is required before any spec runs. The failure
reads as `LoadError: cannot load such file -- lain/lain`, which looks like a missing gem.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb` (T5 adds one require
  line for `interval_partition`; T11 adds the one `seal` line — the second line follow-up 11
  budgeted), `.rubocop.yml`, `spec/spec_helper.rb`, `ROADMAP.md`.
- Multi-card non-shared files are wave-staggered instead of orchestrator-owned:
  `spec/support/algebra_generators.rb` (T6 w1 → T7 w2 → T10 w3), `lib/lain/algebra.rb`
  (T7 w2 → T11 w3), `lib/lain/agent/tool_runner.rb` (T4 w1 → T8 w2), `lib/lain/toolset.rb`
  (T1 w1 → T7 w2), `lib/lain/compaction/strategy/base.rb` (T5 w1 → T10 w3). Do not reorder
  waves without rechecking these.
- Every agent worktree forks from the session's start commit and may be stale: each
  implementer's brief opens with `git merge --ff-only main` before any other work.
- Re-baseline the spec count on post-chunk-B main before wave 1 and record it here.

## Open decisions

None gating. Four interview rulings recorded (Joel, 2026-07-29):

1. **All four streams in scope** (laws, lenses, partition, registry housekeeping).
2. **Lens/.wrap strategy for blocks**, not a Hash subclass, not Data+iso — ruled after the
   spike showed `Canonical.normalize` erases subclasses and raises on non-Hash.
3. **Land after chunk B**, not scoped around it.
4. **Refinement meet is IN scope** — un-defers `chunk-derived-context-timeline.md`
   follow-up 3, with the stated reason "building it proves the value/usage of the
   extraction". The deferral's own text ("speculative generality") is superseded by this
   ruling; T10 records that in the code's doc comment.

## Waves

```
Wave 1: T1, T2, T3, T4, T5, T6      (no unmet deps)
Wave 2: T7 (←T1), T8 (←T4)
Wave 3: T9 (←T8), T10 (←T5, T7), T11 (←T7)
Wave 4: T12 (←T9, T10, T11)
```

Critical path: four chains tie at length 4 — **T4 → T8 → T9 → T12**,
**T1 → T7 → T10 → T12**, **T1 → T7 → T11 → T12**, and **T5 → T10 → T12** is one shorter.
T10's `←T7` is a file dependency (both edit `algebra_generators.rb`), not a design one — it
uses the existing `commutative_monoid` structure.

## Tasks

### T1 — Give Toolset value equality          [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/toolset.rb`, `spec/lain/toolset_spec.rb`
**Reuse:** the mediated-equality precedent this formalizes — `Canonical.dump(to_schema)`
comparison at `toolset_spec.rb:79`; `Usage`/`Event` as `Data`-value equality exemplars.
**Shared-file wiring:** none

Equality is **canonical schema bytes**: two Toolsets are `==` iff `Canonical.dump(to_schema)`
matches (the names comparison is redundant with it — `to_schema` is name-sorted and each
entry carries its name — so names are at most a cheap early-out, stated as an optimization,
never as part of the definition). That is the equality prompt caching already lives by, and
it is honest about its scope: two tools with equal schemas and different `#perform` bodies
compare equal, and the doc comment must say so (schema equality, not behavioral equality).
**The digest is computed eagerly in `#initialize`, before the `freeze`** — `Toolset` freezes
itself at construction (`toolset.rb:34`), so a lazy `@digest ||=` memo is a guaranteed
`FrozenError`, not an option; and `to_schema` re-normalizes per call (`toolset.rb:99-101`),
which T7's property loops would pay repeatedly.

**Acceptance criteria:**

```gherkin
Scenario: same tools, any construction order, equal
  Given two Toolsets built from the same tools in different orders
  When they are compared with == and eql?
  Then both are true and their hashes are equal

Scenario: different capability sets are unequal
  Given one Toolset attenuated with #only and its parent
  When they are compared
  Then they are not equal

Scenario: a Toolset works as a Hash key
  Given a Hash keyed by a Toolset
  When an equal-but-distinct Toolset looks it up
  Then it finds the entry

Scenario: identity assertions are undisturbed
  Given the existing specs pinning posture identity (be(allowed), be(union), equal(toolset_before))
  When the suite runs
  Then they pass unchanged, because equal? is untouched
```
→ spec file: `spec/lain/toolset_spec.rb`

**Escalation triggers:**
- Any existing spec fails because it relied on `==` being object identity for Toolsets
  (grounding found none; `spawn_policy_spec.rb:239,256` and `wiring_spec.rb:109` use
  `be`/`equal`, which are safe) — stop and list them.
- The eager digest computation in `#initialize` visibly changes construction cost somewhere
  hot (unlikely — construction is per-wiring, not per-turn) — stop and show the numbers
  before moving the computation.

### T2 — Prove the exchange law behind parallel_safe?          [wave 1] [risk: medium]

**Depends on:** none
**Files:** `spec/lain/tools/parallel_commutation_spec.rb` (create)
**Reuse:** `ToolRegistry.build` and `shipped_names` (`spec/support/tool_registry.rb`) — the
same real-instance table `parallel_safety_spec.rb` uses; `Agent::ToolRunner#run` driven
directly with a built tool-use response (the `tool_response` builder in
`spec/support/mock_recording.rb:34`); `Effect::Handler::Live` over a real Toolset.
**Shared-file wiring:** none

The law `parallel_safe?` claims and nothing tests: for tools that opt in, results are
independent of execution order. For every unordered pair drawn from the ten
non-spawning true-set tools (`read_file list_files glob grep ast_search code_outline
file_symbols ast_dump test_pattern memory_read`), with fixed inputs over a deterministic
fixture workspace, each order runs as **two single-tool-use responses back-to-back** through
`ToolRunner#run` — a run of one is sequential by construction (`tool_runner.rb:198-201,
:226`), so both orders are genuinely serial and deterministic. **Do not build one two-use
response per order**: two true-set tools in one response *gather* concurrently
(`tool_runner.rb:76-84`), and comparing two gathered fan-outs is the timing-based probe
`parallel_safety_spec.rb:11-18` documents as proving nothing. Per tool, the `tool_result`
content and `is_error` must match across the two orders, and observable Session state (the
read-set) must be the same after both. `subagent` is excluded and the spec says why
(spawning is not a read). This is deliberately a spec-level sweep like
`parallel_safety_spec.rb`, not a registry structure: the per-tool `lib/` artifact is
`#parallel_safe?` itself, and this suite is its proof.

**Acceptance criteria:**

```gherkin
Scenario: every parallel-safe pair commutes on results
  Given a fixture workspace and fixed inputs for each of the ten read-set tools
  When each unordered pair runs in both orders, each order as two single-use responses back-to-back
  Then each tool's result block content and is_error are identical across the two orders

Scenario: the read-set is order-independent
  Given the same pairs
  When the Session read-set is compared after each order
  Then it holds the same recorded reads

Scenario: the suite tracks the shipped true-set
  Given a new tool declares parallel_safe? true
  When the sweep runs without being edited
  Then the new tool is included or the suite fails by name
```
→ spec file: `spec/lain/tools/parallel_commutation_spec.rb`

**Escalation triggers:**
- **A pair genuinely fails the law — STOP.** That is a real parallel-safety defect (the most
  valuable thing this card could find), not a spec to loosen. `Agent::ToolRunner#gather`
  ships that pair concurrently today.
- `grep`'s Core::Client path or FS-enumeration ordering makes a result
  nondeterministic across runs (not just across orders) — pin the fixture (sorted, no
  symlinks) first; if nondeterminism is in the tool, stop and report it.
- The sweep is slow enough to need a tag — mirror `:integration`'s opt-in mechanism only if
  a plain run exceeds a few seconds; do not silently exclude it.

### T3 — Pin posture equivalence over allowed calls          [wave 1] [risk: low]

**Depends on:** none
**Files:** `spec/lain/tools/subagent_posture_equivalence_spec.rb` (create)
**Reuse:** the scripted-child pattern at `subagent_spec.rb:26-56` (`build_subagent`,
`mock`, `loop_driven`); `tool_response`/`text_response` builders
(`spec/support/mock_recording.rb:28,34`); the existing one-posture refusal pin at
`subagent_spec.rb:161-180` stays where it is.
**Shared-file wiring:** none

CE-4 compares the two postures on cache economics; the comparison is honest only if they
agree on everything but the refusal shape. Same scripted call sequence, run twice.

**Acceptance criteria:**

```gherkin
Scenario: allowed calls are extensionally equal across postures
  Given one scripted child conversation whose tool calls all name allowed tools
  When it runs under posture :schema and again under :handler_union
  Then the delivered tool_result blocks are equal (the child's final text under
       Provider::Mock is script-determined either way, so it is deliberately not asserted)

Scenario: the divergence on a disallowed call is exactly the refusal shape
  Given a scripted call naming a tool outside the only-set
  When it runs under each posture
  Then both answer is_error results, the handler_union run journals a "refused" record and
       the schema run does not, and the spec names this as the designed divergence

Scenario: rendered schemas differ exactly as the postures declare
  Given the two runs
  When each run's rendered tools block is inspected
  Then :schema rendered only the allowed tools and :handler_union rendered the union
```
→ spec file: `spec/lain/tools/subagent_posture_equivalence_spec.rb`

**Escalation triggers:**
- Deliveries differ on an *allowed* call — that is a real finding about the seam (something
  besides tool bytes leaks into results); stop and report rather than weakening the law.
- Chunk B's T23 (`Spawn::Seam`) changed `build_subagent`'s construction shape — adapt the
  helper usage, and stop if the posture seam itself moved.

### T4 — ToolUse lens behind Response#tool_uses          [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/response/tool_use.rb` (create), `lib/lain/response.rb` (wrap in
`#tool_uses` + the subtree require, per the index convention), `lib/lain/agent/tool_runner.rb`
(consume readers), `spec/lain/response/tool_use_spec.rb` (create),
`spec/lain/response_spec.rb`, `spec/lain/agent/tool_runner_spec.rb` (must pass unchanged)
**Reuse:** `Middleware::Env` (`middleware/env.rb:31-51`) — idempotent `.wrap`, Hash-duck
surface, typed readers over `fetch`, and its spec's shape (`env_spec.rb`);
`Context::MessageEnvelope` (`context/message_envelope.rb:25-27`) — `#to_h` returns the
original by identity.
**Shared-file wiring:** none (`response.rb` is its own subtree's index)

`Response::ToolUse.wrap(block)`: frozen lens over the post-normalize string-keyed hash,
readers `#id`/`#name`/`#input` (each a `fetch`, so a malformed block raises `KeyError` with
the block in the message), Hash-duck `#[]`/`#fetch`/`#to_h` for compatibility, `#to_h`
returning the wrapped hash **by identity**. `Response#tool_uses` returns wrapped lenses;
`ToolRunner` reads `use.id`/`use.name`/`use.input` instead of `fetch("id")` etc. The wire
hash the runner builds and commits is unchanged.

**Acceptance criteria:**

```gherkin
Scenario: the lens is an identity-preserving view
  Given a tool_use block hash from a Response
  When it is wrapped, and wrapped again
  Then wrap is idempotent, #to_h is the same object, and #id/#name/#input read the fields

Scenario: a malformed block fails loudly at the reader
  Given a block missing "id"
  When #id is read
  Then a KeyError names the missing key

Scenario: committed bytes do not move
  Given a scripted turn with tool calls, run before and after this change
  When the committed turn's digest is compared
  Then it is identical

Scenario: the runner's behavior is unchanged
  Given the existing tool_runner_spec
  When it runs against the lens-consuming runner
  Then every example passes without modification
```
→ spec files: `spec/lain/response/tool_use_spec.rb`, `spec/lain/agent/tool_runner_spec.rb`

**Escalation triggers:**
- Anything downstream of `Response#tool_uses` outside `tool_runner.rb` breaks on receiving a
  lens instead of a raw hash (grounding says consumers are almost entirely in the runner;
  `provider_parity.rb:144-145` and `agent_spec.rb:181-183` are the first specs to check, and
  `grep -rn "tool_uses" spec/` makes the sweep mechanical — spec-side `["name"]` reads
  survive via the Hash-duck `#[]`) —
  if a consumer needs the raw hash, it can take `#to_h`; if the *set* of consumers is larger
  than grounding said, stop and list.
- `DuplicateToolUse`'s message or the observer pairing (`tool_runner.rb:136`) changes shape —
  those are pinned behavior; stop.

### T5 — Extract IntervalPartition as a public value          [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/interval_partition.rb` (create),
`lib/lain/compaction/strategy/base.rb` (delegate to it),
`lib/lain/compaction/source/derived.rb` (PinCuts' `#runs` uses the shared
runs-from-excluded-indices constructor), `spec/lain/interval_partition_spec.rb` (create);
`spec/lain/compaction/strategy_spec.rb`, `spec/lain/compaction/derivation_spec.rb`,
`spec/lain/compaction/source_spec.rb` must pass **unchanged**.
**Reuse:** the seven refusals at `strategy/base.rb:183-252` move (not copy) with their
rationale comments; `Lain::ContentAddressed` as the precedent for a lib-level property
value; `chunk_while`-into-ranges shape from `source/derived.rb:273-278`.
**Shared-file wiring:** `lib/lain.rb` — one require line for `interval_partition`, placed
before `compaction` (its new dependent).

`Lain::IntervalPartition`: a frozen value of `(owner, span, ranges)` carrying the seven
refusals, `#validated`, plus two constructors the second and third instances need:
`.covering(span, excluding:)` — the PinCuts shape, contiguous runs of non-excluded
indices — and `.of(span, ranges, owner:)`. `Strategy::Base#ranges` delegates; its private
`Partition` constant is deleted. Three design points, ruled here rather than discovered
mid-card (panel findings):

- **Canonical range form.** `0..2` and `0...3` are one interval with two spellings
  (`base.rb:257-261` and `derivation.rb:331-334` both pay for that today). The value
  normalizes to inclusive `Integer..Integer` at construction, so T10's `#meet` and equality
  never see two spellings. Refusal checks and their messages run against the range **as
  proposed** (pre-normalization), so the pinned examples (`2..1` and `2...2` both refused
  as empty, `strategy_spec.rb:224-229`) keep their text.
- **Provenance in messages.** `refuse_answerless`'s message embeds the strategy hook name
  ("from #propose_ranges", pinned by `derivation_spec.rb:503`'s regex). That fragment is
  part of a `provenance` argument the strategy path supplies; `.covering` and other
  constructors supply their own, so a PinCuts or meet refusal never cites a hook it did not
  call.
- **The error is the value's.** `NotAPartition` moves to `Lain::IntervalPartition`
  (subclassing `Lain::Error`); `Strategy::NotAPartition` becomes a constant alias so rescue
  sites and pinned specs are untouched. A lib-level value raising a compaction-namespaced
  error would invert the dependency this extraction exists to fix.

`ToolRunner` is deliberately **not** adopted here (its chunk_while is over use-objects, not
indices; T12 records the relationship in the glossary instead — adopting it would be change
for symmetry's sake).

**Acceptance criteria:**

```gherkin
Scenario: all seven refusals survive the move byte-for-byte where specs pin them
  Given the existing strategy_spec and derivation_spec malformed-proposal examples
  When the suite runs against the extracted value
  Then every example passes without modification

Scenario: the value is directly usable and spec'd on its own
  Given a span and ranges
  When each of the seven malformed shapes is validated
  Then each refusal raises NotAPartition naming the owner, and a well-formed answer returns unchanged

Scenario: PinCuts builds its runs through the shared constructor
  Given a span and pinned indices
  When PinCuts proposes ranges
  Then source_spec's pin behavior (keep_last + 3, pinned turn verbatim in place) passes unchanged

Scenario: the value is a value
  Given an IntervalPartition
  Then it is frozen and Ractor.shareable?
```
→ spec files: `spec/lain/interval_partition_spec.rb`, plus the three existing compaction
specs unchanged

**Escalation triggers:**
- The sealing machinery (`base.rb:271-278`, `SEALED`) breaks under delegation — the seal
  exists so no subclass reaches an unvalidated answer; if delegation opens that door, stop.
- Any pinned error-message regex (`/answers nil.*#propose_ranges/`,
  `derivation_audit_spec.rb:385-395`'s `"NotAPartition"`) requires changing — stop; the
  messages are contract.
- `NotAPartition`'s constant home moves (it lives on `Strategy::Base` today, `base.rb:9`) —
  keep a constant alias so rescue sites and specs are untouched, or stop.

### T6 — Declare Middleware's monoid          [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/middleware.rb`, `spec/support/algebra_generators.rb`
**Reuse:** the declaration shape at `context/base.rb:78` (`monoid on: :>>, identity:
Algebra.later { ... }`); `Combinators.observationally_equal`
(`algebra_generators.rb:76-79`); the `strategy_claims` idiom (`:34-39`) since the generators
method is at `Metrics/MethodLength`'s limit; the five existing `include_examples "a monoid"`
sites stay byte-unchanged (declaration is never a precondition — `algebra_laws_spec.rb:24-28`).
**Shared-file wiring:** none

Closes follow-up 0 of `chunk-algebra-vocabulary.md`. Subject is `Middleware::Base` (the
class `Identity = Base.new` at `middleware.rb:75` instantiates — the exact
`Context::Identity` shape `Algebra.later` exists for). The generator must draw observable
subclasses, not bare `Base` instances (the vacuous-pass trap, `algebra_generators.rb:48-53`).

**Acceptance criteria:**

```gherkin
Scenario: reading middleware.rb tells you it is a monoid
  Given lib/lain/middleware.rb
  When the registry is asked what Middleware declares
  Then a monoid on its composition operator with Identity appears

Scenario: the sweep proves it
  Given the algebra law sweep
  When it runs
  Then the Middleware declaration runs the monoid group against an observable-subclass population

Scenario: nothing else moves
  Given the surviving include_examples call sites and the middleware specs
  When the suite runs
  Then all pass byte-unchanged (five sites at 30e82b4, but chunk B's T36 lists env_spec.rb
       among its deletion files — re-count after chunk B lands, do not assert "five")
```
→ spec files: `spec/algebra_laws_spec.rb` (sweep picks it up), `spec/lain/middleware_spec.rb`
(unchanged)

**Escalation triggers:**
- `include Algebra::Monoid` on `Base` must happen **above** `Identity = Base.new` or the
  verb isn't defined yet at declaration time; if load order inside the file forces something
  uglier, stop and show it.
- `registry.about(Middleware::Composed)` answering `[]` (declared on `Base`) confuses a
  consumer — the `Context::Combinator` precedent says base-only is correct; note it in the
  doc comment rather than declaring twice.

### T7 — The attenuation structure, its laws, and the refused join          [wave 2] [risk: high]

**Depends on:** T1
**Files:** `lib/lain/algebra.rb` (STRUCTURES + any new evidence field),
`lib/lain/algebra/attenuation.rb` (create), `lib/lain/toolset.rb` (declaration),
`spec/support/shared_examples/attenuation.rb` (create), `spec/algebra_laws_spec.rb`
(GROUPS/EVIDENCE/POPULATIONS entries), `spec/support/algebra_generators.rb` (Toolset
generator), `spec/lain/toolset_spec.rb` (direct include_examples, matching the house
pattern of proving where the value lives too)
**Reuse:** `Algebra::Elementwise` (`algebra/elementwise.rb`) as the model for a structure
with extra evidence fields; the 9-step recipe in this plan's Grounding; T1's equality as the
law group's `equal:`.
**Shared-file wiring:** none

New structure `:attenuation`, declared per-operation-pair on `Toolset`
(`attenuation on: :only, dual: :except`). The law group, parameterized on a population of
(toolset, name-subset) draws:

- idempotence of `only`: `ts.only(*a).only(*a) == ts.only(*a)` — re-requesting the same
  names is permitted and stable
- chained `except` raises: `ts.except(*x).except(*x)` raises `UnknownTool`, pinned as a
  first-class law (panel ruling: the "run it twice from the parent" restatement is
  `f(p) == f(p)`, determinism dressed up as idempotence — the raise IS the honest fact)
- composition, both halves: for `b ⊆ a`, `ts.only(*a).only(*b) == ts.only(*b)`; for
  `b ⊄ a`, the chain raises `UnknownTool` (the research doc states both halves; dropping
  the raise half would leave the partiality unpinned)
- duality: `ts.except(*x) == ts.only(*(ts.names - x))`
- monotonicity (the no-join law): every attenuation's names are a subset of the receiver's,
  and no public message on the result can name a capability the receiver lacked
- identity: `ts.only(*ts.names) == ts` and `ts.except() == ts`

The refused join is recorded where a reader will meet it: the declaration in `toolset.rb`
carries the security reading in its doc comment ("a capability once dropped cannot be
regained by the holder; union exists only at construction, below the trust boundary"), and
monotonicity is the law that makes it checkable. No `:join_semilattice` structure is added
just to refute it — a structure with no positive declarer anywhere fails the chunk's own
"named consumer" bar.

**Acceptance criteria:**

```gherkin
Scenario: reading toolset.rb tells you the attenuation structure
  Given lib/lain/toolset.rb
  When the registry is asked what Toolset declares
  Then the attenuation on #only with dual #except appears, with the no-join reading in its doc

Scenario: the sweep proves the laws
  Given the law sweep and a generator drawing toolsets and name-subsets
  When it runs
  Then the laws hold, including both raise-halves (chained except, only outside the subset)

Scenario: a declaration with no generator still fails by name
  Given the sweep's existing coverage examples
  When the attenuation structure is declared without its generator
  Then the sweep fails naming Toolset, the operation, and the absent generator

Scenario: nothing about Toolset behaves differently
  Given the pre-existing toolset_spec examples
  When the suite runs
  Then all pass unchanged
```
→ spec files: `spec/algebra_laws_spec.rb`, `spec/lain/toolset_spec.rb`

**Escalation triggers:**
- **A law genuinely fails** (e.g. duality breaks on a normalize edge case) — stop; that is a
  real Toolset defect, not a law to weaken.
- The `Declaration` Data needs more than one new evidence field (`dual:`) — the design may be
  wrong; per-operation claims were the chunk-algebra ruling, so stop and present before
  inventing a multi-operation declaration form. The `dual:` itself must be held to the same
  `answers?` check `refuse_unanswered` applies to the operation (`algebra.rb:209-214`) — a
  typo'd dual registering silently and failing far from the declaration is the exact failure
  the registry's loud-refusal posture exists to prevent.
- If `:attenuation` seems to need a battery (something refutes it), stop — nothing in this
  plan refutes it, and monoid's own missing battery is the precedent for shipping without
  one.

### T8 — ToolResult lens on the write side          [wave 2] [risk: medium]

**Depends on:** T4
**Files:** `lib/lain/tool/result_block.rb` (create), `lib/lain/tool.rb` (subtree require
line — it is the `tool/*` index), `lib/lain/agent/tool_runner.rb` (`#result_block` builds
through the lens), `spec/lain/tool/result_block_spec.rb` (create),
`spec/lain/agent/tool_runner_spec.rb` (unchanged)
**Reuse:** T4's lens shape; `Tool::Result` (`tool.rb:221-251`) — the lens is the missing
arrow from Result to wire; `Context::MessageEnvelope`'s identity-preserving `#to_h`.
**Shared-file wiring:** none

`Tool::ResultBlock.of(result, tool_use_id:)` builds the 4-key wire hash once, in one place,
and wraps it: readers `#tool_use_id`/`#content`/`#error?`, Hash-duck `#[]`/`#fetch`/`#to_h`
(identity). Gate 4 (the id) and gate 3 (`is_error` from `result.error?`, never inferred)
become constructor invariants — a ResultBlock without an id is unbuildable. **Preserve the
four-key insertion order** (`type, tool_use_id, content, is_error`): `Canonical` sorts for
digests, but the NDJSON journal serializes insertion order, and integration check 3 diffs
bytes.
`ToolRunner#result_block` returns `ResultBlock.of(...).to_h` so everything downstream
(delivery, commit, observer) sees the identical plain hash; `.wrap(hash)` re-lenses a
post-normalize block for T9's readers.

**Acceptance criteria:**

```gherkin
Scenario: the wire hash is byte-identical
  Given a scripted turn with tool results, run before and after this change
  When the committed turn's digest is compared
  Then it is identical

Scenario: the gates are constructor invariants
  Given a Tool::Result and no tool_use_id
  When a ResultBlock is built
  Then construction refuses loudly, and is_error always equals the Result's error?

Scenario: wrap and build agree
  Given a block built by .of and the same hash re-wrapped by .wrap
  When their readers are compared
  Then they answer identically, and #to_h of each is the underlying hash by identity

Scenario: the runner's behavior is unchanged
  Given the existing tool_runner_spec (including observer pairing and DuplicateToolUse)
  When it runs
  Then every example passes without modification
```
→ spec files: `spec/lain/tool/result_block_spec.rb`, `spec/lain/agent/tool_runner_spec.rb`

**Escalation triggers:**
- The observer seam (`tool_runner.rb:134-161`) or `Summarizing::Observer` turns out to need
  the lens rather than the hash — keep the seam's documented duck (`#observe(block, name)`
  with a hash) and stop if that duck must change.
- Chunk B's T21 moved `ToolRunner` construction into injected collaborators — the lens is
  internal to the runner and should not care, but if the runner's file moved shape
  substantially, re-anchor before editing.

### T9 — Adopt the read-side lens at the block hotspots          [wave 3] [risk: medium]

**Depends on:** T8
**Files:** `lib/lain/context/purge_failed_inputs.rb`, `lib/lain/context/dedupe_tool_calls.rb`,
`lib/lain/event/projection.rb`, `lib/lain/plan/closure.rb`,
`lib/lain/grader/tool_call_index.rb`; their five spec files (assertions unchanged; setup may
build blocks through the lens)
**Reuse:** `Tool::ResultBlock.wrap` and `Response::ToolUse.wrap` from T8/T4;
`MessageEnvelope`'s rule — the hash stays the primitive, the lens is a view.
**Shared-file wiring:** none

The five non-provider hotspots outside the runner (grounding's counts: 5+5+2+3+6 raw
accesses) read through the lenses' named readers instead of bare string keys. Behavior does
not change; `conversation.rb`, `compaction/summary_snapshot.rb`, `consolidation.rb`, bench
and CLI inspection sites are deliberately left for a follow-up — this card proves the
adoption pattern at the sites whose specs are strongest, it does not sweep the tree.

**Acceptance criteria:**

```gherkin
Scenario: behavior is unchanged at every adopted site
  Given the five files' existing specs
  When they run against the lens-reading implementations
  Then every assertion passes unmodified

Scenario: the adopted files no longer touch bare block keys
  Given the five files
  When grepped for "tool_use_id"], ["is_error"], fetch("id") on block hashes
  Then the reads go through lens readers (the wire-building and journal-record sites excepted)

Scenario: the algebra declarations still hold
  Given DedupeToolCalls' and PurgeFailedInputs' elementwise-given declarations and refutations
  When the law sweep runs
  Then all pass unchanged
```
→ spec files: the five existing spec files, unchanged in their assertions

**Escalation triggers:**
- `grader/tool_call_index.rb` re-normalizes fields through `Canonical.normalize`
  (`:133-135`) — the lens must hand back the same objects so those digests cannot move; if
  wrapping perturbs any digest, stop.
- A site turns out to read a key the lens has no reader for (e.g. nested content shapes in
  `purge_failed_inputs`) — add the reader to the lens (one place), never a one-off fetch;
  if the reader list grows past the block's actual wire fields, the lens is becoming a god
  object — stop.

### T10 — The refinement meet, and the strategy composition that proves it          [wave 3] [risk: high]

**Depends on:** T5, T7 (file-stagger on `algebra_generators.rb` only)
**Files:** `lib/lain/interval_partition.rb` (`#meet`),
`lib/lain/compaction/strategy/composed.rb` (create), `lib/lain/compaction/strategy.rb`
(subtree index require), `lib/lain/compaction/strategy/base.rb` (the hook widening),
`lib/lain/compaction/derivation.rb` (the fold passes the range through),
`lib/lain/compaction/strategy/elide.rb`, `lib/lain/compaction/strategy/summarizing.rb`,
`lib/lain/compaction/strategy/identity.rb` (hooks gain the ignored parameter),
`spec/lain/interval_partition_spec.rb`,
`spec/lain/compaction/strategy/composed_spec.rb` (create),
`spec/support/algebra_generators.rb` (generator for the composition claim);
`spec/lain/compaction/{strategy,derivation,derivation_audit,source}_spec.rb` must pass
unchanged.
**Reuse:** `Strategy::Identity` (`strategy/identity.rb:33`, `NO_RANGES`) is the unit;
`Strategy::Base`'s sealed `#ranges`/`#collapse` template — `Composed` is one more subclass,
not a new seam; the existing `commutative_monoid` structure and law group (no new
STRUCTURES entry); the deferral text at `chunk-derived-context-timeline.md` follow-up 3 —
its design IS this card's spec: disjoint range-sets, partial, commutative, Identity as unit.
**Shared-file wiring:** none

`IntervalPartition#meet(other)`: the common refinement — union of cut points over T5's
canonical range form — over the same span (mismatched spans refuse).
`Strategy::Composed.new(a, b)` (spelled `a | b` on `Strategy::Base`): `#propose_ranges`
answers the two strategies' range-sets when they are **disjoint** and refuses loudly on
overlap, naming both owners and the overlapping indices (the partiality is the contract,
not a failure mode to paper over).

**The dispatch design, ruled at plan time (panel blocker resolved 2026-07-29).**
`#collapse` is sealed (`base.rb:271-278`) and its subclass hook receives only the message
slice (`derivation.rb:341` throws the range away), so per-range ownership can live neither
in an override nor in a memo (strategies must stay frozen and `Ractor.shareable?` —
`Scheduler::COMPOSE` enforces it). Two coordinated moves instead:

1. **The template widens.** The fold already holds the range at its call site;
   `Plan#writes` passes it through, `Base#collapse(messages, range: nil)` forwards it, and
   the hook contract becomes `#blocks(messages, range)`. Every in-tree hook (Elide,
   Summarizing, Identity) gains the ignored parameter in this card. The seal is untouched:
   it prevents *subclass* overrides, and this is the template owner evolving its own
   signature — the thing the seal exists to protect.
2. **Owner-tagged ranges.** `Composed#propose_ranges` answers instances of a small frozen
   `Range` subclass carrying its owning strategy. It passes `refuse_foreign`'s
   `is_a?(Range)`, slices messages exactly as a Range, and — because `#validated` returns
   the proposed objects unchanged and the fold iterates those same objects — arrives back
   at `Composed#blocks(slice, range)` still knowing its owner. Stateless, no memo, no
   slice-content matching, shareability intact. Ranges never pass through `Canonical`
   (they live inside one turn's derivation), so the Hash-subclass erasure lesson does not
   apply to them. T5's canonical-form normalization must **preserve** an owner-tagged
   range's class when it is already in canonical form, or normalize via the subclass's own
   constructor — state which in the code.

Declared `commutative_monoid on: :|` with `Algebra.later { Strategy::Identity.new }` as
unit. **The generator's population design (panel):** the shared monoid group draws its
population via a nullary `generator` called independently per law — up to 3 uncoordinated
draws — so "disjoint pairs only" cannot be expressed as a filter. The generator instead
cycles a fixed list of **≥ 4 zone-disjoint strategies** (each owns a distinct index zone of
one shared span), so any within-law draw set is pairwise disjoint and never `a | a`; the
zones carry non-empty range-sets so the population is not vacuous, and `Identity`
(NO_RANGES) is disjoint with everything by construction. The composed spec demonstrates the
motivating case end to end: elide on tool spans, a deterministic summarizing stand-in on
conversational spans, one derivation, both collapses present, retained gaps intact. The
un-deferral ruling (Joel, 2026-07-29: building this proves the extraction) goes in
`Composed`'s doc comment with the date.

**Acceptance criteria:**

```gherkin
Scenario: the meet is the common refinement
  Given two well-formed partitions over one span
  When they are met
  Then the result cuts wherever either operand cuts and claims only what BOTH claim -- the
       pairwise intersection; it is finer than each under #refines?; and meeting with the
       partition that claims the whole span uncut returns the other operand
  # REWORDED AT EXECUTION (2026-08-02). The original said "the result's cut points are the
  # union of both", which silently assumes TOTAL partitions. These have GAPS -- retained
  # turns live in them -- and under a cut-point reading the meet would FILL those gaps,
  # inventing coverage nobody proposed. Worse, that reading breaks two of this scenario's
  # own three clauses on gapped input: `trivial.meet(other)` answers a re-cut partition
  # rather than `other`, and the result does not `refines?` its own operand. Intersection
  # holds all three. Verified exhaustively: over all 34 partial interval partitions of
  # 0..3, #refines? is a genuine partial order and #meet is the GREATEST lower bound for
  # all 1156 pairs, with zero exceptions.

Scenario: composition is a commutative monoid on disjoint proposals
  Given the law sweep and a generator drawing disjoint strategy pairs
  When it runs
  Then identity and commutativity hold, and a | Identity collapses exactly as a alone

Scenario: overlap refuses loudly
  Given two strategies proposing overlapping ranges over one span
  When the composed strategy is asked for ranges
  Then it refuses naming both owners and the overlapping indices

Scenario: the motivating case derives correctly
  Given a span with a tool stretch and a conversational stretch
  When elide-on-tools composed with a deterministic span summarizer derives
  Then the tool stretch is elided, the conversational stretch is summarized, retained turns
       sit in the gaps, and the derivation's existing well-formedness specs pass unchanged
```
→ spec files: `spec/lain/compaction/strategy/composed_spec.rb`,
`spec/lain/interval_partition_spec.rb`

**Escalation triggers:**
- Commutativity fails because collapse output depends on operand order even over disjoint
  ranges (ranges are folded in ascending index order regardless of operand order, so it
  should not) — stop; that would mean the derivation fold reads operand structure it must not.
- The hook widening (`#blocks(messages, range)`) breaks any pinned spec —
  `strategy_spec.rb:129-185` pins sealing and hook ownership, `derivation_spec.rb` pins the
  fold's writes — stop; the widening is supposed to be observably invisible to every
  existing strategy.
- A zone-disjoint generator still produces an overlapping draw pair inside one law run (the
  cycle length must exceed the group's max draws-per-law, currently 3) — fix the cycle, and
  if the group's draw count grows past the cycle length, stop rather than shrinking zones to
  slivers, per the vacuous-pass trap.

### T11 — Latch the verbs, seal the registry          [wave 3] [risk: medium]

**Depends on:** T7
**Files:** `lib/lain/algebra.rb` (`Registry#seal`, guards), `lib/lain/algebra/monoid.rb`,
`commutative_monoid.rb`, `meet_semilattice.rb`, `elementwise.rb`, `pure.rb`,
`attenuation.rb` (the latch, uniformly), `spec/lain/algebra_spec.rb`
**Reuse:** follow-ups 0b and 11 of `chunk-algebra-vocabulary.md` — "the same invariant seen
from the declaring side and the registry side" — including the recorded probe (global
registry grew 0→1 and retained an anonymous spec class); the injected-`registry:` pattern
`algebra_spec.rb` already uses.
**Shared-file wiring:** `lib/lain.rb` — the one `Lain::Algebra.registry.seal` line after the
last unit loads (the "second line" follow-up 11 budgeted).

After seal: `declare`/`refute` on the sealed global raise a named error; specs keep
declaring against injected registries exactly as today; the sealed registry is frozen and
enumerable. The latch is the same check surfaced through the verbs, so
`Lain::Timeline.meet_semilattice(on: :length, ...)` at runtime raises instead of mutating
process-global state.

**Acceptance criteria:**

```gherkin
Scenario: a post-load declaration is refused
  Given the fully loaded library
  When any declaration verb runs against the global registry
  Then it raises a named Sealed error and the registry is unchanged

Scenario: injected registries are untouched
  Given a spec-local Registry
  When a class declares against it after seal
  Then the declaration lands, exactly as before

Scenario: the sweep still sees everything
  Given the sealed global registry
  When spec/algebra_laws_spec.rb runs
  Then every declaration and refutation is enumerated exactly as before sealing
```
→ spec file: `spec/lain/algebra_spec.rb`

**Escalation triggers:**
- Any spec or lib file declares against the GLOBAL registry after load — grep for the
  declaration verbs themselves called **without** a `registry:` kwarg in `spec/` (the hazard
  follow-up 11 recorded is a verb call that *forgets* the kwarg, which contains no literal
  `Algebra.registry` to grep for); grounding expects the tree clean — stop and list any hit
  before sealing.
- Sealing needs to freeze `@entries` deeply and something holds a reference it mutates —
  stop; that would be a live bug worth its own report.

### T12 — Record the vocabulary where readers will meet it          [wave 4] [risk: low]

**Depends on:** T9, T10, T11
**Files:** `docs/GLOSSARY.md`, `ARCHITECTURE.md` (the "Tools, tiers, and the toolset" and
algebra sections), `planning/tool-use-algebra.md` (status notes on what landed)
**Reuse:** the glossary's existing entry style (general definition first, lain-specific
second); the research doc's phrasings for the lens rule and the no-join reading.
**Shared-file wiring:** none

Updates: the interval-partition entry (seven refusals, now a public value, its three
instances — strategies, PinCuts, and `ToolRunner#contiguous_runs` as the *unadopted* sibling
with the reason; the refinement meet now built); a lens entry (Env, MessageEnvelope,
ToolUse, ResultBlock as one pattern — "the string-keyed shape is the pipeline primitive; a
value is a lens onto it"); the attenuation laws and the no-join security reading; the
handler-chain left-bias note; the "rendered schema does not determine capability under
handler_union" note. ARCHITECTURE's algebra table gains the new declarations.

**Acceptance criteria:**

```gherkin
Scenario: the glossary answers what a reader of the new code will ask
  Given docs/GLOSSARY.md after this chunk
  When a reader looks up interval partition, lens, or attenuation
  Then each entry states the general concept, the lain instances by file, and what proves it

Scenario: no stale claims remain
  Given the glossary's five-refusals sentence and ARCHITECTURE's algebra table
  When they are read against the landed code
  Then the counts, file paths, and structure lists match
```
→ spec file: none (docs card; `spec/lain/gherkin_spec.rb` still parses this plan's fences —
keep them valid)

**Escalation triggers:**
- A claim this card would write contradicts what actually landed (e.g. T10 shipped with a
  different operator spelling) — the docs follow the code; re-read the landed diffs, never
  the plan, before writing.

## Integration checks

After the last wave:

1. `bundle exec rake` (compile, full suite, rubocop) green; spec count strictly above the
   wave-1 re-baseline (new: interval_partition, composed, commutation, posture-equivalence,
   result_block, tool_use lens, attenuation group).
2. `pre-commit run --all-files` green; commits in dependency order per CLAUDE.md.
3. **Digest stability end to end:** `Bench::DryReplay` over a recorded session with tool
   calls reports zero byte diff against its pre-chunk recording — the lens cards' invariant,
   checked at the system level, not just per-spec.
4. The seven pre-existing shared example groups in `spec/support/shared_examples/` are
   byte-unchanged; the only additions are the new `attenuation.rb` group. `spec/lain/rust/*`
   passes unmodified (the port-acceptance rule).
5. `spec/support/algebra_generators.rb` still passes RuboCop without any `Metrics` config
   change (the strategy_claims overflow idiom, not a limit bump).
6. **Manual pass owed to Joel:** read `lib/lain/interval_partition.rb` and
   `lib/lain/toolset.rb` cold — confirm each answers "what structure is this, and what
   proves it" without leaving the file; and one skim of a `ResultBlock`-built turn in a live
   session journal to confirm the wire shape reads exactly as before.
