# frozen_string_literal: true

RSpec.describe Lain::Frontend::Markdown do
  def pairs(text) = described_class.segments(text).map { |segment| [segment.token, segment.text] }

  describe ".segments" do
    it "returns a Renderable" do
      expect(described_class.segments("hi")).to be_a(Lain::Renderable)
    end

    it "paints bold with emphasis and code with code, and drops the markers" do
      expect(pairs("Use **bold** and `code` here")).to eq(
        [[:plain, "Use "], [:emphasis, "bold"], [:plain, " and "], [:code, "code"], [:plain, " here"]]
      )
    end

    it "leaves plain words unpainted" do
      expect(pairs("just words")).to eq([[:plain, "just words"]])
    end

    it "puts prose under the token it is told to, so a reply keeps its colour" do
      tokens = described_class.segments("a **b** c", prose: :response).map(&:token)

      expect(tokens).to eq(%i[response emphasis response])
    end

    it "keeps a fenced block whole, painted code, with the fence lines dropped" do
      text = "before\n```ruby\ndef a\n  b\nend\n```\nafter"

      expect(described_class.segments(text).text).to eq("before\ndef a\n  b\nend\nafter")
    end

    it "paints each line of a fenced block as code and reads no markdown inside it" do
      segments = pairs("```\n**not bold**\n- not a bullet\n```")

      expect(segments).to eq([[:code, "**not bold**"], [:plain, "\n"], [:code, "- not a bullet"]])
    end

    it "paints a heading without its hashes" do
      expect(pairs("## Plan")).to eq([[:heading_md, "Plan"]])
    end

    it "starts each bullet with the bullet glyph painted bullet" do
      expect(pairs("- one\n- two")).to eq(
        [[:bullet, "•"], [:plain, " one"], [:plain, "\n"], [:bullet, "•"], [:plain, " two"]]
      )
    end

    it "keeps a bullet's indentation and reads inline markup in its words" do
      expect(pairs("  - use `x`")).to eq([[:plain, "  "], [:bullet, "•"], [:plain, " use "], [:code, "x"]])
    end

    it "keeps an unclosed fence's remaining lines as code" do
      expect(described_class.segments("```\na\nb").map(&:token)).to eq(%i[code plain code])
    end

    it "leaves an unmatched marker as written" do
      expect(pairs("2 ** 3 and a ` tick")).to eq([[:plain, "2 ** 3 and a ` tick"]])
    end
  end

  describe ".segments with hostile or odd bytes" do
    it "does not pass an escape through raw in prose" do
      expect(pairs("a \e[31mred\e[2J")).to eq([[:plain, "a \\e[31mred\\e[2J"]])
    end

    it "does not pass an escape through raw in a code span" do
      expect(pairs("`\e[2J`")).to eq([[:code, "\\e[2J"]])
    end

    it "keeps tabs" do
      expect(pairs("a\tb")).to eq([[:plain, "a\tb"]])
    end

    it "keeps the newline and tab of a code line while dumping an escape" do
      segments = described_class.segments("```\na\tb\e\n```\n")

      expect(segments.text).to eq("a\tb\\e\n")
    end

    it "carries no carriage return from CRLF line ends" do
      segments = described_class.segments("## Plan\r\n- one\r\n```\r\ncode\r\n```\r\nend\r\n")

      expect(segments.text).to eq("Plan\n• one\ncode\nend\n")
    end
  end

  describe ".segments bullets and bold" do
    it "reads a star bullet" do
      expect(pairs("* one")).to eq([[:bullet, "•"], [:plain, " one"]])
    end

    it "does not read a dash inside a word as a bullet" do
      expect(pairs("a - b")).to eq([[:plain, "a - b"]])
    end

    it "ends each bold run at its own closing marker" do
      emphasis = pairs("**a** and **b**").grep(->((token, _)) { token == :emphasis })

      expect(emphasis).to eq([[:emphasis, "a"], [:emphasis, "b"]])
    end
  end

  describe ".verbatim_rows" do
    it "names a row holding only an inline code span, which therefore never wraps" do
      expect(described_class.verbatim_rows(described_class.segments("words\n`a long span`"))).to eq([1])
    end

    it "names the rows that are whole lines of a code block" do
      renderable = described_class.segments("intro\n```\ncode here\nmore\n```\nUse `x` inline")

      expect(described_class.verbatim_rows(renderable)).to eq([1, 2])
    end

    it "does not name a row that merely holds inline code beside prose" do
      expect(described_class.verbatim_rows(described_class.segments("see `x` now"))).to eq([])
    end
  end
end
