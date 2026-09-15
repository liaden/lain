-- One changed file, drawn into the review's two diff slots: the REAL file
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
-- UNLESS THE FILE IS NOT THE HEAD. When the checkout is at another revision, or
-- has changes to this file, the bytes on disk are not the ones under review, and
-- Ruby says so by sending the head's lines. The new side is then a read-only
-- copy named `lain://review/NEW/<path>`, under a winbar naming the revision
-- (`head_side`, `label`): losing the language server there is the price of a note
-- anchored to a line the reviewed revision actually holds.
--
-- THE OLD SIDE CANNOT BE A FILE -- that revision is not on disk -- so it is a
-- `nofile` scratch buffer named `lain://review/OLD/<path>`, which is how a
-- gesture recovers the side AND the path it came from. Its filetype and
-- 'fileformat' are set BY HAND from the new side's, because a `lain://` name has
-- nothing to sniff and both halves of a diff have to be presented the same way
-- to be comparable at all (see `as_shown` for the CRLF half of that).
--
-- THESE BUFFERS CARRY EXTMARKS -- the note rail's annotations, the diagnostics
-- rail and the thread rail all anchor in them -- so the two rules that protect
-- a mark are stated once, here, and enforced below:
--
--   1. A scratch side is REFILLED IN PLACE, never wholesale (`refill`). A
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
  NEW_PREFIX = "lain://review/NEW/",

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
-- name outside the contract the note rail reads the side and the path back out
-- of. Refusing also says which end is wrong; everything Ruby-side already keys
-- on the relative path it sent.
function review_diff.relative_path(path)
  if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/" then
    error("lain: open_changeset needs a repository-relative path, not " .. tostring(path) ..
      " -- the old side's name embeds it, and an absolute one falls outside lain://review/OLD/", 0)
  end
  return path
end

-- Only Ruby knows which two commits this diff is between, so a missing one is a
-- render that cannot be repaired here -- and the note rail would journal every
-- note on it anchored to nothing, which reads as a note about no diff at all
-- rather than as the wiring slip it is. Refused by NAME, `review_place`'s shape
-- one module down.
function review_diff.revision_for(revisions, side)
  local revision = type(revisions) == "table" and revisions[side] or nil
  if type(revision) ~= "string" or revision == "" then
    error("lain: open_changeset needs a revision for the " .. side ..
      " side -- a note anchored to no revision names no diff", 0)
  end
  return revision
end

-- Every line of one side, checked BEFORE anything is created.
-- `nvim_buf_set_lines` raises on a string containing a newline, and it would
-- raise having already made two buffers and a tabpage -- the half-drawn review
-- this function's argument check exists to prevent.
--
-- The `type(...) ~= "table"` test is doing real work: a Ruby `nil` crosses
-- msgpack as `vim.NIL`, which is USERDATA and therefore truthy, so the
-- `old_lines or {}` a reader would write here is dead code that passes userdata
-- straight to the API.
function review_diff.checked_lines(lines, side)
  if type(lines) ~= "table" then
    return {}
  end
  for i, line in ipairs(lines) do
    if type(line) ~= "string" or line:find("\n", 1, true) then
      error("lain: open_changeset " .. side .. "_lines[" .. i .. "] is not a single line -- " ..
        "each side is one buffer line per line git showed", 0)
    end
  end
  return lines
end

-- The old side as the NEW side is displayed, which for a CRLF file means without
-- the carriage returns. nvim strips them from a 'fileformat=dos' buffer, and git
-- hands them over, so left unstripped every single line differs from its twin:
-- the diff reports the whole file changed and `foldmethod=diff` folds nothing,
-- which is the expand-context affordance simply gone.
--
-- This is the editor-side counterpart of the ruling that the diff wins and
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

-- A side's scratch buffer, VERIFIED to be the one this path names -- the old
-- side always, and the new side when it is the head's copy.
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
--
-- `named_buf` builds `nofile`, so a side that rests `nowrite` is set here on
-- every call rather than only on the path that builds the buffer.
function review_diff.scratch_buffer(prefix, buftype, path)
  local buf = review_diff.named_exactly(prefix .. path)
  vim.bo[buf].buftype = buftype
  return buf
