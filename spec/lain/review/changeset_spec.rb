# frozen_string_literal: true

require "fileutils"
require "mixlib/shellout"

# The three-commit repository the seam half reviews, built ONCE per process and
# copied after that -- {SeedRepo}'s reasoning at the scale of the whole fixture.
#
# `shared.rb` is touched by two of the three commits. `counters.rb` is the
# falsifiable one: its single hunk carries an insertion ABOVE a deletion, so an
# old counter that advanced on the insertion reports `line 7` as `line 8` and
# `git show <base>:counters.rb` disagrees. `long.rb` is changed in two places far
# enough apart that -U3 cannot merge them, so it is the file that makes "every
# hunk of every file" mean more than "the only hunk". `crlf.txt` is committed
# onto `base` BEFORE feature forks, so it is present at the merge base and its
# change is a modification with anchors on both sides.
module ChangesetRepo
  SCRUB = Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB

  # Hermeticity, not decoration: a developer with `core.autocrlf=input` in
  # ~/.gitconfig would have git normalize the fixture on the way in and the CRLF
  # examples would pass by not testing anything. Written into the template's
  # repo-local config, so every copy inherits them -- one mechanism, in the place
  # that covers every consumer.
  PINS = { "core.autocrlf" => "false", "core.eol" => "lf" }.freeze

  Shape = Data.define(:dir, :first, :second, :third)

  class << self
    # @return [Shape] a directory to copy, never to mutate, and its three oids
    def template = @template ||= build # rubocop:disable ThreadSafety/ClassInstanceVariable

    def long_file(changed: false)
      edits = changed ? [5, 35] : []
      (1..40).map { |n| edits.include?(n) ? "CHANGED #{n}\n" : "line #{n}\n" }.join
    end

    private

    def seed
      { "shared.rb" => "a\nb\nc\n",
        "counters.rb" => (1..8).map { |n| "l#{n}\n" }.join,
        "long.rb" => long_file,
        "from.rb" => "keep\nold\n",
        "gone.rb" => "one\ntwo\n" }
    end

    def build
      dir = Dir.mktmpdir("lain-changeset-template")
      at_exit { FileUtils.remove_entry(dir, true) }
      FileUtils.cp_r("#{SeedRepo.at(seed)}/.", dir)
      PINS.each { |key, value| git(dir, "config", key, value) }
      Shape.new(dir:, **commits(dir))
    end

    def commits(dir)
      git(dir, "checkout", "-q", "-b", "base")
      commit(dir, "a CRLF file at the base", "crlf.txt" => "x\r\ny\r\nz\r\n")
      git(dir, "checkout", "-q", "-b", "feature")
      first = commit(dir, "first", "shared.rb" => "a\nCHANGED\nc\n",
                                   "counters.rb" => "l1\nl2\nNEW\nl3\nl4\nl5\nl6\nl8\n")
      second = commit(dir, "second", "shared.rb" => "a\nCHANGED\nc\nappended\n", "added.rb" => "brand new\n",
                                     "long.rb" => long_file(changed: true), "crlf.txt" => "x\r\nCHANGED\r\nz\r\n")
      git(dir, "mv", "from.rb", "to.rb")
      git(dir, "rm", "-q", "gone.rb")
      { first:, second:, third: commit(dir, "third", "to.rb" => "keep\nnew\n") }
    end

    # BINARY writes, so a fixture means the bytes it says.
    def commit(dir, message, files)
      files.each { |path, body| File.binwrite(File.join(dir, path), body) }
      git(dir, "add", "-A")
      git(dir, "commit", "-q", "-m", message)
      git(dir, "rev-parse", "HEAD").stdout.strip
    end

    def git(dir, *)
      shell = Mixlib::ShellOut.new("git", "-C", dir, *, environment: SCRUB)
      shell.run_command.error!
      shell
    end
  end
end

