# Memory read path — manifest in context, replay-side roots, Bm25 cache

status: done (2026-07-15 — T1 21f3231, T2 9262b73, T3 322b42f; suite 1449→1470)
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman · Aaron Patterson

## Intent

Close out roadmap units **5-3.1** and **5-3.2** (`planning/remaining-work.md` § M5 · Stream 5-3).
The 2026-07-13 chunk built every memory *class* — `Memory::Index` (content-addressed,
root-per-write), `Recorder`, `JournalMemoryRoot`, `Manifest`, `Tools::MemoryRead` — but the
read path is wired into **nothing**: `exe/lain` hands the model `memory_write` and no way to
read anything back, `Manifest`/`MemoryRead` are constructed only in specs, and a loaded
recording cannot reconstruct the memory index its renders saw. This plan wires the read path
into the live session, makes `Session::Loader` rebuild per-turn memory roots (closing the
5-3.1 "dry replay recalls against the recorded snapshot" gap at the bench, not just in a seam
spec), and lands the tracked Bm25 root-keyed-cache follow-up (chunk-cache-memory-hands
close-out follow-up #1).

**Decided out of scope** (interview, 2026-07-15): the harness-variance experiment and all its
machinery (R.7 `bench record --provider`, the `Compare` cache-write column, grader threading
into `Bench::Variance`) — deferred whole. Wiring `Context::Recall` into production — the
design plan names `Manifest` (descriptions in context + `memory_read` pull) as the default
arm; push-recall stays a bench arm pending open decision #7 (pull vs push — ask the bench).

## Grounding

Verified against code 2026-07-15 (main @ `590414e`, 1449 examples / 0 failures):

- `Memory::Index#write` returns a new Index with a new root (pure, Merkle-linked nodes over a
  shared `Store`); `Memory::Recorder` is the one mutable holder (`#write` swaps and returns
  the new root; delegates `root`/`fetch`; satisfies the index duck `Tools::MemoryRead` needs).
- `Memory::JournalMemoryRoot` (a Journal decorator) already emits one `Event::MemoryRoot`
  (`turn_digest:`, `root:`) per `Event::TurnUsage`, root read at emit time = the pre-write
  snapshot the render saw. Pinned by `spec/lain/seams/memory_snapshot_seam_spec.rb`.
- `Memory::Manifest#to_reminder` renders the sorted "id | description" block;
  `manifest_spec.rb` already pins digest-identical `Context#render` across write orders.
  `Manifest::Hit` enforces non-blank `why`, finite non-negative score.
- The per-render dynamic channel is `Session#reminders`: `Agent#step` renders via
  `@workspace.with(*@session.reminders)` (`lib/lain/agent.rb:203`). `Session::Null` offers no
  reminders. Todos already ride this channel (`Session#write_todos` → `#reminders`).
- `exe/lain` `#chat` builds one `Memory::Recorder` per session and hands the toolset only
  `Tools::MemoryWrite` (`build_toolset`, exe/lain:166–175). No `MemoryRead`, no manifest.
- `Bench::Session.write` records header + one `turn` record per turn into the same NDJSON the
  Journal owns; `JournalMemoryRoot`'s `memory_root` records land in that stream too.
  `Bench::Session::Loader` re-commits every turn (raising `Session::Corrupt` on digest
  mismatch) but **ignores `memory_root` records entirely**; `Recording` carries no memory
  state. `Bench::DryReplay` byte-diffs `Request#cache_payload` and is memory-blind.
- `Memory::Bm25.new(index:)` rebuilds the `Lain::Ext::Bm25` engine O(corpus) on every
  construction; nothing caches by root (close-out follow-up #1). Empty corpus → `@engine=nil`.
- `Middleware::RefuseSecretWrites` withholds a credential-shaped `memory_write` **before** it
  reaches the recorder — the tool_use still appears in the recorded timeline with an error
  `tool_result`, but the write never entered the index. Any replay that re-applies raw
  tool_use inputs must skip these or its roots diverge from the journaled chain.

Docs vs code, resolved in code's favor:

- `remaining-work.md` lists 5-3.1/5-3.2 unchecked while their dependents (5-3.3/3.4/3.5) are
  ✅ — the classes landed 2026-07-13; what remains is the wiring this plan does.
- `ROADMAP.md:609-610` claims `Compare` has "cache-write columns" — it does not
  (`Compare::METRICS` is tokens/cache-hit/cost/score); CE-2 shipped *attribution*
  (`Request#prefix_digests` + `Bench::Rewrites`), not a column. Out of scope here; noted so
  nobody grounds the deferred experiment on the ROADMAP sentence.
- `lib/lain/event.rb` (~209–233) still documents `Event::MemoryRoot` as "Recorded by the
  BENCH … never by the Agent"; the actual emitter is the `JournalMemoryRoot` decorator. T2
  fixes the comment where it touches those semantics.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lain.gemspec`,
  `Gemfile`, `.rubocop.yml`, `spec/spec_helper.rb`, `.pre-commit-config.yaml`, `CLAUDE.md`.
  Unit index files (`lib/lain/memory.rb`) are wiring: the implementing agent **applies the
  one-line require in its own worktree** (its spec cannot load otherwise — specs load via
  `require "lain"`) and hands the diff back; the orchestrator folds that line into the
  card's own commit, never a separate wiring commit (the untracked-spec pre-commit trap).
- Doc reconciliation (ROADMAP / `remaining-work.md` check-offs, this plan's status) is the
  orchestrator's close-out commit, not card scope — see Integration checks.

## Open decisions

None gating these cards. (Pull-vs-push recall remains open decision #7 in
`remaining-work.md`; this plan deliberately ships only the pull arm.)

## Waves

Wave 1: T1, T2, T3   (no unmet deps; files disjoint)
Critical path: T2 (largest single card; no chains — all cards independent)

## Tasks

### T1 — Wire the memory read path into the live session          [wave 1] [risk: medium] ✅ landed 21f3231 (panel: APPROVE-WITH-FIXES, mechanical — `build_agent` requires `session:`)

**Depends on:** none
**Files:** `lib/lain/session.rb` (modify), `exe/lain` (modify),
`spec/lain/session_spec.rb` (modify), `spec/lain/cli_spec.rb` (modify),
`spec/lain/seams/memory_read_path_seam_spec.rb` (create)
**Reuse:** `Memory::Manifest#to_reminder` (sorted, deterministic — do not re-render);
`Memory::Recorder#index`; the todos precedent in `Session#write_todos`/`#reminders` and
`Session::Null`; `Tools::MemoryRead.new(index:)` accepts the Recorder duck already; the
`Provider::Mock` scripted-tool pattern (`write_call`/`tool_response` helpers) in
`spec/lain/seams/memory_snapshot_seam_spec.rb` is the seam spec's template;
`Request#prefix_digests` for the cache-stability AC.
**Shared-file wiring:** none

The Session gains an injected memory source (the session's `Memory::Recorder`), and
`#reminders` includes the manifest block whenever the index is non-empty — that is the only
per-render channel, and it rides the uncached tail exactly like todos. Note `exe/lain`
constructs **no** Session today — `Agent.new` defaults `session: Session.new` — so the card's
wiring move is: build the Session in `exe/lain`, hand it the recorder, and pass it via
`Agent.new(session:)`; `build_toolset` gains `Tools::MemoryRead.new(index: recorder)`.
`Session.new`'s memory source defaults to an empty holder (Null Object over nil checks —
never a `@memory &&` guard in `#reminders`), and `Session::Null` stays reminder-free.
Keep the Session's dependency on `Memory` message-shaped (it needs only "give me manifest
lines"), not type-checked. Two rulings to honor: (a) `#reminders` runs on **every** render
(see `write_todos`' recorded panel ruling two methods above), so memoize the rendered
manifest block keyed by the recorder's `index.root` — the content address is the free
invalidation key, the same trick T3 uses; (b) label the block at the session layer the way
todos carry a heading (e.g. a first line naming `memory_read` as the way to open an id) —
`Manifest#to_reminder` stays bare and untouched.

**Acceptance criteria** (the test-engineer step turns these into failing specs FIRST — red —
then implementation makes them green):

```gherkin
Scenario: manifest descriptions reach the rendered Request tail
  Given a session whose recorder holds items "aspirin-dosing" and "warfarin-interactions"
  When the Agent renders a Request
  Then the final user message carries both "id | description" lines inside its
       workspace-tagged block
```
→ spec file: `spec/lain/seams/memory_read_path_seam_spec.rb`

```gherkin
Scenario: the manifest never disturbs the cached prefix
  Given the same timeline rendered with and without a populated manifest
  When Request#prefix_digests is computed for both renders
  Then every prefix entry except the final one is digest-identical across the two
```
→ spec file: `spec/lain/seams/memory_read_path_seam_spec.rb`

```gherkin
Scenario: an empty index adds nothing to the render
  Given a session whose recorder holds no items
  When the Agent renders a Request
  Then the rendered bytes are digest-identical to a session with no memory source
```
→ spec file: `spec/lain/seams/memory_read_path_seam_spec.rb`

```gherkin
Scenario: the model can read back what it wrote, same session
  Given the model's memory_write of item "aspirin-dosing" succeeded this session
  When the model calls memory_read with id "aspirin-dosing"
  Then the tool_result carries the item's verbatim body
```
→ spec file: `spec/lain/seams/memory_read_path_seam_spec.rb`

```gherkin
Scenario: Session#reminders composes todos and manifest deterministically
  Given a session with pending todos and a non-empty memory index
  When reminders are read twice with no writes in between
  Then both reads are byte-identical and each block appears exactly once
  And the todo block precedes the manifest block
```
→ spec file: `spec/lain/session_spec.rb`

```gherkin
Scenario: the chat toolset exposes memory_read backed by the session recorder
  Given exe/lain's built toolset
  Then it contains a memory_read tool
  And reading an id written through the same toolset's memory_write succeeds
```
→ spec file: `spec/lain/cli_spec.rb`

**Escalation triggers:**
- `manifest_spec.rb` pins `Context#render` digest-stability across write orders — if wiring
  the manifest through `Session#reminders` breaks that spec or any recorded-fixture digest
  (`spec/fixtures/sessions/variance/*.ndjson` loads), stop: the reminder path is rewriting
  cached-prefix bytes, and the seam is wrong.
- If `Session::Null` needs to learn about memory to keep `Frontend`/`ToolRunner` callers
  working, stop — the Null Object growing a real dependency means the injection point is
  misplaced.
- `Invocation#context` is semantically the Session (close-out follow-up #5): if `MemoryRead`
  turns out to need the Session slot too, stop rather than smuggling a second collaborator.

### T2 — Rebuild per-turn memory roots in Session::Loader          [wave 1] [risk: medium] ✅ landed 9262b73 (panel: APPROVE-WITH-FIXES, mechanical — comment envelope + MemoryReplay extraction + message reword)

**Depends on:** none
**Files:** `lib/lain/bench/session/loader.rb` (modify), `lib/lain/bench/session.rb` (modify —
`Recording` gains the memory surface), `lib/lain/event.rb` (modify — comment only: correct
`Event::MemoryRoot`'s "recorded by the BENCH" doc to name `Memory::JournalMemoryRoot`),
`spec/lain/bench/session/loader_spec.rb` (modify)
**Reuse:** `Memory::Index.empty` / `#write` / `#checkout`; `Memory::Item`; the Loader's
existing verify-by-recommit pattern and `Session::Corrupt`; the pre-write pairing semantics
pinned by `spec/lain/seams/memory_snapshot_seam_spec.rb`; `Session.load`'s tolerant header
reads (`header["extra"] || {}`) as the precedent for absent `memory_root` records; the
`include_journal_record` matcher for journal-shape assertions.
**Shared-file wiring:** none

Event-source the index from the recording itself: successful `memory_write` tool_use inputs
in the recorded turns are the write log (skip tool_uses whose paired tool_result is an
error — refused/failed writes never reached the recorder). Replay them into a fresh
`Memory::Index`, and verify each journaled `memory_root` record equals the replayed root at
that turn — content addressing makes byte-equality the proof. `Recording` exposes the root
per turn and an index checkout at that root, so a bench consumer can recall as-of-turn-N
against the exact snapshot the render saw.

Two pinned rules the implementer must not re-litigate: **(a) writes without roots** — a
journal with **zero** `memory_root` records replays its writes unverified (the tolerant
precedent: pre-decorator recordings, like `header["extra"] || {}`); a journal with *some*
`memory_root` records that fail to cover every write-bearing turn raises `Session::Corrupt`
(a partial chain reads as tampering — `memory_root` records are not Merkle-anchored, so
silent deletion is otherwise undetectable). **(b) scope** — `Bench::Session.write` records
only the *static* `workspace.reminders` in its header, so dynamic reminders (todos today,
the manifest after T1) make a memory-bearing recording non-byte-reproducible under
`DryReplay`; that is pre-existing and accepted — do **not** thread the new memory surface
into `dry_replay.rb`.

**Acceptance criteria** (red first; spec files named here):

```gherkin
Scenario: replayed roots match the journaled memory_root chain
  Given a recorded session containing successful memory_write calls
  When the session is loaded
  Then every journaled memory_root record equals the root replayed from the turns
  And Recording#memory_root_at(turn_digest) returns that root
```
→ spec file: `spec/lain/bench/session/loader_spec.rb`

```gherkin
Scenario: recall-as-of-turn-N sees exactly the writes committed before N
  Given a loaded recording with writes at turns 2 and 4
  When an index is checked out at turn 3's recorded root
  Then the turn-2 item is readable and the turn-4 item is absent
```
→ spec file: `spec/lain/bench/session/loader_spec.rb`

```gherkin
Scenario: a refused memory_write never enters the replayed index
  Given a recorded session where one memory_write's tool_result is an error
  When the session is loaded
  Then the replayed roots still match the journaled chain
  And the refused item's id is absent from every checkout
```
→ spec file: `spec/lain/bench/session/loader_spec.rb`

```gherkin
Scenario: a tampered memory_root record fails loudly
  Given a recorded session whose memory_root record was altered on disk
  When the session is loaded
  Then loading raises Session::Corrupt naming the turn digest
```
→ spec file: `spec/lain/bench/session/loader_spec.rb`

```gherkin
Scenario: memory-free journals load unchanged
  Given a recorded session with no memory_write calls and no memory_root records
        (e.g. the variance fixtures)
  When the session is loaded
  Then loading succeeds and the memory surface reports an empty index for every turn
```
→ spec file: `spec/lain/bench/session/loader_spec.rb`

```gherkin
Scenario: a pre-decorator journal replays writes unverified
  Given a recorded session containing successful memory_write calls and zero
        memory_root records
  When the session is loaded
  Then loading succeeds and checkouts reflect the replayed writes
```
→ spec file: `spec/lain/bench/session/loader_spec.rb`

```gherkin
Scenario: a partial memory_root chain fails loudly
  Given a recorded session with writes at two turns but a memory_root record for
        only one of them
  When the session is loaded
  Then loading raises Session::Corrupt
```
→ spec file: `spec/lain/bench/session/loader_spec.rb`

**Escalation triggers:**
- `memory_snapshot_seam_spec.rb` pins the journaled root as the **pre-write** snapshot paired
  via `TurnUsage`. If replayed roots pair off-by-one against journaled roots, stop and
  re-read that seam spec — do not shift indices until the two mechanisms agree by
  construction.
- If `memory_write` tool_use inputs turn out not to round-trip the full item (id, description,
  body) from recorded turns, the event-sourcing premise fails — stop; do not invent a second
  serialization of items into the journal.
- `loader_spec.rb` pins Corrupt-on-tamper for turns; if adding root verification changes any
  existing Corrupt message or ordering assertion, stop and confirm rather than loosening.
- If rule (a)'s zero-vs-partial distinction turns out to be ambiguous on a real journal shape
  (e.g. a run whose only write was refused, so no root differs from any replayed root), stop
  and present the case rather than widening either branch.

### T3 — Root-keyed cache for Memory::Bm25 builds          [wave 1] [risk: low] ✅ landed 322b42f (panel: APPROVE)

**Depends on:** none
**Files:** `lib/lain/memory/bm25_cache.rb` (create), `spec/lain/memory/bm25_cache_spec.rb`
(create)
**Reuse:** `Memory::Bm25.new(index:)` unchanged underneath; `Memory::Index#root` as the key
(content address — equal roots ⇒ identical corpus by construction); `Memory::Recorder` as
the precedent for a deliberately mutable holder among frozen values.
**Shared-file wiring:** one-line require in `lib/lain/memory.rb` (orchestrator applies).

The tracked follow-up: `Bm25` rebuilds its engine O(corpus) per construction, which bites the
moment anything recalls over a moving index. A small mutable holder —
`Memory::Bm25Cache#for(index) → Bm25` — memoizes the built engine by `index.root`. The
intended first consumer is the bench's push-recall arm (`Context::Recall` over a moving index
in the M6 retrieval sweep — deliberately not wired in this plan); its usage pattern is
"latest root, repeatedly", so a deliberately tiny retention policy (most recent root, or a
small fixed cap) is honest; do not build an LRU framework.

**Acceptance criteria** (red first; spec files named here):

```gherkin
Scenario: the same root never rebuilds
  Given a cache and an index snapshot
  When #for is called twice with indexes sharing one root
  Then both calls return the same Bm25 object (identity, not just equality)
```
→ spec file: `spec/lain/memory/bm25_cache_spec.rb`

```gherkin
Scenario: a new root builds fresh and searches the new corpus
  Given a cached build at root A
  When the index is written to (root B) and #for is called with the new snapshot
  Then the returned Bm25 finds the newly written item
  And a hit's why is populated as usual
```
→ spec file: `spec/lain/memory/bm25_cache_spec.rb`

```gherkin
Scenario: the empty index is served without an engine
  Given a cache and Memory::Index.empty
  When #for is called
  Then searching returns [] and repeated calls do not rebuild
```
→ spec file: `spec/lain/memory/bm25_cache_spec.rb`

**Escalation triggers:**
- `bm25_spec.rb` pins `Memory::Bm25`'s Ractor-shareability and determinism; if caching
  requires making `Bm25` itself mutable or unfrozen, stop — the cache wraps, it never
  modifies the value object.
- `Index#root` is `nil` for the empty index; if that forces nil-keyed special-casing in more
  than one place, stop — that is a Null Object (an empty-index sentinel) wanting a name, not
  a second `if`.

## Integration checks

After the last card merges, the orchestrator runs on `main`:

1. `bundle exec rake compile && bundle exec rspec` — full suite green (baseline 1449; expect
   growth, zero failures).
2. `bundle exec rubocop` — clean at default metrics (no `Metrics/*` loosening).
3. `pre-commit run --all-files`.
4. Recorded-fixture regression: `spec/fixtures/sessions/variance/*.ndjson` still load
   uncorrupted and byte-reproduce (`variance_fixture_spec.rb`) — proves T1 changed no
   recorded bytes and T2 tolerates memory-free journals.
5. **Doc reconciliation commit:** `planning/remaining-work.md` — 5-3.1 and 5-3.2 marked ✅
   (classes 2026-07-13, wiring this plan); ROADMAP M5 stream status updated; close-out
   follow-up #1 (Bm25 rebuild) marked done; this plan's status → done.
6. **Manual pass (Joel):** one live `exe/lain chat` smoke run — memory_write an item, then in
   a later turn ask the model what its memory manifest lists and have it memory_read the item
   back; the reply should quote the body. (Behavioral, not a Journal eyeball — the chat path
   wires no Journal: `build_agent` passes no `journal:`, so there is no NDJSON to inspect.)
