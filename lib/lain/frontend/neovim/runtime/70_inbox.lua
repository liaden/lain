-- The human inbox drain: lain://inbox's two gestures, an OPEN and an ANSWER.
-- Both are enqueue-and-ack commands -- the agent-side consumer resolves the
-- pending ask_human promise off its own queue, so the editor never blocks on
-- one -- and both name the row they are about the same way: the human's own
-- LINE plus the RENDERING STAMP that buffer carries. :LainOpen's comment below
-- is where that convention is argued; :LainReply, defined after it, follows it
-- because an answer and an open are the same question asked about the same row.

-- The cursor-on-an-item OPEN gesture: <CR> -- and `r`, repointed from the
-- one-line answer prompt it used to raise -- opens the question SET the cursor
-- sits on in lain://question. One verb, one vocabulary: a set of N questions
-- has no single-line answer, so the prompt does not survive as a fast path.
-- :LainReply stays for the answer it can still carry, hand-typed.
--
-- :LainPin's shape in every respect that matters, and its comment states the
-- rule this one follows too: the LINE rides as the argument, never a digest.
-- lain://inbox renders no digest on any of its lines (InboxView#line_for), so
-- the Ruby side's own line -> digest index is the only thing that can name the
-- set -- and that index is built by the same pass that produced the lines, one
-- entry per LINE, which is what lets a set's question fold under its
-- summary without a cursor in that fold answering the neighbouring set.
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
-- An earlier version sent the LINE COUNT for this, which was the only fact
-- the editor had before the stamp existed -- and a weak one: the queue drains
-- once per RPC tick, so the screen can be several renderings behind, and two
-- renderings of equal height are indistinguishable by count. Ruby then
-- resolved the gesture against the WRONG rendering and reported success. The
-- stamp is exact, and it is still not a digest: it says what the human is
-- looking at, and Ruby remains the only side that can name a set. What it does
-- NOT protect is a cursor that did not move while the list did -- it says
-- which rendering a line belongs to, never whether that is still the set the
-- human aimed at; InboxView::Gestures #open is where that analysis lives.
--
-- The buffer check is NOT redundant with the buffer-local maps below. `define`
-- makes every :Lain* command GLOBAL, and this one reads the CURRENT window's
-- cursor -- so hand-typed from lain://journal line 7 it would open whatever set
-- the inbox lists on ITS line 7, a set the human never looked at. Hand-typing
-- is an INVITED path here precisely because the maps invoke the command.
--
-- Which ROW a line belongs to, or nothing at all -- and this is a different
-- question from RECORD_START[INBOX], which is `spanning_record`.
-- "Does a record start here" is true of the blank and the keys under the list
-- and of the empty-state placeholder, none of which names a set: <CR> on one
-- is a keystroke about nothing, and an rpcrequest whose only possible answer
-- is "that line names no set" is worse than silence. The two tests still share
-- their one convention -- a continuation is a line the drawing side indented
-- (05_records' CONTINUATION) -- so the fold a human sees and the row this
-- resolves can never disagree about where an item begins.
--
-- A ROW is a line that convention did NOT indent, carrying InboxView#line_for's
-- two-space-padded age. Not anchored at column 1: `from` is a variable-length
-- sender name, so the age's COLUMN moves per line and there is nothing fixed to
-- anchor to; anchored on BOTH sides against the separator instead, which is
-- tighter than "digits followed by s/m/h" alone. The second pattern is that
-- same row with NO sender at all -- #line_for lstrips, and it has to, or a
-- record naming nobody would draw a summary opening with the very two spaces
-- read here as a continuation.
--
-- `%-?` in both because an age can be NEGATIVE: InboxView#age_of subtracts an
-- observation time from a later clock read and neither is monotonic, so an NTP
-- step or a suspend renders `-5s`. Two characters, and the failure they buy off
-- is the worst shape this file has -- the item still LOOKS answerable, folds
-- like its neighbours, and silently sends nothing when a human presses enter.
--
-- The walk UP is what makes every line of a folded item answer that item. What
-- rides is still the human's OWN line (:LainPin's rule), never the row this
-- found: Ruby's line -> digest map holds an entry per LINE, so the editor never
-- has to name a record and a wrong one stays unrepresentable.
local function inbox_row(lines, i)
  local at = i
  while at >= 1 and lines[at] ~= nil and lines[at]:match(CONTINUATION) ~= nil do
    at = at - 1
  end
  local row = at >= 1 and lines[at] or nil
  if row == nil then
    return nil
  end
  if row:match("  %-?%d+[smh]  ") ~= nil or row:match("^%-?%d+[smh]  ") ~= nil then
    return at
  end
  return nil
