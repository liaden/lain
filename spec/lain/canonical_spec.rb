# frozen_string_literal: true

RSpec.describe Lain::Canonical do
  describe ".dump" do
    include_examples "canonical determinism",
                     dump: ->(input) { described_class.dump(input) },
                     ambiguous_key_error: Lain::Canonical::AmbiguousKey,
                     non_finite_float_error: Lain::Canonical::NonFiniteFloat,
                     unsupported_type_error: Lain::Canonical::UnsupportedType

    it "emits compact JSON" do
      expect(described_class.dump({ "a" => [1, 2] })).to eq('{"a":[1,2]}')
    end

    it "passes through scalars" do
      expect(described_class.dump({ "n" => nil, "t" => true, "f" => false, "i" => 1, "s" => "x" }))
        .to eq('{"f":false,"i":1,"n":null,"s":"x","t":true}')
    end

    it "keeps Integer and Float distinct" do
      expect(described_class.dump(1)).not_to eq(described_class.dump(1.0))
    end

    it "handles non-ASCII UTF-8" do
      expect(described_class.dump({ "k" => "café" })).to eq('{"k":"café"}')
    end
  end

  describe ".digest" do
    it "prefixes the algorithm so a future migration is not a silent reinterpretation" do
      expect(described_class.digest("x")).to start_with("blake3:")
    end

    # Digests are Hash keys throughout (the Store, cache-break walks). An unfrozen
    # one leaves any Turn holding it non-Ractor-shareable.
    it "returns a frozen, deduplicated String" do
      expect(described_class.digest("x")).to be_frozen
      expect(described_class.digest("x")).to equal(described_class.digest("x"))
    end

    it "is the BLAKE3 of the canonical dump" do
      # Independently verified against `b3sum` over the dump's bytes
      # (`{"a":1}`), not just re-derived from the same ext call under test.
      expected = "d59b6562d7c9b121bc9760873d787890ef4d429aad33a70b405baa0fa08a1f53"
      expect(described_class.digest({ "a" => 1 })).to eq("blake3:#{expected}")
    end

    it "agrees for structurally equal input regardless of key order" do
      expect(described_class.digest({ "b" => 1, "a" => 2 }))
        .to eq(described_class.digest({ "a" => 2, "b" => 1 }))
    end

    it "differs for different input" do
      expect(described_class.digest({ "a" => 1 })).not_to eq(described_class.digest({ "a" => 2 }))
    end
  end
end
