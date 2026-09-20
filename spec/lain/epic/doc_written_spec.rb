# frozen_string_literal: true

# The record {Home::Journaled} writes after an artifact lands. Its `type`
# string -- derived from the class name, never hand-written -- is a DURABLE
# journal discriminator, so it is pinned here as its siblings are.
RSpec.describe Lain::Epic::DocWritten do
  def written(**overrides)
    described_class.new(epic_slug: "alpha", kind: "epic", path: "epic.md",
                        byte_digest: "blake3:beef", graph_digest: "blake3:cafe", **overrides)
  end

  it "journals under the underscored basename of its class" do
    expect(written.journal_type).to eq("doc_written")
    expect(described_class::JOURNAL_TYPE).to eq("doc_written")
  end

  it "refuses a kind outside the four artifacts a home holds" do
    expect { written(kind: "notes") }.to raise_error(ArgumentError, /kind/)
  end

  it "refuses an unnamed epic, an unnamed path, and undigested bytes" do
    expect { written(epic_slug: nil) }.to raise_error(ArgumentError, /epic_slug/)
    expect { written(path: "  ") }.to raise_error(ArgumentError, /path/)
    expect { written(byte_digest: nil) }.to raise_error(ArgumentError, /byte_digest/)
  end

  it "leaves the graph digest optional, since only an epic write has one" do
    expect(written(graph_digest: nil).graph_digest).to be_nil
    expect(described_class.new(epic_slug: "alpha", kind: "research", path: "research.md",
                               byte_digest: "blake3:beef").graph_digest).to be_nil
  end

  it "is a deeply frozen, shareable value" do
    expect(written).to be_deeply_frozen
  end
end
