# Chunk: causal meet ruling · findings & residuals · supervision + Workspace Timeline · cache-sibling fan-out · interface HUD/inbox/approvals

status: done
commit-mode: orchestrator-commits
language: ruby (+ rust: S2, and R4's mechanical ext half)
panel: Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman · Aaron Patterson (Ruby) — Raph Levien · Andrew Gallant · Frank McSherry · Ashley Williams (Rust, S2 only)

## Intent

Five streams, per the 2026-07-17 interview: (1) **the spine ruling** — TL-3 RULED
(enriched (a), three operators — see Decisions pinned) and landed in Ruby, then T25's
Rust re-port of the Event envelope un-parks the four digest-parity pendings; (2) **deferred findings &
residuals** — R.1–R.5 from `planning/remaining-work.md` plus the recorded residuals from
the last two chunks; (3) **supervision + the Workspace Timeline** — the `:snapshot` write
side, restore/rewind, the OM-6 supervisor reactor, and replay-restart (killed actor
resumes from checkpoint — the flagship demo); (4) **cache-sibling fan-out** — CE-4's
sibling-template spawn arm + CE-5's `stream_started` + stagger scheduling (the "1 write +
N−1 reads" demo number); (5) **interface** — the approved state-feed/tmux HUD, the human
inbox surface, queue-backed approvals with dunstify actions, and lain:// buffer
ergonomics. Satisfies ROADMAP items: TL-3/TL-5 (§ Near-term 8), the R findings and
residual follow-ups (§ Status M4-1, § M5 tail), CE-4/CE-5, OM-6, and § Interface & UX
approved experiments 1, 3, and the inbox half of "the human is an actor".

## Grounding (verified 2026-07-17, four Explore passes + direct checks, main @ 8e99e47)

> Orchestrator staleness note (execution start, main still @ 8e99e47): all wave-1 anchors
> re-verified. One path shorthand: "projection.rb" is `lib/lain/event/projection.rb`
> (line refs correct as written).

Where docs and code disagree, code won:

- **ROADMAP staleness**: `rust-findings-resolution.md` and `code-review-ollama-test-infra.md`
  are both `status: done` despite ROADMAP "Planned" markers. Only R.5 (Ollama `think`)
  genuinely remains from the Ollama band. The "always-AnthropicRaw-for-chat" residual is
  already resolved (`backend.rb:50-52`).
- **TL-3 state**: T17's `causal_meets` implementation survives UNCOMMITTED in worktree
  `.claude/worktrees/agent-af33f2c6893305933` (branch tip 6fc07b7 is on main; the work is
  working-tree only), panel-judged APPROVE-quality; it is stale by two chunks and needs a
  rebase/port, not a merge. `.handback-T17.md` there holds the panel reasoning.
- **R.1**: `Request#prefix_digests` still O(N²) (`request.rb:108-110, 161-174`);
  `Bench::Rewrites` tolerates nil chains (`rewrites.rb:55-58`) but has no format
  discriminator. **R.3**: double normalization confirmed (`journal_requests.rb:32-38` +
  `telemetry.rb:199-205`).
- **R.2**: provenance now decided in `Context::MessageEnvelope#workspace_tagged?`
  (`message_envelope.rb:45-51`, string-prefix on `Workspace::OPENING_TAG`); second site
  `context/reminder.rb:21`; the pattern to mirror is the `"cache"` strip
  (`anthropic_encoding.rb:135-140`, `request.rb:183-189`, ollama drops it too).
- **R.4**: Ruby `Turn` no longer exists (Event collapse) — the sweep is `Request`
  (`request.rb:53-56`), `Toolset` (`toolset.rb:103-106`), `Provider` (`provider.rb:70-73`),
  `Memory::Bm25` (`bm25.rb:63-66`), `Workspace` (`workspace.rb:77-80`) + Rust `Ext::Turn`
  (`lib.rs:742-749, 1367-1368`) and `Ext::Timeline` (`lib.rs:1135, 1401-1402`).
  Interpolation audit CLEAN — no site interpolates these objects into journaled/digested
  strings; the split is byte-safe.
- **R.5**: decode side ready (`ollama.rb:118`, `stream_assembler.rb:93,109`); encoder
  `SAMPLER_KEYS` (`encoding.rb:29`) omits `think`; `CAPABILITIES = %i[streaming]`
  (`ollama.rb:43`). `Request#extra` transport channel exists (`request.rb:20,34`).
- **Workspace Timeline**: `Event::KINDS` includes `:snapshot` and
  `Projection#workspace_at` reads them (`projection.rb:68-73`) — but NOTHING writes a
  `:snapshot` event. Workspace is sent-not-stored reminders only (`workspace.rb:6-17`).
  Session tracks the read-set (read-before-write contract) — the natural write-set seam.
- **OM-6**: actor mode exists but `perform` refuses model dispatch
  (`subagent.rb:151, 276-279`, names "the OM-6 supervisor reactor");
  `launch_actor` (`subagent.rb:127-129`) is programmatic-only; `Conductor`
  (`cli/conductor.rb:193`: "no actor registry to hand it yet") is per-ask supervision
  glue. The render-side per-turn snapshot seam residual (mailbox binding at pipeline
  construction) is recorded in `chunk-fixes-xdg-resume-signals.md` T6 note.
- **CE-4/CE-5**: `PrefixStrategy::REGISTRY` has `fresh`/`inherit` only
  (`spawn_policy.rb:88`); `spec/lain/tool/spawn_policy_spec.rb:26-27` PINS the ABSENCE of
  `:sibling_template` (deliberate deferral — safe to flip). `AttenuationPosture
  :handler_union` (the cache-sharing posture) exists (`spawn_policy.rb:135-144`).
  `stream_started` appears nowhere in lib/exe/spec.
- **Interface**: all five approved experiments have zero code. `Handler::Gate` takes any
  `#call(effect, context) → Boolean` policy (`gate.rb:55-58`) — approval is synchronous
  TTY y/N via `Frontend::ApprovalPolicy`; no queue. `CLI::JournalTee` is a hardcoded 1→2
  tee (`journal_tee.rb:18-26`) — the fan-out generalization point. `ask_human` questions
  surface inline via `TTY#render_question` (`tty.rb:132-138`), Channel-bypassing;
  the runtime transport is one `Async::Queue` (`exe/lain:277-281, 437-443`). TTY prompt is
  single-line `Reline.readline`, no completion, no HUD; history at
  `$XDG_STATE_HOME/lain/history` (`tty.rb:245-292`). Neovim: buffers timeline/workspace/
  diff/journal/request + `:LainResend`; no inbox, no fork, no scrub, no quickfix
  (all confirmed absent). Sessions discovery primitives exist (`cli/sessions.rb`,
  `resume/selector.rb`) — no index file, directory listing.
- **Desktop facts** (2026-07-11 machine checks, interface-integration.md): `dunstify`
  present WITH the `actions` capability; tmux next-3.7 has `pane-focus-in`,
  `monitor-bell`, `client_activity`; `mmdc`/ImageMagick-7 NOT installed (mermaid inline
  stays out of scope).
- **Suite baseline**: 2073 examples, 0 failures, 4 pending (the T25 parity four:
  `rust/turn_spec.rb:73-82, 88-95`, `rust/store_spec.rb:61-73`,
  `rust/timeline_spec.rb:162-178`). `cargo test` 79.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lain.gemspec`,
  `Gemfile`, `Gemfile.lock`, `.rubocop.yml`, `CLAUDE.md`, `spec/spec_helper.rb`,
  `.pre-commit-config.yaml`, `exe/lain` (several cards hand back small exe diffs).
- S2 is reviewed by the Rust panel roster; everything else by the Ruby panel (R4's ext
  half is mechanical and stays with the Ruby review, flagged for a Rust-literate glance).
- The T17 worktree (`agent-af33f2c6893305933`) is INPUT to S1 — the implementing agent
  reads it (and `.handback-T17.md`) but rebases the idea onto current main; never
  fast-forward that branch.
- **Unit-index require lines are orchestrator-owned wiring** exactly like `lib/lain.rb`:
  a card creating a file under an existing unit (`workspace/`, `tools/subagent/`,
  `supervisor/`) hands the index's one-line `require_relative` back as a wiring diff;
  it never edits the index itself. This is what keeps W2/C3/W4 from colliding with
  same-wave substantive edits to `workspace.rb`/`subagent.rb`.
- File-serialization waves (not dependencies): `request.rb` (R1→R2→R4),
  `telemetry.rb` (R1→C1), `workspace.rb` (R2→R4), `subagent.rb` (C2→W3),
  `tty.rb` (I3→I6), `runtime.lua`/`buffers.rb` (I6→I7), `ext/lain/src/lib.rs` (R4→S2),
  `timeline.rb`/`timeline_spec.rb` (S1→S3), `meet_semilattice.rb` (S3 before S2's
  acceptance re-runs).
- Demo framing: W4 (replay-restart) and C3 (staggered fan-out) each end with a
  reproducible driver script/fixture the demo can run live — named in their ACs, not
  improvised later.

## Decisions pinned in this plan (2026-07-17 interview + deep-research pass)

- **TL-3 ruling — enriched (a), RULED by Joel 2026-07-17** after a 103-agent verified
  research pass (findings + sources: `planning/dominator-meet-research-2026-07.md`).
  Three operators, each honest about its question:
  1. `meet`/`diverge_at` stay render-edge and **byte-unchanged** (cache-break
     localization; retroactive drift under causal-edge insertion is disqualifying — a
     single edge insertion can change Θ(n) immediate dominators).
  2. `causal_meets` is **set-valued** — the maximal lower bounds of the causal ancestry
     order (git merge-base precedent: the set can be plural under criss-cross shapes;
     patch theory's "enlarge the codomain rather than force uniqueness"). This REWORKS
     the T17 worktree's one-render-meet-per-causal-parent shape.
  3. A NEW `dominator_meet` over the **union graph** (render ∪ causal edges, virtual
     root over the forest): deepest common dominator — a true meet-semilattice
     (dominance partial order ⇒ dominator sets totally ordered ⇒ tree ⇒ unique NCA),
     property-tested under the SAME `MeetSemilattice` law group. It is the
     synchronization/checkpoint/safe-compaction primitive ("the latest event every path
     from root must pass through"). Computed on demand, memoized by head digest
     (content-addressed input ⇒ memoizable output); the quiet-branch caveat (an open
     subagent branch freezes the frontier at its spawn point until closed) is
     documented behavior, mitigated by actors' explicit `stop`.
- The Rust re-port (S2) is scoped to the **envelope + digest parity + the unchanged
  render meet**; `causal_meets` and `dominator_meet` stay Ruby-first — they are
  projections, not digest-bearing structures, and the five-rule binding test defers
  their port until a bench shows them hot.

## Open decisions

None gating — every card below is runnable as specified.

## Waves

```
Wave 1: S1, R1, R5, RES1, RES2, RES3, RES4, W1, I1, I4
Wave 2: S3(←S1), R2, C1, C2, W2(←W1), I2(←I1), I3(←I1), I5(←I4)
Wave 3: R4, W3(←W1), C3(←C1,C2), I6(←I5)
Wave 4: S2(←S1), W4(←W2,W3), I7(←I6)
```

File-serialization notes (no semantic dependency): C1 sits in wave 2 for `telemetry.rb`
after R1; S3 in wave 2 for `timeline.rb`/`timeline_spec.rb` after S1, and BEFORE S2
because S3 extends `meet_semilattice.rb`, which S2's acceptance specs include; S2 in
wave 4 for `ext/lain/src/lib.rs` after R4. **Unit-index require lines are orchestrator
wiring** (see the contract above), so W2/C3/W4 adding files under `workspace/`,
`tools/subagent/`, and `supervisor/` do not collide with same-wave substantive edits to
those indexes. Substantive-edit chains the orchestrator serializes: `request.rb`
(R1→R2→R4), `telemetry.rb` (R1→C1), `workspace.rb` (R2→R4), `subagent.rb` (C2→W3),
`tty.rb` (I3→I6), `lib.rs` (R4→S2).
Critical path: **I4 → I5 → I6 → I7** (the longest dependency chain); **W1 → W3 → W4**
runs beside it; **S1 → {S3, S2}** is the spine tail.

## Tasks

### S1 — Land the TL-3 ruling: set-valued causal_meets   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/timeline.rb`, `spec/lain/timeline_spec.rb`
**Reuse:** the T17 worktree implementation + `.handback-T17.md`
(`.claude/worktrees/agent-af33f2c6893305933`) as reference for the walk mechanics —
but the RESULT SHAPE changes per the ruling; `Event#causal_parents` (`event.rb:37-38`);
the existing meet (`timeline.rb:128-134`); git merge-base's maximal-lower-bounds
definition as the semantic reference
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: render meet is byte-unchanged
  Given single-parent render chains
  Then meet and diverge_at return exactly what they return today (laws re-run green)

Scenario: causal_meets is the set of maximal lower bounds
  Given two timelines whose causal ancestries share common ancestors
  When causal_meets runs
  Then it returns exactly the common causal ancestors that are not ancestors of
  another common ancestor (git's merge-base definition), as a deterministically
  ordered set (digest order)

Scenario: criss-cross is plural, honestly
  Given a criss-cross causal shape (two incomparable maximal common ancestors)
  Then causal_meets returns both — never an arbitrary singleton

Scenario: the projection never mutates
  When causal_meets runs
  Then no Store put and no Timeline commit occurs
```
→ spec file: `spec/lain/timeline_spec.rb`

**Escalation triggers:**
- The worktree code predates the Event collapse's final shape on main — if
  `causal_parents` semantics drifted (sorted/deduped set, `event.rb:170-172`), port to
  main's semantics, don't restore the worktree's.
- If any semilattice law group fails after the port, STOP — the ruling's premise
  (render meet untouched) is violated.
- causal_meets is set-valued and therefore NOT under the MeetSemilattice law group — if
  a spec is tempted to force those laws onto it, stop: the ruling deliberately does not
  claim them (that is S3's job, for a different operator).

### S2 — Re-port the Event envelope to Rust; un-park digest parity (T25)   [wave 4] [risk: high]

**Depends on:** S1
**Files:** `ext/lain/src/lib.rs` (and new modules under `ext/lain/src/` as the crate's
structure dictates), `spec/lain/rust/turn_spec.rb`, `spec/lain/rust/store_spec.rb`,
`spec/lain/rust/timeline_spec.rb`
**Reuse:** the Ruby `Event` envelope as the byte-reference (`event.rb:89-105`,
`event/payload.rb`); the pinned refusal-message tests (`lib.rs:1524-1535`); `blake3` +
`indexmap` already in the crate
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: digest parity returns
  Given the same role/content/parents built via both implementations
  Then Ruby and Rust digests match byte-for-byte and all four pending specs un-park

Scenario: the envelope is complete
  Given kind, render_parent, causal_parents, correlation, payload_digest
  Then the Rust payload hash equals Ruby's Canonical bytes for every KINDS member

Scenario: shareability holds
  Then Ractor.shareable? stays true for the magnus TypedData objects

Scenario: the render meet ports unchanged
  Then the Rust timeline's meet/diverge_at match Ruby's byte-for-byte under the shared
  law groups (causal_meets and dominator_meet stay Ruby-only per the pinned decision)
```
→ spec files: the three `spec/lain/rust/*_spec.rb` (pendings removed, not rewritten)

**Escalation triggers:**
- The four pending specs are the acceptance test — if any needs its EXPECTATION changed
  (not just the pending removed), stop: that is a digest-scheme disagreement, not a port
  bug.
- `rust/turn_spec.rb` pins `parent: "blake3:abc"` fixtures (lines 64, 78-80, 93) — if the
  port adds constructor shape-validation (R.8 territory), stop; that finding was
  deliberately deferred.
- When parity fails, the stop report names the FIRST diverging field of the Canonical
  byte streams (not just "digests differ") — escalations must arrive debuggable.

### S3 — dominator_meet: the checkpoint primitive   [wave 2] [risk: medium]

**Depends on:** S1
**Files:** `lib/lain/timeline.rb` (or `lib/lain/timeline/dominators.rb` if the
collaborator earns its file — implementer's call; the index require line is
orchestrator wiring), `spec/lain/timeline_spec.rb`,
`spec/support/shared_examples/meet_semilattice.rb` (generator extended to union graphs)
**Reuse:** Cooper/Harvey/Kennedy's `intersect`-on-the-tree as the NCA meet (the
algorithm named in `planning/dominator-meet-research-2026-07.md`); the `MeetSemilattice`
shared law group — verbatim LAWS, with the dominance order injected through the group's
predicate knob (its default ancestry predicate is strictly weaker than dominance);
`Enumerator::Lazy` walk idiom
**Shared-file wiring:** none

The union graph is **argument-anchored**: the ancestry closure of the two heads passed
in, under render ∪ causal edges, with a virtual root over that closure's roots. This is
what makes memoization sound — events are immutable and `causal_parents` are fixed at
creation, so a digest pair's closure never changes.

**Acceptance criteria:**

```gherkin
Scenario: the dominator meet is lawful
  Given randomly generated union graphs (render + causal edges, virtual root)
  Then dominator_meet passes the MeetSemilattice laws with the dominance order injected
  (idempotent, commutative, associative)

Scenario: it matches brute force
  Given small random union graphs
  Then per-node dominator sets computed by exhaustive path enumeration agree with the
  implementation, and dominator_meet is the deepest member of the intersection

Scenario: it names the checkpoint
  Given a fan-out that fully joins back (all children's results consumed by one turn)
  Then dominator_meet of the post-join head with any pre-join head is the join point —
  the latest event every path from the virtual root must pass through

Scenario: a quiet branch freezes the frontier, documented
  Given a parent head and an open subagent branch's head (spawned, never closed)
  When dominator_meet(parent_head, child_head) runs
  Then it answers at or before the spawn point, and the method's WHY documents this as
  inherent (the CRDT causal-stability caveat), not a bug

Scenario: pure and memoizable
  Given the same head-digest pair twice
  Then the second call does no graph walk (memo keyed by the digest pair) and no call
  ever mutates the Store or Timeline
```
→ spec file: `spec/lain/timeline_spec.rb` (+ the extended shared group)

**Escalation triggers:**
- If extending the law-group generator to union graphs breaks it for the EXISTING
  render-meet consumers (S1's re-run, the Rust parity of S2), stop — the generator must
  gain a shape, not change the old one.
- Timeline instances are frozen at construction (`timeline.rb:34-36`) — the memo cannot
  be instance state. It lives on the projection/query object (keyed [head_a, head_b]),
  and must be safe under concurrent actor fibers; if that home turns out not to exist
  cleanly, stop rather than mutate a frozen value or add a global.
- The virtual root is a modeling artifact — if any digest-bearing surface (payload,
  journal) is tempted to record it, stop; it must never leave the projection.

### R1 — Rolling-hash the prefix-digest chain (R.1 + R.3)   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/request.rb`, `lib/lain/bench/rewrites.rb`,
`lib/lain/middleware/journal_requests.rb`, `lib/lain/telemetry.rb`,
`spec/lain/request_spec.rb`, `spec/lain/bench/rewrites_spec.rb`
**Reuse:** `Canonical.digest`; `Rewrites`' nil-tolerance idiom (`rewrites.rb:55-58`);
the recorded variance fixtures under `spec/fixtures/` as old-format corpus.
(R.3 folds in here deliberately — `remaining-work.md` R.3 says "fold into R.1's
touching of that seam"; not an "and"-shaped second responsibility.)
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: journaling cost is linear, observably
  Given a request with N messages and N markers
  When prefix_digests computes under a Canonical.digest/normalize spy
  Then the digest primitive is invoked once per (message, marker-entry) — never once
  per (marker × full prefix) — and each chain entry is H(prev_entry, canonical(message))

Scenario: the chain carries its version
  When a request journals
  Then the record names the chain format version, and Rewrites reads BOTH formats
  (old recorded journals still localize divergence; nil still means "not computed")

Scenario: one normalization pass
  When JournalRequests journals a request
  Then Canonical.normalize runs once per payload, not twice

Scenario: divergence localization unchanged
  Given two sessions diverging at turn k
  Then Rewrites names the same divergence point under old and new formats
```
→ spec files: `spec/lain/request_spec.rb`, `spec/lain/bench/rewrites_spec.rb`

**Escalation triggers:**
- Recorded fixture journals under `spec/fixtures/` carry old-format chains — if any spec
  REGENERATES them rather than dual-reading, stop; old journals must stay loadable.
- If the rolling hash cannot reproduce the current per-marker digest semantics that
  `Bench::Rewrites` divergence-depth reporting relies on, stop and bring the design back.

### R2 — Structural workspace provenance (R.2)   [wave 2] [risk: medium]

**Depends on:** none (wave-2 for request.rb serialization after R1)
**Files:** `lib/lain/workspace.rb`, `lib/lain/context/message_envelope.rb`,
`lib/lain/context/reminder.rb`, `lib/lain/provider/anthropic_encoding.rb`,
`lib/lain/provider/ollama/encoding.rb`, `lib/lain/request.rb`,
`spec/lain/context/message_envelope_spec.rb`, `spec/lain/workspace_spec.rb`
**Reuse:** the `"cache"` marker strip as the exact pattern (`anthropic_encoding.rb:135-140`,
`request.rb:183-189`); `MessageEnvelope`'s WHY comment (`message_envelope.rb:45-51`)
names this card
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: literal tag text is no longer swallowed
  Given a user message that literally starts with "<workspace>"
  When Recall builds its query
  Then that text feeds the query (provenance is the structural key, not the prefix)

Scenario: the wire never sees the key
  When a request encodes for Anthropic or Ollama
  Then no block carries a "workspace" key on the wire

Scenario: prefix digests strip it like cache
  When prefix_digests computes over workspace-tagged blocks
  Then digests are identical before and after the marker strip
```
→ spec files: `spec/lain/context/message_envelope_spec.rb`, `spec/lain/workspace_spec.rb`

**Escalation triggers:**
- Workspace blocks render into REQUESTS, not the Timeline — but if any recorded fixture's
  request digest shifts (the workspace key must be stripped before digesting, mirroring
  "cache"), stop: that is the byte-stability line this card must not cross.
- `reminder.rb:21` is a second prefix-match site — if it turns out to guard different
  semantics than provenance, stop rather than unify blindly.

### R4 — Split to_s/inspect across the five value objects + Ext (R.4)   [wave 3] [risk: low]

**Depends on:** none (wave-3 for request.rb and lib.rs serialization)
**Files:** `lib/lain/request.rb`, `lib/lain/toolset.rb`, `lib/lain/provider.rb`,
`lib/lain/memory/bm25.rb`, `lib/lain/workspace.rb`, `ext/lain/src/lib.rs`,
`spec/lain/request_spec.rb`, `spec/lain/toolset_spec.rb`, `spec/lain/provider_spec.rb`,
`spec/lain/memory/bm25_spec.rb`, `spec/lain/rust/turn_spec.rb`,
`spec/lain/rust/timeline_spec.rb`
**Reuse:** DegradedSet's split as the convention exemplar (T5 of the ollama plan);
the clean interpolation audit (grounding above) as the byte-safety warrant
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: to_s is a human projection
  Then each of Request, Toolset, Provider, Memory::Bm25, Workspace, Ext::Turn,
  Ext::Timeline returns a human-readable to_s and a #<...> class-tagged inspect,
  with no alias between them

Scenario: bytes are untouched
  Given a recorded journal and cassette
  Then journaled and digested bytes are identical before and after the split
```
→ spec files: the six listed above (one example per object)

**Escalation triggers:**
- If ANY interpolation site of these objects into a journaled/error string surfaces that
  the audit missed, stop — the byte-safety warrant is void and the spine two (Request,
  Ext) must be re-audited before proceeding.

### R5 — Ollama think mode + :thinking capability (R.5)   [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/provider/ollama.rb`, `lib/lain/provider/ollama/encoding.rb`,
`spec/lain/provider/ollama_spec.rb`, `spec/lain/provider/ollama_streaming_spec.rb`
**Reuse:** `Request#extra` transport channel (`request.rb:20`); the decode path already
built (`ollama.rb:118`, `stream_assembler.rb:93,109`); `spec/support/ollama_wire.rb`
fixtures
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: think round-trips
  Given extra carries think: true
  When a chat round-trip runs (wire-fixture)
  Then the request body carries think and the Response contains a thinking block
  shaped exactly as the Anthropic path produces

Scenario: capability is honest
  Then CAPABILITIES includes :thinking and the 3c-4 gate sees it

Scenario: non-think runs unchanged
  Given no think extra
  Then request bytes are identical to today's
```
→ spec files: `spec/lain/provider/ollama_spec.rb`, `ollama_streaming_spec.rb`

**Escalation triggers:**
- qwen3 emits thinking only under `think: true`; if the wire fixture shows fragments
  arriving WITHOUT it (model-version drift), stop and re-pin the fixture, don't widen the
  capability claim.

### RES1 — Coerce streamed 4xx to the sync path's error classes   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/provider/http/streaming.rb`,
`lib/lain/provider/http/streaming/faraday_handlers.rb`,
`lib/lain/provider/anthropic_raw/transport.rb`, `spec/lain/provider/anthropic_raw_spec.rb`
**Reuse:** the sync error mapping in `lib/lain/provider/http/error_middleware.rb`;
`RetryTap`'s journaled-retry contract (`retry_tap.rb:43-50`); `spec/support/anthropic_sse.rb`
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: a streamed 4xx is not retried
  Given a streaming request answered 400 with an error body
  Then the same Lain error class raises as the sync path, faraday-retry does not fire,
  and zero ProviderRetry events journal

Scenario: a streamed 429/5xx still retries
  Given a streaming request answered 429
  Then exactly the sync path's retry classification applies and the retry journals
```
→ spec file: `spec/lain/provider/anthropic_raw_spec.rb`

**Escalation triggers:**
- If Faraday's on_data path cannot observe the status before body streaming begins
  (version-dependent — `faraday_handlers.rb` exists precisely for v1/v2 drift), stop and
  record which version breaks; the fix may be version-gated.
- The retry spec pins "exactly one ProviderRetry" — if this card changes that count for
  the SYNC path, stop.

### RES2 — Provider in the session header + loud resume mismatch   [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/bench/session.rb`, `lib/lain/cli/resume.rb`,
`spec/lain/bench/session_spec.rb`, `spec/lain/cli/resume_spec.rb`
**Reuse:** the header's `context_class`-as-data idiom (`bench/session.rb:13-16`);
`Resume`'s notices channel (`resume.rb:24-32`); `CLI::Backend#provider` naming
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: the header names its provider
  When a session journals
  Then the header records the provider name and model as data

Scenario: resume disagreement is loud
  Given a session recorded under anthropic and a resume under --provider ollama
  Then both are printed as a notice and the current flags win (T19's LOUD policy)

Scenario: old headers still load
  Given a header with no provider field
  Then resume proceeds with a "provider unrecorded" notice, not a refusal
```
→ spec files: `spec/lain/bench/session_spec.rb`, `spec/lain/cli/resume_spec.rb`

**Escalation triggers:**
- The header is digest-anchored by `head` — if adding a field breaks any Loader
  verification of EXISTING fixtures, stop; the field must be additive-optional.

### RES3 — Embedder names its model in Vector#why   [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/memory/vector.rb`, `lib/lain/embedder.rb`, `lib/lain/embedder/`
(the Ollama/Static embedders under it), `spec/lain/memory/vector_spec.rb`
**Reuse:** the `Hit#why` non-blank law (`memory_index_laws.rb`); the T10 follow-up note
(chunk-spine T10 line) is this card's charter
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: why names the model
  Given a Vector over Embedder::Ollama pinned to nomic-embed-text
  Then Hit#why names the embedding model id, not just the embedder class

Scenario: the static embedder is honest
  Given Embedder::Static
  Then #why names it as deterministic-fixture, and the sweep report is byte-identical
  to the committed baseline
```
→ spec file: `spec/lain/memory/vector_spec.rb`

**Escalation triggers:**
- `lain bench sweep` output is committed-byte-stable — if naming the model changes the
  sweep report bytes, stop: either the report format versions or the change is
  display-only, and that choice is the orchestrator's.

### RES4 — Spawn through the Role catalog (role→spawn glue)   [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/backend.rb` (or a small `lib/lain/cli/` collaborator if Backend
is the wrong home — implementer's call inside `lib/lain/cli/`),
`spec/lain/cli/backend_spec.rb`
**Reuse:** `Role.fetch`/`Role#spawn_policy` (`role.rb:42-44`); `Role::Catalog::BUILT_INS`
(`catalog.rb:21-29`); today's inline policy (`exe/lain:293-297`) is the thing replaced
**Shared-file wiring:** exe diff — the research subagent is constructed from
`Role.fetch(:researcher)` instead of an inline SpawnPolicy (orchestrator applies)

**Acceptance criteria:**

```gherkin
Scenario: the exe spawns a cataloged role
  When chat wires its research subagent
  Then its SpawnPolicy comes from Role.fetch(:researcher) and equals today's inline
  policy field-for-field (fresh, schema, read_file+list_files)

Scenario: the cache mark is spent knowingly
  Given a role prelude rendered through Context
  Then exactly one system-slot cache mark exists (the T24 5-mark-400 risk is specced,
  not tripped)
```
→ spec file: `spec/lain/cli/backend_spec.rb`

**Escalation triggers:**
- `Context#cache_marked` always marks the LAST system block and `CacheBreakpoints`
  budgets ONE system slot (the T24 follow-up) — if wiring a role prelude produces a
  second system mark, stop; that is the recorded Anthropic-400 risk, and spending it is
  the orchestrator's call.

### W1 — Write the workspace snapshots (:snapshot events)   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/workspace/snapshot.rb` (new), `lib/lain/session.rb` (the write-set
is NEW state this card adds — today Session tracks READS only, `session.rb:39, 62-68`),
`lib/lain/agent.rb` (the commit seam: `Agent#commit_and_account`, `agent.rb:204-215` —
`ToolRunner` never commits and holds no Timeline; it only collects which tools mutated),
`spec/lain/workspace/snapshot_spec.rb`, `spec/lain/session_spec.rb`
**Reuse:** `Event.snapshot` kind + `ChainWriter` (payload-then-envelope,
`event/chain_writer.rb`); `Projection#workspace_at` (`projection.rb:68-73`) as the
already-built read side; `Session`'s read-set (`session.rb:39-68`) as the PATTERN for
the new write-set
**Shared-file wiring:** require line for `workspace/snapshot.rb` in the `workspace.rb`
index (orchestrator applies)

**Acceptance criteria:**

```gherkin
Scenario: a mutating tool snapshots
  Given a turn whose edit_file writes two files
  When the turn commits
  Then one :snapshot event lands, causally parented to the turn, whose payload
  content-addresses each written file's bytes into the Store

Scenario: unchanged files share storage
  Given two consecutive snapshots where one file changed
  Then the unchanged file's blob digest appears in both payloads and the Store holds
  one copy

Scenario: read-only turns snapshot nothing
  Given a turn of read_file/list_files only
  Then no :snapshot event is written

Scenario: bash is an honest gap
  Given a turn whose bash mutates a file outside the session write-set
  Then the snapshot policy's documented behavior holds (write-set only, gap journaled
  as a snapshot_scope note), never a silent wrong snapshot
```
→ spec file: `spec/lain/workspace/snapshot_spec.rb`

**Escalation triggers:**
- Snapshot events enter the render-parentless causal chain exactly as ask_human's do —
  if any committed fixture or parity spec breaks because default-path digests shift,
  stop: snapshots must be additive to the DAG, invisible to render chains.
- If snapshotting inside the turn-commit atom (the `defer_stop` uninterruptible region)
  measurably stretches the ≤150ms heartbeat bound, stop and bring the measurement.

### W2 — Restore and rewind the workspace   [wave 2] [risk: medium]

**Depends on:** W1
**Files:** `lib/lain/workspace/restore.rb` (new), `spec/lain/workspace/restore_spec.rb`
**Reuse:** `Projection#workspace_at`; `Timeline#rewind` (conversation side); W1's blob
scheme
**Shared-file wiring:** require line for `workspace/restore.rb` in the `workspace.rb`
index (orchestrator applies)

**Acceptance criteria:**

```gherkin
Scenario: restore files, keep conversation
  Given snapshots at turns 2 and 5
  When restore(turn: 2) runs
  Then the write-set files match the turn-2 blobs byte-for-byte and the Timeline head
  is unchanged

Scenario: restore both axes
  When restore(turn: 2) combines with Timeline rewind to the same turn
  Then files and conversation agree with the turn-2 state

Scenario: restore refuses dirty surprises
  Given a target file modified outside lain since the snapshot
  Then restore refuses namedly (no silent clobber) unless forced
```
→ spec file: `spec/lain/workspace/restore_spec.rb`

**Escalation triggers:**
- Restore WRITES files — output-discipline does not cover file IO, but the Effect
  boundary might: if restore belongs behind an Effect/Handler (approvable, journaled)
  rather than a bare class, stop and confirm the seam before building it bare.

### W3 — The supervisor reactor: actors become reachable (OM-6 core)   [wave 3] [risk: high]

**Depends on:** W1
**Files:** `lib/lain/supervisor.rb` (new), `lib/lain/tools/subagent.rb` (unrefuse
model-dispatched :actor when a supervisor is present), `lib/lain/cli/conductor.rb`,
`spec/lain/supervisor_spec.rb`, `spec/lain/tools/subagent_spec.rb`
**Reuse:** `Subagent::Actor` (`actor.rb` — launch/settle/tell/stop already built);
`Conductor` as the per-ask precedent (`conductor.rb:193` names this card); the
frozen-log-snapshot-per-turn ruling (chunk-fixes T6) for the render seam.
(The unrefusal is one guard flip riding the Supervisor's existence — bundled here
deliberately, not an "and"-shaped second responsibility.)
**Shared-file wiring:** exe diff — chat constructs the Supervisor and hands it to the
toolset wiring (orchestrator applies)

**Acceptance criteria:**

```gherkin
Scenario: a model-dispatched actor spawns
  Given a toolset whose subagent allows mode: :actor and a running Supervisor
  When the model calls subagent(mode: :actor)
  Then an Actor launches under the Supervisor's reactor task, its spawn event lands,
  and the tool_result returns its handle (no refusal)

Scenario: actor registry is queryable
  Given two live actors
  Then the Supervisor enumerates them with role, state, and head digest

Scenario: the render seam receives per-turn snapshots
  Given an Agent whose pipeline includes Mailbox
  When two turns render
  Then each render folds THAT turn's frozen log snapshot (the recorded OM-6 residual:
  no stale pipeline-construction binding)

Scenario: no supervisor still refuses loudly
  Given no Supervisor wired
  Then subagent(mode: :actor) refuses with today's message

Scenario: actor lifecycle is journaled in the shape the state feed reads
  Given an actor launching, settling, and stopping
  Then each transition journals an attributed event whose shape I1's fleet field
  consumes (spawn/settle/stop visible on the HUD without I1 changes)
```
→ spec files: `spec/lain/supervisor_spec.rb`, `spec/lain/tools/subagent_spec.rb`

**Escalation triggers:**
- The Actor doc pins "persistence across separate asks needs an orchestration reactor
  ABOVE the Agent" (`actor.rb:20-28`) — if the Supervisor cannot own the reactor without
  re-entering Agent#ask's per-call Sync (the wedge the doc warns about), stop.
- Parent→child causal linkage is correlation-grain today (the recorded edge-grain
  question) — if this card needs a true causal edge from a specific tool_result to the
  spawn, stop and surface the design question rather than inventing the edge shape.

### W4 — Replay-restart: a killed actor resumes from checkpoint   [wave 4] [risk: high]

**Depends on:** W2, W3
**Files:** `lib/lain/supervisor/restart.rb` (new), `spec/lain/supervisor/restart_spec.rb`,
`bin/demo-supervision` (new, small driver script for the manual demo — not gem-shipped)
**Reuse:** `Bench::Session::Loader`'s verified replay (re-commit + digest check);
`Resume`'s salvage/notice idiom; W2 restore; W3 registry
**Shared-file wiring:** require line for `supervisor/restart.rb` in the `supervisor.rb`
index (orchestrator applies)

**Acceptance criteria:**

```gherkin
Scenario: crash and resume
  Given an actor three turns in with snapshots
  When its fiber is killed and the Supervisor restarts it
  Then the restarted actor's Timeline head equals the last committed turn, its
  workspace matches the last snapshot, and a restart event journals with both digests

Scenario: restart is replay, not re-spend
  When the restart replays
  Then zero provider calls occur during replay (the same no-respend property as resume)

Scenario: the demo driver runs it end-to-end
  When bin/demo-supervision runs against a mock provider
  Then it prints the kill, the restart, and the matching head digests, exit 0
```
→ spec file: `spec/lain/supervisor/restart_spec.rb`

**Escalation triggers:**
- Supervision-as-replay must be THE SAME code path as M2 session resume (the spec's
  stated acceptance) — if the Loader seam forces a second replay implementation, stop;
  duplicating replay is the exact failure the event-sourcing spine exists to prevent.

### C1 — stream_started on the Channel (CE-5 signal)   [wave 2] [risk: low]

**Depends on:** none (telemetry.rb serialized after R1 by the orchestrator)
**Files:** `lib/lain/telemetry.rb` (new event class), `lib/lain/provider/anthropic.rb`,
`lib/lain/provider/anthropic_raw.rb` (emission at first streamed token),
`spec/lain/provider/anthropic_raw_spec.rb`, `spec/lain/telemetry_spec.rb`
**Reuse:** `Telemetry` event idiom + `Journalable#to_journal`; the SSE first-event seam
in `StreamAssembler`; `spec/support/anthropic_sse.rb`
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: first token emits the signal
  Given a streaming response
  Then exactly one stream_started event lands on the Channel, attributed, carrying the
  request digest, before any content block event

Scenario: an orchestration policy can observe it without the Channel
  Given a per-request first-token observer injected at dispatch
  When the first token arrives
  Then the observer's promise resolves with the request digest — the Channel is
  untouched by this path (it has ONE destructive consumer, the frontend; C3 rides
  this observer, never a second Channel drain)

Scenario: it is transient, not history
  Then stream_started is a Channel/Telemetry event only — no Store event, no new kind
  (the closed KINDS set is untouched)

Scenario: non-streaming emits nothing
  Given stream: false
  Then no stream_started event occurs
```
→ spec files: `spec/lain/telemetry_spec.rb`, `spec/lain/provider/anthropic_raw_spec.rb`

**Escalation triggers:**
- The SDK oracle path (`Provider::Anthropic`) uses `accumulated_message` on a single-pass
  stream — if emitting at first token forces a second pass or breaks the accumulator
  contract (the known trap), stop.

### C2 — The sibling-template prefix strategy (CE-4 arm)   [wave 2] [risk: high]

**Depends on:** none (subagent.rb serialized before W3)
**Files:** `lib/lain/tool/spawn_policy.rb`, `lib/lain/tools/subagent.rb` (template
threading at spawn), `spec/lain/tool/spawn_policy_spec.rb`,
`spec/lain/tools/subagent_spec.rb`
**Reuse:** `Role#prelude_segments` cache ordering (`role.rb:54-63` — role-invariant bulk
first, breakpoint, role-specific after: the T24 layout); `AttenuationPosture::HandlerUnion`
(`spawn_policy.rb:135-144`) — the posture that preserves position-0 sharing;
`Timeline#fork` O(1)
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: siblings share a byte-identical template prefix
  Given three children spawned sibling_template with different tasks
  Then all three requests' prefixes through the template breakpoint are byte-identical
  (prefix_digests share the chain head) and per-child content lands after it

Scenario: the registry gains the arm
  Then PrefixStrategy.fetch(:sibling_template) resolves (the REGISTRY constant is
  private — assert through the public seam), and the three strategies render through
  the same Context seam

Scenario: attenuation keeps sharing when asked
  Given posture :handler_union
  Then all siblings carry the union tool schema (identical bytes) and per-child refusal
  happens at the Handler

Scenario: the floor is respected
  Given a template below the minimum cacheable prefix
  Then the strategy reports it (journaled note), never silently un-cacheable
```
→ spec files: `spec/lain/tool/spawn_policy_spec.rb`, `spec/lain/tools/subagent_spec.rb`

**Escalation triggers:**
- `spawn_policy_spec.rb:26-27` PINS the absence of :sibling_template — flip that example
  as part of this card; if any OTHER spec pins absence, stop and list them.
- If sibling sharing proves impossible without per-child schema bytes ANYWHERE in the
  prefix (the attenuation ↔ position-0 question), stop — the specs' open question says
  the human decides that trade, not the card.

### C3 — Stagger scheduling + the fan-out measurement (CE-5 policy)   [wave 3] [risk: medium]

**Depends on:** C1, C2
**Files:** `lib/lain/tools/subagent/stagger.rb` (new policy), `spec/lain/tools/subagent/
stagger_spec.rb`, `spec/fixtures/` fan-out fixture as the spec builds it
**Reuse:** `Promise` (`promise.rb`) resolved by C1's per-request first-token observer
(NOT the Channel — see C1; `Lain::Channel` is destructively consumed by the frontend,
so a second Channel consumer would steal events); C2's template chain;
`Request#prefix_digests` (post-R1) for the shared-chain assertion
**Shared-file wiring:** require line for `subagent/stagger.rb` in the `subagent.rb`
index (`subagent.rb:295-298`; orchestrator applies)

**Acceptance criteria:**

```gherkin
Scenario: release one, await, release the rest
  Given a fan-out of 4 sibling_template children under the stagger policy
  Then child 1 dispatches alone, children 2-4 dispatch only after child 1's
  stream_started, and dispatch order journals

Scenario: the measurement shows the point
  Given the staggered fixture and an unstaggered control (mock provider, recorded)
  Then the staggered run's requests share one template chain head (1 writable prefix,
  N-1 byte-identical reuses) while the control shows N independent first-dispatches —
  reported as the demo table

Scenario: no stream_started degrades safely
  Given a non-streaming provider
  Then the policy releases all children with a journaled degradation, never hangs
```
→ spec file: `spec/lain/tools/subagent/stagger_spec.rb`

**Escalation triggers:**
- Real cache-write billing is provider-side and unobservable in a mock — this card's
  measurement is prefix-chain identity + ordering, NOT dollars; if the AC seems to need
  a live API assertion, stop (that is a later :integration run, not this card).

### I1 — The state feed: one struct, journaled sources, fan-out tee   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/cli/journal_tee.rb` (generalize 1→2 to 1→N sinks),
`lib/lain/status_feed.rb` (new: subscriber deriving {cache_deadline, fleet, inbox_count},
atomic-rename writes to `.lain/state.json`), `spec/lain/status_feed_spec.rb`,
`spec/lain/cli/journal_tee_spec.rb`
**Reuse:** `JournalTee`'s write-durable-first ordering (`journal_tee.rb:24-26`);
`Telemetry::TurnUsage` (cache fields) + the sliding-TTL warmth rule
(interface-integration.md § 1); `Projection#pending` for inbox count
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: the tee fans out
  Given a journal, a channel, and a status feed as sinks
  Then every event reaches all three, durable journal first, and a closed sink never
  breaks the others (the nvim-death blocker's lesson)

Scenario: state.json is atomic and current
  When a turn's usage lands
  Then .lain/state.json is replaced atomically with the TTL deadline (not a countdown),
  fleet state, and inbox count

Scenario: fleet derives from journaled events only
  Given today's :spawn events (W3's lifecycle events enrich this later without I1
  changes)
  Then the fleet field reflects exactly what the journal shows — StatusFeed never
  reaches into in-process registries

Scenario: a raising sink is loud, not lost
  Given the status-feed leg raises (e.g. ENOSPC on the tmp write)
  Then the journal write and channel leg still complete, and the failure surfaces
  namedly (the tee's swallow-set stays exactly ClosedQueueError — it must not grow)

Scenario: no consumer, no cost
  Given no status feed constructed
  Then chat behaves byte-identically to today
```
→ spec files: `spec/lain/status_feed_spec.rb`, `spec/lain/cli/journal_tee_spec.rb`

**Escalation triggers:**
- The tee ordering (durable first, swallow only ClosedQueueError on the channel leg) is
  a landed blocker fix — if generalizing to N sinks changes that ordering or the
  swallow-set, stop.
- `.lain/` is a PROJECT artifact — if state.json belongs under XDG runtime instead
  (Paths#runtime), stop and ask; the approved doc says `.lain/state.json` but the XDG
  chunk postdates it.

### I2 — `lain up`: the tmux session and status HUD   [wave 2] [risk: medium]

**Depends on:** I1
**Files:** `lib/lain/cli/up.rb` (new: create/attach the lain tmux session, set
session-scoped `status-right` reading state.json via #(jq), `status-interval`,
`monitor-bell`; spawn the chat window), `spec/lain/cli/up_spec.rb`
**Reuse:** `Mixlib::ShellOut` (the bash tool's dependency) for tmux calls; session-scoped
tmux options (interface-integration.md § 1 — session beats global, theme untouched)
**Shared-file wiring:** exe diff — an `up` Thor command (orchestrator applies)

**Acceptance criteria:**

```gherkin
Scenario: up creates the session idempotently
  Given no lain tmux session
  When lain up runs
  Then a session exists with session-scoped status-right showing warmth/fleet/inbox
  from state.json, and a second lain up attaches instead of duplicating

Scenario: the global theme is untouched
  Then no global tmux option changes (only -t lain session options set)

Scenario: no tmux degrades loudly
  Given no tmux binary or no server
  Then up fails with a named Lain::Error, not a backtrace

Scenario: missing jq cannot blank the HUD silently
  Given no jq binary
  Then up warns namedly (or falls back to a jq-free status formatter) — the status
  line must never be silently empty on a demo machine
```
→ spec file: `spec/lain/cli/up_spec.rb` (tmux shelled against a scratch socket
`tmux -L lain-spec`, skipped if no tmux binary)

**Escalation triggers:**
- The desktop runs tmux-next 3.7 but CI/other machines may not — if any option used is
  3.7-only, stop and record the floor version.
- Only the frontend touches stdout — `up`'s user output goes through the exe/Thor `say`
  path, not puts in lib; if that seam is awkward, stop rather than violate discipline.

### I3 — TTY prompt warmth snapshot   [wave 2] [risk: low]

**Depends on:** I1
**Files:** `lib/lain/frontend/tty.rb`, `spec/lain/frontend/tty_spec.rb`
**Reuse:** the StatusFeed struct (I1); Reline's fixed-prompt limitation (the approved doc
pins "as of prompt display", no mid-wait refresh — do not fight it)
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: the prompt shows warmth at display time
  Given a warm cache deadline in the feed
  Then the prompt renders a warm glyph/color; cold renders cold; no feed renders
  today's bare prompt

Scenario: non-tty output is untouched
  Given a piped/spec IO
  Then the prompt is byte-identical to today (no escapes)
```
→ spec file: `spec/lain/frontend/tty_spec.rb`

**Escalation triggers:**
- The countdown owns the bottom line during shutdown — if the prompt segment and
  countdown interleave torn output, stop; the countdown's ownership is spec-pinned.

### I4 — The approval queue behind Handler::Gate   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/approval.rb` + `lib/lain/approval/queue.rb` (new: pending approvals
with requester, tool, surface, decision, latency; journaled decisions; timeout=deny),
`lib/lain/frontend/approval_policy.rb` (becomes a queue surface), `spec/lain/approval_spec.rb`,
`spec/lain/frontend/approval_policy_spec.rb`
**Reuse:** `Handler::Gate`'s injected `#call(effect, context) → Boolean` seam
(`gate.rb:55-58`) — NO Gate changes; `Promise` for the block-until-decided shape;
the fail-closed doctrine (`gate.rb:41-49`)
**Shared-file wiring:** exe diff — chat wires the queue-backed policy in place of the
bare y/N policy (orchestrator applies)

**Acceptance criteria:**

```gherkin
Scenario: a gated call parks on the queue
  Given a tier-3 tool call under the queue policy
  Then the effect enqueues, the calling fiber parks, and the first surface decision
  resolves it (approve runs the tool, deny returns the refusal Result)

Scenario: decisions are journaled evidence
  Then each decision journals surface, verdict, and decision latency

Scenario: timeout is deny
  Given no surface answers within the configured window
  Then the effect is denied and journaled as timed-out (fail-closed holds)

Scenario: first answer wins
  Given two surfaces watching one pending approval
  Then the second answer is a no-op (single-shot resolution, no double-run)
```
→ spec files: `spec/lain/approval_spec.rb`, `spec/lain/frontend/approval_policy_spec.rb`

**Escalation triggers:**
- Gate's policy call is SYNCHRONOUS inside the tool dispatch — if parking the fiber there
  deadlocks the single-threaded reactor paths (the Agent's Sync bridge), stop and bring
  the backtrace; the fix may need the same defer pattern as ask_human, which is design.
- `DenyAll` stays the no-frontend default — if the queue policy leaks into any headless
  path (bench, specs), stop.

### I5 — Desktop notifications: dunstify with actions   [wave 2] [risk: low]

**Depends on:** I4
**Files:** `lib/lain/notify.rb` (new: dunstify adapter — send, action buttons, capture
chosen action; absent-binary → Null), `spec/lain/notify_spec.rb`
**Reuse:** `Mixlib::ShellOut`; the Null Object convention (`Sink::Null` exemplar);
verified: dunst advertises the `actions` capability (2026-07-11 machine check)
**Shared-file wiring:** exe diff — chat registers the notify surface with the approval
queue and the inbox (orchestrator applies)

**Acceptance criteria:**

```gherkin
Scenario: an approval notifies with buttons
  Given a pending approval and the dunst surface registered
  Then a notification fires with approve/deny actions and the chosen action resolves
  the queue entry (dismissal/timeout resolves deny, fail-closed)

Scenario: a question notifies
  Given an ask_human question lands
  Then a notification names the asking agent (no action buttons — answering happens at
  a real surface)

Scenario: no dunstify, no crash
  Given the binary is absent
  Then Notify::Null swallows sends and the queue still works via other surfaces
```
→ spec file: `spec/lain/notify_spec.rb` (ShellOut stubbed; a `:desktop`-tagged example
drives real dunstify, excluded by default)

**Escalation triggers:**
- dunstify blocks while waiting for an action — that wait must live on its own thread or
  task, never the reactor; if the blocking shape fights the fiber scheduler, stop.

### I6 — The human inbox: lain://inbox + drain UX   [wave 3] [risk: medium]

**Depends on:** I5
**Files:** `lib/lain/frontend/neovim/inbox_view.rb` (new), `lib/lain/frontend/neovim/
buffers.rb`, `lib/lain/frontend/neovim/runtime.lua` (`:LainReply`, inbox autocmds),
`lib/lain/frontend/tty.rb` (an `/inbox` drain command at the prompt),
`spec/lain/frontend/neovim/inbox_view_spec.rb`, `spec/lain/frontend/tty_spec.rb`
**Reuse:** `Projection#mailbox`/`#pending` (`projection.rb:38-59`) — the inbox IS this
projection rendered; `AskHuman#reply` (`ask_human.rb:104-114`); the RenderQueue
backpressure idiom (`rpc_thread.rb:15-93`); the `:nvim`-tagged spec harness
**Shared-file wiring:** exe diff — the blocking `answer_loop` (`exe/lain:437-443`)
rewires to arrival-note + inbox drain (orchestrator applies)

**Acceptance criteria:**

```gherkin
Scenario: questions land in the inbox, not as modal prompts
  Given two ask_human questions from two agents
  Then lain://inbox lists both with sender and age, agents keep working (promises
  pending), and the TTY renders a one-line arrival note instead of the inline question

Scenario: reply from the buffer
  Given the cursor on an inbox item
  When :LainReply submits an answer
  Then the promise resolves, the answer journals as the :message event, and the item
  leaves the pending view

Scenario: TTY-only sessions still drain
  Given no nvim attached
  When the user runs /inbox at the prompt
  Then pending items list and answering one resolves it (the inline path remains the
  no-inbox fallback)

Scenario: the tmux flag counts
  Then the state feed's inbox_count matches the pending projection after each arrival
  and drain
```
→ spec files: `spec/lain/frontend/neovim/inbox_view_spec.rb`, `spec/lain/frontend/tty_spec.rb`

**Escalation triggers:**
- Today `perform` BLOCKS the asking tool call on `promise.await` — questions park the
  asker, not the whole team; if converting the TTY from inline-render to
  arrival-note breaks the single-question `@pending` invariant (`ask_human.rb:33-43`),
  stop: multi-question is an explicit design step, not a drive-by.
- Inbox consumption counts `:turn` causal edges only (`projection.rb:109-113`) — a
  REPLY is a `:message`, not consumption; if the pending view needs a new consumption
  rule, stop and surface it.

### I7 — lain:// buffer ergonomics: filetypes, syntax, motions   [wave 4] [risk: low]

**Depends on:** I6
**Files:** `lib/lain/frontend/neovim/runtime.lua` (filetype autocmds, syntax file
strings, buffer-local maps), `spec/lain/frontend/neovim/buffers_spec.rb` (assert
filetype/ maps set via the `:nvim` harness)
**Reuse:** built-in nvim filetypes — `diff` for lain://diff, `markdown` for
lain://request (treesitter parsers the user already has attach via filetype; no custom
grammar); the injected-namespaced-idempotent runtime.lua conventions
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: existing highlighting attaches by filetype
  Then lain://diff gets filetype diff and lain://request gets markdown — whatever
  treesitter/syntax the user's config attaches to those filetypes just works

Scenario: the bespoke buffers get a small syntax
  Then lain://timeline, journal, and inbox define a namespaced regex syntax (digests,
  roles, event kinds, ages) — no treesitter grammar shipped

Scenario: motions navigate records
  Then ]] / [[ jump between turns (timeline) and items (inbox/journal) buffer-locally,
  and <CR> on an inbox item invokes :LainReply

Scenario: user mappings are respected
  Then all maps are buffer-local and namespaced; re-attach is idempotent
```
→ spec file: `spec/lain/frontend/neovim/buffers_spec.rb`

**Escalation triggers:**
- If markdown filetype on lain://request triggers user plugins with side effects
  (auto-format on save in an EDITABLE buffer feeding :LainResend), stop — a formatter
  rewriting request bytes is a correctness hazard, and the answer (a guard, a different
  filetype) is policy.

## Integration checks

1. Full suite green (`bundle exec rspec`), rubocop clean at default metrics,
   `cargo test` + clippy green; **zero pending examples remain** (S2 un-parks the four).
2. **Old-journal compatibility**: a pre-R1 recorded session journal loads, resumes, and
   Rewrites-localizes under the new chain format (R1's dual-read proven on a real file).
3. **Supervision demo dry-run (manual, Joel)**: `bin/demo-supervision` — kill an actor
   mid-task, watch the restart land on the same head digest and workspace; then the same
   flow live in `lain up` with the HUD showing fleet state.
4. **Fan-out demo dry-run (manual, Joel)**: the C3 staggered-vs-control table renders;
   in a live session, four sibling researchers spawn staggered and the journal shows
   dispatch order + shared template chain.
5. **Interface pass (manual, Joel)**: `lain up` HUD ticks warmth/fleet/inbox; an
   approval arrives as a dunst notification with working approve/deny buttons AND as the
   TTY prompt; two queued questions drain from lain://inbox with :LainReply and /inbox;
   buffer motions and highlighting feel right (I7 is taste — veto here).
6. ROADMAP updated: TL-3/TL-5 closed with the ruling recorded (pointing at
   `planning/dominator-meet-research-2026-07.md`); rust-findings-resolution
   and code-review-ollama-test-infra marked [built] (stale "Planned" markers fixed);
   CE-4/CE-5, OM-6, and the landed interface experiments marked; remaining-work.md R.1–R.5
   checked off; the parked-pending note (ROADMAP § Status) removed.

## Execution record (closed 2026-07-17)

All 22 cards landed on `main`, one commit each, every card TDD-red then panel-reviewed
(adversarial probes on medium/high risk); probes that bit became fix-round specs. Suite
at close: **2513 examples, 0 failures, 1 pending** (the `:desktop` real-dunstify test
only — S2 un-parked the four T25 parity pendings), rubocop clean, `cargo test` 86/0,
clippy clean under `-D warnings`. Commits: RES4 `5b455c1`, R5 `d6b96fe`, RES3 `802a5ea`,
S1 `ad87eb6`, RES2 `350b4b9`, RES1 `9e830dd`, I4 `ab9a644`, R1 `8851a25` (+bin fix
`3b4fb7b`), W1 `b2b1051`, I1 `86a2be0`, C2 `5b077c9`, I3 `66fd148`, R2 `6af5c72`, S3
`2448124`, I5 `d42cb44`, W2 `03ef086`, R4 `d72fc24`, C1 `b2967b9`, I2 `9b9ecd2`, S2
`9cb930f`, W3 `b315b60`, I6 `d0a3960`, C3 `738f83e`, I7 `e275470`, W4 `fe9de76`, live
exe wiring `cd131b8`.

### Manual demos owed Joel (not runnable headless — a human at the terminal/desktop)

1. **Supervision** — `bin/demo-supervision` (kill an actor mid-task, watch it restart on
   the same head digest + workspace, zero re-spend); then the same flow live in `lain up`
   with the HUD showing fleet state.
2. **Fan-out** — `bin/demo-fanout` (the staggered-vs-control table: 1 write + N−1 reads
   vs N writes); then four sibling researchers staggered in a live session.
3. **Interface pass** — `lain up` HUD ticking warmth/fleet/inbox; an approval as both a
   dunst notification (working approve/deny buttons) AND the TTY prompt; two queued
   questions drained from `lain://inbox` via `:LainReply` and `/inbox`; buffer
   motions/highlighting (I7 is taste — your veto).

### Follow-up tickets (raised by the review panels; none gate this chunk)

- **Exe composition smoke (highest-value coverage gap)** — the assembled `Repl` (Supervisor
  + notify surface + inbox drain + StatusFeed sink + channel threading, wired at `cd131b8`)
  has no committed spec driving it end-to-end; each collaborator is unit-tested in isolation
  but the composition a real `lain chat` runs is verified only by hand (the assembly agent's
  throwaway async smokes) and by reasoning (that is how the live-HUD inbox over-count was
  found, not by a failing test). Add a `Provider::Mock`-backed spec that boots the Repl and
  drives one turn raising a tier-3 approval and an `ask_human` arrival, asserting the wired
  collaborators compose (approval resolves, StatusFeed publishes, inbox reflects the pending
  question). No network, no desktop — cheap, and it converts the exe layer from hand-verified
  to a regression guard. The `:nvim`/`:desktop`/`:integration`/`:live` surfaces stay
  human-verified by the manual demos above by nature (a headless run cannot assert a tmux
  status line renders or a dunst button works); this ticket closes only the part that can be
  automated.
- **Flag-gated `JournalBlobs` CLI wiring** — replay-restart works via the lib API +
  `bin/demo-supervision`, but no `exe` wires `snapshot_writer`→`JournalBlobs` into a real
  `lain chat`, so a killed on-disk session has no blob records to restore from. Deliberately
  NOT defaulted on: the Journal grows file-size × edit-count (dedup collapses only verbatim
  repeats), so real-session snapshot persistence must be an explicit opt-in flag.
- **Live-HUD inbox over-count** — the consuming `:turn` that retires an inbox item goes
  straight to `@journal`, not the tee, so `StatusFeed`'s `inbox_count` increments on arrival
  but never decrements live. Needs a lib card routing that event-path through the tee.
- **W3 `Actor#launch` pre-`@task` race** — `launch` with real IO in the initial turn
  suspends before `@task` is assigned; a bare `task.async { launch }` without `.wait` wedges
  the reactor. `Supervisor#adopt`'s `.wait` closes it (W4 relies on this); the real fix is in
  `Actor#launch` (assign `@task` before the eager `.async`, or spec `.wait` as contract).
- **`dominator_meet` production bite** — today's production spawn roots are meta-only links,
  so `dominator_meet` answers empty for real spawned children until roots are causally
  anchored (the same causal-edge-grain question W3 records).
- **S2 residuals** — `Ext::Timeline#commit` lacks `causal_parents:` (Ruby parity gap, loud
  ArgumentError, no digest divergence); per-kind envelope cargo vectors (only `:turn` has
  one); the crate never declares `rb_ext_ractor_safe` (calls off the main ractor raise,
  though `Ractor.shareable?` holds).
- **W3 `Drain::Expired`** — the bounded-drain timeout keys on `Async::TimeoutError` class, so
  an actor whose own failure is coincidentally an `Async::TimeoutError` is misread as the
  bound. A dedicated `Drain::Expired` exception makes it exact.
- **C3 post-first-token stall** — a provider that streams its first token then stalls (no
  completion, no raise) wedges the whole staggered `#call`; a dispatch-completion timeout is a
  later card (documented in `Stagger`'s class doc).
- **W3 address-collision fleet undercount** — identical spawns share a content-addressed
  address, so two live actors collapse to one HUD fleet entry (object-routing for tell/stop
  stays correct; the Array registry keeps both).
- **`InboxView` per-event re-walk** — `InboxView#consume` re-walks the full head chain per
  `TurnUsage` (matches the pre-existing `Buffers#timeline_update` precedent; a second full
  walk over the same stream). Bound if long sessions make it visible.
- **RES1 streamed retry buffer reuse** — the `on_data` buffer/`EventStreamParser` is reused
  across faraday-retry attempts; masked today by the outer `ErrorMiddleware` backstop, but a
  mid-stream SSE error after a first response consumed content is a latent corruption (needs a
  live/chunked repro).
