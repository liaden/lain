# POC integration fixes: the cockpit wedge, the compaction tiers, the arm bench, and a spec prune

status: in-progress
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman · Aaron Patterson

## Intent

The 2026-08-15 manual integration POC drove lain end to end on a local ollama arm through the
nvim/tmux cockpit for the first time. Every part had specs; the seams between them did not.
Eleven defects surfaced, and — the recurring theme — **every one of them is green in the suite
today**, because each seam is tested with a double on at least one side.

This chunk fixes all eleven on the production path, writes the specs that would have caught
them (each exercising the real construction site, not an injected collaborator), and prunes the
vacuous and dead specs the grounding pass turned up. A user of `lain up` on a local model should
finish this chunk able to: type a `@role[/skill]` line and answer the question it raises; open a
survey of a subdirectory and mark it reviewed; run `lain bench arms` and get non-zero scores;
and see an honest context-occupancy number.

Findings memo: `/tmp/lain-poc/FINDINGS.md` (session journals under
`~/.local/state/lain/sessions/15087239bad2/`).

## Grounding

Verified 2026-08-15 against working tree `ef57db6` by six parallel Explore passes plus the live
POC run. **Six of the POC memo's claims were wrong and the code won.** Recorded here because
`/execute-plan` must not re-derive them:

| Memo claimed | Code says |
|---|---|
| The 8192 window drove every Act 3 compaction (`token_threshold`) | `Need::TokenThreshold` (`compaction/need.rb:57-65`) fires on **`head_bytes`**, not tokens. The window signal is `Need::ApproachingWindow` (`need.rb:82-94`, ratio 0.9). At 8192×0.9=7373 vs measured peak 7079, it **never fired**. The denominator bug is real but misreported the HUD, it did not trigger compaction. |
| The free summarizer tier is never wired | It **is** wired: `backend.rb:409-410` builds `RoutedSummarizer` with `Catalog.load`, reached via `backend.rb:249-260`. The gate is `Handler::Summarizing::Observer#summarize` (`effect/handler/summarizing.rb:79-83`): `content.bytesize > @threshold_bytes`, `DEFAULT_THRESHOLD_BYTES = 4096`. POC tool results were all smaller, so nothing ever fired. |
| Survey Defect B is a zero-hunk problem | Not zero hunks — **nobody asks**. `ChangesetDiff#open` reaches `changeset.rb:125` `return [] if file.old_path.nil?` (true for every corpus file, `corpus.rb:316`) and never calls `LazyFile#hunks`, the only thing that flips `chunked?` (`lazy_file.rb:136,150`). |
| Survey Defect A strips a path prefix | It is **never attached**. `walk.rb:289` mints a survey-root-relative `path` beside the correct `absolute`, `corpus.rb:170` keeps only `path`, `changeset_diff.rb:127` sends it on a wire documented repo-relative, and `47_diff.lua:66-68` re-anchors at the editor's global cwd. |
| `strict_tools` broke the summarizing strategy | Ollama's encoder never consults `strict_tools` (`ollama/encoding.rb:153-158`). The real cause: `Oracle::Model#request_for` (`oracle/model.rb:63-66`) sends **no `extra:` at all**, so no `format` field — even though `Provider::Ollama::CAPABILITIES` declares `structured_output` (`ollama.rb:79`). |
| `docs/providers/ollama.md` claims 6.5× | It says **"3x decode and 8x prefill"** (`:92`). The 6.5× prefill figure is `DEBUGGING_OLLAMA.md:107`, for `qwen3-coder:30b` specifically (340→2222 tok/s). The POC measured prefill at 1201→1578 tok/s (1.31×) — same axis, very different baseline. Both are on this box; **the discrepancy is unexplained and T17 must not silently pick a winner.** |

Root causes pinned (all verified, with line numbers on the cards):

- **The wedge.** `HumanReplies#surfaces` (`human_replies.rb:272`) spawns `answer_loop`, and has
  **exactly one caller**: `Repl#respond` (`repl.rb:281`). A human-typed `@role[/skill]` line and
  `/meta` both reach `RoleSpawn#call` from `Repl#dispatch` (`repl.rb:174` → `middleware_turn`
  `:247` → `SkillDispatch#report_role_bound` `skill_dispatch.rb:80-83`), i.e. **outside
  `respond`**. The question lands on the `Async::Queue` (`wiring.rb:176`) with nobody dequeuing;
  `AskHuman#perform`'s `awaited(pending)` (`ask_human.rb:520-524`) parks the REPL's own fiber, so
  stdin is never read again. `ApprovalSurfaces#watch` (`repl/approval_surfaces.rb:79-84`) has the
  identical single-caller shape — a gated tool inside a skill spawn wedges the same way.
- **The dangle.** `Scribe#catch_up` (`session_record/scribe.rb:168-181,252-254`) walks only the
  main render chain, so **subagent turns are never journaled at all**, while the child's
  `ask_human` Q is journaled immediately (`ask_human.rb:531`, `causal_parents: [child_head]`).
  Guaranteed dangle. `MessageReplay` deliberately lets `Store::MissingObject` escape
  (`bench/session/message_replay.rb:13-15,48-56`) and `Resume#fork` (`cli/resume.rb:101-114`)
  rescues only `Corrupt`/`ENOENT`, so the user sees the raw store error.
- **`capability_degraded`.** The record (`telemetry/turn_stream.rb:281-287`) and emitter
  (`capability/policy.rb:86-92`) both exist; `Capability::Policy.for` has **zero call sites in
  `lib/`, `exe/`, `bin/`**. Zero records is the current wiring's correct output.
- **Arms score 0.** `exe/lain:463` declares `--system` with no default; `SpawnSeam#initialize`
  (`bench/spawn_seam.rb:72-76`) defaults `system: nil` → project chat slots, which never mention
  the `FILE …/END` contract the grader parses (`arm_sweep/recordings.rb:175`). Also
  `toolset: Toolset.new([])` by default and nothing on the arms path overrides it.
- **DualLedger.** `dual_ledger.rb:97` `until control.settled?`, `:113` `settled: grader.grade(...).pass?`,
  `DEFAULT_MAX_STEPS = 6` (`:24`). No `settled:`/termination seam exists. `SingleThread` (`:55`)
  and `OrchestratorWorker` (`:71`) grade once, at the end.

## Orchestrator contract (plan-specific only)

- **Shared files (orchestrator-owned, wiring diffs only):** `lib/lain.rb`, `lain.gemspec`,
  `.rubocop.yml`, `spec/spec_helper.rb`, `spec/support/**`, and **`exe/lain`** — several cards need
  a new `method_option`; each hands back a one-line diff rather than editing the file.
- **`lib/lain/cli/backend.rb` is a coordination point, not orchestrator-owned.** Five cards touch
  it. At most **one card per wave** may list it under **Files**; the waves below enforce that.
- Deviation: T16, T17 and T18 are spec-only / docs-only. Run the panel on them at low depth.
- The POC memo `/tmp/lain-poc/FINDINGS.md` is **not** repo state and must not be treated as
  ground truth where this Grounding section contradicts it.

### Specs are evidence, not authority

**Most of this suite was written by LLM sessions.** A spec asserting X is evidence that somebody
once wanted X; it is *not* proof that X was reasoned about, and a confident-sounding comment above
it is not provenance. This chunk exists because eleven real defects sat behind a green suite.

So when a card's escalation trigger names a spec that will fail, apply this test before deferring
to it:

- **Treat as authority** when the assertion traces to a real observation outside the spec — a
  documented trap in CLAUDE.md, a measurement, a named upstream bug, a commit whose message
  explains the reason, or a comment citing a specific incident (e.g.
  `role_prelude_wiring_spec.rb:148-149` records an actual Anthropic 4-`cache_control` 400).
- **Treat as re-derivable** when the assertion is self-referential — a number that is just
  arithmetic over the spec's own mock (`total_tokens == 72`), a constant echoed back
  (`eq(described_class::TIER)`), or a comment that explains *what* the code does rather than *why*
  it must. Fix these to match the intended behaviour and say so in the commit; do not escalate.

When a trigger says "stop and confirm", it means the *behaviour* is in question, not that the
spec is sacred. If applying this test changes what a card should do, that is the card working as
intended — record the call in the commit message.

### Every card must prove its red phase

Most ACs in this plan are **guards** — they describe behaviour that is already correct and must
stay correct ("an explicit `--system` still wins", "a fully capable provider records nothing",
"a project-root survey is unchanged"). They are green today by construction. That is fine and
deliberate, but it means *"all my scenarios pass"* is not evidence a fix landed.

So, per card, before writing any implementation: **run the new ACs and record which ones fail.**
At least one must fail for the right reason. A card whose entire AC set is green against unmodified
`main` has not pinned its defect — stop and say so rather than implementing against it. Scenarios
marked `[pin]` in this plan are the ones expected to be red first; the rest are guards.

This is the discipline the whole chunk exists to restore: eleven real defects sat behind a green
suite, and every one of them would have been caught by asking "would this test fail if the code
were wrong?"

## Open decisions

None gate a card. Four things are deliberately *out* of scope or unwired, recorded so they are not
mistaken for oversights:

0. **T16, T17 and T18 build no production capability** — a spec prune, a docs pass, and a
   test-suite guard respectively. Their "Reachable from" is deferred by nature, not by omission.
   T18's production path is the default suite, where it runs on every `rake pspec`.

1. **`/env` does not exist and `/status` is terse** (POC §Act 1). Cosmetic; no card. If wanted,
   file separately against the command registry.
2. **`bench arms` supplies arms no tools** (`Toolset.new([])`). T7 fixes the *grading* contract
   by teaching the format, deliberately **not** by giving arms tools — tool-using arms are a
   different experiment and would change what every recorded arm number means.

## Waves

```
Wave 1: T1, T2, T3, T4, T6, T7, T8, T9, T12, T14, T18
Wave 2: T5 (←T4), T13, T15 (←T14), T16 (←T18)
Wave 3: T11 (←T12)
Wave 4: T10 (←T9), T17 (←T7, T8, T11)
Critical path: T12 → T11 → T17
```

T18 precedes T16 deliberately: the mechanical guard produces the candidate list the prune works
from, so the prune is driven by a repeatable check rather than by one exploration pass's sample.

**Some waves are set by file contention, not by dependencies.** T11 depends only on T12 (wave 1)
but sits in wave 3, and T10 depends only on T9 (wave 1) but sits in wave 4, because
`lib/lain/cli/backend.rb` and `spec/lain/cli/backend_spec.rb` are each touched by three cards and
the contract allows one per wave. If the orchestrator lands waves faster than this implies, the
constraint to preserve is **one backend-touching card at a time**, not the wave numbers.

Verified mechanically: the DAG is acyclic, every dependency sits in a strictly earlier wave, every
wave-1 card has no dependencies, and no two same-wave cards list a common path.
`lib/lain/cli/backend.rb` → T12 (w1), T11 (w3), T10 (w4). `spec/lain/cli/backend_spec.rb` →
T5 (w2), T11 (w3), T10 (w4).

**Cross-wave file sharing is a real merge hazard here, not a formality.** Agent worktrees fork
`origin/main`, so a later-wave agent may branch before an earlier wave has landed. Three spec files
are edited by cards in different waves — `spec/lain/arm/dual_ledger_spec.rb` (T8 w1, T16 w2),
`spec/lain/bench/spawn_seam_spec.rb` (T7 w1, T16 w2), `spec/lain/context_window_spec.rb` (T16 w2,
T10 w4). T16's prune of the first two is **handed to T7 and T8 instead** (see T16), on the
principle that the agent rewriting a file is the one who knows what in it is dead. The
`context_window_spec.rb` overlap remains and is a hard merge gate for T10.

