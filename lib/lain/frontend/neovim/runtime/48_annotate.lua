-- The notes a human leaves on the diff `47_diff.lua` draws: `:LainNote` places
-- one against the line under the cursor, `:LainNoteDone` hands every one of them
-- back. What renders inline is a MARKER and never the words -- right-aligned, so
-- it cannot collide with the code being read, which is octo's shape and the
-- reason the note's text lives in the thread pane (`51_thread.lua`) instead.
--
-- ORDER IS THE OUTPUT. The journal records notes in placement order, and nothing
-- else records which one the human wrote first, so every note carries a
-- placement sequence and the payload is sorted by it. Extmark order is
-- POSITIONAL: notes placed on lines 40, 12 and 25 come back from
-- `nvim_buf_get_extmarks` as 12, 25, 40 -- tidy, plausible, and the wrong
-- answer, which no assertion about a note's content would ever catch.
--
-- THE SEQUENCE IS THE ONLY THING THAT EXPRESSES IT, and the per-buffer store is
-- an array for a smaller reason than it once was. `pairs` has no order, so a
-- `[buf][id]` map like `65_review.lua`'s could not even be walked repeatably --
-- but an array is not ordered by `seq` either, and since a pane can reserve its
-- place long before it writes its note (`reserve`), it is now routinely not.
-- Every reader sorts. Nothing may read either store's order and call it the
-- placement order.
--
-- DRIFT IS MEASURED HERE, AND IT IS NEVER A QUESTION ABOUT WHETHER A MARK
-- SURVIVED. A panel measured that a mark inside a rewritten span MOVES
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
  -- `review.rb` owns (`Lain::Review::ANNOTATION_KINDS`), and it is forced: lua
  -- cannot read a Ruby constant, and a marker per kind needs the members
  -- anyway. `spec/lain/frontend/neovim/annotate_spec.rb` pins these keys
  -- against that declaration, the same defence `Anchor::SIDES`' spec applies to
  -- `Review::SIDES` -- so a fourth kind added on one side and not the other
  -- fails there rather than being refused, silently, at the far end of a wire.
  --
  -- ONE highlight group for all three rather than a severity map: this
  -- module only marks a note's kind inline, and owns no severity vocabulary
  -- a second copy here could disagree with.
  MARKERS = { note = "● note", question = "● question", blocker = "● blocker" },

  -- buf -> the notes placed in it, each holding the extmark id that tracks its
  -- position. IN NO PARTICULAR ORDER: `seq` is the placement order and a
  -- reservation may be spent long after a later one (see `reserve`), so every
  -- reader of this table sorts.
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

-- Whether one of this module's markers is on this row. The row is 1-BASED, as a
-- cursor reports it; the 0-based arithmetic is this function's, and that is the
-- point of it existing.
--
-- Public because another module needs the answer and must not need this one's
-- namespace or its indexing convention to get it: `51_thread.lua`'s
-- `:LainThread` refuses differently for a line carrying a note that has not been
-- handed back yet, and a copy of these two lines over there would be a second
-- place every change here has to reach.
--
-- THE EXTMARK AND NOT `by_buf`: the mark is what carries the `● note` virt_text
-- the human can actually see, and what travelled with the line as they kept
-- editing, while the registry entry keeps the row the note was PLACED on. The
-- question being asked is about what is on the screen.
--
-- READ-ONLY, and it has to stay that way. Nothing here writes into the
-- namespace, adds an entry, or touches `placed` -- the placement ORDER this
-- module's header calls its output belongs to `place` and `settle` alone.
function review_notes.marked(buf, row)
  return #vim.api.nvim_buf_get_extmarks(buf, review_notes.namespace(), { row - 1, 0 }, { row - 1, -1 }, {}) > 0
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
-- Reading them again at settle time would be wrong, and quietly so: `47_diff.lua`
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
      -- NO `lain: ` PREFIX, and that is not a style choice: this is caught by
      -- `:LainNoteDone` and handed to `__lain.review_refused`, which prepends
      -- one. Spelling it here too reached the human as `lain: lain: save ...`.
      -- `error(_, 0)` for the neighbouring reason -- level 0 keeps the file and
      -- line off the front of a sentence a human is meant to read.
      --
      -- THE PATH GOES LAST, AND THE FRAME IS 77 COLUMNS WITH THAT PREFIX. A
      -- buffer name is unbounded, so `refusal_width_discipline_spec.rb`'s rule
      -- for an unbounded field applies: lain's own words -- the condition and the
      -- remedy -- come FIRST, so a shortened echo truncates the path and not the
      -- instruction. This sentence used to interpolate the path mid-clause and
      -- ran to 135 columns with an EMPTY path, 149 with the spec's own fixture,
      -- against a bar of 80 -- a live exceedance that shipped because that spec
      -- walks `lib/` RUBY through Ripper and cannot see a lua literal. Nothing
      -- mechanical guards this number; it was measured by hand and has to be
      -- again if the words change.
      error("save before settling its notes -- an unsaved edit would read as drift: " ..
        vim.api.nvim_buf_get_name(buf), 0)
    end
  end
