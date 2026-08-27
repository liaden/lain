# Chunk: round-14 — who a question is addressed to, and where a child's files live

status: draft
commit-mode: orchestrator-commits
language: ruby (with real Lua in the nvim runtime)
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson, TJ DeVries (Neovim seat, added for T1 and T2 on the round-11 precedent)

## Intent

Discharges [`../qa-findings-round14-2026-08-27.md`](../qa-findings-round14-2026-08-27.md), and takes
two of its findings further than a fix, because grounding showed both were symptoms of a missing
**address**.

**F79** — a session whose subagent parked a question can be neither forked nor resumed — is a
**dangling causal edge, and the panel caught the first draft of this plan re-narrating it as
something more elegant than the evidence supports.** `Bench::Session::MessageReplay#resolvable?`
(`message_replay.rb:135-137`) consults `render_parent` and `causal_parents` and **nothing else**;
`to` is never read for reachability. So re-addressing the question fixes nothing. The findings
document said as much in its own words — *"the question's `from` already resolves; only its
`causal_parents` does not"* — and the first draft edited the address anyway. **T6 fixes the edge.**

The escalation architecture the address change belongs to is still worth having, and it is still in
this chunk — as **T7 and T8**, honestly labelled as what they are: a child addressing its parent, and
a parent that relays rather than a child reaching past it. They improve legibility and give
agent-to-agent coordination a home. They are not the F79 fix, and the plan no longer claims they are.

**F80** — `--isolation worktree` accepted in a chat and leasing nothing — is one line at the point of
use (`Subagent#run_child`, `subagent.rb:214`, hard-codes `WorkerEnv.default`) and **a missing route to
get there**. `Subagent::Seam` (`subagent.rb:388-389`) has eleven members and no isolation; `Supervisor`
holds `@isolation` (`supervisor.rb:47`) behind no reader, reachable only from `#adopt`. The first draft
scoped the fix without either file and would have shipped F80 a second time, green. **T9 gains `Seam`
an `isolation:` member and wires it at `toolset_build.rb:256`**, which also covers
`Skill::RoleSpawn`'s construction for free. The stack it then leases from already composes service
isolation — `with_compose(with_databases(journalled(concrete)))` — and `Telemetry::IsolationLease`
already carries `service_provisioned` / `service_torn_down`. Leasing is synchronous, so it never
creates the parked fiber the actor-mode ruling exists to prevent, and `#adopt` is explicitly the wrong
door: it needs a live reactor and would leak a `Registration` per spawn.

The remaining three findings are ordinary fixes: a cockpit swapfile collision (F73, HIGH), two
readers that treat a zero as a measurement (F78), and a wrap nobody can read back (F76).

## Grounding

Verified 2026-08-27 by four parallel explorations against `12e5715c` plus the round-14 working tree.
Line numbers are from that state.

**F79 — the mechanism, end to end.** `AskHuman#emit_question` (`lib/lain/tools/ask_human.rb:532-539`)
writes `causal_parents: [parent.head_digest].compact`, where `parent_timeline` (`:602-604`) resolves
the child's live head — the assistant turn committed at `lib/lain/agent.rb:348` immediately before
`perform_tools` (`agent.rb:410-412`) dispatched the tool. A child's turns reach the record only
through `Middleware::JournalTurns#call` (`lib/lain/middleware/journal_turns.rb:27-31`), which runs
`@scribe.catch_up` **after** `downstream` — i.e. after the whole iteration. A parked ask never returns
from `perform_tools`, so that iteration's catch-up never runs and the cited turn is never promoted.
The parent's own asker (`lib/lain/cli/wiring.rb:269`) uses the identical expression and is safe only
because `CLI::Repl::Ask#record_interruption` (`lib/lain/cli/repl/ask.rb:74-77`) catches the parent up
on a torn ask. **Nothing does that for a child.** `subagent.rb:628-633` already states the contract
this violates. The answer path is the worked example to copy: `Lineage#message`
(`lib/lain/tools/subagent/lineage.rb:57-62`) cites `[spawn.digest, child.head_digest]`, both on the
record, which is why QA's control forked at exit 0.

**F79 — what actually refuses, which the first draft never named.**
`Bench::Session::MessageReplay#resolvable?` (`message_replay.rb:135-137`) is
`cited_parents?(record) && [record["render_parent"], *cited(record)].compact.all? { |d| @store.key?(d) }`,
and `#cited` (`:145`) is `record.fetch("causal_parents", [])`. **`to` is never consulted for
reachability** — it is read once in the whole loader, at `chain_fold.rb:182`, and only for `rewound`
records. `#forced_put` (`:120-124`) is what raises the sentence round 14 saw. So the refusal turns on
`causal_parents` alone, and any card that edits the address leaves it exactly where it was. T6 is
scoped to the edge for that reason; T7 keeps the address change on its own merits.

**F79 — the address exists too, and is worth having for its own sake.** `Lineage#message`
(`lineage.rb:60`) writes
`from: correlation_of(child), to: correlation_of(parent)`; `Lineage#note` (`:71-75`) takes arbitrary
`from:`/`to:`. `AskHuman::HUMAN` (`ask_human.rb:49`) is the literal `"human"` occupying that same
`to:` slot. `Askers#enrol` (`lib/lain/cli/wiring/askers.rb:79-96`) is called for a child at
`lib/lain/tools/subagent.rb:501` inside `ChildBuilder#build`, whose own comment (`:495-496`) explains
enrolment happens there because "nothing above this method can name a child that does not exist yet"
— and that method already holds `parent`. Absence is modelled throughout the gate
(`lib/lain/approval/gate.rb:116`: "an unattended gate must refuse, never wedge").

**F80 — the seam and the blocker.** `Subagent#run_child` (`subagent.rb:213-215`) calls
`build_child(parent, WorkerEnv.default)`; `build_child` (`:217`) threads `worker_env:` into
`ChildBuilder#build` (`:497`) → `spawn_agent` (`:617`) → `Session.new(worker_env:)` (`:624`), and
`Session` really uses it (`lib/lain/session.rb:262`, `:624`, `:631` — path normalisation and tool cwd).
`Isolation::Null#acquire` (`lib/lain/isolation/null.rb:14`) returns
`Lease.new(worker_env: WorkerEnv.default)` — a genuine no-op, so leasing unconditionally costs nothing
under `--isolation none` and **no conditional is needed**. `descend` (`subagent.rb:150-154`) rebuilds
the nested tool from `@builder.config(parent:)` and threads no `worker_env`, so nesting is broken today.
**The actor route is closed** by a recorded panel ruling with a structural reason
(`spec/lain/actor_spec.rb:38-44`): a perform-launched actor parks as `Agent#ask`'s own child and
structured concurrency never lets `ask` return. This chunk does not touch that ruling.

