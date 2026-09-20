# QA round 18: fix it at the owner

status: done
commit-mode: orchestrator-commits
language: ruby (with Lua in the nvim runtime)
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

Round 18 (`planning/qa-findings-round18-2026-09-15.md`) filed 47 HIGH, MED-HIGH and MEDIUM findings. The
research pass (`planning/qa-round18-research/README.md`) found **no regression** among them, and one cause
repeated across every subsystem: **a fix landed at the site that was driven, not at the owner.** The
model phase is wired on the chat stack only, watcher lifetimes are bound to a stdin line, the backend is
re-derived per command, run state is not scoped to the chain it measured, and bookkeeping is written on
success paths only.

This chunk restores the owners. lain has no production users, so it takes the architectural fix wherever
one exists and **deletes what the owner makes redundant**; there are no aliases for old record shapes,
flags or mode names. It satisfies ROADMAP item 48.

**What a user will observe when it lands:**

1. **The record holds.** A session killed while any tool runs resumes. A child that fails, stops or is
   refused a lease leaves a record that retires it. Every stopped ask says why (`ceiling`,
   `over_window`, `transport`, `stalled_stream`, `stopped`, `torn`).
2. **One backend.** A chat's resolved backend (provider, model, api base, `num_ctx`, `num_batch`) is
   recorded in its session header. `/fork`, `/btw`, `--resume`, `bench record`/`arms`, `epic submit`,
   `consolidate` and `improve` all use that one profile; a flag the human types still wins, loudly.
3. **The window.** Every tool result has a static per-tool byte ceiling sized to fit the smallest local
   window. `web_fetch` returns readable text. A read counts for `edit_file` only while the turn that
   delivered it is on the chain, and several windows the model saw add up to a complete read. A refused
   count and a held cut follow the chain they measured. Held cuts re-collapse, and when no cut can make
   room, a **handoff** writes one structured state document that replaces everything except the current
   ask, and the ask is answered.
4. **The human.** Human input reaches the chat through **one input rail**. `lain up` lays out
   nvim | chat transcript over a separate **input pane** that stays live (HUD and fleet tree) while you
   type. Every approval surface lives for the whole conversation. `/stop` or countdown key `s` stops the
   running ask and keeps the session. `lain://status` shows the fleet as a tree.
5. **Authority.** A mode is **scope × approval**. Scope is `checkout` or `plan`, which confines writes
   and commands to a leased spike worktree or scratch directory. Approval is `ask` or `auto`, and `auto`
   still honours the triage and rule denies. `manual` and `accept_edits` are gone. Automatic shell
   approval checks file content before and after it runs, a leased child is judged against its own
   worktree, and config patterns can be anchored to the project root.
6. **Project memory.** All memory lives in one project memory store. A fresh chat sees what earlier chats
   and `lain consolidate` wrote.
7. **Epic, review, exec, bench:**
   - the stage boundary needs positive approval evidence;
   - the driver keeps filling after a refused launch;
   - two epics land in separate checkouts;
   - a re-run asks whether to keep or delete earlier issue branches;
   - a changeset review's NEW side is the reviewed head;
   - notes journal evidence from objects;
   - a review round can be closed;
   - `bash` output is bounded while it is captured;
   - a docker timeout kills its container;
   - DSL files and Ctrl-C fail in words.

### Two things that must never be confused

**Project memory** and **compaction** are different subsystems with different names, objects and
records, and neither reads the other:

