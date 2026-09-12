# Simplify 12 — nine ways to ask somebody something become one

status: draft — **deferred as a whole**; T1 and T2 extracted to run standalone (see Open decisions)
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

Lain has **nine** mechanisms for "park the agent and get an answer from a human or another agent", plus a
tenth that already generalizes the answerer axis and which four of the nine do not use. They all stand on
one 46-line `Promise`. What is duplicated nine times is everything around it: the outstanding register,
the verdict vocabulary, the journal record, the replay fold, the surface port, and the frontend view. Two
of them are entire approval systems that **never meet** — separate answer types, journal records, policy
catalogs and surfaces, one for chat and one for epics.

This is the largest single simplification available in the repository and the one most likely to eat a
month. It is assembled from five things already in the tree rather than invented, and it lands in seven
steps each of which is independently green.

Delivers: one `Ask` with one register, one journal record, one replay fold, one surface port and one
verdict vocabulary — replacing roughly **10,000 raw lines of `lib/` and 25,000 of `spec/`** with about
1,400 code lines.

## Grounding

Verified 2026-09-12 against the working tree at `d2bb133c`. `code` is non-blank, non-comment.

**The primitive already exists and all nine use it.** `lib/lain/promise.rb` is **46 lines** and is the
"park the fiber, not the reactor" object. Nothing below proposes replacing it.

**The nine, and the tenth:**

1. `Effect::Handler::Gate` + `Approval::Queue`
2. `Approval::Escalation`
3. `Approval::Gate` + `Gate::Policy` / `Gate::Policies`
4. `Approval::SignoffQueue`
5. `Gate::Adjudicator`
6. `Tools::AskHuman` + `Question::*`
7. `Tools::RequestReview` + `Epic::Review`
8. `Review::Session` + `Handover` + `Surface`
9. `Review::Docent`

Plus **`Oracle`**, which already generalizes the *answerer* axis — `#ask(inputs) -> Promise`, with
`Heuristic` / `Model` / `Recorded` tiers — and which **(1), (3), (5) and (9) do not use**.

**Two approval systems that never meet.** `Effect::Handler::Gate` is constructed only at
`cli/switchboard.rb:216` and `tools/subagent.rb:1445` — the chat path. `Approval::Gate` only at
`cli/epic_driver/factory.rb:195` and `cli/epic_submit.rb:459` — the epic path. Separate answer types,
separate journal records, separate policy catalogs, separate surface ducks.

**`subject_digest` is the unifier, and every mechanism already has one.** (1) `tool_use_id`;
(3)(4)(5) `artifact_digest`; (6) the question event's digest; (7) `(epic_slug, generation)`;
(8) the changeset digest plus a hunk key; (9) `anchor_id`. **Content addressing is already the repo's
spine** — `Canonical`, `Event`, `Store`, `Timeline` — and these nine each built a private register beside
it.

**Five journal folds over one NDJSON file, and three cite each other in prose.**
`review/session/replay.rb`, `Epic::Review::Replay` (`epic/review.rb:162-274`) and
`SignoffQueue.from_journal` (`:284-311`) each fold the same file through one `Journal.records` walk, and
their docstrings **cross-reference each other's "shape and discipline"** at
`review/session/replay.rb:7-8`, `signoff_queue.rb:12-20` and `epic/review.rb:161`. Two more folds sit in
`SessionRecord::Replay` and `Bench::Session::Loader`. Duplication admitted in prose and never extracted.

**Sixteen declarations of the verdict vocabulary, in four type forms.** `escalation.rb:93`, `:581-582`;
`rule.rb:73`; `remembered.rb:74`; `auto_surface.rb:30`; `adjudicator.rb:68`, `:259-266`; `gate.rb:201`;
`neovim/approval_view.rb:115`; `oracle/secret_read.rb:60`. **`auto_surface.rb:30` and
`adjudicator.rb:68` are the byte-identical regex** `/\A(approve|deny|defer)\.?\z/i`.

And the vocabulary's collapse causes a re-encoding: **`gate.rb:201` reduces the triad to a Boolean**,
which is *why* `adjudicator.rb:259-266` must re-encode "defer" as `deny` plus a policy string. Worse,
**`escalation.rb:581-582` infers *authority* from a surface's string** — a latent security defect its own
comment names. A field on one record deletes it.

**Records declared three times each.** `epic/records.rb` is 220 code lines for **7 records** — a
`Declarative::Carrier` contract restating the fields, a `Data.define` restating them, and a class reopen
to pin `JOURNAL_TYPE`, about 74 raw lines per record. `review/records.rb` is 112 for 4. And two records
**bypass `Journalable` entirely**, hand-building `{"type" => ...}` at `queue.rb:185-190` and
`escalation.rb:255-257` — so a class rename silently relabels a record type.

**Six Null modules in one file.** `cli/human_replies.rb`: `Unlisted` `:39`, `NoEditor` `:56`, `NoViews`
`:66` (plus `Nothing` `:71`), `NoReview` `:92` (plus `Nothing` `:96`), `NoApprovals` `:618` (plus
`Nothing` `:622`), and `Unattached` at `review_seams.rb:29` — all saying "nothing is open, so there is
nothing to do". `#pending?` at `:201` already `OR`s two registers by hand.

