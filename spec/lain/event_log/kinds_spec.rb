# frozen_string_literal: true

RSpec.describe Lain::EventLog::Kinds do
  it "names the 4 event kinds and the 2 wire roles" do
    expect(described_class::KINDS).to eq(%i[turn spawn message snapshot])
    expect(described_class::ROLES).to contain_exactly("user", "assistant")
  end

  describe ".normalize_kind" do
    it "coerces a String kind to the canonical Symbol" do
      expect(described_class.normalize_kind("message")).to eq(:message)
    end

    it "raises a named error listing the legal kinds" do
      expect { described_class.normalize_kind(:banana) }
        .to raise_error(Lain::Error, "kind must be one of turn, spawn, message, snapshot, got :banana")
    end
  end

  describe ".normalize_role" do
    it "answers a frozen String for either wire role, given as a Symbol or a String" do
      expect(described_class.normalize_role(:user)).to eq("user")
      expect(described_class.normalize_role(:user)).to be_frozen
      expect(described_class.normalize_role("assistant")).to be_frozen
    end

    it "raises a named error for any other role" do
      expect { described_class.normalize_role("system") }
        .to raise_error(Lain::Error, 'role must be one of user, assistant, got "system"')
    end
  end
end
