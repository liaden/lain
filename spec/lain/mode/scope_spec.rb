# frozen_string_literal: true

RSpec.describe Lain::Mode::Scope do
  describe "the declared roster" do
    it "names checkout, the project's own working tree, and plan, the spike that confines it" do
      expect(described_class::NAMES).to eq(%i[checkout plan])
    end

    it "answers a declared name with that scope, however it is spelled" do
      expect(described_class.for("checkout")).to have_attributes(name: :checkout)
      expect(described_class.for(:checkout)).to be(described_class.for("checkout"))
    end

    it "refuses an undeclared name, naming every alternative" do
      expect { described_class.for(:sandbox) }.to raise_error(ArgumentError, /sandbox.*checkout/)
    end
  end

  describe "the lighter" do
    it "leaves the checkout silent, since it is where every session starts" do
      expect(described_class.for(:checkout).lighter).to eq("")
    end

    # What a plan session writes never reaches the checkout the human is
    # looking at, so the prompt has to say where the session is.
    it "lights plan" do
      expect(described_class.for(:plan).lighter).to eq("PLAN")
    end
  end

  it "is a deeply frozen value" do
    expect(described_class::NAMES.map { |name| described_class.for(name) }).to all(be_deeply_frozen)
  end
end
