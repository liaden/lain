# frozen_string_literal: true

RSpec.describe Lain::Telemetry::RoundBounded do
  def record(**over)
    described_class.new(head: "blake3:h", basis: "window", budget: 100, delivered: ["a"], deduplicated: ["b"],
                        withheld: ["c"], **over)
  end

  it "journals under its own type with every field" do
    expect(record.to_journal).to eq("type" => "round_bounded", "head" => "blake3:h", "basis" => "window",
                                    "budget" => 100, "delivered" => ["a"], "deduplicated" => ["b"],
                                    "withheld" => ["c"])
  end

  it "is shareable across Ractors, even when built from mutable strings" do
    expect(record(head: +"blake3:h", basis: +"window", delivered: [+"a"])).to be_deeply_frozen
  end

  it "keeps an absent head absent" do
    expect(record(head: nil).head).to be_nil
  end

  it "takes the budget as an integer" do
    expect(record(budget: "100").budget).to eq(100)
  end
end
