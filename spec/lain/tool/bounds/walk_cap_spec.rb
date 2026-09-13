# frozen_string_literal: true

RSpec.describe Lain::Tool::Bounds::WalkCap do
  subject(:cap) { described_class.new(limit: 2) }

  # Scenario: a walk that exceeds the cap says so without naming a total
  it "cuts a walk that exceeds the cap down to exactly the limit" do
    found = cap.apply([1, 2, 3, 4, 5].lazy)

    expect(found.rows).to eq([1, 2])
    expect(found.capped).to be(true)
  end

  it "phrases the trailer without a total, unlike Enumeration#notice" do
    expect(cap.notice("matches")).to eq("... capped at 2 matches")
    expect(cap.notice("matches")).not_to match(/of \d+/)
  end

  # Scenario: a walk within the cap adds no trailer
  it "returns every row, uncapped, when the walk stays within the limit" do
    found = described_class.new(limit: 5).apply([1, 2].lazy)

    expect(found.rows).to eq([1, 2])
    expect(found.capped).to be(false)
  end

  # Scenario: the cap pulls no more than one item past its limit
  it "pulls exactly limit + 1 items off the walk and no further" do
    pulled = 0
    source = Enumerator.new do |yielder|
      loop do
        pulled += 1
        yielder << pulled
      end
    end.lazy

    cap.apply(source)

    expect(pulled).to eq(3)
  end

  it "is a deeply frozen value object" do
    expect(Ractor.shareable?(cap)).to be(true)
  end

  describe Lain::Tool::Bounds::Found do
    it "can be built directly by a caller that already knows its own capped flag" do
      found = described_class.new(rows: [1, 2], capped: true)

      expect(found.rows).to eq([1, 2])
      expect(found.capped).to be(true)
    end

    it "is a deeply frozen value object" do
      expect(Ractor.shareable?(described_class.new(rows: [1, 2].freeze, capped: false))).to be(true)
    end
  end
end