| | project memory | compaction |
|---|---|---|
| what it is | durable facts written with `memory_write` or by `lain consolidate` | a derived, rebuildable view of one chat's own history |
| lives in | `Memory::ProjectStore`, `$XDG_STATE_HOME/lain/memory/<project-hash>/` | `Compaction::Source` state, and `compaction_cut` records in the session file |
| scope | the project, across chats | one chain |
| records | `memory_loaded`, `memory_root` (the session's view), `memory_write` tool turns | `compaction_cut` (`advance`, `collapse`, `handoff`) |

A handoff state document is never written to project memory, and the consolidation clerk never reads a
compaction replacement. T39 and T43 pin that compaction and handoff write nothing to the store. T45 adds
a structural spec for the other two directions: nothing under `lib/lain/compaction/` names
`Memory::ProjectStore`, and a consolidation scaffold never carries a cut's replacement text.

### The human's rulings (2026-09-15), and where the plan simplified one

- **One chunk.**
- **F131:** control content both before and after an automatically approved shell call. *Plan
  simplification:* the after-execution half **withholds** the result and bars the command from automatic
  approval, so a retry goes to a human. It does not mask, so no release key for a pathless result is
  needed.
- **F135:** fix at the writer. The `tool_use` turn is settled before any tool runs.
- **F134:** a project memory store. *Asked again under the simplification brief:* **one store for all
  memory**; a turn's `memory_root` names the store version it read.
- **Handoff:**
  - it is a fallback, and the ask is kept;
  - one summarizer call writes a structured state document (goal, progress, files and decisions, open
    todos, next step);
  - that document replaces everything except the current ask, its unanswered tool round and pins;
  - it is recorded like a cut and replayed like one.
  - Held cuts re-collapse (T7 S4: yes), and the T7×T24 re-commit is fixed.
- **Chain-scoped state:** a read is keyed to the turn that delivered it, and the token reading is tagged
  with its head. *Planner addition, forced by the ceilings:* windows the model saw add up to a complete
  read, or `edit_file` would become impossible on any file over 24 KiB.
- **F152:** an `oracle_failed` record, plus a JSON instruction in the summarizer template.
- **Tool ceilings:** static, sized per tool, no per-model variation.
- **`web_fetch`:** readable text through a nokogiri converter; `raw: true` returns the markup. `web_fetch`
  is Ruby over Faraday, and the body is captured with `on_data` streaming, so Faraday response middleware
  cannot see it. The converter runs at `WebFetch#rendered`.
- **RunProfile everywhere.** *Plan simplification:* `/fork` and `/btw` do not pass argv. Their child is
  a `--fork`, which defaults to the profile recorded in the header, so the pane command carries no
  backend flags and no secret.
- **Stop an ask:** countdown key `s` and `/stop`.
- **Split TUI via tmux.** *Asked again:* **one input rail with every producer** feeding it (the input
  pane's socket, the in-process line editor for a plain `lain chat`, and nvim's gesture rail as it
  stands). The stdin-arbitration machinery is deleted.
- **Fleet view.** *Asked again:* **a tree in `lain://status`** rather than a new buffer. *Planner:* the
  pane rendering lives in the input pane's live header, because the chat pane is a scrolling transcript.
- **Modes = scope × approval.** *Asked again:* approval is **two levels, `ask` and `auto`**. `ask` is
  today's `accept_edits` behaviour, so no "is this an edit" predicate is added and the modes chunk's
  "no `mutates?` axis" ruling stands. `manual` is deleted. *Planner:* `auto` keeps the triage and rule
  denies (round-10 F63 closed under `auto`).
- **F163/F151:** positive approval evidence opens a stage, and the sign-off fold validates its closed
  sets.
- **F150:** on a re-run of an epic, ask whether to keep or delete earlier issue branches. A crash resume
  defaults to keep.
- **F144:** NEW is the real file only when the checkout is at head and clean; otherwise it is a nowrite
  head blob with a banner. Changeset reviews only: a survey's raw NEW buffer is round 11's ruling and
  stays.
- **Review:** a close gesture; a ceiling refusal binds nothing; a resumed reopen is a new round with a
  banner.
- **F139:** `--init`, `--name`, and a bounded kill on timeout.
- **F202/F189:** typed stop reasons; withdraw the prompt only for provably pre-wire failures; fold a
  stranded prompt rather than stacking a second one.
- **F140/F155:** project-root-anchored config patterns; `exempt` lifts the prompt, never the automatic
  approval.

### Planner choices to ratify before wave 1

The research left these decisions to the human, and the interview did not reach them. The plan takes
the choice below. The orchestrator confirms the list with the human before starting wave 1; a veto
changes only the card named.

| decision | choice taken | card |
|---|---|---|
| F167: fusion rework or corpus change (research decision 38) | rework: each arm contributes a bounded candidate list; no corpus-fit constant and no hybrid≥ assertion | T12 |
| F156: release record, id on the decision, or both (5) | both | T8 |
| F166: the journal passes' provider and scaffold (6, 7) | default to the recorded profile, and mask the scaffold fail-closed | T20, T45 |
| F149: epics concurrently or in turn (34) | a per-epic landing path, so concurrently | T15 |
| F165: merge criteria and status (36) | concatenate both criteria; refuse a `done` or `in_flight` side | T17 |
| F169: when a watch concludes, and its exit status (40) | on a dead writer only; exit 1 | T27 |
| F201/F205: failed bench recordings (41) | rename aside, continue the remaining runs, and flag them in variance | T20 |
| F141: which children may never park | children spawned by an approval judge surface (the automatic approver, the gate adjudicator); the docent still parks, visibly (T25) | T38 |

### What this chunk deletes

- **Modes:** the posture table, `Permits::All`/`Only`, `READ_ONLY`, `ToolsetBuild::PosturePermits`,
  `Subagent::Seam#permits`, the `deny_all` gate-policy entry, the `manual` and `accept_edits` tokens,
  snapshot scope chosen by posture, and journaling of no-op switches.
- **Input:** `Repl::LineScope`, `LineEditor::READS`, `Conductor#owning_stdin`, ticker suppression by an
  open read, and the three typeahead special cases (they become one generation rule).
- **The record:** `Bench::Session::Lineages::InFlight` and the child-only settle handles, if T1 proves
  them redundant.
- **Stop reasons:** `ResendBridge`'s string-only pre-wire/wire distinction.
- **Flags:** `JournalPassFlags`' provider default, `EpicSubmit::Adjudication.flags`, and the backend
  halves of `RECORD_FLAGS`/`ARMS_FLAGS`. One flag band replaces them.
- **Exec:** mixlib on `bash`'s string arm, and `Exec::Local`'s `shell_out_factory` seam. The seams in
  `Isolation::SelfSync`, `Compose` and `Worktree::Registry` stay.
- **Liveness:** one of the two idioms.
- **Tool bounds:** the `web_fetch` EXEMPT row and `AWAITING_RULING`, and the per-tool scattered ceiling
  constants.
- **Surfaces:** the bare-digest fleet listing.
- **Oracles:** "the absence of an answer is the signal".

### LOW findings folded in, because they share an owner

- F168, in T29.
- F174, in T7.
- F175, in T5.
- F176 and F182, in T2.
- F177 and F205, in T20.
- F179 and F204, in T25 and T41.
- F181, in T23.
- F183, in T11.
- F184 and F186 (extra positionals and duplicate flags), in T10.
- F187, in T33.
- F188 and F198, in T27.
- F189, in T18.
- F190, in T38.
- F191, in T21.
- F192 (E18-11 and E18-12), in T17.
- F193 (E18-14), in T19.
- F194 (`deny` wording), in T14.
- F195, in T8.
- F196, in T45.
- F197 (refusal wording), in T12.
- F203, in T18 and T28.
- Item 46's hand-listed refusal classes, in T15.
- T9's `capability_degraded` follow-up, in T20.

## Grounding

Verified 2026-09-15 against `main` at `90f081b9`, read-only.

**Sources:**
- Seven research passes, each re-verifying mechanisms with file:line and tracing the round-17 discharge
  (`planning/qa-round18-research/{secret,compaction,repl,review,epic,subagents,exec}.md`).
- Eight code explorations:
  - RunProfile construction sites;
  - the child stack and settling;
  - terminal and signals;
  - window, bounds and capture;
  - `web_fetch` and sensitivity;
  - compaction and memory;
  - cockpit layout and chat I/O;
  - modes and confinement.
- This plan cites the round-17 chunk's **Execution log**, not its T24 card body, which is stale.

**Facts the cards rest on:**
- **The record.**
  - `Middleware::JournalTurns#call` catches the scribe up only after `perform_tools`
    (`middleware/journal_turns.rb:27-31`), while `turn_usage` and `memory_root` are written at commit
    (`agent.rb:511-530`).
  - `:spawn` and a main-agent `ask_human` question write at once.
  - `b679ed46` fixed this for children only; the top-level `parent` thunk (`cli/wiring.rb:347`) has no
    settler.
- **Children.** `spawn_one_shot` (`tools/subagent.rb:238-247`) has no `ensure`, and the lease is taken
  inside `run_child`, after the spawn record. `SpawnLifecycle::MARKS` is closed.
- **The backend.** Only `ChatLaunch` binds `Backend#journal`. Bench record, bench arms, epic submit,
  consolidate and improve construct their own backend options. `SessionRecord.header` records no
  provider (`session_record.rb:44-51`).
- **Reads.** `ReadSet` is add-only (`session.rb:574-597`). `read_file` has `WHOLE_BOUND` at 256 KiB and
  `WINDOW_BOUND` at 1 MiB (`read_file.rb:59-64`). A window covering the whole file is the only
  "complete" read (`edit_file.rb:64-77`).
- **Stop reasons.** `RunInterrupted::REASONS = interrupted grace_expired stalled_stream torn`. Only
  `WindowExceeded` withdraws the prompt (`agent.rb:336-341`), and `agent_spec.rb:1029-1034` pins that.
- **Compaction.** `HeldCut.holds?` needs the cut's commit head on the chain, and withdrawal removes it,
  so the same cut is re-committed on every stuck ask (the rails 3 journal shows this).
- **Surfaces.** Every approval watcher is spawned per dispatched line (`cli/repl/line_scope.rb:93-105`).
  Plain-chat readers serialise on `READS` (`frontend/reline.rb:79-93`). Reline 0.6.3 has no
  print-above API. No Unix socket server exists anywhere in `lib/`.
- **`lain up`.** It targets panes by window (`S:chat`), and `PaneCorpse` probes the window's active pane
  (`cli/up.rb:389-393`).
- **Modes.** Only `bash` answers `requires_approval?`, so `manual` and `accept_edits` gate the same thing
  (`mode/posture.rb:108-117`). `auto` replaces the whole ladder with `ApproveAll`. Nothing confines
  paths today (`WorkerEnv#resolve` honours absolute paths).
- **Memory.** `lain consolidate` writes into an in-process `Memory::Recorder` over `Channel::Null`
  (`cli/consolidate.rb:29-36`). Memory survives only through `MemoryReplay` of turn records on
  `--resume`.
- **`web_fetch`.** It is Faraday with an `on_data` `ByteCap` and is EXEMPT in
  `spec/tool_bounds_discipline_spec.rb`. There is no nokogiri in `Gemfile.lock`.
- **`bash` capture.** mixlib's `@stdout` and `Shell::Pipeline::Run`'s `@buffers` are unbounded, and the
  one bound lives in `Bash.render_output`.
- **Docker.** `Exec::Docker::RUN = docker run --rm --quiet`: no `--init`, no name, no cleanup.

**Where docs and code disagreed, and which won:**
- **Scenarios the code proved wrong, corrected in T48:**
  - `failure-injection.md` §1b ("no turn committed");
  - `memory-and-dogfood.md`'s fresh-session read-back (true only once T39 lands);
  - `survey.md` §7 check 4 ("replays with it");
  - `secret-boundary.md` §2 (`vault/**` is refused at load);
  - `epic-tier.md` §6, which the positive-evidence ruling changes.
- **Comments, where the code won:**
  - `posture.rb:26-27` contradicts the modes chunk; it is deleted with the table;
  - `ask_human.rb:369-371` is false for a SIGKILL (T1);
  - `docker.rb:111-115` rests on a false premise (T44);
  - `review_spec.rb:596-597` says "holding NOTHING" and is unenforced (T31).
- **`ROADMAP.md` § Interface & UX:**
  - "reline can't refresh mid-wait" is answered by the input pane;
  - the remote-surface paragraph on "the two `auto`s" is restated in T48;
  - the known gap "no surface projects spawn edges" closes with T46.

## Orchestrator contract (plan-specific only)

**Shared files.** These are orchestrator-owned, and cards touch them only through one-line wiring diffs:
- `lib/lain.rb` and every unit index (`lib/lain/<unit>.rb`);
- `.rubocop.yml`;
- `spec/spec_helper.rb`;
- `spec/support/**`;
- `lain.gemspec`;
- `Gemfile.lock`.

**Before wave 1:** commit the round-18 QA documents that are uncommitted in the working tree
(`planning/qa-findings-round18-2026-09-15.md`, `planning/qa-round18-research/`,
`planning/qa/method.md`, `planning/qa/README.md` and the `manual-qa` skill edits). The grounding cites
them. Leave `sites` and `references/repos/smolagents` alone: they are not this chunk's.

**Hot files are sequenced by wave, not shared.** The waves come from a mechanical schedule over every
card's lib, spec and exe files, including the construction sites a card obviously has to touch; no two
cards in one wave list the same file. The orchestrator re-runs that check if a card's file list grows in
flight, and moves the card rather than sharing the file.

| file | cards, in wave order |
|---|---|
| `tools/subagent.rb` | T33 → T1 → T19 → T34 → T47 → T46 |
| `agent.rb` | T1 → T18 → T28 → T43 |
| `exe/lain` | T2 → T20 → T39 → T32 → T42 → T43 |
| `cli/wiring.rb` | T2 → T13 → T39 → T32 → T47 |
| `cli/tool_guard.rb` | T22 → T30 → T38 → T47 |
| `compaction/source.rb` | T28 → T35 → T43 |

Several cards with no dependency sit after wave 1 for file ownership only. Each says so on its card:
T1, T3, T5, T13 and T27 in wave 2; T16 and T21 in wave 3; T8 in wave 4.

**`/mode plan` is refused by name from T33 (wave 1) until T47 (wave 5).** T33 deletes the read-only `plan` posture, and
T47 builds plan scope. Both land in this chunk, so the gap is a mid-chunk state, not a shipped one.

**The nokogiri dependency:** for T36 the orchestrator adds `spec.add_dependency "nokogiri"` to
`lain.gemspec` and runs `bundle install` before the card's red step.

**Output discipline:** terminal code for the input pane lives under `lib/lain/frontend/`, never
`lib/lain/cli/`.

**A tripped `Metrics/*` limit** on `CLI::Backend`, `CLI::Wiring`, `Tools::Subagent`, `Frontend::TTY` or
`CLI::HumanReplies` means a collaborator is missing. It is never a limit raise inside a card.

**Manual passes:** the `planning/qa/method.md` rule on `/mode auto` and `+auto_approve` holds, and it
applies to the new token `auto` too.

## Open decisions

None of these gates a card. Each is deliberately not taken here.

1. **Read tools resolving symlinks** (round-17 T8 S3). Unchanged.
2. **`~`/`$HOME` spellings at the triage rung under automatic approval** (round-17 T23 SF2). Unchanged.
3. **A table-wide cap on `exempt`** (round-17 T8 S4). T23 keeps the per-entry cap.
4. **The review verdict vocabulary** (research open question 3). T31 adds a close gesture and leaves
   `VERDICTS = %w[approve]`.
5. **Whether the docent is told the reviewer's note** (F185). Untouched.
6. **A retry's one-shot spawn digest** (E18-15) and **`/status` vs `/inbox` counts** (E18-16).
   Untouched.
7. **A capture bound on the daemon (`lain-core`) exec arm.** It stays unbounded, and T37 names the
   asymmetry; bounding it needs a Rust change.
8. **The remote-surface wire.** T13's rail values are shaped so a later producer can join; no relay is
   built.
9. **`lain epic finish` over an abandoned issue** (E18-13), **improvement-note dedupe** (F197),
   **approving a gated `grep`/`glob` that returns a withheld result** (F180), **F186's
   `commits`/`FILE_OVER`/`lain_c_l_i` items**, and **F194's other wording.** Untouched.

## Waves

- **Wave 1:** T2, T4, T6, T7, T9, T10, T11, T12, T14, T15, T17, T33.
- **Wave 2:** T1, T3, T5, T13, T20 (←T2), T22 (←T7), T23 (←T7), T24 (←T10), T26 (←T15), T27.
- **Wave 3:** T16, T18 (←T1), T19 (←T1), T21, T25 (←T13), T29 (←T4), T30 (←T7), T31 (←T24),
  T39 (←T1, T4).
- **Wave 4:** T8, T32 (←T13), T34 (←T18, T19), T36 (←T29), T37 (←T29), T38 (←T19, T30),
  T45 (←T39, T20).
- **Wave 5:** T28 (←T18), T40 (←T32), T41 (←T18, T25, T32), T42 (←T20), T44 (←T37), T47 (←T33, T30).
- **Wave 6:** T35 (←T28), T46 (←T19, T32).
- **Wave 7:** T43 (←T35, T6, T2).
- **Wave 8:** T48 (←every card).

**Critical path:** T1 → T18 → T28 → T35 → T43 → T48 (waves 2, 3, 5, 6, 7, 8). T28 sits in wave 5
rather than 4 because `status_feed.rb` is T34's there.
No other chain is longer.

## Execution log

(execute-plan appends Landed SHAs, rulings and follow-ups below)

**Execution start, 2026-09-15.**
- **Base:** the chunk lands on `main`, starting at `90f081b9`. `origin/main` is `b1927ce7`, 388 commits
  behind, and is not a base for anything. Every card worktree is cut from the current `main` head under
  `tmp/worktrees/`.
- **Ratified:** the human accepted all eight planner choices in the table unchanged, and asked for the
  chunk to run through to completion without pausing between waves.
- **Worktrees that existed before the chunk and are not its own:** `.claude/worktrees/agent-a0d26dfa…`
  and `agent-ad39e9a4…`, both at `b1927ce7`. Branches: `flake/review`, `spike/review-ui`,
  `survey/dogfood-2026-08-25`. Close-out leaves these alone.

**Panel review, 2026-09-15:** REQUEST-CHANGES. Every blocker and the substantive should-fixes were applied
before this plan was presented.
- **The input socket (T32, T40).** Its path no longer carries a pid, so `lain up` can name it before
  either pane starts and a restarted chat binds the same path. A stale socket is detected with a connect
  probe.
- **RunProfile (T2).** It listed the files the header is really written through (`Chronicle`, `Scribe`,
  `Wiring`). `Backend.new(options)` now builds the profile internally, so the card no longer edits other
  commands' constructors.
- **Wrong paths.** `ImplementEpic` and `Unpin` live in `cli/command/small.rb`; the runtime spec is
  `neovim/runtime/65_review_spec.rb`; `composed_prompt.rb` sits under `cli/`.
- **The docent (T25, T38).** T38's refusal would have silenced the docent T25 makes visible. The refusal
  now applies only to children spawned by an approval judge surface, and T25's criterion uses an attended
  child.
- **Project memory (T39).** It became a store plus a per-session view: `memory_root` names the view, so
  foreign writers and `/rewind` replay correctly. The resumed-chat construction site
  (`SessionRecord::Replay#memory`) is owned.
- **Waves.** They were recomputed mechanically over lib, spec and exe files, including construction sites
  (8 waves).
- **Countdown over the rail (T32, T41).** The countdown became a rail prompt kind, with a `Lain::Stopped`
  cause (T18), and the pane draws a live HUD header (T32).
- **`read_file` (T13).** A trigger was added for a private Reline API, and a held line's fate is stated.
- **Ceilings (T29).** They are derived from the **measured minimum** bytes per token, not from round 17's
  3.3x variance figure.
- **The fleet tree (T46).** Its facts ride a `child_progress` record, so spawn digests do not change.
- **The spike snapshot (T47).** It uses a temporary index plus `write-tree`/`commit-tree`, not
  `git stash create`.
- **Handoff (T43).** It covers an ask's completed tool rounds, and `--compact-fallback` is recorded in the
  header's compaction section.
- **The memory/compaction boundary (T45).** A structural discipline spec now pins both directions.
- **Ratification.** The planner's choices on owed research decisions are listed for ratification before
  wave 1.
- **Risk ratings.** T8, T29, T38 and T40 were raised.


**Execution complete, 2026-09-20.** Forty-eight cards landed on `main` in eight waves, one commit each
except T15 (which needed its refusal module landed separately, ahead of its dependants) and T36 (whose
gemspec line is its own commit). Two commits are the orchestrator's own, both named below.

### Landed

| Card | SHA | Subject |
|---|---|---|
| T1 | `c8b4430f` | agent: the tool_use turn reaches the session file before its tools run |
| T2 | `a0d6557b` | backend: a chat records its run profile, and resumed chats default to it |
| T3 | `2f9e8d05` | commands: /fork and /btw refuse while a tool call is in flight |
| T4 | `72bb1716` | session: a read counts only on its chain, and seen windows add up |
| T5 | `96407a56` | window: probe budget spent by cost; an over-window 400 vouches |
| T6 | `185fb686` | oracle: a failed fire leaves a record, and the summarizer asks for JSON |
| T7 | `b404cfec` | approval: automatic shell approval reads the file before vouching for it |
| T8 | `d1b56197` | approval: a region release leaves a record; decisions carry the call |
| T9 | `96144228` | review: a changeset's NEW side is the reviewed head unless checked out |
| T10 | `76894dfa` | commands: /survey, /review and /implement-epic parse arguments one way |
| T11 | `c2f3e8e9` | survey: a corpus's line refusal names its own way out |
| T12 | `ac29fa9f` | memory: each hybrid arm offers a bounded candidate list before fusion |
| T13 | `ef3066f1` | frontend: one input rail feeds the chat, and one pump reads stdin |
| T14 | `9917fa1b` | epic: a stage opens only over positive approval evidence |
| T15 | `24656f33`, `f4743669` | epic driver: a refused launch no longer ends the run; epics land apart / refusals declare they came before acting |
| T16 | `d4cc7df6` | epic: a terminal gate times the real wait, and Ctrl-C is a refusal |
| T17 | `38b8becb` | epic: graph edits keep both criteria and respect gates and status |
| T18 | `008ba39e` | agent: say why an ask stopped, withdraw only pre-wire failures, fold |
| T19 | `4740280d` | subagent: a one-shot child that fails or stops leaves a record |
| T20 | `02c5a3d5` | backend: every model-calling command resolves the run profile |
| T21 | `db1755fd` | pins: a pinned tool turn keeps its counterpart; /pin says what it did |
| T22 | `29ad2952` | approval: withhold an automatically approved command's secret output |
| T23 | `fa4f1485` | sensitivity: config patterns anchor at the root; exempt stays human |
| T24 | `df586002` | review: a note's evidence comes from the reviewed objects |
| T25 | `43c46fd8` | approval: every surface lives for the conversation, and prompts queue |
| T26 | `17739c3d` | epic: a re-run asks whether to keep or delete earlier issue branches |
| T27 | `bec91493` | liveness: one verdict on a writer, for resume, watch, sessions and gc |
| T28 | `1bc9ca4a` | reading: tag the believed reading with its head; a held cut survives |
| T29 | `48a1b6ed` | tools: one table of static per-tool result ceilings |
| T30 | `280c1a43` | approval: a leased child's shell calls are judged in its own worktree |
| T31 | `421ef0d5` | review: a round can be closed, and a refused one binds nothing |
| T32 | `b01f5a31` | frontend: a chat can read its human from a socket, fed by lain input |
| T33 | `c8bdcb80` | mode: a mode is scope and approval; the posture table is gone |
| T34 | `c73a64b2` | subagent: a child has a model phase, and its refusals speak as the child |
| T35 | `344d389c` | compaction: held cuts re-collapse into one superseding cut |
| T36 | `d202720a`, `fa44ae32` | web_fetch: return a page's readable text, not its markup / gemspec: nokogiri |
| T37 | `738417ac` | bash: capture is bounded while it runs, on one runner for both arms |
| T38 | `c92b9b47` | approval: judges ask no human, and a judge's child refuses, not parks |
| T39 | `e8d54d35` | memory: one project store, and each session's own view of it |
| T40 | `6ae86263` | up: the cockpit puts the chat over an input pane |
| T41 | `138e4af2` | chat: /stop ends the running ask and keeps the session |
| T42 | `5ca48507` | exe: DSL files, Ctrl-C and arms reports fail in words |
| T43 | `13aed7a7` | compaction: hand off to one state document when no cut can make room |
| T44 | `06717d60` | exec: a docker timeout ends its container |
| T45 | `c9a86049` | consolidate: the clerk's memory is durable, and scaffolds are masked |
| T46 | `0e48e2de` | status: the fleet is a live tree, and a row is text a terminal draws |
| T47 | `15391cbc` | mode: plan scope confines writes and commands to a spike |
| T48 | `b76a648d` | docs: restate the architecture and scenarios against what landed |

The orchestrator's own: `82989f8b` (below), and the conflict resolutions folded into the cards they
belonged to.

### What the panel caught that a green suite did not

Every card was reviewed by the five-persona panel after its implementer reported green. The suite was
green each time. These are the defects that survived it, and the ruling that closed each:

- **A leased child could read the parent's denied `vault/`.** The classifier was anchored on the session,
  not on the call. Ruled: one classifier per gated call, anchored on the cwd *that call named*, with a
  session-anchored fallback — because the fallback must not be a disarm.
- **The output withholder scanned the gate's own refusals**, and later skipped detached bench runs.
- **`write_nonblock` sliced characters, not bytes**, so a multibyte HUD frame tore mid-codepoint.
- **A Ctrl-Z'd pane wedged the chat**; a deaf pane could win a bind race.
- **`/stop` vanished silently when unsupervised.**
- **A resumed chat became unresumable** once memory verification widened.
- **A forged-root exemption keyed on an absence.**
- **The handoff oracle's own input was unbounded** — 391 KB pushed into an 8 KiB window.
- **`Float::INFINITY` timeouts crashed every interactive `epic submit`** on the EPoll backend.
- **Tool commands shared lain's controlling terminal.**
- **The input pane collapsed to one row on client attach.**
- **A model-written task line with ANSI escapes overwrote the pane HUD** — `clean\e[1A\e[2KPWNED` put its
  own words on the HUD line of a real pane. Fixed at the owner: one scrub in
  `Tools::AskHuman::InboxRow.one_line`, breaks and tabs to spaces, whole escape sequences, then the
  control and format characters, in that order. Thirty-two defeat vectors were tried against it.

### Rulings worth keeping

- **The panel was right and I was wrong about the secret boundary.** I told T48 that `auto` keeping the
  ladder merely *closed* §5's long-standing known-open. Its implementer went further and called a failure
  there a live regression; the reviewer proved it by driving the real ladder against a planted key and
  watching the triage rung deny it. §5 now reads as a regression check.
- **Ticket references stay in planning prose.** The ban is scoped, by CLAUDE.md's own words, to `lib/`,
  `spec/` and the nvim Lua runtime. Planning docs, README and ROADMAP are the archive, and already carry
  a hundred such citations.
- **T29's ceilings are one figure, 16 KiB**, measured at 1.31 bytes per token worst case. The human may
  prefer per-tool figures; nothing downstream assumes the single number.
- **`CLEAR_ROW` stays and is now pinned.** Reverting it left the suite green and the pane pixel-identical,
  because dropping the age had removed the redraw that exposed the dirty cursor — an unobservable
  defence, kept with a spec that fails without it.

### Measurements

- **T12:** hybrid recall@5 rose .333 → .417 once each arm offers a bounded candidate list before fusion.
- **T46:** the fleet tree memoised, 150.2 µs / 205 objects → 0.1 µs / 0 objects at 25 members; the pane
  header's redraws over eight seconds, 7 → 1, matching the count before the tree existed.
- **T29:** the single ceiling is 16 KiB, at a measured worst case of 1.31 bytes per token.
- **T1:** the stop latency on a slow disk, measured rather than assumed.

### A trap re-confirmed

The first attempt at `82989f8b` reported **80 failures**. None were real: the suite's own watchdog said
`STARVED` — 2% of one core across 30 seconds, load average 25.1 against 16 cores — because two other
agents were working at the time. The same commit was green on an idle box minutes later. This is
`docs/toolchain-traps.md`'s "a red `pspec` is not evidence until nothing else is running", and it is worth
recording that the watchdog, not the reader, is what caught it.

### Integration checks, run on `b76a648d`

- **The suite, on a quiet machine.** `bundle exec rake pspec`: **20,470 examples, 0 failures, 13
  pendings**, with both `pgrep` preconditions reading 0 first. The pre-chunk baseline was 18,701, so the
  chunk added 1,769 examples.
- **`bundle exec rubocop`:** 1,637 files, no offences. No `Metrics/*` limit raised, no inline disable
  added; the one `.rubocop.yml` change is T32's argued `ThreadSafety/NewThread` exclusion for
  `input_socket.rb`.
- **`bin/comment-census --check-tickets`:** 0 project schemes, 0 unclassified. The single AMBIGUOUS entry
  is pre-existing and is Unicode's C1 control block, which this file already names as the example of why
  the classifier is enumerated rather than heuristic.
- **`bin/spec-census --check`:** reported, not acted on, as this plan directs. Assertions **199 against a
  ceiling of 184**; `lib_reach` **64 against 76**, which the census itself says to lower. No ceiling was
  raised in this chunk.
- **The core tier** (`rake core:build && rspec --tag core`), for T37's daemon-arm parity: **35 examples, 0
  failures**.

### Follow-ups this chunk opened and did not close

Each is real, each was ruled out of scope for the card that found it, and none blocks the round.

- **`request_review` has no byte ceiling** — the one content-bearing tool T29's table does not cover.
- **The input pane reprints a changed header below the last**, so several stale headers can stack in a
  six-row pane. The fix is redraw-in-place, which belongs to the input-socket design, not to the tree.
- **A second header change within milliseconds of a redraw is dropped.** Bounded, and pre-existing.
- **Plan-scope wording is missing from the human's approval prompt** — it needs a reason field on the
  queue entry.
- **Spike paths trip the entropy detector**, and sensitivity patterns are not re-rooted under a spike.
- **A non-descendant plan branch is never reaped.**
- **Friction graders no longer see failed children.**
- **`Approve#serves_replies?` is inert**; the countdown polls at 50 ms.
- **The source supplies its own refusal words** rather than taking the caller's.
- **`checked_out?` is not on the source port.**
- **The epic-gate question after a `--resume` head repair cites an in-memory turn.**
- **`ollama_run_tool_loop.yml` is stale** and wants re-recording against the current `web_fetch` schema.
- **`worker` is published and rendered by nothing.**
- **ARCHITECTURE's Telemetry record counts are stale again** now `ChildProgress` joins the list; the
  file's own policy is to trust the recipe rather than the number.
- **`planning/qa/scenarios/survey.md` has an unbalanced code fence**, pre-existing.
- **`bin/spec-census --check` fails at 199 assertions against a ceiling of 184.** Reported, not raised, as
  the plan directs. `lib_reach` improved to 64 against a ceiling of 76, and the census says to lower it.

## Tasks

### T1 — Settle the `tool_use` turn to the session file before any tool runs          [wave 2] [risk: high]

**Depends on:** none. Wave 2 for file ownership: `chronicle.rb` with T2.

**Files:**
- `lib/lain/agent.rb`
- `lib/lain/middleware/journal_turns.rb`
- `lib/lain/cli/chronicle.rb`
- `lib/lain/bench/session/lineages.rb`
- `lib/lain/tools/subagent.rb`
- `lib/lain/tools/ask_human.rb`
- specs:
  - `spec/lain/agent_spec.rb`
  - `spec/lain/middleware/journal_turns_spec.rb`
  - `spec/lain/bench/session/lineages_spec.rb`
  - `spec/lain/tools/subagent_spec.rb`
  - `spec/lain/tools/ask_human_spec.rb`
  - new `spec/lain/seams/crash_mid_tool_spec.rb`

**Reuse:**
- `b679ed46`'s child-level settle (`Chain#settled`/`#promote`, `tools/subagent.rb:870-902`) is the
  precedent.
- `SessionRecord::Scribe#catch_up`, whose append point makes it idempotent (`scribe.rb:69-80, 328-330`).
- The torn-head `Cancellation` repair in `CLI::Resume::MidTool`.

**Design.**
- After `commit_and_account` and before `perform_tools`, the agent sends its turn middleware one message:
  settle this timeline. It is sent inside the same `defer_stop` shield as the commit, so a stop cannot
  land between the turn's commit and its write.
  - `JournalTurns` answers it with `scribe.catch_up`; the Null instrumentation does nothing.
  - `JournalTurns` keeps its post-iteration catch-up for the `tool_result` turn.
- Every agent level now settles itself, so:
  - the child-only settle handles go if they are redundant;
  - `AskHuman::Parent.over`'s Null settler goes;
  - the false comment at `ask_human.rb:369-371` goes.
- `Lineages::InFlight` is retired: an open file now holds every turn a record cites.

**Shared-file wiring:** none

**Reachable from:**
- `CLI::Chronicle#instrumentation` (`chronicle.rb:224-238`) builds `JournalTurns` as the chat's turn
  middleware, handed to `Agent` by `CLI::Wiring#run`.
- Children get theirs in `Tools::Subagent#spawn_agent`.

**Acceptance criteria**

```gherkin
Scenario: a session killed while a tool runs resumes
  Given a chat subprocess whose model calls bash "sleep 30"
  And the subprocess is killed with SIGKILL while bash runs
  When `lain chat --resume` loads that session file
  Then it loads without refusal
  And the head is that tool_use turn, answered as cancelled

Scenario: a spawn cites a turn the file already holds
  Given a chat agent whose tool_use turn spawns a one-shot child
  When the spawn record is written
  Then the session file already holds the turn record the spawn's causal parent names

Scenario: a main-agent question cites a written turn
  Given a chat agent whose tool_use turn calls ask_human
  When the question record is written
  Then the turn it cites is already in the session file

Scenario: an open file with a spawn in flight is read strictly
  Given a session file written up to a running one-shot spawn
  When Bench::Session::Lineages reads it
  Then it yields the completed lineages with no in-flight tolerance path
```

→ spec files:
- `spec/lain/seams/crash_mid_tool_spec.rb` (real Scribe, Journal and Loader, and a killed subprocess);
- `spec/lain/tools/subagent_spec.rb`;
- `spec/lain/tools/ask_human_spec.rb`;
- `spec/lain/bench/session/lineages_spec.rb`.

**Escalation triggers:**
- Writing inside `defer_stop` measurably delays a stop (a slow disk), or
  `spec/lain/agent_cancellation_spec.rb`'s precedence examples change. Stop.
- `scribe_spec.rb:380` (twin dedupe) or `:395` (child usage) changes meaning. Stop.
- An early settle makes `Scribe#rewound` or `/rewind`'s in-flight refusal see a turn it did not see
  before. Stop and describe it.
- A child has no `JournalTurns`, so its settle handles are not redundant. Keep them and report it.
- `lineages_spec.rb:138-256` exists only because of the gap. Delete it deliberately and list the
  examples removed.

### T2 — Resolve one RunProfile, record it in the session header, and default resumed and forked chats to it          [wave 1] [risk: high]

**Depends on:** none

**Files:**
- new `lib/lain/cli/run_profile.rb`
- `exe/lain`
- `lib/lain/cli/backend.rb`
- `lib/lain/cli/backend/endpoint.rb`
- `lib/lain/session_record.rb`
- `lib/lain/session_record/scribe.rb`
- `lib/lain/cli/chronicle.rb`
- `lib/lain/cli/wiring.rb` (the `Chronicle#start` call at `wiring.rb:356`)
- `lib/lain/cli/chat_launch.rb`
- `lib/lain/cli/resume.rb`
- `lib/lain/cli/resume/mismatch_notices.rb`
- specs:
  - new `spec/lain/cli/run_profile_spec.rb`
  - `spec/lain/session_record/scribe_spec.rb`
  - `spec/lain/cli/chronicle_spec.rb`
  - `spec/lain/cli/command/btw_spec.rb`
  - `spec/lain/cli/backend_spec.rb`
  - `spec/lain/cli/backend/endpoint_spec.rb`
  - `spec/lain/session_record_spec.rb`
  - `spec/lain/cli/chat_launch_spec.rb`
  - `spec/lain/cli/resume_spec.rb`
  - `spec/lain/cli/command/fork_spec.rb`
  - `spec/lain/cli_spec.rb`

**Reuse:**
- `EnvDefaults`, with the env read kept in the exe.
- `ModelFlags.endpoint`/`.throughput` (`exe/lain:741-789`).
- `Backend#sampler_extra` and `OLLAMA_ONLY_KEYS`.
- `Resume::MismatchNotices`.
- The `PANE_ENV` allowlist.

**Design.**
- `RunProfile` is a value: `provider`, `model`, `api_base`, `num_ctx`, `num_batch`, and `typed` (the
  fields the human put on argv). The exe builds it once from Thor options and the environment.
- `CLI::Backend` builds its one `RunProfile` from the options it is handed (`RunProfile.from_options`)
  and reads model access through it. Every caller keeps `Backend.new(options)`; T20 moves the secondary
  commands onto the shared flag band, so this card edits no other command's constructor.
- `SessionRecord.header` records the profile, passed by `Wiring` through `Chronicle#start` to the
  `Scribe`.
- Resolution for `--resume`/`--fork` is typed → recorded → environment → built-in. A typed field that
  disagrees with the recording prints today's LOUD notice ("the current flags win").
- `/fork` and `/btw` compose `chat --fork <selector>` exactly as today. The child resolves the recorded
  profile, so no backend argv and no secret goes on the pane command.
- **F176:** the endpoint refusal names a missing host without claiming the scheme is missing.
- **F182:** `--secret-oracle`'s help no longer says "ahead of the human".

**Shared-file wiring:** a `require_relative "cli/run_profile"` line in `lib/lain/cli.rb`, before
`cli/backend`.

**Reachable from:** `exe/lain chat` → `CLI::ChatLaunch` → `CLI::Backend.new(options)`, which builds
the profile. The header is written by `SessionRecord.header` through `CLI::Wiring#run` →
`CLI::Chronicle#start` → `SessionRecord::Scribe`.

**Acceptance criteria**

```gherkin
Scenario: a chat records the profile it ran with
  Given `lain chat --provider ollama --api-base http://127.0.0.1:11434 --num-batch 2048`
  When the session header is written
  Then it records provider ollama, that api base, num_batch 2048 and num_ctx as resolved

Scenario: /fork of an ollama session runs the child on ollama
  Given a session recorded with provider ollama chosen by argv, and LAIN_PROVIDER unset
  When /fork composes its pane command and that command's ChatLaunch resolves its backend
  Then the child's provider is ollama with the recorded api base
  And no mismatch notice prints
  And the pane command carries no backend flag

Scenario: /btw of an ollama session asks on ollama
  Given the same recorded session
  When /btw "a side question" composes its command and that command resolves
  Then the side chat's provider is ollama

Scenario: a typed flag still wins, loudly
  Given a session recorded with provider ollama
  When `lain chat --resume --provider anthropic` resolves
  Then the provider is anthropic and the mismatch notice names both

Scenario: a flagless run sends no options
  Given no throughput flag and no LAIN_NUM_BATCH
  When the chat's ollama request is encoded
  Then it carries no options object

Scenario: an api base with no host is named precisely
  When `--api-base http://` is resolved
  Then the refusal says the URL has no host and does not say a scheme is required
```

→ spec files:
- `spec/lain/session_record_spec.rb`
- `spec/lain/cli/command/fork_spec.rb` together with `spec/lain/cli/chat_launch_spec.rb` (production
  resolution, no injected backend)
- `spec/lain/cli/resume_spec.rb`
- `spec/lain/cli/backend_spec.rb`
- `spec/lain/cli/backend/endpoint_spec.rb`

**Escalation triggers:**
- `CLI::Backend` is at its ClassLength cap. If the profile adds methods to `Backend` rather than being a
  collaborator, stop.
- `spec/lain/cli/pane_command_spec.rb` re-derives `PANE_ENV` from `exe/lain` and needs an exact match.
  If moving env reads changes that list, stop.
- `Bench::Session.write` writes its own `provider` into bench headers. If the two header writers
  disagree on key names, unify them on the profile's keys and say so.
- Telling a typed flag from a Thor default needs hand-parsing of `ARGV` beyond Thor's API. Stop and
  propose.

### T3 — Give `/fork` and `/btw` the dispatch-lock door that `/rewind` and `/undo` already share          [wave 2] [risk: low]

**Depends on:** none. Wave 2 for file ownership: `fork_spec.rb` with T2.

**Files:**
- `lib/lain/cli/command/fork.rb`
- `lib/lain/cli/command/btw.rb`
- `lib/lain/cli/command/undo.rb`
- new `lib/lain/cli/command/in_flight.rb`
- specs:
  - `spec/lain/cli/command/fork_spec.rb`
  - `spec/lain/cli/command/btw_spec.rb`
  - `spec/lain/cli/command/undo_spec.rb`
  - `spec/lain/cli/command/rewind_spec.rb`
  - new `spec/lain/cli/command/in_flight_spec.rb`

**Reuse:**
- `Undo.in_flight?` (`env.agent.dispatching?`, `undo.rb:63-66`), moved into its own object.
- `/fork`'s `MID_TOOL` hedge wording.

**Design.**
- One predicate object: a head with a pending `tool_use` **and** the agent dispatching.
- `/fork`, `/btw`, `/rewind` and `/undo` all ask it.
- `/fork`'s question-only test and the false comment at `fork.rb:82-88` are deleted.

**Shared-file wiring:** a `require_relative "command/in_flight"` line in `lib/lain/cli/command.rb`,
before `command/undo`.

**Reachable from:** the `Command::Registry` built in `CLI::Wiring` dispatches these commands from
`Repl#dispatch`, and from the cockpit command line.

**Acceptance criteria**

```gherkin
Scenario: /fork refuses while an approval is parked
  Given a cockpit chat whose agent is dispatching a gated bash call
  When /fork is typed at the command line
  Then it refuses with the MID_TOOL hedge and composes no pane

Scenario: /btw refuses the same way
  Given the same parked call
  When /btw "a side question" is typed
  Then it refuses with the MID_TOOL hedge

Scenario: a stranded head at rest still forks
  Given a head with an unanswered tool_use and no dispatch running
  When /fork is typed
  Then it opens, and the child repairs the head as cancelled
```

→ spec files:
- `spec/lain/cli/command/fork_spec.rb`
- `spec/lain/cli/command/btw_spec.rb`
- `spec/lain/cli/command/in_flight_spec.rb`

**Escalation triggers:**
- `fork_spec.rb:170-190` pins `serves_replies?("/fork") == false`. If that must change, stop.
- `repl-commands.md` §4's hedge wording would change. Stop.
- `env.checkpoint` must stay before the gate (`fork.rb:96`). If the predicate needs it after, stop.

### T4 — Count a read only while the turn that delivered it is on the chain, and let windows the model saw add up          [wave 1] [risk: high]

**Depends on:** none

**Files:**
- `lib/lain/session.rb`
- `lib/lain/tools/read_file.rb`
- `lib/lain/tools/edit_file.rb`
- `lib/lain/tools/write_file.rb`
- `lib/lain/agent/tool_delivery.rb`
- `lib/lain/session_record/replay.rb`
- specs:
  - `spec/lain/session_spec.rb`
  - `spec/lain/tools/read_file_spec.rb`
  - `spec/lain/tools/edit_file_spec.rb`
  - `spec/lain/tools/write_file_spec.rb`
  - `spec/lain/agent/tool_delivery_spec.rb`
  - `spec/lain/session_record/replay_spec.rb`
  - new `spec/lain/seams/unseen_read_spec.rb`

**Reuse:**
- `ReadSet`'s three add-only sets (`session.rb:574-597`).
- `ToolDelivery#settled`, where the delivering `tool_result` turn is made.
- `SessionRecord::Replay`'s `session_read` fold.

**Design.**
- A read records its path, the line span it covered, a file identity, and its `tool_use_id`.
- Delivery binds `tool_use_id` to the `tool_result` turn's digest.
- `read?` and completeness count only entries whose delivering turn is on the current head's chain.
- A file is complete when the union of the counted windows over one file identity covers every line.
- **Everything stays add-only:** nothing is ever removed, and masking is independent of the chain.
- **Replay:** `session_read` carries the `tool_use_id`, and the binding is re-made from the replayed
  `tool_result`.
- **Residual, named:** a result on the chain that no request has carried yet still counts. T29's ceilings
  make every result re-sendable.
- `edit_file`'s description and refusal words say that windows add up.

**Shared-file wiring:** none

**Reachable from:** `CLI::Wiring#run_state` constructs the chat's `Session`. `Tools::EditFile` and
`Tools::WriteFile` consult it on the chat toolset built by `ToolsetBuild#build`.

**Acceptance criteria**

```gherkin
Scenario: a read rewound off the chain no longer licenses an edit
  Given an agent that read notes.rb in full and then was rewound past that tool round
  When the model calls edit_file on notes.rb
  Then edit_file refuses because notes.rb was never read on this chain

Scenario: windows that together cover a file license an edit
  Given notes.rb has 900 lines
  And the model read lines 1-450 and 451-900 in two delivered windows
  When the model calls edit_file on notes.rb
  Then the edit applies

Scenario: a file that changed between windows is not complete
  Given the model read lines 1-450, the file then changed on disk, and the model read lines 451-900
  When the model calls edit_file
  Then edit_file refuses naming a partial read

Scenario: a resumed session keeps the rule
  Given a session file whose only full read was rewound away
  When the chat resumes and the model calls edit_file on that path
  Then edit_file refuses
```

→ spec files:
- `spec/lain/seams/unseen_read_spec.rb` (real Agent, Session, ReadFile, EditFile and `Agent#rewind`);
- `spec/lain/session_spec.rb`;
- `spec/lain/session_record/replay_spec.rb`.

**Escalation triggers:**
- `session_spec.rb:85-89` or `:874-875` (monotone completeness under parallel siblings) would have to be
  deleted rather than restated. Stop.
- Chain membership cannot be answered without walking the Store once per call. Stop and propose a
  per-head cache.
- File identity would need a full-file hash for every window. Stop and propose (size, mtime, inode).
- A child's fresh Session could see the parent's reads. Stop.

### T5 — Spend the window-probe budget on timeouts only, let an over-window 400 vouch, and mark a guessed window          [wave 2] [risk: medium]

**Depends on:** none. Wave 2 for file ownership: `prompt_composer.rb` with T33.

**Files:**
- `lib/lain/cli/backend/window_book.rb`
- `lib/lain/provider/ollama.rb`
- `lib/lain/middleware/resolve_window.rb`
- `lib/lain/status_feed/reading.rb`
- `lib/lain/frontend/prompt_composer.rb`
- `docs/providers/ollama.md`
- specs:
  - `spec/lain/cli/backend/window_book_spec.rb`
  - `spec/lain/provider/ollama_spec.rb`
  - `spec/lain/middleware/resolve_window_spec.rb`
  - `spec/lain/status_feed/reading_spec.rb`
  - `spec/lain/frontend/prompt_composer_spec.rb`
  - `spec/lain/seams/window_self_correction_spec.rb`
  - `spec/lain/seams/recorded_run_spec.rb`

**Reuse:**
- `Provider::Ollama#context_window_tokens`.
- The over-window 400's `n_ctx` (`ollama.rb:384-387`).
- `Accounting#observe_refusal`.
- `WindowBook` resolutions and `authoritative?`.

**Design.**
- The provider's probe answers one of three typed results: resident window, nothing resident, or
  unreachable/timed out.
- Only timeouts spend `REASK_LIMIT`, which keeps the black-holed-host bound. "Nothing resident" is
  re-asked on each turn, because it costs about 0.3 ms.
- An over-window 400's `n_ctx` becomes an authoritative reading, which also covers a stale smaller runner.
- The HUD and the prompt line show a guessed window as `ctx ~N%` (F175).

**Shared-file wiring:** none

**Reachable from:** `CLI::Backend#window_book` feeds `Middleware::ResolveWindow`, composed in
`Wiring#model_phase`. `StatusFeed` publishes the HUD that `lain up` reads.

**Acceptance criteria**

```gherkin
Scenario: a server with nothing resident is re-asked until a model loads
  Given a probe answering "nothing resident" for 10 turns, then a resident window of 32768
  When the chat runs 11 turns
  Then the window becomes authoritative at 32768

Scenario: a black-holed host still stops being asked
  Given a probe that times out on every attempt
  When the chat runs 10 turns
  Then the host is probed 1 + REASK_LIMIT times in total

Scenario: an over-window refusal vouches for the window
  Given a guessed window and an ollama 400 carrying n_ctx 32768
  When the refusal is observed
  Then the book is authoritative at 32768 and /critique is no longer UNVOUCHED

Scenario: the HUD marks a guess
  Given a guessed window
  When the HUD renders
  Then the occupancy reads "ctx ~" followed by the percentage
```

→ spec files:
- `spec/lain/cli/backend/window_book_spec.rb`
- `spec/lain/seams/window_self_correction_spec.rb`
- `spec/lain/status_feed/reading_spec.rb`

**Escalation triggers:**
- `recorded_run_spec.rb`'s cassette holds exactly one `/api/ps`. If it must change, stop.
- The three readers (`StatusFeed`, `Compaction::Source`, `Agent#occupancy`) must share one book object
  and re-resolve once per turn. If that breaks, stop.
- "A guess never authorises a rewrite" must stay pinned.

### T6 — A failed oracle fire leaves a record, and the summarizer asks for JSON          [wave 1] [risk: low]

**Depends on:** none

**Files:**
- `lib/lain/oracle/eager.rb`
- `lib/lain/oracle/recorded.rb`
- `lib/lain/oracle/summarize.rb`
- new `lib/lain/telemetry/oracle_failed.rb`
- specs:
  - `spec/lain/oracle/eager_spec.rb`
  - `spec/lain/oracle/recorded_spec.rb`
  - `spec/lain/oracle/summarize_spec.rb`
  - new `spec/lain/telemetry/oracle_failed_spec.rb`

**Reuse:**
- The secret-read template's JSON sentence and its reason (`oracle/secret_read.rb:69-78`).
- `Eager#fire`'s containment boundary.

**Design.**
- `Eager`'s rescue journals `oracle_failed` (tier, error class, the request's join key) beside the
  `request_sent`.
