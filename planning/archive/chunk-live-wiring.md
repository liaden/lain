# Live wiring: per-turn compaction, the secret-write guard, and two leaf gaps

status: done (2026-07-25, `fddc8e3..56a7815`, 15 commits)
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman · Aaron Patterson (Ruby roster, `create-plan/references/rosters.md`)

## Intent

Five chunks of bench machinery landed between 2026-07-18 and 2026-07-23, and the live chat
session uses almost none of it. `CLI::Backend` builds `Context.new` with no `pipeline:`, so
`Compaction::Scheduler` has no production caller; `RefuseSecretWrites` is constructed bare, so
live refusals journal to `Channel::Null`; four path tools ignore `worker_env.cwd`; and
`SessionRecord.turn` drops `causal_parents`. This chunk closes those, with compaction **on by
default** — a working harness default, not an opt-in arm. It satisfies the two named follow-ups
that the bench-science and gherkin chunks both deferred, and it is what makes the owed dogfood
passes performable at all.

Explicitly **not** here: tool-disclosure arms, and `Plan::Runner` (see Open decisions — the
investigation that ruled it out is recorded there with citations, so the next chunk inherits the
finding instead of rediscovering it).

## Grounding

Verified 2026-07-25 by four parallel `Explore` passes plus an executed probe, against `main` at
`fddc8e3`. Where docs and code disagreed, the code won and the disagreement is noted.

**The live construction path.**
- `lib/lain/cli/backend.rb:73-77` — `#context(system_override: nil)` builds
  `Context.new(model:, max_tokens:, extra:, system:)`. **No `pipeline:`.** Returns a fresh
  Context per call; called at **five** sites per chat run (`chat_launch.rb:105,107`;
  `wiring.rb:91,196,227`) plus a sixth thunk for subagents (`wiring.rb:153`).
- `lib/lain/cli/wiring.rb:190-202` — the live `Agent.new`: `provider:`, `toolset:`, `context:`
  (as `board.graft(backend.context)`), `handler:`, `session:`, `timeline:`, `request_override:`,
  `tool_middleware:`, `turn_middleware:`, `**chronicle.telemetry_kwargs`. Never passed:
  `workspace:`, `mailbox:`, `budget:`, `snapshot_writer:`, `transition_listener:`.
- `lib/lain/agent.rb:85` — `@context = context`, assigned once, `attr_reader` at `:48`, no
  writer. Only render at `:287-289`. `turn_middleware` (`:160-170`) carries `:iteration`/
  `:timeline` and cannot reach `#render` two frames deeper — the "INERT mount" the T18 deferral
  named. The Agent **does** hold `@session`, and `#render_request` already reads
  `@session.reminders`.
- `lib/lain/context.rb:105-118` — T21's seam. `pipeline:` is duck-typed: responds to `#requires`
  → used as-is; else called as `->(workspace)` per render. `@requires` derives from the effective
  pipeline at construction; `freeze` at `:117`. `#with_model` (`:124-126`) is the only copy-with
  and carries `pipeline:` through. **There is no `#with_pipeline`.**

**Shareability — the constraint that shapes the A-band.** Executed 2026-07-25 on ruby-4.0.5:

| `Context::Compact` summarizer | `Ractor.shareable?(compact)` | `Scheduler::COMPOSE` |
|---|---|---|
| a live `Oracle::Eager` | **false** | **raises `Ractor::IsolationError`** |
| `Plan::ClosureSummary` (static text — what the bench uses) | true | ok |
| a **frozen digest→summary map** | true | ok |

`Oracle::Eager` holds `@held`/`@fired` and is never frozen (`eager.rb:38-39`) — it must stay
mutable, that is its job. `Compact` freezes itself (`compact.rb:46`) but freezing does not make
it shareable when it references the Eager, and `Scheduler::COMPOSE`
(`scheduler.rb:143-147`) calls `Ractor.make_shareable` on a lambda closing over `compact`. So a
summarizer may **never** hold the live Eager; it must hold a per-turn frozen snapshot. This is
why A4 exists as its own card ahead of the assembly.

**Compaction.**
- `Scheduler#pipeline(need:, cold:, history_size:, base:, messages:)` (`scheduler.rb:118`)
  returns **`base` itself** on defer, else the shareable `COMPOSE` Proc. `Need#check`
  (`need.rb:114`) takes `messages`, `used_tokens`, `manual`, `plan_step_completed`. `Cold`
  (`cold.rb:72,98`) takes `#observe(turn_usage)` and `#idle!(idle_seconds)`.
- **No production caller** for `Scheduler`, `Prepared`, `Cold`, or `Need`; the only non-spec
  constructor of any is `bench/plan_sweep/driver.rb`. `agent.rb`/`agent/` grep clean.
- `bench/plan_sweep/driver.rb:130-153,173-176` is the reference for **assembly order only** —
  take the sequence (derive head → `Need#check` → `Scheduler#pipeline` → one Context per turn).
  Do **not** take its values: it hardcodes `cold: false` and `window_tokens: 1_000_000`.
- `Context::Compact` requires a pure, deterministic `#call(Array<Hash>) -> String`
  (`compact.rb:8-16,59-60` — **the whole dropped array in, one String out**). Every summarizer in
  the tree is `Plan::ClosureSummary.new(text: <static>)`, a bench stand-in. **No real default
  summarizer exists.**
- `Compact#call` (`compact.rb:52-57`) derives its own drop set as `messages[0...-@keep_last]` and
  byte-measures with `Canonical.dump`. `Need` byte-measures a head the *caller* supplies. If the
  two disagree by one message, `Need` fires on a window `Compact` never drops and nothing catches
  it — hence A5.
- `Effect::Handler::Summarizing` + `Oracle::Eager` are PC-7's designed answer, and
  `Summarizing` is **constructed nowhere**. Critically, `eager.rb:54-60` states where the fire
  belongs: *"a DIRECT caller inside a short-lived `Sync` that returns immediately may reap an
  in-flight fire before it resolves — that is a MISS, not an error. The spawn therefore belongs
  where a long-lived reactor is already in scope, **not inside an ephemeral gather task that
  would reap it on return**."* `ToolRunner#gather` (`tool_runner.rb:115-118`) is exactly that
  ephemeral `Sync`, and every parallel-safe read tool runs through it. P7's landing note records
  this as a sanctioned deviation to "revisit at P3 live-wiring" — this chunk is that revisit,
  hence A7.
- **No context-window figure exists.** `CacheProfile` (`cache_profile.rb:24`) has no window
  field; `Budget` holds a spend cap. `Accounting#usage` (`accounting.rb:19`) is **cumulative**;
  feeding it to `Need` would latch `ApproachingWindow` permanently. Hence A2 and A3.
- Measured on ruby-4.0.5, so no one re-litigates it: `Context.new` is **43 µs / 58 objects**
  (and flat in system-prompt size); `Context#render` over 20 turns is 546 µs. **Per-turn Context
  construction is free.** The real cost is on the compacting turn — `Canonical.dump` over a
  180 KB history is 712 µs, and `Compact` runs it once for the threshold plus once per message
  for the protected-pattern partition, while `Scheduler#accounting` (`scheduler.rb:167-169`)
  invokes `@compact.call` a *second* time purely to journal `tokens_after` and the pipeline runs
  it a *third* time at render.

**The secret-write guard.**
- `wiring.rb:208` — `def guarded_tools = Stack.new([RefuseSecretWrites.new])`. Bare: live
  refusals journal to `Channel::Null`, oracle is `NullOracle`. Three other mounts
  (`consolidation.rb:127`, `improve.rb:190`, `bench/cli/run_recorder.rb:66`) pass `journal:`.
- `refuse_secret_writes.rb:86-94` — regex `PATTERNS` first, `@oracle.secret?` second; both
  journal identically, the oracle's under `ORACLE_MATCH = "oracle-flagged"` (`:58`).
  `Guards::WriteRefused` requires `pattern` non-nil (`telemetry.rb:76-79`, enforced at `:366`).
  No `lib/` code reads `WriteRefused#pattern`; only specs do.
