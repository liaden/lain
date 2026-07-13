# Chunk 2026-07 — cache economics, memory writes, retrieval, session hands

status: done
commit-mode: branch-queue
language: ruby (+ rust for T8)
panel: Ruby — Torvalds, Evans, Metz, Schneeman, Patterson · Rust (T8/T9) — Levien, Gallant, McSherry, Williams

> Approved 2026-07-13; panel-reviewed at draft time (verdict APPROVE-WITH-FIXES, all folded
> in). This committed copy is the execution contract and progress tracker — cards are checked
> off here as they land.

## Intent

Close the roadmap's near-term sequence and open the M5 critical path in one parallel chunk:
the CE-1 breakpoint-cap **bug** (>4 `cache_control` blocks is an API 400 on long sessions),
the CE-2/CE-3 cache-write attribution machinery the harness-variance headline experiment
needs, the memory **write** path + PHI/secret guard (5-3.5), BM25 retrieval + `Context::Recall`
(5-3.3/5-3.4 — critical path to the M6 retrieval sweep), the session-state seam with
`edit_file` and `todo_write` (5-4.1/5-2.1), and the concurrency spike (5-0.1) that gates the
next chunk's subagent band. Specs: `planning/specs/cache-economics.md` (CE-1..3),
`planning/remaining-work.md` (5-x units).

## Grounding

Verified 2026-07-13 against `main` @ `daf5baf` — **998 examples, 0 failures** (`rspec --dry-run`),
`cargo test` 39. Files read: `lib/lain/context.rb`, `context/cache_breakpoints.rb`,
`provider/anthropic_encoding.rb`, `request.rb`, `event.rb`, `journal.rb`,
`middleware/journal_requests.rb`, `agent.rb`, `agent/accounting.rb`, `handler/live.rb`,
`agent/tool_runner.rb`, `tool/invocation.rb`, `tool/contracts.rb`, `tools/*.rb`,
`memory/{index,item,manifest}.rb`, `workspace.rb`, `exe/lain`, `ext/lain/src/lib.rs`,
`ext/lain/Cargo.toml`, `ext/lain/CLAUDE.md`, `spec/support/shared_examples/*`,
`spec/lain/seams/memory_snapshot_seam_spec.rb`, `lain.gemspec`, `Gemfile`, `Rakefile`.

Key seam facts task cards rely on:

- `Context::CacheBreakpoints` (`every: 15`, `lookback: 20`) has **no cap**;
  `AnthropicEncoding#with_stride_breakpoint` (anthropic_encoding.rb:103-109) independently
  places markers every 15 blocks — CE-1's two-layer bug confirmed live.
- `Request` is `Data.define(:model, :system, :tools, :messages, :max_tokens, :stream,
  :reasoning, :extra)`; `digest` = `Canonical.digest(cache_payload)`; `cache_prefix` covers
  tools+system only; wire prefix order is tools → system → messages (request.rb:49-51).
  Neutral markers are `"cache" => true` on block hashes. No `prefix_digests` anywhere.
- `Context#cache_marked_system` (context.rb:98-105) marks the **last system block**; the
  default pipeline is `Reminder.new(workspace:) >> CacheBreakpoints.new` (context.rb:46-48).
- New events: `Data.define` under `module Event` + `include Journalable`; `journal_type`
  derives snake_case from the class name; `spec/lain/event_spec.rb` pins the catalog.
- `Handler::Live#dispatch` (live.rb:68-70) builds `Tool::Invocation(tool_use_id:, context:,
  channel:)`; the Agent passes `context: self` (agent.rb:205). `Tools::ReadFile#perform`
  ignores its invocation — no read-set exists. `Tool::Contracts` (`requires`/`ensures`,
  ancestry-composed, `ContractViolation` → error `Result` at `Handler::Live`) exists and is
  **unused by any tool**.
- Agent loop: `@turn_middleware.call({iteration:, timeline:}) { ... inner.merge(response:,
  settled:) }` (agent.rb:103-113); assistant commit at :151, tool-result commit at :205;
  `@workspace` set once at :74, read at :196; the Journal is reachable only via
  `@accounting`.
- `Memory::Index#write` returns a new Merkle-rooted Index (index.rb:73-77); `Manifest#search`
  returns `Hit(id, description, score, why)` and **raises on blank `why`**; `Manifest#to_reminder`
  renders the one-string Workspace form. Only `memory_read` exists under `lib/lain/tools/`.
- `ext/lain`: magnus 0.8.2, `frozen_shareable` pattern = `Arc<T>`-only TypedData frozen at wrap
  (Turn, lib.rs:516-543); FFI in `#[cfg(not(test))] mod ffi`; crate rules: pure/synchronous,
  stable channel, pinned deps (`cargo deny` bans wildcards), print deny at crate root.
- Shared example groups: `"canonical determinism"`, `"a Regular value"`, `"a monoid"`,
  `"a commutative monoid"`, `"a meet semilattice under ancestry"`, `"a content-addressed
  store"`, `"a Lain::Provider"`. Rust specs select impls by naming `Lain::Ext::*` directly.
- `mixlib-shellout` ~> 3.4 is already a runtime dep; `async` is not a dep anywhere.

**Docs vs code disagreements (docs lose; corrections in Integration checks):**

1. `planning/remaining-work.md` lists 3c-3.2 (repl phase) as unbuilt — `exe/lain` already
   wires `repl_middleware` through `dispatch` (exe/lain:85-133). **Dropped from scope.**
2. ROADMAP's "known follow-up: `Agent::Accounting` not yet built" — built (`agent/accounting.rb`),
   with Ledger sourcing cost from the Journal.
3. CLAUDE.md's Rust table places BM25 out-of-process (it assumed tantivy, which is disk-backed).
   Decision with Joel 2026-07-13: the `bm25` crate is pure in-memory data-structure work →
   in-process `ext/lain` binding under the existing placement rules.
