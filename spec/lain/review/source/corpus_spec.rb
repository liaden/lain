# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# A chunker dispatch that records every file it actually chunks, and chunks it
# for real.
#
# It exists because "no file was chunked" is a claim about work that did not
# happen, and a flag set by the subject would be the subject testifying about
# itself. The count is taken at the CHUNKER's own `#call` rather than at the
# dispatch's, so an implementation that resolved a chunker eagerly and chunked
# lazily still counts zero -- which is the fact the laziness pins are about.
# B10 drives the same seam through a real session.
class CorpusChunkCounter
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

# The third source: a directory of files reviewed AS THEY STAND.
#
# Every fixture is built under `Dir.mktmpdir` and the classifier's home is
# INJECTED at a path nothing here creates, so no example can reach the
# developer's real `$HOME`. The secret-shaped fixture below is literal and
# obviously fake.
RSpec.describe Lain::Review::Source::Corpus do
  subject(:corpus) { described_class.new(walk:, projection:, chunker: counter) }

  let(:root) { @root }
  let(:home) { "/home/surveyor" }
  let(:sensitivity) { Lain::Sensitivity.new(home:, cwd: root) }
  let(:walk) { Lain::Survey::Walk.new(root:, sensitivity:) }
  let(:ledger) { Lain::Sensitivity::Ledger.new }
  let(:projection) { Lain::Survey::Projection.new(ledger:) }
  let(:counter) { CorpusChunkCounter.new }

  let(:private_key) do
    "-----BEGIN OPENSSH PRIVATE KEY-----\n" \
      "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAM0ZBS0U\n" \
      "-----END OPENSSH PRIVATE KEY-----\n"
  end

  around do |example|
    Dir.mktmpdir("lain-corpus") { |made| @root = File.realpath(made) and example.run }
  end

  def write(relative, body)
    File.join(root, relative).tap do |path|
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, body)
    end
  end

  def document(*lines) = "#{lines.join("\n")}\n"

  # A prelude and five sections, every one of them at or above the granularity
  # floor so the chunking is a section per unit and nothing coalesces -- the
  # merge rule is {Chunker::Granularity}'s to pin, not this file's.
  def five_sections(bodies)
    document("Prelude line one.", "Prelude line two.", "Prelude line three.",
             "Prelude line four.", "Prelude line five.", "",
             *bodies.flat_map { |name, body| ["## #{name}", "", *body, ""] })
  end

  def sections(revised: "Charlie body two.")
    { "Alpha" => ["Alpha body one.", "Alpha body two.", "Alpha body three."],
      "Bravo" => ["Bravo body one.", "Bravo body two.", "Bravo body three."],
      "Charlie" => ["Charlie body one.", revised, "Charlie body three."],
      "Delta" => ["Delta body one.", "Delta body two.", "Delta body three."],
      "Echo" => ["Echo body one.", "Echo body two.", "Echo body three."] }
  end

  def spread(count, prefix: "note")
    count.times do |index|
      write(format("%<prefix>s-%<index>02d.md", prefix:, index:), document("## Heading #{index}", "", "Body."))
    end
  end

  def file_for(source, path) = source.files.find { |file| file.path == path }

  def keys_for(source, path) = Lain::Review::Hunk.keys(file_for(source, path).hunks)

  def changeset_for(source) = Lain::Review::Changeset.new(source:)

  def marks_over(source, paths)
    keys = paths.flat_map { |path| keys_for(source, path) }
    Lain::Review::Marks.new(base_ref: source.base_ref, marks: keys.to_h { |key| [key, "reviewed"] })
  end

  def build = build_with(projection)

  def build_with(over) = described_class.new(walk: Lain::Survey::Walk.new(root:, sensitivity:), projection: over)

  def build_with_chunker(dispatch)
    described_class.new(walk: Lain::Survey::Walk.new(root:, sensitivity:), projection:, chunker: dispatch)
  end

  # The port itself. A corpus answers the SIX universal messages and neither of
  # the two witnesses -- no `#diff`, no `#commits` -- which is exactly the split
  # `spec/support/shared_examples/review_source.rb` records.
  describe "the changeset-source port" do
    it_behaves_like "a review changeset source", source: lambda {
      write("guide.md", five_sections(sections))
      write("lib/widget.rb", document("# frozen_string_literal: true", "", "class Widget", "  def alpha",
                                      "    1", "  end", "end"))
      write("notes/log.txt", document("First run.", "", "Second run."))
      build
    }

    it "answers neither witness, so no diff-source law can be asked of it" do
      write("guide.md", five_sections(sections))

      expect(corpus).not_to respond_to(:diff)
      expect(corpus).not_to respond_to(:commits)
    end

    # `Partition::ByCommit` is the one strategy that declines a source, and this
    # is the source it declines -- refused by name at presentation rather than
    # dying on a missing message halfway through a grouping.
    it "is declined by the commit walk and accepted by every other grouping" do
      write("guide.md", five_sections(sections))
      strategies = Lain::Review::Partition::STRATEGIES.values
      accepted, declined = strategies.partition { |strategy| strategy.supports?(corpus) }

      expect(declined.map(&:name)).to eq([Lain::Review::Bounds::COMMIT_WALK])
      expect(accepted).not_to be_empty
    end
  end

  describe "#base_ref" do
    # THE incremental property. `Marks` refuses to cross a base change before it
    # consults a single key, so a base derived from anything that moves would
    # discard every mark on every re-survey.
    it "is a fixed constant, so a re-survey never crosses a base change" do
      write("guide.md", five_sections(sections))
      first = corpus.base_ref
      write("guide.md", five_sections(sections(revised: "Charlie body two, revised.")))

      expect(build.base_ref).to eq(first)
      expect(first).to eq(described_class::BASE_REF)
    end

    it "differs from the head, which moves with the tree" do
      write("guide.md", five_sections(sections))

      expect(corpus.base_ref).not_to eq(corpus.head_ref)
    end
  end

  describe "#head_ref" do
    it "moves when the tree does, since it is the corpus's own content address" do
      write("guide.md", five_sections(sections))
      before = corpus.head_ref
      write("guide.md", five_sections(sections(revised: "Charlie body two, revised.")))

      expect(build.head_ref).not_to eq(before)
    end

    it "does not move when nothing does" do
      write("guide.md", five_sections(sections))

      expect(build.head_ref).to eq(corpus.head_ref)
    end
  end

  describe "#files" do
    it "reads a folder that is no repository at all, and calls every file added" do
      write("guide.md", five_sections(sections))
      write("notes/log.txt", document("First run.", "", "Second run."))

      expect(corpus.files.map(&:path)).to eq(["guide.md", "notes/log.txt"])
      expect(corpus.files.map(&:status)).to all(eq(:added))
    end

    it "carries no old side, because there is no revision under a corpus" do
      write("guide.md", five_sections(sections))

      expect(corpus.files.map(&:old_path)).to all(be_nil)
    end

    it "answers the same file objects twice, so a row table keyed by file resolves" do
      write("guide.md", five_sections(sections))

      expect(corpus.files).to eq(corpus.files)
      expect(corpus.files.first).to eql(corpus.files.first)
    end

    # Two derivations of one corpus must produce EQUAL files -- {LazyFile}'s
    # equality runs through whatever chunks it, and `MarkedChangeset`'s row
    # table is a no-default `fetch` keyed by the file itself.
    it "compares equal across two derivations over one tree, so a fetch by file cannot miss" do
      write("guide.md", five_sections(sections))

      expect(build.files).to eq(build.files)
      expect(build.files.map(&:hash)).to eq(build.files.map(&:hash))
    end
  end

  # Joel's ruling, met at the SOURCE: a gated file enters the corpus redacted to
  # its released regions, so no unreleased byte exists above the object that
  # remembers them -- not in a unit, not in a key, not in the address.
  describe "a gated file" do
    let(:api_key) { "sk-ant-api03-QZ9vK2mR7xT4wL8nB3jH6yD1sA5fG0pE" }

    before { write(".env", "API_KEY=#{api_key}\n") }

    it "enters masked rather than whole, keeping the structure a human reviews" do
      body = file_for(corpus, ".env").hunks.flat_map(&:lines).join("\n")

      expect(corpus.files.map(&:path)).to eq([".env"])
      expect(body).to include("API_KEY=", format(Lain::Sensitivity::Regions::PLACEHOLDER, 1))
      expect(body).not_to include(api_key)
    end

    it "reads masked through #file_at too, so no renderer sees what a unit does not" do
      expect(corpus.file_at(corpus.head_ref, ".env")).not_to include(api_key)
    end

    it "addresses the PROJECTION, so a release legitimately re-opens the file" do
      masked = corpus.identity.parts
      absolute = File.join(root, ".env")
      released = Lain::Sensitivity::Ledger.new
      released.release(absolute, Lain::Sensitivity::Regions.detect(File.binread(absolute)))

      expect(masked).not_to include(a_string_including(api_key))
      expect(masked)
        .not_to eq(build_with(Lain::Survey::Projection.new(ledger: released)).identity.parts)
    end
  end

  describe "withheld paths" do
    it "keeps a denied path out of the files and readable from the report" do
      write(".ssh/id_ed25519", private_key)
      write("guide.md", five_sections(sections))

      expect(corpus.files.map(&:path)).to eq(["guide.md"])
      expect(corpus.withheld.map(&:to_s)).to contain_exactly(".ssh/id_ed25519: a protected path")
    end
  end

  # The claim the whole corpus arm exists to make: opening costs one read per
  # file and NO parse, and the parse tier is strictly on demand.
  describe "laziness" do
    it "chunks nothing when a survey is opened and addressed" do
      spread(50)

      expect(Lain::Review::Session.digest(changeset_for(corpus))).to be_a(String)
      expect(counter.chunked).to be_empty
    end

    it "chunks a file once, on first demand, and no other file at all" do
      spread(50)
      2.times { file_for(corpus, "note-07.md").hunks }

      expect(counter.chunked).to eq(["note-07.md"])
    end

    # Round identity must not depend on chunking strategy: improving a chunker
    # later must not open a new round over a tree nobody touched.
    it "addresses the same corpus identically whether or not anything was chunked" do
      spread(10)
      unchunked = described_class.new(walk:, projection:, chunker: counter).identity.digest
      chunked = described_class.new(walk:, projection:, chunker: counter)
      chunked.files.each(&:hunks)

      expect(chunked.identity.digest).to eq(unchunked)
      expect(counter.chunked.size).to eq(10)
    end
  end

  describe "#identity" do
    it "is the projection's content digests, so a release changes exactly the file it touched" do
      write("guide.md", five_sections(sections))
      write("notes/log.txt", document("First run.", "", "Second run."))
      before = corpus.identity.parts
      write("notes/log.txt", document("First run.", "", "Second run.", "", "Third run."))

      expect(build.identity.parts.take(2)).to eq(before.take(2))
      expect(build.identity.parts.drop(2)).not_to eq(before.drop(2))
    end

    it "names its own scheme, so a corpus address is not forgeable into a diff's" do
      write("guide.md", five_sections(sections))

      expect(corpus.identity.scheme).to eq(described_class::DIGEST_SCHEME)
      expect(corpus.identity.scheme).not_to eq(Lain::Review::Source::Diffed::DIGEST_SCHEME)
    end
  end

  # The size {Bounds} decides a ceiling from, and it is an UPPER BOUND rather
  # than a count. `Bounds::Size` measures RENDERED lines -- a hunk's body plus
  # its `@@` header -- so a corpus file costs its own lines plus ONE PER UNIT,
  # and the unit count is knowable only by chunking. Under-measuring would put a
  # corpus on a different tape from a diff source and let an oversized prompt
  # through, so the bound over-measures instead, off the granularity floor.
  describe "the size a bound is decided from" do
    def rendered(file) = file.hunks.sum { |hunk| hunk.lines.size + 1 }

    it "sizes every file without chunking any of them" do
      spread(50)
      sizes = corpus.files.map(&:rendered_lines)

      expect(sizes).to all(be_a(Integer).and(be_positive))
      expect(counter.chunked).to be_empty
    end

    it "is exact on a file that chunks to one unit, which is the small-file case" do
      write("small.md", document("## Heading", "", "Body."))

      expect(corpus.files.first.rendered_lines).to eq(4)
      expect(rendered(corpus.files.first)).to eq(4)
    end

    # The direction that matters: never under, whatever the file is shaped like.
    it "never under-measures what the chunking actually renders" do
      write("guide.md", five_sections(sections))
      write("lib/widget.rb", document("# frozen_string_literal: true", "", "class Widget", "  def alpha",
                                      "    1", "    2", "  end", "end"))
      write("notes/run.log", document(*Array.new(40) { |line| line.even? ? "line #{line}" : "" }))
      write("ragged.txt", "one\ntwo")
      write("empty.txt", "")

      expect(corpus.files.map { |file| file.rendered_lines - rendered(file) }).to all(be >= 0)
    end

    it "over-measures a file of many units rather than under-measuring it" do
      write("many.md", five_sections(sections))

      expect(corpus.files.first.rendered_lines).to be > rendered(corpus.files.first)
    end

    # {LazyFile} accepts zero, because zero is honest for a binary and for a
    # pure rename. A corpus has neither, so a file with content claiming zero
    # would be a source lying about its own cost -- the obligation `sized`
    # cannot check for us.
    it "never reports zero for a file that renders anything at all" do
      write("one.txt", "x")

      expect(corpus.files.first.rendered_lines).to be_positive
    end

    it "lets Bounds measure a whole corpus without reading one hunk" do
      spread(50)
      measured = Lain::Review::Bounds::Size.of(corpus.files)

      expect(measured).to have_attributes(files: 50, lines: 200)
      expect(counter.chunked).to be_empty
    end

    # The disclosed hole, pinned rather than left to be discovered. The bound
    # rests on {Chunker::Granularity}'s floor, which only the dispatch's own
    # chunkers keep; an injected chunker is held to no such contract, and one
    # that emits a unit per paragraph exceeds it.
    it "is not a bound over a chunker that keeps no granularity floor" do
      write("many.log", document(*Array.new(40) { |line| line.even? ? "line #{line}" : "" }))
      forced = build_with_chunker(->(_path) { Lain::Survey::Chunker::Paragraphs.new(ceiling: 1) })

      expect(forced.files.first.rendered_lines).to be < rendered(forced.files.first)
    end
  end

  describe "#file_at" do
    it "reads the working tree at the head and nothing at the base" do
      write("guide.md", five_sections(sections))

      expect(corpus.file_at(corpus.head_ref, "guide.md")).to eq(five_sections(sections).b)
      expect(corpus.file_at(corpus.base_ref, "guide.md")).to be_nil
    end

    it "answers nothing for a revision it does not carry" do
      write("guide.md", five_sections(sections))

      expect(corpus.file_at("whatever", "guide.md")).to be_nil
    end
  end

  # A hunk's body carries an origin marker on EVERY line, blank ones included:
  # `Changeset#context?` reads `""` as CONTEXT, so a bare blank line would grow
  # an old side that does not exist and materialise anchors against a base that
  # holds nothing.
  describe "the hunks a unit becomes" do
    before { write("guide.md", five_sections(sections)) }

    let(:hunks) { file_for(corpus, "guide.md").hunks }

    it "marks every line as an addition, blank lines included" do
      blank = hunks.flat_map(&:lines).select { |line| line == "+" }

      expect(hunks.flat_map(&:lines)).to all(start_with("+"))
      expect(blank).not_to be_empty
    end

    it "leaves no old side at all, so no old-side anchor can materialise" do
      changeset = changeset_for(corpus)

      expect(hunks.map { |hunk| [hunk.old_start, hunk.old_count] }).to all(eq([0, 0]))
      expect(changeset.each_anchor(side: :old).to_a).to be_empty
    end

    it "round-trips its evidence byte for byte, blank lines included" do
      evidence = changeset_for(corpus).each_anchor(side: :new).map(&:anchor_text)

      expect(evidence.join("\n")).to eq(five_sections(sections).delete_suffix("\n"))
    end

    it "starts each hunk where its unit starts, so a new-side anchor names a real line" do
      expect(hunks.map(&:new_start)).to eq(hunks.map(&:new_start).sort)
      expect(hunks.first.new_start).to eq(1)
      expect(hunks.map(&:new_count)).to eq(hunks.map { |hunk| hunk.lines.size })
    end

    it "carries the unit's label as the hunk heading a surface renders" do
      expect(hunks.map(&:heading)).to include("Alpha", "Echo")
    end
  end

  # The scheme is the corpus's own, and the collision it prevents is
  # demonstrable rather than hypothetical: a one-unit surveyed file and the same
  # bytes newly ADDED in a branch diff have the same path frame and the same
  # all-`+` body.
  describe "the key scheme" do
    before { write("only.txt", document("one", "two", "three")) }

    let(:surveyed) { file_for(corpus, "only.txt").hunks.first }

    # `@@ -0,0 +1,3 @@` over an all-`+` body: git's own shape for a file a
    # branch adds, written as a literal so the collision below is demonstrated
    # against the diff world rather than against a restatement of this one.
    let(:added_in_a_diff) do
      Lain::Review::Hunk.new(path: "only.txt", old_start: 0, old_count: 0, new_start: 1, new_count: 3,
                             lines: ["+one", "+two", "+three"], heading: "")
    end

    it "carries the same path, spans and body as that diff hunk, so the collision is real" do
      restated = Lain::Review::Hunk.new(path: surveyed.path, old_start: surveyed.old_start,
                                        old_count: surveyed.old_count, new_start: surveyed.new_start,
                                        new_count: surveyed.new_count, lines: surveyed.lines,
                                        heading: surveyed.heading)

      expect(restated).to eq(added_in_a_diff)
      expect(restated.content_key).to eq(added_in_a_diff.content_key)
    end

    it "cannot satisfy that mark, because the scheme is its own" do
      expect(surveyed.content_key).to start_with("#{Lain::Survey::Unit::CONTENT_SCHEME}:")
      expect(added_in_a_diff.content_key).to start_with("#{Lain::Review::Hunk::CONTENT_SCHEME}:")
      expect(surveyed.content_key).not_to eq(added_in_a_diff.content_key)
      expect(Lain::Review::Hunk.keys([surveyed])).not_to eq(Lain::Review::Hunk.keys([added_in_a_diff]))
    end
  end

  # ACCEPTED behaviour, recorded so it is a property rather than a surprise: two
  # byte-identical units share a content key, so both fall to the span key --
  # which embeds the line they start at, and an insertion above the pair moves
  # both.
  describe "two byte-identical units in one file" do
    subject(:corpus) do
      described_class.new(walk:, projection:, chunker: ->(_path) { Lain::Survey::Chunker::Paragraphs.new(ceiling: 3) })
    end

    let(:twice) { document("same one", "same two", "", "same one", "same two", "") }

    it "gives them distinct, span-qualified keys rather than one key for both" do
      write("twice.log", twice)
      keys = keys_for(corpus, "twice.log")

      expect(keys.uniq.size).to eq(2)
      expect(keys).to all(start_with("#{Lain::Survey::Unit::SPAN_SCHEME}:"))
    end

    # The proof behind {UnitHunk#full_span_key}'s claim that the ladder's third
    # rung is unreachable: the coverage contract gives every unit of a file a
    # distinct start line, and the span key frames it.
    it "never needs the third rung, because two units of one file cannot share a span key" do
      write("twice.log", twice)
      hunks = file_for(corpus, "twice.log").hunks

      expect(hunks.map(&:span_key).uniq.size).to eq(hunks.size)
    end

    it "discards BOTH their marks when a line is inserted above them" do
      write("twice.log", twice)
      before = keys_for(corpus, "twice.log")
      write("twice.log", "new opening\n#{twice}")

      expect(keys_for(build_paragraphs, "twice.log")).not_to include(*before)
    end
  end

  # What a survey is FOR: marks that survive the next reading of the same tree.
  describe "marks across two surveys" do
    let(:untouched) { %w[Alpha Bravo Delta Echo] }

    before { write("guide.md", five_sections(sections)) }

    it "reconciles without raising, because the base never moved" do
      marks = marks_over(corpus, ["guide.md"])
      write("other.md", document("## Late arrival", "", "Body one.", "Body two."))

      expect { marks.reconcile(changeset_for(build)) }.not_to raise_error
    end

    it "keeps every mark when an unrelated file is edited" do
      marks = marks_over(corpus, ["guide.md"])
      write("other.md", document("## Late arrival", "", "Body one.", "Body two."))

      expect(marks.reconcile(changeset_for(build)).to_h.size).to eq(marks.to_h.size)
    end

    # The edited section and the prelude the paragraph landed in, and nothing
    # else: a unit's content key is position-independent, so the four sections
    # below the insertion keep theirs.
    it "loses exactly the edited unit and the one an insertion landed in" do
      marks = marks_over(corpus, ["guide.md"])
      headings = corpus.files.first.hunks.to_h { |hunk| [hunk.content_key, hunk.heading] }
      write("guide.md", "New opening line.\n\n#{five_sections(sections(revised: "Charlie body two, revised."))}")
      kept = marks.reconcile(changeset_for(build)).to_h.keys

      expect(kept.map { |key| headings.fetch(key) }).to match_array(untouched)
    end
  end

  # The ceiling is reached from the WALK, before a byte is read: an oversized
  # corpus is refused without paying for the identity pass it would then throw
  # away.
  describe "the file ceiling" do
    it "refuses a corpus over the ceiling, naming the measurement and what to do" do
      spread(6)
      bounds = Lain::Review::Bounds.new(max_files: 5)

      expect { described_class.new(walk:, projection:, bounds:) }
        .to raise_error(Lain::Review::Bounds::TooLarge, /6 files.*ceiling of 5/m)
    end

    it "reads no file to reach that decision" do
      spread(6)
      allow(File).to receive(:binread).and_raise("a refusal must not read a byte")

      expect { described_class.new(walk:, projection:, bounds: Lain::Review::Bounds.new(max_files: 5)) }
        .to raise_error(Lain::Review::Bounds::TooLarge)
    end

    it "admits a corpus at the ceiling" do
      spread(5)

      expect(described_class.new(walk:, projection:, bounds: Lain::Review::Bounds.new(max_files: 5)).files.size)
        .to eq(5)
    end
  end

  # The observation seam B10 rides, and the reason it is a constructor argument
  # rather than a lookup: the whole laziness claim is only assertable through a
  # chunker somebody else supplied.
  describe "the injected chunker" do
    it "defaults to the dispatch, so each file type meets the chunker that reads it" do
      write("guide.md", five_sections(sections))
      write("lib/widget.rb", document("# frozen_string_literal: true", "", "class Widget", "  def alpha",
                                      "    1", "    2", "    3", "  end", "end"))
      write("notes/run.log", document("First run.", "", "Second run.", "", "Third run."))
      plain = build

      expect(keys_headings(plain, "guide.md")).to include("Alpha", "Echo")
      expect(keys_headings(plain, "lib/widget.rb")).to include(a_string_matching(/alpha/))
      expect(keys_headings(plain, "notes/run.log")).to all(eq(""))
    end

    it "takes any chunker a caller supplies, over the file type's own" do
      write("guide.md", five_sections(sections))
      forced = described_class.new(walk:, projection:,
                                   chunker: ->(_path) { Lain::Survey::Chunker::Paragraphs.new })

      expect(keys_headings(forced, "guide.md")).to all(eq(""))
    end
  end

  def keys_headings(source, path) = file_for(source, path).hunks.map(&:heading)

  def build_paragraphs = build_with_chunker(->(_path) { Lain::Survey::Chunker::Paragraphs.new(ceiling: 3) })
end
