# frozen_string_literal: true

require "fileutils"
require "neovim"
require "socket"
require "timeout"
require "tmpdir"

# `runtime/47_diff.lua` -- the reading surface. One changed file drawn into the
# layout's two diff slots: the real file on the new side, `git show <base>:<path>`
# on the old side, both in nvim's native diff mode.
#
# Its OWN nvim harness rather than an append to `neovim_runtime_spec.rb`, for
# `layout_spec.rb`'s reason: what is under test is what the editor does with
# buffers, windows and folds, and a frontend in front of that would mean every
# assertion had to first prove the frontend was not the thing that moved.
#
# A FRESH editor per example, and it stays affordable because of what the fixture
# is made of. Spawning `--clean --headless` nvim and injecting the runtime is
# ~15ms; the fixture is four small files rather than a git repository, since Ruby
# runs git and sends `old_lines` already read. Sharing one editor across examples
# would save that 15ms and cost the isolation that makes a fold count or a window
# id mean anything -- the wrong trade on the card whose panel found two BLOCKERs
# hiding behind eleven green examples.
#
# ⚠️ THE FILETYPE OF THE FIXTURE IS WHAT COSTS, and it is worth knowing before
# adding an example here: the first `bufload` of a `.rb` file costs **213ms** in
# a fresh editor and every later load costs 0.01ms, because nvim is loading its
# ruby ftplugin, indent and syntax runtime once per process. The same first load
# of a `.txt` file is 4.6ms. So the three examples that assert `filetype == "ruby"`
# -- the AC's own words, and the reason the new side is a real buffer at all --
# open the Ruby fixture and pay it; every other example is about buffer wiring,
# slots, folds, stamps and wipes, none of which the filetype touches, and opens a
# text fixture. That is a fixture choice, not a coverage one: the full
# `open_changeset` path runs against a real Ruby file in both directions either
# way, and the file went 6.5s -> 1.3s.

# The changeset under review, on disk. Built ONCE for the process and shared by
# every example: it is read-only input -- the new side is opened FROM it and
# never written TO it -- so rebuilding it per example would buy nothing but the
# `before(:context)` this codebase has no other instance of.
module DiffModeFixture
  FILES = {
    "lib/widget.rb" => ["class Widget", "  def call = 1", "end"],
    "docs/guide.txt" => ["the guide", "second line", "third line"],
    "docs/other.txt" => ["another document", "second line"],
    "docs/counter.txt" => (1..40).map { |i| "line #{i}" },
    # `bufnr()` treats its argument as a PATTERN, so `a[1].rb` matches `a1.rb`.
    # Both exist here because the collision only happens when both do.
    "weird/a1.rb" => ["class A1", "end"],
    "weird/a[1].rb" => ["class Bracket", "end"]
  }.freeze

  # Byte-exact, because the line endings ARE the fixture: git hands the old side
  # CRs and nvim strips them from the new side, which is the whole of the CRLF
  # defect.
  RAW = { "docs/crlf.txt" => (1..40).map { |i| "line #{i}\r\n" }.join }.freeze

  PROJECT = SocketTmpdir.persistent("lain-diff-spec")

  FILES.each do |path, lines|
    FileUtils.mkdir_p(File.join(PROJECT, File.dirname(path)))
    File.write(File.join(PROJECT, path), "#{lines.join("\n")}\n")
  end

  RAW.each do |path, bytes|
    FileUtils.mkdir_p(File.join(PROJECT, File.dirname(path)))
    File.binwrite(File.join(PROJECT, path), bytes)
  end

  PROBE_AUTOCMD = <<~LUA
    vim.api.nvim_create_autocmd({ "WinNew", "WinEnter", "BufWinEnter" }, {
      group = vim.api.nvim_create_augroup("lain_diff_probe", { clear = true }),
      pattern = "*",
      callback = function(ev)
        local win = vim.api.nvim_get_current_win()
        local world = nil
        if ev.event == "WinEnter" then
          world = { cursor = vim.api.nvim_win_get_cursor(win)[1], slots = {} }
          for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            local slot = vim.w[w].lain_review_slot
            if slot then
              world.slots[slot] = {
                vim.api.nvim_win_get_buf(w), vim.wo[w].diff, vim.api.nvim_win_get_cursor(w)[1],
              }
            end
          end
        end
        table.insert(_G.__diff_probe, { ev.event, win, vim.api.nvim_win_get_buf(win), world })
      end,
    })
  LUA

  at_exit { FileUtils.remove_entry(PROJECT) if File.directory?(PROJECT) }
end

