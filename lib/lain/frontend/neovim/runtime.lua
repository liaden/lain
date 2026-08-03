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
local RUNTIME_PROTOCOL = "6"
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
local COMPOSE = "lain://compose"
local QUESTION = "lain://question"

-- The full buffer set, in render order, as ONE value user config can iterate
-- (it rides the User LainAttach payload below). WORKSPACE joining the set is
-- T5's fix: Ruby (Buffers::WORKSPACE) always rendered it, but no lua table
-- named it, so set_view built it as an orphan -- filetype "" (the nil lookup
-- landed as an unset option), no syntax, outside the lain contract.
--
-- COMPOSE is deliberately NOT in the set (T15), and QUESTION is out for the
-- same reason (T12). Every name here is a projection primed at attach;
-- lain://compose exists only while the human is composing, lain://question only
-- while a set is open, each is created by a gesture, and each takes focus --
-- priming either would open an empty editor window at every attach.
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

-- lain://question's record is one QUESTION, and its start is the heading
-- Question::Document writes: "## `id` (arity)". The ARITY WORD rides in the
-- heading, so this is the same line the `x` keymap recovers a question's
-- boundary from -- one shape read by both, never two.
--
-- The arity is captured and looked up rather than spelled into the pattern:
-- lua patterns have no alternation, so a set of the three labels
-- Question::Document::KIND_LABELS emits is how the disjunction is expressed at
-- all. A body line wearing this shape cannot forge a boundary here --
-- Question::DOCUMENT_HEADING refuses one where the body is BUILT.
--
-- The VALUE is how many ticks the question may carry, which is the other thing
-- the arity word says and the only thing `x` needs from it: "write your answer
-- below" is Question::Document::FREE_TEXT -- a question with no options at all,
-- so nothing under that heading is ever tickable.
local QUESTION_ONE, QUESTION_ANY, QUESTION_NONE = "one", "any", "none"
local QUESTION_ARITIES = {
  ["choose one"] = QUESTION_ONE,
  ["choose any"] = QUESTION_ANY,
  ["write your answer below"] = QUESTION_NONE,
}

-- The question's tick arity, which doubles as the "this line is a heading"
-- predicate the motions and folds ride -- nil for every other line.
local function question_heading(line)
  local arity = line:match("^## `[^`]+` %((.+)%)$")
  return arity ~= nil and QUESTION_ARITIES[arity] or nil
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
  [QUESTION] = function(lines, i) return question_heading(lines[i]) end,
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

-- lain://compose (T15): the ONE lain:// buffer nvim must be able to `:write`,
-- because `:w` IS the return leg of the compose round trip. Two option
-- choices here are not preferences, they are the only settings that work, and
-- both were found the hard way:
--
--   buftype = "acwrite"  -- `nofile` refuses `:write` with E382 BEFORE any
--                           autocommand runs, so BufWriteCmd would never fire
--                           at all. (This is the same property that makes
--                           lain://request safe from format-on-save; here it
--                           is exactly what we must not have.)
--   nvim_buf_set_name    -- an acwrite buffer with no name fails `:write`
--                           with E32. The name is the write target, and it is
--                           also how Ruby and the BufWriteCmd pattern find it.
--
-- bufhidden stays "hide", NOT "wipe": a human who steps over to lain://journal
-- mid-compose and comes back must find their draft, and BufUnload is the
-- ABANDON signal -- wiping on hide would report an abandon they never made.
-- So an abandon means an explicit :bdelete/:bwipeout (or quitting nvim), which
-- is precisely the gesture the round trip reads it as. Verified bonus: "hide"
-- plus nvim's default 'hidden' means even `autowriteall` + a buffer switch
-- does NOT fire a write, because the buffer is hidden rather than abandoned.
--
-- KNOWN LIMITATION, probed and not worked around: `:wall`, and any autosave
-- plugin issuing a timed `:w`, DOES fire BufWriteCmd, and the round trip takes
-- that as the human's answer -- so half-typed text can settle a compose. lain
-- attaches to the human's OWN nvim with their own plugins, so this is not
-- exotic. It is not defended against because the defence would be to stop
-- using `:w` as the gesture, and `:w` being the gesture is the feature: it is
-- the one verb every vim user already reads as "I am done with this text".
local function compose_buf(name)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 then
    return claim(existing, name)
  end

  local buf = claim(vim.api.nvim_create_buf(true, true), name)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  return buf
