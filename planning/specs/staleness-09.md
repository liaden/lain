# Staleness audit — `simplify-09-operations-as-objects.md`

Audited 2026-09-13 against `main` @ `d4a7a1ea`. Read-only; nothing in `lib/`, `spec/` or the plan
was changed.

The plan's Grounding says *"Verified 2026-09-12 against the working tree at `d2bb133c`"*.
**`d2bb133c` is not an ancestor of HEAD.** History diverged; HEAD carries 327 commits and 693
changed files (+29.5k/−22.4k) that `d2bb133c` does not have, and simplify-01 through simplify-07
all landed inside that window (`status: done` in every one). Every figure below was re-derived
empirically — greps at HEAD, plus one `ruby -Ilib -rlain` load to enumerate the live algebra
registry. **None of the plan's own numbers were trusted.**

---

## Verdicts at a glance

| card | verdict | one-line reason |
|---|---|---|
| T1 — split `Effect::Handler` | **ADJUST** | premise holds and every line cite is still exact, but one of the four "adverbs" (`Summarizing`) has zero production construction sites and its namespace holds a live Observer |
| T2 — one place the handler chain is wired | **ADJUST (half DEAD)** | the `ChildBuilder#gated` ↔ `Switchboard#gate` duplication is real and verified; the `spawn_agent` ↔ `AgentBuild.build` half is **DEAD** — `CLI::Wiring::AgentBuild` does not exist anywhere in the tree |
| T3 — trim the registry | **DEAD as written** | its headline premise was false *at authorship*: `declares?` has a production reader that is not `DerivationAudit`, and every count in the card is wrong |
| T4 — meets off the element | **ADJUST (materially changed)** | timeline.rb line cites are all still exact, but the three declarations are now **mirrored onto `Lain::Ext::Timeline` in `lib/lain.rb`**, the three operations have **zero** `lib/` callers, and six of its eleven Files have no reason to change |
| T5 — name the context pipeline | **ADJUST** | premise fully intact; construction counts, the precedent's line numbers and the header key set all drifted |

---

## T1 — Split `Effect::Handler` on the line between interpreting and decorating

| claim | status | fact at HEAD |
|---|---|---|
| six `Effect::Handler` implementations | **VERIFIED (with a pre-existing arithmetic error)** | `lib/lain/effect/handler/` holds exactly `gate.rb`, `live.rb`, `mock.rb`, `recorded.rb`, `sensitivity.rb`, `summarizing.rb` = 6. `Subagent::RefusingHandler` is a **seventh**, at `lib/lain/tools/subagent/refusing_handler.rb`. The plan's "Of the six handlers, **three interpret** … and **four decorate**" sums to seven. The Grounding table's `effect/handler | 6` counts the directory only. |
| three interpret / four decorate | **VERIFIED as a classification** | `Live`/`Mock`/`Recorded` interpret; `Gate`/`Sensitivity`/`Summarizing`/`RefusingHandler` wrap-and-delegate. |
| meeting line `agent/tool_runner.rb:414` | **DRIFTED (line only)** | now **`:455`**. Text is byte-identical: `@middleware.call({ effect:, context: }, &@handler.to_app).result` |
| "`ToolRunner` already holds a second `@toolset` reference at `:186`" | **DRIFTED (line only)** | the second *reference* is now **`:374`** (`answered_questions`); `:222` is the constructor assignment. The claim stands: `tool_runner.rb` is 459 lines, ctor comment at `:216-217` says `toolset:` "exists for `#answered_questions`' harvest alone". |
| `effect/handler.rb:16-18` states the two shapes are the same | **VERIFIED, exact** | |
| `gate.rb:18-20` objection | **VERIFIED, exact** | "Gate holds NO Toolset of its own — it reads the tier off whatever `inner` resolves the name to (`{Handler#tool_named}`)" |
| `Gate#run` at `gate.rb:94-98` | **VERIFIED, exact** | |
| `Sensitivity#decline` at `sensitivity.rb:97-101` | **VERIFIED, exact** | |
| `Sensitivity#perform` nil-branch at `:70-78` | **VERIFIED, exact** | the comment runs `:71-78`, `def perform` at `:79`. The stated reason is *`LiveSensitivity` re-reads `board.call` on EVERY call*, i.e. straddling a board change. |
| `Recorded#from_journal` reads a `type: "tool_result"` record nothing in `lib/` writes | **VERIFIED — the finding is real** | `recorded.rb:29` is `Journal.records(entries, type: "tool_result")`. The only record types `lib/` writes at top level are `SessionRecord::HEADER_TYPE "session"`, `TURN_TYPE "turn"`, `REWOUND_TYPE "rewound"`, `CHILD_TURN_TYPE "child_turn"`, and `journal.rb:236`'s `"journal_error"`. Every other `"tool_result"` in `lib/` (17 sites) is a **content-block** type nested inside a message, never a record. So `from_journal` builds `{}` on any real journal. |
| `ARCHITECTURE.md:338-339` sells `Recorded` as deterministic-replay | **DRIFTED** | the sentence is now at **`:337-338`**, and it names **`Mock` *and* `Recorded`** — "are the deterministic-replay handlers `CLAUDE.md` refers to". The correction T1 owes is therefore two words wider than the card says. |
| `spec/lain/effect/handler_spec.rb` mentions `Tool::ContractViolation` three times | **VERIFIED** | exactly 3; `live.rb:78-80` special-cases it in prose, exact. |
| Files: `lib/lain/cli/wiring/board_build.rb` | **QUESTIONABLE** | `board_build.rb` constructs `Sensitivity::Policy` / `Sensitivity::Rules`; it builds **no handler**. Handler construction is `switchboard.rb:214-217` and `wiring.rb:482`. |
| Shared-file wiring: "four `require_relative` moves between `lib/lain/effect.rb` and `lib/lain/middleware.rb`" | **WRONG FILE on one side** | `lib/lain/effect.rb` has **one** internal require, `effect/handler` (`:54`). The six subclass requires live at **`lib/lain/effect/handler.rb:77-82`**. `middleware.rb:163-171` is the other side, 9 entries. |