RSpec.describe Lain::Frontend::Neovim, :nvim do
  around do |example|
    socket = File.join(Dir.tmpdir, "lain-nvim-diff-spec-#{Process.pid}-#{rand(1_000_000)}.sock")
    # chdir into the fixture: every path on this wire is repository-relative
    # (`RenderInlet#open_changeset` sends "lib/lain/agent.rb"), so the editor's
    # cwd is what resolves it -- and an absolute path in a spec would hide a
    # module that only works because the spec handed it one.
    pid = spawn("nvim", "--headless", "--clean", "-n", "--listen", socket,
                chdir: project, out: File::NULL, err: File::NULL)
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

  def project = DiffModeFixture::PROJECT

  def lua(source, args = []) = @editor.exec_lua(source, args)

  # Both revisions, always: only Ruby knows them and the note rail stamps a note
  # with the one its side was authored against.
  def revisions = { "old" => "base0ff", "new" => "head1ff" }

  # The card's entry point. `old_lines` is `git show <base>:<path>` ALREADY READ
  # -- Ruby runs git, never the editor.
  def open_changeset(path, old_lines, line = 1, revs = revisions)
    lua("_G.__lain.open_changeset(...)", [path, old_lines, line, revs])
  end

  def layout = lua("return _G.__lain.review_layout()")

  def review_tab
    lua(<<~LUA)
      for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        if vim.t[tab].lain_review then return tab end
      end
      return nil
    LUA
  end

  def windows(tab) = lua("return vim.api.nvim_tabpage_list_wins(...)", [tab])

  # slot -> window, read off the window variables the layout stamps, so this
  # never has to call `review_layout` -- which would TAKE FOCUS and destroy the
  # very fact half these examples assert.
  def slots
    lua(<<~LUA, [review_tab])
      local found = {}
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(...)) do
        local slot = vim.w[win].lain_review_slot
        if slot then found[slot] = win end
      end
      return found
    LUA
  end

  def buf_in(win) = lua("return vim.api.nvim_win_get_buf(...)", [win])

  def lines_of(buf) = lua("return vim.api.nvim_buf_get_lines(..., 0, -1, false)", [buf])

  def name_of(buf) = lua("return vim.api.nvim_buf_get_name(...)", [buf])

  # A lua table crosses msgpack with STRING keys; every expectation here reads
  # better in symbols, so the coercion happens once, here.
  def buffer_options(buf)
    lua(<<~LUA, [buf]).transform_keys(&:to_sym)
      local b = ...
      return { buftype = vim.bo[b].buftype, filetype = vim.bo[b].filetype,
               modifiable = vim.bo[b].modifiable, listed = vim.bo[b].buflisted,
               swapfile = vim.bo[b].swapfile, fileformat = vim.bo[b].fileformat }
    LUA
  end

  def window_options(win)
    lua("local w = ... return { diff = vim.wo[w].diff, foldmethod = vim.wo[w].foldmethod, " \
        "foldlevel = vim.wo[w].foldlevel, foldenable = vim.wo[w].foldenable }", [win]).transform_keys(&:to_sym)
  end

  def cursor_in(win) = lua("return vim.api.nvim_win_get_cursor(...)", [win])

  # Which 1-based lines the editor is actually HIDING in this window. The whole
  # point of the fold example: `foldmethod == "diff"` is an option, and an
  # option is not evidence that anything folded.
  def folded_lines(win, count)
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

  def here = lua("return { vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win() }")

  def refusal(*args)
    lua(<<~LUA, args)
      local ok, err = pcall(_G.__lain.open_changeset, ...)
      return { ok, tostring(err) }
    LUA
  end

  def buffer_named(name) = lua("return vim.fn.bufnr(...)", [name])

  def buffer_count = lua("return #vim.api.nvim_list_bufs()")

  def changedtick(buf) = lua("return vim.api.nvim_buf_get_changedtick(...)", [buf])

  # Every window/buffer transition, so "never displayed" can be asserted over a
  # SEQUENCE rather than over the state that happens to be left at the end.
  #
  # A WinEnter additionally carries a SNAPSHOT of the review at the instant focus
  # landed -- what each slot held, whether it was in diff mode, and where every
  # slot's cursor was. Counting WinEnters says which windows were entered but
  # nothing about WHEN, and "focus is taken last" is a claim about when: focusing
  # early and then never again is indistinguishable by count.
  #
  # PER SLOT rather than only the entered window, because focus now lands in the
  # SIDEBAR: the fact that has to be true at that instant is about a window the
  # human is not in -- the new side's cursor is already on the resolved line --
  # and the entered window's own cursor cannot say it.
  def watch_windows
    lua("_G.__diff_probe = {}\n#{DiffModeFixture::PROBE_AUTOCMD}")
  end

  def watched = lua("return _G.__diff_probe")

  # The 40-line fixture with exactly one line changed, which is §3.4's shape.
  def counter_old_lines = (1..40).map { |i| i == 20 ? "was line 20" : "line #{i}" }

  def guide_old_lines = ["the guide", "second line was different", "third line"]

  def other_old_lines = ["another document", "second line was different"]

  def widget_old_lines = ["class Widget", "  def call = 2", "end"]

  describe "the new side" do
    # `buftype=""` is the whole requirement: it is what makes the language
    # server and treesitter attach, and a `nofile` copy of the file would look
    # identical in every other assertion here.
    it "is the real file on disk, not a copy of it" do
      open_changeset("lib/widget.rb", widget_old_lines)

      buf = buf_in(slots["new"])

      expect(buffer_options(buf)).to include(buftype: "", filetype: "ruby")
      expect(name_of(buf)).to eq(File.join(project, "lib/widget.rb"))
      # From DISK, not from the argument list: an implementation that filled
      # both sides from `old_lines` satisfies every option assertion above.
      expect(lines_of(buf)).to eq(["class Widget", "  def call = 1", "end"])
    end

    # An unlisted buffer is invisible to `:ls`, `:bnext` and every buffer
    # picker, so the file the human is reviewing would be unreachable by any
    # ordinary editor gesture. `vim.fn.bufadd` creates one unlisted, which is
    # exactly the detail a reader would not think to check.
    it "is listed, like any file the human opened themselves" do
      open_changeset("docs/guide.txt", guide_old_lines)

      expect(buffer_options(buf_in(slots["new"]))).to include(listed: true, modifiable: true)
    end
  end

  describe "the old side" do
    it "carries its side in its name and is not a real file" do
      open_changeset("docs/guide.txt", guide_old_lines)

      buf = buf_in(slots["old"])

      expect(name_of(buf)).to eq("lain://review/OLD/docs/guide.txt")
      expect(buffer_options(buf)).to include(buftype: "nofile", swapfile: false)
      expect(lines_of(buf)).to eq(guide_old_lines)
    end

    # There is no path to sniff on a `lain://` name, so the filetype is set by
    # hand -- from the new side, which is the only honest source for it. Without
    # this the old half of a review renders as plain text beside a highlighted
    # new half.
    it "takes the new side's filetype, because it has no path to sniff" do
      open_changeset("lib/widget.rb", widget_old_lines)

      expect(buffer_options(buf_in(slots["old"]))).to include(filetype: "ruby")
    end

    # The old side is history: bytes the human cannot change and lain must not
    # let them think they have. `nofile` is what makes `:w` FAIL rather than
    # silently succeed somewhere -- the standing obligation, and here it is the
    # editor's own E382 rather than a `nomodified` this module set.
    it "refuses a write rather than pretending to take one" do
      open_changeset("docs/guide.txt", guide_old_lines)

      ok, message = lua(<<~LUA, [slots["old"]])
        local win = ...
        local ok, err = pcall(function()
          vim.api.nvim_win_call(win, function() vim.cmd("write") end)
        end)
        return { ok, tostring(err) }
      LUA

      expect(ok).to be(false)
      expect(message).to include("E382")
      expect(buffer_options(buf_in(slots["old"]))).to include(modifiable: false)
    end

    # §3.5: drift detection has to work on BOTH sides, and it only can if the
    # scratch buffer moves its marks the way a file buffer does. Rows are
    # 0-based here and nvim's answer is too.
    it "slides an extmark when lines are inserted above it" do
      open_changeset("docs/counter.txt", counter_old_lines)
      buf = buf_in(slots["old"])

      row = lua(<<~LUA, [buf])
        local b = ...
        local ns = vim.api.nvim_create_namespace("diff_spec")
        local id = vim.api.nvim_buf_set_extmark(b, ns, 14, 0, {})
        vim.bo[b].modifiable = true
        vim.api.nvim_buf_set_lines(b, 0, 0, false, { "# inserted", "# inserted" })
        vim.bo[b].modifiable = false
        return vim.api.nvim_buf_get_extmark_by_id(b, ns, id, {})
      LUA

      expect(row).to eq([16, 0])
    end
  end

  # BLOCKER 1. Every wave-4 card anchors extmarks in these buffers, and the old
  # side is the one this module REWRITES -- so what a whole-buffer replace does
  # to a mark is this module's problem, not the note rail's.
  describe "extmarks in the old side, across a re-open" do
    def mark_at(buf, row)
      lua(<<~LUA, [buf, row])
        local b, r = ...
        local ns = vim.api.nvim_create_namespace("diff_spec_marks")
        return vim.api.nvim_buf_set_extmark(b, ns, r, 0, {})
      LUA
    end

    def mark_row(buf, id)
      lua(<<~LUA, [buf, id])
        local b, i = ...
        local ns = vim.api.nvim_create_namespace("diff_spec_marks")
        return vim.api.nvim_buf_get_extmark_by_id(b, ns, i, {})[1]
      LUA
    end

    # `named_buf` answers the SAME buffer for a path already open, and
    # "keeps the old side when the same file is opened again" pins that reuse as
    # supported -- which is exactly what made this silent. A whole-buffer
    # `set_lines(buf, 0, -1, …)` moves every mark to the buffer's end, so a note
    # on line 20 came back reporting line 40.
    it "keeps a mark where it was when the same revision is opened again" do
      open_changeset("docs/counter.txt", counter_old_lines, 20)
      buf = buf_in(slots["old"])
      id = mark_at(buf, 19)
      tick = changedtick(buf)

      open_changeset("docs/counter.txt", counter_old_lines, 20)

      expect(buf_in(slots["old"])).to eq(buf)
      expect(mark_row(buf, id)).to eq(19)
      # And NOTHING was told the buffer changed. A zero-length `set_lines` at the
      # buffer end leaves every mark in place too, but still bumps 'changedtick'
      # and fires `on_lines` -- so an unchanged re-open would announce a change to
      # exactly the listeners the note rail's drift detection is built on. Not
      # moving a mark is half of it; not raising the signal is the other half.
      expect(changedtick(buf)).to eq(tick)
    end

    # The asymmetry is what makes the bug dangerous: the new side is a real file
    # buffer that is never refilled, so it keeps its marks regardless. Two sides
    # that diverge only on re-open is noticed as "my notes moved" long after the
    # cause, so both are pinned together.
    it "keeps marks on both sides, not just the side that is never rewritten" do
      open_changeset("docs/counter.txt", counter_old_lines, 20)
      old_buf = buf_in(slots["old"])
      new_buf = buf_in(slots["new"])
      old_id = mark_at(old_buf, 19)
      new_id = mark_at(new_buf, 19)

      open_changeset("docs/counter.txt", counter_old_lines, 20)

      expect([mark_row(old_buf, old_id), mark_row(new_buf, new_id)]).to eq([19, 19])
    end

    # When the content genuinely differs -- the base moved under a re-review --
    # only the differing span is rewritten. A mark BEFORE it keeps its row, which
    # is what makes the write minimal rather than merely idempotent; a mark
    # inside it moves, and that is drift for the note rail to report rather than
    # something this module should hide.
    it "leaves marks outside the changed span alone when the old side really changes" do
      open_changeset("docs/counter.txt", counter_old_lines, 20)
      buf = buf_in(slots["old"])
      before = mark_at(buf, 2)
      after = mark_at(buf, 38)

      open_changeset("docs/counter.txt", counter_old_lines.map { |l| l == "was line 20" ? "moved on" : l }, 20)

      expect([mark_row(buf, before), mark_row(buf, after)]).to eq([2, 38])
    end
  end

  describe "the pair" do
    it "lands each side in its own slot, not both in whichever window comes first" do
      open_changeset("docs/guide.txt", guide_old_lines)

      pair = slots

      expect(name_of(buf_in(pair["old"]))).to eq("lain://review/OLD/docs/guide.txt")
      expect(name_of(buf_in(pair["new"]))).to eq(File.join(project, "docs/guide.txt"))
      expect(buf_in(pair["sidebar"])).not_to eq(buf_in(pair["new"]))
      expect(buf_in(pair["sidebar"])).not_to eq(buf_in(pair["old"]))
    end

    it "puts both windows in diff mode" do
      open_changeset("docs/guide.txt", guide_old_lines)

      pair = slots

      expect(window_options(pair["old"])).to include(diff: true)
      expect(window_options(pair["new"])).to include(diff: true)
      # The sidebar is a navigator and must not join the diff: a third window
      # in diff mode diffs against both sides and the fold sets stop meaning
      # anything.
      expect(window_options(pair["sidebar"])).to include(diff: false)
    end

    # §3.4's expand-context affordance, asserted as lines the editor is actually
    # HIDING. The layout's own panel found a fold example that passed on two
    # empty placeholders because identical buffers fold completely -- so the changed
    # line being VISIBLE is half the assertion, and it is the half that fails
    # when the two sides are the same bytes.
    # Opened on the CHANGED line, which is where the sidebar's gesture resolves:
    # a target inside an unchanged region legitimately opens the fold around it
    # (the example below), so landing on line 1 here would measure `zv` rather
    # than the fold set.
    it "folds the unchanged regions away on both sides and leaves the change visible" do
      open_changeset("docs/counter.txt", counter_old_lines, 20)

      pair = slots
      hidden = { "old" => folded_lines(pair["old"], 40), "new" => folded_lines(pair["new"], 40) }

      # Six lines of context each side of the change stay open; the other 27 of
      # 40 fold. Both sides agree, which is what makes the pair readable.
      expect(hidden["old"]).to eq([*1..13, *27..40])
      expect(hidden["new"]).to eq(hidden["old"])
      expect(hidden["old"]).not_to include(20)
      expect(window_options(pair["old"])).to include(foldmethod: "diff", foldenable: true)
      expect(window_options(pair["new"])).to include(foldmethod: "diff", foldenable: true)
    end

    # `foldmethod=diff` has just closed every unchanged region, so a target
    # inside one arrives on a CLOSED FOLD -- the human is shown a one-line
    # summary instead of the line they asked for. The sidebar's gesture resolves
    # to hunk lines, which are never folded; the note and diagnostic rails
    # navigate to arbitrary anchors, so this is theirs.
    it "opens just enough fold to show a target inside an unchanged region" do
      open_changeset("docs/counter.txt", counter_old_lines, 5)

      expect(cursor_in(slots["new"]).first).to eq(5)
      expect(folded_lines(slots["new"], 40)).not_to include(5)
      # Just enough: the far unchanged region is still folded.
      expect(folded_lines(slots["new"], 40)).to include(40)
    end

    it "puts the cursor on the line the gesture resolved to" do
      open_changeset("docs/counter.txt", counter_old_lines, 20)

      expect(cursor_in(slots["new"]).first).to eq(20)
    end

    # A line past the end of the file is a resolved target that no longer
    # exists, and `nvim_win_set_cursor` RAISES on one -- which would take the
    # whole render down rather than opening the file at its end.
    it "clamps a target line the file no longer reaches" do
      open_changeset("docs/guide.txt", guide_old_lines, 900)

      expect(cursor_in(slots["new"]).first).to eq(3)
    end
  end

  describe "the stamps a note is authored against" do
    it "stamps each buffer with its own side and revision" do
      open_changeset("docs/guide.txt", guide_old_lines)

      pair = slots
      stamps = lua(<<~LUA, [buf_in(pair["old"]), buf_in(pair["new"])])
        local o, n = ...
        return { { vim.b[o].lain_review_side, vim.b[o].lain_review_revision },
                 { vim.b[n].lain_review_side, vim.b[n].lain_review_revision } }
      LUA

      expect(stamps).to eq([%w[old base0ff], %w[new head1ff]])
    end

    # The REPOSITORY-RELATIVE path, on both sides, as a variable rather than as
    # something the note rail recovers by parsing the old side's `lain://` name
    # -- that parser would be a second spelling of the prefix with nothing
    # pinning it here. The new side cannot supply it by name at all: its name is
    # the absolute path the editor resolved, and Ruby keys on what it sent.
    it "stamps both sides with the path Ruby sent, not the one the editor resolved" do
      open_changeset("docs/guide.txt", guide_old_lines)

      pair = slots
      paths = lua(<<~LUA, [buf_in(pair["old"]), buf_in(pair["new"])])
        local o, n = ...
        return { vim.b[o].lain_review_path, vim.b[n].lain_review_path }
      LUA

      expect(paths).to eq(["docs/guide.txt", "docs/guide.txt"])
      expect(name_of(buf_in(pair["new"]))).to eq(File.join(project, "docs/guide.txt"))
    end

    # A revision that never arrives is a note recorded against no diff at all,
    # and the note rail would journal it silently. Loud, and naming what was
    # missing -- `review_place`'s own refusal shape one module over.
    it "refuses a changeset whose revisions are incomplete, naming what is missing" do
      ok, message = lua(<<~LUA, ["docs/guide.txt", guide_old_lines, 1, { "old" => "base0ff" }])
        local ok, err = pcall(_G.__lain.open_changeset, ...)
        return { ok, tostring(err) }
      LUA

      expect(ok).to be(false)
      expect(message).to include("new").and include("revision")
      expect(review_tab).to be_nil
    end

    it "refuses an empty revision, not only a missing one" do
      ok, message = refusal("docs/guide.txt", guide_old_lines, 1, { "old" => "", "new" => "head1ff" })

      expect(ok).to be(false)
      expect(message).to include("old").and include("revision")
    end

    # `nvim_buf_set_lines` raises on a string carrying a newline. Refusing at the
    # ARGUMENTS rather than at the write is what keeps the half-drawn review the
    # module's own comment forbids from existing: a raise part-way leaves a
    # tabpage and two buffers behind, and the next open inherits them.
    it "refuses a line carrying a newline before it has built anything" do
      before = buffer_count

      ok, message = refusal("docs/guide.txt", %W[fine two\nlines], 1, revisions)

      expect(ok).to be(false)
      expect(message).to include("old_lines[2]")
      expect(review_tab).to be_nil
      expect(buffer_named("lain://review/OLD/docs/guide.txt")).to eq(-1)
      # NOTHING, which includes the new side: validating after `new_side` leaves
      # a buffer for the file behind, and the next open inherits it.
      expect(buffer_count).to eq(before)
    end

    # A Ruby `nil` crosses msgpack as `vim.NIL`, which is USERDATA and therefore
    # TRUTHY -- so the `old_lines or {}` a reader would write is dead code that
    # hands userdata to the API. A file added by the changeset has no old side.
    # Passed as an ARGUMENT, not written as a lua `nil`: a literal nil is a real
    # nil, while a Ruby nil crossing msgpack arrives as `vim.NIL` -- and vim.NIL
    # is what defeats an `or` guard. Spelling it in the lua source would test the
    # one case that was never in doubt.
    it "treats a missing old side as empty rather than as a truthy value" do
      lua("_G.__lain.open_changeset(...)", ["docs/guide.txt", nil, 1, revisions])

      expect(lines_of(buf_in(slots["old"]))).to eq([""])
      expect(buffer_options(buf_in(slots["old"]))).to include(buftype: "nofile")
    end
  end

  describe "opening a second file" do
    # [diffview#509]: the previously focused buffer flashes in both diff windows
    # because the WINDOW is made before the buffer is. Asserted over the whole
    # transition sequence rather than the final state, because the final state is
    # identical either way -- that is what makes it a flash and not a bug you can
    # see afterwards.
    #
    # PER WINDOW, and that is the half a mutation probe caught: collecting what
    # both diff windows showed and comparing it against "the two sides" passes an
    # implementation that shows the OLD buffer in the NEW window on its way to
    # the right answer, because the old buffer is one of the two sides. A flash
    # is a window displaying a buffer that is not ITS side, so each window is
    # pinned to its own.
    it "never displays anything but its own side in either diff window" do
      open_changeset("docs/guide.txt", guide_old_lines)
      first = slots
      sidebar_buf = buf_in(first["sidebar"])
      lua("vim.api.nvim_set_current_win(...)", [first["sidebar"]])
      watch_windows

      open_changeset("docs/other.txt", other_old_lines)

      second = slots
      diff_wins = [second["old"], second["new"]]
      shown = watched.select { |(_, win, _)| diff_wins.include?(win) }
                     .group_by { |(_, win, _)| win }
                     .transform_values { |events| events.map { |(_, _, buf, _)| buf }.uniq }
      expect(shown).to eq(second["old"] => [buf_in(second["old"])],
                          second["new"] => [buf_in(second["new"])])
      expect(shown.values.flatten).not_to include(sidebar_buf)
    end

    # Focus is a flash too, and COUNTING the windows entered does not catch it:
    # focusing the sidebar early and never again enters exactly the same window
    # exactly once. What distinguishes early from late is the state of the review
    # AT THE INSTANT focus lands, so that is what is asserted -- when the human
    # arrives, both sides are already placed, both windows are already in diff
    # mode, and the new side's cursor is already on the target.
    #
    # The human is parked on the NEW side first, so that landing in the sidebar
    # is a real move and produces a WinEnter to read. `nvim_win_call` (how
    # `diffthis` runs) fires no WinEnter, so a real focus change is the only
    # thing that can produce one of these snapshots.
    it "does not take focus until the pair is completely built" do
      open_changeset("docs/guide.txt", guide_old_lines)
      lua("vim.api.nvim_set_current_win(...)", [slots["new"]])
      watch_windows

      open_changeset("docs/counter.txt", counter_old_lines, 20)

      pair = slots
      entered = watched.select { |(event, _, _, _)| event == "WinEnter" }
      expect(entered.map { |(_, win, _, _)| win }).to eq([pair["sidebar"]])
      expect(entered.first.last["slots"]).to eq(
        "sidebar" => [buf_in(pair["sidebar"]), false, 1],
        "old" => [buf_in(pair["old"]), true, 20],
        "new" => [buf_in(pair["new"]), true, 20]
      )
    end

    # "Exactly one WinEnter" is not the invariant either: a human already sitting
    # in the sidebar -- which is where the previous open left them -- is not moved
    # at all, and zero is the right answer there. What is always true is where
    # they END UP, which is why that is the pin and the snapshot above is the one
    # that talks about ordering.
    it "moves nobody who is already on the sidebar, and still lands the pair complete" do
      open_changeset("docs/guide.txt", guide_old_lines)
      watch_windows

      open_changeset("docs/counter.txt", counter_old_lines, 20)

      expect(watched.select { |(event, _, _, _)| event == "WinEnter" }).to be_empty
      expect(here).to eq([review_tab, slots["sidebar"]])
      expect(cursor_in(slots["new"]).first).to eq(20)
      expect(window_options(slots["new"])).to include(diff: true)
    end

    # The layout's own spec covers the human closing a pane, and `buf_for`
    # restores what the slot last held -- so a rebuilt window is born holding the
    # PREVIOUS file. Nothing
    # drove that path here. It is not a visible flash (the whole open is one
    # synchronous call, so no redraw lands inside it -- which is what the
    # no-async guard below is really protecting), but the pane must end up
    # showing the new file, in diff mode, either way.
    %w[old new].each do |closed|
      it "shows the new file in the #{closed} pane after the human closed it" do
        open_changeset("docs/guide.txt", guide_old_lines)
        stale = buf_in(slots["new"])
        lua("vim.api.nvim_win_close(..., true)", [slots[closed]])

        open_changeset("docs/other.txt", other_old_lines)

        pair = slots
        expect(name_of(buf_in(pair["new"]))).to eq(File.join(project, "docs/other.txt"))
        expect(lines_of(buf_in(pair["old"]))).to eq(other_old_lines)
        expect(window_options(pair[closed])).to include(diff: true, foldmethod: "diff")
        # The previous file is left nowhere on screen.
        expect([buf_in(pair["old"]), buf_in(pair["new"]), buf_in(pair["sidebar"])]).not_to include(stale)
      end
    end

    # The other half of the same fix, and the one that says WHY there is no
    # flash: the pair is not re-split per file. A `split <path>` implementation
    # makes a new window every time -- which is where the flash comes from, and
    # it leaves the old pair behind.
    it "reuses the pair's windows rather than splitting a new one" do
      open_changeset("docs/guide.txt", guide_old_lines)
      before = slots
      watch_windows

      open_changeset("docs/other.txt", other_old_lines)

      expect(slots).to eq(before)
      expect(watched.map(&:first)).not_to include("WinNew")
      expect(windows(review_tab).size).to eq(3)
    end

    it "shows the second file on both sides" do
      open_changeset("docs/guide.txt", guide_old_lines)

      open_changeset("docs/other.txt", other_old_lines)

      pair = slots
      expect(name_of(buf_in(pair["new"]))).to eq(File.join(project, "docs/other.txt"))
      expect(lines_of(buf_in(pair["old"]))).to eq(other_old_lines)
    end

    # The layout's `buf_for` guards `nvim_buf_is_valid` BECAUSE this happens: the old
    # side is a per-file scratch buffer, so the previous file's is wiped rather
    # than left to accumulate one hidden buffer per file across a review.
    it "wipes the old side it is replacing" do
      open_changeset("docs/guide.txt", guide_old_lines)
      stale = buf_in(slots["old"])

      open_changeset("docs/other.txt", other_old_lines)

      expect(lua("return vim.api.nvim_buf_is_valid(...)", [stale])).to be(false)
      expect(buffer_named("lain://review/OLD/docs/guide.txt")).to eq(-1)
    end

    # Re-opening the SAME file must not wipe the buffer it just placed, which is
    # what a "wipe every old side but mine" rule gets wrong when `named_buf`
    # answers the existing buffer by name.
    it "keeps the old side when the same file is opened again" do
      open_changeset("docs/guide.txt", guide_old_lines)
      first = buf_in(slots["old"])

      open_changeset("docs/guide.txt", guide_old_lines)

      expect(lua("return vim.api.nvim_buf_is_valid(...)", [first])).to be(true)
      expect(buf_in(slots["old"])).to eq(first)
      expect(lines_of(buf_in(slots["old"]))).to eq(guide_old_lines)
    end
  end

  describe "where the human ends up" do
    # `open_changeset` exists ONLY as the answer to a human asking for a file --
    # nothing else calls it -- so it PRESENTS the review, and that is the
    # distinction `review_place`'s "moves nobody" draws rather than a violation
    # of it: the rule is about a render arriving unbidden while the human reads
    # something else.
    #
    # It lands them in the SIDEBAR rather than on the new side, and the reason is
    # the one below it in this file: the new side is the real file, `buftype = ""`
    # and modifiable on purpose, while the gesture the sidebar's banner teaches
    # next is `x` -- which in a real file is delete-character, silently editing
    # the source the human came to read. The navigator is the surface the review's
    # own keys are bound on, so leaving the human there is not "leaving them in
    # the navigator", it is leaving them where the next gesture works.
    it "lands the human in the sidebar, from wherever they were" do
      layout
      session_tab = lua("return vim.api.nvim_list_tabpages()").first
      lua("vim.api.nvim_set_current_tabpage(...)", [session_tab])

      open_changeset("docs/guide.txt", guide_old_lines, 2)

      expect(here).to eq([review_tab, slots["sidebar"]])
      # The tabpage still holds the whole review, drawn and waiting: landing in
      # the sidebar is a focus decision, not a smaller layout.
      expect(slots.keys).to contain_exactly("sidebar", "old", "new")
      expect(windows(review_tab).size).to eq(3)
      # ON the resolved line, not merely drawn: the human reaches the file with
      # `<C-w>l<C-w>l` -- slot order is sidebar, old, new, so one motion lands on
      # the history side -- and arrives where the gesture pointed. A pane parked
      # at the top of the file is the gesture half-honoured.
      expect(cursor_in(slots["new"]).first).to eq(2)
    end

    # The trap this card closes, stated as the thing that must NOT be true: the
    # cursor is not in a file on disk when the human's next keystroke arrives.
    it "does not leave the cursor in the file the review is of" do
      open_changeset("docs/guide.txt", guide_old_lines, 2)

      expect(here.last).not_to eq(slots["new"])
      expect(buf_in(here.last)).not_to eq(buf_in(slots["new"]))
      expect(buffer_options(buf_in(here.last))).to include(buftype: "nofile")
    end

    # The same fact, against the case the slot marker gets WRONG -- and the
    # reason `landing` reads the buffer rather than trusting `lain_review_slot`.
    # The marker lives on the WINDOW and the buffer inside it is the human's to
    # change: `gf` on a sidebar row, a `:b#`, a quickfix jump or the plain
    # `:edit` used here all leave the window still marked `sidebar` while it
    # displays a real, writable file. Focusing it by its marker lands the
    # review in a real file again, under the sidebar's own name, and every
    # other example in this block stays green while it does.
    it "does not land in a real file the human left in the sidebar's window" do
      open_changeset("docs/guide.txt", guide_old_lines)
      lua(<<~LUA, [slots["sidebar"], File.join(project, "docs/counter.txt")])
        local win, path = ...
        vim.api.nvim_win_call(win, function() vim.cmd("edit " .. vim.fn.fnameescape(path)) end)
      LUA

      open_changeset("docs/other.txt", other_old_lines)

      expect(buffer_options(buf_in(here.last))).to include(buftype: "nofile", modifiable: false)
      expect(name_of(buf_in(here.last))).not_to eq(File.join(project, "docs/counter.txt"))
    end

    # The narrow half of the same door, and the reason `inert` is not simply
    # "not a file buffer". `acwrite` is modifiable and its `:w` runs a
    # BufWriteCmd that performs real file operations -- it is what oil.nvim,
    # fugitive and netrw put in a window -- so a stray keystroke there reaches
    # the filesystem exactly as it would in a `buftype = ""` buffer. Narrower
    # than the plain wandered-window case (it needs a wandered sidebar window
    # AND a `<CR>` fired from somewhere else), and narrow is how that defect
    # survived a full round.
    it "does not land in a write-capable plugin buffer left in the sidebar's window" do
      open_changeset("docs/guide.txt", guide_old_lines)
      wandered = lua(<<~LUA, [slots["sidebar"]])
        local win = ...
        local buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(buf, "oil://" .. vim.fn.getcwd())
        vim.bo[buf].buftype = "acwrite"
        vim.api.nvim_win_set_buf(win, buf)
        return buf
      LUA

      open_changeset("docs/other.txt", other_old_lines)

      expect(buf_in(here.last)).not_to eq(wandered)
      expect(buffer_options(buf_in(here.last))).to include(buftype: "nofile", modifiable: false)
    end

    # And the fix that was NOT taken, pinned so a later card cannot take it by
    # accident: the new side stays the real file, and stays REACHABLE -- drawn in
    # the review's own tabpage beside the human rather than under their cursor.
    # `47_diff.lua`'s header argues `buftype = ""` at length -- it is what makes
    # the language server and treesitter attach -- so making the window safe by
    # making the buffer inert would trade every reading tool for a focus decision
    # that already suffices.
    #
    # The Ruby fixture, and one of only three examples in this file that pays the
    # ~213ms ftplugin load: `filetype` is half of what is being protected here,
    # and a text fixture cannot say the language tooling still has something to
    # attach to.
    it "keeps the new side a real editable file, drawn beside the human not under them" do
      open_changeset("lib/widget.rb", widget_old_lines, 2)

      expect(buffer_options(buf_in(slots["new"])))
        .to include(buftype: "", filetype: "ruby", modifiable: true, listed: true)
      expect(windows(review_tab)).to include(slots["new"])
      expect(here.last).not_to eq(slots["new"])
    end

    # The other half, and the one that keeps the move HONEST: focus is this entry
    # point's own decision, not something the layout does on any render. A
    # sidebar re-render goes through the same seam and must still move nobody --
    # otherwise every scope toggle would yank the human out of the diff.
    it "leaves a sidebar render where it found the human" do
      open_changeset("docs/guide.txt", guide_old_lines)
      lua("vim.api.nvim_set_current_tabpage(...)", [lua("return vim.api.nvim_list_tabpages()").first])
      where = here

      lua("_G.__lain.review_place('sidebar', ...)", [lua("return vim.api.nvim_create_buf(false, true)")])

      expect(here).to eq(where)
    end

    it "builds the review tabpage when there is not one yet" do
      expect(review_tab).to be_nil

      open_changeset("docs/guide.txt", guide_old_lines)

      expect(review_tab).not_to be_nil
      expect(slots.keys).to contain_exactly("sidebar", "old", "new")
    end
  end

  # BLOCKER 2. Paths arrive repository-relative and the editor's working
  # directory belongs to the HUMAN: `:cd`, `:lcd`, `:tcd`, 'autochdir' and every
  # rooter plugin move it. Resolving against it costs real data -- the new side
  # becomes a buffer for a file that does not exist, silently empty, and still
  # `buftype = ""`, so a `:w` CREATES it.
  describe "resolving a path the human's cwd cannot reach" do
    { "cd" => "a global :cd", "lcd" => "a window-local :lcd", "tcd" => "a tab-local :tcd" }
      .each do |command, description|
      it "opens the real file after #{description}" do
        lua("vim.cmd('#{command} docs')")

        open_changeset("docs/guide.txt", guide_old_lines)

        buf = buf_in(slots["new"])
        expect(name_of(buf)).to eq(File.join(project, "docs/guide.txt"))
        expect(lines_of(buf)).to eq(["the guide", "second line", "third line"])
      end
    end

    # The damage, stated as its own fact: the wrong resolution does not fail, it
    # opens an empty writable buffer for a path nobody meant.
    it "never invents a file under the directory the human moved to" do
      lua("vim.cmd('cd docs')")

      open_changeset("docs/guide.txt", guide_old_lines)

      expect(File.exist?(File.join(project, "docs/docs"))).to be(false)
      expect(lines_of(buf_in(slots["new"]))).not_to eq([""])
    end

    # The spelling matters, and "frozen before any :lcd can exist" was my wrong
    # reason for thinking it did not: lain attaches to an editor the human is
    # ALREADY RUNNING, and a session or rooter plugin may have :lcd'd the current
    # window long before. Re-injecting the runtime is exactly that attach, and it
    # is the plugin's own path -- `getcwd()` would freeze the window-local
    # directory as the project root.
    it "captures the global cwd at attach, not whichever window was lcd'd" do
      lua("vim.cmd('lcd docs')")
      lua(Lain::Frontend::Neovim::RuntimeLoader.new.source,
          [Lain::VERSION, Lain::Frontend::Neovim::PROTOCOL, @editor.channel_id])

      open_changeset("docs/guide.txt", guide_old_lines)

      expect(name_of(buf_in(slots["new"]))).to eq(File.join(project, "docs/guide.txt"))
    end

    # The old side's name embeds the path verbatim, so an absolute one spells
    # `lain://review/OLD//abs/path` -- a doubled separator and a name outside the
    # contract the note rail reads the side and the path back out of.
    it "refuses an absolute path rather than embedding it in the old side's name" do
      before = buffer_count

      ok, message = refusal(File.join(project, "docs/guide.txt"), guide_old_lines, 1, revisions)

      expect(ok).to be(false)
      expect(message).to include("relative")
      expect(buffer_count).to eq(before)
      expect(review_tab).to be_nil
    end

    it "lets an editor started elsewhere name the project itself" do
      elsewhere = socket_tmpdir("lain-diff-elsewhere")
      FileUtils.mkdir_p(File.join(elsewhere, "docs"))
      File.write(File.join(elsewhere, "docs/guide.txt"), "from elsewhere\n")
      lua("vim.g.lain_review_root = ...", [elsewhere])

      open_changeset("docs/guide.txt", guide_old_lines)

      expect(lines_of(buf_in(slots["new"]))).to eq(["from elsewhere"])
    ensure
      FileUtils.remove_entry(elsewhere) if elsewhere
    end
  end

  # A panel should-fix, and the ruling one language out: git hands the old side
  # its CRs, nvim strips them from a `fileformat=dos` new side, so left alone
  # every single line differs from its twin -- the diff calls the whole file
  # changed and `foldmethod=diff` folds nothing at all.
  describe "a file with CRLF line endings" do
    def crlf_old_lines = (1..40).map { |i| i == 20 ? "was line 20\r" : "line #{i}\r" }

    it "presents both sides the way nvim presents the file, so the diff is real" do
      open_changeset("docs/crlf.txt", crlf_old_lines, 20)

      pair = slots
      expect(buffer_options(buf_in(pair["new"]))).to include(fileformat: "dos")
      expect(buffer_options(buf_in(pair["old"]))).to include(fileformat: "dos")
      expect(lines_of(buf_in(pair["old"])).first).to eq("line 1")
    end

    it "folds the unchanged regions, which is what the carriage returns destroyed" do
      open_changeset("docs/crlf.txt", crlf_old_lines, 20)

      hidden = folded_lines(slots["new"], 40)
      expect(hidden).to eq([*1..13, *27..40])
      expect(hidden).not_to include(20)
    end
  end

  # A stamp is a claim that this buffer IS the review. The new side is a real
  # file buffer that is never wiped, stays listed and outlives the review, so a
  # stamp left behind tells the note and diagnostic rails to anchor into a file
  # nobody is reviewing -- a wrong answer rather than a missing one.
  describe "stamps as the review moves on" do
    it "withdraws the stamps from the file the human has left" do
      open_changeset("docs/guide.txt", guide_old_lines)
      left = buf_in(slots["new"])

      open_changeset("docs/other.txt", other_old_lines)

      stamps = lua(<<~LUA, [left])
        local b = ...
        return { vim.b[b].lain_review_side, vim.b[b].lain_review_revision, vim.b[b].lain_review_path }
      LUA
      expect(stamps).to eq([])
      expect(lua("return vim.api.nvim_buf_is_valid(...)", [left])).to be(true)
    end

    it "leaves exactly the two buffers of the current file stamped" do
      open_changeset("docs/guide.txt", guide_old_lines)

      open_changeset("docs/other.txt", other_old_lines)

      stamped = lua(<<~LUA)
        local found = {}
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if vim.b[b].lain_review_side ~= nil then table.insert(found, b) end
        end
        return found
      LUA
      expect(stamped).to contain_exactly(buf_in(slots["old"]), buf_in(slots["new"]))
    end
  end

  # `drop_stale` matches on the `lain://review/OLD/` prefix, and
  # every other lain buffer begins `lain://` too -- widening it by one path
  # segment wipes the human's session out from under them.
  describe "what the per-file wipe may not touch" do
    it "leaves every other lain:// buffer alone" do
      others = lua(<<~LUA)
        local made = {}
        for _, name in ipairs({ "lain://journal", "lain://timeline", "lain://inbox",
                                "lain://workspace", "lain://request", "lain://compose" }) do
          local b = vim.api.nvim_create_buf(true, true)
          vim.api.nvim_buf_set_name(b, name)
          made[name] = b
        end
        return made
      LUA

      open_changeset("docs/guide.txt", guide_old_lines)
      open_changeset("docs/other.txt", other_old_lines)

      still = others.transform_values { |buf| lua("return vim.api.nvim_buf_is_valid(...)", [buf]) }
      expect(still.values).to all(be(true))
      expect(still.size).to eq(6)
    end
  end

  # `vim.fn.bufnr(name)` -- how `named_buf` finds an existing
  # buffer -- treats its argument as a PATTERN: measured, `…/weird/a[1].rb`
  # answers `…/weird/a1.rb`'s buffer even once the literal one exists. This
  # module is that function's first caller passing a path a human chose, and
  # `[slug].tsx` routes make it ordinary.
  describe "a path that looks like a pattern" do
    it "does not write one file's review into another file's buffer" do
      open_changeset("weird/a1.rb", ["class A1", "  # was", "end"])
      a1 = buf_in(slots["old"])

      open_changeset("weird/a[1].rb", ["class Bracket", "  # was", "end"])

      bracket = buf_in(slots["old"])
      expect(bracket).not_to eq(a1)
      expect(name_of(bracket)).to eq("lain://review/OLD/weird/a[1].rb")
      expect(lines_of(bracket)).to eq(["class Bracket", "  # was", "end"])
      expect(lines_of(buf_in(slots["new"]))).to eq(["class Bracket", "end"])
      # The buffer built on this path is a `named_buf` in every respect that
      # matters, or the old side silently becomes writable for exactly the
      # files whose names happen to look like patterns.
      expect(buffer_options(bracket)).to include(buftype: "nofile", modifiable: false, swapfile: false)
    end

    it "keeps the name, the content and the stamp naming the same file" do
      open_changeset("weird/a1.rb", ["class A1", "end"])
      open_changeset("weird/a[1].rb", ["class Bracket", "end"])

      buf = buf_in(slots["old"])
      stamped = lua("return vim.b[...].lain_review_path", [buf])
      expect(stamped).to eq("weird/a[1].rb")
      expect(name_of(buf)).to eq("lain://review/OLD/#{stamped}")
    end

    # An old side that is ALREADY what a fresh buffer holds -- `git show` of an
    # empty file is one empty line, which is exactly a new buffer's content -- is
    # the branch where `refill` returns without writing, so nothing restores the
    # resting options afterwards. The constructor is then the only thing standing
    # between the human and an editable copy of history.
    it "rests nomodifiable even when there is nothing to write into it" do
      open_changeset("weird/a1.rb", ["class A1", "end"])

      open_changeset("weird/a[1].rb", [""])

      buf = buf_in(slots["old"])
      expect(name_of(buf)).to eq("lain://review/OLD/weird/a[1].rb")
      expect(lines_of(buf)).to eq([""])
      expect(buffer_options(buf)).to include(modifiable: false, buftype: "nofile")
    end

    # RE-opening it is where the literal scan earns its place, and it needs no
    # second file to go wrong: a pattern does not match ITSELF once the brackets
    # are a character class, so `bufnr` answers -1 for a buffer that plainly
    # exists. Without the scan the module would build a SECOND buffer under a
    # name already taken -- and the marks on the first would be orphaned, which
    # is BLOCKER 1 arriving by another road.
    it "finds its own buffer again when a pattern-shaped path is re-opened" do
      open_changeset("weird/a[1].rb", ["class Bracket", "  # was", "end"])
      first = buf_in(slots["old"])
      id = lua(<<~LUA, [first])
        local b = ...
        return vim.api.nvim_buf_set_extmark(b, vim.api.nvim_create_namespace("diff_spec_marks"), 1, 0, {})
      LUA

      open_changeset("weird/a[1].rb", ["class Bracket", "  # was", "end"])

      expect(buf_in(slots["old"])).to eq(first)
      expect(name_of(first)).to eq("lain://review/OLD/weird/a[1].rb")
      expect(lua(<<~LUA, [first, id])).to eq(1)
        local b, i = ...
        return vim.api.nvim_buf_get_extmark_by_id(b, vim.api.nvim_create_namespace("diff_spec_marks"), i, {})[1]
      LUA
    end
  end

  # A survey of files as they stand presents ONE side, and Ruby says so on
  # the sidebar rail before any row is opened ({RpcThread::SET_REVIEW}'s third
  # argument). The old side is then not a window with an empty buffer in it --
  # it is not built at all, and neither is the buffer.
  describe "a round that presents one side" do
    # The sidebar render that carries the fact. It is what precedes the layout,
    # so it is also the only place the fact can arrive in time.
    def set_review(lines, generation, sides) = lua("_G.__lain.set_review(...)", [lines, generation, sides])

    def surveyed(path, line = 1)
      set_review(["[ ] #{path}"], 1, ["new"])
      # {Frontend::Neovim::ChangesetDiff#open} reads the old side off
      # {Review::Changeset#old_side}, which answers `[]` for every corpus file.
      lua("_G.__lain.open_changeset(...)", [path, [], line, revisions])
    end

    def slot_names = windows(review_tab).map { |win| lua("return vim.w[...].lain_review_slot", [win]) }

    it "holds the sidebar and the file, and nothing else" do
      surveyed("docs/guide.txt")

      expect(slot_names).to eq(%w[sidebar new])
    end

    it "shows the real file on disk in the one window it opened" do
      surveyed("docs/guide.txt")

      expect(name_of(buf_in(slots["new"]))).to eq(File.join(project, "docs/guide.txt"))
      expect(lines_of(buf_in(slots["new"]))).to eq(["the guide", "second line", "third line"])
    end

    # Not merely "no window": the old side's buffer is what `git show` fills and
    # a survey has nothing to put in it, so building one and then hiding it
    # would leave a `lain://review/OLD/...` buffer per file opened.
    it "creates no old-side buffer for the file" do
      surveyed("docs/guide.txt")

      expect(buffer_named("lain://review/OLD/docs/guide.txt")).to eq(-1)
    end

    # A DIFF NEEDS TWO WINDOWS. `diffthis` on one alone still sets
    # 'foldmethod=diff', which folds every line the absent other side did not
    # change -- the whole file, collapsed, on the surface a survey exists to let
    # somebody read.
    it "never puts the lone window in diff mode" do
      surveyed("docs/counter.txt")

      expect(window_options(slots["new"])).to include(diff: false)
      expect(folded_lines(slots["new"], 40)).to be_empty
    end

    it "leaves it out of diff mode after a later render of the same round" do
      surveyed("docs/counter.txt")

      set_review(["[x] docs/counter.txt"], 2, ["new"])

      expect(window_options(slots["new"])).to include(diff: false)
      expect(folded_lines(slots["new"], 40)).to be_empty
    end

    # `landing` falls back to the old side because it is the one window that
    # cannot be a file. There is no such window here, so the chain has to end
    # somewhere that exists rather than at `nvim_set_current_win(nil)`.
    it "lands the human somewhere real rather than raising on a nil window" do
      surveyed("docs/guide.txt")

      expect(here.last).to eq(slots["sidebar"])
    end

    # THE FALLBACK, ACTUALLY REACHED -- and the example above does not reach it,
    # which is why this one exists. `landing` prefers the navigator and REJECTS
    # it when it is not inert: a `gf` on a row, a `:b#`, a quickfix jump or a
    # plain `:edit` all leave the window still marked `sidebar` while it displays
    # a real, writable file, which is the same defect wearing the navigator's
    # name. On a two-sided round the chain then ends on the old side, the one
    # window that cannot be a file. A survey has no such window, so a fallback of
    # `old_win` alone hands `nvim_set_current_win` a nil and the render raises
    # (`Invalid 'win': Expected Lua number`) AFTER it has already drawn the file
    # correctly -- the worst shape a refusal can take.
    it "lands on the file when the navigator is unsafe and the round has no old side" do
      set_review(["[ ] docs/guide.txt"], 1, ["new"])
      lua("vim.api.nvim_win_call(..., function() vim.cmd('edit docs/counter.txt') end)", [slots["sidebar"]])

      lua("_G.__lain.open_changeset(...)", ["docs/guide.txt", [], 1, revisions])

      expect(here.last).to eq(slots["new"])
    end

    # THE ROUND AND THE FILE ARE DIFFERENT QUESTIONS. A changeset's added file
    # has an empty old side and still gets its window; a survey has no old side
    # at all. Inferring one from `old_lines` would collapse the two.
    it "still builds three windows for an added file in a two-sided round" do
      set_review(["[ ] docs/guide.txt"], 1, %w[old new])

      lua("_G.__lain.open_changeset(...)", ["docs/guide.txt", [], 1, revisions])

      expect(slot_names).to eq(%w[sidebar old new])
      expect(lines_of(buf_in(slots["old"]))).to eq([""])
      expect(window_options(slots["new"])).to include(diff: true)
    end

    it "is unchanged for a changeset review that presents both sides" do
      set_review(["[ ] docs/guide.txt"], 1, %w[old new])

      open_changeset("docs/guide.txt", ["the guide", "was second", "third line"])

      expect(slot_names).to eq(%w[sidebar old new])
      expect(window_options(slots["old"])).to include(diff: true)
      expect(window_options(slots["new"])).to include(diff: true)
    end

    # A chat that reviews a changeset, settles it and then surveys reuses the
    # review tabpage. The changeset's old side would otherwise be left showing
    # a diff of a file nobody is reviewing any more.
    #
    # ASSERTED AT THE `set_review` PAINT, BEFORE ANY `<CR>`, and that is the
    # example rather than a tightening of it. `open_changeset` takes the stale
    # window away too, by a different route entirely -- `drop_stale` wipes the
    # previous file's old-side BUFFER, and nvim closes the window displaying it
    # -- so an assertion taken after the open is satisfied with the shed deleted
    # outright, naming a mechanism it never exercised. The layout is the round's
    # shape from the first sidebar render, and this is where that is pinned.
    it "sheds the previous round's old side at the render that changes the round" do
      set_review(["[ ] docs/guide.txt"], 1, %w[old new])
      open_changeset("docs/guide.txt", ["the guide", "was second", "third line"])

      set_review(["[ ] docs/other.txt"], 2, ["new"])

      expect(slot_names).to eq(%w[sidebar new])
    end

    # And the open then lands in the layout it shed down to, which is the half
    # the example above deliberately does not reach.
    it "opens the survey's file into the two windows it shed down to" do
      set_review(["[ ] docs/guide.txt"], 1, %w[old new])
      open_changeset("docs/guide.txt", ["the guide", "was second", "third line"])

      surveyed("docs/other.txt")

      expect(slot_names).to eq(%w[sidebar new])
      expect(name_of(buf_in(slots["new"]))).to eq(File.join(project, "docs/other.txt"))
    end
  end
