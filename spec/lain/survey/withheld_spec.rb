# frozen_string_literal: true

# What a walk found and will not hand to the corpus. Its own value because four
# later cards read it -- the corpus decides what withheld paths do to `#files`,
# two surfaces render them, and the accretion gesture refuses an added denied
# path with a report.
RSpec.describe Lain::Survey::Withheld do
  let(:denial) { Lain::Sensitivity::Verdict.new(level: :denied, reason: :protected) }

  describe "the reason a path was kept out" do
    it "carries the classifier's own explanation for a denial" do
      withheld = described_class.denied(".ssh/id_ed25519", denial)

      expect(withheld).to have_attributes(path: ".ssh/id_ed25519", reason: :denied,
                                          explanation: denial.explanation, denied?: true, binary?: false)
    end

    it "names binary content in its own words, because no classifier saw the bytes" do
      withheld = described_class.binary("logo.png")

      expect(withheld).to have_attributes(path: "logo.png", reason: :binary,
                                          explanation: described_class::BINARY,
                                          binary?: true, denied?: false)
    end

    it "reads as one disclosure line, which is what a surface renders" do
      expect(described_class.binary("logo.png").to_s).to eq("logo.png: #{described_class::BINARY}")
    end
  end

  describe "refusing what it cannot mean" do
    it "takes only a reason it knows, so a typo cannot become a silent third category" do
      expect { described_class.new(path: "a.rb", reason: :ignored, explanation: "ignored") }
        .to raise_error(ArgumentError, /reason must be one of/)
    end

    it "refuses a path that is not a String, rather than stringifying a caller's bug" do
      expect { described_class.new(path: :"a.rb", reason: :binary, explanation: "binary content") }
        .to raise_error(ArgumentError, /a path must be a String/)
    end

    it "refuses a blank explanation, because a withheld path with no why is a mystery" do
      expect { described_class.new(path: "a.rb", reason: :binary, explanation: "  ") }
        .to raise_error(ArgumentError, /an explanation/)
    end
  end

  describe "as a value" do
    it "is deeply frozen, so it crosses a Ractor and journals as it stands" do
      expect(Ractor.shareable?(described_class.binary(+"logo.png"))).to be(true)
    end

    it "equals another withholding of the same path for the same reason" do
      expect(described_class.binary("logo.png")).to eq(described_class.binary("logo.png"))
    end
  end
end
