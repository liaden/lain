# frozen_string_literal: true

require "fileutils"
require "neovim"
require "socket"
require "timeout"
require "tmpdir"

# T16: `runtime/48_annotate.lua` -- placing a note on the diff T15 draws, and
# settling every note the human left. Its own nvim harness rather than an append
# to `diff_mode_spec.rb`, for that file's own stated reason: what is under test
# is what the editor does with marks, and it is also the file this chunk most
# needs to stay fast.
#
# ⚠️ THE FIXTURE IS `.txt` ON PURPOSE. `diff_mode_spec.rb` measured that the
# first `bufload` of a `.rb` file costs 213ms in a fresh editor (nvim loads its
# ruby ftplugin, indent and syntax runtime once per process) against 4.6ms for a
# `.txt`. Nothing here is about filetype, so nothing here pays for one.
#
# THE PAYLOAD IS FED THROUGH {Lain::Review::Annotations} rather than only
# asserted as a Hash. The card's ACs are claims about the RECORD -- "the recorded
# anchor names side new, that file line, and the head revision" -- and a spec
# that stopped at the wire would assert the two halves against two hand-written
# fixtures that are free to disagree. Driving the real module over the real wire
# bytes is what makes them meet.
module AnnotateFixture
  FILES = {
    "docs/guide.txt" => (1..40).map { |i| "line #{i}" },
    "docs/other.txt" => ["another document", "second line"]
  }.freeze

  # Byte-exact, because the line endings ARE the fixture: git hands the old side
  # carriage returns and nvim strips them from a 'fileformat=dos' buffer, which
  # is the whole reason drift has to be measured against the buffer.
  RAW = { "docs/crlf.txt" => (1..5).map { |i| "line #{i}\r\n" }.join }.freeze

  PROJECT = Dir.mktmpdir("lain-annotate-spec")

  FILES.each do |path, lines|
    FileUtils.mkdir_p(File.join(PROJECT, File.dirname(path)))
    File.write(File.join(PROJECT, path), "#{lines.join("\n")}\n")
  end

  RAW.each do |path, bytes|
    FileUtils.mkdir_p(File.join(PROJECT, File.dirname(path)))
    File.binwrite(File.join(PROJECT, path), bytes)
  end

  # `:LainNoteDone` with `vim.rpcrequest` swapped for a capture, the idiom
  # `review_view_spec.rb` established: the spec's own channel has no
  # `lain_command` handler, so a real request would block the editor.
  #
  # The argument makes the capture RAISE, which is how the "a refused settle
  # keeps the notes" example reaches the one branch that matters.
  CAPTURE = <<~LUA
    local refuse = ...
    local seen, calls = nil, 0
    local original = vim.rpcrequest
    vim.rpcrequest = function(_, method, verb, args)
      calls = calls + 1
      seen = { method, verb, args }
      if type(refuse) == "string" then error(refuse, 0) end
    end
    local ok, err = pcall(vim.cmd, "LainNoteDone")
    vim.rpcrequest = original
    return { ok = ok, err = tostring(err), sent = seen, calls = calls }
  LUA

  at_exit { FileUtils.remove_entry(PROJECT) if File.directory?(PROJECT) }
end

