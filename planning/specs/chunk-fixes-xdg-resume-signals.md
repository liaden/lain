# Chunk: critique fixes · XDG paths · durable sessions & resume · graceful exit

status: draft
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman · Aaron Patterson

## Intent

Land the 2026-07-16 review's blocker and eight majors (the panel critique of
`chunk-spine-agents-sweep-nvim`), then make the harness a durable citizen: XDG Base
Directory conformance (ROADMAP § Interface & UX, `[planned]` 2026-07-11), chat sessions
that persist to disk and **resume** — including after SIGKILL or power loss — and a
graceful-exit path (SIGTERM/Ctrl-C grace countdown with cancel / wait-longer /
wait-until-responses). This realizes M2's "resume-after-crash as a property, not a
feature" and the event-sourcing spine's "session-resume is replay to a checkpoint"
(ROADMAP § Event sourcing). Compaction stays a render-side view: the on-disk record keeps
every tool result and turn verbatim even when the rendered context is compacted — review
of old sessions reads the log, never the summary.

## Grounding (verified 2026-07-16, four review panels + three Explore passes, HEAD 0579361)

**Critique findings (each probe-confirmed at this HEAD):**
- Blocker: nvim death closes the tee'd channel; `Accounting#observe` → `JournalTee#<<` →
  `ClosedQueueError`, unrescued (`exe/lain:120-131`, `lib/lain/frontend/neovim.rb:56-59`,
  `lib/lain/channel/drop_oldest.rb:76`). Quitting the editor kills the chat.
- `Prompt::LockedBinding` evaluates against `evaluate`'s own binding; leaked locals
  (`source`, `label`, `template`) are reachable via self-assignment
  (`<% template = template %>`), which Prism sees as `LocalVariableRead` — probe rendered
  nondeterministic bytes (`lib/lain/prompt/locked_binding.rb:55-59`).
- `Subagent::Actor`: `Async::Stop` unwinds `run` past the `StandardError` rescue with
  `@ready` unresolved → `settle` parks forever (`actor.rb:130-137`); a child that raised
  ends its fiber normally so `tell` accepts messages nobody will fold (`actor.rb:89-99`);
  `stop` before `launch` emits a farewell then `NoMethodError`s on `@task.stop`
  (`actor.rb:107-115`).
- `Context::Mailbox` advances its cursor at render time (`context/mailbox.rb:69`) —
  a dispatch that never succeeds permanently loses messages, and `Context#render` purity
  (same args → same bytes) breaks on the second render.
- Event envelope docs claim the payload lives in the Store under `payload_digest`
  (`event.rb:17-33`); no production path stores it (`timeline.rb:56-58`,
  `subagent/lineage.rb:73-80`, `ask_human.rb:132-140`) — every stored event dangles.
- `Event::Projection` aliases its caller's Array (`Array#to_a` returns self,
  `event/projection.rb:24-26`).
- `Subagent` hands children `Session::Null` (`subagent.rb:223`) — `EditFile`'s
  read-before-write contract (`edit_file.rb:36`) can never be satisfied by a child.
- `bench sweep` reads `spec/fixtures/memory/*` (`sweep.rb:46-47`); the gemspec excludes
  `spec/` — installed-gem invocation dies on raw `Errno::ENOENT`. Fixtures: 644K JSON +
  12K YAML.
- The nvim drain thread lacks the death discipline its two sibling threads have;
  `teardown`'s `drainer&.join` re-raises inside `ensure`, skipping `@rpc.stop`
  (`neovim.rb:102-108, 168-178`).
- Duplication the fixes route through: correlation derivation ×3 (`timeline.rb:153-157`,
  `lineage.rb:86-89`, `ask_human.rb:145-148`); payload-then-envelope writing ×2
  (`lineage.rb:73-88`, `ask_human.rb:132-148`).

**Durability/resume state:**
- `Journal` (`journal.rb`): append-only NDJSON, `@io.sync = true`, single `write` under a
  Monitor, lossless-parse invariant. **No fsync.** Default path `.lain/sessions/<UTC>-<pid>.ndjson`
  (`journal.rb:42,61-63`). Plain `lain chat` opens **no** journal — only `--nvim` does
  (`exe/lain:139`), and even then no `session`/`turn` records; only `bench record`
  (`bench/cli/run_recorder.rb:27-51`) produces loadable files.
- Full turn content (assistant blocks **and** `tool_result` blocks, which re-enter as
  `role: :user` turns — `agent.rb:239-241`) lands on disk only via `turn` records written
  by `Bench::Session.write` (`bench/session.rb:126-130,170-173`).
- `Bench::Session::Loader` (`loader.rb:119-176`) rebuilds Timeline+Store by **re-committing
  every turn and verifying digests**, rebuilds Requests, memory (`MemoryReplay` with root
  verification), ledger, slot fills. One `session` header per file enforced
  (`bench/session.rb:24-31`, `loader.rb:77-87`). `RecordedToolset` is schema-bytes only.
- `Store` is purely in-memory (`store.rb:18`); `Store#put` duck-validates
  `parent`/`render_parent`/`causal_parents` edges (`store.rb:66-85`) — `Payload`
  (`event/payload.rb`) names none, so it stores as parentless. `Payload` is
  content-addressed and frozen.
- `Agent` **already accepts `timeline:`** (`agent.rb:71,84` — `timeline || Timeline.empty`),
  with `Subagent#spawn_agent` as a production caller; the seam is real but unpinned
  (`agent_spec.rb` has no `timeline:` example). *(Corrected by the plan panel — an
  earlier Explore pass claimed no seam existed.)* `Session` run-state (read-set, todo
  reminder, manifest pair — `session.rb:39-43`) is never journaled.
- `Context::Compact` exists and is pure/injected (`context/compact.rb:30-54`).

**Signals/interrupt state:**
- **Zero** `Signal.trap` / `at_exit` anywhere. Ctrl-C mid-turn raises `Interrupt` up
  through `Sync`, terminating the process (TTY's `ensure` restores the screen —
  `tty.rb:75-83`).
- The cancellation substrate is done and spec-locked: `Budget#interrupt` = `task.stop`
  (`budget.rb:55-57`, no production caller), `defer_stop` shields commit+journal as one
  atom with stop-preempts-raise precedence (`agent.rb:186-196`,
  `spec/lain/agent_cancellation_spec.rb:146-188`), tree-cancellation covers one-shot
  children and gathers (`tool_runner.rb:44-53`, `subagent_concurrency_spec.rb:138-159`),
  a stopped task's `wait` returns nil and the Repl already tolerates a nil response
  (`exe/lain:284`). Net::HTTP yields to the scheduler, so a stop lands at the next
  socket-read (docs/concurrency.md:172-215). `docs/concurrency.md:406-434` sketches the
  watchdog-calls-`interrupt` supervisor this chunk builds.
- Two-fiber reply path: `Repl#respond` (`exe/lain:280-302`) — `replier` parks on an
  `Async::Queue`, `ensure replier&.stop` is load-bearing.
- nvim teardown order is strict: channel close → resend-inbox close → join workers →
  `@rpc.stop` (`neovim.rb:102-108`).
- `Middleware::Timeout` (`middleware.rb:207-237`) has the injectable monotonic-clock seam
  a countdown reuses; `Actor#stop` (farewell → `@task.stop` → `@task.wait`) is the orderly
  child-shutdown template.