**`Review::Docent` reopens itself six times** — `:84`, `:475`, `:608`, `:703`, `:811`, `:904` — and its
four records `DocentAsked` / `Answered` / `Refused` / `Abandoned` (`:905-1053`) are **one record with a
`state` field**, duplicating `Exchange#state`'s own `STATES = %i[pending answered refused abandoned]`
(`:160`).

**`approval/` must be split before it is judged.** It is three things wearing one directory:

| slice | code | verdict |
|---|---|---|
| `Gate::*` + `SignoffQueue` | 678 | belongs to **epic**, falls with it |
| the permission engine — `escalation` 223, `risk` 112, `rule`+`rule_chain` 159, `remembered` 166, `composed_term` 79 | 739 | `Risk` and `RuleChain` have **zero non-comment callers outside `approval/`** |
| the secret-boundary queue — `queue`, `queue_surface`, `secret_surface`, `auto_surface`, `policy_switch` | ~334 | **load-bearing, keep** |

The third slice is forced by the architecture: `RedactSecretReads:297` **parks a masked read through
`Queue::Outstanding`**, which is one of the three places CLAUDE.md says the secret boundary must be.
Treating `approval/` as one block will either over-cut the boundary or under-cut the product.

**What stays (~1,400 code lines).** `promise.rb`; the five new objects; the changeset model
(`review/{source,changeset,marks,hunk,anchor,partition,bounds,submit}`); the epic model
(`epic/{document,graph,issue,stage,home,scribe,blocking,progress}`); `question/document.rb` promoted to
the one ask-document grammar, absorbing `Epic::Document`'s checkbox grammar — **they already share
`MarkdownIdentifier`**; and `oracle/` as the machine rung.

**What dies (~10,000 raw lib, ~25,000 raw spec).** All of `approval/` except `risk.rb` and `rule.rb` as
stack members — `escalation.rb` (613 raw), `rule_chain.rb` (225), `policy_switch.rb` (120),
`composed_term.rb` (356), `gate.rb` (409), `gate/policy.rb` (281), `gate/policies.rb` (202),
`gate/adjudicator*.rb` (569), `signoff_queue.rb` (328), `queue.rb` (331), the four `*_surface.rb` (447);
`epic/review.rb` (479) + `epic/review/annotations.rb` (54); `review/session.rb` (481) + `session/*` (423),
`review/surface*.rb` (784), `handover.rb` (370), `docent.rb` (1,059), `verdict*.rb` (411),
`records*.rb` (284); `tools/ask_human.rb` + subtree (1,336 → ~250); `tools/request_review.rb`
(768 → ~150); `cli/human_replies.rb` (1,198 → ~350).

**Two shape observations worth carrying into the design.** `question/` **persists nothing at all** — its
Markdown round-trip is an nvim-buffer UI protocol, never a file — which is arguably the pattern
`Epic::Home` should have used instead of writing Markdown to disk and re-parsing it. And
`epic/home/journaled.rb:381` and `epic/intake.rb:76` both compute `Workspace::Snapshot::Blob#digest`, the
Store's own address, **over content they then keep as a file**.

**Where docs and code disagreed.** `ARCHITECTURE.md:338-339` cites `Effect::Handler::Recorded` as a
deterministic-replay handler while its `from_journal` reads a `type: "tool_result"` record **nothing in
`lib/` writes** — relevant because `Ask::Fold` replaces that class of replay and should not inherit the
defect.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lib/lain/approval.rb`,
  `lib/lain/review.rb`, `lib/lain/epic.rb`, `lib/lain/tools.rb`, `lib/lain/cli.rb`, `exe/lain`,
  `lain.gemspec`, `.rubocop.yml`, `spec/spec_helper.rb`.
- **This plan runs for weeks and must not hold a branch open.** Each card lands on `main` with the suite
  green and the old mechanism still working beside the new one. `Ask` is introduced as an **additional**
  mechanism and the nine are migrated one at a time; at no point is the tree in a state where an approval
  cannot be answered.
- **Prerequisites.** simplify-01 (the Metrics limits — every card here produces a class over the current
  cap), simplify-03 (the dead-code sweep, so this plan does not migrate dead code), and
  simplify-09's T1 (the `Effect::Handler` verb/adverb split — T5 builds the ladder on `Middleware::Stack`
  and cannot do so while four adverbs are still handlers).
- simplify-07's T1 builds the shared `Neovim::ListView` that T6 needs. If 07 is not done, T6 grows.

## Open decisions

- **The panel declined this plan in this form, and the objection is the premise.** It conflates two
  different operations. `Effect::Handler::Gate` + `Approval::Queue` is an **authorization** on the tool-call
  path: its answer is a verdict, its default must be fail-closed, and it sits on the secret boundary —
  T1's own AC 4 concedes that, because `RedactSecretReads:297` parks a masked read through
  `Queue::Outstanding`, one of the three places CLAUDE.md says the boundary must be. `Tools::AskHuman` is an
  **enquiry**: its answer is free text, its failure mode is a stalled turn, and fail-closed means nothing.
  Unifying them puts one register astride the secret boundary for a month.

  Worse, **the central key design is already known not to fit one of its clients before the first card
  starts.** T4's escalation says at-most-one-per-subject *"may be wrong… `Review::Session` can plausibly
  have two open asks against one changeset digest with different hunk keys"*, and T7's says *"if
  `Ask::Register`'s at-most-one-per-subject cannot express that, T4's key design was wrong and this card
  will find it — **which is late**."* A plan that names the moment its own foundation might collapse, five
  waves downstream, is not ready.

- **Two cards are extracted and stand on their own merits. Run these; defer the rest.**
  - **T1** (split `approval/` into its three real parts) — pure relocation, no behaviour change, and it
    makes the epic-descope question answerable without over-cutting the secret boundary.
  - **T2** (one verdict vocabulary, authority as a field) — this closes a **named latent security defect**:
    `escalation.rb:581-582` infers authority from a surface's string, which its own comment calls out.
    Worth doing regardless of whether a register ever exists.

  Then re-ask the unification question with `approval/` split and simplify-14 landed. It will be a much
  smaller question, and `Oracle` — which already answers `#ask -> Promise` and which four of the nine do not
  use — may turn out to be most of the answer.

