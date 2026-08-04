# Guardable config validation, petgraph graph primitives, and prop_check

status: in-progress
commit-mode: orchestrator-commits
language: ruby + rust
panel: Ruby (Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson) ·
Rust (Raph Levien, Andrew Gallant, Frank McSherry, Ashley Williams) ·
Category theory (Edward Kmett, Philip Wadler — the MeetSemilattice law group is in scope)

## Intent

Three independent streams from the 2026-08-04 "can gems simplify this?" survey, kept in one
chunk because they share no files and parallelise cleanly.

1. **`Lain::Guard` generalises into `Guardable`,** and `Config`'s ~200 lines of hand-rolled
   `check!` methods become declarative ActiveModel validations on throwaway carriers. Config is
   the second consumer that motivates the generalisation: it needs the raised exception to be a
   *named, path-citing* `Lain::Error`, where today `Guard.check!` raises a bare `ArgumentError`.
2. **The Rust `Timeline` gains the union graph.** `petgraph` replaces a hand-rolled
   Cooper/Harvey/Kennedy dominator walk, and `Ext::Timeline` closes three of the four parity
   gaps `planning/rust-parity-gap.md` catalogued.
3. **`prop_check` replaces `rantly`**, and the property net extends to the Gherkin round trip
   and `Canonical` determinism — two invariants currently pinned by one example each.

Satisfies ROADMAP item 23's Rust half in part (the parity gaps; **not** the wiring/seam
decision, which stays item 23's own chunk).

## Grounding

Verified against the working tree on **2026-08-04 at `f2fb5d8`** — five parallel exploration
passes, direct runtime probes, and a full panel re-verification pass. Where a doc and the code
disagreed, the code won.

**A first draft of this plan was rejected by the panel and rebuilt.** Three of its premises were
false, and they are recorded here because the corrected versions are what the cards now rest on:

- The draft proposed making `Config` an ActiveModel value, mutable while validating and sealed
  afterwards. **Probed: `Config::Epics`, `Config::Epics::Gates` and `Config::Answers` are all
  `Data` subclasses** — frozen the instant `new` returns, `Ractor.shareable?` already true. There
  is no mutable window to seal, and `ActiveModel::Attributes` needs writable attributes.
  `Config` itself probes `frozen?=true shareable?=true` today via plain `freeze`
  (`config.rb:583`), so a seal would also have had nothing to do at that level.
- The draft justified overriding the 2026-07-17 Ruby-first ruling by claiming `dag.rs` and
  `Timeline::Tree#flow_predecessors` "disagree about what an edge is". **They implement different
  operators.** `Timeline#meet` is render-edge *by ruling* (`timeline.rb:169-171`;
  `dominator-meet-research-2026-07.md:77` — *"two lawful operators, not one redefined one"*).
  There is no correctness defect. See Decisions for the argument that actually applies.
- The draft was grounded at `1db060f`, three commits stale. `f2fb5d8` rewrote `config.rb` under a
  new `rubocop-yard` regime — see the C2 triggers.

**Config (`lib/lain/config.rb`, 616 lines).**
- Thirteen error classes. `Gates::Refusal` (opens `:147`) and `Answers::Refusal` (opens `:354`)
  already factor the `path ? "#{path}: " : ""` prefix; `Epics::NotATable`, `UnknownKeys` and
  `InvalidHome` each rebuild it by hand.
- Messages are computed from the **offending values** (`UnknownKeys.new(keys, path:)` where
  `keys` is a computed set difference), not from an attribute name. ActiveModel's error set
  carries `attribute` + `message` and cannot reconstruct these — this is what shapes C3/C4.
- `spec/lain/config_spec.rb` is 776 lines / **82 examples**, dominated by exact-message
  assertions. First `be_deeply_frozen` site is `:491` (not 490); the others are `:585`, `:692`,
  `:743`.
- Load order: `lain/config` is manifest line 14, `lain/guard` 26, `lain/approval` 58,
  `lain/epic` 77. `Epic::STAGES` and `Approval::Gate::Policies` are read only inside method
  bodies today, at call time. `Gates::EMPTY` (`:255`) is built at file-load time and survives
  only because `check!` returns early on an empty table (`:228`).
- `Config.load` is called as a default kwarg at four CLI entry points — `cli/epic.rb:155`,
  `cli/epic_mount.rb:124`, `cli/epic_submit.rb:260`, `cli/epic_land.rb:181`.
- **`Style/Documentation: AllowedConstants` lists `Epics` and `Gates` but NOT `Answers`** —
  `Answers` recurs in two `lib/` files, and `.rubocop.yml:50-53` states that listing a recurring
  name would blind the cop repo-wide. So `Answers` carries its documentation **on the reopen**.

**`Guardable`'s design is probed, not proposed.** Run on ruby 4.0.6 against a `Data` value
shaped like `Config::Epics` — `include Guardable`, a `guard do … end` block, and `check!` called
from the constructor before `super`:

```
Data value frozen?    true
Data value shareable? true
value ivars:          []          <- no ActiveModel residue on the value
refusal:              ArgumentError: home is not included in the list
```

Three things that verification settles: `Class.new(Lain::Guard, &block)` evaluates the block in
the carrier's scope, so the DSL needs no `instance_eval` gymnastics; a custom `raising:` class
comes through (`Thing::Bad`); and **`inclusion: { in: ->(_) { … } }` defers constant resolution
to validation time**, which is the mechanism that keeps `Epic::STAGES` out of the class body and
the manifest order intact. An anonymous carrier's `model_name` falls back to `"Guard"`, exactly
as `guard.rb:30-33` anticipates for a carrier "built by a DSL".

