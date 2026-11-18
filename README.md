# Lain

Lain is a coding agent for the terminal. It runs its own agent loop against Claude or Ollama, shows
its work in a tmux and Neovim cockpit, and asks before it runs anything risky. You can answer those
questions at the prompt, in the editor, or from your phone.

Every session is recorded, so you can rewind it, fork it, undo its file changes and export it.

## Requirements

- Linux or macOS. CI runs on Linux only, and the phone relay and confined `bash` calls need Linux.
- Ruby 4.0 or newer.
- A Rust toolchain and clang, to build the native extension.
- git 2.44 or newer. Older git ignores the `GIT_NO_LAZY_FETCH` that lain's own git runs under.
- `ANTHROPIC_API_KEY` for Claude, or a running [Ollama](docs/users/providers/ollama.md).

Optional, and lain runs without any of them:

| Tool | What it adds |
|---|---|
| tmux | `lain up`, the status HUD, `/fork` into a sibling window, `/btw` popups, subagent viewer windows. |
| Neovim 0.11+ | The editor pane: live `lain://` buffers, approvals and reviews in the editor. |
| Ollama | A free local model, and local summaries for compaction on any provider. |
| bubblewrap | Confined `bash` calls on Linux. The sandbox is built from what the machine offers. |
| herdr | lain reports each chat's state to [herdr](#herdr) and opens forks as herdr tabs. |
| tailscale and ntfy | [Phone approvals](#phone-approvals). |

## Installation

Lain installs from a checkout.

```bash
git clone https://github.com/joeljohnson/lain && cd lain
bin/setup                        # bundle install
bundle exec rake compile         # builds ext/lain into lib/lain/lain.so
bundle exec rake daemon:build    # optional: the per-user daemon
bin/install-shim                 # writes a `lain` launcher to ~/.local/bin
export ANTHROPIC_API_KEY=sk-...
```

`bin/install-shim` records the Ruby on your `PATH` when you run it, so run it from a shell where
`ruby` is the one you built with. It writes to `~/.local/bin`, which must be on your `PATH`; pass
another directory as its argument to write there. Without the shim, run `exe/lain` from the
checkout.

Without `rake daemon:build` there is no daemon, so no phone approvals and no headless runs.

## Quick start

```bash
lain up                       # the cockpit: editor, transcript and input pane
lain up ~/dev/other-project   # the same, in that project
lain up --no-nvim             # no editor pane
lain                          # only the chat, no tmux
lain up -- --provider ollama  # flags after -- go to the chat
```

`lain up` needs tmux, and plain `lain` does not. Type at the `you>` prompt. Prose goes to the model, `/command` runs a session command without a
model turn, and `@role/skill` starts a skill. `/help` lists both.

## Commands

A few session commands, typed at `you>`:

| Command | Does |
|---|---|
| `/mode` | Show or change what the agent may do without asking. |
| `/approve`, `/deny` | Answer a pending tool call. |
| `/stop` | Stop the running ask and keep the session. |
| `/rewind`, `/undo` | Move back N turns, or put back the files the last turn changed. |
| `/fork`, `/btw` | Branch the session into a new window, or ask a side question in a popup. |
| `/model` | Show or switch the model. |
| `/review`, `/survey` | Review a changeset or read a codebase with the agent, in the editor. |

A few shell commands:

| Command | Does |
|---|---|
| `lain up` | Create or reattach to the cockpit. |
| `lain sessions` | List this project's recorded sessions. |
| `lain export SESSION` | Write a session as 1 HTML page. |
| `lain trust` | Let lain run this project's `.lain/*.rb`, after you have read them. |
| `lain daemon status` | Show the per-user daemon, its sessions and its runs. |
| `lain queue` | List what to review next. |

[docs/users/commands.md](docs/users/commands.md) documents every command and flag. `lain help
<command>` prints the same flags.

## Approvals

A mode is a scope and an approval level, and `/mode` shows or changes both.

Scope says where a named write or command may land: `checkout` (the project) or `plan` (a spike
checkout apart from it). Approval says who answers a gated call. `ask` asks you. `auto`, the
default, asks a model judge first and asks you only when the judge cannot settle it. `bypass`
approves what your rules allow.

Rules live in the `approval` verb of `.lain/config.rb`.
[docs/users/commands.md](docs/users/commands.md#mode) has the details.

## Cockpit

`lain up` opens 1 tmux window with 3 panes: Neovim, the chat transcript, and an input pane under
the transcript. A status line shows cache warmth, running subagents and questions waiting on you.

```
┌─ nvim ──────────────────┬─ chat (transcript) ─────┐
│ lain://journal          │ you> refactor the Store │
│  [a3f grep] 12 matches  │                         │
│                         │ ● read_file store.rb    │
├─ lain://timeline ───────┤ ● grep "def fetch"      │
│  user   refactor the... │                         │
├─ lain://inbox ──────────┼─ input ─────────────────┤
│  2m  which Store impl?  │ 🔥 fleet:2 inbox:1      │
│                         │ you> _                  │
└─────────────────────────┴─────────────────────────┘
```

The editor needs no plugin: lain loads its runtime into a bare `nvim --listen` when it attaches.
[docs/users/cockpit.md](docs/users/cockpit.md) lists the buffers, keys and editor commands. The
[tmux plugin](plugin/tmux/README.md) and the [Neovim plugin](plugin/nvim/README.md) add the status
segment and key bindings outside `lain up`.

## Phone approvals

`lain-daemon` is 1 background process per user, and every chat registers with it. With a relay
address set, a call or question that waits on you also shows in the phone app
([apps/lain-remote](apps/lain-remote/README.md)), and you answer it there. The phone reaches the
relay over tailscale. With an ntfy topic set, the daemon sends a notice when an item has waited 60
seconds.

```ruby
# ~/.config/lain/config.rb
remote relay: "100.64.0.7:7820", ntfy: "http://100.64.0.7:2586/lain-your-long-random-topic"
```

The daemon also supervises headless runs (`lain daemon run epic SLUG`), which have no terminal and
take their answers from the phone.

[docs/users/remote.md](docs/users/remote.md) walks through the setup: the tailscale address, a
self-hosted ntfy, pairing the phone with `lain remote pair`, and what crosses the tailnet.

## herdr

herdr is a terminal multiplexer that shows each coding agent's state. A chat started in a herdr
pane reports whether it is working, blocked or idle. Run `lain herdr link` once and `/fork`,
`/btw` and the subagent windows open as herdr tabs. [plugin/herdr](plugin/herdr/README.md) has the
details.

## Providers

| Provider | `--provider` | Default model | Needs |
|---|---|---|---|
| Anthropic | `anthropic` | `claude-opus-4-8` | `ANTHROPIC_API_KEY` |
| Ollama, local | `ollama` | `qwen3:4b` | `ollama serve` and the model pulled |
| Ollama Cloud | `ollama-cloud` | `gpt-oss:20b-cloud` | `OLLAMA_API_KEY` |

[docs/users/providers/](docs/users/providers/README.md) covers setup and each provider's limits.

## Configuration

Lain runs with no config file. To change its behavior:

- `.lain/config.rb` in a project: approval rules, isolation, secret paths, test layout, middleware.
- `~/.config/lain/config.rb` for yourself: theme, keys, the phone relay.
- `.lain/slots/` and `.lain/skills/`: prompt text and your own skills.

Config files are Ruby, and lain runs them only after `lain trust` has recorded their bytes.
[docs/users/configuration.md](docs/users/configuration.md) is the reference, and
[examples/](examples/README.md) has files to copy.

Long sessions compact on their own. [docs/users/compaction.md](docs/users/compaction.md) explains
the tiers and how to write your own summarizer.

## Debugging

[DEBUGGING.md](DEBUGGING.md) lists where lain keeps its records and the common symptoms.

## Documentation

- [docs/users/](docs/users/README.md): commands, configuration, the cockpit, compaction, providers
  and phone approvals.
- [docs/devs/](docs/devs/README.md): architecture, design, the toolchain and the test suite, for
  people changing lain.

## Contributing

Bug reports and pull requests are welcome at https://github.com/joeljohnson/lain.
[CONTRIBUTING.md](CONTRIBUTING.md) has the setup and the rules. Contributors are expected to follow
the [code of conduct](CODE_OF_CONDUCT.md).

## License

MIT. See [LICENSE.txt](LICENSE.txt).