- **Whether the epic path migrates at all.** simplify-08's T9 may retire the altitude cluster and
  simplify-04's T3/T4 reshape the epic commands. If the epic surface is being descoped, `Approval::Gate`,
  `SignoffQueue` and `Epic::Review` go with it and this plan shrinks by ~1,150 code lines and one of its
  two first clients. **Settle 08's T9 before T4 here.**
- **Whether `Docent` survives in any form.** It is 418 code lines, reopened six times, and
  `spec/lain/review/deletability_spec.rb`'s `docent` row already lists it as removable with its consumers
  named. T7 rewrites it over the register; deleting it instead is cheaper and the deletability map already
  certifies the path. **The panel should rule before T7.**
- **Where the ask-document grammar lives.** T3 promotes `question/document.rb` and absorbs
  `Epic::Document`'s checkbox grammar. They already share `MarkdownIdentifier`, but `Epic::Document` is
  written to disk and re-parsed while `Question::Document` is a buffer protocol. One grammar over two
  persistence stories is right; one grammar that assumes a file is not.

## Waves

**T1 and T2 are the extracted pair and run first, standalone.** Everything from T3 on is deferred pending
the premise question in Open decisions.

Wave 1: T1, T2
Wave 2: T3 (←T2)
Wave 3: T4 (←T3)
Wave 4: T5 (←T4)
Wave 5: T6 (←T4)
Wave 6: T7 (←T5, T6)
Critical path: T2 → T3 → T4 → T5 → T7

The waves are deliberately narrow. This is a sequence, not a fan-out: each step's output is the next
step's input, and a step that lands half-done leaves two registers where there was one.

## Tasks

### T1 — Split `approval/` into its three real parts before anything judges it   [wave 1] [risk: medium]

**Depends on:** none
**Files:** move `lib/lain/approval/gate*.rb` and `approval/signoff_queue.rb` under
`lib/lain/epic/`; move `approval/{queue,queue_surface,secret_surface,auto_surface,policy_switch}.rb`
under `lib/lain/sensitivity/` (or a new `lib/lain/parked/` — the card chooses and says why); leave
`approval/{escalation,risk,rule,rule_chain,remembered,composed_term}.rb` in place; modify every caller
**Reuse:** nothing new — this is a relocation that makes the existing three-way split visible
**Shared-file wiring:** require-line moves between `lib/lain/approval.rb`, `lib/lain/epic.rb` and
whichever index receives the queue
**Reachable from:** all three slices stay reachable exactly as they are; AC 4 is the secret-boundary
check, driven through `CLI::ToolGuard`'s real stack

`approval/` is three things: **678 code lines that belong to epic** (`Gate::*` + `SignoffQueue`, whose
only constructors are `epic_driver/factory.rb:195` and `epic_submit.rb:459`), **739 that are a permission
engine** (and `Risk` and `RuleChain` have zero non-comment callers outside the directory), and **~334
that are the secret-boundary queue** — which is load-bearing because `RedactSecretReads:297` parks a
masked read through `Queue::Outstanding`.

**This card changes no behaviour.** It exists so that the rest of this plan, and any future decision to
cut the epic surface, cannot over-cut the boundary or under-cut the product by treating one directory as
one thing.

**Acceptance criteria**

```gherkin
Scenario: an epic gate still adjudicates
  Given an epic issue whose gate policy is adjudicated
  When the gate is asked
  Then it answers as before

Scenario: a chat approval still parks and settles
  Given a chat with a risky tool call
  When it is proposed and then approved
  Then the call proceeds

Scenario: the permission rules still decide in order
  Given two escalation rules, the first matching
  When an effect is judged
  Then the first rule's verdict is used

Scenario: a masked read still parks through the queue
  Given a guard stack built by the tool guard
  And a file whose contents match a secret pattern
  When it is read
  Then the read is parked for a decision
  And the content reaching the model is masked
```
→ spec files: existing specs at their relocated paths; **AC 4 in
`spec/lain/middleware/redact_secret_reads_spec.rb`**, which is the one that proves the boundary survived

