# frozen_string_literal: true

require "fileutils"
require "neovim"
require "timeout"
require "tmpdir"

# The inlet as this object uses it: ONE of {Lain::Frontend::Neovim::RenderInlet}'s
# methods, recorded rather than sent, and answering a refusal sentence or nothing
# exactly as the real one does.
#
# What is recorded is the ARGUMENT LIST, never that the call happened. "It posted
# an open" is true of an implementation sending the new side as the old, or the
# wrong path, or no revisions -- every wrong neighbour this object has -- so the
# payload is the only thing worth asserting about.
class RecordingChangesetInlet
  def initialize(refusal: nil)
    @refusal = refusal
    @posted = []
  end

  # @return [Array<Array>] one entry per post: `[path, old_lines, line, revisions]`
  attr_reader :posted

  def open_changeset(path, old_lines, line, revisions)
    @posted << [path, old_lines, line, revisions]
    @refusal
  end
end

# The NEW side on disk, for the seam that drives a real editor: `47_diff.lua`
# opens the real file for the new side, so one has to exist and its content is
# what the old side is diffed against. One text file rather than a git
# repository, `diff_mode_spec.rb`'s fixture choice and its reason -- Ruby runs
# git and the editor is only ever sent lines.
module ChangesetDiffFixture
  PROJECT = Dir.mktmpdir("lain-changeset-diff-spec")

  File.write(File.join(PROJECT, "guide.rb"), "alpha\nBETA\ngamma\n")

  # One directory DOWN, for the survey half: a row from a survey of `sub` names
  # a file the editor has to find from the project it was started in, which is
  # the only place the two roots can disagree.
  FileUtils.mkdir_p(File.join(PROJECT, "sub"))
  File.write(File.join(PROJECT, "sub", "nested.rb"), "class Nested\n  def call = 1\nend\n")

  at_exit { FileUtils.remove_entry(PROJECT) if File.directory?(PROJECT) }
end

