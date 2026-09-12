# UI/UX chunk: tmux plugin, nvim plugin, slash commands, forks, round-trip

status: done
progress-note: |
  ALL 24 cards landed on main (per-feature commits f69a6c5..1468802), plus the docs
  card (d6f2754) and a Phase-1 doctrine tidy (fddc8e3). Reviews: T13 APPROVE-WITH-FIXES
  (blank-inbox guard), T20 APPROVE, T17 APPROVE, T18 APPROVE (B1 rewound-journal + B2
  dispatch-lock empirically sound, T4 mutex specs intact), T21 SHIP, T22 APPROVE, T23
  REQUEST-CHANGES→BLOCKER-fixed (/meta run path-traversal charset guard), T24 doc-pass.
  Tidy folded the Env fail-loud placeholders into required kwargs (only YoloApprovals is
  a real Null), added build_command_env, StaticModel, Telemetry::{Policy,Model}Switch,
  Bench Boundary, Repl::ApprovalSurfaces. Two review fixups autosquashed into T13/T17.
  Final verify: pre-commit --all-files green (rspec 4085/0/2, rubocop 735 clean,
  cargo test/clippy/deny, shellcheck). Manual passes still owed to Joel — see below.
  Owed manual pass (Joel): `lain up --nvim -- --model <cheap>` cockpit; `/btw` popup
  under plain tmux AND window-degrade under iTerm2 `tmux -CC`; edit-and-`:LainResend`
  round-trip against a real provider; `/meta` generate-review-run; ephemeral reap on a
  clean `/btw` exit checked via `lain sessions --all`. Known infra flake: up_spec:174
  (real-tmux timing, pre-existing, passes isolated/on rerun).
commit-mode: orchestrator-commits
language: ruby
panel: Linus Torvalds · Jeremy Evans · Sandi Metz · Richard Schneeman · Aaron Patterson

## Intent

Lain's interface is deliberately bare (the bench was the deliverable); this chunk makes the
harness pleasant to *drive*. It ships: an in-repo tmux plugin and Neovim plugin; a command
registry with `/help /status /sessions /inbox /approve /yolo /model /rewind /fork /btw /quit
/goal /ruby /meta`; session forking (persistent `/fork`, ephemeral `/btw` with
journal-and-reap); the provider round-trip of an edited `lain://request` (ROADMAP :116's one
committed unbuilt M4-2 item); wiring the already-landed auto-approver; a read-only live
viewer per subagent in tmux windows; `lain up` flag passthrough and nvim orchestration; and
an engineer-facing ARCHITECTURE.md with a README cleanup (xmonad references removed from
living docs). Satisfies ROADMAP § Interface & UX items: lualine/list-buffer surfaces stay
`[exp]`, but the window-topology, inbox, approvals, and M4-2 tails move from `[exp]`/planned
to built.

## Grounding

Verified 2026-07-23 against working tree (HEAD df149d8) by three Explore passes:

- `exe/lain` (785 lines, Thor): Repl/Wiring/HumanReplies/LiveViews all live in the exe.
  Command dispatch at `you>` is `Middleware::SkillDispatch` only — any `/word` parses as a
  skill (`lib/lain/skill/invocation.rb:68`); `/inbox` exists solely as a literal check at the
  `human>` reply prompt (`exe/lain:737`); `exit`/`quit` are bare words (`exe/lain:678`).
- The agent loop **cannot accept an injected Request**: `Agent#call_model`
  (`lib/lain/agent.rb:257-264`) always `@context.render(timeline:…)`;
  `Telemetry::RequestResent` is journaled + diffed but never dispatched
  (`lib/lain/telemetry.rb:251-263`, `lib/lain/frontend/neovim/request_buffer.rb:19-23`).
- `Approval::AutoSurface` is **implemented, spec'd, landed (988283e), never wired** — the
  Repl's `approval_loop` (`exe/lain:673-676`) spawns only TTY + dunst watchers. Known
  follow-up: `@adjudicated` grows unbounded.
- Subagents are in-process `Async` fibers, headless, no PTY, no per-actor external stream;
  `Supervisor` (`lib/lain/supervisor.rb`) is the fleet registry (`Registration`: role, state,
  head_digest, live timeline). All spawn/message lineage lands as `Telemetry::Message`
  records in the parent's NDJSON journal.
- Sessions: `$XDG_STATE_HOME/lain/sessions/<project-hash>/<ts>-<pid>.ndjson` (+ lazy `.wal`);
  the filename is the identity; resume chains via header `resumed_from: {file, head}`
  (`lib/lain/cli/resume.rb`); `Timeline#fork` is identity (forking = two heads, shared
  Store); there is **no** in-process "fork a live head into a new journaled session" seam.
- `lain up` (`lib/lain/cli/up.rb`) is one session/one `chat` window + jq HUD over
  `.lain/state.json` (`{"cache_deadline","fleet","inbox_count"}`, atomic rename); the
  `chat_command:` kwarg exists but the exe never passes flags through.
- `runtime.lua` is gem-shipped and injected at attach (`rpc_thread.rb:257-262`), protocol
  "2"; syntax today is four regex matches on one `lain` filetype; the lua BUFFERS constant
  set omits `lain://workspace` though Ruby renders that view — verify/fix in T5.
- `lain.gemspec` ships any git-tracked top-level dir (only `bin/`, `spec/`, dotfiles
  excluded), so `plugin/` ships in the gem for free.
- `Skill::RoleSpawn` (`lib/lain/skill/role_spawn.rb`) is the caller-picked-role spawn seam
  (`(role, context_mode, prompt) → result`), already used by AutoSurface.
- xmonad references are markdown-only: README.md:87,90; TODO.md:7; ROADMAP.md:566-599;
  planning/interface-integration.md (historical survey — leave that one as record).
