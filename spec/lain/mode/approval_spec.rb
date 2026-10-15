# frozen_string_literal: true

RSpec.describe Lain::Mode::Approval do
  describe "the declared roster" do
    it "names exactly three levels, ask, auto and bypass" do
      expect(described_class::NAMES).to eq(%i[ask auto bypass])
    end

    it "answers a declared name with that level, however it is spelled" do
      expect(described_class.for("bypass")).to have_attributes(name: :bypass)
      expect(described_class.for(:bypass)).to be(described_class.for("bypass"))
    end

    it "refuses an undeclared name, naming every alternative" do
      expect { described_class.for(:manual) }.to raise_error(ArgumentError, /manual.*ask.*bypass/)
    end
  end

  describe "the lighters" do
    it "leaves ask silent, since it is where every session starts" do
      expect(described_class.for(:ask).lighter).to eq("")
    end

    # Automatic approval decides calls a human would otherwise have been asked
    # about, so the prompt has to say so.
    it "lights bypass" do
      expect(described_class.for(:bypass).lighter).to eq("BYPASS")
    end

    it "lights auto, where a model judge decides calls before any human" do
      expect(described_class.for(:auto).lighter).to eq("AUTO")
    end
  end

  it "is a deeply frozen value" do
    expect(described_class::NAMES.map { |name| described_class.for(name) }).to all(be_deeply_frozen)
  end
end
