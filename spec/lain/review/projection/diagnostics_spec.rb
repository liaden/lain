# frozen_string_literal: true

require "fileutils"
require "neovim"
require "socket"
require "timeout"
require "tmpdir"

RSpec.describe Lain::Review::Projection::Diagnostics do
  # The narrowest duck the projection asks of an annotation: the extmark that
  # holds its position, the words, and what it claims to be. Deliberately NOT
  # `Review::AnnotationPlaced` -- that record carries a `line`, which is the one
  # fact this projection must never send (see the class doc).
  def annotation(mark:, text: "unvalidated write reaches the store", kind: "blocker")
    Data.define(:mark, :text, :kind).new(mark:, text:, kind:)
  end

  describe "the severity map" do
    it "maps every annotation kind and nothing else" do
      expect(described_class::SEVERITIES.keys).to eq(Lain::Review::ANNOTATION_KINDS)
    end

    it "maps blocker to ERROR, question to WARN and note to HINT" do
      expect(described_class::SEVERITIES.values_at("blocker", "question", "note")).to eq(%w[ERROR WARN HINT])
    end

    it "gives the panel's three ranks the same three tiers, in the same order" do
      expect(described_class::RANKS.values_at("BLOCKER", "SHOULD-FIX", "NIT")).to eq(%w[ERROR WARN HINT])
    end

    it "spells every severity the way nvim's own vim.diagnostic.severity table does" do
      expect(described_class::SEVERITIES.values.uniq.sort).to eq(%w[ERROR HINT WARN])
    end
  end

  describe "projecting annotations into entries" do
    it "carries the extmark id rather than a line, because only the editor knows the line" do
      entries = described_class.new.entries([annotation(mark: 7)])

      expect(entries.first).to include("mark" => 7)
      expect(entries.first.keys).not_to include("line", "lnum")
    end

    it "maps each annotation's kind onto its severity" do
      entries = described_class.new.entries(
        [annotation(mark: 1, kind: "blocker"), annotation(mark: 2, kind: "question"),
         annotation(mark: 3, kind: "note")]
      )

      expect(entries.map { |entry| entry["severity"] }).to eq(%w[ERROR WARN HINT])
    end

    it "carries the human's own words as the message" do
      entries = described_class.new.entries([annotation(mark: 1, text: "Report could take the digest")])

      expect(entries.first["message"]).to eq("Report could take the digest")
    end

    it "stamps every entry with the projection's source, so a finding is visibly not a human's note" do
      entries = described_class.new(source: "critique").entries([annotation(mark: 1)])

      expect(entries.first["source"]).to eq("critique")
    end

    it "keys every entry the way a lua table does, so nothing has to translate on the far side" do
      entries = described_class.new.entries([annotation(mark: 1)])

      expect(entries.first.keys).to match_array(%w[mark message severity source])
    end

    it "preserves the order it was given, which is the order the human placed them" do
      entries = described_class.new.entries([annotation(mark: 9), annotation(mark: 4), annotation(mark: 6)])

      expect(entries.map { |entry| entry["mark"] }).to eq([9, 4, 6])
    end

    it "answers an empty list for no annotations, which is what clears the namespace" do
      expect(described_class.new.entries([])).to eq([])
    end

    it "refuses a kind no vocabulary knows, naming it and the kinds that exist" do
      expect { described_class.new.entries([annotation(mark: 1, kind: "blocekr")]) }
        .to raise_error(described_class::UnknownKind, /blocekr.*blocker/m)
    end

    it "is deeply frozen, so an entry list cannot be edited after it is projected" do
      entries = described_class.new.entries([annotation(mark: 1)])

      expect(entries).to be_frozen
      expect(entries.first).to be_frozen
      expect(entries.first["message"]).to be_frozen
    end
  end

  describe "the argument list the editor is sent" do
    it "is buffer, namespace and entries, in the order the lua entry point takes them" do
      projection = described_class.new(namespace: "lain_review_findings")
      args = projection.arguments(12, [annotation(mark: 1)])

      expect(args).to eq([12, "lain_review_findings", projection.entries([annotation(mark: 1)])])
    end

    it "defaults to the annotation namespace, which is the one the human's own notes render in" do
      expect(described_class.new.arguments(12, [])[1]).to eq("lain_review_diagnostics")
    end
  end
