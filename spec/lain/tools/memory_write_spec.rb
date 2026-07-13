# frozen_string_literal: true

require "lain/tools/memory_write"
require "lain/tools/memory_read"
require "lain/memory/recorder"
require "lain/tool/invocation"

RSpec.describe Lain::Tools::MemoryWrite do
  subject(:tool) { described_class.new(recorder: recorder) }

  let(:recorder) { Lain::Memory::Recorder.new }

  it "has a model-facing name and description" do
    expect(tool.name).to eq("memory_write")
    expect(tool.description).to be_a(String)
    expect(tool.description).not_to be_empty
  end

  it "is not gated by approval and is tier 1 (no subprocess involved)" do
    expect(tool.requires_approval?).to be(false)
  end

  it "declares id, description, and body as required string fields" do
    schema = tool.input_schema
    expect(schema["properties"].keys).to eq(%w[id description body])
    expect(schema["required"]).to eq(%w[id description body])
  end

  describe "a write" do
    it "bumps the recorder's root and names the id and new root in the result" do
      result = tool.call(id: "dosage", description: "Adult dosage", body: "500mg twice daily")

      expect(result.is_error).to be(false)
      expect(result.content).to include("dosage").and include(recorder.root)
    end

    it "leaves a superseded write reachable via checkout of the old root" do
      tool.call(id: "dosage", description: "v1 guidance", body: "v1 body")
      old_root = recorder.root

      tool.call(id: "dosage", description: "v2 guidance", body: "v2 body")

      expect(recorder.root).not_to eq(old_root)
      expect(recorder.index.checkout(old_root).fetch("dosage").body).to eq("v1 body")
    end
  end

  describe "input rejection" do
    # `required: true` means ActiveModel presence validation, which rejects a
    # blank-but-present id in #validate_input! -- BEFORE #perform runs, so
    # Item's own blank check is never reached and the raise carries
    # ActiveModel's generic message. Handler::Live is the layer that converts
    # this raise into an error Result; a unit spec honestly sees the raise.
    it "raises Tool::InvalidInput on a blank id, before #perform ever runs" do
      expect { tool.call(id: "   ", description: "d", body: "b") }
        .to raise_error(Lain::Tool::InvalidInput)
      expect(recorder.root).to be_nil
    end

    # A multi-line id is present, so it passes the schema layer; only Item's
    # #one_line rejection reaches the tool's rescue and becomes an error Result.
    it "reports a multi-line id as an error Result via Item's one-line check" do
      result = tool.call(id: "two\nlines", description: "d", body: "b")
      expect(result).to have_attributes(is_error: true, content: /one line/)
      expect(recorder.root).to be_nil
    end
  end

  describe "reads in the same session" do
    it "see a write made through a MemoryRead sharing the same recorder" do
      reader = Lain::Tools::MemoryRead.new(index: recorder)
      tool.call(id: "dosage", description: "Adult dosage", body: "500mg twice daily")

      expect(reader.call(id: "dosage")).to eq(Lain::Tool::Result.ok("500mg twice daily"))
    end
  end

  it "does not care about the invocation it is handed" do
    invocation = Lain::Tool::Invocation.new(tool_use_id: "tu_1")
    result = tool.call({ id: "a", description: "about a", body: "body" }, invocation)
    expect(result.is_error).to be(false)
  end
end
