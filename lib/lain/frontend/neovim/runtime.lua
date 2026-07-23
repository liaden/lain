-- lain runtime, injected at attach via nvim_exec_lua. It ships IN the gem (read
-- and sent by Frontend::Neovim::RpcThread), so the lua here and the Ruby that
-- speaks to it can never drift across repos -- the whole reason lain installs
-- nothing in the user's dotfiles. See planning/interface-integration.md.
--
-- Injected args: the gem version (display only, surfaced by :LainVersion), the
-- protocol token (compatibility), and the RPC channel id to call back on.
local gem_version, protocol, chan = ...

-- The Ruby<->runtime contract version: the twin of Frontend::Neovim::PROTOCOL.
-- Bumped in lockstep with it when the injected protocol changes -- never for a
-- gem release, which is why the handshake does not compare gem versions. A
-- mismatch WARNS and keeps going: a stale editor half-works (commands still
-- fire, renders still land) rather than crashing the human's session outright.
local RUNTIME_PROTOCOL = "3"
if protocol ~= RUNTIME_PROTOCOL then
  vim.api.nvim_echo({
    { "lain: runtime.lua protocol " .. RUNTIME_PROTOCOL .. " / gem protocol " .. tostring(protocol) .. " mismatch", "WarningMsg" },
  }, true, {})
end
vim.g.lain_rpc_version = protocol

-- Every lain:// buffer this runtime knows the name of ahead of time -- named
-- once here (I7) so the filetype table, the motion table, and every autocmd
-- pattern below share ONE spelling instead of five copies of the string.
local JOURNAL = "lain://journal"
local TIMELINE = "lain://timeline"
local WORKSPACE = "lain://workspace"
local DIFF = "lain://diff"
local INBOX = "lain://inbox"
local REQUEST = "lain://request"

-- The full buffer set, in render order, as ONE value user config can iterate
-- (it rides the User LainAttach payload below). WORKSPACE joining the set is
-- T5's fix: Ruby (Buffers::WORKSPACE) always rendered it, but no lua table
-- named it, so set_view built it as an orphan -- filetype "" (the nil lookup
-- landed as an unset option), no syntax, outside the lain contract.
local BUFFERS = { JOURNAL, TIMELINE, WORKSPACE, DIFF, INBOX, REQUEST }

-- I7: filetype attached at buffer CREATION (see `named_buf`/`editable_buf`
-- below), never re-set on re-attach -- both constructors already return
-- early for a buffer that exists, so this runs exactly once per buffer ever.
-- lain://diff reuses nvim's own "diff" filetype so whatever treesitter/syntax
-- a human's config attaches to it just works -- no grammar shipped. The other
-- read-only buffers are not an existing filetype's shape (a turn log, a
-- tool-output journal, a pending-question list, a reminders projection), so
-- they share ONE small namespaced regex syntax ("lain", set up further down)
-- -- the recorded default: a single lain filetype, with b:lain_view naming the
-- view, never per-view filetypes.
local READONLY_FILETYPES = {
  [DIFF] = "diff",
  [TIMELINE] = "lain",
  [JOURNAL] = "lain",
  [INBOX] = "lain",
  [WORKSPACE] = "lain",
}

