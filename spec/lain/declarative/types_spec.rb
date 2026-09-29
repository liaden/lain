# frozen_string_literal: true

require "spec_helper"
require "bigdecimal"

# `Lain::Declarative`'s carrier and `settle!` are not yet landed in this tree. Wherever an
# AC below stands in for `settle!`'s extraction, a comment says so and names what to re-point once
# the carrier lands. The types themselves are plain `ActiveModel::Type::Value` subclasses and are exercised
# directly, with no dependency on `Declarative`.
RSpec.describe Lain::Declarative::Types::StrictInteger do
  # Stand-in for the carrier `Declarative` will build: enough `ActiveModel::Attributes` to
  # exercise lazy `cast`, without depending on `Declarative` itself.
  let(:carrier_class) do
    strict_integer = described_class
    Class.new do
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :n, strict_integer.new
    end
  end

  it "raises rather than returning 3 for a value Integer() itself refuses" do
    carrier = carrier_class.new(n: "3x")

    expect { carrier.n }.to raise_error(Lain::Declarative::Types::CoercionError)
  end

  it "returns 42 for a value Integer() accepts" do
    carrier = carrier_class.new(n: "42")

    expect(carrier.n).to eq(42)
  end

  it "is registered under :lain_strict_integer, for declaration by symbol" do
    expect(ActiveModel::Type.lookup(:lain_strict_integer)).to be_a(described_class)
  end

  # BLOCKER 2 fix: the previous version of this example wrapped `carrier.n` inside a hand-rolled
  # class's `initialize` and asserted the wrapper's construction raised. That is tautological --
  # the panel built the identical shape over a type that raises for an UNRELATED reason and it
  # passed, because the assertion is just "reading a raising attribute raises," true of any type.
  # These two examples instead pin the actual claim: `.new` alone does NOT raise (the laziness),
  # and `.n` does (the read is where casting happens) -- both must hold for "lazy" to mean
  # anything.
  describe "casting is lazy: it happens on read, not on construction" do
    it "does not raise when a malformed value is merely assigned" do
      expect { carrier_class.new(n: "3x") }.not_to raise_error
    end

    it "raises only once the attribute is actually read" do
      carrier = carrier_class.new(n: "3x")

      expect { carrier.n }.to raise_error(Lain::Declarative::Types::CoercionError)
    end
  end

  # Finding 5: absence is not policed by the type at all -- an omitted attribute never reaches
  # `cast`, so a strict type cannot substitute for a presence check. Proven by instrumenting
  # `cast` itself, not by inspecting the result (a returned `nil` would be ambiguous between
  # "cast ran and returned nil" and "cast never ran").
  it "never invokes cast for an attribute that was not supplied" do
    invoked = false
    probing_type = Class.new(described_class) do
      define_method(:cast) do |value|
        invoked = true
        super(value)
      end
    end
    carrier_klass = Class.new do
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :n, probing_type.new
    end

    expect(carrier_klass.new.n).to be_nil
    expect(invoked).to be false
  end

  # Finding 6: a `default:` is itself cast lazily, on first read -- not at class declaration and
  # not at `.new`. A typo'd default is silent until something asks for it.
  it "does not cast a malformed default at declaration or construction, only at read" do
    strict_integer = described_class
    carrier_klass = Class.new do
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :d, strict_integer.new, default: "9x"
    end

    carrier = nil
    expect { carrier = carrier_klass.new }.not_to raise_error
    expect { carrier.d }.to raise_error(Lain::Declarative::Types::CoercionError)
  end

  # BLOCKER 1 + BLOCKER 3, pinned together: every accepted row converts to the shown Integer, and
  # every refused row raises the SAME `CoercionError` -- not whatever native exception Ruby's
  # conversion happened to produce. This is the executable version of the fix, row by row.
  describe "the coercion table, pinned end to end" do
    accepted = {
      '"42"' => ["42", 42],
      '"0080" (base 10, not octal -- was silently 8 before this fix)' => ["0080", 80],
      '"010" (base 10, not octal -- was silently 8 before this fix)' => ["010", 10],
      '"08" (a valid base-10 number now that octal auto-detection is gone; previously ' \
      "raised because '8' isn't a valid octal digit)" => ["08", 8],
      '" 42 " (whitespace-tolerant, like Integer())' => [" 42 ", 42],
      '"42\n"' => ["42\n", 42],
      '"1_000" (numeric separator, like Integer())' => ["1_000", 1000],
      "42 (already an Integer)" => [42, 42],
      "3.0 (integral Float)" => [3.0, 3],
      "-3.0 (integral Float)" => [-3.0, -3],
      'BigDecimal("3.0") (integral)' => [BigDecimal("3.0"), 3],
      "Rational(6, 2) (integral)" => [Rational(6, 2), 3]
    }

    accepted.each do |label, (input, expected)|
      it "casts #{label} to #{expected}" do
        expect(described_class.new.cast(input)).to eq(expected)
      end
    end

    refused = {
      '"3x"' => "3x",
      "empty string" => "",
      '"0x1f" (hex is no longer reinterpreted, base is always 10)' => "0x1f",
      '"0b101" (binary is no longer reinterpreted, base is always 10)' => "0b101",
      "nil" => nil,
      "true" => true,
      "false" => false,
      ":sym" => :sym,
      "[] (an Array)" => [],
      "{} (a Hash)" => {},
      "Object.new" => Object.new,
      "3.7 (non-integral Float, no longer truncated)" => 3.7,
      "-3.7 (non-integral Float, no longer truncated)" => -3.7,
      "Float::NAN" => Float::NAN,
      "Float::INFINITY" => Float::INFINITY,
      'BigDecimal("3.7") (non-integral, no longer truncated)' => BigDecimal("3.7"),
      "Rational(7, 2) (non-integral, no longer truncated)" => Rational(7, 2),
      "an object that responds only to #to_i (no implicit duck-typing)" =>
        Class.new { def to_i = 99 }.new,
      "an object that responds to #to_i and #to_int" =>
        Class.new do
          def to_i = 1
          def to_int = 2
        end.new,
      "a Struct instance" => Struct.new(:a).new(1)
    }

    refused.each do |label, input|
      it "refuses #{label}, raising CoercionError rather than any of Ruby's native conversion errors" do
        expect { described_class.new.cast(input) }.to raise_error(Lain::Declarative::Types::CoercionError)
      end
    end
  end

  it "CoercionError is-a Lain::Error, the user-facing-failure boundary, not a programmer-error one" do
    expect(Lain::Declarative::Types::CoercionError.ancestors).to include(Lain::Error)
  end

  it "CoercionError is no longer an ArgumentError -- reparented per the malformed-value/" \
     "malformed-declaration policy ruling" do
    expect(Lain::Declarative::Types::CoercionError.ancestors).not_to include(ArgumentError)
  end

  # Finding 4: NOT a claim that this is fixed here -- it is the `check!`/`settle!` design surface,
  # pinned so it is inherited as a known fact rather than rediscovered. A strict-typed attribute
  # makes `valid?` behave inconsistently depending on whether a validation happens to touch it.
  describe "interaction with ActiveModel validation (documented for D1, not fixed here)" do
    let(:carrier_class) do
      strict_integer = described_class
      Class.new do
        include ActiveModel::Model
        include ActiveModel::Attributes

        attribute :n, strict_integer.new
      end
    end

    it "passes valid? on a malformed value when nothing validates that attribute -- cast is never consulted" do
      expect(carrier_class.new(n: "3x").valid?).to be true
    end

    it "raises OUT OF valid?, rather than returning false, once a presence validation reads the attribute" do
      validated_class = Class.new(carrier_class) { validates :n, presence: true }

      expect { validated_class.new(n: "3x").valid? }.to raise_error(Lain::Declarative::Types::CoercionError)
    end

    it "returns false (not a raise) for the same presence validation when the attribute is simply omitted" do
      validated_class = Class.new(carrier_class) { validates :n, presence: true }

      expect(validated_class.new.valid?).to be false
    end
  end