---

## Tasks

### T1 — Serve human questions and approvals raised outside `Repl#respond`   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/cli/repl.rb`, `lib/lain/cli/repl/conversation_scope.rb`,
`spec/lain/cli/repl_spec.rb`, `spec/lain/seams/skill_spawn_inbox_spec.rb` (new)
**Reuse:** `Lain::CLI::HumanReplies#surfaces` (`human_replies.rb:272`), `#session_surfaces` (`:302`),
`Lain::CLI::Repl::ApprovalSurfaces#watch` (`repl/approval_surfaces.rb:79-84`),
`Lain::CLI::Repl::ConversationScope#open` (`conversation_scope.rb:32-36`)
**Shared-file wiring:** none
**Reachable from:** `Repl#converse` → `Repl#dispatch` (`repl.rb:174`) — the same frame a
human-typed `@role[/skill]` line and `/meta` run in. The AC drives a real `Repl` over
`Provider::Mock`, not an `instance_double(HumanReplies)`.

The wedge. A question or approval raised while a command/skill invocation is being dispatched must
be served, because the dispatching fiber is the one that parks.

**Widen the bracket to `Repl#dispatch`. Do NOT hoist it to `ConversationScope`.** An earlier draft
of this card preferred the conversation scope; that is wrong, and the code says why.
`HumanReplies#surfaces` documents its fiber as one that "must live exactly as long as the ask and
no longer — the reply read parks inside it, and the terminal it reads from is the one the next
`you>` prompt needs back". A conversation-scoped `answer_loop` would leave a fiber parked on stdin
competing with every `you>` read — a second wedge, not a fix. `#session_surfaces` is
conversation-scoped precisely because the **editor** rail polls a socket and never touches the
terminal; that split is deliberate and must survive.

`Repl#dispatch` (`repl.rb:173-180`) is the correct frame: it encloses both the command-registry
path and `middleware_turn` → `respond`, which is exactly the set of frames a question can now be
raised from, and it ends before the next prompt read.

**Acceptance criteria:**

```gherkin
Scenario: a question from a human-typed skill spawn is answerable
  Given a chat whose read-only role subagent calls ask_human
  When the human types "@researcher[/critique] describe this file"
  Then the chat prints the arrival note and a "human> " prompt
  And an answer typed at that prompt resolves the subagent's question
  And the REPL returns to the "you> " prompt afterwards

Scenario: a gated tool inside a skill spawn still reaches the approval surface
  Given a chat at accept_edits posture whose spawned subagent calls a tier-3 tool
  When the human types a role-bound skill invocation that triggers it
  Then the approval is offered and a granted approval lets the tool run

Scenario: a question raised during an ordinary turn still works
  Given a chat whose agent calls ask_human mid-turn
  When the turn runs
  Then the arrival note and "human> " prompt appear exactly once
```
→ spec file: `spec/lain/seams/skill_spawn_inbox_spec.rb` (`:seam`), plus a regression example in
`spec/lain/cli/repl_spec.rb`

**Escalation triggers:**
- `human_replies.rb:229-235` documents `answer_loop`'s fiber as living "only DURING a respond()
  call" and names `/inbox` as the manual second watcher. Widening to `dispatch` keeps that
  contract's *intent* (the fiber dies before the next prompt read) while changing its extent. If
  `spec/lain/cli/human_replies_spec.rb:255-410` (`#drain_at_prompt`) breaks in a way that suggests
  the intent is the extent, stop and confirm — this is the one place in this card where an
  existing spec may carry real reasoning rather than LLM output.
- `#session_surfaces`'s docstring records a measurement (2026-08-05: the editor rail answering
  nothing for 8s at an idle prompt). That is the design record for why the two rails have
  different lifetimes; extend it, do not contradict it.
- If two surfaces end up live at once for the same question (one from the scope, one from
  `respond`) and the arrival note prints twice, stop — double-serving a question is worse than
  the wedge and needs a design call, not a guard.
- `Conductor#supervise` (`conductor.rb:240-259`) routes SIGINT to `Signals::NULL` outside its
  window; if recovering Ctrl-C requires widening that, escalate — it is a separate concern.

---

### T2 — Journal subagent turns so their causal parents resolve   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/session_record/scribe.rb`, `lib/lain/tools/subagent.rb`,
`spec/lain/session_record/scribe_spec.rb` (new — `Scribe` has no mirrored spec today; its
behaviour is pinned indirectly in `spec/lain/session_record_spec.rb`),
`spec/lain/session_record_spec.rb`, `spec/lain/tools/subagent_spec.rb`
**Reuse:** `Scribe#catch_up` (`scribe.rb:168-181`), `#turns_above_append_point` (`:252-254`),
`Subagent::ChildBuilder#spawn_agent` (`subagent.rb:576-584`), `Subagent::Lineage#message`
(`tools/subagent/lineage.rb:64-71`), `Middleware::JournalTurns` (`middleware/journal_turns.rb:28-32`)
**Shared-file wiring:** none
**Reachable from:** `Tools::Subagent::ChildBuilder#build` (`subagent.rb:617-626`) — the real spawn
path used by both the `subagent` tool and `Skill::RoleSpawn`. The AC runs a real child over
`Provider::Mock` and reads the journal file.

A child's `ask_human` question and its `"final"` lineage edge both cite child-timeline digests
(`ask_human.rb:531`, `lineage.rb:64-71`) that no `turn` record carries, because `Scribe` walks only
the main render chain. Every such session is unforkable. Journal the child's turns so the edges
resolve. Note the `Loader#recording` ordering constraint (`bench/session/loader.rb:67-77`): turns
must land before the messages that cite them.

**Acceptance criteria:**

```gherkin
Scenario: a spawned subagent's turns reach the journal
  Given a chat that spawns a subagent which completes a turn
  When the session is written
  Then the journal contains turn records for the child's turns
  And every message record's causal_parents names a digest the journal carries

Scenario: a session containing a subagent question can be forked
  Given a recorded session whose subagent asked the human a question
  When that session is forked at its head digest
  Then the fork succeeds and no Store::MissingObject is raised

Scenario: the main render chain is unchanged
  Given a chat with no subagents
  When the session is written
  Then the journal holds exactly the render-chain turns, in ancestor order
  And ChainFold's walk sees no child turns
```
→ spec file: `spec/lain/session_record/scribe_spec.rb`, `spec/lain/tools/subagent_spec.rb`

**Escalation triggers:**
- `scribe.rb:12-14` states as doctrine that "a Timeline walk sees ONLY render-chain turns". If
  journalling child turns means a child turn can be mistaken for a render-chain turn by
  `ChainFold` or `Timeline#ancestors`, STOP — the fix must not corrupt resume of the parent.
- `spec/lain/bench/session/chain_fold_spec.rb:85-110` pins that a *turn* citing an unlanded
  causal parent becomes `Corrupt`. If your change makes that spec's fixture unreachable, confirm
  before editing it.
- If the child's turns would double-count in `Ledger`/usage accounting (they ride
  `@seam.journal`, `subagent.rb:576-584`), stop — cost accounting changing silently is worse
  than the dangle.

---

### T3 — Refuse a fork over a dangling causal edge with a legible error   [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/resume.rb`, `spec/lain/cli/resume_spec.rb`
**Reuse:** `Bench::Session::Corrupt`, `Store::MissingObject` (`store.rb:88-97`),
`Resume#fork`'s existing rescue (`cli/resume.rb:101-114`) **and its `#fork_refusal` formatter** at
the same site, which already produces the house-style refusal — do not hand-roll a message
**Shared-file wiring:** none
**Reachable from:** `exe/lain chat --fork` → `CLI::Resume#fork` — the AC drives the real command
with a hand-built journal carrying a dangling `message`.

Defence in depth alongside T2: even once child turns are journaled, a session truncated by a
crash can still cite an unwritten digest. Today the user sees the raw
`no object "blake3:..." in store: putting "blake3:..." would dangle`. Turn it into a refusal that
names the session and says what to do.

**Acceptance criteria:**

```gherkin
Scenario: forking a session whose last message dangles
  Given a recorded session whose final message record cites an unjournaled digest
  When the operator forks that session
  Then the command refuses with a message naming the session and the missing digest
  And the process exits non-zero without a backtrace
```
→ spec file: `spec/lain/cli/resume_spec.rb`

**Escalation triggers:**
- `bench/session/message_replay.rb:13-15` says deliberately that causal edges are "the Store's
  own job (a dangling one raises `Store::MissingObject`, not a `Corrupt` this class
  manufactures)". Rescue at `Resume#fork`, **not** by making `MessageReplay` manufacture a
  `Corrupt` — if that seems necessary, escalate rather than reversing a documented decision.
- Per CLAUDE.md, a Thor refusal is `exit(1)` and RSpec does not rescue `SystemExit`: pass
  `debug: true` to any `.start` in the spec and assert the example COUNT.

---

### T4 — Consult the free summarizer tier regardless of result size   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/oracle/routed_summarizer.rb`, `lib/lain/effect/handler/summarizing.rb`,
`spec/lain/oracle/routed_summarizer_spec.rb`, `spec/lain/oracle/eager_spec.rb` (holds the existing
threshold group at `:200-300`; `Handler::Summarizing` has no mirrored spec of its own),
`spec/lain/seams/free_summarizer_spec.rb` (new)
**Reuse:** `Handler::Summarizing::Observer#summarize` (`effect/handler/summarizing.rb:79-83`),
`DEFAULT_THRESHOLD_BYTES` (`:32`), `Oracle::RoutedSummarizer#custom` (`routed_summarizer.rb:77-87`),
`Summarizer::Catalog#for` (`summarizer.rb:44`)
**Shared-file wiring:** none
**Reachable from:** `Backend#tool_observer` (`cli/backend.rb:249-251`) → `ToolRunner#observe_all`
(`agent/tool_runner.rb:147`). The seam AC writes a real `.lain/summarizers.rb`, builds the tier
through `Backend`, runs a real tool result through it, and asserts the declared summarizer's text
reaches the rendered prompt — the chain nothing currently tests end to end.

The 4096-byte gate exists to protect a *model* call. A declared summarizer costs no tokens and no
latency, so gating it behind the model tier's cost threshold is what made the POC's free tier
dead. Consult the catalog for any result; keep the threshold for the model fallthrough.

**Move the size gate down, into `RoutedSummarizer` — do not merely lower it in the Observer.**
The layer is decided here, not in the worktree, because the obvious edit does not work: the
`Observer` holds only `@eager` and `@threshold_bytes`, and the catalog lives a layer below inside
the oracle. Lowering `DEFAULT_THRESHOLD_BYTES` alone would make **every** small tool result fall
through `RoutedSummarizer#custom` (nil on a catalog miss, `routed_summarizer.rb:77-87`) straight
into `@inner.ask` — a model call per `bash` result, which fails this card's second AC. The size
gate is a **cost** policy and `RoutedSummarizer` is the object that knows which tier pays: consult
the catalog unconditionally, and apply the threshold only on the fallthrough to the model tier.
The alternative — injecting a catalog into the `Observer` — needs `cli/backend.rb`, which T12 holds
in this wave.

**Acceptance criteria:**

```gherkin
Scenario: a declared summarizer compacts a small tool result
  Given a project with a .lain/summarizers.rb declaring a summarizer for bash results
  And a bash tool result of 200 bytes that the declaration says it handles
  When the result is observed and the history is compacted
  Then the compacted render contains the declaration's text
  And no oracle_answer record is journaled for that span

Scenario: an unhandled small result still falls through without a model call
  Given the same project and a result the declaration refuses
  When the result is observed
  Then no model summarization is fired for it
```
→ spec file: `spec/lain/seams/free_summarizer_spec.rb` (`:seam`)