end

-- lain://question (T12): compose_buf's shape exactly -- `acwrite` so `:w` can
-- be intercepted at all, a name so `:write` does not answer E32, "hide" so
-- BufUnload means the human closed it rather than merely looked away, markdown
-- because the document IS markdown -- plus the two indent options, which are
-- not preferences either.
--
-- Question::Document's comment slot is prose indented EXACTLY two spaces, and
-- a line indented any other way is refused BY NAME rather than dedented (the
-- grammar will not guess what a tab meant, because guessing is how a round trip
-- starts editing the human's whitespace). A human whose own config indents with
-- tabs would otherwise type a comment the grammar rejects on `:w`, on a line
-- they were invited to write. So the buffer produces the grammar's bytes
-- itself: 'expandtab' makes every indent spaces, 'shiftwidth' makes >> and
-- autoindent two of them, and 'softtabstop' makes the Tab KEY two -- the last
-- is not redundant, because with 'softtabstop' unset a Tab keypress inserts
-- 'tabstop' (8) spaces no matter what 'shiftwidth' says.
--
-- WHERE THIS DIVERGES FROM COMPOSE, and why it had to. `:wall` and autosave
-- plugins fire BufWriteCmd on text the human did not finish, which compose
-- accepts as a known limitation. The blast radius here is LARGER, not smaller,
-- and an earlier version of this comment claimed the opposite: a half-answered
-- document does not fail the grammar. It parses perfectly -- Question::AnswerSet
-- fills an untouched question in as an explicitly unanswered Answer, by design,
-- and `parse_markdown(to_markdown(a), set) == a` is the unit's stated law. So a
-- stock `:wall` over the document as lain rendered it told the model the human
-- had DECLINED EVERY QUESTION, closed the view, and answered their real `:w`
-- with STALE.
--
-- So the write below refuses a buffer byte-identical to what lain rendered,
-- and names `:w!` as the way through. That is not "you must answer before you
-- may submit" (Question::AnswerSet's ruling is explicit that an unanswered
-- question is a legal answer); it is refusing to read a keystroke nobody typed
-- as a decision. b:lain_question_rendered is that comparison's other half,
-- stamped beside the digest in set_question.
local function question_buf(name)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 then
    return claim(existing, name)
  end

  local buf = claim(vim.api.nvim_create_buf(true, true), name)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].expandtab = true
  vim.bo[buf].shiftwidth = 2
  vim.bo[buf].softtabstop = 2
  -- AFTER 'filetype', deliberately: setting it fires FileType synchronously and
  -- nvim's own markdown ftplugin maps ]] and [[ to its section motions. lain's
  -- records ARE the questions, so lain's maps must be the ones that survive --
  -- this is the first buffer where RECORD_START serves folds and motions from
  -- the same predicate and the motions were not bound.
  bind_motions(buf, name)
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

-- Open lain://compose on the human's draft (T15). The ONE render entry point
-- that deliberately takes the cursor: every other buffer here is a live
-- projection that must never steal focus mid-thought, whereas this one exists
-- because the human just pressed C-g and asked to be put in it. It is shown
-- in a split only when no window already holds it, so a second compose lands
-- in the window they left open rather than stacking splits.
--
-- 'modified' is cleared after the write: the buffer's content came from lain,
-- not from the human, so leaving it dirty would make nvim argue about unsaved
-- changes over text nobody typed.
-- b:lain_compose_generation is stamped here and sent back with every answer,
-- so Ruby can tell WHICH compose the editor is talking about. The buffer is
-- reused across round trips (found by name), so a write still in flight when
-- the human opens a second compose would otherwise be indistinguishable from
-- the second one's answer.
function _G.__lain.set_compose(name, lines, generation)
  local buf = compose_buf(name)
  vim.b[buf].lain_compose_generation = generation
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  if vim.fn.win_findbuf(buf)[1] == nil then
    vim.api.nvim_open_win(buf, true, { split = "below", win = 0 })
  end
  announce_render(name, buf)