end

function review_diff.named_exactly(name)
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
-- This is the rule that protects every mark the note, diagnostic and thread
-- rails place here. A whole-buffer `set_lines(buf, 0, -1, …)` moves every
-- extmark in the buffer to its end -- measured: a mark at row 19 reports row 40 after a refill of a
-- 40-line file -- and re-opening the file you are already reading is a supported
-- gesture, so a human's notes would silently pile up at the bottom of the buffer
-- the moment they came back to a file.
--
-- Identical content takes the early return and writes NOTHING AT ALL, which is
-- the re-open case and the common one. The early return is not merely tidier
-- than falling through: the fall-through is a zero-length `set_lines` at the
-- buffer end, and that still BUMPS 'changedtick' and fires `on_lines` -- so a
-- re-open of an unchanged file would announce a change to exactly the listeners
-- the note rail's drift detection is built on. Writing nothing means telling
-- nobody.
--
-- When the content genuinely differs (the base moved under a re-review) only the
-- differing span is rewritten, so marks outside it keep their rows and marks
-- inside it move -- which is drift, and drift is the note rail's to report
-- rather than this module's to hide.
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
  local buf = review_diff.scratch_buffer(review_diff.OLD_PREFIX, "nofile", path)
  review_diff.refill(buf, review_diff.as_shown(lines, fileformat))
  vim.bo[buf].filetype = filetype
  if vim.bo[buf].fileformat ~= fileformat then
    vim.bo[buf].modifiable = true
    vim.bo[buf].fileformat = fileformat
    vim.bo[buf].modifiable = false
  end
  return buf
end

-- The new side as the HEAD holds it, for a checkout that does not: the old
-- side's shape, refilled in place for the same reason, with two differences.
--
-- `nowrite` rather than the old side's `nofile`: `:w` still answers E382, and
-- this is the reviewed FILE at a revision rather than scratch, which is what the
-- plugins that branch on `nofile` would take it for. Its filetype comes from the
-- PATH, since there is no file beside it to borrow one from -- and the old side
-- then borrows this one.
--
-- No CR is stripped. Both sides keep what git showed, so they still diff line
-- for line, and a CRLF file shows its `^M`s on both.
function review_diff.head_side(path, lines)
  local buf = review_diff.scratch_buffer(review_diff.NEW_PREFIX, "nowrite", path)
  review_diff.refill(buf, lines)
  vim.bo[buf].filetype = vim.filetype.match({ buf = buf, filename = path }) or ""
  return buf
end

-- What each pane of a head-copy pair is, as a WINBAR on both windows.
--
-- Not buffer lines, which would move every line a note anchors to. Not a virtual
-- line above row 0 either, and that was measured rather than reasoned: it is
-- drawn only as one window's topfill, which nvim's diff scroll sync does not
-- count, so the pair went out of step on every open -- by two rows, with the
-- deletion filler hidden, when the head drops the file's first lines. A winbar
-- takes the same one row from BOTH windows, so the rows still pair.
--
-- LOCAL to the window, set through `nvim_set_option_value` with `scope =
-- "local"`: 'winbar' is global-local, and `vim.wo[win]` would set the global
-- half too, putting the label over every window the human opens afterwards.
-- An empty local value means "no lain label", and a human's own global winbar
-- shows through again.
--
-- SHORT WORDS FIRST, then `%<`. nvim truncates a winbar too long for its window
-- from the LEFT unless told where, and measured at a 53-column pane the revision
-- and "read-only" were exactly what went. `%<` moves the cut to after them, so
-- the explanation is what a narrow pane loses.
function review_diff.label(old_win, new_win, head, old_revision, new_revision)
  review_diff.winbar(new_win, head and { new_revision:sub(1, 8) .. " read-only",
    " -- the checkout is not at this revision or has changed this file" } or nil)
  if old_win then
    review_diff.winbar(old_win, head and { old_revision:sub(1, 8) .. " base",
      " -- the old side of this review" } or nil)
  end
