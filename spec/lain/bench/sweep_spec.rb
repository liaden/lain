# frozen_string_literal: true

require "json"
require "tempfile"
require "yaml"

# Bench::Sweep is the retrieval eval: a deterministic, offline
# comparison of the five retrieval arms (manifest, bm25, vector, hybrid, graph)
# over the committed gold corpus, ranked by recall@k with a tokens-on-recall
# column. Zero network -- the vector arm reads committed fixture embeddings, so
# the whole sweep runs under the suite's offline (webmock) posture.
#
# Per the panel amendment, "hybrid earns its place" is NOT a unit assertion here
# (it tests the fixture, not the code -- it moved to the manual close-out). These
# specs assert the MECHANISM: every arm is scored, the arms are ranked by their
# recall@k distribution, tokens-on-recall is reported, and the report is
# byte-deterministic.
RSpec.describe Lain::Bench::Sweep do
  def arms = %w[manifest bm25 vector hybrid graph]

  # The data rows of the ranked table: [arm, n, mean, ci95, median, min, max, tokens, ndcg, abstain, support, control].
  # Parsed straight from the report so the assertions read the ACTUAL rendered
  # bytes, never a private accessor.
  def arm_rows(report)
    report.lines.map(&:chomp).filter_map do |line|
      cells = line.split(/\s{2,}/)
      cells if arms.include?(cells.first)
    end
  end

  describe "#report — the headline retrieval eval" do
    subject(:report) { described_class.new(k: 5).report }

    it "scores every one of the five arms" do
      names = arm_rows(report).map(&:first)
      expect(names).to match_array(arms)
    end

    it "ranks the arms by descending recall@k mean" do
      means = arm_rows(report).map { |row| Float(row[2]) }
      expect(means).to eq(means.sort.reverse)
    end

    # "Runs entirely offline" needs no example of its own: every sibling here
    # builds the same report under the suite's webmock posture, so an outbound
    # request from the vector arm fails all of them at once. A bare
    # `not_to raise_error` beside them could only fail where they already had.
    it "carries a tokens-on-recall column, one non-negative value per arm" do
      tokens = arm_rows(report).map { |row| Float(row[7]) }
      expect(tokens).to all(be >= 0)
      expect(tokens.size).to eq(arms.size)
    end

    it "surfaces real retrieval signal -- the top-ranked arm recalls something" do
      top_mean = arm_rows(report).map { |row| Float(row[2]) }.max
      expect(top_mean).to be > 0
    end

    # The shared six columns come from Compare::ArmFold; the seventh is this
    # sweep's own and rides AFTER them. A row built the other way round would
    # still render seven plausible cells.
    #
    # Spelled out rather than read off ArmFold::HEADERS: an expectation sourced
    # from the constant it pins passes a reorder of that constant unchanged, and
    # this is the only report-level spec anywhere that names the rendered column
    # headings at all.
    it "heads the shared columns, then its own tokens, ranking, abstention, support and control columns" do
      header = report.lines.find { |line| line.start_with?("arm ") }
      expect(header.chomp.split(/\s{2,}/))
        .to eq(["arm", "n", "mean", "ci95", "median", "min", "max", "recall tokens", "ndcg@10", "abstention",
                "support@200", "graph from bm25 top 5"])
    end

    it "names the corpus size and k in its header" do
      expect(report).to include("recall@5").and include("12 queries").and include("32 items")
    end

    it "says it scored the dev split only, and how to reach the test split" do
      expect(report.lines.first).to include("dev split").and include("--split test")
    end

    it "scores nDCG between 0 and 1 for every arm" do
      expect(arm_rows(report).map { |row| Float(row[8]) }).to all(be_between(0.0, 1.0))
    end

    it "scores abstention as a rate, 0.0 for an arm that always returns hits" do
      rates = arm_rows(report).to_h { |row| [row.first, Float(row[9])] }
      expect(rates).to include("vector" => 0.0, "manifest" => 0.5)
    end

    it "carries the bm25-seeded graph control on the graph row only" do
      controls = arm_rows(report).to_h { |row| [row.first, row.last] }
      expect(controls.except("graph").values.uniq).to eq(["-"])
      expect(controls.fetch("graph")).to eq("0.333")
    end

    it "reports the committed dev corpus's full-support rate within 200 tokens" do
      supports = arm_rows(report).to_h { |row| [row.first, row[10]] }
      expect(supports).to include("vector" => "0.667")
    end

    it "stays silent about hybrid when it beats bm25 on the committed corpus" do
      expect(report).not_to include("hybrid does not beat bm25")
    end
  end

  describe "when hybrid ties bm25" do
    it "says so with both recalls" do
      Tempfile.create(["tied_corpus", ".yml"]) do |file|
        corpus = YAML.safe_load_file(described_class::CORPUS_PATH)
        corpus["queries"] = corpus.fetch("queries").select { |raw| raw.fetch("query") == "aspirin dosing guidance" }
        file.write(YAML.dump(corpus))
        file.flush

        report = described_class.new(k: 5, corpus_path: file.path).report

        expect(report).to include("hybrid does not beat bm25 on recall@5 (1.000 vs 1.000)")
      end
    end
  end

  describe "the bm25-seeded graph control" do
    let(:item) { Struct.new(:id, :description, :body) }
    let(:hub) { item.new("hub", "hub", "See [[leaf-a]], [[leaf-b]] and [[seeded]].") }
    let(:items) { [hub, item.new("leaf-a", "a", ""), item.new("leaf-b", "b", ""), item.new("seeded", "s", "")] }
    let(:bm25) do
      Class.new do
        def search(_query) = [Struct.new(:id).new("hub"), Struct.new(:id).new("seeded")]
      end.new
    end
    let(:control) { described_class.const_get(:SeededHop).new(bm25:, items: items.to_h { |i| [i.id, i] }) }

    it "reaches the leaves a seed links to, one hop out" do
      expect(control.search("q").map(&:id)).to include("leaf-a", "leaf-b")
    end

    it "does not count an id that is already a seed twice" do
      expect(control.search("q").map(&:id)).to eq(%w[hub seeded leaf-a leaf-b])
    end
  end

  describe "the dev/test split" do
    it "scores only the held-out queries under split test and names the split" do
      report = described_class.new(k: 5, split: "test").report

      expect(report.lines.first).to include("test split").and include("3 queries")
      expect(report).not_to include("dev split")
    end

    it "keeps dev and test query texts disjoint; gold items may appear in both" do
      queries = YAML.safe_load_file(described_class::CORPUS_PATH).fetch("queries").group_by { |raw| raw.fetch("split") }

      expect(queries.fetch("dev").map { |raw| raw["query"] } & queries.fetch("test").map { |raw| raw["query"] })
        .to be_empty
    end

    it "refuses a split it does not know" do
      expect { described_class.new(split: "train") }.to raise_error(ArgumentError, /split/)
    end
  end

  describe ".fully_supported?" do
    let(:lines) { ["a | #{"word " * 150}", "b | #{"word " * 150}"] }

    it "counts a query only when every gold id fits the token budget" do
      expect(described_class.fully_supported?(lines, %w[a b], budget: 200)).to be(false)
    end

    it "counts a query whose gold ids all fit" do
      expect(described_class.fully_supported?(lines, %w[a], budget: 200)).to be(true)
    end
  end

  describe "determinism" do
    it "renders byte-identical reports across two independent runs" do
      first = described_class.new(k: 5).report
      second = described_class.new(k: 5).report
      expect(first).to eq(second)
    end

    it "renders byte-identical reports when the same instance reports twice" do
      sweep = described_class.new(k: 5)
      expect(sweep.report).to eq(sweep.report)
    end
  end

  describe "stale embeddings are loud" do
    it "raises naming BOTH model ids when the fixture was recorded under a different model" do
      stale = Tempfile.new(["stale_embeddings", ".json"])
      stale.write(JSON.generate("model_id" => "some-other-model", "items" => {}, "queries" => {}))
      stale.flush

      expect { described_class.new(k: 5, embeddings_path: stale.path, model: "nomic-embed-text").report }
        .to raise_error(Lain::Error, /some-other-model/) { |e|
          expect(e.message).to include("nomic-embed-text")
        }
    ensure
      stale&.close!
    end

    it "raises on a hand-edited vector -- the recorded content digest no longer matches" do
      data = JSON.parse(File.read(described_class::EMBEDDINGS_PATH))
      digest, vector = data.fetch("items").first
      data["items"][digest] = vector.dup.tap { |values| values[0] += 1.0 }

      tampered = Tempfile.new(["tampered_embeddings", ".json"])
      tampered.write(JSON.generate(data))
      tampered.flush

      expect { described_class.new(k: 5, embeddings_path: tampered.path).report }
        .to raise_error(Lain::Error, /content digest/)
    ensure
      tampered&.close!
    end
  end

  describe "k validation" do
    it "refuses a non-positive k at construction, where the mistake was made" do
      expect { described_class.new(k: 0) }.to raise_error(ArgumentError, /k/)
    end
  end

  describe "a missing corpus refuses namedly" do
    it "raises a Lain::Error naming the missing corpus path, not Errno::ENOENT" do
      missing = "#{described_class::CORPUS_PATH}.does-not-exist"

      expect { described_class.new(k: 5, corpus_path: missing).report }
        .to raise_error(Lain::Bench::Sweep::MissingCorpus, /#{Regexp.escape(missing)}/)
    end

    it "raises a Lain::Error naming a missing embeddings path, not a generic corpus refusal" do
      missing = "#{described_class::EMBEDDINGS_PATH}.does-not-exist"

      expect { described_class.new(k: 5, embeddings_path: missing).report }
        .to raise_error(Lain::Bench::Sweep::MissingCorpus) { |e|
          expect(e.message).to include(missing).and include("embeddings")
          expect(e.message).not_to include("no sweep corpus file")
        }
    end
  end
end
