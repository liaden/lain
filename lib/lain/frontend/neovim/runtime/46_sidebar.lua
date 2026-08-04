-- lain://review, the changeset review's navigator (T14): the buffer Ruby's
-- {Lain::Frontend::Neovim::ReviewView} renders into, and the `<CR>` that opens
-- the row under the cursor.
--
-- 46, above 41: this renders THROUGH the layout's `review_place`, and a module
-- sees only what concatenates before it.
--
-- THE FIRST CALLER OF T26's LAYOUT, and that is the whole of why this file
-- exists rather than another `belowright split`. `review_place` re-ensures the
-- tabpage and its three slots before every render and answers a freshly
-- resolved window id, so a render arriving after the human closed the sidebar
-- rebuilds it and lands in the rebuilt one. `review_layout()`'s return is a
-- SNAPSHOT and is deliberately not called here: caching an id across renders is
-- the documented way to earn `Invalid window id`.
--
-- ONE new top-level name, 41_layout's own economy: the chunk shares one scope
-- and the binding cap is 60 upvalues per function prototype, so every top-level
-- local is a name each later module pays for. The public entry point goes on
-- `_G.__lain`, where the runtime's public surface lives.
local review_sidebar = { NAME = "lain://review" }

-- `named_buf` is the shared constructor (nofile, hidden, nomodifiable at rest,
-- idempotent by name) and it attaches a filetype from READONLY_FILETYPES -- a
-- table in 00_constants, which this module does not edit. The lookup misses, so
-- the option lands unset, and the fix is applied HERE rather than by widening a
-- shared table: the sidebar joins the one shared "lain" filetype like every
-- other record-shaped view, with b:lain_view naming which view it is.
--
-- Guarded on the CURRENT value rather than run unconditionally, because setting
-- 'filetype' fires FileType synchronously -- re-setting it on every render
-- would re-run a human's every FileType autocmd once per row change.
function review_sidebar.buf()
  local buf = named_buf(review_sidebar.NAME)
  if vim.bo[buf].filetype == "" then
    vim.bo[buf].filetype = "lain"
  end
  return buf
end

-- Whole-buffer replace, stamped (T14/T11's SET_REVIEW). The stamp is REQUIRED
-- here where set_view's is optional: a sidebar row moves the moment the scope
-- toggles or a mark redraws a row, and two renderings are routinely the same
-- height -- which is exactly the aliasing protocol 8 replaced the line COUNT to
-- fix. Ruby resolves a gesture only against the rendering the stamp names.
--
-- Written BEFORE the placement, so the window never shows a half-drawn buffer,
-- and placed on EVERY render rather than only the first: `review_place` is what
-- repairs a layout the human has since closed windows in, and it moves nobody.
function _G.__lain.set_review(lines, gen)
  local buf = review_sidebar.buf()
  vim.b[buf].lain_view_generation = gen
  set_lines(buf, 0, -1, lines)
  _G.__lain.review_place("sidebar", buf)
  announce_render(review_sidebar.NAME, buf)
end

-- The cursor-on-a-row OPEN gesture. :LainOpen's shape in every respect that
-- matters, and its comment states the two rules this one follows too: the LINE
-- rides as an argument, never an identity, because a sidebar row renders no hunk
-- key -- and the buffer's STAMP rides beside it, because a line number alone
-- names a position in a buffer whose positions move.
--
-- ONE argument after the verb, and it is an ARRAY. Every verb on this rail is
-- destructured Ruby-side as `verb, args`; 65_review records a verb that sent
-- flat positionals and had everything after the first dropped on the floor.
--
-- The buffer check is NOT redundant with the buffer-local map below. `define`
-- makes every :Lain* command GLOBAL and this one reads the CURRENT window's
-- cursor, so hand-typed from lain://journal line 7 it would open whatever file
-- the sidebar lists on ITS line 7 -- a file the human never looked at. Hand
-- typing is an invited path precisely because the map invokes the command.
--
-- Every line is sent, with no runtime-side test of whether it holds a file: the
-- legend, a commit header and the empty-state placeholder all name none, and
-- Ruby -- which drew them and owns the line -> target map -- is the only side
-- that can say so. It answers with a refusal the human sees on the same rail a
-- refused :LainReviewDone answers on, which is a better outcome than a lua-side
-- pattern match on rendered text that would have to be kept in step with it.
define("LainReviewOpen", function()
  local buf = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_get_name(buf) ~= review_sidebar.NAME then
    vim.notify("lain: :LainReviewOpen opens the file under the cursor in " .. review_sidebar.NAME,
      vim.log.levels.WARN)
    return
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  vim.rpcrequest(chan, "lain_command", "review_open", { line, vim.b[buf].lain_view_generation })
end)

-- Bound from a BufEnter autocmd (in a cleared augroup, so re-attach redefines
-- rather than stacks) because the buffer is created lazily by the first render,
-- not here. <Cmd> rather than ":", the inbox map's reason: it runs the command
-- without leaving normal mode, so the cursor the command is about does not move
-- out from under it.
vim.api.nvim_create_autocmd("BufEnter", {
  group = vim.api.nvim_create_augroup("lain_sidebar", { clear = true }),
  pattern = review_sidebar.NAME,
  callback = function(ev)
    vim.keymap.set("n", "<CR>", "<Cmd>LainReviewOpen<CR>",
      { buffer = ev.buf, desc = "lain: open the file under the cursor" })
  end,
})