end

-- `label` as { what, why }, or nil for no lain winbar. Each half is escaped for
-- the option's statusline syntax, so only the `%<` between them is a directive.
function review_diff.winbar(win, label)
  local escaped = function(text) return (text:gsub("%%", "%%%%")) end
  local text = label and "lain: " .. escaped(label[1]) .. "%<" .. escaped(label[2]) or ""
  vim.api.nvim_set_option_value("winbar", text, { scope = "local", win = win })
end

-- Which side, which commit that side is, and which file -- the three facts the
-- note rail needs off the buffer a note was placed in. The side decides whether a line is
-- an old-side or a new-side anchor, and the revision is what makes the anchor
-- mean anything a year later.
--
-- The PATH is stamped even though the old side's buffer NAME already ends in it,
-- because the alternative is the note rail parsing a URI back apart to recover
-- it -- and that parser would be a second, silent spelling of `OLD_PREFIX` with
-- nothing pinning it to this one. The new side could not answer it anyway: its name is
-- the ABSOLUTE path the editor resolved, while everything Ruby-side keys on the
-- repository-relative path it sent. One variable, both sides, no string surgery.
--
-- THE ROUND'S MEMORY IS DROPPED HERE, which is the other half of what
-- `withdraw` does. The triple is in exactly one of two places at any moment:
-- HELD, as the three stamps below, or PUT DOWN, as `lain_review_round` --
-- never both, so there is no second copy free to disagree with the live one.
--
-- Not tidiness. A file reviewed in one round and reviewed AGAIN in a later one
-- is the same buffer, and it reaches here carrying the FIRST round's record:
-- without this line `reacquire` would put that record back over the stamp this
-- call just made, and every rail downstream would read the new review at the old
-- revision. Measured -- `thread_view_spec.rb`'s "a second review of the same
-- file does not show a previous changeset's threads" catches exactly that, via
-- the `BufEnter` `review_place` fires two statements later.
function review_diff.stamp(buf, side, revision, path)
  vim.b[buf].lain_review_side = side
  vim.b[buf].lain_review_revision = revision
  vim.b[buf].lain_review_path = path
  vim.b[buf].lain_review_round = nil
end

-- A stamp is a claim that this buffer IS the review, so it has to be withdrawn
-- when it stops being true. The new side is a real file buffer: it is not wiped
-- when the human moves to the next file, it stays listed, and it outlives the
-- review entirely -- so a stamp left on it tells the note and diagnostic rails
-- to anchor a note into a file nobody is reviewing any more, which is a wrong
-- answer rather than a missing one.
--
-- MORE THAN TWO BUFFERS MAY CLAIM THE REVIEW: a row the human goes back to
-- inside the review's tabpage takes its stamp back (`reacquire`), so a third and
-- a fourth claim are ordinary. What this function guarantees is that the moment
-- the next row opens, every buffer but the pair being drawn stops claiming, and
-- nothing re-claims except through `reacquire`, which can only hand back what
-- THIS round gave THIS buffer.
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
--
-- THE STAMP IS PUT DOWN, NOT THROWN AWAY. What was withdrawn is copied
-- into `lain_review_round` first, in one variable, and `reacquire` below is the
-- only thing that ever reads it: a buffer this round opened and moved on from is
-- a buffer the human can come BACK to, and inside the review's tabpage coming
-- back has to put the stamp back. Withdrawing is the exact moment that record
-- can be made honestly -- these three values ARE what the round handed this
-- buffer, so nothing is derived and no side or path is ever recovered from a
-- buffer's name (`stamp` above refuses that string surgery, and this inherits
-- the refusal by copying rather than parsing).
--
-- It is written INSIDE the guard, so a buffer that was never stamped -- every
-- buffer in the editor, on every `unstamp` sweep -- gets no record and cannot
-- re-acquire anything. `lain_review_round` is never a membership test:
-- `review_notes.stamp` is still the single one, and it reads the three above.
function review_diff.withdraw(buf)
  if vim.b[buf].lain_review_side ~= nil then
    vim.b[buf].lain_review_round = { side = vim.b[buf].lain_review_side,
      revision = vim.b[buf].lain_review_revision, path = vim.b[buf].lain_review_path }
    vim.b[buf].lain_review_side = nil
    vim.b[buf].lain_review_revision = nil
    vim.b[buf].lain_review_path = nil
  end
