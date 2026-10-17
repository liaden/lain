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

  describe ".abbreviate" do
    let(:digest) { "blake3:#{"a1b2c3d4e5f6" * 5}" }

    it "keeps the scheme and the first 12 hex characters by default" do
      expect(described_class.abbreviate(digest)).to eq("blake3:a1b2c3d4e5f6")
      expect(described_class.abbreviate(digest)).to eq(digest[0, 19])
    end

    it "takes a shorter hex count" do
      expect(described_class.abbreviate(digest, hex: 8)).to eq("blake3:a1b2c3d4")
    end

    it "treats an unprefixed input as all hex" do
      expect(described_class.abbreviate("a1b2c3d4e5f6a1b2")).to eq("a1b2c3d4e5f6")
    end

    it "returns a digest shorter than the cut whole" do
      expect(described_class.abbreviate("blake3:abc")).to eq("blake3:abc")
    end

    it "drops the scheme on request" do
      expect(described_class.abbreviate(digest, hex: 8, scheme: false)).to eq("a1b2c3d4")
    end
  end

  describe ".normalize of its own output" do
    let(:canonical) { described_class.normalize([{ b: [{ z: 1, a: "x" }], a: 2 }]) }

    # Net of the probe itself, which costs an object even around an empty block.
    def allocations_during
      probe = -> { GC.stat(:total_allocated_objects) }
      empty = -probe.call + probe.call
      before = probe.call
      yield
      probe.call - before - empty
    end

    it "returns the same object and allocates nothing" do
      described_class.normalize(canonical)

      expect(allocations_during { described_class.normalize(canonical) }).to eq(0)
      expect(described_class.normalize(canonical)).to equal(canonical)
    end

    it "returns a canonical child unchanged when it sits inside new data" do
      child = canonical.first.fetch("b")

      expect(described_class.normalize({ "k" => child }).fetch("k")).to equal(child)
    end

    it "rebuilds data that only looks canonical into the full normalization's bytes" do
      copy = canonical.dup
      look_alikes = [[{ a: 1 }].freeze, [{ "b" => 1, "a" => 2 }.freeze].freeze, copy]

      expect(look_alikes.map { |input| JSON.generate(described_class.normalize(input)) })
        .to eq(['[{"a":1}]', '[{"a":2,"b":1}]', '[{"a":2,"b":[{"a":"x","z":1}]}]'])
      expect(described_class.normalize(look_alikes.first).first.keys).to eq(["a"])
      expect(described_class.normalize(copy)).not_to equal(copy)
    end

    it "gives a non-main Ractor the full normalization" do
      input = [{ b: 1, a: [2] }]

      expect(Ractor.new(described_class, input) { |canonical, value| canonical.normalize(value) }.value)
        .to eq(described_class.normalize(input))
    end
  end
end
