# Epic wiring, review intake, and serial landing

status: in-progress -- 25 of 26 cards landed (T20 deferred by ruling, T23 remaining).
        The 2026-07-30 resume's five body-less commits were panel-reviewed on
        2026-08-02, repaired, and the range rewritten one card per commit; see
        "The 2026-08-02 panel review" below.
commit-mode: orchestrator-commits
language: ruby (plus lua in lib/lain/frontend/neovim/runtime.lua)
panel: Torvalds, Evans, Metz, Schneeman, Patterson (ruby) with Kmett, Milewski, Wadler, Elliott, Matsakis (algebra/effects seats)

## Intent

The epic domain landed 2026-07-28/29 (chunk-epic-domain.md, all 13 cards) but nothing drives
it: no code constructs a gate, no artifact answers the gate duck, and no producer writes the
records the Progress fold reads. This chunk wires the domain, builds the review-intake flow
(lain writes a doc, the human edits and annotates it in nvim, a done signal turns the diff
and the annotations into journaled events, ownership returns to the agent), and gives
external work a journaled intent/outcome model with serial PR landing as the first consumer.
It also refreshes planning/epic-orchestration.md to match the repo.

Rulings from the 2026-07-30 interview: both design digs in one plan; annotations ride an
extmark side-channel (doc bytes stay clean); serial landing first, the stack cascade is a
follow-on chunk; repo-mode gitignore behavior stays as-is; writing-style.md governs new docs
only. Standing rulings recovered from the 2026-07-28 interview that cards must honor:
overnight deferral is scoped per stage, a deferred gate should attempt a spike before
parking (Policy::Adjudicated), skills stay thin because the abstractions live in lib, and
config lives in .lain/config.toml.

## Grounding

Verified 2026-07-30 against the working tree (three Explore passes plus a fact-check pass).

Epic domain, landed and load-bearing:
- `lib/lain/epic/` holds Issue (8-field frozen Data, `issue.rb:88`), Graph with `ready`
  (`graph.rb:278`), `waves` (`:288`), `split`/`merge`/`add` (`:299-319`), Document with all
  8 fields round-tripping (`document.rb:142-148`), Records with guards shared by write and
  read sides (`records.rb`), Progress.fold requiring `epic_slug:` (`progress.rb:242`), Home
  with two homes off `[epics] home` (`home.rb:71`).
- `Approval::Gate` (`gate.rb:169`), `GateDecision` (9 members, closed by design,
  `gate.rb:72-83`), policies Interactive/HandsOff/Deferred (`gate/policy.rb`), SignoffQueue
  as a fold over `gate_decision` records (`signoff_queue.rb:413`), Adjudicator built but
  constructed nowhere (`gate/adjudicator.rb`).
- CLI: `lain epic status` (`cli/epic.rb:169`), `lain epic queue|approve|deny`
  (`cli/epic_queue.rb`), multi-session journal discovery via `CLI::SessionJournals`
  (`cli/session_journals.rb:48`).

The unwired gaps this chunk exists to close:
- `Approval::Gate.new` and `Adjudicator.new` appear only in specs. No class in lib answers
  `#gate_question` (`gate.rb:256`). No policy selector exists (`PolicySwitch` is tier-3
  only). Nothing writes `issue_transition` or `stage_transition` records.
- The gate registry is process-local and add-only; rebuilding from the journal is named as
  a later card's job at `gate.rb:143-148`.
- The three skill templates state "no evidence is gathered and no model is asked" for
  deferred gates, pinned by `spec/lain/skill/shipped_skills_spec.rb:281-288`. Landing
  Adjudicated means editing all three templates and that spec together.
- `Epic::Home#read_epic` re-parses; nothing diffs disk against what lain wrote
  (`home.rb:115-132`), and `parse_markdown` accepts truncated input silently
  (chunk-epic-domain follow-up 7).

The substrate the intake flow reuses:
- `lain://compose` is the done-signal precedent: acwrite + BufWriteCmd, generation stamping
  (`compose.rb:223-233`, `runtime.lua:588-597`), rpcrequest-first ordering
  (`runtime.lua:651-676`).
- `RequestBuffer#resend` turns edited bytes into a journaled record with a recomputed digest
  (`request_buffer.rb:87-91`).
- `Workspace::Snapshot::Blob` content-addresses disk bytes and skips unchanged files
  (`snapshot.rb:60-79`, `:126-128`).
- Unclaimed `lain_command` verbs land in `command_inbox`; `HumanReplies#editor_reply_loop`
  is the consumer pattern (`human_replies.rb:135-143`). `PROTOCOL = "4"` is twinned at
  `neovim.rb:41` and `runtime.lua:15`. No extmark usage exists anywhere yet. No code opens
  a file in the user's editor.
- `Tools::AskHuman` holds one pending promise on an ivar; its class doc says a concurrent
  asker must carry promises on events instead (`ask_human.rb`).

The substrate the external-state model reuses:
- Effect/Handler is the description/execution split (`effect.rb`, `handler.rb:22-59`);
  `Recorded.from_journal` replays journal outcomes and declines misses (`recorded.rb:34`).
- The intent/ack/reconcile pattern ships once end to end: `JournalRequests` records intent
  before dispatch (`middleware/journal_requests.rb:30`), the response WAL spools observed
  bytes (`provider/response_wal.rb:89`), `SessionRecord::Salvage` reconciles after a crash
  as a pure function (`salvage.rb:64-141`).
- `Handback#preserve` is ref-first and idempotent by reachability (`handback.rb:20-25`,
  `:276-285`); `worker_handoff.rb:46-54` names the missing anchor-only op this chunk adds.
- Tier rule: approval hangs on whether the model controls the command string
  (`tool.rb:115-123`); argv executors are tier 2.
- `shell_out_factory:` is the uniform subprocess seam (8 sites, e.g. `worktree.rb:83`).
- GitHub docs (fetched 2026-07-30): rebase-and-merge always creates new SHAs and rewrites
  committer info. Serial landing avoids stack cascades entirely; the cascade chunk comes
  later.

Where the docs and code disagreed, the code won. planning/epic-orchestration.md §2.3/§3.9
describe as missing what chunk-epic-domain landed; T12 fixes the doc. Binding backlog from
chunk-epic-domain's follow-ups honored here: tickets 3 (T10), 4 and 5 (T9), 6 reshaped
(T21), 7 (T5 closes it structurally), 9 (T14). Tickets 1, 2, 8, 10 stay deferred and are
listed in the doc refresh.

## Orchestrator contract

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lib/lain/epic.rb`,
  `lib/lain/approval.rb`, `lib/lain/tools.rb`, `lib/lain/forge.rb` (T7 creates it; its
  require list is orchestrator-owned from then on), `exe/lain`, `lain.gemspec`,
  `.rubocop.yml` (never touched), `spec/spec_helper.rb`.
- The nvim runtime protocol constant is bumped exactly once this chunk, in T16 (4 to 5).
  T22 extends payloads of existing verbs only.
- T12 is docs-only: skip the code-probe review step; the panel reads the rendered doc.
- Lua cards (T16, T22) are reviewed by reading `runtime.lua` and running the headless specs
  (`spec/plugin/nvim_plugin_spec.rb`, `spec/lain/frontend/neovim_runtime_spec.rb`).

## Open decisions

None. Names decided here: the landing unit is `Lain::Forge`; the review lifecycle object is
`Epic::Review`; record type strings are named per card.

## Waves

- Wave 1: T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12
- Wave 2: T13 (←T8), T14 (←T2,T9), T15 (←T5,T6), T17 (←T7), T18 (←T7,T8),
  T19 (←T1,T2,T3,T4)
- Wave 3: T16 (←T15), T20 (←T8), T21 (←T4,T11), T24 (←T1,T3,T4,T7,T8,T17,T18)
- Wave 4: T22 (←T15,T16), T25 (←T24)
- Wave 5: T23 (←T6,T15,T16,T22)

Critical path: T5 → T15 → T16 → T22 → T23.

## Tasks

### T1 — Give every epic artifact a gate identity          [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/epic/submission.rb` (create), `spec/lain/epic/submission_spec.rb` (create)
**Reuse:** the gate duck (`#digest` + `#gate_question`, `approval/gate.rb:256,272`);
`Epic::Graph#digest` (`epic/graph.rb:324`); `Canonical.digest`; `Epic::Stage::STAGES`
(`epic/stage.rb:124`)
**Shared-file wiring:** require line in `lib/lain/epic.rb`

`Epic::Submission` is a frozen value binding an artifact to a stage: constructors
`Submission.research(text:, slug:)`, `.epic_plan(graph:, slug:)`, `.issue_plan(text:,
slug:, issue_id:)`, `.implementation(slug:, issue_id:, digest:)`. Prose artifacts digest
their bytes through `Canonical.digest`; `epic_plan` reuses the graph's own digest so an
approval survives reformatting that parses to the same graph. `#gate_question` names the
stage, the slug, and one concrete fact (issue count for epic_plan, byte size for prose).

```gherkin
Scenario: a submission answers the gate duck
  Given a Submission built from a 3-issue graph for slug "demo"
  When Approval::Gate#call runs with a pre-resolved approving surface
  Then ensure_approved! returns the graph digest
  And the journaled gate_decision carries stage "epic_plan" and slug "demo"

Scenario: reformatting does not move the epic_plan digest
  Given two markdown renderings that parse to the same graph
  Then their epic_plan submissions share one digest

Scenario: prose edits move the research digest
  Given research text and the same text with one word changed
  Then the two submissions have different digests
```
→ spec file: `spec/lain/epic/submission_spec.rb`

**Escalation triggers:**
- `GateDecision` is closed at 9 members (`gate.rb:72-78`). If a question needs data the
  record cannot carry, stop; do not widen the shape.
- If `gate_question` needs Home paths, stop: Submission must stay disk-free (pure value).

### T2 — Select gate policy per stage from config          [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/config.rb` (modify: `Config::Epics` gains `gates`),
`lib/lain/approval/gate/policies.rb` (create), `spec/lain/config_spec.rb` (modify),
`spec/lain/approval/gate/policies_spec.rb` (create)
**Reuse:** `Config::Epics` closed-table posture (`config.rb:71`, errors `NotATable`,
`UnknownKeys`); policy `NAME` constants (`gate/policy.rb:100,119,140`);
`Epic::Stage::STAGES`
**Shared-file wiring:** require line in `lib/lain/approval.rb`

`[epics.gates]` in `.lain/config.toml` maps stage names to policy names, for example
`epic_plan = "deferred"`. Unknown stages and unknown policy names are refused at load, the
`UnknownKeys` posture. Absent table means interactive everywhere. The factory takes its
collaborators as one dependencies value: `Gate::Policies.for(stage:, config:, deps:)`
where `deps` is a small frozen Data carrying `queue:`, `asker:`, `journal:`, and the
adjudication seams `role_spawn:` and `brief:` (both nil-able). Interactive, hands_off,
and deferred need only the first three. When config names a policy whose seams are nil in
`deps` (adjudicated without a `role_spawn`, T14), the factory refuses loudly, naming the
stage, the policy, and the missing seam. The policy name set this card accepts is
interactive, hands_off, deferred; T14 widens it by one.