**Escalation triggers**
- **AC 4 is the card's gate.** `RedactSecretReads:297` is one of the three places CLAUDE.md says the
  secret boundary must be. If the relocation changes when or whether a masked read parks, **stop** — no
  amount of directory tidiness is worth that.
- If a file turns out to belong to **two** slices — a surface serving both the chat queue and the epic
  gate — the split is not three-way and the card must report the real shape rather than forcing it.
- `Risk` and `RuleChain` having no external callers suggests the permission engine may be largely
  internal to `Escalation`. **Do not act on that here** — T5 folds the ladder and will find out; this card
  only relocates.

### T2 — One verdict vocabulary, with authority as a field   [wave 1] [risk: high]

**Depends on:** none
**Files:** create `lib/lain/ask/verdict.rb`, `spec/lain/ask/verdict_spec.rb`; modify
`lib/lain/approval/escalation.rb`, `approval/rule.rb`, `approval/remembered.rb`,
`approval/auto_surface.rb`, `lib/lain/epic/gate/adjudicator.rb`, `epic/gate.rb`,
`lib/lain/frontend/neovim/approval_view.rb`, `lib/lain/oracle/secret_read.rb`
**Reuse:** `review/vocabulary.rb` already does exactly this for `SIDES` and `FILE_STATES` — one
declaration, every projection derived. Follow it.
**Shared-file wiring:** a manifest line in `lib/lain.rb` before `approval` and `epic`
**Reachable from:** every gate decision and every surface reads a verdict; AC 1 drives a chat approval
and AC 2 an epic gate, both through their real construction paths

**Sixteen declarations in four type forms**, two of them the byte-identical regex
`/\A(approve|deny|defer)\.?\z/i` (`auto_surface.rb:30`, `adjudicator.rb:68`). One vocabulary:
`%i[approve deny defer]` plus `authority ∈ {automatic, human}`, with every projection derived.

**Two defects close with it.** `gate.rb:201` collapses the triad to a **Boolean**, which is why
`adjudicator.rb:259-266` must re-encode "defer" as `deny` plus a policy string — a lossy round-trip that
one three-valued type removes. And **`escalation.rb:581-582` infers authority from a surface's string**,
which its own comment names as a defect; `authority` as a field on the verdict deletes it.

**This card is high risk because it is a security-adjacent type change.** A verdict is what decides
whether a tool call happens.

**Acceptance criteria**

```gherkin
Scenario: a deferred decision is not an approval
  Given a gate whose policy defers
  When an effect is judged
  Then the verdict is defer
  And the effect is not approved

Scenario: a deferral survives a round trip
  Given a deferred verdict written to the journal
  When it is read back
  Then it is still a deferral
  And it is not a denial with a policy note

Scenario: authority is carried, not inferred
  Given a verdict settled automatically and one settled by a human
  When each is read
  Then each names its own authority
  And neither authority was derived from a surface name

Scenario: an unknown verdict word is refused
  Given a recorded answer naming a word that is not a verdict
  When it is read
  Then it is refused, listing the verdicts that exist
```
→ spec files: `spec/lain/ask/verdict_spec.rb` (AC 2, AC 3, AC 4),
`spec/lain/cli/switchboard_spec.rb` (AC 1)

**Escalation triggers**
- **`gate.rb:201`'s Boolean may be load-bearing downstream.** Something consumes a true/false and may not
  handle a third value. Find every consumer before widening the type; a `defer` treated as truthy is an
  approval nobody asked for.
- `escalation.rb:581-582`'s authority inference is a **latent security defect**. Fixing it may change
  which decisions are recorded as human — and therefore what `Approval::Remembered` will replay. If a
  remembered approval's authority changes, a previously-remembered answer may stop applying. That is
  arguably correct and is definitely observable; report it rather than absorbing it.
- Sixteen declarations means sixteen call sites whose specs assert on the old form. If more than a handful
  assert on a **Boolean**, the migration is larger than this card and should be split by consumer.
- `oracle/secret_read.rb:60` is a verdict declaration on the **oracle** side, i.e. a machine answerer. If
  the machine rung's verdict vocabulary differs meaningfully from the human one, that is a real
  distinction and one type may be wrong — say so.

### T3 — One journal record and one fold   [wave 2] [risk: high]

