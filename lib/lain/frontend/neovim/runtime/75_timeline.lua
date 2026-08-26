-- The cursor-on-a-turn pin gesture: `p` in lain://timeline pins the turn the
-- cursor sits on. The KEY invokes the COMMAND, so the mapping and a hand-typed
-- :LainPin are provably one path, and the map is buffer-local, bound from a
-- cleared-augroup BufEnter rather than at buffer creation -- `named_buf` returns
-- early for a buffer an earlier attach already made, which would leave a
-- surviving lain://timeline unbound after a re-attach.
--
-- The LINE rides as the argument, never a digest: lain://timeline renders no
-- digest on it, so the Ruby side's own line -> digest index is the only thing
-- that can name the turn -- and that index is built by the same pass that
-- produced the lines.
--
-- `p` shadows normal-mode paste, which a nomodifiable buffer has no use for.
-- <Cmd> rather than ":": it runs the command without leaving normal mode, so the
-- cursor the command is about does not move out from under it.
--
-- The buffer check is NOT redundant with the buffer-local map. `define` makes
-- every :Lain* command GLOBAL, and this one reads the CURRENT window's cursor,
-- so hand-typed from lain://journal line 7 it would pin TIMELINE turn 7 --
-- silently, and once pins outlive the session, permanently. :LainResend has no
-- such hazard: it looks its buffer up BY NAME.
define("LainPin", function()
  if vim.api.nvim_buf_get_name(0) ~= TIMELINE then
    -- ON THE RAIL, NOT ON `vim.notify`: `51_thread.lua` carries the measurement
    -- -- a plain notify blocks at roughly `#sentence + 12 > columns`, so it
    -- raises the very hit-enter prompt a refusal must not. The rail fits the
    -- line and prepends the `lain: ` this string therefore does not.
    -- `spec/refusal_delivery_discipline_spec.rb` is the gate.
    _G.__lain.review_refused(":LainPin pins the turn under the cursor in " .. TIMELINE)
    return
  end
  vim.rpcrequest(chan, "lain_command", "pin", { vim.api.nvim_win_get_cursor(0)[1] })
end)

local pin_group = vim.api.nvim_create_augroup("lain_pin", { clear = true })
vim.api.nvim_create_autocmd("BufEnter", {
  group = pin_group,
  pattern = TIMELINE,
  callback = function(ev)
    vim.keymap.set("n", "p", "<Cmd>LainPin<CR>", { buffer = ev.buf, desc = "lain: pin the turn under the cursor" })
  end,
})
