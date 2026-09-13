-- lain runtime, injected at attach via nvim_exec_lua. It ships IN the gem, so
-- the lua here and the Ruby that speaks to it can never drift across repos --
-- the whole reason lain installs nothing in the user's dotfiles.
--
-- THIS FILE IS THE HEAD OF THE CHUNK, and `runtime/` holds the rest.
-- {Frontend::Neovim::RuntimeLoader} concatenates this file with every
-- `runtime/NN_*.lua` in sorted order and injects the result as ONE chunk,
-- because an injected chunk has no `package.path`: `require` cannot reach a
-- sibling, and the modules have no other way to see each other.
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
--      reports it; nothing else will.
--
-- Injected args: the gem version (display only, surfaced by :LainVersion), the
-- protocol token (compatibility), and the RPC channel id to call back on.
--
-- The protocol token is a DIGEST of the WHOLE INJECTED CHUNK -- this head plus
-- every `runtime/NN_*.lua` after it, which is what the loader concatenates and
-- what nvim is handed -- taken by the Ruby half over exactly those bytes. Not of
-- this file: a digest of the head alone would move for none of the twenty-three
-- modules that carry the surface.
--
-- It used to be an integer written out twice, once here and once in Ruby, bumped
-- in lockstep by hand -- and a number two files have to agree on is a number one
-- of them forgets. A digest cannot be forgotten, because a change to any module
-- IS the digest moving. What it costs is that this file can hold no literal copy
-- to compare against, so what it compares against is what the runtime already in
-- this editor published about itself (`__lain.protocol`, below).
local gem_version, protocol, chan = ...

-- ONE LAIN PER EDITOR, settled before a single other line of this chunk runs.
--
-- `_G.__lain` is process-wide and every :Lain* command closes over `chan`
-- above, so injecting this chunk a second time repoints every verb at the
-- newcomer's channel. Measured: the first lain's :LainReply then raises
-- `Invalid channel: N` forever, the newcomer's empty prime replaces the first's
-- rendered views, and every review annotation still on screen is dropped by a
-- submit that reports success. So a second attach is REFUSED, and refused HERE
-- -- an editor is taken over by the modules below, and the only place a
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

-- A RUNTIME FROM ANOTHER LAIN, AND THE ONE ANNOUNCEMENT ABOUT IT. Settled
-- second, after ownership, never before it.
--
-- NOT an invariant, and the heading above deliberately does not claim one. `ONE
-- LAIN PER EDITOR` is enforced: it latches, it cannot be cleared by re-running,
-- and two lains never coexist. This is a one-shot ANNOUNCEMENT, and after it the
-- two runtimes do coexist -- see below for why that is the right trade and what
-- it does not buy.
--
-- WHAT IS CHECKED is a runtime that is really here: `_G.__lain.protocol`, which
-- `99_attach.lua` publishes after every module above it has executed. Not
-- `g:lain_rpc_version`, which the line below stamps before a single module runs
-- and which outlives any runtime that set it -- a `:source` of a config, a
-- cleared `_G.__lain`, an editor somebody tidied. A leftover variable is not a
-- stale runtime, and refusing on one costs a human their editor over litter.
--
-- WHAT IT BUYS is that somebody is told. Re-injection replaces everything this
-- chunk defines and every augroup in it is `clear = true`, so what survives is
-- exactly what the newer runtime no longer has: a command it dropped, an autocmd
-- it stopped creating, still wired to a channel that died. That residue survives
-- the consented re-attach too. Telling the human is the whole of the value; the
-- repair is quitting nvim, which is what the sentence Ruby raises says.
--
-- ANNOUNCED ONCE, because the token moves on every edit to any module: a guard
-- that latched would cost a developer their editor each time they touched a line
-- of lua, which is worse than the integer this replaced. The consent is recorded
-- on THIS RUNTIME (`stale_announced`, cleared the moment a runtime finishes
-- installing) rather than on the editor, so the next time a runtime differs it
-- announces itself too instead of being permanently satisfied.
--
-- Nothing published is touched on the way out. Ownership above returns before
-- this line for exactly that reason: a live lain's editor must be left as it was
-- found, and setting a flag is still a write.
local live = type(_G.__lain) == "table" and _G.__lain or nil
if live ~= nil and live.protocol ~= nil and live.protocol ~= protocol and not live.stale_announced then
  live.stale_announced = true
  return { refused = "stale", installed = live.protocol }
end

-- The token the gem INJECTED, stamped before the modules load and never cleared
-- by anything here. Published surface: the shipped plugin reads it to decide
-- whether an editor has been attached at all, so a refusal that deleted it would
-- leave :LainStart telling an attached human their editor was not attached.
-- What the runtime actually RUNNING here speaks is `__lain.protocol`.
vim.g.lain_rpc_version = protocol

-- The one namespace every module publishes through, declared HERE rather than in
-- whichever module loads first: `_G.__lain.foldexpr` and `_G.__lain.tick` are
-- named from vim options as `v:lua.__lain.*`, so the table is the runtime's
-- public surface and belongs to the chunk, not to a capability.
_G.__lain = _G.__lain or {}

-- The ownership marker the check above reads, and the only non-function member
-- of this table. PUBLISHED rather than kept as a local: as an upvalue nothing
-- could see, an editor whose verbs had been repointed at a dead channel could
-- not be inspected, let alone healed -- `:LainVersion` reported a healthy
-- runtime and every gesture raised. Written LAST, so a refused attach leaves the
-- owner's number exactly as it found it.
_G.__lain.channel = chan
