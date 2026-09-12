# The cost axis, and the compaction strategies it makes measurable

status: done   (18 cards + 2 unplanned production fixes, landed 2026-08-18)
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman · Aaron Patterson
(Ruby roster, `create-plan/references/rosters.md`)

## Intent

Every cost number this bench has produced for an Opus model is **3× too high**, and the tool output
that dominates a turn's tokens is unbounded in fourteen tools. This chunk corrects the price model,
bounds tool output, ships the first **content-selective** compaction strategies — the ones that make
`elide | summarize` composable instead of an `Overlap` — and joins the two halves of a cache-waste
meter that already exist and have never been connected. Everything here is reachable from `lain
chat`
or `lain friction` on landing. Discharges `planning/hn-agent-landscape-2026-08.md` T1 and Tier-2 #9,
and **CE-6.2** and **CE-6.3** from `planning/specs/cache-economics.md:141-147`.

**It does not satisfy the Context axis row** (`ROADMAP.md:46`), and an earlier draft claimed it did.
That row promises six arms — `prune`, `compact`, `recall placement`, `IVM combinators`,
`cache-aware compaction`, `breakpoint placement` — and this chunk builds none of them outright. What
it adds is the **first two content-selective compact arms** —
which is what `chunk-derived-context-timeline.md:1703-1707` was waiting for when it wrote that the
cut-point lattice becomes useful "the day a run wants elide on tool spans and summarize on
conversational ones".

**It also carries manual-QA round 4's higher-priority findings** (T14-T18), which is a deliberate
widening: the previous two chunks were pure QA hardening, and this one pairs the feature work with
the five findings that a user actually hits. Two are session-killers reachable from an ordinary
`lain chat` — an iteration ceiling that is per-SESSION rather than per-ask, and a second gated tool
call in one turn that never reaches the approval surface at all. They belong beside the cost axis
rather than in a chunk of their own because **three of the five are the same shape as the cost work**:
a surface that is right about the facts and wrong about how it says them. Findings in
[`../qa-findings-round4-2026-08-18.md`](../qa-findings-round4-2026-08-18.md); the procedure that
found them in [`../qa/`](../qa/).

**The masking-vs-summarization replication is deliberately NOT in this chunk** — see Open decision
1.
A probe showed the bench cannot run it, and the plan that claimed otherwise was wrong.

## Grounding

Verified 2026-08-18 by four parallel read-only passes **and one executed probe** (the probe exists
because the first draft of this plan asserted four seams from grep alone and a panel review found
all
four wrong; `planning/hn-agent-landscape-2026-08.md` records the same lesson from a different
angle).

**Pricing is wrong, and the staleness is load-bearing.** `PriceBook::DEFAULTS`
(`lib/lain/price_book.rb:59-63`) prices `"opus"` at 15/75 per MTok; current Opus 5/4.8/4.7/4.6 list
is
**5/25** — 3× overstated, and the derived cache rows with it. `"haiku"` is 0.8/4 against an actual
1/5. The family-token matcher (`price_book.rb:107-110`) resolves every `claude-opus-*` to the wrong
row. Cost is *not* journaled per turn; `Ledger#cost` (`lib/lain/ledger.rb:69-71`) reprices at read
time, so correcting the table retroactively corrects every stored journal — which is why this is a
one-card fix with repo-wide effect.

**Tool output is unbounded almost everywhere, and the four exceptions all cap-and-disclose.** `grep`
and `ast_search` cap at `MAX_MATCHES = 200` *rows* and append `"... capped at 200 matches"`
(`tools/grep.rb:56,293`, `tools/ast_search.rb:26`); `web_fetch` caps at 5 MiB **streaming**,
aborting
the socket read (`tools/web_fetch.rb:304-313`) and labelling the body (`:415`); `ast_dump` caps at
64 KiB in Rust. **Fourteen tools do not bound at all**, including `read_file` (`File.read` at
`tools/read_file.rb:48`), `bash`/`core_exec` (wall-clock timeout only), `glob`, `list_files`,
`web_search`, `code_outline`, `file_symbols`, `test_pattern`, `memory_read`. `Tool::Result`
(`lib/lain/tool.rb:233-263`) carries no size metadata and nothing downstream measures it. The eager
summarizer inlines the **whole** result into the summarizer prompt
(`lib/lain/oracle/summarize.rb:42-50`),
so a 50 MB read becomes a 50 MB prompt, and `Canonical.digest(content)` runs synchronously on the
observing fiber for every result (`effect/handler/summarizing.rb:84`). `arXiv:2508.21433` measures
observation tokens at **~84% of an average agent turn**.

**On the doctrine, corrected.** A first draft claimed `Review::Bounds`, `Question` and
`Sensitivity::Filter` mandate refusal over truncation. Panel review showed that misreads all three:
`Review::Bounds` (`review/bounds.rb:34-36`) bounds *a human's cumulative view*; `Question`
(`question.rb:36-40`) refuses because a clamp can land mid-fence in *markdown a human edits*, and
says clamping belongs at a render; `Sensitivity::Filter` (`sensitivity/filter.rb:12`) objects to
***silent*** truncation and its own design is drop-the-row-**and-count-it** — an argument *for*
disclosure. The house rule that actually holds across `lib/` is **never lose bytes silently**, and
both shapes satisfy it. This chunk therefore adopts **two shapes on a stated boundary** (T4), not
one
rule: enumerations disclose, whole-artifact reads refuse and name a narrower action.

**The compaction seam is sound; the strategies are missing.** Every shipped strategy claims the
whole
span — `Elide#propose_ranges → [span]` (`strategy/elide.rb:77`), same for `Summarizing`
(`strategy/summarizing.rb:173-175`) and `Held` (`source/derived.rb:226`) — so `elide | summarizing`
**always raises `Composed::Overlap`**, pinned at
`spec/lain/compaction/strategy/composed_spec.rb:141`.
The working hybrid exists **only as spec-local anonymous classes** (`composed_spec.rb:57-66`,
end-to-end at `:266-307`), and that fixture defines `tool?` **once** (`:50`) and applies
`.select { |run| run.size > 1 }` (`:76`) so a lone conversational turn is retained rather than
costing
a model call. Both details are load-bearing and are ported, not re-derived. The named registry is
`CLI::CompactionStrategy::STRATEGIES = %w[summarizing elide]` (`cli/compaction_strategy.rb:117`),
built by a `case` at `:159-166`; `Composed` cannot be spelled from argv.

**Where the two halves of a cache-waste meter are, unjoined.** `Bench::Rewrites`
(`bench/rewrites.rb:43-111`) knows *where* the prefix broke; `Ledger::Index` knows the *billed*
`cache_creation` vs `cache_read` per `Telemetry::TurnUsage`. Both key off the Journal and a
`request_sent`/`turn_usage` pair is recorded per turn (`middleware/journal_requests.rb:20`). Nothing
computes waste attribution today. **`rewrites.rb:34-42` states that a model switch is
"indistinguishable from a real prefix edit" and that callers "must segment the journal per arm
before
projecting"** — on a session where `/model` is a normal move that is the common case, so
segmentation
is a requirement of T11, not an edge case.

### What the probe found (2026-08-18, executed against the repo)

Four seams the first draft asserted from grep, all wrong, all confirmed by running Ruby:

1. **Bench arm agents have no tools.** `Bench::SpawnSeam#initialize(..., toolset: Toolset.new([]),
   ...)`
   (`bench/spawn_seam.rb:88`), and `exe/lain:513-515` passes only `system:` and `isolation:`. Every
   `lain bench arms` agent runs with an empty toolset.
2. **Arm runs are single-turn.** `Arm::SingleThread#run` does one `agent.ask(task)`
   (`arm/single_thread.rb:43-56`), with a comment noting that is "*where a multi-turn run would
   leave
   it*" — it does not do one. A one-turn transcript never reaches `Compaction::Need`'s threshold.
3. **`Backend#pipeline_source` is `bind_once` keyed on `journal:`** (`cli/backend.rb:338-345`), and
   every arm mints a fresh `Channel.new` per run (`single_thread.rb:45`, `dual_ledger.rb:102`,
   `orchestrator_worker.rb:146`, `adaptive_router.rb:69`). Reusing it across tasks raises `Rebound`.
4. **The arms grader and `Grader::TestHarness` speak different ducks.**
   `SuiteGrader#grade(timeline)`
   (`bench/cli.rb:401`) scores a `Trajectory` parsed from assistant text; `TestHarness#grade` takes
   `[[:req, :worker_env]]` and shells the suite found by `Adapter.rspec_root?` — *a Gemfile beside a
   `spec/` directory* (`grader/test_harness/adapter.rb:64`), i.e. **whatever specs are in the
   tree**.

Together those four are why the replication is deferred (Open decision 1) rather than attempted
here.

**One panel finding corrected by the probe.** The panel reported `Session#partially_read?` has no
caller in `lib/`; it has one — `session.rb:747`, inside the journaling wrapper's `recorded?`. The
substantive point survives: **no `edit_file` contract consults it**, so a windowed read is refused
with "path was never read this session" (`tools/edit_file.rb:65`), which is a message that sends the
model back to re-read and be refused identically. T3 owns fixing that, and owns `edit_file.rb`.

**Docs vs code, and which won.** `CompactionStrategy::DEFAULT` *is* read, at
`cli/compaction_strategy.rb:146`; what is true is that `SpanSummarizer` short-circuits on nil
(`backend/span_summarizer.rb:48,77`) so the unset path never reaches it and the real unset behaviour
is `Held` over the eager summary snapshot. Code won. `ROADMAP.md:46` lists the Context axis as
swept;
it is not. Code won.

### What manual-QA round 4 found (2026-08-18, driven against the real cockpit)

Seven findings, five folded in here. Every one carries a reproduction in the findings doc; the
mechanisms below are what the cards are grounded on.

**The iteration ceiling is per-SESSION.** `Agent#seed_run_state` (`agent.rb:365`) sets
`@iterations = 0` and is called from `Agent#initialize` (`agent.rb:183`) — **once per Agent**.
`#ask` commits the user turn and calls `#run`; nothing resets the counter between asks. So
`Budget::DEFAULT_MAX_ITERATIONS = 25`, documented as bounding "an autonomous loop"
(`agent/budget.rb:5-13`) and rendered as `loop ran 25 iterations`, is a whole-session budget across
every prompt a human types. Measured: **25 `turn_usage` records over 9 separate user prompts**.
Worse than the limit is what follows it — each later prompt is accepted at `you>`, committed as a
`turn`, immediately followed by `run_interrupted`, and answered with **nothing rendered at all**
while the HUD keeps reading `idle 0s`.

**A second approval in one turn never reaches the chat surface.** The first gated call renders and
is answerable. The next one — arriving after the first tool's streamed output was written to the
pane — renders nothing **and is never read**: `y` and `/approve` are both echoed by the terminal and
neither is consumed, with the process parked in `io_cqring_wait`. It is genuinely pending: the
journal has `approval_pending`, `.lain/state.json` has `approvals_pending=1`, and `lain://approval`
renders the full command. Only `:LainApprove` recovers it — **so on `--no-nvim` and plain
`lain chat` there is no second surface and the session is permanently wedged.** `frontend/tty.rb:229`
and `:243` already document a reader/stdin-ownership race against the countdown ticker and point at
`exe/lain`'s `approval_surface` comment; that is where to start.

**`lain://timeline` renders once and freezes.** `TimelineView#update` (`buffers.rb:117`) fires on
`Telemetry::TurnUsage` and renders the chain from `event.digest`. Reproduced in two independent
sessions: 12 and 7 `turn_usage` records with distinct advancing digests, and the buffer stuck at the
FIRST ask's chain (2 and 4 lines). **Not the drain thread dying** — `lain://request` and
`lain://diff` update live off `Telemetry::RequestSent` through the same `Surfaces#post`
(`surfaces.rb:99-107`), sampled at 1s: `request` moved 762→780→798 while `timeline` never left 2.
**Not a store miss** — that renders `[timeline unavailable: …]` (`buffers.rb:172`), one line.