### New fact T1 does not have — and it shrinks the card

**`Effect::Handler::Summarizing` (the decorator) has zero production construction sites.** Nothing
in `lib/` or `exe/` calls `Effect::Handler::Summarizing.new`. What production mounts is
`Effect::Handler::Summarizing::Observer` at **`cli/backend.rb:348`** — an Observer, not a Handler —
and `backend.rb:341-342` says so outright: *"`Summarizing::Observer` is the PRODUCTION mount and
the `Summarizing` decorator its alternative"*. Five further `lib/` sites reason about that
namespace (`oracle/routed_summarizer.rb:51`, `:172`; `agent/tool_runner.rb:30-31`;
`compaction/summary_snapshot.rb:20`, `:92`), and `spec/lain/cli/backend_spec.rb:1159` asserts the
Observer's class.

So moving `Summarizing` into `lib/lain/middleware/` **splits a namespace production reads at six
places**: the decorator would become `Middleware::Summarizing` while `Effect::Handler::Summarizing::Observer`
stays put, or the Observer has to move too and six comments plus one spec assertion go with it.
This is a third answer to the card's own "`Summarizing` … is neither verb nor adverb" escalation
trigger that the card does not anticipate: it is a **dead decorator**, and the live thing wearing
its name is not a handler at all.

### Recommended card edits (T1)

1. Fix the arithmetic: "**seven** handler classes — six under `effect/handler/` plus
   `Subagent::RefusingHandler` — of which three interpret and four decorate."
2. Repoint: meeting line → `agent/tool_runner.rb:455`; second `@toolset` → `:374`.
3. Repoint the ARCHITECTURE correction to **`:337-338`** and note it names **Mock and Recorded**.
4. Correct Shared-file wiring: the requires move out of **`lib/lain/effect/handler.rb:77-82`**, not
   `lib/lain/effect.rb`.
5. Drop `lib/lain/cli/wiring/board_build.rb` from Files unless a concrete need appears.
6. **Add an escalation trigger for `Summarizing`'s dead decorator / live Observer split**, with the
   six reader sites listed. Consider settling it the way the card settles `Recorded`: decide
   whether the decorator is deleted outright rather than moved.

---

## T2 — One place an agent's handler chain is wired

| claim | status | fact at HEAD |
|---|---|---|
| `ChildBuilder#gated` at `subagent.rb:1442-1448` | **DRIFTED (line)** | now **`:1213-1219`** |
| `CLI::Switchboard#gate` at `switchboard.rb:213-218` | **VERIFIED** | `:213-219`; `switchboard.rb` is 479 lines |
| the two build the same `Sensitivity -> Gate -> inner` chain from the same four ingredients | **VERIFIED** | `gated`: `Sensitivity.new(sensitivity: @seam.sensitivity, journal: @seam.journal, inner: Gate.new(policy: @seam.gate_policy, sensitivity: @seam.sensitivity, inner:, denial: @seam.denial.call))`. `#gate`: `Sensitivity.new(sensitivity:, journal: @journal, inner: Gate.new(policy: policy_switch, inner:, sensitivity:, denial:))`. Differ only in `denial` (thunk vs method) and keyword order — exactly as the card says. |
| `spawn_agent` at `subagent.rb:1362-1370` | **DRIFTED (line)** | now **`:1133-1141`** |
| "`spawn_agent` likewise duplicates `CLI::Wiring::AgentBuild.build` (`agent_build.rb:44-55`)" | **DEAD** | `lib/lain/cli/wiring/agent_build.rb` **does not exist**. `lib/lain/cli/wiring/` holds only `askers.rb`, `board_build.rb`, `toolset_build.rb`. The constant `AgentBuild` appears **nowhere** in `lib/`, `spec/` or `exe/` — its only occurrences in the repo are two lines of *simplify-04's own plan prose* (`:812`, `:860`), i.e. a file 04 proposed and never created. The parent's `Agent.new` is inline at **`lib/lain/cli/wiring.rb:485-488`**. |
| the `Seam` has **14 members** | **VERIFIED, exact** | `subagent.rb:755-756`: provider, context_factory, parent, tool_middleware, journal, supervisor, observer, gate_policy, permits, askers, sensitivity, denial, isolation, escalation. |
| `denial` is a thunk on the subagent side, a method on the switchboard side | **VERIFIED** | `@seam.denial.call` at `:1217`; `GENERIC_DENIAL = -> { ... }` at `:407` |
| `agent_build.build` passes `snapshot_slot:` and `spawn_agent` does not | **VERIFIED, repointed** | `wiring.rb:487` passes `snapshot_slot:`; `spawn_agent` (`:1134-1141`) does not. The asymmetry is real; only the file name was wrong. |
| `:handler_union` has zero production callers | **VERIFIED** | `Tool::SpawnPolicy::REGISTRY` (`spawn_policy.rb:295`) holds it, `Role#spawn_policy` (`role.rb:32`) defaults to `:schema`, and **no site in `lib/` or `exe/` ever passes `:handler_union`**. ~25 spec sites do. |
| `ARCHITECTURE.md:417-425` on the two postures' cache economics | **DRIFTED (line)** | now **`:416-424`** |
| simplify-04's T12 moves `Subagent::Leases` out of this file | **FIRED AND RESOLVED** | it landed. `lib/lain/isolation/leases.rb` exists; `subagent.rb` is now **1232 lines**, not the 1,461 the card cites. No coordination is needed any more — the trigger can be retired. |

