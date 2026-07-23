# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "neovim"
require "socket"
require "timeout"
require "tmpdir"

# T10: the in-repo nvim plugin (plugin/nvim) -- thin, public API only. It owns
# the CONVENTIONS around the editor frontend (the deterministic server socket,
# :LainStart's layout, socket_path()/status()) and none of the protocol: the
# lain:// buffers, the :Lain* agent commands, and all RPC stay injected by the
# gem's runtime.lua at attach, so a bare `nvim --listen` attaches identically
# with no plugin installed. Same headless-nvim harness as
# neovim_runtime_spec.rb: a real editor driven over a control socket.
RSpec.describe "lain nvim plugin", :nvim do
  around do |example|
    @project = Dir.mktmpdir("lain-plugin-project")
    @runtime_dir = Dir.mktmpdir("lain-plugin-runtime")
    @control = File.join(@runtime_dir, "control.sock")
    example.run
  ensure
    stop_nvim
    FileUtils.remove_entry(@project) if @project
    FileUtils.remove_entry(@runtime_dir) if @runtime_dir
  end

  def plugin_root
    File.expand_path("../../plugin/nvim", __dir__)
  end

  # --clean skips the human's config but still sources plugin/ files from any
  # rtp we add, which is exactly how an installed plugin loads.
  def boot_nvim(plugin: true, xdg: nil, extra_args: [])
    args = ["nvim", "--headless", "--clean"]
    args += ["--cmd", "set rtp+=#{plugin_root}"] if plugin
    args += extra_args
    args += ["--listen", @control]
    @pid = spawn({ "XDG_RUNTIME_DIR" => xdg || @runtime_dir }, *args, chdir: @project, out: File::NULL, err: File::NULL)
    Timeout.timeout(10) { sleep 0.02 until File.exist?(@control) }
  end

  def stop_nvim
    @inspector = nil
    return if @pid.nil?

    Process.kill("TERM", @pid)
    Process.wait(@pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  ensure
    @pid = nil
  end

  def inspector
    @inspector ||= Neovim.attach_unix(@control)
  end

  def lua(code, *args)
    inspector.exec_lua(code, args)
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

  # The editor's own cwd feeds the hash, so a symlinked tmpdir can never make
  # the expectation and the implementation disagree about the path.
  def nvim_cwd
    lua("return vim.fn.getcwd()")
  end

  def deterministic_socket
    File.join(@runtime_dir, "lain", "nvim-#{Digest::SHA256.hexdigest(nvim_cwd)[0, 12]}.sock")
  end

  def serverlist
    lua("return vim.fn.serverlist()")
  end

  def setup!(lua_opts = "{}")
    lua("require('lain').setup(#{lua_opts})")
  end

  def layout_views
    %w[lain://journal lain://timeline lain://inbox lain://request]
  end

  describe "setup() owns the conventions" do
    it "serves the deterministic runtime-dir socket from VimEnter" do
      boot_nvim(extra_args: ["--cmd", "lua require('lain').setup({})"])
      sock = deterministic_socket
      wait_until { File.exist?(sock) }
      expect(serverlist).to include(sock)
    end

    it "honors the project .lain/nvim.sock override" do
      Dir.mkdir(File.join(@project, ".lain"))
      boot_nvim
      setup!
      sock = File.join(nvim_cwd, ".lain", "nvim.sock")
      expect(File.exist?(sock)).to be(true)
      expect(serverlist).to include(sock)
    end

    it "reclaims a socket left behind by a dead instance" do
      boot_nvim
      sock = deterministic_socket
      FileUtils.mkdir_p(File.dirname(sock))
      UNIXServer.new(sock).close # bound then dead: the file stays, connects refuse
      setup!
      expect(serverlist).to include(sock)
      expect { UNIXSocket.new(sock).close }.not_to raise_error
    end

    it "respects a live instance that already owns the socket" do
      boot_nvim
      sock = deterministic_socket
      FileUtils.mkdir_p(File.dirname(sock))
      server = UNIXServer.new(sock)
      begin
        setup!
        expect(serverlist).not_to include(sock)
        expect(File.exist?(sock)).to be(true)
      ensure
        server.close
      end
    end

    it "lets setup opts override the socket, beating vim.g.lain_*" do
      boot_nvim
      g_sock = File.join(@runtime_dir, "from-g.sock")
      opt_sock = File.join(@runtime_dir, "from-opts.sock")
      lua("vim.g.lain_socket = ...", g_sock)
      expect(lua("return require('lain').socket_path()")).to eq(g_sock)
      setup!("{ socket = '#{opt_sock}' }")
      expect(lua("return require('lain').socket_path()")).to eq(opt_sock)
      expect(serverlist).to include(opt_sock)
    end

    # Panel fix 3 / probe b1: reclaim may only ever delete a SOCKET. A user's
    # regular file parked at the deterministic path survives; this instance
    # just serves no socket (serverstart fails inside its pcall).
    it "never deletes a regular file parked at the socket path" do
      boot_nvim
      sock = deterministic_socket
      FileUtils.mkdir_p(File.dirname(sock))
      File.write(sock, "precious user bytes")
      setup!
      expect(File.read(sock)).to eq("precious user bytes")
      expect(serverlist).not_to include(sock)
    end

    it "makes serverstart opt-out" do
      boot_nvim
      setup!("{ serverstart = false }")
      expect(serverlist).to eq([@control])
    end
  end

  describe "public API only, protocol stays injected" do
    it "socket_path() computes the path without serving or creating it" do
      boot_nvim
      sock = lua("return require('lain').socket_path()")
      expect(sock).to eq(deterministic_socket)
      expect(File.exist?(sock)).to be(false)
      expect(serverlist).to eq([@control])
    end

    # Panel fix 2 / probe a: the GLOBAL cwd feeds the hash -- :lcd in a window
    # must not fork the socket identity away from the one VimEnter served.
    it "socket_path() is unmoved by :lcd" do
      Dir.mkdir(File.join(@project, "sub"))
      boot_nvim
      before = lua("return require('lain').socket_path()")
      lua("vim.cmd('lcd sub')")
      expect(lua("return require('lain').socket_path()")).to eq(before)
    end

    # Panel fix 1: the XDG spec says a non-absolute XDG_RUNTIME_DIR is invalid
    # and must be ignored, so the path falls back to /tmp/lain.
    it "ignores a non-absolute XDG_RUNTIME_DIR" do
      boot_nvim(xdg: "not/absolute")
      sock = lua("return require('lain').socket_path()")
      expect(sock).to eq("/tmp/lain/nvim-#{Digest::SHA256.hexdigest(nvim_cwd)[0, 12]}.sock")
    end

    it "status() reads .lain/state.json, nil when absent" do
      boot_nvim
      expect(lua("return require('lain').status()")).to be_nil
      FileUtils.mkdir_p(File.join(@project, ".lain"))
      File.write(File.join(@project, ".lain", "state.json"),
                 JSON.generate({ "cache" => "warm", "inbox" => 2 }))
      expect(lua("return require('lain').status()")).to eq("cache" => "warm", "inbox" => 2)
    end

    it ":LainStart lays out windows over the runtime-injected buffers once attached" do
      boot_nvim
      setup!
      channel = Lain::Channel.new
      frontend = Lain::Frontend::Neovim.new(channel:, socket_path: deterministic_socket)
      frontend.run do
        wait_until do
          layout_views.none? { |name| lua("return vim.fn.bufnr(...)", name) == -1 }
        end
        inspector.command("LainStart")
        shown = lua(<<~LUA)
          local out = {}
          for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            table.insert(out, vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)))
          end
          return out
        LUA
        expect(shown).to match_array(layout_views)
      end
    end

    # The card's discipline clause, pinned mechanically the way
    # output_discipline_spec.rb pins stdout: the plugin may READ buffer names,
    # never create or write buffers, and never speak RPC -- that all belongs
    # to the injected runtime.
    it "ships no buffer logic and no RPC handling" do
      sources = Dir[File.join(plugin_root, "**", "*.lua")]
      expect(sources).not_to be_empty
      forbidden = %w[nvim_create_buf nvim_buf_set_lines rpcrequest rpcnotify __lain]
      sources.each do |path|
        content = File.read(path)
        forbidden.each do |token|
          expect(content).not_to include(token), "#{path} must not reference #{token}"
        end
      end
    end

    # T5's panel doc obligations: trust LainAttach data.protocol over
    # g:lain_rpc_version, name the priming burst, and table the User events
    # and lain* highlight groups (source of truth: runtime.lua's comments).
    it "documents the v3 contract in doc/lain.txt and generates helptags" do
      doc = File.read(File.join(plugin_root, "doc", "lain.txt"))
      expect(doc).to include("LainAttach").and include("LainRender")
      expect(doc).to include("data.protocol").and include("g:lain_rpc_version")
      expect(doc).to match(/prim/i)
      %w[lainToolName lainDigest lainRole lainEventKind lainAge lainSender].each do |group|
        expect(doc).to include(group)
      end

      Dir.mktmpdir("lain-helptags") do |dir|
        FileUtils.cp(File.join(plugin_root, "doc", "lain.txt"), dir)
        system("nvim", "--clean", "--headless", "-c", "helptags #{dir}", "-c", "qa!",
               out: File::NULL, err: File::NULL)
        expect(File.exist?(File.join(dir, "tags"))).to be(true)
      end
    end
  end

  describe "works without the plugin" do
    it "a bare nvim --listen attaches exactly as today" do
      boot_nvim(plugin: false)
      channel = Lain::Channel.new
      frontend = Lain::Frontend::Neovim.new(channel:, socket_path: @control)
      frontend.run do
        wait_until { lua("return vim.g.lain_rpc_version") == "3" }
        expect(lua("return vim.fn.exists(':LainSend')")).to eq(2)
        expect(lua("return vim.fn.exists(':LainStart')")).to eq(0)
      end
    end
  end
end
