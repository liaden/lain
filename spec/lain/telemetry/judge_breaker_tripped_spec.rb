# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::JudgeBreakerTripped do
  def tripped(**overrides) = described_class.new(requester: "dev-1", count: 3, because: "3 in a row", **overrides)

  it "journals byte for byte" do
    expect(JSON.generate(tripped.to_journal))
      .to eq('{"type":"judge_breaker_tripped","requester":"dev-1","count":3,"because":"3 in a row"}')
  end

  it "shares the bytes of every interned field between 2 equal records and is shareable" do
    one = tripped(requester: +"dev-1", because: +"3 in a row")
    other = tripped(requester: +"dev-1", because: +"3 in a row")

    expect([one.requester.equal?(other.requester), one.because.equal?(other.because)]).to eq([true, true])
    expect(one).to be_deeply_frozen
  end

  it "counts in Integers, refusing text that is no number" do
    expect(tripped(count: "20").count).to eq(20)
    expect { tripped(count: "many") }.to raise_error(ArgumentError)
  end

  it "refuses an unknown keyword as an ArgumentError" do
    expect { tripped(extra: 1) }.to raise_error(ArgumentError, /extra/)
  end
end
