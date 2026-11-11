# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# lain://planning: the roadmap sidebar of the planning tab, one row per issue
# in graph order with its stage, its gate and what holds it.
RSpec.describe Lain::Frontend::Neovim::PlanningView do
  def issue(id, **overrides) = Lain::Epic::Issue.new(id:, title: "the #{id} issue", **overrides)

  def graph_of(*issues) = Lain::Epic::Graph.new(issues:)

  def status_for(graph)
    Class.new do
      define_method(:progress) { |slug| Lain::Epic::Progress.fold([], graph:, epic_slug: slug) }
      # The digest `decided` approves by, so an issue's approval reads as of the bytes it holds now.
      define_method(:digest_now) { |partition, _standing| partition.issue_id && "blake3:#{partition.issue_id}" }
    end.new
  end

  def epic(graph, records)
    Lain::Frontend::Neovim::StatusView::Mounted.new(slug: "demo", status: status_for(graph),
                                                    records: ->(_slug) { records })
  end

  def decided(id, verdict:, reason: nil, digest: "blake3:#{id}", policy: "interactive")
    { "type" => "gate_decision", "artifact_digest" => digest, "epic_slug" => "demo", "stage" => "issue_plan",
      "issue_id" => id, "verdict" => verdict, "reason" => reason, "policy" => policy }
  end

  def asked(id, deferred: false)
    { "type" => "awaiting_human", "kind" => "gate", "epic_slug" => "demo", "stage" => "issue_plan",
      "issue_id" => id, "ref" => "blake3:#{id}", "deferred" => deferred }
  end

  def denial
    Lain::Epic::GateDecision.new(artifact_digest: "blake3:x", epic_slug: "demo", stage: "issue_plan",
                                 verdict: Lain::Approval::Verdict::Deny.new(note: "needs tests"),
                                 answered_by: "cli", policy: "interactive", latency: 1,
                                 issue_id: "a")
  end

  def row(lines, id) = lines.find { |line| line.include?("`#{id}`") }

  let(:turn) { Lain::Telemetry::TurnUsage.new(digest: "blake3:t", model: "m", stop_reason: :end_turn, usage: {}) }

  describe "the gate round at a glance" do
    it "shows each issue's state and the first line of a denial's reason" do
      ids = (1..20).map { |n| format("i%02d", n) }
      records = ids.first(18).map { |id| decided(id, verdict: "approve") }
      records << decided("i19", verdict: "deny", reason: "criteria are vague\nsecond line stays out")
      records << asked("i20")
      lines = described_class.new(epic: epic(graph_of(*ids.map { |id| issue(id) }), records)).initial

      expect(ids.first(18).map { |id| row(lines, id) }).to all(include("issue_plan, approved"))
      expect(row(lines, "i19")).to include("denied: criteria are vague")
      expect(row(lines, "i19")).not_to include("second line")
      expect(row(lines, "i20")).to include("issue_plan, waiting")
    end

    it "reads a deferred wait after a denial as parked, and an issue with no gate as draft" do
      records = [decided("a", verdict: "deny", reason: "no"), asked("a", deferred: true)]
      lines = described_class.new(epic: epic(graph_of(issue("a"), issue("b")), records)).initial

      expect(row(lines, "a")).to include("issue_plan, parked")
      expect(row(lines, "a")).not_to include("held")
      expect(row(lines, "b")).to include("draft")
    end

    it "draws an approved implementation gate, whose changeset has no artifact digest to re-read" do
      records = [decided("a", verdict: "approve").merge("stage" => "implementation")]
      lines = described_class.new(epic: epic(graph_of(issue("a")), records)).initial

      expect(row(lines, "a")).to include("implementation, approved")
    end

    it "reads a hold as held with its note, not as a denial" do
      records = [asked("a"), decided("a", verdict: "hold", reason: "back after lunch")]
      lines = described_class.new(epic: epic(graph_of(issue("a")), records)).initial

      expect(row(lines, "a")).to include("issue_plan, held: back after lunch")
      expect(row(lines, "a")).not_to include("denied")
    end

    # Scenario: readers agree on the standing -- the row is Epic::Signoff's answer,
    # never a second reading of the newest record.
    it "reads a denial of a draft the approval superseded as approved, as the sign-off queue does" do
      records = [decided("a", verdict: "deferred", digest: "blake3:v1", policy: "deferred"),
                 decided("a", verdict: "approve", digest: "blake3:v2"),
                 decided("a", verdict: "deny", digest: "blake3:v1", reason: "stale draft")]
      lines = described_class.new(epic: epic(graph_of(issue("a")), records)).initial

      expect(row(lines, "a")).to include("issue_plan, approved")
    end

    it "reads a hold over the standing approval of the same digest as approved, as the sign-off queue does" do
      records = [decided("a", verdict: "approve"), decided("a", verdict: "hold", reason: "back after lunch")]
      lines = described_class.new(epic: epic(graph_of(issue("a")), records)).initial

      expect(row(lines, "a")).to include("issue_plan, approved")
    end

    it "lets a later decision supersede an earlier wait" do
      records = [asked("a"), decided("a", verdict: "approve")]
      lines = described_class.new(epic: epic(graph_of(issue("a")), records)).initial

      expect(row(lines, "a")).to include("approved")
    end

    it "names the blockers of a pending issue, in graph order" do
      lines = described_class.new(epic: epic(graph_of(issue("a", blocks: ["b"]), issue("b")), [])).initial

      expect(lines.index(row(lines, "a"))).to be < lines.index(row(lines, "b"))
      expect(row(lines, "b")).to include("blocked by `a`")
    end

    it "ignores a wait that is not a gate's" do
      question = asked("a").merge("kind" => "question")
      lines = described_class.new(epic: epic(graph_of(issue("a")), [question])).initial

      expect(row(lines, "a")).to include("draft")
    end

    it "ignores a record of another epic" do
      foreign = decided("a", verdict: "approve").merge("epic_slug" => "other")
      lines = described_class.new(epic: epic(graph_of(issue("a")), [foreign])).initial

      expect(row(lines, "a")).to include("draft")
    end
  end

  describe "the phase of a gate against the bytes now" do
    # The digest source answers #digest_now as CLI::Epic does; `asked` collects each partition it was asked about.
    def lines_with(records, current, asked: [])
      source = Class.new do
        define_method(:digest_now) do |partition, _standing|
          asked << partition
          current
        end
      end.new
      progress = Lain::Epic::Progress.fold([], graph: graph_of(issue("a")), epic_slug: "demo")
      Lain::Frontend::Neovim::PlanningView::Roadmap.rows(progress, records, digests: source).map(&:line)
    end

    def stage_approval(stage, digest)
      decided(nil, verdict: "approve", digest:).merge("stage" => stage)
    end

    it "reads an approval of the bytes now as approved" do
      row = row(lines_with([decided("a", verdict: "approve", digest: "blake3:v1")], "blake3:v1"), "a")

      expect(row).to include("issue_plan, approved")
      expect(row).not_to include("other bytes")
    end

    it "reads an approval of other bytes as approved at other bytes" do
      expect(row(lines_with([decided("a", verdict: "approve", digest: "blake3:v1")], "blake3:v2"), "a"))
        .to include("issue_plan, approved at other bytes")
    end

    it "reads an approval whose file is gone as gone" do
      expect(row(lines_with([decided("a", verdict: "approve", digest: "blake3:v1")], nil), "a"))
        .to include("issue_plan, approved but its file is gone")
    end

    it "ranks a parked draft before a hold on another draft, as every other reader does" do
      records = [decided("a", verdict: "deferred", digest: "blake3:v1", policy: "deferred"),
                 decided("a", verdict: "hold", digest: "blake3:v2", reason: "later")]

      row = row(lines_with(records, "blake3:v2"), "a")

      expect(row).to include("issue_plan, parked")
      expect(row).not_to include("held")
    end

    it "reads the digest once for an issue however many records its gate has" do
      asked = []
      records = Array.new(50) { decided("a", verdict: "approve", digest: "blake3:v1") }

      lines_with(records, "blake3:v1", asked:)

      expect(asked.count { |partition| partition.issue_id == "a" }).to eq(1)
    end

    it "reads no digest for an issue id a split retired from the graph" do
      asked = []
      retired = Array.new(50) { |n| decided("old#{n}", verdict: "approve", digest: "blake3:v1") }

      lines_with([*retired, decided("a", verdict: "approve", digest: "blake3:v1")], "blake3:v1", asked:)

      expect(asked.count { |partition| partition.stage == "issue_plan" }).to eq(1)
    end

    it "reads no digest for an epic stage nothing approved" do
      asked = []

      lines_with([stage_approval("epic_plan", "blake3:v1")], "blake3:v1", asked:)

      expect(asked.map(&:stage)).to eq(["epic_plan"])
    end

    # Scenario: an edited plan is not shown approved
    it "says an approved epic plan was approved at other bytes and must be submitted again" do
      lines = lines_with([stage_approval("epic_plan", "blake3:v1")], "blake3:v2")

      expect(lines.first).to eq("epic_plan was approved at other bytes and must be submitted again")
    end

    it "says the same of research" do
      lines = lines_with([stage_approval("research", "blake3:v1")], "blake3:v2")

      expect(lines).to include("research was approved at other bytes and must be submitted again")
    end

    it "says nothing of a stage approved at the bytes it holds now" do
      expect(lines_with([stage_approval("epic_plan", "blake3:v1")], "blake3:v1").size).to eq(1)
    end
  end

  describe "refolding" do
    it "redraws on a gate decision or a new wait, and not on tool output" do
      records = []
      view = described_class.new(epic: epic(graph_of(issue("a")), records))
      view.initial
      records << asked("a")

      expect(view.update(Lain::Telemetry::ToolOutput.new(tool_use_id: "t", stream: :stdout, bytes: "x"))).to be_nil
      waiting = Lain::Telemetry::AwaitingHuman.new(kind: "gate", ref: "blake3:a", summary: "ok?", epic_slug: "demo",
                                                   stage: "issue_plan", issue_id: "a")
      expect(view.update(waiting)).to include(a_string_matching(/`a`.*waiting/))
    end

    it "does not refold for a completed turn, which would re-read every journal each time" do
      records = []
      view = described_class.new(epic: epic(graph_of(issue("a")), records))
      view.initial
      records << decided("a", verdict: "approve")

      expect(view.update(turn)).to be_nil
    end

    it "answers nil when a refold found nothing new" do
      view = described_class.new(epic: epic(graph_of(issue("a")), []))
      view.initial

      expect(view.update(turn)).to be_nil
    end
  end

  describe "an epic that cannot be folded, and a chat with none" do
    it "draws the failure instead of raising" do
      broken = Class.new { def roadmap = raise(Lain::Error, "torn journal") }.new

      expect(described_class.new(epic: broken).initial).to include(a_string_including("torn journal"))
    end

    it "draws nothing for a chat in no epic" do
      expect(described_class.new.initial).to eq([])
    end
  end

  # The production construction: a real epic home and a session journal on disk.
  describe "through the production build", :seam do
    around do |example|
      Dir.mktmpdir do |tmp|
        @tmp = tmp
        FileUtils.mkdir_p(File.join(tmp, "project"))
        example.run
      end
    end

    it "reads a gate decision another process journaled" do
      root = File.join(@tmp, "project")
      paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@tmp, "state"), "HOME" => @tmp })
      config = Lain::Config.new(epics: Lain::Config::Epics.new(home: :xdg))
      Lain::Epic::Home.resolve(config:, paths:, root:, slug: "demo").write_epic(graph_of(issue("a")))
      FileUtils.mkdir_p(paths.filing_dir(root:))
      File.open(File.join(paths.filing_dir(root:), "other.ndjson"), "w") do |io|
        Lain::Journal.new(io:).record(denial)
      end
      mounted = Lain::CLI::Wiring::PlanningBuild.mounted(slug: "demo", root:, paths:,
                                                         status: Lain::CLI::Epic.new(root:, paths:, config:))

      expect(described_class.new(epic: mounted).initial).to include(a_string_matching(/`a`.*denied: needs tests/))
    end

    it "draws the roadmap for an approved implementation gate through the real status" do
      root = File.join(@tmp, "project")
      paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@tmp, "state"), "HOME" => @tmp })
      config = Lain::Config.new(epics: Lain::Config::Epics.new(home: :xdg))
      Lain::Epic::Home.resolve(config:, paths:, root:, slug: "demo").write_epic(graph_of(issue("a")))
      FileUtils.mkdir_p(paths.filing_dir(root:))
      approval = Lain::Epic::GateDecision.new(artifact_digest: "0123abcd", epic_slug: "demo", stage: "implementation",
                                              verdict: Lain::Approval::Verdict::Approve.new, answered_by: "cli",
                                              policy: "interactive", latency: 1, issue_id: "a")
      File.open(File.join(paths.filing_dir(root:), "other.ndjson"), "w") { |io| Lain::Journal.new(io:).record(approval) }
      mounted = Lain::CLI::Wiring::PlanningBuild.mounted(slug: "demo", root:, paths:,
                                                         status: Lain::CLI::Epic.new(root:, paths:, config:))

      expect(described_class.new(epic: mounted).initial).to include(a_string_matching(/`a`.*implementation, approved/))
    end

    # Scenario: an edited plan is not shown approved
    it "says the plan was approved at other bytes once the graph was split" do
      root = File.join(@tmp, "project")
      paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@tmp, "state"), "HOME" => @tmp })
      config = Lain::Config.new(epics: Lain::Config::Epics.new(home: :xdg))
      Lain::Epic::Home.resolve(config:, paths:, root:, slug: "demo").write_epic(graph_of(issue("a"), issue("b")))
      FileUtils.mkdir_p(paths.filing_dir(root:))
      digest = Lain::CLI::EpicSubmit::Digests.new(config:, paths:, root:).digest("demo", "epic_plan", nil)
      approval = Lain::Epic::GateDecision.new(artifact_digest: digest, epic_slug: "demo", stage: "epic_plan",
                                              verdict: Lain::Approval::Verdict::Approve.new, answered_by: "cli",
                                              policy: "interactive", latency: 1)
      File.open(File.join(paths.filing_dir(root:), "other.ndjson"), "w") { |io| Lain::Journal.new(io:).record(approval) }
      status = Lain::CLI::Epic.new(root:, paths:, config:,
                                   ignores: instance_double(Lain::CLI::Epic::GitIgnores, reason: ""))
      status.split("b", "b1,b2", "demo")
      mounted = Lain::CLI::Wiring::PlanningBuild.mounted(slug: "demo", root:, paths:, status:)

      expect(described_class.new(epic: mounted).initial)
        .to include("epic_plan was approved at other bytes and must be submitted again")
    end
  end
end
