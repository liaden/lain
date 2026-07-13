# Interface integration: nvim / tmux / xmonad

> Preliminary research (2026-07-11) into Joel's actual desktop configs — what they already
> provide, what needs to shift for the M4-2 Neovim frontend and the window-topology work
> (ROADMAP § Interface & UX, TODO 7–21), and one open question from the approved plan that
> is now **verified**, not open. Dotfiles live in the `~/.cfg` bare repo.

## Verified: `Neovim.attach_unix` CAN serve inbound `rpcrequest`

The plan (`jiggly-greeting-avalanche.md` § Interface) warned: *verify whether a client from
`Neovim.attach_unix` can serve inbound `rpcrequest`, or whether nvim must `jobstart` the
Ruby handler.* Answered empirically against nvim 0.12.3 + neovim gem 0.10.0
(`planning/rpc_direction_probe.rb`, headless `--clean` nvim):

1. Attach with `Neovim.attach_unix(socket)`; the client knows its `channel_id`.
2. From nvim, `vim.rpcrequest(chan, "lain_ping", "hello")` — a **blocking** request.
3. In Ruby, `client.session.run { |msg| ... }` surfaces it as a
   `Neovim::Message::Request` (`sync?` true).
4. Respond with `client.session.respond(msg.id, value)` — nvim's `rpcrequest` returned
   `"pong:hello"`. Full round trip, no `jobstart` host needed.

**Consequence:** lain can attach to the user's already-running nvim, stash its channel id
(`vim.g.lain_chan = chan`), and define user commands whose callbacks
`vim.rpcrequest(vim.g.lain_chan, ...)` straight back into the Ruby process. Remote-module
ergonomics with zero code installed in the dotfiles.

Four gem gotchas, all load-bearing for the frontend design:

- **Writes flush only on the loop's next read** (`EventLoop#read` is the only `flush` call
  site). A response reaches nvim only while `session.run` keeps looping. Never
  respond-then-shutdown; the serving loop must stay alive for the session's lifetime.
- `Message::Request` has **no `#respond` method** — go through `session.respond(id, value,
  error)`.
- `session.run` **blocks its thread**. It needs a dedicated thread (or fiber, pending the
  concurrency decision), exactly like `Frontend::TTY`'s Channel-drain thread. One loop
  serves both directions: it surfaces inbound requests/notifications and its reads flush
  our outbound writes.
- **The session is single-threaded by construction.** `Session#main_thread_only` raises if
  any call touches the session from a thread other than the one that created it. So
  `Frontend::Neovim` cannot be "serving thread + callers from anywhere": it owns ONE
  thread that both runs the loop and makes outbound calls, and other threads (the agent
  loop, a tool) reach it through an inbox queue it drains — which is conveniently the same
  actor shape the TODO's elixir-style message-passing idea wants anyway. Reentrancy is
  already solved inside that thread: a request made *from within* an inbound-message
  callback rides `yielding_response` (Fiber-based), which is how nvim plugin hosts nest
  calls without deadlocking.

## What the configs already provide (survey)

**nvim 0.12.3** (lazy.nvim, `<space>` leader, rebuilt 0.6→0.11 recently):

- `vim-tmux-navigator` on Alt-hjkl, matching the tmux side — pane topology is already
  seamless.
- `nvim-dap` with an rdbg adapter **including an "Attach to rdbg" configuration** — the
  "step the agent loop from a third pane" plan item is nearly wired already; it only needs
  a port/socket convention shared with how lain starts `rdbg --open`.
- `neotest-rspec` runs `bundle exec rspec` — grader-as-TDD-gate workflows meet the editor
  here for free.
- snacks pickers for **marks, registers, quickfix-shaped lists** — the same introspection
  surfaces TODO 17–21 wants lain to read (jumplist, quickfix, marks, registers) are ones
  Joel demonstrably uses. `nvim_exec_lua` can read all of them
  (`vim.fn.getjumplist()`, `getqflist()`, `getmarklist()`, `getreginfo()`).
- `plugins/ai.lua` is entirely commented out — the "AI in the editor" slot is deliberately
  vacant. Lain is what fills it; don't adopt codecompanion in parallel.
- Markdown: `render-markdown.nvim` (inline heading/table/checkbox decorations, **no
  mermaid**) and `markdown-preview.nvim` (`<leader>wp`, browser, **bundles mermaid.js**).
  See § Markdown & mermaid below.
