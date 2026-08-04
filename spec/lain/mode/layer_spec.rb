# frozen_string_literal: true

RSpec.describe Lain::Mode::Layer do
  describe "the declared family" do
    it "names its layers as a closed, public set" do
      expect(described_class::NAMES).to eq(%i[auto_approve goal notify vi])
    end

    it "answers a declared name with that layer" do
      expect(described_class.for(:goal)).to have_attributes(name: :goal)
    end

    it "answers the same value however the name is spelled" do
      expect(described_class.for("goal")).to eq(described_class.for(:goal))
    end

    it "refuses an undeclared name, naming every alternative" do
      expect { described_class.for(:nonsense) }
        .to raise_error(ArgumentError, /nonsense.*auto_approve.*goal.*notify.*vi/)
    end

    it "is a deeply frozen value" do
      expect(described_class.for(:vi)).to be_deeply_frozen
    end
  end

  # Scenario: a layer that can change an outcome renders a lighter.
  #
  # The roster check alone would be satisfied by four hand-written strings and
  # would say nothing about the fifth layer somebody adds next year, so the
  # obligation is pinned at CONSTRUCTION as well: a layer cannot be declared
  # outcome-altering and silent.
  describe "the lighter obligation" do
    it "gives every outcome-altering layer a non-empty lighter" do
      altering = described_class.all.select(&:alters_outcome?)

      expect(altering).not_to be_empty
      expect(altering.map(&:lighter)).to all(satisfy { |lighter| !lighter.empty? })
    end

    it "refuses to declare an outcome-altering layer with no lighter" do
      expect { described_class.new(name: :phantom, lighter: "", alters_outcome: true) }
        .to raise_error(ArgumentError, /lighter/)
    end

    it "lets a layer that cannot alter an outcome stay silent" do
      expect(described_class.new(name: :phantom, lighter: "", alters_outcome: false).lighter).to eq("")
    end
  end
end

