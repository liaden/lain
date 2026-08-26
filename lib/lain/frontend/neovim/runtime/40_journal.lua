-- Append already-rendered plain lines to the journal, once per drained batch and
-- never per event. The FIRST render replaces rather than appends, so the
-- placeholder JournalView#initial primes does not sit above the real content
-- forever.
--
-- "First render" is tracked with a buffer-local FLAG, not by re-reading the
-- buffer's literal text: a content check worked only while the at-rest state was
-- a bare empty line, and broke the instant it became a non-empty placeholder,
-- which would never look "fresh" again.
function _G.__lain.render(lines)
  local buf = named_buf(JOURNAL)
  local fresh = not vim.b[buf].lain_journal_rendered
  if fresh then
    set_lines(buf, 0, -1, lines)
  else
    set_lines(buf, -1, -1, lines)
  end
  vim.b[buf].lain_journal_rendered = true
  announce_render(JOURNAL, buf)
end