- `init.lua` already does **context detection** (vscode / firenvim / full) and branches to
  different config profiles — the idiom a "lain" profile would join.
- **No `serverstart`/`--listen` convention exists yet.** This is the one real gap.

**tmux next-3.7** (a dev build — popups, extended keys available):

- `extended-keys on` + `xterm*:extkeys` already set — CSI-u modified keys (shift-enter)
  reach the lain pane; whether reline decodes them is an open experiment for multiline
  prompting.
- `focus-events on` — nvim sees FocusGained/FocusLost, useful for attention-following.
- resurrect + continuum — session persistence is a habit; see crash-resume below.
- No `pane-border-status` — panes are currently untitled.
- copycat is legacy (tmux ≥3.1 has built-in regex search) — unrelated cleanup candidate.

**xmonad** (mod4, alacritty, dual 4k — one portrait, one landscape):

- `ifWider 3000` picks a landscape layout (Tall) vs portrait (Column) per screen. The
  plan's "window 1: lain TTY / window 2: nvim" topology maps directly onto the two-monitor
  split with no config change.
- NamedScratchpads (music/slack/discord) behind a `mod+f` submap — an established pattern
  a lain scratchpad can join.
- dunst is running, and `notify-send` is an existing habit (dotfiles commit 5ba00e2 sets
  its timeout) — the cheap channel for "approval needed" when the lain window is unfocused.
- No UrgencyHook configured (optional, later).

**Toolchain trap for anything spawned outside a login shell:** rubies come from
`ruby-install` and are selected by `chruby`, which is sourced only in interactive zsh.
An xmonad `spawn`, a tmux `run-shell`, or a resurrect restore gets system ruby 3.2.3.
Every launcher script must either `chruby-exec ruby-4.0.5 --` or export
`PATH="$HOME/.rubies/ruby-4.0.5/bin:$PATH"` itself.

## Recommended adjustments

Ordered by when they earn their keep. The principle throughout: **lain-specific logic
lives in the lain repo and is injected at attach time; the dotfiles carry only
conventions** (a socket path, a scratchpad entry) so they never drift against lain's code.

### Now, cheap (pre-M4-2)

1. **Deterministic nvim socket, keyed by project.** A few lines in
   `config/autocmds.lua`: when nvim starts inside a directory containing `.lain/` (or
   unconditionally), `vim.fn.serverstart(path)` at a predictable location —
   `$XDG_RUNTIME_DIR/lain/nvim-<hash-of-cwd>.sock` or simply `.lain/nvim.sock`
   (gitignored). This is the *only* nvim dotfile change lain strictly needs: it converts
   "lain spawns nvim" into "lain attaches to the editor Joel already lives in", which is
   what makes attention-following context possible at all. Keep `lain chat` able to spawn
   its own `nvim --listen` as the fallback when no socket answers.
2. **A `lain up` layout script** (repo-side, `bin/` or a Thor subcommand): create/attach a
   tmux session with one window, three panes — chat (lain TTY, alternate screen), nvim
   (`--listen` on the convention path), and the irb/rdbg console. This satisfies
   "segregate the prompting area from the Ruby REPL" (TODO 9–10) with zero tmux.conf
   changes: the script sets per-session options (`tmux set -t lain pane-border-status top`,
   `pane-border-format '#{pane_title}'`) so the global look is untouched and lain can name
   panes via the OSC 2 title escape through its Sink.
3. **Fold the RPC verification into ROADMAP/plan** — flip the ⚠️ open question to a
   verified trap (the flush-on-read behavior belongs next to the other neovim-gem traps).

### With M4-2 (Neovim frontend)

4. **Attach-and-inject bootstrap.** On attach: `nvim_exec_lua` a lua blob shipped in the
   lain gem that records `vim.g.lain_chan`, creates `:LainResend` / `:LainSend` /
   `:LainContext` user commands (callbacks `rpcrequest` back over the channel), and
   registers `BufReadCmd` autocmds for the `lain://` buffer URIs. Nothing to install in
   `~/.config/nvim`; version skew is impossible because the lua ships with the gem that
   speaks to it.
5. **Serving loop as a frontend collaborator.** A `Frontend::Neovim` owning the
   `session.run` thread, symmetric with how TTY owns the Channel-drain thread. Same
   attributed-event discipline; it subscribes to the Journal/Channel, never to the agent.
