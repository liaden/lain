# frozen_string_literal: true

# The Rust BM25 index (`bm25` crate, in-process under the ext's data-structure
# placement rules): built once from a batch of [id, text] pairs, immutable after
# build. Retrieval is deterministic and explainable -- each hit carries the
# surface tokens shared by query and document, and equal-score ties break by
# build-batch insertion order so results are byte-identical across processes.
RSpec.describe Lain::Ext::Bm25 do
  # A tiny drug-mention corpus: exactly one document names the rare term.
  def corpus
    [
      ["mat", "the cat sat on the mat"],
      ["dact", "dactinomycin is an antineoplastic chemotherapy drug"],
      ["imat", "imatinib treats chronic myeloid leukemia"],
      ["aspirin", "aspirin is a common analgesic and antiplatelet agent"]
    ]
  end

  describe ".build" do
    it "returns a frozen, Ractor-shareable index" do
      index = described_class.build(corpus)
      expect(index).to be_deeply_frozen
    end

    it "raises EmptyCorpus on an empty batch" do
      expect { described_class.build([]) }
        .to raise_error(described_class::EmptyCorpus)
    end

    it "raises DuplicateId when two pairs share an id" do
      expect { described_class.build([%w[x one], %w[x two]]) }
        .to raise_error(described_class::DuplicateId, /x/)
    end
  end

  describe "#search" do
    subject(:index) { described_class.build(corpus) }

    it "returns [id, score, matched_tokens] triples" do
      hit = index.search("dactinomycin", 5).first
      id, score, matched = hit
      expect(id).to eq("dact")
      expect(score).to be_a(Float).and be > 0.0
      expect(matched).to include("dactinomycin")
    end

    it "returns the exact-term document as the top hit" do
      results = index.search("dactinomycin", 5)
      expect(results.first[0]).to eq("dact")
      expect(results.first[2]).to include("dactinomycin")
    end

    it "bounds the result count by k" do
      expect(index.search("the drug agent", 2).size).to be <= 2
    end

    it "ranks by descending score" do
      scores = index.search("drug agent chemotherapy", 10).map { |hit| hit[1] }
      expect(scores).to eq(scores.sort.reverse)
    end

    it "is empty when the query shares no tokens with any document" do
      expect(index.search("zzznonexistent qqquux", 5)).to eq([])
    end

    # Every other binding in this ext hands back a frozen outer Array
    # (astgrep, treesitter, fuzzy, prompt); a caller must not have to remember
    # which one is the exception. The triples and their token Arrays were
    # already frozen, so this closes the last mutable layer -- and it is what
    # makes the whole result Ractor-shareable, not just deep-frozen by eye.
    it "returns a deeply frozen result, like every sibling binding" do
      expect(index.search("drug chemotherapy agent", 10)).to be_deeply_frozen
    end

    it "freezes the empty result too" do
      expect(index.search("zzznonexistent qqquux", 5)).to be_frozen
    end

    it "is byte-identical across two builds from the same pairs" do
      a = described_class.build(corpus).search("drug chemotherapy agent", 10)
      b = described_class.build(corpus).search("drug chemotherapy agent", 10)
      expect(a).to eq(b)
    end

    it "breaks equal-score ties by build-batch insertion order" do
      # Two documents identical but for id, inserted first-then-second, tie on
      # any shared query token; the earlier-inserted id must rank first, stably.
      tied = described_class.build([
                                     ["first", "identical body text here"],
                                     ["second", "identical body text here"]
                                   ])
      ids = tied.search("identical body text", 5).map { |hit| hit[0] }
      expect(ids).to eq(%w[first second])
    end
  end

  # The build and the search run with the GVL released, because another Ruby thread runs
  # meanwhile, and an interrupt reaches the work, only while the GVL is not held. A build over
  # this many documents takes a few hundred milliseconds and a search a few dozen, long
  # enough for both to show.
  describe "on another thread" do
    include GapShare

    def synthetic(count, words = 30)
      rng = Random.new(1)
      vocabulary = Array.new(4000) { |i| "w#{i.to_s(36)}" }
      Array.new(count) { |i| ["d#{i}", Array.new(words) { vocabulary[((rng.rand**2) * 4000).to_i] }.join(" ")] }
    end

    # Fixed by their seed, so each is made once and only the examples that ask pay for it.
    once(:pairs) { synthetic(20_000) }
    # Few long documents, so most of a build is the index work that runs unlocked and little is
    # the copy-in that cannot be interrupted.
    once(:long_pairs) { synthetic(1_500, 400) }

    it "ranks a recorded corpus exactly as before the lock was released" do
      index = described_class.build(synthetic(2_000))
      ranked = ["w0 w1 w2", "w3 w9 wz", "w40 w7", "nothing here"].map { |query| index.search(query, 25) }

      expect(Lain::Canonical.digest(ranked))
        .to eq("blake3:53ba3d2aa5165958cc50b890a256f4bd4c7eddea95e250b597da9a9eace0ccd0")
    end

    it "lets the calling thread keep running while it searches" do
      index = described_class.build(pairs)
      worker = Thread.new { Array.new(10) { index.search("w0 w1 w2", 10) } }
      share = longest_gap_share(worker)

      expect(worker.value.map(&:size)).to all(eq(10))
      expect(share).to be < 0.3
    end

    # A build over this many documents takes a few hundred milliseconds, and the bound allows for
    # suite load while staying well under the roughly 600 ms a build holding the lock would take.
    it_behaves_like "a GVL-releasing binding" do
      let(:work) do
        batch = long_pairs
        -> { described_class.build(batch) }
      end
      let(:complete) { ->(index) { index.is_a?(described_class) && index.search("w0", 5).size == 5 } }
      # A build and a search beside each other, each under its threshold.
      let(:small_work) do
        small = synthetic(100)
        -> { described_class.build(small).search("w0 w1 w2", 10) }
      end
      # Over the build threshold, though far cheaper than `work`.
      let(:crowd_work) do
        crowd = synthetic(1_000)
        -> { described_class.build(crowd).search("w0", 3) }
      end
      let(:crowd_complete) { ->(hits) { hits.size == 3 } }
    end

    it "still names the refusal of a degenerate batch when built on another thread" do
      error = Thread.new { described_class.build([%w[x one], %w[x two]]) }
      expect { error.value }.to raise_error(described_class::DuplicateId, /x/)
    end
  end
end
