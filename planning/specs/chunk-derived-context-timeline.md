# The derived context timeline

status: done — all 11 cards landed 2026-07-27, `9408192`..`acc7b2f`
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman · Aaron Patterson
(Ruby roster, `create-plan/references/rosters.md`)
requires: `planning/specs/chunk-algebra-vocabulary.md` landed first — T3 needs its
`Algebra::Elementwise` and `Algebra::Pure`.

## Intent

Compaction today is a **render-time projection**: `Context::Compact` rewrites the message array
inside `Context#render` and the result is never materialized, never addressable, never diffable.
This chunk makes the compacted view a **second lineage** — a derived `Timeline` in the same
content-addressed `Store`, whose summary events name the source events they subsume via
`causal_parents`. The session timeline stays the lossless record; the derived chain is what the
provider sees. That turns compaction from a behavior into a comparable artifact, which is the
bench's whole premise applied one level up.

Two things force the shape. First, **the derivation needs a pluggable strategy seam**, not one
hardcoded summarizer: collapsing a span by asking a model, dropping it to an attested elision,
and collapsing a finished plan step to a deterministic marker are three different policies over
one span, and they should be swappable and comparable like every other axis. Second, **probes found the shipped compacting render is Anthropic-invalid** (§ Grounding F1–F3),
so this chunk carries a correctness fix and the derivation inherits its validator. Be precise about
where that risk sits: T4 fixes `Context::Compact`, which after T9 is off the production render path
and used only by `bench/plan_sweep/driver.rb:157` — so **T9's validity AC is the live fix** and T4's
is the bench arm's. Both are worth doing; only one is urgent.

Satisfies ROADMAP:234-237 (the Context-as-IVM lens, promoted from implementation guidance to a
materialized artifact) and discharges follow-up 2 of
`chunk-compaction-tiers-pins-isolation.md` (the deferred span summarizer) — its "a span's
boundaries move every turn, so its cache key and invalidation are unsolved" objection is
answered by F4: a derived chain has a content address, and `to_a` does not follow causal edges.

**Prerequisite: `planning/specs/chunk-algebra-vocabulary.md` must land first.** That chunk names
lain's algebraic structures as modules in `lib/`, declares the three it already maintains, and applies
the vocabulary to the two combinators that already analyze-then-map. This chunk consumes two of its
modules — `Algebra::Elementwise` and `Algebra::Pure` — in T3's strategy seam, and inherits its
reasoning about why homomorphism is structural rather than asserted. Nothing else here depends on it.

**Explicitly out of scope**, recorded so it does not creep: hierarchical (recursive) derivation,
the plan-step strategy, exchange-level reordering, and retiring `Context::Compact`. The algebra
vocabulary itself, its Rust half, and the `Regular` / `Store` / `Canonical` declarations all belong to
the prerequisite chunk. See Follow-ups.

## Grounding

Verified **2026-07-27** against `main` at `5665f14` by four parallel `Explore` passes plus four
ephemeral probes (`probe_compact.rb`, `probe_render.rb`, `probe_lineage.rb`, `probe_cost.rb`, run
under ruby-4.0.5). Code is source of truth; where a doc disagreed, the code won and the
disagreement is recorded.

### F1 — The shipped compacting render produces an Anthropic-invalid request

