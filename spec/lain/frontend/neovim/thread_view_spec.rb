# frozen_string_literal: true

require "fileutils"
require "neovim"
require "socket"
require "timeout"
require "tmpdir"

# T18: `runtime/51_thread.lua` and {Lain::Frontend::Neovim::ThreadView} -- one
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

  at_exit { FileUtils.remove_entry(PROJECT) if File.directory?(PROJECT) }
end

RSpec.describe Lain::Frontend::Neovim, "the review thread pane", :nvim do
  around do |example|
    socket = File.join(Dir.tmpdir, "lain-nvim-thread-spec-#{Process.pid}-#{rand(1_000_000)}.sock")
    # `-n` (no swap file) is not tidiness: the new side is a REAL file buffer,
    # one example EDITS it, and an editor killed with a modified buffer
    # preserves its swap -- after which the next example's `bufload` of the
    # shared fixture answers E325 ATTENTION and the whole file cascades.
    pid = spawn("nvim", "--headless", "--clean", "-n", "--listen", socket,
                chdir: ThreadFixture::PROJECT, out: File::NULL, err: File::NULL)
    Timeout.timeout(10) { sleep 0.02 until File.exist?(socket) }
    @editor = Neovim.attach_unix(socket)
    @editor.exec_lua(Lain::Frontend::Neovim::RuntimeLoader.new.source,
                     [Lain::VERSION, Lain::Frontend::Neovim::PROTOCOL, @editor.channel_id])
    example.run
  ensure
    @editor = nil
    if pid
      begin
        Process.kill("TERM", pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
    FileUtils.rm_f(socket)
  end

  def lua(source, args = []) = @editor.exec_lua(source, args)

  def revisions = { "old" => "base0ff", "new" => "head1ff" }

  def counter_old_lines = (1..40).map { |i| i == 20 ? "was line 20" : "line #{i}" }

  # The file under review, opened as T15's pair. Every example starts here
  # because a thread pane with no diff pair has nothing to be opposite of.
  def open_counter(line = 1, at: revisions)
    lua("_G.__lain.open_changeset(...)", ["docs/counter.txt", counter_old_lines, line, at])
  end

  def open_other(line = 1)
    lua("_G.__lain.open_changeset(...)", ["docs/other.txt", (1..12).map { |i| "other #{i}" }, line, revisions])
  end

  # T18's entry point. The anchor rides as a TABLE -- its id AND the position the
  # pane has to watch -- because the pane is cursor-driven and Ruby is the only
  # side that knows where an anchor sits (see `51_thread.lua`'s header).
  def anchor(id:, line:, side: "new", path: "docs/counter.txt")
    { "id" => id, "path" => path, "side" => side, "line" => line }
  end

  def set_thread(anchor_table, lines) = lua("_G.__lain.set_thread(...)", [anchor_table, lines])

  def refusal(anchor_table, lines)
    lua("local ok, err = pcall(_G.__lain.set_thread, ...) return { ok, tostring(err) }", [anchor_table, lines])
  end

  # slot -> window, read off T26's window variables so this never calls
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
  def move_to(row) = @editor.command("normal! #{row}G")

  def move_right = @editor.command("normal! l")

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

  def notified
    lua(<<~LUA)
      local seen = {}
      local original = vim.notify
      vim.notify = function(message, level) table.insert(seen, { message, level }) end
      local ok, err = pcall(vim.cmd, "LainThread")
      vim.notify = original
      return { seen = seen, ok = ok, err = tostring(err) }
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

    # T26's panel found a repair that stole focus, invisible to the suite
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

      lua("_G.__lain.set_review(...)", [["[ ] docs/counter.txt"], 1])

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
    # answer, and whether `:w` actually FAILS is lua's to get right.
    it "fails the write and keeps the human's text when the question reaches nobody" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["## you", "why this way?"])
      buf = thread_buf("a-20")
      append(buf, ["", "does this reach anyone?"])

      wrote = written(buf, fail: true)

      expect(wrote["ok"]).to be(false)
      expect(wrote["modified"]).to be(true)
      expect(lines_of(buf).last).to eq("does this reach anyone?")
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
      expect(second["ok"]).to be(false)
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

    it "refuses a write with nothing typed rather than asking an empty question" do
      open_counter
      set_thread(anchor(id: "a-20", line: 20), ["## you", "why this way?"])
      buf = thread_buf("a-20")

      wrote = written(buf)

      expect(wrote["seen"]).to be_nil
      expect(wrote["ok"]).to be(false)
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

      answer = notified

      expect(answer["ok"]).to be(true)
      expect(answer["seen"].flatten.first).to include("no thread")
    end

    it "says so outside a review diff buffer rather than opening whatever is there" do
      open_counter
      enter(slots["sidebar"])

      answer = notified

      expect(answer["ok"]).to be(true)
      expect(answer["seen"].flatten.first).to include("LainThread")
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

  # ⚠️ A CROSS-CARD SHAPE, pinned from the only side this tree can see. T24's
  # docent renders its exchange into these two members from its own value
  # object, by duck rather than by construction, so renaming one here breaks it
  # at RUNTIME with nothing red. This is half a pin: it fails if this side
  # drifts, and it cannot see the other. The whole pin is one example asserting
  # the two member lists equal, and it belongs wherever both constants are
  # loadable -- not here, where T24's is not.
  it "takes a message as a speaker and their text, in those names" do
    expect(described_class::Entry.members).to eq(%i[speaker text])
  end

  it "refuses an anchor whose id names nothing, because every ask cites it back" do
    expect { view.show(Struct.new(:id, :path, :side, :line).new(nil, "a.rb", :new, 1)) }
      .to raise_error(ArgumentError, /names nothing/)
  end
