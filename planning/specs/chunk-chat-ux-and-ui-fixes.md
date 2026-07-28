# Chat UX and the UI defects the live test found

status: in-progress
commit-mode: orchestrator-commits
language: ruby (+ rust in `ext/lain`)
panel: Linus Torvalds, Jeremy Evans, Sandi Metz, Richard Schneeman, Aaron Patterson

## Intent

Two bodies of work in one chunk. First, the four defects a live end-to-end run of
`lain up --nvim` against the ollama arm surfaced on 2026-07-28 — one of which (a zero-byte
session file) has been silently breaking `lain chat --resume` on the dogfood machine since
2026-07-26. Second, the chat-window UX the research pass scoped: a richer prompt line rendered
by a new Rust formatter in `ext/lain`, the metrics that prompt needs (none of which are
published today), a `Theme` of named style tokens, a command render API, vi-mode/multiline
input, `C-g`-to-Neovim composition, and `/` + `@` completion over a Rust fuzzy matcher.

Grounded by `planning/chat-ux-research-2026-07.md` (2026-07-28), which records every option
considered and the tradeoffs — including the rejected ones — with citations. Satisfies ROADMAP
§ Interface & UX's open `[exp]` lines for prompt autocomplete and line editors.

## Grounding

Verified 2026-07-28 against the working tree by four parallel code-exploration passes, a live
smoke run, and a panel verification pass that corrected six citations (recorded below as they
now stand). What the exploration established, and where docs and code disagreed:

- **`lain://journal` cannot fill in a live chat.** `Wiring#run:54` mints one `Lain::Channel`
  consumed only by `Frontend::TTY`; `Effect::Handler::Live` (`wiring.rb:220`) writes
  `Telemetry::ToolOutput` onto it. The nvim `Channel::DropOldest` (`live_views.rb:36`) is a sink
  inside the `JournalTee`, fed by the chronicle. Nothing bridges them, so
  `JournalView#lines` (`lib/lain/frontend/neovim/journal_view.rb:30-37`) has an unreachable only
  branch. **Doc/code disagreement:** that file's comment at `:13` says ToolOutput "renders
  today". It does not.
- **The producer speaks `push`, not `<<`.** `Sink::IOAdapter#emit` calls `@channel.push(...)`
  (`lib/lain/sink.rb:114`). `Channel` aliases `<<` **to** `push` (`lib/lain/channel.rb:129`), not
  the reverse, and `JournalTee` implements **only** `#<<` (`lib/lain/cli/journal_tee.rb:53`). Any
  fan-out substituted at the tool-sink seam must answer `push`. T1 is fenced on exactly this.
- **The bytes are already on disk.** `Bash.render_output` (`tools/bash.rb:44-48`) puts complete
  stdout+stderr into the `tool_result`, which lands in the `turn` record. So this is a *view*
  defect, not a record defect — journaling ToolOutput would duplicate at one fsync'd line per
  write and make every file-materializing reader O(bytes-streamed). Decided: views only.
- **`Approval::Queue#admit` (`approval/queue.rb:149-154`) emits nothing.** The entire approval
  lifecycle's only observable emission is the post-hoc `approval_decision` record. No renderer
  has a signal at PENDING time. `inbox_count: 0` during an approval is therefore correct by
  design — approvals were never in that field's scope.
- **The approval signal will reach `StatusFeed` without `--nvim`.** Verified: `Switchboard.for`
  takes `chronicle.telemetry_kwargs.fetch(:journal)` (`switchboard.rb:28`), `telemetry_kwargs`
  prefers `@tee` (`chronicle.rb:256`), and `LiveViews` calls `wrap_tee` **unconditionally** with
  `status_feed` in the sink list (`live_views.rb:41`).
- **Nothing in the tree emits a terminal BEL.** `lain up:214` sets `monitor-bell on` for a
  window whose occupant never rings. The only `\x07` is `Shutdown::BYTES`' internal pipe protocol.
- **A zero-byte `.ndjson` is the designed-in artifact** of `Journal.open`
  (`lib/lain/journal.rb:60`, `File.new(path, "ab")`) creating the file long before
  `SessionRecord::Scribe#initialize` (`lib/lain/session_record/scribe.rb:57`) writes the header.
  Nothing ever deletes it. Two such files exist on the dogfood machine now. Reader behaviour
  differs three ways: `Sessions` degrades honestly (`sessions.rb:58`); `Resume::Selector#newest`
  (`resume/selector.rb:53-55`) *does* exclude `.btw` via `durable_names` (`:42-44`) but performs
  **no emptiness check**, so it picks the file and `Loader#header` raises `Corrupt`; and
  `Watch#newest_session` (`watch.rb:101`) filters on the `.ndjson` suffix **only** — it excludes
  neither ephemeral nor empty — then tails forever.
- **Zero of the six metrics the prompt wants are published.** Context occupancy's two halves
  exist but the ratio is computed inside `Need::ApproachingWindow#fired?`
  (`lib/lain/compaction/need.rb:78`) and discarded as a boolean (`private_constant :State` is at
  `:32`); session elapsed, time-since-compaction, and time-since-last-input are recorded nowhere.
  `Agent#iterations` (`agent.rb:49-50`) exists but is session-lifetime, not per-ask;
  `Agent#usage` (`:53`) is the cumulative delegation.
- **`StatusFeed`'s published key set is pinned exactly** (`spec/lain/status_feed_spec.rb:234`,
  `contain_exactly`), and the tmux script's copy of the jq filter is pinned by *containment*
  (`spec/plugin/tmux_plugin_spec.rb:53`, `include(Up::Hud::JQ_FILTER)`). Both must move with any
  new key, across `status_feed.rb:196`, `up/hud.rb:24-28`, and
  `plugin/tmux/scripts/lain-status:33-35`. This is why T7 is one card and not four.
- **The frontend palette is nine literal Pastel calls** with no Theme/Palette/token indirection
  anywhere in the repo. `Decorators#render(pastel)` (`decorators.rb:43`) already takes the palette
  as a parameter, so the injection seam exists; only the call sites are literal. **Pastel 0.8.0
  has no 24-bit or 256-colour model** — `pastel/ansi.rb`'s `ATTRIBUTES` is 16 named colours plus
  bright variants. `tty-color` answers *detection* only. T8 is scoped accordingly.
- **A command's whole return is a String** wrapped wholesale in `pastel.cyan` by
  `Repl#settle_command` (`repl.rb:132-139`) plus a full-width rule. Structured styled output is
  impossible without changing that contract.
- **Reline binds keys to method names on `Reline::LineEditor`**, not to Procs — dispatch is
  `respond_to?(method_symbol, true)` then `method(...)` (`line_editor.rb:955-956`). `C-g` (byte 7)
  and `C-x` (24) are both unbound in `EMACS_MAPPING`. **Reline's completion is prefix-only and
  hard-coded**: `filter_normalize_candidates` (`:802-814`) does `item.start_with?(target)`, so
  fuzzy candidates are silently dropped. `@` and `/` are not word-break characters. Prompt
  newlines are mangled at `:225` (`gsub("\n", "\\n")`). **Doc/code disagreement:** ROADMAP
  `:641-646` proposes `completion_proc` for `@file` paths; that route cannot be fuzzy.
- **Reline's own `INT` trap sets a flag and nothing else** (`line_editor.rb:211-213`); the chained
  old trap — `Conductor::PromptBreaker` — runs only from `handle_interrupted` (`:195-204`), on
  Reline's input loop. **Any wait inside a `LineEditor` method must be interruptible or it wedges
  deterministically.** T15 carries this as a design constraint, not a trigger.
