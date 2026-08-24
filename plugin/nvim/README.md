# lain.nvim

The optional Neovim plugin for the [lain](../../README.md) agent harness.

It is deliberately thin. The lain gem injects its own runtime into the editor
at attach time — every `lain://` buffer, every `:Lain*` agent command, all RPC
— so gem and editor can never drift, and a bare `nvim --listen` needs nothing
installed. This plugin only owns the conventions around that contract:

- **a deterministic per-project server socket**, served on `VimEnter`, so
  `lain chat --nvim` finds your editor from the cwd alone:
  `$XDG_RUNTIME_DIR/lain/nvim-<sha256(cwd)[:12]>.sock`, or `.lain/nvim.sock`
  when the project carries a `.lain/` directory. First instance wins; a
  stale socket left by a crash is reclaimed; a live one is respected.
- **`lain.socket_path()`** — that path, computed, nothing created.
- **`lain.state_path()`** — the running session's state feed path, computed
  under `$XDG_STATE_HOME/lain` (or `$HOME/.local/state/lain`) and keyed by the
  same project hash as the socket, nothing created.
- **`lain.status()`** — the decoded contents of `lain.state_path()`, or `nil`.
- **`:LainStart`** — a window layout over the injected buffers (opens on
  attach if lain isn't connected yet).

No buffer logic, no RPC handling — that all stays in the gem.

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

Every default is overridable via `setup` opts or `vim.g.lain_*` — see
`:help lain-configuration`.

## Docs

`:help lain` covers setup, configuration, the socket convention, and — the
part your own config will care about — the v3 attach contract: the
`User LainAttach` / `User LainRender` events, `b:lain_view` dispatch, and the
`lain*` highlight groups.
