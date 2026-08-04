-- The human inbox drain (I6). :LainReply {answer} submits the typed answer as
-- a "reply" command -- enqueue-and-ack like every command, so the agent-side
-- consumer resolves the pending ask_human promise off its own queue and the
-- editor never blocks on it. The answer rides as the command's argument;
-- per-item targeting waits for the multi-question design step (today one
-- question is pending at a time -- ask_human's single-@pending invariant).
local function submit_reply(answer)
  if answer ~= "" then
    vim.rpcrequest(chan, "lain_command", "reply", { answer })
  end
end

define("LainReply", function(opts)
  submit_reply(opts.args)
end, { nargs = "+" })

-- The cursor-on-an-item OPEN gesture (T15, ruling 12): <CR> -- and `r`,
-- repointed from the one-line answer prompt it used to raise -- opens the
-- question SET the cursor sits on in lain://question. One verb, one vocabulary:
-- a set of N questions has no single-line answer, so the prompt does not
-- survive as a fast path. :LainReply stays for the answer it can still carry,
-- hand-typed.
--
-- :LainPin's shape in every respect that matters, and its comment states the
-- rule this one follows too: the LINE rides as the argument, never a digest.
-- lain://inbox is one set per line and renders no digest on it
-- (InboxView#line_for), so the Ruby side's own line -> digest index is the only
-- thing that can name the set -- and that index is built by the same pass that
-- produced the lines.
--
-- WHAT THIS SENDS THAT :LainPin DOES NOT, and it is not decoration: the
-- RENDERING STAMP this buffer carries (b:lain_view_generation, written by
-- set_view), because a line number alone names a POSITION and this buffer's
-- positions are not stable the way lain://timeline's are. A timeline only ever
-- grows, so line 7 means one turn forever; the inbox RETIRES rows, and every
-- row below a retired one moves up -- while the render that removes it is still
-- sitting in lain's render queue. In that window Ruby holds a rendering the
-- human is not looking at, and resolving their cursor against it opens the
-- NEIGHBOURING question set.
--
-- T15 sent the LINE COUNT for this, which was the only fact the editor had
-- before the stamp existed -- and a weak one: the queue drains once per RPC
-- tick, so the screen can be several renderings behind, and two renderings of
-- equal height are indistinguishable by count. Ruby then resolved the gesture
-- against the WRONG rendering and reported success. The stamp is exact, and it
-- is still not a digest: it says what the human is looking at, and Ruby remains
-- the only side that can name a set.
--
-- The buffer check is NOT redundant with the buffer-local maps below. `define`
-- makes every :Lain* command GLOBAL, and this one reads the CURRENT window's
-- cursor -- so hand-typed from lain://journal line 7 it would open whatever set
-- the inbox lists on ITS line 7, a set the human never looked at. Hand-typing
-- is an INVITED path here precisely because the maps invoke the command.
--
-- A line holding no record sends NOTHING, and the test is RECORD_START[INBOX] --
-- the runtime's own answer to "does this line hold an inbox item", already the
-- predicate the ]]/[[ motions and the folds ride, so the keys and the motions
-- cannot disagree about what a line is. The empty-state placeholder is the case
-- that reaches it: <CR> there is a keystroke about nothing, and an rpcrequest
-- whose only possible answer is "that line names no set" is worse than silence.
define("LainOpen", function()
  if vim.api.nvim_buf_get_name(0) ~= INBOX then
    vim.notify("lain: :LainOpen opens the question set under the cursor in " .. INBOX, vim.log.levels.WARN)
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local lines = cached_lines(buf)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  if RECORD_START[INBOX](lines, line) then
    vim.rpcrequest(chan, "lain_command", "open", { line, vim.b[buf].lain_view_generation })
  end
end)

-- Bound from a BufEnter autocmd (in a cleared augroup, so re-attach redefines
-- rather than stacks) because the buffer is created lazily by the first render,
-- not here. <Cmd> rather than ":", the pin map's reason: it runs the command
-- without leaving normal mode, so the cursor the command is about does not move
-- out from under it.
local OPEN_DESC = "lain: open the question set under the cursor"

local inbox_group = vim.api.nvim_create_augroup("lain_inbox", { clear = true })
vim.api.nvim_create_autocmd("BufEnter", {
  group = inbox_group,
  pattern = INBOX,
  callback = function(ev)
    vim.keymap.set("n", "r", "<Cmd>LainOpen<CR>", { buffer = ev.buf, desc = OPEN_DESC })
    vim.keymap.set("n", "<CR>", "<Cmd>LainOpen<CR>", { buffer = ev.buf, desc = OPEN_DESC })
  end,
})
