# frozen_string_literal: true

require "lain"

# The Rust canonicalizer (`Lain::Ext.canonical_dump`/`canonical_digest`) must be
# a byte-for-byte twin of `Lain::Canonical`. It drives the SAME shared
# determinism group the Ruby impl does (proving both satisfy one contract), and
# is then pinned directly against the Ruby output over a battery that includes
# the cases where a naive Rust port would silently diverge (float exponentials,
# bignums, non-ASCII, nested sorting).
RSpec.describe "Lain::Ext canonical (Rust)" do
  describe ".canonical_dump" do
    include_examples "canonical determinism",
                     dump: ->(input) { Lain::Ext.canonical_dump(input) },
                     ambiguous_key_error: Lain::Canonical::AmbiguousKey,
                     non_finite_float_error: Lain::Canonical::NonFiniteFloat,
                     unsupported_type_error: Lain::Canonical::UnsupportedType
  end

  # Values chosen to catch the byte-level divergences a reimplemented serializer
  # hides: Ruby's JSON float format differs from both `Float#to_s` and Rust's
  # shortest-float output in the exponential ranges, integers can exceed i64, and
  # object key order must be sorted recursively.
  def byte_parity_values
    [
      { "a" => 1 }, { a: 1 }, { "b" => 1, "a" => 2 },
      { "z" => { "b" => 1, "a" => 2 }, "y" => 3 },
      [3, 1, 2], "café", { "k" => "café" }, [:text],
      { "n" => nil, "t" => true, "f" => false },
      1, -1, 2**80, { "big" => 2**64 },
      0.0, 1.0, -0.0, 0.1, 3.14, 1e20, 1e-7, 123_456_789_012_345.0,
      { "content" => [{ "type" => "text", "text" => "hi" }], "meta" => { "spawned_from" => "blake3:abc" } }
    ]
  end

  describe "byte-for-byte agreement with Lain::Canonical" do
    it "dumps identically to the Ruby canonicalizer" do
      byte_parity_values.each do |value|
        expect(Lain::Ext.canonical_dump(value))
          .to eq(Lain::Canonical.dump(value)), "dump mismatch for #{value.inspect}"
      end
    end

    it "digests identically to the Ruby canonicalizer" do
      byte_parity_values.each do |value|
        expect(Lain::Ext.canonical_digest(value))
          .to eq(Lain::Canonical.digest(value)), "digest mismatch for #{value.inspect}"
      end
    end
  end

  describe ".canonical_digest" do
    it "is the prefixed blake3 of the canonical dump" do
      # Independently checked with `b3sum` over the bytes of `{"a":1}`.
      expected = "d59b6562d7c9b121bc9760873d787890ef4d429aad33a70b405baa0fa08a1f53"
      expect(Lain::Ext.canonical_digest({ "a" => 1 })).to eq("blake3:#{expected}")
    end

    it "is order-independent, because the dump sorts keys" do
      expect(Lain::Ext.canonical_digest({ "b" => 1, "a" => 2 }))
        .to eq(Lain::Ext.canonical_digest({ "a" => 2, "b" => 1 }))
    end
  end
end
