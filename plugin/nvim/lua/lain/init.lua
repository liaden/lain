-- The lain nvim plugin: the CONVENTIONS around lain's editor frontend, and
-- nothing that belongs to the wire. Everything protocol-shaped -- the lain://
-- buffers, the :LainSend/:LainReply/... commands, all RPC -- is injected by
-- the gem's runtime.lua at attach, so this module must never define buffer
-- logic or RPC handling: a bare `nvim --listen` with no plugin attaches
-- identically (zero-install is the contract, this plugin is sugar).
--
-- No protocol number is quoted here, deliberately. This file said "protocol 3"
-- through five bumps of it, because nothing could tell it had gone stale: the
-- version lives in ONE place (Frontend::Neovim::PROTOCOL) and is stamped into
-- doc/lain.txt, where a spec pins every stamp to that constant. A copy with no
-- guard on it is worse than no copy.
--
-- What lives here instead:
--
--   * the deterministic per-project server socket, served on VimEnter
--     (ported from the reference dotfiles autocmd -- see start_server)
--   * lain.socket_path() / lain.state_path() / lain.status() / lain.hud() --
--     read-only conveniences
--   * :LainStart -- a window layout over the runtime-injected buffers
--
-- doc/lain.txt documents the whole attach contract (User Lain* events, the
-- lain:// buffers, lain* highlight groups) as this plugin's users consume it.
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

-- ONE project identifier, shared by socket_path() and state_path(): the same
-- recipe Lain::Paths#project_hash names, for the same reason -- the socket, the
-- session store and the state feed all key on it, and a project resolves to one
-- identity only if nothing recomputes it its own way. Hashed from project_cwd(),
-- which the kernel has already resolved, matching ruby's realpath-before-hash.
--
-- File-local: this de-duplicates two call sites in this file and has no reader
-- outside it. A function on M is a documented tag in doc/lain.txt and a pinned
-- promise, and an unused public name is a promise nothing holds us to.
local function project_hash()
  return vim.fn.sha256(project_cwd()):sub(1, 12)
end

-- An ABSOLUTE $HOME, or nothing. Ruby's Lain::Paths#home REFUSES a $HOME that
-- is not absolute (Lain::Paths::NonAbsoluteHome) rather than degrading to it,
-- because every XDG fallback is built on it and a relative state path resolves
-- against the process cwd -- which is the project, which is the whole bug the
-- feed was moved out of the tree to fix.
--
-- vim.uv.os_homedir() is libuv's HOME-then-getpwuid lookup, the only passwd
-- fallback this runtime has, and it covers the case vim.env.HOME cannot: a
-- genuinely unset $HOME. It is GUARDED rather than trusted because it reads
-- $HOME first and hands a relative one straight back -- byte for byte the trap
-- ruby's Dir.home sprang on the same code.
local function home_dir()
  local home = vim.env.HOME
  if not (home and home:match("^/")) then
    home = vim.uv.os_homedir()
  end
  if home and home:match("^/") then
    return home
  end
  return nil
end

-- The one rule ruby's File.join has that a `..` concatenation does not: it
-- strips exactly ONE trailing separator from a component. `/x/s/` joins to
-- `/x/s/lain`, `/x/s//` to `/x/s//lain`, and a bare `/` to `/lain`. POSIX
-- collapses a doubled separator, so getting this wrong renders the same file --
-- but state_path() below claims to be byte for byte ruby's answer, and a claim
-- that is only true for canonical input is a claim that is untested where it is
-- false. An operator's `export XDG_STATE_HOME=$HOME/.local/state/` is canonical
-- input to everything except a string comparison.
local function unslashed(base)
  return (base:gsub("/$", ""))
end

-- `<base>/lain`, mirroring Lain::Paths#state_home: $XDG_STATE_HOME when it is
-- absolute, else $HOME/.local/state. Unlike runtime_base() (no $HOME branch --
-- /tmp is fine for ephemera) state is durable and needs a home, so this is the
-- one path that can fail to resolve at all. Lazily, and that matters: an
-- absolute $XDG_STATE_HOME never consults $HOME, so a session whose state
-- resolves fine keeps rendering under a $HOME the gem itself would refuse.
local function state_home()
  local xdg = vim.env.XDG_STATE_HOME
  if xdg and xdg:match("^/") then
    return unslashed(xdg) .. "/lain"
  end
  local home = home_dir()
  if home then
    return unslashed(home) .. "/.local/state/lain"
  end
  return nil
end

-- The deterministic per-project socket path. Pure: no directory or file is
-- created here (start_server owns the side effects). A project carrying a
-- `.lain/` directory owns its socket in-tree (`.lain/nvim.sock`) -- a project
-- artifact, like `.git/`; every other project gets
-- $XDG_RUNTIME_DIR/lain/nvim-<project_hash>.sock -- so lain (and any other
-- tool) can find this editor from the cwd alone.
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
  return ("%s/nvim-%s.sock"):format(dir, project_hash())
end

-- The published state feed, byte for byte Lain::ProjectDir#state_path:
-- `<state_home>/status/<project_hash>/state.json`, keyed by the SAME hash
-- socket_path() uses so the editor and the gem agree on one project from one
-- function. Pure: nothing is created here.
--
-- nil when no absolute base resolves. That is the honest answer rather than a
-- relative path: a relative one would resolve against the editor's cwd and put
-- the state feed back inside the user's repository.
--
-- A `state_path` override (setup opts or vim.g.lain_state_path) bypasses the
-- computation entirely and resolves the legacy way -- absolute as given,
-- relative against the editor's cwd -- for anyone who pinned the retired
-- `.lain/state.json` default explicitly.
function M.state_path()
  local override = config.current().state_path
  if override then
    if override:match("^/") then
      return override
    end
    return project_cwd() .. "/" .. override
  end
  local base = state_home()
  if not base then
    return nil
  end
  return ("%s/status/%s/state.json"):format(base, project_hash())
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

-- The tmux HUD's state feed, read back: the gem's StatusFeed publishes it
-- atomically (write-to-tmp + rename) at state_path(), so a read never sees a
-- half-written file. Returns the decoded table, or nil when no session has
-- published state -- and nil too on a path that does not resolve, and on bytes
-- that do not parse, both treated as absence rather than as an error (the
-- reader polls; the next publish heals it).
function M.status()
  local path = M.state_path()
  if not path then
    return nil
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

-- The HUD line, already rendered: Lain::StatusFeed::Reading composes it (the
-- marker, the fleet and inbox counts, a parked-approval count, the clamped
-- context percentage, the run's token spend and the composed mode lighter) and
-- Lain::StatusFeed publishes it as one field, so a lualine component asks for a
-- string instead of carrying a Lua copy of that derivation. nil when no session
-- has published state, and nil too for a state file written by a lain too old
-- to carry the field -- absence rather than a half-derived guess.
function M.hud()
  local state = M.status()
  if type(state) ~= "table" then
    return nil
  end
  local line = state.hud
  if type(line) ~= "string" or line == "" then
    return nil
  end
  return line
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
-- @return true when a layout was opened, false when there was nothing to place
-- yet. The caller armed on LainRender uses that to decide whether to stay
-- armed, which is why this reports rather than only warning.
local function open_layout(buffer_names)
  local columns = existing_columns(buffer_names)
  if #columns == 0 then
    vim.notify("lain: no lain:// buffers to lay out yet", vim.log.levels.WARN)
    return false
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
  return true
end

-- :LainStart. Attached already: lay out now. Not yet: arm a hook on the first
-- RENDER so the layout opens once `lain chat --nvim` has actually primed a
-- view (re-running :LainStart before that just re-arms the same hook -- the
-- cleared augroup keeps it single).
function M.start()
  local buffers = attached_buffers()
  if buffers then
    open_layout(buffers)
    return
  end
  local group = vim.api.nvim_create_augroup("lain_plugin_start", { clear = true })
  local pending = false
  -- LainRender, NOT LainAttach, and this is the whole of the fix for a layout
  -- that never opened. The attach payload names buffers that do not exist yet
  -- -- the runtime creates them lazily, per render -- so a hook armed on
  -- LainAttach filters every column to empty and is spent before the first
  -- view primes. LainRender is the event that MEANS a buffer now exists.
  --
  -- Not `once`, and scheduled: the first render is one buffer, and the layout
  -- places only what exists, so firing on it would lay out a single column and
  -- call the job done. `vim.schedule` defers to after the current batch of RPC
  -- writes drains, and staying armed until a layout actually opens is what
  -- covers a prime that arrives in more than one batch. `pending` keeps one
  -- attempt in flight, so a burst of renders schedules one layout, not ten.
  vim.api.nvim_create_autocmd("User", {
    pattern = "LainRender",
    group = group,
    callback = function()
      if pending then
        return
      end
      pending = true
      vim.schedule(function()
        pending = false
        if open_layout(attached_buffers() or {}) then
          pcall(vim.api.nvim_del_augroup_by_id, group)
          -- Supersede the "not attached yet" notice below: without this, the
          -- message line sits on the stale line for the whole session,
          -- contradicting the live lain:// buffers now open beside it (UX1 --
          -- nothing ever cleared or replaced it once attach succeeded).
          vim.notify("lain: attached -- layout opened", vim.log.levels.INFO)
        end
      end)
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
