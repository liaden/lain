-- Whole-buffer replace for the state views (4-2.2): lain://timeline,
-- lain://workspace, lain://diff. Unlike the journal these are PROJECTIONS of
-- live state, not a log, so an update REPLACES the buffer's content rather
-- than growing it -- never nvim_input/feedkeys, and the buffer is never
-- focused or jumped to, so a live update cannot steal the human's cursor.
-- The write starts at the first DIFFERING line, not at line 0: a naive
-- whole-buffer replace makes the editor refold everything, resetting every
-- manually opened fold to the foldlevel default (verified live -- probe H's
-- stomp had a second root besides the old forced re-close), while lines an
-- edit never touches keep their fold state naturally (probe I's append
-- evidence). These views grow append-mostly (a timeline gains turns; the
-- shared prefix is stable), so the trimmed write makes the natural
-- preservation the folds rely on the common case -- and skips redraw work
-- for free.
--
-- b:lain_view_generation is the RENDERING STAMP (T16), and it is optional: a
-- view whose gesture resolves through a Ruby-side line -> digest index sends
-- one, every other view sends nothing and the buffer never gains the variable.
-- lain://inbox is the only such view today. It matters because this buffer's
-- positions are NOT stable -- a retired item takes its row out and every row
-- below moves up -- so the line a human presses on means nothing without
-- saying WHICH rendering it is a line of, and the line COUNT cannot say that:
-- two renderings are routinely the same height. `set_compose` and
-- `set_question` have stamped their buffers for exactly this reason since they
-- existed; this is that same idea on a projection.
function _G.__lain.set_view(name, lines, gen)
  local buf = named_buf(name)
  if gen ~= nil then
    vim.b[buf].lain_view_generation = gen
  end
  local old = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local shared = 0
  while shared < #old and shared < #lines and old[shared + 1] == lines[shared + 1] do
    shared = shared + 1
  end
  set_lines(buf, shared, -1, vim.list_slice(lines, shared + 1, #lines))
  announce_render(name, buf)
end