**Paths/XDG state:**
- No paths abstraction; no `XDG_*` read anywhere; nothing written to `$HOME` or `/tmp`.
  The only lain-owned dir is project-local `.lain/` (`journal.rb:42`, `slots.rb:22,47-49` —
  project root = `Dir.pwd`, no walk-up). Reline history is in-memory only (`tty.rb:93`).
  ENV consumed: `ANTHROPIC_API_KEY`, `AWS_BEARER_TOKEN_BEDROCK`/`AWS_REGION`,
  `LAIN_STREAM_DEBUG`. No xdg-shaped gem in the lockfile — hand-roll a small `Lain::Paths`.
  Error convention: refusals subclass `Lain::Error` next to their owner; exe maps to
  `Thor::Error` (`exe/lain:38-40`).
- Session naming precedents: `<UTC>-<pid>.ndjson` (journal default) vs `<i>.ndjson`
  (bench record); directory reads sort by filename (`bench/cli.rb:112-117`).
- nvim socket convention already documented as `$XDG_RUNTIME_DIR/lain/nvim-<sha256(cwd)[:12]>.sock`
  (DEBUGGING_NVIM.md:17, interface-integration.md:107-114).
- `lain chat --resume [session]` idempotent-by-default is the decided CLI shape
  (interface-integration.md:153-157, for tmux-resurrect).

## Decisions pinned in this plan (2026-07-16 interview)

1. **Payload stored at commit** (not docs-only): writers put the `Payload` before the
   envelope; `Store` validates `payload_digest` as an edge; `Event#fetch_body` works on
   every production path; the class docs become true. Event **digests do not change**
   (payload_digest was already hashed).
2. **Mailbox goes pure**: no mutable cursor. "Folded" is derived from the committed
   Timeline — a `:message` is pending iff no committed turn names it a causal parent. The
   assistant commit records the messages it folded as `causal_parents` (this also lands
   the first production writer of causal edges on turns, advancing the OM-1/OM-6
   edge-grain follow-up). A failed dispatch naturally re-folds.
3. **Sessions live under XDG_STATE**, not the project dir:
   `$XDG_STATE_HOME/lain/sessions/<project-hash>/<UTC>-<pid>.ndjson`, where
   `project-hash = sha256(File.expand_path(Dir.pwd))[0,12]` (the DEBUGGING_NVIM
   convention). The session header carries the full project path for humans; session
   discovery is directory-derived (sorted filenames), no separate index file.
   `.lain/` remains for project artifacts the user edits (slots); `Journal.default_path`'s
   `.lain/sessions` is retired. Nothing lands as a bare `$HOME` dotfile;
   `$XDG_RUNTIME_DIR` falls back to `/tmp/lain` (ROADMAP:596-601).
4. **Resume chains files, never reopens them**: each process run writes its own NDJSON;
   a resumed run's header carries `resumed_from` (prior file's basename + its verified
   head digest). The Loader follows the chain. The one-header-per-file rule stands;
   a SIGKILL can never corrupt a prior run's bytes.
