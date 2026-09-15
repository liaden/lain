# Round 18 research: REPL commands, the cockpit and the TTY surfaces

Read against `main` at `90f081b9`. I only read code, `git log`/`git show` and planning docs. Nothing was
run. "Chunk" means `planning/specs/chunk-qa-round17-the-record-the-human-the-window.md`, and a line
number after "chunk:" points into that file. Where I found something by reading code that no fork
drove, it is marked **(code read, not driven)**.

---

## F132: `/fork` and `/btw` start the child on Anthropic

### 1. Mechanism

The finding is correct, with two things to add.

- `lib/lain/cli/command/fork.rb:128` builds the window command as
  `PaneCommand.call("chat", "--fork", selector)`. `btw.rb:53-54` adds `--btw` and `--prompt`.
  `btw.rb:90`, the fallback line it prints for the human to run, carries no backend flags either.
- `PaneCommand` passes on an explicit allowlist, `PANE_ENV` (`pane_command.rb:27-32`, emitted at
  `:151-156`). That list includes `LAIN_PROVIDER`, `LAIN_MODEL`, `LAIN_API_BASE`, `LAIN_NUM_CTX` and
  `LAIN_NUM_BATCH`. So the defect shows only when the backend came from **argv**. A session whose
  provider came from `LAIN_PROVIDER` would fork correctly.
- `--provider` defaults to `EnvDefaults.string("LAIN_PROVIDER", "anthropic")` (`exe/lain:742`).
- The child's `--fork` sees the mismatch and continues anyway. `Resume::MismatchNotices`
  (`cli/resume/mismatch_notices.rb:32-51`, called from `resume.rb:190-192`) prints
  "recorded with …; continuing with … (the current flags win)".
- **Addition 1: the finding's "one method shared with `FleetWindows`" is not needed.** FleetWindows
  runs `lain watch <digest>` (`fleet_windows.rb:70`, `:393`), which takes no backend. The code that
  already carries a chat's flags into a pane is `lain up`'s `@chat_args` (`up.rb:781`, `:854`, `:957`),
  which the running chat never receives.
- **Addition 2: "`--fork` defaults to the recorded backend" cannot work from today's chat header.**
  `SessionRecord.header` (`session_record.rb:44-51`) records `model` and `extra`, but not `provider`,
  `api_base` or `num_ctx`. Only `Bench::Session.write` threads `provider` (`bench/session.rb:171`). A
  forked chat session would therefore read "recorded with provider unrecorded", which is
  `mismatch_notices.rb:46`.
- Other flags a composed child also loses, from reading `PANE_ENV`: `--exec`, `--isolation`,
  `--context-pipeline`/`--compact-strategy` (none has an env default in that list), `--auto-approve`
  and `--secret-oracle`. Losing the last two fails safe.

### 2. Most recent change

The round-17 chunk did not touch either file. `git log` on `fork.rb`:

| commit | change |
|---|---|
| `11547cda` (2026-09-13) | `PaneCommand` promoted out of `Up` |
| `c90e0435` (2026-08-23) | door refusal wording |
| `8cb3ee0a` (2026-07-23) | `/fork` created |

`btw.rb` was created in `c9b5550c` (2026-07-23). The "current flags win" policy came from `eb2924e0`
and `f9ca95fa` (2026-07-16/17).

### 3. Why it is this way

- **"Current flags win" is a recorded decision.**
  - `planning/archive/chunk-fixes-xdg-resume-signals.md:1061-1063`: "if current flags disagree
    (resume an opus session with `--provider ollama`), pick LOUD: print both and continue with the
    flags".
  - `chunk-meet-supervision-fanout-interface.md:506-507` (RES2) extended it to provider.
  - `f9ca95fa`'s message: "extending the LOUD-and-continue policy `model` already had".
  - The decision was made for a human **typing** `--resume`/`--fork` with flags of their own. Nobody
    considered a composer that types no flags at all.
- **No secrets in the pane command is deliberate.**
  - `pane_command.rb:144-147`: "Deliberately no ANTHROPIC_API_KEY: a pane command is readable from
    `tmux list-panes`".
  - `:138-142` explains why the list is an allowlist and not a `LAIN_` sweep.
- **Windows and popups use the pane recipe, not the printed line.**
  - `fork.rb:121-126` and `btw.rb:39-47`: a tmux pane "sources no interactive chruby".
- I found no ruling that a fork should inherit, or should not inherit, the parent's backend.

### 4. Classification

**(c) Pre-existing behaviour the chunk never touched.** The shape has existed since `/fork` and `/btw`
were created (2026-07-23). It becomes a remote send only because the bench's live arm is a local
provider chosen by flag.

### 5. Constraints, pins and open questions

**Specs that pin the composed command:**
- `spec/lain/cli/command/fork_spec.rb:62` expects exactly `PaneCommand.call("chat", "--fork", selector)`.
- `spec/lain/cli/command/btw_spec.rb:36-38` expects the exact `--btw --fork … --prompt` argv.
- The `pane_command_spec` drift check re-derives `PANE_ENV` from `exe/lain` and requires an
  **exact** match (`pane_command.rb:19-26`). Adding a non-`EnvDefaults` name to that list fails it,
  so flags must travel as argv, not as new env names.

**Invariants:**
- No secret goes on a pane command line (`pane_command.rb:144-147`).
- The printed fallback line stays bare and shell-escaped. The window and popup use the recipe.
- The LOUD notice still has to fire when a human's own flags disagree with the recording.

**Do not relitigate:** "current flags win" on a human-typed `--resume`/`--fork`.

**Open questions for the human:**
- Should the child inherit the parent's resolved backend argv (live state), or should the header gain
  `provider`/`api_base` so that `--fork` defaults to what was recorded? The second option changes the
  header schema that `Loader` and the bench read.
- Which flags count as "backend": only provider, model, api-base, num-ctx and num-batch, or also
  `--exec`, `--isolation`, the compaction flags and the sensitivity flags?
- Should `/btw --prompt` refuse outright when the provider would change?

---

## F142: a docent child's parked approval renders nowhere while the chat is idle

### 1. Mechanism

The finding is correct, and the gap is wider than it states.

