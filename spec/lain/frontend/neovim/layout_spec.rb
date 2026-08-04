# frozen_string_literal: true

require "fileutils"
require "neovim"
require "socket"
require "timeout"
require "tmpdir"

# T26: `runtime/41_layout.lua` -- the review's own tabpage, the two entry points
# every later review capability renders through, and the repair that runs before
# each of those renders.
#
# Its OWN nvim harness rather than an append to `neovim_runtime_spec.rb`: this
# file drives the injected chunk DIRECTLY (no {Frontend::Neovim} lifecycle, no
# RPC thread, no render queue), because what is under test is what the editor
# does with windows and tabpages -- and a frontend in front of that would mean
# every assertion had to first prove the frontend was not the thing that moved.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  around do |example|
    socket = File.join(Dir.tmpdir, "lain-nvim-layout-spec-#{Process.pid}-#{rand(1_000_000)}.sock")
    pid = spawn("nvim", "--headless", "--clean", "-n", "--listen", socket, out: File::NULL, err: File::NULL)
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

  def layout = lua("return _G.__lain.review_layout()")

  def place(slot, buf) = lua("return _G.__lain.review_place(...)", [slot, buf])

  def tabpages = lua("return vim.api.nvim_list_tabpages()")

  def session_tab = tabpages.first

  def review_tab
    lua(<<~LUA)
      for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        if vim.t[tab].lain_review then return tab end
      end
      return nil
    LUA
  end

  def windows(tab) = lua("return vim.api.nvim_tabpage_list_wins(...)", [tab])

  # Window ids paired with what each one displays -- the two facts the "session
  # layout untouched" guarantee is actually made of, and the escalation trigger
  # names window ids specifically.
  def arrangement(tab)
    lua(<<~LUA, [tab])
      local state = {}
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(...)) do
        table.insert(state, { win, vim.api.nvim_win_get_buf(win) })
      end
      return state
    LUA
  end

  # An epic already in flight: two lain:// buffers side by side in the first
  # tabpage, the shape `plugin/nvim/lua/lain/init.lua`'s `open_layout` leaves.
  def open_session_layout
    lua(<<~LUA)
      for _, name in ipairs({ "lain://journal", "lain://timeline" }) do
        local buf = vim.api.nvim_create_buf(true, true)
        vim.api.nvim_buf_set_name(buf, name)
        if name ~= "lain://journal" then vim.cmd("botright vsplit") end
        vim.api.nvim_win_set_buf(0, buf)
      end
      return true
    LUA
  end

  def scratch(lines)
    lua(<<~LUA, [lines])
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, ...)
      return buf
    LUA
  end

  def buf_in(win) = lua("return vim.api.nvim_win_get_buf(...)", [win])

  def close(win) = lua("vim.api.nvim_win_close(..., true)", [win])

  def fold_state(win)
    lua("local w = ... return { vim.wo[w].foldmethod, vim.wo[w].foldlevel, vim.wo[w].diff }", [win])
  end

  def width_of(win)
    lua("local w = ... return { vim.api.nvim_win_get_width(w), vim.wo[w].winfixwidth }", [win])
  end

  def here = lua("return { vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win() }")

  def wipe(buf) = lua("vim.api.nvim_buf_delete(..., { force = true })", [buf])

  describe "opening the review" do
    it "puts the sidebar and the diff pair in a tabpage of their own, left to right" do
      open_session_layout

      panes = layout

      expect(panes.keys).to contain_exactly("sidebar", "old", "new")
      expect(tabpages.size).to eq(2)
      expect(windows(review_tab)).to eq([panes["sidebar"], panes["old"], panes["new"]])
    end

    # The whole contract T14, T15 and T18 render through, and the one an
    # implementation that ignored `slot` entirely would still satisfy every
    # OTHER example here: two empty placeholders diff against each other
    # perfectly well, and the sidebar is the window everything falls back to.
    it "lands a buffer in the slot it was given, not in whatever window it finds first" do
      panes = layout
      old_side = scratch(["was line 1"])
      new_side = scratch(["is line 1"])

      landed = { "old" => place("old", old_side), "new" => place("new", new_side) }

      expect(landed).to eq("old" => panes["old"], "new" => panes["new"])
      expect(buf_in(panes["old"])).to eq(old_side)
      expect(buf_in(panes["new"])).to eq(new_side)
      expect(buf_in(panes["sidebar"])).not_to eq(old_side)
    end

    # A navigator, not an equal third of the screen. 'winfixwidth' is the half
    # that has to hold afterwards: without it the diff pair's own splits
    # equalise the sidebar away again on the very next repair.
    it "sizes the sidebar as a navigator on the first open" do
      panes = layout

      expect(width_of(panes["sidebar"])).to eq([40, true])
    end

    # The other branch of the same sizing decision, and BLOCKER 2 was precisely
    # a sizing branch that never ran: a path that is never taken looks exactly
    # like a path that works until something asserts the width. A sidebar the
    # human CLOSED comes back as a new window, so it is sized like one -- unlike
    # the widened sidebar below, which was never re-created and keeps what the
    # human gave it.
    it "sizes a sidebar it had to rebuild, not only the one it opened first" do
      panes = layout
      close(panes["sidebar"])

      restored = layout["sidebar"]

      expect(width_of(restored)).to eq([40, true])
    end

    # 50 rather than something dramatic: the headless editor is 80 columns and
    # nvim clamps a sidebar that leaves the diff pair no room (70 comes back as
    # 57), which would read as this module re-imposing a width when it is the
    # editor doing arithmetic.
    it "keeps a sidebar the human widened, rather than re-imposing its own width on every render" do
      panes = layout
      lua("vim.api.nvim_win_set_width(..., 50)", [panes["sidebar"]])
      close(panes["new"])

      layout

      expect(width_of(panes["sidebar"]).first).to eq(50)
    end

    # The card's escalation trigger, as an assertion: if creating the tabpage
    # renumbered a window or moved a buffer, `Surfaces#post` would land in the
    # wrong window and the whole premise of this card is gone.
    it "leaves the session tabpage's windows and buffers exactly as they were" do
      open_session_layout
      before = arrangement(session_tab)

      layout

      expect(arrangement(session_tab)).to eq(before)
    end

    # Presented from the SESSION tab, which is the case that actually needs the
    # focus to move: the build path takes focus whether or not anyone asked
    # (nvim has no tabpage-without-entering API), so a spec that only ever
    # builds proves nothing about presenting a review that is already open.
    it "focuses the review, because a review is something the human was handed" do
      open_session_layout
      layout
      lua("vim.api.nvim_set_current_tabpage(...)", [session_tab])

      layout

      expect(lua("return vim.api.nvim_get_current_tabpage()")).to eq(review_tab)
    end

    it "reuses its tabpage rather than opening a second one" do
      first = layout
      tabs = tabpages.size

      expect(layout).to eq(first)
      expect(tabpages.size).to eq(tabs)
    end
  end

  describe "leaving and returning" do
    # [diffview#457] and [octo#854] are both editor state lost on tab switching,
    # so the tabpage's windows, buffers AND fold state have to survive `gt` away
    # and back -- diff folds included, since that is what a review is read in.
    it "preserves the same windows, buffers and folds" do
      open_session_layout
      panes = layout
      place("new", scratch((1..40).map { |i| "line #{i}" }))
      place("old", scratch((1..40).map { |i| i == 14 ? "was line 14" : "line #{i}" }))
      lua("for _, win in ipairs(...) do vim.api.nvim_win_call(win, function() vim.cmd('diffthis') end) end",
          [[panes["old"], panes["new"]]])
      before = arrangement(review_tab)
      folds = [fold_state(panes["old"]), fold_state(panes["new"])]
      # Without this the example is satisfiable by two windows in no fold mode
      # at all, which is what a `diffthis` that quietly refused would leave.
      expect(folds).to all(eq(["diff", 0, true]))

      lua("vim.api.nvim_set_current_tabpage(...)", [session_tab])
      lua("vim.api.nvim_set_current_tabpage(...)", [review_tab])

      expect(arrangement(review_tab)).to eq(before)
      expect([fold_state(panes["old"]), fold_state(panes["new"])]).to eq(folds)
    end
  end

  describe "a layout the human has clobbered" do
    it "restores the closed sidebar window and lands the render in it" do
      panes = layout
      close(panes["sidebar"])
      rendered = scratch(["a file", "another file"])

      landed = place("sidebar", rendered)

      expect(landed).not_to eq(panes["sidebar"])
      expect(buf_in(landed)).to eq(rendered)
      expect(windows(review_tab)).to eq([landed, panes["old"], panes["new"]])
    end

    it "repairs in the same tabpage, leaving the windows the human kept alone" do
      panes = layout
      tab = review_tab
      close(panes["old"])

      place("old", scratch(["old side"]))

      expect(review_tab).to eq(tab)
      expect(tabpages.size).to eq(2)
      expect(windows(tab).values_at(0, 2)).to eq([panes["sidebar"], panes["new"]])
    end

    # What "the same buffers are present" has to mean when the window holding one
    # is gone: the tabpage remembers what each slot held, so a repair with no
    # render behind it comes back showing the review rather than an empty pane.
    it "brings back the buffer the closed window held" do
      layout
      rendered = scratch(["the new side"])
      place("new", rendered)
      close(layout["new"])

      expect(buf_in(layout["new"])).to eq(rendered)
    end

    it "rebuilds the whole tabpage when the human closed that too" do
      panes = layout
      lua("vim.cmd('tabclose')")
      expect(review_tab).to be_nil

      rebuilt = layout

      expect(rebuilt.keys).to contain_exactly("sidebar", "old", "new")
      expect(rebuilt["sidebar"]).not_to eq(panes["sidebar"])
      expect(windows(review_tab)).to eq([rebuilt["sidebar"], rebuilt["old"], rebuilt["new"]])
    end

    # A window has to hold SOMETHING between being rebuilt and being rendered
    # into, and every repair makes another one. Wiping the placeholder as it is
    # replaced is what keeps a session's worth of repairs from leaving a
    # buffer list full of empty scratch buffers.
    it "wipes a placeholder the moment a real render replaces it" do
      panes = layout
      placeholder = buf_in(panes["new"])

      place("new", scratch(["the new side"]))

      expect(lua("return vim.api.nvim_buf_is_valid(...)", [placeholder])).to be(false)
    end

    # A remembered bufnr is a bufnr the review no longer controls: T15's diff
    # buffers are wiped and re-made per file, so restoring one blind hands
    # nvim_open_win an invalid buffer and the whole render raises. What a slot
    # remembers is a HINT, checked before it is believed.
    it "does not restore a remembered buffer that has since been wiped" do
      layout
      rendered = scratch(["the new side"])
      place("new", rendered)
      close(layout["new"])
      wipe(rendered)

      restored = layout["new"]

      expect(buf_in(restored)).not_to eq(rendered)
      expect(lua("return vim.api.nvim_buf_is_valid(...)", [buf_in(restored)])).to be(true)
    end
  end

  describe "a render arriving while the human is elsewhere" do
    it "lands in the review without taking the human off the tab they are on" do
      open_session_layout
      layout
      lua("vim.api.nvim_set_current_tabpage(...)", [session_tab])
      where = here

      place("sidebar", scratch(["a render"]))

      expect(here).to eq(where)
    end

    # The intact-layout path above proves nothing about the path that CREATES a
    # window: a repair that entered the window it opened would leave that example
    # green and still yank the human out of the session tab mid-keystroke.
    it "repairs a closed window without moving the human either" do
      open_session_layout
      panes = layout
      tab = review_tab
      close(panes["new"])
      lua("vim.api.nvim_set_current_tabpage(...)", [session_tab])
      where = here

      place("new", scratch(["restored"]))

      expect(here).to eq(where)
      # And not inside the review either. Restoring the TABPAGE hides a repair
      # that entered the window it created, so the human finds their cursor
      # moved the next time they `gt` back -- which is the same theft, deferred.
      expect(lua("return vim.api.nvim_tabpage_get_win(...)", [tab])).to eq(panes["sidebar"])
    end

    # Closing the review tabpage is the human's DISMISS gesture. Rebuilding it
    # for a render that arrives afterwards is right -- the review is still open,
    # and dropping the render would lose it -- but presenting is
    # `review_layout`'s job, so an async render must not drag them back out of
    # the session tab to watch it land.
    it "rebuilds a dismissed review without dragging the human back into it" do
      open_session_layout
      layout
      lua("vim.cmd('tabclose')")
      where = here
      rendered = scratch(["a late render"])

      landed = place("new", rendered)

      expect(buf_in(landed)).to eq(rendered)
      expect(here).to eq(where)
    end
  end

  describe "a slot the layout does not have" do
    # Loud failure, and it has to name the slot: a later capability rendering
    # into a misspelled slot would otherwise write nowhere and look like a view
    # that renders nothing.
    it "refuses by name rather than rendering nowhere" do
      buf = scratch(["x"])

      ok, message = lua("local ok, err = pcall(_G.__lain.review_place, ...); return { ok, err }", ["sidbar", buf])

      expect(ok).to be(false)
      expect(message).to include("sidbar").and include("sidebar, old, new")
    end
  end
