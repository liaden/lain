# Simplify 09 — verbs terminate, adverbs decorate, and an operation gets a name

status: draft — **dropped, not run**; see Execution log
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson; Edward Kmett and Philip Wadler join for T3 and T4

## Execution log

**2026-09-13, by the human: this plan does not run. Dropped whole, not deferred card by card.**

It was queued alongside simplify-08 and simplify-10 and pulled before any card was spawned. The
reason is the algebra half, and the finding is recorded in full at
[`research-algebra-registry-vs-operations.md`](research-algebra-registry-vs-operations.md).

**What the research found.** The plan's thesis — that `Algebra::Registry` is a workaround for
operations not being first-class objects, and that reifying them would encode the same claim in the
type system the way a Rust zero-sized type does — **does not survive contact with the code.** The
registry does five jobs, and the load-bearing one is five **load-time refusals**
(`algebra.rb:232`, `:243`, `:251`, `:258`, `:273`, plus `meet_semilattice.rb:55` and
`attenuation.rb:68`) — Ruby's re-implementation of Rust's impl-completeness check. Ruby's `include`
checks nothing, so module inclusion is a strictly **weaker** claim than a registry entry, and
reification would *lose* the guarantee it was supposed to strengthen. The law sweep also cannot
enumerate operation objects without `ObjectSpace` (rejected at `spec/algebra_laws_spec.rb:9-10`), a
hand-maintained list, or an `included` hook — and an `included` hook is a registry.

**Both algebra cards rested on false premises.**

- **T3** is dead in both halves. Its AC 1 ("the registry has no production reader") cannot pass:
  `Algebra::Pure#pure?` (`algebra/pure.rb:59`) reads `declares?`, with 12 spec sites behind it. And
  dropping the negative verbs contradicts `spec/spec_discipline_spec.rb:964-969`, which rules that
  *"the negative verbs exist to be called by a spec; that is their whole job"* — 20 spec sites. The
  card's counts were also wrong: three `not_a_*` verbs, not six; ~18 declarations and ~6 refutations,
  not "24 claims and 5 refutations".
- **T4**'s four justifications are each false. Its `Reachable from` claim is false — `#meet`,
  `#causal_meets` and `#dominator_meet` have **zero callers in `lib/` or `exe/`**. It does **not**
  gate simplify-13: 13's trait takes `ctx` as a *parameter* and `Ctx` is an associated *type*, so the
  Rust design does not bind the store, and 13 lists the Ruby change as a *should* at wave 9. "A line
  in a catalog" is false because the Rust meet needs `Ext::Store`, making the seam the store
  constructor. And `CrossStore` is a **rename**, not a deletion — 8 spec assertions, 0 rescues, 2
  `lib/` prose sites. T4 would additionally orphan the `Ext::Timeline` "must not drift" mirror that
  simplify-02's T5 added at `lib/lain.rb:141-162`.

**T1, T2 and T5 were independently sound** — none touches `algebra/`, `timeline.rb` or the registry —
and they are dropped only because the plan is dropped, not because anything is wrong with them. If
they are revived, they need `staleness-09.md`'s corrections applied first (notably: `agent_build.rb`
does not exist, `Effect::Handler::Summarizing` has zero production construction sites, and the
meeting line has moved to `agent/tool_runner.rb:455`), and the honest remaining thesis is **"an
operation with no name can be neither selected nor recorded."**

**The standing direction, from the human, 2026-09-13:** *move away from the `Registry` in general,
as a future rearchitecture consideration.* That is a larger question than this plan, and the
research above is the constraint list any such rearchitecture has to answer — the five load-time
refusals and the sweep's enumeration problem are the obstacles, and neither is solved by reification
alone. See `research-algebra-registry-vs-operations.md` §1, §2 and §7.


## Intent

Lain's clean, lawful, composable parts are the ones where the operation is already a first-class
object — `Compaction::Strategy`, `Middleware`, `Arm`, `Oracle`, the context combinators. Its messy
parts are nouns that accumulated behaviour. Seven families already hold ~64 operation-objects and
**exactly one of them is selectable at runtime**, so the missing piece is not reification but a name
and a resolver.

This plan applies that one idea in four places: it splits `Effect::Handler` on the line between
things that *interpret* an effect and things that merely *decorate* the call; it takes the three
meet-ish operations off `Timeline`, which is an element of the lattice rather than the lattice; it
trims the algebra registry to what it is actually for; and it gives the context pipeline a name so
it can be both selected and recorded.

Delivers: `Effect::Handler` as one `call(effect, context) -> Result` with three implementations, four
adverbs moved to `Middleware`; one place an agent's handler chain is wired; a registry with no
production surface and one way to file a refutation; `Timeline`'s meets as store-bound operation
objects, which makes a cross-store meet unconstructable rather than merely refused at runtime; and a
named, journaled context pipeline.

## Grounding

Verified 2026-09-12 against the working tree at `d2bb133c`. `code` is non-blank, non-comment.

**Reification is already done; the catalog is what is missing.** Seven families of operation-objects:

| family | impls | runtime-selectable? |
|---|---|---|
| `compaction/strategy` | 8 | **yes** — `--compact-strategy`, `+`-composable |
| `context` (combinators) | 16 | no flag |
| `middleware` | 9 | no flag |
| `arm` | 12 | no flag |
| `oracle` | 11 | no flag |
| `toolset/disclosure` | 2 | no flag |
| `effect/handler` | 6 | no flag |

