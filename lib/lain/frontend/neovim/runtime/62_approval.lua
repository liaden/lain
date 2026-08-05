-- lain://approval, the parked-approval list (T36): the buffer Ruby's
-- {Lain::Frontend::Neovim::ApprovalView} renders into, and the two keys that
-- answer the call under the cursor.
--
-- WHY THIS IS NOT A COMPOSE BUFFER, when 60_question just above it is. A
-- question is free text with no clock on it, so `:w` is the right gesture and
-- the parse can refuse. An approval is a CLOSED BINARY CHOICE UNDER A TIMEOUT:
-- the agent is parked on it, the queue's fail-closed window is running down,
-- there is nothing to compose, and a buffer whose write could expire mid-typing
-- would owe the human an apology rather than an answer. So this buffer is
-- `nofile` and nomodifiable like every other projection, and the answer is one
-- keystroke.
--
-- ONE new top-level name, 41_layout's and 46_sidebar's economy: the chunk shares
-- one scope and the binding cap is 60 upvalues per function prototype, so every
-- top-level local is a name each later module pays for.
local lain_approval = {
  NAME = "lain://approval",

  -- The verdict, the key that sends it, and the command both of them are. An
  -- ARRAY rather than a map, so `define` and the keymaps below run in one fixed
  -- order and neither is spelled by string surgery on the other.
  --
  -- 46_sidebar's MARK_KEYS, and the same rule for the same reason: A KEY PER
  -- VERDICT, NEVER ONE TOGGLE. The verdict RIDES THE WIRE, because a decision
  -- computed here from the rendering on screen answers the neighbouring call
  -- the moment the list has moved -- in SILENCE, since both values are legal.
  --
  -- Unlike MARK_KEYS this restates no Ruby constant: approve/deny is not a
  -- vocabulary lain could grow a third member of, it is a Boolean
  -- (Approval::Queue::Pending#decide takes one), and the Ruby side refuses any
  -- word it does not have rather than coercing it. `y` and `n` because they are
  -- the letters this same decision already wears at the terminal prompt
  -- ("approve bash(...)? [y/N]"), which is the whole of a human's muscle memory
  -- for this question.
  --
  -- WHAT THE TWO KEYS COST, stated rather than glossed: in this buffer `y` is
  -- not vim's yank and `n` is not repeat-search. Both are non-destructive keys
  -- shadowed in one nomodifiable, transient buffer -- the cheapest pair
  -- available, since every genuinely useful alternative (`a`, `d`, `x`) is an
  -- operator whose absence a human WOULD feel. They are buffer-local, bound
  -- from BufEnter, so nothing outside lain://approval changes.
  VERDICTS = {
    { verdict = "approve", key = "y", command = "LainApprove" },
    { verdict = "deny", key = "n", command = "LainDeny" },
  },
}

-- `named_buf` attaches a filetype from READONLY_FILETYPES, a table in
-- 00_constants which this module does not edit -- so the lookup misses and the
-- option lands unset. 46_sidebar records the fix and this follows it: join the
-- one shared "lain" filetype like every other record-shaped view, with
-- b:lain_view naming which view it is. Guarded on the CURRENT value, because
-- setting 'filetype' fires FileType synchronously and this renders on a poll.
function lain_approval.buf()
  local buf = named_buf(lain_approval.NAME)
  if vim.bo[buf].filetype == "" then
    vim.bo[buf].filetype = "lain"
  end
  return buf
end

-- Whole-buffer replace for the parked list, stamped twice.
--
-- b:lain_view_generation is the RENDERING STAMP, and it is REQUIRED here where
-- set_view's is optional: this buffer's rows move the instant ANY call is
-- answered -- at the terminal, on the desktop, or by the clock -- and two
-- renderings are routinely the same height. Ruby resolves a keypress only
-- against the rendering the stamp names.
--
-- b:lain_approval_rows is how many of the lines are answerable calls, and it is
-- what makes the keys inert on the hint line and on the empty state without
-- this module pattern-matching text Ruby drew. 70_inbox states the rule it
-- serves: a line holding no record sends NOTHING, because an rpcrequest whose
-- only possible answer is "that line names no call" is worse than silence.
--
-- IT TAKES THE WINDOW, and only on the way IN. set_question's reason applies
-- with more force here: lain is not merely handing the human something, it is
-- PARKED on their answer with a clock running, and an editor that showed
-- nothing while the chat pane waited is the defect this whole module exists to
-- fix. Focus is taken only when no window is already showing the buffer and
-- there is something to answer, so a poll never re-steals a cursor and an
-- emptied list never opens a window on nothing.
--
-- Written BEFORE the placement (46_sidebar's ordering), so the window never
-- shows a half-drawn buffer.
function _G.__lain.set_approval(lines, gen, rows)
  local buf = lain_approval.buf()
  vim.b[buf].lain_view_generation = gen
  vim.b[buf].lain_approval_rows = rows
  local shown = vim.fn.win_findbuf(buf)[1]
  set_lines(buf, 0, -1, lines)
  if rows > 0 and shown == nil then
    vim.api.nvim_win_set_cursor(vim.api.nvim_open_win(buf, true, { split = "below", win = 0 }), { 1, 0 })
  end
  announce_render(lain_approval.NAME, buf)
end

-- The cursor-on-a-row ANSWER gesture. :LainReviewMark's shape in every respect
-- that matters: the same buffer guard for the same reason (`define` makes every
-- :Lain* command GLOBAL and this one reads the CURRENT window's cursor, so
-- hand-typed from lain://journal line 7 it would answer whatever call the list
-- holds on ITS line 7 -- a call the human never looked at), the LINE and the
-- buffer's STAMP riding together, and ONE array after the verb, because every
-- verb on this rail is destructured Ruby-side as `verb, args` and 65_review
-- records a verb that sent flat positionals and had everything after the first
-- dropped on the floor.
--
-- ACKED, so nothing here reads a return value -- and that is a design
-- constraint rather than a convenience. Answering a parked approval RESOLVES A
-- PROMISE, which must happen on Ruby's reactor; serving it on the RPC thread
-- the way a question's `:w` is served would mean blocking that thread on the
-- reactor, which this project has ruled out twice. So the gesture rides the
-- command inbox to the consumer fiber, and a refusal comes back on the rail
-- `__lain.review_refused` renders, exactly as a refused open does.
local function submit_approval(verdict)
  local buf = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_get_name(buf) ~= lain_approval.NAME then
    vim.notify("lain: :LainApprove and :LainDeny answer the call under the cursor in " .. lain_approval.NAME,
      vim.log.levels.WARN)
    return
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  if line <= (vim.b[buf].lain_approval_rows or 0) then
    vim.rpcrequest(chan, "lain_command", "approval", { line, verdict, vim.b[buf].lain_view_generation })
  end
end

-- TWO COMMANDS, where 46_sidebar's mark took one parameterised command. The
-- argument there was that a closed set with a completion list should have one
-- place to add its third member to; there is no third verdict to add, because
-- the far side takes a Boolean. What a human types under a running clock is the
-- word itself, so the word is the command name.
--
-- SPELLED OUT, never looped over the table above, and that is not repetition:
-- `spec/plugin/nvim_plugin_spec.rb` reads the runtime's command list by
-- scanning this source for a `define` call whose first argument is a STRING
-- LITERAL, so a name assembled from a variable is a command the doc sweep
-- cannot see -- in EITHER direction, which means a command nothing documents
-- would pass and a help file naming one nothing defines would pass too. (The
-- same scanner is why this paragraph describes that call rather than showing
-- it: a quoted example in a comment reads as a command named after the example.)
define("LainApprove", function()
  submit_approval("approve")
end)
define("LainDeny", function()
  submit_approval("deny")
end)

-- Bound from a BufEnter autocmd (in a cleared augroup, so re-attach redefines
-- rather than stacks) because the buffer is created lazily by the first render,
-- not at attach. <Cmd> rather than ":", the inbox and sidebar maps' reason: it
-- runs the command without leaving normal mode, so the cursor the command is
-- about does not move out from under it.
vim.api.nvim_create_autocmd("BufEnter", {
  group = vim.api.nvim_create_augroup("lain_approval", { clear = true }),
  pattern = lain_approval.NAME,
  callback = function(ev)
    for _, answer in ipairs(lain_approval.VERDICTS) do
      vim.keymap.set("n", answer.key, "<Cmd>" .. answer.command .. "<CR>",
        { buffer = ev.buf, desc = "lain: " .. answer.verdict .. " the call under the cursor" })
    end
  end,
})