Measured at the **composed** production pipeline (`Compact >> Reminder >> CacheBreakpoints`,
`Scheduler::COMPOSE`'s order, `scheduler.rb:187-191`), rendering a real 41-event Timeline through
`Context#render` and reading `Request#messages`:

| config | msgs | `messages[0].role` | alternation violations |
|---|---|---|---|
| uncompacted | 41 | user | none |
| **compacted, `keep_last: 20` (the shipped default)** | 21 | **assistant** | **`0->1` both assistant** |
| compacted, `keep_last: 21` | 22 | **assistant** | none |

Two independent 400 conditions. `Compact#call` returns
`protected_head + [summary(assistant)] + tail` (`context/compact.rb:66`); with no pins
`protected_head` is empty, so **`messages[0]` is the assistant summary at every `keep_last`**.
With an **even** `keep_last` over an alternating history ending on the user's newest turn the tail
also begins assistant, so the summary is followed by another assistant. `--compact-keep` defaults
to 20 (`cli/backend.rb:76`).

Nothing downstream rescues it. `AnthropicEncoding#encode_messages`
(`provider/anthropic_encoding.rb:179-183`) is a pure 1:1 map. The render pipeline has **no**
role-alternation check, **no** first-message-is-user check, **no** tool-pair validation, and **no**
empty-content refusal — verified by grep and confirmed by the exploration pass. `Event::ROLES`
validation happens at *commit* (`event.rb:52-56`) and `Compact` writes the literal `"assistant"`
without going through `normalize_role` (`compact.rb:64`).

Why it was never caught: compaction is on by default (`backend.rb:254`) but integration specs are
opt-in and cost money; `spec/lain/context/compact_spec.rb` (66 lines) never mentions roles,
alternation, or orphans; and the owed manual pass 3 from
`chunk-compaction-tiers-pins-isolation.md` has not been run. `spec/lain/agent_spec.rb:407-410`
pins `%w[user assistant user user]` as *expected* output, so consecutive same-role is treated as
ordinary elsewhere in the suite — see T1's escalation trigger.

### F2 — `keep_last` splits tool_use/tool_result pairs

`keep_last: 20` over a tool-heavy history leaves an **orphan `tool_result`** whose answering
`tool_use` was summarized away (`toolu_0` at 5 rounds, `toolu_1` at 6). `Context::DedupeToolCalls`
already reasons about this invariant (`dedupe_tool_calls.rb:5-9`) — in a combinator with **no
production caller**. `Agent#perform_tools` commits one user message per assistant turn's
tool_results ("Correctness gate 2", `agent.rb:326-328`), so the pair is always exactly two
adjacent messages.

### F3 — The protected/pinned hoist destroys reading order

A pinned message at index 10 of 41 lands at index **0** after compaction, losing its predecessor
entirely. `partition` (`compact.rb:59`) hoists every protected message to the front.
`Context::Prune` is order-preserving by contrast (`prune.rb:57` sorts indices); `Compact` is not.

### F4 — `to_a` follows `render_parent` only, so the derived design is viable

`Event` carries **both** a single `render_parent` and a sorted, frozen set of `causal_parents`
(`event.rb:37-38`, `:170-172`). A derived chain whose summary event named all 4 source digests as
`causal_parents` walked to **2 turns, not 6**; `to_a` never reached a source digest.
`ancestor_digests` and `ancestors` are likewise render-only (`timeline.rb:91-100`). So a summary
event can record exactly what it subsumes **without** the render walking the turns it replaced,
and a causal fan-in creates **no** usage double-count: `Ledger#unique_turns`
(`ledger.rb:115-119`) walks `timeline.ancestors`, i.e. render ancestry only.

`causal_parents` is folded into the envelope digest directly (`event.rb:101`) and pre-sorted so
element order cannot leak into identity (`event.rb:89-94`). **The fan-in precedent already
exists**: `Arm::Synthesis` commits an assistant turn naming every worker head as a causal parent
(`arm/synthesis.rb:55`, `:66`), pinned at `spec/lain/arm/synthesis_spec.rb:38`, and it raises
rather than committing a dangling causal edge (`:77`).

### F5 — There is **no** structural sharing, and the derivation is cheap anyway

A first pass at this claimed the derived chain shares its prefix with the source. **That was
wrong**, and the panel caught it. `Event#payload` folds `render_parent` (`event.rb:100`), so a
retained turn re-committed under a new parent chain gets a **different digest** — measured
directly: identical role and content under a different parent produced a different address. So
there is no sharing between source and derived, and none between successive derived chains
either. The earlier probe measured `fork` + append (the *same* parent chain), which is not the
derivation case.

What saves it is that **the derived chain is bounded by `keep_last` + the number of ranges, not by
history length.** It holds the replacement events plus the retained tail — nothing else. Measured
at `keep_last: 20`:

| source history | derived chain length | objects written per derivation | full derivation | `Compact#call` projection (today, per turn) |
|---|---|---|---|---|
| 50 | 21 | 22 | 0.806 ms | 0.402 ms |
| 200 | 21 | 22 | 1.215 ms | 2.875 ms |
| 800 | 21 | 22 | **1.739 ms** | **10.579 ms** |

So a **full re-derivation every turn** is constant in history length (~22 objects), while the
projection it replaces is O(n) because it re-dumps the whole history through `Canonical.dump`
(5.4 ms alone at n=800). The derivation is ~2× *worse* at 50 messages and ~6× *better* at 800.

Three consequences the cards depend on:

1. **No incremental extension is needed or possible.** Derive fully, every compacting turn. This
   is simpler than the alternative and it is what the non-recursive ruling implies anyway.
2. **The cost of the artifact is store growth, not time**: ~22 objects per derivation, never
   reused, in an in-memory Hash (`store.rb:19`). Bounded and small, but it is the honest price and
   T5 records it.
3. The `im`/`rpds` HAMT binding is **not** retired by this chunk — the earlier draft claimed it
   was. No Rust work is in scope, and the binding stays as latent as `CLAUDE.md` says.

Also measured, and now an AC: deriving into a **fresh** Store raises, because the summary's
causal edges name source digests that store does not hold (`store.rb:84-89`). The derived chain
must be built in the source's Store.

### F6 — `Compaction::Prepared` is the artifact, almost, and has no production caller

`Compaction::Prepared` (`compaction/prepared.rb:45`) already memoizes a computed compaction keyed
by head digest (`Held = Data.define(:head_digest, :messages)`, `:51`), journals
`CompactionPrepared` (`:58-60`), and substitutes it into the pipeline through a
`Replay < Context::Combinator` whose `call(_messages) = @messages` (`:138-146`). It has **no
production caller** — grep finds no `Prepared.new` outside `spec/lain/compaction/prepared_spec.rb`.

**But it cannot be reused as-is, and the first draft wrongly said it should be.** `Replay` is
`private_constant` (`prepared.rb:147`), so `Source` cannot reach it; and `Prepared#initialize`
takes `compact:` and computes the compaction itself from a `Context::Combinator` (`:68-72`,
`:100`), which is the wrong collaborator for a derived projection. T9 therefore writes its own
one-line replay combinator, and **reconciling or retiring `Prepared` is a follow-up**, not a card
here — no card in this chunk touches `compaction/prepared.rb` or its spec.

### F7 — Naming and wiring drift worth knowing

- `Lain::Turn` **was deleted** (`61f7e81`); the unit is `Lain::Event`, kind-tagged `:turn`, with
  `KINDS = %i[turn spawn message snapshot]` (`event.rb:27`) — a `:snapshot` kind already exists.
  `spec/lain/event_spec.rb:16` asserts no `Lain::Turn` constant remains. **CLAUDE.md and
  `~/.claude/plans/jiggly-greeting-avalanche.md` still say `Turn`** — code won; the docs card fixes
  CLAUDE.md.
- `Timeline#commit(role:, content:, meta: {}, causal_parents: [])` takes kwargs, not an Event.
- `Head.from_timeline` has **no production caller** (`Source#decide` uses `Head.new`);
  `Need::Manual` has no production caller; `Prune`, `DedupeToolCalls`, and
  `PurgeFailedInputs` are **unwired in production**. Two near-misses, corrected after panel review:
  `Context::Mailbox` *does* have a production caller (`supervisor.rb:329`), and `Context::Recall` has
  a bench one (`bench/sweep.rb:189`) — neither is in the chat render pipeline, which is a weaker
  claim than "unwired".
- `Capability::Policy#resolve` is **never called** in `lib/` or `exe/` (`backend.rb:47` comment only).
- Production's DAG is 100% pure Ruby. `Lain::Ext::{Turn,Store,Timeline}` exist in Rust but are
  referenced only from `spec/lain/rust/*`; only `Ext.blake3_hex` is a production dependency
  (`canonical.rb:60`).
- **`Oracle::Recorded.from_journal` replays `oracle_answer` records keyed `(oracle_digest,
  question)`** (`oracle/recorded.rb:47-49`). This is what makes "journal the edge, re-derive"
  exact for a model-backed strategy — see the Open decisions ruling.
- Nothing reads a `compaction` record back (`Ledger` reads `turn_usage` only), so a new
  derivation record needs its own reader if it is to be more than a write-only trace.
- The per-turn seam is `Agent::PipelineSource#context_for(base:, timeline:, usage:, session:)`
  (`agent/pipeline_source.rb:17`), called at `agent.rb:302-306`. `Context#render(timeline:)`
  takes the timeline as an **argument from the Agent**, so a derived chain cannot be rendered by
  handing the Context a different timeline — it is substituted as *messages*, via `Replay`.

### F8 — The algebra, in brief (full derivation: the prerequisite chunk's F8)

`#collapse` maps into the free monoid on messages and `DROP` is its unit. By the universal property of
the free monoid, **a strategy is a monoid homomorphism iff it is elementwise** — which is why
`Algebra::Elementwise` makes the property structural rather than asserted. Purity is a second,
genuinely orthogonal axis, and the 2x2 is fully populated:

| | pure | not pure |
|---|---|---|
| **elementwise** | `Strategy::Elide` (T7) | per-message model summarization — the shape `Oracle::Eager` already has |
| **not elementwise** | whole-span deterministic shapes: keep-first-and-last, a message tally | the model span summarizer (T6); the plan-step collapse (follow-up 2) |

The axes gate different guards: `Elementwise` gates **recursion safety** (follow-up 1 refuses anything
else), `Pure` gates **whether the journalled edge alone suffices to re-derive** — which is why T8's
drift diagnosis differs by cell. Every practical consequence for T6 follows from its being
non-homomorphic: the content-address key, the mandated recorded oracle, and the drift under
hierarchical composition.

Two facts specific to this chunk. **The derivation is not a functor on the prefix order** — `T1 <= T2`
does not imply `derive(T1) <= derive(T2)`, because `render_parent` is inside the digest
(`event.rb:100`) and the `keep_last` window slides. That is F5 restated exactly: the failure of
structural sharing *is* the failure of functoriality, and it bounds the ROADMAP's Context-as-IVM
framing to messages rather than addresses. And **`causal_parents` is the fiber of the collapse** — a
replacement event's causal set is its preimage, which is why T8 can audit it, why the pre/post mapping
needs no separate storage, and why `Strategy` must not be a bare `#call(messages) -> messages`
endomorphism: that loses the preimage.

`#ranges` returns an **interval partition**, so its three validation ACs (inside the span,
non-overlapping, ascending) are well-formedness conditions rather than style rules, and a pin is a
**cut point** rather than a shield — which is why pins produce N ranges.

**What there is not.** No adjunction and no retraction: losslessness here is a *storage* property (the
session timeline is still there), not an algebraic one. And `causal_meets` stays a poset, not a
lattice — it already lacked a unique greatest lower bound on criss-cross fan-in
(`timeline.rb:143-152`) and derived chains add more fan-in elements. Render `meet` is untouched,
because a derived root meets the source at the empty timeline.

## Staleness check — absorbed divergences (orchestrator, 2026-07-27, `b6866da`)

The prerequisite chunk landed (`d121116`, `9a95095`, `94ac1df`, `b6866da`), but it shipped a
**stricter and differently-shaped** vocabulary than T3/T6/T7 were written against. Nothing below
invalidates a card's intent; all six are absorbed, and every one of them is an instruction to an
implementer rather than a note.

**D1 — `Algebra::Elementwise` is a declaration DSL, not a `#collapse_one` template.** The shipped
form is `elementwise on: <span op>, each: <per-element op>, given: <analysis>`, and it *generates*
`on` as `span.flat_map { send(each, element[, analysis]) }` — so the declared operation returns an
**Array**, it refuses to overwrite a method the class wrote itself (`Algebra::Occupied`), and the
declaration must sit **below** the helpers it names. Consequence: `#collapse(messages) -> Replacement`
cannot itself be the generated method. **Ruling:** the elementwise declaration goes on a
block-producing span operation — the free monoid on **content blocks**, which is exactly F8's
`#collapse` maps into the free monoid — and `#collapse` wraps that Array in a `Replacement`.
`is_a?(Elementwise)` still classifies, and the registry entry names the block operation.

**D2 — `not_elementwise` raises `Contradiction` by design.** Recording the elementwise negative (T6)
is `Algebra.registry.refute(subject:, operation:, structure: :elementwise, reason:)` called directly,
*without* including the module — exactly what `Context::PurgeFailedInputs` (`purge_failed_inputs.rb:117`)
does. T6's ACs already say "does not include the concern"; this pins the mechanism.

**D3 — `spec/algebra_laws_spec.rb` sweeps the process-wide registry and fails on any unproven
declaration or unconfirmed refutation.** Two files become **orchestrator-owned shared files** this
chunk, amended by T3, T6 and T7 via handed-back diffs:
- `spec/algebra_laws_spec.rb` — `GROUPS` and `BATTERIES` need a `:pure` entry (D4).
- `spec/support/algebra_generators.rb` — one knobs entry per new declaration *and* per new
  refutation, keyed `[Subject, :operation]`. Both "missing" and "orphaned" are asserted empty
  (`:207-215`), so a `lib/` declaration with no generator is red, and a generator for a claim nobody
  makes is equally red. A refutation's knobs must also carry `refutes:` (which law turns) and
  `exhibits:` (a witness showing the recorded reason), per `:293-317`.

**D4 — `:pure` has no law group, and the shipped code says the first consumer writes it.**
`algebra_laws_spec.rb:112-115`: "`:pure` is in `STRUCTURES` and nothing declares it yet, so the first
`pure on:` line will fail here, naming itself, until someone writes its laws. That failure is the
feature." This chunk is that first consumer. **T3 writes `spec/support/shared_examples/pure.rb`** —
both a law group and a battery, since T6 *refutes* pure and a refutation needs a battery. This does
not contradict the "the algebra vocabulary is the prerequisite chunk's" ruling: that ruling forbids
private copies of the **modules**, and the prerequisite deliberately handed the **laws** to the first
consumer.

**D5 — a spec-local strategy double must declare against a scratch registry.** `Algebra.registry` is
process-wide, and the sweep's orphaned-generator check would go red on an anonymous class. Every
verb takes `registry:`; T3's and T6's doubles must pass `Lain::Algebra::Registry.new`. Only `lib/`
classes declare against the global one.

**D6 — `Strategy::Elide` is the first `Alone` (no-analysis) declaration, and the existing battery
cannot read it.** `spec/support/shared_examples/elementwise.rb` transcribes only the `given:` shape
and says so ("an unconditional `Alone` declaration would arrive with a nil analysis and say so loudly
rather than quietly passing"). **T7 extends that battery to the `Alone` shape**; the file is
orchestrator-owned for this chunk. T3's new `monoid_homomorphism.rb` group is still wanted and is a
*different* law — the plain `collapse(A ++ B) == collapse(A) ++ collapse(B)`, which holds for an
`Alone` strategy and is what T6's negative form turns on. T3 must read `elementwise.rb`'s doc on why
the plain form is false for a `given:`-analysis combinator, and scope the new group to `Alone`
strategies accordingly.

**D8 — the seam's method names, corrected after T3's panel review (orchestrator ruling).** The card
text below says the duck's second question is `#collapse(messages) -> Replacement`, and never
mentions the two methods that actually carry the contract. A wave-3 author reading only the card
writes `elementwise on: :collapse`, which the shipped DSL accepts **silently** and which leaves
`#collapse` answering an `Array` where T5 and T9 expect a `Replacement`. The corrected shape, which
`Strategy::Base` now *enforces* rather than describes:

- **`#ranges(messages, span:)` is the public, VALIDATED question** — it applies the interval-partition
  contract (inside the span, non-overlapping, ascending) that the derivation's causal edges depend
  on. A strategy implements an abstract *hook* under a different name; it does not override `#ranges`.
  T5 calls `#ranges` and gets validation. (Panel finding S4: the first shape had the public method
  unvalidated and the validated one invisible from the card, one method name away from being skipped.)
- **`#blocks(messages) -> Array<Hash>` is the operation the algebra declares.** T7 writes only its
  per-message map and declares `elementwise on: :blocks, each: <its map>`; T6 hand-writes `#blocks`
  and refutes on `:blocks`.
- **`#collapse` is concrete on `Base`, never overridden, and wraps `#blocks` into a `Replacement`.**
  `Base` refuses an override at load, naming the offender — both the hand-written door and the
  `elementwise on: :collapse` door, since generating a method fires the same hook.

**D9 — the shared elementwise battery could not read this seam, and that blocked all of wave 3.**
`spec/support/shared_examples/elementwise.rb` was hardcoded to `instance.call(span)`, but the seam
deliberately has no `#call`. Since the registry sweep judges *every* `:elementwise` declaration and
refutation through that group, T7's declaration raised and T6's refutation raised on both laws —
which `algebra_laws_spec.rb:300-302` fails by design ("a refutation confirmed by an error proves
nothing"). **Ruling: T3 extends that battery to read the declared operation, and folds in D6's
nil-analysis (`Alone`) half at the same time** — one edit to one orchestrator-owned file, rather than
serializing two parallel wave-3 cards behind it. **This supersedes D6's assignment of that file to
T7**; T7 no longer touches it. The file is orchestrator-owned and handed back as a diff.

**D7 — baselines are stale.** Measured 2026-07-27 at `b6866da` in Joel's checkout: **4820 examples,
0 failures, 2 pending**. The plan's 4696/4697/4691 predate the algebra chunk. `gherkin_spec.rb:248`
still globs `planning/specs/*.md`, so a worktree with no untracked plan docs counts fewer; each
implementer records its own pre-change baseline after `git merge --ff-only main` and reports both
numbers rather than matching a pinned one.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`,
  `lib/lain/compaction.rb` (the unit index — T2, T3, T5, T8 each add one require line),
  `lib/lain/context.rb` (the `REQUIRES`/combinator
  index — its require block at `:3-17` is order-sensitive), `lib/lain/cli.rb` (the `cli/` subtree
  index; `lib/lain.rb` carries only `require_relative "lain/cli"` — the last chunk's Deviation 6
  is this exact correction), `lib/lain/telemetry.rb`, `exe/lain`, `ROADMAP.md`, `.rubocop.yml`,
  `spec/spec_helper.rb`, `spec/support/tags.rb`.
  **`lib/lain/telemetry.rb` is orchestrator-owned** and T5 is its only amender this chunk; the
  record and its `Guards::` entry are handed back as a diff, following the discipline
  `chunk-compaction-tiers-pins-isolation.md:203-205` used. **`exe/lain` is orchestrator-owned** and
  T11 is its only amender — the last chunk lost four `method_option` lines exactly here, so
  `spec/lain/cli/chat_flags_spec.rb` now fails when a read flag is declared by no command.
- **`lib/lain/compaction/strategy.rb` changes hands mid-chunk.** T3 *creates* it in wave 1 as the
  strategy subtree's index and owns it there, uncontended. From wave 3 it is orchestrator-owned,
  because T6 and T7 each add one `require_relative` line to it in the same wave; both hand back the
  one-line diff rather than editing it.
- **`Metrics/ClassLength` headroom, measured 2026-07-27** (`Max: 110`). Five classes sat within
  two lines of the cap after the last chunk. Cards editing these must extract a collaborator, not
  loosen the cop, and must report the length they leave behind:

  | Class | Now | Cards touching it |
  |---|---|---|
  | `CLI::Backend` | 108 | **none, deliberately** — T11 exists as its own class for this reason |
  | `Compaction::Source` | 101 | T9 |
  | `Compaction::Head` | well under (no offense) | T4 |
  | `Context::Compact` | well under (no offense) | T4 |

  Measured 2026-07-27 with the repo's own config: only `CLI::Backend` (108) and `Compaction::Source`
  (101) are near the cap; `Head`, `Compact`, and `Prepared` register no offense at all, so an
  earlier draft's "five classes within two lines of the cap" was wrong.
  `Compaction::Source` is the one to watch: T9 adds a derivation call path to a class already at
  101/110. If T9 would cross, the extraction is T9's (a `Source::Derived` collaborator owning the
  derive-and-substitute step), not a later card's emergency. `CLI::Backend` at 108/110 is why the
  strategy resolver is T11's own class rather than a `Backend` method.
- Every agent worktree forks from the session's start commit and may be **stale**. Each
  implementer's brief opens with one permitted git command, `git merge --ff-only main`, before any
  other work; the "never run git" rule holds for everything after it.
- **Baselines, measured 2026-07-27.** `spec/lain/gherkin_spec.rb:248` globs `planning/specs/*.md`
  and parses each plan's Gherkin, so the example count depends on which untracked plan docs a
  checkout has:
  - committed tree at `5665f14`: **4696**
  - Joel's checkout, with six untracked `planning/specs/*.md` including this one: **4697, 0
    failures, 2 pending**
  - **an agent worktree: 4691** — no untracked plan docs. Use this one.

  A card reporting any other number has either changed behavior or is looking at a stale worktree;
  `git merge --ff-only main` first, then re-count.

## Open decisions

None gating any card. Four rulings recorded so they are not relitigated:

- **Derivation is non-recursive: every derived chain is a function of the session timeline
  alone** (user, this interview). Hierarchical/recursive derivation is a designed follow-up and a
  future swept arm, not this chunk. The reason to prefer non-recursive first is that it keeps the
  derived head a pure content address of (source head, strategy), which is what makes
  re-derivation exact and the artifact diffable.
- **The derivation takes a pluggable strategy, and the strategy decides both *which* spans
  collapse and *how*** (user, this interview): "worth keeping the API flexible for
  strategies/policies." Four policies are in view — model summarization, dropping a span
  entirely, a deterministic plan-step collapse ("wave 1 done"), and only summarizing spans not
  already summarized. This chunk builds the seam plus the first two, and folds
  summarize-only-what-is-new into the model strategy as its range filter. A card that finds
  itself hardcoding a single collapse policy into `Derivation` has taken a wrong turn — stop and
  escalate.
- **Journal the derivation edge; re-derive the chain on resume** (user, this interview). This is
  exact rather than approximate because deterministic strategies are pure functions of the source,
  and the model strategy answers through `Oracle::Recorded`, whose `oracle_answer` records are
  already journalled and replayed by `(oracle_digest, question)` (`oracle/recorded.rb:47-49`).
  A model strategy that answers through anything **other** than a recorded oracle breaks this
  ruling — that is T6's first escalation trigger.
- **The replacement's role is `user`, decided here, once.** F1 shows that with no pins the
  replacement *is* `messages[0]`, and the Messages API requires that to be `user`. The panel found
  the first draft deciding this in four places (a `Boundary` parameter, a `Replacement` field, a
  parity calculation in `Compact`, and whatever the strategy chose). One owner: **`Replacement`
  carries content only; the derivation assigns the role.** A strategy never picks a role. If a card
  finds itself computing a role from history parity, stop — that is this ruling being violated.
- **Derive fully on every compacting turn; there is no incremental extension.** F5 measured full
  derivation at a constant ~22 objects and ~1.7 ms at 800 messages, against the projection's
  10.6 ms, because the derived chain is bounded by `keep_last`. An "extend the existing chain" path
  would need to hold the last derived head — state the non-recursive ruling was written to avoid —
  and would buy nothing. No card may add one.
- **The algebra vocabulary is the prerequisite chunk's, not this one's.** `Algebra::Elementwise` and
  `Algebra::Pure` arrive from `chunk-algebra-vocabulary.md`; this chunk consumes them and must not
  define private copies. Its rulings on why homomorphism is structural and why purity carries a check
  rather than behavior hold here unchanged.
- **Algebraic properties are structural where they can be, and characterized by a negative test
  where they cannot.** Two consequences, both binding on cards. (1) Homomorphism is a **base
  class**, not a comment or a marker module: `Algebra::Elementwise` is an `ActiveSupport::Concern`
  implementing `#collapse` as a per-message map, so anything including it *cannot* be
  non-homomorphic, and `is_a?(Elementwise)` is the classification — no separate label to drift. (2) Non-functoriality cannot be made
  structural, so it gets a **characterization spec** that fails if someone later "fixes" it into
  incremental extension, plus the deliberate absence of any `Derivation#extend`. The point of the
  negative tests is maintenance: the wrong conceptual model here (derivation is incremental,
  summarizing composes) is exactly the one a reader would otherwise adopt.
- **The derived chain is substituted as messages, not handed to `Context#render` as a
  timeline.** `render(timeline:)` receives the timeline from the Agent (`agent.rb:302-306`), so
  changing what it walks would mean changing the Agent seam. `Compaction::Prepared`'s private
  `Replay` combinator (`prepared.rb:138-146`) already substitutes a computed message array and has
  no production caller. Reuse it; do not add a `timeline:` parameter to the `PipelineSource` duck.

## Shipping decision — CORRECTED after T9's panel. Read this version.

**The ruling below was wrong, and it is kept struck because T10 was briefed off it.** I ruled from the
implementer's description rather than from the code. What actually ships:

- **The derivation is UNCONDITIONAL.** After T9, `Context::Compact` is composed by *nothing* on the
  chat render path — its only production callers are `bench/plan_sweep/driver.rb:157` and
  `plan/linear_rewrite.rb:106`. Every compacting turn, flagged or not, goes through
  `Compaction::Source::Derived`. So the materialized second lineage **is** what a chat renders
  through, which is what the Intent wanted, and **T4's `Context::Compact` fix is the bench arm's** —
  exactly as the Intent said before I inverted it.
- **The STRATEGY is opt-in.** An unset `--compact-strategy` falls through to a private `Held` policy
  that collapses the span through the turn's `SummarySnapshot` — the eager tool-result tier,
  measured **byte-identical** to what `Context::Compact` rendered. Naming a strategy substitutes an
  operator-chosen `Strategy::Base`. Same derivation, same journal edge, same validation, different
  collapse.
- **That opt-in was not actually wired** when the panel looked: `exe/lain` declared the flag with a
  Thor `default:`, so the option was never nil and the control arm was unreachable — F7's pattern
  mirrored, "declared with a default that makes its off-state unreachable". Being fixed in T9's final
  round by dropping the Thor default; `CLI::CompactionStrategy`'s own header already says the
  fallback is its constant "**not a Thor default**".

~~## Shipping decision, ruled wave 4 — the derivation is OPT-IN~~

**An unset `--compact-strategy` does not resolve a strategy, and the derived chain is therefore not
the default projection.** T9 proposed this and I accepted it. Two reasons, the second stronger than
the first:

1. Defaulting to the span strategy would **silently retire the eager tool-result tier**, which is a
   functional regression nothing in this chunk asked for.
2. The bench's premise is that arms are **swappable and comparable**. An arm that replaces the
   shipped path the moment it exists cannot be compared against it. Opt-in keeps both live.

**This inverts the Intent's framing.** The Intent says "T9's validity AC is the live fix and T4's is
the bench arm's". With an opt-in default the reverse holds: **T4's `Context::Compact` fix is the live
one** — it is what every default session renders through — and T9's derivation is the arm's. F1's
three 400s are fixed on the shipped path by `afa2f39`, not by T9.

**This is opt-in, not unwired.** The distinction matters because F7 catalogued five objects in this
codebase that are fully built, spec'd and never called, and a later reader will otherwise file the
derivation as a sixth. The flag is declared in `exe/lain`, read at the call site, resolved through
`CLI::CompactionStrategy`, and specced end to end. T10 must say this plainly in the docs: the derived
context timeline exists, is reachable by `--compact-strategy`, and is **not** what a default `lain
chat` renders through.

## Waves

```
Wave 1: T1, T2, T3            (no unmet deps in this chunk; T3 needs the prerequisite chunk)
Wave 2: T4 (←T1,T2), T5 (←T1,T2,T3)
Wave 3: T6 (←T3,T5), T7 (←T3,T5), T11 (←T3)
Wave 4: T8 (←T5,T11), T9 (←T4,T5,T6,T11)
Wave 5: T10 (←T9)
```

Critical path: **T3 → T5 → T6 → T9 → T10** (five cards). T2 → T5 → T6 → T9 → T10 is the same
length and lower risk per card.

## Tasks

### T1 — Refuse an invalid rendered conversation          [wave 1] [risk: medium] ✅ LANDED `9408192`

**Depends on:** none
**Files:** `lib/lain/context/conversation.rb` (create),
`spec/lain/context/conversation_spec.rb` (create)
**Reuse:** `Context::DedupeToolCalls` (`context/dedupe_tool_calls.rb:5-9`) is the one object in the
repo that already reasons about the tool_use/tool_result pairing invariant — read its doc before
writing that rule, and reuse its block-reading shape (`:53-57`, `:62-68`).
`Context::MessageEnvelope` (`context/message_envelope.rb:18`) for `#user?` and block
reading — it is already the "ask a message a question" object and is idempotent under `.wrap`.
`Event::ROLES` (`event.rb:28`) is the role vocabulary. `Context::PinnedMessages#projection?`
(`pinned_messages.rb:115-117`) is the existing shape-check idiom (`Hash` with `"role"` and
`"content"`). Guard carriers like `Guards::Prune` (`prune.rb:12-23`) are the ActiveModel
validation idiom, but this object validates a **message array**, not construction arguments, so it
reports rather than raising at `initialize`.
**Shared-file wiring:** `lib/lain/context.rb` — one require line for `conversation`, placed in the
existing ordered require block (`context.rb:3-17`) before `compact`.

This is a pure predicate over a rendered message array. It reports violations; it never repairs
and never raises on a bad array — a repairing validator would hide the defect it exists to name,
and T4 needs to *assert* validity in specs rather than have it silently fixed underneath.

The four invariants, each from the Messages API contract: `messages[0]` has role `user`; roles
alternate strictly thereafter; every `tool_use` block has an answering `tool_result` in the
**immediately following** message and vice versa; no message has empty content.

**Acceptance criteria:**

```gherkin
Scenario: a well-formed alternating conversation has no violations
  Given a message array beginning with a user message and alternating thereafter
  When it is asked for its violations
  Then it reports none and answers that it is valid

Scenario: an assistant-first array is refused, naming the position
  Given a message array whose first message is an assistant message
  When it is asked for its violations
  Then a violation names position 0 and the offending role

Scenario: consecutive same-role messages are refused, naming both positions
  Given a message array with two adjacent assistant messages
  When it is asked for its violations
  Then a violation names the adjacent pair

Scenario: a tool_use with no answering tool_result is refused
  Given an assistant message carrying a tool_use followed by an assistant text message
  When it is asked for its violations
  Then a violation names the unanswered tool_use id

Scenario: a tool_result with no preceding tool_use is refused
  Given a user message carrying a tool_result whose id appears nowhere
  When it is asked for its violations
  Then a violation names the orphaned tool_use_id

Scenario: a tool pair split across a non-adjacent gap is refused
  Given a tool_use and its tool_result separated by an intervening message
  When it is asked for its violations
  Then a violation names the separation

Scenario: an empty-content message is refused
  Given a message whose content array is empty
  When it is asked for its violations
  Then a violation names that position

Scenario: the empty array is valid, not a violation
  Given an empty message array
  When it is asked for its violations
  Then it reports none

Scenario: the validator is a pure, shareable value
  Given any message array
  When it is validated twice
  Then both answers agree, the input is unmutated, and the validator is Ractor.shareable?
```
→ spec file: `spec/lain/context/conversation_spec.rb`

**Escalation triggers:**
- `spec/lain/agent_spec.rb:407-410` pins rendered roles as `%w[user assistant user user]` — two
  adjacent user messages, which this card's alternation rule would call a violation. That is the
  real `Agent` shape (a tool_result user turn followed by the human's next ask), so **the
  alternation rule must permit adjacent `user` messages and forbid only adjacent `assistant`
  ones**, or that spec is wrong. Verify which against the Messages API contract before writing the
  rule; if the API forbids adjacent user messages too, STOP — the Agent's own commit shape is then
  invalid and that is a far larger finding than this card.
- This object must not be wired into `Context#render` or any combinator by this card. Making the
  render raise is a behavior change that would break every compaction spec at once; T4 fixes the
  producer. If a spec seems to need the render to refuse, stop.
- If expressing the tool-pair rule requires reading anything other than `"type"`, `"id"`, and
  `"tool_use_id"` off blocks, stop — `ToolRunner#result_block` emits exactly four keys
  (`agent/tool_runner.rb:230-241`) and a fifth would be a wire-shape change.

### T2 — Snap a compaction span to a conversation boundary          [wave 1] [risk: medium] ✅ LANDED `e9f16e4`

**Depends on:** none
**Files:** `lib/lain/compaction/boundary.rb` (create),
`spec/lain/compaction/boundary_spec.rb` (create)
**Shared-file wiring:** `lib/lain/compaction.rb` — one require line for `boundary`, placed before
`head` in the existing ordered list (`compaction.rb:3-9`), since T4 has `Head` consume it.
**Reuse:** `Compaction::Head#droppable` (`head.rb:119-125`) is the slice this generalizes —
`messages[0...-keep_last]`, `[]` when `messages.size <= keep_last`. `Head#validated`
(`head.rb:97-102`) is the `keep_last` positivity check and its refusal message; borrow the same
rule rather than inventing a second. `Context::PinnedMessages#indices_in`
(`pinned_messages.rb:85-89`) returns the frozen Set of pinned positions.

A pure object answering **where a span may be cut**, given a message array, a requested
`keep_last`, and a pin set. It returns the effective split index — never a rewritten array.

**Why not a `Head` method.** `Head` measures a span (`#bytesize`) and is constructed per turn with
an already-projected list; the cut *rule* is consulted by two objects (`Head` and
`Context::Compact`) that must agree, and putting it on one of them makes the other reach into its
collaborator. `Head` has ample `Metrics/ClassLength` headroom, so this is a dependency-direction
choice, not a size one — extracting the rule is what lets T4 hand the *same* answer to both sites,
which is the disagreement `Head`'s own doc (`head.rb:20-29`) exists to delete. Two
adjustments, both derived from F1/F2:

1. **Never cut between a `tool_use` message and its answering `tool_result`.** The pair is always
   two adjacent messages (Correctness gate 2, `agent.rb:326-328`), so the cut moves by at most one
   position.
2. **Land the retained tail on a role that can follow the replacement.** Per the Open decisions
   ruling the replacement's role is always `user`, decided in one place, so this object takes **no
   role parameter** — it answers an index whose tail begins with `assistant`.

It is wired into nothing by this card. T4 gives `Head` and `Context::Compact` the same boundary
in one atomic change, because they must agree.

**Acceptance criteria:**

```gherkin
Scenario: an unconstrained span snaps to exactly the requested keep_last
  Given an alternating history where the requested cut splits no tool pair
  When a boundary is computed
  Then the split index equals the one today's slice would use

Scenario: a cut that would split a tool pair moves off it
  Given a history where the requested keep_last falls between a tool_use and its tool_result
  When a boundary is computed
  Then the split moves so the pair stays whole on one side

Scenario: the retained tail begins with the role that can follow a user replacement
  Given a history whose requested tail would begin with a user message
  When a boundary is computed
  Then the split moves so the tail begins with an assistant message

Scenario: a span shorter than keep_last is empty rather than negative
  Given a history no longer than the requested keep_last
  When a boundary is computed
  Then it reports an empty span and the whole history is retained

Scenario: pins inside the span do not move the cut
  Given a history with pinned messages inside the droppable span
  When a boundary is computed
  Then the split index is unchanged by the pin set

Scenario: a non-positive keep_last is refused at construction
  Given keep_last of zero or a negative number
  When a boundary is constructed
  Then ArgumentError is raised naming the value

Scenario: the boundary is a pure, shareable value
  Given any history
  When a boundary is computed twice
  Then both answers agree, the input is unmutated, and the object is Ractor.shareable?
```
→ spec file: `spec/lain/compaction/boundary_spec.rb`

**Escalation triggers:**
- `spec/lain/compaction/head_spec.rb:318-350` pins the `keep_last` boundary exactly — 0 refused,
  negative refused, 1 accepted, greater-than-history yields empty — and `:326`/`:338` document
  *which* `Compact` behaviors those refusals protect against. This card must reproduce that rule,
  not replace it. If the snapping logic makes any of those four cases answer differently, stop.
- Snapping changes which bytes are droppable, so it moves the measured shrink floor.
  `spec/lain/compaction/source_spec.rb:721-735` pins the 366/367-byte crossover to the exact byte
  (`neutral_pad = 366` at `:113`). This card must not touch
  `Source`, but T4 will move that crossover — record the new numbers here for T4 rather than
  editing that spec.
- If landing the tail on a compatible role requires moving the split by more than two positions,
  stop: that means the history is not alternating in the way F1 measured, and the boundary rule
  needs re-deriving from the real shape.

### T3 — A span-collapse strategy seam          [wave 1] [risk: medium] ✅ LANDED `bd7b1ce`

**Depends on:** none in this chunk. **Cross-chunk prerequisite:** `Algebra::Elementwise` and
`Algebra::Pure` from `chunk-algebra-vocabulary.md` (its A1). If those modules are absent, STOP — this
card must not define private copies of them.
**Files:** `lib/lain/compaction/strategy.rb` (create),
`lib/lain/compaction/strategy/base.rb` (create),
`lib/lain/compaction/strategy/identity.rb` (create),
`lib/lain/compaction/strategy/replacement.rb` (create — the `Replacement` value and the `DROP`
singleton, which four of this card's ACs pin and which T6 and T7 both construct),
`spec/support/shared_examples/monoid_homomorphism.rb` (create — the law group T6 and T7 both use),
`spec/lain/compaction/strategy_spec.rb` (create)
**Reuse:** `Summarizer::Base` (`summarizer/base.rb:48`, `:53`) is the exact precedent one level
down — a two-question duck (`suitable?`/`compact`) over a single tool result, with
`NotImplementedError` naming the implementer in the shape `Arm#run` uses (`arm.rb:117-118`).
This is its sibling over a **span**. `Context::Combinator` (`context/base.rb:32`) is the shape for
a pure, frozen, composable transform with an `Identity` instance (`base.rb:64`).
`spec/support/shared_examples/monoid.rb` is the **parameterized** law-group idiom to copy for the
new homomorphism group — it takes `operation:`/`identity:`/`generator:`/`equal:` built at the
`include_examples` site (`monoid.rb:38-41` explains why they are built there and not in the group),
and `spec/lain/context/base_spec.rb:26-33` is a worked call site.
`Compaction::SummarySnapshot::NOTHING` (`summary_snapshot.rb:60`) exists because a blank
replacement becomes an empty text block that Anthropic rejects — the same refusal applies here.
**Shared-file wiring:** `lib/lain/compaction.rb` — one require line for the `strategy` unit,
placed before `source` in the existing ordered list (`compaction.rb:3-9`).

The duck, decided in Open decisions. **See D8 for the corrected method names — the shape below is
the intent, and D8 is what a strategy actually writes.**

- **`#ranges(messages, span:) -> Array<Range>`** — which sub-spans of the droppable span this
  strategy will collapse, in ascending order, non-overlapping, all inside `span`. Returning `[]`
  means "collapse nothing", which is how a strategy declines a turn. This is where
  summarize-only-what-is-new lives, and where pins split one span into several. Per D8 this is the
  **validated** public question, and a strategy implements an abstract hook rather than overriding it.
- **`#collapse(messages) -> Replacement`** — what replaces one range. A `Replacement` carries
  **content blocks only**; the derivation assigns the role, per the Open decisions ruling. `DROP` is
  the singleton meaning the range vanishes with no replacement event at all. Per D8, `#collapse` is
  **concrete on `Base` and never overridden**: a strategy writes `#blocks`, which is also the
  operation the algebra declares.

`Base` raises `NotImplementedError` naming the strategy for both. `Identity` returns no ranges and
is the Null — a derivation over `Identity` must produce a chain byte-identical to the source, which
is the monoid **unit law**, not an arbitrary check.

**Homomorphism is structural, via `Algebra::Elementwise`** (the prerequisite chunk's A1)**.** A strategy including it implements
only `#collapse_one` and gets `#collapse` as a per-message map. By F8's universal-property argument,
an includer is a monoid homomorphism *by construction* — it cannot be non-homomorphic through that
door. The concern comes from the shared `Lain::Algebra` vocabulary rather than being defined here, so
the same property is declarable by anything else with the shape — the prerequisite chunk's A4 makes
`DedupeToolCalls` and `PurgeFailedInputs` its first non-strategy consumers.

A Concern rather than a superclass for three reasons. `Strategy::Base` is already the superclass and
Ruby has single inheritance, so a superclass form would foreclose every other axis a strategy might
later declare. `include` still makes `is_a?` answer true, so the type check survives — the
classification is the module, with no separate marker to fall out of sync. And CLAUDE.md blesses
exactly this: "`ActiveSupport::Concern` is the right way to extract orthogonal behavior into a named,
separately-testable module."

It is not speculative generality: T7 includes it, T6 deliberately does not, and follow-up 1's
hierarchical derivation is only sound for strategies that do — so the module is load-bearing at
runtime, not a label.

**`Algebra::Pure` (the prerequisite chunk's A1) is the second axis**, declaring that `#collapse` is a total function of the
span alone. Ruby cannot enforce that, so the concern carries the *check* rather than the behavior: an includer must construct with no arguments and be `Ractor.shareable?` —
this repo's existing mechanical proxy for "no reachable mutable state" (F8). The 2x2 is fully
populated and the axes gate different guards (F8's second table): `Elementwise` gates recursion
safety, `Pure` gates whether the journalled edge alone suffices to re-derive.

The prerequisite chunk's A1 owns and proves the concern *mechanics* (that the elementwise concern supplies the whole-span
map, that the pure concern refuses a collaborator-holding includer). This card's ACs cover only
what is specific to the strategy seam: that its own strategies declare the right cells and that
the range contract holds.

This card also writes the two law groups both later cards need: **"a monoid homomorphism"** and its
deliberate counterpart **"not a monoid homomorphism"**. The negative group exists for maintenance —
it records that non-compositionality is intended rather than a bug someone should tidy away.

**Acceptance criteria:**

```gherkin
Scenario: the base strategy refuses both questions loudly, naming itself
  Given a strategy that implements neither method
  When it is asked for ranges and then for a collapse
  Then NotImplementedError is raised each time, naming that strategy

Scenario: the identity strategy collapses nothing
  Given the identity strategy and any droppable span
  When it is asked for ranges
  Then it returns none

Scenario: an elementwise strategy satisfies the homomorphism law over generated spans
  Given an elementwise strategy defined only by its per-message collapse
  When the law group runs over randomly generated spans
  Then collapsing a concatenation equals concatenating the collapses





Scenario: the two axes are independent
  Given a strategy that is elementwise but not pure, and one that is pure but not elementwise
  When each is asked about both properties
  Then each answers the two independently

Scenario: the classification is the module, with nothing to keep in sync
  Given an elementwise strategy and a non-elementwise one
  When each is asked whether it is elementwise
  Then the answer follows from what it includes, and no separate declaration of the property exists

Scenario: ranges must fall inside the span they were asked about
  Given a strategy returning a range outside the span
  When the seam validates it
  Then it is refused, naming the offending range and the span

Scenario: overlapping ranges are refused
  Given a strategy returning two overlapping ranges
  When the seam validates them
  Then it is refused, naming the overlap

Scenario: ranges are answered in ascending order
  Given a strategy returning ranges out of order
  When the seam validates them
  Then it is refused, naming the ordering

Scenario: a replacement cannot carry a role at all
  Given the replacement value
  When its interface is inspected
  Then it exposes content only, and no way to set or read a role

Scenario: a blank replacement is refused rather than rendered
  Given a replacement whose content is empty or blank text
  When it is constructed
  Then it is refused, because a blank block is rejected by the provider

Scenario: the drop replacement is a distinguishable singleton
  Given the drop replacement
  When it is compared to a content-bearing replacement
  Then they are distinguishable and drop carries no content

Scenario: a strategy and its replacements are shareable values
  Given the identity strategy and a content-bearing replacement
  Then both are deeply frozen and Ractor.shareable?
```
→ spec file: `spec/lain/compaction/strategy_spec.rb`

**Escalation triggers:**
- A strategy is asked about **messages**, never about a Timeline, a Session, or an Event. If a
  strategy appears to need any of those to answer `#ranges`, stop — that state belongs to the
  caller — `Compaction::Source` *receives* the session per call (`source.rb:177`); its `initialize`
  (`:126`) holds no session ivar — and must be handed in at construction, or the seam is drawn in
  the wrong place.
- Do **not** give the seam a `#call(messages) -> messages` method. That is
  `Context::Combinator`'s shape, and a strategy that can rewrite the whole array can bypass the
  range discipline the derivation depends on for its causal edges.
- `Summarizer::Base`'s review found that `NotImplementedError < ScriptError`, so
  `rescue StandardError` misses it — recorded three times in
  `chunk-compaction-tiers-pins-isolation.md:1357`. If this card writes any rescue around a
  strategy call, it must not be `rescue StandardError`.
- If a strategy needs to be a Proc rather than an object, stop: `Oracle::Heuristic` is already
  non-shareable for holding a `@predicate` Proc (that chunk's follow-up 11), and the derivation
  runs off the render path but its output must stay shareable.

### T4 — Make the compacted head a valid, order-preserving conversation          [wave 2] [risk: high] ✅ LANDED `afa2f39`

**Depends on:** T1, T2
**Files:** `lib/lain/compaction/head.rb` (modify), `lib/lain/context/compact.rb` (modify),
`spec/lain/compaction/head_spec.rb` (modify), `spec/lain/context/compact_spec.rb` (modify)
**Shared-file wiring:** none
**Reuse:** T2's `Compaction::Boundary` for the split index — **the same instance must reach both
sites**, exactly as `chunk-compaction-tiers-pins-isolation.md`'s B2 required one `pins` object to
reach `Head` and `Compact` (`head.rb:20-29`). T1's `Context::Conversation` for the ACs.
`Context::Prune#call` (`prune.rb:53-58`) is the order-preserving idiom: select indices, sort, then
`values_at` — never partition-and-concatenate.

**Carry-forward from T2's panel review (orchestrator, wave 1).** `Boundary` answers a `#moved`
diagnostic — how far the snap walked — and **nothing is required to read it**. The panel found the
*near*-decline case: one assistant at index 1 followed by thirty user messages, `keep_last: 3`, gives
`index=1, moved=28`, retaining 31 of 32 messages when 3 were asked. That is the *correct* answer and
`Boundary` reports its cost honestly, but `Head` then measures a one-message droppable span, `Need`
never crosses threshold, and compaction effectively does not happen while every predicate says
things are fine — the silent no-op moved one notch down rather than removed. **T4 and T5 must give
`#moved` a consumer**: journalling it in T5's `Telemetry::ContextDerived` record is the natural home,
and thresholding on it is the alternative. A wave-2 card that leaves `#moved` unread has not
discharged this.

This is one card because `Head` and `Compact` must agree on the droppable span; splitting it
leaves the suite red between two waves. Three changes, all in service of one behavior:

1. Both sites take their split index from `Boundary` instead of computing `messages[0...-keep_last]`.
2. `Compact` emits its summary as a **`user`** message — the fixed role from the Open decisions
   ruling, never computed from history parity — which is what makes `messages[0]` valid (F1). T2's
   boundary is what guarantees the tail then begins with `assistant`.
3. `Compact` keeps protected/pinned messages **in position** rather than hoisting them (F3), which
   means the summary is injected where the collapsed span was, not before the survivors.

**Acceptance criteria:**

```gherkin
Scenario: a compacted render is a valid conversation at the shipped default
  Given a long alternating history and the default keep_last of 20
  When the composed compacting pipeline renders
  Then the rendered messages have no conversation violations

Scenario: validity holds across every keep_last, odd and even
  Given a long alternating history
  When it is compacted at each keep_last from one to the history length
  Then no rendered array has a conversation violation

Scenario: a compacted tool-heavy render leaves no orphaned tool blocks
  Given a history of assistant tool_use turns each answered by a user tool_result turn
  When it is compacted at each keep_last across the span
  Then no rendered array has an unanswered tool_use or an orphaned tool_result

Scenario: a pinned message keeps its neighbours
  Given a history with one pinned message in the middle of the droppable span
  When the pipeline renders
  Then the pinned message appears at its original relative position, after the summary of what preceded it

Scenario: Head and Compact still agree on what is droppable
  Given any history, keep_last, and pin set
  When the Head's message list and the messages Compact actually removes are compared
  Then they are equal

Scenario: pinning everything droppable declines rather than emitting an empty summary
  Given a history whose every droppable message is pinned
  When the pipeline renders
  Then the render is byte-identical to the uncompacted one

Scenario: the threshold still measures the unpinned droppable bytes
  Given a history with one pinned message and a threshold between the pinned and unpinned sizes
  When Compact runs
  Then its decision is made on the unpinned bytes, matching the Head's bytesize
```
→ spec file: `spec/lain/compaction/head_spec.rb`, `spec/lain/context/compact_spec.rb`

**Escalation triggers:**
- **`spec/lain/compaction/head_spec.rb:357-372` is an exhaustive agreement sweep** across every
  `keep_last` and pin set. It is the spec that makes this card atomic. It must still pass; if
  making it pass requires changing what agreement *means*, stop and confirm.
- `spec/lain/compaction/head_spec.rb:110-123` and `:249-258` pin the threshold crossover
  two-sidedly (`head.bytesize` compacts, `head.bytesize + 1` defers). Snapping the boundary moves
  `bytesize`, so these will move. Updating them is expected; **deleting** either side is not.
- **`spec/lain/compaction/head_spec.rb:131-147` is the canary the previous chunk planted** for
  exactly this class of change: it asserts `head.bytesize` equals the dump of what `Compact`'s own
  summarizer received, byte for byte. A snapped boundary breaks it before anything else does. It
  must be updated, not deleted — if it cannot be made to hold, the two sites have stopped agreeing.
- `spec/lain/compaction/source_spec.rb:721-735` pins the shrink floor at exactly 366/367 bytes.
  A snapped boundary changes the dumped bytes and will move that crossover. Re-measure and report
  the new numbers to the orchestrator; do **not** loosen the assertion to a range.
- `spec/lain/session_record_compaction_spec.rb:60-77` asserts the compacted request excludes
  ask1/reply1/ask2 and includes `"[compacted]"` while the journal keeps the full history. If a
  changed boundary changes *which* messages survive, that spec's expectations move but its
  invariant (journal lossless, render compacted) must not.
- `spec/lain/context/compact_spec.rb` pins "summarizer receives exactly the dropped messages". If
  keeping pins in position means the summarizer now receives a *different* set, that is the
  contract changing — stop and confirm rather than editing the expectation.
- **If the summary's role appears to need to vary per render, STOP.** The Open decisions ruling fixes
  it at `user` and gives T2's boundary the job of making the tail compatible. A role computed from
  history parity is exactly the four-way leak that ruling exists to prevent — if the boundary cannot
  deliver a compatible tail, the boundary rule is wrong, not the role.

### T5 — Derive a context timeline from a source timeline          [wave 2] [risk: high] ✅ LANDED `2af1fcd`

**Depends on:** T1, T2, T3
**Files:** `lib/lain/compaction/derivation.rb` (create),
`spec/lain/compaction/derivation_spec.rb` (create)
**Reuse:** T1's `Context::Conversation` to validate its own output before returning.
`Arm::Synthesis` (`arm/synthesis.rb:55`, `:66`) is the existing fan-in writer — it
commits a turn naming N causal parents and **raises rather than committing a dangling edge**
(pinned `spec/lain/arm/synthesis_spec.rb:77`); copy that discipline exactly.
`Timeline#commit(role:, content:, causal_parents:)` (`timeline.rb:61-70`) and
`Timeline.empty(store:)` (`timeline.rb:27`) are the writers; the derived chain must be built in
**the same Store**, because the replacement events' causal edges name source digests and a
different store would dangle them (`store.rb:84-89`, `Timeline::CrossStore` at `timeline.rb:23`).
Note this is the *only* reason — F5 measured that there is no prefix sharing to preserve. `Compaction::Head`'s projection (`head.rb:38`) is the message shape.
**Shared-file wiring:** `lib/lain/compaction.rb` — one require line for `derivation`, after
`strategy` and before `source`. `lib/lain/telemetry.rb` — one `Telemetry::ContextDerived` record
(source head digest, derived head digest, strategy name, collapsed ranges as source-digest spans)
with its `Guards::` entry.

The core object, and **the production caller of T1's validator** — it refuses to return a chain
whose projection is an invalid conversation. That is what keeps `Context::Conversation` from
becoming the tenth spec-only object in this codebase (F7 lists nine), and it puts the F1 class of
bug behind a loud failure instead of a spec assertion.

Given a source `Timeline` and a strategy, it returns a **derived `Timeline`** in the same Store: a fresh root whose events are the retained source turns plus one replacement event
per collapsed range, in position. Each replacement event names the source digests it subsumes as
`causal_parents`, which is what F4 proved safe: `to_a` follows `render_parent` only, so the derived
chain renders the replacement and never the turns it replaced.

Non-recursive by ruling: the derivation reads the **source** timeline only, never a previously
derived one. N ranges are natural — one replacement event each — which is the in-scope multi-span
squash.

**Acceptance criteria:**

```gherkin
Scenario: a derived chain replaces a collapsed span with one event naming what it subsumed
  Given a source timeline and a strategy collapsing one range
  When a derivation runs
  Then the derived chain is shorter by that range, and the replacement event's causal parents are exactly that range's source digests

Scenario: the derived chain never renders the turns it replaced
  Given the same derivation
  When the derived chain is walked
  Then no source digest inside a collapsed range appears in the walk

Scenario: several ranges collapse to several events, each in position
  Given a strategy collapsing three non-adjacent ranges
  When a derivation runs
  Then the derived chain carries three replacement events, in the order their ranges appeared, with the retained turns between them

Scenario: a dropped range leaves no replacement event at all
  Given a strategy whose collapse answers drop for a range
  When a derivation runs
  Then the derived chain omits that range entirely and no replacement event names it

Scenario: the identity strategy derives a chain that renders identically to the source
  Given the identity strategy
  When a derivation runs
  Then the derived chain's projected messages are byte-identical to the source's

Scenario: no incremental extension is offered
  Given the derivation object
  When its public interface is inspected
  Then it exposes no method that extends a previously derived chain

Scenario: the same source and strategy derive the same digest
  Given one source timeline and one deterministic strategy
  When a derivation runs twice
  Then both derived head digests are equal

Scenario: the derived chain is bounded by the retained tail, not by history length
  Given source timelines of fifty, two hundred, and eight hundred turns and one collapsing range
  When each is derived at the same keep_last
  Then all three derived chains have the same length and each derivation writes the same number of store objects

Scenario: a derived chain is a valid conversation
  Given any source timeline and any of this chunk's strategies
  When a derivation runs
  Then the derived chain's projected messages have no conversation violations

Scenario: a strategy that would produce an invalid chain is refused loudly
  Given a strategy whose replacement would leave the projection non-alternating
  When a derivation runs
  Then it raises, naming the violation, rather than returning an invalid chain

Scenario: a derivation into a store lacking the source refuses rather than dangling
  Given a source timeline and a different, empty store
  When a derivation is attempted into that store
  Then it raises rather than committing a dangling causal edge

Scenario: the derivation journals its edge
  Given a journal and a collapsing strategy
  When a derivation runs
  Then a record is journalled naming the source head, the derived head, the strategy, and the collapsed ranges

Scenario: every derived event is a deeply frozen, shareable value
  Given any derivation
  When its events are inspected
  Then each is deeply frozen and Ractor.shareable?
```
→ spec file: `spec/lain/compaction/derivation_spec.rb`

**Escalation triggers:**
- **Duplicate `tool_use` ids inside one projection are out of `Context::Conversation`'s scope**
  (T1 panel finding 1, orchestrator ruling wave 1). Its tool-pair rule matches by *set membership at
  a position*, not by multiplicity: two same-id `tool_use` blocks answered once report no violation.
  The doc says so honestly and follow-up 12 records it. The plausible producer is exactly this card —
  a derivation that replays or copies a span. **If the derivation can produce duplicate `tool_use`
  ids within one rendered projection, STOP and escalate**; do not rely on T1's validator to catch it,
  because it will not.
- **`Timeline#to_a` must keep following `render_parent` only.** F4 measured this and the whole
  design rests on it. If making the causal edges work appears to require `to_a`, `ancestors`, or
  `ancestor_digests` to traverse `causal_parents`, STOP — that would make the derived chain render
  the turns it replaced and would also change `Ledger#unique_turns` (`ledger.rb:115-119`) into a
  double-counter.
- `spec/lain/timeline_spec.rb:204` and `:469` run the `MeetSemilattice` property group over a
  random render forest **with causal cross-links**, and `:480-490` pins that render `meet` is
  unperturbed by causal edges. A derived chain adds a new population of fan-in nodes; if any of
  those properties fails, stop — the edge shape is wrong, not the property.
- **The non-functoriality spec is a characterization test, and it is there to be read, not fixed.**
  If a later change makes it fail because derivation became prefix-preserving, that is a real
  achievement and needs confirming — but the far likelier cause is someone "optimising" derivation
  into an incremental extend, which the Open decisions forbid. Either way, stop rather than deleting
  the example; the same discipline `chunk-compaction-tiers-pins-isolation.md`'s A5 used when it left
  a characterization example so a ruling could not re-hide.
- **Corrected 2026-07-27 by measurement (T5 panel).** The claim below was wrong in two ways and is
  kept, struck, because follow-up 8 was going to be argued from it. There is **no** method named
  `Event::Projection#reachable`; the line references point at `consumed_by_turns`
  (`event/projection.rb:111`) and `causal_closure` (`:116-129`). And **`Projection#usage` does NOT
  double-count** — it folds over `unique_digests`, which is `timeline.ancestor_digests`, i.e. render
  ancestry, identical to `Ledger#unique_turns`. Measured over a derived chain: 38 = 32 + 6, no
  double count.

  The real disagreement is elsewhere, and is worth more than the claimed one. Measured on a 32-turn
  tool history with a 27-digest fan-in: **`Projection#provenance` attributes 7 tool_results to a
  replacement whose own content carries 0**, and `consumed_by_turns` injects 27 *turn* digests into
  the mailbox "consumed" set. The latter is harmless only because `#mailbox` yields `:message`-kind
  events and a turn digest can never equal a message digest — a namespace collision resting on a
  `kind` check that method does not make. **That 7 is the number follow-up 8 should be argued from.**

  ~~`Event::Projection#reachable` DOES traverse causal edges transitively, unlike
  `Timeline#ancestors`, so F4's no-double-count guarantee holds for `Ledger#unique_turns` and not
  for `Projection`.~~ The escalation trigger still stands in its operative half: if any spec in
  `spec/lain/event/projection_spec.rb` starts failing, that is this trigger firing, and the answer is
  not to loosen the spec.
- Do **not** put the derived projection into `Event#meta`. Both compaction projections drop `meta`
  (`head.rb:38`, `source.rb:212`), and the only `meta` key anywhere in `lib/` is `spawned_from`
  (F7). A `meta`-carried mapping would be invisible where it is needed.
- This card must not touch `Compaction::Source`, `Context::Compact`, or `Context#render`. Wiring
  the derivation into the render path is T9; three cards editing `source.rb` is the seam being
  wrong.
- If the derived chain needs its own `Store`, stop: cross-store causal edges raise
  `Timeline::CrossStore` and a second store would break the O(new) sharing F5 measured.

### T6 — A model-backed span strategy that only summarizes what is new          [wave 3] [risk: high] ✅ LANDED `93b8d3a`

**Depends on:** T3, T5
**Files:** `lib/lain/compaction/strategy/summarizing.rb` (create),
`spec/lain/compaction/strategy/summarizing_spec.rb` (create)
**Shared-file wiring:** `lib/lain/compaction/strategy.rb` — one require line for
`strategy/summarizing` (that file is this subtree's index and is orchestrator-owned this chunk,
because T6 and T7 both add a line to it in the same wave).
**Reuse:** `Oracle::Summarize::SCHEMA` (`oracle/summarize.rb:33`) is the answer shape and
`.summary` is the field `SummarySnapshot` already reads (`summary_snapshot.rb:137`).
`Oracle::Recorded` (`oracle/recorded.rb:47-49`) is **mandatory**, not optional — its journalled
`oracle_answer` records keyed `(oracle_digest, question)` are what make re-derivation exact under
the "journal the edge, re-derive" ruling. `Compaction::SummarySnapshot` (`summary_snapshot.rb:135`)
is the precedent for keying held answers by content address and for counting hits/misses rather
than guessing.

The model strategy. `#ranges`' hook returns the sub-spans it will collapse; **`#blocks` asks the
oracle** and `Base`'s concrete `#collapse` wraps the answer in a `Replacement` (D8 — do **not**
override `#collapse`, and do **not** declare on it). The elementwise refutation is filed directly
against `:blocks` via `Algebra.registry.refute`, without including the concern, exactly as
`Context::PurgeFailedInputs` does (D2). T3's handback carries a worked example against the final
shape; take it verbatim.

**It must NOT include `Algebra::Elementwise`**, and two of its ACs pin that. Summarizing a
concatenation is not the concatenation of summaries, and F8 shows every practical consequence of
that — the content-address key, the mandated recorded oracle, and the drift under hierarchical
composition all follow from it. The negative law group records the fact so a later reader does not
"tidy" the strategy toward a compositional shape it cannot have.

**"Only summarize what is new" is a property of the oracle, not a range filter.** The first draft
had `#ranges` *skip* ranges whose answer was already recorded — which the panel correctly called
the opposite of the intent: skipping them means the history stops shrinking after the first
compaction. `Oracle::Recorded` already delivers the intent for free (`oracle/recorded.rb:47-52`):
ask it and an already-answered question comes back from the journal with no model call. So the
range is always offered; what varies is whether asking costs anything.

The question is keyed on the **content address of the range's source digests**, so an unchanged
range re-derives to a byte-identical question and hits the recorded answer.

**Acceptance criteria:**

```gherkin
Scenario: a span with no recorded answer is summarized
  Given a recording oracle with nothing recorded and a droppable span
  When the strategy is asked for ranges and then to collapse one
  Then the oracle was asked once and the replacement carries its summary

Scenario: a span whose answer is already recorded is still collapsed, without a model call
  Given an oracle holding a recorded answer for a range's key
  When the strategy is asked for ranges and then to collapse that range
  Then the range is still offered, the replacement carries the recorded summary, and no model call is made

Scenario: an unchanged range re-derives to the same question
  Given one source timeline
  When the strategy computes a range's question twice
  Then both questions are byte-identical

Scenario: a changed range asks a different question
  Given two source timelines differing inside one range
  When the strategy computes that range's question for each
  Then the questions differ

Scenario: the answer is journalled so a later re-derivation is exact
  Given a journalled oracle
  When a range is collapsed and the journal is replayed into a recorded oracle
  Then a second derivation over the same source produces the same derived head digest without asking the model

Scenario: the summarizing strategy is deliberately not a monoid homomorphism
  Given the summarizing strategy and two adjacent spans
  When the negative law group runs
  Then collapsing the concatenation differs from concatenating the collapses

Scenario: the summarizing strategy is deliberately not pure
  Given the summarizing strategy
  When it is asked whether it is pure
  Then it is not, because it holds an oracle, and it does not include the Algebra pure concern

Scenario: the summarizing strategy is deliberately not elementwise
  Given the summarizing strategy
  When it is asked whether it is elementwise
  Then it is not, and it does not include the Algebra elementwise concern

Scenario: a blank answer is refused rather than rendered
  Given an oracle answering with an empty summary
  When the strategy collapses a range
  Then it is refused loudly rather than producing a blank replacement

Scenario: a raising oracle does not take out the derivation
  Given an oracle that raises
  When the strategy is asked to collapse a range
  Then the failure is reported and the range is left uncollapsed
```
→ spec file: `spec/lain/compaction/strategy/summarizing_spec.rb`

**Escalation triggers:**
- **The oracle must be a `Oracle::Recorded`-wrapped tier.** If this strategy is built over a bare
  `Oracle::Model`, the "journal the edge, re-derive" ruling breaks silently: resume would re-ask a
  live model and derive a different chain. If the wiring makes that hard, STOP and escalate rather
  than shipping a strategy whose re-derivation is inexact.
- `Oracle::Definition#digest` folds `tier.to_s` (`oracle/definition.rb:58`), so answering under a
  new tier symbol changes the oracle address and every existing `Recorded` journal misses **loudly**
  (`Recorded::Unrecorded`). Choose the tier symbol deliberately and comment why; if
  `spec/lain/oracle/recorded_spec.rb` starts failing, that is this trigger firing.
- `NotImplementedError < ScriptError` and `Async::Cancel`/`Interrupt < Exception` — both bit this
  codebase repeatedly (`chunk-compaction-tiers-pins-isolation.md:1346-1358`). The "raising oracle"
  AC must not be implemented with `rescue StandardError`.
- This strategy is **not** the eager per-result tier and must not read `Oracle::Eager`.
  `Eager#fire` consumes a digest before spawning (`eager.rb:65-72`), so touching it here would
  spend digests the tool-result path needs. If a spec seems to need `Eager`, stop.
- If the range key ends up being a message digest rather than the range's source-digest address,
  stop: `SummarySnapshot`'s own warning (`summary_snapshot.rb:23-30`) is that a well-formed but
  wrongly-keyed address misses **every** lookup silently and permanently.

### T7 — A deterministic elision strategy that costs nothing          [wave 3] [risk: low] ✅ LANDED `7501d2b`

**Depends on:** T3, T5
**Files:** `lib/lain/compaction/strategy/elide.rb` (create),
`spec/lain/compaction/strategy/elide_spec.rb` (create)
**Shared-file wiring:** `lib/lain/compaction/strategy.rb` — one require line for `strategy/elide`
(orchestrator-owned this chunk; see T6).
**Reuse:** `Compaction::SummarySnapshot`'s attestation rendering (`summary_snapshot.rb:182-205`)
is the exact prose and discipline to copy — `"#{role} #{digest} #{bytes} bytes"` per message, the
`ELIDED` constant (`:54`), and the invariant at `:33-41` that **nothing disappears unattested**.
`SummarySnapshot::NOTHING` (`:60`) is the empty-span answer.

**Includes both `Algebra::Elementwise` and `Algebra::Pure`** (from the prerequisite chunk, threaded through T3's seam) — it is the pure/elementwise
cell of F8's 2x2, which is what makes it the control arm. So it implements only a **per-message map**
and declares `elementwise on: :blocks, each: <that map>` (D8 — the operation is `:blocks`, never
`:collapse`), getting the whole-span map — and its homomorphism — by construction rather than by
assertion. **D9 supersedes D6 for this card**: T3 has already extended the shared elementwise battery
to the `Alone` shape, so T7 no longer edits `spec/support/shared_examples/elementwise.rb`. F8's table is the
reason this matters: because it is a homomorphism, where the boundary falls is irrelevant to its
output, which is exactly what makes it the control arm.

The free strategy: collapse a span to a deterministic attestation of what was there — role,
content address, byte count — with no model call, no IO, and no oracle. It is the honest floor
under the model strategy, the "drop the summary entirely for some parts" case, and the control arm
any comparison of compaction policies needs.

Purely a function of the messages, so its replacement is byte-reproducible and re-derivation is
exact with nothing journalled at all.

**Acceptance criteria:**

```gherkin
Scenario: a collapsed span is attested, not silently dropped
  Given a droppable span of three messages
  When the strategy collapses it
  Then the replacement names each message's role, content address, and byte count

Scenario: the replacement is byte-reproducible
  Given one span
  When it is collapsed twice
  Then both replacements are byte-identical

Scenario: the strategy satisfies the homomorphism law over generated spans
  Given randomly generated adjacent spans
  When the law group runs
  Then collapsing the concatenation equals concatenating the collapses

Scenario: where the boundary falls does not change the output
  Given one span cut into two ranges at every possible position
  When each cutting is collapsed and the results concatenated
  Then every cutting yields the same bytes

Scenario: no model, oracle, or journal is consulted
  Given a strategy built with no collaborators at all
  When a span is collapsed
  Then it succeeds

Scenario: an empty span answers the unit, never a blank block
  Given an empty span
  When the strategy collapses it
  Then the replacement is DROP, the monoid unit
  # AC CORRECTED (orchestrator, wave 3). This originally read "the replacement is the
  # nothing-to-summarize text". That was written before D8's shape existed and is wrong under it:
  # `flat_map` over an empty span is `[]`, `Replacement.of([])` is DROP, and the homomorphism law
  # group's first law IS "maps the empty span to the unit". A `NOTHING`-style placeholder line
  # would break the exact property that makes Elide the control arm -- that where the boundary
  # falls cannot change its output. `SummarySnapshot::NOTHING` remains right for SummarySnapshot,
  # which is not a monoid homomorphism and has no unit to honour.

Scenario: a message with no content blocks is still attested
  Given a span containing a message whose content carries no blocks
  When the strategy collapses it
  Then that message is attested rather than omitted

Scenario: the strategy is a deeply frozen, shareable value
  Given the strategy
  Then it is deeply frozen and Ractor.shareable?
```
→ spec file: `spec/lain/compaction/strategy/elide_spec.rb`

**Escalation triggers:**
- A message with no `"role"` key must raise, as `SummarySnapshot#attest` does via `fetch`
  (`summary_snapshot.rb:194`, pinned `summary_snapshot_spec.rb:464-467`). If this card makes a
  roleless message render as anything other than a raise, stop.
- If this strategy is tempted to reuse `SummarySnapshot` directly rather than copying its
  rendering discipline, check first: `SummarySnapshot` is keyed on **tool-result** source digests
  and built by `.take` over an `Eager`, which is a different question from attesting a span. Two
  objects answering one question is the smell to escalate, not to paper over.

### T8 — Audit a re-derived chain against its journalled edge          [wave 4] [risk: medium] ✅ LANDED `5fafeae`

**Depends on:** T5, T11
**Files:** `lib/lain/compaction/derivation_audit.rb` (create),
`spec/lain/compaction/derivation_audit_spec.rb` (create)
**Shared-file wiring:** `lib/lain/compaction.rb` — one require line for `derivation_audit`, after
`derivation`. (A top-level file rather than `derivation/audit.rb` on purpose: a `derivation/`
subtree would make T5's `derivation.rb` its index, and this card must not edit another card's file.)
**Reuse:** `Journal.records(entries, type:)` (`journal.rb:102-105`) is the lazy reader every other
journal consumer uses. `Bench::Session::ChainFold` (`bench/session/chain_fold.rb:47-56`) is the
precedent for verifying a rebuilt chain by re-commit and comparing digests, and its `#member?`
"can never answer true for unverified bytes" discipline (`chain_fold.rb:13-19`) is the posture to
copy. `Ledger::Index.from_journal` (`ledger/index.rb:37-41`) is the fold shape.

The "journal the edge, re-derive" ruling is only trustworthy if something checks it. This object
reads `Telemetry::ContextDerived` records back and answers whether a re-derivation over the same
source produces the same derived head — the drift guard that keeps the ruling honest instead of
aspirational.

It also gives the record a reader, which matters: F7 found that **nothing** reads a `compaction`
record back today, so a write-only trace is the default failure mode here.

**Acceptance criteria:**

```gherkin
Scenario: a re-derivation matching its record is reported as agreeing
  Given a journal carrying a derivation edge and the source timeline it named
  When the chain is re-derived and audited
  Then the audit reports agreement, naming the derived head digest

Scenario: a drift diagnosis distinguishes a pure strategy from an impure one
  Given two journalled edges, one named by a pure strategy and one by an impure one
  When each re-derivation drifts and is audited
  Then the pure one is reported as a derivation bug and the impure one as an incomplete oracle replay

Scenario: a re-derivation that drifts is reported, naming both digests
  Given a journal edge whose strategy now answers differently
  When the chain is re-derived and audited
  Then the audit reports disagreement, naming the recorded and the re-derived head

Scenario: a journal with no derivation records audits as nothing to check
  Given a journal from a run that never compacted
  When it is audited
  Then it reports nothing to check rather than agreement

Scenario: foreign and malformed journal lines are skipped, not fatal
  Given a journal containing unrelated records and one unparseable line
  When it is audited
  Then the derivation records are still found and nothing raises

Scenario: an edge naming a source head absent from the store is reported, not raised
  Given a journal edge whose source head is not in the store
  When it is audited
  Then the audit reports it as unverifiable, naming the missing digest
```
→ spec file: `spec/lain/compaction/derivation_audit_spec.rb`

**Escalation triggers:**
- Skipping foreign journal lines "is the contract, not a convenience" (`journal.rb:93-97`) because
  the fd can be shared with Rust tracing. If this card makes an unrecognized line fatal, stop.
- This is an offline reader. It must not be wired into the live render path, and it must not open
  a file itself — `SessionRecord::Salvage` is the precedent for a pure function over injected
  ducks that "touches no file" (`salvage.rb:56-63`). If it needs `File`, stop.
- If auditing requires the derived events to have been journalled, the "journal the edge" ruling
  has been misread — the audit re-derives. Stop and re-read the Open decisions.

### T9 — Render through the derived chain          [wave 4] [risk: high] ✅ LANDED `ef73654`

**Depends on:** T4, T5, T6, T11
**Files:** `lib/lain/compaction/source.rb` (modify),
`spec/lain/compaction/source_spec.rb` (modify), **`lib/lain/cli/backend.rb` (modify — scope
expanded, orchestrator ruling wave 3)** and `spec/lain/cli/backend_spec.rb` (modify).
**Shared-file wiring:** none for the flag itself (T11 owns the flag, its declaration and its
resolver).

**SCOPE EXPANSION, ruled wave 3 after T11's panel.** As written this card had nowhere to *call*
`CLI::CompactionStrategy.resolve` — `Backend#compaction_source` lives in `backend.rb`, which no card
in this chunk touched. The flag would then ship **declared, parsed, and read by nobody**: F7's
"unwired in production" pattern, and exactly the failure `spec/lain/cli/chat_flags_spec.rb` exists to
catch *in the direction it cannot see* (it fails on read-but-undeclared, never on
declared-but-unread). **T9 owns the call site**, and T9 is the card that wakes that guard.

Two constraints on the expansion. `CLI::Backend` is at **108 of 110** on `Metrics/ClassLength`, so if
adding the call site crosses it, **extract a collaborator — do not loosen the cop**; `CLI::Backend`
was deliberately kept out of every other card in this chunk for exactly this reason. And
`Backend#pipeline_source` raises `Rebound` on a second differing call (`cli/backend.rb:337-345`)
while `Backend#eager` is memoized run state, so the strategy must be **resolved once and injected**,
never fetched per turn.
**Reuse:** `Compaction::Prepared::Replay` (`prepared.rb:138-146`) is the *shape* to copy — a
`Context::Combinator` whose `call(_messages) = @messages` — but **not the object**: it is
`private_constant` (`:147`) and `Prepared` computes its own compaction from a `compact:`
collaborator (F6). Write the equivalent here; do not reach into `Prepared` and do not edit it.
`Source#commit` (`source.rb:330-337`) is where the pipeline is composed and
`base.with_pipeline` applied; `BASE_PROVIDER` (`source.rb:404-407`) is the shareable
base-provider lambda whose `self` is the Source **class**, and `flattened_twin`
(`source.rb:353`) is why a live `Context::ModelSwitch` does not break shareability.

The wiring. `Source#context_for` derives a context timeline from the source timeline and
substitutes **its projection** as the rendered messages, instead of composing a `Context::Compact`
into the pipeline. Per the Open decisions ruling, the derived chain is substituted as messages —
the `PipelineSource` duck keeps its four keywords and `Context#render` keeps taking the Agent's
timeline.

Defer stays byte-identical: on a defer `Source` must return `base` **itself**, which
`source_spec.rb:167` pins with `equal(base)`.

**Two hard preconditions from T4's panel (orchestrator, wave 2). Read these before writing the
validity AC — the first one will otherwise be shipped false a second time, on the live path.**

1. **The unconditional validity claim is false on one axis: pins.** T4 made the *unpinned*
   compacted render clean — 3,056 exhaustive cells, zero introduced violations of any rule. But a
   pin punches a hole in the **middle** of the span, and neither the boundary nor the summary looks
   at that. Measured through the real production path with one pinned `tool_use` turn at the shipped
   `keep_last: 20`: `neither messages[1] nor messages[2] is a user message` **and** `the tool_use
   "toolu_2" in messages[1] is never answered` — F1 and F2 reconstituted. Swept at `Compact` level:
   780 introduced `unanswered_tool_use`, 780 `orphaned_tool_result`, 344 `alternation` across 20,060
   cells. T4 carries this as a **characterization spec naming a known defect**, not as a passing
   claim. **T9's AC "a rendered compacting turn is a valid conversation" must either exclude pins
   explicitly or fix the hole** — writing it unconditionally reproduces the defect on the path that
   actually reaches Anthropic. The likely proper repair, recorded so it is not re-derived: a pin that
   would strand its counterpart either drags the counterpart along or is dropped with it, which is a
   `PinnedMessages` concern about what a pin *means*. See follow-up 14.
2. **`Compaction::Boundary` is correct only while the replacement's role is `user`.** `Boundary`
   takes no role parameter, by design. With a `user` replacement no tail role can create an illegal
   adjacency, which is what makes the relaxed cut rule sound. **T9 owns the object that assigns the
   role** (per the Open decisions ruling the derivation assigns it), so T9 is exactly where this can
   break — and if a role of `assistant` is ever assigned, every `Boundary`-derived cut becomes F1's
   400 again. T4 made `boundary_spec`'s sweep read the role from where it is decided rather than
   restating it, so the link is now tested; do not re-hardcode it.

Also: `Boundary#moved` **changed meaning between T2 and T4**. Under T2 it measured how badly the cut
degraded; that failure mode is gone. Under T4 it records "a tool pair forced the cut" and is 0 or 1
in every case a well-formed history reaches. Carrying T2's framing into `Source#record` would measure
something that no longer exists. And `declined?` is **not** characterized by `raw == 1` — a message
carrying both a `tool_result` and a `tool_use` declines at `raw == 2`. Ask `declined?`; do not
reconstruct it.

**Acceptance criteria:**

```gherkin
Scenario: a compacting turn renders the projection of the head the journal names
  Given a history long enough to compact, and a journal
  When a turn renders
  Then the rendered messages equal the projection of the derived head named in the journalled record, and the source timeline's head is unchanged

Scenario: a deferring turn is still a true no-op
  Given a history below every threshold
  When a turn renders
  Then the returned Context is the base itself and the render is byte-identical to the unwired one

Scenario: derivation is not a functor on the prefix order
  Given a source timeline and the same timeline with one more turn committed
  When both are derived at the same keep_last with the same strategy
  Then neither derived chain is an ancestor of the other, and their heads differ

Scenario: per-turn derivation cost does not grow with history length
  Given two runs whose histories differ tenfold, both compacting at the same keep_last
  When each renders a compacting turn
  Then each derivation writes the same number of store objects

Scenario: a rendered compacting turn is a valid conversation
  Given any history that compacts, at the shipped default keep_last
  When a turn renders
  Then the rendered messages have no conversation violations

Scenario: the derivation edge is journalled once per derivation
  Given a journal and a run that compacts twice
  When both turns render
  Then two derivation records are journalled, naming distinct derived heads

Scenario: every per-turn Context stays shareable, including with a live model slot
  Given a base Context carrying a live model switch slot
  When a compacting turn renders
  Then the returned Context is Ractor.shareable? and nothing raises

Scenario: the session timeline is never written to by a derivation
  Given any compacting run
  When turns render
  Then the source timeline's head digest advances only by committed turns, never by a replacement event
```
→ spec file: `spec/lain/compaction/source_spec.rb`

**Escalation triggers:**
- **`spec/lain/compaction/source_spec.rb:528` pins that every returned Context is
  `Ractor.shareable?`, and `spec/lain/cli/wiring_spec.rb:397-403` is the A8 regression** — a
  Context carrying the live `/model` slot must still compact without an
  `Ractor::IsolationError`. A `Replay` combinator holding a materialized array is shareable; a
  provider lambda that closes over the Source or its journal is not (`scheduler.rb:172-186`). If
  the derived projection cannot reach the pipeline without capturing the Source, stop.
- `Compaction::Source` is at **101 of 110** on `Metrics/ClassLength`. If this card crosses it,
  extract a `Source::Derived` collaborator owning the derive-and-substitute step — do not loosen
  the cop, and report the length left behind.
- `source_spec.rb:167` pins defer with `equal(base)` and a byte-identical render;
  `spec/lain/cli/backend_spec.rb:339-347` pins that the source object is memoized across calls and
  `:351`/`:359` that a differing journal or cache profile raises `Rebound`. None of those may move.
  (The first draft cited `source_spec.rb` for both; that range is the resumed-session/window group.)
- `spec/lain/agent_spec.rb:506-516` compares whole `Request` values with `eq`, and
  `spec/lain/bench/dry_replay_spec.rb:45-52` requires re-rendering every recorded prefix to
  reproduce byte-identical Requests. If substituting a derived projection makes a recorded replay
  irreproducible, stop — that breaks the bench's determinism claim.
- If this card finds itself needing to add a `timeline:` keyword to
  `Agent::PipelineSource#context_for`, stop: that is the ruling in Open decisions being
  contradicted, and it changes a duck `Agent` and its Null both implement.

### T11 — Resolve a compaction strategy from an option name          [wave 3] [risk: medium] ✅ LANDED `697150f`

**Depends on:** T3
**Files:** `lib/lain/cli/compaction_strategy.rb` (create),
`spec/lain/cli/compaction_strategy_spec.rb` (create)
**Shared-file wiring:** `lib/lain/cli.rb` — one require line for `compaction_strategy` (that file
is the `cli/` subtree's index; `lib/lain.rb` carries only `require_relative "lain/cli"`, a
correction the last chunk had to make mid-flight). `exe/lain` — one `method_option
:compact_strategy` line on `chat`, string, defaulting to this class's own `DEFAULT`, whose help
text interpolates the valid set so the flag and the resolver cannot disagree.

**A standalone class, not a `Backend` method.** `CLI::Backend` sits at **108 of 110** on
`Metrics/ClassLength` after the last chunk, so a new resolver method there would cross the cop.
`CLI::IsolationBackend` (`cli/isolation_backend.rb:78`) is the exact precedent for this shape: a
validated name → object resolver in its own class, with `BACKENDS` as the single authority both the
resolution and the help text read, `DEFAULT` for the unset flag, and a loud `Unknown < Error`
naming the valid set.

**Reuse:** `CLI::IsolationBackend` (`cli/isolation_backend.rb:78-130`) line for line — `BACKENDS`
/ `DEFAULT` / `Unknown` / `self.resolve(...) = new(...).backend`. `Backend#validated`
(`cli/backend.rb:299-303`) is the refusal-message voice: name **which** flag was wrong, since
`--provider` and `--compact-strategy` are different mistakes to make.

**Acceptance criteria:**

```gherkin
Scenario: the default resolves to the summarizing strategy
  Given no strategy option
  When a strategy is resolved
  Then it is the summarizing strategy

Scenario: the elision strategy is selectable by name
  Given the elide option
  When a strategy is resolved
  Then it is the elision strategy and it holds no oracle

Scenario: an unknown strategy name is refused by name, listing the valid set
  Given an unrecognized strategy option
  When a strategy is resolved
  Then a Lain::Error is raised naming the flag and every valid strategy

Scenario: the help text and the resolver cannot disagree
  Given the chat command's declared options
  When the strategy flag's help text is read
  Then it names exactly the strategies the resolver accepts

Scenario: the summarizing strategy is resolved with a recorded oracle, never a bare model tier
  Given a journal and the default option
  When a strategy is resolved
  Then the oracle it holds records its answers
```
→ spec file: `spec/lain/cli/compaction_strategy_spec.rb`

**Escalation triggers:**
- `spec/lain/cli/chat_flags_spec.rb` parses `lib/lain/cli/` with Prism and **fails when a flag the
  code reads is declared by no command**. This card's flag must be declared in `exe/lain` in the
  same commit its reader lands, or that spec goes red. That guard exists precisely because the
  last chunk shipped four flags that were never declared.
- If resolving the summarizing strategy requires reaching into `Backend` for the oracle, stop and
  report it: `Backend#eager` is memoized run state and `Backend#pipeline_source` raises `Rebound`
  on a second differing call (`cli/backend.rb:337-345`). The oracle must be injected here, not
  fetched.
- Do not add a resolver method to `CLI::Backend`. It is at 108/110 and the cop would trip; see the
  Orchestrator contract.

### T10 — Document the two lineages          [wave 5] [risk: low] ✅ LANDED `acc7b2f`

**Depends on:** T9
**Files:** `README.md` (modify), `docs/GLOSSARY.md` (modify), `docs/commands.md` (modify),
`CLAUDE.md` (modify), `spec/docs_naming_spec.rb` (create)
**Shared-file wiring:** none. **`ROADMAP.md` is orchestrator-owned** — the chunk's index entry and
its landed marker are the orchestrator's, not this card's.
**Reuse:** README's existing "Compaction and summarizer tiers" section is the place the tier
ladder is already explained; the "Workers can be isolated…" Design section is the shape for
explaining a mechanism plus its honest limits.

Four things need saying, and one correction:

1. The session timeline is the lossless record; the derived context timeline is what the provider
   sees; the derivation edge is journalled and auditable.
2. The strategy seam and the two shipped strategies, with the flags that select them.
3. That derivation is non-recursive today, and that hierarchical derivation, the plan-step
   strategy, and exchange grouping are designed and not built.
4. **`docs/GLOSSARY.md` gains the algebra, and two existing entries gain a second instance.** The
   glossary's house style is a blockquote definition with a source link, then a paragraph on what it
   buys *in lain specifically* — match it, and keep every claim tied to a law the suite actually
   checks. New entries:
   - **Monoid homomorphism** — the law, and the universal property that makes homomorphic and
     elementwise the same condition on a free monoid. This is where `Algebra::Elementwise` is
     explained as structure rather than convention.
   - **Functor** — with lain's instructive *negative*: derivation is not one on the prefix order,
     and the characterization spec that says so. Name the wrong conceptual model it exists to
     prevent.
   - **Fiber (preimage)** — `causal_parents` on a replacement event, and why that means the
     pre/post mapping needs no separate storage.
   - **Interval partition** — cut points among the gaps, the Boolean lattice `2^(n-1)`, and why a
     pin is a cut point rather than a shield.

   Amended entries: **Free monoid** (`GLOSSARY.md:24-32`) currently describes combinator sequences;
   add the second instance — collapse images concatenating, with `DROP` as `ε`.
   **Property-based testing** (`:315-325`) lists the law groups by filename; add
   `monoid_homomorphism.rb`, and say that this is the first group whose *negative* form is also
   asserted.

The correction: **CLAUDE.md and the approved design plan still say `Turn`**, but `Lain::Turn` was
deleted in `61f7e81` and the unit is `Lain::Event` (F7). CLAUDE.md's "Architecture, in one breath"
and its Rust table both name `Turn`.

**Acceptance criteria:**

```gherkin
Scenario: the README explains both lineages and the derivation edge
  Given a reader who has not seen this chunk
  When they read the compaction section
  Then it distinguishes the session timeline from the derived context timeline and says the edge is journalled

Scenario: the strategy seam and its shipped strategies are documented with their flags
  Given the commands doc
  When a reader looks for how to select a compaction strategy
  Then each shipped strategy and its flag are listed with what it costs

Scenario: what is not built is stated rather than implied
  Given the README
  When a reader looks for the limits
  Then non-recursive derivation, the absent plan-step strategy, and the absent exchange grouping are named

Scenario: the glossary explains each new structure in terms of a law the suite checks
  Given the glossary
  When a reader looks up monoid homomorphism, functor, fiber, and interval partition
  Then each entry names the lain object it describes and the shared example group or spec that checks it

Scenario: the glossary records the negative as deliberate
  Given the glossary's functor entry
  When a reader asks whether derivation is incremental
  Then the entry says it is not, names the characterization spec, and says which wrong model that spec exists to prevent

Scenario: CLAUDE.md names Event, not Turn
  Given CLAUDE.md
  When it is grepped for the turn primitive
  Then it names Lain::Event and no longer claims a Turn class exists
```
→ spec file: `spec/docs_naming_spec.rb` — a doc drift guard in the repo's own idiom
(`spec/output_discipline_spec.rb` parses `lib/`; `spec/lain/cli/chat_flags_spec.rb` parses
`lib/lain/cli/`). It asserts the living docs name `Lain::Event` and no longer claim a `Turn` class,
mirroring `spec/lain/event_spec.rb:16`, so this correction cannot silently regress.

**Escalation triggers:**
- Any flag this card documents must exist and be reachable. The last chunk shipped four
  `method_option` lines that never landed, so `spec/lain/cli/chat_flags_spec.rb` now fails when a
  flag the code reads is declared by no command. Verify each documented flag against
  `LainCLI.commands["chat"].options` before writing the row.
- If documenting the derivation requires explaining that it is inert or unreachable on some path,
  say so plainly in the doc — the isolation section is the precedent. Do not describe intended
  behavior as shipped behavior.
- Every algebraic claim in the glossary must point at a law the suite runs. The existing entries do
  this (`Idempotence` names `meet_semilattice.rb`; `Property-based testing` lists the groups), and it
  is what keeps the glossary from becoming aspirational mathematics. If an entry cannot name its
  check, either the check is missing — escalate — or the claim should not be made.

## Integration checks

After the last wave:

1. `bundle exec rake` (compile, full suite, rubocop) green. Expect **> 4697** examples.
2. `cargo test && cargo clippy --all-targets -- -D warnings` green (no Rust in scope here — the
   prerequisite chunk's A5 owns the Rust side; this is the no-regression check).
3. `pre-commit run --all-files` green.
4. Confirm `spec/lain/compaction/head_spec.rb:357-372`'s exhaustive Head/Compact agreement sweep
   still passes, and that the threshold crossovers at `:110-123` and `:249-258` were **updated
   with re-measured numbers**, not deleted.
5. Confirm `spec/lain/context/conversation_spec.rb`'s invariants hold over a rendered request from
   a real compacting `Agent` run, not only over hand-built arrays.
6. Grep a real run's journal for a credential: the derivation record is a new journal writer and
   must carry digests and a strategy name only — never message content, never a path.
7. Re-run the four ephemeral probes from this chunk's Grounding against the finished branch and
   confirm F1, F2, and F3 no longer reproduce.

**Manual passes owed to Joel** (named so they do not silently drop). **Corrected after the wave-4/5
panels — passes 1, 2 and 4 as originally written would mislead.**

1. A long `lain chat` crossing the compaction threshold twice against the real Anthropic API — the
   pass F1 says has never happened. Confirm no 400, and read `lain://request` for the derived
   projection. **Run it twice: once un-flagged (the eager-tier control) and once with
   `--compact-strategy summarizing`.** They are different collapse policies through the same
   derivation, and only the second exercises the model arm.
2. `/pin` a turn mid-history, cross the threshold, and confirm in `lain://request` that the pinned
   turn is verbatim **and still beside its neighbours** (F3's regression). **Expect two different
   outcomes**: a pin that does not strand a tool pair yields the pin sitting *between two
   replacements* (pins are cut points, `keep_last + 3`); a pin whose `tool_use` answer would be
   collapsed makes the derivation **refuse** — the turn renders uncompacted and journals
   `derivation_refused`. The refusal is correct behaviour, not a failure of this pass.
3. A compacting run with `--compact-strategy elide`, confirming no model call is made and the
   attestation lines are readable.
4. Audit a finished session's journal with the T8 reader. **Use a session run under
   `--compact-strategy elide` with no pins.** Per follow-up 21 the default policy's edge names a
   private `Held` class the audit cannot build and whose `SummarySnapshot` input was never
   journalled, and a pinned run re-derives different ranges — so an audit of a default session
   reports failures that are the gap, not drift, and is indistinguishable from a bug in the reader.

## Follow-ups designed here, deliberately not built

1. **Hierarchical (recursive) derivation as a swept arm** (user ruling, this interview). Derive
   the next chain from the previous derived chain rather than from source. Cheaper at extreme
   length; drift accumulates and the derived head stops being a pure function of the source, which
   is exactly why it wants to be measured against the non-recursive arm rather than assumed.
   **F8 gives that card a ready-made guard**: recursion is sound exactly for homomorphic strategies,
   so it can refuse a strategy that is not an `Algebra::Elementwise` rather than silently drifting.
   That is also what keeps `Elementwise` from being a label — it becomes load-bearing at runtime.
2. **The deterministic plan-step strategy** (user, this interview): collapse a completed plan step
   to `"wave 1 done"` with no model call. The seam (T3) makes it expressible;
   `Session#plan_step_completed?` (already read by `Compaction::Need`) is the state it needs. Left
   out to keep this chunk's strategy count at two.
3. **Combining strategies over the cut-point lattice.** F8 notes `#ranges` is an interval partition,
   so two strategies' answers have a canonical common refinement and disjoint range-sets form a
   partial commutative monoid with `Identity` as unit. This chunk needs none of it — one strategy
   runs per derivation — and building the lattice ops now would be speculative generality. It is the
   right shape the day a run wants elide on tool spans and summarize on conversational ones.
4. **Exchange-level reordering** — grouping an orchestrator's back-and-forth with one subagent so
   it collapses as a unit. The API permits moving whole assistant+tool_result exchanges but not
   individual turns; this has the least empirical support of anything discussed and should not be
   built before the grouping is shown to help.
5. **Reconcile or retire `Compaction::Prepared`.** It memoizes a computed compaction keyed by head
   digest, journals `CompactionPrepared`, carries a `Replay` combinator, and has no production
   caller (F6). After T9 there are two objects that hold a computed projection and one of them is
   dead. No card here touches it — deciding whether it becomes the derivation's memo or gets
   deleted is a card of its own.
6. **`causal_parents` now carries three meanings with no discriminator** (panel finding): folded
   mailbox messages (`timeline.rb:56-60`), combined worker heads (`arm/synthesis.rb:66`), and
   subsumed source turns. `Event::KINDS` already has four values and a `:snapshot` kind nobody uses
   much; whether subsumption wants its own kind, or an edge label, is the open question. Nothing
   breaks today because the three are never mixed in one reader, but `Event::Projection#reachable`
   walks all of them transitively.
7. **Retire `Context::Compact`, or keep it as the projection arm.** After T9, two compaction paths
   exist: the combinator (still used by `Bench::PlanSweep`'s reactive baseline,
   `bench/plan_sweep/driver.rb:157`) and the derivation. Deciding whether the combinator is a
   legacy path or a deliberate comparison arm is its own question.
8. **Give `Event::Projection#usage` a production caller.** F7 found it implements
   unique-reachable-digest aggregation but **no production site passes `usage:`**, so the
   correctness claim is spec-only there while `Ledger` carries it live. Two implementations of one
   rule is a seam waiting to be named.
9. **A tool that greps the session timeline.** The derived chain elides; the source keeps
   everything; nothing lets the agent go read what was elided. `Context::Recall` exists and is
   unwired in production (F7) — it is the plausible seam.
10. **`Capability::Policy#resolve` has no caller** (F7). The `requires`/`supports?` resolution is
   fully built and spec'd and never runs, so a provider lacking `:prompt_caching` degrades
   silently rather than loudly. Pre-existing, unrelated to this chunk, recorded because the
   grounding pass found it.
20. **"Journal the edge, re-derive on resume" does not describe resume** (T10, wave 5).
   `Oracle::Recorded.from_journal` has **no compaction caller in `lib/`** — only
   `bench/decider_sweep/arms.rb`. `CLI::CompactionStrategy`'s own header says in capitals that it
   builds the **live path only** and that a resume/replay seam is deliberately not its job. So the
   ruling that named this chunk's central property has carried "on resume" through eleven cards
   while resume does not use it. Nothing built is wrong — the journalled answers genuinely make
   exact re-derivation possible, and T8's audit exercises it — but the capability is **latent**, and
   this is F7's pattern in the ruling layer rather than the code. Wiring it is a card of its own.
21. **The default collapse policy's journalled edge is not re-derivable** (T10 panel, wave 5). An
   un-flagged derivation journals `strategy: "Compaction::Source::Derived::Held"` — a
   `private_constant` whose `#blocks` reads a per-turn `SummarySnapshot` that is never journalled —
   and `DerivationAudit` takes a `name => builder` map nothing shipped can satisfy for that name.
   `ContextDerived` also carries no pin set, so a pinned run re-derives different ranges and the
   audit reports drift nobody made. **The audit works for `elide` without pins and not for the
   default.** Manual pass 4 walks into this; its wording is corrected below.
22. **A refused derivation has already paid for the strategy** (T10 panel, wave 5). A refusal is a
   defer reached *after* `Derived#over`, so under `--compact-strategy summarizing` the model call is
   already made and journalled as an `oracle_answer` whose answer is discarded — and because the
   memo is keyed by span content address, a session that keeps chatting pays it **every turn**. The
   `consecutive` streak makes the refusal visible but says nothing about its cost.
23. **`CLI::CompactionStrategy::DEFAULT` is unreachable and its own comment contradicts what ships**
   (T10 panel, wave 5). `initialize` does `@name = name || DEFAULT` and the constant's doc calls it
   "what an unset flag falls through to", while an unset flag actually means the eager tier — the
   CLI never reaches it only because `Backend::SpanSummarizer` short-circuits first. A future caller
   writing `CompactionStrategy.resolve(options[:compact_strategy])` silently gets summarizing. Two
   smaller siblings: `summarizing.rb:130` claims `CLI::CompactionStrategy` builds
   `Oracle::Recorded.from_journal` "on resume", which that class explicitly disclaims; and
   `derivation.rb:37` says "23 objects" where the spec pins **22**.
16. **`SummarySnapshot`'s attested digest is a fingerprint, not a Store key, and its doc says
   otherwise** (T7 panel, wave 3). `summary_snapshot.rb:41` claims a reader "can always fetch the
   original from the Store". Measured: `#attest` hashes the `{"role"=>, "content"=>}` projection
   shape while the Store is keyed by `Event#digest = Canonical.digest(payload)` (`event.rb:85`) —
   different hash over a different object, so `store.fetch(attested)` raises `MissingObject`. The
   invariant (nothing disappears unattested) holds; the affordance does not. T7 corrected its own
   copy of the sentence; this is the original.
17. **Every attested message is canonically dumped twice** (T7 panel, wave 3). `Canonical.digest(v)`
   calls `dump(v)` internally (`canonical.rb:60`), so one interpolation runs `normalize` +
   `JSON.generate` twice per message. Measured over 200 messages × 4 blocks × 50 collapses: **0.463s
   vs 0.215s, 25204 vs 13603 allocated objects** against a one-dump variant whose output is
   byte-identical. It is `SummarySnapshot#attest`'s idiom and `Strategy::Elide` copies it
   deliberately, so the fix is one shared helper answering both facts off a single dump, applied to
   both call sites. Note the asymmetry: `SummarySnapshot` runs once per compaction, while `Elide` is
   the control arm and runs on every arm of every sweep.
18. **`Algebra::Elementwise`'s generated method is public regardless of the surrounding `private`**
   (T7 panel, wave 3), because `define_method` runs inside the macro and never sees the class body's
   visibility. Benign and correct — but the concern's "The generated method's shape" section
   enumerates arity and block-swallowing and omits visibility, and `Strategy::Base`'s doc example
   prescribes the `private`-then-`elementwise` shape without the caveat. Both belong to the
   prerequisite chunk's files.
19. **A missing generator knob fails as a bare `KeyError`** ("1 error occurred outside of examples")
   rather than a sentence — the only failure in the algebra sweep that does not name its own cause.
   Belongs with the D4 law files.
14. **A pin inside the span can strand its tool counterpart, producing a 400** (T4 panel, wave 2).
   The compacted render is valid with pins off and invalid with a pin that splits a tool pair —
   measured on the real production path, and carried as a characterization spec in
   `spec/lain/context/compact_spec.rb` rather than as a passing claim. The repair is a design
   decision about pin semantics: a pin that would strand its counterpart either **drags the
   counterpart along** or is **dropped with it**. That belongs to `Context::PinnedMessages`, not to
   the compaction path, which is why no card in this chunk took it. T9 carries the matching
   escalation trigger.
15. **Two guards in `Compaction::Boundary` are mutation-verified untested** if a later change removes
   them (T4 panel S2/S3): the by-id (not by-type) pair match, and the re-check at the moved cut's
   destination. T4 added a discriminating fixture for each, so this is closed — recorded because the
   *pattern* recurred twice in one chunk (it is T2's NIT 7 shape), and a guard whose safety is argued
   in prose and asserted nowhere is now a known failure mode for this codebase.
12. **`Context::Conversation` pairs tool blocks by set membership, not multiplicity** (T1 panel
   finding 1, wave 1). Two same-id `tool_use` blocks in one message answered once validate clean,
   which contradicts the object's own invariant 3 as stated for *counts* while holding for
   *positions*. The honest scope is documented at the object rather than implemented, because
   nothing in the codebase produces the shape today. Match-and-consume is the fuller fix; T5 carries
   an escalation trigger in case a derivation ever produces it.
13. **`Boundary#moved` needs a consumer.** The near-decline case — one assistant early in a long
   user run — retains almost the whole history while every predicate reports normally. T4/T5 are
   directed to journal or threshold it (see T4's carry-forward note); if they discharge it only
   partly, this is where the remainder lives.
11. **Adjacent-user-message alternation.** T1's first escalation trigger: `agent_spec.rb:407-410`
   pins `%w[user assistant user user]` as the real Agent shape. If the Messages API forbids
   adjacent user messages, the Agent's own commit shape needs revisiting — a much larger finding
   than this chunk, and one to settle with a live API probe rather than by reading.