**Refusals are well-written and delivered as crashes, in two subsystems.** `:LainReviewVerdict` over
a partially-reviewed changeset produces a Lua error with a `stack traceback:` and a blocking
`Press ENTER` modal — from `error(tostring(refusal), 0)` at `46_sidebar.lua:196`. The comment
directly above it (`:183-192`) records the measurement that nvim appends a traceback to anything
escaping a `define`d callback *however raised* — but the sibling command `:LainReviewDone`
(`65_review.lua:115-123`) already dodges it completely by answering through
`_G.__lain.review_refused` and RETURNING instead of raising. **The pattern exists in the same
runtime and this site did not get it**; `48_annotate.lua`'s `:LainNoteDone` is the third instance.
On the Ruby side, `Budget::Exceeded` escaping its `Async::Task` prints
`Task may have ended with unhandled exception` plus 27 frames *before* `CLI::Repl#respond`'s correct
one-line `error: loop ran 25 iterations, ceiling is 25`.

**Three smaller surface dishonesties.** The exhausted-retry line reports `attempt: options.max`
(`provider/ollama/retry_tap.rb:126`, `provider/anthropic/retry_tap.rb:49`) — the RETRY count, not
the ordinal of the attempt that failed — so a counting TCP listener saw **4 real attempts** rendered
as `1, 2, 3, 3`. `JournalView#initial` (`journal_view.rb:23-25`) returns `[""]`, the only view with
no placeholder, against `Surfaces#prime`'s own stated principle that an empty view "reads as
broken"; and it is named `lain://journal` while rendering `Telemetry::ToolOutput` only, never the
NDJSON journal. And `plugin/nvim/lua/lain/init.lua:243` notifies
`lain: not attached yet -- layout opens when 'lain chat --nvim' attaches` and nothing supersedes it
once attach succeeds, so it sits on screen contradicting the live buffers beside it.

**What round 4 confirmed FIXED**, so no card re-does it: the `--num-ctx` trained-maximum refusal,
all five `--api-base` shapes, the connect-timeout collapse (>10min → 26s, and 8s under
`LAIN_CONNECT_TIMEOUT=1`), live retry rendering, per-turn window re-resolution
(`guessed` cold → `probed` warm within one session), the named empty-result messages, the requester
on the approval prompt, the review-verdict acknowledgement, the `options` asymmetry, and both halves
of the torn-record contract (`1 line unparsed` at rest, a named refusal with both digests on use).

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lain.gemspec`,
  `.rubocop.yml`, `spec/spec_helper.rb`, `spec/support/tool_registry.rb`, `exe/lain`,
  `docs/commands.md`, `.pre-commit-config.yaml`, **`spec/algebra_laws_spec.rb`**,
  **`spec/support/algebra_generators.rb`**.
  The last two are shared because `spec/algebra_laws_spec.rb:236-242` asserts no missing **and no
  orphaned** generators, so any card declaring an algebraic property touches a file every other such
  card also touches.
- No deviation from the default review process. Every card is panel-reviewed.

## Open decisions

1. **The masking-vs-summarization replication (`arXiv:2508.21433`) is deferred to a follow-up
   chunk**,
   and the reason is measured, not suspected. Running it needs four things the bench does not have,
   all confirmed by probe: a non-empty toolset on the arm path, a multi-turn arm loop, a real worker
   tree for a suite-based grader, and a grader duck reconciliation (`#grade(timeline)` vs
   `#grade(worker_env)`). Attempting it on today's `bench arms` would report a **clean null that
   looks
   like a finding** — the exact failure `ROADMAP.md:975-983` already records for the
   orchestrator-worker arm. The follow-up chunk is "a bench that can run a real task"; this chunk
   makes the strategies it will compare exist and be selectable.
2. **The 1-hour cache-write multiplier is not modelled.** `CacheProfile` carries a single scalar
   `write_multiplier` of 1.25 (`cache_profile.rb:86-92`); a 1-hour write bills at 2×. But nothing in
   `lib/` writes a `ttl: "1h"` `cache_control`, and `write_multiplier` has exactly one consumer
   (`plan/seam_decision.rb:101`), so modelling it now is a shape change to a pinned public surface
   (`cache_profile.rb:47-77`) for a rate nothing can reach. Recorded as a known under-pricing; the
   card that writes the 1h path owns the multiplier.
3. **Per-model minimum cacheable prefix is not corrected.** `MINIMUM_CACHEABLE_TOKENS = 4096`
   (`cache_profile.rb:36`) is stale — the real minimums are 512/1024/2048/4096 and **non-monotonic
   across generations** (4.6 is 4096 while 4.7 is 2048). Fixing it changes
   `Provider#cache_profile`'s
   signature, which today takes no model (`provider.rb:55`, `provider/anthropic.rb:76`,
   `bedrock.rb:88`) and has five further callers, and needs exact-model keys because `PriceBook`'s
   longest-contained-token matcher cannot express a non-monotonic sequence. **The card is already
   owed and recorded** — `planning/specs/chunk-bench-science.md:57-61` lists "per-model
   `cache_profile` accuracy before T17/T18 trust it" and "relocate `MINIMUM_CACHEABLE_TOKENS` to a
   neutral wire-facts home". Reference that ticket rather than minting a new one; note it also
   invalidates T17/T18's cold-detection accuracy until done.
4. **`Grader::Rubric`'s judge tokens stay off the run's ledger.** `Rubric#grade` drives
   `@provider.complete` directly (`grader/rubric.rb:66`) against a model whose price T1 corrects,
   but
   the judge is not on `Arm::Run`'s Ledger (`lib/lain/arm.rb:81`), so T12's cost column will not
   include it. That makes the omission *visible* for the first time. Recorded as a known gap in
   T12's close-out, not fixed here — fixing it means deciding whether grading cost belongs in an
   arm's cost, which is a bench-science question.
5. **CE-6.3's wall-clock `$/sec` term is NOT in this chunk, and the reason is a shape obstacle worth
   recording.** `cache-economics.md:144-150` asks for "dollars = token-cost + $/sec × wall-clock",
   and
   `Arm::Driver::METRICS` already carries the wall-clock operand. But that registry is
   `{of: <Symbol>, fmt:}` read as `run.public_send(...)` (`arm/driver.rb:66`), and a *total* is not
   a
   message on `Run` — so it needs either a new `Run` field (four construction sites:
   `single_thread.rb:55`,
   `orchestrator_worker.rb:71`, `dual_ledger.rb:113`, `adaptive_router.rb:99`) or a registry
   reshape,
   and a source for the rate that does not exist anywhere today.

   **The reason to defer is design order, not effort.** `ROADMAP.md:1052` (item 21,
   `chunk-review-missing-objects.md`) already owns "**`Compare::Run` widened to a `metrics:` hash
   collapsing five hand-rolled sweep folds**". There are four metric registries in `lib/` today
   (`compare.rb:93`, `arm/driver.rb:22`, `bench/arm_sweep/report.rb:25`,
   `bench/plan_sweep/report.rb:19`) in **two incompatible shapes** — `{label:, reader:, fmt:}` and
   `{of:, fmt:}`. A metric that is a *computed total* rather than a message on `Run` is exactly the
   case those shapes cannot express, so building it before the collapse means building it twice and
   making item 21 strictly larger. **Correct CE-6.3's stated home when it does land**: it says "in
   `Compare`", but `Compare::METRICS` has no wall-clock operand and `Arm::Driver` does.

   T12 accepts a small, deliberate debt against the same item: it adds **one** entry to
   `Arm::Driver::METRICS` in the pre-collapse shape, because a chunk about the cost axis that
   reports
   no cost is not worth landing. One entry is a line for item 21 to move; a computed total is a
   design it would have to undo.