5. **The response WAL** (2026-07-16 mid-plan addition, Joel's DB-WAL framing). Three
   options considered:
   (a) *journal-only*: fsync'd turn records at commit — crash mid-response loses the
   in-flight generation; (b) *spool tee*: raw provider bytes append to an fsync'd
   per-session `.wal` file, framed by request digest, as they stream; (c) *spool +
   salvage*: (b) plus a resume-time pass that re-assembles any **complete** response newer
   than the last committed assistant turn and re-commits it without re-spending, and
   surfaces **partial** tails as reviewable artifacts (never auto-committed — no valid
   stop reason exists). **Chosen: (c).** SSE is line-framed, so a truncated tail is
   detectable and discardable; the raw spool doubles as the rawest "review old behaviors"
   artifact and matches the transport fork's byte-diff-oracle culture.
6. **Signal semantics**: first SIGINT or a SIGTERM → grace countdown (default 60s,
   `--grace SECONDS`), rendered by the TTY with live options — `c`/Enter cancels the
   shutdown, `w` adds 60s, `r` switches to wait-until-responses (settle in-flight run and
   children, then exit), second Ctrl-C promotes to immediate. SIGQUIT → immediate
   structured stop, no countdown. "Immediate" is always `Budget#interrupt` (structured;
   `defer_stop` atoms complete; teardown `ensure`s run; `session_closed` journals with a
   reason) — never `exit!`. SIGKILL is untrappable by definition: fsync'd journal + WAL
   are what make it survivable, and that is the point of decision 5.
7. **Compaction retention is an invariant, not a card**: `Context::Compact` only shapes
   the *rendered* request; `turn` records journal full content at commit. An integration
   check (below) proves a compacted session's journal still replays byte-complete.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lain.gemspec`,
  `exe/lain`, `.rubocop.yml`, `spec/spec_helper.rb`, `spec/support/*`.
- `exe/lain` stays thin: every card puts its logic in `lib/` (`Lain::CLI::*`,
  `Lain::Frontend::*`) and hands the exe diff to the orchestrator, following the
  T15/CLI::Backend precedent.
- The four Ruby↔Rust digest-parity pendings (T25 of the prior chunk) stay pending; no
  card here may touch `ext/lain`. TL-3 remains Joel's open ruling.

## Panel amendments (review 2026-07-16, folded before presenting)

The plan panel (five-persona roster) returned REQUEST-CHANGES; both blockers and all
should-fixes are folded in below:
- **B1 (T13):** the scribe cannot discover `:message` events from a Timeline walk —
  causal edges point backward and `Store` has no enumeration API. Fixed: `ChainWriter`
  (T5) gains an observer seam; the scribe subscribes. T13 now depends on T5.
- **B2 (T6):** the "request env" render→commit channel did not exist. Fixed: the Agent
  re-derives the pending set at commit from the projection (pure function of the
  rendered head); `Event.turn`/`Timeline#commit` gain `causal_parents:`; `event.rb`
  added to Files; T6 now also depends on T5 (timeline.rb overlap made explicit).
- **S1:** `Agent#timeline:` already exists — T15 rescoped to spec-pinning the seam.
- **S2:** `spec/lain/grader/recall_spec.rb` reads the corpus too — added to T8.
- **S3:** `:message` records get their own additive record type (they cannot re-commit
  through the Loader's turn fold); T13 pins the fields, T14 owns the re-put.
- **S4:** default chat now wires `Middleware::JournalRequests` (T13 exe diff) so T18's
  salvage has `request_sent` records to key on.
- **S5:** T20 pins the trap→reactor wakeup mechanism; T22 gains the
  SIGTERM-while-parked-at-prompt scenario.
- **S6:** T2's AC now uses the actually-live escape (`<%= template %>` bare read).
- **S7:** T4's Files list now includes the two bridge sites.
- **N1–N4:** exit-time re-raise becomes a rendered notice (T9); T17 ACs made
  behavioral and frame-opening ownership pinned; "session index" wording deleted
  (directory-derived listing); T6's T5-dependency recorded.

## Open decisions

None gating. (TL-3 and the Rust re-port remain open from the prior chunk but no card
below depends on either.)

## Waves

Wave 1: T1, T2, T3, T4, T7, T8, T9, T10, T15   (no unmet deps)
Wave 2: T5 (←T4), T11 (←T10), T12 (←T10)
Wave 3: T6 (←T4, T5), T13 (←T1, T5, T11)
Wave 4: T14 (←T13), T16 (←T13), T17 (←T10, T13), T20 (←T3, T13)
Wave 5: T19 (←T11, T14, T15, T16), T21 (←T20)
Wave 6: T18 (←T17, T19), T22 (←T9, T20, T21)

Critical path: T4 → T5 → T13 → T14 → T19 → T18 (tied: T10 → T11 → T13 → …).

## Tasks

### T1 — Extract `JournalTee` to lib and survive editor death   [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/journal_tee.rb` (new; extracted from `exe/lain:120-131`),
`spec/lain/cli/journal_tee_spec.rb` (new)
**Reuse:** `Lain::CLI::Backend` extraction precedent (`lib/lain/cli/backend.rb`);
`Channel::DropOldest` close semantics (`channel/drop_oldest.rb:76,103`)
**Shared-file wiring:** `require_relative "cli/journal_tee"` in `lib/lain/cli.rb`;
exe diff replacing the nested class with `Lain::CLI::JournalTee` (orchestrator applies)

**Acceptance criteria:**

```gherkin
Scenario: journal leg survives a dead channel
  Given a JournalTee over a real journal and a closed DropOldest channel
  When an event is appended
  Then the journal receives the record and no error escapes

Scenario: journal leg writes first
  Given a channel whose << raises ClosedQueueError
  When an event is appended
  Then the journal already holds the record

Scenario: a live channel still receives events
  Given both legs open
  When an event is appended
  Then both the journal and the channel hold it
```
→ spec file: `spec/lain/cli/journal_tee_spec.rb`

**Escalation triggers:**
- If anything other than `ClosedQueueError` needs rescuing to survive editor death (e.g.
  the channel raises something else through a middleware), stop — the fix must not become
  a blanket rescue.
- `spec/lain/frontend/neovim_spec.rb`'s death-propagation examples pin that the channel
  *closes* on RPC death; if the fix changes when/whether it closes, stop.

### T2 — Evaluate slot templates against a zero-local clean binding   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/prompt/locked_binding.rb`, `spec/lain/prompt/slots_spec.rb` (add
examples)
**Reuse:** the existing Prism `Purity` allowlist and its spec table (`slots_spec.rb`)
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: leaked-local escape is closed
  Given the fill "<% template = template %><%= template %>"
  # the bare LocalVariableRead is the LIVE escape at HEAD — a receiver'd .to_s is
  # already rejected by erb_plumbing?; do not pin the dead variant
  When Purity.check! and render run
  Then it is rejected as impure OR renders byte-identically across two fresh Slots
  # (either closing the parse hole or emptying the binding satisfies the invariant;
  #  the invariant is byte-stability, pin THAT)

Scenario: no evaluator locals are readable
  Given a fill that names any of source/label/template as a bare local
  When rendered
  Then the bytes contain no object inspection of the evaluator's state

Scenario: legitimate fills still render
  Given the shipped system.md.erb and every role template
  When rendered twice
  Then bytes are identical and digests unchanged from HEAD
```
→ spec file: `spec/lain/prompt/slots_spec.rb`

**Escalation triggers:**
- If fixing the binding changes any shipped template's rendered bytes (slot digests are
  journaled as `slot_fills` and cache-relevant), stop — digest stability of existing
  fills is the acceptance bar.
- If a zero-local binding breaks the `render("name")` helper resolution inside fills,
  stop and confirm the helper-surface design rather than re-widening the binding.

### T3 — Harden the actor lifecycle: settle, tell, stop   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/tools/subagent/actor.rb`, `spec/lain/actor_spec.rb` (add examples)
**Reuse:** `Async::Variable` resolve-once semantics; the probe scenarios from the
2026-07-16 review (settle-after-early-stop; tell-after-failure)
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: settle never parks forever after an early stop
  Given a launched actor whose provider is still in flight
  When stop is called and then settle
  Then settle returns (or raises the recorded failure) within the reactor tick

Scenario: tell refuses a failed actor
  Given an actor whose turn raised and whose failure settle has surfaced
  When tell is called
  Then it raises Stopped (or an equally loud refusal) and the mailbox does not grow

Scenario: stop before launch fails loudly without side effects
  Given an actor never launched
  When stop is called
  Then it raises a named error and no farewell event enters the Store

Scenario: existing lifecycle survives
  Given the current actor_spec examples
  Then all pass unchanged
```
→ spec file: `spec/lain/actor_spec.rb`

**Escalation triggers:**
- The plan-doc NIT from T23 says the OM-6 supervisor will pin delivery semantics; if the
  tell-after-failure fix requires *changing* mailbox fold semantics (not just refusing),
  stop — that is OM-6 scope.
- If `@ready` resolution on `Async::Stop` requires rescuing `Exception`, stop and confirm
  the `ensure`-based shape instead.

### T4 — Store the payload at commit; validate `payload_digest` as an edge   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/timeline.rb` (`#commit` puts payload before envelope),
`lib/lain/store.rb` (`parent_edges` learns `payload_digest`), `lib/lain/event.rb`
(class docs become true; `fetch_body` error message updated),
`lib/lain/tools/subagent/lineage.rb` + `lib/lain/tools/ask_human.rb` (two-line
payload-then-envelope bridges at the existing put sites — extraction is T5's job),
`spec/lain/timeline_spec.rb`, `spec/lain/store_spec.rb`, `spec/lain/event_spec.rb`
**Reuse:** `Store#put` idempotence and duck-typed `parent_edges` (`store.rb:66-85`);
`Payload` is already content-addressed and frozen (`event/payload.rb`)
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: a committed turn's body is retrievable
  Given a Timeline commit
  Then store.fetch(head.payload_digest) returns the Payload and fetch_body succeeds

Scenario: digests are unchanged
  Given the variance fixtures at HEAD
  When re-loaded through the Loader
  Then every recomputed digest still verifies (payload storage is additive)

Scenario: an envelope naming an absent payload is refused
  Given a hand-built Event whose payload was never put
  When store.put(event) runs
  Then MissingObject is raised naming the payload digest

Scenario: Ractor-shareability holds
  Then Ractor.shareable?(stored payload) is true
```
→ spec files: `spec/lain/timeline_spec.rb`, `spec/lain/store_spec.rb`,
`spec/lain/event_spec.rb`

**Escalation triggers:**
- `spec/lain/rust/store_spec.rb` pins byte-parity of `MissingObject` messages across
  impls; if extending `parent_edges` changes any pinned message byte, stop.
- If any existing spec hand-builds envelopes without payloads and now fails the new edge
  validation in ways that require weakening validation (rather than fixing the spec's
  setup), stop.
- `Lineage#put` and `AskHuman#write_message` will fail the new validation until T5 —
  if they cannot be made green *within this card* by putting payload-then-envelope at
  their two existing sites (a two-line bridge each, extraction deferred to T5), stop.

### T5 — Extract the chain writer: one home for message-writing and correlation   [wave 2] [risk: medium]

**Depends on:** T4
**Files:** `lib/lain/event/chain_writer.rb` (new — payload-then-envelope put + the
`head && (head.correlation || head_digest)` identity derivation + an **observer seam**:
an injected callable, Null default, invoked with every event it writes — this is the
one funnel all `:message`/`:spawn` events pass through, and it is how T13's scribe
sees them, since causal edges point backward and the Store cannot be enumerated),
`lib/lain/tools/subagent/lineage.rb`, `lib/lain/tools/ask_human.rb` (both delegate),
`lib/lain/timeline.rb` (`#correlation` made public; `next_correlation` delegates),
`spec/lain/event/chain_writer_spec.rb` (new)
**Reuse:** the three existing copies (`timeline.rb:153-157`, `lineage.rb:73-89`,
`ask_human.rb:132-148`) — behavior is pinned by `spec/lain/tools/subagent_spec.rb` and
`spec/lain/tools/ask_human_spec.rb`
**Shared-file wiring:** `require` line in `lib/lain/event.rb`'s subtree index (event.rb
is the unit index — loads after the class body, like `effect/handler.rb`'s children)

**Acceptance criteria:**

```gherkin
Scenario: one derivation, three callers
  Given a chain with and without an explicit correlation head
  When Lineage, AskHuman, and Timeline derive identity
  Then all three produce the digest the current suite pins, via the shared object

Scenario: every message write stores its payload
  When a :spawn or :message event is written through the chain writer
  Then the payload is fetchable from the Store (T4's edge validation passes)

Scenario: the observer sees every write
  Given a chain writer with an observer injected
  When Lineage and AskHuman write events through it
  Then the observer received each event exactly once, in write order; with no observer
  injected, behavior is unchanged

Scenario: no behavioral drift
  Then subagent_spec, ask_human_spec, and timeline_spec pass unchanged
```
→ spec file: `spec/lain/event/chain_writer_spec.rb`

**Escalation triggers:**
- If unifying the derivation exposes that any caller *intends* a different correlation
  grain (the plan doc's OM-1/OM-6 note), stop — do not paper over a semantic fork.
- If the extraction wants to change `Lineage`'s public surface (its spec is
  correlation-grain-documented), stop.

### T6 — Make `Context::Mailbox` a pure projection; record folded messages as causal parents   [wave 3] [risk: high]

**Depends on:** T4, T5 (timeline.rb overlap; correlation surface)
**Files:** `lib/lain/context/mailbox.rb` (cursor deleted; folded-set derived),
`lib/lain/event/projection.rb` (`@events = events.to_a.dup.freeze`; pending-message
projection keyed on causal edges), `lib/lain/event.rb` (`Event.turn` accepts
`causal_parents:`, default `[]` — today it has no such parameter and the projection
spec must hand-build turns to get one), `lib/lain/timeline.rb` (`#commit` accepts and
threads `causal_parents:`), `lib/lain/agent.rb` (at commit, the Agent **re-derives**
the pending set from the projection at the rendered head — "folded" is a pure function
of `(timeline-at-render, mailbox source)`, so render and commit computing it
independently CANNOT disagree; no render→commit side-channel exists or is added),
`spec/lain/context/mailbox_spec.rb`, `spec/lain/event/projection_spec.rb`,
`spec/lain/timeline_spec.rb`
**Reuse:** `Projection.mailbox` fold (`event/projection.rb`); `Store` already validates
causal edges; T5's public `Timeline#correlation`
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: render is pure again
  Given pending messages and a fixed Timeline
  When render runs twice with the same arguments
  Then the request bytes are identical

Scenario: a failed dispatch loses nothing
  Given a render that folded two messages
  When no turn commits (the dispatch raised) and render runs again
  Then both messages fold again

Scenario: a committed turn consumes its folded messages
  Given a render that folded two messages and a commit recording them as causal parents
  When render runs on the new head
  Then neither message folds again, and diverge-safe: a fork before the commit still sees them

Scenario: projection no longer aliases its input
  Given an Array of events
  When the caller appends to it after constructing a Projection
  Then the projection's views are unchanged
```
→ spec files: `spec/lain/context/mailbox_spec.rb`, `spec/lain/event/projection_spec.rb`

**Escalation triggers:**
- `Context#render`'s signature is architecture (`(Timeline, Toolset, Workspace) → Request`);
  if the pure re-derivation at commit turns out to need information only the render-time
  stage had (i.e. render and commit CAN disagree about the pending set), stop — that
  falsifies the design premise and a side-channel becomes a real decision, not a hack.
- Turn digests change when `causal_parents` are non-empty (they are hashed) — that is
  *correct* (content changed), but if any committed fixture or parity spec breaks because
  a previously-empty field now populates on the *default* no-mailbox path, stop: the
  default path must keep producing byte-identical digests.
- The prior plan ratified "cursor advances at render time" as a NIT to pin with OM-6;
  this card supersedes that note — update the T23 residual-NIT line in
  `chunk-spine-agents-sweep-nvim.md` (one-line edit, orchestrator applies).

### T7 — Give spawned children a real Session   [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/tools/subagent.rb` (`session: Session.new` per spawn; `Session::Null`
only where semantics are genuinely absent), `spec/lain/tools/subagent_spec.rb` (add
examples)
**Reuse:** `Session.new` is dependency-free (`session.rb`); the read-before-write
contract spec (`spec/lain/tools/*edit_file*`)
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: a write-capable child can satisfy read-before-write
  Given a child granted read_file and edit_file
  When it reads then edits a file
  Then the edit is not refused for want of session.read?

Scenario: children do not share the parent's session
  Given a parent that has read a file
  When a child spawns
  Then the child's session has an empty read-set

Scenario: sibling children do not share sessions
  Given two children spawned in one turn
  Then each holds its own Session instance
```
→ spec file: `spec/lain/tools/subagent_spec.rb`

**Escalation triggers:**
- If the spawn seam's re-entrancy contract (T23's "return records, don't stash ivars")
  makes a per-spawn Session awkward to thread, stop — do not reintroduce per-call ivar
  state to carry it.
- If any existing spec relies on children being session-blind (e.g. the attenuated
  read-only chat child), confirm the child's *toolset* is what enforces read-only-ness,
  not the Null session.

### T8 — Package the sweep corpus with the gem   [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/bench/corpus/retrieval_corpus.yml`,
`lib/lain/bench/corpus/corpus_embeddings.json` (moved from `spec/fixtures/memory/`),
`lib/lain/bench/sweep.rb` (paths become `File.expand_path("corpus/...", __dir__)`;
missing file → a named `Lain::Error` refusal, not `Errno::ENOENT`),
`spec/lain/bench/sweep_spec.rb`, `spec/lain/bench/sweep_fixture_spec.rb` (paths updated;
refusal example added), `spec/lain/grader/recall_spec.rb` (line 92 reads the corpus —
the third consumer the pre-move grep found; path updated)
**Reuse:** `Sweep::StaleEmbeddings` (`sweep.rb:30`) as the refusal-error precedent;
`Bench::CLI::Refusal` message voice (`bench/cli.rb:16`)
**Shared-file wiring:** none (gemspec already ships `lib/**`); if any spec support glob
assumed fixtures live under `spec/`, the orchestrator adjusts it

**Acceptance criteria:**

```gherkin
Scenario: sweep runs from packaged paths
  Given the corpus under lib/lain/bench/corpus/
  When lain bench sweep -k 5 runs in the checkout
  Then the report is byte-identical to HEAD's

Scenario: a missing corpus refuses namedly
  Given a corpus file deleted
  When sweep runs
  Then a Lain::Error naming the path is raised (the exe presents it without a backtrace)

Scenario: the content digest guard still holds
  Then the fixture-integrity spec passes against the new location
```
→ spec files: `spec/lain/bench/sweep_spec.rb`, `spec/lain/bench/sweep_fixture_spec.rb`

**Escalation triggers:**
- If any spec besides the sweep pair reads the moved fixtures (grep before moving), stop
  and list them — the move must not silently orphan a consumer.
- If gem size or `spec.files` policy is questioned (644K JSON now ships), note it in the
  commit message; do not split the corpus.

### T9 — Drain-thread death discipline and clobber-free nvim teardown   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/frontend/neovim.rb` (drain wrapped in record-death-and-close like its
siblings; `teardown` joins with deferred re-raise so `@rpc.stop` always runs),
`spec/lain/frontend/neovim_spec.rb` (add examples; `LAIN_NVIM=1`-gated like siblings)
**Reuse:** `record_death`/`reraise_recorded_failure` (`neovim.rb:56-59,92-95`) and the
resend-worker death pattern — the discipline exists twice already; this is the third copy
becoming a shared shape
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: an unexpected drain exception is recorded, not silent
  Given a drain fed an event whose render raises NoMethodError
  When the drain dies
  Then the failure is recorded, the channel closes, and run re-raises it after teardown

