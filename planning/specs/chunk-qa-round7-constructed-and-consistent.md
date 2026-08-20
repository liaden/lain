# Wire what was built, and make the next gap loud

status: in-progress
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

Discharge QA round 7 and its `/survey` supplement. Three of the findings are the **same defect
shape** — a capability built, spec'd, and never constructed on the production path
(`Provider::Admission::Journal` and `Review::Docent`; the note rail's acknowledgement is a
**missing** feature rather than an unwired one, and is fixed alongside) — so this
chunk both fixes the instances and adds the guard that makes the next one fail loudly instead of
shipping green. Alongside that it collapses two Faraday extension mechanisms into one, deletes a
dependency-version branch that has been dead since the gemspec pinned `faraday "~> 2.14"`, and
repairs the review surface's messages to the human.

Discharges: `planning/qa-findings-round7-2026-08-20.md` (F28, F29, UX10, and **FG1 by
redirection** — T16 adds `--non-interactive` with an honest exit status; `--prompt` itself keeps
its REPL-seed semantics and still exits 0 on a failed turn, so round 8 should re-file against the
new flag rather than read FG1 as fixed) and
`planning/qa-findings-round7-survey-2026-08-20.md` (F30–F39).

## Grounding

Verified against the working tree on **2026-08-20**, by reading the code rather than the findings:

- **F28 confirmed.** `Provider::Admission.build` (`lib/lain/provider/admission.rb:262-269`) is the
  single construction point and returns `new(...)` or `Null.new(...)` — never wrapped in
  `Admission::Journal`. `grep -rn 'Admission::Journal' lib/` finds only a doc reference in
  `telemetry/provider_wait.rb:84`. Round 7's journals hold **zero** `provider_wait` records.
  `admission.rb:15` states "F26 is the absent concept this fills"; `:216` says "F26, still live".
- **F32 confirmed, and the mechanism is sharper than the finding states.**
  `Review::Handover#initialize` (`lib/lain/review/handover.rb:243`) takes `docent: Unattended` — a
  **Null default** — and all three construction sites omit it:
  `lib/lain/tools/request_review.rb:656`, `lib/lain/cli/command/survey.rb:358`,
  `lib/lain/cli/command/review.rb:258`. `Handover#ask` (`:373`) then delegates to the Null.
- **F30 confirmed.** `define("LainNoteDone")` (`48_annotate.lua:415-416`) calls
  `review_notes.settled()` **outside** the `pcall`; `assert_saved` (`:252-254`) raises via
  `error(...)`. T16's fix wraps only the `vim.rpcrequest` leg.
- **F34 confirmed, and it is a DOC defect too.** `47_diff.lua:8` states "THE NEW SIDE IS THE FILE,
  not a copy of it" — `buftype = ""` deliberately, so LSP and treesitter attach. Focus is set at
  `47_diff.lua:460`. `planning/qa/scenarios/cockpit-surfaces.md:136` claims `x` there "silently does
  nothing because the buffer is `nomodifiable`", which is **false** and instructs drivers to type
  into a real source file. **The code wins; the scenario is wrong.**
- **Faraday v1 is already unreachable.** `lain.gemspec:69` pins `faraday "~> 2.14"`; `Gemfile.lock`
  resolves **2.14.3**; `faraday_1?` is `Faraday::VERSION.start_with?("1")`
  (`provider/http/streaming.rb:164-166`). 10 sites across 4 files. It is dead code, not a shim.
- **`env` is never nil in Faraday 2.** `Faraday::Env#stream_response` (faraday 2.14.3, `env.rb:176`
  and `:179`) calls `request.on_data.call(chunk, size, self)` at both sites. The `env&.status` in
  `v2_on_data` is v1 arity-padding defensiveness — a non-lambda proc pads a missing third arg with
  nil. Deleting v1 makes it dead.
- **Both transports already use `req.options.context`** for a per-request collaborator:
  ollama threads `attempt:` (`ollama/transport.rb:59,80`), anthropic threads `frame:`
  (`anthropic/transport.rb:39,63`). The callers hold the `Lain::Request`
  (`provider/ollama.rb:391,413`). So journaling context is an extension of an existing idiom.
- **F27 was WITHDRAWN on re-test** and is not in this plan. Session commands *do* run at `human>`
  (`wiring.rb:460` binds the registry; `human_replies.rb:1050-1054` dispatches). The real defect is
  F29: `Reply#drained` (`human_replies.rb:1131-1136`) builds a bare reader lambda that consults no
  registry.
- **`STATE_MARKERS` exists twice** — `frontend/neovim/review_view.rb:151` (the nvim surface) and
  `review/surface/text.rb:51` (derived from `Review::FILE_STATES`). A fourth state must not be added
  to one alone.
- **`Verdict::Policy#admit!`** (`review/verdict/policy.rb:35,75,112`) takes `(verdict, changeset:,
  marks:)` — annotations are not among its arguments, which is why a blocker cannot block.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lain.gemspec`,
  `.rubocop.yml`, `spec/spec_helper.rb`, and each unit's index file (e.g. `lib/lain/provider.rb`,
  `lib/lain/tool.rb`) — see the repo CLAUDE.md's Requires rule: a new leaf is added to its unit's
  index, never by a `require_relative` in the leaf itself.
- **`lain.gemspec` needs no Faraday change** — `~> 2.14` is already correct. T18 adds a documented
  nvim minimum, which is prose, not a gemspec dependency.
- Docs-only cards (T20) still take a panel pass, because T20 corrects instructions that caused a
  driver to modify a real file.

## Open decisions

- **Should a skipped oracle journal anything?** `Admission::Journal`'s docstring records that
  `#try_enter` forwards untouched and that a busy endpoint there is a *skip, not a wait*, so it is
  deliberately unjournaled. `Oracle::Eager` is the `try_enter` caller. T5 wires the decorator and does
  **not** change that: an oracle skipped for capacity still leaves no record. Deciding otherwise is a
  follow-up, not this chunk.
- **`Provider::Mock` and `Provider::Recorded` never touch HTTP**, so T4's detector cannot see them.
  Benches and mock-backed specs are guarded by T3's emission only. Deliberate; recorded so a future
  round does not read a clean mock run as proof.