**`lib/lain/guard.rb` (51 lines).** `class Guard` includes `ActiveModel::Model` +
`ActiveModel::Attributes`; `.model_name` (`:34`) already anticipates an anonymous carrier "built
by a DSL"; `.check!(**attrs)` (`:43`) builds, validates, and raises `ArgumentError` with
`"#{error.attribute} #{error.message}"` joined by `", "`. Its docstring (`:8-15`) is the
authority on why a frozen value must never include `ActiveModel::Validations`. Five live
consumers: `channel.rb:107-115`, `approval/signoff_queue.rb:72-119` (uses `message:` overrides
with `%<value>s`), `question.rb:375`, `improvement.rb:104`, `telemetry.rb:39` (a `Guards` module
when a namespace has several).

**Rust (`ext/lain/`).**
- `dag.rs` (698 lines): seven public functions, **every one follows `render_parent` only**.
  Nineteen `#[test]`s; the four laws are fenced at `:390-403`.
- **The hard blocker:** `Ext::Timeline#commit` (`lib.rs:1306`) reads kwargs
  `["role","content"]` + optional `["meta"]` and hard-codes `Vec::new()` at `:1325`. No union
  graph exists on the Rust side. `read_causal_parents` (`:895`) already exists and is called by
  `Turn::new` (`:969`); `normalize_causal` (`event.rs:321`) already sorts and dedups.
- `Ext::Timeline` has no `#dominator_meet`, no `#causal_meets`, no dominance predicate.
- Ruby's `Dominators#meet` returns **nil** for disjoint heads (`timeline.rb:331-337`);
  `dominator_meet` `checkout`s that to the empty Timeline (`:211`), and the in-code note says the
  empty Timeline **absorbs** (`:330`). The declared bottom is prose (`:219`).
- Ruby scopes each tree to the closure of **the queried pair** (`Tree.new(@store, key)`,
  `timeline.rb:335`, `:393-394`) and memoizes by sorted head-digest pair (`:331-337`) — the
  TL-3 ruling pinned *"computed on demand, memoized by head digest"*.
- The fourth law is checked through an injected `ancestor_of:` which
  `spec/support/algebra_generators.rb:183-190` supplies as **`dominators.dominates?`**, not
  `ancestor_of?` — `timeline.rb:339-341` says the render-ancestry predicate is "strictly weaker".
- **petgraph 0.8.1** read out of the `.crate` tarball in `~/.cargo/registry/cache` (only 0.6.5 is
  unpacked under `registry/src/` — do not read that one): `MIT OR Apache-2.0`,
  `algo::dominators::simple_fast` at `src/algo/dominators.rs:164`, with `immediate_dominator`,
  `strict_dominators`, `dominators`. Wave layering is **not** in petgraph. It pulls
  `fixedbitset`, `hashbrown`, `indexmap` into the workspace lock.
- `Cargo.lock` is at the **workspace root**, shared with `crates/lain-core`.
- `ext/lain/CLAUDE.md`: **`cargo test` never compiles the magnus surface**, so green tests are
  not a building crate — `cargo clippy --all-targets -- -D warnings` or `rake compile` is the
  gate. A module carrying a law needs its own scoped
  `#[deny(clippy::missing_docs_in_private_items)]`. No `forbid(unsafe_code)` in this crate. Its
  "190/190 tests" line is stale — the actual count is **216**.
- All three meets have **zero production callers** anywhere in `lib/`, `exe/`, `bin/`, `plugin/`.
  `#meet`'s only `lib/` caller is `#diverge_at` (`timeline.rb:159`), which itself has none.

**prop_check / rantly.**
- `rantly` appears in **one file, three call sites** — `spec/support/shared_examples/monoid.rb:55,
  63, 87` — and every one is `property_of { true }.check do`. The generator handed to the engine
  is the constant `true`; it is a `100.times` loop.
- `prop_check` 1.0.2, **zero transitive dependencies**. Spiked on branch `spike/gems`
  (`9f3ddf6`, worktree `../lain-spike-gems`): suite green at 9457 examples / 18s.
- Spike-measured gotchas: the global `aggregate_failures` (`spec/spec_helper.rb:58`) **defeats
  shrinking** — property examples need `aggregate_failures: false`, which `spec_helper.rb:55`
  documents as the opt-out; and prop_check has **no seeded replay** (`property.rb:334` does a
  bare `rng = Random.new`).
- `canonical_laws.rb:42-50` tests key-order invariance with 5 hardcoded keys and
  `10.times { shuffle }`. The Gherkin round trip has **exactly one** example
  (`spec/lain/gherkin_spec.rb:263-268`). Rust canonical nesting is pinned at
  `spec/lain/rust/canonical_spec.rb:72`, bound **≤100** (100 accepted, 101 raises).
- Gherkin refusals, verified: `gherkin.rb:216` colon-token; `:227` an empty scenario **name**;
  `:240` an empty **clause**; `:242` a leading `And`. **`#` comments are NOT refused** —
  `dispatch` (`:205-213`) routes `ignorable?` to nil.

## Decisions pinned in this plan (2026-08-04 interview)

- **`Guardable`, not a seal.** Joel's seal/lifecycle idea was verified sound in the abstract
  (`Ractor.make_shareable` does restore shareability after `valid?`) but does not fit these
  objects — they are `Data`, frozen at birth. The repo's own answer applies instead
  (`guard.rb:8-15`): validate on a throwaway carrier the value never touches. Joel's follow-up
  ask — generalise it as `Guardable` so there is one mechanism — is what C1 builds, and Config
  is the second consumer that earns it.
- **The 2026-07-17 "Ruby-first" deferral is superseded, on narrower grounds than the first
  draft claimed.** There is no correctness defect to fix. The argument is: (a) the prefer-crates
  rule — `Timeline::Tree` hand-rolls a published algorithm that `petgraph` implements; (b)
  capability — `dag.rs` defers causal projections "until a bench shows them hot", which orders
  the work backwards if they are wanted at all; (c) Joel's explicit direction that the five rules
  are guidelines weighed against tradeoffs, not absolutes. **Rule 3 fails outright and knowingly:
  these operators have no production caller.** This is speculative infrastructure, accepted as
  such. If that is not acceptable, cut Stream R — it is severable.
