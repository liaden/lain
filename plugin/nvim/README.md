# lain.nvim

The optional Neovim plugin for the [lain](../../README.md) coding agent.

The plugin is thin. The lain gem injects its own runtime into the editor when
it attaches: every `lain://` buffer, every `:Lain*` command and all RPC. Gem
and editor therefore cannot drift, and a bare `nvim --listen` needs nothing
installed. The plugin adds only the conventions around that contract:

- A deterministic per-project server socket, served on `VimEnter`, so
  `lain chat --nvim` finds your editor from the cwd alone. The path is
  `$XDG_RUNTIME_DIR/lain/nvim-<sha256(cwd)[:12]>.sock`, or `.lain/nvim.sock`
  when the project has a `.lain/` directory. The first instance wins, a stale
  socket left by a crash is reclaimed, and a live one is respected.
- `lain.socket_path()` returns that path. It creates nothing.
- `lain.state_path()` returns the running session's state feed path, under
  `$XDG_STATE_HOME/lain` (or `$HOME/.local/state/lain`), keyed by the same
  project hash as the socket. It creates nothing.
- `lain.status()` returns the decoded contents of `lain.state_path()`, or `nil`.
- `:LainStart` switches to the one session tab over the injected buffers, or
  rebuilds it if you closed it. Views fill in as they render, and a view you
  close stays closed until the tab is rebuilt. Approvals and questions open
  there, with a notice when you are in another tab.

The plugin has no buffer logic and no RPC handling. Both live in the gem.

## Install

The plugin directory ships inside the gem at `plugin/nvim`. Point your plugin
manager (or `runtimepath`) at it and call setup:

```lua
-- lazy.nvim
{
  dir = "/path/to/lain/plugin/nvim",  -- e.g. `$(dirname "$(gem contents lain | grep -m1 plugin/nvim/README)")`
  config = function()
    require("lain").setup({})
  end,
}
```

You can override every default through `setup` opts or `vim.g.lain_*`. See
`:help lain-configuration`.

## Docs

`:help lain` covers setup, configuration and the socket convention. It also
documents the v3 attach contract, which your own config will care about: the
`User LainAttach` and `User LainRender` events, `b:lain_view` dispatch, and the
`lain*` highlight groups.
