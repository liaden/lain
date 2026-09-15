# frozen_string_literal: true

RSpec.describe Lain::Mode::Scope do
  describe "the declared roster" do
    it "names checkout, the project's own working tree, and nothing else yet" do
      expect(described_class::NAMES).to eq(%i[checkout])
    end

    it "answers a declared name with that scope, however it is spelled" do
      expect(described_class.for("checkout")).to have_attributes(name: :checkout)
      expect(described_class.for(:checkout)).to be(described_class.for("checkout"))
    end

    it "refuses an undeclared name, naming every alternative" do
      expect { described_class.for(:sandbox) }.to raise_error(ArgumentError, /sandbox.*checkout/)
    end

    # Plan scope is a confinement that is not built yet, so the name must not
    # quietly resolve to the checkout it would have confined.
    it "refuses plan rather than answering the checkout" do
      expect { described_class.for(:plan) }.to raise_error(ArgumentError, /plan/)
    end
  end

  describe "the lighter" do
    it "leaves the checkout silent, since it is where every session starts" do
      expect(described_class.for(:checkout).lighter).to eq("")
    end
  end

  it "is a deeply frozen value" do
    expect(described_class.for(:checkout)).to be_deeply_frozen
  end
end
