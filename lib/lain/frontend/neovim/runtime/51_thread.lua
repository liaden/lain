-- One anchor's conversation, shown in the diff pane the cursor is NOT in (T18),
-- and swapped as the cursor moves. Ported from octo.nvim's review thread panel
-- (MIT) -- `thread-panel.lua:62-88` for the buffer swap, `autocmds.lua:66-74`
-- for the CursorMoved trigger with a buffer-variable bail-out, `layout.lua:246-295`
-- for noticing a window arrangement the human has clobbered -- with its two
-- known defects fixed rather than inherited (see IDEMPOTENCE and NO REGISTRY
-- below).
--
-- THE PANE IS PERSISTENT AND ITS BUFFER IS SWAPPED. No window is created or
-- destroyed as the cursor moves, which is what makes this cheap enough to hang
-- off CursorMoved at all: creating a window per annotated line is the flicker
-- and layout churn octo's panel exists to avoid. The conversation lives in a
-- real buffer rather than in virtual text because it can be long, and because a
-- buffer can be searched, yanked, scrolled and typed into -- the last is the
-- point, since the reply goes back through `:w`.
--
-- A RENDER MAY REBUILD THE LAYOUT; A CURSOR MOVE MAY NOT, and the two callers
-- of `refresh` are split on exactly that. `review_place` re-ensures the whole
-- review tabpage, which is right for a render arriving after the human closed a
-- window (41_layout says so, and dropping the render would lose it) and wrong
-- for a motion: closing the review tabpage IS the human's dismiss gesture, and
-- the first version of this module answered a `20G` in the human's own file, in
-- their own tabpage, by materialising a three-window review out of nothing. The
-- same split is what lets the human close the thread pane and have it STAY
-- closed -- a pane that comes back on the next column move is a plugin nobody
-- keeps. So the sentence above holds for the trigger and only for the trigger.
--
-- WHICH PANE. The opposite one: reading the new side puts the thread on the
-- old, and vice versa. The sidebar is never touched -- it is the navigator, and
-- a review whose file list vanished when the cursor crossed a note would be
-- unusable.
--
-- WHAT CROSSES THE WIRE, and the one place this reads T11's parameter more
-- richly than its name. `SET_THREAD` names its first argument `anchor_id`, and
-- its reasoning -- key on an id Ruby minted, never on a line, because a line
-- only names a position in the rendering that drew it -- is kept exactly. What
-- that reasoning does not supply is the fact this module cannot work without:
-- WHERE the anchor sits. Nothing else on this rail carries it (`open_changeset`
-- carries the file, never its notes), the pane is cursor-driven, and only Ruby
-- knows. So the anchor arrives whole -- `{ id, path, side, line }` -- and the
-- id stays OPAQUE here: it is a key and a stamp, never parsed, which is the
-- half of T11's rule that binds. A bare id is refused BY NAME rather than
-- accommodated, so a caller sending the old shape learns why in one sentence
-- instead of watching a pane that never opens.
--
-- IDEMPOTENCE, octo's first defect. octo guards its HIDE path and not its SHOW
-- path, so every CursorMoved on a commented line re-runs `nvim_win_set_buf`,
-- its configure step, its keymaps and `diffoff!`. Here the guard is on both,
-- because there is only one path: what the pane already shows is compared with
-- what the cursor now wants, and equal means return. Moving by one column is
-- the common case and costs a buffer-variable read, an extmark query scoped to
-- one row, and a comparison.
--
-- The bail-out for every OTHER buffer -- which is the cost a human pays for
-- having lain attached at all -- is a single buffer-variable read of T15's
-- `b:lain_review_side`. Measured on a 20,000-line buffer: 0.47us for that read,
-- 0.67us for the extmark query, against a redraw three orders of magnitude
-- larger.
--
-- NO REGISTRY, octo's second defect. octo keeps `bufnr -> threads` in a module
-- table that grows for the life of the session; the card asks for a
-- `BufWipeout` sweep of it. The stronger fix is the one 41_layout already made
-- for the layout's own bookkeeping: keep it ON the thing it describes, so there
-- is nothing to sweep. A diff buffer's anchors live in `b:lain_thread_anchors`
-- and die with that buffer; a thread buffer's identity lives in
-- `b:lain_thread_anchor` and dies with it; and "which thread is the pane
-- showing" is READ OFF THE PANE rather than remembered, so it cannot disagree
-- with the editor -- a re-opened changeset that re-places both diff buffers
-- resets it for free, with nothing here noticing.
--
-- Say what that does and does not buy, because the first version of this header
-- overclaimed it and a panel measured the difference. `b:lain_thread_anchors`
-- keeps ONE entry and ONE extmark per anchor, however often a thread is sent,
-- and every entry is checked before it is believed -- so the residue is bounded
-- by the anchors the session actually saw and is inert, not absent. A wiped
-- thread is no thread at all: `anchor_at` answers nil and the pane keeps the
-- diff, which is what a stale registry would get wrong on every keystroke.
--
-- IDENTITY IS THE STAMP; THE BUFNR IS A HINT. The entry carries a bufnr because
-- resolving one by scanning is O(buffers) and this runs per keystroke on an
-- annotated line -- but it is resolved through `found(id)` the moment the hint
-- stops answering, which is what makes the hint safe rather than what makes it
-- fast. `nvim_buf_is_valid` is NOT the test, and that mistake is worth naming:
-- nvim clears a buffer's variables on UNLOAD and keeps the buffer and its name,
-- so `:bdelete`, `:bunload` and a `:mksession` restore all leave a valid,
-- unstamped, EMPTY husk under the thread's own name. Believing it showed the
-- human `[""]` where their conversation was, and naming a fresh buffer then
-- raised E95 -- for the rest of the session, leaking one buffer per render.
-- `buf()` reclaims such a husk instead: the human's gesture was "close this",
-- not "lose this".
--
-- DIFF MODE IS NVIM'S TO RESTORE WHILE THE WINDOW SURVIVES, AND OURS ON THE
-- REPAIR PATH -- the card's second escalation trigger, measured rather than
-- assumed, in both halves. octo calls `diffoff!` on the thread buffer; here
-- that is both unnecessary and harmful, because 'diff', 'foldmethod',
-- 'scrollbind' and 'wrap' are window-local PER BUFFER: nvim unsets them when
-- the thread buffer lands in the pane and restores them when the diff buffer
-- comes back, with the folds the human had open still open. Measured on nvim
-- 0.12.4 against a 40-line pair: swapping in a fresh buffer gives
-- `diff = false, foldmethod = manual` while the other side stays `diff = true`;
-- swapping the diff buffer back gives `diff = true, foldmethod = diff` and the
-- same 14 hidden lines as before. An UNCONDITIONAL `diffthis` on the restore
-- path re-closes every fold (14 hidden -> 27), the human's reading position
-- destroyed on every step off a note; and `diffoff!` is worse than
-- unnecessary, since its bang means every window in the tabpage -- the "unsets
-- the wrong window" half of the trigger.
--
-- What that reasoning does not cover is a window the human CLOSED. Its saved
-- winopts died with it, and nvim unsets 'diff' in the survivor when one of a
-- pair closes, so a rebuilt pane comes back holding the old side as a plain
-- buffer: a two-pane view that looks like a review and diffs nothing, silently.
-- `open_changeset` re-establishes it through 47_diff's `pair()`; this is the
-- only other caller of `review_place` for those buffers, so `rediff` owes the
-- same -- GATED on the window not already being in diff mode, which is the
-- whole difference between the fix and the fold-destroying regression above.
--
-- 51, after 41_layout (`review_place`, the seam it renders through), 20_buffers
-- (`claim`, `announce_render`, `jump_record`) and 30_commands (`define`). ONE
-- new top-level name, 41_layout's economy: the chunk shares one scope and the
-- cap that binds is 60 upvalues per function prototype.
local review_thread = {
  -- The buffer name's stem; the anchor's id completes it. A buffer PER ANCHOR,
  -- so a half-typed reply belongs to the thread it was typed in and survives
  -- the cursor moving away.
  PREFIX = "lain://thread/",

  -- Cursor side -> the slot its thread lands in. Doubles as the membership test
  -- for a side, which is why `set_thread` can refuse an unknown one from the
  -- same table that routes a known one -- one spelling, not two.
  OPPOSITE = { old = "new", new = "old" },

  -- Where a message starts, for ]]/[[. The other half of this vocabulary is
  -- {ThreadView::SPEAKER_PREFIX}; a static chunk can derive nothing from Ruby,
  -- so the two are pinned by BEHAVIOUR in `thread_view_spec.rb` -- a real
  -- rendering driven into a real editor, and ]] asserted to land on the second
  -- speaker.
  ENTRY = "^## ",
}