- **`surface/text.rb`'s `STATE_MARKERS`** is derived from `Review::FILE_STATES`, so a fourth state
  added there changes the text surface too. **This is not a blocking decision: T14 owns the call**
  and must record which layer it put the state in on its handback. It is listed here so the choice
  is visible, not so a card waits on it.

## Waves

```
Wave 1: T1, T3, T5, T6, T7, T10, T11, T14, T15, T16, T17, T20   (no unmet deps)
Wave 2: T2 (←T1), T4 (←T3), T8 (←T7), T9 (←T6), T12 (←T11, T6), T13 (←T14), T18 (←T20)
Wave 3: T19 (←T6, T8, T12)
```

Critical path: **T6 → T8 → T19** (wire a docent that answers, acknowledge the note rail, then pin
both with specs in the files those cards own). T6 is also the highest-risk card in the plan.

Several deps are **file-ordering** rather than logical, and are marked as such on the cards:
T13/T14 both edit `review_view.rb`, T8/T7 both edit `48_annotate.lua`, T12/T6 both edit
`cli/command/survey.rb` and `cli/command/review.rb`, T18/T20 both touch `planning/qa/`, and
T19/T8/T12 all edit `handover_spec.rb` and `annotate_spec.rb`, and T9/T6 both edit
`review/surface/neovim.rb`. The **genuine** dependencies are
T2←T1 (the v1 branch must go before the clock moves), T4←T3 (the allowlist names T3's sites) and
T19←T6 (a docent must answer before its exchange can be pinned).

T16 moved to wave 1: the re-cut T3 no longer touches `cli/backend.rb`, so the ordering dep that
held it back is gone.

## Tasks

### T1 — Delete the Faraday v1 branches  [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/provider/http/streaming.rb`, `lib/lain/provider/http/streaming/faraday_handlers.rb`,
`lib/lain/provider/http/streaming/error_handling.rb`, `lib/lain/provider/ollama/transport.rb`
**Reuse:** nothing new — this is deletion. `Faraday::VERSION` is pinned at `~> 2.14` in `lain.gemspec:69`.
**Shared-file wiring:** none
**Reachable from:** the branch being deleted is unreachable today (`faraday_1?` is always false under
the pinned Faraday), so this card removes dead code from the live streaming path
`Provider::Ollama#complete → Transport#stream → FaradayHandlers.build`.

**Acceptance criteria:**

```gherkin
Scenario: the version predicate is gone
  Given the repository after this card
  When lib/ is searched for a Faraday version predicate
  Then no file matches "Faraday::VERSION" outside the gemspec
  And no file references faraday_v1 or faraday_1?

Scenario: streaming still assembles chunks through the v2 handler
  Given a stubbed streaming transport yielding three NDJSON chunks
  When a completion is streamed
  Then the assembled response carries all three chunks in order
```
→ spec file: `spec/lain/provider/http/streaming_spec.rb`, `spec/lain/provider/ollama_spec.rb`

**Escalation triggers:**
- Any existing spec stubs `Faraday::VERSION` or exercises `v1_on_data` directly — that spec is
  asserting the dead branch and must be deleted with it, not adapted; confirm before removing.
- `error_handling.rb:79`'s branch turns out to differ in more than the handler arity — stop, because
  the two legs then are not equivalent and this is not a pure deletion.

### T2 — Move the stall clock onto the Faraday request context  [wave 2] [risk: medium]

**Depends on:** T1
**Files:** `lib/lain/provider/http/streaming/faraday_handlers.rb`,
`lib/lain/provider/http/connection/middleware_stack.rb`
**Reuse:** the `req.options.context` idiom already used for `retry_attempt`
(`ollama/transport.rb:59`) and `wal_frame` (`anthropic/transport.rb:39`);
`Faraday::Env#stream_response` passes `self` to `on_data` at both call sites.
**Shared-file wiring:** none
**Reachable from:** `Provider::HTTP::Connection::MiddlewareStack` builds the stack every provider
connection uses; the clock is installed at `middleware_stack.rb:34` on the live streaming path.

**Acceptance criteria:**

```gherkin
Scenario: two concurrent streams each tick their own clock
  Given two streaming completions in flight as sibling tasks on one reactor
  When chunks arrive interleaved on both
  Then neither stream's stall clock fires
  And each clock records only its own stream's chunks

Scenario: a stalled stream is still torn down by name
  Given a streaming completion whose upstream stops sending after the first chunk
  When the grace period elapses
  Then the turn is torn down reporting a stalled stream with the silent duration

Scenario: fiber storage is no longer used for the clock
  Given the repository after this card
  When faraday_handlers.rb is searched
  Then it contains no Fiber[] access for the stall clock
```
→ spec file: `spec/lain/provider/http/streaming/faraday_handlers_spec.rb`

**Escalation triggers:**
- `on_data` is observed receiving a nil `env` at runtime — **STOP**. The whole card rests on
  `stream_response` always passing `self`; a nil means an adapter is in play that does not, and
  leaving the clock on fiber storage is correct rather than migrating it.
- `stream_response`'s `on_data.call(+'', 0, self) unless yielded` (an empty chunk when nothing was
  yielded) turns out to tick the clock as liveness — decide explicitly and record which, because it
  changes what "no bytes" means.
- Any spec asserts `StallClock.current` as a public entry point — that surface disappears here.

### T3 — Journal the oracle tiers' model round trips  [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/provider/journaled.rb` (new), `lib/lain/cli/backend/summarizer.rb`,
`lib/lain/cli/backend/span_summarizer.rb`, `lib/lain/oracle/secret_read.rb`,
`spec/lain/provider/journaled_spec.rb` (new)
**Reuse:** `Telemetry::RequestSent.from` (`telemetry/turn_stream.rb:190`) — it reads `#digest`,
`#cache_payload`, `#prefix_digests`, none of which survive serialization, which is why this rides
above the wire. Decorator shape from `Provider::Admission::Journal` and `Provider::Admitted`.
`Oracle::SecretRead.tier` (`oracle/secret_read.rb:131`) **already takes a `journal:` keyword**.
**Shared-file wiring:** `require_relative "provider/journaled"` in `lib/lain/provider.rb`'s index
(orchestrator applies).
**Reachable from:** the three sites that build an oracle's model tier —
`CLI::Backend::Summarizer#tier` (`backend/summarizer.rb:52-53`),
`CLI::Backend::SpanSummarizer#tier` (`backend/span_summarizer.rb:108`), and
`Oracle::SecretRead.tier` (`oracle/secret_read.rb:131`, reached in production from
`cli/wiring.rb:139` behind `--secret-oracle`). Each wraps the provider it hands `Oracle::Model`.

