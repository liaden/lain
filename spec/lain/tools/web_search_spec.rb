# frozen_string_literal: true

RSpec.describe Lain::Tools::WebSearch do
  # The tool is credential-agnostic: it owns no API key or endpoint. A backend
  # is injected; the tool only renders whatever ranked results it returns. Specs
  # inject a static backend -- never a live search API.
  def result(title:, url:, snippet: nil)
    Lain::Tools::WebSearch::Result.new(title:, url:, snippet:)
  end

  let(:backend) do
    hits = [result(title: "Frozen string literals", url: "https://ruby-doc.org/frozen",
                   snippet: "magic comment"),
            result(title: "String#freeze", url: "https://ruby-doc.org/freeze")]
    ->(_query) { hits }
  end

  subject(:tool) { described_class.new(backend:) }

  it "has a model-facing name and description" do
    expect(tool.name).to eq("web_search")
    expect(tool.description).to be_a(String)
    expect(tool.description).not_to be_empty
  end

  # Tier 1: bounded by the injected backend, not an approval gate.
  it "is not gated by approval" do
    expect(tool.requires_approval?).to be(false)
  end

  it "returns titled, linked results from the injected backend" do
    result = tool.call({ query: "ruby frozen string" }, nil)
    expect(result).to be_ok
    expect(result.content).to include("Frozen string literals")
    expect(result.content).to include("https://ruby-doc.org/frozen")
    expect(result.content).to include("String#freeze")
    expect(result.content).to include("https://ruby-doc.org/freeze")
  end

  it "passes the query through to the backend" do
    seen = []
    tool = described_class.new(backend: ->(query) { seen << query and [] })
    tool.call({ query: "medical literature" }, nil)
    expect(seen).to eq(["medical literature"])
  end

  it "reports no results as an ok Result rather than an empty crash" do
    tool = described_class.new(backend: ->(_query) { [] })
    result = tool.call({ query: "nothing matches" }, nil)
    expect(result).to be_ok
    expect(result.content).to match(/no results/i)
  end

  it "surfaces a raising backend as a loud error Result, not a crash" do
    tool = described_class.new(backend: ->(_query) { raise "backend down" })
    result = tool.call({ query: "boom" }, nil)
    expect(result).to be_error
    expect(result.content).to match(/backend down/)
  end

  describe "the default (unconfigured) backend" do
    # Ships with a Null backend so the tool is constructible without wiring in a
    # concrete provider. An unconfigured search yields nothing, loudly labelled.
    it "constructs with no backend and returns a no-backend result" do
      result = described_class.new.call({ query: "anything" }, nil)
      expect(result).to be_ok
      expect(result.content).to match(/no.*backend|no results/i)
    end
  end
end