**Depends on:** T2
**Files:** create `lib/lain/ask/answered.rb`, `lib/lain/ask/fold.rb`,
`spec/lain/ask/answered_spec.rb`, `spec/lain/ask/fold_spec.rb`; modify
`lib/lain/review/session/replay.rb`, `lib/lain/epic/review.rb`, `lib/lain/epic/signoff_queue.rb`,
`lib/lain/approval/queue.rb`, `lib/lain/approval/escalation.rb`
**Reuse:** `Journal.parse` and `Journal.records` are the one walk; `Journalable#journal_type` already
derives the discriminator from the class name. The three folds' docstrings already cross-cite each other's
*"shape and discipline"* — that prose becomes `Ask::Fold`'s.
**Shared-file wiring:** two manifest lines in `lib/lain.rb`
**Reachable from:** the fold is what reconstructs parked state after a resume, reached from
`CLI::Resume`; AC 3 drives a real resume over a journal written by a real run

**This is the load-bearing half, and it lands without touching a surface.** One `Journalable` record —
`(subject, verdict, authority, surface, latency, body)` — and one fold, replacing five folds over one
NDJSON file.

**Two records currently bypass `Journalable`**, hand-building `{"type" => ...}` at `queue.rb:185-190` and
`escalation.rb:255-257`, so a class rename silently relabels a record type. Both go through the new record.

`Ask::Fold` must answer the epoch questions the five folds each answered separately: which epoch wins,
first-wins or last-wins, and abort-versus-skip on a malformed line. **The three cross-citing docstrings
are the specification** — read all three before choosing, because they may not agree, and a disagreement
is a finding.

**Acceptance criteria**

```gherkin
Scenario: an answered ask is recorded once with its verdict and authority
  Given an ask settled by a human
  When the journal is read
  Then one record names the subject, the verdict and the authority

Scenario: replaying a journal reconstructs what is still open
  Given a journal holding three asks of which one was answered
  When it is folded
  Then two are open and one is settled

Scenario: a resumed session sees the same open set
  Given a run that parked two asks and was interrupted
  When it is resumed
  Then both asks are still open

Scenario: a malformed line does not lose the records after it
  Given a journal with one unparseable line in the middle
  When it is folded
  Then the records after it are still read
  And the malformed line is reported

Scenario: the same ask answered twice keeps one answer
  Given two answers for one subject
  When the journal is folded
  Then one answer stands
  And which one is deterministic
```
→ spec files: `spec/lain/ask/answered_spec.rb` (AC 1), `spec/lain/ask/fold_spec.rb` (AC 2, AC 4, AC 5),
`spec/lain/cli/resume_spec.rb` (AC 3)

**Escalation triggers**
- **AC 5 is where the five folds may disagree.** First-wins and last-wins are both defensible and the
  three docstrings may specify different answers. If they do, **stop and report the disagreement** — this
  is the single most important thing this card can discover, because it means two mechanisms currently
  replay the same journal differently.
- The Journal is **the experiment record** and its format is append-only NDJSON. A new record type is
  additive, but if `Ask::Answered` *replaces* a type some existing reader expects, old journals stop
  replaying. Decide whether `Fold` reads both old and new shapes, and for how long.
- `ARCHITECTURE.md:338-339` cites `Effect::Handler::Recorded` as a deterministic-replay handler while its
  `from_journal` reads a `type: "tool_result"` record **nothing writes**. Do not inherit that shape: a
  fold that silently returns empty is worse than one that raises.
- `SessionRecord::Replay` and `Bench::Session::Loader` are the other two folds and are **out of scope** —
  they fold turns, not asks. Confirm that before touching them; simplify-08's T-series may also be moving
  `Bench::Session`.

### T4 — One register   [wave 3] [risk: high]

**Depends on:** T3
**Files:** create `lib/lain/ask.rb`, `lib/lain/ask/register.rb`,
`spec/lain/ask_spec.rb`, `spec/lain/ask/register_spec.rb`; modify
`lib/lain/approval/queue.rb` and `lib/lain/epic/review.rb` as the first two clients
**Reuse:** **`lib/lain/promise.rb` (46 lines) is the parking primitive and is not replaced.**
`Queue::Outstanding` is the most complete of the nine registers and is the shape to generalize.
**Shared-file wiring:** two manifest lines in `lib/lain.rb`
**Reachable from:** `Approval::Queue` is on the chat path via `CLI::Switchboard`; `Epic::Review` on the
epic path via `CLI::EpicSubmit`. AC 1 drives a chat approval and AC 4 an epic review, each through its
real construction.

`Ask` is `(subject_digest, prompt, options, arity, requester, deadline)`. `Ask::Register` is the open set
keyed by `subject_digest`: park a `Promise`, settle **exactly one** awaiting fiber, **timeout → deny
fail-closed**, at-most-one-per-subject.

**Two first clients, chosen for the cleanest keys.** `Approval::Queue` keys on `tool_use_id`;
`Epic::Review` on `(epic_slug, generation)`. The other seven migrate in T7.

**`subject_digest` is why this works.** Every one of the nine already has one, and content addressing is
already the repo's spine — these registers were each built *beside* it.

**Acceptance criteria**