### Recommended card edits (T2)

1. **Rewrite the `spawn_agent` half.** Replace `CLI::Wiring::AgentBuild.build (agent_build.rb:44-55)`
   with `lib/lain/cli/wiring.rb:485-488` throughout, and swap `lib/lain/cli/wiring/agent_build.rb`
   for `lib/lain/cli/wiring.rb` in Files. Note in the card that the duplication is now
   *inline construction vs `spawn_agent`*, not *builder vs builder* — the "one builder" AC 3 now
   requires **creating** the shared builder rather than reusing an existing one, which is more work
   than the card budgets at `[risk: medium]`.
2. Repoint `#gated` → `:1213-1219`, `spawn_agent` → `:1133-1141`, ARCHITECTURE → `:416-424`.
3. Retire the simplify-04/T12 escalation trigger (satisfied) and update the file size to 1,232 lines.
4. Keep the `snapshot_slot:` trigger verbatim — it is still exactly right.

---

## T3 — Trim the registry to what it is for   **DEAD as written**

### Removal 1 — "the production query surface" is **false, and was false at authorship**

The card says *"`Algebra.registry`'s only non-declaring reader in `lib/` is
`Compaction::DerivationAudit`"*.

- `Compaction::DerivationAudit` is **gone** (simplify-03's T7 landed; `lib/lain/compaction/derivation_audit.rb`
  does not exist). That dependency **is** satisfied.
- But `declares?` has **another production reader**: `Algebra::Pure#pure?` at
  **`lib/lain/algebra/pure.rb:58-60`** —
  `registry.declares?(subject: self.class, operation:, structure: :pure) && Ractor.shareable?(self)`.
- `git show d2bb133c:lib/lain/algebra/pure.rb` has the identical two lines at `:58-59`. **This is
  not drift; the Grounding was wrong when it was written.**
- `pure?` has **zero callers in `lib/`, `exe/` or `bench/`** — but **12 call sites across 5 spec
  files**: `spec/lain/algebra_spec.rb` (×7), `spec/lain/compaction/strategy/elide_spec.rb:128`,
  `elide_tool_observations_spec.rb:178`, `strategy_spec.rb:259`/`:261`, and a naming assertion in
  `summarizing_spec.rb:229`.

**Consequence:** AC 1 — *"the registry has no production reader / none is found"* — **cannot pass**
without also deleting `Algebra::Pure#pure?`, which is a public, spec-exercised API and is not in
T3's Files list, its Intent, or its escalation triggers. That is a second, unscoped deletion.

`refutations` **is** clean: no reader in `lib/` outside `algebra.rb:153` where it is defined. Eight
spec sites read it.

### Removal 2 — the verb counts are wrong in three directions

Measured by loading the library at HEAD (`ruby -Ilib -rlain`, registry enumerated after seal):

```
declarations: 18   refutations: 6   total: 24
declarations by structure:  meet_semilattice 5 · monoid 5 · pure 3 ·
                            commutative_monoid 2 · elementwise 2 · attenuation 1
refutations (all six):
  Lain::Context::PurgeFailedInputs            #call         !elementwise
  Lain::Compaction::Strategy::Summarizing     #blocks       !elementwise
  Lain::Compaction::Strategy::Summarizing     #blocks       !pure
  Lain::Compaction::Strategy::SummarizeConversation #blocks !pure
  Lain::Timeline                              #causal_meets !meet_semilattice
  Lain::Ext::Timeline                         #causal_meets !meet_semilattice
```

