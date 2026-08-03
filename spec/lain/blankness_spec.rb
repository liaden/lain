# frozen_string_literal: true

RSpec.describe Lain::Blankness do
  # Every invisible character below is built from its CODEPOINT rather than
  # written as itself. A literal is invisible in the diff, in the editor and in
  # review -- which is how an example named "non-breaking space" came to be
  # asserting U+0020.
  let(:nbsp) { 0x00A0.chr(Encoding::UTF_8) }
  let(:space_separators) { [0x00A0, 0x2007, 0x3000].map { |point| point.chr(Encoding::UTF_8) } }
  let(:zero_width) { [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF].map { |point| point.chr(Encoding::UTF_8) } }

  describe ".blank?" do
    it "is blank for nothing at all" do
      expect(described_class).to be_blank(nil)
      expect(described_class).to be_blank("")
    end

    it "is blank for ASCII whitespace" do
      expect(described_class).to be_blank("  \t\n ")
    end

    # The whole reason this predicate exists: `String#strip` is ASCII-only, so a
    # single U+00A0 satisfied `strip != ""` and let a bare APPROVE close a gate
    # on empty evidence.
    it "is blank for the space separators `strip` does not touch" do
      space_separators.each { |invisible| expect(described_class).to be_blank(invisible) }
    end

    # Not space to any locale, so POSIX [[:space:]] does not cover them and each
    # one has to be named.
    it "is blank for the zero-width set" do
      zero_width.each { |invisible| expect(described_class).to be_blank(invisible) }
    end

    it "is not blank for text, however little, and however padded" do
      expect(described_class).not_to be_blank("x")
      expect(described_class).not_to be_blank("#{nbsp} ok #{nbsp}")
      expect(described_class).not_to be_blank("#{zero_width.first}ok")
    end

    it "reads a non-String through #to_s, so a symbol answers like its text" do
      expect(described_class).to be_blank(:"")
      expect(described_class).not_to be_blank(:ok)
    end

    # Mojibake carries nothing usable either, so wholly undecodable bytes belong
    # on the blank arm rather than in an exception.
    it "is blank for undecodable bytes rather than raising" do
      expect { described_class.blank?("\xC3\x28".b) }.not_to raise_error
      expect(described_class).to be_blank("\xFF\xFE".b)
      expect(described_class).not_to be_blank("\xC3\x28".b)
    end
  end

  # The predicate moved down so `question` could stop reaching up into
  # `approval` for it; the old name has to keep answering identically or every
  # approval spec that pins it is pinning the wrong thing.
  it "is what Approval's GateEvidence.blank? now answers with" do
    evidence = Lain::Approval::Gate::Adjudicator::GateEvidence
    ["", nbsp, zero_width.first, "ok", nil].each do |value|
      expect(evidence.blank?(value)).to be(described_class.blank?(value))
    end
  end
end