end

-- Open lain://question on a pending set's rendered document (T12), taking the
-- cursor for set_compose's reason: lain is handing the human something and
-- asking them to answer it.
--
-- FOCUSING an already-shown buffer is this function's job and not Ruby's, and
-- that division is deliberate. QuestionView REFUSES to open a set while one is
-- open, so nothing above ever re-renders over a half-ticked document -- which
-- means the only window-already-there case that reaches here is a fresh set
-- landing in a window the human left open, and putting them back in it is
-- exactly right. set_compose merely declines to stack a second split; this one
-- also moves the cursor, because a document that appears off-screen reads as
-- nothing having happened.
--
-- b:lain_question_digest is the set's CONTENT digest, not a counter: it stamps
-- the buffer, rides back with every write and abandon, and is what lets a write
-- naming a set nobody holds be dropped rather than reinterpreted against
-- whatever is open now.
-- b:lain_question_rendered is the OTHER half of the untouched-write refusal
-- (see question_buf): the bytes lain wrote, kept so the write can tell "the
-- human decided to answer nothing" from "nobody has touched this yet". Stamped
-- here rather than recovered later, because by the time `:w` fires the buffer
-- is the only copy of anything and it is the copy under suspicion.
--
-- The cursor lands on line 1, which open_at_rest has just made the OPEN
-- question: a form starts at the top, and being dropped inside a closed fold
-- is how a `dd` eats a question the human never read.
function _G.__lain.set_question(name, lines, digest)
  local buf = question_buf(name)
  vim.b[buf].lain_question_digest = digest
  vim.b[buf].lain_question_rendered = lines
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  local win = vim.fn.win_findbuf(buf)[1]
  if win == nil then
    win = vim.api.nvim_open_win(buf, true, { split = "below", win = 0 })
  else
    vim.api.nvim_set_current_win(win)
  end
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  announce_render(name, buf)
end

-- The annotation TEXT for every extmark, per review buffer: `buf -> id -> text`
-- (T16). The extmark itself carries only the position -- nvim moves it as the
-- human edits, which is the whole reason to use one -- so the words live here,
-- keyed by the id nvim answers with. The two are written together and MUST be
-- cleared together: a stale entry, or a mark whose text is gone, produces an
-- annotation with a missing key on the wire, and the Ruby side reads it as a
-- malformed review rather than as the bookkeeping slip it is.
local review_annotations = {}