| plan says | actually |
|---|---|
| "Six `not_a_*` verbs exist" | **Three** verbs carry the `not_a_*` spelling: `not_a_monoid` (`monoid.rb:36`), `not_a_commutative_monoid` (`commutative_monoid.rb:38`), `not_a_meet_semilattice` (`meet_semilattice.rb:46`). Counting all negative verbs gives **five that file a refutation** (+ `not_pure` `pure.rb:52`, `not_an_attenuation` `attenuation.rb:56`) — plus `not_elementwise` (`elementwise.rb:107`), which **always raises and files nothing**, so it is not a refutation path at all. |
| "Twelve verbs support five entries" | Twelve verbs (6 positive + 6 negative) is right; **six** refutation entries, and one of the twelve cannot file. |
| "only `not_a_meet_semilattice` is used (2 entries: `timeline.rb:185`)" | Still the only verb used — but now from **two call sites**: `timeline.rb:185` **and `lib/lain.rb:153`**. |
| "the other three refutations are filed by calling `Algebra.registry.refute` **directly** — `context/purge_failed_inputs.rb:103`, `compaction/strategy/summarizing.rb:247`, `:253`" | **Four** direct sites. The plan **missed `lib/lain/compaction/strategy/summarize_conversation.rb:90`**. |
| "production already prefers `.refute` (3 sites to 2)" | The ratio is **4 to 2**. The card's argument gets *stronger*; only its number is wrong. |
| "Filed: 24 claims (elementwise 7, meet_semilattice 5, monoid 4, pure 4, attenuation 2, commutative_monoid 2) and 5 refutations" | **18 declarations + 6 refutations = 24 total entries.** The per-structure breakdown matches nothing measured — elementwise is 2, not 7; monoid 5, not 4; pure 3, not 4; attenuation 1, not 2. The plan appears to have counted 24 *entries* and labelled them *claims*. |
| "Sealed at `lib/lain.rb:146`, the file's last statement" | The seal is at **`lib/lain.rb:166`**, and it is **no longer immediately after the requires** — `lib/lain.rb:141-162` now opens `module Lain; module Ext; class Timeline` and files three algebra claims there (see T4). It is still the file's last statement. |

### The escalation trigger about simplify-02's T5 **has fired**, in a shape the card did not predict

The card warns: *"simplify-02's T5 adds a third `not_a_meet_semilattice` call (on `:causal_meets`)…
this card converts three refutations to direct `.refute` calls, not two."*

What actually landed is **not** a third call on `Timeline`. It is a **mirror block on
`Lain::Ext::Timeline`** — the compiled Rust class — inside `lib/lain.rb:141-162`, filing **two
`meet_semilattice` declarations and one `not_a_meet_semilattice` refutation**, with a comment:

> *"Mirrors lib/lain/timeline.rb's three algebra claims and must not drift from them. Declared here
> rather than in `lib/` because the class is the extension's: this is the only point after it loads
> and before the seal."*

So the count is 2 verb call sites and 4 direct sites — and, critically:

**T3's "Shared-file wiring: none — the seal at `lib/lain.rb:146` is unchanged" is now FALSE.**
Dropping the `not_a_*` verbs forces an edit to `lib/lain.rb:153`, which the Orchestrator contract
lists as an orchestrator-owned shared file. T3 acquires a shared-file wiring diff it did not have.

### Recommended card edits (T3)

1. **Rewrite Removal 1 entirely.** Either (a) scope in `Algebra::Pure#pure?` — naming the 12 spec
   sites and adding `spec/lain/algebra_spec.rb`, `spec/lain/compaction/strategy/elide_spec.rb`,
   `elide_tool_observations_spec.rb` and `strategy_spec.rb` to Files — or (b) **drop Removal 1 and
   keep `declares?`**, reducing T3 to the refutation-path question alone. Option (b) makes T3 a
   small, honest card; option (a) roughly doubles it and changes its risk from `low`.
2. Replace every count: three `not_a_*`-spelled verbs / five filing negative verbs / `not_elementwise`
   files nothing; 18 declarations + 6 refutations; **4 direct `.refute` sites to 2 verb sites**;
   add `compaction/strategy/summarize_conversation.rb:90` to Files.
3. Repoint the seal to `lib/lain.rb:166` and strike "the file's last statement following the requires".
4. Change **Shared-file wiring** from "none" to `lib/lain.rb:153` (the `not_a_meet_semilattice` call
   on `Lain::Ext::Timeline`), and say the seal itself still does not move.
5. Rewrite the simplify-02/T5 trigger as a *landed fact*, describing the `Ext::Timeline` mirror.
6. AC 1 must be restated to whichever of (a)/(b) is chosen — as written it asserts something that is
   false today for a reason the card never names.

---

## T4 — Take the three meets off the element and bind them to the store

**`lib/lain/timeline.rb` was not touched in the divergence window. Every line number the card cites
is still exact** — a rare clean result:

