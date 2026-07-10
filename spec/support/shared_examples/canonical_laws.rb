# frozen_string_literal: true

# The algorithm-AGNOSTIC half of Canonical's contract: deterministic bytes out
# of a Hash/Array/scalar tree, independent of Ruby Hash insertion order,
# Symbol-vs-String spelling, or nesting depth -- plus the input shapes JSON
# cannot represent, which must raise rather than silently mis-encode. This is
# what a Turn hashes and what makes the prompt cache stable; it does NOT cover
# which digest algorithm sits on top (sha256 today) -- those assertions stay
# inline in canonical_spec.rb so a hash-algorithm migration only ever touches
# one file.
#
# Include with a Hash:
#
#   dump                     [#call(input) -> String]   the canonicalizer
#                                                         under test.
#   ambiguous_key_error      [Class]   raised when a key appears as both a
#                                      Symbol and a String.
#   non_finite_float_error   [Class]   raised on NaN/Infinity.
#   unsupported_type_error   [Class]   raised on any other un-encodable input.
#
# == Why `dump` runs through #canonical_call instead of a bare call
#
# Same reason as "a monoid" (see monoid.rb): the config Hash is built inside a
# `describe` body, so a Proc literal there closes over the example GROUP, not
# an instance. `instance_exec` keeps this shared group usable even if a future
# implementation's `dump` needs to read example-local state.
RSpec.shared_examples "canonical determinism" do |config|
  dump = config.fetch(:dump)
  ambiguous_key_error = config.fetch(:ambiguous_key_error)
  non_finite_float_error = config.fetch(:non_finite_float_error)
  unsupported_type_error = config.fetch(:unsupported_type_error)

  define_method(:canonical_call) { |callable, *args| instance_exec(*args, &callable) }

  it "sorts object keys" do
    expect(canonical_call(dump, { "b" => 1, "a" => 2 })).to eq('{"a":2,"b":1}')
  end

  # The whole point: a Hash iterating in insertion order across two Toolset
  # constructions must not produce different bytes, or the prompt cache dies
  # silently.
  it "is invariant under key insertion order" do
    keys = %w[alpha beta gamma delta epsilon]
    reference = canonical_call(dump, keys.to_h { |k| [k, k.length] })

    10.times do
      shuffled = keys.shuffle.to_h { |k| [k, k.length] }
      expect(canonical_call(dump, shuffled)).to eq(reference)
    end
  end

  it "sorts nested object keys too" do
    nested = { "z" => { "b" => 1, "a" => 2 }, "y" => 3 }
    expect(canonical_call(dump, nested)).to eq('{"y":3,"z":{"a":2,"b":1}}')
  end

  it "preserves array order, because array order is meaning" do
    expect(canonical_call(dump, [3, 1, 2])).to eq("[3,1,2]")
  end

  # The canonical form names the wire representation, and both become JSON
  # strings, so they are the same message.
  it "collapses Symbol and String keys" do
    expect(canonical_call(dump, { a: 1 })).to eq(canonical_call(dump, { "a" => 1 }))
  end

  it "collapses Symbol and String values" do
    expect(canonical_call(dump, [:text])).to eq(canonical_call(dump, ["text"]))
  end

  it "raises when a key appears as both a Symbol and a String" do
    expect { canonical_call(dump, { :a => 1, "a" => 2 }) }
      .to raise_error(ambiguous_key_error, /both a String and a Symbol/)
  end

  context "with values JSON cannot represent" do
    it "raises on NaN" do
      expect { canonical_call(dump, Float::NAN) }.to raise_error(non_finite_float_error)
    end

    it "raises on Infinity" do
      expect { canonical_call(dump, Float::INFINITY) }.to raise_error(non_finite_float_error)
    end

    it "raises on an arbitrary object" do
      expect { canonical_call(dump, Object.new) }
        .to raise_error(unsupported_type_error, /cannot canonicalize/)
    end

    it "raises on a non-String, non-Symbol key" do
      expect { canonical_call(dump, { 1 => "a" }) }
        .to raise_error(unsupported_type_error, /hash keys must be/)
    end

    it "raises on bytes that are not convertible to UTF-8" do
      expect { canonical_call(dump, "\xff".b) }.to raise_error(unsupported_type_error, /UTF-8/)
    end

    it "raises on a String tagged UTF-8 that holds invalid bytes" do
      expect { canonical_call(dump, "\xff".dup.force_encoding(Encoding::UTF_8)) }
        .to raise_error(unsupported_type_error, /not valid UTF-8/)
    end
  end
end
