# frozen_string_literal: true

RSpec.describe Lain::Epic::GateView do
  verdicts = Lain::Approval::Verdict
  partition = Lain::Epic::SignoffQueue::Partition.new(epic_slug: "alpha", stage: "issue_plan", issue_id: "a")
  standing = ->(verdict, digest) { Lain::Epic::Signoff::Standing.new(digest:, verdict:) }

  def decided(verdict, digest:, stage: "issue_plan", issue_id: "a", slug: "alpha")
    policy = Lain::Epic::GateDecision.deferred?(verdict) ? "deferred" : "signoff"
    Lain::Epic::GateDecision.new(artifact_digest: digest, epic_slug: slug, stage:, verdict:, answered_by: policy,
                                 policy:, latency: 0.1, issue_id:)
  end

  describe "#phase" do
    standings = { "no standing" => nil,
                  "an approval at the current bytes" => standing.call(verdicts::Approve.new, "now"),
                  "an approval at other bytes" => standing.call(verdicts::Approve.new, "before"),
                  "a denial" => standing.call(verdicts::Deny.new, "now") }
    rule = [[:parked, ->(view) { view.drafts.any? }], [:held, ->(view) { view.held.any? }],
            [:approved, ->(view) { view.standing&.verdict&.approved? && view.standing.digest == view.current }],
            [:edited, ->(view) { view.standing&.verdict&.approved? && !view.current.nil? }],
            [:gone, ->(view) { view.standing&.verdict&.approved? }],
            [:denied, ->(view) { !view.standing.nil? }]]

    [true, false].product([true, false], standings.keys, ["now", nil]).each do |parked, held, named, current|
      view = described_class.new(partition:, standing: standings.fetch(named), drafts: parked ? ["draft"] : [],
                                 held: held ? ["held"] : [], current:)
      expected = rule.find { |_, holds| holds.call(view) }&.first || :open

      it "reads #{expected} with#{" a parked draft," if parked}#{" a hold," if held} #{named}, " \
         "#{current ? "and the artifact present" : "and the artifact gone"}" do
        expect(view.phase).to eq(expected)
      end
    end

    it "does not wait on a draft the standing approval superseded" do
      view = described_class.new(partition:, standing: standing.call(verdicts::Approve.new, "now"), drafts: ["older"],
                                 superseded: ["older"], held: [], current: "now")

      expect([view.phase, view.drafts]).to eq([:approved, ["older"]])
    end
  end

  describe "#landable_digest" do
    it "answers the standing digest only while the phase is approved" do
      approved = standing.call(verdicts::Approve.new, "now")

      expect([described_class.new(partition:, standing: approved, drafts: [], held: [], current: "now"),
              described_class.new(partition:, standing: approved, drafts: ["next"], held: [], current: "now"),
              described_class.new(partition:, standing: approved, drafts: [], held: [], current: "later")]
               .map(&:landable_digest)).to eq(["now", nil, nil])
    end
  end

  describe "the view is a pure read of one fold" do
    records = lambda do |spec|
      [spec.decided(Lain::Epic::GateDecision::Deferred.new, digest: "blake3:v1"),
       spec.decided(verdicts::Approve.new, digest: "blake3:v2"),
       spec.decided(verdicts::Hold.new, digest: "blake3:v3"),
       spec.decided(Lain::Epic::GateDecision::Deferred.new, digest: "blake3:v4"),
       spec.decided(verdicts::Deny.new, digest: "blake3:v1")]
    end

    it "reads the same view from 2 halves combined as from a single fold" do
      session = records.call(self)
      whole = Lain::Epic::Signoff.over(session)

      (0..session.size).each do |cut|
        halves = Lain::Epic::Signoff.over(session.take(cut)).combine(Lain::Epic::Signoff.over(session.drop(cut)))

        expect(halves.view(partition, current: "blake3:v2")).to eq(whole.view(partition, current: "blake3:v2"))
      end
    end

    it "waits on a draft again once the approval that superseded it is denied" do
      session = [decided(Lain::Epic::GateDecision::Deferred.new, digest: "blake3:d1"),
                 decided(Lain::Epic::GateDecision::Deferred.new, digest: "blake3:d2"),
                 decided(verdicts::Approve.new, digest: "blake3:d2"), decided(verdicts::Deny.new, digest: "blake3:d2")]
      view = Lain::Epic::Signoff.over(session).view(partition, current: "blake3:d2")

      expect([view.phase, view.waiting]).to eq([:parked, ["blake3:d1"]])
    end

    it "carries the parked drafts and the holds the fold left" do
      view = Lain::Epic::Signoff.over(records.call(self)).view(partition, current: "blake3:v2")

      expect([view.drafts, view.held, view.standing.digest]).to eq([["blake3:v4"], ["blake3:v3"], "blake3:v2"])
    end

    it "is open for a partition nothing decided" do
      expect(Lain::Epic::Signoff.unit.view(partition, current: "blake3:v1").phase).to eq(:open)
    end
  end

  describe "the epic plan, read at its structural digest" do
    criteria = <<~GHERKIN
      ```gherkin
      Scenario: the ingest command reads a file
        Given a file of 3 rows
        When it is ingested
        Then the store holds 3 rows
      ```
    GHERKIN

    let(:graph) do
      Lain::Epic::Graph.new(issues: [Lain::Epic::Issue.new(id: "a", title: "Ingest", criteria:, blocks: ["b"]),
                                     Lain::Epic::Issue.new(id: "b", title: "Report")])
    end

    def address(graph) = Lain::Epic::Submission.epic_plan(graph:, slug: "alpha").digest

    def phase_after(graph)
      approval = decided(Lain::Approval::Verdict::Approve.new, digest: address(self.graph), stage: "epic_plan",
                                                               issue_id: nil)
      plan = Lain::Epic::SignoffQueue::Partition.new(epic_slug: "alpha", stage: "epic_plan")
      Lain::Epic::Signoff.over([approval]).view(plan, current: address(graph)).phase
    end

    it "reads edited once epic_graph splits an issue" do
      split = graph.split("b", into: [Lain::Epic::Issue.new(id: "b1", title: "Report one"),
                                      Lain::Epic::Issue.new(id: "b2", title: "Report two")])

      expect(phase_after(split)).to eq(:edited)
    end

    it "stays approved when only an issue's status changes" do
      flipped = Lain::Epic::Graph.new(issues: graph.issues.map { _1.id == "a" ? _1.with_status("in_flight") : _1 })

      expect(phase_after(flipped)).to eq(:approved)
    end

    it "moves the structural digest with titles, criteria and edges, and with nothing else" do
      moved = [graph.retitle("a", "Ingest rows"), graph.unlink("blocks", "a", "b"),
               Lain::Epic::Graph.new(issues: [graph.fetch("a").with(criteria: criteria.sub("3 rows", "4 rows")),
                                              graph.fetch("b")])]
      kept = [Lain::Epic::Graph.new(issues: graph.issues.map { _1.with_status("done") }),
              graph.describe("a", "Reads rows from a file."), graph.subject("a", "ingest")]

      expect(moved.map(&:structural_digest)).to all(satisfy { _1 != graph.structural_digest })
      expect(kept.map(&:structural_digest)).to all(eq(graph.structural_digest))
    end
  end
end