| cite | status |
|---|---|
| `:26` `include Algebra::MeetSemilattice`, reason at `:23-25` | **exact** |
| `:28` `class CrossStore < Error; end` | **exact** |
| `:30` `attr_reader :head_digest, :store` | **exact** |
| `:159` `meet_semilattice on: :meet, bottom: "the empty Timeline, per store"` | **exact** |
| `:185` `not_a_meet_semilattice on: :causal_meets` | **exact** |
| `:225` `meet_semilattice on: :dominator_meet, bottom: "…the virtual root, unnameable"` | **exact** |
| `:178` `#causal_meets`, `:215` `#dominator_meet(other, dominators: Dominators.new(store))` | **exact** |
| `:263` `raise CrossStore, "cannot compare Timelines backed by different stores"` | **exact** |
| `:273` / `:281` store-bound inner class, `initialize(store)` / `meets(head_a, head_b)` | **exact** — but the class is named **`CausalAncestry`**, not `Meets` |
| `:329` / `:337` `Dominators#initialize(store)` / `#meet(head_a, head_b)` | **exact** |
| `ledger.rb:109` passes a block to `#ancestors` | **exact** |

`timeline.rb` is 461 lines and reopens `class Timeline` three times (`:22`, `:267`, `:320`).

### Four material drifts

**1. The three declarations are now MIRRORED onto `Lain::Ext::Timeline` — and T4 is silent on it.**

`lib/lain.rb:141-162` files `meet_semilattice on: :meet`, `meet_semilattice on: :dominator_meet`
and `not_a_meet_semilattice on: :causal_meets` against the **Rust extension class**, with a comment
that it *"must not drift"* from `timeline.rb`. T4's whole move is that `is_a?` becomes the
classification because the operations become objects — but `Lain::Ext::Timeline` **stays an element
with three instance methods** and cannot host a store-bound Ruby operation object. So after T4:

- Ruby side: three claims move to `Dag::RenderMeet` / `Dag::DominanceMeet` / `Dag::CausalMeets`.
- Rust side: three claims remain, attached to a class with `on:` keywords — *exactly the shape T4
  argues is unnecessary*, and the "must not drift" invariant now has nothing to mirror.

This is a design question the card must answer, not a wiring detail. It also means T4's edits to
`lib/lain.rb` go far past the "manifest lines placed before `timeline`" the Shared-file wiring
promises — it must rewrite or delete the `Ext::Timeline` declaration block. **This is the single
biggest change to T4's shape.**

**2. `Timeline#meet`, `#dominator_meet`, `#causal_meets` and `#diverge_at` have ZERO callers in
`lib/` or `exe/`.** The only `lib/` occurrences outside `timeline.rb` are three *comments*
(`request.rb:96`, `grader/frustration_repair.rb:34`, `bench/rewrites.rb:6`) and the two
`lib/lain.rb` declaration lines. So:

- The card's **Reachable from** — *"`Timeline#meet` is reached from the compaction and fork paths"* —
  is **false**.
- The escalation trigger *"Check the five call sites first"* resolves as **zero call sites**. The
  question "do callers want the timeline back rather than a head?" is answerable from `spec/` alone.
- Risk drops sharply: in Ruby these three operations are **spec-and-law-sweep surface only**
  (16 spec files reference them). The real consumers are the Rust mirror and
  `spec/support/shared_examples/meet_semilattice.rb`.

**3. `Timeline::CrossStore` is asserted by name in EIGHT spec places, not seven.** The seven the
card names are all still at their exact lines — `spec/lain/timeline_spec.rb:185`, `:299`, `:350`;
`spec/lain/rust/dominator_meet_spec.rb:135`, `:176`; `spec/lain/rust/causal_meets_spec.rb:169`;
`spec/lain/rust/store_spec.rb:120`. The card **missed `spec/lain/rust/timeline_spec.rb:233`**
(`expect { left.meet(stranger) }.to raise_error(described_class::CrossStore)`).

The three prose sites the card lists are also exact (`timeline_spec.rb:538`, `algebra_spec.rb:202`,
`spec/support/algebra_generators.rb:15`) — **plus two more it does not list, and they are in `lib/`**:
`lib/lain/algebra/meet_semilattice.rb:29` and `:54` both reason about CrossStore-against-a-stored-bottom.
`meet_semilattice.rb` is in **T3's** Files list, not T4's. Either T4 gains the file or the two cards
must coordinate on it.

**4. Nothing rescues `CrossStore` anywhere.** The escalation trigger *"`CrossStore` may be rescued
somewhere — grep before removing"* **clears**: there is no `rescue` of it in `lib/`, `spec/`, `ext/`
or `crates/`. The Rust side raises `Lain::Ext::Timeline::CrossStore` from `ext/lain/src/lib.rs:1762`
and defines it at `:1967`, which is exactly the "Rust keeps raising the old one either way" the card
already anticipates.

### Files list is internally contradictory

T4 lists these six as "modify": `lib/lain/ledger.rb`, `lib/lain/cli/command/pin.rb`,
`lib/lain/cli/command/rewind.rb`, `lib/lain/cli/goal_driver.rb`, `lib/lain/session_record/scribe.rb`,
`lib/lain/tools/subagent/turn_feed.rb`. All six exist. **All six are `#ancestors` call sites, and
none calls any meet:**

