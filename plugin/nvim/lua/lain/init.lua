-- The lain nvim plugin: the CONVENTIONS around lain's editor frontend, and
-- nothing that belongs to the wire. Everything protocol-shaped -- the lain://
-- buffers, the :LainSend/:LainReply/... commands, all RPC -- is injected by
-- the gem's runtime.lua at attach (protocol 3), so this module must never
-- define buffer logic or RPC handling: a bare `nvim --listen` with no plugin
-- attaches identically (zero-install is the contract, this plugin is sugar).
-- What lives here instead:
--
--   * the deterministic per-project server socket, served on VimEnter
--     (ported from the reference dotfiles autocmd -- see start_server)
--   * lain.socket_path() / lain.status() -- read-only conveniences
--   * :LainStart -- a window layout over the runtime-injected buffers
--
-- doc/lain.txt documents the full v3 attach contract (User Lain* events,
-- lain* highlight groups) as this plugin's users consume it.
local config = require("lain.config")

local M = {}

-- The last User LainAttach payload, recorded by setup()'s listener; nil
-- before any attach (or when the attach predated setup -- see
-- attached_buffers' fallback).
M._attach = nil

-- The XDG base directory spec says a non-absolute XDG_RUNTIME_DIR is invalid
-- and must be ignored -- the same rule the gem's Ruby side applies -- so a
-- relative value falls through to /tmp rather than minting a cwd-relative
-- socket dir.
local function runtime_base()
  local xdg = vim.env.XDG_RUNTIME_DIR
  if xdg and xdg:match("^/") then
    return xdg
  end
  return "/tmp"
end

-- The GLOBAL cwd (getcwd(-1, -1)), never the window-local one: :lcd in some
-- window must not fork the socket identity away from the one VimEnter served
-- (panel probe a). Note this is the kernel-resolved cwd -- symlinked project
-- paths hash post-resolution.
local function project_cwd()
  return vim.fn.getcwd(-1, -1)
end

-- The deterministic per-project socket path. Pure: no directory or file is
-- created here (start_server owns the side effects). A project carrying a
-- `.lain/` directory owns its socket in-tree (`.lain/nvim.sock`, the same
-- "beside the project, like .git/" convention as state.json); every other
-- project gets $XDG_RUNTIME_DIR/lain/nvim-<sha256(cwd)[:12]>.sock -- so lain
-- (and any other tool) can find this editor from the cwd alone.
function M.socket_path()
  local conf = config.current()
  if conf.socket then
    return conf.socket
  end
  local cwd = project_cwd()
  if vim.fn.isdirectory(cwd .. "/.lain") == 1 then
    return cwd .. "/" .. conf.project_socket
  end
  local dir = conf.socket_dir or (runtime_base() .. "/lain")
  return ("%s/nvim-%s.sock"):format(dir, vim.fn.sha256(cwd):sub(1, 12))
end

-- Faithful port of the reference reclaim logic (the only tested one): first
-- instance in a project wins the socket; a socket left by a crashed instance
-- is reclaimed (a live one answers sockconnect, a stale one refuses). Known
-- and accepted, same as the reference: two instances starting at the same
-- instant can race between the probe and serverstart -- the loser's
-- serverstart fails inside pcall and it simply serves no socket, a benign
-- outcome. Do not add locking here.
local function start_server()
  local sock = M.socket_path()
  -- 0700 (448): the runtime base may have fallen back to world-readable /tmp,
  -- and a socket dir is per-user state. Applies only to dirs created here.
  vim.fn.mkdir(vim.fs.dirname(sock), "p", 448)
  local stat = vim.uv.fs_stat(sock)
  if stat then
    local ok, chan = pcall(vim.fn.sockconnect, "pipe", sock)
    if ok and chan > 0 then
      vim.fn.chanclose(chan)
      return -- another live instance owns this project's socket
    end
    -- Reclaim only ever deletes a SOCKET: anything else parked at the path
    -- (a user's regular file -- panel probe b1) must survive, and that means
    -- RETURNING, not falling through -- nvim's serverstart does not fail on
    -- an occupied path, it unlinks and binds over it (verified on 0.12.4),
    -- so "let serverstart fail" would destroy the file anyway. os.remove's
    -- own failure is unchecked on purpose: serverstart then fails inside its
    -- pcall and this instance simply serves no socket, the documented
    -- degrade mode.
    if stat.type ~= "socket" then
      return
    end
    os.remove(sock)
  end
  pcall(vim.fn.serverstart, sock)
end

-- The tmux HUD's state feed, read back: the gem's StatusFeed publishes
-- .lain/state.json atomically (write-to-tmp + rename), so a read never sees
-- a half-written file. Returns the decoded table, or nil when no session has
-- published state -- and nil too on bytes that do not parse, treated as
-- absence rather than an error (the reader polls; the next publish heals it).
function M.status()
  local path = config.current().state_path
  if not path:match("^/") then
    path = project_cwd() .. "/" .. path
  end
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local bytes = file:read("*a")
  file:close()
  -- vim.NIL maps to plain nil: a file holding literal `null` is "no state",
  -- and callers should get the same nil as for a missing file.
  local ok, decoded = pcall(vim.json.decode, bytes)
  if ok and decoded ~= vim.NIL then
    return decoded
  end
  return nil
end

-- The buffers eligible for layout: the LainAttach payload when our listener
-- saw the attach; otherwise (attach predates setup) the lain:// buffers that
-- actually exist -- READING names is fine, creating buffers would be the
-- runtime's job. nil when no attach has happened at all
-- (vim.g.lain_rpc_version is set by every attach, plugin or not).
local function attached_buffers()
  if M._attach then
    return M._attach.buffers
  end
  if not vim.g.lain_rpc_version then
    return nil
  end
  local names = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name:match("^lain://") then
      table.insert(names, name)
    end
  end
  return names
end

-- config.layout filtered to buffers the runtime has actually created: the
-- attach payload names buffers lazily, so a view that has not primed yet is
-- skipped, never conjured. Empty columns drop out entirely.
local function existing_columns(buffer_names)
  local present = {}
  for _, name in ipairs(buffer_names) do
    present[name] = true
  end
  local columns = {}
  for _, column in ipairs(config.current().layout) do
    local bufs = {}
    for _, name in ipairs(column) do
      local buf = vim.fn.bufnr(name)
      if present[name] and buf ~= -1 then
        table.insert(bufs, buf)
      end
    end
    if #bufs > 0 then
      table.insert(columns, bufs)
    end
  end
  return columns
end

-- A new tab, columns left to right (full-height vsplit), buffers within a
-- column top to bottom.
local function open_layout(buffer_names)
  local columns = existing_columns(buffer_names)
  if #columns == 0 then
    vim.notify("lain: no lain:// buffers to lay out yet", vim.log.levels.WARN)
    return
  end
  vim.cmd("tabnew")
  for i, column in ipairs(columns) do
    if i > 1 then
      vim.cmd("botright vsplit")
    end
    for j, buf in ipairs(column) do
      if j > 1 then
        vim.cmd("belowright split")
      end
      vim.api.nvim_win_set_buf(0, buf)
    end
  end
end

-- :LainStart. Attached already: lay out now. Not yet: arm a one-shot
-- LainAttach hook so the layout opens the moment `lain chat --nvim` lands
-- (re-running :LainStart before that just re-arms the same hook -- the
-- cleared augroup keeps it single).
function M.start()
  local buffers = attached_buffers()
  if buffers then
    open_layout(buffers)
    return
  end
  vim.api.nvim_create_autocmd("User", {
    pattern = "LainAttach",
    once = true,
    group = vim.api.nvim_create_augroup("lain_plugin_start", { clear = true }),
    callback = function(ev)
      open_layout(ev.data.buffers)
    end,
  })
  vim.notify("lain: not attached yet -- layout opens when `lain chat --nvim` attaches", vim.log.levels.INFO)
end

-- Same delete-then-define convention as the runtime's own commands, so a
-- reload (or plugin file + setup both running) never stacks duplicates.
function M.define_commands()
  pcall(vim.api.nvim_del_user_command, "LainStart")
  vim.api.nvim_create_user_command("LainStart", function()
    M.start()
  end, { desc = "lain: open a window layout over the attached lain:// buffers" })
end

local function install_attach_listener()
  vim.api.nvim_create_autocmd("User", {
    pattern = "LainAttach",
    group = vim.api.nvim_create_augroup("lain_plugin_attach", { clear = true }),
    callback = function(ev)
      M._attach = ev.data
    end,
  })
end

-- The entry point: record opts, define :LainStart, listen for attaches, and
-- serve the socket. Serving happens ON VimEnter -- or immediately when
-- VimEnter has already fired (a lazy-loading plugin manager calls setup
-- after startup), so "call setup, get a socket" holds either way.
--
-- Re-running setup with a DIFFERENT socket config serves the new path but
-- keeps the old one listening (nvim's serverstart is additive and no
-- bookkeeping unwinds it here) -- accepted: re-setup is a config-reload
-- shape, not a lifecycle we manage.
function M.setup(setup_opts)
  config.set(setup_opts)
  M.define_commands()
  install_attach_listener()
  if config.current().serverstart then
    if vim.v.vim_did_enter == 1 then
      start_server()
    else
      vim.api.nvim_create_autocmd("VimEnter", {
        group = vim.api.nvim_create_augroup("lain_plugin_server", { clear = true }),
        callback = start_server,
      })
    end
  end
  return M
end

return M