- **`reline` is not a `lain.gemspec` dependency** — it appears only as a comment (`:93`) and
  transitively via dev-group `debug`/`irb` (`Gemfile.lock:86,144,201`). A released gem gets
  whatever Reline ships with the user's Ruby. T14 must add it as a runtime dependency to pin it.
- **Standing rulings that constrain this chunk** (`planning/interface-integration.md:418-436`):
  tmux is the primary HUD, the TTY prompt is a per-prompt snapshot, and *"the prompt string is
  fixed once readline is waiting… Don't fight this."* `TTY#render_countdown` already owns the
  bottom line via `@lock` (`tty.rb:516`) and that ownership is spec-pinned. **This chunk honors
  all three** — the prompt is snapshot-shaped. Ticking is out of scope; T12 leaves the seam.
- **`ext/lain`'s charter was widened by Joel on 2026-07-28** beyond persistent data structures to
  any powerful Rust capability. The out-of-process rule is unchanged; the surviving in-process
  test is pure + synchronous + no terminal ownership. Root `CLAUDE.md`'s five-rule section is
  stale on rule 1.
- **`ext/lain` does NOT `forbid(unsafe_code)`** and must not start. `ext/lain/CLAUDE.md:29-35` is
  explicit: that rule belongs to `crates/lain-core`; this crate has **8** `unsafe` blocks
  (verified in `src/lib.rs`), all FFI-boundary calls in magnus's own unsafe API plus `libc::dup`,
  each carrying a `SAFETY:` comment. The root rule means *do not hand-roll new unsafe*.
  `Lain::Ext::Bm25` (`src/lib.rs:1487`) is the exemplar binding: `#[magnus(class = ...,
  free_immediately, frozen_shareable)]` wrapping only an `Arc`.
- **`cargo deny` config lives in the workspace-root `deny.toml`**, not in any `Cargo.toml`.
  `MPL-2.0` is **already** in its allow list (`deny.toml:24`), so `nucleo-matcher`'s licence is a
  settled question. `[bans]` at `:28-31` is workspace-wide, binding `crates/lain-core` too.
- **Verified working before planning** (so no card is speculative): the nvim compose round trip
  (`buftype=acwrite` + `nvim_buf_set_name` + `BufWriteCmd`/`BufUnload` → `rpcnotify` →
  `nvim_buf_get_lines`); `:LainStart` laying out all four buffers once the plugin is on
  runtimepath; and the `:LainResend` provider round trip end to end.

## Orchestrator contract (plan-specific only)