6. **Two adjacent items were drafted into this chunk and then cut on soundness, not on cost.**
   Recorded so they are not re-added by the next reader who notices they look cheap.
   - **A Thor door for `Bench::CLI#arm_sweep_report`** (ROADMAP Deviation 8's remaining half). The
     draft card was wrong about its own subject: `arm_sweep_report` takes **two** paths
     (`tasks_path:, recordings_path:`, `bench/cli.rb:70`) where the card said one, and its docstring
     three lines above says "**no provider, no money, no network**" while the card's escalation
     trigger asked the implementer to go find out whether it spends money. It also declared
     `Files: none` with its only production change in orchestrator-owned `exe/lain` — a card that
     cannot make its own spec green, which is precisely the failure
     `spec/lain/bench/arms_command_spec.rb:33-37` was written to prevent.
   - **A repo lint for `lib/` classes with no production caller** (ROADMAP item 24's "also owed"
     line). `ROADMAP.md:1103-1125` states the triage is "**a review item, not a build item**, and
     the
     answer per unit is a door, a deletion, or a dated reason to keep it dark". A lint shipping with
     ~12 exemptions and zero actionable findings is a rubber stamp, and inventing those twelve
     rulings as a side effect of building the enforcement tool inverts the order. The lint belongs
     to
     the chunk that does the triage. (It also wanted a "deferred-wiring marker" on `Tool::Bounds`
     and
     `ToolMessages` — which no commit could ever read, since both are wired a wave before the lint
     would exist.)
7. **`claude-fable-5` / `claude-mythos-5` remain unpriced** (`UnknownModel`, `price_book.rb:113`),
   and Opus 5 **fast mode** bills at a different rate for the same model id, which
   one-rate-per-model
   cannot express. T1 records both in the table's prose rather than silently leaving them wrong.

## Waves

```
Wave 1: T1, T3, T4, T7, T12, T14, T15   (no unmet deps)
Wave 2: T2 (←T1), T5 (←T3,T4), T6 (←T4), T8 (←T7), T9 (←T7), T11 (←T1), T13 (←T4),
        T16 (←T14), T17
Wave 3: T10 (←T8,T9), T18
```

The QA cards are independent of the cost work and of each other, with one exception: **T16 ←T14**,
because half of T16 is how `Budget::Exceeded` is delivered and T14 changes when it fires. T15 is
wave 1 despite its risk because it is a session-killer on the default path and everything else can
land around it.

Critical path: **T7 → T8 → T10** — the shared predicate, the strategy built on it, and the CLI
spelling that makes it reachable. T7 is rated low but gates three cards; if it slips, wave 2 loses a
third of its width and wave 3 loses its only card.

## Tasks

### T1 — Refresh the stale price rates   [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/price_book.rb`
**Reuse:** `Price.per_mtok` (`price_book.rb:19-22`) and `Price.dollars` (`:27-29`) coerce via
`String`
so `BigDecimal` stays exact — do not introduce Floats. The four-term dot product `Price#cost`
(`:35-40`) is unchanged; only the table's numbers move.
**Shared-file wiring:** none
**Reachable from:** `PriceBook.default` (`price_book.rb:101`) → `Ledger#cost_of`
(`lib/lain/ledger.rb:92-96`), read by `lain ledger` and every bench cost column.

**Acceptance criteria:**

```gherkin
Scenario: an Opus model prices at the current published rate
  Given a Usage of one million input tokens and one million output tokens
  When PriceBook.default costs it for "claude-opus-5"
  Then the input cost is 5 dollars and the output cost is 25 dollars

Scenario: a Haiku model prices at the current published rate
  When PriceBook.default costs one million input tokens for "claude-haiku-4-5"
  Then the input cost is 1 dollar

Scenario: the cache rows stay derived from the corrected input rate
  Then the Opus cache-read rate is one tenth of its input rate
    and the Opus cache-write rate is 1.25 times its input rate
```
→ spec file: `spec/lain/price_book_spec.rb`

**Escalation triggers:**
- `spec/lain/cli/wiring_spec.rb:802` pins `CLI::Backend::COMPACTION_PRICES` producing `"0.0"` via a
  zero fallback for an unlisted model. If correcting `DEFAULTS` changes that string, stop — the zero
  fallback is deliberate policy (`cli/backend.rb:87-100`), not a bug to fix here.
- If any existing spec asserts a **specific dollar figure** derived from the opus row, it encodes
  the
  3× error. Stop and list them rather than silently re-baselining — the corrected figure is the
  point
  of the card and each one deserves a deliberate update.
- Do **not** touch `CacheProfile` in this card. Open decisions 2 and 3 explain why; a card that
  wanders into `cache_profile.rb` has left its scope.

### T2 — Add a price-table freshness lint to the repo   [wave 2] [risk: low]

**Depends on:** T1
**Files:** `bin/lint-price-freshness`, `spec/lain/price_book_spec.rb` (added examples)
**Reuse:** `bin/lint-gherkin-docs` and `bin/lint-commit-msg` are the two existing repo lints — match
their shape, exit codes and output discipline.
**Shared-file wiring:** add a `lint-price-freshness` hook entry to `.pre-commit-config.yaml`
**Reachable from:** `pre-commit run --all-files`, i.e. the git hook every commit runs. Per the
interview ruling this is a **repo lint, not application code** — it must add no runtime check.

**Acceptance criteria:**

```gherkin
Scenario: a price table older than its review horizon fails the lint
  Given a reviewed-on marker dated more than 90 days before the injected clock
  When the lint runs
  Then it exits non-zero, naming the marker and the file to update

Scenario: a current table passes silently
  Given a reviewed-on marker dated at the injected clock
  When the lint runs
  Then it exits zero and prints nothing
```
→ spec file: `spec/lain/price_book_spec.rb`

**Escalation triggers:**
- The spec must drive the lint with an **injected clock**; the hook may read the system clock. If
  the
  only workable design makes a spec pass today and fail in 91 days, stop — a time-bomb spec is worse
  than no lint.
- Record in the marker's prose that Sonnet 5 currently carries an introductory rate through
  2026-08-31 while the table holds the list rate. That is precisely the drift this lint exists to
  catch, and it is live right now.
- If `.pre-commit-config.yaml` runs Ruby local hooks with an interpreter selection different from
  `bin/lint-gherkin-docs`, stop and confirm which is canonical rather than adding a third pattern.

### T3 — Give `read_file` a window, and teach `edit_file` to say why it refuses   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/tools/read_file.rb`, `lib/lain/tools/edit_file.rb`
**Reuse:** `Session#record_read(path, complete:)` (`session.rb:118-121`) already takes the keyword;
`ReadSet` (`:387-424`) is add-only and monotone so a partial read followed by a complete one
upgrades
correctly. `Session#partially_read?` (`:148`) already exists — its only caller today is the
journaling wrapper's `recorded?` (`:747`), and **this card gives it its second**. The masked-read
contract (`edit_file.rb:59-64`) is the shape to copy: a third `requires` with its own message.
**Shared-file wiring:** none
**Reachable from:** the shipped tool roster — `Tools::ReadFile` and `Tools::EditFile` are
constructed
in `lib/lain/cli/wiring/base_tools.rb:15-22` and dispatched by `Agent::ToolRunner#run`
(`agent/tool_runner.rb:87-95`).

**Acceptance criteria:**

```gherkin
Scenario: a windowed read returns only the requested window
  Given a file of 5000 lines
  When read_file is called with offset 2001 and limit 2000
  Then the result contains line 2001 through line 4000 and no line of the file besides
    and one trailing notice says the window is partial and the file continues

Scenario: a window that reaches the end of the file adds no notice
  Given a file of 100 lines
  When read_file is called with offset 1 and limit 100
  Then the result is the whole file with no notice appended

Scenario: editing after only a windowed read is refused, naming the partial read
  Given read_file has returned a window of a file
  When edit_file is called on that file
  Then it refuses with a message naming the partial read, distinct from the never-read message

Scenario: a window covering the whole file counts as a complete read
  Given a file of 100 lines
  When read_file is called with offset 1 and limit 100
  Then edit_file on that file is permitted

Scenario: an unwindowed read of a normal file is unchanged
  Given a file small enough to read whole
  When read_file is called with no offset or limit
  Then the bytes returned are identical to the pre-change behaviour and edit_file is permitted
```
→ spec file: `spec/lain/tools/read_file_spec.rb`, `spec/lain/tools/edit_file_spec.rb`

**Escalation triggers:**
- **The deadlock this card must not create.** T5 refuses an unwindowed read above a cap; if a
  windowed
  read can never complete the read-set, `edit_file` on a large file becomes permanently impossible.
  AC 3 exists to prevent this. If AC 3 turns out unimplementable, **stop** — T5 must not land
  without it.

  **Corrected 2026-08-18 by T3's implementer, and the correction raises the stakes rather than
  lowering them.** This trigger originally said the escape was `write_file`, "which checks
  `masked_read?` only and whole-file-overwrites the very file too big to read". That is wrong:
  `write_file` carries a **second** contract, `"path exists and was never read this session"`
  (`tools/write_file.rb:59-63`), which asks `Session#read?` and is therefore false for a partial
  read. So the feared clobber hatch never existed — what existed was a **dead end**: before this
  card, a windowed read left an existing file with no writing path at all, neither `edit_file` nor
  `write_file`. AC 3 is not one door of two; it is the only door.
- `spec/lain/tools/read_file_spec.rb:23` asserts read_file "reads a file's **full** contents" and
  `:55-95` pins read-set recording. The default path's bytes must not change; if they do, stop.
- The read-before-write contract is a **safety** property. If any existing `edit_file` spec passes
  while a windowed read is recorded, the contract has a hole — report it, do not patch around it.
- `Tool::Input` validations check shape, not safety (`tool/input.rb` header). If an offset/limit
  validator starts reading like a path-safety control, stop.

### T4 — Add `Tool::Bounds`, with two shapes on a stated boundary   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/tool/bounds.rb`
**Reuse:** `Tools::Grep`'s in-band trailer (`tools/grep.rb:293`) is the disclosure precedent;
`WebFetch::ByteCap` (`tools/web_fetch.rb:304-313`) is the **streaming** precedent and the shape to
copy for anything that can refuse before materialising. `Review::Bounds#check_presentation!`
(`review/bounds.rb:29-35`) is the *decision-before-walk* precedent: "the DECISION to refuse is
reached
on a file count alone and never costs a walk over the thing it is refusing to walk over."
**Shared-file wiring:** `require` line in `lib/lain/tool.rb`'s subtree index
**Reachable from:** deferred to T5 and T6, which apply it to the tools. Both are in this chunk and
named here; nothing constructs `Bounds` on the production path until they land.

**The boundary this card states, and every applying card must cite:**
- **Enumerations disclose.** A row-shaped result (matches, paths, symbols, hits) is capped and the
  cap
  is announced in band, exactly as `grep` already does. The model gets a usable partial answer and
  knows it is partial.
- **Whole artifacts refuse.** A single indivisible payload (a file's contents, a command's output)
  is
  refused above its cap, and the refusal names a narrower action. Truncating one is not a partial
  answer, it is a *misleading* one, and the model has a better move available.
- **A window the model asked for discloses too, and it is the cheap case.** Added 2026-08-18 after
  T3's review, which found the chunk about to ship two doctrines. A windowed `read_file` is neither
  an enumeration nor a whole artifact — the model chose the bound — so the first draft let it stay
  silent. But the `complete` bit that decides editability is computed on the way past and then
  thrown away, so a silent window makes the model learn its own partialness by attempting an edit
  and eating a refusal round trip. The disclosure is free: a window knows it is short without a
  total, exactly as `grep`'s `"... capped at 200 matches"` names a cap and never a total. **So it
  discloses when short and says nothing when it covered the file** — a complete window withholds
  nothing and a notice on it would be noise. One rule across the chunk, no exemption.

**Acceptance criteria:**

```gherkin
Scenario: an enumeration within the cap is untouched
  Given an enumeration bound of 200 rows
  When 10 rows are offered
  Then the identical rows are returned with no added text

Scenario: an enumeration over the cap is capped and says so in band
  Given an enumeration bound of 200 rows
  When 5000 rows are offered
  Then 200 rows are returned followed by a notice stating the cap and the true count

Scenario: an artifact over the cap is refused, naming a narrower action
  Given an artifact bound and a caller that supplies narrower alternatives
  When an oversized artifact is offered
  Then an error Result states the actual size, the cap, and at least one narrower action

Scenario: an artifact refusal carries none of the oversized content
  When an artifact is refused for exceeding its bound
  Then the error text contains no bytes from the artifact

Scenario: the refusal decision can be made from a size alone
  Given only a byte count and a bound
  Then the decision is answerable without the content being present
```
→ spec file: `spec/lain/tool/bounds_spec.rb`

**Escalation triggers:**
- If an implementation wants to include a preview of the refused artifact "to be helpful", stop —
  that is truncation wearing a refusal's clothes and it re-introduces the silent-loss failure.
- `spec/lain/middleware/withhold_secret_paths_spec.rb:287-290` and
  `spec/lain/sensitivity/filter_spec.rb:37-44` both pin that grep's `... capped at 200 matches`
  trailer **survives secret filtering**. If the enumeration shape changes that string, stop — those
  specs pin the interaction between bounding and secret filtering.
- The last AC is the one that makes T5's memory claim possible. If `Bounds` can only answer once it
  holds the content, say so and stop: T5's `read_file` and `bash` cards depend on deciding from
  `File.size` and a streaming counter respectively, not from a materialised String.

### T5 — Bound the whole-artifact tools   [wave 2] [risk: high]

**Depends on:** T3, T4
**Files:** `lib/lain/tools/read_file.rb`, `lib/lain/tools/bash.rb`, `lib/lain/tools/memory_read.rb`,
and — **added 2026-08-18 by orchestrator ruling at review** — `lib/lain/tools/memory_write.rb`.
Review measured that `memory_write` accepts a 262,145-byte body and `memory_read` then refuses it
**forever**, which is the read/write asymmetry T3's own trigger exists to prevent, reproduced in a
different toolset. Neither narrower action the read refusal named survives being followed: there is
no manifest *tool* to consult (`Tools.constants.grep(/Memory/)` is `[:MemoryWrite, :MemoryRead]` —
the manifest rides every Request via `Workspace`), and "supersede it under the same id" is
destructive and requires knowing what was denied. The ceiling belongs where the artifact is created
and where the model has a real alternative — write less, or split across ids — which also makes the
read ceiling unreachable-by-construction, as the card already claimed it was. A window on
`memory_read` is **not** the answer; `memory_read_spec.rb:32` pins `properties.keys == ["id"]` and
widening that is its own card.
**Reuse:** `Tool::Bounds`' artifact shape from T4; `read_file`'s window from T3 is the narrower
action
its refusal names. `Bash.render_output` (`tools/bash.rb:64-68`) is shared by both the Ruby and
daemon
arms and is where a bound must live so parity holds.
**Shared-file wiring:** none
**Reachable from:** each tool's `#perform`, dispatched by `Agent::ToolRunner#run` on the live chat
path. `Tools::CoreExec` is deliberately **excluded** — it has no production construction site in
`lib/` (the shipped floor is `cli/wiring/base_tools.rb:15-22`), so bounding it would reach nothing.

**Acceptance criteria:**

```gherkin
Scenario: an oversized file read is refused before the bytes are read
  Given a file far larger than the read bound
  When read_file is called with no window
  Then it refuses naming offset and limit, and the file is never fully read into memory

Scenario: the read refusal also names the structural tools
  Given an oversized Ruby file
  When read_file refuses it for size
  Then the message names at least one of code_outline, file_symbols or ast_search

Scenario: oversized command output is refused without losing the exit status
  Given a command that prints far more than the output bound and exits non-zero
  When bash runs it
  Then the result is an error stating the output size and the exit status

Scenario: the bound holds identically on both bash arms
  Given the same oversized command run through the Ruby arm and the daemon arm
  Then both refuse with byte-identical messages
```
→ spec file: `spec/lain/tools/read_file_spec.rb`, `spec/lain/tools/bash_spec.rb`,
`spec/lain/tools/memory_read_spec.rb`

**Escalation triggers:**
- `spec/lain/tools/bash_spec.rb:256` asserts **byte-identity** of output across the Ruby and daemon
  arms. A bound applied on one arm only breaks that parity — it belongs in `Bash.render_output`,
  which both share. If it cannot go there, stop.
- AC 1 says the file is never fully read. If the only workable implementation is `File.read` then
  check the length, stop and say so — the memory half of this chunk's claim depends on `File.size`
  preceding the read, and shipping a post-hoc check while the Intent claims otherwise is worse than
  shipping nothing.
- **T3's AC 3 must have landed.** Without "a window covering the whole file completes the read",
  this card makes every oversized file permanently uneditable. Verify before starting.
- If a bound trips during the existing suite, **raise the fixture question, do not raise the cap**
  to
  make a spec pass.

### T6 — Bound the enumeration tools   [wave 2] [risk: medium]

**Depends on:** T4
**Files:** `lib/lain/tools/glob.rb`, `lib/lain/tools/list_files.rb`,
`lib/lain/tools/code_outline.rb`,
`lib/lain/tools/file_symbols.rb`, `lib/lain/tools/test_pattern.rb`, `lib/lain/tools/web_search.rb`
**Reuse:** `Tool::Bounds`' enumeration shape from T4, whose contract is `grep`'s existing trailer —
these six become consistent with the four tools that already cap-and-disclose.
**Shared-file wiring:** none
**Reachable from:** each tool's `#perform` on the live chat path. `Tools::ToolSearch` is
deliberately
**excluded** — no production construction site in `lib/`.

**Acceptance criteria:**

```gherkin
Scenario: an oversized listing is capped and discloses the true count
  Given a directory with far more entries than the listing bound
  When list_files runs
  Then the capped entries are returned followed by a notice naming the cap and the true count

Scenario: capping does not change which entries are returned within the cap
  Given a directory whose listing exceeds the bound
  When list_files runs twice
  Then both runs return the same entries in the same order

Scenario: a listing within the cap gains no notice
  Given a small directory
  Then the result is byte-identical to the pre-change behaviour
```
→ spec file: `spec/lain/tools/glob_spec.rb`, `spec/lain/tools/list_files_spec.rb`,
`spec/lain/tools/web_search_spec.rb`, `spec/lain/tools/code_outline_spec.rb`

**Escalation triggers:**
- `spec/lain/tools/glob_spec.rb:25` pins deterministic sorted order, and
  `spec/lain/core/grep_parity_spec.rb:278` records that walk order diverges **under** a cap. AC 2
  exists for that reason: cap **after** the deterministic sort, never by stopping the walk early. If
  an implementation caps during the walk, stop.
- `web_search` results come from a backend whose ordering this repo does not control. If its result
  count cannot be capped deterministically, say so and leave it uncapped with the reason recorded
  rather than shipping a nondeterministic cap.

### T7 — Extract the tool-message predicate as a shared, tested object   [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/compaction/tool_messages.rb`
**Reuse:** port `ComposedFixtures.tool?` from `spec/lain/compaction/strategy/composed_spec.rb:50`
verbatim — `message.fetch("content").any? { |block| block.fetch("type").start_with?("tool_") }` —
and
the run-selection shape at `:76`, including its `.select { |run| run.size > 1 }` filter.
**Shared-file wiring:** `require` line in `lib/lain/compaction.rb`'s subtree index
**Reachable from:** deferred to T8 and T9, both in this chunk and named here. This card exists
**because** T8 and T9 must be exact complements: if two parallel agents each spell the predicate,
the sets stop being complements and `Composed#refuse_overlap` (`strategy/composed.rb:135-146`)
raises
**at proposal time, mid-session, in a live chat**.

**Acceptance criteria:**

```gherkin
Scenario: a message carrying any tool block is a tool message
  Given a message whose content includes a tool_use block
  Then it is classified as a tool message

Scenario: a message carrying text alongside a tool block is still a tool message
  Given an assistant message with a text block and a tool_use block
  Then it is classified as a tool message

Scenario: the two selections never claim the same index
  Given any span of messages
  Then no index is claimed by both the tool runs and the conversational runs
    and every index claimed by neither is a lone conversational run

Scenario: a conversational run of one message is not selected for summarizing
  Given a span where a single conversational message sits between two tool runs
  Then the conversational selection excludes it
```
→ spec file: `spec/lain/compaction/tool_messages_spec.rb`

**Escalation triggers:**
- AC 2 records a real consequence: the normal Anthropic assistant shape is **text + `tool_use` in
  one
  message**, so a message-granular predicate elides the model's own prose along with the
  observation.
  That is a deliberate, stated limitation of message-granularity — `arXiv:2508.21433` masks
  *observations*, which are blocks. If the panel wants block-granularity, that is a different seam
  (`Strategy::Base` is handed messages, `strategy/base.rb:48-51`) and a different card. **Do not
  quietly widen this card to blocks.**
- If `IntervalPartition.covering(span, excluding:)` (`lib/lain/interval_partition.rb:77-93`) does
  not
  make the two selections exact complements, AC 3 fails and T8/T9 cannot compose. Stop there rather
  than in wave 2.

### T8 — Add `Strategy::ElideToolObservations`   [wave 2] [risk: medium]

**Depends on:** T7
**Files:** `lib/lain/compaction/strategy/elide_tool_observations.rb`
**Reuse:** subclass `Compaction::Strategy::Elide` (`strategy/elide.rb:58`) to inherit the
attestation;
use `Compaction::ToolMessages` from T7 for selection — **do not spell the predicate here**.
**Shared-file wiring:** `require` line in `lib/lain/compaction/strategy.rb`'s subtree index; if this
card declares an algebraic property, a generator entry in `spec/support/algebra_generators.rb`
(orchestrator-owned).
**Reachable from:** deferred to T10, which registers the name and makes it selectable from
`--compact-strategy` on `lain chat`. T10 is in this chunk and is named here.

**Acceptance criteria:**

```gherkin
Scenario: only tool-carrying messages are claimed
  Given a span where two messages carry tool blocks
  When ranges are proposed
  Then the proposed ranges cover exactly those messages

Scenario: conversational turns are retained verbatim and in position
  Given a derivation over a mixed span
  Then the conversational messages appear unchanged and in their original order

Scenario: a purely conversational span proposes nothing
  Given a span with no tool messages
  Then no ranges are proposed and the derivation is a no-op
```
→ spec file: `spec/lain/compaction/strategy/elide_tool_observations_spec.rb`

**Escalation triggers:**
- `strategy/elide.rb:97-98` declares `elementwise on: :blocks` and `pure on: :blocks`, and
  `spec/lain/compaction/strategy_spec.rb:142` records that declaring `elementwise on: :collapse` is
  a
  trap. A subclass inherits those claims — if its behaviour differs, the claims must be restated or
  refuted, not silently inherited. **`spec/algebra_laws_spec.rb`** (note: not
  `spec/lain/algebra_laws_spec.rb`) walks the registry and asserts no missing and no orphaned
  generators.
- If the inherited attestation's byte-identity property (`elide_spec.rb:68-86` — identical output
  under any partition) does not hold for a partial-span claim, stop: that property is what makes
  `Elide` the control arm.