end

-- The round's memory, dropped -- which `withdraw` deliberately does NOT do.
-- Withdrawing a stamp says "not right now"; forgetting the round says "never
-- again", and exactly one event means the second. `:saveas` renames the buffer,
-- so the path this round handed it names a different file: re-acquiring that
-- stamp would anchor a note into the file the human renamed TO, wearing the name
-- of the one they were reviewing. Every other way out of a review -- the next
-- row, another tabpage, any buffer the human wanders into -- is temporary by
-- design, and is what `reacquire` exists to undo.
function review_diff.forget_round(buf)
  vim.b[buf].lain_review_round = nil
end

-- Which round this tabpage is showing, as the two revisions it is between.
--
-- ON THE TABPAGE, `41_layout`'s choice and its reason: `vim.t[tab].lain_review`
-- dies with the tabpage, so there is no registry to go stale. It is also the
-- whole of what `reacquire` needs from outside the buffer, which is what keeps
-- that callback off the wire -- asking Ruby which revisions this round is
-- between would be an RPC round trip per `BufEnter`, on the rail a human
-- navigates with.
function review_diff.round(tab, old_revision, new_revision)
  vim.t[tab].lain_review_revisions = { old = old_revision, new = new_revision }
end

-- A buffer THIS round already opened, re-entered inside the review's tabpage,
-- takes its stamp back.
--
-- The new side is a real, editable, file-backed buffer -- deliberately, so
-- the language server and treesitter attach -- which invites the `gf`, the `:b#`
-- and the quickfix jump that lead straight out of it. `unstamp` had withdrawn
-- the stamp when the next row opened, so coming back left the human inside the
-- file they were reviewing with none of the review's keys on it, and no way back
-- but the sidebar. Within the review's tabpage, navigating is not leaving.
--
-- IT ONLY EVER ADDS A STAMP, which is what keeps it from fighting `unstamp`: it
-- puts back a stamp `unstamp` took, at a strictly later moment, and never takes
-- one `unstamp` left. `unstamp`'s rule is unchanged and is the rule being kept
-- here, read forwards -- a stamp is a claim that this buffer IS the review, and
-- inside the review's tabpage, for a file this round opened, it is.
--
-- Only a WITHDRAWN stamp is ever put back, because `withdraw` is the only writer
-- of the record and `stamp` clears it: a buffer that still holds its stamp
-- carries no record and needs nothing from this, and one that never held a stamp
-- has nothing to put back.
--
-- A BUFFER THE ROUND NEVER OPENED IS NOT THE REVIEW and cannot be made one here.
-- It carries no record, and the side, revision and path it would need are facts
-- only Ruby holds; the alternative is deriving a repository-relative path from a
-- buffer name, which is the second silent spelling of `OLD_PREFIX` that `stamp`
-- refuses one screen up. So a `gf` onto a file no row has opened gets no keys,
-- and `:LainNote`'s refusal names the way in.
--
-- THE TABPAGE TEST AND THE ROUND TEST ARE ONE READ. A tabpage that is not the
-- review's carries no revisions at all, so the same buffer opened in a second
-- tabpage stays cold; a review tabpage on a LATER round carries different ones,
-- so a buffer a settled round stamped cannot re-acquire against a diff nobody is
-- reviewing. A review tabpage the human closed and lain rebuilt is the honest
-- corner: the new tabpage carries no revisions until the next row opens in it,
-- and until then nothing re-acquires.
function review_diff.reacquire(buf)
  local round = vim.b[buf].lain_review_round
  if type(round) ~= "table" then
    return
  end
  local revisions = vim.t[vim.api.nvim_get_current_tabpage()].lain_review_revisions
  if type(revisions) ~= "table" or revisions[round.side] ~= round.revision then
    return
  end
  review_diff.stamp(buf, round.side, round.revision, round.path)
