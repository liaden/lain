-- The review's own TABPAGE, and the two entry points every review capability
-- renders through (T26). An epic already in flight has the journal, timeline,
-- inbox and request buffers laid out; a review needs room and must not fight
-- that, so it opens beside the session layout rather than over it -- `tabnew`
-- inside the same nvim, sidebar plus the diff pair, `gt` back to the session.
-- octo and diffview both do this, and `plugin/nvim/lua/lain/init.lua`'s
-- open_layout is the same `tabnew` + full-height-vsplit idiom, one tab over.
--
-- What the session layout is guaranteed is its window IDS AND BUFFERS, stated
-- that precisely because it is not quite "untouched": opening a tabpage raises
-- the tabline at the default 'showtabline', which costs every session window one
-- row (22 -> 21). Ids, buffers, window-local options, cursor position, alternate
-- file and 'laststatus' are all measured identical either side.
--
-- THE RULE FOR CALLERS, and it is the one T14/T15/T18 need: a window id from
-- {_G.__lain.review_layout} is a SNAPSHOT, correct when handed over and stale
-- after the human's next gesture. Do not cache one across renders. Ids do not
-- recycle in this editor and a stale one raises `Invalid window id` rather than
-- quietly hitting some other window, so the failure is loud rather than a render
-- landing in the wrong place -- but loud is not free, and the fix is to render
-- through {_G.__lain.review_place}, which re-ensures the layout and answers a
-- freshly resolved id every time.
--
-- 41, the lowest free number in the capability band: this is a FOUNDATION the
-- later review modules (sidebar, diff, annotate, diagnostics, thread) render
-- through, and a module sees only the locals declared above it, so it has to
-- concatenate before all of them.
--
-- ONE new top-level name -- `review_panes`, the private helpers -- rather than
-- five: the chunk shares one scope and the binding cap is 60 UPVALUES per
-- function, so each top-level local is a name every later module pays for. The
-- two public entry points go on `_G.__lain`, which is where the runtime's
-- public surface lives.
--
-- The layout's own bookkeeping lives in VIM VARIABLES, not in a lua table, and
-- that choice is what keeps the repair honest: `vim.t[tab].lain_review` dies with
-- the tabpage and `vim.w[win].lain_review_slot` dies with the window, so there is
-- no registry to leave stale (octo's thread registry grows unboundedly for
-- exactly the opposite reason). It also survives the one thing a lua table would
-- get wrong: `:vsplit` copies window OPTIONS and NOT window variables (measured
-- -- the same fact 10_folds rides), so a human splitting the sidebar gets an
-- ordinary window, never a second window claiming to BE the sidebar.
--
-- The one piece of state that DOES outlive its window is what each slot last
-- held, and it is a hint rather than a record: see `buf_for`.
--
-- "old" and "new" are {Lain::Review::SIDES}, restated here because a static
-- chunk can derive nothing from Ruby. `layout_spec.rb` pins the two spellings
-- equal by reading this file, which is the only defence a cross-language
-- vocabulary has.
local review_panes = { SLOTS = { "sidebar", "old", "new" } }

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
-- placeholder. The validity check is not defensive habit: a slot remembers a
-- bufnr the review no longer controls, and the diff pair's buffers are wiped and
-- re-made per file -- so restoring one blind hands `nvim_open_win` an invalid
-- buffer and the whole render raises. What a slot remembers is a hint, checked
-- before it is believed.
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
-- `created` is answered by the two places that actually create a window, and NOT
-- by re-reading `map()` afterwards. That read is the version that shipped and it
-- was dead code: the build branch claims the sidebar's slot marker before
-- `map()` runs, so "is the sidebar new" came back false on the one path where it
-- is always true, and a first open got an equal-third sidebar at 26 columns with
-- no 'winfixwidth' -- while every later repair got the 40 the reader would have
-- assumed all along.
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

  local found = review_panes.map(tab)
  for _, slot in ipairs(review_panes.SLOTS) do
    if found[slot] == nil then
      found[slot] = review_panes.open(tab, found, slot)
      created[slot] = true
    end
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
-- them to work on -- the same reasoning as set_compose and open_review.
--
-- Its answer is a SNAPSHOT and must not be cached across renders: the ids are
-- right when they are handed over and go stale on the human's next gesture. Use
-- {review_place}, which re-ensures and answers a fresh id, as the seam.
--
-- @return slot -> window id, for every slot
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
-- Closing the review tabpage is the human's dismiss gesture, and rebuilding it
-- for a render that arrives afterwards is right (the review is still open, and
-- dropping the render would lose it), but a render is not a presentation: an
-- async one that yanked them out of the session tab to watch it land is the
-- card's own "session layout untouched" defect one level up. `tabnew` inside
-- `ensure` cannot help entering the new tabpage, so the entry that was NOT a
-- presentation puts them back.
--
-- An unknown slot is an ERROR naming both it and the slots that exist: a
-- misspelled slot would otherwise render into nothing at all, and present as a
-- view that draws nothing rather than as the typo it is.
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
  vim.api.nvim_win_set_buf(found[slot], buf)
  review_panes.remember(tab, slot, buf)
  return found[slot]
end
