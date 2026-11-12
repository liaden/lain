# frozen_string_literal: true

RSpec.describe Lain::Approval::Verdict do
  let(:variants) { [described_class::Approve, described_class::Hold, described_class::Deny] }

  it "answers exactly one of approved?, held? and denied? per variant" do
    answers = variants.map { |v| v.new(note: "x").then { [_1.approved?, _1.held?, _1.denied?] } }

    expect(answers).to eq([[true, false, false], [false, true, false], [false, false, true]])
  end

  it "keeps a note as 1 string" do
    expect(described_class::Approve.new(note: "a; b").note).to eq("a; b")
  end

  it "turns a blank note into nil" do
    expect(variants.map { _1.new(note: "  ").note }).to all(be_nil)
  end

  it "takes a nil note" do
    expect(described_class::Hold.new(note: nil).note).to be_nil
  end

  it "freezes the note" do
    expect(described_class::Deny.new(note: +"no").note).to be_frozen
  end

  it "refuses a note that is neither a string nor nil" do
    [5, :sym, ["a"]].each do |note|
      expect { described_class::Approve.new(note:) }.to raise_error(ArgumentError, /note/)
    end
  end

  it "keeps variants with the same note distinct" do
    expect(described_class::Approve.new(note: "x")).not_to eq(described_class::Hold.new(note: "x"))
  end

  it "is shareable across ractors" do
    expect(variants.map { Ractor.shareable?(_1.new(note: +"n")) }).to all(be(true))
  end

  it "passes a variant through coerce" do
    verdict = described_class::Hold.new(note: "later")

    expect(described_class.coerce(verdict)).to equal(verdict)
  end

  it "refuses anything else, naming the 3 variants" do
    [true, :approve, nil].each do |value|
      expect { described_class.coerce(value) }
        .to raise_error(ArgumentError, /Approve.*Hold.*Deny/)
    end
  end

  describe "an approval with network" do
    it "is not chosen by default" do
      expect(described_class::Approve.new.network?).to be(false)
    end

    it "is chosen only when asked for" do
      expect(described_class::Approve.new(note: "x", network: true).network?).to be(true)
    end

    it "differs from a plain approval with the same note" do
      expect(described_class::Approve.new(network: true)).not_to eq(described_class::Approve.new)
    end

    it "is refused on a hold or a deny" do
      [described_class::Hold, described_class::Deny].each do |kind|
        expect { kind.new(network: true) }.to raise_error(ArgumentError, /network/)
      end
    end
  end
end
