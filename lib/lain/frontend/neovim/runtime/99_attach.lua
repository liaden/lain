-- 99 IS RESERVED FOR THIS FILE. A new capability takes a free number below it,
-- never 99 and never above -- the announcement has to be the last thing the
-- chunk does, and the sorted glob is what makes that true.
--
-- The attach announcement, deliberately LAST: by the time a user callback
-- runs, every :Lain* command and autocmd above exists, so config reacting to
-- LainAttach may call any of them. The payload carries buffer NAMES (the
-- whole BUFFERS set), never bufnrs -- the buffers themselves are created
-- lazily by the first render, which each announces itself via LainRender.
-- protocol is RUNTIME_PROTOCOL, the contract this running lua actually
-- speaks, which a mismatched injection has already warned about above.
vim.api.nvim_exec_autocmds("User", {
  pattern = "LainAttach",
  modeline = false,
  data = { buffers = BUFFERS, gem_version = tostring(gem_version), protocol = RUNTIME_PROTOCOL },
})
