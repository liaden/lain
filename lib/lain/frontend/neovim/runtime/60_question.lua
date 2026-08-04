-- lain://question (T12): compose_buf's shape exactly -- `acwrite` so `:w` can
-- be intercepted at all, a name so `:write` does not answer E32, "hide" so
-- BufUnload means the human closed it rather than merely looked away, markdown
-- because the document IS markdown -- plus the two indent options, which are
-- not preferences either.
--
-- Question::Document's comment slot is prose indented EXACTLY two spaces, and
-- a line indented any other way is refused BY NAME rather than dedented (the
-- grammar will not guess what a tab meant, because guessing is how a round trip
-- starts editing the human's whitespace). A human whose own config indents with
-- tabs would otherwise type a comment the grammar rejects on `:w`, on a line
-- they were invited to write. So the buffer produces the grammar's bytes
-- itself: 'expandtab' makes every indent spaces, 'shiftwidth' makes >> and
-- autoindent two of them, and 'softtabstop' makes the Tab KEY two -- the last
-- is not redundant, because with 'softtabstop' unset a Tab keypress inserts
-- 'tabstop' (8) spaces no matter what 'shiftwidth' says.
--
-- WHERE THIS DIVERGES FROM COMPOSE, and why it had to. `:wall` and autosave
-- plugins fire BufWriteCmd on text the human did not finish, which compose
-- accepts as a known limitation. The blast radius here is LARGER, not smaller,
-- and an earlier version of this comment claimed the opposite: a half-answered
-- document does not fail the grammar. It parses perfectly -- Question::AnswerSet
-- fills an untouched question in as an explicitly unanswered Answer, by design,
-- and `parse_markdown(to_markdown(a), set) == a` is the unit's stated law. So a
-- stock `:wall` over the document as lain rendered it told the model the human
-- had DECLINED EVERY QUESTION, closed the view, and answered their real `:w`
-- with STALE.
--
-- So the write below refuses a buffer byte-identical to what lain rendered,
-- and names `:w!` as the way through. That is not "you must answer before you
-- may submit" (Question::AnswerSet's ruling is explicit that an unanswered
-- question is a legal answer); it is refusing to read a keystroke nobody typed
-- as a decision. b:lain_question_rendered is that comparison's other half,
-- stamped beside the digest in set_question.
local function question_buf(name)
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
  vim.bo[buf].expandtab = true
  vim.bo[buf].shiftwidth = 2
  vim.bo[buf].softtabstop = 2
  -- AFTER 'filetype', deliberately: setting it fires FileType synchronously and
  -- nvim's own markdown ftplugin maps ]] and [[ to its section motions. lain's
  -- records ARE the questions, so lain's maps must be the ones that survive --
  -- this is the first buffer where RECORD_START serves folds and motions from
  -- the same predicate and the motions were not bound.
  bind_motions(buf, name)
  return buf
end

-- Open lain://question on a pending set's rendered document (T12), taking the
-- cursor for set_compose's reason: lain is handing the human something and
-- asking them to answer it.
--
-- FOCUSING an already-shown buffer is this function's job and not Ruby's, and
-- that division is deliberate. QuestionView REFUSES to open a set while one is
-- open, so nothing above ever re-renders over a half-ticked document -- which
-- means the only window-already-there case that reaches here is a fresh set
-- landing in a window the human left open, and putting them back in it is
-- exactly right. set_compose merely declines to stack a second split; this one
-- also moves the cursor, because a document that appears off-screen reads as
-- nothing having happened.
--
-- b:lain_question_digest is the set's CONTENT digest, not a counter: it stamps
-- the buffer, rides back with every write and abandon, and is what lets a write
-- naming a set nobody holds be dropped rather than reinterpreted against
-- whatever is open now.
-- b:lain_question_rendered is the OTHER half of the untouched-write refusal
-- (see question_buf): the bytes lain wrote, kept so the write can tell "the
-- human decided to answer nothing" from "nobody has touched this yet". Stamped
-- here rather than recovered later, because by the time `:w` fires the buffer
-- is the only copy of anything and it is the copy under suspicion.
--
-- The cursor lands on line 1, which open_at_rest has just made the OPEN
-- question: a form starts at the top, and being dropped inside a closed fold
-- is how a `dd` eats a question the human never read.
function _G.__lain.set_question(name, lines, digest)
  local buf = question_buf(name)
  vim.b[buf].lain_question_digest = digest
  vim.b[buf].lain_question_rendered = lines
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  local win = vim.fn.win_findbuf(buf)[1]
  if win == nil then
    win = vim.api.nvim_open_win(buf, true, { split = "below", win = 0 })
  else
    vim.api.nvim_set_current_win(win)
  end
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  announce_render(name, buf)
end