**F78 — two unconditional writes.** `StatusFeed#observe_usage` (`lib/lain/status_feed.rb:307`) replaces
`@occupancy` on every record; `Agent::Accounting#observe` (`lib/lain/agent/accounting.rb:34`) replaces
`@last_turn_usage`. `Usage` has no absence — `#initialize` coerces `Integer(x || 0)`
(`lib/lain/usage.rb:21-29`) and `Usage.zero` is value-equal to a real all-zero response (`:39-41`,
`:69-71`). `ContextWindow::Occupancy` **does** model absence (`Occupancy::None`,
`lib/lain/context_window.rb:270-312`), and `Need::ApproachingWindow` depends on the distinction —
`spec/lain/compaction/need_spec.rb:110-119` pins that `used_tokens: 0` fires at ratio 0.0 where `nil`
does not. `status_feed_spec.rb:669-683` already pins the wanted shape for the `usage: nil` case (a
record derives nothing and leaves the prior occupancy alone); this chunk extends that to all-zero.
**The HUD constrains the fix**: `spec/lain/cli/up_spec.rb:1673-1682` pins that `0.0` renders `ctx:0%`
and only `nil` is silent — so a genuinely empty context must keep rendering `0%`.

**F78 — the producer.** `Ollama::StreamAssembler#build_body`
(`lib/lain/provider/ollama/stream_assembler.rb:149-155`) fabricates `"done" => true` **regardless of
whether a `done:true` frame ever arrived**, emitting `done_reason`/`prompt_eval_count`/`eval_count` as
whatever `#reset` (`:76-87`) left them — `nil`. `Decoding#decode_stop_reason`
(`lib/lain/provider/ollama/decoding.rb:151-160`) then normalises `nil` to `:unknown`, and `#build_usage`
(`:162-164`) yields all zeros, while content accumulated on every frame (`stream_assembler.rb:133-137`).
That is byte-for-byte round 14's observation. There is no guard anywhere that a terminal frame was seen.

**F73.** `SCRATCH_BUFFER = "file lain-cockpit://start"` is at `lib/lain/cli/up/cockpit.rb:90` (the
findings cite `:105`, which has drifted). Argv is assembled at `:92-94`; `#rtp_flag` (`:118-122`) is the
existing precedent for a conditionally-inserted flag pair. Nothing in `lib/` sets `noswapfile`,
`buftype` or `-n` for this nvim. The docstring (`:71-89`) explains the name is load-bearing — it trips
snacks' "buffer has a name" guard — so the fix must keep the name and lose the swapfile. **Every spec
harness passes `-n`** (`spec/lain/frontend/neovim_buffers_spec.rb:30` and five siblings), which is why
no automated test reproduces this. The exact-argv assertion at `spec/lain/cli/up_spec.rb:1446-1449` is
an `eq`, so it is the drift guard any added flag must update.

**F76.** The wrap is a hard cut in Ruby, not nvim: `BODY = /.{1,#{WIDTH - INDENT.length}}/m` at
`lib/lain/frontend/neovim/approval_view.rb:105`, applied at `:397`, with `WIDTH = 96` (`:78`),
`INDENT = "  "` (`:83`). The Lua side (`runtime/62_approval.lua:144-159`) writes the array verbatim and
reflows nothing. `InboxView` carries a byte-identical duplicate (`inbox_view.rb:76`, `:83`, `:88`,
`:99`; applied at `inbox_view/row.rb:131`) — duplicated deliberately, because `neovim.rb`'s manifest
loads `inbox_view.rb` **first**, so a constant reference to `ApprovalView` would resolve before it
exists (`inbox_view.rb:78-82`). **The mid-token break is documented intent**
(`approval_view.rb:89-104`): the bytes are a command a `y` will release, so a word-boundary wrap that
swallowed spaces would show the human something other than what runs. `approval_view_spec.rb:554-557`
states the counter-argument explicitly. So F76 is **not** "stop hard-wrapping" — it is that a reader
cannot reliably reassemble. `runtime/05_records.lua`'s `CONTINUATION` pattern `"^  "` and
`10_folds.lua:65` both depend on the 2-space indent.

**Where docs and code disagreed, and which won.** Round 14's findings cite `cockpit.rb:105` for
`SCRATCH_BUFFER`; the code says `:90` — **code wins**, the finding's line drifted. `method.md:255-261`
carries "run ONE cockpit at a time" as a standing driver rule; that is a workaround for F73 and
**T1 retires it**. `subagents-and-backends.md` §3 frames the `--isolation` question as "the help text
says inert / the wiring is live, one of the two is wrong"; the shipped text no longer says inert
(`exe/lain:991-994`) — **the scenario is stale**, and T11 corrects it.

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only): `lib/lain.rb`, `lain.gemspec`,
  `.rubocop.yml`, `spec/spec_helper.rb`.
- **A new file's manifest line goes in its SUBTREE's index, not in `lib/lain.rb`** — CLAUDE.md's rule
  is that a `foo.rb` beside a `foo/` is that subtree's index. The first draft named `lib/lain.rb` for
  three cards that do not touch it. Verified: `lib/lain.rb` carries **zero** `neovim` and **zero**
  `telemetry/` entries. The real indexes are `lib/lain/telemetry.rb:71-91` and
  `lib/lain/isolation.rb:20-28`; the neovim one is `lib/lain/frontend/neovim.rb:509-524`.
  **Only T5 introduces a new file in this plan**, and its manifest line belongs in
  `lib/lain/telemetry.rb`. That index is **not** orchestrator-owned, so it rides in T5's own commit —
  which CLAUDE.md's same-commit rule (new lib file + manifest line + spec together) requires.
- T1's fix is unreproducible under the spec suite's own harness (seven harnesses pass `-n`). Its
  verification is a composition assertion plus a **named manual check** in Integration checks; do not
  accept "the suite is green" as evidence for it.

## Open decisions

