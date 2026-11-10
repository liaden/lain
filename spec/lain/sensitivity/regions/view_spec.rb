# frozen_string_literal: true

require "zlib"

RSpec.describe Lain::Sensitivity::Regions::View do
  let(:line) { "API_KEY=AKIAQZ7R2M4X9TBL3KWE\n" }

  def utf16(text, order) = text.encode(order).b

  def png
    header = [13].pack("N") + "IHDR".b + [1, 1, 8, 2, 0, 0, 0].pack("NNC5")
    "\x89PNG\r\n\x1A\n".b + header + [Zlib.crc32(header.byteslice(4..))].pack("N")
  end

  describe ".of" do
    it "reads a UTF-16LE byte order mark" do
      view = described_class.of("\xFF\xFE".b + utf16(line, Encoding::UTF_16LE))

      expect(view).to have_attributes(encoding: :utf16le, text: line)
    end

    it "reads a UTF-16BE byte order mark" do
      view = described_class.of("\xFE\xFF".b + utf16(line, Encoding::UTF_16BE))

      expect(view).to have_attributes(encoding: :utf16be, text: line)
    end

    it "reads UTF-16LE with no byte order mark by its NUL pattern" do
      expect(described_class.of(utf16(line, Encoding::UTF_16LE))).to have_attributes(encoding: :utf16le, text: line)
    end

    it "reads UTF-16BE with no byte order mark by its NUL pattern" do
      expect(described_class.of(utf16(line, Encoding::UTF_16BE))).to have_attributes(encoding: :utf16be, text: line)
    end

    it "reads UTF-8 behind its byte order mark as the text after it" do
      expect(described_class.of("\xEF\xBB\xBF#{line}".b)).to have_attributes(encoding: :utf8, text: line)
    end

    it "reads plain UTF-8 as itself" do
      expect(described_class.of(line)).to have_attributes(encoding: :utf8, text: line)
    end

    it "takes a PNG header for UTF-8, not UTF-16" do
      expect(described_class.of(png).encoding).to eq(:utf8)
    end

    it "takes a gzip stream for UTF-8, not UTF-16" do
      expect(described_class.of(Zlib.gzip(Random.new(7).bytes(4096))).encoding).to eq(:utf8)
    end

    it "takes NUL-separated names for UTF-8" do
      expect(described_class.of("./lib/a.rb\0./spec/a_spec.rb\0./exe/lain\0").encoding).to eq(:utf8)
    end

    it "takes text holding a few NULs for UTF-8" do
      expect(described_class.of("a\0b=c\0d\nefghij\n").encoding).to eq(:utf8)
    end

    it "takes environ-shaped names and short values for UTF-8" do
      expect(described_class.of("TERM=xt\0LANG=C.\0USER=ab\0PATH=/b\0").encoding).to eq(:utf8)
    end

    it "takes a run of 3 printable units for UTF-8" do
      expect(described_class.of("a\0b\0c\0").encoding).to eq(:utf8)
    end

    it "takes UTF-16 shapes holding a lone surrogate for UTF-8" do
      expect(described_class.of("\x00\xD8".b + utf16(line, Encoding::UTF_16LE)).encoding).to eq(:utf8)
    end

    it "takes UTF-16 shapes holding NUL characters for UTF-8" do
      expect(described_class.of(utf16("ab\0\0cd", Encoding::UTF_16LE)).encoding).to eq(:utf8)
    end

    it "takes UTF-16 shapes holding control characters for UTF-8" do
      expect(described_class.of(utf16("ab\x01\x02cd", Encoding::UTF_16LE)).encoding).to eq(:utf8)
    end
  end

  describe "#offset" do
    it "maps a UTF-8 offset to the original byte, past the byte order mark" do
      view = described_class.of("\xFF\xFE".b + utf16(line, Encoding::UTF_16LE))

      expect(view.offset(8)).to eq(2 + 16)
    end

    it "maps across characters of every width" do
      text = "é€😀K"
      view = described_class.of("\xFE\xFF".b + utf16(text, Encoding::UTF_16BE))

      expect([0, 2, 5, 9].map { view.offset(_1) }).to eq([2, 4, 6, 10])
    end

    it "maps an offset inside a character to that character's first byte" do
      view = described_class.of(utf16("aa€€aa", Encoding::UTF_16LE))

      expect(view.offset(3)).to eq(4)
    end

    it "adds a UTF-8 byte order mark back" do
      expect(described_class.of("\xEF\xBB\xBF#{line}".b).offset(8)).to eq(11)
    end
  end

  describe "#end_offset" do
    it "maps an offset inside a character to the byte past it, so a span only widens" do
      view = described_class.of(utf16("aa€€aa", Encoding::UTF_16LE))

      expect(view.end_offset(3)).to eq(6)
    end

    it "maps the end of the text to the end of the bytes it was read from" do
      bytes = "\xFF\xFE".b + utf16(line, Encoding::UTF_16LE)

      expect(described_class.of(bytes).end_offset(line.bytesize)).to eq(bytes.bytesize)
    end
  end

  describe "#encode" do
    it "writes UTF-8 text in the view's byte order" do
      view = described_class.of(utf16(line, Encoding::UTF_16BE))

      expect(view.encode("<redacted:1>")).to eq(utf16("<redacted:1>", Encoding::UTF_16BE))
    end

    it "leaves UTF-8 text as it is in a UTF-8 view" do
      expect(described_class.of(line).encode("<redacted:1>")).to eq("<redacted:1>".b)
    end
  end

  describe "#decode" do
    it "reads the view's bytes as UTF-8" do
      view = described_class.of(utf16(line, Encoding::UTF_16LE))

      expect(view.decode(utf16("hello", Encoding::UTF_16LE))).to eq("hello")
    end
  end

  describe "#utf16?" do
    it "answers for each encoding" do
      expect([line, utf16(line, Encoding::UTF_16LE)].map { described_class.of(_1).utf16? }).to eq([false, true])
    end
  end
end
