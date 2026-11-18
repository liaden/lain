# Cockpit

`lain up --nvim` is the full setup. One tmux window, 3 panes: an editor pane, a chat
transcript beside it, and an input pane under the transcript. All are pinned to the same cwd and
the same socket, with a status HUD along the bottom.

It requires nvim 0.11+. Below that, lain does not degrade gracefully: the review rail's refusal
delivery reads `'messagesopt'`, an option that does not exist there, and a refusal either arrives as
nvim's own `stack traceback:` or does not arrive at all.

```
┌─ nvim ──────────────────┬─ chat (transcript) ─────┐
│ lain://journal          │ you> refactor the Store │
│  [a3f grep] 12 matches  │                         │
│  [a3f read] store.rb    │ ● read_file store.rb    │
│                         │ ● grep "def fetch"      │
├─ lain://timeline ───────┤ ! docent asks to run    │
│  user   refactor the... │   bash(..) -- answer in │
│  asst   tool_use ×2     │   lain://approval       │
├─ lain://inbox ──────────┼─ input ─────────────────┤
│  2m  which Store impl?  │ 🔥 fleet:2 inbox:1      │
├─ lain://request ────────┤ you> _                  │
│  system: You are...     │                         │
│                         │                         │
└─────────────────────────┴─────────────────────────┘
  🔥 fleet:2 inbox:1                          14:32
```

The input pane is where you type. It is a separate pane because the chat pane is a
scrolling transcript: a prompt drawn into it scrolls away, and a HUD drawn into it cannot be
refreshed in place. So `lain up` runs `lain input` in a pane beneath the transcript. It draws
the HUD on 1 line above the prompt, refreshes it in place without a keypress, and feeds each
line back to the chat over a Unix socket.

