-- lain://review, the changeset review's navigator: the buffer Ruby's
-- {Lain::Frontend::Neovim::ReviewView} renders into, and the `<CR>` that opens
-- the row under the cursor.
--
-- 46, above 41: this renders THROUGH the layout's `review_place`, and a module
-- sees only what concatenates before it.
--
-- `review_place` re-ensures the tabpage and its slots before every render and
-- answers a freshly resolved window id, so a render arriving after the human
-- closed the sidebar rebuilds it and lands in the rebuilt one.
-- `review_layout()`'s return is a SNAPSHOT and is deliberately not called here:
-- caching an id across renders is the documented way to earn
-- `Invalid window id`.
--
-- ONE new top-level name, 41_layout's economy: the binding cap is 60 upvalues
-- per function prototype, so every top-level local is a name each later module
-- pays for.
local review_sidebar = {
  NAME = "lain://review",

  -- state -> the key that sends it. THE SECOND SPELLING of the closed set
  -- `Lain::Review::MARK_STATES`, and it is forced: lua cannot read a Ruby
  -- constant. `review_view_spec.rb` pins these keys against that declaration, so
  -- a third state added on one side and not the other fails there rather than
  -- being refused silently at the far end of a wire.
  --
  -- A KEY PER STATE, NEVER ONE TOGGLE KEY. The state RIDES THE WIRE: a toggle
  -- would have to be computed here from the rendering on screen, and a rendering
  -- that has since moved flips the wrong hunk in SILENCE, because both values are
  -- legal. What the human pressed is what gets sent.
  --
  -- `x` is lain's tick gesture already and the sidebar draws a mark as `[x]`, so
  -- the two agree by sight. `u` is its counterpart and costs nothing: the sidebar
  -- is `nofile` and nomodifiable, so vim's own `u` has nothing to undo in it.
  MARK_KEYS = { reviewed = "x", unreviewed = "u" },
}

