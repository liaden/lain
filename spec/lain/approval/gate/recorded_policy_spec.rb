# frozen_string_literal: true

require "stringio"

# RecordedPolicy replays gate_decisions journaled in an EARLIER run, keyed by
# artifact digest, so a progressive epic arm re-run against the same
# artifacts answers exactly as recorded -- no human present, no live model
# asked to guess. It is kept out of Policies::CATALOG on purpose: nothing in
# [epics.gates] could ever name a digest to replay before a run has happened.
#
# NOT a Gate::Policy subclass: spec/lain/skill/shipped_skills_spec.rb pins
# Policy.subclasses to the exact family a session can configure through
# [epics.gates], which the epic skills document, and this policy is not a
# member of that family. It composes Policy::Boundary and Policy::StandingAnswer
# rather than inheriting, and answers the same #decide(artifact, gate:, stage:,
# epic_slug:) duck every caller of a policy sends.
RSpec.describe Lain::Approval::Gate::RecordedPolicy do
  def artifact(digest:, question: "Approve? Reply approve or deny.")
    Data.define(:digest, :gate_question).new(digest:, gate_question: question)
  end

  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:gate) { Lain::Approval::Gate.new(journal:, timeout: 0.5) }
  let(:queue) { Lain::Approval::SignoffQueue.new }
  let(:drained) { Lain::Approval::Gate::Policy::Drained }

  def decide(policy, digest:, stage: "issue_plan", epic_slug: "lain-epics")
    Sync { policy.decide(artifact(digest:), gate:, stage:, epic_slug:) }
  end

  def decisions
    Lain::Journal.records(journal_io.string.lines, type: "gate_decision").to_a
  end

  # A journal carrying one earlier run's recorded decisions -- built through a
  # real Gate + Interactive policy so the fixture is a shape the class under
  # test actually reads back, not a hand-typed record that could drift from
  # {Approval::GateDecision}'s real wire shape.
  def recorded_journal(&block)
    recording_io = StringIO.new
    recording_journal = Lain::Journal.new(io: recording_io)
    recording_gate = Lain::Approval::Gate.new(journal: recording_journal, timeout: 0.5)
    yield(recording_gate)
    recording_io.string.lines
  end

  def approve(recording_gate, digest:, stage: "issue_plan", epic_slug: "lain-epics")
    asker = Object.new
    asker.define_singleton_method(:ask) do |_question|
      Lain::Promise.new.tap { |promise| promise.resolve(Lain::Approval::Gate::Answer.approve("human")) }
    end
    Sync { recording_gate.call(artifact(digest:), asker:, stage:, epic_slug:) }
  end

  def deny(recording_gate, digest:, stage: "issue_plan", epic_slug: "lain-epics")
    asker = Object.new
    asker.define_singleton_method(:ask) do |_question|
      Lain::Promise.new.tap { |promise| promise.resolve(Lain::Approval::Gate::Answer.deny("human")) }
    end
    Sync { recording_gate.call(artifact(digest:), asker:, stage:, epic_slug:) }
  end

  # Scenario: recorded answers replay, and an unrecorded digest is refused.
  describe "recorded answers replay, and an unrecorded digest is refused" do
    it "approves a recorded digest under policy recorded, and refuses an unrecorded one by name" do
      entries = recorded_journal { |recording_gate| approve(recording_gate, digest: "blake3:D") }
      policy = described_class.from_journal(entries, queue: drained)

      expect(decide(policy, digest: "blake3:D")).to be(true)
      expect(decisions.first).to include("approved" => true, "answered_by" => "human", "policy" => "recorded")

      expect { decide(policy, digest: "blake3:E") }
        .to raise_error(described_class::Unrecorded, /blake3:E/)
    end

    it "replays a recorded denial as a denial, still under policy recorded" do
      entries = recorded_journal { |recording_gate| deny(recording_gate, digest: "blake3:D") }
      policy = described_class.from_journal(entries, queue: drained)

      expect(decide(policy, digest: "blake3:D")).to be(false)
      expect(decisions.first).to include("approved" => false, "answered_by" => "human", "policy" => "recorded")
    end

    it "journals no gate decision at all when the digest was never recorded" do
      policy = described_class.from_journal([], queue: drained)

      expect { decide(policy, digest: "blake3:E") }.to raise_error(described_class::Unrecorded)
      expect(decisions).to be_empty
    end

    it "replays the LATEST verdict when the same address was decided more than once" do
      entries = recorded_journal do |recording_gate|
        deny(recording_gate, digest: "blake3:D")
        approve(recording_gate, digest: "blake3:D")
      end
      policy = described_class.from_journal(entries, queue: drained)

      expect(decide(policy, digest: "blake3:D")).to be(true)
    end

    it "checks the stage boundary before answering, like every other policy" do
      queue.park(artifact_digest: "blake3:research", epic_slug: "lain-epics", stage: "research",
                 question: "Approve the research?")
      entries = recorded_journal { |recording_gate| approve(recording_gate, digest: "blake3:D") }
      policy = described_class.new(decisions: {}, queue:)

      expect { decide(policy, digest: "blake3:D", stage: "epic_plan") }
        .to raise_error(Lain::Epic::StageBlocked)
      expect(entries).not_to be_empty # sanity: the fixture-building block above ran
    end
  end

  # Scenario: config cannot name the recorded policy.
  describe "config cannot name the recorded policy" do
    it "is absent from the catalog config validates configurable policy names against" do
      expect(Lain::Approval::Gate::Policies.known?(described_class::NAME)).to be(false)
      expect(Lain::Approval::Gate::Policies.names).not_to include(described_class::NAME)
    end

    it "makes an [epics.gates] entry naming it refuse as an unknown policy" do
      expect do
        Lain::Config::Epics::Gates.from({ "issue_plan" => described_class::NAME })
      end.to raise_error(Lain::Config::Epics::Gates::UnknownPolicies, /recorded/)
    end
  end

  # Not a Gate::Policy subclass: the family that class exposes is exactly the
  # set a session can configure through [epics.gates], and
  # spec/lain/skill/shipped_skills_spec.rb pins it as such for the epic
  # skills to document. This class composes Policy::Boundary and
  # Policy::StandingAnswer rather than inheriting, so it answers the same
  # duck every caller of a policy sends without joining that family.
  describe "the configurable policy family" do
    it "does not join Gate::Policy.subclasses" do
      expect(Lain::Approval::Gate::Policy.subclasses).not_to include(described_class)
    end

    it "is not a kind of Gate::Policy at all" do
      policy = described_class.new(decisions: {}, queue: drained)

      expect(policy).not_to be_a(Lain::Approval::Gate::Policy)
    end

    # The exact seam a caller hands ANY policy to -- CLI::EpicSubmit's
    # `@policy.decide(@submission, gate:, stage:, epic_slug:)` and the
    # altitude arms' progressive replay alike -- generic over whatever object
    # Policies.for/for_all or a direct wiring handed them, never a Policy
    # type-check.
    it "still quacks wherever the altitude arms will hand it to the gate: #name and #decide(...)" do
      entries = recorded_journal { |recording_gate| approve(recording_gate, digest: "blake3:D") }
      policy = described_class.from_journal(entries, queue: drained)

      expect(policy.name).to eq("recorded")
      expect(decide(policy, digest: "blake3:D")).to be(true)
      expect(decisions.first).to include("policy" => "recorded")
    end
  end
end
