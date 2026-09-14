# frozen_string_literal: true

require "fileutils"
require "neovim"
require "socket"
require "timeout"
require "tmpdir"

# `runtime/51_thread.lua` and {Lain::Frontend::Neovim::ThreadView} -- one
# anchor's conversation, shown in the diff pane the cursor is NOT in, swapped as
# the cursor moves.
#
# Its OWN nvim harness rather than an append to `neovim_runtime_spec.rb`, for
# `layout_spec.rb`'s and `diff_mode_spec.rb`'s reason: what is under test is what
# the editor does with windows and buffers as a cursor moves through them, and a
# frontend in front of that would mean every assertion had to first prove the
# frontend was not the thing that moved.
#
# ⚠️ THE CURSOR HAS TO MOVE FOR REAL. `nvim_win_set_cursor` does NOT fire
# CursorMoved -- it is an API call, not a motion -- so every example below drives
# the cursor with `normal!` in a window it has actually focused, which is the
# only version of these scenarios that exercises the trigger the capability is
# built on. Measured: `nvim_win_set_cursor` fires nothing, `normal! 20G` fires
# once, `normal! l` fires once.
module ThreadFixture
  FILES = {
    "docs/counter.txt" => (1..40).map { |i| "line #{i}" },
    "docs/other.txt" => (1..12).map { |i| "other #{i}" }
  }.freeze

  PROJECT = Dir.mktmpdir("lain-thread-spec")

  FILES.each do |path, lines|
    FileUtils.mkdir_p(File.join(PROJECT, File.dirname(path)))
    File.write(File.join(PROJECT, path), "#{lines.join("\n")}\n")
  end

  # A CursorMoved firing is NOT synchronous with the `normal!` that triggers it --
  # measured, under load, straddling `watch_calls` below: `nvim_command("normal!
  # 21G")` can return to Ruby before nvim has dispatched the CursorMoved it
  # queued, and the dispatch then happens on whatever RPC request arrives next.
  # A `move_to` that just returns after the command races that dispatch against
  # every following line, which is a spec defect (`move_to` assuming a duration,
  # not a condition) and not a product one -- `51_thread.lua`'s own idempotency
  # guard is what a delayed run of `refresh` still has to satisfy, and it does.
  # This tick is the condition: it runs in the SAME group-ordering position
  # `51_thread.lua`'s own callback does (registered after it, at runtime load,
  # so `refresh` has already applied for this dispatch by the time the tick
  # advances), and `move_to` below polls it rather than trusting the round trip.
  CURSOR_TICK_PROBE = <<~LUA
    _G.__cursor_tick = 0
    vim.api.nvim_create_autocmd("CursorMoved", {
      callback = function() _G.__cursor_tick = _G.__cursor_tick + 1 end,
    })
  LUA

  # The two API calls the "does not re-render" AC names, counted at the source.
  # Both are read off `vim.api`/`vim.keymap` at CALL time by the runtime, so a
  # shim installed here is what the module actually reaches. In a constant for
  # `DiffModeFixture::PROBE_AUTOCMD`'s reason -- long lua belongs beside the
  # fixture, not inside a helper.
  COUNTING_SHIM = <<~LUA
    _G.__thread_probe = { set_buf = 0, keymap = 0 }
    local set_buf, keymap = vim.api.nvim_win_set_buf, vim.keymap.set
    vim.api.nvim_win_set_buf = function(...)
      _G.__thread_probe.set_buf = _G.__thread_probe.set_buf + 1
      return set_buf(...)
    end
    vim.keymap.set = function(...)
      _G.__thread_probe.keymap = _G.__thread_probe.keymap + 1
      return keymap(...)
    end
  LUA

  # `vim.rpcrequest` replaced by a recorder -- `review_view_spec.rb`'s idiom, and
  # the only way to see the wire without a Ruby end serving requests.
  WRITE_PROBE = <<~LUA
    local target, should_fail = ...
    local seen = nil
    local original = vim.rpcrequest
    vim.rpcrequest = function(_, method, verb, args)
      seen = { method, verb, args }
      if should_fail then error("no editor took this", 0) end
      return true
    end
    local ok, err = pcall(function()
      vim.api.nvim_buf_call(target, function() vim.cmd("write") end)
    end)
    vim.rpcrequest = original
    return { seen = seen, ok = ok, err = tostring(err), modified = vim.bo[target].modified }
  LUA

  # The same deaf wire as `WRITE_PROBE`'s failing leg, but replaced for GOOD:
  # the examples that drive `:w` as keystrokes have no lua block to restore it
  # in, because the write happens after the call that set this up has returned.
  DEAF_RPC = <<~LUA
    vim.rpcrequest = function() error("no editor took this", 0) end
  LUA

  # `review_refused` ANSWERS with the line it put on SCREEN, and its own doc
  # calls that the sole witness of what a human actually saw: the fitted line is
  # echoed with `history = false`, so `:messages` holds the unshortened sentence
  # and not the one the human read. Wrapping the rail is the only way to get that
  # answer back out of a callback that discards it.
  # ONE spelling of the message-history read: `messages` runs it on the
  # example's own connection and `spoke?` on a throwaway one, and the two must
  # not be able to disagree about what "the history" is.
  MESSAGES = "return vim.api.nvim_exec2('messages', { output = true }).output"

  RAIL_PROBE = <<~LUA
    _G.__thread_rail = {}
    local real = _G.__lain.review_refused
    _G.__lain.review_refused = function(message)
      local shown = real(message)
      table.insert(_G.__thread_rail, shown)
      return shown
    end
  LUA

  at_exit { FileUtils.remove_entry(PROJECT) if File.directory?(PROJECT) }
end

