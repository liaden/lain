-- lain://review, the changeset review's navigator (T14): the buffer Ruby's
-- {Lain::Frontend::Neovim::ReviewView} renders into, and the `<CR>` that opens
-- the row under the cursor.
--
-- 46, above 41: this renders THROUGH the layout's `review_place`, and a module
-- sees only what concatenates before it.
--
-- THE FIRST CALLER OF T26's LAYOUT, and that is the whole of why this file
-- exists rather than another `belowright split`. `review_place` re-ensures the
-- tabpage and its three slots before every render and answers a freshly
-- resolved window id, so a render arriving after the human closed the sidebar
-- rebuilds it and lands in the rebuilt one. `review_layout()`'s return is a
-- SNAPSHOT and is deliberately not called here: caching an id across renders is
-- the documented way to earn `Invalid window id`.
--
-- ONE new top-level name, 41_layout's own economy: the chunk shares one scope
-- and the binding cap is 60 upvalues per function prototype, so every top-level
-- local is a name each later module pays for. The public entry point goes on
-- `_G.__lain`, where the runtime's public surface lives.
local review_sidebar = {
  NAME = "lain://review",

  -- state -> the key that sends it. THE SECOND SPELLING of a closed set
  -- `review/vocabulary.rb` owns (`Lain::Review::MARK_STATES`), and it is forced:
  -- lua cannot read a Ruby constant, and a key per state needs both members by
  -- name anyway. `review_view_spec.rb` pins these keys against that declaration,
  -- the same defence `48_annotate`'s MARKERS applies to `ANNOTATION_KINDS` -- so
  -- a third state added on one side and not the other fails there rather than
  -- being refused, silently, at the far end of a wire.
  --
  -- A KEY PER STATE, NEVER ONE TOGGLE KEY, and that is this table's whole
  -- reason for existing rather than a preference. The state RIDES THE WIRE: a
  -- toggle would have to be computed here from the rendering on screen, and
  -- `cli/human_replies.rb` says what that costs -- a rendering that has since
  -- moved flips the wrong hunk, in SILENCE, because both values are legal. What
  -- the human pressed is what they meant, and it is what gets sent.
  --
  -- `x` is lain's tick gesture already (`60_question.lua` binds it to ticking
  -- the option under the cursor) and the sidebar draws a mark as `[x]`, so the
  -- two agree by sight. `u` is its counterpart and costs nothing here: the
  -- sidebar is `nofile` and nomodifiable, so vim's own `u` has nothing to undo
  -- in it.
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

-- `named_buf` is the shared constructor (nofile, hidden, nomodifiable at rest,
-- idempotent by name) and it attaches a filetype from READONLY_FILETYPES -- a
-- table in 00_constants, which this module does not edit. The lookup misses, so
-- the option lands unset, and the fix is applied HERE rather than by widening a
-- shared table: the sidebar joins the one shared "lain" filetype like every
-- other record-shaped view, with b:lain_view naming which view it is.
--
-- Guarded on the CURRENT value rather than run unconditionally, because setting
-- 'filetype' fires FileType synchronously -- re-setting it on every render
-- would re-run a human's every FileType autocmd once per row change.
function review_sidebar.buf()
  local buf = named_buf(review_sidebar.NAME)
  if vim.bo[buf].filetype == "" then
    vim.bo[buf].filetype = "lain"
  end
  return buf
end