-- Extmarks, not line numbers: the new side is a REAL file buffer the human can
-- edit (`do`/`dp` in diff mode is the ordinary gesture), and 47_diff's header
-- states outright that T18's threads anchor in marks. A mark inside a rewritten
-- span MOVES rather than invalidates, which is the extmark contract this rides
-- and never tests.
review_thread.NAMESPACE = vim.api.nvim_create_namespace("lain_thread_anchors")

-- Everything that can refuse, before anything is created -- 47_diff's rule, for
-- its reason: a raise that had already made a buffer would leave a thread
-- half-built on a wiring mistake.
--
-- The `type(...) ~= "table"` arm is where a caller still sending T11's bare id
-- lands, so it says what the pane needs and why, rather than "expected table".
function review_thread.checked_anchor(anchor)
  if type(anchor) ~= "table" then
    error("lain: set_thread needs the anchor as a table {id, path, side, line}, got " .. tostring(anchor) ..
      " -- the pane watches a POSITION as the cursor moves and a bare id names none", 0)
  end
  if type(anchor.id) ~= "string" or anchor.id == "" then
    error("lain: set_thread needs a non-empty anchor id, got " .. tostring(anchor.id) ..
      " -- every question typed into the pane cites it back", 0)
  end
  if type(anchor.path) ~= "string" or anchor.path == "" then
    error("lain: set_thread needs the repository-relative path the anchor is in, got " ..
      tostring(anchor.path), 0)
  end
  if review_thread.OPPOSITE[anchor.side] == nil then
    error("lain: set_thread needs side old or new, got " .. tostring(anchor.side) ..
      " -- the thread shows in the OPPOSITE pane, and there is no opposite of a third side", 0)
  end
  if type(anchor.line) ~= "number" or anchor.line < 1 or anchor.line % 1 ~= 0 then
    error("lain: set_thread needs a line the anchor sits on, got " .. tostring(anchor.line) ..
      " -- lines are 1-based positions", 0)
  end
  return anchor
