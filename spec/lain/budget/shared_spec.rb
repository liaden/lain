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

  describe "a payment a secondary call makes" do
    def paid(tokens, dollars)
      Lain::Budget::Spent.new(usage: Lain::Usage.new(input_tokens: tokens),
                              dollars: Lain::Friction::CacheWaste::Dollars.of(BigDecimal(dollars)))
    end

    def account(ceilings)
      Lain::Budget::Account.new(ceilings:, spent: Lain::Agent::Accounting.new(spend: shared).spent)
    end

    it "adds its dollars and none of its tokens" do
      shared.pay(paid(500, "0.02"))

      expect([shared.spent.usage, shared.spent.dollars.amount]).to eq([Lain::Usage.zero, BigDecimal("0.02")])
    end

    it "refuses the next chat step on the dollar ceiling once judged calls cost more than it" do
      2.times { shared.pay(paid(700, "0.006")) }

      expect { account(Lain::Budget::Ceilings::UNLIMITED.with(dollars: BigDecimal("0.01"))).check_step!(0) }
        .to raise_error(Lain::Budget::Exceeded) { |error| expect(error.kind).to eq(:dollars) }
    end

    it "leaves the chat's token room where it was" do
      shared.pay(paid(900, "0.01"))

      expect(account(Lain::Budget::Ceilings::UNLIMITED.with(tokens: 1000)).remaining(:tokens)).to eq(1000)
    end

    it "sums to the same spend whichever order the tier and a child pay in" do
      other = described_class.new
      child = paid(150, "0.03")
      shared.pay(paid(500, "0.02"))
      shared.reserve { tokens(400) }.settle(child)
      other.reserve { tokens(400) }.settle(child)
      other.pay(paid(500, "0.02"))

      expect(shared.spent).to eq(other.spent)
    end
  end

  describe Lain::Budget::Shared::Reservation do
    def reservation(messages) = Lain::Budget::Shared.new.reserve { Lain::Budget::Ceilings::UNLIMITED.with(messages:) }

    it "counts messages up to its ceiling and refuses the next, naming messages" do
      held = reservation(2)
      2.times { held.note_message! }

      expect { held.note_message! }.to raise_error(Lain::Budget::Exceeded) { |error| expect(error.kind).to eq(:messages) }
    end

    it "never refuses a message under an unlimited ceiling" do
      held = reservation(nil)

      expect { 100.times { held.note_message! } }.not_to raise_error
    end
  end

  describe "the Unreserved" do
    it "counts nothing" do
      expect { 100.times { described_class::Unreserved.note_message! } }.not_to raise_error
    end
  end

  describe "the Null" do
    subject(:null) { described_class::Null }

    it "spends and holds nothing, whatever it is told" do
      null.reserve { tokens(400) }.settle(spent(150))

      expect([null.spent, null.reserved]).to eq([Lain::Budget::Spent.zero, 0])
    end

    it "keeps no payment" do
      null.pay(spent(150))

      expect(null.spent).to eq(Lain::Budget::Spent.zero)
    end

    it "still hands back the ceilings it was asked to grant" do
      expect(null.reserve { tokens(400) }.ceilings.tokens).to eq(400)
    end
  end
end