-- Sorted, so a refusal message and a completion list are the same list in the
-- same order every time rather than whatever `pairs` felt like.
function review_sidebar.states()
  local names = {}
  for state in pairs(review_sidebar.MARK_KEYS) do
    names[#names + 1] = state
  end
  table.sort(names)
  return names
end

-- `named_buf` attaches a filetype from READONLY_FILETYPES, a table this module
-- does not edit, so the lookup misses and the option lands unset. Fixed HERE
-- rather than by widening a shared table: the sidebar joins the one shared
-- "lain" filetype like every other record-shaped view.
--
-- Guarded on the CURRENT value rather than run unconditionally, because setting
-- 'filetype' fires FileType synchronously -- re-setting it on every render would
-- re-run a human's every FileType autocmd once per row change.
function review_sidebar.buf()
  local buf = named_buf(review_sidebar.NAME)
  if vim.bo[buf].filetype == "" then
    vim.bo[buf].filetype = "lain"
  end
  return buf
end

-- Whole-buffer replace, stamped. The stamp is REQUIRED here where set_view's is
-- optional: a sidebar row moves the moment the scope toggles or a mark redraws a
-- row, and two renderings are routinely the same height, so a line COUNT
-- aliases. Ruby resolves a gesture only against the rendering the stamp names.
--
-- Written BEFORE the placement, so the window never shows a half-drawn buffer,
-- and placed on EVERY render rather than only the first: `review_place` is what
-- repairs a layout the human has since closed windows in, and it moves nobody.
--
-- `sides` is a FACT about the round, never a layout instruction, and it rides
-- THIS render because this render precedes the layout -- the panes are built by
-- the `review_place` below, before any row is opened, so a fact sent with the
-- open would arrive after the window it would have prevented already exists.
-- Carried onto `review_panes` rather than passed down, because on the first
-- paint there is no review tabpage yet to write it to.
function _G.__lain.set_review(lines, gen, sides)
  local buf = review_sidebar.buf()
  vim.b[buf].lain_view_generation = gen
  set_lines(buf, 0, -1, lines)
  review_panes.sides = review_panes.carried(sides)
  _G.__lain.review_place("sidebar", buf)
  announce_render(review_sidebar.NAME, buf)
end

-- The cursor-on-a-row OPEN gesture. The LINE rides as an argument, never an
-- identity, because a sidebar row renders no hunk key -- and the buffer's STAMP
-- rides beside it, because a line number alone names a position in a buffer
-- whose positions move.
--
-- ONE argument after the verb, and it is an ARRAY. Every verb on this rail is
-- destructured Ruby-side as `verb, args`; 65_review records a verb that sent
-- flat positionals and had everything after the first dropped on the floor.
--
-- The buffer check is NOT redundant with the buffer-local map below. `define`
-- makes every :Lain* command GLOBAL and this one reads the CURRENT window's
-- cursor, so hand-typed from lain://journal line 7 it would open whatever file
-- the sidebar lists on ITS line 7. Hand typing is an invited path precisely
-- because the map invokes the command.
--
-- Every line is sent, with no runtime-side test of whether it holds a file: the
-- legend, a commit header and the empty-state placeholder all name none, and
-- Ruby -- which drew them and owns the line -> target map -- is the only side
-- that can say so.
--
-- EVERY REFUSAL RIDES `review_refused`, including the buffer guard's own: a
-- plain `vim.notify` blocks at roughly `#sentence + 12 > columns`, which is the
-- hit-enter prompt every non-fast RPC request then queues behind. The rail fits
-- the line, folds the rest into `:messages`, supplies its own highlight and
-- prepends the `lain: ` these strings therefore do not.
-- `spec/refusal_delivery_discipline_spec.rb` keeps it that way.
define("LainReviewOpen", function()
  local buf = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_get_name(buf) ~= review_sidebar.NAME then
    _G.__lain.review_refused(":LainReviewOpen opens the file under the cursor in " .. review_sidebar.NAME)
    return
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  vim.rpcrequest(chan, "lain_command", "review_open", { line, vim.b[buf].lain_view_generation })
end)

-- The cursor-on-a-row MARK gesture, `:LainReviewOpen`'s shape in every respect
-- that matters: the same buffer guard for the same reason (a global command
-- reading the CURRENT window's cursor), the LINE and the buffer's STAMP riding
-- together, and ONE array after the verb.
--
-- The STATE is required and is never inferred, which is the whole card. See
-- MARK_KEYS above for why a toggle cannot be computed here; the two keymaps
-- below each name their state as a literal, so the value on the wire is
-- decided by which key the human pressed and by nothing else.
--
-- ONE parameterised command rather than two, `:LainNote {kind}`'s shape: the
-- vocabulary is a closed set with a completion list, and two commands would be
-- two places to add the third state to. It is still a command PER KEYMAP in the
-- sense that matters -- everything either key does is invocable by name, with
-- the state typed out.
--
-- ACKED, so nothing here reads a return value: a refusal comes back on the rail
-- `__lain.review_refused` renders -- INCLUDING the one raised here. nvim appends
-- its own `stack traceback:` to anything escaping a `define`d callback,
-- `error(msg, 0)` included, then raises a hit-enter prompt that queues every
-- non-fast RPC request, so the editor stopped answering lain exactly while a
-- refusal naming the vocabulary was on screen.
define("LainReviewMark", function(opts)
  local buf = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_get_name(buf) ~= review_sidebar.NAME then
    _G.__lain.review_refused(":LainReviewMark marks the row under the cursor in " .. review_sidebar.NAME)
    return
  end
  local state = opts.fargs[1]
  if review_sidebar.MARK_KEYS[state] == nil then
    -- NO `lain: ` PREFIX: the rail prepends one (`65_review.lua`), and spelling
    -- it here too reached the human as `lain: lain: ...`.
    --
    -- `'s state is one of` rather than `'s argument is the state -- one of`,
    -- which measured 91 with an ordinary mistyped state and so paged. The
    -- vocabulary is 20 columns, the frame 39, and the word they typed goes
    -- LAST, where a shortened echo truncates their text and not lain's.
    _G.__lain.review_refused(":LainReviewMark's state is one of " ..
      table.concat(review_sidebar.states(), ", ") .. " -- got " .. tostring(state))
    return
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  vim.rpcrequest(chan, "lain_command", "review_mark", { line, state, vim.b[buf].lain_view_generation })
end, {
  nargs = 1,
  complete = function(lead)
    return vim.tbl_filter(function(state) return vim.startswith(state, lead) end, review_sidebar.states())
  end,
})

-- The review's conclusion. NO BUFFER GUARD, and the difference from the two
-- commands above is not an oversight: they read the current window's CURSOR, so
-- typed in the wrong buffer they would act on a row the human never looked at.
-- This carries only the word they typed, so there is no wrong place to type it
-- -- and a human who has just finished reading the last diff should not have to
-- hop back to the sidebar to say so.
--
-- It lives in the sidebar's module rather than in `65_review.lua` because that
-- file is the EPIC document rail (`:LainReviewDone` hands one document back);
-- this concludes the CHANGESET review whose navigator this module is. The two
-- share a word and nothing else.
--
-- THE VOCABULARY IS NOT RESTATED HERE, where MARK_KEYS above had to restate
-- one. Nothing in this command needs a member by name, so whatever the human
-- typed goes over as-is and `Lain::Review::VERDICTS` -- the one declaration --
-- is what judges it. The refusal that comes back therefore always names the
-- CURRENT vocabulary, and no completion list can drift from it. An empty
-- argument takes the same path for the same reason: `""` is a verdict lain does
-- not have, and lain says so, naming the ones it does.
--
-- ANSWERED, unlike every other gesture in this module: the request's return leg
-- IS lain's verdict on the write, and a refusal arrives as the request's ERROR.
-- `pcall` is what turns that ERROR -- which may be a raw table that crossed
-- msgpack, not a string -- into READABLE TEXT before anything is shown.
--
-- IT IS THEN ANSWERED AND NOT RE-RAISED. Any error escaping a `define`d callback
-- gets nvim's own `stack traceback:` appended however it was raised --
-- `error(msg, 0)` and a re-raise from inside a `pcall` included -- because the
-- traceback is nvim's outer wrapper's doing. A refusal does not have to raise.
--
-- The traceback is not the whole cost: `nvim_echo` of a message longer than the
-- message area PAGES. Measured with a UI attached at 80 columns, a 134-character
-- refusal left `nvim_get_mode` reading `{mode = "r", blocking = true}`, while
-- the same message at width 200 and a short one at width 80 did not.
-- `__lain.review_refused` records the whole sentence in `:messages` and displays
-- one line that fits `v:echospace`, folding line breaks and eliding the middle,
-- and it suppresses `-- More --` around the recording echo -- a SEPARATE prompt
-- under a separate option. A `blocking = true` after a refusal is a REGRESSION,
-- not a known cost.
define("LainReviewVerdict", function(opts)
  local taken, refusal = pcall(vim.rpcrequest, chan, "lain_command", "review_verdict", { opts.args })
  if not taken then
    _G.__lain.review_refused(refusal)
  end
end, { nargs = "*" })

-- Bound from a BufEnter autocmd (in a cleared augroup, so re-attach redefines
-- rather than stacks) because the buffer is created lazily by the first render,
-- not here. <Cmd> rather than ":", the inbox map's reason: it runs the command
-- without leaving normal mode, so the cursor the command is about does not move
-- out from under it.
--
-- The mark keys are bound from the SAME autocmd in the SAME augroup, so the one
-- clear that repairs `<CR>` on re-attach repairs all three, and a buffer that
-- has `<CR>` has never got fewer keys than it should.
vim.api.nvim_create_autocmd("BufEnter", {
  group = vim.api.nvim_create_augroup("lain_sidebar", { clear = true }),
  pattern = review_sidebar.NAME,
  callback = function(ev)
    vim.keymap.set("n", "<CR>", "<Cmd>LainReviewOpen<CR>",
      { buffer = ev.buf, desc = "lain: open the file under the cursor" })
    for state, key in pairs(review_sidebar.MARK_KEYS) do
      vim.keymap.set("n", key, "<Cmd>LainReviewMark " .. state .. "<CR>",
        { buffer = ev.buf, desc = "lain: mark the row under the cursor " .. state })
    end
  end,
})

-- The add-to-survey gesture, the wire half of accretion. What differs from every
-- keymap above is the BUFFER: a sidebar row is a NAME this runtime knows ahead
-- of time to scope a `BufEnter` to, but a survey grows from WHATEVER FILE the
-- human is reading, so the command and its keymap are GLOBAL.
--
-- PREFIXED rather than a bare letter: `x`/`u`/`<CR>` are safe to claim on a
-- `nomodifiable` sidebar, but the buffer this fires from is the human's own
-- real, EDITABLE file, where a bare `a` would cost them vim's own append.
--
-- It REFUSES rather than acking. `Gestures#routes` has no `survey_add` entry,
-- and `Router#call`'s `@routes[verb]&.call(...)` is a silent no-op for a verb
-- its table does not carry -- the ack having already returned by the time that
-- ran, so the key told the human it worked while nothing was added to a survey.
-- No payload is built for a route that does not exist.
--
-- An empty NAME alone is not enough of a guard: every lain:// buffer has one and
-- would sail through to the wrong refusal. `buftype ~= ""` is the real
-- discriminator, `47_diff.lua`'s own: `buftype = ""` is what makes the diff's
-- new side THE FILE rather than a scratch copy, and it is exactly what every
-- lain:// buffer (`nofile`, `acwrite`) is not.
define("LainSurveyAdd", function()
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or vim.bo[buf].buftype ~= "" then
    _G.__lain.review_refused(":LainSurveyAdd needs a real file buffer, not " ..
      (name == "" and "an unnamed one" or name))
    return
  end
  _G.__lain.review_refused(":LainSurveyAdd sends nothing -- accretion is not wired yet")
end)

lain_key("sa", "<Cmd>LainSurveyAdd<CR>", "add the current file to the open survey")
