# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

# A chunker dispatch that records every file it actually chunks, and chunks it
# for real.
#
# `Source::Corpus`'s `chunker:` seam, ridden by a counter rather than replaced
# by a fake: the real dispatch resolves the real chunker and the real chunker
# runs, so "this survey chunked nothing" is a measurement taken through the
# production stack instead of a flag the subject sets about itself.
#
# The count is taken at the CHUNKER's `#call`, never at the dispatch's, because
# those are two different events: resolving a chunker for a path reads an
# extension, and chunking parses a file. A corpus that resolved eagerly and
# chunked lazily is still lazy, and counting at the dispatch would call it
# eager.
#
# `corpus_spec.rb` carries the same object for the single-subject pins. It is
# duplicated rather than shared through `spec/support/`, which `spec_helper`
# globs into every worker of every run -- two files needing one helper is not
# yet a reason to load it into all of them.
class SurveySessionChunkCounter
  Counted = Data.define(:chunker, :log) do
    def call(path:, source:)
      log << path
      chunker.call(path:, source:)
    end
  end

  # @return [Array<String>] one entry per chunking, in the order they happened
  attr_reader :chunked

  # @param chunker [#call] resolves a path to the chunker it gets; the real
  #   dispatch by default, so the counter rides the production stack
  def initialize(chunker: Lain::Survey::Chunker.method(:for))
    @chunker = chunker
    @chunked = []
  end

  def call(path) = Counted.new(chunker: @chunker.call(path), log: @chunked)

  def counted(path) = @chunked.count(path)
end

# The directories these examples survey, built ONCE per process.
#
# `SeedRepo`'s shape without the copy: a survey never writes into the tree it
# reads, and nothing below a `Corpus` can, so one tree serves every example and
# a copy would protect nothing. Fifty files written per example is fifty
# `write` syscalls of setup against a file whose whole subject is how little
# work a presentation does.
#
# Each tree carries a guard on the way out, `DivergedRepo`'s rule: the pins
# below need a file that chunks to more than one unit, and a template that
# quietly stopped producing one would delete the distinction between `partial`
# and `reviewed` while staying green.
module SurveyTree
  # `Chunker::Granularity`'s floor, so a section written here is a section the
  # chunker emits rather than a runt it merges backward. Read off the constant:
  # a floor that moved would otherwise silently coalesce these fixtures into
  # one unit apiece and take the tri-state pins with it.
  FLOOR = Lain::Survey::Chunker::DEFAULT_MINIMUM

  class << self
    # @param name [Symbol] one of the trees below
    # @return [String] a directory to survey, never to write into
    def at(name) = trees[name] ||= build(name)

    private

    # Process-wide, and safe without a lock for the reason `SeedRepo` is:
    # `parallel_tests` forks PROCESSES and one example runs at a time in each.
    def trees = @trees ||= {} # rubocop:disable ThreadSafety/ClassInstanceVariable

    def build(name)
      dir = Dir.mktmpdir("lain-survey-tree")
      at_exit { FileUtils.remove_entry(dir, true) }
      send(name, dir)
      dir
    end

    # One directory, two files, and the units to mark three of.
    def notebook(dir)
      write(dir, "notes/journal.md", document(prelude, *%w[Alpha Bravo Charlie Delta].map { section(_1) }))
      write(dir, "notes/agenda.md", document(prelude, section("Echo")))
      dir
    end

    # Fifty files inside every ceiling, each chunking to a prelude and two
    # sections -- more than one unit, so a single mark reads `partial` and
    # cannot be confused with a whole file falling to `reviewed`.
    def wide(dir)
      50.times do |index|
        write(dir, format("note-%<index>02d.md", index:),
              document(prelude, section("Head #{index}"), section("Tail #{index}")))
      end
      dir
    end

    # Three directories, two files each.
    def spread(dir)
      %w[alpha beta gamma].product(%w[one two]).each do |directory, leaf|
        write(dir, "#{directory}/#{leaf}.md", document(prelude, section("#{directory} #{leaf}")))
      end
      dir
    end

    def write(dir, relative, body)
      File.join(dir, relative).tap do |path|
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, body)
      end
    end

    def document(*blocks) = "#{blocks.flatten.join("\n")}\n"

    def prelude = Array.new(FLOOR) { |line| "Prelude line #{line}." }

    def section(name) = ["", "## #{name}", "", *Array.new(FLOOR) { |line| "#{name} body line #{line}." }]
  end