- **Shared files (orchestrator-owned, wiring diffs only):** `lib/lain.rb`,
  `lib/lain/frontend.rb`, `lain.gemspec`, `Cargo.toml`, `ext/lain/Cargo.toml`, `deny.toml`,
  root `CLAUDE.md`, `.rubocop.yml`, `spec/spec_helper.rb`, `.rspec`.
  A new file under `lib/lain/frontend/` is required by **`lib/lain/frontend.rb`**, that subtree's
  index — not by `lib/lain.rb`. A new file, its index line, and its spec land in the **same
  commit** (CLAUDE.md's Committing rule).
- **`lib/lain/frontend/tty.rb` is the contended file.** T8 → T9 → T12 → T14 each touch it, in
  four separate waves, deliberately. No two same-wave cards touch it. Do not let a card "help" by
  editing it out of turn.
- **`lib/lain/frontend/reline.rb` (T14) is the second contended file.** T15 and T16 both register
  actions through it and are therefore in **different waves**. Registration lines are wiring
  diffs the orchestrator applies.
- **Rust cards build before Ruby cards that call them.** `bundle exec rake compile` must pass
  before T13 or T16 can go green.
- **Orchestrator action after wave 1, not a card deliverable:** amend root `CLAUDE.md`'s
  five-rule Rust section for the widened `ext/lain` charter. Wave-1 worktrees fork before it, so a
  card cannot own it.

## Open decisions

None. All four interview questions were answered 2026-07-28; the research doc's Part 7 records
the reasoning. Explicitly deferred **out** of this chunk, with no card gated on them: a ticking
status line (T12 leaves the seam, nothing more), the nvim lualine component (T7 publishes what it
would need), and the two pre-existing `StatusFeed` defects named as non-goals in T7.

## Waves

```
Wave 1: T1, T2, T3, T4, T5, T6, T8, T10      (no unmet deps)
Wave 2: T7 (←T4,T5,T6), T9 (←T8), T11 (←T10)
Wave 3: T12 (←T9)
Wave 4: T13 (←T10,T12), T14 (←T12)
Wave 5: T15 (←T14)
Wave 6: T16 (←T11,T14,T15)
```

Critical path: **T8 → T9 → T12 → T14 → T15 → T16**.

> T12's dependency on T9 is **file contention, not behaviour** — T12 needs nothing from the
> renderable. It waits because both own `tty.rb`. Stated plainly so a future reader does not
> infer a design coupling that isn't there. T16 follows T15 for the same reason: both register
> through `reline.rb`.

---

## Tasks

### T1 — Fan streamed tool output onto the live-view channel   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/cli/wiring.rb`, `lib/lain/cli/live_views.rb`, `lib/lain/cli/chat_launch.rb`
**Reuse:** `Lain::Channel::DropOldest` (`lib/lain/channel.rb`) is the editor-side channel that
must receive the events; `Lain::Channel::Null` is the no-editor path. **Note the duck:** the
producer calls `push` (`sink.rb:114`), so whatever is handed to `Effect::Handler::Live` must
answer `push` — `JournalTee` answers only `<<` (`journal_tee.rb:53`) and cannot be dropped in
unchanged. Its per-sink `ClosedQueueError` swallow is the behaviour worth copying.
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: a shell tool's streamed output reaches the editor
  Given a chat with an attached nvim frontend
  When a bash tool call writes "hello" to stdout
  Then the lain://journal buffer contains a line attributed "[<tool_use_id> stdout] hello"
  And the TTY renders that same output

Scenario: the durable record is unchanged
  Given a chat with --journal
  When a bash tool call streams output
  Then the session NDJSON contains no record of type "tool_output"

Scenario: a quit editor never breaks tool execution
  Given a chat whose nvim channel has been closed
  When a bash tool call streams output
  Then the tool completes and the TTY renders its output

Scenario: a chat with no editor is unaffected
  Given a chat started without --nvim
  When a bash tool call streams output
  Then the TTY renders it and nothing raises
```
→ spec file: `spec/lain/cli/live_views_spec.rb` (new — none exists today), plus an added
example in `spec/lain/cli/wiring_spec.rb`

**Escalation triggers:**
- **The fan-out must answer `push`.** `Sink::IOAdapter#emit` calls `@channel.push` and `Channel`
  aliases `<<` to `push`, not the reverse. A `JournalTee` substituted at `wiring.rb:220` raises
  `NoMethodError` on the first byte of tool output. If the only fix is to grow `Sink` a second
  method, stop — that is a public seam change.
- `spec/lain/cli/chat_launch_spec.rb:127` asserts by **identity** (`be`) that the nvim tee's
  journal leg is the SAME object the scribe writes turns into. If threading the view channel into
  `Wiring` changes which object that is, stop — that invariant is why the one-journal-not-two bug
  was fixed.
- `spec/lain/frontend/neovim_buffers_spec.rb:263-295` uses `ToolOutput` as its render-backpressure
  pump at capacity 4. If ToolOutput now also moves a *view*, those examples stop testing what they
  name — report before adjusting them.

---

### T2 — Put lain's own nvim plugin on the cockpit's runtimepath   [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/cli/up/cockpit.rb`, `lib/lain/cli/up.rb`, `lib/lain/paths.rb`
**Reuse:** `Lain::Core::Child::BINARY` (`lib/lain/core/child.rb:24`) is the precedent for
locating a shipped non-`lib/` file via `File.expand_path(..., __dir__)`; `Up#binary_present?`
(`up.rb:239`) probes a binary; the `@warnings` accumulation idiom is `up.rb:90,100,177,191,211`.
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: the cockpit lays out without the user installing anything
  Given nvim is on PATH and the user's config does not load lain's plugin
  When `lain up --nvim` creates the cockpit
  Then the nvim pane command puts the gem's plugin/nvim directory on the runtimepath
  And the pane command still guards the :LainStart call with exists()

Scenario: a missing shipped plugin degrades loudly
  Given the gem's plugin/nvim directory cannot be located
  When `lain up --nvim` creates the cockpit
  Then a warning naming the missing plugin directory is reported before attaching
  And the cockpit still opens with a plain nvim pane

Scenario: reattaching to an existing cockpit stays silent
  Given a session whose chat window already carries two panes
  When `lain up --nvim` reattaches
  Then no warning is reported
```
→ spec file: `spec/lain/cli/up_spec.rb` (extend the existing `--nvim cockpit composition` group)

**Escalation triggers:**
- `spec/lain/cli/up_spec.rb:388-389` asserts the nvim pane command **by exact string equality**.
  This card changes that string; update that example deliberately and say so — do not widen it to
  a `match`.
- `spec/lain/cli/up_spec.rb:474-480` asserts `report.warnings` is **empty** on a reattach with
  `--nvim` when the cockpit already exists. A new unconditional warning breaks it.
- `plugin/nvim/plugin/lain.lua:1-6` states installing the plugin "must change nothing about how
  lain attaches". If injecting rtp makes a *bare* `nvim --listen` behave differently, stop — the
  zero-install contract is pinned by `spec/plugin/nvim_plugin_spec.rb:266-275`.

---

### T3 — A zero-byte session never blocks resume, fork, or watch   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/cli/resume/selector.rb`, `lib/lain/cli/watch.rb`, `lib/lain/cli/sessions.rb`,
`lib/lain/journal.rb`
**Reuse:** `Paths.ephemeral?` (`lib/lain/paths.rb:49`) is the `.btw` predicate `Watch` currently
lacks (`Selector#durable_names` at `resume/selector.rb:42-44` already has it); `Resume::Refusal`
for the named-selector message.
**Shared-file wiring:** none

> **Consider not creating the artifact before teaching three readers to recognise it.**
> `Journal.open` (`journal.rb:60`) creates the file; the header lands much later
> (`session_record/scribe.rb:57`). Special-casing three readers leaves the fourth one, written
> next year, to hang the same way. Deferring creation until the first record, or unlinking a
> never-written journal on a failed start, removes the class of bug. **If that proves feasible,
> prefer it and reduce the reader changes to defence in depth. If it does not, say why in the
> commit message.**

**Acceptance criteria:**

```gherkin
Scenario: a bare --resume skips an empty newest session
  Given the newest durable session file is zero bytes
  And an older session file is resumable
  When a bare --resume resolves a selector
  Then the older session is chosen

Scenario: naming an empty session refuses with a message that says it is empty
  Given a zero-byte session file
  When --resume names it explicitly
  Then the refusal states the file is empty, not that it is corrupt

Scenario: watch never tails a file that can never close
  Given the newest session file is zero bytes
  When `lain watch <selector>` runs with no --session
  Then it exits with a message rather than polling indefinitely

Scenario: watch ignores ephemeral sessions when choosing the newest
  Given the newest session file is a .btw ephemeral session
  When `lain watch <selector>` runs with no --session
  Then a durable session is chosen instead

Scenario: the listing distinguishes empty from unreadable
  Given a zero-byte session file and a headerless non-empty one
  When `lain sessions` lists them
  Then the zero-byte one reads as empty and the other as unreadable

Scenario: a session that never wrote a record leaves no file behind
  Given a chat that fails before its header is written
  When the process exits
  Then no zero-byte session file remains
```
→ spec files: `spec/lain/cli/resume_spec.rb`, `spec/lain/cli/watch_spec.rb`,
`spec/lain/cli/sessions_spec.rb`, `spec/lain/journal_spec.rb`

**Escalation triggers:**
- `spec/lain/cli/sessions_spec.rb:139-143` pins "headerless → unreadable" using a **non-empty**
  file. That example must keep passing unchanged; only the zero-byte case is new.
- `Resume::Selector` is shared with `CLI::ForkPoint` (`fork_point.rb:33-36`). Changing `newest`
  changes `--fork` too — verify both, and if the two want different rules, stop.
- Deferring file creation changes `Journal.open`'s contract, which `Chronicle` and the WAL both
  build on. If `Paths.wal_for` or `Chronicle#close` assumes the file exists, **stop** — the
  reader-side fixes alone still satisfy every other AC.
- `resume/selector.rb:29-31` documents "`.last` is the newest — also what makes resume
  idempotent". If skipping empties breaks that idempotence claim, report it.

---

### T4 — Emit an approval-pending signal when a tool call parks   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/approval/queue.rb`, `lib/lain/telemetry.rb`
**Reuse:** `Telemetry::Journalable` (`telemetry.rb:28-35`) — `journal_type` derives the record
discriminator from the class name, so a new event needs no registry; `Approval::Queue::Pending`
already carries `requester`, `tool`, `input`.
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: parking a gated tool call announces itself
  Given an approval queue with a journal
  When a tier-3 tool call is admitted and parks awaiting a decision
  Then an approval_pending record naming the requester and the tool is journaled
  And it is journaled before any decision is made

Scenario: the decision record is unchanged
  Given a parked approval
  When it is approved at the tty surface
  Then an approval_decision record is journaled exactly as before

Scenario: an abandoned approval still announced itself
  Given a parked approval
  When the run is abandoned before any decision
  Then the pending record is present and the decision record names the abandoned surface

Scenario: the pending event is deeply frozen
  Given an approval_pending event
  Then Ractor.shareable? holds for it
```
→ spec files: `spec/lain/approval_spec.rb`, `spec/lain/telemetry_spec.rb`

**Escalation triggers:**
- `spec/lain/approval/queue_concurrency_spec.rb:95-97` asserts journal contents via
  `contain_exactly` for N independent pendings. Adding an emission breaks it — update deliberately.
- `Queue#settle`'s `ensure` (`queue.rb:162-168`) is where the decision record is written. If the
  pending emission has to move relative to `@parked << pending` or `@arrivals.enqueue`, stop:
  first-answer-wins and the abandonment path both depend on that ordering.
- A `Pending` holds a clock and a mutable decision, so it is **not** shareable. Emit a separate
  frozen value object rather than the `Pending` itself.

---

### T5 — A run clock: session start, last input, last compaction   [wave 1] [risk: low]

**Depends on:** none
**Files:** `lib/lain/run_clock.rb` (new), `lib/lain/cli/conductor.rb`
**Reuse:** the injected-clock idiom used by `StatusFeed` and `Frontend::TTY::Warmth`
(`tty.rb:375`); `Telemetry::Compaction` (`telemetry.rb:879`) marks a compaction;
`Conductor#read_prompt` (`conductor.rb:111-116`) is the one place a user prompt is answered and
therefore where "last input" is known.
**Shared-file wiring:** one `require_relative` line in `lib/lain.rb`, placed before `status_feed`

> **This card also wires the clock's one write site.** A clock nobody tells about user input is
> dead code; `Conductor` is the only object that sees a prompt return, and no other card in this
> chunk touches it.

**Acceptance criteria:**

```gherkin
Scenario: elapsed time is measured from construction
  Given a run clock built at a known time
  When the clock advances 90 seconds
  Then its elapsed reads 90 seconds

Scenario: answering a prompt resets the idle measure
  Given a chat at the prompt
  When the user answers and then 30 seconds pass
  Then the run clock's idle reads 30 seconds

Scenario: a compaction event is observed off the channel
  Given a run clock used as a channel sink
  When a compaction event arrives and then 10 seconds pass
  Then its since_compaction reads 10 seconds

Scenario: never-compacted is absence, not zero
  Given a run clock that has seen no compaction
  Then its since_compaction is nil

Scenario: unrelated events are inert
  Given a run clock used as a channel sink
  When a tool-output event arrives
  Then nothing raises and no measure changes
```
→ spec files: `spec/lain/run_clock_spec.rb` (new), `spec/lain/cli/conductor_spec.rb`

**Escalation triggers:**
- As a `#<<` channel sink it must tolerate every other event type inertly, the way
  `StatusFeed#<<` (`status_feed.rb:135-140`) does. If any event makes it raise, stop.
- Monotonic vs wall clock: elapsed/idle want monotonic, but `StatusFeed` publishes ISO8601
  absolute deadlines so renderers tick locally. If those two needs conflict, report before
  choosing.
- `Conductor#read_prompt` rescues `PromptBreaker::Break` and closes the session
  (`conductor.rb:111-116`). A signal-ended prompt is **not** user input — do not record one.

---

### T6 — Context-window occupancy as a readable number   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/agent/accounting.rb`, `lib/lain/agent.rb`, `lib/lain/context_window.rb`,
`lib/lain/compaction/need.rb`
**Reuse:** `Agent::Accounting#last_turn_usage` (`agent/accounting.rb:49`) already holds the
numerator — its doc at `:41-45` says "how full is the context right now";
`ContextWindow#window_tokens` (`context_window.rb:104-112`) holds the denominator with
`CONSERVATIVE_FALLBACK` at `:78`. The ratio is currently computed and discarded inside
`Compaction::Need::ApproachingWindow#fired?` (`compaction/need.rb:78`).
**Shared-file wiring:** none

**Acceptance criteria:**

```gherkin
Scenario: occupancy is readable after a turn
  Given an agent that has completed a turn reporting 4096 input tokens
  And a model whose context window is 8192 tokens
  When occupancy is read
  Then it reports 0.5

Scenario: occupancy before any turn is absence
  Given an agent that has completed no turn
  When occupancy is read
  Then it is nil

Scenario: an unknown model falls back conservatively
  Given a model absent from the context-window book
  When occupancy is read for a turn of 4096 input tokens
  Then the conservative fallback window is used as the denominator

Scenario: the compaction trigger is unchanged
  Given a turn at exactly the approaching-window threshold
  When the compaction need is evaluated
  Then it fires exactly as it does today
```
→ spec files: `spec/lain/agent/accounting_spec.rb`, `spec/lain/context_window_spec.rb`,
`spec/lain/compaction/need_spec.rb`

**Escalation triggers:**
- The card owns `need.rb` **only** to extract the shared ratio. `Need::State` is
  `private_constant` (`need.rb:32`) and must stay private. If extraction changes `Need`'s
  behaviour by even one boundary case, stop — the fourth AC is the guard, not a formality.
- `@accounting` is a private ivar on `Agent` and `Agent` delegates only cumulative `usage`
  (`agent.rb:53`). Adding one delegator is fine; widening `Accounting`'s public surface beyond one
  reader is not.

---

### T7 — Publish the run's live metrics to the state feed and its renderers   [wave 2] [risk: high]

**Depends on:** T4, T5, T6
**Files:** `lib/lain/status_feed.rb`, `lib/lain/cli/up/hud.rb`,
`plugin/tmux/scripts/lain-status`, `lib/lain/cli/wiring.rb`, `lib/lain/cli/chat_launch.rb`
**Reuse:** `StatusFeed`'s atomic publish (`status_feed.rb:212-221`) and publish-only-when-changed
guard; `Up::Hud::JQ_FILTER` (`up/hud.rb:24-28`) is the single source the tmux script embeds;
`RunClock` (T5) and the occupancy reader (T6) supply the values; `ChatLaunch#status_feed`
(`chat_launch.rb:79`) is where the one feed instance is built and threaded.
**Shared-file wiring:** none

> **Deliberately does NOT touch `lib/lain/cli/command/status.rb`.** T9 owns that file in the same
> wave. `/status` renders only the keys it names, so it keeps working unchanged against a wider
> state; surfacing the new fields there is T9's business, and T9 must not assume they exist.
>
> **Two pre-existing defects are explicit NON-GOALS of this card**, recorded so the sub-agent does
> not chase them: the live `inbox_count` over-count (`status_feed.rb:54-74` documents it as
> escalated and unfixed, and its stated fix needs a construction-order change to
> orchestrator-owned files) and the W3 fleet undercount (identical spawns share a content address
> **by design**). This card must not make either worse; fixing either is a separate chunk.

**Acceptance criteria:**

```gherkin
Scenario: a parked approval is visible in the published state
  Given a chat publishing state
  When a tool call parks awaiting approval
  Then the published state reports one pending approval

Scenario: an approval decision clears it
  Given one parked approval reflected in the published state
  When it is decided
  Then the published state reports no pending approvals

Scenario: the run's own measures are published
  Given a chat that has run for 90 seconds, been idle 30, and never compacted
  When the state is published
  Then it reports the elapsed and idle seconds and no compaction age

Scenario: context occupancy is published
  Given a turn filling half the model's context window
  When the state is published
  Then it reports 0.5 occupancy

Scenario: the HUD renders the new fields
  Given a published state with a pending approval and 34% occupancy
  When the tmux status filter renders it
  Then the output names both

Scenario: the tmux plugin script and the HUD filter cannot drift
  Then the shipped lain-status script contains the HUD filter

Scenario: an existing reader survives the wider state
  Given a published state carrying the new fields
  When /status renders it unchanged
  Then it still reports cache, fleet and inbox

Scenario: the two known defects are not made worse
  Given a pending human question and two same-digest spawns
  When the state is published
  Then inbox_count and fleet report exactly what they report today
```
→ spec files: `spec/lain/status_feed_spec.rb`, `spec/lain/cli/up_spec.rb`,
`spec/plugin/tmux_plugin_spec.rb`

**Escalation triggers:**
- `spec/lain/status_feed_spec.rb:234` pins the key set with `contain_exactly`, and
  `spec/plugin/tmux_plugin_spec.rb:53` asserts the shipped script contains `JQ_FILTER`. Both move
  here, together, or the wave ends inconsistent.
- `spec/lain/cli/up_spec.rb:72-90` asserts exact HUD strings (`"🔥 fleet:2 inbox:3"`). Those
  change here; update deliberately.
- `spec/lain/frontend/neovim/inbox_view_spec.rb:143-179` holds `InboxView` and
  `StatusFeed#inbox_count` to the **same** rule. Do not touch either side.
- `StatusFeed` is constructed in `ChatLaunch#open_chronicle`, **before** `Wiring` exists
  (`chat_launch.rb:64-72`). If publishing occupancy requires reading a live `Agent`, that is the
  same construction-order problem the inbox gap hit — **stop and hand back** rather than
  restructuring `ChatLaunch`.

---

### T8 — A Theme of named style tokens over Pastel   [wave 1] [risk: medium]

**Depends on:** none
**Files:** `lib/lain/frontend/theme.rb` (new), `lib/lain/frontend/tty.rb`,
`lib/lain/frontend/decorators.rb`
**Reuse:** `Decorators#render(pastel)` (`decorators.rb:43`) already takes the palette as a
parameter — that is the injection seam; `tty-color` (in the bundle via pastel) answers colour
**depth detection**; `Sink::Null` is the Null Object exemplar for a no-colour theme.
**Shared-file wiring:** one `require_relative` line in **`lib/lain/frontend.rb`**

> **Pastel 0.8.0 has 16 named colours and their bright variants — no hex, no 256, no `38;2`.**
> This card therefore does **not** build an SGR quantizer. A token resolves to a Pastel style; the
> theme's job is to report the terminal's depth and never name a colour beyond it.

**Acceptance criteria:**

```gherkin
Scenario: rendering names a token, never a colour
  Given a theme and a tool-output event on stderr
  When the decorator renders it
  Then the styling comes from the theme's error token

Scenario: a theme reports the terminal's colour depth
  Given a terminal reporting 16-colour support
  When the theme is asked for its depth
  Then it reports 16

Scenario: a disabled theme emits no escapes
  Given a theme built for a non-tty stream
  When any token is rendered
  Then the output contains no ANSI escape sequences

Scenario: today's default appearance is preserved
  Given the default theme
  When a response, an error, a question, and tool output are rendered
  Then each carries the same colour it carries today

Scenario: an unknown token fails loudly
  Given a theme
  When an unregistered token is requested
  Then it raises rather than returning unstyled text
```
→ spec files: `spec/lain/frontend/theme_spec.rb` (new), `spec/lain/frontend/decorators_spec.rb`

**Escalation triggers:**
- `spec/lain/frontend/decorators_spec.rb:20` asserts `include(colored.red("boom\n"))` with colour
  enabled — it pins **red for stderr**, round-tripped through Pastel. It must become a token
  assertion here; if the indirection changes the emitted bytes, that is a visible regression —
  report it rather than rewriting the expectation to match.
- `spec/lain/frontend/tty_spec.rb:233` asserts non-tty output is **byte-identical** (`eq("> ")`).
  A theme must not add a single byte on that path.
- `spec/output_discipline_spec.rb` exempts only `lib/lain/frontend/`. If the theme is tempted
  outside that prefix, stop — colours stay frontend-owned.
- The "unknown token raises" AC is the loud-failure rule from CLAUDE.md (why `StringInquirer` was
  rejected). Do not let a missing token silently render plain.

---

### T9 — Commands return a renderable, not a String   [wave 2] [risk: high]

**Depends on:** T8
**Files:** `lib/lain/renderable.rb` (new), `lib/lain/cli/repl.rb`,
`lib/lain/cli/command/status.rb`, `lib/lain/cli/command/help.rb`,
`lib/lain/frontend/tty.rb`
**Reuse:** `Repl#settle_command` (`repl.rb:132-139`) is the whole contract today — `nil`,
`:quit`, `String`, else error; `Repl#deliver_text` (`:147-150`) wraps text in a synthetic
`Response`; `Command::Registry` needs no change since it never inspects a return value.
**Shared-file wiring:** one `require_relative` line in `lib/lain.rb`, before `frontend`

> **The renderable names tokens as Symbols and knows nothing about colour.** That is what lets it
> live in `lib/lain/` and be returned by a command without the `cli` layer depending on the
> frontend; the `Theme` (T8) resolves Symbols to styles at render time. **Only two commands are
> migrated in this card** — `/status` and `/help`, the two with structure worth showing. Every
> other command keeps returning a String, which stays a valid return forever.

**Acceptance criteria:**

```gherkin
Scenario: a command renders styled structured output
  Given a status command returning a renderable whose cache segment names the warm token
  When the repl settles it
  Then the frontend renders that segment in the theme's warm style
  And the surrounding text is not forced into a single colour

Scenario: a plain string still works
  Given a command returning a plain String
  When the repl settles it
  Then it is rendered as it is today

Scenario: quitting is unchanged
  Given a command returning :quit
  When the repl settles it
  Then the conversation ends

Scenario: an unrecognised return is still a loud error
  Given a command returning an Integer
  When the repl settles it
  Then an error naming the command is rendered

Scenario: the text of the migrated commands is unchanged
  Given the status and help commands
  When each is settled
  Then the words rendered are the same as today

Scenario: a renderable on a non-tty stream carries no escapes
  Given a renderable and a non-tty stream
  When it is rendered
  Then the output contains no ANSI escape sequences
```
→ spec files: `spec/lain/renderable_spec.rb` (new), `spec/lain/cli/repl_spec.rb`,
`spec/lain/cli/command/status_spec.rb`, `spec/lain/cli/command/help_spec.rb`

**Escalation triggers:**
- If the renderable cannot travel `deliver_text`'s synthetic-`Response` path (`repl.rb:147-150`),
  report before inventing a second delivery route.
- `spec/lain/cli/repl_spec.rb` asserts on `output.string` with `include`. Changing the **text** of
  `/help` or `/status` is out of scope — only the styling changes.
- If migrating `/status` and `/help` requires touching a third command, stop: String must remain
  a first-class return, and a renderable that forces migration is the wrong shape.
- The renderable must be frozen and `Ractor.shareable?`, like every other value object here.

---

### T10 — A starship-compatible prompt formatter in ext/lain   [wave 1] [risk: high]

**Depends on:** none
**Files:** `ext/lain/src/prompt.rs` (new), `ext/lain/src/lib.rs`, `ext/lain/CLAUDE.md`,
`ext/lain/NOTICE` (new)
**Reuse:** `Lain::Ext::Bm25` (`ext/lain/src/lib.rs:1487`) is the exemplar binding shape —
`#[magnus(class = ..., free_immediately, frozen_shareable)]` over an `Arc`, with
`DataTypeFunctions`; the grammar is starship's `src/formatter/spec.pest` (ISC, 1,712 bytes,
four productions) reproduced in `planning/chat-ux-research-2026-07.md` §6.1.
**Shared-file wiring:** `ext/lain/Cargo.toml` — add `anstyle`, `toml`, `serde`, `unicode-width`.
`deny.toml` — add a `[bans] deny` list for `crossterm`, `termion`, `termwiz`, `console`,
`termcolor`, `terminal_size`, `onig_sys`.

