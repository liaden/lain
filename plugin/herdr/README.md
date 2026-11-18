# lain herdr plugin

herdr is a terminal multiplexer that shows each coding agent's state. lain reports its own panes
to it (`lib/lain/herdr/`), and with this plugin linked, `/fork`, `/btw` and the fleet windows open
as herdr tabs. Without the link they open in tmux.

## What it declares

`herdr-plugin.toml` names the plugin `lain` (needs herdr 0.9.5 or newer) and declares one pane,
`run`. herdr closes a pane the moment its command exits and reports no status, so the pane's script
runs `$LAIN_RUN_COMMAND`, writes the exit status to `$LAIN_RUN_STATUS`, and holds a failed pane open
when `LAIN_KEEP_FAILED=1`. `lib/lain/cli/herdr_surface.rb` reads that status file back.

## Install

```bash
lain herdr link       # herdr plugin link <lain>/plugin/herdr
lain herdr unlink     # herdr plugin unlink lain
lain herdr status     # herdr plugin list
```

`link` records a link to this folder, so an upgrade of lain is picked up without linking again. It
needs `herdr` on `PATH` and is the only lain command that writes to herdr's configuration.
The code is `lib/lain/cli/herdr_link.rb`.

## Commands that use it

- `/fork`, `/btw` and the fleet windows pick herdr over tmux when the chat is in a herdr pane and
  the plugin is linked (`lib/lain/cli/window_surface.rb`). Otherwise the chat says that
  `lain herdr link` would open them in herdr.
- `lain daemon herdr-sync` shows the live runs on the `lain` workspace.
- `lain queue open` starts a `review <dir>` workspace running `lain up --nvim` when run inside herdr.
- `lain queue poll` sets the `reviews` token in the herdr sidebar.

See [docs/users/commands.md](../../docs/users/commands.md) for each command's full behavior.