### T9 — Add `Strategy::SummarizeConversation`   [wave 2] [risk: medium]

**Depends on:** T7
**Files:** `lib/lain/compaction/strategy/summarize_conversation.rb`
**Reuse:** subclass `Compaction::Strategy::Summarizing` (`strategy/summarizing.rb:87`) to inherit
the
oracle contract, content-address keying and recorded-answer replay; use
`Compaction::ToolMessages.conversational_runs` from T7 — **do not spell the predicate here**, and
note it is the FILTERED complement (`.select { |run| run.size > 1 }`), not the raw one, which is
what AC 2 depends on.
**Shared-file wiring:** `require` line in `lib/lain/compaction/strategy.rb`'s subtree index;
generator
entry in `spec/support/algebra_generators.rb` if a property is declared (orchestrator-owned).
**Reachable from:** deferred to T10, named here.

**Acceptance criteria:**

```gherkin
Scenario: only conversational runs of more than one message are claimed
  Given a span where two messages carry tool blocks
  Then the proposed ranges claim the conversational runs of length two or more
    and claim no message carrying a tool block
    and leave a lone conversational message unclaimed

Scenario: the oracle is asked once per claimed run
  Given a span with two separate conversational runs of more than one message
  When the strategy collapses it
  Then the oracle receives exactly two questions

Scenario: an unchanged run replays its recorded answer with no model call
  Given a span already summarized under a recorded oracle
  When the derivation runs again over byte-identical messages
  Then no new oracle call is made and the head digest is unchanged
```
→ spec file: `spec/lain/compaction/strategy/summarize_conversation_spec.rb`

**Escalation triggers:**
- `strategy/summarizing.rb:138-141` records that `TEMPLATE` **is a journal address** — rewording it
  silently re-keys every recorded answer, and the miss surfaces on resume *after* the model has been
  paid. If this card needs different prompt text it must be a **new** definition with its own
  address,
  never an edit to the parent's. Stop and confirm.
- `spec/lain/compaction/strategy/summarizing_spec.rb:223,229` registers refutations of elementwise
  and
  pure for the parent. A subclass inherits them; if its behaviour differs they must be restated.
- AC 2 depends on T7's single-message filter. If a lone conversational turn reaches the oracle, the
  card is paying a model call to summarize one message — stop and check T7's AC 4.

### T10 — Make a composed strategy selectable from the command line   [wave 3] [risk: medium]

**Depends on:** T8, T9
**Files:** `lib/lain/cli/compaction_strategy.rb`
**Reuse:** `Base#|` (`strategy/base.rb:167`) builds `Composed` and is a declared commutative monoid
with `Identity` as unit (`:235`); `STRATEGIES` (`cli/compaction_strategy.rb:117`) and its `case`
(`:159-166`) are the existing registry.

**Shared-file wiring:** add the new names to the `--compact-strategy` table in `docs/commands.md` —
`spec/docs_naming_spec.rb:92-106` pins the set against that doc.
**Reachable from:** `exe/lain:699-703` (`--compact-strategy`, declared on `chat`) →
`CLI::Backend::SpanSummarizer` (`backend/span_summarizer.rb:76-80`) →
`CLI::Backend#compaction_source`
(`cli/backend.rb:474-482`) → `CompactionMount` (`cli/compaction_mount.rb:54`) → the live `Agent`.
**This is the card that makes T7, T8 and T9 reachable, and the trace above is probe-verified.**

**Acceptance criteria:**

```gherkin
Scenario: the two new strategies resolve by name
  When --compact-strategy is given "elide-tools"
  Then a strategy that claims only tool messages is constructed

Scenario: a hybrid is spelled as a composition and proposes without overlapping
  When --compact-strategy is given "elide-tools+summarize-conversation"
  Then a Composed strategy is constructed, and proposing ranges over a mixed span raises nothing

Scenario: an unknown name is refused naming the whole advertised set
  When --compact-strategy is given an unregistered name
  Then the refusal names every registered strategy

Scenario: composing two whole-span strategies fails at the first compaction, naming both
  When --compact-strategy is given "elide+summarizing"
  Then the first compaction raises Overlap naming both operands
```
→ spec file: `spec/lain/cli/compaction_strategy_spec.rb`

**Escalation triggers:**
- AC 4 is deliberately weaker than "refuse before any run begins". `Base#|` only constructs;
  `Overlap` is raised inside `propose_ranges` (`composed.rb:135-146`), which needs messages and a
  span
  the resolver does not have, and `composed_spec.rb:141` pins that. A static "claims the whole span"
  declaration would allow resolve-time refusal and is a **design decision for its own card** — if
  you
  find yourself adding one, stop.
- `spec/docs_naming_spec.rb:92-106` also pins that "unset is its own case". The unset path builds
  `Held`; if adding a composition spelling makes unset resolve to a strategy, stop — that changes
  shipped default behaviour for every chat session.
- `spec/lain/cli/compaction_strategy_spec.rb:57` pins that an unknown name's refusal names the set.
  Growing the set changes that message — update it deliberately.
- If the `+` separator collides with anything Thor treats specially, pick another rather than
  escaping.
- **`DEFAULT`'s docstring is stale and this card is the one reading it.**
  `chunk-derived-context-timeline.md:1758-1765` records that the constant's doc calls it "what an
  unset flag falls through to" while an unset flag actually means the eager tier, and warns that "a
  future caller writing `CompactionStrategy.resolve(options[:compact_strategy])` silently gets
  summarizing". Correct the comment while here; `backend/span_summarizer.rb:19-48` has the accurate
  version to copy.
