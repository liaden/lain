# frozen_string_literal: true

# The first of the two records the baton writes, journaled by {Review#open}
# before the baton is held. Its `type` string -- derived from the class name,
# never hand-written -- is a DURABLE journal discriminator: a rename re-labels
# records nobody can join any more, so it is pinned here.
RSpec.describe Lain::Epic::ReviewOpened do
  def opened(**overrides)
    described_class.new(epic_slug: "alpha", path: "/srv/state/lain/epics/alpha/epic.md", generation: 1,
                        written_digest: "blake3:beef", graph_digest: "blake3:cafe", **overrides)
  end

  it "journals under the underscored basename of its class" do
    expect(opened.journal_type).to eq("review_opened")
    expect(described_class::JOURNAL_TYPE).to eq("review_opened")
  end

  it "refuses an unnamed epic, an unheld path, and the byte digest missing" do
    expect { opened(epic_slug: nil) }.to raise_error(ArgumentError, /epic_slug/)
    expect { opened(path: "  ") }.to raise_error(ArgumentError, /path/)
    expect { opened(written_digest: nil) }.to raise_error(ArgumentError, /written_digest/)
  end

  # Not an omission from the example above: a prose artifact HAS no graph, so
  # nil is its honest graph address rather than a missing one. The empty string
  # is what the record must never hold -- an address-shaped value addressing
  # nothing -- and `&&=` is what keeps the two apart.
  it "keeps a prose review's absent graph digest absent rather than blank" do
    expect(opened(graph_digest: nil).graph_digest).to be_nil
  end

  it "refuses a generation that is not the positive integer identifying a review" do
    expect { opened(generation: 0) }.to raise_error(ArgumentError, /generation/)
    expect { opened(generation: nil) }.to raise_error(ArgumentError, /generation/)
    expect { opened(generation: "later") }.to raise_error(ArgumentError, /generation/)
  end

  it "refuses fractional and non-canonical wire generations" do
    expect { opened(generation: 1.9) }.to raise_error(ArgumentError, /generation/)
    expect { opened(generation: "3junk") }.to raise_error(ArgumentError, /generation/)
  end

  it "reads a wire generation as the integer it keys on" do
    expect(opened(generation: "3").generation).to eq(3)
  end

  it "is a deeply frozen, shareable value" do
    expect(opened).to be_deeply_frozen
  end
end
