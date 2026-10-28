# frozen_string_literal: true

require "json"

RSpec.describe Lain::Telemetry::Tripwire do
  def counted(**overrides)
    described_class.new(requester: "dev-1", signal: "refused_exec", weight: "high", score: 5, stop: "would_stop",
                        evidence: [{ "signal" => "refused_exec", "weight" => "high" }], **overrides)
  end

  it "journals byte for byte" do
    expect(JSON.generate(counted.to_journal))
      .to eq('{"type":"tripwire","requester":"dev-1","signal":"refused_exec","weight":"high","score":5,' \
             '"stop":"would_stop","evidence":[{"signal":"refused_exec","weight":"high"}]}')
  end

  it "shares the bytes of every interned field between 2 equal records" do
    one = counted(requester: +"dev-1", signal: +"refused_exec", weight: +"high", stop: +"would_stop")
    other = counted(requester: +"dev-1", signal: +"refused_exec", weight: +"high", stop: +"would_stop")

    expect(%i[requester signal weight stop].map { one.public_send(_1).equal?(other.public_send(_1)) })
      .to eq([true, true, true, true])
  end

  it "is shareable when built from mutable evidence" do
    expect(counted(evidence: [{ "signal" => +"refused_exec" }])).to be_deeply_frozen
  end

  it "refuses an unknown keyword as an ArgumentError" do
    expect { counted(extra: 1) }.to raise_error(ArgumentError, /extra/)
  end
end