- **Every approval watcher lives for one dispatched line.**
  - `Repl#dispatch` → `LineScope#serve` (`cli/repl.rb:200-203`, `cli/repl/line_scope.rb:93-105`)
    spawns `ApprovalSurfaces#watch` (`approval_surfaces.rb:92-97`) and stops it in its `ensure`.
  - That set is: the terminal surface (`Arrivals` in a cockpit, `:103-108`), `@auto_surface`,
    `@secret_surface` and `@editor.watch` (the `lain://approval` `ApprovalView`).
  - `ApprovalView#watch` says so: "One fiber beside the TTY prompt, spawned per ask and stopped with
    it" (`frontend/neovim/approval_view.rb:241-256`).
- **The docent runs outside any line.**
  - `ConversationScope#open` (`conversation_scope.rb:32-36`) starts only `HumanReplies#session_surfaces`,
    which is just `editor_reply_loop` (`human_replies.rb:311`, `:409-410`).
  - That loop routes `review_ask` → `ask_docent` → `@review.call.ask` (`human_replies.rb:994`,
    `:1060-1063`), which spawns the docent child.
- **Its gated `read_file` parks in the parent's queue** (V2 evidence: `approval_pending requester=subagent`).
  - `diff_docent` is `unattended: true` (`role/catalog.rb:52-63`), but that only withholds the
    child's `ask_human` (`tools/subagent.rb:1029-1034`, "holds no tool that can block on a human").
  - It does not stop the sensitivity gate from parking an **approval**.
  - The queue's fail-closed timer runs regardless, so the call is denied at 300 s.
- **Addition, (code read, not driven): between lines neither the automatic approver nor the secret
  oracle runs either.**
  - Under `/mode +auto_approve` or `--secret-oracle`, a docent's parked call would still wait for
    the timeout. Those watchers sit in the same `watch` set.
- **Why typing `/status` "fixes" it:** the line opens a `LineScope`, and the watchers sweep the parked
  set.

### 2. Most recent change

| commit | card | what it did |
|---|---|---|
| `caa2c5f7` | T6 | swapped the cockpit's terminal surface for `Arrivals` and added `Attention` (`approval_surfaces.rb:103-108`) |
| `1cfdf970` | T23 | made the auto surface always spawned, gated by the layer |
| `9d47a7b1` | T28 | `Arrivals` rings |

None of the three changed the lifetime. The lifetime comes from older commits:

| commit | date | what it did |
|---|---|---|
| `71e7d13f` | 2026-08-17 | "The surfaces now bracket one dispatched line… Not the whole conversation" |
| `2b48b73a` | 2026-08-05 | added `ApprovalView` as a per-ask fiber |
| `b3fbada1` / `485246e9` | 2026-08-05 / 08-20 | added the docent on the conversation-scoped rail |
| `b697adf9` | 2026-08-25 | made `diff_docent` unattended |

### 3. Why it is this way

- **`71e7d13f`'s message:** "a reply loop parked on stdin for the length of a conversation is a
  second wedge wearing the first one's clothes".
- **`line_scope.rb:16-23`:** "THE LINE IS THE WIDEST THIS MAY GO. The reply read parks on the stdin
  the next `you>` prompt needs back… The editor's gesture rail is scoped to the conversation
  precisely because it polls a socket and touches no terminal."
  - That test is about the **terminal**. `ApprovalView`, `AutoSurface` and `SecretSurface` touch no
    terminal; `Arrivals` does.
- **T6 (chunk:1024-1131) did consider an actor parking while the chat is idle.** Its AC answers that
  case through `/approve` typed on a line: "Given a chat with an attached editor and one parked
  approval raised by an actor while the chat is idle" (chunk:1088). Its "Reachable from" names
  `LineScope#serve` "on every dispatched line".
- **T23's "Reachable from" says the same:** "`ApprovalSurfaces#watch` on every dispatched line"
  (chunk:2366-2368).
- **T6 escalation trigger** (chunk:1120-1122): "no item may be retired because the chat stopped
  reading it… If an attached editor detaching mid-session leaves a pending with no surface, stop".
  That rules against losing items. It does not cover rendering while idle.
- **`diff_docent`'s comment** (`catalog.rb:52-58`): a child that parked on a question "would hang the
  very thing being waited for". The same argument applies to an approval park, but only `ask_human`
  was removed.
- The cockpit-surfaces §7 / F64 history (the round-14 and round-15 findings) removed the
  question-shaped stall. V2 is the approval-shaped version.

### 4. Classification

**(b) A gap outside the card's scope.** T6 and T23 knowingly bound their watchers to the line, and
T6 tested the idle-actor case only through `/approve`. The lifetime mismatch with conversation-scoped
work (the docent) predates the chunk.

### 5. Constraints, pins and open questions

**Invariants:**
- Any watcher that touches the terminal must stay line-scoped, or must be unable to race `you>`
  (`line_scope.rb:16-23`, `conversation_scope.rb:19-23`). `Arrivals` writes to the terminal.
  Promoting it prints onto the idle `you>` line, which is F179's shape.
- There is exactly one queue **consumer**: `spec/approval_consumer_discipline_spec.rb`, restated at
  `approval_surfaces.rb:119-124` and `approval_view.rb` header. `ApprovalView`, `Arrivals` and
  `AutoSurface` must stay observers.
- `ApprovalView#watch`'s final sweep in `ensure` exists so no stale row survives a stop
  (`approval_view.rb:243-256`). A longer-lived view must still retire decided rows. V2 run 2 shows a
  row denied between lines staying on screen.
- "Nothing is dropped by not reading it inline" (T6) and the queue's fail-closed timeout both stay.
- `AutoSurface` spends model calls. Moving it spawns a judge between lines. That is a cost change,
  and `method.md` bans raising `+auto_approve` during rounds.

**Specs pinning the current shape:**
- `spec/lain/cli/repl/approval_surfaces_spec.rb` pins the **size** and classes of the `watch` set
  (`approval_surfaces.rb:79-85`).
- `spec/lain/cli/repl/line_scope_spec.rb`: "stops every surface it started, so the next you> read
  has the terminal back"; "hands each line a fresh attention".
- `spec/lain/seams/cockpit_answer_surfaces_spec.rb`.
- `spec/lain/frontend/neovim/runtime/62_approval_spec.rb` has a recorded load flake: "two parked
  approvals" (chunk:365-366).

**Do not relitigate:** conversation-scoped terminal readers (`71e7d13f`); nvim-first (T6).