Scenario: teardown always stops the RPC thread
  Given a drainer that died mid-session
  When teardown runs
  Then resender is joined and @rpc.stop is called (no leaked thread)

Scenario: the block's own exception is not clobbered
  Given the run block raising A while the drainer died with B
  Then A propagates and B is observable (recorded), never swapped

Scenario: editor death ends as a notice, not a crash at exit
  Given T1 has made editor death survivable mid-session
  When the user later exits the chat normally
  Then the recorded RPC failure presents as a rendered notice (a Lain::Error the exe
  shows cleanly), not a raw re-raise with a backtrace
```
→ spec file: `spec/lain/frontend/neovim_spec.rb`

**Escalation triggers:**
- The strict teardown order (channel → inbox → joins → rpc.stop) is comment-documented as
  race-free; if the fix must reorder it, stop.
- If making the drain resilient means rescuing per-event and continuing (rather than
  die-loudly-and-close), stop — the two sibling threads' policy is record-and-die, match it.

### T10 — Build `Lain::Paths`: the XDG resolver   [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/paths.rb` (new unit: `config_home`, `cache_home`, `state_home`,
`runtime_dir` — each `$XDG_*` with the spec-mandated fallback (`~/.config`,
`~/.cache`, `~/.local/state`; runtime falls back to `/tmp/lain` per ROADMAP:600),
all suffixed `/lain`; `project_hash(dir = Dir.pwd)` = `sha256(expand_path)[0,12]`;
`sessions_dir(project: …)`; `mkdir_p`-on-demand with a named `Lain::Paths::Unwritable`
refusal), `spec/lain/paths_spec.rb` (new)
**Reuse:** `Journal.open`'s mkdir_p-then-own pattern (`journal.rb:50-58`);
`Canonical.digest`? — no: use `Digest::SHA256` (stdlib) to match DEBUGGING_NVIM's recipe;
error-taxonomy convention (refusal subclasses `Lain::Error` next to its owner)
**Shared-file wiring:** `require_relative "lain/paths"` in `lib/lain.rb` (early — it is
a leaf depending only on stdlib)