- **A refused derivation has already paid for the strategy.**
  `chunk-derived-context-timeline.md:1753-1757`
  records that under an oracle-backed strategy the model call is made and journaled as an
  `oracle_answer` **whose answer is discarded**. This card makes
  `elide-tools+summarize-conversation` the recommended spelling and integration check 7 runs it
  against a real repo, so a reachable refusal path burns money on the manual pass.

  **MEASURED 2026-08-18. The refusal path IS reachable, it is the outcome on every turn with short
  tool results, and "pays it every turn" is the wrong shape.** The memo keys per RUN, so unchanged
  runs are hits: the cost is **N on the first compacting turn, then ~1 per turn** — where N is the
  number of conversational runs the history had accumulated before compaction first fired. From a
  13-message history N is 2; from a 33-message history it is **7**. A burst, not a doubled call, and
  it scales with how long the session chatted first.

  **It is not only money — it pollutes the experiment record.** On a three-turn run that refused
  every turn, the journal holds `oracle_answer => 4`, `context_derived => 3`,
  `compaction_decision => 3`, `compaction => 0`: four model calls paid and journalled, three
  derivations written into the Store, **zero compactions committed**. That is precisely the hazard
  `source.rb`'s `timely?` comment argues for the *timing* gate — "would fill the experiment record
  with derivations no render ever used" — with the floor gate sitting on the wrong side of the same
  argument. `Source#weigh` calls `@derived.over(...)` before both defer gates (`source.rb:390-398`),
  so the spend is unconditional.

  **The switch is not tool-output size**, which a first reading suggested: with large
  *conversational* messages and 2-byte tool results the composition still shrinks. It is the net of
  the elide half's ~230 B-per-message attestation against the summarize half's saving. Integration
  check 7 carries the operative form of this.

### T11 — Attribute and price cache waste per session, segmented by model   [wave 2] [risk: medium]

**Depends on:** T1
**Files:** `lib/lain/friction/cache_waste.rb`, `lib/lain/friction/report.rb`
**Reuse:** `Bench::Rewrites` (`bench/rewrites.rb:43-111`) computes where the prefix broke;
`Ledger::Index` parses billed cache tokens per `Telemetry::TurnUsage`; `PriceBook` (corrected by T1)
prices the difference; `Friction::Report` (`friction/report.rb:133`) already consumes `Rewrites` and
is the report this joins into.
**Shared-file wiring:** `require` line in `lib/lain/friction.rb`'s subtree index
**Reachable from:** `lain friction SESSION` (`exe/lain:857-858`) → `CLI::Friction#report` →
`Friction::Report`, joining `Friction::Report::ANALYZERS` (`friction/report.rb:51`) as a fourth
analyzer over one session's entries.

**Land the per-turn cache fact as a reusable object, not inline in the rendering.** The
`cache_read_input_tokens == 0` reading this card computes, segmented per model, is exactly the
sensor
`ROADMAP.md:221-225`'s cache-aware compaction scheduler needs ("run only when the cache is already
cold … confirmed by `cache_read_input_tokens == 0`"). Folding it into report prose would make that a
re-derivation; keeping it a small object makes it a card. Costs nothing now.

**This discharges a recorded follow-up.** `chunk-cache-memory-hands.md:932-934` owes "segment
journals per arm before cross-model comparison" against exactly this `Bench::Rewrites` behaviour —
AC 2 is that ticket. Mark it closed in the close-out rather than leaving a duplicate open.

**Acceptance criteria:**

```gherkin
Scenario: a broken prefix reports re-billed tokens and their cost
  Given a journal where a turn's prefix diverged and the next turn billed cache creation
  Then the report states the re-billed token count and its cost at that turn's model price

Scenario: a model switch is not counted as waste
  Given a journal where the only prefix divergence coincides with a model change
  Then the report attributes no waste to it and says why

Scenario: a session whose cache never broke reports no waste explicitly
  Given a journal where every turn read the cache
  Then the report states there was no cache waste rather than omitting the section
```
→ spec file: `spec/lain/friction/cache_waste_spec.rb`

**Escalation triggers:**
- **AC 2 is the card's central difficulty, not an edge case.** `bench/rewrites.rb:34-42` states a
  model switch is "indistinguishable from a real prefix edit" and that callers "must segment the
  journal per arm before projecting". `/model` is a normal move in a chat session, so without
  segmentation this metric inflates on most real sessions. The journal records the model per turn —
  segment on it. If segmentation proves impossible, stop and report rather than shipping an
  inflating
  metric.
- `Provider::Mock` reports all-zero cache fields (`lib/lain/response.rb:49`), recorded as a standing
  trigger at `bench/plan_sweep/driver.rb:23-30`. A mock-backed spec for this card **passes
  vacuously**
  — use a recorded or synthetic usage with non-zero cache fields.
- No `provider` field is recorded per turn anywhere. If correct pricing needs one, stop and raise
  it;
  do not infer the provider from the model string.
- **A waste figure alone is an anti-metric**, by this repo's own rule: `ROADMAP.md:233` — "Prelude
  size alone is an anti-metric — always grader × tokens × cache-write." An agent that reads nothing
  wastes no cache. Report the figure beside what it bought, and follow the `Friction` doctrine at
  `ROADMAP.md:1218-1223`: a friction section **proposes with evidence, never applies**.

### T12 — Report cost in the arm comparison, and say what produced the report   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/arm/driver.rb`, `lib/lain/arm.rb`, `lib/lain/bench/cli.rb`,
`lib/lain/bench/spawn_seam.rb`
**Reuse:** `Arm::Run#compare_run` (`lib/lain/arm.rb:83-86`) already builds a priced `Compare::Run`
from the run's own Ledger. `Arm::Driver::METRICS` (`arm/driver.rb:22-26`) uses the `{of:, fmt:}`
shape and reads via `run.public_send(spec.fetch(:of))` (`:66`) — add to **that** registry, not
`Compare::METRICS`, which uses `{label:, reader:, fmt:}`.
**Shared-file wiring:** none
**Reachable from:** `lain bench arms FIXTURE` (`exe/lain:450`) → `Bench::CLI#arms_report`
(`bench/cli.rb:170-177`) → `Arm::Driver#report`.

**Why the header is in scope, and why the file list is larger than it looks.**
`chunk-bench-arms-subcommand.md:322-326` records that the header "`Arm driver — 3 arms over 8
tasks`" carries **no fixture path, no provider, no model, no isolation name** — "an unattributable
bench report is a weak experiment record". A **dollar figure on a report that names no model** is
precisely the lie `price_book.rb:48-50` refuses to tell, so the column and the attribution belong
together. But the Driver cannot currently answer any of the three: `arms_report` hands it
`tasks: suite.map(&:prompt)` (`bench/cli.rb:174`), so the fixture path never arrives; `SpawnSeam`
exposes no reader for `@provider`/`@context` (`bench/spawn_seam.rb:88-92`), so the model is
unreachable; and the unset isolation case passes **no keyword at all**, defaulting to the bare
`NoIsolation` module (`arm.rb:29`), so there is no name to print. Those three facts are why
`bench/cli.rb` and `bench/spawn_seam.rb` are in Files.

**Acceptance criteria:**

```gherkin
Scenario: the arm report carries a cost column
  Given an arm run whose ledger prices its turns
  When the report is rendered
  Then it contains a cost column matching that ledger's cost

Scenario: cost is reported per arm
  Given three arms over the same tasks
  Then each arm's row carries its own cost

Scenario: the report header names what produced it
  When the report is rendered
  Then the header names the fixture, the model and the isolation backend

Scenario: an unset isolation backend is named as unset, not omitted
  Given a run with no isolation configured
  Then the header says so rather than leaving the field blank
```
→ spec file: `spec/lain/arm/driver_spec.rb`, `spec/lain/bench/arms_report_spec.rb`

**Escalation triggers:**
- **Pricing can raise where tokens cannot.** `Arm::Run#usage`'s docstring (`arm.rb:88-89`) says a
  tokens metric "is available even where a **bare-mock run cannot be priced**", and `Ledger#cost_of`
  (`ledger.rb:85-87`) raises `PriceBook::UnknownModel` for a payment with no model. `METRICS` is
  folded for **every** run (`driver.rb:66`), so a cost column converts a documented graceful
  degradation into a hard raise for any modelless mock. `spec/lain/arm/driver_spec.rb:20` survives
  today only because its mock happens to carry a model. Decide the degradation deliberately.
- `Arm::Run` has **no `#cost`** today despite its class doc at `lib/lain/arm.rb:68` claiming
  "`#usage`/`#cost`/`#compare_run` fold the Ledger". If adding it changes what `#compare_run`
  returns, stop.
- `spec/lain/arm/driver_spec.rb:42` pins that the driver returns a String and never prints.
- `spec/lain/bench/arms_report_spec.rb:98` pins the "3 arms over 8 tasks" header and `:107` the
  score
  spread. Both change here — update them in one edit, not incrementally.
- The header must not name a provider API key or base URL. `spec/output_discipline_spec.rb` will not
  catch a leaked base URL inside a report String; check by eye.
- The reported cost **excludes any LLM-judge tokens** (Open decision 4). Say so in the close-out.

### T13 — Bound the summarizer's input where the cost gate already lives   [wave 2] [risk: medium]

**Depends on:** T4
**Files:** `lib/lain/oracle/routed_summarizer.rb`
**Reuse:** `Oracle::RoutedSummarizer` already holds `@threshold_bytes`
(`oracle/routed_summarizer.rb:73,82`) and already routes on **which tier pays** — it is the object
that owns size-vs-cost policy. `MODEL_THRESHOLD_BYTES = 4096` (`:72`) is the existing **lower**
bound;
this card adds the **upper** one beside it.
**Shared-file wiring:** none
**Reachable from:** `Oracle::RoutedSummarizer` is constructed on the live path by
`CLI::Backend` and consulted per tool result via `Effect::Handler::Summarizing::Observer#summarize`
(`effect/handler/summarizing.rb:81-85`).

**Why here and not at the mount, which an earlier draft of this card got wrong.**
`effect/handler/summarizing.rb:33-44` records that this file "once refused to fire below 4096
bytes",
that gating there "made a project's own `.lain/summarizers.rb` dead for every ordinary tool result",
and that consequently **"the cost gate sits with the object that knows which tier pays,
`Oracle::RoutedSummarizer::MODEL_THRESHOLD_BYTES`"**. Siting a bound at the mount would re-introduce
the exact mistake that comment exists to prevent.

**Why the card is needed at all, stated truthfully.** After T5 and T6 the entire 17-tool shipped
floor (`cli/wiring/base_tools.rb:15-22`) is bounded, so the Intent's 50 MB `read_file` example is
closed by **T5**, not by this card. The real case is one tool over: **`web_fetch` legitimately
returns up to 5 MiB** (`tools/web_fetch.rb:28`), which is a *transport* cap three orders of
magnitude
above a sane summarizer input — and the summarizer's live tier defaults to a local ollama model
(`oracle/summarize.rb:15-18`). Four further tools (`subagent`, `request_review`, `ask_human`,
`run_skill`) are added outside the base floor and are bounded by neither T5 nor T6.

**Acceptance criteria:**

```gherkin
Scenario: an input above the upper bound is never sent to a paid tier
  Given a tool result larger than the summarizer's input bound
  When the routed summarizer is asked for a summary
  Then the model tier is not asked

Scenario: a project's own summarizer is not bounded by this ceiling
  Given a project catalog that answers for a tool result larger than the input bound
  Then its answer is used

Scenario: the two bounds are independent
  Given an input below the model threshold and another above the upper bound
  Then the first is offered to the free tier only
    and the second reaches no paid tier

Scenario: a bound that could never admit anything is refused at construction
  Given an input bound whose limit is at or below the model threshold
  When the routed summarizer is built
  Then it refuses, naming both knobs

Scenario: an input between the bounds is summarized exactly as before
  Given an input above the model threshold and below the upper bound
  Then the summarization is byte-identical to the pre-change behaviour
```
→ spec file: `spec/lain/oracle/routed_summarizer_spec.rb`