```
ledger.rb:109            timeline.ancestors { |turn| ... }
cli/command/pin.rb:68    @timeline.ancestors.find { ... }
cli/command/rewind.rb:112  timeline.ancestors.to_a
cli/goal_driver.rb:274   timeline.ancestors.find { ... }
session_record/scribe.rb:111, :329   timeline...ancestors.take / take_while
tools/subagent/turn_feed.rb:60       timeline.ancestors.take_while { ... }
```

The card's own escalation trigger says *"this card should **not** touch `#ancestors`"*. So the Files
list names six files the card is forbidden from changing. Drop all six.

### Recommended card edits (T4)

1. **Add the `Lain::Ext::Timeline` mirror (`lib/lain.rb:141-162`) as a first-class part of the card**,
   with a stated decision: keep the Rust-side per-operation claims (and accept the asymmetry), or
   move them too. Widen Shared-file wiring accordingly — this is more than "manifest lines".
2. Rewrite **Reachable from**: the three operations have **no `lib/` callers**; reachability is
   `spec/algebra_laws_spec.rb`'s law sweep, `spec/support/shared_examples/meet_semilattice.rb`, the
   five `spec/lain/rust/*` files and the differential oracle against `ext/lain`.
3. Correct **seven → eight** CrossStore assertions and add `spec/lain/rust/timeline_spec.rb:233`.
4. Add the two `lib/lain/algebra/meet_semilattice.rb` prose sites (`:29`, `:54`) to the re-read list,
   and coordinate that file with T3.
5. Drop the six `#ancestors`-only files from Files; add `lib/lain.rb`.
6. Mark the "CrossStore may be rescued" trigger **discharged — zero rescues found**.
7. Rename the card's `Meets` reference to **`CausalAncestry`**.
8. Reconsider `[risk: high]`: with zero production callers the blast radius is spec-and-Rust-mirror,
   which is a different kind of risk (differential-oracle drift) than the card describes.

---

## T5 — Give the context pipeline a name, a resolver, and a journal field

| claim | status | fact at HEAD |
|---|---|---|
| `context.rb:39-41` `self.pipeline(workspace) = Reminder.new(workspace:) >> CacheBreakpoints.new` | **VERIFIED, exact** | |
| `Context::REQUIRES` at `context.rb:48`, derived from `pipeline(Workspace.empty)` | **VERIFIED, exact** | as is the `:37` "single source" comment and the `:76` "never shortcut to the REQUIRES constant" comment |
| `Backend#context` (`cli/backend.rb:236`) passes no `pipeline:` | **DRIFTED (line)** | now **`:234-237`**; claim holds — `Context.new(model:, max_tokens:, extra:, system:)` only |
| `Role#child_context` (`role.rb:62`) calls `Context.new` omitting `pipeline:` | **VERIFIED, exact** | and there is **no comment saying the omission is deliberate** — the card's "read both sites before assuming it's a bug" trigger resolves toward AC 4 as written |
| `Tool::SpawnPolicy` (`spawn_policy.rb:198`) likewise | **DRIFTED (line)** | `Context.new` is at **`:196`**; claim holds |
| `compaction/source.rb:589` swaps the pipeline **per turn** | **VERIFIED, exact** | `compacted ? base.with_pipeline(pipeline) : base` |
| `Prune` 0 / `DedupeToolCalls` 0 / `PurgeFailedInputs` 0 construction sites | **VERIFIED** | zero in `lib/`, `bench/`, `exe/` |
| `Mailbox` 0 "as of 2026-09-13" | **VERIFIED** | zero; `Supervisor::TurnMailbox` is gone (simplify-04 T11 landed). The card's own re-ground instruction is satisfied. |
| `Recall` 2, "both `bench/sweep.rb:192`" | **DRIFTED — it is 1, at a different line** | `Context::Recall.new` appears **once**, at **`bench/sweep.rb:190`**. `bench/sweep.rb:182` is `Grader::Recall.new` — a different class in a different namespace. |
| `Compact` 2 (`plan/linear_rewrite.rb`, `bench/plan_sweep`) | **VERIFIED** | `plan/linear_rewrite.rb:98`, `bench/plan_sweep/driver.rb:168` |
| "Of `context/`'s **714** code lines, roughly **107** are reachable and always on" | **half DRIFTED** | `lib/lain/context/*.rb` is **633** non-blank non-comment lines across 16 files (11 are combinators; `base`, `conversation`, `message_envelope`, `model_switch`, `static_model` are not). The **107** figure is **exactly right**: `reminder.rb + cache_breakpoints.rb + base.rb` = 107. |
| `SessionRecord.header` "complete key set is `context_class`, `model`, `max_tokens`, `system`, `stream`, `extra`, `head`, `tools`, `reminders`" | **INCOMPLETE** | `session_record.rb:43-50` also writes **`"type" => HEADER_TYPE`** (`"session"`) and conditionally merges **`"resumed_from"`**. `context_class` is `context.class.name`, so it does read `"Lain::Context"` in every real run — the card's point stands. |
| `CLI::CompactionStrategy` precedent: "one authority constant (`:120`)", "315 code lines of strategies behind a 62-line resolver" | **DRIFTED** | the authority constant is **`STRATEGIES` at `:107`** (`%w[summarizing elide summarize-conversation elide-tools]`); `SEPARATOR` `:111`, `DEFAULT` `:126`. The file is **296 lines**, not 62. `lib/lain/compaction/strategy/` holds 8 files. |
| "deliberately no Thor default (`exe/lain:817-826`)" | **DRIFTED (line)** | the `method_option :compact_strategy` is at **`exe/lain:829`**; the comment explaining why there is no default runs **`:820-828`**. `exe/lain` is 1158 lines. |
| `ARCHITECTURE.md:1008` claims `bench sweep` enumerates combinator words | **DRIFTED (line)** | `:1008` is the algebra registry mermaid diagram. The sentence the card means is at **`ARCHITECTURE.md:1035`**: *"…the length, and `lain bench sweep` walks the words mechanically."* |

