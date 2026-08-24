# frozen_string_literal: true

# T15 (chunk-ollama-cloud-arm.md): characterizes what {Lain::Friction::Report}
# already does over a session priced on an arm {Lain::PriceBook::DEFAULT} has
# no row for -- Ollama Cloud is metered by subscription quota, not per-token
# dollars, and the report must neither fabricate a figure nor crash trying to
# produce one. Both halves turned out to already be true: {Friction::CacheWaste}
# rescues {PriceBook::UnknownModel} per model (`cache_waste.rb:502`) and
# {Friction::Report::CacheWasteSection#figure_phrase} withholds a figure with
# nothing priceable behind it (`report.rb:317-335`) rather than printing a
# confident `$0.000000`. This file exists at the mirrored path CLAUDE.md
# specifies; the class's broader coverage predates that convention and stays
# at `spec/lain/friction_spec.rb`, untouched by this card.
RSpec.describe Lain::Friction::Report do
  def request_sent(digest, model)
    { "type" => "request_sent", "digest" => "blake3:req", "payload" => { "model" => model },
      "prefix_chain_version" => 1, "prefix_digests" => [[0, digest]] }
  end

  def turn_usage(model, read: 0, create: 0)
    { "type" => "turn_usage", "digest" => "blake3:turn", "model" => model,
      "usage" => { "input_tokens" => 10, "output_tokens" => 10,
                   "cache_creation_input_tokens" => create, "cache_read_input_tokens" => read } }
  end

  # AC 1. A prefix break followed by a re-billed cache-creation write and a
  # served cache-read, both against a model PriceBook::DEFAULT has no row for
  # -- the shape that would otherwise raise UnknownModel mid-render.
  describe "a session whose payments name an ollama model" do
    subject(:rendered) { described_class.new(entries).render }

    let(:model) { "qwen3:4b" }
    let(:entries) do
      [request_sent("a", model), turn_usage(model),
       request_sent("b", model), turn_usage(model, read: 5_000, create: 2_000)]
    end

    it "does not raise" do
      expect { rendered }.not_to raise_error
    end

    it "states token figures" do
      expect(rendered).to include("2000 tokens re-billed")
      expect(rendered).to include("5000 tokens served from cache")
    end

    it "states no dollar figure" do
      expect(rendered).not_to include("$")
    end

    it "says which model the withheld figures exclude" do
      expect(rendered).to include("dollar figures exclude qwen3:4b -- no price recorded")
    end
  end
end