-- The question round trip's return leg (T12). Same gesture as compose -- `:w`
-- is "I am done with this text" -- and the same order, rpcrequest FIRST and
-- 'modified' cleared only once it returns.
--
-- What is NOT the same, and is the whole reason this buffer exists: this write
-- can be REFUSED. Ruby parses the document synchronously inside this request,
-- so a line the grammar has no slot for comes back as the request's ERROR
-- rather than as an ack, and erroring here leaves the buffer modified with the
-- human's own text for them to go fix. Nothing re-renders over it. The two
-- failures therefore share one path on purpose: "the grammar refused line 6"
-- and "lain was not there" are both a `:w` that did not save, and the message
-- carries which one it was.
--
-- The message rides the ERROR rather than an nvim_echo, and that is a choice
-- worth recording: nvim 0.12 appends a lua stack traceback under it (naming a
-- byte offset in an injected string, which is noise no human can act on), and
-- `error(msg, 0)` does not suppress that. The dodge -- echo the sentence, then
-- `error("", 0)` -- would move the one thing a human needs off the failure and
-- into `:messages`, where a scripted `:w` and a pcall cannot see it at all. The
-- sentence belongs to the write that failed.
local question_group = vim.api.nvim_create_augroup("lain_question", { clear = true })

-- The write nobody typed. `vim.v.cmdbang` is what `:w!` sets, and it is the
-- override: declining every question stays possible and stays CHOSEN.
local UNTOUCHED = "lain: nothing in this buffer has been typed, and a plain :w would answer every question as " ..
  "unanswered -- which is a decision, not a default. Answer something, or use :w! to submit it as it stands."

local function untouched(buf, lines)
  return vim.v.cmdbang == 0 and vim.deep_equal(lines, vim.b[buf].lain_question_rendered)
end

vim.api.nvim_create_autocmd("BufWriteCmd", {
  group = question_group,
  pattern = QUESTION,
  callback = function(ev)
    local lines = vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false)
    if untouched(ev.buf, lines) then
      error(UNTOUCHED, 0)
    end
    local ok, err = pcall(vim.rpcrequest, chan, "lain_command", "question", lines,
      vim.b[ev.buf].lain_question_digest)
    if not ok then
      error("lain: question NOT saved: " .. tostring(err), 0)
    end
    vim.bo[ev.buf].modified = false
  end,
})

-- BufUnload is the ABANDON signal, pcall'd for the compose leg's reason: one of
-- these cases is nvim EXITING, where Ruby may already have torn the RPC thread
-- down and an unanswered rpcrequest would surface as an autocmd error in the
-- human's face on the way out. Nothing is stranded by the loss -- no fiber
-- waits on a question, and the set stays pending in the inbox either way.
--
-- WHICH GESTURES UNLOAD, measured: `:bd!`, `:bw!`, `:q!` in the question
-- window, and quitting nvim all do, and each abandons carrying the digest.
-- `:close`, `:enew` and nvim_win_close do NOT -- `bufhidden = "hide"` means the
-- buffer survives being looked away from, which is the point, so the set stays
-- open with no window showing it. That is not a leak: QuestionView answers the
-- NEXT set with OCCUPIED naming this buffer, so `:buffer lain://question` is
-- always the way back.
vim.api.nvim_create_autocmd("BufUnload", {
  group = question_group,
  pattern = QUESTION,
  callback = function(ev)
    pcall(vim.rpcrequest, chan, "lain_command", "question_abandon", vim.b[ev.buf].lain_question_digest)
  end,
})

