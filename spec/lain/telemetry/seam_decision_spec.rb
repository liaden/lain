# frozen_string_literal: true

require "bigdecimal"
require "json"

RSpec.describe Lain::Telemetry::SeamDecision do
  def record(**overrides)
    described_class.new(size: "L", estimated_turns: 13, calibrated: true, bytes_removed: 8_000, bytes_after: 2_000,
                        rewrite_cost: BigDecimal("0.003125"), payback: BigDecimal("0.013"),
                        verdict: :rewrite_now, **overrides)
  end

  it "journals byte for byte" do
    expect(JSON.generate(record.to_journal)).to eq(
      '{"type":"seam_decision","size":"L","estimated_turns":13,"calibrated":true,"bytes_removed":8000,' \
      '"bytes_after":2000,"rewrite_cost":"0.003125","payback":"0.013","verdict":"rewrite_now"}'
    )
  end

  it "journals a fractional estimate and a deferral" do
    expect(JSON.generate(record(estimated_turns: 2.5, calibrated: false, verdict: "defer").to_journal)).to eq(
      '{"type":"seam_decision","size":"L","estimated_turns":2.5,"calibrated":false,"bytes_removed":8000,' \
      '"bytes_after":2000,"rewrite_cost":"0.003125","payback":"0.013","verdict":"defer"}'
    )
  end

  it "shares the size String across equal records" do
    expect(record(size: +"M").size).to equal(record(size: +"M").size)
  end

  it "is deeply frozen" do
    expect(record).to be_deeply_frozen
  end

  it "refuses a size outside S, M and L" do
    expect { record(size: "XL") }.to raise_error(ArgumentError, %r{size.*S/M/L.*XL})
  end

  it "refuses a verdict outside rewrite_now and defer" do
    expect { record(verdict: :maybe) }.to raise_error(ArgumentError, /verdict/)
  end

  it "refuses an unquoted side by name" do
    expect { record(rewrite_cost: nil) }.to raise_error(ArgumentError, /rewrite_cost must quote/)
    expect { record(payback: nil) }.to raise_error(ArgumentError, /payback must quote/)
  end

  it "refuses an unknown keyword" do
    expect { record(extra: 1) }.to raise_error(ArgumentError, /extra/)
  end
end