The HUD's `fleet:N` is the count. The tree itself is
read in [`lain://status`](#cockpit) and `lain watch`, so a child starting or ending never
reprints the pane. The pane has a floor of 6 rows and no fixed height: grow it and
it stays grown, and only a layout change that drove it under the floor puts it back.

Every gesture works there (`[y/N]`, `human>`, `↑`/`↓` history, `C-g`, `C-x`, `Tab`, Ctrl-C's
countdown and its `s` key), and the HUD stays live while an ask runs and while you type.

`lain input` is an ordinary command, so a pane that dies can be restarted by hand:
`lain input --name <tmux session>` derives the same socket `lain up` did.

The HUD is the `🔥 fleet:2 inbox:1` segment, drawn both in the input pane and along the
bottom of the window. 🔥 means the provider's cached prefix was inside
its sliding TTL at the last publish and ❄ means it was not. `fleet` is how many subagents are running,
and `inbox` is how many questions are waiting on you.

It reads the state file `Lain::StatusFeed`
publishes under `$XDG_STATE_HOME/lain/status/`, keyed by project and never written into your
source tree, so it describes the project the active pane is sitting in. `lain up` prints the
resolved path when it starts. The line is composed once, in Ruby, and published as a field, so
every surface shows the same string and none of them needs a JSON filter. It is never blank and
never an error.

The marker is as fresh as the last publish, and a publish happens on an event. Sit idle past
the provider's cache window and the HUD still shows the marker your last turn earned, which is
wrong in the optimistic direction: 🔥 where the truth is ❄. The prompt's own ●/○ is re-derived at
every turn boundary and no more often.

The input pane redraws its header without a keypress. That redraw is not a new reading: the figure
behind it only moves on an event, so no surface updates during a long idle. `elapsed`,
`idle` and `since_compaction` in the state file have always had the same property. Read the
marker as "how the cache stood when lain last did something".

The editor pane needs nothing installed. `lain chat --nvim` injects its whole runtime into a
bare `nvim --listen` at attach time, so the gem and the editor cannot drift out of sync. Nine
runtime buffers exist from attach, `lain://approval` is primed beside them (10 in all), and other buffers
appear while you use them:

| Buffer | What it shows | Editable |
|---|---|---|
| `lain://journal` | live tool output, attributed `[id stream]` per run | no |
| `lain://timeline` | one line per turn, folded per turn | no |
| `lain://inbox` | pending human questions, newest age first | answer in place |
| `lain://request` | the exact prompt about to be sent | yes |
| `lain://workspace` | the workspace projection, on demand | no |
| `lain://diff` | pending edits, in nvim's own diff filetype | no |
| `lain://status` | the mounted epic's issue graph, as a list and as mermaid, over the live fleet, drawn as a tree with one row per child, nested under the parent it was spawned from | no |
| `lain://tree` | every turn the session has seen, drawn as a tree whose trunk is the chain the session stands on. Abandoned branches are marked `[abandoned]`, the head `[head]`, and a label shows after `#` | no |
| `lain://todos` | the model's todo list, one line per item (`[ ]` pending, `[~]` in progress, `[x]` completed), open work first; `(no todos)` when empty | no |
| `lain://approval` | gated tool calls waiting on you, one row per call. Primed at attach; opens a window only while a call is parked | answer in place |
| `lain://question` | the question set you are answering. Appears when a set is opened from `lain://inbox` | yes |
| `lain://compose` | the draft handed over by `C-g`. Appears while you compose | yes |
| `lain://review` | the review sidebar: the changeset's files (flat or grouped by commit) with their reviewed state. Exists while a changeset review or a survey is open | no |
| `lain://review/OLD/<path>` | the old side of a changeset review diff, beside the new side, which is your real file | no |
| `lain://thread/<id>` | one anchor's conversation in a review, shown in the diff pane your cursor is not in | yes, below the conversation |
| `lain://note/<n>` | a pane for a note too long for the cmdline, opened by `:LainNoteCompose`; one per note | yes |
| `lain://planning` | the roadmap sidebar of the planning tab: one row per issue with its stage, its gate and what blocks it. Exists only in a chat that has an epic mounted | no |
| `lain://epic/<slug>/<doc>` | an epic document the chat just wrote (`research.md`, `epic.md`, an issue or a plan), opened in a split below your window without taking focus. Created on the first write, so it is not among the buffers primed at attach; closing its window is respected on later writes | no |

The fleet is a tree in `lain://status`. Each child gets 1 row: its role, whether it is running,
how many turns it has committed, and the first line of the task it was given. The row is indented under the
parent it was spawned from, so a grandchild reads as one, with the child's age beside it. A drawn
row is clamped to 80 terminal columns, measured by display width and not by character count, so a
long task line cannot wrap out of its row. The input pane shows only the HUD's `fleet:N` count.

A task line is text a model wrote, so it is scrubbed before any terminal sees it: newlines and
tabs become spaces, then whole ANSI escape sequences are removed, then the control and format
characters. A task of `clean\e[1A\e[2KPWNED` was measured putting its own words on the HUD line
before that landed.

`:LainStart` lays them out: journal down the left, timeline over inbox over request on the right.
The planning tab keeps `lain://planning` in a sidebar (44 columns, `vim.g.lain_planning_sidebar_width`
changes it) beside the epic document you open from it.

`lain://request` is the one editable buffer. Change the
prompt by hand, then `:LainResend` sends your bytes to the provider instead of the rendered ones.
That is the fastest way to test whether a context tactic made the difference.

Keys. Everything below is bound by the injected runtime, so it works with the plugin
uninstalled. `:help lain-runtime-commands` is the full contract; this is the index.

At `you>`, in the input pane under the cockpit or in the terminal itself for a plain `lain
chat`:

| Key | Does |
|---|---|
| `↑` / `↓` | walk this session's lines. The durable file at `$XDG_STATE_HOME/lain/history` is still appended per accepted line, but it is never read back. It is one pool shared by every project and every concurrent `lain up` pane, so recalling from it merged panes you were not sitting in |
| `C-g` | hand the draft to `lain://compose` in the editor; `:w` there puts the composed text back at the prompt, where you press `<CR>` to send it |
| `C-x` / `Tab` | completion menu for a `/` or `@` token under the cursor |
| `Shift+Enter` / `Alt+Enter` | insert a newline instead of submitting, at every prompt. A hint row above the prompt says so once per `you>`. Under the cockpit, Shift+Enter needs tmux's `extended-keys`, which `lain up` turns on |
| `\` at end of line | continue onto another line instead of submitting. Emacs and vi insert mode only; vi command mode submits on `<CR>` regardless, a Reline limitation |
| `C-c` | open the grace window; a second `C-c` interrupts now |
| `c` / `w` / `r` / `s` | inside that window: cancel, extend, wait for responses, or stop the running ask and keep the session. An idle `you>` countdown offers only `c` and `w`, since there is no ask to stop |
| `C-d` | EOF, which ends the session |

With the cockpit's tmux mouse on, the wheel scrolls the chat pane's history and your terminal's
native text selection needs Shift held while you drag.

`C-g`, `C-i` (Tab) and `C-x` are the only control keys free across all 3 keymaps lain binds
(emacs, vi_insert, vi_command); Tab is free because lain sets no Reline completion of its own.

In the editor, one key is global, because a survey grows from whatever file you are reading and
there is no buffer name to scope it to:

| Key | Runs | Where |
|---|---|---|
| `<leader>Lsa` | `:LainSurveyAdd` | any real file buffer. Refuses from an unnamed buffer or one of lain's own, and refuses everywhere else too until adding to a survey is wired |

`<leader>L` is the prefix every global lain key uses, and `vim.g.lain_prefix` moves it. Only
global keys wear it: they fire in your own editable file, where every bare letter is already yours.

Every other key is buffer-local, bound on `BufEnter` in that view's own augroup. The ones on
buffers lain built and holds `nomodifiable` are bare letters; `x` on a sidebar row can collide with
nothing. The ones on a review diff wear the prefix, because its new side is your real editable
file. They are bound off the review stamp and not a buffer name, so they exist exactly where
a note may be left:

| Buffer | Key | Does |
|---|---|---|
| any record view (`journal`, `timeline`, `inbox`, `question`, `approval`, a review thread) | `]]` / `[[` | next / previous record. `lain://diff` and `lain://workspace` have neither: they are projections of live state and not logs of records |
| `lain://inbox` | `r`, `<CR>` | `:LainOpen`: open the question set under the cursor in `lain://question` |
| `lain://question` | `x` | tick the option under the cursor; on any other line it is still vim's `x` |
| `lain://question` | `:w` | submit the set. `:w!` declines the whole set. After the last set the buffer is marked `answered at HH:MM`, made read-only and its window closed, with your answers still readable under `:buffer lain://question` |
| `lain://compose` | `:w` | send the draft back to the prompt |
| `lain://tree` | `<CR>` / `L` | `:LainTreeRewind`: move the head to the turn under the cursor (the typed `/rewind`; a turn on an abandoned branch is refused). `:LainTreeLabel`: prompt for a label on that turn, an empty one retracts it |
| `lain://planning` | `<CR>` | open the issue document of the row under the cursor in the planning tab's main window |
| `lain://timeline` | `p` | `:LainPin`: pin the turn under the cursor so compaction may not elide it |
| `lain://approval` | `y` / `n` | `:LainApprove [note]` / `:LainDeny [reason]` / `:LainHold [note]` for the call under the cursor. The `y` and `n` keys answer without words; `:LainDeny` takes the words after it as the reason, and the model reads them in the tool result; `:LainHold` postpones the call and tells the agent a human will answer later. At the `[y/N]` prompt in a plain chat, `n <why>` does the same |
| `lain://review` (the sidebar) | `<CR>` | `:LainReviewOpen`: open the file under the cursor at its first hunk |
| `lain://review` (the sidebar) | `x` / `u` | `:LainReviewMark reviewed` / `unreviewed`. There are 2 keys and no toggle, because a toggle would have to be computed from rows that may already have moved |
| a review thread | `:w` | send what you typed under the conversation to the docent as a question |
| a review diff (either side) | `<leader>Ln` / `<leader>Lq` / `<leader>Lb` | pre-fill `:LainNote note ` / `question ` / `blocker ` on the cmdline: type your words, press `<CR>` |
| a review diff (either side) | `<leader>Lc` | pre-fill `:LainNoteCompose ` on the cmdline: type a kind, press `<CR>`, and a pane opens for a long note |
| a review diff (either side) | `<leader>LN` | `:LainNoteDone`: hand every note back, in placement order |
| a review diff (either side) | `<leader>Lt` | `:LainThread`: open the thread on this line |

The rest are commands with no key on them. All are global, and each refuses outside the buffer it is
about, so none acts on whatever sits on that line somewhere else:

| Command | Does |
|---|---|
| `:LainResend` | send `lain://request` as you edited it, in place of the rendered bytes |
| `:LainReply {answer}` | answer a question set as a one-liner: the set under the cursor in `lain://inbox`, or the oldest listed one from any other buffer |
| `:LainMode {level}` | set the approval level to `ask`, `auto` or `bypass` from any buffer |
| `:LainGoalOff` | stop the chat's standing goal before its next iteration, as `/goal off` does in the chat pane |
| `:LainTreeRefresh` | in `lain://tree`, rescan the session directory for forks of this session |
| `:LainReviewClose` | let the open changeset review or survey go without a verdict |
| `:LainNoteCompose {kind}` | in a changeset diff, open a `lain://note/<n>` pane for a long note on the line under the cursor; `:w` places it |
| `:LainSend`, `:LainContext` | queue a `send` or `context` verb for the agent; nothing acts on either today |
| `:LainSurveyAdd` | bound to `<leader>Lsa`, but it refuses every time: adding a file to a survey is not wired yet |
| `:LainNote {kind} {text}` | in a changeset diff, place a note on the line under the cursor. `{kind}` is `note`, `question` or `blocker` |
| `:LainNoteDone` | hand every note back, in placement order |
| `:LainThread` | open the thread on the line under the cursor |
| `:LainReviewVerdict {verdict}` | conclude a changeset review or a survey. Reads no cursor, so there is no wrong window to type it in |
| `:LainAnnotate` | in an epic review document, prompt for a note and attach it to the current line |
| `:LainReviewDone` | hand an epic review document back. Refuses while the buffer is modified |
| `:LainVersion` | the runtime protocol version |
| `:LainStart` | (the plugin, not the runtime) switch to the session tab of lain buffers, or rebuild it if you closed it |

In tmux, the [plugin](../../plugin/tmux/README.md) binds `prefix + b` for a `/btw` popup and `prefix + F`
to fork the session into a new window. `@lain_btw_key` and `@lain_fork_key` change them.

For your own config, the plugin fires `User LainAttach` and `User LainRender`, marks every buffer
with `b:lain_view`, and ships `lain*` highlight groups. `:help lain` has the full contract.

Without `lain up`. The [tmux plugin](../../plugin/tmux/README.md) puts the same `#{lain_status}`
segment in any status bar and binds the 2 prefix keys above, with no managed session involved.
The [Neovim plugin](../../plugin/nvim/README.md) owns only the per-project socket convention
(`$XDG_RUNTIME_DIR/lain/nvim-<hash>.sock`, or `.lain/nvim.sock` when the project has a `.lain/`)
and the `:LainStart` layout.

Watching subagents. `lain chat --windows` opens a tmux window per subagent spawn, each running
a read-only [`lain watch`](commands.md#lain-watch) on that actor's lineage. It needs `$TMUX`
and a journal.
