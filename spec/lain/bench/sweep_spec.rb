# frozen_string_literal: true

require "json"
require "tempfile"

# Bench::Sweep is the M6 retrieval eval (6-2.4): a deterministic, offline
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

  # The data rows of the ranked table: [arm, n, mean, median, min, max, tokens].
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
      expect(names).to contain_exactly(*arms)
    end

    it "ranks the arms by descending recall@k mean" do
      means = arm_rows(report).map { |row| Float(row[2]) }
      expect(means).to eq(means.sort.reverse)
    end

    it "runs entirely offline -- the vector arm reads committed fixture embeddings, not the network" do
      # Any outbound HTTP would raise under the suite's webmock posture; a clean
      # report is the proof there was none.
      expect { described_class.new(k: 5).report }.not_to raise_error
    end

    it "carries a tokens-on-recall column, one non-negative value per arm" do
      tokens = arm_rows(report).map { |row| Float(row.last) }
      expect(tokens).to all(be >= 0)
      expect(tokens.size).to eq(arms.size)
    end

    it "surfaces real retrieval signal -- the top-ranked arm recalls something" do
      top_mean = arm_rows(report).map { |row| Float(row[2]) }.max
      expect(top_mean).to be > 0
    end

    it "names the corpus size and k in its header" do
      expect(report).to match(/recall@5/).and match(/12 queries/).and match(/32 items/)
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
        .to raise_error(Lain::Bench::Sweep::StaleEmbeddings, /some-other-model/) { |e|
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
        .to raise_error(Lain::Bench::Sweep::StaleEmbeddings, /content digest/)
    ensure
      tampered&.close!
    end
  end

  describe "k validation" do
    it "refuses a non-positive k at construction, where the mistake was made" do
      expect { described_class.new(k: 0) }.to raise_error(ArgumentError, /k/)
    end
  end
end