RSpec.describe "the review annotation runtime", :nvim do
  around do |example|
    socket = File.join(Dir.tmpdir, "lain-nvim-annotate-spec-#{Process.pid}-#{rand(1_000_000)}.sock")
    # `noswapfile` because this file MODIFIES the new side (the refusal example
    # has to), and the editor is killed with TERM afterwards -- which leaves a
    # swap file in the shared fixture beside the real file. The next example's
    # `bufload` then meets `E325: ATTENTION` and the failure names nothing about
    # annotations at all. The new side's swap file is `47_diff.lua`'s concern and
    # `diff_mode_spec.rb` is where it is asserted; nothing here depends on it.
    pid = spawn("nvim", "--headless", "--clean", "-n", "--cmd", "set noswapfile", "--listen", socket,
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

  def project = AnnotateFixture::PROJECT

  def lua(source, args = []) = @editor.exec_lua(source, args)

  # The two commits the diff spans. T15 stamps each side with its own, and a
  # note's whole worth a year later is which of them it was authored against.
  def revisions = { "old" => "base0ff", "new" => "head1ff" }

  # 40 lines with exactly one of them different, which is §3.4's shape: it gives
  # a rewritten span with marks both inside and outside it.
  def guide_old_lines(changed: 20)
    (1..40).map { |i| i == changed ? "was line #{i}" : "line #{i}" }
  end

  def other_old_lines = ["another document", "second line was different"]

  def open_changeset(path, old_lines, line = 1)
    lua("_G.__lain.open_changeset(...)", [path, old_lines, line, revisions])
  end

  # slot -> window, off the window variables T26 stamps, so this never calls
  # `review_layout` -- which would TAKE FOCUS and move the cursor these examples
  # place notes with.
  def slots
    lua(<<~LUA)
      local found = {}
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local slot = vim.w[win].lain_review_slot
        if slot then found[slot] = win end
      end
      return found
    LUA
  end

  def buf_in(win) = lua("return vim.api.nvim_win_get_buf(...)", [win])

  # Place a note on `line` of one side, exactly as a human does: move the cursor
  # into that window, then run the command.
  def note(side, line, kind, text)
    lua(<<~LUA, [slots.fetch(side), line, "LainNote #{kind} #{text}"])
      local win, row, command = ...
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      vim.cmd(command)
    LUA
  end

  def refusal(side, line, argument)
    lua(<<~LUA, [slots.fetch(side), line, "LainNote #{argument}"])
      local win, row, command = ...
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { row, 0 })
      local ok, err = pcall(vim.cmd, command)
      return { ok, tostring(err) }
    LUA
  end

  # `:LainNoteDone` with `vim.rpcrequest` swapped for a capture, the idiom
  # `review_view_spec.rb` established: the spec's own channel has no
  # `lain_command` handler, so a real request would block the editor.
  #
  # `refuse` makes the capture RAISE, which is how the "a refused settle keeps
  # the notes" example reaches the one branch that matters.
  def settle(refuse: nil) = lua(AnnotateFixture::CAPTURE, [refuse])

  # The notes as they crossed the wire, in wire order.
  def settled(refuse: nil)
    answer = settle(refuse:)
    raise "LainNoteDone refused: #{answer["err"]}" unless answer["ok"]

    answer.fetch("sent").fetch(2).fetch(0)
  end

  # The wire payload driven through the real Ruby module, which is where the
  # card's ACs are actually stated ("the RECORDED anchor names side new..."). It
  # takes no documents: drift was measured in the editor, at settle, and rides
  # the wire as a field.
  def records(notes) = Lain::Review::Annotations.settle(notes)

  def marks_on(buf)
    lua(<<~LUA, [buf])
      local b = ...
      return vim.api.nvim_buf_get_extmarks(b, vim.api.nvim_create_namespace("lain_review_notes"),
                                           0, -1, { details = true })
    LUA
  end

  def changedtick(buf) = lua("return vim.api.nvim_buf_get_changedtick(...)", [buf])

  describe "placing a note" do
    # T15 WITHDRAWS the stamps when the human moves on, so a stamped buffer is
    # not a review buffer forever -- reading the variable IS the check, and there
    # is no buffer-name parsing anywhere in this module for exactly that reason.
    it "refuses a buffer lain does not have open for review" do
      open_changeset("docs/guide.txt", guide_old_lines)

      answer = lua(<<~LUA)
        vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, true))
        local ok, err = pcall(vim.cmd, "LainNote note nothing to see")
        return { ok, tostring(err) }
      LUA

      expect(answer.first).to be(false)
      expect(answer.last).to include("review")
    end

    # The kind is a closed set, and an unrecognised one must fail HERE rather
    # than survive to the settle: a refusal is worth something only while the
    # human's words are still in front of them, and by `:LainNoteDone` they have
    # placed a dozen more.
    it "refuses a kind that is not one of the three, naming them" do
      open_changeset("docs/guide.txt", guide_old_lines)

      answer = refusal("new", 3, "praise this is lovely")

      expect(answer.first).to be(false)
      expect(answer.last).to include("note", "question", "blocker", "praise")
      expect(marks_on(buf_in(slots.fetch("new")))).to be_empty
    end

    it "refuses a note with no words in it" do
      open_changeset("docs/guide.txt", guide_old_lines)

      answer = refusal("new", 3, "blocker")

      expect(answer.first).to be(false)
      expect(marks_on(buf_in(slots.fetch("new")))).to be_empty
    end

    # AC5. Right-aligned is what keeps the marker off the code -- the whole
    # reason the note's TEXT lives in the thread pane (T18) and only a marker
    # renders inline, as octo does. `virt_text_pos` is read back off the mark
    # rather than assumed, because a `virt_text` with no position defaults to
    # `eol`, which sits immediately after the code it must not collide with.
    it "renders a right-aligned marker naming the kind, on the cursor line" do
      open_changeset("docs/guide.txt", guide_old_lines)

      note("new", 7, "blocker", "this allocates per row")

      marks = marks_on(buf_in(slots.fetch("new")))
      expect(marks.size).to eq(1)
      _id, row, _col, details = marks.first
      expect(row).to eq(6)
      expect(details["virt_text_pos"]).to eq("right_align")
      expect(details["virt_text"].flatten).to include(a_string_including("blocker"))
    end

    # The kind is a closed set the human has to type, so it completes -- and it
    # completes ONLY where a kind may go. Offering `blocker` halfway through a
    # sentence is worse than offering nothing, and the third case here is the one
    # a `complete` that ignored the command line would get wrong.
    it "completes the kind, and only where a kind may go" do
      expect(lua('return vim.fn.getcompletion("LainNote ", "cmdline")')).to eq(%w[blocker note question])
      expect(lua('return vim.fn.getcompletion("LainNote b", "cmdline")')).to eq(["blocker"])
      expect(lua('return vim.fn.getcompletion("LainNote note some ", "cmdline")')).to eq([])
    end

    it "renders one marker per note rather than one per line" do
      open_changeset("docs/guide.txt", guide_old_lines)

      note("new", 7, "note", "first")
      note("new", 7, "question", "second")

      expect(marks_on(buf_in(slots.fetch("new"))).size).to eq(2)
    end
  end

  describe "what settles" do
    # AC1, end to end: the editor's stamp, across the wire, into the record.
    it "records a new-side note against that file line and the head revision" do
      open_changeset("docs/guide.txt", guide_old_lines)

      note("new", 12, "note", "off by one here")

      record = records(settled).first
      expect(record.to_h.except(:id)).to eq(
        path: "docs/guide.txt", side: "new", line: 12, anchor_text: "line 12",
        text: "off by one here", kind: "note", drifted: false, revision: "head1ff"
      )
    end

    # AC2. The old side's revision is the MERGE BASE, and it is a different
    # string from the new side's -- a module that stamped one revision on both
    # would pass every new-side example above.
    it "records an old-side note against the old-side line and the merge-base revision" do
      open_changeset("docs/guide.txt", guide_old_lines)

      note("old", 20, "question", "why was this here")

      record = records(settled).first
      expect(record.side).to eq("old")
      expect(record.revision).to eq("base0ff")
      expect(record.line).to eq(20)
      expect(record.anchor_text).to eq("was line 20")
      expect(record.drifted).to be(false)
    end

    # AC4, and the reason this module keeps a placement sequence at all.
    # `nvim_buf_get_extmarks` answers in POSITION order, so an implementation
    # that iterated marks would send 12, 25, 40 -- a plausible, tidy, wrong
    # answer that no assertion about content would ever catch.
    it "settles three notes placed on lines 40, 12 and 25 in that order" do
      open_changeset("docs/guide.txt", guide_old_lines)

      note("new", 40, "note", "last line")
      note("new", 12, "blocker", "twelfth")
      note("new", 25, "question", "middle")

      # ONE settle: `:LainNoteDone` forgets what it handed over, so a second call
      # would answer an empty payload (which the "forgets" example below pins).
      settled_records = records(settled)

      expect(settled_records.map(&:line)).to eq([40, 12, 25])
      expect(settled_records.map(&:kind)).to eq(%w[note blocker question])
    end

    # Placement order across the two SIDES too, which is where a per-buffer
    # sequence (or a per-buffer iteration) reads differently from the truth: the
    # human alternated, and `pairs` over a buffer table has no order at all.
    it "settles notes from both sides in one placement order" do
      open_changeset("docs/guide.txt", guide_old_lines)

      note("new", 5, "note", "new first")
      note("old", 30, "note", "old second")
      note("new", 8, "note", "new third")

      expect(settled.map { |sent| [sent["side"], sent["line"]] })
        .to eq([["new", 5], ["old", 30], ["new", 8]])
    end

    # THE WIRE SHAPE, and it is the mistake this rail keeps making: every verb
    # here is destructured Ruby-side as `verb, args`, so flat positionals arrive
    # as the first note alone and every other one is dropped on the floor.
    it "sends the whole payload as ONE array of arguments" do
      open_changeset("docs/guide.txt", guide_old_lines)
      note("new", 3, "note", "first")
      note("new", 4, "note", "second")

      sent = settle.fetch("sent")

      expect(sent[0]).to eq("lain_command")
      expect(sent[1]).to eq("review_notes")
      expect(sent[2]).to be_an(Array).and have_attributes(size: 1)
      expect(sent[2].first).to be_an(Array).and have_attributes(size: 2)
    end

    # Every key, always present -- `drifted` most of all. A nil value drops its
    # key from a lua table entirely, and {Review::AnnotationPlaced} gives
    # `drifted` no default precisely so a hole cannot be journaled as "did not
    # drift". `false` is the answer most notes give, so the key going missing on
    # the common path is exactly the slip that would never be noticed.
    it "carries every key Ruby needs, including the measurement, and nothing it does not" do
      open_changeset("docs/guide.txt", guide_old_lines)
      note("new", 3, "note", "first")

      sent = settled.first
      expect(sent.keys).to match_array(%w[path side line anchor_text text kind revision drifted])
      expect(sent["drifted"]).to be(false)
    end

    it "settles an empty review rather than refusing it" do
      open_changeset("docs/guide.txt", guide_old_lines)

      expect(settled).to eq([])
    end
  end

  describe "a note whose review has moved on" do
    # T15 UNSTAMPS a buffer when the human opens the next file, which is what
    # makes reading the stamp at SETTLE time wrong: by then the new side of the
    # file the note is on carries no side, no revision and no path. Capturing all
    # three at PLACEMENT is the only shape that survives the human navigating,
    # and navigating is what a review IS.
    it "keeps the side, revision and path it was placed against" do
      open_changeset("docs/guide.txt", guide_old_lines)
      note("new", 12, "note", "off by one here")

      open_changeset("docs/other.txt", other_old_lines)

      expect(lua("return vim.b[vim.fn.bufnr(...)].lain_review_side", ["docs/guide.txt"])).to be_nil
      expect(settled.first.slice("path", "side", "revision"))
        .to eq("path" => "docs/guide.txt", "side" => "new", "revision" => "head1ff")
    end
  end

  describe "drift" do
    # THE EXTMARK CONTRACT, and the reason drift is never a question about mark
    # validity. A mark inside a rewritten span MOVES: `get_extmark_by_id` still
    # answers a position and never reports invalid, so a validity check reads
    # "still there" for a mark that now names a different line -- the silent
    # wrong answer, in the one place a human would most trust it.
    #
    # The old side is refilled in place when the base moves under a re-review,
    # and here the base rewrote the very line the note is on. The note still
    # carries the text that line SAID when it was placed, and that comparison --
    # not the mark's survival -- is the whole of the drift answer.
    it "reports drift as a content comparison, on a mark that is still perfectly valid" do
      open_changeset("docs/guide.txt", guide_old_lines(changed: 20))
      note("old", 20, "blocker", "this is the one")
      old_buf = buf_in(slots.fetch("old"))

      moved = guide_old_lines(changed: 20)
      moved[19] = "was line 20, rewritten"
      open_changeset("docs/guide.txt", moved)

      # THE MARK IS STILL THERE, and answers a position. Anything that decided
      # drift by asking whether it survived would report this note as fine.
      expect(marks_on(old_buf).size).to eq(1)

      sent = settled.first
      expect(sent["anchor_text"]).to eq("was line 20")
      expect(sent["drifted"]).to be(true)

      record = records([sent]).first
      expect(record.drifted).to be(true)
      expect(record.text).to eq("this is the one")
    end

    # A line the buffer no longer reaches answers drifted rather than raising or
    # going quiet: `nvim_buf_get_lines` hands back nothing for it, and nothing is
    # not what the note anchored to. That collapses "moved" and "gone" into one
    # boolean deliberately -- the same collapse `Anchor#drifted?` documents --
    # and the note is KEPT either way, which is the half that matters.
    it "reports drift for a note whose line the buffer no longer has" do
      open_changeset("docs/guide.txt", guide_old_lines)
      note("old", 40, "blocker", "the last line")

      open_changeset("docs/guide.txt", guide_old_lines.take(10))

      record = records(settled).first
      expect(record.drifted).to be(true)
      expect(record.text).to eq("the last line")
    end

    # THE ROW COMES OFF THE MARK, never off where the note was placed. Two lines
    # inserted above it move it from line 30 to line 32 without changing a word
    # of it -- so a module that reported the placement row would name a line the
    # human never chose AND report drift against it, while one that reported the
    # mark's row gets both right. Nothing else in this file tells the two apart:
    # every other example leaves the note where it was put.
    it "reports the mark's current row after lines are inserted above it" do
      open_changeset("docs/guide.txt", guide_old_lines(changed: 20))
      note("old", 30, "note", "unchanged, but moved")

      inserted = guide_old_lines(changed: 20)
      inserted.insert(4, "brand new a", "brand new b")
      open_changeset("docs/guide.txt", inserted)

      record = records(settled).first
      expect(record).to have_attributes(line: 32, anchor_text: "line 30", drifted: false)
    end

    # WHY THE MEASUREMENT HAS TO HAPPEN IN THE EDITOR, in the one case where a
    # Ruby-side one is not merely awkward but wrong. git hands the old side its
    # carriage returns, nvim strips them from a 'fileformat=dos' buffer and
    # `47_diff.as_shown` strips them from the old side to match -- so the anchor
    # a human captures reads `line 2` while git's own bytes read `line 2\r`.
    # Compared against those bytes, EVERY line of the file drifts: a review
    # surface telling a human that nothing is where they left it. Both halves of
    # the comparison come off the same buffer, so it cannot arise.
    it "reports no drift on a CRLF file, on either side" do
      open_changeset("docs/crlf.txt", (1..5).map { |i| "line #{i}\r" })

      note("old", 2, "note", "old side of a dos file")
      note("new", 3, "note", "new side of a dos file")

      expect(settled.map { |sent| [sent["side"], sent["anchor_text"], sent["drifted"]] })
        .to eq([["old", "line 2", false], ["new", "line 3", false]])
    end

    # The measured silence T15 hands over: two identical re-opens write NOTHING,
    # bump no 'changedtick' and fire no `on_lines`, so a note survives the
    # gesture a human makes most -- coming back to the file they are reading.
    it "is unmoved by a re-open of identical content, which writes nothing at all" do
      open_changeset("docs/guide.txt", guide_old_lines)
      note("old", 20, "note", "still here")
      old_buf = buf_in(slots.fetch("old"))
      before = changedtick(old_buf)

      open_changeset("docs/guide.txt", guide_old_lines)

      expect(changedtick(old_buf)).to eq(before)
      expect(records(settled).first).to have_attributes(line: 20, drifted: false)
    end

    # Marks OUTSIDE the rewritten span hold their rows, on both sides -- the
    # asymmetry that once lost only the old side's marks is closed. A note above
    # the change must not be reported as drifted, or every settle would cry wolf.
    it "leaves a note above the rewritten span reading exactly what it read" do
      open_changeset("docs/guide.txt", guide_old_lines(changed: 30))
      note("old", 5, "note", "well above the change")

      open_changeset("docs/guide.txt", guide_old_lines(changed: 31))

      expect(records(settled).first).to have_attributes(line: 5, anchor_text: "line 5", drifted: false)
    end
  end

  describe "a buffer that goes away" do
    # ESCALATION TRIGGER 1, and it cuts BOTH ways. The `BufUnload` GC must fire
    # so no per-buffer entry outlives its buffer -- and T15's `drop_stale` wipes
    # the previous file's old side the moment the human opens the next file, so a
    # GC that merely DROPPED would lose every old-side note the instant the human
    # navigated. The words are the part nobody can reconstruct, so the note is
    # HARVESTED at its last known row instead.
    it "harvests an old-side note when the next file wipes its buffer" do
      open_changeset("docs/guide.txt", guide_old_lines)
      note("old", 20, "blocker", "history says otherwise")
      old_buf = buf_in(slots.fetch("old"))

      open_changeset("docs/other.txt", other_old_lines)

      expect(lua("return vim.api.nvim_buf_is_valid(...)", [old_buf])).to be(false)
      expect(settled.first.slice("path", "side", "line", "anchor_text", "text"))
        .to eq("path" => "docs/guide.txt", "side" => "old", "line" => 20,
               "anchor_text" => "was line 20", "text" => "history says otherwise")
    end

    it "keeps no entry for a buffer that is gone" do
      open_changeset("docs/guide.txt", guide_old_lines)
      note("old", 20, "note", "history says otherwise")
      old_buf = buf_in(slots.fetch("old"))

      open_changeset("docs/other.txt", other_old_lines)

      expect(lua("return _G.__lain.review_notes_held(...)", [old_buf])).to be_nil
    end

    # THE `BufUnload` GC IS NOT A GUARANTEE, and this is the residue of
    # escalation trigger 1. The autocmd does not fire under 'eventignore', under
    # `noautocmd`, or for a plugin that suppresses events around its own
    # bookkeeping -- and then the entry outlives its buffer. Measured before the
    # guard existed: `nvim_buf_get_extmark_by_id` raises a raw
    # `Invalid buffer id: 2` out of `:LainNoteDone`, nothing is sent, and the
    # human can NEVER settle again, because every later gesture dies on the same
    # dead entry. The failure is total, not partial.
    #
    # lain's own `drop_stale` uses a plain `nvim_buf_delete`, so nothing lain
    # does reaches this today; it was one `nvim_buf_is_valid` away.
    it "settles a note whose buffer died without its BufUnload firing" do
      open_changeset("docs/guide.txt", guide_old_lines)
      note("old", 20, "blocker", "history says otherwise")
      old_buf = buf_in(slots.fetch("old"))

      lua(<<~LUA, [old_buf])
        local b = ...
        local restore = vim.o.eventignore
        vim.o.eventignore = "BufUnload"
        vim.api.nvim_buf_delete(b, { force = true })
        vim.o.eventignore = restore
      LUA

      answer = settle
      expect(answer["ok"]).to be(true)
      expect(answer["calls"]).to eq(1)
      # Kept, at the row it was placed on, and reported DRIFTED: the position
      # cannot be checked without the buffer, and "I could not tell" must never
      # be recorded as "it still says what it said".
      expect(answer.fetch("sent").fetch(2).fetch(0).first)
        .to include("side" => "old", "line" => 20, "anchor_text" => "was line 20",
                    "text" => "history says otherwise", "drifted" => true)
    end

    it "drops the orphaned entry once it has settled it, so a reused bufnr inherits nothing" do
      open_changeset("docs/guide.txt", guide_old_lines)
      note("old", 20, "note", "history says otherwise")
      old_buf = buf_in(slots.fetch("old"))

      lua(<<~LUA, [old_buf])
        local b = ...
        local restore = vim.o.eventignore
        vim.o.eventignore = "BufUnload"
        vim.api.nvim_buf_delete(b, { force = true })
        vim.o.eventignore = restore
      LUA
      settle

      expect(lua("return _G.__lain.review_notes_held(...)", [old_buf])).to be_nil
    end

    # Harvest ONCE. A buffer can unload more than once in a session (hide, then
    # wipe), and a note harvested twice is a note the human placed once and the
    # journal records twice.
    it "harvests a note once however often its buffer unloads" do
      open_changeset("docs/guide.txt", guide_old_lines)
      note("old", 20, "note", "once only")
      open_changeset("docs/other.txt", other_old_lines)
      open_changeset("docs/guide.txt", guide_old_lines)

      expect(settled.size).to eq(1)
    end
  end

  describe "settling" do
    # `:LainNoteDone` measures drift against the document ON DISK, so an unsaved
    # buffer would have lain report drift on lines nobody has -- and it refuses
    # BEFORE anything crosses the wire, so a refused settle is a settle that did
    # not happen rather than one that half did.
    it "refuses while a buffer holding notes is modified, and sends nothing" do
      open_changeset("docs/guide.txt", guide_old_lines)
      note("new", 12, "note", "off by one here")
      lua("vim.api.nvim_buf_set_lines(vim.fn.bufnr(...), 0, 1, false, { 'edited' })", ["docs/guide.txt"])

      answer = settle

      expect(answer["ok"]).to be(false)
      expect(answer["err"]).to include("docs/guide.txt")
      expect(answer["calls"]).to eq(0)
    end

    # Handed back means handed back: the notes and their markers are cleared, so
    # a second gesture settles nothing rather than journaling every note twice.
    it "forgets the notes it handed over" do
      open_changeset("docs/guide.txt", guide_old_lines)
      note("new", 12, "note", "off by one here")

      expect(settled.size).to eq(1)
      expect(settled).to eq([])
      expect(marks_on(buf_in(slots.fetch("new")))).to be_empty
    end

    # ...and only when it really was handed over. `review_notes` is an ANSWERED
    # verb, so lain's refusal comes back as the request's error and raises here
    # -- which is exactly why `forget` sits on the far side of a `pcall`. A
    # refused write must leave every note AND every marker where the human left
    # them: a refusal they cannot retype from is worse than no refusal at all.
    it "keeps the notes and the markers when the write is refused, and says why" do
      open_changeset("docs/guide.txt", guide_old_lines)
      note("new", 12, "note", "off by one here")

      answer = settle(refuse: "no review is open in this editor")

      expect(answer["ok"]).to be(false)
      expect(answer["err"]).to include("no review is open in this editor")
      expect(marks_on(buf_in(slots.fetch("new"))).size).to eq(1)
      expect(settled.size).to eq(1)
    end
  end
