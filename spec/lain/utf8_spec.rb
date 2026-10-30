# frozen_string_literal: true

RSpec.describe Lain::Utf8 do
  describe ".bytes?" do
    it "accepts ASCII and valid UTF-8 whatever the tag" do
      expect([described_class.bytes?("abc"), described_class.bytes?("caf\xC3\xA9".b)]).to all(be(true))
    end

    it "refuses bytes that are not UTF-8, binary-tagged or not" do
      invalid = (+"a\xFF").force_encoding(Encoding::UTF_8)

      expect([described_class.bytes?("a\xFF".b), described_class.bytes?(invalid)]).to all(be(false))
    end
  end

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

  describe ".escaped" do
    it "makes an escape and a bidi override visible" do
      escaped = described_class.escaped("\e[2J\u202Eevil")

      expect(escaped).to eq("\\e[2J\\u202Eevil")
      expect(escaped.size).to eq(15)
    end

    it "dumps the marks that reorder text without a bidi override" do
      expect(described_class.escaped("\u200E\u200F\u061C")).to eq("\\u200E\\u200F\\u061C")
    end

    it "dumps a C1 control" do
      expect(described_class.escaped("a\u0085b")).to eq("a\\u0085b")
    end

    it "leaves the characters named in keep" do
      expect(described_class.escaped("a\tb\nc\e", keep: "\n\t")).to eq("a\tb\nc\\e")
    end

    it "leaves a joined emoji and a flag whole" do
      joined = "\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u{1F1EB}\u{1F1F7}"

      expect(described_class.escaped(joined)).to eq(joined)
    end

    it "scrubs invalid bytes first" do
      expect(described_class.escaped("a\xFF\e".b)).to eq("a\u{FFFD}\\e")
    end
  end

  describe "the one escaper" do
    it "is the only place in lib that dumps a control character" do
      root = File.expand_path("../../lib", __dir__)
      files = Dir[File.join(root, "**", "*.rb")].select { File.read(_1).match?(/gsub.*(dump|inspect)\[1\.\.-2\]/) }

      expect(files.map { _1.delete_prefix("#{root}/") }).to eq(["lain/utf8.rb"])
    end
  end
end