-- Open a real file on disk for review (T16), in a focused split -- the same
-- deliberate focus-taking as set_compose, and for the same reason: lain is
-- handing the human something and asking them to work on it. The stamps are
-- what the `done` gesture sends back: `(generation, epic_slug)` is the review's
-- whole identity, because generations are drawn per epic and a bare number
-- cannot say which review it means.
--
-- The namespace is CLEARED, not just created: nvim answers with the same
-- namespace id for a name it already knows, so a second review of one file
-- would otherwise inherit the first review's extmarks while `review_annotations`
-- starts empty -- marks with no text, which is exactly the malformed-annotation
-- shape above.
function _G.__lain.open_review(path, generation, epic_slug)
  vim.cmd("belowright split " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  local namespace = vim.api.nvim_create_namespace("lain_review_annotations")
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  vim.b[buf].lain_annotation_namespace = namespace
  review_annotations[buf] = {}
  vim.b[buf].lain_review_generation = generation
  vim.b[buf].lain_review_epic_slug = epic_slug
end

-- A `done` the Ruby side could not honour -- a generation it does not hold, a
-- file that moved, an annotation it could not read. Echoed rather than silent
-- because the human made a deliberate gesture and is owed an answer to it.
function _G.__lain.review_refused(message)
  vim.api.nvim_echo({ { "lain: " .. tostring(message), "WarningMsg" } }, true, {})
end

-- Buffer numbers are REUSED once nvim frees them, so annotation text left
-- behind here would eventually be read as some later buffer's. Cleared on
-- unload, where the extmarks die anyway.
vim.api.nvim_create_autocmd("BufUnload", {
  group = vim.api.nvim_create_augroup("lain_review", { clear = true }),
  callback = function(ev) review_annotations[ev.buf] = nil end,
})

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
-- A note against the line the cursor is on (T16). The text is shown as virtual
-- text and remembered beside the extmark that holds its position, so it travels
-- with the line as the human keeps editing. The cursor row is 1-based and
-- extmarks are 0-based, which is the whole of the arithmetic here.
--
-- vim.ui.input is asynchronous under the dressing plugins that replace it
-- (dressing.nvim, noice, telescope), so the callback may run long after this
-- command returns. That is fine BECAUSE nothing here is sent: the note lands in
-- the buffer's own table and only :LainReviewDone puts anything on the wire.
define("LainAnnotate", function()
  local buf = vim.api.nvim_get_current_buf()
  local namespace = vim.b[buf].lain_annotation_namespace
  if namespace == nil then error("lain: :LainAnnotate needs an open lain review", 0) end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  vim.ui.input({ prompt = "Annotation: " }, function(text)
    if text and text ~= "" then
      local id = vim.api.nvim_buf_set_extmark(buf, namespace, row, 0, { virt_text = { { text, "Comment" } } })
      review_annotations[buf] = review_annotations[buf] or {}
      review_annotations[buf][id] = text
    end
  end)
end)

-- Hand the review back (T16). The command refuses rather than sending on a
-- modified buffer: the Ruby side settles from what is ON DISK, so unsaved edits
-- would be a review of bytes nobody has.
--
-- ONE argument after the verb, and it is an ARRAY. Every verb on this rail is
-- destructured Ruby-side as `verb, args`, so flat positionals arrive as the
-- generation alone and the rest is dropped on the floor -- which is what
-- happened: every done gesture was refused as "not open" and the annotations
-- were never even looked at.
--
-- Each annotation is a table with STRING keys, which is what a lua map becomes
-- on the other side of msgpack, and every key is always present: a mark whose
-- text has gone missing is SKIPPED, because a nil value drops its key from a
-- lua table entirely and the Ruby side would read the hole as a malformed
-- review rather than as a note that was never written.
define("LainReviewDone", function()
  local buf = vim.api.nvim_get_current_buf()
  local generation = vim.b[buf].lain_review_generation
  local epic_slug = vim.b[buf].lain_review_epic_slug
  if generation == nil or epic_slug == nil then
    error("lain: :LainReviewDone needs an open lain review", 0)
  end
  if vim.bo[buf].modified then
    error("lain: save the review before marking it done", 0)
  end
  local marks = vim.api.nvim_buf_get_extmarks(buf, vim.b[buf].lain_annotation_namespace or -1, 0, -1, {})
  local annotations = review_annotations[buf] or {}
  local payload = {}
  for _, mark in ipairs(marks) do
    local line, text = mark[2], annotations[mark[1]]
    if text then
      table.insert(payload, {
        line = line + 1,
        text = text,
        anchor_text = vim.api.nvim_buf_get_lines(buf, line, line + 1, false)[1] or "",
      })
    end
  end
  vim.rpcrequest(chan, "lain_command", "review_done", { generation, epic_slug, payload })
end)

-- The compose round trip's return leg (T15). No :Lain* command here on
-- purpose: the human's gesture is `:w`, the one thing every vim user already
-- knows means "I am done with this text", and lain://compose is `acwrite`
-- exactly so that gesture can be intercepted. Both callbacks are ordinary
-- enqueue-and-ack rpcREQUESTS -- the same path :LainResend takes -- so the
-- Ruby side answers in microseconds and nothing new reads the RPC session.
-- Cleared augroup, like every lain augroup, so re-attach redefines rather
-- than stacks (a stacked BufWriteCmd would report one write twice).
--
-- BufWriteCmd REPLACES the write: nothing is persisted anywhere, and clearing
-- 'modified' is what tells nvim the write succeeded. That is the whole point
-- -- the "file" is the prompt.
--
-- ORDER IS THE CORRECTNESS HERE. The rpcrequest goes FIRST and 'modified' is
-- cleared only once it returns. Clearing first meant a write that never
-- reached lain -- the Ruby end torn down, "Invalid channel" -- still left the
-- buffer looking saved, so nvim would not warn on `:q` and the human's text
-- was simply gone. Now a failed write leaves the buffer dirty, exactly as a
-- failed `:w` to a real file would, and says so.
local compose_group = vim.api.nvim_create_augroup("lain_compose", { clear = true })
vim.api.nvim_create_autocmd("BufWriteCmd", {
  group = compose_group,
  pattern = COMPOSE,
  callback = function(ev)
    local lines = vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false)
    local ok, err = pcall(vim.rpcrequest, chan, "lain_command", "compose", lines,
      vim.b[ev.buf].lain_compose_generation)
    if not ok then
      -- Re-raised, not merely notified: a `:w` whose text reached nobody must
      -- FAIL as a write. Erroring here is what leaves 'modified' set, so the
      -- buffer keeps saying it holds unsaved text and nvim refuses to DISCARD
      -- it -- `:bdelete`/`:bwipeout` answer E89, and a last-window quit is
      -- refused. Note plain `:q` still succeeds: bufhidden = "hide" hides the
      -- buffer rather than abandoning it, so quitting a window is not a
      -- discard and nvim has nothing to object to.
      error("lain: compose could not reach lain, buffer NOT saved: " .. tostring(err), 0)
    end
    vim.bo[ev.buf].modified = false
  end,
})