**Acceptance criteria:**

```gherkin
Scenario: XDG variables win
  Given XDG_STATE_HOME=/x
  Then state_home == "/x/lain" and sessions_dir starts with it

Scenario: fallbacks are the XDG-spec defaults
  Given the variables unset
  Then state_home == "$HOME/.local/state/lain" and runtime_dir == "/tmp/lain"

Scenario: project hash is stable and path-shaped
  Given two calls from the same cwd
  Then the same 12-hex-char hash; a different cwd gives a different hash

Scenario: unwritable target refuses namedly
  Given a state_home pointing into a read-only dir
  When a dir-ensuring accessor runs
  Then Lain::Paths::Unwritable names the path
```
→ spec file: `spec/lain/paths_spec.rb`

**Escalation triggers:**
- Specs must never touch the real `$HOME` — if isolating requires more than ENV stubbing +
  `Dir.mktmpdir`, stop.
- If any consumer needs a *project-root walk-up* (`.lain/` discovery beyond `Dir.pwd`),
  stop — that changes `Slots.load` semantics and is not this card.

### T11 — Route the Journal's default home through Paths   [wave 2] [risk: low]

**Depends on:** T10
**Files:** `lib/lain/journal.rb` (`default_path` → `Paths.sessions_dir/<UTC>-<pid>.ndjson`;
`SESSIONS_DIR` retired; optional `fsync: true` mode — when set, `#record` fsyncs after
write), `spec/lain/journal_spec.rb`
**Reuse:** the existing timestamp+pid naming (kept — it is the index-friendly scheme);
`@io.sync` discipline stays
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: default journal lands in XDG state
  Given XDG_STATE_HOME=/x and cwd C
  When Journal.open runs with no path
  Then the file is /x/lain/sessions/<hash(C)>/<UTC>-<pid>.ndjson

Scenario: fsync mode reaches the metal
  Given Journal.open(path, fsync: true)
  When a record is written
  Then IO#fsync was invoked after the write (observable via an injected IO double)

Scenario: injected-IO journals are untouched
  Given a StringIO journal
  Then behavior is unchanged (no fsync attempts on an IO that lacks it)
```
→ spec file: `spec/lain/journal_spec.rb`

**Escalation triggers:**
- `bench record --out` must stay experimenter-chosen and unaffected — if any bench spec
  breaks, stop.
- If anything outside specs referenced `.lain/sessions` (grep first), stop and list.

### T12 — Persist reline history to XDG state   [wave 2] [risk: low]

**Depends on:** T10
**Files:** `lib/lain/frontend/tty.rb` (load history at `run` entry; append each accepted
line durably — write-through, not dump-at-exit, so SIGKILL loses at most nothing),
`spec/lain/frontend/tty_spec.rb`
**Reuse:** `Reline::HISTORY` (already fed by `readline(…, true)` — `tty.rb:93`);
`Paths.state_home`
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: history round-trips a process
  Given a history file with two lines
  When TTY starts
  Then Reline::HISTORY contains them in order

Scenario: an accepted line is on disk before the next prompt
  When the user submits a line
  Then the history file already ends with it

Scenario: a missing or unwritable history file degrades loudly-but-usable
  Given state_home unwritable
  Then the prompt still works and one warning renders through the frontend (never $stderr
  from lib outside frontend/ — TTY *is* the frontend, so it may render it)
```
→ spec file: `spec/lain/frontend/tty_spec.rb`

**Escalation triggers:**
- History is a secret-adjacent surface (pasted keys). If size/permission policy questions
  arise beyond `0600` + append, stop and ask rather than inventing retention policy.
- Non-tty input mode (`@input.gets` fallback) must not create the file — if the seam makes
  that awkward, stop.

### T13 — The live session scribe: chat journals a loadable session   [wave 3] [risk: high]

**Depends on:** T1, T5, T11
**Files:** `lib/lain/session_record.rb` + `lib/lain/session_record/scribe.rb` (new unit:
the format's field names promoted out of `Bench::Session` — header write-first with
`head: nil` meaning *open*; `Scribe#catch_up(timeline)` appends `turn` records for every
event above the last-written head by walking the **render chain** — render-chain turns
only, that is all a Timeline walk can see; `:message`/`:spawn` events reach the scribe
by **subscribing to T5's ChainWriter observer seam** (causal edges point backward and
the Store has no enumeration API — a Timeline walk CANNOT find them; panel B1) and are
journaled as a NEW additive record type `message` pinning
`{digest, kind, from, to, payload, causal_parents, correlation}` — NOT the `turn` shape,
which the Loader digest-verifies through `Timeline#commit` and which a `:message` can
never survive (panel S3); `session_closed` record carries the final head anchor
+ a reason enum `%i[exit interrupted grace_expired]`; `run_interrupted` record for a
stop that beat the response), `lib/lain/telemetry.rb` additions ride this card
(`SessionClosed`, `RunInterrupted`, `Message`), `spec/lain/session_record_spec.rb`,
`spec/lain/telemetry_spec.rb` (discriminator examples)
**Reuse:** `Bench::Session.write`'s `turn_record` shape (`bench/session.rb:155-173`) —
the on-disk field names for TURN records stay byte-compatible so one Loader reads both
(the existing Loader's `of_type` narrowing skips unknown types, so the new `message`
type is invisible to old readers by construction); T5's ChainWriter observer; `Journal`
fsync mode (T11); `JournalTee` (T1) when `--nvim` runs too
**Shared-file wiring:** `require_relative "lain/session_record"` in `lib/lain.rb`
(after timeline/event); exe diff wiring chat to open a Paths-based fsync journal +
scribe by default with `--no-journal` opting out, **and wiring
`Middleware::JournalRequests` into default chat** (today it is `--nvim`-only —
`exe/lain:227-232`; T18's salvage keys on `request_sent`, so plain chat must journal
requests too; panel S4) (orchestrator applies)