end

# `[deletable]`: T25 removes this capability by deleting its files, so nothing
# outside them may name it. Runs without an editor.
RSpec.describe "the thread pane's deletability" do
  it "is one runtime module, at the prefix T18 was given" do
    modules = Lain::Frontend::Neovim::RuntimeLoader.new.module_paths.map { |path| File.basename(path) }

    expect(modules).to include("51_thread.lua")
  end

  # ⚠️ REWRITTEN, because the first version proved the wrong thing. It asserted
  # that NOTHING outside T18's own files names the capability -- which is not
  # deletability, it is "this feature has no users", a property no shipped
  # feature can satisfy and the very state that let this one ship broken (the
  # port adapter posted a shape the editor refuses, and no spec reached the
  # rail). It also made prose pay: a sibling card's comments had to say "T18's
  # editor half" rather than cite {ThreadView::Entry}, because naming a thing
  # failed a test.
  #
  # So: CODE may name the capability only from an enumerated set of consumers,
  # and PROSE may name it anywhere. A whole-line comment is stripped before the
  # scan; a new unlisted reference in code still fails, which is what keeps T25
  # able to find everything by deleting and reading the reds.
  #
  # The row, and what T25 owes each entry:
  #
  #   1. `lib/lain/frontend/neovim.rb` -- the require line. A dangling
  #      `require_relative` is a LoadError rather than a missing feature. (No
  #      such line for the lua module: T6's loader globs the directory.)
  #   2. `lib/lain/review/surface/neovim.rb` -- the port adapter renders
  #      `#annotate` and `#thread` through {ThreadView}. Those two messages are
  #      the PORT's, so deleting the pane does not delete them: T25 has to
  #      decide what they become. Left as they are they would post to a lua
  #      entry point that no longer exists -- a silent nil call inside a notify,
  #      not a LoadError, which is exactly the failure this row exists to make
  #      impossible.
  #   3. the two specs that drive the rail.
  def names_it_in_code?(path)
    comment = path.end_with?(".lua") ? /^\s*--/ : /^\s*#/
    File.readlines(path).grep_v(comment).join.match?(/ThreadView|thread_view|51_thread/)
  end

  it "is named in CODE only by its own files and an enumerated set of consumers" do
    root = File.expand_path("../../../..", __dir__)
    own = ["lib/lain/frontend/neovim/thread_view.rb", "lib/lain/frontend/neovim/runtime/51_thread.lua",
           "spec/lain/frontend/neovim/thread_view_spec.rb"]
    consumers = ["lib/lain/frontend/neovim.rb", "lib/lain/review/surface/neovim.rb",
                 "spec/lain/review/surface/neovim_spec.rb"]
    # T25's `deletability_spec.rb` is the MAP, so it names every deletable
    # capability by construction and exempts itself from its own sweep for the
    # same reason. It is not a consumer: the thread pane's deletion takes its
    # ROW there, which is an edit, not the file.
    sources = (Dir[File.join(root, "{lib,spec,exe}/**/*.{rb,lua}")] + [File.join(root, "exe/lain")])
              .reject { |path| path.end_with?("spec/lain/review/deletability_spec.rb") }

    unlisted = "a file outside the thread pane's deletion row now names it in CODE. If that is a " \
               "legitimate new consumer, add it to `consumers` above AND to the chunk's deletion map, so " \
               "T25 removes it with the capability. If it is only a mention in prose, a whole-line comment " \
               "is already exempt."

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
  # that is gone. Named here, in the row, so T25 finds it by failing.
  it "is documented in one stanza of the manual, which goes with it" do
    doc = File.read(File.expand_path("../../../../plugin/nvim/doc/lain.txt", __dir__))

    expect(doc).to include("*:LainThread*").and include("*lain://thread*")
  end
end
