-- A PANE for a note too long to type into the cmdline. `:LainNoteCompose {kind}`
-- opens it against the line the cursor is on; `:w` places the note. Everything
-- afterwards -- the marker, the drift measurement, the hand-back -- is
-- `48_annotate.lua`'s, unchanged: this module takes ONE reservation out of that
-- module and spends it, and owns nothing else about a note.
--
-- THE PLACE IN LINE IS TAKEN WHEN THE PANE OPENS, WHICH IS THE WHOLE POINT. A
-- human who starts a long note on line 10, remembers something and drops a quick
-- cmdline note on line 20, then finishes and writes the pane, has made their two
-- decisions in that order -- and `48_annotate`'s header calls that order the
-- module's output. A number taken at COMMIT time would hand them back reversed,
-- and no assertion about either note's content or position would ever catch it.
--
-- `vim.ui.input` IS FORBIDDEN AND NOT MERELY UNFASHIONABLE, `48_annotate.lua`
-- rejects it in terms one screen above `:LainNote`, and this module is where
-- that rejection would have cost the most: the prompt is asynchronous under the
-- dressing plugins that replace it (dressing.nvim, noice, telescope), so two
-- overlapping prompts put the placement SEQUENCE at the mercy of how fast the
-- human types. A `:w` is a discrete synchronous event on the main loop, which is
-- exactly why this shape has the ordering problem that shape does not.
--
-- THE FOUR OPTIONS ARE `51_thread.lua`'s AND THEY ARE NOT PREFERENCES:
--
--   buftype = "acwrite"  -- `nofile` refuses `:write` with E382 BEFORE any
--                           autocommand runs, so BufWriteCmd would never fire.
--   nvim_buf_set_name    -- an acwrite buffer with no name fails `:write` with
--                           E32, and the name is what the BufWriteCmd pattern
--                           matches on.
--   bufhidden = "hide"   -- a long note is long; stepping over to the diff to
--                           re-read the line must not throw the draft away.
--   buflisted = false    -- one pane PER NOTE, the thread pane's reason: a
--                           review with a dozen of them would bury the human's
--                           own files in `:ls` and `:bnext`.
--
-- THE NAME IS THE IDENTITY AND THE MODULE HOLDS NOTHING ELSE. There is no
-- `b:lain_note`: what the pane is for lives in `review_notes.reserved`, keyed by
-- this buffer's name, and the pane reads it back the same way on every write.
-- That is not tidiness. A buffer variable dies with `:bdelete` while the NAME
-- survives, so a husk's `:w` used to find no state, conclude the note had been
-- placed, and report a successful write over a note nothing ever placed. Module
-- state keyed by the surviving half cannot say that.
--
-- THE NAME IS ALSO CHOSEN, NOT DERIVED, and that is a fix rather than a taste.
-- `review_notes.placed` is CHUNK state: `RuntimeLoader` injects the runtime once
-- per attach, so it starts again at one -- while nvim outlives the Ruby process
-- (`lain up` reattaches to a tmux session whose editor pane is still there) and
-- a hidden pane keeps its name. Naming a fresh buffer `lain://note/1` over a
-- surviving one is E95, raised out of a `define`d callback wearing nvim's own
-- `stack traceback:` and, with a UI attached, a hit-enter prompt behind which
-- every non-fast RPC queues -- and it leaves an ORPHANED unnamed acwrite buffer
-- behind every time, because the buffer is created before it is named. So the
-- name is the first one no buffer holds, the sequence is whatever `reserve`
-- says, and the two are allowed to differ. `20_buffers.lua`'s header states the
-- general case this belongs to: a `lain://` buffer surviving from an older
-- attach is NORMAL.
--
-- IT IS NOT A THIRD WRITER OF THE STAMP STATE, and that is a constraint rather
-- than an observation. A buffer this round opened is in one of two states with
-- exactly two writers -- HELD (`47_diff`'s three stamp variables, still
-- `review_notes.stamp`'s single membership test) or PUT DOWN AND REMEMBERED
-- (`b:lain_review_round`, written by `withdraw` and read by `reacquire`).
-- Nothing here writes any of those four. The pane's own buffer is never stamped,
-- so `bind_note_keys` entering it finds no stamp and binds no note key, and
-- `review_diff.entered` finds neither a claim to withdraw nor a round to
-- re-acquire against -- measured for real, inside the review's tabpage, which is
-- the entry that could have re-acquired. The stamp is READ ONCE, at open, and
-- COPIED into the reservation -- `place`'s own rule, which reads it at placement
-- for the same reason: by the time a long note is finished, the human may have
-- navigated on and `47_diff` withdrawn the stamp.
--
-- IT TAKES NO REVIEW SLOT. `41_layout.lua` records that on a survey the thread
-- pane already borrows the `old` slot, and a second borrower would need a rule
-- about which of them wins. This needs none: the pane is an ordinary split under
-- the window the human pressed the key in, carrying no `w:lain_review_slot`, so
-- `review_panes.map` does not see it, `shed` cannot close it and `review_place`
-- cannot land a render in it. It is the human's window, opened by the human's
-- gesture, closed by their `:q`.
--
-- A `:q`d PANE IS HIDDEN, NOT GONE, AND THE HUMAN IS TOLD ITS ADDRESS. `hide`
-- plus `buflisted = false` means `:ls` does not show it and no gesture reaches
-- it: the draft is there, modified, holding their words, and unfindable. The
-- open echo names the buffer for exactly that reason -- it is the one moment
-- lain can -- and `assert_placed` names it again if they try to settle around it.
--
-- 52, after 48_annotate (`reserve`, `anchor`, `holding`, `release` and `stamp`)
-- and after 30_commands (`define`, `lain_prefix`) and 20_buffers (`claim`). ONE
-- new top-level name, the chunk's economy: the binding cap is 60 upvalues per
-- function prototype and every top-level local is a name every later module pays
-- for.
local note_compose = {
  -- The buffer name's stem. A buffer PER NOTE, so two panes open at once are two
  -- drafts and not one clobbering the other.
  PREFIX = "lain://note/",
}

-- A buffer under this EXACT name, whoever it belongs to. `nvim_buf_get_name`
-- rather than `vim.fn.bufnr`, and `51_thread.named` carries the measurement:
-- the argument to `bufnr` is a PATTERN, so `lain://note/1` finds `lain://note/10`
-- -- which here would answer "taken" for a free name and, worse, "free" for
-- none. The scan is O(buffers) and runs once per gesture.
function note_compose.named(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == name then
      return buf
    end
  end
  return nil
end

-- The first name no buffer holds. See the header: a hidden pane from a previous
-- attach keeps its name while the counter that would have picked it starts again
-- at one, so a name has to be CHOSEN against the editor rather than derived from
-- chunk state that does not outlive the attach.
--
-- It never reclaims a survivor, and that is deliberate: that pane belongs to a
-- round nobody is holding any more -- its target buffer, its revision and its
-- stamp all died with the previous attach -- so its words can no longer be
-- placed anywhere. Leaving it where it is keeps them readable; writing over it
-- would not.
function note_compose.free_name()
  local n = 1
  while note_compose.named(note_compose.PREFIX .. n) ~= nil do
    n = n + 1
  end
  return note_compose.PREFIX .. n
end

-- What the human typed, which here is the whole buffer: lain renders nothing
-- into this pane, so there is no rendering of its own to exclude. Trimmed, so
-- the blank line an empty pane starts on and the whitespace a wandering cursor
-- leaves are both "nothing typed" rather than a note made of spaces.
--
-- Lines are joined with newlines and NOT reflowed. `Review::Wire.text` interns a
-- note's text without stripping it (its own comment says why: an anchored line's
-- indentation is evidence a drift check compares), so a paragraph typed over
-- four lines reaches the journal as four lines.
function note_compose.typed(buf)
  local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
  return text ~= "" and text or nil
end

-- The pane, made once per reservation, under a name nothing else holds.
function note_compose.buf(name)
  local buf = claim(vim.api.nvim_create_buf(false, true), name)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  return buf
end

-- Where the pane goes, and it TAKES FOCUS -- `55_compose.lua`'s one exception to
-- "a render moves nobody", for its reason: the human just pressed a key asking
-- to be put somewhere to type.
--
-- A SPLIT UNDER THE WINDOW THEY PRESSED IT IN, never a review slot. See the
-- header. Ten rows is a paragraph with room to see it; a human who wants more
-- resizes, which is a gesture they already have and needs no option to keep in
-- sync with a help file.
function note_compose.open(buf)
  vim.api.nvim_open_win(buf, true, { split = "below", win = 0, height = 10 })
end

-- Open a pane for a long note against the line the cursor is on.
-- `:LainNoteCompose {kind} [the first words of it]`.
--
-- `nargs = "+"` AND `fargs[1]`, which is `:LainNote`'s shape and is forced by the
-- key: `<leader>Lc` pre-fills the cmdline exactly as `<leader>Ln` does, and that
-- key's contract is "the kind, then your words". Under `nargs = 1` nvim does not
-- split, so `fargs[1]` is the WHOLE argument line -- and a human who kept typing
-- had all of it echoed back as a mistyped kind, measured at 98 columns against a
-- budget of 80. Splitting makes the echoed kind one whitespace-free token, and
-- the words that follow SEED the pane rather than being dropped on the floor:
-- they are the beginning of the note, taken from the raw argument string so the
-- human's own spacing survives (`:LainNote`'s rule, for its reason).
--
-- EVERY REFUSAL RIDES `__lain.review_refused` AND RETURNS, `:LainNote`'s rail
-- and F72's fix: an `error()` escaping a `define`d callback wears nvim's own
-- `stack traceback:` however it was raised, and with a UI attached raises a
-- hit-enter prompt behind which every non-fast RPC request queues -- including
-- the `:messages` the refusal tells them to read. NONE of them spells `lain: `,
-- because the rail prepends exactly one.
--
-- NOTHING IS RESERVED UNTIL EVERY REFUSAL IS PAST, `open_changeset`'s rule: a
-- gesture that half happened is worse than one that did not.
define("LainNoteCompose", function(opts)
  local buf = vim.api.nvim_get_current_buf()
  local stamp = review_notes.stamp(buf)
  if stamp == nil then
    -- The sentence `:LainNote` gives, shortened by exactly what the longer verb
    -- costs: 70 columns with the rail's prefix, against the 80
    -- `refusal_delivery_discipline_spec.rb` measures mechanically. `<C-o>` for
    -- that refusal's reason -- it is nvim's own way back from a jump, needs no
    -- window the human can still see, and landing is what re-acquires the stamp.
    _G.__lain.review_refused(":LainNoteCompose needs a buffer lain has open -- <C-o> goes back")
    return
  end
  local kind = opts.fargs[1]
  if review_notes.MARKERS[kind] == nil then
    -- THE VOCABULARY IS 23 COLUMNS AND THE FRAME IS 39, so this fits the budget
    -- with twelve columns of their word on the end -- four fewer than
    -- `:LainNote`'s, which is exactly what the longer verb costs. Their word
    -- goes LAST because it is the unbounded field, so a mistyped kind long
    -- enough to page has its MIDDLE elided by the rail and keeps both the
    -- command that refused and the tail of what they typed.
    _G.__lain.review_refused(":LainNoteCompose takes a kind: " ..
      table.concat(review_notes.kinds(), ", ") .. " -- got " .. tostring(kind))
    return
  end

  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  -- THE BUFFER FIRST, THEN THE CLAIM, and the order IS the invariant rather than
  -- an accident of how these statements were typed. A claim is a buffer name, and
  -- `assert_placed`'s only remedy is `:bwipeout <claim>` -- so a claim naming no
  -- buffer is a refusal whose remedy answers E94, which is the one way that guard
  -- can trap a human. Reserving first left that true only for as long as nothing
  -- between the two lines could fail; making the buffer first leaves nothing that
  -- can. Keeping it true AFTERWARDS is what the two autocmds at the foot of this
  -- file are for, and neither half is sufficient alone.
  local name = note_compose.free_name()
  local pane = note_compose.buf(name)
  review_notes.reserve(name, {
    target = buf,
    row = row,
    kind = kind,
    -- READ AT OPEN, `place`'s own rule: the line as the human saw it when they
    -- began. An edit to the reviewed buffer while they are still typing makes
    -- this disagree with what the row says at settle, which is exactly what
    -- `wired` reports as drift -- the honest reading, not a miss.
    anchor_text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "",
    side = stamp.side,
    revision = stamp.revision,
    path = stamp.path,
  })

  local seed = opts.args:match("^%S+%s+(.*)$")
  if seed ~= nil then
    vim.api.nvim_buf_set_lines(pane, 0, -1, false, { seed })
  end
  note_compose.open(pane)
  -- THE ADDRESS IS THE SUBSTANCE HERE, not decoration. `hide` plus unlisted
  -- means a pane the human backs out of with `:q` is absent from `:ls`, present
  -- only in `:ls!`, and reachable by no key -- so this is the ONE moment lain can
  -- tell them where their draft lives. `:b` prefers an exact name over a longer
  -- one containing it (measured on 0.12.4 with `lain://note/1` beside
  -- `lain://note/10`), so the address it gives is unambiguous.
  --
  -- THE PATH GOES LAST, `assert_saved`'s rule for an unbounded field: lain's own
  -- words and the way back come first, so a shortened echo truncates the file
  -- and not the address. 45 columns of frame; 65 with this pane's name and a
  -- four-character path.
  _G.__lain.review_refused(":w places this note; :b " .. name ..
    " comes back -- " .. stamp.path .. ":" .. (row + 1))
end, {
  nargs = "+",
  -- Only ever the FIRST argument: the rest is the beginning of the human's note,
  -- and offering them `blocker` halfway through a sentence is worse than
  -- offering nothing. `:LainNote`'s completion, for its reason.
  complete = function(lead, line)
    if line:match("^%s*LainNoteCompose%s+%S*$") == nil then
      return {}
    end
    return vim.tbl_filter(function(kind) return vim.startswith(kind, lead) end, review_notes.kinds())
  end,
})

