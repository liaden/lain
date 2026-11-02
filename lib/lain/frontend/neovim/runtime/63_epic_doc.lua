-- The layout hangs off `tab_layout` rather than a new top-level local: every
-- top-level name is an upvalue each later module pays for. A sidebar render
-- alone never builds the tab, so an idle session gets no extra tabpage.
do
  local planning = tab_layout.new({ var = "lain_planning", SLOTS = { "sidebar", "main" } })
  tab_layout.planning = planning

  function planning.anchor(tab, found, slot)
    if slot == "sidebar" then
      return found.main or vim.api.nvim_tabpage_get_win(tab), "left"
    end
    return found.sidebar or vim.api.nvim_tabpage_get_win(tab), "right"
  end

  -- `tabnew` cannot create a tabpage without entering it, so the caller puts the
  -- human back.
  function planning.ensure()
    local tab = planning.tab()
    if tab == nil then
      vim.cmd("tabnew")
      tab = vim.api.nvim_get_current_tabpage()
      vim.t[tab][planning.VAR] = true
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, planning.buf_for(tab, "main"))
      vim.w[win].lain_slot = "main"
    end
    local found = planning.map(tab)
    if found.sidebar == nil then
      found.sidebar = planning.open(tab, found, "sidebar")
      vim.api.nvim_win_set_width(found.sidebar, vim.g.lain_planning_sidebar_width or 44)
      vim.wo[found.sidebar][0].winfixwidth = true
    end
    return tab, found
  end

  -- Moves nobody: the window id is resolved fresh each call and the human is put
  -- back in the tab they were in.
  function _G.__lain.planning_place(slot, buf)
    local was = vim.api.nvim_get_current_tabpage()
    local tab, found = planning.ensure()
    if tab ~= was then
      vim.api.nvim_set_current_tabpage(was)
    end
    vim.api.nvim_win_set_buf(found[slot], buf)
    planning.remember(tab, slot, buf)
    return found[slot]
  end

  function _G.__lain.planning_sidebar(buf)
    if vim.bo[buf].filetype == "" then
      vim.bo[buf].filetype = "lain"
    end
    vim.keymap.set("n", "<CR>", function() _G.__lain.planning_open() end,
      { buffer = buf, desc = "lain: open the issue under the cursor" })
    if planning.tab() ~= nil then
      _G.__lain.planning_place("sidebar", buf)
    end
  end

  function _G.__lain.planning_open()
    local line = vim.api.nvim_get_current_line()
    local id = line:match("^%[.%] `([^`]+)`")
    if id == nil then
      return
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(buf):match("^lain://epic/[^/]+/issues/" .. vim.pesc(id) .. "%.md$") then
        _G.__lain.planning_place("main", buf)
        return
      end
    end
    vim.notify("lain: issue " .. id .. " has no document written yet", vim.log.levels.INFO)
  end
end

-- The buffer name is dynamic (`lain://epic/<slug>/<path>`), so it is claimed
-- here on first sight rather than listed in READONLY_FILETYPES.
--
-- It takes the planning tab's main window exactly once, when the buffer is
-- created: a later write refreshes the lines in place, and the human's own
-- choice of what the main window shows is not overridden on every rewrite.
function _G.__lain.set_epic_doc(name, lines)
  local created = vim.fn.bufnr(name) == -1
  local buf = named_buf(name)
  vim.bo[buf].filetype = "markdown"
  set_lines(buf, 0, -1, lines)
  if created then
    _G.__lain.planning_place("main", buf)
    _G.__lain.planning_sidebar(named_buf("lain://planning"))
  end
  announce_render(name, buf)
end
