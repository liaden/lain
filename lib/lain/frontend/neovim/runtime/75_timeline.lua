-- The cursor-on-a-turn pin gesture (B4): `p` in lain://timeline pins the turn
-- the cursor sits on -- "compaction may not elide this one". Mirrors the inbox
-- drain above in every respect that matters: the KEY invokes the COMMAND, so
-- the mapping and a hand-typed :LainPin are provably one path; the command is
-- enqueue-and-ack like every other; and the map is buffer-local, bound from a
-- cleared-augroup BufEnter (not at buffer creation) because `named_buf` returns
-- early for a buffer an earlier attach already made, which would leave a
-- surviving lain://timeline unbound after a re-attach.
--
-- The LINE rides as the argument, never a digest: lain://timeline is one turn
-- per line and renders no digest on it (Buffers#turn_line), so the Ruby side's
-- own line -> digest index is the only thing that can name the turn -- and that
-- index is built by the same pass that produced the lines, so it cannot
-- disagree with what the human is looking at.
--
-- `p` shadows normal-mode paste, which a nomodifiable buffer has no use for.
-- <Cmd> rather than ":": it runs the command without leaving normal mode, so
-- the cursor the command is about does not move out from under it.
-- The buffer check is NOT redundant with the buffer-local map. `define` makes
-- every :Lain* command GLOBAL, and this one reads the CURRENT window's cursor
-- -- so hand-typed from lain://journal line 7 it would send ["pin", [7]] and
-- pin TIMELINE turn 7, a turn the human never looked at, silently and (once
-- pins outlive the session) permanently. Hand-typing is an INVITED path here
-- precisely because the map invokes the command, so the command has to hold
-- the invariant itself. :LainResend has no such hazard -- it looks its buffer
-- up BY NAME rather than reading whatever window happens to be current.
define("LainPin", function()
  if vim.api.nvim_buf_get_name(0) ~= TIMELINE then
    vim.notify("lain: :LainPin pins the turn under the cursor in " .. TIMELINE, vim.log.levels.WARN)
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
