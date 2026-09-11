# frozen_string_literal: true

require "stringio"

# Putting an approved plan's issue in flight, shared by every surface that can
# approve a plan: a verdict from `lain epic submit` and a sign-off from `lain
# epic approve`. Both ask this class whether an approval starts an issue, so
# the trigger rule and the move live in one place.
RSpec.describe Lain::Epic::InFlight do
  def issue(id, **overrides) = Lain::Epic::Issue.new(id:, title: id.upcase, **overrides)

  let(:io) { StringIO.new }
  let(:scribe) { Lain::Epic::Scribe.new(epic_slug: "demo", journal: Lain::Journal.new(io:)) }
  let(:chain) { Lain::Epic::Graph.new(issues: [issue("a", blocks: ["b"]), issue("b")]) }

  def fold = Lain::Epic::Progress.fold(io.string.lines, graph: chain, epic_slug: "demo")
  def in_flight(id, progress: -> { fold }) = described_class.new(scribe:, progress:, issue_id: id)

  describe ".starts?" do
    it "is true for an approved issue plan that names its issue" do
      expect(described_class.starts?(approved: true, stage: "issue_plan", issue_id: "a")).to be(true)
    end

    it "is false for a denied plan" do
      expect(described_class.starts?(approved: false, stage: "issue_plan", issue_id: "a")).to be(false)
    end

    it "is false for any other stage, an implementation included" do
      expect(described_class.starts?(approved: true, stage: "implementation", issue_id: "a")).to be(false)
      expect(described_class.starts?(approved: true, stage: "research", issue_id: nil)).to be(false)
    end

    # A plan approval recorded before gates named their issue has nothing to
    # move -- guessing which issue it meant would be worse than moving none.
    it "is false for a plan approval that names no issue" do
      expect(described_class.starts?(approved: true, stage: "issue_plan", issue_id: nil)).to be(false)
    end
  end

  it "moves a pending issue in flight, and says so" do
    expect(in_flight("a").call).to eq("issue a moved pending -> in_flight")
    expect(fold.status("a")).to eq("in_flight")
  end

  it "moves nothing for an issue that is not pending" do
    scribe.issue_moved("a", from: "pending", to: "in_flight")

    expect(in_flight("a").call).to eq("issue a is in_flight -- nothing moved")
    expect(io.string.lines.size).to eq(1)
  end

  # At least once: two processes that each read pending both write the move,
  # and the fold merges them into one status.
  it "folds two processes' moves of the same issue into one status" do
    stale = Lain::Epic::Progress.fold([], graph: chain, epic_slug: "demo")
    in_flight("a").call
    in_flight("a", progress: -> { stale }).call

    expect(io.string.lines.size).to eq(2)
    expect(fold.status("a")).to eq("in_flight")
  end
end
