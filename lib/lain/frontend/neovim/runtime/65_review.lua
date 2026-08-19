-- The annotation TEXT for every extmark, per review buffer: `buf -> id -> text`
-- (T16). The extmark itself carries only the position -- nvim moves it as the
-- human edits, which is the whole reason to use one -- so the words live here,
-- keyed by the id nvim answers with. The two are written together and MUST be
-- cleared together: a stale entry, or a mark whose text is gone, produces an
-- annotation with a missing key on the wire, and the Ruby side reads it as a
-- malformed review rather than as the bookkeeping slip it is.
local review_annotations = {}

-- Open a real file on disk for review (T16), in a focused split -- the same
-- deliberate focus-taking as set_compose, and for the same reason: lain is
-- handing the human something and asking them to work on it. The stamps are
-- what the `done` gesture sends back: `(generation, epic_slug)` is the review's
-- whole identity, because generations are drawn per epic and a bare number
-- cannot say which review it means.
--
-- The namespace is CLEARED, not just created: nvim answers with the same
-- namespace id for a name it already knows, so a second review of one file
-- would otherwise inherit the first review's extmarks while `review_annotations`
-- starts empty -- marks with no text, which is exactly the malformed-annotation
-- shape above.
function _G.__lain.open_review(path, generation, epic_slug)
  vim.cmd("belowright split " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  local namespace = vim.api.nvim_create_namespace("lain_review_annotations")
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  vim.b[buf].lain_annotation_namespace = namespace
  review_annotations[buf] = {}
  vim.b[buf].lain_review_generation = generation
  vim.b[buf].lain_review_epic_slug = epic_slug
end

-- What marks the words a one-line echo could not carry. The MIDDLE is what
-- goes: every sentence on this rail leads with the CONDITION and ends with the
-- REMEDY -- `:LainReviewDone`'s own two refusals below,
-- `Review::Surface::Neovim::PARTLY_MARKED` -- so a head-first clip would drop
-- exactly the half that says what to do next, and a refusal that names a
-- condition but not its remedy is the loop this rail exists to break.
local ELISION = " ... "

-- The least a refusal can say and still be one: something happened, and
-- `:messages` has it. Reached only where the message area cannot hold even an
-- elided line -- a pane under about seventeen columns -- and clipped in turn,
-- because at that width even this does not always fit. An empty echo was the
-- first answer here and it is the wrong one: a human who gestured and got a
-- blank message area has no reason to look in `:messages` at all.
local SENTINEL = "lain: ..."

local function elided(text, chars, keep)
  local head = math.floor(keep / 2)
  return vim.fn.strcharpart(text, 0, head) .. ELISION ..
    vim.fn.strcharpart(text, chars - (keep - head), keep - head)
end

-- Longest prefix of `text` that fits `room` cells.
local function clipped(text, room)
  local keep = math.min(vim.fn.strchars(text), room)
  local shown = vim.fn.strcharpart(text, 0, keep)
  while keep > 0 and vim.fn.strdisplaywidth(shown) > room do
    keep = keep - 1
    shown = vim.fn.strcharpart(text, 0, keep)
  end
  return shown
end

-- ONE LINE, not merely one line's worth of cells.
--
-- `nvim_echo` renders a newline as a LINE BREAK while `strdisplaywidth`
-- measures cells on a single axis, so the two disagree about the same string: a
-- two-line, fifty-three-cell sentence measured as fitting at 110 columns and
-- paged every time. Eliding is no answer either -- a head-and-tail cut of a
-- many-lined sentence still carries breaks in both halves -- so the breaks have
-- to go before anything is measured. This is not a corner case:
-- `CLI::HumanReplies#serve_editor_command` rescues `StandardError, ScriptError`
-- and puts `e.message` straight onto this rail, and a `ScriptError#message` from
-- Ruby 4's error formatter is FIVE lines.
--
-- ` / ` rather than a space, because a folded sentence that reads as run-on
-- prose hides the fact that it ever had a shape. Only the DISPLAYED line is
-- folded; `recorded` below writes the original, so a human sent to `:messages`
-- for a five-line syntax error finds it laid out as it was. A lone `\r` folds
-- with it: measured, nvim renders it inline as `^M` and `strdisplaywidth` agrees
-- at two cells, so it is not a paging risk -- but a control character mid-line
-- is not something to show a human either.
local function folded(text)
  return (vim.trim(text):gsub("%s*[\r\n]+%s*", " / "))
end

-- `v:echospace` is how many cells the message area holds before nvim raises its
-- hit-enter prompt: `&columns` less the eleven 'showcmd' reserves in the last
-- screen line, less one nvim keeps whatever the options say -- 98 at the 110
-- columns `lain up` gives the nvim pane, and 109 there under 'noshowcmd'.
-- 'ruler' costs nothing at the default `laststatus=2`, where the ruler lives in
-- the statusline rather than the last line. It answers for the LAST line only,
-- so a session running 'cmdheight' above 1 gets shortened more than it strictly
-- needs -- the safe direction, and measured: at `cmdheight=3` it still reads 98.
local function fitted(text)
  local room = vim.v.echospace
  if vim.fn.strdisplaywidth(text) <= room then return text end
  local keep = room - vim.fn.strdisplaywidth(ELISION)
  -- Under two kept characters the marker would BE the whole message, which says
  -- strictly less than the sentinel does; under its width, nothing fits at all.
  if keep < 2 then return clipped(SENTINEL, room) end
  local chars = vim.fn.strchars(text)
  local shown = elided(text, chars, keep)
  -- `strcharpart` counts CHARACTERS while the ceiling is in CELLS, so a wide
  -- glyph overflows a candidate cut to the right LENGTH. Shrink until it
  -- measures, rather than assuming one character is one cell. The floor is the
  -- bare marker, which the guard above has already proved fits.
  while keep > 0 and vim.fn.strdisplaywidth(shown) > room do
    keep = keep - 1
    shown = elided(text, chars, keep)
  end
  return shown
end

-- Put the WHOLE sentence in `:messages` with nothing on screen.
--
-- 'messagesopt' decides what nvim does when a message outgrows the message
-- area, and its `hit-enter` item IS the prompt. Swapped for `wait:0` for the
-- length of this one call, nvim records and prints and carries on; the option
-- goes back before anything else in the session can see it, and the `redraw`
-- takes the overflowed print back off the screen so the fitted line that
-- follows is the only thing left.
--
-- Both halves happen inside one call, so a plain grid UI never flushes between
-- them and no witness of the transient print exists there. A UI running
-- `ext_messages` (noice and friends) is the exception: it receives the full
-- sentence and the fitted line as two separate `msg_show` events and may render
-- both. That is the honest cost of the only route into the history, and it is
-- still bounded -- the second event is what a reader ends on.
--
-- Measured on nvim 0.12, and the reason this is not spelled the obvious way:
-- `nvim_echo(_, true, _)` is the ONLY route into the message history, and it
-- always DISPLAYS what it records, which is exactly what pages. Every "record
-- quietly" spelling records nothing at all -- `:silent echomsg`,
-- `:silent! echomsg`, `vim.fn.execute(..., "silent")` and
-- `nvim_exec2(..., { output = true })` each suppress the HISTORY along with the
-- display. 'shortmess' is no help either: `T` (truncate in the middle) is
-- already in the default and `nvim_echo` ignores it.
--
-- TWO PROMPTS, TWO OPTIONS, and 'messagesopt' only ever governed one of them.
-- A message wider than the area raises the hit-enter prompt (`mode == "r"`),
-- which is 'messagesopt's `hit-enter` item; a message TALLER than the editor
-- raises `-- More --` (`mode == "rm"`), which is 'more' and nothing else. The
-- recorded copy is deliberately the unfolded original -- that is the whole point
-- of recording separately -- so it is exactly the copy that can be tall, and it
-- paged on the second prompt while the first was handled. Measured: clean at 19
-- lines in a 20-line pane, blocking at 20; clean at 49 in a 50-line pane,
-- blocking at 50; `nomore` makes it vanish, which is what names the mechanism.
-- At 60 lines in a 20-line pane, twenty `<CR>`s did not clear it.
--
-- THE SWAPS ARE ON GLOBAL OPTIONS, so the echo is wrapped and both restores are
-- unconditional. An error escaping that one call used to leave `wait:0` in place
-- for the rest of the session, and with it nvim stops raising the hit-enter
-- prompt for ANY message from ANY source -- every over-long message anywhere
-- silently vanishing, which is a far worse failure than the one this rail was
-- built to fix. Verified by injecting a raise around `nvim_echo`: before the
-- `pcall`, a plain 400-cell echo from elsewhere afterwards read `blocking=false`.
-- With two options the live hazard is a PARTIAL restore, which is why both are
-- read back in the spec rather than only the one a given blocker named.
--
-- The error is deliberately not re-raised. Anything escaping a `define`d
-- callback gets nvim's own `stack traceback:` appended (the paragraph on
-- `:LainReviewDone` below carries that measurement), and a refusal that reads
-- as a plugin crash is the thing this rail exists to avoid. The DISPLAY half
-- still runs after this returns, so the human still gets their answer; what a
-- failure here costs is the copy in `:messages`, and nothing else.
local function recorded(full)
  local messagesopt, more = vim.o.messagesopt, vim.o.more
  vim.o.messagesopt = messagesopt:gsub("hit%-enter", "wait:0")
  vim.o.more = false
  pcall(vim.api.nvim_echo, { { full, "WarningMsg" } }, true, {})
  vim.o.messagesopt = messagesopt
  vim.o.more = more
  vim.cmd("redraw")
