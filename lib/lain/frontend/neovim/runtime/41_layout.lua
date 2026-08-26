-- The review's own TABPAGE, and the two entry points every review capability
-- renders through. An epic in flight already has the journal, timeline, inbox
-- and request buffers laid out, so a review opens BESIDE the session layout
-- rather than over it: `tabnew` inside the same nvim, sidebar plus the diff
-- pair, `gt` back to the session.
--
-- The session layout is guaranteed its window IDS AND BUFFERS, stated that
-- precisely because it is not quite "untouched": opening a tabpage raises the
-- tabline at the default 'showtabline', costing every session window one row
-- (22 -> 21). Ids, buffers, window-local options, cursor position, alternate
-- file and 'laststatus' are all measured identical either side.
--
-- THE RULE FOR CALLERS: a window id from {_G.__lain.review_layout} is a
-- SNAPSHOT, correct when handed over and stale after the human's next gesture.
-- Do not cache one across renders. Ids do not recycle in this editor and a stale
-- one raises `Invalid window id` rather than quietly hitting some other window,
-- so the failure is loud -- but loud is not free, and the fix is to render
-- through {_G.__lain.review_place}, which re-ensures the layout and answers a
-- freshly resolved id every time.
--
-- 41, the lowest free number in the capability band: this is a FOUNDATION the
-- later review modules render through, and a module sees only the locals
-- declared above it.
--
-- ONE new top-level name rather than five: the chunk shares one scope and the
-- binding cap is 60 UPVALUES per function, so each top-level local is a name
-- every later module pays for.
--
-- The layout's own bookkeeping lives in VIM VARIABLES, not a lua table, which is
-- what keeps the repair honest: `vim.t[tab].lain_review` dies with the tabpage
-- and `vim.w[win].lain_review_slot` dies with the window, so there is no
-- registry to leave stale. It also survives the one thing a lua table would get
-- wrong: `:vsplit` copies window OPTIONS and NOT window variables (measured), so
-- a human splitting the sidebar gets an ordinary window rather than a second
-- window claiming to BE the sidebar.
--
-- "old" and "new" are {Lain::Review::SIDES}, restated here because a static
-- chunk can derive nothing from Ruby. `layout_spec.rb` pins the two spellings
-- equal by reading this file, the only defence a cross-language vocabulary has.
--
-- SLOTS IS THE VOCABULARY, NOT THE ROUND. What a round OPENS is a subset
-- (`opens`), because a survey of files as they stand presents only a new side --
-- but `old` stays spelled, ordered and refusable BY NAME here. That keeps four
-- things working at once: `index_of` still gives `anchor` a total order,
-- `review_place` can still tell a MISSPELLED slot from one this round did not
-- open, the cross-language pin still reads this literal, and `:LainThread` on a
-- survey still has an `old` slot to put the docent's conversation in.
local review_panes = { SLOTS = { "sidebar", "old", "new" } }

-- THE ROUND'S SIDES, IN TRANSIT ONLY. `set_review` carries {Review::SIDES} here
-- and `ensure` writes them through to `vim.t[tab]`, because on the FIRST sidebar
-- paint there is no review tabpage yet to write them to.
--
-- Not the registry the header rules out: no window id, no bufnr, no tabpage --
-- nothing that can dangle. The durable home is the tabpage variable, which dies
-- with the tabpage. `set_review` lands on EVERY redraw, so this is re-posted
-- every paint and a value left here cannot drift from the round on screen.
review_panes.sides = nil

-- Slot order IS left-to-right window order, which is what makes "put the
-- restored window back where it was" a comparison of indices rather than a
-- remembered geometry.
function review_panes.index_of(slot)
  for i, name in ipairs(review_panes.SLOTS) do
    if name == slot then
      return i
    end
  end
  return nil
end

function review_panes.tab()
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if vim.t[tab].lain_review then
      return tab
    end
  end
  return nil
end