- `Recorded` never reads it as an answer; a missing answer still raises `Unrecorded`.
- `Summarize::TEMPLATE` ends by asking for JSON matching its schema.
- Deployment capabilities stay identical on both ollama arms.

**Shared-file wiring:** a `require_relative "telemetry/oracle_failed"` line in `lib/lain/telemetry.rb`.

**Reachable from:** `CLI::Backend#summary_oracle` and `Backend::Summarizer#tier` construct `Eager` over
`Recorded` on the chat path.

**Acceptance criteria**

```gherkin
Scenario: an undecodable summary is recorded and the turn continues
  Given a summarizer tier whose model answers in markdown
  When compaction fires the eager summary
  Then the journal holds request_sent and oracle_failed naming UndecodableAnswer
  And the turn completes

Scenario: a recorded failure is not an answer
  Given a journal holding oracle_failed for a question
  When Recorded replays that question
  Then it raises Unrecorded

Scenario: the template asks for JSON
  When the summarize request is rendered
  Then its prompt text asks for JSON matching the schema
```

→ spec files:
- `spec/lain/oracle/eager_spec.rb`
- `spec/lain/oracle/recorded_spec.rb`
- `spec/lain/oracle/summarize_spec.rb`

**Escalation triggers:**
- `spec/lain/oracle/model_spec.rb:71-127`'s Anthropic byte-identity pin covers the template text. If it
  does, stop and confirm the change is intended.
- A committed cassette embeds the old template. Stop.

### T7 — Automatic shell approval asks the file's content, and the PEM mask covers the whole block          [wave 1] [risk: medium]

**Depends on:** none

**Files:**
- `lib/lain/approval/composed_term.rb`
- `lib/lain/cli/wiring/board_build.rb`
- `lib/lain/credential_patterns.rb`
- specs:
  - `spec/lain/approval/composed_term_spec.rb`
  - `spec/lain/cli/wiring/board_build_spec.rb`
  - `spec/lain/credential_patterns_spec.rb`
  - `spec/lain/middleware/redact_secret_reads_spec.rb`

**Reuse:**
- `BoardBuild::Classifiers#confinement`, the one place this boundary asks the filesystem.
- `Sensitivity::Regions.detect`.
- ComposedTerm's "one more `&&`, one method" predicate shape.

**Design.**
- `Classifiers#content(word)` sits beside `#confinement`. For a word that resolves to an existing regular
  file inside the root, it abstains if either:
  - the file is not world-readable, or
  - its first 64 KiB carry a region.
- ComposedTerm gains that predicate, so an abstention parks the call for a human.
- `credential_patterns.rb` matches a PEM as one `BEGIN`..`END` span, so the short last base64 line is
  inside the mask (F174).

**Shared-file wiring:** none

**Reachable from:** `BoardBuild.for` builds one `Classifiers` factory for the Triage and Rules rungs in
`Switchboard#build_ladder`, on every attended chat.

**Acceptance criteria**

```gherkin
Scenario: a 0600 key behind an ordinary name is not approved automatically
  Given deploy_key, mode 0600, inside the project root
  When the ladder judges `cat deploy_key`
  Then ComposedTerm abstains and the call parks for a human

Scenario: a world-readable file holding a key is not approved automatically
  Given notes.txt, mode 0644, containing a PKCS#8 private key
  When the ladder judges `cat notes.txt`
  Then ComposedTerm abstains

Scenario: an ordinary read is still approved with nobody asked
  When the ladder judges `cat README.md | head -20`
  Then it is approved automatically

Scenario: the whole RSA block is masked
  Given a 3072-bit RSA private key file
  When read_file reads it
  Then no line between BEGIN and END reaches the result
```

→ spec files:
- `spec/lain/cli/wiring/board_build_spec.rb` (the production factory over a real tmp tree)
- `spec/lain/approval/composed_term_spec.rb`
- `spec/lain/credential_patterns_spec.rb`

**Escalation triggers:**
- The lexical classifier must make no filesystem calls (`sensitivity_spec.rb:658`). If the new check
  leaks into it, stop.
- A named FIFO, device or socket could block the byte read. Regular files only; if that is not enough,
  stop.
- `composed_term_spec.rb:51` or `:512-517` stops approving. Stop.

### T8 — A region release leaves a record, and decisions carry the call's id and requester          [wave 4] [risk: medium]

**Depends on:** none. Wave 4 for file ownership: `approval/escalation.rb` with T22 and T30.

**Files:**
- `lib/lain/middleware/redact_secret_reads.rb`
- `lib/lain/approval/queue.rb`
- `lib/lain/approval/escalation.rb` (it also writes `approval_decision`)
- new `lib/lain/telemetry/read_released.rb`
- specs:
  - `spec/lain/middleware/redact_secret_reads_spec.rb`
  - `spec/lain/approval/queue_spec.rb`
  - new `spec/lain/telemetry/read_released_spec.rb`
  - `spec/lain/session_record/replay_spec.rb`
  - `spec/lain/approval/escalation_spec.rb`

**Reuse:**
- `ReadRedacted`'s count-by-subtraction rule (`redact_secret_reads.rb:167-187`).
- `Asking#requested`'s way of threading the requester through the context.
- `Queue#requester_for`.

**Design.**
- `read_released` records the path, the number of regions this read released, the `tool_use_id`, the
  requester and the surface. It carries no bytes.
- `approval_decision` gains `tool_use_id` and `requester`.
- A child's release threads its requester through the context (F195).
- Replay does not fold `read_released`: a resumed run re-asks, which the doc comment says.

**Shared-file wiring:** a `require_relative "telemetry/read_released"` line in `lib/lain/telemetry.rb`.

**Reachable from:** `CLI::ToolGuard` builds `RedactSecretReads` on every agent's stack.
`Switchboard` builds the one `Approval::Queue`.

**Acceptance criteria**

```gherkin
Scenario: a human release is recorded
  Given read_file of .env parks with 2 regions
  When the human releases it
  Then the journal holds read_released with count 2, the path and the tool_use_id

Scenario: a child's release names its requester
  Given a subagent child reads a gated file
  When the release is asked
  Then the pending and the decision name the child's requester, not "agent"

Scenario: pending and decision pair by id
  Given two parked calls decided out of order
  Then each approval_decision carries the tool_use_id of its approval_pending

Scenario: a release does not resume as a mask
  Given a session file holding read_released for .env
  When it resumes
  Then edit_file over .env is not refused as masked
```

→ spec files:
- `spec/lain/middleware/redact_secret_reads_spec.rb`
- `spec/lain/approval/queue_spec.rb`
- `spec/lain/session_record/replay_spec.rb`

**Escalation triggers:**
- `redact_secret_reads_spec.rb:390-396` pins "the approval's own decision record is what says a secret
  was sent". Rewrite it deliberately, never delete it.
- A reader (friction, `StatusFeed`) pairs pending with decision by counting. Update it or stop.

### T9 — A changeset review's NEW side shows the reviewed head unless the checkout is at that head and clean          [wave 1] [risk: medium]

**Depends on:** none

**Files:**
- `lib/lain/frontend/neovim/changeset_diff.rb`
- `lib/lain/frontend/neovim/runtime/47_diff.lua`
- specs:
  - `spec/lain/frontend/neovim/changeset_diff_spec.rb`
  - `spec/lain/frontend/neovim/diff_mode_spec.rb`

**Reuse:**
- `ChangesetDiff#drawn`'s `old_lines` post (from `git show base:path`).
- `47_diff.lua`'s nowrite fallback (`:154-183`).

**Design.**
- Ruby decides whether the checkout is at head and clean: `HEAD` equals `head_ref` and the path is
  unmodified.
  - If so, the post is unchanged, and NEW is the real file with `buftype=""`.
  - Otherwise Ruby also posts `new_lines` from `git show head:path`, and Lua opens a nowrite buffer with
    a banner naming the revision and saying the checkout differs.
- Surveys are untouched.

**Shared-file wiring:** none

**Reachable from:** `/review` → `Review::Surface::Neovim` → `ChangesetDiff#drawn`.

**Acceptance criteria**

```gherkin
Scenario: at head and clean, NEW is the real file
  Given a local-branch review whose checkout is at head_ref with no changes
  When the file is opened
  Then NEW is the file on disk with buftype ""

Scenario: behind head, NEW shows the head's bytes
  Given the checkout is one commit behind head_ref
  When the file is opened
  Then NEW holds head_ref's content, is nowrite, and its banner names head_ref

Scenario: a survey's NEW side is still the disk file
  When a /survey opens a file
  Then NEW is the file on disk
```

→ spec files:
- `spec/lain/frontend/neovim/diff_mode_spec.rb` (real nvim)
- `spec/lain/frontend/neovim/changeset_diff_spec.rb`

**Escalation triggers:**
- The Lua would have to shell out (`47_diff.lua:28-40`). Stop.
- `diff_mode_spec.rb:227-236` ("is the real file on disk") fails for the at-head case. Stop.
- `spec/lain/review/deletability_spec.rb`'s rows would need to change. Stop.

### T10 — Parse slash-command arguments once, with quoting and named refusals          [wave 1] [risk: low]

**Depends on:** none

**Files:**
- new `lib/lain/cli/command/args.rb`
- `lib/lain/cli/command/survey.rb`
- `lib/lain/cli/command/review.rb`
- `lib/lain/cli/command/small.rb` (`ImplementEpic`, `small.rb:235`)
- specs:
  - new `spec/lain/cli/command/args_spec.rb`
  - `spec/lain/cli/command/survey_spec.rb`
  - `spec/lain/cli/command/review_spec.rb`
  - `spec/lain/cli/command/small_spec.rb`

**Reuse:**
- Ruby's `Shellwords`.
- The existing flag declarations and the needs-value refusals (`survey.rb:172-189`).

**Design.**
- `Command::Args.parse(text, flags:, positionals:)` splits with `Shellwords` and pairs flags with their
  values.
- It refuses by name:
  - an unknown flag (`--wdith`);
  - a duplicated flag;
  - an extra positional;
  - an unterminated quote.
- All three commands use it.

**Shared-file wiring:** a `require_relative "command/args"` line in `lib/lain/cli/command.rb`, before
the commands that use it.

**Reachable from:** the `Command::Registry` built in `CLI::Wiring` dispatches `/survey`, `/review` and
`/implement-epic`.

**Acceptance criteria**

```gherkin
Scenario: a quoted directory with a space is surveyed
  Given a directory "my notes"
  When `/survey "my notes"` is typed
  Then the survey opens over "my notes"

Scenario: an extra positional is named
  When `/review main extra` is typed
  Then it refuses naming "extra"

Scenario: a mistyped flag is named
  When `/implement-epic plans --wdith 1` is typed
  Then it refuses naming "--wdith"
```

→ spec files:
- `spec/lain/cli/command/args_spec.rb`
- `spec/lain/cli/command/survey_spec.rb`
- `spec/lain/cli/command/small_spec.rb`

**Escalation triggers:**
- The existing needs-value refusal wording would change. Stop.
- `/review` and `/survey` are deliberate mirrors. If one needs a flag grammar the other rejects, stop.

### T11 — A corpus's line refusal names its own way out, and the text header drops the climb          [wave 1] [risk: low]

**Depends on:** none

**Files:**
- `lib/lain/review/bounds.rb`
- `lib/lain/review/surface/text.rb`
- `lib/lain/review/source/corpus.rb`
- specs:
  - `spec/lain/review/bounds_spec.rb`
  - `spec/lain/review/surface/text_spec.rb`
  - `spec/lain/review/source/corpus_spec.rb`
  - `spec/lain/cli/survey_spec.rb`

**Reuse:**
- `CORPUS_NARROWING` and the `CORPUS` subject word (`bounds.rb:106-110`).
- The row strip in `text.rb:158`.
- `review_view.rb`'s `displayed_path`.

**Design.**
- The line-ceiling refusal takes its subject and advice from the source, not from a type test in
  `Bounds`.
- A corpus supplies:
  - the subject "this corpus";
  - the narrower scopes it supports;
  - `--unbounded`, last.
- `/review` keeps its sentences.
- `Surface::Text` strips the leading climb from group headers as it does from rows.

**Shared-file wiring:** none

**Reachable from:** `Review::Session#present` → `Bounds#check_presentation!`, from `/survey` and
`lain survey`.

**Acceptance criteria**

```gherkin
Scenario: an over-line corpus names --unbounded
  Given a corpus under the file ceiling but over the line ceiling
  When `lain survey` presents it
  Then the refusal names "this corpus" and ends with --unbounded

Scenario: a changeset keeps its words
  Given a changeset over the line ceiling
  When /review presents it
  Then the refusal still says no scope presents this changeset whole

Scenario: the text header has no climb
  Given `lain survey ../big` run from a sibling directory
  Then no group header starts with "../"
```

→ spec files:
- `spec/lain/cli/survey_spec.rb`
- `spec/lain/review/bounds_spec.rb`
- `spec/lain/review/surface/text_spec.rb`

**Escalation triggers:**
- `bounds_spec.rb:880-930`'s Ripper count of `check_presentation!` callers must stay at one.
- The file-count refusal would start measuring or walking. Stop.

### T12 — Hybrid fuses a bounded candidate list, and the sweep's refusal names its file          [wave 1] [risk: low]

**Depends on:** none

**Files:**
- `lib/lain/memory/hybrid.rb`
- `lib/lain/memory/vector.rb`
- `lib/lain/bench/sweep.rb`
- specs:
  - `spec/lain/memory/hybrid_spec.rb`
  - `spec/lain/memory/vector_spec.rb`
  - `spec/lain/bench/sweep_spec.rb`

**Reuse:** `Hybrid#ranked`/`hit_for`, `RRF_K = 60`, and `Sweep#existing!`.

**Design.**
- Before reciprocal-rank fusion, each arm contributes at most `CANDIDATES` hits, a fixed constant with its
  reason stated. It is not fit to any corpus.
- `RRF_K` is unchanged.
- The missing-embeddings refusal names the embeddings file, not "no sweep corpus file" (F197).

**Shared-file wiring:** none

**Reachable from:** `lain bench sweep` → `Bench::Sweep` constructs every arm, `Memory::Hybrid` included.

**Acceptance criteria**

```gherkin
Scenario: noise present in both lists no longer outranks a vector-only answer
  Given a vector arm whose top hit is the gold item and a bm25 arm whose hits are all noise
  When hybrid ranks the query at k=1
  Then the gold item is first

Scenario: the sweep stays deterministic
  When `lain bench sweep -k 5` runs twice
  Then both reports are byte-identical

Scenario: missing embeddings name the file
  Given the corpus without its embeddings file
  When the sweep runs
  Then the refusal names the embeddings file's path
```

→ spec files:
- `spec/lain/memory/hybrid_spec.rb`
- `spec/lain/bench/sweep_spec.rb`

**Escalation triggers:**
- The M6 panel amendment forbids a hybrid≥vector unit assertion and a corpus-fit `RRF_K`. If either seems
  necessary, stop.
- `hybrid_spec.rb:54-66` would be deleted rather than restated. Stop.
- Record the new sweep numbers in the Execution log.

### T13 — One input rail: the chat reads human input from a single queue that producers feed          [wave 2] [risk: high]

**Depends on:** none. Wave 2 for file ownership: `cli/wiring.rb` with T2.

**Files:**
- new `lib/lain/frontend/input_rail.rb`
- new `lib/lain/frontend/stdin_pump.rb`
- `lib/lain/cli/conductor.rb`
- `lib/lain/frontend/tty.rb`
- `lib/lain/frontend/reline.rb`
- `lib/lain/cli/human_replies.rb`
- `lib/lain/frontend/approval_policy.rb`
- `lib/lain/cli/repl.rb`
- `lib/lain/cli/composed_prompt.rb`
- `lib/lain/cli/wiring.rb`
- specs:
  - new `spec/lain/frontend/input_rail_spec.rb`
  - new `spec/lain/frontend/stdin_pump_spec.rb`
  - `spec/lain/cli/conductor_spec.rb`
  - `spec/lain/frontend/tty_spec.rb`
  - `spec/lain/cli/human_replies_spec.rb`
  - `spec/lain/frontend/approval_policy_spec.rb`
  - `spec/lain/cli/repl_spec.rb`
  - `spec/lain/seams/plain_chat_prompt_guards_spec.rb`
  - new `spec/lain/seams/stdin_regular_file_spec.rb`
  - `spec/reply_surface_discipline_spec.rb`

**Reuse:**
- `LineEditor` (Reline, History, the vi `EditingMode`, completion).
- `PromptComposer`.
- `Countdown#print_above`'s one writer lock.
- `Neovim::CommandInbox` as the model of a queue fed by a producer.
- The rail's three typed reads, which already exist as `Conductor#read_prompt`/`read_reply`/`read_command`.

