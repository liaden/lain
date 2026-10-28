# frozen_string_literal: true

RSpec.describe Lain::Bench::PricedRun do
  let(:model) { "claude-haiku-5-5" }
  let(:counted_class) { Lain::Bench::CompactionSweep::Live::Counted }
  let(:counted) do
    [counted_class.new(arm: "a", journal: "one", turn: 1, tokens: 100, cost: BigDecimal("0.5")),
     counted_class.new(arm: "a", journal: "one", turn: 2, tokens: 100, cost: BigDecimal("0.25")),
     counted_class.new(arm: "b", journal: "two", turn: 1, tokens: 100, cost: BigDecimal("1"))]
  end

  def priced(confirm: ->(_) { true }, unit: "lane", **rest)
    described_class.new(counted:, price_book: Lain::PriceBook.default, model:, confirm:, unit:, **rest)
  end

  describe "#preflight" do
    it "projects the cost by arm and is shareable" do
      checked = priced.preflight

      expect(checked.projected).to eq("a" => BigDecimal("0.75"), "b" => BigDecimal("1"))
      expect(Ractor.shareable?(checked)).to be(true)
    end

    it "is computed once" do
      run = priced

      expect(run.preflight).to be(run.preflight)
    end

    it "lists the requests over the model's price tier" do
      boundary = Lain::PriceBook.default.price(model).tiers.map(&:above_prompt_tokens).min
      big = counted_class.new(arm: "a", journal: "one", turn: 3, tokens: boundary + 1, cost: BigDecimal("2"))
      run = described_class.new(counted: [*counted, big], price_book: Lain::PriceBook.default, model:,
                                confirm: ->(_) { true }, unit: "lane")

      expect(run.preflight.over_tier).to eq([big])
    end
  end

  describe "#ceilings" do
    it "caps each lane at 1.5 times its projection once confirmed" do
      ceilings = priced.ceilings

      expect(ceilings.transform_values(&:dollars))
        .to eq(%w[a one] => BigDecimal("1.125"), %w[b two] => BigDecimal("1.5"))
    end

    it "hands the confirmation the preflight" do
      seen = nil
      priced(confirm: ->(checked) { (seen = checked) && true }).ceilings

      expect(seen).to be_a(Lain::Bench::CompactionSweep::Live::Preflight)
    end

    it "raises Declined with the shared wording unless confirmed" do
      expect { priced(confirm: ->(_) { false }).ceilings }
        .to raise_error(Lain::Bench::CompactionSweep::Live::Declined, Lain::Bench::CompactionSweep::Live::DECLINED)
    end

    it "keys by whatever the caller names" do
      ceilings = priced(key: :arm.to_proc).ceilings

      expect(ceilings.keys).to eq(%w[a b])
    end
  end

  describe "#halt_for" do
    let(:dollars) { Lain::Budget::Exceeded.new("over", kind: :dollars) }

    it "words the halt for its unit" do
      expect(priced(unit: "lane").halt_for(dollars)).to eq("not run: an earlier lane passed its dollar ceiling")
      expect(priced(unit: "question").halt_for(dollars))
        .to eq("not run: an earlier question passed its dollar ceiling")
    end

    it "is nil for any other stop" do
      expect(priced.halt_for(Lain::Budget::Exceeded.new("over", kind: :iterations))).to be_nil
      expect(priced.halt_for(nil)).to be_nil
      expect(priced.halt_for(RuntimeError.new("boom"))).to be_nil
    end
  end

  it "still raises ArgumentError for an unknown keyword" do
    expect { described_class.new(counted:, price_book: nil, model:, confirm: nil, unit: "lane", bogus: 1) }
      .to raise_error(ArgumentError, /bogus/)
  end
end