**Open questions for the human:**
- Should the non-terminal watchers (the editor view, and possibly the auto and secret surfaces) move
  to `ConversationScope`, leaving `Arrivals` and the TTY read line-scoped?
- Or should an `unattended` role's gated call be refused by an unattended rung instead of parking?
  `Switchboard::Unattended` already exists (`switchboard.rb:471-482`). The docent is "unattended"
  but is not treated that way for approvals.
- Should the chat pane get any idle note for a park it cannot show? That would need F179's
  print-above-prompt mechanism.

---

## F145: `/fork` forks through a parked approval

### 1. Mechanism

The finding is correct, and incomplete in one place.

- `Fork#anchor!` (`fork.rb:95-102`) refuses only when `Event.pending_tool_use?(head)` **and**
  `env.replies.pending?`. `pending?` means questions only: `!@inbox.empty? || !@questions.empty?`
  (`human_replies.rb:212`).
- **The comment's premise is false since T6.** `fork.rb:82-88` says "Those two prompts are the only
  command-dispatch surfaces in `lib/` — the approval prompt reads y/N straight through
  `conductor.read_reply` … so nothing else can be running a tool while this line is read."
- **T6 added a third surface.** `HumanReplies::CommandLine` runs any registered command while a
  call is parked (`human_replies.rb:701-721`, `commanded`/`routed` at `:1241-1258`).
  `Attention` opens it for a parked approval (`approval_surfaces.rb:106`).
- **`/rewind` and `/undo` already agree** through `Undo.in_flight?(env) = env.agent.dispatching?`
  (`command/undo.rb:63-66`, `command/rewind.rb:73-82`). `Agent#dispatching?` is
  `@dispatch_lock.mon_locked?` (`agent.rb:276`).
- **Addition, (code read, not driven): `/btw` has no mid-tool gate at all.** `Btw#anchored_selector`
  (`btw.rb:67-74`) checks only for an ephemeral session, a head and a journal. So `/btw` at `command>`
  with a call parked, or at `human>` with a question parked, forks a pending `tool_use` head that the
  child repairs as cancelled. It then dispatches `--prompt` at once.
- In a `--no-nvim` chat `/fork` cannot be typed at a drawn `[y/N]`: T27 holds a `/`-line there
  (`frontend/approval_policy.rb:78-83`).

### 2. Most recent change

- The gate came from `8cb3ee0a` (2026-07-23), narrowed by review, then got its wording in `c90e0435`
  (2026-08-23).
- The premise was invalidated by T6 `caa2c5f7`.
- T3 `04a9d40a` unified `/rewind` with `/undo` and left `/fork` alone.

### 3. Why it is this way

- **The narrow gate is deliberate.**
  - `fork.rb:75-81`: "The gate is narrow because the child REPAIRS a torn head, so refusing every
    torn head would refuse forks the child would open happily. But a live head is not a recorded one".
  - `fork.rb:90-94`: over-refusing a subagent question at `you>` "costs a message".
  - `fork_spec.rb:88-106` restates the design.
