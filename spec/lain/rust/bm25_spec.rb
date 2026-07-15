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
end
