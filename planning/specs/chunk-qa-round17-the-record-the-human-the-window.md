# Chunk: round-17 — what the record keeps, who the human answers through, what the window can hold

status: done -- planned 2026-09-14, panel-reviewed (REVISE → fixes applied); executed 2026-09-14..15
commit-mode: orchestrator-commits
language: ruby (plus nvim runtime Lua in T27, and `planning/qa/` prose in T29)
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

This chunk discharges [`../qa-findings-round17-2026-09-14.md`](../qa-findings-round17-2026-09-14.md)
(F88–F130, the fork findings T1–T6 / E1–E16 / V1–V2, and P36). **One chunk, by the human's
ruling.** Cards that touched the same files have been merged, so the waves are about file ownership
rather than theme.

The round's defects are not forty-five independent bugs. They come from **six missing owners**, and
each card below restores one of them rather than patching its symptom:

1. **Nothing owns the bytes a tool hands back.** `Canonical#utf8` is the first object that checks
   encoding, and it runs at commit — after the command ran and after the `tool_use` turn is
   committed. Nothing repairs the unanswered call such a tear leaves behind (F88, F89, F103, F129).
2. **Nothing owns where a record goes.** Five collaborators are handed the display `Channel` as
   their journal, so `shell_arm`, `isolation_lease`, `handback` and supervisor records never reach
   the session file (F92). A spawn's identity omits what makes twin spawns distinct (F97). Every
   lineage reader walks a record shape production never wrote (F98). The sign-off fold reads a torn
   line as a decision nobody made (F93, F114).
3. **Nothing owns stdin.** Four readers race on one terminal, and typeahead goes to whichever reads
   next (F101, F102, F105, F106). **The human ruled nvim-first:** in a cockpit the chat stops
   reading answers inline, and `lain://inbox` / `lain://approval` become the answer surfaces. Plain
   `--no-nvim` chat keeps its inline prompts with two guards.
4. **Nothing owns the window.** No object measures a request against the served window before
   sending (F90). Secondary model calls drop the run's sampler options and re-key the runner (F95).
   Compaction re-decides on every render, so a signal that clears un-compacts the history (F94).
5. **Nothing owns what an automatic approval may read.** `ComposedTerm` has no project-root
   predicate, and the credential table was sized for "a human is still asked" (F91). Mode layers are
   lighters with no consumer (F104).
6. **The epic, undo and review tiers keep their truth in two places** (F99–F100, F107–F108,
   F111–F117).

**The human's rulings, taken in the interview and binding on the cards:**
- one chunk;
- nvim-first answer surfaces;
- a **sticky compaction cut** that keeps the Timeline lossless and has the derived replacement
  *span* the compacted range;
- **root predicate + widened GATED** for credentials;
- **wire all four mode layers**;
- **build `/critique` over a held review Docent-style**, and verify it with a manual `/critique` of
  lain on itself;
- **prompt digest in the one-shot spawn body.**

## Grounding

**Verified 2026-09-14 against `d073c232`.** Six parallel read-only explorations, one per root
cause, plus direct reads. The live evidence for every mechanism below is in the round-17 findings
file and its fork reports (`~/tmp/lain-qa-round17/records/fork-{epic,shell,survey}-report.md`).

### 1. The bytes

- **Where encoding is decided.**
  - Mixlib buffers are UTF-8 until the first byte ≥ 0x80 arrives, then ASCII-8BIT, even for valid
    UTF-8.
  - `Shell::Pipeline` (`shell/pipeline.rb:397-408`) copies that rule; `Exec::Core` is always
    ASCII-8BIT.
  - `Tools::Bash.render_output` (`tools/bash.rb:137-147`) interpolates the bytes. The timeout path
    (`bash.rb:283`) embeds them in an error message.
  - `Tool::ResultBlock.of` (`tool/result_block.rb:54-63`) is "the SOLE writer of a tool_result
    block" and copies content untouched. `ToolDelivery#settle`'s commit (`agent/tool_delivery.rb:73-78`)
    reaches `Canonical#utf8` (`canonical.rb:110-117`), which raises `UnsupportedType < Lain::Error`.
- **There is no shared bytes→turn-safe-text object.**
  - `ReadFile::Read#committable?` (`read_file.rb:189`, private) refuses by name (the `780c4a08`
    fix).
  - `WebFetch::Text` (`web_fetch.rb:214-300`) decodes by guessing a charset.
  - The Rust `read_text` (`ext/lain/src/read_text.rs:72-139`) accepts BINARY strings whose bytes
    are valid UTF-8, which is the rule the text boundary should share.
- **Listings and grep.**
  - `WithholdSecretPaths#sift` (`withhold_secret_paths.rb:269-271`) calls `split` on an invalid
    string and raises, withholding the whole listing. The byte-safe idiom is
    `Survey::Unit.lines_of` (`survey/unit.rb:57`).
  - `Grep`'s `skip?` (`grep.rb:117`) and `AstSearch`'s (`:198`) raise on an invalid filename.
  - `Grep#each_matching_line` (`grep.rb:121-131`) skips the rest of a file silently, which under
    `LC_ALL=C` means every non-ASCII file.

### 2. Torn runs

- **What strands a call.** `Agent#commit_and_account` (`agent.rb:452-462`) commits the `tool_use`,
  then delivery runs. A non-`Async::Stop` raise in `settle` leaves it unanswered:
  `Ask#record_interruption` (`cli/repl/ask.rb:74-77`) writes `run_interrupted :torn`, and the next
  `Agent#ask` (`agent.rb:209-215`) commits user text on top. `Budget#check_tokens!`
  (`agent/budget.rb:33-37`) strands a call the same way.
- **Repairs exist, but only for two shapes.**
  - `ToolDelivery#cancel` (`:111-138`) handles `Async::Stop`.
  - `CLI::Resume#settled` (`cli/resume.rb:249-253`) with `Resume::Cancellation`
    (`cli/resume/cancellation.rb:39-95`) handles a loaded head only.
  - `ToolRunner::Answers` reaches *up* into `CLI::Resume::Cancellation`. `tool_runner.rb:59-69`
    names the move to `lib/lain/tool/cancellation.rb` as owed.
- **Nobody validates the live request.** `Context::Conversation` is used only by
  `Derivation#refuse_invalid` (`compaction/derivation.rb:178-185`).

### 3. The record

- **Records routed to the display channel.** `CLI::Wiring` builds `Lain::Channel.new` (`:282`) and
  hands it as `journal:` at `:419` (`IsolationBackend`), `:637` (`ToolsetBuild`), `:648`
  (`Supervisor`), `:681` (`WorkerHandoff`) and `:813` (`EpicDriver::Seams`).
  `Frontend::Decorators.for` renders only three types and skips the rest (`decorators.rb:30-35`).
- **The durable path.** `Chronicle#record_journal` already exists (`chronicle.rb:238`), and
  three sites already use it: the snapshot slot, degradation, and the goal journal
  (`wiring.rb:486, 520, 825`).
  - Under `--nvim` it **is** the tee, `LiveViews#journal` (`live_views.rb:129`) built by
    `Chronicle#wrap_tee`, which also feeds `StatusFeed` and `FleetWindows`.
  - There is no reader that is durable **and not** the tee.
- **A child's own `TurnUsage` must not reach the file as `turn_usage`.** It would pair with the
  parent's in-flight request in `session_record/salvage.rb:64`, pollute
  `friction/cache_waste.rb:211-214`, and be priced — against `scribe_spec.rb:395`.
- **Round 16 diagnosed this and deferred it** (its Open decision 5).
- **The spawn body.** It is `{prefix, posture, only, spawned_from}` (`tools/subagent/lineage.rb:60-61`).
  `RoleSpawn#call` builds a new `Lineage` per call (`skill/role_spawn.rb:49-81`), so a per-writer
  counter cannot separate role-spawn twins.
  - Consumers keyed on that digest: `FleetWindows` (`fleet_windows.rb:370-421`),
    `StatusFeed::Fleet` (`status_feed/fleet.rb:37-70`), `lain watch`'s `LineageFilter`
    (`watch/lineage_filter.rb:47-73`).
- **Lineage readers walk a shape nobody wrote.**
  - Production has never written `meta["spawned_from"]`: `git log -S` finds only the `:spawn`
    body, and child turns are `child_turn` records (`session_record/scribe.rb:284-290`, since
    `c1fb99da`).
  - `Consolidation` (`consolidation.rb:60-62, 180-183`), `Grader::ToolCallIndex`
    (`grader/tool_call_index.rb:36-39, 100-108`) and `CLI::Improve` (`improve.rb:77`) all read
    `turn` + `meta.spawned_from`, against invented spec helpers (`consolidation_spec.rb:31-35`).
  - `CLAUDE.md:221-223` and `ARCHITECTURE.md:118,134` state the same false shape.
  - `Bench::Session::Loader` (`bench/session/loader.rb:43,196-205`) already folds
    `message` + `child_turn` into one Store correctly.
- **The sign-off fold.**
  - `Journal.records` (`journal.rb:104-125`) skips unparseable lines on a "shared fd with Rust
    tracing" contract that has **no production caller** (`init_tracing` is spec-only; spans are
    whole JSON lines). So an unparseable line is always damage.
  - `SessionJournals#reading_of` (`cli/session_journals.rb:149-160`) counts and drops it, and only
    the `EpicQueue` listing reads that count (`epic_queue.rb:199-205`).
  - The sign-off folds that ignore it: `EpicSubmit`, `EpicDriver::Factory`, `CLI::Epic::Journals`
    and `EpicQueue` approve/deny, **plus** `epic_land.rb:138-140`, `epic_finish.rb:134` and
    `epic_mount.rb:254` (found by the panel).
  - `Declarative` refuses with `ArgumentError` by default (`declarative.rb:124,152`); the exe maps
    only `Lain::Error`.

### 4. The human

- **Four stdin readers go through `Frontend::TTY#prompt`**, and Reline's process mutex is the only
  arbiter.
- **Typeahead.** Between reads the terminal is cooked with echo on. The next raw reader gets the
  buffered line — F102's 19 ms deny.
  - Reline's `@buf` (`io/ansi.rb:25,166`) holds only `ungetc` bytes, so the typeahead lives in the
    kernel.
  - `IO#iflush` discards those bytes without returning them.
- **A dispatching line's only chat reader** is the `human>` `AnswerLoop`, which already classifies
  `/`-commands (`human_replies.rb:999-1004`). `you>` reads only after the line settles
  (`repl.rb:156-160, 182`), and a line parked on its own approval never settles.
  - So removing every inline reader in a cockpit would leave no way to type `/approve` while the
    main agent is parked. T6 keeps a command-only reader for that reason.
- **The watchers.** `Repl::ApprovalSurfaces#watch` (`repl/approval_surfaces.rb`) spawns the TTY
  watcher `if terminal`, and already holds `@editor`. `HumanReplies#surfaces`
  (`human_replies.rb:254`) spawns the `AnswerLoop` reader unconditionally.
  `HumanReplies#editor_reply_loop` (`:344-345`) already branches on `@editor.attached?`.
- **The ghost prompt.** `AnswerLoop#serve` (`:528-532, 602-605`) re-queues on every unwind.
  `HumanReplies#settled(digest)` (`:334-337`) is where every surface's answer converges, but it
  signals no parked loop.
- **`/approve`** reads the terminal undeclared (`command/small.rb:151-156`), which the reply-surface
  discipline spec's name scan misses.
- **`/goal off` and `/rewind`.**
  - `Repl#next_text` (`repl.rb:156-160`) never reads `you>` while `GoalDriver` returns prompts, and
    `GoalDriver#interrupt` (`goal_driver.rb:112`) has no production caller.
  - `/rewind` has no in-flight check (`command/rewind.rb:28-56`). `ToolDelivery` settles onto a
    captured timeline and yields it back over the rewound head (`agent.rb:530`,
    `tool_delivery.rb:57-78`). `/undo`'s `quiet!` (`command/undo.rb:116-125`) is the in-flight
    predicate to share.

### 5. The window

- **Occupancy** is `prompt_eval_count` after server-side truncation (`provider/ollama/decoding.rb:164`).
  No object estimates request size before `ModelCaller#call` (`agent/model_caller.rb:31-35`).
  `TruncatedStream` (`provider/ollama.rb:479-484`) is the precedent for a provider-cut witness.
- **Where a model-phase middleware can live.** `Chronicle.instrumentation(nil)` returns a bare
  `Agent::Instrumentation` (`chronicle.rb:113-114`), so `--no-journal` has no model stack at all.
  `Wiring#backing` (`wiring.rb:531-544`) already composes `turn_phase` with the window, and that is
  the composition point that exists under every journal setting.
  - `Request` memoizes nothing (`request.rb:39-45`).
- **The summary memo.** `Strategy::Summarizing::Answers` is in-memory and never memoizes a failure
  (`strategy/summarizing.rb:215-233`), so a summary's bytes do not survive a resume.
- **Secondary calls.** `Oracle::Model#request_for` (`oracle/model.rb:69`) builds `extra:` from the
  schema only. The three sites that construct one — `Backend::Summarizer#tier`
  (`summarizer.rb:51`), `SpanSummarizer#tier` (`:122`), `Oracle::SecretRead.tier`
  (`secret_read.rb:127`) — pass no sampler options. **Risk:** `anthropic_encoding.rb:67` forwards
  every `extra` key to the wire, so options must be filtered by arm.
- **Compaction.**
  - `Session#write_todos` (`session.rb:272-279`) sets a level that stays up until the next write.
  - `Compaction::Source#defer` (`source.rb:557-561`) returns the full chain whenever no signal
    fires.
  - Non-recursion of the **derivation** is design (`derivation.rb:41-48`,
    `ARCHITECTURE.md:1274-1282`, `docs/GLOSSARY.md:109-118`). Stickiness of the **decision** is
    not ruled out anywhere, and `planning/specs/plan-shaped-compaction.md:75-78` asks for it
    ("seam decisions are frozen at the seam").
  - `Source::Reporting` (`source.rb:283-299`) is the edge-latch precedent.
  - `Telemetry::ContextDerived` (`telemetry/context_derived.rb`) already records `spans` and
    `keep_last`.

### 6. Policy, epic, undo, review

- **Credentials.**
  - `ComposedTerm` predicate 4 (`approval/composed_term.rb:341-344`) consults only `ordinary?`.
  - `Approval::Risk::OutsideRoot#within_root?` (`risk.rb:176-213`) is a lexical root predicate with
    no production caller.
  - `BoardBuild::Classifiers` (`board_build.rb:290-311`) is the one factory the rule holds, and it
    swallows errors to the session classifier, so a root check there must fail closed.
- **Mode layers.** They are read only for lighters (`prompt_composer.rb:407`, `mode_state.rb:56`).
  `AutoSurface` comes from `options[:auto_approve]` (`toolset_build.rb:216`). `vi_mode:` is
  constructor-only (`tty.rb:88,388`). `notify`'s only meaning left with `c40ab419`.
- **Pricing.** `Compare::Run.from_timeline` prices eagerly (`compare.rb:47-50`), and
  `Compare#shown_metrics` (`:190-193`) already withholds a metric not every run has.
  `Arm::Driver#fold` (`arm/driver.rb:204-206`) degrades to `Unpriced`.
- **Epic.**
  - `EpicSubmit::Verdict#advance_epic` (`epic_submit.rb:260-281`) is the only writer of
    `stage_transition`. `Epic::InFlight` (`epic/in_flight.rb`) is the shared-rule precedent.
  - `Document.parse_markdown`/`to_markdown` (`epic/document.rb:139-151`) drop the preamble.
  - `Factory` reads `[tests]` from the worktree (`factory.rb:861-874`).
  - `Run#judge` skips only a nil SHA (`:763-770`), while `IssueTests::Red#sha` exists.
  - `cut_landing` adds an unlocked worktree (`:342`) that `Gc` reaps (`gc.rb:293-298`).
  - A retained dirty checkout still holds its issue branch (`isolation/worktree/release.rb:24-35`,
    `leftover.rb:44-87`).
  - `Approval::Gate` withdraws only in memory (`approval/gate.rb:256-274`, `ask_human.rb:794`).
- **Undo.** `WriteSet#paths` is the whole session write set with current bytes
  (`snapshot/scope.rb:63`). `SnapshotLog` blocks a first write as `:unrecorded`
  (`snapshot_log.rb:146-160`). `Revert::Move(before: nil)` is already a delete (`revert.rb:58,82`).
- **Critique.** `Review::Bounds#each_critique_chunk` (`review/bounds.rb:260`) has no caller in
  `lib/`.
  - Chunks pack to 7,000 lines (`bounds.rb:52`), about 99k tokens, and `max_critique_lines:` is
    already a parameter (`bounds.rb:198`).
  - `Review::Docent` (`review/docent.rb:272-292, 358`) is the only path that puts changeset bytes
    into a role child's prompt.
  - A held round lives in `Submit::Outbox`.
  - `SkillDispatch` is constructed in `cli/repl_middleware.rb:27`
    (`ReplMiddleware.build(role_spawn:, library:)`) with no outbox.
- **Gate policies in production.** The attended Gate's policy is `Approval::PolicySwitch`
  (`tool_guard.rb:136` via `switchboard.rb:189`), selecting among `Mode::Resolution::GATE_POLICIES`.

### Where docs and code disagree, and which won

**Code won everywhere:**
- CLAUDE.md's and ARCHITECTURE.md's `meta["spawned_from"]` sentence (T22 corrects it).
- `goal_driver.rb:19-24`'s "only the approval half is wired" (stale).
- `lineage.rb:45-46`'s "a one-shot is addressed by nobody" (false on `--windows` and `lain watch`).
- `mode/layer.rb:75-79`'s "turns Approval::AutoSurface on" (false).
- `--exec` help "docker refuses a PIPELINE" (`exe/lain:982`).
- The `Journal.records` skip contract.

**Round 16 withdrew F86 and F87 on the human's ruling.** They are not re-filed here.

**No notifier exists for any OS.** The only one, dunst-only `Lain::Notify`, was deleted in
`c40ab419`. T28's `notify` layer does not bring a desktop daemon back (see T28).

## Orchestrator contract (plan-specific only)

- **Shared files** (orchestrator-owned, wiring diffs only): `lib/lain.rb`, the index files
  `lib/lain/tool.rb`, `lib/lain/middleware.rb`, `lib/lain/epic.rb`, `lib/lain/review.rb`,
  `lib/lain/telemetry.rb`, `lib/lain/bench/session.rb`, `lib/lain/session_record.rb`, plus
  `.rubocop.yml`, `spec/spec_helper.rb`, `spec/support/**`, `lain.gemspec`.
  - A card needing a `spec/support` helper hands the orchestrator the helper's full text as its
    wiring diff.
- **A new lib file, its index require line and its spec land in ONE commit** (CLAUDE.md's
  commit-grouping rule). New lib files come from T3, T7, T21, T22, T24 and T25.