end

-- A COMPOSE PANE HOLDING A PLACE IN LINE IT HAS NOT SPENT IS A NOTE THIS SETTLE
-- CANNOT SEE, and settling around one inverts the very order this module calls
-- its output. Measured: a pane opened on line 10 (seq 1) and a cmdline note on
-- line 20 (seq 2) settle to line 20 ALONE -- and the pane's note then reaches
-- the journal in a LATER batch than the note it was reserved before. Nothing
-- downstream can repair that: the batches are what the record is made of.
--
-- So it refuses, `assert_saved`'s shape and its neighbouring reason -- a settle
-- that half happened is worse than one that did not, and an unwritten pane is
-- the same class of "you are not finished yet" as an unsaved buffer.
--
-- BOTH REMEDIES, because the human may mean either: `:w` finishes the note,
-- `:bwipeout` drops it and releases the place. The claim goes LAST -- it is a
-- buffer name, the unbounded field -- and it is the address `:bwipeout` needs,
-- which is the same address the pane echoed when it opened.
--
-- WHICH RESTS ON EVERY CLAIM NAMING A LIVE BUFFER, stated at `CMDLINE` above and
-- kept in three places, none of them here: `52_note_compose` makes the buffer
-- BEFORE it makes the claim, and releases on `BufUnload` and on `BufFilePre`;
-- `place` never leaves `CMDLINE` outstanding. A claim that outlived its buffer
-- would make this the one refusal in the runtime whose remedy cannot be taken --
-- worse than the inversion it exists to prevent, which is why the rule is written
-- down beside the claim rather than left to be inferred from here.
--
-- NO `lain: ` PREFIX, `assert_saved`'s rule: this is caught by
-- `:LainNoteDone`'s `pcall` and handed to `__lain.review_refused`, which
-- prepends exactly one. 53 columns with that prefix, before the claim.
function review_notes.assert_placed()
  local waiting = review_notes.outstanding()
  if #waiting > 0 then
    error("a note pane is unwritten -- :w it, or :bwipeout " .. waiting[1], 0)
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
  review_notes.assert_placed()

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

-- The receipt for a hand-off that lands, and the sentence for one with nothing
-- to hand.
--
-- WHAT THE HUMAN SEES OTHERWISE IS MARKERS DISAPPEARING, and that is ambiguous
-- in the worst direction: it looks exactly the same whether lain took every note
-- or dropped the lot. So the count is the substance -- it is the one fact they
-- can check against what they remember placing -- and the singular is spelled
-- rather than left as `1 notes`, because a receipt is read by somebody counting.
--
-- NOTHING PENDING IS THE EDITOR'S CALL, and it is answered HERE rather than
-- being sent and refused. Ruby cannot tell a review nobody had anything to say
-- about from one whose notes were already handed back -- both arrive as the same
-- empty array, and `ReviewWrite.notes` takes it deliberately (its `unbatched`
-- refusal promises the array "even when there is one of them or none"). This
-- module holds the notes, so it is the only side that can answer, and a refusal
-- written into the wire protocol would be a guess dressed as a verdict.
--
-- Both ride `__lain.review_refused`, which is the rail rather than the mood:
-- `Review::Surface::Neovim::MARKED` -- an acknowledgement, not a refusal -- is
-- posted through it too, and a second echo path would be a second place a
-- sentence can page over the human's editor. Both carry NO `lain: ` prefix, for
-- `assert_saved`'s reason one screen up: the rail prepends exactly one.
--
-- Both also sit inside `spec/refusal_width_discipline_spec.rb`'s 80-column
-- budget, prefix included (73 and 53) -- applied by hand, because that spec
-- reads `lib/` RUBY through Ripper and cannot see a lua string.
--
-- "nothing pending" names the REMEDY rather than the history, because one
-- sentence covers two situations -- a human who placed nothing, and one who
-- settled a moment ago -- and telling the second of them to "place one first"
-- would be telling them they had not.
review_notes.NOTHING_PENDING = "no notes are pending -- :LainNote places one on the line you are on"

