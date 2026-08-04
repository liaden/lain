-- BEFORE 20_buffers, and that is the one ordering in this directory a reader
-- would guess wrong: folds look like a decoration layered ON buffers, but
-- `announce_render` -- which every set_* render entry point calls -- opens with
-- `refresh_folds`, so the dependency runs the other way. Nothing here reads a
-- buffer constructor back, so the cut is clean in this direction only.
--
-- Folds are opt-out, not opt-in: vim.g.lain_fold = false disables the whole
-- surface, checked per fold event so a human can flip it live -- flipping it
-- UN-installs any window still carrying the surface (see uninstall_folds).
local function fold_enabled()
  return vim.g.lain_fold ~= false
end

-- w:lain_fold_saved is both the "surface installed here" marker and the
-- window's PRIOR fold options, captured at install so leaving the lain view
-- can hand the window back exactly as found (panel probe J: window options
-- are sticky per window, and lain's expr surface riding into the human's
-- next buffer would flatten their own indent/marker folds). A window
-- variable, not a lua table, so it dies with the window -- but :vsplit
-- copies window OPTIONS and NOT window variables (probe J re-run), so a
-- split from a lain-view window carries lain's foldexpr with no saved
-- record. That orphaned surface (however a window acquired it) self-heals
-- here: no saved options means the GLOBAL values are the best truth of
-- "before lain", exactly what a fresh split would have held.
local function uninstall_folds(win)
  local saved = vim.w[win].lain_fold_saved
  if saved == nil then
    if not vim.wo[win].foldexpr:find("__lain", 1, true) then
      return
    end
    saved = { method = vim.go.foldmethod, expr = vim.go.foldexpr, text = vim.go.foldtext,
              minlines = vim.go.foldminlines, level = vim.go.foldlevel }
  end
  vim.w[win].lain_fold_saved = nil
  vim.wo[win][0].foldmethod = saved.method
  vim.wo[win][0].foldexpr = saved.expr
  vim.wo[win][0].foldtext = saved.text
  vim.wo[win][0].foldminlines = saved.minlines
  vim.wo[win][0].foldlevel = saved.level
  -- Switching 'foldmethod' back to "manual" KEEPS the expr-computed folds as
  -- manual folds (vim's documented conversion) -- eliminate them, or lain's
  -- record folds would linger in the human's buffer. Any other restored
  -- method recomputes its own folds and drops lain's for free.
  if saved.method == "manual" then
    vim.api.nvim_win_call(win, function()
      vim.cmd("silent! normal! zE")
    end)
  end
end

-- The older-closed/newest-open DEFAULT, applied ONCE per display (the
-- BufWinEnter install), never per render: the editor itself preserves
-- per-fold open/closed state across appends and whole-buffer replaces
-- (panel probe I), so re-forcing it every render only stomped the human's
-- own zo/zR (panel probe H). The close is an explicit :%foldclose!, not a
-- 'foldlevel' write: folds just created come out OPEN and a same-value
-- foldlevel write is a no-op, so the option alone shows nothing closed --
-- verified live. vim.g.lain_foldlevel (>= 1 covers these level-1 folds)
-- skips the forced close for a human who wants everything open at rest.
-- WHICH record stays open at rest, and it is not one answer for every view. A
-- LOG's live record is its LAST -- a human follows a timeline or a journal
-- downward, and the newest line is the one they are waiting for. A FORM's is
-- its FIRST: lain://question is a document to fill in from the top, and the
-- older-closed default handed the human a form with the cursor on line 1
-- INSIDE a closed fold, two collapsed summaries above the only open question.
-- A `dd` there deletes a whole question they never saw.
local function open_at_rest(buf)
  if vim.b[buf].lain_view == QUESTION then
    return 1
  end
  return vim.api.nvim_buf_line_count(buf)
end

local function default_folds(win, buf)
  local level = vim.g.lain_foldlevel or 0
  vim.wo[win][0].foldlevel = level
  vim.api.nvim_win_call(win, function()
    if level == 0 then
      vim.cmd("silent! %foldclose!")
    end
    vim.cmd(("silent! %dfoldopen!"):format(open_at_rest(buf)))
  end)
end

-- Every fold-option WRITE in this file goes through vim.wo[win][0] --
-- :setlocal scope -- never bare vim.wo[win]: the bare form writes like :set,
-- which ALSO updates the option's global default for every window opened
-- later (verified live -- it was why the orphan self-heal above once read
-- lain's own values back out of vim.go and "restored" the leak in place).
-- Local writes keep vim.go.* the human's, which is what makes the heal's
-- global fallback truthful.
local function install_folds(win, buf)
  if vim.w[win].lain_fold_saved == nil then
    vim.w[win].lain_fold_saved = {
      method = vim.wo[win].foldmethod,
      expr = vim.wo[win].foldexpr,
      text = vim.wo[win].foldtext,
      minlines = vim.wo[win].foldminlines,
      level = vim.wo[win].foldlevel,
    }
  end
  vim.wo[win][0].foldmethod = "expr"
  vim.wo[win][0].foldexpr = "v:lua.__lain.foldexpr(v:lnum)"
  vim.wo[win][0].foldtext = "v:lua.__lain.foldtext()"
  -- 'foldminlines' defaults to 1, under which a SINGLE-line fold always
  -- displays open -- and a timeline turn / inbox question is one line
  -- today, so without this the older-closed default silently never shows.
  vim.wo[win][0].foldminlines = 0
  default_folds(win, buf)
end

-- Per-render fold upkeep, deliberately minimal: at most re-open the NEWEST
-- record (the one a human is following live -- an append can land inside a
-- closed last fold), NEVER a re-close or a foldlevel write, so manual opens
-- and zR survive every render (probes H/I). This is also where a live
-- vim.g.lain_fold = false takes effect: a still-installed window meeting a
-- fold event while disabled is restored on the spot.
local function refresh_folds(buf)
  if RECORD_START[vim.b[buf].lain_view] == nil then
    return
  end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.w[win].lain_fold_saved ~= nil then
      if fold_enabled() then
        vim.api.nvim_win_call(win, function()
          vim.cmd(("silent! %dfoldopen!"):format(open_at_rest(buf)))
        end)
      else
        uninstall_folds(win)
      end
    end
  end
end

-- Folds: fold boundaries ARE record boundaries. The foldexpr reuses
-- RECORD_START -- the one source of truth for "where a record starts" that
-- the ]]/[[ motions already ride -- so motions and folds can never disagree
-- about a boundary. One fold per turn on lain://timeline, per pending
-- question on lain://inbox, per "[id stream]" attribution run on
-- lain://journal (the prefix IS the run's tool/stream lineage, so grouping
-- falls out of the same prefix-change test the motion uses). The views
-- ABSENT from RECORD_START get no fold surface, deliberately:
-- lain://request (markdown, human-edited) and lain://diff (nvim's own diff
-- filetype) keep whatever fold behavior the human's config gives those
-- filetypes; lain://workspace is a flat projection with no record grammar.
--
-- foldexpr is evaluated once per LINE per re-evaluation, so it must not read
-- the whole buffer each call (O(n^2) on a growing journal). The
-- cached-anchor idiom: the buffer is read ONCE per changedtick and every
-- per-line call hits the cache.
local fold_lines = {}

