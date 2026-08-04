-- lain://compose (T15): the ONE lain:// buffer nvim must be able to `:write`,
-- because `:w` IS the return leg of the compose round trip. Two option
-- choices here are not preferences, they are the only settings that work, and
-- both were found the hard way:
--
--   buftype = "acwrite"  -- `nofile` refuses `:write` with E382 BEFORE any
--                           autocommand runs, so BufWriteCmd would never fire
--                           at all. (This is the same property that makes
--                           lain://request safe from format-on-save; here it
--                           is exactly what we must not have.)
--   nvim_buf_set_name    -- an acwrite buffer with no name fails `:write`
--                           with E32. The name is the write target, and it is
--                           also how Ruby and the BufWriteCmd pattern find it.
--
-- bufhidden stays "hide", NOT "wipe": a human who steps over to lain://journal
-- mid-compose and comes back must find their draft, and BufUnload is the
-- ABANDON signal -- wiping on hide would report an abandon they never made.
-- So an abandon means an explicit :bdelete/:bwipeout (or quitting nvim), which
-- is precisely the gesture the round trip reads it as. Verified bonus: "hide"
-- plus nvim's default 'hidden' means even `autowriteall` + a buffer switch
-- does NOT fire a write, because the buffer is hidden rather than abandoned.
--
-- KNOWN LIMITATION, probed and not worked around: `:wall`, and any autosave
-- plugin issuing a timed `:w`, DOES fire BufWriteCmd, and the round trip takes
-- that as the human's answer -- so half-typed text can settle a compose. lain
-- attaches to the human's OWN nvim with their own plugins, so this is not
-- exotic. It is not defended against because the defence would be to stop
-- using `:w` as the gesture, and `:w` being the gesture is the feature: it is
-- the one verb every vim user already reads as "I am done with this text".
local function compose_buf(name)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 then
    return claim(existing, name)
  end

  local buf = claim(vim.api.nvim_create_buf(true, true), name)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  return buf
end

-- Open lain://compose on the human's draft (T15). The ONE render entry point
-- that deliberately takes the cursor: every other buffer here is a live
-- projection that must never steal focus mid-thought, whereas this one exists
-- because the human just pressed C-g and asked to be put in it. It is shown
-- in a split only when no window already holds it, so a second compose lands
-- in the window they left open rather than stacking splits.
--
-- 'modified' is cleared after the write: the buffer's content came from lain,
-- not from the human, so leaving it dirty would make nvim argue about unsaved
-- changes over text nobody typed.
-- b:lain_compose_generation is stamped here and sent back with every answer,
-- so Ruby can tell WHICH compose the editor is talking about. The buffer is
-- reused across round trips (found by name), so a write still in flight when
-- the human opens a second compose would otherwise be indistinguishable from
-- the second one's answer.
function _G.__lain.set_compose(name, lines, generation)
  local buf = compose_buf(name)
  vim.b[buf].lain_compose_generation = generation
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  if vim.fn.win_findbuf(buf)[1] == nil then
    vim.api.nvim_open_win(buf, true, { split = "below", win = 0 })
  end
  announce_render(name, buf)
end

-- The compose round trip's return leg (T15). No :Lain* command here on
-- purpose: the human's gesture is `:w`, the one thing every vim user already
-- knows means "I am done with this text", and lain://compose is `acwrite`
-- exactly so that gesture can be intercepted. Both callbacks are ordinary
-- enqueue-and-ack rpcREQUESTS -- the same path :LainResend takes -- so the
-- Ruby side answers in microseconds and nothing new reads the RPC session.
-- Cleared augroup, like every lain augroup, so re-attach redefines rather
-- than stacks (a stacked BufWriteCmd would report one write twice).
--
-- BufWriteCmd REPLACES the write: nothing is persisted anywhere, and clearing
-- 'modified' is what tells nvim the write succeeded. That is the whole point
-- -- the "file" is the prompt.
--
-- ORDER IS THE CORRECTNESS HERE. The rpcrequest goes FIRST and 'modified' is
-- cleared only once it returns. Clearing first meant a write that never
-- reached lain -- the Ruby end torn down, "Invalid channel" -- still left the
-- buffer looking saved, so nvim would not warn on `:q` and the human's text
-- was simply gone. Now a failed write leaves the buffer dirty, exactly as a
-- failed `:w` to a real file would, and says so.
local compose_group = vim.api.nvim_create_augroup("lain_compose", { clear = true })
vim.api.nvim_create_autocmd("BufWriteCmd", {
  group = compose_group,
  pattern = COMPOSE,
  callback = function(ev)
    local lines = vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false)
    local ok, err = pcall(vim.rpcrequest, chan, "lain_command", "compose", lines,
      vim.b[ev.buf].lain_compose_generation)
    if not ok then
      -- Re-raised, not merely notified: a `:w` whose text reached nobody must
      -- FAIL as a write. Erroring here is what leaves 'modified' set, so the
      -- buffer keeps saying it holds unsaved text and nvim refuses to DISCARD
      -- it -- `:bdelete`/`:bwipeout` answer E89, and a last-window quit is
      -- refused. Note plain `:q` still succeeds: bufhidden = "hide" hides the
      -- buffer rather than abandoning it, so quitting a window is not a
      -- discard and nvim has nothing to object to.
      error("lain: compose could not reach lain, buffer NOT saved: " .. tostring(err), 0)
    end
    vim.bo[ev.buf].modified = false
  end,
})

-- BufUnload is the ABANDON signal: :bdelete/:bwipeout, or quitting nvim.
-- pcall'd because one of those cases is nvim EXITING, where the Ruby end may
-- already have torn its RPC thread down -- an unanswered rpcrequest would
-- then surface as an autocmd error in the human's face on the way out, over a
-- notice whose only reader has gone. The prompt is not stranded by the loss:
-- Compose's own bound covers exactly this.
vim.api.nvim_create_autocmd("BufUnload", {
  group = compose_group,
  pattern = COMPOSE,
  callback = function(ev)
    pcall(vim.rpcrequest, chan, "lain_command", "compose_abandon", vim.b[ev.buf].lain_compose_generation)
  end,
})