function review_notes.receipt(count)
  return "handed " .. count .. (count == 1
    and " note back; its marker goes with it"
    or " notes back; their markers go with them")
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

-- A PLACE IN LINE, TAKEN BEFORE THERE IS A NOTE TO PUT IN IT.
--
-- `placed` is unchanged in every respect that matters -- still one monotonic
-- session counter, still incremented exactly once per note. What is new is that
-- the increment can happen EARLIER than the note can be written, which is what
-- `52_note_compose.lua` needs: a pane the human types a long note into takes its
-- number when it OPENS, so a quick cmdline note placed while they are still
-- typing comes back AFTER it, in the order the human actually decided.
--
-- THE RESERVATION IS AN OBJECT THE MODULE OWNS, NOT AN INTEGER IT HANDS OUT.
-- Handing back a bare `seq` lets `anchor` take one from anybody: nothing checks
-- that a sequence came from `reserve`, was used once, or did not exceed
-- `placed`. A forged or duplicated sequence has to be UNREPRESENTABLE, so a
-- caller names a CLAIM, the module holds the placement under it, and `anchor`
-- can only spend what is there. A pane's claim is its buffer NAME, the one piece
-- of its identity that survives `:bdelete`.
--
-- A RESERVATION IS A DEBT THE SETTLE COLLECTS. `assert_placed` refuses
-- `:LainNoteDone` while one is outstanding -- see it below for why that is a
-- correctness rule and not tidiness.
review_notes.reserved = {}

-- A CLAIM IS A BUFFER NAME. Not a convention -- a requirement, and
-- `assert_placed` is what makes it one: the only remedy it can offer for an
-- outstanding claim is `:bwipeout <claim>`, so a claim naming no buffer is a
-- refusal whose remedy answers E94.
--
-- `CMDLINE` IS THE ONE CLAIM THAT IS NOT A BUFFER NAME, and it is therefore the
-- one claim that may never be outstanding when anybody looks. `place` is its only
-- user and spends or releases it in the same breath it takes it -- unconditionally,
-- on both legs of a `pcall` -- so `outstanding` cannot see it. That is the whole
-- of the enforcement and it is eight lines below. Nothing here skips it: a guard
-- against a state the code forbids is dead code that would also swallow the only
-- symptom of the rule having broken.
review_notes.CMDLINE = ":LainNote"

-- @param claim [String] the caller's name for this gesture
-- @param placement target, row (0-based), kind, anchor_text, side, revision, path
function review_notes.reserve(claim, placement)
  review_notes.placed = review_notes.placed + 1
  placement.seq = review_notes.placed
  review_notes.reserved[claim] = placement
  return placement
end

-- The placement this claim is holding a place for, or nil. The pane's whole
-- membership test: it keeps no buffer variable of its own to disagree with this.
function review_notes.holding(claim)
  return review_notes.reserved[claim]
end

-- A place in line given up without a note. Reached when the pane's buffer
-- UNLOADS -- `:bdelete`, `:bwipeout`, nvim exiting -- which is exactly when the
-- draft it was holding stops existing.
--
-- The number is not returned to the pool and nothing tries to: `settled` sorts
-- by `seq` and reads it as neither an index nor a count, so an abandoned
-- reservation costs one integer and no correctness.
function review_notes.release(claim)
  review_notes.reserved[claim] = nil
end

