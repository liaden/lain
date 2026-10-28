# frozen_string_literal: true

RSpec.describe Lain::Frontend::Decorators::AskSettled do
  let(:theme) { Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: false)) }
  let(:event) { Lain::Telemetry::AskSettled.new(head: "ab", stop_reason: :end_turn, turns: 3, seconds: 12.34) }

  it "says how the ask ended, in how many turns and how long" do
    expect(described_class.new(event).render(theme)).to eq("ask settled: end_turn after 3 turns in 12.3s")
  end

  it "says turn in the singular for one" do
    one = Lain::Telemetry::AskSettled.new(head: "ab", stop_reason: :end_turn, turns: 1, seconds: 0.5)

    expect(described_class.new(one).render(theme)).to eq("ask settled: end_turn after 1 turn in 0.5s")
  end

  it "is a stamped line" do
    decorator = described_class.new(event)

    expect([decorator.line_shaped?, decorator.stamped?]).to eq([true, true])
  end

  it "paints through the label token, which is dim" do
    pastel = Pastel.new(enabled: true)
    painted = described_class.new(event).render(Lain::Frontend::Theme.new(pastel:))

    expect(painted).to eq(pastel.dim("ask settled: end_turn after 3 turns in 12.3s"))
  end

  it "is the decorator Decorators.for picks" do
    expect(Lain::Frontend::Decorators.for(event)).to be_a(described_class)
  end
end