**Acceptance criteria:**

```gherkin
Scenario: a chat turn is on disk before the reply renders
  Given a chat with the scribe attached
  When one ask completes
  Then the journal file contains the session header, the user turn, the assistant turn,
  and any tool_result turns, each fsync'd, digest-verifiable by re-commit

Scenario: an open session is recognizable
  Given a scribe that never closed (simulated SIGKILL — the process just stops)
  Then the file has a header with no anchor and no session_closed record, and every
  written turn still re-commits to its recorded digest

Scenario: graceful close anchors the head
  When close(reason: :exit) runs
  Then a session_closed record carries the final head digest and the reason

Scenario: ask_human Q&A survives
  Given a turn that asked a question and got a reply through an observed ChainWriter
  Then both :message events appear as `message` records carrying digest, kind, from/to,
  payload, causal_parents, and correlation — field-pinned here; re-putting them into a
  Store is T14's acceptance, not this card's
```
→ spec file: `spec/lain/session_record_spec.rb`

**Escalation triggers:**
- If any `:message` write path does NOT route through the ChainWriter (grep for direct
  `store.put` of message events after T5), stop — an unobserved writer means silent
  record loss, the exact failure class this chunk exists to close.
- `spec/lain/telemetry_spec.rb` pins `journal_type` strings as the on-disk contract —
  new types must be additive; if any existing discriminator wants renaming, stop.
- If per-turn fsync measurably stalls the REPL (it should not at human cadence), stop
  rather than silently dropping fsync.

### T14 — Teach the Loader open sessions and resume chains   [wave 4] [risk: medium]

**Depends on:** T13
**Files:** `lib/lain/bench/session/loader.rb` (accepts: header-first files, absent
anchor → verified-unanchored load; `resumed_from` in a header → recursively load the
prior file and verify its head matches the recorded digest before continuing the chain;
**owns re-putting T13's `message` records** — payload first, then envelope, digest
verified against the recorded one, causal edges validated by the Store),
`lib/lain/bench/session.rb` (header
gains optional `resumed_from`; `Corrupt` voice extended for chain breaks),
`spec/lain/bench/session/loader_spec.rb`
**Reuse:** `verified_turn`/`anchored` re-commit machinery (`loader.rb:119-142`);
`MemoryReplay.covered!` partial-chain precedent (`memory_replay.rb:91-98`)
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: an open (crashed) session loads
  Given a header-no-anchor file with N verified turns
  Then a Recording is returned flagged open, timeline head = the last verified turn

Scenario: a resume chain loads as one conversation
  Given file B whose header resumed_from names file A and A's head digest
  Then the loaded Timeline contains A's turns then B's, every digest verified

Scenario: a broken chain refuses
  Given B's resumed_from digest not matching A's actual head
  Then Corrupt names both digests

Scenario: message records rejoin the Store
  Given a session containing T13 message records for an ask_human Q&A
  When loaded
  Then both events are fetchable by digest with their causal edges intact, and an
  edited message record fails its digest check with Corrupt

Scenario: bench files load unchanged
  Then every existing loader_spec example passes as-is
```
→ spec file: `spec/lain/bench/session/loader_spec.rb`

**Escalation triggers:**
- If chain-following wants filesystem knowledge inside the Loader (it currently takes
  entries, not paths), stop and confirm the seam (a resolver duck injected, not
  `File.read` in the Loader).
- If `Recording`'s surface must change incompatibly for `open?`/chain metadata, check
  `bench variance`'s consumers first; stop on any breakage.

### T15 — Spec-pin the Agent's existing Timeline injection seam   [wave 1] [risk: low]

**Depends on:** none
**Files:** `spec/lain/agent_spec.rb` (add examples — spec-only card; the seam already
exists: `agent.rb:71,84`, with `Subagent#spawn_agent` as a production caller. The panel
corrected the original grounding here; T19 builds on this seam, so its behavior gets
pinned before T19 depends on it)
**Reuse:** `Agent#rewind`'s existing "resume from any earlier turn" note
(`agent.rb:130-134`); `Provider::Mock` for the spec
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: an injected timeline is the starting state
  Given a Timeline with three committed turns
  When Agent.new(timeline: it) asks a question
  Then the request renders all three turns before the new user turn

Scenario: the injected timeline's store is the agent's store
  Then subsequent commits land in the same Store (no copy)

Scenario: an injected mid-conversation head resumes without inventing a user turn
  Given a timeline whose head is an assistant turn
  Then ask commits exactly one new user turn on top of it
```
→ spec file: `spec/lain/agent_spec.rb`

**Escalation triggers:**
- If the machine's initial state (`:awaiting_user` vs `:awaiting_model`) must vary with
  the injected head's role, stop — resuming mid-tool-call is T18/T19 territory, not this
  card; this card may require the injected head to be a settled turn.

### T16 — Journal and replay Session run-state   [wave 4] [risk: medium]

**Depends on:** T13
**Files:** `lib/lain/telemetry.rb` (`SessionRead` — one per first-read of a path;
`TodoSnapshot` — whole list per write, matching Session's replace semantics),
`lib/lain/session.rb` (accepts an optional journal to emit through — or the scribe
subscribes; pick the seam that keeps Session journal-ignorant if possible),
`lib/lain/session_record/replay.rb` (new: fold the records back into a Session),
`spec/lain/session_spec.rb`, `spec/lain/session_record_spec.rb`
**Reuse:** `Memory::JournalMemoryRoot` decorator shape (`journal_memory_root.rb`) — the
precedent for "domain object stays pure, a decorator journals"; `MemoryReplay` for the
fold-back idiom
**Shared-file wiring:** exe diff if the decorator wires in chat (orchestrator applies)

**Acceptance criteria:**

```gherkin
Scenario: reads and todos round-trip
  Given a session that read two files and wrote a todo list twice
  When the journal is replayed into a fresh Session
  Then read?(each path) is true and the reminder renders the LAST todo list only

Scenario: the manifest pair needs no new record
  Given memory_root records already journaled
  Then replay reconstructs manifest reminders through the existing MemoryReplay root

Scenario: Session stays pure of journaling when decorated
  Then Session's own spec passes with no journal in sight
```
→ spec files: `spec/lain/session_spec.rb`, `spec/lain/session_record_spec.rb`

**Escalation triggers:**
- The read-set normalizes via `File.expand_path` — absolute paths in the journal leak
  machine specifics into a reviewable artifact; if that privacy/portability tradeoff
  needs a policy (relative-to-project?), stop and ask.
- If per-read records get chatty inside big tool loops, stop before inventing batching.

### T17 — The response WAL: spool raw provider bytes per session   [wave 4] [risk: high]

**Depends on:** T10, T13
**Files:** `lib/lain/provider/response_wal.rb` (new: append-only spool, one file per
session — `<session-stem>.wal` beside the NDJSON; frame = header line
`{request_digest, at}` + raw SSE/body bytes + terminator line with byte count and a
`complete: true/false` marker written on stream end; fsync on frame close, and on a
byte-count watermark mid-stream), transport tee: `lib/lain/provider/anthropic_raw/transport.rb`
(accepts an injected spool duck, `Spool::Null` default — every `on_data` chunk tees to
it), `lib/lain/provider/spool/null.rb`, `spec/lain/provider/response_wal_spec.rb`
**Reuse:** `Sink::Null` null-object precedent; `on_data` seam (`transport.rb:30-46`);
`request_sent` journaling already records the request digest the frame keys on
(`middleware/journal_requests.rb:32`)
**Shared-file wiring:** `require` lines in the provider unit index; exe diff wiring the
spool when the scribe is on (orchestrator applies)

**Acceptance criteria:**

```gherkin
Scenario: a streamed response is spooled verbatim
  Given a stubbed streaming response
  Then the .wal frame holds the exact bytes, keyed by the request digest, marked complete

