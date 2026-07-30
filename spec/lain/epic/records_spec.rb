# frozen_string_literal: true

require "stringio"

# The epic tier's two journal records. They are Journalable Data values like
# every other Lain::Telemetry event, and their `type` strings -- derived from the
# class name, never hand-written -- are DURABLE journal discriminators: a rename
# re-labels records nobody can join anymore, so both are pinned here.
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

  # AC4
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
    expect(Ractor.shareable?(transition)).to be(true)
  end
end

RSpec.describe Lain::Epic::StageTransition do
  def stage_event(**overrides)
    described_class.new(epic_slug: "alpha", stage: "epic_plan", event: "started", **overrides)
  end

  it "journals under the underscored basename of its class" do
    expect(stage_event.journal_type).to eq("stage_transition")
    expect(described_class::JOURNAL_TYPE).to eq("stage_transition")
  end

  it "carries its epic, stage, and event into the record" do
    expect(stage_event.to_journal).to eq("type" => "stage_transition", "epic_slug" => "alpha",
                                         "stage" => "epic_plan", "event" => "started")
  end

  # A stage is a partition key, so a typo that constructed would fold onto a
  # partition nothing else writes to -- Stage's own closed set is what refuses it.
  it "refuses a stage outside the pipeline" do
    expect { stage_event(stage: "planning") }.to raise_error(Lain::Epic::UnknownStage, /planning/)
  end

  it "refuses an event outside started/completed" do
    expect { stage_event(event: "finished") }.to raise_error(ArgumentError, /event/)
  end

  it "accepts a Stage value as readily as its name" do
    expect(stage_event(stage: Lain::Epic::Stage.new("research")).stage).to eq("research")
  end

  it "is a deeply frozen, shareable value" do
    expect(Ractor.shareable?(stage_event)).to be(true)
  end
end

# One structural revision of the issue graph, journaled: the fiber a graph
# operation yielded, plus the epic it belongs to. The record is the REPLAY
# PAYLOAD and not a note about one -- a reader holding it can perform the edit
# again -- so what it carries is judged against what a replay needs.
RSpec.describe Lain::Epic::GraphRevision do
  def issue(id, **overrides) = Lain::Epic::Issue.new(id:, title: "Issue #{id}", **overrides)

  def graph(*issues) = Lain::Epic::Graph.new(issues:)

  # The Gherkin scenario's split: "a" divided into "a1" and "a2".
  let(:before) { graph(issue("x", blocks: %w[a]), issue("a")) }
  let(:parts) { [issue("a1"), issue("a2")] }
  let(:fiber) do
    caught = nil
    before.split("a", into: parts) { |yielded| caught = yielded }
    caught
  end

  def revision(**overrides) = described_class.new(epic_slug: "alpha", **fiber.to_h, **overrides)

  it "journals under the underscored basename of its class", :aggregate_failures do
    expect(revision.journal_type).to eq("graph_revision")
    expect(described_class::JOURNAL_TYPE).to eq("graph_revision")
  end

  # AC1: a split's fiber is journaled with its payload.
  it "holds the preimage, the results, the arriving issues' canonical forms and both digests" do
    after = before.split("a", into: parts)

    expect(revision.to_journal)
      .to eq("type" => "graph_revision", "epic_slug" => "alpha", "operation" => "split",
             "arguments" => { "id" => "a", "into" => parts.map(&:canonical) },
             "preimage" => %w[a], "results" => %w[a1 a2],
             "before" => before.digest, "after" => after.digest)
  end

  it "round-trips through the journal, string-keyed, under its discriminator" do
    io = StringIO.new
    Lain::Journal.new(io:).record(revision)

    found = Lain::Journal.records(io.string.lines, type: "graph_revision").to_a

    expect(found.first).to include("epic_slug" => "alpha", "operation" => "split", "preimage" => %w[a],
                                   "results" => %w[a1 a2], "before" => before.digest)
  end

  # The record is one fiber plus the epic a Graph cannot name (it carries no
  # slug). Pinned, so a member added to one side and forgotten on the other is
  # loud rather than a field the journal quietly stops carrying.
  it "is exactly a fiber plus the epic it belongs to" do
    expect(described_class.members).to eq([:epic_slug, *Lain::Epic::GraphFiber.members])
  end

  it "refuses an unnamed epic" do
    expect { revision(epic_slug: nil) }.to raise_error(ArgumentError, /epic_slug/)
  end

  # ArgumentError rather than the {Epic::GraphFiber} refusal underneath it: the
  # record's own guard is checked FIRST, so an out-of-range operation reads like
  # every other out-of-range field on an epic record.
  it "refuses an operation nothing can replay" do
    expect { revision(operation: "rename") }.to raise_error(ArgumentError, /operation/)
  end

  it "is a deeply frozen, shareable value" do
    expect(Ractor.shareable?(revision)).to be(true)
  end
end