# Two halves, and the split is deliberate.
#
# The UNIT half drives a hand-written diff through an `instance_double` of the
# source port, because a diff shape is a string and building a real repo to
# produce one hides which bytes the assertion is actually about.
#
# The SEAM half drives real git, because the two acceptance criteria that matter
# most -- "every new-side anchor resolves against the working tree" and "every
# old-side anchor resolves against the merge base" -- are FALSIFIABLE only
# against a real revision. The spike found its old-side counter bug exactly
# there: a hand-written expectation would have been written to match whatever the
# parser answered.
RSpec.describe Lain::Review::Changeset do
  # A diff whose one hunk carries an addition BEFORE a deletion. That order is
  # the whole point: with the old-side counter wrongly advancing on `+inserted`,
  # `-gamma` is reported at old line 4 instead of 3, and every assertion that
  # only reads the new side still passes.
  def one_file_diff
    <<~DIFF
      diff --git a/one.rb b/one.rb
      index 1111111..2222222 100644
      --- a/one.rb
      +++ b/one.rb
      @@ -1,3 +1,4 @@ def method
       alpha
      +inserted
       beta
      -gamma
      +GAMMA
    DIFF
  end

  def commit_record(sha:, subject: "s", body: "", paths: [])
    numstat = paths.map { |path| Lain::Review::Source::FileStat.new(path: -path, added: 1, deleted: 1) }
    Lain::Review::Source::Commit.new(sha:, subject:, body:, numstat: numstat.freeze)
  end

  def fake_source(diff:, commits: [commit_record(sha: "c1", paths: ["one.rb"])],
                  base_ref: "b" * 40, head_ref: "h" * 40)
    instance_double(Lain::Review::Source::LocalBranch,
                    diff: diff.b, commits: commits.freeze, base_ref:, head_ref:)
  end

  def changeset_over(diff, **) = described_class.new(source: fake_source(diff:, **))

  describe "the parse, against a hand-written diff" do
    subject(:changeset) { changeset_over(one_file_diff) }

    it "names one file, one hunk" do
      expect(changeset.files.map(&:path)).to eq(["one.rb"])
      expect(changeset.hunks.map(&:path)).to eq(["one.rb"])
    end

    it "reads the hunk's two spans off its header" do
      hunk = changeset.hunks.first
      expect([hunk.old_start, hunk.old_count, hunk.new_start, hunk.new_count]).to eq([1, 3, 1, 4])
    end

    it "carries the hunk heading, which Hunk excludes from both of its keys" do
      expect(changeset.hunks.first.heading).to eq("def method")
    end

    it "keeps every body line's origin marker, which is what the content key hashes" do
      expect(changeset.hunks.first.lines).to eq([" alpha", "+inserted", " beta", "-gamma", "+GAMMA"])
    end

    # The escalation trigger, in miniature. `-gamma` is the THIRD old line, not
    # the fourth: `+inserted` advances only the new counter.
    it "does not advance the old counter across an addition" do
      old = changeset.each_anchor(side: :old).to_a
      expect(old.map { |anchor| [anchor.line, anchor.anchor_text] })
        .to eq([[1, "alpha"], [2, "beta"], [3, "gamma"]])
    end

    it "advances the new counter across an addition and a context line alike" do
      new = changeset.each_anchor.to_a
      expect(new.map { |anchor| [anchor.line, anchor.anchor_text] })
        .to eq([[1, "alpha"], [2, "inserted"], [3, "beta"], [4, "GAMMA"]])
    end

    it "anchors a context line on BOTH sides, one walk each, never as a third side" do
      expect(changeset.each_anchor(side: :new).map(&:side).uniq).to eq([:new])
      expect(changeset.each_anchor(side: :old).map(&:side).uniq).to eq([:old])
    end

    # A new-side anchor claims the head; an old-side one claims the merge base.
    # Getting this backwards resolves every deletion against a revision that
    # never held it.
    it "stamps each side's anchors with the revision that side belongs to" do
      expect(changeset.each_anchor.map(&:revision).uniq).to eq(["h" * 40])
      expect(changeset.each_anchor(side: :old).map(&:revision).uniq).to eq(["b" * 40])
    end

    it "refuses a side that is not one of Review::SIDES" do
      expect { changeset.each_anchor(side: :both) }.to raise_error(Lain::Review::Anchor::UnknownSide)
    end
  end

  describe "the line walk is lazy" do
    # An Enumerator that has already run the walk is not lazy, however it is
    # spelled. Reading the SOURCE is the observable: no diff, no parse.
    it "returns an Enumerator without reading the source's diff" do
      source = fake_source(diff: one_file_diff)
      enumerator = described_class.new(source:).each_anchor

      expect(enumerator).to be_a(Enumerator)
      expect(source).not_to have_received(:diff)
    end

    it "reads the diff only once the enumerator is drawn from" do
      source = fake_source(diff: one_file_diff)
      enumerator = described_class.new(source:).each_anchor

      expect(enumerator.first.anchor_text).to eq("alpha")
      expect(source).to have_received(:diff)
    end

    it "does not materialize the walk: taking one line does not build the rest" do
      changeset = changeset_over(one_file_diff)
      expect(changeset.each_anchor.lazy.map(&:line).first(2)).to eq([1, 2])
    end

    it "reads neither the diff nor the walk when merely constructed" do
      source = fake_source(diff: one_file_diff)
      described_class.new(source:)

      expect(source).not_to have_received(:diff)
      expect(source).not_to have_received(:commits)
    end

    # `#each_anchor` was lazy and `#each` was not, which is worse than either
    # being consistent: a caller holding an `Enumerable` cannot tell which of the
    # two it has, and the eager one parses a work-scale diff to hand back an
    # object nobody has asked a question of yet.
    it "returns an Enumerator from #each without reading the source's diff" do
      source = fake_source(diff: one_file_diff)
      enumerator = described_class.new(source:).each

      expect(enumerator).to be_a(Enumerator)
      expect(source).not_to have_received(:diff)
    end

    # An Enumerator with no size block answers `nil`, which a reader takes for
    # "empty". A size block is called only WHEN asked, so answering honestly
    # costs nothing until somebody wants the number.
    it "answers a real size when asked, and still reads nothing until then" do
      source = fake_source(diff: one_file_diff)
      enumerator = described_class.new(source:).each_anchor

      expect(source).not_to have_received(:diff)
      expect(enumerator.size).to eq(4)
      expect(source).to have_received(:diff)
    end

    it "sizes each side's walk separately, agreeing with what that walk yields" do
      changeset = changeset_over(one_file_diff)
      expect(changeset.each_anchor(side: :old).size).to eq(3)
      expect(changeset.each_anchor(side: :old).size).to eq(changeset.each_anchor(side: :old).count)
    end
  end

  # The defect was total rather than partial: the parser deliberately keeps a
  # body line's `\r` (it is content), while `Anchor#drifted?` read the document
  # with `lines(chomp: true)`, which strips `\r\n`. Every anchor into a CRLF file
  # compared `"x\r"` against `"x"` and reported drift on a line nobody touched.
  describe "a CRLF file, whose lines carry a carriage return that is content" do
    subject(:changeset) do
      changeset_over("diff --git a/crlf.txt b/crlf.txt\n--- a/crlf.txt\n+++ b/crlf.txt\n" \
                     "@@ -1,3 +1,3 @@\n x\r\n-y\r\n+CHANGED\r\n z\r\n")
    end

    it "keeps the carriage return in anchor_text, because the diff says the line has one" do
      expect(changeset.each_anchor.map(&:anchor_text)).to eq(["x\r", "CHANGED\r", "z\r"])
    end

    it "reports no drift against the document the anchors came from" do
      document = "x\r\nCHANGED\r\nz\r\n"
      expect(changeset.each_anchor.map { |anchor| anchor.drifted?(document) }).to eq([false, false, false])
    end

    it "reports no drift on the old side against the old document" do
      document = "x\r\ny\r\nz\r\n"
      expect(changeset.each_anchor(side: :old).map { |anchor| anchor.drifted?(document) })
        .to eq([false, false, false])
    end

    # The agreement is one function, not two ends that happen to chomp alike.
    it "produces anchor_text the anchor's OWN line rule reproduces from the document" do
      document = "x\r\nCHANGED\r\nz\r\n"
      lines = Lain::Review::Anchor.lines(document)
      expect(changeset.each_anchor.map { |a| lines[a.line - 1] }).to eq(changeset.each_anchor.map(&:anchor_text))
    end
  end

  describe "diff shapes the two counters have to survive" do
    # The spike guarded `+++`/`---` inside its predicates because it walked the
    # whole diff in one pass. Splitting head from body at the first `@@` makes
    # that guard WRONG: a deleted line that itself starts with `--` is content.
    it "counts a deleted line that begins with dashes as a deletion, not a file header" do
      diff = <<~DIFF
        diff --git a/dashes.rb b/dashes.rb
        --- a/dashes.rb
        +++ b/dashes.rb
        @@ -1,2 +1,2 @@
        --- was a comment
        +++ is a comment
         tail
      DIFF
      changeset = changeset_over(diff)
      expect(changeset.each_anchor(side: :old).map { |a| [a.line, a.anchor_text] })
        .to eq([[1, "-- was a comment"], [2, "tail"]])
      expect(changeset.each_anchor.map { |a| [a.line, a.anchor_text] })
        .to eq([[1, "++ is a comment"], [2, "tail"]])
    end

    it "treats the no-newline marker as neither side, so it moves no counter" do
      diff = <<~DIFF
        diff --git a/nl.rb b/nl.rb
        --- a/nl.rb
        +++ b/nl.rb
        @@ -1,2 +1,2 @@
        -one
        \\ No newline at end of file
        +one!
        \\ No newline at end of file
         two
      DIFF
      changeset = changeset_over(diff)
      expect(changeset.each_anchor.map { |a| [a.line, a.anchor_text] }).to eq([[1, "one!"], [2, "two"]])
      expect(changeset.each_anchor(side: :old).map { |a| [a.line, a.anchor_text] })
        .to eq([[1, "one"], [2, "two"]])
    end

    # A one-hunk fixture cannot tell "the first hunk" from "the last": both are
    # the same hunk, and a parser that cut the file's header at the WRONG `@@`
    # passes every example above.
    it "reads every hunk of a multi-hunk file, not only its first or its last" do
      diff = <<~DIFF
        diff --git a/two.rb b/two.rb
        --- a/two.rb
        +++ b/two.rb
        @@ -1,2 +1,2 @@
        -a
        +A
         b
        @@ -20,2 +20,2 @@ tail
        -y
        +Y
         z
      DIFF
      changeset = changeset_over(diff)
      expect(changeset.hunks.map(&:old_start)).to eq([1, 20])
      expect(changeset.each_anchor(side: :old).map { |a| [a.line, a.anchor_text] })
        .to eq([[1, "a"], [2, "b"], [20, "y"], [21, "z"]])
    end

    it "reads a hunk header with no counts as a span of one" do
      diff = <<~DIFF
        diff --git a/single.rb b/single.rb
        --- a/single.rb
        +++ b/single.rb
        @@ -7 +7 @@
        -old
        +new
      DIFF
      hunk = changeset_over(diff).hunks.first
      expect([hunk.old_start, hunk.old_count, hunk.new_start, hunk.new_count]).to eq([7, 1, 7, 1])
    end

    it "keeps a path carrying a space, which git terminates with a tab" do
      diff = "diff --git a/has space.rb b/has space.rb\n" \
             "--- a/has space.rb\t\n+++ b/has space.rb\t\n@@ -1 +1 @@\n-a\n+b\n"
      expect(changeset_over(diff).files.map(&:path)).to eq(["has space.rb"])
    end

    it "unquotes a path git had to C-quote, so the anchor names a file that opens" do
      diff = %(diff --git "a/caf\\303\\251.rb" "b/caf\\303\\251.rb"\n)
      expect(changeset_over(diff).files.map(&:path)).to eq(["café.rb"])
    end

    # An empty context line is ` ` in git's own output, but a diff that reached
    # us through a wire that trimmed trailing whitespace would stall BOTH
    # counters on it and shift every anchor below -- silently.
    it "treats a wholly empty body line as context rather than stalling both counters" do
      diff = "diff --git a/blank.rb b/blank.rb\n--- a/blank.rb\n+++ b/blank.rb\n@@ -1,3 +1,3 @@\n a\n\n-c\n+C\n"
      expect(changeset_over(diff).each_anchor(side: :old).map(&:line)).to eq([1, 2, 3])
    end
  end

  describe "a file the two counters cannot describe at all" do
    it "keeps a binary file as a file with no hunks, rather than dropping it" do
      diff = <<~DIFF
        diff --git a/blob.bin b/blob.bin
        index f971a5e..f8e616e 100644
        Binary files a/blob.bin and b/blob.bin differ
      DIFF
      file = changeset_over(diff).files.first
      expect(file).to be_binary
      expect([file.path, file.status, file.hunks]).to eq(["blob.bin", :modified, []])
    end

    it "keeps a mode-only change, which has neither hunks nor a ---/+++ pair" do
      diff = <<~DIFF
        diff --git a/mode.sh b/mode.sh
        old mode 100644
        new mode 100755
      DIFF
      file = changeset_over(diff).files.first
      expect([file.path, file.status, file.hunks, file.binary?]).to eq(["mode.sh", :modified, [], false])
    end

    it "keeps a pure rename, whose only paths are on its rename lines" do
      diff = <<~DIFF
        diff --git a/from.rb b/to.rb
        similarity index 100%
        rename from from.rb
        rename to to.rb
      DIFF
      file = changeset_over(diff).files.first
      expect([file.old_path, file.new_path, file.status]).to eq(["from.rb", "to.rb", :renamed])
    end

    # Equality both ways, not membership: a status this object can answer but the
    # vocabulary does not declare is a spelling nothing else in the review surface
    # will recognise, and a declared status nothing can answer is a set that lies
    # about its own size.
    it "answers exactly the statuses the shared vocabulary declares, no more and no fewer" do
      answered = [%w[a a], [nil, "a"], ["a", nil], %w[a b]].map do |old_path, new_path|
        described_class::ChangedFile.new(old_path:, new_path:, hunks: []).status
      end
      expect(answered.uniq).to match_array(Lain::Review::FILE_STATUSES.map(&:to_sym))
    end
  end

  describe "which path each side of a rename anchors against" do
    subject(:changeset) do
      changeset_over(<<~DIFF, commits: [commit_record(sha: "c1", paths: ["from.rb => to.rb"])])
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

    it "identifies the file by its NEW path, which is what a mark is keyed under" do
      expect(changeset.files.map(&:path)).to eq(["to.rb"])
      expect(changeset.hunks.map(&:path)).to eq(["to.rb"])
    end

    # `git show <base>:to.rb` resolves nothing -- the file did not exist under
    # that name at the base. An old-side anchor naming the new path is an anchor
    # that can never be checked for drift.
    it "names the OLD path on an old-side anchor, which is the only one the base holds" do
      expect(changeset.each_anchor(side: :old).map(&:path).uniq).to eq(["from.rb"])
      expect(changeset.each_anchor.map(&:path).uniq).to eq(["to.rb"])
    end

    it "attributes a renamed file to the commit whose numstat spells the rename" do
      expect(changeset.by_commit.map { |scope| scope.files.map(&:path) }).to eq([["to.rb"]])
    end
  end

  describe "an added and a deleted file" do
    subject(:changeset) { changeset_over(diff, commits: [commit_record(sha: "c1", paths: %w[gone.rb new.rb])]) }

    let(:diff) do
      <<~DIFF
        diff --git a/gone.rb b/gone.rb
        deleted file mode 100644
        index 1111111..0000000
        --- a/gone.rb
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -one
        -two
        diff --git a/new.rb b/new.rb
        new file mode 100644
        index 0000000..1111111
        --- /dev/null
        +++ b/new.rb
        @@ -0,0 +1,2 @@
        +alpha
        +beta
      DIFF
    end

    it "reads a deletion as having no new path and an addition as having no old one" do
      expect(changeset.files.map { |file| [file.path, file.status, file.old_path, file.new_path] })
        .to eq([["gone.rb", :deleted, "gone.rb", nil], ["new.rb", :added, nil, "new.rb"]])
    end

    it "anchors a deleted file only on the old side and an added one only on the new" do
      expect(changeset.each_anchor(side: :old).map { |a| [a.path, a.line] })
        .to eq([["gone.rb", 1], ["gone.rb", 2]])
      expect(changeset.each_anchor.map { |a| [a.path, a.line] }).to eq([["new.rb", 1], ["new.rb", 2]])
    end
  end

  # What an editor has to ask before it can DRAW a changeset: which file is this
  # row, and what did the base hold for it. Neither is answerable from the diff
  # alone -- it carries the hunks and three lines around them -- so both go
  # through the source, and getting either wrong draws a diff of the wrong bytes
  # rather than failing.
  describe "one file's old side" do
    subject(:changeset) { described_class.new(source:) }

    let(:blobs) { {} }
    let(:paths) { ["one.rb"] }
    let(:diff) { one_file_diff }
    let(:source) do
      instance_double(Lain::Review::Source::LocalBranch,
                      diff: diff.b, commits: [commit_record(sha: "c1", paths:)].freeze,
                      base_ref: "b" * 40, head_ref: "h" * 40).tap do |double|
        allow(double).to receive(:file_at) { |revision, path| blobs[[revision, path]] }
      end
    end

    it "answers the file its identifying path names" do
      expect(changeset.file("one.rb").status).to eq(:modified)
    end

    # A gesture can name a row drawn from a changeset that has since been
    # replaced, so this is an ordinary answer rather than an error -- and it must
    # not be the NEAREST file, which is what a loose scan would give.
    it "answers nothing for a path it does not carry" do
      expect(changeset.file("two.rb")).to be_nil
      expect(changeset.file("")).to be_nil
    end

    it "reads the old side at the BASE, one entry per line" do
      blobs[["b" * 40, "one.rb"]] = "alpha\nbeta\ngamma\n".b

      expect(changeset.old_side(changeset.file("one.rb"))).to eq(%w[alpha beta gamma])
    end

    # The head is the plausible wrong revision, and it is the one already on
    # screen: reading it would diff the new side against itself, so the pane
    # comes up empty and the review looks finished.
    it "does not read the head, which would diff the new side against itself" do
      changeset.old_side(changeset.file("one.rb"))

      expect(source).to have_received(:file_at).with("b" * 40, "one.rb")
      expect(source).not_to have_received(:file_at).with("h" * 40, anything)
    end

    context "with a renamed file" do
      let(:paths) { ["from.rb => to.rb"] }
      let(:diff) do
        <<~DIFF
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

      # `base:to.rb` resolves nothing -- the file did not exist under that name
      # at the base -- so a rename read by its identifying path has an empty old
      # side, which renders as "every line of this file is new".
      it "reads it at the OLD path, which is the only name the base holds" do
        blobs[["b" * 40, "from.rb"]] = "keep\nold\n".b

        expect(changeset.old_side(changeset.file("to.rb"))).to eq(%w[keep old])
      end
    end

    context "with a file the changeset adds" do
      let(:paths) { ["new.rb"] }
      let(:diff) do
        <<~DIFF
          diff --git a/new.rb b/new.rb
          new file mode 100644
          --- /dev/null
          +++ b/new.rb
          @@ -0,0 +1,2 @@
          +alpha
          +beta
        DIFF
      end

      # An EMPTY old side, and asked of nobody: the base cannot hold a file that
      # did not exist yet, so a source that answered would be answering about
      # some other revision.
      it "answers an empty old side without asking the source for one" do
        expect(changeset.old_side(changeset.file("new.rb"))).to eq([])
        expect(source).not_to have_received(:file_at)
      end
    end

    # The one case that is neither: the diff says this file has an old side and
    # the repository cannot produce it. Told apart from the empty old side above,
    # because "nothing was there" and "this repository cannot answer for its own
    # diff" need different things from whoever asked.
    it "answers nothing when the base does not carry a file the diff says it should" do
      expect(changeset.old_side(changeset.file("one.rb"))).to be_nil
    end

    # A trailing newline TERMINATES the last line; it does not begin an empty
    # one. `split("\n", -1)` alone appends a phantom entry to every well-formed
    # file, which an editor then shows as a changed line at the bottom of it.
    it "reads a trailing newline as a terminator and an empty file as no lines" do
      blobs[["b" * 40, "one.rb"]] = "alpha\n".b
      expect(changeset.old_side(changeset.file("one.rb"))).to eq(["alpha"])

      blobs[["b" * 40, "one.rb"]] = "".b
      expect(described_class.new(source:).old_side(changeset.file("one.rb"))).to eq([])
    end

    # A blank line in the middle is content and survives; only the terminator
    # goes. A per-line `chomp` would take the carriage return with it, and
    # whether a CR is shown is the display's decision -- see {Changeset#old_side}.
    it "keeps interior blank lines and a carriage return, which are both content" do
      blobs[["b" * 40, "one.rb"]] = "alpha\r\n\nbeta\r\n".b

      expect(changeset.old_side(changeset.file("one.rb"))).to eq(["alpha\r", "", "beta\r"])
    end
  end

  describe "grouping by commit" do
    subject(:changeset) { changeset_over(diff, commits:) }

    # `shared.rb` is touched by both commits. The cumulative diff shows its
    # hunks ONCE, so a grouping that hands them to every commit that touched the
    # file double-counts and the sum stops meaning anything.
    let(:commits) do
      [commit_record(sha: "c1", subject: "first", paths: %w[shared.rb only_first.rb]),
       commit_record(sha: "c2", subject: "second", paths: %w[shared.rb only_second.rb])]
    end

    let(:diff) do
      %w[only_first.rb shared.rb only_second.rb].map do |path|
        "diff --git a/#{path} b/#{path}\n--- a/#{path}\n+++ b/#{path}\n@@ -1 +1 @@\n-a\n+b\n"
      end.join
    end

    it "yields one group per commit, in walk order" do
      expect(changeset.by_commit.map(&:sha)).to eq(%w[c1 c2])
      expect(changeset.by_commit.map(&:subject)).to eq(%w[first second])
    end

    it "partitions the files, so the groups' hunks sum to the cumulative hunk count" do
      expect(changeset.by_commit.sum { |scope| scope.files.sum { |file| file.hunks.size } })
        .to eq(changeset.hunks.size)
    end

    it "gives an overlapping file to the LAST commit that touched it, never to both" do
      expect(changeset.by_commit.map { |scope| scope.files.map(&:path) })
        .to eq([["only_first.rb"], %w[shared.rb only_second.rb]])
    end

    it "carries each commit's own numstat, which is the walk's figure and not the partition's" do
      expect(changeset.by_commit.first.numstat.map(&:path)).to eq(%w[shared.rb only_first.rb])
    end

    it "refuses loudly rather than drop a file no commit's numstat accounts for" do
      orphaned = changeset_over(diff, commits: [commit_record(sha: "c1", paths: ["shared.rb"])])
      expect { orphaned.by_commit }
        .to raise_error(described_class::Unattributed, /only_first\.rb/)
    end
  end

  # The distinction T8's reconciler depends on is made STRUCTURAL here rather
  # than by naming convention: a commit scope is a different class that does not
  # answer the two messages the reconciler reads.
  describe "a commit scope cannot be mistaken for the whole changeset" do
    subject(:scope) do
      changeset_over(one_file_diff).by_commit.first
    end

    it "does not answer #hunks, so no caller can hand a filtered set to the pruner" do
      expect(scope).not_to respond_to(:hunks)
    end

    it "does not answer #base_ref, which the reconciler reads before anything else" do
      expect(scope).not_to respond_to(:base_ref)
    end

    it "still reaches its hunks the honest way, through its files" do
      expect(scope.files.flat_map(&:hunks)).to eq(changeset_over(one_file_diff).hunks)
    end
  end

  describe "the ducks two sibling cards already assume" do
    subject(:changeset) { changeset_over(one_file_diff) }

    # T8's Marks#reconcile / #states read exactly these two.
    it "answers #base_ref as a String and #hunks as a flat Enumerable of Hunk" do
      expect(changeset.base_ref).to be_a(String)
      expect(changeset.hunks).to all(be_a(Lain::Review::Hunk))
    end

    # Hunk.keys is BATCH-oriented: it cannot decide the duplicate fallback one
    # hunk at a time, and calling it per hunk hands two byte-identical hunks the
    # SAME key -- reviewed state landing on unreviewed code. A file carrying two
    # of them is the only fixture that can tell the two callings apart.
    it "answers hunks a whole file at a time, so Hunk.keys can see duplicates" do
      duplicated = changeset_over(<<~DIFF)
        diff --git a/dup.rb b/dup.rb
        --- a/dup.rb
        +++ b/dup.rb
        @@ -1 +1 @@
        -old
        +new
        @@ -10 +10 @@
        -old
        +new
      DIFF
      per_hunk = duplicated.hunks.flat_map { |hunk| Lain::Review::Hunk.keys([hunk]) }
      batched = duplicated.hunks.group_by(&:path).flat_map { |_path, hunks| Lain::Review::Hunk.keys(hunks) }
      expect(per_hunk.uniq.size).to eq(1)
      expect(batched.uniq.size).to eq(2)
    end

    # T9's Surface::Text reads #files and #by_commit.
    it "answers #files and #by_commit with entries carrying the messages the text surface reads" do
      expect(changeset.files.first).to respond_to(:path)
      expect(changeset.by_commit.first).to respond_to(:subject, :files)
    end

    # Deliberately ABSENT. `state` is the marks-derived tri-state in T9's table,
    # and a changeset cannot know it; answering the diff's own status under that
    # name would put two meanings on one message and render the wrong glyph.
    it "does not answer #state on a file, which is the marks-derived tri-state" do
      expect(changeset.files.first).not_to respond_to(:state)
      expect(changeset.files.first.status).to eq(:modified)
    end

    it "is Enumerable over its files" do
      expect(changeset).to be_a(Enumerable)
      expect(changeset.map(&:path)).to eq(changeset.files.map(&:path))
    end
  end

  describe "deep immutability" do
    subject(:changeset) { changeset_over(one_file_diff) }

    it "answers frozen, shareable value objects, so no reachable mutable state remains" do
      expect(changeset.files).to all(satisfy { |file| Ractor.shareable?(file) })
      expect(changeset.by_commit).to all(satisfy { |scope| Ractor.shareable?(scope) })
    end

    it "answers the same file objects on a second call rather than reparsing" do
      expect(changeset.files).to equal(changeset.files)
    end
  end

  # ---------------------------------------------------------------------------
  # The seam half: real git, a real worktree, a real merge base.
  # ---------------------------------------------------------------------------
  describe "against a real repository", :seam do
    subject(:changeset) { described_class.new(source:) }

    let(:source) { Lain::Review::Source::LocalBranch.new(base: "base", repo_root: @repo) }

    around do |example|
      Dir.mktmpdir("lain-changeset-repo") do |root|
        @root = File.realpath(root)
        example.run
      end
    end

    # A copy, not a rebuild. The three commits below are a constant, and building
    # them per example cost 18 git spawns each across 26 examples -- 468 of this
    # group's 559, for a repository that is byte-identical every time. A copy IS
    # the repository rather than a reconstruction of one (see {SeedRepo}), so the
    # shas are the same in every copy and the memo can hand them over.
    before do
      template = ChangesetRepo.template
      @repo = File.join(@root, "repo")
      FileUtils.cp_r(template.dir, @repo)
      @first = template.first
      @second = template.second
      @third = template.third
    end

    def long_file(changed: false) = ChangesetRepo.long_file(changed:)

    def run_git(*args)
      shell = Mixlib::ShellOut.new("git", "-C", @repo, *args,
                                   environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
      shell.run_command.error!
      shell.stdout
    end

    # BINARY writes, so a fixture means the bytes it says: `File.write` on a
    # CRLF body would still be exact here, but the intent is that nothing in
    # this fixture is at the mercy of a text-mode translation.
    def commit(message, files)
      files.each { |path, body| File.binwrite(File.join(@repo, path), body) }
      run_git("add", "-A")
      run_git("commit", "-q", "-m", message)
      run_git("rev-parse", "HEAD").strip
    end

    # `Anchor.lines`, never `readlines(chomp: true)`. The chomp form strips a
    # trailing `\r` as well as the `\n`, so it disagreed with the diff about what
    # a CRLF line IS -- and an AC helper that disagrees with the subject proves
    # the subject wrong for the helper's reason.
    def disk_document(path) = File.read(File.join(@repo, path))

    # One `git show` per PATH, not one per ANCHOR. The examples below call this
    # inside a `reject` over `each_anchor`, so a file with n anchors spawned n
    # subprocesses for a document that cannot differ between them: `base_ref` is
    # resolved once when `source` is built, and nothing here writes to the base
    # revision. Measured over this file, 637 of its 756 git spawns were this call.
    #
    # Still a fresh String per call, so a caller owns its copy exactly as it did
    # when every call ran its own subprocess.
    def base_document(path)
      base_documents[path] ||= run_git("show", "#{source.base_ref}:#{path}").force_encoding(Encoding::UTF_8)
      base_documents[path].dup
    end

    def base_documents = @base_documents ||= {}

    def disk_lines(path) = Lain::Review::Anchor.lines(disk_document(path))

    def base_lines(path) = Lain::Review::Anchor.lines(base_document(path))

    it "sees the modified files, the rename, the addition and the deletion" do
      expect(changeset.files.map { |file| [file.path, file.status] })
        .to contain_exactly(["added.rb", :added], ["counters.rb", :modified], ["crlf.txt", :modified],
                            ["gone.rb", :deleted], ["long.rb", :modified], ["shared.rb", :modified],
                            ["to.rb", :renamed])
    end

    it "reads both of a two-hunk file's hunks, at the spans git reports" do
      long = changeset.files.find { |file| file.path == "long.rb" }
      expect(long.hunks.map(&:old_start)).to eq([2, 32])
    end

    # AC 1.
    it "resolves every new-side anchor against the file on disk" do
      mismatched = changeset.each_anchor.reject do |anchor|
        disk_lines(anchor.path)[anchor.line - 1] == anchor.anchor_text
      end
      expect(changeset.each_anchor.count).to be_positive
      expect(mismatched.map(&:to_s)).to be_empty
    end

    # AC 2, and the escalation trigger: if this fails the counter is wrong, not
    # the fixture.
    it "resolves every old-side anchor against the merge base" do
      mismatched = changeset.each_anchor(side: :old).reject do |anchor|
        base_lines(anchor.path)[anchor.line - 1] == anchor.anchor_text
      end
      expect(changeset.each_anchor(side: :old).count).to be_positive
      expect(mismatched.map(&:to_s)).to be_empty
    end

    it "anchors the deleted line of counters.rb where the base actually holds it" do
      deleted = changeset.each_anchor(side: :old).select { |anchor| anchor.anchor_text == "l7" }
      expect(deleted.map(&:line)).to eq([7])
    end

    # AC 1 and AC 2 again, asked of the object that CONSUMES an anchor rather
    # than of a helper written beside it. A helper can be wrong the same way the
    # subject is; `drifted?` is what the editor and the session actually call.
    it "reports no drift for any new-side anchor against the working tree" do
      drifted = changeset.each_anchor.select { |anchor| anchor.drifted?(disk_document(anchor.path)) }
      expect(drifted.map(&:to_s)).to be_empty
    end

    it "reports no drift for any old-side anchor against the merge base" do
      drifted = changeset.each_anchor(side: :old).select { |anchor| anchor.drifted?(base_document(anchor.path)) }
      expect(drifted.map(&:to_s)).to be_empty
    end

    it "anchors the CRLF file's lines with the carriage return the file holds" do
      crlf = changeset.each_anchor.select { |anchor| anchor.path == "crlf.txt" }
      expect(crlf.map(&:anchor_text)).to eq(["x\r", "CHANGED\r", "z\r"])
    end

    # The old side WHOLE, against a real object database -- the four shapes an
    # editor drawing this changeset meets, each of which a plausible wrong
    # implementation gets wrong in its own way: the modified file (read the head
    # and the pane is empty), the rename (read the new path and the file reads as
    # wholly new), the addition (read anything and it is not the base), and the
    # deletion (whose old side is the entire file).
    it "reads each file's old side out of the base, at the name the base holds it under" do
      old = changeset.files.to_h { |file| [file.path, changeset.old_side(file)] }

      expect(old["shared.rb"]).to eq(%w[a b c])
      expect(old["to.rb"]).to eq(%w[keep old])
      expect(old["added.rb"]).to eq([])
      expect(old["gone.rb"]).to eq(%w[one two])
    end

    # The carriage return survives the round trip through git, which is what
    # makes it the DISPLAY's decision downstream rather than a byte this tier
    # already threw away.
    it "keeps the CRLF file's carriage returns in its old side" do
      expect(changeset.old_side(changeset.file("crlf.txt"))).to eq(["x\r", "y\r", "z\r"])
    end

    # AC 4.
    it "yields one group per commit whose hunks sum to the cumulative hunk count" do
      expect(changeset.by_commit.map(&:sha)).to eq([@first, @second, @third])
      expect(changeset.by_commit.sum { |scope| scope.files.sum { |file| file.hunks.size } })
        .to eq(changeset.hunks.size)
    end

    it "gives shared.rb to the second commit, which is the last one to touch it" do
      owner = changeset.by_commit.find { |scope| scope.files.any? { |file| file.path == "shared.rb" } }
      expect(owner.sha).to eq(@second)
    end

    it "reports paths as UTF-8, since an anchor is journalled as JSON" do
      expect(changeset.files.map { |file| file.path.encoding }.uniq).to eq([Encoding::UTF_8])
      expect(changeset.each_anchor.map { |anchor| anchor.path.encoding }.uniq).to eq([Encoding::UTF_8])
    end

    it "survives JSON generation, which is how an anchor reaches the Journal" do
      expect { changeset.each_anchor.each { |anchor| anchor.to_h.to_json } }.not_to raise_error
    end

    describe "a merge commit in the range" do
      before do
        run_git("checkout", "-q", "-b", "side", "base")
        commit("side one", "side_only.rb" => "side\n")
        run_git("checkout", "-q", "feature")
        run_git("merge", "-q", "--no-ff", "--no-commit", "side")
        @merge = commit("merge side into feature", "only_in_merge.rb" => "resolved by hand\n")
      end

      # A COMBINED diff (`@@@ -1,8 -1,8 +1,8 @@@`) carries two old sides, which
      # Hunk's single (old_start, old_count) cannot represent. A changeset never
      # meets one: its diff is a two-tree `git diff <base> <head>`, and git emits
      # a combined diff only for a commit-vs-its-parents view.
      it "never meets a combined diff, so no hunk has two old sides" do
        expect(source.diff).not_to include("@@@")
      end

      it "attributes the merge's hand-resolved file to the merge commit rather than dropping it" do
        owner = changeset.by_commit.find { |scope| scope.files.any? { |file| file.path == "only_in_merge.rb" } }
        expect(owner.sha).to eq(@merge)
      end

      it "still partitions every file, merge included" do
        expect(changeset.by_commit.flat_map { |scope| scope.files.map(&:path) })
          .to match_array(changeset.files.map(&:path))
      end

      it "still resolves every old-side anchor against the merge base" do
        mismatched = changeset.each_anchor(side: :old).reject do |anchor|
          base_lines(anchor.path)[anchor.line - 1] == anchor.anchor_text
        end
        expect(mismatched.map(&:to_s)).to be_empty
      end

      # PINNED, not endorsed, and the limitation is sharper than the
      # file-granularity one: `--diff-merges=first-parent` re-reports everything
      # the merge brought in, so the merge's numstat names the side branch's
      # files too and last-writer-wins hands them ALL to the merge. The commit
      # that authored `side_only.rb` shows an empty scope.
      #
      # It cannot be fixed from inside this object: telling a merge from an
      # ordinary commit needs a parent count, and `Source::Commit` carries
      # `sha`/`subject`/`body`/`numstat` and no parents. That is a port change,
      # not a grouping change, which is why this is disclosed rather than
      # patched. `#numstat` stays the commit's OWN figure, so a consumer that
      # needs "what did this commit do" has an honest answer to read.
      it "hands a merge every file it re-reports, emptying the scopes that authored them" do
        authored = changeset.by_commit.find { |scope| scope.subject == "side one" }
        merge = changeset.by_commit.find { |scope| scope.sha == @merge }

        expect(authored.files).to be_empty
        expect(authored.numstat.map(&:path)).to include("side_only.rb")
        expect(merge.files.map(&:path)).to include("side_only.rb")
      end
    end

    # BLOCKER: `core.quotePath=false` covers a non-ASCII path and nothing else.
    # A name carrying a quote or a tab is C-quoted regardless, and the numstat
    # side was not decoded -- so `ownership` held `"we\"ird.rb"`, the lookup
    # asked for `we"ird.rb`, and an ordinary file took the whole changeset down
    # with an `Unattributed` refusal. One decoder, at the edge both sides cross.
    describe "a path git C-quotes whatever core.quotePath says" do
      before { commit("tricky paths", 'we"ird.rb' => "q\n", "ta\tb.rb" => "t\n") }

      it "names the files by the name that opens them, on both sides of the join" do
        expect(changeset.files.map(&:path)).to include('we"ird.rb', "ta\tb.rb")
      end

      it "groups them by commit rather than refusing the whole changeset" do
        expect { changeset.by_commit }.not_to raise_error
        expect(changeset.by_commit.flat_map { |scope| scope.files.map(&:path) })
          .to include('we"ird.rb', "ta\tb.rb")
      end

      it "anchors into them under the real name" do
        expect(changeset.each_anchor.map(&:path)).to include('we"ird.rb', "ta\tb.rb")
      end
    end

    # `path_text` scrubs, and this is what makes the scrub do work: a filename
    # whose bytes are not valid UTF-8 is legal on this filesystem, is NOT quoted
    # by git (quotePath governs non-ASCII, not invalid), and would otherwise
    # reach an `Anchor` -- and the NDJSON Journal -- as bytes JSON cannot
    # generate. Both sides scrub identically, which is what keeps the join
    # working on a name neither side can spell.
    #
    # The cost is real, and is PINNED below rather than left to be discovered:
    # the scrubbed name is not a name that opens, so `drifted?` and T15's
    # file-opening cannot reach this one file. See `Parser#path_text` for why the
    # journal wins that fork.
    describe "a filename whose bytes are not valid UTF-8" do
      before { commit("an unspellable name", "bad\xFF.rb".b => "x\n") }

      it "reports a path that is valid UTF-8, so an anchor can be journalled" do
        expect(changeset.files.map(&:path)).to all(be_valid_encoding)
        expect { changeset.each_anchor.each { |anchor| anchor.to_h.to_json } }.not_to raise_error
      end

      it "still joins the diff to the walk, because both sides scrub the same way" do
        expect { changeset.by_commit }.not_to raise_error
        expect(changeset.by_commit.flat_map { |scope| scope.files.map(&:path) }.size)
          .to eq(changeset.files.size)
      end

      # The disclosed cost, asserted rather than described: the reported name is
      # a DIFFERENT name from the one on disk, so nothing that opens files can
      # follow it. A reader who needs `drifted?` on such a file needs the raw
      # bytes carried beside the scrubbed name, which nothing does yet.
      it "reports a name that no longer opens, which is what the journal costs" do
        unspellable = changeset.files.map(&:path).find { |path| path.start_with?("bad") }

        expect(unspellable).not_to eq("bad\xFF.rb".b)
        expect(File.exist?(File.join(@repo, unspellable))).to be(false)
        expect(File.exist?(File.join(@repo, "bad\xFF.rb".b))).to be(true)
      end
    end

    describe "a binary file and a non-ASCII path" do
      before do
        File.binwrite(File.join(@repo, "blob.bin"), "\x00\x01\x02\xff".b)
        commit("a binary and a unicode path", "café.rb" => "unicode\n")
      end

      it "keeps the binary file as a hunkless file rather than dropping it" do
        blob = changeset.files.find { |file| file.path == "blob.bin" }
        expect(blob).to be_binary
        expect(blob.hunks).to be_empty
      end

      it "reports a non-ASCII path verbatim, whatever core.quotePath is set to" do
        run_git("config", "core.quotePath", "true")
        expect(changeset.files.map(&:path)).to include("café.rb")
      end

      it "attributes both to a commit, so neither goes missing from the walk" do
        walked = changeset.by_commit.flat_map { |scope| scope.files.map(&:path) }
        expect(walked).to include("blob.bin", "café.rb")
      end
    end
  end
end
