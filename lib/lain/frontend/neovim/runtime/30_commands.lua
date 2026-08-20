-- The command primitives, ahead of every capability that spends them: a module
-- calling `define` sorts after this one BY ITS PREFIX, which is the whole of the
-- enforcement.
--
-- Re-attach is idempotent: delete before create so a name is defined exactly
-- once, and every command is Lain-namespaced (no collision with the human's
-- config or a plugin).
local function define(name, fn, opts)
  pcall(vim.api.nvim_del_user_command, name)
  vim.api.nvim_create_user_command(name, fn, opts or {})
end

-- Agent-facing commands enqueue-and-ack: the callback makes ONE blocking
-- rpcrequest that the Ruby side answers in microseconds (queue the work, ack).
-- The editor unblocks immediately; the agent's latency never freezes it.
local function agent_command(name)
  return function()
    vim.rpcrequest(chan, "lain_command", name)
  end
end

-- The prefix every lain KEY hangs off, and the two binders that spend it.
--
-- `vim.g.lain_prefix` overrides it, the opt-out shape `vim.g.lain_fold` and
-- `vim.g.lain_review_sidebar_width` already use. It is read when a map is
-- CREATED -- at attach for a global key, at BufEnter for a buffer-local one --
-- so set it before `lain ... --nvim`, or re-attach after changing it.
-- `<leader>` is expanded by nvim at map time, so a human with their own
-- mapleader gets theirs rather than a literal backslash.
local function lain_prefix()
  return vim.g.lain_prefix or "<leader>L"
end

-- A GLOBAL lain key: it fires in the human's own editable file, where every
-- bare letter is already theirs, so it wears the prefix and there is nowhere
-- else to scope it to.
--
-- DELETE BEFORE CREATE, `define`'s rule one layer up and for a sharper reason:
-- re-attaching under a changed prefix would otherwise leave the old lhs bound,
-- and a key still firing from a prefix lain no longer admits to is exactly the
-- silently-stolen key this seam exists to prevent. The record has to outlive
-- the chunk -- a re-attach re-executes this file, so a chunk-local table would
-- be empty every time and remember nothing -- so it lives on `vim.g`.
local function lain_key(suffix, rhs, desc)
  local bound = vim.g.lain_bound_keys or {}
  if bound[suffix] then
    pcall(vim.keymap.del, "n", bound[suffix])
  end
  local lhs = lain_prefix() .. suffix
  vim.keymap.set("n", lhs, rhs, { desc = "lain: " .. desc })
  bound[suffix] = lhs
  vim.g.lain_bound_keys = bound
end

-- The same key, scoped to ONE buffer. Two things differ from the global binder
-- and both are consequences of the scope rather than choices:
--
-- It needs no delete-before-create and keeps no record, because the map dies
-- with the buffer -- there is no lhs to strand at an old prefix.
--
-- It is still PREFIXED, unlike `x`/`u`/`y`/`n`/`p`/<CR>, and the line between
-- them is what the buffer IS. Those are claimed on buffers lain built and holds
-- `nomodifiable`, where a bare letter can collide with nothing the human wanted.
-- A review DIFF is the opposite: its new side is a real, editable file buffer
-- (`47_diff.lua` keeps `buftype = ""` deliberately, so it is THE FILE and not a
-- scratch copy), so a bare `n` there would cost the human repeat-search in a
-- buffer they are also editing.
local function lain_buf_key(buf, suffix, rhs, desc)
  vim.keymap.set("n", lain_prefix() .. suffix, rhs, { buffer = buf, desc = "lain: " .. desc })
end