end

RSpec.describe Lain::Declarative::Types::Canonicalized do
  let(:carrier_class) do
    canonicalized = described_class
    Class.new do
      include ActiveModel::Model
      include ActiveModel::Attributes

      attribute :payload, canonicalized.new
    end
  end

  it "normalizes a nested hash with symbol keys the same way Canonical.normalize does" do
    input = { b: 1, a: { c: 2 } }
    carrier = carrier_class.new(payload: input)

    expect(carrier.payload).to eq(Lain::Canonical.normalize(input))
  end

  it "stays Ractor-shareable, the invariant settle! depends on" do
    carrier = carrier_class.new(payload: { b: 1, a: { c: 2 } })

    expect(Ractor.shareable?(carrier.payload)).to be true
  end

  it "is registered under :lain_canonical, for declaration by symbol" do
    expect(ActiveModel::Type.lookup(:lain_canonical)).to be_a(described_class)
  end

  # SUBSTANTIVE 1 fix: `Canonical.normalize` raises its own taxonomy for input it refuses, and the
  # first version of this file let all three escape raw -- the same "more than one rescuable
  # class" defect Blocker 3 fixed for `StrictInteger`, just relocated to this type. Pinned here so
  # the one-class guarantee the module docstring states is no longer half true.
  describe "wraps Canonical.normalize's own refusals into the same CoercionError" do
    it "wraps UnsupportedType (an object Canonical.normalize cannot serialize)" do
      expect { described_class.new.cast(Object.new) }.to raise_error(Lain::Declarative::Types::CoercionError)
    end

    it "wraps AmbiguousKey (a Hash with both a Symbol and a String form of the same key)" do
      expect { described_class.new.cast({ a: 1, "a" => 2 }) }
        .to raise_error(Lain::Declarative::Types::CoercionError)
    end

    it "wraps NonFiniteFloat (NaN has no JSON representation)" do
      expect { described_class.new.cast(Float::NAN) }.to raise_error(Lain::Declarative::Types::CoercionError)
    end
  end
end

RSpec.describe "stock vs. strict coercion, pinned rather than assumed" do
  it "records that the stock :integer type casts \"3x\" to 3" do
    expect(ActiveModel::Type::Integer.new.cast("3x")).to eq(3)
  end

  it "records that the strict integer type raises on the same input" do
    expect { Lain::Declarative::Types::StrictInteger.new.cast("3x") }
      .to raise_error(Lain::Declarative::Types::CoercionError)
  end
end