**Design.**
- `InputRail` carries frozen values:
  - `Prompt(kind: you|human|approval|command, text, header, generation)`, which the chat publishes when it
    wants a line;
  - `Line(text, generation)`;
  - `Signal(name)`, delivered at once (`sigint`, `cancel`, `extend`, `wait_responses`);
  - `Eof`.
- The Conductor's readers take lines only from the rail.
- **Typeahead:** a `Line` whose generation predates the open prompt is held, and is never an answer. A
  held line becomes the next `you>` line once the prompts ahead of it close, as today's held line does.
  This one rule replaces round 17's typeahead guards.
- **`StdinPump` is the in-process producer, and the only reader of `$stdin`:**
  - on a tty it runs the line editor for each published prompt;
  - off a tty it reads unbuffered from a private dup of fd 0, and fd 0 itself is re-seated to
    `/dev/null`, so a forked child's `STDIN.reopen` cannot rewind the chat's input (F147).
- Output stays in `TTY`. A note that arrives while a prompt is drawn is printed above it (close the line,
  print, redraw) under the one writer lock.
- The deletions (`READS`, `owning_stdin`, `LineScope`) belong to T25.

**Shared-file wiring:** `require_relative "frontend/input_rail"` and `require_relative
"frontend/stdin_pump"` lines in `lib/lain/frontend.rb`, before `frontend/tty`.

**Reachable from:** `CLI::Wiring#run` builds the rail, hands it to `tty_factory` and the Conductor, and
starts `StdinPump` for every attended chat that has no `--input socket` (T32).

**Acceptance criteria**

```gherkin
Scenario: a typed-ahead line is never an approval
  Given a plain chat in a PTY where the human typed "y" before a gated call parked
  When the [y/N] prompt is published
  Then the held "y" is not taken as the answer and the prompt waits

Scenario: a regular-file stdin is read once, in order
  Given `lain chat < prompts.txt` whose second prompt makes the model call bash through the string arm
  When the chat runs to end of input
  Then each prompt is asked exactly once, in file order

Scenario: a note does not tear a drawn prompt
  Given `you>` is drawn with "half a sent" typed
  When an arrival note is rendered
  Then the note prints above the prompt and "half a sent" is still in the editor

Scenario: only the pump reads stdin in the chat
  Then no object on the chat path (lib/lain/cli and lib/lain/frontend) outside Frontend::StdinPump reads $stdin
  And `lain epic submit`'s own terminal prompt is outside this rule
```

→ spec files:
- `spec/lain/seams/plain_chat_prompt_guards_spec.rb` (PTY child with real TTY, Conductor, HumanReplies
  and Queue; every existing example stays green)
- `spec/lain/seams/stdin_regular_file_spec.rb`
- `spec/lain/frontend/tty_spec.rb`
- `spec/reply_surface_discipline_spec.rb`

**Escalation triggers:**
- Reline cannot run its read off the main thread; it re-traps SIGINT (`reline.rb:396-403`). Stop and
  propose inverting which thread runs the agent loop.
- The countdown's raw key reads cannot share the tty with the pump's editor. Stop.
- `repl_spec.rb`'s goal-typeahead examples (710, 831) or `human_replies_spec.rb`'s EOF examples need more
  than a restatement. Stop.
- `--prompt`, `--non-interactive` or `LAIN_PREFLIGHT=1` behaviour changes. Stop.
- Printing above a drawn prompt while keeping the typed text needs a private Reline API. Stop and
  propose instead holding notes while a prompt is drawn and printing them when it closes.

### T14 — A stage opens on positive approval evidence, and the sign-off fold validates its closed sets          [wave 1] [risk: medium]

**Depends on:** none

**Files:**
- `lib/lain/epic/stage.rb`
- `lib/lain/approval/gate/policy.rb`
- `lib/lain/approval/signoff_queue.rb`
- `lib/lain/cli/session_journals.rb`
- `lib/lain/cli/epic_queue.rb`
- specs:
  - `spec/lain/epic/stage_spec.rb`
  - `spec/lain/approval/gate/policy_spec.rb`
  - `spec/lain/approval/signoff_queue_spec.rb`
  - `spec/lain/cli/session_journals_spec.rb`
  - `spec/lain/cli/epic_queue_spec.rb`
  - `spec/lain/cli/epic_submit_spec.rb`

**Reuse:**
- `Policy::Boundary`, the one boundary call site.
- `SignoffQueue`'s `Contracts`.
- `UnreadableRecord.for`.
- `SessionJournals::Torn.decisive_types`, which reads `Epic::STAGES` at call time.

**Design.**
- `Stage#ensure_open!` requires, for each earlier stage in the same epic (issue-scoped where that stage
  is), an approved terminal `gate_decision` in that partition, as well as nothing parked there.
- `SignoffQueue.apply` refuses a record in either case:
  - its `stage` is not in `Epic::STAGES`;
  - its `policy` is not in the known set (interactive, hands_off, deferred, adjudicated, signoff).
- `SessionJournals` refuses a record that carries `artifact_digest`, `epic_slug` and `policy` under an
  unknown type.
- `lain epic deny` confirms with "denied", not "signed off" (F194).

**Shared-file wiring:** none

**Reachable from:** `Policy#decide` and the adjudicator, on the path of both `lain epic submit` and the
in-chat `/implement-epic`.

**Acceptance criteria**

```gherkin
Scenario: a stage never approved blocks the next
  Given an epic with no research or epic_plan approval
  When `lain epic submit issue_plan plans --issue a` runs
  Then it refuses naming research as not approved

Scenario: a misspelt policy refuses the fold
  Given a session journal holding a gate_decision with policy "deferrd"
  When the sign-off queue folds it
  Then the fold refuses naming that record

Scenario: a gate-shaped record of unknown type refuses
  Given a record typed "gate_decisoin" carrying artifact_digest, epic_slug and policy
  When session journals are read for sign-offs
  Then the read refuses naming the type

Scenario: one epic does not block another
  Given epic "plans" fully approved through research, and epic "other" with nothing submitted
  When plans' epic_plan is submitted
  Then it proceeds
```

→ spec files:
- `spec/lain/cli/epic_submit_spec.rb` (production `EpicSubmit` over real session journals)
- `spec/lain/approval/signoff_queue_spec.rb`
- `spec/lain/cli/session_journals_spec.rb`

**Escalation triggers:**
- About 21 `epic_submit_spec.rb` fixtures open later stages over empty partitions. Rewrite them as
  approvals; never loosen the rule.
- `Journal.records`' foreign-skip contract (`journal_spec.rb:537`) would change. Stop.
- Write-side carriers that build test stages ("s", "nonsense") would start refusing. Stop: validation
  lives at the fold only.

### T15 — The epic driver keeps filling after a refused launch, and each epic lands in its own checkout          [wave 1] [risk: medium]

**Depends on:** none

**Files:**
- `lib/lain/cli/epic_driver/factory.rb`
- specs:
  - `spec/lain/cli/epic_driver/run_spec.rb`
  - `spec/lain/cli/epic_driver/factory_spec.rb`
  - `spec/lain/isolation/gc_spec.rb`

**Reuse:**
- `Run#drive`/`fill`/`untouched?`.
- `LandingCheckout`'s lock discipline.
- `IsolationBackend.worktree_root`.

**Design.**
- `drive` fills iteratively, never recursing per refusal, until something is live or nothing is startable.
- Run-wide refusals (a torn sign-off) stay run-wide.
- The landing checkout path is `landing/<epic slug>`.
- `Run#refused_before_merging?` reads refusal classes from a set the refusals declare, not a hand list
  (item 46).

**Shared-file wiring:** none

**Reachable from:** `/implement-epic` → `EpicDriver::Factory` → `Run#drive`.

**Acceptance criteria**

```gherkin
Scenario: a refused launch does not end the run
  Given width 1 and two in_flight issues, the first of which declares no subject
  When the run starts
  Then the first is reported refused and the second launches

Scenario: a torn sign-off still refuses the run
  Given a torn issue_plan sign-off line
  When the run starts
  Then it refuses and launches nothing

Scenario: two epics cut separate landing checkouts
  Given epic "plans" with a standing landing checkout
  When epic "tiny" is driven in the same project
  Then it cuts landing/tiny and succeeds
```

→ spec files:
- `spec/lain/cli/epic_driver/run_spec.rb`
- `spec/lain/cli/epic_driver/factory_spec.rb` (real git)

**Escalation triggers:**
- The refill would start a `pending` issue (the one-writer rule). Stop.
- Width would be exceeded at any instant. Stop.
- `gc_spec.rb` fixtures hard-code `landing`; update them. If T10's "a checkout at its cut point has not
  landed" guard stops holding, stop.

### T16 — A terminal epic gate measures latency from the question, and Ctrl-C is a named refusal          [wave 3] [risk: low]

**Depends on:** none. Wave 3 for file ownership: `epic_submit.rb` with T20.

**Files:**
- `lib/lain/cli/epic_submit.rb`
- `lib/lain/approval/gate.rb`
- specs:
  - `spec/lain/cli/epic_submit_spec.rb`
  - `spec/lain/approval/gate_spec.rb`

**Reuse:** `Gate#await`'s clock, the `Heard`/`Hearing` promises, and `GateReply::EOF`.

**Design.**
- `Prompt#ask` returns an unresolved promise that the terminal read resolves, so `Gate#await`'s clock runs
  from the question's write.
- The interactive terminal gate keeps no timeout, per `7dfdd9dd`'s design.
- `Interrupt` during the read settles the gate fail-closed as `interrupted`, journaled, and surfaces as a
  `Lain::Error` naming it.

**Shared-file wiring:** none

**Reachable from:** `lain epic submit` → `CLI::EpicSubmit` → `Approval::Gate#call`.

**Acceptance criteria**

```gherkin
Scenario: latency is measured
  Given an interactive research gate whose reader answers "y" after 2 seconds
  When the gate settles
  Then the gate_decision's latency is at least 2

Scenario: Ctrl-C at the prompt is a refusal
  Given an interactive gate waiting on input
  When Interrupt is raised in the reader
  Then the decision is journaled as interrupted and not approved

Scenario: EOF stays fail-closed
  When input ends
  Then the decision is eof and not approved
```

→ spec files:
- `spec/lain/cli/epic_submit_spec.rb`
- `spec/lain/approval/gate_spec.rb`

**Escalation triggers:**
- A blocking `gets` under Async's scheduler stops the promise from resolving. Stop and propose a reader
  thread.
- `run_spec.rb:503` ("leaves the asker free") changes. Stop.

### T17 — Graph edits keep content and respect runtime state          [wave 1] [risk: low]

**Depends on:** none

**Files:**
- `lib/lain/cli/epic.rb`
- `lib/lain/epic/issue.rb`
- `lib/lain/epic/graph.rb`
- specs:
  - `spec/lain/cli/epic_spec.rb`
  - `spec/lain/epic/issue_spec.rb`
  - `spec/lain/epic/graph_spec.rb`

**Reuse:**
- `CLI::Epic#split`'s `original.with(id:)`.
- `Issue#emittable?`.
- `Home::NAME`.
- `SessionJournals` for parked gates.

**Design.**
- `merge` builds its arrival with both descriptions and both criteria blocks, as scenarios in one fence,
  and refuses a `done` or `in_flight` side by name.
- `add`, `split` and `merge` refuse an edit to an issue that holds a parked or approved gate, naming the
  gate.
- `Issue` refuses at parse an id that `Home::NAME` cannot write.

**Shared-file wiring:** none

**Reachable from:** `lain epic merge`/`split`/`add` → `CLI::Epic#apply`.

**Acceptance criteria**

```gherkin
Scenario: merge keeps both criteria
  Given issues a and b, each with one Gherkin scenario
  When `lain epic merge plans a b --as ab` runs
  Then ab holds both scenarios and is emittable

Scenario: merging a done issue refuses
  Given issue a is done
  When a and b are merged
  Then it refuses naming a as done

Scenario: an edit over a parked gate refuses
  Given issue a holds a parked implementation gate
  When a is split
  Then it refuses naming the parked gate

Scenario: an unwritable id refuses at parse
  Given an epic.md declaring issue id a_b
  When the epic is read
  Then it refuses naming a_b
```

→ spec files:
- `spec/lain/cli/epic_spec.rb`
- `spec/lain/epic/issue_spec.rb`

**Escalation triggers:**
- `graph_spec.rb`'s fiber replay laws fail. Stop.
- Concatenated criteria fail `Document.grammar_failures`. Stop.
- `Issue` is mutation-tested: keep the tests green under its harness.

### T18 — Say why an ask stopped, by type; withdraw only provably pre-wire failures; fold a stranded prompt          [wave 3] [risk: high]

**Depends on:** T1

**Files:**
- `lib/lain/error.rb`
- `lib/lain/agent.rb`
- new `lib/lain/agent/stop_reason.rb`
- `lib/lain/cli/repl/ask.rb`
- `lib/lain/telemetry/session_lifecycle.rb`
- `lib/lain/provider/ollama.rb`
- `lib/lain/provider/anthropic.rb`
- `lib/lain/cli/resend_bridge.rb`
- `lib/lain/middleware/request_budget.rb`
- specs:
  - new `spec/lain/agent/stop_reason_spec.rb`
  - `spec/lain/agent_spec.rb`
  - `spec/lain/cli/repl/ask_spec.rb`
  - `spec/lain/telemetry_spec.rb`
  - `spec/lain/provider/ollama_spec.rb`
  - `spec/lain/provider/anthropic_spec.rb`
  - `spec/lain/cli/resend_bridge_spec.rb`
  - `spec/lain/middleware/request_budget_spec.rb`
  - `spec/lain/seams/over_window_request_spec.rb`

**Reuse:**
- `Lain::WindowExceeded`, a duck mixed into provider errors (the precedent for classifying by type).
- `Agent#withdrawing`.
- `StalledStreamError`.
- `ResendBridge`'s pre-wire/wire reasoning (`resend_bridge.rb:29-36`).

**Design.**
- `Agent::StopReason.for(error)` classifies by type, never by message:
  - `Budget::Exceeded` → `ceiling`;
  - `WindowExceeded` → `over_window`;
  - `StalledStreamError` → `stalled_stream`;
  - a provider transport error → `transport`;
  - `Lain::Stopped`, the cause a stop-this-ask interrupt carries (defined here, raised by T41) →
    `stopped`, told apart from Ctrl-C's `interrupted` by that cause, not by `Async::Stop` alone;
  - anything else → `torn`.
- `RunInterrupted::REASONS` gains those four new members. `INTERRUPT_REASONS` does not change.
- **Pre-wire:** provider errors raised before a request byte leaves the process mix in `Lain::PreWire`.
  `withdrawing` withdraws the asked text for `WindowExceeded` or `PreWire` only, and only while that text
  is still the head. `ResendBridge` reads the same duck.
- **A stranded prompt:** a failure after the wire leaves the prompt committed. The next `ask` over a head
  that is an unanswered user turn folds the stranded text and the new text into one user turn, cut from
  the stranded turn's parent. The old turn stays in the Store, and the human is told the earlier text is
  being sent again.
- **Refusal wording:** `RequestBudget` says "withdrawn" only when the error says the Agent withdrew (F203).

**Shared-file wiring:** a `require_relative "agent/stop_reason"` line in `lib/lain/agent.rb`'s index
section.

**Reachable from:** `Agent#ask` (every agent) and `CLI::Repl::Ask#record_interruption` on the chat.

**Acceptance criteria**

```gherkin
Scenario: a ceiling says why the ask stopped
  Given an ask that ends with Budget::Exceeded
  When the chat records the interruption
  Then run_interrupted has reason ceiling

Scenario: an over-window refusal says why the ask stopped
  Given an ask that ends with a WindowExceeded provider 400
  When the chat records the interruption
  Then run_interrupted has reason over_window

Scenario: a stalled stream says why the ask stopped
  Given an ask that ends with StalledStreamError
  When the chat records the interruption
  Then run_interrupted has reason stalled_stream

Scenario: a stop says why the ask stopped
  Given an ask that ends with Lain::Stopped
  When the chat records the interruption
  Then run_interrupted has reason stopped

Scenario: an unknown error says why the ask stopped
  Given an ask that ends with a Lain::Error of no known kind
  When the chat records the interruption
  Then run_interrupted has reason torn

Scenario: a refused connection withdraws the prompt
  Given ollama refuses the TCP connection on every attempt
  When the ask fails
  Then the asked user turn is not on the head
  And run_interrupted has reason transport

Scenario: a stream cut after bytes keeps the prompt, and the next ask folds it
  Given a transport failure after the request was written
  When the human asks "next"
  Then the head holds one user turn carrying both texts, not two user turns

Scenario: a refusal after a tool round does not claim a withdrawal
  Given an over-window refusal after a tool round in the same ask
  Then the refusal text does not say the prompt was withdrawn
```

→ spec files:
- `spec/lain/agent_spec.rb`
- `spec/lain/cli/repl/ask_spec.rb`
- `spec/lain/seams/over_window_request_spec.rb`
- `spec/lain/provider/ollama_spec.rb`

**Escalation triggers:**
- `agent_spec.rb:1029-1034` ("leaves any other failure's prompt committed") is reversed only for
  pre-wire failures. If more than that must change, stop.
- `ask_spec.rb:99-103` (ceiling reads `torn`) is rewritten, never deleted.
- A withdrawn pre-wire prompt could meet a complete WAL frame at salvage. Stop.
- The closed-enum message in `telemetry_spec.rb:687-710` lists the members. Update it deliberately.

### T19 — A one-shot child that fails or stops leaves a record; the lease comes before the spawn          [wave 3] [risk: medium]

**Depends on:** T1

**Files:**
- `lib/lain/tools/subagent.rb`
- `lib/lain/tools/subagent/lineage.rb`
- `lib/lain/status_feed/spawn_lifecycle.rb`
- `lib/lain/status_feed/fleet.rb`
- `lib/lain/cli/fleet_windows.rb`
- `lib/lain/isolation/leases.rb`
- `lib/lain/bench/session/lineages.rb`
- specs:
  - `spec/lain/tools/subagent_spec.rb`
  - `spec/lain/tools/subagent/lineage_spec.rb`
  - `spec/lain/status_feed/spawn_lifecycle_spec.rb`
  - `spec/lain/status_feed/fleet_spec.rb`
  - `spec/lain/cli/fleet_windows_spec.rb`
  - `spec/lain/isolation/leases_spec.rb`
  - `spec/lain/bench/session/lineages_spec.rb`
  - `spec/lain/seams/one_shot_handback_spec.rb`

**Reuse:**
- The actor path, which already leases first (`Supervisor#adopt`, `subagent.rb:216-222`).
- `Lineage#message`.
- `Approval::Gate#retired`'s `QuestionsConsumed` precedent.
- `SelfSync`.

**Design.**
- `spawn_one_shot` acquires the lease first, so a refused lease writes no `:spawn`.
- The spawn's completion is written in an `ensure`:
  - a finished child's completion is unchanged;
  - a raise writes `lifecycle: failed` with the error class and the child's head if it has one;
  - `Async::Stop` writes `lifecycle: stopped`.
- `SpawnLifecycle::MARKS` gains `FAILED`, which is terminal. The fleet and `FleetWindows` retire and mark
  it.
- `Lineages` yields finished lineages only, so consolidate and improve never see failed ones.
- A stopped or failed child's unanswered questions are retired with `QuestionsConsumed` (F141's residue).
- The self-sync runs on the error path too, so a dirty child hands back `dirty` (E18-14).
- One twin's failure retires the shared entry, as Open decision 5 already accepts for success.

**Shared-file wiring:** none

**Reachable from:** `Tools::Subagent#spawn_one_shot` on every chat toolset (`ToolsetBuild#build`).
`StatusFeed` folds the records through `LiveViews`' tee.

**Acceptance criteria**

```gherkin
Scenario: a child that hits its ceiling is retired
  Given a one-shot child that raises Budget::Exceeded
  When the spawn returns an error result to the parent
  Then the journal holds a completion with lifecycle failed
  And the HUD fleet count returns to 0 and its window title is marked failed

Scenario: a refused lease spawns nothing
  Given an isolation backend that refuses acquire
  When the subagent tool runs
  Then no spawn record is written and the refusal is the tool result

Scenario: a stopped child's question leaves the inbox
  Given a child parked on ask_human
  When the child's task is stopped
  Then QuestionsConsumed names its question set and inbox_count drops

Scenario: a dirty child that failed hands back dirty
  Given a leased child that wrote a file and then hit its ceiling
  Then its handback records dirty true
```

→ spec files:
- `spec/lain/tools/subagent_spec.rb`
- `spec/lain/seams/one_shot_handback_spec.rb` (real Leases and worktree)
- `spec/lain/status_feed/fleet_spec.rb`

**Escalation triggers:**
- The records ride locals across the IO yield (`subagent.rb:225-230`). If the `ensure` breaks
  re-entrancy, stop.
- `lineage_spec.rb`'s pinned bodies would change for finished children. Stop.
- A watch pane or `lain watch` needs the spawn record before the lease. Stop.

### T20 — Every model-calling command resolves through the profile, and bench runs journal their provider          [wave 2] [risk: medium]

**Depends on:** T2

**Files:**
- `exe/lain`
- `lib/lain/bench/cli.rb`
- `lib/lain/bench/cli/run_recorder.rb`
- `lib/lain/bench/live_arms.rb`
- `lib/lain/bench/variance.rb`
- `lib/lain/cli/epic_submit.rb`
- `lib/lain/cli/consolidate.rb`
- `lib/lain/cli/improve.rb`
- `lib/lain/cli/backend.rb`
- specs:
  - `spec/lain/cli_spec.rb`
  - `spec/lain/bench/cli_spec.rb`
  - `spec/lain/bench/cli/run_recorder_spec.rb`
  - `spec/lain/bench/live_arms_spec.rb`
  - `spec/lain/bench/variance_spec.rb`
  - `spec/lain/cli/epic_submit_spec.rb`
  - `spec/lain/consolidation_spec.rb`
  - `spec/lain/cli/improve_spec.rb`

**Reuse:**
- `RunProfile` (T2).
- `Backend::Summarizer::RunJournal`'s per-event resolution idiom.
- `Provider::Ollama`'s `/api/show`.
- `Provider::Unreachable` for dry runs.

**Design.**
- One `ModelFlags` band is declared on each of `bench record`, `bench arms`, `epic submit`, `consolidate`
  and `improve`. `JournalPassFlags`' anthropic default, `Adjudication.flags` and the backend halves of
  `RECORD_FLAGS`/`ARMS_FLAGS` are deleted.
- `consolidate` and `improve` default to the source session header's recorded profile. A typed flag wins
  loudly.
- `bench record` and `bench arms` bind the provider's journal to the current run's file, so
  `truncated_stream`, `provider_wait` and `capability_degraded` land there.
- **A failed recording:**
  - it is renamed `N.failed.ndjson`, and the remaining runs continue;
  - `bench variance` lists failed files;
  - it excludes a zero-usage run that has a `truncated_stream` beside it, and names it (F201, F205).
- `--cheap-model` is probed with `/api/show` on ollama before any spend, with no per-provider table
  (F177).

**Shared-file wiring:** none

**Reachable from:** `exe/lain` `bench record`/`arms` → `Bench::CLI`; `epic submit` → `EpicSubmit.from_options`;
`consolidate` → `CLI::Consolidate.from_options`; `improve` → `CLI::Improve.from_options`.

**Acceptance criteria**

