# frozen_string_literal: true

RSpec.describe Lain::Survey::Chunker::Markdown do
  nested = <<~MD
    # Alpha

    intro

    ## Beta

    mid

    ### Gamma

    deep
  MD

  fenced = <<~MD
    # Real

    alpha

    ```rust
    # not a heading
    fn main() {}
    ```

    beta

    ## Real Two

    gamma
  MD

  setext = <<~MD
    Title
    =====

    body one
    body two

    Subtitle
    --------

    body three
    body four
  MD

  frontmatter = <<~MD
    ---
    title: Doc
    ---

    preamble prose
    still preamble

    # First

    body
  MD

  five_sections = <<~MD
    # One

    body one

    # Two

    body two

    # Three

    body three

    # Four

    body four

    # Five

    body five
  MD

  # Granularity is a separate subject with its own spec and its own tree-wide
  # AC, so the section-tree examples below hold it at its identity (nothing is
  # smaller than one line) rather than reading the tree through it. The shared
  # contract group runs on the real defaults.
  def chunk(source, ceiling: 4, path: "doc.md", minimum: 1)
    described_class.new(ceiling:, granularity: Lain::Survey::Chunker::Granularity.new(minimum:))
                   .call(path:, source:)
  end

  def unit_holding(units, needle) = units.find { |unit| unit.lines.any? { |line| line.include?(needle) } }

  it_behaves_like "a survey chunker",
                  chunker: -> { described_class.new(ceiling: 4) },
                  corpus: {
                    "a nested markdown document" => { path: "nested.md", source: nested },
                    "a markdown document with a fenced code block" => { path: "fenced.md", source: fenced },
                    "a setext-headed markdown document" => { path: "setext.md", source: setext },
                    "a markdown document opening with frontmatter" => { path: "front.md", source: frontmatter },
                    "a markdown document with CRLF line endings" => {
                      path: "crlf.md",
                      source: "# Title\r\n\r\nbody one\r\n\r\n## Sub\r\n\r\nbody two\r\n"
                    },
                    "a markdown document small enough to be one unit" => {
                      path: "tiny.md", source: "# Tiny\n\nbody\n"
                    }
                  }

  describe "reading the section tree" do
    it "makes a whole section one unit when it fits under the ceiling" do
      units = chunk("# Tiny\n\nbody\n", ceiling: 10)
      expect(units.size).to eq(1)
      expect(units.first.label).to eq("Tiny")
    end

    it "labels a unit with the path of headings down to it" do
      expect(unit_holding(chunk(nested), "deep").label).to eq("Alpha > Beta > Gamma")
    end

    it "descends into an oversized section's children, prose first" do
      source = <<~MD
        ## Parent

        parent prose one
        parent prose two

        ### Child A

        a body

        ### Child B

        b body

        ### Child C

        c body
      MD

      labels = chunk(source).map(&:label)

      expect(labels).to include("Parent")
      expect(labels).to include("Parent > Child A", "Parent > Child B", "Parent > Child C")
    end

    it "never puts two children of an oversized section in one unit" do
      source = "## Parent\n\nprose\n\n### A\n\na body\n\n### B\n\nb body\n"
      unit = unit_holding(chunk(source), "a body")
      expect(unit.lines.join("\n")).not_to include("b body")
    end

    it "covers frontmatter and the preamble before the first heading" do
      units = chunk(frontmatter)
      expect(units.first.start_line).to eq(1)
      expect(units.first.lines.first).to eq("---")
    end
  end

  describe "the fenced-code-block rule" do
    it "opens no section for a hash inside a fence" do
      expect(chunk(fenced).map(&:label)).to all(satisfy { |label| !label.include?("not a heading") })
    end

    it "starts no unit at the fenced hash line" do
      fenced_line = Lain::Survey::Unit.lines_of(fenced).index("# not a heading") + 1
      expect(chunk(fenced).map(&:start_line)).not_to include(fenced_line)
    end
  end

  # Measured, not assumed: a setext_heading node exists but opens NO section, so
  # a two-setext-heading document parses as one section with no children. The
  # ruling is that such a document takes the paragraph floor, said out loud
  # rather than silently fallen into.
  describe "a setext-authored document" do
    it "falls to the paragraph floor rather than inventing a hierarchy" do
      units = chunk(setext, ceiling: 3)
      expect(units.size).to be > 1
      expect(units.map(&:label).uniq).to eq([""])
    end

    # The mixed case, stated because a README is shaped exactly like this: the
    # setext heading opens no section, so it is absorbed by the enclosing ATX
    # one. Extent stays faithful -- only the LABEL is missing.
    it "keeps extent faithful in a document mixing ATX and setext headings" do
      mixed = "# Atx\n\nintro\n\nSetext\n------\n\nunder the setext\n\n## Second Atx\n\ntail\n"
      units = chunk(mixed, ceiling: 4)

      expect(units.flat_map(&:lines)).to eq(Lain::Survey::Unit.lines_of(mixed))
      expect(units.map(&:label)).to include("Atx > Second Atx")
      expect(units.map(&:label).join).not_to include("Setext")
    end
  end

  describe "granularity, at the shipped default" do
    it "merges sections too small to be worth a mark" do
      tiny = "# A\n\na\n\n# B\n\nb\n\n# C\n\nc\n"
      units = described_class.new(ceiling: 10).call(path: "tiny.md", source: tiny)

      expect(units.size).to be < 3
      expect(units.flat_map(&:lines)).to eq(Lain::Survey::Unit.lines_of(tiny))
    end

    it "names every section a merged unit swallowed" do
      tiny = "# A\n\na\n\n# B\n\nb\n"
      units = described_class.new(ceiling: 10).call(path: "tiny.md", source: tiny)

      expect(units.map(&:label)).to eq(["A, B"])
    end
  end

  describe "keys, at the shipped default granularity" do
    it "moves one key when one section of a document of ordinary sections is edited" do
      document = (1..4).map { |n| "## Section #{n}\n\nbody #{n} first\nbody #{n} second\nbody #{n} third\n\n" }.join
      before = described_class.new(ceiling: 20).call(path: "doc.md", source: document)
      after = described_class.new(ceiling: 20).call(path: "doc.md", source: document.sub("body 3 second", "edited"))

      moved = before.map(&:content_key).zip(after.map(&:content_key)).count { |a, b| a != b }

      expect(before.size).to be > 1
      expect(moved).to eq(1)
    end

    it "reads a latin-1-tagged document as prose rather than raising" do
      source = (+"# Title\n\nbody\n").force_encoding(Encoding::ISO_8859_1)

      expect { described_class.new.call(path: "latin1.md", source:) }.not_to raise_error
      expect(described_class.new.call(path: "latin1.md", source:).map(&:label).uniq).to eq([""])
    end
  end

  describe "keys" do
    # The heading is INSIDE the hashed body, inverting Hunk's rule on purpose:
    # Hunk excludes the `@@` line because it is derived position, while a
    # markdown heading is authored content a reviewer must re-read.
    it "changes only the reworded section's key" do
      before = chunk(five_sections, ceiling: 5)
      after = chunk(five_sections.sub("# Three\n", "# Three, revised\n"), ceiling: 5)

      differing = before.map(&:content_key).zip(after.map(&:content_key)).count { |a, b| a != b }
      expect(before.size).to eq(5)
      expect(differing).to eq(1)
    end

    it "leaves every other section's key alone when one body is edited" do
      before = chunk(five_sections, ceiling: 5)
      after = chunk(five_sections.sub("body four", "body four, revised"), ceiling: 5)

      expect(after.map(&:content_key) - before.map(&:content_key)).to contain_exactly(after[3].content_key)
    end
  end
end