RSpec.describe Lain::Frontend::Neovim, "the review thread pane", :nvim do
  around do |example|
    headless_editor("lain-nvim-thread-spec", chdir: ThreadFixture::PROJECT, runtime: true) do
      # The cursor probe rides with the runtime: every example in this file reads
      # what it recorded, so an editor without it is an editor no example can use.
      @editor.exec_lua(ThreadFixture::CURSOR_TICK_PROBE, [])
      example.run
    end
  end

  def lua(source, args = []) = @editor.exec_lua(source, args)

  def revisions = { "old" => "base0ff", "new" => "head1ff" }

  def counter_old_lines = (1..40).map { |i| i == 20 ? "was line 20" : "line #{i}" }

  # The file under review, opened as `47_diff.lua`'s pair. Every example starts
  # here because a thread pane with no diff pair has nothing to be opposite of.
  def open_counter(line = 1, at: revisions)
    lua("_G.__lain.open_changeset(...)", ["docs/counter.txt", counter_old_lines, line, at])
  end

  def open_other(line = 1)
    lua("_G.__lain.open_changeset(...)", ["docs/other.txt", (1..12).map { |i| "other #{i}" }, line, revisions])
  end

  # The thread pane's entry point. The anchor rides as a TABLE -- its id AND the
  # position the pane has to watch -- because the pane is cursor-driven and Ruby
  # is the only side that knows where an anchor sits (see `51_thread.lua`'s
  # header).
  def anchor(id:, line:, side: "new", path: "docs/counter.txt")
    { "id" => id, "path" => path, "side" => side, "line" => line }
  end

  def set_thread(anchor_table, lines) = lua("_G.__lain.set_thread(...)", [anchor_table, lines])

  def refusal(anchor_table, lines)
    lua("local ok, err = pcall(_G.__lain.set_thread, ...) return { ok, tostring(err) }", [anchor_table, lines])
  end

  # slot -> window, read off `41_layout.lua`'s window variables so this never calls
  # `review_layout`, which TAKES FOCUS and would destroy what half these
  # examples assert.
  def slots
    # A lua table with no entries crosses msgpack as an ARRAY, and "the human
    # closed the whole review" is now a state these examples reach on purpose --
    # so it answers an empty Hash rather than something `["old"]` raises on.
    found = lua(<<~LUA)
      local found = {}
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local slot = vim.w[win].lain_review_slot
        if slot then found[slot] = win end
      end
      return found
    LUA
    found.is_a?(Hash) ? found : {}
  end

  def buf_in(win) = lua("return vim.api.nvim_win_get_buf(...)", [win])

  def lines_of(buf) = lua("return vim.api.nvim_buf_get_lines(..., 0, -1, false)", [buf])

  def name_of(buf) = lua("return vim.api.nvim_buf_get_name(...)", [buf])

  def buffer_var(buf, name) = lua("local b, v = ... return vim.b[b][v]", [buf, name])

  def here = lua("return vim.api.nvim_get_current_win()")

  def enter(win) = lua("vim.api.nvim_set_current_win(...)", [win])

  # A REAL motion, in whichever window is current -- see the file header.
  # Waits on `CURSOR_TICK_PROBE`'s counter rather than trusting the round trip:
  # the constant's comment is the measurement, and `ticked_motion` is the fix --
  # a condition, not a duration, so a slow dispatch is waited out rather than
  # raced.
  def move_to(row) = ticked_motion { @editor.command("normal! #{row}G") }

  def move_right = ticked_motion { @editor.command("normal! l") }

  # THE GUARD ABOVE THE WAIT: CursorMoved does not fire at all when the motion
  # did not actually move anything (`move_to` onto the line the cursor already
  # sits on, in `open_counter`'s default position) -- vim's own rule, not a
  # gap in the probe. The command's own reply already carries the real,
  # non-deferred cursor position (only the AUTOCMD dispatch is what races), so
  # comparing positions before and after is what tells a genuine no-op apart
  # from a motion still in flight, and only the latter has anything to wait for.
  def ticked_motion
    before_tick = lua("return _G.__cursor_tick")
    before_pos = cursor_position
    yield
    return if cursor_position == before_pos

    wait_until(reason: "CursorMoved to settle after a motion") { lua("return _G.__cursor_tick") > before_tick }
  end

  def cursor_position
    lua("local c = vim.api.nvim_win_get_cursor(0) return { vim.api.nvim_get_current_win(), c[1], c[2] }")
  end

  def window_options(win)
    lua("local w = ... return { diff = vim.wo[w].diff, foldmethod = vim.wo[w].foldmethod }", [win])
      .transform_keys(&:to_sym)
  end

  # Which 1-based lines this window is actually HIDING. `foldmethod == "diff"` is
  # an option; a fold count is evidence that the diff is live.
  def folded_lines(win, count = 40)
    lua(<<~LUA, [win, count])
      local w, n = ...
      local hidden = {}
      vim.api.nvim_win_call(w, function()
        for i = 1, n do
          if vim.fn.foldclosed(i) ~= -1 then table.insert(hidden, i) end
        end
      end)
      return hidden
    LUA
  end

  def watch_calls = lua(ThreadFixture::COUNTING_SHIM)

  def calls = lua("return _G.__thread_probe").transform_keys(&:to_sym)

  def thread_buffers
    lua(<<~LUA)
      local found = {}
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.b[buf].lain_thread_anchor ~= nil then
          table.insert(found, { buf, vim.b[buf].lain_thread_anchor })
        end
      end
      return found
    LUA
  end

  def wipe(buf) = lua("vim.api.nvim_buf_delete(..., { force = true })", [buf])

  # `:bdelete`, one letter from `:bwipeout` and a completely different fact:
  # nvim UNLOADS the buffer, clearing every buffer-local variable, and keeps the
  # buffer and its name. See the husk examples below.
  def bdelete(buf) = lua("vim.cmd('bdelete! ' .. ...)", [buf])

  def loaded?(buf) = lua("return vim.api.nvim_buf_is_loaded(...)", [buf])

  # What the DIFF buffer remembers about its anchors -- the module's actual
  # bookkeeping, and the place a wipe leaves residue. `thread_buffers` cannot
  # see it: that walks `nvim_list_bufs()`, which a wiped buffer leaves by
  # definition.
  def held_anchors(buf) = lua("return vim.b[...].lain_thread_anchors", [buf])

  def anchor_marks(buf)
    lua(<<~LUA, [buf])
      local b = ...
      return vim.api.nvim_buf_get_extmarks(b, vim.api.nvim_create_namespace("lain_thread_anchors"), 0, -1, {})
    LUA
  end

  def tabpages = lua("return #vim.api.nvim_list_tabpages()")

  def windows = lua("return #vim.api.nvim_list_wins()")

  def listed = lua("return vim.fn.getbufinfo({ buflisted = 1 })").map { |info| info["name"] }

  def close_window(win) = lua("vim.api.nvim_win_close(..., true)", [win])

  def buffer_maps(buf, lhs)
    lua(<<~LUA, [buf, lhs])
      local b, key = ...
      local found = {}
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do
        if map.lhs == key then table.insert(found, map.desc or "") end
      end
      return found
    LUA
  end

  # A real motion in a real window on this buffer, so `]]`/`[[` resolve through
  # whatever mapping the buffer actually carries.
  def motion(buf, from, keys)
    lua(<<~LUA, [buf, from, keys])
      local target, row, sequence = ...
      local win = vim.api.nvim_open_win(target, true, { split = "below" })
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      vim.cmd("normal " .. sequence)
      local landed = vim.api.nvim_win_get_cursor(win)[1]
      vim.api.nvim_win_close(win, true)
      return landed
    LUA
  end

  def written(buf, fail: false) = lua(ThreadFixture::WRITE_PROBE, [buf, fail])

  def append(buf, lines)
    lua("local b, l = ... vim.api.nvim_buf_set_lines(b, -1, -1, false, l)", [buf, lines])
  end

  # nvim's own message history, which is where `__lain.review_refused` echoes
  # and where a `stack traceback:` would land -- so one read answers both halves
  # of "a refusal is not a crash".
  def messages = lua(ThreadFixture::MESSAGES, [])

  # `:w` as a human types it, in a real window on the thread buffer.
  #
  # KEYSTROKES AND NOT A LUA CALL, because the two spellings witness different
  # editors. Measured here: an error out of a NOTIFIED `nvim_exec_lua` is
  # discarded by nvim -- `:messages` stays empty and the editor reads
  # `blocking = false` -- so a write driven that way cannot see the traceback or
  # the prompt behind it even when both are there. Typed `:w` reproduces round
  # 7's `{mode = "r", blocking = true}` exactly. `written` cannot serve either:
  # its `pcall` is the thing that swallows both.
  def type_write(buf)
    lua("vim.api.nvim_open_win(..., true, { split = 'below' })", [buf])
    @editor.session.notify(:nvim_input, ":w\r")
  end

  # Input is queued for the main loop, so a request behind it can be answered
  # before the keystrokes have run. Everything read after a typed `:w` waits for
  # the editor to have said something first.
  def said(timeout: 5)
    deadline = Time.now + timeout
    text = messages
    while text.strip.empty? && Time.now < deadline
      sleep 0.02
      text = messages
    end
    text
  end

  # The line the rail DISPLAYED, which is not the line `:messages` holds once a
  # sentence has to be shortened. Waits for the same reason `said` does.
  def shown_refusal(timeout: 5)
    deadline = Time.now + timeout
    seen = lua("return _G.__thread_rail", [])
    while (seen.nil? || seen.empty?) && Time.now < deadline
      sleep 0.02
      seen = lua("return _G.__thread_rail", [])
    end
    Array(seen).last.to_s
  end

  # Insurance, not a gesture: `nvim_input` is one of the two calls answered WHILE
  # nvim is blocked on a hit-enter prompt, so pressing it before any read means a
  # failing expectation below reads as the expectation that failed rather than as
  # a mystery timeout on the read that queued behind the prompt.
  def press_enter = @editor.session.request(:nvim_input, "\r")

  # `neovim_runtime_spec.rb`'s "the refusal rail's width" apparatus, for its
  # reason: measured on nvim 0.12, an editor with NO UI never raises the
  # hit-enter prompt at all, so a headless connection cannot witness this defect.
  def attach_ui(columns: 60, lines: 20)
    @editor.session.request(:nvim_ui_attach, columns, lines, { "rgb" => true, "ext_linegrid" => true })
  end

  # Sampled across a window and never exited early on a `false`: `nvim_get_mode`
  # is answered while the main loop is busy, so it can answer before the
  # keystrokes queued ahead of it have run, and an early "not blocking" would be
  # a pass taken before the subject acted.
  def settled_mode(window: 0.5)
    deadline = Time.now + window
    modes = [@editor.session.request(:nvim_get_mode)]
    while Time.now < deadline
      sleep 0.02
      modes << @editor.session.request(:nvim_get_mode)
    end
    modes.find { |mode| mode["blocking"] } || modes.last
  end

  # The operational half of the finding: a non-fast request queues behind the
  # main loop and never comes back while a prompt stands. On a SECOND connection
  # deliberately -- an abandoned request on `@editor` leaves a response pending
  # there, which the `ensure` clearing the prompt would then read as its own.
  def round_trip(timeout: 5)
    probe = Neovim.attach_unix(@socket)
    Timeout.timeout(timeout) { probe.session.request(:nvim_eval, "1 + 1") }
  rescue Timeout::Error
    :timed_out
  ensure
    probe&.session&.shutdown
  end

  # `48_annotate.lua`'s own gesture, driven as the command a human types: the
  # marker this card's refusal reads is placed by `review_notes.place` off the
  # CURRENT window's cursor, so the note lands wherever `move_to` last left it.
  def place_note(kind, text) = @editor.command("LainNote #{kind} #{text}")

  # `:LainThread` as a human types it, answering the settled mode and the slice
  # of `:messages` this one command added.
  #
  # THE DELTA AND NOT THE WHOLE HISTORY: `raising_blocks` deliberately leaves a
  # `stack traceback:` in it, so an example asserting that string's absence over
  # the full buffer would fail on its own guard.
  def typed_refusal
    before = messages
    @editor.session.notify(:nvim_input, ":LainThread\r")
    mode = mode_once_spoken(before)
    clear_prompt
    wait_until(reason: "the refusal to reach :messages") { messages.length > before.length }
    [mode, messages[before.length..]]
  end

  # STRUCTURAL RATHER THAN TIMED, and the panel's NIT: a fixed sampling window
  # can end before the command it is sampling has run, and would then report
  # "not blocking" for the wrong reason. This ends on a FACT.
  #
  # A hit-enter prompt does not clear itself, so once it is up `nvim_get_mode`
  # keeps reporting it and there is no window to miss -- what has to be waited
  # for is the command having RUN. Its two witnesses are the prompt itself (fast,
  # answered straight through it) and the sentence reaching `:messages` (only
  # askable while nothing is blocking), so polling both ends the wait either way.
  def mode_once_spoken(before)
    wait_until(reason: ":LainThread to speak or to block") do
      @editor.session.request(:nvim_get_mode)["blocking"] || spoke?(before)
    end
    @editor.session.request(:nvim_get_mode)
  end

  # ON ITS OWN CONNECTION, `round_trip`'s reason one leg earlier. This read is
  # non-fast, so a prompt raised in the gap after the mode check above queues it
  # forever -- and abandoning it on `@editor` would leave a response pending
  # there that `clear_prompt`'s next read would collect as its own.
  def spoke?(before)
    probe = Neovim.attach_unix(@socket)
    Timeout.timeout(0.3) { probe.exec_lua(ThreadFixture::MESSAGES, []).length > before.length }
  rescue Timeout::Error
    false
  ensure
    probe&.session&.shutdown
  end

  # Only ever presses when a prompt is actually standing: a stray `\r` in normal
  # mode is a cursor motion, and the examples here place notes by cursor row.
  # Loops because a traceback can span more screens than one prompt clears.
  def clear_prompt
    wait_until(reason: "any hit-enter prompt to clear") do
      blocking = @editor.session.request(:nvim_get_mode)["blocking"]
      press_enter if blocking
      !blocking
    end
  end

  # THE NON-VACUITY GUARD: a command that really does `error()`, driven exactly
  # as the refusals are, on the same attached UI. If this does not block, the
  # apparatus cannot witness the defect and the three passes it precedes mean
  # nothing. Measured by a panel probe at 120 columns as `raise=true,
  # notify=false`, so it separates a raise from a message rather than from
  # silence.
  def raising_blocks
    lua(<<~LUA)
      vim.api.nvim_create_user_command("LainThreadSpecRaise", function() error("deliberate") end, {})
    LUA
    @editor.session.notify(:nvim_input, ":LainThreadSpecRaise\r")
    settled_mode["blocking"].tap { clear_prompt }
  end

  # `:LainThread` refuses on `__lain.review_refused`, so the line a human SAW is
  # the one the rail answered with -- `RAIL_PROBE`'s whole reason. `pcall` still
  # wraps the command because "it refused rather than raised" is half of what
  # every example below pins.
  def refused_thread
    lua(ThreadFixture::RAIL_PROBE)
    lua(<<~LUA)
      local ok, err = pcall(vim.cmd, "LainThread")
      return { ok = ok, err = tostring(err), shown = _G.__thread_rail }
    LUA
  end

  describe "following the cursor" do
    # The card's first AC. An implementation that showed the thread in the
    # cursor's OWN pane, or in the sidebar, satisfies "a thread is displayed"
    # and fails this.
    it "shows the anchored thread in the pane the cursor is not in" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["## you", "why this way?"])
      enter(slots["new"])
      move_to(1)

      move_to(20)

      pane = buf_in(slots["old"])
      expect(buffer_var(pane, "lain_thread_anchor")).to eq("a-20")
      expect(lines_of(pane)).to eq(["## you", "why this way?"])
      # The cursor's own side is untouched: swapping the pane the human is
      # READING is the one thing this must never do.
      expect(name_of(buf_in(slots["new"]))).to end_with("docs/counter.txt")
    end

    # The mirror image, and the mutant this kills is the obvious one: a module
    # that always places into "old" passes every new-side example in this file.
    it "shows an old-side anchor's thread in the NEW pane" do
      open_counter
      set_thread(anchor(id: "a-old", line: 3, side: "old"), ["## you", "and this?"])
      enter(slots["old"])
      move_to(1)

      move_to(3)

      expect(buffer_var(buf_in(slots["new"]), "lain_thread_anchor")).to eq("a-old")
      expect(name_of(buf_in(slots["old"]))).to include("lain://review/OLD/docs/counter.txt")
    end

    # Two anchors, so "the thread buffer for that annotation" is a claim about
    # WHICH one -- an implementation holding a single thread buffer passes the
    # example above.
    it "shows the thread belonging to the line under the cursor, not the last one sent" do
      open_counter
      set_thread(anchor(id: "a-12", line: 12), ["twelve"])
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      enter(slots["new"])

      move_to(12)
      at_twelve = lines_of(buf_in(slots["old"]))
      move_to(20)

      expect(at_twelve).to eq(["twelve"])
      expect(lines_of(buf_in(slots["old"]))).to eq(["twenty"])
    end

    # The idempotency guard octo does not have on its show path. Counted at the
    # two API calls the AC names, and the counters are proved live in the same
    # example: the show moves both, the column move moves neither.
    it "sets no buffer and registers no keymap when the cursor moves within an annotated line" do
      open_counter
      enter(slots["new"])
      move_to(1)
      watch_calls
      set_thread(anchor(id: "a-20", line: 20), ["## you", "why this way?"])
      move_to(20)
      shown = calls

      move_right
      move_right

      expect(shown[:set_buf]).to be_positive
      expect(shown[:keymap]).to be_positive
      expect(calls).to eq(shown)
    end

    # The other half of octo's re-run: its show path re-registers keymaps every
    # time it fires. The guard above hides that from a column move, so this
    # asserts the stronger property the design actually has -- the maps belong
    # to the buffer's construction, so a second show cannot re-register them.
    # `set_buf` moving is what keeps it honest: the show really did happen.
    it "registers the thread's keymaps when the buffer is made, not on every show" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      enter(slots["new"])
      move_to(20)
      move_to(21)
      watch_calls

      move_to(20)

      expect(calls[:set_buf]).to be_positive
      expect(calls[:keymap]).to eq(0)
    end

    it "restores the diff when the cursor moves off the annotated line" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      enter(slots["new"])
      move_to(20)

      move_to(21)

      expect(name_of(buf_in(slots["old"]))).to include("lain://review/OLD/docs/counter.txt")
      expect(lines_of(buf_in(slots["old"]))).to eq(counter_old_lines)
    end

    it "does not re-place the diff on every further move once it is back" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      enter(slots["new"])
      move_to(20)
      move_to(21)
      watch_calls

      move_to(22)
      move_to(23)

      expect(calls[:set_buf]).to eq(0)
    end

    # THE ONE STATED EXCEPTION to "a render moves nobody", and it had six lines
    # of justification in two files and no coverage: every other example here
    # moves the cursor after `set_thread`, so a mutant deleting the closing
    # `refresh()` survived the whole file. A human already standing on the
    # anchored line has no further motion to trigger the pane.
    it "shows a thread that arrives while the human is already standing on its line" do
      open_counter
      enter(slots["new"])
      move_to(20)

      set_thread(anchor(id: "a-20", line: 20), ["twenty"])

      expect(buffer_var(buf_in(slots["old"]), "lain_thread_anchor")).to eq("a-20")
      expect(here).to eq(slots["new"])
    end

    # Deterministic, and it is the module's stated tie-break rather than
    # whichever entry `pairs()` happened to yield: `nvim_buf_get_extmarks`
    # answers in position then id order, so the FIRST mark placed on a row wins.
    it "shows the thread anchored first when two anchors share a line" do
      open_counter
      set_thread(anchor(id: "a-first", line: 20), ["first"])
      set_thread(anchor(id: "a-second", line: 20), ["second"])
      enter(slots["new"])

      move_to(20)

      expect(buffer_var(buf_in(slots["old"]), "lain_thread_anchor")).to eq("a-first")
    end

    # UNLISTED, against a doc promise: a review carries one thread buffer per
    # note, and thirty of them in `:ls` and `:bnext` would bury the human's own
    # files. Asserted against the buffers a review already lists, so "nothing is
    # listed" cannot pass it vacuously.
    it "leaves the human's own buffer list to the human's own files" do
      open_counter
      (1..5).each { |i| set_thread(anchor(id: "a-#{i}", line: i * 4), ["thread #{i}"]) }

      expect(listed.grep(%r{lain://thread/})).to be_empty
      expect(listed.grep(%r{lain://review/OLD/|docs/counter\.txt})).not_to be_empty
    end

    # 20_buffers' post-render announcement, which is the stable surface a
    # human's own config hooks. Dropping it changed nothing any example could
    # see.
    it "announces the render on lain's own User event" do
      open_counter
      lua(<<~LUA)
        _G.__thread_seen = {}
        vim.api.nvim_create_autocmd("User", { pattern = "LainRender",
          callback = function(ev) table.insert(_G.__thread_seen, ev.data.name) end })
      LUA

      set_thread(anchor(id: "a-20", line: 20), ["twenty"])

      expect(lua("return _G.__thread_seen")).to eq(["lain://thread/a-20"])
    end

    # THE EXTMARK CONTRACT: the anchor is a mark, not a line number, so an edit
    # above it moves the position the pane watches. A line-number registry
    # passes every other example here and fails this one.
    it "follows the line as the human edits above it" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      enter(slots["new"])
      lua("vim.api.nvim_buf_set_lines(..., 0, 0, false, { 'inserted a', 'inserted b' })",
          [buf_in(slots["new"])])

      move_to(20)
      at_old_line = buffer_var(buf_in(slots["old"]), "lain_thread_anchor")
      move_to(22)

      expect(at_old_line).to be_nil
      expect(buffer_var(buf_in(slots["old"]), "lain_thread_anchor")).to eq("a-20")
    end
  end

  describe "native diff mode" do
    # THE SECOND ESCALATION TRIGGER, measured rather than assumed. octo calls
    # `diffoff!` on the thread buffer; in this editor that would be both
    # unnecessary and harmful, because 'diff', 'foldmethod', 'scrollbind' and
    # 'wrap' are window-local PER BUFFER -- nvim swaps them with the buffer.
    it "shows the thread out of diff mode while the cursor's own side stays in it" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      enter(slots["new"])

      move_to(20)

      expect(window_options(slots["old"])).to include(diff: false)
      expect(window_options(slots["new"])).to include(diff: true, foldmethod: "diff")
    end

    # The other half: a restored diff is a LIVE diff, not merely a buffer back
    # in a window -- and it keeps the folds the human had open, which an
    # unconditional `diffthis` on the restore path destroys (measured: it
    # re-closes every fold, 14 hidden lines -> 27).
    it "restores a live diff with the folds the human was reading" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      enter(slots["new"])
      before = folded_lines(slots["old"])

      move_to(20)
      move_to(21)

      expect(window_options(slots["old"])).to include(diff: true, foldmethod: "diff")
      expect(folded_lines(slots["old"])).to eq(before)
      expect(before).not_to be_empty
    end
  end

  # A RENDER may rebuild what the human clobbered; a CURSOR MOVE may not. The
  # first cut of this module made no such distinction and a review panel found
  # both halves of the cost: one `20G` in the human's own file, after they had
  # closed the review tabpage, materialised a whole review tabpage; and closing
  # the thread pane and moving one column brought it straight back, so the pane
  # could not be dismissed at all.
  describe "a layout the human has clobbered" do
    it "rebuilds the closed pane and shows the thread in the rebuilt window" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      enter(slots["new"])
      move_to(20)
      closed = slots["old"]
      close_window(closed)

      set_thread(anchor(id: "a-20", line: 20), ["twenty", "and more"])

      rebuilt = slots["old"]
      expect(rebuilt).not_to eq(closed)
      expect(buffer_var(buf_in(rebuilt), "lain_thread_anchor")).to eq("a-20")
    end

    # A review panel found a repair that stole focus, invisible to the suite
    # because the no-focus-theft example only exercised the INTACT path. This is
    # that example pinned on the repair path.
    it "leaves the human where they were while it rebuilds" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      enter(slots["new"])
      move_to(20)
      close_window(slots["old"])
      reading = here

      set_thread(anchor(id: "a-20", line: 20), ["twenty", "and more"])

      expect(here).to eq(reading)
    end

    it "leaves the human where they were on the intact path too" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      enter(slots["new"])
      reading = here

      move_to(20)

      expect(here).to eq(reading)
    end

    # THE PANE IS THE HUMAN'S TO CLOSE. `shown` answers nil when there is no
    # pane, so "what the cursor wants" and "what the pane shows" differ forever
    # -- and a module that repairs on the trigger therefore reopens the window
    # on the very next column move. Both moves are asserted: one onto a fresh
    # note, so the guard is not merely reading "nothing changed".
    it "leaves the thread pane closed when the human closes it, however far the cursor moves" do
      open_counter
      set_thread(anchor(id: "a-12", line: 12), ["twelve"])
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      enter(slots["new"])
      move_to(20)
      close_window(slots["old"])
      after_close = slots.keys.sort

      move_right
      move_to(12)

      expect(after_close).to eq(%w[new sidebar])
      expect(slots.keys.sort).to eq(%w[new sidebar])
    end

    # Closing the review tabpage IS the human's dismiss gesture (41_layout says
    # so). `unstamp` only runs on the next `open_changeset`, so the new side --
    # a real file buffer that outlives the review -- keeps its stamp and its
    # anchors, the bail-out does not bail, and a module that repaired on the
    # trigger answered a motion in the human's own tabpage by building a
    # three-window review out of nothing.
    it "builds no review tabpage from a cursor move after the human closed the review" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      enter(slots["new"])
      lua("vim.cmd('tabclose')")
      lua("vim.cmd('edit docs/counter.txt')")

      move_to(20)
      move_to(21)

      expect(tabpages).to eq(1)
      expect(windows).to eq(1)
      expect(lua("return vim.v.errmsg")).to eq("")
    end

    # A RENDER still may, which is the other half of the split and is what the
    # AC asks for: 41_layout's own reasoning is that the review is still open
    # and dropping the render would lose it. Same starting state as the example
    # above -- the review dismissed, the human back in the file it stamped, the
    # cursor on the anchored line, which is where a motion built nothing.
    it "rebuilds the review tabpage for a render that arrives after the dismissal" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      enter(slots["new"])
      lua("vim.cmd('tabclose')")
      lua("vim.cmd('edit docs/counter.txt')")
      move_to(20)

      set_thread(anchor(id: "a-20", line: 20), ["twenty", "and more"])

      expect(tabpages).to eq(2)
      expect(slots.keys).to contain_exactly("sidebar", "old", "new")
      expect(buffer_var(buf_in(slots["old"]), "lain_thread_anchor")).to eq("a-20")
    end

    # THE REPAIR PATH IS NOT THE INTACT PATH. Window-local-per-buffer options
    # die with the window, and nvim takes the SURVIVOR of a diff pair out of
    # diff mode when one of them closes -- so a rebuilt pane comes back holding
    # the old side as a plain buffer: two panes that look like a review and diff
    # nothing. `open_changeset` re-establishes it through 47_diff's `pair()`;
    # this module is the only other caller of `review_place` for those buffers.
    # The folds are the evidence the diff is LIVE rather than merely optioned.
    it "restores a live diff into a pane that had to be rebuilt" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      enter(slots["new"])
      move_to(20)
      close_window(slots["old"])
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])

      move_to(21)

      expect(name_of(buf_in(slots["old"]))).to include("lain://review/OLD/docs/counter.txt")
      expect(window_options(slots["old"])).to include(diff: true, foldmethod: "diff")
      expect(folded_lines(slots["old"])).not_to be_empty
    end

    # THE SEATS' OWN SCENARIO, and the one the example above cannot reach: when
    # the pane is closed while it holds the DIFF, nvim takes the human's own
    # side out of diff mode too, so BOTH windows have to come back. (Closing it
    # while it holds a conversation leaves the reading side alone -- measured --
    # which is why one example is not enough.)
    it "restores BOTH sides of a pair the human broke by closing the diff pane" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      enter(slots["new"])
      close_window(slots["old"])
      broken = window_options(slots["new"])
      move_to(20)
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])

      move_to(21)

      expect(broken).to include(diff: false)
      expect(window_options(slots["new"])).to include(diff: true)
      expect(window_options(slots["old"])).to include(diff: true, foldmethod: "diff")
      expect(folded_lines(slots["old"])).not_to be_empty
    end

    # `review_place` REMEMBERS what it placed, on the TABPAGE, precisely so the
    # memory outlives the window -- so a slot told that a conversation is its
    # content resurrects that conversation into the diff slot on the next
    # unrelated render. "Which thread the pane shows is read off the pane rather
    # than remembered" is true of this module and was false of the system it
    # renders through. Driven through a real unrelated render (the sidebar),
    # because the defect is what `ensure()` rebuilds from, not what the variable
    # says.
    it "does not leave a conversation behind as the diff slot's remembered content" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      enter(slots["new"])
      move_to(20)
      close_window(slots["old"])

      lua("_G.__lain.set_review(...)", [["[ ] docs/counter.txt"], 1, Lain::Review::SIDES])

      expect(name_of(buf_in(slots["old"]))).to include("lain://review/OLD/docs/counter.txt")
    end

    # CONVERGENCE. The old side is a LISTED buffer, so a human tidying `:ls`
    # reaches it. With it gone the restore had nothing to place, the `if target
    # ~= nil` swallowed that, `shown` was never updated -- so the pane
    # permanently named a thread the cursor was nowhere near and the O(buffers)
    # scan re-ran on every keystroke. The guard has to be an equality the
    # failure path can reach.
    it "stops naming a thread the cursor has left, even with the diff buffer gone" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      enter(slots["new"])
      old_side = buf_in(slots["old"])
      move_to(20)
      wipe(old_side)
      watch_calls

      move_to(21)
      3.times { move_right }

      expect(buffer_var(buf_in(slots["old"]), "lain_thread_anchor")).to be_nil
      expect(calls[:set_buf]).to eq(1)
      expect(lua("return vim.v.errmsg")).to eq("")
    end
  end

  # The new side is a REAL file buffer: it is not wiped between files, it stays
  # listed, and 47_diff says outright that it outlives the review. So its
  # anchors and their extmarks outlive `unstamp` too, and a second review of the
  # same file used to re-stamp on top of the first one's -- showing threads from
  # a changeset nobody is looking at, at drifted mark positions. The entry
  # carries the revision it was registered against, which makes that
  # self-correcting in both directions.
  describe "a second review of the same file" do
    it "does not show a previous changeset's threads" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      open_other
      open_counter(1, at: { "old" => "base9ff", "new" => "head9ff" })
      enter(slots["new"])

      move_to(20)

      expect(buffer_var(buf_in(slots["old"]), "lain_thread_anchor")).to be_nil
      expect(name_of(buf_in(slots["old"]))).to include("lain://review/OLD/docs/counter.txt")
    end

    it "keeps them when it is the same changeset re-opened" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      open_other
      open_counter
      enter(slots["new"])

      move_to(20)

      expect(buffer_var(buf_in(slots["old"]), "lain_thread_anchor")).to eq("a-20")
    end
  end

  describe "thread buffers the human has wiped" do
    def five_threads
      (1..5).map do |i|
        set_thread(anchor(id: "a-#{i}", line: i * 4), ["thread #{i}"])
        thread_buffers.find { |_, id| id == "a-#{i}" }.first
      end
    end

    # ⚠️ REWRITTEN AFTER A REVIEW PANEL, and the reason is worth keeping. This
    # asserted `thread_buffers` was empty after wiping -- and `thread_buffers`
    # walks `nvim_list_bufs()`, which a wiped buffer leaves BY DEFINITION. No
    # implementation, correct or otherwise, could fail it: a probe planted a
    # deliberately stale octo-style module registry and it still read green.
    # What the module actually keeps is the DIFF buffer's `b:lain_thread_anchors`
    # and the namespace's extmarks, so that is what these two scan, and the
    # claim is the true one: the residue is BOUNDED (one entry and one mark per
    # anchor, however often a thread is sent) and INERT (the examples below).
    it "keeps one entry and one mark per anchor however often a thread is re-sent" do
      open_counter
      five_threads
      diff = buf_in(slots["new"])

      five_threads
      five_threads

      expect(held_anchors(diff).values.map { |entry| entry["id"] }.sort).to eq(%w[a-1 a-2 a-3 a-4 a-5])
      expect(anchor_marks(diff).size).to eq(5)
    end

    it "re-sends a wiped thread into that anchor's existing entry, not a second one" do
      open_counter
      buffers = five_threads
      buffers.each { |buf| wipe(buf) }
      diff = buf_in(slots["new"])
      marks = anchor_marks(diff).map(&:first)

      set_thread(anchor(id: "a-1", line: 4), ["thread 1 again"])

      expect(anchor_marks(diff).map(&:first)).to eq(marks)
      expect(held_anchors(diff).values.map { |entry| entry["id"] }.sort).to eq(%w[a-1 a-2 a-3 a-4 a-5])
    end

    # The behaviour a stale registry would produce is not a leak, it is a raise:
    # `nvim_win_set_buf` on a wiped buffer fails, and this one would fail from
    # inside a CursorMoved autocmd -- on every keystroke.
    it "keeps the diff and raises nothing when the cursor reaches a wiped thread" do
      open_counter
      buffers = five_threads
      buffers.each { |buf| wipe(buf) }
      enter(slots["new"])

      move_to(4)

      expect(name_of(buf_in(slots["old"]))).to include("lain://review/OLD/docs/counter.txt")
      expect(lua("return vim.v.errmsg")).to eq("")
    end

    it "lands a re-sent thread in a fresh buffer" do
      open_counter
      first = five_threads.first
      wipe(first)

      set_thread(anchor(id: "a-1", line: 4), ["thread 1 again"])
      enter(slots["new"])
      move_to(4)

      expect(buf_in(slots["old"])).not_to eq(first)
      expect(lines_of(buf_in(slots["old"]))).to eq(["thread 1 again"])
    end
  end

  # `:bdelete` is ONE LETTER from the `:bwipeout` the manual recommends, and it
  # is a completely different fact: nvim unloads the buffer, clearing every
  # buffer-local variable, and KEEPS the buffer and its name. `:LainThread` is
  # the documented way into the pane and `:bd` with no argument deletes the
  # buffer you are in, so this is the documented gesture followed by an ordinary
  # one. `:bunload` and a `:mksession` restore leave the same husk.
  #
  # Untreated it compounds three ways: the husk is VALID, so a validity guard
  # hands the pane an empty buffer and displaying it LOADS it; the stamp is gone
  # while the name is not, so naming a fresh buffer raises E95 -- permanently
  # for that anchor, leaking one orphaned buffer per render; and the idempotency
  # guard reads the stamp off the pane, so three column moves produce three
  # buffer sets where the AC demands none.
  describe "a thread buffer the human has :bdeleted" do
    it "keeps the diff rather than showing the emptied husk, and does not load it" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["## you", "why this way?"])
      husk = thread_buffers.first.first
      bdelete(husk)
      enter(slots["new"])

      move_to(20)

      expect(name_of(buf_in(slots["old"]))).to include("lain://review/OLD/docs/counter.txt")
      expect(loaded?(husk)).to be(false)
      expect(lua("return vim.v.errmsg")).to eq("")
    end

    it "reclaims the husk when lain sends the thread again, rather than raising E95" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["## you", "why this way?"])
      husk = thread_buffers.first.first
      bdelete(husk)

      3.times { set_thread(anchor(id: "a-20", line: 20), ["## you", "why this way?", "", "## docent", "because"]) }
      enter(slots["new"])
      move_to(20)

      expect(lines_of(buf_in(slots["old"]))).to eq(["## you", "why this way?", "", "## docent", "because"])
      expect(thread_buffers.map(&:last)).to eq(["a-20"])
      expect(lua("return vim.v.errmsg")).to eq("")
    end

    # The leak, counted: every failed render made a buffer before it raised.
    it "orphans no buffer, however many times the thread is re-sent" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      bdelete(thread_buffers.first.first)
      before = lua("return #vim.api.nvim_list_bufs()")

      10.times { set_thread(anchor(id: "a-20", line: 20), ["twenty"]) }

      expect(lua("return #vim.api.nvim_list_bufs()")).to eq(before)
    end

    # octo's show-path defect -- this card's FIRST escalation trigger --
    # resurrected by the husk, because `shown` reads the stamp off the pane and
    # an unloaded buffer has none.
    it "sets no buffer when the cursor moves within the line of a bdeleted thread" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      bdelete(thread_buffers.first.first)
      enter(slots["new"])
      move_to(20)
      watch_calls

      3.times { move_right }

      expect(calls[:set_buf]).to eq(0)
    end

    # The motions and the resting options come back with the buffer: unloading
    # drops buffer-local keymaps and resets 'buftype'/'bufhidden' to "".
    it "restores the reclaimed buffer's resting shape and its motions" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["## you", "why?"])
      husk = thread_buffers.first.first
      bdelete(husk)

      set_thread(anchor(id: "a-20", line: 20), ["## you", "why?"])

      expect(thread_buffers.first.first).to eq(husk)
      expect(lua("local b = ... return { vim.bo[b].buftype, vim.bo[b].bufhidden }", [husk]))
        .to eq(%w[acwrite hide])
      expect(buffer_maps(husk, "]]")).to eq(["lain: next message in this thread"])
    end
  end

  describe "what it refuses" do
    it "refuses a bare id, naming the position the pane cannot learn without it" do
      open_counter

      ok, message = refusal("a-20", ["twenty"])

      expect(ok).to be(false)
      expect(message).to include("set_thread").and match(/position/i)
    end

    it "refuses a side that is neither of the two" do
      open_counter

      ok, message = refusal(anchor(id: "a-20", line: 20, side: "middle"), ["twenty"])

      expect(ok).to be(false)
      expect(message).to include("middle")
    end

    it "refuses a line that is not a position" do
      open_counter

      ok, message = refusal(anchor(id: "a-20", line: 0), ["twenty"])

      expect(ok).to be(false)
      expect(message).to include("line")
    end

    # `nvim_buf_set_lines` raises on a String holding a newline, and it would
    # raise having already made the buffer -- 47_diff's `checked_lines` reason.
    it "refuses a thread line that is more than one line" do
      open_counter

      ok, message = refusal(anchor(id: "a-20", line: 20), ["one\ntwo"])

      expect(ok).to be(false)
      expect(message).to include("single line")
    end

    # A Ruby nil crosses msgpack as `vim.NIL`, which is USERDATA and therefore
    # TRUTHY -- so the `lines or {}` a reader would write in the runtime is dead
    # code that hands userdata to `ipairs`. The type test is what makes an empty
    # conversation an empty buffer rather than a raise.
    it "renders a thread sent with no lines at all as an empty conversation" do
      open_counter
      ok, = refusal(anchor(id: "a-20", line: 20), nil)

      expect(ok).to be(true)
      expect(lines_of(thread_buffers.first.first)).to eq([""])
    end

    it "refuses an anchor with no path, which names no diff buffer to anchor in" do
      open_counter

      ok, message = refusal({ "id" => "a-20", "side" => "new", "line" => 20 }, ["twenty"])

      expect(ok).to be(false)
      expect(message).to include("path")
    end

    # 47_diff's `focus_line` reason, one module over: a line the changeset named
    # and the file no longer reaches would make `nvim_buf_set_extmark` raise --
    # taking down a render over a note. Clamped to the last line instead, which
    # is where the anchor's content most likely went.
    it "anchors a thread past the end of the file on its last line rather than raising" do
      open_counter
      set_thread(anchor(id: "a-past", line: 400), ["past the end"])
      enter(slots["new"])

      move_to(40)

      expect(buffer_var(buf_in(slots["old"]), "lain_thread_anchor")).to eq("a-past")
      expect(lua("return vim.v.errmsg")).to eq("")
    end

    # Normal, not exceptional: Ruby holds threads for a whole changeset and the
    # human is looking at one file of it.
    it "keeps a thread for a file nobody is reviewing without registering a position" do
      open_counter
      set_thread(anchor(id: "a-other", line: 3, path: "docs/other.txt"), ["elsewhere"])
      enter(slots["new"])

      move_to(3)

      expect(thread_buffers.map(&:last)).to eq(["a-other"])
      expect(name_of(buf_in(slots["old"]))).to include("lain://review/OLD/docs/counter.txt")
    end
  end

  describe "asking in the thread" do
    def thread_buf(id) = thread_buffers.find { |_, held| held == id }.first

    # The wire shape every verb on this rail takes: ONE array after the verb.
    # `65_review.lua` records a verb that sent flat positionals and had
    # everything after the first dropped on the floor.
    it "sends what the human typed as review_ask, one array of arguments" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["## you", "why this way?"])
      buf = thread_buf("a-20")
      append(buf, ["", "and what breaks if I change it?"])

      wrote = written(buf)

      expect(wrote["seen"]).to eq(["lain_command", "review_ask", ["a-20", "and what breaks if I change it?"]])
      expect(wrote["ok"]).to be(true)
      expect(wrote["modified"]).to be(false)
    end

    # The standing obligation, and it is decided entirely here: Ruby can only
    # answer, and whether `:w` reports success is lua's to get right.
    #
    # THE WRITE NO LONGER RAISES AND STILL DOES NOT SUCCEED. `ok` is now true --
    # the callback returns -- and 'modified' carries the whole of the refusal:
    # measured on nvim 0.12, a `BufWriteCmd` that returns without clearing it
    # leaves the buffer dirty, `:w` reports nothing written, and `:wq` declines
    # to quit. So the human's words are as safe as the raise made them, without
    # the traceback and the prompt the next two examples pin.
    it "does not clear modified, and keeps the human's text, when the question reaches nobody" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["## you", "why this way?"])
      buf = thread_buf("a-20")
      append(buf, ["", "does this reach anyone?"])

      wrote = written(buf, fail: true)

      expect(wrote["ok"]).to be(true)
      expect(wrote["modified"]).to be(true)
      expect(lines_of(buf).last).to eq("does this reach anyone?")
    end

    # ROUND 7'S RESIDUE, and it is the same fact the example above pins, told to
    # the human. The question was typed and reached nobody, so it goes out on
    # `__lain.review_refused` -- a LOCAL `nvim_echo`, which is what makes it
    # deliverable on the one leg where `vim.rpcrequest` has just failed -- and
    # names the wire error rather than an unexplained failure.
    it "refuses on the rail when the question reaches nobody, naming why it was not sent" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["## you", "why this way?"])
      buf = thread_buf("a-20")
      append(buf, ["", "does this reach anyone?"])
      lua(ThreadFixture::DEAF_RPC)
      lua(ThreadFixture::RAIL_PROBE)
      # 110 columns is what `lain up` gives this pane, and `v:echospace` there is
      # 98 -- so this is the width at which "names why" either survives or does
      # not. An earlier sentence read back as `... the question was NOT sent and
      # your text  ... ll modified, so :w again ...`, eliding the one part of it
      # a human cannot guess.
      attach_ui(columns: 110)

      type_write(buf)
      press_enter

      expect(shown_refusal).to include("was NOT sent").and include("no editor took this")
      expect(shown_refusal).not_to include(" ... ")

      # `Error in BufWriteCmd Autocommands` is nvim's own framing for a raise out
      # of this callback, and pinning its ABSENCE is what makes this example
      # about the rail rather than about the error text happening to carry the
      # same words.
      expect(said).to include("lain:")
      expect(said).not_to include("stack traceback")
      expect(said).not_to include("Error in BufWriteCmd")
      expect(said).not_to include("lain: lain:")
    end

    # The other half of the prompt-wedge defect, and the half round 7 left live
    # in this pane: a raise out of a `BufWriteCmd` reaches the human wearing nvim's
    # `stack traceback:` with a hit-enter prompt behind it, and that prompt
    # queues every non-fast RPC request -- `:messages` included -- until
    # somebody presses a key. Round 7 measured this exact leg at
    # `{mode = "r", blocking = true}` with the next round trip timing out.
    it "leaves the editor answering RPC when the question reaches nobody" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["## you", "why this way?"])
      buf = thread_buf("a-20")
      append(buf, ["", "does this reach anyone?"])
      lua(ThreadFixture::DEAF_RPC)
      attach_ui

      # BOTH GUARDS ARE AGAINST A VACUOUS PASS, and both were measured rather
      # than imagined. With NO UI attached nvim never raises the prompt at all,
      # so an edit that dropped `attach_ui` would leave this example green over
      # an editor that cannot fail it.
      expect(lua("return #vim.api.nvim_list_uis()", [])).to be_positive

      type_write(buf)

      begin
        expect(settled_mode).to include("blocking" => false)
        expect(round_trip).to eq(2)
      ensure
        # One prompt left standing hangs this example's own teardown and reads
        # as a mystery timeout rather than as the expectation that failed.
        press_enter
      end

      # The second guard: the refusal really did happen. Without it a write that
      # never reached the callback -- `type_write` respelled as a lua call, whose
      # errors nvim discards -- would also read as "not blocking".
      expect(said).to include("was NOT sent")
    end

    # `:w` on an acwrite buffer fires BufWriteCmd whether or not the buffer is
    # modified, and a duplicate here is a duplicate docent spawn and a duplicate
    # provider call. Ruby cannot dedupe it at the door -- `review_ask` sits in
    # the Router's ACKED table, so the write is answered `true` before anything
    # consumes it -- so the watermark is what has to stop it.
    it "refuses a second write that would ask the same question again" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["## you", "why this way?"])
      buf = thread_buf("a-20")
      append(buf, ["", "and what breaks if I change it?"])

      first = written(buf)
      second = written(buf)

      expect(first["seen"].last).to eq(["a-20", "and what breaks if I change it?"])
      expect(second["seen"]).to be_nil
      expect(messages).to include("nothing has been typed")
      expect(messages).not_to include("stack traceback")
      expect(messages).not_to include("lain: lain:")
    end

    # The other half, and what keeps the watermark from meaning "one question
    # per buffer, ever": a question is whatever follows what has already been
    # asked.
    it "sends only what the human has typed since the last question" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["## you", "why this way?"])
      buf = thread_buf("a-20")
      append(buf, ["", "and what breaks if I change it?"])
      written(buf)
      append(buf, ["", "and this?"])

      second = written(buf)

      expect(second["seen"].last).to eq(["a-20", "and this?"])
    end

    # THE MECHANISM CHANGED AND THE RULE DID NOT, and the two "refuses" in this
    # block are no longer the same act. A write with nothing typed risks
    # nothing -- the buffer is unmodified and there is no text to lose -- so it
    # is refused IN WORDS on `__lain.review_refused` and the command completes.
    # It used to raise, and a raise out of a `BufWriteCmd` reaches the human
    # wearing nvim's `stack traceback:` with a hit-enter prompt behind it, which
    # queues every non-fast RPC request until somebody presses a key; the
    # editor-not-locked half of that is pinned in `rpc_thread_spec.rb`, which
    # attaches a UI and can therefore witness the prompt.
    #
    # The refusal above it -- a question that reached nobody -- still RAISES,
    # and must: there the human's words are in the buffer and `:w` reporting
    # success would report them sent.
    it "refuses a write with nothing typed rather than asking an empty question" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["## you", "why this way?"])
      buf = thread_buf("a-20")

      wrote = written(buf)

      expect(wrote["seen"]).to be_nil
      expect(messages).to include("lain:").and include("nothing has been typed")
      expect(messages).not_to include("stack traceback")
      expect(messages).not_to include("lain: lain:")
    end

    it "does not overwrite a half-typed reply when a render lands" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["## you", "why this way?"])
      buf = thread_buf("a-20")
      append(buf, ["half a thought"])

      set_thread(anchor(id: "a-20", line: 20), ["## you", "why this way?", "", "## docent", "because"])

      expect(lines_of(buf).last).to eq("half a thought")
    end
  end

  describe ":LainThread" do
    it "puts the human in the pane holding the thread under the cursor" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      enter(slots["new"])
      move_to(20)

      @editor.command("LainThread")

      expect(here).to eq(slots["old"])
      expect(buffer_var(buf_in(slots["old"]), "lain_thread_anchor")).to eq("a-20")
    end

    it "says so rather than raising when the line under the cursor has no thread" do
      open_counter
      enter(slots["new"])
      move_to(7)

      answer = refused_thread

      expect(answer["ok"]).to be(true)
      expect(answer["shown"].last).to include("no thread")
      # The sentence this card ADDS belongs to a line that has a note on it.
      # Without this half, a refusal that named `:LainNoteDone` unconditionally
      # would pass every example below while telling a human with no note at all
      # to hand one back.
      expect(answer["shown"].last).not_to include("LainNoteDone")
    end

    it "says so outside a review diff buffer rather than opening whatever is there" do
      open_counter
      enter(slots["sidebar"])

      answer = refused_thread

      expect(answer["ok"]).to be(true)
      expect(answer["shown"].last).to include("LainThread")
      expect(answer["shown"].last).not_to include("LainNoteDone")
    end

    # Both sentences were true and the human could only see one: a `● note`
    # marker sits visibly on the line, and `:LainThread` answered "no thread on
    # this line". The anchor id is minted at hand-back
    # ({Lain::Review::Handover}), so a thread genuinely cannot exist yet -- the
    # fix is the third sentence, not earlier ids.
    #
    # The marker is read through `48_annotate.lua`'s own `review_notes.marked`,
    # so what the refusal reacts to is the thing the human can see rather than a
    # second registry that could disagree with it.
    it "names the unhanded note and its remedy when a marker sits on the line" do
      open_counter
      enter(slots["new"])
      move_to(7)
      place_note("note", "this line reads oddly")

      answer = refused_thread

      expect(answer["ok"]).to be(true)
      expect(answer["shown"].last).to include("note").and include("LainNoteDone")
      expect(answer["shown"].last).not_to include("no thread on this line")
    end

    # A note on ANOTHER line must not answer for this one -- otherwise the new
    # sentence is really "this buffer has notes somewhere", which is not a
    # question anybody asked.
    it "keeps the bare sentence for a line whose neighbour carries the note" do
      open_counter
      enter(slots["new"])
      move_to(7)
      place_note("note", "this line reads oddly")
      move_to(9)

      answer = refused_thread

      expect(answer["ok"]).to be(true)
      expect(answer["shown"].last).to include("no thread")
      expect(answer["shown"].last).not_to include("LainNoteDone")
    end

    # THE THREE SENTENCES, PINNED WHOLE AND IN ONE PLACE. Each example above
    # asserts the DISTINGUISHING half of its own refusal, which is what makes
    # them readable; this is where the exact wording lives, so a reworded
    # sentence fails once with a diff rather than three times by keyword.
    #
    # The `lain: ` on each is the RAIL'S, not the caller's -- `review_refused`
    # prepends it -- so this also pins that none of the three carries its own and
    # doubles it.
    it "refuses in three sentences, each naming its own state" do
      open_counter
      lua(ThreadFixture::RAIL_PROBE)

      enter(slots["sidebar"])
      lua('pcall(vim.cmd, "LainThread")')
      enter(slots["new"])
      move_to(7)
      lua('pcall(vim.cmd, "LainThread")')
      place_note("note", "this line reads oddly")
      lua('pcall(vim.cmd, "LainThread")')

      expect(lua("return _G.__thread_rail", [])).to eq(
        ["lain: no review diff here -- open one, then :LainThread",
         "lain: no thread on this line",
         "lain: note not handed back yet -- hand it back with :LainNoteDone"]
      )
    end

    # THE ELIDED FORM IS WHAT THE HUMAN READS AT THE MOMENT THEY NEED IT, and
    # surviving the hit-enter prompt is not the same as surviving legibly. The
    # rail fits a sentence by keeping its HEAD AND TAIL (`65_review.lua`'s
    # `elided`), so a remedy in the MIDDLE is cut in half: measured, an earlier
    # draft of the note refusal read back as
    #
    #   lain: note not handed ... Done gives it a thread
    #
    # and `Done` is not a command. `v:echospace` is `columns - 12`, so 60 columns
    # leaves 48 cells and every sentence here but the bare one is fitted.
    #
    # THE RULE THIS PINS: the token a human cannot guess goes LAST, because the
    # tail is what survives. Both command names qualify -- `<leader>Lt` reaches
    # this refusal without the human ever having typed `:LainThread`, so the name
    # is not recoverable from what they just did.
    it "keeps the command a human cannot guess whole when the rail has to elide" do
      open_counter
      attach_ui(columns: 60, lines: 24)
      lua(ThreadFixture::RAIL_PROBE)

      enter(slots["sidebar"])
      lua('pcall(vim.cmd, "LainThread")')
      enter(slots["new"])
      move_to(7)
      place_note("note", "this line reads oddly")
      lua('pcall(vim.cmd, "LainThread")')

      outside, noted = lua("return _G.__thread_rail", [])

      expect(outside).to include(":LainThread")
      expect(noted).to include(":LainNoteDone")
      # NON-VACUITY: if neither sentence were fitted at all this example would
      # pass over a rail that had never been asked the question.
      expect([outside, noted]).to all(include(" ... "))
    end

    # Round 7's prompt-wedge defect, on the surface this card touches: an
    # `error()` inside a `define`d command reaches the human wearing
    # `stack traceback:` with a hit-enter prompt behind it, and that prompt
    # queues every non-fast RPC request until somebody presses a key.
    #
    # KEYSTROKES WITH A UI ATTACHED, for `type_write`'s measured reason -- an
    # error out of a NOTIFIED `nvim_exec_lua` is discarded by nvim,
    # `refused_thread`'s own `pcall` swallows one too, and a headless editor
    # never raises the prompt at all. Any of the three shortcuts reads green over
    # an editor that cannot fail this.
    #
    # ⚠️ 80 AND 100 COLUMNS, AND THE PAIR IS THE POINT. A panel measured the
    # blocking threshold for a plain `vim.notify` at roughly `len + 12 > columns`:
    # the pre-existing 95-character refusal blocked at anything up to 105
    # columns, and a 106-character new one would have blocked up to 115 -- taking
    # this surface from one refusal modaling to two, on ordinary terminals. A
    # first cut of this example passed only because it ran at 120 columns, which
    # is two columns of headroom and not a margin. These are the widths a human
    # actually has, so they are the widths the property is pinned at. The remedy
    # is `__lain.review_refused`, which fits the line to the screen and was
    # measured never to block at 60, 80, 100 or 110.
    [80, 100].each do |columns|
      it "leaves the editor answering RPC on each of its three refusals at #{columns} columns" do
        open_counter
        attach_ui(columns:, lines: 24)
        expect(lua("return #vim.api.nvim_list_uis()", [])).to be_positive
        expect(raising_blocks).to be(true)

        enter(slots["sidebar"])
        outside = typed_refusal

        enter(slots["new"])
        move_to(7)
        bare = typed_refusal

        enter(slots["new"])
        move_to(7)
        place_note("note", "this line reads oddly")
        noted = typed_refusal

        said = [outside, bare, noted].map(&:last)

        expect([outside, bare, noted].map { |mode, _| mode["blocking"] }).to eq([false, false, false])
        expect(round_trip).to eq(2)
        expect(said).to all(include("lain:"))
        expect(said.join("\n")).not_to include("stack traceback")
        expect(said.join("\n")).not_to include("Error executing")
      end
    end
  end

  # The one place a cross-language vocabulary can be pinned: Ruby renders the
  # message boundary and lua's motion recognises it. Asserted through a REAL
  # {ThreadView} rendering driven into a REAL editor, so the two spellings agree
  # by behaviour rather than by both being written down twice.
  #
  # ⚠️ THE MAPPING IS ASSERTED TO BE OURS, and that is not belt-and-braces. The
  # first cut of this example measured nvim 0.12.4's own markdown ftplugin: it
  # binds `]]` to a next-heading motion that lands on EXACTLY the line asserted
  # here, so a module that bound nothing read green. `normal` (no bang) was
  # taken for the guard -- it prefers a user mapping -- but it falls THROUGH to
  # the built-in when there is none, which is the whole hole. A panel measured
  # it against a buffer carrying no lain mapping at all.
  describe "the messages ThreadView renders" do
    # A REAL rendering, posted through a recording inlet the example holds, so
    # the lines driven into the editor are the ones production would send.
    def rendered_thread
      inlet = RecordingThreadInlet.new
      Lain::Frontend::Neovim::ThreadView.new(rpc: inlet)
                                        .show(thread_anchor, [thread_entry("you", "why?"),
                                                              thread_entry("docent", "because")])
      set_thread(*inlet.posts.first)
      thread_buffers.first.first
    end

    def thread_entry(speaker, text) = Lain::Frontend::Neovim::ThreadView::Entry.new(speaker:, text:)

    it "are what ]] jumps between, through this module's own mapping" do
      open_counter
      buf = rendered_thread

      first = motion(buf, 1, "]]")
      second = motion(buf, first, "]]")

      expect(buffer_maps(buf, "]]")).to eq(["lain: next message in this thread"])
      expect([lines_of(buf)[first - 1], lines_of(buf)[second - 1]]).to eq(["## you", "## docent"])
    end

    # `[[` had no example at all, and it is half of the vocabulary: a module
    # binding only `]]` passed everything above.
    it "are what [[ jumps back between, through this module's own mapping" do
      open_counter
      buf = rendered_thread
      last = lines_of(buf).length

      back = motion(buf, last, "[[")
      further = motion(buf, back, "[[")

      expect(buffer_maps(buf, "[[")).to eq(["lain: previous message in this thread"])
      expect([lines_of(buf)[back - 1], lines_of(buf)[further - 1]]).to eq(["## docent", "## you"])
    end
  end

  # A survey presents ONE side, so the layout opens `sidebar | new` and the
  # `old` slot -- still in the vocabulary, still ordered, simply not opened --
  # is where `OPPOSITE["new"]` sends the thread. The pane therefore has to be
  # opened ON DEMAND, by the gesture that asks for it, and the alternative is
  # what this group exists to keep out: `review_place` handing
  # `nvim_win_set_buf` a nil window inside a `define`d command, which is an
  # `error()`, a traceback and a blocking hit-enter prompt -- round 7's
  # prompt-wedge shape, on the surface this chunk exists to repair.
  describe "the docent thread pane on a round that presents one side" do
    # The fact rides the SIDEBAR rail, because that render precedes the layout:
    # the panes are built on the first sidebar paint, before any row is opened.
    def set_review(lines, generation, sides) = lua("_G.__lain.set_review(...)", [lines, generation, sides])

    # `/survey docs`, as far as the editor is concerned: one side named, and an
    # old side that is `[]` rather than absent -- {Review::Changeset#old_side}
    # answers `[]` for every corpus file.
    def surveyed(line = 1)
      set_review(["[ ] docs/counter.txt"], 1, ["new"])
      lua("_G.__lain.open_changeset(...)", ["docs/counter.txt", [], line, revisions])
    end

    # `:LainThread` as a human types it, answering the settled mode and the
    # slice of `:messages` this one command added. `typed_refusal`'s shape, with
    # the wait it cannot borrow: a command that succeeds says nothing, so there
    # is no sentence to poll for and the window is what separates "did not
    # block" from "has not run yet". The example's own assertion that the pane
    # opened is what makes that non-vacuous.
    def typed_thread
      before = messages
      @editor.session.notify(:nvim_input, ":LainThread\r")
      mode = settled_mode
      clear_prompt
      [mode, messages[before.length..]]
    end

    it "opens the pane the round did not, and puts the human in it" do
      surveyed
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      enter(slots["new"])
      move_to(20)

      @editor.command("LainThread")

      expect(here).to eq(slots["old"])
      expect(buffer_var(buf_in(slots["old"]), "lain_thread_anchor")).to eq("a-20")
    end

    # Slot order is still what places it, so the pane lands BETWEEN the
    # navigator and the file rather than wherever a bare split would have put
    # it: `sidebar | thread | file`, which is the same left-to-right reading a
    # changeset gives.
    it "puts it where slot order puts it, between the navigator and the file" do
      surveyed
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      enter(slots["new"])
      move_to(20)

      @editor.command("LainThread")

      expect(lua("return vim.api.nvim_tabpage_list_wins(0)").map do |win|
        lua("return vim.w[...].lain_review_slot", [win])
      end).to eq(%w[sidebar old new])
    end

    # A DIFF NEEDS TWO. With the pane open the file window is still the only
    # review SIDE in the layout, and `rediff` runs on every swap the cursor
    # causes -- so an implementation gated on the WINDOW rather than on the
    # ROUND runs `diffthis` on one window and 'foldmethod=diff' collapses the
    # whole file the human came to read.
    it "leaves the file window out of diff mode as the cursor moves the pane" do
      surveyed
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      enter(slots["new"])
      move_to(20)
      @editor.command("LainThread")

      enter(slots["new"])
      move_to(7)

      expect(window_options(slots["new"])).to include(diff: false)
      expect(folded_lines(slots["new"])).to be_empty
    end

    # AT A REALISTIC WIDTH, and at two of them. A no-error claim measured only
    # at 120 columns is not the property: `nvim_echo` writes the message AREA,
    # so a traceback too wide for it raises the hit-enter prompt that queues
    # every non-fast RPC request -- and the widths a cockpit pane actually has
    # are 80 and 100.
    [80, 100].each do |columns|
      it "opens without raising, without a traceback and without blocking at #{columns} columns" do
        attach_ui(columns:, lines: 24)
        # THE NON-VACUITY GUARD: a command that really does `error()`, driven
        # the same way on the same UI. Without it a "did not block" pass says
        # only that the apparatus cannot witness the defect.
        expect(raising_blocks).to be(true)
        surveyed
        set_thread(anchor(id: "a-20", line: 20), ["twenty"])
        enter(slots["new"])
        move_to(20)

        mode, spoken = typed_thread

        expect(mode["blocking"]).to be(false)
        expect(spoken).not_to include("stack traceback")
        expect(spoken).not_to include("Wrong type for argument")
        expect(buffer_var(buf_in(slots["old"]), "lain_thread_anchor")).to eq("a-20")
      end
    end

    # And the two-sided round is untouched: the pane is the old side, already
    # open, and the thread is an OVERLAY on it rather than a window this card
    # now has to create.
    it "still lands in the old side for a round that presents both" do
      set_review(["[ ] docs/counter.txt"], 1, %w[old new])
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["twenty"])
      enter(slots["new"])
      move_to(20)

      @editor.command("LainThread")

      expect(here).to eq(slots["old"])
      expect(window_options(slots["new"])).to include(diff: true)
    end
  end

  def thread_anchor
    Lain::Review::Anchor.new(path: "docs/counter.txt", side: :new, line: 20,
                             anchor_text: "line 20", revision: "head1ff", id: "a-20")
  end
