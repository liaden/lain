# frozen_string_literal: true

RSpec.describe Lain::Mode::Layer do
  describe "the declared family" do
    it "names its layers as a closed, public set" do
      expect(described_class::NAMES).to eq(%i[goal notify vi])
    end

    it "answers a declared name with that layer" do
      expect(described_class.for(:goal)).to have_attributes(name: :goal)
    end

    it "answers the same value however the name is spelled" do
      expect(described_class.for("goal")).to eq(described_class.for(:goal))
    end

    it "refuses an undeclared name, naming every alternative" do
      expect { described_class.for(:nonsense) }
        .to raise_error(ArgumentError, /nonsense.*goal.*notify.*vi/)
    end

    it "is a deeply frozen value" do
      expect(described_class.for(:vi)).to be_deeply_frozen
    end
  end

  describe "what a layer declares" do
    it "carries a name and a lighter and no outcome flag" do
      expect(described_class.members).to eq(%i[name lighter])
    end

    it "refuses an unknown auto_approve layer" do
      expect { described_class.for(:auto_approve) }
        .to raise_error(ArgumentError, /auto_approve.*goal.*notify.*vi/)
    end

    it "lets a layer stay silent with an empty lighter" do
      expect(described_class.new(name: :phantom, lighter: "").lighter).to eq("")
    end
  end

  # The notify layer rings the terminal and, inside tmux, displays a message --
  # nothing outside those two -- so its lighter names the bell rather than a
  # notification some desktop daemon would be expected to show.
  describe "what the notify layer's lighter promises" do
    it "lights notify as BELL" do
      expect(described_class.for(:notify)).to have_attributes(lighter: "BELL")
    end
  end
end
