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
    @project = socket_tmpdir("lain-plugin-project")
    @runtime_dir = socket_tmpdir("lain-plugin-runtime")
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

  # "the help file names this command" -- word-boundaried, which is the whole of
  # it: without the boundary a LONGER command's name certifies a shorter one, and
  # `:LainNote` has been a prefix of `:LainNoteDone` since protocol 9. A method
  # rather than an inline regex so the example that pins the boundary constrains
  # the sweep itself rather than a second copy of the same expression.
  def documents?(doc, name) = doc.match?(/:#{name}\b/)

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

    # THE AUTOMATIC PATH, which the example above does not exercise: it waits
    # for every buffer and only then types :LainStart. The cockpit types
    # :LainStart at STARTUP, before any attach, so what has to work is the
    # one-shot -- and it did not. It armed on LainAttach, which the runtime
    # fires carrying buffer NAMES because "the buffers themselves are created
    # lazily by the first render". At that instant nothing has primed, every
    # column filters to empty, and the hook is spent warning "no lain:// buffers
    # to lay out yet". Measured in a live cockpit: augroup consumed, tabs=1,
    # wins=1, six buffers present and none displayed.
    it "lays out automatically when :LainStart precedes the attach, as the cockpit types it" do
      boot_nvim
      setup!
      inspector.command("LainStart") # armed BEFORE anything attaches

      channel = Lain::Channel.new
      frontend = Lain::Frontend::Neovim.new(channel:, socket_path: deterministic_socket)
      frontend.run do
        shown = wait_until do
          names = lua(<<~LUA)
            local out = {}
            for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
              table.insert(out, vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)))
            end
            return out
          LUA
          names if names.any? { |name| name.start_with?("lain://") }
        end

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
    it "documents the injected contract and generates helptags" do
      doc = File.read(File.join(plugin_root, "doc", "lain.txt"))
      expect(doc).to include("LainAttach").and include("LainRender")
      expect(doc).to include("data.protocol").and include("g:lain_rpc_version")
      expect(doc).to match(/prim/i)
      %w[lainToolName lainDigest lainRole lainEventKind lainAge lainSender].each do |group|
        expect(doc).to include(group)
      end

      # Read from the constant, never as a literal: this file's LAST example
      # already learned that a hardcoded token turns every bump into a false
      # green -- and this line then certified "protocol 5" through T12's bump to
      # "6", which is exactly the drift the assertion exists to catch.
      expect(doc).to include("LainReviewDone").and include("LainAnnotate")
      # `include` is case-sensitive and satisfied by ONE marker, so it pinned
      # line 14 and let the other three drift. Counting them instead pinned how
      # MANY sections the doc has, which is not a property of anything -- adding
      # the question section broke a green assertion about protocol numbers.
      # What holds is the shape: a PARENTHESIZED "(protocol n)" is this file's
      # current-contract stamp, every one of them states the same contract, and
      # that contract is the constant. Prose recording when a feature landed is
      # deliberately not this shape and is left alone.
      #
      # And the limit, stated so nobody reads more into it than it says: this
      # certifies UNIFORMITY and agreement with the constant, never PLACEMENT. A
      # stamp added to a section that never carried one passes, correctly -- the
      # stamp means "this section states the current contract", not "this feature
      # landed at n" -- and a stamp DELETED from one of several passes too. The two
      # structural ones are anchored by name below, which is where placement is
      # pinnable without pinning how many sections the doc has.
      stamps = doc.scan(/\(protocol (\d+)\)/i).flatten
      expect(stamps).not_to be_empty
      expect(stamps.uniq).to eq([Lain::Frontend::Neovim::PROTOCOL]),
                             "(protocol n) stamps disagree: found #{stamps.uniq.inspect}, expected " \
                             "every one to be #{Lain::Frontend::Neovim::PROTOCOL.inspect}"

      # The contract section's own heading and its TOC line: the two stamps that
      # are structure rather than decoration, so a sweep that DROPS one of them --
      # invisible to the uniformity check above, which sees only the survivors --
      # fails here by name.
      protocol = Lain::Frontend::Neovim::PROTOCOL
      expect(doc).to match(/^6\. THE ATTACH CONTRACT \(PROTOCOL #{protocol}\)/)
      expect(doc).to match(/^\s+6\. The attach contract \(protocol #{protocol}\)/)

      Dir.mktmpdir("lain-helptags") do |dir|
        FileUtils.cp(File.join(plugin_root, "doc", "lain.txt"), dir)
        system("nvim", "--clean", "--headless", "-c", "helptags #{dir}", "-c", "qa!",
               out: File::NULL, err: File::NULL)
        expect(File.exist?(File.join(dir, "tags"))).to be(true)
      end
    end

    # T35. A refused attach is the one contract change a human meets as a
    # REFUSAL rather than as a capability, so the doc owes them the whole of it:
    # what happened, that the editor is untouched, what to do instead, and --
    # the part a "just say it refuses" paragraph drops -- that a lain which
    # crashed does NOT wedge their editor. That last sentence is the difference
    # between the guard as built and the guard that detects presence, which is
    # exactly the confusion a human hits at the worst moment.
    it "documents one lain per editor, its marker, and the crashed case" do
      doc = File.read(File.join(plugin_root, "doc", "lain.txt"))
      expect(doc).to include("*lain-ownership*").and include("*__lain.channel*")
      expect(doc).to match(/refused/i).and match(/crashed/i).and match(/live/i)
    end

    # The command list is READ OFF the runtime rather than written down here,
    # because a written-down list is what drifted: :LainPin shipped undocumented
    # and stayed that way through two doc passes. The runtime's `define` is the
    # one place a runtime command comes into existence, so scanning it makes
    # "documented" a property of the runtime rather than of somebody's memory --
    # a new command now fails this example BY NAME until doc/lain.txt names it.
    #
    # Read through {RuntimeLoader} rather than off runtime.lua, which is now only
    # the chunk's HEAD: T6 moved every `define` site into runtime/*.lua, so a
    # single-file read scanned the one file that defines no commands and answered
    # a confident []. The loader is what nvim is actually sent, which makes this
    # the one scan that cannot go stale as modules are added -- and adding them is
    # the plan for the next six cards.
    #
    # Only the runtime's own commands are checked. :LainStart is the plugin's
    # and is documented in |lain-api|, which is the section this doc owns
    # outright; the contract section documents what the gem injects.
    it "documents every command the runtime defines" do
      runtime = Lain::Frontend::Neovim::RuntimeLoader.new.source
      commands = runtime.scan(/define\("(\w+)"/).flatten
      expect(commands).to include("LainPin", "LainOpen", "LainSend")

      doc = File.read(File.join(plugin_root, "doc", "lain.txt"))
      expect(commands.reject { |name| documents?(doc, name) }).to be_empty
    end

    # The predicate above, stated on two sentences instead of on the shipped help
    # file, because nothing in the suite established that its word boundary is the
    # guard rather than decoration -- the panel replaced it with a bare `include?`
    # and every example stayed green. It is the same method the sweep calls, so this
    # constrains the sweep and not a copy of it, and it needs no editor.
    #
    # A bare include? lets a LONGER command certify a shorter one, which stopped
    # being hypothetical at protocol 9: `:LainNote` IS a prefix of `:LainNoteDone`,
    # so the boundary is the only thing between an undocumented `:LainNote` and a
    # green run. (nvim itself is not confused -- `exists(':LainNote')` answers 2, an
    # exact full match, because an exact name beats an abbreviation.)
    it "refuses to let a longer command's name certify a shorter one" do
      expect(documents?("Inside a review: `:LainNoteDone`.", "LainNote")).to be(false)
      expect(documents?("Inside a review: `:LainNote`, `:LainNoteDone`.", "LainNote")).to be(true)
    end

    # The same sweep from the other side, and only this direction catches the defect
    # T28 was handed: the plan for this chunk assumed a `:LainDiffOpen`, and nothing
    # ever defined one. A doc naming a command that does not exist passes `helptags`,
    # passes the sweep above (which only walks runtime -> doc), and answers E492 to
    # the first human who types it. `:LainStart` is the exception BY SOURCE, not by
    # name: the plugin defines it, so it is read off plugin/nvim the same way the
    # runtime's are read off the loader, and neither list is written down here.
    #
    # Scanned WITHOUT requiring the colon, because requiring it was a hole the panel
    # walked through: `Use LainDiffOpen to open the pair.` named a command nothing
    # defines and passed. The Lain-named things that are legitimately not commands
    # are the two User autocmd patterns, subtracted by reading the runtime's own
    # `pattern = "Lain..."` sites -- the same by-source rule :LainStart follows.
    it "names no command that neither the runtime nor the plugin defines" do
      runtime = Lain::Frontend::Neovim::RuntimeLoader.new.source
      plugin = Dir[File.join(plugin_root, "**", "*.lua")].map { |path| File.read(path) }.join
      defined_commands = runtime.scan(/define\("(\w+)"/).flatten |
                         plugin.scan(/nvim_create_user_command\("(\w+)"/).flatten
      expect(defined_commands).to include("LainStart")

      doc = File.read(File.join(plugin_root, "doc", "lain.txt"))
      events = runtime.scan(/pattern = "(Lain\w+)"/).flatten
      documented = doc.scan(/\bLain[A-Z]\w+\b/).uniq - events
      expect(documented).not_to be_empty
      undefined = documented - defined_commands
      expect(undefined).to be_empty, "doc/lain.txt names commands nothing defines: #{undefined.inspect}"
    end

    # T28's first documentation correction, and the half nothing read: deleting the
    # whole `Since protocol 9, b:lain_view no longer always names a VIEW` paragraph
    # left the suite green at 0 failures. The history entry's copy is doubly pinned;
    # the help file's -- the one a human writing a config actually reads, which is
    # the group that was being misled -- was pinned nowhere.
    #
    # Scoped to the SECTION that documents b:lain_view, because both strings appear
    # again in |lain-review-diff| and a whole-file `include?` would pass with 6.2
    # still saying the set is closed. The old side's prefix is read off the runtime
    # that writes it, never written down here: it is one constant in one module, and
    # a second spelling of it in a spec is the drift this file keeps closing.
    it "warns, where it documents b:lain_view, that the name is no longer a closed set" do
      runtime = Lain::Frontend::Neovim::RuntimeLoader.new.source
      old_prefix = runtime[/OLD_PREFIX = "([^"]+)"/, 1]
      expect(old_prefix).not_to be_nil

      doc = File.read(File.join(plugin_root, "doc", "lain.txt"))
      buffers = doc.split(/^-{78}$/).find { |section| section.include?("*lain-buffers*") }
      expect(buffers).not_to be_nil, "doc/lain.txt has no *lain-buffers* section"
      expect(buffers).to include(old_prefix).and include("b:lain_review_side")
    end

    # `helptags` builds an index of the tags a file DEFINES and never looks at
    # the ones it REFERENCES, so a |lain-review| pointing at a section that was
    # never written generates tags happily and answers E149 the moment a human
    # follows it. The TOC did exactly that. Only lain's own tags are checked --
    # references to vim's help (|User|, |E89|, |za|) resolve against runtime
    # files this spec has no business indexing.
    it "resolves every lain tag it points at" do
      doc = File.read(File.join(plugin_root, "doc", "lain.txt"))
      defined_tags = doc.scan(/\*(lain[^\s*]*|:Lain\w+|b:lain\w+|User-Lain\w+)\*/).flatten
      referenced = doc.scan(/\|(lain-[^|\s]+)\|/).flatten.uniq

      expect(referenced).not_to be_empty
      expect(referenced - defined_tags).to be_empty
    end

    # The same rule as above, from the OTHER side, and nothing else can see it.
    # `helptags` indexes the tags a doc DEFINES and never the ones it
    # REFERENCES; the sweep above closes that by scanning the DOC for |tag|. A
    # `:h <tag>` held in Ruby or Lua source is structurally outside its reach --
    # and lain's source does hold them, because a rendered buffer can be too
    # narrow to carry its own caveats and has to point at help instead
    # (`ReviewView::WALK_LEGEND`, 38 columns of a 40-column sidebar). Written
    # against a tag that was never defined, such a pointer generates tags
    # happily, passes every example here, and answers E149 to the first human
    # who follows it. That is exactly what happened while T14 was in review.
    it "resolves every :h tag the gem's own source points at" do
      doc = File.read(File.join(plugin_root, "doc", "lain.txt"))
      defined_tags = doc.scan(/\*(lain[^\s*]*|:Lain\w+|b:lain\w+|User-Lain\w+)\*/).flatten

      sources = Dir[File.expand_path("../../lib/**/*.{rb,lua}", __dir__)]
      referenced = sources.flat_map { |path| File.read(path).scan(/:h ([^\s"'`]+)/) }.flatten.uniq

      expect(referenced).not_to be_empty
      expect(referenced - defined_tags).to be_empty
    end
  end

  describe "works without the plugin" do
    it "a bare nvim --listen attaches exactly as today" do
      boot_nvim(plugin: false)
      channel = Lain::Channel.new
      frontend = Lain::Frontend::Neovim.new(channel:, socket_path: @control)
      frontend.run do
        # The CONSTANT, not a literal: this example is about a bare nvim
        # attaching at all, and a hardcoded token turns every protocol bump
        # into a false failure here (T15's did).
        wait_until { lua("return vim.g.lain_rpc_version") == Lain::Frontend::Neovim::PROTOCOL }
        expect(lua("return vim.fn.exists(':LainSend')")).to eq(2)
        expect(lua("return vim.fn.exists(':LainStart')")).to eq(0)
      end
    end
  end
end