RSpec.describe Lain::Mode::LayerSet do
  # Every member is built from its underlying NAMES, never by folding `#|` or
  # `#enable` over a seed. Building the population through the operation under
  # test is how a law sweep certifies nothing: make `#|` left-absorbing and a
  # population grown by `reduce(empty, :|)` collapses to the unit, so both laws
  # hold vacuously and the sweep stays green. Construct, then operate.
  def layer_set(*names) = described_class.new(names)

  def sample_set
    described_class.new(Lain::Mode::Layer::NAMES.select { rand < 0.5 })
  end

  # Scenario: enabling layers in either order gives the same set
  it "reaches the same set however the enables were ordered" do
    expect(described_class.empty.enable(:goal).enable(:notify))
      .to eq(described_class.empty.enable(:notify).enable(:goal))
  end

  # Scenario: enabling twice changes nothing
  it "is unchanged by enabling a layer it already holds" do
    held = layer_set(:goal)

    expect(held.enable(:goal)).to eq(held)
  end

  # Scenario: disabling a layer that was never enabled is not an error
  it "treats disabling an absent layer as a no-op" do
    expect(described_class.empty.disable(:goal)).to eq(described_class.empty)
  end

  it "returns a set that is still empty after that no-op" do
    expect(described_class.empty.disable(:goal)).to be_empty
  end

  # The Gherkin covers only disable's two edge cases -- the absent layer and
  # the undeclared name -- so without these two the happy path is proven by
  # nothing and a `#disable` that removes nothing ships green. It is the other
  # half of the `/mode -goal` pair T3 and T4 build on.
  it "removes a layer the set actually holds" do
    expect(layer_set(:goal, :vi).disable(:goal)).to eq(layer_set(:vi))
  end

  it "leaves the other layers alone while doing it" do
    expect(layer_set(:auto_approve, :goal, :vi).disable(:goal).to_a).to eq(%i[auto_approve vi])
  end

  # Scenario: an unknown layer name fails loudly
  it "refuses to enable an undeclared layer, naming the declared ones" do
    expect { described_class.empty.enable(:nonsense) }
      .to raise_error(ArgumentError, /nonsense.*auto_approve.*goal.*notify.*vi/)
  end

  it "refuses to disable an undeclared layer too" do
    expect { described_class.empty.disable(:nonsense) }.to raise_error(ArgumentError, /nonsense/)
  end

  it "refuses to be constructed from an undeclared layer" do
    expect { layer_set(:goal, :nonsense) }.to raise_error(ArgumentError, /nonsense/)
  end

  describe "the value it is" do
    it "is equal to a set built in the opposite order" do
      expect(layer_set(:vi, :goal)).to eq(layer_set(:goal, :vi))
    end

    it "hashes equal to that set, so it can key a Hash" do
      expect({ layer_set(:vi, :goal) => :held }[layer_set(:goal, :vi)]).to eq(:held)
    end

    it "collapses a repeated name" do
      expect(layer_set(:goal, :goal).to_a).to eq(%i[goal])
    end

    # Derived from NAMES rather than written out, because a hardcoded
    # `%i[auto_approve goal vi]` is satisfied by a `.sort` just as well as by
    # the canonicalizing `select` -- see the canary below.
    it "canonicalizes any permutation back to declaration order" do
      expect(layer_set(*Lain::Mode::Layer::NAMES.reverse).to_a).to eq(Lain::Mode::Layer::NAMES)
    end

    # A canary, not a requirement. Today's roster happens to be alphabetical,
    # so nothing here can tell declaration order from a sort. T3 reads this
    # order as PRECEDENCE, so the day a layer is declared out of alphabetical
    # position this goes red and says that the example above stopped being a
    # proof of anything.
    it "records that declaration order and alphabetical order still coincide" do
      expect(Lain::Mode::Layer::NAMES).to eq(Lain::Mode::Layer::NAMES.sort)
    end

    it "is not equal to a bare Array of the same names" do
      expect(layer_set(:goal)).not_to eq(%i[goal])
    end

    # The `instance_of?` guard, pinned rather than only argued for in the
    # comment beside it. An `is_a?` guard passes the subclass example one way
    # and fails it the other; a `respond_to?(:names)` duck-test passes both and
    # fails the Struct. The owed convergence of DegradedSet and
    # ContentAddressed onto `instance_of?` must not drag this class backwards
    # silently.
    it "is not equal to a subclass instance holding the same layers" do
      expect(layer_set(:goal)).not_to eq(Class.new(described_class).new([:goal]))
    end

    it "is unequal in the other direction too, so equality stays symmetric" do
      expect(Class.new(described_class).new([:goal])).not_to eq(layer_set(:goal))
    end

    it "is not equal to a duck that merely answers #names" do
      expect(layer_set(:goal)).not_to eq(Struct.new(:names).new(%i[goal]))
    end

    it "renders the layer values behind its names" do
      expect(layer_set(:goal).layers.map(&:lighter)).to eq([Lain::Mode::Layer.for(:goal).lighter])
    end

    it "is a deeply frozen value" do
      expect(layer_set(:goal, :vi)).to be_deeply_frozen
    end
  end

  # `#enable`/`#disable` reconstructing through `.new` rather than delegating to
  # `#|` is what keeps the order-independence scenarios above and the union laws
  # below INDEPENDENT claims -- the anti-vacuity guarantee this card rests on.
  # A comment cannot hold that: routing `#enable` through `#|` leaves every
  # other example in this file green. A subclass with a degenerate union is what
  # holds it.
  describe "the decoupling of enable/disable from #|" do
    let(:degenerate) { Class.new(described_class) { def |(_other) = self.class.empty } }

    it "still enables when #| has been gutted" do
      expect(degenerate.new([:goal]).enable(:vi).to_a).to eq(%i[goal vi])
    end

    it "still disables when #| has been gutted" do
      expect(degenerate.new(%i[goal vi]).disable(:goal).to_a).to eq(%i[vi])
    end
  end

  # Emacs states order-independence as a convention; here it is a property.
  # `#|` is union, so it is a commutative, idempotent monoid whose unit is the
  # empty set -- BOTH groups, because the commutative group alone does not test
  # the unit, and a `#|` that answered `empty` for everything would satisfy
  # commutativity while destroying every layer the human enabled.
  describe "the union laws" do
    random_layer_set = -> { sample_set }

    include_examples "a monoid",
                     operation: ->(a, b) { a | b },
                     identity: described_class.empty,
                     generator: random_layer_set

    include_examples "a commutative monoid",
                     operation: ->(a, b) { a | b },
                     generator: random_layer_set

    # Idempotence rests ENTIRELY on this example: neither shared group above
    # can prove it. Symmetric difference is an associative, commutative monoid
    # with the empty set as its unit and sails through both, so a reader must
    # not take `commutative_monoid` as covering the third law.
    #
    # Unioned with a SEPARATE object holding the same layers rather than with
    # itself: `a | a` trips Lint/BinaryOperatorWithIdenticalOperands, and the
    # two-object form is the stronger claim anyway -- it cannot be satisfied by
    # an `#|` that merely recognizes its own receiver.
    it "is idempotent" do
      50.times do
        drawn = sample_set
        expect(drawn | described_class.new(drawn.to_a)).to eq(drawn)
      end
    end

    # The falsification guard for the two groups above: a population of
    # identical or empty draws makes every law hold of nothing.
    it "draws a population that is neither constant nor uniformly empty" do
      drawn = Array.new(50) { sample_set }

      expect(drawn.uniq.size).to be > 1
      expect(drawn.reject(&:empty?)).not_to be_empty
    end

    it "unions to the set holding both operands' layers" do
      expect((layer_set(:goal) | layer_set(:vi)).to_a).to eq(%i[goal vi])
    end
  end
end
