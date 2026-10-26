# frozen_string_literal: true

# A budget stop is the harness deciding to halt (it raises), which is a different
# thing from a model `:refusal` (recorded, not raised).
RSpec.describe Lain::Budget do
  def spent(tokens: 0)
    Lain::Budget::Spent.new(usage: Lain::Usage.new(input_tokens: tokens), dollars: Lain::Friction::CacheWaste::Dollars.zero)
  end

  def account(ceilings, spent) = Lain::Budget::Account.new(ceilings:, spent:)

  describe ".ceilings" do
    it "defaults to a finite iteration ceiling so an unattended loop still stops" do
      expect(described_class.ceilings.iterations).to eq(described_class::DEFAULT_ITERATIONS)
    end

    it "leaves every other kind unlimited" do
      expect(described_class.ceilings.to_h.except(:iterations, :messages).values).to all(be_nil)
    end

    it "bounds messages by default so an actor's chatter is finite" do
      expect(described_class.ceilings.messages).to eq(64)
    end

    it "takes a message ceiling" do
      expect(described_class.ceilings(messages: 2).messages).to eq(2)
    end
  end

  describe Lain::Budget::Account do
    def ceilings(**) = Lain::Budget.ceilings(**)
    it "reports the room left under a token ceiling" do
      expect(account(ceilings(tokens: 50), spent(tokens: 40)).remaining(:tokens)).to eq(10)
    end

    it "reports unlimited room as nil" do
      expect(account(Lain::Budget::Ceilings::UNLIMITED, spent(tokens: 40)).remaining(:tokens)).to be_nil
    end

    it "is not exceeded at the ceiling" do
      expect(account(ceilings(tokens: 50), spent(tokens: 50)).exceeded?(:tokens)).to be(false)
    end

    it "is exceeded once spend passes the ceiling" do
      expect(account(ceilings(tokens: 50), spent(tokens: 51)).exceeded?(:tokens)).to be(true)
    end

    it "grants the ceilings less the iterations used, the spend and the reserve" do
      room = account(ceilings(iterations: 10, tokens: 50), spent(tokens: 20)).room(iterations_used: 4, reserved: 5)

      expect(room).to have_attributes(iterations: 6, tokens: 25, dollars: nil)
    end

    it "grants unlimited iterations and tokens as nil" do
      room = account(Lain::Budget::Ceilings.unlimited, spent(tokens: 20)).room(iterations_used: 4, reserved: 5)

      expect(room).to have_attributes(iterations: nil, tokens: nil)
    end

    it "reports the room left under a dollar ceiling" do
      priced = Lain::Budget::Spent.new(usage: Lain::Usage.zero,
                                       dollars: Lain::Friction::CacheWaste::Dollars.of(BigDecimal("0.25")))
      limited = Lain::Budget::Ceilings.unlimited.with(dollars: BigDecimal(1))

      expect(account(limited, priced).remaining(:dollars)).to eq(BigDecimal("0.75"))
    end

    describe "#check_step! under a dollar ceiling" do
      def dollars_spent(amount)
        Lain::Budget::Spent.new(usage: Lain::Usage.zero, dollars: Lain::Friction::CacheWaste::Dollars.of(BigDecimal(amount)))
      end

      let(:limited) { Lain::Budget::Ceilings.unlimited.with(dollars: BigDecimal("0.01")) }

      it "refuses the next call once the dollars are spent, naming dollars" do
        expect { account(limited, dollars_spent("0.01")).check_step!(0) }
          .to raise_error(Lain::Budget::Exceeded, /0\.01 dollars/) { |error| expect(error.kind).to eq(:dollars) }
      end

      it "lets a call through while there is room" do
        expect { account(limited, dollars_spent("0.005")).check_step!(0) }.not_to raise_error
      end
    end

    it "counts nothing spent against width and depth" do
      limited = Lain::Budget::Ceilings.unlimited.with(width: 3, depth: 2)
      held = account(limited, spent(tokens: 10))

      expect([held.remaining(:width), held.remaining(:depth)]).to eq([3, 2])
    end

    it "refuses to answer for iterations, which the Agent counts per ask" do
      expect { account(ceilings, spent).remaining(:iterations) }.to raise_error(ArgumentError, /per ask/)
      expect { account(ceilings, spent).exceeded?(:iterations) }.to raise_error(ArgumentError, /per ask/)
    end

    it "is never exceeded under an unlimited ceiling" do
      expect(account(Lain::Budget::Ceilings::UNLIMITED, spent(tokens: 10**9)).exceeded?(:tokens)).to be(false)
    end
  end

  describe Lain::Budget::Exceeded do
    it "is the harness's own halt type, not a generic error" do
      expect(described_class.new("x")).to be_a(Lain::Error)
    end

    it "names the kind of ceiling that stopped the run" do
      expect(described_class.new("loop ran 3 iterations, ceiling is 3", kind: :iterations).kind).to eq(:iterations)
    end
  end
end
