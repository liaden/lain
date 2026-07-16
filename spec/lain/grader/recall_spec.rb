# frozen_string_literal: true

require "yaml"

# Recall@k over one query: what fraction of the query's gold ids the ranked hits
# surface in the top k. A Grader::Grade like Fixture's -- one scalar verdict per
# subject; folding many queries into a distribution is Compare's job, not this
# class's (grader.rb's module doc: "Compare folds a Grade's #score into its
# distribution").
RSpec.describe Lain::Grader::Recall do
  describe "#grade" do
    it "computes recall@k exactly, with a why naming the missed id" do
      recall = described_class.new(gold_ids: %w[a b c])

      grade = recall.grade(%w[a x b], k: 3)

      expect(grade.score).to eq(2.0.fdiv(3))
      expect(grade.why).to include("c")
    end

    it "scores 1.0 and passes when every gold id is found within k" do
      recall = described_class.new(gold_ids: %w[a b])

      grade = recall.grade(%w[a b x], k: 3)

      expect(grade.score).to eq(1.0)
      expect(grade).to be_pass
    end

    it "scores 0.0 when no gold id appears in the top k" do
      recall = described_class.new(gold_ids: %w[a b])

      grade = recall.grade(%w[x y z], k: 3)

      expect(grade.score).to eq(0.0)
      expect(grade).not_to be_pass
      expect(grade.why).to include("a").and include("b")
    end

    it "truncates ranked hits to k before scoring -- a gold id past k does not count" do
      recall = described_class.new(gold_ids: %w[a b])

      grade = recall.grade(%w[x a b], k: 1)

      expect(grade.score).to eq(0.0)
    end

    it "accepts anything duck-typed with #id, not just bare strings" do
      hit = Struct.new(:id).new("a")
      recall = described_class.new(gold_ids: %w[a])

      grade = recall.grade([hit], k: 1)

      expect(grade.score).to eq(1.0)
    end

    it "defaults k to the full ranked list when k is omitted" do
      recall = described_class.new(gold_ids: %w[a b c])

      grade = recall.grade(%w[x y a b c])

      expect(grade.score).to eq(1.0)
    end

    it "is deterministic: the same hits score the same Grade twice" do
      recall = described_class.new(gold_ids: %w[a b c])

      expect(recall.grade(%w[a x b], k: 3)).to eq(recall.grade(%w[a x b], k: 3))
    end
  end

  describe "construction" do
    it "rejects an empty gold_ids list -- a recall score over no gold answers is meaningless" do
      expect { described_class.new(gold_ids: []) }.to raise_error(ArgumentError, /gold_ids/)
    end
  end
end

# The gold retrieval corpus that will feed the M6 retrieval-arm sweep (bm25, vector,
# hybrid, graph). These specs are the "validity spec, not a runtime check" the card
# asks for: nothing here builds a Memory::Index or runs a real search, it only checks
# the fixture's own internal consistency and its ability to separate arms by design.
RSpec.describe "the gold retrieval corpus" do
  # Same tokenization rule as Memory::Manifest (manifest.rb's TOKEN regex): \w+ runs,
  # lowercased, deduplicated. Reused here (not required) so this validity spec stays a
  # leaf file per the Requires policy -- it is a small enough rule to restate rather
  # than pull in Memory::Manifest as a dependency of a corpus fixture spec.
  def tokens(text)
    text.to_s.downcase.scan(/\w+/).uniq
  end

  let(:corpus_path) { Lain::Bench::Sweep::CORPUS_PATH }
  let(:corpus) { YAML.safe_load_file(corpus_path, symbolize_names: true) }
  let(:items) { corpus.fetch(:items) }
  let(:queries) { corpus.fetch(:queries) }
  let(:item_ids) { items.map { |item| item[:id] } }

  def item_tokens(item)
    tokens("#{item[:id]} #{item[:description]} #{item[:body]}")
  end

  def linked_ids(item)
    item[:body].to_s.scan(/\[\[([^\]]+)\]\]/).flatten
  end

  it "loads and is non-empty" do
    expect(items).not_to be_empty
    expect(queries).not_to be_empty
  end

  it "is internally valid: every query's gold ids exist among the corpus items" do
    queries.each do |query|
      missing = query.fetch(:gold_ids) - item_ids
      expect(missing).to be_empty, "query #{query[:query].inspect} names unknown gold ids: #{missing}"
    end
  end

  it "has no duplicate item ids" do
    expect(item_ids.uniq.size).to eq(item_ids.size)
  end

  it "can separate the arms: at least 30 items and 10 queries spanning three classes" do
    expect(items.size).to be >= 30
    expect(queries.size).to be >= 10
    expect(queries.map { |query| query[:class] }.uniq.sort)
      .to eq(%w[exact-lexical semantic-paraphrase wikilink-reachable])
  end

  it "is synthetic-only: no PHI-shaped content (patient names, MRNs, dates of birth)" do
    blob = items.flat_map { |item| [item[:description], item[:body]] }.join("\n")
    expect(blob).not_to match(/\bpatient\b/i)
    expect(blob).not_to match(/\bmrn\b/i)
    expect(blob).not_to match(/\bdob\b/i)
    expect(blob).not_to match(/\b\d{3}-\d{2}-\d{4}\b/) # SSN shape
  end

  describe "exact-lexical queries" do
    it "share at least one content token with every one of their gold items" do
      queries.select { |query| query[:class] == "exact-lexical" }.each do |query|
        query_tokens = tokens(query[:query])
        query[:gold_ids].each do |gold_id|
          gold_item = items.find { |item| item[:id] == gold_id }
          overlap = query_tokens & item_tokens(gold_item)
          expect(overlap).not_to be_empty,
                                 "exact-lexical query #{query[:query].inspect} shares no tokens with #{gold_id}"
        end
      end
    end
  end

  describe "semantic-paraphrase queries" do
    it "share ZERO tokens with their gold item -- only meaning, not lexical overlap, finds it" do
      queries.select { |query| query[:class] == "semantic-paraphrase" }.each do |query|
        query_tokens = tokens(query[:query])
        query[:gold_ids].each do |gold_id|
          gold_item = items.find { |item| item[:id] == gold_id }
          overlap = query_tokens & item_tokens(gold_item)
          expect(overlap).to be_empty,
                             "paraphrase query #{query[:query].inspect} leaks tokens #{overlap} into #{gold_id}"
        end
      end
    end
  end

  describe "wikilink-reachable queries" do
    it "share zero tokens with their gold leaf items, reachable only via a [[wikilink]] hub" do
      queries.select { |query| query[:class] == "wikilink-reachable" }.each do |query|
        query_tokens = tokens(query[:query])
        query[:gold_ids].each do |gold_id|
          gold_item = items.find { |item| item[:id] == gold_id }
          overlap = query_tokens & item_tokens(gold_item)
          expect(overlap).to be_empty,
                             "wikilink query #{query[:query].inspect} leaks tokens #{overlap} into leaf #{gold_id}"
        end
      end
    end

    it "reaches every gold id through a hub item that both matches the query and links to it" do
      queries.select { |query| query[:class] == "wikilink-reachable" }.each do |query|
        query_tokens = tokens(query[:query])
        hubs = items.select { |item| query_tokens.intersect?(item_tokens(item)) }

        query[:gold_ids].each do |gold_id|
          linking_hub = hubs.find { |hub| linked_ids(hub).include?(gold_id) }
          expect(linking_hub).not_to be_nil,
                                     "no lexically-matched hub links to #{gold_id} for query #{query[:query].inspect}"
        end
      end
    end
  end
end
