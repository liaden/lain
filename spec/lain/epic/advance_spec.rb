# frozen_string_literal: true

require "stringio"

# What an approval advances, shared by every surface that can approve: a
# verdict from `lain epic submit`, a re-submit over a standing approval, and a
# sign-off from `lain epic approve`. One rule, so the three cannot disagree
# about whether an approval moved the epic.
RSpec.describe Lain::Epic::Advance do
  def issue(id, **overrides) = Lain::Epic::Issue.new(id:, title: id.upcase, **overrides)

  let(:io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io:) }
  let(:chain) { Lain::Epic::Graph.new(issues: [issue("a", blocks: ["b"]), issue("b")]) }

  def lines = io.string.lines
  def fold = Lain::Epic::Progress.fold(lines, graph: chain, epic_slug: "demo")
  def records = Lain::Journal.records(lines).to_a

  def stage_events
    transitions = Lain::Journal.records(lines, type: "stage_transition").to_a
    transitions.map { |record| record.values_at("stage", "event") }
  end

  # The two folds the approving surfaces read through {Lain::CLI::Epic}. The
  # stage is folded from the records alone, with no document, because research
  # is approved before epic.md is written.
  def epics
    instance_double(Lain::CLI::Epic).tap do |epics|
      allow(epics).to receive(:stage) { |slug| Lain::Epic::Progress.stage(lines, epic_slug: slug) }
      allow(epics).to receive(:progress) { |_slug| fold }
    end
  end

  def advance(stage, issue_id: nil) = described_class.new(epic_slug: "demo", stage:, issue_id:)

  def approve(stage, issue_id: nil, reading: epics) = advance(stage, issue_id:).read(reading).call(journal)

  describe "#moves?" do
    it "is true for an epic-wide stage" do
      expect([advance("research"), advance("epic_plan")].map(&:moves?)).to eq([true, true])
    end

    it "is true for an issue plan that names its issue" do
      expect(advance("issue_plan", issue_id: "a").moves?).to be(true)
    end

    it "is false for an implementation, which moves nothing until it lands" do
      expect(advance("implementation", issue_id: "a").moves?).to be(false)
    end

    it "is false for a plan approval that names no issue" do
      expect(advance("issue_plan").moves?).to be(false)
    end
  end

  describe "an epic-wide stage" do
    it "completes the approved stage and starts its successor, and says so" do
      expect(approve("research")).to eq("research completed, epic_plan started")

      expect(stage_events).to eq([%w[research completed], %w[epic_plan started]])
      expect(fold.stage.name).to eq("epic_plan")
    end

    it "reads where the epic stands without its document" do
      reading = instance_double(Lain::CLI::Epic)
      allow(reading).to receive(:stage) { |slug| Lain::Epic::Progress.stage(lines, epic_slug: slug) }

      expect(approve("research", reading:)).to eq("research completed, epic_plan started")
    end

    # A research approval that never wrote its transition leaves the epic
    # reading research; approving the plan still moves it on.
    it "advances from a stage the epic never recorded leaving" do
      expect(approve("epic_plan")).to eq("epic_plan completed, issue_plan started")

      expect(fold.stage.name).to eq("issue_plan")
    end

    it "moves nothing once the epic is past the approved stage, and says where it stands" do
      Lain::Epic::Scribe.new(epic_slug: "demo", journal:).stage_started("epic_plan")

      expect(approve("research")).to eq("epic is at epic_plan -- research is already behind it, nothing moved")
      expect(stage_events).to eq([%w[epic_plan started]])
    end

    it "never writes a transition twice for one approval, run after run" do
      2.times { approve("research") }

      expect(stage_events).to eq([%w[research completed], %w[epic_plan started]])
    end

    it "accepts the stage as a value as readily as by name" do
      expect(advance(Lain::Epic::Stage.new("research")).read(epics).call(journal))
        .to eq("research completed, epic_plan started")
    end

    # At least once: two processes that each read the epic at research both
    # write the advance, and the fold reads the later start either way.
    it "folds two processes' advances of the same stage into one stage" do
      stale = advance("research").read(epics)
      approve("research")
      stale.call(journal)

      expect(stage_events.size).to eq(4)
      expect(fold.stage.name).to eq("epic_plan")
    end
  end

  describe "an issue-scoped stage" do
    it "puts an approved plan's issue in flight, moving no epic-wide stage" do
      expect(approve("issue_plan", issue_id: "a")).to eq("issue a moved pending -> in_flight")

      expect(fold.status("a")).to eq("in_flight")
      expect(stage_events).to be_empty
    end

    it "moves nothing for an implementation, without reading the epic" do
      said = approve("implementation", issue_id: "a", reading: instance_double(Lain::CLI::Epic))

      expect(said).to eq("issue a's implementation is approved -- nothing moves until it lands")
      expect(records).to be_empty
    end

    it "moves nothing for a plan approval that names no issue, and says why" do
      said = approve("issue_plan", reading: instance_double(Lain::CLI::Epic))

      expect(said).to eq("this issue_plan approval names no issue -- nothing moved")
      expect(records).to be_empty
    end
  end
end