```gherkin
Scenario: an ask parks its requester and settles exactly one
  Given two fibers awaiting one subject
  When an answer arrives
  Then exactly one is settled

Scenario: a second ask for one subject is refused
  Given an open ask for a subject
  When another is opened for the same subject
  Then it is refused

Scenario: an ask that times out denies
  Given an ask with a deadline in the past
  When its deadline passes
  Then it is denied
  And the denial names the timeout

Scenario: an epic review parks and settles through the register
  Given an epic generation awaiting review
  When it is approved
  Then the epic proceeds

Scenario: a chat approval parks and settles through the register
  Given a risky tool call
  When it is approved at the terminal
  Then the call proceeds
```
→ spec files: `spec/lain/ask/register_spec.rb` (AC 1-3), `spec/lain/epic/review_spec.rb` (AC 4),
`spec/lain/cli/switchboard_spec.rb` (AC 5)

**Escalation triggers**
- **Fail-closed on timeout is a security property, not a convenience.** If any of the nine currently
  fails *open* on a deadline — proceeding when nobody answered — unifying them changes behaviour in the
  safe direction but **observably**. Find out which do and report it; a previously-working unattended run
  may now stop.
- **Exactly-one-settles is a concurrency claim** and `spec/lain/supervisor_concurrency_spec.rb` and
  `subagent_concurrency_spec.rb` are the house style for proving one. Write the register's concurrency
  spec in that style; a register that settles two fibers is a double-approval.
- `Queue::Outstanding` is where `RedactSecretReads:297` parks a masked read. If generalizing it changes
  the masked-read path at all, T1's AC 4 is the guard and it must still pass.
- At-most-one-per-subject may be **wrong** for one of the nine. `Review::Session` can plausibly have two
  open asks against one changeset digest with different hunk keys — which is why the key is
  `(digest, hunk)` there. If the composite key does not fit `subject_digest`, say so; a register whose key
  is sometimes composite and sometimes not is two registers.

### T5 — The escalation ladder as a middleware stack   [wave 4] [risk: high]

**Depends on:** T4
**Files:** modify `lib/lain/approval/escalation.rb` (deleting most of it),
`lib/lain/approval/rule.rb`, `approval/risk.rb`; delete `lib/lain/approval/rule_chain.rb`,
`lib/lain/epic/gate/policy.rb`, `epic/gate/policies.rb`; modify `lib/lain/cli/switchboard.rb`,
`lib/lain/epic/gate.rb`
**Reuse:** **`Middleware::Stack` is already a property-tested monoid** and simplify-09's T1 has just
moved four adverbs onto it — the ladder is the same shape. `Risk` and `Rule` survive **as stack members**.
`Oracle` is the machine rung and already answers `#ask -> Promise`.
**Shared-file wiring:** require-line removals from `lib/lain/approval.rb` and `lib/lain/epic.rb`
**Reachable from:** `CLI::Switchboard` builds the chat ladder and `Epic::Gate` the epic one; AC 1 and
AC 4 each drive one

An escalation ladder is a stack of decision layers where each may answer or pass down — which is exactly
a `Middleware::Stack` over an `Ask`. `Escalation` (223 code), `RuleChain` (67),
`Gate::Policy` (91) and `Gate::Policies` (83) collapse onto it.

`Gate::Policies`' **four bespoke error classes** for a four-entry catalog (`Unknown`, `MissingSeam`,
`UnusableSeam`, `UnknownSeam`) go with it — one refusal naming which entry and why.

**`Oracle` becomes a rung.** Four of the nine mechanisms do not use it today despite its being exactly the
"ask a machine instead" abstraction; as a stack member it is available to all of them.

**This card requires simplify-09's T1.** Building the ladder on `Middleware::Stack` while four adverbs are
still `Effect::Handler`s means two composition mechanisms again.

**Acceptance criteria**

```gherkin
Scenario: the ladder decides at the first rung that answers
  Given a ladder whose second rung approves and whose third denies
  When an effect is judged
  Then it is approved

Scenario: a rung that passes reaches the next
  Given a ladder whose first rung passes
  When an effect is judged
  Then the second rung was consulted

Scenario: an unanswered effect reaches the human rung
  Given a ladder whose machine rungs all pass
  When an effect is judged
  Then it is parked for a human

Scenario: an epic gate's ladder is the same mechanism
  Given an epic gate and a chat gate
  When each is asked for its ladder
  Then both are middleware stacks

Scenario: an unknown policy name is refused with the names that exist
  Given a config naming a policy that does not exist
  When the ladder is built
  Then it is refused, listing the policies available
```
→ spec files: `spec/lain/approval/escalation_spec.rb` (AC 1-3), `spec/lain/epic/gate_spec.rb` (AC 4),
`spec/lain/ask/ladder_spec.rb` (AC 5)

**Escalation triggers**
- **A middleware stack is ordered and a ladder is ordered — but a middleware can also act on the way back
  out.** If any current rung does something *after* the inner rungs answer (recording a latency, say),
  that is a middleware and fine; if a rung's behaviour depends on being the *last*, the mapping is not
  exact. Check each.
- `Approval::Remembered` (166 code) replays a previously-given answer. As a rung it must not
  short-circuit a *fresh* subject — and T2 may have changed which answers are remembered as human. Those
  two interact; read T2's escalation note.