### Two new facts T5 should carry

**1. A second real context pipeline already exists in the tree.**
`lib/lain/bench/plan_sweep/driver.rb:40`:
```ruby
BASE_PIPELINE = Ractor.make_shareable(->(_workspace) { Context::CacheBreakpoints.new })
```
threaded as `pipeline:` through `Plan::Runner#run` at `driver.rb:110`. This is a working example of
the `->(workspace)` provider form the card wants to catalogue, it is the *only* non-default pipeline
in production-adjacent code, and it belongs in the resolver's initial catalog. It also sits in a
subtree **simplify-08 edits** (see collisions).

**2. `pipeline` is already an overloaded word, three ways.** `Plan::Runner#run(timeline:, pipeline:)`
and `Plan::SeamPolicy` mean a *plan step pipeline*; `Exec::Local.new(pipeline: Shell::Pipeline.new)`
means a *shell pipeline*; `Context.new(pipeline:)` is the one this card names. The flag name
`--context-pipeline` is therefore correct and the card should say *why* — a bare `--pipeline` would
be genuinely ambiguous in this codebase.

Also worth citing: **`compaction/source.rb:308`** already states the defect T5 exists to fix —
*"writes the record is handed a pipeline and cannot name the policy"*.

### Recommended card edits (T5)

1. Repoint: `backend.rb:234`, `spawn_policy.rb:196`, `exe/lain:829`, `ARCHITECTURE.md:1035`,
   `compaction_strategy.rb:107` (authority = `STRATEGIES`), and correct "62-line resolver" → 296 lines.
2. Fix `Recall`: **1** site, at `bench/sweep.rb:190`; note `:182` is the unrelated `Grader::Recall`.
3. Fix `context/` to **633** code lines; keep 107 (verified exact).
4. Complete the `SessionRecord.header` key set with `type` and the conditional `resumed_from`.
5. Add `bench/plan_sweep/driver.rb:40`'s `BASE_PIPELINE` as a catalog seed and a `pipeline:` precedent.
6. Record that `role.rb:62` carries **no** comment justifying the omission, so AC 4 stands as written.
7. Add the `pipeline` name-collision note.

---

## Cross-plan collisions

09 will run alongside **simplify-08** (bench/arm/compare/`exe/lain`) and **simplify-10** (spec hygiene).
Declared-shared files plus every real overlap found:

### 09 ∩ 08