6. **rdbg convention.** Decide the socket/port lain uses for `rdbg --open` and add a
   matching entry to `dap.lua`'s ruby configurations, so `<leader>dc` → "Attach to lain"
   is one keystroke. (Current dap config attaches over TCP `${port}`; rdbg's default is a
   unix socket — align one way or the other.)

### With subagents (M5) — the placement decision

7. **Tmux-native subagent placement over xmonad-native** (agreed 2026-07-11). Arguments:
   - Programmatic: `tmux split-window -d` / `new-window -t lain -n <agent>` with pane ids
     lain can track and kill; xmonad placement means spawning terminal emulators and
     matching WM_CLASS, with no handle back.
   - **It answers the iTerm2 question for free**: on macOS, `tmux -CC` renders the same
     session as native windows/tabs. One placement mechanism, both platforms — the
     xmonad/iTerm2 fork in TODO 16 dissolves.
   - Survives SSH and detach; resurrect can restore it.
   - xmonad still supplies the *outer* topology (chat monitor vs editor monitor), which it
     already does with zero changes.
8. **Crash-resume ↔ tmux-resurrect.** TODO 3 (resume after crash) should shape the CLI:
   resurrect restores panes by relaunching the literal command, so `lain chat --resume
   [session]` being idempotent-by-default makes `set -g @resurrect-processes 'lain'` a
   two-word dotfile change that revives the whole bench after a reboot. Design the flag
   with that semantics in mind even before wiring resurrect.
9. **Notification middleware.** A small middleware/Channel subscriber that `notify-send`s
   on approval-request and turn-complete when the pane is unfocused (tmux knows focus;
   `focus-events` already on). Dunst is running; urgency hints via xmonad UrgencyHook are
   a later nicety. On macOS the same seam targets `osascript`/`terminal-notifier`.

### Optional, any time

10. **Lain scratchpad in xmonad.** Join the existing `mod+f` submap: `NS "lain"
    "alacritty --class lain -e <wrapper>" (appName =? "lain") (customFloating $
    rectCentered 0.8)` where the wrapper is `tmux new -A -s lain` chained through
    `chruby-exec` (trap above). Summonable chat from any workspace, matching how
    slack/discord already behave.
11. **tmux popup approvals.** `display-popup` (available on next-3.7) could host the
    tier-3 approval prompt when triggered from an unfocused pane — an alternative arm to
    the dunst notification; worth a quick spike only after the notification middleware
    exists to compare against.

## Markdown & mermaid rendering (plans, research docs)

The question: when lain shows a plan or research doc containing ```mermaid``` blocks, does
the editor render them, or is a separate preview window unavoidable?

What the config can and cannot do today:

- `render-markdown.nvim` renders headings/bullets/tables/checkboxes **in the buffer** via
  extmarks. It does not draw diagrams as text; diagrams-as-images are an image backend's
  job.
- Inline images in a terminal need a graphics protocol. **Official alacritty ships none**
  (no kitty-graphics, no sixel — only an unmaintained fork adds sixel/iTerm2, and not the
  kitty protocol nvim plugins use). This, not any nvim plugin, is the blocker.
- `markdown-preview.nvim` is already installed, bundles mermaid.js, live-syncs with the
  buffer including scroll position, and renders in a browser.

**The inline path exists and is nearly free on the nvim side** (surveyed 2026-07-11):
`snacks.image` — part of the already-installed snacks.nvim — renders images inline in
markdown/latex/typst buffers over the kitty graphics protocol, **converts ```mermaid```
blocks itself** (via `mmdc` from `@mermaid-js/mermaid-cli`, plus ImageMagick for
non-PNG), and **auto-enables tmux `allow-passthrough`** so it works inside the existing
tmux stack. Enabling it is a snacks `opts` flag plus two CLI installs — zero new plugins.
Alternatives in the same space if snacks.image disappoints: `diagram.nvim` /
`mermaider.nvim` (both need `image.nvim` as backend), `md-render.nvim` (rich renderer,
same kitty-protocol + `mmdc` requirements) — all share the identical terminal constraint,
which confirms the constraint is the terminal, not the plugin choice.

