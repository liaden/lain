# frozen_string_literal: true

# The join itself, at its own mirror path. `session_spec.rb` drives it through a
# real {Lain::Review::Session} and keeps every claim that needs one -- the
# same-object row pin, the partition-row accounting, the vocabulary refusal.
# What lives HERE is the claim a session cannot make: what the join reads, and
# what it declines to read, when it is handed a key table that names less than
# the whole changeset.
#
# Every changeset over a real diff String is a real {Lain::Review::Changeset}.
# The one double is the corpus fixture, where the ASSERTION is that a file's
# hunks are never asked for -- which no real object can report on itself.
RSpec.describe Lain::Review::Session::MarkedChangeset do
  # Two files, three hunks: enough for one file to be partially reviewed while
  # the other is untouched, which is what keeps the agreement claim below from
  # holding vacuously over a table of one repeated answer.
  def diff
    <<~DIFF
      diff --git a/a.rb b/a.rb
      index 1111111..2222222 100644
      --- a/a.rb
      +++ b/a.rb
      @@ -1,3 +1,3 @@ def alpha
       one
      -two
      +TWO
      @@ -10,3 +10,3 @@ def beta
       ten
      -eleven
      +ELEVEN
      diff --git a/b.rb b/b.rb
      index 3333333..4444444 100644
      --- a/b.rb
      +++ b/b.rb
      @@ -1,2 +1,2 @@ def gamma
       x
      -y
      +Y
    DIFF
  end

  def base_sha = -("b" * 40)

  def head_sha = -("h" * 40)

  # Wrapped in {DiffSource}, so `files` and `identity` are the production
  # composition rather than two more stubs -- the port hands the changeset model
  # values, and stubbing them here would make these examples assert about their
  # own fixture.
  def source_double
    DiffSource.over(instance_double(Lain::Review::Source::LocalBranch,
                                    diff: diff.b, commits: [].freeze,
                                    base_ref: base_sha, head_ref: head_sha))
  end

  # The flat view, so no example here depends on a commit walk it does not
  # otherwise exercise.
  def whole = Lain::Review::Partition::STRATEGIES.fetch(:cumulative)

  def marks_over(base_ref, pairs = [])
    pairs.reduce(Lain::Review::Marks.new(base_ref:)) { |set, (key, state)| set.mark(key, state) }
  end

  def marks(pairs = []) = marks_over(base_sha, pairs)

  # A corpus file as it stands the moment a survey opens: listed, sized, and
  # unread. Asking it for its hunks RAISES, which is the honest way to assert
  # that nothing chunked it -- a counting spy passes just as well against a
  # subject that walks and discards the answer.
  #
  # A REAL {LazyFile} rather than a double, because `#chunked?` is now the fact
  # every example here turns on and a stubbed one would be the fixture asserting
  # about itself.
  def unread_file(path)
    Lain::Review::LazyFile.new(old_path: nil, new_path: path, rendered_lines: 2,
                               chunker: -> { raise "#{path} was chunked to answer a question needing no hunk" })
  end

  # The same file after something has finally read it: one unit, chunked for
  # real, keyed by the same {Hunk} ladder a diff's hunks are.
  def read_file(path, units: 1)
    file = Lain::Review::LazyFile.new(old_path: nil, new_path: path, rendered_lines: 2,
                                      chunker: -> { Array.new(units) { |n| unit_hunk(path, n) } })
    file.tap(&:hunks)
  end

  # A read file that produced nothing -- a binary, a mode-only change, a file
  # whose chunker found no unit. {HUNKLESS}'s original case.
  def read_hunkless_file(path)
    Lain::Review::LazyFile.new(old_path: nil, new_path: path, rendered_lines: 0,
                               chunker: -> { [] }).tap(&:hunks)
  end

  def unit_hunk(path, ordinal)
    Lain::Review::Hunk.new(path:, old_start: 0, old_count: 0, new_start: ordinal + 1, new_count: 1,
                           lines: ["+#{path} unit #{ordinal}"])
  end

  # `#hunks` on the changeset is `files.flat_map(&:hunks)`, which is what
  # {Changeset#hunks} actually is -- so a walk over the changeset chunks the
  # files, and the raise names the file it chunked rather than reporting an
  # unstubbed message.
  def corpus_changeset(files)
    instance_double(Lain::Review::Changeset, files:, base_ref: base_sha, head_ref: head_sha,
                                             partitions: [Lain::Review::Partition.new(label: -"s", files:)])
      .tap { |changeset| allow(changeset).to receive(:hunks) { files.flat_map(&:hunks) } }
  end

  def unchunked_changeset(paths = %w[a.rb b.rb]) = corpus_changeset(paths.map { |path| unread_file(path) })

  # The table is derived from what has been READ, so it grows with the survey
  # rather than being all of it or none of it. That is the whole of what B15's
  # empty-table shortcut could not do: it skipped the derivation only while the
  # table named nothing at all.
  describe "the key table, which names only what has been read" do
    it "names no path at all while nothing has been chunked" do
      expect(described_class.keys_by_path(unchunked_changeset)).to eq({})
    end

    it "names the file something has read and not the ones it has not, reading nothing to decide" do
      changeset = corpus_changeset([unread_file("a.rb"), read_file("b.rb"), unread_file("c.rb")])

      expect(described_class.keys_by_path(changeset).keys).to eq(["b.rb"])
    end

    # A read file that produced no hunk contributes no entry, exactly as a
    # binary file in a diff does -- which is why the row derivation cannot read
    # an absent entry as "unread".
    it "names no path for a read file that chunked to nothing" do
      expect(described_class.keys_by_path(corpus_changeset([read_hunkless_file("bin.dat")]))).to eq({})
    end

    # The diff half, and the requirement that made this card safe to take: a
    # parser has already produced every file's hunks, so every path is named and
    # the table is the one it has always been.
    it "names every path of a diff, whose files are read the moment they are parsed" do
      changeset = Lain::Review::Changeset.new(source: source_double)

      expect(described_class.keys_by_path(changeset).keys).to eq(%w[a.rb b.rb])
    end
  end

  describe "a state derived for a file nobody has chunked" do
    # The whole of this card's mechanism: {HUNKLESS} already reads a file with
    # no hunks as unreviewed, and a file nobody has been ASKED about is the same
    # honest answer for the same reason -- no hunk of it is marked, because
    # there is no hunk of it here yet.
    it "derives every file's state without reading a hunk, when the key table names no path" do
      marked = described_class.of(unchunked_changeset, marks, keys_by_path: {}, strategy: whole)

      expect(marked.files.map(&:state)).to eq([described_class::HUNKLESS, described_class::HUNKLESS])
    end

    # The pin that keeps the one above from passing by accident: an
    # `instance_double` stubbed with only the base check refuses every other
    # message, so a derivation that still asked {Marks} anything -- `#states`,
    # which walks `changeset.hunks`, or `#state_of` for a file with no keys --
    # would be red here whatever the fixture's files did.
    it "asks Marks for no derivation at all, so nothing can walk the corpus behind it" do
      mute = instance_double(Lain::Review::Marks, assert_same_base!: nil)

      expect { described_class.of(unchunked_changeset, mute, keys_by_path: {}, strategy: whole) }
        .not_to raise_error
    end

    it "hands those rows no hunk keys, so no gesture can name a unit nobody has chunked" do
      marked = described_class.of(unchunked_changeset, marks, keys_by_path: {}, strategy: whole)

      expect(marked.files.map(&:hunk_keys)).to all(be_empty)
    end

    # Laziness lives in the DERIVATION, not in row identity: an unchunked
    # corpus's rows are shared between the partition and the whole exactly as a
    # diff's are, so one mark still redraws both.
    it "still carries the same row object under a partition as at whole scope" do
      marked = described_class.of(unchunked_changeset, marks, keys_by_path: {}, strategy: whole)

      expect(marked.partitions.first.files.first).to be(marked.files.first)
    end

    it "still forwards the diff's own facts, which are known without any hunk" do
      row = described_class.of(unchunked_changeset, marks, keys_by_path: {}, strategy: whole).files.first

      expect([row.path, row.status, row.binary?]).to eq(["a.rb", :added, false])
    end
  end

  # Where the all-or-nothing pin used to live. The table WAS all-or-nothing: one
  # named path took the derivation and {Marks#states} then walked all fifty --
  # measured, 1 key chunked 50 of 50 files. The derivation is per path now, so
  # the file the table does not name is the file that is not read.
  describe "a partial table, which used to cost the whole corpus" do
    it "derives the read file from its marks and leaves the unread ones untouched" do
      changeset = corpus_changeset([read_file("a.rb"), unread_file("b.rb"), unread_file("c.rb")])
      keys = described_class.keys_by_path(changeset)
      set = marks(keys.fetch("a.rb").map { |key| [key, "reviewed"] })

      rows = described_class.of(changeset, set, keys_by_path: keys, strategy: whole).files

      expect(rows.map { |row| [row.path, row.state] })
        .to eq([["a.rb", "reviewed"], ["b.rb", "unreviewed"], ["c.rb", "unreviewed"]])
    end

    # The partial half of the tri-state, so the example above is not passing on
    # a derivation that answers `reviewed` for anything the table names.
    it "reads a partially marked file as partial, still without touching its neighbours" do
      changeset = corpus_changeset([read_file("a.rb", units: 2), unread_file("b.rb")])
      keys = described_class.keys_by_path(changeset)
      set = marks([[keys.fetch("a.rb").first, "reviewed"]])

      rows = described_class.of(changeset, set, keys_by_path: keys, strategy: whole).files

      expect(rows.map { |row| [row.path, row.state] }).to eq([["a.rb", "partial"], ["b.rb", "unreviewed"]])
    end

    it "hands the read file its keys and the unread ones none" do
      changeset = corpus_changeset([read_file("a.rb"), unread_file("b.rb")])

      rows = described_class.of(changeset, marks, keys_by_path: described_class.keys_by_path(changeset),
                                                  strategy: whole).files

      expect(rows.map { |row| row.hunk_keys.size }).to eq([1, 0])
    end

    # A read file that produced nothing is absent from the table for a reason
    # the FILE knows and the table cannot express, so the refusal below must not
    # catch it.
    it "still reads a read file that chunked to nothing as unreviewed" do
      changeset = corpus_changeset([read_hunkless_file("bin.dat")])

      row = described_class.of(changeset, marks, keys_by_path: {}, strategy: whole).files.first

      expect(row.state).to eq(described_class::HUNKLESS)
    end

    # THE hazard this card had to not reintroduce. `.of(cs, fully_marked, {})`
    # rendered every file of a fully-reviewed diff as `unreviewed`, silently,
    # because an absent path and an unread one asked the same question of the
    # same table. They are different facts now -- the FILE says whether it was
    # read -- and a read file with hunks that the table does not name is a table
    # disagreeing with the changeset, which is refused rather than drawn.
    it "refuses a table that omits a file something has read, rather than calling it unreviewed" do
      changeset = Lain::Review::Changeset.new(source: source_double)
      set = marks(described_class.keys_by_path(changeset).values.flatten.map { |key| [key, "reviewed"] })

      expect { described_class.of(changeset, set, keys_by_path: {}, strategy: whole) }
        .to raise_error(KeyError, /a\.rb/)
    end

    # The base check survives the move off `Marks#states`, which used to make
    # it on the derivation's way past. `.of` holds the pair, so `.of` asks.
    it "still refuses a mark set recorded against another base" do
      changeset = corpus_changeset([unread_file("a.rb")])

      expect { described_class.of(changeset, marks_over("z" * 40), keys_by_path: {}, strategy: whole) }
        .to raise_error(Lain::Review::Marks::BaseMismatch)
    end
  end

  describe "a diff review, which must see nothing change" do
    let(:changeset) { Lain::Review::Changeset.new(source: source_double) }

    # One of a.rb's two hunks, so a.rb is partial and b.rb unreviewed -- three
    # of the four states are exercised and the comparison below cannot pass by
    # both sides answering the same thing everywhere.
    def half_marked(changeset)
      marks([[described_class.keys_by_path(changeset).fetch("a.rb").first, "reviewed"]])
    end

    it "answers exactly the states Marks derives, in FILE_STATES' own spelling" do
      set = half_marked(changeset)

      rows = described_class.of(changeset, set, strategy: whole).files

      expect(rows.to_h { |row| [row.path, row.state] })
        .to eq(set.states(changeset).transform_values { |state| described_class::STATES.fetch(state) })
    end

    it "and those states are not all one answer, or the agreement above would hold over nothing" do
      rows = described_class.of(changeset, half_marked(changeset), strategy: whole).files

      expect(rows.map { |row| [row.path, row.state] }).to eq([["a.rb", "partial"], ["b.rb", "unreviewed"]])
    end

    it "keeps deriving from Marks whenever the table names a path, marked or not" do
      rows = described_class.of(changeset, marks, strategy: whole).files

      expect(rows.map(&:state)).to eq(%w[unreviewed unreviewed])
    end
  end
end
