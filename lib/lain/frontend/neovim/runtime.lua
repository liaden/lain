-- lain runtime, injected at attach via nvim_exec_lua. It ships IN the gem (read
-- and sent by Frontend::Neovim::RpcThread), so the lua here and the Ruby that
-- speaks to it can never drift across repos -- the whole reason lain installs
-- nothing in the user's dotfiles. See planning/interface-integration.md.
--
-- THIS FILE IS THE HEAD OF THE CHUNK, and `runtime/` holds the rest.
-- {Frontend::Neovim::RuntimeLoader} concatenates this file with every
-- `runtime/NN_*.lua` in sorted order and injects the result as ONE chunk. The
-- concatenation is not a taste preference: an injected chunk has no
-- `package.path`, so `require` cannot reach a sibling and the modules have no
-- other way to see each other.
--
-- Three rules follow from being one chunk, and every module inherits them:
--
--   1. NO MODULE MAY BE WRAPPED IN A FUNCTION. The injected args below are
--      varargs, which are legal only in a main chunk, and a wrapper would also
--      hide a module's top-level locals from the modules after it -- which is
--      the only way they are shared.
--   2. A module sees every local declared ABOVE it and none below, so the
--      numeric prefix IS the dependency order. Sorted glob, never a list, so
--      adding a capability is adding a file and no later card edits a loader.
--   3. Two modules declaring the same local name shadow SILENTLY. `selene`
--      reports it (see planning/lua-tooling-2026-08.md); nothing else will.
--
-- Injected args: the gem version (display only, surfaced by :LainVersion), the
-- protocol token (compatibility), and the RPC channel id to call back on.
local gem_version, protocol, chan = ...

-- ONE LAIN PER EDITOR, settled before a single other line of this chunk runs.
--
-- `_G.__lain` is process-wide and every :Lain* command closes over `chan`
-- above, so injecting this chunk a second time repoints every verb at the
-- newcomer's channel. Measured twice: the first lain's :LainReply then raises
-- `Invalid channel: N` forever, the newcomer's empty prime replaces the first's
-- rendered views, and every review annotation still drawn on screen is dropped
-- by a submit that reports success. So a second attach is REFUSED, and refused
-- HERE -- an editor is taken over by the modules below, and the only place a
-- takeover can be declined is before them.
--
-- LIVENESS, never presence, and the distinction is the whole design. A lain
-- that crashed leaves its `_G.__lain` behind exactly as a running one does, and
-- an editor that refuses every attach until nvim is restarted is worse than the
-- defect. So the marker is a CHANNEL ID and the editor is asked whether that
-- channel is still there: nvim reaps an RPC channel the moment its socket peer
-- goes (measured at well under a millisecond), and `nvim_get_chan_info` answers
-- an empty table for one that is gone. Nothing has to be cleaned up on the way
-- out, which is why a crash strands nothing -- and nvim never reuses a channel
-- id, so a dead owner's number cannot come back as somebody else's.
--
-- The refusal is a VALUE and not a message: only Ruby knows which socket this
-- is, and the human who has to act on it is at the terminal that just tried to
-- attach, not in this editor. `nvim_exec_lua` hands this table straight back to
-- Frontend::Neovim::RpcThread#attach, which raises the sentence.
--
-- A runtime injected before this marker existed (any protocol below 11) names
-- no owner and so cannot answer for one; it is treated as stale, because the
-- alternative is refusing an attach on evidence nobody has.
local function channel_alive(id)
  return type(id) == "number" and next(vim.api.nvim_get_chan_info(id)) ~= nil
end

local owner = type(_G.__lain) == "table" and _G.__lain.channel or nil
if owner ~= chan and channel_alive(owner) then
  return { refused = "owned", channel = owner }
end

-- The Ruby<->runtime contract version: the twin of Frontend::Neovim::PROTOCOL.
-- Bumped in lockstep with it when the injected protocol changes -- never for a
-- gem release, which is why the handshake does not compare gem versions. A
-- mismatch WARNS and keeps going: a stale editor half-works (commands still
-- fire, renders still land) rather than crashing the human's session outright.
local RUNTIME_PROTOCOL = "12"
if protocol ~= RUNTIME_PROTOCOL then
  vim.api.nvim_echo({
    { "lain: runtime.lua protocol " .. RUNTIME_PROTOCOL .. " / gem protocol " .. tostring(protocol) .. " mismatch", "WarningMsg" },
  }, true, {})
end
vim.g.lain_rpc_version = protocol

-- The one namespace every module publishes through, declared HERE rather than
-- in whichever module happens to load first: `_G.__lain.foldexpr` and
-- `_G.__lain.tick` are named from vim options as `v:lua.__lain.*`, so the table
-- is the runtime's public surface and belongs to the chunk, not to a capability.
_G.__lain = _G.__lain or {}

-- The ownership marker the check above reads, and the only non-function member
-- of this table. It is published rather than kept as a local for the reason the
-- defect had no remedy: `chan` was an upvalue nothing could see, so an editor
-- whose verbs had been repointed at a dead channel could not be inspected, let
-- alone healed -- `:LainVersion` reported a healthy runtime and every gesture
-- raised. Written LAST, so a refused attach leaves the owner's number exactly
-- as it found it.
_G.__lain.channel = chan