end

# The one closed set this runtime has to restate, pinned against the declaration
# that owns it. lua cannot read `Lain::Review::ANNOTATION_KINDS`, and the module
# needs the members anyway to render a marker per kind -- so the second spelling
# is forced, and the pair itself is the trap `review/vocabulary.rb` was written
# about. This is the same defence `Anchor::SIDES`' spec applies to `Review::SIDES`:
# a fourth kind added on one side and not the other fails here rather than being
# refused, in silence, at the far end of a wire.
#
# It runs without an editor (it passes under `LAIN_NVIM=0`) and costs ~2ms.
RSpec.describe "the annotation runtime's vocabulary" do
  let(:source) do
    path = Lain::Frontend::Neovim::RuntimeLoader.new.module_paths.find { |name| name.end_with?("_annotate.lua") }
    raise "no runtime annotate module found -- T16's module is gone" if path.nil?

    File.read(path)
  end

  it "declares exactly the annotation kinds Lain::Review does" do
    declared = source[/MARKERS = \{(.*?)\}/m, 1].to_s.scan(/(\w+)\s*=/).flatten

    expect(declared).to match_array(Lain::Review::ANNOTATION_KINDS)
  end

  # THE SAME TRIPWIRE `diff_mode_spec.rb` puts on `47_diff.lua`, on the module
  # its comment names as the likely offender. [diffview#466] is `E5560
  # nvim_buf_is_valid must not be called in a lua loop callback`: an nvim call
  # reached from a libuv callback needs `vim.schedule`, and getting it wrong
  # CRASHES the editor instead of failing a spec, so the signal has to arrive at
  # the edit rather than at a run.
  #
  # `nvim_buf_attach`'s `on_lines` is the specific reach, and it is the natural
  # one: it looks like the way to notice an edit. It is not needed -- an extmark
  # already tracks the edits and the comparison happens once, at settle -- so a
  # later card adding one has changed the design, not merely the code, and owes
  # `vim.schedule` on every nvim call beneath it.
  #
  # Read `diff_mode_spec.rb`'s copy for what a scan like this CANNOT catch (it
  # scans the callee, does not follow into `20_buffers.lua`, and loses to
  # aliasing). This one is not a second copy of the reasoning, only of the guard,
  # on a second file that inherits the same constraint.
  it "reaches for nothing that would run its nvim calls in a libuv callback" do
    code = source.lines.grep_v(/\A\s*--/).join
    reaches = {
      /vim[.\[]\s*["']?(uv|loop)\b/ => "libuv directly",
      /\brequire\s*\(\s*["']luv["']/ => "libuv under its other name",
      /vim\.fn[.\[]\s*["']?(jobstart|termopen|timer_start)\b/ => "a job or timer",
      /vim[.\[]\s*["']?system\b/ => "an async subprocess",
      /vim\.(defer_fn|schedule|schedule_wrap)\b/ => "deferral, which only exists to serve an async call site",
      /vim\.wait\b/ => "a yield to the event loop mid-command",
      /nvim_buf_attach/ => "an on_lines callback -- the textlock family, and unnecessary here",
      /vim\.ui\.\w+/ => "a prompt the dressing plugins make asynchronous, which would unorder placement",
      /=\s*vim\s*$/ => "an alias for `vim`, which defeats every pattern above"
    }

    expect(reaches.select { |pattern, _| code.match?(pattern) }.values).to be_empty
  end
end