**What switching costs:** alacritty → **kitty or ghostty** (both verified good with
snacks.image, including through tmux). Lean kitty: it is the protocol's reference
implementation, the most exercised backend for images-through-tmux, and the zen-mode
config *already* carries a kitty integration block (`plugins.kitty = { enabled = true }`).
Knock-on edits are small and mechanical: `myTerminal` in xmonad.hs, the scratchpad/`lain
up` spawn commands' `--class` flags (kitty and ghostty both support `--class`), and a
config port from alacritty.toml.

**The wider field** (surveyed 2026-07-11 against kitty's own adopter list — Ghostty,
Konsole, st-patched, Warp, wayst, WezTerm, iTerm2, xterm.js — cross-checked with what
snacks.image actually supports, which is only kitty / ghostty / wezterm / tmux):

- **iTerm2 now implements the kitty graphics protocol** — newer than the earlier note in
  this doc assumed, and it changes the macOS calculus: iTerm2 could give inline images
  *and keep `tmux -CC`*, removing that trade-off entirely. Caveat: snacks.image does not
  auto-detect iTerm2, so it needs the `SNACKS_${ENV_NAME}=true` override and a real test
  before relying on it — wezterm is the proof that "speaks the protocol" and "works for
  inline" can differ. iTerm2's older proprietary OSC-1337 image protocol is irrelevant
  here; the nvim plugins in question use the kitty protocol.
- **Konsole** speaks the protocol but is not in snacks' supported set, and pulls KDE
  framework weight into an xmonad desktop for no offsetting win.
- **WezTerm**: partial implementation, inline rendering explicitly unsupported by snacks,
  plus reported hangs in picker previews. Out.
- **Warp**: speaks the protocol, but proprietary, account-pushing, AI-first — the wrong
  citizen for a study bench whose premise is observing your *own* agent.
- **Rio / contour / foot / st**: rio's implementation is young and not on kitty's adopter
  list; contour and foot are sixel-family (a different protocol these nvim plugins don't
  use); st needs patching. None are worth the bet over kitty/ghostty.

So: **Linux shortlist stays kitty or ghostty**; on macOS, test iTerm2-with-override first
(it preserves `tmux -CC`), fall back to kitty/ghostty there if snacks balks. The
tmux-native placement decision survives every branch (`-CC` was a bonus, plain attach
works).

**Recommendation, revised:** if the terminal switch is acceptable — and it appears to be —
inline mermaid via snacks.image is the primary path: diagrams render where the annotation
loop happens, no window juggling, and the plan-iteration flow stays in one buffer. Keep
`markdown-preview.nvim` as the complementary surface rather than replacing it: it is still
better for long-document review (scroll-synced full render) and for anyone without a
kitty-protocol terminal, and lain can still trigger it on `:LainPlan` when a full-page
view is wanted. GitHub renders the same blocks once committed, so no second diagram
source is ever authored.

Sequencing: switch terminal + enable snacks.image first (it pays off independently of
lain); only then wire lain's plan flow to assume inline rendering. Verify at that point
that snacks.image picks up `lain://`-scheme buffers (it keys on filetype; scratch buffers
with `filetype=markdown` should work — same verification item as markdown-preview below).

Rejected: ASCII-art mermaid renderers (immature, lossy for the DAG-shaped diagrams lain
actually produces); wezterm (partial protocol support); lain serving its own HTML preview
(a fourth frontend to maintain).

## Editor state as context (registers, buffers, quickfix, jumplist)

Worth fleshing out — this is TODO 17–21 and it fits the architecture unusually cleanly:
**editor state is Workspace-shaped**. It is volatile, it must be *sent, not stored*, and
it renders into the Request without ever being appended to the Timeline. That single
placement decision answers most of the design questions:

- **Where it renders:** after the last cache breakpoint, exactly like `Context::Recall` —
  editor state changes every turn, and anywhere earlier it would shred the cache prefix.
  Purity is preserved the same way Workspace already is: the *snapshot* is taken before
  render; `Context#render` stays a pure function of its inputs.
- **How it crosses the boundary:** one `nvim_exec_lua` call returning one Lua table per
  snapshot (the batch rule, same as the Rust boundary). The lua blob ships in the gem:
  `vim.fn.getqflist()`, `getjumplist()`, `getmarklist()`, `getbufinfo({buflisted=1})`
  (name, filetype, modified, lastused, cursor), `getreginfo()` for a *selected* register
  set, current buffer's cursor-window of ±N lines.