end

# The editor half, driven against a REAL nvim, because every claim this card
# makes is a claim about what `vim.diagnostic` does -- and the one that decides
# the design (do diagnostics track edits?) can only be answered by asking one.
#
# Measured on nvim 0.12.4, and the answer is sharper than the spike's:
#
#     BEFORE  diag.get lnum=2   anchor extmark row=2   rendered rows=[2]
#     AFTER+2 diag.get lnum=2   anchor extmark row=4   rendered rows=[4]
#
# `vim.diagnostic.get` reports the SAME lnum forever, while the virtual text and
# sign the diagnostic layer drew MOVE -- they are extmarks, and nvim slides them
# like any other. So the screen looks correct after an edit while the record is
# stale, and everything that reads the record (`]d`, `setqflist`, every picker's
# diagnostics source, and anything Ruby asks back) gets the old line. That is
# worse than a visibly wrong answer, and it is why re-rendering from the anchor
# extmarks is the design rather than a tidiness.
#
# Its own harness rather than an append to `diff_mode_spec.rb` for that file's
# stated reason: what is under test is what the editor does, and a frontend in
# front of it would mean proving the frontend was not the thing that moved.
RSpec.describe "runtime/49_diagnostics.lua", :nvim, :seam do
  around do |example|
    socket = File.join(Dir.tmpdir, "lain-nvim-diag-spec-#{Process.pid}-#{rand(1_000_000)}.sock")
    # `-n` -- NO SWAP FILE -- and it is not tidiness. Every example here makes a
    # real (non-scratch) buffer, so nvim writes a swap file per example into its
    # GLOBAL swap directory, keyed by the cwd. That directory is shared by every
    # nvim on the machine, including the ones every sibling worktree's specs
    # spawn, and nvim only has so many extensions to fall back through: measured,
    # a mutation run left 588 files named `%home%joel%dev%lain-t17.sw*`/`.sa*` and
    # the NEXT run died with `E326: Too many swap files found` on
    # `nvim_buf_set_lines`. That failure is indistinguishable from a mutant being
    # killed -- every nvim example fails at once -- which is how a mutation matrix
    # comes back all-green-looking nonsense.
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

  # A review buffer as T15 leaves one: real lines, and STAMPED. The stamp is
  # what says this buffer is still under review; T15 withdraws it when the human
  # moves on, and this module has to honour that.
  def review_buffer(lines: (1..8).map { |i| "line #{i}" }, side: "new")
    lua(<<~LUA, [lines, side])
      local content, side = ...
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
      vim.b[buf].lain_review_side = side
      vim.b[buf].lain_review_revision = "head1ff"
      vim.b[buf].lain_review_path = "lib/widget.rb"
      return buf
    LUA
  end

  # An anchor extmark in the namespace the human's notes live in -- the position
  # this module reads and never writes.
  def anchor(buf, row)
    lua(<<~LUA, [buf, row])
      local b, row = ...
      return vim.api.nvim_buf_set_extmark(b, vim.api.nvim_create_namespace("lain_review_annotations"), row, 0, {})
    LUA
  end

  def entry(mark, kind = "blocker", text = "note #{mark}", source = "review")
    { "mark" => mark, "message" => text, "severity" => severity_for(kind), "source" => source }
  end

  def severity_for(kind) = Lain::Review::Projection::Diagnostics::SEVERITIES.fetch(kind)

  def place(buf, entries, namespace = "lain_review_diagnostics")
    lua("_G.__lain.set_review_diagnostics(...)", [buf, namespace, entries])
  end

  def refuse(buf, entries, namespace = "lain_review_diagnostics")
    lua(<<~LUA, [buf, namespace, entries])
      local ok, err = pcall(_G.__lain.set_review_diagnostics, ...)
      return { ok, tostring(err) }
    LUA
  end

  # Every diagnostic in a namespace, as `[lnum, severity, message, source]` --
  # 0-based lnum, exactly as nvim stores it.
  def diagnostics(buf, namespace = "lain_review_diagnostics")
    lua(<<~LUA, [buf, namespace])
      local b, name = ...
      local found = {}
      for _, d in ipairs(vim.diagnostic.get(b, { namespace = vim.api.nvim_create_namespace(name) })) do
        table.insert(found, { d.lnum, d.severity, d.message, d.source })
      end
      table.sort(found, function(x, y) return x[1] < y[1] end)
      return found
    LUA
  end

  def at_severity(buf, name)
    lua(<<~LUA, [buf, name])
      local b, sev = ...
      local found = {}
      local query = { namespace = vim.api.nvim_create_namespace("lain_review_diagnostics"),
                      severity = vim.diagnostic.severity[sev] }
      for _, d in ipairs(vim.diagnostic.get(b, query)) do table.insert(found, d.message) end
      table.sort(found)
      return found
    LUA
  end

  # The anchor marks, by id and row, read straight from the namespace this
  # module must leave alone.
  def anchors(buf)
    lua(<<~LUA, [buf])
      local b = ...
      local found = {}
      local ns = vim.api.nvim_create_namespace("lain_review_annotations")
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, {})) do
        table.insert(found, { m[1], m[2] })
      end
      return found
    LUA
  end

  def insert_lines(buf, row, lines)
    lua("local b, r, l = ... vim.api.nvim_buf_set_lines(b, r, r, false, l)", [buf, row, lines])
  end

  def refresh(buf) = lua("_G.__lain.refresh_review_diagnostics(...)", [buf])

  def severity_number(name) = lua("return vim.diagnostic.severity[...]", [name])

  describe "annotations render as diagnostics in their own namespace" do
    it "places one diagnostic per annotation, each at its anchor's row" do
      buf = review_buffer
      marks = [anchor(buf, 1), anchor(buf, 3), anchor(buf, 5)]
      place(buf, [entry(marks[0], "blocker"), entry(marks[1], "question"), entry(marks[2], "note")])

      expect(diagnostics(buf).map(&:first)).to eq([1, 3, 5])
    end

    it "gives each the severity its kind maps to" do
      buf = review_buffer
      marks = [anchor(buf, 1), anchor(buf, 3), anchor(buf, 5)]
      place(buf, [entry(marks[0], "blocker"), entry(marks[1], "question"), entry(marks[2], "note")])

      expect(diagnostics(buf).map { |d| d[1] })
        .to eq([severity_number("ERROR"), severity_number("WARN"), severity_number("HINT")])
    end

    it "carries the message and the source through unchanged" do
      buf = review_buffer
      place(buf, [entry(anchor(buf, 2), "blocker", "unvalidated write", "critique")])

      expect(diagnostics(buf).first[2..]).to eq(["unvalidated write", "critique"])
    end

    it "renders findings into whatever namespace it is given, leaving the annotations' alone" do
      buf = review_buffer
      place(buf, [entry(anchor(buf, 1), "blocker", "human")])
      place(buf, [entry(anchor(buf, 4), "note", "finding")], "lain_review_findings")

      expect(diagnostics(buf).map { |d| d[2] }).to eq(["human"])
      expect(diagnostics(buf, "lain_review_findings").map { |d| d[2] }).to eq(["finding"])
    end
  end

  describe "diagnostics coexist with the annotation extmarks" do
    it "leaves every anchor extmark in place, at its own row" do
      buf = review_buffer
      marks = [anchor(buf, 1), anchor(buf, 4)]
      place(buf, [entry(marks[0]), entry(marks[1])])

      expect(anchors(buf)).to eq([[marks[0], 1], [marks[1], 4]])
    end

    it "still leaves them when the diagnostics are cleared" do
      buf = review_buffer
      marks = [anchor(buf, 1), anchor(buf, 4)]
      place(buf, [entry(marks[0]), entry(marks[1])])
      place(buf, [])

      expect(diagnostics(buf)).to eq([])
      expect(anchors(buf)).to eq([[marks[0], 1], [marks[1], 4]])
    end
  end

  describe "re-rendering after an edit rather than trusting positions" do
    it "reports the anchor's NEW row once refreshed" do
      buf = review_buffer
      mark = anchor(buf, 2)
      place(buf, [entry(mark)])
      insert_lines(buf, 0, ["# frozen_string_literal: true", ""])
      refresh(buf)

      expect(diagnostics(buf).first.first).to eq(4)
    end

    # The measurement that makes the refresh worth its code: WITHOUT it the
    # record is stale, so this asserts the exact wrong answer the design exists
    # to prevent. If nvim ever starts tracking edits, this example fails and the
    # card's escalation trigger has fired.
    it "reports the OLD row until it is refreshed, because vim.diagnostic tracks no edits" do
      buf = review_buffer
      mark = anchor(buf, 2)
      place(buf, [entry(mark)])
      insert_lines(buf, 0, ["# frozen_string_literal: true", ""])

      expect(anchors(buf)).to eq([[mark, 4]])
      expect(diagnostics(buf).first.first).to eq(2)
    end

    # A REAL edit, typed, rather than `nvim_exec_autocmds` -- an API write does
    # not fire TextChanged, so a synthesized event would prove the callback is
    # wired and nothing about whether nvim ever calls it. `yyP` duplicates line
    # 1 above itself, which pushes every anchor down one.
    it "re-renders by itself when the human edits the buffer" do
      buf = review_buffer
      mark = anchor(buf, 2)
      place(buf, [entry(mark)])
      lua(<<~LUA, [buf])
        local b = ...
        vim.api.nvim_win_set_buf(0, b)
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.api.nvim_feedkeys("yyP", "x", false)
      LUA

      expect(anchors(buf)).to eq([[mark, 3]])
      expect(diagnostics(buf).first.first).to eq(3)
    end

    it "re-renders after an insert-mode edit, once the human leaves insert" do
      buf = review_buffer
      mark = anchor(buf, 2)
      place(buf, [entry(mark)])
      lua(<<~LUA, [buf])
        local b = ...
        vim.api.nvim_win_set_buf(0, b)
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.api.nvim_feedkeys("Otyped" .. vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
      LUA

      expect(diagnostics(buf).first.first).to eq(3)
    end

    it "keeps every remembered entry's message and severity across the refresh" do
      buf = review_buffer
      marks = [anchor(buf, 1), anchor(buf, 3)]
      place(buf, [entry(marks[0], "blocker", "first"), entry(marks[1], "note", "second")])
      insert_lines(buf, 0, ["inserted"])
      refresh(buf)

      expect(diagnostics(buf)).to eq([[2, severity_number("ERROR"), "first", "review"],
                                      [4, severity_number("HINT"), "second", "review"]])
    end

    it "refreshes every namespace it has rendered, not only the last one" do
      buf = review_buffer
      marks = [anchor(buf, 1), anchor(buf, 3)]
      place(buf, [entry(marks[0], "blocker", "human")])
      place(buf, [entry(marks[1], "note", "finding")], "lain_review_findings")
      insert_lines(buf, 0, ["inserted"])
      refresh(buf)

      expect(diagnostics(buf).first.first).to eq(2)
      expect(diagnostics(buf, "lain_review_findings").first.first).to eq(4)
    end
  end

  describe "severity filtering" do
    it "yields only the blockers when asked at ERROR" do
      buf = review_buffer
      place(buf, [entry(anchor(buf, 1), "blocker", "a blocker"), entry(anchor(buf, 3), "question", "a question"),
                  entry(anchor(buf, 5), "note", "a note")])

      expect(at_severity(buf, "ERROR")).to eq(["a blocker"])
    end

    it "yields only the notes when asked at HINT" do
      buf = review_buffer
      place(buf, [entry(anchor(buf, 1), "blocker", "a blocker"), entry(anchor(buf, 3), "question", "a question"),
                  entry(anchor(buf, 5), "note", "a note")])

      expect(at_severity(buf, "HINT")).to eq(["a note"])
    end
  end

  describe "refusals" do
    it "refuses an entry whose anchor extmark no longer resolves, naming the mark" do
      buf = review_buffer
      ok, err = refuse(buf, [entry(4242)])

      expect(ok).to be(false)
      expect(err).to include("4242")
    end

    it "refuses a severity nvim has no name for, naming it" do
      buf = review_buffer
      ok, err = refuse(buf, [{ "mark" => anchor(buf, 1), "message" => "m", "severity" => "URGENT",
                               "source" => "review" }])

      expect(ok).to be(false)
      expect(err).to include("URGENT")
    end

    # nvim refuses a dead buffer by itself, so `include("9999")` alone proves
    # nothing about this module -- measured, the unguarded message is
    # `scoped variable: Invalid buffer id: 9999`, which names a chunk line and
    # a vim.b lookup. What the guard adds is the ENTRY POINT, which is the
    # difference between "something in the runtime touched a dead buffer" and
    # "this call did", so that is what this asserts.
    it "refuses a buffer that is not a buffer, naming the call that asked" do
      ok, err = refuse(9999, [])

      expect(ok).to be(false)
      expect(err).to include("9999").and include("set_review_diagnostics")
    end
  end

  describe "honouring T15's stamp" do
    # T15 withdraws `b:lain_review_side` when the human moves on, and the new
    # side is a real file buffer that outlives the review. Diagnostics left on
    # it would be a review of a file nobody is reviewing.
    it "clears and forgets a buffer whose review stamp has been withdrawn" do
      buf = review_buffer
      place(buf, [entry(anchor(buf, 1))])
      lua("vim.b[...].lain_review_side = nil", [buf])
      refresh(buf)

      expect(diagnostics(buf)).to eq([])
    end

    it "stays forgotten, so a later edit does not resurrect it" do
      buf = review_buffer
      place(buf, [entry(anchor(buf, 1))])
      lua("vim.b[...].lain_review_side = nil", [buf])
      refresh(buf)
      lua("vim.b[...].lain_review_side = 'new'", [buf])
      refresh(buf)

      expect(diagnostics(buf)).to eq([])
    end
  end

  # The set/refresh asymmetry, applied to the MARK rather than to T15's stamp.
  # A `set` is Ruby naming a mark it believes in, so an unresolvable one is a
  # slip and is refused (see "refusals" above). A refresh is speculative, and
  # T16 owns annotation removal -- so a mark that has gone since the render is a
  # note somebody withdrew.
  #
  # Raising there is not merely strict, it is silently catastrophic: nvim
  # SWALLOWS an error thrown from an autocmd callback, so the buffer stays
  # tracked and the diagnostic sits at its stale row forever -- this card's own
  # failure mode, made permanent.
  describe "an anchor that has been removed since the render" do
    def clear_anchors(buf)
      lua("local b = ... vim.api.nvim_buf_clear_namespace(b, " \
          "vim.api.nvim_create_namespace('lain_review_annotations'), 0, -1)", [buf])
    end

    it "withdraws the note on refresh instead of raising" do
      buf = review_buffer
      place(buf, [entry(anchor(buf, 2))])
      clear_anchors(buf)
      ok, err = lua("local ok, e = pcall(_G.__lain.refresh_review_diagnostics, ...) return { ok, tostring(e) }", [buf])

      expect([ok, err]).to eq([true, "nil"])
      expect(diagnostics(buf)).to eq([])
    end

    it "stops tracking the buffer, so nothing is left to redraw" do
      buf = review_buffer
      place(buf, [entry(anchor(buf, 2))])
      clear_anchors(buf)
      refresh(buf)

      expect(lua("return _G.__lain.review_diagnostics_tracked()")).to eq([])
    end

    # The panel's own probe, as an example: a real typed edit is what fires the
    # autocmd, and it is where the swallowed error left a permanently stale row.
    it "leaves no stale diagnostic behind after a typed edit" do
      buf = review_buffer
      place(buf, [entry(anchor(buf, 2))])
      clear_anchors(buf)
      lua(<<~LUA, [buf])
        local b = ...
        vim.api.nvim_win_set_buf(0, b)
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.api.nvim_feedkeys("O" .. vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
      LUA

      expect(diagnostics(buf)).to eq([])
    end

    it "keeps the notes whose own anchors survive, at their new rows" do
      buf = review_buffer
      gone = anchor(buf, 1)
      kept = anchor(buf, 3)
      place(buf, [entry(gone, "blocker", "withdrawn"), entry(kept, "note", "still here")])
      lua("local b, m = ... vim.api.nvim_buf_del_extmark(b, " \
          "vim.api.nvim_create_namespace('lain_review_annotations'), m)", [buf, gone])
      insert_lines(buf, 0, ["inserted"])
      refresh(buf)

      expect(diagnostics(buf)).to eq([[4, severity_number("HINT"), "still here", "review"]])
    end

    it "still refuses the same mark on a set, because that is Ruby naming it" do
      buf = review_buffer
      mark = anchor(buf, 2)
      clear_anchors(buf)
      ok, err = refuse(buf, [entry(mark)])

      expect(ok).to be(false)
      expect(err).to include(mark.to_s)
    end
  end

  # `withdraw` resets only the namespaces this module rendered into. An LSP's
  # diagnostics on the same buffer are somebody else's.
  describe "other people's diagnostics" do
    def foreign(buf)
      lua(<<~LUA, [buf])
        local b = ...
        vim.diagnostic.set(vim.api.nvim_create_namespace("some_lsp"), b,
          { { lnum = 0, col = 0, message = "undefined method", severity = vim.diagnostic.severity.ERROR } })
      LUA
    end

    def foreign_count(buf)
      lua("local b = ... return #vim.diagnostic.get(b, " \
          "{ namespace = vim.api.nvim_create_namespace('some_lsp') })", [buf])
    end

    it "survives this module clearing its own namespace" do
      buf = review_buffer
      foreign(buf)
      place(buf, [entry(anchor(buf, 2))])
      place(buf, [])

      expect(foreign_count(buf)).to eq(1)
    end

    it "survives the review stamp being withdrawn" do
      buf = review_buffer
      foreign(buf)
      place(buf, [entry(anchor(buf, 2))])
      lua("vim.b[...].lain_review_side = nil", [buf])
      refresh(buf)

      expect(diagnostics(buf)).to eq([])
      expect(foreign_count(buf)).to eq(1)
    end
  end

  describe "the per-buffer registry" do
    # octo's own defect, named in T18's card: a registry keyed by bufnr that
    # nothing ever cleans grows for the life of the session.
    it "drops a buffer's entries when the buffer unloads" do
      buf = review_buffer
      place(buf, [entry(anchor(buf, 1))])
      lua("vim.api.nvim_buf_delete(..., { force = true })", [buf])

      expect(lua("return _G.__lain.review_diagnostics_tracked()")).to eq([])
    end

    it "tracks a buffer only while it holds entries" do
      buf = review_buffer
      place(buf, [entry(anchor(buf, 1))])
      tracked = lua("return _G.__lain.review_diagnostics_tracked()")
      place(buf, [])

      expect(tracked).to eq([buf])
      expect(lua("return _G.__lain.review_diagnostics_tracked()")).to eq([])
    end
  end
end