- `Oracle::MemorySave::OPAQUE_TOKEN = %r{\A[A-Za-z0-9+/=_.-]{24,}\z}` (`memory_save.rb:50`)
  refuses any unbroken 24+-char body — git SHAs, UUIDs, base64 — and that is pinned as *intended*
  today by `spec/lain/oracle/memory_save_spec.rb`. Deferral recorded verbatim at
  `chunk-bench-science.md:21-26` and `chunk-gherkin-…-compaction.md:85-87,155-156`.

**The two leaf gaps.**
- Path resolution, tool by tool. **Honor `worker_env.cwd`:** `read_file.rb:44`, `grep.rb:75-77`,
  `glob.rb:49`, `edit_file.rb:82`, `write_file.rb:40,61`. **Ignore it:** `list_files.rb:35`,
  `ast_search.rb:95-96`, `code_outline.rb:55`, `file_symbols.rb:54`. Reference pattern is
  `WorkerEnv#resolve` (`worker_env.rb:49-51`) as used by `bash.rb:88-101` and
  `core_exec.rb:77-78,95-102`. Docs said "tier-1 structural tools"
  (`chunk-parallel-tools-core-skeleton.md:118-121`); the code says **four** tools, one of which
  (`list_files`) is not structural and is unnamed in the follow-up. Code won.
- `SessionRecord.turn` (`session_record.rb:56-59`) emits six keys and **drops `causal_parents`**,
  though `Event` carries them (`event.rb:37-38`), they are part of the **content address**
  (`event.rb:101`), and `Agent` commits them live (`agent.rb:237`). Latent only because the live
  `mailbox:` is always `Context::Mailbox::Null`, so `inbox.folded` is always empty. The reader is
  `Bench::Session::ChainFold` (`bench/session/chain_fold.rb:55-57`), which rebuilds with only
  `role`/`content`/`meta` and then **verifies the digest**, raising `Corrupt` on mismatch
  (`:60-69`). All 13 committed `.ndjson` fixtures carry zero `causal_parents`. Byte-compatible
  twin writer: `Bench::Session::Scribe#turn_record` (`bench/session.rb:228-231`).

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only — no card lists these under **Files**):
  `lib/lain.rb`, `lib/lain/compaction.rb` (unit index), `lib/lain/cli/wiring.rb`,
  `.rubocop.yml`, `spec/spec_helper.rb`, `lain.gemspec`, `Gemfile`, `CLAUDE.md`,
  `.pre-commit-config.yaml`.
  - `lib/lain/cli/wiring.rb` is orchestrator-owned **for this chunk specifically**: three cards
    (B1, B4, A8) need one-line collaborator injections, and at 107/110 `ClassLength` it has
    three lines of headroom. Cards hand back the diff and own the spec that proves it.
  - Unit-index ownership follows `chunk-gherkin-meta-agents-plan-compaction.md`'s precedent.
    Exception: `lib/lain/agent.rb` is A1's file and `lib/lain/agent/tool_runner.rb` is A7's — each
    card owns its own `require` line, and no other card touches those files.
- **Index lines must be staged WITH the card that needs them.** `CLAUDE.md`'s commit-grouping
  rule and orchestrator-owned indexes interact badly: pre-commit stashes unstaged tracked changes
  and runs the suite against the staged tree, so a card's untracked spec runs while an unstaged
  index edit is stashed to `HEAD` — the constant does not resolve and an unrelated commit fails
  its hook. When committing A3, A4, or A5, stage the `lib/lain.rb` / `lib/lain/compaction.rb`
  line **in the same commit** as the new file and its spec.
- **Never raise `Metrics/ClassLength`** (`Max: 110`). Joel's one grant is spent on the assembly
  classes. **Corrected 2026-07-25 by A1: the plan's `Context` figure of 98 was raw file lines, not
  the cop's measure — `Context` actually measured 47, i.e. ~60 lines of headroom, not ~12.
  `Agent`'s 100 was right.** Comments do NOT count toward `ClassLength` here (probed by B1).
  Measured after waves 1–2: `CLI::Wiring` **108** — B4 spent three, the orchestrator's
  `#guard_kwargs` extraction bought two back, so **A8 has exactly two lines**; `Agent` **105**
  (A1); `Context` **50** (A1); `CLI::Backend` 46. If anything crosses, extract a collaborator
  (precedents already taken out of `Wiring`: `BaseTools`, `Switchboard`, `Command::Surface`,
  `Chronicle`, `ChatLaunch`).
- Deviations from the default process: none.

## Open decisions

None gating any card. Five rulings recorded so they are not relitigated:

- **`Plan::Runner` live wiring — ruled OUT (2026-07-25, Joel).** Investigated during planning and
  pivoted away. (1) `runner.rb:5-23` declares its own posture — *"the same built-for-the-bench
  posture as `Bench::Arm` and `Compaction::Scheduler`: Lain owns the loop because the loop is the
  object of study, and live `agent.rb` wiring is a deliberate later follow-up, not this driver."*
  (2) `bench/plan_sweep/driver.rb:112-118` already names the exact collision with A6: *"Cannot
  ride `Plan::Runner` faithfully — the Runner fixes one pipeline per chunk, whereas the scheduler
  re-decides every turn."* (3) `Runner#run` (`:87-93`) is a **top-level control flow** driving
  chunks → steps → `agent_step`, competing with the REPL loop rather than composing with it.
  (4) `Runner::Outcome` (`:38`) requires a `grade` per step. (5) Under A1 the Runner's per-step
  `Context.new(pipeline:)` (`:139`) degrades to a base the per-turn scheduler overrides,
  inverting its documented authority. **Verdict:** a Runner-backed `agent_step` is a second
  non-interactive execution mode (`lain plan run`), not live wiring — its own chunk.
- **Tool-disclosure arms — deferred (Joel, scope call).** Recorded because the wiring is not
  free: `Deferred` rewrites the head of the cache prefix (`request.rb:56-58`) and needs
  `Tools::ToolSearch`, which is in **no** toolset today (`wiring/base_tools.rb:15-22`).
- **Subagents get `PipelineSource::Null` — deliberate.** `child_seam_kwargs` passes
  `context_factory: -> { backend.context }` (`wiring.rb:153`) and `ChildBuilder#child_context`
  (`tools/subagent.rb:432`) builds from it. Sharing the parent's `Cold`/`Need` state across a
  child would cross-pollute two independent histories, and a per-child source is a bigger design
  question (whose window? whose idle clock?). Children stay uncompacted this chunk. **This is
  the known sharp edge**: a research subagent grinding tool results is the most likely thing to
  blow a window. Recorded as the first follow-up out of this chunk.
- **Rewind does not rewind compaction state.** `Agent#rewind` (`agent.rb:149-153`) rewinds the
  Timeline; `Cold`'s `@pending`/`@cold` do not follow. Accepted: the next turn's `#observe`
  corrects the warmth reading, and the byte-threshold detector reads the live history. Pinned by
  an A6 escalation trigger rather than solved.