end

-- A `done` the Ruby side could not honour -- a generation it does not hold, a
-- file that moved, an annotation it could not read. Echoed rather than silent
-- because the human made a deliberate gesture and is owed an answer to it.
--
-- SIZE-AWARE ON THREE AXES, and it has to be. `nvim_echo` writes the MESSAGE
-- AREA and never reads a window (`Review::Surface::Neovim::MARKED` carries that
-- measurement), and a message the area cannot hold blocks the RPC rather than
-- merely the keyboard -- so `:messages` and `:LainApprove` are both unreachable
-- exactly while a refusal is on screen (F25 measured a full two-minute hang over
-- `--server`). A sentence can fail to fit in three separate ways, each with its
-- own prompt and its own option, and all three had to be closed before the rail
-- could survive ANY sentence handed to it rather than only the short ones its
-- callers send today:
--
--   CELLS   too wide for one message line  -> hit-enter, `mode == "r"`   ('messagesopt')
--   BREAKS  a newline renders as a line    -> hit-enter, `mode == "r"`   ('messagesopt')
--   HEIGHT  more lines than the editor has -> `-- More --`, `mode == "rm"` ('more')
--
-- Each was found separately and the first two fixes did not close the third, so
-- treat this list as the checklist any change here has to re-run. What "any
-- sentence" is worth is what was measured: eleven shapes crossing all three axes
-- -- 2000 lines in a ten-row pane, 20000 cells on one line, 200x400, CJK and
-- emoji in a six-row pane, a one-ROW pane, a 10x2 pane, 500 bare newlines, the
-- real five-line `ScriptError` in a three-row pane -- every one of them
-- `blocking = false` with a non-fast RPC round trip answering afterwards, and
-- both options back as found.
--
-- Two things are owed at once and one call cannot do both, because the flag
-- that records is the flag that displays. They are separated instead: the whole
-- sentence into `:messages` with nothing on screen, then one line that fits
-- onto the screen with nothing in `:messages` -- so history holds the sentence
-- exactly once and holds it whole. A refusal that already fits takes neither
-- path and is echoed exactly as it always was.
--
-- Answers with the line it DISPLAYED, which is the only record of it: the
-- fitted line is echoed with `history = false` and so is deliberately absent
-- from `:messages`, where the unshortened sentence lives instead. That makes
-- the return the sole witness of what a human actually saw -- an answer from a
-- function whose whole job is to put something on screen, not an accessor.
function _G.__lain.review_refused(message)
  local full = "lain: " .. tostring(message)
  local shown = fitted(folded(full))
  if shown == full then
    vim.api.nvim_echo({ { full, "WarningMsg" } }, true, {})
    return full
  end
  recorded(full)
  vim.api.nvim_echo({ { shown, "WarningMsg" } }, false, {})
  return shown
