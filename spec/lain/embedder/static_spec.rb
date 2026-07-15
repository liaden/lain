# frozen_string_literal: true

RSpec.describe Lain::Embedder::Static do
  subject(:embedder) { described_class.new(vocabulary: %w[kidney liver renal biopsy]) }

  # AC: Static is byte-stable -- the same text, embedded twice, is identical.
  # This is the property the whole point of a Static arm rests on: it is the
  # determinism oracle a later memory-retrieval sweep pins its fixtures against,
  # so drift here would poison every downstream comparison.
  describe "#embed determinism" do
    it "returns identical vectors for the same text across two calls" do
      first = embedder.embed(["renal biopsy of the kidney"])
      second = embedder.embed(["renal biopsy of the kidney"])

      expect(first).to eq(second)
    end
  end

  # AC (shared with the batch-embed shape): equal-dimension Float vectors, one
  # per input text.
  describe "#embed shape" do
    it "returns one Float vector per text, every vector at the vocabulary's dimension" do
      vectors = embedder.embed(["kidney kidney liver", "biopsy"])

      expect(vectors.size).to eq(2)
      expect(vectors.map(&:size).uniq).to eq([4])
      expect(vectors.flatten).to all(be_a(Float))
    end

    it "counts term frequency over the configured vocabulary, ignoring out-of-vocab tokens" do
      vector = embedder.embed(["kidney kidney tumor liver"]).first

      # vocabulary order: kidney, liver, renal, biopsy -- "tumor" is not scored.
      expect(vector).to eq([2.0, 1.0, 0.0, 0.0])
    end

    it "is case-insensitive so PHI-free synthetic prompts tokenize predictably" do
      expect(embedder.embed(["KIDNEY Kidney"]).first).to eq([2.0, 0.0, 0.0, 0.0])
    end
  end

  # Probe finding: a bare String leaked out as NoMethodError. The seam's errors
  # are named -- a caller rescues Embedder::Error, never a duck-typing accident.
  describe "#embed on a non-Array" do
    it "raises a named Embedder::Error, not a bare NoMethodError" do
      expect { embedder.embed("kidney") }.to raise_error(Lain::Embedder::Error, /Array/)
    end
  end

  describe "a degenerate vocabulary" do
    it "de-duplicates the configured vocabulary so the dimension is stable" do
      embedder = described_class.new(vocabulary: %w[kidney kidney liver])

      expect(embedder.embed(["kidney liver"]).first).to eq([1.0, 1.0])
    end
  end
end