-- BufUnload is the ABANDON signal: :bdelete/:bwipeout, or quitting nvim.
-- pcall'd because one of those cases is nvim EXITING, where the Ruby end may
-- already have torn its RPC thread down -- an unanswered rpcrequest would
-- then surface as an autocmd error in the human's face on the way out, over a
-- notice whose only reader has gone. The prompt is not stranded by the loss:
-- Compose's own bound covers exactly this.
vim.api.nvim_create_autocmd("BufUnload", {
  group = compose_group,
  pattern = COMPOSE,
  callback = function(ev)
    pcall(vim.rpcrequest, chan, "lain_command", "compose_abandon", vim.b[ev.buf].lain_compose_generation)
  end,
})

-- The question round trip's return leg (T12). Same gesture as compose -- `:w`
-- is "I am done with this text" -- and the same order, rpcrequest FIRST and
-- 'modified' cleared only once it returns.
--
-- What is NOT the same, and is the whole reason this buffer exists: this write
-- can be REFUSED. Ruby parses the document synchronously inside this request,
-- so a line the grammar has no slot for comes back as the request's ERROR
-- rather than as an ack, and erroring here leaves the buffer modified with the
-- human's own text for them to go fix. Nothing re-renders over it. The two
-- failures therefore share one path on purpose: "the grammar refused line 6"
-- and "lain was not there" are both a `:w` that did not save, and the message
-- carries which one it was.
--
-- The message rides the ERROR rather than an nvim_echo, and that is a choice
-- worth recording: nvim 0.12 appends a lua stack traceback under it (naming a
-- byte offset in an injected string, which is noise no human can act on), and
-- `error(msg, 0)` does not suppress that. The dodge -- echo the sentence, then
-- `error("", 0)` -- would move the one thing a human needs off the failure and
-- into `:messages`, where a scripted `:w` and a pcall cannot see it at all. The
-- sentence belongs to the write that failed.
local question_group = vim.api.nvim_create_augroup("lain_question", { clear = true })

-- The write nobody typed. `vim.v.cmdbang` is what `:w!` sets, and it is the
-- override: declining every question stays possible and stays CHOSEN.
local UNTOUCHED = "lain: nothing in this buffer has been typed, and a plain :w would answer every question as " ..
  "unanswered -- which is a decision, not a default. Answer something, or use :w! to submit it as it stands."