- **The readers-and-writers isolation strategy is CUT from this chunk and owed its own.** The first
  draft carried it as a late wave on the user's explicit request. The panel refuted its premise
  against a recorded ruling: `Tool#requires_approval?`'s docstring (`lib/lain/tool.rb:117-119`) states
  that **"the axis that predicts danger is whether the model controls the command string, not
  read-versus-write"**, and there is no read/write predicate anywhere on `Tool`, `Toolset` or
  `Tool::Input` — verified. So "may this child write" cannot be answered from a spawn's toolset today,
  and the card's own first escalation trigger would have fired on the implementer's first grep. It was
  also the only card in the plan with no grounding paragraph. **It needs its own chunk**, whose first
  question is where a write axis could honestly live — `Effect` and `Sensitivity::Policy` are the
  candidates, since `Tool` deliberately refuses to carry one. T9 leaves the acquisition point it would
  build on.
- **Exposing `mode` on `Subagent::Input` is deliberately NOT in this chunk.** A model-dispatched actor
  is refused for a structural reason (`spec/lain/actor_spec.rb:38-44`): `Agent#ask`'s per-call `Sync`
  owns any fiber a tool dispatch spawns, so a perform-launched actor parks as ask's own child and ask
  never returns. **The plan's first draft over-stated this as "closed by the ruling"** — in fact
  `adopt_actor` refuses only `unless supervisor.running?`, and a chat wires a live `Supervisor`
  (`wiring.rb:184`); what actually closes the route is `Input` carrying no `mode`. Either way this
  chunk delivers subagent isolation without it, synchronously, via T9.
- **Whether a parent that cannot answer should spend a model call deciding to escalate** is settled in
  T8 as "no": the parent relays without a round trip. Revisit only with a measurement.

## Waves

```
Wave 1: T1, T2, T3, T4, T5, T6
Wave 2: T7 (←T6), T9 (←T6)
Wave 3: T8 (←T7), T10 (←T1, T3, T4, T5), T11 (←T9)
Wave 4: T12 (←T8, T9)
```

Critical path: **T6 → T7 → T8 → T12** (depth 4). The first draft ran to depth 5; merging the lease and
its nesting into one card (T9) removed a wave, as the panel argued — `worker_env` is per-dispatch
state threaded through the same `build_child` → `child_union` → `descend` spine, so splitting it gave
two cards one seam and guaranteed a conflict.

T7 depends on T6 and T9 depends on T6 for sequencing as well as substance: T6 and T7 both edit
`ask_human.rb`, and T6 and T9 both edit `subagent.rb`. No two same-wave cards share a file.

## Tasks

### T1 — Give the cockpit's scratch buffer no swapfile           [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/up/cockpit.rb`, `spec/lain/cli/up_spec.rb`
**Reuse:** `#rtp_flag` (`cockpit.rb:118-122`) for the SHAPE of a conditionally-inserted flag pair.
`spec/lain/frontend/neovim/annotate_spec.rb:88` for the SPELLING — it already spawns nvim with
`--cmd "set noswapfile"`, and is simultaneously a live demonstration of the process-wide form this
card must not use.
**Shared-file wiring:** none
**Reachable from:** `CLI::Up#spawn_cockpit_panes` (`lib/lain/cli/up.rb:737-744`) → `respawn-pane` with
`Cockpit#nvim_pane_command` (`cockpit.rb:92-94`). The only nvim argv `lain up` builds.

Two cockpits on two different projects collide on one swap path because the buffer name is a constant
(`$XDG_STATE_HOME/nvim/swap/lain-cockpit:%%start.swp`). The modal blocks before nvim serves RPC, so
`lain://approval` and `:LainApprove` are unreachable while the chat pane looks healthy. **Keep the
name** — `SCRATCH_BUFFER`'s docstring (`:71-89`) explains it is what trips snacks' "buffer has a name"
guard — and lose the swapfile, **scoped to that buffer**.

**Acceptance criteria:**

```gherkin
Scenario: the cockpit's scratch buffer is told not to write a swapfile
  Given a cockpit pane command is composed for a project
  When the nvim argv is read
  Then the swapfile is disabled for that buffer
  And the disabling is scoped to the buffer rather than to the whole nvim process

Scenario: the buffer keeps the name snacks' guard reads
  Given the composed argv
  When the scratch buffer command is read
  Then it still starts with "file " and still carries the lain-cockpit:// scheme
  And it does not carry the lain:// scheme the runtime's fallback scan claims
```
→ spec file: `spec/lain/cli/up_spec.rb` (the `"--nvim cockpit composition"` group, `:1407+`; the exact
`eq` at `:1446-1449` must be updated in the same edit)

**Escalation triggers:**
- **`set noswapfile` is process-wide, exactly like `-n`.** A global-local option set with `set` rather
  than `setlocal` disables swap for every file a human later opens in the review tab, silently. If the
  implementation reaches for `--cmd 'set noswapfile'` or a bare `-c 'set noswapfile'`, stop — the
  scoped forms are `-c 'setlocal noswapfile'` **after** the `:file` (which re-derives the swap path on
  rename), or `setlocal buftype=nofile`.
- If `buftype=nofile` is chosen, CLAUDE.md records that nvim then refuses `:write` on that buffer
  (`E382`). Confirm nothing writes the scratch buffer before taking that route.
- The `eq` at `up_spec.rb:1446-1449` asserts the full argv. If updating it makes the rtp-ordering
  example at `:1494-1500` fail, the flag went in the wrong position — stop, do not reorder
  `--cmd`/`--listen` to suit it.
- If the snacks dashboard reappears over the cockpit, the name guard is broken; stop and report which
  half of `SCRATCH_BUFFER` did it.

### T2 — Give a reader the approval command unwrapped              [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/frontend/neovim/runtime/62_approval.lua`,
`lib/lain/frontend/neovim/approval_view.rb`, `lib/lain/frontend/neovim/rpc_thread.rb`,
`spec/lain/frontend/neovim_runtime_spec.rb`
**Reuse:** `62_approval.lua:146-147` already sets `b:lain_view_generation` and `b:lain_approval_rows`
via `vim.b[buf].name = value` — follow that idiom exactly. `ApprovalView::Rendering`
(`approval_view.rb:372-378`) already carries `lines:` and `owners:` alongside each other.
**Shared-file wiring:** none
**Reachable from:** `ApprovalView#rendering_of` → `RpcThread#set_approval` (`rpc_thread.rb:438-440`)
→ the `SET_APPROVAL` lua payload (`rpc_thread.rb:132-133`) → `_G.__lain.set_approval`
(`62_approval.lua:144-159`), on the live cockpit render path.

