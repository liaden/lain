# frozen_string_literal: true

RSpec.describe Lain::Budget::Shared do
  subject(:shared) { described_class.new }

  def tokens(count) = Lain::Budget::Ceilings::UNLIMITED.with(tokens: count)

  def spent(count) = Lain::Budget::Spent.zero.with(usage: Lain::Usage.new(input_tokens: count))

  it "starts with nothing spent and nothing held" do
    expect([shared.spent, shared.reserved]).to eq([Lain::Budget::Spent.zero, 0])
  end

  it "holds a grant's tokens until it settles" do
    reservation = shared.reserve { tokens(400) }

    expect([reservation.ceilings.tokens, shared.reserved]).to eq([400, 400])
  end

  it "trades the held tokens for what the child spent when it settles" do
    shared.reserve { tokens(400) }.settle(spent(150))

    expect([shared.spent.usage.total_tokens, shared.reserved]).to eq([150, 0])
  end

  it "counts a reservation settled twice once" do
    reservation = shared.reserve { tokens(400) }
    reservation.settle(spent(150))
    reservation.settle(spent(150))

    expect([shared.spent.usage.total_tokens, shared.reserved]).to eq([150, 0])
  end

  it "frees a released reservation without spending anything" do
    shared.reserve { tokens(400) }.release

    expect([shared.spent, shared.reserved]).to eq([Lain::Budget::Spent.zero, 0])
  end

  it "holds nothing for a grant with no token ceiling, or none left" do
    shared.reserve { tokens(nil) }
    shared.reserve { tokens(-20) }

    expect(shared.reserved).to eq(0)
  end

  it "holds nothing when the grant is refused" do
    refusal = Lain::Budget::Ceilings::Unrunnable.new(:depth)

    expect { shared.reserve { raise refusal } }.to raise_error(refusal)
    expect(shared.reserved).to eq(0)
  end

  it "grants concurrent siblings no more than the room between them" do
    grant = lambda do
      shared.reserve do
        left = 1000 - shared.reserved
        sleep 0.01
        tokens([400, left].min)
      end
    end
    threads = Array.new(3) { Thread.new(&grant) }
    granted = threads.map { |thread| thread.value.ceilings.tokens }

    expect([granted.sum, shared.reserved]).to eq([1000, 1000])
  end

  describe "the Null" do
    subject(:null) { described_class::Null }

    it "spends and holds nothing, whatever it is told" do
      null.reserve { tokens(400) }.settle(spent(150))

      expect([null.spent, null.reserved]).to eq([Lain::Budget::Spent.zero, 0])
    end

    it "still hands back the ceilings it was asked to grant" do
      expect(null.reserve { tokens(400) }.ceilings.tokens).to eq(400)
    end
  end
end
