-- Configuration for the lain nvim plugin. Every default is overridable, with
-- precedence (highest first): setup({...}) opts, then vim.g.lain_<key>, then
-- the defaults below. Resolution happens at READ time (config.current()), not
-- at setup() time, so vim.g.lain_* set after setup -- or with no setup at all
-- -- still applies.
local M = {}

M.defaults = {
  -- Relative paths resolve against the editor's cwd. project_socket is only
  -- consulted when `cwd/.lain` is a directory (the project-override trigger).
  --
  -- state_path has NO default here, deliberately. The state feed is machine
  -- state that lain rewrites every turn, so it lives under $XDG_STATE_HOME
  -- keyed by project hash rather than beside the code -- a literal default
  -- cannot spell that, and init.lua's state_path() computes it the same way it
  -- computes socket_path(). Setting the key (setup opts or vim.g.lain_state_path)
  -- overrides that computation and resolves the legacy, cwd-relative way, for
  -- anyone who pinned the retired `.lain/state.json` explicitly.
  project_socket = ".lain/nvim.sock",
  serverstart = true,
  -- :LainStart's window layout: a list of COLUMNS (left to right), each a
  -- list of lain:// buffer names (top to bottom). lain://diff and
  -- lain://workspace are on-demand views, left out of the default.
  layout = {
    { "lain://journal" },
    { "lain://timeline", "lain://inbox", "lain://request" },
  },
}

-- The full key set, listed explicitly because three keys default to nil and so
-- never appear in a pairs() walk over the defaults: `socket` overrides the
-- whole socket-path computation, `socket_dir` overrides only the runtime-dir
-- base ($XDG_RUNTIME_DIR/lain), and `state_path` overrides the state feed's
-- computed location.
local KEYS = { "socket", "socket_dir", "project_socket", "state_path", "serverstart", "layout" }

local opts = {}

function M.set(new_opts)
  opts = new_opts or {}
end

-- `~= nil` (never truthiness): an explicit `serverstart = false` must win.
local function pick(key)
  if opts[key] ~= nil then
    return opts[key]
  end
  local global = vim.g["lain_" .. key]
  if global ~= nil then
    return global
  end
  return M.defaults[key]
end

function M.current()
  local out = {}
  for _, key in ipairs(KEYS) do
    out[key] = pick(key)
  end
  return out
end

return M