- **The graph code stays inside `ext/lain`** (no new workspace crate). Recorded cost: it lives in
  a `cdylib` and is **not liftable to another codebase as-is**. Extracting to
  `crates/lain-graph` later is a known move.
- **cucumber-gherkin is rejected.** The corpus is 600 fenced blocks across 40 files with **zero**
  `Feature:`, `Outline`, `Examples:`, tags, DocStrings, or tables, while the continuation fold
  600 fences rely on has no Gherkin equivalent, and any change to `canonical`'s key set
  re-addresses every criteria. The parser stays and gains properties instead.
- **`Epic::Graph::Blocking` is out of scope**, deferred to a follow-up.
- **The per-use-site meet axis is framing for a future chunk, not built here.** The three meets
  answer different questions and are not interchangeable arms.
- **Error messages are preserved byte-for-byte in Stream C.** All thirteen named classes stay.
  Stream C is a structure win, not a line-count win.

## Open decisions

None gating. Every card below is runnable as specified.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, **wiring diffs only**): `lib/lain.rb`, `lain.gemspec`,
  `.rubocop.yml`, `spec/spec_helper.rb`.
- **Two exceptions, stated so no card is surprised:**
  - `Gemfile` / `Gemfile.lock` — P1 owns the rantly→prop_check swap outright, because a card
    whose gem is not in the bundle cannot run its own specs.
  - `ext/lain/Cargo.toml`, the workspace-root `Cargo.lock`, and the `mod graph;` line in
    `ext/lain/src/lib.rs` — **R1 owns all three.** A Rust module absent from the build graph is
    never compiled and `cargo test` reports green having never seen it; `ext/lain/CLAUDE.md:44`
    names this exact trap. R1 declares `mod graph;` against a stub so R2 has something to fill.
- **`ext/lain/src/lib.rs` is otherwise NOT orchestrator-owned.** R1, R3 and R4 make substantive
  edits and list it under Files; the orchestrator serialises them **R1 → R3 → R4**.
- Substantive-edit chains the orchestrator serialises: `ext/lain/src/lib.rs` (R1→R3→R4),
  `lib/lain/guard.rb` (C1 only), `lib/lain/config.rb` (C2 only),
  `lib/lain/config/*.rb` (C2→C3, C2→C4), `spec/lain/config/*_spec.rb` (C2→C3, C2→C4),
  `spec/lain/rust/timeline_spec.rb` (R1→R5).

## Waves

```
Wave 1: C1, C2, R1, P1              (no unmet deps)
Wave 2: C3 (←C1,C2), C4 (←C1,C2), R2 (←R1), P2 (←P1), P3 (←P1)
Wave 3: R3 (←R2)
Wave 4: R4 (←R3), R5 (←R3)
```

Critical path: **R1 → R2 → R3 → R4** (four deep). Stream C finishes in wave 2 and Stream P in
wave 2; the Rust chain is the whole tail, because three of its cards edit `lib.rs` and cannot
overlap.

## Tasks

### C1 — Extract `Guardable` from `Guard`   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/guardable.rb` (new), `lib/lain/guard.rb`, `spec/lain/guardable_spec.rb`
(new), `spec/lain/guard_spec.rb`
**Reuse:** `lib/lain/guard.rb` in full — `Guard` becomes a thin class that `include Guardable`,
so there is ONE mechanism with two entry points, not two mechanisms. `ActiveSupport::Concern` is
the sanctioned extraction tool (root `CLAUDE.md`, "Code style"). `Guard.model_name` (`:34`)
already handles the anonymous-carrier case a DSL creates.

**The API, as probed:** a `guard do … end` block that builds an anonymous `Guard` subclass for
the including class and evaluates the block in that subclass's scope, so `attribute` and
`validates` read exactly as they do in a named `Guard` today. It takes a `raising:` keyword
defaulting to `ArgumentError`.

```ruby
guard raising: SomeNamedError do
  attribute :home, :string
  validates :home, inclusion: { in: ->(_) { HOME_VALUES } }   # deferred to validation time
end
```
**Shared-file wiring:** one line — `require_relative "lain/guardable"` in `lib/lain.rb`,
**before** `lain/guard` (line 26) and before `lain/config` (line 14) if C3/C4 are to use it.

**Acceptance criteria:**

```gherkin
Scenario: a value class declares its guard in a block
  Given a Data value class that includes Guardable and declares a guard block
  When it is constructed with an attribute its guard refuses
  Then construction raises, naming the offending attribute

Scenario: the value carries no ActiveModel residue
  Given a Data value class that includes Guardable
  When it is constructed successfully
  Then it is deeply frozen and holds none of ActiveModel's instance variables

Scenario: the raised exception class is the declarer's choice
  Given a guard block declaring a named error class to raise
  When that guard refuses
  Then the named class is raised, not ArgumentError

Scenario: a guard defaults to ArgumentError
  Given a guard block declaring no error class
  When that guard refuses
  Then ArgumentError is raised, as Guard.check! raises today

Scenario: a validation may name a constant that loads after this file
  Given a guard whose inclusion set is supplied by a lambda
  When the class body is evaluated during require
  Then the constant is not resolved until a value is actually validated

Scenario: the existing Guard subclasses are unchanged
  Given the five existing Guard consumers
  When each is constructed with input its guard refuses
  Then each still raises ArgumentError with the message it raised before
```
→ spec files: `spec/lain/guardable_spec.rb`, `spec/lain/guard_spec.rb`

**Escalation triggers:**
- `approval/signoff_queue.rb:72-119` uses ActiveModel `message:` overrides containing
  `%<value>s`. If `Guardable` changes how a message is interpolated, STOP — those messages are
  pinned by that file's spec.