-- Whole-buffer replace, stamped (T14/T11's SET_REVIEW). The stamp is REQUIRED
-- here where set_view's is optional: a sidebar row moves the moment the scope
-- toggles or a mark redraws a row, and two renderings are routinely the same
-- height -- which is exactly the aliasing protocol 8 replaced the line COUNT to
-- fix. Ruby resolves a gesture only against the rendering the stamp names.
--
-- Written BEFORE the placement, so the window never shows a half-drawn buffer,
-- and placed on EVERY render rather than only the first: `review_place` is what
-- repairs a layout the human has since closed windows in, and it moves nobody.
function _G.__lain.set_review(lines, gen)
  local buf = review_sidebar.buf()
  vim.b[buf].lain_view_generation = gen
  set_lines(buf, 0, -1, lines)
  _G.__lain.review_place("sidebar", buf)
  announce_render(review_sidebar.NAME, buf)
end

-- The cursor-on-a-row OPEN gesture. :LainOpen's shape in every respect that
-- matters, and its comment states the two rules this one follows too: the LINE
-- rides as an argument, never an identity, because a sidebar row renders no hunk
-- key -- and the buffer's STAMP rides beside it, because a line number alone
-- names a position in a buffer whose positions move.
--
-- ONE argument after the verb, and it is an ARRAY. Every verb on this rail is
-- destructured Ruby-side as `verb, args`; 65_review records a verb that sent
-- flat positionals and had everything after the first dropped on the floor.
--
-- The buffer check is NOT redundant with the buffer-local map below. `define`
-- makes every :Lain* command GLOBAL and this one reads the CURRENT window's
-- cursor, so hand-typed from lain://journal line 7 it would open whatever file
-- the sidebar lists on ITS line 7 -- a file the human never looked at. Hand
-- typing is an invited path precisely because the map invokes the command.
--
-- Every line is sent, with no runtime-side test of whether it holds a file: the
-- legend, a commit header and the empty-state placeholder all name none, and
-- Ruby -- which drew them and owns the line -> target map -- is the only side
-- that can say so. It answers with a refusal the human sees on the same rail a
-- refused :LainReviewDone answers on, which is a better outcome than a lua-side
-- pattern match on rendered text that would have to be kept in step with it.
define("LainReviewOpen", function()
  local buf = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_get_name(buf) ~= review_sidebar.NAME then
    vim.notify("lain: :LainReviewOpen opens the file under the cursor in " .. review_sidebar.NAME,
      vim.log.levels.WARN)
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
-- ACKED, so nothing here reads a return value: a refusal comes back on the
-- rail `__lain.review_refused` renders, exactly as a refused open does.
define("LainReviewMark", function(opts)
  local buf = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_get_name(buf) ~= review_sidebar.NAME then
    vim.notify("lain: :LainReviewMark marks the row under the cursor in " .. review_sidebar.NAME,
      vim.log.levels.WARN)
    return
  end
  local state = opts.fargs[1]
  if review_sidebar.MARK_KEYS[state] == nil then
    error("lain: :LainReviewMark's argument is the state -- one of " ..
      table.concat(review_sidebar.states(), ", ") .. " -- got " .. tostring(state), 0)
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
-- IT IS THEN ANSWERED AND NOT RE-RAISED, and the correction is worth stating
-- because the comment here used to draw the opposite conclusion from the same
-- true measurement. The measurement stands: any error escaping a `define`d
-- callback gets nvim's own `stack traceback:` appended however it was raised --
-- `error(msg, 0)` included, and re-raising a caught error from inside a `pcall`
-- included -- because the traceback is nvim's outer wrapper's doing and not
-- this function's. What the old comment got wrong was reading that as a limit
-- on the REFUSAL rather than on RAISING. A refusal does not have to raise. So
-- it goes out on `__lain.review_refused` (`65_review.lua`), which is where
-- `:LainReviewMark`'s refusals above already land and what `:LainReviewDone`
-- switched to for exactly this reason -- and the human gets lain's sentence
-- with no traceback under it. `48_annotate`'s `:LainNoteDone` is the third
-- site and keeps the same shape.
--
-- BE EXACT ABOUT WHAT THAT BUYS, because the first draft of this comment
-- overclaimed and a doc sentence went out with it. The TRACEBACK is gone; the
-- hit-enter prompt is not always. `nvim_echo` of a message longer than the
-- window still pages -- measured with a UI attached at 80 columns,
-- `NoReviewWrites::UNOPENED` (134 chars with the `lain: ` prefix) leaves
-- `nvim_get_mode` reading `{mode = "r", blocking = true}`, while the same
-- message at width 200, and a short one at width 80, do not. So this trades a
-- CRASH for a long MESSAGE, which is the whole of the claim: the traceback and
-- the raise are gone, and a narrow window can still ask for a keypress to read
-- lain's own sentence.
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

-- The add-to-survey gesture (B16), the wire half of accretion (B12). It lives
-- here rather than getting its own file because this module already carries
-- two of the four gestures reaching `Gestures#routes`
-- (`human_replies.rb:609-611`) -- `review_open`/`review_mark` above -- and
-- `survey_add` is the third; `51_thread.lua`'s `review_ask` is the fourth. What
-- differs from every keymap above is the BUFFER: a sidebar row is a NAME this
-- runtime knows ahead of time to scope a `BufEnter` to, but a survey grows from
-- WHATEVER FILE the human is reading, and there is no name to scope that to --
-- so the command and its keymap are GLOBAL, never buffer-local.
--
-- `<leader>` rather than a bare letter, the one place this departs from its
-- siblings' shape: `x`/`u`/`<CR>` are safe to claim on `review_sidebar.buf()`,
-- which is `nomodifiable` with nothing to type into (see the `u` comment
-- above) -- but the buffer this fires from is the human's own real, EDITABLE
-- file, where a bare `a` would cost them vim's own append.
--
-- ACKED, `review_open`/`review_mark`'s shape, and this card proves emission
-- only: nothing here reads a return value, and an unrouted verb is not a raise
-- -- `Router#call`'s `@routes[verb]&.call(...)` (`rpc_thread.rb:741`) is a
-- silent no-op for a verb its table does not carry, and the ack
-- (`respond(request.id, true)`, `rpc_thread.rb:1118-1121`) has already
-- returned by the time that runs. So today, ahead of B12, pressing this key
-- sends `survey_add` into {Lain::Frontend::Neovim::RpcThread#command_inbox}
-- for nobody yet to drain -- the editor is never blocked or raised through.
--
-- The PATH is forced through `:p`, `47_diff.lua`'s `review_diff.absolute`
-- idiom, rather than trusted as `nvim_buf_get_name` hands it back: a buffer
-- opened by a relative `:edit` answers with that relative name until
-- something forces it, and B12's own escalation list names a relative path as
-- a payload it cannot resolve. GENERATION rides whatever
-- `b:lain_view_generation` the buffer already carries -- the generic rendering
-- stamp `45_views.lua`'s `set_view` sends only when a gesture needs one -- and
-- is nil for an ordinary file, exactly as unstamped there. Deciding what a
-- survey's own generation means is B12's open design question, not this
-- card's to answer.
--
-- UNSTAMPED is not the only nil case a receiver may see: a Lua table literal
-- `{ path, gen }` with `gen == nil` TRUNCATES before it crosses msgpack (Lua's
-- array part stops at the first hole), so an unstamped buffer's payload
-- arrives Ruby-side as the ONE-element `[path]`, not `[path, nil]`. Harmless
-- (`Array#[]` past the end answers `nil` either way), but the ARITY itself is
-- therefore not a fixed contract -- worth knowing before indexing past 0.
--
-- Every OTHER buffer-guard in this module (see `LainReviewOpen`/
-- `LainReviewMark` above, and `:LainPin`'s own spec at
-- `neovim_spec.rb:416`) refuses when fired from the wrong buffer and SAYS SO,
-- rather than acting on whatever is current. An empty name alone is not
-- enough of a guard here: every lain:// buffer HAS a name (`lain://timeline`,
-- `lain://review`, ...) and would otherwise sail through and be sent as a
-- "path". `buftype ~= ""` is the real discriminator, `47_diff.lua`'s own:
-- `buftype = ""` is what makes the diff's new side "THE FILE" rather than a
-- scratch copy, and it is exactly what every lain:// buffer (`nofile`,
-- `acwrite`) is not.
define("LainSurveyAdd", function()
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or vim.bo[buf].buftype ~= "" then
    vim.notify("lain: :LainSurveyAdd needs a real file buffer, not " ..
      (name == "" and "an unnamed one" or name), vim.log.levels.WARN)
    return
  end
  vim.rpcrequest(chan, "lain_command", "survey_add",
    { vim.fn.fnamemodify(name, ":p"), vim.b[buf].lain_view_generation })
end)

vim.keymap.set("n", "<leader>sa", "<Cmd>LainSurveyAdd<CR>",
  { desc = "lain: add the current file to the open survey" })
