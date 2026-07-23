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
end
