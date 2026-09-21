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
end
