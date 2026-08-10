# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

# A chunker dispatch that records every file it actually chunks, and chunks it
# for real. `corpus_spec.rb`'s `CorpusChunkCounter` under its own name, because
# both files load into one worker and a second definition of that constant would
# quietly be whichever file loaded last.
#
# It is here because every claim below about a widening is a claim about work
# that happened or did not: "the surviving mark is the WIDER corpus's own key"
# is only worth anything if that corpus really chunked the file the mark names,
# and a subject-set flag would be the subject testifying about itself. The count
# is taken at the CHUNKER's `#call` rather than at the dispatch's, so resolving a
# chunker eagerly and chunking lazily still counts zero.
class WideningChunkCounter
  Counted = Data.define(:chunker, :log) do
    def call(path:, source:)
      log << path
      chunker.call(path:, source:)
    end
  end

  # @return [Array<String>] one entry per chunking, in the order they happened
  attr_reader :chunked

  def initialize = @chunked = []

  def call(path) = Counted.new(chunker: Lain::Survey::Chunker.for(path), log: @chunked)

  def counted(path) = @chunked.count(path)
end

# A survey ACCRETES: the human points at a subtree, then adds the file they are
# reading to the round already open. This is the aggregate half of that -- the
# widening message, the record it journals, and the replay that rebuilds a round
# spanning what was added.
#
# Every fixture is a real corpus under `Dir.mktmpdir` over the real chunker
# dispatch, and the classifier's home is INJECTED at a path nothing here creates,
# so no example can reach the developer's real `$HOME`. Nothing about a widening
# is provable against a doubled source: the whole claim is that two independently
# derived corpora agree on the keys of the files they share, which a stub would
# decide by construction.
RSpec.describe Lain::Review::Session, "widening a round already open" do
  let(:root) { @root }
  let(:home) { "/home/surveyor" }
  let(:sensitivity) { Lain::Sensitivity.new(home:, cwd: root) }
  let(:ledger) { Lain::Sensitivity::Ledger.new }
  let(:projection) { Lain::Survey::Projection.new(ledger:) }
  let(:io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io:) }
  let(:surface) { Lain::Review::Surface::Null.new }

  around do |example|
    Dir.mktmpdir("lain-widen") { |made| @root = File.realpath(made) and example.run }
  end

  def entries = io.string.lines

  def write(relative, body)
    File.join(root, relative).tap do |path|
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, body)
    end
  end

  def document(*lines) = "#{lines.join("\n")}\n"

  # One heading and a body over the granularity floor, so the file chunks to
  # exactly one unit and an example counting keys is counting files.
  def note(name, body: "one")
    document("## #{name}", "", "#{name} body #{body}.", "#{name} body two.", "#{name} body three.")
  end

  # A fresh walk every time, which is what a widening actually is: the tree is
  # re-listed, so a file written since the round opened is simply there.
  def corpus(counter)
    Lain::Review::Source::Corpus.new(walk: Lain::Survey::Walk.new(root:, sensitivity:),
                                     projection:, chunker: counter)
  end

  def changeset(counter = WideningChunkCounter.new) = Lain::Review::Changeset.new(source: corpus(counter))

  def open_round(over) = described_class.open(changeset: over, journal:, source: "corpus", surface:)

  def file_in(over, path) = over.files.find { |file| file.path == path }

  # Derived HERE, from the changeset handed in, by the same batch rule Marks
  # itself applies -- a helper that asked the session for its own keys could not
  # catch the session keying them differently, which is what would silently
  # unmark everything.
  def keys_for(over, path) = Lain::Review::Hunk.keys(file_in(over, path).hunks)

  def paths_of(over) = over.files.map(&:path)

  # At the scope a survey is actually drawn at: {Partition::ByCommit} declines a
  # corpus through `#supports?`, so `#marked`'s commit-walk default is a
  # grouping this source cannot answer.
  def whole = Lain::Review::Partition::STRATEGIES.fetch(Lain::Review::Partition::DEFAULT_SCOPE.to_sym)

  def rows(session) = session.marked(strategy: whole).files

  def state_of(session, path)
    rows(session).find { |row| row.path == path }.state
  end

  # A survey marks through hunk keys, and a key exists only once its file has
  # been chunked -- which is what a human opening the file in the cockpit does.
  # So the fixture opens the file first and then marks it, in that order,
  # because the session refuses a key its key table does not name.
  def mark_reviewed(session, over, path)
    keys_for(over, path).each { |key| session.mark(key, "reviewed") }
  end

  def two_files
    write("a.md", note("Alpha"))
    write("b.md", note("Bravo"))
  end

  describe "the widening itself" do
    # Counted through B8's injected `chunker:` seam, at the chunker's own `#call`,
    # because every claim here is about work: that building the wider corpus
    # chunks NOTHING (the laziness survives the widening path), that the widening
    # then walks it whole (the reconcile, and the eagerness that is ticketed
    # rather than a defect of this method), and that the mark which survived
    # matches a key that walk DERIVED rather than one carried over.
    it "keeps every mark, and the new file's units arrive unreviewed" do
      two_files
      opened = changeset
      session = open_round(opened)
      mark_reviewed(session, opened, "a.md")
      write("c.md", note("Charlie"))
      wider = changeset(counter = WideningChunkCounter.new)
      expect(counter.chunked).to be_empty

      session.widen(wider)
      walked = counter.chunked.dup

      expect(walked).to match_array(%w[a.md b.md c.md])
      expect(session.marks.to_h.keys).to match_array(keys_for(wider, "a.md")).and(be_any)
      expect(counter.chunked).to eq(walked)
      expect(state_of(session, "a.md")).to eq("reviewed")
      expect(state_of(session, "c.md")).to eq("unreviewed")
    end

    # The other half of the same measurement, and the one that says the eagerness
    # belongs to {Marks#reconcile} rather than to the widening: a round with
    # nothing marked has nothing that could be stale, and pays nothing.
    it "chunks nothing when there is no mark that could have gone stale" do
      two_files
      session = open_round(changeset)
      write("c.md", note("Charlie"))
      wider = changeset(counter = WideningChunkCounter.new)

      session.widen(wider)

      expect(counter.chunked).to be_empty
    end

    it "spans the wider corpus, and says so through the changeset it now holds" do
      two_files
      session = open_round(changeset)
      write("c.md", note("Charlie"))

      session.widen(changeset)

      expect(paths_of(session.changeset)).to eq(%w[a.md b.md c.md])
    end

    it "journals what joined and the address the corpus now has" do
      two_files
      session = open_round(changeset)
      write("c.md", note("Charlie"))
      wider = changeset

      session.widen(wider)

      extended = Lain::Journal.records(entries, type: Lain::Review::CorpusExtended::JOURNAL_TYPE).to_a
      expect(extended.size).to eq(1)
      expect(extended.first["paths"]).to eq(["c.md"])
      expect(extended.first["digest"]).to eq(described_class.digest(wider))
    end

    # The invariant that makes the mutation safe. Marks are pruned against
    # whatever the changeset now produces, so a "widening" that dropped a path
    # would silently discard its marks -- the failure a rebuild through
    # `.from_journal` could not have, and the one this refusal buys back.
    # It ADDS one too, which is what makes the refusal the drop's own rather
    # than the empty-addition rule reached by another road: a swap -- one file
    # gone, one arrived -- is exactly the shape that would look like a widening
    # and silently discard the marks on what it lost.
    it "refuses a changeset that drops a path this round already spans" do
      two_files
      session = open_round(changeset)
      File.delete(File.join(root, "b.md"))
      write("c.md", note("Charlie"))

      expect { session.widen(changeset) }
        .to raise_error(described_class::NotWidened, /drops \["b\.md"\]/)
    end

    it "refuses a changeset that adds nothing, rather than journalling a widening that widened nothing" do
      two_files
      session = open_round(changeset)

      expect { session.widen(changeset) }
        .to raise_error(described_class::NotWidened, /adds no path/)
    end

    it "leaves nothing on record when it refuses" do
      two_files
      session = open_round(changeset)
      before = entries.size

      expect { session.widen(changeset) }.to raise_error(described_class::NotWidened)
      expect(entries.size).to eq(before)
    end

    # The hole the panel found, and the ordinary path a survey takes: approve,
    # keep reading, add a file. A widened round would report the verdict it was
    # given while holding a file nobody has looked at, {Verdict::Policy} would
    # never be asked again, and {AlreadySettled} forecloses correcting it -- so
    # the widening is refused instead, which is the one answer that leaves the
    # human somewhere to go (open a fresh survey).
    it "refuses to widen a round that has already been judged" do
      two_files
      opened = changeset
      session = open_round(opened)
      %w[a.md b.md].each { |path| mark_reviewed(session, opened, path) }
      session.submit("approve")
      write("c.md", note("Charlie"))

      expect { session.widen(changeset) }
        .to raise_error(described_class::AlreadySettled, /approve/)
    end

    it "leaves the judged round exactly as it stood, on record and in hand" do
      two_files
      opened = changeset
      session = open_round(opened)
      %w[a.md b.md].each { |path| mark_reviewed(session, opened, path) }
      session.submit("approve")
      write("c.md", note("Charlie"))

      expect { session.widen(changeset) }.to raise_error(described_class::AlreadySettled)
      expect(entries.grep(/corpus_extended/)).to be_empty
      expect(paths_of(session.changeset)).to eq(%w[a.md b.md])
      expect(session.digest).to eq(session.judgement.changeset_digest)
    end

    # Marks are pinned to the base they were recorded against, and a widening is
    # a reconcile -- so a "wider" changeset from another base is refused by the
    # mark set itself, ahead of any key being consulted, and before anything is
    # journaled.
    it "refuses a changeset recorded against another base" do
      two_files
      session = open_round(changeset)

      expect { session.widen(Lain::Review::Changeset.new(source: other_base)) }
        .to raise_error(Lain::Review::Marks::BaseMismatch)
      expect(entries.grep(/corpus_extended/)).to be_empty
    end
  end

  describe "the derived answers a widening invalidates" do
    it "moves the digest and the key table it had already been asked for" do
      two_files
      opened = changeset
      session = open_round(opened)
      mark_reviewed(session, opened, "a.md")
      narrow_digest = session.digest
      narrow_rows = rows(session).map(&:path)
      write("c.md", note("Charlie"))
      wider = changeset

      session.widen(wider)

      expect(narrow_rows).to eq(%w[a.md b.md])
      expect(session.digest).to eq(described_class.digest(wider))
      expect(session.digest).not_to eq(narrow_digest)
      expect(rows(session).map(&:path)).to eq(%w[a.md b.md c.md])
    end
  end

  describe "telling a widening apart from the ground shifting underneath" do
    it "does not report itself regenerated after a deliberate widening" do
      two_files
      session = open_round(changeset)
      write("c.md", note("Charlie"))

      session.widen(changeset)

      expect(session).not_to be_regenerated
    end

    it "reports regenerated when a file already in the widened survey is edited outside it" do
      two_files
      session = open_round(changeset)
      write("c.md", note("Charlie"))
      session.widen(changeset)
      write("a.md", note("Alpha", body: "rewritten"))

      rebuilt = described_class.from_journal(entries, changeset:, journal:, surface:)

      expect(rebuilt).to be_regenerated
    end

    it "reports regenerated for a resume that does not span what the widening recorded" do
      two_files
      session = open_round(changeset)
      write("c.md", note("Charlie"))
      session.widen(changeset)
      File.delete(File.join(root, "c.md"))

      rebuilt = described_class.from_journal(entries, changeset:, journal:, surface:)

      expect(rebuilt).to be_regenerated
    end
  end

  describe "rebuilding a widened round from its journal" do
    it "spans the wider path set and both marks stand" do
      two_files
      opened = changeset
      session = open_round(opened)
      mark_reviewed(session, opened, "a.md")
      mark_reviewed(session, opened, "b.md")
      write("c.md", note("Charlie"))
      session.widen(changeset)

      wider = changeset(counter = WideningChunkCounter.new)
      rebuilt = described_class.from_journal(entries, changeset: wider, journal:, surface:)

      expect(paths_of(rebuilt.changeset)).to eq(%w[a.md b.md c.md])
      expect(rebuilt.marks.to_h.keys)
        .to match_array(keys_for(wider, "a.md") + keys_for(wider, "b.md"))
      expect(counter.counted("a.md")).to eq(1)
      expect(rebuilt).not_to be_regenerated
    end

    # A resume has to be able to rebuild the WIDER corpus, and the only thing
    # that can tell it which paths joined is the record. `Marks` cannot: a mark
    # carries a hunk key and nothing else, and a key is a digest no path reads
    # back out of.
    it "names every path that joined, so a resume can rebuild what to walk" do
      two_files
      session = open_round(changeset)
      write("c.md", note("Charlie"))
      session.widen(changeset)
      write("d.md", note("Delta"))
      session.widen(changeset)

      expect(Lain::Review::Session::Replay.new(entries).paths).to eq(%w[c.md d.md])
    end

    # The wire boundary, driven as a wire. {Replay#extension} reads `paths`
    # straight off JSON, so a line carrying a null replays into a nil path a
    # resume would then walk -- and this fold's own doctrine is that a record
    # which ARRIVES malformed aborts the rebuild rather than being skipped.
    it "aborts the rebuild on a widening whose path list carries a blank" do
      two_files
      session = open_round(changeset)
      write("c.md", note("Charlie"))
      session.widen(changeset)
      doctored = entries.map { |line| line.sub('"paths":["c.md"]', '"paths":[null,"c.md"]') }

      expect { Lain::Review::Session::Replay.new(doctored) }
        .to raise_error(ArgumentError, /paths/)
    end

    # The round is POSITIONAL and a widening changes nothing about that: a new
    # round opened over the same tree inherits neither the marks nor the
    # widenings of the one before it.
    it "reads no widening from a round that ended before it" do
      two_files
      session = open_round(changeset)
      write("c.md", note("Charlie"))
      session.widen(changeset)
      open_round(changeset)

      replay = Lain::Review::Session::Replay.new(entries)

      expect(replay.paths).to be_empty
      expect(replay.marks("x").to_h).to be_empty
    end
  end

  # A diff source spanning BOTH files the round already has and one more, so it
  # is genuinely wider by paths and the only thing left to refuse it is the base.
  # Built through DiffSource for the production composition rather than a stub
  # whose identity would be the fixture's own.
  def other_base
    DiffSource.over(instance_double(Lain::Review::Source::LocalBranch,
                                    diff: diff.b, commits: [].freeze,
                                    base_ref: "b" * 40, head_ref: "h" * 40))
  end

  def diff = %w[a.md b.md c.md].map { |path| one_file_diff(path) }.join

  def one_file_diff(path)
    <<~DIFF
      diff --git a/#{path} b/#{path}
      index 1111111..2222222 100644
      --- a/#{path}
      +++ b/#{path}
      @@ -1,3 +1,3 @@ heading
       one
      -two
      +TWO
    DIFF
  end
end
