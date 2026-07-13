# frozen_string_literal: true

require "lain/memory/recorder"
require "lain/memory/index"
require "lain/memory/item"
require "lain/tools/memory_read"
require "lain/tool"

RSpec.describe Lain::Memory::Recorder do
  subject(:recorder) { described_class.new }

  def item(id, body = "v1")
    Lain::Memory::Item.new(id: id, description: "about #{id}", body: body)
  end

  describe "over an empty index" do
    it "starts with no root" do
      expect(recorder.root).to be_nil
    end

    it "exposes the underlying (empty) Index" do
      expect(recorder.index).to eq(Lain::Memory::Index.empty)
    end
  end

  describe "#write" do
    it "bumps the root and returns it" do
      root = recorder.write(item("a"))
      expect(root).not_to be_nil
      expect(recorder.root).to eq(root)
    end

    it "is a NEW write reachable afterwards via #fetch" do
      recorder.write(item("dosage", "v1"))
      expect(recorder.fetch("dosage").body).to eq("v1")
    end

    it "leaves the prior write reachable via checkout of the old root" do
      recorder.write(item("dosage", "v1"))
      old_root = recorder.root
      recorder.write(item("dosage", "v2"))

      expect(recorder.root).not_to eq(old_root)
      expect(recorder.index.checkout(old_root).fetch("dosage").body).to eq("v1")
    end
  end

  describe "#fetch" do
    it "delegates to the current snapshot, raising the same UnknownId" do
      expect { recorder.fetch("nope") }.to raise_error(Lain::Memory::Index::UnknownId, /nope/)
    end
  end

  # The whole point of the Recorder: it satisfies the index duck MemoryRead
  # was built against, so no constructor contract changes for the reader.
  it "satisfies the index duck MemoryRead depends on" do
    recorder.write(item("dosage", "500mg"))
    reader = Lain::Tools::MemoryRead.new(index: recorder)
    expect(reader.call(id: "dosage")).to eq(Lain::Tool::Result.ok("500mg"))
  end
end