```gherkin
Scenario: bench arms honours LAIN_NUM_BATCH
  Given LAIN_NUM_BATCH=2048 and provider ollama
  When `lain bench arms` builds its backend from exe options
  Then every ollama request it encodes carries num_batch 2048

Scenario: consolidate follows the recorded session's provider
  Given a session recorded on ollama and no --provider flag
  When `lain consolidate --dry-run` resolves its backend
  Then the provider is ollama

Scenario: improve follows the recorded session's provider too
  Given the same session
  When `lain improve --dry-run` resolves its backend
  Then the provider is ollama

Scenario: an adjudicated epic stage carries the throughput flags
  Given LAIN_NUM_BATCH=2048, provider ollama, and an adjudicated stage
  When `lain epic submit` builds the adjudication pair
  Then the adjudicator's ollama requests carry num_batch 2048

Scenario: a bench record's truncated stream lands in its run file
  Given a recording provider whose stream ends without done
  When run 1 is recorded
  Then 1.ndjson holds truncated_stream

Scenario: a failed recording is set aside and flagged
  Given run 1 fails with a transport error
  When `lain bench record -n 2` completes
  Then 1.failed.ndjson and 2.ndjson exist and `bench variance` names run 1 as failed

Scenario: an unservable cheap model refuses before spend
  Given ollama /api/show answers 404 for nonesuch:1b
  When `lain bench arms --cheap-model nonesuch:1b` starts
  Then it refuses naming the model and no chat request is sent
```

→ spec files:
- `spec/lain/cli_spec.rb` (the exe path)
- `spec/lain/bench/cli/run_recorder_spec.rb`
- `spec/lain/bench/variance_spec.rb`
- `spec/lain/bench/live_arms_spec.rb`
- `spec/lain/consolidation_spec.rb`

**Escalation triggers:**
- A flagless command would send `options`, or ollama-only keys would reach Anthropic. Stop.
- A dry run would fetch a key or construct a provider. Stop.
- One provider serves N runs, and the journal must follow the run, not capture it at construction. If
  that is not possible, stop.

### T21 — A pin keeps its tool counterpart, and pins say what they did          [wave 3] [risk: low]

**Depends on:** none. Wave 3 for file ownership: `cli/command/small.rb` with T10 and T26.

**Files:**
- `lib/lain/cli/command/pin.rb`
- `lib/lain/cli/command/small.rb` (for `/unpin`)
- `lib/lain/context/pinned_messages.rb`
- `lib/lain/compaction/source/derived.rb`
- `lib/lain/cli/command/undo.rb`
- specs:
  - `spec/lain/cli/command/pin_spec.rb`
  - `spec/lain/cli/command/small_spec.rb`
  - `spec/lain/context/pinned_messages_spec.rb`
  - `spec/lain/context/compact_spec.rb`
  - `spec/lain/compaction/source_spec.rb`
  - `spec/lain/cli/command/undo_spec.rb`

**Reuse:** `Pin::Target`, `SessionPin` records, and `Derived::PinCuts`.

**Design.**
- Pinning a `tool_use` or `tool_result` turn pins its counterpart; both are recorded, so replay matches.
- A bare `/pin` skips an assistant turn whose `tool_use` is unanswered and names the turn it pinned.
- A pin inside a range a held cut already collapsed says so instead of claiming "compaction keeps this
  turn".
- `/pin` and `/unpin` accept the same selectors, and `/undo skip` wording is fixed (F191).
- `compact_spec.rb:200-222`'s characterization example is deleted, as its own comment requires.

**Shared-file wiring:** none

**Reachable from:** `/pin` and `/unpin` in the chat's `Command::Registry`. `Compaction::Source#pinned`
reads `SessionPin`s.

**Acceptance criteria**

```gherkin
Scenario: bare /pin at a parked question pins an answered turn
  Given the newest assistant turn is an unanswered ask_human tool_use
  When /pin is typed
  Then the previous answered assistant turn is pinned and the reply names it

Scenario: a pinned tool_use survives a cut with its answer
  Given a pinned tool_use turn whose tool_result falls inside the next cut's range
  When compaction cuts
  Then no derivation_refused is journaled and both turns render

Scenario: a pin inside a collapsed range says so
  Given a turn inside a held cut's range
  When /pin names it
  Then the reply says the turn is already compacted
```

→ spec files:
- `spec/lain/cli/command/pin_spec.rb`
- `spec/lain/compaction/source_spec.rb`

**Escalation triggers:**
- The derivation must take no pin policy (`derived.rb:25-34`). If the drag cannot live in
  `PinnedMessages`, stop.
- `SessionPin` replay would render differently from live. Stop.

### T22 — Withhold an automatically approved command's credential-shaped output          [wave 2] [risk: medium]

**Depends on:** T7

**Files:**
- new `lib/lain/middleware/withhold_automatic_output.rb`
- `lib/lain/cli/tool_guard.rb`
- `lib/lain/approval/escalation.rb`
- specs:
  - new `spec/lain/middleware/withhold_automatic_output_spec.rb`
  - `spec/lain/cli/tool_guard_spec.rb`
  - `spec/lain/approval/escalation_spec.rb`

**Reuse:**
- `Sensitivity::Regions.detect`.
- The escalation record's authority.
- `RefuseSecretWrites`' refusal-result shape.
- `Approval::Remembered`, for the session bar.

**Design.**
- The ladder's decision authority (automatic, or human) rides the invocation context.
- After `bash` returns under automatic authority, the result is scanned. A result carrying any region is
  replaced by a refusal that:
  - names the count;
  - names the move: "ask again; a human will be asked".
- That command string is barred from automatic approval for the rest of the session.
- A human-approved call returns its bytes unchanged.
- The record is `automatic_output_withheld` (`tool_use_id`, region count), with no bytes.

**Shared-file wiring:** a `require_relative "middleware/withhold_automatic_output"` line in
`lib/lain/middleware.rb`.

**Reachable from:** `CLI::ToolGuard` composes the middleware on every agent's stack, parent and child.

**Acceptance criteria**

```gherkin
Scenario: an automatically approved key print is withheld
  Given notes.txt holding a private key, and a rule that approves `cat notes.txt` automatically
  When the call runs
  Then the model receives a withheld refusal naming 1 region

Scenario: the retry goes to a human
  Given that withheld call
  When the model calls `cat notes.txt` again
  Then it parks for a human

Scenario: a human-approved print is untouched
  When a human approves `cat notes.txt`
  Then the result holds the file's bytes

Scenario: ordinary output passes
  When `ls` is approved automatically
  Then its output is unchanged
```

→ spec files:
- `spec/lain/cli/tool_guard_spec.rb` (the production stack)
- `spec/lain/middleware/withhold_automatic_output_spec.rb`

**Escalation triggers:**
- The authority can only be carried as a `Rule::Call` member, which is locked. Stop.
- `redact_secret_reads_spec.rb:431` ("passes an unguarded tool's result through") would change. Stop.
- The escalation record does not know automatic from human. Stop and name where that fact lives.

### T23 — Project-anchored config patterns, `exempt` never licensing automatic approval, and the missing credential rows          [wave 2] [risk: medium]

**Depends on:** T7

**Files:**
- `lib/lain/sensitivity.rb`
- `lib/lain/approval/composed_term.rb`
- `lib/lain/cli/wiring/board_build.rb`
- specs:
  - `spec/lain/sensitivity_spec.rb`
  - `spec/lain/approval/composed_term_spec.rb`
  - `spec/lain/cli/wiring/board_build_spec.rb`

**Reuse:** `Rules.located`, `Rule.within`/`named`/`homed`, the `lifted_by` probe, and the home exact/beneath
split.

**Design.**
- `Sensitivity.new` takes `root:`.
- In config, a pattern with a leading `/` is anchored at the project root. A trailing `/` covers the
  directory and everything beneath it, for `denied` and `gated` only.
- `exempt` accepts an anchored exact file; an anchored directory is refused at load.
- A verdict with reason `exempt` is not ordinary for ComposedTerm: the exemption lifts the prompt, not
  the automatic approval.
- The GATED table gains F181's names, each with a sample:
  - `~/.ssh/` beneath, excluding `*.pub` and `known_hosts`;
  - `.vault-token`;
  - `~/.cargo/credentials.toml`;
  - gcloud application default credentials;
  - `.terraform.d/credentials.tfrc.json`;
  - `~/.azure/`;
  - `~/.kube/config*`.

**Shared-file wiring:** none

**Reachable from:** `BoardBuild.for` builds `Sensitivity::Policy` from `.lain/config.toml`'s
`[sensitivity]` on every attended chat.

**Acceptance criteria**

```gherkin
Scenario: an anchored directory denial covers its contents
  Given `denied = ["/vault/"]`
  When the model reads vault/a.txt, lists vault, or greps across the project
  Then the read refuses, the listing withholds it, and the grep hit is withheld

Scenario: an anchored exemption lifts one file and not the automatic approval
  Given `exempt = ["/fixtures/.env"]`
  When read_file reads fixtures/.env
  Then it reads without a prompt
  And `cat fixtures/.env` still parks for a human

Scenario: an anchored directory exemption refuses at load
  Given `exempt = ["/fixtures/"]`
  When the config loads
  Then it refuses naming the pattern

Scenario: a kube config backup is gated
  When read_file reads ~/.kube/config.bak
  Then it is gated
```

→ spec files:
- `spec/lain/cli/wiring/board_build_spec.rb` (the production policy from a config file)
- `spec/lain/sensitivity_spec.rb`

**Escalation triggers:**
- A built-in DENIED entry becomes liftable. Stop.
- A new locator has no meaningful `lifted_by` sample. Stop.
- The table-wide exempt cap (Open decision 3) seems required. Stop; do not add it.

### T24 — A note's evidence comes from objects or the projection, not the editor buffer          [wave 2] [risk: medium]

**Depends on:** T10

**Files:**
- `lib/lain/review/handover.rb`
- `lib/lain/cli/command/survey.rb`
- `lib/lain/cli/command/review.rb`
- `lib/lain/review/changeset.rb`
- specs:
  - `spec/lain/review/handover_spec.rb`
  - `spec/lain/cli/command/survey_spec.rb`
  - `spec/lain/cli/command/review_spec.rb`
  - `spec/lain/review/changeset_spec.rb`
  - `spec/lain/seams/survey_session_spec.rb`

**Reuse:**
- `Command::Survey`'s `@projection`, the run's one ledger.
- The corpus `Reading#content`.
- `Changeset`'s `git show` readers.

**Design.**
- `Handover` takes an evidence reader:
  - a changeset reads the head blob's line at the anchor;
  - a survey reads the projected corpus `Reading`'s line.
- `annotation_placed.anchor_text` and `revision` come from that reader.
- `drifted` is still forwarded from Lua's raw-buffer measurement.
- The survey's NEW buffer stays raw (the round-11 ruling).

**Shared-file wiring:** none

**Reachable from:** `Command::Survey#call` and `Command::Review#call` construct the `Handover`, which the
nvim rail's `ReviewWrite` drives.

**Acceptance criteria**

```gherkin
Scenario: a note on a masked survey line journals the masked text
  Given a survey over a file whose line 3 holds a credential region
  When the human places a note on line 3
  Then annotation_placed.anchor_text holds the projected line, not the credential

Scenario: a note on a changeset journals the reviewed head
  Given a changeset review whose checkout differs from head_ref at the anchor
  When a note is placed
  Then anchor_text is head_ref's line and revision is head_ref

Scenario: drift is still the editor's measurement
  When Lua reports drifted true
  Then the record carries drifted true unchanged
```

→ spec files:
- `spec/lain/seams/survey_session_spec.rb` (real projection and ledger)
- `spec/lain/review/handover_spec.rb`

**Escalation triggers:**
- Projecting a lone line through `Projection#project` would forget releases (whole-file reconcile). Stop.
- `Review::Session::Replay` or `Anchor#drifted?` would compare projected text against disk lines in a way
  a spec pins. Stop.
- `rpc_thread_spec.rb:799-801`'s `Wire.text` pin would change. Stop.

### T25 — Every approval surface lives for the conversation; plain-chat prompts queue visibly          [wave 3] [risk: high]

**Depends on:** T13

**Files:**
- delete `lib/lain/cli/repl/line_scope.rb`
- `lib/lain/cli/repl/conversation_scope.rb`
- `lib/lain/cli/repl/approval_surfaces.rb`
- `lib/lain/cli/human_replies.rb`
- `lib/lain/frontend/tty.rb`
- `lib/lain/frontend/reline.rb`
- `lib/lain/cli/conductor.rb`
- `lib/lain/frontend/neovim/approval_view.rb`
- `lib/lain/cli/repl.rb`
- specs:
  - delete `spec/lain/cli/repl/line_scope_spec.rb`
  - `spec/lain/cli/repl/conversation_scope_spec.rb`
  - `spec/lain/cli/repl/approval_surfaces_spec.rb`
  - `spec/lain/cli/human_replies_spec.rb`
  - `spec/lain/frontend/tty_spec.rb`
  - `spec/lain/seams/cockpit_answer_surfaces_spec.rb`
  - `spec/lain/seams/plain_chat_prompt_guards_spec.rb`
  - `spec/approval_consumer_discipline_spec.rb`

**Reuse:**
- T13's rail prompts and generations.
- `ConversationScope#open`.
- `Arrivals`.
- `Announcement#document`.
- `AnswerLoop`'s answered-elsewhere race.

**Design.**
- Every approval surface is opened once per conversation: `ApprovalView`, `AutoSurface`,
  `SecretSurface`, `Arrivals` and the terminal `[y/N]`. Terminal prompts are published on the rail one at
  a time, in arrival order.
- **Plain chat (F153):** a prompt queued behind an open one is announced at once with a one-line arrival.
  A queued prompt decided elsewhere, or timed out, prints "decided by <surface>: <verdict>".
- **Plain chat (F171):** a question prints its `Announcement#document` above `human>`, and the pointer
  reads "answer below, or /inbox".
- **The `/inbox` drain** races answered-elsewhere as `AnswerLoop` does (F179, third shape).
- **Deleted:** `LineScope`, `LineEditor::READS`, `Conductor#owning_stdin`, and ticker suppression by an
  open read, so a first Ctrl-C at `human>` draws the countdown (F204).

**Shared-file wiring:** remove `require_relative "repl/line_scope"` from `lib/lain/cli/repl.rb:6`. The
orchestrator applies that one line; the card edits `Repl`'s class body in the same file.

**Reachable from:** `Repl#converse` → `ConversationScope#open`, on every attended chat.

**Acceptance criteria**

```gherkin
Scenario: an idle chat's child park is visible
  Given a cockpit chat at rest, and an attended subagent child (still running after its spawning line) whose gated read parks
  When the approval view sweeps
  Then lain://approval lists the call without any line being typed

Scenario: a plain chat announces an approval queued behind a question
  Given `human>` is open for a question
  When a gated call parks
  Then a one-line arrival naming the call prints above the prompt
  And after the question is answered the [y/N] prompt draws

Scenario: a queued prompt that times out says so
  Given a [y/N] queued behind `human>` whose queue timeout expires
  Then a line says it was denied by timeout

Scenario: Ctrl-C at human> draws the countdown
  When SIGINT arrives while `human>` is open
  Then the shutdown countdown line draws

Scenario: there is still exactly one queue consumer
  Then approval_consumer_discipline_spec passes
```

→ spec files:
- `spec/lain/seams/cockpit_answer_surfaces_spec.rb`
- `spec/lain/seams/plain_chat_prompt_guards_spec.rb`
- `spec/lain/frontend/tty_spec.rb`
- `spec/approval_consumer_discipline_spec.rb`

**Escalation triggers:**
- `AutoSurface` would spend model calls between lines, which is a cost change. Say so in the Execution
  log. If the spend is unbounded, stop.
- `ApprovalView`'s final sweep must still retire decided rows. If a longer life leaves stale rows, stop.
- A `/`-line at `[y/N]` must stay held, never a decision (the round-17 T27 ruling).

### T26 — On an epic re-run, ask whether to keep or delete earlier issue branches          [wave 2] [risk: medium]

**Depends on:** T15

**Files:**
- `lib/lain/cli/epic_driver/issue_actor.rb`
- `lib/lain/cli/epic_driver/factory.rb`
- `lib/lain/isolation/working_branch.rb`
- `lib/lain/cli/command/small.rb` (`ImplementEpic`)
- specs:
  - `spec/lain/cli/epic_driver/issue_actor_spec.rb`
  - `spec/lain/cli/epic_driver/issue_tests_spec.rb`
  - `spec/lain/isolation/working_branch_spec.rb`
  - `spec/lain/cli/command/small_spec.rb`

**Reuse:**
- `WorkingBranch.owned` and its marker (the licence to delete).
- The `refs/lain/worker/*` anchors.
- The criteria digest in the red commit's message (`factory.rb:1108`).
- The chat's question surface.

**Design.**
- `/implement-epic` over an epic whose issues hold lain-owned branches from an earlier run asks the human
  once, listing the branches: keep or delete?
- **Delete:** anchor each tip under `refs/lain/worker/...`, delete the lain-owned branches, and cut fresh
  from the epic tip.
- **Keep**, which is the default with no question on `--resume` or a crash resume: the red step accepts
  an existing red commit on the branch whose message records a matching criteria digest and whose tests
  still fail.
- The brief says the branch was reused rather than claiming it was cut from the tip, and the refusal's
  misleading parenthetical is fixed.

**Shared-file wiring:** none

**Reachable from:** `Command::ImplementEpic` → `EpicDriver` `Run` → `IssueActor#cut`.

**Acceptance criteria**

```gherkin
Scenario: delete starts fresh and keeps the old tip reachable
  Given issue a's branch from a previous run carries a red commit
  When /implement-epic runs and the human answers delete
  Then the branch is recreated at the epic tip
  And a refs/lain/worker ref points at the old tip

Scenario: keep carries the red commit forward
  When the human answers keep
  Then issue a's red step passes on the existing red commit and the actor continues

Scenario: a resumed chat keeps without asking
  Given the chat was resumed mid-epic
  When the driver relaunches issue a
  Then no question is asked and the branch is kept

Scenario: a branch lain did not create still refuses
  Given a branch of the issue's name without lain's marker
  Then the launch refuses naming the branch
```

→ spec files:
- `spec/lain/cli/epic_driver/issue_actor_spec.rb` (real git)
- `spec/lain/cli/command/small_spec.rb`

**Escalation triggers:**
- Deleting would ever move rather than delete an owned branch, which the "never force-move" ruling
  forbids. Stop.
- A carried red commit sits under implementation commits, so "none failed before any work was done" would
  be false. Stop and propose wording.
- `RedOnly`'s net-diff judgement after the rebase changes. Stop.

### T27 — One liveness idiom for resume, watch, sessions and gc          [wave 2] [risk: medium]

**Depends on:** none. Wave 2 for file ownership: `cli/resume.rb` with T2.

**Files:**
- new `lib/lain/liveness.rb`
- `lib/lain/isolation/lease_lock.rb`
- `lib/lain/cli/resume.rb`
- `lib/lain/cli/watch.rb`
- `lib/lain/cli/sessions.rb`
- `lib/lain/isolation/gc.rb`
- `lib/lain/isolation/worktree/leftover.rb`
- `lib/lain/isolation/worktree.rb`
- specs:
  - new `spec/lain/liveness_spec.rb`
  - `spec/lain/cli/resume_spec.rb`
  - `spec/lain/cli/watch_spec.rb`
  - `spec/lain/cli/sessions_spec.rb`
  - `spec/lain/isolation/gc_spec.rb`
  - `spec/lain/isolation/worktree_spec.rb`

**Reuse:**
- `LeaseLock::ProcessTable#verdict` (EPERM reads live; the start-time guard against pid reuse).
- `Resume::WRITER_PID`.

**Design.**
- `Liveness.of(pid, started_at:)` answers live, dead or unknown. `Resume`, `Watch` and `Gc` all ask it,
  and `Resume#alive?` is deleted.
- **`lain watch`** concludes when the writer is dead and no `session_closed` arrived: it prints that the
  writer ended without closing and exits 1 (F169).
- **`lain sessions`** honours `rewound` when naming a head and counting turns (F188).
- **gc** reaps a clean, unmoved checkout whose lock verdict is dead.
- **A lease refusal** names the worker id, and a moved-aside checkout keeps its original retention stamp
  (F198).

**Shared-file wiring:** a `require_relative "lain/liveness"` line in `lib/lain.rb`, before the CLI and
isolation units.

**Reachable from:** `exe/lain` `watch`, `sessions`, `gc`, and `chat --resume`.

**Acceptance criteria**

```gherkin
Scenario: a watch of a crashed session concludes
  Given a session file with no session_closed, whose writer pid is dead
  When `lain watch` tails it
  Then it prints that the writer ended without closing the session and exits 1

Scenario: a live empty session is still tailed
  Given an empty session file whose writer is alive
  Then the watch keeps waiting

Scenario: sessions honours a rewind
  Given a session that rewound 3 turns
  When `lain sessions` lists it
  Then the head and turn count exclude the rewound turns

Scenario: gc reaps a clean checkout abandoned by a dead process
  Given a clean, unmoved worktree whose lock names a dead pid
  When `lain gc` runs
  Then the worktree is reaped
```

→ spec files:
- `spec/lain/cli/watch_spec.rb`
- `spec/lain/cli/sessions_spec.rb`
- `spec/lain/isolation/gc_spec.rb` (real git)

**Escalation triggers:**
- Watch must stay read-only, holding no Store, provider or Channel. If the probe needs a write, stop.
- `Resume`'s EPERM reading flips from dead to live, and a `resume_spec.rb` example asserts the old
  reading. Stop and confirm.
- gc would reap a live or unlocked landing checkout (F116). Stop.

### T28 — Tag the believed reading with the head it measured, and let a held cut survive a withdrawal          [wave 5] [risk: medium]

**Depends on:** T18

**Files:**
- `lib/lain/agent/accounting.rb`
- `lib/lain/agent.rb`
- `lib/lain/status_feed.rb`
- `lib/lain/compaction/source/held_cut.rb`
- `lib/lain/compaction/source.rb`
- `lib/lain/cli/command/introspect.rb`
- specs:
  - `spec/lain/agent/accounting_spec.rb`
  - `spec/lain/status_feed_spec.rb`
  - new `spec/lain/compaction/source/held_cut_spec.rb`
  - `spec/lain/compaction/source_spec.rb`
  - `spec/lain/seams/over_window_request_spec.rb`

**Reuse:** `Accounting#observe_refusal`, `HeldCut.holds?`, and `Timeline` ancestry.

**Design.**
- `last_turn_usage` carries the head digest it measured. A reading whose head is not the current head or
  one of its ancestors reads as absent: nil, never 0, in `Accounting` and `StatusFeed` alike (F203).
- A held cut's commit head becomes the last turn its span needs, not the live head that includes the
  asked user turn. A withdrawal that removes only the asked turn therefore keeps the cut, and the same cut
  is not re-committed on every stuck ask (F173).
- `introspect.rb`'s stale comment is corrected.

**Shared-file wiring:** none

**Reachable from:** `Agent#call_model` feeds `Accounting` on every agent. `CLI::Backend#pipeline_source`
builds the chat's `Compaction::Source`.

**Acceptance criteria**

```gherkin
Scenario: a rewind past a refused turn does not force a compaction
  Given an over-window refusal at 33,000 tokens followed by /rewind 2
  When the next ask renders
  Then approaching_window does not fire on the refused count

Scenario: a stuck ask does not re-commit its cut
  Given a held cut and two consecutive refused asks, each withdrawn
  Then the journal holds exactly one compaction_cut record for that cut

Scenario: a refused count is still believed on the chain it measured
  Given an over-window refusal with no rewind
  When the next render is decided
  Then compaction decides against the refused count

Scenario: the agent and the HUD agree
  Then Agent#occupancy and the status feed read the same value after a rewind
```