- **Replay/bench integrity:** the snapshot must land in the Journal as part of the
  rendered Request (it already will if Workspace content is journaled with the Request —
  verify), otherwise `DryReplay` cannot reproduce the turn and the whole arm is
  unmeasurable.
- **It is a swept axis, not a feature.** Arms: none / quickfix-only / full
  attention-following / attention-with-recency-scoring. Metric: grader score vs. tokens
  spent. The jumplist-recency idea (weight what the human visited last) is exactly the
  kind of hypothesis the bench exists to test rather than assume.

Risks to design in from the start:

- **Registers leak secrets.** Joel yanks passwords like everyone else. Default the
  register set to a conservative allowlist (`"`, `0`, maybe `a–e` opt-in), cap bytes per
  register, and make the whole register arm opt-in per session. Same caution for marks in
  files outside the project root — filter to workspace-relative paths.
- **Size discipline:** every list gets a hard cap (last N jumps, first M quickfix entries)
  and the snapshot renders as terse structured text, not raw dumps.
- **Unsaved buffers:** `modified` buffers mean disk and editor disagree — surface the flag
  in the snapshot so the model knows a `read_file` may be stale (see the tool section's
  read-routing rule, which is the real fix).

## Editor commands as tool calls

Also worth fleshing out, because the capability tiering falls out naturally and one
decision here (LSP) is high-leverage:

- **Tier 1 (structured, read-only):** the snapshot above, plus point-reads —
  `nvim_buf_get_lines` on a loaded buffer, `getqflist`. Also the *inverse* direction:
  lain **pushing** a quickfix list into the editor (`setqflist` with a title) so "here are
  the 14 call sites I'm about to change" lands in the human's native review idiom, and
  jumping the human's cursor to a location on request (`:LainShow` → `nvim_win_set_cursor`).
- **Tier 2 (allowlisted, structured mutation):** the sed/awk replacement (TODO 13–15).
  Project-wide search-replace as `setqflist` + `cfdo s/…/…/g | update` — visible,
  buffer-local-undoable, and quickfix-scoped rather than filesystem-scoped. Macro
  playback over a range (`norm! @q` on selected lines) for repetitive structural edits.
  **LSP through the user's already-running servers**: `vim.lsp.buf.rename`, references,
  workspace symbols, code actions, diagnostics pull. This is the sleeper win — lain gets
  semantic rename/references for Ruby, Rust, Lua, LaTeX without owning a single LSP
  process, because the editor already runs them, configured exactly as the human likes.
- **Tier 3 (approval-gated):** arbitrary `nvim_command` / `nvim_exec_lua` with
  free-form input. This is shell-equivalent (`:!cmd`, `system()`, `vim.uv.spawn` are all
  reachable), so it sits at exactly the same tier as `Tools::Bash` — no pretending a
  "vim expression subset" is a sandbox (Tool::Input validates shape, not safety; same
  doctrine here).

Risks, and the rules that answer them:

- **Disk/buffer coherence.** If the agent edits files on disk while the editor holds a
  modified buffer (or vice versa), someone's work gets clobbered. Rule: when a file is
  loaded *and modified* in the attached editor, tool reads route through the buffer, and
  tool writes either refuse or go through the buffer + `:update`. `autoread` handles the
  clean-buffer direction. This is also the honest answer to the Workspace-as-second-DAG
  checkpointing (M4): git checkpoints see disk, so editor-side edits must `:update`
  before a checkpoint is cut.
- **Two hands on one editor.** The human is typing in the same instance the agent drives.
  Rules: the agent never uses `nvim_input`/`nvim_feedkeys` (mode-dependent, races the
  human mid-insert); it operates on buffers by id via `nvim_buf_*` (window- and
  mode-independent); anything that must run in a window context targets a lain-owned
  window. Cursor-stealing (`:LainShow`) happens only on explicit human request.
- **Atomicity/undo:** batch each tool call's edits per buffer (`nvim_buf_set_text` calls
  inside one `undojoin` sequence) so one agent action is one `u` for the human.