Scenario: a crash mid-stream leaves a recoverable file
  Given a stream cut at 60% (no terminator written)
  Then a reader identifies the frame as incomplete and every prior frame as intact

Scenario: the sync path spools too
  Given a non-streaming completion
  Then one complete frame holding the raw HTTP response body as received off the wire
  (Faraday env.body BEFORE JSON parsing — never a re-serialization, which would forfeit
  the byte-oracle property)

Scenario: Null spool is free
  Given no spool injected
  Then transport behavior is unchanged and no spool file is created
```

Frame-opening ownership: the **Provider** opens the frame (it computes the request
digest) and hands the transport an opened frame handle; the transport only appends
chunks and closes. The transport never learns what a digest is.
→ spec file: `spec/lain/provider/response_wal_spec.rb`

**Escalation triggers:**
- The Provider is "one round trip, never a loop" — if the tee wants retry/reconnect
  awareness, stop.
- Raw bodies contain the full prompt echo? They do not (responses only) — but they DO
  contain model output that may quote secrets from context; the WAL inherits the
  journal's threat model. If anything wants scrubbing/encryption policy, stop and ask.
- If fsync-per-chunk measurably slows streaming, the watermark policy (e.g. every 64KiB)
  is the knob — pick one, document it, and note the measurement; stop only if no
  watermark satisfies both.

### T18 — Salvage on resume: recover paid-for responses from the WAL   [wave 6] [risk: medium]

**Depends on:** T17, T19
**Files:** `lib/lain/session_record/salvage.rb` (new: given a loaded open session + its
`.wal` — find frames whose request digest matches the last journaled `request_sent` and
which are newer than the last committed assistant turn; a **complete** frame re-assembles
through the provider's existing SSE accumulator and yields a committable Response; an
**incomplete** frame yields a reviewable artifact, never a commit),
`lib/lain/cli/resume.rb` (T19's assembler consumes this), `spec/lain/session_record/salvage_spec.rb`
**Reuse:** the SSE accumulation path in `Provider::AnthropicRaw` (the parser is already
separate from the socket); `Loader`'s open-session flag (T14)
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: a complete uncommitted response is recovered without re-spending
  Given an open session whose last record is request_sent and a complete WAL frame for it
  When salvage runs
  Then a Response equal to the original assembles and commits as the assistant turn,
  and no provider call is made

Scenario: a partial frame is surfaced, not committed
  Given an incomplete frame
  Then salvage returns it as text-with-provenance (request digest, byte count) and the
  timeline head is unchanged

Scenario: nothing to salvage is a clean no-op
  Given a session whose last turn committed normally
  Then salvage reports nothing and touches nothing
```
→ spec file: `spec/lain/session_record/salvage_spec.rb`

**Escalation triggers:**
- If the accumulator cannot be driven from recorded bytes without a socket (i.e. parsing
  is entangled with transport), stop — do not fork a second SSE parser; the seam must be
  extracted first.
- A salvaged commit is an assistant turn with no `turn_usage` (Accounting never saw it) —
  the Ledger prices from the journal, so document the zero-cost line and journal the
  salvage as its own record type; if that accounting story raises questions, stop.

### T19 — `lain chat --resume` and `lain sessions`   [wave 5] [risk: high]

**Depends on:** T11, T14, T15, T16
**Files:** `lib/lain/cli/resume.rb` (new: resolve `--resume` — bare flag = newest session
for this project's hash; an argument = filename/prefix under the project's session dir;
load via Loader (chain-aware), rebuild Session run-state (T16 replay), memory
(`MemoryReplay`), inject the Timeline (T15); open the NEW chained journal with
`resumed_from`; wire the live toolset/provider from the current flags — the recorded
schema bytes are display-only), `lib/lain/cli/sessions.rb` (new: list this project's
sessions — started-at, turns, open/closed/chained, head digest short form),
`spec/lain/cli/resume_spec.rb`, `spec/lain/cli/sessions_spec.rb`
**Reuse:** `Bench::CLI` directory-listing idiom (`bench/cli.rb:112-117`, sorted
filenames); `CLI::Backend` for provider resolution; Loader + Replay + Agent seam from
the dependency cards
**Shared-file wiring:** exe diff — `chat` gains `--resume [SESSION]`, a `sessions`
Thor command prints through `say` (orchestrator applies)

**Acceptance criteria:**

```gherkin
Scenario: resume restores the whole conversation
  Given a closed session of three turns
  When lain chat --resume runs and the user asks a fourth question
  Then the request carries all three prior turns and the new file's header chains to the old

Scenario: resume is idempotent
  Given a resumed session exited immediately
  When --resume runs again
  Then it resumes the head of the CHAIN (no fork, no duplicate)

Scenario: resume after SIGKILL works
  Given an open (unanchored) session file
  When --resume runs
  Then the verified turns load, the open state is reported to the user, and chat continues

Scenario: a corrupt or missing session refuses namedly
  Then a Lain::Error (not a backtrace) names the file and reason

Scenario: sessions lists honestly
  Given two closed sessions and one open one
  Then the listing marks each, newest first
```
→ spec files: `spec/lain/cli/resume_spec.rb`, `spec/lain/cli/sessions_spec.rb`

**Escalation triggers:**
- Recorded sessions carry the recorded model/provider in the header; if current flags
  disagree (resume an opus session with `--provider ollama`), pick LOUD: print both and
  continue with the flags — but if that policy feels wrong mid-build, stop and ask.
- Memory replay only reconstructs `memory_write`s that the journal saw; a session
  predating the scribe has none — refuse to resume pre-scribe `--nvim`-era files namedly.
- If resume-of-an-open-session must handle a head that is a `tool_use` turn awaiting
  results (crash mid-tool), stop: committing synthetic tool_results is a design decision,
  not an implementation detail. (T18 covers the response side; the tool side may need a
  "refused: re-ask" shape.)

### T20 — The shutdown coordinator   [wave 4] [risk: high]

**Depends on:** T3, T13
**Files:** `lib/lain/cli/shutdown.rb` (new: owns the run-task handle and the policy —
states `running → grace(deadline) → draining → closed`, inputs
`%i[sigint sigterm sigquit cancel extend wait_responses promote]`; grace default 60,
injectable clock (the `Middleware::Timeout` seam); on expiry or promote →
`Budget#interrupt(run_task)`; `wait_responses` → settle in-flight (the run task's own
`wait`; actors via `settle` — T3 makes that safe); every transition journals
(`session_closed` reason enum from T13); signal-safe ingress **pinned as a self-pipe**:
the trap body does one `write` of a single byte-tagged symbol to a pipe — an
async-signal-safe syscall — and the coordinator fiber parks on the pipe's read end,
which the fiber scheduler's `io_wait` hook makes reactor-native (the nvim RpcThread's
wake pipe — `rpc_thread.rb:220-225` — is the in-repo precedent; a `Thread::Queue`
drained by a fiber was considered and rejected: unblock-from-trap-context on the
reactor thread is version-sensitive, panel S5),
`spec/lain/cli/shutdown_spec.rb`
**Reuse:** `Budget#interrupt` (`budget.rb:55-57` — gains its first production caller,
exactly as `docs/concurrency.md:406-434` sketched); `agent_cancellation_spec`'s
`ParkingProvider` harness for deterministic in-flight tests; `Actor#stop` template
**Shared-file wiring:** `require` in `lib/lain/cli.rb`

