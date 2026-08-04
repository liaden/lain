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

-- Annotation text for a buffer that is gone is text nothing can read again, and
-- this table would otherwise grow for the life of the session -- octo's own
-- registry defect. Cleared on unload, where the extmarks die anyway.
--
-- The reason recorded here first was that bufnrs get REUSED, which would make
-- this a correctness bug rather than a leak. Measured against this nvim: they do
-- not -- `nvim_create_buf` after a wipe answers a strictly higher number -- so
-- the growth is the whole of it. 41_layout's `buf_for` rides the same fact from
-- the other side: a remembered bufnr can go invalid, never come back as somebody
-- else's.
vim.api.nvim_create_autocmd("BufUnload", {
  group = vim.api.nvim_create_augroup("lain_review", { clear = true }),
  callback = function(ev) review_annotations[ev.buf] = nil end,
})

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