local function untouched(buf, lines)
  return vim.v.cmdbang == 0 and vim.deep_equal(lines, vim.b[buf].lain_question_rendered)
end

vim.api.nvim_create_autocmd("BufWriteCmd", {
  group = question_group,
  pattern = QUESTION,
  callback = function(ev)
    local lines = vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false)
    if untouched(ev.buf, lines) then
      error(UNTOUCHED, 0)
    end
    local ok, err = pcall(vim.rpcrequest, chan, "lain_command", "question", lines,
      vim.b[ev.buf].lain_question_digest)
    if not ok then
      error("lain: question NOT saved: " .. tostring(err), 0)
    end
    vim.bo[ev.buf].modified = false
  end,
})

-- BufUnload is the ABANDON signal, pcall'd for the compose leg's reason: one of
-- these cases is nvim EXITING, where Ruby may already have torn the RPC thread
-- down and an unanswered rpcrequest would surface as an autocmd error in the
-- human's face on the way out. Nothing is stranded by the loss -- no fiber
-- waits on a question, and the set stays pending in the inbox either way.
--
-- WHICH GESTURES UNLOAD, measured: `:bd!`, `:bw!`, `:q!` in the question
-- window, and quitting nvim all do, and each abandons carrying the digest.
-- `:close`, `:enew` and nvim_win_close do NOT -- `bufhidden = "hide"` means the
-- buffer survives being looked away from, which is the point, so the set stays
-- open with no window showing it. That is not a leak: QuestionView answers the
-- NEXT set with OCCUPIED naming this buffer, so `:buffer lain://question` is
-- always the way back.
vim.api.nvim_create_autocmd("BufUnload", {
  group = question_group,
  pattern = QUESTION,
  callback = function(ev)
    pcall(vim.rpcrequest, chan, "lain_command", "question_abandon", vim.b[ev.buf].lain_question_digest)
  end,
})

-- Ticking a box (T13), and it sends NOTHING: the human ticks, writes, and `:w`
-- once. What makes a local keymap possible at all is that the ARITY RIDES IN
-- THE HEADING, so a question's boundary and whether it takes one tick or many
-- are recoverable from buffer TEXT -- no rpcrequest, no state kept beside the
-- buffer. This is spec/lain/question/document_spec.rb's own buffer-only `scan`
-- ported: bounds from the nearest heading at or above the line to the next
-- heading below it, then the option lines inside them.
--
-- The two marks Question::Document::SELECTION_MARKS writes, and nothing else.
-- A mangled mark ("[?]") is deliberately NOT an option line here either: `x`
-- falls through to vim's own, which deletes the offending character -- the
-- grammar refuses that mark by name on `:w`, so the fall-through is the fix.
local QUESTION_TICKS = { [" "] = "x", ["x"] = " " }
local QUESTION_OPTION = "^%- %[([x ])%] `[^`]+` "

-- The mark's byte offset in "- [x] `id` label", 0-based for nvim_buf_set_text.
-- Writing the ONE byte rather than the line is what keeps every other byte of
-- the human's document -- and their cursor column, and any extmark on the line
-- -- exactly where it was.
local QUESTION_MARK_COLUMN = 3

local function option_mark(line)
  return line ~= nil and line:match(QUESTION_OPTION) or nil
end

-- The question the line at `row` belongs to: the row of its heading, and the
-- last row before the next question's. A body CANNOT forge either boundary --
-- Question::DOCUMENT_HEADING refuses a heading-shaped body line where the body
-- is BUILT -- which is why scanning to the nearest heading is safe.
local function question_bounds(lines, row)
  local heading = row
  while heading >= 1 and question_heading(lines[heading]) == nil do
    heading = heading - 1
  end
  if heading < 1 then
    return nil
  end
  local last = row
  while last < #lines and question_heading(lines[last + 1]) == nil do
    last = last + 1
  end
  return heading, last
end