- **UI freezing:** an inbound `rpcrequest` from nvim blocks the *editor* until lain
  responds. Handler rule: enqueue-and-ack in microseconds, never run agent work inline;
  anything slow is `rpcnotify` + a later push back. (The reverse direction is safe —
  lain's outbound requests block only its nvim thread.)

## Config isolation: whose init.lua does which nvim run?

There are two different nvims in the topology and they want different answers:

- **The human's editor** (attention context, plan annotation, LSP tools): full personal
  config, always. The whole value is the *real* editor state and the *real* LSP setup;
  isolating any of it defeats the point. Lain's footprint stays injection-only
  (`nvim_exec_lua` at attach), so there is nothing to isolate — the config never learns
  lain exists beyond the socket convention.
- **Agent-facing automation / fallback-spawned nvim** (headless macro or `cfdo` execution
  when no editor is attached; anything the *bench* replays): spawn with `nvim --headless
  --clean -u <lain-init.lua>` where the init ships in the gem. `--clean -u` beats
  `NVIM_APPNAME` here: APPNAME creates a whole parallel profile (its own lazy.nvim
  install, plugin state, treesitter parsers) that would need provisioning and would
  *still* drift, while API-driven automation needs no plugins at all. Determinism is the
  bench requirement — a swept axis that depends on whatever plugins were installed that
  week is not an axis.
- **Not recommended:** a `lain` branch in the personal init.lua's context detection
  (alongside vscode/firenvim). It fits the config's existing idiom, but it splits lain
  logic across two repos with independent update cadences — the drift the
  injection-at-attach design exists to prevent. The context-detection pattern stays the
  right answer for things that are *Joel's preferences about lain sessions* (e.g. a
  quieter statusline in a lain-spawned editor), if any ever accumulate — not for anything
  lain functionally depends on.

The one config-side risk to watch: injected user commands can collide with plugin
lazy-loading or duplicate `:Lain*` names on re-attach. Namespace everything `Lain*`,
make the bootstrap idempotent (`pcall(nvim_del_user_command)` before create), and version
the injected blob (`vim.g.lain_rpc_version`) so a stale editor session refuses a
mismatched gem instead of half-working.

## Line editors: one inputrc governs three panes

`Frontend::TTY`'s prompt is **Reline** — and so are irb's and rdbg's. The bash pane is GNU
readline. All four read `~/.inputrc`. `~/.editrc` is libedit and governs **psql only**
(keep the `EXPLAIN (ANALYZE, BUFFERS, WAL)` bind; it is irrelevant to lain).

The dotfiles **dropped `~/.inputrc`** in commit `18a212e` (2026-06-20, a psql-focused
cleanup). The dropped file carried `set editing-mode vi`, `show-mode-in-prompt`, and
cursor-shape mode strings (bar in insert, block in command). Verified against reline
0.6.3's `config.rb`: Reline supports **exactly those directives** (`editing-mode`,
`show-mode-in-prompt`, `vi-cmd-mode-string`, `vi-ins-mode-string`, plus keyseq bindings
and `keyseq-timeout`). Consequences:

- Today, lain's chat prompt, irb, rdbg, and bash are all **emacs-mode with no mode
  indicator** — at odds with vi-everywhere muscle memory (tmux copy-mode vi, nvim,
  psql via `bind -v`).
- Restoring `~/.inputrc` fixes all four surfaces in one file, vi mode strings included.
  Decide whether the drop was deliberate (some vi users do prefer emacs at line editors);
  if it was, no action — lain inherits emacs consistently.
- **Multiline input**: `Reline.readmultiline(prompt, add_hist) { |text| terminated? }` is
  what irb itself uses. `Frontend::TTY#prompt` should adopt it (continuation decided by a
  termination block) — which demotes the shift-enter/CSI-u question from blocker to
  polish. If shift-enter is still wanted, inputrc keyseq bindings are the first thing to
  try (extended-keys already reach the pane through tmux); reline's handling of CSI-u
  sequences remains the open experiment.
- `.pryrc` exists (editor nvim, debugging aliases); modern pry also rides Reline, so the
  same inputrc applies if pry joins the REPL pane.

## One state feed, three renderers (approved 2026-07-11)

Cache warmth, fleet state, and inbox count are one small state struct published by a
Channel/Journal subscriber — never computed by a renderer. Three surfaces render it:

1. **TTY prompt segment** — prompt color/glyph for cache warm/cooling/cold (lain knows
   last-request time and the sliding TTL; countdown computable locally).
2. **tmux status-right** — per-session flag/count via the `lain up` session options, plus
   `monitor-bell` window flags for subagent state transitions (zero-code fleet glance).