- **T3 raised the exact tension as an escalation trigger** (chunk:821-824): "Refusing `/rewind` while
  `dispatching?` also refuses it at `human>` while a *subagent's* question is parked and the parent
  is idle-in-tool. If `fork_spec.rb:107-135`'s narrower gate is shown to be the intended rule, stop
  and confirm which predicate `/rewind` takes."
  - T3 landed with `dispatching?` for `/rewind` (commit message: "/rewind holds the dispatch lock
    across its record and move").
  - The execution log has no ruling on `/fork`.
- **Round 17's F96 fix line was "`/rewind` shares `/fork`'s mid-tool door"**
  (`qa-findings-round17-2026-09-14.md:328`). T3 went the other way and adopted `/undo`'s predicate.
- **`repl-commands.md` §4 treats the door's hedge as load-bearing:** "A refusal that has regained the
  confident phrasing is a regression".

### 4. Classification

**(b) A gap outside the card's scope.** T6 created a command surface that runs while an approval is
parked, and T3 unified two of the three doors. The third door's documented premise stopped holding,
and neither card owned `fork.rb`.

### 5. Constraints, pins and open questions

**Specs pinning today's gate** (a switch to the dispatch lock must restate or keep them):
- `spec/lain/cli/command/fork_spec.rb:107-167`:
  - "with a reply outstanding" refuses;
  - "with nobody waiting on a reply — the tear is stranded" **opens** and repairs;
  - "a settled head while a reply is outstanding forks normally".
- `fork_spec.rb:170-190` pins `serves_replies?("/fork") == false`, which is load-bearing for the
  registry.
- `spec/lain/cli/command/rewind_spec.rb` and `undo_spec.rb` pin the shared `Undo.in_flight?`.

**Invariants:**
- A stranded head at rest (torn, and not dispatching) must still fork and be repaired. T3's
  `answer_stranded` repairs at the next ask (`agent.rb:233-238`), so such heads exist only until then.
- Keep the `MID_TOOL` hedge ("may still be making that call") per `repl-commands.md` §4.
- `env.checkpoint` runs **before** the gate (`fork.rb:96`) so the refusal reads a durable head. Keep
  that order.
- `/rewind` holds the lock across the move (`rewind.rb:66-82`). `/fork` only reads, so a snapshot
  predicate is enough.

**Open questions for the human:**
- Should `/fork` take `Undo.in_flight?` (head pending **and** dispatching), dropping the question-only
  test and its documented over-refusal?
- Should `/btw` get the same door? Today it has none.

---

## F146: a `--no-journal` cockpit crashes on `/goal`, and `/mode` reports failure after applying

### 1. Mechanism

The finding is correct about the crash. "`/mode` has applied" is **only partly true**, and the
affected surface is wider than two commands.

- `JournalTee` answers `<<` only (`cli/journal_tee.rb:47-53`).
- **How the tee reaches callers that use `#record`:**
  - `Chronicle::Null#record_journal = @tee || durable_journal` (`chronicle.rb:34`).
  - `Null#wrap_tee` sets `@tee = JournalTee.new(journal, channel)` (`:50-54`).
  - `ChatLaunch#open_chronicle` builds `LiveViews` and wraps the tee whenever `--nvim` **or**
    `--journal` is set (`chat_launch.rb:171-178`, `live_views.rb:129`). It does this before wiring
    (`chat_launch.rb:107`, `:333`).
  - So a `--no-journal --nvim` run hands the bare tee to every `record_journal` caller. A plain
    `--no-journal` run opens no tee, which is why it works.
- **Why a journaled cockpit does not crash:**
  - The real `Chronicle#record_journal = instrumentation.journal` (`:244`) is also the tee under
    `--nvim` (`:232`).
  - But `wrap_memory` is always called (`wiring.rb:331`), and it decorates that journal with
    `Memory::JournalMemoryRoot`, which defines `record` (`memory/journal_memory_root.rb:41-48`).
  - `Null#wrap_memory` returns the recorder and stores nothing (`chronicle.rb:26`).
- **`/goal`:**
  - `Wiring#goal_journal = chronicle.record_journal` (`wiring.rb:863`).
  - `GoalDriver::Run#drive` → `@journal.record` (`goal_driver.rb:322-327`) runs from `Repl#next_text`
    → `poll`, with nothing rescuing it.
  - With T27, `/goal x` first runs `GoalDriver#start` → `@current = Run.new` → `@layer.enable`
    (`goal_driver.rb:167-171`, `:104-115`). That goes through the mode switch, whose record also
    raises: "command /goal failed" (`command/registry.rb:94`). The `Run` is already active by then, so
    the next poll crashes in `drive`.
- **`/mode` is only half applied. (Code read, not driven.)**
  - `Mode::Switch#switch` assigns `@current` and then calls `@journal.record` (`mode/switch.rb:61-66`).
  - The caller `BoundSwitch#switch` (`switchboard.rb:452-457`) calls `@switch.switch(...)` **before**
    `@apply.call(resolution)`, which is `Switchboard#apply` (`:364-368`): it switches the policy,
    rebinds the toolset and rebinds the snapshot scope.
  - So the record raises after the mode slot has moved and **before** policy, toolset and snapshot
    move. `/mode plan` therefore shows `PLAN` while the gate policy is still `:queue` and the toolset
    still holds `bash`/`edit_file`. The fork's "it applied" was read off `/mode`'s description.
  - Layers are read live from the mode slot (for example `toolset_build.rb:60`), so a layer flip
    **does** take effect. `/mode +notify` rang, as observed.
  - By the same code, `/mode +auto_approve` (never driven, per `method.md`) would turn the automatic
    approver on while reporting failure.
- **Other `#record` callers built over the same journal (code read, not driven):**
  - `Switchboard` builds the approval queue, `ModelSwitch`, `PolicySwitch` and `Escalation` over it
    (`switchboard.rb:106`, `:196-198`, `:302`, `:314`, `:349`).
  - `Approval::Queue#record_evidence` and `Escalation#record` rescue and swallow the failure
    (`approval/queue.rb:323-337`, `approval/escalation.rb:268-274`). Approvals keep working, but no
    `approval_pending`, `approval_decision` or `escalation` record reaches nvim's journal or
    `StatusFeed`.
  - `/model` goes through `ModelSwitch#switch` → `record` (`context/model_switch.rb:39`), unrescued.
    I have not traced whether the command catches it.
  - `/review` and `/survey` pass `record_journal` into their sessions (`command/review.rb:241`,
    `:269`; `survey.rb:272`, `:298`).

### 2. Most recent change

- **The defect was introduced in `3e8502e0` (2026-07-29), "agent: one instrumentation value".** It
  added `Null#record_journal = @tee || Journal.new(null)` with the comment "{Channel::Null} is not a
  journal (it answers `#<<`, not `#record`)", and missed that `JournalTee` is not one either.
- T4 `69df4d08` kept `@tee ||` and added `durable_journal` beside it (`git show 69df4d08 --
  chronicle.rb`).
- T27 `cb816f58` added the goal-layer switch in `start`.
- `drive`'s `record` dates from `7c34b626` (2026-07-23). `Switch#switch`'s assign-then-record order
  dates from `af9a757b` (2026-08-02); `9025ad7c` kept it.

### 3. Why it is this way

- **Recorded follow-up (chunk:392-393):** "Predates the chunk (T4 review): a mode switch under
  `--no-journal --nvim` raises `NoMethodError`, because `JournalTee` has no `#record`." It was not
  carded.
- **"Now worse" is imprecise.** Before T27, `/goal x` also reached `drive` and crashed. T27 added one
  more failing record (the layer), reported as a command failure while it leaves the `Run` active.
- **Why records go through the tee:** `chronicle.rb:238-244`, "The journal a run's own switches record
  into… The same destination {#instrumentation} carries, so a flip and a turn_usage cannot land in
  two different files".
- **Why the Null opens its own journal:** `chronicle.rb:45-49`, "--no-journal + --nvim: there is no
  session record to share, so nvim gets its OWN real journal". This combination is supported on
  purpose.
- **What `Mode::Switch`'s ordering comment actually protects** (`switch.rb:42-48`): "The record is
  BUILT before the slot moves… assigning first would leave the harness in a mode the Journal never
  recorded". It covers **construction** refusals; a **write** failure leaves exactly that state.
  `spec/lain/mode/switch_spec.rb:55-72` pins only construction and non-Mode refusals.

### 4. Classification

**(c) Pre-existing since `3e8502e0`**, recorded as a T4 follow-up and not carded. T27 added a second
failure point without being the cause.

### 5. Constraints, pins and open questions

**Specs pinning current shapes:**
- `spec/lain/cli/chronicle_spec.rb:648-658` expects `null.instrumentation.journal` to be a
  `JournalTee` after `wrap_tee`, which fans telemetry to live views.
- `chronicle_spec.rb:376-385`: "answers something that records, so a flip cannot crash on it". This
  is only for the real chronicle **without** a tee or recorder.
- `chronicle_spec.rb:661-672`: the Null `durable_journal` is never the tee.
- `spec/lain/mode/switch_spec.rb:55-72`: a refused flip leaves the mode in force and writes nothing.
- `spec/journal_routing_discipline_spec.rb` (T4).

**Invariants:**
- The tee writes the journal leg **first** and swallows only `ClosedQueueError` per sink
  (`journal_tee.rb:5-26`).
- Records a live view folds go through the tee (`record_journal`). Records nothing live folds go to
  `durable_journal` (T4).
- A flip and a `turn_usage` must land in the same destination (`chronicle.rb:241-243`).
- "Evidence about a turn must never COST the turn" (`queue.rb:306-316`).

**Open questions for the human:**
- Should `JournalTee` gain `#record` (the simplest duck fix, which also makes the Null path match the
  journaled one)?
- Or should `Switch#switch` and `BoundSwitch#switch` be reordered so that journal failure leaves no
  half-applied posture? That is a separate atomicity question, and it also matters for a closed
  journal on the real path.
- Do the swallowed approval and escalation records under `--no-journal --nvim` matter for
  `StatusFeed`'s `approvals_pending`?

---

## F153: in `--no-nvim`, an approval parked while `human>` holds the TTY is never drawn

### 1. Mechanism

The finding says "Mechanism not read in code; same per-line watcher family as F142". **That family
attribution is wrong.** Both surfaces were live in the same line. The cause is one-stdin
serialisation.

- **In a plain chat both terminal readers go through the conductor.**
  - The question: `AnswerLoop#exchange` → `@reply.for(item)` (`human_replies.rb:649-658`).
  - The approval: `ApprovalPolicy#decide` via `reader: conductor.read_reply`
    (`approval_surfaces.rb:52-56`).
  - Both reach `Conductor#read_reply` → `TTY#prompt_afresh` (`conductor.rb:147`, `tty.rb:205-213`),
    which draws only **inside** `LineEditor.exclusively`, the process-wide `READS` mutex
    (`frontend/reline.rb:79-93`).
- **While `human>` holds the mutex:**
  - The `[y/N]` fiber waits with `state = :waiting` and nothing drawn.
  - When the queue's timer decides, `ApprovalPolicy#answered` stops the asking task
    (`approval_policy.rb:154-159`).
  - `prompt_afresh`'s ensure closes the line only `if state == :drawn`. The comment says so: "One
    stopped while still waiting on the lock drew nothing, so there is no line to end"
    (`tty.rb:199-213`). So the human is told neither that a call was parked nor that it was denied.
- **One `[y/N]` at a time is structural.** `ApprovalPolicy#watch` is
  `loop { answered(queue.dequeue) }` (`approval_policy.rb:109-111`). E18-10's "290.5 s undrawn behind
  an `issue_orchestrator` prompt" is this serial dequeue.
- **A plain chat has no one-line approval arrival.** `Arrivals` exists only with an editor
  (`approval_surfaces.rb:103-108`). T29 recorded the notify-bell consequence (chunk:473-477).
- **Before T13 it was the same.** The draw happened inside Reline's own `@mutex.synchronize` in
  `readmultiline` (reline-0.6.3 `lib/reline.rb:250-251`). The chunk's Grounding §4 names "Reline's
  process mutex is the only arbiter" (chunk:144-145).

### 2. Most recent change

- T13 `70c0782f` replaced Reline's implicit serialisation with lain's `READS`
  (`git log -L82,93:lib/lain/frontend/reline.rb`), added the "decided by" close for drawn prompts
  only, and made the ticker suppression a count.
- The serialisation and the single arrival-less `[y/N]` go back to `71e7d13f` (2026-08-17).

### 3. Why it is this way

- **`line_scope.rb:75-82`:** "THE RULE ABOVE IS NARROWER than 'at most one fiber holds the terminal
  read'… on an ORDINARY line of a PLAIN chat both surfaces spawn, so a question and a gated call
  arriving together put two reads on one stdin… A cockpit does not have that race, by the human's
  ruling".
- **`line_scope.rb:84-88`:** "The withholding costs little, and in the safe direction… Worst case a
  call is REFUSED".
- **T13's scope** (chunk:1592-1685) covered three guards: typeahead, decided-elsewhere close and
  answered-elsewhere retire. None of them covers a prompt queued behind another read.
- **The human's ruling:** "Plain `--no-nvim` chat keeps its inline prompts with two guards"
  (chunk:28-29).
- **Owed decision (chunk:530):** "the plain-chat notify bell on `[y/N]`". It has the same root: no
  plain-chat approval arrival.

### 4. Classification

**(c) Pre-existing, and documented as accepted in `line_scope.rb`.** T13's close-on-decide
deliberately excludes a prompt that was never drawn, so the silent timeout is (b), a gap T13 knew
about in code but did not surface.

### 5. Constraints, pins and open questions

**Invariants:**
- One reader at a time on stdin (`READS`). The typeahead drain and the read form one critical section
  (`reline.rb:88-93`).
- An unrecognised keystroke is never consent (`approval_policy.rb:45-48`). A `/`-line at `[y/N]` is
  held, never a decision (T27 ruling, chunk:459-462).
- `approval_policy_spec.rb:384` (chunk:1667-1668) expects the policy's own output empty when another
  surface answers. Words go through the TTY.

**Specs:** `spec/lain/seams/plain_chat_prompt_guards_spec.rb`, `spec/lain/frontend/tty_spec.rb`,
`spec/lain/cli/conductor_spec.rb` (the count), `spec/lain/frontend/approval_policy_spec.rb`.

**Open questions for the human:**
- Should a plain chat print a one-line approval arrival (as a cockpit does) when the `[y/N]` cannot
  draw? That also answers the owed bell decision.
- Should a pending decided while its prompt waits for the lock say so once the lock frees? It would
  need a line that F179 does not splice.

---

## F162: `manual` gates exactly what `accept_edits` gates, with weaker undo

### 1. Mechanism

The finding is correct. `mode/posture.rb:108-117`:
- `manual` is `Permits::All, gate_policy: :queue, snapshot_scope: :write_set, lighter: "MAN"`.
- `accept_edits` is the same apart from `:shadow_git` and the lighter `""`.
- `NAMES` is documented "most restrictive first" (`:119-122`).
- The write-set scope structurally cannot see `bash` writes (see §3).

### 2. Most recent change

- `387b5d50` (2026-09-12) only deleted a tool from `READ_ONLY`. The table comes from `370c2328` and
  `ce897ec1` (2026-08-02), the modes chunk.
- T20 `3af82b61` (round-17) made write-set undo record pre-images, fixing F107, but did not change
  what the scope can see.

### 3. Why it is this way

**Joel's ruling, `planning/archive/chunk-modes-approval-undo.md:137-143`:** "do not add a `mutates?`
axis — `bash` mutates too… So the `accept_edits` and `auto` rungs buy their safety from
**reversibility**". Its table (`:146-149`) gives `manual` "`Triage → Queue` | `WriteSet` | `MAN`".

- The chunk's intent (`:19-25`) says shadow git exists to catch "the ones `bash` mutated, which
  today's write-set scope structurally cannot see". So `manual` kept the pre-modes undo scope on
  purpose.
- I found **no stated rationale** for what `manual` adds over `accept_edits`.
- The in-code comment disagrees with the chunk. `posture.rb:26-27` says "The two lower rungs buy
  theirs from REVERSIBILITY, which is why they differ only in snapshot scope", which names
  `manual`/`accept_edits`, where the chunk named `accept_edits`/`auto`.

### 4. Classification

**(d) By design, ruling owed.** The finding asks for a ruling. None has been taken since the modes
chunk.

### 5. Constraints, pins and open questions

**Specs:**
- `spec/lain/mode/resolution_spec.rb:48`, `:104-105` ("plan and manual select the write-set scope"),
  `:158`.
- `spec/lain/mode/posture_spec.rb:8` (the `NAMES` order).
- `planning/archive/chunk-modes-approval-undo.md:613-621`: the modes chunk's own acceptance criteria.

**Do not relitigate:**
- No `mutates?` axis. "Gate writes under `manual`" must be phrased without one, for example as a
  named tool list or a posture permit, or it re-opens that ruling.
- Tools are capabilities, not permissions (CLAUDE.md).

**Open questions for the human:**
- Is `manual` meant to ask about `edit_file`/`write_file`? If so, by what mechanism, given the ruling?
- Or should `manual` be renamed or reordered, or removed?
- Should `posture.rb:26-27`'s comment be corrected either way?

---

## F171: a plain-chat multi-line `ask_human` shows its first line only, and the pointer names `lain://inbox`

### 1. Mechanism

The finding is correct.

- `AnswerLoop#exchange` → `announce` → `TTY#render_arrival` (`human_replies.rb:649-652`, `:686-688`;
  `tty.rb:283-285`).
- That calls `Inbox#arrival`, which prints `InboxRow.one_line("? <asker><summary>  -- #{POINTER}")`
  (`tty.rb:674-679`) with `POINTER = "answer in lain://inbox, or /inbox"` (`:641`).
- The `human>` read then opens (`human_replies.rb:652`). Only the `/inbox` drain prints the listing
  and the document (`tty.rb:688-695`).
- `Announcement#summary` is the first line clamped to 96 characters, plus "(+N more)"
  (`tools/ask_human.rb:492-540`).
- A `document` rendering already exists: "the block a surface shows BELOW its one-line row"
  (`ask_human.rb:509-515`).
- The repl fork withdrew the pointer half on `tty.rb:636-641`'s "both surfaces, always". SB5 and FI-6
  kept it.

### 2. Most recent change

- **T13 `70c0782f`** changed `POINTER` from "/inbox here, or the inbox buffer in nvim" to "answer in
  lain://inbox, or /inbox". This followed the execution log (chunk:508-509): "T6: the
  question-arrival line still reads '(/inbox here, or the inbox buffer in nvim)', not 'lain://inbox',
  because `tty.rb` is T13's. T13 aligns the wording."
- The one-line summary came from `40160943` and `8c48a5c3` (2026-08-03).

### 3. Why it is this way

- **`40160943`:** "The arrival note names the asker and points at both surfaces, and it prints the
  set's SUMMARY, never the announcement's bytes — for a lone question those bytes are the body
  verbatim, so the one-line note was five lines in a real session… the editor is not a stable fact,
  so nothing here asks whether one is attached".
- **`tty.rb:637-641`:** "Both surfaces, always: which one is live is not a fact this class can hold —
  nvim dies mid-session".
- **`ask_human.rb:482-485`:** "a question cut to its first line is one a human cannot answer". That
  is the reason the bytes stay whole on the value.
- **T6's AC** made the cockpit arrival exactly this line (chunk:1060-1062). T13 aligned the plain-chat
  wording with it without separating the two cases. In a plain chat the next typed line **is** the
  answer, which `method.md:362` states.

### 4. Classification

- **Pointer:** (b)/(d). The "both surfaces" rule is deliberate (`40160943`), and T13's wording made
  the buffer name typeable in a chat that has no buffer.
- **First line only:** (c), deliberate for the **arrival**. Not showing the document before a live
  `human>` read in a plain chat is a gap no card owned.

### 5. Constraints, pins and open questions

**Specs pinning the wording and shape:**
- `spec/lain/frontend/tty_spec.rb:663-690`: pointer text; one line for a five-question set; "one line
  for a terminal, not merely free of newlines" (a `\r` in a question overwriting the asker is a
  forgery guard).
- `spec/lain/cli/human_replies_spec.rb:2000-2006`.
- `spec/lain/seams/cockpit_answer_surfaces_spec.rb:189`, which uses `Inbox::POINTER`.

**Invariants:**
- The arrival stays one terminal line. T28's bell and `display-message` consume that note
  (`tty.rb:283-285`, `:290-293`).
- Any document printed above `human>` must be scrubbed the way the drain listing is.

**Open questions for the human:**
- Should the plain chat print `Announcement#document` above its `human>` read, as the drain does, and
  leave the arrival line alone?
- Should the pointer differ by whether an editor is attached, which `40160943` rejected, or name the
  reply action ("type your answer below, or /inbox")?

---

## F172: nothing stops a running ask without closing the chat

### 1. Mechanism

The finding is correct.

- `Shutdown::STATES = %i[running grace draining closed]` (`cli/shutdown.rb:36`).
- `HANDLERS` (`:48-54`): `sigint` → `request_grace`; a second signal → `interrupt_now` →
  `force_stop(:interrupted)` → `Budget#interrupt` then `finish` → `@closer.close` (`:136-190`).
- `cancel` only disarms back to `:running` (`:145-152`).
- No input stops the run and keeps the session. The command roster has no stop verb either
  (`spec/lain/cli/command/surface_spec.rb:188-192`).
- The only in-session stops are `/goal off` and `:LainGoalOff` (T27, between goal iterations) and
  denying calls.

### 2. Most recent change

- `shutdown.rb`: `c9ff7eea`/`e16eb4cf` (2026-07-16), `b0fe3ec7` (2026-07-29).
- The chunk left it alone.
- T21's seam B (`3ec1dc79`) put middleware turns under `Conductor#supervise` so Ctrl-C reaches
  `/critique` (chunk:408-413), still as a close.

### 3. Why it is this way

**Decision 6 in `planning/archive/chunk-fixes-xdg-resume-signals.md:159-165`:**

> first SIGINT or a SIGTERM → grace countdown (default 60s…) — `c`/Enter cancels the shutdown, `w`
> adds 60s, `r` switches to wait-until-responses…, second Ctrl-C promotes to immediate… 'Immediate'
> is always `Budget#interrupt`

Commit `c9ff7eea`: "a signal during a run stopped it right away, which could cut off a model call
mid-flight or catch a user who hit Ctrl-C on impulse."

- The design treats every signal as a **shutdown** request. A "stop this ask, stay in the session"
  input was never on the table.
- The substrate for one exists:
  - `Budget#interrupt` and structured cancellation with `defer_stop` (`shutdown.rb:26-34`);
  - T3's repair of a stranded head at the next ask (`agent.rb:233-238`).
- **Related open follow-up (chunk:414-415):** "a chat's `/implement-epic` cannot be interrupted,
  because the signal traps point at `Signals::NULL` during a slash command. T21's seam B… may cover
  it, so check once both land." I found no record that this was checked.

### 4. Classification

**(d)/(c).** Signal semantics are a recorded design decision. A separate "stop the ask" was never
designed, so this is a feature gap, not a regression.

### 5. Constraints, pins and open questions

**Invariants:**
- No `exit!` and no `Thread#kill`. The trap body does one `write(2)` (`shutdown.rb:207-221`).
- Interrupt only through `Budget#interrupt` on the task **hosting** the run.
- Stop-preempts-raise precedence: `spec/lain/agent_cancellation_spec.rb`.
- `session_closed`/`run_interrupted` reasons are closed enums. A stop that keeps the session must not
  write `session_closed`.
- An interrupted ask must leave an answered head, per T3's tear repair
  (`spec/lain/agent/tool_delivery_spec.rb`, `spec/lain/seams/tool_cancellation_spec.rb`).

**Specs:** `spec/lain/cli/shutdown_spec.rb` (the five scenarios from xdg T20),
`spec/lain/cli/conductor_spec.rb`, `spec/lain/frontend/tty_spec.rb` (the countdown).

**Neighbour:** F204 (FI-7), a first Ctrl-C at `human>` that draws no countdown, is the ticker
suppression by an open read (`conductor.rb:138-147`).

**Open questions for the human:**
- Which gesture should "stop this ask" be: a countdown key (a fourth option beside c/w/r), a command,
  or a different signal?
- Should it be offered at `command>`/`human>` too, where a read suppresses the countdown?

---

## F147: `lain chat < file` replays stdin after each `Mixlib::ShellOut` fork

### 1. Mechanism

The finding and R4 are correct, and the lain-free repro isolates it.

- `mixlib-shellout-3.4.10/lib/mixlib/shellout/unix.rb:237` does `STDIN.reopen stdin_pipe.first` in
  the forked child, unconditionally. The `input:` option does not avoid it.
- Lain reads non-TTY stdin through buffered `@input.gets` (`frontend/tty.rb:182-189`). The typeahead
  drain skips non-terminals (`tty.rb:964`).
- **Callers that go through mixlib and trigger it:**
  - `Exec::Local#shell`, `bash`'s string arm (`exec/local.rb:22`, `:71-77`);
  - the shadow-git snapshot (`workspace/snapshot/scope/shadow_git.rb:114`, `shadow_git/repository.rb:44`),
    which runs per turn under `accept_edits`;
  - `Isolation::Compose`, `TmuxSurface`, the T28 notify `display-message` (`tty.rb:879-881`), the
    review sources and others.
- **Arms that are already safe:**
  - `Shell::Out` spawns with `in: File::NULL` (`shell/out.rb:57-63`).
  - `Shell::Pipeline`, `bash`'s term arm, passes `in: File::NULL` (`shell/pipeline.rb:358-360`).
- I did not verify the Ruby `IO#reopen` seek internals the finding describes. The repro in the repl
  report (`L1 L2 L3 L2 L3`) is the evidence.

### 2. Most recent change

- Not changed by the chunk.
- It was **found** by T29's drives and recorded as a follow-up (chunk:478-480): "`lain chat` with
  stdin redirected from a regular file re-reads earlier prompts in a loop once a prompt triggers a
  `bash` call. `/dev/null`, a pipe and a TTY are fine."
- `exec/local.rb`'s mixlib factory dates from `210ad08d` (2026-08-23). mixlib use predates that.

### 3. Why it is this way

- **`shell/out.rb:12-26`:** `Shell::Out` exists for fork cost ("SPAWNED, NOT FORKED… linear in the
  parent's RSS"). It is "NOT A REPLACEMENT FOR `Mixlib::ShellOut` EVERYWHERE. … Callers wanting
  mixlib's `cwd:`, `input:`, `live_stdout:` or its `CommandTimeout` class keep mixlib".
- **`shell/out.rb:57-63`:** "mixlib hands its child an immediately-closed pipe and
  `crates/lain-core/src/exec.rs` sets `Stdio::null()`, so all three arms agree". That statement is
  about the child's view of stdin. It does not cover the parent's file offset.
- **`exec/local.rb:31-41`:** the two-arm byte-identity invariant.

### 4. Classification

**(c) Pre-existing**, recorded as a follow-up and not carded.

### 5. Constraints, pins and open questions

**Invariants:**
- `bash`'s two-arm byte identity (`exec/local.rb:31-41`; `spec/lain/tools/bash_spec.rb`).
- T1's non-ASCII timeout message handling in `Exec::Local#shell` (`exec/local.rb:65-77`;
  `spec/lain/exec/local_spec.rb:116-147`).
- Process-group kill with a TERM→KILL grace (mixlib's 3 s, matched by `Shell::Out::GRACE`).
- The `live_stdout`/`live_stderr` streaming sinks.

**Specs:** `spec/lain/exec/local_spec.rb`, `spec/lain/shell/out_spec.rb`,
`spec/lain/shell/pipeline_spec.rb`, `spec/lain/tools/bash_spec.rb`, the shadow-git specs.

**Open questions for the human:**
- Fix it at the parent (unbuffered `sysread` for non-TTY input, or a pipe in front of a regular-file
  stdin), which covers every mixlib caller at once?
- Or replace mixlib at each call site (`Process.spawn` with `in:`), which touches many callers and
  mixlib-only features?

---

## F179 (LOW): arrivals printed onto a drawn prompt line

### 1. Mechanism

The finding is correct.

- **Nothing in `lib/` prints above an open Reline read.**
  - `render_warning`/`render_line` is a bare `@output.puts` (`tty.rb:397-406`).
  - `render_arrival` and `render_summons` use it (`tty.rb:283-293`).
  - `Countdown#print_above` clears and redraws only the **countdown status line**, and only while one
    is active (`tty.rb:1021-1056`). Channel events go through it (`tty.rb:473-484`), and notes do not.
- **The three observed shapes:**
  1. **`command> ! agent asks to run …`:** the cockpit `Arrivals` note (`approval_surfaces.rb:173-176`)
     lands while `CommandLine`'s `read_command` is drawn. `Attention` opens that read because
     something was already outstanding (`approval_surfaces.rb:103-107`).
  2. **`…? [y/N] ? auto_approver …`:** in a plain chat, `AnswerLoop#announce` prints the question
     arrival **before** its read queues on `READS`. The `[y/N]` holds `READS`, so the note lands on
     it (F153's inverse). The judge's question exists because T23's automatic approver is a spawn
     that can `ask_human` (F141/S2).
  3. **`human> You like banana…` (R14):** the cockpit `/inbox` drain `drain_at_prompt` →
     `@reply.at_prompt` (`human_replies.rb:248-253`, `:1223`) is **not** raced against `OpenReads`.
     Only `AnswerLoop#exchange` is (`:652`). So `:LainReply` settling the set leaves the drain read
     drawn with no closing line, and the model's reply renders onto it.

### 2. Most recent change

| shape | card | commit |
|---|---|---|
| 1 | T6 | `caa2c5f7` |
| 2 (the judge surface that can ask) | T23 | `1cfdf970` |
| 3 (answered-elsewhere race added to `AnswerLoop` only) | T13 | `70c0782f` |

The underlying lack of a print-above-prompt path predates all of them: arrivals since `cab6f59f`
(2026-07-17), both terminal surfaces in one line since `71e7d13f`.

### 3. Why it is this way

- T6 kept `/inbox` as a drain that owns the terminal for its line (chunk:1054-1057).
- T13 guard 3 names `AnswerLoop` specifically (chunk:1621-1623).
- `read_line_with_history`'s comment (`tty.rb:361-364`): "Reline's prompt is one line and it mangles
  a newline into a literal backslash-n". Everything above the editor line is printed before the read.
- No card or ruling addresses notes that arrive during a read.

### 4. Classification

**(b).** The class is pre-existing, and T6, T13 and T23 each added a new path into it outside their
ACs.

### 5. Constraints, pins and open questions

**Invariants:**
- Every terminal write shares one lock with the countdown and the completion menu
  (`tty.rb:1028-1040`: "two locks over one stream is two locks that can interleave a torn write").
- `READS` serialises reads (`reline.rb:79-93`).
- Arrival notes stay one terminal line (`tty_spec.rb:680-690`).

**Specs:** `spec/lain/frontend/tty_spec.rb:995` (clear and redraw around a channel event).

**Open question:** should notes route through a print-above-prompt seam, which Reline may not offer
publicly (unverified), or should a drawn read be closed and redrawn around them?

---

## Cross-finding

**Shared root causes:**
1. **One stdin, several readers, and no path to print above an open read.**
   - This covers F153 (a queued `[y/N]` never draws, and a timeout while waiting is silent), F179
     (notes splice onto drawn prompts) and part of F171 (the plain chat's live `human>` shows only
     the one-line note).
   - A TTY seam that renders "above the prompt" and redraws the drawn line, under the same lock
     `Countdown` uses, would cover F179's shapes 1 and 2. It would also make an idle or queued note
     for F153 and F142 possible without a second reader.
2. **Watcher lifetimes are bound to the dispatched line while work runs at conversation scope.**
   - F142, from the docent, and potentially any conversation-scoped spawn.
   - The line was chosen for **terminal** readers (`71e7d13f`). The non-terminal watchers
     (`ApprovalView`, `AutoSurface`, `SecretSurface`) inherited it without that reason.
   - Not F153, contrary to the findings file.
3. **A command-dispatch surface grew (T6's `command>`) under doors that assumed only two.**
   - F145 (`/fork`'s premise at `fork.rb:82-88`), and `/btw`'s missing door.
   - One shared predicate (`Undo.in_flight?`) for `/fork`, `/btw`, `/rewind` and `/undo` covers both.
4. **Composed child commands carry env but not argv.** F132 covers `/fork` and `/btw`. `lain up`'s
   `@chat_args` is the only place that carries flags.
5. **A duck that is not a journal passed where `#record` is required.**
   - F146: `JournalTee` in `Chronicle::Null#record_journal`. The journaled path is hidden only by
     `JournalMemoryRoot`.
   - Separately, `Switch`/`BoundSwitch` apply non-atomically when a record write fails.
6. **A buffered parent stdin shared with forked children.** F147 has its own root, and one
   parent-side fix covers every mixlib caller.
7. **By-design rulings owed.**
   - F162: `manual`'s semantics under the no-`mutates?` ruling.
   - F172: signal semantics have no "stop the ask" input.
   - The plain-chat approval arrival and bell (chunk:530) is shared by F153 and T28's gap.

**Which single fix covers which findings:**

| fix | covers |
|---|---|
| `/fork` (and `/btw`) take the dispatch-lock predicate | F145 and the unfiled `/btw` hole |
| `JournalTee#record`, or a real journal from `Null#record_journal` | F146's crash and swallowed approval and escalation records. The `/mode` half-apply needs the separate reorder |
| A print-above-prompt TTY seam | F179 shapes 1–2, the delivery half of F153 and F142's chat note. Not the `/inbox` drain race (shape 3), which needs `drain_at_prompt` raced like `AnswerLoop` |
| Moving non-terminal approval watchers to `ConversationScope` | F142, and the same gap for `+auto_approve` and `--secret-oracle` between lines |
| A plain-chat one-line approval arrival | F153's announcement and the owed notify-bell decision. F171's pointer wording is decided in the same place (`TTY::Inbox`) |
| Parent-side unbuffered non-TTY stdin | F147, for every mixlib caller |
| Carrying backend argv into composed children | F132 only |
