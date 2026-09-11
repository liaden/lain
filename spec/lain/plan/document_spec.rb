# frozen_string_literal: true

# The plan as a deeply frozen, content-addressed value: ordered steps split into
# chunks by author-editable seams, every mutation returning a new value, and two
# renderings -- the live #to_reminder projection (the Workspace tail) and the
# author-editable #to_markdown that round-trips back to the same digest.
RSpec.describe Lain::Plan::Document do
  subject(:document) { described_class.new(steps:) }

  let(:steps) do
    [
      Lain::Plan::Step.new(id: "s1", title: "First step", size: "M"),
      Lain::Plan::Step.new(id: "s2", title: "Second step", size: "S", criteria_digest: "blake3:abc123"),
      Lain::Plan::Step.new(id: "s3", title: "Third step", size: "L")
    ]
  end

  describe "chunks and seams" do
    # Given a document with three steps and seams after each [internal boundary].
    subject(:seamed) { document.insert_seam(after: "s1").insert_seam(after: "s2") }

    it "splits into one chunk per step when every boundary is seamed" do
      expect(seamed.chunks.map { |chunk| chunk.map(&:id) }).to eq([["s1"], ["s2"], ["s3"]])
    end

    it "merges the adjacent chunks when a seam is removed, showing exactly one seam" do
      merged = seamed.remove_seam(after: "s2")

      expect(merged.chunks.map { |chunk| chunk.map(&:id) }).to eq([["s1"], %w[s2 s3]])
      expect(merged.to_markdown.scan("---").size).to eq(1)
    end

    it "is one chunk with no seams" do
      expect(document.chunks.map { |chunk| chunk.map(&:id) }).to eq([%w[s1 s2 s3]])
    end

    it "refuses a seam after a step that does not exist" do
      expect { document.insert_seam(after: "nope") }.to raise_error(Lain::Plan::UnknownStep)
    end

    it "refuses a seam after the last step (it bounds nothing)" do
      expect { document.insert_seam(after: "s3") }.to raise_error(ArgumentError, /last step/)
    end

    it "refuses to remove a seam that is not there" do
      expect { document.remove_seam(after: "s2") }.to raise_error(Lain::Plan::UnknownStep)
    end

    it "normalizes an equivalent seam set to one value regardless of build order" do
      a = document.insert_seam(after: "s2").insert_seam(after: "s1")
      b = document.insert_seam(after: "s1").insert_seam(after: "s2")

      expect(a).to eq(b)
      expect(a.digest).to eq(b.digest)
    end
  end

  describe "#advance" do
    it "returns a new document with only the named step's status changed" do
      advanced = document.advance("s2", status: "done")

      expect(document.steps.map(&:status)).to eq(%w[pending pending pending]) # original untouched
      expect(advanced.steps.map(&:status)).to eq(%w[pending done pending])
    end

    it "refuses to advance a step that does not exist" do
      expect { document.advance("nope", status: "done") }.to raise_error(Lain::Plan::UnknownStep)
    end
  end

  describe "immutability -- the sent-not-stored carrier never mutates" do
    it "is Ractor.shareable? (deeply frozen, no reachable mutable state)" do
      expect(document.insert_seam(after: "s1").advance("s1", status: "active")).to be_deeply_frozen
    end

    it "has Ractor.shareable? steps" do
      expect(document.steps).to all(be_deeply_frozen)
    end

    it "is value-equal to another document built from the same inputs" do
      expect(described_class.new(steps:)).to eq(described_class.new(steps:))
    end

    # The constructor must not freeze the caller's array in place -- it copies
    # before freezing, so a caller can keep mutating its own steps array.
    it "leaves the caller's steps array unfrozen" do
      caller_steps = steps.dup
      described_class.new(steps: caller_steps)

      expect(caller_steps).not_to be_frozen
    end
  end

  describe "#digest -- content-addressed, Store-borne" do
    it "is a blake3 content address" do
      expect(document.digest).to start_with("blake3:")
    end

    it "changes when a step's status changes" do
      expect(document.advance("s1", status: "done").digest).not_to eq(document.digest)
    end

    it "survives a Store round-trip by digest (so it survives fork/replay)" do
      store = Lain::Store.new
      digest = store.put(document)

      expect(digest).to eq(document.digest)
      expect(store.fetch(digest)).to eq(document)
    end
  end

  describe "#to_reminder -- the Workspace projection" do
    subject(:reminder) { document.insert_seam(after: "s1").advance("s1", status: "active").to_reminder }

    it "names the chunks and each step's status" do
      expect(reminder).to include("Chunk 1", "Chunk 2")
      expect(reminder).to include("s1", "active")
      expect(reminder).to include("s3", "pending")
    end

    it "rides the Workspace as an ordinary tagged reminder block" do
      block = Lain::Workspace.empty.with(reminder).to_blocks.first

      expect(block["text"]).to include("Chunk 1")
    end
  end

  describe "#to_markdown -- the author-editable artifact that round-trips" do
    subject(:edited) { document.insert_seam(after: "s1").advance("s3", status: "done") }

    it "shows visible seams, sizes, statuses, and criteria references" do
      markdown = edited.to_markdown

      expect(markdown).to include("- [ ] `s1` (M) First step")
      expect(markdown).to include("- [ ] `s2` (S) Second step {blake3:abc123}")
      expect(markdown).to include("- [x] `s3` (L) Third step")
      expect(markdown).to include("\n---\n")
    end

    it "parses back to a value with the same digest -- the author-review loop" do
      parsed = described_class.parse_markdown(edited.to_markdown)

      expect(parsed).to eq(edited)
      expect(parsed.digest).to eq(edited.digest)
    end

    it "ignores prose and blank lines around the plan on the way back" do
      decorated = "Some intro.\n\n#{document.to_markdown}\n\nSome outro.\n"

      expect(described_class.parse_markdown(decorated).digest).to eq(document.digest)
    end
  end
end