**Escalation triggers:**
- `summarizer.rb:26-33` documents that `Catalog#for` **raises whatever user code raises**. If
  removing the size gate exposes every tool result to a user predicate, confirm the failure
  posture: `RoutedSummarizer#compacted` rescues (`routed_summarizer.rb:103-108`) but the
  Observer path may not.
- If dropping the gate measurably slows the turn loop (the catalog is consulted per result now),
  stop and report the number rather than reinstating a threshold silently.
- `spec/lain/oracle/eager_spec.rb:200-300` pins the threshold behaviour with a `pending_oracle`
  double. Those examples must be rewritten to distinguish the free tier from the model tier, not
  deleted.

---

### T5 — Route the span-collapse summarizer through the free tier   [wave 2] [risk: medium]

**Depends on:** T4
**Files:** `lib/lain/cli/backend/span_summarizer.rb`,
`spec/lain/cli/backend/span_summarizer_spec.rb` (new — the mirrored path this subject lacks),
`spec/lain/cli/backend_spec.rb`
**Reuse:** `Oracle::RoutedSummarizer` (`oracle/routed_summarizer.rb`), `Backend#summary_oracle`
(`cli/backend.rb:408-411`) as the nesting exemplar, `Oracle::Recorded::Journaling`
**Shared-file wiring:** none
**Reachable from:** `CLI::CompactionStrategy` (`cli/compaction_strategy.rb:196-199`) →
`Backend::SpanSummarizer#oracle` — reached by `--compact-strategy=summarizing`. The AC asserts the
constructed nesting from `Backend`, not from a hand-built oracle.

`span_summarizer.rb:88-91` builds a bare `Oracle::Model`, so `--compact-strategy=summarizing`
never consults `.lain/summarizers.rb` — the one strategy a user would expect it to help most.
Wrap it the way `summary_oracle` does: `RoutedSummarizer` outermost over `Journaling(Model)`, so a
free answer is never journaled as a model call and a fallthrough is journaled exactly once.

**Acceptance criteria:**

```gherkin
Scenario: a declared summarizer answers a span collapse
  Given a project declaring a summarizer suitable for the span's source
  When a compaction runs under --compact-strategy=summarizing
  Then the span collapses using the declaration
  And no oracle_answer record is journaled for it

Scenario: an unsuitable span still reaches the model tier and is journaled once
  Given a project whose declaration refuses the span
  When the same compaction runs
  Then exactly one oracle_answer record is journaled for it
```
→ spec file: `spec/lain/cli/backend/span_summarizer_spec.rb` (new coverage),
`spec/lain/cli/backend_spec.rb` (the existing nesting pin)

**Escalation triggers:**
- `spec/lain/cli/backend_spec.rb:560-565` asserts the strategy's oracle `be_a(Oracle::Recorded::Journaling)`
  — it pins the current two-layer nesting and **will fail**. Update it to the three-layer
  assertion; do not delete it.
- `routed_summarizer.rb:83` returns nil for a source with no `tool_name`. A span source may be
  bare text, in which case the free tier can never match here — if so, STOP and report: the fix
  may need a `Summarizer::Result` at the span boundary, which is a bigger change than this card.
- `compaction/source/derived.rb:104` (`@strategy || Held.new(snapshot)`) means the eager snapshot
  is discarded under any explicit strategy. If T4's work appears to double-collapse, escalate.

---

### T6 — Ask ollama for structured output when an oracle needs JSON   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/oracle/model.rb`, `spec/lain/oracle/model_spec.rb`,
`spec/lain/provider/ollama/encoding_spec.rb`
**Reuse:** `Provider::Ollama::Encoding::STRUCTURED_OUTPUT_KEY` (`ollama/encoding.rb:48`, handled
`:92-95`), `Provider::Ollama::CAPABILITIES` (`ollama.rb:79`, declares `structured_output`),
`Provider#supports?` (`provider.rb:46-48`), `Oracle::Definition#render`
**Shared-file wiring:** none
**Reachable from:** `Backend::Summarizer#oracle` (`cli/backend/summarizer.rb:42-43`) and
`Backend::SpanSummarizer` (`span_summarizer.rb:89-90`) — both construct `Oracle::Model`. The AC
asserts the encoded request body carries the format field on the ollama path.

`Oracle::Model#request_for` (`oracle/model.rb:63-66`) sends no `extra:`, so nothing ever requests
grammar-constrained decoding — which is why qwen3-coder answered the summarizer with markdown and
raised `UndecodableAnswer`, leaving every span uncollapsed. Ollama already declares
`structured_output` and the encoder already knows the key; the oracle just never asks.

**Acceptance criteria:**

```gherkin
Scenario: an oracle asks a structured-output-capable provider for JSON
  Given a summarizer oracle over a provider declaring structured_output
  When it builds its request
  Then the encoded body carries the provider's structured-output field

Scenario: a provider without the capability is asked plainly
  Given the same oracle over a provider that does not declare structured_output
  When it builds its request
  Then the body carries no structured-output field and the oracle still parses a JSON reply
```
→ spec file: `spec/lain/oracle/model_spec.rb`

**Escalation triggers:**
- `Provider::Anthropic::CAPABILITIES` (`anthropic.rb:48`) does **not** include `structured_output`.
  If threading `extra:` changes the Anthropic-path request bytes at all, STOP — prompt-cache
  stability is a `Canonical` invariant (CLAUDE.md), and a changed prefix breaks caching.
- If `UndecodableAnswer` still fires against a real ollama model with the format field set,
  report it rather than adding a JSON-repair fallback; a repair layer is its own card.
- `spec/lain/provider/ollama/encoding_spec.rb:36-40` passes `extra:` with **Symbol** keys while
  `SAMPLER_KEYS` is Strings (`encoding.rb:32`) — the setup does not mean what it reads as. Fix
  that premise while here.

---

### T7 — Teach `bench arms` the FILE/END contract by default   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/bench/arm_sweep/recordings.rb` (the default prompt lives beside the parser it
must satisfy), `lib/lain/bench/spawn_seam.rb`, `lib/lain/bench/cli.rb`,
`spec/lain/bench/spawn_seam_spec.rb`, `spec/lain/bench/arms_report_spec.rb`
**Reuse:** `ArmSweep::Recordings::FileBlocks::BLOCK` (`bench/arm_sweep/recordings.rb:175`) — the
parser the default prompt must satisfy; `Backend#context(system_override:)` (`cli/backend.rb:201-203`)
**Shared-file wiring:** none (the `--system` flag already exists at `exe/lain:463`; this card adds
the *default*, not the flag)
**Reachable from:** `exe/lain bench arms` → `Bench::CLI#arms_report` (`bench/cli.rb:164-171`) →
`SpawnSeam.new`. The AC asserts the rendered system prompt an arm actually receives when
`--system` is unset — not an injected one.

Without `--system` every arm scores exactly 0.000 on the live path, because the grader parses
`FILE <path>\n…\nEND` out of assistant text and nothing tells the model that contract. The
offline sweep hides it: `spec/fixtures/bench/arm_sweep/recordings.yml:29-52` is hand-authored to
satisfy the parser. Ship a default arms system prompt; an explicit `--system` still overrides it.

Define the default prompt **beside the parser it must satisfy**, so the contract has one home.

**Acceptance criteria:**

```gherkin
Scenario: arms are taught the trajectory format by default
  Given a bench arms run with no --system flag
  When an arm's request is rendered
  Then its system prompt instructs the FILE <path> / END block format

Scenario: an explicit --system still wins
  Given a bench arms run with --system "be terse"
  When an arm's request is rendered
  Then its system prompt is "be terse"

Scenario: a model answering in the taught format grades non-zero
  Given a mock provider answering in the default prompt's format
  When the arms report is produced
  Then at least one arm scores above zero
```
→ spec file: `spec/lain/bench/spawn_seam_spec.rb`, `spec/lain/bench/arms_report_spec.rb`

**Escalation triggers:**
- `spec/lain/bench/arms_report_spec.rb:21-23` hand-writes the `FILE…END` answer and `:97-99`
  asserts `1.000`/`0.000` off it — the vacuous pair this defect hid behind. **Leave that example
  alone and ADD a new one** asserting the rendered system prompt carries the contract: `:97-99` is
  the only per-task-gold-dispatch coverage there is, and it will still pass after this card (the
  mock answers the same regardless of system prompt), so rewriting it in place would trade real
  coverage for a duplicate of the new example.
- `spec/lain/bench/spawn_seam_spec.rb:200-204` covers only the `system:`-given case and stays
  green either way. Extend it with the unset case; if it starts failing, something else changed.
- Changing the default prompt changes every future live arm number. If the prompt's wording
  materially shifts scores in a way that would make past `bench record` fixtures incomparable,
  say so — recorded-run comparability is a methodology question for the owner.

---

### T8 — Let the ledger, not the grader, settle DualLedger's outer loop   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/arm/dual_ledger.rb`, `spec/lain/arm/dual_ledger_spec.rb`
**Reuse:** `DualLedger::DEFAULT_PROGRESS` (`arm/dual_ledger.rb:215-219`) — the ledger-based signal
that should decide settling; `Loop#advance` (`:149-152`), `Loop#stalled?` (`:158`),
`DEFAULT_MAX_STEPS` (`:24`), `Arm::SingleThread#run` (`single_thread.rb:55`) as the
grade-once-at-the-end exemplar
**Shared-file wiring:** none
**Reachable from:** `Bench::LiveArms.build` (`bench/live_arms.rb:58-66`), which constructs
`DualLedger` with all defaults. The AC drives the arm through `Arm::Driver` with a grader that
never passes and asserts the step count.

`dual_ledger.rb:113` reads the **scoring function** as a control signal — oracle leakage its
controls do not get, so cross-arm score comparisons are confounded by protocol rather than
strategy. It also costs 18× the controls' tokens on an ungradeable task (measured: 2546 vs
141/162). Settle from the ledger's own progress reading; keep `max_steps` as the bound; grade
once at the end for the `Run`, as the other two arms do.

**This is a methodology change and it is intended.** Arm numbers recorded before and after are
not comparable — say so in the commit message, and see T17.

**Acceptance criteria:**

```gherkin
Scenario: the outer loop settles without consulting the grader
  Given a dual-ledger arm and a grader that never passes
  When the arm runs a task on which the ledger stops advancing
  Then the loop terminates before max_steps
  And the grader is asked exactly once, for the Run's grade

Scenario: an ungradeable task no longer costs six model calls
  Given a grader that never passes and a model that repeats itself
  When the arm runs
  Then the provider is asked fewer times than max_steps

Scenario: a stall still fires a journaled replan
  Given a model repeating identical output
  When the arm runs
  Then the run's journal carries the stall and replan transitions
```
→ spec file: `spec/lain/arm/dual_ledger_spec.rb`

**Escalation triggers:**
- `spec/lain/arm/dual_ledger_spec.rb:62-70` pins one step and `total_tokens == 72`; `:80-85` pins
  `elapsed == 0.25`; `:189-197` pairs it with SingleThread. These are **re-derivable** by the test
  in the Orchestrator contract — 72 is arithmetic over the spec's own mock and 0.25 is its own
  injected clock tick. Update the numbers to whatever the ledger-settled arm actually does; no
  escalation needed. Escalate only if the arm stops terminating on a *healthy* task, which is a
  behaviour question, not a spec one.
