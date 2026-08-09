# frozen_string_literal: true

RSpec.describe Lain::Survey::Unit do
  def unit(lines, path: "doc.md", label: "", start_line: 1)
    described_class.new(path:, label:, start_line:, lines:)
  end

  describe ".lines_of" do
    it "terminates the last line rather than starting an empty one" do
      expect(described_class.lines_of("alpha\nbeta\n")).to eq(%w[alpha beta])
    end

    it "keeps a last line that carries no terminator" do
      expect(described_class.lines_of("alpha\nbeta")).to eq(%w[alpha beta])
    end

    it "keeps interior blank lines, which are content" do
      expect(described_class.lines_of("alpha\n\nbeta\n")).to eq(["alpha", "", "beta"])
    end

    # `chomp("\n")` would strip a trailing "\r\n" WHOLE, losing exactly one
    # carriage return -- the last line's -- and leaving it different from every
    # line above it. `delete_suffix` is the rule changeset.rb:265 records.
    it "keeps a CRLF file's carriage returns, the last line included" do
      expect(described_class.lines_of("alpha\r\nbeta\r\n")).to eq(["alpha\r", "beta\r"])
    end

    it "yields no lines for an empty file" do
      expect(described_class.lines_of("")).to eq([])
    end

    # A file holding one newline holds one line -- an empty one. Reading it as
    # zero lines is how a whole line went unshown while reconstruction still
    # matched byte for byte, because the trailing newline was restored from the
    # source rather than from the units.
    it "reads a lone newline as one empty line, not as no lines" do
      expect(described_class.lines_of("\n")).to eq([""])
    end

    it "reads two newlines as two empty lines" do
      expect(described_class.lines_of("\n\n")).to eq(["", ""])
    end

    # A lone carriage return is not a line separator here: only "\n" is.
    it "does not split on a lone carriage return" do
      expect(described_class.lines_of("alpha\rbeta\n")).to eq(["alpha\rbeta"])
    end

    it "keeps a byte-order mark as content of the first line" do
      expect(described_class.lines_of("\xEF\xBB\xBFalpha\n")).to eq(["\xEF\xBB\xBFalpha"])
    end

    # `String#split` VALIDATES, so a latin-1 byte in a UTF-8-tagged file raised
    # a bare ArgumentError naming neither the file nor the offset. Splitting on
    # bytes and restoring the tag is the same move {Review::Hunk#body} makes.
    it "splits a file whose bytes are not valid UTF-8 rather than raising" do
      source = "alpha\n caf\xE9 \nbeta\n"

      expect { described_class.lines_of(source) }.not_to raise_error
      expect(described_class.lines_of(source).size).to eq(3)
    end

    it "keeps the source's encoding on every line, so a rejoin is byte-identical" do
      source = "caf\xE9\nbeta\n"
      lines = described_class.lines_of(source)

      expect(lines.map(&:encoding).uniq).to eq([source.encoding])
      expect("#{lines.join("\n")}\n").to eq(source)
    end

    it "answers frozen lines in a frozen array" do
      lines = described_class.lines_of("alpha\nbeta\n")

      expect(lines).to be_frozen
      expect(lines).to all(be_frozen)
    end
  end

  describe "as a value object" do
    it "is deeply frozen and Ractor-shareable" do
      expect(Ractor.shareable?(unit(%w[alpha beta]))).to be(true)
    end

    it "equals another unit built from the same values" do
      expect(unit(%w[alpha])).to eq(unit(%w[alpha]))
    end

    it "reports the last line it covers" do
      expect(unit(%w[a b c], start_line: 10).end_line).to eq(12)
    end

    it "refuses a nil path loudly rather than addressing as the empty string" do
      expect { described_class.new(path: nil, label: "", start_line: 1, lines: []) }
        .to raise_error(NoMethodError)
    end
  end

  describe "#content_key" do
    it "is stable for the same bytes at the same path" do
      expect(unit(%w[alpha beta]).content_key).to eq(unit(%w[alpha beta]).content_key)
    end

    it "is position-independent, so an edit above a unit does not clear its mark" do
      expect(unit(%w[alpha], start_line: 1).content_key).to eq(unit(%w[alpha], start_line: 90).content_key)
    end

    it "is independent of the label, which is derived presentation" do
      expect(unit(%w[alpha], label: "").content_key).to eq(unit(%w[alpha], label: "Intro").content_key)
    end

    it "differs when the bytes differ" do
      expect(unit(%w[alpha]).content_key).not_to eq(unit(%w[alpho]).content_key)
    end

    it "differs when the path differs" do
      expect(unit(%w[alpha], path: "a.md").content_key).not_to eq(unit(%w[alpha], path: "b.md").content_key)
    end

    it "names its own scheme" do
      expect(unit(%w[alpha]).content_key).to start_with("#{described_class::CONTENT_SCHEME}:")
    end

    # A one-unit surveyed file and the same file newly ADDED in a branch diff
    # carry the same path and the same bytes, so a shared scheme would let a
    # corpus mark satisfy a changeset hunk. The scheme is hashed in, not merely
    # prefixed, so the two cannot be made to agree.
    it "cannot collide with a diff hunk over the same path and bytes" do
      hunk = Lain::Review::Hunk.new(path: "a.md", old_start: 0, old_count: 0,
                                    new_start: 1, new_count: 1, lines: ["+alpha"])
      expect(unit(%w[alpha], path: "a.md").content_key).not_to eq(hunk.content_key)
    end
  end

  describe ".keys" do
    it "keys each unit by its content" do
      units = [unit(%w[alpha]), unit(%w[beta], start_line: 2)]
      expect(described_class.keys(units)).to eq(units.map(&:content_key))
    end

    # Byte-identical units are ordinary in prose -- a repeated licence header, a
    # separator run -- and a content key alone would hand both the same key, so
    # marking one would mark the other.
    it "qualifies duplicated content by span, so no two units share a key" do
      units = [unit(%w[same], start_line: 1), unit(%w[same], start_line: 40)]
      keys = described_class.keys(units)
      expect(keys.uniq.size).to eq(2)
      expect(keys).to all(start_with("#{described_class::SPAN_SCHEME}:"))
    end

    it "leaves an unduplicated unit's key alone when a sibling is duplicated" do
      alone = unit(%w[alone], start_line: 9)
      units = [unit(%w[same], start_line: 1), unit(%w[same], start_line: 40), alone]
      expect(described_class.keys(units).last).to eq(alone.content_key)
    end

    it "answers a frozen array" do
      expect(described_class.keys([unit(%w[alpha])])).to be_frozen
    end
  end
end
