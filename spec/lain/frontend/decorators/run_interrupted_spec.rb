# frozen_string_literal: true

RSpec.describe Lain::Frontend::Decorators::RunInterrupted do
  let(:theme) { Lain::Frontend::Theme.new(pastel: Pastel.new(enabled: false)) }

  def decorator(reason) = described_class.new(Lain::Telemetry::RunInterrupted.new(head: "ab", reason:))

  it "carries the failure as a note and renders nothing, the reply already said it" do
    expect([decorator(:max_tokens).note, decorator(:max_tokens).render(theme)]).to eq(["ask failed: max_tokens", nil])
  end

  it "has no note for a stop the human made" do
    expect(%i[interrupted grace_expired stopped].map { decorator(_1).note }).to all(be_nil)
  end

  it "is the decorator Decorators.for picks" do
    event = Lain::Telemetry::RunInterrupted.new(head: "ab", reason: :transport)

    expect(Lain::Frontend::Decorators.for(event)).to be_a(described_class)
  end
end
