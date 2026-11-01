-- One placement policy, `tab_layout`, for every lain window. In the session tab
-- a view the human closed stays closed until the tab is rebuilt, while a new
-- approval or question shows itself; the review tab rebuilds a closed window on
-- the next render.
--
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
-- TWO top-level names, the policy and its review instance, rather than one per
-- function: the chunk shares one scope and the binding cap is 60 UPVALUES per
-- function, so each top-level local is a name every later module pays for. The
-- session instance hangs off the policy for the same reason.
--
-- The layout's own bookkeeping lives in VIM VARIABLES, not a lua table, which is
-- what keeps the repair honest: `vim.t[tab].lain_review` dies with the tabpage
-- and `vim.w[win].lain_slot` dies with the window, so there is no
-- registry to leave stale. It also survives the one thing a lua table would get
-- wrong: `:vsplit` copies window OPTIONS and NOT window variables (measured), so
-- a human splitting the sidebar gets an ordinary window rather than a second
-- window claiming to BE the sidebar.
local tab_layout = {}

-- Closing a tabpage's last window closes the TAB, throwing the human's focus
-- into a tab they were not looking at because a queue drained, so that window
-- is kept and the empty list left showing is the smaller surprise.
function tab_layout.last_in_its_tab(win)
  return #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win)) == 1
end

-- Hand back the windows lain opened for `buf` as `kind`. The buffer is checked as
-- well as the mark, because the mark names the window and the human may have
-- put another buffer in it.
function tab_layout.give_back(buf, kind)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.w[win].lain_slot == kind and not tab_layout.last_in_its_tab(win) then
      vim.api.nvim_win_close(win, false)
    end
  end
end

-- One layout: the tabpage variable that names its tabpage, and its slot
-- vocabulary. Each instance defines its own `anchor(tab, found, slot)`, the one
-- thing a row of review panes and a grid of session columns disagree on.
function tab_layout.new(spec)
  local layout = { VAR = spec.var, SLOTS = spec.SLOTS }

  -- Slot order IS left-to-right window order for the review, which is what
  -- makes "put the restored window back where it was" a comparison of indices
  -- rather than a remembered geometry.
  function layout.index_of(slot)
    for i, name in ipairs(layout.SLOTS) do
      if name == slot then
        return i
      end
    end
    return nil
  end

  function layout.tab()
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
      if vim.t[tab][layout.VAR] then
        return tab
      end
    end
    return nil
  end

  -- slot -> window, for the slots that are actually still there. Read fresh on
  -- every call rather than cached: the human closing a window is the normal
  -- case this module exists to absorb, not an exception.
  function layout.map(tab)
    local found = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local slot = vim.w[win].lain_slot
      if slot then
        found[slot] = win
      end
    end
    return found
  end

  -- What each slot last held, remembered on the TABPAGE so it outlives the
  -- window (a window variable would die with the window that is precisely what
  -- got closed). Read-modify-WRITE, because a vim variable answers a copy:
  -- mutating the table `vim.t` hands back changes nothing.
  function layout.remember(tab, slot, buf)
    local key = layout.VAR .. "_buffers"
    local held = vim.t[tab][key] or {}
    held[slot] = buf
    vim.t[tab][key] = held
  end

  -- The remembered buffer if it is STILL a buffer, else a fresh scratch
  -- placeholder. Not defensive habit: the diff pair's buffers are wiped and
  -- re-made per file, so restoring one blind hands `nvim_open_win` an invalid
  -- buffer and the whole render raises. What a slot remembers is a HINT.
  --
  -- `bufhidden = "wipe"` on the placeholder is what keeps repeated repairs from
  -- littering the buffer list: the moment a real render replaces it, it is gone.
  function layout.buf_for(tab, slot)
    local held = (vim.t[tab][layout.VAR .. "_buffers"] or {})[slot]
    if held and vim.api.nvim_buf_is_valid(held) then
      return held
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    return buf
  end

  -- nvim_open_win with a `split` config, never `:vsplit`: it names the window to
  -- split and takes `enter = false`, so a repair can happen in a tabpage the
  -- human is not looking at without moving them into it. An ex-command would
  -- have to make the target window current first, and putting the cursor
  -- somewhere the human did not ask for is the one thing a render must never do
  -- (45_views).
  --
  -- A TOP-LEVEL split (`win = -1`) is what makes a new full-height column, and
  -- it lands in the CURRENT tabpage, so it is made from inside a window of the
  -- target tab; `nvim_win_call` puts the human back afterwards.
  function layout.open(tab, found, slot, buf)
    local anchor, side, top = layout.anchor(tab, found, slot)
    local shown = buf or layout.buf_for(tab, slot)
    local win
    if top then
      win = vim.api.nvim_win_call(anchor, function()
        return vim.api.nvim_open_win(shown, false, { split = side, win = -1 })
      end)
    else
      win = vim.api.nvim_open_win(shown, false, { split = side, win = anchor })
    end
    vim.w[win].lain_slot = slot
    return win
  end

  return layout
