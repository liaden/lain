# Chunk — event spine, orchestration, retrieval sweep, Neovim

status: in-progress
commit-mode: orchestrator-commits
language: ruby (+ rust, T25 only)
panel: Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman · Aaron Patterson (Ruby) — Raph Levien · Andrew Gallant · Frank McSherry · Ashley Williams (Rust, T25)

## Intent

Four streams pulled in together, per the 2026-07-15 interview: (1) the **event spine** —
`planning/specs/event-schema.md` + `planning/specs/timeline.md` realized in full, TL-1..5
including the Rust re-port; (2) the **M5 orchestration band** — fibers adopted,
`Tool::Subagent` one-shot + actor, `ask_human` promises, role catalog on prompt slots
(PS-1..3 + OM-0..5 from `planning/specs/orchestration-model.md` / `prompt-slots.md`);
(3) the **M6 retrieval sweep** — `Vector`/`Hybrid`/`Graph` arms, recall@k, gold corpus,
sweep driver (remaining-work 6-2, thesis-critical path); (4) the **Neovim frontend**
(remaining-work 4-2.1–4-2.3). Satisfies ROADMAP near-term item 8 in one coordinated chunk.

## Grounding (verified 2026-07-15, three Explore passes)

Suite baseline: **1470 Ruby examples green, 79 cargo tests**. Where docs and code disagree,
code won; the disagreements are folded into cards below:

- **`Lain::Event` is already taken** — `lib/lain/event.rb` is the Journal telemetry module
  (`ToolOutput`, `TurnUsage`, `RequestSent`, …, each `Journalable#to_journal`). The specs'
  envelope wants the name. **Decision (interview):** envelope wins; telemetry renamed (T1).
- **The Turn→Event generalization is entirely unbuilt.** `Turn` (turn.rb:17) has
  `role/content/parent/meta/digest`, single parent only. `meta["spawned_from"]` is inert
  spec-only convention — no lib code reads it (contra event-schema.md:61 "already half-encodes").
- **The seven gates never ran against `Ext::Timeline`** — rust specs
  (spec/lain/rust/{turn,timeline}_spec.rb) run `Regular` + `MeetSemilattice` +
  `Ractor.shareable?` only; the gates are provider/agent-level (provider_parity.rb). TL-5's
  acceptance is corrected accordingly (T25).
- **Fibers are decided on paper, not adopted.** `async` ~>2.34 is a dev-group dep marked
  spike-only; the loop is a plain `loop do` (agent.rb:114). 5-0.1 spike passed
  (docs/concurrency.md:172 — scheduler hooks `io_select`/`process_wait`; idle child only;
  stdout-flood re-verify required). 5-0.2/5-0.3 unstarted.
- **No subagent, mailbox, actor, or ask_human code exists.** Tools today:
  bash, edit_file, list_files, read_file, memory_read, memory_write, todo_write.
  `Toolset#only` exists (toolset.rb:75). Gate 2 is the Agent's single commit (agent.rb:212).
- **No prompt-slot or Gherkin-grader code exists**; no `.lain/` dir in this repo.
- **Retrieval scaffolding is ready; the measurement layer is not.** Index duck =
  `Manifest::Hit` (manifest.rb:29, `why` non-blank enforced) shared by Bm25 (bm25.rb:71);
  shared law group "a memory search index" (memory_index_laws.rb:40) abstracts differing
  `#search` signatures via injected `build:`/`search:` lambdas. **No embedding capability
  anywhere** (Ollama is chat-only, ollama.rb:43; the vendored stack deliberately dropped
  `#embed`, http/provider.rb:21). No recall@k, no gold corpus, no sweep driver.
  `Session::Loader#context` hardcodes the default pipeline (loader.rb:64-68).
- **CORRECTED (panel, 2026-07-15): variance fixtures DO record turn digests and the
  Loader cross-checks them.** one.ndjson holds 4 `"type":"turn"` records with digests;
  `Loader#verified_turn` (loader.rb:87-95) re-commits each and raises `Corrupt` on
  mismatch, then `anchored` checks the header `head`. `memory_root` records key by turn
  digest too. The T13 collapse changes turn digests by construction, so T13 now owns a
  mechanical offline fixture regeneration (see T13 amendment); request digests remain
  independent (rebuilt from payloads), so DryReplay byte-stability still holds after
  regeneration.
- **Neovim RPC direction verified 2026-07-11** (planning/rpc_direction_probe.rb, nvim 0.12.3
  + neovim gem 0.10.0): an `attach_unix` client can serve inbound `rpcrequest`; the gem traps
  (flush-on-next-read, `main_thread_only` raises off-thread, enqueue-and-ack) are recorded in
  ROADMAP § Interface and planning/interface-integration.md — load-bearing for T6.