~64 objects, one resolver. And the resolver mechanism exists: `Lain::DslCatalog`, **50 lines**, two
users (`Summarizer::Catalog`, `Isolation::Services`), where a subclass names exactly a public
`DSL_PATH` and `def self.builder = Builder`.

**The counter-example proves it is a wiring choice.** `--compact-strategy elide-tools+summarize-conversation`
works: four named strategies from one authority (`cli/compaction_strategy.rb:120`), help text derived
from that same constant so it cannot drift, `+` composition folding through a declared commutative
monoid, **deliberately no Thor default** (`exe/lain:817-826`) so the unset state stays reachable as the
control arm, and loud refusal on a typo. 315 code lines of strategies behind a 62-line resolver. The
context axis uses the same `>>` idiom and the same monoid machinery and never got a resolver.

**Two composition mechanisms of identical shape, and the code says so.**
`effect/handler.rb:16-18`: handlers compose *"by decoration — each holds an optional `inner`… the same
chain-of-responsibility shape the middleware stack uses, one layer down."* They meet at exactly one
line, `agent/tool_runner.rb:414`:

    @middleware.call({effect:, context:}, &@handler.to_app).result

Of the six handlers, **three interpret** — `Live`, `Mock`, `Recorded` — and **four decorate**:
`Gate`, `Sensitivity`, `Summarizing`, `Subagent::RefusingHandler`. The four wrap, maybe short-circuit,
else pass downstream, which is the definition of a middleware — and they already have middleware
siblings doing the same job on the result side (`RefuseSecretWrites`, `RedactSecretReads`,
`WithholdSecretPaths`).

**The `handles?`/`perform`/`inner` triad forces both to route around it.** `Gate#run`
(`effect/handler/gate.rb:94-98`) and `Sensitivity#decline` (`effect/handler/sensitivity.rb:97-101`)
each re-implement the delegation `Handler#call` was supposed to own. And `Sensitivity#perform` has a
nil-branch (`:70-78`) purely because `handles?` and `perform` can straddle a board change.

**The one objection to answer.** `gate.rb:18-20` argues `Gate` must read the tool off whatever `inner`
resolves, so authorization cannot be decided against a different set than possession. A middleware
answers this *better* than a chain-walk: resolve the tool once in `ToolRunner#dispatch` and put it in
the env, so gate and terminal handler read the same object by construction. Note **`ToolRunner`
already holds a second `@toolset` reference at `:186`**, so the current design does not deliver the
single-reference guarantee it claims.

**The registry's production surface serves one dead consumer.** `Algebra.registry`'s only
non-declaring reader in `lib/` is `Compaction::DerivationAudit` — `:277`'s
`declares?(subject:, operation: BLOCKS, structure: :pure)` and `:283`'s `refutations.any?` — and
`DerivationAudit` has zero callers. **simplify-03's T7 deletes it.** After that, the registry is
filed at load and read only by `spec/algebra_laws_spec.rb`, so `declares?` and `refutations` can leave
the production surface.

**Two ways to file a refutation.** Six `not_a_*` verbs exist, but only `not_a_meet_semilattice` is
used (2 entries: `timeline.rb:185`). The other three refutations are filed by calling
`Algebra.registry.refute` **directly** — `context/purge_failed_inputs.rb:103`,
`compaction/strategy/summarizing.rb:247`, `:253` — and `algebra/elementwise.rb:111` documents the
direct route as sanctioned. **Twelve verbs support five entries, with production preferring the path
that bypasses them.** Filed: 24 claims (elementwise 7, meet_semilattice 5, monoid 4, pure 4,
attenuation 2, commutative_monoid 2) and 5 refutations. Sealed at `lib/lain.rb:146`, the file's last
statement.

**`Timeline` is an element of the lattice, not the lattice.** `timeline.rb:30` is
`attr_reader :head_digest, :store`, and `:263` raises
`CrossStore, "cannot compare Timelines backed by different stores"` (class at `:28`). Both bottoms are
declared as **prose** because a bottom is store-relative:

    :159  meet_semilattice on: :meet, bottom: "the empty Timeline, per store"
    :185  not_a_meet_semilattice on: :causal_meets, because: <criss-cross fan-in ...>
    :225  meet_semilattice on: :dominator_meet, bottom: "the empty Timeline, per store (the virtual root, unnameable)"

`:26`'s `include Algebra::MeetSemilattice` carries the reason at `:23-25`: *"Granted here, claimed per
operation below: three meet-ish operators and only two of them are semilattices, so a bare `include`
naming nothing would be a lie about #causal_meets."*

**And two of the three are already store-bound objects taking head pairs:**

    timeline.rb:273  def initialize(store)        # already store-bound
    timeline.rb:281  def meets(head_a, head_b)    # already takes a head PAIR
    timeline.rb:329  def initialize(store)        # Dominators, same shape
    timeline.rb:337  def meet(head_a, head_b)

`#causal_meets` (`:178`) and `#dominator_meet` (`:215`, taking
`dominators: Dominators.new(store)`) are thin delegating wrappers over them. **The shape exists; it is
private, and the public API re-wraps it into an instance method.** Which is what forces the `on:`
keyword, the `CrossStore` runtime error, and the prose bottoms.