-- Every claim still holding a place in line, sorted -- so which one a refusal
-- names is not whatever `pairs` chose, `assert_saved`'s rule one screen down.
function review_notes.outstanding()
  local claims = {}
  for claim in pairs(review_notes.reserved) do
    claims[#claims + 1] = claim
  end
  table.sort(claims)
  return claims
end

-- Spend a reservation: the note it was taken for, with the words that have
-- finally arrived.
--
-- ONE place builds the entry, because there are two gestures that reach it and
-- they differ only in how long the words took. A second copy of these fields is
-- precisely how a member starts being dropped in silence, which is `wired`'s own
-- reason one screen up.
--
-- `by_buf` is untouched in SHAPE: still an array per buffer, still appended to.
-- What it stops being is sorted by `seq` -- and nothing ever read it that way
-- (`settled` gathers both stores and sorts; `harvest` and `reap` only move
-- entries between them). The array's order was never the output. `seq` is.
function review_notes.anchor(claim, text)
  local placement = review_notes.reserved[claim]
  if placement == nil then
    error("no place in line is reserved for " .. tostring(claim), 0)
  end
  local id = vim.api.nvim_buf_set_extmark(placement.target, review_notes.namespace(), placement.row, 0, {
    virt_text = { { review_notes.MARKERS[placement.kind], "Comment" } },
    virt_text_pos = "right_align",
  })
  review_notes.reserved[claim] = nil
  review_notes.by_buf[placement.target] = review_notes.by_buf[placement.target] or {}
  local notes = review_notes.by_buf[placement.target]
  notes[#notes + 1] = {
    id = id,
    row = placement.row,
    seq = placement.seq,
    kind = placement.kind,
    text = text,
    anchor_text = placement.anchor_text,
    side = placement.side,
    revision = placement.revision,
    path = placement.path,
  }
end

-- The cursor row is 1-based and extmarks are 0-based, which is the whole of the
-- arithmetic here.
--
-- RESERVE AND SPEND IN ONE BREATH, and the `release` is what keeps that true
-- under a raise. `nvim_buf_set_extmark` can fail, and a reservation left behind
-- by a failed `:LainNote` would refuse every later `:LainNoteDone` naming a
-- gesture the human already saw fail. Releasing after the `pcall` costs nothing
-- on the path that worked -- `anchor` has already cleared the claim -- and is
-- the whole of the guarantee on the path that did not.
function review_notes.place(buf, stamp, kind, text)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  review_notes.reserve(review_notes.CMDLINE, {
    target = buf,
    row = row,
    kind = kind,
    anchor_text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "",
    side = stamp.side,
    revision = stamp.revision,
    path = stamp.path,
  })
  local placed, failure = pcall(review_notes.anchor, review_notes.CMDLINE, text)
  review_notes.release(review_notes.CMDLINE)
  if not placed then
    error(failure, 0)
  end
end

-- How many live notes this module is tracking for a buffer, or nil for one it is
-- not tracking at all.
--
-- Public because the obligation it makes checkable is otherwise invisible: a
-- per-buffer table that keeps entries for dead buffers grows for the life of the
-- session, and a leak nothing can observe is a leak nobody notices. `65_review`'s
-- own GC comment records that registry growth as the defect it exists for.
-- A settled review's notes are not the next review's; 47's `review_settled` reaches
-- `forget` through this because 47 loads first and cannot see the local.
function _G.__lain.review_notes_forget()
  review_notes.forget()
end

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
-- ALL THREE REFUSALS RIDE `__lain.review_refused` AND RETURN, which is
-- `:LainNoteDone`'s rail one function down, and the fix that put it there. They
-- used to `error()`, and nvim appends its own `stack traceback:` to anything
-- escaping a `define`d callback -- `error(msg, 0)` included, because the
-- traceback is nvim's outer wrapper's doing -- then raises a hit-enter prompt
-- behind which every non-fast RPC request queues. That is the hit-enter
-- deadlock at a second site: the editor answers nothing at all, including the
-- `:messages` the refusal tells them to read, until a human presses a key.
-- NONE OF THE THREE SPELLS `lain: ` any more, for `assert_saved`'s reason
-- above: the rail prepends one.
-- `spec/refusal_delivery_discipline_spec.rb` is the gate.
define("LainNote", function(opts)
  local buf = vim.api.nvim_get_current_buf()
  local stamp = review_notes.stamp(buf)
  if stamp == nil then
    -- THE REMEDY IS THE TAIL, and it is what the entry-time stamp re-acquisition
    -- leaves this refusal owing. A buffer the round already opened re-acquires
    -- its stamp on entry now, so the human who reaches this sentence is in a file
    -- no row has opened -- a `gf` into a neighbour, most likely.
    --
    -- IT NAMES A GESTURE THAT WORKS FROM WHERE THEY ARE, which is why it is not
    -- the sidebar's `<CR>`. `gf` replaces the buffer in the window it was pressed
    -- in, so out of the navigator it takes the sidebar off the screen and out of
    -- the file pane it takes the diff: a refusal naming a surface this very
    -- gesture can have hidden is a remedy the human cannot take. `<C-o>` is
    -- nvim's own way back from a jump, it needs no window they can still see, and
    -- landing is what re-acquires the stamp -- so the sentence and the fix are
    -- one keystroke. Measured against a real `gf` in `neovim_runtime_spec.rb`.
    --
    -- 74 columns with the rail's prefix, against
    -- `refusal_delivery_discipline_spec.rb`'s 80 -- which measures this literal
    -- mechanically, on every run, rather than leaving it to a reader's eye.
    _G.__lain.review_refused(":LainNote needs a buffer lain has open for review -- <C-o> goes back")
    return
  end
  local kind = opts.fargs[1]
  if review_notes.MARKERS[kind] == nil then
    -- THE VOCABULARY IS 23 COLUMNS AND THE FRAME IS 33, so the whole sentence
    -- fits the 80-column budget with a word of theirs on the end. It used to
    -- read `:LainNote's first argument is the kind`, which was 92 with an
    -- ordinary mistyped kind -- over the bar, and paged.
    _G.__lain.review_refused(":LainNote's kind is one of " ..
      table.concat(review_notes.kinds(), ", ") .. " -- got " .. tostring(kind))
    return
  end
  local text = opts.args:match("^%S+%s+(.*)$")
  if text == nil or text:match("^%s*$") ~= nil then
    -- THE REMEDY IS THE WHOLE SENTENCE NOW, and the `why` it used to carry --
    -- `a note with nothing in it records no opinion` -- lives here instead.
    -- That clause put the sentence at 109 columns, so `fitted` elided its
    -- MIDDLE, and because `fitted` keeps head and tail the part it dropped was
    -- the instruction: at 80 columns a human read `lain: :LainNote question
    -- needs  ... nothing in it records no opinion`. 51_thread's rule, paid for
    -- here: a sentence over the budget loses the thing it exists to say.
    _G.__lain.review_refused(":LainNote " .. kind .. " needs the note itself after the kind")
    return
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
-- THE REFUSAL IS ANSWERED, NOT RE-RAISED. nvim appends its own
-- `stack traceback:` to anything escaping a `define`d callback however it was
-- raised, `error(msg, 0)` and a `pcall`-then-reraise alike, because the
-- traceback is nvim's outer wrapper's doing -- a limit on RAISING, not on
-- refusing. Sending it out on `__lain.review_refused` costs the human no
-- traceback. It does NOT promise no hit-enter prompt: a message longer than the
-- window still pages, and `46_sidebar.lua` carries that measurement.
--
-- TWO `pcall`s, because there are two refusals and only one of them has been
-- anywhere. `settled` runs `assert_saved`, which refuses a modified buffer
-- HERE, before a byte crosses the wire; the second is lain's own answer to a
-- batch it received. `settled` used to sit OUTSIDE the pcall, so that first
-- refusal escaped the callback and reached the human exactly as the paragraph
-- above says it would -- wearing a `stack traceback:`, and, with a UI attached,
-- raising the hit-enter prompt that leaves the editor answering no RPC at all.
-- `:messages` and `:LainApprove` were then unavailable exactly while a refusal
-- was on screen, which is to say the recovery it named could not be taken -- the
-- same shape QA measured on the sidebar's rail.
--
-- THREE LEGS ANSWER AND ONE HANDS OVER, and the emptiness check sits between
-- the two `pcall`s rather than before them. NOT because an earlier count would
-- MISS a dead buffer's notes -- it would not, and that reason does not survive
-- inspection: `reap` is what moves them out of `by_buf`, so before `settled`
-- runs they are still there under the dead bufnr, where any hand-rolled count
-- would find them.
--
-- The reason is AUTHORITY. `settled` resolves the two stores into one ordered
-- payload, and its return is the only statement of what is about to be sent; a
-- check upstream of it would be a second, independent tally, free to disagree
-- with the first -- the same defect a second copy of the wire key list would be,
-- one file over. Placed here it also inherits `assert_saved`: "nothing pending"
-- is only ever said about a settle that was otherwise legal.
--
-- THE RECEIPT IS ECHOED ON THE RETURN LEG, AND BEFORE `forget`, in that order
-- for two separate reasons. Lain's answer to the request is what ADMITS the
-- batch, so a receipt sent any earlier would be the editor reporting a hand-off
-- the record had not agreed to. And clearing the markers is what makes the
-- gesture irreversible, so the human has to have been told first -- markers that
-- vanish with nothing said is the ambiguity the receipt exists to close.
--
-- THE ECHO IS UNGUARDED, AND THE STRONGER ARGUMENT RUNS AGAINST THAT, which is
-- why both halves are written down rather than the convenient one. This is a
-- call that can raise, sitting between a write lain has ALREADY taken and the
-- `forget` that retires it. Forced to raise: the traceback escapes into the very
-- callback this rail exists to keep clean, the markers survive notes lain is
-- holding, and the human's retry hands the same notes over a SECOND time -- the
-- double journal `forget`'s own comment exists to prevent. Reachability is
-- near-nil, but that is the shape.
--
-- Against it: a `pcall` that cleared anyway would buy a SILENT clear -- markers
-- gone, nothing said, which is the defect the receipt was added for -- and it
-- would swallow the only evidence that the RAIL broke. If `review_refused` can
-- raise, it can raise for the two refusal legs above too, neither of which
-- guards it either, and a runtime that half-trusts it in three places is harder
-- to reason about than one that treats it as total in all three. So: total, and
-- the near-nil path stays loud. That the rail is unguarded is a measured fact
-- rather than an assumption -- `review_refused` does not `pcall` its own
-- `nvim_echo`; only `recorded()` does.
define("LainNoteDone", function()
  -- `pcall`'s second return is the VALUE or the ERROR, so `batch` is the
  -- refusal on one leg and the payload on the other. Lua's convention, spelled
  -- out because one name cannot be right for both.
  local gathered, batch = pcall(review_notes.settled)
  if not gathered then
    _G.__lain.review_refused(batch)
    return
  end

  if #batch == 0 then
    _G.__lain.review_refused(review_notes.NOTHING_PENDING)
    return
  end

  local taken, refusal = pcall(vim.rpcrequest, chan, "lain_command", "review_notes", { batch })
  if not taken then
    _G.__lain.review_refused(refusal)
    return
  end
  _G.__lain.review_refused(review_notes.receipt(#batch))
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
-- It follows that the keys are REMOVED when the stamp is withdrawn (`47_diff.lua`
-- does that when the human opens the next file). A key left behind would still find
-- `:LainNote`, which would refuse correctly -- but a key that is present and
-- refuses teaches the human that notes are broken, where a key that is absent
-- teaches them they are somewhere else.
--
-- AND IT FOLLOWS BOTH WAYS: entering a buffer is also the moment a withdrawn
-- stamp can become true again -- and the moment a stamp that has left the
-- review's tabpage stops being true. `review_diff.entered` decides both, and
-- it is called here rather than from a second `BufEnter` of its own so the order
-- is written down instead of inherited from module load order. It is not a
-- second membership test: it may put a stamp back or take one away, and the line
-- below still asks `review_notes.stamp` the one question that decides the keys.
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
--
-- `c` IS THE LONG PATH AND IT IS PRE-FILLED TOO, not executed -- one key rather
-- than one per kind, because the kind is what the human types on the cmdline
-- and `:LainNoteCompose`'s completion offers the same closed set the three keys
-- above spell out. A fourth, fifth and sixth prefixed letter for `question` and
-- `blocker` panes would cost the human's `<leader>L` namespace three more
-- letters to buy nothing the cmdline does not already give them.
local NOTE_KEYS = {
  { "n", ":LainNote note ", "note on this line (finish the sentence, then <CR>)" },
  { "q", ":LainNote question ", "question on this line (finish it, then <CR>)" },
  { "b", ":LainNote blocker ", "blocker on this line (finish it, then <CR>)" },
  { "c", ":LainNoteCompose ", "compose a long note on this line in a pane (kind, then <CR>)" },
  { "N", "<Cmd>LainNoteDone<CR>", "hand every note back" },
  { "t", "<Cmd>LainThread<CR>", "open the thread on this line" },
}

local function bind_note_keys(buf)
  review_diff.entered(buf)
  local stamped = review_notes.stamp(buf) ~= nil
  for _, key in ipairs(NOTE_KEYS) do
    if stamped then
      lain_buf_key(buf, key[1], key[2], key[3])
    else
      pcall(vim.keymap.del, "n", lain_prefix() .. key[1], { buffer = buf })
    end
  end
end

-- `WinEnter` BESIDE `BufEnter`, because the rule `review_diff.entered` keeps is
-- about the TABPAGE, and `BufEnter` cannot see a tabpage change that does not
-- change the buffer. The same file shown in the review's pane and in a window of
-- another tabpage is ONE buffer, so crossing between them with `gt` moves the
-- human over the boundary twice while nvim reports no buffer entry at all -- and
-- the keys would be whatever the last buffer switch left them. Entering a
-- tabpage always enters a window, so this is the event that closes it.
vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
  group = vim.api.nvim_create_augroup("lain_review_note_keys", { clear = true }),
  callback = function(ev) bind_note_keys(ev.buf) end,
})
