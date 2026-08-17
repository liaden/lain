-- One changed file, drawn into the review's two diff slots (T15): the REAL file
-- on the new side, `git show <base>:<path>` on the old, both in nvim's native
-- diff mode. This is the surface a review is actually read on, and native diff
-- is the whole design -- folds, `]c`, `do`/`dp` and the human's own colorscheme
-- all come for free, and none of them would if this rendered a unified diff into
-- a scratch buffer.
--
-- THE NEW SIDE IS THE FILE, not a copy of it. `buftype = ""` is what makes the
-- language server and treesitter attach, so the human reads the code they are
-- reviewing with the tools they read code with. A `nofile` copy would present
-- identically in every other respect and silently lose all of it.
--
-- THE OLD SIDE CANNOT BE A FILE -- that revision is not on disk -- so it is a
-- `nofile` scratch buffer named `lain://review/OLD/<path>`, which is how a
-- gesture recovers the side AND the path it came from. Its filetype and
-- 'fileformat' are set BY HAND from the new side's, because a `lain://` name has
-- nothing to sniff and both halves of a diff have to be presented the same way
-- to be comparable at all (see `as_shown` for the CRLF half of that).
--
-- THESE BUFFERS CARRY EXTMARKS -- T16's notes, T17's diagnostics and T18's
-- threads all anchor in them -- so the two rules that protect a mark are stated
-- once, here, and enforced below:
--
--   1. The old side is REFILLED IN PLACE, never wholesale (`refill`). A
--      whole-buffer replace moves every mark in the buffer to its end.
--   2. A buffer that leaves the review is UNSTAMPED (`unstamp`), so nothing
--      downstream mistakes a file the human has moved on from for the one under
--      review.
--
-- NOTHING HERE IS ASYNCHRONOUS, and that is a rule rather than an accident.
-- [diffview#466] is `E5560 nvim_buf_is_valid must not be called in a lua loop
-- callback`: an nvim API call reached from a libuv callback needs
-- `vim.schedule`, and getting that wrong CRASHES the editor instead of failing a
-- spec. Every call below is reached from `nvim_exec_lua` on the main loop, where
-- E5560 cannot arise -- which holds only while this module shells out to
-- nothing, starts no timer and never yields. Ruby runs git and sends `old_lines`
-- already read, so there is no reason for it to. It also means `open_changeset`
-- cannot be interrupted part-way: no redraw lands between the first buffer
-- arriving and the last, which is what makes "the human never sees a half-built
-- pair" true rather than hoped for.
--
-- 47, after 41_layout (the slots it renders through) and 20_buffers (`named_buf`
-- and `set_lines`, which it builds the old side with). ONE new top-level name,
-- as 41_layout takes one, because the chunk shares a scope.
local review_diff = {
  OLD_PREFIX = "lain://review/OLD/",

  -- The project root, captured AT ATTACH and never re-read. Paths arrive
  -- repository-relative, and resolving them against the editor's CURRENT
  -- directory is wrong in a way that costs data: `:cd`, `:lcd`, `:tcd`,
  -- 'autochdir' and every rooter plugin move it, and after a `:cd docs` the path
  -- `docs/guide.txt` resolves to `docs/docs/guide.txt` -- a buffer for a file
  -- that does not exist, empty, and still `buftype = ""`, so the human's `:w`
  -- CREATES it. Freezing the root at attach makes every one of those a no-op,
  -- and `new_side` closes the `:w` half for whatever still resolves to no file.
  --
  -- `getcwd(-1, -1)` is the GLOBAL cwd specifically, the same call and the same
  -- reasoning as `plugin/nvim/lua/lain/init.lua`'s `project_cwd`: a `:lcd` in
  -- one window must not fork the project. This is the editor lain attached to,
  -- and that socket's identity is already derived from this same directory.
  ROOT = vim.fn.getcwd(-1, -1),
}

-- `vim.g.lain_review_root` overrides it, the same opt-out shape as
-- vim.g.lain_fold and vim.g.lain_review_sidebar_width -- for an editor started
-- somewhere other than the repository it is reviewing.
function review_diff.absolute(path)
  return vim.fn.fnamemodify((vim.g.lain_review_root or review_diff.ROOT) .. "/" .. path, ":p")
end

-- The path must be repository-relative, and an absolute one is REFUSED rather
-- than quietly accommodated: the old side's buffer name embeds it verbatim, so
-- `/abs/path` spells `lain://review/OLD//abs/path` -- a doubled separator, and a
-- name outside the contract T16 reads the side and the path back out of.
-- Refusing also says which end is wrong; everything Ruby-side already keys on
-- the relative path it sent.
function review_diff.relative_path(path)
  if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/" then
    error("lain: open_changeset needs a repository-relative path, not " .. tostring(path) ..
      " -- the old side's name embeds it, and an absolute one falls outside lain://review/OLD/", 0)
  end
  return path
end

-- Only Ruby knows which two commits this diff is between, so a missing one is a
-- render that cannot be repaired here -- and T16 would journal every note on it
-- anchored to nothing, which reads as a note about no diff at all rather than as
-- the wiring slip it is. Refused by NAME, `review_place`'s shape one module down.
function review_diff.revision_for(revisions, side)
  local revision = type(revisions) == "table" and revisions[side] or nil
  if type(revision) ~= "string" or revision == "" then
    error("lain: open_changeset needs a revision for the " .. side ..
      " side -- a note anchored to no revision names no diff", 0)
  end
  return revision
end

-- Every line, checked BEFORE anything is created. `nvim_buf_set_lines` raises on
-- a string containing a newline, and it would raise having already made two
-- buffers and a tabpage -- the half-drawn review this function's argument check
-- exists to prevent.
--
-- The `type(...) ~= "table"` test is doing real work: a Ruby `nil` crosses
-- msgpack as `vim.NIL`, which is USERDATA and therefore truthy, so the
-- `old_lines or {}` a reader would write here is dead code that passes userdata
-- straight to the API.
function review_diff.checked_lines(old_lines)
  if type(old_lines) ~= "table" then
    return {}
  end
  for i, line in ipairs(old_lines) do
    if type(line) ~= "string" or line:find("\n", 1, true) then
      error("lain: open_changeset old_lines[" .. i .. "] is not a single line -- " ..
        "the old side is one buffer line per line git showed", 0)
    end
  end
  return old_lines
end

-- The old side as the NEW side is displayed, which for a CRLF file means without
-- the carriage returns. nvim strips them from a 'fileformat=dos' buffer, and git
-- hands them over, so left unstripped every single line differs from its twin:
-- the diff reports the whole file changed and `foldmethod=diff` folds nothing,
-- which is the expand-context affordance simply gone.
--
-- This is the editor-side counterpart of T7's ruling that the diff wins and
-- `Anchor` yields. A file whose line endings the changeset actually CONVERTED is
-- the case this deliberately does not hide: the new side is then `unix`, nothing
-- is stripped, and the stray CRs render as `^M` exactly as vim renders them in
-- any unix file -- which is the honest picture of that change.
function review_diff.as_shown(lines, fileformat)
  if fileformat ~= "dos" then
    return lines
  end
  local shown = {}
  for i, line in ipairs(lines) do
    shown[i] = line:sub(-1) == "\r" and line:sub(1, -2) or line
  end
  return shown
end

-- `bufadd` + `bufload` rather than `:edit`, and that pair IS the fix for
-- [diffview#509] (the previously focused buffer flashing in both diff windows):
-- it produces a fully loaded buffer -- contents read, filetype and 'fileformat'
-- detected -- with no window involved at all, so the buffer exists BEFORE
-- anything shows it. Any `split <path>` form has to make the window first, and a
-- window is born holding whatever the current buffer is.
--
-- `buflisted` because `bufadd` answers an UNLISTED buffer while `:edit` answers
-- a listed one: unlisted would hide the file the human is reviewing from `:ls`,
-- `:bnext` and every buffer picker they own.
--
-- WHERE THERE IS NO FILE THERE IS NO WAY TO WRITE ONE. `buftype = ""` is what
-- makes the language server attach AND what makes a `:w` here CREATE the path
-- the buffer names, and two ordinary things arrive with no file behind them: a
-- review of a DELETED file, whose new side is a working copy that no longer
-- exists, and any path this editor resolves differently than the sender meant
-- (the hazard the frozen ROOT above is written against). Either way the human
-- gets an empty writable buffer, and one absent-minded `:w` turns a review into
-- a write -- resurrecting a deletion as an empty file, or scattering files
-- under whatever directory the resolution landed in.
--
-- `nowrite` answers `:w` AND `:w!` with the editor's own E382 (measured), which
-- is the same refusal the old side's `nofile` already gives. Set on BOTH
-- branches, as the buffer's resting state rather than as a one-way flip: a
-- buffer is found by name and reused, so one built for a file that has since
-- appeared must stop refusing, and one for a file that has since gone must
-- start. `:saveas` is the exit neither option closes; `withdraw` below does.
--
-- `filereadable` is a READ test and not an existence one, so a mode-000 file
-- and a directory both take the refusing branch. That is the safe direction --
-- neither is a file this review can write -- but the human sees an empty
-- buffer where the truth is "there and unreadable", and nothing here says so.
--
-- `nofile` was weighed and NOT taken, though it stops one more thing: measured,
-- it also refuses `:saveas`, where `nowrite` exports. Two reasons for the
-- narrower option. `nowrite` leaves the buffer a real file buffer, and every
-- plugin that branches on `buftype == "nofile"` treats one as scratch -- a
-- claim that is false of a file which is merely absent. And `:saveas <target>`
-- is a human naming a destination on purpose, which is a reasonable way to
-- start the file a review says is missing; the half that CORRUPTS a review is
-- the stamp surviving the rename, and `withdraw` below closes that instead.
function review_diff.new_side(path)
  local absolute = review_diff.absolute(path)
  local buf = vim.fn.bufadd(absolute)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  vim.bo[buf].buftype = vim.fn.filereadable(absolute) == 1 and "" or "nowrite"
  return buf
end

-- The old side's buffer, VERIFIED to be the one this path names.
--
-- `named_buf` finds an existing buffer with `vim.fn.bufnr(name)`, and that
-- argument is a PATTERN, not a literal. Measured, because the behaviour is
-- narrower than "it is a pattern" suggests: an exact match wins while it is the
-- only candidate, but as soon as another buffer ALSO matches the pattern, that
-- other buffer wins -- so reviewing `weird/a1.rb` and then `weird/a[1].rb` hands
-- back a1's buffer, and the second file's content would be written into the
-- first file's review under a name saying otherwise. `[slug].tsx` routes make
-- such paths ordinary, and this module is `bufnr`'s first caller passing a path
-- a human chose.
--
-- Checking the NAME of what came back is the whole fix, and a scan of the buffer
-- list before it would be dead code: any misfire lands here, and `drop_stale`
-- keeps at most one old-side buffer alive, so the case where a scan would find
-- something `bufnr` missed cannot arise. Building the buffer here rather than
-- through `named_buf` happens only on the path where `named_buf` is WRONG.
function review_diff.old_buffer(path)
  local name = review_diff.OLD_PREFIX .. path
  local found = named_buf(name)
  if vim.api.nvim_buf_get_name(found) == name then
    return found
  end

  -- Every option here is the buffer's RESTING state and has to be established by
  -- the constructor, `modifiable` most of all: `refill` restores it after a
  -- write but may not write at all -- an empty old side (a file the changeset
  -- ADDS) is already what a fresh buffer holds, so it takes the early return.
  -- Left out, that buffer stays modifiable and the human can edit history.
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.b[buf].lain_view = name
  return buf
end

-- Write only what actually CHANGED, never the whole buffer.
--
-- This is the rule that protects every mark T16, T17 and T18 will place here. A
-- whole-buffer `set_lines(buf, 0, -1, …)` moves every extmark in the buffer to
-- its end -- measured: a mark at row 19 reports row 40 after a refill of a
-- 40-line file -- and re-opening the file you are already reading is a supported
-- gesture, so a human's notes would silently pile up at the bottom of the buffer
-- the moment they came back to a file.
--
-- Identical content takes the early return and writes NOTHING AT ALL, which is
-- the re-open case and the common one. The early return is not merely tidier
-- than falling through: the fall-through is a zero-length `set_lines` at the
-- buffer end, and that still BUMPS 'changedtick' and fires `on_lines` -- so a
-- re-open of an unchanged file would announce a change to exactly the listeners
-- T16's drift detection is built on. Writing nothing means telling nobody.
--
-- When the content genuinely differs (the base moved under a re-review) only the
-- differing span is rewritten, so marks outside it keep their rows and marks
-- inside it move -- which is drift, and drift is T16's to report rather than
-- this module's to hide.
--
-- The shared-prefix half is `set_view`'s idiom (45_views); the shared-SUFFIX
-- half is this one's own, because a diff's changed span is as often in the
-- middle as at the end.
function review_diff.refill(buf, lines)
  local held = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local first = 0
  while first < #held and first < #lines and held[first + 1] == lines[first + 1] do
    first = first + 1
  end
  if first == #held and first == #lines then
    return
  end

  local last = 0
  while last < #held - first and last < #lines - first and held[#held - last] == lines[#lines - last] do
    last = last + 1
  end
  set_lines(buf, first, #held - last, vim.list_slice(lines, first + 1, #lines - last))
end

-- `named_buf`'s resting shape -- nofile, no swapfile, nomodifiable, found by
-- name so re-opening one file reuses its buffer -- and nomodifiable is the one
-- that matters most: the old side is history, and `:w` fails on it with the
-- editor's own E382 rather than with anything this module has to remember to do.
-- 'fileformat' is a change to the BUFFER rather than a display option, so nvim
-- refuses it with E21 while the buffer is nomodifiable -- the same flip
-- `set_lines` makes around a write, and skipped entirely when it already agrees.
function review_diff.old_side(path, lines, filetype, fileformat)
  local buf = review_diff.old_buffer(path)
  review_diff.refill(buf, review_diff.as_shown(lines, fileformat))
  vim.bo[buf].filetype = filetype
  if vim.bo[buf].fileformat ~= fileformat then
    vim.bo[buf].modifiable = true
    vim.bo[buf].fileformat = fileformat
    vim.bo[buf].modifiable = false
  end
  return buf
end

-- Which side, which commit that side is, and which file -- the three facts T16
-- needs off the buffer a note was placed in. The side decides whether a line is
-- an old-side or a new-side anchor, and the revision is what makes the anchor
-- mean anything a year later.
--
-- The PATH is stamped even though the old side's buffer NAME already ends in it,
-- because the alternative is T16 parsing a URI back apart to recover it -- and
-- that parser would be a second, silent spelling of `OLD_PREFIX` with nothing
-- pinning it to this one. The new side could not answer it anyway: its name is
-- the ABSOLUTE path the editor resolved, while everything Ruby-side keys on the
-- repository-relative path it sent. One variable, both sides, no string surgery.
function review_diff.stamp(buf, side, revision, path)
  vim.b[buf].lain_review_side = side
  vim.b[buf].lain_review_revision = revision
  vim.b[buf].lain_review_path = path
end

-- A stamp is a claim that this buffer IS the review, so it has to be withdrawn
-- when it stops being true. The new side is a real file buffer: it is not wiped
-- when the human moves to the next file, it stays listed, and it outlives the
-- review entirely -- so a stamp left on it tells T16 and T17 to anchor a note
-- into a file nobody is reviewing any more, which is a wrong answer rather than
-- a missing one.
--
-- Derived from the live buffer list, like `drop_stale`, so there is no registry
-- to go stale.
function review_diff.unstamp(old_buf, new_buf)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= old_buf and buf ~= new_buf then
      review_diff.withdraw(buf)
    end
  end
end

-- The three stamps, dropped together. One expression, because a stamp read
-- without its revision is a note anchored to no diff -- the same reason
-- `open_changeset` refuses a missing revision before it builds anything.
function review_diff.withdraw(buf)
  if vim.b[buf].lain_review_side ~= nil then
    vim.b[buf].lain_review_side = nil
    vim.b[buf].lain_review_revision = nil
    vim.b[buf].lain_review_path = nil
  end
end

-- The OTHER way a buffer leaves the review, and the one `unstamp` cannot see:
-- `:saveas` renames a buffer in place. It succeeds even here -- measured, with
-- 'buftype' nowrite AND nomodifiable, both of which stop `:w` and neither of
-- which stops a rename -- so the buffer would go on carrying
-- `lain_review_path` while naming a different file, and T16 would anchor a note
-- into it. Withdrawing the stamp says what is true: this is no longer the file
-- under review.
--
-- `BufFilePost` fires after the rename, on the main loop (no `vim.schedule`
-- needed -- see this module's header on E5560), in a CLEARED augroup, which is
-- every lain autocmd's convention and what makes a re-attach idempotent.
vim.api.nvim_create_autocmd("BufFilePost", {
  group = vim.api.nvim_create_augroup("lain_review_diff", { clear = true }),
  callback = function(event) review_diff.withdraw(event.buf) end,
})

-- The old side is per-FILE, so the previous file's buffer is wiped rather than
-- left hidden -- otherwise a review of a real changeset ends with one dead
-- scratch buffer per file opened. Found by NAME rather than remembered in a
-- table: a registry of buffers is the thing that goes stale (41_layout's
-- `buf_for` guards `nvim_buf_is_valid` for exactly this reason, and octo's
-- unbounded thread registry is the failure being avoided), while the live buffer
-- list cannot.
--
-- The prefix test is the whole SCOPE of this function, and it is deliberately
-- narrow: `lain://journal`, `lain://timeline`, `lain://inbox`,
-- `lain://workspace`, `lain://request` and `lain://compose` all live in the same
-- buffer list and all begin `lain://`. Widening this to "any lain buffer" would
-- wipe the session out from under the human, so a spec pins those six as
-- survivors.
--
-- Runs AFTER both sides are placed. Wiping a buffer a window still displays
-- makes the editor pick a replacement for that window, which is the flash this
-- module exists to avoid, arriving by the back door.
function review_diff.drop_stale(keep)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if buf ~= keep and name:sub(1, #review_diff.OLD_PREFIX) == review_diff.OLD_PREFIX then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
end

-- Both windows, always, and always after both buffers have landed: `diffthis` on
-- one window alone diffs it against whatever the other still holds, which on a
-- second open is the PREVIOUS file -- a diff of two unrelated files that renders
-- perfectly and means nothing.
function review_diff.pair(wins)
  for _, win in ipairs(wins) do
    vim.api.nvim_win_call(win, function() vim.cmd("diffthis") end)
  end
end

-- The line the sidebar's gesture resolved to, CLAMPED: a target past the end of
-- the file is a line the changeset named and the file no longer reaches, and
-- `nvim_win_set_cursor` raises on one -- taking the whole render down instead of
-- opening the file. `line` is clamped through a type test rather than
-- `line or 1` for `checked_lines`' reason: a Ruby nil arrives as truthy userdata.
--
-- `zv` because 'foldmethod=diff' has just closed every unchanged region, and a
-- target inside one lands the human on a CLOSED FOLD showing a summary line
-- instead of their file. T14 resolves to hunk lines, which are never folded, but
-- T16 and T17 both navigate to arbitrary anchors. `zv` opens exactly enough to
-- show the line and nothing more.
--
-- Only the new side is positioned; the old side follows through diff mode's own
-- scroll binding, and setting it by hand would put it on a line number that
-- means something else entirely.
function review_diff.focus_line(win, buf, line)
  local wanted = type(line) == "number" and line or 1
  local target = math.max(1, math.min(wanted, vim.api.nvim_buf_line_count(buf)))
  vim.api.nvim_win_set_cursor(win, { target, 0 })
  vim.api.nvim_win_call(win, function() vim.cmd("normal! zv") end)
end

-- Open one changed file as the diff pair.
--
-- TAKES FOCUS, landing the human on the new side, and that is not a violation of
-- `review_place`'s "moves nobody" -- it is the distinction that rule draws. The
-- rule is about a RENDER arriving unbidden while the human reads something else;
-- this entry point exists ONLY as the answer to a human asking for a file, and
-- nothing else calls it. A navigator whose `<CR>` leaves you sitting in the
-- navigator reads as broken, and both surveyed projects (diffview, octo) focus.
-- The sidebar's own re-render still moves nobody, because it goes through
-- `review_place` and this is the only entry point that adds the move.
--
-- Focus is taken LAST, after both sides have landed, the pair is in diff mode
-- and the cursor is on its target: arriving in a window that is still being
-- assembled is #509 one level up. `nvim_set_current_win` crosses the tabpage for
-- free, so the human lands in the review from wherever they were.
--
-- The window ids come back from `review_place` and are used inside this one
-- synchronous call. That does not break the do-not-cache-an-id rule: nothing
-- between here and the last use can close a window, and the rule is about ids
-- held ACROSS renders, when the human has had a turn.
--
-- @param path repository-relative, exactly as Ruby sent it -- resolved against
--   {ROOT} to open, and kept verbatim as the old side's name and stamp
-- @param old_lines `git show <base>:<path>`, already read by Ruby
-- @param line the new-side line the gesture resolved to
-- @param revisions the two commit-ish strings, keyed by side
function _G.__lain.open_changeset(path, old_lines, line, revisions)
  -- Everything that can refuse, before anything is created: a raise that had
  -- already built a tabpage and two buffers would leave the review half-drawn on
  -- a wiring mistake, which is worse than not opening at all.
  review_diff.relative_path(path)
  local old_revision = review_diff.revision_for(revisions, "old")
  local new_revision = review_diff.revision_for(revisions, "new")
  local lines = review_diff.checked_lines(old_lines)

  local new_buf = review_diff.new_side(path)
  local old_buf = review_diff.old_side(path, lines, vim.bo[new_buf].filetype, vim.bo[new_buf].fileformat)
  review_diff.unstamp(old_buf, new_buf)
  review_diff.stamp(new_buf, "new", new_revision, path)
  review_diff.stamp(old_buf, "old", old_revision, path)

  local old_win = _G.__lain.review_place("old", old_buf)
  local new_win = _G.__lain.review_place("new", new_buf)

  review_diff.drop_stale(old_buf)
  review_diff.pair({ old_win, new_win })
  review_diff.focus_line(new_win, new_buf, line)
  vim.api.nvim_set_current_win(new_win)
end
