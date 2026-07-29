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