**Three independent lines converge on binding the store.** The inner classes above; the architectural
argument that a `Timeline` is `(head, store)`; and simplify-13's Rust trait design, which has
`type Ctx` (the store) and `type Elem` (the head) as **separate associated types**, derived from the
laws without reference to those inner classes.

**The context pipeline is one hardcoded line.** `context.rb:39-41`:

    def self.pipeline(workspace)
      Reminder.new(workspace:) >> CacheBreakpoints.new
    end

`Backend#context` (`cli/backend.rb:236`) passes no `pipeline:`. Construction sites for the advertised
combinators: **`Prune` 0, `DedupeToolCalls` 0, `PurgeFailedInputs` 0**; `Recall` 2 (both
`bench/sweep.rb:192`); **`Mailbox` 0 as of 2026-09-13** — it was 1, inside `Supervisor::TurnMailbox`,
itself constructed only in specs, and simplify-04's T11 deleted that class, so re-ground this line
before acting on it; `Compact` 2 (`plan/linear_rewrite.rb`, `bench/plan_sweep`). Of `context/`'s 714 code lines,
roughly **107 are reachable and always on**.

**And a swapped pipeline is silently dropped at every spawn boundary** — `Role#child_context`
(`role.rb:62`) and `Tool::SpawnPolicy` (`spawn_policy.rb:198`) both call `Context.new` omitting
`pipeline:`.

**An anonymous operation cannot be recorded either.** `SessionRecord.header`
(`session_record.rb:43-50`) is written once and its complete key set is `context_class`, `model`,
`max_tokens`, `system`, `stream`, `extra`, `head`, `tools`, `reminders`. **`context_class` reads
`"Lain::Context"` in every real run**, because the pipeline is an injected constructor argument rather
than a subclass — and `compaction/source.rb:589` swaps it **per turn**. So the record cannot say which
pipeline rendered a request. You cannot record what has no name, and you cannot select what has no
name: they are the same defect.

**Where docs and code disagreed.** `ARCHITECTURE.md:338-339` cites `Effect::Handler::Recorded` as a
deterministic-replay handler while its `from_journal` reads a `type: "tool_result"` record **nothing
in `lib/` writes** — so on any real journal it builds an empty map and silently falls through. T1
touches that class and should report it rather than fix it; it is a correctness finding, not a
simplification. `ARCHITECTURE.md:417-425` devotes a careful paragraph to two spawn postures' cache
economics and **`:handler_union` has zero production callers** — relevant to T2, which touches the
spawn chain.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb` (**including the
  `Algebra.registry.seal` at `:146`**), `lib/lain/effect.rb`, `lib/lain/middleware.rb`'s require
  block, `lib/lain/context.rb`'s require block, `lain.gemspec`, `.rubocop.yml`, `spec/spec_helper.rb`.
- **T3 and T4 both interact with the seal's position.** T4 moves where `meet_semilattice` is declared;
  T3 changes what the registry exposes. Neither may move the seal itself.
- This plan assumes **simplify-01 has landed** (T1 and T4 both produce objects over the current
  `Metrics/ClassLength`) and **simplify-03's T7 has landed** (T3 cannot remove the registry's
  production surface while `DerivationAudit` still reads it).
- **T4 must land before simplify-13.** Store-bound operation objects *are* the Rust seam; doing 13
  first means building a 42-site factory that T4 makes unnecessary.

## Open decisions

- **Whether `Effect::Handler` keeps the name.** After T1 it is one interface with three
  implementations, all interpreters. `Effect::Interpreter` would say that; renaming touches every
  construction site and the specs. T1 keeps the name and reports the option.
- **Whether the six `not_a_*` verbs go or the direct `.refute` does.** T3 drops the verbs because
  production already prefers `.refute` (3 sites to 2) and `elementwise.rb:111` sanctions it. The
  opposite choice — keep the verbs, forbid the direct call — is equally coherent and would make the
  registry's API smaller in a different direction. Panel decides; nothing is gated.
- **How far T5 goes.** It gives the pipeline a name, a catalog and a journal field. It does **not**
  enumerate combinator words for the bench — `ARCHITECTURE.md:1008` claims `bench sweep` does that and
  it is false, and making it true is a bench feature, not a naming one.

## Waves

Wave 1: T4
Wave 2: T1, T3 (←T4), T5
Wave 3: T2 (←T1)
Critical path: T4 → T3

**T3 and T4 both rewrite `lib/lain/timeline.rb`'s declaration block, and in the same wave each would have
destroyed the other's premise** — T3 removes the `not_a_*` verbs at `timeline.rb:185`; T4 moves all three
declarations off `Timeline` entirely. T4 goes first and T3 then prunes whatever declarations remain, which
is also the order T3's own escalation trigger asks for.

T4 is first on merit anyway: it is what simplify-13 waits on. T2 follows T1 because the gate chain it
deduplicates is made of the handlers T1 reshapes.

## Tasks

### T1 — Split `Effect::Handler` on the line between interpreting and decorating   [wave 2] [risk: high]

**Depends on:** none
**Files:** modify `lib/lain/effect/handler.rb`, `lib/lain/agent/tool_runner.rb`;
move `lib/lain/effect/handler/gate.rb`, `handler/sensitivity.rb`, `handler/summarizing.rb` and
`lib/lain/tools/subagent/refusing_handler.rb` into `lib/lain/middleware/`; modify
`lib/lain/cli/switchboard.rb`, `lib/lain/tools/subagent.rb`, `lib/lain/cli/wiring/board_build.rb`;
modify the corresponding spec files
**Reuse:** `Middleware::Stack` is the adverb mechanism and already holds
`RefuseSecretWrites`/`RedactSecretReads`/`WithholdSecretPaths` doing the same job on the result side.
`effect/handler.rb:16-18` already states the two shapes are the same.
**Shared-file wiring:** four `require_relative` moves between `lib/lain/effect.rb` and
`lib/lain/middleware.rb`, with the middleware entries placed after `Middleware::Base`
**Also in scope: `Effect::Handler::Recorded`, which three plans have now noticed and none has owned.**
`ARCHITECTURE.md:338-339` sells it as the deterministic-replay handler; it reads a record nothing in
`lib/` writes, so replay cannot work. simplify-03 and simplify-12 both record it and both say *report,
don't fix*. **This card is the one that has the file open** — it is deciding what `Effect::Handler`'s
remaining verbs are, and a verb that cannot function is exactly the question it is answering. Settle it:
either name the writer and wire it, or delete the handler and correct `ARCHITECTURE.md:338-339`. If the
answer is "a later chunk writes the record", that goes in this plan's **Open decisions** with the reason,
not in a third plan's grounding.

**Reachable from:** `ToolRunner#dispatch` reaches `agent/tool_runner.rb:414`, where the two mechanisms
meet, on every tool call; AC 4 drives a gated refusal through a `CLI::Wiring`-built stack