end

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
local review_panes = tab_layout.new({ var = "lain_review", SLOTS = { "sidebar", "old", "new" } })

-- THE ROUND'S SIDES, IN TRANSIT ONLY. `set_review` carries {Review::SIDES} here
-- and `ensure` writes them through to `vim.t[tab]`, because on the FIRST sidebar
-- paint there is no review tabpage yet to write them to.
--
-- Not the registry the header rules out: no window id, no bufnr, no tabpage --
-- nothing that can dangle. The durable home is the tabpage variable, which dies
-- with the tabpage. `set_review` lands on EVERY redraw, so this is re-posted
-- every paint and a value left here cannot drift from the round on screen.
review_panes.sides = nil

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
    -- An approval or question placed in this tab wears the same mark, and is
    -- not the review's to shed.
    if review_panes.index_of(slot) ~= nil and not opens[slot] and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
      found[slot] = nil
    end
  end
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
    vim.w[win].lain_slot = "sidebar"
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

-- What lain places in the session tab besides the configured views.
tab_layout.KINDS = { "approval", "question" }

-- THE SESSION TAB: the plugin's `config.layout`, columns of lain:// view names,
-- plus the KINDS placed beside them. Unlike the review tab, a window the human
-- closed here is a decision rather than damage: its buffer is recorded closed on
-- the tabpage. A view is not reopened until the tabpage is rebuilt; a kind hides
-- only what it showed, and a new approval or question shows itself.
--
-- A `do` block, so the session's helpers cost later modules no top-level name.
do
  local session = tab_layout.new({ var = "lain_session", SLOTS = tab_layout.KINDS })
  tab_layout.session = session

  function session.mark(win, slot, buf)
    vim.w[win].lain_slot = slot
    vim.w[win].lain_slot_buf = buf
  end

  -- One line, so it never raises the hit-enter prompt, and only to a human who
  -- is not already looking at the session tab.
  function session.tell(text)
    local tab = session.tab()
    if tab ~= nil and tab ~= vim.api.nvim_get_current_tabpage() then
      vim.notify("lain: " .. text .. " waiting in the session tab", vim.log.levels.INFO)
    end
  end

  function session.columns(tab)
    return vim.t[tab].lain_session_columns or {}
  end

  -- Exact, where `bufnr()` would read the name as a pattern.
  function session.buf_named(name)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf) == name then
        return buf
      end
    end
    return nil
  end

  function session.cell(tab, slot)
    for c, column in ipairs(session.columns(tab)) do
      for r, name in ipairs(column) do
        if name == slot then
          return c, r
        end
      end
    end
    return nil
  end

  function session.column_wins(tab, found, c)
    local wins = {}
    for _, name in ipairs(session.columns(tab)[c] or {}) do
      if found[name] then
        wins[#wins + 1] = found[name]
      end
    end
    return wins
  end

  function session.nearest_column(tab, found, from, to, step)
    for c = from, to, step do
      local win = session.column_wins(tab, found, c)[1]
      if win then
        return win
      end
    end
    return nil
  end

  function session.bottom_of_last_column(tab, found)
    for c = #session.columns(tab), 1, -1 do
      local wins = session.column_wins(tab, found, c)
      if #wins > 0 then
        return wins[#wins]
      end
    end
    return vim.api.nvim_tabpage_get_win(tab)
  end

  -- A kind goes under the rightmost column. A view goes beside its neighbour in
  -- its own column, or, as the first of its column, into a new full-height
  -- column on the side the configuration puts it. A whole column missing BETWEEN
  -- two present ones cannot be inserted at full height by `nvim_open_win`, so it
  -- splits beside its right neighbour instead.
  function session.anchor(tab, found, slot)
    local c, r = session.cell(tab, slot)
    if c == nil then
      return session.bottom_of_last_column(tab, found), "below"
    end
    local column = session.columns(tab)[c]
    for j = r - 1, 1, -1 do
      if found[column[j]] then
        return found[column[j]], "below"
      end
    end
    for j = r + 1, #column do
      if found[column[j]] then
        return found[column[j]], "above"
      end
    end
    local left = session.nearest_column(tab, found, c - 1, 1, -1)
    local right = session.nearest_column(tab, found, c + 1, #session.columns(tab), 1)
    if right then
      return right, "left", left == nil
    end
    return left or vim.api.nvim_tabpage_get_win(tab), "right", true
  end

  function session.closed(tab, buf)
    return (vim.t[tab].lain_session_closed or {})[vim.api.nvim_buf_get_name(buf)] == true
  end

  function session.mark_closed(tab, buf)
    local name = vim.api.nvim_buf_get_name(buf)
    if name ~= "" then
      local closed = vim.t[tab].lain_session_closed or {}
      closed[name] = true
      vim.t[tab].lain_session_closed = closed
    end
  end

  -- `tabnew` takes focus, and this is reached only when the human asked for the
  -- session layout. Its empty buffer is wiped the moment the first view replaces
  -- it, so a rebuilt tab leaves nothing in the buffer list.
  function session.build(columns)
    for _, column in ipairs(columns) do
      for _, name in ipairs(column) do
        local buf = session.buf_named(name)
        if buf then
          vim.cmd("tabnew")
          local tab = vim.api.nvim_get_current_tabpage()
          vim.t[tab].lain_session = true
          vim.bo[vim.api.nvim_get_current_buf()].bufhidden = "wipe"
          vim.api.nvim_win_set_buf(0, buf)
          session.mark(vim.api.nvim_get_current_win(), name, buf)
          return tab
        end
      end
    end
    return nil
  end

  function session.fill(tab)
    local found = session.map(tab)
    for _, column in ipairs(session.columns(tab)) do
      for _, name in ipairs(column) do
        local buf = session.buf_named(name)
        if buf and found[name] == nil and not session.closed(tab, buf) then
          found[name] = session.open(tab, found, name, buf)
          session.mark(found[name], name, buf)
        end
      end
    end
  end

  -- `build` is the human asking for the layout. Without it a render only fills a
  -- tab that is there, so a session tab the human closed is not rebuilt under
  -- them by the next render.
  function session.place(spec)
    local tab = session.tab()
    if tab == nil and spec.build then
      tab = session.build(spec.layout)
    elseif tab ~= nil and spec.build then
      vim.api.nvim_set_current_tabpage(tab)
    end
    if tab ~= nil then
      vim.t[tab].lain_session_columns = spec.layout
      session.fill(tab)
    end
    return tab
  end

  -- With no session tab (a bare nvim, no plugin) a kind keeps the old placement,
  -- a split under the current window, so the call is still on screen.
  --
  -- Closing a kind's window hides what it showed then, not what comes next: a
  -- `fresh` buffer (a new call parked, a new question asked) shows itself even
  -- in a slot the human closed.
  function session.place_kind(kind, buf, fresh)
    local shown = vim.fn.win_findbuf(buf)[1]
    if shown ~= nil then
      return shown
    end
    local tab = session.tab()
    local win
    if tab == nil then
      win = vim.api.nvim_open_win(buf, false, { split = "below", win = 0 })
    elseif fresh or not session.closed(tab, buf) then
      session.reopen(tab, buf)
      win = session.open(tab, session.map(tab), kind, buf)
    end
    if win ~= nil then
      session.mark(win, kind, buf)
    end
    return win
  end

  function session.reopen(tab, buf)
    local closed = vim.t[tab].lain_session_closed or {}
    closed[vim.api.nvim_buf_get_name(buf)] = nil
    vim.t[tab].lain_session_closed = closed
  end
end

-- Place a lain window by kind: "session" lays out the configured views
-- (`{ layout = columns, build = bool }`), and each of KINDS places its buffer,
-- `fresh` when it holds something the human has not seen.
-- MOVES NOBODY, except a session `build`, which the human asked for.
--
-- @return the window the buffer is in, the session tabpage, or nil when there is
--   nowhere to put it: nothing primed yet, or a window the human closed
function _G.__lain.place(kind, arg, fresh)
  if kind == "session" then
    return tab_layout.session.place(arg)
  end
  if tab_layout.session.index_of(kind) == nil then
    error("lain: unknown placement " .. tostring(kind) .. " -- lain places session, " ..
      table.concat(tab_layout.KINDS, ", "), 0)
  end
  return tab_layout.session.place_kind(kind, arg, fresh)
end

do
  local layout_group = vim.api.nvim_create_augroup("lain_layout", { clear = true })

  -- Every window close is recorded, lain's own included: lain closes only
  -- approval and question windows, and a fresh one reopens its slot anyway.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = layout_group,
    callback = function(ev)
      local win = tonumber(ev.match)
      if vim.api.nvim_win_is_valid(win) and vim.w[win].lain_slot ~= nil then
        local tab = vim.api.nvim_win_get_tabpage(win)
        if vim.t[tab].lain_session then
          tab_layout.session.mark_closed(tab, vim.api.nvim_win_get_buf(win))
        end
      end
    end,
  })

  -- A session window the human sends to another buffer is theirs from then on,
  -- so the mark goes, and bringing lain's buffer back later does not restore
  -- it. Review panes carry no `lain_slot_buf`: their buffers change by design.
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = layout_group,
    callback = function(ev)
      local win = vim.api.nvim_get_current_win()
      local placed = vim.w[win].lain_slot_buf
      if placed ~= nil and placed ~= ev.buf then
        vim.w[win].lain_slot = nil
        vim.w[win].lain_slot_buf = nil
      end
    end,
  })
end
