# frozen_string_literal: true

RSpec.describe Lain::Survey::Chunker::Code do
  # Real files, because the coverage contract over a synthetic four-method
  # fixture proves nothing about the shapes a repository actually holds --
  # heredocs, reopened classes, a hundred lines of docstring between two defs.
  def self.repo_file(relative) = Pathname(__dir__).join("../../../..", relative).expand_path

  hunk_rb = repo_file("lib/lain/review/hunk.rb")
  session_rb = repo_file("lib/lain/review/session.rb")

  four_methods = <<~RUBY
    # frozen_string_literal: true

    require "json"
    require "set"

    class Shapes
      def alpha
        1
      end

      def beta
        2
      end

      def gamma
        3
      end

      def delta
        4
      end
    end
  RUBY

  documented_methods = <<~RUBY
    # frozen_string_literal: true

    class Shapes
      # This comment documents ALPHA.
      def alpha
        1
      end

      # This comment documents BETA.
      #
      # It runs to several lines, as the house style does.
      def beta
        2
      end
    end
  RUBY

  # Granularity is a separate subject with its own spec and its own tree-wide
  # AC, so the partition examples below hold it at its identity (nothing is
  # smaller than one line). The shared contract group runs on the real defaults.
  def chunk(source, path: "shapes.rb", ceiling: 60, minimum: 1)
    described_class.new(ceiling:, granularity: Lain::Survey::Chunker::Granularity.new(minimum:))
                   .call(path:, source:)
  end

  def unit_holding(units, needle) = units.find { |unit| unit.lines.any? { |line| line.include?(needle) } }

  it_behaves_like "a survey chunker",
                  chunker: -> { described_class.new(ceiling: 30) },
                  corpus: {
                    "a Ruby file of four methods" => { path: "shapes.rb", source: four_methods },
                    "this repository's own review/hunk.rb" => {
                      path: "lib/lain/review/hunk.rb", source: File.read(hunk_rb, encoding: Encoding::UTF_8)
                    },
                    "this repository's own review/session.rb" => {
                      path: "lib/lain/review/session.rb", source: File.read(session_rb, encoding: Encoding::UTF_8)
                    },
                    "a Rust file" => {
                      path: "point.rs",
                      source: "use std::fmt;\n\npub struct Point {\n    x: i32,\n}\n\nfn helper() {}\n"
                    },
                    "a file in a language with no authored query" => {
                      path: "script.lua", source: "local x = 1\n\nfunction f()\n  return x\nend\n"
                    },
                    "a file whose first line is already a definition" => {
                      path: "bare.rb", source: "class Bare\nend\n"
                    }
                  }

  describe "the gap rule" do
    # Attaching a gap DOWNWARD is the tempting move and it is wrong: an edit to
    # a file-level require would then clear the mark on an unrelated method.
    it "makes the file-level requires their own unit, not part of the first definition" do
      units = chunk(four_methods)
      preamble = units.first

      expect(preamble.lines.join("\n")).to include("require \"json\"")
      expect(preamble.lines.join("\n")).not_to include("class Shapes")
    end

    it "starts a unit at each top-level definition" do
      starts = chunk(four_methods).map(&:start_line)
      lines = Lain::Survey::Unit.lines_of(four_methods)

      %w[alpha beta gamma delta].each do |name|
        expect(starts).to include(lines.index { |line| line.include?("def #{name}") } + 1)
      end
    end

    it "produces no preamble unit when the first line is already a definition" do
      units = chunk("class Bare\nend\n")
      expect(units.first.start_line).to eq(1)
    end
  end

  # The rule the panel's counter-example forced: without it, editing BETA's
  # docstring changed ALPHA's key and left BETA's untouched.
  describe "a comment run above a definition" do
    it "belongs to the definition it documents" do
      units = chunk(documented_methods)

      expect(unit_holding(units, "documents BETA").lines.join("\n")).to include("def beta")
      expect(unit_holding(units, "documents BETA").lines.join("\n")).not_to include("def alpha")
    end

    it "moves that definition's key when the comment is edited, and no other" do
      before = chunk(documented_methods)
      after = chunk(documented_methods.sub("documents BETA.", "documents BETA, at length."))

      moved = before.map(&:content_key).zip(after.map(&:content_key)).count { |a, b| a != b }
      changed = unit_holding(after, "documents BETA")

      expect(moved).to eq(1)
      expect(changed.lines.join("\n")).to include("def beta")
    end

    # The preamble half of the rule, which the card was right about: a require
    # is not a comment, so the run stops there and file-level requires stay in
    # their own unit.
    it "does not reach past a require into the preamble" do
      source = "# frozen_string_literal: true\n\nrequire \"json\"\n\n# Documented.\nclass Shapes\nend\n"
      units = chunk(source)

      expect(units.first.lines.join("\n")).to include("require \"json\"")
      expect(units.first.lines.join("\n")).not_to include("# Documented.")
      expect(unit_holding(units, "# Documented.").lines.join("\n")).to include("class Shapes")
    end

    it "leaves a run of blank lines alone, so a method keeps the blank below it" do
      units = chunk(four_methods)
      alpha = unit_holding(units, "def alpha")

      expect(alpha.lines.last).to eq("")
    end

    # What counts as commentary is per-LANGUAGE. A Rust attribute is not a
    # comment, so a blank-or-comment walk stops at `#[inline]` and strands the
    # doc comment ABOVE it with the previous definition -- the exact harm this
    # rule removes for Ruby, left intact for Rust. 374 definitions in this
    # repository's own Rust are preceded by an attribute line.
    it "treats a Rust attribute as commentary, so a doc above it is not stranded" do
      source = <<~RUST
        /// Alpha does the first thing.
        pub fn alpha() -> i32 {
            1
        }

        /// Beta does the second thing.
        #[inline]
        #[must_use]
        pub fn beta() -> i32 {
            2
        }
      RUST
      units = chunk(source, path: "point.rs")

      expect(unit_holding(units, "Beta does").lines.join("\n")).to include("pub fn beta")
      expect(unit_holding(units, "Alpha does").lines.join("\n")).not_to include("#[inline]")
    end

    it "moves only the documented Rust definition's key when its doc is edited" do
      source = <<~RUST
        /// Alpha does the first thing.
        pub fn alpha() -> i32 {
            1
        }

        /// Beta does the second thing.
        #[inline]
        pub fn beta() -> i32 {
            2
        }
      RUST
      before = chunk(source, path: "point.rs")
      after = chunk(source.sub("Beta does the second thing.", "Beta does the second thing, briskly."),
                    path: "point.rs")

      moved = before.map(&:content_key).zip(after.map(&:content_key)).count { |a, b| a != b }

      expect(moved).to eq(1)
      expect(unit_holding(after, "briskly").lines.join("\n")).to include("pub fn beta")
    end

    it "treats a TypeScript decorator as commentary too" do
      source = <<~TS
        // Alpha.
        export function alpha(): number { return 1; }

        // Beta.
        @Injectable()
        export class Beta {}
      TS
      units = chunk(source, path: "beta.ts")

      expect(unit_holding(units, "Beta.").lines.join("\n")).to include("@Injectable()")
      expect(unit_holding(units, "Alpha.").lines.join("\n")).not_to include("@Injectable()")
    end
  end

  # Every other keying example holds granularity at its identity so it can read
  # the partition. These run at the SHIPPED defaults, because merge boundaries
  # are position-dependent while a content key is not, so what a mark costs
  # differs -- and that difference is what a reviewer actually pays.
  describe "keys, at the shipped default granularity" do
    wide_methods = <<~RUBY
      # frozen_string_literal: true

      class Wide
        def alpha
          first = 1
          second = 2
          first + second
        end

        def beta
          third = 3
          fourth = 4
          third + fourth
        end

        def gamma
          fifth = 5
          sixth = 6
          fifth + sixth
        end
      end
    RUBY

    it "moves one key when one method of a file of ordinary methods is edited" do
      before = described_class.new.call(path: "wide.rb", source: wide_methods)
      after = described_class.new.call(path: "wide.rb", source: wide_methods.sub("third = 3", "third = 33"))

      moved = before.map(&:content_key).zip(after.map(&:content_key)).count { |a, b| a != b }

      expect(before.size).to be > 1
      expect(moved).to eq(1)
    end

    # The disclosed cost, pinned so it cannot change in silence. A content key
    # is position-independent, so at the identity granularity an insertion above
    # costs the unit it landed in and nothing else. Coalescing merges by
    # POSITION, so one inserted line re-draws which units merge and the loss
    # spreads. Measured on this repository: `cli/command/sessions.rb` loses
    # 4 of 4 where the identity loses 1 of 9; `finding.rb` 2 of 14 against
    # 1 of 32; `session.rb` 1 of 21 against 1 of 29.
    def keys_lost(chunker, path, source)
      before = chunker.call(path:, source:)
      after = chunker.call(path:, source: "# a new line\n#{source}")
      before.size - (before.map(&:content_key) & after.map(&:content_key)).size
    end

    it "costs exactly one key to insert a line at the top, before coalescing" do
      source = File.read(self.class.repo_file("lib/lain/cli/command/sessions.rb"), encoding: Encoding::UTF_8)
      identity = described_class.new(granularity: Lain::Survey::Chunker::Granularity.new(minimum: 1))

      expect(keys_lost(identity, "sessions.rb", source)).to eq(1)
    end

    it "costs more than that once units are merged, because merging is positional" do
      source = File.read(self.class.repo_file("lib/lain/cli/command/sessions.rb"), encoding: Encoding::UTF_8)
      identity = described_class.new(granularity: Lain::Survey::Chunker::Granularity.new(minimum: 1))

      expect(keys_lost(described_class.new, "sessions.rb", source))
        .to be > keys_lost(identity, "sessions.rb", source)
    end

    it "can lose every key in a small file to a one-line insertion at the top" do
      small = "class Tiny\n  def alpha\n    1\n  end\n\n  def beta\n    2\n  end\nend\n"

      expect(keys_lost(described_class.new, "tiny.rb", small))
        .to eq(described_class.new.call(path: "tiny.rb", source: small).size)
    end
  end

  describe "keys" do
    it "leaves the siblings' keys alone when one method's body is edited" do
      before = chunk(four_methods)
      after = chunk(four_methods.sub("    2\n", "    2 + 2\n"))

      expect(after.map(&:content_key) - before.map(&:content_key)).to contain_exactly(after[3].content_key)
    end
  end

  describe "a language with no authored symbols query" do
    it "falls back to paragraph runs rather than refusing" do
      source = "local x = 1\n\nfunction f()\n  return x\nend\n"
      units = chunk(source, path: "script.lua", ceiling: 2)

      expect(units.size).to be > 1
      expect(units.map(&:label).uniq).to eq([""])
    end

    it "treats a file with no extension the same way" do
      expect { chunk("just prose\n", path: "LICENSE") }.not_to raise_error
    end

    # The extension table maps extensions; whether lain can PARSE the language
    # is Structural::Queries' answer, asked every call. Restating support here
    # is how a table drifts from the queries actually shipped.
    it "asks the query catalog, so dropping a language there makes these files prose" do
      allow(Lain::Structural::Queries).to receive(:languages_for).with(:symbols).and_return(%i[rust])

      units = chunk("class Shapes\n  def alpha\n    1\n  end\nend\n")

      expect(units.map(&:label).uniq).to eq([""])
    end
  end

  describe "a file whose bytes are not valid UTF-8" do
    # The ext refuses a source it would have to transcode, naming a byte offset
    # in a file this layer cannot name back, so the floor takes it rather than
    # the survey losing the file.
    it "reads it as prose rather than raising out of the parser" do
      units = chunk("# frozen_string_literal: true\n\nclass Caf\xE9\n  def alpha\n  end\nend\n")

      expect(units.map(&:label).uniq).to eq([""])
      expect(units).not_to be_empty
    end

    # Validity is not the question the ext asks. It refuses on the ENCODING
    # TAG as well, so a latin-1-tagged String whose bytes are pure ASCII is
    # `valid_encoding? == true` and still raises `source must be UTF-8, got
    # ISO-8859-1` -- the leak fix 4 exists to stop.
    it "reads a latin-1-TAGGED file as prose, even where every byte is ASCII" do
      source = (+"class Shapes\n  def alpha\n    1\n  end\nend\n").force_encoding(Encoding::ISO_8859_1)

      expect { chunk(source, path: "latin1.rb") }.not_to raise_error
      expect(chunk(source, path: "latin1.rb").map(&:label).uniq).to eq([""])
    end

    it "still parses a US-ASCII or binary-tagged file the ext does accept" do
      source = "class Shapes\n  def alpha\n    1\n  end\nend\n"

      expect(chunk(source.dup.force_encoding(Encoding::US_ASCII), path: "ascii.rb").map(&:label))
        .to include(a_string_matching(/class Shapes/))
      expect(chunk(source.b, path: "binary.rb").map(&:label)).to include(a_string_matching(/class Shapes/))
    end
  end

  # The granularity floor the escalation trigger binds, asserted at the same
  # threshold so the AC and the trigger cannot disagree: more units than
  # lines/5 makes marking useless.
  #
  # These twelve are files the sweep found ABOVE OR ON the cap with granularity
  # at its identity -- a sample of the offenders, not the twelve worst, and not
  # a hand-picked file that passes. (`cli/command/model.rb`,
  # `provider/http/chunk.rb` and `isolation/null.rb` all scored above two of
  # them.) A sweep of all 620 `lib/**/*.rb` put 49 above the cap and 23 exactly
  # on it; `finding.rb` was the worst, 108 lines and 32 units, fourteen of them
  # one line. Pinning offenders by name is what stops a future reader concluding
  # from one comfortable file that the whole tree is comfortable.
  #
  # The cap is `max(1, lines/5)`: under plain integer division a four-line file
  # has a cap of zero, and one unit is the least any chunking can emit.
  describe "granularity, over files the sweep found at or over the cap" do
    worst_cases = %w[
      lib/lain/compaction/derivation_audit/finding.rb
      lib/lain/version.rb
      lib/lain/error.rb
      lib/lain/structural.rb
      lib/lain/cli/command/sessions.rb
      lib/lain/cli/command/quit.rb
      lib/lain/provider/http/error.rb
      lib/lain/provider/spool/null.rb
      lib/lain/toolset/disclosure/upfront.rb
      lib/lain/tools/ask_human/notifying.rb
      lib/lain/review/session.rb
      lib/lain/review/hunk.rb
    ]

    worst_cases.each do |relative|
      context "with #{relative}" do
        let(:source) { File.read(self.class.superclass.repo_file(relative), encoding: Encoding::UTF_8) }
        let(:units) { described_class.new.call(path: relative, source:) }

        it "keeps to at most one unit per five lines" do
          expect(units.size).to be <= [Lain::Survey::Unit.lines_of(source).size / 5, 1].max
        end

        # The example carrying the general claim, so it runs over all twelve:
        # the cap holds because every unit clears the minimum, not by
        # arithmetic luck. A file shorter than the minimum is the documented
        # exception -- it has one unit, the least any chunking can emit.
        it "gives every unit at least the minimum, unless the file is shorter than one" do
          minimum = Lain::Survey::Chunker::DEFAULT_MINIMUM

          expect(units.size).to be >= 1
          expect(units.map { |unit| unit.lines.size }).to all(be >= minimum) if units.size > 1
        end
      end
    end
  end
end