**Acceptance criteria:**

```gherkin
Scenario: a text group carries its style
  Given the format "[lain](bold green) "
  When it is rendered with colour enabled
  Then the output styles "lain" bold green

Scenario: a variable interpolates
  Given the format "$model" and a variable model set to "qwen3:4b"
  When it is rendered
  Then the output is "qwen3:4b"

Scenario: a conditional group elides when every variable inside it is empty
  Given the format "a(-$missing-)b" and no value for missing
  When it is rendered
  Then the output is "ab"

Scenario: a conditional group survives when any variable inside it is set
  Given the format "a(-$present-)b" and present set to "x"
  When it is rendered
  Then the output is "a-x-b"

Scenario: colour is decided by the caller, never by the process
  Given the format "[x](red)" and colour disabled
  When it is rendered
  Then the output is "x" with no escape sequences

Scenario: an interpolated value cannot inject format syntax
  Given a variable whose value is "[evil](red)"
  When it is rendered
  Then that text appears literally and is not interpreted as a text group

Scenario: a malformed format is refused, not silently mangled
  Given the format "[unclosed"
  When it is parsed
  Then a parse error naming the position is raised

Scenario: the renderer is shareable
  Given a compiled format
  Then Ractor.shareable? holds for it
```
→ spec file: `spec/lain/ext/prompt_spec.rb` (new), plus Rust unit tests in `ext/lain/src/prompt.rs`