- `Guard.check!` currently joins **all** errors with `", "` (`guard.rb:47`), not just the first.
  Preserve that; several specs match on a multi-error string.
- `Guardable` must be requirable **before** `lain/config` (manifest line 14) without dragging
  `approval` or `epic` in. If it cannot load that early, STOP — this inverts the manifest and
  breaks `require "lain"` entirely, which is every spec at once.
- The carrier class is held in a **class-level instance variable**, which
  `rubocop-thread_safety`'s `ClassInstanceVariable` cop exists to flag. It is written once at
  class-definition time and only read afterwards, so it is safe — but if the cop fires, resolve
  it by making the state genuinely immutable, never by loosening the cop (root `CLAUDE.md`).
- **`raising:` is per-guard, not per-rule.** Config needs a *different* named class per broken
  rule (`UnknownKeys` vs `NotATable` vs `InvalidHome`). Do not grow `Guardable` with per-rule
  raisers to serve that — C3/C4 handle it by keeping the closed-set computation in the named
  class. If a card seems to need per-rule raising, STOP and escalate rather than widening this
  concern's surface.

---

### C2 — Split `config.rb` into a `config/` unit   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/config.rb` (becomes the unit index + the `Config` class),
`lib/lain/config/epics.rb` (new), `lib/lain/config/gates.rb` (new),
`lib/lain/config/answers.rb` (new), `spec/lain/config_spec.rb`,
`spec/lain/config/epics_spec.rb` (new), `spec/lain/config/gates_spec.rb` (new),
`spec/lain/config/answers_spec.rb` (new)

The spec splits to mirror the lib split — **every one of the 82 examples moves verbatim**, none
rewritten, added, or dropped. That is what lets C3 and C4 share a wave.
**Reuse:** the unit-index pattern in `lib/lain/context.rb` and `lib/lain/effect/handler.rb` — a
`foo.rb` with a sibling `foo/` requires its children itself, where load order dictates.
**Shared-file wiring:** none — `lib/lain.rb:14` already requires `lain/config`.

**Acceptance criteria:**

```gherkin
Scenario: the split is behaviour-preserving
  Given a project with a valid .lain/config.toml
  When Config.load reads it
  Then every value it answers equals what it answered before the split

Scenario: the load-time EMPTY constants still build
  Given a fresh ruby process
  When it requires "lain"
  Then it succeeds and Config.empty answers a Config

Scenario: the published documentation still describes each class
  Given the split files
  When yard documents Config, Epics, Gates and Answers
  Then each publishes its own class documentation, not a mechanical reopen note
```
→ spec files: `spec/lain/config_spec.rb`, `spec/lain/config/epics_spec.rb`,
`spec/lain/config/gates_spec.rb`, `spec/lain/config/answers_spec.rb` — the existing 82 examples,
redistributed and otherwise unchanged

