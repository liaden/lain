# Commands

Two command surfaces. `lain <subcommand>` runs from your shell. `/<name>` runs from the `you>`
prompt inside a live session, lib-side, with zero model turns.

Every flag listed here is also in `lain help <subcommand>`, which reads the same Thor
declarations in `exe/lain`.

`lain <subcommand> --help` prints the same screen. A `--help` written after a command name is
routed to `help`, so `lain chat --help`, `lain up --help` and `lain sessions --help` print that
command's usage. Every other unknown switch is refused by name (`lain sessions --bogus`
answers `Unknown switches "--bogus"`), so a mistyped flag is never read as a positional argument.

Contents:

- Shell commands: [lain chat](#lain-chat), [lain up](#lain-up), [lain remote](#lain-remote),
  [lain input](#lain-input), [lain sessions](#lain-sessions), [lain watch](#lain-watch),
  [lain export](#lain-export), [lain trust](#lain-trust), [lain gateway](#lain-gateway),
  [lain consolidate](#lain-consolidate), [lain improve](#lain-improve),
  [lain improvements](#lain-improvements), [lain epic](#lain-epic), [lain land](#lain-land),
  [lain todos](#lain-todos), [lain queue](#lain-queue), [lain worktrees gc](#lain-worktrees-gc),
  [lain daemon](#lain-daemon), [lain herdr](#lain-herdr)
- Session commands: [/help](#help), [/status](#status), [/sessions](#sessions), [/model](#model),
  [/mode](#mode), [/stop](#stop), [/rewind](#rewind), [/undo](#undo), [/pin](#pin),
  [/unpin](#unpin), [/label](#label), [/park](#park), [/fork](#fork), [/btw](#btw),
  [/keep](#keep), [/inbox](#inbox), [/approve](#approve), [/deny](#deny), [/held](#held),
  [/clear](#clear), [/resume](#resume), [/release](#release), [/share](#share),
  [/survey](#survey), [/review](#review), [/review-submit](#review-submit), [/goal](#goal),
  [/implement-epic](#implement-epic), [/ruby](#ruby), [/meta](#meta), [/quit](#quit)

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
| `--api-base` | Ollama's localhost | Overrides the Ollama base URL, for whichever of the chat and the summarizer is on Ollama (see [Compaction](#compaction-flags)). |
| `--round-budget` | `window` | What one tool round's results may cost together. `window` holds them to the context window left after the turn that made the calls, its reply and the reserve for the next reply; `static` to a fixed byte cap of 2 results' worth; `off` sets no round limit. The session header records it, and a resume runs under the recorded arm and says so when it is weaker than a fresh chat's. |
| `--round-dedup` | `on` | Answers a repeated tool result by naming the first call that returned it, whatever the round budget. `off` delivers repeats whole. With `--round-budget off` and this `off`, a round is unbounded. The session header records it. |
| `--max-tokens` | the model's own | Per model turn. Unset, the ceiling comes from the model; a typed value overrides it and survives a resume. See [Token ceiling](#token-ceiling). |
| `--secret-oracle` | `off` | `off`, `local` or `cloud`: a model that answers parked reads of gated paths, never shown the contents. `cloud` needs `--gateway`. See [Secret oracle, gateway and egress](#secret-oracle-gateway-and-egress). |
| `--secret-oracle-model NAME` | `qwen3:4b` for `local`; none for `cloud` | The secret oracle's model. Required with `--secret-oracle cloud`. The local tier refuses a cloud model name, in any case. |
| `--gateway URL` | unset | The `http://127.0.0.1:<port>` URL that [`lain gateway`](#lain-gateway) printed, with no token. Required with `--secret-oracle cloud`. See [Secret oracle, gateway and egress](#secret-oracle-gateway-and-egress). |
| `--supervise-egress` | `off` | `off`, `oracle` or `all`: park outbound model requests for you. `all` parks every one, `oracle` only the secret oracle's. See [Secret oracle, gateway and egress](#secret-oracle-gateway-and-egress). |
| `--context-pipeline` | unset | `default`, `reminder`, `cache-breakpoints`, `prune`, `dedupe-tool-calls`, `purge-failed-inputs`, or several joined by `+` and applied left to right. Which combinators render every request. A word replaces the default: `prune` alone sends no reminders and no cache breakpoints; `prune+default` keeps both. Unset renders the default and writes no `context_pipeline` key into the session header; a named pipeline, `default` included, is recorded. An unknown, empty or repeated part is refused at launch. |
| `--temperature`, `--seed` | unset | Ride `Request#extra`. Ollama honors both; `--temperature 0` is the determinism recipe. |
| `--approval` | `auto` | `ask`, `auto` or `bypass`: who decides a gated call the rules left open. `ask` parks it for you, `auto` asks a model judge first and parks only what it is unsure of, `bypass` approves it. See [/mode](#mode) for what each does and what none of them guarantee. |
| `--journal` / `--no-journal` | on | The durable, fsync'd, replayable session record. `--no-journal` also disables `--windows`. |
| `--resume [SESSION]` | off | Bare picks the newest; or give a filename or prefix under this project's session dir. A typed `--max-tokens`, the compaction flags and the experiment arms of the recorded session carry over unless you type them again. A salvaged crash rebuilds the prompt it lost as a user turn and puts the recovered answer after it. |
| `--fork SESSION@DIGEST` | off | Fork a recorded session at a digest prefix. The parent opens read-only. |
| `--btw` | off | Ephemeral session (`<ts>-<pid>.btw.ndjson`), reaped on clean exit unless promoted with [`/keep`](#keep). |
| `--prompt` | unset | Seed the first question, then read the terminal as usual. |
| `--non-interactive` | off | Run `--prompt`'s question and stop, reading nothing from the terminal. Needs `--prompt`. A gated call is decided without a human; see [Non-interactive runs](#non-interactive-runs). |
| `--nvim SOCKET` | off | Attach a Neovim frontend to an `nvim --listen` socket. |
| `--human remote` | unset | With `--non-interactive`: a gated call the judge leaves open parks for the phone instead of being refused, and `ask_human` waits for the phone's answer. Refused at launch without `--non-interactive`, without `remote relay:` in the user config, when the daemon's relay is not `running`, or when bash is not confined by a sandbox. A bash call you approve from the phone runs traced, as a terminal approval does. See [docs/users/remote.md](remote.md). |
| `--input socket:NAME` | off | Read the human from a [`lain input`](#lain-input) pane instead of from this terminal. `NAME` is a name, not a path: the socket is derived from it under this project. Bare `socket:` means `chat`; `lain up` passes the tmux session's name, so 2 cockpits on one project do not collide. |
| `--windows` | off | Open a tmux window running [`lain watch`](#lain-watch) per subagent spawn. Needs `$TMUX` and a journal. |
| `--isolation` | `none` | `none` or `worktree`. Which backend actor-mode subagents lease workers from. Inert in plain chat; see [Isolation](#isolation-flag). |
| `--epic SLUG` | the sole epic in the home | Mount an epic: its documents become reviewable, [`/implement-epic`](#implement-epic) has something to work, and `lain://status` draws its graph. A home holding several epics with no slug here starts anyway, with a notice. |
| `--grace` | `60` | Seconds a first Ctrl-C or SIGTERM grants a run before it is stopped. See [Interrupt grace](#interrupt-grace). |
| `--max-cost DOLLARS` | off | Stop the run once its priced turns, children included, have cost this many dollars. A model with no price counts nothing against it, and the launch says so once. |
| `--root PATH` | detected | Treat `PATH` as this run's project root instead of walking up from the working directory. An explicit root is intent, so it skips the walk's refusal set. The session is filed under the root's key, wherever you launched from, so `lain sessions` and `--resume` run inside the root find it. |
| `--cwd PATH` | the root | Run as if the working directory were `PATH`. Must lie under the root, and defaults to it, so `--root PATH` alone opens that project whatever directory the shell is in. |

#### Token ceiling

`--max-tokens` caps one model turn. Unset, the ceiling comes from the model: Anthropic's table
(128,000 for Opus 4.6 and later), the window an ollama server says it serves, else 32,768. A typed
value overrides it, and the session header records which (`max_tokens_source`).

A typed `--max-tokens` survives a resume. `--resume` and `--fork`, and the `/btw` fork, send the
recorded value when you type none. A different value typed on the resume prints
`recorded with --max-tokens N; continuing with M (the current flags win)` and wins. Only a typed
ceiling is inherited; a per-model one is worked out again for the resumed chat.

The flag caps the reply and reserves nothing, so a reply under it is unchanged. A thinking model's
reasoning counts against it, so a turn cut at the cap prints `model hit max_tokens before finishing`
and then `raise --max-tokens (now N); a thinking model's reasoning counts against it`.

On Ollama every request sends `shift: false` beside `truncate: false`, so a reply that fills the
context window is cut rather than shifted, and the line names the window instead:
`the reply filled the context window; raise LAIN_NUM_CTX or start a shorter chat`.

#### Secret oracle, gateway and egress

`--secret-oracle` lets a model answer a read of a gated path that is parked for approval. The model
is shown the path and region count, never the contents. Either tier carries the egress guard.

- `local` asks the local ollama, never a remote provider, whatever `--provider` says.
- `cloud` asks a hosted model only through a [`lain gateway`](#lain-gateway) named by `--gateway`.
  Before every question the gateway must answer a fresh nonce with its HMAC under the token it left
  in its token file (the token itself is never sent), and name the path the model is asked at
  (`/api/chat` for a `:cloud` or `-cloud` tag, `/v1/messages` otherwise). The human at the gateway
  sees every request before it leaves. A failed proof stops the launch, and later puts a notice on
  screen and leaves the read for you.

What the oracle may decide:

- An oracle approve is applied only when the path is gated for where it is (ordinary, exempt,
  `out_of_scope`, `outside_project`). It is checked when the surface claims the pending and again
  when it settles. The local qwen3:4b oracle was measured approving `.env` at 0.8 to 1.0
  confidence, which is why the approve is checked this way.
- A deny is always applied.
- The oracle never releases a region a named pattern flagged (any detector but entropy). Its
  confident approve of one is journaled as an `approval_surface_deferred` record, and the read waits
  for a human.
- `.env`, keys, named, configured, protected and malformed paths always wait for a human.

Known gaps: a link repointed before the surface first claims the pending, and the oracle is never
offered an `outside_project` park.

`--gateway URL` is the URL `lain gateway` printed, `http://127.0.0.1:<port>`, with no token. The
chat reads the gateway's token from `$XDG_STATE_HOME/lain/gateway/<port>.token`, which the gateway
writes at mode 0600 on start and removes when it stops. A missing file, one other users may read,
one another user owns, or a symlink is refused, naming the path. A URL that still carries `?token=`
is refused, so the token never lands on a command line. Only `127.0.0.1` is accepted, the one
address the gateway binds.

`--supervise-egress` parks outbound model requests for you, showing who sends it, the endpoint,
size and digest, never the body. `all` parks every request and `oracle` only the secret oracle's.
Not held: the local ollama server's model metadata probe at launch, and the secret oracle's gateway
identity probe, which carries only a nonce. With nobody attached a held request is refused.

#### Non-interactive runs

`--non-interactive` runs the `--prompt` question and stops, reading nothing from the terminal. A
gated call has no human to park for:

- Under the default `auto`, the judge decides it, and a call the judge is unsure of is refused.
- Under `ask`, every gated call is refused.
- Under `bypass`, it is approved.

To make a run refuse everything the rules leave open, pass `--approval ask`.

#### Interrupt grace

`--grace` is the number of seconds a first Ctrl-C or SIGTERM grants a run before it is stopped. A
`human>`, `[y/N]` or `command>` prompt open at that moment steps aside for the countdown, and
anything half typed there is discarded; it comes back empty if the countdown is cancelled. That
includes a `[y/N]` that took the terminal from an idle `you>`.

At `you>` in this terminal, or at `you>` or `command>` in the `lain input` pane, a Ctrl-C over a
typed line only clears that line and reaches no chat. Over an empty line it goes to the chat as
before, and at `you>` that ends the chat.

#### Compaction flags

Compaction is on by default. See
[Compaction and summarizer tiers](compaction.md) for how the 3
tiers work.

| Flag | Default | What it does |
|---|---|---|
| `--compact` / `--no-compact` | on | Summarize the history's head as it grows. Recorded in the session header only when off; an untyped `--resume` keeps the recorded choice. |
| `--compact-bytes` | `262144` | Claimed bytes above which a compaction is warranted: the droppable head narrowed to the turns `--compact-strategy` can collapse, pins excluded. Roughly 64k tokens. |
| `--compact-cap` | `1048576` | Claimed bytes that force a compaction even while the prompt cache is warm. Measured as `--compact-bytes` is, so turns the strategy would leave standing never trip it. |
| `--compact-keep` | `20` | Trailing messages a compaction leaves verbatim. About the last 10 exchanges. |
| `--compact-strategy` | none | `summarizing`, `elide`, `summarize-conversation`, `elide-tools`, `truncate-cumulative`, `summarizing-flat`, or a `+`-joined composition of them. Which policy collapses a span; see [Collapse strategies](#collapse-strategies). Unset is its own case and a synonym for none of them. |
| `--compact-schedule` | `idle` | When a compaction runs. `idle` commits the cut while you are away (a fresh chat ticks every 5 seconds, and a prepare runs once the chat has sat idle past the provider's cache TTL, or at least 120 seconds where there is none), so your next line pays no summarizer wait. `turn` compacts at the next ask. Recorded in the session header as `compact_schedule`; a bad name is refused before the journal opens, and `--resume` inherits the recorded one. Runs under different schedules do not pool in study comparisons. |
| `--summarizer-provider` | the chat's `--provider` | `anthropic`, `ollama`, or `ollama-cloud`. The summarizer is a tier, chosen independently of `--provider`; `ollama` is the local tier. |
| `--summarizer-model` | the chat's model when the providers match, else the summarizer provider's own | Inherits the chat's `--model` only while both tiers share a provider. |
| `--summarizer-max-tokens` | `1024` | Ceiling per summary. A truncated summary replaces the result it compressed, so the ceiling is sized for a paragraph. |

Both provider flags are validated against the same set. A typo in either is refused when the
`Backend` is constructed, which is earlier than the first compacting turn (under `--no-compact`
that turn never comes). A non-positive `--summarizer-max-tokens` is refused there too.

The compaction signal counts only what the strategy can claim. `summarize-conversation` claims
conversational runs of 2 or more messages and `elide-tools` claims tool rounds, so under either
alone a head made of the other kind is not counted. When the window fills and the strategy can
claim none of the droppable turns, the compaction decision says so, naming the strategy. When the
wider arm would claim what it left, the decision suggests
`--compact-strategy elide-tools+summarize-conversation` instead of `--compact-keep`. A pin keeps
its turn through a compaction and is not counted either.

```bash
lain --provider anthropic --summarizer-provider ollama    # frontier chat, free local summaries
lain --provider ollama --summarizer-provider anthropic \
     --summarizer-model claude-haiku-4-5-20251001         # local chat, bought summaries
```

A third tier takes no flag: the deterministic summarizers you declare in `.lain/summarizers.rb`.
They are consulted before any model call, for every tool result, large or small,
because a declaration you wrote costs no tokens and no latency and so has no threshold to clear.

Two consequences before you write one. A declaration that raises falls through to the flagged
tiers above at no cost. A predicate that never returns blocks the turn that observed the result,
with no timeout. See [Compaction and summarizer tiers](compaction.md).

#### Collapse strategies

`--compact-strategy` does not switch compaction on, and it does not decide whether the derived
context timeline is built. Every compacting turn derives; this flag picks the policy that
collapses a span inside that derivation. The background is
[2 lineages, one render path](../devs/compaction.md#two-lineages).

| Value | What collapses a span | What it costs |
|---|---|---|
| *unset* (the default) | The run's own eager tool-result tier, read back through the turn's `SummarySnapshot`. This is the control arm, and it is what every un-flagged chat has always rendered. | Nothing extra. The summaries were already fired off the critical path by tier 1; the compacting turn only reads them. A result with no held summary becomes an elision line. |
| `summarizing` | One model call per span, answered through the `--summarizer-*` tier and wrapped in a recorded oracle, so every answer lands on the journal as an `oracle_answer` that a later re-derivation could read back instead of re-asking. Nothing in the CLI does that yet, so a resumed chat re-asks. | Tokens and latency on the compacting turn's critical path, where the eager tier's are not. An unreachable tier leaves the span uncollapsed and writes a line to `stderr` attributed to `lain:compaction`; it costs the span, never the turn. |
| `elide` | A deterministic per-message attestation (role, digest, byte count, one line each) and no model call at all. | Nothing but its own bytes, and those are not always a saving: over short messages an attested span can be no smaller than what it replaced. That case is caught and declined as `refused: inflates`. |
| `elide-tools` | `elide`'s attestation, narrowed to the contiguous runs of tool-carrying messages. Every conversational turn is left for the derivation to retain verbatim, in place. | Nothing, and no model call. The same `refused: inflates` caveat as `elide` applies more often: the span it claims is exactly the tool observations, so over short tool results the attestation is the whole of what it wrote. |
| `summarize-conversation` | `summarizing`, cut to the conversational stretches of more than one message. The model is never asked about a tool observation, and a lone turn between 2 tool rounds is retained, since summarizing 1 message into a message would cost a call for nothing. | One model call per claimed run, so the per-turn multiplier is N rather than 1. Otherwise the costs are `summarizing`'s: critical-path tokens and latency, and an unreachable tier leaves that one run uncollapsed while its neighbours still collapse. |
| `truncate-cumulative` | The span's own text, cut by fixed rules and no model call: assistant text verbatim, a human turn up to 20000 characters, each tool call as one `[tool] name arguments` line (arguments cut to 150), each tool result cut to 500 (a failed one is prefixed `[tool error]`; no other part is labelled, by role or otherwise). It never splits a tool call from its results. Each cut covers only the span after the last one, and every earlier replacement stays. | What the cuts discard is gone, not attested: thinking, images and the tail of a long result. A faithful form that drops earlier replacements is not offered, because a held cut renders from its recorded content. |
| `summarizing-flat` | `summarizing`, asking about the span as labelled lines (`[User]: ...`, `[Assistant]: ...`, `[Tool result]: ...`) instead of canonical JSON, so tool output reaches the model unescaped. One model call per span, answered through the same recorded oracle; the journal holds a different question under the same oracle digest. | The same model call as `summarizing`. The answer is still keyed by the span's digest, but a recorded flat answer replays only under this arm. |

Two strategies compose with `+`, and `elide-tools+summarize-conversation` is the pair to use.
They are exact complements by construction (both ask one predicate which messages carry a tool
block), so together they partition a span without overlapping. Any other composition overlaps
and is refused at launch (for example `elide+summarize-conversation` or `elide+elide-tools`),
naming the flag value and suggesting `elide-tools+summarize-conversation`. The union is
commutative, so the order of the 2 names is not a setting.

Unset carries no Thor default, on purpose. A default would materialize the key, and the code that
reads the flag could then not tell "no strategy was named" from "someone named the default". The
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

`--isolation worktree` resolves an `Isolation::Clone` backend under a per-project root, decorated
with whatever `.lain/services.rb` declares, and hands it to the `Supervisor` the chat fleet leases
from. Each worker's checkout is a `git clone --shared` of the repository, cut detached at the
working branch's tip; its commits reach upstream only at the fold-back fetch, when it hands back.
`lain worktrees gc` reaps clones, and keeps one whose git dir was tampered with for a human.

Things to know before you use it:

- One-shot and `@role` spawns lease too. Under `--isolation worktree`, a one-shot spawn and an
  `@role/skill` line each take a clone of their own from the supervisor. Actor-mode children are
  what [`/implement-epic`](#implement-epic) runs, and the epic driver builds its own linked-worktree
  isolation over the epic's working branch and does not lease through this flag.
- A chat's workers hand their commits back through the merge coordinator. A worker runs its
  fast checks (`check`, and `lint` on the files `lint_files` selects) before it rebases onto the
  branch, then queues for the coordinator and answers
  `queued as <id>; lain land wait <id> --branch <branch>`. The parent checkout is never merged into,
  so your uncommitted edits there never block a handback and no handback waits on another's merge.
  [`lain land wait`](#lain-land) says when the work is on the branch. The `isolation` verb tunes the
  checks, the rebase and the landing.
- One concurrent isolated run per project. The worktree root is keyed on the repository and
  worker ids restart at 1 per process, so a second `--isolation worktree` run in the same repo
  reaps the first's live checkouts. That is a deliberate trade: it lets a crashed run's
  leftovers get cleared before the next lease.
- A leased child stays in its checkout. A worker's worktree, a researcher's kept lease or a lent
  checkout: a `write_file` or `edit_file` path, a `bash` cwd, a `cd`, a redirect, and a path a known
  writer (`tee`, `cp`, `mv`, `sed -i`, `dd of=` and the like) writes are refused when they land
  outside it, before any approval is asked, even when a later `;` or `cd -` makes the rest
  unreadable. A read outside the project still asks. A writer lain does not know, a script or build
  tool, and a command whose paths cannot be named (an expansion such as `$D` anywhere in it) are
  left to the approval ladder, so `bypass` approves them. The check reads the disk as it stands
  before the command runs, so a link the command itself creates is not seen.

A bad backend name, or `worktree` outside a git repository, is refused during wiring, before the
journal is opened.

### lain up

Create or reattach to the `lain` tmux session: a `chat` window plus a session-scoped status HUD.
`PATH` is the project directory to open, expanded against the shell's own, and refused by name
if it is not a directory. Flags after `--` are forwarded to [`lain chat`](#lain-chat).

```bash
lain up                                        # editor | transcript over input pane, + HUD
lain up ~/dev/other-project                    # ...in that one instead
lain up ~/dev/new-project --create             # make it first if it is missing
lain up --no-nvim                              # no nvim pane; still transcript over input pane
lain up --nvim-socket /tmp/lain-abc123.sock    # explicit nvim socket
lain up -- --provider ollama --no-compact
```

The window is 3 panes: an `nvim --listen` pane, a `chat` pane beside it, and an input
pane split beneath the chat pane. `--no-nvim` drops the editor and nothing else. The chat is still
a transcript over an input pane, because the chat pane scrolls. The input pane runs
[`lain input`](#lain-input): it draws the HUD above the prompt and refreshes it without a
keypress, and every gesture the prompt ever had works there, `[y/N]` and `human>` included.

The input pane's height is a floor. lain seats it at 6 rows on a `window-layout-changed` hook, and
only when something drove it below that, so a pane you grow stays grown. In a window shorter than
13 rows the hook stands aside and lets tmux's own arithmetic run, so the transcript is not squeezed
out of existence.

| Flag | Default | What it does |
|---|---|---|
| `--session` | `lain` | tmux session name. Also the input socket's name, so 2 cockpits on one project do not collide. |
| `--socket` | tmux's default | tmux socket (`-L`). |
| `--nvim` / `--no-nvim` | on | Add the nvim pane beside the chat. The input pane is there either way. |
| `--create` | off | Make `PATH` when it does not exist. Only the last directory is made, so its parent must exist; without the flag a missing `PATH` is refused and the refusal names `--create`. |
| `--nvim-socket PATH` | derived | Listen on this nvim socket instead of the per-project one lain derives. Must be absolute: the socket is the one name both panes have to agree on, and a relative one resolves against whichever pane reads it. |

One directory feeds all 4 of the places `up` names one: every pane's `-c`, the nvim socket's
hash, the input socket's hash, and the HUD's state file. The state file lives under
`$XDG_STATE_HOME/lain/status/`, keyed by that directory's hash, not inside the project. `up`
prints the resolved path on every launch, because nothing else in the program names it.

**Write a value-taking flag with an `=` when it is the last thing before `--`.** `lain up /tmp
--nvim-socket -- --provider ollama` is refused, because the option parser skips the separator and
takes `--provider` as the socket, which would silently forward the `PATH` you typed to `chat`.
`--nvim-socket=/tmp/x.sock` cannot be read that way.

**Mouse and selection.** The session turns tmux's `mouse` on, so the wheel scrolls the chat pane's
history. tmux then owns the mouse, and your terminal's native text selection needs Shift held
while you drag.

`lain up` also sets the tmux server option `extended-keys` to `on` when it reads `off`, and it
prints a notice when it does (the setting is server-wide). That option alone does not deliver
Shift+Enter. The line editor also asks the terminal for it (`\e[>4;1m`) around every prompt read
(`you>`, `command>`, `human>` and `[y/N]` alike) and hands the terminal back its plain Enter
(`\e[>4;0m`) afterwards, so other programs in the same tmux are unaffected. Alt+Enter inserts a
newline too, in vi command mode as well.

The input pane redraws the HUD in place only over an empty editor: while you are typing it holds
still, and a resize waits for the next whole prompt.

`lain up` `exec`s into tmux, replacing the process. From inside tmux it uses `switch-client`;
from outside, `attach`.

### lain remote

```bash
lain remote pair my-phone      # admit a phone; prints its token and the relay address, once
lain remote revoke my-phone    # stop admitting it
```

`lain remote pair NAME` adds a device to the devices file under `$XDG_STATE_HOME/lain/remote/` and
prints `paired NAME`, the `token:` and the `relay:` address (this host's `tailscale0` address on
port 7820, or `none` when the host has no such address). Enter the token and address in the
settings of the phone app (`apps/lain-remote`, labelled `lain` on the phone). The token is not
shown again.

`lain remote revoke NAME` removes the device. The relay rereads the file on its own, so neither
verb restarts it, and a revoked device's connection closes at that reread. Any other verb, or a
missing `NAME`, is refused by name.

The phone surface itself is switched on by the [`remote` config verb](configuration.md), and
[docs/users/remote.md](remote.md) walks through the whole setup.

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
`$XDG_RUNTIME_DIR` is unset), in a directory created at `0700`. It carries no pid, because the
chat and the pane have to derive the same name before either process exists. A stale socket file
left by a dead chat is rebound; one a live chat still holds is refused by name.

Panes are clients, so a second `lain input` on the same socket simply connects. It is redrawn with
the prompt and HUD standing at that moment rather than waiting for the next change.

The pane draws the chat's HUD above the prompt and refreshes it without a keypress, completes a
`/` or `@` word with Tab or C-x, and shows the mode's layer lighters beside the prompt. While an
ask runs, its HUD line updates in place; redraws stop once a line is sent, until the next prompt
draws the header. A typed line that wraps past the pane width can misplace an in-place redraw.

The pane holds no agent, so Ctrl-C, Ctrl-\ and `/stop` there travel to the chat's own rail and are
not answered locally. The exception is a Ctrl-C over a typed line (at `you>`, at `command>`, or a
draft typed while a run is busy), which only clears that line. HUP and TERM end only the pane:
closing or killing it leaves the chat running, and a new `lain input` on the same socket picks the
chat back up.

**The transcript reads as a conversation.** Because you type in a different pane from the one that
scrolls, a chat started with an input socket (the `lain up` cockpit) says your side back, stamped
`HH:MM:SS`. A prompt read at `you>` appears as `you> <text>`, a slash command included, with the
rows of a multi-line prompt indented under the first. An answered question set appears as
`answered lain's questions` followed by one indented line per answer, each cut at 120 columns
(`TTY::ECHO_WIDTH`), because a reply can run to tens of kilobytes. A plain chat echoes nothing, since
the terminal already shows what you typed.

A tool round that wrote files adds 1 stamped line, however
many tools ran in it: `wrote src/main.rs` for one file, or `wrote 5 files: a, b, c (+2 more)` with the
first 3 named. Only `write_file`, `edit_file` and `epic_write` count, and reads are not reported
(`lain://timeline` lists them). A path under the project root is shown relative to it, any other path
absolute with your home directory as `~`, and an epic document as `<slug>/<path>`. A subagent's write
is reported too, with its role first (`dev wrote src/main.rs`).

Known gaps: a chat resumed from a session file shows write paths relative to the process's working
directory rather than the project root, and a subagent working in its own worktree reports paths
relative to that worktree without naming it, so `dev wrote src/main.rs` reads as if it were your checkout.

**A line typed while the agent is working is a note to it.** Type at the input pane (or the plain
prompt) while a model call or a tool is running and nothing is asking you a question: the line is
recorded as a message to the agent, and the transcript echoes it as `note for the agent: <text>`. The run is not
stopped. The agent reads the note in its next model request, which is the first one after the tool
round that was running, as a `<mailbox>` block reading `human | <text>`, beside the tool results. A note
joins exactly 1 request: the requests after it carry only the model's reply to it, not the note again.

Four cases differ:

- A slash command keeps its place as your next prompt, since it is addressed to lain.
- A blank line is not a note.
- A line typed at a parked `human>` or `[y/N]` is that prompt's to answer, or is held as before.
- A note typed during the last model call of a run has no later request to join, so it stays
  pending. When the run ends the transcript says `your note joins your next prompt`, and it rides
  the first request of the next prompt you send.

Once the run's final reply has arrived the agent is no longer working, so a line typed then is
your next prompt, even before `you>` is back.

### lain sessions

List this project's recorded sessions, newest first, from the root's sessions directory. Offline.

`--all` includes ephemeral `--btw` sessions, which are hidden by default.

A row ending in `N lines unparsed` names a session with unparseable lines in its journal.
`Journal.records` skips them rather than raising, since a crash can tear the last line or another
writer can leave bytes in it. Nothing can be built on the gap: forking such a session refuses
precisely, naming the record index and both digests. Treat the count as a reason to inspect the
file.

### lain watch

Read-only live tail of one actor's lineage. The selector is a spawn digest prefix.

```bash
lain watch 9f3c
lain watch 9f3c --session 20260725-1a2b.ndjson
```

`--session` defaults to this project's newest. This is what `lain chat --windows` opens per
subagent spawn. It owns its exit status, and Ctrl-C on a SIGKILL'd session exits clean.

### lain export

```
lain export SESSION [--html | --jsonl] [--out PATH] [--force] [--include-released]
```

`--html` (the default) is the share artifact: one self-contained page of the conversation only (turns,
tool calls and results, compaction cuts), with the home directory written as `~` and the project root
as `<project>`. Masked regions stay as their `<redacted:n>` placeholders; the footer counts masked reads,
commands and searches, and any released reads, and nothing is re-scanned. A session that released reads
to the model is refused unless `--include-released` is given.

`--jsonl` is a local record and is not for sharing: the applied record stream, one record per line, each
byte for byte as the file holds it, so it keeps the system prompt, absolute paths and approval records.
It drops a retreat line whose turn never landed, so the chain links no longer close. `--html` and `--jsonl` are exclusive.

`SESSION` is an explicit path, a filename under this project's session dir, or a filename without
its `.ndjson` suffix. Without `--out` the document goes to stdout; with it
the file is written with mode 0600, an existing path is refused unless `--force`, and the path is printed.

### lain trust

```
lain trust [PATH]          # show the project's .lain/*.rb, ask [y/N]
lain trust --yes [PATH]    # grant without asking, for a headless run
lain trust --user          # the same for $XDG_CONFIG_HOME/lain/config.rb, which takes no PATH
```

Shows every top-level `.lain/*.rb` of the project at `PATH` (default: the current project), with
control characters escaped, and on a yes records a mark for that project root and those exact
bytes. Trust covers those files only, not what they `require` or `load`. Any changed byte, added
file or rename is a new decision, and so is the same bytes under another root. A linked worktree
that inherits the main checkout's `.lain/` is the same project and shares its mark.

A no, or end of input, records nothing and exits non-zero, so `lain trust && lain chat` stops
there. A project with no `.lain/*.rb` has nothing to trust. `--user` judges the one file
`$XDG_CONFIG_HOME/lain/config.rb`, which runs in every project, under a mark no project's can
equal.

### lain consolidate

Court-clerk pass: distill a session's completed subagent lineages into memory.

`--dry-run` reports what would be clerked with no spawn and no API key. Takes `--provider`,
`--model`, and `--max-tokens` like [`lain chat`](#lain-chat), so you can clerk locally against
Ollama.

A clerk whose prompt outgrows its window is recorded as a failed lineage and the pass reports the failure.

### lain improve

Harness-improver pass: record what would make lain itself better into the dogfood queue.

Same `--dry-run` / `--provider` / `--model` / `--max-tokens` shape as
[`lain consolidate`](#lain-consolidate).

A pass whose prompt outgrows the model's window ends with one line naming the prompt size, the window and how many notes it stored (`improve: the N-token prompt exceeds the M-token window, stored K notes`), not the server's raw error. A note is stored once, however many times the model repeats the call.

### lain improvements

The accumulated cross-project dogfood queue, written by the `improvement_write` tool into
`$XDG_STATE_HOME/lain/improvements.ndjson`.

`--project` filters to one project (a 12-hex-char hash, or a path resolved the same way).
`--kind` filters to `knob`, `bug`, `missing-feature`, or `doc`.

### lain gateway

Serve one allow-listed model upstream on loopback, asking you before each request leaves. It is the
other half of `lain chat --secret-oracle cloud --gateway URL`: the chat sends its question to the
gateway, and you see it here first. There is no bind option and no way to forward without asking.

```bash
lain gateway --upstream https://ollama.com
lain gateway --upstream https://api.anthropic.com --port 8787 --root ~/dev/app
```

| Flag | Default | What it does |
|---|---|---|
| `--upstream URL` | required | Where approved requests go: `https://ollama.com` or `https://api.anthropic.com`. Any other spelling is refused. |
| `--port N` | `0` | The loopback port; 0 picks a free one, printed at start. A value that is not an integer in 0 to 65535, or a port taken or not yours to take, is refused naming the port. |
| `--root PATH` | the working directory | The project whose git history and ignored files hold secrets to refuse. Outside a git checkout only the gateway's environment secrets are checked, and the start-up output says so. |
| `--log PATH` | under the state home | The gateway's NDJSON log. Unset, it is `$XDG_STATE_HOME/lain/gateway/<timestamp>-<pid>.ndjson`. |

The gateway's environment must hold the upstream's key (`OLLAMA_API_KEY` for `https://ollama.com`,
`ANTHROPIC_API_KEY` for `https://api.anthropic.com`), or it refuses to start naming the variable.
It binds `127.0.0.1` only.

At start it prints 3 lines, plus a `note:` line for each caveat:

```
lain gateway: http://127.0.0.1:<port>
token: <path of the token file>
log: <path of the log>
```

The URL carries no token. The token is written to `$XDG_STATE_HOME/lain/gateway/<port>.token` at
mode 0600 before the URL is printed, and removed however the gateway ends, so the chat reads it from
there. Each request is then shown whole (`--- POST <endpoint>, <bytes> bytes`, with a `flagged:` line
for what the secret inspection found) and followed by `Forward POST <endpoint>, <bytes> bytes? [y/N]`.
Only `y` or `yes` forwards it. A long run of whitespace or invisible characters in a body is shown as
a count, so a payload cannot scroll the question off the screen. It serves until interrupted and exits 0.

### lain epic

The epic tier: the artifact home, the issue graph, and the sign-off queue. Every verb takes an
optional `SLUG`. With one epic in the home it can be left out; with several, an ambiguous command
refuses and names them.

```bash
lain epic status                                   # where one epic stands
lain epic status --mermaid                         # the issue graph as mermaid source
lain epic show                                     # the research document, printed as written
lain epic show issues/export-stream                # ...or any other document of the epic
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
| `lain epic show [DOC] [SLUG]` | Print one document of the epic, verbatim: `research` (the default), `epic` or `issues/ID`. The epic home sits under `$XDG_STATE_HOME`, so this is how you read `research.md` outside a chat. A missing file names itself and the epic home; any other `DOC` is refused with the 3 names. Read-only. |
| `lain epic submit STAGE [SLUG]` | Submit an artifact to a stage's gate. `--issue` names the issue for the per-issue stages, `--wave N` asks, in one question, every issue plan of wave N whose approval does not already stand, and records 1 decision per issue (`deny <id>: reason` denies only the issues named), `--digest` the changeset for `implementation`; `--provider`/`--model` wire the adjudicating spike. A denied or unanswered gate exits 1; a deferred one exits 0. |
| `lain epic queue [SLUG]` | The parked sign-offs, folded from the journals rather than read from a file. |
| `lain epic approve DIGEST` / `lain epic deny DIGEST` | Append a terminal decision, draining the partition. Both take `--reason`. |
| `lain epic add ID TITLE [SLUG]` | Add an issue discovered mid-flight. `--discovered-from` names the live issue it grew out of. |
| `lain epic split ID [SLUG]` | Replace one issue with several. `--into` is required and takes comma-separated ids. |
| `lain epic merge LEFT RIGHT [SLUG]` | Replace 2 issues with one. `--as` is required and names the id it takes; `--title` overrides the combined title. |
| `lain epic land ISSUE_ID [SLUG]` | Land one approved issue onto the epic's working branch, pushing nothing. `--resume` finishes a landing that merged and then stopped. |
| `lain epic finish [SLUG]` | Take an epic whose every issue is done to `main` as one pull request, then delete its remote branch. `--local` merges it into `main` in this repository instead: no remote, no pull request, nothing pushed. With no remote it refuses and names `--local`; a stopped finish exits 1. |

The 3 graph verbs are journaled as a `graph_revision`, so a restructuring is part of the
record.

**In the editor, a written document opens itself.** With `--nvim`, each time one of the chat's epic tools writes a
document (`epic_write` is the usual one) the cockpit draws it as a read-only `lain://epic/<slug>/<path>` buffer (for example
`lain://epic/frugirl/research.md`), mounted epic or not, with the markdown filetype. The first write
opens it in a split below your window and never takes focus. A later write to the same document
refreshes the buffer in place. If you close its window, a later write refreshes the hidden buffer
and does not open the window again; `:buffer lain://epic/<slug>/<path>` brings it back. It is
not one of the buffers primed at attach: it does not exist until the first write. See `:help lain-buffers`.

**`lain epic finish --local`** is for a repository with no remote. The base branch is always
`main`. It must be the branch checked out in the project root, with no uncommitted changes to
tracked files, and no untracked file standing where the merge would write. Otherwise the command
refuses before merging anything and names what to fix.

The merge is computed in the object store with `git merge-tree`, so a conflict is found without
touching your checkout: the command stops, names the conflicting paths, and `main` has not moved.
A clean merge becomes one merge commit, and `main` is fast-forwarded to it. If `main` already
holds the epic's tip, the command says so and merges nothing.

The journal records the merge as `local_merge`, so a later remote finish never reads it as a pull
request. The local `epic/<slug>` branch stays for [`lain worktrees gc`](#lain-worktrees-gc) to
reap.

`lain epic land` names an issue and takes no SHA. The commit it lands is the one anchored when the
implementation gate approved it, so a commit nobody approved cannot be landed by typing it.

When it refuses, it says which thing is missing:

- `no worker commit is anchored for issue X of epic <slug>` means the driver never handed back a
  commit for that issue. Re-run it through the driver.
- `no anchored commit carries an approved implementation gate for issue X` means a commit is
  anchored but nobody approved it. The refusal names
  `lain epic submit implementation <slug> --issue X --digest <sha>`.

`--digest` must be a commit in the repository; anything else is refused. The implementation
gate's question reports what the project's suite did on that commit (`tests: 3 passed, 1 error`,
`tests: 4 passed`, or `tests: not run (why)`). A red result does not refuse the gate; the decision
is yours.

### lain land

The merge coordinator's command line. A chat's workers queue through it on their own; you run it
to land a commit by hand, or to see where a queued one stands.

One drainer lands a branch's queue at a time, a batch of up to `batch_cap` entries per run of the
suite named by `verify`, and the branch only ever fast-forwards to a commit that run passed. With
no `verify` configured a branch fast-forwards unverified, and `lain land wait` says
`verification skipped: no verification is configured` after the landed line.

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
| `3` | No live process has held the drain lock for 5 seconds, or the one that held it is dead. It prints the `lain land drain --branch <b>` command to run. A drainer still booting can read this way; running the printed command then is harmless, because the lock admits one drainer. |
| `130` | Interrupted with Ctrl-C. The entry stays queued unless it landed meanwhile. |
| `64` | The id, repository or branch was refused: an id the queue never minted, a bare repository, a detached branch. |

A malformed command line, such as a missing id, is Thor's usage error and exits `1`. `lain land enqueue` and `lain land status` refuse, by name and in one line, a `drain.lock` that is unreadable (or, for `enqueue`, not writable), rather than saying a drainer is landing.

The coordinator's root is the repository's main worktree, whichever linked worktree you run
from: its `.lain/config.rb`, its journal and its verify worktree are the main one's. A bare
repository is refused.

`lain epic land` and the drainer share one verify worktree and take turns on the branch's drain
lock, so a landing waits and does not race the other. A verify run takes the suite lock, which is
one lock per machine, so 2 repositories never run their suites at once.

A drainer killed mid-verify leaves its suite running. The next suite-lock holder stops that
process group before its own verify starts, and says so (in `drain.log` for a drainer, on stderr
for `lain epic land`). It stops a group only when its leader's start time still matches, or when a
member carries a verify's `lain-verify-` TMPDIR. A start time it cannot read leaves the group
running and is named the same way.

### lain todos

Drain, count and extend the project's chore file: one `- [ ] text` line per chore, `[research]` after
the box for a question the research skill answers instead of a change. The file is `TODOS.md` unless
the [`todos` verb](configuration.md#todos) names another. [`docs/devs/dogfood.md`](../devs/dogfood.md) covers keeping it out of git,
what runs unattended, and a nightly timer.

```bash
lain todos drain --max-items 3
lain todos status
lain todos add 'tidy the README'
```

| Command | What it does |
|---|---|
| `lain todos drain` | Take each open line in file order: claim it, cut a clone lease, run a headless `lain chat` in it, and land the commit it made through [`lain land`](#lain-land). Prints one line per item. `--max-items` stops after that many; `--max-cost` is each chat's `--max-cost` in dollars (default 5). |
| `lain todos status` | The counts by state, then each claimed line with its pid, host and whether that pid is live. |
| `lain todos add TEXT` | Append `- [ ] TEXT` to the file. Nothing else in it changes. |

`lain todos drain` exits `0` when every item landed or was researched, `1` when any failed, and `130`
when interrupted. An interrupted item stays claimed, and the next drain takes it back.

### lain queue

Print what is waiting for review, 1 row per line as `<id>\t<reason>\t<summary>`, best reason
first. Rows already opened (in the queue log) are hidden. Notes, such as a search that hit its
cap, go to stderr. Text from outside (a plan title, a pull request title) is printed with tabs,
newlines and control characters removed, so a row is always 1 line.

```bash
lain queue here
lain queue prs --json
lain queue show "pr:acme/api#42"
```

| Command | What it does |
|---|---|
| `lain queue here` | Plan runs in this repository, then its local changes. |
| `lain queue local` | Local changes only. |
| `lain queue prs` | Pull requests that request my review (my own requests; path and keyword matching off). |
| `lain queue show ID` | The row's reason and range, and for a pull request its title, author and requested time. |
| `lain queue prs --all` | Also requests asked of a team of mine or of me as code owner. |
| `lain queue prs --matches` | Also pull requests a configured keyword or path picks out. |
| `lain queue pick [here\|local\|prs]` | Choose a row in fzf and open it. Enter opens it; Alt-Enter opens it with a critique focused on its reason; Escape opens nothing (exit 130), and a filter that matches nothing opens nothing (exit 0). Without fzf it prints the rows and exits 1. For `prs`, Ctrl-T toggles team requests and Ctrl-K toggles keyword and path matches; the prompt shows the state. |
| `lain queue open ID [--critique FOCUS]` | Offer the row's review to the newest chat in its checkout that answers; the chat asks before it runs, and the other chats there are named. Marks the row seen only when the human presses Enter at the offer, live or held; a dropped offer leaves it listed. When no chat runs there, the review is held for the checkout, and the next attended `lain chat --nvim` there (which `lain up --nvim` starts) offers it once, at its first `you>`: Enter takes it and marks the row seen, and `x` then Enter drops it; a chat that ends before the answer holds it again; Ctrl-D in the input pane at the offer drops it, as `x` does. Inside herdr, a focused workspace labelled `review <dir>` is started at the checkout running `lain up --nvim`, unless one with that label is open already; when herdr starts none, the review stays held, the line says so, and the next open asks herdr again. A second open while a review a chat would still take is held replaces it and says so, and says too whether herdr started a workspace for it; a file where held reviews go is refused in 1 line, exit 1. A held review that fails validation, names another checkout, is over 1 day old or dated ahead, is not a regular file, or allows group or other access is removed with 1 note. Exits 1 saying why when the chat is showing another offer, already shows this one, or refuses a field; also when the chat takes the connection but sends no answer within 30 s, naming that chat, which may still show the offer. A pull request with no local clone opens in the browser as the configured GitHub account instead. `--critique FOCUS` works on pull request rows only, is cut to 80 printable ASCII characters (escape sequences dropped, accents folded), and is not used when the row opens in the browser. |
| `lain queue poll` | Count the review requests asked of me: direct, team, and direct ones made since `lain queue prs` or `lain queue pick prs` last listed them for me. Rewrites `reviews.json` in lain's state directory, sets the herdr `reviews` workspace token, and notifies each new direct request once. Needs no running chat; a timer runs it, for example every 5 minutes, and a poll that starts while another runs does nothing. When GitHub cannot be reached it keeps the last counts, marked stale, and notifies nothing; with no earlier counts it writes nothing. |

`--json` on `here`, `local` and `prs` prints 1 JSON object per row instead.

Every HUD (the tmux status line, the `lain up` status line, the input pane's header, and nvim's `require('lain').hud()`) ends with `rv N+M` from the last `lain queue poll`: N review requests, M of them new direct ones, and a trailing `?` when that poll could not reach GitHub. With no counts file the HUD is unchanged, and the tmux and `lain up` status lines show the segment only once a chat has published its state.

### lain worktrees gc

Reap lain's worker checkouts, anchors and merged epic branches whose work is safe elsewhere. No
flags.

```bash
lain worktrees gc
```

A checkout is kept unless its work is provably somewhere else. A lease whose owning process is still
alive is live and kept; a checkout that is dirty is kept, re-locked as retained; and a lock whose
reason cannot be read means keep.

Before anything is removed, the committed `HEAD`, plus a snapshot
of any dirty state, is anchored under `refs/lain/worker/*`, so a reaped tree still cannot cost a
commit. An `epic/<slug>` branch is deleted only once its tip has moved from its marker, is an
ancestor of `main`, and is checked out nowhere. How long a released checkout is kept is
[`isolation retain_days:`](configuration.md#isolation).

Runs take a per-repository lock, so a second concurrent `gc` does nothing and says so.

**It also runs itself, once a day.** A `lain` launch spawns a detached `lain worktrees gc` when the
stamp under `$XDG_STATE_HOME/lain/gc/` is older than 24 hours, logging beside it. The stamp is
renewed only after a spawn succeeds, and 2 simultaneous launches start one run between them.

### lain daemon

The per-user daemon that holds chat registrations, the phone relay, the ntfy notice and supervised runs. Every chat registers with it and starts it when none runs. [docs/users/remote.md](remote.md) covers the phone setup.

```bash
lain daemon status            # pid, uptime, build, relay state, sessions and runs
lain daemon runs              # the runs it supervises, with status and log
lain daemon ensure            # start it, or replace one this checkout's build has outdated
lain daemon restart [--force] # refuses while a run is live, naming it, unless --force
lain daemon stop RUN          # TERM the run's process group, KILL after its shutdown grace
lain daemon run epic SLUG     # start a headless epic run in the current project
lain daemon run chores        # start a headless chores run in the current project
lain daemon herdr-sync        # show the live runs on the lain herdr workspace
```

A run's root is the current project, and the run outlives the terminal that started it. `epic`
runs a headless chat (`--non-interactive --approval auto --human remote`) on
`/implement-epic SLUG`, and `chores` runs `lain todos drain`. A run answers its approvals from the
phone (`--human remote`).

`herdr-sync` shows the live runs on the `lain` workspace in herdr. The daemon runs it as runs
change, so you rarely type it. See [plugin/herdr/README.md](../../plugin/herdr/README.md).

The daemon also starts a review poll (`lain queue poll`) every 5 minutes when the user config has
a `github` verb, and 1 for each project with its own github settings while a chat runs there; each
shows in `runs`.

With no built daemon binary, each command exits 1 naming `rake daemon:build`. `status` and `runs`
never start a daemon: with none running they print "no daemon is running" and exit 0, while
`stop RUN` exits 1 saying the same. `restart --force` lists the live runs it leaves going, since
the new daemon cannot list them.

### lain herdr

Link, unlink or list lain's herdr plugin. No flags.

```bash
lain herdr link      # herdr plugin link <lain>/plugin/herdr
lain herdr unlink    # herdr plugin unlink lain
lain herdr status    # herdr plugin list
```

This is the only command that writes to herdr's configuration, and it does so by asking herdr: `link`
records a link to the plugin folder this lain ships, so an upgrade of lain is picked up without
linking again. A herdr not on `PATH` exits 1 saying so, and nothing is written.

## Session commands

Typed at the `you>` prompt. Each one dispatches ahead of the skill middleware and costs no model
turn. `/help` lists the live registry, so it matches what is registered.

### /help

List the registered commands and the loaded skills.

### /status

Cache warmth, fleet size, and inbox count for this session. Cache warmth has 3 answers: warm,
cold, and a feed that has published no deadline at all, which is not a cache that went cold.

`fleet` here is a count. The fleet's shape (one row per child, nested under the parent it was
spawned from) is drawn in `lain://status` in the editor and followed by `lain watch`; the input
pane's header is the HUD line alone. A row names the child's role, whether it is running, how many
turns it has committed, the first line of its task and its age. Neither surface prints the spawn
digest, which is the address [`lain watch`](#lain-watch) takes and is 70 columns that a reader of
a fleet does not need.

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
| `plan` | scope | Writes and commands are confined to a spike: a worktree cut on `lain/plan/<key>` from the checkout's tracked state, or a scratch directory outside a git repository. |
| `ask` | approval | A gated call parks for you (or the secret oracle) to answer. |
| `auto` | approval | A model judge decides first; only a call it is unsure of parks. The default at launch. |
| `bypass` | approval | A gated call the rules left open is approved, with no judge and no prompt. |
| `+layer` / `-layer` | layers | Enable or disable one of `goal`, `notify`, `quiet`, `vi`. |
| `!` | none | Reset: `ask` approval, no layers, and then `plan` scope. |

Tokens fold over one mode and switch once, so `/mode bypass +notify -goal` journals a single
flip naming where the session started and where it ended. An axis holds one value, so 2 tokens
naming the same axis refuse whole and name both: taking the last would hand a typo the gate.

A run that blocks on the human (a question, a parked approval, a gated prompt) rings the bell by
default; `quiet` turns that off.

With `notify` up, a settled run also rings the bell and sends the
terminal a desktop notification (OSC 9, 99 or 777 by terminal), and writes a feed record.

Under tmux 3.3 and later the notification sequence is dropped unless
`set -g allow-passthrough on`.

`--approval ask|auto|bypass` picks the level a chat starts in. A launched chat starts in `auto`,
and the HUD shows no approval lighter for it; `ask` shows `ASK` and `bypass` shows `BYPASS`.
`/mode !` lands on `ask` (not on the default `auto`), because a reset is the move that gets a human
back in the loop.

#### What each approval level does

All 3 run the same deterministic rungs first. A path the sensitivity rules deny, a call the
`approval` rules deny and a command the shell rule bars are refused under every level, and a
protected or credential path never goes to a model. The levels differ only in what stands below
those rungs.

* `ask` parks the call. You answer it, or the [secret oracle](#lain-chat) does for a read
  it may.
* `auto` asks a judge first: a fresh, tool-limited `auto_approver` child shown the one call,
  with the project root, the working directory, the requester and any named path outside the root,
  bounded at 30 seconds. It answers approve, deny or unsure. Approve and deny settle the call.
  Unsure parks it for you, and so does a judge that errors or runs out of time (a fault never
  turns into an approve). Calls that touch a credential, a protected path, a named or configured
  path, or a path the classifier could not read are never shown to the judge at all: they go
  straight to you.

  A `bash` command is held to every path its words name. A glob is held to every file it
  matches, and a recursive reader (`grep -r`, `find`, `rg`, `cp -r`, `rsync -a`, `tar c`) to
  every file below its root, through links. `git diff`, `git show` and a plain `git log`
  print file contents or commit bodies, so they are held to the whole checkout. Only
  `git status`, `ls-files`, `ls-tree`, `rev-parse`, `shortlog` and a `git log` whose format
  prints no body (`--oneline`, `short`, or a format without `%b`) are not.

  So `cat .e*` or `grep -r x .` beside a credential goes straight to you. So do a glob with more
  than 64 matches, a tree of more than 2,000 entries, a `shopt` or `set`, and a command whose
  paths lain cannot name for certain: an expansion such as `$HOME`, a loop, inline code, or a `cd`
  not joined to the next command by `&&`. These lists are known to be incomplete: some readers
  lain does not know still reach the judge. A script a command runs (`bash x.sh`, `make`) is
  judged by the command's words, never by what the script reads.

  A git write that stays inside the checkout (`git add`, `commit`, `restore`, `reset`, `rm`, `mv`
  and `checkout -- <path>`) is held to the paths it names and the checkout's `.git`, not the whole
  tree, when it runs from the checkout's top level with nothing before the subcommand, no
  `--no-verify` or `--pathspec-from-file`, no short option its subcommand does not take, and
  nothing that opens an editor or a prompt (a commit says where its message comes from: `-m`, `-F`
  or `--no-edit`). Every path it names must be relative with no `..`, read from the words, so a
  link inside the tree is followed; an absolute path, a `~` path or a run from a subdirectory goes
  to you.

  `commit -a`, `add -A`/`-u`, a pathspec of `.` or with a glob or `:` magic, `reset --hard`,
  `--merge` or `--keep`, and `switch` or `checkout` with `--detach` reach the whole tree and its
  object store, so they go to you at any size; a plain directory pathspec (`git add lib`) is walked
  whole, up to the 2,000-entry bound above.

  A headless run (`--non-interactive`) has no one to park for, so there an unsure call is
  refused, and so is a call that would have gone to a human.
* `bypass` approves what the rules allow. Nothing else
  stands between the model and the command.

**`bypass` is not a shell boundary.** Triage reads the words of a command it could parse. When the
shell verdict cannot parse one, there are no words to check, so each of these was approved
under approve-all and is approved under `bypass`: a quoted path (`cat '/etc/shadow'`), a
redirect (`cat < /etc/shadow`), `sudo cat /etc/shadow`, a glob or brace, `cd /etc && cat shadow`,
a relative name with the cwd set to `/etc`, a `$HOME/..` spelling and `head --file=/etc/shadow`.
The same holds for `~/.ssh/id_rsa`. Only file modes stop them. The judge under `auto` does see
these, but it is a model and can be wrong. If a session must not read a file, make its mode
`ask` or take the file out of reach.

Account and sudo files are refused under every level and for every agent: `/etc/shadow`,
`/etc/gshadow`, `/etc/sudoers`, `/etc/sudoers.d/*` and their `-` backups, by name or through a
link on every file tool. On `bash`, every path a command names is checked whenever lain can read
every path in it, whether or not the shell verdict understood the command. A command it cannot
read for certain (an expansion, a `..` after a directory name, or a `cd` not joined by `&&`) is
not checked: under `ask` it goes to you, under `auto` to the judge, and under `bypass` it is
approved. The refusal says no approval can lift it. A project's own `etc/shadow` is not that file.

A chat's child (a researcher, say) also has its reads of `/etc/passwd` and `/etc/group` refused,
not parked, and is told its home directory is in its environment block; your own agent's read of
those still asks.

A deny you give is remembered. When you deny a call, that requester (the main agent, or all
researchers together) is refused a later call of any tool on a path the denied call named, or
anything under it, for the rest of the session, with your reason, but only when that later call
would have asked you.

A `bash` call is remembered by every word its command reads as a path, but never by a word that
starts with `-`, the directory it runs in or a directory above it, a `cd` target or a directory
above one, or a glob's or a search's root. A command whose paths cannot all be named is not
remembered. A timeout or an automatic deny is not remembered, and another requester still asks.

**What runs without anyone asking.** The shell rule approves a command with no human and no model
only when every word of it is ordinary and under the project root. That includes:

* `ls`, `pwd` and `which`, and `NAME --version` for `rustc`, `cargo`, `rustup`, `dx`, `adb`, `go`,
  `gcc`, `clang` and `cmake`. A rustup proxy (`rustc`, `cargo`) is refused beside a `rust-toolchain`
  file, because that file can name a binary to run. `ls` is refused when it would list a name
  `list_files` withholds.
* `node`, `npm`, `python3` and `ruby` are not probes. An interpreter runs what its arguments
  name, so `ruby --version` waits for a decision like any other command.
* `a && b` runs as a sequence without a shell, each side checked on its own. A shell builtin
  such as `cd` abstains, so a sequence holding one is left to the ladder whole.
* A redirect after a stage is read only as `2>&1`, `2>/dev/null` or `>/dev/null`, and does not make a
  command unparseable. Any other redirect still does, and so does `&>`: `sh` that is dash (Docker's
  `sh -c`) reads `cmd &>/dev/null` as "run in the background, then truncate".
* `a ; b` is read as pipelines that must each be approvable. A line with a leading `cd` and any
  `;` goes to the ladder whole: when the `cd` fails, `sh` runs the later pipeline in the original
  directory, so the move cannot be applied to it.
* `sleep` with 1 plain number of up to 3 digits (decimals allowed; never `infinity`, `1d` or an
  exponent), `true` and `false`, and `echo` and `printf` over literal words with no redirect or
  substitution. `printf` refuses `-v`, and any format whose width or precision is 4 digits or comes
  from an argument.
* `git status`, `ls-files` and a listing-only `branch`, each held to what an `ls` of the same tree
  may print. `git show`, `log -p` and `diff` only when every rev peels to a tree and every path they
  print classifies as ordinary; a `show <rev>` with no path, or a `log -p` with no pathspec, goes to
  the judge. These stay with the judge in every form: a global option (`-c`, `-C`, `--git-dir`),
  `--stdin`, `--output`, `--ext-diff` and textconv, a repository config or a `post-index-change`
  hook that runs a program, and a `rev:path` with more than 1 colon. Output masking still covers
  every result, whoever approved the call.
* `cargo check`, `clippy`, `build` and `test` pinned with `--locked`, `--offline` or `--frozen`,
  and `cargo fmt --check`. Every option is matched whole against a table for its subcommand, so a
  `--config`, a `-Z` or a `-C` is refused, as is any option before the subcommand; a toolchain is a
  channel or a version (`+nightly`, `+1.85`), never a path. After `--`, `clippy` takes only lint
  levels and lint names, and `test` takes only filters and options that neither open nor write a
  file.

  The call is approved only when every manifest and `.cargo/config.toml` cargo would load lies
  inside the project root and is plain TOML. A manifest's path dependencies, build scripts,
  `[patch]` and `[replace]` entries and workspace members must resolve inside the root, a git or
  registry source on disk (`file:` or no scheme) is refused, a manifest may not turn on a
  `cargo-features` entry, and a member glob may not use `**`.

  A project config may hold only an allowlist of inert keys: aliases (never for `fmt` or
  `clippy`), terminal, network and build-job settings, and a runner, wrapper or linker given as a
  bare program name such as `sccache`, whose arguments are plain words. Its `rustflags` may only
  set lint levels, `--cfg`, a few `-C` codegen options and a linker by name, and an `[env]` table
  is refused. Paths in a config are refused, never resolved. The walk has a budget per call, and no
  `rust-toolchain` file may be in the working directory or above it. Your own cargo home config
  counts only when it sets nothing that runs.

  Code that source pulls in by itself, such as `#[path]`, `include!` or a symlinked `build.rs`, is
  the workspace sandbox's to stop, not this rule's. Anything else goes to the judge. `check`,
  `clippy`, `build` and `test` write the target directory, so a rule-approved one runs under the
  workspace sandbox profile when the workspace switch is on, and under the reader profile (where
  the build cannot write `target/`) when it is off. `fmt --check` stays on the reader.

#### Cycling approval from the keyboard

**Shift+Tab** flips approval between `ask` and `auto`, and the flip is journaled as a `mode_switch`
from surface `key`. From `bypass` it goes to `ask`. Scope and layers are kept.

* In the `lain input` pane it flips at once, even with no prompt open.
* In a chat running in your own terminal it flips only at its prompts. A Shift+Tab typed ahead
  while a run is in flight is dropped, not replayed later. A flip redraws the open prompt's header.
* Known gap: after a paste that contains Shift+Tab, the pane row shows `^[[Z`.

In the editor, `:LainMode ask|auto|bypass` sets the level from any buffer and journals a
`mode_switch` from surface `nvim`; any other word is refused in the editor. Known gap: it does not
redraw an open terminal prompt's header, so the next prompt shows the new level.

The key is a property of your terminal, so it is set only in the user-level config
(`$XDG_CONFIG_HOME/lain/config.rb`, after `lain trust --user`), with a `keys` verb that takes
`approval_cycle:`, as in `keys approval_cycle: "S-Tab"`. Its value is `"S-Tab"`, the only key that
works today; the configured key drives the prompt, the typeahead sweep and the pane. A project's
`.lain/config.rb` that says `keys` is refused as a verb only the user's file may use.

A key you declare is checked at launch and refused with the file and line when lain holds it (`C-x`
and `Tab` completion, `C-g` compose) or the line editor already holds it: every other `C-<letter>`,
and `S-Tab` itself if your inputrc binds `\e[Z`. Leaving `keys` out never fails: with no
declaration the default `S-Tab` is bound if it can be, and the chat says so when it cannot.

#### `plan` scope

`plan` scope confines where a tool writes and is not a sandbox. It checks the location a tool
names: `write_file`/`edit_file`'s path, `bash`'s `cwd`. It refuses anything outside the spike by
name, pointing at `/mode checkout`. A human-approved shell command's own words can still write
elsewhere. Leaving `plan` keeps the spike's branch if it carries commits and deletes it if it
does not, saying which.

A scope move is refused while a turn is in flight, since a running tool call may be writing where
the session's writes would stop landing: wait, or `/stop`. `/mode !` is the exception: it lands
everything but the scope immediately, because dropping `bypass` is the part that cannot wait, and
says the scope move waits for the turn to end.

`manual` and `accept_edits` are retired and are refused as unknown tokens. The `auto_approve` layer
is gone too, and `+auto_approve` is an unknown layer: asking a model first is what `auto` does.

#### Where a researcher works, and how to clean up

A chat's researcher subagent gets its own directory, whatever `--isolation` says, and keeps
it. It can run commands (`bash`, with its working directory in the lease) and write files there,
and it cannot write outside it: a write aimed at the project is refused naming the lease.
A researcher a role skill spawns (`@researcher[/skill]`) gets a kept scratch lease of its own (a
role skill cannot name `extends`), refuses a write outside it the same way, and asks approval as
`researcher`. Either way, a researcher's first message names its working directory and the
project's path, so it reads project files by absolute path.

| What | Where |
|---|---|
| Scratch, the default | `$XDG_STATE_HOME/lain/research/<project_hash>/scratch/research-*` |
| A spike, when the spawn names `extends` | `$XDG_STATE_HOME/lain/research/<project_hash>/worktrees/<hash>`, on branch `lain/plan/<key>` |
| A spilled answer, from any child, when its answer is over 16 KiB and no summary of it can be delivered | `$XDG_STATE_HOME/lain/answers/<project_hash>/<stamp>-<hex>.md`, with `.summary.md` beside it when the child gave one |

`$XDG_STATE_HOME` is `~/.local/state` when unset. A spike is cut from the project or one of its
related directories, and commits there land on its branch. Under `plan` scope the researcher is
lent the session's own spike instead, and nothing new is cut.

**Nothing removes these.** `lain worktrees gc` leaves them alone on purpose. To clean up, delete
the scratch directories, and for a spike run `git worktree remove <path>` from the project, then
`git branch -D lain/plan/<key>` and `git update-ref -d refs/lain/owned/heads/lain/plan/<key>`.
The branch pass of `gc` may delete a merged branch that no worktree has checked out.

### /stop

`/stop` stops the ask in flight and keeps the session. The run's task is interrupted, a
`run_interrupted` record is written with reason `stopped`, no `session_closed` is written, and
the prompt comes back as `you>` in the same conversation.

Whenever an ask is running, the input rail answers `/stop` instead of the command registry, so it
works from a prompt a run is waiting on (a `[y/N]` or a `human>`) as well as from `you>`. With
nothing running there is nothing to intercept and the command answers instead:
*"no ask is running -- /stop at the prompt it parks on, or s at a countdown"*.

An epic run is stopped the same way. While `/implement-epic` drives issues, `/stop` halts the run:
each issue it ends is named (`stopped epic issue <id>`), a stop that finds no issue running still
halts the run and prints `stopped the epic run`, and the loop launches nothing further. An issue
stopped mid-run is left unsettled and ungated; its work is kept on its ref at the sha that was
anchored, its checkout is released, and the next run starts a fresh attempt and does not resume
it. An issue whose gate was already asked is reported as abandoned, and nothing lands.

The countdown's `s` key is the same gesture: Ctrl-C opens the grace window, and `s` there stops
the ask while `c` cancels the countdown, `w` extends it and `r` waits for responses. An idle
`you>` countdown offers only `c` and `w`, since there is no ask to stop.

Every stopped ask says why. The reason recorded on `run_interrupted` is one of `stopped`,
`ceiling`, `over_window`, `transport`, `stalled_stream` and `torn` (plus `interrupted` and
`grace_expired`, which come from Ctrl-C and the shutdown window rather than from an ask).

### /rewind

`/rewind` moves the session back one turn. `/rewind N` moves back N. `/rewind <digest>` moves to a
recorded turn. The Timeline is content-addressed, so nothing is destroyed and the old head stays
reachable.

The todo list follows the chain: rewinding past a `todo_write` drops that list from the next request, and a list written on the kept chain stays in force. The same holds for a replay and for `--fork`.

**A prompt left unanswered at the head goes out again with your next one.** A failure after the
request reached the provider, a Ctrl-C or [`/stop`](#stop), a failed resend, or a `/rewind` that
lands on a prompt all leave a prompt with no answer on the chain. The next thing you ask is sent
as 1 turn carrying both texts, cut from that prompt's parent (not as a second prompt stacked
beside the first), and the chat says so before the wire:

> the prompt at the head has no answer on this chain, so this ask carries it too -- /rewind 1
> before asking to leave it out

`/rewind 1` is the way out, and the warning names it.

A prompt that provably never reached the provider is withdrawn, so it does not come
back. Exactly 2 shapes qualify: every connection refused before the request was sent, and a
prompt the provider refused whole for not fitting its context. Anything else is kept.

### /undo

`/undo` puts back the files the last file-changing turn wrote. `/undo skip` drops that turn without
restoring anything, so the next `/undo` reaches the turn before it. Run it again to walk further
back.

**It reverts that one turn's own paths.** A snapshot is a delta, so undo restores each path the
turn added, changed or deleted and never touches a path the turn did not name. The conversation is
untouched; [`/rewind`](#rewind) moves that.

What it will not do, always refusing by name and before anything moves:

| It refuses when | Because |
|---|---|
| a turn is still in flight, or a supervised worker is still running | a parked tool call could write after the files were put back |
| a path changed since that turn | your later edit is not undo's to discard |
| a path was first written in that turn under the write-set scope | nothing recorded what it held before |
| a path is a symlink, is `.gitignore`'d, sits outside the project root, or is inside a nested repository | undo neither follows nor restores those |

A refusal changes nothing at all and names every path it choked on, so the remedies are to put those
back by hand and `/undo` again, or to `/undo skip` that turn entirely.

Scope decides how much was recorded. Under the shadow-git scope a turn's change is the whole
tree diff, so a file a `bash` command wrote is restored like any other. Under the write-set scope
only lain's own tools are recorded, and the reply says so: *"Only files lain's own tools wrote were
restored: that turn ran under the write-set scope, which records nothing a shell did."*

### /pin

`/pin` marks a turn so compaction may not elide it. Bare `/pin` takes the last assistant turn;
`/pin <digest>` takes the turn a digest prefix names, resolved against this session's chain.

Unlike `/rewind`, `/pin` takes no turn count: its argument names a turn. A prefix must be at
least 4 characters, so a count-shaped `/pin 3` is refused and never resolves against a digest
that happens to start with `3`.

Pins live on the session and are journalled, so they survive `--resume`.

### /unpin

`/unpin` releases a pin, taking the same argument grammar `/pin` does. A turn that was not pinned
says so rather than reporting a release.

### /label

`/label [<digest>] <text>` names a turn, the last one by default, and the name survives `--resume`.
A leading word of 4 or more hex characters (or a `blake3:` prefix) that a turn's digest starts with
names that turn; a prefix 2 turns share is refused, as `/pin` refuses it. A label with no text
clears the turn's label, so a lone word that a turn's digest starts with, such as `/label beef`,
clears that turn rather than labeling the last one.

### /park

`/park <text>` leaves a re-entry note for when you come back: what you are waiting on and what to do
next. It is journaled in the session record, the latest note wins, and `lain chat --resume` prints it
first, as `parked: <text>`. A fork carries the note too. `/park` with no text clears it.
Parking also sends `parked: <text>` to the morning feed at once and, in a herdr pane lain reports to, sets
the `lain_parked` token on that pane; clearing the note clears the token and sends nothing.

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

A question arrives as a set: one `ask_human` call carrying one question or several, each with a
markdown body, a closed list of options, and how many of them you may pick. Every row is
attributed to the agent that asked it, so a subagent's question is answerable without knowing
which agent is stuck.

`/inbox` lists every pending row, then prints the document of the set it is about to answer and
reads one reply. A typed reply answers the whole set in prose. The model is told the human
answered in prose and not by selection, and your words are blockquoted so nothing you type can be
read as a choice. That is the terminal's only gesture, and it stays available whether or not an
editor is attached.

Ticking boxes is the editor's. With `--nvim`, `<CR>` on an inbox row opens the set in
`lain://question` as a folded markdown document: `x` ticks the option under the cursor, 2-space
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

A call that reads secrets (a file holding a sensitive region, or files lain cannot name or scan
whole) runs contained on a plain `y`, where files lain masks read as empty (a Rails key pair as a
decoy that decrypts to empty credentials) and it has no network, and its `[y/N/network]` prompt
says so. Under `--confine workspace`, a build tool's fetch that earns its ports (such as `cargo
fetch`) keeps them while contained, and the prompt names those ports instead of saying it has no
network.

Answer `network` (or `approve network`, or `:LainApprove network` in nvim) to run it unconfined as
before, with network, which a `git push` needs. A note never chooses network. Where lain cannot
contain the call, a plain `y` is refused and the row says to answer `network`; with `--confine off`
or `--confine classes` the row says the call will run unconfined. The phone keeps approve, hold and
deny, and its approve runs contained.

### /deny

`/deny <reason>` refuses a parked call and hands your reason to the agent as the last clause of its
tool result. With 1 call parked it is denied at once. With several, each is asked `[y/N]` in turn
through the prompt `/approve` uses, with the reason offered on that call while it is asked, so a
bare `n` at any prompt about it carries the reason.

The walk ends at the first deny it made, and a call another surface decided meanwhile does not
count. The outcome line names who decided and which call (the call cut at 60 characters). With
nothing parked it says so. Like [`/approve`](#approve), `/inbox`, `/held` and [`/stop`](#stop), it
runs while the agent works and does not wait behind it as a typed line.

### /held

`/held` lists the lines you typed while nothing was reading them, each waiting for its turn at `you>`. `/held clear` drops them.
Any other argument is refused. It runs while the agent works.

### /clear

`/clear` restarts the chat fresh in the same `lain up` cockpit pane. It quits the chat through its
normal exit, so leases, parked approvals and the session record close, and a tmux job respawns the
pane once the chat is gone, dropping `--resume` and `--fork`. The new chat starts on a new session
file with the same epic mounted and the input and editor panes left standing.

It is refused at a reply prompt before anything is armed, arms at most 1 restart, and stays in the
chat, saying why, if tmux cannot set the restart up. Outside `lain up` it refuses and points to
`/rewind 0`, which empties the context in place.

### /resume

`/resume [<session>]` restarts the `lain up` cockpit chat on a session, in place, the way [`/clear`](#clear) restarts it fresh:
the chat quits through its normal exit and the pane respawns with `--resume <session>`.

With no name it takes the newest session
other than this one, if that session was never closed and its writer is gone; older sessions are not searched. A session still
open in a running process is refused before anything quits, naming the process. Outside `lain up` it refuses and points to
`lain chat --resume <session>`.

### /release

`/release <path>` forgets this run's decline or lapse for a file, so the model's next read of it
parks on the release prompt again instead of returning the masked copy. A relative path resolves
against the chat's working directory. It answers with how many declined or lapsed regions it
forgot, or says nothing was declined for that path.

A file under a related directory is refused by name: its regions are masked without ever asking,
so there is no decline to forget.

### /share

```
/share
```

Publishes this chat's session as a secret gist through `gh gist create --public=false`: the HTML
export, which rewrites the home directory and project root. It takes no argument; the `--jsonl`
record is local only (see [`lain export`](#lain-export)). The bytes are the model's masked view, never a
re-scan, so a masked region stays its `<redacted:n>` placeholder. The reply names the file, the gist
URL and how many regions were masked, and the journal records a `session_shared` entry.

A session that released a read in clear is refused, naming how many regions were released and pointing
at [`lain export`](#lain-export) for a local copy. It needs `gh` on `PATH` and logged in; without it the
reply says so and nothing is sent. A chat started with `--no-journal` has no session file to share.

A secret gist is unlisted, not private: anyone holding the URL can read it.

### /survey

`/survey <path>` opens a survey of a directory in the editor this chat is already attached to: the
round the text-mode survey command prints, drawn in the cockpit with this
chat's gesture rails bound to it. Its usage line:

```
/survey <path> [--scope cumulative|commits|by_directory] [--unbounded] [--permissive]
```

The scope names in that line are filled in from the registered partition strategies, so the
usage lists whatever is registered.

It reads 3 flags: `--scope`, `--unbounded` and `--permissive`. `--permissive` chooses the rule a verdict is judged under (it forgives rows nobody read
and still refuses an objection nobody answered), and only the cockpit submits a verdict. Anything
else beginning with `--` is refused by name and is not read as a path. A declared flag whose value
is missing gets its own refusal, because the remedy differs.

Without an editor it refuses: a survey nothing drew and no gesture could reach is the failure the
review surface was written against. The refusal names `lain up --nvim` (or
`lain chat --nvim <socket>`) as the way to get one, and nothing else opens one.

**A survey opens 2 windows: `sidebar | file`.** There is no diff pair, because a corpus has no
base revision and nothing to put on an old side. A changeset review opens 3, `sidebar | old | new`.
The `old` slot stays in the layout's vocabulary either way, and a survey opens it on demand, which
is what keeps `:LainThread` working there.

The banner lain prints on opening teaches the motion for the round it drew: 1 `<C-w>l` from the
sidebar to the file on a survey, 2 on a changeset review.

One chat draws one review at a time. A `/survey` over an open changeset review is refused,
naming the one already open; a `/survey` over an open survey rebinds, which is how you take
a second look at a tree.

There is no `/survey-submit`, because a corpus has no pull request under it. A drawn survey is
held all the same, so [`/review-submit`](#review-submit) names the survey and does not claim
nothing is open.

### /review

`/review <pull-request|branch>` opens a changeset review in the attached editor. Its usage line:

```
/review <pull-request|branch> [--base <ref>] [--since <sha>] [--scope cumulative|commits|by_directory] [--permissive] [--critique[=FOCUS]]
/review close
```

`--critique` is written bare or as `--critique=FOCUS`; the space form (`--critique focus`) is
refused. The focus runs to the end of the line and takes `/critique`'s own options (`critics=`,
`model=`), so put it last. The critique runs as `/critique` does, so `/stop` reaches it. A refusal it can only find
after the review opens (an unserved model, no window, a chunk past the room) leaves the review open, with
the error line under the headline. At a reply prompt `/review --critique` is refused before it opens a round;
a plain `/review` still runs there.

Same editor rule as `/survey`: no editor is a refusal, not a Null surface. Same one-surface rule
too, from the other side.

**`/review close` lets the open round go without a verdict.** It takes nothing after it:
`/review close --base main` is either a typo or a review of a branch called `close`, and guessing
would do one of them wrongly, so it refuses and says that a branch named `close` is reviewed as
`refs/heads/close`. In a repository that really has such a branch, that hint is printed beside
whatever the close answers. A round that already carries a verdict refuses, and so does one already
closed. The close journals a `changeset_closed` record naming who closed it, `human` or `refusal`.

The `refusal` half is the other half of the same gesture: a round bound and then refused (a ceiling
refusal, say) is closed on the way out, so a refused round binds nothing. The rails unbind, the
outbox is released, and the refusal is what you are told, so the surfaces do not stay bound over a
round nobody will ever see. `:LainReviewClose` is the editor's spelling of the same command.

`--permissive` is accepted here so the partial-review refusal can be answered from a `/review`
round as well as a `/survey` one. Submitting `approve` over a changeset that is not fully reviewed
is refused by naming the rows that are outstanding (the first few, then a count of the rest) and
offering 2 remedies: mark each row reviewed with `x` in `lain://review`, or re-open the review with
`--permissive` if this run means to judge regardless. A command that could not read the flag would
name a remedy unreachable from the very review that refused.

`--since <sha>` is for pull requests: it shows only the commits after `<sha>`, so a re-review
reads what changed since your last look. A branch refuses it and names `--base`. When `<sha>`
is not an ancestor of the head, as after a force-push, the round shows the whole pull request
and its banner says so. Comments are still placed against the whole pull request when the
round is posted, so a comment on a line the whole pull request does not change goes into the
review's body rather than inline.

### /review-submit

`/review-submit [summary]` posts the open changeset review to its pull request, once.

There is no retry: an accepted POST creates a review every time, so a GitHub refusal is raised
loudly and nothing tries again. A review that did not land must not read like a line of success.

A survey has nowhere to post. That is a modelled outcome and not an error, so this command names
the survey instead of claiming nothing is open.

### /goal

`/goal <objective>` drives the agent toward a standing goal until it signals done. `/goal off`
clears it.

### /implement-epic

`/implement-epic` works the mounted epic's approved issues to its working branch. Each issue runs as
its own actor in a worktree cut from `epic/<slug>`, rebases itself, and lands serially through one
queue; the issue graph and the live fleet are drawn in [`lain://status`](cockpit.md),
the fleet as a tree with each issue's own children nested under it.

```
/implement-epic [SLUG] [--width N]
```

`--width` is the only flag, and it takes a whole number above zero: how many issues may be in flight
at once. It defaults to 2. Anything else is refused by name.

The epic comes from `lain chat --epic SLUG`. A SLUG typed here must name that epic, and any other
is refused naming the mounted one. Before an unattended run, know 2 properties:

- It stops between issues when the session is closing. The loop asks the conductor whether it is
  closed before each issue and while waiting on a gate, so a Ctrl-C stops the run at the next
  boundary instead of mid-merge. Work already in flight is reported as unsettled rather than
  abandoned silently.
- It is not bounded by a model-turn ceiling. `/implement-epic` never enters an agent `ask`, so
  neither [`/goal`](#goal)'s 5-iteration cap nor an agent's own 25-iteration tool-loop ceiling
  applies to it. Its bound is issues, and by default there is no issue budget at all: it runs until
  the epic is done, it is interrupted, or an issue stops it.

A refusal stops that issue and not the whole run.

### /ruby

Inspect live state. Bare opens a console, an expression prints its `inspect`, a path reads a file.

### /meta

`/meta <prompt>` generates a customized harness script into `.lain/meta/`. Review it, then
`/meta run <slug>`.

`/meta summarizer <prompt>` generates a summarizer declaration into `.lain/summarizers/`.
Nothing loads that directory: the catalog loads the single file `.lain/summarizers.rb`, so review
the generated file and copy the declaration into it yourself. A summarizer is loaded and never
launched: there is no run verb for it, and `/meta run` cannot reach one.

### /quit

End the session. Same as a bare `quit`.

---