end

-- What ENTERING a buffer means for its claim, which is the whole of the tabpage
-- rule and the only caller of `reacquire`.
--
-- THE TEST RUNS ON EVERY ENTRY, NOT ON THE FIRST. A stamp is a BUFFER variable,
-- so it follows the buffer into any window that shows it -- and a rule checked
-- once would let a human who revisited a row inside the review then annotate it
-- from a tabpage the review is not in. That is authority, not decoration: the
-- note rail would take it. So outside the review's tabpage a claim is withdrawn,
-- and withdrawal is what RECORDS the round, which is why coming back restores it
-- rather than losing it.
--
-- A REVIEW WITH NO TABPAGE AT ALL IS NOT A REVIEW SOMEBODY LEFT. Closing the
-- review tabpage is the human's DISMISS gesture and the review stays open --
-- 41_layout's own ruling, and `51_thread` rebuilds the whole layout for a render
-- that arrives afterwards, finding the pair by the stamps this would otherwise
-- have taken. So the question is asked of `review_panes.tab()` rather than of
-- the current tabpage's marker: with no review tabpage there is no boundary to
-- be outside of, and the claim stands until the round settles. It costs a scan
-- of the tabpage list per entry, which is the same scan `review_panes.holds`
-- makes and is bounded by how many tabpages a human keeps.
--
-- WHAT THE WITHDRAWAL LEG COSTS, recorded because it is silent. `51_thread`
-- finds the pair by these stamps (`side_buf`), so a human reading the reviewed
-- file OUTSIDE the review tabpage has a buffer `side_buf` no longer answers for
-- -- and `register` then places the anchor's extmark nowhere and returns nil,
-- with no crash and no sentence. Reachable when an AGENT-initiated `annotate`
-- lands in exactly that window of time; before this leg existed the stamp
-- survived and it registered. It is not repaired here because the withdrawal is
-- the correct half of the boundary -- a stamp outside the review tabpage is the
-- authority defect this leg exists to end -- and because a thread pane silently
-- not anchoring is a refusal somebody has to design, on the rail that owns it.
-- Written down rather than fixed in passing.
--
-- SAFE DURING A PLACEMENT, measured rather than assumed. `open_changeset` stamps
-- before `review_place` draws, so the question is whether a placement fires a
-- `BufEnter` outside the review's tabpage while a fresh stamp is on. It fires
-- exactly one, and it arrives BEFORE the stamp does (the `bufadd`/`bufload` in
-- `new_side`, with the buffer not yet stamped and no window slot); every later
-- one is inside the review tabpage. So there is never a stamp for it to take.
function review_diff.entered(buf)
  local tab = review_panes.tab()
  if tab == nil then
    return
  end
  if tab == vim.api.nvim_get_current_tabpage() then
    review_diff.reacquire(buf)
  else
    review_diff.withdraw(buf)
  end
end