end

# What the editor's inlet is, from {ThreadView}'s side: it takes the anchor's
# identity and the rendered conversation, and answers why it did not land.
class RecordingThreadInlet
  attr_reader :posts

  def initialize(refusal: nil)
    @posts = []
    @refusal = refusal
  end

  def set_thread(anchor, lines)
    @posts << [anchor, lines]
    @refusal
  end
end

RSpec.describe Lain::Frontend::Neovim::ThreadView do
  subject(:view) { described_class.new(rpc: inlet) }

  let(:inlet) { RecordingThreadInlet.new }

  def anchor(id: "a-20", line: 20, side: :new, path: "docs/counter.txt")
    Lain::Review::Anchor.new(path:, side:, line:, anchor_text: "line 20", revision: "head1ff", id:)
  end

  def entry(speaker, text) = described_class::Entry.new(speaker:, text:)

  it "posts the anchor's identity AND the position the pane has to watch" do
    view.show(anchor, [entry("you", "why this way?")])

    expect(inlet.posts.first.first)
      .to eq("id" => "a-20", "path" => "docs/counter.txt", "side" => "new", "line" => 20)
  end

  it "renders each message under a heading naming who said it, under the position" do
    view.show(anchor, [entry("you", "why this way?"), entry("docent", "because the store owns it")])

    expect(inlet.posts.first.last)
      .to eq(["-- thread at docs/counter.txt:20 --", "", "## you", "why this way?",
              "", "## docent", "because the store owns it"])
  end

  # Both halves of the position, because a header naming the file and losing
  # the line points at the top of a diff rather than at the note -- the same law
  # the review-surface shared group states for `#thread`.
  it "names where the conversation hangs, file and line" do
    view.show(anchor(path: "lib/b.rb", line: 3), [entry("you", "why?")])

    expect(inlet.posts.first.last.first).to eq("-- thread at lib/b.rb:3 --")
  end

  # `nvim_buf_set_lines` raises on a String holding a newline, so a paragraph
  # has to arrive already cut into buffer lines.
  it "cuts a multi-line message into buffer lines" do
    view.show(anchor, [entry("docent", "first\nsecond")])

    expect(inlet.posts.first.last).to eq(["-- thread at docs/counter.txt:20 --", "", "## docent",
                                          "first", "second"])
  end

  it "invites the first question rather than posting an empty buffer" do
    view.show(anchor)

    expect(inlet.posts.first.last).to eq(["-- thread at docs/counter.txt:20 --", described_class::EMPTY])
  end

  it "answers the refusal the editor gave rather than raising" do
    refused = described_class.new(rpc: RecordingThreadInlet.new(refusal: "no editor"))

    expect(refused.show(anchor)).to eq("no editor")
  end

  it "answers nothing when the conversation landed" do
    expect(view.show(anchor)).to be_nil
  end

  # The default is the Null editor, so an unwired view refuses honestly rather
  # than reporting a thread that never landed ({QuestionView::Detached}'s shape).
  it "refuses honestly when no editor is wired" do
    expect(described_class.new.show(anchor)).to eq(described_class::DETACHED)
  end

  # The port's promise, and this chunk's deletion map depends on it: a view
  # holding conversation state is a second copy of the session's.
  it "holds no thread state of its own" do
    view.show(anchor(id: "a-1", line: 4), [entry("you", "one")])
    view.show(anchor(id: "a-2", line: 8), [entry("you", "two")])

    held = view.instance_variables.map { |name| view.instance_variable_get(name) }
    expect(held.map(&:class)).to eq([RecordingThreadInlet])
  end

  # ⚠️ A CROSS-CARD SHAPE, pinned from the only side this tree can see. The
  # docent renders its exchange into these two members from its own value
  # object, by duck rather than by construction, so renaming one here breaks it
  # at RUNTIME with nothing red. This is half a pin: it fails if this side
  # drifts, and it cannot see the other. The whole pin is one example asserting
  # the two member lists equal, and it belongs wherever both constants are
  # loadable -- not here, where the docent's is not.
  it "takes a message as a speaker and their text, in those names" do
    expect(described_class::Entry.members).to eq(%i[speaker text])
  end

  it "refuses an anchor whose id names nothing, because every ask cites it back" do
    expect { view.show(Struct.new(:id, :path, :side, :line).new(nil, "a.rb", :new, 1)) }
      .to raise_error(ArgumentError, /names nothing/)
  end
