# frozen_string_literal: true

# Lain::Structural::Matcher is THE single Ruby seam over Lain::Ext::AstGrep
# (T1): no other unit calls the ext directly, so it alone would need to change
# on a breaking ext bump. It owns byte -> 1-based line conversion and the
# supported-language allowlist -- both deliberately absent from the ext's own
# byte-offsets-only contract (see ext/lain/src/astgrep.rs's module doc).
RSpec.describe Lain::Structural::Matcher do
  subject(:matcher) { described_class.new }

  describe "#match" do
    it "returns one domain Match per structural hit, with a byte range and named captures" do
      matches = matcher.match(source: "def total(x)\n  x\nend", language: :ruby, pattern: "def $NAME($$$A)")

      expect(matches.size).to eq(1)
      match = matches.first
      expect(match.byte_range).to eq(0...(match.byte_range.end))
      expect(match.byte_range).to be_a(Range)
      expect(match.captures).to eq("NAME" => "total")
    end

    it "computes a 1-based line by counting newlines in the byte prefix, not trusting the ext's own line" do
      source = "# leading comment\n# second comment\ndef total(x)\n  x\nend"

      matches = matcher.match(source:, language: :ruby, pattern: "def $NAME($$$A)")

      expect(matches.first.line).to eq(3)
    end

    it "returns [] for a valid pattern with no matches" do
      expect(matcher.match(source: "x = 1", language: :ruby, pattern: "$RECV.save")).to eq([])
    end

    it "matches structure, so `save` inside a comment or a string never counts" do
      src = <<~RUBY
        # remember to record.save the row
        note = "call record.save when ready"
        record.save
      RUBY

      matches = matcher.match(source: src, language: :ruby, pattern: "$RECV.save")

      expect(matches.size).to eq(1)
      expect(matches.first.captures).to eq("RECV" => "record")
    end

    it "returns deeply frozen Match value objects" do
      matches = matcher.match(source: "def total(x)\n  x\nend", language: :ruby, pattern: "def $NAME($$$A)")

      expect(matches.first).to be_deeply_frozen
    end

    it "wraps a malformed pattern in its OWN typed error, insulating the ext's BadPattern" do
      expect(Lain::Structural::Matcher::BadPattern.ancestors).to include(Lain::Error)

      expect { matcher.match(source: "x = 1", language: :ruby, pattern: "def (") }
        .to raise_error(Lain::Structural::Matcher::BadPattern)
    end

    it "never lets the ext's own BadPattern escape uncaught" do
      error = begin
        matcher.match(source: "x = 1", language: :ruby, pattern: "def (")
      rescue StandardError => e
        e
      end

      expect(error).to be_a(Lain::Structural::Matcher::BadPattern)
      expect(error).not_to be_a(Lain::Ext::AstGrep::BadPattern)
    end

    it "rejects an unsupported language before ever calling the ext, naming the language" do
      expect(Lain::Ext::AstGrep).not_to receive(:search)

      expect { matcher.match(source: "x = 1", language: :cobol, pattern: "$A") }
        .to raise_error(Lain::Structural::Matcher::UnknownLanguage, /cobol/)
    end
  end

  describe "#dump" do
    it "delegates to the ext and reveals the singleton_method node distinct from a plain method" do
      dumped = matcher.dump(source: "def self.x; end", language: :ruby)

      expect(dumped).to include("singleton_method")
    end

    it "rejects an unsupported language before ever calling the ext, naming the language" do
      expect(Lain::Ext::AstGrep).not_to receive(:dump)

      expect { matcher.dump(source: "x = 1", language: :cobol) }
        .to raise_error(Lain::Structural::Matcher::UnknownLanguage, /cobol/)
    end
  end
end
