# frozen_string_literal: true

RSpec.describe Lain::Tools::MemoryRead do
  subject(:tool) { described_class.new(index:) }

  let(:item) do
    Lain::Memory::Item.new(
      id: "dosage",
      description: "Adult dosage guidance for the trial drug",
      body: "500mg twice daily with food.\nHalve for renal impairment."
    )
  end
  let(:index) { Lain::Memory::Index.empty.write(item) }

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

  # The same tier-1 contract this tool states in its own docstring ("never a
  # raise"), over the byte shapes that break readers. It runs the BYTE half
  # only: the path half is a filesystem's to pose, and non-UTF-8 is not a shape
  # a memory item can even take -- Canonical refuses those bytes when the Item
  # is constructed, which is a different boundary and a correct one.
  describe "the tier-1 read contract, over pathological bodies" do
    def read_ceiling = Lain::Tools::MemoryRead::BOUND.limit

    def read_of(bytes)
      body = Lain::Memory::Item.new(id: "shape", description: "one shape", body: bytes)
      described_class.new(index: Lain::Memory::Index.empty.write(body)).call(id: "shape")
    end

    it_behaves_like "a tier-1 read that never raises"
  end

  # T5: a memory body is a whole artifact like a file's contents, so an
  # oversized one is refused rather than truncated. It is the THIN case of the
  # three -- there is no window on memory and no structural query over it -- so
  # what the refusal names is the manifest line every item already has and the
  # superseding write that can replace it.
  describe "refusing a body too large to hand back" do
    let(:ceiling) { Lain::Tools::MemoryRead::BOUND.limit }

    let(:oversized) do
      Lain::Memory::Item.new(id: "dump", description: "A whole log, pasted",
                             body: "SENTINEL\n" * ((ceiling / 9) + 2))
    end
    let(:index) { Lain::Memory::Index.empty.write(item).write(oversized) }

    it "refuses the read, naming the body's size and the ceiling" do
      result = tool.call(id: "dump")

      expect(result).to have_attributes(is_error: true)
      expect(result.content).to include("dump", oversized.body.bytesize.to_s, ceiling.to_s)
    end

    it "carries none of the refused body" do
      expect(tool.call(id: "dump").content).not_to include("SENTINEL")
    end

    # Fix round, S1: neither of the first draft's two narrower actions survived
    # being followed. There is no manifest TOOL -- the manifest rides every
    # Request through Workspace -- so "read the manifest" named a call the
    # model cannot make; and "supersede it with a smaller memory_write" is
    # destructive AND needs the bytes it was just denied. What is left is a
    # fact it already has and a call it can actually place.
    it "names only actions that exist" do
      content = tool.call(id: "dump").content

      expect(content).to include("manifest already in your context", "different id")
      expect(content).not_to include("supersede")
    end

    # It may MENTION memory_write to explain why an item this large exists at
    # all; what it must not do is send the model there, because superseding an
    # id needs the bytes this refusal just withheld and destroys them either
    # way.
    it "does not send the model to a memory_write that cannot help it" do
      expect(Lain::Tools::MemoryRead::NARROWER.join(" ")).not_to match(/supersede|write a smaller|replace it/)
    end

    it "leaves every item under the ceiling readable" do
      expect(tool.call(id: "dosage")).to eq(Lain::Tool::Result.ok(item.body))
    end
  end
end
