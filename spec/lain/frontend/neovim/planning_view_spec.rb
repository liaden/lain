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
    end.new
  end

  def epic(graph, records)
    Lain::Frontend::Neovim::StatusView::Mounted.new(slug: "demo", status: status_for(graph),
                                                    records: ->(_slug) { records })
  end

  def decided(id, approved:, reason: nil)
    { "type" => "gate_decision", "epic_slug" => "demo", "stage" => "issue_plan", "issue_id" => id,
      "approved" => approved, "reason" => reason }
  end

  def asked(id, deferred: false)
    { "type" => "awaiting_human", "kind" => "gate", "epic_slug" => "demo", "stage" => "issue_plan",
      "issue_id" => id, "ref" => "blake3:#{id}", "deferred" => deferred }
  end

  def denial
    Lain::Epic::GateDecision.new(artifact_digest: "blake3:x", epic_slug: "demo", stage: "issue_plan", approved: false,
                                 answered_by: "cli", policy: "interactive", latency: 1, reason: "needs tests",
                                 issue_id: "a")
  end

  def row(lines, id) = lines.find { |line| line.include?("`#{id}`") }

  let(:turn) { Lain::Telemetry::TurnUsage.new(digest: "blake3:t", model: "m", stop_reason: :end_turn, usage: {}) }

  describe "the gate round at a glance" do
    it "shows each issue's state and the first line of a denial's reason" do
      ids = (1..20).map { |n| format("i%02d", n) }
      records = ids.first(18).map { |id| decided(id, approved: true) }
      records << decided("i19", approved: false, reason: "criteria are vague\nsecond line stays out")
      records << asked("i20")
      lines = described_class.new(epic: epic(graph_of(*ids.map { |id| issue(id) }), records)).initial

      expect(ids.first(18).map { |id| row(lines, id) }).to all(include("issue_plan, approved"))
      expect(row(lines, "i19")).to include("denied: criteria are vague")
      expect(row(lines, "i19")).not_to include("second line")
      expect(row(lines, "i20")).to include("issue_plan, waiting")
    end

    it "reads a deferred wait after a denial as held, and an issue with no gate as draft" do
      records = [decided("a", approved: false, reason: "no"), asked("a", deferred: true)]
      lines = described_class.new(epic: epic(graph_of(issue("a"), issue("b")), records)).initial

      expect(row(lines, "a")).to include("held")
      expect(row(lines, "b")).to include("draft")
    end

    it "lets a later decision supersede an earlier wait" do
      records = [asked("a"), decided("a", approved: true)]
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
      foreign = decided("a", approved: true).merge("epic_slug" => "other")
      lines = described_class.new(epic: epic(graph_of(issue("a")), [foreign])).initial

      expect(row(lines, "a")).to include("draft")
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
      records << decided("a", approved: true)

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
  end
end