**Scoped to the ORACLE tiers deliberately, and NOT to `Backend#provider`.** Three reasons, all
verified: `Backend#provider` (`backend.rb:198`) has **no `journal:` parameter**, and
`summarizer_provider` (`:217`) forwards only `queue:` — its docstring refuses the chat's spool and
channel because "an oracle round trip is not a turn". `channel:` is the live frontend stream, not a
journal, so routing records through it would paint oracle traffic onto the human's screen. And
`middleware/journal_requests.rb:7-16` states that **whether** to record requests is a per-experiment
wiring decision a bench arm opts into — wrapping every provider would hand every bench arm records
it never asked for and double them for arms that already opt in
(`bench/cli/run_recorder.rb:65`, `bench/variance_fixtures.rb:124`, both deliberately innermost).
The agent turn is already journaled by that middleware; the gap F28 measured is the **oracle**.

**Acceptance criteria:**

```gherkin
Scenario: an oracle consulting the model leaves a request_sent
  Given a summarizer tier built through CLI::Backend::Summarizer against a stubbed endpoint
  When the oracle is asked about a span
  Then the journal holds a request_sent whose digest equals that request's own digest

Scenario: the record carries the fields only the Request can supply
  Given an oracle round trip through the journaled provider
  When the request_sent record is read back
  Then it carries the request's cache_payload and prefix_digests unchanged

Scenario: the secret-read oracle journals to the journal it was handed
  Given Oracle::SecretRead.tier constructed with a real journal
  When it consults the model about a candidate
  Then that journal holds a request_sent for the round trip
  And the record does not land on the frontend channel

Scenario: a bench arm that opted out records nothing extra
  Given a bench arm whose model_middleware does not include JournalRequests
  When it runs a turn
  Then no duplicate request_sent is written for that turn
```
→ spec file: `spec/lain/provider/journaled_spec.rb`, `spec/lain/cli/backend/summarizer_spec.rb`,
`spec/lain/oracle/secret_read_spec.rb`

**Escalation triggers:**
- `Oracle::SecretRead`'s docstring says a `provider:` keyword there "is the whole failure this arm
  exists to prevent", and a spec pins its parameter list — so the provider must be wrapped **inside**
  `tier`, never injected. If wrapping cannot be done without widening that signature, **STOP**: the
  security property outranks the telemetry.
- Wrapping a tier double-journals because some caller already threads `JournalRequests` — stop and
  name who owns the record rather than suppressing one side.
- `Backend::Summarizer` and `Backend::SpanSummarizer` both call `summarizer_provider` but need
  opposite `queue:` answers; if wrapping collapses that distinction, the eager oracle starts waiting
  on the turn, which is F26's mechanism. Verify both `#tier` methods separately.

### T4 — Forbid an unjournaled provider construction, mechanically  [wave 2] [risk: low]

**Depends on:** T3 (the allowlist must name the sites T3 establishes)
**Files:** `spec/provider_construction_discipline_spec.rb` (new)
**Reuse:** `spec/output_discipline_spec.rb` — the existing Ripper AST walk over every file in
`lib/`, which already enforces "only the frontend may touch the terminal" the same way. This card
is that idiom pointed at provider construction.
**Reachable from:** the suite. This is a discipline spec, so its "production path" is every file in
`lib/` — it fails the build when a new construction site appears anywhere outside the allowlist.

**This REPLACES the runtime Faraday detector the first draft proposed, and the reason is worth
keeping.** A middleware reading `req.options.context` cannot answer the question: the digest would be
threaded by the **concrete provider**, whether or not `Provider::Journaled` wrapped it, so a call
that bypassed the decorator still carries one. Distinguishing them would need a process-global set of
journaled digests — mutable shared state with no stated owner or reset point. A discipline spec
answers the real question ("can an unjournaled provider be constructed at all?") with no runtime
cost, no ambient state, and it catches the **next** F28 rather than one instance of it.

**Acceptance criteria:**

```gherkin
Scenario: a provider constructed outside the allowlist fails the suite
  Given a file in lib/ that constructs a concrete Provider directly
  When the discipline spec runs
  Then it fails naming that file and line

Scenario: the approved construction sites pass
  Given lib/ as it stands after T3
  When the discipline spec runs
  Then it passes
  And its allowlist names each approved site with the reason it is approved

Scenario: a capability left at its Null default is reported
  Given a construction site that builds a Docent with the default answerer
  When the discipline spec runs
  Then it fails naming that site
```
→ spec file: `spec/provider_construction_discipline_spec.rb`

**Escalation triggers:**
- An allowlist that grows past a handful of entries means the seam is wrong, not that the list needs
  another line — **stop and say so** rather than encoding the sprawl.
- `Provider::Mock` and `Provider::Recorded` are legitimate direct constructions in specs and benches;
  if the walk cannot separate `lib/` from `spec/` cleanly, scope it to `lib/` only and record that
  benches are unguarded.
- The third scenario (Null-default detection) may not be expressible in Ripper without over-matching;
  if so, **drop it from this card and say so on the handback** — a discipline spec that reports false
  positives gets deleted, which is worse than a narrower one.

