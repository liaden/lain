# frozen_string_literal: true

RSpec.describe Lain::Capability::DegradedSet do
  it "is sorted, deduplicated, and symbolized regardless of input order" do
    set = described_class.new(%i[thinking server_tools thinking])
    expect(set.to_a).to eq(%i[server_tools thinking])
  end

  it "coerces string capabilities to symbols" do
    expect(described_class.new(%w[thinking]).to_a).to eq(%i[thinking])
  end

  it "is enumerable over its capabilities" do
    expect(described_class.new(%i[b a]).map(&:to_s)).to eq(%w[a b])
  end

  it "reports emptiness" do
    expect(described_class.new([])).to be_empty
    expect(described_class.new(%i[thinking])).not_to be_empty
  end

  # Equality is one of the Regular laws; the shared group pins structural
  # equality, the eql?/hash agreement, and Hash-key + Set-dedup behavior together
  # instead of restating them by hand.
  describe "equality (Regular)" do
    include_examples "a Regular value",
                     equal_pair: lambda {
                       [Lain::Capability::DegradedSet.new(%i[thinking server_tools]),
                        Lain::Capability::DegradedSet.new(%i[server_tools thinking])]
                     },
                     unequal: -> { Lain::Capability::DegradedSet.new(%i[thinking]) },
                     non_member: -> { %i[thinking server_tools] }
  end

  # The eql?/hash contract spelled out on this type directly: DegradedSet's whole
  # reason to exist is being the key `Compare` buckets runs by, so a == pair that
  # hashed differently would scatter across buckets and Compare would miscompare.
  it "keeps ==/eql?/hash in agreement for a == pair" do
    a = described_class.new(%i[thinking server_tools])
    b = described_class.new(%i[server_tools thinking])
    expect(a).to eq(b)
    expect(a).to eql(b)
    expect(a.hash).to eq(b.hash)
    expect({ a => :found }[b]).to eq(:found)
  end

  it "is a deeply frozen, Ractor-shareable value object" do
    set = described_class.new(%i[thinking server_tools])
    expect(set).to be_frozen
    expect(Ractor.shareable?(set)).to be(true)
  end

  # to_s is the human-facing capability list; inspect keeps the class-tagged,
  # debug-oriented form (Joel's review: to_s should read for humans).
  describe "string conversions" do
    subject(:set) { described_class.new(%i[thinking server_tools]) }

    it "renders to_s as the joined capability list" do
      expect(set.to_s).to eq("server_tools, thinking")
    end

    it "keeps inspect class-tagged for debugging" do
      expect(set.inspect).to eq("#<#{described_class} server_tools, thinking>")
    end
  end
end
