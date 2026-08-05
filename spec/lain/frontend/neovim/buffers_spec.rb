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
    pid = spawn("nvim", "--headless", "--clean", "-n", "--listen", socket, out: File::NULL, err: File::NULL)
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
  # `generation` is the OPTIONAL rendering stamp (T16), sent exactly as
  # {Lain::Frontend::Neovim::RenderQueue#post_view} sends it: present for the
  # one view whose gesture resolves through a rendering index (lain://inbox),
  # ABSENT -- not nil -- for every other, because a nil crosses msgpack as
  # `vim.NIL`, which is truthy in lua.
  def set_view(name, lines, generation = nil)
    inspector.exec_lua("local name, lines, gen = ...; _G.__lain.set_view(name, lines, gen)",
                       [name, lines, generation].compact)
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

    # T15/ruling 12 repointed this key: <CR> used to raise a one-line answer
    # prompt and invoke :LainReply with it, and a set of N questions has no
    # single-line answer. What survives is the PROPERTY the old example pinned
    # -- the key invokes a COMMAND a human could type by hand, never a private
    # helper -- so both are provably one path.
    it "invokes :LainOpen when <CR> is pressed on an inbox item, carrying that line and the rendering it is in" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do |handle|
        wait_until { bufnr("lain://inbox") != -1 }
        set_view("lain://inbox", ["researcher  12s  deploy now?", "orchestrator  3m  which db?"], 41)

        feed("lain://inbox", "<CR>", cursor: [2, 0])

        expect(Timeout.timeout(5) { handle.command_inbox.pop }).to eq(["open", [2, 41]])
      end
    end

    # T16: the stamp, not the line count. Two renderings are routinely the same
    # height -- the retire-then-arrive sequence produces exactly that -- so a
    # count cannot say which one the human is holding, and Ruby resolved the
    # gesture against the wrong one. What the editor sends back is what the
    # render that drew those lines stamped this buffer with.
    it "carries the stamp the rendering was posted with, not how many lines it holds" do
      frontend = described_class.new(channel:, socket_path: @socket)

      frontend.run do |handle|
        wait_until { bufnr("lain://inbox") != -1 }
        set_view("lain://inbox", ["researcher  12s  deploy now?", "orchestrator  3m  which db?"], 6)
        set_view("lain://inbox", ["planner  4s  ship it?", "orchestrator  3m  which db?"], 7)

        feed("lain://inbox", "<CR>", cursor: [1, 0])

        expect(Timeout.timeout(5) { handle.command_inbox.pop }).to eq(["open", [1, 7]])
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

    # SEQUENTIAL since T35, and it has to be: two lains attached to one editor
    # at once is refused by name now, so the only re-attach there is is the one
    # a human performs -- quit lain, start another in the same nvim. What it
    # pins is unchanged, because nothing is torn down when a lain exits: the
    # second arrives to buffers, commands and maps its predecessor left
    # standing, and the runtime's `define` deleting before it creates (with
    # every augroup `{ clear = true }`) is what keeps one of each.
    #
    # It was written as one attach NESTED inside another, which is the shape
    # ticket 31 measured as silent data destruction. The spec certified the
    # defect as a feature for as long as it stood.
    it "re-attach is idempotent: no duplicate commands, and motions/syntax still work" do
      described_class.new(channel: Lain::Channel.new, socket_path: @socket)
                     .run { wait_until { bufnr("lain://timeline") != -1 } }
      second = described_class.new(channel: Lain::Channel.new, socket_path: @socket)

      expect do
        second.run do
          wait_until { bufnr("lain://timeline") != -1 }
          commands = inspector.exec_lua("return vim.tbl_keys(vim.api.nvim_get_commands({}))", [])
          expect(commands.count("LainReply")).to eq(1)

          set_view("lain://timeline", ["user: a", "assistant: b"])
          expect(feed("lain://timeline", "]]", cursor: [1, 0])).to eq([2, 0])
          expect(syntax_name_at("lain://timeline", 1, 1)).to eq("lainRole")
        end
      end.not_to raise_error
    end
  end

  # T13: `x` in lain://question. Same harness and the same idiom as everything
  # above -- the document is injected straight through the runtime's own
  # `set_question` entry point, because the keymap is a fact about what
  # runtime.lua does with rendered lines, and the claim it has to earn is that
  # it does it from BUFFER TEXT ALONE. The arity rides in the heading
  # {Question::Document} writes ("## `id` (choose one)"), so a question's
  # boundary and how many ticks it may carry are both recoverable with no RPC;
  # spec/lain/question/document_spec.rb pins the same scan in ruby.
  #
  # Every expected document below is what the GRAMMAR would render for those
  # selections, never hand-written markdown -- so an example asserts the whole
  # buffer against bytes the parse would accept, not against a substitution.
  describe "`x` ticks an option in lain://question" do
    def option(id, label) = Lain::Question::Option.new(id:, label:)

    def question(id, body, options: [], arity: Lain::Question::SINGLE)
      Lain::Question.new(id:, body:, options:, arity:)
    end

    let(:storage) do
      question("storage", "Which storage engine?",
               options: [option("pg", "Postgres"), option("sqlite", "SQLite")])
    end
    let(:checks) do
      question("checks", "Which checks run?", arity: Lain::Question::MULTI,
                                              options: [option("lint", "RuboCop"), option("test", "RSpec")])
    end
    let(:notes) { question("notes", "Anything else?") }
    let(:asked) { Lain::Question::Set.new(questions: [storage, checks, notes]) }
    let(:digest) { "blake3:c0ffee" }
    let(:frontend) { described_class.new(channel:, socket_path: @socket) }

    def lines_of(markdown) = markdown.lines.map { |line| line.delete_suffix("\n") }

    def rendered(selected = {}, commented = {})
      answers = asked.questions.map do |asked_question|
        Lain::Question::Answer.new(question_id: asked_question.id, comment: commented[asked_question.id],
                                   option_ids: selected.fetch(asked_question.id, []))
      end
      lines_of(Lain::Question::Document.to_markdown(Lain::Question::AnswerSet.new(questions: asked, answers:)))
    end

    def row_of(lines, text) = lines.index(text) + 1

    # The document straight into the buffer, then zR. The at-rest fold state
    # (T12) leaves every question but the first CLOSED, and these examples are
    # about the keymap rather than the fold surface -- neovim_runtime_spec pins
    # that -- so opening them keeps a cursor seated inside a fold out of it.
    #
    # The priming wait is this file's own idiom and not decoration: {#run}
    # returns once the runtime is injected, but the drain thread is still
    # posting every projection's at-rest state, and those renders reach the
    # editor on the RPC thread while the inspector connection drives it from
    # here. Waiting for priming to land is what keeps a keymap example from
    # interleaving with one.
    def open_question(lines)
      wait_until { bufnr("lain://timeline") != -1 }
      inspector.exec_lua(<<~LUA, [lines, digest])
        local lines, digest = ...
        _G.__lain.set_question("lain://question", lines, digest)
        vim.cmd("normal! zR")
        return true
      LUA
    end

    def question_lines
      inspector.exec_lua('return vim.api.nvim_buf_get_lines(vim.fn.bufnr("lain://question"), 0, -1, false)', [])
    end

    def write_question
      inspector.exec_lua(<<~LUA, [])
        local ok, err = pcall(function()
          vim.api.nvim_buf_call(vim.fn.bufnr("lain://question"), function() vim.cmd("write") end)
        end)
        return { ok = ok, err = tostring(err) }
      LUA
    end

    it "ticks the option under the cursor, sending nothing" do
      frontend.run do |handle|
        document = rendered
        open_question(document)

        feed("lain://question", "x", cursor: [row_of(document, "- [ ] `pg` Postgres"), 0])

        expect(question_lines).to eq(rendered("storage" => %w[pg]))
        expect { handle.command_inbox.pop(true) }.to raise_error(ThreadError)
      end
    end

    it "clears a tick the cursor sits on" do
      frontend.run do
        document = rendered("storage" => %w[pg])
        open_question(document)

        feed("lain://question", "x", cursor: [row_of(document, "- [x] `pg` Postgres"), 0])

        expect(question_lines).to eq(rendered)
      end
    end

    it "keeps at most one tick on a single-select question, clearing the sibling" do
      frontend.run do
        document = rendered("storage" => %w[pg])
        open_question(document)

        feed("lain://question", "x", cursor: [row_of(document, "- [ ] `sqlite` SQLite"), 0])

        expect(question_lines).to eq(rendered("storage" => %w[sqlite]))
      end
    end

    it "accumulates ticks on a multi-select question" do
      frontend.run do
        document = rendered
        open_question(document)

        feed("lain://question", "x", cursor: [row_of(document, "- [ ] `lint` RuboCop"), 0])
        feed("lain://question", "x", cursor: [row_of(document, "- [ ] `test` RSpec"), 0])

        expect(question_lines).to eq(rendered("checks" => %w[lint test]))
      end
    end

    # Ruling 11: lain://question is `acwrite` and the human types PROSE into it,
    # so an unconditional map would break deleting a character while writing a
    # comment. The whole buffer still renders as a document the grammar accepts,
    # one character shorter.
    it "is vim's own `x` on the prose line a human is writing" do
      frontend.run do
        document = rendered({ "storage" => %w[sqlite] }, "storage" => "because it is embedded")
        open_question(document)

        feed("lain://question", "x", cursor: [row_of(document, "  because it is embedded"), 2])

        expect(question_lines).to eq(rendered({ "storage" => %w[sqlite] }, "storage" => "ecause it is embedded"))
      end
    end

    # `.` is the most reflexive key a vim user reaches for after "do a thing to
    # a line", and the tick is the one line this card made special. A bare
    # buffer write leaves NO redo entry, so `.` silently replayed the previous
    # real change -- the raw `x` from the line before -- and ate the option's
    # "- ". The panel's P1 sequence exactly, and the resulting document is still
    # one the grammar renders: a repeated toggle is an untick.
    it "repeats the tick with `.`, never a stale `x`, on the line the tick made special" do
      frontend.run do
        document = rendered
        open_question(document)

        feed("lain://question", "x", cursor: [row_of(document, "Which storage engine?"), 0])
        feed("lain://question", "x", cursor: [row_of(document, "- [ ] `pg` Postgres"), 0])
        feed("lain://question", ".")

        expect(question_lines).to eq(rendered.map do |line|
          line.sub("Which storage engine?", "hich storage engine?")
        end)
      end
    end

    # The other half of the same mechanism, and the reason it is worth having
    # rather than merely worth not breaking: `.` is how a human ticks the next
    # option without moving their hand.
    it "carries the tick to the next option with `.`" do
      frontend.run do
        document = rendered
        open_question(document)

        feed("lain://question", "x", cursor: [row_of(document, "- [ ] `lint` RuboCop"), 0])
        feed("lain://question", ".", cursor: [row_of(document, "- [ ] `test` RSpec"), 0])

        expect(question_lines).to eq(rendered("checks" => %w[lint test]))
      end
    end

    # A single-select tick is TWO nvim_buf_set_text calls (the new tick, the
    # sibling it clears) and must still be ONE change to undo: a human who
    # mis-clicks and presses `u` expects the document back, not half of it.
    it "undoes a single-select tick and the sibling it cleared in one `u`" do
      frontend.run do
        document = rendered("storage" => %w[pg])
        open_question(document)

        feed("lain://question", "x", cursor: [row_of(document, "- [ ] `sqlite` SQLite"), 0])
        expect(question_lines).to eq(rendered("storage" => %w[sqlite]))
        feed("lain://question", "u")

        expect(question_lines).to eq(document)
      end
    end

    # `.` replays `g@l` DIRECTLY -- the map does not run again -- so the operator
    # function is the only guard a repeat passes through, and what it repeats is
    # "tick this", not "delete a character". A repeat that fell through to vim's
    # `x` would make the most reflexive key in vim destructive on the prose the
    # human is in the middle of writing.
    it "repeats to nothing when `.` lands where there is nothing to tick" do
      frontend.run do
        document = rendered({ "storage" => %w[sqlite] }, "storage" => "because it is embedded")
        open_question(document)

        feed("lain://question", "x", cursor: [row_of(document, "- [ ] `pg` Postgres"), 0])
        feed("lain://question", ".", cursor: [row_of(document, "  because it is embedded"), 2])

        expect(question_lines).to eq(rendered({ "storage" => %w[pg] }, "storage" => "because it is embedded"))
      end
    end

    # v:count and v:register are PENDING when a mapping fires, and an expr map's
    # returned keys are executed with both still pending -- so `3x` and `"ax`
    # off an option line are vim's own, byte for byte, with nothing
    # reconstructed. These two pin that the fall-through really is `x` and not
    # an imitation of it.
    it "carries a count through to vim's `x`" do
      frontend.run do
        document = rendered({ "storage" => %w[sqlite] }, "storage" => "because it is embedded")
        open_question(document)

        feed("lain://question", "3x", cursor: [row_of(document, "  because it is embedded"), 2])

        expect(question_lines).to eq(rendered({ "storage" => %w[sqlite] }, "storage" => "ause it is embedded"))
      end
    end

    it "carries a register through to vim's `x`" do
      frontend.run do
        document = rendered
        open_question(document)

        feed("lain://question", '"ax', cursor: [row_of(document, "Which storage engine?"), 0])

        expect(inspector.exec_lua('return vim.fn.getreg("a")', [])).to eq("W")
        expect(question_lines).to eq(rendered.map do |line|
          line.sub("Which storage engine?", "hich storage engine?")
        end)
      end
    end

    # `[x]` and `[ ]` are the only marks Question::Document writes, and a mark
    # it does not write is not an option line here either -- so `x` deletes the
    # offending character, which is exactly the edit the grammar's own refusal
    # ("[?] is not a checkbox mark this grammar writes") asks the human for.
    # Toggling it instead would be this keymap normalizing text the grammar
    # refuses, and a nil mark reaching the buffer write is an error in their face.
    #
    # The cursor is at column 0 and NOT on the mark, deliberately: widening the
    # pattern to any mark deletes the mark itself (a nil replacement is an empty
    # one), which from column 3 is byte-identical to vim's `x` -- the mutation
    # survived this example until the cursor moved off it. Vim's `x` deletes the
    # character under the CURSOR, and that is what is asserted.
    it "is vim's own `x` on a checkbox the grammar would refuse" do
      frontend.run do
        mangled = rendered.map { |line| line.sub("- [ ] `pg`", "- [?] `pg`") }
        open_question(mangled)

        feed("lain://question", "x", cursor: [row_of(mangled, "- [?] `pg` Postgres"), 0])

        expect(question_lines).to eq(mangled.map { |line| line.sub("- [?] `pg`", " [?] `pg`") })
      end
    end

    it "leaves the map buffer-local, so `x` is untouched in every other buffer" do
      frontend.run do
        wait_until { bufnr("lain://timeline") != -1 }
        open_question(rendered)

        expect(buffer_local_map?("lain://question", "x")).to be(true)
        expect(buffer_local_map?("lain://timeline", "x")).to be(false)
      end
    end

    # A tick is a real edit, so the untouched-write refusal (T12) is done with
    # and a PLAIN `:w` submits -- which is the path a human actually takes.
    # The real QuestionView here rather than the injected document: the write's
    # verdict is Ruby's, and it is the half a bare set_question cannot exercise.
    it "leaves a plain `:w` submitting the answer the tick made" do
      one = Lain::Question::Set.new(questions: [storage])

      frontend.run do |handle|
        expect(frontend.question_view.open(one, digest)).to be_nil
        wait_until { bufnr("lain://question") != -1 }

        feed("lain://question", "x", cursor: [row_of(lines_of(Lain::Question::Document.unanswered(one)),
                                                     "- [ ] `pg` Postgres"), 0])
        expect(write_question).to include("ok" => true)

        verb, args = Timeout.timeout(5) { handle.command_inbox.pop }
        expect(verb).to eq("question_answered")
        expect(args.last.fetch("storage").option_ids).to eq(%w[pg])
      end
    end

    # The heading shape is implemented TWICE -- Question::Document::HEADING and
    # KIND_LABELS in ruby, `question_heading` and QUESTION_ARITIES in lua -- and
    # the arity WORDS were the half nothing held to the other. lua patterns have
    # no alternation, so the three labels have to be spelled out as a set; add a
    # fourth kind in ruby and that question goes invisible to the folds, to
    # ]]/[[ AND to `x` at once, with a green suite, because all three read that
    # one predicate. The motion is the cheapest observable of it: `]]` walks
    # heading to heading, so a heading lua does not recognize is one `]]` skips.
    describe "every kind the grammar can write" do
      def question_for(kind, index)
        return question("q#{index}", "Body #{index}") if kind == Lain::Question::Document::FREE_TEXT

        question("q#{index}", "Body #{index}", arity: kind, options: [option("o#{index}", "Option #{index}")])
      end

      let(:kinds) { Lain::Question::Document::KIND_LABELS.keys }
      let(:asked) do
        Lain::Question::Set.new(questions: kinds.each_with_index.map { |kind, index| question_for(kind, index) })
      end

      it "is a heading the runtime recognizes, so folds, motions and `x` see every question" do
        frontend.run do
          document = rendered
          open_question(document)
          headings = document.each_index.select { |index| document[index].start_with?("## `") }
                                        .map { |index| index + 1 }
          expect(headings.size).to eq(kinds.size)

          feed("lain://question", "", cursor: [1, 0])
          walked = Array.new(headings.size - 1) { feed("lain://question", "]]").first }

          expect([1, *walked]).to eq(headings)
        end
      end
    end

    # T5's caveat: a question BODY is rendered verbatim and may legally hold a
    # line matching OPTION -- a fenced diff showing `- [x] `no` No` is the
    # documented case, and here it is byte-identical to a real option line.
    # DECIDED: `x` falls through to vim's own there. The keymap takes only the
    # LAST run of option lines in a question (the renderer emits the options as
    # one unbroken run, always after a blank line, and the comment beneath them
    # is indented), so a body line is never in it. Ticking it would not corrupt
    # the document silently -- the next `:w` refuses it by name -- but it would
    # read as a broken keymap.
    describe "a question body that shows the grammar" do
      let(:fenced) do
        question("fenced", "Is this diff right?\n\n```\n- [x] `no` No\n```",
                 options: [option("yes", "Yes"), option("no", "No")])
      end
      let(:asked) { Lain::Question::Set.new(questions: [fenced]) }

      it "falls through to vim's `x` on an option-shaped line inside the body" do
        frontend.run do
          document = rendered
          open_question(document)
          body = row_of(document, "- [x] `no` No")

          feed("lain://question", "x", cursor: [body, 0])

          expect(question_lines).to eq(document.each_with_index.map do |line, index|
            index + 1 == body ? " [x] `no` No" : line
          end)
        end
      end
    end

    # The other half of the same caveat, and the one the last-run rule alone
    # cannot answer: this question has NO options, so its body's option-shaped
    # line IS the last run. The heading is what refuses it -- "write your answer
    # below" says there is nothing here to tick.
    describe "a free-text question whose body ends in an option-shaped line" do
      let(:asked) { Lain::Question::Set.new(questions: [question("notes", "Anything else?\n\n- [ ] `x` y")]) }

      it "falls through to vim's `x`, because the heading says the question offers no options" do
        frontend.run do
          document = rendered
          open_question(document)
          body = row_of(document, "- [ ] `x` y")

          feed("lain://question", "x", cursor: [body, 0])

          expect(question_lines).to eq(document.each_with_index.map do |line, index|
            index + 1 == body ? " [ ] `x` y" : line
          end)
        end
      end
    end
  end
end
