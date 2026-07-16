-- lain runtime, injected at attach via nvim_exec_lua. It ships IN the gem (read
-- and sent by Frontend::Neovim::RpcThread), so the lua here and the Ruby that
-- speaks to it can never drift across repos -- the whole reason lain installs
-- nothing in the user's dotfiles. See planning/interface-integration.md.
--
-- Injected args: the gem version (display only, surfaced by :LainVersion), the
-- protocol token (compatibility), and the RPC channel id to call back on.
local gem_version, protocol, chan = ...

-- The Ruby<->runtime contract version: the twin of Frontend::Neovim::PROTOCOL.
-- Bumped in lockstep with it when the injected protocol changes -- never for a
-- gem release, which is why the handshake does not compare gem versions. A
-- mismatch WARNS and keeps going: a stale editor half-works (commands still
-- fire, renders still land) rather than crashing the human's session outright.
local RUNTIME_PROTOCOL = "1"
if protocol ~= RUNTIME_PROTOCOL then
  vim.api.nvim_echo({
    { "lain: runtime.lua protocol " .. RUNTIME_PROTOCOL .. " / gem protocol " .. tostring(protocol) .. " mismatch", "WarningMsg" },
  }, true, {})
end
vim.g.lain_rpc_version = protocol

-- Every lain:// buffer -- the append-only journal and the read-only state
-- views alike -- is found by name so re-attach reuses it (idempotent) instead
-- of stacking a fresh buffer per reconnect, and stays nomodifiable at rest
-- (4-2.2: "read-only and unobtrusive") so a human's stray keystroke in one
-- can never desync it from the state it presents.
local function named_buf(name)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 then
    return existing
  end

  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  return buf
end

-- `nvim_buf_set_lines` itself raises against a nomodifiable buffer, so every
-- write flips the option around the call rather than leaving it open --
-- nomodifiable is the buffer's resting state, and the flip is one synchronous
-- Lua call, never observable as a modifiable window a human could type into.
local function set_lines(buf, start, stop, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, start, stop, false, lines)
  vim.bo[buf].modifiable = false
end

local JOURNAL = "lain://journal"

_G.__lain = _G.__lain or {}

-- Append already-rendered plain lines to the journal. The Ruby RPC thread
-- calls this once per drained batch (the batch rule), never per event. A
-- fresh scratch buffer holds one empty line; the first render replaces it
-- rather than appending below it, so the journal never leads with a blank.
function _G.__lain.render(lines)
  local buf = named_buf(JOURNAL)
  local fresh = vim.api.nvim_buf_line_count(buf) == 1
    and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
  if fresh then
    set_lines(buf, 0, -1, lines)
  else
    set_lines(buf, -1, -1, lines)
  end
end

-- Whole-buffer replace for the state views (4-2.2): lain://timeline,
-- lain://workspace, lain://diff. Unlike the journal these are PROJECTIONS of
-- live state, not a log, so an update REPLACES the buffer's content rather
-- than growing it -- never nvim_input/feedkeys, and the buffer is never
-- focused or jumped to, so a live update cannot steal the human's cursor.
function _G.__lain.set_view(name, lines)
  set_lines(named_buf(name), 0, -1, lines)
end

-- Re-attach is idempotent: delete before create so a name is defined exactly
-- once, and every command is Lain-namespaced (no collision with the human's
-- config or a plugin).
local function define(name, fn)
  pcall(vim.api.nvim_del_user_command, name)
  vim.api.nvim_create_user_command(name, fn, {})
end

-- Agent-facing commands enqueue-and-ack: the callback makes ONE blocking
-- rpcrequest that the Ruby side answers in microseconds (queue the work, ack).
-- The editor unblocks immediately; the agent's latency never freezes it.
local function agent_command(name)
  return function()
    vim.rpcrequest(chan, "lain_command", name)
  end
end

define("LainResend", agent_command("resend"))
define("LainSend", agent_command("send"))
define("LainContext", agent_command("context"))

-- The observable half of the version handshake: :LainVersion surfaces the gem
-- version the attach recorded, straight into :messages -- no rpc round trip.
define("LainVersion", function()
  vim.api.nvim_echo({ { "lain gem " .. tostring(gem_version), "None" } }, true, {})
end)