-- I7 motions: ]]/[[ jump between "records", but the three bespoke buffers
-- pack records differently, so each gets its own boundary TEST rather than
-- one shared regex. lain://timeline is one turn per LINE (Buffers#turn_line);
-- lain://inbox is one item per LINE, marked by InboxView#line_for's own
-- two-space-padded age; lain://journal is the odd one out -- one tool-output
-- RUN can span several wrapped LINES sharing an "[id stream]" prefix
-- (JournalView#attribute_lines), so its boundary is a PREFIX CHANGE, not
-- "next line" -- else every wrapped line would present as its own record.
local function journal_prefix(line)
  return line:match("^%[([^%]]*)%]")
end

local RECORD_START = {
  [TIMELINE] = function(lines, i) return lines[i]:match("^%a+:") ~= nil end,
  -- Not anchored at column 1: `from` is a variable-length sender name
  -- (InboxView::Item), so the age's COLUMN moves per line and there is no
  -- fixed position to anchor to. Anchored on BOTH sides against the
  -- separator instead -- exactly InboxView#line_for's two-space padding
  -- around the age (`"#{from}  #{age}  #{question}"`) -- which is tighter
  -- than "digits followed by s/m/h" alone: a question's free text would need
  -- to independently contain that exact double-space-padded shape to
  -- false-positive, an accepted low-probability risk for an ergonomic (not
  -- correctness-critical) motion.
  [INBOX] = function(lines, i) return lines[i]:match("  %d+[smh]  ") ~= nil end,
  [JOURNAL] = function(lines, i)
    return i == 1 or journal_prefix(lines[i]) ~= journal_prefix(lines[i - 1])
  end,
}

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

-- b:lain_view names the view on every lain:// buffer -- the contract's one
-- per-buffer variable (protocol 3), what user config dispatches on given the
-- single shared "lain" filetype. Set on BOTH constructor paths (create and
-- found-by-name), so a buffer surviving from an older runtime's attach gains
-- it on re-attach, not only at creation. On the create path the claim MUST
-- precede the 'filetype' assignment: setting the option fires FileType
-- SYNCHRONOUSLY, and the advertised dispatch pattern (autocmd FileType lain
-- -> read vim.b.lain_view) would otherwise see nil (panel probe G).
local function claim(buf, name)
  vim.b[buf].lain_view = name
  return buf
end

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
local function default_folds(win, buf)
  local level = vim.g.lain_foldlevel or 0
  vim.wo[win][0].foldlevel = level
  vim.api.nvim_win_call(win, function()
    if level == 0 then
      vim.cmd("silent! %foldclose!")
    end
    vim.cmd(("silent! %dfoldopen!"):format(vim.api.nvim_buf_line_count(buf)))
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
          vim.cmd(("silent! %dfoldopen!"):format(vim.api.nvim_buf_line_count(buf)))
        end)
      else
        uninstall_folds(win)
      end
    end
  end
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

_G.__lain = _G.__lain or {}

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

-- Append already-rendered plain lines to the journal. The Ruby RPC thread
-- calls this once per drained batch (the batch rule), never per event. A
-- fresh scratch buffer holds one empty line; the first render replaces it
-- rather than appending below it, so the journal never leads with a blank.
function _G.__lain.render(lines)
  local buf = named_buf(JOURNAL)
  local fresh = vim.api.nvim_buf_line_count(buf) == 1
    and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
  if fresh then
    set_lines(buf, 0, -1, lines)
  else
    set_lines(buf, -1, -1, lines)
  end
  announce_render(JOURNAL, buf)
end

-- Whole-buffer replace for the state views (4-2.2): lain://timeline,
-- lain://workspace, lain://diff. Unlike the journal these are PROJECTIONS of
-- live state, not a log, so an update REPLACES the buffer's content rather
-- than growing it -- never nvim_input/feedkeys, and the buffer is never
-- focused or jumped to, so a live update cannot steal the human's cursor.
-- The write starts at the first DIFFERING line, not at line 0: a naive
-- whole-buffer replace makes the editor refold everything, resetting every
-- manually opened fold to the foldlevel default (verified live -- probe H's
-- stomp had a second root besides the old forced re-close), while lines an
-- edit never touches keep their fold state naturally (probe I's append
-- evidence). These views grow append-mostly (a timeline gains turns; the
-- shared prefix is stable), so the trimmed write makes the natural
-- preservation the folds rely on the common case -- and skips redraw work
-- for free.
function _G.__lain.set_view(name, lines)
  local buf = named_buf(name)
  local old = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local shared = 0
  while shared < #old and shared < #lines and old[shared + 1] == lines[shared + 1] do
    shared = shared + 1
  end
  set_lines(buf, shared, -1, vim.list_slice(lines, shared + 1, #lines))
  announce_render(name, buf)
end

-- Whole-buffer replace for the ONE editable view, lain://request (4-2.3). It
-- writes WITHOUT the nomodifiable flip set_view does, so the buffer stays
-- editable for the human after the render. Like set_view it never focuses or
-- jumps to the buffer, so a re-render can't steal the cursor mid-edit.
function _G.__lain.set_request(name, lines)
  local buf = editable_buf(name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  announce_render(name, buf)
end

-- The current lain://request bytes, for :LainResend to hand back to Ruby -- read
-- HERE, in the lua callback, so the resend rpcrequest carries the edited lines
-- as its argument and the Ruby side never has to nest a buffer read inside its
-- inbound dispatch. Empty when nobody has rendered a request yet.
local function request_lines()
  local buf = vim.fn.bufnr(REQUEST)
  if buf == -1 then
    return {}
  end
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

-- Re-attach is idempotent: delete before create so a name is defined exactly
-- once, and every command is Lain-namespaced (no collision with the human's
-- config or a plugin).
local function define(name, fn, opts)
  pcall(vim.api.nvim_del_user_command, name)
  vim.api.nvim_create_user_command(name, fn, opts or {})
end

-- Agent-facing commands enqueue-and-ack: the callback makes ONE blocking
-- rpcrequest that the Ruby side answers in microseconds (queue the work, ack).
-- The editor unblocks immediately; the agent's latency never freezes it.
local function agent_command(name)
  return function()
    vim.rpcrequest(chan, "lain_command", name)
  end
end

-- :LainResend carries the edited buffer along, so it can't reuse agent_command
-- (which sends only the verb): it reads lain://request and passes the lines as
-- the command's second argument. Still enqueue-and-ack -- the Ruby side queues
-- the resend and answers in microseconds, exactly like the bare commands.
define("LainResend", function()
  vim.rpcrequest(chan, "lain_command", "resend", request_lines())
end)
define("LainSend", agent_command("send"))
define("LainContext", agent_command("context"))

-- The human inbox drain (I6). :LainReply {answer} submits the typed answer as
-- a "reply" command -- enqueue-and-ack like every command, so the agent-side
-- consumer resolves the pending ask_human promise off its own queue and the
-- editor never blocks on it. The answer rides as the command's argument;
-- per-item targeting waits for the multi-question design step (today one
-- question is pending at a time -- ask_human's single-@pending invariant).
local function submit_reply(answer)
  if answer ~= "" then
    vim.rpcrequest(chan, "lain_command", "reply", { answer })
  end
end

define("LainReply", function(opts)
  submit_reply(opts.args)
end, { nargs = "+" })

-- The cursor-on-an-item drain: `r` and, I7, <CR> in lain://inbox prompt for
-- the answer and submit it by invoking :LainReply itself, not {submit_reply}
-- directly -- so both keys are provably the SAME path a human typing the
-- command by hand would take, and the empty-answer guard lives in ONE place
-- (nargs = "+" already refuses zero arguments; skipping the call below on a
-- blank/cancelled prompt keeps that the only guard). Bound from a BufEnter
-- autocmd (in a cleared augroup, so re-attach redefines rather than stacks)
-- because the buffer is created lazily by the first render, not here.
local function prompt_reply()
  vim.ui.input({ prompt = "answer> " }, function(answer)
    if answer and answer ~= "" then
      vim.cmd("LainReply " .. answer)
    end
  end)
end

local group = vim.api.nvim_create_augroup("lain_inbox", { clear = true })
vim.api.nvim_create_autocmd("BufEnter", {
  group = group,
  pattern = INBOX,
  callback = function(ev)
    vim.keymap.set("n", "r", prompt_reply, { buffer = ev.buf, desc = "lain: answer the pending question" })
    vim.keymap.set("n", "<CR>", prompt_reply, { buffer = ev.buf, desc = "lain: answer the pending question" })
  end,
})

-- The observable half of the version handshake: :LainVersion surfaces the gem
-- version the attach recorded, straight into :messages -- no rpc round trip.
define("LainVersion", function()
  vim.api.nvim_echo({ { "lain gem " .. tostring(gem_version), "None" } }, true, {})
end)

-- The attach announcement, deliberately LAST: by the time a user callback
-- runs, every :Lain* command and autocmd above exists, so config reacting to
-- LainAttach may call any of them. The payload carries buffer NAMES (the
-- whole BUFFERS set), never bufnrs -- the buffers themselves are created
-- lazily by the first render, which each announces itself via LainRender.
-- protocol is RUNTIME_PROTOCOL, the contract this running lua actually
-- speaks, which a mismatched injection has already warned about above.
vim.api.nvim_exec_autocmds("User", {
  pattern = "LainAttach",
  modeline = false,
  data = { buffers = BUFFERS, gem_version = tostring(gem_version), protocol = RUNTIME_PROTOCOL },
})
