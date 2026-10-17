# frozen_string_literal: true

RSpec.describe Lain::Utf8 do
  describe ".legible" do
    it "replaces the bytes that are not valid UTF-8 and leaves the rest" do
      expect(described_class.legible("caf\xC3\xA9 \xFF".b)).to eq("café �")
    end

    it "takes a replacement for the invalid sequence" do
      expect(described_class.legible("a\xFFb", "?")).to eq("a?b")
    end

    # `encode` would return a UTF-8-tagged String unchanged, invalid bytes and all.
    it "scrubs a String already tagged UTF-8" do
      tagged = (+"a\xFFb").force_encoding(Encoding::UTF_8)

      expect(described_class.legible(tagged)).to be_valid_encoding
      expect(described_class.legible(tagged)).to eq("a�b")
    end

    it "does not touch the String it was given" do
      given = "a\xFF".b

      described_class.legible(given)

      expect(given.encoding).to eq(Encoding::BINARY)
    end

    it "reads nil as the empty String" do
      expect(described_class.legible(nil)).to eq("")
    end
  end
end