end

# Every prior card proves its own object. This one proves they compose: a real
# `Source::Corpus` under a real `Changeset`, opened by a real `Session`, joined
# to real `Marks` through a real `MarkedChangeset`, drawn by a real
# `Surface::Text`. No double stands between any two of them.
#
# The laziness pins are the reason it is a seam rather than four unit specs.
# "Presenting chunks nothing" is a claim about `Session#present`,
# `MarkedChangeset.of`, `Marks#reconcile`, `Bounds#check_presentation!`,
# `LazyFile#chunked?` and `Surface::Text#file_table` all declining to force the
# same thing, and any one of them forcing it makes the claim false. It is
# measured through the injected `chunker:` seam -- the counter above -- so what
# fails is the work, not an assertion about an internal.
#
# The tree is under `Dir.mktmpdir` and the classifier's home is INJECTED at a
# path nothing here creates, so no example can reach the developer's real
# `$HOME`.
RSpec.describe "a survey, from a directory to a rendering", :seam do
  let(:home) { "/home/surveyor" }
  let(:buffer) { StringIO.new }
  let(:surface) { Lain::Review::Surface::Text.new(sink: buffer) }
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:counter) { SurveySessionChunkCounter.new }

  def corpus_over(name, chunker:)
    root = SurveyTree.at(name)
    Lain::Review::Source::Corpus.new(
      walk: Lain::Survey::Walk.new(root:, sensitivity: Lain::Sensitivity.new(home:, cwd: root)),
      projection: Lain::Survey::Projection.new(ledger: Lain::Sensitivity::Ledger.new), chunker:
    )
  end

  def changeset_over(name, chunker: counter) = Lain::Review::Changeset.new(source: corpus_over(name, chunker:))

  def open_over(name, over: changeset_over(name))
    Lain::Review::Session.open(changeset: over, journal:, source: "corpus", surface:)
  end

  def entries = journal_io.string.lines

  # The sink is cleared FIRST, so what comes back is this presentation and not
  # every one before it. `StringIO#string=` rewinds, which `#truncate` alone
  # does not -- a write past a truncated length pads with NUL.
  def redrawn(session, scope:)
    buffer.string = +""
    session.present(scope:)
    buffer.string.chomp
  end

  def rows(drawn) = drawn.split("\n")

  def row_for(drawn, path) = rows(drawn).find { |row| row.end_with?(" #{path}") }

  def file_in(session, path) = session.changeset.files.find { |file| file.path == path }

  def keys_in(session, path) = Lain::Review::Hunk.keys(file_in(session, path).hunks)

  def anchor_on(session, path, line, text)
    Lain::Review::Anchor.new(path:, side: :new, line:, anchor_text: text,
                             revision: session.changeset.head_ref)
  end

  # The fixture guard: three of these pins turn on a file chunking to more than
  # one unit, and a chunker or a granularity floor that changed under them
  # would collapse `partial` into `reviewed` with nothing failing.
  it "surveys files that chunk to more than one unit" do
    session = open_over(:wide)

    expect(file_in(session, "note-00.md").hunks.size).to be > 1
    expect(file_in(open_over(:notebook), "notes/journal.md").hunks.size).to be >= 3
  end

  describe "a survey opens, marks, renders and replays" do
    it "carries the marks and the note across a replay, over a round nothing regenerated" do
      session = open_over(:notebook)
      marked = keys_in(session, "notes/journal.md").first(3)
      marked.each { |key| session.mark(key, "reviewed") }
      session.annotate(anchor_on(session, "notes/journal.md", 1, "Prelude line 0."),
                       "this section is the one to read first", kind: :note, drifted: false)

      rebuilt = Lain::Review::Session.from_journal(entries, changeset: changeset_over(:notebook),
                                                            journal:, surface:)

      expect(rebuilt.marks.to_h).to eq(marked.to_h { |key| [key, "reviewed"] })
      expect(rebuilt.annotations.map(&:text)).to eq(["this section is the one to read first"])
      expect(rebuilt).not_to be_regenerated
    end

    # The marks are not merely on the replayed session: they reach the join and
    # come out of the rendering as the tri-state a reader sees.
    it "draws the replayed marks as the file's tri-state" do
      session = open_over(:notebook)
      keys_in(session, "notes/journal.md").first(3).each { |key| session.mark(key, "reviewed") }

      rebuilt = Lain::Review::Session.from_journal(entries, changeset: changeset_over(:notebook),
                                                            journal:, surface:)

      drawn = redrawn(rebuilt, scope: :cumulative)
      expect(row_for(drawn, "notes/journal.md")).to eq("[~] notes/journal.md")
      expect(row_for(drawn, "notes/agenda.md")).to eq("[ ] notes/agenda.md")
    end
  end

  describe "presenting a survey chunks only what it must" do
    it "draws the tri-state for every file, having chunked none of them" do
      session = open_over(:wide)

      drawn = redrawn(session, scope: :cumulative)

      expect(counter.chunked).to be_empty
      expect(rows(drawn).size).to eq(50)
      expect(rows(drawn)).to all(start_with("[ ] note-"))
    end

    # The canary the zero above is worth nothing without: a counter that
    # observed nothing would report zero for a corpus chunked end to end. One
    # deliberate read has to move it, and by exactly one.
    it "counts a file the moment something reads it, so the zero above is a measurement" do
      session = open_over(:wide)
      redrawn(session, scope: :cumulative)

      file_in(session, "note-00.md").hunks

      expect(counter.chunked).to eq(["note-00.md"])
    end

    # Re-presenting is where the memo that used to live on
    # `Session#keys_by_path` did its damage: the first present was lazy and
    # every later one was not.
    it "chunks nothing on a second presentation either" do
      session = open_over(:wide)
      redrawn(session, scope: :cumulative)
      redrawn(session, scope: :by_directory)
      redrawn(session, scope: :cumulative)

      expect(counter.chunked).to be_empty
    end
  end

  describe "marking a unit chunks its file and no other" do
    it "leaves every unmarked file unread, and draws the marked one partial" do
      session = open_over(:wide)
      redrawn(session, scope: :cumulative)
      session.mark(keys_in(session, "note-07.md").first, "reviewed")

      drawn = redrawn(session, scope: :cumulative)

      expect(counter.chunked).to eq(["note-07.md"])
      expect(counter.counted("note-07.md")).to eq(1)
      expect(row_for(drawn, "note-07.md")).to eq("[~] note-07.md")
      expect(rows(drawn).count { |row| row.start_with?("[ ] ") }).to eq(49)
    end

    it "draws the file reviewed once every one of its units is marked" do
      session = open_over(:wide)
      redrawn(session, scope: :cumulative)
      keys_in(session, "note-07.md").each { |key| session.mark(key, "reviewed") }

      drawn = redrawn(session, scope: :cumulative)

      expect(counter.chunked).to eq(["note-07.md"])
      expect(row_for(drawn, "note-07.md")).to eq("[x] note-07.md")
    end
  end

  # The note rail over a real projection and the run's one ledger. The editor's
  # buffer is the file on disk, unprojected by ruling, so the text it sends is
  # the credential itself; the journal is the artifact, and it must hold only
  # what the projection shows.
  describe "a note placed on a masked line" do
    let(:api_key) { "sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE" }
    let(:ledger) { Lain::Sensitivity::Ledger.new }
    let(:pem) do
      "-----BEGIN PRIVATE KEY-----\n#{Array.new(4) { "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZn" }.join("\n")}\n" \
        "-----END PRIVATE KEY-----"
    end
    let(:session) do
      corpus = Lain::Review::Source::Corpus.new(
        walk: Lain::Survey::Walk.new(root: @root, sensitivity: Lain::Sensitivity.new(home:, cwd: @root)),
        projection: Lain::Survey::Projection.new(ledger:)
      )
      open_over(:unused, over: Lain::Review::Changeset.new(source: corpus))
    end

    around do |example|
      Dir.mktmpdir("lain-survey-masked") do |made|
        @root = File.realpath(made)
        File.binwrite(File.join(@root, "settings.env"), "# service\nREGION=eu\nAPI_KEY=#{api_key}\nDEBUG=0\n")
        File.binwrite(File.join(@root, "keyed.md"), "one\n#{pem}\nseven\neight\n")
        File.binwrite(File.join(@root, "latin.txt"), "caf\xE9 au lait\nplain\n".b)
        example.run
      end
    end

    def placed = Lain::Journal.records(entries, type: "annotation_placed").to_a

    def note(drifted: false, path: "settings.env", line: 3, anchor_text: "API_KEY=#{api_key}")
      { "path" => path, "side" => "new", "line" => line, "anchor_text" => anchor_text,
        "text" => "rotate this", "kind" => "note", "revision" => session.changeset.head_ref,
        "drifted" => drifted }
    end

    def handed_back(*notes)
      handover = Lain::Review::Handover.new(session:)
      Lain::Frontend::Neovim::ReviewWrite.notes([notes]) { |one| handover.wrote_annotation(one) }
    end

    it "journals the projected line, never the credential the buffer sent" do
      expect(handed_back(note)).to be_nil

      expect(placed.map { |record| record["anchor_text"] })
        .to eq(["API_KEY=#{format(Lain::Sensitivity::Regions::PLACEHOLDER, 1)}"])
      expect(entries.join).not_to include(api_key)
    end

    it "names the corpus's own head as the revision the evidence was read at" do
      handed_back(note)

      expect(placed.first["revision"]).to eq(session.changeset.head_ref)
    end

    it "carries the editor's drift measurement unchanged" do
      handed_back(note(drifted: true))

      expect(placed.first["drifted"]).to be(true)
    end

    # A latin-1 file's line does not decode, and a record that is not valid
    # UTF-8 cannot be journaled: the note would live in memory and be gone from
    # the record, so a resumed round would have lost it.
    it "journals a note on a line that does not decode, so a replay still holds it" do
      expect(handed_back(note(path: "latin.txt", line: 1, anchor_text: "café au lait"))).to be_nil

      replayed = Lain::Review::Session.from_journal(entries, changeset: session.changeset, journal:, surface:)
      expect([session.annotations.size, replayed.annotations.size]).to eq([1, 1])
      expect(replayed.annotations.first.anchor_text).to eq("caf\uFFFD au lait")
    end

    # A private key spans lines and the whole-file projection collapses it to
    # one placeholder, so its line numbers are not the buffer's. The note names
    # the buffer's line, and its evidence is that raw line, masked.
    it "reads each note's evidence at the buffer's own line number, below a multi-line masked region too" do
      raw = "one\n#{pem}\nseven\neight\n".lines(chomp: true)
      notes = [3, 7, 8, 9].map { |line| note(path: "keyed.md", line:, anchor_text: raw[line - 1]) }

      expect(handed_back(*notes)).to be_nil

      expect(placed.map { |record| record.values_at("line", "anchor_text") })
        .to eq([[3, format(Lain::Sensitivity::Regions::PLACEHOLDER, 1)],
                [7, format(Lain::Sensitivity::Regions::PLACEHOLDER, 1)], [8, "seven"], [9, "eight"]])
      expect(entries.join).not_to include("QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZn")
    end
  end

  describe "a survey groups by directory" do
    it "heads each directory with its own files" do
      session = open_over(:spread)

      drawn = redrawn(session, scope: :by_directory)

      expect(drawn).to eq(<<~TABLE.chomp)
        alpha
          [ ] alpha/one.md
          [ ] alpha/two.md

        beta
          [ ] beta/one.md
          [ ] beta/two.md

        gamma
          [ ] gamma/one.md
          [ ] gamma/two.md
      TABLE
    end

    it "groups without chunking anything" do
      session = open_over(:spread)

      redrawn(session, scope: :by_directory)

      expect(counter.chunked).to be_empty
    end
  end
end
