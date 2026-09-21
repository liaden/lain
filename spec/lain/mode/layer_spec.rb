# frozen_string_literal: true

RSpec.describe Lain::Mode::Layer do
  describe "the declared family" do
    it "names its layers as a closed, public set" do
      expect(described_class::NAMES).to eq(%i[auto_approve goal notify vi])
    end

    it "answers a declared name with that layer" do
      expect(described_class.for(:goal)).to have_attributes(name: :goal)
    end

    it "answers the same value however the name is spelled" do
      expect(described_class.for("goal")).to eq(described_class.for(:goal))
    end

    it "refuses an undeclared name, naming every alternative" do
      expect { described_class.for(:nonsense) }
        .to raise_error(ArgumentError, /nonsense.*auto_approve.*goal.*notify.*vi/)
    end

    it "is a deeply frozen value" do
      expect(described_class.for(:vi)).to be_deeply_frozen
    end
  end

  # Scenario: a layer that can change an outcome renders a lighter.
  #
  # The roster check alone would be satisfied by four hand-written strings and
  # would say nothing about the fifth layer somebody adds next year, so the
  # obligation is pinned at CONSTRUCTION as well: a layer cannot be declared
  # outcome-altering and silent.
  describe "the lighter obligation" do
    it "gives every outcome-altering layer a non-empty lighter" do
      altering = described_class.all.select(&:alters_outcome?)

      expect(altering).not_to be_empty
      expect(altering.map(&:lighter)).to all(satisfy { |lighter| !lighter.empty? })
    end

    # The layer the automatic approval surface answers to, so the prompt that
    # carries its lighter is telling the human something is deciding for them.
    it "declares auto_approve as outcome-altering, lit as AA" do
      expect(described_class.for(:auto_approve)).to have_attributes(alters_outcome?: true, lighter: "AA")
    end

    it "refuses to declare an outcome-altering layer with no lighter" do
      expect { described_class.new(name: :phantom, lighter: "", alters_outcome: true) }
        .to raise_error(ArgumentError, /lighter/)
    end

    it "lets a layer that cannot alter an outcome stay silent" do
      expect(described_class.new(name: :phantom, lighter: "", alters_outcome: false).lighter).to eq("")
    end
  end

  # The notify layer rings the terminal and, inside tmux, displays a message --
  # nothing outside those two -- so its lighter names the bell rather than a
  # notification some desktop daemon would be expected to show.
  describe "what the notify layer's lighter promises" do
    it "lights notify as BELL" do
      expect(described_class.for(:notify)).to have_attributes(alters_outcome?: false, lighter: "BELL")
    end
  end
end
