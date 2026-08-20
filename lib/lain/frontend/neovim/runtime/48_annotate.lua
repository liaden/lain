-- The notes a human leaves on the diff T15 draws (T16): `:LainNote` places one
-- against the line under the cursor, `:LainNoteDone` hands every one of them
-- back. What renders inline is a MARKER and never the words -- right-aligned, so
-- it cannot collide with the code being read, which is octo's shape and the
-- reason the note's text lives in the thread pane (T18) instead.
--
-- ORDER IS THE OUTPUT. The journal records notes in placement order, and nothing
-- else records which one the human wrote first, so every note carries a
-- placement sequence and the payload is sorted by it. Extmark order is
-- POSITIONAL: notes placed on lines 40, 12 and 25 come back from
-- `nvim_buf_get_extmarks` as 12, 25, 40 -- tidy, plausible, and the wrong
-- answer, which no assertion about a note's content would ever catch. That is
-- also why the per-buffer store is an ARRAY and not the `[buf][id]` map
-- `65_review.lua` uses: `pairs` has no order at all, so that map cannot express
-- this module's central requirement.
--
-- DRIFT IS MEASURED HERE, AND IT IS NEVER A QUESTION ABOUT WHETHER A MARK
-- SURVIVED. T15's panel measured that a mark inside a rewritten span MOVES
-- rather than invalidates -- `get_extmark_by_id` still answers a position and
-- never reports invalid -- so "is the mark still there" reads YES for a mark
-- that now names a different line. Nothing here asks it. What `resolved` does
-- instead is read the line the mark NOW names and compare it, as text, with what
-- that line said when the note was placed. Content against content, at the
-- moment of settling.
--
-- IT IS MEASURED IN THE EDITOR BECAUSE NOTHING ELSE CAN. "The line the number
-- now names" lives in this buffer: a session holds a DIFF, not a working tree,
-- and the surface adapter must not cache the changeset. A Ruby-side measurement
-- would be against a copy that is free to disagree with what the human is
-- looking at -- and for a 'fileformat=dos' file it certainly would, since nvim
-- strips the carriage returns this buffer never shows while git's bytes carry
-- them. Both halves of the comparison come off the same buffer, so that whole
-- class of false drift cannot arise.
--
-- The boolean rides the wire and Ruby takes it as given. It is never omitted: a
-- nil value drops its key from a lua table entirely, and `AnnotationPlaced`
-- gives `drifted` no default, so a hole here is refused rather than journaled as
-- "did not drift".
--
-- NOTHING HERE IS ASYNCHRONOUS, `47_diff.lua`'s constraint and its reason:
-- [diffview#466] is `E5560 nvim_buf_is_valid must not be called in a lua loop
-- callback`, which CRASHES the editor rather than failing a spec. Drift
-- detection is the card most likely to reach for `nvim_buf_attach`'s `on_lines`
-- -- the diff spec's tripwire names this module by name for it -- and it does
-- not need to: an extmark already tracks the edits, and the comparison happens
-- once, at settle, on the main loop. There is no listener to install.
--
-- 48, after 47_diff (whose stamps it reads and whose buffers it marks) and after
-- 30_commands (`define`). ONE new top-level name, as 41_layout and 47_diff each
-- take one, because the chunk shares a scope.
local review_notes = {
  -- The inline marker per kind. THE SECOND SPELLING of a closed set that
  -- `review/vocabulary.rb` owns (`Lain::Review::ANNOTATION_KINDS`), and it is
  -- forced: lua cannot read a Ruby constant, and a marker per kind needs the
  -- members anyway. `spec/lain/frontend/neovim/annotate_spec.rb` pins these keys
  -- against that declaration, the same defence `Anchor::SIDES`' spec applies to
  -- `Review::SIDES` -- so a fourth kind added on one side and not the other
  -- fails there rather than being refused, silently, at the far end of a wire.
  --
  -- ONE highlight group for all three rather than a severity map: T17 projects
  -- these into diagnostics and owns that map, and a second copy here would be
  -- free to disagree with it.
  MARKERS = { note = "● note", question = "● question", blocker = "● blocker" },

  -- buf -> the notes placed in it, IN PLACEMENT ORDER, each holding the extmark
  -- id that tracks its position.
  by_buf = {},

  -- Notes whose buffer is gone, already resolved to their last known row. See
  -- `harvest`.
  harvested = {},

  -- Monotonic across the session, never per buffer: the human alternates sides
  -- as they read, so a per-buffer counter would order each side correctly and
  -- the review wrongly.
  placed = 0,
}

-- Idempotent: nvim answers the same id for a name it already knows.
function review_notes.namespace()
  return vim.api.nvim_create_namespace("lain_review_notes")
end

-- Sorted, so a refusal message and a completion list are the same list in the
-- same order every time rather than whatever `pairs` felt like.
function review_notes.kinds()
  local names = {}
  for kind in pairs(review_notes.MARKERS) do
    names[#names + 1] = kind
  end
  table.sort(names)
  return names
end

-- The three facts a note needs off the buffer it is placed in, READ AT
-- PLACEMENT and copied into the note.
--
-- Reading them again at settle time would be wrong, and quietly so: T15
-- WITHDRAWS these stamps when the human opens the next file, so by the time
-- `:LainNoteDone` runs, the buffer a note is on carries no side, no revision and
-- no path. Navigating is what a review IS, so the settle-time read is wrong for
-- every note but the last file's.
--
-- Reading the variable is also the whole membership test -- there is no buffer
-- NAME parsing anywhere in this module. A stamped buffer is not a review buffer
-- forever, and the name outlives the stamp.
function review_notes.stamp(buf)
  local side = vim.b[buf].lain_review_side
  local revision = vim.b[buf].lain_review_revision
  local path = vim.b[buf].lain_review_path
  if type(side) ~= "string" or type(revision) ~= "string" or type(path) ~= "string" then
    return nil
  end
  return { side = side, revision = revision, path = path }
end

-- The note as Ruby will read it: the mark's row NOW, the text the line said when
-- it was placed, and whether the two still agree. Exactly the keys
-- {Lain::Review::Annotations} reads and no others -- an extra key is either
-- noise or a version skew, and every key is always present because a nil value
-- drops its key from a lua table entirely and the hole reaches Ruby as a note
-- naming no side, or reporting no measurement, at all.
--
-- `held` is nil when the row is past the end of the buffer, which no anchor_text
-- can equal, so a line the document no longer reaches answers drifted. That
-- deliberately collapses "moved" and "gone" into one boolean -- the same
-- collapse {Lain::Review::Anchor#drifted?} documents, and for the same reason:
-- telling them apart is the drift-model spike, and this card answers only "does
-- this position still say what it said".
--
-- The stored row is the fallback for a mark that is genuinely GONE (something
-- cleared the namespace), which `get_extmark_by_id` reports as an empty answer.
-- Freezing the note at the row it was placed on is what keeps the human's words:
-- it then almost certainly reports drift, which is the honest reading, where
-- dropping the note would lose the one part nobody can reconstruct.
-- ONE place builds the wire table, because there are two ways to reach it
-- (`resolved` and `reaped`) and they differ only in where the row and the held
-- line come from. A second copy of the key list is precisely how a member starts
-- being dropped in silence, which is the defect this card had to fix one layer
-- up in `ReviewWrite::KEYS`.
--
-- `held` is nil for a row the buffer does not reach, and nil for a buffer that
-- is not there at all. No anchor_text equals nil, so both answer DRIFTED.
function review_notes.wired(note, row, held)
  return {
    seq = note.seq,
    wire = {
      path = note.path,
      side = note.side,
      revision = note.revision,
      kind = note.kind,
      text = note.text,
      anchor_text = note.anchor_text,
      line = row + 1,
      drifted = held ~= note.anchor_text,
    },
  }
end

function review_notes.resolved(buf, note)
  local position = vim.api.nvim_buf_get_extmark_by_id(buf, review_notes.namespace(), note.id, {})
  local row = position[1] or note.row
  return review_notes.wired(note, row, vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1])
end

-- A note whose buffer is GONE while its entry survived, which happens exactly
-- when `BufUnload` did not fire: under 'eventignore', under `noautocmd`, or for
-- a plugin that suppresses events around its own bookkeeping. Nothing lain does
-- reaches it -- `47_diff.drop_stale` uses a plain `nvim_buf_delete` -- but the
-- failure when something does is TOTAL rather than partial:
-- `nvim_buf_get_extmark_by_id` raises `Invalid buffer id` out of
-- `:LainNoteDone`, nothing is sent, and the human can never settle again
-- because every later gesture dies on the same dead entry.
--
-- Kept rather than skipped: the words are the part nobody can reconstruct. The
-- note freezes at the row it was placed on and reports DRIFTED, because the
-- position cannot be checked without the buffer and "I could not tell" must
-- never be recorded as "it still says what it said".
function review_notes.reaped(note)
  return review_notes.wired(note, note.row, nil)
end

-- Entries whose buffer died without `BufUnload`, moved into `harvested` and
-- removed. Assigning nil to the key being visited is defined behaviour in lua's
-- `next`, so this is safe to do during the traversal.
--
-- It runs at SETTLE and moves them rather than answering them in place, because
-- `forget` is deliberately deferred past the write: a refused hand-off has to
-- leave every note recoverable, and a note dropped here would not be.
function review_notes.reap()
  for buf, live in pairs(review_notes.by_buf) do
    if not vim.api.nvim_buf_is_valid(buf) then
      review_notes.by_buf[buf] = nil
      for _, note in ipairs(live) do
        review_notes.harvested[#review_notes.harvested + 1] = review_notes.reaped(note)
      end
    end
  end
end

-- A buffer leaving the session takes its extmarks with it, so its notes are
-- RESOLVED and kept rather than dropped -- and this is the half a naive garbage
-- collector gets exactly backwards. `47_diff.drop_stale` WIPES the previous
-- file's old side the moment the human opens the next file, so a GC that merely
-- cleared the entry would delete every old-side note the instant they navigated.
--
-- The entry itself is still removed, which is the leak `65_review.lua`'s own GC
-- exists to prevent (octo's unbounded thread registry is the failure being
-- avoided): nothing keyed by a dead bufnr survives this. Measured against this
-- nvim, extmarks, lines and the buffer name are ALL still readable inside
-- `BufUnload`, which is what makes resolving here possible at all.
--
-- Clearing the entry first is also what makes this harvest-once: a buffer can
-- unload more than once in a session (hidden, then wiped), and a note harvested
-- twice is a note the human placed once and the journal records twice.
function review_notes.harvest(buf)
  local live = review_notes.by_buf[buf]
  if live == nil then
    return
  end
  review_notes.by_buf[buf] = nil
  for _, note in ipairs(live) do
    review_notes.harvested[#review_notes.harvested + 1] = review_notes.resolved(buf, note)
  end
end

-- Refuses BEFORE anything is gathered or sent, `open_changeset`'s rule: a settle
-- that half happened is worse than one that did not.
--
-- The reason is sharper now that drift is measured HERE rather than against a
-- document on disk, not weaker. A review is of the changeset, and drift is
-- supposed to report that the CHANGESET moved under a note -- so settling over
-- an unsaved buffer would measure the human's own half-finished edit and journal
-- it as the diff having shifted. That is the silent wrong answer, dressed as
-- evidence. `:LainReviewDone` refuses a modified buffer for the neighbouring
-- reason, and this rail refuses it too.
--
-- Sorted, so which file a two-file refusal names is not whatever `pairs` chose.
--
-- No validity check, and its absence is the invariant rather than an omission:
-- `settled` runs `reap` first, so every entry left here is keyed by a live
-- buffer. This once guarded `nvim_buf_is_valid` while `resolved` did not, which
-- is the shape of a suspicion acted on in one place out of two -- the guard
-- looked like care and the gap two lines down was the actual defect.
function review_notes.assert_saved()
  local bufs = {}
  for buf in pairs(review_notes.by_buf) do
    bufs[#bufs + 1] = buf
  end
  table.sort(bufs)
  for _, buf in ipairs(bufs) do
    if vim.bo[buf].modified then
      error("lain: save " .. vim.api.nvim_buf_get_name(buf) .. " before settling its notes -- an unsaved " ..
        "edit would be measured as the changeset drifting under your notes, which it did not", 0)
    end
  end
end

-- Every note the human has placed, in the order they placed them.
--
-- `reap` FIRST, and the order is the point: it is what leaves every remaining
-- entry keyed by a live buffer, so `assert_saved` and `resolved` below can both
-- touch one without asking again.
function review_notes.settled()
  review_notes.reap()
  review_notes.assert_saved()

  local gathered = {}
  for _, note in ipairs(review_notes.harvested) do
    gathered[#gathered + 1] = note
  end
  for buf, live in pairs(review_notes.by_buf) do
    for _, note in ipairs(live) do
      gathered[#gathered + 1] = review_notes.resolved(buf, note)
    end
  end
  table.sort(gathered, function(a, b) return a.seq < b.seq end)

  local payload = {}
  for _, note in ipairs(gathered) do
    payload[#payload + 1] = note.wire
  end
  return payload
end

-- Handed back means handed back: the markers go with the notes, so a second
-- gesture settles nothing rather than journaling every note a second time.
-- Reached only AFTER the rpcrequest returns, so a refused write leaves the
-- human's notes exactly where they were.
function review_notes.forget()
  for buf in pairs(review_notes.by_buf) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, review_notes.namespace(), 0, -1)
    end
  end
  review_notes.by_buf = {}
  review_notes.harvested = {}
end

-- The cursor row is 1-based and extmarks are 0-based, which is the whole of the
-- arithmetic here.
function review_notes.place(buf, stamp, kind, text)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local id = vim.api.nvim_buf_set_extmark(buf, review_notes.namespace(), row, 0, {
    virt_text = { { review_notes.MARKERS[kind], "Comment" } },
    virt_text_pos = "right_align",
  })
  review_notes.placed = review_notes.placed + 1
  review_notes.by_buf[buf] = review_notes.by_buf[buf] or {}
  local notes = review_notes.by_buf[buf]
  notes[#notes + 1] = {
    id = id,
    row = row,
    seq = review_notes.placed,
    kind = kind,
    text = text,
    anchor_text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "",
    side = stamp.side,
    revision = stamp.revision,
    path = stamp.path,
  }
end

-- How many live notes this module is tracking for a buffer, or nil for one it is
-- not tracking at all.
--
-- Public because the obligation it makes checkable is otherwise invisible: a
-- per-buffer table that keeps entries for dead buffers grows for the life of the
-- session, and a leak nothing can observe is a leak nobody notices. `65_review`'s
-- own GC comment records that registry growth as the defect it exists for.
function _G.__lain.review_notes_held(buf)
  local live = review_notes.by_buf[buf]
  if live == nil then
    return nil
  end
  return #live
end

-- A note against the line the cursor is on. `:LainNote {kind} {text}`.
--
-- The kind is the FIRST word and is required, never inferred: it is a closed set
-- (`Lain::Review::ANNOTATION_KINDS`), and a `blocker` that silently became a
-- `note` because the parse guessed is the one failure mode that matters here --
-- `blocker` is the only kind a verdict policy reads.
--
-- The text is taken from the RAW argument string rather than rejoined from
-- `fargs`, so the human's own spacing survives: an anchored line's indentation
-- is evidence a drift check compares, and their words are not this module's to
-- reformat.
--
-- SYNCHRONOUS, deliberately, where `65_review.lua`'s `:LainAnnotate` prompts
-- through `vim.ui.input`. That is asynchronous under the dressing plugins that
-- replace it (dressing.nvim, noice, telescope), so the callback runs after the
-- command returns -- harmless there because nothing is sent, but here it would
-- put the placement SEQUENCE at the mercy of how fast the human types into two
-- overlapping prompts, and the sequence is this card's whole output.
define("LainNote", function(opts)
  local buf = vim.api.nvim_get_current_buf()
  local stamp = review_notes.stamp(buf)
  if stamp == nil then
    error("lain: :LainNote needs a buffer lain has open for review", 0)
  end
  local kind = opts.fargs[1]
  if review_notes.MARKERS[kind] == nil then
    error("lain: :LainNote's first argument is the kind -- one of " ..
      table.concat(review_notes.kinds(), ", ") .. " -- got " .. tostring(kind), 0)
  end
  local text = opts.args:match("^%S+%s+(.*)$")
  if text == nil or text:match("^%s*$") ~= nil then
    error("lain: :LainNote " .. kind .. " needs the note itself after the kind -- " ..
      "a note with nothing in it records no opinion", 0)
  end
  review_notes.place(buf, stamp, kind, text)
end, {
  nargs = "+",
  -- Only ever the FIRST argument: the rest is the human's prose, and offering
  -- them `blocker` halfway through a sentence is worse than offering nothing.
  complete = function(lead, line)
    if line:match("^%s*LainNote%s+%S*$") == nil then
      return {}
    end
    return vim.tbl_filter(function(kind) return vim.startswith(kind, lead) end, review_notes.kinds())
  end,
})

-- Hand every note back, in placement order.
--
-- ONE argument after the verb, and it is an ARRAY -- of which the payload is the
-- sole member, so the batch arrives whole. Every verb on this rail is
-- destructured Ruby-side as `verb, args`, so flat positionals arrive as the
-- first note alone and every other one is dropped on the floor -- which is
-- exactly what happened to `:LainReviewDone` once (`65_review.lua` records it).
-- `Neovim::ReviewWrite` refuses both spellings of that mistake by name.
--
-- `review_notes` is an ANSWERED verb, so the request's return leg IS lain's
-- verdict on the write and a refusal comes back as the request's ERROR.
-- `pcall` does two things here, and the second is the load-bearing one: it
-- turns that ERROR into READABLE TEXT rather than a raw table that crossed
-- msgpack, and it keeps `forget` on the far side of it. A refused hand-off must
-- leave every note and every marker exactly where the human left them -- a
-- refusal they cannot retype from is worse than no refusal at all -- so nothing
-- is cleared until lain says it took them, which is what the early RETURN
-- below preserves.
--
-- THE REFUSAL IS ANSWERED, NOT RE-RAISED, and this comment used to say the
-- opposite for a true reason wrongly applied. It is true that nvim appends its
-- own `stack traceback:` to anything escaping a `define`d callback however it
-- was raised, `error(msg, 0)` and a `pcall`-then-reraise alike; the traceback
-- is nvim's outer wrapper's doing. That is a limit on RAISING, not on
-- refusing. Sending it out on `__lain.review_refused` instead costs the human
-- no traceback, which is what `65_review.lua`'s `:LainReviewDone` already does
-- and what `46_sidebar.lua`'s `:LainReviewVerdict` now does too. It does NOT
-- promise no hit-enter prompt -- a message longer than the window still pages;
-- `46_sidebar.lua`'s comment carries the measurement.
define("LainNoteDone", function()
  local payload = review_notes.settled()
  local taken, refusal = pcall(vim.rpcrequest, chan, "lain_command", "review_notes", { payload })
  if not taken then
    _G.__lain.review_refused(refusal)
    return
  end
  review_notes.forget()
end)

-- Its OWN augroup, and the name matters: `65_review.lua` creates
-- `lain_review` with `clear = true` and loads AFTER this module, so sharing the
-- name would delete this autocmd at attach and every old-side note would be lost
-- with its buffer, in silence.
vim.api.nvim_create_autocmd("BufUnload", {
  group = vim.api.nvim_create_augroup("lain_review_notes", { clear = true }),
  callback = function(ev) review_notes.harvest(ev.buf) end,
})

-- The note keys, on the buffers a note can actually be placed in.
--
-- THE MEMBERSHIP TEST IS THE STAMP, `review_notes.stamp`'s own rule and not a
-- second reading of it: a `BufEnter` pattern cannot match on a buffer variable,
-- and it must not match on a NAME -- a stamped buffer is not a review buffer
-- forever, and the name outlives the stamp. So the autocmd is broad and the
-- callback asks the one question that decides it, which is also the question
-- `:LainNote` itself asks before placing anything. Two answers to "may a note
-- go here" cannot disagree, because there is one.
--
-- It follows that the keys are REMOVED when the stamp is withdrawn (T15 does
-- that when the human opens the next file). A key left behind would still find
-- `:LainNote`, which would refuse correctly -- but a key that is present and
-- refuses teaches the human that notes are broken, where a key that is absent
-- teaches them they are somewhere else.
--
-- THE CMDLINE IS PRE-FILLED, NOT EXECUTED -- no `<CR>`, no `vim.ui.input`. The
-- prompt version is the obvious one and it is wrong here for the reason stated
-- above `:LainNote`: `vim.ui.input` is asynchronous under the dressing plugins
-- that replace it, and two overlapping prompts would put the placement SEQUENCE
-- at the mercy of how fast the human types -- and the sequence is the output.
-- Typing into the cmdline is synchronous, and the command that runs on Enter is
-- the same one, in the same order, that a human typing it out would get. It
-- also leaves the command's name on screen, which is how the key teaches what
-- it is a shortcut for.
--
-- One key per KIND, never a prompt for the kind: it is a closed set, and
-- `blocker` -- the only kind a verdict policy reads -- must not be reachable
-- only through a word the human has to remember to type.
-- ONE table, read by both halves, so a key added to the bind list cannot be
-- forgotten by the unbind list -- which is the drift that would leave exactly
-- the stale, refusing key this whole autocmd exists to remove.
local NOTE_KEYS = {
  { "n", ":LainNote note ", "note on this line (finish the sentence, then <CR>)" },
  { "q", ":LainNote question ", "question on this line (finish it, then <CR>)" },
  { "b", ":LainNote blocker ", "blocker on this line (finish it, then <CR>)" },
  { "N", "<Cmd>LainNoteDone<CR>", "hand every note back" },
  { "t", "<Cmd>LainThread<CR>", "open the thread on this line" },
}

local function bind_note_keys(buf)
  local stamped = review_notes.stamp(buf) ~= nil
  for _, key in ipairs(NOTE_KEYS) do
    if stamped then
      lain_buf_key(buf, key[1], key[2], key[3])
    else
      pcall(vim.keymap.del, "n", lain_prefix() .. key[1], { buffer = buf })
    end
  end
end

vim.api.nvim_create_autocmd("BufEnter", {
  group = vim.api.nvim_create_augroup("lain_review_note_keys", { clear = true }),
  callback = function(ev) bind_note_keys(ev.buf) end,
})