end

-- Every line, checked before anything is created: `nvim_buf_set_lines` raises on
-- a string containing a newline. The `type(...) ~= "table"` test does real work
-- -- a Ruby nil crosses msgpack as `vim.NIL`, which is USERDATA and therefore
-- truthy, so the `lines or {}` a reader would write here is dead code.
function review_thread.checked_lines(lines)
  if type(lines) ~= "table" then
    return {}
  end
  for i, line in ipairs(lines) do
    if type(line) ~= "string" or line:find("\n", 1, true) then
      error("lain: set_thread lines[" .. i .. "] is not a single line -- a thread is one buffer line per line", 0)
    end
  end
  return lines
end

-- The diff buffer T15 stamped for this side of this file, or nil when the human
-- is looking at another file. Derived from the live buffer list rather than
-- remembered (47_diff's `unstamp`/`drop_stale` discipline): a registry of
-- buffers is the thing that goes stale, and T15 withdraws a stamp the moment
-- the human moves on, so at most one buffer answers.
function review_thread.side_buf(path, side)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[buf].lain_review_path == path and vim.b[buf].lain_review_side == side then
      return buf
    end
  end
  return nil
end

-- The buffer holding this anchor's conversation, found by its own stamp. NOT by
-- `vim.fn.bufnr(name)`: that argument is a PATTERN, so `lain://thread/a-1`
-- matches `lain://thread/a-10` too, and with both open it answers -1 -- after
-- which naming a new buffer would collide (E95). 47_diff was bitten by the same
-- API from the other side and verifies the name it gets back; here the stamp is
-- exact to begin with.
--
-- The stamp is exact but it does not LAST -- see the header's IDENTITY note --
-- so `named` below is the other half, for a name the stamp has been cleared off.
function review_thread.found(id)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[buf].lain_thread_anchor == id then
      return buf
    end
  end
  return nil
end

-- Is this buffer the thread's, right now? `nvim_buf_is_loaded` and not
-- `nvim_buf_is_valid`, because an unloaded husk is valid and answers `[""]`;
-- and it is asked FIRST, because reading `vim.b` off an invalid bufnr raises
-- while `nvim_buf_is_loaded` answers false for one.
function review_thread.holds(buf, id)
  return buf ~= nil and vim.api.nvim_buf_is_loaded(buf) and vim.b[buf].lain_thread_anchor == id
end

-- A buffer under this EXACT name, whoever it belongs to. `nvim_buf_get_name`
-- rather than `vim.fn.bufnr`, for `found`'s reason -- the argument to `bufnr`
-- is a pattern and `lain://thread/a-1` would find `a-10`'s buffer. Every other
-- lain:// buffer goes through `20_buffers.named_buf`, whose `bufnr` DOES find
-- an unloaded husk, which is why they all recover from `:bdelete` and, until
-- this existed, the thread buffer alone did not.
function review_thread.named(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf) == name then
      return buf
    end
  end
  return nil
end

-- The thread's buffer, made once per anchor.
--
-- `acwrite` for compose's reason and no other: `nofile` refuses `:write` with
-- E382 BEFORE any autocommand runs, so BufWriteCmd would never fire -- and `:w`
-- is how a question is asked. A NAME is required for the same write (E32) and
-- is what the BufWriteCmd pattern matches on.
--
-- `hide`, never `wipe`: the pane's buffer is swapped every time the cursor
-- crosses a note, and wiping on hide would throw away a half-typed question on
-- the human's next keystroke.
--
-- UNLISTED, unlike lain://compose and lain://question: those are singletons,
-- this proliferates one per note, and a review with thirty of them would bury
-- the human's own files in `:ls` and `:bnext`. It stays reachable by `:b` on
-- its name, and by `:LainThread`, which is the gesture a human would actually
-- use.
--
-- The motions are bound HERE, once, at creation -- which is what makes "no
-- keymap is re-registered" a property of the structure rather than a promise
-- about the show path. `jump_record` is 20_buffers' own walk; the boundary
-- predicate is local because RECORD_START is keyed by a fixed buffer NAME and
-- these names are per-anchor (46_sidebar fixed the analogous filetype miss the
-- same way, locally, rather than by widening a shared table).
--
-- Binding once has one exposure worth stating, since it is what that property
-- leans on: nvim's own markdown ftplugin binds `]]` to a next-heading motion,
-- so any RE-run of FileType on this buffer (`:e`, `:set ft=`, `filetype
-- detect`) silently takes the motion back, with no error. Ordering here is
-- correct -- the maps are set after 'filetype', so they win at creation -- and
-- 60_question carries the identical exposure, so this is consistent rather than
-- special. Re-binding from a `FileType` autocmd is the idiomatic fix for both.
--
-- A HUSK IS RECLAIMED, never worked around. `:bdelete`, `:bunload` and a
-- `:mksession` restore all clear the stamp and keep the NAME, so the early
-- return misses and `nvim_buf_set_name` on a fresh buffer raises E95 -- with
-- the buffer already created, so every later render orphaned one and the thread
-- was unrecoverable for the rest of the session. `bufload` is what turns the
-- husk back into a buffer with contents; everything below then re-establishes
-- the resting state nvim reset (`buftype` and `bufhidden` both go back to "")
-- and the motions, which unloading dropped.
function review_thread.buf(id)
  local found = review_thread.found(id)
  if found ~= nil then
    return found
  end

  local name = review_thread.PREFIX .. id
  local buf = review_thread.named(name)
  if buf == nil then
    buf = claim(vim.api.nvim_create_buf(false, true), name)
    vim.api.nvim_buf_set_name(buf, name)
  else
    claim(buf, name)
    vim.fn.bufload(buf)
  end
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.b[buf].lain_thread_anchor = id

  local is_start = function(lines, i) return lines[i]:match(review_thread.ENTRY) ~= nil end
  vim.keymap.set("n", "]]", function() jump_record(buf, 1, is_start) end,
    { buffer = buf, desc = "lain: next message in this thread" })
  vim.keymap.set("n", "[[", function() jump_record(buf, -1, is_start) end,
    { buffer = buf, desc = "lain: previous message in this thread" })
  return buf
end

-- Anchor the thread in the diff buffer it belongs to, or do nothing at all: a
-- thread for a file nobody is currently reviewing is NORMAL (Ruby holds them
-- for a whole changeset), and it becomes visible the moment that file is
-- opened and the threads are sent again.
--
-- The mark is MOVED rather than added when this anchor already has one, so a
-- re-render leaves one mark per anchor instead of a pile of them on the same
-- row.
--
-- The bufnr is remembered BESIDE the id, and it is a hint RESOLVED THROUGH the
-- id rather than merely validated (41_layout's `buf_for` guards a bufnr; this
-- can do better, because the id is the identity and `found` answers it). It is
-- there to keep the common case off an O(buffers) scan, never to decide which
-- buffer this is -- see `anchor_at`.
--
-- The REVISION is remembered too, and it is what stops a thread outliving the
-- changeset it belongs to. The new side is a real file buffer: it is not wiped
-- between files, it outlives the review entirely, and 47_diff's `unstamp`
-- withdraws the review's own stamp but cannot know about these. So a second
-- review of the same file used to re-stamp on top of the first one's anchors
-- and show them at drifted mark positions. Comparing the entry's revision with
-- the buffer's CURRENT one makes that self-correcting: the same changeset
-- re-opened keeps its threads, a different one ignores them, and Ruby re-sends
-- whatever is still live either way.
--
-- The row is CLAMPED, 47_diff's `focus_line` reason: a line past the end of the
-- buffer is one the changeset named and the file no longer reaches, and
-- `nvim_buf_set_extmark` raises on it -- taking down a render over a note.
function review_thread.register(anchor, thread)
  local target = review_thread.side_buf(anchor.path, anchor.side)
  if target == nil then
    return nil
  end

  local held = vim.b[target].lain_thread_anchors or {}
  local existing = nil
  for mark, entry in pairs(held) do
    if entry.id == anchor.id then
      existing = tonumber(mark)
    end
  end
  local row = math.max(0, math.min(anchor.line, vim.api.nvim_buf_line_count(target)) - 1)
  local mark = vim.api.nvim_buf_set_extmark(target, review_thread.NAMESPACE, row, 0, { id = existing })
  held[tostring(mark)] = { id = anchor.id, buf = thread, rev = vim.b[target].lain_review_revision }
  -- Read-modify-WRITE: a vim variable answers a COPY, so mutating what
  -- `vim.b` handed over changes nothing (41_layout's `remember`).
  vim.b[target].lain_thread_anchors = held
  return target
end

-- The thread anchored on this row, as `{ id, buf }` -- nil when the row carries
-- no mark, when the mark belongs to a changeset this buffer is no longer
-- showing, when the mark's thread has been wiped, or when the bookkeeping and
-- the marks have parted company. All of them answer "no thread here", which is
-- the honest reading: a thread whose buffer is gone is not one the pane can
-- show, and pretending otherwise is the stale-registry raise this module exists
-- to avoid.
--
-- THE HINT IS RESOLVED, NOT TRUSTED, and that ordering is the whole guard: the
-- remembered bufnr is used only while it still carries this anchor's stamp, and
-- otherwise the id is looked up again. An unloaded husk fails `holds` (it is
-- valid, and empty), so it neither reaches the pane nor gets loaded by being
-- put there -- which is what used to escalate an ordinary `:bdelete` into a
-- permanent E95.
--
-- The FIRST mark on the row wins when several anchors share a line. Arbitrary
-- but deterministic -- `nvim_buf_get_extmarks` answers in position then id
-- order, so it is the one placed first.
function review_thread.anchor_at(buf, row)
  local marks = vim.api.nvim_buf_get_extmarks(buf, review_thread.NAMESPACE, { row - 1, 0 }, { row - 1, -1 }, {})
  if #marks == 0 then
    return nil
  end
  local held = (vim.b[buf].lain_thread_anchors or {})[tostring(marks[1][1])]
  if held == nil or held.rev ~= vim.b[buf].lain_review_revision then
    return nil
  end
  if review_thread.holds(held.buf, held.id) then
    return held
  end

  local again = review_thread.found(held.id)
  return review_thread.holds(again, held.id) and { id = held.id, buf = again } or nil
end

-- The window a slot is in, WITHOUT going through `review_layout` (which takes
-- focus) or `review_place` (which is the thing being guarded against calling).
-- `nvim_list_wins` spans every tabpage, so this needs no notion of which one the
-- review is in. nil when the human has closed that window, which is exactly the
-- state the repair below is for.
function review_thread.pane(slot)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.w[win].lain_review_slot == slot then
      return win
    end
  end
  return nil
end

-- Which thread the pane is showing, READ OFF THE PANE. This is the whole of the
-- module's "state", and it is not state: nothing here can be stale, a pane
-- holding a diff buffer answers nil for free, and anything else that re-places
-- the pane (T15 opening the next file) resets it without knowing this module
-- exists.
function review_thread.shown(slot)
  local win = review_thread.pane(slot)
  if win == nil then
    return nil
  end
  return vim.b[vim.api.nvim_win_get_buf(win)].lain_thread_anchor
end

-- Somewhere for the pane to CONVERGE on when the diff buffer this slot held is
-- gone -- the old side is listed, so a human tidying `:ls` reaches it. Without
-- one the restore silently did nothing: `shown` kept answering the thread the
-- cursor had left, so the equality guard could never be true again, the pane
-- permanently named a thread the cursor was nowhere near, and the O(buffers)
-- `side_buf` scan re-ran on every keystroke (measured: 297us -> 500us a move).
-- 41_layout's own placeholder shape, `bufhidden = "wipe"`, so the next real
-- render removes it rather than leaving it in the buffer list.
function review_thread.placeholder()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  return buf
end

-- The window this slot's content goes in, REBUILT only for a render.
--
-- Rebuilt holding the DIFF, never the thread, and that is not a detail:
-- `review_place` REMEMBERS what it placed (41_layout's `remember`, scoped to
-- the tabpage precisely so it outlives the window), so a slot told the thread
-- was its content resurrects that conversation into the diff slot on the next
-- unrelated render. The thread is an OVERLAY on a pane whose content is the old
-- side; only the old side is ever placed, and every swap after that is a
-- straight `nvim_win_set_buf` into the window this answers.
function review_thread.window(slot, path, rebuild)
  local win = review_thread.pane(slot)
  if win ~= nil or not rebuild then
    return win
  end
  return _G.__lain.review_place(slot, review_thread.side_buf(path, slot) or review_thread.placeholder())
end

-- Put the diff pair back IN diff mode when a repair has taken it out -- see the
-- header. Gated per window on 'diff' already being false, so the intact path,
-- where nvim restores everything itself, is untouched and the human's folds
-- survive; and gated on the window actually holding a review side buffer, so
-- the pane showing a conversation is not diffed against anything.
--
-- Both windows, for 47_diff `pair`'s reason: closing one of a diff pair takes
-- the SURVIVOR out of diff mode too, so restoring only the rebuilt one leaves a
-- diff of one window, which renders as a plain buffer.
function review_thread.rediff()
  for _, slot in ipairs({ "old", "new" }) do
    local win = review_thread.pane(slot)
    if win ~= nil and not vim.wo[win].diff and
        vim.b[vim.api.nvim_win_get_buf(win)].lain_review_side ~= nil then
      vim.api.nvim_win_call(win, function() vim.cmd("diffthis") end)
    end
  end
end

-- The whole decision, from wherever the cursor now is. Called from CursorMoved
-- with `rebuild` false, and again after every render with it true, because a
-- human standing on the anchored line when the conversation arrives has no
-- further cursor movement to trigger it -- and that is not a render presenting
-- itself, it is the pane it is already looking at catching up. See the header
-- for why only one of those two callers may build a layout.
--
-- MOVES NOBODY. `review_place` re-ensures the layout and takes no focus, and
-- nothing is added here -- including on the repair path, which is where T26's
-- panel found a focus theft that its intact-path example could not see.
function review_thread.refresh(rebuild)
  -- THE BAIL-OUT: one buffer-variable read, in every buffer that is not a
  -- review diff. `vim.b.x` and not `vim.b[buf].x` -- the indexed form builds a
  -- fresh accessor table per call and measures 0.489us against 0.061us. T15
  -- withdraws the stamp when the human moves on, so this is also what stops a
  -- thread following a file out of the review.
  local slot = review_thread.OPPOSITE[vim.b.lain_review_side]
  if slot == nil then
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local held = review_thread.anchor_at(buf, vim.api.nvim_win_get_cursor(0)[1])
  local wanted = held ~= nil and held.id or nil
  -- THE IDEMPOTENCY GUARD, on the show path as much as the hide path: a column
  -- move, or any move within the anchored line, ends here having set no buffer
  -- and registered no keymap.
  if wanted == review_thread.shown(slot) then
    return
  end

  local path = vim.b[buf].lain_review_path
  local win = review_thread.window(slot, path, rebuild)
  if win == nil then
    return
  end
  vim.api.nvim_win_set_buf(win, held ~= nil and held.buf or
    review_thread.side_buf(path, slot) or review_thread.placeholder())
  review_thread.rediff()
end

-- Render one anchor's conversation (T18). See the header for why the anchor
-- arrives whole.
--
-- A MODIFIED buffer is not overwritten: the human is mid-question, their text
-- is the only copy of it, and a docent's answer arriving is not a reason to
-- discard it. The anchor is still re-registered, so the position stays right --
-- only the words wait. (Ruby re-renders on the next exchange, so nothing is
-- lost permanently; the buffer catches up as soon as the question is sent.)
--
-- @param anchor `{ id, path, side, line }` -- identity AND position
-- @param lines the conversation, one buffer line per line
function _G.__lain.set_thread(anchor, lines)
  local checked = review_thread.checked_anchor(anchor)
  local body = review_thread.checked_lines(lines)
  local buf = review_thread.buf(checked.id)

  if not vim.bo[buf].modified then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, body)
    vim.bo[buf].modified = false
    -- The other half of "what did the human type": everything past what lain
    -- wrote is theirs. Stamped beside the content for question_view's reason --
    -- by the time `:w` fires the buffer is the only copy of anything, and it is
    -- the copy under suspicion.
    vim.b[buf].lain_thread_rendered = body
  end

  review_thread.register(checked, buf)
  announce_render(review_thread.PREFIX .. checked.id, buf)
  review_thread.refresh(true)
end

local thread_group = vim.api.nvim_create_augroup("lain_thread", { clear = true })

-- The trigger, and `false`: a motion may swap the pane's buffer and may not
-- build a window (see the header).
--
-- No pattern, and the honest cost, because the first version of this comment
-- had it backwards and a panel measured it. Per dispatch on 0.12.4: dispatching
-- to a global lua callback is ~2.8us over a floor of nothing registered, of
-- which ~0.8us IS the buffer-name pattern match; the bail-out body itself is
-- ~0.16us; a `buffer=`-scoped autocmd is indexed by bufnr and costs ~0.09us
-- when it does not match. So this pays ~2.8us per cursor move in every buffer
-- in the editor to avoid ~0.8us paid only in review buffers -- the wrong way
-- round, and kept anyway because it is three orders of magnitude under a
-- redraw and because attaching per buffer means attaching in `register`, where
-- the buffers a review stamps are not yet all known. A `buffer=`-scoped
-- CursorMoved is the cheaper and more idiomatic spelling if this is ever a
-- cost that shows.
vim.api.nvim_create_autocmd("CursorMoved", {
  group = thread_group,
  callback = function() review_thread.refresh(false) end,
})

-- What the human typed, which is everything past what lain rendered. nil when
-- they typed nothing.
--
-- Deliberately NOT a diff of the whole buffer: editing lain's own words in
-- place is not a question, and treating it as one would send the conversation
-- back to itself. The question is what follows it, which is also where the
-- cursor lands after `:LainThread`.
function review_thread.typed(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local rendered = vim.b[buf].lain_thread_rendered or {}
  local typed = {}
  for i = #rendered + 1, #lines do
    table.insert(typed, lines[i])
  end
  local text = vim.trim(table.concat(typed, "\n"))
  return text ~= "" and text or nil
end

-- The ask (T24's inbound leg, whose answer comes back as another `set_thread`).
-- `:w` is the gesture for compose's and question's reason: it is the one verb
-- every vim user already reads as "I am done with this text".
--
-- ORDER IS THE CORRECTNESS. The rpcrequest goes first and 'modified' is cleared
-- only once it returns, so a question that reached nobody leaves the buffer
-- dirty with the human's words in it and `:w` FAILS -- which is the standing
-- obligation this card owns outright, since Ruby can only answer and cannot
-- make a write fail.
--
-- ONE argument after the verb, and it is an ARRAY: every verb on this rail is
-- destructured Ruby-side as `verb, args`, and 65_review records a verb that
-- sent flat positionals and had everything after the first dropped on the floor.
vim.api.nvim_create_autocmd("BufWriteCmd", {
  group = thread_group,
  pattern = review_thread.PREFIX .. "*",
  callback = function(ev)
    local question = review_thread.typed(ev.buf)
    if question == nil then
      error("lain: nothing has been typed under the conversation, so there is no question to ask -- " ..
        "write it below the last message and :w again", 0)
    end
    local ok, err = pcall(vim.rpcrequest, chan, "lain_command", "review_ask",
      { vim.b[ev.buf].lain_thread_anchor, question })
    if not ok then
      error("lain: the question was NOT sent and your text is untouched: " .. tostring(err), 0)
    end
    -- ASKED IS RENDERED. `BufWriteCmd` fires on an acwrite buffer whether or
    -- not it is modified, so a second `:w` used to re-send the identical
    -- question -- a second docent spawn and a second provider call. Ruby cannot
    -- dedupe it at the door: `review_ask` is in the Router's ACKED table, so
    -- `:w` is answered `true` before anything consumes the command. Advancing
    -- the watermark stops it at the source: what has been asked is no longer
    -- "what the human has typed", so the second write finds no question and
    -- refuses in words, while anything typed AFTER it still sends. The next
    -- `set_thread` re-stamps this with lain's own rendering, which by then
    -- includes the question.
    vim.b[ev.buf].lain_thread_rendered = vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false)
    vim.bo[ev.buf].modified = false
  end,
})

-- Put the human IN the thread on this line. The pane follows the cursor by
-- itself; this is how you get into it to type, and taking focus is right for
-- 47_diff's reason -- a render must move nobody, a gesture the human just made
-- is the one thing that may.
--
-- Refuses in words rather than raising, and says which of the two things is
-- wrong: `define` makes every :Lain* command GLOBAL, so this is reachable from
-- lain://journal as readily as from the diff, and "no thread on this line" told
-- to somebody who is not even in a review is the wrong sentence.
define("LainThread", function()
  local buf = vim.api.nvim_get_current_buf()
  local slot = review_thread.OPPOSITE[vim.b[buf].lain_review_side]
  if slot == nil then
    vim.notify("lain: :LainThread opens the thread on the line under the cursor, and needs a review diff buffer",
      vim.log.levels.WARN)
    return
  end

  local held = review_thread.anchor_at(buf, vim.api.nvim_win_get_cursor(0)[1])
  if held == nil then
    vim.notify("lain: no thread on this line", vim.log.levels.WARN)
    return
  end
  -- A GESTURE, so it may rebuild -- and through `window` rather than
  -- `review_place` directly, so the slot is not taught that a conversation is
  -- its content (see `window`).
  local win = review_thread.window(slot, vim.b[buf].lain_review_path, true)
  vim.api.nvim_win_set_buf(win, held.buf)
  vim.api.nvim_set_current_win(win)
end)