**The hard wrap stays and no rendered byte changes.** `approval_view.rb:89-104` rules it: the bytes
are a command a `y` releases, so a word-boundary wrap that moved spaces would show the human something
other than what runs, and `approval_view_spec.rb:554-557` restates that. F76 is not "stop wrapping" —
it is that **a reader cannot get the command back**. `neovim_runtime_spec.rb:487-489` is the live
proof: it does `buffer_lines("lain://approval").join`, which leaves the 2-space `INDENT` embedded
mid-token, so a substring match misses. Publish the unwrapped calls as a buffer variable beside the
row count. The display is unchanged; the reader gets an authoritative copy.

**Acceptance criteria:**

```gherkin
Scenario: a reader can recover a wrapped command without reassembling lines
  Given a parked approval whose command is longer than the display width
  When the approval buffer is rendered
  Then a buffer variable carries that command in full, unwrapped
  And reading it does not require stripping an indent or joining lines

Scenario: the rendered lines are byte-identical to before this card
  Given the same parked approval
  When its buffer lines are read
  Then they are wrapped exactly as they were, at the same column, mid-token

Scenario: the unwrapped calls line up with the answerable rows
  Given two parked approvals
  When the buffer variables are read
  Then there is one unwrapped call per answerable row, in the same order
```
→ spec file: `spec/lain/frontend/neovim_runtime_spec.rb` (live nvim; the group around `:485-493`,
whose `approve_in_editor` helper is the reader F76 was filed about)

**Escalation triggers:**
- **If this card changes any rendered byte, it has overshot.** `inbox_view_spec.rb:782` pins
  `lines.first.length == WIDTH` and `approval_view_spec.rb:578-596` asserts the Ruby `INDENT` equals
  `05_records.lua`'s `CONTINUATION` pattern by reading the Lua source. Both must pass untouched.
- `runtime/10_folds.lua:65` and `05_records.lua`'s `"^  "` both key on the indent and the record
  boundary. If publishing a variable changes how rows are counted, folding breaks — stop.
- `neovim_runtime_spec.rb:855` asserts the runtime entry string contains `__lain.set_approval` and
  `b:lain_approval_rows`. A new variable must join that assertion, not replace either name.
- If `InboxView` turns out to have the same reader problem, **do not widen this card** — file it, and
  say so in the findings. The two views duplicate their constants deliberately for a load-order reason
  (`inbox_view.rb:78-82`) and unifying them is not this card's job.

### T3 — A zero occupancy reading is absence, not a measurement, on the feed   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/status_feed.rb`, `spec/lain/status_feed_spec.rb`
**Reuse:** **`Usage#zero?` (`lib/lain/usage.rb:39-41`)** — the predicate already exists, implemented as
`self == self.class.zero` against the frozen `ZERO` (`:69`). Use it rather than spelling a new one;
T4 uses the same predicate, and a second spelling is how the two drift. `#start_empty`'s stated
principle (`status_feed.rb:187-188`, "absence where absence is the honest answer") and the existing
`usage.nil?` guard at `:302`, whose pin (`status_feed_spec.rb:669-683`) is the shape to extend.
**Shared-file wiring:** none
**Reachable from:** `CLI::Wiring` constructs the feed and tees it onto the journal; `#observe_usage`
runs on every `Telemetry::TurnUsage` on the live chat path. `#observed` (`:398-400`) publishes
`"occupancy"` to `state.json`, read by `CLI::Up::Hud` (`hud.rb:69`) and `plugin/tmux/scripts/lain-status:68`.

A `turn_usage` whose usage is entirely zero overwrites a real occupancy with `0.0`, while `run_tokens`
(an accrual) keeps its value — so the feed remembers the tokens and forgets the occupancy.

**`@occupancy` has exactly two writers** — `start_empty` (`:192`, nil) and `observe_usage` (`:307`) —
so suppressing the zero write means **this producer can no longer publish `0.0` at all**. That is the
intended outcome and the card must say so: a real provider always bills a system prompt, so a genuinely
all-zero input reading does not occur in practice; what occurred was T5's truncated stream. The HUD's
`0.0`-renders-`ctx:0%` behaviour (`up_spec.rb:1673-1682`) stays correct **as a renderer contract** and
is simply no longer exercised from here.

**Acceptance criteria:**

```gherkin
Scenario: a zero-usage record leaves the last real occupancy standing
  Given a feed that has observed a turn at half the window
  When it observes a turn whose usage is entirely zero
  Then the published occupancy is still one half

Scenario: the zero-usage turn's tokens are still accrued
  Given the same feed
  When it observes that zero-usage turn
  Then the published run tokens have not been reduced by it

Scenario: absence before any turn is unchanged
  Given a feed that has observed nothing
  When its state is published
  Then the occupancy is absent rather than zero

Scenario: the renderer still distinguishes a zero from an absence
  Given a published state whose occupancy is zero
  When the HUD renders it
  Then it shows a zero percentage rather than nothing
```
→ spec file: `spec/lain/status_feed_spec.rb` (the occupancy group, `:600-742`); the fourth scenario
already exists at `spec/lain/cli/up_spec.rb:1673-1682` and must be left passing, not rewritten.

**Escalation triggers:**
- **After this card, does any producer still publish occupancy `0.0`?** If the answer is no and that
  is a surprise to the implementer, stop — the card intends it, and `up_spec.rb:1673-1682` plus
  `tmux_plugin_spec.rb:110-155` become renderer-only guards. If either is *deleted* rather than left
  standing, that is the wrong response.
- `spec/lain/seams/window_self_correction_spec.rb:266-267` asserts `agent.occupancy` equals the
  published occupancy. T3 and T4 must land the same policy; if this card alone makes that seam fail,
  stop and coordinate rather than adjusting the seam spec.
- If `Usage#zero?` turns out to be the wrong predicate because a turn can legitimately bill output but
  no input, stop and say so — that is a different rule than either card assumes.

