# frozen_string_literal: true

RSpec.describe Lain::Compaction::Worth do
  subject(:worth) { described_class.new(floor: 0.10) }

  def rewrite(saved_percent, before: 100_000)
    Lain::Compaction::Scheduler::Rewrite.new(before:, after: before - (before * saved_percent / 100))
  end

  def anthropic_price = Lain::PriceBook.default.price("claude-sonnet-5-5")

  def weigh(saved_percent, ttl: Lain::CacheProfile::ANTHROPIC.ttl, prices: anthropic_price, steps_left: 2)
    worth.call(rewrite: rewrite(saved_percent), ttl:, prices:, steps_left:)
  end

  describe "Scenario: the trial's low-saving compactions are refused" do
    it "refuses each of the 6 recorded rewrites on a no-cache provider with below_floor" do
      verdicts = [0, 1, 1, 1, 1, 3].map do |saved|
        weigh(saved, ttl: nil, prices: nil, steps_left: nil)
      end

      expect(verdicts).to all(eq(:below_floor))
    end
  end

  describe "Scenario: a cached provider keeps its cache when the break does not pay" do
    it "refuses a 20% saving with 2 steps left with cache_break_unpaid" do
      expect(weigh(20)).to eq(:cache_break_unpaid)
    end
  end

  it "compacts a cached rewrite whose read savings over the steps left outweigh the rewrite" do
    expect(weigh(50, steps_left: 40)).to eq(:compact)
  end

  # Half dropped and half kept are the same token count, so 2 requests at half the write price
  # read back exactly what the break writes.
  it "refuses a break whose read saving over the horizon only equals its write cost" do
    even = Lain::Price.per_mtok(input: 1, output: 1, cache_creation: 1, cache_read: 0.5)

    expect(weigh(50, prices: even, steps_left: 2)).to eq(:cache_break_unpaid)
  end

  it "compacts a no-cache rewrite that passes the floor" do
    expect([weigh(20, ttl: nil), weigh(20, ttl: 0)]).to eq(%i[compact compact])
  end

  it "applies the floor only to an unlisted model" do
    expect([weigh(20, prices: nil), weigh(5, prices: nil)]).to eq(%i[compact below_floor])
  end

  it "applies the floor only when no horizon is known" do
    expect(weigh(20, steps_left: nil)).to eq(:compact)
  end

  it "applies the floor only to a price that charges nothing for a cache write" do
    free = Lain::Price.per_mtok(input: 0, output: 0, cache_creation: 0, cache_read: 0)

    expect(weigh(20, prices: free)).to eq(:compact)
  end

  it "defaults its floor to 10%" do
    floor_only = { ttl: nil, prices: nil, steps_left: nil }

    expect([described_class.new.call(rewrite: rewrite(9), **floor_only),
            described_class.new.call(rewrite: rewrite(10), **floor_only)]).to eq(%i[below_floor compact])
  end

  describe ".horizon" do
    it "is the open todos at the plan's observed requests per completed todo" do
      expect(described_class.horizon(open: 2, completed: 2, requests: 17)).to eq(17)
    end

    it "keeps a fractional rate rather than rounding it down" do
      expect(described_class.horizon(open: 1, completed: 2, requests: 3)).to eq(Rational(3, 2))
    end

    it "is unknown before any todo has completed" do
      expect(described_class.horizon(open: 2, completed: 0, requests: 9)).to be_nil
    end

    it "is unknown before any request has been counted" do
      expect(described_class.horizon(open: 2, completed: 3, requests: 0)).to be_nil
    end

    it "is unknown with no todo open" do
      expect(described_class.horizon(open: 0, completed: 3, requests: 9)).to be_nil
    end
  end
end