4. `Event::MemoryRoot` doc (event.rb:157-160) says the **bench** records it and the Agent is
   memory-blind; the scope said "wire into the Agent loop". Reconciled: a **turn-phase
   middleware** journals it (T6); the Agent's only change is exposing the committed head digest
   in the turn env.

## Orchestrator contract

- **Pre-work (step 0, orchestrator, before any fan-out):** commit pending `main` state so
  worktrees see the specs — the `.gitignore` + `variance_fixtures.rb` comment diffs, then
  `ROADMAP.md`, `TODO.md`, `planning/`, `references/` + `.gitmodules` (submodules staged with
  `git add -f` per the new ignore rule), `DEBUGGING_NVIM.md`, and this plan copied to
  `planning/specs/chunk-cache-memory-hands.md`. `.claude/` stays untracked. Leaf-first, terse
  messages. Export `PATH="$HOME/.rubies/ruby-4.0.5/bin:$PATH"` in every commit shell
  (pre-commit runs the suite).
- **commit-mode: branch-queue.** Implementing sub-agents work in their own git worktree on
  branch `chunk/T<id>-<slug>`, committing there only. The orchestrator reviews, rebases the
  branch onto current `main` if needed, and merges `--ff-only`. Merge order within a wave:
  smallest diff first, except **T1 merges before T10** (T10's specs compose
  `CacheBreakpoints.new`, whose constructor T1 is changing in the same wave). Only T11
  touches `agent.rb` in the whole plan; wave 2 forks from post-wave-1 `main`.
- **Critique pairing (Joel's instruction):** each implementing sub-agent is paired with a
  `/critique` sub-agent using **only the personas relevant to that card** (Rust roster for T8;
  Ruby roster otherwise; Metz always on seam cards T5/T6/T11). Critique feedback goes to the
  implementer to address as they go; the orchestrator sees the final critique verdict before
  merging.
- **Shared files (wiring diffs only, applied by the orchestrator at merge):** `lib/lain.rb`
  (require lines), `lain.gemspec`, `Gemfile`, `.rubocop.yml`, `CLAUDE.md`,
  `spec/spec_helper.rb`, `.pre-commit-config.yaml`, root `Cargo.toml`.
- **TDD:** every card's ACs become failing specs first (red), then implementation (green).
  Specs `require` their own subject — pre-commit stashes unstaged tracked changes, and
  untracked specs run during every commit.
- Escalation ladder: sub-agent stops on a card trigger → orchestrator researches and answers →
  if still blocked, escalate to Joel with context and 2–3 candidate directions.
- Review: panel sub-agent per task, depth by risk (low = single-pass). Reviewers verify
  empirically; probes that find defects become specs in the fix round.

## Open decisions

None gating. (BM25 tokenizer features — stemming/stopwords on or off — is decided inside T8
as "off by default, deterministic surface tokens for `#why`"; revisiting is a bench sweep,
not a blocker.)

## Waves

```
Wave 1: T1, T2, T5, T8, T10, T11, T14        (no deps; no file overlap; merge T1 before T10)
Wave 2: T3 (←T2), T4 (←T2), T6 (←T5), T7 (←T5), T9 (←T8, T10), T12 (←T11), T13 (←T11)
Critical path: T8 → T9 (the FFI card dominates wall-clock; all chains are depth 2)
```

## Tasks

### T1 — Cap cache breakpoints at 4; encoder becomes pure translation   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/context/cache_breakpoints.rb`, `lib/lain/provider/anthropic_encoding.rb`,
`spec/lain/context/cache_breakpoints_spec.rb`, `spec/lain/provider/anthropic_encoding_spec.rb`
**Reuse:** `Context#cache_marked_system` (context.rb:98-105) spends 1 of the 4;
`translate_block` (anthropic_encoding.rb:95-101) is the pure translation that survives.
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: a long session never exceeds the marker budget
  Given a Timeline rendering more than 100 content blocks with a cache-marked system prompt
  When Context#render runs with the default pipeline
  Then the Request carries at most 4 neutral "cache" markers across system + messages
  And the message markers are tail-clustered: last block marked, oldest intermediates dropped
```
→ spec file: `spec/lain/context/cache_breakpoints_spec.rb`

```gherkin
Scenario: the encoder adds no placement of its own
  Given a message list containing no neutral cache markers
  When AnthropicEncoding encodes it
  Then no cache_control key appears anywhere in the encoded output
```
→ spec file: `spec/lain/provider/anthropic_encoding_spec.rb`

```gherkin
Scenario: cap is a parameter, system marker counts against it
  Given CacheBreakpoints.new(cap: 4) and a cache-marked system block
  When the pipeline renders
  Then at most 3 markers land in messages
```
→ spec file: `spec/lain/context/cache_breakpoints_spec.rb`

**Escalation triggers:**
- An existing spec pins `with_stride_breakpoint` behavior that the raw-vs-SDK differential
  (`spec/lain/provider/`) itself depends on — stop before rewriting the differential.
- Interaction between the cap and `Reminder`'s tail injection (Reminder runs *before*
  CacheBreakpoints in `Context.pipeline`) changes which block is "last" in a way an existing
  spec pins — stop and confirm the intended order.

**Model:** sonnet

### T2 — Request#prefix_digests and the journaled digest chain   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/request.rb`, `lib/lain/event.rb` (extend `RequestSent`),
`lib/lain/middleware/journal_requests.rb`, `spec/lain/request_spec.rb`,
`spec/lain/event_spec.rb`, `spec/lain/middleware/journal_requests_spec.rb`
**Reuse:** `Canonical.digest`; wire-prefix order tools → system → messages (request.rb:49-51);
`Journalable` (`event.rb:22-31`); `JournalRequests` (journal_requests.rb:34-43).
**Shared-file wiring:** none

Design (panel-corrected): the chain must survive **marker movement** — `CacheBreakpoints`
always marks the last message and T1's cap slides the marker window, so a chain sampled *at
marker positions over marker-bearing bytes* would read every append as a rewrite. Therefore:
each chain entry is a `(position, digest)` pair where `position` is the **message index** at
which a marker sits and `digest` is `Canonical.digest` of the **marker-stripped** canonical
sub-structure `{model, tools, system, messages[0..position]}` (strip every `"cache"` key
before digesting; include `model` — the provider cache is per-model). Digests are thus
placement-independent: the same content prefix hashes identically whether or not a marker
sits on it today. `RequestSent` gains a `prefix_digests` field (frozen, `Canonical.normalize`d
— events must stay Ractor-shareable); `JournalRequests` emits it per model call.

**Acceptance criteria:**

```gherkin
Scenario: one entry per marker, deterministic, in wire-prefix order
  Given a Request whose system and messages carry N neutral cache markers
  When prefix_digests is computed twice
  Then both results are the same N (position, digest) pairs in ascending position order
```
→ spec file: `spec/lain/request_spec.rb`

```gherkin
Scenario: digests are marker-placement-independent
  Given two Requests with identical content whose neutral markers sit at different indices
  When prefix_digests is computed for a position both chains contain
  Then the digests at that position are equal
```
→ spec file: `spec/lain/request_spec.rb`

```gherkin
Scenario: divergence localizes at the chain
  Given two Requests identical up to position p and differing after it
  Then their chains agree at every shared position <= p and differ beyond it
```
→ spec file: `spec/lain/request_spec.rb`

```gherkin
Scenario: the Journal carries the chain per model call
  Given an Agent run with JournalRequests innermost
  When a model call is dispatched
  Then the journaled request_sent record includes "prefix_digests" as position/digest pairs
```
→ spec file: `spec/lain/middleware/journal_requests_spec.rb`

**Escalation triggers:**
- `RequestSent`'s payload is documented as O(n²) with dedupe named as future work
  (event.rb:121-137) — if adding the chain tempts a payload-dedupe refactor, don't; chain
  only. Stop if the two can't be separated.
- If a marker sits on a non-final block of a message (foreign pipeline; the default pipeline
  only marks message-final blocks post-T1), the message-index position key is ambiguous —
  stop and propose the truncation rule rather than inventing one.

**Model:** sonnet

### T3 — Byte-identical prelude invariant across processes (CE-3)   [wave 2] [risk: low]

**Depends on:** T2
**Files:** `spec/lain/seams/prelude_invariant_spec.rb` (new; a helper script inline or under
`spec/support/`)
**Reuse:** committed session fixtures (`lib/lain/bench/variance_fixtures.rb`, fixtures under
`spec/fixtures/`); `Request#digest`, `Request#prefix_digests` (T2).
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: two processes render the same bytes
  Given a committed fixture (Timeline, Toolset, Workspace)
  When this process and a spawned fresh ruby process each render it via Context#render
  Then the canonical Request bytes are identical and prefix_digests are equal
```
→ spec file: `spec/lain/seams/prelude_invariant_spec.rb`

Implementation note: spawn the subprocess via `RbConfig.ruby`, never a bare `"ruby"` — the
shell default is the wrong interpreter (3.2.3, per CLAUDE.md), and version skew would present
exactly like the nondeterminism leak this spec hunts.

**Escalation triggers:**
- If the spec FAILS against the current render path, a real nondeterminism leak exists
  (`Time.now` / unsorted keys / per-process value) — report the leaking value, do not patch
  the spec around it.
- If spawning a subprocess needs the compiled `lain.so` and the worktree hasn't built it,
  build via `bundle exec rake compile` — stop only if compile itself fails.

**Model:** sonnet

### T4 — Rewrite-attribution projection over journaled chains (CE-2 offline half)   [wave 2] [risk: medium]

**Depends on:** T2
**Files:** `lib/lain/bench/rewrites.rb`, `spec/lain/bench/rewrites_spec.rb`
**Reuse:** `Journal.records(type: "request_sent")` (journal.rb:99-102); `Ledger::Index.from_journal`
(ledger/index.rb) as the from-journal-projection pattern; `Compare` for the surfacing check.
**Shared-file wiring:** require line in `lib/lain.rb`.

**Acceptance criteria:**

Rewrite semantics (panel-corrected, matches T2's position-keyed chain): a **rewrite** is a
position present in both consecutive chains **with different digests**; rewrite **depth** is
the smallest such position; a position present in only one chain (marker slid or appended) is
**not** a rewrite. Attribution names the digest/position at the divergence.

```gherkin
Scenario: rewrites counted and attributed offline
  Given a Journal with consecutive request_sent records sharing positions whose digests differ
  When Bench::Rewrites projects over it
  Then it reports the rewrite count, each rewrite's depth (smallest differing shared
       position), and the position/digest at the divergence (the breaking turn)