local note_compose_group = vim.api.nvim_create_augroup("lain_note_compose", { clear = true })

-- The pane's return leg. `:w` is the gesture for compose's, question's and the
-- thread pane's reason: it is the one verb every vim user already reads as "I am
-- done with this text".
--
-- ORDER IS THE CORRECTNESS, and it is the thread pane's order with the wire
-- taken out of it. There the rpcrequest goes first and 'modified' is cleared
-- only once it returns; here `anchor` is what takes the human's words, so it
-- goes first and 'modified' is cleared only once it has.
--
-- THREE LEGS, AND WHAT EACH DOES TO 'modified' IS THE DIFFERENCE BETWEEN THEM.
-- Leaving the flag set is how a `:w` FAILS -- measured on nvim 0.12, a
-- `BufWriteCmd` that returns without clearing it leaves the buffer dirty, `:w`
-- says nothing was written and `:wq` declines to quit -- so the rule is that a
-- write which placed nothing must not come back clean, and a write whose note
-- really was taken must not come back dirty.
vim.api.nvim_create_autocmd("BufWriteCmd", {
  group = note_compose_group,
  pattern = note_compose.PREFIX .. "*",
  callback = function(ev)
    local name = vim.api.nvim_buf_get_name(ev.buf)
    local held = review_notes.holding(name)
    if held == nil then
      if vim.b[ev.buf].lain_note_placed then
        -- THE SECOND `:w`, which `BufWriteCmd` fires whether or not the buffer is
        -- modified -- so without this the identical note would be placed twice,
        -- on one line, under two sequence numbers. The buffer is left CLEAN:
        -- this pane's note really was taken, and a write reporting failure over
        -- that would be the lie in the other direction.
        _G.__lain.review_refused("this pane's note is already placed; a new one: " .. lain_prefix() .. "c")
        return
      end
      -- THE HUSK, and the one leg where "reaching here means they typed
      -- something" is FALSE. `:bdelete` throws the draft away and keeps the
      -- name, so the buffer comes back `buftype = ""`, empty and UNMODIFIED --
      -- and a `:w` that placed nothing exited clean, silently, while this rail
      -- said the note had been placed. It had not. So the flag is set here
      -- rather than merely left, which is this module's rule applied on the one
      -- path the human's own typing did not already satisfy it.
      vim.bo[ev.buf].modified = true
      _G.__lain.review_refused("nothing is pending in this pane; a new one: " .. lain_prefix() .. "c")
      return
    end
    local text = note_compose.typed(ev.buf)
    if text == nil then
      -- 'modified' IS DELIBERATELY LEFT SET, the thread pane's ruling: whitespace
      -- under nothing is not a note, and clearing the flag would be this pane's
      -- one write that says "saved" over text lain never took.
      _G.__lain.review_refused("this pane has no note in it yet -- write one, then :w again")
      return
    end
    if not vim.api.nvim_buf_is_valid(held.target) or
        held.row >= vim.api.nvim_buf_line_count(held.target) then
      -- The reviewed buffer went away underneath the pane -- `47_diff.drop_stale`
      -- wipes the previous file's old side the moment the next row opens, which
      -- is reachable for a note begun on the old side and finished after
      -- navigating. Their words are still in front of them and the pane is still
      -- theirs; what is gone is the line to hang them on.
      _G.__lain.review_refused("the line this note was opened on is gone; nothing was placed")
      return
    end

    local placed, refusal = pcall(review_notes.anchor, name, text)
    if not placed then
      -- THE CAUSE GOES LAST, this module's own rule for an unbounded field: a lua
      -- error carries a chunk name and a line number and has no bound, so the
      -- statement the human needs -- nothing was placed, nothing was lost -- is
      -- what survives a shortened echo. 56 columns before the cause.
      _G.__lain.review_refused("the note was NOT placed; your text is untouched -- " .. tostring(refusal))
      return
    end
    -- THE RECEIPT FOR THIS PANE, which is what makes the second `:w` above
    -- readable. It is a receipt and not the invariant: it dies with the buffer,
    -- and that is right -- a husk has no note of its own to have placed.
    vim.b[ev.buf].lain_note_placed = true
    vim.bo[ev.buf].modified = false
    _G.__lain.review_refused("note placed on line " .. (held.row + 1) ..
      "; :LainNoteDone hands it back")
  end,
})

