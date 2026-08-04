# frozen_string_literal: true

require "pastel"
require "stringio"

# T9: a command's answer as STRUCTURE. The renderable names style TOKENS as
# Symbols and never a colour -- that is what lets it live in lib/lain/ and be
# returned by a command without the cli layer depending on the frontend. The
# Theme (T8) is the only object that turns a Symbol into an escape sequence.
RSpec.describe Lain::Renderable do
  def theme(enabled: true, depth: 256, tokens: Lain::Frontend::Theme::DEFAULT_TOKENS)
    Lain::Frontend::Theme.new(pastel: Pastel.new(enabled:), tokens:, detect: -> { depth })
  end

  let(:colored) { Pastel.new(enabled: true) }

  describe "building" do
    it "starts with no segments" do
      expect(described_class.new).to be_empty
    end

    it "grows into a NEW renderable, never mutating the one it was built from" do
      base = described_class.new
      grown = base.with(:warning, "careful")

      expect(base).to be_empty
      expect(grown.count).to eq(1)
    end

    it "names its token as a Symbol, beside the words it styles" do
      segment = described_class.new.with(:warning, "careful").first

      expect(segment.token).to eq(:warning)
      expect(segment.text).to eq("careful")
    end

    it "#plain is sugar for the token that names no style" do
      expect(described_class.new.plain("hi").first.token).to eq(described_class::PLAIN)
    end

    it "registers that plain token in the theme's own vocabulary" do
      expect(theme.token?(described_class::PLAIN)).to be(true)
    end

    it "concatenates two renderables into one" do
      combined = described_class.new.plain("a") + described_class.new.with(:warning, "b")

      expect(combined.map(&:text)).to eq(%w[a b])
    end

    it "takes its segments up front too" do
      segments = [described_class::Segment.new(token: :warning, text: "a")]

      expect(described_class.new(segments).text).to eq("a")
    end
  end

  describe "Enumerable" do
    it "enumerates its segments in the order they were named" do
      renderable = described_class.new.plain("a").with(:warning, "b")

      expect(renderable.map(&:token)).to eq([described_class::PLAIN, :warning])
    end

    it "answers an Enumerator when nobody passed a block" do
      expect(described_class.new.plain("a").each).to be_a(Enumerator)
    end
  end

  describe "#text" do
    it "joins the words with no styling knowledge at all" do
      expect(described_class.new.plain("cache ").with(:warning, "cold").text).to eq("cache cold")
    end
  end

  describe "#paint" do
    it "paints each segment through the token it named" do
      renderable = described_class.new.plain("cache ").with(:error, "gone")

      expect(renderable.paint(theme)).to eq("cache #{colored.red.bold("gone")}")
    end

    it "leaves the surrounding text out of the styled segment's colour" do
      painted = described_class.new.plain("cache ").with(:error, "gone").paint(theme)

      expect(painted).to start_with("cache ")
    end

    it "carries no ANSI escapes at all on a non-tty stream" do
      painted = described_class.new.plain("cache ").with(:error, "gone")
                               .paint(Lain::Frontend::Theme.for(StringIO.new))

      expect(painted).to eq("cache gone")
      expect(painted).not_to include("\e[")
    end

    it "fails loudly on a token nobody registered -- never renders it plain" do
      expect { described_class.new.with(:chartreuse, "x").paint(theme) }
        .to raise_error(Lain::Frontend::Theme::UnknownToken)
    end
  end

  describe "as a value object" do
    it "is frozen" do
      expect(described_class.new.plain("a")).to be_frozen
    end

    it "is Ractor.shareable? -- no reachable mutable state" do
      expect(described_class.new.plain("a").with(:error, "b")).to be_deeply_frozen
    end

    it "is equal by its segments" do
      expect(described_class.new.plain("a")).to eq(described_class.new.plain("a"))
    end

    it "hashes by its segments, so it keys a Hash" do
      expect({ described_class.new.plain("a") => 1 }[described_class.new.plain("a")]).to eq(1)
    end

    it "never freezes the caller's own String" do
      words = +"mutable"
      described_class.new.plain(words)

      expect(words).not_to be_frozen
    end
  end
end