end

# `[deletable]`: removing this capability means deleting its files, so nothing
# outside them may name it. Runs without an editor.
RSpec.describe "the thread pane's deletability" do
  it "is one runtime module, at the prefix the thread pane was given" do
    modules = Lain::Frontend::Neovim::RuntimeLoader.new.module_paths.map { |path| File.basename(path) }

    expect(modules).to include("51_thread.lua")
  end

  # ⚠️ REWRITTEN, because the first version proved the wrong thing. It asserted
  # that NOTHING outside the thread pane's own files names the capability --
  # which is not deletability, it is "this feature has no users", a property no
  # shipped feature can satisfy and the very state that let this one ship broken (the
  # port adapter posted a shape the editor refuses, and no spec reached the
  # rail). It also made prose pay: a sibling card's comments had to say "the
  # thread pane's editor half" rather than cite {ThreadView::Entry}, because
  # naming a thing failed a test.
  #
  # So: CODE may name the capability only from an enumerated set of consumers,
  # and PROSE may name it anywhere. A whole-line comment is stripped before the
  # scan; a new unlisted reference in code still fails, which is what keeps a
  # deletion able to find everything by deleting and reading the reds.
  #
  # The row, and what a deletion owes each entry:
  #
  #   1. `lib/lain/frontend/neovim.rb` -- the require line. A dangling
  #      `require_relative` is a LoadError rather than a missing feature. (No
  #      such line for the lua module: the runtime loader globs the directory.)
  #   2. `lib/lain/review/surface/neovim.rb` -- the port adapter renders
  #      `#annotate` and `#thread` through {ThreadView}. Those two messages are
  #      the PORT's, so deleting the pane does not delete them: a deletion has
  #      to decide what they become. Left as they are they would post to a lua
  #      entry point that no longer exists -- a silent nil call inside a notify,
  #      not a LoadError, which is exactly the failure this row exists to make
  #      impossible.
  #   3. `lib/lain/review/docent.rb` -- the docent asks a review surface whether
  #      it has a pane to draw an answer into, and takes the one it finds. It
  #      costs a deletion nothing extra: the deletion map already records that removing
  #      the pane forces the docent out with it, so this reference goes with the
  #      file it lives in. It is listed because THIS sweep is a flat allowlist
  #      and knows nothing about that nesting. Its own spec is here for the same
  #      reason: it stands a surface in that answers `#thread_view`.
  #   4. the two specs that drive the rail.
  def names_it_in_code?(path)
    comment = path.end_with?(".lua") ? /^\s*--/ : /^\s*#/
    File.readlines(path).grep_v(comment).join.match?(/ThreadView|thread_view|51_thread/)
  end

  it "is named in CODE only by its own files and an enumerated set of consumers" do
    root = File.expand_path("../../../..", __dir__)
    own = ["lib/lain/frontend/neovim/thread_view.rb", "lib/lain/frontend/neovim/runtime/51_thread.lua",
           "spec/lain/frontend/neovim/thread_view_spec.rb"]
    consumers = ["lib/lain/frontend/neovim.rb", "lib/lain/review/docent.rb",
                 "lib/lain/review/surface/neovim.rb", "spec/lain/review/docent_spec.rb",
                 "spec/lain/review/surface/neovim_spec.rb"]
    # `deletability_spec.rb` is the MAP, so it names every deletable
    # capability by construction and exempts itself from its own sweep for the
    # same reason. It is not a consumer: the thread pane's deletion takes its
    # ROW there, which is an edit, not the file.
    sources = (Dir[File.join(root, "{lib,spec,exe}/**/*.{rb,lua}")] + [File.join(root, "exe/lain")])
              .reject { |path| path.end_with?("spec/lain/review/deletability_spec.rb") }

    unlisted = "a file outside the thread pane's deletion row now names it in CODE. If that is a " \
               "legitimate new consumer, add it to `consumers` above AND to the chunk's deletion map, so " \
               "a deletion removes it with the capability. If it is only a mention in prose, a " \
               "whole-line comment is already exempt."

    naming = sources.select { |path| File.file?(path) && names_it_in_code?(path) }
                    .map { |path| path.delete_prefix("#{root}/") }

    expect((naming - own).sort).to eq(consumers.sort), unlisted
    expect(File.read(File.join(root, "lib/lain/frontend/neovim.rb")).scan(/^.*thread_view.*$/))
      .to eq(['require_relative "neovim/thread_view"'])
  end

  # The manual is not in the glob above and cannot be: it names `:LainThread`
  # and `lain://thread` in prose, and `nvim_plugin_spec.rb`'s own check is
  # one-directional (a documented command must exist, never the reverse). So the
  # stanza would survive a deletion green, leaving a manual entry for a command
  # that is gone. Named here, in the row, so a deletion finds it by failing.
  it "is documented in one stanza of the manual, which goes with it" do
    doc = File.read(File.expand_path("../../../../plugin/nvim/doc/lain.txt", __dir__))

    expect(doc).to include("*:LainThread*").and include("*lain://thread*")
  end
end