end

# A TRIPWIRE on this module's call sites, and it is worth being exact about what
# that is worth. [diffview#466] is `E5560 nvim_buf_is_valid must not be called in
# a lua loop callback`: an nvim API call reached from a libuv callback needs
# `vim.schedule`, and getting that wrong CRASHES the editor rather than failing a
# spec -- so the signal has to arrive at the EDIT, which a runtime spec cannot do.
#
# ⚠️ WHAT IT CATCHES: this module itself acquiring an asynchronous call site, in
# any of the spellings below. That is the change that would make every nvim call
# beneath it need `vim.schedule`, and it is the change a later card is actually
# likely to make (the note rail's drift detection reaching for `nvim_buf_attach`
# is the concrete one).
#
# ⚠️ WHAT IT CANNOT CATCH, stated so nobody reads it as a proof:
#
#   1. It scans the CALLEE, while #466's real shape is `open_changeset` being
#      CALLED FROM a libuv context. `open_changeset` is a public global and
#      the note, diagnostic and thread rails all call it; if one of them calls
#      it from a timer or an `on_lines`, nothing here fires. That obligation
#      belongs to the caller, and is why the module header states the constraint
#      in prose as well.
#   2. It does not follow callees. `named_buf` and `set_lines` live in
#      20_buffers.lua; if either gained a `vim.uv` call, this stays green.
#   3. It is textual, so it loses to aliasing (`local L = vim; L.uv.new_timer()`).
#      The `= vim` line below closes the obvious form and nothing closes the
#      clever ones.
#
# It runs without an editor (it passes under `LAIN_NVIM=0`) and costs ~5ms. It is
# a guard, not redundant coverage -- deleting it removes the only mechanical
# signal on a constraint whose violation is a crash.
RSpec.describe "the diff module's call sites" do
  # CODE, with the comment lines stripped: the module's own header explains why
  # it shells out to nothing, and a scan that reads its prose reports the
  # explanation as the violation.
  let(:code) do
    path = Lain::Frontend::Neovim::RuntimeLoader.new.module_paths.find { |name| name.end_with?("_diff.lua") }
    raise "no runtime diff module found -- the review diff module is gone" if path.nil?

    File.readlines(path).grep_v(/\A\s*--/).join
  end

  # Spelled as a table because the REASON is the useful half of a failure here: a
  # card that trips one of these needs to know it has just taken on the
  # `vim.schedule` obligation, not merely that a regex matched.
  let(:async_call_sites) do
    {
      /vim[.\[]\s*["']?(uv|loop)\b/ => "libuv directly -- every nvim call under a callback needs vim.schedule",
      /\brequire\s*\(\s*["']luv["']/ => "libuv under its other name",
      /vim\.fn[.\[]\s*["']?(jobstart|termopen|timer_start)\b/ => "a job or timer, whose callbacks are libuv callbacks",
      /vim[.\[]\s*["']?system\b/ => "an async subprocess; Ruby runs git and sends old_lines already read",
      /vim\.(defer_fn|schedule|schedule_wrap)\b/ => "deferral, which only exists to serve an async call site",
      /vim\.wait\b/ => "a yield to the event loop mid-render, which lets a callback run inside open_changeset",
      /nvim_buf_attach/ => "an on_lines callback -- the textlock family the note rail's drift detection will reach for",
      /vim\.ui\.\w+/ => "a callback the dressing plugins make asynchronous (65_review's :LainAnnotate note)",
      /=\s*vim\s*$/ => "an alias for `vim`, which defeats every pattern above"
    }
  end

  it "reaches for nothing that would run its nvim calls in a libuv callback" do
    tripped = async_call_sites.select { |pattern, _| code.match?(pattern) }.map { |_, why| why }

    expect(tripped).to be_empty
  end

  # Ruby runs git. An injected chunk shelling out would put half the review model
  # in the editor -- and the async spellings of it are the call sites above.
  it "runs no subprocess, because the old side arrives already read" do
    expect(code).not_to match(/vim\.fn[.\[]\s*["']?systemlist\b/)
    expect(code).not_to match(/\bio\.popen\b|\bos\.execute\b/)
  end
end