# A changeset built from a hand-written diff over a doubled source, because the
# subject's whole job is what it reads OFF a changeset and what it posts: a real
# repository would put the assertions two objects away from the bytes they are
# about. {Lain::Review::Changeset}'s own spec drives the git half.
RSpec.describe Lain::Frontend::Neovim::ChangesetDiff do
  subject(:diff) { described_class.new(rpc: inlet) }

  let(:inlet) { RecordingChangesetInlet.new }
  let(:blobs) { { [base, "guide.rb"] => "alpha\nbeta\ngamma\n".b } }
  let(:base) { "b" * 40 }
  let(:head) { "h" * 40 }

  def modified_diff
    <<~DIFF
      diff --git a/guide.rb b/guide.rb
      --- a/guide.rb
      +++ b/guide.rb
      @@ -1,3 +1,3 @@
       alpha
      -beta
      +BETA
       gamma
    DIFF
  end

  def walk(paths)
    numstat = paths.map { |path| Lain::Review::Source::FileStat.new(path: -path, added: 1, deleted: 1) }
    [Lain::Review::Source::Commit.new(sha: "c1", subject: "s", body: "", numstat: numstat.freeze)].freeze
  end

  def source_for(text, paths)
    double = instance_double(Lain::Review::Source::LocalBranch,
                             diff: text.b, commits: walk(paths), base_ref: base, head_ref: head)
    allow(double).to receive(:file_at) { |revision, path| blobs[[revision, path]] }
    DiffSource.over(double)
  end

  def changeset_over(text = modified_diff, paths = ["guide.rb"])
    Lain::Review::Changeset.new(source: source_for(text, paths))
  end

  # The payload, named, because every example below is about one field of it and
  # `posted.first[1]` reads as nothing at all.
  def posted = inlet.posted.map { |(path, old_lines, line, revisions)| { path:, old_lines:, line:, revisions: } }

  describe "opening a row of the changeset under review" do
    before { diff.reviewing(changeset_over) }

    # The duck {Lain::Frontend::Neovim::ReviewView#offer} consumes: a String is
    # the reason nothing opened, and anything else means it did. Answering a
    # sentence on success would report every successful open as a refusal.
    it "answers nothing, which is what says the open landed" do
      expect(diff.open("guide.rb", 2)).to be_nil
    end

    it "posts the file's old side, from the BASE" do
      diff.open("guide.rb", 2)

      expect(posted).to eq([{ path: "guide.rb", old_lines: %w[alpha beta gamma], line: 2,
                              revisions: { "old" => base, "new" => head } }])
    end

    # The wrong neighbour that renders perfectly: posting the NEW side draws a
    # pane identical to the one beside it, so the diff is empty and the file
    # reads as reviewed. `beta` against `BETA` is what tells the two apart.
    it "posts the old side and not the new one, which would diff the file against itself" do
      diff.open("guide.rb", 2)

      expect(posted.first[:old_lines]).to include("beta")
      expect(posted.first[:old_lines]).not_to include("BETA")
    end

    # Both, keyed by side, because the editor stamps each buffer with its own and
    # a note anchored to no revision names no diff -- `47_diff.lua` refuses the
    # open outright rather than drawing half of it.
    it "posts both revisions, keyed by the side each belongs to" do
      diff.open("guide.rb", 2)

      expect(posted.first[:revisions]).to eq({ "old" => base, "new" => head })
    end

    it "posts the line the gesture resolved to, so the cursor lands on the hunk" do
      diff.open("guide.rb", 41)

      expect(posted.first[:line]).to eq(41)
    end

    # The editor's own refusal (a detached editor, a full queue) is a value, and
    # this object is a tail call: translating it would lose the sentence the
    # inlet already wrote.
    it "hands the editor's refusal back unchanged" do
      refusing = described_class.new(rpc: RecordingChangesetInlet.new(refusal: "no editor is attached"))
      refusing.reviewing(changeset_over)

      expect(refusing.open("guide.rb", 2)).to eq("no editor is attached")
    end
  end

  describe "a file the changeset adds" do
    let(:blobs) { {} }

    before do
      diff.reviewing(changeset_over(<<~DIFF, ["new.rb"]))
        diff --git a/new.rb b/new.rb
        new file mode 100644
        --- /dev/null
        +++ b/new.rb
        @@ -0,0 +1,2 @@
        +alpha
        +beta
      DIFF
    end

    # It OPENS, with an empty old side: a file with no old side is a diff against
    # nothing, which is exactly what a new file is, and refusing it would make
    # every added file unreadable in the editor.
    it "opens with an empty old side rather than refusing" do
      expect(diff.open("new.rb", 1)).to be_nil
      expect(posted).to eq([{ path: "new.rb", old_lines: [], line: 1,
                              revisions: { "old" => base, "new" => head } }])
    end
  end

  describe "a renamed file" do
    let(:blobs) { { [base, "from.rb"] => "keep\nold\n".b } }

    before do
      diff.reviewing(changeset_over(<<~DIFF, ["from.rb => to.rb"]))
        diff --git a/from.rb b/to.rb
        similarity index 80%
        rename from from.rb
        rename to to.rb
        --- a/from.rb
        +++ b/to.rb
        @@ -1,2 +1,2 @@
         keep
        -old
        +new
      DIFF
    end

    # The old side comes from the OLD name and the buffer is stamped with the
    # NEW one: the base holds no `to.rb`, and everything downstream -- the stamp,
    # the note, the mark -- keys on the path the sidebar drew.
    it "reads the old side at the old path and posts the new one" do
      diff.open("to.rb", 1)

      expect(posted.first[:path]).to eq("to.rb")
      expect(posted.first[:old_lines]).to eq(%w[keep old])
    end
  end

  describe "a row this changeset cannot open" do
    before { diff.reviewing(changeset_over) }

    # `47_diff.lua` REFUSES an absolute path by name -- the old side's buffer is
    # named `lain://review/OLD/<path>` and an absolute one falls outside that
    # contract. This object cannot trip it, because what it posts is the path the
    # CHANGESET carries and an argument that is not one of those never gets that
    # far.
    it "refuses an absolute path rather than posting one the editor would reject" do
      expect(diff.open("/etc/passwd", 1)).to be_a(String)
      expect(inlet.posted).to be_empty
    end

    it "refuses a path this changeset does not carry, naming it" do
      expect(diff.open("elsewhere.rb", 1)).to include("elsewhere.rb")
      expect(inlet.posted).to be_empty
    end

    it "refuses an empty path, which the editor would refuse for its own reasons" do
      expect(diff.open("", 1)).to be_a(String)
      expect(inlet.posted).to be_empty
    end

    # Before anything is drawn there is no changeset to open a row of, and this
    # is the sentence that says so rather than one blaming the row.
    it "refuses when no changeset has been drawn into the editor at all" do
      expect(described_class.new(rpc: inlet).open("guide.rb", 1)).to be_a(String)
      expect(inlet.posted).to be_empty
    end
  end

  describe "a binary file" do
    let(:blobs) { { [base, "blob.bin"] => "\x00\x01\x02".b } }

    before do
      diff.reviewing(changeset_over(<<~DIFF, ["blob.bin"]))
        diff --git a/blob.bin b/blob.bin
        index 1111111..2222222 100644
        Binary files a/blob.bin and b/blob.bin differ
      DIFF
    end

    # A binary file has no lines, so `old_lines` would be whatever splitting its
    # bytes on newlines happened to produce -- NULs into buffer lines, against a
    # new side nvim renders as binary. Refused in words instead, which is the
    # honest answer to "show me the diff of a picture".
    it "refuses rather than posting bytes nvim would have to render as lines" do
      expect(diff.open("blob.bin", 1)).to be_a(String)
      expect(inlet.posted).to be_empty
    end
  end

  describe "a base the repository cannot answer for" do
    let(:blobs) { {} }

    before { diff.reviewing(changeset_over) }

    # The diff says this file has an old side and the object database does not
    # have it. Posting an empty old side instead would draw every line of the
    # file as added -- a review of a changeset nobody wrote, rendered perfectly.
    it "refuses rather than drawing the whole file as new" do
      expect(diff.open("guide.rb", 1)).to include(base)
      expect(inlet.posted).to be_empty
    end
  end

  # THE CARD'S ACCEPTANCE TEST, end to end and against a real editor: a real
  # {Lain::Frontend::Neovim::RenderInlet}, a real queue, a real `nvim_exec_lua`
  # into a real nvim, and a real {Lain::Frontend::Neovim::ReviewView} resolving
  # the row. `47_diff.lua` and its `pair()` were already spec'd; what was missing
  # was any caller at all, so the only assertion worth making here is one that
  # reads the buffers nvim actually holds -- a queued command is not a drawn one.
  describe "against a real editor", :nvim, :seam do
    subject(:diff) { described_class.new(rpc: real_inlet) }

    let(:real_inlet) { Lain::Frontend::Neovim::RenderInlet.new(waker: -> {}) }

    around do |example|
      socket = File.join(Dir.tmpdir, "lain-changeset-diff-#{Process.pid}-#{rand(1_000_000)}.sock")
      # `-n` (no swap file), the repository's rule for a headless nvim in a spec:
      # a suite that leaves swap files behind eventually fails with E326.
      pid = spawn("nvim", "--headless", "--clean", "-n", "--listen", socket,
                  chdir: ChangesetDiffFixture::PROJECT, out: File::NULL, err: File::NULL)
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

    # Every buffer the review stamped, as the three facts T16 reads off one plus
    # its lines -- which is the whole of what `:LainNote` needs to place a note,
    # and the whole of what nothing in the tree produced before this object.
    def stamped_buffers
      @editor.exec_lua(<<~LUA, [])
        local found = {}
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if vim.b[b].lain_review_side ~= nil then
            found[vim.b[b].lain_review_side] = { revision = vim.b[b].lain_review_revision,
              path = vim.b[b].lain_review_path, lines = vim.api.nvim_buf_get_lines(b, 0, -1, false) }
          end
        end
        return found
      LUA
    end

    def diffed_windows
      @editor.exec_lua("return vim.tbl_map(function(w) return vim.wo[w].diff end, vim.api.nvim_list_wins())", [])
    end

    it "draws both sides, each stamped with its own side, revision and path" do
      diff.reviewing(changeset_over)
      diff.open("guide.rb", 2)
      real_inlet.drain(@editor)

      expect(stamped_buffers).to eq(
        "old" => { "revision" => base, "path" => "guide.rb", "lines" => %w[alpha beta gamma] },
        "new" => { "revision" => head, "path" => "guide.rb", "lines" => %w[alpha BETA gamma] }
      )
    end

    # `pair()`, which is the reason the stamps are worth having: two buffers
    # side by side are not a diff, and `diffthis` on one window alone diffs it
    # against whatever the other happens to hold.
    it "puts the pair into diff mode, which is what makes it a review and not two files" do
      diff.reviewing(changeset_over)
      diff.open("guide.rb", 2)
      real_inlet.drain(@editor)

      expect(diffed_windows.count(true)).to eq(2)
    end

    # The whole gesture, from the row number the editor sends: the view resolves
    # it, this object reads the changeset, the editor draws. Nothing between the
    # `<CR>` and the buffers is a double.
    it "opens from a sidebar row a real ReviewView resolved" do
      changeset = changeset_over
      view = Lain::Frontend::Neovim::ReviewView.new(changesets: diff)
      view.reviewing(changeset)
      rendered = view.render(marked_like(changeset), scope: :cumulative)

      opened = view.open(1, generation: rendered.generation)
      real_inlet.drain(@editor)

      expect(opened).to have_attributes(opened?: true, path: "guide.rb")
      expect(stamped_buffers.keys).to contain_exactly("old", "new")
    end

    # A SURVEY of a subdirectory, through the same object: the corpus names its
    # files from the project it was surveyed in, so the path this posts is one
    # the editor's own root resolves. Named from the corpus rather than written
    # here, because a literal would pass against the very defect this pins --
    # a corpus that named the file `sub.rb` posts `sub.rb`, and the buffer is
    # then an empty one at the project root.
    it "opens the real file for a row a subdirectory survey named" do
      diff.reviewing(Lain::Review::Changeset.new(source: corpus_over_sub))
      diff.open("sub/nested.rb", 1)
      real_inlet.drain(@editor)

      expect(new_side).to include("name" => File.join(ChangesetDiffFixture::PROJECT, "sub/nested.rb"),
                                  "lines" => ["class Nested", "  def call = 1", "end"])
    end

    # The latent hazard beside the resolution, and the one that WRITES: a new
    # side with no file behind it -- a deletion under review, or a path this
    # editor resolves differently than the sender meant -- is an empty buffer
    # that a `:w` turns into a file. `nowrite` is the editor's own E382.
    describe "a new side with no file behind it" do
      let(:blobs) { { [base, "gone.rb"] => "alpha\nbeta\n".b } }

      it "refuses to write it, rather than creating the file the review says is gone" do
        diff.reviewing(changeset_over(deleted_diff, ["gone.rb"]))
        diff.open("gone.rb", 1)
        real_inlet.drain(@editor)

        expect(new_side.fetch("buftype")).to eq("nowrite")
        expect(written("gone.rb")).to include("E382")
        expect(File.exist?(File.join(ChangesetDiffFixture::PROJECT, "gone.rb"))).to be(false)
      end
    end

    # The OTHER way out of a review, and the one no buffer option closes:
    # `:saveas` succeeds under both `nowrite` and `nomodifiable` (measured) and
    # renames the buffer in place. A stamp left on it says the review is still
    # looking at a file it no longer names, which is a wrong answer rather than
    # a missing one -- the rule this module already states for `unstamp`.
    it "withdraws the review stamp from a buffer :saveas renamed out from under it" do
      diff.reviewing(changeset_over)
      diff.open("guide.rb", 2)
      real_inlet.drain(@editor)

      renamed_new_side("elsewhere.rb")

      expect(stamped_buffers).not_to have_key("new")
      expect(stamped_buffers.keys).to contain_exactly("old")
    end

    def renamed_new_side(name)
      @editor.exec_lua(<<~LUA, [File.join(ChangesetDiffFixture::PROJECT, name)])
        local wanted = ...
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if vim.b[b].lain_review_side == "new" then
            vim.api.nvim_buf_call(b, function() vim.cmd("saveas! " .. wanted) end)
            return true
          end
        end
        return false
      LUA
    end

    it "leaves a new side that DOES name a file writable, which is half of why it is the real file" do
      diff.reviewing(changeset_over)
      diff.open("guide.rb", 2)
      real_inlet.drain(@editor)

      expect(new_side.fetch("buftype")).to eq("")
    end

    # The new side as nvim holds it, at the two facts this group is about: the
    # name it resolved to, and whether writing it would create that path.
    def new_side
      @editor.exec_lua(<<~LUA, [])
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if vim.b[b].lain_review_side == "new" then
            return { name = vim.api.nvim_buf_get_name(b), buftype = vim.bo[b].buftype,
                     lines = vim.api.nvim_buf_get_lines(b, 0, -1, false) }
          end
        end
        return nil
      LUA
    end

    # What `:w` in that buffer answers. `pcall`, because the refusal is an error
    # the editor raises and an uncaught one would take the RPC call down instead
    # of reporting the refusal this example is about.
    def written(name)
      @editor.exec_lua(<<~LUA, [name])
        local wanted = ...
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
          if vim.b[b].lain_review_path == wanted and vim.b[b].lain_review_side == "new" then
            local ok, err = pcall(function() vim.api.nvim_buf_call(b, function() vim.cmd("write") end) end)
            return ok and "written" or tostring(err)
          end
        end
        return "no such buffer"
      LUA
    end

    # A real {Lain::Review::Source::Corpus} over a subdirectory, named from the
    # directory THIS editor was started in -- which is the wiring
    # {Lain::CLI::Command::Survey} does and the whole of what the row carries.
    def corpus_over_sub
      here = ChangesetDiffFixture::PROJECT
      sub = File.join(here, "sub")
      Lain::Review::Source::Corpus.new(
        walk: Lain::Survey::Walk.new(root: sub, sensitivity: Lain::Sensitivity.new(home: "/home/nobody", cwd: here)),
        projection: Lain::Survey::Projection.new(ledger: Lain::Sensitivity::Ledger.new), named_from: here
      )
    end

    def deleted_diff
      <<~DIFF
        diff --git a/gone.rb b/gone.rb
        deleted file mode 100644
        --- a/gone.rb
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -alpha
        -beta
      DIFF
    end

    # The sidebar's own duck, which is T13's to build -- and it is built here
    # rather than doubled, because that duck has grown twice since (a row's
    # `#hunk_keys`, then its `#chunked?`) and a hand-rolled Struct is a fixture
    # that goes stale without failing until a view finally asks.
    def marked_like(changeset)
      Lain::Review::Session::MarkedChangeset.of(changeset,
                                                Lain::Review::Marks.new(base_ref: changeset.base_ref),
                                                strategy: Lain::Review::Partition::STRATEGIES.fetch(:cumulative))
    end
  end

  describe "the round the editor is on" do
    # The changeset is what a LATER gesture resolves against, so a second round
    # in the same editor must open rows of the second changeset. Holding the
    # first would open the file the human is no longer reviewing.
    it "opens rows of the changeset most recently drawn" do
      diff.reviewing(changeset_over)
      diff.reviewing(changeset_over(<<~DIFF, ["other.rb"]))
        diff --git a/other.rb b/other.rb
        new file mode 100644
        --- /dev/null
        +++ b/other.rb
        @@ -0,0 +1 @@
        +only here
      DIFF

      expect(diff.open("other.rb", 1)).to be_nil
      expect(diff.open("guide.rb", 1)).to be_a(String)
    end
  end
end