```gherkin
Scenario: per-stage policies resolve from config
  Given config with gates research = "hands_off" and epic_plan = "deferred"
  Then Policies.for stage "research" is a HandsOff
  And Policies.for stage "epic_plan" is a Deferred holding the injected queue
  And Policies.for stage "issue_plan" is Interactive by default

Scenario: a typo in a stage name refuses at load
  Given config with gates reserch = "deferred"
  Then Config.load raises naming the unknown key

Scenario: a policy missing its seams refuses with a name
  Given deps whose role_spawn is nil and config naming a policy that needs one
  Then Policies.for raises naming the stage, the policy, and role_spawn
```
→ spec files: `spec/lain/config_spec.rb`, `spec/lain/approval/gate/policies_spec.rb`

**Escalation triggers:**
- The TOML key precedent is short names (`home`, not `epics_home`; chunk-epic-domain
  deviation). If the schema fights the existing `Config::Epics` shape, stop.
- If the factory needs a live reactor at construction time, the seam is wrong; stop. A
  journal in `deps` is expected (policies journal decisions); a reactor is not.

### T3 — Rebuild the gate registry from the journal        [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/approval/gate.rb` (modify), `spec/lain/approval/gate_spec.rb` (modify)
**Reuse:** `SignoffQueue.from_journal` fold shape (`signoff_queue.rb:413`);
`Journal.records(entries, type:)` (`journal.rb:140`); the registry comment naming this as
future work (`gate.rb:143-148`)
**Shared-file wiring:** none

`Approval::Gate.from_journal(entries, journal:, timeout:, clock:)` folds `gate_decision`
records and registers every approved digest, then behaves as a normal Gate. Denials
register nothing (the registry is add-only and approval-only, unchanged semantics). This is
what lets a day-two process answer `#approved?` for day-one approvals.

```gherkin
Scenario: approvals survive a restart
  Given a journal holding an approved gate_decision for digest D and a denied one for E
  When a Gate is rebuilt with from_journal
  Then approved?(D) is true and approved?(E) is false
  And ensure_approved! on an artifact with digest D returns D

Scenario: foreign record types are skipped
  Given a journal holding turn_usage and doc_written records between gate_decisions
  Then from_journal folds without raising
```
→ spec file: `spec/lain/approval/gate_spec.rb`

**Escalation triggers:**
- `gate.rb:143-148` documents process-locality as deliberate-for-now. Rewrite that comment
  as part of this card; if any existing spec pins non-persistence, amend it in the same
  commit and say so in the handoff.
- If fold order could matter (approve then deny of one digest), stop: that means the
  registry semantics changed somewhere.

### T4 — One writer for epic transition records            [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/epic/scribe.rb` (create), `spec/lain/epic/scribe_spec.rb` (create)
**Reuse:** `Epic::IssueTransition` / `Epic::StageTransition` and their guards
(`epic/records.rb:25-113`); `Telemetry::Journalable`; `Progress.fold`
(`epic/progress.rb:242`) as the read-side oracle
**Shared-file wiring:** require line in `lib/lain/epic.rb`

`Epic::Scribe.new(epic_slug:, journal:)` owns the write side the fold has been waiting for:
`#stage_started(stage)`, `#stage_completed(stage)`, `#issue_moved(id, from:, to:)`. Guards
refuse before anything reaches the journal. Nothing else in lib may construct these records
(the fold's `ForeignJournal` and guard re-checks stay the only read-side defense).

```gherkin
Scenario: the fold sees what the scribe writes
  Given a 2-issue graph and a scribe for slug "demo"
  When issue_moved marks issue "a" from pending to done and stage_started marks issue_plan
  Then Progress.fold over the journaled records reports stage issue_plan
  And ready contains the issue that "a" was blocking

Scenario: a bad status never reaches the journal
  When issue_moved is called with to_status "finished"
  Then it raises before the journal receives anything
```
→ spec file: `spec/lain/epic/scribe_spec.rb`

**Escalation triggers:**
- If `Progress.fold` refuses a record the write-side guards accepted, the shared-guard
  contract broke (ticket 8 territory): stop, do not patch either side alone.
- A `completed` event advances nothing by design (`progress.rb:187`); if a caller seems to
  need completed-implies-next-started, that logic belongs in T19, not here.

### T5 — Compute the intake delta between written and disk [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/epic/intake.rb` (create), `spec/lain/epic/intake_spec.rb` (create)
**Reuse:** `Epic::Document.parse_markdown` / `.to_markdown` (`document.rb:142-148`);
`Epic::Graph#digest`, `Epic::Issue#digest`; `Canonical.digest` for byte digests;
`Buffers#unified_diff` shape as prior art only (`neovim/buffers.rb:280-320`)
**Shared-file wiring:** require line in `lib/lain/epic.rb`

`Epic::Intake.diff(written:, disk:)` is a pure function: `written` carries the bytes and
graph lain last wrote, `disk` the bytes found at settle time. It returns a frozen
`Intake::Delta`: byte digests both sides, `#byte_identical?`, and a structural account
built from parsing disk (issues added, removed, retitled, redescribed, edges changed,
status marks changed, criteria changed), each keyed by issue id. A disk parse failure
returns `Delta.malformed(error)` rather than raising. Mass disappearance (parsed ids lose
more than half of written ids) sets `#lossy?`, which is how a silently truncated file
stops masquerading as an intentional edit (closes follow-up 7 structurally). `lossy?` is
advisory, a suspicion and never a verdict: a legitimate mass edit trips it too, so
consumers render it as "possibly truncated" and ask, they do not assert truncation.

```gherkin
Scenario: a whitespace-only edit is byte change without structural change
  Given a written graph and disk bytes that differ only in trailing spaces
  Then the delta is not byte_identical and its structural account is empty

Scenario: a retitle is attributed to its issue
  Given disk bytes where issue "b" has a new title
  Then the delta lists "b" under retitled and nothing else

Scenario: a truncated file reads as lossy, never as clean removals
  Given disk bytes cut off after the first of four issues
  Then the delta lists three removals and lossy? is true

Scenario: unparseable disk bytes are a malformed delta
  Given disk bytes with a corrupt heading line
  Then the delta is malformed and carries the parse error
```
→ spec file: `spec/lain/epic/intake_spec.rb`

**Escalation triggers:**
- `Document` drops preamble prose by design (`document.rb:249`). Preamble edits count in
  the byte diff only; if a scenario needs preamble attribution, stop.
- If detecting an edge change needs Document internals (Reader/Draft are private), stop;
  the public parse must suffice.

### T6 — Journal every artifact write with its digest      [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/epic/home/journaled.rb` (create), `lib/lain/epic/records.rb` (modify:
add `DocWritten`), `spec/lain/epic/home/journaled_spec.rb` (create)
**Reuse:** `Isolation::Journal` decorator shape and its ordering rule (`isolation/
journal.rb:56-60`); `Epic::Home` duck (`home.rb:104-132`); `Telemetry::Journalable`
**Shared-file wiring:** require line in `lib/lain/epic.rb`

`Epic::Home::Journaled.new(home, journal:, reviews: Reviews::Null)` answers the Home duck
and journals `doc_written` after each successful write: slug, relative path, byte digest,
kind (research, epic, issue, plan), and the graph digest when the write was `write_epic`.
Write first, journal second, so a refused write never journals: `doc_written` is an
observation of a completed write, an ack and never an intent, which is why its ordering
is the opposite of T7's intent-before-effect rule (do not "fix" it into intent-first).
The `reviews:` seam is a
duck answering `#open?(path)`; when a review is open for the path, the write refuses
(`ReviewPending` error). The default `Reviews::Null` never refuses; T15 provides the real
implementation and T23 wires it. This is the regeneration guard: lain cannot overwrite a
doc the human is mid-review on.

```gherkin
Scenario: write_epic journals bytes and graph digests
  When write_epic lands a 2-issue graph
  Then a doc_written record carries kind "epic", the byte digest, and the graph digest

Scenario: a refused write journals nothing
  Given a graph holding an issue the Writer refuses to emit
  Then write_epic raises and the journal holds no doc_written

Scenario: an open review blocks regeneration
  Given a reviews seam reporting open? true for the epic path
  Then write_epic raises ReviewPending and the file is untouched
```
→ spec file: `spec/lain/epic/home/journaled_spec.rb`

**Escalation triggers:**
- `Home.new` and `Home.[]` are private (`home.rb:267`). The decorator wraps an instance
  from `Home.resolve`; if it needs the constructor, stop.
- Atomic-write behavior (`home.rb:251-258`) must be observable through the decorator
  unchanged; if the decorator has to reimplement any write mechanics, the seam is wrong.
- `doc_written` is slug-bearing. If `Progress`'s `refuse_foreign_journal!` needs it in
  `SLUG_TYPES` (`progress.rb:79`), make that edit deliberate and say so in the handoff
  (same trigger as T15).

### T7 — Journaled intents and a reconcile fold for external effects [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/forge.rb` (create: unit index), `lib/lain/forge/intent.rb` (create),
`lib/lain/forge/reconcile.rb` (create), `spec/lain/forge/intent_spec.rb`,
`spec/lain/forge/reconcile_spec.rb` (create)
**Reuse:** `JournalRequests` intent-before-dispatch (`middleware/journal_requests.rb:30`);
`SessionRecord::Salvage` as the reconcile shape, pure function over injected ducks
(`salvage.rb:64-141`); `Telemetry::Journalable`; `Journal.records`
**Shared-file wiring:** require line for `forge.rb` in `lib/lain.rb` (placed after epic)

Two records and one fold. `Forge::Intent` (type `forge_intent`): intent_id (digest of
action plus params), action from the closed set `promote pr_create pr_merge` (exactly
what T24 uses; promotion is the push, a separate push action would be speculative),
epic_slug, issue_id, params. `Forge::Outcome` (type `forge_outcome`): intent_id, ok,
observed, detail. Pairing law: an outcome settles the first unmatched intent with its
intent_id in journal order, so repeated identical actions (T18 allows re-promotion of the
same sha) pair positionally; an outcome with no unmatched intent is named by the fold as
an orphan, never dropped. `Forge::Reconcile.new(entries:, world:)` answers `#settled`,
`#unsettled`, `#orphans`, and for each unsettled asks the injected `world` duck
(`#ref_exists?`, `#sha_of`, `#pr_state`, and `#pr_for(head:)` so a crashed `pr_create`
with no recorded number is still observable) whether the action already happened,
returning `completed_externally` or `needs_retry` per intent. Reconcile is a pure
function and idempotent: same entries, same world, same report. Idempotency of the
actions themselves is asked of the world by observation, never remembered (the
`Handback#preserve` and `Salvage#already_committed?` doctrine).

```gherkin
Scenario: an intent without an outcome is unsettled
  Given a journal with a push intent and no outcome
  Then reconcile lists it unsettled

Scenario: the world settles a crashed push
  Given an unsettled push intent whose ref the world reports at the pushed sha
  Then reconcile marks it completed_externally

Scenario: a missing ref means retry
  Given an unsettled promote intent whose ref the world reports absent
  Then reconcile marks it needs_retry

Scenario: repeated identical intents pair positionally
  Given two identical promote intents and one outcome
  Then the first intent is settled and the second is unsettled

Scenario: an orphan outcome is named, never dropped
  Given an outcome whose intent_id matches no unmatched intent
  Then reconcile lists it under orphans

Scenario: reconcile is idempotent
  Given any entries and a fixed world
  Then running reconcile twice yields equal reports

Scenario: a crashed pr_create is observable by head ref
  Given an unsettled pr_create intent and a world whose pr_for(head:) reports the PR
  Then reconcile marks it completed_externally
```
→ spec files: `spec/lain/forge/intent_spec.rb`, `spec/lain/forge/reconcile_spec.rb`