-- The OTHER way a buffer leaves the review, and the one `unstamp` cannot see:
-- `:saveas` renames a buffer in place. It succeeds even here -- measured, with
-- 'buftype' nowrite AND nomodifiable, both of which stop `:w` and neither of
-- which stops a rename -- so the buffer would go on carrying
-- `lain_review_path` while naming a different file, and the note rail would
-- anchor a note into it. Withdrawing the stamp says what is true: this is no
-- longer the file under review.
--
-- `BufFilePost` fires after the rename, on the main loop (no `vim.schedule`
-- needed -- see this module's header on E5560), in a CLEARED augroup, which is
-- every lain autocmd's convention and what makes a re-attach idempotent.
--
-- BOTH, and the second is what makes the first stick now that `withdraw`
-- REMEMBERS what it withdrew: a withdrawal alone would be undone by `reacquire`
-- the next time the human entered the renamed buffer inside the review's
-- tabpage, putting the stamp back on a buffer that no longer is the file the
-- record names. This is the one exit that is permanent, so it is the one that
-- forgets.
vim.api.nvim_create_autocmd("BufFilePost", {
  group = vim.api.nvim_create_augroup("lain_review_diff", { clear = true }),
  callback = function(event)
    review_diff.withdraw(event.buf)
    review_diff.forget_round(event.buf)
  end,
})

-- Both scratch sides are per-FILE, so the previous file's are wiped rather than
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
function review_diff.drop_stale(old_buf, new_buf)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local stale = buf ~= old_buf and buf ~= new_buf
    if stale and review_diff.scratch_side(vim.api.nvim_buf_get_name(buf)) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
end

function review_diff.scratch_side(name)
  return name:sub(1, #review_diff.OLD_PREFIX) == review_diff.OLD_PREFIX or
      name:sub(1, #review_diff.NEW_PREFIX) == review_diff.NEW_PREFIX
end

-- Both windows, always, and always after both buffers have landed: `diffthis` on
-- one window alone diffs it against whatever the other still holds, which on a
-- second open is the PREVIOUS file -- a diff of two unrelated files that renders
-- perfectly and means nothing.
--
-- A DIFF NEEDS TWO, so fewer than two is not a diff to be made carefully -- it
-- is no diff at all. On a round that presents one side (a survey) `diffthis`
-- would still take, still set 'foldmethod=diff', and still fold every line the
-- absent other side did not change: the whole file, collapsed, on the surface
-- that exists to let somebody read it.
function review_diff.pair(wins)
  if #wins < 2 then
    return
  end
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
-- instead of their file. The sidebar's gesture resolves to hunk lines, which
-- are never folded, but the note and diagnostic rails both navigate to arbitrary
-- anchors. `zv` opens exactly enough to show the line and nothing more.
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

-- Whether a window is somewhere a stray keystroke cannot reach a file on disk.
--
-- TWO values, not one. `buftype = ""` is the file-backed case the stray-`x`
-- edit was measured on, and `acwrite` is the same defect one door along: it is
-- modifiable, and its `:w` runs a BufWriteCmd that performs real file
-- operations. It is what oil.nvim, fugitive and netrw leave in a window, so it
-- is not a hypothetical.
-- Every OTHER value (`nofile`, `nowrite`, `quickfix`, `help`, `terminal`,
-- `prompt`) refuses to write the path it names, which makes `x` there a no-op at
-- worst -- so this is a deny-list of the two that write, not an allow-list that
-- would have to grow with nvim.
function review_diff.inert(win)
  local buftype = vim.bo[vim.api.nvim_win_get_buf(win)].buftype
  return buftype ~= "" and buftype ~= "acwrite"
end

-- Where the human lands: the review's navigator, or the old side if the
-- navigator is not currently safe to land in.
--
-- THE SLOT MARKER ALONE IS NOT ENOUGH, and that is the stray-`x` edit returning
-- by a side door. `vim.w[win].lain_review_slot` lives on the WINDOW, and the
-- buffer inside it is the human's to change: a `gf` on a row, a `:b#`, a
-- quickfix jump or a plain `:edit` all leave the window still marked `sidebar`
-- while it displays a real, writable file. Focusing it by its marker would then
-- land the cursor in exactly the kind of buffer this whole focus decision exists
-- to keep it out of, wearing the sidebar's name. So the BUFFER is what is
-- checked.
--
-- Identity against `review_sidebar.buf()` would be the tighter test and is the
-- wrong one, twice over. It is a CONSTRUCTOR (`named_buf`), so asking the
-- question would materialise a `lain://review` buffer as a side effect; and the
-- layout's own placeholder (`review_panes.buf_for`, a `nofile` scratch buffer
-- held by a slot whose view has not rendered yet) is a legitimate occupant that
-- it would reject. Inertness accepts both honest occupants and rejects only the
-- dangerous one.
--
-- THE OLD SIDE IS THE FALLBACK because it is the one window in the layout that
-- cannot be a file: `nofile` and `nomodifiable`, rebuilt by `old_side` two
-- statements before this is called. So the chain always ends somewhere safe --
-- there is no branch here whose behaviour is the bug, and none that raises over
-- a review which is already correctly drawn. A sidebar the human has wandered
-- off repairs itself on the next `set_review`, which re-places it every render.
--
-- UNLESS THE ROUND HAS NO OLD SIDE, and then the chain ends on the file. A
-- survey builds no such window, so `old_win` is nil and the fallback would be
-- `nvim_set_current_win(nil)` -- a raise, taking down a render that had already
-- drawn correctly. Landing on the file is the stray-`x` risk this decision
-- exists to avoid, and it is reached only when the navigator is BOTH present and
-- unsafe, which is the human having wandered off in a layout that has nowhere
-- else to go. Somewhere real beats a traceback.
--
-- FIRST match rather than last, which is where this differs from
-- `review_panes.map`'s reading of the same marker: that one answers "which
-- window IS the sidebar" and lets a later claimant win, while this one answers
-- "where is it safe to land" and any inert claimant will do.
function review_diff.landing(old_win, new_win)
  local tab = vim.api.nvim_win_get_tabpage(new_win)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.w[win].lain_review_slot == "sidebar" and review_diff.inert(win) then
      return win
    end
  end
  return old_win or new_win
end

-- Open one changed file as the diff pair.
--
-- TAKES FOCUS, and that is not a violation of `review_place`'s "moves nobody" --
-- it is the distinction that rule draws. The rule is about a RENDER arriving
-- unbidden while the human reads something else; this entry point exists ONLY as
-- the answer to a human asking for a file, and nothing else calls it. The
-- sidebar's own re-render still moves nobody, because it goes through
-- `review_place` and this is the only entry point that adds the move.
--
-- IT LANDS THEM IN THE SIDEBAR, not on the new side, and that reverses what this
-- module first shipped. The new side is the real file whenever there is one on
-- disk -- `buftype = ""` and modifiable, argued at the top of this file and
-- still right; `new_side` falls back to `nowrite` only for a path
-- `filereadable` cannot find -- and the next gesture the sidebar's banner
-- teaches is `x`, which in a real file is delete-character. A human who pressed
-- `<CR>` and then `x` silently edited the source they came to read (measured: QA
-- round 7). The alternative fixes are worse: making the new side inert
-- trades the language server and treesitter for a focus decision, and
-- documenting the trap leaves it armed. Landing in the navigator is not "leaving
-- you in the navigator" -- the review's own keys are bound there, and the pair
-- is drawn and positioned beside it, two windows to the right (slot order is
-- sidebar, old, new, so `<C-w>l` reaches the history side and `<C-w>l<C-w>l` the
-- file).
--
-- Focus is taken LAST, after both sides have landed, the pair is in diff mode
-- and the new side's cursor is on its target: presenting a review that is still
-- being assembled is #509 one level up. `nvim_set_current_win` crosses the
-- tabpage without a separate tabpage call, so the human lands in the review from
-- wherever they were -- though not for free in WinEnter terms: crossing enters
-- the target tabpage's current window before landing, so a human arriving from
-- the session tab sees two, whichever way this is spelled.
--
-- `landing` rather than `_G.__lain.review_layout().sidebar`, which reads like the
-- seam for this and is not: `review_layout` is the layout's PRESENTATION entry
-- point, so it re-runs `ensure` for a question the two `review_place` calls above
-- have already answered, and it takes focus itself. Measured, the two spellings
-- fire the SAME WinEnters -- so the reason is the duplicated work and the
-- borrowed semantics, not a flash. `landing` also answers a question
-- `review_layout` cannot: whether the sidebar is somewhere safe to land at all.
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
-- @param new_lines `git show <head>:<path>`, sent only when the checkout does
--   not hold the head; absent, the new side is the file on disk
function _G.__lain.open_changeset(path, old_lines, line, revisions, new_lines)
  -- Everything that can refuse, before anything is created: a raise that had
  -- already built a tabpage and two buffers would leave the review half-drawn on
  -- a wiring mistake, which is worse than not opening at all.
  review_diff.relative_path(path)
  local old_revision = review_diff.revision_for(revisions, "old")
  local new_revision = review_diff.revision_for(revisions, "new")
  local lines = review_diff.checked_lines(old_lines, "old")
  local head = type(new_lines) == "table" and review_diff.checked_lines(new_lines, "new") or nil

  -- THE ROUND, ASKED ONCE, and asked of the LAYOUT rather than inferred from
  -- `old_lines`. A changeset containing an added file sends `[]` here too, and
  -- that file still gets its window with an empty history in it -- "this FILE
  -- has no old side" and "this ROUND has none" are different facts, and only
  -- the second one may take a window away. Ruby says which round this is
  -- ({Review::Source#sides}); nothing here reads the content to guess.
  local sided = review_panes.holds("old")

  local new_buf = head and review_diff.head_side(path, head) or review_diff.new_side(path)
  local old_buf = sided and
      review_diff.old_side(path, lines, vim.bo[new_buf].filetype, vim.bo[new_buf].fileformat) or nil
  review_diff.unstamp(old_buf, new_buf)
  review_diff.stamp(new_buf, "new", new_revision, path)
  if sided then
    review_diff.stamp(old_buf, "old", old_revision, path)
  end

  local old_win = sided and _G.__lain.review_place("old", old_buf) or nil
  local new_win = _G.__lain.review_place("new", new_buf)

  -- The round, onto the tabpage the review is actually drawn in -- which only a
  -- window that has just landed can name, because `review_place` BUILDS that
  -- tabpage when there is none. Both revisions are the checked ones from the
  -- top, so a survey (which draws no old side) still records what its old side
  -- would be, and every note of one round names the same pair.
  review_diff.round(vim.api.nvim_win_get_tabpage(new_win), old_revision, new_revision)

  review_diff.drop_stale(old_buf, new_buf)
  review_diff.label(old_win, new_win, head, old_revision, new_revision)
  review_diff.pair(sided and { old_win, new_win } or { new_win })
  review_diff.focus_line(new_win, new_buf, line)
  vim.api.nvim_set_current_win(review_diff.landing(old_win, new_win))
end

-- The round is over: the tabpage stops vouching for it, and every claim it
-- issued is withdrawn.
--
-- NOTHING IN THE EDITOR CAN SEE A SETTLE. The tabpage, its panes, the sidebar
-- and every file buffer survive a verdict untouched -- `Review::Surface::Neovim#settle`
-- echoes a sentence and changes no editor state -- so the round's revisions
-- would sit on the tabpage for the rest of the session, and every file the round
-- opened would go on re-acquiring on entry. A note would then land in a review
-- nobody is holding: `unstamp`'s own "a wrong answer rather than a missing one",
-- one gesture further along. This is the editor half of being told.
--
-- THREE HALVES, and none of them is tidying. Clearing the revisions stops
-- anything re-acquiring; withdrawing stops what is STILL stamped, which is the
-- last row's pair -- a claim that outlived its review even before `reacquire`
-- widened what could re-claim; and FORGETTING is what keeps the withdrawal from
-- arming what it just took. `withdraw` is the writer of the round record, so a
-- sweep that only withdrew would leave every buffer of the settled round
-- remembering it -- a teardown whose own mechanism re-arms every claim it
-- retires. Harmless while the revisions are gone, and exactly the state
-- `forget_round` exists to refuse to leave lying around: settling is as
-- permanent for a round as `:saveas` is for one buffer, so it ends the same way,
-- with both.
--
-- Written out here rather than through `unstamp(nil, nil)`: that function's
-- subject is the two buffers still under review, and it has no third argument
-- for "and forget them" -- reaching for its degenerate case would be borrowing a
-- rule that says something else.
--
-- IDEMPOTENT, and it has to be: a settle can be echoed to an editor that never
-- drew this round at all (another tabpage's session, a cockpit restarted
-- mid-review), where there is no review tabpage to clear and no stamp to take.
function _G.__lain.review_settled()
  local tab = review_panes.tab()
  if tab ~= nil then
    vim.t[tab].lain_review_revisions = nil
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    review_diff.withdraw(buf)
    review_diff.forget_round(buf)
  end
end