### T4 — A zero last-turn usage is absence, not a measurement, in Accounting   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/agent/accounting.rb`, `spec/lain/agent/accounting_spec.rb`
**Reuse:** **`Usage#zero?` (`lib/lain/usage.rb:39-41`)** — the same predicate T3 uses; a second
spelling here (`total_input_tokens.zero?`, which ignores output) is the drift T3's trigger fears.
The attribute's own docstring (`accounting.rb:44-52`) already names the hazard; make the setter obey
the getter's contract. `ContextWindow::Occupancy::None` (`context_window.rb:270-303`) is the shape
absence already takes downstream.
**Shared-file wiring:** none
**Reachable from:** `Agent#commit_and_account` (`lib/lain/agent.rb:352`) calls `#observe` on every
committed turn; `#last_turn_usage` is read by `Agent#occupancy` (`agent.rb:248`) and by
`#render_request` (`agent.rb:406`), which feeds `Compaction::Source#context_for`.

**Compaction's own input.** After a zero-usage turn the loop currently believes the context is empty,
so `Need::ApproachingWindow` cannot fire until a real reading arrives.

**Acceptance criteria:**

```gherkin
Scenario: a zero-usage response leaves the last real reading standing
  Given accounting that has observed a response reporting input tokens
  When it observes a response whose usage is entirely zero
  Then the last turn usage is still the earlier response's input tokens

Scenario: the cumulative total still counts the zero-usage turn
  Given accounting that has observed one response
  When it observes a zero-usage response
  Then the cumulative usage has folded in both responses

Scenario: the turn is still journaled even though its reading is not taken
  Given accounting observing a zero-usage response
  When the record is written
  Then a turn usage record is still journaled for that turn

Scenario: absence before any turn is unchanged
  Given fresh accounting
  When nothing has been observed
  Then the last turn usage is absent rather than zero
```
→ spec file: `spec/lain/agent/accounting_spec.rb` (extends the group at `:74-88`)

**Escalation triggers:**
- `spec/lain/compaction/need_spec.rb:110-119` deliberately pins that `used_tokens: 0` **fires**
  `ApproachingWindow` at ratio 0.0 where `nil` does not. If this card makes a genuinely-zero context
  stop firing, stop — that distinction is being preserved, not removed.
- `spec/lain/compaction/source_spec.rb:437-462` pins that a resumed session does not force-compact on
  turn one, distinguishing unknown occupancy from a measured zero. A failure there means absence and
  zero have been conflated at the wrong layer.
- The turn was paid for and the record is the experiment's. If suppressing the *reading* also
  suppresses the `turn_usage` **record**, stop — that is scenario 3 and it is not negotiable.

### T5 — Say whether the stream ever terminated, instead of fabricating it   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/provider/ollama/stream_assembler.rb`, `lib/lain/provider/ollama.rb`;
create `lib/lain/telemetry/truncated_stream.rb`;
create `spec/lain/telemetry/truncated_stream_spec.rb`; modify
`spec/lain/provider/ollama/stream_assembler_spec.rb`
**Reuse:** `Telemetry::MalformedResponse` is the precedent for "the provider did something the loop
should record rather than swallow" — round 14 confirmed it fires and names the tool. Follow its record
shape and `Journalable` inclusion; `Carriers::*` (`telemetry/turn_stream.rb:17-22`) is the validation
idiom. `Provider::Ollama`'s `@journal` (`ollama.rb:216`) is the channel `RequestSent` already rides.
**Shared-file wiring:** the manifest line goes in **`lib/lain/telemetry.rb`** (`:71-91`), that
subtree's own index — **not** `lib/lain.rb`, which carries no `telemetry/` entries. Per CLAUDE.md's
same-commit rule it lands in this card's commit alongside the new file and its spec.
**Reachable from:** `Provider::Ollama#stream_body` (`ollama.rb:447-451`) calls `assembler.result` on
every streamed turn and holds the journal; the emission belongs there, not in the assembler, which
takes no arguments and holds no channel.

`#build_body` (`stream_assembler.rb:149-155`) fabricates `"done" => true` **whether or not a terminal
frame arrived**, so a truncated stream is indistinguishable from a complete one and decodes to
`:unknown` plus all-zero usage with the content intact. T3 and T4 harden the readers; **this card makes
the producer say what happened**, so the next occurrence is diagnosable rather than seen once and lost
— which is exactly what round 14 could not do.

**Acceptance criteria:**

```gherkin
Scenario: a stream that never terminated is recorded as truncated
  Given content frames arrive and no terminal frame ever does
  When the turn completes
  Then a truncated-stream record is journaled naming the frame count and the bytes accumulated

Scenario: the content that did arrive still reaches the caller
  Given the same truncated stream
  When the response is built
  Then it still carries the content the frames delivered

Scenario: a stream that terminated normally records nothing
  Given content frames followed by a terminal frame carrying token counts
  When the turn completes
  Then no truncated-stream record is journaled

Scenario: a terminal frame with no token counts is recorded too
  Given a terminal frame whose prompt and eval counts are absent
  When the turn completes
  Then a truncated-stream record names that the counts were absent
```
→ spec files: `spec/lain/telemetry/truncated_stream_spec.rb` (the record),
`spec/lain/provider/ollama/stream_assembler_spec.rb` (the detection and the emission)

**Escalation triggers:**
- **`StreamAssembler#reset` must not raise** — its contract at `:70-76` says so explicitly:
  `RetryTap#retry_block` abandons before it journals, so an exception there loses that attempt's
  `Telemetry::ProviderRetry`. A "saw a terminal frame" flag must be a literal assignment in `#reset`
  and stay one. If it needs anything more, stop.
- `ollama.rb:437-449` registers `assembler.reset` per attempt, and QA measured that a mid-stream sever
  is cleanly **retried**. If a superseded attempt emits a truncated-stream record, the record is noise
  — scope it to the attempt actually returned.
- Round 14's observation was a **content-bearing** turn. If this card makes a truncated stream return
  nothing, it has converted a silent accounting bug into a lost answer — stop.
- Output discipline: the record reaches a `Lain::Channel`, never `$stderr`
  (`spec/output_discipline_spec.rb`).

### T6 — A parked question cites an edge the record already carries   [wave 1] [risk: high]

**Depends on:** none
**Files:** `lib/lain/tools/ask_human.rb`, `lib/lain/tools/subagent.rb`,
`spec/lain/tools/ask_human_spec.rb`, `spec/lain/tools/subagent_spec.rb`
**Reuse:** **`Lineage#message` (`lib/lain/tools/subagent/lineage.rb:57-62`) is the worked example** —
it cites `[spawn.digest, child.head_digest]`, both already on the record, which is why the answered
path forks at exit 0. `Subagent::TurnFeed#catch_up` (`subagent/turn_feed.rb:45-51`) is the child's
existing promoter and is idempotent (it walks from `@stop`; an empty walk is the caught-up case).
`CLI::Repl::Ask#record_interruption` (`repl/ask.rb:74-77`) is what does this for the parent and is the
shape to mirror.
**Shared-file wiring:** none
**Reachable from:** `AskHuman#perform` (`ask_human.rb:482-489`) on the live child dispatch; the asker
is enrolled for a child at `ChildBuilder#build` (`subagent.rb:497-503`), the only place that can name
a child, and the only place that can hand the asker anything more than a timeline thunk.

