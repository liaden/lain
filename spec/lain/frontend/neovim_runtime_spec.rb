# frozen_string_literal: true

require "fileutils"
require "neovim"
require "socket"
require "timeout"
require "tmpdir"

# The runtime.lua contract, protocol 3 (T5): User autocmds, b:lain_view on
# every lain:// buffer, the richer shared syntax, and lain://workspace's
# lua-side home. Same headless-nvim harness as neovim_spec.rb: a real editor
# on a unix socket, observed through a SECOND independent connection so every
# assertion is about what the editor actually did.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  around do |example|
    socket = File.join(Dir.tmpdir, "lain-nvim-runtime-spec-#{Process.pid}-#{rand(1_000_000)}.sock")
    pid = spawn("nvim", "--headless", "--clean", "--listen", socket, out: File::NULL, err: File::NULL)
    Timeout.timeout(10) { sleep 0.02 until File.exist?(socket) }
    @socket = socket
    example.run
  ensure
    @inspector = nil
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

  let(:channel) { Lain::Channel.new }

  # Every buffer the runtime owns -- the contract surface this file pins.
  def all_views
    %w[lain://journal lain://timeline lain://workspace lain://diff lain://inbox lain://request]
  end

  # The six documented lain* groups (T5's AC): tool attribution, digests,
  # roles, event kinds, ages, sender attribution.
  def syntax_groups
    %w[lainToolName lainDigest lainRole lainEventKind lainAge lainSender]
  end

  def inspector
    @inspector ||= Neovim.attach_unix(@socket)
  end

  def wait_until(timeout: 8)
    deadline = Time.now + timeout
    result = yield
    until result
      raise "timed out waiting for editor state" if Time.now > deadline

      sleep 0.02
      result = yield
    end
    result
  end

  def buffer_lines(name)
    inspector.exec_lua(<<~LUA, [name])
      local buf = vim.fn.bufnr(...)
      if buf == -1 then return {} end
      return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    LUA
  end

  # Record every User LainAttach / LainRender payload BEFORE the frontend
  # attaches, exactly as a human's config would from their own dotfiles.
  def install_recorder
    inspector.exec_lua(<<~LUA, [])
      _G.__seen = { LainAttach = {}, LainRender = {} }
      for pattern, log in pairs(_G.__seen) do
        vim.api.nvim_create_autocmd("User", {
          pattern = pattern,
          callback = function(ev) table.insert(log, ev.data) end,
        })
      end
      return true
    LUA
  end

  def seen
    inspector.exec_lua("return _G.__seen", [])
  end

  describe "user autocmds get a stable surface" do
    it "fires User LainAttach and User LainRender with buffer names in the payload" do
      install_recorder
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { seen["LainAttach"].any? && seen["LainRender"].any? }

        attach = seen["LainAttach"].first
        expect(attach["protocol"]).to eq(described_class::PROTOCOL)
        expect(attach["buffers"]).to match_array(all_views)

        # Priming posts every view at attach, so each named buffer announces
        # its own render, name in the payload.
        rendered = wait_until do
          names = seen["LainRender"].map { |data| data["name"] }
          names if (all_views - names).empty?
        end
        expect(rendered).to include(*all_views)
      end
    end

    it "sets b:lain_view on every lain:// buffer" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        views = wait_until do
          found = inspector.exec_lua(<<~LUA, [])
            local out = {}
            for _, buf in ipairs(vim.api.nvim_list_bufs()) do
              local name = vim.api.nvim_buf_get_name(buf)
              if name:match("^lain://") then out[name] = vim.b[buf].lain_view end
            end
            return out
          LUA
          found if found.size == all_views.size && found.values.none?(&:nil?)
        end

        expect(views.keys).to match_array(all_views)
        views.each { |name, view| expect(view).to eq(name) }
      end
    end

    # Panel probe G: the advertised dispatch pattern is
    #   autocmd FileType lain -> read vim.b.lain_view
    # and setting 'filetype' fires FileType SYNCHRONOUSLY, so the claim must
    # land BEFORE the filetype assignment in the buffer constructors -- a
    # claim after it leaves every FileType callback reading nil.
    it "sets b:lain_view before the FileType autocmd fires" do
      inspector.exec_lua(<<~LUA, [])
        _G.__ft_views = {}
        vim.api.nvim_create_autocmd("FileType", {
          pattern = "lain",
          callback = function(ev)
            table.insert(_G.__ft_views, vim.b[ev.buf].lain_view or "NIL-AT-FILETYPE-TIME")
          end,
        })
        return true
      LUA
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        # The four "lain"-filetype buffers: journal, timeline, workspace, inbox.
        views = wait_until do
          found = inspector.exec_lua("return _G.__ft_views", [])
          found if found.size >= 4
        end
        expect(views).to all(start_with("lain://"))
      end
    end
  end

  def group_links
    inspector.exec_lua(<<~LUA, [syntax_groups])
      local groups = ...
      local out = {}
      for _, group in ipairs(groups) do
        out[group] = vim.api.nvim_get_hl(0, { name = group }).link
      end
      return out
    LUA
  end

  describe "richer highlighting" do
    it "links all six documented lain* groups and defines their matches on lain buffers" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { buffer_lines("lain://timeline").any? }

        links = group_links
        syntax_groups.each { |group| expect(links.fetch(group)).to be_a(String), "#{group} is not linked" }

        # The matches attach to the "lain" filetype buffers (timeline here).
        defined = inspector.exec_lua(<<~LUA, [])
          local buf = vim.fn.bufnr("lain://timeline")
          return vim.api.nvim_buf_call(buf, function()
            return vim.fn.execute("syntax list")
          end)
        LUA
        syntax_groups.each { |group| expect(defined).to include(group) }
      end
    end

    # `highlight default link`'s observable contract (nvim_get_hl does not
    # surface the default flag): a link the human's config already made wins;
    # the runtime's defaults must never clobber it.
    it "yields to a user's pre-existing links for every group" do
      syntax_groups.each { |group| inspector.command("highlight link #{group} ErrorMsg") }
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { buffer_lines("lain://timeline").any? }
        group_links.each { |group, link| expect(link).to eq("ErrorMsg"), "#{group} was clobbered (links to #{link})" }
      end
    end
  end

  describe "workspace view has a lua-side home" do
    it "renders lain://workspace through set_view as a first-class lain buffer, not an orphan" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        # Session::Null has no reminders, so priming renders the empty state.
        # Before the fix, named_buf("lain://workspace") looked up a name the
        # runtime's tables never held: `vim.bo[buf].filetype = nil` silently
        # left the filetype "", so the buffer rendered but lived OUTSIDE the
        # lain contract -- no syntax, no view marker. That is the orphan.
        wait_until { buffer_lines("lain://workspace") == ["(no reminders)"] }

        state = inspector.exec_lua(<<~LUA, [])
          local buf = vim.fn.bufnr("lain://workspace")
          return {
            filetype = vim.bo[buf].filetype,
            buftype = vim.bo[buf].buftype,
            modifiable = vim.bo[buf].modifiable,
            lain_view = vim.b[buf].lain_view,
          }
        LUA

        expect(state["filetype"]).to eq("lain")
        expect(state["buftype"]).to eq("nofile")
        expect(state["modifiable"]).to be(false)
        expect(state["lain_view"]).to eq("lain://workspace")
      end
    end
  end

  describe "protocol lockstep" do
    it "bumps PROTOCOL to 3 and attaches without a mismatch warning" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { inspector.get_var("lain_rpc_version") == "3" }
        expect(described_class::PROTOCOL).to eq("3")
        messages = inspector.exec_lua("return vim.api.nvim_exec2('messages', { output = true }).output", [])
        expect(messages).not_to match(/mismatch/)
      end
    end
  end

  # Show a lain:// buffer in the (sole headless) window -- what a human's
  # :buffer lain://timeline does -- so the window-local fold surface applies.
  def display(name)
    inspector.exec_lua(<<~LUA, [name])
      local buf = vim.fn.bufnr(...)
      vim.api.nvim_win_set_buf(0, buf)
      return buf
    LUA
  end

  # foldclosed() per line in the displaying window: -1 for open, else the
  # closed fold's first line -- the observable the fold examples assert on.
  def fold_closes(count)
    inspector.exec_lua(<<~LUA, [count])
      local count, out = ..., {}
      for lnum = 1, count do out[lnum] = vim.fn.foldclosed(lnum) end
      return out
    LUA
  end

  def window_fold_options
    inspector.exec_lua("return { method = vim.wo.foldmethod, expr = vim.wo.foldexpr, text = vim.wo.foldtext }", [])
  end

  def render_timeline(lines)
    inspector.exec_lua("local lines = ...; _G.__lain.set_view('lain://timeline', lines); return true", [lines])
  end

  def fold_open_at(line)
    inspector.exec_lua(<<~LUA, [line])
      local line = ...
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      vim.cmd("silent! foldopen!")
      return true
    LUA
  end

  describe "folds" do
    let(:turns) { ["user: hi", "assistant: hello there", "user: and then?", "assistant: done"] }

    it "installs the foldexpr surface on record-shaped lain buffers" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { buffer_lines("lain://timeline").any? }
        display("lain://timeline")

        options = wait_until do
          opts = window_fold_options
          opts if opts["method"] == "expr"
        end
        expect(options["expr"]).to include("__lain.foldexpr")
        expect(options["text"]).to include("__lain.foldtext")
      end
    end

    # The amended contract: the older-closed/newest-open DEFAULT applies once,
    # at first display; a render may at most re-open the newest record. The
    # editor itself preserves per-fold open/closed state across a whole-buffer
    # replace (panel probe I), so preservation -- not re-defaulting -- is what
    # a render must exhibit.
    it "defaults once at display, then preserves fold state across re-renders" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { buffer_lines("lain://timeline").any? }
        render_timeline(turns)
        display("lain://timeline")
        wait_until { fold_closes(4) == [1, 2, 3, -1] }

        # A new turn arrives open; the closed older turns stay closed, the
        # previously-open turn stays open -- no forced re-close.
        render_timeline(turns + ["user: one more"])
        wait_until { fold_closes(5) == [1, 2, 3, -1, -1] }
        messages = inspector.exec_lua("return vim.api.nvim_exec2('messages', { output = true }).output", [])
        expect(messages).not_to match(/E\d+/)
      end
    end

    # Panel probe H: a turn the human opened by hand must survive the agent's
    # next render -- the stomp this fix round exists to kill.
    it "keeps a manually opened turn open across a re-render" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { buffer_lines("lain://timeline").any? }
        render_timeline(turns)
        display("lain://timeline")
        wait_until { fold_closes(4) == [1, 2, 3, -1] }

        fold_open_at(2)
        wait_until { fold_closes(4) == [1, -1, 3, -1] }

        render_timeline(turns + ["user: one more"])
        wait_until { fold_closes(5) == [1, -1, 3, -1, -1] }
      end
    end

    # Probe H's zR case: opening everything is a foldlevel statement, and a
    # render must not write foldlevel back down.
    it "lets zR stick across renders" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { buffer_lines("lain://timeline").any? }
        render_timeline(turns)
        display("lain://timeline")
        wait_until { fold_closes(4) == [1, 2, 3, -1] }

        inspector.exec_lua("vim.cmd('normal! zR'); return true", [])
        render_timeline(turns + ["user: one more"])
        wait_until { buffer_lines("lain://timeline").size == 5 }
        expect(inspector.exec_lua("return vim.wo.foldlevel", [])).to be >= 1
        expect(fold_closes(5)).to eq([-1, -1, -1, -1, -1])
      end
    end

    it "groups journal lines by attribution run and preserves runs across appends" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "t1", stream: :stdout, bytes: "a\nb"))
        channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "t2", stream: :stdout, bytes: "c\nd"))
        wait_until { buffer_lines("lain://journal").size == 4 }
        display("lain://journal")

        # One fold per [id stream] run: t1's two lines closed together, t2's open.
        wait_until { fold_closes(4) == [1, 1, -1, -1] }

        # An append never re-closes what the display state holds (probe H).
        channel.push(Lain::Telemetry::ToolOutput.new(tool_use_id: "t3", stream: :stdout, bytes: "e"))
        wait_until { buffer_lines("lain://journal").size == 5 && fold_closes(5) == [1, 1, -1, -1, -1] }
      end
    end

    # Panel probe J: window-local fold options are sticky per window -- when
    # the human navigates the window away to a normal buffer, lain's expr
    # surface must not ride along and flatten their own folds. The :vsplit is
    # the probe's sharpest case: a split copies window OPTIONS but NOT window
    # VARIABLES, so the new window carries lain's foldexpr with no saved
    # prior options -- an orphaned surface that must self-heal on leave.
    it "restores the window's prior fold options when it leaves the lain view, split windows included" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { buffer_lines("lain://timeline").any? }
        render_timeline(turns)
        display("lain://timeline")
        wait_until { window_fold_options["method"] == "expr" }

        options = inspector.exec_lua(<<~LUA, [])
          vim.cmd("vsplit")
          local buf = vim.api.nvim_create_buf(true, false)
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "def outer", "  a = 1", "end" })
          vim.api.nvim_win_set_buf(0, buf)
          return { method = vim.wo.foldmethod, expr = vim.wo.foldexpr }
        LUA

        expect(options["method"]).to eq("manual")
        expect(options["expr"]).not_to include("__lain")
      end
    end

    # Panel probe I: the kill switch must un-install LIVE -- flipping
    # vim.g.lain_fold mid-session restores the window and drops lain's folds
    # on the next fold event, not merely at the next fresh display.
    it "un-installs live when vim.g.lain_fold flips to false mid-session" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { buffer_lines("lain://timeline").any? }
        render_timeline(turns)
        display("lain://timeline")
        wait_until { fold_closes(4) == [1, 2, 3, -1] }

        inspector.exec_lua("vim.g.lain_fold = false; return true", [])
        render_timeline(turns + ["user: one more"])

        wait_until { window_fold_options["method"] == "manual" }
        expect(fold_closes(5)).to eq([-1, -1, -1, -1, -1])
      end
    end

    it "stays hands-off when vim.g.lain_fold is false" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { buffer_lines("lain://timeline").any? }
        inspector.exec_lua("vim.g.lain_fold = false; return true", [])
        display("lain://timeline")
        render_timeline(turns)

        wait_until { buffer_lines("lain://timeline") == turns }
        expect(window_fold_options["method"]).to eq("manual")
        expect(fold_closes(4)).to eq([-1, -1, -1, -1])
      end
    end
  end
end