| file | how | severity |
|---|---|---|
| `exe/lain` | 09/T5 adds `--context-pipeline` to `chat`; 08 edits bench subcommands | **known** — orchestrator-owned; serialize |
| `lib/lain.rb` | 09/T3 (`:153`), 09/T4 (`Ext::Timeline` block + manifest), 08 (manifest lines) | **known** — orchestrator-owned |
| `lain.gemspec`, `.rubocop.yml` | both declare them | **known** |
| **`ARCHITECTURE.md`** | 08 modifies it; 09/T1 must correct `:337-338` (Recorded) and 09/T2 cites `:416-424`, 09/T5 cites `:1035` | **UNDECLARED** — 09's Orchestrator contract does **not** list `ARCHITECTURE.md` as shared. Any 08 edit invalidates all three of 09's line cites. **Add it to the shared list.** |
| **`lib/lain/dsl_catalog.rb`** | 08 modifies it; 09's Grounding names it as *the* resolver mechanism and T5 builds a resolver | **real** — if 08 changes `DSL_PATH` / `def self.builder`, T5's precedent moves under it |
| **`lib/lain/bench/spawn_seam.rb`** | 08 modifies it; 09/T2 reshapes the `Seam` → gate-builder contract, and `Bench::SpawnSeam:119` builds an `Agent` | **real** — `subagent.rb:743` calls it "a DIFFERENT duck", but T2's unification may make it a third caller of the shared builder |
| **`lib/lain/bench/cli/run_recorder.rb`**, **`lib/lain/bench/sweep.rb`** | 08 modifies both; 09/T5's `Recall` count and `run_recorder.rb:59`'s `Agent.new` live there | **real** — 08 can delete the one `Context::Recall.new` site T5 counts |
| `lib/lain/bench/plan_sweep/report.rb` (08) vs `driver.rb` (09/T5's new `BASE_PIPELINE` fact) | same subtree | **watch** |

### 09 ∩ 10

| file | how | severity |
|---|---|---|
| `lib/lain.rb`, `.rubocop.yml`, `spec/spec_helper.rb` | both declare them | **known** |
| **`spec/lain/tools/subagent_spec.rb`** | 10 modifies it; 09/T2's AC 4 targets it | **real, direct** — same file, same wave window |
| **`spec/support/algebra_generators.rb`** | 09/T4 modifies it explicitly; 10's Files carries a `support/**/*.rb` glob | **real** — a glob-scoped sweep will collide with T4's targeted edit |
| **`spec/support/shared_examples/elementwise.rb`** | 10 modifies it; 09/T3 edits `algebra/elementwise.rb` and `spec/algebra_laws_spec.rb` | **real** — the shared example is what holds `elementwise` claims to their laws; T3 changes what gets filed |
| **`lib/lain/refusals.rb`** + **`refusal_width_discipline_spec.rb`** | 10 owns both; 09/T1's collapse changes refusal sentences and 09/T4 renames the `CrossStore` refusal | **real** — new/changed refusal text must satisfy 10's width discipline. 09's own Integration checks already flag "any changed refusal sentence from T1's collapse". |
| `spec/support/tags.rb` | 10 modifies it; 09 adds no tags | low |

### 08 ∩ 10 (for the orchestrator's awareness)
`lib/lain.rb`, `.rubocop.yml`, `spec/spec_helper.rb` — the same three-way shared set.

**Net:** the three-way contention is `lib/lain.rb`, `.rubocop.yml`, `spec/spec_helper.rb`,
`exe/lain` (09/08), and `ARCHITECTURE.md` (09/08) — the last of which 09 has not declared.

---

## Recommended wave changes

1. **Re-ground the plan before running any card.** Change the Grounding header to
   *"Verified 2026-09-13 against `d4a7a1ea`"* and apply the per-card corrections above. Roughly
   two-thirds of the plan's numeric claims are wrong; `timeline.rb`'s and `context.rb`'s are the
   two clean exceptions.

2. **T3 must be rewritten or dropped from the wave.** Its Removal 1 rests on a claim that was false
   at authorship (`Algebra::Pure#pure?` reads `declares?`), and AC 1 as written cannot pass. If the
   panel takes the narrow option — keep `declares?`, drop only the `not_a_*` verbs — T3 becomes a
   ~30-minute card and could merge into T4's commit, since both now edit `lib/lain.rb`'s
   `Ext::Timeline` block and `algebra/meet_semilattice.rb`. **Recommend: fold the narrow T3 into T4,
   or re-scope T3 to explicitly include `pure?` and its 12 spec sites.**

3. **T4 needs a new decision recorded before it starts** — what happens to the
   `Lain::Ext::Timeline` mirror in `lib/lain.rb:141-162`. This did not exist when the plan was
   written and it is the load-bearing complication. It also makes T4's "manifest lines" wiring a
   substantive shared-file edit, which the orchestrator must sequence.

4. **The T3←T4 ordering argument is now stronger, not weaker.** Both cards edit *the same
   `lib/lain.rb` declaration block* as well as `timeline.rb`. Keep T4 in wave 1 and T3 strictly
   after it, exactly as the plan says — and note that T3's Shared-file wiring is no longer "none".

5. **T2 should move out of the "medium risk / deduplicate" framing.** With `AgentBuild` non-existent,
   AC 3 ("both were built by the same builder") requires *writing* the builder and rewiring
   `lib/lain/cli/wiring.rb:485-488`, which is the parent's live chat path. Either re-scope T2 to the
   `#gated` ↔ `#gate` half only (which is genuinely a deduplication and genuinely medium), or
   re-rate it high and add `lib/lain/cli/wiring.rb` to the shared-file list.

6. **Add `ARCHITECTURE.md` to 09's Orchestrator-contract shared-file list** — T1 must edit it, T2 and
   T5 cite it, and simplify-08 edits it concurrently.

7. **Sequence against 10 on `spec/support/`.** 10's `support/**/*.rb` glob will collide with T4's
   targeted `algebra_generators.rb` edit and with T3's elementwise shared example. Either 09's
   algebra cards land first, or 10 excludes `spec/support/algebra_generators.rb` and
   `spec/support/shared_examples/elementwise.rb` from its sweep.

8. **Sequence against 08 on the bench subtree.** T5's `Recall` count and its new `BASE_PIPELINE`
   catalog seed both live in files 08 rewrites. T5 should either precede 08's bench cards or take
   its combinator census as a card-time measurement rather than a plan-time figure.

9. **Two escalation triggers can be retired as satisfied:** simplify-04's T12 (`Subagent::Leases`
   moved; `subagent.rb` is 1,232 lines) and T4's "`CrossStore` may be rescued somewhere" (zero
   rescues anywhere in the tree).

10. **Two findings the plan reports rather than fixes both survive verification** and should be kept
    verbatim: `Recorded#from_journal`'s unwritten `"tool_result"` record type, and `:handler_union`'s
    zero production callers. Both are real at HEAD.
