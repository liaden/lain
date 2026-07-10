# frozen_string_literal: true

RSpec.describe Lain::Canonical do
  describe ".dump" do
    it "sorts object keys" do
      expect(described_class.dump({ "b" => 1, "a" => 2 })).to eq('{"a":2,"b":1}')
    end

    it "emits compact JSON" do
      expect(described_class.dump({ "a" => [1, 2] })).to eq('{"a":[1,2]}')
    end

    # The whole point: a Hash iterating in insertion order across two Toolset
    # constructions must not produce different bytes, or the prompt cache dies
    # silently.
    it "is invariant under key insertion order" do
      keys = %w[alpha beta gamma delta epsilon]
      reference = described_class.dump(keys.to_h { |k| [k, k.length] })

      10.times do
        shuffled = keys.shuffle.to_h { |k| [k, k.length] }
        expect(described_class.dump(shuffled)).to eq(reference)
      end
    end

    it "sorts nested object keys too" do
      nested = { "z" => { "b" => 1, "a" => 2 }, "y" => 3 }
      expect(described_class.dump(nested)).to eq('{"y":3,"z":{"a":2,"b":1}}')
    end

    it "preserves array order, because array order is meaning" do
      expect(described_class.dump([3, 1, 2])).to eq("[3,1,2]")
    end

    # The canonical form names the wire representation, and both become JSON
    # strings, so they are the same message.
    it "collapses Symbol and String keys" do
      expect(described_class.dump({ a: 1 })).to eq(described_class.dump({ "a" => 1 }))
    end

    it "collapses Symbol and String values" do
      expect(described_class.dump([:text])).to eq(described_class.dump(["text"]))
    end

    it "raises when a key appears as both a Symbol and a String" do
      expect { described_class.dump({ :a => 1, "a" => 2 }) }
        .to raise_error(Lain::Canonical::AmbiguousKey, /both a String and a Symbol/)
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

    context "with values JSON cannot represent" do
      it "raises on NaN" do
        expect { described_class.dump(Float::NAN) }.to raise_error(Lain::Canonical::NonFiniteFloat)
      end

      it "raises on Infinity" do
        expect { described_class.dump(Float::INFINITY) }
          .to raise_error(Lain::Canonical::NonFiniteFloat)
      end

      it "raises on an arbitrary object" do
        expect { described_class.dump(Object.new) }
          .to raise_error(Lain::Canonical::UnsupportedType, /cannot canonicalize/)
      end

      it "raises on a non-String, non-Symbol key" do
        expect { described_class.dump({ 1 => "a" }) }
          .to raise_error(Lain::Canonical::UnsupportedType, /hash keys must be/)
      end

      it "raises on bytes that are not convertible to UTF-8" do
        expect { described_class.dump("\xff".b) }
          .to raise_error(Lain::Canonical::UnsupportedType, /UTF-8/)
      end

      it "raises on a String tagged UTF-8 that holds invalid bytes" do
        expect { described_class.dump("\xff".dup.force_encoding(Encoding::UTF_8)) }
          .to raise_error(Lain::Canonical::UnsupportedType, /not valid UTF-8/)
      end
    end
  end

  describe ".digest" do
    it "prefixes the algorithm so a future migration is not a silent reinterpretation" do
      expect(described_class.digest("x")).to start_with("sha256:")
    end

    # Digests are Hash keys throughout (the Store, cache-break walks). An unfrozen
    # one leaves any Turn holding it non-Ractor-shareable.
    it "returns a frozen, deduplicated String" do
      expect(described_class.digest("x")).to be_frozen
      expect(described_class.digest("x")).to equal(described_class.digest("x"))
    end

    it "is the SHA-256 of the canonical dump" do
      expected = Digest::SHA256.hexdigest(described_class.dump({ "a" => 1 }))
      expect(described_class.digest({ "a" => 1 })).to eq("sha256:#{expected}")
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