-- The question's OPTION BLOCK: the LAST run of option lines between `first`
-- and `last`. That "last" is the whole defence against a body that shows the
-- grammar. A body is written verbatim and may legally hold a line matching
-- OPTION (a fenced diff showing `- [x] no` is the documented case), but the
-- renderer emits the options as one unbroken run preceded by a blank line, and
-- the comment beneath them is INDENTED -- so nothing below the block wears this
-- shape at column 0, and a body's option-shaped line is always separated from
-- the block by at least that blank. nil when the question has no run at all.
local function option_block(lines, first, last)
  local stop = last
  while stop > first and option_mark(lines[stop]) == nil do
    stop = stop - 1
  end
  if option_mark(lines[stop]) == nil then
    return nil
  end
  local start = stop
  while start > first and option_mark(lines[start - 1]) ~= nil do
    start = start - 1
  end
  return start, stop
end

-- What `x` would write, given where the cursor is: the option under it, and --
-- for a single-select question being TICKED -- the siblings whose ticks it
-- clears. nil for every other line, which is the fall-through to vim's own `x`.
local function tick_targets(lines, row)
  local mark = option_mark(lines[row])
  local heading, ends = question_bounds(lines, row)
  if mark == nil or heading == nil then
    return nil
  end
  local arity = question_heading(lines[heading])
  -- A free-text question offers nothing to tick, so the only option-shaped
  -- line under its heading is one its body showed -- the case the last-run rule
  -- above cannot see, because that run IS the last one.
  if arity == QUESTION_NONE then
    return nil
  end
  local first, last = option_block(lines, heading, ends)
  if first == nil or row < first or row > last then
    return nil
  end

  local writes = { { row = row, mark = QUESTION_TICKS[mark] } }
  if arity == QUESTION_ONE and mark == " " then
    for sibling = first, last do
      if sibling ~= row and option_mark(lines[sibling]) == "x" then
        table.insert(writes, { row = sibling, mark = " " })
      end
    end
  end
  return writes
end

-- The tick itself, reachable as an 'operatorfunc' (hence global, hence on the
-- __lain table -- it is NOT a render entry point and nothing about it crosses
-- the RPC rail, so it is no part of the protocol). It re-decides from the
-- buffer rather than trusting the map that scheduled it, because `.` replays
-- `g@l` DIRECTLY: the map does not run again, so this is the only guard a
-- repeat passes through. A repeat over a line with nothing to tick therefore
-- does nothing, which is what repeating "tick this" means -- notably NOT vim's
-- `x`, which would make `.` destructive on the human's prose.
--
-- The count and the register are dropped on this path, deliberately: `3x` ticks
-- once (an operator invocation is one call, whatever region `3l` covered) and
-- `"ax` yanks nothing, because a tick is not a delete and there is nothing for
-- a register to hold. Both are carried in full on the fall-through below.
function _G.__lain.tick()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local writes = tick_targets(cached_lines(buf), row)
  if writes ~= nil then
    for _, write in ipairs(writes) do
      vim.api.nvim_buf_set_text(buf, write.row - 1, QUESTION_MARK_COLUMN,
        write.row - 1, QUESTION_MARK_COLUMN + 1, { write.mark })
    end
  end
end

-- Ruling 11, and the half that is not optional: lain://question is `acwrite`
-- and the human types PROSE into it, so `x` off an option line must be vim's
-- `x`. (`p` in lain://timeline could be shadowed outright because a
-- NOMODIFIABLE buffer has no use for paste; this buffer is the opposite case.)
--
-- AN EXPR MAP, AND `g@` -- because of `.`, which is the most reflexive key a
-- vim user has. Both branches are dot-repeatable only in this shape:
--
--   returning "x" is not an imitation of vim's `x`, it IS vim's `x`. v:count
--   and v:register are still PENDING when a mapping fires and are applied to
--   the returned keys, so `"a3x` needs nothing reconstructed, and `.` repeats
--   the real thing because vim recorded the real thing.
--
--   "g@l" runs 'operatorfunc' over one character, and `g@` is dot-repeatable BY
--   CONSTRUCTION. A bare buffer write is not: it leaves no redo entry, so `.`
--   after a tick replayed whatever real change came before it -- the panel
--   caught a raw `x` from an earlier line eating a ticked option's "- ".
--
-- The write CANNOT happen here: an expr callback runs under textlock, where
-- nvim_buf_set_text answers E565. Reads and an option write are fine, which is
-- exactly what this branch does -- the buffer write is the operator function's,
-- and an operator function is not under textlock. That is the whole reason for
-- the indirection, and it is nvim's standard idiom for it.
--
-- cached_lines rather than a fresh read: every tick bumps changedtick, so this
-- does NOT skip the read on a run of ticks -- what it buys is one read per
-- keystroke shared with the foldexpr's own re-evaluation, which in a real
-- (non-headless) editor re-warms the cache between keystrokes anyway.
local function tick_or_delete()
  local buf = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  if tick_targets(cached_lines(buf), row) == nil then
    return "x"
  end
  vim.go.operatorfunc = "v:lua.__lain.tick"
  return "g@l"
