# frozen_string_literal: true

# The one rendering of a withheld region, shared by the two arms that withhold
# one: `read_file` on its way out of the tool phase, and a survey's projection
# of a file it may list. Both walked their own byte offsets before this object
# existed; the walk is the thing that had to stop being duplicated, because a
# shared FORMAT with two walks still lets the arms disagree about the bytes
# around it.
RSpec.describe Lain::Sensitivity::Masking do
  # Long enough and random enough that no threshold under discussion misses it,
  # and literal so a fixture built from the detector's own tables cannot fail
  # when those tables are wrong.
  let(:secret) { "kJ8fQ2mZ4vX7pL0aB3nR6yT9uW1cE5dG8hK2jM4qS7vY0zA3" }

  def detect(content) = Lain::Sensitivity::Regions.detect(content)

  def placeholder(ordinal) = format(Lain::Sensitivity::Regions::PLACEHOLDER, ordinal)

  describe ".render" do
    let(:content) { "API_KEY=#{secret}\n" }

    it "swaps the region's bytes for the placeholder and keeps everything around them" do
      expect(described_class.render(content, detect(content))).to eq("API_KEY=#{placeholder(1)}\n")
    end

    # The ordinal counts masked regions in reading order, so three masked values
    # render as three distinguishable placeholders. The byte LENGTH would
    # disclose how long each secret is, which is a fact about the secret.
    it "numbers the placeholders in reading order" do
      three = "A_TOKEN=#{secret}\nB_TOKEN=#{secret.reverse}\nC_TOKEN=#{secret.succ}\n"

      expect(described_class.render(three, detect(three)))
        .to eq("A_TOKEN=#{placeholder(1)}\nB_TOKEN=#{placeholder(2)}\nC_TOKEN=#{placeholder(3)}\n")
    end

    it "masks only the regions it is handed, which is how a partial release renders" do
      two = "A_TOKEN=#{secret}\nB_TOKEN=#{secret.reverse}\n"

      expect(described_class.render(two, detect(two).last(1)))
        .to eq("A_TOKEN=#{secret}\nB_TOKEN=#{placeholder(1)}\n")
    end

    it "hands back content with nothing to mask unchanged" do
      prose = "x = 1\nDEBUG = true\nNote: this is important\n"

      expect(described_class.render(prose, [])).to eq(prose)
    end

    # The read middleware numbers across the content BLOCKS of one result, so
    # the sequence belongs to the caller; the default is what a single-string
    # caller wants.
    it "continues an ordinal sequence a caller supplies, so numbering spans two calls" do
      ordinals = (1..).each
      described_class.render(content, detect(content), ordinals:)

      expect(described_class.render(content, detect(content), ordinals:)).to eq("API_KEY=#{placeholder(2)}\n")
    end

    # The cases the panel's own drift matrix ran over both arms. They live here
    # now because there is one arm to test.
    it "masks a region that begins at byte 0 with no assignment around it" do
      expect(described_class.render(secret, detect(secret))).to eq(placeholder(1))
    end

    it "masks a region ending at EOF with no trailing newline" do
      tail = "API_KEY=#{secret}"

      expect(described_class.render(tail, detect(tail))).to eq("API_KEY=#{placeholder(1)}")
    end

    it "keeps CRLF line endings, which are bytes like any other" do
      crlf = "API_KEY=#{secret}\r\nDATABASE_PASSWORD=hunter2SecretValue\r\n"

      expect(described_class.render(crlf, detect(crlf)))
        .to eq("API_KEY=#{placeholder(1)}\r\nDATABASE_PASSWORD=#{placeholder(2)}\r\n")
    end

    it "keeps a BOM, whose bytes the detector skipped but whose offsets it kept" do
      bom = "\xEF\xBB\xBFAPI_KEY=#{secret}\n"

      expect(described_class.render(bom, detect(bom))).to eq("\xEF\xBB\xBFAPI_KEY=#{placeholder(1)}\n")
    end

    it "masks two regions with no separator bytes between them" do
      adjacent = "a=#{secret}\nb=3f5a9c2e1d7b4a6f8c0e2d4b6a8f0c1e\n"

      expect(described_class.render(adjacent, detect(adjacent)))
        .to eq("a=#{placeholder(1)}\nb=#{placeholder(2)}\n")
    end

    # The whole walk is in BINARY because an offset into re-decoded text is a
    # different offset, so the label has to be put back.
    it "restores the encoding it was given" do
      utf8 = "# café\nAPI_KEY=#{secret}\n"

      masked = described_class.render(utf8, detect(utf8))

      expect(masked.encoding).to eq(Encoding::UTF_8)
      expect(masked).to eq("# café\nAPI_KEY=#{placeholder(1)}\n")
    end

    it "keeps a multibyte character sitting inside the same line as the region" do
      mixed = "naïve=café API_KEY=#{secret}\n"

      expect(described_class.render(mixed, detect(mixed))).to eq("naïve=café API_KEY=#{placeholder(1)}\n")
    end
  end
end
