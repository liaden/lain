# frozen_string_literal: true

module CeilingsPopulations
  module_function

  # Every nil-or-finite mix across the 5 fields, plus 2 whose finite values differ,
  # so a per-field min is read against unequal numbers as well as equal ones.
  def population
    mixes = [[nil, 2], [nil, 100], [nil, BigDecimal("0.5")], [nil, 3], [nil, 1]].reduce([[]]) do |rows, choices|
      rows.product(choices).map { |row, choice| row + [choice] }
    end
    (mixes + [[5, 200, BigDecimal("1.5"), 7, 4], [1, 50, BigDecimal("0.25"), 1, 9]])
      .map { |fields| Lain::Budget::Ceilings.new(*fields) }
  end

  def at_least_as_tight?(tight, loose)
    bounds = loose.to_h
    tight.to_h.all? { |kind, value| bounds[kind].nil? || (!value.nil? && value <= bounds[kind]) }
  end
end

RSpec.describe Lain::Budget::Ceilings do
  def ceilings(**fields)
    described_class.new(**described_class::UNLIMITED.to_h, **fields)
  end

  describe "the meet semilattice laws, with unlimited as the top" do
    population = CeilingsPopulations.population

    it "has unlimited as the top" do
      expect(population.all? { |c| c == c.meet(described_class::UNLIMITED) }).to be(true)
    end

    context "when every pair and triple is read" do
      pairs = population.product(population)

      it "is idempotent" do
        expect(population.find { |a| a.meet(a) != a }).to be_nil
      end

      it "is commutative" do
        expect(pairs.find { |a, b| a.meet(b) != b.meet(a) }).to be_nil
      end

      it "is associative" do
        triples = pairs.product(population).map(&:flatten)
        expect(triples.find { |a, b, c| a.meet(b).meet(c) != a.meet(b.meet(c)) }).to be_nil
      end

      it "orders a meet below both operands" do
        tight = CeilingsPopulations.method(:at_least_as_tight?)
        expect(pairs.find { |a, b| !(tight.call(a.meet(b), a) && tight.call(a.meet(b), b)) }).to be_nil
      end
    end

    include_examples "a meet semilattice",
                     population: -> { population },
                     ancestor_of: ->(tight, loose) { CeilingsPopulations.at_least_as_tight?(tight, loose) }
  end

  describe "#attenuate" do
    it "inherits the holder's room where the request is nil" do
      child = ceilings(tokens: 1000).attenuate(ceilings)

      expect(child.tokens).to eq(1000)
    end

    it "grants the iterations requested even above the holder's remaining room" do
      child = ceilings(iterations: 5).attenuate(ceilings(iterations: 25))

      expect(child.iterations).to eq(25)
    end

    it "still clamps tokens to the holder's remaining room" do
      child = ceilings(tokens: 1000).attenuate(ceilings(tokens: 10_000))

      expect(child.tokens).to eq(1000)
    end

    it "inherits the holder's iterations where the request is nil" do
      expect(ceilings(iterations: 5).attenuate(ceilings).iterations).to eq(5)
    end

    it "grants a request below the remaining room" do
      child = ceilings(iterations: 5).attenuate(ceilings(iterations: 3))

      expect(child.iterations).to eq(3)
    end

    it "decrements a finite depth" do
      expect(ceilings(depth: 3).attenuate(ceilings).depth).to eq(2)
    end

    it "leaves an unlimited depth unlimited" do
      expect(ceilings(iterations: 5).attenuate(ceilings).depth).to be_nil
    end

    it "refuses a holder with no iterations left, naming iterations" do
      expect { ceilings(iterations: 0).attenuate(ceilings) }
        .to raise_error(described_class::Unrunnable, /iterations/)
    end

    it "grants a role's request to a holder with no iterations left, which only a nil request refuses" do
      expect(ceilings(iterations: 0).attenuate(ceilings(iterations: 60)).iterations).to eq(60)
    end

    it "bounds recursion by depth, since an unclamped child can still try to spawn" do
      child = ceilings(iterations: 5, depth: 1).attenuate(ceilings(iterations: 60))

      expect { child.attenuate(ceilings(iterations: 60)) }.to raise_error(described_class::Unrunnable, /depth/)
    end

    it "refuses a request for no iterations, naming iterations" do
      expect { ceilings(iterations: 5).attenuate(ceilings(iterations: 0)) }
        .to raise_error(described_class::Unrunnable, /iterations/)
    end

    it "refuses a holder with no depth left, naming depth" do
      expect { ceilings(depth: 0).attenuate(ceilings) }
        .to raise_error(described_class::Unrunnable, /depth/)
    end

    it "grants a holder at depth 1 a child at depth 0, which runs but cannot spawn" do
      expect(ceilings(depth: 1).attenuate(ceilings).depth).to eq(0)
    end

    it "does not refuse for a ceiling other than iterations or depth being 0" do
      expect(ceilings(tokens: 0).attenuate(ceilings).tokens).to eq(0)
    end

    it "is a Lain::Error" do
      expect(described_class::Unrunnable.ancestors).to include(Lain::Error)
    end
  end

  describe "#descend" do
    it "decrements depth where finite and never below 0" do
      expect([ceilings(depth: 2).descend.depth, ceilings(depth: 0).descend.depth]).to eq([1, 0])
    end
  end

  it "is deeply frozen" do
    expect(Ractor.shareable?(described_class::UNLIMITED)).to be(true)
  end
end