3. **nvim lualine component** — lain pushes the struct via `rpcnotify` → injected lua
   stores `vim.g.lain_state` → a one-line lualine component (`function() return
   vim.g.lain_status or '' end`) renders it, degrading to empty when no lain is attached.
   This is one of the few justified dotfile touches (lualine opts are user config); push
   the *deadline* not a countdown, so the component ticks locally without RPC chatter.

## Approved experiments — feasibility notes (research pass, 2026-07-11)

Per-proposal mechanics, verified facts, and the risks worth designing around. Machine
checks done on the actual desktop: `dunstify` present and its server advertises the
**`actions` capability**; tmux next-3.7 documents `pane-focus-in` hooks, `monitor-bell`,
and `client_activity`; **`mmdc` and ImageMagick 7 are NOT installed** (IM6 `convert`
only).

**1 · One state feed, three renderers — tmux primary (decided 2026-07-11).**
- **Renderer hierarchy:** the tmux status line is the *persistent* surface — visible from
  every pane and window in the lain session (chat, REPL, all subagent panes), already
  positioned `top` in the dotfiles, a natural HUD. lualine only renders while the nvim
  pane is focused, so it demotes to *optional enrichment* (editor-specific state, or skip
  it initially). The TTY prompt is a per-prompt snapshot. Build tmux first; the publisher
  doesn't care.
- tmux: simplest is lain writing the struct to `.lain/state.json` and the lain session's
  `status-right` using `#(jq …)` on a `status-interval`; session-scoped options set by
  `lain up` override the theme plugin's globals (tmux option inheritance: session beats
  global), so the everyday status stays untouched. `monitor-bell` + a BEL from subagent
  panes gives window flags for state transitions with zero code.
- nvim (if/when wanted): no lua handler needed — lain calls `nvim_set_var("lain_state",
  {…})` outbound (already-verified direction); a lualine component reads
  `vim.g.lain_state` on its refresh tick. Push the TTL *deadline*, not a countdown —
  renderers tick locally, no RPC chatter.
- **Reline limitation (design-shaping):** the prompt string is fixed once `readline` /
  `readmultiline` is waiting — no mid-wait refresh. So the TTY prompt shows warmth
  *as of prompt display*; live ticking belongs to tmux. Don't fight this.

**2 · Time-travel as editor motion.**
- Mechanics: one extmark per rendered turn in `lain://timeline` carrying its digest;
  `CursorMoved` autocmd debounced via `vim.uv` timer (~75ms) → `rpcnotify("lain_scrub",
  digest)`; lain re-renders `lain://request`/`lain://diff` **only when the digest under
  the cursor changed**. `Context#render` purity is what makes scrubbing safe: a scrub is
  N pure renders, zero mutations — the invariant to spec is *scrub never writes the
  Store, never commits the Timeline*.
- Cost: render-per-digest is cacheable by digest (content-addressed input ⇒ memoizable
  output); buffer swap via `nvim_buf_set_lines` is fine at request sizes.
- `:LainFork` at cursor = `Timeline` fork from that digest (O(1) by construction) into a
  new chat pane or a mode switch — decide which when building; the cheap part is the fork.

**3 · Approvals in editor idioms.**
- `Handler::Approving` already accepts any `#call(effect, context) → Boolean` policy, so
  **no architectural change**: the new policy enqueues the effect on an approval queue
  and blocks until *some* surface decides. Surfaces: the existing TTY y/N, the list
  buffer (`<CR>`/`dd` → rpcrequest back), and `dunstify
  --action=approve,Approve --action=deny,Deny` (prints the chosen action to stdout;
  capability verified present).
- Fail-closed doctrine extends: notification **timeout or dismissal = deny**, exactly as
  an unrecognized keystroke denies today. First surface to answer wins; the queue
  invalidates the rest. The queue is also what makes approvals *journal-able* (who
  approved, from where, after how long — bench-relevant friction data).

**4 · Human attention as a Journal stream (opt-in).**
- Sensors, all scoped to the lain session so global config is untouched: `set-hook -t
  lain pane-focus-in 'run-shell …'` appending NDJSON lines to a FIFO lain owns; nvim
  `FocusGained`/`FocusLost` autocmds → `rpcnotify`; idleness derived from
  `#{client_activity}` on the same status-interval tick — no extra daemon anywhere.