end

-- Annotation text for a buffer that is gone is text nothing can read again, and
-- this table would otherwise grow for the life of the session -- octo's own
-- registry defect. Cleared on unload, where the extmarks die anyway.
--
-- The reason recorded here first was that bufnrs get REUSED, which would make
-- this a correctness bug rather than a leak. Measured against this nvim: they do
-- not -- `nvim_create_buf` after a wipe answers a strictly higher number -- so
-- the growth is the whole of it. 41_layout's `buf_for` rides the same fact from
-- the other side: a remembered bufnr can go invalid, never come back as somebody
-- else's.
vim.api.nvim_create_autocmd("BufUnload", {
  group = vim.api.nvim_create_augroup("lain_review", { clear = true }),
  callback = function(ev) review_annotations[ev.buf] = nil end,
})

-- A note against the line the cursor is on (T16). The text is shown as virtual
-- text and remembered beside the extmark that holds its position, so it travels
-- with the line as the human keeps editing. The cursor row is 1-based and
-- extmarks are 0-based, which is the whole of the arithmetic here.
--
-- vim.ui.input is asynchronous under the dressing plugins that replace it
-- (dressing.nvim, noice, telescope), so the callback may run long after this
-- command returns. That is fine BECAUSE nothing here is sent: the note lands in
-- the buffer's own table and only :LainReviewDone puts anything on the wire.
define("LainAnnotate", function()
  local buf = vim.api.nvim_get_current_buf()
  local namespace = vim.b[buf].lain_annotation_namespace
  if namespace == nil then error("lain: :LainAnnotate needs an open lain review", 0) end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  vim.ui.input({ prompt = "Annotation: " }, function(text)
    if text and text ~= "" then
      local id = vim.api.nvim_buf_set_extmark(buf, namespace, row, 0, { virt_text = { { text, "Comment" } } })
      review_annotations[buf] = review_annotations[buf] or {}
      review_annotations[buf][id] = text
    end
  end)
end)