```
→ spec file: `spec/lain/bench/rewrites_spec.rb`

```gherkin
Scenario: appends and marker drift are not rewrites
  Given consecutive records where every shared position carries an equal digest,
        while markers slid and new positions appeared at the tail
  Then the projection reports zero rewrites
```
→ spec file: `spec/lain/bench/rewrites_spec.rb`

**Escalation triggers:**
- If `Usage`/`TurnUsage` does not already carry cache-write token counts, surfacing
  `cache_write_tokens` in `Compare` is a schema change beyond this card — report, don't build.
- If attribution needs Timeline access (not just journal bytes), stop — the spec says this is
  an offline projection over the Journal alone.

**Model:** sonnet

### T5 — Memory::Recorder and the memory_write tool   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/memory/recorder.rb`, `lib/lain/tools/memory_write.rb`,
`spec/lain/memory/recorder_spec.rb`, `spec/lain/tools/memory_write_spec.rb`
**Reuse:** `Memory::Index#write` (memory/index.rb:73-77) and `#checkout`; `Tools::MemoryRead`
(tools/memory_read.rb) as the tool template; `Tool::Input` for the id/description/body schema.
**Shared-file wiring:** require lines in `lib/lain.rb`.

Design: `Recorder` is the one mutable holder of a live immutable `Memory::Index` (single-
threaded, like `Accounting`): `#write` swaps in the new index, `#root` and `#index` expose the
current snapshot, and `#fetch(id)` delegates to the current snapshot so the Recorder
**satisfies the index duck** — `Tools::MemoryRead.new(index: recorder)` works unchanged, no
constructor contract changes. `Tools::MemoryWrite` (tier 1) is constructed with the recorder
injected.

