-- Append already-rendered plain lines to the journal. The Ruby RPC thread
-- calls this once per drained batch (the batch rule), never per event. The
-- first render REPLACES rather than appends below, so the journal never
-- leads with a blank -- or, since JournalView#initial primes an idle
-- placeholder rather than an empty line, with a stale header that would
-- otherwise sit above the real content forever.
--
-- "First render" is tracked with a buffer-local FLAG, not by re-reading the
-- buffer's literal text: a content check (line count == 1 and the line ==
-- "") worked only while the at-rest state was a bare empty line, and broke
-- the instant that state became a non-empty placeholder -- the placeholder
-- would never look "fresh" again, so every real append would stack below it
-- instead of replacing it.
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
