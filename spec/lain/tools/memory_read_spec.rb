# frozen_string_literal: true

require "lain/tools/memory_read"
require "lain/memory/index"
require "lain/memory/item"

RSpec.describe Lain::Tools::MemoryRead do
  subject(:tool) { described_class.new(index: index) }

  let(:item) do
    Lain::Memory::Item.new(
      id: "dosage",
      description: "Adult dosage guidance for the trial drug",
      body: "500mg twice daily with food.\nHalve for renal impairment."
    )
  end
  let(:index) { Lain::Memory::Index.empty.write(item) }

  it "has a model-facing name and description" do
    expect(tool.name).to eq("memory_read")
    expect(tool.description).to be_a(String)
    expect(tool.description).not_to be_empty
  end

  it "is not gated by approval and is tier 1 (no subprocess involved)" do
    expect(tool.requires_approval?).to be(false)
  end

  it "returns the item's body verbatim on a hit" do
    expect(tool.call(id: "dosage")).to eq(Lain::Tool::Result.ok(item.body))
  end

  it "answers an unknown id with an error Result naming the id, never a raise" do
    result = nil
    expect { result = tool.call(id: "half-life") }.not_to raise_error
    expect(result).to have_attributes(is_error: true, content: /no memory with id.*half-life/)
  end

  it "does not care about the invocation it is handed" do
    invocation = Lain::Tool::Invocation.new(tool_use_id: "tu_1")
    expect(tool.call({ id: "dosage" }, invocation)).to eq(Lain::Tool::Result.ok(item.body))
  end

  it "declares one required string field \"id\"" do
    schema = tool.input_schema
    expect(schema["properties"].keys).to eq(["id"])
    expect(schema["properties"]["id"]).to include("type" => "string")
    expect(schema["required"]).to eq(["id"])
  end
end