**Escalation triggers:**
**AC 1 corrected 2026-08-18, after review measured the premise away.** It originally read "declined
before any tier is asked … without consulting the free tier or the model tier", and that wording is
what forced the ceiling in front of the catalog — re-introducing, at a different size, exactly the
mistake `effect/handler/summarizing.rb:33-44` exists to prevent: **a project's own
`.lain/summarizers.rb` going dead for results it was written to handle.** The CPU justification did
not survive measurement (the docstring's own example predicate over 5 MiB is **1.87ms**, against a
`split("\n")` at 40ms and a documented *spinning*-predicate hazard of 0.637s on a 17-byte result,
which no size gate reaches). And the region the ceiling removed is the one where the free tier is the
**only** tier that can answer: a 5 MiB `web_fetch` is 65-87k tokens, past `qwen3:4b`'s 32,768 trained
maximum, so the model tier could never have served it. The `input_bound:` escape does not rescue the
affected party either — `CLI::Backend#summary_oracle` passes neither keyword and there is no flag or
`.lain/` knob, so a project has no lever at all. **The ceiling is a cost gate; it belongs on the tier
that costs money.** Keep it, and site the test in `#fallthrough` beside the threshold so
`custom(source)` stays unbounded.

- `MODEL_THRESHOLD_BYTES` is a **lower** bound and this adds an **upper** one. If an implementation
  collapses them into one knob, stop — they answer different questions, and merging them would
  silently change which results get a free-tier summary.
- `Compaction::SummarySnapshot.take` keys summaries by result content digest
  (`compaction/summary_snapshot.rb:135-142`); a result that is never summarized has no entry and
  renders as `ELIDED` (`:200-205`). Verify that path — a declined oversized result is now the common
  way to reach it.
- `spec/lain/oracle/routed_summarizer_spec.rb:118,250,289` pin the existing threshold behaviour and
  a
  lowered threshold. Adding a second bound changes that surface; update deliberately.

### T14 — Bound ONE ask, not the whole session   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/agent.rb`, `spec/lain/agent_spec.rb`
**Reuse:** `Budget` is already stateless and frozen — it takes the count as an argument
(`agent/budget.rb:27-32`), so nothing about the ceiling object changes. The counter is the bug, and
`seed_run_state` (`agent.rb:365`) is already the one place run state is named.
**Shared-file wiring:** none
**Reachable from:** every `lain chat` session; `Agent#ask` → `#run` → `#run_loop` → `#step`.

The counter is seeded in `#initialize` and never reset, so 25 model calls spread over any number of
prompts exhausts it. Reset it where a new autonomous loop begins. **The silent-swallow half is the
more dangerous one and must be fixed with it**: after the ceiling, a prompt is committed and
`run_interrupted` with nothing rendered.

```gherkin
Scenario: a fresh ask starts a fresh iteration count
  Given an agent whose previous ask ran to the iteration ceiling
  When the human asks a second question
  Then the loop runs again
    and the ceiling bounds that ask alone

Scenario: a long single ask still stops at the ceiling
  Given an agent asked one question the model answers with tool calls forever
  When the loop reaches the ceiling within that one ask
  Then Budget::Exceeded is raised

Scenario: a refused run says so
  Given an ask that stops at the ceiling
  Then the human is told the run stopped and why
    and the session accepts the next prompt normally
```
→ spec file: `spec/lain/agent_spec.rb`

**Escalation triggers:**
- If any spec depends on `@iterations` accumulating across asks, stop and list them — that is the
  behaviour under question, and each deserves a deliberate decision rather than a re-baseline.
- If a **session-wide** ceiling turns out to be wanted (an unattended run is the plausible case), do
  not smuggle it in as the same number. It needs its own name, its own default and its own rendered
  refusal; propose it and stop.
- `commit_and_account`'s `defer_stop` region (`agent.rb:393-400`) exists so a stop cannot land
  between a Timeline commit and its `TurnUsage`. Do not move the reset inside it.

**Recorded at review, 2026-08-18 — a scheduled debt, not a hidden one.** With this card's line,
`Agent` sits at **exactly `Metrics/ClassLength` 110/110** (measured against main with
`rubocop --stdin`: main clean, main+patch clean, main+patch+one counted line `[111/110]`). No limit
was loosened and the inline was the right call here — extracting a *method* cannot satisfy
`ClassLength`, it adds lines; only extracting an **object** does, which is precisely what the cop is
saying. The object is already named by `#seed_run_state`'s own docstring — *"the mutable run
context"*: session, snapshot_writer, budget, iterations, failure_reason, transition_listener. The
tell that it is overdue is in this card's diff, where `@iterations = 0` now appears twice in two
methods meaning two different scopes and needs a paragraph to stop it reading as a contradiction.
An `Agent::RunState` would let `#run_loop` say `@run = RunState.begin(...)`. **The next card that
touches `agent.rb` inherits this extraction** — written here rather than left in a hand-back so it
arrives as a decision rather than as an ambush at 111/110 mid-work.

### T15 — Every pending approval reaches the surface the human is looking at   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/frontend/approval_policy.rb`, `lib/lain/frontend/tty.rb`,
`spec/lain/frontend/approval_policy_spec.rb`
**Reuse:** `TTY#drain_inbox`'s injectable `reader:` (`tty.rb:229-250`) is the shape that already
solves "something else owns stdin" for the inbox — the approval read is the same problem and should
not invent a second answer. `exe/lain`'s `approval_surface` comment is the reference both docstrings
point at.
**Shared-file wiring:** `exe/lain` — orchestrator applies any surface-construction change.
**Reachable from:** `lain chat` with no nvim; `Approval::Queue` → the TTY approval surface.

A second gated call in one turn renders no prompt **and is never read**, so the run wedges with no
way to answer it. The first call in the same turn is fine, and the distinguishing event is the
streamed `Telemetry::ToolOutput` written to the pane in between.

```gherkin
Scenario: a second gated call in one turn still prompts
  Given a turn whose first gated tool call was approved and streamed output to the pane
  When the model makes a second gated tool call in the same turn
  Then the human is prompted to approve it
    and the prompt names the requester and the tool

Scenario: the answer to that prompt is consumed
  Given a rendered approval prompt for a second gated call
  When the human answers it
  Then the decision is applied to that pending call
    and the run continues

Scenario: a denied second call refuses without wedging
  Given a rendered approval prompt for a second gated call
  When the human denies it
  Then the tool does not run
    and the session returns to the prompt
```
→ spec file: `spec/lain/frontend/approval_policy_spec.rb`

**Escalation triggers:**
- **Rated high because this is stdin ownership**, which `tty.rb` already records as raceable against
  the countdown ticker. If the fix requires deciding who owns stdin during a turn, that is a design
  question — write it up and stop rather than picking one.
- Verify on `--no-nvim`, which is where the defect is fatal. A fix that only works in the cockpit
  has not fixed it: `:LainApprove` was the recovery path there and it masked the bug.
- Do **not** "fix" this by making `lain://approval` the primary surface. The plain chat path is
  supported and has no editor.

### T16 — A refusal is not a crash   [wave 2] [risk: medium]

**Depends on:** T14
**Files:** `lib/lain/frontend/neovim/runtime/46_sidebar.lua`,
`lib/lain/frontend/neovim/runtime/48_annotate.lua`, `lib/lain/cli/repl.rb`,
`spec/lain/frontend/neovim/runtime_spec.rb`, `spec/lain/cli/repl_spec.rb`
**Reuse:** `_G.__lain.review_refused` (`65_review.lua:36`) and the answer-then-RETURN shape
`:LainReviewDone` uses (`65_review.lua:115-123`). This card **applies an existing, measured,
documented pattern to the sites that did not get it** — it does not invent one.
**Shared-file wiring:** none
**Reachable from:** `:LainReviewVerdict` / `:LainNoteDone` in the cockpit; the budget ceiling in any
`lain chat`.

Two halves of one rule. **Lua:** `error(tostring(refusal), 0)` at `46_sidebar.lua:196` re-raises a
refusal that `pcall` has already caught, and nvim appends a `stack traceback:` plus a blocking
`Press ENTER` modal to anything escaping a `define`d callback. Route it through the refusal channel
and return instead. The comments at `46_sidebar.lua:183-192` and its twin in `48_annotate.lua`
currently record the traceback as unavoidable — true of *raising*, and the point is not to raise, so
**both comments must be corrected with the code** or the next reader re-derives the wrong conclusion.
**Ruby:** `Budget::Exceeded` escaping its `Async::Task` prints
`Task may have ended with unhandled exception` and 27 frames before `Repl#respond` renders the
correct line.

**Two corrections from T14's review, 2026-08-18, and the first one costs money.**

**The reproduction this card was written against no longer exists, and its replacement is worse.**
T14 makes the iteration ceiling per-ask, so "type anything after the ceiling" is gone as a way to
reach a bust — drive **one** ask into a tool loop instead. But the panel measured that
`max_total_tokens` still reproduces the identical wedge shape and **survives T14 untouched**: with
the token ceiling busted, each later `ask` commits a user turn, **reaches the provider**, commits an
assistant turn, then raises — measured `provider calls=3, turns committed after the first bust=4`
across three dead prompts. It is permanent exactly as the iteration ceiling's was, and strictly
worse in one respect: the old dead prompts were free, these cost a full round trip each. It renders
(`error: spent N tokens, ceiling is 50`) and it is off by default (`max_total_tokens: nil`), which
is why it is a SHOULD-FIX rather than a session-killer — but the first thing anyone who sets it on
an unattended run meets is a session that keeps accepting prompts and keeps spending. **Use it as
this card's live repro.**

**Do not let the silent render close as "diagnosed".** T14 discharged manual-QA's "nothing rendered
at all" by making the state that exhibited it unreachable, which is correct and sufficient for that
finding. The **mechanism was never identified**: the panel traced `Repl#respond`'s rescue,
`record_interruption` (which cannot raise on a merely-extending timeline) and `render_error`, and
found no path in `lib/` that produces an empty screen. So if it is real it fires for *any*
`Lain::Error` raised mid-ask, and the token bust above is the ready-made reproduction. Inherit the
open question with the repro rather than recording it as closed.

```gherkin
Scenario: a verdict refused over an unreviewed changeset reads as a refusal
  Given a changeset review with one unreviewed file
  When the human runs the verdict command
  Then the refusal names the unreviewed file and what to do about it
    and no stack traceback is shown
    and no hit-enter prompt blocks the editor

Scenario: a budget refusal renders one line
  Given a run that stops at its iteration ceiling
  When the refusal reaches the human
  Then one line names the ceiling and the count
    and no unhandled-exception warning is printed
    and no backtrace is printed
```
→ spec files: `spec/lain/frontend/neovim/runtime_spec.rb`, `spec/lain/cli/repl_spec.rb`

**Escalation triggers:**
- If a refusal turns out to carry a value the caller needs (rather than only a message), stop — the
  answer-then-return shape drops the raise, and a caller depending on the raise for control flow is
  a real design question.
- Do not silence the Async warning globally. The task must stop *without terminating as an
  exception*; a suppressed logger would also hide real crashes.

### T17 — Keep `lain://timeline` live   [wave 2] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/frontend/neovim/buffers.rb`, `lib/lain/frontend/neovim/surfaces.rb`,
`spec/lain/frontend/neovim/buffers_spec.rb`
**Reuse:** `Surfaces#post` (`surfaces.rb:99-107`) already fans one event into three projections and
is demonstrably working — `lain://request` and `lain://diff` update live through it. Whatever is
wrong is on the `TurnUsage` branch, not the delivery path.
**Shared-file wiring:** none
**Reachable from:** the cockpit's timeline view, and the `p` pin and `]]`/`[[` record-boundary
gestures that resolve their cursor through it (`buffers.rb:140`, `75_timeline.lua`).

The view renders during the first ask and never updates again, so every gesture that resolves
through it addresses a stale chain.

**Start by instrumenting, not by reading.** The mechanism was NOT determined during QA and three
plausible explanations were each ruled out by measurement (drain thread death, store miss, the
events not being produced). Log which event classes actually reach `Surfaces#post` in a live
session before changing anything.

```gherkin
Scenario: the timeline follows the session across asks
  Given a cockpit session with one completed ask rendered in the timeline
  When a second ask completes
  Then the timeline view shows the second ask's turns

Scenario: a digest the store cannot resolve stays legible
  Given a turn-usage event naming a digest this store never held
  Then the view renders that it is unavailable
    and the drain thread survives
```
→ spec file: `spec/lain/frontend/neovim/buffers_spec.rb`

