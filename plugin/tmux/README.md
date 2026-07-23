# lain tmux plugin

Puts lain's HUD in any tmux status bar and binds prefix keys for the two
tmux-native lain gestures — without `lain up`'s managed session. It reads the
same `.lain/state.json` that `Lain::StatusFeed` publishes (three keys:
`cache_deadline`, `fleet`, `inbox_count`), resolved against the **active
pane's** working directory, so the segment always describes the project you
are looking at.

## Install

Add to `~/.tmux.conf` (options first, `run-shell` last), then reload with
`tmux source-file ~/.tmux.conf`:

```tmux
set -g status-right "#{lain_status} | %H:%M"
run-shell /path/to/lain/plugin/tmux/lain.tmux
```

`lain.tmux` rewrites every `#{lain_status}` placeholder in `status-left` /
`status-right` into a `#('scripts/lain-status' #{q:pane_current_path})` job —
the tpm interpolation idiom, so it composes with any theme. The
`#{q:...}` shell-quote modifier is what keeps a pane whose path contains a
quote or a space from breaking (or worse, injecting into) the status shell.

**If the plugin's own path contains spaces**, quote it *inside* the
`run-shell` argument — tmux passes that argument to `sh -c` without
re-quoting, so it word-splits otherwise:

```tmux
run-shell "'/path/with spaces/lain/plugin/tmux/lain.tmux'"
```

## What you get

- **`#{lain_status}`** renders `🔥 fleet:2 inbox:3` — cache warmth (🔥 while
  the provider's cached prefix is still inside its sliding TTL, ❄ after),
  subagent fleet size, and how many questions await you. With `jq` on PATH it
  uses the exact filter `lain up` uses; without `jq` it degrades to the raw
  JSON; with no state file yet it prints `lain: no state yet`. Never blank,
  never an error.
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

tmux ≥ 3.2 (`display-popup`); `jq` optional but recommended. The plugin is
pinned by `spec/plugin/tmux_plugin_spec.rb`.