**Acceptance criteria:**

```gherkin
Scenario: sigterm starts a grace window, expiry interrupts
  Given a run parked in a model call and grace 60 with an injected clock
  When sigterm arrives and the clock passes the deadline
  Then the run task is interrupted, the commit+journal atom completes (defer_stop), and
  session_closed records reason grace_expired

Scenario: cancel aborts the shutdown
  When cancel arrives mid-countdown
  Then the state returns to running and nothing was interrupted

Scenario: a second sigint promotes
  Given a countdown in progress
  When sigint arrives again
  Then the interrupt fires immediately with reason interrupted

Scenario: wait-until-responses settles then closes
  Given an in-flight run
  When wait_responses arrives and the provider completes
  Then no interrupt fires, the turn commits, then the session closes with reason exit

Scenario: sigquit skips the countdown
  Then immediate structured interrupt, same journaling
```
→ spec file: `spec/lain/cli/shutdown_spec.rb`

**Escalation triggers:**
- `Budget#interrupt` stops the task *hosting* the run — the handle must be the
  `task.async` wrapper (`exe/lain:283` shape), not the reactor task; if holding it
  across the Repl's Sync structure is awkward, stop and bring the wiring question back.
- If the coordinator fiber ever fails to wake on a trapped signal (the self-pipe read
  never returns under the scheduler), stop — do not paper over it with a poll loop.
- Stop-preempts-raise precedence is pinned (`agent_cancellation_spec:146-188`); if the
  coordinator's interrupt path could double-fire into a Budget ceiling raise, stop.
- No `exit!`, no `Thread#kill`, no trap-context allocation beyond the queue push — if any
  path seems to need one, stop.

### T21 — Countdown UI in the TTY   [wave 5] [risk: medium]

**Depends on:** T20
**Files:** `lib/lain/frontend/tty.rb` (`#render_countdown(deadline:, options:)` — one
status line redrawn on a timer tick, coexisting with the channel-drain render thread;
reads single keys for c/w/r during the window and feeds them to the coordinator;
non-tty input → render the countdown line without key handling),
`spec/lain/frontend/tty_spec.rb`
**Reuse:** `TTY.rule`/`::TTY::Screen.width` (`tty.rb:153-155`); the injected-clock seam
(T20); `render_question`'s synchronous-render precedent (`tty.rb:118`)
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: the countdown renders and ticks
  Given a deadline 3 ticks away with an injected clock
  Then three successive renders show decreasing seconds and the offered keys

Scenario: a key becomes a coordinator input
  When "w" is pressed during the window
  Then the coordinator receives :extend and the rendered deadline grows

Scenario: the drain thread and the countdown do not interleave torn lines
  Given channel events arriving during a countdown
  Then output lines remain whole (the countdown owns the bottom line; events render above)

Scenario: non-tty degrades to plain lines
  Given a non-tty output
  Then countdown state prints as plain lines, no key reading, no escapes
```
→ spec file: `spec/lain/frontend/tty_spec.rb`

**Escalation triggers:**
- Reline owns the terminal while parked at a prompt — a countdown firing mid-`readline`
  must not fight it; if the only clean answer is "interrupt the readline and re-prompt
  after", stop and confirm that UX.
- Only the frontend touches `$stdout` (output_discipline_spec) — the countdown must live
  entirely in TTY; if any coordinator state wants to print, it goes through the Channel.

### T22 — Wire the signals: trap, Repl, teardown   [wave 6] [risk: high]

**Depends on:** T9, T20, T21
**Files:** `lib/lain/cli/signals.rb` (new: installs `Signal.trap("INT"/"TERM"/"QUIT")`
pushing into the coordinator's queue, restores prior handlers on teardown; trap bodies
are push-only), `spec/lain/cli/signals_spec.rb` (real-signal integration examples,
`Process.kill` on self, tagged like other slow/system specs if needed)
**Reuse:** the coordinator (T20), countdown (T21); the strict nvim teardown order (T9);
`TTY#run`'s ensure (screen restore) — the shutdown path must thread through both ensures
untouched
**Shared-file wiring:** exe diff — chat installs Signals around the Repl, passes the
run-task handle per ask into the coordinator, `--grace SECONDS` flag (orchestrator
applies)

**Acceptance criteria:**

```gherkin
Scenario: SIGTERM ends a parked chat gracefully end-to-end
  Given a chat parked mid-model-call (ParkingProvider)
  When SIGTERM arrives and grace expires
  Then the process exits 0-or-documented-code, the terminal is restored, the journal
  ends with session_closed(grace_expired), and no thread leaks

Scenario: double Ctrl-C is immediate
  When two SIGINTs arrive inside the window
  Then the run is interrupted at once and the session closes as interrupted

Scenario: SIGTERM while parked at the prompt (no run in flight)
  Given a chat idle in Reline.readline with nothing for Budget#interrupt to stop
  When SIGTERM arrives and grace expires (or is promoted)
  Then the readline is broken out of, the session closes cleanly with session_closed,
  and the terminal is restored

Scenario: traps are restored
  When the Repl exits normally
  Then INT/TERM/QUIT handlers are back to their prior values

Scenario: nvim teardown still runs under signal exit
  Given chat --nvim
  When SIGTERM shuts the session down
  Then the RPC thread is stopped and joined (no leak), per T9's order
```
→ spec file: `spec/lain/cli/signals_spec.rb`

**Escalation triggers:**
- Reline installs its own INT handling inside `readline`; if the trap and Reline fight
  over INT at the prompt (vs mid-turn), stop and bring back the observed behavior — the
  resolution may be prompt-scoped handler swapping, which is policy.
- If exiting the alternate screen races the countdown's last render, the ensure order in
  `TTY#run` is pinned by spec — stop rather than reorder it.
- Trap context restrictions (no Mutex, no IO) — the queue push must be the only trap-body
  operation; if anything more creeps in, stop.

## Integration checks

1. Full suite green (`bundle exec rspec`), rubocop clean, `cargo test`/clippy untouched
   (no `ext/` changes allowed this chunk).
2. **Gem-install smoke** (T8's real target): `gem build && gem install` into a clean
   dir; `lain bench sweep -k 5` produces the HEAD-identical report; `lain chat --help`
   works.
3. **XDG smoke**: with `XDG_STATE_HOME` pointed at a tmpdir, a two-turn ollama chat
   (`--provider ollama`, per the local-smoke convention) writes
   `sessions/<hash>/<file>.ndjson` there, plus history; nothing new under `$HOME` or the
   repo except `.lain/` slots already present.
4. **Kill dance (manual, Joel)**: (a) `kill -9` mid-response → `lain chat --resume`
   reports the open session, salvages a complete frame if the stream had finished,
   surfaces the partial otherwise; (b) Ctrl-C → countdown renders, `c` cancels, `w`
   extends, second Ctrl-C exits immediately with terminal restored; (c) SIGTERM from
   another pane → countdown, expiry, clean exit, `session_closed` in the journal;
   (d) quit nvim mid-`--nvim` chat → chat keeps running (T1's blocker proven live).
5. **Compaction-retention invariant**: record a session with `Context::Compact` composed
   into the pipeline; verify the journal's turn records carry FULL uncompacted content,
   `--resume` reproduces the conversation, and the rendered request (the compacted view)
   differs — the log is lossless, the view is a view. (Automated as part of T13/T14
   specs plus one seam spec if the pipeline wiring needs it; call it out in review.)
6. ROADMAP updated: XDG conformance and resume items marked with this chunk; the
   `chunk-spine-agents-sweep-nvim.md` T23 residual-NIT line amended by T6.
