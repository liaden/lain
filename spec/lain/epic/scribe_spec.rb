# frozen_string_literal: true

require "stringio"

# The epic tier's one write path. {Epic::Scribe} is the only thing in lib
# permitted to construct an {Epic::IssueTransition} or {Epic::StageTransition}
# -- everywhere else, a caller that wants a transition journaled goes through
# here, so the write-side guards in {Epic::Guards} are checked in exactly one
# place. {Epic::Progress.fold} is the read-side oracle: these specs prove what
# the scribe wrote is what the fold sees, never re-asserting the fold's own
# behaviour (that belongs to progress_spec.rb).
RSpec.describe Lain::Epic::Scribe do
  def issue(id, **overrides) = Lain::Epic::Issue.new(id:, title: id.upcase, **overrides)

  def graph_of(*issues) = Lain::Epic::Graph.new(issues:)

  let(:io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io:) }
  let(:scribe) { described_class.new(epic_slug: "demo", journal:) }

  # a blocks b, so b is ready only once a is done.
  let(:chain) { graph_of(issue("a", blocks: ["b"]), issue("b")) }

  def fold = Lain::Epic::Progress.fold(io.string.lines, graph: chain, epic_slug: "demo")

  # AC1: "the fold sees what the scribe writes"
  it "writes an issue_moved and a stage_started record the fold reads back", :aggregate_failures do
    scribe.issue_moved("a", from: "pending", to: "done")
    scribe.stage_started("issue_plan")

    progress = fold

    expect(progress.stage.name).to eq("issue_plan")
    expect(progress.ready.map(&:id)).to eq(["b"])
  end

  # A stage_completed record is journaled as its own event; whether the fold
  # advances on it is Progress's own rule (it does not -- T19's concern, not
  # this card's), so this only proves the scribe's write lands.
  it "writes a stage_completed record" do
    scribe.stage_started("research")
    scribe.stage_completed("research")

    records = Lain::Journal.records(io.string.lines, type: "stage_transition").to_a
    expect(records.map { |r| r["event"] }).to eq(%w[started completed])
  end

  # AC2: "a bad status never reaches the journal"
  it "raises before an out-of-range status reaches the journal", :aggregate_failures do
    expect { scribe.issue_moved("a", from: "pending", to: "finished") }
      .to raise_error(ArgumentError, /to_status/)
    expect(io.string).to eq("")
  end

  it "raises before an unknown stage reaches the journal", :aggregate_failures do
    expect { scribe.stage_started("planning") }.to raise_error(Lain::Epic::UnknownStage, /planning/)
    expect(io.string).to eq("")
  end

  it "returns self, so calls can chain", :aggregate_failures do
    expect(scribe.issue_moved("a", from: "pending", to: "done")).to be(scribe)
    expect(scribe.stage_started("research")).to be(scribe)
    expect(scribe.stage_completed("research")).to be(scribe)
  end

  # T4 review, fix 1 -- probe_t4b.rb's central finding: `Guards::IssueTransition`
  # only demands a non-blank epic_slug, but `Refold#mine?` partitions on
  # BYTE-EXACT equality against the slug a caller names to `Progress.fold`.
  # A Scribe built on a slug that differs only in whitespace or case therefore
  # writes successfully and then silently partitions as another epic's record
  # -- dropped, not refused, and irrecoverably so in an append-only journal.
  # `Home.checked_name` is the one gate every REAL epic slug already passes
  # (it always came from `Home.resolve`), so checking it here catches exactly
  # the caller that skipped that door.
  describe "the epic slug" do
    # AC (probe_t4b): before the fix, this silently dropped the "a" transition
    # -- `Progress.fold(..., epic_slug: "demo").status("a")` read back
    # "pending", the document's stale status, with no exception. The fix
    # makes the leading space unconstructible instead.
    it "refuses a slug that differs from a real epic's only by leading whitespace" do
      expect { described_class.new(epic_slug: " demo", journal: Lain::Journal.new(io: StringIO.new)) }
        .to raise_error(Lain::Epic::Home::MalformedName, /epic slug/)
    end

    # Same defect, the case-variant probe_t4b also pinned.
    it "refuses a slug that differs from a real epic's only by case" do
      expect { described_class.new(epic_slug: "Demo", journal: Lain::Journal.new(io: StringIO.new)) }
        .to raise_error(Lain::Epic::Home::MalformedName, /epic slug/)
    end

    it "refuses a blank or absent slug" do
      expect { described_class.new(epic_slug: "", journal: Lain::Journal.new(io: StringIO.new)) }
        .to raise_error(Lain::Epic::Home::MalformedName, /epic slug/)
      expect { described_class.new(epic_slug: nil, journal: Lain::Journal.new(io: StringIO.new)) }
        .to raise_error(Lain::Epic::Home::MalformedName, /epic slug/)
    end

    it "accepts a slug that already satisfies Home's grammar" do
      expect { described_class.new(epic_slug: "the-plan-2", journal: Lain::Journal.new(io: StringIO.new)) }
        .not_to raise_error
    end
  end

  # The third record the scribe writes, and the one whose payload a later reader
  # REPLAYS rather than merely reads. A {Graph} carries no slug, so the fiber it
  # yields carries none either: naming the epic is exactly what this write path
  # adds, and it is why a graph cannot journal itself.
  describe "#graph_revised" do
    def fiber
      caught = nil
      chain.split("b", into: [issue("b1"), issue("b2")]) { |yielded| caught = yielded }
      caught
    end

    it "writes a graph_revision record carrying this epic's slug and the whole fiber" do
      scribe.graph_revised(fiber)

      record = Lain::Journal.records(io.string.lines, type: "graph_revision").to_a.first

      expect(record).to include("epic_slug" => "demo", "operation" => "split", "preimage" => %w[b],
                                "results" => %w[b1 b2], "before" => chain.digest,
                                "arguments" => include("id" => "b"))
    end

    it "returns self, so a revision can be journaled in the middle of a chain of writes" do
      expect(scribe.graph_revised(fiber)).to be(scribe)
    end

    it "raises before an unreplayable revision reaches the journal", :aggregate_failures do
      expect { scribe.graph_revised(nil) }.to raise_error(ArgumentError)
      expect(io.string).to eq("")
    end
  end

  # T4 review, fix 2 -- `Progress`'s own rule (`named_epic`/`refuse_stranger!`)
  # applied to the Scribe's other collaborator: a construction-time argument
  # that cannot do its job is refused AT construction, not on first use deep
  # inside a private method with the real mistake off the backtrace.
  describe "the journal collaborator" do
    it "refuses a journal that cannot accept a record" do
      expect { described_class.new(epic_slug: "demo", journal: nil) }
        .to raise_error(ArgumentError, /journal/)
    end
  end

  it "is frozen once constructed" do
    expect(scribe.frozen?).to be(true)
  end
end
