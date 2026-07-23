-- Sourced from the runtimepath at startup. Deliberately near-empty: the
-- plugin's behavior is opt-in via require("lain").setup(...) -- installing it
-- must change nothing about how lain attaches (the gem's runtime.lua is
-- self-contained; a bare `nvim --listen` works without us). Only :LainStart
-- is defined here, lazily requiring the module, so the command exists even
-- before setup() runs.
if vim.g.loaded_lain_plugin then
  return
end
vim.g.loaded_lain_plugin = 1

vim.api.nvim_create_user_command("LainStart", function()
  require("lain").start()
end, { desc = "lain: open a window layout over the attached lain:// buffers" })