**Escalation triggers:**
- The action set is closed on purpose. If a scenario wants a free-form action string, stop;
  that is the tier-3 shape this design exists to avoid.
- `SessionJournals` ordering depends on fixed-width `iso8601(6)` timestamps
  (`session_journals.rb:19-42`); Forge records ride the same journals and owe the same
  format via `Journal#record`. If a record needs its own clock, stop.

### T8 — Anchor a worker ref without merging               [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/isolation/worktree/handback.rb` (modify),
`lib/lain/isolation/worker_handoff.rb` (modify),
`spec/lain/isolation/worktree/handback_spec.rb` (modify),
`spec/lain/isolation/worker_handoff_spec.rb` (modify)
**Reuse:** `Handback#preserve` (`handback.rb:276-285`); the gap statement at
`worker_handoff.rb:46-54`; `Outcome::KINDS` (`handback.rb:115`)
**Shared-file wiring:** none

`Handback#anchor(lease, worker_id:)`: rev-parse the worker HEAD, `update-ref` it under
`refs/lain/worker/`, merge nothing, return an Outcome. Idempotent, no working-tree state
touched, safe to call from an `ensure`. `WorkerHandoff#complete` calls it inside its
`ensure` so a raise mid-`call` can no longer reclaim a worktree whose commits were never
anchored. Rewrite the `worker_handoff.rb:46-54` comment to state the closed guarantee.

```gherkin
Scenario: a raise mid-handback no longer loses commits
  Given a worker lease holding one commit and a handback whose merge raises
  When WorkerHandoff#reclaim runs
  Then refs/lain/worker/<key> points at the worker commit
  And the lease is released

Scenario: anchor is idempotent
  When anchor runs twice for the same lease
  Then the second call returns nothing_to_do and the ref is unchanged

Scenario: an empty worktree anchors nothing
  Given a lease with no commits beyond the fork point
  Then anchor returns nothing_to_do and writes no ref
```
→ spec files: `spec/lain/isolation/worktree/handback_spec.rb`,
`spec/lain/isolation/worker_handoff_spec.rb`

**Escalation triggers:**
- `Outcome::KINDS` is a closed set. If anchor needs a kind outside it, stop.
- `ensure` blocks here must survive `Exception`, not just `StandardError`
  (`worker_handoff.rb:29-34`); if the anchor path can raise inside the ensure, the retry
  must be bounded. Anything unbounded: stop.

### T9 — One boundary check and a shared terminal guard    [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/approval/gate/adjudicator.rb` (modify),
`lib/lain/approval/gate/policy.rb` (modify),
`spec/lain/approval/gate/adjudicator_spec.rb` (modify),
`spec/lain/approval/gate/policy_spec.rb` (modify)
**Reuse:** chunk-epic-domain follow-ups 4 and 5; `Epic::Stage#ensure_open!`
(`stage.rb:204`); `Gate#approved?`
**Shared-file wiring:** none

Two recorded defects, one card. First: `ensure_open!` is called in both `Policy#decide`
(`policy.rb:55`) and `Adjudicator#call` (`adjudicator.rb`); collapse to one owner so the
boundary rule has a single call site. Second: `Adjudicator::AlreadyDecided` guards a
per-instance ivar, so a second Adjudicator over the same Gate can re-adjudicate and
journal a deny while `Gate#approved?` stays true. The add-only approval registry cannot
answer "was this decided", only "was this approved" (a terminal deny is invisible to it),
so the decided-check folds journaled `gate_decision` records whose policy is
`TERMINAL_POLICY` ("adjudicated"): approved or denied, a terminal adjudication for a
digest refuses any second one. This closes both directions, including the unattended
ratchet where re-running after a terminal deny could eventually approve.

```gherkin
Scenario: two adjudicators cannot disagree about one artifact
  Given a Gate that already approved digest D via adjudication
  When a second Adjudicator is asked about the same artifact
  Then it refuses with AlreadyDecided and journals nothing

Scenario: a terminal deny is also terminal
  Given a journaled adjudicated deny for digest D
  When a second Adjudicator is asked about the same artifact
  Then it refuses with AlreadyDecided and no new gate_decision lands

Scenario: the stage boundary is checked exactly once per decision
  Given a queue with a parked item in the preceding stage
  When an adjudicated decide runs
  Then StageBlocked is raised before any spike is spawned
```
→ spec files: `spec/lain/approval/gate/adjudicator_spec.rb`,
`spec/lain/approval/gate/policy_spec.rb`

**Escalation triggers:**
- If collapsing the call sites changes the journaled `gate_decision` or `gate_evidence`
  shapes in any way, stop: both are closed.
- T14 builds directly on this card; if the refactor wants to rename public methods on
  Policy, stop (T14's diff would collide).

### T10 — Emittability lives on the issue                  [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/epic/issue.rb` (modify), `lib/lain/epic/document.rb` (modify:
Writer consults the predicate), `lib/lain/epic/home.rb` (modify: name grammar readable),
`spec/lain/epic/issue_spec.rb` (modify), `spec/lain/epic/document_spec.rb` (modify)
**Reuse:** chunk-epic-domain follow-up 3; `Home::NAME` (`home.rb:37`); Writer refusal
behavior (`document.rb:373`)
**Shared-file wiring:** none

`Issue#emittable?` and `#emittable_failures` answer for both downstream grammars: the
document grammar (what Writer refuses) and the filesystem grammar (what `Home.checked_name`
refuses for `issues/<id>.md`). `Document::Writer` and `Home` consult the predicate rather
than keeping private copies of the rules, so a graph operation that mints an un-renderable
issue is detectable at the value, before a render or a write raises at a distance.

```gherkin
Scenario: a filesystem-hostile id is named at the issue
  Given an issue whose id is valid for the document grammar and invalid for Home::NAME
  Then emittable? is false and emittable_failures names the filesystem grammar

Scenario: Writer and the predicate agree
  Given any issue where emittable? is true
  Then Writer emits it without raising
```
→ spec files: `spec/lain/epic/issue_spec.rb`, `spec/lain/epic/document_spec.rb`

**Escalation triggers:**
- `issue.rb` and `document.rb` are mutation-tested, landed files. If the predicate needs a
  constant moved between units, stop and hand the move to the orchestrator as wiring.
- Do not make `split`/`merge` refuse un-emittable results; that behavior change belongs to
  a future card if the panel wants it.

### T11 — Property tests for the graph's scheduling laws   [wave 1] [risk: low]

**Depends on:** none
**Files:** `spec/lain/epic/graph_laws_spec.rb` (create)
**Reuse:** generator style from `spec/support/algebra_generators.rb`; `Epic::Graph`
public API only
**Shared-file wiring:** none

The §3.10 results as executable laws over generated graphs: `ready` is monotone under
landings (marking any ready issue done never removes another issue from ready); `ready`
is deliberately not monotone under graph edits (a fixed, constructed witness where an
`add(discovered_from:)` un-readies an issue; existence claims over random graphs are
flaky by construction, so the exhibit is deterministic); waves partition the issue set
(disjoint, exhaustive) and each wave is an antichain (no `blocks` edge within one);
`split` and `merge` preserve acyclicity, never dangle edges, and preserve blocking
reachability (whoever waited on the whole waits on every part, the Revision doc's own
claim, `graph.rb:177`).

```gherkin
Scenario: landings only grow the ready set
  Given 50 generated acyclic graphs
  When any ready issue is marked done
  Then every previously ready issue is still ready

Scenario: a discovered_from addition may shrink the ready set
  Given the constructed witness graph
  When an issue is added with discovered_from blocking a ready issue
  Then that issue leaves the ready set

Scenario: waves partition and reachability survives revisions
  Given 50 generated acyclic graphs
  Then waves are disjoint, exhaustive, and antichains
  And after any split or merge every former transitive blocker still blocks
```
→ spec file: `spec/lain/epic/graph_laws_spec.rb`

**Escalation triggers:**
- A failing law is a Graph bug, not a spec bug: stop and report; never weaken the law.
- These laws do not belong in the Algebra registry (its `STRUCTURES` set has no scheduling
  entry); if registration seems needed, stop rather than widen `STRUCTURES`.

### T12 — Refresh the epic orchestration research doc      [wave 1] [risk: low]

**Depends on:** none
**Files:** `planning/epic-orchestration.md` (modify)
**Reuse:** the 2026-07-30 critique (`.critique-epic-orchestration.md`); this plan's
Grounding section; GitHub merge-method docs quoted there
**Shared-file wiring:** none

Content-only refresh, existing prose style grandfathered. Adds a dated addendum: per-chunk
status against §3.9 (domain landed, this chunk in flight, cascade and bench chunks
pending); corrects §2.2's claim that rebase-merge avoids the squash trap (GitHub always
rewrites SHAs; the cascade cost is real under every button method and serial landing is
the v1 answer); records the interview rulings (extmark annotations, ownership baton,
serial-first, repo-mode gitignore as-is, overnight deferral scoped per stage, spike-first
deferral); replaces §2.3's Missing list with the true remaining-gap list; corrects the
aws-sdk-core gemspec claim, the TMPDIR reaping claim, and flags the Linear rate-limit
figure as unverified; lists deferred follow-ups (tickets 1, 2, 8, 10) so they are not lost.

```gherkin
Scenario: the doc stops contradicting the repo
  Then no section describes Epic::Graph, Approval::Gate, or the epic skills as missing
  And the squash-trap paragraph states that GitHub rebase-merge rewrites SHAs
  And an addendum dated 2026-07-30 records the interview rulings
```
→ verified by orchestrator read (docs-only deviation recorded in the contract)

**Escalation triggers:**
- If a correction would change a decision this plan builds on (not just describe it),
  stop: the plan is the ruling, the doc records it.

### T13 — Reap a crashed worker's worktree without losing its commits [wave 2] [risk: medium]

**Depends on:** T8
**Files:** `lib/lain/supervisor.rb` (modify), `spec/lain/supervisor_spec.rb` (modify)
**Reuse:** chunk-orchestration-arms-isolation B5 follow-up (crashed-worker worktrees
persist until `#stop`); `Supervisor::Restart` (`supervisor/restart.rb:39`);
`WorkerHandoff#surrender` (`worker_handoff.rb:245`: anchor, release, spawn nothing);
ref-first doctrine (`worker_handoff.rb:36-44`)
**Shared-file wiring:** none

`Supervisor::Restart` takes a new worker_id, so the dead worker's lease leaks until
`#stop`. A bare lease release would be worse: reclaim destroys the checkout, and a
crashed worker is exactly the one likely to hold unmerged commits. On restart, route the
dead worker through `WorkerHandoff#surrender` (anchored under `refs/lain/worker/`, lease
released, no resolver spawned), before the replacement adopts. A multi-day epic run must
not accumulate one orphan worktree per crash, and must not pay for the cleanup with a
worker's commits.

