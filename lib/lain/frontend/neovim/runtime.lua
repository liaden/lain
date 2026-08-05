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

-- The Ruby<->runtime contract version: the twin of Frontend::Neovim::PROTOCOL.
-- Bumped in lockstep with it when the injected protocol changes -- never for a
-- gem release, which is why the handshake does not compare gem versions. A
-- mismatch WARNS and keeps going: a stale editor half-works (commands still
-- fire, renders still land) rather than crashing the human's session outright.
local RUNTIME_PROTOCOL = "10"
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