**Verbs terminate; adverbs decorate.** `Live`, `Mock` and `Recorded` interpret an effect — something
happens. `Gate`, `Sensitivity`, `Summarizing` and `Subagent::RefusingHandler` wrap, maybe
short-circuit, else pass downstream. The four move to `Middleware`.

`Handler` then loses `inner:`, `handles?`, the delegation triad, `to_app`, `UnhandledEffect`'s
chain-walk and `tool_named`'s chain-walk — becoming one `call(effect, context) -> Result` with three
implementations. **Two composition mechanisms become one inspectable, ordered `Stack`.**

Two forced workarounds disappear with it: `Gate#run` (`gate.rb:94-98`) and `Sensitivity#decline`
(`sensitivity.rb:97-101`) each re-implement the delegation `Handler#call` owned, and
`Sensitivity#perform`'s nil-branch (`:70-78`) exists only because `handles?` and `perform` can
straddle a board change.

**Answering `gate.rb:18-20`.** It argues `Gate` must read the tool off whatever `inner` resolves so
authorization is not decided against a different set than possession. Resolve the tool **once** in
`ToolRunner#dispatch` and put it in the env: gate and terminal handler then read the same object by
construction, which is stronger than a chain-walk. Note `ToolRunner` already holds a second
`@toolset` at `:186`, so today's design does not deliver that guarantee anyway.

**Acceptance criteria**

```gherkin
Scenario: a denied effect is refused before it is interpreted
  Given a stack whose gate denies a tool
  When that tool's effect is dispatched
  Then it is refused
  And no interpreter ran

Scenario: an allowed effect reaches the interpreter
  Given a stack whose gate allows a tool
  When that tool's effect is dispatched
  Then the interpreter ran
  And its result is returned

Scenario: the gate and the interpreter judge the same tool
  Given a stack whose gate allows one tool and denies another
  When an effect naming the allowed tool is dispatched
  Then the tool the gate judged is the tool that ran

Scenario: an effect no interpreter handles is refused by name
  Given a stack with a mock interpreter that handles nothing
  When an effect is dispatched
  Then it is refused, naming the effect

Scenario: the stack's order is inspectable
  Given a stack built by the wiring
  When its members are listed
  Then the adverbs appear before the interpreter, in declaration order
```
→ spec files: `spec/lain/effect/handler_spec.rb` (AC 2, AC 4), `spec/lain/middleware_spec.rb` (AC 5),
`spec/lain/cli/switchboard_spec.rb` (AC 1, AC 3)

**Escalation triggers**
- **AC 3 is the card's real gate.** It is `gate.rb:18-20`'s invariant restated as a test. If resolving
  the tool once in `ToolRunner#dispatch` cannot be made to serve both the gate and the interpreter,
  **stop** — the chain-walk exists for a reason and this card would be trading a real guarantee for a
  tidier shape.
- `Summarizing` is a handler that *rewrites a result*, not one that refuses. If it turns out to depend
  on `inner`'s return value in a way a middleware cannot express, it is neither verb nor adverb and
  needs its own argument.
- `ARCHITECTURE.md:338-339` calls `Recorded` a deterministic-replay handler, but its `from_journal`
  reads `type: "tool_result"` — **a top-level record type nothing in `lib/` writes** — so it builds an
  empty map and silently falls through. **Report this; do not fix it here.** It is a correctness
  finding and fixing it inside a refactor would hide it.
- `spec/lain/effect/handler_spec.rb` mentions `Tool::ContractViolation` three times, and
  `effect/handler/live.rb:78-80` special-cases it in a comment. If moving the adverbs changes which
  layer catches it, the message a user sees changes.