**Acceptance criteria:**

```gherkin
Scenario: a write bumps the root and stays auditable
  Given a Recorder over an empty index
  When memory_write is called with id, description, and body
  Then the recorder's root changes and the tool result names the id and new root
  And a second write to the same id leaves the first reachable via checkout of the old root
```
→ spec file: `spec/lain/memory/recorder_spec.rb`, `spec/lain/tools/memory_write_spec.rb`

```gherkin
Scenario: reads in the same session see the write
  Given a MemoryWrite holding the recorder and a MemoryRead constructed with the recorder
        as its index duck
  When a write lands and a read of that id follows
  Then the read returns the written body
```
→ spec file: `spec/lain/tools/memory_write_spec.rb`

**Escalation triggers:**
- `Memory::Index#write`'s signature may not match the tool's input shape 1:1 (Item
  construction, digest fields) — adapt in the tool, stop if Index itself needs changing.
- If `MemoryRead` calls anything on its index beyond `#fetch` that the Recorder cannot
  delegate cleanly, stop and propose rather than widening the Recorder's surface.

**Model:** sonnet

### T6 — Journal MemoryRoot per turn via a Journal decorator   [wave 2] [risk: medium]

**Depends on:** T5
**Files:** `lib/lain/memory/journal_memory_root.rb` (a Journal-duck decorator),
`spec/lain/memory/journal_memory_root_spec.rb`,
`spec/lain/seams/memory_snapshot_seam_spec.rb` (rewire from manual emission to real wiring)
**Reuse:** `Event::MemoryRoot` (event.rb:157-178); `Event::TurnUsage` — journaled inside
`#step` after the assistant commit and *before* `perform_tools`, so it already carries the
assistant digest at the exact instant the recorder's root is the pre-write root the render
saw; `Sink::Null` as the decorator/Null-duck exemplar.
**Shared-file wiring:** require line in `lib/lain.rb`.

Design (panel-corrected): **zero `agent.rb` changes** — the Agent stays literally memory-blind.
`JournalMemoryRoot.new(journal:, recorder:)` satisfies the Journal duck and is passed *as* the
Agent's journal; on recording a `turn_usage` event it also emits
`MemoryRoot(turn_digest: event digest, root: recorder.root)`. The assistant digest is the
join key (`event.rb:161-163` documents it as mandatory; the seam spec pins
`memory_root.turn_digest == turn_usage.digest`), and the pre-write root matches "what was
readable at that turn".

**Acceptance criteria:**

```gherkin
Scenario: every committed turn pairs with its live memory root
  Given an Agent whose journal is JournalMemoryRoot wrapping the real Journal,
        with tools that write memory
  When a run commits turns
  Then the Journal holds one memory_root record per turn, in commit order, each pairing the
       assistant turn's digest (== the turn_usage digest) with the recorder's pre-write root
```
→ spec file: `spec/lain/seams/memory_snapshot_seam_spec.rb`

```gherkin
Scenario: resume recalls against the exact snapshot
  Given the journaled memory_root records of a finished run
  When an index is checked out at a recorded root
  Then memory_read over that snapshot returns what was readable at that turn (recall is pure)
```
→ spec file: `spec/lain/seams/memory_snapshot_seam_spec.rb`

**Escalation triggers:**
- If more than one `turn_usage` lands per committed turn (retry paths, future multi-call
  turns), the decorator would emit duplicate roots for one digest — stop and confirm dedupe
  semantics rather than guessing.
- If the seam spec's pinned pairing (`memory_root.turn_digest == turn_usage.digest`, pre-write
  root) conflicts with any AC as written, stop — do not touch `agent.rb` to resolve it.

**Model:** sonnet

### T7 — Secret write-refusal tool middleware (5-3.5)   [wave 2] [risk: low]

**Depends on:** T5
**Files:** `lib/lain/middleware/refuse_secret_writes.rb`, `lib/lain/event.rb` (add
`Event::WriteRefused`), `spec/lain/middleware/refuse_secret_writes_spec.rb`,
`spec/lain/event_spec.rb` (catalog addition)
**Reuse:** the tool-phase middleware seam (`ToolRunner#dispatch`, tool_runner.rb:45-57 — env
is `{effect:, context:}`, result under `:result`); `Journalable`; `Tool::Result.error`.
**Shared-file wiring:** require line in `lib/lain.rb`.

Design: deterministic secret patterns (API-key shapes, PEM blocks, obvious credential
assignments) + an injectable predicate seam (Null Object default) so a future ollama oracle
(OR-1, `planning/specs/oracles.md`) becomes a swappable arm. PHI heuristics are explicitly
out of scope — that is the oracle's job.

**Acceptance criteria:**

```gherkin
Scenario: a secret never reaches the index
  Given tool middleware including RefuseSecretWrites
  When a memory_write effect whose input matches a secret pattern is dispatched
  Then downstream is never called, the tool result is an error the model can read,
       and the Journal holds a write_refused record that does NOT contain the secret bytes
```
→ spec file: `spec/lain/middleware/refuse_secret_writes_spec.rb`

```gherkin
Scenario: ordinary writes pass through untouched
  Given the same middleware
  When a memory_write with benign input is dispatched
  Then the write proceeds and no refusal is journaled
```
→ spec file: `spec/lain/middleware/refuse_secret_writes_spec.rb`

```gherkin
Scenario: only write-shaped effects are guarded
  Given the same middleware
  When a non-memory_write effect (e.g. read_file, bash) whose input matches a secret
       pattern is dispatched
  Then it passes through unrefused
```
→ spec file: `spec/lain/middleware/refuse_secret_writes_spec.rb`