- R.7 (bench record lacks `--provider`) confirmed open (bench/cli.rb:138 hardcodes
  `AnthropicRaw`); folded in as T15. R.1–R.6, R.8, P.1–P.3, Bedrock T4 stay out of scope.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lain.gemspec`,
  `Gemfile`, `Gemfile.lock`, `.rubocop.yml`, `CLAUDE.md`, `spec/spec_helper.rb`,
  `.pre-commit-config.yaml`, **and for this plan `exe/lain`** (four cards need small diffs
  there; cards hand the diff back, never edit it).
- Wave 0 (lead, before wave 1): promote `async` (~>2.34) from the Gemfile dev group to a
  gemspec runtime dependency; add `neovim` (~>0.10) as a gemspec runtime dependency.
- T25 is reviewed by the Rust panel roster; everything else by the Ruby panel.
- Cross-impl digest parity: T13 marks the Ruby↔Rust digest-parity spec pending-with-reason;
  T25 restores it. The orchestrator verifies no pending spec survives the final wave.

## Decisions pinned in this plan (from the 2026-07-15 interview)

- **Envelope takes the `Lain::Event` name**; telemetry module becomes `Lain::Telemetry`
  with `to_journal` wire tags byte-unchanged (recorded NDJSON must still load).
- **Full TL-1..5 including the Rust re-port**; Ruby stays the reference; law groups + digest
  parity gate the port.
- **Attenuation is a spawn-seam policy object** with two arms — `schema` (per-role tool
  schemas; default) and `handler_union` (union schema, Handler refusal, journaled) — so the
  CE-4 heterogeneous-fan-out cache case stays benchable. Prelude ordering: role-invariant
  bulk first, breakpoint, role-specific after.
- **Slots are session-fixed**: loaded once at session start, content-addressed, journaled
  once in the session header; same-role siblings render byte-identical preludes.
- **Vector = exact cosine in Ruby** over embeddings from a local model (Ollama `/api/embed`,
  pinned model, default `nomic-embed-text`); **Graph = pure-Ruby wikilink N-hop**. The
  five-rule binding test fails at bench corpus sizes, so no usearch/petgraph bindings; they
  become a later scale card gated by the same law group.
- **The sweep is a deterministic retrieval eval** — no live model calls: recall@k over the
  gold corpus per arm + tokens-on-recall from dry-rendered `Context::Recall` blocks; the
  Vector arm reads committed fixture embeddings (regenerated via an `:integration` task).
- **`correlation` = the chain's root event digest** (no new id machinery).
- **Actor fold-in default**: a `Context::Mailbox` combinator folds all pending messages at
  the parent's turn start, placed after the last cache breakpoint (same tail rule as Recall).
- Out of scope, deliberately: OM-6 supervision (needs the Workspace Timeline),
  grader-from-Gherkin, PS-4/PS-5, the sibling-template prefix arm + `stream_started` (CE-5),
  live-graded sweeps, R.1–R.6/R.8, P.*, Bedrock T4.

## Open decisions

None gating — every card below is runnable as specified. Deferred questions (actor GC/
archival policy beyond explicit stop; mailbox projection indexing at scale; user-defined
roles) are noted in their cards as future work, not blockers.

## Waves (amended per panel — T12 after T13; T25 pulled to wave 5)

```
Wave 1: T1, T2, T3, T4, T5, T7              (no unmet deps)
Wave 2: T6(←T1), T8(←T1), T9(←T1,T2), T10(←T4), T11(←T3)
Wave 3: T13(←T8), T14(←T10), T15
Wave 4: T12(←T6,T13), T17(←T13), T18(←T13), T19(←T13), T20(←T5,T7,T10,T14)
Wave 5: T21(←T8,T11,T18), T22(←T19,T11), T24(←T2,T9,T19), T25(←T17,T18)
Wave 6: T16(←T12), T23(←T19,T18)
```

Critical path: **T1 → T8 → T13 → T17 → T25** (the spine). T23 sits in wave 6 because it
shares `lib/lain/tools/subagent.rb` with T22 (file serialization, not a dependency).
T12 moved behind T13 so the buffer views never render a Turn surface mid-reshape.

## Panel amendments (review landed 2026-07-15, folded in-flight by the orchestrator)

The create-plan panel returned APPROVE-WITH-FIXES after execution began. Verified and
folded in; wave-2+ briefs carry these deltas:

- **T1/T8 constant conflict (blocker):** T1's `defined?(Lain::Event) is falsy` example is
  correct only until T8 re-takes the constant. T8's Files now include
  `spec/lain/telemetry_spec.rb`: replace that example with "no telemetry record resolves
  under `Lain::Event`".
- **T13 fixture regeneration (blocker, decision made per the card's own trigger):**
  regenerate, don't version. T13 gains a mechanical offline re-digest script (spec
  support or one-off) that rewrites turn `digest` fields, the header `head` anchor, and
  every record keyed by turn digest (`memory_root`, `turn_usage`) in
  spec/fixtures/sessions/variance/*.ndjson — content untouched, digests recomputed under
  the Event scheme. Scenario 3 (DryReplay request byte-stability) holds *after*
  regeneration since request digests rebuild from payloads.
- **T2:** the impurity AC's `NameError` is not achievable via constant interception
  (lexical lookup); a *named Lain error at render* satisfies the intent. Loud, not silent.
- **T8:** pin `causal_parents` canonical order (sorted digests) in the digest bytes — a
  set, not insertion order; parity (T25) depends on it. New trigger: the Rust store
  byte-parity example (spec/lain/rust/store_spec.rb pins the dangling-put refusal message
  byte-identical) — existing refusal wording for single-parent puts must not change.
- **T18:** usage numbers come from an *injected* digest→usage map (Journal-derived);
  usage must NOT ride event payloads/meta — the digest stays content-only (repo
  invariant). New trigger naming that invariant.
- **T19:** injection path pinned — the Subagent tool takes its collaborators (provider,
  store, journal, context factory, budget) by constructor injection at toolset-build
  time; the dispatch duck (`context:` = Session) does not widen.
- **T20:** "hybrid earns its place" drops from unit AC to the integration/manual
  close-out (it tests the fixture, not the code; keeping it as a unit AC incentivizes
  corpus-gaming). Mechanism ACs stay.
- **T11:** the flood spec stays `:spike`-gated but must assert a pinned bound (compare
  the 5-0.1 record's 50ms tick baseline), and the cancellation spec runs in the default
  suite.
- **T24 (+T2):** role-slot filename mapping pinned: `.lain/slots/role/<name>.md` with
  the role name's underscores as hyphens (`test_engineer` → `test-engineer.md`); unknown
  files in the role namespace are loud exactly like top-level slots.
- **T6:** version handshake made observable: `:LainVersion` returns the gem version;
  attach warns (never crashes) on a runtime.lua↔gem version mismatch.
- **T25:** scope corrected — Rust ports the envelope + store + timeline (Regular,
  DAG-MeetSemilattice, digest parity, shareability, byte-identical refusal text);
  projections stay Ruby-only (they join Journal-side data; a per-node crossing fails
  binding rule #4). Pulled to wave 5.
- T15 stays wave 3 (load-balancing, not dependency). T21 may fold Promise into
  ask_human if a separate file isn't earning its seam.

## Tasks

### T1 — Rename the telemetry module `Lain::Event` → `Lain::Telemetry`   [wave 1] [risk: low] ✅ landed (panel: APPROVE)

**Depends on:** none
**Files:** `lib/lain/telemetry.rb` (moved from `lib/lain/event.rb`), `lib/lain/channel.rb`,
`lib/lain/sink.rb`, `lib/lain/journal.rb`, `lib/lain/middleware/journal_requests.rb`,
`lib/lain/memory/journal_memory_root.rb`, `lib/lain/bench/session/loader.rb` and siblings,
`lib/lain/frontend/**` consumers, `spec/lain/telemetry_spec.rb` (moved), all specs
referencing `Lain::Event`
**Reuse:** the existing `Journalable#to_journal` tag mechanism (event.rb:88-269) — tags are
the wire format and must not change
**Shared-file wiring:** `lib/lain.rb`: `require "lain/event"` → `require "lain/telemetry"`

**Acceptance criteria:**

```gherkin
Scenario: the constant is freed with the wire format intact
  Given the full suite after the rename
  When bundle exec rspec runs
  Then it is green and defined?(Lain::Event) is falsy

Scenario: recorded journals still load
  Given the committed fixtures spec/fixtures/sessions/variance/*.ndjson
  When Bench::Session::Loader loads them
  Then every record parses with the same type tags as before the rename
```
→ spec file: `spec/lain/telemetry_spec.rb` (+ a fixture-load regression example)

**Escalation triggers:**
- Any `to_journal` tag string would need to change to complete the rename — stop; tags are
  the recorded wire format.
- Any consumer turns out to resolve event classes reflectively from journal `type` strings
  (class-name coupling the grep can't see) — stop and name it.

### T2 — Build `Prompt::Slots`, markdown partials in a locked pure binding (PS-1)   [wave 1] [risk: medium] ✅ landed (panel: REQUEST-CHANGES → node-type allowlist redesign → APPROVE; digests over rendered bytes; exe/lain chat wiring applied — new cache marker, SYSTEM_PREFIX untouched, sub-4096 default won't cache until an override grows it)

**Depends on:** none
**Files:** `lib/lain/prompt.rb` (unit index), `lib/lain/prompt/slots.rb`,
`lib/lain/prompt/locked_binding.rb`, `lib/lain/prompt/templates/system.md.erb` (shipped
default), `spec/lain/prompt/slots_spec.rb`
**Reuse:** `Lain::Canonical` for fill digests; purity discipline of `Context#render`
(lib/lain/context.rb); the `Data.define` lexical-scoping trap (CLAUDE.md § Known traps)
**Shared-file wiring:** `lib/lain.rb` require line for `lain/prompt`; `exe/lain` diff routing
the chat system prompt through `Prompt::Slots` (orchestrator applies)

**Acceptance criteria (PS-1):**

```gherkin
Scenario: a project override fills its hole verbatim
  Given .lain/slots/system.md exists in the project dir
  When the base template renders
  Then the rendered system prompt contains the file's content verbatim in the system hole

Scenario: a missing fill falls back to the shipped default
  Given no .lain/slots/system.md
  When the base template renders
  Then the shipped default text renders and no error is raised

Scenario: impurity fails loudly
  Given a slot fill interpolating <%= Time.now %>
  When the template renders
  Then a NameError is raised at render, not a silently nondeterministic value

Scenario: renders are pure
  Given identical fills and template
  When rendered twice
  Then the outputs are byte-identical

Scenario: an unknown top-level slot file is loud
  Given .lain/slots/tyop.md
  When slots load
  Then an error names the file and lists the known slots
```
→ spec file: `spec/lain/prompt/slots_spec.rb`

**Escalation triggers:**
- Wiring the rendered system prompt into the live session would move or resize
  `Request::SYSTEM_PREFIX` / cache-marker placement (the 4096-token minimum-cacheable-prefix
  trap) — stop and show the before/after prelude.
- The locked binding cannot exclude `Time`/IO without unfreezing or subclassing value
  objects — stop; do not weaken `Freezable`.

### T3 — Spike effects-via-Fiber vs handler objects (5-0.2)   [wave 1] [risk: low] ✅ landed (panel: A-W-F mechanical, fixed; finding: Fiber is single-shot — handler chain stays, 3c-5.6 builds on Timeline#fork)

**Depends on:** none
**Files:** `spec/spikes/effects_fiber_spike_spec.rb`, `docs/concurrency.md` (new section)
**Reuse:** the spike idiom of `spec/spikes/async_shellout_spike_spec.rb`;
`lib/lain/effect.rb`, `lib/lain/effect/handler.rb`, `lib/lain/middleware.rb`
**Shared-file wiring:** none

**Acceptance criteria (5-0.2):**

```gherkin
Scenario: both prototypes behind the identical public API
  Given a fiber-based interpreter and the existing handler-object interpreter
  When the same Effect runs through the same Middleware#call(env) surface
  Then both produce the same result and the spike spec asserts the equivalence

Scenario: the trade is recorded, not remembered
  Given a tool that raises inside each prototype
  When the backtraces are captured
  Then docs/concurrency.md records both traces, the multi-shot-resumption implication for
       speculative branching (3c-5.6), and a recommendation with reasons
```
→ spec file: `spec/spikes/effects_fiber_spike_spec.rb`

**Escalation triggers:**
- The fiber prototype cannot preserve `Middleware`'s monoid laws (associativity/identity
  shared group) — record the failure as the finding; do not force an API change.

### T4 — Embedder seam + `Embedder::Ollama` over `/api/embed`   [wave 1] [risk: medium] ✅ landed (panel: REQUEST-CHANGES → fixed → APPROVE; live tag switched :integration→:ollama; deferred: provider-side transport extraction to dissolve the 7-line build_config/wrap_error mirror)

**Depends on:** none
**Files:** `lib/lain/embedder.rb` (duck + unit index), `lib/lain/embedder/ollama.rb`,
`lib/lain/embedder/static.rb` (deterministic, injectable; also a PHI-free bench arm),
`spec/lain/embedder/ollama_spec.rb`, `spec/lain/embedder/static_spec.rb`
**Reuse:** `Provider::Ollama`'s base-url/env posture (lib/lain/provider/ollama.rb); webmock
stubs + the `:integration` tag gating (spec/support/tags.rb)
**Shared-file wiring:** `lib/lain.rb` require line for `lain/embedder`

**Acceptance criteria:**

```gherkin
Scenario: batch embed
  Given a stubbed /api/embed response for two texts
  When embedder.embed(["a", "b"]) runs
  Then it returns two Float vectors of equal dimension

Scenario: failures are loud
  Given the endpoint returns a non-2xx or malformed body
  When embed runs
  Then a named Lain error is raised — never a silent empty vector

Scenario: Static is byte-stable
  Given Embedder::Static with a configured vocabulary
  When the same text embeds twice
  Then the vectors are identical

Scenario: live round trip (integration)
  Given LAIN_INTEGRATION=1 and a local ollama with the pinned model (default nomic-embed-text)
  When a real embed runs
  Then vectors return with the model's advertised dimension
```
→ spec files: `spec/lain/embedder/ollama_spec.rb`, `spec/lain/embedder/static_spec.rb`

**Escalation triggers:**
- The real `/api/embed` response shape differs from the stub (verify against local ollama
  before writing the stub — free, per the ollama smoke-testing convention) — stop and fix the
  stub first, not the code to match a guess.
- Repeated identical local calls return drifting vectors — document the nondeterminism, pin
  model+options, and stop if drift would undermine the committed-fixture determinism T20 needs.

### T5 — Build `Memory::Graph`, wikilink N-hop retrieval   [wave 1] [risk: low] ✅ landed (panel: APPROVE; link rule: verbatim [[name]]→Item#id, unresolved links dead-end silently)

**Depends on:** none
**Files:** `lib/lain/memory/graph.rb`, `spec/lain/memory/graph_spec.rb`, require line in
`lib/lain/memory.rb` (unit index — card-editable)
**Reuse:** `Memory::Manifest::Hit` (manifest.rb:29 — `why` non-blank); `Memory::Index#to_a`;
shared group "a memory search index" (memory_index_laws.rb:40) via `build:`/`search:` lambdas
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: seed match
  Given an item whose description mentions the query term
  When search runs
  Then that item is a hit whose why names the matched term

Scenario: one hop across a wikilink
  Given item A's body contains [[b]] and item B matches no query term
  When search runs with hops: 1
  Then B is a hit and its why names the path (seed A → [[b]])

Scenario: hop limit and dedup
  Given a chain a → [[b]] → [[c]]
  When search runs with hops: 1
  Then c is absent, and no item appears twice

Scenario: the index laws hold
  Given the shared law-group corpus
  Then "a memory search index" passes with Graph's build/search lambdas
```
→ spec file: `spec/lain/memory/graph_spec.rb`

**Escalation triggers:**
- Wikilink targets in the law corpus don't resolve to item ids (the `[[name]]` convention vs
  `Memory::Item#id` mismatch) — stop and pin the link-resolution rule before coding around it.

### T6 — Build the `Frontend::Neovim` skeleton (4-2.1)   [wave 2] [risk: high] ✅ landed (panel: REQUEST-CHANGES → teardown-hang/death-propagation/protocol-handshake fixes → A-W-F; **T12 inherits**: bound the `@renders` queue (SizedQueue or batch cap) so backpressure reaches the producer — unbounded backlog starved inbound acks to 6.4s in an adversarial probe)

**Depends on:** T1 (renders `Lain::Telemetry` events; starting before the rename lands would
race on the constant)
**Files:** `lib/lain/frontend/neovim.rb`, `lib/lain/frontend/neovim/rpc_thread.rb`,
`lib/lain/frontend/neovim/runtime.lua` (injected at attach, shipped in the gem),
`spec/lain/frontend/neovim_spec.rb` (`:nvim`-tagged, headless `nvim --clean --embed`)
**Reuse:** `Frontend::TTY`'s Channel-drain shape (lib/lain/frontend/); the verified RPC traps
in ROADMAP § Interface + `planning/interface-integration.md` + `planning/rpc_direction_probe.rb`
(one thread serves AND sends via an inbox queue; enqueue-and-ack; writes flush on the loop's
next read; `Session#main_thread_only` raises off-thread)
**Shared-file wiring:** `lain.gemspec` gains `neovim` runtime dep (wave 0); `lib/lain.rb`
require line; `spec/support/tags.rb` gains `:nvim` gating (one-line, orchestrator applies)

**Acceptance criteria (4-2.1):**

```gherkin
Scenario: journal events render into a buffer
  Given an attached headless nvim and the frontend subscribed to the Channel
  When a Telemetry event is pushed
  Then a lain:// buffer gains a rendered line, and the agent has no reference to nvim

Scenario: re-attach is idempotent
  Given the frontend attaches twice to the same nvim
  Then :Lain* commands are defined once, namespaced, with a version handshake

Scenario: inbound requests do not deadlock
  Given nvim invokes a :Lain* command while the frontend is mid-send
  When the request arrives
  Then it is enqueued and acked without freezing the editor (the enqueue-and-ack rule)
```
→ spec file: `spec/lain/frontend/neovim_spec.rb`

**Escalation triggers:**
- The one-thread inbox design cannot serve nested requests through the gem's
  Fiber-based `yielding_response` — stop; do not add a second RPC thread.
- Headless `--embed` semantics diverge from `--listen`+`attach_unix` such that the spec can't
  exercise the attach path — stop and record which mode specs can honestly cover.
- Any temptation to write `$stdout` for debugging — `spec/output_discipline_spec.rb` covers
  `lib/lain/frontend/` too; it must stay green.

### T7 — Gold retrieval corpus + `Grader::Recall` (recall@k)   [wave 1] [risk: low] ✅ landed (panel: APPROVE; zero-token-overlap verified against the real BM25/Manifest tokenizers)

**Depends on:** none
**Files:** `spec/fixtures/memory/retrieval_corpus.yml` (items + labeled queries),
`lib/lain/grader/recall.rb`, `spec/lain/grader/recall_spec.rb`, require line in
`lib/lain/grader.rb`
**Reuse:** `Grader::Fixture`'s shape (grader/fixture.rb:22) and the `Grade` value
(grader.rb:15); the synthetic drug-name style of the law corpus (memory_index_laws.rb:58)
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: recall@k computes exactly
  Given a query with gold ids {a, b, c} and hits ranking a, x, b in the top 3
  When recall at k=3 is scored
  Then the score is 2/3 with a why naming the missed id

Scenario: the corpus is internally valid
  Given every query's gold ids
  Then each exists among the corpus items (a validity spec, not a runtime check)

Scenario: the corpus can separate the arms
  Given the committed corpus
  Then it holds ≥30 items and ≥10 queries spanning exact-lexical, semantic-paraphrase,
       and wikilink-reachable classes, and is synthetic-only (the PHI/cassette rule)
```
→ spec file: `spec/lain/grader/recall_spec.rb`

**Escalation triggers:**
- `Grade`'s scalar shape can't carry per-query results the way `Compare::Run` will need in
  T20 — stop and agree the aggregation shape with the orchestrator rather than inventing one.

### T8 — Define the `Lain::Event` envelope, four kinds, two edges (TL-1)   [wave 2] [risk: high] ✅ landed (panel: A-W-F mechanical → APPROVE; note: `correlation` is caller-supplied and unvalidated at this layer by design — T13's chain construction derives it as the root event digest; Rust store byte-parity verified intact)

**Depends on:** T1
**Files:** `lib/lain/event.rb` (the envelope + unit index), `lib/lain/event/payload.rb`
(kind-typed payloads), `lib/lain/store.rb` (referential integrity over both edge types),
`spec/lain/event_spec.rb`, additions to `spec/lain/store_spec.rb`
**Reuse:** `Canonical`, `Freezable`, `ContentAddressed`; `Turn`'s payload discipline
(turn.rb:33); `Store#put`'s dangling-parent refusal (store.rb:33-39) and the duck-typed
`validate_parent!` that `Memory::Index::Node` also flows through (store.rb:65-70)
**Shared-file wiring:** `lib/lain.rb` require line for `lain/event` (placed after `store`)

**Acceptance criteria (TL-1 + pins):**

```gherkin
Scenario: the kind set is closed and loud
  Given an event constructed with kind: :banana
  Then a named error is raised identifying the kind and listing the four legal kinds

Scenario: referential integrity covers both edges
  Given an event whose render_parent or any causal_parent is absent from the Store
  When Store#put runs
  Then it refuses, matching the existing dangling-parent behavior

Scenario: deep immutability and identity
  Given any constructed event
  Then Ractor.shareable?(event) is true and its digest is stable across processes
       (Canonical bytes; correlation = the chain's root event digest)

Scenario: payloads are content-addressed, never inline in the envelope
  Given a :turn event
  Then the envelope carries payload_digest and the payload object is separately
       retrievable from the same Store by that digest
```
→ spec file: `spec/lain/event_spec.rb`

**Escalation triggers:**
- Out-of-line payloads would force `Timeline#commit` callers (agent.rb:162, :212) to change
  non-additively, or would break gate-1's full-content assertion (provider_parity.rb:113) —
  stop; the collapse (T13) owns caller changes, not this card.
- `Memory::Index::Node` can no longer flow through `Store#put` duck-typing — stop; the memory
  stream depends on that duck.

### T9 — Journal session slot digests (PS-2, session-fixed model)   [wave 2] [risk: medium] ✅ landed (panel: A-W-F → mechanical fixes applied; kept to attribution; EMISSION moved to T15 by orchestrator decision; found: the default pipeline wraps system into cache-marked text blocks — join guard pins block text)

**Depends on:** T1, T2
**Files:** `lib/lain/prompt/slots.rb` (digest exposure), `lib/lain/telemetry.rb` (new
`SlotFills` record: name → digest map + fill bytes, emitted once at session start),
`lib/lain/bench/session/loader.rb` (surface recorded fills), `spec/lain/prompt/slot_journal_spec.rb`
**Reuse:** `Journalable#to_journal`; `Canonical.digest`; the loader's existing header-record
handling (bench/session/loader.rb)
**Shared-file wiring:** none

**Acceptance criteria (PS-2, adjusted for session-fixed slots):**

```gherkin
Scenario: one header record pins the session's fills
  Given a session started with an overridden system slot
  When the journal is read
  Then exactly one SlotFills record carries the slot name, digest, and fill bytes

Scenario: replay identifies the fills without touching .lain/slots
  Given a recorded session and a changed .lain/slots/system.md on disk
  When the Loader loads the recording
  Then the recorded fills (not the disk state) are reported for that run

Scenario: attribution is diffable
  Given two recordings with different system fills
  Then their SlotFills digests differ and the fill bytes explain the diff
```
→ spec file: `spec/lain/prompt/slot_journal_spec.rb`

**Escalation triggers:**
- `RequestSent` already journals the fully rendered system text, so if byte-recovery needs
  nothing new, keep this card to attribution (digests + fills) — confirm with the
  orchestrator before adding replay machinery the journal already provides.

### T10 — Build `Memory::Vector`, exact cosine over embeddings   [wave 2] [risk: low] ✅ landed (panel: APPROVE; follow-up logged: Embedder wants a model-id reader so Vector's why can name the model, not just the class)

**Depends on:** T4
**Files:** `lib/lain/memory/vector.rb`, `spec/lain/memory/vector_spec.rb`, require line in
`lib/lain/memory.rb`
**Reuse:** `Embedder::Static` for unit determinism; `Manifest::Hit`; Bm25's build-once shape
(bm25.rb:32-42); shared group "a memory search index"
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: nearest neighbor ranks first
  Given Static embeddings placing item X nearest the query
  When search runs
  Then X is the top hit and why names the cosine score and embedder/model id

Scenario: determinism and ties
  Given equal-scoring items
  Then order is stable (ties break by id) across repeated builds

Scenario: degenerate corpus
  Given an empty index
  Then search returns [] without error

Scenario: the index laws hold
  Then "a memory search index" passes with Vector's build/search lambdas
```
→ spec file: `spec/lain/memory/vector_spec.rb`

**Escalation triggers:**
- The law group's injected corpus can't be paired with an injected embedder without editing
  the shared group — extend the group's injection points (it already takes lambdas); stop if
  that would weaken laws for the existing indexes.

### T11 — Adopt `Async` in the agent loop with structured cancellation (5-0.3)   [wave 2] [risk: high] ✅ landed (panel: A-W-F → defer_stop shield around commit+journal → APPROVE; net/http yields to the scheduler (measured); pending stop preempts Budget::Exceeded but usage is journaled first — recomputable, documented)

**Depends on:** T3
**Files:** `lib/lain/agent.rb`, `lib/lain/agent/budget.rb` (interrupt/cancel seam),
`docs/concurrency.md` (adoption record), `spec/lain/agent_cancellation_spec.rb`,
`spec/spikes/async_shellout_flood_spec.rb` (the 5-0.3 stdout-flood re-verify)
**Reuse:** the 5-0.1 spike record (docs/concurrency.md:172-215); `Async::Task#stop`;
`LoopMachine` (agent/loop_machine.rb:48-58) and gate-6 totality (provider_parity.rb:187)
**Shared-file wiring:** `lain.gemspec` `async` runtime dep (wave 0); Gemfile dev-group entry
removed (orchestrator)

**Acceptance criteria (5-0.3 / OM-0):**

```gherkin
Scenario: existing behavior unchanged outside a reactor
  Given the full existing suite
  When it runs
  Then gate 7 (bounded loop) and all agent specs pass unchanged (a Sync bridge wraps
       non-reactor callers)

Scenario: real cancellation
  Given a run inside Async with an interrupt raised mid-turn
  When the task is stopped
  Then the state machine settles in a legal state and the Timeline holds either the
       committed turn or no partial turn — never a torn commit

Scenario: shellout under stdout flood
  Given a bash tool streaming ~10MB to stdout inside the reactor
  When a heartbeat fiber ticks concurrently
  Then heartbeat latency stays bounded, or the documented thread-offload fallback is
       implemented and docs/concurrency.md records the measured numbers
```
→ spec files: `spec/lain/agent_cancellation_spec.rb`, `spec/spikes/async_shellout_flood_spec.rb`

**Escalation triggers:**
- The flood test stalls the reactor — STOP before implementing the thread-offload fallback;
  confirm scope (it touches `Tools::Bash`, which this card otherwise must not).
- Structured cancellation needs a new `LoopMachine` state/transition — stop; gate-6 totality
  is spec'd and any machine change is orchestrator-visible.
- Faraday/net_http turns out to block the scheduler (it should hook `io_select`) — record
  measurements in docs/concurrency.md and stop if provider calls serialize the reactor.

### T12 — Neovim read-only buffers (4-2.2)   [wave 4 per amended DAG] [risk: low] ✅ landed (panel: A-W-F → drain-survival + DetachedStore Null → APPROVE; inherited T6 backpressure fix shipped as RenderQueue; production TurnUsage/RequestSent→Channel wiring folded into T16)

**Depends on:** T6
**Files:** `lib/lain/frontend/neovim/buffers.rb`, `lib/lain/frontend/neovim/runtime.lua`
(additions), `spec/lain/frontend/neovim_buffers_spec.rb` (`:nvim`-tagged)
**Reuse:** T6's rpc thread + injected command surface; `Timeline#ancestors` for the
timeline view; `Session#reminders` for the workspace view
**Shared-file wiring:** none

**Acceptance criteria (4-2.2):**

```gherkin
Scenario: live views
  Given an attached nvim and an active session
  When a turn commits / reminders change / a request is sent
  Then lain://timeline, lain://workspace, and lain://diff each reflect the new state

Scenario: read-only and unobtrusive
  Given any lain:// buffer
  Then it is nomodifiable, updates never use nvim_input/feedkeys, and focus is not stolen
```
→ spec file: `spec/lain/frontend/neovim_buffers_spec.rb`

**Escalation triggers:**
- Rendering the timeline needs Turn internals beyond the public walk (`ancestors`/`to_a`) —
  stop; T13 is about to reshape Turn and this card must depend only on the stable surface.

### T13 — Collapse `Turn` into `Event(kind: :turn)` (TL-2)   [wave 3] [risk: high] ✅ landed as two commits (prove-≅ f045836, collapse 6fc07b7; panel: A-W-F → APPROVE; fixtures regenerated content-preservingly — field-level forensics verified only turn-digest fields moved; correlation derived in Timeline#commit; 4 parity pendings name T25, incl. 2 refusal byte-parity examples ratified as turn-digest-parity-in-disguise)

**Depends on:** T8
**Files:** `lib/lain/turn.rb` (reimplement, then remove), `lib/lain/timeline.rb`,
`lib/lain/agent.rb` + `lib/lain/agent/tool_runner.rb` touchpoints, `spec/lain/turn_spec.rb`,
`spec/lain/timeline_spec.rb`, the Ruby↔Rust digest-parity spec (marked pending, see trigger)
**Reuse:** the shared groups `Regular` + `MeetSemilattice` and the seven gates as the oracle
(the spec's own sequence: define → prove ≅ → only then collapse); `Event` from T8
**Shared-file wiring:** `lib/lain.rb` drops the `lain/turn` require once removal lands

**Acceptance criteria (TL-2):**

```gherkin
Scenario: the isomorphism is proved before the cut
  Given Turn.new reimplemented to return Event(kind: :turn) with the same public surface
  When the full suite runs
  Then Regular, MeetSemilattice, all seven gates, and Ractor.shareable? pass unchanged

Scenario: the collapse completes
  Given the green isomorphism
  When Lain::Turn is removed and callers reference Event
  Then the suite is green and no Lain::Turn constant remains

Scenario: recorded replays stay byte-stable
  Given spec/fixtures/sessions/variance/*.ndjson
  When DryReplay re-renders them under the identity context
  Then requests are byte-identical (request digests derive from rendered payloads,
       not Turn digests — verified in grounding)
```
→ spec files: `spec/lain/turn_spec.rb`, `spec/lain/timeline_spec.rb`

**Escalation triggers:**
- Any fixture, `Loader`, or `MemoryReplay` path cross-checks a recorded **turn** digest
  (grounding found none, but verify) — stop; regenerate-vs-chain-version is the
  orchestrator's call.
- The Rust parity specs (spec/lain/rust/*) pin the old TurnData shape; Ruby↔Rust digest
  parity WILL break here until T25 — mark exactly that spec pending-with-reason naming T25,
  and stop if anything beyond that one spec breaks cross-impl.
- `Event`'s envelope digest cannot reproduce a stable identity for legacy `meta` semantics
  (meta rides the digest today, turn.rb:33) — stop before changing what is content-addressed.

### T14 — Build `Memory::Hybrid`, reciprocal-rank fusion   [wave 3] [risk: low] ✅ landed (panel: APPROVE; note for T20: Hybrid injects BUILT arms (`bm25:`/`vector:`), Recall-style — `index:` means build-from-Index elsewhere; don't "fix" into inconsistency)

**Depends on:** T10
**Files:** `lib/lain/memory/hybrid.rb`, `spec/lain/memory/hybrid_spec.rb`, require line in
`lib/lain/memory.rb`
**Reuse:** `Memory::Bm25`, `Memory::Vector`, `Manifest::Hit`, the shared law group; RRF with
a fixed k constant (deterministic, no tuning), ties by id
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: fusion beats a disagreement
  Given a fixture where bm25's top hit and vector's top hit differ and the gold doc is
        ranked second by both
  When hybrid searches
  Then the gold doc is the top hit and why cites both source ranks

Scenario: the index laws hold
  Then "a memory search index" passes with Hybrid's build/search lambdas
```
→ spec file: `spec/lain/memory/hybrid_spec.rb`

**Escalation triggers:**
- RRF over the law corpus produces rank ties the group's determinism law rejects — pin the
  tie-break in the card's spec, and stop if it requires changing the shared group's law.

### T15 — Extract `CLI::Backend`; give `bench record` provider/sampler flags (R.7)   [wave 3] [risk: medium]

> **Orchestrator amendment (from T9's review):** T15 also owns the SlotFills emission
> point — where `bench record` opens its journal, emit
> `journal << Telemetry::SlotFills.from(slots)` once, using the slots the extracted
> `Backend#context` rendered. T9 shipped the record + Loader surface; this card makes a
> real session actually write it.

**✅ landed** (panel: A-W-F → override-attribution fix → APPROVE; exe/lain swapped to the
alias atomically; record gained provider/api_base/temperature/seed; SlotFills emits
honestly under --system; `RECORD_DEFAULTS[:model]` now docs-only)

**Depends on:** none
**Files:** `lib/lain/cli.rb` (unit index), `lib/lain/cli/backend.rb` (extracted from
exe/lain:19-79), `lib/lain/bench/cli.rb` (`record` gains `provider:/temperature:/seed:`),
`spec/lain/cli/backend_spec.rb`, `spec/lain/bench/cli_spec.rb` additions
**Reuse:** the existing `LainCLI::Backend` logic verbatim (PROVIDERS, DEFAULT_MODEL fallback,
`sampler_extra` riding `Request#extra`); `RECORD_DEFAULTS` (bench/cli.rb:25)
**Shared-file wiring:** `exe/lain` diff replacing the nested Backend with `Lain::CLI::Backend`
(orchestrator applies); `lib/lain.rb` require line for `lain/cli`

**Acceptance criteria (R.7):**

```gherkin
Scenario: an ollama temp-0 arm is recordable
  Given bench record --provider ollama --temperature 0 --seed 7
  When the session records (provider stubbed in spec)
  Then the session header carries the sampler extra and the recording replays dry

Scenario: chat and record resolve providers identically
  Given an unknown --provider name
  Then both paths raise the same named Lain error (not Thor::Error from lib/)
```
→ spec files: `spec/lain/cli/backend_spec.rb`, `spec/lain/bench/cli_spec.rb`

**Escalation triggers:**
- The extraction would drag `thor` into `lib/` (Thor::Error raised below the frontend) —
  stop; error types in lib are Lain's, the exe layer maps them.

### T16 — Editable `lain://request` + `:LainResend` (4-2.3)   [wave 6 per amended DAG] [risk: medium] ✅ landed (panel blessed the diff-only reading against the roadmap's own 4-2.3 acceptance — provider round-trip is later [exp] work; REQUEST-CHANGES-grade fixes: resends journal as `request_resent` (distinct type, never mined as a failed dispatch) + resend-worker death observability; `chat --nvim SOCKET` wires the live views via a JournalTee)

> **Orchestrator amendment (from T12's review):** T16 also owns wiring the live views'
> event sources — today NOTHING pushes `TurnUsage`/`RequestSent` onto the Channel
> (they go to the Journal only), so T12's timeline/workspace/diff views work only when
> a caller pushes those events. Wire the sources (channel tee at the emission points,
> or an exe/lain flag attaching Frontend::Neovim with the session's store) so the
> manual close-out ("attach to a real nvim, watch buffers render") is honestly runnable.

**Depends on:** T12
**Files:** `lib/lain/frontend/neovim/request_buffer.rb`, `lib/lain/frontend/neovim/runtime.lua`
(additions), `spec/lain/frontend/neovim_request_spec.rb` (`:nvim`-tagged)
**Reuse:** `Timeline#fork` (resend is a speculative fork at head, never history rewrite);
the request render/diff machinery `Bench::DryReplay` uses (bench/dry_replay.rb:30)
**Shared-file wiring:** none

**Acceptance criteria (4-2.3):**

```gherkin
Scenario: edit, resend, see what changed
  Given lain://request showing the pending request
  When the buffer is edited and :LainResend fires
  Then the dispatched request reflects the edit and lain://diff shows exactly the change

Scenario: an unedited resend is a no-op diff
  When :LainResend fires with no edits
  Then the diff view is empty

Scenario: resends are journaled and non-destructive
  Then the resent request is journaled like any other and the original Timeline head is
       still reachable (speculative fork, not rewrite)
```
→ spec file: `spec/lain/frontend/neovim_request_spec.rb`

**Escalation triggers:**
- Dispatching a hand-edited request needs an Agent entry point that doesn't exist (render is
  pure; dispatch isn't exposed) — stop and agree the seam; do not reach into Agent internals.

### T17 — Generalize `meet`/`diverge_at` over the causal DAG (TL-3)   [wave 4] [risk: high]

**Depends on:** T13
**Files:** `lib/lain/timeline.rb`, `spec/lain/timeline_spec.rb`,
`spec/support/shared_examples/meet_semilattice.rb` (DAG generator)
**Reuse:** the existing meet (timeline.rb:117-128); `rantly` property testing; T8's
`causal_parents`
**Shared-file wiring:** none

**Acceptance criteria (TL-3):**

```gherkin
Scenario: fan-in has a correct meet
  Given a synthesis event with N causal parents
  When meet runs against each parent's chain
  Then it returns the LCA for each

Scenario: the laws survive the generalization
  Given randomly generated DAGs (not just forests)
  Then associativity, commutativity, and idempotence hold property-tested

Scenario: linear behavior is a strict regression
  Given single-parent chains only
  Then meet and diverge_at return exactly what they return today
```
→ spec file: `spec/lain/timeline_spec.rb` (+ the generalized shared group)

**Escalation triggers:**
- LCA non-uniqueness over general DAGs breaks the semilattice laws — STOP. Candidate
  redefinitions (render-chain meet + a causal reachability predicate; deepest common
  dominator) change the algebra; the human decides, not the card.

> ⚠️ **OPEN — BLOCKED ON JOEL.** The trigger fired; this decision is yours per the card, and
> T17 (plus T25, which mirrors it) stays OFF main until you rule. What the implementer built
> (worktree only): `meet`/`diverge_at` byte-unchanged + an additive `Timeline#causal_meets`
> query (one render-meet per causal parent — the card's first candidate). The panel judged
> the code APPROVE-quality but escalated the reading. The facts for your call: a literal
> meet-over-the-causal-DAG cannot satisfy the semilattice laws (LCA over a general DAG is
> non-unique); meet's stated purpose (cache-break localization) lives on the render edge.
> Options: (a) accept the projection as TL-3's reading; (b) redefine meet as a
> dominator-tree meet over the union graph (law-preserving but new algebra, and it serves
> no cache purpose we could name); (c) something else. The panel's full reasoning is in the
> T17 worktree's review + .handback-T17.md.

### T18 — Projections: mailbox, workspace_at, provenance, unique-usage (TL-4)   [wave 4] [risk: medium] ✅ landed (panel: A-W-F → stack-safe provenance + contract pins → merged; usage silent-zero policy documented)

**Depends on:** T13
**Files:** `lib/lain/event/projection.rb`, `spec/lain/event/projection_spec.rb`, require
line in `lib/lain/event.rb`
**Reuse:** the `Enumerator::Lazy` walk idiom (timeline.rb ancestors); the `Usage` monoid
(usage.rb); `Ledger` for pricing folds
**Shared-file wiring:** none

**Acceptance criteria (TL-4):**

```gherkin
Scenario: a mailbox is exactly a filter
  Given :message events to several recipients
  When mailbox(:human) projects
  Then it yields exactly the events addressed to :human, in log order, as a pure fold

Scenario: workspace at a point in time
  Given :snapshot events at turns 2 and 5
  When workspace_at(4) folds
  Then it reflects the turn-2 snapshot only

Scenario: provenance reaches the source
  Given a :turn whose causal parents chain back to a tool_result block
  When provenance walks
  Then it returns the originating tool_result reference

Scenario: usage never double-counts a shared prefix
  Given two forks sharing a prefix
  When usage folds over unique reachable digests
  Then the shared prefix is counted once
```
→ spec file: `spec/lain/event/projection_spec.rb`

**Escalation triggers:**
- Folds go measurably super-linear on fixture-sized logs — note the measurement and proceed
  in Ruby; do NOT reach for a roaring/petgraph binding (the five-rule test fails at this
  scale); flag it for the M6+ indexing card instead.

### T19 — Build `Tool::Subagent` one-shot + the spawn policy objects (OM-2 / 5-1.1–5-1.3)   [wave 4] [risk: high] ✅ landed (panel: A-W-F → transitive depth ceiling via #descend + correlation-grain provenance documented → APPROVE; lineage = :spawn/:message causal-only events, render chain untouched; tool_result→child link is correlation-grain, edge-grain deferred to OM-1/OM-6)

**Depends on:** T13
**Files:** `lib/lain/tools/subagent.rb`, `lib/lain/tool/spawn_policy.rb` (PrefixStrategy:
`fresh` | `inherit` — sibling-template deferred; AttenuationPosture: `schema` default |
`handler_union`), require lines in `lib/lain/tools.rb` and `lib/lain/tool.rb`,
`spec/lain/tools/subagent_spec.rb`, `spec/lain/tool/spawn_policy_spec.rb`
**Reuse:** `Toolset#only` (toolset.rb:75); Agent construction (agent.rb:83); the `:spawn`
kind + causal edge (T8); `Session::Null` (session.rb:132); `Budget` for the child's ceiling
**Shared-file wiring:** `exe/lain` diff adding subagent to the chat toolset (orchestrator)

**Acceptance criteria (5-1.1/5-1.2/5-1.3):**

```gherkin
Scenario: fresh root over the shared Store
  Given a parent at head H spawning with prefix: :fresh
  Then the child Timeline contains no parent turn, meet(child, parent) is empty, and a
       :spawn event records the lineage with a causal edge to H

Scenario: the return is an ordinary tool_result
  Given the child settles with a final turn F
  Then the parent's next user turn carries the child's result as a tool_result whose
       event names the :spawn and F among its causal parents (gate 2 intact)

Scenario: attenuation under each posture
  Given a child spawned with only(:read_file) under posture: :schema
  Then the child's rendered request contains only read_file's schema
  Given the same under posture: :handler_union
  Then the rendered tools block equals the parent's, and a disallowed call yields a
       refused is_error tool_result that is journaled

Scenario: inherit is O(1)
  Given prefix: :inherit
  Then the child's head equals the parent's head before its first commit, with no
       Store copying
```
→ spec files: `spec/lain/tools/subagent_spec.rb`, `spec/lain/tool/spawn_policy_spec.rb`

**Escalation triggers:**
- Nested Agent loops sharing one Store hit the Monitor in a way that changes gate-2 ordering
  (agent_spec.rb:44) — stop.
- Unbounded recursion (child spawning children) has no natural ceiling — pin a depth cap in
  the card spec and stop if the cap needs Budget changes beyond a constructor arg.

### T20 — Build `Bench::Sweep` + `lain bench sweep` (6-2.4, deterministic)   [wave 4] [risk: medium] ✅ landed (panel: A-W-F → Compare::Table extraction + -k refusal + content_digest guard → APPROVE; measured: vector .667 / graph .438 / bm25=hybrid=manifest .333 — **hybrid does NOT beat vector on this corpus** (RRF dilution); the close-out hybrid≥ check is Joel's to eyeball)

**Depends on:** T5, T7, T10, T14
**Files:** `lib/lain/bench/sweep.rb`, `lib/lain/bench/cli.rb` (sweep command),
`lib/lain/compare.rb` (metrics `recall_at_k`, `recall_tokens`),
`lib/lain/bench/session/loader.rb` (injectable pipeline factory, replacing the hardcoded
default at loader.rb:64-68), `spec/fixtures/memory/corpus_embeddings.json` (committed,
keyed by item digest + model id), `spec/lain/bench/sweep_spec.rb`
**Reuse:** `Compare` distributions (compare.rb:86); `Grader::Recall` (T7); all five indexes;
`Bm25Cache` (bm25_cache.rb:21 — built for exactly this); `Context::Recall` dry render for
tokens-on-recall; `Embedder::Static`/fixture vectors for determinism
**Shared-file wiring:** `exe/lain` diff registering `bench sweep` (orchestrator)

**Acceptance criteria (6-2.4 + 6-2.2):**

```gherkin
Scenario: the headline report
  Given the gold corpus and committed fixture embeddings
  When lain bench sweep -k 5 runs
  Then a Compare-style report ranks manifest, bm25, vector, hybrid, and graph by
       recall@5 distributions with a tokens-on-recall column, with zero network calls

Scenario: determinism
  When the sweep runs twice
  Then the reports are byte-identical

Scenario: hybrid earns its place (6-2.2)
  Given the corpus's paraphrase and exact-lexical query classes
  Then hybrid's mean recall@5 ≥ each of bm25's and vector's on the fixture corpus

Scenario: stale embeddings are loud
  Given fixture embeddings recorded under a different model id than requested
  Then the sweep raises naming both model ids
```
→ spec file: `spec/lain/bench/sweep_spec.rb`

**Escalation triggers:**
- Per-query distributions don't fit `Compare::Run`'s scalar score without reshaping Compare's
  public surface — stop and agree the shape (this is the bench's reporting API).
- Regenerating fixture embeddings (`:integration` task against local ollama) produces vectors
  that flip the hybrid≥ assertion — stop; corpus or fusion needs rework, not a loosened AC.

### T21 — Build `ask_human` as a promise (OM-4)   [wave 5] [risk: medium] ✅ landed (panel: A-W-F → reply-guard-before-Store-write → merged; AskHuman::Notifying decorator added in lib for the REPL wake; exe two-fiber reply path applied — live REPL verification rides the manual close-out)

**Depends on:** T8, T11, T18
**Files:** `lib/lain/tools/ask_human.rb`, `lib/lain/promise.rb` (thin Async::Variable
wrapper), `lib/lain/frontend/tty.rb` (pending-question rendering), require lines in
`lib/lain/tools.rb`, `spec/lain/tools/ask_human_spec.rb`
**Reuse:** the `:message` kind (T8); mailbox projection (T18) — the human's inbox is
`mailbox(:human)`; Async fiber parking (T11)
**Shared-file wiring:** `exe/lain` diff for the REPL reply path (orchestrator)

**Acceptance criteria (OM-4):**

```gherkin
Scenario: ask does not block
  Given an agent that calls ask_human then continues with other tool work
  When the question is emitted
  Then a :message to :human enters the Store and the agent proceeds

Scenario: await parks the fiber, not the reactor
  Given an unresolved promise being awaited
  When a concurrent fiber does work
  Then the concurrent work proceeds while the awaiting fiber is parked

Scenario: a reply resolves
  Given a :message from :human answering the question
  Then the promise resolves with the answer, and both Q and A are replayable Store events
       (AC reconciled at review: Q rides mailbox(:human), A rides mailbox(asker) with a
       causal edge to Q — the honest addressing; "both via mailbox(:human)" mislabeled A)

Scenario: the sync gate is the degenerate case
  Given an agent that awaits immediately
  Then behavior is a synchronous question-answer with no extra API
```
→ spec file: `spec/lain/tools/ask_human_spec.rb`

**Escalation triggers:**
- An unresolved promise at a turn boundary (answer needed mid-render) has no pinned policy —
  stop and pin the await point with the orchestrator; do not invent a timeout.

### T22 — Within-turn concurrent subagents (5-1.4)   [wave 5] [risk: high] ✅ landed (panel: APPROVE outright; whole-turn all-or-nothing gather on parallel_safe?; NITs noted for docs: orphan :spawn events after a cancel are observable; journal record order for interleaved children is honestly nondeterministic)

**Depends on:** T19, T11
**Files:** `lib/lain/tools/subagent.rb` (async fan-out), `lib/lain/agent/tool_runner.rb`
(gather semantics for `parallel_safe?` tools), `spec/lain/tools/subagent_concurrency_spec.rb`
**Reuse:** Async task groups + structured cancellation (T11); gate-2's single-commit
discipline (agent.rb:212, tool_runner.rb:23)
**Shared-file wiring:** none

**Acceptance criteria (5-1.4):**

```gherkin
Scenario: out-of-order completion, one turn
  Given three async children finishing in reverse spawn order
  When the parent gathers
  Then all tool_results land in ONE user message ordered by tool_use order, and the
       provider-parity gate-2 example still passes unchanged

Scenario: cancellation propagates
  Given the parent's task stopped mid-fan-out
  Then all child tasks stop and no partial results commit

Scenario: attribution survives concurrency
  Given interleaved child events
  Then every Store event carries its child's attribution with no torn writes
```
→ spec file: `spec/lain/tools/subagent_concurrency_spec.rb`

**Escalation triggers:**
- `ToolRunner`'s sequential map (tool_runner.rb:23-24) is load-bearing for a non-subagent
  tool's ordering assumptions — gate concurrency on `parallel_safe?` only, and stop if any
  existing tool must change to stay correct.

### T23 — Build the long-lived actor subagent + `Context::Mailbox` (OM-3)   [wave 6] [risk: high]

**✅ landed** (panel: REQUEST-CHANGES → perform-wedge refusal + settle failure-path +
folded cursor → APPROVE; model-dispatched :actor refuses loudly pending OM-6; residual
NIT recorded: the cursor advances at render time, not send time — pin delivery semantics
with OM-6)

> **Orchestrator note (from T19's review):** the one-shot Subagent tool is stateful and
> parent-bound (@parent thunk; per-call observability state) — safe for synchronous
> one-shots, a live race the moment actors spawn siblings concurrently. T23 must make the
> spawn path re-entrant (return records, don't stash ivars) before adding mode :actor.
> Also recorded for the M5 tail: the parent's rendered tool_result turn links to the
> child's chain at CORRELATION grain only (no causal edge — ToolRunner's commit carries
> none); OM-1/OM-6 should decide if edge-grain provenance is ever needed.

**Depends on:** T19, T18
**Files:** `lib/lain/tools/subagent.rb` (mode `:actor`), `lib/lain/context/mailbox.rb`
(fold-in combinator), require line in `lib/lain/context.rb`, `spec/lain/actor_spec.rb`,
`spec/lain/context/mailbox_spec.rb`
**Reuse:** mailbox projection (T18); the Recall combinator's tail-placement rule
(context/recall.rb — after the last cache breakpoint); Async supervision (T11)
**Shared-file wiring:** none

**Acceptance criteria (OM-3 + pinned fold-in policy):**

```gherkin
Scenario: an actor persists across parent turns
  Given a child spawned with mode: :actor
  When the parent completes two turns
  Then the actor's own Timeline retains its state and meet(actor, parent) is empty

Scenario: the mailbox is a view, not a queue
  Given messages exchanged both directions
  Then each side's mailbox is a pure projection over Store events — re-foldable, never
       a mutable structure

Scenario: the parent folds deliberately
  Given three pending actor messages at the parent's turn start
  When Context::Mailbox renders (default: fold all pending)
  Then exactly those messages ride after the last cache breakpoint, the cached prefix is
       unchanged, and unfolded events remain queryable in the Store

Scenario: explicit stop
  Given actor.stop
  Then a final attributed event lands and the fiber ends under structured cancellation
```
→ spec files: `spec/lain/actor_spec.rb`, `spec/lain/context/mailbox_spec.rb`

**Escalation triggers:**
- Folding actor messages threatens gate 2 (they must not masquerade as tool_results in the
  single user turn) — stop and pin the rendered shape with the orchestrator.
- Actor archival/GC policy beyond explicit stop is genuinely needed by a spec — stop;
  archival-as-tombstone is deferred by plan decision.

### T24 — Build the role catalog on role slots (OM-5 + PS-3)   [wave 5] [risk: medium] ✅ landed (panel: A-W-F → segment-shaped preludes realize CE-4 + boot invariant catalog==templates → merged; follow-up for the spawn glue: Context#cache_marked always marks the LAST system block, and CacheBreakpoints budgets one system slot — a seam-marked bulk risks a 5-mark Anthropic 400, spend knowingly)

**Depends on:** T2, T9, T19
**Files:** `lib/lain/role.rb` (unit index + Role value), `lib/lain/role/catalog.rb`
(built-ins: dev, test_engineer, reviewer_sre, reviewer_security, reviewer_dba, researcher,
court_clerk), `lib/lain/prompt/templates/role/*.md` (shipped defaults),
`spec/lain/role_spec.rb`
**Reuse:** `Prompt::Slots` (T2) for `.lain/slots/role/<name>.md` overrides; `Toolset#only`;
`Tool::Subagent` + `AttenuationPosture` (T19); the pinned prelude ordering (role-invariant
first, breakpoint, role slot after)
**Shared-file wiring:** `lib/lain.rb` require line for `lain/role`

**Acceptance criteria (OM-5 / PS-3):**

```gherkin
Scenario: a built-in role spawns attenuated and framed
  Given the test_engineer role
  When it spawns
  Then the child holds exactly the role's toolset and its rendered prelude contains the
       role slot after the role-invariant preamble

Scenario: an override touches one role only
  Given .lain/slots/role/test-engineer.md
  Then test_engineer's prelude changes and every sibling role's bytes are identical to before

Scenario: the cache properties hold
  Given two spawns of the same role in one session (slots session-fixed)
  Then their preludes are byte-identical
  Given two different roles under posture: :handler_union
  Then their rendered tools blocks are byte-identical

Scenario: unknown roles are loud
  Given spawn with role: :chef
  Then the error lists the catalog
```
→ spec file: `spec/lain/role_spec.rb`

**Escalation triggers:**
- A role's framing genuinely cannot render after the shared preamble without incoherence —
  stop; that breaks the pinned prelude ordering and the CE-4 economics with it.
- The test_engineer role tempts a Gherkin-grader pipeline — out of scope by plan decision;
  ship the role framing only.

### T25 — Re-port the Event spine to `ext/lain` (TL-5)   [wave 6] [risk: high]

**Depends on:** T17, T18
**Files:** `ext/lain/src/lib.rs`, `ext/lain/src/event.rs` (new), existing store/timeline
modules reshaped, `spec/lain/rust/event_spec.rb` (renamed from turn_spec),
`spec/lain/rust/timeline_spec.rb`, the restored cross-impl digest-parity spec
**Reuse:** the existing port (lib.rs:668-860), `rpds` structural sharing, the Digest newtype
and Role enum from the rust-findings cards, `blake3`/`indexmap`; the shared law groups as the
oracle (bound via the same two-impl pattern the current rust specs use)
**Shared-file wiring:** none (Cargo.toml is inside ext/, card-editable; no new crates)

**Acceptance criteria (TL-5, corrected — law groups + parity, not the seven gates, which are
provider-level and never ran against Ext):**

```gherkin
Scenario: both implementations, one law set
  Given the Ruby Event spine as reference
  Then Regular, the DAG-generalized MeetSemilattice, and the projection property specs pass
       against BOTH implementations unchanged

Scenario: identity is byte-identical
  Given the same envelope fields in Ruby and Rust
  Then digests match byte-for-byte and the parity spec T13 marked pending is restored green

Scenario: shareability survives the port
  Then Ractor.shareable?(Lain::Ext::Event.new(...)) is true (frozen_shareable established
       deliberately, per the ext/lain CLAUDE.md warning)

Scenario: the crate stays clean
  Then cargo fmt --check, clippy --all-targets -- -D warnings, cargo test, and deny pass
```
→ spec files: `spec/lain/rust/event_spec.rb`, `spec/lain/rust/timeline_spec.rb`

**Escalation triggers:**
- `frozen_shareable` cannot be established for the multi-parent causal set representation —
  stop; shareability is the port's acceptance test, not an obstacle (ext/lain/CLAUDE.md).
- The T17 meet definition relies on Ruby-side semantics that can't be mirrored
  byte-identically (ordering, hashing) — stop before diverging the two implementations.

## Integration checks

After the last wave, the orchestrator runs and records:

1. `export PATH="$HOME/.rubies/ruby-4.0.5/bin:$PATH"` — then `bundle exec rspec` (expect
   ≥1470 + this plan's examples, 0 failures), `bundle exec rubocop` (zero offenses, default
   metrics), `bundle exec rake compile`, `cargo test && cargo fmt --check && cargo clippy
   --all-targets -- -D warnings` in ext/lain, `pre-commit run --all-files`.
2. `spec/output_discipline_spec.rb` green (the Neovim frontend lives under
   `lib/lain/frontend/` — verify nothing leaked outside it).
3. **No pending specs survive**: the Ruby↔Rust digest-parity spec T13 parked must be green
   again via T25.
4. Provider-parity shared group green across Mock, Anthropic, AnthropicRaw, Ollama,
   BedrockRaw — the seven gates over the collapsed Event spine.
5. `Ractor.shareable?` specs green for Event in both implementations.
6. Manual pass (the human, recorded in the close-out commit message):
   - Ollama smoke (free, constrained toolset per the house convention): a chat that spawns a
     one-shot subagent, calls `ask_human` and receives a REPL reply, and reads a memory —
     eyeball the journal for :spawn/:message events and the child's tool_result.
   - `LAIN_INTEGRATION=1` embed round trip against local ollama; regenerate
     `corpus_embeddings.json` and confirm the sweep's hybrid assertion still holds.
   - `lain bench sweep -k 5` — eyeball the five-arm report; this is the M6-2.4 deliverable.
   - Attach `Frontend::Neovim` to a real `nvim --listen`: buffers render, edit
     `lain://request`, `:LainResend`, watch the diff.
7. Doc close-out (orchestrator): tick 4-2.1–4-2.3, 5-0.2/5-0.3, 5-1.1–5-1.4, 6-2.1–6-2.4,
   R.7 in `planning/remaining-work.md`; update ROADMAP status + suite counts; note OM-6/GG/
   sibling-template as the remaining M5 tail.
