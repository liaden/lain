# frozen_string_literal: true

# The baton's other record, journaled by {Review#settle}. It reports a
# comparison rather than an intent, so what it refuses is what would let an
# empty `changes` mean two different things; its discriminator is pinned for
# {ReviewOpened}'s reason.
RSpec.describe Lain::Epic::ReviewClosed do
  def closed(**overrides)
    described_class.new(epic_slug: "alpha", path: "/srv/state/lain/epics/alpha/epic.md", generation: 1,
                        written_digest: "blake3:beef", disk_digest: "blake3:feed",
                        changes: { retitled: ["b2"] }, lossy: false, **overrides)
  end

  it "journals under the underscored basename of its class" do
    expect(closed.journal_type).to eq("review_closed")
    expect(described_class::JOURNAL_TYPE).to eq("review_closed")
  end

  it "string-keys the structural summary, so a record read back from JSON equals the one written" do
    expect(closed.changes).to eq({ "retitled" => ["b2"] })
    expect(closed(changes: { "retitled" => ["b2"] })).to eq(closed)
  end

  it "refuses a summary that is not the account's Hash of changed kinds" do
    expect { closed(changes: nil) }.to raise_error(ArgumentError, /changes/)
    expect { closed(changes: %w[retitled]) }.to raise_error(ArgumentError, /changes/)
  end

  it "refuses a suspicion that is not a boolean, since lossy is one measure and not a level" do
    expect { closed(lossy: nil) }.to raise_error(ArgumentError, /lossy/)
    expect { closed(lossy: "maybe") }.to raise_error(ArgumentError, /lossy/)
  end

  it "keeps a parse error and its kind together, the way the delta it reports does" do
    expect { closed(error: "no heading") }.to raise_error(ArgumentError, /error/)
    expect { closed(error_kind: "Lain::Epic::MalformedDocument") }.to raise_error(ArgumentError, /error/)
    expect(closed(error: "no heading", error_kind: "Lain::Epic::MalformedDocument").error_kind)
      .to eq("Lain::Epic::MalformedDocument")
  end

  it "is a deeply frozen, shareable value even with a nested summary" do
    expect(closed(changes: { retitled: ["b2"], removed: ["c"] })).to be_deeply_frozen
    expect(closed).to be_deeply_frozen
  end
end
