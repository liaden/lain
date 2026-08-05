-- How a lain:// buffer is made, written and bound: the constructors every
-- capability below calls, plus the shared write (`set_lines`) and the shared
-- post-render announcement. The per-capability constructors do NOT live here --
-- `compose_buf` and `question_buf` sit with the round trips that own them, so a
-- capability stays deletable with its file.
--
-- direction: 1 for ]] (forward), -1 for [[ (backward). Walks from the cursor
-- to the next/previous line `is_start` calls a boundary; running off either
-- end leaves the cursor where it was, same as vim's own ]]/[[ at a buffer
-- edge (no wraparound -- a human re-orients from a fixed end, not a loop).
local function jump_record(buf, direction, is_start)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local i = vim.api.nvim_win_get_cursor(0)[1] + direction
  while i >= 1 and i <= #lines do
    if is_start(lines, i) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
    i = i + direction
  end
end

-- A no-op for DIFF/WORKSPACE (absent from RECORD_START): those are
-- projections of live state, not a log of records, so ]]/[[ has nothing to
-- mean there.
local function bind_motions(buf, name)
  local is_start = RECORD_START[name]
  if is_start then
    vim.keymap.set("n", "]]", function() jump_record(buf, 1, is_start) end,
      { buffer = buf, desc = "lain: next record" })
    vim.keymap.set("n", "[[", function() jump_record(buf, -1, is_start) end,
      { buffer = buf, desc = "lain: previous record" })
  end
end

-- b:lain_view names every lain:// buffer -- the contract's one per-buffer
-- variable (protocol 3), what user config dispatches on given the single
-- shared "lain" filetype. It stopped naming a VIEW at protocol 9: the
-- changeset diff's old side is built through this same constructor, so what it
-- claims there is `lain://review/OLD/<path>`, a value that differs per FILE.
-- Inside a review, b:lain_review_side and its pair (47_diff) are what a gesture
-- reads instead. Set on BOTH constructor paths (create and
-- found-by-name), so a buffer surviving from an older runtime's attach gains
-- it on re-attach, not only at creation. On the create path the claim MUST
-- precede the 'filetype' assignment: setting the option fires FileType
-- SYNCHRONOUSLY, and the advertised dispatch pattern (autocmd FileType lain
-- -> read vim.b.lain_view) would otherwise see nil (panel probe G).
local function claim(buf, name)
  vim.b[buf].lain_view = name
  return buf
end

-- User events -- the stable surface a human's config hooks WITHOUT touching
-- lain internals (protocol 3): LainAttach fires once per attach, its payload
-- naming the full BUFFERS set (plus versions); LainRender fires after every
-- landed render, its payload naming the buffer just written. modeline = false
-- everywhere: these are notifications about nofile buffers, never an edit a
-- modeline should run against. Fold upkeep runs BEFORE the event fires, so a
-- User LainRender autocmd is the per-render escape hatch -- whatever it
-- opens or closes lands last and wins.
local function announce_render(name, buf)
  refresh_folds(buf)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "LainRender",
    modeline = false,
    data = { name = name, buf = buf },
  })
end

-- Every lain:// buffer -- the append-only journal and the read-only state
-- views alike -- is found by name so re-attach reuses it (idempotent) instead
-- of stacking a fresh buffer per reconnect, and stays nomodifiable at rest
-- (4-2.2: "read-only and unobtrusive") so a human's stray keystroke in one
-- can never desync it from the state it presents.
local function named_buf(name)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 then
    return claim(existing, name)
  end

  local buf = claim(vim.api.nvim_create_buf(true, true), name)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = READONLY_FILETYPES[name]
  bind_motions(buf, name)
  return buf
end

