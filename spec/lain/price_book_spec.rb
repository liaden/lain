# frozen_string_literal: true

require "bigdecimal"

RSpec.describe Lain::PriceBook do
  def usage(input: 0, output: 0, creation: 0, read: 0)
    Lain::Usage.new(input_tokens: input, output_tokens: output,
                    cache_creation_input_tokens: creation, cache_read_input_tokens: read)
  end

  describe Lain::Price do
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
  end

  describe "#cost" do
    subject(:book) { described_class.default }

    it "prices a known family" do
      cost = book.cost("claude-sonnet-4", usage(input: 1_000_000))
      expect(cost).to eq(BigDecimal("3"))
    end

    it "matches a dated snapshot by its family token" do
      exact = book.cost("sonnet", usage(input: 1_000_000))
      dated = book.cost("claude-3-5-sonnet-20241022", usage(input: 1_000_000))
      expect(dated).to eq(exact)
    end

    it "prefers the longest matching family token" do
      book = described_class.new(prices: {
                                   "opus" => Lain::Price.per_mtok(input: 15, output: 75, cache_creation: 0,
                                                                  cache_read: 0),
                                   "claude-opus-4" => Lain::Price.per_mtok(input: 20, output: 100, cache_creation: 0,
                                                                           cache_read: 0)
                                 })
      expect(book.cost("claude-opus-4-8", usage(input: 1_000_000))).to eq(BigDecimal("20"))
    end
  end

  describe "an unknown model" do
    it "raises rather than silently pricing at zero" do
      expect { described_class.default.cost("gpt-4", usage(input: 10)) }
        .to raise_error(described_class::UnknownModel)
    end

    it "uses an explicit fallback when one is configured" do
      fallback = Lain::Price.per_mtok(input: 1, output: 1, cache_creation: 0, cache_read: 0)
      book = described_class.new(prices: {}, fallback:)
      expect(book.cost("anything", usage(input: 1_000_000))).to eq(BigDecimal("1"))
    end
  end
end