- If the four moved classes need anything from `Effect` that `Middleware` cannot see, the split is in
  the wrong place — report the dependency rather than adding a bridge.

### T2 — One place an agent's handler chain is wired   [wave 3] [risk: medium]

**Depends on:** T1
**Files:** modify `lib/lain/tools/subagent.rb`, `lib/lain/cli/switchboard.rb`,
`lib/lain/cli/wiring/agent_build.rb`; modify `spec/lain/tools/subagent_gate_spec.rb`,
`spec/lain/cli/switchboard_spec.rb`
**Reuse:** the `Seam` already carries `sensitivity`, `gate_policy`, `denial` and `journal` — the exact
four ingredients `Switchboard` holds
**Shared-file wiring:** none
**Reachable from:** `ChildBuilder#gated` is on the spawn path from `Tools::Subagent#call`; AC 3 drives
a real spawn and compares the child's chain with the parent's

`Tools::Subagent::ChildBuilder#gated` (`subagent.rb:1442-1448`) and `CLI::Switchboard#gate`
(`switchboard.rb:213-218`) build **the same `Sensitivity -> Gate -> inner` chain from the same four
ingredients**, differing only in `denial` (a thunk called once per child chain versus a method) and in
keyword order. `spawn_agent` (`subagent.rb:1362-1370`) likewise duplicates
`CLI::Wiring::AgentBuild.build` (`agent_build.rb:44-55`).

**Have the `Seam` carry the gate *builder* instead of its ingredients.** `#gated` and three `Seam`
members disappear, and there is one place an agent's chain is wired — which removes a class of drift
where a child could be gated differently from its parent.

Sequenced after T1 because the collapse changes what the chain is *made of*.

**Acceptance criteria**

```gherkin
Scenario: a child is gated by the same policy as its parent
  Given a parent whose gate denies a tool
  When it spawns a child
  Then the child's gate denies that tool

Scenario: a child's denial message is its own
  Given a parent and a spawned child
  When each refuses the same tool
  Then the child's refusal names the child

Scenario: parent and child chains are built by one builder
  Given a spawn
  When the parent's chain and the child's are compared
  Then both were built by the same builder

Scenario: a child spawned with no gate policy is refused
  When a spawn seam is built with no gate policy
  Then construction is refused
```
→ spec files: `spec/lain/tools/subagent_gate_spec.rb` (AC 1-3),
`spec/lain/tools/subagent_spec.rb` (AC 4)

**Escalation triggers**
- The `Seam` has **14 members** and `denial` is currently a **thunk** on the subagent side
  (`@seam.denial.call`) and a **method** on the switchboard side. If the builder cannot accept both
  without a conditional, one of the two call shapes is wrong — find which before adding a branch.
- `ARCHITECTURE.md:417-425` argues the cache economics of two spawn postures, and **`:handler_union`
  has zero production callers** — only `:schema` runs. If this card's builder makes the union posture
  reachable or unreachable, say so; a posture that silently cannot be selected is the same defect
  class this plan is about.
- `agent_build.build` passes `snapshot_slot:` and `spawn_agent` does not. If unifying the two makes a
  subagent acquire a snapshot slot it never had, that is a behaviour change with real cost — report
  it rather than accepting it as tidiness.
- simplify-04's T12 moves `Subagent::Leases` out of this file. If both are in flight, coordinate — they
  touch adjacent regions of a 1,461-line file.

### T3 — Trim the registry to what it is for   [wave 2] [risk: low]

**Depends on:** T4
**Files:** modify `lib/lain/algebra.rb`, `lib/lain/algebra/monoid.rb`,
`algebra/commutative_monoid.rb`, `algebra/meet_semilattice.rb`, `algebra/attenuation.rb`,
`algebra/pure.rb`, `algebra/elementwise.rb`, `lib/lain/timeline.rb`,
`lib/lain/context/purge_failed_inputs.rb`, `lib/lain/compaction/strategy/summarizing.rb`;
modify `spec/algebra_laws_spec.rb`
**Reuse:** `Algebra.registry.refute` is the path production already prefers (3 sites to 2), and
`algebra/elementwise.rb:111` documents it as sanctioned
**Shared-file wiring:** none — the seal at `lib/lain.rb:146` is unchanged
**Reachable from:** the registry is filed by class bodies at load and swept by
`spec/algebra_laws_spec.rb`; after this card it has **no production reader**, which AC 3 asserts

Two removals:

1. **The production query surface.** `declares?` and `refutations` exist for one consumer,
   `Compaction::DerivationAudit` (`:277`, `:283`), which simplify-03's T7 deletes. After that the
   registry is a load-time collection one spec walks — it no longer needs to be a runtime-queryable
   global, and saying so is most of the simplification.
2. **One of the two refutation paths.** Six `not_a_*` verbs exist; only `not_a_meet_semilattice` is
   used (2 entries at `timeline.rb:185`). The other three refutations go through
   `Algebra.registry.refute` directly. **Twelve verbs for five entries** — drop the verbs, keep
   `.refute` with its mandatory reason.

**Keep the registry and the seal.** The per-operation granularity is the whole point: `Timeline` has
three meet-ish operations and only two are semilattices, so `is_a?` cannot be the classification while
the claim attaches to a class. (T4 changes that premise — see its note.)

