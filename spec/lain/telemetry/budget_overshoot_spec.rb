# frozen_string_literal: true

RSpec.describe Lain::Telemetry::BudgetOvershoot do
  let(:ceilings) { Lain::Budget.ceilings.with(dollars: BigDecimal("0.10")) }
  let(:journal) { [] }

  def spent_of(amount, complete: true)
    dollars = Lain::Friction::CacheWaste::Dollars.zero
    dollars += Lain::Friction::CacheWaste::Dollars.new(amount: BigDecimal(amount), complete:)
    Lain::Budget::Spent.zero.with(dollars:)
  end

  def check(spent) = described_class.check!(ceilings, spent, journal:, model: "claude-opus-4-8")

  it "journals the figures as fixed-point strings and is deeply frozen" do
    record = described_class.new(ceiling: BigDecimal("0.10"), spent: BigDecimal("0.13"),
                                 overshoot: BigDecimal("0.03"), model: "claude-opus-4-8", complete: true)

    expect(record.to_journal).to eq("type" => "budget_overshoot", "ceiling" => "0.1", "spent" => "0.13",
                                    "overshoot" => "0.03", "model" => "claude-opus-4-8", "complete" => true)
    expect(Ractor.shareable?(record)).to be(true)
  end

  it "journals byte for byte" do
    record = described_class.new(ceiling: BigDecimal("0.10"), spent: BigDecimal("0.13"),
                                 overshoot: BigDecimal("0.03"), model: "claude-opus-4-8", complete: false)

    expect(JSON.generate(record.to_journal)).to eq(
      '{"type":"budget_overshoot","ceiling":"0.1","spent":"0.13","overshoot":"0.03",' \
      '"model":"claude-opus-4-8","complete":false}'
    )
  end

  it "shares the model String across equal records" do
    build = -> { described_class.new(ceiling: 1, spent: 2, overshoot: 1, model: +"claude-opus-4-8", complete: true) }

    expect(build.call.model).to equal(build.call.model)
  end

  it "reads a truthy complete as true" do
    record = described_class.new(ceiling: 1, spent: 2, overshoot: 1, model: "m", complete: "yes")

    expect(record.complete).to be(true)
  end

  it "refuses an unknown keyword" do
    expect { described_class.new(ceiling: 1, spent: 2, overshoot: 1, model: "m", complete: true, extra: 1) }
      .to raise_error(ArgumentError, /extra/)
  end

  it "records the overshoot, then raises Exceeded" do
    expect { check(spent_of("0.13")) }.to raise_error(Lain::Budget::Exceeded)
    expect(journal.map(&:to_journal)).to eq([{ "type" => "budget_overshoot", "ceiling" => "0.1", "spent" => "0.13",
                                               "overshoot" => "0.03", "model" => "claude-opus-4-8",
                                               "complete" => true }])
  end

  it "names unpriced turns with complete: false" do
    expect { check(spent_of("0.13", complete: false)) }.to raise_error(Lain::Budget::Exceeded)
    expect(journal.first.complete).to be(false)
  end

  it "writes nothing while spend is within the ceiling" do
    check(spent_of("0.10"))
    expect(journal).to be_empty
  end

  it "writes nothing and passes when no dollar ceiling is set" do
    described_class.check!(Lain::Budget.ceilings, spent_of("5"), journal:, model: "m")
    expect(journal).to be_empty
  end
end