- **`Compaction::Head` stays protected-agnostic; A6 wires `ProtectedPatterns::NONE`.**
  (Ruling 2026-07-25, orchestrator, on A5's escalation.) A5's probe confirmed the trigger's
  suspicion: under a non-`NONE` policy `Compact` removes a **subset** of the candidate head
  (measured 3 msgs / 579 B candidate vs 2 msgs / 514 B actually removed), so a protected-agnostic
  `Head` **over-reports**. Ruled acceptable, and `Head` keeps the candidate span, for three
  reasons. (1) It is latent: no production or bench site passes a non-`NONE` policy — `grep`
  clean. (2) The cost is asymmetric in the wrong place. `Head#bytesize` is consulted **every
  turn** to decide whether to compact; `Compact`'s protected partition runs only on turns that
  actually compact. Making `Head` protected-aware buys correctness for a latent case by adding a
  per-message `Canonical.dump` pass to the hot path — and Grounding already counts three full
  dumps on a compacting turn. (3) The error direction is fail-eager (compact slightly sooner),
  not fail-silent (never compact), which is the failure mode this chunk exists to prevent.
  **Binding constraint on A6:** wire `ProtectedPatterns::NONE` and say why in a comment. If a
  later chunk wants protected patterns live, `Head` must become protected-aware in the same
  change — A5 left a characterization example pinning today's behavior so this cannot re-hide.
- **`Manual` and `PlanStepCompletion` detectors.** `PlanStepCompletion` is wired (A6 reads
  `Session#plan_step_completed?`). `Manual` (`need.rb:74-85`) has no trigger this chunk — no
  `/compact` command is added. It ships dead, knowingly; a `/compact` command is a follow-up.

## Waves

```
Wave 1: A2, A3, A4, A5, A7, B1, B2, B3, C1, C2   (no unmet deps)
Wave 2: A1 (←A2), B4 (←B2,B3)
Wave 3: A6 (←A1,A3,A4,A5)
Wave 4: A8 (←A6,A7)
```

Critical path: **A2 → A1 → A6 → A8** (length 4).

Wave file-disjointness verified. `spec/lain/cli/wiring_spec.rb` is touched by B1 (w1), B4 (w2),
A8 (w4) — three different waves, and the `wiring.rb:208` diff is applied twice in that order
(B1's `journal:`, then B4's `oracle:`).

## Tasks

### A2 — Expose last-turn usage on Accounting          [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/agent/accounting.rb`, `spec/lain/agent/accounting_spec.rb`
**Reuse:** `Usage#total_input_tokens` (`usage.rb:47-49`) — the "billed on the way in" figure that
is the honest occupancy proxy; `Telemetry::TurnUsage` (`telemetry.rb:163`), already emitted per
turn at `accounting.rb:30-35`.
**Shared-file wiring:** none

`#usage` is the run's cumulative sum. Compaction needs *current context occupancy* — the most
recent response. Add a reader for it. **Return `nil`, not zero, before any turn:** `Need`
distinguishes them (`need.rb:67` guards `!state.used_tokens.nil?`), and a zero would read as
"empty context" on a resumed session whose Accounting is fresh but whose Timeline is not.

**Acceptance criteria:**

```gherkin
Scenario: last-turn usage is the most recent response, not the sum
  Given an Accounting that has observed two responses of 100 and 250 input tokens
  When last_turn_usage is read
  Then it reports 250 input tokens
  And the cumulative usage still reports 350

Scenario: before any turn the answer is unknown, not zero
  Given a freshly constructed Accounting
  When last_turn_usage is read
  Then it is nil

Scenario: observe still returns the cumulative total
  Given an Accounting with one observed response
  When another response is observed
  Then the return value is the cumulative Usage the budget check consumes
```
→ spec file: `spec/lain/agent/accounting_spec.rb`

**Escalation triggers:**
- `Agent#commit_and_account` (`agent.rb:241`) feeds `#observe`'s return straight into
  `Budget#check_tokens!`. If changing that return type is even considered, STOP.
- If any existing spec asserts `Accounting` has exactly one usage reader, STOP and confirm —
  this card adds a second and their meanings must not be confusable in the journal.

### A3 — A per-model context-window book          [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/context_window.rb` (new), `spec/lain/context_window_spec.rb` (new)
**Reuse:** `PriceBook` (`price_book.rb:50-70`) — copy its resolution shape: exact match, then the
longest known family token contained in the model name, optional explicit `fallback`, and
`UnknownModel` when there is none.
**Shared-file wiring:** orchestrator adds the `context_window` unit line to `lib/lain.rb`.

Nothing can supply `Need::ApproachingWindow`'s `window_tokens:`. Build the lookup — **with a
conservative default fallback**, because A8 turns compaction on by default and
`Backend::PROVIDERS` includes `ollama` and `bedrock` (`backend.rb:27`), whose model ids will
never be in an Anthropic-shaped table. A harness default must not turn a supported provider into
a startup crash. The raise stays available for explicit bench arms.

**Acceptance criteria:**

```gherkin
Scenario: an exact model name resolves
  Given a book with an entry for a specific dated model id
  When that id is looked up
  Then its window is returned

Scenario: a dated snapshot resolves by family
  Given a book with a family entry but no entry for a dated snapshot of it
  When the dated snapshot id is looked up
  Then the family's window is returned

Scenario: the default book answers for an unknown model
  Given the default book and an ollama-style model id in no table
  When it is looked up
  Then a conservative window is returned and nothing raises

Scenario: a book built without a fallback raises
  Given a book constructed with no fallback
  When an unrecognized model is looked up
  Then UnknownModel is raised naming the model
```
→ spec file: `spec/lain/context_window_spec.rb`

**Escalation triggers:**
- If a model name contains two known family tokens, mirror `PriceBook`'s tie-break rather than
  inventing one. If `PriceBook`'s actual behavior differs from longest-token-wins, STOP and
  reconcile — two lookup books disagreeing on one model name is worse than either rule.
- If the conservative fallback would have to be larger than the smallest real window in the
  table, STOP: a fallback that over-estimates the window means compaction never fires for the
  provider it was added for, which is worse than the crash it replaced.

### A4 — A frozen per-turn summary snapshot          [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/compaction/summary_snapshot.rb` (new),
`spec/lain/compaction/summary_snapshot_spec.rb` (new)
**Reuse:** `Oracle::Eager#held(digest)` (`eager.rb:84-86`) — non-blocking, nil on miss;
`Effect::Handler::Summarizing#fire_summary` (`summarizing.rb:~55`) for the **exact** key
derivation, `Canonical.digest(result.content)`; `Canonical.dump` for byte counts.
**Shared-file wiring:** orchestrator adds `compaction/summary_snapshot` to `lib/lain/compaction.rb`.

**This card exists because a summarizer may never hold the live `Eager`** — see Grounding's
executed shareability table. Deliver a frozen, shareable value object: built once per turn by
reading whatever the Eager holds for a given set of messages, it then answers
`#call(Array<Hash>) -> String` — the duck `Context::Compact` actually invokes
(`compact.rb:59-60`: whole dropped array in, one String out). A digest with a held summary
renders as that summary; a miss renders as an attested elision naming role, digest, and byte
count.

**Acceptance criteria:**

```gherkin
Scenario: a held summary is used
  Given an Eager holding a summary for a message's content digest
  When a snapshot is taken over that message and called with the dropped array
  Then the returned String contains the held summary

Scenario: a miss degrades to an attested elision
  Given an Eager holding nothing for a message
  When a snapshot is taken and called with the dropped array
  Then the returned String names that message's role, digest, and byte count

Scenario: the snapshot is frozen against later Eager writes
  Given a snapshot taken while the Eager held nothing for a message
  When the Eager later gains a summary for that same digest
  Then calling the same snapshot still returns the elision, byte-identically

Scenario: the snapshot is shareable
  Given a snapshot taken over any messages
  Then Ractor.shareable? is true for it
  And a Context::Compact holding it is shareable too

Scenario: it takes the whole dropped array
  Given a snapshot and three dropped messages
  When called once with all three
  Then one String is returned covering all three
```
→ spec file: `spec/lain/compaction/summary_snapshot_spec.rb`

**Escalation triggers:**
- `Summarizing` fires keyed on `Canonical.digest(result.content)` where content is the
  `Tool::Result`'s **String**; the committed *message* carries those bytes nested in a
  `tool_result` block. If the digest recomputed from the message does not equal the fired key,
  every lookup misses **silently** and the default degrades to pure elision with no error. Prove
  the round-trip in a spec — fire through `Summarizing`, then look it up from the committed
  message — **before** building the fallback. If they cannot be made to agree, STOP: the key
  derivation then belongs in one shared place, which is a design change, not a card.
- The fourth AC is the card's reason for existing. If it cannot be made to pass, STOP
  immediately — A6 and A8 both rest on it, and a non-shareable summarizer raises
  `Ractor::IsolationError` inside `Scheduler::COMPOSE` on the first compacting turn, not in any
  spec that holds the snapshot alone.
- `Eager#held` returns nil for both "no summary" and "still in flight". If the card wants to
  distinguish them, STOP — `Eager`'s API does not and widening it is out of scope.

### A5 — One candidate-head derivation          [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/compaction/head.rb` (new), `spec/lain/compaction/head_spec.rb` (new)
**Reuse:** `Context#render`'s message projection (`context.rb:138`,
`timeline.to_a.map { |t| {"role" => t.role, "content" => t.content} }`); `Compact#call`'s drop
slice (`compact.rb:52`, `messages[0...-@keep_last]`); `Canonical.dump(...).bytesize` as the byte
proxy both `Need` and `Compact` use.
**Shared-file wiring:** orchestrator adds `compaction/head` to `lib/lain/compaction.rb`.

