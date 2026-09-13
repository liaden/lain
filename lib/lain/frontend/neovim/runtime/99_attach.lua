-- 99 IS RESERVED FOR THIS FILE. A new capability takes a free number below it,
-- never 99 and never above -- the announcement has to be the last thing the
-- chunk does, and the sorted glob is what makes that true.
--
-- The attach announcement, deliberately LAST: by the time a user callback
-- runs, every :Lain* command and autocmd above exists, so config reacting to
-- LainAttach may call any of them. The payload carries buffer NAMES (the
-- whole BUFFERS set), never bufnrs -- the buffers themselves are created
-- lazily by the first render, which each announces itself via LainRender.
-- protocol is the digest of the injected chunk, taken by the gem over the
-- exact bytes it sent, so it names the runtime that is actually running here
-- -- there is no second copy for it to disagree with. It is honest in THIS
-- payload, and only here, because this autocmd fires only if the whole chunk
-- loaded.

-- The runtime's own account of which chunk is live in this editor, published
-- HERE and nowhere earlier: 99 is the last thing the chunk does, so this is set
-- only if every module above it executed. `g:lain_rpc_version` is stamped by the
-- head before any of them run and therefore says what was INJECTED; a chunk that
-- errors mid-load stamps that and leaves a runtime that is not there. This is
-- what the head's stale check reads, and the reason it cannot be fooled by half
-- a load.
--
-- The consent flag goes with it: a successful install is what the one-shot was
-- consented TO, so the next runtime that differs announces itself rather than
-- finding a guard already satisfied.
_G.__lain.protocol = protocol
_G.__lain.stale_announced = nil

vim.api.nvim_exec_autocmds("User", {
  pattern = "LainAttach",
  modeline = false,
  data = { buffers = BUFFERS, gem_version = tostring(gem_version), protocol = protocol },
})