**Escalation triggers:**
- **`NO_COLOR`/`FORCE_COLOR`/isatty must never be read in Rust.** Colour arrives as a resolved
  argument because Ruby owns the stream. If any crate reaches for the environment, stop — that is
  the `anstyle`-over-`console` rule, and it belongs in `ext/lain/CLAUDE.md`.
- **Do not add `forbid(unsafe_code)`.** `ext/lain/CLAUDE.md:29-35` says that rule is
  `crates/lain-core`'s; this crate has 8 FFI `unsafe` blocks and forbidding them would not
  compile. The rule here is: add no **new** hand-rolled `unsafe`, and every existing one keeps its
  `SAFETY:` comment.
- The `[bans]` list in `deny.toml` is **workspace-wide** and therefore also binds
  `crates/lain-core`. Verify `cargo deny check` still passes for that crate and say so.
- The grammar is copied from an ISC-licensed project — `ext/lain/NOTICE` must carry the
  attribution. `deny.toml:24` allowing ISC covers *dependencies*, not vendored source.
- `Ractor.shareable?` must hold for the wrapped renderer. If a parser cache or scratch buffer
  breaks it, hold only an `Arc` of immutable state and report.

---

### T11 — A fuzzy matcher binding in ext/lain   [wave 2] [risk: medium]