- **Metrics.** `Compaction::Source`, `CLI::Backend` and `CLI::Wiring` sit at their
  `Metrics/ClassLength` caps.
  - A card that adds state to them extracts a collaborator (CLAUDE.md's SRP rule).
  - A limit raise is never a card's escalation-free default.
- **Skip the panel review on T11 and T29.** T11 is table rows and a validator; T29 is docs. The
  suite and a proofread gate them.
- **Commit the round-17 QA edits before wave 1.** `planning/qa/method.md`, `planning/qa/README.md`,
  the manual-qa skill and the findings file are uncommitted in the working tree. Commit them (or
  have the human rule on them) before any card starts, so T29 and pre-commit's autostash never
  sweep them.
- **No ticket ids in `lib/`/`spec/`/runtime Lua comments** (CLAUDE.md; `bin/comment-census
  --check-tickets`). Every F/T/E/V/P id in this plan stays in the plan and in commit messages.
- **Wave order is ownership.** Several `Depends on:` edges are file-ownership edges, marked
  `(file)`. They exist so two cards never hold one file in the same wave, not because the later
  card needs the earlier card's behaviour.

## Open decisions

1. **`[tests]`/`[isolation]` config strictness between `lain chat` and `lain epic` (fork E16) is not
   taken.** `lain chat` warns where `lain epic`/`lain worktrees gc` refuse, while
   `TestLayout`'s docstring says a typo "is refused". Refusing in chat would stop every chat over
   one typo; warning in epic would weaken a gate. That is a policy ruling for the human. No card is
   gated on it.
2. **A window-relative `read_file`/tool result bound (F90's third leg) is deferred.**
   `Tool::Invocation` carries no window (`tool/invocation.rb:16`), and `read_file` decides from
   `File.size` before reading. T24 makes an over-window request **visible and refused before
   send**, which is the harm. Making the per-tool ceilings window-relative is a separate
   `Invocation` change. The deferral is named on T24.
3. **Already-damaged journals are not healed.** T3 repairs an unanswered `tool_use` **going
   forward**, at the next ask. A journal like `rails-blog`'s first session, with user text already
   committed on top of an orphan, stays damaged: `/fork` and `--resume` refuse it at the orphan's
   position, and T3 makes that refusal name the position. Healing history would mean a
   render-time pairing combinator, which the validator's "reports, never repairs" stance argues
   against. The human's call.
4. **The `--exec core` daemon arm of `bash`** gets T1's text boundary through
   `Tool::ResultBlock.of` like every other arm. The only `:core`-tagged run scheduled is T2's grep
   parity spec (integration check 2).
5. **Identical-prompt twins still share one fleet window.** T12 separates spawns doing different
   work. Two spawns of **identical** prompts from one head keep one digest, so the first completion
   releases their shared window (`fleet_windows.rb:420`). Accepted: they are the same work, and
   `scribe_spec.rb:380`'s child-turn dedupe depends on it. A seam-scoped ordinal would split them
   and is the next step if sibling addressing needs it.

## Waves

- **Wave 1:** T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11 (no unmet deps)
- **Wave 2:**
  - T12 (←T4 file)
  - T13 (←T6)
  - T14 (←T4 file)
  - T15
  - T16
  - T17 (←T5 file, T4)
  - T18 (←T5 file)
  - T19 (←T5 file, T10)
  - T20 (←T3, T7 file)
  - T21
- **Wave 3:**
  - T22 (←T12, T7 file)
  - T23 (←T6, T4 file, T15 file)
  - T24 (←T14 file, T4)
  - T25 (←T17, T5)
  - T26 (←T3 file, T16 file)
- **Wave 4:** T27 (←T13, T6, T24 file)
- **Wave 5:** T28 (←T27 file, T23 file, T13 file)
- **Wave 6:** T29 (←T19, T20, T22, T25, T26, T28)

**Critical path:** T4 → T14 → T24 → T27 → T28 → T29 (six waves).

## Execution log

- **2026-09-14, start.** Lands on `main`. Base `d073c232` = `HEAD` = `main` (no `origin` remote
  ahead of it); the Grounding SHA is the base, so no card's line numbers have drifted. Worktrees are
  cut by the orchestrator from `HEAD` under `tmp/worktrees/` (ignored by `/tmp/`), each with its own
  `TMPDIR=$HOME/tmp/lain-<card>` and a copied `lib/lain/lain.so` (no card touches Rust).
- **Box:** 16 logical cores, 15 GB RAM. Implementers run targeted spec files only; the full
  `rake pspec` runs serially at landing (the pre-commit `rake compile check`).
- **Ready at start** (no unmet deps): T1–T11, plus T15, T16, T21 pulled forward from wave 2.
  First launch favours the critical path and the cards that unblock most (T4, T6, T5, T3, T7, T10,
  T15, T16) alongside T1, T2, T8, T11; T9 and T21 (leaves) start as slots free.

- **T15 escalated (a third production Gate policy).** `CLI::ToolGuard::Asking` (`tool_guard.rb:46-48`)
  wraps `PolicySwitch` for every child's gate. Orchestrator ruling: add `cli/tool_guard.rb` and
  `approval/queue.rb` to T15's Files, and give both `#rule`. Gate normalises a bare callable once at
  construction through one named adapter, rather than asking only `#rule`, so the ~20 specs that
  hand Gate a lambda (several held by T1, T4 and T16) stay untouched. Every production policy
  answers `#rule` itself. The sentence is chosen by rung: only a triage or rules refusal says
  unliftable, and every surfaces refusal, a timeout included, keeps today's sentence.

- **T11 escalated (retired rows pinned by a spec).** The only references were the table's own spec
  rows, so the rows and their pins were removed together.
- **T21 escalated (two seams).** (1) A chunk child cannot be tool-less, since every catalog role holds
  `read_file`. Ruling: a new read-only `diff_critic` role spawned via `RoleSpawn#within` in a
  detached checkout of the reviewed head. (2) The window book reaches `Command::Surface` only via
  `window: backend.context_window` in `Wiring#assemble_surface`, which the orchestrator applies at
  T21's landing, after T4.
- **T1 surprise → T1 fix round.** A timeout of a non-ASCII command makes mixlib's timeout message
  raise an encoding error, and `Exec::Core#killed` builds its message the same way. `exec/local.rb`
  and `exec/core.rb` are added to T1's fix round as a deliberate scope expansion. The tool name in
  `ResultBlock.of`'s refusal needs one line in `tool_runner.rb`, applied after T3 lands.
- **Commit-hook flake under agent load.** `62_approval_spec`'s "two parked approvals" (a recorded
  load flake) tripped 2 of 4 landing commits; each was retried green.

### Follow-ups found in flight (not cards)

- `Bench::CLI::RunRecorder` never journals `capability_degraded`, so the cache-ratio withholding
  only fires on hand-built journals (T9's review).
- `Approval::Gate.from_journal` and `LocalLanding::Approvals.from` still raise a bare `ArgumentError`
  on a malformed `approved` (T5). Those files belong to T17 and T19; each card is told.
- F116 is not closed until T19's lock lands, because an unlocked landing checkout that merged once
  still reads "folded into" (T10's review). A retained checkout left mid-rebase still blocks the
  retry's `git switch` (F99 remainder).
- `LocalLanding::Approvals.from` treats `approved: "maybe"` as not approved without a word (T5 review),
  which is T19's to decide. `Approval::Gate#absorb` (`gate.rb:344`) raises a bare `ArgumentError`
  from `epic_submit.rb:399, 424`, which is T17's.
- **Human decision owed (T8 review S3).** `Sensitivity`'s path classifier is lexical, so a symlink
  inside the project (`link -> /`) may carry a read tool past the gated and denied tiers. T8's fix
  round adds a real-path check to `ComposedTerm`'s automatic approval only (fail closed). Whether
  the classifier itself should resolve links is a boundary ruling, not taken here. **Observed in T8's
  fix round:** with `h -> $HOME` inside the project, `read_file h/.config/gh/hosts.yml` classifies
  ordinary and returns the token file verbatim, although the direct spelling is denied, and
  `read_file link/etc/shadow` reaches the tool with nobody asked.
- T8 review S5: subagent children are judged by rules built over the parent's `project.cwd`, while
  a child's `bash` runs in its own worktree. This predates the chunk and is a follow-up card.
- Open decision (T8 review S4): whether `exempt` needs a table-wide cap, since many one-entry
  patterns can together lift the table.
- Predates the chunk (T4 review): a mode switch under `--no-journal --nvim` raises `NoMethodError`,
  because `JournalTee` has no `#record`.
- T4's fix round takes `cli/conductor.rb`, so that `Supervisor#stop` runs before `Chronicle#close`.
  A signal-driven shutdown otherwise raised and hung. T13 takes the file afterwards, from `HEAD`.
- **T7 review rulings.**
  - The plan-step edge is consumed only by a **committed** compaction, not by a warm defer. Without
    that, the signal never compacted in a real chat.
  - A cut holds while the head it was **committed at** is on the chain; "the cut wins over
    `keep_last`" is dropped.
  - `compaction_cut` records are deltas with a parent content digest, since whole records grew
    quadratically.
  - The latch state is journaled for replay, a retreat is journaled, and a cut names its strategy
    (a cut from another strategy is not held).
- **Open decisions for the human (T7 review).** S4: held replacements never re-collapse, so ten cuts
  under summarize-conversation render ten summaries, with no remedy once the window fills past the
  cut. S5: a `/pin` on a turn inside a held range is silently ignored.
- **T21 review B1: a running `/critique` ignored Ctrl-C and SIGTERM.** Its children run in the
  unsupervised middleware phase.
  - Ruling: seam B. `Repl#middleware_turn` wraps `@middleware.call` in `@conductor.supervise`, which
    covers every middleware that answers without a model turn (`/meta generate` included).
  - `repl.rb` is T6's, so after T6 lands T21's diff is ported onto a fresh worktree from `HEAD`, seam
    B is added with a production-delivery spec, and the whole card gets its one re-review.
- Follow-up (T19 review): a chat's `/implement-epic` cannot be interrupted, because the signal traps
  point at `Signals::NULL` during a slash command. T21's seam B (supervising middleware turns) may
  cover it, so check once both land.
- T14's review took the `seed` filter in scope, since it is the card's own sentence about the chat's
  `Context#extra`. Ollama-only keys no longer reach another provider's wire.
- **A deliberate file share: T24 and T21 both hold `cli/wiring.rb` and `wiring_spec.rb`.** They edit
  different regions (`#backing` against `#assemble_surface`), and the orchestrator merges them at
  landing. This keeps the critical path moving instead of waiting for T21's re-review.
- **Human decision owed (T23 review SF2, security, predates the chunk).** With automatic approval on,
  only a literal protected path is refused before the model judge. `cat ~/.ssh/id_rsa`,
  `cat $HOME/.ssh/id_rsa`, `cd ~/.ssh && cat id_rsa` and `sh -c 'cat …'` all reach the judge, and ran
  once it said APPROVE. `--auto-approve` already had this gap; T23 makes it one `/mode +auto_approve`
  away. The fix belongs to the triage rung (`approval/escalation.rb`).
- **Follow-ups from T23's review:**
  - Refuse `--auto-approve --non-interactive` at launch, as `--windows --no-journal` already is.
  - The `--auto-approve` help text in `exe/lain` and `docs/commands.md:38` still describes the old
    opt-in surface.
  - T29 rewords `method.md`'s reason for banning `+auto_approve`, but keeps the ban.
- **T24 is redesigned on measured evidence.** The review ran a real ollama 0.32.12 against the
  production wiring.
  - **Why the pre-send estimate failed.** It broke three ways:
    - a stale smaller runner made the window book refuse every prompt forever;
    - a refused request yields no reading, so compaction never fired (the card's "compaction first"
      trigger);
    - tokens per byte vary 3.3x by content, so the half-estimate witness had both a hole (ollama's
      mode B silently drops old messages) and a sticky false alarm.
  - **Ruling.** Send `"truncate": false` to ollama. The server then refuses an over-window prompt with
    HTTP 400 carrying the exact prompt count and context size. `RequestBudget` translates that into
    `window_pressure over_window`, a refusal that names the moves, and a believed reading so compaction
    fires.
  - **Also dropped:** the refused prompt's user turn does not stay on the head, and the calibration
    and the ratio witness are gone.
  - **AC changes.** AC1, AC3 and AC5 are restated to match. Open decision 2 (window-relative
    per-tool bounds) still stands.
- **A second deliberate file share: T28 and T27 both hold `frontend/tty.rb`, `cli/wiring.rb` and
  `tty_spec.rb`.** T27 edits the typeahead hold and the `goal_off` route; T28 edits `render_arrival`
  and the `tty_factory` predicate. They are merged at landing. T13's integration check caught one
  real cross-card break: the epic seat builds `HumanReplies` without a question queue, so a null
  object now stands in for it.
- **Integration check 2, partial (2026-09-14):**
  - `bin/comment-census --check-tickets`: 0 unclassified. The one ambiguous `C1` in
    `frontend/completion.rb` is Unicode's control block and predates the chunk.
  - `rake core:build`, then `rspec --tag core spec/lain/core/grep_parity_spec.rb`: 16 examples,
    0 failures, T2's added witness included.
  - `cargo test` and `cargo clippy -D warnings`: clean.
- **T27 review ruling:** a `/`-command line read at a `[y/N]` is never a decision. It is held for
  `you>` and the prompt reopens (fail-closed). Before this, `/goal off` typed at a drawn approval
  denied the call and was lost, so the goal ran on.
- Follow-up (T27 review): `Switchboard#apply` journals a no-op `policy_switch escalation ->
  escalation` on every layer flip, which is noise for bench readers.
- **Integration checks 1–3 (2026-09-15, `main` at `4c8089ab`, no other parallel_rspec running):**
  - Check 1: `rake pspec` at 12 workers gave **18,701 examples, 0 failures, 13 pending** in 64s.
    Every one of the 12 workers reported. That is +864 over the pre-chunk 17,837.
  - Check 3: the three discipline specs together gave 15 examples, 0 failures.
  - `bundle exec rubocop`: 1,577 files, no offenses.
  - Check 2 (census, core parity, cargo) is recorded above.
- **T29's drive record.** The command and output for each drive, 62 in phase 1 and more in phase 2,
  is in `~/tmp/lain-T29/records/`. Strings not driven are marked `(prediction, not yet driven)` in the
  scenarios.
- **Possible T28 gap (T29 phase 2).** With `notify` on, a `--no-nvim` chat's inline `[y/N]` rings no
  bell, because only one-line arrival notes ring and a plain chat draws none for approvals. That fits
  the card's AC, which names questions, but the layer's description says approvals too. Open
  decision, and the scenarios record it as current behaviour. `/help` has no per-layer description yet
  (T28, deferred).
- **Found by T29's drives against the built binary (follow-ups):**
  - `lain chat` with stdin redirected from a regular file re-reads earlier prompts in a loop once a
    prompt triggers a `bash` call. `/dev/null`, a pipe and a TTY are fine.
  - `secret-boundary.md` §2's own example, `exempt = ["fixtures/.env"]`, is now refused at load by
    T8's exempt check. Check whether that is a false positive of the per-entry probe.
  - `lain review <branch>` in a repo with no `main` still refuses without naming `--base`; only
    `/review` was changed.
- **Follow-ups from T24's re-review:**
  - `WindowBook` keeps a stale smaller runner's context after ollama reloads a bigger one, so
    occupancy reads about 100% and compaction can fire early.
  - The Anthropic "prompt is too long" 400 is not translated, because its numbers are only in message
    text.
  - Whether ollama.com refuses rather than truncates an over-window prompt is unverified; a 200 with
    `truncate: false` was confirmed.
- **Follow-up (T22 review S4):** adopted actors are not lineages to `Bench::Session::Lineages`. In a
  real epic session about 140 of 194 child turns are invisible to consolidate, improve and friction.
- **T25:** a concurrent submit and re-submit may both write one stage_transition pair. That is
  accepted as `Epic::InFlight`'s at-least-once rule, since the fold takes the last start.
- Follow-ups (T20 review N1): store pre-images in the content store by digest, since the log keeps
  every turn's bytes for the whole session.
- **T17 review rulings.**
  - Reading the answer leaves `Approval::Gate`: the human's words ride with the resolved answer.
    Before this, an nvim `:w` approval was journaled as a denial.
  - A reply that is not an approve or deny word is recorded as `unrecognised`, not as the human's
    denial.
- **Passed to T13 from T6's review:**
  - Closing the cockpit `command>` reader when the Ctrl-C grace countdown starts needs
    `Conductor#counting_down?` (hold the ask's shutdown during `supervise`), plus one check in the
    reader.
  - Until then, the countdown's c/w/r keys are blocked only while a call or question is pending.
- T6: the question-arrival line still reads "(/inbox here, or the inbox buffer in nvim)", not
  "lain://inbox", because `tty.rb` is T13's. T13 aligns the wording.

### Close-out (2026-09-15)

- **All 29 cards landed on `main`.** Every card was panel-reviewed except T11 and T29, which were
  exempt.
  - The panel caught blockers the green suites had missed: T5, T6, T7, T8, T13 (three fail-open
    approval paths), T17, T19, T20, T21, T22, T24, T25 and T27.
  - T24 was redesigned on measured ollama evidence.
  - Six cards were ported or re-landed onto a fresh `HEAD` after sibling landings: T21, T13, and the
    wiring and TTY file shares.
- **Integration checks 1–3 pass** (recorded above).
- **Manual checks 4–9 are still owed:** the reachability walk; F88/F89 end to end; the nvim-first
  cockpit (T29 drove parts of it); compaction at scale; `/critique` of lain on itself; the next
  `/manual-qa` round.
- **Human decisions still owed (above):**
  - should the read tools' secret-path check resolve symlinks;
  - the triage rung for `~`/`$HOME` spellings under automatic approval;
  - an `exempt` table-wide cap;
  - compaction S4 (summaries accumulate) and S5 (a pin inside a held cut);
  - `[tests]` strictness (Open decision 1);
  - the plain-chat notify bell on `[y/N]`.

### Landed

- T11 `5154d819` · T16 `13b5e71c` · T9 `a0683dd8` · T10 `4b0778f8` · T15 `0cf8d2f1` · T5 `60998de4` · T1 `cf3505a3`
  · T2 `7b9d9589` · T4 `69df4d08` · T3 `04a9d40a` (with the tool-name call site T1 left owed) · T8 `c6f64656`
  · T7 `acfed808` · T6 `caa2c5f7` · T18 `dac580d4` · T12 `afb5e73f` · T14 `bfe984e9` · T19 `51b0be4d`
  · T23 `1cfdf970` · T21 `3ec1dc79` (with the middleware-phase supervision) · T17 `7016ab7d` · T20 `3af82b61`
  · T26 `c3ccaa39` · T25 `f13d276d` · T22 `ad045078` · T24 `4cf30b98` · T13 `70c0782f` · T27 `cb816f58`
  · T28 `9d47a7b1` · T29 `a16ff7a2`

---

## Tasks

### T1 — Give every tool result one text boundary before it can reach a commit   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/tool/result_block.rb`, `lib/lain/tools/bash.rb`,
`spec/lain/tool/result_block_spec.rb`, `spec/lain/tools/bash_spec.rb`,
`spec/lain/seams/tool_text_boundary_spec.rb` (new spec)
**Reuse:**
- The Rust `read_text` acceptance rule (`ext/lain/src/read_text.rs:72-139`): BINARY-tagged bytes
  that are valid UTF-8 are text.
- `ReadFile.not_text`'s refuse-by-name wording shape (`tools/read_file.rb:634`).
- `spec/lain/seams/read_to_turn_spec.rb` as the seam-spec template.

**Shared-file wiring:** none
**Reachable from:** `Agent::ToolRunner#answer` → `Tool::ResultBlock.of` (`agent/tool_runner.rb:437-440`)
on every tool call of every agent, parent and child; `Tools::Bash` is built at
`CLI::Wiring::BaseTools` (`cli/wiring.rb:156`).

**The problem.** F88: a `bash` result carrying any byte ≥ 0x80 — a valid `✅` included — tears the
ask after the command ran. Every other byte-carrying tool has its own half-answer, or none.

**The boundary.** `ResultBlock.of` becomes the one place a result's text is made committable:
- String content (and each text part of Array content) whose bytes are valid UTF-8 is re-tagged
  UTF-8 **without mutating the input**: `String.new(s, encoding: Encoding::UTF_8)`, never
  `force_encoding`, which raises `FrozenError` on a frozen literal and would rewrite a caller's
  string.
- Content that is not valid UTF-8 becomes an `is_error` result that **names the tool and says the
  output was not text**, carries the valid prefix's byte count, and suggests a narrower action
  (`| head -c`, `xxd`, `file`).
- It is not scrubbed silently. Replacement characters would be bytes the command never printed.

**`Canonical` stays strict**, and the shared laws stay as they are (`spec/support/shared_examples/canonical_laws.rb:181`).
The boundary exists so commit never sees the bytes.

**Bash.** `Tools::Bash`'s timeout and exec-error messages (`bash.rb:283`) pass through the same
boundary, since they embed the same bytes.

**One rule per kind of tool, shared with T2.**
- **Tools whose output is a document** (`bash`, and every tool that does not escape its own
  output) refuse invalid text by name, here.
- **Tools that enumerate names or matched lines** (T2's listings, `grep`, `ast_search`) escape
  their own invalid bytes as `\xNN` before returning. Their output therefore never reaches this
  refusal.

**Acceptance criteria:**

```gherkin
Scenario: valid UTF-8 output from a shell commits
  Given a bash call whose stdout is the bytes of "✅ ok" read as ASCII-8BIT
  When the call is answered and the turn is committed
  Then the tool_result carries "✅ ok" and the ask continues

Scenario: output that is not UTF-8 is refused by name, not torn
  Given a bash call whose stdout contains the byte 0xE9 outside a valid sequence
  When the call is answered and the turn is committed
  Then the tool_result is an error naming bash and saying the output was not text
  And the ask continues to its next model call
  And no run_interrupted record is journaled

Scenario: a timed-out command's non-UTF-8 output does not tear the ask
  Given a bash call that times out after printing invalid UTF-8
  When the call is answered
  Then the tool_result is an error result and the turn commits

Scenario: both bash arms render the same committable content
  Given the same non-ASCII valid UTF-8 output on the string arm and on the term arm
  When each result block is built
  Then the two contents are byte-identical and both are UTF-8 tagged

Scenario: a frozen tool result is not mutated
  Given a tool that returns a frozen ASCII-8BIT string of valid UTF-8 bytes
  When its result block is built
  Then the block's content is UTF-8 and the tool's string is unchanged
```

→ spec file: `spec/lain/tool/result_block_spec.rb`, `spec/lain/tools/bash_spec.rb`,
`spec/lain/seams/tool_text_boundary_spec.rb` (the first two scenarios drive a real `Agent`, a real
`Tools::Bash` and a `Provider::Mock`, and commit through a real `Timeline`)

**Escalation triggers:**
- `ResultBlock.of` already raises `ArgumentError`, which `ToolRunner::Answers` converts
  (`tool_runner.rb`). If an invalid-text result has to travel as a raise rather than as a returned
  error block, **stop**: T3 owns `tool_runner.rb` in this wave.
- `spec/lain/tools/bash_spec.rb:311` compares the two arms' `Tool::Result#content` encodings,
  **upstream** of the boundary, so it does not change. The encoding assertion this card adds is at
  the **block** level. If a card change makes the arms' `Tool::Result` encodings differ, stop:
  that is an arm change, not a boundary change.
- If `Exec::Core` output reaches `ResultBlock.of` by a path that bypasses it, name the path and
  stop.

---

### T2 — Make listings, grep and ast_search tolerate a name or line that is not UTF-8   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/middleware/withhold_secret_paths.rb`, `lib/lain/tools/grep.rb`,
`lib/lain/tools/ast_search.rb`, `lib/lain/tools/list_files.rb`, `lib/lain/tools/glob.rb`,
`spec/lain/middleware/withhold_secret_paths_spec.rb`, `spec/lain/tools/grep_spec.rb`,
`spec/lain/tools/ast_search_spec.rb`, `spec/lain/tools/list_files_spec.rb`,
`spec/lain/tools/glob_spec.rb`, `spec/lain/core/grep_parity_spec.rb`
**Reuse:**
- `Survey::Unit.lines_of` (`survey/unit.rb:57-63`) for a byte-level split.
- `Sensitivity.readable?` (`sensitivity.rb:380-382`) and the existing MALFORMED withholding path
  (`withhold_secret_paths.rb:281-298`).
- `Lain::FILESYSTEM` (`paths.rb:20`) for what a path's encoding is.

**Shared-file wiring:** none
**Reachable from:** `CLI::ToolGuard.stack` (`cli/tool_guard.rb:131-137`) builds
`WithholdSecretPaths` on every agent; `Tools::Grep`/`AstSearch`/`ListFiles`/`Glob` are built at
`CLI::Wiring::BaseTools`.

**The problem.**
- F103: one non-UTF-8 filename withholds a whole listing, naming only `(ArgumentError)`.
- `grep`/`ast_search` raise the whole search on one bad filename.
- F129: `grep` skips the rest of a file on one invalid line and says nothing, which under
  `LC_ALL=C` is every non-ASCII file.

**The rules this card sets:**
- **Names.** A name that is not UTF-8 cannot be classified. That fails closed as today's doctrine
  says (`Sensitivity.readable?`).
  - `WithholdSecretPaths` splits by bytes and withholds **exactly that row** as MALFORMED, never
    the whole listing.
  - `grep`/`ast_search` skip such a file and **count** it in a trailer
    (`N file(s) skipped: unreadable name`) beside the existing cap trailer.
- **Matched lines.** Grep reads each file as bytes and matches an ASCII pattern against bytes.
  - A matched line whose bytes are not UTF-8 is returned with each invalid byte escaped as `\xNN`.
  - No file is skipped for its content's encoding.
- **Committable output.** This is T1's second rule: these tools escape their own bytes, so nothing
  they return reaches T1's refusal. T1's boundary is the backstop, not the plan.

**Acceptance criteria:**

```gherkin
Scenario: one unreadable filename withholds one row
  Given a directory holding "ok.rb" and a file whose name bytes are "bad\xFF.rb"
  When list_files runs through the guarded tool stack
  Then "ok.rb" is listed
  And the trailer says "1 path withheld (malformed)"
  And the result is not an error

Scenario: grep survives an unreadable filename and says so
  Given a tree holding a file with a non-UTF-8 name and a file containing "needle"
  When grep searches for "needle"
  Then the match in the readable file is returned
  And the result says 1 file was skipped for an unreadable name

Scenario: grep returns a Latin-1 match with its bytes escaped
  Given a Latin-1 file whose line is the bytes "caf\xE9 zzzmarker" and a UTF-8 file containing "zzzmarker"
  When grep searches for "zzzmarker" through the guarded stack and the turn is committed
  Then both matches are returned
  And the Latin-1 line reads "caf\xE9 zzzmarker" with the byte escaped as text
  And the tool_result is not an error

Scenario: a C locale does not skip every non-ASCII file
  Given LC_ALL=C and a UTF-8 file containing "café needle"
  When grep searches for "needle"
  Then the line is returned
```

→ spec file: `spec/lain/middleware/withhold_secret_paths_spec.rb`, `spec/lain/tools/grep_spec.rb`,
`spec/lain/tools/list_files_spec.rb`, `spec/lain/tools/ast_search_spec.rb`,
`spec/lain/tools/glob_spec.rb`

**Escalation triggers:**
- `spec/lain/core/grep_parity_spec.rb:325` ("DIVERGES on invalid UTF-8") is a deliberate witness of
  a Ruby/Core divergence. It is `:core`-tagged, so the default suite never runs it; run it by
  integration check 2. If this card closes the divergence, update it deliberately and say so. If
  it widens it, stop.
- `withhold_secret_paths_spec.rb:253` requires an ordinary listing to be byte-identical to the
  tool's own output. A byte split must not normalise a trailing newline — stop if it does.
- If byte-matching a non-ASCII pattern changes grep's result for any existing spec, stop and
  confirm the match rule.

---

### T3 — Never leave a tool_use unanswered, and never move the head under an in-flight run   [wave 1] [risk: high]

**Depends on:** none
**Files:**
- `lib/lain/tool/cancellation.rb` (new)
- `lib/lain/agent/tool_runner.rb`, `lib/lain/agent/tool_delivery.rb`, `lib/lain/agent.rb`
- `lib/lain/cli/resume/cancellation.rb`, `lib/lain/cli/resume.rb`, `lib/lain/cli/command/rewind.rb`,
  `lib/lain/cli/command/undo.rb` (its private `quiet!` predicate is extracted so `/rewind` can
  share it)
- `spec/lain/tool/cancellation_spec.rb` (new), `spec/lain/agent/tool_delivery_spec.rb`,
  `spec/lain/agent_spec.rb`, `spec/lain/cli/command/rewind_spec.rb`,
  `spec/lain/cli/command/undo_spec.rb`, `spec/lain/seams/tool_cancellation_spec.rb`,
  `spec/lain/cli/resume_spec.rb`

**Reuse:**
- `ToolRunner::Answers` and `Resume::Cancellation`'s block format (`cli/resume/cancellation.rb:39-95`).
- `Event.pending_tool_use?` (`event.rb:83-86`).
- `Context::Conversation` (`context/conversation.rb`) as the assertion.
- `Command::Undo#quiet!`'s in-flight predicate (`command/undo.rb:116-125`) and
  `Agent#dispatching?` (`agent.rb:251`).

**Shared-file wiring:** `require_relative "tool/cancellation"` in `lib/lain/tool.rb`
**Reachable from:** `CLI::Repl::Ask#attempt` → `Agent#ask` on every prompt; `ToolDelivery` is built
by `Agent`; `/rewind` is registered in `Command::Surface#history_commands`
(`command/surface.rb:149`).

**Two ways the Agent's head goes wrong today:**
1. **F89.** Any non-`Async::Stop` raise while settling tool results (T1's encoding refusal was one;
   `Budget#check_tokens!` after a `tool_use` commit is another) leaves the `tool_use` unanswered.
   The next ask commits user text over it, and every later derivation refuses.
2. **F96.** `/rewind` while a tool call is parked succeeds, then the settling run re-commits every
   rewound turn.

**The design.**
- **Move the cancellation notice** to `lib/lain/tool/cancellation.rb`. That pays the layering debt
  `tool_runner.rb:59-69` names; `CLI::Resume::Cancellation` and `ToolRunner::Answers` both read it.
- **At the tear.** `settle` runs in an `else` outside `perform`'s rescue
  (`tool_delivery.rb:62-76`), so the repair wraps `settle` itself.
  - A non-Stop failure there commits a user turn that **rebuilds every block** as an errored
    notice from `Tool::Cancellation`, then lets the error through to `Ask`.
  - It must **not** reuse `answers.blocks` (`tool_runner.rb:288-290`, what `cancelled_delivery`
    does today): those are the blocks whose commit just raised, and re-committing them raises
    again.
  - The notice says the call **errored**, distinct from "cancelled" and "no result".
- **At the budget.** `Budget#check_tokens!` raises inside `Agent#commit_and_account`
  (`agent.rb:459`), after the `tool_use` commit and **before** any `ToolDelivery` exists. So that
  path is rescued in `Agent`, which commits the same errored-notice turn and re-raises.
- **At the next ask.** `Agent#ask` answers a pending `tool_use` at the head before committing user
  text: the in-process twin of `Resume#settled`.
- **In flight.** `Agent#rewind` refuses while `dispatching?`. `/rewind` gets `/undo`'s `quiet!`
  predicate and names the parked call. Its refusal restates what the human typed — a digest stays a
  digest, which is F122.
- **Damaged journals.** `Resume#settled`'s refusal for a journal with user text **on top of** an
  orphan names the orphan's position instead of healing it (Open decision 3).

**Acceptance criteria:**

```gherkin
Scenario: a tear while settling tool results still answers the call
  Given an agent whose tool result cannot be committed
  When the ask runs
  Then the timeline's head is a user turn answering every tool_use with an errored notice
  And none of the original result content is in that turn
  And the Messages API conversation check reports no violation

Scenario: the next ask never builds on an unanswered call
  Given a timeline whose head is an assistant tool_use with no answer
  When the human asks something new
  Then the request sent carries a tool_result for that call before the new user text

Scenario: a token budget refusal after a tool_use leaves no orphan
  Given a budget that is exceeded by the turn that emits a tool_use
  When the ask stops
  Then the head answers that tool_use

Scenario: rewind refuses while a tool call is parked
  Given an agent parked on an ask_human call
  When the human types /rewind 1
  Then the refusal names the parked call and says nothing moved
  And answering the question afterwards commits no rewound turn again

Scenario: a digest target keeps the human's words in the refusal
  Given a head that is an assistant tool_use awaiting results
  When the human types /rewind with that turn's 4-character digest prefix
  Then the refusal quotes that prefix, not a count

Scenario: the resumed session still repairs its head the same way
  Given a recorded session whose head is an unanswered tool_use
  When it is resumed
  Then the repair blocks equal the ones a live tear commits, apart from the notice kind
```

→ spec file: `spec/lain/agent/tool_delivery_spec.rb`, `spec/lain/agent_spec.rb`,
`spec/lain/cli/command/rewind_spec.rb`, `spec/lain/tool/cancellation_spec.rb`,
`spec/lain/seams/tool_cancellation_spec.rb` (the first two scenarios run a real `Agent` over a real
`Timeline`)

**Escalation triggers:**
- `ToolDelivery`'s `else` branch is documented as intentionally unrescued. The "Unpairable:
  interrupt outranks repair" ordering (`tool_delivery.rb`, spec "lets the interrupt through when a
  stranded call names an id…") must survive. If the new rescue changes that ordering, stop.
- `cli/resume/cancellation.rb:27-33` names a duplicate-id hole. If moving the notice needs that hole
  closed first, stop and name it.
- Refusing `/rewind` while `dispatching?` also refuses it at `human>` while a *subagent's* question
  is parked and the parent is idle-in-tool. If `fork_spec.rb:107-135`'s narrower gate is shown to be
  the intended rule, stop and confirm which predicate `/rewind` takes.

---

### T4 — Route every record to the session file, and keep the display channel for display   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/cli/wiring.rb`, `lib/lain/cli/chronicle.rb`,
`lib/lain/cli/wiring/toolset_build.rb`, `lib/lain/tools/subagent.rb`,
`lib/lain/tools/subagent/actor.rb`, `lib/lain/supervisor.rb`, `lib/lain/supervisor/restart.rb`,
`spec/lain/cli/wiring_spec.rb`, `spec/lain/cli/chronicle_spec.rb`,
`spec/lain/tools/subagent/actor_spec.rb` (new), `spec/lain/supervisor_spec.rb`, `spec/lain/supervisor/restart_spec.rb`,
`spec/lain/cli/wiring/toolset_build_spec.rb`, `spec/journal_routing_discipline_spec.rb` (new spec)
**Reuse:**
- The scribe's split rule: record data goes to the raw journal, live-view telemetry to the tee
  (`session_record/scribe.rb:128-141, 256-262`; `chronicle.rb:192-203`).
- `Chronicle#record_journal` (`chronicle.rb:238`), which already exists and is the tee under
  `--nvim`; round 16's Open decision 5 pointed at it.
- The `ObjectSpace` sweep in `spec/journalable_surface_spec.rb:10-14`.
- The chronicle read-back fixture at `wiring_spec.rb:1053-1054`.

**Shared-file wiring:** none
**Reachable from:** `CLI::ChatLaunch#call` → `Wiring#run` (`wiring.rb:279-289`): the five
construction sites `:419, :637, :648, :681, :813`.

**The problem.** F92: `shell_arm`, `isolation_lease`, `handback`, `worker_reaped`,
`drain_timed_out` and the subagent seam's records (`stagger`, `answer_bounded`,
`lease_not_reclaimed`, spawn-policy floor, `refuse_unpermitted`) go to the display `Channel` and are
dropped.

**The design.**
- **Journal-role sites.** Give `Chronicle` a second reader, `#durable_journal`.
  - It is the raw session journal under every setting and **never** the tee, and it is memoised
    (`Chronicle::Null` answers one memoised null journal).
  - Hand it to the five journal-role sites and to the spawn seam's journal, which the child `bash`
    also receives (`toolset_build.rb:266`).
  - Display-role sites keep `channel`.
  - Also route `Supervisor::Restart`'s `WorkspaceBlob` (`supervisor/restart.rb:271`), which goes to
    the channel today.
- **The existing `record_journal` callers stay on the tee** — the snapshot slot, degradation and
  the goal journal (`wiring.rb:486, 520, 825`). They are records live views may fold, and they
  reach the file today. Moving them is not this card's defect.
  - The rule the discipline spec states: **a record a live view folds goes to `record_journal`;
    a record nothing live folds goes to `durable_journal`.**
  - T17's `QuestionsConsumed` is the first kind.
- **The child Agent's own journal stays off the file** (`TurnUsage`/`ToolCancelled`; see
  Grounding §3). Route it to `Channel::Null` **explicitly**, with a comment naming salvage, cache
  waste and ledger pricing, so the choice is visible rather than accidental.
- **Actor lifecycle `Message`** already reaches the file through observer → scribe. Drop its journal
  leg so it is written once.
- **Discipline spec.** Drive a real `Wiring` with a recording `Chronicle` and a spy display channel.
  Every `Telemetry::Journalable` type pushed onto the channel is either one `Decorators.for`
  renders, or also present in the chronicle.

**Acceptance criteria:**

```gherkin
Scenario: the bash tool's arm record reaches the session file
  Given a chat session wired by CLI::Wiring with a recording chronicle
  When a bash call runs
  Then the chronicle holds a shell_arm record for that call

Scenario: a worktree lease is on the record
  Given a chat session wired with --isolation worktree and a recording chronicle
  When a subagent dispatch leases and releases a worktree
  Then the chronicle holds an acquire and a release isolation_lease record, once each

Scenario: nothing a collaborator journals is lost to the display channel
  Given a real Wiring with a recording chronicle and a spy display channel
  When a session runs a bash call, a subagent spawn and a supervisor settle
  Then every journalable record on the display channel is either rendered by the TTY decorators or also in the chronicle

Scenario: a child's own usage is not written as the parent's
  Given a chat session that spawns a one-shot subagent
  When the child completes
  Then the session file holds no turn_usage record whose digest is a child turn
  And the salvage and ledger readers of that file see only the parent's requests

Scenario: an actor's lifecycle message is recorded once
  Given an adopted actor that stops
  When the session file is read
  Then exactly one message record carries that stop

Scenario: records reach the file with no journal-dependent middleware
  Given a chat session launched without --nvim
  When a bash call runs
  Then the session file holds a shell_arm record
  And the status feed received no shell_arm record
```

→ spec file: `spec/journal_routing_discipline_spec.rb`, `spec/lain/cli/wiring_spec.rb`,
`spec/lain/cli/chronicle_spec.rb`

**Escalation triggers:**
- Anything routed to the **tee** reaches `StatusFeed` and `FleetWindows`. If a record this card
  routes changes `run_tokens`, occupancy or the fleet window cap in an existing spec, stop: that
  record belongs on the raw path.
- `Chronicle::Null#record_journal` opens a `/dev/null` File per call (`wiring.rb:821-825` notes it).
  If the new reader cannot be memoised on `Chronicle`, stop.
- A `WorkerReaped` written after `Conductor#close` raises `Journal::Closed` (`journal.rb:162`). If an
  existing shutdown spec goes red that way, stop and confirm the close ordering rather than
  swallowing it.
- `wiring_spec.rb:1237-1266, 1454-1500` and `:3295-3316` read `channel.events`. They move to the
  chronicle; if one cannot, name it and stop.

---

### T5 — Refuse to fold a sign-off journal it could not read whole   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/cli/session_journals.rb`, `lib/lain/approval/signoff_queue.rb`,
`lib/lain/cli/epic_submit.rb`, `lib/lain/cli/epic_queue.rb`, `lib/lain/cli/epic.rb`,
`lib/lain/cli/epic_driver/factory.rb`, `lib/lain/cli/epic_land.rb`, `lib/lain/cli/epic_finish.rb`,
`lib/lain/cli/epic_mount.rb`, `spec/lain/cli/session_journals_spec.rb`,
`spec/lain/approval/signoff_queue_spec.rb`, `spec/lain/cli/epic_submit_spec.rb`,
`spec/lain/cli/epic_queue_spec.rb`, `spec/lain/epic/progress_spec.rb`,
`spec/lain/cli/epic_land_spec.rb`, `spec/lain/cli/epic_finish_spec.rb`,
`spec/lain/cli/epic_mount_spec.rb`, `spec/journalable_surface_spec.rb`
**Reuse:**
- `SessionJournals::Tally`/`Reading` (`session_journals.rb:149-160`).
- `EpicQueue::UnreadableRecord` (`epic_queue.rb:45`).
- `Bench::Session::Loader#posture`'s rescue-and-translate (`bench/session/loader.rb:302-306`).
- The NDJSON record prefix `{"ts":"…","type":"…"` (`journal.rb:249`).

**Shared-file wiring:** none
**Reachable from:** `exe/lain` `epic submit` → `CLI::EpicSubmit#decide` (`epic_submit.rb:412-422`);
`CLI::EpicQueue` approve/deny; `EpicDriver::Factory#signoffs` (`factory.rb:431-433`) under
`/implement-epic`; `CLI::Epic::Journals#walk` (`epic.rb:445-484`) under `lain epic status`.

**The problem.**
- **F93.** A truncated `gate_decision` line is skipped, the queue folds empty, and
  `Epic::Stage#ensure_open!` opens the next stage.
- **F114.** A parseable but malformed record raises `ArgumentError` with a backtrace.

**The design.**
- **Record where damage is.** `SessionJournals` records file and line for each unparseable line.
- **Strict is the default.** `SessionJournals` refuses on damage unless a caller opts into
  leniency. Only the `EpicQueue` **listing** opts in, and it keeps its warning.
  - The refusal is `Unreadable < Lain::Error`, naming the file, the line and the remedy ("move the
    damaged file aside or repair the line; nothing was decided").
  - Inverting the default means a fold nobody listed — `epic_land.rb:138-140`,
    `epic_finish.rb:134`, `epic_mount.rb:254`, or the next one written — is safe without being
    named.
- **Refuse only what could matter.** Using the record-prefix sniff:
  - a line whose type prefix is unreadable, or names `gate_decision`/`stage_transition`, refuses;
  - a torn line of any other type is counted and skipped, as today.
- **The sniff rests on `"type"` being the second key** after `"ts"` (`telemetry.rb:20`), which is
  a convention. Pin it: extend `spec/journalable_surface_spec.rb`'s `ObjectSpace` sweep so every
  journalable record serialises with `ts` then `type` first.
- **At the fold boundary,** `SignoffQueue.from_journal` translates `ArgumentError` into
  `UnreadableRecord`.
- **The carriers' write-side `ArgumentError` is untouched.**

**Acceptance criteria:**

```gherkin
Scenario: a torn sign-off line blocks the next stage instead of opening it
  Given research parked under the deferred policy
  And that gate_decision line halved in its session file
  When lain epic submit epic_plan runs
  Then it exits 1 naming the file and line and saying nothing was decided
  And no gate_decision or stage_transition is journaled

Scenario: a torn line of an unrelated type does not block a gate
  Given a session file whose only damaged line is a torn turn record
  When lain epic submit research runs
  Then the gate proceeds
  And lain epic queue's listing still warns about the unreadable line

Scenario: a malformed but parseable gate_decision refuses by name
  Given a gate_decision whose approved field is "maybe"
  When lain epic queue, submit and status each run
  Then each exits 1 with one line naming the record and no backtrace

Scenario: the driver will not start issues over an unreadable sign-off
  Given /implement-epic on an epic whose issue_plan sign-off line is torn
  When the run starts
  Then it refuses naming the file and starts no issue

Scenario: landing and finishing refuse over a torn sign-off too
  Given an epic whose implementation gate_decision line is torn
  When lain epic land and lain epic finish each run
  Then each exits 1 naming the file and line
```

→ spec file: `spec/lain/cli/epic_submit_spec.rb`, `spec/lain/cli/epic_queue_spec.rb`,
`spec/lain/cli/session_journals_spec.rb`, `spec/lain/approval/signoff_queue_spec.rb`

**Escalation triggers:**
- `spec/lain/journal_spec.rb` pins `.records` skipping foreign lines. This card must **not** change
  `Journal.records`. If the strict reading needs it changed, stop.
- A live chat's last line can be caught mid-write. If a spec shows a transient refusal on an
  unterminated final line of a watched type, stop and confirm whether an unterminated tail is
  "in progress" (skip) or "torn" (refuse).
- Many specs match `ArgumentError` (`signoff_queue_spec.rb`, `progress_spec.rb`,
  `epic_queue_spec.rb` "a malformed gate_decision record"). They change to the refusal class. If a
  **write-side** spec would have to change, stop.

---

### T6 — In a cockpit, answer questions and approvals in nvim rather than racing the chat's stdin   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/cli/repl/approval_surfaces.rb`, `lib/lain/cli/human_replies.rb`,
`lib/lain/cli/command/small.rb`, `lib/lain/cli/repl/line_scope.rb`, `lib/lain/cli/repl.rb`,
`spec/lain/cli/repl_spec.rb`,
`spec/lain/cli/repl/approval_surfaces_spec.rb`, `spec/lain/cli/human_replies_spec.rb`,
`spec/lain/cli/repl/line_scope_spec.rb`, `spec/reply_surface_discipline_spec.rb`,
`spec/lain/seams/cockpit_answer_surfaces_spec.rb` (new spec)
**Reuse:**
- `ApprovalSurfaces#watch(task, terminal:)` and its `@editor` (`repl/approval_surfaces.rb`).
- `HumanReplies#editor_reply_loop`'s `@editor.attached?` branch (`human_replies.rb:344-345`).
- `Frontend::TTY#render_arrival` (`tty.rb:205`).
- `Frontend::Neovim::ApprovalView`, which already re-projects `reject(&:decided?)` on every poll.
- `Registry#serves_replies?`.

**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring#build_repl` → `Repl` → `LineScope#serve` (`line_scope.rb:70-80`)
on every dispatched line; `HumanReplies#bind_editor` and `ApprovalSurfaces#bind_editor` are called
when `lain up --nvim` attaches.

**The human's ruling (nvim-first).** With an editor attached:
- **No inline answer readers.** The chat pane opens **no `[y/N]` reader and no reader whose line
  can become an answer**.
- **One command-only line reader stays for a dispatching line** (Grounding §4). Without it,
  `/approve` could not be typed while the main agent's own call is parked, because that line never
  settles and `you>` never returns.
  - In a cockpit, the `AnswerLoop` spawned by `HumanReplies#surfaces` becomes that reader.
  - A `/`-command runs, as `classify` already does: `/approve` and `/inbox` included, each owning
    the terminal for its line.
  - A prose line is **held as the next `you>` input** and rendered as `held as your next prompt`.
    It is never an answer and never discarded.
  - `Repl#next_text` takes a held line before reading.
- **Arrivals are one line.** A question arrival renders
  `? <asker> <question…>  -- answer in lain://inbox, or /inbox`. An approval arrival renders
  `! <requester> asks to run <tool>(…)  -- answer in lain://approval, or /approve`.
- **The explicit chat paths remain.** `/inbox` and `/approve` are the deliberate way to answer from
  the chat, and each **owns the terminal** for its line. `/approve` becomes a declared terminal
  reader. `serves_replies?` is split so declaring `/approve` does not swallow it at `human>` (the
  `reply_surface_discipline_spec.rb:213-231` hazard).
- **Nothing is dropped.** Arrivals stay listed in the pending inbox and approval queue, so
  `/inbox`, `/approve` and nvim all see them.

This removes F101's ghost prompt, F102's typeahead-into-approval, and F106's live-looking stale
`[y/N]` **in the cockpit** by construction. `--no-nvim` keeps today's inline readers (T13 adds its
guards).

**Acceptance criteria:**

```gherkin
Scenario: a cockpit chat does not read an approval inline
  Given a chat with an attached editor
  When a gated bash call parks
  Then the chat pane prints one line naming the call and lain://approval
  And no terminal read is open for that pending
  And :LainApprove in lain://approval decides it

Scenario: a cockpit chat does not read a question inline
  Given a chat with an attached editor
  When a subagent's ask_human parks
  Then the chat pane prints one line naming lain://inbox
  And the prompt the human types next is dispatched as a prompt, not as an answer

Scenario: /approve in a cockpit owns the terminal for its line
  Given a chat with an attached editor and one parked approval raised by an actor while the chat is idle
  When the human types /approve and answers y
  Then that pending is approved by the tty surface and no other terminal reader was open during the line

Scenario: /approve reaches the main agent's own parked call
  Given a chat with an attached editor
  And the main agent's dispatching line parked on its own gated bash call
  When the human types /approve in the chat pane and answers y
  Then that pending is approved by the tty surface
  And the dispatching line continues to its next model call

Scenario: a line typed while a turn dispatches is never an answer in a cockpit
  Given a chat with an attached editor
  When the human types "yes please" while a turn is dispatching and a gated call then parks
  Then no approval_decision is journaled from the tty
  And the chat shows the line held as the next prompt
  And after the line settles "yes please" is dispatched as a prompt

Scenario: a plain chat keeps its inline prompts
  Given a chat with no editor attached
  When a gated bash call parks
  Then the chat renders the [y/N] prompt
```

→ spec file: `spec/lain/seams/cockpit_answer_surfaces_spec.rb` (real `HumanReplies`,
`ApprovalSurfaces`, `LineScope`, an `Approval::Queue` and a fake attached editor view — no double
between them), `spec/lain/cli/repl/approval_surfaces_spec.rb`, `spec/lain/cli/human_replies_spec.rb`,
`spec/reply_surface_discipline_spec.rb`

**Escalation triggers:**
- `spec/approval_consumer_discipline_spec.rb:151` pins exactly one approval consumer. If `/approve`
  becoming a declared reader breaks that invariant rather than satisfying it, stop.
- The re-queue trade (`human_replies.rb:514-527`): **no item may be retired because the chat stopped
  reading it.** If an attached editor detaching mid-session leaves a pending with no surface, stop
  and confirm the fallback: the pending should become readable again at the TTY.
- If the question arrival line needs a `Frontend::TTY` change, stop. T13 owns `tty.rb` next wave;
  use `render_arrival`.
- **Held line vs parked line.** A held prose line waits for the dispatching line to settle. If a
  parked call can only be decided in nvim and the human never goes there, the held line waits with
  it. That is the ruling (nvim is the answer surface), but if a spec shows the held line lost on
  Ctrl-C of the dispatching line, stop: it must survive to `you>`.

---

### T7 — Hold a compaction cut once committed, so the compacted range spans stable and never un-compacts   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/compaction/source.rb`, `lib/lain/compaction/derivation.rb`,
`lib/lain/compaction/source/derived.rb`, `lib/lain/compaction/need.rb`, `lib/lain/session.rb`,
`lib/lain/telemetry/context_derived.rb`, `lib/lain/telemetry/compaction_cut.rb` (new),
`lib/lain/session_record/replay.rb`, `spec/lain/telemetry/compaction_cut_spec.rb` (new), `ARCHITECTURE.md`,
`docs/GLOSSARY.md`, `spec/lain/compaction/source_spec.rb`, `spec/lain/compaction/derivation_spec.rb`,
`spec/lain/compaction/need_spec.rb`, `spec/lain/session_spec.rb`,
`spec/lain/session_record/replay_spec.rb` (new spec)
**Reuse:**
- `Source::Reporting`'s edge latch (`source.rb:283-299`).
- `Telemetry::ContextDerived`'s `spans`/`keep_last` (`derivation.rb:187-191`).
- `Derivation`'s span planning (`Plan.over`, `Boundary`).
- `Strategy::Summarizing::Answers`, keyed by a range's content address.
- `planning/specs/plan-shaped-compaction.md:75-78`'s monotonicity rule.

**Shared-file wiring:** `require_relative "telemetry/compaction_cut"` in `lib/lain/telemetry.rb`
**Reachable from:** `CLI::Wiring#backing` → `CompactionMount` → `Compaction::Source#context_for`,
called by `Agent#render_request` (`agent.rb:514-519`) on every model call.

**The human's question, answered inside the architecture.** "Preserve the history prior to
compaction, and have the compacted history span over the range of events that have been
compacted."
- **The Timeline is never rewritten.** It stays the lossless record, and this card does not touch
  it.
- **The cut is the frozen seam.** The derived context's replacement already carries `spans`
  endpoints naming the source range it stands for; that span is the thing that becomes stable.
- **What is added is policy state, not a derived head.** `Source` remembers **the cut** (the source
  digest a committed compaction collapsed up to) and re-derives **from the source root** every
  turn, with `[root, cut]` collapsed and everything after kept.
- **Why that holds both invariants.** Derivation stays non-recursive (ARCHITECTURE's rule), and
  because the cut is fixed, the replacement's bytes are identical turn to turn. So the summary memo
  hits, the prefix is stable, and a clearing signal can **never** render the full history again.
- **The cut advances** only when a signal fires again and the span after the cut is droppable. The
  new cut is a later seam.
- **The cut holds only while the head's chain contains it.** After `/rewind`, `/fork`, a resend,
  or a resume onto a head below the cut, the cut **retreats** to the latest recorded cut still on
  the chain, or to none. A sticky digest off the chain would collapse the wrong range.
- **The cut is journaled once per advance.** A new `compaction_cut` record carries:
  - the cut digest;
  - the span endpoints;
  - **the replacement's summary text**, which is the one part a resume cannot recompute, because
    `Summarizing::Answers` is an in-memory memo that forgets failures (Grounding §5).

  `context_derived` names the cut digest on every render. Replay folds `compaction_cut` into
  `Source`, so `--resume` renders the recorded replacement byte for byte, without re-summarizing.
- **Byte identity across renders holds once the cut's summary has landed.** A summarize call that
  fails is retried on the next render and does not advance the cut, so no cut exists until its
  replacement text does.
- **The plan step is edge-triggered.** `plan_step_completion` fires once per rising `todo_write`, not
  on every render until the next write.

**Acceptance criteria:**

```gherkin
Scenario: a compaction is not undone when its signal clears
  Given a session that compacted under plan_step_completion
  When the next todo_write completes nothing and the next turn renders
  Then the rendered request still carries the compacted replacement
  And its message count is not greater than the previous turn's plus the new turns

Scenario: the compacted range spans the same events turn after turn
  Given a committed cut under a summarizing strategy whose summary has landed
  When three more turns render
  Then every context_derived record names the same span endpoints and the same cut
  And the replacement message bytes are identical across the three renders

Scenario: the lossless record is untouched
  Given a session that compacted twice
  When the session file's turns are folded
  Then every pre-compaction turn is present in order

Scenario: a completed plan step fires once
  Given a todo_write that raises the completed count
  When two turns render without another todo_write
  Then only the first compaction_decision carries plan_step_completion

Scenario: a resumed session renders its cut without re-summarizing
  Given a recorded session with a committed cut under summarize-conversation
  When it is resumed and the next request is rendered
  Then the request carries the same replacement bytes as the recording's last derived render
  And no summarizer request is made for the cut's range

Scenario: rewinding past the cut retreats it
  Given a session with a committed cut
  When the human rewinds to a turn before the cut and the next turn renders
  Then the rendered request carries no replacement for the abandoned range
  And the next context_derived names no cut

Scenario: a failed summary does not commit a cut
  Given a signal that fires while the summarizer fails
  When the turn renders
  Then no compaction_cut is journaled and the next render retries
```

→ spec file: `spec/lain/compaction/source_spec.rb` (a real `Source` over a real `Timeline` and
`Session`), `spec/lain/compaction/need_spec.rb`, `spec/lain/session_spec.rb`,
`spec/lain/session_record/replay_spec.rb` (new; the last scenario — kept out of `resume_spec.rb`,
which T3 holds this wave)

**Escalation triggers:**
- `derivation_spec.rb:524` and `source_spec.rb:1297` ("is not a functor on the prefix order")
  characterise derivation without a cut. They **change meaning** under a cut: confirm them, don't
  delete them. If the derivation itself has to hold a derived head to meet the ACs, **stop** —
  that is the ruled-out design.
- Compaction pipelines are `Ractor.make_shareable` (`scheduler.rb:238-240`, `derived.rb:186-199`).
  The cut must live in `Source`, not be captured in a pipeline. If that is impossible, stop.
- `Source` is at its ClassLength cap. Extract the cut holder as a collaborator; if extraction pulls
  in `Reporting`/`Cold`, name the new shape before building it.
- `source_spec.rb:276-282` ("deferring is a true no-op", "renders byte-identically to the base
  Context") is true only before the first cut. Scope it; do not delete it.
- **The eager summarizer.** `SummarySnapshot` replaces tool results as they land, independently
  of the cut. If a cut's replacement bytes change because an eager summary landed inside the cut's
  range after the cut committed, stop. Decide whether the cut freezes the snapshot it saw, or
  whether eager summaries inside a cut are moot.
- **Record size.** A summary on `compaction_cut` is bounded by the summarizer's max tokens. If a
  spec shows a cut record over `Journal`'s line expectations, stop.

---

### T8 — Confine automatic shell approval to the project root, and name the credential files it must not read   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/approval/composed_term.rb`, `lib/lain/cli/wiring/board_build.rb`,
`lib/lain/sensitivity.rb`, `lib/lain/approval/risk.rb`, `spec/lain/approval/composed_term_spec.rb`,
`spec/lain/cli/wiring/board_build_spec.rb`, `spec/lain/sensitivity_spec.rb`
**Reuse:**
- `Approval::Risk::OutsideRoot#within_root?` (`risk.rb:176-213`): lexical, refuses a leading `~`,
  no `getpwnam`.
- `Project#root` and its `detected_by`.
- `BoardBuild::Classifiers` (`board_build.rb:290-311`).
- `Sensitivity::Rule.within/named/homed`.
- The GATED widen-freely doctrine (`sensitivity.rb:29-35`).

**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring::BoardBuild.for(project:)` (`board_build.rb:67-81`) → `ComposedTerm`
(`:101-103`), the rules rung of every attended session's escalation ladder.

**The human's ruling: root predicate + widen GATED.**

1. **Root predicate (F91).** `ComposedTerm` approves a composed term only if every path-like word
   **and the call's own cwd** resolve lexically under `project.root`. It gives no automatic
   approval at all when the root **is** `$HOME` or `detected_by: :none`.
   - Extract the lexical check from `OutsideRoot` into a shared predicate rather than copying it.
   - `Classifiers` must fail **closed** for this predicate (it currently rescues to the session
     classifier).
2. **Widen GATED.** Add the named credential files a human must be asked about:
   - `config/master.key`, `*.key`, `credentials.yml.enc`, `.pgpass`, `*_history`,
     `.gem/credentials`, `.ssh/config`, `rclone.conf`, `*.keyring`/`keyrings/**`;
   - a bare `id_rsa`/`id_ed25519`/`id_ecdsa` anywhere, except `*.pub`.

   This costs a prompt on `read_file` for those names, and listing tools withhold those rows. That
   is the doctrine working, and it keeps the boundary in one table.
3. **Exempt can't subtract wholesale (F128).** An `exempt` pattern that lifts **more than one**
   built-in GATED entry (probe each compiled exempt rule against one representative name per GATED
   entry) refuses at load, naming the entries it would lift. A `~/` pattern containing glob
   metacharacters refuses as "can never match".

**Acceptance criteria:**

```gherkin
Scenario: a reader outside the project root reaches a human
  Given an attended session rooted at a project directory
  When the model runs cat on a path under the home directory outside that root
  Then no rule approves it and an approval parks

Scenario: a call whose cwd escapes the root is not approved
  Given an attended session rooted at a project directory
  When the model runs cat README.md with cwd "/"
  Then no rule approves it

Scenario: a home-directory root approves nothing automatically
  Given a session whose project root is the home directory
  When the model runs cat README.md
  Then no rule approves it

Scenario: a named credential file inside the root reaches a human
  Given a project containing config/master.key
  When the model runs cat config/master.key
  Then no rule approves it and an approval parks
  And read_file of the same path parks as gated credential

Scenario: a public key is still ordinary
  Given a project containing id_ed25519.pub
  When the model runs cat id_ed25519.pub
  Then the composed-term rule approves it

Scenario: an exemption that lifts a whole class refuses at load
  Given [sensitivity] exempt = [".*"]
  When a chat launches
  Then it exits 1 naming the config file and the gated entries the pattern would lift

Scenario: the ordinary project read is still approved with nobody asked
  Given an attended session rooted at a project directory
  When the model runs cat README.md | head -20
  Then the composed-term rule approves it
```

→ spec file: `spec/lain/cli/wiring/board_build_spec.rb` (production `BoardBuild.for` construction),
`spec/lain/approval/composed_term_spec.rb`, `spec/lain/sensitivity_spec.rb`

**Escalation triggers:**
- `composed_term_spec.rb:421` expects `cat id_rsa` at the root to allow, and `:358` expects
  `/dev/stdin` to allow. Both flip **by design**. Any **other** flip in `board_build_spec.rb:505,
  546, 559`, stop.
- `CLAUDE.md`'s rule is one `Filter.new` in `lib/`, built inside `Sensitivity::Policy`. If the root
  predicate needs a second classifier construction, stop.
- The doc comment's "predicate 7" names two different things (`composed_term.rb:29-31` vs
  `:121-123`). Name the root predicate distinctly and fix both comments. If the PATH-trust meaning
  is load-bearing elsewhere, stop.

---

### T9 — Degrade an unpriced run in the one comparison seam every report shares   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/compare.rb`, `lib/lain/bench/variance.rb`, `lib/lain/arm/driver.rb`,
`lib/lain/bench/decider_sweep/arms.rb`, `spec/lain/compare_spec.rb`,
`spec/lain/bench/variance_spec.rb`, `spec/lain/arm/driver_spec.rb`
**Reuse:**
- `Compare#shown_metrics` (`compare.rb:190-193`) withholding `:score` unless every run is graded.
- `Arm::Driver::Unpriced` and its `"not priced — <ledger message>"` wording (`arm/driver.rb:261-279`).
- `Friction::CacheWaste::Dollars` (`friction/cache_waste.rb:113-127`).
- `Compare::Run#degraded`.

**Shared-file wiring:** none
**Reachable from:** `exe/lain` `bench variance` → `Bench::CLI#variance_report`
(`bench/cli.rb:55-58`) → `Variance#build_compare`; `bench arms` → `Arm::Driver`.

**The problem.** F109: `lain bench variance` over any local recording with usage refuses outright
("no price for model"), while `bench arms` degrades its cost section, and `decider_sweep` raises the
same way.

**The design.**
- `Compare::Run` carries cost as **priced or unpriced-with-reason**, never a zero.
- `shown_metrics` withholds the cost metric with the ledger's reason when any run is unpriced.
- It likewise withholds `cache_hit_ratio` when every run records `prompt_caching` degraded.
- `Arm::Driver`'s own `Unpriced` fold collapses onto this, one of the four registries
  `compare.rb:103-110` names as owed.

**Acceptance criteria:**

```gherkin
Scenario: variance reports two local recordings with usage
  Given two recordings of an unpriced model, each with turn usage
  When lain bench variance runs over them
  Then it exits 0 and reports total tokens
  And the cost row reads "not priced" with the ledger's reason, never 0.000000

Scenario: a cacheless provider shows no cache hit ratio
  Given recordings that journal prompt_caching degraded
  When the comparison is rendered
  Then no cache hit ratio column is shown and the report says why

Scenario: arms keeps its refusal wording
  Given an arm run this price book cannot price
  When the driver reports
  Then score, tokens and wall-time render and the cost section is refused with the ledger's message
```

→ spec file: `spec/lain/bench/variance_spec.rb`, `spec/lain/compare_spec.rb`,
`spec/lain/arm/driver_spec.rb`

**Escalation triggers:**
- `ledger_spec.rb` pins `UnknownModel` raising with the fallback escape hatch named. The **ledger**
  keeps raising; if degrading needs the ledger to stop raising, stop.
- `arm/driver_spec.rb:308` ("a run this price book cannot price") must pass unchanged in wording.
  If collapsing `Unpriced` changes any of its strings, stop.

---

### T10 — Keep a retained checkout from holding its branch, and never reap a live landing checkout   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/isolation/worktree/release.rb`, `lib/lain/isolation/worktree/leftover.rb`,
`lib/lain/isolation/gc.rb`, `spec/lain/isolation/worktree_spec.rb`,
`spec/lain/isolation/gc_spec.rb`
**Reuse:**
- `Anchorage#keep` (worktree handback), to anchor before detaching.
- `LeaseLock::Held` and `Worktree::Registry#add`'s `--lock --reason` (`registry.rb:42`).
- `Gc`'s branch-pass guards "nothing has landed since lain created it" and `in_use`
  (`gc.rb:419-436`).

**Shared-file wiring:** none
**Reachable from:** `Supervisor#register`'s release → `Worktree::Release#call` on every lease end;
`CLI::GcSchedule` (`cli/gc_schedule.rb:9-13`) starts `Gc` from `lain chat`; `lain worktrees gc`.

**The problem.**
- F99: a retained dirty checkout keeps its issue branch checked out, so the retry's `git switch`
  fails.
- F116: an unlocked landing worktree cut at trunk's tip is reaped as "landed on main" while the
  cockpit runs.

**The design.**
- **Retained or moved-aside checkouts.** When `Release` retains a dirty checkout, or `Leftover`
  moves one aside: anchor its HEAD commit, then **detach HEAD**. The retained tree then holds a
  commit, not the branch name. The files are untouched, which honours "nothing a worker made is
  discarded".
- **`Gc` gains a checkout-level twin of the branch guard.** A checkout whose HEAD is exactly the
  commit lain cut it at, with nothing since, is not "landed". It is kept, and the gc report says
  so.
- **Locking the landing checkout** is T19's (it is cut in `factory.rb`).

**Acceptance criteria:**

```gherkin
Scenario: a retained dirty checkout does not block its branch
  Given a worker lease on branch lain/issue/e/i with uncommitted changes
  When the lease is released
  Then the retained checkout's HEAD is detached at the branch's commit
  And git switch lain/issue/e/i succeeds in a new worktree
  And the uncommitted file is still present in the retained checkout

Scenario: a fresh checkout at its cut point is not reaped as landed
  Given an unlocked worktree whose HEAD is the commit it was cut at and is reachable from main
  When lain worktrees gc runs
  Then the worktree is kept and the report says nothing has landed since it was cut
```

→ spec file: `spec/lain/isolation/worktree_spec.rb` (real `git` — `:seam`), `spec/lain/isolation/gc_spec.rb`

**Escalation triggers:**
- `worktree_spec.rb` "retains a checkout with uncommitted changes, re-locked as retained, and says
  so" and "moves a crashed leftover aside, retained…" assert the branch state. They change
  deliberately. If the **anchor** they write moves, stop.
- `gc_spec.rb` "calls work reachable from main landed" must still reap a checkout **with** commits
  since its cut. If the new guard keeps that case, stop.
- CLAUDE.md trap: a fixture shelling to `git` under `pre-commit` must scrub `GIT_INDEX_FILE`. A spec
  green alone and red at commit time is that trap, not this card.

---

### T11 — Correct three hand-maintained tables   [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/tools/web_fetch.rb`, `lib/lain/context_window.rb`, `lib/lain/shell/exclusions.rb`,
`spec/lain/tools/web_fetch_spec.rb`, `spec/lain/context_window_spec.rb`,
`spec/lain/shell/exclusions_spec.rb`
**Reuse:** the existing range table in `web_fetch.rb`; `ContextWindow::CLOUD_WINDOWS`; the
`[shell] exclude` loader's refusal vocabulary.
**Shared-file wiring:** none
**Reachable from:**
- `Tools::WebFetch` (`CLI::Wiring::BaseTools`) on every fetch.
- `CLI::Backend::WindowBook` resolving any `--provider ollama-cloud` window.
- `Shell::Exclusions` loaded by `BoardBuild.for` at chat launch.

**The three corrections:**
- **Fork T3.** `web_fetch` refuses `240.0.0.0/4`, which the table omits, so a real SYN is sent
  today.
- **F126.** Remove the two retired `CLOUD_WINDOWS` rows, `deepseek-v4-flash:preview-cloud` and
  `deepseek-v4-pro:preview-cloud` (their `/api/show` says "was retired").
- **Fork T6.** A `[shell] exclude` entry containing whitespace refuses at load as "can never match
  an unquoted command". A table with both a malformed entry and an unknown key reports both.

**Acceptance criteria:**

```gherkin
Scenario: the reserved range is not fetched
  Given a web_fetch of http://240.0.0.1/
  When the tool runs
  Then it refuses naming the non-routable range and opens no connection

Scenario: a retired cloud tag has no published window
  Given --provider ollama-cloud --model deepseek-v4-pro:preview-cloud
  When the window resolves
  Then it is not resolved as published

Scenario: an exclude entry that can never match refuses
  Given [shell] exclude = ["cu rl"]
  When a chat launches
  Then it exits 1 naming the entry

Scenario: every table problem is reported in one pass
  Given [shell] exclude with a malformed entry and an unknown key
  When a chat launches
  Then the refusal names both
```

→ spec file: `spec/lain/tools/web_fetch_spec.rb`, `spec/lain/context_window_spec.rb`,
`spec/lain/shell/exclusions_spec.rb`

**Escalation triggers:**
- If a `CLOUD_WINDOWS` row is referenced by a spec fixture or a bench suite, stop before removing
  it.
- If the exclude loader lives somewhere other than `shell/exclusions.rb`, name it and stop rather
  than editing `board_build.rb` (T8 owns it this wave).

---

### T12 — Make a one-shot spawn's identity include the work it was given   [wave 2] [risk: medium]

**Depends on:** T4 (file: `tools/subagent.rb`, `tools/subagent/actor.rb`)
**Files:** `lib/lain/tools/subagent/lineage.rb`, `lib/lain/tools/subagent.rb`,
`lib/lain/tools/subagent/actor.rb` (`:87`, so actor spawns carry the task digest),
`lib/lain/cli/watch/lineage_filter.rb`, `spec/lain/tools/subagent/lineage_spec.rb`,
`spec/lain/tools/subagent/actor_spec.rb`,
`spec/lain/cli/fleet_windows_spec.rb`, `spec/lain/status_feed/fleet_spec.rb`,
`spec/lain/cli/watch_spec.rb`
**Reuse:**
- `Lineage#spawn`'s conditional body idiom (`lineage.rb:60-63`).
- `Canonical` digests.
- Round 16's twin examples (`supervisor_reactor_spec.rb:158, 203`; `status_feed/fleet_spec.rb:193`).

**Shared-file wiring:** none
**Reachable from:** `Tools::Subagent#spawn_one_shot` → `Lineage#spawn` (`subagent.rb:238-246`) on
every model-dispatched and role spawn; `Skill::RoleSpawn#call` builds the tool per call.

**The human's ruling: prompt digest in the body.**
- A one-shot spawn's body carries `task: <digest of the prompt>` (the digest, not the text).
  Identity is then content-derived: order-independent, resume-safe, reproducible across runs, and
  shared only by spawns doing identical work from one head.
- Actor spawns keep round 16's adoption ordinal, and also carry the task digest.
- `lineage.rb:45-46`'s "a one-shot is addressed by nobody" is corrected: `--windows` and
  `lain watch` address one.
- **Identical-prompt twins still share one address** (Open decision 5): the same work from one
  head is the same spawn, and its first completion releases the shared window. That is accepted,
  not fixed.
- **No consumer changes are needed.** `FleetWindows`, `StatusFeed::Fleet` and `LineageFilter` key
  on the spawn digest (`fleet_windows.rb:371-420`), so a body change propagates to them.
  `lineage_filter.rb` is listed only to correct its stale comment.

**Acceptance criteria:**

```gherkin
Scenario: two parallel spawns of different work take different addresses
  Given one assistant turn with two subagent calls with different prompts from one head
  When both spawn
  Then the two spawn records have different digests
  And --windows opens two windows and the HUD fleet counts two until each completes

Scenario: watching one twin shows only its own lineage
  Given two concurrent spawns from one head with different prompts
  When lain watch is given one spawn's digest
  Then only that child's result is rendered

Scenario: the same work from the same head reproduces its address
  Given an identical run spawning the same prompt from the same head
  When both runs spawn
  Then the spawn digests are equal

Scenario: a recorded spawn re-derives its recorded digest
  Given a spawn record carrying a task digest
  When its body is rebuilt from what was recorded
  Then it re-derives its recorded digest
```

→ spec file: `spec/lain/tools/subagent/lineage_spec.rb`, `spec/lain/cli/fleet_windows_spec.rb`,
`spec/lain/status_feed/fleet_spec.rb`, `spec/lain/cli/watch_spec.rb`

**Escalation triggers:**
- `lineage_spec.rb:58-75, 119-122` pin one-shot bytes unchanged. They flip **by design**. If a
  **fixture journal** under `spec/fixtures/` carries a one-shot spawn whose digest a replay spec
  checks, stop.
- `scribe_spec.rb:380` ("records one transcript for a fan-out of siblings that ran identically")
  must still hold for identical prompts. If distinct task digests break child-turn dedupe for
  identical work, stop.

---

### T13 — Guard a plain chat's inline prompts: discard typeahead, close a decided prompt, retire an answered question   [wave 2] [risk: high]

**Depends on:** T6
**Files:** `lib/lain/cli/conductor.rb`, `lib/lain/frontend/tty.rb`, `lib/lain/frontend/reline.rb`,
`lib/lain/frontend/approval_policy.rb`, `lib/lain/cli/human_replies.rb`,
`spec/lain/cli/conductor_spec.rb`, `spec/lain/frontend/approval_policy_spec.rb`,
`spec/lain/cli/human_replies_spec.rb`, `spec/lain/frontend/reline_spec.rb`,
`spec/lain/seams/plain_chat_prompt_guards_spec.rb` (new spec)
**Reuse:**
- `ApprovalPolicy#answered`'s `pending.await` withdrawal (`approval_policy.rb:113-118`).
- `HumanReplies#settled(digest)` (`:334-337`), where every surface's answer converges.
- `TTY::Countdown`'s `@lock`/`draw` (`tty.rb:756-761`).
- `IO#raw` plus a `read_nonblock` loop (io/console). **Not** `IO#iflush`, which discards bytes
  without returning them.
- T6's held-line slot in `Repl#next_text`, so a complete discarded line becomes the next prompt.

**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring#build_repl` for a chat with no editor attached;
`Conductor#read_reply` on every `human>`/`[y/N]` read.

**`--no-nvim` keeps inline prompts, with these guards (the human's ruling):**
1. **Typeahead is never an answer, and never lost.** Immediately before a `[y/N]` or `human>` read
   opens, `Frontend::TTY` drains buffered terminal input: `@input.raw { read_nonblock loop }`.
   - The drained bytes live in the kernel. Reline's `@buf` holds only `ungetc` bytes, so nothing
     reaches into Reline.
   - **Complete lines** in the drain are held as the next `you>` input, exactly as T6 holds a
     cockpit line, and rendered as `held as your next prompt: <text>`. So a `/goal off` typed
     during a goal iteration that then parks an approval still runs.
   - A trailing **partial** line is rendered back as `discarded: <text>`.
2. **A prompt decided elsewhere is closed.** When a pending the TTY is reading is decided by another
   surface (the timeout, `secret_oracle`, `/approve`), the read is stopped (as today). The prompt
   line is ended with `-- decided by <surface>: <verdict>` through the TTY's own rendering, never
   raw `$stdout`.
3. **A question answered elsewhere retires.** `AnswerLoop` races its read against a per-digest
   settled signal from `HumanReplies#settled`. An item settled elsewhere is retired, not re-queued,
   so F101's ghost `human>` cannot recur.
4. **The ticker's suppression flag becomes a count** (`conductor.rb:138-144`), so two concurrent
   reads cannot clear it early.

**Acceptance criteria:**

```gherkin
Scenario: a line typed during dispatch does not answer the next approval
  Given a plain chat with no editor
  When the human types "yes please" and Enter while a turn dispatches and a gated call then parks
  Then the approval prompt opens empty and waits
  And the chat shows "yes please" held as the next prompt
  And after the line settles "yes please" is dispatched as a prompt

Scenario: a partial line typed before a prompt is not an answer
  Given a plain chat with no editor
  When the human types "y" without Enter while a turn dispatches and a gated call then parks
  Then the approval prompt opens empty
  And the chat shows "y" as discarded

Scenario: a prompt decided by the timeout is closed in words
  Given a plain chat reading a [y/N] prompt
  When the approval window closes
  Then the prompt line ends with "decided by" and the verdict
  And a y typed afterwards is not recorded as an approval decision

Scenario: a question answered elsewhere never re-prompts
  Given a plain chat with a parked subagent question read at human>
  When the question is settled by another surface
  Then no human> prompt is drawn on the next three dispatched lines

Scenario: a surviving read keeps the ticker suppressed
  Given two replies outstanding at once
  When the first read finishes
  Then the countdown ticker stays suppressed until the second finishes
```

→ spec file: `spec/lain/seams/plain_chat_prompt_guards_spec.rb` (a real `Conductor`,
`Frontend::TTY` over a PTY, `ApprovalPolicy` and `Approval::Queue` — `:seam`),
`spec/lain/frontend/approval_policy_spec.rb`, `spec/lain/cli/human_replies_spec.rb`,
`spec/lain/cli/conductor_spec.rb`

**Escalation triggers:**
- **Fail-closed doctrine.** A discard must never turn into an approval, and an unrecognised
  keystroke is still not consent. Any path where discarding changes a verdict from deny to approve:
  stop.
- `approval_policy_spec.rb:384` expects the policy's `output.string` empty when another surface
  answers. The "decided by" line goes through the TTY, not the policy's `@output`. If it cannot,
  stop.
- **Draining in raw mode must not race Reline.** It runs only between reads, under the same
  process mutex Reline's reads take. If a drain can run while a Reline read is open, or leaves the
  terminal out of cooked mode on an exception, stop.
- If a held line would need `repl.rb` changes beyond T6's slot, stop. T27 owns `repl.rb` later.
- **The re-queue trade** (`human_replies.rb:522-527`) and the handback window (`ask_human.rb:864-876`,
  where `awaited` abandons and `reopened` claims the same digest). The settled check must be
  exact. If a re-opened handback set would be retired, stop.

---

### T14 — Carry the run's sampler options into every secondary model request, scoped to the arm that reads them   [wave 2] [risk: medium]

**Depends on:** T4 (file: `cli/wiring.rb`)
**Files:** `lib/lain/oracle/model.rb`, `lib/lain/cli/backend.rb`,
`lib/lain/cli/backend/summarizer.rb`, `lib/lain/cli/backend/span_summarizer.rb`,
`lib/lain/oracle/secret_read.rb`, `lib/lain/cli/wiring.rb`, `spec/lain/oracle/model_spec.rb`,
`spec/lain/cli/backend_spec.rb`, `spec/lain/cli/backend/summarizer_spec.rb`,
`spec/lain/cli/backend/span_summarizer_spec.rb`, `spec/lain/oracle/secret_read_spec.rb`
**Reuse:**
- `Backend#sampler_extra` (`backend.rb:554`).
- `Provider::Ollama::Encoding::SAMPLER_KEYS` (`encoding.rb:35`).
- `Backend#summarizer_model`/`summarizer_max_tokens`, which both tiers already read.

**Shared-file wiring:** none
**Reachable from:**
- `CLI::Backend#summary_oracle` → `Backend::Summarizer#tier` (eager summarizer).
- `CompactionStrategy.resolve(tier:)` → `SpanSummarizer#tier` (span strategies).
- `CLI::Wiring#secret_surface` → `Oracle::SecretRead.tier` (`wiring.rb:224-229`).

**The problem.** F95: `Oracle::Model#request_for` builds `extra:` from the schema only. With
`LAIN_NUM_BATCH` set, every summarized tool result re-keys the runner twice. Measured: 29.4s
oracle wall against 1.6s without the variable.

**The design.**
- **`Backend` resolves one tier-options value, and it is narrow on purpose.**
  - It carries only the **runner-keying** knobs, `num_batch` and `num_ctx`.
  - It carries them only when the tier's model **equals the chat's model** on the same ollama
    endpoint: the one case where a mismatch reloads the chat's runner (F95).
  - The chat's `temperature`/`seed` never reach a tier, because they would change the secret
    oracle's judgements and the summaries.
  - A different tier model (e.g. `qwen3:4b`) gets no carried options. The chat's `num_ctx` would
    force that tier's own reload.
- **The same filter applies to the chat's own `Context#extra`.** The chat path forwards ollama keys
  to the Anthropic wire today (`anthropic_encoding.rb:67`).
- **`Oracle::Model.new(extra:)`** merges them under the schema.
- **Whether `SecretRead` needs options at all** follows from the rule above. It takes
  `options:` so a same-model configuration is covered, and it gets an empty value in the
  default configuration.
- **`SecretRead.tier(options:)`** takes the value. Its parameter pin (`secret_read_spec.rb:100`,
  "takes no provider, backend or router seam") is amended deliberately: options are not an endpoint
  seam, and the loopback and model rules stay.
- **`request_sent.extra`** on the tier's journaled request shows what went on the wire.

**Acceptance criteria:**

```gherkin
Scenario: the summarizer asks with the chat's batch size
  Given a chat launched with LAIN_NUM_BATCH=2048 on the ollama arm
  When a tool result summons the eager summarizer
  Then the summarizer's request carries num_batch 2048
  And its journaled request_sent.extra says so

Scenario: an Anthropic tier never receives ollama options
  Given LAIN_NUM_BATCH=2048 and --summarizer-provider anthropic
  When the summarizer request is encoded
  Then the wire body carries no num_batch key

Scenario: a flagless run still sends no options
  Given no sampler flag or variable
  When any tier request is encoded for ollama
  Then it carries no options key

Scenario: a tier on a different model carries none of the chat's options
  Given --secret-oracle on qwen3:4b with LAIN_NUM_BATCH=2048 and --temperature 0.2 for a qwen3-coder chat
  When the oracle judges a release
  Then its request carries no num_batch and no temperature and still goes to the loopback endpoint

Scenario: the chat's temperature never reaches a same-model summarizer
  Given a chat with --temperature 0.2 and LAIN_NUM_BATCH=2048 whose summarizer uses the chat model
  When the summarizer is asked
  Then its request carries num_batch 2048 and no temperature
```

→ spec file: `spec/lain/cli/backend_spec.rb` (production `Backend` construction from options),
`spec/lain/oracle/model_spec.rb`, `spec/lain/oracle/secret_read_spec.rb`,
`spec/lain/cli/backend/summarizer_spec.rb`

**Escalation triggers:**
- `model_spec.rb:71-127` pins "sends the Anthropic path byte-identical wire bytes to a request
  carrying no extra". Filtering must keep that. If it can't, stop.
- `backend_spec.rb` "renders a Request whose cache_payload is identical to the flagless render"
  must hold. `Request#digest` excludes `extra`; if it doesn't, stop.
- `SecretRead`'s `qwen3:4b` evicts the chat's model on one GPU (`backend.rb:197-203`). This card
  fixes `-b`, not residency. If a spec or the human expects residency fixed here, stop and name it.

---

### T15 — Tell the model which rung refused a gated call, not only that it was refused   [wave 2] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/approval/escalation.rb`, `lib/lain/middleware/gate.rb`,
`lib/lain/cli/switchboard.rb`, `lib/lain/approval/policy_switch.rb`, `lib/lain/mode/resolution.rb`,
`spec/lain/approval/escalation_spec.rb`, `spec/lain/middleware/gate_spec.rb`,
`spec/lain/cli/switchboard_spec.rb`, `spec/lain/approval/policy_switch_spec.rb`,
`spec/lain/mode/resolution_spec.rb`
**Reuse:**
- `Escalation#settle`'s `Ruling#because`.
- `Switchboard#denial` (`switchboard.rb:254-265`), which already injects an unattended sentence.
- `Middleware::Sensitivity#refuse`'s sentence shape ("no approval can lift this, so name a
  different path rather than retrying this one in another form").

**Shared-file wiring:** none
**Reachable from:** `CLI::Switchboard` → `Middleware::Gate` on every gated tool call.

**The problem.** Fork T4: a triage deny on a protected argv, or a project `[shell] exclude` deny,
reaches the model as `approval denied for tool "bash"`. The model then concludes "bash is not
allowed in this environment" (observed twice) and routes around the refusal.

**The design.**
- **Policies answer with a ruling, not a Boolean.** `Gate` takes a policy that can answer
  `#rule(effect, context)`, returning allow or deny with a because.
  - The production Gate policy is **`Approval::PolicySwitch`** (Grounding §6). It forwards
    `#rule` to whichever of `Mode::Resolution::GATE_POLICIES` is selected.
  - `Escalation` returns its settled ruling.
  - `ApproveAll`/`DenyAll`/the queue answer with their fixed sentence.
- **A deny carrying a because renders it.**
  - A **triage/rules** deny renders its reason plus "no approval will lift this; do not re-send
    the same command in another form".
  - A **human** deny keeps today's sentence.
  - The unattended sentence stays.

**Acceptance criteria:**

```gherkin
Scenario: a protected-path deny says why
  Given an attended session
  When the model runs cat on a protected private key path
  Then the tool_result names the protected path and says no approval will lift it

Scenario: a project exclusion deny names the exclusion
  Given [shell] exclude = ["curl"]
  When the model runs curl
  Then the tool_result names the exclude entry

Scenario: a human's denial is unchanged
  Given an attended session
  When the human denies a gated call
  Then the tool_result is "approval denied for tool \"bash\""
```

→ spec file: `spec/lain/middleware/gate_spec.rb`, `spec/lain/approval/escalation_spec.rb`,
`spec/lain/cli/switchboard_spec.rb` (production `Switchboard` construction)

**Escalation triggers:**
- The Gate docstring (`gate.rb:78-83`) says "a Boolean has no room for a why". If a Gate policy in
  production is neither `PolicySwitch` nor one of `GATE_POLICIES`, stop and list it.
- `secret-boundary.md` §5 records the generic sentence as the *expected* screen. T29 amends it; if
  any spec pins the generic sentence for a triage deny, it flips deliberately — say so in the
  commit.

---

### T16 — Let `bench arms` route to a cheap model the operator names   [wave 2] [risk: low]

**Depends on:** none
**Files:** `lib/lain/bench/live_arms.rb`, `lib/lain/bench/cli.rb`, `exe/lain`,
`spec/lain/bench/live_arms_spec.rb`, `spec/lain/bench/arms_report_spec.rb`, `spec/lain/cli_spec.rb`
**Reuse:**
- The `--summarizer-model` literal flag pattern (`backend.rb:193-208`).
- `LiveArms.default_route(capable)` (`live_arms.rb:90-100`).
- `ARMS_FLAGS` (`exe/lain:620-621`).

**Shared-file wiring:** none
**Reachable from:** `exe/lain` `bench arms` → `Bench::CLI#arms_report` → `LiveArms.build` →
`default_router`.

**The problem.** F110: every non-Anthropic backend is refused, and the second remedy it names is a
Ruby method argument.

**The design.**
- **Add `--cheap-model ID`**, read literally.
  - Unset on a Claude backend, the router keeps `claude-haiku-4-5`.
  - Unset on any other backend, it refuses **naming `--cheap-model`**.
  - Equal to the capable model, it refuses as "would run the control twice".
- **Fix the wording.** The refusal drops "no cheaper than" for a model that is merely not Claude,
  and stops naming the Ruby `router:` argument.

**Acceptance criteria:**

```gherkin
Scenario: an ollama backend runs the routing arm with a named cheap model
  Given lain bench arms --provider ollama --model qwen3-coder:30b --cheap-model qwen3:4b
  When the roster is built
  Then the routing arm sends single-file tasks to qwen3:4b and the rest to qwen3-coder:30b

Scenario: an ollama backend without a cheap model is refused by flag name
  Given lain bench arms --provider ollama --model qwen3-coder:30b
  When the roster is built
  Then it refuses naming --cheap-model and spends nothing

Scenario: a cheap model equal to the capable one is refused
  Given --model qwen3:4b --cheap-model qwen3:4b
  When the roster is built
  Then it refuses saying both branches would run the same model
```

→ spec file: `spec/lain/bench/live_arms_spec.rb`, `spec/lain/bench/arms_report_spec.rb`,
`spec/lain/cli_spec.rb` (the flag reaches `arms_report`)

**Escalation triggers:**
- `live_arms_spec.rb:166` matches `/--model.*router:/m`. It changes by design. If any **other**
  example asserts the router Ruby seam is the operator's escape, stop.
- `live_arms.rb:59-63` rejects a per-provider sibling table. This card must not add one; if a test
  seems to need one, stop.

---

### T17 — Retire an epic gate's question on every surface once the gate settles   [wave 2] [risk: medium]

**Depends on:** T5 (file: `cli/epic_submit.rb`, `cli/epic_mount.rb`), T4 (the `durable_journal` /
`record_journal` split)
**Files:** `lib/lain/approval/gate.rb`, `lib/lain/tools/ask_human.rb`,
`lib/lain/approval/gate/policies.rb`, `lib/lain/cli/epic_submit.rb`, `lib/lain/cli/epic_mount.rb`,
`spec/lain/approval/gate_spec.rb`, `spec/lain/tools/ask_human_spec.rb`,
`spec/lain/cli/epic_mount_spec.rb`,
`spec/lain/cli/epic_submit_spec.rb`, `spec/lain/status_feed/inbox_spec.rb`,
`spec/lain/frontend/neovim/inbox_view_spec.rb`
**Reuse:**
- `Telemetry::QuestionsConsumed` (`telemetry/questions_consumed.rb`), which all three record-based
  inbox readers already retire on.
- `AskHuman::Unanswered` (`ask_human.rb:888-907`).
- The inbox parity specs.

**Shared-file wiring:** none
**Reachable from:** `Approval::Gate#call` (`gate.rb:256-274`), constructed by the epic seat under
`lain chat --epic` and by `EpicSubmit`.

**The problems.**
- F100: a gate that timed out, and very likely one that was answered, leaves its question in
  `lain://inbox` and `inbox_count` forever, because only the tool's delivered path emits a
  consumption edge.
- Fork F113/E1: an unattended submit of a `hands_off` stage refuses because another stage is
  `interactive`, saying "missing asker".
- Fork E3: an EOF at an interactive gate is journaled `answered_by: human`.

**The design.**
- **Verify first.** Add the answered-gate spec before building; its result is recorded in the
  commit.
- **Retire on settle.** When a gate settles by answer, timeout or withdrawal, it emits
  `QuestionsConsumed` naming `asked.digest`.
  - It goes to **`record_journal`, the tee**, because `StatusFeed` and the nvim inbox fold it.
  - It must **not** go to the `durable_journal` that T4 hands `EpicDriver::Seams`, which never
    reaches a live view.
- **An unattended submit of a non-interactive stage proceeds.** `for_all`'s early wiring refusal
  still fires for a stage that **is** interactive, and names it: "stdin is not a terminal; set
  `<stage> = hands_off` or `deferred`".
- **An EOF at an interactive gate** is recorded with `answered_by: eof`, not `human`.

**Acceptance criteria:**

```gherkin
Scenario: a timed-out gate's question leaves every reader
  Given an interactive implementation gate whose window closes
  When the gate settles by timeout
  Then inbox_count returns to 0 and lain://inbox shows no question

Scenario: an answered gate's question leaves every reader
  Given an interactive gate answered through the inbox
  When the gate settles
  Then inbox_count returns to 0

Scenario: the production epic seat retires its gate's question on the live feed
  Given lain chat --epic wired by CLI::Wiring with a live status feed
  When the seat's interactive gate times out
  Then the status feed's inbox_count returns to 0

Scenario: an unattended submit of a hands-off stage proceeds
  Given research = "hands_off" and every other stage left at its default
  When lain epic submit research runs with stdin not a terminal
  Then research is approved as hands_off

Scenario: an unattended submit of an interactive stage refuses in words
  Given research left interactive
  When lain epic submit research runs with stdin not a terminal
  Then it exits 1 saying stdin is not a terminal and naming the policies that would proceed

Scenario: end of input is not a human's answer
  Given an interactive gate whose stdin reaches end of file
  When the gate settles
  Then the gate_decision is not answered_by human
```

→ spec file: `spec/lain/approval/gate_spec.rb`, `spec/lain/cli/epic_submit_spec.rb`,
`spec/lain/status_feed/inbox_spec.rb`, `spec/lain/frontend/neovim/inbox_view_spec.rb`

**Escalation triggers:**
- `ask_human_spec.rb` "leaves the question it withdrew in the record" is the design: the question
  stays in the record and the **consumption** retires it. If retiring needs the question removed,
  stop.
- `run_spec.rb` "leaves the asker free for the next run's first gate" must hold.
- If `Event::Projection#pending` needs to learn a new record type, stop. This card uses the existing
  one.
- **Two gate journals.** `EpicMount` already hands the chat seat `chronicle.record_journal`
  (`epic_mount.rb:105`). `/implement-epic`'s gates come through `EpicDriver::Seams`, which T4 moves
  to `durable_journal`. If those gates' consumption must reach the live inbox, `Seams` needs both
  journals, and that is a `wiring.rb` edit T14 holds this wave. Stop and hand the orchestrator the
  one-line diff.

---

### T18 — Keep an epic's preamble and provenance through graph edits   [wave 2] [risk: low]

**Depends on:** T5 (file: `cli/epic.rb`)
**Files:** `lib/lain/epic/document.rb`, `lib/lain/cli/epic.rb`, `lib/lain/epic/intake.rb`,
`lib/lain/epic/home/journaled.rb`, `lib/lain/epic/graph.rb`, `spec/lain/epic/document_spec.rb`,
`spec/lain/cli/epic_spec.rb`, `spec/lain/epic/graph_spec.rb`
**Reuse:** `Document.parse_markdown`/`to_markdown` (`epic/document.rb:139-151, 259-267`);
`Intake::Written#recorded`'s compare-by-parse (`intake.rb:131-134`).
**Shared-file wiring:** none
**Reachable from:** `exe/lain` `epic add/split/merge` → `CLI::Epic#apply` (`epic.rb:386-394`).

**The problems.**
- F117: `lain epic add/split/merge` deletes everything above the first heading.
- Fork E7: `merge` drops `Discovered from:` provenance even when both sides agree.

**The design.** Carry the preamble alongside the graph, with `to_markdown(graph, preamble:)`. The
digest stays graph-only, so a preamble never moves a digest. `Graph#merge` keeps a provenance both
sides share.

**Acceptance criteria:**

```gherkin
Scenario: a graph edit keeps the preamble
  Given an epic.md with prose above its first heading
  When lain epic add runs
  Then the rewritten epic.md starts with the same prose

Scenario: a preamble does not move the digest
  Given two epic.md files differing only in their preamble
  When both are parsed
  Then their digests are equal

Scenario: a merge keeps the provenance both sides share
  Given two issues both discovered from issue a
  When they are merged
  Then the merged issue is discovered from a
```

→ spec file: `spec/lain/epic/document_spec.rb`, `spec/lain/cli/epic_spec.rb`,
`spec/lain/epic/graph_spec.rb`

**Escalation triggers:**
- `Home::Journaled#write_epic` (`home/journaled.rb:79-81`) must emit the same bytes as `apply`. If
  the two byte digests disagree after this card, stop.
- `document_spec.rb` "parses to the same digest with and without a preamble" must pass unchanged.

---

### T19 — Make the epic driver read the project's layout, judge real work, and hold its landing checkout   [wave 2] [risk: medium]

**Depends on:** T5 (file: `cli/epic_driver/factory.rb`), T10
**Files:** `lib/lain/cli/epic_driver/factory.rb`, `lib/lain/forge/local_landing.rb`,
`spec/lain/cli/epic_driver/issue_tests_spec.rb`, `spec/lain/cli/epic_driver/run_spec.rb`,
`spec/lain/cli/epic_driver/factory_spec.rb`, `spec/lain/forge/local_landing_spec.rb`,
`spec/lain/isolation/gc_spec.rb`
**Reuse:**
- `IssueTests::Red#sha` (`factory.rb:833`), carried by `IssueActor::Launch#tests`.
- `Worktree::Registry#add` with `--lock --reason` and `LeaseLock::Held`.
- T10's checkout guard.

**Shared-file wiring:** none
**Reachable from:** `/implement-epic` → `EpicDriver::Factory` → `Run#judge` and `cut_landing`.

**The problems.**
- F115: `[tests]` is read from the worktree, so a gitignored `.lain/config.toml` blocks every issue.
  `LocalLanding::Placement` silently skips its guard for the same reason.
- F111: the implementation gate opens over the red commit when the actor committed nothing.
- F116's lock half: the landing checkout is cut unlocked.

**The design.**
- Resolve `TestLayout` **once, from the project root**, in `Factory`, and inject it into
  `IssueTests` and `Landing`.
- `Run#judge` treats `report.sha == launch.tests.sha` as "committed nothing".
- `cut_landing` adds its checkout **locked**, and the run's end releases the lock.

**Acceptance criteria:**

```gherkin
Scenario: a gitignored project config still declares the layout
  Given a project whose .lain/config.toml declares [tests] and is gitignored
  When /implement-epic starts an issue
  Then the red step writes the generated tests

Scenario: the landing guard runs with the project's layout
  Given the same project and a misplaced test in an issue's work
  When the issue lands
  Then landing refuses naming the misplaced test

Scenario: an actor that committed nothing opens no gate
  Given an issue whose only commit is the red step's
  When the actor settles
  Then the issue is reported as having committed no work and no implementation gate opens

Scenario: gc keeps a live landing checkout
  Given a running /implement-epic whose landing checkout was just cut
  When lain worktrees gc runs
  Then the landing checkout is kept as held
```

→ spec file: `spec/lain/cli/epic_driver/factory_spec.rb` (production `Factory` construction),
`spec/lain/cli/epic_driver/run_spec.rb`, `spec/lain/cli/epic_driver/issue_tests_spec.rb`,
`spec/lain/isolation/gc_spec.rb`

**Escalation triggers:**
- `issue_tests_spec.rb` "refuses, naming [tests], a project that declares no test layout" deletes
  the config from the held checkout. It must now delete it from the **project root**. If the
  refusal can no longer be reached, stop.
- A locked landing checkout must be released on **every** run end, including Ctrl-C. If no `ensure`
  covers the interrupt path, stop.

---

### T20 — Record a file's state before its first write in a turn, so write-set undo can put it back   [wave 2] [risk: medium]

**Depends on:** T3 (file: `agent/tool_delivery.rb`), T7 (file: `session.rb`)
**Files:** `lib/lain/tools/write_file.rb`, `lib/lain/tools/edit_file.rb`, `lib/lain/session.rb`,
`lib/lain/agent/tool_delivery.rb`, `lib/lain/agent/snapshot_slot.rb`,
`lib/lain/workspace/snapshot_log.rb`, `lib/lain/cli/command/undo.rb`,
`spec/lain/workspace/snapshot_log_spec.rb`, `spec/lain/cli/command/undo_spec.rb`,
`spec/lain/tools/write_file_spec.rb`, `spec/lain/tools/edit_file_spec.rb`
**Reuse:**
- `Revert::Move(before: nil)`, already a delete (`workspace/revert.rb:58, 82`).
- `SnapshotLog::Entry`'s `@pairs`, which lives outside the `:snapshot` body.
- `ToolDelivery#perform`'s slot priming (`tool_delivery.rb:57-59`).
- `edit_file`'s existing read.

**Shared-file wiring:** none
**Reachable from:** `Tools::WriteFile`/`EditFile` (`CLI::Wiring::BaseTools`) under
`manual`/`plan` (`:write_set` scope); `/undo` is registered in `Command::Surface#history_commands`.

**The problem.** F107: under the write-set scope, nothing records a path's state before a turn's
first write. Every created file and every first overwrite of a tracked file refuses as "first
written in that turn", and after a posture change the refusal names paths the turn never touched.

**The design.**
- **Capture the pre-image.** `write_file`/`edit_file` record a per-turn pre-image (`absent` or the
  bytes) the first time a path is written in a turn.
- **Scope it to the turn.** `ToolDelivery#perform` opens the turn's pre-image set, and `settle`
  hands it to the snapshot.
- **Store it out of band.** `SnapshotLog::Entry` keeps pre-images beside `@pairs`, never in the
  `:snapshot` body.
- **Undo reads it.**
  - An `absent` pre-image deletes the file; bytes restore it.
  - `changed` is limited to keys that moved since an earlier record or carry a pre-image from this
    turn. Others are skipped, not blamed.
  - `:unrecorded`'s sentence says "nothing recorded what it held before lain first wrote it" (not
    "first written in that turn").

**Acceptance criteria:**

```gherkin
Scenario: a created file is removed by undo under manual
  Given a manual-posture session whose turn created x.txt
  When the human types /undo
  Then x.txt no longer exists and the reply names it as deleted

Scenario: a first overwrite of a tracked file is restored under manual
  Given a manual-posture session whose turn overwrote a committed keep.txt
  When the human types /undo
  Then keep.txt holds its committed bytes

Scenario: undo after a posture change names only what the turn wrote
  Given a session with accept_edits turns writing c.txt then a manual turn writing only e.txt
  When the human types /undo
  Then the reply names e.txt and no other path

Scenario: shadow-git undo is unchanged
  Given an accept_edits session whose turn created b.txt
  When the human types /undo
  Then b.txt is deleted exactly as before this change
```

→ spec file: `spec/lain/cli/command/undo_spec.rb` (production `/undo` over a real `SnapshotLog`
and tools), `spec/lain/workspace/snapshot_log_spec.rb`

**Escalation triggers:**
- `Plan::Closure` reads the `:snapshot` body (`plan/closure.rb:115-116`). If a pre-image seems to
  belong in that body, stop.
- A `bash` write between capture and the tool's write is a race. If a spec shows a pre-image
  capturing bytes a shell wrote in the same turn after the tool's first write, stop and confirm the
  scope's documented gap.
- **Memory.** Pre-images hold bytes of every first-written file in a turn. If an existing spec
  writes files over `ReadFile::WHOLE_BOUND`, stop and confirm whether an oversized pre-image refuses
  the undo or skips capture.

---

### T21 — Critique a held review Docent-style, over the changeset's objects, one chunk per child   [wave 2] [risk: high]

**Depends on:** none
**Files:** `lib/lain/review/critique.rb` (new), `lib/lain/middleware/skill_dispatch.rb`,
`lib/lain/cli/command/surface.rb`, `lib/lain/cli/repl_middleware.rb`,
`spec/lain/review/critique_spec.rb` (new), `spec/lain/middleware/skill_dispatch_spec.rb`,
`spec/lain/cli/repl_middleware_spec.rb`,
`spec/lain/seams/critique_over_held_review_spec.rb` (new spec)
**Reuse:**
- `Review::Bounds#each_critique_chunk` (`review/bounds.rb:260-264`).
- `Review::Docent.for(changeset:, surface:, spawn:, journal:)` (`review/docent.rb:272`) and its
  fresh-root role-spawn seam.
- `Submit::Outbox#held_session` (`review/submit/outbox.rb:90-180`).
- The `critique` skill template (`prompt/templates/skill/critique/skill.md`) as each child's
  instructions.
- `Source::LocalBranch`'s object-level diff (`review/source/local_branch.rb:87`).
- `Review::Bounds`'s `max_critique_lines:` (`bounds.rb:198`), and `CLI::Backend::WindowBook` for
  the child model's served window.
- `Lain::ProxyBytes::BYTES_PER_TOKEN` for the estimate (the same one T24 uses).

**Shared-file wiring:** `require_relative "review/critique"` in `lib/lain/review.rb`
**Reachable from:** `/critique` typed at `you>` → `Repl#dispatch` → no command claims it →
`Command::Surface#middleware` → `CLI::ReplMiddleware.build` (`repl_middleware.rb:27`) →
`Middleware::SkillDispatch` → `Review::Critique`.
- `SkillDispatch` has no `outbox:` today.
- **This card threads it:** `Surface` builds the `Outbox` (`command/surface.rb:68`) and passes it,
  with the window book, through `ReplMiddleware.build(outbox:, window:)` into `SkillDispatch`.

**The human's ruling: build it.** F108: the 7,000-line critique chunker has never had a caller, and
`/critique` over an open review reads the dirty working tree.

**The design.**
- **With a round held,** `/critique [focus]` does not run the skill inline over the working tree.
  It builds `Review::Critique` over the held changeset.
  - **One fresh-root role child per chunk**, Docent-style, whose prompt carries that chunk's hunks
    from git objects and the skill's instructions.
  - **No working-tree tools**, or a read-only set scoped to nothing outside the chunk.
  - **Findings merged** in chunk order, rendered to the chat, and journaled per chunk.
- **Chunks are sized to the child's window.** Without this, every chunk child re-creates F90 on a
  local model: 7,000 lines is about 99k tokens against a 32k window, and T24 does not cover child
  requests.
  - `Critique` resolves the role child's served window through `WindowBook` and derives
    `max_critique_lines:` from it: the window, less the skill's instructions and a response
    reserve, in lines at the measured bytes per line.
  - `Bounds` measures every chunk before yielding one. So when any single chunk (one file's hunks,
    which `Bounds` never splits) still estimates over the window, the **whole critique refuses by
    name before spawning anything**, naming the window, the chunk and its estimate.
- **With no round held,** `/critique` is the skill exactly as today.

**Acceptance criteria:**

```gherkin
Scenario: a critique of a held review never sees the working tree
  Given /review of a local branch is held and the working tree has an uncommitted change
  When the human types /critique
  Then no child request contains the uncommitted change
  And each child request contains hunks from the reviewed revisions

Scenario: a large changeset is critiqued in chunks, not truncated
  Given a held review whose rendered lines exceed the critique ceiling
  When /critique runs
  Then one child is spawned per chunk
  And the merged findings name every chunk

Scenario: chunks fit the child's window
  Given a 32768-token child window and a held review of 7,000 changed lines across many files
  When /critique runs
  Then every child request estimates under the child's window

Scenario: a chunk that cannot fit refuses the critique before any spend
  Given a 32768-token child window and a held review whose single file's hunks estimate 60000 tokens
  When /critique runs
  Then no child is spawned
  And the refusal names the file, its estimate and the window

Scenario: /critique reaches the held round through the production chat wiring
  Given a chat built by CLI::Wiring with /review of a local branch held
  When the human types /critique
  Then Review::Critique runs over the held changeset rather than the skill

Scenario: without a held review, /critique is the skill
  Given no review is held
  When the human types /critique some/path
  Then the critique skill runs inline as before
```

→ spec file: `spec/lain/seams/critique_over_held_review_spec.rb` (a real `Outbox`, `Review::Session`
over a real `git` repo, `SkillDispatch` and a `Provider::Mock` capturing child requests — `:seam`),
`spec/lain/review/critique_spec.rb`, `spec/lain/middleware/skill_dispatch_spec.rb`

**Escalation triggers:**
- **Route.** The command registry is command-first, so registering `critique` as a command would
  shadow the skill everywhere. If `SkillDispatch` cannot see the `Outbox` without a new wiring
  seam, **stop and name the seam** rather than registering a command.
- **Tool bounds.** A merged findings render is not a tool result, but if a child result enters the
  main timeline it is subject to `spec/tool_bounds_discipline_spec.rb`. If that trips, stop.
- **Window resolution.** If the role child's model has no resolvable window before spawn (an
  unauthoritative `WindowBook` answer), stop. Do not fall back to the 7,000-line default: that
  default is the F90 shape.
- **Splitting a file.** If sizing needs `Bounds` to split one file's hunks across chunks, stop.
  `Bounds` keeps a file whole by design, and splitting changes what a finding can cite.

---

### T22 — Read subagent lineages the way the session file actually records them   [wave 3] [risk: medium]

**Depends on:** T12, T7 (file: `ARCHITECTURE.md`)
**Files:**
- `lib/lain/bench/session/lineages.rb` (new), `lib/lain/consolidation.rb`,
  `lib/lain/grader/tool_call_index.rb`, `lib/lain/cli/improve.rb`
- `lib/lain/compaction/derivation.rb` (comment only, `:61-63`), `lib/lain/cli/watch/lineage_filter.rb`
  (stale comment only, `:8-10`)
- `CLAUDE.md`, `ARCHITECTURE.md`
- `spec/lain/bench/session/lineages_spec.rb` (new), `spec/lain/consolidation_spec.rb`,
  `spec/lain/grader/tool_call_index_spec.rb`, `spec/lain/grader/frustration_repair_spec.rb`,
  `spec/lain/cli/improve_spec.rb`

**Reuse:**
- `Bench::Session::Loader` (`FLAT_EVENT_TYPES`, the `ChainFold`+`MessageReplay` fixpoint,
  `loader.rb:43, 196-205`).
- `StatusFeed::SpawnLifecycle#terminal?`.
- `spec/support/spawn_record.rb:40-52` (`#child(store)`) as the walk's shape.

**Shared-file wiring:** `require_relative "session/lineages"` in `lib/lain/bench/session.rb`

**Reachable from:**
- `exe/lain` `consolidate` → `CLI::Consolidate` → `Consolidation#lineages`.
- `exe/lain` `improve` → `CLI::Improve`.
- `exe/lain` `friction` → `Friction::Report` → `Grader::ToolCallIndex`.

**The problem.** F98: every lineage reader walks `turn` records with `meta.spawned_from`, a shape
production never wrote. `lain consolidate` finds nothing in any chat session, `lain improve` and
friction cannot see child work, and CLAUDE.md states the false shape.

**The design.**
- **One reader.** `Bench::Session::Lineages` yields `(spawn, completion, child_turns)` per
  **completed** lineage, over `Loader`'s Store. The spawn is the `:spawn` among the completion's
  `causal_parents`; the child is `Timeline(head: completion.body.final)` walked to
  `spawn.body.spawned_from` (inherit) or its root (fresh).
- **Every lineage reader moves onto it:** `Consolidation`, `ToolCallIndex`'s predecessor, and
  `Improve`.
- **Invented shapes go.** Spec helpers that invent `meta.spawned_from` are replaced with records a
  real `Scribe` writes.
- **Docs.** CLAUDE.md and ARCHITECTURE.md say where lineage actually lives.

**Acceptance criteria:**

```gherkin
Scenario: consolidate finds the lineages a chat session recorded
  Given a session file written by a real chat whose agent spawned two one-shot subagents that completed
  When lain consolidate --dry-run runs on it
  Then it names two lineages

Scenario: an inherit-prefix child is walked only to its spawn point
  Given a recorded inherit-prefix spawn and its completion
  When the lineages are read
  Then the child's turns stop at the parent's head named by spawned_from

Scenario: friction attributes a child's failure to the turn that spawned it
  Given a session whose subagent child repeated a failing call
  When lain friction runs
  Then the repair signal names the parent turn that spawned the child

Scenario: an open or damaged session is refused by name, not silently empty
  Given a session file with a torn child_turn line
  When lain consolidate runs on it
  Then it exits 1 naming the damage
```

→ spec file: `spec/lain/bench/session/lineages_spec.rb` (session files written by a real `Scribe`),
`spec/lain/consolidation_spec.rb`, `spec/lain/grader/tool_call_index_spec.rb`,
`spec/lain/cli/improve_spec.rb`

**Escalation triggers:**
- `consolidation_spec.rb:230` ("drops a headless tail") becomes a refusal under `Loader`. It changes
  deliberately. If `lain improve` on a live, still-open session must keep working, stop and confirm
  whether an open session reads its completed lineages or refuses.
- `scribe_spec.rb:395` must stay green: this card reads, it never re-types child usage.
- Resume chains: if `Loader` needs a `resolve:` that `consolidate`'s selector cannot supply, stop.

---

### T23 — Make `+auto_approve` switch the automatic approver on and off, and show it when the flag set it   [wave 3] [risk: high]

**Depends on:** T6 (file: `repl/approval_surfaces.rb`), T4 (file: `wiring/toolset_build.rb`),
T15 (file: `cli/switchboard.rb`)
**Files:** `lib/lain/mode/layer.rb`, `lib/lain/approval/auto_surface.rb`,
`lib/lain/cli/wiring/toolset_build.rb`, `lib/lain/cli/switchboard.rb`,
`lib/lain/cli/repl/approval_surfaces.rb`, `spec/lain/mode/layer_spec.rb`,
`spec/lain/approval/auto_surface_spec.rb`, `spec/lain/cli/command/mode_spec.rb`,
`spec/lain/cli/switchboard_spec.rb`
**Reuse:**
- `LiveToolset.new(-> { @resolved })`'s thunk pattern (`switchboard.rb:285`).
- `Escalation::Surfaces::AUTOMATIC`.
- `Mode::Layer::DECLARED` and the lighter rule.

**Shared-file wiring:** none
**Reachable from:** `/mode +auto_approve` → `Command::Mode` → `BoundSwitch#switch`
(`switchboard.rb:421-426`); `--auto-approve` seeds the session's initial `Mode`
(`switchboard.rb:189`); `ApprovalSurfaces#watch` on every dispatched line.

**The human's ruling: wire all four layers.** This card owns `auto_approve`; T27 owns `goal`; T28
owns `vi` and `notify`.

**The problem.** F104: `+auto_approve` lights `AA` and approves nothing, while `--auto-approve`
approves with no lighter.

**The design.**
- **Build `AutoSurface` for every attended session**, gated by a live predicate over the mode
  switch's layers.
- **Its watcher decides only while the layer is on.** Turning the layer off mid-session withdraws
  it from the next pending.
- **`--auto-approve` seeds `layers: [:auto_approve]`**, so its lighter shows.
- **Correct the comment** at `layer.rb:75-79`.

**Acceptance criteria:**

```gherkin
Scenario: turning the layer on lets the automatic approver decide
  Given an attended chat at accept_edits
  When the human types /mode +auto_approve and a gated call parks
  Then the pending is decided by the auto_approver surface

Scenario: turning the layer off returns decisions to the human
  Given the auto_approve layer on
  When the human types /mode -auto_approve and a gated call parks
  Then no automatic surface decides it

Scenario: the launch flag shows its lighter
  Given lain chat --auto-approve
  When the first prompt renders
  Then the prompt carries the AA lighter and /mode lists auto_approve

Scenario: a denied path stays unliftable under the layer
  Given the auto_approve layer on
  When the model reads a protected private key with read_file
  Then it is refused by the sensitivity boundary before any surface is asked
```

→ spec file: `spec/lain/cli/switchboard_spec.rb` (production `Switchboard` and `ToolsetBuild` over
real options), `spec/lain/cli/command/mode_spec.rb`, `spec/lain/approval/auto_surface_spec.rb`

**Escalation triggers:**
- `Switchboard` is built after the toolset, so the predicate must be a thunk. If `AutoSurface` needs
  the switch at construction, stop.
- Each automatic decision costs a model spend. If building `AutoSurface` for every attended session
  constructs a provider at launch that spends or requires a key when the layer is off, stop.
- `method.md` bans `+auto_approve` as a route to approve-all. T29 amends it; if an existing
  **discipline** spec encodes that ban, stop.

---

### T24 — Measure a request against the served window before sending, and witness a truncation after   [wave 3] [risk: high]

**Depends on:** T14 (file: `cli/wiring.rb`), T4
**Files:** `lib/lain/middleware/request_budget.rb` (new), `lib/lain/cli/wiring.rb`,
`lib/lain/usage.rb`, `lib/lain/agent/accounting.rb`, `lib/lain/telemetry/window_pressure.rb` (new),
`spec/lain/middleware/request_budget_spec.rb` (new), `spec/lain/usage_spec.rb`,
`spec/lain/agent/accounting_spec.rb`, `spec/lain/cli/wiring_spec.rb`,
`spec/lain/telemetry/window_pressure_spec.rb` (new), `spec/lain/seams/over_window_request_spec.rb`
(new spec)
**Reuse:**
- `Lain::ProxyBytes::BYTES_PER_TOKEN` (4), **only** as the estimate before the first believed
  reading.
- `CLI::Backend::WindowBook::Live` and `Wiring#backing`'s `turn_phase` composition
  (`wiring.rb:531-544`).
- `Telemetry::TruncatedStream` (`provider/ollama.rb:479-484`) as the provider-cut witness
  precedent.
- `Chronicle#durable_journal` (T4) for the `window_pressure` record.

**Shared-file wiring:** `require_relative "middleware/request_budget"` in `lib/lain/middleware.rb`;
`require_relative "telemetry/window_pressure"` in `lib/lain/telemetry.rb`
**Reachable from:** `exe/lain` → `ChatLaunch#call` → `Wiring#run` → `agent_over` → `Wiring#backing`.
- There the card composes `model_middleware:` itself:
  `Stack[RequestBudget.new(book: window, journal:), *chronicle model middleware]`, beside
  `turn_phase`.
- **Not** inside `Chronicle.instrumentation`, which has no model stack under `--no-journal`
  (Grounding §5).

**The problem.** F90: a 330 KB request was truncated by ollama to 16,386 tokens, dropping the system
prompt and tools. Lain journaled the truncated count as occupancy (50%, then 16%), nothing warned,
and the model lost its tools.

**The design.**
- **One object, both sides of the call.** `RequestBudget` is outermost in the model phase. It
  wraps the provider call, so it sees the rendered request going out and the usage coming back,
  and it is provider-agnostic.
- **The estimate is calibrated, not fixed.** 4 B/token is wrong both ways: against the measured
  5.5 B/token it refuses at about 73% real occupancy, before `ApproachingWindow` (0.9) can compact.
  Against dense JSON at about 3 B/token it under-detects.
  - So the budget keeps the ratio from the **last believed reading**, `prompt tokens ÷ request
    bytes`, and uses 4 only before the first one.
  - The request's canonical bytes are measured **once per call** and carried in the model-phase
    env, never re-dumped (`Request` memoizes nothing).
- **Before sending.** When the calibrated estimate exceeds the served window, the call is
  **refused before sending**:
  - it journals `window_pressure kind=over_window` with the estimate, the ratio and the window;
  - it hands the ask a one-line refusal naming the estimate, the window and the moves: compaction,
    `/rewind`, `/pin` release, a narrower read.

  This is an `Ask` value, so the session survives.
- **After sending.** When the reported prompt tokens are below half the estimate, the budget
  journals `window_pressure kind=truncated` with both numbers, keyed by request digest.
  - It returns the response with its `Usage` marked `prompt_truncated: true`: a new `Usage` field
    defaulting to false, carried by `Response#with`.
  - `Accounting#take_reading` skips a truncated reading.
  - A truncated reading never updates the calibration.
- **Open decision 2 stands:** per-tool window-relative bounds are not built here.

**Acceptance criteria:**

```gherkin
Scenario: a request larger than the window is refused before it is sent
  Given a 32768-token served window and a timeline whose rendered request estimates 80000 tokens
  When the agent is about to call the model
  Then no provider request is made
  And a window_pressure over_window record names the estimate and the window
  And the ask ends with a refusal naming the moves and the session answers its next prompt

Scenario: a truncated prompt is witnessed and not believed
  Given an ollama response whose prompt_eval_count is 5142 for a request estimated at 60000 tokens
  When the turn is accounted
  Then a window_pressure truncated record names both numbers
  And the published occupancy is not lowered to 5142 of the window

Scenario: an ordinary request is untouched
  Given a request estimated well under the window
  When the model is called
  Then no window_pressure record is written and the request is byte-identical to before

Scenario: the budget holds under --no-journal
  Given lain chat --no-journal wired by CLI::Wiring with a 32768-token window
  When a request estimating 80000 tokens is about to be sent
  Then no provider request is made and the ask ends with the refusal

Scenario: calibration follows the measured ratio
  Given a believed reading of 20000 prompt tokens for a 110000-byte request
  When the next request of 170000 bytes is rendered against a 32768-token window
  Then it is sent, because it estimates about 30900 tokens rather than 42500
```

→ spec file: `spec/lain/seams/over_window_request_spec.rb` (real `Agent`, production
`Wiring#backing` composition, `WindowBook` and a recording provider),
`spec/lain/middleware/request_budget_spec.rb`, `spec/lain/agent/accounting_spec.rb`,
`spec/lain/cli/wiring_spec.rb` (the `--no-journal` scenario)

**Escalation triggers:**
- **Compaction first.** A refusal that repeats every turn with nothing compactable is F82's shape. If
  compaction (T7's cut) would have shrunk the request, the budget must not fire before the pipeline
  runs. If ordering the middleware after the render cannot guarantee that, stop.
- **Child agents.** A child's requests are not journaled (`request_sent` is main-agent only). If the
  budget must cover children (T21's chunk children), stop and name the construction site.
- **Accounting gates.** `Accounting#take_reading` already gates on positive totals
  (`accounting.rb:84-87`). If "not believed" needs a third state in `StatusFeed`'s
  `unmeasured_turns`, stop and confirm rather than inventing one.
- **Warm KV cache.** Before building the truncation witness, measure whether ollama reports a low
  `prompt_eval_count` on a cache hit (only newly evaluated tokens). If it does, "below half" fires
  on every warm turn. Stop and pick the right field (or the `/api/ps` context) rather than shipping
  a witness that is always on.
- **Ractor shareability.** The calibration is mutable state in a middleware instance. If the model
  stack must be `Ractor.shareable?`, stop and name where the ratio lives instead.

---

### T25 — Advance the epic from one rule whichever surface approved it, and name the issue a gate is for   [wave 3] [risk: medium]

**Depends on:** T17 (file: `cli/epic_submit.rb`), T5 (file: `cli/epic_queue.rb`)
**Files:** `lib/lain/epic/advance.rb` (new), `lib/lain/epic/in_flight.rb`,
`lib/lain/cli/epic_submit.rb`, `lib/lain/cli/epic_queue.rb`, `spec/lain/epic/advance_spec.rb` (new),
`spec/lain/cli/epic_submit_spec.rb`, `spec/lain/cli/epic_queue_spec.rb`
**Reuse:** `Epic::InFlight` (`epic/in_flight.rb`, "at least once, only from the right state");
`EpicSubmit::Verdict#advance_epic` (`epic_submit.rb:260-281`).
**Shared-file wiring:** `require_relative "epic/advance"` in `lib/lain/epic.rb`
**Reachable from:** `exe/lain` `epic approve` → `CLI::EpicQueue` → `Starts`; `epic submit` →
`EpicSubmit::Verdict` and the `standing` path.

**The problems.**
- F112: approving `research`/`epic_plan` from the queue never writes `stage_transition`, and no
  command can repair it.
- Fork E15: implementation queue rows and sign-off messages do not name the issue, and "evidence:
  <none gathered -- the spike did not answer>" appears when no spike ran.

**The design.**
- **One rule for what an approval advances.** `Epic::Advance` answers it: an issue in flight, or the
  stage completed and the next one started. `Verdict`, `Starts` and `standing` all call it.
- **`standing` repairs** an approval with no transition.
- **Queue rows** for issue-scoped stages carry the issue id.
- **The evidence cell** says "no spike ran" when the policy gathered none.

**Acceptance criteria:**

```gherkin
Scenario: a queue approval of research advances the epic
  Given research parked under deferred
  When lain epic approve approves it
  Then lain epic status reads stage epic_plan

Scenario: a standing approval with no transition is repaired
  Given a research approval journaled with no stage_transition
  When lain epic submit research runs
  Then a stage_transition is journaled and status reads stage epic_plan

Scenario: implementation rows name their issue
  Given two parked implementation gates for issues greet and shout
  When lain epic queue lists them
  Then each row names its issue id
```

→ spec file: `spec/lain/cli/epic_queue_spec.rb` (production `EpicQueue` over a real home),
`spec/lain/epic/advance_spec.rb`, `spec/lain/cli/epic_submit_spec.rb`

**Escalation triggers:**
- `epic_submit_spec.rb` "completes the gated stage and starts its successor" must pass unchanged. If
  `Verdict` through `Advance` writes a different record sequence, stop.
- A transition must never be written twice for one approval. If `standing`'s repair can race a
  concurrent submit, stop and confirm the "at least once" rule covers it.

---

### T26 — Say the right thing at eight small refusals   [wave 3] [risk: low]

**Depends on:** T3 (file: `cli/resume.rb`), T16 (file: `exe/lain`)
**Files:** `lib/lain/cli/chat_launch.rb`, `lib/lain/cli/watch.rb`, `lib/lain/cli/improvements.rb`,
`lib/lain/cli/command/review.rb`, `lib/lain/review/source.rb`, `lib/lain/cli/context_pipeline.rb`,
`lib/lain/cli/resume.rb`, `lib/lain/cli/command/meta.rb`, `lib/lain/cli/command/survey.rb`,
`lib/lain/cli/survey.rb`, `exe/lain`, `spec/lain/cli/chat_launch_spec.rb`, `spec/lain/cli/watch_spec.rb`,
`spec/lain/cli/improvements_spec.rb`, `spec/lain/cli/command/review_spec.rb`,
`spec/lain/cli/context_pipeline_spec.rb`, `spec/lain/cli/resume_spec.rb`,
`spec/lain/cli/command/meta_spec.rb`, `spec/lain/cli/survey_spec.rb`
**Reuse:**
- `ChatLaunch#refuse_windows_without_journal!` (`chat_launch.rb:275-281`).
- `Survey`'s "takes a value" sentence.
- `Review::Source::Corpus`'s `named_from:`.

**Shared-file wiring:** none
**Reachable from:** each command's own exe path, named per item below.

**Items:**
- **F118.** `lain chat --windows` outside `$TMUX` refuses at launch in `ChatLaunch#call` (**not**
  `#preflight`: `lain up` pre-flights from a non-tmux shell), naming `$TMUX`.
- **F119.** `lain watch` accepts a bare hex prefix as well as `blake3:`, and a no-match names the
  session file it searched.
- **F120.** `lain improvements --kind X` with nothing of that kind says "no X improvements among N
  recorded", not "no improvements recorded yet".
- **F121.** `/review <branch> --base` with no value says `--base takes a ref`.
  - **V2:** a repo with no `main` refuses naming `--base <ref>`.
- **F123.** `repeated part` refusal's tail mentions `default` only when `default` is involved.
- **F124.** `--resume` of a session whose writer pid is alive says so ("still open in process N"),
  not "not gracefully closed".
- **F125.** `/meta` checks the generated script parses with `Prism.parse_success?`, which never
  evaluates, and says so instead of writing an unparseable `.rb` as ready. `/meta run` refuses an
  unparseable script by name.
- **F127.** The `--exec` help says a pipeline runs through `sh -c` inside the container.
- **V1.** `lain survey <path>` and `/survey <path>` name rows from the same base.

**Acceptance criteria:**

```gherkin
Scenario: --windows outside tmux refuses at launch but lain up's pre-flight does not
  Given no TMUX in the environment
  When lain chat --windows launches
  Then it exits 1 naming $TMUX
  And lain up's pre-flight with --windows succeeds

Scenario: lain watch takes a bare hex prefix
  Given a recorded spawn blake3:c81907db9d1c...
  When lain watch c81907db9d1c --session <file> runs
  Then the lineage renders

Scenario: an empty kind filter does not claim an empty store
  Given two doc improvements recorded
  When lain improvements --kind knob runs
  Then it says no knob improvements among 2 recorded

Scenario: /review --base with no value names the missing value
  Given a chat
  When the human types /review feature --base --permissive
  Then the refusal says --base takes a ref

Scenario: a live session's resume says it is live
  Given a session file whose writer process is running
  When lain chat --resume names it
  Then the notice says the session is still open in that process

Scenario: /meta does not hand back an unparseable script as ready
  Given a model reply that is prose, not Ruby
  When /meta writes the script
  Then the reply says the script does not parse and /meta run refuses it by name

Scenario: both survey surfaces name a row the same way
  Given a directory outside the chat's cwd
  When lain survey and /survey run on it
  Then both list its rows under the same names
```

→ spec file: `spec/lain/cli/chat_launch_spec.rb`, `spec/lain/cli/watch_spec.rb`,
`spec/lain/cli/improvements_spec.rb`, `spec/lain/cli/command/review_spec.rb`,
`spec/lain/cli/resume_spec.rb`, `spec/lain/cli/command/meta_spec.rb`, `spec/lain/cli/survey_spec.rb`,
`spec/lain/cli/context_pipeline_spec.rb`

**Escalation triggers:**
- `fleet_windows_spec.rb:653` pins the Null sink outside tmux. The **sink** stays Null; only
  `ChatLaunch#call` refuses. If the refusal needs `FleetWindows.for` changed, stop.
- **Checking the writer pid for F124** must not probe another user's process or hang. If
  `Process.kill(0, pid)` is not enough, stop.
- `/meta run` executing a script is the dangerous act. The parse check must run on the file
  **without** evaluating it. Stop if it can't.

---

### T27 — Let the human stop a running goal, and make the goal layer the driver's   [wave 4] [risk: medium]

**Depends on:** T13 (its `Frontend::TTY` typeahead drain; file `cli/human_replies.rb`), T6 (the
held-line slot in `Repl#next_text`), T24 (file: `cli/wiring.rb`)
**Files:** `lib/lain/cli/goal_driver.rb`, `lib/lain/cli/repl.rb`, `lib/lain/cli/command/goal.rb`,
`lib/lain/cli/command/mode.rb`, `lib/lain/cli/human_replies.rb`, `lib/lain/cli/wiring.rb`,
`lib/lain/frontend/tty.rb`, `spec/lain/frontend/tty_spec.rb`, `spec/lain/cli/repl_spec.rb`,
`lib/lain/frontend/neovim/runtime/70_inbox.lua`, `spec/lain/cli/goal_driver_spec.rb`,
`spec/lain/cli/command/goal_spec.rb`, `spec/lain/cli/command/mode_spec.rb`,
`spec/lain/frontend/neovim/runtime/70_inbox_spec.rb`
**Reuse:**
- `GoalDriver#interrupt`/`stop` (`goal_driver.rb:112-115`, no production caller yet).
- `HumanReplies#routes`' editor verb table (`human_replies.rb:395-401`).
- The mode switch's `BoundSwitch#switch`.

**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring` constructs `GoalDriver` (`wiring.rb:819-831`); `Repl#next_text`
(`repl.rb:156-160`) polls it; `:LainGoalOff` routes through `HumanReplies#editor_reply_loop` in a
cockpit.

**The problems.**
- F105: `/goal off` typed mid-drive runs only after the cap.
- F104's `goal` half: `/goal` never sets the `goal` layer.

**The design.**
- **Typed input stops the drive.** Between iterations, `Repl#next_text` asks the frontend for
  typed lines **before** polling the driver.
  - The stdin check belongs to the frontend, not `Repl`: it is `Frontend::TTY`'s typeahead drain
    from T13, exposed as a query that returns complete lines without opening a read.
  - A drained line goes into T6's held-line slot and is dispatched as `you>` first, so
    `/goal off` typed during a drive dispatches **before the next iteration**.
  - A line T13 already held (typed while an iteration parked an approval) takes the same path.
- **The cockpit can stop it.** `:LainGoalOff` in nvim calls `GoalDriver#stop`.
- **The driver owns the layer.** A standing goal sets the `goal` layer, and any stop (done, cap,
  off) clears it. `/mode +goal` with no standing goal refuses, and `/mode -goal` stops the goal.
- **Correct the stale comments** at `goal_driver.rb:19-24` and the spec heading at
  `goal_driver_spec.rb:329`.

**Acceptance criteria:**

```gherkin
Scenario: /goal off typed during a drive stops the next iteration
  Given a standing goal with a cap of 5 in its second iteration
  When the human types /goal off
  Then no third goal_iteration is journaled
  And the reply says the driver stopped

Scenario: /goal off typed while an iteration waits on an approval still stops the goal
  Given a plain chat with a standing goal whose second iteration parks a gated bash call
  When the human types /goal off and Enter, then answers the approval n
  Then no third goal_iteration is journaled

Scenario: the cockpit stops a goal
  Given a standing goal in a cockpit
  When :LainGoalOff runs in nvim
  Then the driver stops before its next iteration

Scenario: a standing goal shows its layer and loses it when it ends
  Given /goal <objective>
  When the first iteration runs
  Then /mode lists goal
  And after the goal reaches GOAL_COMPLETE /mode lists no goal layer

Scenario: the goal layer cannot be raised with no goal
  Given no standing goal
  When the human types /mode +goal
  Then it refuses naming /goal <objective>
```

→ spec file: `spec/lain/cli/goal_driver_spec.rb`, `spec/lain/cli/command/goal_spec.rb`,
`spec/lain/cli/command/mode_spec.rb`, `spec/lain/frontend/neovim/runtime/70_inbox_spec.rb` (real
headless nvim — `:seam`)

**Escalation triggers:**
- **Stdin readability.** The between-iteration query must reuse T13's drain under Reline's mutex.
  If it needs a second raw reader, or a partial line typed mid-iteration is dropped rather than
  left for `you>`, stop.
- **Discipline spec.** `spec/lain/cli/command/surface_spec.rb`'s literal roster pins the command
  set. `:LainGoalOff` is an editor verb, not a command; if one is needed, stop.
- **Lua spec file.** If `70_inbox.lua` is the wrong runtime module for an editor verb (verbs may
  live in another numbered file), name the right one and stop before editing two.

---

### T28 — Make the `vi` layer drive the line editor and the `notify` layer ring the terminal on arrivals   [wave 5] [risk: medium]

**Depends on:** T27 (file: `cli/wiring.rb`), T23 (file: `mode/layer.rb`), T13 (file:
`frontend/tty.rb`, `frontend/reline.rb`)
**Files:** `lib/lain/frontend/reline.rb`, `lib/lain/frontend/tty.rb`, `lib/lain/cli/wiring.rb`,
`lib/lain/mode/layer.rb`, `spec/lain/frontend/reline_spec.rb`, `spec/lain/frontend/tty_spec.rb`,
`spec/lain/mode/layer_spec.rb`, `spec/lain/cli/wiring_spec.rb`
**Reuse:**
- `Frontend::LineEditor#configure`, which runs on every read (`reline.rb:108-109, 147-157`).
- `TTY#render_arrival` (`tty.rb:205`) and T6's approval arrival line.
- tmux's `display-message` through the pane's `$TMUX` (the `FleetWindows` tmux invocation
  precedent).

**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring#run` → `tty_factory.call(channel:, prompt_renderer:)`
(`wiring.rb:284`); `/mode +vi` / `+notify` → `BoundSwitch#switch`.

**The human's ruling: wire all four.** No desktop notifier exists or is restored; `c40ab419`
deleted it for cause.

**The design.**
- **`vi`.** A live predicate over the mode switch's layers reaches `LineEditor`. `configure` sets
  vi mode on each read while the layer is on, and restores the editing mode the session started
  with when it is turned off. The "touches neither editing mode unless asked" contract (`:92-95`)
  holds when the layer was never raised.
- **`notify`.** While the layer is on, a question, approval or review arrival rings the terminal
  bell. Inside `$TMUX` it also raises `tmux display-message` naming the arrival. Nothing runs
  outside the terminal and tmux. The layer's lighter and its `/help` description say exactly that.

**Acceptance criteria:**

```gherkin
Scenario: raising the vi layer switches the line editor at the next read
  Given a chat whose session started in emacs editing mode
  When the human types /mode +vi and the next prompt reads
  Then the line editor is in vi mode
  And after /mode -vi the next read is in emacs mode

Scenario: an untouched session never changes the editing mode
  Given a chat that never raises the vi layer
  When prompts read
  Then the line editor's editing mode is never set by lain

Scenario: the notify layer rings on an arrival
  Given a chat with the notify layer on
  When a subagent's question arrives
  Then the terminal receives a bell and, inside tmux, a display-message naming the asker

Scenario: arrivals are silent without the layer
  Given a chat with the notify layer off
  When a question arrives
  Then no bell is written and no tmux command runs
```

→ spec file: `spec/lain/frontend/reline_spec.rb`, `spec/lain/frontend/tty_spec.rb`,
`spec/lain/cli/wiring_spec.rb` (the production `tty_factory` receives the live predicate)

**Escalation triggers:**
- **Restoring emacs** after vi must not override an operator's inputrc choice (`reline.rb:92-95`).
  If restoring means writing a mode the session never set, stop.
- **Tmux calls** run from the chat process, so `$TMUX` must be the chat's own. If
  `display-message` needs the `Up.pane_command` environment that F84's root cause named
  (round-16 chunk), stop and name it.
- **No shell-out** in the `notify` path may block the arrival render. If `Mixlib::ShellOut` without
  a timeout is the only route, stop.

---

### T29 — Bring the QA bench's documents in line with what this chunk and round 17 established   [wave 6] [risk: low]

**Depends on:** T19, T20, T22, T25, T26, T28
**Files:** `planning/qa/scenarios/cockpit-surfaces.md`, `planning/qa/scenarios/shell-terms.md`,
`planning/qa/scenarios/shell-term-approval.md`, `planning/qa/scenarios/rails-blog.md`,
`planning/qa/scenarios/repl-commands.md`, `planning/qa/scenarios/secret-boundary.md`,
`planning/qa/scenarios/changeset-review.md`, `planning/qa/scenarios/subagents-and-backends.md`,
`planning/qa/scenarios/memory-and-dogfood.md`, `planning/qa/scenarios/bench-arms.md`,
`planning/qa/scenarios/failure-injection.md`, `planning/qa/scenarios/bowling-ruby.md`,
`planning/qa/scenarios/session-and-window.md`, `planning/qa/scenarios/prompt-slots-and-roles.md`,
`planning/qa/scenarios/epic-tier.md`, `planning/qa/scenarios/survey.md`,
`planning/qa/scenarios/ollama-cloud-arm.md`, `planning/qa/method.md`, `planning/qa/README.md`
**Reuse:**
- The findings file's "Scenario corrections owed" list.
- The three fork reports' corrections (`~/tmp/lain-qa-round17/records/fork-*-report.md`).
- The memory rule that a stale enumeration is worse than a missing one.

**Shared-file wiring:** none
**Reachable from:** deferred: documents, not code. They are the inputs to the next `/manual-qa`
round, which is integration check 9 below.

**What changes.**
- **P36.** Remove or mark moot every notifier and `LAIN_DESKTOP` passage.
- **Round 17's corrections.** Apply the scenario corrections from the findings file and fork
  reports, **re-stated against this chunk's behaviour** where a card changed it:
  - nvim-first answer surfaces (T6);
  - the "decided by" line (T13);
  - named denials (T15);
  - `--cheap-model` (T16);
  - layers (T23, T27, T28);
  - `/critique` over a held review (T21);
  - the sticky cut (T7);
  - `window_pressure` (T24);
  - write-set undo (T20);
  - lineages (T22).
- **Expected strings get re-driven.** Every expected string a card changed is re-read against the
  built binary before it is written down. A prediction stays marked as a prediction.

**Acceptance criteria:**

```gherkin
Scenario: no scenario gates on the deleted notifier
  Given the planning/qa tree
  When it is searched for LAIN_DESKTOP, dunstify and dunstctl
  Then every hit is in a sentence recording that the notifier was deleted

Scenario: every changed refusal string in a scenario matches the binary
  Given the refusal strings this chunk changed
  When each is driven once against the built lain
  Then the scenario quotes the string the binary printed
```

→ spec file: `spec/lain/comment_census_spec.rb` is unaffected. There is no suite spec: this card is
gated by integration check 9 and a proofread. Its ACs are verified by the orchestrator with `rg`
and a scripted drive, recorded in the commit.

**Escalation triggers:**
- If a scenario's section depends on behaviour a card **deferred** (Open decisions 1–4), mark it
  deferred in the scenario. If the deferral contradicts the section's purpose, stop and ask.
- `README.md`'s roster rule: the directory listing is authority. If this card adds or removes a
  scenario file, stop.

---

## Integration checks

1. **The full suite, and the counts that make it trustworthy.**
   - Run `bundle exec rake pspec` with `LAIN_SPEC_WORKERS=12`, toolchain per CLAUDE.md.
   - Record the **example count** against the pre-chunk count (17,837 on 2026-09-13), not only the
     failure count: a dead worker reads as a pass.
   - Confirm `pgrep -cf 'mise/installs/ruby/[0-9.]*/bin/parallel_rspec'` reads 0 before believing a
     red run.
2. **Lints.** `bundle exec rubocop` (no `-A`), `pre-commit run --all-files`, and
   `bin/comment-census --check-tickets` (no ticket ids in `lib/`/`spec/`). Also
   `cargo test && cargo clippy --all-targets -- -D warnings`: no card touches Rust, but T1's policy
   must still agree with `read_text`. And the one `:core` run: `bundle exec rake core:build &&
   bundle exec rspec --tag core spec/lain/core/grep_parity_spec.rb` (T2).
3. **The three discipline specs the chunk adds or leans on, green together:**
   `spec/journal_routing_discipline_spec.rb` (T4), `spec/reply_surface_discipline_spec.rb` (T6),
   `spec/approval_consumer_discipline_spec.rb`.
4. **Reachability walk (human).** For each capability, trace from `exe/lain` to the construction
   site named on its card and confirm the collaborator is passed, not defaulted:
   - T4's `durable_journal` at all five sites and at the spawn seam;
   - T6's editor-attached branch and its command-only reader;
   - T14's tier options;
   - T21's `Surface` → `ReplMiddleware.build(outbox:, window:)` → `SkillDispatch` → `Critique`;
   - T23's `AutoSurface` predicate;
   - T24's `RequestBudget` composed in `Wiring#backing` under both `--journal` and `--no-journal`;
   - T28's `tty_factory` predicate.
5. **Manual: F88/F89 end to end (local ollama).** In a plain chat, ask for `bash` `echo "✅ ok"`
   and for `cat` of a Latin-1 file. The first commits; the second refuses by name. Neither writes
   `run_interrupted`, and the next ask's `request_sent` carries no unanswered `tool_use`.
6. **Manual: nvim-first cockpit.** In `lain up --nvim`, park a gated call and a subagent question.
   - The chat pane shows one line each and opens no answer reader.
   - Answer both in nvim.
   - Park the **main agent's own** gated call and approve it with `/approve` typed in the chat pane.
   - Type prose ahead during a dispatch. No `approval_decision` from `tty` appears, and the prose
     runs as the next prompt.
   - Repeat in `--no-nvim` and confirm the held-line, discard and `decided by` lines.
7. **Manual: compaction at scale** — `rails-blog` §1, the act round 17 could not reach. Drive a
   session with `--compact-strategy elide-tools+summarize-conversation` to a committed cut. Then:
   - `todo_write` with no completion, and confirm the next request's message count does not jump
     back;
   - confirm `context_derived` names a stable span and one `compaction_cut` carries its summary;
   - `/rewind` below the cut and confirm the next request carries no replacement;
   - quit and `--resume`, and confirm the first resumed request carries the recorded replacement
     with no summarizer call;
   - confirm `window_pressure` is absent until a deliberate 300 KB window read, where it refuses
     before sending.
8. **Manual: `/critique` of lain on itself (the human's ask).**
   - Open `/review` of a lain branch with real changes against `main` in a cockpit.
   - Dirty the working tree with a marker line.
   - Run `/critique`.
   - Confirm one child per chunk, every child request under the child's served window (read
     `ollama ps` and the child's `prompt_eval_count`, which must not be truncated), no child
     request containing the marker, and merged findings naming each chunk.
   - Record wall-clock and token counts per child (the "cost and latency" gap the QA README names).
9. **Manual: the next QA round.** Run `/manual-qa` with no scope over the corrected scenario set.
   The findings must account for every round-17 finding this chunk claims to discharge, each with a
   FIXED / DIFFERENT / UNCHANGED verdict. A round that finds nothing new did not push hard enough.