**Acceptance criteria**

```gherkin
Scenario: the registry has no production reader
  When the library is searched for calls to the registry's query methods
  Then none is found

Scenario: a refutation is filed with its reason
  Given an operation refuted with a stated reason
  When the registry's refutations are enumerated
  Then that operation appears with its reason

Scenario: a refutation without a reason is refused
  When an operation is refuted with no reason
  Then it is refused

Scenario: the law sweep still holds every claim to its laws
  When the algebra law sweep runs
  Then every filed claim was exercised

Scenario: a claim filed after the seal is refused
  Given the registry is sealed
  When a further claim is filed
  Then it is refused
```
→ spec file: `spec/algebra_laws_spec.rb` (AC 2-5, all existing behaviour that must stay green); AC 1 is
a reachability assertion recorded in the commit message

**Escalation triggers**
- **If simplify-03's T7 has not landed, `DerivationAudit` still reads the registry** and this card
  cannot remove the query surface. Check first; removing it under a live reader is a `NoMethodError`
  on the compaction path.
- **simplify-02's T5 adds a third `not_a_meet_semilattice` call** (on `:causal_meets`, as part of the
  Rust-divergence fix). If 02 has landed, this card converts **three** refutations to direct
  `.refute` calls, not two — count them at the time rather than trusting this plan's figure.
- `algebra/elementwise.rb:111`'s message tells an author to *"include the module and call
  `Algebra.registry.refute` directly"*. If dropping the `not_a_*` verbs makes that message wrong for
  some module, fix the message in the same commit.
- `Elementwise` is documented as the **exception** where `include` asserts something rather than
  granting vocabulary. Do not fold it into the same shape as the other five without reading why.
- T4 changes whether per-operation granularity is still needed. **If T4 lands first**, three of the
  five `meet_semilattice` claims move onto operation objects where `is_a?` *is* the classification —
  which shrinks this card's premise. Read T4's note before assuming the registry's rationale is
  unchanged.

### T4 — Take the three meets off the element and bind them to the store   [wave 1] [risk: high]

**Depends on:** none
**Files:** modify `lib/lain/timeline.rb`; create `lib/lain/dag/render_meet.rb`,
`dag/dominance_meet.rb`, `dag/causal_meets.rb` (or one file — the card chooses and says why);
modify `lib/lain/ledger.rb`, `lib/lain/cli/command/pin.rb`, `lib/lain/cli/command/rewind.rb`,
`lib/lain/cli/goal_driver.rb`, `lib/lain/session_record/scribe.rb`,
`lib/lain/tools/subagent/turn_feed.rb`; modify `spec/lain/timeline_spec.rb`,
`spec/support/algebra_generators.rb`
**Reuse:** **the operation objects already exist, privately** — `timeline.rb:273-281` is store-bound
and takes a head pair, and `:329-337` (`Dominators`) has the same shape. This card promotes them
rather than writing them.
**Shared-file wiring:** manifest lines in `lib/lain.rb` placed **before** `timeline` and **before**
the `Algebra.registry.seal` at `:146`
**Reachable from:** `Ledger#unique_turns` (`ledger.rb:105-111`) and seven other `lib/` sites walk a
timeline; `Timeline#meet` is reached from the compaction and fork paths. AC 1 drives a real
`Ledger`; AC 4 drives a fork.

`Timeline` is `(head_digest, store)` — an **element** of the lattice. The lattice is "heads within one
store", which is why `:263` raises `CrossStore` and why both bottoms are **prose** rather than values.

Make each operation a store-bound object taking two heads — `RenderMeet.new(store).call(head_a, head_b)`
— and three things fall out:

1. **`CrossStore` becomes unrepresentable.** The store is bound once; both operands are heads in it.
   An error class deleted **by construction**, which is the move this codebase already prizes.
2. **The bottom becomes a value**, `nil`, within the bound store. So
   `Algebra::MeetSemilattice.refuse_unnamed_bottom` and the prose-bottom apparatus have nothing left
   to do.
3. **`is_a?` becomes the classification.** `CausalMeets` omits the module; `RenderMeet` and
   `DominanceMeet` carry it truthfully. No `on:` keyword, no `(subject, operation)` tuples for these
   three — which is three of the registry's five `meet_semilattice` claims.

`Timeline` **stays** — callers still want the ergonomic pair for `#commit`, `#ancestors`, `#fork`. Only
the three binary operations move out, and they are the part that never belonged on an element.

**This card gates simplify-13.** Store-bound operation objects *are* the Rust seam: swapping
`Dag::RenderMeet` for a Rust-backed one is a line in a catalog, not a 42-site refactor.

**Acceptance criteria**

```gherkin
Scenario: a meet of two heads in one store is their greatest common ancestor
  Given a store with two heads sharing a prefix
  When the render meet is taken
  Then it is the last shared commit

Scenario: a meet with the empty head is the empty head
  Given a store with one head
  When the render meet of that head and nothing is taken
  Then nothing comes back

Scenario: heads from two stores are refused by name
  Given two heads belonging to different stores
  When a meet is attempted across them
  Then it is refused, naming the two stores

Scenario: a fork still finds its divergence point
  Given a timeline forked and both branches extended
  When their divergence is asked for
  Then the last shared commit is named

Scenario: the causal operator makes no semilattice claim
  When the algebra registry is enumerated
  Then the causal operator is refuted with its reason
  And the two meets are claimed
```
→ spec files: `spec/lain/dag/render_meet_spec.rb`, `dag/dominance_meet_spec.rb` (AC 1, AC 2, AC 3),
`spec/lain/timeline_spec.rb` (AC 4), `spec/algebra_laws_spec.rb` (AC 5).