**Depends on:** T10
**Files:** `ext/lain/src/fuzzy.rs` (new), `ext/lain/src/lib.rs`, `ext/lain/CLAUDE.md`
**Reuse:** the same `Bm25` binding shape as T10; `nucleo-matcher` 0.3.1 — upstream-documented as
"purely functional with no I/O or threading", chosen over `skim` (which installs a global
allocator from its library crate) per `planning/chat-ux-research-2026-07.md` §6.1/§6.4.
**Shared-file wiring:** `ext/lain/Cargo.toml` — add `nucleo-matcher` with the
`unicode-segmentation` feature

**Acceptance criteria:**

```gherkin
Scenario: candidates come back ranked
  Given the candidates "lib/lain/frontend/tty.rb" and "lib/lain/tools/bash.rb"
  When they are matched against the query "ttyrb"
  Then the frontend path ranks first

Scenario: matches carry highlight positions
  Given a candidate matched by a query
  When the match is returned
  Then it names the character positions that matched

Scenario: a non-matching candidate is excluded
  Given the candidate "lib/lain/tools/bash.rb"
  When it is matched against the query "zzzz"
  Then it is not returned

Scenario: the boundary is crossed once per batch
  Given five hundred candidates
  When they are matched in one call
  Then one call returns all ranked results

Scenario: ties break deterministically
  Given two candidates scoring identically
  When they are matched twice
  Then the order is the same both times
```
→ spec file: `spec/lain/ext/fuzzy_spec.rb` (new), plus Rust unit tests in `ext/lain/src/fuzzy.rs`

**Escalation triggers:**
- **`nucleo`'s `Matcher` takes `&mut self`** and carries ~135 KB of scratch, so this binding
  cannot be `frozen_shareable` the way `Bm25` is. **Decide deliberately and report which:** keep
  the matcher internal to a single call (shareable wrapper, allocation per call), or expose a
  non-shareable object and exempt it explicitly. Integration check #7 asserts shareability for
  T10's object only — do not silently widen it.
- The licence question is **settled**: `MPL-2.0` is already in `deny.toml:24`. Do not stop on it.
- If matching is ever tempted into a per-candidate FFI call, stop — batch the boundary crossing.

---

### T12 — A prompt-composition seam in the terminal frontend   [wave 3] [risk: medium]

**Depends on:** T9 *(file contention on `tty.rb` only — no behavioural dependency)*
**Files:** `lib/lain/frontend/prompt.rb` (new), `lib/lain/frontend/tty.rb`
**Reuse:** `TTY#read_line_with_history` (`tty.rb:222-226`) is the sole composition site today;
`TTY::Warmth#prefix` (`tty.rb:375-380`) is the precedent for a composed segment returning `""`
rather than nil; `Sink::Null` for the Null renderer.
**Shared-file wiring:** one `require_relative` line in **`lib/lain/frontend.rb`**

**Acceptance criteria:**

```gherkin
Scenario: the default renderer reproduces today's prompt exactly
  Given the null prompt renderer and a warm cache
  When the prompt is displayed on a tty
  Then the string handed to the line editor is byte-identical to today's

Scenario: a non-tty stream is untouched
  Given any prompt renderer
  When the prompt is displayed on a non-tty stream
  Then the output is exactly "> "

Scenario: a renderer composes the prompt from run state
  Given a renderer that reports the model and occupancy
  When the prompt is displayed
  Then the string handed to the line editor contains both

Scenario: a multi-line rendering never reaches the line editor
  Given a renderer returning two lines
  When the prompt is displayed
  Then all but the final line are written to the screen first
  And only the final line is handed to the line editor

Scenario: a failing renderer never blocks the prompt
  Given a renderer that raises
  When the prompt is displayed
  Then today's prompt is shown instead
```
→ spec files: `spec/lain/frontend/prompt_spec.rb` (new), `spec/lain/frontend/tty_spec.rb`

**Escalation triggers:**
- `spec/lain/frontend/tty_spec.rb:182,191,206,215,224` assert the prompt argument is the **exact
  literal `"> "`** across five degraded cases, and `:233` asserts byte-identical non-tty output.
  These must pass **unchanged** with the null renderer. If they cannot, the seam is in the wrong
  place. **Note for the orchestrator:** T14 changes the call site from `readline` to
  `readmultiline` and will have to update these five deliberately — that is T14's job, not this
  card's. Do not pre-emptively loosen them here.
- Reline mangles newlines (`line_editor.rb:225`), which is why multi-line rendering is split by
  the frontend. A header that redraws on resize is out of scope — record it, do not build it.
- **Leave room for ticking.** The seam must not assume it is called only at prompt display. But do
  not build ticking, and do not arbitrate with `Countdown` (`tty.rb:516`) in this card — that
  ownership is spec-pinned.

---

### T13 — Render the prompt through the Rust formatter   [wave 4] [risk: medium]

**Depends on:** T10, T12
**Files:** `lib/lain/frontend/prompt.rb`, `lib/lain/prompt/default.toml` (new),
`lib/lain/cli/wiring.rb`
**Reuse:** `Lain::Ext::Prompt` from T10; `Frontend::Theme` (T8) supplies the resolved colour
mode; `RunClock` (T5) and the occupancy reader (T6) supply the variables.
**Shared-file wiring:** none — `lain.gemspec:34-38` builds `spec.files` from `git ls-files` with
a reject list that does not exclude `lib/`, so a committed TOML ships automatically.

