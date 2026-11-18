# lain tmux plugin

The plugin puts lain's HUD in any tmux status bar and binds prefix keys for the
2 tmux-native lain gestures, without `lain up`'s managed session. It reads
the same state feed `Lain::StatusFeed` publishes (`cache_deadline`, `fleet`,
`inbox_count`, and the optional `approvals_pending`, `occupancy`,
`window_guessed`, `mode_lighter`).

The feed is resolved against the active pane's working directory, so the
segment describes the project that pane is in. The exactness this implies is
spelled out below. The context segment reads `ctx:61%`, or `ctx:~61%` when
`window_guessed` says nothing has vouched for the window it was divided by yet.

The feed lives at:

```
${XDG_STATE_HOME:-$HOME/.local/state}/lain/status/<project-hash>/state.json
```

`<project-hash>` is the first 12 hex characters of `sha256(realpath(dir))`.
lain's nvim socket and session store use the same project identifier.
`lain.tmux state-path [DIR]` prints the path, which answers "which file is my
status bar reading" for a directory named by a hash.

## Pane directory

The identity is the pane's exact directory. There is no walk up to a project
root.

A pane in a subdirectory of the project your session started in hashes to
something else and reads `lain: no state yet`. `cd src/` blanks the HUD, and
`cd ..` restores it.

This follows from keying on the pane instead of on one directory chosen when
the plugin was sourced. Keying on a single directory would show another
project's numbers in every pane that had moved, and a wrong number is worse
than an absent one.

If a bar is unexpectedly empty, run `lain.tmux state-path` in that pane and
`lain.tmux state-path <project-root>`. The 2 hashes will disagree.

## Install

Add this to `~/.tmux.conf` (options first, `run-shell` last), then reload with
`tmux source-file ~/.tmux.conf`:

```tmux
set -g status-right "#{lain_status} | %H:%M"
run-shell /path/to/lain/plugin/tmux/lain.tmux
```

tmux cuts `status-right` at 40 columns by default, which hides most of the HUD.
`lain up` raises it to 120 for its own session only. With the plugin, set it
yourself: `set -g status-right-length 120`.

`lain.tmux` rewrites every `#{lain_status}` placeholder in `status-left` and
`status-right` into a `#('lain.tmux' status #{q:pane_current_path})` job. This
is the tpm interpolation idiom, so it composes with any theme. The `#{q:...}`
shell-quote modifier keeps a pane whose path contains a quote or a space from
breaking the status shell, or injecting into it.

The job re-enters `lain.tmux` and does not call `scripts/lain-status`
directly. tmux expands `#{pane_current_path}` per pane, at render time, so
turning a directory into a state file cannot happen when the plugin is
sourced. A path computed then would be wrong in every pane sitting somewhere
else.

`lain.tmux` is bash and does that work on each render. `scripts/lain-status`
is POSIX `sh` and is handed a file. Its contract is to never blank and never
error, and being handed the file means it needs no binary on `PATH`.

If the plugin's own path contains spaces, quote it inside the `run-shell`
argument. tmux passes that argument to `sh -c` without re-quoting, so it
word-splits otherwise:

```tmux
run-shell "'/path/with spaces/lain/plugin/tmux/lain.tmux'"
```

## What you get

- `#{lain_status}` renders `🔥 fleet:2 inbox:3`: cache warmth (🔥 if the
  provider's cached prefix was inside its sliding TTL at the last publish, ❄
  otherwise), subagent fleet size, and how many questions await you.
  `Lain::StatusFeed` publishes that line already rendered, so the plugin
  prints a field and derives nothing. It is the same string `lain up` shows.
  With no state file yet it prints `lain: no state yet`. It is never blank and
  never an error.

  The marker is as fresh as the last publish, which can be older than the last
  `status-interval` tick. A publish happens when lain observes an event, so an
  idle session keeps showing its last turn's marker. Past the provider's cache
  window that marker is wrong in the optimistic direction: 🔥 where the truth
  is ❄. Before the line was pre-rendered, this segment re-evaluated the
  deadline on every tick and was lain's only live warmth indicator. It no
  longer is, and no other surface took over. Read it as how the cache stood
  when lain last did something.
- `prefix + b` opens an ephemeral side-question popup (`lain chat --btw`).
- `prefix + F` forks the session into a new window (`lain chat --fork`).

Both bindings check their binary first and fall back to a `display-message`
when `lain` is not on tmux's PATH.

## Options

Set these before the `run-shell` line:

| Option | Default |
|---|---|
| `@lain_btw_key` | `b` |
| `@lain_fork_key` | `F` |
| `@lain_btw_command` | `lain chat --btw` |
| `@lain_fork_command` | `lain chat --fork` |

The `@lain_*_command` values are embedded in a double-quoted `if-shell`
argument, so keep them free of double quotes. Flags and single-quoted
arguments are fine.

## Requirements

- tmux 3.2 or later (`display-popup`).
- To resolve a pane's directory to its state file, one of `sha256sum`,
  `shasum` or `openssl`. With none of the 3, the HUD reads
  `lain: no state yet` and does not guess.

`scripts/lain-status` itself needs none of them, because it is handed the path.
`spec/plugin/tmux_plugin_spec.rb` pins the plugin.
