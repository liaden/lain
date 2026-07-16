# frozen_string_literal: true

require "yaml"
require "json"

# The regeneration path for lib/lain/bench/corpus/corpus_embeddings.json -- the
# committed vectors the offline Bench::Sweep vector arm reads. It is tagged
# :ollama (skipped unless LAIN_OLLAMA=1 with a reachable server), so the DEFAULT
# suite never touches the network: the fixture is committed, the sweep reads it,
# and this spec exists only to RE-RECORD it deterministically when the corpus or
# the embed model changes.
#
# Keyed by item content digest + model id, exactly the shape Sweep::Embeddings
# loads. Regenerate with:
#
#   LAIN_OLLAMA=1 bundle exec rspec spec/lain/bench/sweep_fixture_spec.rb
RSpec.describe "the sweep's committed corpus embeddings", :ollama do
  let(:model) { Lain::Embedder::Ollama::DEFAULT_MODEL }
  let(:corpus_path) { Lain::Bench::Sweep::CORPUS_PATH }
  let(:fixture_path) { Lain::Bench::Sweep::EMBEDDINGS_PATH }
  let(:corpus) { YAML.safe_load_file(corpus_path) }

  def items(corpus)
    corpus.fetch("items").map do |raw|
      Lain::Memory::Item.new(id: raw.fetch("id"), description: raw.fetch("description"), body: raw.fetch("body"))
    end
  end

  # The :ollama hook probes the CHAT DEFAULT_MODEL; the embed model is a
  # different pull, so guard it here too (skip, never fail, when absent). Ollama
  # stores a tagless reference under ":latest", so match the exact name and any
  # "model:tag" form -- the same rule the embedder's live spec uses.
  before do
    names = Array(OllamaTestServer.fetch_tags(OLLAMA_API_BASE)&.[]("models")).filter_map { |entry| entry["name"] }
    present = names.any? { |name| name == model || name.start_with?("#{model}:") }
    skip "embed model #{model.inspect} not pulled -- run `ollama pull #{model}`" unless present
  end

  it "regenerates the committed fixture from a live embed, keyed by item digest + model id" do
    embedder = Lain::Embedder::Ollama.new(model:)
    corpus_items = items(corpus)
    queries = corpus.fetch("queries").map { |raw| raw.fetch("query") }
    item_vectors = embedder.embed(corpus_items.map { |item| "#{item.description}\n#{item.body}" })
    query_vectors = embedder.embed(queries)

    fixture = {
      "model_id" => model,
      "dimension" => item_vectors.first.size,
      "items" => corpus_items.each_index.to_h { |i| [corpus_items[i].digest, item_vectors[i]] },
      "queries" => queries.each_index.to_h { |i| [queries[i], query_vectors[i]] }
    }
    # Canonical over everything but the digest itself -- the corruption check
    # Sweep::Embeddings.load verifies, so a hand-edited float is loud.
    fixture["content_digest"] = Lain::Canonical.digest(fixture)
    File.write(fixture_path, "#{JSON.pretty_generate(fixture)}\n")

    # The whole contract Sweep::Embeddings depends on: model id present, every
    # item and query embedded, equal dimension. If this holds, the offline sweep
    # loads clean.
    reloaded = JSON.parse(File.read(fixture_path))
    expect(reloaded.fetch("model_id")).to eq(model)
    expect(reloaded.fetch("items").size).to eq(corpus_items.size)
    expect(reloaded.fetch("queries").size).to eq(queries.size)
    expect(reloaded.fetch("items").values.map(&:size).uniq).to eq([item_vectors.first.size])
    expect { Lain::Bench::Sweep.new(k: 5).report }.not_to raise_error
  end
end