**Acceptance criteria:**

```gherkin
Scenario: the shipped default renders the run's state
  Given the shipped default prompt config
  And a run with a known model, occupancy, fleet size and idle time
  When the prompt is displayed
  Then it names the model, the occupancy and the idle time

Scenario: a user config replaces the shipped one
  Given a project prompt config naming only the model
  When the prompt is displayed
  Then only the model appears

Scenario: a malformed user config degrades loudly and keeps the chat usable
  Given a project prompt config that does not parse
  When the chat starts
  Then a warning naming the file is reported
  And the prompt falls back to today's

Scenario: colour is resolved by Ruby
  Given a non-tty stream
  When the prompt is rendered through the formatter
  Then no escape sequences are emitted

Scenario: the prompt aligns with wide glyphs
  Given a prompt containing an emoji and a CJK character
  When the prompt is displayed
  Then the reported prompt width counts graphemes, not characters
```
→ spec files: `spec/lain/frontend/prompt_spec.rb`, `spec/lain/cli/wiring_spec.rb`

**Escalation triggers:**
- `bundle exec rake compile` must have run; a missing `lain.so` makes this card's specs fail for
  the wrong reason.
- If the prompt render measurably slows the prompt, report the measurement — avoiding a fork/exec
  per prompt was the whole argument for in-process over shelling out to starship.
- Prompt **width** must be measured in graphemes, not chars (`unicode-width` 0.2 semantics: `str`
  width is no longer the sum of `char` widths). If glyphs misalign the cursor, stop.

---

### T14 — Configure Reline: vi mode, multiline input, and a key-action seam   [wave 4] [risk: high]

**Depends on:** T12
**Files:** `lib/lain/frontend/reline.rb` (new), `lib/lain/frontend/tty.rb`
**Reuse:** `Reline.core.config` accessors (`show_mode_in_prompt=`, `vi_cmd_mode_string=`,
`add_default_key_binding_by_keymap`) let lain configure Reline **without** touching the user's
`~/.inputrc`; `Reline.readmultiline(prompt, add_hist) { |buffer| ... }` is what IRB itself uses.
`C-g` (byte 7) is verified unbound in `Reline::KeyActor::EMACS_MAPPING`.
**Shared-file wiring:** `lain.gemspec` — add `reline` as a **runtime** dependency with an
explicit version constraint (it is currently only a comment at `:93` and a dev-side transitive)

> This card owns lain's whole Reline layer because the three parts share one file and one
> question — "how does lain configure the line editor". T15 and T16 register actions through the
> seam it exposes; neither edits this file.
>
> **The submit predicate is this card's most consequential decision.** `readmultiline`'s block
> *is* that predicate. The chosen rule: **a line ending in a backslash continues; anything else
> submits.** State it in the code, and make the AC assert the *rule*, not merely that two lines
> concatenate.

**Acceptance criteria:**

```gherkin
Scenario: a trailing backslash continues the message
  Given a chat prompt
  When the user enters "first \" and then "second"
  Then one message arrives containing both lines

Scenario: a line without a trailing backslash submits immediately
  Given a chat prompt
  When the user enters "hello"
  Then the message "hello" is submitted at once

Scenario: vi mode is off unless configured
  Given no vi-mode configuration
  When the chat prompt is displayed
  Then the line editor is in its default editing mode

Scenario: vi mode shows which mode is active
  Given vi mode is enabled
  When the prompt is displayed
  Then the mode indicator is present

Scenario: lain never edits the user's inputrc
  Given a user inputrc on disk
  When lain configures the line editor
  Then that file is unchanged

Scenario: a registered key action is invoked with the current buffer
  Given an action registered on a free key
  When that key is pressed with "hello" typed
  Then the action receives "hello"

Scenario: an action can replace the buffer without submitting
  Given a registered action that returns replacement text
  When the key is pressed
  Then the buffer becomes the replacement
  And the line is not submitted

Scenario: registering on an already-bound key is refused
  Given a key already bound by the line editor
  When an action is registered on it
  Then registration raises rather than silently shadowing
```
→ spec file: `spec/lain/frontend/reline_spec.rb` (new), plus updates to
`spec/lain/frontend/tty_spec.rb`

**Escalation triggers:**
- **This card breaks five byte-exact prompt assertions that T12 was required to preserve.**
  `spec/lain/frontend/tty_spec.rb:182,191,206,215,224` assert `have_received(:readline)`; moving
  to `readmultiline` changes the message. Update all five **and** `:233` deliberately, and state
  in the commit that the prompt bytes are unchanged even though the method is not. If the bytes
  *do* change, stop.
- Reline binds keys to **method names on `Reline::LineEditor`**, not Procs — so this card adds a
  method to a stdlib class and touches `@buffer_of_lines`. **If it needs more than one method or
  more than one private ivar, stop** — the coupling is then too deep and wants a different design.
- The gemspec pin is not optional. Without it a released gem gets whatever Reline ships with the
  user's Ruby, and a minor bump renaming that ivar breaks the prompt **silently**. Add a spec that
  fails loudly if the ivar disappears.
- `Reline::HISTORY` is process-global and `/ruby` deliberately forces `IRB::StdioInputMethod`
  (`command/ruby.rb:81`) to avoid fighting it. If this card's configuration leaks into IRB, stop.
- `readmultiline`'s block is **not consulted in vi command mode**. If enabling vi mode breaks
  multiline submission, report it rather than working around it.

---

### T15 — C-g composes the message in Neovim and :wq returns it   [wave 5] [risk: high]

**Depends on:** T14
**Files:** `lib/lain/frontend/neovim/compose.rb` (new),
`lib/lain/frontend/neovim/runtime.lua`, `lib/lain/frontend/neovim/rpc_thread.rb`
**Reuse:** `RpcThread#dispatch` (`rpc_thread.rb:291-299`) already routes a `lain_command`
rpcrequest and acks it; `Resender`/`ResendBridge` is the exemplar for an editor-initiated round
trip with a queue and a notice; `Frontend::Neovim::Unbridged` is the Null Object for "no editor
attached".
**Shared-file wiring:** one `require_relative` line in `lib/lain/frontend/neovim.rb`; one
registration line for the `C-g` action, handed to the orchestrator

> **The wait must be interruptible by construction, not by hope.** Reline's own `INT` trap sets a
> flag (`line_editor.rb:211-213`) and the chained `PromptBreaker` runs only from
> `handle_interrupted` (`:195-204`) on Reline's input loop. A blocking `Queue#pop` inside a
> `LineEditor` method sits **on** that loop and will wedge deterministically. Use a bounded,
> pollable wait that yields to the interrupt path.

**Acceptance criteria:**

```gherkin
Scenario: the current draft opens in the editor
  Given an attached editor and "draft text" typed at the prompt
  When the compose key is pressed
  Then a lain://compose buffer holds "draft text"

Scenario: writing returns the edited text to the prompt
  Given a compose buffer holding edited text
  When the buffer is written
  Then the prompt's buffer becomes the edited text
  And the line is not submitted

Scenario: abandoning the buffer restores the prompt
  Given an open compose buffer
  When it is unloaded without being written
  Then the prompt's buffer is unchanged and the prompt is usable

Scenario: no editor attached degrades honestly
  Given no attached editor
  When the compose key is pressed
  Then a notice says composing needs an attached editor
  And the prompt is unchanged

Scenario: interrupting while waiting returns control
  Given the prompt is waiting on a compose round trip
  When the run is interrupted
  Then the prompt returns control rather than blocking

Scenario: a dead editor never wedges the prompt
  Given the editor exits without writing or unloading the buffer
  When the wait exceeds its bound
  Then the prompt returns control with a notice
```
→ spec files: `spec/lain/frontend/neovim/compose_spec.rb` (new),
`spec/lain/frontend/neovim_runtime_spec.rb` (`:nvim`-tagged, real headless nvim)