end

-- Buffer-local, bound from a BufEnter in the question's own cleared augroup --
-- the inbox reply keys' shape, and for their reason: the buffer is created by a
-- gesture rather than at attach. A GLOBAL `x` would break deleting a character
-- in every other buffer the human has open. The desc names BOTH halves: on most
-- lines of this buffer the map is vim's `x`, and `:map x` saying only "tick"
-- would tell the human the wrong thing about the line they are on.
vim.api.nvim_create_autocmd("BufEnter", {
  group = question_group,
  pattern = QUESTION,
  callback = function(ev)
    vim.keymap.set("n", "x", tick_or_delete,
      { buffer = ev.buf, expr = true, desc = "lain: tick the option under the cursor, else vim's x" })
  end,
})

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

-- The cursor-on-a-turn pin gesture (B4): `p` in lain://timeline pins the turn
-- the cursor sits on -- "compaction may not elide this one". Mirrors the inbox
-- drain above in every respect that matters: the KEY invokes the COMMAND, so
-- the mapping and a hand-typed :LainPin are provably one path; the command is
-- enqueue-and-ack like every other; and the map is buffer-local, bound from a
-- cleared-augroup BufEnter (not at buffer creation) because `named_buf` returns
-- early for a buffer an earlier attach already made, which would leave a
-- surviving lain://timeline unbound after a re-attach.
--
-- The LINE rides as the argument, never a digest: lain://timeline is one turn
-- per line and renders no digest on it (Buffers#turn_line), so the Ruby side's
-- own line -> digest index is the only thing that can name the turn -- and that
-- index is built by the same pass that produced the lines, so it cannot
-- disagree with what the human is looking at.
--
-- `p` shadows normal-mode paste, which a nomodifiable buffer has no use for.
-- <Cmd> rather than ":": it runs the command without leaving normal mode, so
-- the cursor the command is about does not move out from under it.
-- The buffer check is NOT redundant with the buffer-local map. `define` makes
-- every :Lain* command GLOBAL, and this one reads the CURRENT window's cursor
-- -- so hand-typed from lain://journal line 7 it would send ["pin", [7]] and
-- pin TIMELINE turn 7, a turn the human never looked at, silently and (once
-- pins outlive the session) permanently. Hand-typing is an INVITED path here
-- precisely because the map invokes the command, so the command has to hold
-- the invariant itself. :LainResend has no such hazard -- it looks its buffer
-- up BY NAME rather than reading whatever window happens to be current.
define("LainPin", function()
  if vim.api.nvim_buf_get_name(0) ~= TIMELINE then
    vim.notify("lain: :LainPin pins the turn under the cursor in " .. TIMELINE, vim.log.levels.WARN)
    return
  end
  vim.rpcrequest(chan, "lain_command", "pin", { vim.api.nvim_win_get_cursor(0)[1] })
end)

local pin_group = vim.api.nvim_create_augroup("lain_pin", { clear = true })
vim.api.nvim_create_autocmd("BufEnter", {
  group = pin_group,
  pattern = TIMELINE,
  callback = function(ev)
    vim.keymap.set("n", "p", "<Cmd>LainPin<CR>", { buffer = ev.buf, desc = "lain: pin the turn under the cursor" })
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
