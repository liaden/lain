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
    it "is one posture and a set of layers" do
      mode = described_class.new(posture: :manual, layers: %i[notify goal])

      expect(mode.posture).to eq(Lain::Mode::Posture.for(:manual))
      expect(mode.layers).to eq(Lain::Mode::LayerSet.new(%i[goal notify]))
    end

    it "accepts an already-built Posture and LayerSet, not only raw names" do
      posture = Lain::Mode::Posture.for(:auto)
      layers = Lain::Mode::LayerSet.new(%i[vi])

      mode = described_class.new(posture:, layers:)

      expect(mode.posture).to be(posture)
      expect(mode.layers).to be(layers)
    end

    it "defaults to no active layers" do
      mode = described_class.new(posture: :accept_edits)

      expect(mode.layers).to be_empty
    end

    it "fails loudly on an unknown posture, naming every alternative" do
      expect { described_class.new(posture: :turbo) }
        .to raise_error(ArgumentError, /turbo.*plan.*manual.*accept_edits.*auto/m)
    end

    it "fails loudly on an unknown layer, naming every alternative" do
      expect { described_class.new(posture: :manual, layers: %i[nonsense]) }
        .to raise_error(ArgumentError, /nonsense.*auto_approve.*goal.*notify.*vi/)
    end

    # A name-shaped posture (a Symbol or String that just doesn't NAME one of
    # the four) already raises Posture.for's own ArgumentError, above. These
    # five are the OTHER kind of garbage -- not even name/Array-shaped -- and
    # the panel's point stands even though nothing was ever silently
    # accepted: before this fix each one leaked a NoMethodError from whichever
    # private method (`to_sym`, `map`) the coercion happened to call first,
    # instead of the same ArgumentError a bad NAME gets.
    describe "type-shaped garbage, not just name-shaped garbage" do
      it "rejects a nil posture with ArgumentError, not NoMethodError" do
        expect { described_class.new(posture: nil) }.to raise_error(ArgumentError, /unknown posture/)
      end

      it "rejects an Integer posture with ArgumentError, not NoMethodError" do
        expect { described_class.new(posture: 42) }.to raise_error(ArgumentError, /unknown posture/)
      end

      it "rejects an Array posture with ArgumentError, not NoMethodError" do
        expect { described_class.new(posture: [:manual]) }.to raise_error(ArgumentError, /unknown posture/)
      end

      it "rejects nil layers with ArgumentError, not NoMethodError" do
        expect { described_class.new(posture: :manual, layers: nil) }
          .to raise_error(ArgumentError, /unknown mode layers/)
      end

      it "rejects String layers with ArgumentError, not NoMethodError" do
        expect { described_class.new(posture: :manual, layers: "goal") }
          .to raise_error(ArgumentError, /unknown mode layers/)
      end
    end
  end

  describe "#describe" do
    it "names the posture first, then every active layer in precedence order, each with its lighter" do
      mode = described_class.new(posture: :accept_edits, layers: enabled_names)

      description = mode.describe

      expect(description).to start_with("accept_edits")
      expect(precedence_order.map { |name| Lain::Mode::Layer.for(name).to_s })
        .to all(satisfy { |rendered| description.include?(rendered) })

      positions = precedence_order.map { |name| description.index(Lain::Mode::Layer.for(name).to_s) }
      expect(positions).to eq(positions.sort)
    end

    it "still names the posture when no layers are active, and says so" do
      mode = described_class.new(posture: :manual)

      description = mode.describe

      expect(description).to start_with("manual")
      expect(description).to include("no layers active")
    end

    it "renders a rung's own lighter too, when it has one" do
      mode = described_class.new(posture: :auto)

      expect(mode.describe).to include("auto").and include("AUTO")
    end
  end

  describe "the value it is" do
    it "is a frozen value, safe to share across a Ractor" do
      mode = described_class.new(posture: :plan, layers: %i[goal])

      expect(Ractor.shareable?(mode)).to be(true)
    end
  end

  describe "the require index this file also is" do
    it "still resolves Mode::Posture and Mode::Layer -- the constants this class must not drop" do
      expect(described_class::Posture).to be_a(Class)
      expect(described_class::Layer).to be_a(Class)
      expect(described_class::LayerSet).to be_a(Class)
    end
  end
end