```gherkin
Scenario: restart surrenders the dead worker's lease
  Given an adopted worker whose actor dies holding one committed change
  When Restart replays it under a new worker_id
  Then the dead worker's worktree directory is gone
  And the commit is reachable via refs/lain/worker/
  And the replacement holds a fresh lease

Scenario: stop still reaps everything
  Then #stop after a restart leaves no lain-owned worktrees
```
→ spec file: `spec/lain/supervisor_spec.rb`

**Escalation triggers:**
- If the supervisor's restart path has no handle on a `WorkerHandoff` (it may only hold
  the isolation backend), stop and hand the wiring question to the orchestrator; do not
  fall back to a bare release.
- The Worktree monitor serializes acquire/reap; if the fix needs to touch that
  serialization, stop.

### T14 — Deferred gates spike before parking              [wave 2] [risk: medium]

**Depends on:** T2, T9
**Files:** `lib/lain/approval/gate/policy.rb` (modify: add `Adjudicated`),
`lib/lain/approval/gate/policies.rb` (modify: accept the name),
`lib/lain/prompt/templates/skill/research-epic/skill.md`,
`lib/lain/prompt/templates/skill/plan-epic/skill.md`,
`lib/lain/prompt/templates/skill/create-epic-issues/skill.md` (modify: the deferred
sentence), `spec/lain/skill/shipped_skills_spec.rb` (modify: the pinned assertion),
`spec/lain/approval/gate/policy_spec.rb` (modify)
**Reuse:** `Adjudicator` (`gate/adjudicator.rb:58`, spike → adjudicate → settle or park);
`gate_adjudicator` role (`role/catalog.rb:37`); chunk-epic-domain follow-up 9
**Shared-file wiring:** none

`Policy::Adjudicated` wraps the Adjudicator as a first-class policy: on decide, run the
read-only spike, let the adjudicator approve, deny, or park with evidence. It is
constructed through T2's `deps` value (`role_spawn:` and `brief:` filled); the factory's
missing-seam refusal from T2 is what a bare context hits. This is the recorded interview
intent for overnight runs: try to answer your own question before parking it for the
morning queue. The three skill templates currently promise the opposite in a sentence
pinned by `shipped_skills_spec.rb:281-288`; template edits and the spec change land in
this card together.

```gherkin
Scenario: a spiked deferral parks with evidence
  Given an Adjudicated policy whose spike returns findings and whose verdict is defer
  When decide runs
  Then the parked item carries an evidence_digest
  And a gate_evidence record is journaled

Scenario: an adjudicator approval opens the gate
  Given a spike whose verdict is approve
  Then decide returns true and the gate registers the digest with policy "adjudicated"

Scenario: the templates and the policy agree
  Then no shipped template claims deferred gathers no evidence
```
→ spec files: `spec/lain/approval/gate/policy_spec.rb`,
`spec/lain/skill/shipped_skills_spec.rb`

**Escalation triggers:**
- The `gate_adjudicator` role's only-set is read-only file tools. If the spike needs
  anything wider, stop; widening an attenuation set is a human decision.
- If `Deferred` and `Adjudicated` start sharing more than the queue seam, resist merging
  them: plain Deferred remains the no-model-spend policy and both stay selectable (T2).

### T15 — A review parks on its own promise                [wave 2] [risk: high]

**Depends on:** T5, T6
**Files:** `lib/lain/epic/review.rb` (create), `lib/lain/epic/records.rb` (modify: add
`ReviewOpened`, `ReviewClosed`), `spec/lain/epic/review_spec.rb` (create)
**Reuse:** `Lain::Promise` (`promise.rb`); generation stamping (`compose.rb:223-233`);
`Epic::Intake` (T5); the promises-on-events instruction in `ask_human.rb`'s class doc;
`SignoffQueue.from_journal` fold shape
**Shared-file wiring:** require line in `lib/lain/epic.rb`

`Epic::Review` owns the ownership baton. `#open(path:, written:)` journals `review_opened`
(slug, path, written byte and graph digests, generation) and returns a generation token
with a fresh Promise held per generation, never on a shared ivar (this is the concurrent
asker the AskHuman doc says must carry promises on events). `#settle(generation, disk:)`
computes the T5 delta, journals `review_closed` (generation, both digests, structural
summary, lossy flag), resolves that generation's promise with the delta. Unknown and
already-settled generations refuse. A known-open generation holding no promise (the
restart case: `from_journal` rebuilds state, never promises) settles normally, journals
`review_closed`, and resolves nothing; refusing there would wedge the review forever.
At most one review per path: `#open` refuses while `#open?(path)` is true, so a second
opener cannot shadow the first generation. `Review.from_journal` rebuilds the open set
so a restarted process knows a review is pending (rendering that in `lain epic status`
is a named follow-up, not this chunk).

```gherkin
Scenario: settle resolves exactly its own generation
  Given two reviews open for different paths
  When the second is settled with edited disk bytes
  Then the second promise resolves with a delta and the first stays pending

Scenario: a stale settle refuses
  Given a review settled once
  When settle runs again with the same generation
  Then it refuses and no second review_closed is journaled

Scenario: an open review survives a restart as state
  Given a journal holding review_opened without review_closed
  Then Review.from_journal reports open? true for that path

Scenario: settling a rebuilt review does not wedge
  Given a Review rebuilt from journal with an open, promiseless generation
  When settle runs with disk bytes
  Then review_closed is journaled and no promise resolution is attempted

Scenario: one review per path
  Given an open review for the epic path
  When open runs again for the same path
  Then it refuses and no second review_opened is journaled

Scenario: the baton blocks regeneration while open
  Given a Journaled home wired to this review
  Then write_epic on the reviewed path raises ReviewPending until settle
```
→ spec file: `spec/lain/epic/review_spec.rb`

**Escalation triggers:**
- `Promise#await` parks a fiber and needs a reactor (`gate.rb` raises NoReactor for the
  same reason). If any path here would block a bare thread, stop.
- Records land through the same journal the epic folds read; if `Progress`'s
  `refuse_foreign_journal!` trips on the new types, the SLUG_TYPES list needs the
  addition; make that edit deliberate, not incidental.
- Cross-restart promise revival is out of scope: from_journal rebuilds state, never
  promises. If a scenario seems to need a promise surviving a process, stop.

### T16 — Open a review in the attached editor, settle on done [wave 3] [risk: medium]

**Depends on:** T15
**Files:** `lib/lain/frontend/neovim/runtime.lua` (modify),
`lib/lain/frontend/neovim/rpc_thread.rb` (modify),
`lib/lain/frontend/neovim.rb` (modify),
`lib/lain/cli/human_replies.rb` (modify),
`plugin/nvim/doc/lain.txt` (modify),
`spec/lain/frontend/neovim_runtime_spec.rb`, `spec/lain/frontend/neovim/rpc_thread_spec.rb`,
`spec/lain/cli/human_replies_spec.rb`, `spec/plugin/nvim_plugin_spec.rb` (modify)
**Reuse:** the `SET_COMPOSE` render-snippet precedent (`rpc_thread.rb:34`,
`runtime.lua:588-597`); `agent_command` shape (`runtime.lua:622-626`); the
`command_inbox` consumer loop (`human_replies.rb:135-143`); protocol twins
(`neovim.rb:41`, `runtime.lua:15`)
**Shared-file wiring:** none

The editor surface for T15. A new `_G.__lain.open_review(path, generation)` render entry
point opens the real file in a split (taking focus, like compose) and stamps
`b:lain_review_generation`. A new `:LainReviewDone` command refuses on a modified buffer
(unsaved edits are not a settled review), then sends `["review_done", [generation]]` down
the existing `lain_command` rail. `HumanReplies#editor_reply_loop` gains the verb and
calls the bound review's settle with the disk bytes. A settle refused Ruby-side (stale
generation, no open review) must not die silently in the consumer loop's drop-the-verb
pattern: the refusal is journaled and surfaced to the editor (echo via the existing
render rail) so the human's done gesture always gets an answer. `PROTOCOL` and
`RUNTIME_PROTOCOL` bump 4 to 5 together; `doc/lain.txt` documents the command (the
plugin spec pins doc mentions).

```gherkin
Scenario: done settles the review with what is on disk
  Given an open review and the file edited and saved in headless nvim
  When :LainReviewDone runs
  Then the review's promise resolves with a delta reflecting the saved edit

Scenario: an unsaved buffer refuses to signal done
  Given the review buffer has unsaved modifications
  When :LainReviewDone runs
  Then the command aborts with a message and no verb is sent

Scenario: a refused done gets an answer
  Given no review is open
  When :LainReviewDone sends a stale generation
  Then the human sees a refusal message in the editor
  And nothing is journaled as review_closed

Scenario: protocol twins stay in lockstep
  Then PROTOCOL and RUNTIME_PROTOCOL both read "5"
```
→ spec files: `spec/lain/frontend/neovim_runtime_spec.rb`,
`spec/lain/cli/human_replies_spec.rb`, `spec/plugin/nvim_plugin_spec.rb`

**Escalation triggers:**
- All buffer and RPC logic goes in `runtime.lua`; the plugin-side grep spec
  (`nvim_plugin_spec.rb:232-242`) fails the build otherwise. If the flow seems to need
  plugin-side code, stop.
- This is the chunk's one protocol bump. If the wire shape proves insufficient here,
  redesign the payload now; T22 may only extend this verb's payload.
- `:wall` and autosave fire writes without human intent (`runtime.lua:407-414`); done is
  the explicit command, never a write autocmd. If a reviewer asks for save-is-done, stop:
  that was compose's contract, this flow decouples saving from settling.

### T17 — A gh executor pair held to one contract          [wave 2] [risk: medium]

**Depends on:** T7
**Files:** `lib/lain/forge/gh.rb` (create), `lib/lain/forge/gh/recorded.rb` (create),
`lib/lain/forge/journaled.rb` (create),
`spec/support/shared_examples/gh_parity.rb` (create),
`spec/lain/forge/gh_spec.rb`, `spec/lain/forge/gh/recorded_spec.rb`,
`spec/lain/forge/journaled_spec.rb` (create)
**Reuse:** `shell_out_factory:` seam (`worktree.rb:83` and 7 siblings);
`Effect::Handler::Recorded` decline-on-miss doctrine (`recorded.rb:24-47`); parity via
shared example group (`spec/support/shared_examples/exec_boundary_parity.rb:32`);
`Isolation::Journal` decorator ordering
**Shared-file wiring:** require lines in `lib/lain/forge.rb`

`Forge::Gh` executes a closed verb set as argv arrays through an injected
`shell_out_factory`: `pr_create(base:, head:, title:, body:)`, `pr_view(ref:, fields:)`,
`pr_merge(number:, auto:)`, `merge_state(number:)` with a bounded UNKNOWN retry (GitHub
computes mergeability lazily; querying schedules it). The retry waits through an
injected sleeper/clock seam so specs never sleep real seconds. Never `sh -c`, never a
model-built string: tier 2 by construction. `Forge::Gh::Recorded` replays journaled outcomes keyed by
intent_id and declines misses. `Forge::Journaled` wraps either executor: `forge_intent`
before invoke, `forge_outcome` after, the T7 records. A shared example group holds Live
and Recorded to one contract.