-- The place in line, given back when the draft holding it stops existing.
--
-- `BufUnload` and not `BufWipeout`, because `:bdelete` is the commoner gesture
-- and it destroys the contents just as thoroughly -- the husk it leaves is a
-- name and nothing else. `bufhidden = "hide"` means a `:q` does NOT reach here,
-- which is the split that matters: a hidden pane still holds its draft AND its
-- place in line, and `assert_placed` is what tells the human so when they try to
-- settle around it.
--
-- Without this, a human who deleted a pane could never settle again: the
-- reservation would stand for the life of the attach and refuse every
-- `:LainNoteDone` naming a buffer they had already thrown away.
vim.api.nvim_create_autocmd("BufUnload", {
  group = note_compose_group,
  pattern = note_compose.PREFIX .. "*",
  callback = function(ev) review_notes.release(vim.api.nvim_buf_get_name(ev.buf)) end,
})

-- The same place in line, given back when the pane stops being lain's at all.
--
-- `:file` and `:saveas` rename a buffer IN PLACE and unload nothing, so the
-- autocmd above never fires and the claim was stranded under a name whose buffer
-- no longer holds the draft: `assert_placed` then refused every settle for the
-- life of the attach, naming a buffer that could not lead anybody back to their
-- words. `47_diff` carries a `BufFilePost` handler for this exact gesture on a
-- buffer that is `nowrite` AND `nomodifiable` -- it succeeds even there -- so it
-- is a real thing humans do and not a corner.
--
-- `BufFilePre` AND NOT `BufFilePost`, which is the whole subtlety: the claim IS
-- the old name, and by `BufFilePost` the buffer no longer has it. `47_diff` wants
-- the post-state because it is judging what the buffer has BECOME; this is
-- releasing what it WAS.
--
-- The draft itself is untouched and their words stay in front of them. What they
-- lose is the place in line, which is right: the buffer they renamed is a file of
-- their own now, its `:w` writes it, and lain has nothing left to place.
vim.api.nvim_create_autocmd("BufFilePre", {
  group = note_compose_group,
  pattern = note_compose.PREFIX .. "*",
  callback = function(ev) review_notes.release(vim.api.nvim_buf_get_name(ev.buf)) end,
})
