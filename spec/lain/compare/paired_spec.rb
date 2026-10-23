# frozen_string_literal: true

RSpec.describe Lain::Compare::Paired do
  def paired(values_by_task) = described_class.of(baseline: "single", candidate: "orchestrator", values_by_task:)

  it "takes differences as candidate minus baseline for each shared task" do
    result = paired(1 => [0.5, 0.6], 2 => [0.5, 0.7], 3 => [0.9, 0.8])

    expect(result.pairs.values).to match([be_within(1e-9).of(0.1), be_within(1e-9).of(0.2), be_within(1e-9).of(-0.1)])
    expect(result.mean_difference).to be_within(1e-9).of(0.2 / 3)
  end

  it "counts wins, losses and ties" do
    result = paired(1 => [0.5, 0.6], 2 => [0.5, 0.5], 3 => [0.9, 0.8], 4 => [0.1, 0.9])

    expect([result.wins, result.losses, result.ties]).to eq([2, 1, 1])
  end

  it "gives the interval of the differences" do
    result = paired(1 => [0.0, 0.1], 2 => [0.0, 0.2], 3 => [0.0, 0.3])

    expect(result.interval.low).to be_within(5e-5).of(-0.0484)
    expect(result.interval.high).to be_within(5e-5).of(0.4484)
  end

  it "has no interval from a single pair" do
    expect(paired(1 => [0.0, 0.1]).interval).to be_nil
  end

  it "leaves a task out of the pairs when a side carries a reason instead of a value" do
    result = paired(1 => [0.5, 0.6], 2 => [0.5, "ceiling"], 3 => ["malformed", 0.7])

    expect(result.pairs.keys).to eq([1])
    expect(result.unpaired).to eq(2 => "ceiling", 3 => "malformed")
  end

  it "has no mean difference without pairs" do
    expect(paired(1 => [0.5, "ceiling"]).mean_difference).to be_nil
  end

  it "names both arms" do
    result = paired(1 => [0.5, 0.6])

    expect([result.baseline, result.candidate]).to eq(%w[single orchestrator])
  end

  it "is deeply frozen" do
    expect(Ractor.shareable?(paired(1 => [0.5, 0.6], 2 => [0.5, "ceiling"]))).to be(true)
  end
end
