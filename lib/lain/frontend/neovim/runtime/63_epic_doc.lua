-- An epic document, drawn read-only beside the human's window. The buffer name is
-- dynamic (`lain://epic/<slug>/<path>`), so it is claimed here on first sight
-- rather than listed in READONLY_FILETYPES.
--
-- It opens in a split exactly once, when the buffer is created, and never takes
-- focus: a later write refreshes the lines in place, and a human who closed the
-- window is not given it back on every rewrite.
function _G.__lain.set_epic_doc(name, lines)
  local created = vim.fn.bufnr(name) == -1
  local buf = named_buf(name)
  vim.bo[buf].filetype = "markdown"
  set_lines(buf, 0, -1, lines)
  if created then
    vim.api.nvim_open_win(buf, false, { split = "below", win = 0 })
  end
  announce_render(name, buf)
end