- `spec/lain/bench/arm_sweep_spec.rb:117-121` asserts the report discloses that single-thread and
  dual-ledger produce identical rows (`bench/arm_sweep/report.rb:44-47`). That disclosure is only
  true because the replayed grader settles after one step. If the tie breaks, the NOTE text and
  that assertion both need revisiting — escalate before rewriting the disclosure prose.
- `DEFAULT_PROGRESS`'s own comment (`:205-213`) calls it "deliberately crude" and says it "cannot
  tell real work from a reworded non-answer". If settling on it makes a healthy run stop early,
  that is a real design problem — report it, do not tune the heuristic silently.

---

### T9 — Give Provider a context-window surface, implemented for ollama   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/provider.rb`, `lib/lain/provider/ollama.rb`,
`lib/lain/provider/ollama/transport.rb`, `spec/lain/provider/ollama_spec.rb`,
`spec/lain/provider_spec.rb`
**Reuse:** `Provider`'s abstract surface (`provider.rb:29-85`) and its `require!`/`supports?`
idiom; `Ollama::Transport::COMPLETION_PATH` (`ollama/transport.rb:22`) as the pattern for a second
endpoint; `ContextWindow::DEFAULTS` (`context_window.rb:46-56`) for the fallback shape
**Shared-file wiring:** none
**Reachable from:** nothing yet — **T10 constructs it on the real path.** This card ships the
surface and the ollama implementation with its own specs; T10 wires it. Recorded here rather than
merged because T10 also edits `lib/lain/cli/backend.rb`, which is a per-wave coordination point.

Add a provider method answering "how many tokens can this model take **here**", nil when it cannot
say.

**The trained window and the served window are different numbers, and returning the wrong one is
worse than today's bug.** `/api/show` reports `model_info.<arch>.context_length` — the model's
*trained* maximum (262,144 for `qwen3-coder:30b`). The *served* window is
`min(trained, OLLAMA_CONTEXT_LENGTH, per-request num_ctx)`; this box serves 32,768
(`DEBUGGING_OLLAMA.md:43`). No ollama endpoint reports the served figure directly.

Return the trained number and T10 divides by 262,144: occupancy under-reports **8×**, compaction
never fires, and nothing errors. `context_window.rb:74-77` already states this asymmetry —
"an over-estimated fallback would instead mean compaction never fires for the provider it exists
to protect, which is worse than the crash it replaces". **Under-estimate when unsure; never
over-estimate.**

Resolution order for the ollama implementation: the server's configured cap if it is discoverable,
else `min(trained context_length, CONSERVATIVE_FALLBACK-safe ceiling)`, else nil. If the cap is not
discoverable over the API, answering **nil** is correct and honest — T10's `--num-ctx` override
(T11) is then the operator's lever, and the conservative fallback stands.

`references/ollama/` carries `api-chat.md` and `openai-compat.md` but **no `/api/show` reference**;
capture what you learn there so the next reader is not guessing.

**Acceptance criteria:**

```gherkin
Scenario: a trained window larger than the server's cap answers the cap   [pin]
  Given a model trained to 262144 tokens served by a server capped at 32768
  When the provider is asked for that model's window
  Then it answers 32768, never 262144

Scenario: a cap the API does not expose answers nil rather than the trained window   [pin]
  Given a server that reports a trained context length but no configured cap
  When the provider is asked for that model's window
  Then it answers nil, so the conservative fallback stands

Scenario: an unreachable or silent server does not raise
  Given an ollama server that errors or omits the field
  When the provider is asked for the window
  Then it answers nil rather than raising

Scenario: a provider with no window knowledge answers nil
  Given the abstract Provider surface
  When a provider that does not implement it is asked
  Then it answers nil
```
→ spec file: `spec/lain/provider/ollama_spec.rb`, `spec/lain/provider_spec.rb`

**Escalation triggers:**
- `ollama/transport.rb:22` currently exposes exactly one endpoint. Reuse `Transport`'s existing
  Faraday stack, retry and error mapping (`#connection`) — do not build a second Faraday. If adding
  an endpoint means the transport can no longer be constructed without a live server in unit specs,
  stop — the seam must stay offline-testable.
- **If you cannot determine the served cap from the API, say so and answer nil.** Do not substitute
  the trained `context_length` because it is the number that is available. An over-estimate
  disables compaction silently, which is the failure `context_window.rb:74-77` explicitly ranks as
  worse than the one this card fixes.
- A blocking HTTP call at session start is a latency cost on every `lain chat`. If the lookup
  cannot be made lazy or cheap, report the measured cost before wiring it in T10.
- `spec/lain/provider/ollama_spec.rb:28-38` asserts `capabilities` by exact equality. Do not add a
  capability symbol for this; it is a query method, not a capability.

---

### T10 — Wire the provider-reported window into occupancy and compaction   [wave 4] [risk: medium]

**Depends on:** T9
**Files:** `lib/lain/cli/backend.rb`, `lib/lain/cli/chat_launch.rb`,
`lib/lain/frontend/prompt_composer.rb`, `lib/lain/agent.rb`,
`spec/lain/cli/backend_spec.rb`, `spec/lain/cli/chat_launch_spec.rb`,
`spec/lain/status_feed_spec.rb`, `spec/lain/context_window_spec.rb`, `spec/lain/agent_spec.rb`
**Reuse:** `ContextWindow.new(windows:, fallback:)` (`context_window.rb:237` builds `DEFAULT` this
way) — the documented seam at `context_window.rb:74-77` says a deployment knowing its real local
window "should construct its own book with an explicit `fallback:`"; injection points already
exist at `status_feed.rb:249`, `compaction/source.rb:154`, `agent.rb:247`
**Shared-file wiring:** none
**Reachable from:** `CLI::ChatLaunch` (`chat_launch.rb:46`) constructs the `StatusFeed` with no
`context_window:` today, and `Backend` builds `Compaction::Source` (`backend.rb:355-357`). Both
must be handed a book built from T9's answer. The AC asserts the occupancy a real chat publishes.

The POC measured `occupancy × 8192` reproducing real `input_tokens` exactly — the numerator is
right and only the denominator is wrong, reporting 86.4% at 2.7% of real capacity. Build the book
from the provider's answer, falling back to `DEFAULTS`/`CONSERVATIVE_FALLBACK` unchanged when the
provider says nothing.

**Three construction sites, not two — the third is the one a human actually reads.**
`Frontend::PromptComposer#occupancy` (`prompt_composer.rb:390-391`) calls `@agent.occupancy` with
**no keyword**, and `Agent#occupancy(context_window: ContextWindow.default)` (`agent.rb:247`)
defaults per call. That is the `ctx:` figure in the REPL prompt line. Wiring only `ChatLaunch` and
`Backend` fixes `state.json` and leaves the prompt dividing by 8192 — a half-fixed number is worse
than a uniformly wrong one, because the two surfaces would then disagree. Move `Agent`'s book to
constructor injection, or thread it at the composer's call site; either way, name it in the commit.

**`--num-ctx` (T11) outranks the provider's answer.** Once an operator sets it, the served window
*is* that value. Resolution order: `--num-ctx` if set, then the provider's answer, then `DEFAULTS`,
then `CONSERVATIVE_FALLBACK`.

Also add the denominator to the record: `CompactionDecision`
(`compaction/source.rb:64-67`) carries no `window_tokens`/`used_tokens`, so a journal reader cannot
see which window fired `approaching_window`.

**Acceptance criteria:**

```gherkin
Scenario: occupancy is measured against the served window
  Given an ollama provider reporting a 32768-token window for the chat's model
  When a turn uses 7079 input tokens
  Then the published occupancy is 7079 divided by 32768

Scenario: a silent provider keeps the conservative fallback
  Given a provider that reports no window
  When the same turn runs
  Then the published occupancy is measured against the conservative fallback

Scenario: a compaction decision records the window it was judged against
  Given a chat that reaches a compaction decision
  When the decision is journaled
  Then the record names the window and used tokens behind it

Scenario: the launcher itself builds the provider-derived book   [pin]
  Given a chat launched through the real ChatLaunch on an ollama provider reporting 32768
  When the status feed and the compaction source are constructed
  Then both measure against 32768 without the spec injecting a book

Scenario: the prompt line agrees with the published state   [pin]
  Given the same launched chat after a turn
  Then the ctx figure in the REPL prompt equals the occupancy published to .lain/state.json

Scenario: an explicit --num-ctx outranks the provider   [pin]
  Given a chat started with --num-ctx 16384 against a provider reporting 32768
  When occupancy is measured
  Then it is measured against 16384
```
→ spec file: `spec/lain/cli/chat_launch_spec.rb` (the construction pins),
`spec/lain/cli/backend_spec.rb`, `spec/lain/status_feed_spec.rb`