**Escalation triggers:**
- **The `Data.define` documentation trap, landed in `f2fb5d8` (this is newer than most of the
  file's history).** Nothing may sit above a reopen — prose, `:nodoc:`, even a
  `rubocop:disable` directive becomes the docstring and destroys the real one. The reopen note
  lives *inside* the reopened body. All three moved classes are `Data.define` + reopen pairs.
- **`Style/Documentation: AllowedConstants` lists `Epics` and `Gates` but NOT `Answers`**
  (`.rubocop.yml`), because `Answers` recurs in two `lib/` files and listing it would blind the
  cop repo-wide. `Answers` must keep its documentation **on the reopen**. If the split makes a
  previously-unique name recur, STOP — adding it to `AllowedConstants` is exactly what that
  config comment forbids.
- `Gates::EMPTY` (`config.rb:255`) is built at file-load time and depends on `check!` returning
  early for an empty table. If the split changes when it is built relative to `Epic::STAGES` or
  `Approval::Gate::Policies`, STOP — `require "lain"` fails outright.
- `lib/lain/approval/remembered.rb:113, 294, 297` reach `Config::Answers::TOOL` / `INPUT` /
  `TOOL_WIDE`. If a constant's fully-qualified name moves, STOP.

---

### C3 — Validate Epics and Gates through Guardable   [wave 2] [risk: high]

**Depends on:** C1, C2
**Files:** `lib/lain/config/epics.rb`, `lib/lain/config/gates.rb`,
`spec/lain/config/epics_spec.rb`, `spec/lain/config/gates_spec.rb`
**Reuse:** C1's `Guardable`. The thirteen named error classes stay and become the translation
layer — a guard reports *that* a rule failed; the named class computes the message from the
offending values, exactly as it does now.
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: an unknown epics key is refused with its existing message
  Given a config.toml whose [epics] table carries an unknown key
  When Config.load reads it
  Then it raises Epics::UnknownKeys naming the key, the path, and the known keys

Scenario: an invalid epics_home is refused with its existing message
  Given a config.toml whose epics_home is not xdg or repo
  When Config.load reads it
  Then it raises Epics::InvalidHome naming the value and the permitted values

Scenario: an unknown gate stage is refused with its existing message
  Given a config.toml whose [epics.gates] names a stage the pipeline has not
  When Config.load reads it
  Then it raises Gates::UnknownStages naming the stage and the pipeline

Scenario: a hand-built value refuses identically to a loaded one
  Given a Gates value constructed directly with an unknown stage
  Then it raises the same class with the same message, minus the path prefix

Scenario: requiring lain does not resolve Epic::STAGES at load time
  Given a fresh ruby process
  When it requires "lain"
  Then it succeeds, and no validation declaration has forced Epic or Approval to load early
```
→ spec files: `spec/lain/config/epics_spec.rb`, `spec/lain/config/gates_spec.rb`

**Escalation triggers:**
- **The load-order trap.** `Epic::STAGES` and `Approval::Gate::Policies` must stay resolved at
  *call* time. A class-body `validates ..., inclusion: { in: Epic::STAGES }` resolves during
  `require` and breaks `require "lain"` — config is manifest line 14, epic is 77. Use a lambda
  or `validate :method_name`. If a validation cannot be expressed without a load-time constant,
  STOP.
- **Messages are computed from offending values, not attribute names.** ActiveModel's error set
  carries `attribute` + `message` and cannot reconstruct `"has no keys :a, :b; known keys: …"`.
  If a guard's error set cannot drive the named class's message, keep the closed-set computation
  hand-written and use the guard only for shape. Do NOT change a message to fit the mechanism.
- `Gates#initialize` re-validates (`config.rb:240`) so a hand-built value refuses identically to
  a loaded one (pinned by the moved examples originally at `spec:475-485`, `:536-565`). Preserve
  that; do not validate only in `.from`.
- `Gates::EMPTY` is constructed while this file loads. If a guard runs at that moment and touches
  `Epic::STAGES`, STOP — this is the same total failure C2's trigger names.

---

### C4 — Validate Answers through Guardable   [wave 2] [risk: high]

**Depends on:** C1, C2
**Files:** `lib/lain/config/answers.rb`, `spec/lain/config/answers_spec.rb`
**Reuse:** C1's `Guardable`; `Answers::Refusal` (opens `config.rb:354`) already factors the path
prefix and stays the translation base.
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: a non-list approval key is refused with its existing message
  Given a config.toml whose [approval] allow is not a list of tables
  When Config.load reads it
  Then it raises Answers::NotAList naming the key and the expected shape

Scenario: an entry with no tool name is refused
  Given an [[approval.allow]] entry whose tool is absent or blank
  When Config.load reads it
  Then it raises Answers::MalformedEntry naming the entry and what it needs

Scenario: a non-scalar input value is refused naming the offending keys
  Given an [[approval.allow]] entry whose input holds an array
  When Config.load reads it
  Then it raises Answers::MalformedEntry naming that key as not a scalar

Scenario: remembered answers stay shareable
  Given a config.toml carrying remembered approval answers
  When Config.load reads it
  Then the config and its answers are deeply frozen
```
→ spec file: `spec/lain/config/answers_spec.rb`

**Escalation triggers:**
- `Answers#settled` / `#named` / `#scalars` (`config.rb:512-535`) hand-freeze entries and
  deliberately **dup rather than intern** unbounded String values (`Risk::Keepsake.scalar`'s
  reason). If a rewrite interns them, STOP — that is an unbounded-memory change.
- The example originally at `spec/lain/config_spec.rb:739-743` (moved to
  `spec/lain/config/answers_spec.rb` by C2) asserts the config "stays Ractor-shareable with
  remembered answers aboard". `be_deeply_frozen` is documented as the ONLY spelling of that
  assertion (`spec/support/matchers/be_deeply_frozen.rb:59-65`) — do not add a bare
  `Ractor.shareable?` expectation beside it.
- `approval/remembered.rb:113` reads `Config::Answers::TOOL` / `INPUT` as row keys. Changing the
  entry Hash's key spelling breaks it **silently** — the reader would just find nil. STOP.

---

### R1 — Accept `causal_parents:` on commit, and land the Rust wiring   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `ext/lain/src/lib.rs`, `ext/lain/src/graph.rs` (new, a documented stub),
`ext/lain/Cargo.toml`, `Cargo.lock`, `spec/lain/rust/timeline_spec.rb`
**Reuse:** `read_causal_parents` (`lib.rs:895`) is already called by `Turn::new` (`:969`);
`EventData::turn` (`event.rs:209`) already takes the vector; `normalize_causal` (`event.rs:321`)
already sorts and dedups. Ruby's signature to match is
`Timeline#commit(role:, content:, meta: {}, causal_parents: [])` (`lib/lain/timeline.rb:66`).
**Shared-file wiring:** none — this card owns `Cargo.toml`, `Cargo.lock` and the `mod graph;`
line **by exception** (see the orchestrator contract), because a module absent from the build
graph is silently never compiled.

**Acceptance criteria:**

```gherkin
Scenario: a commit carries its causal parents
  Given an Ext::Timeline with two committed heads
  When a turn is committed naming both as causal parents
  Then the resulting head answers those digests from causal_parents

Scenario: causal parents are normalised as Ruby normalises them
  Given a commit naming the same causal parent twice, out of order
  Then causal_parents answers each digest once, sorted

Scenario: an absent causal_parents is still the empty set
  Given a commit naming no causal parents
  Then causal_parents answers an empty list, as before this card

Scenario: the digest matches Ruby's for the same causal edges
  Given the same role, content and causal parents committed on both implementations
  Then Lain::Timeline and Lain::Ext::Timeline answer the same head digest

Scenario: a causal parent the store does not hold is refused
  Given a commit naming a digest absent from the store
  Then it raises Store::MissingObject with the message Ruby raises
```
→ spec file: `spec/lain/rust/timeline_spec.rb`

**Escalation triggers:**
- The envelope digest is over seven sorted keys including `causal_parents`
  (`event.rs:359-367`), with golden Ruby-computed vectors at `event.rs:542, 550, 613, 626-643`.
  **If any existing golden digest changes, STOP** — this card must not re-address existing
  events.
- Adding petgraph rewrites the **workspace-root** `Cargo.lock` and pulls `fixedbitset`,
  `hashbrown` and `indexmap` into a tree shared with `crates/lain-core`.
  `deny.toml` sets `[bans] multiple-versions = "warn"` — if a duplicate version appears, report
  it rather than silencing it. petgraph is `MIT OR Apache-2.0`, already allowlisted; pin exact
  (`= 0.8.1`), because wildcards are denied.
- `cargo test` does **not** compile the `ffi` module. Run `cargo clippy --all-targets -- -D
  warnings` or `bundle exec rake compile` before believing this card is green. The stub
  `graph.rs` must carry the scoped `#[deny(clippy::missing_docs_in_private_items)]` that
  `mod dag;` carries, since R2 fills it with a law-bearing module.

---

### R2 — A petgraph union-graph module: dominators and causal closure   [wave 2] [risk: high]

**Depends on:** R1
**Files:** `ext/lain/src/graph.rs`
**Reuse:** `dag::StoreMap` (`dag.rs:57`) is the store type. `petgraph::algo::dominators::
simple_fast` is the same Cooper/Harvey/Kennedy algorithm `lib/lain/timeline.rb:359-452`
hand-rolls; `Tree::ROOT` (`:363`) is the virtual-root modelling to mirror.
`Timeline::CausalAncestry` (`timeline.rb:266-311`) specifies the closure: reflexive-transitive
over `[render_parent, *causal_parents]` (`:309`), with `#meets` answering
`maximal(common).sort` (`:275-278`).
**Shared-file wiring:** none — R1 declared the module.

**Acceptance criteria:**

```gherkin
Scenario: the dominator meet is the deepest common dominator
  Given a union graph whose two heads share history through one bottleneck event
  Then the dominator meet of those heads answers that bottleneck

Scenario: disjoint heads meet at the absorbing bottom
  Given two heads in one store with no shared history
  Then their dominator meet answers None rather than an arbitrary node

Scenario: the meet obeys its four laws with None as bottom
  Given a population of heads including at least one pair with no shared history
  Then the meet is idempotent, commutative and associative over Option, and sits below
    both operands, with None absorbing

Scenario: causal edges participate
  Given two events joined only by a causal edge
  Then the dominator meet reflects that edge, unlike a render-only walk

Scenario: the causal meets answer every maximal lower bound
  Given a three-way criss-cross whose heads have two incomparable common ancestors
  Then both are answered, never an arbitrary one

Scenario: a query reads only the ancestry it needs
  Given a store holding many events unrelated to the queried pair
  Then answering a dominator meet does not visit those unrelated events
```
→ spec file: `#[test]`s in `ext/lain/src/graph.rs` (the Ruby parity proof is R5)

**Escalation triggers:**
- **The laws are over `Option<Digest>`, with `None` as the absorbing bottom** — that is what
  Ruby's nil-to-empty-Timeline `checkout` means (`timeline.rb:211`, `:330`). Four law tests over
  a fully-connected population would go green and prove nothing about the boundary the second
  scenario introduces. The population MUST include a disconnected pair.
- **Do NOT add law tests to the causal-meets function.** `causal_meets` is declared
  `not_a_meet_semilattice` (`timeline.rb:179-183`, pinned at `spec/lain/algebra_spec.rb:244-260`)
  because a set-valued operator makes no semilattice claim. If a law appears to hold, the witness
  population is wrong — Ruby's `criss_cross` (`spec/support/algebra_generators.rb:227-232`) is
  deliberately **three-way** so associativity fails under both `.first` and `.last`.
- **Scope and cost.** Ruby builds a tree over the closure of the queried **pair**
  (`timeline.rb:335`, `:393-394`), not the whole store, and memoizes by sorted head-digest pair
  (`:331-337`) — the TL-3 ruling pinned "memoized by head digest". Building a petgraph over the
  entire `StoreMap` per query is a different asymptotic than the code being ported. If pair
  scoping is not achievable, STOP and escalate rather than shipping the whole-store shape.
- The four law tests must be named for their laws and fenced as `dag.rs:390-403` fences its four,
  so the two modules cannot drift about what a law is.
- Stable channel only; no `#![feature]`.

---

### R3 — Expose `dominator_meet` and the dominance predicate   [wave 3] [risk: medium]

**Depends on:** R2
**Files:** `ext/lain/src/lib.rs`, `spec/lain/rust/dominator_meet_spec.rb` (new)
**Reuse:** R2's primitives. Ruby's contract: `dominator_meet` returns a **Timeline** and maps the
virtual root to the empty Timeline via `checkout` (`timeline.rb:209-213`) — `checkout` is
`lib.rs:1373`, and it is `checkout`, not `Timeline::wrap` alone, that supplies the nil handling
the third scenario needs. `Dominators#dominates?` is `timeline.rb:344-349`.
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: the Rust dominator meet answers what Ruby answers
  Given the same union graph built on both implementations
  Then the dominator meet of the same two heads answers the same head digest on each

Scenario: a virtual-root answer is the empty timeline
  Given two heads whose only common dominator is the virtual root
  Then their dominator meet answers an empty timeline rather than exposing the root

Scenario: a cross-store meet is refused
  Given two Ext timelines over different stores
  Then their dominator meet raises CrossStore, as Ruby does

Scenario: the dominance predicate is strictly stronger than render ancestry
  Given a node reachable by render ancestry but not dominated
  Then the dominance predicate answers false where ancestor_of? answers true
```
→ spec file: `spec/lain/rust/dominator_meet_spec.rb`

**Escalation triggers:**
- **The dominance predicate is not optional.** R5's fourth law is checked through an injected
  `ancestor_of:`, and `spec/support/algebra_generators.rb:183-190` supplies
  `dominators.dominates?` — `timeline.rb:339-341` states the render-ancestry predicate is
  "strictly weaker". Wiring R5 to `ancestor_of?` makes meet-below-both pass **vacuously**. If
  this card ships without the predicate, R5 cannot be honest.
- Ruby's `dominator_meet` takes a `dominators:` collaborator holding a **mutable** `@meets` Hash
  (`timeline.rb:322-337`). If exposing an equivalent query object is required, that is a
  SEPARATE card — STOP and escalate rather than growing this one. A mutable memo also interacts
  with the shareability rule below.
- `Timeline` is wrapped `mark` but deliberately **not** `frozen_shareable` (`lib.rs:1195-1200`,
  reasoned at `:719-722`) because it holds a Ruby `Opaque<Value>`. Do not add
  `frozen_shareable` to make a spec pass — STOP.
- If Ruby and Rust disagree on any meet, **Ruby is the oracle** — STOP rather than adjusting Ruby.

---

### R4 — Expose `Ext::Timeline#causal_meets`   [wave 4] [risk: medium]

**Depends on:** R3
**Files:** `ext/lain/src/lib.rs`, `spec/lain/rust/causal_meets_spec.rb` (new)
**Reuse:** R2's closure primitive. Ruby's contract: a **frozen, sorted Array of digest Strings**,
not a Timeline (`timeline.rb:172-176`). Deep-freezing of returned values follows
`Turn::causal_parents` (`lib.rs:1030`).
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: the Rust causal meets answer what Ruby answers
  Given the same criss-cross graph built on both implementations
  Then the causal meets of the same two heads answer the same sorted digests on each

Scenario: the answer is deeply frozen
  Given any causal meets answer from the Rust timeline
  Then the array and every digest in it are frozen and Ractor-shareable

Scenario: heads sharing no causal history answer nothing
  Given two heads with disjoint causal ancestry
  Then the answer is empty rather than an error
```
→ spec file: `spec/lain/rust/causal_meets_spec.rb`

**Escalation triggers:**
- This is the **third** substantive edit to `lib.rs`, behind R1 and R3. If R3 has not landed,
  STOP — the orchestrator serialises this chain.
- Returning an Array of Strings crosses the FFI boundary per element. If the obvious
  implementation calls into Ruby per digest, STOP: `dag.rs:9-11` sets the standard that a walk
  crosses the boundary **once**, with a batched result.
- Do not declare a semilattice on this operator (see R2's trigger).

---

### R5 — Prove the Rust dominator meet against the shared law group   [wave 4] [risk: medium]

**Depends on:** R3
**Files:** `spec/lain/rust/timeline_spec.rb`, `spec/support/algebra_generators.rb`
**Reuse:** `include_examples "a meet semilattice under ancestry"` — the group
`spec/lain/timeline_spec.rb:515` runs against Ruby's `dominator_meet`, configured by the
`meet:` / `ancestor_of:` lambdas at `spec/support/algebra_generators.rb:183-190`.
`MeetSemilatticePopulations.union_graph` is `spec/support/shared_examples/meet_semilattice.rb:85-91`.
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: the Rust dominator meet satisfies the same four laws as Ruby's
  Given a union-graph population built on the Ext timeline, carrying causal edges
  When the shared meet-semilattice group runs against its dominator meet
  Then all four laws hold, with the group's source unchanged

Scenario: the fourth law is checked by dominance, not render ancestry
  Given the population above
  Then the ancestor_of predicate the group is given is the dominance predicate
```
→ spec file: `spec/lain/rust/timeline_spec.rb`

**Escalation triggers:**
- **The vacuous-pass trap, twice over.** If the population comes out a pure render forest (no
  causal edges — needs R1), or the `ancestor_of:` lambda is wired to `ancestor_of?` instead of
  R3's dominance predicate, all four laws pass while proving nothing. Check the population
  actually contains causal edges, and the predicate is the strong one, before believing green.
- The shared group must be included **unchanged**. If it needs an argument it does not take,
  STOP — bending it bends it for Ruby too, and `spec/algebra_laws_spec.rb:21-28` states the group
  is the differential oracle for the port.
- `spec/support/algebra_generators.rb` is a registry read by `spec/algebra_laws_spec.rb`'s
  coverage sweep ("registers exactly one generator per claim: none missing, none orphaned").
  Adding an entry for a Rust subject without a matching `Algebra` declaration fails that sweep —
  if this card needs a new registry key, STOP and escalate.

---

### P1 — Adopt prop_check and retire rantly   [wave 1] [risk: low]

**Depends on:** none
**Files:** `spec/support/prop_check_setup.rb` (new),
`spec/support/shared_examples/monoid.rb`, `spec/lain/usage_spec.rb`,
`spec/lain/middleware_spec.rb`, `Gemfile`, `Gemfile.lock`
**Reuse:** the spike on branch `spike/gems` (`9f3ddf6`, worktree `../lain-spike-gems`) has a
working `prop_check_setup.rb` and a converted shared-example file to lift verbatim.
**Shared-file wiring:** none — this card owns the `Gemfile` swap by exception (see the
orchestrator contract), because its specs cannot run otherwise.

**Acceptance criteria:**

```gherkin
Scenario: the monoid laws still hold for Usage and Middleware
  Given the rewritten shared example groups
  Then Usage satisfies the monoid and commutative monoid laws, and Middleware the monoid laws

Scenario: a broken law reports a minimal counterexample
  Given a deliberately broken commutative operation
  Then the failure names a shrunken counterexample, not a hundred undifferentiated failures
```
→ spec files: `spec/lain/usage_spec.rb`, `spec/lain/middleware_spec.rb`

**Escalation triggers:**
- Property examples **must** carry `aggregate_failures: false`. The global default
  (`spec/spec_helper.rb:58`) collects failures instead of raising, which stops shrinking
  entirely — measured in the spike: the counterexample block disappears and 100 failures are
  reported instead. `spec_helper.rb:55` documents the opt-out.
- `monoid.rb:11` sets `ENV["RANTLY_VERBOSE"]` before requiring rantly and explains it must
  happen before that file first loads. Removing rantly removes that guard; if any other file
  depends on it, STOP.
- prop_check has no seeded replay (`property.rb:334`). Do not write a spec that assumes `--seed`
  reproduces a property failure.
- Confirm rantly's absence from the bundle as part of **Integration checks**, not as an example
  in a subject spec.

---

### P2 — Property-test the Gherkin round trip and digest   [wave 2] [risk: low]

**Depends on:** P1
**Files:** `spec/lain/gherkin_spec.rb`
**Reuse:** P1's `forall` helper. The existing single round-trip example is
`spec/lain/gherkin_spec.rb:263-268`; `Criteria#digest` is `gherkin.rb:82-84`. The generator emits
only the house grammar the corpus uses — `Scenario:` plus `Given|When|Then|And`.
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: rendering and reparsing is identity for any criteria
  Given an arbitrary generated set of scenarios in the house format
  Then rendering and parsing it again yields an equal value

Scenario: the digest is stable across a render and parse cycle
  Given an arbitrary generated set of scenarios
  Then the digest of the reparsed value equals the digest of the original

Scenario: a changed clause changes the address
  Given two generated criteria differing in exactly one clause
  Then their digests differ
```
→ spec file: `spec/lain/gherkin_spec.rb`

**Escalation triggers:**
- The generator must avoid inputs the grammar refuses **by design**, verified as: a clause whose
  first token matches `/\A[A-Z][A-Za-z]*:\z/` (`gherkin.rb:216`); an empty scenario **name**
  (`:227`); an empty **clause text** (`:240`); a leading `And` (`:242`). If the property fails on
  one of these, fix the generator, not the parser.
- **`#` comment lines are NOT refused** — `dispatch` (`:205-213`) routes `ignorable?` to nil, so
  a generated comment is legal input and simply disappears. Do not treat its absence from the
  reparsed value as a round-trip failure; it is not part of the value.
- If the round trip genuinely fails on valid house-format input, STOP and escalate — that is a
  real parser defect and 600 corpus fences depend on the answer.

---

### P3 — Property-test Canonical determinism   [wave 2] [risk: low]

**Depends on:** P1
**Files:** `spec/support/shared_examples/canonical_laws.rb`, `spec/lain/canonical_spec.rb`,
`spec/lain/rust/canonical_spec.rb`
**Reuse:** P1's `forall` helper. The group is parameterised by a single `dump:` lambda and is
already included by both consumers (`spec/lain/rust/canonical_spec.rb:11-15` supplies
`Lain::Ext.canonical_dump`), so a property added to the group strengthens both at once. Today
key-order invariance uses 5 hardcoded keys and `10.times { shuffle }` (`canonical_laws.rb:42-50`).
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: canonical bytes do not depend on hash insertion order
  Given an arbitrary generated nested structure of JSON-native values
  Then shuffling its keys at every level and dumping again yields identical bytes

Scenario: symbol and string keys collapse to the same bytes
  Given an arbitrary generated structure keyed by symbols
  Then it dumps to the same bytes as the same structure keyed by strings

Scenario: the Rust and Ruby canonicalisers agree on arbitrary input
  Given an arbitrary generated nested structure
  Then both implementations dump identical bytes
```
→ spec files: the first two scenarios go in
`spec/support/shared_examples/canonical_laws.rb` (run by both consumers); **the third is a
differential and belongs in `spec/lain/rust/canonical_spec.rb`**, which
`ext/lain/CLAUDE.md:150` names as the sole authority on cross-implementation agreement — the
shared group holds only one `dump:` lambda and structurally cannot compare two.

**Escalation triggers:**
- The generator must not produce a hash carrying **both** `:a` and `"a"` (`AmbiguousKey` by
  design, `canonical.rb:29`), NaN/Infinity (`NonFiniteFloat`), or any non-JSON-native type
  (`UnsupportedType`).
- Nesting depth is bounded at **≤100** — 100 is accepted, 101 raises
  (`spec/lain/rust/canonical_spec.rb:72`). A deeper generated value fails for that reason, not a
  determinism one.
- If Ruby and Rust disagree on any generated input, STOP — that is a live content-addressing
  defect affecting turn hashing and prompt-cache stability, not a spec problem.

## Integration checks

After the last wave:

- `bundle exec rake pspec` — full suite green. **Check the example count against a serial run**
  before believing it; `parallel_tests` reports only surviving examples, so a dead worker looks
  like "fewer examples, 0 failures".
- Confirm `rantly` is absent from `Gemfile.lock` and no spec requires it.
- `bundle exec rubocop` — clean. Never name a `.toml` on the command line.
- `bundle exec yard stats --list-undoc` and the `rubocop-yard` cops — C2 moves three
  `Data.define` + reopen pairs under the regime `f2fb5d8` landed; confirm each class still
  publishes its own docstring rather than a reopen note.
- `cargo test` **and** `cargo clippy --all-targets -- -D warnings` — the second is what compiles
  the magnus surface. The `#[test]` baseline is **216**, not the 190 `ext/lain/CLAUDE.md` states;
  correct that line while here.
- `cargo fmt -- --check`, `cargo deny check` (petgraph pinned exact; report any
  `multiple-versions` warning from the new `hashbrown`/`indexmap` edges rather than silencing
  it), `cargo doc --no-deps` clean.
- `bundle exec rake compile` — the extension builds into `lib/lain/lain.so`.
- **The prelude invariant spec** (fresh-ruby subprocess doing `require "lain"`) must pass — the
  guard for C1/C2/C3's load-order hazard, whose failure mode is total.
- `pre-commit run --all-files`.
- **Manual pass owed to Joel:** exercise the four CLI entry points that load a config —
  `lain epic`, and the mount / submit / land paths — against a real `.lain/config.toml` and a
  deliberately malformed one, and confirm the refusal messages still read well. The suite pins
  the strings; only a human can say whether they still *help*.
- **Follow-ups to record on landing:** migrate the five existing `Guard` subclasses onto
  `Guardable` if C1 leaves them on the old entry point; `Epic::Graph::Blocking` as a second
  consumer of the graph primitives (with an SCC-based cycle message); extraction to
  `crates/lain-graph` if cross-repo reuse is wanted; an `Ext::Dominators` query object if the
  memo needs exposing; the per-use-site meet axis once `dominator_meet` has a production caller;
  and ROADMAP item 23's seam decision, which this chunk deliberately does not touch.