**Escalation triggers:**
- If the cause is that `TurnUsage` does not reach the frontend Channel at all, that is a **wiring**
  finding with a wider blast radius than this view — say so and stop, because `InboxView` retires
  questions off the same event (`inbox_view.rb:252`).
- A spec that asserts the buffer's content after ONE ask cannot catch this. The regression test must
  drive **two** asks; that is the whole reason it survived a green suite.

  **Corrected 2026-08-18 by the implementer, who found the real mechanism and showed this guidance
  was wrong.** Two asks is NOT sufficient — they drove two asks three ways, including a real
  `lain up` cockpit, and it passed every time. The trigger is a **newline**.
  `nvim_buf_set_lines` refuses any item containing one, and renders ride `nvim_exec_lua` as a
  **notify**, so the refusal reaches nobody: `TimelineView#preview` joined a turn's text blocks
  verbatim, real model prose is multi-line, and the first such turn silently lost the whole buffer
  write — and every later render still carried it, which is why the freeze is permanent and why its
  onset moved with whenever the model first wrote a paragraph. Reproduced deterministically by
  replaying QA round 4's own journal through the real frontend (`2 → 4 → 4 → 4 …` while request went
  `557 → 724`), with the error caught verbatim by proxying `_G.__lain.set_view`:
  `'replacement string' item contains newlines`. **The fixture must contain a newline**; the ask
  count is incidental.

### T18 — Three surfaces that are right about the facts and wrong about saying them   [wave 3] [risk: low]

**Depends on:** none
**Files:** `lib/lain/provider/ollama/retry_tap.rb`, `lib/lain/provider/anthropic/retry_tap.rb`,
`lib/lain/frontend/neovim/journal_view.rb`, `plugin/nvim/lua/lain/init.lua`,
`spec/lain/provider/ollama/retry_tap_spec.rb`, `spec/lain/frontend/neovim/journal_view_spec.rb`
**Reuse:** the placeholder shape every sibling view already uses (`(no reminders)`,
`(no questions pending)`, `(no approvals pending)`, `(no requests yet)` — `buffers.rb:260-269`).
**Shared-file wiring:** none
**Reachable from:** any retried request; the cockpit at attach and at rest.

Three independent one-liners, grouped because each is a surface stating something it knows to be
untrue and none is worth a card alone.

1. **The retry ordinal.** `exhausted_block` pushes `attempt: options.max` — the retry count, not the
   ordinal of the attempt that failed — so four real attempts render as `1, 2, 3, 3`. Both taps.
2. **`lain://journal` has no placeholder** while every sibling does, against `Surfaces#prime`'s own
   stated principle. It also renders `Telemetry::ToolOutput` only; **consider renaming it**, because
   "journal" means the NDJSON record everywhere else in the system and this is not it. A rename is a
   documented user-visible surface (`doc/lain.txt`, `:h lain-runtime-commands`) — propose it, do not
   assume it.
3. **The attach notice persists.** `init.lua:243` notifies `not attached yet` and nothing supersedes
   it when `open_layout` later succeeds, so it contradicts the live buffers beside it.

```gherkin
Scenario: the give-up line names the attempt that actually failed
  Given a request retried until its retries are exhausted
  When the exhausted notice is rendered
  Then it names a higher attempt number than the last retrying notice did

Scenario: an idle journal view says what it is waiting for
  Given a cockpit session in which no tool has streamed output
  Then lain://journal renders a placeholder rather than an empty line
```
→ spec files: `spec/lain/provider/ollama/retry_tap_spec.rb`,
`spec/lain/frontend/neovim/journal_view_spec.rb`

**Escalation triggers:**
- The Anthropic tap's ordinal must move with the Ollama one, or the two providers disagree about
  what "attempt" means — a worse state than the bug.
- A row-level `x` currently emits one acknowledgement **per hunk** (six for one gesture). If a
  summary line is attempted, note that `Review::Surface::MESSAGES` is a closed set — that is a
  seventh message, not a reworded one, and it belongs in its own card if it grows past a line.

## One method lesson worth keeping

**A stated obstacle is the most dangerous prose to leave unverified, because it terminates the
enquiry — nobody re-checks a road marked closed.** T9 declined to restate an algebra refutation and
wrote the reason into `lib/`: that doing so "would go red as an ORPHAN at the coverage sweep". The
sweep actually fails such a claim as **MISSING**, which is the ordinary cost its sibling card had
already paid. The claim was checkable in one command and was never run, and because it was written
as a *closed road* rather than an open question, it survived the implementer, the hand-back, and
would have survived the chunk had the two cards not been reviewed as a pair. The implementer's own
statement of the lesson is better than a rule: they reasoned from the registry's **purpose** rather
than its **mechanism**, then wrote a checkable claim about a failure mode into `lib/` without
running it.

This is the same shape as the two grounding corrections earlier in this chunk — the `write_file`
"clobber hatch" that was really a dead end, and the `remain-on-exit` comment that recorded a
traceback as unavoidable when the sibling command had already dodged it. **Prose that says "we
cannot" earns a command, not a nod.**

## Discovered during the chunk — owed cards, not this chunk's work

Recorded here rather than left in hand-backs, which are deleted with their worktrees.

1. **`lain up` applies `remain-on-exit` too late to catch the failures it was added for.**
   Found while fixing the tmux flake, and demonstrated deterministically with tmux alone. `up.rb`
   runs `create_session` — which spawns the pane already running chat — and only *then*
   `configure_session` → `keep_failed_pane`. A chat that exits inside that gap takes pane → window →
   session → **the whole server**, and `up.call` itself then raises `TmuxUnavailable: no server
   running` from `up.rb:333`. So the `remain-on-exit failed` option, added for the 2026-08-06 "starts
   and immediately crashes" report, does not cover the fastest crashes — exactly the ones it exists
   for.

   **TWO examples witness it, not one, and a close-out reading only this line will meet the second
   as a surprise.** `up_spec.rb`'s "threads -- chat args into the spawned window's command, each
   argument shell-escaped" is the one found here; "--nvim cockpit splits the chat window into an
   nvim pane and a chat pane sharing one socket and one cwd" in the same file fails from the same
   cause. `chunk-qa-round3-defects.md:143` already names both together and is the fuller record.
   The cockpit one was separately repaired this chunk (`6a7b51d5`) for a DIFFERENT, real defect --
   it used to fail with a misleading `Errno::ENOENT` from a lossy parse -- so it now fails HONESTLY
   when load kills both panes. Neither was silenced with a server-wide `-g remain-on-exit on`,
   because that would delete the only witness. **A production card, and it should keep both.**

2. **The approval surfaces copy `QueueSurface`'s machinery instead of sharing it.** T15's panel
   showed `Notify` reimplements `POLL_INTERVAL`, `@raised`, `@pruning`, `#sweep`, `#unraised?` and
   `#notify_about` as a hand copy of `QueueSurface`'s `watch`/`sweep`/`mine?`/`adjudicate`, and that
   two of T15's own findings *are* that copy's drift — the missing `decided?` re-check and the
   missing fault guard, both lost in the same commit that made the copy. `CLAUDE.md` names the
   remedy: `ActiveSupport::Concern` for orthogonal behaviour that wants separate testing. Deferred
   because it is an architecture change across the approval surfaces, wider than the card that found
   it. T15 instead ships `spec/approval_consumer_discipline_spec.rb`, which is what actually stops
   the bug regrowing — a second `dequeue` consumer now fails at commit.

3. **`max_total_tokens` keeps spending after it is busted, and the leak has no card of its own.**
   Confirmed twice by measurement in this chunk. With the token ceiling busted, each later `ask`
   commits a user turn, **reaches the provider**, commits an assistant turn, then raises — measured
   4 asks, 4 provider calls, 8 turns. T16 fixed the *noise* half (the refusal no longer arrives as an
   unhandled-exception warning plus 27 frames) as a side effect; the **cost** half is untouched. It
   renders and it is off by default (`max_total_tokens: nil`), which is why it is not a
   session-killer — but the first thing anyone who sets it on an unattended run meets is a session
   that keeps accepting prompts and keeps paying for them. `grep max_total_tokens planning/
   ROADMAP.md` currently returns **nothing**: the only description of this lives inside T16's card as
   "this card's live repro", so when T16 closes a live spend-after-bust leak has no owner.

4. **The empty render QA saw is still unexplained, and the best-founded candidate is the interrupt
   path — not the one T16's hand-back originally pointed at.** T16 could not reproduce it and
   correctly declined to call it fixed. Its first pointer (`Repl#dispatch`/`#middleware_turn`) is a
   hypothesis with no producer: `SkillDispatch` is the only repl-phase short-circuit in `lib/` and it
   sets a real `Response`. What review **measured** instead: `Agent::Budget#interrupt` is `task.stop`
   (`budget.rb:55-57`), and `Async::Task#wait` on a stopped task **returns `nil` without raising**.
   So an interrupted ask yields `Outcome(response: nil)` → `Ask#settle(nil)` → not a `Lain::Error` →
   `nil` → `middleware_turn`'s `deliver(nil)` → `catch_up`, and **renders nothing** — with `Shutdown`
   rendering no outcome line either and the ticker having erased the countdown. A reachable,
   in-`lib/`, screen-renders-nothing path on the interrupt half, which nobody has traced.

5. **`:LainNoteDone`'s second raise site (`assert_saved`) still tracebacks, and the obvious fix has a
   trap in it.** Recorded with the corrected facts, because the version in T16's hand-back would
   cause a defect if followed. `55_compose.lua:106` and `60_question.lua:138,143` are **not** `define`d
   commands — they are `BufWriteCmd` autocmds whose raise is **load-bearing**, and `55_compose.lua`
   says why in place: "Erroring here is what leaves 'modified' set, so the buffer keeps saying it
   holds unsaved text and nvim refuses to DISCARD it -- `:bdelete`/`:bwipeout` answer E89."
   Converting those would let a failed write be silently discarded. The genuine change is small:
   `review_notes.assert_saved` has one caller (`settled`), which has one caller (`:LainNoteDone` at
   `48_annotate.lua:415`), and `settled()` returning `payload, refusal` needs no `pcall` and no
   duplicated `reap`. **Two functions, one call site.**

6. **A refusal wider than one clause still raises a hit-enter modal, and the repo already knows why.**
   T16 removed the `stack traceback:`, which was the card's subject and is genuinely gone — but the
   blocking `Press ENTER` is not, and it also blocks the RPC channel while up. Measured: `nvim_echo`
   of a 128-character refusal at 80 columns puts nvim in mode `r` with `blocking: true`; the same
   message at width 200, and a 23-character message at width 80, do not. AC 1's own scenario hits it,
   because the unreviewed-changeset refusal (`review/verdict/policy.rb:92`) is **230 characters** and
   names `Lain::Review::Verdict::Policy::Permissive` in full. The doctrine is already written down
   twice — `Surface::Neovim::MARKED` and `ASK_VERDICT` (`review/surface/neovim.rb:217-221`) say a
   message must be "one short clause" *because* `65_review.lua:37` echoes it, and two specs cap
   echoed notices at `< 60` and `< 40` naming `Press ENTER or type command to continue` as the
   failure. `:LainReviewDone`'s own 152-character refusal has it too, so this is rail-wide.
   **No spec anywhere attaches a UI** (`grep nvim_ui_attach` finds nothing), which is why 13924
   examples cannot see it; `nvim_get_mode().blocking` is the available witness.

7. **`Approval::Escalation`'s surface taxonomy cannot name a frontend surface, and this is a
   load-order constraint rather than a preference.** Found by T15, which needed a name for a
   fault-denial so it would stop being journalled as though a person had typed `n`.
   `Surfaces::AUTOMATIC` (`escalation.rb:629`) is that name's true home, and **cannot hold it**: the
   constant is evaluated while `lain/approval` loads, before `Frontend::ApprovalPolicy` exists, so
   referencing it there is a load-time `NameError`. T15 ships `FAULT_SURFACE = "tty_fault"` accounted
   for in `escalation_spec` instead, with the reason in a comment. **Making the taxonomy late-bound
   is the real fix and is a design change to how `Escalation` classifies surfaces** — wider than the
   card that found it. Whoever takes it should note the comment exists precisely to stop the obvious
   move (relocating the constant into `AUTOMATIC`), which fails at boot.

