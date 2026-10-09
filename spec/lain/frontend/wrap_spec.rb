# frozen_string_literal: true

RSpec.describe Lain::Frontend::Wrap do
  def widths(text) = text.split("\n", -1).map { |line| Lain::Ext::Prompt.width(line) }

  describe ".call" do
    it "breaks a long sentence between words" do
      wrapped = described_class.call("the quick brown fox jumps over the lazy dog", width: 20)

      expect(wrapped).to eq("the quick brown fox\njumps over the lazy\ndog")
    end

    it "hard-breaks a word longer than the width" do
      wrapped = described_class.call("a" * 25, width: 10)

      expect(wrapped.split("\n")).to eq(["a" * 10, "a" * 10, "a" * 5])
    end

    it "starts an over-long word on a fresh line" do
      wrapped = described_class.call("see #{"b" * 12}", width: 10)

      expect(wrapped.split("\n")).to eq(["see", "b" * 10, "bb"])
    end

    it "does not count styling escapes toward the width" do
      coloured = "\e[31m#{"x" * 8} #{"y" * 9}\e[0m"

      expect(described_class.call(coloured, width: 20)).to eq(coloured)
    end

    it "keeps the escapes when it breaks a coloured line" do
      wrapped = described_class.call("\e[31mone two three\e[0m", width: 7)

      expect(wrapped).to eq("\e[31mone two\nthree\e[0m")
    end

    it "counts a wide character as 2 columns" do
      wrapped = described_class.call("日本語日本語", width: 10)

      expect(wrapped.split("\n")).to eq(%w[日本語日本 語])
    end

    it "never lets a line exceed the width" do
      text = "mixed 日本語 prose with \e[1mbold\e[0m words and a verylongwordthatdoesnotfitanywhere"

      expect(widths(described_class.call(text, width: 12))).to all(be <= 12)
    end

    it "keeps a short line and its blank lines untouched" do
      expect(described_class.call("one\n\ntwo\n", width: 20)).to eq("one\n\ntwo\n")
    end

    it "wraps each line of a multi-line text independently" do
      wrapped = described_class.call("aaa bbb\nccc ddd", width: 5)

      expect(wrapped).to eq("aaa\nbbb\nccc\nddd")
    end

    it "keeps a line's indentation, and repeats it on the continuation" do
      wrapped = described_class.call("    return some_long_call( argument)", width: 20)

      expect(wrapped.split("\n")).to eq(["    return", "    some_long_call(", "    argument)"])
    end

    it "keeps spacing inside a line that fits" do
      expect(described_class.call("a    b", width: 20)).to eq("a    b")
    end

    it "places one grapheme per line when the width is narrower than it" do
      expect(described_class.call("日本", width: 1).split("\n")).to eq(%w[日 本])
    end

    it "returns a coloured, indented line that fits byte for byte" do
      line = "\e[32m    foo  \e[0m"

      expect(described_class.call(line, width: 20)).to eq(line)
    end

    it "keeps the indent that follows a leading escape when it wraps" do
      wrapped = described_class.call("\e[32m    aaa bbb ccc\e[0m", width: 11)

      expect(wrapped.split("\n")).to eq(["\e[32m    aaa bbb", "    ccc\e[0m"])
    end

    it "expands a tab to the next stop of 8 columns" do
      expect(described_class.call("a\tb cccc", width: 10).split("\n")).to eq(["a       b", "cccc"])
    end

    it "leaves a tabbed line that fits once expanded" do
      expect(described_class.call("a\tb", width: 9)).to eq("a\tb")
    end

    it "joins rows with the end of line it is given" do
      expect(described_class.call("aaa bbb", width: 4, eol: "\r\n")).to eq("aaa\r\nbbb")
    end

    it "passes lines inside a fenced code block through, however wide" do
      code = "#{"a" * 30} #{"b" * 30}"
      text = "intro words here\n```ruby\n#{code}\n```\nafter the fence"

      expect(described_class.call(text, width: 12).split("\n")).to eq(
        ["intro words", "here", "```ruby", code, "```", "after the", "fence"]
      )
    end

    it "passes text that is not valid UTF-8 through whole" do
      expect(described_class.call("review \xFF\xFE.md is waiting", width: 5)).to eq("review \xFF\xFE.md is waiting")
    end

    it "returns the text unchanged for a non-positive width" do
      expect(described_class.call("some words here", width: 0)).to eq("some words here")
    end
  end
end