-- I7/T5: the record-shaped buffers' one small syntax -- no treesitter grammar
-- shipped, and every group is lain-prefixed so a human's own syntax plugins
-- never collide (the same idea every :Lain* command and augroup already
-- follows). The six documented groups, each anchored to a view's own
-- rendered shape, all `highlight default link`ed so a colorscheme (or the
-- human) overrides any of them without a fight:
--
--   lainToolName   the journal's tool attribution -- the tool_use id (the
--                  tool's name, once renders carry one) leading each
--                  "[id stream]" prefix (JournalView#attribute_lines)
--   lainDigest     the Store's own "blake3:..." digest shape
--   lainRole       exactly {Event::ROLES} (user/assistant) opening a
--                  timeline turn line (Buffers#turn_line)
--   lainEventKind  {Event::KINDS} plus the tool-stream words the journal
--                  prints (stdout/stderr)
--   lainAge        {InboxView#age_of}'s "12s"/"3m"/"1h" shape
--   lainSender     inbox sender attribution: the text leading the
--                  double-space-padded age -- the same both-sides anchor
--                  RECORD_START[INBOX] rides, for the same reason (a
--                  variable-length sender name has no fixed column). A
--                  leading "[" is refused (panel probe F): the syntax is
--                  SHARED across the lain views, and a journal line whose
--                  tool stdout happens to contain "  12s  " would otherwise
--                  paint its "[id stream]" attribution as a sender,
--                  swallowing lainToolName
--
-- Registered once per attach in a cleared augroup (idempotent re-attach,
-- same convention as `lain_inbox` below); the MATCHES it defines stick to
-- each buffer once applied, so a second attach re-registering the autocmd
-- does not need to (and will not, since FileType only fires on a filetype
-- CHANGE) redraw syntax on a buffer the first attach already set up.
local syntax_group = vim.api.nvim_create_augroup("lain_syntax", { clear = true })
vim.api.nvim_create_autocmd("FileType", {
  group = syntax_group,
  pattern = "lain",
  -- [=[ ... ]=] (not [[ ... ]]): lainToolName's bracket expression contains a
  -- literal "]]", which would close a plain long-bracket string mid-regex.
  callback = function()
    vim.cmd([=[
      syntax clear
      syntax match lainToolName /^\[\zs[^ \]]\+/
      syntax match lainDigest /\<blake3:\S\+/
      syntax match lainRole /^\(user\|assistant\)\ze:/
      syntax match lainEventKind /\<\(turn\|spawn\|message\|snapshot\|tool_use\|tool_result\|stdout\|stderr\)\>/
      syntax match lainAge /\<[0-9]\+[smh]\>/
      syntax match lainSender /^\[\@!.\{-1,}\ze  [0-9]\+[smh]  /
      highlight default link lainToolName Function
      highlight default link lainDigest Identifier
      highlight default link lainRole Keyword
      highlight default link lainEventKind Type
      highlight default link lainAge Comment
      highlight default link lainSender Constant
    ]=])
  end,
})

-- `nvim_buf_set_lines` itself raises against a nomodifiable buffer, so every
-- write flips the option around the call rather than leaving it open --
-- nomodifiable is the buffer's resting state, and the flip is one synchronous
-- Lua call, never observable as a modifiable window a human could type into.
local function set_lines(buf, start, stop, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, start, stop, false, lines)
  vim.bo[buf].modifiable = false
end

-- The ONE editable lain:// buffer (4-2.3): same scratch shape as named_buf but
-- left MODIFIABLE at rest, because a human edits the pending request here before
-- :LainResend. Idempotent by name on re-attach, like every other lain:// buffer.
--
-- I7: reuses nvim's built-in "markdown" filetype (READONLY_FILETYPES' comment
-- explains the "just works, no grammar shipped" reasoning; markdown was the
-- deliberate pick here too, not "json"). The payload is pretty-printed JSON,
-- not prose -- worth naming why that is not a format-on-save hazard: `buftype
-- = "nofile"` below is the actual guard. BufWritePre (what every
-- format-on-save plugin rides) never fires on a nofile buffer -- nvim raises
-- E382 on `:write` before autocommands even run -- so no formatter can touch
-- these bytes via save, human `:w` included. Filetype alone would not have
-- been enough; buftype is what makes it safe. Belt-and-suspenders anyway: a
-- formatter that DID reach the buffer through some other trigger and mangled
-- it into invalid JSON still only degrades to a silent, harmless :LainResend
-- no-op (RequestBuffer#parse already treats a malformed edit that way) --
-- the frontend holds no commit path into the Timeline at all.
local function editable_buf(name)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 then
    return claim(existing, name)
  end

  local buf = claim(vim.api.nvim_create_buf(true, true), name)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  return buf
end
