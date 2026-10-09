# Commands

Two command surfaces. `lain <subcommand>` runs from your shell. `/<name>` runs from the `you>`
prompt inside a live session, lib-side, with zero model turns.

Every flag listed here is also in `lain help <subcommand>`, which reads from the same Thor
declarations in `exe/lain`.

`lain <subcommand> --help` reaches the same screen. A `--help` written *after* a command name is
routed to `help`, so `lain chat --help`, `lain up --help` and `lain sessions --help` print that
command's usage rather than refusing an unknown switch. Every other unknown switch *is* refused
by name — `lain survey ./docs --permissive` answers `Unknown switches "--permissive"` — so a
mistyped flag never gets read as a positional argument.

---

## Shell commands

### lain chat

Start an interactive session. This is the default subcommand, so bare `lain` runs it.

```bash
lain                                   # anthropic, compaction on, approval gate on
lain --provider ollama --model qwen3:8b
lain --resume                          # newest session for this project
lain --fork 20260725-1a2b@blake3:9f3c  # branch a recorded session at a digest
```

| Flag | Default | What it does |
|---|---|---|
| `--provider` | `anthropic` | `anthropic`, `ollama`, or `ollama-cloud`. |
| `--model` | the provider's own | Model id. Free-form string, not validated against a list. |
| `--api-base` | Ollama's localhost | Overrides the Ollama base URL — for whichever of the chat and the summarizer is on Ollama (see [Compaction](#compaction-flags)). |
| `--max-tokens` | `16384` | Per model turn. A cap, not a reservation: it changes nothing for a reply under it. A thinking model's reasoning counts against it, so a turn cut at the cap prints `model hit max_tokens before finishing` and then `raise --max-tokens (now N); a thinking model's reasoning counts against it`. |
| `--secret-oracle` | off | A local model answers a parked read of a gated path, shown the path and region count, never the contents. The local qwen3:4b oracle was measured approving `.env` at 0.8 to 1.0 confidence (`planning/approval-layering-research-2026-10.md`), so an oracle approve is applied only when the path is gated for where it is (ordinary, exempt, `out_of_scope`, `outside_project`), checked when the surface claims the pending and again when it settles. A deny is always applied. `.env`, keys, named, configured, protected and malformed paths always wait for a human. Known gaps: a link repointed before the surface first claims the pending, and the oracle is never offered an `outside_project` park. |
| `--context-pipeline` | unset | `default`, `reminder`, `cache-breakpoints`, `prune`, `dedupe-tool-calls`, `purge-failed-inputs`, or several joined by `+` and applied left to right. Which combinators render every request. A word **replaces** the default: `prune` alone sends no reminders and no cache breakpoints; `prune+default` keeps both. Unset renders the default and writes no `context_pipeline` key into the session header; a named pipeline, `default` included, is recorded. An unknown, empty or repeated part is refused at launch. |
| `--temperature`, `--seed` | unset | Ride `Request#extra`. Ollama honors both; `--temperature 0` is the determinism recipe. |
| `--auto-approve` | off | Wire an `auto_approver` role that judges pendings the human has not. Races the human's surfaces. |
| `--journal` / `--no-journal` | on | The durable, fsync'd, replayable session record. `--no-journal` also disables `--windows`. |
| `--resume [SESSION]` | off | Bare picks the newest; or give a filename or prefix under this project's session dir. |
| `--fork SESSION@DIGEST` | off | Fork a recorded session at a digest prefix. The parent opens read-only. |
| `--btw` | off | Ephemeral session (`<ts>-<pid>.btw.ndjson`), reaped on clean exit unless promoted with [`/keep`](#keep). |
| `--prompt` | unset | Seed the first question, then read the terminal as usual. |
| `--nvim SOCKET` | off | Attach a Neovim frontend to an `nvim --listen` socket. |
| `--input socket:NAME` | off | Read the human from a [`lain input`](#lain-input) pane instead of from this terminal. `NAME` is a name, not a path — the socket is derived from it under this project. Bare `socket:` means `chat`; `lain up` passes the tmux session's name, so two cockpits on one project do not collide. |
| `--windows` | off | Open a tmux window running [`lain watch`](#lain-watch) per subagent spawn. Needs `$TMUX` and a journal. |
| `--isolation` | `none` | `none` or `worktree`. Which backend actor-mode subagents lease workers from. **Inert in plain chat** — see [Isolation](#isolation-flag). |
| `--epic SLUG` | the sole epic in the home | Mount an epic: its documents become reviewable, [`/implement-epic`](#implement-epic) has something to work, and `lain://status` draws its graph. A home holding several epics with no slug here starts anyway, with a notice. |
| `--grace` | `60` | Seconds a first Ctrl-C or SIGTERM grants a run before it is stopped. A `human>`, `[y/N]` or `command>` prompt open at that moment steps aside for the countdown, and anything half typed there is discarded; it comes back empty if the countdown is cancelled. That includes a `[y/N]` that took the terminal from an idle `you>`; a Ctrl-C at `you>` itself still ends the chat. |
| `--root PATH` | detected | Treat `PATH` as this run's project root instead of walking up from the working directory. An explicit root is intent, so it skips the walk's refusal set. |
| `--cwd PATH` | **the root** | Run as if the working directory were `PATH`. Must lie under the root — and defaults to it, so `--root PATH` alone means "open that project" rather than "that root, from wherever the shell happens to be". |

#### Compaction flags

Compaction is on by default. See
[Compaction and summarizer tiers](../README.md#compaction-and-summarizer-tiers) for how the three
tiers work.

| Flag | Default | What it does |
|---|---|---|
| `--compact` / `--no-compact` | on | Summarize the history's head as it grows. |
| `--compact-bytes` | `262144` | Claimed bytes above which a compaction is warranted: the droppable head narrowed to the turns `--compact-strategy` can collapse, pins excluded. Roughly 64k tokens. |
| `--compact-cap` | `1048576` | Claimed bytes that force a compaction even while the prompt cache is warm. Measured as `--compact-bytes` is, so turns the strategy would leave standing never trip it. |
| `--compact-keep` | `20` | Trailing messages a compaction leaves verbatim. About the last 10 exchanges. |
| `--compact-strategy` | **none** | `summarizing`, `elide`, `summarize-conversation`, `elide-tools`, or a `+`-joined composition of them. Which policy collapses a span — see [Collapse strategies](#collapse-strategies). Unset is not a synonym for any of them. |
| `--summarizer-provider` | `ollama` | `anthropic`, `ollama`, or `ollama-cloud`. The summarizer is a **tier**, chosen independently of `--provider`. |
| `--summarizer-model` | the summarizer provider's own | Never inherits the chat's `--model`. |
| `--summarizer-max-tokens` | `1024` | Ceiling per summary. A truncated summary *replaces* the result it compressed, so this is sized for a paragraph, not a turn. |

Both provider flags are validated against the same set, and a typo in either is refused when the
`Backend` is constructed — not at the first compacting turn, which under `--no-compact` never comes.
A non-positive `--summarizer-max-tokens` is refused there too.

**The signal counts only what the strategy can claim.** `summarize-conversation` claims conversational runs of 2 or more
messages and `elide-tools` claims tool rounds, so under either alone a head made of the other kind is not counted. When the
window fills and the strategy can claim none of the droppable turns, the compaction decision says so, naming the strategy,
and, when the wider arm would claim what it left, suggests `--compact-strategy elide-tools+summarize-conversation` instead of
`--compact-keep`. A pin keeps its turn through a compaction and is not counted either.

```bash
lain --provider anthropic --summarizer-provider ollama    # frontier chat, free local summaries (default)
lain --provider ollama --summarizer-provider anthropic \
     --summarizer-model claude-haiku-4-5-20251001         # local chat, bought summaries
```

Ahead of both sits a third tier that takes no flag: the deterministic summarizers you declare in
`.lain/summarizers.rb`, consulted before any model call — for **every** tool result, not just the
large ones, since a declaration you wrote costs no tokens and no latency and so has no threshold to
clear. Two consequences worth knowing before you write one: a declaration that *raises* falls
through to the flagged tiers above and costs you nothing, but a predicate that never *returns*
blocks the turn that observed the result, with no timeout. See
[Compaction and summarizer tiers](../README.md#compaction-and-summarizer-tiers).

#### Collapse strategies

`--compact-strategy` does **not** switch compaction on, and it does not decide whether the derived
context timeline is built. Every compacting turn derives; this picks the policy that collapses a span
inside that derivation. The background is
[Two lineages, one render path](../README.md#two-lineages-one-render-path).

| Value | What collapses a span | What it costs |
|---|---|---|
| *unset* — the default | The run's own **eager tool-result tier**, read back through the turn's `SummarySnapshot`. This is the control arm, and it is what every un-flagged chat has always rendered. | Nothing extra. The summaries were already fired off the critical path by tier 1; the compacting turn only reads them. A result with no held summary becomes an elision line. |
| `summarizing` | One model call per span, answered through the `--summarizer-*` tier and wrapped in a recorded oracle, so every answer lands on the journal as an `oracle_answer` that a later re-derivation *could* read back instead of re-asking. Nothing in the CLI does that yet — a resumed chat re-asks. | Tokens and latency **on the compacting turn's critical path**, where the eager tier's are not. An unreachable tier leaves the span **uncollapsed** and writes a line to `stderr` attributed to `lain:compaction`; it costs the span, never the turn. |
| `elide` | A deterministic per-message attestation — role, digest, byte count, one line each — and no model call at all. | Nothing but its own bytes, and those are not always a saving: over short messages an attested span can be no smaller than what it replaced. That case is caught and declined as `would_not_shrink` rather than shipped. |
| `elide-tools` | `elide`'s attestation, narrowed to the contiguous runs of **tool-carrying** messages. Every conversational turn is left for the derivation to retain verbatim, in place. | Nothing — no model call. The same `would_not_shrink` caveat as `elide`, and it bites *harder*: the span it claims is exactly the tool observations, so over short tool results the attestation is the whole of what it wrote. |
| `summarize-conversation` | `summarizing`, cut to the **conversational** stretches of more than one message. The model is never asked about a tool observation, and a lone turn between two tool rounds is retained rather than costing a call to summarize one message into a message. | One model call **per claimed run**, not per span — so the per-turn multiplier is N, not 1. Otherwise `summarizing`'s costs exactly: critical-path tokens and latency, and an unreachable tier leaves that one run uncollapsed while its neighbours still collapse. |

**Two strategies compose with `+`, and `elide-tools+summarize-conversation` is the pair to reach
for.** Those two are exact complements by construction — both ask one predicate which messages
carry a tool block — so together they partition a span rather than fighting over it. Any *other*
composition overlaps and is refused at launch (for example `elide+summarize-conversation` or
`elide+elide-tools`), naming the flag value and suggesting `elide-tools+summarize-conversation`.
The union is commutative; the order you write the two names in is not a setting.

**Unset carries no Thor default, on purpose.** A default would materialize the key, so the code that
reads the flag could never tell "no strategy was named" from "someone named the default" — and the
eager tier, the control every flagged run is measured against, would be selectable by nobody. An
unrecognized name is refused by name, listing the valid ones.

```bash
lain --compact-strategy elide          # no model call at compaction time, attestations instead
lain --compact-strategy summarizing \
     --summarizer-provider ollama      # a fresh local summary per span, on the critical path
lain --compact-strategy elide-tools+summarize-conversation \
     --summarizer-provider ollama      # attest the tool rounds, summarize the talk — one derivation
```

#### Isolation flag

`--isolation worktree` resolves an `Isolation::Worktree` backend under a per-project root, decorated
with whatever `.lain/services.rb` declares, and hands it to the `Supervisor` the chat fleet leases
from. Two things are true and worth knowing before you reach for it:

- **Only actor-mode subagents lease.** One-shot spawns and `@role/skill` lines never touch the
  supervisor, and plain `lain chat` constructs no actor-mode subagent — so on its own the flag
  resolves a real backend that nothing leases from. Actor-mode children are what
  [`/implement-epic`](#implement-epic) runs, and the epic driver builds its own worktree isolation
  over the epic's working branch rather than leasing through this flag.
- **A chat's workers do hand their commits back, through the merge coordinator.** A worker runs its
  fast checks (`check`, and `lint` on the files `lint_files` selects) before it rebases onto the
  branch, then queues for the coordinator and answers
  `queued as <id>; lain land wait <id> --branch <branch>`. The parent checkout is never merged into,
  so your uncommitted edits there never block a handback and no handback waits on another's merge.
  [`lain land wait`](#lain-land) says when the work is on the branch. The `isolation` verb tunes the
  checks, the rebase and the landing.
- **One concurrent isolated run per project.** The worktree root is keyed on the repository and
  worker ids restart at 1 per process, so a second `--isolation worktree` run in the same repo
  reaps the first's live checkouts. That is a deliberate trade — it is what lets a *crashed* run's
  leftovers get cleared before the next lease — not an oversight.

A bad backend name, or `worktree` outside a git repository, is refused during wiring, before the
journal is opened.

### lain up

Create or reattach to the `lain` tmux session: a `chat` window plus a session-scoped status HUD.
`PATH` is the project directory to open — expanded against the shell's own, and refused by name
if it is not a directory. Flags after `--` are forwarded to [`lain chat`](#lain-chat).

```bash
lain up                                        # editor | transcript over input pane, + HUD
lain up ~/dev/other-project                    # ...in that one instead
lain up ~/dev/new-project --create             # make it first if it is missing
lain up --no-nvim                              # no nvim pane; still transcript over input pane
lain up --nvim-socket /tmp/lain-abc123.sock    # explicit nvim socket
lain up -- --provider ollama --no-compact
```

**The window is three panes**, not two: an `nvim --listen` pane, a `chat` pane beside it, and an
**input pane** split beneath the chat pane. `--no-nvim` drops the editor and nothing else — the
chat is still a transcript over an input pane, because the reason for the split is that the chat
pane scrolls. The input pane runs [`lain input`](#lain-input): it draws the HUD above the prompt
and refreshes it without a keypress, and every gesture the prompt ever had works there, `[y/N]`
and `human>` included.

Its height is a **floor, not a fixed size**. lain seats it at 6 rows on a
`window-layout-changed` hook, and only when something drove it below that — grow the pane
yourself and it stays grown. In a window shorter than 13 rows the hook stands aside and lets
tmux's own arithmetic run, rather than squeezing the transcript out of existence.

| Flag | Default | What it does |
|---|---|---|
| `--session` | `Up::DEFAULT_SESSION` | tmux session name. Also the input socket's name, so two cockpits on one project do not collide. |
| `--socket` | tmux's default | tmux socket (`-L`). |
| `--nvim` / `--no-nvim` | on | Add the nvim pane beside the chat. The input pane is there either way. |
| `--create` | off | Make `PATH` when it does not exist. Only the last directory is made, so its parent must exist; without the flag a missing `PATH` is refused and the refusal names `--create`. |
| `--nvim-socket PATH` | derived | Listen on this nvim socket instead of the per-project one lain derives. Must be absolute — the socket is the one name both panes have to agree on, and a relative one resolves against whichever pane reads it. |

One directory feeds all four of the places `up` names one: every pane's `-c`, the nvim socket's
hash, the input socket's hash, and the HUD's state file — which lives under
`$XDG_STATE_HOME/lain/status/`, keyed by that same directory's hash, rather than inside the
project. `up` prints the resolved path on every
launch, because nothing else in the program names it.

**Write a value-taking flag with an `=` when it is the last thing before `--`.** `lain up /tmp
--nvim-socket -- --provider ollama` is refused, because the option parser skips the separator and
takes `--provider` as the socket — which would silently forward the `PATH` you typed to `chat`
instead. `--nvim-socket=/tmp/x.sock` cannot be read that way.

**Mouse and selection.** The session turns tmux's `mouse` on, so the wheel scrolls the chat pane's
history. tmux then owns the mouse, and your terminal's native text selection needs Shift held
while you drag. `lain up` also sets the tmux server option `extended-keys` to `on` when it reads
`off`, and it prints a notice when it does (the setting is server-wide). That option alone does not deliver Shift+Enter:
the line editor also asks the terminal for it (`\e[>4;1m`) around every prompt read, `you>`, `command>`, `human>` and the
`[y/N]` alike, and hands the terminal back its plain Enter (`\e[>4;0m`) afterwards, so other programs in the same tmux are
unaffected. Alt+Enter inserts a newline too, in vi command mode as well. The input pane redraws the HUD in place only over
an empty editor: while you are typing it holds still, and a resize waits for the next whole prompt.

`lain up` `exec`s into tmux, replacing the process. From inside tmux it uses `switch-client`;
from outside, `attach`.

### lain input

The pane a human types into, feeding a `lain chat --input socket:NAME`. `lain up` runs it for
you; you run it by hand only to bring a dead input pane back, or to drive a chat you started
yourself.

```bash
lain input                       # the chat socket named `chat`, under this project
lain input --name lain           # the socket `lain up --session lain` derived
lain input --socket /run/user/1000/lain/input-ab12cd34ef56-lain.sock
```

| Flag | Default | What it does |
|---|---|---|
| `--name NAME` | `chat` | The chat's input socket, by name, derived under this project. |
| `--socket PATH` | derived from `--name` | The chat's input socket, by path. |

The derived path is `$XDG_RUNTIME_DIR/lain/input-<project-hash>-<name>.sock` (`/tmp/lain/` when
`$XDG_RUNTIME_DIR` is unset), in a directory created at `0700`. It carries **no pid**, on
purpose: the chat and the pane have to derive the same name before either process exists. A
stale socket file left by a dead chat is rebound; one a live chat still holds is refused by name
rather than stolen. Panes themselves are clients, so a second `lain input` on the same socket
simply connects — and is redrawn with the prompt and HUD standing at that moment rather than
waiting for the next change.

The pane draws the chat's HUD above the prompt and refreshes it without a keypress, completes
`/command` names, and shows the mode's layer lighters beside the prompt. It holds no agent, so
Ctrl-C, Ctrl-\ and `/stop` there travel to the chat's own rail rather than being answered locally.
HUP and TERM end only the pane: closing or killing it leaves the chat running, and a new
`lain input` on the same socket picks the chat back up.
While an ask runs, the input pane's header rows update in place; redraws stop once a line is
sent, until the next prompt draws the header, and a header that gains or loses rows waits for the
next prompt too. A typed line that wraps past the pane width can misplace an in-place redraw.

### lain sessions

List this project's recorded sessions, newest first. Offline.

`--all` includes ephemeral `--btw` sessions, which are hidden by default.

A row ending in `N lines unparsed` names a session with unparseable lines in its journal
(`Journal.records` skips them rather than raising, since the fd can be shared with Rust tracing
spans). Nothing wrong can be *built* on the gap -- forking such a session refuses precisely,
naming the record index and both digests -- but the count is real: treat it as a reason to
inspect the file, not as noise to ignore.

### lain watch

Read-only live tail of one actor's lineage. The selector is a spawn digest prefix.

```bash
lain watch 9f3c
lain watch 9f3c --session 20260725-1a2b.ndjson
```

`--session` defaults to this project's newest. This is what `lain chat --windows` opens per
subagent spawn. It owns its exit status, and Ctrl-C on a SIGKILL'd session exits clean.

### lain friction

Knob guidance from one session's friction signals. Offline, deterministic, no API key.

Reads the journal back and tells you which knobs the run was fighting: approval churn,
compaction thrash, iteration ceilings.

### lain trust

```
lain trust [PATH]          # show the project's .lain/*.rb, ask [y/N]
lain trust --yes [PATH]    # grant without asking, for a headless run
lain trust --user          # the same for $XDG_CONFIG_HOME/lain/config.rb, which takes no PATH
```

Shows every top-level `.lain/*.rb` of the project at `PATH` (default: the current project), with
control characters escaped, and on a yes records a mark for those exact bytes. Trust covers those
files only, not what they `require` or `load`. Any changed byte, added file or rename is a new
decision. A no, or end of input, records nothing and exits non-zero, so `lain trust && lain chat`
stops there. A project with no `.lain/*.rb` has nothing to trust. `--user` judges the one file
`$XDG_CONFIG_HOME/lain/config.rb`, which runs in every project, under a mark no project's can equal.

### lain consolidate

Court-clerk pass: distill a session's completed subagent lineages into memory.

`--dry-run` reports what would be clerked with no spawn and no API key. Takes `--provider`,
`--model`, and `--max-tokens` like [`lain chat`](#lain-chat), so you can clerk locally against
Ollama.

### lain improve

Harness-improver pass: record what would make lain itself better into the dogfood queue.

Same `--dry-run` / `--provider` / `--model` / `--max-tokens` shape as
[`lain consolidate`](#lain-consolidate).

### lain improvements

The accumulated cross-project dogfood queue, written by the `improvement_write` tool into
`$XDG_STATE_HOME/lain/improvements.ndjson`.

`--project` filters to one project (a 12-hex-char hash, or a path resolved the same way).
`--kind` filters to `knob`, `bug`, `missing-feature`, or `doc`.

### lain epic

The epic tier: the artifact home, the issue graph, and the sign-off queue. Every verb takes an
optional `SLUG`, and with one epic in the home it is optional — with several, an ambiguous command
refuses and names them rather than guessing.

```bash
lain epic status                                   # where one epic stands
lain epic status --mermaid                         # the issue graph as mermaid source
lain epic submit issue_plan --issue export-stream
lain epic queue                                    # what is parked for sign-off
lain epic approve DIGEST --reason 'read it'
lain epic land export-stream                       # land one approved issue, locally
lain epic finish                                   # every issue done -> one pull request
lain epic finish --local                           # ...or one merge commit in main, no remote
```

| Command | What it does |
|---|---|
| `lain epic status [SLUG]` | Ready issues and remaining waves, folded from the Journal. `--mermaid` renders the graph as mermaid flowchart source instead of the text report. Read-only and deterministic. |
| `lain epic submit STAGE [SLUG]` | Submit an artifact to a stage's gate. `--issue` names the issue for the per-issue stages, `--digest` the changeset for `implementation`; `--provider`/`--model` wire the adjudicating spike. |
| `lain epic queue [SLUG]` | The parked sign-offs, folded from the journals rather than read from a file. |
| `lain epic approve DIGEST` / `lain epic deny DIGEST` | Append a terminal decision, draining the partition. Both take `--reason`. |
| `lain epic add ID TITLE [SLUG]` | Add an issue discovered mid-flight. `--discovered-from` names the live issue it grew out of. |
| `lain epic split ID [SLUG]` | Replace one issue with several. `--into` is required and takes comma-separated ids. |
| `lain epic merge LEFT RIGHT [SLUG]` | Replace two issues with one. `--as` is required and names the id it takes; `--title` overrides the combined title. |
| `lain epic land ISSUE_ID [SLUG]` | Land one approved issue onto the epic's working branch, pushing nothing. `--resume` finishes a landing that merged and then stopped. |
| `lain epic finish [SLUG]` | Take an epic whose every issue is done to `main` as one pull request, then delete its remote branch. `--local` merges it into `main` in this repository instead: no remote, no pull request, nothing pushed. |

The three graph verbs are journaled as a `graph_revision`, so a restructuring is part of the record
rather than an unexplained change to a file.

**`lain epic finish --local`** is for a repository with no remote. The base branch is always `main`.
It must be the branch checked out in the project root, with no uncommitted changes to tracked
files, and no untracked file standing where the merge would write. Otherwise the command refuses
before merging anything and names what to fix. The merge is computed in the object store with
`git merge-tree`, so a conflict is found without touching your checkout: the command stops, names
the conflicting paths, and `main` has not moved. A clean merge becomes one merge commit, and `main`
is fast-forwarded to it. If `main` already holds the epic's tip, the command says so and merges
nothing. The journal records the merge as `local_merge`, so a later remote finish never reads it as
a pull request. The local `epic/<slug>` branch stays for [`lain worktrees gc`](#lain-worktrees-gc) to reap.

**`lain epic land` names an issue, never a commit.** It takes no SHA: the commit it lands is the one
anchored when the implementation gate approved it, found rather than named. A commit nobody approved
therefore has no way to be landed by typing it — unrepresentable rather than merely refused.

When it refuses, it says which thing is missing. `no worker commit is anchored for issue X of epic <slug>` means the driver
never handed back a commit for that issue: re-run it through the driver. `no anchored commit carries an approved
implementation gate for issue X` means a commit is anchored but nobody approved it, and the refusal names
`lain epic submit implementation <slug> --issue X --digest <sha>`. `--digest` must be a commit in the repository; anything
else is refused. The implementation gate's question reports what the project's suite did on that commit (`tests: 3 passed,
1 error`, `tests: 4 passed`, or `tests: not run (why)`); a red result does not refuse the gate, the decision is yours.

### lain land

The merge coordinator's command line. A chat's workers queue through it on their own; you run it to
land a commit by hand, or to see where a queued one stands. One drainer lands a branch's queue at a
time, a batch of up to `batch_cap` entries per run of the suite named by `verify`, and the branch only
ever fast-forwards to a commit that run passed.

```bash
lain land enqueue                       # queue HEAD for the main worktree's branch, start a drainer
lain land enqueue abc123 --branch main --id export-stream
lain land wait export-stream-3f2a --timeout 600
lain land status
lain land drain                         # what the detached drainer runs; useful by hand if none started
```

| Command | What it does |
|---|---|
| `lain land enqueue [REF]` | Anchor REF (default `HEAD`) under `refs/lain/worker/`, queue it, and start a detached drainer. Prints the entry id and its place in the queue. `--branch` names the branch (default the main worktree's checked-out branch, which must not be detached); `--id` names the worker (default this checkout's directory name). |
| `lain land wait ID` | Block until the entry has a result. `--branch` names the queue it was put on; `--timeout` is in seconds. |
| `lain land status` | The pending entries, and whether a drainer holds the branch's drain lock and for how long. A holder line whose process is gone is reported as stale, not as a drainer. |
| `lain land drain` | Land every queued entry, a batch at a time, then exit. `--branch` and `--project` default as above. |

**`lain land wait` exit codes:**

| Exit | Meaning |
|---|---|
| `0` | The work is on the branch (or was already). |
| `1` | It did not land; the output names why. |
| `2` | The timeout passed and the entry is still queued. |
| `130` | Interrupted with Ctrl-C. The entry stays queued unless it landed meanwhile. |
| `64` | The id, repository or branch was refused: an id the queue never minted, a bare repository, a detached branch. |

A malformed command line, such as a missing id, is Thor's usage error and exits `1`.

**The coordinator's root is the repository's main worktree**, whichever linked worktree you run
from: its `.lain/config.rb`, its journal and its verify worktree are the main one's. A bare
repository is refused. `lain epic land` and the drainer share one verify worktree and take turns on
the branch's drain lock, so a landing waits rather than racing the other. A verify run takes the
suite lock, which is one lock per machine, so two repositories never run their suites at once.

### lain worktrees gc

Reap lain's worker checkouts, anchors and merged epic branches whose work is safe elsewhere. No
flags.

```bash
lain worktrees gc
```

A checkout is kept unless its work is provably somewhere else. A lease whose owning process is still
alive is live and kept; a checkout that is **dirty** is kept, re-locked as retained; and a lock whose
reason cannot be read means keep. Before anything is removed, the committed `HEAD` — plus a snapshot
of any dirty state — is anchored under `refs/lain/worker/*`, so a reaped tree still cannot cost a
commit. An `epic/<slug>` branch is deleted only once its tip has moved from its marker, is an
ancestor of `main`, and is checked out nowhere. How long a released checkout is kept is
[`isolation retain_days:`](#isolation).

Runs take a per-repository lock, so a second concurrent `gc` does nothing and says so.

**It also runs itself, once a day.** A `lain` launch spawns a detached `lain worktrees gc` when the
stamp under `$XDG_STATE_HOME/lain/gc/` is older than 24 hours, logging beside it. The stamp is
renewed only after a spawn succeeds, and two simultaneous launches start one run between them.

### lain review

Review a pull request or a branch. `lain review 4821` takes a pull request number,
`lain review feature/foo` a branch. It resolves the target, opens a round over the changeset,
and prints the round as **text** — no editor is involved. [`/review`](#review) is the same round
drawn in the cockpit.

```bash
lain review 4821
lain review feature/foo --scope by_directory
lain review feature/foo --base origin/main
lain review open help                        # a branch actually named `help`
```

`open` is a disambiguating verb, not a mode. Thor owns the first word, so a target named `help`
or `tree` would reach Thor's own command instead of the resolver; `lain review open help` is the
way through. Every target that does not collide works without it.

| Flag | Default | What it does |
|---|---|---|
| `--scope` | unset — the round opens at `cumulative` | `cumulative`, `commits`, or `by_directory`: which grouping the sidebar opens on. The enum is read off the registered partition strategies rather than written out in `exe/lain`, so a scope the registry serves cannot be refused before the registry is asked. |
| `--base` | unset | Override the base ref the changeset is cut against. |

An unresolvable target is refused by name, and names the repository it looked in:
`head ref "does-not-exist-xyz" does not resolve to a commit in <root>`.

### lain survey

Review a directory **as it stands** — no pull request, no branch, no diff. `lain survey ./docs`
walks the tree, opens a round over it, and prints the listing as text.
[`/survey`](#survey) is the same round drawn in the cockpit.

```bash
lain survey ./docs
lain survey ./lib --unbounded
lain survey open help                        # a directory actually named `help`
```

`open` is the same escape valve `lain review` carries, for the same reason.

| Flag | Default | What it does |
|---|---|---|
| `--scope` | unset — the round opens at `cumulative` | The same three registered strategies `lain review` offers. A corpus does not answer all of them — see below. |
| `--unbounded` | `false` | Present the whole tree however large it is. It lifts the corpus file ceiling below; the separate `/critique` packing ceiling still holds. |

**`--permissive` is not a flag of this command.** It chooses the rule a *verdict* is judged
under, and `lain survey` renders a tree and submits nothing; the in-session
[`/survey`](#survey) is where it lives. `lain survey ./docs --permissive` answers
`Unknown switches "--permissive"` — it names the switch you typed rather than reading the word
as a path or inventing a verb for it.

A tree outside the project is judged by the names below its own root, so `secrets/prod` is masked whole in the corpus, the
notes and the briefs, and the docent that answers questions about the survey works inside the surveyed tree: a read it makes
there meets the same name rule from that root.

Two refusals worth meeting on paper first.

**A scope the registry has but this source cannot answer** is refused in prose, and names the
ones that would have worked:

```
scope commits is not available for the corpus source -- it does not answer what that grouping
reads. cumulative, by_directory do present this one
```

A scope that is not registered at all never reaches the source: Thor validates the enum ahead of
dispatch and answers `Expected '--scope' to be one of cumulative, commits, by_directory; got by_size`.

**A tree over the file ceiling** is refused before a single file is read:

```
this corpus is 742 files, over the ceiling of 300 -- survey a subdirectory instead, or raise
the ceiling with --unbounded
```

The decision is made from a file count alone, when the corpus is built — **before any `--scope`
is applied**. So no scope lifts it: `--scope by_directory` groups the same file set and refuses
with the same sentence. The two remedies the refusal names are the only two there are.

### lain bench variance

Report determinism, divergence, and distribution across recorded sessions. Offline.

```bash
lain bench variance sessions/          # a directory
lain bench variance a.ndjson b.ndjson  # explicit files
```

### lain bench record

Record N live runs of a task file, one prompt per line. **Spends real API money.**

```bash
lain bench record tasks.txt --out runs/ --n 10 --provider ollama --temperature 0
```

`--out` is required. `--n` defaults to `Bench::CLI::RECORD_DEFAULTS[:runs]`. Also takes
`--model`, `--max-tokens`, `--system`, `--provider`, `--api-base`, `--temperature`, `--seed`.

### lain bench sweep

Deterministic 5-arm retrieval eval, recall@k over the gold corpus. Offline, no API.

`-k` / `--k` sets retrieval depth.

### lain bench plan-sweep

Shape x density sweep over a fixture plan's scripted runs. Offline, deterministic.

Both `--plan` (fixture plan markdown, P1 format) and `--runs` (scripted runs YAML) are required.

---

## Session commands

Typed at the `you>` prompt. Each one dispatches ahead of the skill middleware and costs no model
turn. `/help` lists the live registry, so it never drifts from what is actually registered.

### /help

List the registered commands and the loaded skills.

### /status

Cache warmth, fleet size, and inbox count for this session. Cache warmth has **three** answers,
not two: warm, cold, and a feed that has published no deadline at all, which is not a cache that
went cold.

**`fleet` here is a count, deliberately.** The fleet's shape — one row per child, nested under
the parent it was spawned from — is drawn in `lain://status` in the editor, and its top two rows
sit in the input pane's header under the HUD. A row names the child's role, whether it is
running, how many turns it has committed and the first line of its task; `lain://status` also
shows the child's age, which the pane's header leaves out so that the header does not change
once a second. Neither surface prints the spawn digest: that is the address
[`lain watch`](#lain-watch) takes, and it is seventy columns of what a human reading a fleet is
not looking for.

### /sessions

List recorded sessions, newest first. `/sessions --all` includes ephemeral `.btw` ones.

### /model

`/model` shows the model in force. `/model <id>` switches the next turn's model, mid-session.

### /mode

A mode is **scope × approval**, plus a set of layers. Its usage line:

```
/mode [scope] [approval] [+layer] [-layer] [!]
```

Bare `/mode` reports and changes nothing.

| Token | Axis | What it means |
|---|---|---|
| `checkout` | scope | Writes and commands land in the project's own checkout. |
| `plan` | scope | Writes and commands are confined to a **spike** — a worktree cut on `lain/plan/<key>` from the checkout's tracked state, or a scratch directory outside a git repository. |
| `ask` | approval | A gated call parks for a surface to answer. |
| `auto` | approval | A gated call is approved at the ladder's last rung. |
| `+layer` / `-layer` | layers | Enable or disable one of `auto_approve`, `goal`, `notify`, `vi`. |
| `!` | — | Reset: `ask` approval, no layers, and then `plan` scope. |

Tokens **fold over one mode and switch once**, so `/mode auto +notify -goal` journals a single
flip naming where the session started and where it ended. An axis holds one value, so two tokens
naming the same axis refuse whole and name both — taking the last would hand a typo the gate.

`auto` is not a different gate, only a different last rung: the triage and the rule denies run
first either way, so a protected path still refuses under `auto`. The `auto_approve` **layer** is
a separate thing entirely — it leaves the ladder in place and adds a model judge at its end.

`plan` scope is confinement, not a sandbox. It checks the location a tool **names** —
`write_file`/`edit_file`'s path, `bash`'s `cwd` — and refuses anything outside the spike by name,
pointing at `/mode checkout`. A human-approved shell command's own words can still write
elsewhere. Leaving `plan` keeps the spike's branch if it carries commits and deletes it if it
does not, saying which.

A **scope** move is refused while a turn is in flight, since a running tool call may be writing
where the session's writes would stop landing: wait, or `/stop`. `/mode !` is the exception — it
lands everything but the scope immediately, because dropping `auto` is the part that cannot
wait, and says the scope move waits for the turn to end.

`manual` and `accept_edits` are retired, and are refused by name rather than as typos: approval
is `ask` or `auto`, and `ask` gates everything `manual` gated.

### /stop

`/stop` stops the ask in flight and **keeps the session**. The run's task is interrupted, a
`run_interrupted` record is written with reason `stopped`, no `session_closed` is written, and
the prompt comes back as `you>` in the same conversation.

It is answered by the input rail rather than by the command registry whenever an ask is actually
running, so it works from a prompt a run is waiting on — a `[y/N]` or a `human>` — and not only
from `you>`. With nothing running there is nothing to intercept and the command answers instead:
*"no ask is running -- /stop at the prompt it parks on, or s at a countdown"*.

The countdown's `s` key is the same gesture: Ctrl-C opens the grace window, and `s` there stops
the ask while `c` cancels the countdown, `w` extends it and `r` waits for responses. An idle
`you>` countdown offers only `c` and `w`, since there is no ask to stop.

**Every stopped ask says why.** The reason recorded on `run_interrupted` is one of `stopped`,
`ceiling`, `over_window`, `transport`, `stalled_stream` and `torn` (plus `interrupted` and
`grace_expired`, which come from Ctrl-C and the shutdown window rather than from an ask).

### /rewind

`/rewind` moves the session back one turn. `/rewind N` moves back N. `/rewind <digest>` moves to a
recorded turn. The Timeline is content-addressed, so nothing is destroyed and the old head stays
reachable.

**A prompt left unanswered at the head goes out again with your next one.** A failure after the
request reached the provider, a Ctrl-C or [`/stop`](#stop), a failed resend, or a `/rewind` that
lands on a prompt all leave a prompt with no answer on the chain. The next thing you ask is sent
as **one** turn carrying both texts, cut from that prompt's parent — never as a second prompt
stacked beside the first — and the chat says so before the wire:

> the prompt at the head has no answer on this chain, so this ask carries it too -- /rewind 1
> before asking to leave it out

So `/rewind 1` is the escape, and it is named in the warning rather than left to be remembered.

A prompt that provably never reached the provider is **withdrawn** instead, so it does not come
back. Exactly two shapes qualify: every connection refused before the request was sent, and a
prompt the provider refused whole for not fitting its context. Anything else is kept.

### /undo

`/undo` puts back the files the last file-changing turn wrote. `/undo skip` drops that turn without
restoring anything, so the next `/undo` reaches the turn before it. Run it again to walk further
back.

**It reverts that one turn's own paths, and nothing else.** A snapshot is a delta rather than a
picture of the whole tree, so undo restores each path the turn added, changed or deleted, and never
touches a path the turn did not name. The conversation is untouched — [`/rewind`](#rewind) is what
moves that.

What it will not do, always refusing by name and before anything moves:

| It refuses when | Because |
|---|---|
| a turn is still in flight, or a supervised worker is still running | a parked tool call could write after the files were put back |
| a path changed since that turn | your later edit is not undo's to discard |
| a path was first written in that turn under the write-set scope | nothing recorded what it held before |
| a path is a symlink, is `.gitignore`'d, sits outside the project root, or is inside a nested repository | undo neither follows nor restores those |

A refusal changes nothing at all and names every path it choked on, so the remedies are to put those
back by hand and `/undo` again, or to `/undo skip` that turn entirely.

**Scope decides how much was recorded.** Under the shadow-git scope a turn's change is the whole
tree diff, so a file a `bash` command wrote is restored like any other. Under the write-set scope
only lain's own tools are recorded, and the reply says so: *"Only files lain's own tools wrote were
restored: that turn ran under the write-set scope, which records nothing a shell did."*

### /pin

`/pin` marks a turn so compaction may not elide it. Bare `/pin` takes the last assistant turn;
`/pin <digest>` takes the turn a digest prefix names, resolved against this session's chain.

Unlike `/rewind`, `/pin` takes **no turn count** — its argument names a turn, it does not measure a
distance. A prefix must be at least four characters, so a count-shaped `/pin 3` is refused rather
than silently resolving against whichever digest happens to start with `3`.

Pins live on the session and are journalled, so they survive `--resume`.

### /unpin

`/unpin` releases a pin, taking the same argument grammar `/pin` does. A turn that was not pinned
says so rather than reporting a release.

### /fork

Fork this session at its head into a new tmux window: a durable sibling chat over the shared
store. O(1), because a Timeline is a `(head_digest, store)` pair.

### /btw

`/btw <question>` asks an ephemeral side-question in a tmux popup. It is journalled and then
reaped on clean exit, unless you [`/keep`](#keep) it from inside.

### /keep

Promote this ephemeral (`--btw`) session into a durable one. Run it inside the `/btw` popup.

### /inbox

List and answer pending human questions. Same drain as the `human>` prompt.

A question arrives as a **set** — one `ask_human` call carrying one question or several, each
with a markdown body, a closed list of options, and how many of them you may pick. Every row is
attributed to the agent that asked it, so a subagent's question is answerable without knowing
which agent is stuck.

`/inbox` lists every pending row, then prints the document of the set it is about to answer and
reads one reply. **A typed reply answers the whole set in prose**, not option by option: the
model is told the human answered in prose rather than by selection, and your words are
blockquoted so nothing you type can be read as a choice. That is the terminal's only gesture,
and it stays available whether or not an editor is attached.

Ticking boxes is the editor's. With `--nvim`, `<CR>` on an inbox row opens the set in
`lain://question` as a folded markdown document: `x` ticks the option under the cursor, two-space
indented prose beneath an option says why, and `:w` submits the whole document and opens the next
set you have not answered. See `:help lain-question`.

### /approve

Answer each pending tool approval `y/N`.

**A `[y/N]` takes only a verdict.** At a plain-chat prompt (and the input pane's) the accepted answers are `y`, `yes`,
`n`, `no`, `nope` and `nah`, in any case and with trailing punctuation (`yes!`), an empty line (a no), and `n <reason>`,
`no, <reason>` or `n: <reason>`, which denies and hands the reason to the model. Anything else, including a `/command`
and a pasted block of several lines whatever its first line says, leaves the approval open and is held as your next
prompt, with one line saying `a y or n answers the approval`. A prompt that lapses on its clock tells the model so
(`approval denied for tool "bash": denied after 5:00 with no answer`), where a human's `n` gives the bare sentence.

### /survey

`/survey <path>` opens a survey of a directory in the editor this chat is **already** attached
to — the round [`lain survey`](#lain-survey) prints as text, drawn in the cockpit with this
chat's gesture rails bound to it. Its usage line:

```
/survey <path> [--scope cumulative|commits|by_directory] [--unbounded] [--permissive]
```

The scope names in that line are filled in from the registered partition strategies, so the
usage enumerates whatever is registered rather than restating a list that could drift from it.

It reads three flags: the two `lain survey` has, plus `--permissive`, which the one-shot has no
use for. `--permissive` chooses the rule a **verdict** is judged under — it forgives rows nobody
read and still refuses an objection nobody answered — and only the cockpit submits a verdict.
Anything else beginning with `--` is refused by name rather than read as a path, and a declared
flag whose value is missing gets its own refusal, because the remedy is the opposite one.

Without an editor it **refuses** rather than drawing into nothing: a survey nothing drew and no
gesture could reach is the failure the review surface was written against. The refusal names
`lain up --nvim` (or `lain chat --nvim <socket>`) as the way to get one, and `lain survey <path>`
as the way to read one without.

**A survey opens two windows: `sidebar | file`.** There is no diff pair — a corpus has no base
revision, so there is nothing to put on an old side. A changeset review opens three,
`sidebar | old | new`. The `old` slot stays in the layout's vocabulary either way, and a survey
opens it **on demand**, which is what keeps `:LainThread` working there.

The banner lain prints on opening teaches the motion for the round it actually drew: **one**
`<C-w>l` from the sidebar to the file on a survey, two on a changeset review.

One chat draws one review at a time. A `/survey` over an open changeset review is refused,
naming the one already open; a `/survey` over an open **survey** rebinds, which is how you take
a second look at a tree.

There is no `/survey-submit` — a corpus has no pull request under it. A drawn survey is held all
the same, so [`/review-submit`](#review-submit) names the survey rather than claiming nothing is
open.

### /review

`/review <pull-request|branch>` opens a changeset review in the attached editor. Its usage line:

```
/review <pull-request|branch> [--base <ref>] [--scope cumulative|commits|by_directory] [--permissive]
/review close
```

Same editor rule as `/survey`: no editor is a refusal, not a Null surface. Same one-surface rule
too, from the other side.

**`/review close` lets the open round go without a verdict.** It takes nothing after it —
`/review close --base main` is either a typo or a review of a branch called `close`, and
guessing would do one of them wrongly — so it refuses and says that a branch named `close` is
reviewed as `refs/heads/close`. In a repository that really has such a branch, that hint is
printed beside whatever the close answers. A round that already carries a verdict refuses, and
so does one already closed. The close journals a `changeset_closed` record naming who closed it,
`human` or `refusal`.

The `refusal` half is the other half of the same gesture: a round bound and then refused — a
ceiling refusal, say — is closed on the way out, so **a refused round binds nothing**. The rails
unbind, the outbox is released, and the refusal is what you are told, instead of both surfaces
staying bound over a round nobody will ever see. `:LainReviewClose` is the editor's spelling of
the same command.

`--permissive` is here so the partial-review refusal stays honest from a `/review` round as well
as a `/survey` one. Submitting `approve` over a changeset that is not fully reviewed is refused
by naming the rows that are outstanding — the first few, then a count of the rest — and offering
two remedies: mark each row reviewed with `x` in `lain://review`, or re-open the review with
`--permissive` if this run means to judge regardless. A command that could not read the flag
would be naming a remedy unreachable from the very review that refused.

### /review-submit

`/review-submit [summary]` posts the open changeset review to its pull request, **once**.

There is no retry, and that is structural rather than shy: an accepted POST creates a review
every time, so GitHub refusing comes back as a refusal that is raised loudly and nothing here
tries again. A review that did not land must not read like a line of success.

A survey has nowhere to post. That is a modelled outcome rather than an error — a perfectly good
review with nowhere to post — so this command names the survey instead of claiming nothing is
open.

### /goal

`/goal <objective>` drives the agent toward a standing goal until it signals done. `/goal off`
clears it.

### /implement-epic

`/implement-epic` works the mounted epic's approved issues to its working branch. Each issue runs as
its own actor in a worktree cut from `epic/<slug>`, rebases itself, and lands serially through one
queue; the issue graph and the live fleet are drawn in [`lain://status`](../README.md#the-cockpit),
the fleet as a tree with each issue's own children nested under it.

```
/implement-epic [--width N]
```

`--width` is the only flag, and it takes a whole number above zero: how many issues may be in flight
at once. It defaults to 2. Anything else is refused by name.

The epic comes from `lain chat --epic SLUG`, not from an argument here. Two properties worth knowing
before an unattended run:

- **It stops between issues when the session is closing.** The loop asks the conductor whether it is
  closed before each issue and while waiting on a gate, so a Ctrl-C stops the run at the next
  boundary instead of mid-merge. Work already in flight is reported as unsettled rather than
  abandoned silently.
- **It is not bounded by a model-turn ceiling.** `/implement-epic` never enters an agent `ask`, so
  neither [`/goal`](#goal)'s 5-iteration cap nor an agent's own 25-iteration tool-loop ceiling
  applies to it. Its bound is issues, and by default there is no issue budget at all — it runs until
  the epic is done, it is interrupted, or an issue stops it.

A refusal stops **that issue**, never the whole run.

### /ruby

Inspect live state. Bare opens a console, an expression prints its `inspect`, a path reads a file.

### /meta

`/meta <prompt>` generates a customized harness script into `.lain/meta/`. Review it, then
`/meta run <slug>`.

`/meta summarizer <prompt>` generates a summarizer declaration into `.lain/summarizers/`.
**Nothing loads that directory** — the catalog loads the single file `.lain/summarizers.rb`,
so review the generated file and copy the declaration into it yourself. A summarizer is loaded,
never launched: there is no run verb for it, and `/meta run` cannot reach one.

### /quit

End the session. Same as a bare `quit`.

---

## Configuration (config.rb)

`.lain/config.rb` is Ruby, evaluated once per launch, with 8 verbs: `epics`, `approval`,
`isolation`, `sensitivity`, `shell`, `search`, `tests` and `middleware`. Each verb may appear once, and every
one is optional. Each is read by its own **strict** reader: an unknown key is refused by name,
listing the keys that do exist, because a restricting table has to refuse a typo loudly rather than
silently leave the restriction off.

The file runs only after [`lain trust`](#lain-trust) has recorded its bytes. A file that exists and
is untrusted, or that will not load (a Ruby error, an unknown verb, a refused value), refuses every
launch before anything starts, naming `.lain/config.rb:LINE`. A project with no `.lain/config.rb`
is never refused: every table is then at its default.

```ruby
epics home: :repo, width: 3 do
  gate :research, :hands_off
end
approval timeout: 900 do
  allow "bash", command: "bundle exec rspec"
  deny_tool "web_fetch"
end
isolation retain_days: 14
sensitivity gated: %w[secrets.yml], related: %w[~/notes]
shell exclude: %w[curl]
search include: %w[planning/notes/*.md], max_entries: 50_000, max_bytes: 100_000_000
tests preset: :rspec
```

* `epics`: `home:` (`:xdg` by default, or `:repo` to keep epics under `.lain/epics/`), `width:`, and
  one `gate stage, policy` line per stage in the block.
* `approval`: `allow "tool", field: value` and `deny "tool", field: value` match one tool call by
  input; `deny_tool "tool"` refuses a whole tool and takes no fields. `timeout:` is how many
  seconds a parked call waits for an answer before it is denied (300 by default); it must be a
  finite number above 0, and the prompt, `lain://approval` and the chat show the time left.
* `isolation`, `tests`: documented below.
* `sensitivity`: `denied:`, `gated:` and `exempt:`, each a list of path globs, and `related:`, a
  list of directories (each starting with `~/` or `/`, and each must exist). A read under a related
  directory masks its flagged regions without asking and never releases them ; a file the path
  rules gate or deny is still gated or denied. The verb refuses `/`, your home directory and any
  ancestor of it, an entry that is not a directory, and a path that is not clean.
  Round 23: a spawned child's read of a path outside the project root, outside every `related` directory and outside its own working root is gated as `outside_project` (the tools: `read_file`, `list_files`, `glob` (its walk root too), `grep`, `ast_search`, `file_symbols`). Under `ask` it parks for the human. With the `auto_approve` layer the model judge or the human answers, whichever comes first. Under `/mode auto` it is approved like any gated call. A child that can never park (an approval judge, the epic adjudicator) is refused. The main agent's reads are unchanged. Known gaps, by ruling: a `grep` over the project follows a file link that points outside without parking, and in a chat with no project marker the root is the cwd, so a chat started in $HOME confines its children to all of $HOME.
  Detected secret regions are masked in what `read_file`, `grep` and `ast_search` return: a `grep` or `ast_search` row
  reads `<redacted:N>` in place with nothing parked, and a trailer says `read_file` on the file asks for their release.
  A secret path is withheld from those rows, not masked.
  A name names a secret when it holds `pass`, `passwd`, `passcode`, `token`, `private` or `auth` as its own word
  (`vault-pass.txt`, `dbToken.txt`), `api key` or `api_keys`, or ends in `secret`, `password`, `credential` or `apikey`
  (`mysecrets.txt`); `AUTHORS` and `tokenizer.json` are ordinary, and source and markdown files are excepted by extension.
  `dbPasswordFile.txt` is a known miss and `libsecret` a known catch; a bare `pass` also gates compiler-pass files such as `*_pass.mlir` and `hlo/pass/`, by ruling. A directory named so counts below the project root,
  below a checkout, and below the root of a `lain survey` of a tree outside the project.
* `shell`: `exclude:`, a list of program names or globs the shell tool refuses. `exclude: %w[*]` is
  the strictest setting.
* `search`: how `grep`, `glob`, `list_files` and `ast_search` walk the project. Searches list files
  the way `git ls-files --exclude-standard` does, so they skip what git's ignore rules exclude.
  `include:` is a list of globs, relative to the repository top, that name ignored files a search
  should still read; a glob that leaves the project is refused. `max_entries:` (20,000 by default)
  caps the files one walk lists and `max_bytes:` (200 MiB by default) the bytes it reads; both are
  positive integers, and a search that hits one says it was cut short.
* `middleware`: documented [below](#middleware).

### middleware

Your own code, run around what lain already does. The `middleware` verb takes one line per
registration, and the area (`model`, `tool`, `turn`, `repl` or `http`) is the verb of that line.

```ruby
class TagRequests < Lain::Middleware::Base
  def initialize(tag:) = (@tag = tag)
  def call(env, &app) = downstream(env.merge(tag: @tag), &app)
end

class CountTurns < Lain::Middleware::Base
  def call(env, &app) = downstream(env, &app)
end

class AddHeader < Faraday::Middleware
  def initialize(app, name, value)
    super(app)
    @name = name
    @value = value
  end

  def call(env)
    env.request_headers[@name] = @value
    @app.call(env)
  end
end

middleware do
  model TagRequests, tag: "home"
  tool { |env, &downstream| downstream.call(env) }
  turn CountTurns
  repl { |env, &downstream| downstream.call(env) }
  http AddHeader, "x-mine", "yes"
end
```

Write `Lain::Middleware::Base` in full: the file is evaluated as a string, so a bare
`Middleware::Base` does not resolve. A class defined in the file belongs to that evaluation, and a
block becomes a middleware of its own (`Lain::Middleware::Inline`).

| Area | Runs around | `env` in | Pass on, and set |
|---|---|---|---|
| `model` | each provider call | `:request`, `:stands_on` | `:response` |
| `tool` | each tool call | `:effect`, `:context`, `:tool` | `:result` |
| `turn` | each pass of the agent loop | `:iteration`, `:timeline` | `:response`, `:settled` |
| `repl` | each line a human types | `:text`, `:agent` | `:response` |
| `http` | each HTTP attempt | a Faraday request env | the Faraday response |

`env` is read-only: `env.merge(key: value)` returns a new one, and an absent key raises
`KeyError`. A middleware that answers without calling downstream must still set the key its phase
reads on the way out, or the phase raises. A `turn` class must also answer `#settle(timeline)`,
which every turn sends as it commits; `Lain::Middleware::Base` answers it with nothing to do, and
a class that does not is refused when the file loads.

**Order.** Configured middleware runs outermost in every phase: your user-level file first, then
the project's, each in the order written, ahead of every member lain builds. In the `tool` phase
each of lain's guards therefore judges whatever your middleware passes on, and on the way back your
middleware sees a result after `RedactSecretReads` has masked it. The approval gate stays last, so
nothing you write can sit between a judged call and its interpreter. In `http`, entries sit after
stall protection and before JSON encoding, so each retry attempt passes through them and they see
the body as a Hash.

**Instances.** A `model`, `tool`, `turn` or `repl` registration is a recipe: lain builds a new
instance each time it builds a stack, so two agents never share one. Its arguments are frozen
when the file loads, and a value that cannot be frozen is refused. `http` is the exception.
Faraday builds an `http` middleware once per provider connection, and subagents use their
parent's provider, so **one instance serves the parent and every child at the same time. It must
be thread-safe.** An `http` entry is a class, never a block, and faraday-retry hands the same body
object to each attempt, so an edit made in place repeats on every retry.

**Refusals.** A registration that is not a class (or a block), a class with no instance `#call`, a
`turn` class with no `#settle`, an `http` block, an unknown area, and a constructor that rejects
its arguments are each refused naming `config.rb:LINE` of the line that registered it.

**Scope.** `lain chat` and `lain up` read the middleware once, before the session opens, and apply
it to the chat and to every subagent it spawns. `lain bench`, `lain consolidate`, `lain improve`
and `lain epic submit` read none, so a bench arm does not change with the home directory.

**The user-level file.** `$XDG_CONFIG_HOME/lain/config.rb` (by default `~/.config/lain/config.rb`)
accepts only the `middleware` verb and applies to every project. It runs only after
`lain trust --user`, which shows the file and records its exact bytes. Trust is consent to bytes
someone reviewed: it is not containment, and an agent that can write the file can also write the
mark, as it can for a project today. Any changed byte asks again.

### isolation

How a worker's checkout is kept, brought current, and merged. Every key has a default, so the
table is optional and an absent one behaves exactly like the defaults below.

| Key | Default | What it does |
|---|---|---|
| `retain_days` | `7` | Days a released worktree is kept before [`lain worktrees gc`](#lain-worktrees-gc) may reap it. A whole number of days, at least 1. |
| `rebase_retries` | `1` | How many times a worker retries its self-rebase before handing back. At least 0 — and `0` is how a project turns worker self-sync off entirely. |
| `diff_algorithm` | `histogram` | `histogram`, `patience`, `minimal`, or `myers`. Reaches git as `-X diff-algorithm=<value>`. |
| `conflict_style` | `zdiff3` | `zdiff3`, `diff3`, or `merge`. Reaches git as `-c merge.conflictStyle=<value>`. |
| `verifier` | `command` | The strategy that judges a landing batch. Only `command` exists. |
| `verify` | `[]` | Argv for the full suite, as a list of non-empty strings. `[]` skips verification. |
| `verify_timeout` | `1800` | Seconds the full suite may run. A whole number, at least 1. |
| `verify_keep` | `["target/"]` | Relative paths the scratch worktree reset keeps. |
| `batch_cap` | `8` | Most queued entries landed in one batch. At least 1. |
| `rebuild_cap` | `3` | Times a batch is rebuilt after the branch tip moves. At least 0. |
| `check` | `[]` | Argv for the fast-tier test command; changed and mirror test paths are appended. |
| `lint` | `[]` | Argv for the fast-tier lint command; changed files are appended. |
| `lint_files` | `[]` | Globs a changed file must match to be handed to `lint`. `[]` hands it every changed file. |
| `check_retries` | `1` | Times a worker is asked to fix a failed fast-tier check. At least 0. |

Both merge knobs ride **lain's own command line**, never your `git config`: a worker's merge should
not depend on the machine it ran on, and it must not rewrite a setting the human chose for their own
checkout. `rerere.enabled=false` is pinned on the same line for the same reason.

```ruby
isolation retain_days: 14, rebase_retries: 3
```

Landing through the coordinator adds a verify command and a batch size:

```ruby
isolation verify: ["bundle", "exec", "rake", "spec"], batch_cap: 4, verify_timeout: 900,
          check: ["bundle", "exec", "rspec"], lint: ["bundle", "exec", "rubocop"], lint_files: ["**/*.rb"]
```

A bad value is refused at `.lain/config.rb:LINE`, naming the key and what would have been legal:
`retain_days: 0 is not a whole number of days, at least 1`.

### tests

A target project's test layout: where its source lives, where each level of test goes, and what is
exempt. This is what holds lain's own writes — and its subagents' — to the layout a project already
keeps.

**Enforcement is opt-in.** A project with **no `tests` verb is refused nothing**: the layout
resolves to `TestLayout::None`, no write is ever refused for its path, and the session journals a
single `test_layout_absent` record to say the guard ran with nothing to enforce. Nothing is
auto-detected on your behalf, deliberately — a detected preset would impose level roots on a project
that never chose them and start refusing its existing flat specs as strays.

| Key | Default | What it does |
|---|---|---|
| `preset` | none — **required** once the table exists | `rspec`, `minitest`, `pytest`, or `cargo`. Sets every key below, and names the test-file shape (`_spec.rb`, `_test.rb`, a `test_` prefix, `.rs`). |
| `source_roots` | the preset's — `lib` under `rspec` | The roots a test mirrors. Non-empty, relative, and non-overlapping. |
| `level_roots` | the preset's — `spec/unit`, `spec/seam`, `spec/integration` under `rspec` | Level name to its root. A level name is lowercase; roots may not nest. `cargo` maps `unit` to `inline`, which only a preset that does not mirror may use. |
| `exempt` | the preset's, which is always empty | Globs no refusal applies to. A preset exempts nothing by design — an exemption is a project's own decision to state. |
| `default_level` | unset — `unit` wherever the table declares that level, or the only level that mirrors | Where a test that names no level belongs: what the guard holds an untagged test to, and where `/implement-epic` writes an issue's failing tests. Must name a level the table declares. Required only when the table mirrors two or more levels and none is `unit`, which is otherwise refused rather than settled by whichever key was typed first. |

```ruby
tests preset: :rspec, source_roots: %w[lib app], exempt: %w[spec/fixtures/**]
```

Omitted keys inherit the preset's, so the table above changes the source roots and the exemptions
and keeps `rspec`'s level roots. A `tests` verb naming no `preset` is refused, listing the four.
