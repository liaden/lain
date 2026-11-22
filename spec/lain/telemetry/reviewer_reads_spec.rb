# frozen_string_literal: true

# What an implementation reviewer read, keyed by the issue it reviewed and the
# commit its lease was cut from, so the gate can say whether its verdict rests
# on anything.
RSpec.describe Lain::Telemetry::ReviewerReads do
  it "journals as reviewer_reads, naming the epic, the issue, the commit and each read" do
    record = described_class.new(epic_slug: "demo", issue_id: "a", sha: "abc123",
                                 reads: ["lib/a.rb", "git show abc123:src/a.rs"])

    expect(JSON.generate(record.to_journal)).to eq(
      '{"type":"reviewer_reads","epic_slug":"demo","issue_id":"a","sha":"abc123",' \
      '"reads":["lib/a.rb","git show abc123:src/a.rs"]}'
    )
  end

  it "reads back from its journal line as the value it was written from" do
    record = described_class.new(epic_slug: "demo", issue_id: "a", sha: "abc123", reads: [])
    io = StringIO.new
    Lain::Journal.new(io:, chain: Lain::Journal::Line::ORIGIN).record(record)

    expect(Lain::Telemetry.read(Lain::Journal.parse(io.string))).to eq(record)
  end

  it "refuses a record that names no epic, no issue or no commit" do
    expect { described_class.new(epic_slug: " ", issue_id: "a", sha: "abc", reads: []) }
      .to raise_error(ArgumentError, /epic_slug/)
    expect { described_class.new(epic_slug: "demo", issue_id: "", sha: "abc", reads: []) }
      .to raise_error(ArgumentError, /issue_id/)
    expect { described_class.new(epic_slug: "demo", issue_id: "a", sha: nil, reads: []) }
      .to raise_error(ArgumentError, /sha/)
  end

  it "is deeply frozen, even from unfrozen strings" do
    expect(described_class.new(epic_slug: +"demo", issue_id: +"a", sha: +"abc", reads: [+"lib/a.rb"]))
      .to be_deeply_frozen
  end
end
