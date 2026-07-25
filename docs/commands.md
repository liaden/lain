# Commands

Two command surfaces. `lain <subcommand>` runs from your shell. `/<name>` runs from the `you>`
prompt inside a live session, lib-side, with zero model turns.

Every flag listed here is also in `lain help <subcommand>`, which reads from the same Thor
declarations in `exe/lain`.

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
| `--provider` | `anthropic` | `anthropic`, `ollama`, or `bedrock`. |
| `--model` | the provider's own | Model id. Free-form string, not validated against a list. |
| `--api-base` | Ollama's localhost | Overrides the Ollama base URL. Also moves the compaction summarizer (see [Compaction](#compaction-flags)). |
| `--max-tokens` | `4096` | Per model turn. |
| `--temperature`, `--seed` | unset | Ride `Request#extra`. Ollama honors both; `--temperature 0` is the determinism recipe. |
| `--yolo` | off | Skip the approval prompt for tier-3 (free-form shell) tools. |
| `--auto-approve` | off | Wire an `auto_approver` role that judges pendings the human has not. Races the human and dunst surfaces. |
| `--journal` / `--no-journal` | on | The durable, fsync'd, replayable session record. `--no-journal` also disables `--windows`. |
| `--resume [SESSION]` | off | Bare picks the newest; or give a filename or prefix under this project's session dir. |
| `--fork SESSION@DIGEST` | off | Fork a recorded session at a digest prefix. The parent opens read-only. |
| `--btw` | off | Ephemeral session (`<ts>-<pid>.btw.ndjson`), reaped on clean exit unless promoted with [`/keep`](#keep). |
| `--prompt` | unset | Seed the first question, then read the terminal as usual. |
| `--nvim SOCKET` | off | Attach a Neovim frontend to an `nvim --listen` socket. |
| `--windows` | off | Open a tmux window running [`lain watch`](#lain-watch) per subagent spawn. Needs `$TMUX` and a journal. |
| `--grace` | `60` | Seconds a first Ctrl-C or SIGTERM grants a run before it is stopped. |

#### Compaction flags

Compaction is on by default. See [Compaction and local summarization](../README.md#compaction-and-local-summarization)
for how the two tiers work.

| Flag | Default | What it does |
|---|---|---|
| `--compact` / `--no-compact` | on | Summarize the history's head as it grows. |
| `--compact-bytes` | `262144` | Droppable-head bytes above which a compaction is warranted. Roughly 64k tokens. |
| `--compact-cap` | `1048576` | History bytes that force a compaction even while the prompt cache is warm. |
| `--compact-keep` | `20` | Trailing messages a compaction leaves verbatim. About the last 10 exchanges. |

### lain up

Create or reattach to the `lain` tmux session: a `chat` window plus a session-scoped status HUD.
Flags after `--` are forwarded to [`lain chat`](#lain-chat).

```bash
lain up                                  # chat window + HUD
lain up --nvim                           # split into an nvim pane + a chat pane
lain up --nvim /tmp/lain-abc123.sock     # explicit socket
lain up -- --provider ollama --no-compact
```

| Flag | Default | What it does |
|---|---|---|
| `--session` | `Up::DEFAULT_SESSION` | tmux session name. |
| `--socket` | tmux's default | tmux socket (`-L`). |
| `--nvim [SOCKET]` | off | Split the chat window into an nvim + chat cockpit. Bare derives the per-project socket. |

`lain up` `exec`s into tmux, replacing the process. From inside tmux it uses `switch-client`;
from outside, `attach`.

### lain sessions

List this project's recorded sessions, newest first. Offline.

`--all` includes ephemeral `--btw` sessions, which are hidden by default.

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

Cache warmth, fleet size, and inbox count for this session.

### /sessions

List recorded sessions, newest first. `/sessions --all` includes ephemeral `.btw` ones.

### /model

`/model` shows the model in force. `/model <id>` switches the next turn's model, mid-session.

### /rewind

`/rewind` moves the session back one turn. `/rewind N` moves back N. `/rewind <digest>` moves to a
recorded turn. The Timeline is content-addressed, so nothing is destroyed and the old head stays
reachable.

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

### /approve

Answer each pending tool approval `y/N`.

### /yolo

`/yolo on` auto-approves gated tool calls. `/yolo off` restores the approval queue.

### /goal

`/goal <objective>` drives the agent toward a standing goal until it signals done. `/goal off`
clears it.

### /ruby

Inspect live state. Bare opens a console, an expression prints its `inspect`, a path reads a file.

### /meta

`/meta <prompt>` generates a customized harness script into `.lain/meta/`. Review it, then
`/meta run <slug>`.

### /quit

End the session. Same as a bare `quit`.