**This is the F79 fix, and it is at `causal_parents`, not at the address.** `#emit_question`
(`ask_human.rb:532-537`) cites `parent.head_digest` — the child's live head, committed at
`agent.rb:348` just before `perform_tools` dispatched the tool. A child's turns reach the record only
via `Middleware::JournalTurns#call` (`journal_turns.rb:27-31`), which runs `catch_up` **after**
`downstream`; a parked ask never returns from `perform_tools`, so that iteration's catch-up never runs
and the cited turn is never promoted. Either flush the child's feed before the question is written, or
cite an edge already on the record as `Lineage#message` does. **Both routes require the enrolment site
to hand the asker more than it does today**, which is why `subagent.rb` is in Files.

**Acceptance criteria:**

```gherkin
Scenario: every digest a parked question cites is already on the record
  Given a subagent that parks a question mid-iteration
  When the question record is written
  Then every causal parent it cites resolves against a record the journal already carries

Scenario: a session whose subagent parked a question can be forked
  Given a session in which a subagent parked a question and it was never answered
  When the session is forked at its head
  Then the fork succeeds

Scenario: the same session can be resumed
  Given that session
  When it is resumed
  Then the resume succeeds

Scenario: the answered path is unchanged
  Given a subagent whose question was answered and which settled normally
  When the session is forked
  Then it succeeds as it did before this card
```
→ spec files: `spec/lain/tools/ask_human_spec.rb` (the citation — no spec pins
`last_question.causal_parents` today, so this card creates that pin),
`spec/lain/tools/subagent_spec.rb` (the fork/resume pair, extending `:1048-1090`, which covers only
the **answered** path today)

**Escalation triggers:**
- **`Bench::Session::MessageReplay` is the object that produces the refusal.** Its `#resolvable?`
  (`message_replay.rb:135-137`) consults `render_parent` and `causal_parents` and nothing else — `to`
  is never read for reachability. **If after this card the question record's `causal_parents` still
  names a digest no journal record carries, the card is at the wrong field.** Re-read
  `spec/lain/bench/session/message_replay_spec.rb:148` before changing anything else.
- If flushing the child's feed before the question means calling `catch_up` from inside a tool
  dispatch, confirm it cannot re-enter `JournalTurns` — a nested catch-up mid-iteration is a different
  hazard than the one being fixed, and `turn_feed.rb`'s `@stop` is the only guard.
- `subagent.rb:628-638`'s comment states the per-iteration feeding intent and why per-settle would be
  wrong. If this card's fix amounts to feeding per-settle, stop — that is the alternative that comment
  already rejects.

### T7 — A child addresses its parent                              [wave 2] [risk: medium]

**Depends on:** T6 (both edit `ask_human.rb`; T6 lands the citation fix first)
**Files:** `lib/lain/tools/ask_human.rb`, `spec/lain/tools/ask_human_spec.rb`
**Reuse:** `Lineage#message` (`lineage.rb:60`) already writes
`from: correlation_of(child), to: correlation_of(parent)` — agent-to-agent addressing exists and this
is its spelling. `Event::ChainWriter.correlation_of` (`chain_writer.rb:33-36`) is already the
question's `from:`.
**Shared-file wiring:** none
**Reachable from:** `AskHuman#perform` (`ask_human.rb:482-489`); the child's asker enrolled at
`subagent.rb:501`. The run's own asker (`wiring.rb:269`) is unchanged.

**This is NOT the F79 fix and the plan no longer claims it is** — T6 is. `to:` is never consulted for
reachability. This card is worth doing on its own merits: a child currently addresses the literal
`"human"` (`ask_human.rb:49`), reaching past the parent that spawned it, so the record cannot say who
a question was actually put to, and there is no place for a parent to answer one. It gives the
escalation chain in T8 something to stand on.

**Acceptance criteria:**

```gherkin
Scenario: a child's question is addressed to its parent
  Given a subagent enrolled under a parent chain
  When the child asks a question
  Then the question record's recipient is the parent's correlation
  And it is not the literal human address

Scenario: the run's own asker still addresses the human
  Given the top-level agent's asker
  When it asks a question
  Then the recipient is the human address, unchanged

Scenario: the human is still told which role is asking
  Given a child enrolled under a named role
  When the question is announced
  Then the announcement names that role
```
→ spec file: `spec/lain/tools/ask_human_spec.rb`

**Escalation triggers:**
- T6's fork/resume ACs must still pass after this card. If re-addressing breaks them, the two cards
  have collided on the same record and the citation fix has been disturbed.
- `ask_human.rb:516` writes the answer with `from: HUMAN`. If changing the question's recipient leaves
  the answer's sender inconsistent with it, stop — the pair is one conversation and must stay legible.
- The notifier renders `"#{agent} asks"` clamped to `NAME_WIDTH = 19` (`askers.rb:23`). If routing
  through the parent changes who the human is told is asking, stop: the human must learn which role
  asked, not which parent relayed.

### T8 — The parent relays, and an unattended run refuses          [wave 3] [risk: high]

**Depends on:** T7
**Files:** `lib/lain/tools/ask_human.rb`, `spec/lain/tools/ask_human_spec.rb`
**Reuse:** T7's parent address. The **`unattended`** vocabulary already runs through the approval gate
(`lib/lain/approval/gate.rb:116`: "an unattended gate must refuse, never wedge") — reuse that word
rather than inventing a second one for "the human is not here".
**Shared-file wiring:** none
**Reachable from:** `AskHuman#perform` (`ask_human.rb:482-489`) on the live child dispatch; the
escalation reaches the human through the same `Askers` registry the main agent's asker uses
(`wiring.rb:269`).

With T7 a child asks its parent. This card gives that address meaning: the parent **relays** and owns
the escalation, so the human answers a question the parent is accountable for. Per Open decisions the
parent does not spend a model call deciding — it relays. The value is that the chain is explicit and
journaled, and that the human is the end of it rather than a peer of it.

