# frozen_string_literal: true

require "fileutils"
require "neovim"
require "socket"
require "timeout"
require "tmpdir"

# T6: the injected runtime is one chunk assembled from many files, and this is
# the assembly's own spec. `neovim_runtime_spec.rb` pins what the runtime DOES
# and passed the split unmodified, which is that card's contract; what it cannot
# see is the loader -- a module silently dropped from the glob, or concatenated
# in the wrong order, presents there as a feature that stopped working rather
# than as a loader that is broken.
RSpec.describe Lain::Frontend::Neovim::RuntimeLoader do
  # A chunk head and modules under our own roof, so ordering and discovery are
  # asserted against files this example wrote rather than against the real
  # runtime, whose module list changes with every card that adds a capability.
  def loader_over(files, head: "-- head\n")
    dir = Dir.mktmpdir("lain-runtime-modules")
    head_path = File.join(dir, "head.lua")
    modules = File.join(dir, "modules")
    Dir.mkdir(modules)
    File.write(head_path, head)
    files.each { |name, body| File.write(File.join(modules, name), body) }
    yield described_class.new(head: head_path, modules:), modules
  ensure
    FileUtils.remove_entry(dir) if dir
  end

  describe "assembling the chunk" do
    # The card's reason for a glob: a hardcoded list would make this class a file
    # every later capability has to edit, which is what serializes work that has
    # no reason to be serial. Adding a module is adding a file.
    it "discovers a new module from the directory without being told about it" do
      loader_over({ "10_first.lua" => "local a = 1\n" }) do |loader, modules|
        expect(loader.source).not_to include("local b = 2")
        File.write(File.join(modules, "20_later.lua"), "local b = 2\n")
        expect(loader.source).to include("local b = 2")
      end
    end

    # The prefix IS the dependency order (modules share top-level locals, so a
    # module sees only what sorts above it), which makes readdir order a
    # correctness question rather than a cosmetic one.
    it "orders modules by prefix" do
      files = { "20_second.lua" => "-- second\n", "00_first.lua" => "-- first\n", "10_middle.lua" => "-- middle\n" }
      loader_over(files) do |loader|
        expect(loader.source.index("-- first")).to be < loader.source.index("-- middle")
        expect(loader.source.index("-- middle")).to be < loader.source.index("-- second")
      end
    end

    it "puts the chunk head before every module" do
      loader_over({ "00_only.lua" => "-- module\n" }, head: "-- the head\n") do |loader|
        expect(loader.source.index("-- the head")).to be < loader.source.index("-- module")
      end
    end

    # An empty directory injects a chunk that is nothing but the handshake, so
    # nvim attaches, answers a healthy protocol, and then does nothing at all --
    # a silent failure wearing the shape of a working editor. The message names
    # the directory because "the runtime did not load" sends a reader to the lua.
    it "refuses an empty module directory, naming it" do
      loader_over({}) do |loader|
        expect { loader.source }.to raise_error(/no lua modules in .*modules/)
      end
    end

    # This is the example that pins the WIRING, and it is the one the `#ordered`
    # group cannot replace. Testing `ordered` as a pure function proves the rule
    # exists; it says nothing about whether assembly still routes through it. A
    # card that replaces the body of `module_paths` with a bare `Dir.glob` -- the
    # simplification that reads as harmless, because glob sorts too -- passes every
    # `#ordered` example and every order assertion, since lexicographic and numeric
    # order agree for all VALID names. What it loses is the validation, and this is
    # where that loss becomes a failure.
    it "validates while assembling, not only when asked to order" do
      loader_over({ "20_buffers.lua" => "-- real\n", "100_foo.lua" => "-- misnamed\n" }) do |loader|
        expect { loader.source }.to raise_error(/"100_foo\.lua" is not named NN_name\.lua/)
      end
    end

    # Both of these used to surface as a raw Errno with no mention of the runtime:
    # ENOENT from the directory read, EISDIR from reading a directory whose name
    # ends in .lua. Same failure, said in the vocabulary of the thing that broke.
    it "refuses a missing module directory in its own words" do
      expect { described_class.new(head: __FILE__, modules: "/nonexistent/modules").source }
        .to raise_error(%r{runtime module directory is missing: /nonexistent/modules})
    end

    # emacs writes `.#20_buffers.lua` as a DANGLING symlink while a file is open,
    # so it answers neither File.file? nor File.directory?. Refusing it took lain
    # down for as long as a developer had a module open in another editor, and
    # named a directory while doing it.
    it "ignores an editor lock file rather than refusing to attach" do
      loader_over({ "20_buffers.lua" => "-- real\n" }) do |loader, modules|
        File.symlink("joel@host.12345:1", File.join(modules, ".#20_buffers.lua"))
        expect(loader.source).to include("-- real")
        expect(loader.module_paths.size).to eq(1)
      end
    end

    it "refuses a subdirectory wearing a module's name" do
      loader_over({ "20_buffers.lua" => "-- real\n" }) do |loader, modules|
        Dir.mkdir(File.join(modules, "50_sub.lua"))
        expect { loader.source }.to raise_error(/50_sub\.lua .* is a directory, not a runtime module/)
      end
    end
  end

  # Load order is a contract SIX later cards inherit (T14 sidebar, T15 diff, T16
  # annotate, T17 diagnostics, T18 thread, T26 layout), so it is asserted as a
  # pure function of the names. Stubbing a directory reader instead is what makes
  # the guard asymmetric: a card that swaps the reader out entirely leaves such an
  # example vacuously green, because the stub no longer applies to anything.
  # Nothing here touches the filesystem, so no reader swap can dodge it.
  describe "#ordered" do
    subject(:loader) { described_class.new }

    it "orders by the parsed prefix, from any starting order" do
      names = %w[99_attach.lua 00_constants.lua 45_views.lua 05_records.lua]
      expect(loader.ordered(names)).to eq(%w[00_constants.lua 05_records.lua 45_views.lua 99_attach.lua])
      expect(loader.ordered(names.reverse)).to eq(loader.ordered(names))
    end

    # The bug an Integer comparison retires: as STRINGS, "100_" sorts before
    # "20_", so a card taking "the next number after 99" would have loaded its
    # module before the buffer constructors -- ahead of everything it depends on.
    # Two digits is now the whole of the namespace, and 100 is simply not a name.
    it "refuses a three-digit prefix, which as a string would sort first" do
      expect { loader.ordered(%w[20_buffers.lua 100_foo.lua]) }
        .to raise_error(/"100_foo\.lua" is not named NN_name\.lua/)
    end

    # Letters sort after digits, so an unprefixed module loaded PAST
    # 99_attach.lua -- silently breaking the one rule the scheme states outright,
    # that the attach announcement is last.
    it "refuses a module with no prefix, which would sort past the attach announcement" do
      expect { loader.ordered(%w[20_buffers.lua sidebar.lua]) }
        .to raise_error(/"sidebar\.lua" is not named NN_name\.lua/)
    end

    it "refuses an uppercase name, which sorts before lowercase at the same prefix" do
      expect { loader.ordered(%w[40_Diff.lua]) }.to raise_error(/"40_Diff\.lua" is not named/)
    end

    # Two cards merging on the same number is the likeliest collision of the six,
    # and it resolved by filename with no signal at all.
    it "refuses two modules claiming one position, naming both" do
      expect { loader.ordered(%w[40_diff.lua 40_annotate.lua 20_buffers.lua]) }
        .to raise_error(/40 is claimed by 40_annotate\.lua and 40_diff\.lua/)
    end

    # 99 needs no rule of its own: two digits cannot exceed it, and the collision
    # refusal above is what makes it taken. This is that reasoning, asserted.
    it "leaves the attach announcement last, and refuses a second claim on 99" do
      expect(loader.ordered(%w[99_attach.lua 98_late.lua]).last).to eq("99_attach.lua")
      expect { loader.ordered(%w[99_attach.lua 99_sidebar.lua]) }
        .to raise_error(/99 is claimed by 99_attach\.lua and 99_sidebar\.lua/)
    end
  end

  # A broken module reports `[string "<nvim>"]:566` -- no filename, and since the
  # split that number no longer indexes runtime.lua either. Pre-split it did, so
  # this is a regression the concatenation introduced and this method repays.
  describe "#locate" do
    subject(:loader) { described_class.new }

    it "names the module a chunk line came from, and the line within it" do
      chunk = loader.source.lines
      target = chunk.index { |line| line.include?("function _G.__lain.open_review") } + 1
      name, line = loader.locate(target)

      expect(name).to eq("65_review.lua")
      expect(File.readlines(File.join(described_class::MODULES, name))[line - 1])
        .to include("function _G.__lain.open_review")
    end

    it "attributes the first line to the chunk head" do
      expect(loader.locate(1)).to eq(["runtime.lua", 1])
    end

    it "refuses a line past the end of the chunk" do
      expect { loader.locate(loader.source.lines.size + 1) }.to raise_error(/outside the injected chunk/)
    end

    # The blank `join("\n")` leaves between two modules is inside the chunk and
    # inside no module. Calling that "outside the injected chunk" contradicted the
    # line number in the same sentence.
    it "names a separator line as a separator, not as outside the chunk" do
      head_lines = File.readlines(described_class::HEAD).size
      expect { loader.locate(head_lines + 1) }
        .to raise_error(/is the blank separator before 00_constants\.lua/)
    end
  end

  describe "the runtime it assembles" do
    it "holds the real runtime's modules" do
      expect(described_class.new.module_paths).not_to be_empty
    end

    # Against the SHIPPED tree, which the `#ordered` examples cannot do: they pin
    # the rule using literal names, so they stay green if the real attach module
    # is RENAMED. `98_attach.lua` would free 99 for a later card, and the
    # announcement -- which must be the chunk's last act -- would stop being last
    # with nothing to catch it. The reservation lives here, in the spec, rather
    # than as a filename hardcoded inside the loader.
    it "ends with the attach announcement, which must be the chunk's last act" do
      expect(described_class.new.module_paths.last).to end_with("99_attach.lua")
    end

    # The head is the file that must not become a module: it captures the
    # injected varargs, which are legal only at the top of a main chunk.
    it "leads with the chunk head's injected-args line" do
      expect(described_class.new.source).to start_with("-- lain runtime")
      expect(described_class.new.source).to include("local gem_version, protocol, chan = ...")
    end
  end

  # The assembled chunk in a real editor. Every module the loader named has to be
  # PRESENT and has to have RUN -- a chunk that parses but whose later half never
  # executed would still satisfy every string assertion above.
  describe "injected into a real editor", :nvim do
    around do |example|
      socket = File.join(Dir.tmpdir, "lain-runtime-loader-spec-#{Process.pid}-#{rand(1_000_000)}.sock")
      pid = spawn("nvim", "--headless", "--clean", "-n", "--listen", socket, out: File::NULL, err: File::NULL)
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

    def inspector
      @inspector ||= Neovim.attach_unix(@socket)
    end

    def wait_until(timeout: 8)
      deadline = Time.now + timeout
      result = yield
      until result
        raise "timed out waiting for the injected runtime" if Time.now > deadline

        sleep 0.02
        result = yield
      end
      result
    end

    let(:frontend) { Lain::Frontend::Neovim.new(channel: Lain::Channel.new, socket_path: @socket) }

    # One export per module that publishes one, so a module dropped from the glob
    # fails HERE by name rather than as a mystery somewhere downstream.
    it "publishes every render entry point on _G.__lain" do
      frontend.run do
        exposed = wait_until do
          names = inspector.exec_lua("return vim.tbl_keys(_G.__lain or {})", [])
          names if names.any?
        end
        expect(exposed).to include("render", "set_view", "set_request", "set_compose",
                                   "set_question", "open_review", "review_refused")
      end
    end

    # The handshake reads off the HEAD, which is the one part of the chunk the
    # split moved bytes around. Against the constant, never a literal: a bump
    # (T28 has one planned) must not be able to leave this green by accident.
    it "hands the editor the protocol the gem holds" do
      frontend.run do
        wait_until { inspector.get_var("lain_rpc_version") == Lain::Frontend::Neovim::PROTOCOL }
        messages = inspector.exec_lua("return vim.api.nvim_exec2('messages', { output = true }).output", [])
        expect(messages).not_to include("mismatch")
      end
    end
  end
end