**Escalation triggers:**
- The buffer **must** be `buftype=acwrite` and **must** be named. `nofile` makes `:w` fail with
  `E382` and `BufWriteCmd` never fires; an unnamed `acwrite` buffer fails with `E32`. Both were
  hit during research — if either appears, the setup is wrong, not nvim.
- `RpcThread#dispatch` currently handles only `sync?` messages; notifications are dropped. If this
  needs `rpcnotify` delivery, that is new routing on the RPC thread — the gem raises on any
  request from a non-main thread, so keep the single-owner discipline and report.
- Do **not** call `finish` on return (the defect in Reline's own `vi_histedit`): the user reviews,
  then submits.

---

### T16 — Fuzzy completion for `/` commands and `@` paths   [wave 6] [risk: high]

**Depends on:** T11, T14, T15 *(T15 for `reline.rb` registration ordering only)*
**Files:** `lib/lain/frontend/completion.rb` (new), `lib/lain/frontend/completion/sources.rb`
(new), `lib/lain/frontend/tty.rb`
**Reuse:** `Lain::Ext::Fuzzy` from T11; `Command::Registry` includes `Enumerable`
(`command/registry.rb:14`) and yields in registration order, so it is already a candidate source;
`Skill::Catalog` for skills. The `Frontend::Theme` (T8) styles the menu and match highlights.
`Countdown#print_above` / `@lock` (`tty.rb:515-531`) is the **existing** owner of writing to the
screen while the prompt is live — the menu goes through that lock, it does not invent a second one.
**Shared-file wiring:** one registration line for the completion key action, handed to the
orchestrator

> Reline's own completion **cannot** be used: `filter_normalize_candidates` (`line_editor.rb:802-814`)
> applies `item.start_with?(target)` to everything `completion_proc` returns, so fuzzy candidates
> are silently dropped. This card renders its own menu through the T14 seam.
>
> **Path candidates come from a plain directory walk, not from the tool layer.** `Tools::ListFiles`
> and `Glob` are `Tool` subclasses with `Tool::Input` validation that flow through the
> effect/approval machinery; sourcing a keystroke path from them would invert the dependency
> direction (frontend → tools) and drag validation into the render loop.

**Acceptance criteria:**

```gherkin
Scenario: a slash prefix offers commands and skills
  Given a registry holding /help and /status
  When completion is requested for "/st"
  Then /status is offered

Scenario: an at prefix offers paths
  Given a project containing lib/lain/frontend/tty.rb
  When completion is requested for "@ttyrb"
  Then that path is offered

Scenario: candidates are ranked by the fuzzy matcher
  Given several matching paths
  When completion is requested
  Then they are offered best match first

Scenario: matched characters are highlighted
  Given a matched candidate
  When the menu is rendered
  Then the matching characters carry the theme's match token

Scenario: accepting a candidate replaces only the completed token
  Given "tell me about @ttyrb" at the prompt
  When a path candidate is accepted
  Then only the @-token is replaced and the rest of the line is intact

Scenario: no candidates leaves the line untouched
  Given a query matching nothing
  When completion is requested
  Then the line is unchanged and a notice is shown

Scenario: the menu never outlives the prompt
  Given an open completion menu
  When the prompt is submitted
  Then the screen carries no menu remnants

Scenario: the candidate set is built once, not per keystroke
  Given a project of one thousand files
  When completion is requested three times
  Then the directory is walked once
```
→ spec files: `spec/lain/frontend/completion_spec.rb` (new),
`spec/lain/frontend/completion/sources_spec.rb` (new)

**Escalation triggers:**
- **Drawing a menu means writing to the screen while Reline is mid-`readline`** — the same
  contested ground `Countdown` owns via `@lock` (`tty.rb:516`), where a PTY probe already found
  Reline hostile (`chunk-fixes-xdg-resume-signals.md:1170-1178`). Go **through** that lock. If the
  menu smears against Reline's echo or steals a keystroke, **stop and hand back** — do not fight
  it inside this card.
- If the candidate walk makes completion visibly slow, stop and report — build once, match per
  keystroke (batch the boundary crossing).
- `@` and `/` are not word-break characters, so the token includes the sigil. If changing
  `Reline.completer_word_break_characters` seems necessary, stop: it is process-global and would
  change `/ruby`'s IRB behaviour too.
- T15 registers first. If both registrations collide at the same key or the same seam method,
  stop — the seam is under-specified and that is T14's defect, not this card's.

---

## Integration checks

After the last wave:

1. `bundle exec rake compile` then `bundle exec rspec` — the full default suite green, with **no
   net decrease in example count** against `main` (`CLAUDE.md`'s "297 examples" is stale; measure,
   do not trust it). `:integration` and `:core` excluded as usual.
2. `bundle exec rspec --tag nvim` — the headless-nvim specs, which T2, T15 and T16 all extend.
3. `bundle exec rubocop -a` clean; **no `Metrics/*` limit loosened** (extract a collaborator
   instead — T9 and T16 are the likely offenders).
4. `cargo test && cargo clippy --all-targets -- -D warnings`, and `cargo deny check` — which now
   enforces T10's terminal-crate ban **workspace-wide**, so confirm `crates/lain-core` still passes.
5. `bundle exec rspec spec/output_discipline_spec.rb` — no new file outside
   `lib/lain/frontend/` touches the terminal.
6. `pre-commit run --all-files`.
7. **Ractor shareability** — the existing spec still passes, including for the new
   `approval_pending` event (T4), the `Renderable` (T9), and T10's compiled format. T11's matcher
   is explicitly **exempt** pending that card's reported decision.

**Manual passes owed to Joel** (none can be asserted headlessly — the rule the previous UI/UX
chunk recorded):

- `lain up --nvim` in a fresh terminal: the cockpit lays out **without** installing the plugin (T2),
  and the prompt renders the new segments (T13).
- A tier-3 approval while watching the tmux HUD: the pending approval appears and clears (T4, T7).
- `C-g` at the prompt with an editor attached: compose, `:wq`, confirm the text returns
  unsubmitted; then `:q!`; then Ctrl-C mid-wait — confirm the prompt survives all three (T15).
- `/st` and `@` completion at the prompt, including accepting a candidate mid-sentence, and a
  completion menu open when a subagent event arrives (T16 against T1's live journal traffic).
- Multiline input with a trailing backslash, and vi mode enabled (T14).
- **On macOS under iTerm2 `tmux -CC`:** confirm the HUD degrade. Per
  `planning/chat-ux-research-2026-07.md` §5.7, `display-popup` never renders and the tmux status
  line is not transmitted to a control client at all — so the HUD may be invisible there
  regardless of this chunk. Record what is actually seen; a `refresh-client -B` subscription is
  the known robust seam if it needs fixing later.
- Confirm the two zero-byte session files on the dogfood machine no longer break bare
  `lain chat --resume` (T3).