**Acceptance criteria:**

```gherkin
Scenario: a child's question reaches the human through its parent
  Given a child that has addressed a question to its parent
  When the question is escalated
  Then the human is asked
  And the record shows the child asked the parent and the parent asked the human

Scenario: an unattended run refuses the escalation rather than parking forever
  Given a run with no queue for the human to answer from
  When a child escalates a question
  Then the escalation is refused by name
  And the child receives that refusal as its answer rather than waiting

Scenario: the escalation names the originating role
  Given a child enrolled under a named role
  When its question reaches the human
  Then the human is told which role originally asked
```
→ spec file: `spec/lain/tools/ask_human_spec.rb`

**Escalation triggers:**
- **If relaying requires the parent to be mid-dispatch for the question to be answerable, stop** — that
  reintroduces F79's shape one level up, where the parent's own head is the unjournaled turn. T6's
  fork/resume ACs are the regression check and must still pass.
- `ask_human_spec.rb:630`, `:702`, `:794` pin the answer and unanswered records, including
  `answer.causal_parents == [asked.digest]`. If the relay inserts a record between question and answer
  that breaks that, stop and confirm the intended chain shape before rewriting those pins.
- Round 14's F64: a docent that parks an `ask_human` strands its thread pane. If this card changes who
  a docent's question is addressed to, that is out of scope — stop and report.

### T9 — A spawned child runs in a leased environment, nesting included   [wave 2] [risk: high]

**Depends on:** T6 (both edit `subagent.rb`; T6 lands first)
**Files:** `lib/lain/tools/subagent.rb`, `lib/lain/cli/wiring/toolset_build.rb`,
`spec/lain/tools/subagent_spec.rb`, `spec/lain/cli/wiring_spec.rb`
**Reuse:** `build_child(parent, worker_env)` (`subagent.rb:217`) already threads a `worker_env` to
`Session.new(worker_env:)` (`:624`), and `Session` really uses it (`session.rb:262`). `Seam`
(`subagent.rb:388-389`) is the Data whose members are already the child's injected collaborators, and
every one after `parent` already defaults to a Null — `Isolation::Null` (`isolation/null.rb:14`)
returns a default-env lease, so an unisolated run needs **no conditional**.
**Shared-file wiring:** none
**Reachable from:** `exe/lain chat --isolation` → `CLI::Wiring#fleet_isolation` (`wiring.rb:236`) →
`ToolsetBuild#spawn_seam` (`toolset_build.rb:256-262`) → `Seam` → `Subagent#run_child`
(`subagent.rb:213-215`) on every model-dispatched spawn. **Adding `isolation:` to `Seam` also covers
`Skill::RoleSpawn`'s construction (`role_spawn.rb:57`) for free**, since it builds from the same seam.

**The route does not exist today and that is half the card.** `Seam` has eleven members and no
isolation; `Supervisor` holds `@isolation` (`supervisor.rb:47`) behind no reader, reachable only from
`#adopt`. The first draft of this plan scoped the fix without either file and would have shipped F80
again, green. **Nesting is the same seam, not a second card**: `worker_env` is per-dispatch state
threaded through `build_child` → `child_union` (called `:500`, defined `:604`) → `descend` (`:150`),
so splitting it would give two cards one spine and guarantee a conflict.

**Acceptance criteria:**

```gherkin
Scenario: the REAL wiring leases, not an injected backend
  Given a chat wired by CLI::Wiring with the worktree backend selected by --isolation
  When that wiring's own subagent tool spawns a child
  Then an isolation lease is journaled naming the concrete worktree backend
  And the child resolves relative paths against the leased checkout

Scenario: the lease is released when the dispatch ends, and when it fails
  Given a spawn that acquires a lease
  When the child returns, or raises
  Then the lease has been released in both cases

Scenario: a nested child does not escape its parent's isolation
  Given a spawned child running in a leased directory
  When that child spawns a child of its own
  Then the grandchild's working directory is neither the host's nor its parent's

Scenario: an unisolated run is unchanged
  Given a run with no isolation backend configured
  When a subagent is spawned
  Then it runs in the host working directory as before
```
→ spec files: `spec/lain/cli/wiring_spec.rb` (scenario 1 — extending `:985-1085`, the only group that
drives the really-wired supervisor; it must go through **the tool**, not the hand-rolled
`WiringSpecWorker`), `spec/lain/tools/subagent_spec.rb` (the rest)

**Escalation triggers:**
- **Do not route through `supervisor.adopt`.** `#adopt` (`supervisor.rb:105-113`) needs a live reactor,
  raises `NotRunning` without one, and appends a `Registration` that a one-shot dispatch would never
  deregister — leaking a registry row and a lease into `#stop` and `#reap_crashed` on every spawn.
  Acquire from the backend directly. The card's Reuse deliberately does **not** name `#launch_actor`
  for this reason.
- **Scenario 1 must not use a double.** F80 existed *because* every spec injected its own backend while
  production passed `WorkerEnv.default`. A card proving only that an injected backend leases ships the
  same gap again, green. If it cannot be written against the real wiring, stop — that means the route
  is still missing.
- Scenario 3 must distinguish the fix from the bug: a second ordinary `acquire` from the same
  host-rooted `Worktree` yields a **sibling** checkout, which is "not the host's" while not being
  nested. **Assert against the parent's leased path, not against the host's.**
- `Isolation::Worktree#acquire` is `Monitor`-serialized and refuses an already-leased path
  (`worktree.rb:101`). `#fan_out` (`subagent.rb:119-123`) dispatches siblings concurrently through
  `Stagger`; if siblings contend for one worker id, the id allocation is the bug, not the refusal.
- Whether a worktree-of-a-worktree branches from the parent or is a sibling from the host root is a
  **design decision this plan has not taken**. `Worktree` shells `add` against a fixed repo root
  (`worktree.rb:98-108`). Settle it with the orchestrator before implementing, not at 2am in a worktree.
- A backend must be wrapped **exactly once**, nearest the concrete (`isolation_backend.rb:126`,
  `isolation/journal.rb:18-20`). If this card wraps again, every transition double-journals.

### T10 — Retire the driver rules that stood in for these fixes    [wave 3] [risk: low]

**Depends on:** T1, T3, T4, T5
**Files:** `planning/qa/method.md`, `planning/qa/scenarios/failure-injection.md`
**Reuse:** the findings' own wording for each; `method.md`'s existing structure.
**Shared-file wiring:** none
**Reachable from:** documentation card — no production construction, named as such deliberately.
`method.md:255-261` currently instructs every driver to run one cockpit at a time as a workaround for
F73, and that instruction outlives the defect unless a card removes it.