- `Risk` (112) and `Rule` (159) survive as members. If either needs the whole chain rather than just the
  next rung, it is not a middleware. `RuleChain`'s existence suggests it might.
- `escalation.rb` is 613 raw lines and this card deletes most of them. **The prose contains measured
  facts** — read before deleting, and move any measurement to wherever the behaviour now lives.

### T6 — One surface port   [wave 5] [risk: medium]

**Depends on:** T4
**Files:** create `lib/lain/ask/surface.rb`, `spec/lain/ask/surface_spec.rb`; modify
`lib/lain/frontend/tty.rb`, `lib/lain/frontend/neovim/approval_view.rb`,
`lib/lain/frontend/neovim/inbox_view.rb`, `lib/lain/frontend/neovim/question_view.rb`;
delete the four `approval/*_surface.rb` duck implementations that the port replaces
**Reuse:** **simplify-07's T1 `Neovim::ListView`** is the editor-side view this port renders through —
one generation-stamped ring for every kind of ask. `Ask::Verdict` (T2) is what a surface returns.
**Shared-file wiring:** a manifest line in `lib/lain.rb`
**Reachable from:** `CLI::Wiring` assembles the surfaces a run offers; AC 1 drives the terminal and AC 2
the editor, both through `CLI::Wiring`

One port: `#present(ask) -> Answer | nil`. Two implementations, terminal and editor, plus the
`auto_approver` for unattended runs.

Today there are **four `*_surface.rb` duck implementations** in `approval/` (447 raw lines) plus separate
view code per kind of ask in the editor. With `ListView` from simplify-07 and one `Ask`, an approval, a
question and a review annotation are **rows in one list** rather than three surfaces.

**Acceptance criteria**

```gherkin
Scenario: an ask is presented at the terminal and answered
  Given an open ask
  When the terminal surface presents it and a verdict is entered
  Then the ask is settled with that verdict

Scenario: an ask is presented in the editor and answered
  Given an open ask and a live editor
  When the editor surface presents it and the approve gesture is pressed
  Then the ask is settled

Scenario: a surface that cannot present says so rather than raising
  Given a surface whose editor has detached
  When an ask is presented
  Then it reports that nothing could be shown
  And the ask is still open

Scenario: an unattended run answers from its policy
  Given a run with no human surface and an auto policy
  When an ask is opened
  Then it is settled by the policy
  And the journal records the authority as automatic
```
→ spec files: `spec/lain/ask/surface_spec.rb` (AC 3), `spec/lain/frontend/tty_spec.rb` (AC 1),
`spec/lain/frontend/neovim_runtime_spec.rb` (AC 2 — `:nvim`-tagged, a real editor),
`spec/lain/cli/switchboard_spec.rb` (AC 4)

**Escalation triggers**
- **AC 3 is the reason the port returns `nil` rather than raising.** A detached editor must not lose an
  ask. If the port's contract makes a failed presentation indistinguishable from a refusal, an ask can be
  silently dropped — which is the worst outcome available here.
- `spec/approval_consumer_discipline_spec.rb` exists because `Lain::Notify` once **took** the approval
  queue, leaving `--no-nvim` with no surface. That guard is about the queue having a consumer; if this
  card's port changes what "having a consumer" means, the guard needs rewriting rather than deleting.
- A question, an approval and a review annotation have different **arity** — one is yes/no, one picks from
  options, one may take free text. `Ask` carries `arity`, but if a surface needs to render three
  materially different widgets, one port with one `#present` may be too thin. Report if so.
- simplify-07's T1 excludes `review_view.rb` because simplify-14 may delete it. If 14 has not been
  settled, the editor surface for review asks is in limbo — say which asks this card covers.

### T7 — Rewrite the five remaining clients over the register   [wave 6] [risk: high]

**Depends on:** T5, T6
**Files:** modify `lib/lain/tools/ask_human.rb` (1,336 raw → ~250), `lib/lain/tools/request_review.rb`
(768 → ~150), `lib/lain/cli/human_replies.rb` (1,198 → ~350); modify or delete
`lib/lain/review/session.rb` + `session/*`, `review/handover.rb`, `review/docent.rb`,
`review/verdict*.rb`, `review/records*.rb`, `lib/lain/epic/signoff_queue.rb`,
`lib/lain/epic/gate/adjudicator*.rb`; modify `lib/lain/question/document.rb`
**Reuse:** everything this plan has built — `Ask`, `Register`, `Answered`, `Fold`, `Verdict`, the ladder,
the surface. `question/document.rb` becomes the one ask-document grammar, absorbing `Epic::Document`'s
checkbox grammar; **they already share `MarkdownIdentifier`.**
**Shared-file wiring:** require-line removals across `lib/lain/review.rb`, `lib/lain/epic.rb`,
`lib/lain/tools.rb`
**Reachable from:** each client keeps its existing entry point — `ask_human` and `request_review` as
tools, `human_replies` as the REPL drain, `Review::Session` from `/review`. AC 1-4 each drive one.

The last and largest step. Five clients move onto the register:

- **`Tools::AskHuman`** — its `Outstanding` register, its `Directory`, its `Holding` module and its
  `Promise` handling all become `Ask::Register` calls.
- **`Tools::RequestReview`** — its `Seams`, its `NoNotes`, its own park/notify/release become the same.
- **`CLI::HumanReplies`** — **six Null modules** (`:39`, `:56`, `:66`, `:92`, `:618`, plus
  `review_seams.rb:29`) become one, and `#pending?` (`:201`) stops `OR`-ing two registers by hand.
- **`Review::Session`** + `Handover` — its fold is `Ask::Fold`, its surface is `Ask::Surface`.
- **`Review::Docent`** — reopened six times, with four records (`:905-1053`) that are **one record with a
  `state` field**, duplicating `Exchange#state`'s own `STATES` (`:160`). **See Open decisions: deleting
  it may be the answer rather than rewriting it.**

**Acceptance criteria**

```gherkin
Scenario: a tool asks a human and the answer reaches it
  Given an agent turn that asks a human
  When the human answers at the terminal
  Then the tool's result carries the answer

Scenario: a review is requested, settled, and its delta reported
  Given a changeset
  When a review is requested and approved
  Then the tool reports the settled delta

Scenario: the REPL drain lists every kind of open ask together
  Given one parked approval, one open question and one open review
  When the inbox is drained
  Then all three are listed

Scenario: an epic generation is signed off through the register
  Given an epic generation awaiting signoff
  When it is approved
  Then the epic proceeds

Scenario: an interrupted run resumes with every ask still open
  Given a run with three open asks of different kinds
  When it is interrupted and resumed
  Then all three are still open
```
→ spec files: `spec/lain/tools/ask_human_spec.rb` (AC 1), `spec/lain/tools/request_review_spec.rb`
(AC 2), `spec/lain/cli/human_replies_spec.rb` (AC 3), `spec/lain/epic/signoff_queue_spec.rb` (AC 4),
`spec/lain/cli/resume_spec.rb` (AC 5)

**Escalation triggers**
- **AC 3 is the card's justification.** If three kinds of ask cannot be listed together, they were never
  one concept and this plan's premise is wrong. That is worth discovering, loudly, rather than working
  around — stop and report.
- `human_replies_spec.rb` has **71 `allow(` calls of which 60+ are the same one** —
  `allow(conductor).to receive(:read_reply)` — plus `:855`/`:862` stubbing a **private** method. Expect
  most of that file to be rewritten; `Reply#heard` (`:950-954`) needs **one line of text** and is
  currently injected a whole `Conductor`, so the honest fix is a `reader:` lambda, exactly as
  `switchboard.rb:357` already does for the approval prompt.
- `Review::Docent` is 418 code lines and its own deletability row is already written. **Do not rewrite it
  before the panel has ruled** on whether it survives — a week spent porting a deletable capability is the
  most expensive possible outcome of this plan.
- `Review::Session` may carry **two open asks against one changeset digest** with different hunk keys. If
  `Ask::Register`'s at-most-one-per-subject cannot express that, T4's key design was wrong and this card
  will find it — which is late. Re-read T4's escalation note before starting.
- This card touches ~4,700 raw lines across five clients. **Land each client separately**, with the suite
  green between, and keep the old mechanism working beside the new one until its last caller moves. A
  half-migrated client is two registers.

## Integration checks

After the last wave:

- `bundle exec rake pspec` green, **with the example count recorded and the arithmetic written out**. This
  plan deletes on the order of 25,000 raw spec lines; the count will drop a very long way legitimately,
  which is exactly the condition under which a dead worker hides.
- `bundle exec rubocop` clean, **and `Style/Documentation`'s `AllowedConstants` list smaller** — `Docent`
  and `RequestReview` are both on it because both are reopened, and this plan un-reopens them.
- `bundle exec rspec spec/lain/ask spec/lain/approval spec/lain/epic spec/lain/review` as the focused run.
- **`bundle exec rspec spec/lain/middleware/redact_secret_reads_spec.rb`** on its own, every wave. T1's
  AC 4 is the secret boundary and `RedactSecretReads:297` parks through the queue this plan generalizes.
  It is the one assertion that must never go red.
- `bundle exec rspec --tag nvim` — T6 changes every surface the editor renders.
- **`bundle exec rspec spec/lain/*concurrency_spec.rb`** — T4's register makes an exactly-one-settles
  claim, and those specs are the house style for proving one.
- **Manual, human, once per wave:** park an approval and answer it at the terminal; park one and answer it
  in the editor; ask a question and answer it; open a review and settle it. Four gestures, and the plan is
  not done until all four work at every wave boundary. **The suite cannot tell you whether a human can
  actually answer.**
- **Manual, human:** interrupt a run with three open asks and resume it. AC 5 covers this in a spec, but a
  real resume crosses the journal, the fold, the register and the surface at once.
- Update `planning/qa/scenarios/` **at every wave**, not at the end. This plan changes the approval,
  question and review surfaces — `planning/qa/README.md` names which scenario answers which question, and
  several answers change more than once during the sequence.
