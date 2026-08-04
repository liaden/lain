# frozen_string_literal: true

require "stringio"

# Epic::Progress is an OFFLINE REFOLD: the parsed document supplies the issue
# set and its edges, and the Journal supplies what actually happened to them.
# Where the two disagree the Journal wins -- a document is what an author wrote,
# a journal is what ran.
#
# The two rules with teeth here are the superseded-id rule (a transition naming
# an id a structural edit removed is inert HISTORY, not drift) and the fold's
# refusal to skip anything it cannot read (a skipped deferral reads as drained
# exactly as a misread terminal does, and both open a stage over unsigned work).
#
# The epic being folded is NAMED, never derived. A graph carries no slug, so a
# derived one could not be checked against it -- and a journal holding only
# another epic's records would derive that epic and fold its work onto these
# issues.
RSpec.describe Lain::Epic::Progress do
  def issue(id, **overrides) = Lain::Epic::Issue.new(id:, title: id.upcase, **overrides)

  def graph_of(*issues) = Lain::Epic::Graph.new(issues:)

  def journaled(*records)
    io = StringIO.new
    journal = Lain::Journal.new(io:)
    records.each { |record| journal.record(record) }
    io.string.lines
  end

  def transition(issue_id:, to_status: "done", from_status: "pending", epic_slug: "alpha")
    Lain::Epic::IssueTransition.new(epic_slug:, issue_id:, from_status:, to_status:)
  end

  def stage_event(stage:, event: "started", epic_slug: "alpha")
    Lain::Epic::StageTransition.new(epic_slug:, stage:, event:)
  end

  def gate(policy: "deferred", approved: false, stage: "research", epic_slug: "alpha", digest: "blake3:plan")
    Lain::Approval::GateDecision.new(artifact_digest: digest, epic_slug:, stage:, approved:,
                                     answered_by: policy, policy:, latency: 0.1)
  end

  def fold(entries, graph:, epic_slug: "alpha") = described_class.fold(entries, graph:, epic_slug:)

  # a blocks b, so b is ready only once a is done.
  let(:chain) { graph_of(issue("a", blocks: ["b"]), issue("b")) }

  describe "the overlay" do
    # AC1
    it "lets a journal transition override the document's status, and ready with it" do
      progress = fold(journaled(transition(issue_id: "a")), graph: chain)

      expect(progress.status("a")).to eq("done")
      expect(progress.ready.map(&:id)).to eq(["b"])
    end

    it "reads the document alone when the journal says nothing" do
      progress = fold([], graph: chain)

      expect(progress.status("a")).to eq("pending")
      expect(progress.ready.map(&:id)).to eq(["a"])
    end

    it "takes the last transition for an issue, not the first" do
      entries = journaled(transition(issue_id: "a", to_status: "in_flight"),
                          transition(issue_id: "a", from_status: "in_flight", to_status: "done"))

      expect(fold(entries, graph: chain).status("a")).to eq("done")
    end

    # An abandoned blocker still blocks -- Graph#ready's rule, reached through
    # the overlay rather than restated here.
    it "derives ready through the graph, so an abandoned blocker still blocks" do
      entries = journaled(transition(issue_id: "a", to_status: "abandoned"))

      expect(fold(entries, graph: chain).ready.map(&:id)).to be_empty
    end
  end

  # The superseded-id rule reaches exactly ONE hop: the set is every
  # `discovered_from` a LIVE issue declares. A transition is inert history while
  # some live issue's link still names its id, and loud once none does.
  describe "unknown ids" do
    # AC2
    it "refuses a transition naming an issue no live link reaches" do
      entries = journaled(transition(issue_id: "ghost"))

      expect { fold(entries, graph: chain) }
        .to raise_error(Lain::Epic::UnknownIssue, /"ghost".*"alpha"/m)
    end

    # AC3
    it "folds a split issue's own history as inert, leaving its parts untouched" do
      graph = graph_of(issue("x"), issue("y")).split("y", into: [issue("y1"), issue("y2")])
      entries = journaled(transition(issue_id: "y", to_status: "done"))

      progress = fold(entries, graph:)

      expect(progress.status("y1")).to eq("pending")
      expect(progress.status("y2")).to eq("pending")
      expect(progress.status("x")).to eq("pending")
    end

    # One sibling is enough: re-splitting y1 drops ITS link to y, but y2 still
    # declares it, so y's history stays legible. That is what "one hop from any
    # live issue" buys, and it is the shape a real epic reaches most often.
    it "keeps history inert while any surviving sibling still names the id" do
      graph = graph_of(issue("y")).split("y", into: [issue("y1"), issue("y2")])
                                  .split("y1", into: [issue("y1a")])
      entries = journaled(transition(issue_id: "y", to_status: "done"))

      progress = fold(entries, graph:)

      expect(progress.status("y2")).to eq("pending")
      expect(progress.status("y1a")).to eq("pending")
    end

    # The rule's real boundary, pinned rather than left to be discovered: ANY
    # structural edit that removes the last live issue whose link names the id.
    # Re-splitting the only part is one way to reach it.
    it "refuses once no live issue's link still names the id" do
      graph = graph_of(issue("y")).split("y", into: [issue("y1")]).split("y1", into: [issue("y1a")])
      entries = journaled(transition(issue_id: "y", to_status: "done"))

      expect { fold(entries, graph:) }.to raise_error(Lain::Epic::UnknownIssue, /"y"/)
    end

    # A merge reaches that boundary in ONE edit. Graph#merge passes no
    # provenance override, so an arrival declaring none orphans both parents at
    # once -- and `discovered_from` is single-valued, so declaring one always
    # orphans the other, as merge's own comment concedes.
    it "refuses a merged-away parent, which one merge is enough to orphan" do
      graph = graph_of(issue("y"), issue("w")).merge("y", "w", as: issue("z", discovered_from: "y"))
      entries = journaled(transition(issue_id: "w", to_status: "done"))

      expect { fold(entries, graph:) }.to raise_error(Lain::Epic::UnknownIssue, /"w"/)
    end

    it "names the remedy rather than the machinery" do
      expect { fold(journaled(transition(issue_id: "ghost")), graph: chain) }
        .to raise_error(Lain::Epic::UnknownIssue, /Re-journal the transition|declare the missing provenance/)
    end
  end

  describe "refusal" do
    # A malformed transition must abort the whole fold: skipping it would leave
    # an issue reading at its document status, which is exactly the stale answer
    # the Journal exists to override.
    it "aborts on an issue_transition it cannot read" do
      entries = journaled({ "type" => "issue_transition", "issue_id" => "a", "epic_slug" => "alpha" })

      expect { fold(entries, graph: chain) }.to raise_error(ArgumentError, /to_status/)
    end

    it "aborts on a stage_transition it cannot read" do
      entries = journaled({ "type" => "stage_transition", "epic_slug" => "alpha", "stage" => "research" })

      expect { fold(entries, graph: chain) }.to raise_error(ArgumentError, /event/)
    end

    # T6's rule, one tier up: a failed queue rebuild NEVER degrades to an empty
    # queue, because an empty queue reads as drained and drained opens the next
    # stage over work nobody signed off. Policy::Drained is not a fallback here.
    it "aborts on a gate_decision the sign-off fold cannot read, never reading it as drained" do
      damaged = { "type" => "gate_decision", "artifact_digest" => "blake3:plan", "epic_slug" => "alpha",
                  "stage" => "research", "approved" => false }
      entries = journaled(transition(issue_id: "a"), damaged)

      expect { fold(entries, graph: chain) }.to raise_error(ArgumentError, /policy/)
    end

    # The epic filter must not become the silent skip the rules above forbid. A
    # record naming ANOTHER epic is genuinely not ours; a record naming NO epic
    # is unattributable, so it is kept and its own guard refuses it. Filtering
    # on plain equality would drop exactly the unreadable line.
    it "keeps an unattributable issue_transition so its own guard refuses it" do
      entries = journaled({ "type" => "issue_transition", "issue_id" => "a",
                            "from_status" => "pending", "to_status" => "done" })

      expect { fold(entries, graph: chain) }.to raise_error(ArgumentError, /epic_slug/)
    end

    it "keeps an unattributable gate_decision so the sign-off fold refuses it" do
      entries = journaled(transition(issue_id: "a"),
                          { "type" => "gate_decision", "artifact_digest" => "blake3:plan",
                            "stage" => "research", "approved" => false, "policy" => "deferred" })

      expect { fold(entries, graph: chain) }.to raise_error(ArgumentError, /epic_slug/)
    end
  end

  describe "the stage" do
    it "is the first stage until something says otherwise" do
      expect(fold([], graph: chain).stage).to eq(Lain::Epic::Stage.new("research"))
    end

    it "is the last stage started" do
      entries = journaled(stage_event(stage: "research"), stage_event(stage: "research", event: "completed"),
                          stage_event(stage: "epic_plan"))

      expect(fold(entries, graph: chain).stage.name).to eq("epic_plan")
    end

    # Completing a stage starts nothing; inventing the successor would claim
    # work began that no record shows.
    it "does not advance on a completion alone" do
      entries = journaled(stage_event(stage: "research"), stage_event(stage: "research", event: "completed"))

      expect(fold(entries, graph: chain).stage.name).to eq("research")
    end
  end

  describe "parked sign-offs" do
    it "re-exposes the sign-off queue's fold for the current stage" do
      entries = journaled(gate, stage_event(stage: "research"))

      expect(fold(entries, graph: chain).parked.map(&:artifact_digest)).to eq(["blake3:plan"])
    end

    it "drops an item a later terminal decision answered" do
      entries = journaled(gate, gate(policy: "signoff", approved: true))

      expect(fold(entries, graph: chain).parked).to be_empty
    end

    it "holds nothing when the journal is empty" do
      expect(fold([], graph: chain).parked).to be_empty
    end
  end

  describe "the epic it folds" do
    # The blocker the panel found: a derived slug cannot be checked against the
    # graph, which carries none, so a journal holding only beta's records would
    # derive "beta" and fold beta's work onto alpha's issues -- answering
    # confidently about work that never happened. The only defence is not
    # deriving, and every caller knows the slug from the document it just read.
    it "requires the caller to name the epic" do
      expect { described_class.fold([], graph: chain) }.to raise_error(ArgumentError, /epic_slug/)
    end

    it "ignores another epic's records when they sit beside this epic's own" do
      entries = journaled(transition(issue_id: "a"), transition(issue_id: "ghost", epic_slug: "beta"))

      expect(fold(entries, graph: chain).status("a")).to eq("done")
    end

    # The residual of the blocker: a typo'd slug, or the wrong journal handed
    # in, would otherwise fold silently to "nothing happened here".
    it "refuses a journal that names other epics and never this one" do
      entries = journaled(transition(issue_id: "a", epic_slug: "beta"),
                          stage_event(stage: "research", epic_slug: "gamma"))

      expect { fold(entries, graph: chain) }
        .to raise_error(Lain::Epic::ForeignJournal, /"alpha".*"beta".*"gamma"/m)
    end

    it "folds a fresh epic whose journal holds nothing at all" do
      expect(fold([], graph: chain).epic_slug).to eq("alpha")
    end

    # A gate parked before any issue moved is a real state, so a gate_decision
    # counts as this epic being present in the journal.
    it "counts a parked gate as this epic's presence" do
      expect(fold(journaled(gate), graph: chain).parked.size).to eq(1)
    end
  end

  describe "#summary" do
    let(:nine) { graph_of(*(1..9).map { |n| issue("i#{n}") }) }

    it "reads as one line an author can scan" do
      entries = journaled(
        stage_event(stage: "research"), stage_event(stage: "epic_plan"),
        *(1..4).map { |n| transition(issue_id: "i#{n}") },
        *(5..6).map { |n| transition(issue_id: "i#{n}", to_status: "in_flight") },
        gate(stage: "epic_plan")
      )

      expect(fold(entries, graph: nine).summary)
        .to eq("stage epic_plan — 4/9 done, 2 in flight, 1 gate parked")
    end

    it "pluralizes the parked gates" do
      entries = journaled(gate(digest: "blake3:one"), gate(digest: "blake3:two"))

      expect(fold(entries, graph: nine).summary)
        .to eq("stage research — 0/9 done, 0 in flight, 2 gates parked")
    end
  end

  describe "the value itself" do
    it "is deeply frozen and shareable, parked items included" do
      progress = fold(journaled(transition(issue_id: "a"), gate), graph: chain)

      expect(progress).to be_deeply_frozen
    end

    # `Data` freezes the instance and `Array#freeze` is shallow, so deep
    # frozenness holds only because every parked member is itself a frozen
    # value. The constructor is public, so it says so rather than hoping.
    it "refuses a parked member that is not a sign-off item" do
      expect { built(parked: [+"loose"]) }.to raise_error(ArgumentError, /Item/)
    end

    # The same rule the fold's entry point keeps, kept by the value itself: a
    # blank slug interns to "" and would name a partition nothing can match.
    # A constructor that refuses a bad `parked` and shrugs at a nil slug is
    # inconsistent in the one direction this unit keeps getting bitten by.
    it "refuses an epic slug that names nothing" do
      expect { built(epic_slug: nil) }.to raise_error(ArgumentError, /epic_slug/)
      expect { built(epic_slug: "  ") }.to raise_error(ArgumentError, /epic_slug/)
    end

    def built(**overrides)
      described_class.new(graph: chain, stage: Lain::Epic::Stage.new("research"),
                          epic_slug: "alpha", parked: [], **overrides)
    end
  end
end
