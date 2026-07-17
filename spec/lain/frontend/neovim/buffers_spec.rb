# frozen_string_literal: true

require "fileutils"
require "neovim"
require "tmpdir"
require "timeout"

# I7: lain:// buffer ERGONOMICS -- filetypes, syntax, motions -- on the same
# real headless-nvim harness as neovim_spec/neovim_buffers_spec/inbox_view_spec
# (a SECOND, independent connection, {#inspector}, observes what the editor
# actually did). Content is injected straight through the runtime's own
# `_G.__lain.set_view`/`render` entry points rather than through full
# Telemetry events: this card is about what runtime.lua does with rendered
# lines once they land, not about {Buffers}/{InboxView}/{JournalView}'s own
# rendering logic, which the other specs already cover.
RSpec.describe Lain::Frontend::Neovim, :nvim do
  around do |example|
    socket = File.join(Dir.tmpdir, "lain-nvim-buffers-spec-#{Process.pid}-#{rand(1_000_000)}.sock")
    pid = spawn("nvim", "--headless", "--clean", "--listen", socket, out: File::NULL, err: File::NULL)
    Timeout.timeout(10) { sleep 0.02 until File.exist?(socket) }
    @socket = socket
    example.run
  ensure
    begin
      Process.kill("TERM", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    FileUtils.rm_f(socket)
  end

  let(:channel) { Lain::Channel.new }

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

  def bufnr(name) = inspector.exec_lua("return vim.fn.bufnr(...)", [name])

  def filetype_of(name)
    wait_until { bufnr(name) != -1 }
    inspector.exec_lua("return vim.bo[vim.fn.bufnr(...)].filetype", [name])
  end

  # The runtime's own whole-buffer-replace / append entry points, called
  # directly from the inspector connection -- `_G.__lain` is nvim-process-wide
  # Lua state, reachable from any RPC connection, not just the one that
  # injected it (the same fact {RpcThread}'s own render queue relies on).
  def set_view(name, lines)
    inspector.exec_lua("local name, lines = ...; _G.__lain.set_view(name, lines)", [name, lines])
  end

  def render(lines)
    inspector.exec_lua("_G.__lain.render(...)", [lines])
  end

  def syntax_name_at(bufname, line, col)
    inspector.exec_lua(<<~LUA, [bufname, line, col])
      local bufname, line, col = ...
      vim.cmd("buffer " .. bufname)
      return vim.fn.synIDattr(vim.fn.synID(line, col, 1), "name")
    LUA
  end

  # Switches to `bufname`, optionally seats the cursor, feeds `keys` through
  # nvim's own mapping resolution (feedkeys, NOT `:normal!`, which bypasses
  # mappings entirely -- this must exercise the actual buffer-local map), and
  # answers where the cursor landed. `cursor` rides as an empty array rather
  # than nil: msgpack round-trips a bare nil array element as `vim.NIL`
  # (TRUTHY in Lua), so `cursor[1]` -- nil on an empty table -- is the
  # reliable "no cursor given" test.
  def feed(bufname, keys, cursor: [])
    inspector.exec_lua(<<~LUA, [bufname, keys, cursor])
      local bufname, keys, cursor = ...
      vim.cmd("buffer " .. bufname)
      if cursor[1] then
        vim.api.nvim_win_set_cursor(0, cursor)
      end
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
      return vim.api.nvim_win_get_cursor(0)
    LUA
  end

  def buffer_local_map?(bufname, lhs)
    inspector.exec_lua(<<~LUA, [bufname, lhs])
      local bufname, lhs = ...
      vim.cmd("buffer " .. bufname)
      local m = vim.fn.maparg(lhs, "n", false, true)
      return m.buffer == 1
    LUA
  end

  describe "existing highlighting attaches by filetype" do
    it "gives lain://diff the built-in diff filetype -- whatever a human's config attaches there just works" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        expect(filetype_of("lain://diff")).to eq("diff")
      end
    end

    it "gives lain://request the built-in markdown filetype" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        expect(filetype_of("lain://request")).to eq("markdown")
      end
    end

    # The markdown filetype is not what keeps a format-on-save plugin off this
    # EDITABLE buffer's bytes -- buftype=nofile is: BufWritePre (what every
    # such plugin rides) never fires there, because nvim refuses :write on a
    # nofile buffer before any autocommand runs. Pinned directly so a future
    # buftype relaxation on lain://request reopens the hazard LOUDLY, as a
    # failing spec, rather than silently.
    it "keeps lain://request unwritable (buftype=nofile), so :write can never trigger a save-hooked formatter" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { bufnr("lain://request") != -1 }

        buftype = inspector.exec_lua("return vim.bo[vim.fn.bufnr(...)].buftype", ["lain://request"])
        wrote = inspector.exec_lua(<<~LUA, [])
          vim.cmd("buffer lain://request")
          return pcall(vim.cmd, "write")
        LUA

        expect(buftype).to eq("nofile")
        expect(wrote).to be(false)
      end
    end
  end

  describe "the bespoke buffers get a small namespaced syntax (no treesitter grammar shipped)" do
    it "highlights a turn's role in lain://timeline as lainRole" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { bufnr("lain://timeline") != -1 }
        set_view("lain://timeline", ["user: hi there", "assistant: (tool_use)"])

        expect(syntax_name_at("lain://timeline", 1, 1)).to eq("lainRole")
        expect(syntax_name_at("lain://timeline", 2, 1)).to eq("lainRole")
      end
    end

    it "highlights a digest and an event/stream kind in lain://journal" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { bufnr("lain://journal") != -1 }
        render(["committed blake3:abcdef123 turn", "[t1 stdout] hello"])

        digest_col = "committed blake3:abcdef123 turn".index("blake3") + 1
        kind_col = "[t1 stdout] hello".index("stdout") + 1
        expect(syntax_name_at("lain://journal", 1, digest_col)).to eq("lainDigest")
        expect(syntax_name_at("lain://journal", 2, kind_col)).to eq("lainEventKind")
      end
    end

    it "highlights an item's age in lain://inbox as lainAge" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { bufnr("lain://inbox") != -1 }
        set_view("lain://inbox", ["researcher  12s  deploy now?"])

        age_col = "researcher  12s  deploy now?".index("12s") + 1
        expect(syntax_name_at("lain://inbox", 1, age_col)).to eq("lainAge")
      end
    end
  end

  describe "motions navigate records" do
    it "]] / [[ step between turns in lain://timeline, buffer-locally" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { bufnr("lain://timeline") != -1 }
        set_view("lain://timeline", ["user: first", "assistant: second", "user: third"])

        expect(feed("lain://timeline", "]]", cursor: [1, 0])).to eq([2, 0])
        expect(feed("lain://timeline", "]]")).to eq([3, 0])
        expect(feed("lain://timeline", "]]")).to eq([3, 0]) # already the last record: no wraparound
        expect(feed("lain://timeline", "[[")).to eq([2, 0])
      end
    end

    it "]] / [[ step between items in lain://inbox, buffer-locally" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { bufnr("lain://inbox") != -1 }
        set_view("lain://inbox", ["researcher  12s  deploy now?", "orchestrator  3m  which db?"])

        expect(feed("lain://inbox", "]]", cursor: [1, 0])).to eq([2, 0])
        expect(feed("lain://inbox", "[[")).to eq([1, 0])
      end
    end

    it "does not treat the inbox's empty-state placeholder as a record" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { bufnr("lain://inbox") != -1 }
        set_view("lain://inbox", ["(no questions pending)"])

        expect(feed("lain://inbox", "]]", cursor: [1, 0])).to eq([1, 0])
      end
    end

    it "]] treats a wrapped multi-line tool-output run as ONE record in lain://journal" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { bufnr("lain://journal") != -1 }
        render(["[t2 stdout] line1", "[t2 stdout] line2", "[t3 stderr] oops"])
        lines = inspector.exec_lua(<<~LUA, [])
          return vim.api.nvim_buf_get_lines(vim.fn.bufnr("lain://journal"), 0, -1, false)
        LUA
        run_start = lines.index("[t2 stdout] line1") + 1

        landed = feed("lain://journal", "]]", cursor: [run_start, 0])

        expect(lines[landed.first - 1]).to eq("[t3 stderr] oops")
      end
    end

    it "invokes :LainReply when <CR> is pressed on an inbox item" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do |handle|
        wait_until { bufnr("lain://inbox") != -1 }
        set_view("lain://inbox", ["researcher  12s  deploy now?"])
        inspector.exec_lua('vim.ui.input = function(_, cb) cb("postgres") end', [])

        feed("lain://inbox", "<CR>", cursor: [1, 0])

        verb, args = Timeout.timeout(5) { handle.command_inbox.pop }
        expect(verb).to eq("reply")
        expect(args).to eq(["postgres"])
      end
    end
  end

  describe "user mappings are respected" do
    it "keeps the motions and the inbox reply keys buffer-local, never global" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { bufnr("lain://timeline") != -1 }
        set_view("lain://timeline", ["user: hi"])

        expect(buffer_local_map?("lain://timeline", "]]")).to be(true)
        expect(buffer_local_map?("lain://timeline", "[[")).to be(true)
        expect(buffer_local_map?("lain://inbox", "r")).to be(true)
        expect(buffer_local_map?("lain://inbox", "<CR>")).to be(true)
      end
    end

    it "namespaces every syntax group under lain*, so a human's own syntax plugins never collide" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do
        wait_until { bufnr("lain://timeline") != -1 }
        set_view("lain://timeline", ["user: hi"])

        groups = inspector.exec_lua(<<~LUA, [])
          vim.cmd("buffer lain://timeline")
          return vim.fn.execute("syntax list")
        LUA
        defined = groups.scan(/^(\w+)\s+xxx\s+match/).flatten
        expect(defined).to all(start_with("lain"))
        expect(defined).to include("lainRole", "lainDigest", "lainEventKind", "lainAge")
      end
    end

    it "re-attach is idempotent: no duplicate commands, and motions/syntax still work" do
      first = described_class.new(channel: Lain::Channel.new, socket_path: @socket)
      second = described_class.new(channel: Lain::Channel.new, socket_path: @socket)

      expect do
        first.run do
          second.run do
            wait_until { bufnr("lain://timeline") != -1 }
            commands = inspector.exec_lua("return vim.tbl_keys(vim.api.nvim_get_commands({}))", [])
            expect(commands.count("LainReply")).to eq(1)

            set_view("lain://timeline", ["user: a", "assistant: b"])
            expect(feed("lain://timeline", "]]", cursor: [1, 0])).to eq([2, 0])
            expect(syntax_name_at("lain://timeline", 1, 1)).to eq("lainRole")
          end
        end
      end.not_to raise_error
    end
  end
end