→ spec files:
- `spec/lain/seams/over_window_request_spec.rb` (real Agent, RequestBudget and Source)
- `spec/lain/compaction/source_spec.rb`

**Escalation triggers:**
- `held_cut.rb:18-19`'s `--compact-keep` resume guarantee would break. Stop.
- The cut state would need capturing in a pipeline, which breaks Ractor shareability. Stop.
- A resumed session must still read nil as absence. If any path writes 0, stop.

### T29 — One table of static per-tool result ceilings, sized to the smallest local window          [wave 3] [risk: high]

**Depends on:** T4

**Files:**
- `lib/lain/tool/bounds.rb`
- `lib/lain/tools/read_file.rb`
- `lib/lain/tools/bash.rb`
- `lib/lain/tools/memory_read.rb`
- `lib/lain/tools/memory_write.rb`
- `lib/lain/tools/run_skill.rb`
- `lib/lain/tools/ask_human.rb`
- `spec/tool_bounds_discipline_spec.rb`
- specs:
  - `spec/lain/tool/bounds_spec.rb`
  - `spec/lain/tools/read_file_spec.rb`
  - `spec/lain/tools/bash_spec.rb`
  - `spec/lain/tools/memory_read_spec.rb`
  - `spec/lain/tools/memory_write_spec.rb`
  - `spec/lain/tools/run_skill_spec.rb`
  - `spec/lain/tools/ask_human_spec.rb`

**Reuse:**
- The `Tool::Bounds::Artifact` refusal shape, which already names narrower moves.
- The discipline spec's shape sweep.

**Design.**
- `Tool::Bounds::CEILINGS` is one frozen table naming each result-returning tool's byte ceiling. Its one
  comment gives the derivation:
  - the smallest supported local window is 32,768 tokens;
  - one result may take at most a fifth of that window;
  - the byte figure comes from the **minimum** bytes per token the card measures, not from the 3.3x
    token/byte *variance* round 17 recorded. It measures request bytes against the prompt token counts
    in the round-18 QA journals (`~/tmp/lain-qa-round18/xdg/state/lain/sessions/`), separately for
    source code, JSON tool results and prose, and takes each tool's ceiling from the ratio of the
    content that tool returns.
- The figures below are the plan's placeholders. The measurement replaces them, and the Execution log
  records the measured ratios.

| tool | ceiling | note |
|---|---|---|
| `read_file` | 24 KiB | whole read and window alike |
| `bash` | 24 KiB | stdout and stderr together |
| `memory_read` | 24 KiB | also `memory_write`'s body |
| `run_skill` | 24 KiB | |
| `ask_human` | 16 KiB | |
| `subagent` | 16 KiB | already that size; left in place |
| `web_fetch` | 32 KiB | added by T36, sized with the prose ratio |

- `memory_write` also bounds `id` to 128 bytes and `description` to 512 bytes, at the tool and before
  `Memory::Item` (F168).
- Each tool reads its ceiling from the table. Every refusal names the move that fits: windows that add up
  (T4) for `read_file`; piping through `head` or writing to a file for `bash`.
- The discipline spec requires every bounded tool to appear in the table.
- There is no per-model variation.

**Shared-file wiring:** none

**Reachable from:** each tool, as `ToolsetBuild#build` places it on the chat toolset.

**Acceptance criteria**

```gherkin
Scenario: a 30 KiB file read whole refuses and names windows
  Given a 30 KiB source file
  When read_file reads it with no window
  Then it refuses naming the ceiling and offset/limit windows

Scenario: two windows that fit license an edit
  Given the same file read in two delivered windows under 24 KiB each that cover it
  When edit_file is called
  Then the edit applies

Scenario: bash over the ceiling keeps the exit status
  When bash prints 30 KiB and exits 3
  Then it refuses naming the exact size and exit status 3

Scenario: an oversized description is refused before storage
  When memory_write is called with a 300 KiB description
  Then it refuses and nothing is written

Scenario: a new tool cannot ship without a ceiling
  Given a result-returning tool absent from CEILINGS
  Then tool_bounds_discipline_spec fails naming it
```