-- Hand the review back (T16). The command refuses rather than sending on a
-- modified buffer: the Ruby side settles from what is ON DISK, so unsaved edits
-- would be a review of bytes nobody has.
--
-- ONE argument after the verb, and it is an ARRAY. Every verb on this rail is
-- destructured Ruby-side as `verb, args`, so flat positionals arrive as the
-- generation alone and the rest is dropped on the floor -- which is what
-- happened: every done gesture was refused as "not open" and the annotations
-- were never even looked at.
--
-- Each annotation is a table with STRING keys, which is what a lua map becomes
-- on the other side of msgpack, and every key is always present: a mark whose
-- text has gone missing is SKIPPED, because a nil value drops its key from a
-- lua table entirely and the Ruby side would read the hole as a malformed
-- review rather than as a note that was never written.
--
-- BOTH refusals below answer through `__lain.review_refused` and RETURN,
-- rather than `error()`ing: this command is bound by `nvim_create_user_command`
-- (`define`, `30_commands.lua`), and nvim wraps every such callback in its own
-- protected call -- an error that escapes THIS function gets a Lua
-- `stack traceback:` appended underneath it no matter how it was raised
-- (measured: even `error(msg, 0)` gets one, and re-raising a caught error from
-- inside a `pcall` does too, because the traceback is nvim's own outer
-- wrapper's doing, not this function's). That reads as a plugin crash. A
-- refusal a human can act on is not one, and this is the command's OWN
-- refusal rather than one the Ruby side sent back over the wire, so it names
-- the surface itself: a buffer this guard rejects is not open for the EPIC
-- review `:LainReviewDone` hands back -- it is very likely a changeset review
-- or a survey, which answer to `:LainReviewVerdict {verdict}` instead
-- (`46_sidebar.lua:188`). `{verdict}` is a PLACEHOLDER -- see :h lain-runtime-commands
-- for doc/lain.txt's own spelling of this command's argument -- lua has no
-- `Lain::Review::VERDICTS` to read an exemplar off, unlike the banner
-- (`cli/command/survey.rb#drawn`, `cli/command/review.rb#drawn`), which shows
-- a real one for exactly that reason.
define("LainReviewDone", function()
  local buf = vim.api.nvim_get_current_buf()
  local generation = vim.b[buf].lain_review_generation
  local epic_slug = vim.b[buf].lain_review_epic_slug
  if generation == nil or epic_slug == nil then
    _G.__lain.review_refused(":LainReviewDone needs an open EPIC review, and this buffer is not one -- " ..
      "a changeset review or a survey hands back with :LainReviewVerdict {verdict} instead")
    return
  end
  if vim.bo[buf].modified then
    _G.__lain.review_refused("save the review before marking it done")
    return
  end
  local marks = vim.api.nvim_buf_get_extmarks(buf, vim.b[buf].lain_annotation_namespace or -1, 0, -1, {})
  local annotations = review_annotations[buf] or {}
  local payload = {}
  for _, mark in ipairs(marks) do
    local line, text = mark[2], annotations[mark[1]]
    if text then
      table.insert(payload, {
        line = line + 1,
        text = text,
        anchor_text = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1] or "",
      })
    end
  end
  vim.rpcrequest(chan, "lain_command", "review_done", { generation, epic_slug, payload })
end)