**AC 3 is a runtime assertion, and an earlier draft of this card got that wrong.** It said the
cross-store case became "impossible to express" and needed no example. It does not: Ruby will happily
pass a head from one store to an operation bound to another, and what changes is only *which* error
comes back. Today it is `Timeline::CrossStore`, raised deliberately and asserted **by name in seven
places** — `spec/lain/timeline_spec.rb:185`, `:299`, `:350`; `spec/lain/rust/dominator_meet_spec.rb:135`,
`:176`; `spec/lain/rust/causal_meets_spec.rb:169`; and `spec/lain/rust/store_spec.rb:120`, which asserts
`Lain::Ext::Timeline::CrossStore.ancestors` includes `Lain::Error`. Delete the class and those become a
`NoMethodError` or a nil digest — a worse message, arriving further from the cause, and the Rust side
keeps raising the old one either way.

So the card **keeps a named refusal on the operation object** and moves those seven assertions to it,
rather than deleting the concept. Two further sites reason about it in prose and must be re-read, not
just re-pointed: `spec/lain/algebra_spec.rb:202` and `timeline_spec.rb:538` both explain that a
*stored* bottom would raise against every real operand, which is why `Algebra`'s identity element is
what it is — and `spec/support/algebra_generators.rb:15` builds its generators on the same fact.
**`CrossStore` disappearing from `Timeline` is a rename, not a deletion**, and the Intent's "deletes
`CrossStore` by construction" overstates it: what construction deletes is the *class of bug*, because
an operation bound to a store cannot be handed the wrong store's head without saying so.

**Escalation triggers**
- **`CrossStore` may be rescued somewhere.** Deleting an error class by construction is only sound if
  nothing catches it. Grep `lib/` and `spec/` before removing it; a rescue site means some caller
  *does* pass cross-store heads and the design is not as clean as it looks.
- The two inner classes are **private**. If promoting them exposes a method that was private for a
  reason — `Dominators` builds a dominator tree and may be expensive to construct — the public object
  needs a memoization story that the private one got for free by being built per call.
- `ledger.rb:109` passes a **block** to `#ancestors`, and simplify-02's T4 fixes the Rust side of
  exactly that. If T4 here changes `#ancestors`' shape too, the two cards collide — this card should
  **not** touch `#ancestors`.
- `spec/support/algebra_generators.rb` supplies the law groups' populations, and
  `spec/algebra_laws_spec.rb:163` warns that Timeline's generator *"would mint a fresh Store each
  time"*. A store-bound operation makes that cheaper, but if the generator must change shape, report
  it — the law groups are the only thing holding these operations to their laws.
- If `Timeline#meet`'s callers turn out to want the *timeline* back rather than a head, the operation
  object returns the wrong type and the ergonomic wrapper must stay. Check the five call sites first.

### T5 — Give the context pipeline a name, a resolver, and a journal field   [wave 2] [risk: medium]

**Depends on:** none
**Files:** create `lib/lain/cli/context_pipeline.rb`, `spec/lain/cli/context_pipeline_spec.rb`;
modify `lib/lain/context.rb`, `lib/lain/cli/backend.rb`, `lib/lain/session_record.rb`,
`lib/lain/role.rb`, `lib/lain/tool/spawn_policy.rb`, `exe/lain`
**Reuse:** **`CLI::CompactionStrategy`** (`cli/compaction_strategy.rb`) is the working precedent and
should be copied closely: one authority constant (`:120`), help text derived from it so it cannot
drift, `+` composition through a declared monoid, **no Thor default** (`exe/lain:817-826`) so the
unset state stays reachable as the control arm, and loud refusal on a typo. The context axis already
has `Combinator#>>` and the same monoid machinery.
**Shared-file wiring:** `require_relative "cli/context_pipeline"` in `lib/lain/cli.rb`; a
`--context-pipeline` `method_option` on `chat` in `exe/lain`
**Reachable from:** `Backend#context` (`cli/backend.rb:236`) builds the `Context` every turn renders
through; AC 1 drives `lain chat --context-pipeline` and AC 3 reads the session record it wrote

Three parts, and the third is why this card is in *this* plan rather than a bench one:

1. **A named pipeline and a resolver.** `Context.pipeline` (`:39-41`) is one hardcoded line and
   `Backend#context` passes no `pipeline:`. Give the compositions names and resolve them the way
   `--compact-strategy` resolves strategies.
