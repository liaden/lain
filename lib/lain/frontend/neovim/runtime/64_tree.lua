-- The gestures of lain://tree: `<CR>` rewinds to the turn under the cursor, `L` labels it. Each KEY
-- invokes its COMMAND, so a map and a hand-typed command are one path, and the maps are bound from a
-- cleared-augroup BufEnter for 75_timeline.lua's reason (a surviving buffer would stay unbound).
--
-- The LINE rides as the argument, never a digest: the Ruby view's own line -> digest index, built by
-- the pass that drew the lines, is the only thing that can name the turn. It rides WITH the rendering
-- stamp (b:lain_view_generation, written by set_view), because a line alone names a position in a buffer
-- that repaints on the drain thread's clock. `L` reads both BEFORE the prompt: the label is applied after
-- an async input, and the stamp the human pressed on is the one that must be judged.
--
-- The buffer check is NOT redundant with the buffer-local map: `define` makes every :Lain* command
-- GLOBAL and these read the CURRENT window's cursor.
local function on_tree(command, what)
  if vim.api.nvim_buf_get_name(0) ~= TREE then
    _G.__lain.review_refused(command .. " " .. what .. " in " .. TREE)
    return false
  end
  return true
end

define("LainTreeRewind", function()
  if on_tree(":LainTreeRewind", "rewinds to the turn under the cursor") then
    vim.rpcrequest(chan, "lain_command", "tree_rewind",
      { vim.api.nvim_win_get_cursor(0)[1], vim.b.lain_view_generation })
  end
end)

-- A cancelled prompt hands back nil, and nothing is labeled: an empty line is the retraction.
define("LainTreeLabel", function()
  if on_tree(":LainTreeLabel", "labels the turn under the cursor") then
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local generation = vim.b.lain_view_generation
    vim.ui.input({ prompt = "label: " }, function(text)
      if text ~= nil then
        vim.rpcrequest(chan, "lain_command", "tree_label", { line, text, generation })
      end
    end)
  end
end)

local tree_group = vim.api.nvim_create_augroup("lain_tree", { clear = true })
vim.api.nvim_create_autocmd("BufEnter", {
  group = tree_group,
  pattern = TREE,
  callback = function(ev)
    vim.keymap.set("n", "<CR>", "<Cmd>LainTreeRewind<CR>", { buffer = ev.buf, desc = "lain: rewind to the turn under the cursor" })
    vim.keymap.set("n", "L", "<Cmd>LainTreeLabel<CR>", { buffer = ev.buf, desc = "lain: label the turn under the cursor" })
  end,
})