8. **Bound the rewrite before the oracle is paid, in `Source#weigh`.** The card this chunk's cost
   measurements earn. `Source#weigh` calls `@derived.over(...)` **before** both defer gates
   (`source.rb:390-398`), so an oracle-backed strategy is paid unconditionally and then possibly
   refused on the `shrinks?` floor — measured at four paid calls and three stored derivations for
   zero committed compactions over three turns. This bites whole-span `summarizing` identically;
   `elide-tools+summarize-conversation` merely makes it reachable and recommended.

   **The bound is free, which is what makes this a card rather than a wish.** The elide half's
   attestation cost is fully deterministic with no model call, and the summarize half's saving has a
   hard ceiling — it cannot save more than the bytes it replaces. So `Source` can ask "even with a
   perfect summary, would this shrink?" for zero tokens and defer before `over`. One card discharges
   it for every oracle-backed strategy at once.

   **A per-operand shrink test is explicitly REFUSED, so it is not re-litigated.** `shrinks?`
   measures the *rendered history* — the array a render actually sends — and there is no such thing
   as half a rendered history, so a per-operand verdict answers a question nobody asks. Worse,
   `Base` declares `commutative_monoid on: :|` with property tests walking the registry, and a
   partial application that can drop one operand makes the result depend on which operand was
   measured first. It would also require `Source` to reach into `strategy.operands` and undo a
   composition the operator asked for, and would still pay the oracle first. One `shrinks?` verdict
   over the composed rewrite is the right seam.

9. **The real-tmux specs leak a socket inode per example.** Measured 2026-08-18 while reviewing the
   `lain up` fix: **19,604 stale socket files in `/tmp/tmux-1000` against ZERO live servers**, and
   confirmed independently. `up_spec` mints a per-example socket (`lain-spec-<pid>-<object_id>`) and
   the server dies with the example, but the socket file is never unlinked.

   **It is NOT a flake contributor, and an earlier draft of this entry wrongly guessed it might be.**
   Corrected on review: tmux resolves `-L NAME` to an exact path and `connect()`s, never enumerating
   the directory, and these are zero-byte inodes on tmpfs — no per-operation cost, no memory
   pressure. This chunk's two real tmux flake causes were both found and both proven, and neither
   needed a third explanation. The two reasons it still earns a card are different ones: `/tmp` is
   tmpfs with a finite **1,048,576-inode ceiling** (~19.7k of the 12% in use is these sockets) and
   the leak is unbounded until reboot; and it makes `CLAUDE.md`'s own mandated "check for stray
   `tmux -L` servers before believing a result" noisy, so 19k dead entries invite reading a quiet box
   as a busy one — a direct tax on the debugging discipline that found both defects.

   It is **three** spec files, not one: `lain-spec-*` 14,625, `tmux-surface-spec-*` 4,050,
   `fleet-windows-spec-*` 672. `kill-server` does not unlink its socket, and the `after` hook kills
   the server without removing the file. The cheap fix covers all three at once: point `TMUX_TMPDIR`
   at the per-example `Dir.mktmpdir` the around hook already creates, so the socket dies with the
   directory. Cleaning the existing backlog is safe whenever `pgrep -c tmux` is 0.

10. **A private method is reached with `.send` in `chat_flags_spec.rb:222` to make a claim about the
   executable's flag surface**, and T10's new "the unset name" group now asserts the same fact
   through the public API. The honest end state is deleting the `.send` line as a duplicate rather
   than renaming it — but no card owns that file, so it was left renamed and correct.

11. **The `lain://journal` rename proposal's file list was incomplete, and the miss was functional.**
   T18 proposed renaming the buffer to `lain://tool-output` and listed `journal_view.rb`'s `NAME`,
   `doc/lain.txt:197,696` and ~8 seam specs. Its panel found two more, one of which is code rather
   than prose: **`plugin/nvim/lua/lain/config.lua:19`**, where the shipped **default window layout**
   names the buffer literally — applying the proposal as listed would silently break it — and
   `README.md:368,395`. Prose references that would go stale also live in `lib/lain/cli/live_views.rb:115`,
   `spec/lain/cli/live_views_spec.rb:84`, `spec/lain/cli/wiring_spec.rb:551` and several `.lua`
   runtime headers. **Whoever takes the rename inherits this corrected list, not the hand-back's.**

## Close-out (2026-08-18)

**All 18 cards landed**, plus two fixes this chunk's own work surfaced and the user asked for:
the `up_spec` cwd-parse repair (`6a7b51d5`) and the **`lain up` `remain-on-exit` ordering defect**
(`014b8d45`) — a real user-facing bug where a chat that died instantly took the tmux server with it,
so the option added for the 2026-08-06 "starts and immediately crashes" report never covered the
crashes it was written for. Forced reproduction: **9 losses in 20 repeats before, 0 in 20 after.**

**Integration checks.** 1 green on BOTH paths (`rake pspec`, and a full serial `bundle exec rake` at
**14272 examples / 0 failures / 15 pending**, rubocop clean over 1325 files — the serial path was
failing on `up_spec` before the production fix and passes after, which is independent confirmation
of the cause). 2 green, with one honest caveat: a single `cargo test` failure appeared once and did
**not** reproduce across three further runs, and its name was not captured — recorded as one
unattributed failure, explicitly NOT added to any flake list, per this repo's own rule that an
unnamed entry is worse than none. 3 green including the new price-freshness lint. 6 unaffected.
**4 and 5 could not be performed as written and say so above rather than being skipped.**
7-13 are the human manual pass, still owed — `planning/qa/` now carries scenarios for all of it.

**What the panel caught that a green 14,000-example suite did not.** Every card was reviewed; nine
came back REQUEST-CHANGES or with a blocker. The findings that mattered most were all *wrong answers
returned as successes*, which is the class a suite is worst at: `read_file` handing back line 1's
tail labelled "line 2" because `drop` counts chunks and not lines; a cache-waste meter reporting a
clean bill against $0.375 of real waste on an alternating-`/model` session, and 500,000 tokens
attributed against a truth of 12,000 when a subagent's usage landed between a request and its own;
`lain bench arms --provider ollama` destroying its entire report after paying for the runs;
`FrozenError` on `touch foo.rb`. Three panels also overturned their own round-1 claims with
measurement, and one overturned a claim of mine.

**The recurring defect of this chunk was prose, not code**: a checkable claim written into `lib/` or
a hand-back and never run. It appeared at least six times — the `write_file` "clobber hatch" that was
really a dead end, the traceback recorded as unavoidable when the sibling command had already dodged
it, T9's "would go red as an ORPHAN" (it fails as MISSING), `Up::Tmux`'s "the ONE place", the
`-f File::NULL` pin that silently made an assertion vacuous, and **T1's "Reachable from: `lain
ledger`" — a command that does not exist, which survived both a grounding pass and a panel review.**
See "One method lesson worth keeping" above.

**Eleven owed cards are recorded above**, including the one this chunk most wants next: bound the
rewrite before the oracle is paid (`Source#weigh`), which measured **four model calls and three
stored derivations for zero committed compactions** on a three-turn refused run.

## Integration checks

After the last wave:

1. `bundle exec rake` (compile, full suite, rubocop) green. Re-measure the example count rather than
   quoting one — `CLAUDE.md` records that the headline figure is a date stamp, not a fact.

   **Measured mid-chunk at `144913f7` (T1, T7, T14, T4, T3, T12, T2, T18, T8 landed): 14033 examples,
   0 failures, 15 pending.** Recorded because three separate implementers independently reported a
   mismatch against a figure their orchestrator had quoted, and each correctly flagged rather than
   adjusted to it. Every one of those readings (13910-13971) was taken on a worktree cut from a stale
   base and therefore missing landed cards — the count is a function of which commits are present, so
   a figure quoted across agents working from different bases is guaranteed to disagree. **Quote the
   commit with the count, or do not quote the count.**
2. `cargo test && cargo clippy --all-targets -- -D warnings` green (no Rust in scope; regression
   only).
3. `pre-commit run --all-files` green, **including the new price-freshness lint from T2**.
4. Confirm the corrected price table changes stored-journal readings, and record both figures in
   the close-out. **A ~3x drop is the expected, correct outcome** — not a regression.

   **CORRECTED 2026-08-18: there is no `lain ledger` command, and this check named one.** The
   verified command set is `approve arms bench chat consolidate deny epic friction improve
   improvements land open plan-sweep queue record review sessions status submit survey sweep up
   variance watch`. Worse, **T1's own "Reachable from" line made the same claim** ("read by `lain
   ledger` and every bench cost column") and it survived both the pre-flight grounding check and a
   panel review — a reachability claim is exactly the kind that reads as verified because it names a
   file and a method, while the *door* it names is the unchecked half. Use a surface that exists:
   **`lain friction SESSION`**, whose cache-waste section T11 added and which prices per turn, or
   **`lain bench arms`**, whose cost column T12 added. Both read `PriceBook` through `Ledger#cost_of`
   on a real path.
5. Confirm no tool bound fires during a normal `rake pspec` run.

   **RAISED 2026-08-18, as this check's own parenthesis instructed: no such record exists.** The
   check assumed bounds emit a `Telemetry` record when they trip, making it greppable in a run's
   journals. `lib/lain/tool/bounds.rb` references `Telemetry` nowhere, and neither T4 (which built
   it) nor T5/T6/T13 (which applied it) added one — correctly, since no card asked for it. So the
   check is **unperformable as written** and is not being silently skipped. What stands in for it:
   the suite is green with every bound applied, and both applying cards report that no fixture
   tripped a bound and that no cap was raised to make a spec pass. **Whether a tripped bound should
   be observable at all is a real question and belongs to a card** — a bench whose thesis is that
   observation tokens dominate a turn arguably wants to count the moment it refuses to spend them.
6. Confirm `lain bench arms spec/fixtures/arms/tasks.yml` reports the same scores as before this
   chunk. Nothing here touches the arm path except T12's column, so a score change is a finding.
7. **Manual pass (human):** run `lain chat --compact-strategy elide-tools+summarize-conversation`
   against a real repo until compaction fires at least twice, and confirm from the journal that tool
   observations were elided while conversational turns survived verbatim. This is the only
   end-to-end check that the composed strategy works on the live path.

   **Use tools that return REAL BYTES, and treat this as a precondition rather than advice.** T10
   probed the composed strategy against the real `Derived` and found `shrinks?` is **false on every
   turn** when tool results are `"ok"`-sized, and true at 2 KB. The driver is the **elide half's
   ~230-byte attestation**, not the oracle half -- `summarize-conversation` alone shrinks on the same
   history. So a short-output scenario does not merely fail to demonstrate the strategy: every turn
   asks the oracle, is refused as `would_not_shrink`, and discards what it paid for. A manual pass on
   toy outputs measures nothing and bills for it. Read a few real files; do not drive it with `echo`.
8. **Manual pass (human):** run `lain friction` over that session and confirm the cache-waste
   section
   reports a figure, and that a `/model` switch mid-session is not counted as waste.
9. Grep a real run's journal for a credential: `Friction::CacheWaste` is a new report over journal
   records and must carry digests, token counts and dollars only — never message content, never a
   path.
10. **Manual pass (human), the QA half:** run `planning/qa/scenarios/session-and-window.md` and
    `planning/qa/scenarios/failure-injection.md` — both are cheap, deterministic and cover the paths
    these cards touch. Then confirm each of the five findings behaves differently, and **record
    whether differently means better**; one previous chunk turned a silent hang into a hard crash.
11. **T14 and T15 must be confirmed on the PLAIN path, not the cockpit.** Drive
    `lain chat --provider ollama` with no nvim: ~30 model calls over several prompts (T14), and one
    turn making two gated `bash` calls where the first streams stdout (T15). The cockpit has a second
    approval surface that masked T15 entirely.
12. Confirm no card re-broke a round-4 confirmed-fixed behaviour. The cheapest guard is the
    launch-level refusal set in `session-and-window.md` §1 — nine one-line launches, no model call.
13. Fold anything these cards teach the QA method back into `planning/qa/`, and delete the
    "budget the round around the session ceiling" note in `method.md` once T14 lands — a stale
    workaround in a procedure doc costs the next round real time.
