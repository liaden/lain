# frozen_string_literal: true

RSpec.describe Lain::Price do
  def usage(input: 0, output: 0, creation: 0, read: 0)
    Lain::Usage.new(input_tokens: input, output_tokens: output,
                    cache_creation_input_tokens: creation, cache_read_input_tokens: read)
  end

  it "prices each token class at its own per-million rate, in BigDecimal" do
    price = described_class.per_mtok(input: 3, output: 15, cache_creation: 3.75, cache_read: 0.3)
    cost = price.cost(usage(input: 1_000_000, output: 1_000_000, creation: 1_000_000, read: 1_000_000))
    expect(cost).to be_a(BigDecimal)
    expect(cost).to eq(BigDecimal("22.05"))
  end

  # Float would accumulate error across a session; a fractional-cent price times
  # a large token count must be exact.
  it "is exact where Float would drift" do
    price = described_class.per_mtok(input: 0.1, output: 0, cache_creation: 0, cache_read: 0)
    expect(price.cost(usage(input: 3))).to eq(BigDecimal("0.0000003"))
  end

  it "answers itself as the rate of a row with no tiers and no off-peak window" do
    flat = described_class.per_mtok(input: 1, output: 1, cache_creation: 0, cache_read: 0)
    expect(flat.rate_for(usage(input: 10), at: Time.utc(2026, 10, 25))).to be(flat)
  end

  describe "a prompt-size tier" do
    let(:tiered) do
      described_class.per_mtok(
        input: 0.10, output: 0.50, cache_creation: 0.125, cache_read: 0.01,
        tiers: [Lain::Price::Tier.new(
          above_prompt_tokens: 100_000,
          price: described_class.per_mtok(input: 0.50, output: 2.50, cache_creation: 0.625, cache_read: 0.05)
        )]
      )
    end

    it "bills a prompt exactly at the boundary at the base rate" do
      expect(tiered.cost(usage(input: 100_000))).to eq(BigDecimal("0.010"))
    end

    it "bills every token class at the tier rate once the whole prompt crosses the boundary" do
      cost = tiered.cost(usage(input: 60_000, read: 30_000, creation: 20_000, output: 10_000))
      expect(cost).to eq(BigDecimal("0.03") + BigDecimal("0.0015") + BigDecimal("0.0125") + BigDecimal("0.025"))
    end

    it "answers the flat rate one request is billed at" do
      rate = tiered.rate_for(usage(input: 110_000))
      expect(rate).to have_attributes(input: BigDecimal("0.5") / 1_000_000, tiers: [], off_peak: nil)
    end

    it "answers a flat rate below the boundary too" do
      expect(tiered.rate_for(usage(input: 90_000))).to have_attributes(tiers: [], off_peak: nil)
    end

    it "bills the highest tier the prompt passes, whatever order the tiers were given in" do
      two = described_class.per_mtok(
        input: 1, output: 0, cache_creation: 0, cache_read: 0,
        tiers: [
          Lain::Price::Tier.new(above_prompt_tokens: 200_000,
                                price: described_class.per_mtok(input: 3, output: 0, cache_creation: 0, cache_read: 0)),
          Lain::Price::Tier.new(above_prompt_tokens: 100_000,
                                price: described_class.per_mtok(input: 2, output: 0, cache_creation: 0, cache_read: 0))
        ]
      )
      expect(two.cost(usage(input: 1_000_000))).to eq(BigDecimal("3"))
    end

    it "refuses a tier whose price carries tiers of its own" do
      nested = Lain::Price::Tier.new(above_prompt_tokens: 1, price: tiered)
      expect { described_class.per_mtok(input: 0.1, output: 0, cache_creation: 0, cache_read: 0, tiers: [nested]) }
        .to raise_error(ArgumentError, /tier/)
    end

    it "refuses a tier whose price carries an off-peak row" do
      windowed = described_class.per_mtok(input: 0.5, output: 0, cache_creation: 0, cache_read: 0,
                                          off_peak: Lain::Price::OffPeak.new(price: tiered.rate_for(usage)))
      nested = Lain::Price::Tier.new(above_prompt_tokens: 1, price: windowed)
      expect { described_class.per_mtok(input: 0.1, output: 0, cache_creation: 0, cache_read: 0, tiers: [nested]) }
        .to raise_error(ArgumentError, /tier/)
    end

    it "stays a shareable value with an off-peak window beside it" do
      half = described_class.per_mtok(input: 0.05, output: 0.25, cache_creation: 0, cache_read: 0)
      price = tiered.with(off_peak: Lain::Price::OffPeak.new(price: half))
      expect(Ractor.shareable?(price)).to be(true)
    end
  end

  describe "an off-peak window" do
    let(:windowed) do
      described_class.per_mtok(
        input: 1, output: 0, cache_creation: 0, cache_read: 0,
        off_peak: Lain::Price::OffPeak.new(
          price: described_class.per_mtok(input: 0.5, output: 0, cache_creation: 0, cache_read: 0)
        )
      )
    end
    let(:million) { usage(input: 1_000_000) }

    it "bills the standard rate inside the weekday peak" do
      expect(windowed.cost(million, at: Time.utc(2026, 10, 21, 14))).to eq(BigDecimal("1"))
    end

    it "bills the off-peak rate on a weekday evening" do
      expect(windowed.cost(million, at: Time.utc(2026, 10, 21, 20))).to eq(BigDecimal("0.5"))
    end

    it "bills the off-peak rate all weekend" do
      expect(windowed.cost(million, at: Time.utc(2026, 10, 24, 14))).to eq(BigDecimal("0.5"))
    end

    it "reads the window in UTC whatever the zone of the time given" do
      expect(windowed.cost(million, at: Time.new(2026, 10, 21, 16, 0, 0, "-05:00"))).to eq(BigDecimal("0.5"))
    end

    it "bills the peak rate from 12:00 to just before 18:00 UTC on a weekday" do
      at = ->(hour, minute, second) { Time.utc(2026, 10, 21, hour, minute, second) }
      times = [at[11, 59, 59], at[12, 0, 0], at[17, 59, 59], at[18, 0, 0]]
      costs = times.map { |time| windowed.cost(million, at: time) }
      expect(costs).to eq([BigDecimal("0.5"), BigDecimal("1"), BigDecimal("1"), BigDecimal("0.5")])
    end

    it "bills the off-peak row alone in its window, so the base row's tiers do not apply there" do
      tiered = windowed.with(tiers: [Lain::Price::Tier.new(
        above_prompt_tokens: 100_000,
        price: described_class.per_mtok(input: 4, output: 0, cache_creation: 0, cache_read: 0)
      )])
      expect(tiered.cost(million, at: Time.utc(2026, 10, 25, 9))).to eq(BigDecimal("0.5"))
    end

    it "refuses an off-peak row that carries an off-peak row of its own" do
      nested = Lain::Price::OffPeak.new(price: windowed)
      expect { described_class.per_mtok(input: 1, output: 0, cache_creation: 0, cache_read: 0, off_peak: nested) }
        .to raise_error(ArgumentError, /off-peak/)
    end

    it "bills the standard rate when no request time is known" do
      expect(windowed.cost(million, at: nil)).to eq(BigDecimal("1"))
    end
  end
end
