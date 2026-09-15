# frozen_string_literal: true

RSpec.describe Lain::Mode::Approval do
  describe "the declared roster" do
    it "names exactly two levels, ask and then auto" do
      expect(described_class::NAMES).to eq(%i[ask auto])
    end

    it "answers a declared name with that level, however it is spelled" do
      expect(described_class.for("auto")).to have_attributes(name: :auto)
      expect(described_class.for(:auto)).to be(described_class.for("auto"))
    end

    it "refuses an undeclared name, naming every alternative" do
      expect { described_class.for(:manual) }.to raise_error(ArgumentError, /manual.*ask.*auto/)
    end
  end

  describe "the lighters" do
    it "leaves ask silent, since it is where every session starts" do
      expect(described_class.for(:ask).lighter).to eq("")
    end

    # Automatic approval decides calls a human would otherwise have been asked
    # about, so the prompt has to say so.
    it "lights auto" do
      expect(described_class.for(:auto).lighter).to eq("AUTO")
    end
  end

  it "is a deeply frozen value" do
    expect(described_class::NAMES.map { |name| described_class.for(name) }).to all(be_deeply_frozen)
  end
end
