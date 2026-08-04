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
  announce_render(JOURNAL, buf)
end
