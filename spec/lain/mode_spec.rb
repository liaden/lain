# frozen_string_literal: true

RSpec.describe Lain::Mode do
  # Layer::NAMES is declaration order, and today that happens to coincide with
  # alphabetical order (mode/layer_spec.rb pins that coincidence with its own
  # canary). Deriving the expectation from NAMES rather than writing
  # `%i[auto_approve goal]` by hand is what makes this spec a proof of
  # PRECEDENCE and not a proof that RSpec can sort an Array -- if a fifth layer
  # ever lands out of alphabetical position, this still passes and a
  # hand-written literal would not have.
  let(:enabled_names) { %i[goal auto_approve] }
  let(:precedence_order) { Lain::Mode::Layer::NAMES.select { |name| enabled_names.include?(name) } }

  describe "construction" do
    it "is a scope, an approval level and a set of layers" do
      mode = described_class.new(scope: :checkout, approval: :auto, layers: %i[notify goal])

      expect(mode.scope).to be(Lain::Mode::Scope.for(:checkout))
      expect(mode.approval).to be(Lain::Mode::Approval.for(:auto))
      expect(mode.layers).to eq(Lain::Mode::LayerSet.new(%i[goal notify]))
    end

    it "accepts already-built axis values and a LayerSet, not only raw names" do
      approval = Lain::Mode::Approval.for(:auto)
      layers = Lain::Mode::LayerSet.new(%i[vi])

      mode = described_class.new(approval:, layers:)

      expect(mode.approval).to be(approval)
      expect(mode.layers).to be(layers)
    end

    # `Mode.new` is where a session starts, so the defaults are a claim about
    # every session.
    it "defaults to the checkout, ask approval and no active layers" do
      mode = described_class.new

      expect([mode.scope.name, mode.approval.name]).to eq(%i[checkout ask])
      expect(mode.layers).to be_empty
    end

    it "fails loudly on an unknown approval level, naming every alternative" do
      expect { described_class.new(approval: :manual) }.to raise_error(ArgumentError, /manual.*ask.*auto/m)
    end

    it "fails loudly on an unknown scope, naming every alternative" do
      expect { described_class.new(scope: :sandbox) }.to raise_error(ArgumentError, /sandbox.*checkout.*plan/m)
    end

    it "fails loudly on an unknown layer, naming every alternative" do
      expect { described_class.new(layers: %i[nonsense]) }
        .to raise_error(ArgumentError, /nonsense.*auto_approve.*goal.*notify.*vi/)
    end

    # A name-shaped value that just doesn't NAME a declared one raises the
    # family's own ArgumentError, above. These are the OTHER kind of garbage --
    # not even name/Array-shaped -- which would otherwise leak a NoMethodError
    # from whichever private method (`to_sym`, `map`) the coercion calls first.
    describe "type-shaped garbage, not just name-shaped garbage" do
      it "rejects a nil approval with ArgumentError, not NoMethodError" do
        expect { described_class.new(approval: nil) }.to raise_error(ArgumentError, /unknown approval/)
      end

      it "rejects an Integer scope with ArgumentError, not NoMethodError" do
        expect { described_class.new(scope: 42) }.to raise_error(ArgumentError, /unknown mode scope/)
      end

      it "rejects an Array approval with ArgumentError, not NoMethodError" do
        expect { described_class.new(approval: [:ask]) }.to raise_error(ArgumentError, /unknown approval/)
      end

      it "rejects nil layers with ArgumentError, not NoMethodError" do
        expect { described_class.new(layers: nil) }.to raise_error(ArgumentError, /unknown mode layers/)
      end

      it "rejects String layers with ArgumentError, not NoMethodError" do
        expect { described_class.new(layers: "goal") }.to raise_error(ArgumentError, /unknown mode layers/)
      end
    end
  end

  describe "#describe" do
    it "names the scope and approval first, then every active layer in precedence order, each with its lighter" do
      mode = described_class.new(layers: enabled_names)

      description = mode.describe

      expect(description).to start_with("checkout ask:")
      expect(precedence_order.map { |name| Lain::Mode::Layer.for(name).to_s })
        .to all(satisfy { |rendered| description.include?(rendered) })

      positions = precedence_order.map { |name| description.index(Lain::Mode::Layer.for(name).to_s) }
      expect(positions).to eq(positions.sort)
    end

    it "still names the axes when no layers are active, and says so" do
      expect(described_class.new.describe).to eq("checkout ask: no layers active")
    end

    it "renders an axis value's own lighter too, when it has one" do
      expect(described_class.new(approval: :auto).describe).to eq("checkout auto (AUTO): no layers active")
    end
  end

  describe "the value it is" do
    it "is a frozen value, safe to share across a Ractor" do
      mode = described_class.new(approval: :auto, layers: %i[goal])

      expect(mode).to be_deeply_frozen
    end

    it "compares equal to a mode built from the same names, so a flip can tell nothing moved" do
      expect(described_class.new(approval: "auto", layers: %i[vi]))
        .to eq(described_class.new(approval: :auto, layers: %w[vi]))
    end
  end

  describe "the require index this file also is" do
    it "still resolves Mode::Scope, Mode::Approval and Mode::Layer -- the constants this class must not drop" do
      expect(described_class::Scope).to be_a(Class)
      expect(described_class::Approval).to be_a(Class)
      expect(described_class::Layer).to be_a(Class)
      expect(described_class::LayerSet).to be_a(Class)
    end
  end
end