2. **Thread it through the spawn boundary.** `Role#child_context` (`role.rb:62`) and
   `Tool::SpawnPolicy` (`spawn_policy.rb:198`) both call `Context.new` **omitting `pipeline:`**, so a
   swapped pipeline is silently dropped at every spawn.
   **And `Context::REQUIRES` (`context.rb:48`) is `pipeline(Workspace.empty).requires`, computed at load
   time from the hardcoded composition.** Once the pipeline is selectable, that constant is a snapshot of
   one pipeline being read as though it described all of them — `context.rb:37` says it exists so
   `#render` and `REQUIRES` share a single source, which is exactly the invariant selection breaks. This
   card owns it: either `REQUIRES` becomes a query on the resolved pipeline, or the comment at `:76`
   (*"never shortcut to the REQUIRES constant"*) becomes the rule for every reader and the constant goes.
   No other plan in the series touches it.
3. **Journal the name.** `SessionRecord.header`'s `context_class` reads `"Lain::Context"` in every real
   run, because the pipeline is an anonymous constructor argument. A named pipeline can be recorded —
   and `compaction/source.rb:589` swaps it **per turn**, so the header alone may not be enough; the
   card says whether a per-turn record is needed.

**This closes both halves of one defect.** You cannot record what has no name, and you cannot select
what has no name.

Note three combinators — `Prune`, `DedupeToolCalls`, `PurgeFailedInputs` — have **zero construction
sites anywhere**. Naming them makes them selectable for the first time; whether they *work* is
unknown, and AC 5 is the honest minimum.

**Acceptance criteria**

```gherkin
Scenario: the default pipeline is unchanged when no pipeline is named
  Given no pipeline flag
  When a chat's context is built
  Then it renders the reminder and the cache breakpoints

Scenario: a named pipeline is used
  Given a pipeline named on the command line
  When a chat's context is built
  Then that pipeline renders the request

Scenario: the session record names the pipeline that rendered
  Given a chat launched with a named pipeline
  When its session record header is read
  Then it names that pipeline

Scenario: a subagent inherits its parent's pipeline
  Given a parent whose pipeline is named
  When it spawns a child
  Then the child renders through the same pipeline

Scenario: an unknown pipeline name is refused
  Given a pipeline name that does not exist
  When a chat is launched
  Then it is refused
  And the refusal lists the pipelines that exist

Scenario: a previously unconstructed combinator can be named and runs
  Given a pipeline naming the prune combinator
  When a request is rendered
  Then it renders without error
```
→ spec files: `spec/lain/cli/context_pipeline_spec.rb` (AC 1, AC 2, AC 5, AC 6),
`spec/lain/session_record_spec.rb` (AC 3), `spec/lain/tool/spawn_policy_spec.rb` (AC 4)

**Escalation triggers**
- **AC 6 is a discovery, not a regression test.** `Prune`, `DedupeToolCalls` and `PurgeFailedInputs`
  have never been constructed in production or in the bench. If naming one raises, that is its first
  execution — report what broke rather than fixing it inside this card, because a combinator that has
  never run may need real work.
- `compaction/source.rb:589` swaps the pipeline **per turn**. If the journal field records only the
  launch-time name, it will be wrong for any run that compacts — which is most long runs. Decide
  whether the record is per-run or per-turn and say why; a field that is right at launch and stale
  after is worse than none.
- `Context#render` is documented as **pure**, and purity is the same constraint as cache-hit. If a
  named pipeline's resolution reads the clock or the filesystem at render time, that breaks the
  property `ARCHITECTURE.md` rests the cache story on. Resolve at construction, never at render.
- `Role#child_context` and `Tool::SpawnPolicy` omitting `pipeline:` may be **deliberate** — a subagent
  arguably should not inherit a parent's experimental pipeline. If there is a comment saying so, AC 4
  is wrong and the card should invert it. Read both sites before assuming the omission is a bug.
- `exe/lain:817-826` deliberately gives `--compact-strategy` **no default** so the unset state is the
  control arm. Copy that; a defaulted `--context-pipeline` would make the control unreachable, which is
  the mistake that flag's comment exists to prevent.

## Integration checks

After the last wave:

- `bundle exec rake pspec` green, **with the example count recorded**. T1 and T4 both move examples
  between files; write the arithmetic.
- `bundle exec rubocop` clean with no new `rubocop:disable`.
- **`bundle exec rspec spec/algebra_laws_spec.rb spec/lain/dag spec/lain/timeline_spec.rb`** as a
  focused algebra run. T3 and T4 both touch what the registry holds, and the law sweep is the only
  thing that holds the meets to their laws.
- `bundle exec rspec spec/lain/effect spec/lain/middleware spec/lain/cli/tool_guard_spec.rb spec/lain/tools/subagent_gate_spec.rb`
  as a focused chain run for T1 and T2.
- **Verify `CrossStore` is gone and nothing rescued it.** T4's claim is that an error class became
  unrepresentable; grep for the constant across `lib/` and `spec/` and record that the count is zero.
- **Read one session record header** written by a chat launched with `--context-pipeline`. T5's third
  part is the one that serves the mandate, and a field that is present but wrong is worse than absent.
- **Manual, human:** one `lain chat` with a tool denied by policy, confirming T1's split still refuses
  before interpreting, and one `/mode plan` flip confirming the posture still attenuates. The handler
  chain is the security boundary and its specs use doubles at several layers.
- **Manual, human:** one spawn with a named pipeline, confirming the child inherits it (T5's AC 4) — or
  confirming it deliberately does not, if the card inverted that AC.
- Update `planning/qa/scenarios/` for the new `--context-pipeline` flag and any changed refusal
  sentence from T1's collapse.
