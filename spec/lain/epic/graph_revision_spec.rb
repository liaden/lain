# frozen_string_literal: true

require "stringio"

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

  # A split's fiber is journaled with its payload.
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
    expect(revision).to be_deeply_frozen
  end
end