end

define("LainOpen", function()
  if vim.api.nvim_buf_get_name(0) ~= INBOX then
    -- ON THE RAIL, NOT ON `vim.notify`: `51_thread.lua` carries the measurement
    -- -- a plain notify blocks at roughly `#sentence + 12 > columns`, so it
    -- raises the very hit-enter prompt a refusal must not. The rail fits the
    -- line, keeps the whole sentence in `:messages`, and prepends the `lain: `
    -- this string therefore does not.
    -- `spec/refusal_delivery_discipline_spec.rb` is the gate.
    _G.__lain.review_refused(":LainOpen opens the question set under the cursor in " .. INBOX)
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local lines = cached_lines(buf)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  if inbox_row(lines, line) ~= nil then
    vim.rpcrequest(chan, "lain_command", "open", { line, vim.b[buf].lain_view_generation })
  end
end)

-- :LainReply {answer} submits the typed answer for the question set the cursor
-- sits on. The answer rides as the command's argument and the ROW rides beside
-- it -- :LainOpen's line and generation, resolved through :LainOpen's index --
-- so an answer names its own question rather than leaving the consumer to pick
-- one. Defined HERE and not at the top of the file because it reads the same
-- `inbox_row` :LainOpen does, and a local declared later is a global (nil) to
-- everything above it.
--
-- It used to send the answer ALONE, and the consumer then guessed: the OLDEST
-- item listed. That guess names a set only while one is pending AND it reached
-- HumanReplies::Pending at all -- and a question raised from the EDITOR while
-- the human sits at `you>` never does, so the guess was nil and the human was
-- told the row in front of them was stale. That is what became of the old note
-- here about one question being pending at a time: the invariant it leaned on
-- is ask_human's per-ASKER one, and a fleet has an asker per agent.
--
-- THREE CASES, NOT TWO, and the middle one is the whole of this gesture's
-- safety:
--
--   * NOT THIS BUFFER -- the answer goes on alone. `define` makes every :Lain*
--     command GLOBAL and this one reads the CURRENT window, so it is typable
--     from lain://journal, where a line number names something else entirely
--     and inventing a row from it is the wrong-set answer the stamp exists to
--     prevent. With no row named the consumer keeps its oldest-listed reading,
--     which is the rule the terminal drain reads a typed answer by.
--   * THIS BUFFER, ON A ROW -- line and stamp ride, and the answer names its
--     own question.
--   * THIS BUFFER, NO ROW -- the trailer blank, the keys hint, the empty-state
--     placeholder. NOTHING is sent. Falling back to oldest-listed HERE would
--     answer against a different list from the one this buffer renders, in the
--     one place the human can see the rows and believes they picked one; the
--     fallback above is honest only because there is no listing in front of
--     them to contradict.
--
-- It NOTIFIES where <CR> stays silent, and the asymmetry is deliberate: a
-- keystroke that does nothing is self-evident, while an answer the human TYPED
-- vanishing without a word reads as a reply that was delivered.
--
-- `inbox_row` decides all three, so the fold a human sees, the row <CR> opens
-- and the row an answer names can never disagree.
--
-- ⚠️ `{ answer, line, generation }` is a table CONSTRUCTOR, so a buffer with no
-- `b:lain_view_generation` (never stamped by set_view) builds a two-element
-- array -- msgpack carries the border, not the nil. Ruby then reads the stamp
-- as nil, `Renderings#holds?(nil)` is false, and the human is told to press
-- again: a refusal, never a wrongly-resolved row.
local function submit_reply(answer)
  if answer == "" then
    return
  end
  if vim.api.nvim_buf_get_name(0) ~= INBOX then
    vim.rpcrequest(chan, "lain_command", "reply", { answer })
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  if inbox_row(cached_lines(buf), line) == nil then
    -- ON THE RAIL, NOT ON `vim.notify`, for the reason `:LainOpen` above
    -- records: a plain notify raises the hit-enter prompt a refusal must not.
    -- `submit_reply` is a helper, but its callers are `define`d callbacks, so
    -- the door it reaches is theirs. The rail prepends the `lain: ` this
    -- string therefore does not.
    _G.__lain.review_refused("that line names no question set -- answer from a listed row")
    return
  end
  vim.rpcrequest(chan, "lain_command", "reply", { answer, line, vim.b[buf].lain_view_generation })
end

define("LainReply", function(opts)
  submit_reply(opts.args)
end, { nargs = "+" })

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