-- Ticking a box (T13), and it sends NOTHING: the human ticks, writes, and `:w`
-- once. What makes a local keymap possible at all is that the ARITY RIDES IN
-- THE HEADING, so a question's boundary and whether it takes one tick or many
-- are recoverable from buffer TEXT -- no rpcrequest, no state kept beside the
-- buffer. This is spec/lain/question/document_spec.rb's own buffer-only `scan`
-- ported: bounds from the nearest heading at or above the line to the next
-- heading below it, then the option lines inside them.
--
-- The two marks Question::Document::SELECTION_MARKS writes, and nothing else.
-- A mangled mark ("[?]") is deliberately NOT an option line here either: `x`
-- falls through to vim's own, which deletes the offending character -- the
-- grammar refuses that mark by name on `:w`, so the fall-through is the fix.
local QUESTION_TICKS = { [" "] = "x", ["x"] = " " }
local QUESTION_OPTION = "^%- %[([x ])%] `[^`]+` "

-- The mark's byte offset in "- [x] `id` label", 0-based for nvim_buf_set_text.
-- Writing the ONE byte rather than the line is what keeps every other byte of
-- the human's document -- and their cursor column, and any extmark on the line
-- -- exactly where it was.
local QUESTION_MARK_COLUMN = 3

local function option_mark(line)
  return line ~= nil and line:match(QUESTION_OPTION) or nil
end

-- The question the line at `row` belongs to: the row of its heading, and the
-- last row before the next question's. A body CANNOT forge either boundary --
-- Question::DOCUMENT_HEADING refuses a heading-shaped body line where the body
-- is BUILT -- which is why scanning to the nearest heading is safe.
local function question_bounds(lines, row)
  local heading = row
  while heading >= 1 and question_heading(lines[heading]) == nil do
    heading = heading - 1
  end
  if heading < 1 then
    return nil
  end
  local last = row
  while last < #lines and question_heading(lines[last + 1]) == nil do
    last = last + 1
  end
  return heading, last
end

-- The question's OPTION BLOCK: the LAST run of option lines between `first`
-- and `last`. That "last" is the whole defence against a body that shows the
-- grammar. A body is written verbatim and may legally hold a line matching
-- OPTION (a fenced diff showing `- [x] no` is the documented case), but the
-- renderer emits the options as one unbroken run preceded by a blank line, and
-- the comment beneath them is INDENTED -- so nothing below the block wears this
-- shape at column 0, and a body's option-shaped line is always separated from
-- the block by at least that blank. nil when the question has no run at all.
local function option_block(lines, first, last)
  local stop = last
  while stop > first and option_mark(lines[stop]) == nil do
    stop = stop - 1
  end
  if option_mark(lines[stop]) == nil then
    return nil
  end
  local start = stop
  while start > first and option_mark(lines[start - 1]) ~= nil do
    start = start - 1
  end
  return start, stop
end

-- What `x` would write, given where the cursor is: the option under it, and --
-- for a single-select question being TICKED -- the siblings whose ticks it
-- clears. nil for every other line, which is the fall-through to vim's own `x`.
local function tick_targets(lines, row)
  local mark = option_mark(lines[row])
  local heading, ends = question_bounds(lines, row)
  if mark == nil or heading == nil then
    return nil
  end
  local arity = question_heading(lines[heading])
  -- A free-text question offers nothing to tick, so the only option-shaped
  -- line under its heading is one its body showed -- the case the last-run rule
  -- above cannot see, because that run IS the last one.
  if arity == QUESTION_NONE then
    return nil
  end
  local first, last = option_block(lines, heading, ends)
  if first == nil or row < first or row > last then
    return nil
  end

  local writes = { { row = row, mark = QUESTION_TICKS[mark] } }
  if arity == QUESTION_ONE and mark == " " then
    for sibling = first, last do
      if sibling ~= row and option_mark(lines[sibling]) == "x" then
        table.insert(writes, { row = sibling, mark = " " })
      end
    end
  end
  return writes