- Journal shape: `interface.attention.*` event types, attributed like every other event,
  behind a single opt-in flag; the Journal header records that the stream was on, so a
  replay knows whether absence-of-attention-events means "opted out" or "never looked".
- Risk to respect: this stream can reconstruct the human's working rhythm. Opt-in,
  greppable event prefix, and trivially strippable (`grep -v`) before sharing a Journal.

**5 · Bench reports through the same pipeline.**
- Blocker found: the **whole mermaid path** (snacks.image inline *and* report rendering)
  runs through `mmdc` — one install serves both, but it is `@mermaid-js/mermaid-cli`,
  which pulls **puppeteer + headless Chromium** (~500MB). Accept it once, globally
  (`npm i -g`), not per-project. snacks.image also wants ImageMagick for non-PNG; only
  IM6 `convert` is installed — install IM7 (`magick`) or verify snacks' IM6 fallback
  before relying on it.
- The report itself is just markdown emitted by `Compare` into `.lain/reports/` — no new
  rendering code; it inherits whatever the mermaid decision lands on, and reads fine on
  GitHub regardless.

**6 · Statusline (folded into 1).** lualine confirmed (`globalstatus`, nightfox); the
component is the one-liner already described; degrade-to-empty keeps the statusline
honest when no lain session is attached.

## TODO.md cross-check: interface halves of already-covered ideas

A 2026-07-11 sweep of TODO.md against the ROADMAP found most UI-adjacent ideas already
landed (idle compaction → M3c's cache-aware scheduling spec; ollama → the M3b local-model
arm; bash-without-pipes → subsumed by code mode; worktrees → M5 orchestration). But five
of them have an **interface half** that the covering item didn't state. Now recorded in
ROADMAP § Interface & UX; details here:

- **Worktree-pane binding** (TODO 71–73): subagent panes spawn `split-window -c
  <worktree>` with title `role@branch` — switching panes *is* switching isolated
  checkouts, and `lain up` owns the wiring.
- **Idle signals** (TODO 4–6): the compaction scheduler consumes idleness; the interface
  layers *produce* it — tmux `client_activity` + `focus-events` (already enabled), nvim
  `FocusLost`/`CursorHold`, time-at-prompt. Sensor and policy stay separate objects.
- **The human's inbox surface** (TODO 29–30, 74–80): mailboxes-as-projections and the
  `ask_human` promise are M5; the interface half is one notification middleware fanning
  out to dunst (unfocused), a tmux status flag, and a drainable `lain://inbox` view.
  Escalations are inbox items with urgency, never interrupts.
- **Prompt autocomplete surface** (TODO 31): reline has `completion_proc` but no ghost
  text; an nvim `buftype=prompt` buffer is the alternate chat-input arm where extmark
  ghost text (local model) becomes possible.
- **Plan-comment syntax** (TODO 41–42): no nvim markdown plugin has a first-class
  annotation primitive worth adopting; the answer is syntax, not plugin. HTML comments
  (`<!-- lain: ... -->`) are machine-extractable and invisible in every renderer
  (preview, GitHub, inline images); `> [!NOTE]` callouts are the visible alternative when
  the comment should render. The COMMENT template slots (ROADMAP M4 fold-in) should pick
  one of these two shapes so the diff-driven loop can parse annotations positionally.

## Open experiments

- **Shift-enter multiline input**: extended-keys reach the pane; does reline decode CSI-u?
  If not, the lain prompt needs its own keymap layer or a different line editor.
- **`Frontend::Neovim` + concurrency choice**: if the fiber (`async`) answer wins
  (docs/concurrency.md), the `session.run` blocking read needs the same scheduler-hook
  scrutiny as `Mixlib::ShellOut`.
- **Attention-following selection**: jumplist/quickfix/marks are readable today via
  `nvim_exec_lua`; the open design question is scoring/recency-windowing them into a
  `Context::Recall`-shaped combinator so the arm is sweepable like any other.
- **Workspace journaling for replay**: confirm the rendered Workspace/editor snapshot is
  reproducible from the Journal (DryReplay needs the exact request bytes; "sent, not
  stored" must not mean "sent, not recorded").
- **markdown-preview.nvim on lain-driven buffers**: scratch/`acwrite` backing, and reload
  behavior under whole-buffer `nvim_buf_set_lines` rewrites.
- **Injected-command lifecycle**: idempotent re-attach, `:Lain*` namespace collisions,
  version handshake between injected lua and gem.
