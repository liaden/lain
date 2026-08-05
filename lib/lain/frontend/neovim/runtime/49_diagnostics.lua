-- Annotations and critique findings, projected into nvim's DIAGNOSTIC layer
-- (T17). The whole trade: a severity map, in exchange for gutter signs, virtual
-- text, `]d`/`[d`, `:setqflist`, severity filtering and every picker's
-- diagnostics source -- which is how `:Telescope diagnostics` becomes a comment
-- browser without a line of code here. None of that is machinery this repo then
-- owns.
--
-- A DISPLAY LAYER, NEVER AN ANCHOR, and that is a measurement rather than a
-- preference. Inserting two lines above a diagnostic, on nvim 0.12.4:
--
--   BEFORE  diag.get lnum=2   anchor extmark row=2   rendered rows=[2]
--   AFTER+2 diag.get lnum=2   anchor extmark row=4   rendered rows=[4]
--
-- `vim.diagnostic.get` reports the same lnum forever, while the sign and
-- virtual text the diagnostic layer drew MOVE -- they are extmarks, and nvim
-- slides them like every other. So the SCREEN keeps looking right while the
-- RECORD goes stale, and everything reading the record (`]d`, `setqflist`, a
-- picker, anything Ruby asks back) answers the old line. A visibly wrong answer
-- would be kinder than that, and it is why the position never travels: an entry
-- names its anchor extmark, this module asks nvim where that mark is NOW, and
-- the whole namespace is re-rendered whenever the buffer changes.
--
-- 49, after 47_diff: the buffers it decorates are T15's, and it reads the
-- `b:lain_review_side` stamp T15 withdraws when the human moves on. ONE new
-- top-level name, as 41_layout and 47_diff each take one, because the chunk
-- shares a scope.
--
-- NOTHING HERE IS ASYNCHRONOUS, the same rule 47_diff states and for the same
-- reason ([diffview#466]: an nvim call reached from a libuv callback needs
-- `vim.schedule`, and getting it wrong crashes the editor instead of failing a
-- spec). This module is the obvious place to reach for `nvim_buf_attach`'s
-- `on_lines` to re-render on every edit; it deliberately does not. Autocmd
-- callbacks run on the main loop, `on_lines` does not, and the two are one
-- keyword apart in a reader's head.
local review_diagnostics = {
  -- Where the human's own notes are anchored. Read, never written and never
  -- cleared: the marks are somebody else's record of where a note lives, and
  -- this module is a projection of them.
  ANCHORS = "lain_review_annotations",

  -- `buf -> namespace -> entries`, so a refresh can redraw the human's notes
  -- and a critique's findings independently without either being told about
  -- the other. Cleared on BufUnload, which is octo's unbounded-registry defect
  -- avoided rather than inherited.
  kept = {},
}

-- The buffer whose marks are being read, VERIFIED. `vim.b[buf]` on a dead
-- buffer raises from inside whatever called it, naming nothing useful; this
-- says which buffer and which entry point.
function review_diagnostics.buffer(buf, verb)
  if type(buf) ~= "number" or not vim.api.nvim_buf_is_valid(buf) then
    error("lain: " .. verb .. " needs a live buffer, not " .. tostring(buf), 0)
  end
  return buf
end

-- Whichever namespace this buffer's notes actually live in: the stamp
-- 65_review.lua already sets when it opens a review, falling back to the name
-- that stamp is derived from. `nvim_create_namespace` answers the same id for a
-- name it already knows, so the fallback is the same namespace rather than a
-- second empty one -- which is what lets this module read marks it never placed
-- without depending on the file that placed them.
function review_diagnostics.anchors(buf)
  return vim.b[buf].lain_annotation_namespace or vim.api.nvim_create_namespace(review_diagnostics.ANCHORS)
end

-- nvim's own severity, from nvim's own spelling. The projection sends
-- "ERROR"/"WARN"/"HINT" rather than 1/2/4 so the numbers live in exactly one
-- place -- nvim's -- and a name nvim does not know is refused here instead of
-- indexing to nil and rendering at whatever severity nil sorts as.
--
-- The table is bidirectional (`severity[1] == "ERROR"`), so the type test is on
-- the ANSWER being a number, not merely on it being non-nil: `severity[1]`
-- would otherwise pass this check and hand a string back as a severity.
function review_diagnostics.severity(name)
  local level = type(name) == "string" and vim.diagnostic.severity[name] or nil
  if type(level) ~= "number" then
    error("lain: " .. tostring(name) .. " is not a vim.diagnostic.severity name -- " ..
      "the projection sends nvim's own spelling (ERROR/WARN/INFO/HINT)", 0)
  end
  return level
end

-- Where the note IS, asked of the extmark that holds it. A mark that answers
-- nothing is refused rather than skipped: the extmark contract measured for T15
-- is that a mark inside a rewritten span MOVES and never invalidates, so an id
-- with no position is a bookkeeping slip -- an entry naming a mark from another
-- buffer or another namespace -- and dropping it silently would lose a note the
-- human wrote while every count still looked right.
--
-- Answers nil rather than refusing, because the two callers want opposite things
-- from the same question and only ONE of them is being told something new. See
-- `list` (refuses) and `surviving` (drops).
function review_diagnostics.row(buf, anchors, mark)
  local position = type(mark) == "number" and vim.api.nvim_buf_get_extmark_by_id(buf, anchors, mark, {}) or {}
  return position[1]
end

-- The diagnostic list, built WHOLE before anything is rendered. A refusal
-- part-way through would otherwise leave the namespace holding the entries that
-- happened to come first, which reads as a review with some of its notes.
--
-- `col = 0` because an anchor is a line, not a column: a note is about the line
-- the human was on, and a column nobody chose would put the sign and the
-- `]d` landing point somewhere they did not mean.
function review_diagnostics.list(buf, entries)
  local anchors = review_diagnostics.anchors(buf)
  local list = {}
  for i, entry in ipairs(entries) do
    if type(entry) ~= "table" or type(entry.message) ~= "string" then
      error("lain: diagnostic entry " .. i .. " carries no message -- " ..
        "an entry is { mark, message, severity, source } as Review::Projection::Diagnostics sends it", 0)
    end
    local row = review_diagnostics.row(buf, anchors, entry.mark)
    if row == nil then
      error("lain: no annotation extmark " .. tostring(entry.mark) .. " in buffer " .. buf ..
        " -- a diagnostic's line comes from its mark, so a mark that answers nothing is a note pointing nowhere", 0)
    end
    list[i] = {
      lnum = row,
      col = 0,
      message = entry.message,
      severity = review_diagnostics.severity(entry.severity),
      source = type(entry.source) == "string" and entry.source or nil,
    }
  end
  return list
end

-- The entries whose anchors are STILL THERE, for the speculative path.
--
-- This is the set/refresh asymmetry this module already states for T15's stamp,
-- applied to the mark -- and it was missing, which cost the card its own failure
-- mode back. A `set` is Ruby naming a mark it believes in, so a mark that
-- answers nothing is a bookkeeping slip and is refused. A REFRESH is
-- speculative: T16 owns annotation removal, so a mark that has gone since the
-- render is a note somebody legitimately withdrew, not a slip.
--
-- Raising there was silently catastrophic rather than loud. Measured: clear the
-- annotation namespace and type one character -- nvim SWALLOWS an error thrown
-- from an autocmd callback, the buffer stays in `kept`, and the diagnostic sits
-- at its stale row forever. That is exactly the "screen right, record stale"
-- failure this whole module exists to prevent, made permanent, plus an error
-- message per keystroke under a real UI.
function review_diagnostics.surviving(buf, entries)
  local anchors = review_diagnostics.anchors(buf)
  local kept = {}
  for _, entry in ipairs(entries) do
    if review_diagnostics.row(buf, anchors, entry.mark) ~= nil then
      table.insert(kept, entry)
    end
  end
  return kept
end

-- An empty namespace is FORGOTTEN, not remembered as empty, and a buffer with
-- no namespaces left stops being tracked at all. That is what makes
-- `review_diagnostics_tracked` an honest answer to "what would a refresh
-- redraw" rather than a list of everything ever rendered.
function review_diagnostics.remember(buf, namespace, entries)
  local held = review_diagnostics.kept[buf] or {}
  held[namespace] = #entries > 0 and entries or nil
  review_diagnostics.kept[buf] = next(held) ~= nil and held or nil
end

-- Clear this buffer's diagnostics everywhere they were drawn, and stop tracking
-- it. Only the namespaces THIS module rendered into: an lsp's diagnostics on
-- the same buffer are somebody else's and survive.
function review_diagnostics.withdraw(buf)
  local held = review_diagnostics.kept[buf]
  review_diagnostics.kept[buf] = nil
  if held == nil or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  for namespace, _ in pairs(held) do
    vim.diagnostic.reset(vim.api.nvim_create_namespace(namespace), buf)
  end
end

-- Render one namespace of notes onto one buffer, replacing whatever it held.
--
-- @param buf the buffer the anchor extmarks live in
-- @param namespace the diagnostic namespace -- the human's notes and a
--   critique's findings take different ones, so a suggestion is visibly a
--   suggestion and clearing one never touches the other
-- @param entries `{ mark, message, severity, source }`, exactly as
--   `Review::Projection::Diagnostics#arguments` sends them. No line: only the
--   editor knows where a mark is now.
function _G.__lain.set_review_diagnostics(buf, namespace, entries)
  review_diagnostics.buffer(buf, "set_review_diagnostics")
  if type(namespace) ~= "string" or namespace == "" then
    error("lain: set_review_diagnostics needs a namespace name, not " .. tostring(namespace), 0)
  end
  if type(entries) ~= "table" then
    error("lain: set_review_diagnostics needs an entry list, not " .. tostring(entries), 0)
  end

  local list = review_diagnostics.list(buf, entries)
  vim.diagnostic.set(vim.api.nvim_create_namespace(namespace), buf, list)
  review_diagnostics.remember(buf, namespace, entries)
end

-- Redraw every namespace on this buffer from where its marks are NOW. Cheap and
-- idempotent: nothing crosses the wire, because the words were remembered when
-- they were rendered and only the positions can have moved.
--
-- It re-checks T15's stamp AND each mark, where `set_review_diagnostics` refuses
-- on both, and the asymmetry is the point. A `set` is an instruction from Ruby,
-- which knows what it is rendering; a refresh is speculative -- an autocmd fired
-- it, or a caller with no fresh knowledge did -- so it has to ask whether the
-- claims still hold, and a claim that has stopped holding is somebody else's
-- legitimate change rather than an error to throw at them.
--
-- So: T15 withdraws the stamp when the human moves on (the new side is a real
-- file buffer that outlives the review, and diagnostics left on it would be a
-- review of a file nobody is reviewing) -- the buffer is cleared and forgotten.
-- T16 withdraws a note -- that entry is dropped, its siblings keep rendering,
-- and a namespace with nothing left is reset and forgotten. NOTHING here
-- raises, because see `surviving`: an error thrown from an autocmd callback is
-- swallowed by nvim, which turns a refusal into a diagnostic frozen at a stale
-- row forever.
function _G.__lain.refresh_review_diagnostics(buf)
  local held = review_diagnostics.kept[buf]
  if held == nil then
    return
  end
  if not vim.api.nvim_buf_is_valid(buf) or vim.b[buf].lain_review_side == nil then
    review_diagnostics.withdraw(buf)
    return
  end
  -- The surviving map is built and only then installed: `remember` reads and
  -- rewrites `kept[buf]`, and calling it inside this loop would both mutate the
  -- table being traversed and resurrect a buffer it had just dropped.
  local remaining = {}
  for namespace, entries in pairs(held) do
    local surviving = review_diagnostics.surviving(buf, entries)
    local id = vim.api.nvim_create_namespace(namespace)
    if #surviving > 0 then
      vim.diagnostic.set(id, buf, review_diagnostics.list(buf, surviving))
      remaining[namespace] = surviving
    else
      vim.diagnostic.reset(id, buf)
    end
  end
  review_diagnostics.kept[buf] = next(remaining) ~= nil and remaining or nil
end

-- Which buffers a refresh would redraw. Introspection, and the only way a spec
-- can assert the registry does not grow -- octo's own defect is invisible from
-- the outside precisely because a leak renders identically to no leak.
function _G.__lain.review_diagnostics_tracked()
  local tracked = {}
  for buf, _ in pairs(review_diagnostics.kept) do
    table.insert(tracked, buf)
  end
  table.sort(tracked)
  return tracked
end

-- One group, created once and reused: `nvim_create_augroup(name, { clear =
-- true })` called a second time would delete the autocmd registered against the
-- first call.
local review_diagnostics_group = vim.api.nvim_create_augroup("lain_review_diagnostics", { clear = true })

-- The re-render, on the human's own edits. TextChanged and InsertLeave rather
-- than TextChangedI: what goes stale is the RECORD, not the picture -- the sign
-- and the virtual text are extmarks and slide by themselves -- so a redraw per
-- keystroke would buy nothing a human can see, and leaving insert is soon
-- enough for `]d` and the quickfix list to be right.
vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
  group = review_diagnostics_group,
  callback = function(ev) _G.__lain.refresh_review_diagnostics(ev.buf) end,
})

-- Entries for a buffer that is gone are entries nothing can redraw. Dropped
-- rather than withdrawn: the diagnostics die with the buffer, and
-- `vim.diagnostic.reset` on a buffer mid-unload is work for nobody.
vim.api.nvim_create_autocmd("BufUnload", {
  group = review_diagnostics_group,
  callback = function(ev) review_diagnostics.kept[ev.buf] = nil end,
})