### T5 — Wire Admission::Journal so endpoint contention is recorded  [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/provider/admitted.rb`, `lib/lain/provider/ollama.rb`,
`lib/lain/provider/anthropic.rb`, `spec/lain/provider/admitted_spec.rb`
**Reuse:** `Provider::Admission::Journal` (already written, already spec'd, never constructed);
`Telemetry::ProviderWait` and its `Guards::ProviderWait` validations.
**Shared-file wiring:** none
**Reachable from:** `Provider::Admitted#admitted`, which every provider calls per round trip. Wrapping
here rather than in `Admission.build` is deliberate: **capacity is process-global (a property of the
server) while the journal is per-session (a property of the caller)**, and the mismatch of those two
lifetimes is exactly why the decorator was never constructed.

**Acceptance criteria:**

```gherkin
Scenario: a caller that queued for a busy endpoint leaves a record
  Given a local endpoint whose only slot is held
  When a second completion queues and then acquires the slot
  Then the journal holds a provider_wait record naming that endpoint and the seconds queued

Scenario: an idle endpoint journals nothing
  Given a local endpoint with a free slot
  When a completion takes the slot on its first attempt
  Then no provider_wait record is written

Scenario: a provider built through the real backend records its wait
  Given a provider built through CLI::Backend against a local endpoint whose only slot is held
  When it queues and then acquires the slot
  Then a provider_wait record naming that endpoint is journaled
```
→ spec file: `spec/lain/provider/admitted_spec.rb`

**Escalation triggers:**
- `Admitted` depends on exactly two messages, `#resolved_endpoint` and `#queue_for_capacity?`
  (`admitted.rb:14-19`). A journal must arrive as a THIRD message on every includer, which is why
  `provider/ollama.rb` and `provider/anthropic.rb` are in Files. If an includer cannot answer it,
  stop rather than reaching for an ivar.
- **`Oracle::SecretRead`'s bare `Provider::Ollama.new` (`secret_read.rb:131`) gets
  `channel: Channel::Null`** — so the internal oracle, the caller F26 is *about*, still journals no
  wait when it is the one that queues. T3 wraps its request journaling; whether its **wait** is
  recorded too is this card's call, and must be stated on the handback.
- *Not* a trigger, recorded so it is not re-derived: the process-global `Admission` registry does
  **not** conflict with a per-session journal. The decorator is applied per call inside
  `#admitted`, so two sessions in one process wrapping one memoised gate are independent.
- `spec/lain/provider/ollama_spec.rb`'s `without_admission` helper pairs a registry reset with
  `ENV_KEY`; if wrapping breaks that helper, fix the helper deliberately rather than skipping it.

### T6 — Wire a Docent that can actually answer  [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/tools/request_review.rb`, `lib/lain/cli/command/survey.rb`,
`lib/lain/cli/command/review.rb`, `lib/lain/review/surface/neovim.rb`
**Reuse:** `Review::Docent` and `Docent::Answerer` (`review/docent.rb:236-238`), whose spawn duck is
`(role, mode, brief)`; **`Command::Env#role_spawn`** (`cli/command/env.rb:8`, used at
`cli/command/meta.rb:123`) satisfies that duck exactly, and `env.chronicle` is the journal. The view
duck is `#show(anchor, entries)` (`docent.rb:436`), which `Frontend::Neovim::ThreadView` answers —
held privately as `@thread_view` at `review/surface/neovim.rb:263`.
**Shared-file wiring:** none
**Reachable from:** the three `Review::Handover.new` sites — `cli/command/survey.rb:358` (the one
`/survey` reaches, and the site an AC must drive), `cli/command/review.rb:258`,
`tools/request_review.rb:656`.

**⚠️ CONSTRUCTING A DOCENT IS NOT ENOUGH, AND THIS IS THE CARD'S WHOLE POINT.**
`Docent#initialize` (`review/docent.rb:286`) is
`(changeset:, view:, answerer: Unanswerable, journal: Channel::Null.instance, ...)`. `Unanswerable`
(`:205-211`) returns `Tool::Result.error(NOT_WIRED)` for every question. So
`Docent.new(changeset:, view:)` is a fully constructed Docent that refuses everything — passing any
AC phrased "a docent was constructed" or "it is not `Handover::Unattended`". **That would be F32
re-shipped one Null deeper.** `Unanswerable` and `Channel::Null` are FORBIDDEN end states for this
card; the ACs below assert an answer comes back and is recorded.

**Acceptance criteria:**

```gherkin
Scenario: a question about a hunk reaches the spawn seam
  Given a survey handover built through the /survey command path
  When a thread question is asked against an anchor
  Then the role spawn is called with the docent's role, its mode and the brief

Scenario: the answer comes back and is rendered
  Given a survey handover whose spawn seam answers with a successful Tool::Result
  When a thread question is asked
  Then the answer is shown on the thread view for that anchor

Scenario: the exchange is journaled
  Given a survey handover built through the /survey command path
  When a question is asked and answered
  Then the journal holds the docent-asked and docent-answered records for that anchor

Scenario: a review with no docent still refuses by name
  Given a handover constructed without a docent
  When a question is asked
  Then it refuses with the existing unattended sentence
```
→ spec file: `spec/lain/cli/command/survey_spec.rb`, `spec/lain/review/docent_spec.rb`

**Escalation triggers:**
- **The `view:` half is the genuinely unresolved seam.** `env.replies.review_view` answers a
  `ReviewView`, a DIFFERENT duck from the `#show(anchor, entries)` Docent needs; the right object is
  the `ThreadView` held privately at `surface/neovim.rb:263`. If exposing it means widening
  `Surface::Neovim`'s public surface, **stop and confirm** — a docent drawing into the wrong pane is
  worse than one that refuses. (`answerer:` and `journal:` are NOT blocked: `role_spawn` and
  `chronicle` are already on `Command::Env`.)
- A headless `/review` (no editor) has no thread view at all; that path must keep refusing rather
  than construct a docent that cannot render. Confirm which Null it gets.
- `Handover::NO_DOCENT` (`handover.rb:120`) is asserted by an existing spec as the expected state of
  a real review — that spec encodes the defect and must be re-aimed deliberately.

### T7 — Deliver every review-rail refusal without raising  [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/frontend/neovim/runtime/48_annotate.lua`,
`lib/lain/frontend/neovim/runtime/51_thread.lua`
**Reuse:** `_G.__lain.review_refused` — the rail `65_review.lua`'s `:LainReviewDone` and
`46_sidebar.lua`'s `:LainReviewVerdict` already answer on, described at `48_annotate.lua:405-414`.
**Shared-file wiring:** none
**Reachable from:** `:LainNoteDone` and the thread pane's `BufWriteCmd`, both bound at cockpit attach
and reachable by the keys the review banner teaches.

**Acceptance criteria:**

```gherkin
Scenario: settling notes over an unsaved buffer refuses without a traceback
  Given a review with an unsaved modified diff buffer and a placed note
  When :LainNoteDone runs
  Then the refusal names the unsaved file and the reason
  And no stack traceback is produced
  And a subsequent RPC call answers within the timeout

Scenario: the thread pane's write refusal does not block the editor
  Given a thread pane with nothing newly typed
  When :w runs
  Then the refusal is delivered on the review rail
  And a subsequent RPC call answers within the timeout
```
→ spec file: `spec/lain/frontend/neovim/annotate_spec.rb`, `spec/lain/frontend/neovim/rpc_thread_spec.rb`
(`thread_view_spec.rb` covers the view half; there is no `thread_spec.rb` and one must not be
created — CLAUDE.md forbids sharding a spec away from its subject's mirrored path)

**Escalation triggers:**
- `51_thread.lua:616`'s `error()` has a **real** reason — a `BufWriteCmd` must fail for `:w` to
  report failure. Removing it wholesale would make a failed write look successful. Only `:610` is
  clearly wrong (the buffer is unmodified there). **Stop and confirm** before changing `:616`.
- Any spec asserts a traceback or `Press ENTER` as the expected delivery — that spec pins the defect.
- High risk because this is a **refusal path that currently locks the editor**: a wrong fix makes a
  refusal silent, which is worse than a loud one.

### T8 — Acknowledge a note handback, and say when there is nothing to send  [wave 2] [risk: medium]

**Depends on:** T7 (same file: `48_annotate.lua`)
**Files:** `lib/lain/frontend/neovim/runtime/48_annotate.lua`,
`lib/lain/frontend/neovim/rpc_thread.rb`
**Reuse:** `Surface::Neovim::MARKED` (`review/surface/neovim.rb:204`) as the precedent for how an
acknowledgement is posted, and `_G.__lain.review_refused` (`48_annotate.lua:405-414`) as the message
rail. **NOT `Review::Surface.acknowledge`** — that is `surface.settle(verdict)`
(`review/surface.rb:293`), a verdict-terminal helper whose whole docstring is about a durable
verdict being misreported; a note batch has no `settle` semantics and must not be routed through it.
**Shared-file wiring:** none
**Reachable from:** `:LainNoteDone` on the live cockpit rail, via `rpc_thread.rb`'s `notes` handler
(`:594-601`).

**Acceptance criteria:**

```gherkin
Scenario: a successful handback says what it sent
  Given four notes placed on a review
  When :LainNoteDone settles them
  Then the human is told how many notes were handed back
  And the markers are cleared only after that acknowledgement

Scenario: an empty handback says there was nothing to send
  Given a review with no placed notes
  When :LainNoteDone runs
  Then the human is told nothing was pending
  And no note records are written
```
→ spec file: `spec/lain/frontend/neovim/annotate_spec.rb`

**Escalation triggers:**
- An empty batch is currently *legal* on the Ruby side (`rpc_thread.rb:594-601` returns nil for
  `[]`), so "nothing pending" may need to be decided in Lua before the RPC rather than refused in
  Ruby — confirm which side owns it before writing a refusal into the wire protocol.
- Erasing markers before the acknowledgement lands is the current order; reordering it must not make
  a failed handback leave markers the Ruby side already consumed.

### T9 — Name the row in a mark acknowledgement  [wave 2] [risk: low]

**Depends on:** T6 as a **file-ordering** dep — both edit `lib/lain/review/surface/neovim.rb`
(T6 exposes the thread view for the docent; this card changes the mark acknowledgement)
**Files:** `lib/lain/review/surface/neovim.rb`
**Reuse:** `PARTLY_MARKED` (`surface/neovim.rb:214`) already aggregates a multi-unit row into ONE
sentence — the same shape this card needs for the success path.
**Shared-file wiring:** none
**Reachable from:** `Review::Surface::Neovim#mark` (`:306`), reached by the `x` key the review banner
teaches.

**Acceptance criteria:**

```gherkin
Scenario: marking a single-unit row names the file
  Given a review row for lib/counter.rb with one unit
  When the row is marked reviewed
  Then the acknowledgement names lib/counter.rb rather than a content hash

Scenario: marking a multi-unit row acknowledges once
  Given a review row whose file partitions into two units
  When the row is marked reviewed
  Then exactly one acknowledgement is posted
  And it states that both units were marked
```
→ spec file: `spec/lain/review/surface/neovim_spec.rb`

**Escalation triggers:**
- `MARKED`'s `%<hunk_key>s` is consumed by another surface or by a spec asserting the hash form —
  the key may be load-bearing for a gesture that resolves back to a unit; check before replacing it
  rather than shadowing it.
- **`Session#mark` (`session.rb:355-356`) has TWO callers**: `Surface::Neovim#marked` (`:344`, per
  key from `#marked_at`'s map at `:385`) and `Handover#mark` (`handover.rb:393`). Making `#mark`
  silent so `marked_at` can post one summary would silently remove the Handover path's
  acknowledgement and diverge `Surface::Neovim` from `Surface::Text`, which
  `spec/support/shared_examples/review_surface.rb` covers as a port contract. **Stop** if the fix
  requires changing `#mark` itself.

### T10 — Land review focus in the sidebar, not the file  [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/frontend/neovim/runtime/47_diff.lua`
**Reuse:** the existing three-window layout; `47_diff.lua:460`'s `nvim_set_current_win` is the single
line that decides focus.
**Shared-file wiring:** none
**Reachable from:** `:LainReviewOpen`, bound to `<CR>` at `46_sidebar.lua:240`.

**Acceptance criteria:**

```gherkin
Scenario: opening a row leaves the cursor on the sidebar
  Given a review sidebar with the cursor on a row
  When <CR> opens that row
  Then the tab holds sidebar, OLD and NEW windows
  And the current window is the sidebar

Scenario: the NEW window is still the real editable file
  Given a row opened from the sidebar
  When the NEW buffer is inspected
  Then its buftype is empty so language tooling still attaches
```
→ spec file: `spec/lain/frontend/neovim/diff_mode_spec.rb` (`47_diff.lua`'s real home; there is no
`diff_spec.rb` and one must not be created)

**Escalation triggers:**
- An existing spec or the scenario's focus discipline asserts `winnr() == 3` after `<CR>` — that
  assertion encodes the defect and must be re-aimed together with
  `planning/qa/scenarios/cockpit-surfaces.md` (T20 owns the doc half).
- Making NEW non-editable instead is **out of scope and wrong**: `47_diff.lua:8` records that
  `buftype = ""` is deliberate. If a reviewer proposes it, escalate.

### T11 — Let a blocker block an approve verdict  [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/review/verdict/policy.rb`, `lib/lain/review/session.rb`
**Reuse:** `Review::Session` is where the annotations already live (`session.rb:217`, `:291`,
`:386`) and is `admit!`'s **only caller** (`session.rb:425`) — `handover.rb` never calls it. The existing annotation kinds (`note` / `blocker`) already carried to the journal and
rendered as markers; `Verdict::Policy`'s three `admit!` implementations (`:35`, `:75`, `:112`).
**Shared-file wiring:** none
**Reachable from:** `:LainReviewVerdict approve` on the cockpit rail, through
`Review::Handover`'s verdict path into `Verdict::Policy#admit!`.

**Acceptance criteria:**

```gherkin
Scenario: an unresolved blocker refuses approve by name
  Given a fully marked changeset carrying one unresolved blocker annotation
  When approve is submitted
  Then it is refused naming the blocker's file and line
  And the review is not settled

Scenario: a plain note does not block
  Given a fully marked changeset carrying only note annotations
  When approve is submitted
  Then the review settles as approved

Scenario: a permissive policy still admits over a blocker
  Given a session opened with the permissive verdict policy
  When approve is submitted over an unresolved blocker
  Then the review settles as approved
```
→ spec file: `spec/lain/review/verdict/policy_spec.rb`, `spec/lain/review/handover_spec.rb`

**Escalation triggers:**
- `admit!`'s signature is `(verdict, changeset:, marks:)` across three implementations including a
  Null; adding annotations changes all three AND its one caller at `session.rb:425`. If any
  implementation lives outside `policy.rb`, stop and enumerate them first.
- "Resolved" has no representation today. If a blocker cannot be marked resolved, this card creates a
  state a human cannot leave — **escalate rather than shipping a dead end**; the minimum viable answer
  may be that removing the annotation resolves it.

### T12 — Offer a remedy the human can actually reach  [wave 2] [risk: low]

**Depends on:** T11; and T6 as a **file-ordering** dep — both edit `cli/command/survey.rb` and
`cli/command/review.rb`
**Files:** `lib/lain/review/handover.rb`, `lib/lain/cli/command/survey.rb`,
`lib/lain/cli/command/review.rb`
**Reuse:** `/survey`'s existing flag set (`cli/command/survey.rb:65,71,77` — `--scope`,
`--unbounded`), which is where a reachable override belongs.
**Shared-file wiring:** none
**Reachable from:** the partial-verdict refusal text, produced on the `:LainReviewVerdict` rail.

**Acceptance criteria:**

```gherkin
Scenario: the refusal names only remedies a human can perform
  Given a partially reviewed changeset
  When approve is refused
  Then the message names the unreviewed files and an editor gesture or a command flag
  And it does not name a Ruby constructor

Scenario: the named flag actually admits the verdict
  Given a survey started with the permissive flag this card names
  When approve is submitted over a partially reviewed changeset
  Then the review settles
```
→ spec file: `spec/lain/review/handover_spec.rb`, `spec/lain/cli/command/survey_spec.rb`

**Escalation triggers:**
- If no flag is added, the refusal must stop promising an override at all rather than naming an
  unreachable one — decide explicitly and say which in the card's handback.

### T13 — Name out-of-root rows by the surveyed root  [wave 2] [risk: low]

**Depends on:** T14 (same file: `review_view.rb`)
**Files:** `lib/lain/frontend/neovim/review_view.rb`
**Reuse:** `legible(file.path)` at `review_view.rb:498`, the single site that renders a row's path.
**Shared-file wiring:** none
**Reachable from:** `/survey <absolute path>` outside the project root, rendering into
`lain://review`.

**Acceptance criteria:**

```gherkin
Scenario: a survey outside the project root names rows by the surveyed tree
  Given a survey of an absolute path outside the project root
  When the sidebar is rendered
  Then each row names its path relative to the surveyed root
  And no row begins with a parent-directory traversal

Scenario: a survey inside the project is unchanged
  Given a survey of ./lib inside the project
  When the sidebar is rendered
  Then rows read as they did before this card
```
→ spec file: `spec/lain/frontend/neovim/review_view_spec.rb`

**Escalation triggers:**
- A row's path is also the key a gesture resolves back through — if changing the rendered path
  changes what `<CR>` or `x` resolves, **stop**: the display name and the resolution key must be
  separated first.

### T14 — Give a hunkless row a marker of its own  [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/frontend/neovim/review_view.rb`
**Reuse:** `STATE_MARKERS` (`review_view.rb:151`); `Marks#state_of`'s documented rule at
`review/marks.rb:203-205` ("an empty batch answers `:unreviewed`"), which this card does **not**
change — only its rendering.
**Shared-file wiring:** none
**Reachable from:** any `/survey` whose tree contains an empty file, rendered into `lain://review`.

**Acceptance criteria:**

```gherkin
Scenario: a file with no hunks carries its own marker
  Given a survey containing an empty file
  When the sidebar is rendered
  Then that row carries the hunkless marker this card introduces
  And it is distinguishable from both the reviewed and the unreviewed markers

Scenario: an approved review shows no unreviewed rows
  Given a changeset with one empty file and all other rows marked
  When approve settles the review
  Then no row in the sidebar reads as unreviewed
```
→ spec file: `spec/lain/frontend/neovim/review_view_spec.rb`

**Escalation triggers:**
- If the fourth state is added to `Review::FILE_STATES` rather than to the nvim renderer alone, it
  also changes `review/surface/text.rb:51`, which derives its markers from that constant — decide
  which layer owns "nothing to review here" and state it (this is in **Open decisions**).

### T15 — Let a tool precondition name its subject  [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/tool/contracts.rb`, `lib/lain/tools/edit_file.rb`, `lib/lain/tools/write_file.rb`
**Reuse:** `Tool::Bounds`' message construction (`tool/bounds.rb:191`), which already interpolates the
real subject at call time — this card gives contracts the same capability.
**Shared-file wiring:** none
**Reachable from:** every `edit_file` / `write_file` precondition refusal the model receives, through
`Tool#call → check_preconditions!`.

**Acceptance criteria:**

```gherkin
Scenario: a windowed-read refusal names the file
  Given a file read only through an offset/limit window
  When edit_file is called on it
  Then the refusal names that file's path
  And it still names the remedy of re-reading with a full-cover window

Scenario: a static message still works
  Given a precondition declared with a plain string message
  When it fails
  Then the refusal reads exactly that string
```
→ spec file: `spec/lain/tool/contracts_spec.rb`, `spec/lain/tools/edit_file_spec.rb`

**Escalation triggers:**
- `requires` is used by tools beyond `edit_file`/`write_file`; a signature change must stay backward
  compatible with static strings, or every caller is in scope and this card is mis-sized.
- `planning/qa/scenarios/failure-injection.md` §9 records the current sentence **verbatim** as the
  expected string. T20 owns updating it; if the wording changes, the two must land together.

### T16 — Add a `--non-interactive` mode that refuses to block on a human  [wave 1] [risk: medium]

**Depends on:** none
**Files:** `exe/lain`, `lib/lain/cli/repl.rb`, `lib/lain/cli/backend.rb`
**Reuse:** the existing posture vocabulary (`Mode::Posture`, `deny_all` / `queue` / `approve_all`,
`cli/switchboard.rb:133`); `Repl#converse`'s `first_prompt` seam (`repl.rb:55-58`).
> Wave 1 despite touching `cli/backend.rb`: the re-cut journaling card no longer edits that file, so
> the file-ordering dep that previously held this card back is gone.
**Shared-file wiring:** none
**Reachable from:** `lain chat --non-interactive` on the CLI, through `CLI::Backend` into the Repl.

**Acceptance criteria:**

```gherkin
Scenario: a turn that fails is reported in the exit status
  Given a non-interactive chat against an unreachable endpoint
  When the run finishes
  Then the process exits non-zero

Scenario: a completed ask exits zero
  Given a non-interactive chat against a stubbed endpoint that answers
  When the run finishes
  Then the process exits zero

Scenario: a request for human input refuses rather than parking
  Given a non-interactive chat
  When the model calls ask_human
  Then the tool refuses by name explaining no human is attached
  And the session does not block waiting for input
```
→ spec file: `spec/lain/cli/repl_spec.rb`, `spec/lain/cli/up_spec.rb`

**Escalation triggers:**
- `--prompt` must keep its current seed semantics — T17's `/btw` child chat depends on
  seed-then-continue. If `--non-interactive` cannot be added without changing `--prompt`,
  **stop and confirm**.
- Approvals under this mode are undecided between "deny every gated call" and "refuse at launch if
  any tool requires approval" — pick one, state it on the handback, and do not silently auto-approve.
- Pass `debug: true` to any Thor `.start` in a spec — a `SystemExit` inside an example truncates the
  run while still reporting 0 failures (repo CLAUDE.md).

### T17 — Consult the command registry in the inbox drain  [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/cli/human_replies.rb`
**Reuse:** `Reply#typed`'s existing classification (`human_replies.rb:1050-1054`) — `prose?`, then
`serves_replies?`, then `@commands.dispatch`. This card gives the drain the same classification
rather than a second one.
**Shared-file wiring:** none
**Reachable from:** `/inbox` typed at a `human>` prompt with a question parked, through
`Reply#drained` (`:1131-1136`).

**Acceptance criteria:**

```gherkin
Scenario: a session command typed into the inbox drain runs
  Given a parked question and an open inbox drain
  When /status is typed
  Then the status is rendered
  And no answer is recorded for the parked question

Scenario: prose typed into the drain still answers
  Given a parked question and an open inbox drain
  When ordinary prose is typed
  Then it is recorded as the answer to that question

Scenario: an unknown slash word does not silently become an answer
  Given a parked question and an open inbox drain
  When an unregistered /word is typed
  Then it is refused by name rather than sent to the model
```
→ spec file: `spec/lain/cli/human_replies_spec.rb`

**Escalation triggers:**
- The drain reads through `@tty.drain_inbox` with a raw reader lambda; if the registry cannot be
  threaded without `Frontend::TTY::Inbox` learning about commands, **stop** — the seam may belong in
  the reader rather than the drain.
- `spec/reply_surface_discipline_spec.rb` exists and may pin exactly one reply path; check it before
  adding a second classification site.

### T18 — Declare nvim 0.11 as the minimum and delete the capability probe  [wave 2] [risk: low]

**Depends on:** T20 (which owns every `planning/qa/` edit, including deleting the 0.10
degradation note this card makes false)
**Files:** `lib/lain/frontend/neovim/runtime/65_review.lua`, `README.md` (or the repo's stated
requirements doc)
**Reuse:** nothing — this is deletion plus a stated requirement.
**Shared-file wiring:** none
**Reachable from:** the refusal rail in `65_review.lua`, which every review refusal passes through.

**Acceptance criteria:**

```gherkin
Scenario: the refusal rail no longer probes for the option
  Given the repository after this card
  When 65_review.lua is searched
  Then it contains no exists("&messagesopt") probe

Scenario: a long refusal still folds to one line
  Given a refusal longer than the message line
  When it is delivered on the review rail
  Then one fitted line is shown
  And the unfolded sentence is recorded to :messages
```
→ spec file: `spec/lain/frontend/neovim/neovim_runtime_spec.rb` (`65_review.lua`'s home, alongside
`refusal_width_discipline_spec.rb`; there is no `review_spec.rb`)

**Escalation triggers:**
- **`spec/lain/frontend/neovim_runtime_spec.rb:1470`** is `it "neither errors nor pages on an nvim
  too old to have 'messagesopt'"`, stubbing the probe at `:1489`. That example asserts the branch
  this card deletes: it must be **deleted with it, not adapted** — confirm before removing, exactly
  as T1 does for the Faraday specs.
- The minimum version is a **user-visible requirement**, unlike the Faraday deletion. State it in
  `README.md`'s existing nvim section (`:363-400`), not in a Lua comment.
- `planning/qa/method.md` carries a 0.10 degradation note that T20 deletes. Under
  `orchestrator-commits` the two land together; if T20 is dropped, **stop** rather than shipping a
  method that documents a degradation path the code no longer has.

### T19 — Pin the survey note-anchor path with specs  [wave 3] [risk: medium]

**Depends on:** T6 (the docent must answer before its exchange can be pinned), T8 and T12 as
**file-ordering** deps — they hold `annotate_spec.rb` and `handover_spec.rb` in wave 2
**Files:** `spec/lain/review/handover_spec.rb`, `spec/lain/frontend/neovim/annotate_spec.rb`
**Reuse:** the behaviour round 7's survey pass measured and confirmed working — notes placed at lines
5, 9, 2, 3 arriving in **placement** order with `drifted` present on every one; the three note kinds
and their markers; `spec/support/shared_examples/review_surface.rb`'s port contract.
**Shared-file wiring:** none
**Reachable from:** these are specs over the production `/survey` handover path T6 wires — the
placement-order example must drive a handover built the way `cli/command/survey.rb:358` builds one,
not an injected double.

**These are the REAL homes, and no new spec file is created.** An earlier draft of this card
proposed `spec/lain/review/anchor_spec.rb` as new; it has existed since 2026-08-04, is 10 KB, and
specs `Review::Anchor` — a different subject. The behaviours here belong to the handover and the
annotate rail, and CLAUDE.md forbids sharding a spec away from its subject's mirrored path.

**Acceptance criteria:**

```gherkin
Scenario: notes arrive in placement order, not positional order
  Given notes placed on lines 5, 9, 2 and 3 of one file
  When they are handed back through a handover built the way /survey builds one
  Then the records appear in placement order

Scenario: every note carries its anchor and drift state
  Given a note placed on a known line
  When it is handed back
  Then its record names side, revision, path and line
  And it reports whether the anchor drifted

Scenario: each note kind renders its own marker
  Given one note and one blocker placed on a file
  When the diff is rendered
  Then each carries the marker for its kind
```
→ spec file: `spec/lain/review/handover_spec.rb`, `spec/lain/frontend/neovim/annotate_spec.rb`

**Escalation triggers:**
- Round 7 drove this against a **corpus** survey only, where OLD is empty by construction. If a
  git-backed changeset behaves differently for drift, that is a finding, not a spec to bend —
  escalate rather than encoding the corpus behaviour as the contract.
- If a spec needs a real editor to assert marker placement, it belongs at `:seam` and must carry the
  tag, not be doubled into meaninglessness.
- T8 and T12 edit these same two files in wave 2. If either left them in a state where these
  examples cannot be added without rewriting theirs, **stop and hand back to the orchestrator**.

### T20 — Correct the QA scenarios and the manual-qa skill  [wave 1] [risk: low]

**Depends on:** none
**Files:** `planning/qa/scenarios/cockpit-surfaces.md`, `planning/qa/method.md`,
`planning/qa/README.md`, `.claude/skills/manual-qa/SKILL.md`
**Reuse:** the round 7 findings docs as the source of every correction.
**Already done by the planner — do NOT repeat:** `planning/qa/README.md`'s Findings list already
links both round-7 documents and this chunk spec. This card edits that file only for the coverage
notes its ACs name.
**Shared-file wiring:** none
**Reachable from:** these are the instructions every future QA round follows — the "production path"
here is a human driving a round.

**Acceptance criteria:**

```gherkin
Scenario: the scenario no longer tells a driver to type into a real file
  Given cockpit-surfaces.md after this card
  When section 4's focus discipline is read
  Then it states that the NEW window is the real editable file
  And it does not claim the buffer is nomodifiable

Scenario: the survey sections are marked as newly covered
  Given the QA README after this card
  When the coverage notes are read
  Then they record that section 4b was first driven on 2026-08-20
  And they name :LainReviewDone as the rail still undriven

Scenario: the method records the traps round 7 hit
  Given method.md after this card
  When its trap list is read
  Then it warns that /inbox opens a drain in which the next line is an answer
  And it warns that a mistyped env grep returns nothing and reads like a leak
```
→ spec file: none — docs-only; verified by the integration checks below.

**Escalation triggers:**
- If T10 changes where focus lands, §4's focus discipline must describe the **new** behaviour, not
  the old — this card and T10 must agree; escalate if T10 is deferred.
- If T15 changes the `edit_file` refusal wording, `failure-injection.md` §9's verbatim expected
  string must change in the same commit or the next round will file a false regression.

## Integration checks

After the last wave:

1. `bundle exec rake pspec` green, and the **example count** compared against a pre-chunk baseline —
   a `SystemExit` in a Thor spec truncates a run while reporting 0 failures (repo CLAUDE.md).
2. `bundle exec rubocop` and `pre-commit run --all-files` clean. Never name a `.toml` on a rubocop
   command line.
3. `cargo test && cargo clippy --all-targets -- -D warnings` if any Rust was touched (none expected).
4. **A reachability audit, because this chunk exists because of that failure mode — and a grep alone
   CANNOT perform it.** For `Provider::Journaled`, `Admission::Journal` and `Review::Docent`, confirm
   each has a construction site in `lib/` that is not a spec **and that every behaviour-carrying
   collaborator at that site is not left at its Null default**. A `Docent.new(changeset:, view:)` has a
   construction site and still refuses every question, because `answerer:` defaults to `Unanswerable`
   and `journal:` to `Channel::Null` — that is the exact shape this chunk exists to end, and a grep
   for the constant cannot tell it from a fix. T4's discipline spec is the mechanical half of this
   check; this step is the human half.
5. **A manual QA pass** — `/manual-qa` covering `cockpit-surfaces` §4 and §4b (to confirm F30, F31,
   F33, F34, F38, F39 behave differently, and to reach `:LainReviewDone`, which round 7 never drove),
   plus `failure-injection` §12 with the proxy to confirm F28's `provider_wait` records now appear.
   This is a human-driven pass and must not be marked done by any card.
6. Confirm the round-7 findings docs are updated with the verdict for each discharged finding, so the
   next round re-checks against fact rather than against this plan's intent.
