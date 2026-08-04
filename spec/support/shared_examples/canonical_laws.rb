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

  # A JSON-native leaf: the scalar types Canonical accepts without
  # qualification. `real_float`, not `float` -- `Generators#float` injects
  # NaN/Infinity roughly 1/50 draws BY DESIGN (its docstring), which is
  # exactly what NonFiniteFloat exists to refuse; `real_float`'s docstring
  # guarantees "no infinity, no NaN". `printable_ascii_string` keeps strings
  # inside plain ASCII so no draw can collide with the UTF-8-validity
  # refusals, which are pinned separately below by explicit examples.
  define_method(:json_leaf_generator) do
    generators = PropCheck::Generators
    generators.one_of(generators.constant(nil), generators.boolean, generators.integer,
                      generators.real_float, generators.printable_ascii_string)
  end

  # A JSON-shaped tree over that leaf: arrays and String-keyed Hashes
  # nesting arbitrarily. `PropCheck::Generators#tree` is the library's own
  # documented recipe for "a simple generator for parsed JSON data" (see
  # generators.rb). Its depth is O(log(size)) by construction --
  # `random_pseudofactors` roughly halves the size budget per level -- so at
  # this suite's n_runs (100, meaning size climbs to at most 100) sampling
  # measured a maximum observed depth of 6, nowhere near the ≤100 ceiling
  # `spec/lain/rust/canonical_spec.rb` enforces; `max: 5` per container
  # additionally keeps a single draw's node count small so a batch of 100
  # runs stays fast. Every key generated is a String, by construction --
  # AmbiguousKey (a Hash carrying both `:a` and `"a"`) is therefore
  # unreachable from this generator, not merely unlikely.
  define_method(:json_value_generator) do
    generators = PropCheck::Generators
    generators.tree(json_leaf_generator) do |subtree|
      generators.one_of(
        generators.array(subtree, max: 5),
        generators.hash_of(generators.printable_ascii_string, subtree, max: 5)
      )
    end
  end

  # Rebuilds `value` with every Hash's entries in a freshly shuffled
  # insertion order, at EVERY nesting level -- not just the top one, which
  # is what the hardcoded five-key example this replaces could reach.
  #
  # Draws from Kernel's RNG (`Array#shuffle`), not prop_check's, so a
  # printed `Shrunken input` on a failure here is the PRE-shuffle value --
  # each shrink step re-shuffles independently rather than replaying the
  # exact order that failed. Harmless to what this property checks (no
  # order should ever matter), but it means a reported counterexample is
  # not guaranteed to reproduce verbatim by hand; re-run the property
  # instead of trusting the printed shuffle to repeat.
  define_method(:shuffle_keys) do |value|
    case value
    when Hash then value.to_a.shuffle.to_h { |k, v| [k, shuffle_keys(v)] }
    when Array then value.map { |v| shuffle_keys(v) }
    else value
    end
  end

  # Re-keys every Hash in `value`, recursively, flipping a coin PER KEY
  # between its String spelling and the equivalent Symbol -- not a
  # wholesale rewrite. A wholesale rewrite can only ever compare an
  # all-Symbol tree to an all-String tree; real Lain payloads mix spellings
  # within one Hash (`{ :a => 1, "b" => 2 }` is legal input to Canonical),
  # and a per-key normalization bug that only fires when a single Hash
  # carries BOTH spellings at once would pass a wholesale-only comparison
  # vacuously -- every Hash on both sides of that comparison is
  # single-spelling throughout. Still cannot trip AmbiguousKey: each key
  # keeps exactly ONE spelling, so no Hash here ever carries both `:a` and
  # `"a"`.
  #
  # Same RNG caveat as `shuffle_keys` above: `Array#sample` draws from
  # Kernel's RNG, not prop_check's, so a printed `Shrunken input` re-flips
  # spellings on replay rather than reproducing the exact mix that failed.
  define_method(:mixed_spelling_keys) do |value|
    case value
    when Hash then value.to_h { |k, v| [[k, k.to_sym].sample, mixed_spelling_keys(v)] }
    when Array then value.map { |v| mixed_spelling_keys(v) }
    else value
    end
  end

  it "sorts object keys" do
    expect(canonical_call(dump, { "b" => 1, "a" => 2 })).to eq('{"a":2,"b":1}')
  end

  # The whole point: a Hash iterating in insertion order across two Toolset
  # constructions must not produce different bytes, or the prompt cache dies
  # silently -- checked at every nesting level of an arbitrary generated
  # structure, not just five hardcoded top-level keys.
  it "is invariant under key insertion order, at any nesting level", aggregate_failures: false do
    forall(value: json_value_generator) do |value:|
      expect(canonical_call(dump, shuffle_keys(value))).to eq(canonical_call(dump, value))
    end
  end

  # The canonical form names the wire representation, so a key's Symbol or
  # String spelling must not affect the dump -- checked PER KEY over an
  # arbitrary generated structure (so some drawn Hashes carry both
  # spellings at once, the shape a wholesale rewrite could never produce),
  # not just the one-key example below.
  it "collapses Symbol and String keys for an arbitrary structure, spelling flipped per key",
     aggregate_failures: false do
    forall(value: json_value_generator) do |value:|
      expect(canonical_call(dump, mixed_spelling_keys(value))).to eq(canonical_call(dump, value))
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
      expect { canonical_call(dump, (+"\xff").force_encoding(Encoding::UTF_8)) }
        .to raise_error(unsupported_type_error, /not valid UTF-8/)
    end
  end
end