`Need` byte-measures a head its caller supplies; `Compact` derives its own drop set internally
from the same `keep_last`. Nothing makes them agree, and a one-message disagreement means `Need`
fires on a window `Compact` never drops — silently, forever. Extract the derivation so there is
exactly one answer to "what is the candidate head, and how big is it."

**Acceptance criteria:**

```gherkin
Scenario: the head excludes the kept tail
  Given a timeline of ten turns and a keep_last of three
  When the head is derived
  Then it holds the first seven messages in timeline order

Scenario: the head's byte size is the canonical dump size
  Given a derived head
  When its size is read
  Then it equals the canonical dump bytesize of its messages

Scenario: the head agrees with what Compact would drop
  Given the same messages and keep_last handed to a Context::Compact
  When Compact summarizes above its threshold
  Then the messages it dropped are exactly the head's messages

Scenario: a timeline shorter than keep_last yields an empty head
  Given a timeline of two turns and a keep_last of three
  When the head is derived
  Then it is empty and its size is zero
```
→ spec file: `spec/lain/compaction/head_spec.rb`

**Escalation triggers:**
- The third AC couples this card to `Compact`'s private slicing. If `Compact` turns out to drop a
  different set than `messages[0...-@keep_last]` under `protected_patterns`
  (`compact.rb:56-58` partitions the dropped set further), STOP and confirm which set `Need`
  should be measuring — the protected head survives, so measuring it as droppable over-reports.

### A7 — Fire eager summaries from the agent loop, not the gather task          [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/agent/tool_runner.rb`, `spec/lain/agent/tool_runner_spec.rb`
**Reuse:** `Oracle::Eager#fire(digest, text)` (`eager.rb:65-79`) and its own placement rule at
`:54-60`; `Effect::Handler::Summarizing#summarizable?` (`summarizing.rb:~62`) for the
"successful, String content, over threshold" predicate; `ToolRunner#gather`
(`tool_runner.rb:115-118`) as the scope to fire **after**, not inside.
**Shared-file wiring:** none

`Eager`'s own header forbids the mount A6/A8 would otherwise take: a fire spawned inside
`gather`'s ephemeral `Sync` is reaped when that scope returns. Every parallel-safe read tool goes
through `gather`, and those are exactly the tools producing results worth summarizing — so the
naive mount misses systematically in production while passing in a spec that awaits the task.
Give `ToolRunner` a post-dispatch observation seam that runs in the agent's long-lived reactor,
defaulting to a Null that fires nothing. P7's landing note flagged this as the revisit.

**Acceptance criteria:**

```gherkin
Scenario: a large result is observed after the gather scope closes
  Given a ToolRunner with an observer and a tool returning a result over the threshold
  When a turn of tools is dispatched
  Then the observer saw that result after the gathering scope returned

Scenario: the fire survives to completion
  Given a real Oracle::Eager as the observer inside a long-lived reactor
  When a turn dispatches a large tool result
  Then the summary is retrievable from the Eager after the turn completes

Scenario: the default observer changes nothing
  Given a ToolRunner constructed without an observer
  When a turn of tools is dispatched
  Then the committed tool_result turn is byte-identical to before this change

Scenario: an observer that raises does not break the turn
  Given an observer that raises
  When a turn of tools is dispatched
  Then the tool results are returned unchanged
```
→ spec file: `spec/lain/agent/tool_runner_spec.rb`

**Escalation triggers:**
- The second AC is the whole point and is the one that will be tempting to weaken. If it can only
  be made green by awaiting inside `gather`, STOP — that reintroduces the reaping this card
  exists to fix, and `eager.rb:54-60` says so explicitly.
- `gather` is inside `Sync` with structured cancellation (`tool_runner.rb:110-118`): a stop
  cancels siblings as one tree. If the new seam changes what an interrupt mid-fan-out commits,
  STOP — gate 2 (all results land in ONE user turn) is pinned by existing specs.
- If firing post-dispatch requires `ToolRunner` to know about `Oracle::Eager` by name rather than
  through a duck, STOP: the dependency direction is wrong and the Null default becomes impossible.

### A1 — Give Agent a per-turn Context seam          [wave 2] [risk: high]

**Depends on:** A2
**Files:** `lib/lain/agent.rb`, `lib/lain/agent/pipeline_source.rb` (new), `lib/lain/context.rb`,
`spec/lain/agent/pipeline_source_spec.rb` (new), `spec/lain/agent_spec.rb`,
`spec/lain/context_spec.rb`
**Reuse:** `Context#with_model` (`context.rb:124-126`) — the copy-with precedent, which already
carries `pipeline:` through; `Context#pipeline_for` (`:161-165`) for the duck contract;
`T21PipelineProviders::DEFAULT` (`spec/lain/context_spec.rb:35-45`) as the shareable-provider
spec idiom; `Accounting#last_turn_usage` (A2); the Agent's own `@session`, already read by
`#render_request` (`agent.rb:288`).
**Shared-file wiring:** none.

Deliver `Context#with_pipeline(pipeline)` — the mirror of `#with_model` — and
`Agent::PipelineSource`, a duck answering
`context_for(base:, timeline:, usage:, session:) -> Context`, with `PipelineSource::Null` (a real
Null Object returning `base` unchanged) as the default. `Agent#render_request` routes through it,
passing its own `@session` and A2's last-turn usage.

**The `session:` parameter is load-bearing and must be in the signature from this card.** A6
needs `Session#plan_step_completed?` (`session.rb:163`), and the Session is not reachable from
`CLI::Backend` where A8 constructs the source — it is built in `Wiring#run_state`
(`wiring.rb:74-79`) and handed to `Agent.new` separately. The Agent is the only place both
exist.

**Acceptance criteria:**

```gherkin
Scenario: the default source changes nothing
  Given an Agent constructed without a pipeline_source
  When it renders a turn
  Then the Request is byte-identical to one rendered from its base Context directly

Scenario: an injected source decides what renders
  Given a pipeline_source returning base.with_pipeline(a combinator dropping the first message)
  When the agent takes a turn
  Then the rendered Request's messages are missing that first message

Scenario: the source is consulted every turn, not once
  Given a pipeline_source returning a different pipeline on each call
  When the agent runs three turns
  Then three distinct pipelines were applied, one per render

Scenario: the source receives the session and the last turn's usage
  Given an Agent that has completed one turn
  When the next render calls the source
  Then it received the agent's Session and the previous response's usage

Scenario: with_pipeline preserves a live model switch
  Given a Context grafted with a Context::ModelSwitch and then copied via with_pipeline
  When the switch's current model changes
  Then the copied Context renders the new model

Scenario: a per-turn Context stays shareable
  Given a pipeline_source returning a Context built from a shareable provider
  When the agent renders
  Then Ractor.shareable? is true for the Context it rendered through
```
→ spec files: `spec/lain/agent/pipeline_source_spec.rb`, `spec/lain/agent_spec.rb`,
`spec/lain/context_spec.rb`

**Escalation triggers:**
- `Context#with_model(model)` passes a **shadowed parameter**, not the reader (`context.rb:124-125`).
  `@model` may be a `ModelSwitch`/`StaticModel` whose reader (`:71`) unwraps to `.current`, so a
  `with_pipeline` that writes `model:` from the reader flattens the switch to its present value
  and silently breaks `/model`. The fifth AC exists to catch exactly this — write it first.
- `Agent#request_override` (`agent.rb:277-282`) bypasses `#render` entirely. If any existing spec
  asserts a resend's relationship to the rendered request, do not change it — stop and confirm.
- `Context#initialize` derives `@requires` from the effective pipeline and then freezes. If a
  per-turn Context's `requires` differs from the base's, capability guarding (`:strict`/`:degrade`)
  can now fire mid-session where it never did — stop and confirm the intended policy.
