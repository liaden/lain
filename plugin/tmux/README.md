# lain tmux plugin

Puts lain's HUD in any tmux status bar and binds prefix keys for the two
tmux-native lain gestures — without `lain up`'s managed session. It reads the
same state feed `Lain::StatusFeed` publishes (`cache_deadline`, `fleet`,
`inbox_count`, and the optional `approvals_pending`, `occupancy`,
`mode_lighter`), resolved against the **active pane's** working directory, so
the segment describes the project that pane is in rather than a fixed one —
with the exactness that implies, spelled out below.

That feed lives at

```
${XDG_STATE_HOME:-$HOME/.local/state}/lain/status/<project-hash>/state.json
```

where `<project-hash>` is the first twelve hex characters of
`sha256(realpath(dir))` — the same project identifier lain's nvim socket and
session store use. `lain.tmux state-path [DIR]` prints it, which is the way to
answer "which file is my status bar reading" for a directory named by a hash.

**That identity is the pane's exact directory, and there is no walk up to a
project root.** So a pane sitting in a *subdirectory* of the project your
session started in hashes to something else and reads `lain: no state yet` —
`cd src/` blanks the HUD, `cd ..` back restores it. This is the cost of keying
on the pane rather than on one directory chosen when the plugin was sourced;
the alternative renders another project's numbers in every pane that has moved,
and a confidently wrong number is worse than an honest absence. If a bar is
unexpectedly empty, `lain.tmux state-path` in that pane against
`lain.tmux state-path <project-root>` shows the two hashes disagreeing.

## Install

Add to `~/.tmux.conf` (options first, `run-shell` last), then reload with
`tmux source-file ~/.tmux.conf`:

```tmux
set -g status-right "#{lain_status} | %H:%M"
run-shell /path/to/lain/plugin/tmux/lain.tmux
```

`lain.tmux` rewrites every `#{lain_status}` placeholder in `status-left` /
`status-right` into a `#('lain.tmux' status #{q:pane_current_path})` job —
the tpm interpolation idiom, so it composes with any theme. The
`#{q:...}` shell-quote modifier is what keeps a pane whose path contains a
quote or a space from breaking (or worse, injecting into) the status shell.

The job re-enters `lain.tmux` rather than calling `scripts/lain-status`
directly, and the split is deliberate. tmux expands `#{pane_current_path}`
**per pane, at render time**, so turning a directory into a state file cannot
happen when the plugin is sourced — a path computed then would be confidently
wrong in every pane sitting somewhere else. `lain.tmux` is bash and does that
work each render; `scripts/lain-status` is POSIX `sh` that is simply *told* a
file, so the one script whose contract is to never blank and never error needs
no binary on `PATH` at all.

**If the plugin's own path contains spaces**, quote it *inside* the
`run-shell` argument — tmux passes that argument to `sh -c` without
re-quoting, so it word-splits otherwise:

```tmux
run-shell "'/path/with spaces/lain/plugin/tmux/lain.tmux'"
```

## What you get

- **`#{lain_status}`** renders `🔥 fleet:2 inbox:3` — cache warmth (🔥 if the
  provider's cached prefix was inside its sliding TTL at the last publish, ❄
  otherwise),
  subagent fleet size, and how many questions await you. `Lain::StatusFeed`
  publishes that line already rendered, so this prints a field rather than
  deriving anything — the same string `lain up` shows, by construction. With no
  state file yet it prints `lain: no state yet`. Never blank, never an error.

  **The marker is as fresh as the last publish, not as fresh as the last
  `status-interval` tick.** A publish happens when lain observes an event, so an
  idle session keeps showing its last turn's marker, and past the provider's
  cache window that is wrong in the optimistic direction — 🔥 where the truth is
  ❄. Before the line was pre-rendered this segment re-evaluated the deadline on
  every tick and was the only live warmth indicator lain had; it no longer is,
  and no other surface took over. Read it as "how the cache stood when lain last
  did something".
- **`prefix + b`** — open an ephemeral side-question popup (`lain chat --btw`).
- **`prefix + F`** — fork the session into a new window (`lain chat --fork`).

Both bindings check their binary first and degrade to a `display-message`
when `lain` is not on tmux's PATH.

## Options

Set before the `run-shell` line:

| Option | Default |
|---|---|
| `@lain_btw_key` | `b` |
| `@lain_fork_key` | `F` |
| `@lain_btw_command` | `lain chat --btw` |
| `@lain_fork_command` | `lain chat --fork` |

The `@lain_*_command` values are embedded in a double-quoted `if-shell`
argument, so keep them free of double quotes (flags and single-quoted
arguments are fine).

## Requirements

tmux ≥ 3.2 (`display-popup`); and, to resolve
a pane's directory to its state file, one of `sha256sum`, `shasum` or
`openssl` — with none of the three the HUD reads `lain: no state yet` rather
than guessing. `scripts/lain-status` itself needs none of them: it is handed
the path. The plugin is pinned by `spec/plugin/tmux_plugin_spec.rb`.
