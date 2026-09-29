# frozen_string_literal: true

RSpec.describe Lain::Memory::Recorder do
  subject(:recorder) { described_class.new }

  def item(id, body = "v1")
    Lain::Memory::Item.new(id:, description: "about #{id}", body:)
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

  # A Recorder IS a session's view of the project memory store: what the store
  # held when this session opened, plus the writes made since.
  describe "as a view over a store" do
    # A recording store, so what reaches it is asserted directly rather than
    # through a file this unit has no business knowing about.
    let(:appended) { [] }
    let(:store) { double_store(appended) }

    def double_store(collected)
      Class.new do
        define_method(:append) { |item| collected << item }
      end.new
    end

    it "keeps nothing durable by default, so a bare Recorder is unchanged" do
      expect(recorder.loaded).to eq(Lain::Memory::ProjectStore.empty)
      expect { recorder.write(item("a")) }.not_to raise_error
    end

    it "appends a write to the store as well as to the view" do
      view = described_class.new(store:)
      view.write(item("dosage"))

      expect(appended.map(&:id)).to eq(["dosage"])
      expect(view.fetch("dosage").body).to eq("v1")
    end

    # The store first, the view second: a store that refuses leaves the view
    # where it was rather than rendering an item nothing durable holds.
    it "leaves the view unmoved when the store refuses the write" do
      refusing = Class.new { def append(_item) = raise(IOError, "disk") }.new
      view = described_class.new(store: refusing)

      expect { view.write(item("a")) }.to raise_error(IOError)
      expect(view.index).to be_empty
    end

    it "carries the load it opened on, which is what a session file records" do
      loaded = Lain::Memory::ProjectStore::Loaded.of([item("seeded")])
      view = described_class.new(index: loaded.index, loaded:)

      expect(view.loaded).to eq(loaded)
      expect(view.fetch("seeded").body).to eq("v1")
    end
  end

  # The whole point of the Recorder: it satisfies the index duck MemoryRead
  # was built against, so no constructor contract changes for the reader.
  it "satisfies the index duck MemoryRead depends on" do
    recorder.write(item("dosage", "500mg"))
    reader = Lain::Tools::MemoryRead.new(index: recorder)
    expect(reader.call(id: "dosage")).to eq(Lain::Tool::Result.ok("author: chat\n500mg"))
  end
end
