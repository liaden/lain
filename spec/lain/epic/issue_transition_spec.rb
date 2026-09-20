# frozen_string_literal: true

require "stringio"

# One issue's status change, journaled. It is a Journalable Data value like
# every other Lain::Telemetry event, and its `type` string -- derived from the
# class name, never hand-written -- is a DURABLE journal discriminator: a
# rename re-labels records nobody can join any more, so it is pinned here.
RSpec.describe Lain::Epic::IssueTransition do
  def journaled(*records)
    io = StringIO.new
    journal = Lain::Journal.new(io:)
    records.each { |record| journal.record(record) }
    io.string.lines
  end

  def transition(**overrides)
    described_class.new(epic_slug: "alpha", issue_id: "a", from_status: "pending",
                        to_status: "done", **overrides)
  end

  it "journals under the underscored basename of its class" do
    expect(transition.journal_type).to eq("issue_transition")
    expect(described_class::JOURNAL_TYPE).to eq("issue_transition")
  end

  it "round-trips through the journal, string-keyed, under its discriminator" do
    other = Lain::Epic::StageTransition.new(epic_slug: "alpha", stage: "research", event: "started")

    found = Lain::Journal.records(journaled(transition, other), type: "issue_transition").to_a

    expect(found.size).to eq(1)
    expect(found.first).to include("type" => "issue_transition", "epic_slug" => "alpha", "issue_id" => "a",
                                   "from_status" => "pending", "to_status" => "done")
  end

  it "refuses a status outside the stored set, on either side" do
    expect { transition(to_status: "ready") }.to raise_error(ArgumentError, /to_status/)
    expect { transition(from_status: "nonsense") }.to raise_error(ArgumentError, /from_status/)
  end

  it "refuses an unnamed epic or an unnamed issue" do
    expect { transition(epic_slug: nil) }.to raise_error(ArgumentError, /epic_slug/)
    expect { transition(issue_id: "  ") }.to raise_error(ArgumentError, /issue_id/)
  end

  it "is a deeply frozen, shareable value" do
    expect(transition).to be_deeply_frozen
  end
end