- README.md Status/Topology sections describe an M0/M1-era repo ("no exe/lain", "Neovim
  frontend not built") — all false now.
- iTerm2 `tmux -CC` control mode does not render `display-popup`; popups need a degrade
  path (interface-integration.md:141-161 decided tmux-native placement for `-CC` compat).

Docs-vs-code disagreements found: README staleness (code wins, T24 fixes); RequestResent doc
comment says "never dispatched" (true today, T18 changes it and must update the comment);
runtime.lua workspace constant gap (T5 verifies which side is right).

## Orchestrator contract (plan-specific only)

- Shared files (orchestrator-owned, wiring diffs only):
  `lib/lain.rb` (manifest), `lain.gemspec`, `.rubocop.yml`, `spec/spec_helper.rb`,
  `spec/support/tags.rb`, and — **after their extraction/creation cards land** —
  `exe/lain` (thin shell; post-T1 cards hand flag/wiring one-liners),
  `lib/lain/cli/repl.rb` and `lib/lain/cli/wiring.rb` (orchestrator-owned **from wave 3
  on** — the sanctioned structural edits are T1's extraction and wave 2's T9 dispatch
  changes; wave 3+ cards, including T12, hand one-liners only),
  `lib/lain/cli/command.rb` (the command index; each command card hands one require +
  one registry line).
- Deviations from the default process: T8 and T24 are docs-only cards with no spec files —
  their verification is the panel review plus the Integration checks doc pass.
- New spec tags follow the existing opt-in posture: tmux-driving specs use the
  `up_spec.rb` inline `skip("tmux not found")` guard, not a new env tag; nvim-driving specs
  use the existing `:nvim` / `LAIN_NVIM=1` gate.
- Output discipline is absolute for every new lib file: commands and viewers **return
  rendered text / push onto Channels**; only the frontend prints.
  `spec/output_discipline_spec.rb` will enforce this mechanically — do not add exemptions.
- Protocol: T5 bumps `PROTOCOL`/`RUNTIME_PROTOCOL` "2"→"3" once; no other card touches the
  handshake.

## Open decisions

None gating. Recorded defaults execute-plan may revisit only with the human:
- Single `lain` filetype with `b:lain_view` (not per-view filetypes) — T5/T10 build on this.
- `/goal` v1 termination = explicit agent done-signal, iteration cap, or `/goal off` —
  no LLM judge in this chunk.
- **Deferred out of this chunk (panel ruling):** `/fork <subagent>` — a child actor's turn
  chain never hits disk (only `:spawn`/`:message` lineage lands in the parent journal), so
  a new process cannot rebuild a child head. A later card must first investigate what
  `Supervisor::Restart` actually replays from and, if needed, put child chains on disk.
  T16 is orchestrator-head-only by design, not by accident.

## Progress (execute-plan, 2026-07-23)

- [x] T1 landed b3f6cd9 (panel: APPROVE-WITH-FIXES mechanical, applied)
- [x] T2 landed ff65d50 (panel: APPROVE; note — popup with no attached client raises
      TmuxUnavailable; in-spec, callers T16/T17/T20 always run attached)
- [x] T3 landed d4725bc (panel: APPROVE after fix round — Salvager wal fallback,
      Chronicle btw:/RelocatableSpool, Collision guards; chronicle.rb scope-expanded to
      T3. CARRIED TO T15: the loader's linear fold cannot represent an on-disk rewind —
      a parent journaling a rewound divergence below a fork point breaks children
      (reviewer probe_rewind_membership); T15's fold work is the fix. CARRIED to the
      promotion-trigger card (T17): run promote! strictly between round trips or
      synchronize RelocatableSpool#relocate with the ResponseWal monitor.)
- [x] T4 landed 545c0a2 (panel: APPROVE after fix round — mutex slot, deliver
      consume-on-success, splice pinned; T18 owes at-least-once-send doc line)
- [x] T5 landed 5a3cd19 (panel: APPROVE-WITH-FIXES mechanical, applied)
- [x] T6 landed 89c8469 (panel: APPROVE after fix round — #{q:} injection fix)
- [x] T7 lib landed 0250afc (panel: APPROVE after fix round); exe `watch` wiring deferred
      until the ChatLaunch extraction frees exe ClassLength headroom
- [x] T8 landed 14a1f12 (panel: APPROVE-WITH-FIXES, applied — forbid(unsafe_code) is
      lain-core's; ext/lain has 8 FFI unsafe sites)
- [ ] T9 in progress (restarted after stale-fork escalation)
- [ ] T10 in progress (relocated to worktrees/t10-nvim after a resume landed it in the
      main checkout; no tracked files touched)
- [ ] T11 impl done, review in progress
- [x] T11 lib landed 818890e (panel: APPROVE-WITH-FIXES — both substantive conditions
      attach to the exe wiring: land it with a Thor-.start-level argv spec, and guard
      `lain up <typo>` loudly [require `--` in ARGV before accepting chat_args])
- Unplanned orchestrator addition: ChatLaunch extraction (exe chat lifecycle → lib), in
  progress — exe was at ClassLength capacity with five cards still owing exe lines
- Unplanned card (Joel, mid-chunk): per-turn folds in lain:// views via runtime.lua
  foldexpr/foldtext (timeline per turn, inbox per question, journal per lineage-group);
  newest-open default, vim.g.lain_fold*; no protocol bump. Panel REQUEST-CHANGES round:
  card text AMENDED — defaults apply once at first display (BufWinEnter), never
  re-applied per render (the editor preserves per-fold state naturally; per-render
  re-application stomped the user's opened turns, defeating the feature). Fix round in
  progress.
- Wave-1/2 exe wiring landed 79face2: `lain watch` command; `up [-- CHAT_FLAGS]` with
  loud no-`--` guard and Thor-.start-level argv specs (T11 panel's two conditions met).

## Waves

Wave 1: T1, T2, T3, T4, T5, T6, T7, T8
Wave 2: T9 (←T1), T10 (←T5), T11 (←T1)
Wave 3: T12 (←T1,T9), T13 (←T9), T14 (←T9), T15 (←T3,T9), T16 (←T2,T3,T9),
        T17 (←T2,T3,T6,T9), T18 (←T4,T9), T19 (←T10,T11), T20 (←T2,T7)
Wave 4: T21 (←T9), T22 (←T9), T23 (←T2,T9), T24 (←T8,T18,T19)
Critical path: T1 → T9 → T18 → T24

## Tasks

### T1 — Extract Repl and Wiring from exe/lain into lib          [wave 1] [risk: medium]

**Depends on:** none
**Files:** create `lib/lain/cli/repl.rb`, `lib/lain/cli/wiring.rb`,
`lib/lain/cli/live_views.rb`, `lib/lain/cli/human_replies.rb`; modify `exe/lain` (becomes a
thin Thor shell: option declarations + construction calls only)
**Reuse:** the existing classes verbatim — `LainCLI::Repl` (exe/lain:517-681), `Wiring`
(:312-475), `LiveViews` (:267-289), `HumanReplies` (:688-776); `lib/lain/cli/up.rb` as the
model for a CLI collaborator with injected `shell_out_factory`.
**Shared-file wiring:** require lines for the four new files in `lib/lain/cli.rb` index;
none in `lib/lain.rb` (cli.rb is already the unit).

**Acceptance criteria:**

```gherkin
Scenario: behavior is move-only
  Given the full suite passing before the move
  When Repl, Wiring, LiveViews, and HumanReplies live under lib/lain/cli/
  Then the suite passes unchanged and `lain chat --help` output is byte-identical

Scenario: the extracted Repl is constructible without the exe
  Given a Provider::Mock, a Channel, and a Frontend::TTY test double
  When Lain::CLI::Repl is constructed through Lain::CLI::Wiring
  Then one converse round-trip settles and the journal records it
```
→ spec file: `spec/lain/cli/repl_spec.rb`, `spec/lain/cli/wiring_spec.rb`

**Escalation triggers:**
- `spec/output_discipline_spec.rb` walks `lib/` — the moved classes already route I/O
  through `@tty`/`@conductor` (verified: no `$stdout`/Reline in Repl/HumanReplies; the
  exe's one `$stdout.flush` at :189 belongs to `up` and stays). If the discipline spec
  nevertheless flags a moved file, that is a real leak the exe was hiding — STOP; do not
  add an exemption path.
- `spec/lain/cli_spec.rb` will need mechanical constant-rename edits
  (`LainCLI::Wiring` → `Lain::CLI::Wiring`) — those are expected. Any diff BEYOND renames
  (changed output, changed wiring order) means the move leaked policy — stop and report
  rather than patching the spec.

### T2 — TmuxSurface: one object that opens windows, popups, sessions   [wave 1] [risk: low]

**Depends on:** none
**Files:** create `lib/lain/cli/tmux_surface.rb`
**Reuse:** `Lain::CLI::Up`'s `Mixlib::ShellOut` argv discipline and `TmuxUnavailable` error
(`up.rb:22-36`); `up_spec.rb`'s scratch `-L` server + `FakeShellOut` patterns.
**Shared-file wiring:** require line in `lib/lain/cli.rb`.

**Acceptance criteria:**

```gherkin
Scenario: popup degrades under control mode
  Given a TmuxSurface whose client reports control mode (tmux -CC) or an old tmux
  When popup(command:) is requested
  Then it opens a new-window instead and the returned Placement names the degrade reason

Scenario: no tmux, loud degrade
  Given ENV without TMUX and no tmux binary
  When any surface verb is requested
  Then TmuxUnavailable is raised with the remedy in the message, and nothing is executed
```
→ spec file: `spec/lain/cli/tmux_surface_spec.rb`

**Escalation triggers:**
- If control-mode detection proves impossible from inside the pane (no reliable
  `client_control_mode` format on the installed tmux), stop and confirm the fallback
  (always-window under `-CC` ambiguity) rather than guessing per-platform.

### T3 — Fork selector, fork-from-live, and ephemeral session lifecycle   [wave 1] [risk: high]

**Depends on:** none
**Files:** create `lib/lain/cli/fork_point.rb`; modify `lib/lain/cli/resume.rb`,
`lib/lain/cli/resume/salvager.rb` (fork mode must never reach it),
`lib/lain/bench/session/resume_chain.rb` and `lib/lain/bench/session/loader.rb`
(ancestor-head chains: `resumed_from.head` may be any digest ON the prior file's chain.
**Membership is defined as "a verified turn RECORDED IN the prior file", at any fold
position — NOT "ancestor of the file's final rebuilt head"**: a parent that later
/rewinds below a fork point must not render children forked above it unloadable (T15
interaction). `Timeline#checkout` verifies nothing by itself — the verification is the
fold-membership check. The prose comment at `resume_chain.rb:19-22`, which states head
EQUALITY as the integrity property, is rewritten in the same commit), `lib/lain/cli/sessions.rb` (hide ephemerals unless
`--all`), `lib/lain/paths.rb` (ephemeral filename convention)
**Reuse:** `Resume#call` chain machinery and `resumed_from: {file, head}`
(`resume.rb:24-32,158-168`); `Timeline#checkout` (`timeline.rb:78`); the filename-is-the-
identity design (`session_record.rb` — the header is write-once; ephemerality therefore
lives in the FILENAME: `<ts>-<pid>.btw.ndjson`, promotion = `File.rename` of journal+WAL,
which keeps the owning appender's fd valid).
**Shared-file wiring:** `exe/lain` one-liners: `--fork SELECTOR` and `--btw` flags on
`chat` (post-T1 thin exe).

**Acceptance criteria:**

```gherkin
Scenario: fork from an arbitrary head of a CLOSED session
  Given a closed session whose journal contains head H and ancestor A
  When Resume resolves selector "<file>@<A-prefix>" via ForkPoint
  Then the new run's Timeline head is A (chain verified via checkout, not head equality),
    the new journal chains resumed_from {file, A}, and the parent journal is untouched

Scenario: fork from a LIVE session never writes to the parent journal
  Given an OPEN session file whose owner is still appending
  When a fork resolves "<file>@<H>" in fork mode
  Then the parent file is opened read-only, NO salvage or session_closed record is
    appended to it (Salvager is never constructed), and the parent's subsequent appends
    keep the parent loadable

Scenario: ephemeral session reaps on clean exit
  Given a chat journaling to <ts>-<pid>.btw.ndjson
  When it exits cleanly without promotion
  Then its .ndjson and .wal are deleted; after a crash instead, both survive for salvage

Scenario: promotion is a rename
  Given an ephemeral session
  When it is promoted
  Then journal and WAL are renamed to strip the .btw mark (same directory; WAL FIRST,
    then journal — the spec pins the order and the crash window: a crash between the two
    must leave a pair salvage still finds, never an .ndjson whose WAL basename no longer
    matches Paths.wal_for), the header is untouched, and `lain sessions` lists it
```
→ spec file: `spec/lain/cli/fork_point_spec.rb`, additions to `spec/lain/cli/resume_spec.rb`,
`spec/lain/cli/sessions_spec.rb`, `spec/lain/bench/session/resume_chain_spec.rb`

**Escalation triggers:**
- `ResumeChain#prior_timeline` (`resume_chain.rb:99-105`) today raises `Corrupt` unless
  `resumed_from.head` EQUALS the prior file's rebuilt head — this card deliberately
  loosens that to chain-membership (rebuild, then `checkout(A)`). If any existing spec
  treats head-equality itself as the integrity property (not membership), stop and
  reconcile with the orchestrator — that is the chunk's Merkle-integrity line.
- `Resume#call` refuses a mid-tool head — if selector-resolution reaches one, surface the
  refusal verbatim; do not auto-pick a neighboring head.
- If any code path in fork mode can still construct a `Salvager` against the parent file,
  stop — an appended close anchor corrupts the live parent's chain for every future
  reader (this is the panel's Evans BLOCKER; it must be impossible by construction, e.g.
  fork mode never receives a writable handle).
- Known accepted edge (record it in the card result, do not solve here): a session that
  recorded `resumed_from.file = <name>.btw.ndjson` before that parent was promoted breaks
  on the rename (GuardedResolver raises on the missing basename). Forking FROM an
  ephemeral is expected to be rare; if it turns out to matter, the fix is a
  promotion-aware resolver fallback, its own card.

### T4 — Request-override seam in the agent loop          [wave 1] [risk: high]

**Depends on:** none
**Files:** create `lib/lain/agent/request_override.rb`; modify `lib/lain/agent.rb`
(`call_model` consults the override), `lib/lain/agent/model_caller.rb` (none if override
resolves before the middleware thread — decide inside the card, but only one of the two
files owns the decision)
**Reuse:** `Agent::Budget` / `Agent::ToolRunner` as the pattern for a small extracted
collaborator; `Provider::Mock` for specs; Null Object (`RequestOverride::None`) so
`call_model` has no nil check.
**Shared-file wiring:** none — `lib/lain/agent.rb` is itself the agent unit's index (its
`require_relative` block); T4 owns that file and adds the line there. `lib/lain.rb` does
not change.

**Acceptance criteria:**

```gherkin
Scenario: one-shot override
  Given an Agent with a queued RequestOverride carrying edited Request R
  When the next loop iteration dispatches
  Then the provider receives R byte-identically, the following iteration renders from the
    Timeline again, and the override cannot apply twice

Scenario: commit semantics unchanged
  Given the same run
  Then the response to R commits like any turn (turn digest over canonical response) and
    T4 emits NO new telemetry — how an overridden dispatch is journaled is T18's scope
```
→ spec file: `spec/lain/agent/request_override_spec.rb`

**Escalation triggers:**
- `Context#render` purity is a stated invariant ("purity and cache-hit are the same
  constraint"). The override must bypass render, never mutate its inputs. If the
  implementation is tempted to write anything into Timeline/Workspace to carry the edit,
  STOP — that is the design this seam exists to avoid.
- If `spec/lain/agent_spec.rb` pins "provider receives exactly context.render output",
  reconcile with the orchestrator before weakening that spec.

### T5 — runtime.lua contract v3: User events, richer syntax, workspace fix   [wave 1] [risk: medium]

**Depends on:** none
**Files:** modify `lib/lain/frontend/neovim/runtime.lua`, `lib/lain/frontend/neovim.rb`
(PROTOCOL "3")
**Reuse:** existing `lain_syntax` augroup shape (runtime.lua:139-156); `define` idempotent
command helper (:249-252).
**Shared-file wiring:** none.

**Acceptance criteria:**

```gherkin
Scenario: user autocmds get a stable surface
  Given a listening nvim with a user autocmd on User LainAttach and User LainRender
  When lain attaches and renders a view
  Then both autocmds fire with the buffer name in the payload, and b:lain_view is set on
    every lain:// buffer

Scenario: richer highlighting
  Given the timeline/journal/inbox views
  Then tool names, digests, roles, event kinds, ages, and sender attribution each carry a
    documented lain* highlight group, all `highlight default link`ed

Scenario: workspace view has a lua-side home
  Given the Ruby side renders lain://workspace
  Then the lua BUFFERS set names it and set_view on it does not create an orphan buffer
```
→ spec file: `spec/lain/frontend/neovim_runtime_spec.rb` (`:nvim`, headless pattern from
`neovim_spec.rb:9-59`)

**Escalation triggers:**
- If the workspace constant gap turns out to be intentional (workspace rendered through a
  different path), record why in the card result and do not add the constant blind.
- Protocol bump: if any spec pins PROTOCOL "2", the bump belongs in this card alone —
  finding a second place that hardcodes "2" outside neovim.rb/runtime.lua means the
  handshake has drifted; stop and report.

### T6 — In-repo tmux plugin          [wave 1] [risk: medium]

**Depends on:** none
**Files:** create `plugin/tmux/lain.tmux`, `plugin/tmux/scripts/lain-status`,
`plugin/tmux/README.md`
**Reuse:** `Up::JQ_FILTER` semantics and the `.lain/state.json` 3-key schema
(`status_feed.rb:159-161`); `up_spec.rb` scratch-server + `eval_status_job` assertion
pattern (:37-41).
**Shared-file wiring:** `lain.gemspec` needs no change (git-tracked top-level dirs ship);
one README pointer line handed to T24.

**Acceptance criteria:**

```gherkin
Scenario: tpm-style install surface
  Given `run-shell .../lain.tmux` in a scratch server's conf
  Then #{lain_status} interpolates in status-right via lain-status (jq if present, cat
    fallback), and prefix keybindings for btw-popup and fork-window are bound, each
    overridable via @lain_* options (the spec pins that the bindings EXIST and invoke the
    right command lines — the --btw/--fork flags land concurrently in T3, so no
    integration assertion against them here)

Scenario: no state file
  Given no .lain/state.json in the pane's cwd
  Then lain-status prints "lain: no state yet" and the binding degrades to a message,
    never an error
```
→ spec file: `spec/plugin/tmux_plugin_spec.rb` (inline tmux-absent skip guard)

**Escalation triggers:**
- The plugin must read the SAME state.json schema `Up::JQ_FILTER` reads; if the card finds
  itself wanting a fourth key in state.json, that is StatusFeed scope (a different card's
  file) — stop and hand the orchestrator the request.

### T7 — lain watch: read-only live view of one actor          [wave 1] [risk: medium]

**Depends on:** none
**Files:** create `lib/lain/cli/watch.rb`, `lib/lain/cli/watch/lineage_filter.rb`
**Reuse:** journal NDJSON record shapes (`lib/lain/session_record.rb`); lineage fields
`spawned_from`/`causal_parents` (`lib/lain/tools/subagent/lineage.rb:43-53`);
`Frontend::Neovim::JournalView`'s line rendering as the display duck; `Sink::IOAdapter`
for output.
**Shared-file wiring:** `exe/lain` one-liner: `watch SELECTOR` Thor command (post-T1).

**Acceptance criteria:**

```gherkin
Scenario: follow one actor's stream
  Given a live session journal containing spawn S and interleaved events of two actors
  When watch runs with S's digest prefix
  Then it tails the file (survives rename/rotation is NOT required), renders only records
    whose lineage chains to S, and exits 0 on session_closed

Scenario: read-only by construction
  Then watch opens the journal read-only and holds no Store, no provider, no Channel push
```
→ spec file: `spec/lain/cli/watch_spec.rb`

**Escalation triggers:**
- Turn records carry digests, not full lineage chains; if chaining a record to S requires
  Store reconstruction beyond what the NDJSON itself carries, stop and confirm the
  fallback (filter on the Message records' explicit fields only) before building a loader.

### T8 — ARCHITECTURE.md          [wave 1] [risk: low]

**Depends on:** none
**Files:** create `ARCHITECTURE.md`
**Reuse:** README "Architecture, in one breath" (:63-76) as the seed; `docs/concurrency.md`,
`docs/agent-state-machine.md`; the CLAUDE.md architecture paragraph; grounding facts above
(collaborator graph, session disk layout, frontend channels, lain-core boundary).
**Shared-file wiring:** none (README pointer lands in T24).

**Acceptance criteria:**

```gherkin
Scenario: an engineer can locate every moving part
  Given only ARCHITECTURE.md
  Then it maps: Canonical/Turn/Store/Timeline; Context render purity; Effect/Handler/Gate
    and Middleware; Provider boundary; Repl collaborator graph (post-T1 lib paths);
    Channel/JournalTee/StatusFeed fan-out; Subagent/Supervisor/isolation; session NDJSON +
    WAL disk layout; the ext/lain vs crates/lain-core placement rule — each section naming
    its primary source files

Scenario: no duplicated narrative
  Then README keeps the elevator pitch and links here; sections here link to docs/ rather
    than restating them
```
→ spec file: none (docs card; panel review covers it)

**Escalation triggers:**
- Where the grounding notes disagree with a doc being summarized (e.g. README staleness),
  code wins; if a THIRD source (approved plan) disagrees with code, stop and flag rather
  than canonizing either.

### T9 — Command registry ahead of SkillDispatch, /help /quit          [wave 2] [risk: medium]

**Depends on:** T1
**Files:** create `lib/lain/cli/command.rb` (index), `lib/lain/cli/command/registry.rb`,
`lib/lain/cli/command/env.rb`, `lib/lain/cli/command/help.rb`,
`lib/lain/cli/command/quit.rb`; modify `lib/lain/cli/repl.rb` (dispatch consults registry
before `@middleware`), `lib/lain/cli/repl_middleware.rb`, `lib/lain/cli/wiring.rb`
(assembles the Env once)
**Reuse:** `Middleware::SkillDispatch` + `Skill::Invocation` grammar
(`skill_dispatch.rb:45-67`) — commands parse with the same `/word args` shape;
`Skill::Catalog` for /help's skill listing; `Repl#farewell?` (bare exit/quit stays).
**Shared-file wiring:** subsequent command cards hand one require + one
`Registry.register` line each; this card owns the registry's shape.

**Acceptance criteria:**

```gherkin
Scenario: commands shadow skills only when registered
  Given a registry with /help and a skill catalog containing "help" is absent
  When "/help" is typed at you>
  Then the command runs, listing commands with one-line usage AND skills from the catalog;
    an unregistered "/word" still reaches SkillDispatch unchanged

Scenario: the command interface is one message
  Given any registered command
  Then it implements call(args, env) where env is a frozen Command::Env value assembled
    ONCE by Wiring (readers: status feed, sessions listing, approvals queue, supervisor,
    replies drain, fork_point, tmux_surface, agent handle — nil-free via Null collaborators),
    and it RETURNS rendered text or a Repl action; later command cards add Env readers
    only via one-line wiring diffs, never by reaching into Repl internals

Scenario: commands return text, never print
  Given any registered command
  Then its result renders through the TTY frontend; output_discipline_spec stays green

Scenario: /quit
  When "/quit" is typed
  Then the Repl winds down through the same path as bare "quit"
```
→ spec file: `spec/lain/cli/command/registry_spec.rb`, `spec/lain/cli/command/help_spec.rb`

**Escalation triggers:**
- If a real skill named like a planned command exists in a catalog (e.g. a user skill
  "fork"), precedence is command-first by design — but finding a SHIPPED lain skill with a
  colliding name means the namespace needs the human; stop.

### T10 — In-repo Neovim plugin (thin, public API)          [wave 2] [risk: medium]

**Depends on:** T5
**Files:** create `plugin/nvim/lua/lain/init.lua`, `plugin/nvim/lua/lain/config.lua`,
`plugin/nvim/plugin/lain.lua`, `plugin/nvim/doc/lain.txt`, `plugin/nvim/README.md`
**Reuse:** the dotfiles socket autocmd as the reference implementation
(`~/.config/nvim/lua/config/autocmds.lua:88-114` — deterministic
`$XDG_RUNTIME_DIR/lain/nvim-<sha256(cwd)[:12]>.sock`, `.lain/nvim.sock` override,
stale-socket reclaim); T5's User events and documented highlight groups as the contract.
**Shared-file wiring:** none (plugin dir ships via gemspec glob).

**Acceptance criteria:**

```gherkin
Scenario: setup() owns the conventions
  Given require("lain").setup({}) in a headless nvim
  Then serverstart on the deterministic socket happens on VimEnter (project override
    honored, stale socket reclaimed, live instance respected), and every default is
    overridable via setup opts / vim.g.lain_*

Scenario: public API only, protocol stays injected
  Then the plugin defines no lain:// buffer logic and no RPC handling; it exposes
    lain.socket_path(), lain.status() (reads .lain/state.json), :LainStart (window layout
    over the injected buffers once attached), and documents the User Lain* events and
    lain* highlight groups from the v3 contract

Scenario: works without the plugin
  Given a bare nvim --listen with no plugin
  Then lain chat --nvim attaches exactly as today (zero-install unchanged)
```
→ spec file: `spec/plugin/nvim_plugin_spec.rb` (`:nvim`, drives headless nvim with the
plugin on rtp)

**Escalation triggers:**
- The dotfiles reclaim logic is the ONLY tested implementation of socket reclaim; port it
  faithfully. If porting reveals a race the dotfiles version papers over (two instances
  starting simultaneously), stop and record it rather than inventing locking.

### T11 — lain up passes chat flags through          [wave 2] [risk: low]

**Depends on:** T1
**Files:** modify `lib/lain/cli/up.rb`
**Reuse:** the existing-but-unused `chat_command:` seam (`up.rb:84,155-157`);
`Shellwords.escape` discipline (:222).
**Shared-file wiring:** `exe/lain` up subcommand: Thor trailing-args capture after `--`,
one-line hand-off to `Up.new(chat_args:)`.

**Acceptance criteria:**

```gherkin
Scenario: flags reach the chat window
  Given `lain up -- --model claude-fable-5 --no-journal`
  Then the new-session window command is `export PATH=...; exec <prog> chat --model
    claude-fable-5 --no-journal` with every arg shell-escaped

Scenario: hostile args stay inert
  Given a chat arg containing `; rm -rf` or `$(...)`
  Then it arrives at chat as one literal argument
```
→ spec file: additions to `spec/lain/cli/up_spec.rb`

**Escalation triggers:**
- `chat` validates its own flags; Up must NOT re-validate (no flag list duplication). If
  the card finds itself importing chat's option table, the seam is wrong — stop.

### T12 — Wire the auto-approver: --auto-approve          [wave 3] [risk: low]

**Depends on:** T1, T9
**Files:** create `lib/lain/approval/auto_surface/pruning.rb` (note the require policy:
this makes `auto_surface.rb` the subtree's index — the card adds that internal require
there, not in a leaf); or, if the fix fits cleanly inside `auto_surface.rb`, modify that
one file and create no subtree
**Reuse:** `Approval::AutoSurface` as-is (`lib/lain/approval/auto_surface.rb`), its
`role_spawn` seam already assembled by the exe for skills; the two existing watchers'
`#watch(@approvals)` idiom (`approval_loop`).
**Shared-file wiring:** `exe/lain` one-liner: `--auto-approve` flag on chat;
`lib/lain/cli/wiring.rb` one-liner constructing the surface when enabled;
`lib/lain/cli/repl.rb` one-liner adding the third watcher — all three applied by the
orchestrator (repl.rb/wiring.rb are orchestrator-owned in wave 3).

**Acceptance criteria:**

```gherkin
Scenario: opt-in third surface
  Given chat without --auto-approve
  Then no AutoSurface is constructed (unchanged wiring)
  Given chat with --auto-approve
  Then AutoSurface watches the same queue as TTY and dunst, decisions are signed
    "auto_approver", and the human surfaces still see and can race every pending

Scenario: the seen-set no longer grows unbounded
  Given a long watch over pendings that settle
  Then adjudicated entries for settled pendings are released (observable via the pruning
    seam's own spec, not object-count heuristics)
```
→ spec file: additions to `spec/lain/approval/auto_surface_spec.rb`,
`spec/lain/cli/wiring_spec.rb`

**Escalation triggers:**
- AutoSurface's contract is observe-don't-dequeue (`queue.rb:11-16`); if wiring it third
  exposes a race the existing queue-concurrency spec doesn't cover, add the failing spec
  and stop for review — the fail-closed semantics are the subsystem's premise.

### T13 — /status, /sessions, /inbox          [wave 3] [risk: low]

**Depends on:** T9
**Files:** create `lib/lain/cli/command/status.rb`, `command/sessions.rb`,
`command/inbox.rb`
**Reuse:** `StatusFeed` state derivation (inject the live instance via Command::Env, not
the JSON file). NOTE the wiring reality: today the exe constructs StatusFeed inline into
the tee and drops the reference, and no LiveViews exists under `--no-journal` without
`--nvim` — so this card's wiring makes Wiring ALWAYS construct and retain one StatusFeed
sink (the state.json write stays gated on journaling; the in-memory feed is always live).
`CLI::Sessions#listing`; `HumanReplies` drain path (`/inbox` at `human>` stays; this
command reuses its drain object at `you>`).
**Shared-file wiring:** three require+register lines in `lib/lain/cli/command.rb`;
`lib/lain/cli/wiring.rb` one-liner retaining the always-constructed StatusFeed in Env;
`lib/lain/cli/live_views.rb` one-liner using that instance instead of constructing its own.

**AMENDED (T9 panel, orchestrator-applied):** the "always construct and retain one
StatusFeed" wiring is NOT a one-liner as written — LiveViews is constructed in
ChatLaunch#open_chronicle BEFORE Wiring exists, the feed must be in the tee's sink list
at wrap_tee time, and headless (--no-journal --no-nvim) runs build no tee at all. The
card must thread ONE StatusFeed instance constructed early (ChatLaunch), given to both
the tee path and Wiring's Command::Env — do NOT construct a second feed inside Wiring
(it would be event-blind and /status would render empty with no error). T9's
Command::Env already exposes a loud NullStatus placeholder to swap.

**Acceptance criteria:**

```gherkin
Scenario: /status inline
  When "/status" is typed
  Then warmth, fleet size, and inbox count render inline from the live StatusFeed (works
    with --no-journal, where state.json is absent, because the feed is always wired)

Scenario: /inbox at the main prompt
  Given two pending human questions
  When "/inbox" is typed at you>
  Then the same drain UX as the human> prompt runs and answered items retire from
    StatusFeed's count
```
→ spec file: `spec/lain/cli/command/status_spec.rb`, `sessions_spec.rb`, `inbox_spec.rb`
(under command/)

**Escalation triggers:**
- StatusFeed's `inbox_count` has a known live over-count (never decrements in-session);
  if /inbox surfaces it, fix belongs to the StatusFeed retiring path — coordinate with
  the orchestrator, do not fork a second counter.

### T14 — /approve, /yolo, /model          [wave 3] [risk: medium]

**Depends on:** T9
**Files:** create `lib/lain/cli/command/approve.rb`, `command/yolo.rb`,
`command/model.rb`, `lib/lain/approval/policy_switch.rb`, `lib/lain/context/model_switch.rb`
**Reuse:** `Frontend::ApprovalPolicy`'s prompt loop as the drain UX; `Handler::Gate`'s
policy duck (`ApproveAll`/queue — `gate.rb`). NOTE the seam reality: `Agent`'s `@context`
is construction-fixed and `call_model` always renders from it — `/model` therefore needs a
delegating slot the Context reads at render time (`ModelSwitch`, the same delegating-value
pattern as `PolicySwitch`), injected at Context construction. Do not add a setter to Agent.
**Shared-file wiring:** require+register lines; `lib/lain/cli/wiring.rb` one-liners:
construct Gate with `PolicySwitch.new(initial)` and Context with
`ModelSwitch.new(initial)`, both exposed via Command::Env.

**Acceptance criteria:**

```gherkin
Scenario: /yolo flips the live gate
  Given a chat started without --yolo and a pending-approval tool call
  When "/yolo on" is typed
  Then subsequent gated calls pass without prompting, "/yolo off" restores the queue, and
    each flip is journaled as an attributed event

Scenario: /approve drains inline
  Given three parked pendings
  When "/approve" is typed
  Then each renders for y/N in turn, decisions signed "tty"

Scenario: /model switches the next render
  When "/model <id>" is typed
  Then the next Request carries the new model, the change is journaled, and an unknown
    provider/model fails loudly at dispatch (no silent fallback)
```
→ spec file: `spec/lain/cli/command/approve_spec.rb`, `yolo_spec.rb`, `model_spec.rb`,
`spec/lain/approval/policy_switch_spec.rb`, `spec/lain/context/model_switch_spec.rb`

**Escalation triggers:**
- Gate treats its policy as construction-fixed today; PolicySwitch must be a delegating
  value the Gate already holds, NOT a setter on Gate. If Gate's spec pins policy
  immutability as a security property, stop — that spec is the design speaking.
- `Context#render` is pinned pure ("purity and cache-hit are the same constraint"). A
  ModelSwitch read at render time is a deliberate, journaled impurity with an obvious
  cache consequence (a model change breaks the cache anyway). If a Context spec asserts
  render is referentially transparent over identical Timelines, stop and reconcile before
  weakening it — the switch may need to live one level up (Wiring rebuilding Context),
  and that choice is the orchestrator's.

### T15 — /rewind          [wave 3] [risk: high]

**Depends on:** T3, T9
**Files:** create `lib/lain/cli/command/rewind.rb`; modify `lib/lain/session_record.rb`
(additive `rewound` record type: `{from: H, to: A}`), `lib/lain/bench/session/loader.rb`
(`build_chain` folds `of_type(TURN_TYPE)` today, which discards ordering against other
types — it must fold turn AND rewound records in file order, checking out A and
continuing on a rewound record), `lib/lain/session_record/scribe.rb` (**load-bearing**:
`Scribe#catch_up`'s `extends_written_chain!` raises `Diverged` on exactly the rewound
case — the card adds a `Scribe#rewound(to:)` seam that appends the record, resets the
written head, AND prunes `@written` above the target, because a rewind-and-retry that
re-commits identical content yields an identical digest the skip-set would otherwise
swallow, leaving a parent-hole in the record)
**Reuse:** **`Agent#rewind(count)` — already public and shipped** (`lib/lain/agent.rb:
137-141`, checkouts and `reopen!`s the machine in place; no agent rebuild, no Conductor
teardown). T3's ForkPoint digest resolution for the `/rewind <digest>` form. The additive-
record-type convention (`session_record.rb:8-9` — old readers' `of_type` narrowing skips
unknown types by construction).
**Shared-file wiring:** require+register line.

**Acceptance criteria:**

```gherkin
Scenario: rewind N turns without loss
  Given a session at head H with 3 committed turns
  When "/rewind 2" is typed
  Then Agent#rewind moves the machine to the grandparent in place, the journal appends a
    rewound record {from: H, to: A}, and the next request renders from A

Scenario: a rewound session stays loadable
  Given a journal containing turns to H, a rewound record to A, then two more turns
  When the Loader rebuilds it
  Then build_chain follows the rewound checkout and verifies every turn digest, and
    resume yields the post-rewind head — H stays reachable in the Store record

Scenario: bad target fails loudly
  When "/rewind" names an unknown digest or exceeds history
  Then the command reports the valid range and changes nothing
```
→ spec file: `spec/lain/cli/command/rewind_spec.rb`, additions to
`spec/lain/bench/session/loader_spec.rb` and `spec/lain/session_record_spec.rb`
(the Scribe `Diverged`-on-rewind spec changes here, with orchestrator sign-off)

**Escalation triggers:**
- The loader change is the load-bearing half of this card: without it every /rewind
  session becomes permanently unloadable (`verified_turn` raises `Corrupt` on the first
  post-rewind commit). If the fold cannot express "checkout then continue" without
  weakening digest verification, STOP — that is a Merkle-DAG design conversation.
- `Agent#rewind` may be pinned by specs as an idle-only operation; if it refuses mid-ask
  states, surface the refusal to the user verbatim rather than queueing the rewind.

### T16 — /fork: persistent fork in a new tmux window/session          [wave 3] [risk: medium]

**Depends on:** T2, T3, T9
**Files:** create `lib/lain/cli/command/fork.rb`
**Reuse:** T3 ForkPoint + `--fork` selector; T2 TmuxSurface (window for same-project fork,
detached session for "fork the lain session"); the current head write path Chronicle owns.
**Shared-file wiring:** require+register line.

**Acceptance criteria:**

```gherkin
Scenario: fork the orchestrator at its head
  Given a live chat inside tmux at head H
  When "/fork" is typed
  Then the head is durably journaled first, a new tmux window runs `lain chat --fork
    <session>@<H>`, and the child inherits exactly the H-lineage context (no sibling chat)

Scenario: a subagent target is refused honestly
  Given a Supervisor registration for actor R
  When "/fork R" is typed
  Then the command explains that child chains are not on disk yet and names the
    orchestrator-head form — it does NOT attempt the fork (see Open decisions: /fork
    <subagent> is deferred out of this chunk by panel ruling)

Scenario: outside tmux
  Then /fork prints the exact `lain chat --fork ...` command instead of failing
```
→ spec file: `spec/lain/cli/command/fork_spec.rb`

**Escalation triggers:**
- If investigation shows `Supervisor::Restart` CAN rebuild a child chain from the shared
  journal's records, do not quietly implement /fork R here — report it so the deferred
  card gets pulled in deliberately with its own ACs.

### T17 — /btw: ephemeral side-question in a popup          [wave 3] [risk: medium]

**Depends on:** T2, T3, T6, T9
**Files:** create `lib/lain/cli/command/btw.rb`, `lib/lain/cli/command/keep.rb`
**Reuse:** T3 ephemeral lifecycle (journal-and-reap, promote clears mark); T2
TmuxSurface popup-with-degrade; T6's plugin binding calls the same entry.
**Shared-file wiring:** require+register lines.

**Acceptance criteria:**

```gherkin
Scenario: ephemeral popup
  Given a live chat inside tmux (not control mode)
  When "/btw why is the build red?" is typed
  Then a tmux popup runs an ephemeral fork from the current head with the question as the
    first prompt; closing it cleanly reaps the session

Scenario: promote from inside
  Given a /btw session worth keeping
  When "/keep" is typed inside it
  Then the ephemeral mark clears and the session survives as an ordinary chained fork

Scenario: control mode degrade
  Given tmux -CC
  Then /btw opens a window (per T2's Placement) and says why
```
→ spec file: `spec/lain/cli/command/btw_spec.rb`

**Escalation triggers:**
- Reap-on-clean-exit runs in the CHILD process (it owns its files); if the popup's tmux
  lifecycle kills the child before its atexit runs (popup close = SIGHUP), the reap must
  survive that path — if it cannot, stop and confirm switching to parent-side reaping.

### T18 — Round-trip: edited lain://request reaches the provider          [wave 3] [risk: high]

**Depends on:** T4, T9
**Files:** modify `lib/lain/frontend/neovim/request_buffer.rb`,
`lib/lain/frontend/neovim.rb`, `lib/lain/telemetry.rb` (RequestResent doc + a dispatched
marker), create `lib/lain/cli/resend_bridge.rb`
**Reuse:** T4 RequestOverride; the resend's EXISTING dedicated path — `:LainResend` →
`RpcThread#on_resend` → `Neovim#post_resend` → the resend worker (`neovim.rb:185-198`) —
which the bridge extends, NOT `command_inbox`: that queue has one consumer
(`HumanReplies#editor_reply_loop`, exe/lain:761-769) which pops every verb and drops
non-"reply" on the floor — a second consumer would race it and resends would vanish.
ResendBridge is injected into `Frontend::Neovim`; the resend worker, after journaling the
projection, offers the rebuilt Request to the bridge (Null bridge = today's behavior).
`Channel::DropOldest` stays for view traffic.
**Shared-file wiring:** `lib/lain/cli/repl.rb` one-liner constructing ResendBridge over
the agent's override and passing it to the frontend.

**Acceptance criteria:**

```gherkin
Scenario: edit, resend, dispatch
  Given a chat with --nvim showing lain://request and an idle agent
  When the JSON is edited and :LainResend fires
  Then the NEXT dispatch sends the edited request byte-identically (T4), the journal
    records projection AND dispatch distinctly (the provenance marker lives in the record
    TYPE, never in `extra` — `extra` rides onto the wire, telemetry.rb:256-262), and
    lain://diff shows edited-vs-rendered

Scenario: mid-flight resend is refused, not queued silently
  Given the agent is mid-turn
  When :LainResend fires
  Then the editor is told (echo/virt-text via existing render path) the resend was
    refused and why; nothing dispatches later surprisingly

Scenario: the projection path without the bridge is unchanged
  Given no ResendBridge wired (plain --nvim today)
  Then :LainResend journals + diffs exactly as before
```
→ spec file: `spec/lain/cli/resend_bridge_spec.rb`, additions to
`spec/lain/frontend/neovim_request_spec.rb` (`:nvim`)

**Escalation triggers:**
- `request_buffer.rb:19-23` and `telemetry.rb:251-262` state "never dispatched" as design;
  this card deliberately supersedes that — BOTH comments must be rewritten in the same
  commit (including the "a request_sent with no following turn_usage reads as failure"
  reading, which a dispatched override changes), and if any spec asserts the
  never-dispatched property, it changes here with the orchestrator's sign-off, not
  silently.
- `command_inbox` is out of bounds for this card. If the implementation finds itself
  wanting to route resends through it, stop — verb routing on that queue is a
  HumanReplies redesign this chunk deliberately avoids.
- Timeline commit integrity: the response to an overridden request commits like any turn.
  If digest/canonical machinery resists (turn hash expects rendered-request provenance),
  STOP — that is a Merkle-DAG design conversation, not a workaround site.

### T19 — lain up --nvim: full cockpit layout          [wave 3] [risk: medium]

**Depends on:** T10, T11
**Files:** modify `lib/lain/cli/up.rb`
**Reuse:** T11's chat_args passthrough; T10's `lain.socket_path()` convention (Ruby twin
already in `Paths#project_hash`, `paths.rb:54-58`); `Up`'s session-scoped option
discipline.
**Shared-file wiring:** `exe/lain` up flag one-liner: `--nvim` (boolean or socket).

**Acceptance criteria:**

```gherkin
Scenario: one command, whole cockpit
  Given `lain up --nvim` outside tmux with nvim installed
  Then the chat window is split: one pane `nvim --listen <deterministic socket>`, one pane
    `lain chat --nvim <same socket> <passthrough args>`, and after attach the injected
    runtime opens the standard view layout (T10's :LainStart equivalent invoked via
    --cmd/remote, not keystroke injection)

Scenario: nvim missing
  Then lain up --nvim degrades to today's single chat pane with a named warning in the
    launch messages
```
→ spec file: additions to `spec/lain/cli/up_spec.rb` (tmux-guarded; nvim assertions
additionally `:nvim`-gated)

**Escalation triggers:**
- Socket-path agreement is convention-by-construction (`Paths#project_hash` on both
  sides); if the panes' cwds can differ (tmux default-path quirks), the hash diverges
  silently — assert same-cwd in the spec, and stop if tmux versions make it unpinnable.

### T20 — Subagent windows: spawn → tmux window running lain watch   [wave 3] [risk: medium]

**Depends on:** T2, T7
**Files:** create `lib/lain/cli/fleet_windows.rb`
**Reuse:** the `#<<` sink duck on `JournalTee` (a FleetWindows sink observes `:spawn` /
terminal Message records, exactly StatusFeed's pattern — `status_feed.rb` observe) — but
the sink ONLY enqueues: `tmux new-window` shell-outs run on a separate fiber draining that
queue, never inside the tee fan-out (a synchronous ShellOut there would put process-spawn
latency on the path every telemetry record traverses); T2 TmuxSurface; T7 `lain watch`.
**Shared-file wiring:** `exe/lain` one-liner: `--windows` flag on chat;
`lib/lain/cli/live_views.rb` one-liner adding the sink when enabled and $TMUX present.

**Acceptance criteria:**

```gherkin
Scenario: window per actor
  Given chat --windows inside tmux
  When a subagent actor spawns
  Then a tmux window named for its role opens running `lain watch <spawn-digest>`, and
    when the actor's lineage closes the window title gains a done marker (window is NOT
    auto-killed — the human closes it)

Scenario: outside tmux or without the flag
  Then no window machinery constructs (Null sink), spawn behavior unchanged
```
→ spec file: `spec/lain/cli/fleet_windows_spec.rb` (FakeShellOut; one tmux-guarded
example)

**Escalation triggers:**
- One-shot subagents can spawn in bursts (fan_out); if windows-per-spawn floods (>4 in
  one turn), the card caps and logs rather than opening N windows — but pick the cap with
  the orchestrator, and never silently drop the watch capability for actors.

### T21 — /goal: standing-goal driver          [wave 4] [risk: medium]

**Depends on:** T9
**Files:** create `lib/lain/cli/command/goal.rb`, `lib/lain/cli/goal_driver.rb`
**Reuse:** the Repl's converse loop seam (T1's extraction exposes ask boundaries);
journaled attributed events for each driver iteration; `Agent::Budget` for the cap.
**Shared-file wiring:** require+register line; `lib/lain/cli/repl.rb` one-liner
consulting the driver between asks.

**Acceptance criteria:**

```gherkin
Scenario: goal loops until done-signal
  Given "/goal make the specs green" and a Provider::Mock scripting two continue turns
    then an explicit done marker
  Then the driver re-prompts after each settled turn with the goal + a continue/done
    instruction, stops on the marker, and each iteration is journaled as goal-attributed

Scenario: hard stops
  Then "/goal off", the iteration cap (default 5), and budget interrupt each stop the
    loop, reported inline — no LLM judge decides termination in this version
```
→ spec file: `spec/lain/cli/command/goal_spec.rb`, `spec/lain/cli/goal_driver_spec.rb`

**Escalation triggers:**
- The driver must not re-prompt while an approval is parked or a human question is
  pending (inbox) — if the sequencing seam for "quiescent" isn't observable from the Repl,
  stop rather than polling internals.

### T22 — /ruby: console, file, or expression          [wave 4] [risk: medium]

**Depends on:** T9
**Files:** create `lib/lain/cli/command/ruby.rb`, `lib/lain/cli/inspection_binding.rb`
**Reuse:** IRB's `IRB::Irb` with a custom workspace (the Reline stack chat already uses);
the Repl's collaborator set (timeline, session, supervisor, status_feed) exposed
read-mostly via InspectionBinding.
**Shared-file wiring:** require+register line.

**Acceptance criteria:**

```gherkin
Scenario: three arities
  When "/ruby" bare is typed              Then an IRB console opens over the inspection
    binding and exit returns to chat
  When "/ruby timeline.head" is typed     Then the expression's inspect renders inline
  When "/ruby ./probe.rb" names a file    Then the file runs against the same binding

Scenario: discipline holds
  Then the new lib files contain no $stdout/puts (output_discipline_spec stays green);
    console I/O reaches the terminal only through the streams the TTY frontend hands the
    IRB workspace
```
→ spec file: `spec/lain/cli/command/ruby_spec.rb`

**Escalation triggers:**
- IRB owns the terminal while open; if nesting IRB's Reline inside the Repl's Reline
  corrupts either history or the prompt state machine, stop and confirm a fallback
  (spawn `irb` as a child process with a drb/socket binding) before hand-rolling a REPL.

### T23 — /meta: generate and launch a customized harness          [wave 4] [risk: medium]

**Depends on:** T2, T9
**Files:** create `lib/lain/cli/command/meta.rb`, `lib/lain/prompt/templates/role/meta-harness.md`
**Reuse:** `Skill::RoleSpawn` (`role_spawn.rb:53` — caller-picked role, `:inherit`
context); `Role::Catalog` registration pattern (`catalog.rb:30`); T2 TmuxSurface for the
launch window; `.lain/` as the artifact home (like state.json).
**Shared-file wiring:** require+register line; one `Role::Catalog` entry line
(`:meta_harness`, read-only toolset).

**Acceptance criteria:**

```gherkin
Scenario: generate, review, launch — never auto-run
  Given "/meta try a planner-executor split on this task"
  Then a meta_harness role spawn writes .lain/meta/<slug>.rb (a plain script using lain's
    public API to assemble and run a customized Agent/Wiring), the command prints the path
    and a summary, and ONLY an explicit "/meta run <slug>" launches it in a new tmux
    window (`ruby .lain/meta/<slug>.rb`) — generation never executes generated code

Scenario: generated scripts are honest
  Then the script requires "lain" and carries a header naming its origin prompt and head
    digest; the spec pins BOTH that the template skeleton passes `ruby -c` (syntax) AND
    that its named constants resolve under `require "lain"` (a load check, separately)
```
→ spec file: `spec/lain/cli/command/meta_spec.rb`

**Escalation triggers:**
- The generated script runs with the user's full authority; the generate/run separation
  is the safety line. If any path would make generation and execution one step (including
  "convenience" flags), stop — that design change needs the human.

### T24 — README cleanup, xmonad removal, doc pointers          [wave 4] [risk: low]

**Depends on:** T8, T18, T19
**Files:** modify `README.md`, `TODO.md` (line 7), `ROADMAP.md` (window-topology entry
:566-599 rewritten to the tmux-native reality; xmonad refs dropped from living sections)
**Reuse:** T8's ARCHITECTURE.md as the link target; grounding's stale-claim inventory
(README:15-20,47-50,58-59,82,87-98 and the Status table).
**Shared-file wiring:** none (this card owns these docs; ROADMAP index line for THIS plan
is the orchestrator's).

**Acceptance criteria:**

```gherkin
Scenario: README tells the truth, user-facing
  Then Status/Topology reflect the shipped M4-2 + interface band, `lain up`/`--nvim`/the
    plugins are documented as the entry points, deep architecture moves behind a link to
    ARCHITECTURE.md, and no xmonad reference remains in README or TODO

Scenario: history stays history
  Then planning/interface-integration.md keeps its xmonad survey verbatim (it is a
    record), and ROADMAP's rewritten entry links it
```
→ spec file: none (docs card)

**Escalation triggers:**
- The README topology mermaid also mis-labels journal/Store status; if rewriting it
  surfaces a claim the grounding didn't settle (e.g. lain-core's current wiredness),
  verify in code before writing, or leave the subsection out — no aspirational diagrams.

## Integration checks

- Full suite: `bundle exec rspec` green; `bundle exec rubocop -a` clean;
  `pre-commit run --all-files` green; `cargo test && cargo clippy` untouched-but-verified.
- Gated passes: `LAIN_NVIM=1 bundle exec rspec --tag nvim` (headless editor suite) and the
  tmux-guarded examples on a machine with tmux ≥ the dev box's.
- Manual pass (Joel): `lain up --nvim -- --model <cheap>` cockpit comes up; `/btw` popup
  under plain tmux AND the window degrade under iTerm2 `tmux -CC`; edit-and-`:LainResend`
  round-trip against a real provider (small model); `/fork` a subagent lineage; `/meta`
  generate-review-run; confirm ephemeral reap by exiting a /btw cleanly and checking
  `lain sessions --all`.
- Doc pass: README renders on GitHub without the stale claims; ARCHITECTURE.md file paths
  all resolve (`grep -o` the backtick paths and stat them).