→ spec files:
- `spec/lain/tools/read_file_spec.rb`
- `spec/lain/seams/unseen_read_spec.rb` (extends T4's seam through the ceiling)
- `spec/lain/tools/bash_spec.rb`
- `spec/lain/tools/memory_write_spec.rb`
- `spec/tool_bounds_discipline_spec.rb`

**Escalation triggers:**
- `bash_spec.rb:600-620`'s byte-identical refusals across arms break. Stop.
- A committed recorded cassette carries a result over the new ceilings. Stop.
- The measured minimum is under 2 bytes per token, which would put `read_file` under 12 KiB. Stop and
  report the ratios before sizing anything.
- `read_file`'s 16 KiB separator block size is a different number (it is not a ceiling). Leave it
  unchanged.

### T30 — Judge a leased child's shell calls against its own worktree          [wave 3] [risk: medium]

**Depends on:** T7

**Files:**
- `lib/lain/cli/tool_guard.rb`
- `lib/lain/cli/wiring/board_build.rb`
- `lib/lain/approval/escalation.rb`
- `lib/lain/cli/switchboard.rb` (`build_ladder`, `switchboard.rb:348-352`)
- specs:
  - `spec/lain/cli/tool_guard_spec.rb`
  - `spec/lain/cli/wiring/board_build_spec.rb`
  - `spec/lain/approval/escalation_spec.rb`
  - new `spec/lain/seams/child_worktree_approval_spec.rb`
  - `spec/lain/cli/switchboard_spec.rb`

**Reuse:**
- `ToolGuard.child_stack(worker_env)`.
- `GuardTestLayout::Run#roots_for(worker_env)`, the precedent.
- `BoardBuild::Classifiers`.

**Design.**
- `ToolGuard.child_stack` builds the child's `Classifiers` factory from the child's worker env: the root
  is the lease path. It is handed to both the Triage rung and the Rules rung the child is judged by.
- The board's one policy, one ledger and one `Filter.new` are kept.
- The parent is unchanged.

**Shared-file wiring:** none

**Reachable from:** `Tools::Subagent::ChildBuilder` → `CLI::ToolGuard.child_stack` for every leased
child.

**Acceptance criteria**

```gherkin
Scenario: a child's symlink to a key is judged in its worktree
  Given a child leased into a worktree holding keylink, a symlink to a 0600 key in that worktree
  When the child calls `cat keylink`
  Then automatic approval abstains

Scenario: an ordinary read in the child's worktree is approved
  When the child calls `cat README.md`
  Then it is approved automatically

Scenario: the parent's judgements are unchanged
  Then the parent's `cat README.md` is approved against the project root

Scenario: there is still one listing filter
  Then lib/ holds exactly one Filter.new
```

→ spec files:
- `spec/lain/seams/child_worktree_approval_spec.rb` (real worktree lease and ToolGuard)
- `spec/lain/cli/tool_guard_spec.rb`

**Escalation triggers:**
- Triage and ComposedTerm would see different roots. Stop.
- The lease sits outside `project.root`, so the root predicate would abstain on every child call. Stop if
  the root cannot be the lease.
- `Rule::Call` would need a new member. Stop.

### T31 — A review round can be closed, a refused one binds nothing, and a resumed reopen is a new round          [wave 3] [risk: medium]

**Depends on:** T24

**Files:**
- `lib/lain/cli/command/review.rb`
- `lib/lain/cli/command/survey.rb`
- `lib/lain/review/session.rb`
- `lib/lain/review/handover.rb`
- `lib/lain/review/submit/outbox.rb`
- `lib/lain/frontend/neovim/rpc_thread.rb`
- `lib/lain/frontend/neovim/runtime/65_review.lua`
- specs:
  - `spec/lain/cli/command/review_spec.rb`
  - `spec/lain/cli/command/survey_spec.rb`
  - `spec/lain/review/session_spec.rb`
  - `spec/lain/review/submit/outbox_spec.rb`
  - `spec/lain/frontend/neovim/rpc_thread_spec.rb`
  - `spec/lain/frontend/neovim/runtime/65_review_spec.rb`

**Reuse:**
- `Session.open`'s journal-first rule.
- `ReviewWrite`'s router.
- The sidebar placeholder rendering.
- `resumed_from` in the header.

**Design.**
- `/review close` and `:LainReviewClose` journal `review_closed` (the round, no verdict), unbind the rails,
  release the outbox hold, and post a placeholder sidebar.
- A ceiling or scope refusal raised after the bind unbinds the rails and outbox, so nothing is bound, and
  posts a placeholder naming the refusal (F143).
- In a resumed chat, `/review` or `/survey` of a target the resumed-from session had an open round on
  opens a new round with a banner saying the earlier notes are not carried over (F157).
- `VERDICTS` is unchanged.

**Shared-file wiring:** none

**Reachable from:** the `Command::Registry` built in `CLI::Wiring`, and `RpcThread`'s `ReviewWrite`
router for `:LainReviewClose`.

**Acceptance criteria**

```gherkin
Scenario: closing a survey frees /review
  Given an unsettled survey round
  When /review close is typed and then /review main
  Then the review opens and the journal holds review_closed for the survey round

Scenario: a verdict after close is refused
  Given a closed round
  When an approve arrives on the rail
  Then the answer says no round is open

Scenario: a ceiling refusal leaves nothing bound
  Given /review of a changeset over the line ceiling
  Then the outbox is not open, the rails are unbound, and the sidebar shows the refusal placeholder

Scenario: a resumed reopen says it is new
  Given a resumed chat whose earlier session had an open survey of big/
  When /survey big is typed
  Then a new round opens with the not-carried-over banner
```

→ spec files:
- `spec/lain/cli/command/review_spec.rb`
- `spec/lain/cli/command/survey_spec.rb`
- `spec/lain/frontend/neovim/runtime/65_review_spec.rb` (real nvim)

**Escalation triggers:**
- `check_presentation!` would gain a second caller. Stop.
- Bind-before-draw's "human fast enough" race would reopen. Stop.
- A gesture rail would raise rather than answer a String. Stop.
- `@held` must survive for `/review-submit` after a settle.

### T32 — An input socket for the chat, and `lain input` as the pane that feeds it          [wave 4] [risk: high]

**Depends on:** T13

**Files:**
- new `lib/lain/cli/input_socket.rb`
- new `lib/lain/frontend/input_pane.rb`
- `lib/lain/frontend/input_rail.rb`
- `exe/lain`
- `lib/lain/cli/wiring.rb`
- `lib/lain/cli/signals.rb`
- `lib/lain/cli/conductor.rb`
- specs:
  - new `spec/lain/cli/input_socket_spec.rb`
  - new `spec/lain/frontend/input_pane_spec.rb`
  - `spec/lain/frontend/input_rail_spec.rb`
  - `spec/lain/cli/signals_spec.rb`
  - `spec/lain/cli_spec.rb`
  - new `spec/lain/seams/input_pane_socket_spec.rb`

**Reuse:**
- T13's rail values and `StdinPump`'s editor loop.
- `Paths#runtime_dir` and `project_hash`.
- `Up::Cockpit#derived_socket`, which names a socket with no pid (`up.rb:667-671`).
- `StatusFeed` publication, for layers, the HUD and the command names.
- `PromptComposer`'s HUD rendering.

**Design.**
- **The server.** `lain chat --input socket:<name>` makes an `InputSocket` server the rail's producer.
  The chat never reads stdin in that mode.
  - The socket path is `runtime_dir/input-<project_hash>-<name>.sock`, with no pid, so `lain up` can
    write both pane commands before either process starts, and a restarted chat binds the same path.
    `<name>` is the tmux session name, or `chat`. The directory is 0700 and the socket 0600.
  - Before binding, the chat probes an existing path with `connect()`. A refused connection is a stale
    socket, which is unlinked. A live one refuses the second chat by name.
  - The codec is newline-delimited JSON of the rail values.
- **The countdown on the rail.** `Prompt` gains the kind `countdown`: the chat publishes it when the
  shutdown countdown opens, with the keys it accepts (`c`, `w`, `r`). The pane shows it, sends the chosen
  key as a `Signal`, and returns to the line prompt when the countdown closes. T41 adds `s`.
- **The pane.** `lain input --socket PATH` runs `Frontend::InputPane`:
  - it runs `StdinPump`'s editor (Reline, history, vi from the published layers) against the prompt the
    chat publishes;
  - completion draws its command names from the published command list, since the pane holds no
    registry;
  - above the editor it draws a live header, the HUD line `PromptComposer` renders, refreshed when the
    publication changes, with no keypress needed;
  - it sends `Line`, `Signal` and `Eof`; Ctrl-C in the pane sends `Signal(sigint)`;
  - it reconnects when the chat restarts, and exits when the chat closes cleanly.
- `Signals#current` exposes the routed sink, so a socket signal reaches `Shutdown` or `PromptBreaker`.
- **Other windows.** Composed `/fork` and `/btw` windows keep a plain `lain chat` with its in-process pump;
  no input pane is opened for them.

**Shared-file wiring:**
- a `require_relative "cli/input_socket"` line in `lib/lain/cli.rb`;
- a `require_relative "frontend/input_pane"` line in `lib/lain/frontend.rb`, after `frontend/input_rail`.

**Reachable from:** `exe/lain chat --input socket:<name>` → `CLI::ChatLaunch` → `CLI::Wiring#run`;
`exe/lain input` → `Frontend::InputPane`. T40 composes both from `lain up`.

**Acceptance criteria**

```gherkin
Scenario: a prompt typed in the pane is answered by the chat
  Given a chat process started with --input socket:s1 and a `lain input` process in a PTY on that path
  When "hello" is typed in the pane and Enter pressed
  Then the chat journals a user turn "hello"

Scenario: an approval is answered from the pane
  Given the chat parks a gated call
  When the pane shows the [y/N] prompt and "y" is entered
  Then the call is approved by the pane's surface

Scenario: the countdown is driven from the pane
  When Ctrl-C is pressed in the pane during a running ask
  Then the pane shows the countdown keys
  And pressing c in the pane cancels the shutdown and the ask continues

Scenario: the pane's header stays live
  Given the pane idle at `you>`
  When the chat's published occupancy changes
  Then the header's HUD line shows the new value without a keypress

Scenario: the chat never reads its stdin
  Given the chat's stdin is closed
  Then the chat keeps running and accepts pane input

Scenario: a restarted chat is reconnected, and a stale socket is replaced
  Given the chat was killed, leaving its socket file behind
  When a new chat starts with --input socket:s1
  Then it binds the same path, and the pane's next line reaches the new chat

Scenario: a second live chat on one path refuses
  Given a live chat on socket s1
  When another chat starts with --input socket:s1
  Then it refuses naming the path
```

→ spec files:
- `spec/lain/seams/input_pane_socket_spec.rb` (two real processes and a real Unix socket)
- `spec/lain/cli/input_socket_spec.rb`
- `spec/lain/frontend/input_pane_spec.rb`

**Escalation triggers:**
- Terminal writes would be needed outside `lib/lain/frontend/`. Stop (output discipline).
- A countdown driven over the socket would need `Shutdown` to read keys from somewhere other than a
  `Signal`. Stop.
- The pane's `lain` binary would come from the spec runner's PATH (the tmux PATH trap). The spec must
  exec the repo's `exe/lain`.
- Reline redrawing its header while a line is being edited needs a private API. Stop and propose
  redrawing the header only between keystrokes.

### T33 — A mode is scope × approval: delete the posture table, keep one toolset          [wave 1] [risk: high]

**Depends on:** none

**Files:**
- `lib/lain/mode.rb`
- delete `lib/lain/mode/posture.rb`
- new `lib/lain/mode/approval.rb`
- new `lib/lain/mode/scope.rb`
- `lib/lain/mode/resolution.rb`
- `lib/lain/mode/switch.rb`
- `lib/lain/cli/switchboard.rb`
- `lib/lain/approval/policy_switch.rb`
- `lib/lain/approval/gate.rb`
- `lib/lain/middleware/gate.rb` (`ApproveAll`, `gate.rb:43`)
- `lib/lain/approval/escalation.rb` (`Escalation.for`)
- `lib/lain/cli/journal_tee.rb`
- `lib/lain/cli/command/mode.rb`
- `lib/lain/status_feed/mode_state.rb`
- `lib/lain/frontend/prompt_composer.rb`
- `lib/lain/compare/posture.rb`
- `lib/lain/compare.rb`
- `lib/lain/bench/variance.rb`
- `lib/lain/bench/session/loader.rb`
- `lib/lain/cli/wiring/toolset_build.rb`
- `lib/lain/tools/subagent.rb`
- `lib/lain/tools/subagent/lineage.rb` (the spawn body's `"posture"` key, `lineage.rb:66`)
- `lib/lain/cli/goal_driver.rb`
- `lib/lain/telemetry/switches.rb`
- `lib/lain/prompt/default.toml`
- specs:
  - `spec/lain/mode_spec.rb`
  - delete `spec/lain/mode/posture_spec.rb`
  - new `spec/lain/mode/approval_spec.rb`
  - new `spec/lain/mode/scope_spec.rb`
  - `spec/lain/mode/resolution_spec.rb`
  - `spec/lain/mode/switch_spec.rb`
  - `spec/lain/cli/switchboard_spec.rb`
  - `spec/lain/cli/journal_tee_spec.rb`
  - `spec/lain/cli/command/mode_spec.rb`
  - `spec/lain/status_feed/mode_state_spec.rb`
  - `spec/lain/compare/posture_spec.rb`
  - `spec/lain/bench/session/loader_spec.rb`
  - `spec/lain/cli/wiring/toolset_build_spec.rb`
  - `spec/lain/tools/subagent_gate_spec.rb`
  - `spec/lain/cli/command/undo_spec.rb`
  - `spec/lain/cli/wiring_spec.rb`
  - `spec/lain/tools/subagent/lineage_spec.rb`
  - `spec/lain/compare_spec.rb`
  - `spec/lain/bench/variance_spec.rb`

**Reuse:**
- `Escalation.for`'s ladder.
- `LayerSet`.
- `SnapshotSlot#rebind`.
- `Compare`'s axis machinery.
- `Mode::Switch`'s build-before-assign check.

**Design.**
- **The value.** `Mode` is `(scope, approval, layers)`. Scope is `checkout` here; T47 adds `plan`.
- **Approval.**
  - `ask` is today's `accept_edits` ladder: Triage, Rules, Surfaces.
  - `auto` is Triage, Rules, then approve the remainder, so triage and rule denies still decide (F63
    under `auto`).
- **Deleted:** `POSTURES`, `READ_ONLY`, `Permits`, `ToolsetBuild::PosturePermits`, `Seam#permits` and the
  `deny_all` mapping. The toolset never changes with the mode, so the tool block's cache stays stable.
- **Snapshots:** the scope is always `shadow_git`, with `write_set` kept as the degraded fallback.
- **`/mode` tokens:** `ask`, `auto`, `checkout`, `!`, and `+layer`/`-layer`.
  - Two tokens from one axis refuse, naming both (F187).
  - `plan`, `manual` and `accept_edits` refuse by name; `plan` until T47.
- **Journaling.**
  - `Mode::Switch` writes its record before it assigns.
  - A no-op flip writes nothing, in `Switch` and `PolicySwitch` alike.
  - `JournalTee` answers `#record` (F146).
- **Records and readers.**
  - `mode_switch` records the from/to scope, approval and layers.
  - `Compare::Posture` becomes the mode axis.
  - The loader reads the new shape only.
- The lighters show the scope and approval.

**Shared-file wiring:** in `lib/lain/mode.rb`'s index, replace `mode/posture` with `mode/approval` and
`mode/scope`.

**Reachable from:** `CLI::Switchboard.for`, constructed in `CLI::Wiring`; `/mode` through
`Switchboard`'s `BoundSwitch`.

**Acceptance criteria**

```gherkin
Scenario: auto still honours a triage deny
  Given `/mode auto`
  When the model calls bash writing under a protected path that triage denies
  Then the call is denied, not approved

Scenario: contradictory tokens refuse
  When `/mode ask auto` is typed
  Then it refuses naming ask and auto and the mode is unchanged

Scenario: a no-op flip journals nothing
  Given the vi layer is on
  When `/mode +vi` is typed
  Then no mode_switch or policy_switch record is written

Scenario: a switch applies wholly under --no-journal --nvim
  Given `lain chat --no-journal --nvim`
  When `/mode auto` and then `/goal x` are typed
  Then the gate policy is the auto ladder and the goal drives, with no NoMethodError

Scenario: the toolset does not change with the mode
  Then the tool block's digest is identical before and after `/mode auto`

Scenario: retired names refuse
  When `/mode manual` is typed
  Then it refuses naming manual and listing the tokens
```

→ spec files:
- `spec/lain/cli/switchboard_spec.rb` (the production `Switchboard.for`)
- `spec/lain/cli/command/mode_spec.rb`
- `spec/lain/mode/switch_spec.rb`
- `spec/lain/cli/wiring_spec.rb`

**Escalation triggers:**
- Committed fixture journals under `spec/` name postures. Regenerate or edit them; never add an alias.
- `undo_spec.rb:489-530` pins `manual`'s `write_set` scope. Delete those examples with the reason.
- `approval_consumer_discipline_spec` or the `AutoSurface` partition would change. Stop.
- `CLI::Wiring` would need edits beyond construction arguments (T2 owns it this wave). Stop.
- Dropping `posture` from the spawn body changes every spawn digest. That is expected: say so in the
  Execution log. If a committed fixture's digests are pinned, regenerate it.

### T34 — Give child agents a model phase: a request budget with worded refusals, recorded as theirs          [wave 4] [risk: medium]

**Depends on:** T18, T19

**Files:**
- `lib/lain/tools/subagent.rb`
- `lib/lain/middleware/request_budget.rb`
- `lib/lain/status_feed.rb`
- `lib/lain/review/critique.rb`
- specs:
  - `spec/lain/tools/subagent_spec.rb`
  - `spec/lain/middleware/request_budget_spec.rb`
  - `spec/lain/status_feed_spec.rb`
  - `spec/lain/review/critique_spec.rb`
  - `spec/lain/seams/critique_over_held_review_spec.rb`

**Reuse:**
- `Wiring#model_phase`'s composition.
- The seam's durable journal.
- T18's `StopReason`.

**Design.**
- `spawn_agent` composes a child `RequestBudget` writing to the seam's **durable** journal, never the tee.
- The child's wording names the child and its task and never offers `/rewind`.
- `StatusFeed#observe_refusal` ignores a `window_pressure` that names a spawn.
- `Critique#answer`'s chunk text is the worded refusal naming the chunk, not the provider's JSON.

**Shared-file wiring:** none

**Reachable from:** `Tools::Subagent#spawn_agent` on the chat toolset; `/critique` → `Review::Critique`.

**Acceptance criteria**

```gherkin
Scenario: an over-window critique chunk is worded
  Given a critique child whose request the provider refuses as over-window
  When the findings merge
  Then that chunk's text names the chunk and the window and contains no JSON
  And the other chunks' findings are present

Scenario: a child's pressure does not move the parent's HUD
  When a child's window_pressure is recorded
  Then the parent's occupancy reading is unchanged
  And the record is in the durable journal only
```

→ spec files:
- `spec/lain/seams/critique_over_held_review_spec.rb`
- `spec/lain/status_feed_spec.rb`

**Escalation triggers:**
- A child's record could be paired as the parent's by salvage or `cache_waste`. Stop.
- `critique_spec.rb:172-181` pins the provider's message in the findings. Update it deliberately.

### T35 — Re-collapse held cuts into one superseding cut          [wave 6] [risk: high]

**Depends on:** T28

**Files:**
- `lib/lain/compaction/source.rb`
- `lib/lain/compaction/source/held_cut.rb`
- `lib/lain/compaction/source/derived.rb`
- `lib/lain/telemetry/compaction_cut.rb`
- `lib/lain/session_record/replay.rb`
- specs:
  - `spec/lain/compaction/source_spec.rb`
  - new `spec/lain/compaction/source/held_cut_spec.rb`
  - `spec/lain/compaction/derivation_spec.rb`
  - `spec/lain/telemetry/compaction_cut_spec.rb`
  - `spec/lain/session_record/replay_spec.rb`

**Reuse:**
- `CompactionCut`'s parent deltas.
- `HeldCut`.
- `Derived`.
- The summarize strategy's oracle.

**Design.**
- `CompactionCut` gains `kind` (`advance`, `collapse` or `handoff`) and `supersedes` (the cut digests it
  replaces). `HeldCut` and the seam drop superseded cuts.
- When more than one cut is held and a signal fires with nothing droppable past them, `Source` commits a
  `collapse` cut:
  - its range spans the union of the held ranges, over raw turns;
  - its replacement is written from the held replacements' text.
- **A stated narrowing of the non-recursive rule:** the record still spans raw turns; only the
  summarizer's input may be earlier replacements.
- Replay folds `supersedes`.

**Shared-file wiring:** none

**Reachable from:** `CLI::Backend#pipeline_source` → `Compaction::Source` on every journaled chat.

**Acceptance criteria**

```gherkin
Scenario: accumulated summaries collapse into one
  Given four held advance cuts under summarize-conversation and a signal with nothing droppable
  When the next render is decided
  Then one collapse cut supersedes the four and the render holds one replacement

Scenario: a resume renders the collapse
  Given a session file holding those cuts and the collapse
  When it resumes
  Then the render is byte-identical to the live one

Scenario: a withdrawal keeps the collapse
  When the next ask is refused and withdrawn
  Then the collapse still holds and is not re-committed
```

→ spec files:
- `spec/lain/compaction/source_spec.rb`
- `spec/lain/session_record/replay_spec.rb`

**Escalation triggers:**
- The derivation itself would have to hold a derived head. Stop: that is the design T7 ruled out.
- `shrinks?`'s strict saving would decline every collapse. Stop and report the measurement.
- "The cut wins over keep_last" stays dropped for `advance` and `collapse`.

### T36 — `web_fetch` returns readable text          [wave 4] [risk: medium]

**Depends on:** T29

**Files:**
- `lib/lain/tools/web_fetch.rb`
- new `lib/lain/tools/web_fetch/readable.rb`
- `lib/lain/tool/bounds.rb`
- `spec/tool_bounds_discipline_spec.rb`
- specs:
  - `spec/lain/tools/web_fetch_spec.rb`
  - new `spec/lain/tools/web_fetch/readable_spec.rb`

**Reuse:**
- `WebFetch#rendered` after `Text.decode` (`web_fetch.rb:564-570`).
- `ByteCap`'s 5 MiB network cap, unchanged.
- The `CEILINGS` table.
- `Tool::Input` for `raw`.

**Design.**
- `WebFetch::Readable.call(html, base_url)`, over nokogiri:
  - drops `script`, `style`, `nav`, `header`, `footer`, `aside`, `form`, `noscript` and `svg`;
  - prefers `main`/`article`;
  - renders headings as `#`, list items as `-`, and links as `text (absolute url)`;
  - keeps `pre`/`code` verbatim and collapses whitespace.
- It applies to `text/html` unless `raw: true`, a new boolean field on `Input`.
- `web_fetch`'s ceiling is 32 KiB of result text (raw or readable). A refusal names the size and, for
  readable text, a narrower URL or fragment.
- `web_fetch`'s EXEMPT row is deleted. `AWAITING_RULING` stays, because `request_review` still holds it
  (`tool_bounds_discipline_spec.rb:310`).

**Shared-file wiring:**
- in `lain.gemspec`, `spec.add_dependency "nokogiri"`, pinned to the version `bundle install` resolves,
  followed by `bundle install` (orchestrator);
- a `require_relative "tools/web_fetch/readable"` line in `lib/lain/tools.rb`, after `tools/web_fetch`.

**Reachable from:** `web_fetch` in the base toolset built by `ToolsetBuild#build`.

**Acceptance criteria**

```gherkin
Scenario: an HTML article becomes text
  Given a fetched page with a nav, a script, and an article holding an h2 and a link
  When web_fetch renders it
  Then the result holds "## " before the heading and "text (https://…)" for the link
  And no nav or script text

Scenario: raw returns markup
  When web_fetch is called with raw true
  Then the result holds the HTML

Scenario: non-HTML is untouched
  Given a text/plain response
  Then the result is the decoded body

Scenario: oversized text refuses
  Given an article whose readable text is 60 KiB
  Then web_fetch refuses naming the size and the ceiling
```

→ spec files:
- `spec/lain/tools/web_fetch_spec.rb` (injected Faraday connection, no network)
- `spec/lain/tools/web_fetch/readable_spec.rb`

**Escalation triggers:**
- nokogiri fails to build against mise ruby 4.0.6. Stop.
- `ByteCap`'s streaming would change. Stop.

### T37 — Bound `bash`'s capture while it runs, on one runner for both Ruby arms          [wave 4] [risk: high]

**Depends on:** T29

**Files:**
- new `lib/lain/exec/capture.rb`
- `lib/lain/exec/local.rb`
- `lib/lain/shell/pipeline.rb`
- `lib/lain/tools/bash.rb`
- `lib/lain/exec/core.rb`
- specs:
  - new `spec/lain/exec/capture_spec.rb`
  - `spec/lain/exec/local_spec.rb`
  - `spec/lain/shell/pipeline_spec.rb`
  - `spec/lain/tools/bash_spec.rb`
  - `spec/lain/exec/core_spec.rb`

**Reuse:**
- `Shell::Pipeline::Run`: process group, TERM→grace→KILL, `cwd`, live sinks, `in: File::NULL`.
- `Bash.render_output` as the one renderer.
- `Exec::Timeout`.

**Design.**
- `Exec::Capture` counts every byte of stdout and stderr, retains up to the ceiling plus one byte, keeps
  draining the pipes, and forwards every chunk to the live sinks.
- Both Ruby arms fill a capture. The string arm runs as a one-stage `["sh", "-c", command]` through
  `Shell::Pipeline::Run`, so mixlib leaves `Exec::Local` and `Exec::Local`'s `shell_out_factory` seam is deleted. The seams in
  `Isolation::SelfSync`, `Compose` and `Worktree::Registry` are untouched.
- Timeout messages quote the bounded capture.
- The verdict split, where a term never reaches a shell, is unchanged: only the runner is shared.
- The daemon arm is unchanged, and its doc names the asymmetry (Open decision 7).

**Shared-file wiring:** a `require_relative "exec/capture"` line in `lib/lain/exec.rb`, before
`exec/local`.

**Reachable from:** `Tools::Bash` through the exec backend `CLI::ExecBackend` builds in `CLI::Wiring`.

**Acceptance criteria**

```gherkin
Scenario: a flood is bounded while captured
  Given `head -c 200000000 /dev/zero | tr '\0' a` approved as a term
  When bash runs it
  Then the refusal names 200000000 bytes and exit status 0
  And the capture retained at most the ceiling plus one byte

Scenario: both arms refuse identically
  Given the same over-ceiling output from the string arm and the term arm
  Then the two refusals are byte-identical

Scenario: the string arm cannot rewind a regular-file stdin
  Given `lain chat < prompts.txt` whose prompt triggers a string-arm bash call
  Then every prompt is asked once

Scenario: a timeout over the ceiling stays out of the result
  When a command times out after printing 1 MiB
  Then the timeout result quotes at most the ceiling
```

→ spec files:
- `spec/lain/tools/bash_spec.rb`
- `spec/lain/exec/capture_spec.rb`
- `spec/lain/seams/stdin_regular_file_spec.rb` (T13's, extended)

**Escalation triggers:**
- The exit status would be replaced by a signal. Stop: never kill the group at the ceiling.
- The `live_stdout` streaming contract changes for the human. Stop.
- An RSS-based assertion flakes under `rake pspec`. Assert retained bytes on the capture instead.
- The `:core` tier's parity needs `rake core:build`; run it once and log it.

### T38 — Approval judges are unattended, and a judge's child refuses rather than parks          [wave 4] [risk: medium]

**Depends on:** T19, T30

**Files:**
- `lib/lain/role/catalog.rb`
- `lib/lain/cli/tool_guard.rb`
- `lib/lain/approval/auto_surface.rb`
- `lib/lain/approval/gate/adjudicator.rb`
- `lib/lain/prompt/slots.rb`
- `lib/lain/cli/wiring/toolset_build.rb`
- specs:
  - `spec/lain/role_spec.rb`
  - `spec/lain/cli/tool_guard_spec.rb`
  - `spec/lain/approval/auto_surface_spec.rb`
  - `spec/lain/approval/gate/adjudicator_spec.rb`
  - `spec/lain/prompt/slots_spec.rb`

**Reuse:**
- `Switchboard::Unattended`, the single always-deny rung.
- `Role#unattended`.
- `Skill::RoleSpawn`'s tool-guard argument.

**Design.**
- `auto_approver` and `gate_adjudicator` declare `unattended: true`, so neither is granted `ask_human`.
- **A child spawned by an approval judge surface** (`AutoSurface` or the gate adjudicator) is built with the
  Unattended rung, passed by that surface at its spawn site. Its gated read or region release refuses with
  words instead of parking. Such a child's park would wait on the very sweep that spawned it.
- **The docent and other unattended roles still park,** and T25 makes the park visible in an idle chat.
  This is a property of the spawn site, not of `Role#unattended`, which keeps meaning "never asks a human".
- A slot file with the wrong extension is named, with the expected extension (F190).
- One role has one spelling: the `reviewer_code`/`reviewer-code` duplication is removed.

**Shared-file wiring:** none

**Reachable from:** `AutoSurface#answer_for` and `Gate::Adjudicator` → `Skill::RoleSpawn` →
`CLI::ToolGuard.child_stack`, on every attended chat with `+auto_approve` and every adjudicated epic
stage.

**Acceptance criteria**

```gherkin
Scenario: a judge cannot ask a human
  When the automatic approver spawns auto_approver
  Then its toolset holds no ask_human

Scenario: a judge's gated read refuses instead of parking
  Given the automatic approver's child reads .env
  Then the read refuses with words and nothing parks in the approval queue

Scenario: a docent's gated read still parks
  Given a diff_docent child reads .env
  Then the read parks for a human

Scenario: a mistyped slot file is named
  Given .lain/slots/role/dev.txt
  Then loading names dev.txt and the expected .md extension
```

→ spec files:
- `spec/lain/approval/auto_surface_spec.rb` (the production spawn through `RoleSpawn`)
- `spec/lain/cli/tool_guard_spec.rb`
- `spec/lain/prompt/slots_spec.rb`

**Escalation triggers:**
- A refused read would make the judge approve rather than defer. Stop: the rule is deny when unsure.
- `role_spec.rb:74-94`'s roll call of unattended roles changes beyond the two judges. Stop.
- The surface cannot pass the rung without a new `Role` attribute. Stop and propose.

### T39 — One project memory store for all memory          [wave 3] [risk: high]

**Depends on:** T1, T4

**Files:**
- new `lib/lain/memory/project_store.rb`
- `lib/lain/memory/recorder.rb`
- `lib/lain/memory/journal_memory_root.rb`
- `lib/lain/bench/session/memory_replay.rb`
- `lib/lain/bench/session/loader.rb`
- `lib/lain/session_record/replay.rb` (a resumed chat's recorder, `replay.rb:75`)
- `lib/lain/cli/wiring.rb`
- `lib/lain/session.rb`
- `lib/lain/bench/cli/run_recorder.rb`
- `lib/lain/bench/cli.rb`
- `exe/lain` (`--memory` on `bench record` and `bench arms`)
- new `lib/lain/telemetry/memory_loaded.rb`
- specs:
  - new `spec/lain/memory/project_store_spec.rb`
  - `spec/lain/memory/recorder_spec.rb`
  - `spec/lain/memory/journal_memory_root_spec.rb`
  - `spec/lain/bench/session/memory_replay_spec.rb`
  - `spec/lain/bench/session/loader_spec.rb`
  - `spec/lain/session_record/replay_spec.rb`
  - `spec/lain/cli/wiring_spec.rb`
  - `spec/lain/bench/cli/run_recorder_spec.rb`
  - new `spec/lain/seams/project_memory_spec.rb`

**Reuse:**
- `Memory::Item`, `Recorder`, `Index` and `Manifest`.
- `Paths#state_home` and `project_hash`.
- `RefuseSecretWrites`.
- The `memory_root` integrity check.

**Design.** Two objects, kept apart: the project's durable **store**, and each session's **view** of it.

- **The store.** `Memory::ProjectStore` lives at `state_home/memory/<project_hash>/store.ndjson`: an
  append-only file of `Item`s, each with its digest. A write takes the store's lock off the reactor, so a
  wait never blocks the Async loop. Entries are unique by digest.
- **The view.** A session's view is the store version it **loaded**, plus the writes **on its current
  chain**.
  - A fresh chat loads the store head and journals `memory_loaded`: the version and the loaded items'
    ids, descriptions and bodies.
  - `memory_write` appends to the store **and** to the view.
  - A turn's `memory_root` names the **view's** digest, so another chat's writes mid-session never change
    this session's render or its verification.
- **Replay and resume.**
  - `SessionRecord::Replay#memory` and `MemoryReplay` seed the view from `memory_loaded` and fold the
    chain's recorded writes, so a session file is self-contained and a resume renders exactly what was
    recorded.
  - A resumed chat keeps its recorded view. It does not pick up entries other chats added since; a fresh
    chat does. The resume notice says how many newer entries the store holds.
- **`/rewind`** past a `memory_write` removes it from the view, because the view follows the chain. The
  entry stays in the store, where a fresh chat will see it.
- **Children** keep today's fresh, empty recorder. That is stated, not changed.
- **Bench.** `bench record` and `bench arms` start from the empty version unless given `--memory
  project`, and journal it.
- **The boundary.** It is called "project memory", and nothing in `Compaction` reads or writes it.

**Shared-file wiring:**
- a `require_relative "memory/project_store"` line in `lib/lain/memory.rb`, before `memory/recorder`;
- a `require_relative "telemetry/memory_loaded"` line in `lib/lain/telemetry.rb`.

**Reachable from:**
- `CLI::Wiring#run_state` builds a fresh chat's view over `ProjectStore`.
- `SessionRecord::Replay#memory` builds a resumed chat's view (`wiring.rb:329` takes `resumed.recorder`).
- T45 wires `lain consolidate` to the store.

**Acceptance criteria**

```gherkin
Scenario: a fresh chat sees an earlier chat's memory
  Given chat A wrote memory "db-conventions" in a project
  When a fresh chat B starts in that project
  Then B's first request's manifest lists "db-conventions"

Scenario: another chat's write mid-session does not change this session
  Given chat A running, and chat B writes memory "other" to the store
  When chat A renders its next request and its memory_root is verified
  Then A's manifest does not list "other" and verification passes

Scenario: a resume replays the recorded view exactly
  Given a session file with memory_loaded and one memory_write
  When the chat resumes
  Then its rendered manifest equals the recorded one and every memory_root verifies

Scenario: a rewind past a write, then a resume
  Given a session that wrote "tmp-note" and then rewound past that turn
  When it resumes
  Then the manifest does not list "tmp-note", verification passes, and the store still holds "tmp-note"

Scenario: compaction never touches project memory
  When a compaction cut commits
  Then the store's contents are unchanged

Scenario: a bench recording starts empty
  When `lain bench record` runs without --memory
  Then its memory_loaded names the empty version
```

→ spec files:
- `spec/lain/seams/project_memory_spec.rb` (the production `Wiring#run_state` and
  `SessionRecord::Replay#memory` over a tmp `XDG_STATE_HOME`)
- `spec/lain/bench/session/loader_spec.rb`
- `spec/lain/memory/project_store_spec.rb`

**Escalation triggers:**
- `loader_spec.rb:675-721`'s `memory_root` chain cannot be restated over view digests. Stop.
- Committed recorded sessions under `spec/fixtures` hold `memory_root`. Regenerate them, or stop if they
  cannot be regenerated.
- The store would land in `.lain/`, against the F50 rule. Stop.
- `memory_loaded` bodies make session files large (the store over a few MiB). Stop and propose recording
  digests with a content-addressed side file.

### T40 — `lain up` lays out the chat over its input pane          [wave 5] [risk: high]

**Depends on:** T32

**Files:**
- `lib/lain/cli/up.rb`
- `lib/lain/cli/pane_command.rb`
- specs:
  - `spec/lain/cli/up_spec.rb`
  - `spec/lain/cli/pane_command_spec.rb`

**Reuse:**
- `PaneCommand.call`.
- `Up::Cockpit`'s socket derivation.
- `PaneCorpse`.
- `configure_session`.

**Design.**
- **The cockpit:** nvim on the left; on the right, the chat on top of the input pane (`split-window -v
  -l 6` of the chat pane).
- **`--no-nvim`:** the chat on top of the input pane.
- Pane ids are captured with `-P -F '#{pane_id}'` and stored as session options `@lain_chat_pane` and
  `@lain_input_pane`.
- The chat runs `chat --input socket:<session name>`. The input pane runs `input --socket <path>`, the
  same pid-free path T32 derives, through `PaneCommand` and in the same cwd. The input pane's command
  waits for the socket to appear, bounded by the preflight timeout, so the order in which the panes start
  does not matter.
- `PaneCorpse` targets the chat pane's id. Reattach decides by the stored ids. Focus lands in the input
  pane.

**Shared-file wiring:** none

**Reachable from:** `exe/lain up` → `CLI::Up#create_session`.

**Acceptance criteria**

```gherkin
Scenario: the cockpit has three panes
  When `lain up` creates a session on a machine with nvim
  Then the window holds nvim, chat and input panes
  And the chat and input commands name the same socket

Scenario: no-nvim has two panes
  When `lain up --no-nvim` creates a session
  Then the window holds a chat pane over an input pane

Scenario: a dead chat is seen while the input pane is focused
  Given the chat pane's process exits during start-up
  Then `lain up` raises ChatDied from the chat pane's capture

Scenario: reattach reads the stored panes
  Given a --no-nvim session
  When `lain up --nvim` reattaches
  Then the missing-editor warning prints
```

→ spec files:
- `spec/lain/cli/up_spec.rb` (real tmux, the production `create_session`)

**Escalation triggers:**
- The tmux PATH trap: a pane passes on a binary production never sees. The PATH pins at
  `up_spec.rb:1644-1708` must stay green.
- `up_spec.rb:373-398`'s global options would be touched. Stop.

### T41 — Stop the running ask and keep the session          [wave 5] [risk: medium]

**Depends on:** T18, T25, T32

**Files:**
- `lib/lain/cli/shutdown.rb`
- `lib/lain/frontend/tty.rb`
- new `lib/lain/cli/command/stop.rb`
- `lib/lain/frontend/input_pane.rb`
- `lib/lain/frontend/stdin_pump.rb`
- `lib/lain/frontend/input_rail.rb`
- `lib/lain/cli/conductor.rb`
- specs:
  - `spec/lain/cli/shutdown_spec.rb`
  - `spec/lain/frontend/stdin_pump_spec.rb`
  - `spec/lain/frontend/tty_spec.rb`
  - new `spec/lain/cli/command/stop_spec.rb`
  - `spec/lain/frontend/input_pane_spec.rb`
  - new `spec/lain/seams/stop_ask_spec.rb`

**Reuse:**
- `Shutdown`'s BYTES and HANDLERS.
- `Budget#interrupt`.
- The torn-head repair.
- T18's `stopped` reason.

**Design.**
- `Shutdown` gains a `stop` action (byte `\x08`). It interrupts the task hosting the current ask with the
  `Lain::Stopped` cause T18 defined, returns to `running`, and never closes.
- Countdown key `s` stops the ask and cancels the countdown. It is accepted by the tty countdown in a
  plain chat, and added to the `countdown` rail prompt's keys so the input pane offers it too.
- `/stop` is recognised by the rail producers (the input pane and the plain-chat pump), even while an ask
  runs, and sent as `Signal(stop)`.
- The journal records `run_interrupted reason: stopped` and no `session_closed`. The head is left
  answered.

**Shared-file wiring:** a `require_relative "command/stop"` line in `lib/lain/cli/command.rb`.

**Reachable from:** `Conductor#supervise` routes signals to `Shutdown`; `/stop` from `Frontend::InputPane`
and `StdinPump`; the countdown's key reader in `TTY`.

**Acceptance criteria**

```gherkin
Scenario: /stop from the input pane ends a runaway ask
  Given a chat whose model loops bash calls, driven through --input socket
  When /stop is entered in the input pane
  Then `you>` is published again
  And the session file holds run_interrupted with reason stopped and no session_closed

Scenario: the countdown offers stop, in a plain chat and in the pane
  When the first Ctrl-C opens the countdown during an ask
  Then the countdown offers "[s] stop this ask" in the plain chat's terminal and in the input pane
  And pressing s in either returns to `you>` with run_interrupted reason stopped

Scenario: /stop with nothing running
  When /stop is typed at `you>`
  Then it says no ask is running
```

→ spec files:
- `spec/lain/seams/stop_ask_spec.rb` (a real chat process and input client)
- `spec/lain/cli/shutdown_spec.rb`
- `spec/lain/frontend/tty_spec.rb`

**Escalation triggers:**
- The stop would need `exit!` or `Thread#kill`. Stop.
- `agent_cancellation_spec.rb`'s stop-preempts-raise precedence would change. Stop.
- `/stop` during `/implement-epic` cannot reach the driver because the traps point at `Signals::NULL`
  during a slash command. Report it; do not widen the card.

### T42 — DSL files, Ctrl-C and report commands fail in words at the exe          [wave 5] [risk: low]

**Depends on:** T20

**Files:**
- `lib/lain/dsl_catalog.rb`
- `exe/lain`
- `lib/lain/bench/cli.rb`
- specs:
  - `spec/lain/dsl_catalog_spec.rb`
  - `spec/lain/summarizer/builder_spec.rb`
  - `spec/lain/isolation/services_spec.rb`
  - `spec/lain/cli_spec.rb`
  - `spec/lain/bench/cli_spec.rb`

**Reuse:** the exe's `render` and `exit_status` (the `watch` Interrupt precedent), `Lain::Error`, and
`grade_record`.

**Design.**
- `DslCatalog.load` translates `ScriptError`, `ArgumentError`, `NameError` and `NoMethodError` raised
  from the user's file into a `Lain::Error` naming `path:line` and the message.
- `render` rescues `Interrupt`: it prints "interrupted" and exits 130.
- `arms_report` yields graded runs as they complete, so an interrupt prints the table so far, marked
  PARTIAL.

**Shared-file wiring:** none

**Reachable from:** `exe/lain chat` (services and summarizers), `epic submit` and `bench arms`.

**Acceptance criteria**

```gherkin
Scenario: a broken services.rb refuses in one line
  Given .lain/services.rb with a syntax error on line 3
  When `lain chat --isolation none` starts
  Then it prints one refusal naming services.rb:3 and exits 1, with no backtrace

Scenario: Ctrl-C of a report command exits cleanly
  When Interrupt reaches `lain epic submit`
  Then it prints "interrupted" and exits 130

Scenario: an interrupted arms run shows its partial table
  Given two graded runs completed
  When Interrupt arrives
  Then the table has 2 rows and is marked PARTIAL
```

→ spec files:
- `spec/lain/cli_spec.rb` (`.start` with `debug: true`)
- `spec/lain/dsl_catalog_spec.rb`
- `spec/lain/bench/cli_spec.rb`

**Escalation triggers:**
- `builder_spec.rb:229-232` pins a bare `ArgumentError`. Update it deliberately; never rescue into an
  empty catalog.
- A `SystemExit` inside an example truncates the run. Every Thor start in a spec needs `debug: true`.

### T43 — When no cut can make room, hand off to one state document and answer the ask          [wave 7] [risk: high]

**Depends on:** T35, T6, T2

**Files:**
- new `lib/lain/oracle/handoff.rb`
- `lib/lain/compaction/source.rb`
- `lib/lain/middleware/request_budget.rb`
- `lib/lain/agent.rb`
- `lib/lain/cli/backend.rb`
- `exe/lain`
- `lib/lain/session_record.rb`
- specs:
  - new `spec/lain/oracle/handoff_spec.rb`
  - `spec/lain/session_record_spec.rb`
  - `spec/lain/compaction/source_spec.rb`
  - `spec/lain/middleware/request_budget_spec.rb`
  - `spec/lain/agent_spec.rb`
  - `spec/lain/cli/backend_spec.rb`
  - new `spec/lain/seams/handoff_spec.rb`

**Reuse:**
- `Oracle::Definition` and `Oracle::Summarize`'s shape and structured output.
- T35's `supersedes` and `kind`.
- T6's `oracle_failed`.
- `Accounting#observe_refusal`'s exact count.

**Design.**
- **The oracle.** `Oracle::Handoff` has a template that asks for JSON and a schema: `goal`, `progress`,
  `files_and_decisions`, `open_todos`, `next_step`. Its input is:
  - the held replacements;
  - the uncollapsed span, with each tool result reduced to a one-line stub;
  - a list of the pins.
- **The trigger:** an over-window refusal while `Source` had nothing droppable, or a refusal of a render
  that already held the newest cut. There is no estimate before send.
- **The cut.** `Source` commits a `handoff` cut superseding every held cut. Its range is every turn before
  the current ask's unanswered tool round, except the current ask's user turn and the pins. Tool rounds
  the current ask already **completed** are inside the range, so an ask whose own iterations fill the
  window (a large read, then more work) can still be handed off. This kind alone does not keep
  `keep_last` (the ruling).
- **Keeping the ask.** `Agent#call_model` retries that render once after a handoff commits. A second
  refusal withdraws and refuses as T18 does. A failed handoff oracle writes `oracle_failed` and refuses,
  naming `/rewind`.
- **A bench arm.** `--compact-fallback handoff|none` (default `handoff`) is declared beside the chat's
  compaction flags in `exe/lain`, not on `RunProfile`. It is recorded in the session header's compaction
  section by `SessionRecord.header`, which T2 already threads.
- `RequestBudget`'s words say that a handoff happened.
- The state document is never written to project memory.

**Shared-file wiring:** a `require_relative "oracle/handoff"` line in `lib/lain/oracle.rb`, after
`oracle/summarize`.

**Reachable from:** `CLI::Backend#pipeline_source` builds the chat's `Source` with the handoff oracle;
`Agent#call_model` on the chat.

**Acceptance criteria**

```gherkin
Scenario: a tail that fills the window is handed off and the ask answered
  Given a recorded session whose keep_last tail alone exceeds a 32k window
  When the human asks a new question
  Then one handoff cut commits, one summarizer call is journaled, and the ask gets an answer
  And the render's replacement holds the five state headings

Scenario: an ask that fills the window itself is handed off
  Given a short history and an ask whose completed tool rounds hold two large reads
  When the next request in that ask is refused over the window
  Then a handoff cut covers those completed rounds, and the ask continues from the state document

Scenario: a resume renders the handoff
  When that session resumes
  Then the render is byte-identical to the live render after the handoff

Scenario: with the fallback off, the refusal stands
  Given --compact-fallback none
  Then the ask is refused as before and no handoff cut exists

Scenario: a handoff never writes project memory
  Then the project memory store's version is unchanged by the handoff

Scenario: a failed handoff is recorded and refused in words
  Given the handoff oracle's answer is undecodable
  Then oracle_failed is journaled and the refusal names /rewind
```

→ spec files:
- `spec/lain/seams/handoff_spec.rb` (real Agent, Source, RequestBudget and a recorded provider)
- `spec/lain/compaction/source_spec.rb`
- `spec/lain/oracle/handoff_spec.rb`

**Escalation triggers:**
- The handoff oracle's own input will not fit its window after stubbing. Stop and propose an elision
  depth.
- `HeldCut.holds?`'s `--compact-keep` resume guarantee cannot be stated for the `handoff` kind. Stop.
- The retry would need a size estimate before send. Stop.

### T44 — A docker timeout ends its container          [wave 5] [risk: low]

**Depends on:** T37

**Files:**
- `lib/lain/exec/docker.rb`
- `lib/lain/tools/bash.rb`
- specs:
  - `spec/lain/exec/docker_spec.rb`
  - `spec/lain/tools/bash_spec.rb`

**Reuse:**
- The inner exec's one kill implementation.
- `Prober`'s bounded deadline idiom.
- `Exec::Timeout`.

**Design.**
- `RUN` gains `--init` and a per-call `--name lain-<pid>-<n>`; the object stays frozen.
- After the inner backend raises `Exec::Timeout`, the backend runs `docker kill` and then `docker rm -f`
  for that name, through the same injected exec, within a 5 second deadline.
- If cleanup fails, the timeout message says the container may still be running and names it.
- `bash`'s timeout descriptions say what happens under docker.

**Shared-file wiring:** none

**Reachable from:** `--exec docker` → `CLI::ExecBackend` → `Exec::Docker`, under `Tools::Bash`.

**Acceptance criteria**

```gherkin
Scenario: a TERM-ignoring command leaves no container
  Given docker is available
  When bash runs `sh -c 'trap "" TERM; sleep 600'` under --exec docker with a 1 second timeout
  Then within 10 seconds no container named lain-* from this call exists

Scenario: the argv keeps its prefix
  Then the argv starts `docker run --rm` and includes --init and --name

Scenario: an unreachable daemon's cleanup is bounded
  Given DOCKER_HOST points at a black-holed address
  When a timeout triggers cleanup
  Then the call returns within the cleanup deadline and names the container
```

→ spec files:
- `spec/lain/exec/docker_spec.rb` (`:seam`, which skips without a docker client)

**Escalation triggers:**
- `docker_spec.rb:177-181`'s argv prefix would break. Stop.
- A spec would pull an image. Stop.
- A `--cidfile` would seem necessary. Stop: the temp-file lifecycle is rejected.

### T45 — `consolidate` and `improve` write durably, and their scaffolds are masked          [wave 4] [risk: medium]

**Depends on:** T39, T20

**Files:**
- `lib/lain/consolidation.rb`
- `lib/lain/cli/consolidate.rb`
- `lib/lain/cli/improve.rb`
- `lib/lain/cli/improvements.rb`
- specs:
  - `spec/lain/consolidation_spec.rb`
  - new `spec/lain/cli/consolidate_spec.rb`
  - `spec/lain/cli/improve_spec.rb`
  - `spec/lain/cli/improvements_spec.rb`
  - new `spec/memory_compaction_separation_discipline_spec.rb`

**Reuse:**
- `Memory::ProjectStore` (T39).
- `ToolGuard::Unreleased`, the "nobody here to release" fail-closed precedent.
- `Sensitivity::Regions`.
- `SessionJournals`' torn-last-line rule.

**Design.**
- `lain consolidate` opens a real journal at `state_home/consolidation/<project_hash>/<timestamp>.ndjson`.
  The clerk's `memory_write` lands in the project memory store.
- `lain improve` journals the same way.
- Both scaffolds pass through region masking before any provider sees them, fail closed.
- `lain improvements --project` with no match names the project.
- A torn last line is tolerated; a torn line mid-file refuses (F196).
- **The boundary, pinned structurally.** `spec/memory_compaction_separation_discipline_spec.rb` fails when:
  - any file under `lib/lain/compaction/` names `Memory::ProjectStore` or a memory record;
  - any file under `lib/lain/consolidation*`, `lib/lain/cli/consolidate.rb` or `lib/lain/cli/improve.rb`
    reads `compaction_cut` records or `Compaction::` objects.
  Its sibling discipline specs are the precedent.

**Shared-file wiring:** none

**Reachable from:** `exe/lain consolidate` → `CLI::Consolidate.from_options`; `improve` →
`CLI::Improve.from_options`; `improvements` → `CLI::Improvements`.

**Acceptance criteria**

```gherkin
Scenario: consolidated memory reaches a fresh chat
  Given a session with one completed lineage and a clerk that writes one memory
  When `lain consolidate` runs and a fresh chat starts in that project
  Then the fresh chat's manifest lists the clerk's memory

Scenario: a released key in a child's text reaches no provider
  Given a child transcript echoing a released private key
  When consolidate builds its scaffold
  Then the provider receives the scaffold with the region masked

Scenario: a compaction replacement never reaches the clerk
  Given a source session holding a compaction_cut whose replacement text is "SUMMARY-MARKER"
  When consolidate builds its scaffold
  Then the scaffold does not contain "SUMMARY-MARKER"

Scenario: the separation holds in the tree
  Then memory_compaction_separation_discipline_spec passes

Scenario: a dry run stays keyless
  When `lain consolidate --dry-run` runs with no API key
  Then it prints the scaffold and constructs no provider

Scenario: no-match wording names the project
  When `lain improvements --project nope` runs
  Then it says no improvements are recorded for nope
```

→ spec files:
- new `spec/lain/cli/consolidate_spec.rb` (production `from_options` over a tmp XDG tree)
- `spec/lain/consolidation_spec.rb`
- `spec/lain/cli/improvements_spec.rb`

**Escalation triggers:**
- The clerk's spawn would stop being fresh-root. Stop: that is not negotiable.
- The detector's known residuals would let a key through the scaffold. Stop and name the residual.

### T46 — Show the fleet as a live tree in `lain://status` and in the input pane          [wave 6] [risk: medium]

**Depends on:** T19, T32

**Files:**
- `lib/lain/tools/subagent.rb` (where a spawn starts, and where a child turn is fed)
- `lib/lain/status_feed/fleet.rb`
- `lib/lain/status_feed.rb`
- `lib/lain/frontend/neovim/status_view.rb`
- `lib/lain/session_record/scribe.rb`
- `lib/lain/frontend/input_pane.rb`
- new `lib/lain/telemetry/child_progress.rb`
- specs:
  - `spec/lain/tools/subagent_spec.rb`
  - `spec/lain/status_feed/fleet_spec.rb`
  - `spec/lain/status_feed_spec.rb`
  - `spec/lain/frontend/neovim/status_view_spec.rb`
  - `spec/lain/session_record/scribe_spec.rb`
  - `spec/lain/frontend/input_pane_spec.rb`

**Reuse:**
- `StatusFeed::Fleet` and `SpawnLifecycle`.
- `InboxRow.one_line`'s scrub.
- `StatusFeed` publication.
- `StatusView`'s epic fold.

**Design.**
- **The spawn body is untouched**, so spawn digests and the cross-run join stay as they are.
- The tee carries a `child_progress` record naming the spawn digest:
  - once at start: `role` ("subagent" when roleless), `task_line` (the prompt's first line, clamped to 96
    characters and scrubbed to one terminal line) and `worker` (the lease key, known because T19 leases
    first);
  - then on each child turn: turn count and head.
  `child_turn` stays durable-only.
- `StatusFeed::Fleet` folds a tree:
  - parent edges via `spawned_from` → the owning spawn;
  - each child's state: running, done, failed or stopped;
  - turn count and elapsed time.
- The publication carries `fleet_tree` rows.
- `lain://status` renders the tree in place of the bare-digest list.
- The input pane's header, under the HUD line, shows the tree's top rows and refreshes when the
  publication changes.

**Shared-file wiring:** a `require_relative "telemetry/child_progress"` line in `lib/lain/telemetry.rb`.

**Reachable from:** `LiveViews`' tee → `StatusFeed` publication; `Frontend::Neovim`'s status buffer;
`exe/lain input` → `Frontend::InputPane`.

**Acceptance criteria**

```gherkin
Scenario: a nested fleet renders as a tree
  Given a chat that spawns a dev child, which spawns a test_engineer grandchild
  When lain://status refreshes
  Then it shows dev with its task line and the grandchild indented beneath, each with state and turns

Scenario: a failed child reads failed
  Given a child that hit its ceiling
  Then its row reads failed

Scenario: the input pane updates while waiting
  Given the input pane is idle at `you>`
  When a child's turn count changes
  Then the pane's header shows the new count without a keypress

Scenario: a forged line cannot overwrite the row
  Given a task whose first line holds a carriage return
  Then the row is still one terminal line
```

→ spec files:
- `spec/lain/status_feed/fleet_spec.rb`
- `spec/lain/frontend/neovim/status_view_spec.rb`
- `spec/lain/frontend/input_pane_spec.rb`

**Escalation triggers:**
- `StatusFeed` would need to ask the live Supervisor registry. Stop.
- The spawn digest, the watch address, would change for the same prompt and head. Stop: `task` stays the
  digest and `task_line` is additional.
- `scribe_spec.rb:380`'s dedupe changes. Stop.

### T47 — Plan scope: confine writes and commands to a spike worktree or scratch directory          [wave 5] [risk: high]

**Depends on:** T33, T30

**Files:**
- `lib/lain/mode/scope.rb`
- new `lib/lain/isolation/scratch.rb`
- new `lib/lain/middleware/confine_to_scope.rb`
- `lib/lain/session.rb`
- `lib/lain/cli/wiring.rb`
- `lib/lain/agent/snapshot_slot.rb`
- `lib/lain/cli/switchboard.rb`
- `lib/lain/cli/wiring/board_build.rb`
- `lib/lain/cli/tool_guard.rb`
- `lib/lain/tools/subagent.rb` (children inherit the scope env)
- specs:
  - `spec/lain/mode/scope_spec.rb`
  - `spec/lain/tools/subagent_spec.rb`
  - new `spec/lain/isolation/scratch_spec.rb`
  - new `spec/lain/middleware/confine_to_scope_spec.rb`
  - `spec/lain/session_spec.rb`
  - `spec/lain/agent/snapshot_slot_spec.rb`
  - `spec/lain/cli/switchboard_spec.rb`
  - new `spec/lain/seams/plan_scope_spike_spec.rb`

**Reuse:**
- `Isolation::Worktree#acquire` and `Leases::InPlace`.
- `BoardBuild::Classifiers::Confinement`.
- T30's per-worker-env classifier factory.
- `WorkingBranch.owned`.
- `SnapshotSlot#rebind`.

**Design.**
- **Entering plan.** `/mode plan` leases a spike worktree on a lain-owned `lain/plan/<session>` branch, cut
  at a snapshot commit of the checkout's tracked state, so its uncommitted tracked changes come along.
  The snapshot touches neither the checkout's index nor its stash list: `git add -u` into a temporary
  `GIT_INDEX_FILE` seeded from `HEAD`, then `git write-tree` and `git commit-tree -p HEAD`, or `HEAD`
  itself when the tree is clean. The result is a single-parent commit.
  Outside a git repository it uses an `Isolation::Scratch` temporary directory.
- **The worker env.** The Session's worker env becomes a live slot, rebound on the flip. Relative paths
  and `bash`'s default cwd resolve against the scope root.
- **`ConfineToScope`**, before the Gate, refuses a `write_file`/`edit_file` path or a `bash` `cwd` whose
  real path is outside the scope root.
- **Automatic approval.** Under plan, a `bash` call is approved automatically only when the scope-rooted
  confinement classifier proves its words confined. Otherwise it asks a human, whatever the approval
  level, with words saying plan scope cannot confine it.
- **Everything else follows the scope:**
  - the snapshot slot roots at the scope;
  - children spawned under plan inherit the scope env;
  - the workspace tells the model its scope, its path, and that untracked files were not copied.
- **Leaving plan** releases the lease (the gc retention rules apply) and restores the checkout env. `!`
  means plan scope with `ask`.
- **The honest limit, stated in the docs:** a human-approved command can still write anywhere; plan
  scope is not a sandbox.

**Shared-file wiring:**
- a `require_relative "isolation/scratch"` line in `lib/lain/isolation.rb`;
- a `require_relative "middleware/confine_to_scope"` line in `lib/lain/middleware.rb`.

**Reachable from:** `/mode plan` → `Switchboard`'s `BoundSwitch` → `Mode::Resolution`; `CLI::ToolGuard`
composes `ConfineToScope` on every stack.

**Acceptance criteria**

```gherkin
Scenario: a spike in plan scope leaves the checkout untouched
  Given a git project with an uncommitted edit to lib/a.rb
  When `/mode plan` is typed and the model writes notes.md and runs `ruby -e 'File.write("x", 1)'`
  Then the checkout's git status shows only the original edit
  And notes.md and x exist in the spike worktree, whose lib/a.rb carries the uncommitted edit

Scenario: a write aimed at the checkout refuses
  When the model calls write_file with an absolute path inside the checkout
  Then it refuses naming the scope root

Scenario: an unconfinable command asks a human even under auto
  Given `/mode plan auto`
  When the model calls bash `cd /path/to/checkout && touch y`
  Then the call parks for a human with the plan-scope wording

Scenario: plan scope outside git uses a scratch directory
  Given a project that is not a git repository
  When `/mode plan` is typed
  Then the worker cwd is a scratch directory under the lain tmp root

Scenario: leaving plan restores the checkout
  When `/mode checkout` is typed
  Then bash's default cwd is the project cwd again
```

→ spec files:
- `spec/lain/seams/plan_scope_spike_spec.rb` (real git, Switchboard, ToolGuard and Session)
- `spec/lain/middleware/confine_to_scope_spec.rb`

**Escalation triggers:**
- The root predicate cannot be re-anchored to the lease. Stop.
- The snapshot commit would change the checkout's `.git/index` mtime, its stash list or its reflog.
  Stop. The seam spec compares all three before and after, and scrubs any inherited `GIT_INDEX_FILE`
  first (the pre-commit trap).
- A second `Filter.new` would appear. Stop.
- `lain/plan/*` branches are not covered by worktree gc. Report it; do not widen the card.

### T48 — Restate the architecture, commands and QA scenarios against what landed          [wave 8] [risk: low]

**Depends on:** every card, T1–T47

**Files:**
- `ARCHITECTURE.md`
- `CLAUDE.md` (§ Architecture, in one breath)
- `ROADMAP.md`
- `docs/commands.md`
- `docs/providers/ollama.md`
- `planning/qa/README.md`
- `planning/qa/method.md`
- `planning/qa/scenarios/*.md`, each named below
- spec: `spec/lain/comment_census_spec.rb`

**Reuse:** the QA-scenarios-track-features rule (memory), and `bin/comment-census --check-tickets`.

**Design.**
- **`ARCHITECTURE.md` gains:**
  - the input rail and the pane layout;
  - modes as scope × approval;
  - the project memory vs. compaction table from Intent;
  - superseding cuts and handoff;
  - `RunProfile`;
  - typed stop reasons;
  - settle-before-tools.
- **`CLAUDE.md`'s one-breath section** gets one sentence each for the rail, modes and project memory.
- **`ROADMAP.md`:**
  - item 48's status;
  - the Interface & UX HUD and prompt paragraphs;
  - the remote-surface paragraph on the two `auto`s (`auto` is now a ladder with final denies).
- **`docs/commands.md`:** `/mode`, `/stop` and `/review close`.
- **Scenarios:**
  - `failure-injection.md` §1b: a transport failure after the wire keeps the prompt, and the next ask
    folds it;
  - `memory-and-dogfood.md`: the fresh-session read-back is now expected;
  - `survey.md` §7 check 4;
  - `epic-tier.md` §6: positive evidence;
  - `secret-boundary.md` §2: anchored patterns replace `vault/**`;
  - `subagents-and-backends.md`: the docker timeout leaves no container; a failed child is retired;
  - `cockpit-surfaces.md`: three panes, `/stop`, the fleet tree;
  - `repl-commands.md`: `/mode` usage and tokens;
  - `shell-term-approval.md`: postures → approval levels;
  - `session-and-window.md`: handoff and re-collapse;
  - `bench-arms.md`: the flag band and failed recordings.
- **QA documents:** `planning/qa/README.md`'s known gap on spawn edges is closed, and
  `planning/qa/method.md`'s mode ban is restated for the token `auto`.

**Shared-file wiring:** none

**Reachable from:** documentation only. It records what T1–T47 made reachable.

**Acceptance criteria**

```gherkin
Scenario: no ticket id lands in a comment
  When `bin/comment-census --check-tickets` runs
  Then it reports no ticket-shaped reference in lib/, spec/ or the runtime Lua

Scenario: CLAUDE.md's comment scope is unchanged
  When comment_census_spec reads the scope from CLAUDE.md
  Then it matches what the census opens
```

→ spec file: `spec/lain/comment_census_spec.rb`

**Escalation triggers:**
- A scenario's enumeration cannot be made to match the code, because a card shipped differently than
  specified. Record it in the Execution log as a follow-up rather than writing the plan's version.
- A `ROADMAP.md` edit would change a ruling recorded in an earlier item. Stop.

## Integration checks

After the last wave:

1. **The suite, on a quiet machine.**
   - `pgrep -cf 'mise/installs/ruby/[0-9.]*/bin/parallel_rspec'` and `pgrep -f '[p]re-commit'` both read 0.
   - `bundle exec rake pspec` is green. Compare the **example count** against the count taken before
     wave 1 plus the added specs, not only the failure count.
2. **The tiers and linters.**
   - `bundle exec rake core:build && bundle exec rspec --tag core`, for T37's daemon-arm parity.
   - `bundle exec rubocop` is clean.
   - `bin/comment-census --check-tickets` passes.
   - `bin/spec-census --check` is reported; raise no ceiling in this chunk.
3. **A manual cockpit pass, by the human.**
   - `lain up` shows three panes. Typing in the input pane while an ask runs keeps the HUD and fleet tree
     live.
   - `[y/N]` and `human>` are answered from the pane.
   - Ctrl-C in the pane opens the countdown, and `s` stops the ask.
   - `/stop` returns to `you>`.
   - `lain://status` shows the tree for a spawn that spawns.
4. **A manual plain-chat pass.**
   - `lain chat --no-nvim` in a bare terminal: an approval that arrives while `human>` is open is announced
     and then drawn.
   - A note never tears a prompt.
   - `lain chat < prompts.txt` with `bash` answers each prompt once.
5. **Compaction on `rails-blog`.** Drive the session until its tail fills a 32k window: one handoff, the
   ask answered, and `--resume` renders the same.
6. **Plan scope.** `/mode plan` on a dirty repository, a spike, then `/mode checkout`: the checkout's
   `git status` is unchanged.
7. **Project memory.** `lain consolidate` over a session with a lineage, then a fresh `lain chat` lists the
   memory.
8. **Throughput.** `LAIN_NUM_BATCH=2048 lain bench arms` against the local runner: the ollama log shows no
   `-b 512` reloads.
9. **Docker.** `--exec docker` with a TERM-ignoring `sleep 600` at a 1 s timeout: `docker ps -a` shows no
   leftover `lain-*` container.
10. **`web_fetch`.** Fetch a real documentation page with network access (human-run) and get readable
    text.
11. **The QA round.** Schedule round 19 as a full round over every scenario, since this chunk changes the
    input surface, modes and memory together.