```gherkin
Scenario: both executors satisfy the parity group
  Then Forge::Gh and Forge::Gh::Recorded pass the shared gh contract examples

Scenario: intent lands before the subprocess runs
  Given a journaled executor whose subprocess raises
  Then the journal holds the forge_intent and an outcome with ok false

Scenario: UNKNOWN merge state retries a bounded number of times
  Given gh returning UNKNOWN twice then CLEAN
  Then merge_state answers CLEAN after three polls
  And gh returning UNKNOWN forever answers UNKNOWN after the bound
```
→ spec files: `spec/lain/forge/gh_spec.rb`, `spec/lain/forge/gh/recorded_spec.rb`,
`spec/lain/forge/journaled_spec.rb`

**Escalation triggers:**
- No verb here may take a raw command string; if a needed gh capability does not fit an
  argv verb, stop.
- `gh` output shapes vary by version; the executor returns structured errors, never raw
  parse exceptions. If a field this chunk needs is missing from the installed gh, stop
  and name the minimum version.

### T18 — Promote an anchored ref to a pushed epic branch  [wave 2] [risk: medium]

**Depends on:** T7, T8
**Files:** `lib/lain/forge/promotion.rb` (create), `spec/lain/forge/promotion_spec.rb`
(create)
**Reuse:** `Handback::REF_NAMESPACE` and ref naming (`handback.rb:53,397`); the push
refspec form `git push origin <sha>:refs/heads/...` (no local branch needed);
`Home.checked_name` grammar for slugs; T7 records via `Forge::Journaled`
**Shared-file wiring:** require line in `lib/lain/forge.rb`

`Forge::Promotion` takes an anchored sha, an epic slug, and an issue id, and pushes
`refs/heads/epic/<slug>/<issue-id>` on the remote via the refspec form. Validation before
any subprocess: slug and issue id through the name grammar, the composed ref through
`git check-ref-format`, and a directory/file conflict check (an existing `epic/<slug>`
branch makes the namespaced name impossible). Re-promotion of the same sha is ok (observed,
not forced); a different sha refuses (no force in this chunk). Runs under the journaled
executor so every promotion is an intent/outcome pair.

```gherkin
Scenario: promotion pushes without a local branch
  Given a fixture repo with a local bare remote and an anchored commit
  When promotion runs for slug "demo" issue "a1"
  Then the remote has refs/heads/epic/demo/a1 at the anchored sha
  And no local branch was created

Scenario: promotion is idempotent by observation
  When promotion runs twice for the same sha
  Then the second outcome is ok and no force flag was used

Scenario: a diverged remote branch refuses
  Given the remote branch already at a different sha
  Then promotion refuses and the outcome says diverged
```
→ spec file: `spec/lain/forge/promotion_spec.rb`

**Escalation triggers:**
- If any path here wants `--force` or `--force-with-lease`, stop: force semantics belong
  to the cascade chunk.
- Fixture repos must run with the `GIT_CONTEXT_SCRUB` environment (`worktree.rb:56`);
  a spec passing only outside a git hook context is the trap to check for.

### T19 — Submit a stage artifact to its gate from the CLI [wave 2] [risk: medium]

**Depends on:** T1, T2, T3, T4
**Files:** `lib/lain/cli/epic_submit.rb` (create), `spec/lain/cli/epic_submit_spec.rb`
(create)
**Reuse:** `CLI::Epic` construction pattern (`cli/epic.rb:155`, returns a String, prints
nothing); `CLI::EpicQueue` drain-is-journaling doctrine (`epic_queue.rb:14-20`);
Submission (T1), Policies (T2), `Gate.from_journal` (T3), Scribe (T4);
`Epic::Stage#ensure_open!`
**Shared-file wiring:** subcommand registration in `exe/lain` (orchestrator applies)

`lain epic submit STAGE [SLUG]` builds the stage's Submission from the Home artifacts,
rebuilds the Gate from every session journal, resolves the stage's policy from config, and
decides. Approval journals `stage_completed` for the gated stage and `stage_started` for
its successor through the Scribe (the last stage completes only). Deferral prints the
parked address (`lain epic queue` shows it). Under the interactive policy the asker is a
TTY y/n prompt owned by this command; in-chat interactive review rides T23, not this
verb. When config names a policy this command cannot construct (adjudicated needs a
role_spawn a bare CLI does not have), the command reports the T2 factory refusal verbatim
and exits without deciding anything.

```gherkin
Scenario: a hands_off submit advances the stage
  Given config gating research as hands_off and a written research.md
  When lain epic submit research runs
  Then the output names the approval
  And Progress.fold reports stage epic_plan started

Scenario: a deferred submit parks and does not advance
  Given config gating epic_plan as deferred
  When lain epic submit epic_plan runs
  Then the output prints the parked digest and stage
  And Progress.fold still reports stage epic_plan

Scenario: a submit out of order refuses
  Given a parked gate in research
  When lain epic submit epic_plan runs
  Then the command reports StageBlocked and journals nothing

Scenario: an unconstructable policy refuses loudly
  Given config gating epic_plan as adjudicated and no role_spawn available
  When lain epic submit epic_plan runs
  Then the output names the stage, the policy, and the missing seam
  And no gate_decision is journaled
```
→ spec file: `spec/lain/cli/epic_submit_spec.rb`

**Escalation triggers:**
- `#status`-style methods return strings and print nothing (output discipline;
  `spec/output_discipline_spec.rb` parses every lib file). A single stray puts fails the
  suite: build the TTY prompt on an injected IO.
- Re-submitting an already-approved digest must be a no-op with a message, never a second
  decision; if the Gate's add-only registry makes that awkward, stop rather than
  special-case.

### T20 — Chat-spawned workers hand their commits back     [wave 3] [risk: high]

**Depends on:** T8
**Files:** discovery first (the chat fleet's completion path; ROADMAP:846-848 and
chunk-orchestration spec ticket 6 name the gap; likely `lib/lain/cli/` fleet wiring plus
`lib/lain/supervisor.rb`), then the wire; `spec/lain/isolation/worker_handoff_spec.rb`
and the located seam's spec (modify)
**Reuse:** `WorkerHandoff.over(repo_root:, journal:, resolver:)`
(`worker_handoff.rb:210`); `Isolation::Journal` (leases already journaled); the Arm
classes as the only current callers (the pattern to mirror)
**Shared-file wiring:** none expected; escalate if the wire needs exe/lain

The chat fleet isolates workers but never reclaims: commits die with the worktree. Wire
`WorkerHandoff#reclaim` into the chat path's actor-completion seam, mirroring how the
bench arms drive it, journaling the Report. Conflicts follow the existing escalation
machinery (merge_resolver assists, a human decides); surrender on unwind paths.

```gherkin
Scenario: a chat worker's commit reaches the parent
  Given a chat-spawned actor that commits in its worktree lease and completes
  Then a handback Outcome is journaled
  And the parent repo contains the worker's commit or a conflicted report names it

Scenario: an unwinding fleet surrenders instead of resolving
  Given a fleet stopping while a worker holds commits
  Then the ref is anchored and no resolver is spawned
```
→ spec files: the located seam's spec plus `spec/lain/isolation/worker_handoff_spec.rb`

**Escalation triggers:**
- Discovery may show the chat actor lifecycle has no completion signal at all (the gap was
  deliberate). If so, stop after the discovery step and hand the orchestrator the map;
  designing the signal is not this card's scope.
- If the wire touches `Supervisor#adopt`'s public signature, stop: OM-6 consumers pin it.

### T21 — Graph revisions record their fibers              [wave 3] [risk: medium]

**Depends on:** T4, T11
**Files:** `lib/lain/epic/records.rb` (modify: add `GraphRevision`),
`lib/lain/epic/scribe.rb` (modify: `#graph_revised`), `lib/lain/epic/graph.rb` (modify:
`split`/`merge`/`add` return revision metadata alongside the graph),
`spec/lain/epic/records_spec.rb`, `spec/lain/epic/scribe_spec.rb`,
`spec/lain/epic/graph_spec.rb` (modify)
**Reuse:** chunk-epic-domain follow-up 6; `Compaction::DerivationAudit` re-derivation
pattern; `Revision` internals (`graph.rb:177-238`)
**Shared-file wiring:** none

Deviation from follow-up 6's sketch, recorded here: fibers live in the journal, the Issue
value shape stays closed. Each `split`/`merge`/`add` yields, with the new graph, a frozen
revision descriptor carrying everything replay needs: op name, the op's full arguments
(arriving issues in `Issue#canonical` form plus keywords such as `as:` and
`discovered_from:`), preimage ids, result ids, and the before and after graph digests.
Ids and digests alone cannot re-run `split(id, into:)`, so the descriptor is the replay
payload, the digest pair is the oracle. `Scribe#graph_revised` journals it as
`graph_revision`. The one-hop provenance limit and merge's orphaning stop mattering for
audit: the journal holds every fiber, and a re-derivation check replays the ops from the
before digest and must land on the after digest. The decomposition-fidelity grader
(bench chunk) reads these records.

```gherkin
Scenario: a split's fiber is journaled with its payload
  When split divides issue "a" into "a1" and "a2" and the scribe records it
  Then a graph_revision record holds preimage ["a"], results ["a1","a2"],
       the canonical forms of "a1" and "a2", and both graph digests

Scenario: revisions replay to the recorded digest
  Given a chain of three journaled revisions from graph G
  When each op is re-applied from its recorded arguments in order
  Then the final graph digest equals the last record's after digest
```
→ spec files: `spec/lain/epic/records_spec.rb`, `spec/lain/epic/graph_spec.rb`

**Escalation triggers:**
- `graph.rb` is mutation-tested; the return-shape change to `split`/`merge`/`add` must
  keep the graph-only return available (additive API, e.g. a keyword or a paired method).
  If callers in the skills' documented flows break, stop.
- If record-level fibers prove insufficient for a value-level consumer (the panel may
  press here), stop and record the argument; do not widen `discovered_from` casually.

### T22 — Annotations ride extmarks and land as events     [wave 4] [risk: medium]

**Depends on:** T15, T16
**Files:** `lib/lain/frontend/neovim/runtime.lua` (modify),
`lib/lain/epic/review/annotations.rb` (create), `lib/lain/epic/records.rb` (modify: add
`Annotation`), `lib/lain/cli/human_replies.rb` (modify: extended payload),
`spec/lain/frontend/neovim_runtime_spec.rb`, `spec/lain/epic/review/annotations_spec.rb`
(create), `spec/lain/epic/review_spec.rb` (modify)
**Reuse:** `vim.ui.input` prompt pattern (`runtime.lua:717-733`); buffer-local keymaps
from cleared-augroup BufEnter (`runtime.lua:769-776`); `Document::HEADING` regex
(`document.rb:40`) for line-to-issue mapping
**Shared-file wiring:** none