end

-- The tick itself, reachable as an 'operatorfunc' (hence global, hence on the
-- __lain table -- it is NOT a render entry point and nothing about it crosses
-- the RPC rail, so it is no part of the protocol). It re-decides from the
-- buffer rather than trusting the map that scheduled it, because `.` replays
-- `g@l` DIRECTLY: the map does not run again, so this is the only guard a
-- repeat passes through. A repeat over a line with nothing to tick therefore
-- does nothing, which is what repeating "tick this" means -- notably NOT vim's
-- `x`, which would make `.` destructive on the human's prose.
--
-- The count and the register are dropped on this path, deliberately: `3x` ticks
-- once (an operator invocation is one call, whatever region `3l` covered) and
-- `"ax` yanks nothing, because a tick is not a delete and there is nothing for
-- a register to hold. Both are carried in full on the fall-through below.
function _G.__lain.tick()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local writes = tick_targets(cached_lines(buf), row)
  if writes ~= nil then
    for _, write in ipairs(writes) do
      vim.api.nvim_buf_set_text(buf, write.row - 1, QUESTION_MARK_COLUMN,
        write.row - 1, QUESTION_MARK_COLUMN + 1, { write.mark })
    end
  end
end

-- Ruling 11, and the half that is not optional: lain://question is `acwrite`
-- and the human types PROSE into it, so `x` off an option line must be vim's
-- `x`. (`p` in lain://timeline could be shadowed outright because a
-- NOMODIFIABLE buffer has no use for paste; this buffer is the opposite case.)
--
-- AN EXPR MAP, AND `g@` -- because of `.`, which is the most reflexive key a
-- vim user has. Both branches are dot-repeatable only in this shape:
--
--   returning "x" is not an imitation of vim's `x`, it IS vim's `x`. v:count
--   and v:register are still PENDING when a mapping fires and are applied to
--   the returned keys, so `"a3x` needs nothing reconstructed, and `.` repeats
--   the real thing because vim recorded the real thing.
--
--   "g@l" runs 'operatorfunc' over one character, and `g@` is dot-repeatable BY
--   CONSTRUCTION. A bare buffer write is not: it leaves no redo entry, so `.`
--   after a tick replayed whatever real change came before it -- the panel
--   caught a raw `x` from an earlier line eating a ticked option's "- ".
--
-- The write CANNOT happen here: an expr callback runs under textlock, where
-- nvim_buf_set_text answers E565. Reads and an option write are fine, which is
-- exactly what this branch does -- the buffer write is the operator function's,
-- and an operator function is not under textlock. That is the whole reason for
-- the indirection, and it is nvim's standard idiom for it.
--
-- cached_lines rather than a fresh read: every tick bumps changedtick, so this
-- does NOT skip the read on a run of ticks -- what it buys is one read per
-- keystroke shared with the foldexpr's own re-evaluation, which in a real
-- (non-headless) editor re-warms the cache between keystrokes anyway.
local function tick_or_delete()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  if tick_targets(cached_lines(buf), row) == nil then
    return "x"
  end
  vim.go.operatorfunc = "v:lua.__lain.tick"
  return "g@l"
end

-- Buffer-local, bound from a BufEnter in the question's own cleared augroup --
-- the inbox reply keys' shape, and for their reason: the buffer is created by a
-- gesture rather than at attach. A GLOBAL `x` would break deleting a character
-- in every other buffer the human has open. The desc names BOTH halves: on most
-- lines of this buffer the map is vim's `x`, and `:map x` saying only "tick"
-- would tell the human the wrong thing about the line they are on.
vim.api.nvim_create_autocmd("BufEnter", {
  group = question_group,
  pattern = QUESTION,
  callback = function(ev)
    vim.keymap.set("n", "x", tick_or_delete,
      { buffer = ev.buf, expr = true, desc = "lain: tick the option under the cursor, else vim's x" })
  end,
})