-- The sides off the wire, or nil for a round that said nothing.
--
-- THE TYPE TEST DOES REAL WORK: a Ruby nil crosses msgpack as `vim.NIL`, which
-- is USERDATA and therefore TRUTHY, so a truthiness check would take "this
-- caller sends no sides" for a list of them. Filtered against the vocabulary as
-- well, with the navigator dropped: a round is not allowed to say the sidebar is
-- optional.
--
-- An empty result answers nil rather than "a round with no sides at all": Ruby's
-- contract is that the list is never empty, and a layout with no file in it is
-- not a better answer to a broken wire than the whole vocabulary is.
function review_panes.carried(sides)
  if type(sides) ~= "table" then
    return nil
  end
  local kept = {}
  for _, side in ipairs(sides) do
    if type(side) == "string" and side ~= review_panes.SLOTS[1] and review_panes.index_of(side) ~= nil then
      kept[#kept + 1] = side
    end
  end
  if #kept == 0 then
    return nil
  end
  return kept
end

-- The slots THIS round opens: the navigator, plus the sides the round presents,
-- in SLOTS order -- so left-to-right placement stays the same reading whether a
-- round has one side or two. A round that never said gets the whole vocabulary,
-- which is what every caller driving `open_changeset` with no sidebar render in
-- front of it relies on.
function review_panes.opens(tab)
  local sides = vim.t[tab].lain_review_sides
  if type(sides) ~= "table" then
    return review_panes.SLOTS
  end
  local wanted = {}
  for _, side in ipairs(sides) do
    wanted[side] = true
  end
  local opens = {}
  for index, slot in ipairs(review_panes.SLOTS) do
    if index == 1 or wanted[slot] then
      opens[#opens + 1] = slot
    end
  end
  return opens
end

-- Whether this round opens a slot at all, asked without a tabpage in hand --
-- `47_diff` needs it before deciding whether to BUILD an old side.
--
-- IT FINDS ITS OWN TABPAGE where `opens` is handed one, and the split is the
-- question each answers: `opens` is asked BY the layout mid-`ensure`, where the
-- tabpage is already resolved, while `holds` is asked by a module that has no
-- tabpage and no business acquiring one.
function review_panes.holds(slot)
  local tab = review_panes.tab()
  local opens = tab ~= nil and review_panes.opens(tab) or review_panes.SLOTS
  for _, name in ipairs(opens) do
    if name == slot then
      return true
    end
  end
  return false
end

-- What `set_review` carried, written onto the tabpage the moment there is one.
-- Answers whether the round CHANGED, which is the only moment a window may be
-- shed -- a round re-posting the same fact on its next redraw must not take away
-- a pane opened since. A tabpage that held nothing is not a change: calling it
-- one would make the first paint of every round a repair.
--
-- THE ONE ASYMMETRY: a round that sends NO sides writes nothing, inheriting
-- whatever the tabpage held rather than resetting it to the whole vocabulary.
-- "The wire said nothing" is not "the round has both sides", and clobbering a
-- known fact with an absent one is the worse guess.
function review_panes.carry(tab)
  local sides = review_panes.sides
  if sides == nil then
    return false
  end
  local held = vim.t[tab].lain_review_sides
  vim.t[tab].lain_review_sides = sides
  return type(held) == "table" and table.concat(held, ",") ~= table.concat(sides, ",")
end

-- Close the windows this round has no slot for, and forget them, so `ensure`'s
-- own loop does not read a closed id back. Only ever reached from `carry`
-- answering true: a changeset review settled and then surveyed reuses the review
-- tabpage, and the changeset's old side would otherwise be left showing a diff
-- of a file nobody is reviewing any more.
function review_panes.shed(tab, found)
  local opens = {}
  for _, slot in ipairs(review_panes.opens(tab)) do
    opens[slot] = true
  end
  for slot, win in pairs(found) do
    if not opens[slot] and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
      found[slot] = nil
    end
  end
end

-- slot -> window, for the slots that are actually still there. Read fresh on
-- every call rather than cached: the human closing a window is the normal case
-- this module exists to absorb, not an exception.
function review_panes.map(tab)
  local found = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    local slot = vim.w[win].lain_review_slot
    if slot then
      found[slot] = win
    end
  end
  return found
end

-- What each slot last held, remembered on the TABPAGE so it outlives the window
-- (a window variable would die with the window that is precisely what got
-- closed). Read-modify-WRITE, because a vim variable answers a copy: mutating
-- the table `vim.t` hands back changes nothing.
function review_panes.remember(tab, slot, buf)
  local held = vim.t[tab].lain_review_buffers or {}
  held[slot] = buf
  vim.t[tab].lain_review_buffers = held
end

-- The remembered buffer if it is STILL a buffer, else a fresh scratch
-- placeholder. Not defensive habit: the diff pair's buffers are wiped and
-- re-made per file, so restoring one blind hands `nvim_open_win` an invalid
-- buffer and the whole render raises. What a slot remembers is a HINT.
--
-- `bufhidden = "wipe"` on the placeholder is what keeps repeated repairs from
-- littering the buffer list: the moment a real render replaces it, it is gone.
function review_panes.buf_for(tab, slot)
  local held = (vim.t[tab].lain_review_buffers or {})[slot]
  if held and vim.api.nvim_buf_is_valid(held) then
    return held
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  return buf
end

-- Where a missing window goes back: beside the nearest slot that IS there, on
-- the side slot order puts it -- so a restored sidebar lands LEFT of the diff
-- pair rather than wherever a bare `vsplit` would have put it. With no slot
-- windows left at all (the human kept the tabpage but closed all three), the
-- tabpage's current window is the anchor; that is a corner, and splitting
-- beside whatever the human put there beats guessing.
function review_panes.anchor(tab, found, slot)
  local index = review_panes.index_of(slot)
  for j = index - 1, 1, -1 do
    local win = found[review_panes.SLOTS[j]]
    if win then
      return win, "right"
    end
  end
  for j = index + 1, #review_panes.SLOTS do
    local win = found[review_panes.SLOTS[j]]
    if win then
      return win, "left"
    end
  end
  return vim.api.nvim_tabpage_get_win(tab), "right"
end

-- nvim_open_win with a `split` config, never `:vsplit`: it names the window to
-- split and takes `enter = false`, so a repair can happen in a tabpage the
-- human is not looking at without moving them into it. An ex-command would have
-- to make the target window current first, and putting the cursor somewhere the
-- human did not ask for is the one thing a render must never do (45_views).
function review_panes.open(tab, found, slot)
  local anchor, side = review_panes.anchor(tab, found, slot)
  local win = vim.api.nvim_open_win(review_panes.buf_for(tab, slot), false, { split = side, win = anchor })
  vim.w[win].lain_review_slot = slot
  return win
end

-- The sidebar is a navigator, not a third of the screen. Applied only to a
-- window this module just CREATED, so a human who widened it keeps that width
-- across every later render; 'winfixwidth' is what stops the diff pair's own
-- splits equalising it away again. vim.g.lain_review_sidebar_width is the
-- opt-out, the same shape as vim.g.lain_fold / vim.g.lain_foldlevel.
function review_panes.size(win)
  local width = vim.g.lain_review_sidebar_width or 40
  if width > 0 then
    vim.api.nvim_win_set_width(win, width)
    vim.wo[win][0].winfixwidth = true
  end
end

-- The layout, built if it is not there and repaired if it is only partly there.
-- Runs before EVERY render, because the human will close a window and the
-- alternative is a render that raises at an invalid window id.
--
-- `tabnew` is the one step here that takes focus, and it cannot not: nvim has no
-- API for creating a tabpage without entering it. Both callers put the human
-- back where they were, so nothing above this function moves them.
--
-- `created` is answered by the two places that actually create a window, NOT by
-- re-reading `map()` afterwards: the build branch claims the sidebar's slot
-- marker before `map()` runs, so "is the sidebar new" came back false on the one
-- path where it is always true, and a first open got an equal-third sidebar at
-- 26 columns with no 'winfixwidth'.
function review_panes.ensure()
  local tab = review_panes.tab()
  local created = {}
  if tab == nil then
    vim.cmd("tabnew")
    tab = vim.api.nvim_get_current_tabpage()
    vim.t[tab].lain_review = true
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, review_panes.buf_for(tab, "sidebar"))
    vim.w[win].lain_review_slot = "sidebar"
    created.sidebar = true
  end

  -- The round's fact, onto the tabpage, BEFORE anything is opened from it. This
  -- is the one place it can land on the paint that needs it: the branch above is
  -- what creates the tabpage, so nothing earlier had a `vim.t` to write to.
  local changed = review_panes.carry(tab)

  local found = review_panes.map(tab)
  for _, slot in ipairs(review_panes.opens(tab)) do
    if found[slot] == nil then
      found[slot] = review_panes.open(tab, found, slot)
      created[slot] = true
    end
  end

  -- AFTER the opens, never before. In a layout the human has closed windows in,
  -- the slot being shed can be the tabpage's LAST surviving window -- and closing
  -- that takes the tabpage down in the middle of the repair that was rebuilding
  -- it. Running second means the round's own windows are already there to
  -- survive it.
  if changed then
    review_panes.shed(tab, found)
  end

  -- After the splits, never between them: each one redistributes width. Only a
  -- sidebar this call CREATED is sized, so a human who widened it keeps that
  -- across every later render.
  if created.sidebar then
    review_panes.size(found.sidebar)
  end
  return tab, found
end

-- Present the review: ensure the layout and go there. The ONLY entry point that
-- takes focus, because a review is something lain handed the human and asked
-- them to work on.
--
-- Its answer is a SNAPSHOT and must not be cached across renders. Use
-- {review_place}, which re-ensures and answers a fresh id, as the seam.
--
-- @return slot -> window id, for every slot THIS ROUND OPENS -- which is the
--   whole vocabulary for a changeset and the navigator plus the new side for a
--   survey, so a caller indexing it by name must expect a nil (see
--   {review_place}, which opens one on demand rather than making every caller
--   carry that test)
function _G.__lain.review_layout()
  local tab, found = review_panes.ensure()
  vim.api.nvim_set_current_tabpage(tab)
  return found
end

-- Land a render in a slot. The seam every later review capability renders
-- through: the layout is validated first, so a render arriving after the human
-- closed the window rebuilds it and lands in the rebuilt one, and the id
-- returned is that render's, freshly resolved.
--
-- MOVES NOBODY, ever -- including when it has to build the tabpage from nothing.
-- Closing the review tabpage is the human's dismiss gesture and rebuilding it
-- for a later render is right, but a render is not a presentation: an async one
-- that yanked them out of the session tab to watch it land is the "session
-- layout untouched" defect one level up. `tabnew` inside `ensure` cannot help
-- entering the new tabpage, so this puts them back.
--
-- An unknown slot is an ERROR naming both it and the slots that exist: it would
-- otherwise render into nothing at all and present as a view that draws nothing
-- rather than as the typo it is.
--
-- A slot THIS ROUND DID NOT OPEN is the other case, and it OPENS. On a survey the
-- human stands in the new side, so `:LainThread` asks for `OPPOSITE["new"]` and
-- the thread pane IS the `old` slot. Without this the placement would hand
-- `nvim_win_set_buf` a nil window inside a `define`d command: an `error()`, a
-- traceback and a blocking hit-enter prompt, the shape this whole surface exists
-- to keep out.
--
-- @return the window id the buffer landed in
function _G.__lain.review_place(slot, buf)
  if review_panes.index_of(slot) == nil then
    error("lain: unknown review slot " .. tostring(slot) .. " -- the review layout holds " ..
      table.concat(review_panes.SLOTS, ", "), 0)
  end
  local was = vim.api.nvim_get_current_tabpage()
  local tab, found = review_panes.ensure()
  if tab ~= was then
    vim.api.nvim_set_current_tabpage(was)
  end
  if found[slot] == nil then
    found[slot] = review_panes.open(tab, found, slot)
  end
  vim.api.nvim_win_set_buf(found[slot], buf)
  review_panes.remember(tab, slot, buf)
  return found[slot]
end