**Escalation triggers:**
- `Tool::Input`'s header comment says validations check shape, not safety — this middleware
  IS a safety control, so it must NOT be implemented as an Input validator. If the middleware
  seam can't produce an error `Result` without invoking the tool, stop.
- If pattern matching needs the coerced (post-validation) input rather than the raw effect
  input, stop and propose where coercion happens.

**Model:** sonnet

### T8 — BM25 in ext/lain via the bm25 crate   [wave 1] [risk: high]

**Depends on:** none
**Files:** `ext/lain/Cargo.toml` (add pinned `bm25` dep), `ext/lain/src/lib.rs` (or a new
`src/bm25.rs` module), `spec/lain/rust/bm25_spec.rb`
**Reuse:** the `frozen_shareable` `Arc`-only TypedData pattern (`Turn`, lib.rs:516-543); the
`#[cfg(not(test))] mod ffi` split so `cargo test` needs no libruby; `define_error` /
`Lain::Ext` registration in `init` (lib.rs:949-1023).
**Shared-file wiring:** none (root `Cargo.toml` is a workspace list only; unchanged).

Design: `Lain::Ext::Bm25` — built **once from a batch** of `[id, text]` pairs (rule #4),
immutable after build, `frozen_shareable` **only if an audit earns it**: `frozen_shareable`
is an unchecked promise to magnus, and `Arc<T>` over a third-party type is honest only if
nothing reachable has interior mutability. Record a source audit of the wrapped crate types
(no `Cell`/`RefCell`/`Mutex`/lazy caches anywhere reachable) in the crate comment; the Turn
pattern (lib.rs:516-543) works because `TurnData` is ours. `search(query, k)` returns
`[[id, score, matched_tokens], ...]` — matched tokens via the crate's public `Tokenizer`
(tokenize query ∩ document tokens stored at build). **Equal-score ties break by build-batch
insertion order** (pinned, matching Manifest's deterministic-ordering convention). Tokenizer
configured deterministic: no language detection, stemming/stopwords off (surface tokens make
`#why` honest). No `parallelism` feature. Degenerate builds (empty corpus, duplicate ids)
raise named errors via the existing `define_error` pattern. Pure-Rust unit tests for
build/search/intersection.

**Acceptance criteria:**

```gherkin
Scenario: deterministic ranked retrieval with explainable hits
  Given an index built from [id, text] pairs
  When searched with a query and k
  Then at most k hits return, ranked by descending BM25 score with equal-score ties in
       build-batch insertion order, each carrying the tokens shared by query and document
  And two builds from the same pairs return byte-identical results for the same query
```
→ spec file: `spec/lain/rust/bm25_spec.rb` (+ `cargo test` cases in the crate)

```gherkin
Scenario: degenerate builds fail loudly, and the crate suite does not regress
  Given an empty corpus or duplicate ids
  When the index is built
  Then a named Lain error is raised (define_error pattern), and `cargo test` passes with
       at least the pre-existing 39 cases
```
→ spec file: `spec/lain/rust/bm25_spec.rb` (+ `cargo test`)

```gherkin
Scenario: the exact-term query wins
  Given documents where exactly one contains the rare term "dactinomycin"
  When searched for "dactinomycin"
  Then that document is the top hit and its matched tokens include the term
```
→ spec file: `spec/lain/rust/bm25_spec.rb`

```gherkin
Scenario: no match, no noise
  Given any index
  When searched with a query sharing no tokens with any document
  Then the result is empty
```
→ spec file: `spec/lain/rust/bm25_spec.rb`

**Escalation triggers:**
- The `bm25` crate cannot expose matched tokens even via its public `Tokenizer` trait, or its
  scoring is nondeterministic across processes — stop with alternatives assessed
  (`bm25-vectorizer`, hand-rolled BM25 scoring over `indexmap`).
- `cargo deny` rejects the crate's dependency tree (wildcards/duplicates/licenses) — stop with
  the deny report.
- The interior-mutability audit fails (any `Cell`/`RefCell`/`Mutex`/lazy cache reachable from
  the wrapped type) — fall back to non-shareable `free_immediately` and SAY SO in the card
  report; do not claim `frozen_shareable` on an unaudited type.

**Model:** opus

### T9 — Memory::Bm25 wrapper and the shared index contract   [wave 2] [risk: medium]

**Depends on:** T8, T10
**Files:** `lib/lain/memory/bm25.rb`, `spec/lain/memory/bm25_spec.rb`,
`spec/support/shared_examples/memory_index_laws.rb` (new),
`spec/lain/memory/manifest_spec.rb` (consume the shared group)
**Reuse:** `Memory::Manifest`'s `Hit` (manifest.rb:29-31 — `why` raises on blank) and its
search duck; `Lain::Ext::Bm25` (T8); shared-example registration style of
`spec/support/shared_examples/regular.rb`.
**Shared-file wiring:** require line in `lib/lain.rb`.

Design: `Memory::Bm25.new(index:)` builds the Rust index from the snapshot's items
(description + body), returns `Hit`s whose `why` is "matched tokens: …" from the binding.
The shared group `"a memory search index"` pins the cross-impl contract: deterministic
results **including pinned equal-score tie order** (insertion/id order per impl, stable across
runs), `Hit` duck, non-blank `why`, k-bounding, empty-on-no-match — **not** score values
(scales differ by design). Manifest is the baseline arm; no Ruby BM25 twin.

**Acceptance criteria:**

```gherkin
Scenario: both indexes honor one contract
  Given the shared example group "a memory search index"
  When run against Memory::Manifest and Memory::Bm25 over the same fixture corpus
  Then both pass: deterministic hits, k-bounded, Hit#why never blank, empty on no match
```
→ spec file: `spec/support/shared_examples/memory_index_laws.rb`, consumed by
`spec/lain/memory/{manifest,bm25}_spec.rb`

```gherkin
Scenario: exact drug-name recall (remaining-work 5-3.3 acceptance)
  Given a corpus where one item's body names "imatinib"
  When Memory::Bm25 searches "imatinib"
  Then the hit is that item and #why names the matched token
```
→ spec file: `spec/lain/memory/bm25_spec.rb`

```gherkin
Scenario: Recall composes over Bm25
  Given a pipeline Reminder >> CacheBreakpoints >> Recall over a Memory::Bm25 snapshot
  When rendered
  Then recalled hits land after the last neutral marker (uncached tail)
```
→ spec file: `spec/lain/memory/bm25_spec.rb`

**Escalation triggers:**
- If Manifest cannot pass a common determinism/ordering pin without weakening its existing
  spec, pin order-stability per impl rather than cross-impl ordering — stop only if even that
  fails.
- If building from `index` snapshots is slow enough to need caching keyed by root, note it as
  a follow-up; do not build caching here.

**Model:** sonnet

### T10 — Context::Recall combinator   [wave 1] [risk: medium]

**Depends on:** none (uses Manifest; Bm25 slots in via T9)
**Files:** `lib/lain/context/recall.rb`, `spec/lain/context/recall_spec.rb`
**Reuse:** `Context::Reminder` (context/reminder.rb) as the tail-injection template;
`Context::Base` `>>`/`requires` (context/base.rb:21-63); `Manifest#search` + the
`Manifest#to_reminder` rendering shape.
**Shared-file wiring:** require line in `lib/lain.rb`.

Design: `Recall.new(index:, k:)` holds a frozen index snapshot; the query is a pure function
of the message list with a **pinned extraction rule** (panel-corrected — after a tool turn
the last user message is tool_results, and Reminder has already appended `<workspace>`
blocks): take the text blocks of the last user message, **excluding `<workspace>`-tagged
blocks and tool_result blocks**; if that yields nothing, fall back to the most recent user
message with real text; if none, inject nothing. Ordered **after** `CacheBreakpoints`, it
appends one recall block (id + description + why per hit) to the message tail, beyond the
last neutral marker. `requires` stays `[]`. Purity: same snapshot + same messages →
byte-identical output.

**Acceptance criteria:**

```gherkin
Scenario: recall rides the uncached tail
  Given a pipeline Reminder >> CacheBreakpoints >> Recall with a populated index
  When rendered over a Timeline whose last user message matches indexed items
  Then every block up to and including the last neutral marker is byte-identical to the
       same render without Recall, and the recall block appears after that marker
```
→ spec file: `spec/lain/context/recall_spec.rb`

```gherkin
Scenario: recall is pure and explainable
  Given the same index snapshot and message list
  When rendered twice
  Then the outputs are byte-identical and each recalled line carries the hit's why
```
→ spec file: `spec/lain/context/recall_spec.rb`

```gherkin
Scenario: nothing to recall, nothing injected
  Given an index with no matches for the tail message
  Then the rendered messages equal the without-Recall render exactly
```
→ spec file: `spec/lain/context/recall_spec.rb`

```gherkin
Scenario: a tool-result tail recalls from the last real user text (the common case)
  Given a Timeline whose last user message contains only tool_result blocks
  When rendered with Recall
  Then the query derives from the most recent user message with real text,
       never from <workspace> blocks or tool_results
```
→ spec file: `spec/lain/context/recall_spec.rb`

**Escalation triggers:**
- `CacheBreakpoints`' spec pins "last block is marked" — Recall appending after the marker
  changes which block is last *within one render*. If that spec (or T1's cap rework, running
  in the same wave) asserts something Recall breaks, coordinate through the orchestrator —
  do not edit `cache_breakpoints_spec.rb` from this card.
- If deriving the query needs anything beyond the message list (Workspace, Timeline meta),
  stop — that's an impurity.

**Model:** sonnet

### T11 — Session state seam: read-set + workspace channel   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/session.rb` (Session + Session::Null), `lib/lain/agent.rb` (construct the
session; pass `context: @session` at :205; compose
`workspace: @workspace.with(*@session.reminders)` at :196), `lib/lain/tools/read_file.rb`
(record reads),
`spec/lain/session_spec.rb`, `spec/lain/tools/read_file_spec.rb`, `spec/lain/agent_spec.rb`
(thread-through coverage)
**Reuse:** `Tool::Invocation#context` (tool/invocation.rb:18-26 — the documented threading
point, no new plumbing); `Sink::Null` as the Null Object exemplar; `Workspace#with`
(workspace.rb:42) for composition; `Provider::Mock`/`Handler::Mock` for the integration spec.
**Shared-file wiring:** require line in `lib/lain.rb`.

Design: `Session` is deliberately mutable single-run state (not a value object; never enters
the Timeline): a read-set (`record_read(path)` / `read?(path)`) and a reminders channel
(`reminders` — empty now; T13 adds todos). **Path identity is pinned:** both `record_read`
and `read?` normalize via `File.expand_path`, so `"./app.rb"` read then `"app.rb"` queried
match. `Session::Null` satisfies the duck (no-ops, `read?` false, empty reminders) so no call
site nil-checks. The Agent composes per render with Workspace's existing API —
`@workspace.with(*@session.reminders)` — keeping Session ignorant of Workspace and Workspace
frozen and sent-not-stored.

**Acceptance criteria:**

```gherkin
Scenario: reads are recorded
  Given a Session threaded as the invocation context
  When read_file succeeds on a path
  Then session.read?(path) is true, and false for paths never read
```
→ spec file: `spec/lain/tools/read_file_spec.rb`, `spec/lain/session_spec.rb`

```gherkin
Scenario: path spelling does not defeat the read-set
  Given "./app.rb" was recorded as read
  When read? is asked about "app.rb" (and vice versa)
  Then both spellings answer true
```
→ spec file: `spec/lain/session_spec.rb`

```gherkin
Scenario: the null session keeps bare specs working
  Given a tool invoked with a Session::Null context
  When it records a read or asks read?
  Then nothing raises and read? is false
```
→ spec file: `spec/lain/session_spec.rb`

```gherkin
Scenario: the agent threads one session end to end
  Given an Agent run over Provider::Mock where a tool call reads a file
  When a later tool asks its invocation context
  Then it sees the same session with the read recorded
```
→ spec file: `spec/lain/agent_spec.rb`

```gherkin
Scenario: session reminders reach the request tail without touching the Timeline
  Given a session with a reminder
  When the Agent renders a Request
  Then the reminder rides the workspace tail and no Timeline turn contains it
```
→ spec file: `spec/lain/agent_spec.rb`

**Escalation triggers:**
- `context: self` (agent.rb:205) currently hands tools the Agent. Grep for any consumer of
  `invocation.context` beyond specs before replacing — if anything depends on Agent-as-context,
  stop.
- The output-discipline and Ractor-shareability specs must stay green: Session is mutable by
  design, so it must never become reachable from a frozen value object — if a spec trips, stop.
- If per-render workspace composition breaks `Context#render` purity expectations pinned in
  `context_spec.rb` (same args → same bytes still holds; the *args* now vary by session state),
  stop and confirm the framing.

**Model:** opus

### T12 — Tools::EditFile with the read-before-write contract (5-4.1)   [wave 2] [risk: medium]

**Depends on:** T11
**Files:** `lib/lain/tools/edit_file.rb`, `spec/lain/tools/edit_file_spec.rb`
**Reuse:** `Tool::Contracts` (`requires`, tool/contracts.rb:34-43 — the doc's motivating
example IS this card); `Tools::ReadFile` as the tier-1 template; `Tool::Result.error` for
loud failures; `Handler::Live`'s ContractViolation→error-Result conversion (tool.rb:23-27).
**Shared-file wiring:** require line in `lib/lain.rb`.

Design: tier 2, `str_replace` semantics — `path`, `old_string`, `new_string`; `old_string`
must occur exactly once. Precondition via the contract mechanism:
`requires("file was read this session") { |input, inv| inv.context.read?(input.path) }` —
note **`input.path`, not `input["path"]`**: `Tool#call` hands contracts the coerced
`Tool::Input` instance (tool.rb:117-119). The doc example in `tool/contracts.rb:34-36` has
this same latent bug; fix that comment in passing. The violation message must name what the
session knows ("path was never read this session"), not just the contract label. A successful
edit re-records the path in the read-set (content changed under the same path).

**Acceptance criteria:**

```gherkin
Scenario: writing blind is refused loudly
  Given a session where the target path was never read
  When edit_file runs through Handler::Live
  Then the precondition raises ContractViolation and the model receives an error result
       naming the unmet contract
```
→ spec file: `spec/lain/tools/edit_file_spec.rb`

```gherkin
Scenario: a unique replacement lands
  Given the path was read this session and old_string occurs exactly once
  When edit_file runs
  Then the file contains new_string in place of old_string and the result reports success
```
→ spec file: `spec/lain/tools/edit_file_spec.rb`

```gherkin
Scenario: ambiguity is an error, not a guess
  Given old_string occurs zero or multiple times in the file
  When edit_file runs
  Then the result is an error naming the count, and the file is unchanged
```
→ spec file: `spec/lain/tools/edit_file_spec.rb`

**Escalation triggers:**
- If `Handler::Live` does not actually convert `ContractViolation` into an error `Result` as
  tool.rb:23-27 documents (first real consumer of that path) — stop; that's a defect to
  surface, not to work around in the tool.
- If the read-set is path-based but the file changed on disk since the read (external edit),
  this card does NOT add digest staleness checking — note it as a follow-up if it comes up.

**Model:** sonnet

### T13 — todo_write riding the session workspace channel (5-2.1)   [wave 2] [risk: low]

**Depends on:** T11
**Files:** `lib/lain/tools/todo_write.rb`, `lib/lain/session.rb` (todos on the reminders
channel), `spec/lain/tools/todo_write_spec.rb`, `spec/lain/session_spec.rb` (todo additions)
**Reuse:** `Session`'s reminders channel (T11); `Manifest#to_reminder` as the render-to-one-
string precedent; `Tool::Input` for the todo-list schema.
**Shared-file wiring:** require line in `lib/lain.rb`.

Design: `todo_write` replaces the whole todo list (deterministic, no merge logic); the session
renders todos as one reminder string; the Agent's per-render composition (T11) carries it into
the Request tail.

**Acceptance criteria:**

```gherkin
Scenario: todos ride the request tail, never the Timeline
  Given an Agent whose session holds todos written by todo_write
  When the next Request renders
  Then the todo list appears in the workspace tail and no Timeline turn contains it
```
→ spec file: `spec/lain/tools/todo_write_spec.rb`

```gherkin
Scenario: todos do not resurrect on rewind
  Given a run that wrote todos, then forked/rewound the Timeline to an earlier digest
  When rendering from the rewound Timeline with the same session
  Then the rendered todos are the session's current list, not a resurrected historical one
```
→ spec file: `spec/lain/tools/todo_write_spec.rb`

```gherkin
Scenario: replacement is total
  Given an existing todo list
  When todo_write submits a new list
  Then the rendered reminder shows exactly the new list
```
→ spec file: `spec/lain/tools/todo_write_spec.rb`

**Escalation triggers:**
- If rendering todos requires Workspace itself to gain todo-awareness (a new field rather
  than the reminders channel), stop — Workspace stays a dumb frozen value.
- If the rewind AC can't be expressed without `Timeline#fork` semantics this card shouldn't
  touch, use the existing fork spec fixtures — stop if none fit.

**Model:** sonnet

### T14 — Concurrency spike: Async × Mixlib::ShellOut (5-0.1)   [wave 1] [risk: low]

**Depends on:** none
**Files:** `spec/spikes/async_shellout_spike_spec.rb` (tagged `:spike`, excluded by default
like `:integration`), `docs/concurrency.md` (decision recorded)
**Reuse:** `docs/concurrency.md`'s existing analysis (fibers leaning, `Thread#kill` rejection);
`Tools::Bash`'s `Mixlib::ShellOut` usage as the workload shape; the `:integration` tag-gating
pattern in `spec/support/`.
**Shared-file wiring:** `gem "async"` added to the Gemfile `:development, :test` group
(orchestrator applies); spike tag exclusion in `spec/spec_helper.rb` if not derivable from the
existing tag support (orchestrator applies).

Deliverable is a **decision**, empirically grounded: does `Mixlib::ShellOut` under the `async`
reactor stall the event loop (its internal `IO.select` at `unix.rb:282/:406` not yielding to
the fiber scheduler), or does it cooperate? Record the answer + recommendation (offload to a
thread vs native cooperation) in `docs/concurrency.md`, dated, with the spike runnable.

**Acceptance criteria:**

Two mutually exclusive scenarios are written; **exactly one is committed passing** (the other
stays as documentation of the alternative, skipped with a reason naming the measurement):

```gherkin
Scenario: ShellOut starves the reactor
  Given two concurrent Async tasks: one Mixlib::ShellOut sleep-command, one pure-Ruby ticker
  When run under the async reactor (spike-tagged spec)
  Then the ticker records no progress during the shellout window
```

```gherkin
Scenario: ShellOut cooperates with the fiber scheduler
  Given the same two tasks
  When run under the async reactor
  Then the ticker records progress throughout the shellout window
```
→ spec file: `spec/spikes/async_shellout_spike_spec.rb`; plus `docs/concurrency.md` records
the measured result, the pinned ruby/async/mixlib versions, and the chosen model for 5-0

**Escalation triggers:**
- If the answer is version-dependent (ruby 4.0 fiber scheduler vs the gem's IO path), pin the
  observed versions in the doc — stop only if the result is nondeterministic across runs.
- Do not refactor `Tools::Bash` or adopt the model anywhere — this card decides, 5-0.3 adopts
  (next chunk).

**Model:** sonnet

## Integration checks

After the last wave merges, the orchestrator runs on `main`:

1. `bundle exec rake compile && bundle exec rspec` — full suite green (was 998; expect growth).
2. `bundle exec rubocop` — clean at default metrics (no `Metrics/*` loosening slipped in).
3. `cargo test && cargo clippy --all-targets -- -D warnings && cargo fmt -- --check && cargo deny check`.
4. `pre-commit run --all-files`.
5. **Doc reconciliation commit:** ROADMAP status/near-term-sequence updated (CE-1 done,
   CE-2/CE-3 done, 5-2.1/5-3.3/5-3.4/5-3.5/5-4.1/5-0.1 done, 3c-3.2 marked already-built);
   `planning/remaining-work.md` check-offs; CLAUDE.md Rust table row for BM25 corrected
   (in-process `bm25` crate, tantivy note removed) and the tools list updated if it names
   tools; note the known follow-up "Memory::Bm25 rebuild is O(corpus) per snapshot — cache
   keyed by index root when Recall drives a moving index"; this plan's status → done.
6. **Manual pass (Joel):** one live `exe/lain chat` smoke run exercising read → edit_file →
   todo_write → memory_write, eyeballing the rendered tail in the Journal; P.1–P.3 remain
   deferred to a Console-key session.


---

## Close-out (2026-07-13)

All 14 cards landed on `main` via ff-only merges; every implementer ran TDD red-first in an
isolated worktree and passed a persona review panel (depth by risk). Final integration:
**1161 examples / 0 failures**, rubocop clean, `cargo test` 49 + clippy/fmt/deny clean,
`pre-commit run --all-files` green.

**What the panels caught (fixed before merge):**
- T2/T4 (plan-time BLOCKER): the digest chain redesigned to (position, digest) pairs over
  marker-stripped bytes — the original marker-sampled design would have read every append as
  a rewrite.
- T6 (plan-time BLOCKER): MemoryRoot journaling became a Journal decorator keyed off
  TurnUsage — zero agent.rb changes, and the recorded root is provably the pre-write root the
  render saw.
- T7: the `sk-` secret pattern false-positived on hyphenated prose (live-demonstrated);
  anchored with a lookbehind, probe cases became specs.
- T12: `scan`-based occurrence counting missed overlapping matches ("aa" in "aaa" reported
  unique); replaced with an overlap-aware walk that errors on ambiguity.
- T3: the cross-process divergence failure message now names the first differing byte offset
  with windowed excerpts (was an unreadable truncated diff).
- T5: a dead rescue claiming to catch blank ids (ActiveModel presence intercepts first);
  both rejection layers now spec-pinned where they actually live.
- T8's panel proved cross-process determinism (3 processes, randomized hash seed,
  byte-identical results) and audited the crate for interior mutability before honoring
  `frozen_shareable`.

**Orchestrator decisions during execution:**
- RUSTSEC-2025-0057 (`fxhash` unmaintained, advisory-only) ignored in `deny.toml` with a WHY
  comment — fxhash's determinism is load-bearing; revisit if bm25 upstream migrates hashers.
- T13 used Tool's raw-schema path instead of `Tool::Input` (nested object arrays don't fit
  the ActiveModel DSL; panel verified the raw path is first-class and validation is loud).
- Wave 2 cards started as soon as their specific dependencies merged rather than at the wave
  boundary; the plan's file-disjointness made this safe.

**Follow-ups (not built, tracked):**
1. `Memory::Bm25` rebuilds its index O(corpus) per snapshot — add a root-digest-keyed cache
   when Recall drives a moving index.
2. No structural ≤4-marker guard outside `Context.pipeline` — a hand-built Request with >4
   markers still 400s at the API; consider a loud Request/Provider-level assertion.
3. 5-0.3 must re-verify ShellOut cooperation under stdout-flood / CPU-heavy children before
   adopting no-offload for all bash workloads.
4. `Bench::Rewrites` reads a model switch as a rewrite at the earliest shared position
   (per-model digests by design) — segment journals per arm before cross-model comparison
   (documented + spec-pinned).
5. `Invocation#context` is now semantically the Session; a future tool wanting a second
   collaborator will contend for the one slot.
6. Pre-existing oddity noticed during pre-work: a nested
   `references/papers/rst/references/papers/rst/` path exists in the corpus — worth flattening.