- `Agent` measures **100 of 110** `ClassLength` and `Context` **98**. This card grows both. If
  either crosses, extract — do not raise the limit.

### A6 — The live compaction Context source          [wave 3] [risk: high]

**Depends on:** A1, A3, A4, A5
**Files:** `lib/lain/compaction/source.rb` (new), `spec/lain/compaction/source_spec.rb` (new)
**Reuse:** `Compaction::Scheduler#pipeline` (`scheduler.rb:118`), `Need#check` (`need.rb:114`),
`Cold#observe`/`#idle!` (`cold.rb:72,98`), `Compaction::Head` (A5), `SummarySnapshot` (A4),
`ContextWindow` (A3), `Context#with_pipeline` (A1); the assembly **order** of
`bench/plan_sweep/driver.rb:130-153` (not its hardcoded values); `StatusFeed`'s injected-clock
idiom (`status_feed.rb:112`).
**Shared-file wiring:** orchestrator adds `compaction/source` to `lib/lain/compaction.rb`.

Implement A1's duck for real. Two halves, kept visibly separate inside the object: **observe**
(feed `Cold` this turn's usage and the clock's idle gap) and **decide** (derive the head, check
`Need`, ask `Scheduler`, take a fresh `SummarySnapshot`, and answer with either the base Context
untouched or a copy carrying the composed pipeline).

**Acceptance criteria:**

```gherkin
Scenario: deferring is a true no-op
  Given a history well below the byte threshold
  When context_for is called
  Then the returned Context renders byte-identically to the base Context

Scenario: crossing the hard cap compacts even while the cache is warm
  Given a history above the scheduler's hard cap and a cache that is not cold
  When context_for is called
  Then the returned Context's render shows the head summarized

Scenario: a cold cache is observed from usage
  Given a turn whose usage reports zero cache-read tokens
  When that usage is observed and context_for is called at the threshold
  Then the decision taken is the cold-free one, not the forced-warm one

Scenario: a completed plan step is a trigger
  Given a Session reporting a completed plan step and a history above the byte threshold
  When context_for is called
  Then compaction applies

Scenario: occupancy comes from the last turn, not the run
  Given three observed turns whose cumulative input tokens exceed the window
    but whose most recent turn is far below it
  When context_for is called
  Then the approaching-window signal does not fire

Scenario: a resumed session does not force-compact on its first turn
  Given a source whose usage is nil because no turn has completed this process
  When context_for is called against a large resumed history
  Then the approaching-window signal does not fire

Scenario: every returned Context is shareable
  Given any decision path, deferring or compacting
  When context_for returns
  Then Ractor.shareable? is true for the returned Context
```
→ spec file: `spec/lain/compaction/source_spec.rb`

**Escalation triggers:**
- `Scheduler#pipeline` returns **`base` itself** on defer (`scheduler.rb:120`). Wrapping or
  copying it anyway makes the deferring turn non-byte-identical and turns the DEFER contract into
  a lie no test catches. AC1 pins exactly this.
- The last AC is the blocker A4 exists to prevent. If a compacting turn raises
  `Ractor::IsolationError` from inside `Scheduler::COMPOSE`, the snapshot is not frozen or the
  source is closing over itself — STOP, do not work around it by skipping `make_shareable`.
- `Need#check(used_tokens:)` must get A2's last-turn value, and **nil when there is none**.
  Passing cumulative usage latches `ApproachingWindow` permanently once the run total crosses the
  window; passing zero on a resumed session reads as an empty context. AC5 and AC6 pin both.
- `Cold#idle!` needs elapsed seconds and no clock exists in the agent loop. If the card reads
  `Time.now` inline rather than through an injected clock, STOP — determinism under replay is why
  the clock is a collaborator.
- `Scheduler#accounting` (`scheduler.rb:167-169`) re-invokes `@compact.call` purely to journal
  `tokens_after`, so a compacting turn runs summarization three times (threshold check,
  accounting, render) plus a `Canonical.dump` per message for the protected-pattern partition.
  Against a multi-second round trip that is survivable, but if a spec shows the snapshot being
  rebuilt inside any of those passes, STOP — it must be taken once per turn.
- Rewind does not rewind `Cold`'s flags (see Open decisions). If a spec asserts warmth is
  consistent across a rewind, that is out of scope — confirm rather than fixing it here.
- **Get `base:` from `Context#pipeline_for`, NOT from `base.class.pipeline(workspace)`, and NOT
  from `bench/plan_sweep/driver.rb`.** (A1's panel, 2026-07-25 — the highest-value finding for this
  card.) `base.class.pipeline(workspace)` **silently discards an injected `@pipeline`**: an
  `Identity`-carrying Context rebuilds reporting `[:prompt_caching]`. And the precedent A6 would
  naturally copy, `driver.rb:42`, uses `->(_ws) { CacheBreakpoints.new }` — which **omits
  `Reminder`**, so copying it makes **session reminders vanish on every compacting turn with
  nothing failing**. A1 makes `#pipeline_for` public precisely so this card can ask.
- **The capability drift A1 first recorded was misdiagnosed; here is the real one.**
  `with_pipeline(Prune)` does drop `:prompt_caching`, but `Scheduler#pipeline` returns
  `COMPOSE(compact, base)`, whose `#requires` is the **union** — so the composed per-turn Context
  *preserves* `[:prompt_caching]`. That hazard cannot fire in this card's real shape. The one that
  can is the `base:` choice above.