**Escalation triggers:**
- Four specs pin the 8192 fallback and **must be updated, not deleted**:
  `spec/lain/context_window_spec.rb:136-141` (asserts `ratio == 0.5`),
  `spec/lain/agent_spec.rb:447-456` (naked `0.5`),
  `spec/lain/status_feed_spec.rb:450-457` (asserts `be > 1.0`, which fails outright at 32768),
  `spec/lain/cli/backend_spec.rb:485-500` (its comment at `:488-490` says explicitly that "only
  the fallback makes the signal fire here"). If any cannot be expressed against a provider-supplied
  window, escalate rather than weakening the assertion to a tautology.
- The comments at `spec/lain/cli/up_spec.rb:802-806` and `spec/plugin/tmux_plugin_spec.rb:93-95`
  explain the 8192 fallback and go stale; the examples themselves feed a literal ratio and still
  pass. Fix the prose, keep the tests.
- If wiring the book requires the provider before the `StatusFeed` exists (a construction-order
  cycle at `chat_launch.rb:46`), STOP and report the ordering rather than making the feed
  lazily reach for a global.
- `spec/lain/cli/chat_launch_spec.rb` stubs `status_feed_factory:` with a fixed-arity lambda
  (`lambda { |run_clock:| … }`). Changing that factory's arity breaks it — expected, and it is the
  spec that proves the wiring happened. If it does **not** break, you wired the book somewhere
  other than the construction site and the capability is still dormant.
- **If your change breaks none of the four specs named above, stop and re-check.** All four build
  `ContextWindow.default` directly and are untouched by a wiring-only change; a green suite after
  this card is evidence the book never reached production, not evidence of success.

---

### T11 — Send `num_batch` and `num_ctx` on the ollama sampler path   [wave 3] [risk: medium]

**Depends on:** T12
**Files:** `lib/lain/cli/backend.rb`, `lib/lain/provider/ollama/encoding.rb`,
`spec/lain/cli/backend_spec.rb`, `spec/lain/provider/ollama/encoding_spec.rb`
**Reuse:** `Ollama::Encoding::SAMPLER_KEYS` (`ollama/encoding.rb:32`) and `#encode_options`
(`:160-164`) — strictly opt-in, so an absent key is never emitted; `Backend#sampler_extra`
(`cli/backend.rb:416-421`), which today emits only temperature and seed
**Shared-file wiring:** two `method_option` lines in `exe/lain` beside `ModelFlags.sampling`
(`exe/lain:608-617`): `--num-batch` and `--num-ctx`. Required — `spec/lain/cli/chat_flags_spec.rb:143-149`
statically parses `lib/` with Prism and fails on any `@options[:key]` read whose key is not a
declared chat flag.
**Reachable from:** `Backend#sampler_extra` → `Context#extra` → `Ollama::Encoding#optional_fields`
(`ollama/encoding.rb:67-71`). The AC asserts the encoded request body from a real `Backend`.

`num_ctx` is already in `SAMPLER_KEYS` but nothing ever puts it in `extra` — a dead branch.
`num_batch` is absent entirely, so every request inherits ollama's `-b 512`. Measured on this box:
1201/1194 tok/s prefill at the default vs 1578/1562 with `num_batch: 2048` — **1.31×, replicated**.

**Acceptance criteria:**

```gherkin
Scenario: an operator-set batch size reaches the request
  Given a chat on the ollama provider started with a batch size
  When a request is encoded
  Then the request options carry that batch size

Scenario: unset sampler knobs emit no options key at all
  Given a chat on the ollama provider with no sampler flags
  When a request is encoded
  Then the request carries no options key

Scenario: num_ctx reaches the request when set
  Given a chat on the ollama provider started with a context length
  When a request is encoded
  Then the request options carry that context length
```
→ spec file: `spec/lain/provider/ollama/encoding_spec.rb`, `spec/lain/cli/backend_spec.rb`

**Escalation triggers:**
- `spec/lain/cli/backend_spec.rb:817-819` asserts `payload[:options]` by **exact equality**
  (`eq(temperature: 0)`) and **will break** if `num_batch` is defaulted on rather than
  operator-set. Decide the layer deliberately: this card threads it via `sampler_extra` from a
  flag, so an unset flag must leave the options hash untouched.
- `spec/lain/provider/ollama_spec.rb:152-155` asserts no `:options` key when no knobs are given —
  the guard for the above. If it fails, you defaulted the value inside the encoder; move it.
- `spec/lain/cli/chat_flags_spec.rb:68-71` has a `DYNAMIC` pin whose message names "the
  `%i[temperature seed]` sampler pair". The assertion compares paths only so it stays green, but
  the prose is now wrong — update it.

---

### T12 — Default the summarizer model to the chat's when both tiers share a provider   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/cli/backend.rb`, `spec/lain/cli/backend_spec.rb`,
`spec/lain/cli/chat_flags_spec.rb`
**Reuse:** `Backend#summarizer_model` (`cli/backend.rb:169-172`) — the single line both consumers
go through; `#provider_name` (`:312`), `#model` (`:335`), `#summarizer_name` (`:314`)
**Shared-file wiring:** one doc-string edit in `exe/lain:708-710`, whose desc currently says
"defaults to the summarizer provider's own default, **never the chat's --model**"
**Reachable from:** `Backend::Summarizer#oracle` (`cli/backend/summarizer.rb:42-43`) and
`Backend::SpanSummarizer` (`span_summarizer.rb:89-90`) — both read `summarizer_model`. The AC
resolves it from a real `Backend` built from flags.

On one GPU an unpinned summarizer falls to `qwen3:4b` and evicts the resident chat model on every
compaction: **84.0s vs 7.5s, an 11× penalty**, measured. When both tiers name the *same provider*,
the chat's model is the right default. Cross-provider behaviour is unchanged and deliberate.

**Acceptance criteria:**

```gherkin
Scenario: same provider on both tiers inherits the chat's model
  Given a chat with --provider ollama --model qwen3-coder:30b and no --summarizer-model
  When the summarizer model resolves
  Then it is qwen3-coder:30b

Scenario: a different summarizer provider keeps its own default
  Given a chat with --provider ollama and --summarizer-provider anthropic
  When the summarizer model resolves
  Then it is the anthropic provider's default model

Scenario: an explicit --summarizer-model always wins
  Given a chat with --provider ollama and an explicit --summarizer-model
  When the summarizer model resolves
  Then it is the model the operator named
```
→ spec file: `spec/lain/cli/backend_spec.rb`, `spec/lain/cli/chat_flags_spec.rb`

**Escalation triggers:**
- `spec/lain/cli/chat_flags_spec.rb:272-276` is titled `"never lets the chat's --model name the
  summarizer's"` and asserts exactly the behaviour this card reverses. **Rewrite it** to keep the
  cross-provider half of its intent; deleting it drops that guard.
- `spec/lain/cli/backend_spec.rb:662-672` ("points the summarizer at a paid provider while the
  chat model stays local") is the cross-provider guard that must keep passing untouched. If it
  breaks, the rule is too broad — escalate.
- `chat_flags_spec.rb:265-270`'s ollama assertion passes coincidentally under the new rule (unset
  `--model` makes both the same). Do not let that coincidence stand in for coverage.

---

### T13 — Emit `capability_degraded` when a provider lacks a required capability   [wave 2] [risk: high]

**Depends on:** none
**Files:** `lib/lain/cli/wiring.rb`, `spec/lain/cli/wiring_spec.rb`,
`spec/lain/seams/capability_degraded_spec.rb` (new)
**Reuse:** `Capability::Policy.for` / `Policy::Degrade#handle_missing` (`capability/policy.rb:58,86-92`)
— the emitter that already exists; `Telemetry::CapabilityDegraded` (`telemetry/turn_stream.rb:281-287`);
`Context#requires` (`context.rb:53-63`), `Provider#supports?` (`provider.rb:46-48`);
`Bench::Session::Loader`'s `DegradedSet` fold (`bench/session/loader.rb:207-211`), which already
consumes the record
**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring` on the real chat construction path. Everything downstream is
built and tested; only the call is missing. The AC runs a real ollama-provider chat and reads the
journal.

**Wire `:degrade`, and only `:degrade`.** `Capability::Policy.for` takes `:strict` or `:degrade`.
Under `:strict`, `Policy::Strict#handle_missing` calls `provider.require!` and raises
`Provider::Unsupported` — and `Context::REQUIRES` derives `[:prompt_caching]` from
`CacheBreakpoints#requires` (`context/cache_breakpoints.rb:83-84`), which ollama does not declare
(`ollama.rb:79`). **Wiring `:strict` would kill every ollama chat at turn one.** There is no
`--capability` flag in `exe/lain` today and this card does not add one; `:degrade` is the wired
constant, and a flag is a later decision.

`Capability::Policy.for` has **zero call sites in `lib/`, `exe/`, `bin/`** — the record type, the
emitter, and the reader all exist and nothing ever constructs the policy. That is why 12 POC
journals carried zero records while `CacheBreakpoints` required `prompt_caching`
(`context/cache_breakpoints.rb:83-84`) from a provider that does not offer it
(`ollama.rb:79`). `Compare` refuses to compare runs with differing degraded sets
(`compare.rb:12`), so the gap silently makes incomparable runs look comparable.

**Acceptance criteria:**

```gherkin
Scenario: a chat on a provider lacking prompt_caching records the degradation
  Given a chat on the ollama provider whose context requires prompt_caching
  When the session runs a turn
  Then the journal carries a capability_degraded record naming prompt_caching and the provider

Scenario: a fully capable provider records nothing
  Given a chat on a provider supporting every capability its context requires
  When the session runs a turn
  Then the journal carries no capability_degraded record

Scenario: a degraded capability never aborts the chat   [pin]
  Given a chat on the ollama provider, whose context requires prompt_caching
  When the session runs a turn
  Then the turn completes normally and no Provider::Unsupported is raised
```
→ spec file: `spec/lain/seams/capability_degraded_spec.rb` (`:seam`)

**Escalation triggers:**
- Emitting one record per turn instead of once per session would flood the journal. If the
  natural call site fires per turn, stop and confirm the intended cardinality.
- `Compare` refuses to compare runs with differing degraded sets (`compare.rb:12`). Emitting
  records for the first time may make previously-comparable recorded runs refuse. If any
  committed bench fixture is affected, escalate — that is a data-migration question.
- Every existing `capability_degraded` spec hand-constructs the record
  (`spec/lain/bench/session/loader_spec.rb:54-56`, `spec/lain/bench/session_spec.rb:304-307`,
  `spec/lain/telemetry_spec.rb:523-553`). They are fine as reader/serialization tests — do not
  delete them, and do not mistake them for emission coverage.

---

### T14 — Resolve a review row against the survey root it came from   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/review/source/corpus.rb`, `lib/lain/frontend/neovim/changeset_diff.rb`,
`lib/lain/frontend/neovim/runtime/47_diff.lua`, `spec/lain/review/source/corpus_spec.rb`,
`spec/lain/frontend/neovim/changeset_diff_spec.rb`,
`spec/lain/seams/survey_subdirectory_spec.rb` (new)
**Reuse:** `Survey::Walk::Listing#absolute` (`survey/walk.rb:117,289`) — the correct full path,
already computed and then discarded; `Corpus#path` (`source/corpus.rb:170`), `LazyFile`
(`corpus.rb:316-318`), `ChangesetDiff#drawn` (`changeset_diff.rb:123-128`),
`review_diff.absolute` (`47_diff.lua:66-68`) and its `vim.g.lain_review_root` hook (`:60`)
**Shared-file wiring:** none
**Reachable from:** `CLI::Command::Survey#opened` (`cli/command/survey.rb:239-248`) →
`Review::Source::Corpus` → `ReviewView#open` → `ChangesetDiff#open` → `47_diff.lua`. The AC drives
a real survey of a subdirectory and asserts the buffer opened names an existing file.

`/survey ./lib` labels a row `greeter.rb` (survey-root-relative) and then resolves it against the
project root, opening a file that does not exist. `Listing#absolute` already knows the answer at
`walk.rb:289` and is dropped one layer up. Carry the survey root through so resolution and label
agree. Note `47_diff.lua:76-82` **refuses an absolute path outright**, so sending
`listing.absolute` is not a drop-in fix; `vim.g.lain_review_root` (`:60`) is the existing hook.

Latent hazard worth closing while here: `47_diff.lua:50-54` means a `:w` in the wrongly-resolved
buffer would **create** the missing file.

**Acceptance criteria:**

```gherkin
Scenario: a row from a subdirectory survey opens the real file
  Given a project with a file at lib/greeter.rb
  When the operator surveys ./lib and opens the row for greeter.rb
  Then the buffer opened names the existing lib/greeter.rb
  And its contents are the file's contents

Scenario: a project-root survey is unchanged
  Given the same project
  When the operator surveys . and opens the row for lib/greeter.rb
  Then the buffer opened names the existing lib/greeter.rb

Scenario: a verdict refusal names the path the operator can find
  Given a survey of ./lib with an unreviewed file
  When an approve verdict is refused
  Then the refusal names a path that resolves from the project root
```
→ spec file: `spec/lain/seams/survey_subdirectory_spec.rb` (`:seam`),
`spec/lain/frontend/neovim/changeset_diff_spec.rb`

**Escalation triggers:**
- `spec/lain/survey/walk_spec.rb:471` is the **only** subdirectory survey root in the suite and it
  asserts the sub-root-relative path as correct (`eq(%w[one.md two.md])`) for a gitignore case.
  A fix at the `Walk` layer will fail it. Its subject is gitignore filtering, not path contracts,
  so the path assertion is incidental and re-derivable — change it if `Walk` is the right layer.
  Escalate only if you cannot tell whether `Walk` returning survey-relative paths is depended on
  elsewhere; `Listing#absolute` existing beside it suggests the pair is intentional.
- `changeset_diff.rb:106-107` documents the wire path as "repository-relative". Changing that
  contract touches the diff-source path too (`diff_mode_spec.rb:100-103` chdirs so the two
  coincide). If the local-branch review surface regresses, escalate.
- The old-side buffer name `lain://review/OLD/<path>` embeds the path verbatim. If disambiguating
  two files with the same survey-relative name is now possible, report it.

---

### T15 — Register a read when a review row is opened   [wave 2] [risk: medium]

**Depends on:** T14
**Files:** `lib/lain/frontend/neovim/changeset_diff.rb`, `lib/lain/review/changeset.rb`,
`spec/lain/frontend/neovim/changeset_diff_spec.rb`, `spec/lain/review/handover_spec.rb`
**Reuse:** `LazyFile#hunks` / `#chunked?` (`review/lazy_file.rb:136,150`) — the only thing that
flips a read; `Changeset#old_side` (`review/changeset.rb:124-129`), whose
`return [] if file.old_path.nil?` short-circuit is the bug; `MarkedChangeset.row`
(`review/session/marked_changeset.rb:183-188`), `ReviewView#unmarkable` (`review_view.rb:446`)
**Shared-file wiring:** none
**Reachable from:** `ReviewView#open` (`review_view.rb:379-426`) → `ChangesetDiff#open`
(`changeset_diff.rb:110-128`) — the `<CR>` gesture. The AC drives the gesture and then marks,
rather than calling `#hunks` in the spec.

Every corpus file has `old_path: nil`, so `ChangesetDiff#open` short-circuits at
`changeset.rb:125` and never calls `#hunks`. `chunked?` stays false forever, `MarkedChangeset.row`
returns `hunk_keys: NO_KEYS`, and `x` / `:LainReviewMark` / verdict all refuse. Not zero hunks —
nobody asked. (`marks.rb:114-115` still claims `ReviewView` "forces every file at render until
B19 lands"; B19 landed in `b45553e` and removed exactly that forcing, turning an accidental read
into a hole. Fix the stale comment.)

**Acceptance criteria:**

```gherkin
Scenario: opening a row makes it markable
  Given a survey with an unread file
  When the operator opens that row with the open gesture
  And then marks it reviewed
  Then the row shows as reviewed and no unread refusal is raised

Scenario: an unopened row still refuses to be marked
  Given a survey with an unread file
  When the operator marks it without opening it
  Then the refusal names the file and says to open it first

Scenario: a fully opened and marked survey admits an approve verdict
  Given a survey whose every file has been opened and marked reviewed
  When an approve verdict is submitted
  Then it is admitted
```
→ spec file: `spec/lain/frontend/neovim/changeset_diff_spec.rb`, `spec/lain/review/handover_spec.rb`

**Escalation triggers:**
- `spec/lain/frontend/neovim/review_view_spec.rb:212-300` uses an `unread_entry` double whose
  `#hunks` **raises**, to prove the view does not read at render time (the b45553e behaviour).
  If your fix makes the *view* force hunks again you will fail it and undo b45553e — the read must
  register on the **open gesture**, not on render. Stop if that distinction collapses.
- `spec/lain/review/handover_spec.rb` opens its session with `source: "local_branch"` (`:129,:169`),
  where every file is already chunked, so it cannot see this defect. Add corpus coverage; do not
  assume the existing examples guard it.
- `Verdict::Policy::EveryHunk#admit!` reaches `marks.states(changeset)` → `changeset.hunks`
  (`marks.rb:182`), which chunks the **entire** corpus. If reads now register earlier, confirm
  the approve path does not double-chunk a large survey into a latency problem.

---

### T16 — Prune the vacuous and dead specs   [wave 2] [risk: medium]

**Depends on:** T18
**Files:** `spec/lain/compaction/prepared_spec.rb`, `spec/lain/compaction/cold_spec.rb`,
`spec/lain/context_window_spec.rb`, `spec/lain/bench/sweep_spec.rb`,
`spec/lain/bench/spawn_seam_spec.rb`, `spec/lain/arm/single_thread_spec.rb`,
`spec/lain/arm/dual_ledger_spec.rb`, `spec/lain/arm/orchestrator_worker_spec.rb`,
`spec/lain/arm/adaptive_router_spec.rb`, `spec/lain/arm/driver_spec.rb`,
`spec/lain/review/bounds_spec.rb`, `spec/lain/compaction/strategy/summarizing_spec.rb`
**Reuse:** the repo's tag doctrine in `spec/support/tags.rb:103-131`; `Instrument.new(clock:)`
injection as used at `spec/lain/arm/orchestrator_worker_spec.rb:130` — the real assertion the
tautological `elapsed` examples should collapse into
**Shared-file wiring:** none
**Reachable from:** deferred: spec-only card, builds no capability. Recorded in Open decisions.

Rewrite onto real behaviour where the intent is salvageable; delete only what is genuinely dead.
Do **not** touch any spec another card in this chunk owns.

**Work from T18's report, not only from the list below.** The list is one exploration pass's
sample of the seams this chunk touches; T18's guard scans the whole suite. Where the two disagree,
the guard is the wider net and the list is the verified core. Apply the evidence-not-authority test
from the Orchestrator contract to every candidate — most of this suite is LLM-written, so an
assertion with no traceable reason behind it is a candidate, not a constraint.

Verified vacuous, delete or rewrite:
- `compaction/prepared_spec.rb:232-234` — passes `Channel::Null` in explicitly, then asserts only
  `not_to raise_error`; never exercises the production default. Rewrite to construct with no journal.
- `context_window_spec.rb:31-34` — title claims determinism, asserts only `not_to raise_error`.
  Rewrite to assert longest-token-wins.
- `context_window_spec.rb:113-115` — nested `expect` inside `expect {}`, fully subsumed by
  `:136-141`. **Delete.**
- `bench/sweep_spec.rb:44-48` — `not_to raise_error` under a webmock posture that would already
  fail every sibling example. **Delete.**
- `bench/spawn_seam_spec.rb:172-175` — `not_to raise_error` on a hole the comment says production
  never injects. **Delete.**
- The `expect(run.elapsed).to be_a(Float).and be >= 0` tautologies at
  `single_thread_spec.rb:46-48`, `orchestrator_worker_spec.rb:121-123` and
  `adaptive_router_spec.rb:62-66` — a monotonic delta cannot be negative. Collapse into one shared
  example, or delete in favour of the injected-clock examples next door.
  **The fourth (`dual_ledger_spec.rb:73-75`) is handed to T8**, along with the rest of that file's
  prune — see the handoff note below.
- `arm/driver_spec.rb:34` — `it "is a String -- never touches stdout"` asserts only the String
  half; `bench/arms_report_spec.rb:78-82` does it properly with `output("").to_stdout`. **Delete.**
- `compaction/cold_spec.rb:170-172` — does construct the real default but asserts only
  `not_to raise_error`. Strengthen, do not delete.
- `review/bounds_spec.rb:161,166,174` — three standalone literal-constant assertions that block
  any retune. Rewrite to assert the ceiling's *effect*, or delete.
- `compaction/strategy/summarizing_spec.rb:203` — `expect(TIER).to eq(:model)`; the next line
  carries the real assertion. **Delete line 203 only.**

**Handed to earlier-wave cards, NOT done here** — worktrees fork `origin/main`, so a wave-2 agent
may branch before wave 1 lands, and these are the two files this chunk edits most. The agent
rewriting a file is also the one who knows what in it is dead:

- `spec/lain/arm/dual_ledger_spec.rb` → **T8** (its `elapsed` tautology at `:73-75`, alongside the
  settle-behaviour updates T8 already owns).
- `spec/lain/bench/spawn_seam_spec.rb` → **T7** (`:172-175` `not_to raise_error`, and `:219`'s
  constant assertion, alongside the default-system-prompt work T7 already owns).

`spec/lain/context_window_spec.rb` stays here but is also touched by T10 in wave 4 — that overlap
is a hard merge gate for T10, which must rebase onto T16 rather than the reverse.

Two coverage holes to fill while here (both HIGH-value, both named by the grounding pass):
- `arm/driver_spec.rb:8-20` — the spec's `spawn_seam` lambda has **fixed arity** (`journal:` only)
  while production's takes `(journal:, workspace:, timeline:, base_timeline:, worker_env:, **)`
  (`bench/spawn_seam.rb:104`). Widen it, or the Driver spec can never drive the isolated path.
- `arm/orchestrator_worker_spec.rb:102-105` — a hand-made three-**line** task makes the default
  decompose fan out, hiding that `DEFAULT_DECOMPOSE` splits on lines while real prompts are folded
  single-line YAML scalars (which is why both production callers override it —
  `bench/live_arms.rb:47`, `bench/arm_sweep.rb:142`). Add a single-line-task example.

**Acceptance criteria:**

```gherkin
Scenario: every candidate the guard reports is triaged
  Given T18's report of flagged examples
  When the prune is finished
  Then each flagged example is either fixed, deleted, or allowlisted with a stated reason
  And the guard passes with no unexplained entries

Scenario: the suite still discriminates after the prune
  Given the pruned suite
  When the full suite runs
  Then the example count equals the old count minus deletions plus additions
  And no example fails

Scenario: the rewritten arm driver spec drives the production seam arity
  Given the widened spawn_seam lambda in the driver spec
  When the driver runs an arm through it
  Then it accepts the keywords production passes

Scenario: the default decompose is shown to split on lines
  Given a single-line task and the default decompose
  When an orchestrator-worker arm runs it
  Then it fans out to exactly one worker
```
→ spec file: the files listed above

**Escalation triggers:**
- Leave these alone; they are deliberate and were checked: `spec/lain/role_prelude_wiring_spec.rb:148-149`
  (pending since 2026-07-17, records a latent Anthropic 4-`cache_control` 400),
  `spec/lain/supervisor_reactor_spec.rb:179-183,457-460` (inverted-on-purpose probes from
  2026-08-04), and the ~10 `skip`ped shared examples reached via
  `spec/lain/review/surface/null_spec.rb:9`. If a prune makes any of them fail, STOP.
- `spec/lain/bench/sweep_fixture_spec.rb:55` **writes into `lib/lain/bench/corpus/`** — it is a
  fixture regenerator wearing a `_spec.rb` name, inert by default behind `:ollama`. Do not delete
  it; flag it for the owner.
- Do not touch `spec/lain/bench/arms_report_spec.rb` (T7 owns it),
  `spec/lain/arm/dual_ledger_spec.rb`'s settle examples (T8), or the four ContextWindow pins (T10).
  Overlap with those cards means the prune deleted coverage another card needed.
- If the deleted example count does not match the suite's drop exactly, a delete removed more than
  intended — stop and reconcile.

---

### T18 — Guard mechanically against assertion shapes that cannot fail   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `spec/spec_discipline_spec.rb` (new). **No allowlist file** — this card is report-only,
and an allowlist nothing enforces is a file that rots.
**Reuse:** `spec/output_discipline_spec.rb` — the repo's existing precedent for a spec that parses
the AST of every file and fails on a banned shape; Prism, already used for static analysis in
`spec/lain/cli/chat_flags_spec.rb:143-149`; `spec/support/tags.rb:103-131` for the tag vocabulary
**Shared-file wiring:** none — this card creates its own files. It does **not** edit
`spec/spec_helper.rb` (orchestrator-owned); if a `require` is needed there, hand back the one-line
diff.
**Reachable from:** deferred: a test-suite guard, not a product capability. Recorded in Open
decisions. It runs in the default suite, which is its production path.

The suite is largely LLM-written and will keep growing that way, so a one-time prune (T16) fixes
today's instances and nothing else. This card makes the highest-signal vacuous shapes mechanically
detectable, the way `output_discipline_spec.rb` makes a stray `puts` detectable.

**This card ships REPORT-ONLY. The failing guard is a follow-up, not this chunk.** A crude scan
during planning found **352 raw `not_to raise_error` occurrences across 183 spec files**, of which
roughly 127 look like sole assertions, plus ~26 constant-literal examples. An earlier draft set a
"stop if more than ~40" trigger and would have halted in wave 1, blocking T16. The real number is
3–4× that, so a guard that *fails* the suite on day one would need a 150-entry allowlist, which is
a disabled guard wearing a spec's name.

So: build the scanner, have it **print a report and pass**, and record the baseline counts in the
chunk's progress note. T16 consumes the report. Turning the guard into a failing check is a
separate decision once the count is down — say so in the card's own comment so a later reader does
not mistake report-only for an oversight.

Flag exactly these two shapes:

1. **`expect { … }.not_to raise_error` as an example's only assertion.** Verified instances:
   `compaction/prepared_spec.rb:232` (under a `describe "the default journal"` that passes the Null
   in explicitly), `context_window_spec.rb:31`, `bench/sweep_spec.rb:44`,
   `bench/spawn_seam_spec.rb:172`, `compaction/cold_spec.rb:170`.
2. **A nested `expect` inside an `expect { … }` block** — RSpec swallows the inner failure, so this
   is unambiguously a bug rather than a taste call, and the cost of a false negative is total.
   Verified at `context_window_spec.rb:113`.

**A third shape — an example whose only assertion is `expect(SomeConst).to eq(<literal>)` — was
considered and dropped.** Two of its five candidate instances are healthy on inspection:
`bench/spawn_seam_spec.rb:219` and `compaction/strategy/summarizing_spec.rb:203` each carry a
second, real assertion on the following line, so the rule would not have flagged them anyway. The
three genuine ones (`review/bounds_spec.rb:161,166,174`) sit under
`describe "the defaults, and the evidence for each"` with comments citing external research —
which the Orchestrator contract's own test classifies as **authority**, not as re-derivable. A rule
whose best instances are the ones you should keep is the wrong rule. T16 still prunes those three
by hand if the evidence does not hold up; the guard does not.

**Acceptance criteria:**

```gherkin
Scenario: an example asserting only that nothing raised is flagged
  Given a spec file whose example's sole assertion is expect { }.not_to raise_error
  When the guard runs
  Then it reports that example with its file and line

Scenario: a nested expect inside an expect block is flagged
  Given a spec file with expect { expect(x).to be_a(Integer) }.not_to raise_error
  When the guard runs
  Then it reports that example with its file and line

Scenario: an example with a second real assertion is not flagged
  Given an example whose not_to raise_error sits beside an assertion on a value
  When the guard runs
  Then it is not reported

Scenario: the guard reports without failing the suite
  Given a suite with many flagged examples
  When the guard runs
  Then it prints the counts by shape and the run passes

Scenario: a healthy example is not flagged
  Given an example that asserts an observable outcome
  When the guard runs
  Then it is not reported
```
→ spec file: `spec/spec_discipline_spec.rb`

**Escalation triggers:**
- The planning scan (crude, grep-based) found ~127 sole-assertion `not_to raise_error` examples
  across 183 files. If your AST scan lands within ~2× of that, proceed. If it lands **an order of
  magnitude** off in either direction, stop — either the shape detector is wrong or the crude scan
  was, and allowlisting the difference blind is how a guard rots.
- Report-only means report-only: **do not** make the guard fail the suite in this chunk, and do not
  add an allowlist file that nothing enforces. If a ratchet is wanted later it should assert
  `count <= <recorded ceiling>` so a new entry costs an old one — note that in the card's comment
  as the intended follow-up, and leave it unbuilt here.
- Per CLAUDE.md, **never park a harness in `spec/support/`** that defines global methods:
  `spec_helper.rb` globs `support/**/*.rb` and loads it in every worker of every run. The allowlist
  is data (YAML); any code lives in the spec file itself.
- If parsing every spec file measurably slows the suite, report the cost — `output_discipline_spec.rb`
  already parses all of `lib/`, so parsing `spec/` too may matter. The suite's wall is a MAX over
  files (CLAUDE.md), so a single slow guard file can become the floor.
- Do not flag `expect { … }.not_to raise_error` when the example has *other* assertions; that is a
  legitimate smoke check beside a real one (`spec/support/shared_examples/review_surface.rb:242-250`
  is the borderline case — allowlist it rather than narrowing the rule to nothing).

---

### T17 — Correct the ollama performance docs and record the bench methodology change   [wave 4] [risk: low]

**Depends on:** T8 (only item 3 needs it; items 1 and 2 depend on nothing)
**Files:** `docs/providers/ollama.md`, `DEBUGGING_OLLAMA.md`, `planning/README.md`,
`planning/specs/chunk-poc-integration-fixes.md` (this file's status line)
**Reuse:** the measurement discipline in `DEBUGGING_OLLAMA.md`'s existing tables; the
symptom → diagnosis → fix shape both docs already use
**Shared-file wiring:** one row in `planning/README.md`'s specs table pointing at this plan
**Reachable from:** deferred: docs-only card. Recorded in Open decisions.

Three things to record, none of which may be resolved by picking a convenient number:

1. **The prefill discrepancy is unexplained and must be presented as such.**
   `DEBUGGING_OLLAMA.md:107` reports `qwen3-coder:30b` prefill 340 → 2222 tok/s (6.5×) with
   `num_batch: 2048`; the 2026-08-15 POC measured 1201/1194 → 1578/1562 tok/s (1.31×), replicated
   with distinct random prompts on the same box and build. Same axis, same model, incompatible
   baselines. Record both with their conditions and say the reconciliation is open. Do **not**
   overwrite one with the other, and do not average them.
2. `docs/providers/ollama.md:92`'s "3x decode and 8x prefill" headline needs the POC numbers
   beside it and the same caveat.
3. **T8 changed what the arm bench measures.** DualLedger no longer settles on the grader, so arm
   numbers recorded before this chunk are not comparable to numbers after it. Say so where a
   reader of recorded arm data will find it.

**Acceptance criteria:**

```gherkin
Scenario: the prefill claim carries both measurements and its open question
  Given the ollama provider doc
  When a reader looks up the num_batch prefill claim
  Then both the 6.5x and the 1.31x measurements appear with their conditions
  And the text states the discrepancy is unreconciled

Scenario: the arm bench methodology change is discoverable
  Given the docs a reader of recorded arm data would consult
  When they look for how dual-ledger terminates
  Then they find that it settles on its ledger, and that pre-chunk numbers are not comparable

Scenario: the plan is indexed
  Given planning/README.md
  When a reader scans the specs table
  Then this chunk plan is listed
```
→ spec file: none (docs-only). `spec/docs_naming_spec.rb` and `yard-lint` must stay green; verify
via the integration checks below.

**Escalation triggers:**
- If re-measuring reconciles the two prefill figures (e.g. the 340 tok/s baseline came from a
  different KV-cache type or context length), that is a better outcome than documenting an open
  question — report the finding and update the card rather than writing the caveat.
- Per CLAUDE.md, **never name a `.toml` on a `rubocop` command line**; and this repo's writing-style
  rules apply to new docs. If an edit would restyle prose beyond the numbers, keep it minimal.

---

## Progress note — execution, 2026-08-17

**Wave 1 complete: all 11 cards implemented, none reviewed or landed yet.** T1, T2, T3, T4, T6,
T7, T8, T9, T12, T14, T18. Each proved a red phase; hand-backs live in the agents' worktrees.

**Toolchain: RESOLVED 2026-08-17.** The suite is green (13118 examples, 0 failures, 33s parallel)
and `pre-commit` passes apart from a missing `shellcheck` binary. The environment now lives in
`.envrc` (machine-local, globally gitignored): mise's ruby 4.0.6, `LD_LIBRARY_PATH` for Homebrew
OpenSSL, and a `TMPDIR` under `$HOME`. The findings below cost real debugging and must not be
re-derived:

- **`~/.rubies/ruby-4.0.6` is unusable** — built against a home-directory prefix that no longer exists,
  so its `$LOAD_PATH` is dead and all 16 gem binstub shebangs point at nothing. Use mise's install.
  CLAUDE.md's toolchain snippet is **not sufficient** on this box.
- **`rake compile` needs `clang`** (bindgen/libclang). Switching interpreters invalidates `rb-sys`'s
  build fingerprint and forces a rebuild, which is when its absence surfaces.
- **A stray `~/.lain/state.json`** made every fixture under `$HOME` resolve `$HOME` as the project
  root (`detected_by: :lain_dir`), failing 3 `project/resolver_spec` examples. Moved to
  `~/.lain.bak`. Worth noting on its own: it means any `lain` run from a non-project directory under
  `$HOME` would have inferred the whole home as the project root.
- **Three real-resource specs are flaky under heavy external load**, each green on repeat in
  isolation. Recorded by NAME, never by line number, per CLAUDE.md — the four first recorded as
  `cli/up_spec.rb:115` drifted within days:
  - `Lain::Frontend::Neovim the review thread pane following the cursor does not re-place the diff
    on every further move once it is back`
  - `Lain::Frontend::Neovim user mappings are respected re-attach is idempotent: no duplicate
    commands, and motions/syntax still work`
  - `Lain::CLI::Up against a real tmux server --nvim cockpit splits the chat window into an nvim
    pane and a chat pane sharing one socket and one cwd`

  These drive real `nvim`/`tmux`, so they are timing-sensitive rather than order-sensitive. The
  trigger is **load, not concurrency within the suite**: at load ~28 with 3G available (several
  agents running their own suites) the tmux one failed two commits in a row while passing 2/2
  isolated. The practical rule for an orchestrator landing commits in parallel with agent work is to
  land in a quiet window, because `pre-commit` runs the whole suite and one flake fails the commit.

The findings below were the diagnosis, and are kept because two of them were wrong turns worth not
repeating:

- `~/.rubies/ruby-4.0.6` was built against a home-directory prefix that no longer exists (the account
  was renamed). 16 gem binstub shebangs and 4 `rbconfig.rb` entries still point there, so `bundle`,
  `rake`, and every `parallel_tests` worker fail to start. CLAUDE.md's toolchain snippet is **not
  sufficient** on this box.
- **The 11 "pre-existing failures" every agent reported are environmental artifacts, not repo
  defects.** Both halves were diagnosed and neither needs a code change:
  - **7 in `review/deletability_spec.rb`** — `/tmp` is tmpfs, a different device from `$HOME`, so
    the fixture's `cp -al` hard-link copy cannot work. Setting `TMPDIR` to a path on the same
    filesystem makes all 16 examples pass.
  - **4 in `provider/anthropic_reference_spec.rb` and `provider/bedrock_reference_spec.rb`** — an
    artifact of the `RUBYLIB` workaround itself. Ruby 4.0 ships a stripped default `cgi.rb` without
    `CGI.parse`; `RUBYLIB` puts the stdlib ahead of gems and shadows the real `cgi` gem (0.5.2,
    already in `Gemfile.lock`). With correct precedence these specs pass **43/43**. There is no
    `CGI.parse` bug to fix, and no Gemfile change is warranted.
- Consequence for the integration checks below: **"full suite green" is achievable** once the
  toolchain is repaired. Do not record an 11-failure baseline as acceptable.
- `rake pspec` also refuses with `RuntimeLogTooSmallError` if `tmp/parallel_runtime_rspec.log` has
  been overwritten by a narrower `parallel_rspec` run. The log is regenerable — delete it.

**Commit constraint for this chunk (owner's instruction, 2026-08-17):** no personal username may
appear in any path in any new commit. Verified: no card's diff or new file introduces one, and the
working tree is clean of the current one entirely. The pre-existing home-path references
in tracked files are all in published history (`main == origin/main`, 0 unpushed) and are
explicitly **out of scope**.

**Landed so far:** T3 (`resume: name the session when a fork dangles`).

**Follow-ups the panels surfaced — each wants its own card, none in scope here:**

1. **`Resume#rebuild` has T3's gap.** The plain `--resume` path (`cli/resume.rb:136-152`) still rescues
   only `Corrupt`/`CorruptFrame`, so a dangling causal edge on an ordinary resume still leaks a raw
   `Store::MissingObject`. T3 fixed `--fork` only, which is what its card scoped.
2. **SIGINT at a `human>` prompt raised outside `respond` is uncovered.** `Conductor#supervise` routes
   signals only around `respond`'s ask; T1 makes that state reachable for the first time.
3. **The arms grader scores a file nobody wrote.** A task whose gold is `contains:` + `excludes:` has
   its `excludes` half pass vacuously against `content_at` returning `""`, so an empty trajectory
   scores **0.500** on `fix-off-by-one-loop` and the suite floor is 0.0625, not 0. Same family of
   defect as the vacuous assertions this chunk prunes, but in the measurement instrument.
4. **`ARCHITECTURE.md:249-252`** claims `Provider::Ollama` is wired unconditionally; already falsified
   on main by `--summarizer-provider`, and T12 makes the paragraph wronger.
5. **`Actor`'s settle note (`actor.rb:216`)** is the same class of dangle T2 fixes, outside T2's card.
6. **No guard on summarizer flag help text** — `exe/lain:709` was free to assert the opposite of the
   code; only a human reading the card caught it. *(Closed by T12, which added the guard.)*
7. **`capability_degraded` reaches the live view and nothing renders it.** `Chronicle#record_journal`
   resolves to the tee under `--journal`/`--nvim`, and the record is the first event on the live nvim
   Channel — but `grep CapabilityDegraded lib/lain/frontend/**` matches zero files. The run that
   silently lost `prompt_caching` still tells the operator nothing at the moment they could act,
   which is what the record type's own docstring ("the degradation is made LOUD here") exists to
   prevent.
8. **DualLedger needs a progress detector that can say *complete*.** `DEFAULT_PROGRESS` reads only
   `response.text`, so a model that has finished and repeats itself and one that is stuck repeating a
   non-answer hand it byte-identical input. Separating them is the `progress:` seam. Pair it with a
   `Measurement`/report column for the terminal state, so the disclosure is data-backed rather than
   prose — `ArmSweep#measure_dual_ledger` still counts only `event == :replan`.
9. **`UndecodableAnswer` survives structured output, and `--summarizer-max-tokens` is inert on the
   ollama path.** `format` constrains shape, not length, so a reply cut at the token ceiling is a
   prefix of grammar-valid JSON and `JsonDecoder` never inspects `stop_reason` — the message blames
   the model for a ceiling. Separately, `Ollama::Encoding#encode` never puts `num_predict` on the
   wire, so the flag is silently dead on exactly the path T6 fixes.
10. **`:structured_output` names two incompatible contracts** — grammar-constrained decoding on
    ollama, tool-*forcing* on `AnthropicReference` — so `supports?` answers a different question than
    the caller asks. Wants the marker to become a value object that cannot be half-built.
11. **`ARCHITECTURE.md`'s absolute counts are stale at HEAD by ~21** (re-derived 74/37 against a
    documented 53/34), independent of this chunk. Wants a doc audit, not a silent rewrite.

12. **SIGINT at a `human>` prompt raised outside `respond` is uncovered** — `Conductor#supervise`
    routes signals only around `respond`'s ask, and T1 makes that state reachable for the first time.
    (Recorded here rather than in an untracked hand-back, which is where it kept living.)
13. **`Command::Survey` is parked at 110/110 `Metrics/ClassLength`** by joining a line. The binding
    rule was honoured, but the class did not get simpler and the cop's real signal — an object is
    missing — now sits at the ceiling, where the next line to land trips it again.
    `parse`/`opened`/`round`/`drawn`/`held`/`refuse_second_surface!`/`classifier` is more than one
    responsibility.
14. **New agent worktrees fork a stale base, not current `main`.** Observed 2026-08-17: T16 and T5
    were created at the pre-chunk commit, so T5's tree lacked the dependency its card was written
    against and T16's lacked the guard whose report it consumes — `spec/spec_discipline_spec.rb` did
    not exist in it at all. Both were fast-forwarded by hand. **An orchestrator must fast-forward
    each new worktree at spawn and tell the agent to re-measure its baseline count**, or a
    dependent card silently works against the tree its dependency was supposed to change.

**Migration note owed to a reader of recorded runs (T13):** once `capability_degraded` is emitted, a
pre-change and post-change ollama run refuse to compare — `cannot compare runs with differing
degraded sets: [] vs [:prompt_caching]`. The refusal is *correct*: both runs were degraded, only one
said so. But the message sends a reader hunting an arm difference, so read it as "this recording
predates capability recording". No committed fixture is affected.

**Review round 1 outcomes** (panel: Torvalds/Evans/Metz/Schneeman/Patterson, depth by risk):

- **T3 — APPROVE**, landed. Panel reproduced red and green independently and traced every path that
  can reach the widened rescue to confirm it is not over-broad.
- **T1 — REQUEST-CHANGES**, two BLOCKERs, each a measured pre/post delta. (1) `/inbox` is a registered
  command so it now runs *inside* `LineScope`, racing `answer_loop` against `drain_at_prompt` on one
  stdin — peak concurrent reply reads 1 → 2, and the second answer routed to the **wrong digest**.
  (2) A question arriving during any short command line (`/help`, `/status`) is dequeued, rendered,
  then destroyed by `serve_question`'s unconditional ensure — off `@questions` *and* `@inbox`, asker
  parked forever, no error. The underlying ensure is pre-existing; this card newly exposes every
  command line to it while breaking the recovery path. **Design calls made by the orchestrator:** a
  line that is itself a reply surface must never have a second surface opened around it; and an item
  may leave the queues only when answered (re-enqueue, never retire). `human_replies.rb` authorised.
- **T4 — APPROVE-WITH-FIXES.** AC2 probed across nine catalog-miss shapes, zero model calls in every
  case. `SystemStackError` escapes both rescues (a recursive `suitable?` is the DSL's likeliest
  failure) and a non-terminating predicate blocks the tool path ~0.64s per result with no timeout —
  both newly reachable on *every* tool result rather than only above 4096 bytes. The
  `tool_runner_spec.rb` scope expansion was adjudicated **necessary and correct**.
- **T9 — APPROVE-WITH-FIXES.** The upstream claim was verified at ollama source, including that the
  `numParallel` multiplication never reaches the recorded `contextLength`, so the 8× over-estimate is
  genuinely closed. Malformed `/api/ps` bodies raise instead of answering nil; the anti-`/api/show`
  trap asserts nothing (an unused WebMock stub fails nothing); `Integer(..., exception: false)` reads
  `"0x40000"` as 262144, which is the forbidden direction.
- **T12 — APPROVE-WITH-FIXES**, no blockers. Both cost guards verified untouched and no false "same
  provider" is constructible across 25 probed shapes. But a mutant of the one judgment call leaves
  the **whole suite green** — nine lines of prose defending an untested claim.
- **T7 — REQUEST-CHANGES**, one BLOCKER: the new default prompt's worked example is `lib/widget.rb` /
  `def normalize`, which **is the gold for the suite's first task**. An arm echoing the format and
  doing no work scores 0.500 on it; suite contamination +0.0625. Replaced the bug "arms score 0
  because nobody told them the rules" with "arms score ≥0.0625 because the rules contain an answer".
- **T18 — REQUEST-CHANGES**, two BLOCKERs. (1) Precision against the card's intent is **~12%**: most
  of the 128 are the accepts-half of accept/refuse pairs against `check!`/`admit!`/`ensure_open!`
  methods, which fail loudly on regression — and the report reads as a delete queue with no warning,
  so T16 would have deleted good tests while staying green. (2) It shipped `be_between(63, 254)` and
  `not_to be_empty`, i.e. a ratchet *and* an anti-ratchet, in direct violation of report-only — and
  it **fails when T16 succeeds**. T16's "allowlisted" AC branch is redefined as "documented in the
  hand-back with a reason", since T18 correctly refused to build an allowlist.

- **T8 — REQUEST-CHANGES**, two BLOCKERs, both reproduced by probe rather than read off the
  hand-back. (1) The sweep report's tie disclosure is now false; **scope expansion AUTHORISED** to
  `lib/lain/bench/arm_sweep/report.rb` + `spec/lain/bench/arm_sweep_spec.rb` (no other card owns
  either), with the tie to be pinned numerically so prose and data cannot drift again. (2)
  `settled? = recovering && stalls.positive?` means a healthy run cannot terminate without being
  journaled as stalled, so the replans metric degenerates to a termination flag — to be fixed via
  `Agent::LoopMachine`'s wired-but-never-fired `event(:end_turn) { transition awaiting_model: :done }`.
  Plus: validate `stall_limit >= 2`, guard the load-bearing `K + 2 <= max_steps` relation, correct
  an elapsed-pin comment that claims more than it pins.
- **Routed T8 → T7:** `bench/cli.rb:138-139`'s live-cost warning says the dual-ledger arm asks "up
  to" `DEFAULT_MAX_STEPS` times; post-change it asks ~5 on essentially every task, so the worst case
  is now the typical case. `bench/cli.rb` is T7's file, so the fix lands with T7.

**Original escalation from T8** — the `arm_sweep` linear-arms tie has broken: grade rows still tie, but
dual-ledger tokens go 998 → 4990 and replans 0 → 8 over `recordings.yml`, so the report's NOTE that
the difference is "visible only in the replans/stalls metric" is now false. `arm_sweep_spec:117-121`
still passes because it asserts static prose, which is why it missed this. Needs an orchestrator
decision before T8 lands; `report.rb` is not T8's file.

## Integration checks

After the last wave:

1. `bundle exec rake pspec` — full suite green. **Check the example COUNT against a serial run**
   (CLAUDE.md: a truncated run and an OOM kill both report "0 failures"). Expect the count to fall
   by exactly T16's deletions and rise by the new specs.
1b. Record T18's allowlist size before and after T16, in the chunk's progress note. A guard whose
   allowlist did not shrink means the prune did not reach what the guard found.
2. `bundle exec rubocop` (bare — never name a `.toml`), `pre-commit run --all-files`,
   `cargo test && cargo clippy --all-targets -- -D warnings`.
3. `bundle exec rspec --tag core` after `rake core:build`.
4. **Manual pass owed to the owner** (the POC's own checkpoints, re-run against the fixes; the suite
   cannot cover the tmux/nvim round trip):
   - `lain up` on a throwaway repo with `--model` on a local ollama arm; type
     `@researcher[/critique] …` and answer the question it raises — **checkpoint 5, the wedge**.
   - `/meta summarizer …` produces a reviewable declaration in `.lain/summarizers/` and returns
     to the prompt — **checkpoint 7**.
   - `/survey ./lib`, `<CR>`, `x`, then an approve verdict — **checkpoint 6, both survey defects**.
   - `lain bench arms <fixture>` with **no** `--system`: scores must be non-zero — **checkpoint 8**.
   - Fork a session that contains a subagent question — **T2/T3**.
   - Confirm `.lain/state.json` occupancy against the journal's `input_tokens` and the served
     window — **T10**.
5. Re-run the POC's Act 4 record checks over a fresh session: every journal line parses, no
   `journal_error`, and a `capability_degraded` record now appears on the ollama arm.
6. Update `/tmp/lain-poc/FINDINGS.md`'s corrected claims (see Grounding) if that memo is kept.
