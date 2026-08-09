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

  def source_double
    instance_double(Lain::Review::Source::LocalBranch,
                    diff: diff.b, commits: [].freeze, base_ref: base_sha, head_ref: head_sha)
  end

  # The flat view, so no example here depends on a commit walk it does not
  # otherwise exercise.
  def whole = Lain::Review::Partition::STRATEGIES.fetch(:cumulative)

  def marks(pairs = []) = pairs.reduce(Lain::Review::Marks.new(base_ref: base_sha)) { |set, (k, s)| set.mark(k, s) }

  # A corpus as it stands the moment a survey opens: the paths and the statuses
  # are known from the walk, and not one file has been chunked. Asking such a
  # file for its hunks RAISES, which is the honest way to assert that nothing
  # chunked it -- a counting spy passes just as well against a subject that
  # walks and discards the answer.
  #
  # `#hunks` on the changeset is `files.flat_map(&:hunks)`, which is what
  # {Changeset#hunks} actually is (`changeset.rb:132`) -- so a walk over the
  # changeset chunks the files, and the raise names the file it chunked rather
  # than reporting an unstubbed message.
  def unchunked_changeset(paths = %w[a.rb b.rb])
    files = paths.map { |path| unchunked_file(path) }
    instance_double(Lain::Review::Changeset, files:, base_ref: base_sha, head_ref: head_sha,
                                             partitions: [Lain::Review::Partition.new(label: -"s", files:)])
      .tap { |changeset| allow(changeset).to receive(:hunks) { files.flat_map(&:hunks) } }
  end

  def unchunked_file(path)
    instance_double(Lain::Review::LazyFile, path:, old_path: path, new_path: path,
                                            status: :modified, binary?: false).tap do |file|
      allow(file).to receive(:hunks).and_raise("#{path} was chunked to answer a question that needed no hunk")
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
    # `instance_double` with no stubs refuses EVERY message, and `Marks#states`
    # walks `changeset.hunks` -- so a derivation that still asked for it would
    # be red here whatever the fixture's files did.
    it "asks Marks for no derivation at all, so nothing can walk the corpus behind it" do
      mute = instance_double(Lain::Review::Marks)

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

    # The shortcut's LIMIT, pinned where a reader will meet it. It is
    # all-or-nothing: one named path is enough to take the derivation, and
    # `Marks#states` then walks the whole changeset -- so every file here is
    # chunked and the raise says so. Written because the comment on `.of` first
    # claimed the opposite, and nothing in this file was able to contradict it.
    it "takes the derivation, and so reads every file, as soon as the table names a single path" do
      one_path = { "a.rb" => ["hunk-content-v1:abc"] }

      expect { described_class.of(unchunked_changeset, marks, keys_by_path: one_path, strategy: whole) }
        .to raise_error(/was chunked/)
    end

    it "still forwards the diff's own facts, which are known without any hunk" do
      row = described_class.of(unchunked_changeset, marks, keys_by_path: {}, strategy: whole).files.first

      expect([row.path, row.status, row.binary?]).to eq(["a.rb", :modified, false])
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
