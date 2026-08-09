# frozen_string_literal: true

RSpec.describe Lain::Survey::Chunker::Paragraphs do
  # Ten one-line paragraphs, blank-line separated: small enough that a ceiling
  # above their total must pack them, large enough that one per paragraph is a
  # visibly different answer.
  def short_paragraphs(count) = (1..count).map { |n| "paragraph #{n}\n" }.join("\n")

  it_behaves_like "a survey chunker",
                  chunker: -> { described_class.new(ceiling: 6) },
                  corpus: {
                    "a prose file of blank-line-separated paragraphs" => {
                      path: "notes.txt",
                      source: "alpha one\nalpha two\n\nbeta one\n\n\ngamma one\ngamma two\ngamma three\n"
                    },
                    "a CRLF file" => {
                      path: "crlf.txt",
                      source: "alpha\r\n\r\nbeta one\r\nbeta two\r\n"
                    },
                    "a file that is one long unsplittable paragraph" => {
                      path: "wall.txt",
                      source: (1..20).map { |n| "line #{n}\n" }.join
                    },
                    "a file of nothing but blank lines" => {
                      path: "blanks.txt",
                      source: "\n\n\n\n"
                    },
                    "a file whose first line is blank" => {
                      path: "leading.txt",
                      source: "\n\nalpha\n\nbeta\n"
                    }
                  }

  describe "#call" do
    it "packs short paragraphs toward the ceiling rather than emitting one per paragraph" do
      units = described_class.new(ceiling: 20).call(path: "notes.txt", source: short_paragraphs(10))
      expect(units.size).to be < 10
    end

    it "fills each run up to the ceiling" do
      units = described_class.new(ceiling: 4).call(path: "notes.txt", source: short_paragraphs(10))
      expect(units.map { |unit| unit.lines.size }).to all(be <= 4)
    end

    # Cutting mid-paragraph would hand a reviewer half a thought and make the
    # other half a separate mark. Exceeding the ceiling is the honest answer.
    it "emits one over-ceiling unit rather than cutting an unsplittable run" do
      source = (1..20).map { |n| "line #{n}\n" }.join
      units = described_class.new(ceiling: 5).call(path: "wall.txt", source:)
      expect(units.size).to eq(1)
      expect(units.first.lines.size).to eq(20)
    end

    it "does not pack a further paragraph onto an already over-ceiling run" do
      source = "#{(1..20).map { |n| "line #{n}\n" }.join}\ntail\n"
      units = described_class.new(ceiling: 5).call(path: "wall.txt", source:)
      expect(units.size).to eq(2)
    end

    it "keeps a paragraph's trailing blank lines with the paragraph above them" do
      units = described_class.new(ceiling: 2).call(path: "notes.txt", source: "alpha\n\nbeta\n")
      expect(units.map(&:lines)).to eq([["alpha", ""], ["beta"]])
    end

    it "labels its units with nothing, having no structure to name" do
      units = described_class.new(ceiling: 3).call(path: "notes.txt", source: short_paragraphs(4))
      expect(units.map(&:label).uniq).to eq([""])
    end

    it "produces no units for an empty file" do
      expect(described_class.new(ceiling: 5).call(path: "empty.txt", source: "")).to eq([])
    end
  end

  # The floor is a collaborator of the markdown and code chunkers, which hand it
  # a SLICE of a file: the lines, where they start, and the label of whatever
  # structure they were found inside.
  describe "#pack" do
    subject(:floor) { described_class.new(ceiling: 3) }

    it "numbers the units from the start line it was given" do
      units = floor.pack(path: "doc.md", lines: %w[a b c d], start_line: 40, label: "Intro")
      expect(units.first.start_line).to eq(40)
    end

    it "carries the caller's label onto every unit" do
      units = floor.pack(path: "doc.md", lines: ["a", "", "b", "", "c"], start_line: 1, label: "Intro")
      expect(units.map(&:label).uniq).to eq(["Intro"])
    end

    it "produces no units for no lines" do
      expect(floor.pack(path: "doc.md", lines: [], start_line: 7, label: "Intro")).to eq([])
    end
  end
end