-- Valid only while BOTH the changedtick and the line count still match: a
-- recycled bufnr could coincide on tick alone, and stale anchors would fold
-- silently wrong, so the count is the cheap second witness.
local function cached_lines(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local cached = fold_lines[buf]
  if cached == nil or cached.tick ~= tick or #cached.lines ~= vim.api.nvim_buf_line_count(buf) then
    cached = { tick = tick, lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false) }
    fold_lines[buf] = cached
  end
  return cached.lines
end

-- ">1" opens a level-1 fold at each record start; "=" carries that level
-- across a record's continuation lines (the journal's wrapped runs). Lines
-- belonging to no record at all -- the placeholder states, "(no turns yet)"
-- -- sit at level 0, so an empty view offers nothing to fold.
function _G.__lain.foldexpr(lnum)
  local buf = vim.api.nvim_get_current_buf()
  local is_start = RECORD_START[vim.b[buf].lain_view]
  if is_start == nil then
    return "0"
  end
  if is_start(cached_lines(buf), lnum) then
    return ">1"
  end
  return lnum == 1 and "0" or "="
end

-- One line, no noise: a record's own first line already leads with its
-- role/attribution/sender-and-age (that is each view's documented line
-- shape), so it IS the summary; a multi-line record appends only its hidden
-- line count.
function _G.__lain.foldtext()
  local line = vim.fn.getline(vim.v.foldstart)
  local span = vim.v.foldend - vim.v.foldstart + 1
  if span == 1 then
    return line
  end
  return line .. "  (+" .. (span - 1) .. " lines)"
end

-- 'foldmethod' and friends are WINDOW options, and these buffers are created
-- hidden by the first render -- so the fold surface attaches when a lain
-- buffer is first SHOWN (BufWinEnter), not at creation, and only in that
-- window. The pattern is "*", not "lain://*", because the SAME event is the
-- uninstall seam: a window whose buffer stops being a record-shaped lain
-- view (the human navigated away, or vim.g.lain_fold went false) is handed
-- back its saved fold options right here (probe J's leak). Cleared-augroup
-- convention like every lain augroup. The wipeout hook drops the line cache
-- so a recycled bufnr can never serve stale anchors.
local fold_group = vim.api.nvim_create_augroup("lain_folds", { clear = true })
vim.api.nvim_create_autocmd("BufWinEnter", {
  group = fold_group,
  pattern = "*",
  callback = function(ev)
    local win = vim.api.nvim_get_current_win()
    if fold_enabled() and RECORD_START[vim.b[ev.buf].lain_view] ~= nil then
      install_folds(win, ev.buf)
    else
      uninstall_folds(win)
    end
  end,
})
vim.api.nvim_create_autocmd("BufWipeout", {
  group = fold_group,
  pattern = "lain://*",
  callback = function(ev)
    fold_lines[ev.buf] = nil
  end,
})
