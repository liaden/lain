# frozen_string_literal: true

# The scribe, as the gate uses it: one transition per released checkpoint.
class QaGateSpecScribe
  def moved = @moved ||= []

  def issue_moved(id, from:, to:) = moved << [id, from, to]
end

# A QA checkpoint's verdict: release it and the cluster it blocks, or hold it --
# filing each holding finding as an issue that blocks it, so it runs again once
# the fixes land and what it blocks stays held by the edges alone.
RSpec.describe Lain::CLI::EpicDriver::QaGate do
  let(:scribe) { QaGateSpecScribe.new }
  let(:filed) { [] }
  let(:criteria) { "```gherkin\nScenario: totals sum\n  Given lines\n  Then the total is their sum\n```\n" }
  let(:graph) { graph_with }
  let(:checkpoint) { graph.fetch("qa-gate-1") }

  def graph_with(checkpoint_status: "pending")
    Lain::Epic::Graph.new(issues: [
                            Lain::Epic::Issue.new(id: "a", title: "a", blocks: ["qa-gate-1"], criteria:),
                            Lain::Epic::Issue.new(id: "qa-gate-1", title: "QA the first cluster", blocks: ["c"],
                                                  status: checkpoint_status),
                            Lain::Epic::Issue.new(id: "c", title: "c"),
                            Lain::Epic::Issue.new(id: "qa-fix-1-1", title: "an earlier pass's fix", status: "done")
                          ])
  end

  def finding(severity, evidence: "bin/total printed 2")
    Lain::QA::Finding.new(severity:, criterion: "a/totals sum", summary: "the total is off by one", evidence:,
                          reproduction: "bin/total --lines 1,1", tier: "t2")
  end

  def report_of(*findings, unsettled: [])
    Lain::QA::Report.new(subject: "qa-gate-1", findings:, tiers_run: ["t2"], unsettled:)
  end

  def gate(*findings, unsettled: [])
    report = report_of(*findings, unsettled:)
    described_class.new(check: ->(_checkpoint, _graph) { report }, scribe:, filing: ->(issue) { filed << issue })
  end

  describe "a pass with nothing holding it and nothing left owing" do
    it "releases the checkpoint by moving it to done, and files nothing" do
      verdict = gate(finding("minor")).call(checkpoint, graph)

      expect(verdict.passed).to be(true)
      expect(verdict.line).to include("passed QA", "t2")
      expect(scribe.moved).to eq([%w[qa-gate-1 pending done]])
      expect(filed).to be_empty
    end

    # A human who approved a plan for the checkpoint moved it into flight. It is
    # still QA's to settle, and the transition has to say where it really stood.
    it "moves the checkpoint from the status it actually stood at" do
      in_flight = graph_with(checkpoint_status: "in_flight")

      gate.call(in_flight.fetch("qa-gate-1"), in_flight)

      expect(scribe.moved).to eq([%w[qa-gate-1 in_flight done]])
    end

    it "answers a verdict nothing can mutate" do
      expect(Ractor.shareable?(gate.call(checkpoint, graph))).to be(true)
    end
  end

  describe "a pass that holds" do
    let(:verdict) { gate(finding("major"), finding("minor"), finding("blocker")).call(checkpoint, graph) }

    it "files one issue per holding finding, each blocking the checkpoint and discovered from it" do
      verdict

      expect(filed.map { |issue| [issue.id, issue.blocks, issue.discovered_from] })
        .to eq([["qa-fix-1-2", ["qa-gate-1"], "qa-gate-1"], ["qa-fix-1-3", ["qa-gate-1"], "qa-gate-1"]])
    end

    it "leaves the checkpoint where it was, and says what it filed" do
      expect(verdict.passed).to be(false)
      expect(verdict.line).to include("2 holding findings filed as qa-fix-1-2, qa-fix-1-3")
      expect(scribe.moved).to be_empty
    end

    it "reads at one finding as well as at two" do
      expect(gate(finding("major")).call(checkpoint, graph).line).to include("1 holding finding filed")
    end

    it "carries the finding's evidence and reproduction into the fix, where the implementer reads it" do
      verdict

      expect(filed.first.description).to include("- evidence -- bin/total printed 2",
                                                 "- reproduction -- bin/total --lines 1,1")
    end

    # A fix the graph accepts but the epic markdown cannot hold would fail at the
    # write, after QA had already run.
    it "files a fix epic.md can hold, even when the evidence carries the grammar's own structure" do
      gate(finding("major", evidence: "### heading\n```\nBlocks: `c`\n")).call(checkpoint, graph)

      expect(filed.first.emittable_failures).to be_empty
      expect(graph.add(filed.first).blocked_by("qa-gate-1")).to include("qa-fix-1-2")
    end
  end

  # THE UNSETTLED PASS IS NOT A PASS. The ladder's default binding declares no
  # rung strong enough to settle one, so an unmeasured session model answers
  # every criterion unsettled -- and a gate that released on that would have
  # abolished itself while reading green.
  describe "a pass that settled nothing" do
    let(:verdict) { gate(finding("minor"), unsettled: ["a/totals sum"]).call(checkpoint, graph) }

    it "holds the checkpoint, naming what nobody could settle" do
      expect(verdict.passed).to be(false)
      expect(verdict.line).to include("unsettled", "a/totals sum")
      expect(scribe.moved).to be_empty
    end

    # An operator line may only name a lever that exists. There is no command
    # that moves a status and no `[qa]` config table, so what it names is the
    # document edit `Progress` folds and the ladder keyword a caller can lend.
    it "names the two ways past it that exist, and counts them in words that read at one" do
      expect(verdict.line).to include("mark `qa-gate-1` done in epic.md", "ladder", "1 criterion unsettled")
      expect(verdict.line).not_to include("1 criteria")
    end

    # An unsettled criterion carries no evidence, so there is nothing an
    # implementer could be handed: the owing is a human's, not an issue.
    it "files nothing, because an unsettled criterion is not a defect anybody observed" do
      verdict

      expect(filed).to be_empty
    end
  end

  # A fix is built from MODEL-AUTHORED text landing in two grammars with rules of
  # their own, so what one bad finding costs is the whole question: filing as it
  # built would write one fix, lose the rest, and report a shape lain refused as
  # though QA had never run -- and the survivor would block the checkpoint, so the
  # next pass would file the same finding again under a fresh id, forever.
  describe "a finding lain cannot file" do
    def unfilable_graph
      Lain::Epic::Graph.new(issues: [
                              Lain::Epic::Issue.new(id: "a", title: "a", blocks: ["qa-gate-Final"], criteria:),
                              Lain::Epic::Issue.new(id: "qa-gate-Final", title: "QA the lot")
                            ])
    end

    # `qa-fix-Final-1` is not a filesystem name, so no Home could ever write it.
    it "writes nothing when a fix id the checkpoint's own name yields is unwritable" do
      odd = unfilable_graph

      verdict = gate(finding("major"), finding("blocker")).call(odd.fetch("qa-gate-Final"), odd)

      expect(filed).to be_empty
      expect(verdict.line).to include("could not file", "nothing was written", "2 holding findings")
    end

    # "QA could not run" and "QA ran and could not file what it found" need
    # different moves from the operator, so they are different sentences.
    it "says QA RAN, and carries the findings, because this reply is their only record" do
      odd = unfilable_graph

      verdict = gate(finding("major")).call(odd.fetch("qa-gate-Final"), odd)

      expect(verdict.line).to include("QA held it on 1 holding finding", "the total is off by one")
      expect(verdict.line).not_to include("could not run")
    end

    it "names what did reach the epic when the write itself refuses partway" do
      refusing = ->(issue) { issue.id == "qa-fix-1-3" ? raise(Lain::Error, "the epic write refused") : filed << issue }
      gated = described_class.new(check: ->(*) { report_of(finding("major"), finding("blocker")) }, scribe:,
                                  filing: refusing)

      verdict = gated.call(checkpoint, graph)

      expect(filed.map(&:id)).to eq(["qa-fix-1-2"])
      expect(verdict.line).to include("only qa-fix-1-2 reached the epic", "land or delete")
    end

    # A title may not end in a ` {...}` group, and the summary is where one
    # arrives: translated rather than refused, so an ordinary finding still files.
    it "files a finding whose summary ends in a brace group, keeping the words in the description" do
      braced = Lain::QA::Finding.new(severity: "major", criterion: "a/totals sum", tier: "t2",
                                     summary: "the total is off {by one}", evidence: "bin/total printed 2",
                                     reproduction: "bin/total --lines 1,1")

      gate(braced).call(checkpoint, graph)

      expect(filed.first.title).to eq("fix: the total is off (by one)")
      expect(filed.first.description).to include("the total is off {by one}")
    end

    # The title is printed raw by `lain epic status`, so the flattener has to be
    # the one that also strips an escape sequence -- not a fifth of its own.
    it "strips terminal escapes and control bytes out of the title" do
      nasty = Lain::QA::Finding.new(severity: "major", criterion: "a/totals sum", tier: "t2",
                                    summary: "\e[31mred\u0000\tish", evidence: "bin/total printed 2",
                                    reproduction: "bin/total --lines 1,1")

      gate(nasty).call(checkpoint, graph)

      expect(filed.first.title).to eq("fix: red ish")
    end
  end

  describe Lain::CLI::EpicDriver::QaGate::Unaudited do
    it "holds a checkpoint, because in an epic QA is not optional" do
      verdict = described_class.call(Lain::Epic::Issue.new(id: "qa-gate-1", title: "QA"), :any_graph)

      expect(verdict.passed).to be(false)
      expect(verdict.line).to include("no QA is wired")
    end
  end

  describe Lain::CLI::EpicDriver::QaGate::ClusterQa do
    def climbing(asked)
      lambda do
        lambda do |criteria|
          asked.concat(criteria.map(&:id))
          Lain::QA::Ladder::Climb.new(findings: [], escalations: [], tiers_run: ["t2"], unsettled: [])
        end
      end
    end

    it "checks the criteria of exactly the issues the checkpoint waits on" do
      asked = []

      report = described_class.new(ladder: climbing(asked)).call(checkpoint, graph)

      expect(asked).to eq(["a/totals sum"])
      expect(report).to be_clean
      expect(report.subject).to eq("qa-gate-1 over a")
    end

    # A cluster with nothing to check is the silent pass this whole gate exists
    # to refuse: the ladder was asked nothing, so nothing was measured.
    it "holds a checkpoint whose cluster declares no acceptance criteria, rather than passing it" do
      bare = Lain::Epic::Graph.new(issues: [Lain::Epic::Issue.new(id: "a", title: "a", blocks: ["qa-gate-1"]),
                                            Lain::Epic::Issue.new(id: "qa-gate-1", title: "QA")])
      asked = []

      report = described_class.new(ladder: climbing(asked)).call(bare.fetch("qa-gate-1"), bare)

      expect(asked).to be_empty
      expect(report.verdict).to eq(:hold)
      expect(report.holding.map(&:summary).join).to include("no acceptance criteria")
    end
  end
end