The margin channel. In a review buffer, `:LainAnnotate` (and a buffer-local `ga` map)
prompts via `vim.ui.input`, sets an extmark with virtual text at the cursor line, and
stores the note. `:LainReviewDone` collects annotations as
`{line, text, anchor_text}` (anchor_text is the line's current content) and sends them in
the existing `review_done` payload, no protocol bump. Ruby side:
`Epic::Review::Annotations.resolve(annotations, document_bytes)` maps each line to the
enclosing issue heading (nil when the line sits in the preamble or mapping is ambiguous),
and settle journals one `annotation` record per note (generation, slug, issue id or nil,
line, anchor_text, text). The agent receives them with the delta.

```gherkin
Scenario: an annotation renders and survives collection
  Given a review buffer in headless nvim
  When :LainAnnotate adds "tighten this AC" at line 7
  Then the buffer shows virtual text at line 7
  And :LainReviewDone sends the note with line 7 and that line's content

Scenario: notes map to their issue
  Given a doc where line 7 sits under the heading for issue "b2"
  Then the journaled annotation carries issue id "b2"

Scenario: a drifted anchor degrades honestly
  Given the human inserted lines above the annotation before done
  Then the annotation's anchor_text still matches the annotated line's content
  And when no heading can be attributed the issue id is nil, never guessed
```
→ spec files: `spec/lain/frontend/neovim_runtime_spec.rb`,
`spec/lain/epic/review/annotations_spec.rb`

**Escalation triggers:**
- No protocol bump here (T16 owns the chunk's one). If the payload extension cannot stay
  backward-compatible inside the `review_done` verb, stop.
- Extmarks move with edits; if headless tests show nvim reporting positions inconsistently
  across versions, pin the behavior actually observed and note the version, do not chase
  it.

### T23 — The agent requests a review and waits            [wave 5] [risk: medium]

**Depends on:** T6, T15, T16, T22
**Files:** `lib/lain/tools/request_review.rb` (create),
`spec/lain/tools/request_review_spec.rb` (create)
**Reuse:** `Tool::Input` (schema and validation in one declaration); `Tools::AskHuman`
shape (park on promise, notify via `Notify#question`); `Epic::Home::Journaled` with the
reviews seam (T6); `Epic::Review` (T15); the frontend open surface (T16) behind an
injected duck; `Tool::Result`
**Shared-file wiring:** toolset registration line in `lib/lain/cli/wiring.rb`
(orchestrator applies)

`Tools::RequestReview` closes the baton loop from the agent side: input names the stage
artifact (slug, kind, issue id when applicable); the tool writes through the journaled
home, opens a Review, asks the injected editor surface to open the file, notifies the
human, parks on that review's promise, and returns a `Tool::Result` rendering the delta
(byte and structural summary, lossy flag, malformed error if any) and the annotations.
While parked, regeneration of that path refuses (T6+T15). Unbounded wait, like AskHuman:
a review is done when the human says so.

```gherkin
Scenario: the round trip returns edits and notes
  Given a stubbed editor surface and a review settled with a retitle and one annotation
  When the tool runs
  Then the result text names the retitled issue and quotes the annotation
  And ownership returned: a subsequent write_epic on the path succeeds

Scenario: a lossy settle is loud and honest in the result
  Given disk bytes that lost half the issues
  Then the result says possibly truncated, lists the missing ids, and asserts nothing

Scenario: concurrent reviews do not collide
  Given two agents reviewing different paths
  Then each tool call resolves with its own delta
```
→ spec file: `spec/lain/tools/request_review_spec.rb`

**Escalation triggers:**
- The `@pending` single-question invariant belongs to AskHuman alone; this tool must hold
  no instance-wide pending state. If the toolset wiring pushes toward a shared ivar, stop.
- InboxView counts only ask_human pendings; a parked review is journal-visible but not
  inbox-visible this chunk. If that gap blocks the manual pass, note it in the handoff,
  do not extend InboxView here.

### T24 — Land one issue at a time, resumable after a crash [wave 3] [risk: high]

**Depends on:** T1, T3, T4, T7, T8, T17, T18
**Files:** `lib/lain/forge/landing.rb` (create), `spec/lain/forge/landing_spec.rb`
(create)
**Reuse:** Promotion (T18), the gh executor pair (T17), Reconcile (T7), Scribe (T4),
`Gate.from_journal` (T3), `ensure_approved!` (`gate.rb:297`); Salvage's
pure-function-plus-writer split (`salvage.rb:56-63`)
**Shared-file wiring:** require line in `lib/lain/forge.rb`

`Forge::Landing` runs the serial protocol for one issue: `ensure_approved!` on the
implementation submission digest, then promote, `pr_create` against main, poll to merged,
journal `issue_moved` to done. Every step is an intent/outcome pair through the journaled
executor; the gate check happens before the first intent. Conflicts and dirty states stop
with a structured outcome and escalate to the human, never auto-resolve, no force.
`Landing.resume(entries:, world:)` uses Reconcile to skip settled intents and continue
from the first unsettled one, asking the world before retrying: a crash between promote
and pr_create resumes by creating the PR, never by re-promoting.

```gherkin
Scenario: a landing is a chain of settled intents
  Given an approved implementation digest and stubbed executors
  When landing runs for issue "a1"
  Then the journal holds intent/outcome pairs for promote, pr_create, pr_merge
  And an issue_transition marks "a1" done

Scenario: no approval, no intent
  Given a digest the gate never approved
  Then landing raises NotApproved and the journal holds no forge_intent

Scenario: resume continues instead of repeating
  Given a journal ending after a settled promote and world showing the branch pushed
  When resume runs
  Then the first new intent is pr_create and no second promote intent lands

Scenario: resume after a crashed pr_create finds its PR by head ref
  Given a journal ending after an unsettled pr_create and world whose pr_for(head:)
        reports the PR open
  When resume runs
  Then no second pr_create intent lands and the run proceeds to the merge step

Scenario: resume is a fixpoint against an unchanged world
  Given any journal and a world that does not change between runs
  When resume runs twice
  Then the second run emits no new intents

Scenario: a dirty merge state stops the run
  Given merge_state answering DIRTY
  Then landing stops with a conflicted outcome and journals no pr_merge intent
```
→ spec file: `spec/lain/forge/landing_spec.rb`

**Escalation triggers:**
- Live GitHub is touched only under `:integration`; every unit spec runs against stubs
  and fixture repos. If a behavior cannot be pinned without the network, stop and add it
  to the manual pass instead.
- If serial landing turns out to need any retargeting or cascade logic (it should not,
  base is always main), stop: that is the next chunk's boundary, and crossing it here
  means the cut was wrong.

### T25 — Land and resume from the CLI                     [wave 4] [risk: medium]

**Depends on:** T24
**Files:** `lib/lain/cli/epic_land.rb` (create), `spec/lain/cli/epic_land_spec.rb`
(create)
**Reuse:** `Forge::Landing` and `Landing.resume` (T24); `CLI::Epic` construction and
string-return pattern (`cli/epic.rb:155-169`); `CLI::SessionJournals` for the fold;
`GitIgnores`-style injectable subprocess seams for anything git-shaped
**Shared-file wiring:** subcommand registration in `exe/lain` (orchestrator applies)

`lain epic land ISSUE_ID [SLUG]` constructs the landing (gate rebuilt from journals,
executors under the journaled wrapper) and runs it; `lain epic land --resume [SLUG]`
reconciles and continues. Without this verb T24 is an object nothing can invoke, and
manual pass 2 (kill mid-landing, resume, no duplicates) has no entry point. Returns
strings, prints nothing (output discipline), reports stop-and-escalate outcomes with the
parked or conflicted address the human acts on.

```gherkin
Scenario: the happy path lands from the command line
  Given stubbed executors and an approved implementation digest
  When lain epic land a1 runs
  Then the output names the branch, the PR, and the merged state
  And Progress.fold shows issue "a1" done

Scenario: resume picks up where the crash left off
  Given a journal ending after a settled promote
  When lain epic land --resume runs
  Then the output names the skipped promote and the continued steps

Scenario: an unapproved issue refuses before any effect
  Given no approval for the implementation digest
  Then the output names NotApproved and the journal gains no forge_intent
```
→ spec file: `spec/lain/cli/epic_land_spec.rb`

**Escalation triggers:**
- `exe/lain` is orchestrator-owned; the card hands the registration as a wiring diff.
- If the command needs interactive decisions mid-landing (it should not; gates are
  decided before landing), stop: that would mean T24's protocol leaked a human step.

## Execution log (2026-07-30)

Rulings and corrections made during execution. These supersede the card text above.

**Landed:** T12 `9530b2f`, T4 `e1ec5b1`, T3 `f3fb35a`, T10 `4f4ef2a`, T9 `4e3e109`,
T11 `ef917ee`, T6 `5fa71a2`, T2 `e2e43b9`, T7 `a645138`.

**Landed in the 2026-07-30 resume (waves 2-4), by a different agent:** T1, T5, T8, T13,
T14, T15, T16, T17, T18, T19, T21, T22, T24 across five commits — `26a24e5`, `cc8749a`,
`08a8a8b`, `10bb2cb`, `f573057`. Those five bundle several cards each and carry **no commit
bodies**, against a repo whose every other commit records its reasoning; the plan doc was
never updated, so the tracker showed wave 1 only. See the 2026-08-02 review below.

**Landed 2026-08-02:** T25 `ee37954`, T26 `9cbef9a`, the review-intake repairs `0477f5d`.
T20 stays deferred by the ruling above. T23 is unblocked by T26 and not yet built.

- **T1's AC1 wording is superseded.** Two panels independently found `Approval::Gate`'s
  registry is keyed on artifact digest alone, so an approval at one `(epic, stage)` opened
  every other: the same graph under two slugs shared a digest, and research prose resubmitted
  as an `issue_plan` inherited the research sign-off. **Joel ruled: `Submission#digest` covers
  `{stage, slug, artifact}`.** `ensure_approved!` returns the *submission* digest;
  `#content_digest` exposes the raw content address. AC2 and AC3 unchanged. `Graph`,
  `Document` and `Approval::Gate` untouched. Considered and rejected: embedding stage+slug in
  the artifact text so the content digest moves naturally — it covers `research` and
  `issue_plan` but not `epic_plan` (`Graph = Data.define(:issues)` has no slug, `to_markdown`
  emits no header, `parse_markdown` drops preamble) and not `implementation` (an external sha,
  no text). Filed as follow-up 5.

- **`Epic::Stage::STAGES` does not exist** (cited in T1 and T2). It is `Lain::Epic::STAGES` —
  `stage.rb:8` sits inside a `Data.define do ... end` block, so its constants scope to the
  enclosing module. The trap CLAUDE.md already documents.

- **Require placement: the subtree index owns its children.** T2's `gate/policies.rb` is
  required from `lib/lain/approval/gate.rb`; T6's `home/journaled.rb` from
  `lib/lain/epic/home.rb`. Both cards' "Shared-file wiring" lines named the unit index instead
  and are wrong.

- **T8's spec path is wrong in the card** — the file is
  `spec/lain/isolation/worktree_handback_spec.rb`.

- **Every wave-1 worktree forked `origin/main`, 51 commits behind local `main`.** Salvaged by
  merging main into each. The cards' own files had not moved, but `.rubocop.yml` (+283) and
  `Gemfile.lock` (+23) had, so no agent's RuboCop run was meaningful until re-run after merge.
  One real casualty: T3's `clock: MONOTONIC` was correct at its base and became a `NameError`
  when main's `9cc3797` moved the constant — integration drift, not a defect. Landing hazard
  the same staleness created: a card's worktree copy of a shared file predates a sibling that
  already landed, so copying it wholesale silently reverts the sibling. Hit twice (T6's
  `home.rb` vs T10, T2's `gate.rb` vs T3); both resolved by taking main's file and appending
  only the wiring line.

- **Baseline correction.** The Integration checks cite 6441 from chunk-epic-domain. Main
  measured **7030** before this chunk; that is the real bar.

### Follow-up cards owed, from panel findings accepted as deferred

1. **`Refold::SLUG_TYPES` does not list the new slug-bearing record types.** A journal holding
   only another epic's `doc_written` records folds as "untouched" instead of raising
   `ForeignJournal` — reproduced twice. One line plus one `progress_spec.rb` example, covering
   `doc_written` (T6) and `review_opened`/`review_closed` (T15).
2. **The terminal-adjudication guard is check-then-act across two model spawns.** Two
   concurrent Adjudicators both pass `ensure_undecided!` before either writes; a probe produced
   two terminal `gate_decision` records for one digest, one approving and one denying. T9
   closed the sequential hole and widened the concurrent window. The real fix is
   compare-and-append, which `Journal` has no primitive for.
3. **`Checkout` and `Naming` as sibling files under `worktree/`.** `Metrics/ClassLength` does
   not count a nested class's lines toward the outer class, so nesting shrinks the counter
   without shortening the file.
4. **`Epic::Scribe` wants an optional `graph:` seam.** A mistyped issue id writes fine and then
   detonates `Progress.fold` with `UnknownIssue` permanently for that epic, in an append-only
   journal. `SessionRecord::Scribe::Diverged` resolves the identical shape the other way.
5. **Human-visible artifact front-matter**, scoped with the `Graph` slug member it needs — the
   rejected half of the T1 digest ruling.
6. **`lain.gemspec:60`** claims `--provider bedrock` builds `Provider::BedrockRaw` and
   `--provider anthropic` builds `Provider::AnthropicRaw`; neither constant exists anywhere in
   `lib/` or `spec/`, and `cli/backend.rb:158` builds `Provider::Bedrock` (verified).
7. **`Forge::Outcome` carries only a digest**, so an orphan cannot be attributed to an epic or
   issue. T17/T18 should put slug/issue in `detail`; widening the wire shape needs its own card.
8. **An approval whose transitions never landed wedges the epic permanently.** `gate.call` and
   the Scribe's two transitions are separate journal writes with no atomicity. Probed: with the
   approval journalled and the transitions not, a re-submit answers "already approved … nothing
   was decided or journaled again", `stage_events` stays empty, and progress never advances —
   `standing` short-circuits before the Scribe forever, offering no remedy. Not-re-deciding is
   correct; the flaw is using "already decided" as a proxy for "already advanced". Wants either
   a reconcile in `standing` when progress shows the gated stage incomplete, or a named remedy
   in the message.
9. **`CLI::EpicQueue` and `CLI::Epic` disagree about the session directory.** EpicQueue reads
   `@paths.sessions_dir` (project defaults to `Dir.pwd`); `CLI::Epic` reads
   `sessions_dir(project: project_hash(root))`. They agree under `exe/lain` and diverge for any
   injected `root:`, so an approved submit is invisible to `status`. Predates this chunk.
10. **`Promotion` has a read-then-write window against the remote.** `ls-remote` then `push` is
    two round trips, and git's non-force push refuses only *non-fast-forward* updates — so a
    concurrent actor that advances the ref to an **ancestor** of our sha in between gets the
    push landed, silently advancing a branch `decide` refused one line earlier. Verified with
    the exact argv the file constructs. The clean fix is `--force-with-lease`, which this chunk
    forbids; it belongs to the cascade chunk. Named in the class doc meanwhile.
11. **`issue_id` denotes two different value sets across one seam.** `Forge::Promotion` runs it
    through `Epic::Home.checked_name` (`/\A[a-z0-9][a-z0-9-]*\z/`), so `issue_id: "T18"`
    **raises `MalformedName`** — outside the journal, with no outcome a reconcile can read —
    while `Epic::Submission.issue_plan(issue_id: "T7")` is accepted and spec'd on main
    (`spec/lain/epic/submission_spec.rb:187`). A pre-existing split, inherited rather than
    created. Must be decided before T24 hands real ids in. Probable answer: issue ids are
    lowercase because `Home` writes `issues/<id>.md`, and `Submission` should say so too —
    but that is T1's landed file, so it wants its own card.
12. **`graph_revision` is a write-only trace, and `GraphFiber.of` discards the slug.** Nothing
    in `lib/` reads these records back, classifies them, or filters by epic — so a journal
    holding two epics' revisions, filtered on `type` alone, interleaves two chains into one
    nonsense replay. The card's own Reuse named `Compaction::DerivationAudit`, whose doc says a
    write-only trace is that subsystem's default failure mode: a field nobody consumes drifts
    from what it claims without a spec going red. The re-derivation *pattern* was reused; the
    *posture* was not. Distinct from item 1's `SLUG_TYPES` gap. The bench decomposition-fidelity
    grader is the intended reader — this is the card that should build it.
13. **A deferred adjudication re-spends without bound** — three re-decisions of one parked
    address cost 6 model spawns and 3 `gate_evidence` records for 1 queue item. That is T9's
    spec'd intent and nothing in `lib/` re-decides today, but `Policy::Adjudicated` makes it
    reachable from config overnight and nothing says a re-run re-pays.

### T20 stopped after discovery — its escalation trigger fired

The card said: if the chat actor lifecycle has no completion signal, stop after discovery and
hand back the map, because designing that signal is out of scope. It has none. Verified
2026-07-30, no `lib/` or `spec/` file touched:

- **No completion signal.** `Tools::Subagent::Actor#run` (`actor.rb:166-174`) is
  `process(prompt)` → `@ready.resolve(true)` → `@park.wait`, and `@park` is signalled nowhere in
  `lib/`. The actor parks forever after its initial turn. A lease is released in exactly two
  places, both unwind: `Supervisor#register`'s `ensure` and `Supervisor#stop`
  (`supervisor.rb:137-147`). The registry is append-only.
- **Near misses ruled out.** `Registration#settle` awaits only the *initial* turn and its lone
  production caller is the graceful-shutdown drain (`conductor.rb:230` → `Shutdown#drain`),
  itself an unwind. `Registration#state` cannot distinguish parked-quiescent from working —
  `CLI::Command::Keep` already documents that.
- **Nothing holds a `WorkerHandoff`.** `WorkerHandoff.over` is called by **zero** files in
  `lib/` or `exe/`; the real object is constructed only in specs. Chat holds the isolation
  backend alone (`wiring.rb:131`), `Supervisor` has no `handoff:` keyword, and
  `Registration#release` is a bare `lease.release`. `Arm::Driver`, `LiveArms` and `ArmSweep`
  all leave the `Null` default.
- **Compounding, and it lowers the urgency:** `mode: :actor` is constructed by no `lib/`/`exe/`
  file either — chat's toolset and `Skill::RoleSpawn` both build one-shot subagents. **No chat
  worker is ever adopted today, so there are no commits to lose yet.** `ROADMAP.md:844-848`
  already records both halves as chunk-14 deviations (spec tickets 6 and 13).

Only one half of T20's Gherkin is reachable without new design: *an unwinding fleet surrenders*
— `Supervisor#stop`/`#register` calling `#surrender` rather than a bare `lease.release`. That is
T13's file. **Deferred pending T13's own outcome**: T13 carries the identical escalation trigger
("if the restart path has no handle on a `WorkerHandoff`, stop"), so it may hit the same wall,
and the wiring question is better answered once with both maps in hand than guessed at twice.
The completion signal and the `mode: :actor` wire want their own cards.

### Ruling: the `WorkerHandoff` call site is NOT wired in this chunk

T13 built the seam (`Supervisor#initialize(handoff:)`, `#reap_crashed` before the acquire,
`Registration#surrender`) and escalated the call site: `lib/lain/cli/wiring.rb:131` builds the
Supervisor with an isolation backend and no handoff, so the reap does not fire in production.
Ruled 2026-07-30, with T20's map alongside it:

**Not wired here.** Three reasons. (1) T20 established `mode: :actor` is constructed by no
`lib/`/`exe/` file, so no chat worker is adopted today — the reap would have nothing to reap.
(2) Constructing a real `WorkerHandoff.over(repo_root:, journal:, resolver:)` requires a
**resolver**, a model-spawning collaborator; putting that in the default chat path is a cost and
behaviour decision, not a one-line wiring diff. (3) T13's default is `Supervisor::Retain`, not
`WorkerHandoff::Null` — Null *releases*, and with nothing wired nothing can anchor, so Retain
keeps today's behaviour exactly and nothing regresses by leaving it.

Follow-up card, to land with the completion-signal work rather than alone: pass a real
`WorkerHandoff` at `wiring.rb:131` and decide what resolver the chat path gets.

### Constraint T13, T18 and T20 inherit

`Handback` sits at exactly **110/110** on `Metrics/ClassLength` after T8 — zero headroom. Any
card adding to its direct body trips the cop, and CLAUDE.md forbids loosening it. Follow-up 3
should land before those three cards touch it, or each pays the extraction cost separately.

### Constraints T14 inherits (from T9's panel)

- Three ducks must address one journal — `gate:` (whose Gate writes the decision), `journal:`
  (evidence), `decisions:` (read-back) — and **no object can check it**. Pointing `decisions:`
  at a different `StringIO` makes the terminal guard silently never fire.
- **T9's boundary-counting spec cannot catch T14's double-check.** It builds an Adjudicator
  directly, so it counts only checks inside `Adjudicator#call`. A `Policy` subclass doing the
  inherited boundary check then delegating asks four times with the suite still green.
- `shipped_skills_spec` pins `Policy.subclasses` to exactly three, so an anonymous
  `Class.new(Policy)` in a spec is an order-dependent flake. Use a named class or the real
  `Policy::Adjudicated`.

### Ruling: T25's SHA is an argument, and `--resume` derives it from its own journal

T25 stopped because "no durable record binds an approved implementation content digest to the
exact commit it may promote." Verified 2026-08-02: `Approval::GateDecision`
(`approval/gate.rb:104`) records `artifact_digest` — the COMPOSED `(stage, slug, content)`
hash — and nothing else journals the content digest, so the approved SHA is genuinely
unrecoverable from the journal. That gap is real; the conclusion drawn from it was not.

**The binding does not need a record — it is the hash.** `Submission.implementation`
(`submission.rb:213`) takes its digest as given, and `epic_submit.rb:159` gets that string from
the human on the command line. So `lain epic land ISSUE_ID SHA [SLUG]` reconstructs
`Submission.implementation(slug:, issue_id:, digest: sha)` and lets `ensure_approved!` answer:
a SHA nobody approved produces a digest the registry has never seen, and the run refuses before
the first intent. Landing a commit other than the approved one is not prevented by bookkeeping,
it is unrepresentable. `Promotion::Remote#anchored!` (`promotion.rb:154`) already refuses
anything that is not a full object name naming a commit, so `HEAD`, an abbreviation, and a
branch are all rejected on the same path — the three identities the stub feared conflating stay
distinct without a new record.

`--resume` takes the issue id too, and derives the SHA: the journaled `promote` intent carries
`params["sha"]` (`promotion.rb:225`), which is by construction the SHA the gate already cleared.
No promote intent for that issue means there is nothing to resume, and the command says so.
`Intent` carries `epic_slug`/`issue_id` (`intent.rb:85`), so the CLI filters entries to the
named issue before `Reconcile` folds them — one epic's two landing histories must never
interleave, which is the whole of the "issue selector" half of the blocker.

Considered and rejected: journaling the content digest at submit time so `land ISSUE_ID` could
discover it. It widens a landed, mutation-tested value in a subsystem outside this chunk, and it
reverses `Approval::Gate`'s deliberate ignorance of what it is gating (its header states the
registry knows nothing of stages or epics) to save the human retyping a SHA they typed once
already.

### Ruling: T23's blocker is real, and splits into T26 + a narrowed T23

The T23 hand-back (`.handback-T23.md`) is correct on the facts: `Review#open` demands an
`Intake::Written` (`review.rb:312`), which refuses anything but an `Epic::Graph`
(`intake.rb:142-146`), while three of the four stages are not graphs. Its conclusion — treating
prose as an epic document would report ordinary prose as a malformed review — is right, and
widening `Written` to accept prose would destroy the one invariant it exists for: bytes and
graph that agree.

**The seam is the baseline, not `Written`.** `Review#open` uses `written` for exactly two
readers (`byte_digest`, `graph_digest`) and then wraps it in `Baseline`, whose whole body is
`delta(disk)` (`review.rb:93-99`) — and `Recalled` (`review.rb:115`) already proves a second
baseline shape is a supported thing to be. `ReviewOpened` already defaults `graph_digest` to nil
(`records.rb:257`), and `Account.empty` (`intake/delta.rb:42`) already names an account nobody
compared structurally. So prose reviews cost a sibling value and a sibling baseline, and no
change to `Written`, `Graph`, or `Document`.

Split, because it is two responsibilities and the first is the one with the invariants:

- **T26 (new, wave 5, risk: medium)** — the prose review baseline. Below.
- **T23 (narrowed)** — `Tools::RequestReview` over the three DOCUMENT-backed stages, refusing
  `implementation` by name.

`implementation` is out of T23's scope for good: `Epic::Home` exposes no implementation document
(`home.rb:108-111`) and the stage gates an external changeset digest, so "review it" means
reviewing a diff — a surface this chunk does not build. The tool must refuse it with a message
that says which stages are reviewable and why this one is not, never silently.

### T26 — A prose artifact can be reviewed too            [wave 5] [risk: medium]

**Depends on:** T15
**Files:** `lib/lain/epic/intake.rb`, `lib/lain/epic/review.rb`,
`spec/lain/epic/intake_spec.rb`, `spec/lain/epic/review_spec.rb`
**Reuse:** `Intake::Written` (the shape to sit beside, not to widen); `Review::Recalled` (the
proof that a second baseline duck is supported); `Account.empty`; `Intake.byte_digest`;
`Intake.lossy?`
**Shared-file wiring:** none — both files are already in the manifest, and `Intake::Prose` sits
in `intake.rb` beside `Written` rather than in a new file.

`Intake::Prose` is the bytes lain last wrote to a prose artifact, with no graph: it answers
`byte_digest` and answers `graph_digest` as nil. `Review::ProseBaseline` answers the same
`delta(disk)` duck as `Baseline`, reporting the two byte addresses and `Intake.lossy?` over an
`Account.empty` — measured, uncompared, and never parsed as an epic document. A prose review
that comes back rewritten is `byte_identical? == false` with `structural? == false`, which is the
true sentence about prose: the bytes moved and nothing structural was claimed.

```gherkin
Scenario: prose comes back edited
  Given a review opened on prose bytes and disk bytes differing by one sentence
  When it settles
  Then the delta is not byte_identical, not structural, not malformed, and not lossy

Scenario: prose that is not an epic document is not malformed
  Given prose that would fail Document.parse_markdown outright
  When it settles
  Then the delta carries no error and asserts nothing structural

Scenario: a truncated prose file is still suspected
  Given disk bytes under half the written bytesize
  Then the delta is lossy

Scenario: a prose review journals a nil graph digest
  Then the review_opened record carries the byte digest and no graph digest

Scenario: prose and graph reviews coexist on one Review
  Given one path opened with prose and another with a graph
  Then each settles against its own baseline and neither sees the other's account
```
→ spec files: `spec/lain/epic/intake_spec.rb`, `spec/lain/epic/review_spec.rb`

**Escalation triggers:**
- If `Intake::Written` has to change at all, stop — the split exists precisely to avoid that.
- If a prose delta cannot be built without `Delta` learning a new member, stop and report:
  `Delta`'s shape is pinned by `refuse_shapes!` and is not this card's to widen.

### The 2026-08-02 panel review of the resumed waves, and what it cost

Joel asked for the five body-less commits to be reviewed on the grounds that he could not
tell whether the resuming agent had the right context. Three panels (forge/landing,
review-intake, supervisor+editor) all returned **REQUEST-CHANGES**. What they found, and
what it says about the process rather than the code:

1. **The suite had been silently truncated since `f573057`.** `spec/lain/cli/epic_land_spec.rb`
   called `LainCLI::Epic.start` inside an example; `exe/lain` declares `exit_on_failure?`, so
   Thor rescued its own error and called `Kernel#exit`, killing the rspec process mid-run.
   `bundle exec rspec` reported **1160 examples, 0 failures, exit 1** where it should have
   reported 7728. The COUNT is the tell, not the failure list — the same shape CLAUDE.md
   documents for a dead parallel worker. **No suite run between `f573057` and `ee37954`
   meant anything, including this chunk's own integration check.** It was found twice
   independently: by the forge panel, and by the next commit's pre-commit hook refusing.
2. **`Forge::Landing` merged commits nobody approved.** It called `promote` and discarded the
   answer, on both paths. `Promotion` refuses a diverged remote, a namespace conflict and an
   inexact sha as `ok: false` VALUES; discarding them meant a branch standing at a stranger's
   commit was opened as a PR, merged into main, and journaled as the issue's approved work.
   `settled?` also ignored `ok`, so resume skipped a *failed* promote. The tier's whole
   apparatus exists to make "land only the approved commit" mechanical, and the object at the
   top of it dropped the one answer that enforced it.
3. **Two seams that had never worked, both with green specs on either side.** Annotations
   crossed msgpack String-keyed while Ruby read Symbols (`KeyError` on every real note, after
   the settlement was journaled); and `runtime.lua` sent `review_done` as flat positionals
   where the rail destructures `[verb, args]`, so every `:LainReviewDone` was refused. Two
   green tests either side of a seam nothing crossed is this repo's recurring defect, and it
   is what a cross-seam spec exists to catch.
4. **`Supervisor#stop` lost a crashed worker's commits** — bare-releasing the lease where
   `#register` surrenders. T13's headline guarantee, failing on the likeliest operator path.
5. **`cc8749a` reintroduced a poison pill directly beneath the comment forbidding it**, making
   an epic permanently un-rebuildable from two ordinary journal shapes.
6. **Two `Metrics/*` disables** (`landing.rb`, five cops; `rpc_thread.rb`, ClassLength at
   120/110), which CLAUDE.md forbids outright and which every other disable in `lib/` respects.

**The provenance explains it.** The execution notes record "T24 isolation was unavailable to
its agent; the orchestrator completed it locally" — the chunk's one HIGH-risk card was written
without isolation, without TDD, and without a panel. `landing.rb` is 3% comments (two of its
four comment lines are the RuboCop pragmas) against 47-65% for its panel-reviewed siblings,
and its spec pinned 2 of 6 scenarios: deleting the promotion step, replacing `Landing.resume`
with `nil`, and merging unconditionally all left the suite GREEN.

**Rulings.** T24 is rebuilt from the card by a TDD sub-agent (Joel's call: the shape is what
hid the defects, so patching it preserves the shape). The other three areas take targeted fix
passes with red-before-green per finding and probes-become-specs. Every fix pass re-runs the
panel's own mutation battery.

**Process lessons for the skill, beyond this chunk.** A resumed execution must (a) re-run the
FULL suite and compare the example COUNT against the recorded baseline, never just the failure
list; (b) keep one card per commit, because a three-card commit cannot be reverted per card;
(c) write commit bodies — on a bench whose deliverable is the experiment record, five empty
bodies is 2,900 lines whose reasoning exists nowhere; and (d) update the plan doc, which is
the tracker, not a side notes file.

## Integration checks

- Full suite: `bundle exec rspec` green; example count strictly above the 6441 baseline
  from chunk-epic-domain; `spec/output_discipline_spec.rb` and `spec/algebra_laws_spec.rb`
  untouched and green.
- `bundle exec rubocop -a` clean at default metrics; `.rubocop.yml` unchanged.
- Headless nvim suites green: `spec/plugin/nvim_plugin_spec.rb`,
  `spec/lain/frontend/neovim_runtime_spec.rb`; helptags generate for the updated
  `doc/lain.txt`.
- `pre-commit run --all-files` green.
- Manual passes for Joel, named so nothing drops silently:
  1. Live review round trip: `lain up --nvim`, agent writes an epic doc, requests review,
     annotate with `ga`, edit a title, `:LainReviewDone`, confirm the agent narrates the
     delta and the annotations.
  2. Serial landing dry run against a scratch GitHub repo with real `gh` auth: approve an
     implementation gate, `lain epic land`, watch the intent/outcome chain, kill the
     process mid-landing, `lain epic land --resume`, confirm no duplicate branch or PR.
  3. Overnight deferred smoke: gates set to `adjudicated` for epic_plan, run
     `/plan-epic` in the evening, drain the morning queue and read the spike evidence
     (needs T14; this is the pass chunk-epic-domain deferred for lack of a spike caller).
  4. Still owed from earlier chunks, unblocked or unchanged by this one: the Bedrock live
     integration pass (bedrock-provider.md checks 4 to 7), the toy-epic walk through
     `/plan-epic` and `/iterate-epic`, the `[epics] home = "repo"` flip, and the
     kill-dance resume pass.
- Follow-up from the T24 rebuild (2026-08-02): `CLI::EpicLand::Scoped` filters
  `issue_transition` records out of the entries it hands `Reconcile`, so a resume cannot see
  whether the issue already moved. The rebuild answers the fixpoint law from the run instead
  (`run.performed ? moved : run`), which is correct for every case the card names, and leaves
  one residual: a merge the world confirms but whose transition never reached the journal
  leaves the issue `in_flight` forever. Closing it means widening the scope filter to carry
  the issue's own transitions, which is a change to what "one issue's entries" means and
  wants its own card.
- Follow-up from the intake repairs (2026-08-02): `annotation` records are still WRITE-ONLY --
  nothing in `lib/` reads them and `Intake::Delta` has no member for them, so T22's "the agent
  receives them with the delta" is unmet. `Tools::RequestReview` (T23) is the intended reader;
  the hand-back records the record shape, the `(epic_slug, generation)` join, the order
  guarantee, and the two meanings of a nil `issue_id`, so T23 can be written against it.
- Named follow-ups this chunk creates (so they are not lost): render open reviews in
  `lain epic status`; surface parked reviews in the inbox count; the stack-cascade chunk
  (retargeting, `--onto`, `--force-with-lease` semantics); the bench altitude arms and
  the decomposition-fidelity grader reading T21's `graph_revision` records.
