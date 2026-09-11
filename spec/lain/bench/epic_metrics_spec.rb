# frozen_string_literal: true

require "stringio"
require "json"

# EpicMetrics is a pure fold over one epic run's own journal: rework (an
# issue moving out of `done`, plus a plan step a supersession names as
# reopened) and round-trips (gate decisions per epic/stage/issue). No
# collaborator -- every number is a count of records already on disk, read by
# their journal `type` tag alone.
RSpec.describe Lain::Bench::EpicMetrics do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }

  def entries = journal_io.string.lines

  def transition(issue_id:, from:, to:, epic_slug: "lain-epics")
    journal.record(Lain::Epic::IssueTransition.new(epic_slug:, issue_id:, from_status: from, to_status: to))
  end

  def gate_decision(approved:, epic_slug: "lain-epics", stage: "issue_plan", digest: "blake3:artifact")
    journal.record(
      Lain::Approval::GateDecision.new(artifact_digest: digest, epic_slug:, stage:, approved:,
                                       answered_by: "human", policy: "interactive", latency: 0.1)
    )
  end

  # A `gate_decision` line carrying `issue_id`, the field a LATER card's
  # issue-scoped gates will journal -- GateDecision's own wire shape does not
  # carry it yet, so this writes the raw line directly rather than through
  # {Lain::Approval::GateDecision}, the same forward-compatible shape
  # {Lain::Journal.records} already reads any foreign-but-typed line as.
  def gate_decision_for_issue(issue_id:, approved:, epic_slug: "lain-epics", stage: "issue_plan",
                              digest: "blake3:artifact")
    record = Lain::Approval::GateDecision.new(artifact_digest: digest, epic_slug:, stage:, approved:,
                                              answered_by: "human", policy: "interactive", latency: 0.1)
    journal_io.puts(record.to_journal.merge("issue_id" => issue_id).to_json)
  end

  def supersession(step_id:, plan_digest: "blake3:plan")
    journal.record(
      Lain::Telemetry::SupersessionRecord.new(supersession_digest: "blake3:super", step_id:,
                                              superseded_digest: "blake3:old", superseding_digest: "blake3:new",
                                              plan_digest:)
    )
  end

  # Scenario: rework and round-trips fold from records.
  describe "rework and round-trips fold from records" do
    it "counts a done->pending transition as one rework, and every gate decision at a stage as a round-trip" do
      transition(issue_id: "a", from: "done", to: "pending")
      gate_decision(stage: "issue_plan", approved: false)
      gate_decision(stage: "issue_plan", approved: false)
      gate_decision(stage: "issue_plan", approved: true)

      metrics = described_class.from_journal(entries)

      expect(metrics.rework(epic_slug: "lain-epics", issue_id: "a")).to eq(1)
      expect(metrics.round_trips(epic_slug: "lain-epics", stage: "issue_plan")).to eq(3)
    end
  end

  describe "#rework" do
    it "answers 0 for an issue with no journaled rework at all" do
      metrics = described_class.from_journal([])

      expect(metrics.rework(epic_slug: "lain-epics", issue_id: "never-reworked")).to eq(0)
    end

    it "does not count a transition that never passed through done" do
      transition(issue_id: "a", from: "pending", to: "in_flight")

      expect(described_class.from_journal(entries).rework(epic_slug: "lain-epics", issue_id: "a")).to eq(0)
    end

    it "does not count a transition INTO done, only a transition OUT of it" do
      transition(issue_id: "a", from: "in_flight", to: "done")

      expect(described_class.from_journal(entries).rework(epic_slug: "lain-epics", issue_id: "a")).to eq(0)
    end

    it "sums repeated rework for the same issue" do
      transition(issue_id: "a", from: "done", to: "pending")
      transition(issue_id: "a", from: "in_flight", to: "done")
      transition(issue_id: "a", from: "done", to: "abandoned")

      expect(described_class.from_journal(entries).rework(epic_slug: "lain-epics", issue_id: "a")).to eq(2)
    end

    it "keeps two issues' rework independent" do
      transition(issue_id: "a", from: "done", to: "pending")
      transition(issue_id: "b", from: "done", to: "pending")
      transition(issue_id: "b", from: "in_flight", to: "done")
      transition(issue_id: "b", from: "done", to: "abandoned")

      metrics = described_class.from_journal(entries)

      expect(metrics.rework(epic_slug: "lain-epics", issue_id: "a")).to eq(1)
      expect(metrics.rework(epic_slug: "lain-epics", issue_id: "b")).to eq(2)
    end

    # A bare issue_id key would sum two DIFFERENT epics' issue "a" into one
    # number belonging to neither -- issue ids are epic-scoped free text
    # (lib/lain/epic/issue.rb's ID_RULES demand no global uniqueness), and
    # short mnemonic ids like "a" are the norm. #rework takes epic_slug the
    # same way #round_trips always has, for exactly this reason.
    it "keeps the same issue_id in two different epics independent, rather than summing them" do
      transition(issue_id: "a", from: "done", to: "pending", epic_slug: "alpha")
      transition(issue_id: "a", from: "done", to: "pending", epic_slug: "beta")
      transition(issue_id: "a", from: "in_flight", to: "done", epic_slug: "beta")
      transition(issue_id: "a", from: "done", to: "abandoned", epic_slug: "beta")

      metrics = described_class.from_journal(entries)

      expect(metrics.rework(epic_slug: "alpha", issue_id: "a")).to eq(1)
      expect(metrics.rework(epic_slug: "beta", issue_id: "a")).to eq(2)
    end

    # Part 3's other rework source: a plan step a supersession names as
    # reopened. Telemetry::SupersessionRecord carries no epic_slug at all (it
    # names a plan step, not an epic -- see the class comment), so it folds
    # under a NIL epic scope rather than guessing one; a real epic's own
    # issue_id, which always folds under its real epic_slug, can never
    # collide with this unscoped bucket.
    it "counts a plan step's supersession as rework under its own step_id, scoped to no epic" do
      supersession(step_id: "step-a")

      expect(described_class.from_journal(entries).rework(epic_slug: nil, issue_id: "step-a")).to eq(1)
    end

    it "does not let a supersession's unscoped step_id collide with a same-named issue_id in a real epic" do
      transition(issue_id: "a", from: "done", to: "pending", epic_slug: "alpha")
      supersession(step_id: "a")

      metrics = described_class.from_journal(entries)

      expect(metrics.rework(epic_slug: "alpha", issue_id: "a")).to eq(1)
      expect(metrics.rework(epic_slug: nil, issue_id: "a")).to eq(1)
    end
  end

  describe "#round_trips" do
    it "answers 0 for an (epic, stage) that never gated anything" do
      metrics = described_class.from_journal([])

      expect(metrics.round_trips(epic_slug: "lain-epics", stage: "research")).to eq(0)
    end

    it "keeps two stages of the same epic independent" do
      gate_decision(stage: "research", approved: true)
      gate_decision(stage: "epic_plan", approved: true)
      gate_decision(stage: "epic_plan", approved: false)

      metrics = described_class.from_journal(entries)

      expect(metrics.round_trips(epic_slug: "lain-epics", stage: "research")).to eq(1)
      expect(metrics.round_trips(epic_slug: "lain-epics", stage: "epic_plan")).to eq(2)
    end

    it "keeps two epics at the same stage independent" do
      gate_decision(epic_slug: "alpha", stage: "research", approved: true)
      gate_decision(epic_slug: "beta", stage: "research", approved: true)
      gate_decision(epic_slug: "beta", stage: "research", approved: false)

      metrics = described_class.from_journal(entries)

      expect(metrics.round_trips(epic_slug: "alpha", stage: "research")).to eq(1)
      expect(metrics.round_trips(epic_slug: "beta", stage: "research")).to eq(2)
    end

    # Gate decisions fold per (epic, stage, issue). A later card makes
    # issue_plan/implementation gates issue-scoped and journals `issue_id` on
    # the decision; today's records never carry it, which folds under nil (an
    # epic-wide stage's own honest answer: "no issue").
    it "keeps two issues' issue_plan decisions in the same epic independent when they carry issue_id" do
      gate_decision_for_issue(issue_id: "a", approved: true)
      gate_decision_for_issue(issue_id: "a", approved: false)
      gate_decision_for_issue(issue_id: "b", approved: true)

      metrics = described_class.from_journal(entries)

      expect(metrics.round_trips(epic_slug: "lain-epics", stage: "issue_plan", issue_id: "a")).to eq(2)
      expect(metrics.round_trips(epic_slug: "lain-epics", stage: "issue_plan", issue_id: "b")).to eq(1)
    end

    it "folds a record with no issue_id under nil, and answers it whether or not issue_id: is passed" do
      gate_decision(stage: "research", approved: true)

      metrics = described_class.from_journal(entries)

      expect(metrics.round_trips(epic_slug: "lain-epics", stage: "research")).to eq(1)
      expect(metrics.round_trips(epic_slug: "lain-epics", stage: "research", issue_id: nil)).to eq(1)
    end

    it "does not let an issue-scoped decision leak into the epic-wide (issue_id: nil) bucket" do
      gate_decision_for_issue(issue_id: "a", approved: true)
      gate_decision(stage: "issue_plan", approved: true) # no issue_id -- a different bucket entirely

      metrics = described_class.from_journal(entries)

      expect(metrics.round_trips(epic_slug: "lain-epics", stage: "issue_plan", issue_id: "a")).to eq(1)
      expect(metrics.round_trips(epic_slug: "lain-epics", stage: "issue_plan", issue_id: nil)).to eq(1)
    end
  end

  describe "ignoring what does not belong to either fold" do
    it "skips a foreign record type rather than raising" do
      journal.record(Lain::Telemetry::SessionClosed.new(head: "blake3:head", reason: :exit))

      expect { described_class.from_journal(entries) }.not_to raise_error
    end

    it "skips a line that is not JSON at all, the way every Journal reader does" do
      entries_with_garbage = entries.to_a + ["not json\n"]

      expect { described_class.from_journal(entries_with_garbage) }.not_to raise_error
    end
  end
end