- **The per-turn decision must reach the Journal.** (A1's panel.) `Agent#render_request` now
  delegates a per-turn choice to a collaborator that reports nothing back, so the only trace is
  what the source journals itself. On a bench whose deliverable is comparability, an unrecorded
  decision is a missing measurement — A8 must confirm it lands on the live path.
- **Build a `SummarySnapshot` with `.take`, never `.new(summaries:)`.** A4's panel proved a
  message-digest-shaped key passes the validator and yields a permanent, total, silent miss with
  `hits`/`misses` both reporting `0` — indistinguishable from "never taken". `.take` is correct by
  construction; the only sanctioned `.new` is the no-arg pure-elision default.
- **Nothing loaded before `lain.rb:71` may hash at load time.** (A4, discovered the hard way.)
  `Canonical.digest` reaches into the Rust extension, required at `lain.rb:71`, while `compaction`
  loads at `:24` — so a class-body constant computed from `Canonical.digest` fails at *library
  load* with `NameError: uninitialized constant Lain::Ext`. Memoize on first use instead. A6 and
  A8 both live in that window.
- **Pass `head.messages`, never the `Head` itself, to `Need#check` and `Scheduler`.** Measured by
  A5 after its fix round: `Need#check(messages: head)` **raises `Canonical::UnsupportedType`** —
  `Head` is not dumpable. Separately, `Scheduler#accounting` re-slices whatever `messages:` it is
  given, so handing it `head.messages` journals `tokens_after` for a head-*of-the-head* (measured
  6 → 3). A6 must hand `Need` the messages and give `Scheduler` the full candidate set it expects,
  and must have a spec pinning the journalled `tokens_after` against a hand-computed figure.
- **An empty `Head` measures 2, not 0** (`Canonical.dump([])` is `"[]"`), after the A5 fix round.
  Ask emptiness with `#empty?`, never `bytesize.zero?`.
- **Thread `head.bytesize` into `Scheduler#pipeline(history_size:)`; do not re-derive it.**
  (A5's panel, 2026-07-25.) As wired today `Head` *adds* a per-turn `Canonical.dump` rather
  than removing one: `Need::TokenThreshold` re-dumps `state.messages` (`need.rb:51`) and
  `Scheduler#accounting` dumps twice more. A6 must pass the head it already built — both its
  `messages` and its `bytesize` — and must not compute a fresh dump for `history_size:`.
  Changing `Need` to take a `Head` is out of scope for this chunk; record it as a follow-up.
- **Wire `Context::Compact` with `ProtectedPatterns::NONE`** and comment why. Ruled 2026-07-25 —
  see Open decisions. `Compaction::Head` measures the candidate span and is protected-agnostic,
  so under any non-`NONE` policy `Need` would measure a head larger than `Compact` removes. Do
  not pass a non-`NONE` policy in this card; if a spec seems to need one, STOP.

### A8 — Assemble it in Backend and default it on          [wave 4] [risk: medium]

**Depends on:** A6, A7
**Files:** `lib/lain/cli/backend.rb`, `exe/lain`, `spec/lain/cli/backend_spec.rb`,
`spec/lain/cli/wiring_spec.rb`
**Reuse:** `Backend#context`/`#slots`/`#spawn_policy` (`backend.rb:73,83,96`) as the sibling
factory idiom and `#slots`' memoization (`:83-85`); `Backend#provider`'s option-reading shape
(`:60`); `exe/lain:138-175` for the existing `chat` flag block.
**Shared-file wiring:** orchestrator applies two one-line diffs to `lib/lain/cli/wiring.rb` —
`pipeline_source: backend.pipeline_source` in the `Agent.new` call (`:195-202`), and passing
`backend.eager` as the `ToolRunner` observer A7 introduced. **Both must reference the one `Eager`
instance Backend owns.**

Backend gains the factories, memoized; `exe/lain chat` gains the flags. Compaction is **on by
default** — a plain `lain chat` compacts, with eager summaries when available and elision when
not.

**Acceptance criteria:**

```gherkin
Scenario: compaction is on by default
  Given chat options with no compaction flags
  When the backend's pipeline source is built
  Then it is a live compaction source, not the Null

Scenario: it can be turned off
  Given chat options carrying --no-compact
  When the backend's pipeline source is built
  Then it is the Null source and a rendered Request is byte-identical to an unwired one

Scenario: a summary fired this session is the one that renders
  Given a wired chat whose tool dispatch has fired a summary for a large result
  When that result is later dropped by compaction
  Then the rendered summary is the fired text, not an elision line

Scenario: an unsupported provider still starts
  Given chat options selecting ollama with a model in no window table
  When the backend's pipeline source is built
  Then it is built against the fallback window and chat starts

Scenario: thresholds are overridable
  Given chat options overriding the compaction byte threshold
  When the pipeline source is built
  Then it schedules against the overridden threshold

Scenario: the source is built once per run
  Given a backend whose pipeline source is requested twice
  Then the same instance is returned both times
```
→ spec files: `spec/lain/cli/backend_spec.rb`, `spec/lain/cli/wiring_spec.rb`

**Escalation triggers:**
- **The source must join the `CLI::JournalTee` sink list** (A6, 2026-07-25). `context_for`'s
  `usage:` is A2's Integer, but `Cold#observe` needs a `TurnUsage`'s cache-read field, and there is
  no route to it from the render seam — so A6's response leg is a `#<<` sink. If A8 does not add
  the source to the tee, **`Cold` is never fed and the `:cold` decision path is dead on the live
  path**: it degrades gracefully (forced compaction still fires) but `cache_state` would only ever
  read `forced`, which would quietly make one of the bench's comparison arms meaningless.
- `CLI::Wiring` is at **107 of 110** `ClassLength`. If the orchestrator's two injected lines trip
  the cop, extract a collaborator — Joel's one grant is spent.
- `exe/lain`'s `LainCLI` has hit `ClassLength` saturation twice (forcing the `LiveViews` and
  run-path-into-`Wiring` extractions). If the new flags trip it, extract rather than bump.
- `Backend#context` returns a **fresh** Context per call at six sites. If `#pipeline_source` or
  `#eager` is likewise rebuilt per call, `Cold`'s accumulated warmth and the Eager's fired
  summaries reset silently every time. AC6 pins this; memoize as `#slots` is memoized.
- The default eager tier is a local model. If ollama is absent the fire is a graceful no-op
  (`eager.rb:65-79`) and summaries degrade to elision — intended. If the card finds itself adding
  a hard dependency on a running ollama, STOP.
- Subagents deliberately get `PipelineSource::Null` (see Open decisions). If wiring a child source
  seems necessary to make a spec pass, STOP — that is the follow-up chunk, not this card.

### B1 — Journal the live secret-write guard          [wave 1] [risk: low]

**Depends on:** none
**Files:** `spec/lain/cli/wiring_spec.rb`
**Reuse:** the three mounts that already pass a journal — `consolidation.rb:127`,
`improve.rb:190`, `bench/cli/run_recorder.rb:66`; `Telemetry::WriteRefused`; `Chronicle`'s
journal accessor (`chronicle.rb:124-129`).
**Shared-file wiring:** orchestrator changes `wiring.rb:208` to pass `journal:` into
`RefuseSecretWrites.new`.

Live refusals journal to `Channel::Null` — a credential-shaped write is refused and leaves no
record, while every other mount of this middleware journals.

**Acceptance criteria:**

```gherkin
Scenario: a live refusal is recorded
  Given a wired chat whose journal is capturing
  When a memory_write carrying a credential-shaped body is refused
  Then a WriteRefused record naming the matched pattern is on the journal

Scenario: journaling off still refuses
  Given a wired chat started with --no-journal
  When a memory_write carrying a credential-shaped body is dispatched
  Then it is still refused and nothing raises
```
→ spec file: `spec/lain/cli/wiring_spec.rb`

**Escalation triggers:**
- `chronicle.telemetry_kwargs` is `{}` when journaling is off (`chronicle.rb:124-129`), so there
  may be no journal object to pass. Confirm `Chronicle` exposes a journal-or-Null before wiring;
  if it does not, STOP rather than inventing an accessor. AC2 is what forces the question.

### B2 — Separate an oracle's decline from a pattern match          [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/middleware/refuse_secret_writes.rb`,
`spec/lain/middleware/refuse_secret_writes_spec.rb`
**Reuse:** `PATTERNS` and `ORACLE_MATCH` (`refuse_secret_writes.rb:49-58`); the refusal path at
`:86-94,121-126`; `CLAUDE.md`'s `Tool::Input` note that validations check *shape, not safety* —
the same confusion is the defect here.
**Shared-file wiring:** none

A regex hit means "this looks like a credential." An oracle decline means "this is not worth
remembering." Today both journal through one refusal path and the oracle's verdict is recorded as
a security finding. Give them distinct, honest reasons in the record and in the message the model
sees.

**Acceptance criteria:**

```gherkin
Scenario: a pattern hit is recorded as a pattern hit
  Given a body matching a known credential pattern
  When the write is refused
  Then the journaled reason names that pattern

Scenario: an oracle decline is recorded as a decline, not a pattern
  Given a body matching no pattern and an oracle that declines it
  When the write is refused
  Then the journaled reason is distinguishable from every pattern name

Scenario: the model is told which happened
  Given the two refusals above
  Then their result messages differ, and neither describes a decline as a credential
```
→ spec file: `spec/lain/middleware/refuse_secret_writes_spec.rb`

**Escalation triggers:**
- `Guards::WriteRefused` requires `pattern` to be **non-nil** (`telemetry.rb:76-79`, enforced at
  `:366`). A decline must therefore still carry *some* value in that field — a nil is a hard
  raise, not a graceful absence. Decide the vocabulary before editing.
- `spec/lain/middleware/refuse_secret_writes_spec.rb:157-182` asserts
  `journal.events.first.pattern == ORACLE_MATCH` verbatim. This card changes that grammar
  deliberately — update the example, do not delete it.
- If the honest fix needs a second record *type* rather than a second reason value, STOP: adding
  a `Telemetry` type touches a file other cards may be in.

### B3 — Recalibrate the memory-save heuristic          [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/oracle/memory_save.rb`, `spec/lain/oracle/memory_save_spec.rb`
**Reuse:** `OPAQUE_TOKEN` (`memory_save.rb:50`) and `.heuristic` (`:56-62`); the module's
hot-path constraint at `:8-17`.
**Shared-file wiring:** none

`%r{\A[A-Za-z0-9+/=_.-]{24,}\z}` refuses any unbroken 24+-character body — git SHAs, UUIDs,
tracking numbers, base64. That over-refusal is what blocked live wiring.

**Acceptance criteria:**

```gherkin
Scenario: a git SHA is worth saving
  Given a body that is a 40-character hex commit SHA
  When the heuristic scores it
  Then it is worth saving

Scenario: a UUID is worth saving
  Given a body that is a canonical UUID
  When the heuristic scores it
  Then it is worth saving

Scenario: an empty body is still not worth saving
  Given a body that is blank or whitespace
  When the heuristic scores it
  Then it is not worth saving

Scenario: the heuristic does not claim to detect secrets
  Given a body shaped like an API key
  When the heuristic scores it
  Then whatever it answers, the credential is still refused by pattern, not by this oracle
```
→ spec file: `spec/lain/oracle/memory_save_spec.rb`

**Escalation triggers:**
- The spec currently pins a 40-character opaque blob as **not** worth saving, and it is green.
  This card inverts that example on purpose. Invert it explicitly — do not delete it — and if
  inverting it makes any *other* green spec fail, STOP: something depends on the over-refusal.
- The module forbids a model tier on this path (`memory_save.rb:8-17`). If recalibration seems to
  need a model, STOP.

### B4 — Wire the memory-save gate into the live guard          [wave 2] [risk: medium]

**Depends on:** B2, B3
**Files:** `spec/lain/cli/wiring_spec.rb`
**Reuse:** `Oracle::MemorySave::Gate` (`memory_save.rb:67-85`); the injection already proven by
`spec/lain/middleware/refuse_secret_writes_spec.rb:157-182`.
**Shared-file wiring:** orchestrator adds `oracle: Oracle::MemorySave::Gate.new` to the
`RefuseSecretWrites.new` call at `wiring.rb:208`, which by then carries B1's `journal:`.

**Acceptance criteria:**

```gherkin
Scenario: a legitimate opaque identifier now saves
  Given a wired chat
  When a memory_write whose body is a git commit SHA is dispatched
  Then it is not refused

Scenario: a credential is still refused, by pattern
  Given a wired chat
  When a memory_write carrying an API-key-shaped body is dispatched
  Then it is refused and the journaled reason names the pattern, not the oracle

Scenario: a contentless body is declined, by the oracle
  Given a wired chat
  When a memory_write with a blank body is dispatched
  Then it is refused and the journaled reason is the oracle's decline
```
→ spec file: `spec/lain/cli/wiring_spec.rb`

**Escalation triggers:**
- If B2's new vocabulary and B3's new calibration disagree — the gate declining something B3
  decided is worth saving — STOP. That is a contradiction between two wave-1 cards for the
  orchestrator to reconcile, not this card.

### C1 — Resolve tool paths against the worker cwd          [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/tools/list_files.rb`, `lib/lain/tools/ast_search.rb`,
`lib/lain/tools/code_outline.rb`, `lib/lain/tools/file_symbols.rb`,
`spec/lain/tools/list_files_spec.rb`, `spec/lain/tools/ast_search_spec.rb`,
`spec/lain/tools/code_outline_spec.rb`, `spec/lain/tools/file_symbols_spec.rb`
**Reuse:** `WorkerEnv#resolve` (`worker_env.rb:49-51`) — the one shared rule; the
`session_of(invocation)` accessor pattern from `bash.rb:88-101` and `core_exec.rb:77-78`; the
inline form the five correct file tools use (`read_file.rb:44`, `grep.rb:75-77`, `glob.rb:49`).
**Shared-file wiring:** none

Four tools resolve `input.path` against the process CWD while five siblings honor the worker's.
Under a worktree-isolated worker that is a silent wrong-directory read.

**Acceptance criteria:**

```gherkin
Scenario: a relative path lands under the worker cwd
  Given a Session whose worker_env cwd is a directory other than the process cwd
  When each of the four tools is invoked with a relative path
  Then each reads from under the worker cwd

Scenario: an absolute path is honored as given
  Given the same Session
  When each tool is invoked with an absolute path
  Then each reads that exact path

Scenario: the default worker env resolves to the process cwd
  Given a Session with the default WorkerEnv
  When each tool is invoked with a relative path
  Then each returns the same entries as that path read from the process cwd
```
→ spec files: the four named above

**Escalation triggers:**
- `ast_search.rb:213` stamps the raw `input.path` into its "no matches … under X" message, and
  the search uses it as a file-label prefix. Resolving changes user-visible output. Decide
  whether the message shows the given or the resolved path and pin it — do not let it drift.
- `list_files.rb:27-29` carries a comment asserting it "touches no Session". That becomes false;
  move the comment with the code rather than leaving a lie behind.
- All four tools are currently in `TRUE_TOOLS` in
  `spec/lain/tools/parallel_safety_spec.rb:45-47`. If reaching for the Session changes a tool's
  parallel-safety answer, STOP — that tripwire exists to catch exactly this.

### C2 — Journal causal_parents on turn records          [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/session_record.rb`, `lib/lain/bench/session.rb`,
`lib/lain/bench/session/chain_fold.rb`, `spec/lain/session_record_spec.rb`,
`spec/lain/bench/session_spec.rb`, `spec/lain/bench/session/chain_fold_spec.rb`
**Reuse:** `Telemetry::Message` (`telemetry.rb:527`) — the one record type already carrying
`causal_parents`, and the precedent for how they serialize; `Event#causal_parents`
(`event.rb:37-38,170-172`, normalized/sorted/frozen); `Timeline#commit`'s `causal_parents:`
parameter (`timeline.rb:61-70`); `Bench::Session::Scribe#turn_record` (`bench/session.rb:228-231`),
the byte-compatible twin.
**Shared-file wiring:** none

`SessionRecord.turn` emits six keys and drops the causal edge, so no journal-shaped grader can
reach `Timeline#causal_meets`'s multi-ancestor case — `Grader::FrustrationRepair` documents the
consequence in code (`frustration_repair.rb:37-47`). **Writer and reader must move together:**
`causal_parents` is part of the content address, and `ChainFold` rebuilds turns without it
(`chain_fold.rb:55-57`) then verifies the digest and raises `Corrupt` (`:60-69`). Adding the
field to the writer alone converts a latent bug into a live one.

**Acceptance criteria:**

```gherkin
Scenario: a causal edge survives the round trip
  Given a turn committed with two causal parents
  When it is journaled and then folded back by the reader
  Then the rebuilt turn carries both parent digests
  And its digest matches the journaled digest

Scenario: a turn with no causal parents is unchanged
  Given a turn committed with no causal parents
  When it is journaled
  Then the record is byte-identical to what it was before this change

Scenario: an older journal still loads
  Given a recorded journal whose turn records predate this field
  When the session is folded
  Then it folds without raising and the turns carry no causal parents

Scenario: the bench scribe stays in lockstep
  Given the same turn written by both scribes
  Then both records carry the same keys
```
→ spec files: `spec/lain/session_record_spec.rb`, `spec/lain/bench/session_spec.rb`,
`spec/lain/bench/session/chain_fold_spec.rb`

**Escalation triggers:**
- `ChainFold#verified_turn` (`chain_fold.rb:60-69`) is the integrity guarantee. If making AC1
  pass seems to require relaxing that verification, STOP — the check is the point, and the fix
  belongs in what the reader feeds `commit`, never in what it accepts.
- All 13 committed `.ndjson` fixtures carry zero `causal_parents`, so AC3 is the compatibility
  path and must be proven against a real committed fixture, not a synthetic one.
- If any *newly recorded* fixture would carry non-empty `causal_parents`, STOP — regenerating
  recorded digests is a separate decision with its own review.

## Integration checks

After the last wave, on `main`:

- `bundle exec rspec` — full suite green (baseline re-measured 2026-07-25 at `fddc8e3`:
  **4086 examples / 0 failures / 2 pending** — one more than the plan's recorded 4085, absorbed;
  the 2 pending are the `:desktop` dunstify test and the known `up_spec.rb:174` real-tmux timing
  flake, which passes in isolation).
- `bundle exec rubocop` — clean at default metrics, **no `Metrics/*` limit raised**. Confirm
  `Metrics/ClassLength` is still `Max: 110` and that `CLI::Wiring`, `Agent`, `Context`, and
  `exe/lain`'s `LainCLI` are all under it.
- `cargo test && cargo clippy --all-targets -- -D warnings && cargo deny check` — regression gate.
- `bundle exec rspec --tag core` — the `:core` daemon specs.
- `pre-commit run --all-files`.
- **Shareability gate:** a spec that drives one full compacting turn end to end and asserts no
  `Ractor::IsolationError`. The executed probe in Grounding shows this is the failure mode a
  card-local spec would miss.
- **Byte-identity regression:** render a Request from a recorded fixture session with
  `--no-compact` and confirm it is byte-identical to the pre-chunk render — the pin that the new
  seam is inert when disabled, independent of the defaults question.

## Follow-up tickets out of this chunk

Raised during execution (implementers and review panels), each deliberately out of its card's
scope. Ordered by the plan's own judgement of risk.

1. **Subagents get `PipelineSource::Null`** — the known sharp edge, already recorded in Open
   decisions. A research subagent grinding tool results is the most likely thing to blow a
   window. Needs a per-child source design (whose window? whose idle clock?).
2. **`Bench::Session::Loader` needs a one-pass fold over `turn` + `message` together.**
   `Loader#recording` evaluates `timeline:` before `messages:` because a message's causal parents
   can name a turn; now that a turn can name a message, no single-pass ordering satisfies both.
   C2's panel proved messages-first fails the other way (`AskHuman#ask` writes Q citing a *turn*),
   so this is a real ticket, not a nicety. **Correction — this is NOT latent, and an earlier note
   here wrongly said it was.** The mailbox is not the only writer of a turn's causal edge:
   `Agent#step` (`agent.rb:310`) takes them from `ToolRunner#delivery`'s `answered_questions`,
   harvested from `Tools::AskHuman`, which `CLI::Wiring` puts in the **live** toolset
   (`wiring.rb:132`). C2 ships a `Store::MissingObject` → named `Corrupt` translation in
   `ChainFold` so `CLI::Resume#rebuild` keeps returning a clean `Refusal`, but the underlying
   ordering fix is still owed.
3. **One path-resolution object for the tool layer** (C1's panel). `File.expand_path` is at 10
   sites across 9 tools plus two `WorkerEnv#resolve` callers — eleven statements of one rule in
   two idioms. A `ResolvedPath = Data.define(:locator, :display)` or `Tool#resolve_path` collapses
   that and `ast_search`'s new `(path, display)` parameter clump. Same ticket: `worker_env.rb`'s
   "the ONE cwd-resolution rule both exec arms share" comment is now inaccurate, and decide
   whether `WorkerEnv` must require an absolute `cwd`.
4. **One family-token resolution book** (A3's panel). `ContextWindow` duplicates `PriceBook`'s
   exact-then-longest-token algorithm verbatim; a third book will copy it again. The duplication
   was mandated by A3's card so the two could not disagree — the parity probe proved they do not
   today, but nothing keeps them in step.
5. **Let `Need` take a `Compaction::Head`** (A5's panel). `Need::TokenThreshold` re-dumps
   `state.messages` and `Scheduler#accounting` dumps twice more, so `Head` currently *adds* a
   per-turn `Canonical.dump` rather than removing one. Threading the head through would remove
   the redundant passes on the hot path.
6. **Rename the `RefuseSecretWrites` oracle duck** (B2's implementer). The injected duck is
   `#secret?`, but `Oracle::MemorySave::Gate` answers "not worth remembering" by it. `#withhold?`
   is the honest name; renaming touches B3's file, so it was documented rather than done.
7. **`Eager#fire` should consume the digest on completion, not before spawn** (A7's panel).
   Because `@fired << digest` precedes the spawn, any reaped fire — a last turn's, or one killed
   by the reactor close after an interrupt — leaves the digest **permanently spent**, so identical
   content re-read later in that session can never be summarized. A7 routes around it by mounting
   post-dispatch; the ordering itself is still wrong.
8. **`Summarizing::Observer#observe` reads String wire keys** (`block["content"]`/`block["is_error"]`),
   so a Symbol-keyed caller silently no-ops rather than failing loudly — against CLAUDE.md's
   loud-failure premise. Unreachable today (`effect.input` is JSON-parsed), nothing pins it.
9. **The memory-save contentlessness floor covers only one of two `GUARDED_TOOLS`** (B3's panel).
   `improvement_write`'s `note` is wholly unjudged, and `Gate::JUDGED_FIELD` is a bare String with
   nothing pinning that `effect.input` is String-keyed.
10. **`Bench::Session.header_record` vs `SessionRecord.header` are a hand-maintained twin with no
    key-parity pin** (C2's panel), diverging on `provider`/`resumed_from` — the same species of
    drift C2 repaired one method below.
11. **The live secret-write guard is not `Ractor.shareable?` once an oracle is wired.** B4's panel
    flagged it and the orchestrator diagnosed it: `RefuseSecretWrites.new` alone is shareable
    `true`; with `oracle: Gate.new` it is `false`. The blocker is **not** the Gate — freezing that
    is insufficient — it is `Oracle::Heuristic`, which is unfrozen and holds a non-shareable
    `@predicate` Proc. A shallow `freeze` on `Gate` was written and then **reverted**, because it
    would not have achieved shareability while carrying a comment claiming it did. The real fix
    belongs in `Oracle::Heuristic` and must not deep-freeze a `Recorded` replay tier's cursor.
    Nothing breaks today (no middleware shareability spec), but this chunk's A-band works under a
    live shareability constraint, so it is worth closing deliberately.
12. **`guard_kwargs` is a kwargs bag, not the collaborator `CLI::Wiring` actually needs**
    (B4's panel). It bought two `ClassLength` lines; the real extraction — the guard's whole
    construction as one named object — is still owed, and `Wiring` sits at 108/110.
13. **`/model` and the compaction Source are calibrated at different times** (A8's panel — the
    highest-value open item). `Need`'s `window_tokens` is fixed from `--model` when the Source is
    built, but the Context is live. Start on haiku (200 k), `/model` to opus (1 M): 190 k used
    tokens still fires `:approaching_window` and **forces a cache-destroying rewrite the model in
    force does not need**. The reverse under-fires, with the byte threshold as backstop. Same
    family as the `Ractor::IsolationError` A8 fixed — the Context is live, the Source is a
    snapshot. Real fix: derive the window per turn from the live model, which means a per-turn
    `Need` (it takes `window_tokens:` at construction today).
14. **The compaction cost record is fabricable across a `/model` switch** (A8's panel). A run
    started on opus and switched to `qwen3:4b` journals `cost_saved 0.275925 / cost_spent
    0.0847125` for a turn that ran **free**; started local and switched to opus journals
    `0.0 / 0.0`. Exactly the lie `price_book.rb:48-50` refuses. A8 puts the priced-against model on
    the record so the mismatch is *visible*; making it *correct* needs ticket 13.
15. **`CLI::ToolGuard` is the extraction only halfway done** (A8's panel), superseding the earlier
    `#guard_kwargs` ticket: a `module_function` namespace over two functions still returning the
    same kwargs bag, with `.kwargs` as public surface no outside caller needs.
16. **`CLI::Wiring` is at 109 of 110** — one line left — and a deferring turn now costs
    ~1.47 ms / 2 132 objects on **every** turn of every chat. Follow-up 5 (`Need` takes a `Head`)
    is the structural fix; `Scheduler.new` demanding the `Compact` at construction while
    `#evaluate` never reads it is the other ~1.2 ms (A6).
17. **A `/compact` command** — already recorded in Open decisions. `Need::Manual` ships wired but
   dead without one.

**Manual passes owed to Joel** (named so they do not silently drop):

1. A real dogfood chat with compaction on by default, long enough to cross the threshold —
   confirm the summary that lands is an eager model summary, **not** an elision line, and read
   the journaled `Telemetry::Compaction` records.
2. The same with ollama **stopped** — graceful degradation to elision, no raise, no stall.
3. A **resumed** session (`--resume`) that crosses the threshold — confirm the first turn does
   not force-compact and that summaries for pre-resume history elide rather than erroring.
4. `--no-compact` for one session, confirming the harness behaves as it did pre-chunk.
5. A `memory_write` of a git SHA and of a real-looking credential in a live chat — the first
   saves, the second is refused *and journaled* with the pattern reason.
6. One `lain chat` from inside a worktree-isolated worker, confirming `list_files`/`ast_search`/
   `code_outline`/`file_symbols` read from the worker's checkout, not the launch directory.