**Acceptance criteria:**

```gherkin
Scenario: the one-cockpit-at-a-time workaround is retired with its defect
  Given the cockpit swapfile fix has landed and its manual check has passed
  When the standing method is read
  Then it no longer instructs a driver to run only one cockpit
  And it records that the constraint was removed and when

Scenario: the zero-usage case is documented as a checked invariant
  Given the hardened readers and the truncated-stream record
  When failure-injection's record-integrity section is read
  Then it names the zero-usage case, the record that now reports its producer, and how to drive both
```
→ spec file: none (documentation). Verified by the Integration checks' doc pass.

**Escalation triggers:**
- **T1 is a dependency, not a trigger.** If T1 has landed but the manual two-cockpit check in
  Integration checks has not been run, do not retire the rule — the rule is the only protection while
  the fix is unverified.
- `spec/lain/comment_census_spec.rb` reads scope out of `CLAUDE.md`. If editing these docs trips it, a
  doc a spec parses has been touched — stop.

### T11 — Say what `--isolation` now does                          [wave 3] [risk: low]

**Depends on:** T9
**Files:** `exe/lain`, `spec/lain/cli/chat_flags_spec.rb`,
`planning/qa/scenarios/subagents-and-backends.md`
**Reuse:** the existing `desc:` at `exe/lain:991-994` and the comment above it at `:986-990`, which
claims "only an actor-mode subagent leases from it" — the fact T9 changes.
**Shared-file wiring:** none
**Reachable from:** `exe/lain`'s `chat` command declaration — the operator-facing surface read by
`lain help chat`.

With T9 a chat's spawned subagents lease. The help text, the comment above it, and
`subagents-and-backends.md` §3 (which still frames the question as open) all describe the pre-T9 world.

**Acceptance criteria:**

```gherkin
Scenario: the flag describes leasing by spawned subagents
  Given the chat command's isolation option
  When its description is read
  Then it says spawned subagents lease from it
  And it still says the main chat's own session is never isolated
  And it still names every available backend
```
→ spec file: `spec/lain/cli/chat_flags_spec.rb` (extends the group at `:227-262`)

**Escalation triggers:**
- `chat_flags_spec.rb:238-245` asserts the text does **not** match `/inert|no chat path|does nothing/i`,
  with a comment explaining that "inert" described the resolver's caller count and not the flag's
  effect. That guard must survive; if the new wording trips it, the wording is wrong.
- If T9 has not landed, this card must not run — describing leasing that does not happen is worse than
  the current text.

### T12 — Pin the round's two session-killers against regression   [wave 4] [risk: medium]

**Depends on:** T8, T9
**Files:** `planning/qa/scenarios/failure-injection.md`,
`planning/qa/scenarios/subagents-and-backends.md`
**Reuse:** `failure-injection.md` §3's four-door table (`--fork`, `--resume`, the bench, the
supervisor) is the shape; this adds the **healthy** case that must not refuse.
**Shared-file wiring:** none
**Reachable from:** documentation card — the manual bench. Named because round 14 found F79 only by
driving a spawn by hand: every existing fixture either answers the question
(`subagent_spec.rb:1048-1090`) or hand-builds the records (`resume_spec.rb:1249-1262`), so the suite
structurally could not have caught it.

**Acceptance criteria:**

```gherkin
Scenario: the bench drives fork and resume on a session with a PARKED question
  Given failure-injection's record-integrity section
  When it is read
  Then it names a spawn that parks a question as a case to drive
  And it states that both doors must exit zero, with the answered spawn as the control

Scenario: the bench confirms a spawned child leased, from a chat
  Given the subagents-and-backends scenario
  When its isolation section is read
  Then it names how to confirm a spawned child leased using the lease records
  And it no longer frames the isolation question as open
```
→ spec file: none (documentation). Verified by the Integration checks' manual pass.

**Escalation triggers:**
- If, when writing the reproduction, `--fork` on a parked-question session **still refuses**, stop and
  reopen F79 — this card documents a fix and must not describe one that is not there. T6's own ACs
  should already have caught it; this is the second net.
- `subagent_spec.rb:1048-1090` covers the answered path only. T6 adds the parked case as a unit pin; if
  writing this card shows the manual reproduction is redundant, say so — a suite pin is better than a
  manual one and the doc should point at it rather than duplicate it.

## Integration checks

After the last wave:

1. **Full suite**: `bundle exec rake pspec`. Check the **example count** against the pre-chunk
   baseline, not just the failure count — `parallel_tests` reports only survivors (CLAUDE.md).
2. **Lints**: `bundle exec rubocop` (bare, never naming a `.toml`), `bin/comment-census
   --check-tickets`, `pre-commit run --all-files`.
3. **Rust untouched** — `git diff --stat ext/ crates/` must be empty; nothing here reaches it.
4. **The manual check T1 cannot automate**, because seven spec harnesses pass `-n` and the suite
   structurally cannot reproduce F73: bring up **two concurrent cockpits on two different projects**
   and assert the second's nvim answers `--remote-expr '1+1'` within 15s, its pane carries no `E325`,
   and `$XDG_STATE_HOME/nvim/swap/` holds no `lain-cockpit*` entry. **T10 must not land until this
   passes.** Then confirm the negative the fix must not buy: open a real file in the review tab and
   check it still gets a swapfile — the scoping is the point.
5. **The manual check T9 needs**: from a real chat launched `--isolation worktree`, spawn a subagent
   and confirm `isolation_lease` records appear naming `Isolation::Worktree`, that `git worktree list`
   shows a checkout while the dispatch is live and none after, and that a nested spawn lands somewhere
   that is neither the host nor its parent.
6. **The F79 end-to-end, which is the round's headline**: drive a spawn that **parks** a question, then
   run both `lain chat --fork SESSION@HEAD` and `lain chat --resume SESSION` and require **exit 0**
   from both — with an **answered** spawn as one control and a **never-spawned** session as the other.
   Round 14's evidence is the regression baseline: both doors exited 1, identically, at every fork
   point.
7. **Regression gate** from `planning/qa/README.md`: `failure-injection` + `session-and-window` +
   `repl-commands` + `epic-tier` + `survey` + `prompt-slots-and-roles`.