end

# The two diff slots ARE {Lain::Review::SIDES}, restated in lua because a static
# chunk cannot derive anything from Ruby -- which is exactly the shape of the
# trap {Review::VOCABULARY} exists to prevent, one language further out. A
# vocabulary declared twice and never compared drifts the day someone renames a
# side: the Ruby guards keep refusing the new spelling while the editor keeps
# sending the old one, and both halves look right in isolation.
#
# {Review::Anchor::SIDES} derives its Symbol spelling and has a spec pinning the
# two equal. This is the same pin across the language boundary, and it needs no
# editor -- it reads the module -- so it stays out of the `:nvim` group above and
# runs even on a machine with no nvim.
RSpec.describe "the review layout's slot vocabulary" do
  # Found through the loader rather than by path, because the module's NUMBER is
  # this card's choice and a later renumber is legitimate. The vocabulary is not.
  let(:source) do
    path = Lain::Frontend::Neovim::RuntimeLoader.new.module_paths.find { |name| name.end_with?("_layout.lua") }
    raise "no runtime layout module found -- the slot vocabulary has nowhere to live" if path.nil?

    File.read(path)
  end

  let(:slots) { source[/SLOTS = \{(?<members>[^}]*)\}/, :members].scan(/"([a-z_]+)"/).flatten }

  it "spells its diff slots exactly as Review::SIDES does, in the same order" do
    expect(slots).to eq(["sidebar", *Lain::Review::SIDES])
  end

  # Slot order IS left-to-right window order, so this pins the sidebar's position
  # too: the leftmost slot is the navigator, and the diff pair reads old then new.
  it "puts the navigator first, so neither side of the diff can claim the sidebar's place" do
    expect(slots.first).to eq("sidebar")
    expect(Lain::Review::SIDES).not_to include("sidebar")
  end
end
