# frozen_string_literal: true

require "fileutils"
require "json"
require "pty"
require "stringio"
require "tmpdir"

module EpicSubmitSpecSupport
  # A {Lain::Skill::RoleSpawn} stand-in scripted per role: an adjudicated gate
  # spawns the evidence spike and the verdict as two roles in one decision.
  # It builds no children, so the copy an adjudicator spawns through is itself.
  class ScriptedRoleSpawn
    def initialize(answers)
      @answers = answers
    end

    def never_parking = self

    # An answer may be a callable, to answer each prompt on its own.
    def call(role, _context_mode, prompt)
      answer = @answers.fetch(role)
      Lain::Tool::Result.ok(answer.respond_to?(:call) ? answer.call(prompt) : answer)
    end
  end

  # The three things the adjudication pair reads off a backend; `provider` is
  # asked for with the journal its own records should land in.
  FakeBackend = Data.define(:wire, :context, :slots) do
    def provider(**) = wire
  end
end

# `lain epic submit` is the one verb that puts an epic's artifact in front of a
# gate. Everything it does is assembled from objects that already carry their
# own specs -- {Lain::Epic::Submission} addresses the artifact,
# {Lain::Epic::Gate::Policies} chooses HOW the verdict is reached,
# {Lain::Epic::SignoffQueue} remembers what was already approved, and
# {Lain::Epic::Scribe} is the only writer of a stage transition -- so what is
# pinned here is the WIRING, and the three ways it must refuse.
#
# The refusals are the point. A submit whose policy cannot be built must fail at
# WIRING time naming the seam, not hours in; a submit that crosses a stage
# boundary with sign-offs still parked must journal nothing at all; and a
# re-submit of a digest that already carries an approval must decide nothing a
# second time, because {Epic::Gate}'s registry is add-only and a second
# verdict over a standing approval could only ever be noise in the record.
RSpec.describe Lain::CLI::EpicSubmit do
  around do |example|
    Dir.mktmpdir do |tmp|
      @tmp = tmp
      FileUtils.mkdir_p(root)
      example.run
    end
  end

  def root = File.join(@tmp, "project")
  def state_home = File.join(@tmp, "state")
  def paths = @paths ||= Lain::Paths.new(env: { "XDG_STATE_HOME" => state_home, "HOME" => state_home })

  def config(gates = {}, approval_timeout: Lain::Approval::Parked::Queue::DEFAULT_TIMEOUT,
             approval_silence: Lain::Config::DEFAULT_APPROVAL_SILENCE)
    Lain::Config.new(epics: Lain::Config::Epics.new(home: :xdg, gates:), approval_timeout:, approval_silence:)
  end

  # Every stage gated the same way, so an example that is about ONE stage does
  # not have to keep the other three buildable by hand. `for_all` resolves the
  # whole pipeline at wiring time, which is the behaviour under test in the
  # missing-seam example below -- and the reason a stage nobody is submitting
  # still has to name a policy this session can construct.
  def hands_off = Lain::Epic::STAGES.to_h { |stage| [stage, "hands_off"] }

  # A terminal a human answers. `instance_double(IO)` is what makes
  # `respond_to?(:tty?)` true without a pty, which is the one question the
  # command asks before it decides it has an asker at all.
  # Each read takes the next reply, and the last one repeats.
  def tty(*replies)
    instance_double(IO, tty?: true).tap do |input|
      allow(input).to receive(:gets).and_return(*(replies.empty? ? ["y\n"] : replies))
    end
  end

  def command(gates: hands_off, input: tty, output: StringIO.new, approval_timeout: 300)
    described_class.new(root:, paths:, config: config(gates, approval_timeout:), input:, output:)
  end

  def home(slug = "alpha") = Lain::Epic::Home.resolve(config:, paths:, root:, slug:)

  # An implementation's digest names a commit in the project's repository.
  def commit_sha
    @commit_sha ||= begin
      SeedRepo.git(root, "init", "-q")
      SeedRepo.git(root, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false",
                   "commit", "-q", "--allow-empty", "-m", "work")
      SeedRepo.git(root, "rev-parse", "HEAD").stdout.strip
    end
  end

  def research_text = "the research, such as it is\n"

  def write_research(text = research_text, slug: "alpha") = home(slug).research.write(text)
  def write_epic(slug: "alpha") = home(slug).write_epic(chain)

  def issue(id, **overrides) = Lain::Epic::Issue.new(id:, title: "the #{id} issue", **overrides)
  def chain = Lain::Epic::Graph.new(issues: [issue("a", blocks: ["b"]), issue("b")])

  def sessions_dir = paths.filing_dir(root:)

  def session(name, *records, at: "2026-01-01T00:00:00Z")
    File.open(File.join(sessions_dir, name), "w") do |io|
      journal = Lain::Journal.new(io:, clock: -> { at })
      records.each { |record| journal.record(record) }
    end
  end

  # Ordered by `ts`, the way {Lain::CLI::SessionJournals} orders the same
  # directory: a fixture stamped in January and a live record stamped today land
  # in files whose NAMES sort the other way round, and reading them in filename
  # order would make the fold see a completion before its own start.
  def session_records
    Dir.children(sessions_dir).select { |name| name.end_with?(".ndjson") }.sort
       .flat_map { |name| Lain::Journal.records(File.foreach(File.join(sessions_dir, name))).to_a }
       .sort_by { |record| record["ts"].to_s }
  end

  def gate_decisions = session_records.select { |record| record["type"] == "gate_decision" }
  def stage_transitions = session_records.select { |record| record["type"] == "stage_transition" }
  def stage_events = stage_transitions.map { |record| [record["stage"], record["event"]] }

  def progress(slug = "alpha")
    Lain::Epic::Progress.fold(session_records, graph: home(slug).read_epic, epic_slug: slug)
  end

  # Built through the real producers, so no fixture can drift from the wire
  # shape the live path writes.
  def decision(digest:, stage:, approved: false, policy: "deferred", slug: "alpha")
    Lain::Epic::GateDecision.new(artifact_digest: digest, epic_slug: slug, stage:,
                                 verdict: Lain::Approval::Verdict.const_get(approved ? :Approve : :Deny).new,
                                 answered_by: policy, policy:, latency: 1.0)
  end

  # Approvals of the named stages, as the stages before an epic's later gates
  # carry them: a boundary opens only over an earlier stage approved at the
  # bytes its artifact holds now, so each is stamped at the current digest.
  def approvals(*stages, slug: "alpha")
    stages.map do |stage|
      decision(digest: current_digest(slug, stage), stage:, approved: true, policy: "hands_off", slug:)
    end
  end

  def current_digest(slug, stage)
    Lain::CLI::EpicSubmit::Digests.new(config:, paths:, root:).digest(slug, stage, nil) || "blake3:#{stage}-gone"
  end

  # The research and plan approvals an epic past its plan carries. Research is
  # stamped at the bytes on disk, so a setup writes research.md before this.
  def epic_approved(slug: "alpha") = approvals(*epic_approved_stages, slug:)

  def epic_approved_stages = %w[research epic_plan]

  # What the examples decided, past the approvals a fixture stamped before them.
  def submitted_decisions = gate_decisions.drop(epic_approved_stages.size)

  def stage_event(stage, event: "started", slug: "alpha")
    Lain::Epic::StageTransition.new(epic_slug: slug, stage:, event:)
  end

  def research_digest(text = research_text, slug: "alpha")
    Lain::Epic::Submission.research(text:, slug:).digest
  end

  def epic_plan_digest(slug: "alpha")
    Lain::Epic::Submission.epic_plan(graph: home(slug).read_epic, slug:).digest
  end

  # Scenario: a hands_off submit advances the stage
  describe "an approved submit" do
    before do
      write_research
      write_epic
    end

    it "names the approval and the artifact it approved" do
      said = command(gates: { "research" => "hands_off" }).submit("research").text

      expect(said).to include("approved", research_digest, "research", "alpha")
    end

    it "names the policy that approved it" do
      said = command(gates: { "research" => "hands_off" }).submit("research").text

      expect(said.lines.first).to include("by policy hands_off")
    end

    it "journals one approving gate_decision under the configured policy" do
      command(gates: { "research" => "hands_off" }).submit("research")

      expect(gate_decisions.map { |record| record.values_at("verdict", "policy", "stage") })
        .to eq([%w[approve hands_off research]])
    end

    it "completes the gated stage and starts its successor" do
      command(gates: { "research" => "hands_off" }).submit("research")

      expect(stage_events).to eq([%w[research completed], %w[epic_plan started]])
      expect(progress.stage.name).to eq("epic_plan")
    end

    # An issue's implementation is ONE issue's; approving it says nothing about
    # the epic's other issues, so it moves no epic-wide stage.
    it "moves no epic-wide stage when one issue's implementation is approved", :seam do
      write_research
      session("started.ndjson", *epic_approved, stage_event("issue_plan"))
      home.issue("a").write("the prose for a\n")
      command.submit("issue_plan", issue: "a")

      command.submit("implementation", issue: "a", digest: commit_sha)

      expect(stage_events).to eq([%w[issue_plan started]])
      expect(submitted_decisions.map { |record| record.values_at("stage", "issue_id", "verdict") })
        .to eq([%w[issue_plan a approve], %w[implementation a approve]])
    end

    it "parks a manual issue's implementation under hands_off, naming manual acceptance", :seam do
      home.write_epic(Lain::Epic::Graph.new(issues: [issue("a", subject: "scripts/x.sh", level: "manual")]))
      write_research
      session("started.ndjson", *epic_approved, stage_event("issue_plan"))
      home.issue("a").write("the prose for a\n")
      command.submit("issue_plan", issue: "a")

      command.submit("implementation", issue: "a", digest: commit_sha)

      implementation = gate_decisions.find { |record| record["stage"] == "implementation" }
      expect(implementation).to include("verdict" => "deferred", "policy" => "deferred")
      expect(session_records.select { |record| record["type"] == "awaiting_human" && record["issue_id"] == "a" })
        .to include(include("deferred" => true, "summary" => /manual acceptance/))
    end

    # `Bench::EpicMetrics` folds round trips on the record's `issue_id`, and an
    # epic-wide decision is the nil member of that key -- present, not absent.
    it "journals an epic-wide decision with a nil issue" do
      command(gates: { "research" => "hands_off" }).submit("research")

      expect(gate_decisions.first).to include("issue_id" => nil)
    end
  end

  # The first gate of the real pipeline: research-epic writes research.md, and
  # plan-epic writes epic.md only once research is approved. So research is
  # decided, advanced and repaired with no epic.md on disk.
  describe "research, before epic.md exists" do
    before { write_research }

    it "approves research and advances the epic" do
      said = command(gates: { "research" => "hands_off" }).submit("research").text

      expect(said).to start_with("approved #{research_digest}")
      expect(said).to include("research completed, epic_plan started")
      expect(gate_decisions.map { |record| record.values_at("verdict", "stage") }).to eq([%w[approve research]])
      expect(stage_events).to eq([%w[research completed], %w[epic_plan started]])
      expect(home.epic.exist?).to be(false)
    end

    it "repairs a standing research approval that never advanced the epic" do
      session("approved.ndjson", decision(digest: research_digest, stage: "research", approved: true,
                                          policy: "hands_off"))

      said = command(gates: { "research" => "hands_off" }).submit("research").text

      expect(said).to include("already approved", "research completed, epic_plan started")
      expect(stage_events).to eq([%w[research completed], %w[epic_plan started]])
    end
  end

  describe "a hand-placed file in sources/ that is not a source name" do
    before do
      write_research
      FileUtils.mkdir_p(File.join(home("alpha").path, "sources"))
      File.write(File.join(home("alpha").path, "sources", "Odd.md"), "a cited fact\n")
    end

    it "refuses the submit naming the file, and journals no gate_decision" do
      expect { command(gates: { "research" => "hands_off" }).submit("research") }
        .to raise_error(Lain::Error,
                        /#{Regexp.escape(File.join(home("alpha").path, "sources",
                                                   "Odd.md"))}.*not a valid source name.*rename or remove/)
      expect(gate_decisions).to be_empty
    end
  end

  # Where the epic stands is read BEFORE the verdict is journaled, so a stage
  # record the fold cannot read refuses the submit with nothing recorded. Read
  # after, it left an approval on the record and an epic that never moved.
  describe "a stage record the fold cannot read" do
    before do
      write_research
      write_epic
      unreadable = { "ts" => "2026-01-01T00:00:00Z", "type" => "stage_transition", "epic_slug" => "alpha",
                     "stage" => "reserach", "event" => "started" }
      File.write(File.join(sessions_dir, "damaged.ndjson"), "#{JSON.generate(unreadable)}\n")
    end

    it "refuses the submit as a named error, and journals no gate_decision" do
      expect { command(gates: { "research" => "hands_off" }).submit("research") }
        .to raise_error(Lain::Error, /reserach/)
      expect(gate_decisions).to be_empty
    end
  end

  # Scenarios: a parked issue does not block a sibling; approving an issue's
  # plan puts that issue in flight, and only it.
  describe "issue-scoped gates" do
    before do
      write_epic
      write_research
      session("started.ndjson", *epic_approved, stage_event("issue_plan"))
      home.issue("a").write("the prose for a\n")
      home.issue("b").write("the prose for b\n")
    end

    def deferring = command(gates: hands_off.merge("issue_plan" => "deferred"))
    def changeset = commit_sha
    def parked_plans = Lain::Epic::SignoffQueue.from_journal(session_records).parked("alpha", "issue_plan")

    it "opens b's implementation gate while a's issue_plan is parked", :seam do
      deferring.submit("issue_plan", issue: "a")
      command.submit("issue_plan", issue: "b")

      said = command.submit("implementation", issue: "b", digest: changeset).text

      expect(said).to start_with("approved")
      expect(parked_plans.map(&:issue_id)).to eq(["a"])
    end

    # An implementation's address names its issue, so an approval of a's commit
    # opens no other issue's gate over that same commit.
    it "does not read a's implementation approval as b's, over the same commit", :seam do
      command.submit("issue_plan", issue: "a")
      command.submit("issue_plan", issue: "b")
      command.submit("implementation", issue: "a", digest: changeset)

      said = command.submit("implementation", issue: "b", digest: changeset).text

      expect(said).not_to start_with("already approved")
      implementations = gate_decisions.select { |record| record["stage"] == "implementation" }
      expect(implementations.map { |record| record.values_at("issue_id", "verdict") })
        .to eq([%w[a approve], %w[b approve]])
      expect(implementations.map { |record| record["artifact_digest"] }.uniq.size).to eq(2)
    end

    it "still refuses a's own implementation while a's plan is parked", :seam do
      deferring.submit("issue_plan", issue: "a")

      expect { command.submit("implementation", issue: "a", digest: changeset) }
        .to raise_error(Lain::Error, /"a".*issue_plan/m)
    end

    it "puts a in flight when a's plan is approved, leaves b pending, and takes a out of the ready set" do
      expect(progress.ready.map(&:id)).to eq(["a"])

      said = command.submit("issue_plan", issue: "a").text

      expect(said).to include("issue a moved pending -> in_flight")
      expect([progress.status("a"), progress.status("b")]).to eq(%w[in_flight pending])
      expect(progress.ready.map(&:id)).not_to include("a")
    end

    it "moves an issue only once -- re-approving a revised plan for an issue in flight moves nothing" do
      command.submit("issue_plan", issue: "a")
      home.issue("a").write("the prose for a, revised\n")

      command.submit("issue_plan", issue: "a")

      expect(session_records.count { |record| record["type"] == "issue_transition" }).to eq(1)
    end

    # A plan the adjudicator would not call parks, and a human approves it
    # from the queue -- the designed path. The driver launches only issues in
    # flight, so the queue's approval must move the issue exactly as a verdict
    # here would.
    it "puts a in flight when a's parked plan is approved from the queue" do
      deferring.submit("issue_plan", issue: "a")
      queue = Lain::CLI::EpicQueue.new(paths:, root:,
                                       epics: Lain::CLI::Epic.new(root:, paths:, config: config(hands_off)))

      said = queue.approve(parked_plans.first.artifact_digest)

      expect(said).to include("issue a moved pending -> in_flight")
      expect([progress.status("a"), progress.status("b")]).to eq(%w[in_flight pending])
    end

    it "names the issue's own partition when its plan parks" do
      expect(deferring.submit("issue_plan", issue: "a").text).to include("parked in alpha/issue_plan/a")
    end

    it "moves no epic-wide stage for one issue's plan" do
      command.submit("issue_plan", issue: "a")

      expect(stage_events).to eq([%w[issue_plan started]])
    end

    it "journals the issue on the decision and on the park" do
      deferring.submit("issue_plan", issue: "a")

      expect(submitted_decisions.map { |record| record["issue_id"] }).to eq(["a"])
      expect(parked_plans.map(&:issue_id)).to eq(["a"])
    end
  end

  # One question per wave of issue plans, one decision per issue.
  describe "a wave of issue plans" do
    def wave_graph = Lain::Epic::Graph.new(issues: [issue("a", blocks: %w[b c d]), issue("b"), issue("c"), issue("d")])

    before do
      home.write_epic(wave_graph)
      write_research
      session("started.ndjson", *epic_approved, stage_event("issue_plan"))
      %w[a b c d].each { |id| home.issue(id).write("the prose for #{id}\n") }
    end

    def asking(*replies, output: StringIO.new)
      command(gates: hands_off.merge("issue_plan" => "interactive"), input: tty(*replies.map { "#{_1}\n" }), output:)
    end

    def plan_digest(id)
      Lain::Epic::Submission.issue_plan(view: Lain::Epic::IssueView.read(home, id), slug: "alpha", issue_id: id).digest
    end

    def verdicts = submitted_decisions.to_h { |record| [record["issue_id"], record.values_at("verdict", "reason")] }

    # Scenario: a wave is approved but for one issue
    it "approves the wave but for the issue a deny names, and names all 3 outcomes" do
      said = asking("approve; deny c: the end time is missing").submit("issue_plan", wave: 2)

      expect(verdicts).to eq("b" => ["approve", nil], "c" => ["deny", "the end time is missing"],
                             "d" => ["approve", nil])
      expect(said.status).to eq(1)
      expect(said.text).to include("approved b #{plan_digest("b")}", "approved d #{plan_digest("d")}",
                                   "denied c #{plan_digest("c")}", "reason: the end time is missing")
    end

    # Scenario: implementation still needs each issue's own approval
    it "still refuses c's implementation, naming c's issue_plan gate, while b's plan stands" do
      asking("approve; deny c: the end time is missing").submit("issue_plan", wave: 2)

      expect(command.ensure_plan_approved!("b")).to eq(plan_digest("b"))
      expect { command.ensure_plan_approved!("c") }
        .to raise_error(described_class::PlanNotApproved, /"c".*issue_plan #{plan_digest("c")}/m)
    end

    # Scenario: a mistyped id is asked again
    it "asks again when the reply names an id outside the wave, saying so, and decides on the next reply" do
      screen = StringIO.new
      asking("deny cc: the end time is missing", "deny", output: screen).submit("issue_plan", wave: 2)

      expect(screen.string).to include("cc is not in wave 2")
      expect(verdicts).to eq(%w[b c d].to_h { |id| [id, ["deny", nil]] })
    end

    it "reports a held issue as held, beside the issues decided" do
      said = asking("approve; hold c: after lunch").submit("issue_plan", wave: 2)

      expect(said.status).to eq(1)
      expect(said.text).to include("approved b", "held c #{plan_digest("c")}", "note: after lunch", "approved d")
    end

    # Scenario: a bare deny denies everything
    it "denies b, c and d with a bare deny's reason" do
      asking("deny: not yet").submit("issue_plan", wave: 2)

      expect(verdicts).to eq(%w[b c d].to_h { |id| [id, ["deny", "not yet"]] })
    end

    # Scenario: a semicolon inside a reason is not a new clause
    it "keeps a semicolon inside a reason, and starts a clause at the next verdict word" do
      asking("approve; deny c: keep the WAV; add the end time; deny d: rename it").submit("issue_plan", wave: 2)

      expect(verdicts).to eq("b" => ["approve", nil], "c" => ["deny", "keep the WAV; add the end time"],
                             "d" => ["deny", "rename it"])
    end

    it "puts every approved issue in flight" do
      said = asking("approve").submit("issue_plan", wave: 2)

      expect(said.status).to eq(0)
      expect(%w[b c d].map { |id| progress.status(id) }).to eq(%w[in_flight in_flight in_flight])
    end

    it "asks one question, listing each issue's title, blockers and view path" do
      screen = StringIO.new
      asking("approve", output: screen).submit("issue_plan", wave: 2)

      expect(screen.string.scan(described_class::Prompt::CUE).size).to eq(1)
      expect(screen.string).not_to include("[y/N]")
      expect(screen.string).to include("wave 2", '"the b issue"', "blocked by a", "lain://epic/alpha/issues/d.md")
    end

    it "holds the whole wave on hold, telling the agent to wait" do
      held = asking("hold").submit("issue_plan", wave: 2)

      expect(held).to be_a(described_class::Held)
      expect(submitted_decisions.map { |record| record["verdict"] }).to eq(%w[hold hold hold])
    end

    it "parks one item per issue under the deferred policy" do
      said = command(gates: hands_off.merge("issue_plan" => "deferred")).submit("issue_plan", wave: 2)

      parked = Lain::Epic::SignoffQueue.from_journal(session_records).parked("alpha", "issue_plan")
      expect(parked.map(&:issue_id)).to contain_exactly("b", "c", "d")
      expect(said.text).to include("parked in alpha/issue_plan/c")
    end

    it "runs one evidence spike per issue under the adjudicated policy" do
      spawn = EpicSubmitSpecSupport::ScriptedRoleSpawn.new(evidence_researcher: "the plan names its files",
                                                           gate_adjudicator: "APPROVE")
      adjudicating = described_class.new(root:, paths:, config: config(hands_off.merge("issue_plan" => "adjudicated")),
                                         role_spawn: spawn, brief: ->(artifact) { "read #{artifact.issue_id}" })

      said = adjudicating.submit("issue_plan", wave: 2)

      expect(session_records.select { |record| record["type"] == "gate_evidence" }.map { |record| record["stage"] })
        .to eq(%w[issue_plan issue_plan issue_plan])
      expect(verdicts.values.map(&:first)).to eq(%w[approve approve approve])
      expect(said.status).to eq(0)
    end

    it "journals each issue's own adjudicated verdict, a deny beside the approvals" do
      judge = ->(prompt) { prompt.include?("issue c ") ? "DENY" : "APPROVE" }
      spawn = EpicSubmitSpecSupport::ScriptedRoleSpawn.new(evidence_researcher: "the plan names its files",
                                                           gate_adjudicator: judge)
      adjudicating = described_class.new(root:, paths:, config: config(hands_off.merge("issue_plan" => "adjudicated")),
                                         role_spawn: spawn, brief: ->(artifact) { "read #{artifact.issue_id}" })

      said = adjudicating.submit("issue_plan", wave: 2)

      expect(verdicts.transform_values(&:first)).to eq("b" => "approve", "c" => "deny", "d" => "approve")
      expect(said.status).to eq(1)
      expect(said.text).to include("2 approved, 0 held, 1 not", "approved b", "denied c", "approved d")
    end

    it "counts a held issue on its own in the heading" do
      said = asking("approve; hold c: after lunch").submit("issue_plan", wave: 2)

      expect(said.text).to include("2 approved, 1 held, 0 not")
    end

    # A new edge or a status mark reopens one issue's gate; its approved
    # siblings stand, so only the reopened issue is asked again.
    it "asks again only about an issue whose plan changed since the wave was approved" do
      asking("approve").submit("issue_plan", wave: 2)
      home.issue("c").write("the prose for c, revised\n")
      screen = StringIO.new

      said = asking("approve", output: screen).submit("issue_plan", wave: 2)

      expect(screen.string).to include('"the c issue"')
      expect(screen.string).not_to include('"the b issue"')
      expect(said.text).to include("already approved b", "approved c #{plan_digest("c")}")
    end

    it "marks the issue an edit reopened in the question it is asked again" do
      asking("approve").submit("issue_plan", wave: 2)
      home.issue("c").write("the prose for c, revised\n")
      screen = StringIO.new

      asking("approve", output: screen).submit("issue_plan", wave: 2)

      expect(screen.string).to match(/issue c [^\n]*\(reopened by an edit\)/)
    end

    it "names, in the next wave's question, an issue an edit reopened in another wave" do
      asking("approve").submit("issue_plan", wave: 1)
      home.issue("a").write("the prose for a, revised\n")
      screen = StringIO.new

      asking("approve", output: screen).submit("issue_plan", wave: 2)

      expect(screen.string).to include("also reopened by an edit, in another wave: a")
    end

    it "says nothing of an edit when no approved plan changed" do
      screen = StringIO.new

      asking("approve", output: screen).submit("issue_plan", wave: 2)

      expect(screen.string).not_to include("reopened by an edit")
    end

    it "keeps the review lines in what a parked wave leaves for the queue, one question per issue" do
      read = %w[b c d].to_h { [_1, plan_digest(_1)] }
      findings = "## cluster 1 of 1 -- wave 2\n\nMUST-FIX:\n- none\nMINOR:\n- none\nVERDICT: approve"
      review = Lain::Epic::ReviewResult.parse(findings, epic_slug: "alpha", stage: "issue_plan", read:, clusters: 1,
                                                        critics: 1)

      command(gates: hands_off.merge("issue_plan" => "deferred")).submit("issue_plan", wave: 2, review:)

      waits = session_records.select { |record| record["type"] == "awaiting_human" }
      expect(waits.map { |record| record["summary"] }).to all(include(review.id))
      expect(waits.size).to eq(3)
    end

    it "reaches the wave path from `lain epic submit --wave`" do
      load File.expand_path("../../../exe/lain", __dir__) unless defined?(LainCLI)
      gates = Lain::Epic::STAGES.map { |stage| "  gate :#{stage}, :hands_off\n" }.join
      write_config(root, "epics home: :xdg do\n#{gates}end\n", paths:)
      submitting = lambda do
        with_env("XDG_STATE_HOME" => state_home, "HOME" => state_home) do
          Dir.chdir(root) { LainCLI.start(%w[epic submit issue_plan alpha --wave 2], debug: true) }
        end
      end

      expect(&submitting).to output(/wave 2.*approved b.*approved c.*approved d/m).to_stdout
      expect(submitted_decisions.map { |record| record["issue_id"] }).to eq(%w[b c d])
    end

    it "refuses a wave number that is not a whole number from `lain epic submit --wave`" do
      load File.expand_path("../../../exe/lain", __dir__) unless defined?(LainCLI)
      gates = Lain::Epic::STAGES.map { |stage| "  gate :#{stage}, :hands_off\n" }.join
      write_config(root, "epics home: :xdg do\n#{gates}end\n", paths:)

      expect do
        with_env("XDG_STATE_HOME" => state_home, "HOME" => state_home) do
          Dir.chdir(root) { LainCLI.start(%w[epic submit issue_plan alpha --wave 1.5], debug: true) }
        end
      end.to raise_error(Thor::Error, /no wave 1\.5/)
      expect(submitted_decisions).to be_empty
    end

    # The re-asked wave holds only the issues still pending, so a standing
    # issue named in a deny is not a typo, and is not said to be one.
    it "says an issue whose approval stands was not asked this time, rather than not in the wave" do
      asking("approve").submit("issue_plan", wave: 2)
      home.issue("c").write("the prose for c, revised\n")

      screen = StringIO.new
      asking("deny b: x", "approve", output: screen).submit("issue_plan", wave: 2)

      expect(screen.string).to include("b is in wave 2 but was not asked this time: its approval stands")
      expect(screen.string).not_to include("b is not in wave 2")
      expect(command.ensure_plan_approved!("b")).to eq(plan_digest("b"))
    end

    it "lists the siblings whose approval stands when a re-asked wave is held" do
      asking("approve").submit("issue_plan", wave: 2)
      home.issue("c").write("the prose for c, revised\n")

      held = asking("hold").submit("issue_plan", wave: 2)

      expect(held.text).to include("already approved b", "already approved d")
    end

    it "refuses a wave the epic does not have" do
      expect { command.submit("issue_plan", wave: 3) }.to raise_error(Lain::Error, /wave 3.*2 waves/)
    end

    it "refuses a wave named beside an issue" do
      expect { command.submit("issue_plan", issue: "b", wave: 2) }.to raise_error(Lain::Error, /issue or a wave/)
    end

    it "refuses a wave for a stage other than issue_plan" do
      expect { command.submit("research", wave: 2) }.to raise_error(Lain::Error, /issue_plan/)
    end
  end

  # Scenario: a deferred submit parks and does not advance
  describe "a deferred submit" do
    before do
      write_research
      write_epic
      session("started.ndjson", *approvals("research"), stage_event("epic_plan"))
    end

    # Asserted on the DEFERRAL's own rendering, not on tokens it shares with a
    # plain denial. The first pass matched only the digest, the stage and the
    # slug -- all three of which the denied branch prints too, so deleting the
    # deferral rendering entirely left the suite green.
    it "prints the parked digest and the stage it is parked in" do
      said = command(gates: hands_off.merge("epic_plan" => "deferred")).submit("epic_plan").text

      expect(said).to start_with("deferred #{epic_plan_digest}")
      expect(said).to include("parked in alpha/epic_plan", "lain epic queue alpha")
    end

    it "advances nothing" do
      command(gates: hands_off.merge("epic_plan" => "deferred")).submit("epic_plan")

      expect(stage_events).to eq([%w[epic_plan started]])
      expect(progress.stage.name).to eq("epic_plan")
    end

    it "exits 0, because a deferral is not a failure" do
      said = command(gates: hands_off.merge("epic_plan" => "deferred")).submit("epic_plan")

      expect(said.status).to eq(0)
    end

    it "leaves the artifact parked for sign-off" do
      command(gates: hands_off.merge("epic_plan" => "deferred")).submit("epic_plan")

      expect(Lain::Epic::SignoffQueue.from_journal(session_records).drained?("alpha", "epic_plan")).to be(false)
    end
  end

  # Scenario: a submit out of order refuses
  describe "a submit across a stage boundary" do
    before do
      write_research
      write_epic
      session("parked.ndjson", decision(digest: "blake3:#{"a" * 64}", stage: "research"))
    end

    it "reports StageBlocked naming the epic and the stage still holding" do
      expect { command.submit("epic_plan") }
        .to raise_error(Lain::Epic::StageBlocked, /alpha.*epic_plan.*research/m)
    end

    it "journals nothing" do
      before_records = session_records

      expect { command.submit("epic_plan") }.to raise_error(Lain::Epic::StageBlocked)

      expect(session_records).to eq(before_records)
    end
  end

  # Drained is only the absence of a parked sign-off, which a stage nobody ever
  # submitted has too: an issue once went in flight over an epic with no
  # research or plan approval at all. A boundary opens on positive evidence.
  # The partition's newest verdict is what a stage stands on, so "already
  # approved" has to mean the same thing: a digest approved once and then
  # superseded by a denied revision is decided again when it comes back, or
  # the epic is stranded between "already approved" and "not approved".
  describe "a reverted research after a denied revision" do
    before do
      write_research("v1\n")
      write_epic
    end

    def deny_revision
      revised = Lain::Epic::Submission.research(text: "v2\n", slug: "alpha").digest
      session("zz-denied.ndjson", decision(digest: revised, stage: "research", approved: false, policy: "signoff"),
              at: Time.now.utc.iso8601(6))
    end

    it "decides the reverted research again, and then opens epic_plan" do
      command(gates: hands_off).submit("research")
      deny_revision
      expect { command.submit("epic_plan") }.to raise_error(Lain::Epic::StageBlocked, /research not approved/)

      expect(command.submit("research").text).to start_with("approved #{research_digest("v1\n")}")
      expect(command.submit("epic_plan").text).to start_with("approved")
    end
  end

  # The boundary asks whether research stands approved at the bytes on disk now,
  # so an edit after the approval shuts the next stage until research is decided again.
  describe "a research edited since its approval" do
    before do
      write_research("v1\n")
      write_epic
      command.submit("research")
    end

    it "keeps epic_plan blocked, naming research as changed since its approval" do
      write_research("v2\n")

      expect { command.submit("epic_plan") }.to raise_error(Lain::Epic::StageBlocked) { |error|
        expect(error.message)
          .to start_with('epic "alpha" cannot open its epic_plan stage -- research changed since its approval; ' \
                         "resubmit research")
      }
      expect(gate_decisions.map { _1["stage"] }).to eq(["research"])
    end

    # A standing approval's repair never reaches a policy, so the submit's own boundary check is what refuses it.
    it "refuses a standing epic_plan resubmitted after the research was edited" do
      command.submit("epic_plan")
      write_research("v2\n")

      expect { command.submit("epic_plan") }
        .to raise_error(Lain::Epic::StageBlocked, /research changed since its approval; resubmit research/)
    end

    it "opens epic_plan again once the edit is undone" do
      write_research("v2\n")
      write_research("v1\n")

      expect(command.submit("epic_plan").text).to start_with("approved")
    end

    it "refuses over a research.md removed since its approval, saying to restore it" do
      FileUtils.rm(home.research.path)

      expect { command.submit("epic_plan") }
        .to raise_error(Lain::Epic::StageBlocked, /research's file is missing; restore it, then resubmit research/)
    end
  end

  describe "a stage never approved" do
    before do
      write_research(slug: "plans")
      write_epic(slug: "plans")
      home("plans").issue("a").write("the prose for a\n")
    end

    # Scenario: a stage never approved blocks the next
    it "refuses an issue plan naming research as not approved, and journals nothing" do
      expect { command.submit("issue_plan", "plans", issue: "a") }
        .to raise_error(Lain::Epic::StageBlocked,
                        /"plans" cannot open its issue_plan stage for issue "a" -- research, epic_plan not approved/)
      expect(gate_decisions).to be_empty
    end

    it "refuses over a denied research too, since a denial is no approval" do
      session("denied.ndjson", decision(digest: research_digest(slug: "plans"), stage: "research", approved: false,
                                        policy: "hands_off", slug: "plans"))

      expect { command.submit("epic_plan", "plans") }.to raise_error(Lain::Epic::StageBlocked, /research not approved/)
    end

    # Scenario: one epic does not block another
    it "lets plans' epic_plan proceed once its research is approved, while another epic has submitted nothing" do
      write_research(slug: "other")
      write_epic(slug: "other")
      session("approved.ndjson", *approvals("research", slug: "plans"))

      expect(command.submit("epic_plan", "plans").text).to start_with("approved")
    end

    it "does not read another epic's approvals as this one's" do
      write_research(slug: "other")
      session("approved.ndjson", *epic_approved(slug: "other"))

      expect { command.submit("epic_plan", "plans") }.to raise_error(Lain::Epic::StageBlocked, /"plans".*research/)
    end
  end

  # A sign-off the fold could not read whole is a decision nobody made. Skipped,
  # a torn deferral folded the queue empty, drained opened the next stage, and
  # the stage opened over work nobody signed off.
  describe "a sign-off journal it could not read whole" do
    before do
      write_research
      write_epic
    end

    def halve_last_line(name)
      path = File.join(sessions_dir, name)
      lines = File.readlines(path)
      File.write(path, [*lines[0...-1], lines.last[0, lines.last.size / 2]].join)
    end

    # Scenario: a torn sign-off line blocks the next stage instead of opening it
    it "refuses the next stage over a halved deferral, naming the file and line, and journals nothing" do
      session("parked.ndjson", stage_event("research"), decision(digest: research_digest, stage: "research"))
      halve_last_line("parked.ndjson")

      expect { command.submit("epic_plan") }
        .to raise_error(Lain::CLI::SessionJournals::Unreadable, /parked\.ndjson.*line 2.*nothing was decided/m)
      expect(gate_decisions).to be_empty
      expect(stage_events).to eq([%w[research started]])
    end

    # Scenario: a torn line of an unrelated type does not block a gate
    it "proceeds when the only damaged line is a torn turn record" do
      File.write(File.join(sessions_dir, "chat.ndjson"),
                 %({"ts":"2026-01-01T00:00:00.000000Z","type":"turn","digest":"blake3:\n))

      said = command(gates: { "research" => "hands_off" }).submit("research").text

      expect(said).to include("approved", research_digest)
      expect(gate_decisions.map { |record| record["stage"] }).to eq(["research"])
    end

    # Scenario: a malformed but parseable gate_decision refuses by name
    it "refuses a gate_decision whose approved field is \"maybe\" in one line naming the record" do
      File.write(File.join(sessions_dir, "damaged.ndjson"),
                 "#{JSON.generate(decision(digest: research_digest, stage: "research").to_journal
                                    .merge("ts" => "2026-01-01T00:00:00Z", "verdict" => "maybe"))}\n")

      expect { command.submit("epic_plan") }.to raise_error(Lain::Error) { |error|
        expect(error).to be_a(Lain::Epic::SignoffQueue::UnreadableRecord)
        expect(error.message).to include("gate_decision", research_digest, "verdict")
        expect(error.message).not_to include("\n")
      }
      expect(stage_transitions).to be_empty
    end
  end

  # The plan check an issue's launch and `lain epic land` both ask reads the
  # approvals straight off the journals, with no sign-off fold in front of it
  # to have refused a damaged line first.
  describe "a plan check over a sign-off it could not read whole" do
    it "refuses a gate_decision whose approved field is \"maybe\" in one line naming the record" do
      write_research
      write_epic
      home.issue("a").write("the prose for a\n")
      File.write(File.join(sessions_dir, "damaged.ndjson"),
                 "#{JSON.generate(decision(digest: "blake3:damaged", stage: "issue_plan").to_journal
                                    .merge("ts" => "2026-01-01T00:00:00Z", "verdict" => "maybe"))}\n")

      expect { command.ensure_plan_approved!("a") }.to raise_error(Lain::Error) { |error|
        expect(error).to be_a(Lain::Epic::SignoffQueue::UnreadableRecord)
        expect(error.message).to include("gate_decision", "blake3:damaged", "verdict")
        expect(error.message).not_to include("\n")
      }
    end
  end

  # Scenario: an unconstructable policy refuses loudly.
  #
  # Two seams, refused on two scopes. An `adjudicated` stage in a session that
  # wired no role spawn and brief is refused for EVERY stage at wiring time --
  # the last example -- because that is a process wired wrong. A missing asker
  # is a fact about the terminal this command was run from, and this command
  # decides one stage: so it is refused, before anything is decided, only when
  # the stage being submitted is the one that would ask.
  describe "a policy this session cannot construct" do
    before do
      write_research
      write_epic
    end

    def unaskable = command(gates: hands_off.merge("epic_plan" => "interactive"), input: nil)

    # The boundary is checked before the policy is built, so epic_plan reaches
    # the asker only over an approved research.
    def research_approved = session("approved.ndjson", *approvals("research"))

    # Scenario: an unattended submit of an interactive stage refuses in words
    it "says stdin is not a terminal, naming the stage and the policies that would proceed" do
      research_approved
      expect { unaskable.submit("epic_plan") }.to raise_error(Lain::Error) { |error|
        expect(error).to be_a(Lain::Epic::Gate::Policies::Refusal)
        expect(error.kind).to eq(:missing_seam)
        expect(error.message).to match(/epic_plan.*interactive.*stdin is not a terminal/)
        expect(error.message)
          .to include("`gate :epic_plan, :hands_off`", ":deferred", "`epics` block of .lain/config.rb")
        expect(error.message).not_to include("adjudicated", "\n")
      }
    end

    # Scenario: an unattended submit of a hands-off stage proceeds
    it "decides a hands_off stage while the stages it is not submitting are left interactive" do
      said = command(gates: { "research" => "hands_off" }, input: nil).submit("research").text

      expect(said).to include("approved", research_digest)
      expect(gate_decisions.map { |record| record.values_at("stage", "policy") }).to eq([%w[research hands_off]])
    end

    # No wired path builds one, but the sentence must not depend on that: a
    # caller that hands over live streams and still no asker gets a reason.
    it "names the missing asker itself when the streams could have carried a question" do
      research_approved
      askerless = described_class.new(root:, paths:, config: config(hands_off.merge("epic_plan" => "interactive")),
                                      input: tty, output: StringIO.new, asker: nil)

      expect { askerless.submit("epic_plan") }
        .to raise_error(Lain::Epic::Gate::Policies::Refusal, /epic_plan.*but this session wired no asker, so/)
    end

    it "journals no gate_decision" do
      # The regex is the discriminator, and it is load-bearing: `Refusal` is now
      # EVERY refusal this factory makes, so a bare class match would be
      # satisfied by an unknown-policy or unknown-seam refusal too.
      research_approved
      expect { unaskable.submit("epic_plan") }
        .to raise_error(Lain::Epic::Gate::Policies::Refusal, /epic_plan.*interactive.*not a terminal/m)

      expect(gate_decisions.map { |record| record["policy"] }).to eq(["hands_off"])
    end

    # Scenario: an unattended submit meets the boundary first
    it "names the stage boundary, not stdin, when research is not approved" do
      expect { unaskable.submit("epic_plan") }.to raise_error(Lain::Epic::StageBlocked) { |error|
        expect(error.message).to include("research not approved")
        expect(error.message).not_to include("stdin")
      }
      expect(gate_decisions).to be_empty
    end

    # The CLI always wires the pair when a stage wants it; an in-process
    # caller that constructs this command without one is refused by name.
    it "refuses an adjudicated stage in a session that wired no role spawn or brief" do
      expect { command(gates: hands_off.merge("implementation" => "adjudicated")).submit("research") }
        .to raise_error(Lain::Epic::Gate::Policies::Refusal, /implementation.*adjudicated.*role_spawn, brief/m)
    end
  end

  # Scenarios: an adjudicated research gate decides and journals evidence; an
  # ambiguous artifact parks, and unadjudicated stages build no backend.
  describe "an adjudicated gate" do
    before do
      write_research
      write_epic
    end

    def adjudicating = hands_off.merge("research" => "adjudicated")
    def brief = ->(artifact) { "gather evidence on #{artifact.digest}" }

    def scripted(verdict)
      EpicSubmitSpecSupport::ScriptedRoleSpawn.new(
        evidence_researcher: "the research names its sources, its method and two open questions",
        gate_adjudicator: verdict
      )
    end

    def adjudicated(verdict)
      described_class.new(root:, paths:, config: config(adjudicating), role_spawn: scripted(verdict), brief:)
    end

    def from_options(gates, backend:)
      described_class.from_options({}, input: tty, output: StringIO.new, root:, paths:, config: config(gates),
                                       backend:)
    end

    def real_backend(*answers)
      EpicSubmitSpecSupport::FakeBackend.new(
        wire: Lain::Provider::Mock.new(responses: answers.map { |answer| text_response(answer) }),
        context: Lain::Context.new(model: "judge", max_tokens: 256), slots: Lain::Prompt::Slots.load(root:)
      )
    end

    it "decides a clear artifact, journaling the evidence and a terminal adjudicated decision" do
      said = adjudicated("APPROVE").submit("research").text

      expect(said).to start_with("approved")
      expect(session_records.map { |record| record["type"] }).to include("gate_evidence")
      expect(gate_decisions.last).to include("policy" => "adjudicated", "verdict" => "approve")
    end

    it "parks an artifact the adjudicator will not call, for a human" do
      said = adjudicated("It is one sentence -- I cannot tell whether it covers the epic.").submit("research").text

      expect(said).to start_with("deferred")
      expect(Lain::Epic::SignoffQueue.from_journal(session_records).drained?("alpha", "research")).to be(false)
    end

    it "builds its own pair from the backend flags and decides through a real spawn" do
      said = from_options(adjudicating, backend: -> { real_backend("the evidence, gathered", "APPROVE") })
             .submit("research").text

      expect(said).to start_with("approved")
      expect(gate_decisions.last).to include("policy" => "adjudicated")
    end

    # The whole exe path with only the wire faked: the flag band `epic submit`
    # declares, the profile the exe resolves under the environment, and the
    # backend the pair is really built over.
    it "carries the environment's throughput flags onto every adjudication request" do
      load File.expand_path("../../../exe/lain", __dir__) unless defined?(LainCLI)
      chat = stub_request(:post, "http://localhost:11434/api/chat")
             .to_return(status: 200, headers: { "Content-Type" => "application/x-ndjson" },
                        body: "#{JSON.generate("model" => "qwen3:4b", "done" => true, "done_reason" => "stop",
                                               "message" => { "role" => "assistant", "content" => "APPROVE" })}\n")
      options = Thor::Options.new(LainCLI::Epic.commands.fetch("submit").options).parse(%w[--provider ollama])
      profile = with_env("LAIN_NUM_BATCH" => "2048") { Lain::CLI::Exe::ModelFlags.profile(options) }

      described_class.from_options(options, profile:, input: tty, output: StringIO.new, root:, paths:,
                                            config: config(adjudicating)).submit("research")

      expect(chat).to have_been_requested.at_least_twice
      expect(a_request(:post, "http://localhost:11434/api/chat")
               .with { |req| JSON.parse(req.body).dig("options", "num_batch") != 2048 }).not_to have_been_made
    end

    # The model id stands in for a value the environment names as a secret,
    # because it is the one string every adjudication request certainly carries.
    it "refuses an adjudication request that carries a secret from the command's environment" do
      load File.expand_path("../../../exe/lain", __dir__) unless defined?(LainCLI)
      chat = stub_request(:post, "http://localhost:11434/api/chat")
      options = Thor::Options.new(LainCLI::Epic.commands.fetch("submit").options).parse(%w[--provider ollama])

      with_env("SPEC_SERVICE_TOKEN" => "qwen3:4b") do
        described_class.from_options(options, profile: Lain::CLI::Exe::ModelFlags.profile(options), input: tty,
                                              output: StringIO.new, root:, paths:, config: config(adjudicating))
                       .submit("research")
      end

      expect(chat).not_to have_been_requested
      expect(session_records.find { |record| record["type"] == "gate_evidence" }.to_json).to include("known secret")
    end

    describe "the evidence researcher's reach" do
      def reading(path)
        @wire = Lain::Provider::Mock.new(responses: [tool_response(["t1", "read_file", { "path" => path }]),
                                                     text_response("the evidence"), text_response("APPROVE")])
        EpicSubmitSpecSupport::FakeBackend.new(wire: @wire, context: Lain::Context.new(model: "judge", max_tokens: 256),
                                               slots: Lain::Prompt::Slots.load(root:))
      end

      def read_result = @wire.requests[1].messages.to_json

      it "reads its own epic's issue under epics home :xdg" do
        home("alpha").issue("a").write("PLAN-ALPHA-TEXT\n")

        from_options(adjudicating, backend: -> { reading(home("alpha").issue("a").path) }).submit("research", "alpha")

        expect(read_result).to include("PLAN-ALPHA-TEXT")
        expect(gate_evidence.fetch("text")).to eq("the evidence")
      end

      it "is outside its roots reading another epic's research" do
        write_research("OTHER-EPIC-TEXT #{research_text}", slug: "other")

        from_options(adjudicating, backend: -> { reading(home("other").research.path) }).submit("research", "alpha")

        expect(read_result).to include("was refused")
        expect(read_result).not_to include("OTHER-EPIC-TEXT")
      end

      def gate_evidence = session_records.find { |record| record["type"] == "gate_evidence" }
    end

    it "journals a failed spike's malformed_response into the decision journal" do
      prose = "Looking.\n<function=read_file>\n<parameter=path>\nepic.md\n</parameter>\n</function>\n</tool_call>"
      stub_request(:post, "http://localhost:11434/api/chat")
        .to_return(status: 200, headers: { "Content-Type" => "application/x-ndjson" },
                   body: "#{JSON.generate("model" => "qwen3:4b", "done" => true, "done_reason" => "stop",
                                          "message" => { "role" => "assistant", "content" => prose })}\n")
      load File.expand_path("../../../exe/lain", __dir__) unless defined?(LainCLI)
      options = Thor::Options.new(LainCLI::Epic.commands.fetch("submit").options).parse(%w[--provider ollama])

      described_class.from_options(options, profile: Lain::CLI::Exe::ModelFlags.profile(options), input: tty,
                                            output: StringIO.new, root:, paths:, config: config(adjudicating))
                     .submit("research")

      malformed = session_records.select { |record| record["type"] == "malformed_response" }
      expect(malformed.map { |record| record["kind"] }).to include("prose_tool_call")
      note = session_records.find { |record| record["type"] == "gate_evidence" }.fetch("reason")
      expect(note).to include("see its malformed_response journal record")
    end

    it "builds no backend when every stage is interactive" do
      interactive = Lain::Epic::STAGES.to_h { |stage| [stage, "interactive"] }

      said = from_options(interactive, backend: -> { raise "built a backend with nothing to adjudicate" })
             .submit("research").text

      expect(said).to start_with("approved")
    end
  end

  # The driver runs this command in-process, so everything it would otherwise
  # build for itself can be handed in instead.
  describe Lain::CLI::EpicSubmit::ReadBack do
    def decided(answered_by, reason)
      Lain::Epic::GateDecision.new(artifact_digest: "blake3:x", epic_slug: "alpha", stage: "research", verdict: Lain::Approval::Verdict::Deny.new,
                                   answered_by:, policy: "deferred", latency: 1.0, reason:)
    end

    def reason_after(answered_by)
      described_class.new(StringIO.new.then { Lain::Journal.new(io: _1) }, -> { [] })
                     .tap { _1.record(decided(answered_by, "judge exploded: stack")) }
                     .reason("blake3:x")
    end

    it "has no reason to show for a denial the adjudicator reached" do
      expect(reason_after("adjudicator")).to be_nil
    end

    it "has the human's reason" do
      expect(reason_after("human")).to eq("judge exploded: stack")
    end
  end

  describe "injected collaborators" do
    before do
      write_research
      write_epic
    end

    it "asks through an injected asker, with no terminal at all" do
      asker = Lain::Epic::Gate::Policy::StandingAnswer.new(Lain::Epic::Gate::Answer.approve("driver"))

      described_class.new(root:, paths:, config: config(hands_off.merge("research" => "interactive")), asker:)
                     .submit("research")

      expect(gate_decisions.last).to include("answered_by" => "driver", "verdict" => "approve")
    end

    it "journals into an injected journal, and leaves it open for its owner" do
      path = File.join(sessions_dir, "driver.ndjson")
      journal = Lain::Journal.open(path)

      described_class.new(root:, paths:, config: config(hands_off), journal:).submit("research")

      expect(journal).not_to be_closed
      expect(Lain::Journal.records(File.foreach(path), type: "gate_decision").count).to eq(1)
    ensure
      journal&.close
    end

    # Scenario: the production epic seat retires its gate's question on the live feed
    #
    # Assembled the way the chat's epic driver assembles this command: the
    # chat's own asker, writing its question through the chronicle's observer,
    # and the chronicle's RECORD journal, whose tee is the one the status feed
    # rides. Nothing between them is doubled; only the gate's window is short.
    describe "the chat's epic seat", :seam do
      let(:feed_path) { File.join(@tmp, "state.json") }
      let(:feed) { Lain::StatusFeed.new(path: feed_path) }
      let(:session_journal) { Lain::Journal.open(File.join(sessions_dir, "chat.ndjson")) }
      let(:chronicle) do
        Lain::CLI::Chronicle.new(journal: session_journal).tap do |chronicle|
          chronicle.wrap_tee(feed)
          chronicle.wrap_memory(Lain::Memory::Recorder.new)
          chronicle.start(context: Lain::Context.new(model: "m", max_tokens: 64), toolset: Lain::Toolset.new,
                          sections: SessionSections.complete)
        end
      end
      let(:asker) do
        Lain::Tools::AskHuman.new(parent: CoreGraph.timeline, observer: chronicle.observer)
      end

      after { session_journal.close }

      def inbox_count = JSON.parse(File.read(feed_path)).fetch("inbox_count")

      def seat(approval_timeout: Lain::Approval::Parked::Queue::DEFAULT_TIMEOUT,
               approval_silence: Lain::Config::DEFAULT_APPROVAL_SILENCE, stage: "research")
        described_class.new(root:, paths:, asker:, journal: chronicle.record_journal,
                            config: config(hands_off.merge(stage => "interactive"), approval_timeout:,
                                                                                    approval_silence:))
      end

      # The human's side of the gate, run beside the submit the way the chat's
      # drain runs beside the driver: it waits for the question, then acts.
      # Each reply answers the next question the gate asks.
      # A reply the gate never asks for is left unsent, and the replier stops with the submit.
      def answered_in_turn(*replies)
        Sync do |task|
          replier = task.async do
            replies.reduce(nil) do |answered, reply|
              task.yield until asker.pending? && asker.last_question.digest != answered
              asker.last_question.digest.tap { asker.reply(reply, _1) }
            end
          end
          seat(approval_timeout: 5).submit("research").text.tap { replier.stop }
        end
      end

      def submitted_while
        Sync do |task|
          task.async do
            task.yield until asker.pending?
            yield asker.last_question
          end
          seat.submit("research").text
        end
      end

      def verdicts = gate_decisions.map { |record| record.values_at("verdict", "answered_by") }

      # The cockpit's own answer gesture: <CR> on the inbox row opens
      # lain://question, the human writes beneath the gate's question, and `:w`
      # hands the parsed document to the chat's reply drain as
      # `question_answered`. What reaches the asker is the RENDERED answer set,
      # so a reading of that rendering as the human's words denied every
      # approval written this way.
      describe "an approval written in lain://question" do
        let(:rail) do
          Class.new do
            def initialize = @commands = Thread::Queue.new
            def push(command) = @commands.push(command)
            def pop(non_block) = @commands.pop(non_block)
            def attached? = true
          end.new
        end
        let(:editor) do
          Class.new do
            attr_reader :opened

            def initialize = @opened = []
            def open_question(lines, digest) = (@opened << [lines, digest]) && nil
          end.new
        end
        let(:question_view) do
          Lain::Frontend::Neovim::QuestionView.new(
            rpc: editor, submit: ->(digest, answers) { rail.push(["question_answered", [digest, answers]]) }
          )
        end
        let(:replies) do
          tty = Lain::Frontend::TTY.new(channel: Lain::Channel.new, output: StringIO.new, input: StringIO.new,
                                        history_path: File.join(@tmp, "history"))
          Lain::CLI::HumanReplies.new(tty:, conductor: nil, ask_human: asker, questions: nil).tap do |drain|
            drain.bind_editor(rail)
          end
        end

        # The document as the editor was handed it, with the human's answer
        # written beneath the question the way a comment is: indented two spaces.
        def written_and_saved(reply)
          Sync do |task|
            surfaces = replies.session_surfaces(task)
            task.async do
              task.yield until asker.pending?
              write_beneath(asker.last_question, reply)
            end
            seat.submit("research").text.tap { surfaces.each(&:stop) }
          end
        end

        # <CR> opens the set; the human writes; `:w` hands it on.
        def write_beneath(question, reply)
          expect(question_view.open(Lain::Question::Set.from_body(question.body), question.digest)).to be_nil
          expect(question_view.wrote([*editor.opened.last.first, "", "  #{reply}"], question.digest)).to be_nil
        end

        it "approves when the human writes approve and saves" do
          expect(written_and_saved("approve")).to include("approved")

          expect(verdicts).to eq([%w[approve human]])
        end

        it "denies as the human's own denial when the human writes deny and saves" do
          expect(written_and_saved("deny")).to include("denied")

          expect(verdicts).to eq([%w[deny human]])
        end
      end

      # Scenario: a reply is classified, and only a word the question names is a
      # human's verdict. Typed at `human>` or sent by `:LainReply`, the reply
      # reaches the asker as the words themselves.
      describe "a reply in words" do
        {
          "approve" => "approve", "approved" => "approve", "y" => "approve", "yes" => "approve",
          "  YES \n" => "approve", "Approve." => "approve", "approved!" => "approve",
          "deny" => "deny", "denied" => "deny", "n" => "deny", "No." => "deny"
        }.each do |reply, verdict|
          it "reads #{reply.inspect} as the human #{verdict == "approve" ? "approving" : "denying"}" do
            submitted_while { |question| asker.reply(reply, question.digest) }

            expect(verdicts).to eq([[verdict, "human"]])
          end
        end

        ["lgtm", "approve it", "approve?", "yes?"].each do |reply|
          it "asks again after #{reply.inspect}, recording no decision for it" do
            said = answered_in_turn(reply, "deny")

            expect(said).to include("denied")
            expect(verdicts).to eq([%w[deny human]])
            expect(asker.last_question.body.to_s).to include("The reply", reply)
          end
        end

        it "approves with the note after a comma" do
          expect(answered_in_turn("approve, round 2 research, re-signed unchanged")).to include("approved")

          expect(gate_decisions.map { |record| record.values_at("verdict", "answered_by", "reason") })
            .to eq([["approve", "human", "round 2 research, re-signed unchanged"]])
        end

        it "journals the words after a denial as the human's reason and shows them under denied" do
          said = submitted_while { |question| asker.reply("deny: needs a benchmark first", question.digest) }

          expect(said).to start_with("denied")
          expect(said).to include("needs a benchmark first")
          expect(verdicts).to eq([%w[deny human]])
          expect(gate_decisions.first["reason"]).to eq("needs a benchmark first")
        end

        it "carries a long numbered reason whole, every line indented under reason:" do
          lines = Array.new(4) { |i| "#{i + 1}. #{"x" * 170}" }
          said = submitted_while { |question| asker.reply("deny: #{lines.join("\n")}", question.digest) }

          expect(said).to include("  reason: #{lines.first}", *lines.drop(1).map { |line| "    #{line}" })
        end

        it "indents a reason line that reads like a verdict so it cannot pose as one" do
          said = submitted_while { |question| asker.reply("deny: no\napproved blake3:abc", question.digest) }

          expect(said.lines.grep(/\Aapproved/)).to be_empty
          expect(said).to include("\n    approved blake3:abc")
        end

        # Scenario: hold stops the agent until the human speaks
        it "journals a hold as a hold, not a denial, and says it held with the human's note" do
          said = submitted_while { |question| asker.reply("hold, I'll run the review myself", question.digest) }

          expect(said).to start_with("held").and include("I'll run the review myself", "nothing advanced")
          expect(said).not_to include("denied")
          expect(verdicts).to eq([%w[hold human]])
          expect(gate_decisions.first["reason"]).to eq("I'll run the review myself")
        end

        # Scenario: end of input is not a human's answer
        it "records end of input at the reply prompt as eof" do
          submitted_while { |question| asker.reply(Lain::Tools::AskHuman::Unanswered.new, question.digest) }

          expect(verdicts).to eq([%w[deny eof]])
        end
      end

      it "waits 300 seconds for a chat's answer when the project sets no approval timeout" do
        allow(Lain::Epic::Gate).to receive(:new).and_call_original

        submitted_while { |question| asker.reply("approve", question.digest) }

        expect(Lain::Epic::Gate).to have_received(:new).with(hash_including(timeout: 300))
      end

      def unanswered_in_chat(approval_silence)
        stub_chronicle = instance_double(Lain::CLI::Chronicle, journal_path: File.join(sessions_dir, "chat.ndjson"))
        Sync do
          described_class::InChat.new(chronicle: stub_chronicle,
                                      command: seat(approval_timeout: 0.2, approval_silence:))
                                 .submit("research", "alpha")
        end
      end

      # Scenario: an unanswered gate hands the agent a next step and waits
      it "hands the chat's agent the resubmit and the wait when the window closes unanswered under deny" do
        result = unanswered_in_chat(:deny)

        expect(result.ends_turn).to be(true)
        expect(result.content).to include("did not answer", "0.2 seconds", "epic_submit again", "research",
                                          "has not advanced", "tell the user")
        expect(result.content).not_to include("lain epic submit")
      end

      it "tells the chat's agent a held gate waits on the user before any resubmit, under hold" do
        result = unanswered_in_chat(:hold)

        expect(result.ends_turn).to be(true)
        expect(result.content).to include("did not answer", "0.2 seconds",
                                          "It is held: tell the user, and call epic_submit again only when they ask")
        expect(result.content).not_to include("lain epic status", "do not re-submit")
        expect(result.content).not_to include("epic_submit again with", "reopen the gate")
      end

      # Scenario: a silent wave gate holds each issue
      describe "a wave nobody answers" do
        let(:ids) { (1..9).map { "i#{_1}" } }

        before do
          home.write_epic(Lain::Epic::Graph.new(issues: [issue("a", blocks: ids), *ids.map { issue(_1) }]))
          write_research
          session("started.ndjson", *epic_approved, stage_event("issue_plan"))
          ["a", *ids].each { |id| home.issue(id).write("the prose for #{id}\n") }
        end

        def silent_wave(approval_silence)
          Sync do
            seat(approval_timeout: 0.2, approval_silence:, stage: "issue_plan").submit("issue_plan", wave: 2)
          end
        end

        def wave_verdicts = submitted_decisions.map { _1.values_at("issue_id", "verdict", "reason") }

        it "holds all 9 issues when the project leaves silence unset, and reports them unsettled" do
          said = silent_wave(Lain::Config::DEFAULT_APPROVAL_SILENCE)

          expect(wave_verdicts).to eq(ids.map { [_1, "hold", "no answer within 0.2s"] })
          expect(said.text).to include("unanswered wave 2 of epic alpha", "held for the human")
          expect(said.wait).to include("It is held: tell the user, and call epic_submit again only when they ask")
          expect(said.wait).not_to include("lain epic status")
          expect(said.wait).not_to include("reopen the gate")
        end

        it "denies all 9 with the word timeout when the project chooses deny, and says how to reopen" do
          said = silent_wave(:deny)

          expect(wave_verdicts).to eq(ids.map { [_1, "deny", "timeout"] })
          expect(said.wait).to include("To reopen the gate", "epic_submit again")
        end
      end

      it "counts the gate's question while it waits and none once its window closes" do
        while_waiting = nil

        said = Sync do |task|
          task.async do
            task.yield until asker.pending?
            while_waiting = inbox_count
          end
          seat(approval_timeout: 0.2).submit("research").text
        end

        expect(said).to include("nobody answered", "nothing advanced")
        expect(while_waiting).to eq(1)
        expect(inbox_count).to eq(0)
      end
    end
  end

  # What a chat's epic_submit tool decides through: the chat's own journal,
  # lent, or a refusal when the chat keeps none.
  describe ".in_chat" do
    before { write_research }

    def in_chat(chronicle)
      described_class.in_chat(chronicle:, root:, paths:, config: config(hands_off), asker: nil, role_spawn: nil)
    end

    it "decides into the chronicle's own record journal, lent and left open" do
      io = StringIO.new
      chronicle = Lain::CLI::Chronicle.new(journal: Lain::Journal.new(io:),
                                           journal_path: File.join(sessions_dir, "chat.ndjson"))

      in_chat(chronicle).submit("research", "alpha")

      expect(journal_records(io, "gate_decision").count).to eq(1)
      expect(gate_decisions).to be_empty
      expect(chronicle.record_journal).not_to be_closed
    end

    # A --btw session's file is reaped at close, and the decision with it.
    it "refuses in an ephemeral session until it is kept, naming --btw and /keep" do
      chronicle = Lain::CLI::Chronicle.for(enabled: true, btw: true, paths:, root: Dir.pwd)
      submitter = in_chat(chronicle)

      expect { submitter.submit("research", "alpha") }.to raise_error(Lain::Error, %r{--btw.*/keep}m)
      chronicle.promote!
      expect(submitter.submit("research", "alpha")).to have_attributes(ends_turn: false)
        .and(have_attributes(text: start_with("approved")))
    ensure
      chronicle&.close
    end

    it "refuses under --no-journal, naming the flag, and journals nothing" do
      expect { in_chat(Lain::CLI::Chronicle::Null.new).submit("research", "alpha") }
        .to raise_error(Lain::Error, /--no-journal/)
      expect(gate_decisions).to be_empty
    end
  end

  describe "an epic named in a home that holds none" do
    it "says the home holds no epics" do
      expect { command.submit("research", "ghost") }.to raise_error(Lain::Error, /holds no epics/)
    end
  end

  # Re-submitting a digest that already carries an approval: a second decision
  # could only add a record nobody asked for.
  describe "a re-submit of an already-approved artifact" do
    before do
      write_research
      write_epic
      session("approved.ndjson", decision(digest: research_digest, stage: "research", approved: true,
                                          policy: "hands_off"))
    end

    it "says so and decides nothing" do
      said = command(gates: { "research" => "hands_off" }).submit("research").text

      expect(said).to include("already approved", research_digest)
      expect(gate_decisions.size).to eq(1)
    end

    # Scenario: a standing approval with no transition is repaired. An approval
    # whose process died, or whose surface never advanced the epic, left the
    # epic reading research; re-submitting is how the operator repairs it.
    it "repairs an approval that never advanced the epic" do
      said = command(gates: { "research" => "hands_off" }).submit("research").text

      expect(said).to include("already approved", "research completed, epic_plan started")
      expect(stage_events).to eq([%w[research completed], %w[epic_plan started]])
      expect(progress.stage.name).to eq("epic_plan")
    end

    it "writes the repair once, however often the approval is re-submitted" do
      2.times { command(gates: { "research" => "hands_off" }).submit("research") }

      expect(stage_events).to eq([%w[research completed], %w[epic_plan started]])
    end

    # The repair advances the epic, so it meets the boundary a verdict meets:
    # a research denied since withdraws what epic_plan's approval stood on.
    it "refuses to repair epic_plan over a research denied since, journaling no transition" do
      session("plan-approved.ndjson", decision(digest: epic_plan_digest, stage: "epic_plan", approved: true,
                                               policy: "hands_off"), at: "2026-01-01T00:00:01Z")
      session("research-denied.ndjson", decision(digest: research_digest("v2\n"), stage: "research",
                                                 policy: "signoff"), at: "2026-01-01T00:00:02Z")

      expect { command.submit("epic_plan") }.to raise_error(Lain::Epic::StageBlocked, /research not approved/)
      expect(stage_events).to be_empty
    end

    it "journals no further stage transition over an approval that already advanced the epic" do
      session("advanced.ndjson", stage_event("research", event: "completed"), stage_event("epic_plan"),
              at: "2026-01-01T00:00:01Z")

      said = command(gates: { "research" => "hands_off" }).submit("research").text

      expect(said).to include("nothing moved")
      expect(stage_events).to eq([%w[research completed], %w[epic_plan started]])
    end
  end

  # ONE instance, submitted twice. The journals were memoized, so a reused
  # command folded the world as it was BEFORE its own first decision and
  # cheerfully approved the same artifact again -- two `gate_decision` records
  # and two rounds of stage transitions. The add-only registry cannot be the
  # only thing standing between a user and a duplicate verdict, and "exe/lain
  # builds a fresh object per process" is not a property of this class.
  it "re-reads the journals, so one instance cannot decide the same artifact twice" do
    write_research
    write_epic
    reused = command(gates: { "research" => "hands_off" })

    reused.submit("research")
    said = reused.submit("research").text

    expect(said).to include("already approved")
    expect(gate_decisions.size).to eq(1)
    expect(stage_events).to eq([%w[research completed], %w[epic_plan started]])
  end

  describe "an abbreviated implementation digest", :seam do
    before do
      write_epic
      write_research
      session("started.ndjson", *epic_approved, stage_event("issue_plan"))
      home.issue("a").write("the prose for a\n")
      command.submit("issue_plan", issue: "a")
    end

    # Two commits whose ids share a 4-hex prefix, found by hashing candidate
    # bodies in Ruby and writing only the pair.
    def colliding_prefix
      tree = SeedRepo.git(root, "mktree").stdout.strip
      seen = {}
      (0..).each do |n|
        body = "tree #{tree}\nauthor t <t@example.com> 0 +0000\ncommitter t <t@example.com> 0 +0000\n\nc#{n}\n"
        sha = Digest::SHA1.hexdigest("commit #{body.bytesize}\0#{body}")
        seen[sha[0, 4]] ||= []
        seen[sha[0, 4]] << body
        return seen[sha[0, 4]] if seen[sha[0, 4]].size == 2
      end
    end

    it "submits the full sha of the commit a unique prefix names" do
      full = command.submit("implementation", issue: "a", digest: commit_sha)
      abbreviated = command.submit("implementation", issue: "a", digest: commit_sha[0, 7])

      expect(abbreviated.text).to start_with("already approved #{full.text[/blake3:\h+/]}")
    end

    it "refuses a prefix that matches 2 commits, saying it is ambiguous" do
      commit_sha
      bodies = colliding_prefix
      bodies.each do |body|
        SeedRepo.git(root.to_s, "hash-object", "-t", "commit", "-w", "--stdin", "--literally", input: body)
      end
      prefix = Digest::SHA1.hexdigest("commit #{bodies.first.bytesize}\0#{bodies.first}")[0, 4]

      expect { command.submit("implementation", issue: "a", digest: prefix) }
        .to raise_error(Lain::Error, /#{prefix}.*ambiguous/)
    end

    ["abc", "not-hex", "--foo", "--end-of-options"].each do |digest|
      it "refuses #{digest.inspect} as not a commit without running git" do
        commit_sha
        expect(Lain::Isolation::Checkout).not_to receive(:new)

        expect { command.submit("implementation", issue: "a", digest:) }
          .to raise_error(Lain::Error, /#{Regexp.escape(digest)}.*not a commit/)
      end
    end

    it "refuses a prefix that names no commit, by name" do
      commit_sha

      expect { command.submit("implementation", issue: "a", digest: "deadbeef") }
        .to raise_error(Lain::Error, /deadbeef.*not a commit/)
    end
  end

  # The interactive asker: a y/n prompt on the INJECTED streams. Nothing here
  # may touch $stdout -- the `Lain/TerminalOutput` cop parses lib/ for that
  # -- so the question is written to the stream the command was handed.
  describe "the TTY prompt" do
    before do
      write_research
      write_epic
    end

    def tip = commit_sha

    it "writes what the tip's tests did into an implementation's question", :seam do
      write_research
      session("started.ndjson", *epic_approved, stage_event("issue_plan"))
      home.issue("a").write("the prose for a\n")
      command.submit("issue_plan", issue: "a")
      screen = StringIO.new
      tests = Lain::Telemetry::TestsRan.new(issue_id: "a", sha: tip, ran: true, passed: 3, errors: 1)

      command(gates: hands_off.merge("implementation" => "interactive"), output: screen)
        .submit("implementation", issue: "a", digest: tip, tests:)

      expect(screen.string).to include("(issue a, #{tip}, tests: 3 passed, 1 error)")
    end

    it "carries the tests through a chat's guarded submit", :seam do
      write_research
      session("started.ndjson", *epic_approved, stage_event("issue_plan"))
      home.issue("a").write("the prose for a\n")
      command.submit("issue_plan", issue: "a")
      screen = StringIO.new
      tests = Lain::Telemetry::TestsRan.new(issue_id: "a", sha: tip, ran: true, passed: 4)
      chronicle = instance_double(Lain::CLI::Chronicle, journal_path: File.join(sessions_dir, "chat.ndjson"))
      inner = command(gates: hands_off.merge("implementation" => "interactive"), output: screen)

      described_class::InChat.new(chronicle:, command: inner)
                             .submit("implementation", issue: "a", digest: tip, tests:)

      expect(screen.string).to include("(issue a, #{tip}, tests: 4 passed)")
    end

    it "says nothing ran for a hand submit given no tests", :seam do
      write_research
      session("started.ndjson", *epic_approved, stage_event("issue_plan"))
      home.issue("a").write("the prose for a\n")
      command.submit("issue_plan", issue: "a")
      screen = StringIO.new

      command(gates: hands_off.merge("implementation" => "interactive"), output: screen)
        .submit("implementation", issue: "a", digest: tip)

      expect(screen.string).to include("tests: not run")
    end

    it "writes the artifact's own question to the injected output" do
      screen = StringIO.new

      command(gates: hands_off.merge("research" => "interactive"), output: screen).submit("research")

      expect(screen.string).to include("Approve the research stage", "alpha")
    end

    it "denies on anything but an affirmative reply, and advances nothing" do
      said = command(gates: hands_off.merge("research" => "interactive"), input: tty("n\n")).submit("research").text

      expect(said).to include("denied")
      expect(stage_transitions).to be_empty
      expect(gate_decisions.map { |record| record["verdict"] }).to eq(["deny"])
    end

    it "exits 1 on a denial and 0 on an approval" do
      denied = command(gates: hands_off.merge("research" => "interactive"), input: tty("n\n")).submit("research")
      approved = command(gates: hands_off.merge("research" => "interactive"), input: tty("y\n")).submit("research")

      expect([denied.status, approved.status]).to eq([1, 0])
    end

    it "exits 1 on a hold typed at the terminal, which advanced nothing" do
      held = command(gates: hands_off.merge("research" => "interactive"), input: tty("hold\n")).submit("research")

      expect([held.status, held.text]).to match([1, start_with("held")])
      expect(stage_transitions).to be_empty
    end

    it "prints denied, not parked, when a human denies over an earlier deferral of the same digest" do
      session("parked.ndjson", decision(digest: research_digest, stage: "research"))

      said = command(gates: hands_off.merge("research" => "interactive"), input: tty("n\n")).submit("research").text

      expect(said).to start_with("denied")
      expect(said).not_to include("parked")
      queue = Lain::Epic::SignoffQueue.from_journal(session_records)
      expect(queue.parked("alpha", "research")).to be_empty
    end

    # An asker that cannot speak is not an asker. A TTY input with nowhere to
    # write the question used to reach `nil.write` from inside the reactor --
    # a NoMethodError, not a {Lain::Error}, so it escaped `exe/lain`'s rescue
    # and printed a backtrace at a user standing at a half-answered gate.
    it "refuses a half-wired terminal as a missing seam, not a NoMethodError" do
      expect { command(gates: hands_off.merge("research" => "interactive"), output: nil).submit("research") }
        .to raise_error(Lain::Epic::Gate::Policies::Refusal, /research.*interactive.*nowhere to write/m)
    end

    it "asks again after an unrecognised reply, and records only the reply that decided" do
      screen = StringIO.new
      said = command(gates: hands_off.merge("research" => "interactive"), input: tty("maybe\n", "n\n"),
                     output: screen).submit("research").text

      expect(said).to include("denied")
      expect(screen.string).to include('The reply "maybe" decides nothing')
      expect(gate_decisions.map { |record| record.values_at("verdict", "answered_by") }).to eq([%w[deny human]])
    end

    # Scenario: end of input is not a human's answer
    it "fails closed on end of input, and records nobody's answer as eof" do
      said = command(gates: hands_off.merge("research" => "interactive"), input: tty(nil)).submit("research").text

      expect(said).to include("denied")
      expect(gate_decisions.map { |record| record.values_at("verdict", "answered_by") }).to eq([%w[deny eof]])
    end

    # Scenario: latency is measured from the question's write, not from
    # before it. {Prompt#ask} used to resolve synchronously, so
    # {Epic::Gate#await}'s clock only ever started after a human had
    # already answered -- every journaled latency read as instant no matter
    # how long the read actually took.
    it "measures at least as long as the terminal read actually takes" do
      slow = instance_double(IO, tty?: true)
      allow(slow).to receive(:gets) do
        sleep 0.2
        "y\n"
      end

      command(gates: hands_off.merge("research" => "interactive"), input: slow).submit("research")

      expect(gate_decisions.first["latency"]).to be >= 0.2
    end

    # A bounded gate would deny with `answered_by: "timeout"` before the human
    # ever got to type, once the read outlasts the project's approval timeout.
    it "keeps no timeout: a read that outlasts the approval timeout still answers" do
      slow = instance_double(IO, tty?: true)
      allow(slow).to receive(:gets) do
        sleep 0.2
        "y\n"
      end

      said = command(gates: hands_off.merge("research" => "interactive"), input: slow, approval_timeout: 0.05)
             .submit("research").text

      expect(said).to include("approved")
      expect(gate_decisions.map { |record| record["answered_by"] }).to eq(["human"])
    end

    # Real reactor cancellation, the way a SIGINT reaches the CLI: `Async` turns
    # it into a stop of every task, which can land while the prompt's bytes are
    # already out but the write has not returned.
    it "journals the fail-closed decision for a stop landing while the prompt is being drawn" do
      slow = StringIO.new
      slow.define_singleton_method(:write) { |*| sleep 0.2 }
      io = StringIO.new
      gate = Lain::Epic::Gate.new(journal: Lain::Journal.new(io:), timeout: Lain::Epic::Gate::Window::Unbounded)
      prompt = described_class::Prompt.new(input: IO.pipe.first, output: slow)
      artifact = Lain::Epic::Submission.research(text: research_text, slug: "alpha")

      Sync do |task|
        asking = task.async { gate.call(artifact, asker: prompt, stage: "research", epic_slug: "alpha") }
        sleep 0.05
        asking.stop
      end

      decisions = journal_records(io, "gate_decision").to_a
      expect(decisions.map { |record| record.values_at("verdict", "answered_by") }).to eq([%w[deny interrupted]])
    end
  end

  # Ctrl-C at an unanswered prompt unwinds the whole reactor before the plain
  # `Interrupt` the human sent re-emerges outside {Epic::Gate}'s own Sync
  # boundary -- see that class's own `Async::Cancel` handling, which journals
  # the fail-closed refusal before letting the cancellation through.
  # {Verdict#call} is where the boundary this command owns sits, so this
  # drives it directly with a policy that raises the same way, rather than
  # fighting a real terminal and a real signal inside an example -- RSpec
  # traps SIGINT for its own graceful shutdown, so a self-sent one here would
  # be caught by the RUNNER, not by this class.
  describe Lain::CLI::EpicSubmit::Verdict do
    # NOT translated. {Epic::Gate} has already journaled the fail-closed
    # decision by the time this `Interrupt` reaches here -- see that class's
    # own `Async::Cancel` handling -- so `Verdict#call` lets it climb bare,
    # the same `Interrupt` every other command's `render` meets and turns
    # into "interrupted", exit 130. A `StandardError` in its place would be
    # swallowed by the epic driver's own `rescue StandardError` around one
    # issue's settle, reporting a live run's Ctrl-C as an ordinary refusal
    # while the run kept going.
    it "lets a real Interrupt climb untouched, never turning it into a StandardError" do
      policy = Object.new
      policy.define_singleton_method(:decide) { |*| raise Interrupt }
      submission = Lain::Epic::Submission.research(text: research_text, slug: "alpha")
      verdict = described_class.new(submission:, stage: Lain::Epic::Stage.new("research"), policy:, gate: nil,
                                    queue: nil, advance: nil, journal: nil)

      expect { verdict.call }.to raise_error(Interrupt)
    end

    it "says a 1-second window in the singular" do
      policy = Object.new
      policy.define_singleton_method(:decide) { |*| false }
      journal = Object.new
      journal.define_singleton_method(:expired) { |_digest| 1 }
      journal.define_singleton_method(:held?) { |_digest| false }
      submission = Lain::Epic::Submission.research(text: research_text, slug: "alpha")
      verdict = described_class.new(submission:, stage: Lain::Epic::Stage.new("research"), policy:, gate: nil,
                                    queue: nil, advance: nil, journal:)

      expect(verdict.call.text).to include("within 1 second --")
    end

    it "exits 1 when the window closed unanswered" do
      policy = Object.new
      policy.define_singleton_method(:decide) { |*| false }
      journal = Object.new
      journal.define_singleton_method(:expired) { |_digest| 5 }
      journal.define_singleton_method(:held?) { |_digest| false }
      submission = Lain::Epic::Submission.research(text: research_text, slug: "alpha")
      verdict = described_class.new(submission:, stage: Lain::Epic::Stage.new("research"), policy:, gate: nil,
                                    queue: nil, advance: nil, journal:)
      expect(verdict.call.status).to eq(1)
    end
  end

  # A REAL Ctrl-C through a REAL `lain epic submit`, in its own PROCESS: a PTY
  # so the child has a real controlling terminal (`Prompt.on` refuses without
  # one) and a real line discipline (^C on the master is what actually sends
  # SIGINT to the child's foreground process group -- the same delivery path
  # an operator's terminal uses, and the one no in-process trick reproduces).
  # `Epic::Gate` journals the fail-closed decision from its own
  # `Async::Cancel` handling, and the plain `Interrupt` that re-emerges once
  # the child's reactor unwinds is what `render`'s own Ctrl-C rescue turns
  # into "interrupted", exit 130 -- pinning that neither half of that
  # contract silently drops the other.
  describe "Ctrl-C through the real CLI", :seam do
    # Bounded by the child living, not by a clock of its own: a slow boot under
    # load is not a regression, and a child that exits or hangs before asking is
    # caught by EOF on the reader and by the suite watchdog respectively. `screen`
    # grows from a background reader so this poll never blocks on the child.
    def await_prompt(screen, mutex, reader)
      sleep 0.02 until mutex.synchronize { screen.include?(described_class::Prompt::CUE) } || !reader.alive?
      mutex.synchronize { screen.include?(described_class::Prompt::CUE) }
    end

    describe "waiting for the prompt" do
      let(:mutex) { Mutex.new }

      it "finds the prompt after other output arrives late" do
        screen = +"gem-ctags_plugin.rb: cannot load such file\n"
        reader = Thread.new do
          sleep 0.1
          mutex.synchronize { screen << described_class::Prompt::CUE }
        end

        expect(await_prompt(screen, mutex, reader)).to be(true)
      end

      it "gives up when the child's output ends without the prompt" do
        screen = +"gem-ctags_plugin.rb: cannot load such file\n"
        reader = Thread.new { nil }

        expect(await_prompt(screen, mutex, reader)).to be(false)
      end
    end

    it "exits 130, with the fail-closed decision already journaled",
       starvable: "boots a bundled ruby child that a loaded box can starve before it prompts" do
      write_research
      write_epic
      write_config(root, <<~RUBY, paths:)
        epics home: :xdg do
          gate :research, :interactive
        end
      RUBY

      exe = File.expand_path("../../../exe/lain", __dir__)
      gemfile = File.expand_path("../../../Gemfile", __dir__)
      env = { "XDG_STATE_HOME" => state_home, "BUNDLE_GEMFILE" => gemfile }
      cmd = ["bundle", "exec", "ruby", "-W0", exe, "epic", "submit", "research", "alpha"]

      screen = +""
      mutex = Mutex.new
      status = nil
      PTY.spawn(env, *cmd, chdir: root) do |out, inp, pid|
        # The lock guards only the BUFFER APPEND, never the blocking read
        # itself -- holding it across `readpartial` would starve every poller
        # until the child next wrote a byte, which is the one moment nothing
        # is available to read at all while the prompt is still being waited
        # for.
        reader = Thread.new do
          loop do
            chunk = out.readpartial(4096)
            mutex.synchronize { screen << chunk }
          end
        rescue EOFError, Errno::EIO
          nil
        end

        raise "child never reached the gate's prompt; got: #{mutex.synchronize { screen }.inspect}" \
          unless await_prompt(screen, mutex, reader)

        inp.write("\x03")
        _, status = Process.wait2(pid)
        reader.join(2)
      end

      paths = Lain::Paths.new(env: SpecHome.env({ "XDG_STATE_HOME" => state_home }))
      written_to = paths.filing_dir(root:)
      written = Dir.children(written_to).select { |name| name.end_with?(".ndjson") }
                   .flat_map { |name| Lain::Journal.records(File.foreach(File.join(written_to, name))).to_a }
      decisions = written.select { |record| record["type"] == "gate_decision" }

      expect(status.exitstatus).to eq(130)
      expect(screen).to include("interrupted")
      expect(decisions.map { |record| record.values_at("verdict", "answered_by") }).to eq([%w[deny interrupted]])
    end
  end

  # Which epic a bare `lain epic submit STAGE` means. It must be the SAME
  # question `lain epic status` answers, or the two commands report on
  # different work without either of them raising.
  describe "choosing the epic" do
    it "resolves the sole epic in the home when no slug is given" do
      write_research
      write_epic

      expect(command.submit("research").text).to include("alpha")
    end

    # The remedy names THIS command, not the report: a human who typed
    # `lain epic submit research` and is told to run `lain epic status SLUG`
    # has been advised to do something other than what they were doing.
    it "refuses when the home holds more than one epic, advising the submit spelling" do
      write_research
      write_epic
      write_research(slug: "beta")
      write_epic(slug: "beta")

      expect { command.submit("research") }
        .to raise_error(Lain::CLI::Epic::Ambiguous, /alpha.*beta.*name one: lain epic submit STAGE SLUG/m)
    end

    it "submits the named epic when one is given" do
      write_research
      write_epic
      write_research("beta's research\n", slug: "beta")
      write_epic(slug: "beta")

      said = command.submit("research", "beta").text

      expect(said).to include("beta", research_digest("beta's research\n", slug: "beta"))
    end
  end

  # Scenario: approving an issue plan approves its criteria, and editing them
  # reopens the gate. The criteria are the issue's Gherkin block in epic.md --
  # the source {Lain::Epic::Issue#criteria_digest} reads -- so that is where the
  # edit lands.
  describe "an issue plan's criteria" do
    def criteria(outcome)
      <<~GHERKIN
        ```gherkin
        Scenario: the thing works
          Given the thing
          Then #{outcome}
        ```
      GHERKIN
    end

    def graph_with(outcome)
      Lain::Epic::Graph.new(issues: [issue("a", blocks: ["b"], criteria: criteria(outcome)), issue("b")])
    end

    def criteria_digest_of(outcome) = Lain::Gherkin::Criteria.parse(criteria(outcome)).digest
    def changeset = commit_sha

    def plan_digest(outcome)
      graph = graph_with(outcome)
      view = Lain::Epic::IssueView.new(issue: graph.fetch("a"), graph:, authored: home.issue("a").read)
      Lain::Epic::Submission.issue_plan(view:, slug: "alpha", issue_id: "a").digest
    end

    before do
      home.write_epic(graph_with("it works"))
      write_research
      session("started.ndjson", *epic_approved, stage_event("issue_plan"))
      home.issue("a").write("the prose for a\n")
    end

    # An implementation's repair writes nothing, so it has no boundary to
    # meet: the epic driver re-submits one while a research revision waits.
    it "still reports an implementation already approved while a research revision is parked", :seam do
      command.submit("issue_plan", issue: "a")
      command.submit("implementation", issue: "a", digest: changeset)
      session("zz-parked.ndjson", decision(digest: research_digest("v2\n"), stage: "research"),
              at: Time.now.utc.iso8601(6))

      expect(command.submit("implementation", issue: "a", digest: changeset).text).to start_with("already approved")
    end

    it "journals the criteria the plan was approved with" do
      command.submit("issue_plan", issue: "a")

      expect(gate_decisions.last).to include("artifact_digest" => plan_digest("it works"), "issue_id" => "a",
                                             "criteria_digest" => criteria_digest_of("it works"))
    end

    it "refuses the implementation once a criterion is edited, naming the un-approved plan digest", :seam do
      command.submit("issue_plan", issue: "a")
      home.write_epic(graph_with("it works, and says so"))

      expect { command.submit("implementation", issue: "a", digest: changeset) }
        .to raise_error(described_class::PlanNotApproved, /"a".*issue_plan.*#{plan_digest("it works, and says so")}/m)
    end

    it "journals nothing when it refuses", :seam do
      command.submit("issue_plan", issue: "a")
      home.write_epic(graph_with("it works, and says so"))
      before_records = session_records

      expect { command.submit("implementation", issue: "a", digest: changeset) }
        .to raise_error(described_class::PlanNotApproved)

      expect(session_records).to eq(before_records)
    end

    # Scenario: editing the authored issue file reopens its gate
    it "refuses ensure_plan_approved! once the authored file gains a scenario, naming the gate" do
      command.submit("issue_plan", issue: "a")
      home.issue("a").write("the prose for a\n\n## Acceptance criteria\n\n```gherkin\nScenario: it also logs\n  " \
                            "Given a run\n  When it ends\n  Then it logs\n```\n")

      expect { command.ensure_plan_approved!("a") }
        .to raise_error(described_class::PlanNotApproved, /"a".*issue_plan.*#{plan_digest("it works")}/m)
    end

    it "refuses ensure_plan_approved! once a new edge blocks the issue" do
      command.submit("issue_plan", issue: "a")
      home.write_epic(Lain::Epic::Graph.new(issues: [*graph_with("it works"), issue("c", blocks: ["a"])]))

      expect { command.ensure_plan_approved!("a") }.to raise_error(described_class::PlanNotApproved, /issue_plan/)
    end

    it "passes ensure_plan_approved! for the issue as it was approved, read twice" do
      command.submit("issue_plan", issue: "a")

      expect(command.ensure_plan_approved!("a")).to eq(command.ensure_plan_approved!("a"))
    end

    # Scenario: the gate prompt shows what is judged
    it "asks an issue_plan's gate with the issue's title, blockers, scenario names and view path" do
      home.issue("b").write("## Acceptance criteria\n\n```gherkin\nScenario: b lists\n  Given a\n  Then a list\n```\n")
      screen = StringIO.new
      command(gates: hands_off.merge("issue_plan" => "interactive"), output: screen).submit("issue_plan", issue: "b")

      expect(screen.string).to include('"the b issue"', "blocked by a", '"b lists"', "lain://epic/alpha/issues/b.md")
      expect(screen.string).not_to match(/\d+ bytes/)
    end

    # Criteria are part of the epic plan's structure, so their edit is signed again there first.
    it "opens the implementation again once the edited plan is approved", :seam do
      command.submit("issue_plan", issue: "a")
      home.write_epic(graph_with("it works, and says so"))
      command.submit("epic_plan")
      command.submit("issue_plan", issue: "a")

      expect(command.submit("implementation", issue: "a", digest: changeset).text).to start_with("approved")
    end

    it "refuses an implementation for an issue whose plan was never approved", :seam do
      expect { command.submit("implementation", issue: "a", digest: changeset) }
        .to raise_error(described_class::PlanNotApproved, /lain epic submit issue_plan alpha --issue a/)
    end

    it "names the epic in the remedy for an implementation that names no issue" do
      expect { command.submit("implementation") }
        .to raise_error(Lain::Error, /lain epic submit implementation alpha --issue ISSUE_ID/)
    end

    it "names the epic in the remedy for an implementation that names no digest" do
      expect { command.submit("implementation", issue: "a") }
        .to raise_error(Lain::Error, /lain epic submit implementation alpha --issue ISSUE_ID --digest ADDRESS/)
    end

    it "refuses a plan for an issue the epic does not hold, before anything is journaled" do
      home.issue("ghost").write("prose for nothing\n")

      expect { command.submit("issue_plan", issue: "ghost") }.to raise_error(Lain::Error, /issue "ghost"/)
      expect(submitted_decisions).to be_empty
    end
  end

  # The stages whose artifact is not one of the epic's own two documents have to
  # be told WHICH issue. Refused by name rather than left to build a Submission
  # for an unnamed issue.
  describe "the issue-scoped stages" do
    before do
      write_epic
      write_research
      session("started.ndjson", *epic_approved, stage_event("issue_plan"))
    end

    it "submits the issue file written for one issue" do
      home.issue("a").write("the prose for a\n")

      said = command.submit("issue_plan", issue: "a").text

      expect(said).to include("approved", "issue_plan")
    end

    it "refuses when no issue is named" do
      expect { command.submit("issue_plan") }.to raise_error(Lain::Error, /issue_plan/)
    end

    it "refuses an implementation digest that names no commit in the repository", :seam do
      commit_sha
      missing = "e" * 40

      expect { command.submit("implementation", issue: "a", digest: missing) }
        .to raise_error(Lain::Error, /#{missing}.*not a commit/)
    end

    it "refuses a revision name or an option where a commit is wanted", :seam do
      commit_sha

      %w[HEAD --foo].each do |digest|
        expect { command.submit("implementation", issue: "a", digest:) }
          .to raise_error(Lain::Error, /#{Regexp.escape(digest)}.*not a commit/)
      end
    end

    it "refuses an implementation digest in a project that is not a repository" do
      expect { command.submit("implementation", issue: "a", digest: "blake3:#{"e" * 64}") }
        .to raise_error(Lain::Error, /not a commit/)
    end

    def seeded_on(branch)
      home.issue("a").write("the prose for a\n")
      command.submit("issue_plan", issue: "a")
      SeedRepo.git(root, "init", "-q", "-b", branch)
      commit_on_branch("chore: seed")
      SeedRepo.git(root, "checkout", "-q", "-b", "issue/a")
    end

    def commit_on_branch(subject)
      SeedRepo.git(root, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false",
                   "commit", "-q", "--allow-empty", "-m", subject)
      SeedRepo.git(root, "rev-parse", "HEAD").stdout.strip
    end

    def red_subject = Lain::Epic::RedCommit.subject("spec/a_spec.rb", "abc123")
    def implementation_stages = gate_decisions.map { |record| record["stage"] }.grep("implementation")

    it "refuses an implementation digest whose commits hold only the issue's failing tests", :seam do
      seeded_on("epic/alpha")
      red = commit_on_branch(red_subject)

      expect { command.submit("implementation", issue: "a", digest: red) }
        .to raise_error(Lain::Error, "that commit holds only a's failing tests; re-run the issue")
      expect(implementation_stages).to be_empty
    end

    it "refuses a red-only digest by its own subject when the epic branch is missing", :seam do
      seeded_on("main")
      red = commit_on_branch(red_subject)

      expect { command.submit("implementation", issue: "a", digest: red) }
        .to raise_error(Lain::Error, "that commit holds only a's failing tests; re-run the issue")
      expect(implementation_stages).to be_empty
    end

    it "approves an implementation built on top of the red commit", :seam do
      seeded_on("epic/alpha")
      commit_on_branch(red_subject)

      said = command.submit("implementation", issue: "a", digest: commit_on_branch("feat: greet")).text

      expect(said).to start_with("approved")
      expect(implementation_stages).to eq(["implementation"])
    end

    it "refuses an implementation with no changeset address" do
      expect { command.submit("implementation", issue: "a") }
        .to raise_error(Lain::Error, /implementation/)
    end
  end

  it "refuses a stage outside the pipeline" do
    write_research
    write_epic

    expect { command.submit("reserch") }.to raise_error(Lain::Epic::UnknownStage, /reserch/)
  end

  # The adjudication pair -- a role spawn and a brief -- is what an
  # `adjudicated` gate needs and nothing else does. This command builds it out
  # of chat, from the same backend flags a chat reads, and ONLY when some stage
  # is configured `adjudicated`: a session gating everything interactively never
  # constructs a provider, so it never needs a key.
  describe Lain::CLI::EpicSubmit::HomedGuard do
    subject(:guard) { described_class.new(root:) }

    def reach?(path)
      verdict = guard.guard_inputs.sensitivity.judge(path, cwd: root)
      verdict != Lain::Sensitivity::Policy::OUTSIDE_PROJECT
    end

    it "reaches the decided epic's home only for the length of the decision" do
      inside = home("alpha").research.path
      guard.within(home("alpha")) { expect(reach?(inside)).to be(true) }

      expect(reach?(inside)).to be(false)
    end

    it "gives the home back when the decision raises" do
      inside = home("alpha").research.path
      expect { guard.within(home("alpha")) { raise "boom" } }.to raise_error("boom")

      expect(reach?(inside)).to be(false)
    end
  end

  describe Lain::CLI::EpicSubmit::Adjudication do
    def interactive = Lain::Epic::STAGES.to_h { |stage| [stage, "interactive"] }
    def adjudicating = interactive.merge("research" => "adjudicated")

    def spike_backend(*answers)
      EpicSubmitSpecSupport::FakeBackend.new(
        wire: Lain::Provider::Mock.new(responses: answers.map { |answer| text_response(answer) }),
        context: Lain::Context.new(model: "judge", max_tokens: 256), slots: Lain::Prompt::Slots.load(root:)
      )
    end

    def pair(gates = adjudicating, backend: -> { spike_backend("the evidence") },
             tool_middleware: ToolRegistry::UNGUARDED, **rest)
      described_class.pair(config: config(gates), paths:, root:, backend:, tool_middleware:, **rest)
    end

    def text_of(result)
      content = result.content
      content.is_a?(String) ? content : content.filter_map { |block| block["text"] }.join("\n")
    end

    describe "built lazily" do
      it "builds no backend when no stage is adjudicated" do
        built = pair(interactive, backend: -> { raise "a backend was built for a session with nothing to adjudicate" })

        expect(built).to eq(described_class::NONE)
        expect([built.role_spawn, built.brief]).to eq([nil, nil])
      end

      it "builds its backend exactly once when any stage is adjudicated" do
        calls = 0
        pair(adjudicating, backend: -> { (calls += 1) && spike_backend("the evidence") })

        expect(calls).to eq(1)
      end
    end

    describe "the role spawn" do
      it "spawns an out-of-chat child over the backend's provider" do
        result = pair.role_spawn.call(:evidence_researcher, :fresh, "gather evidence on the research")

        expect(result).to be_ok
        expect(text_of(result)).to eq("the evidence")
      end

      it "serves the verdict role too, whose tools the same union must hold" do
        result = pair(backend: -> { spike_backend("APPROVE") }).role_spawn.call(:gate_adjudicator, :fresh, "judge it")

        expect(text_of(result)).to eq("APPROVE")
      end

      # A child spawned here gets no tool middleware from any chat, so the guard
      # its reads go through must be HANDED IN -- and the spawn seam is where a
      # guard reaches a child.
      it "hands its spawned children the tool middleware it was given" do
        guard = ->(_worker_env, **) { Lain::Middleware::Stack.new }

        expect(pair(tool_middleware: guard).role_spawn.seam.tool_middleware).to be(guard)
      end

      # Same argument as the guard, one seam member over: out of chat no
      # attachment store reaches a child unless this command hands one in, and
      # the seam's Null raises from inside the child's model phase -- where
      # {Lain::Effect::Handler::Live#run} flattens it into a tool_result, losing
      # the class and journalling nothing.
      #
      # The DIRECTORY is what is asserted, not the object: this command is not a
      # chat and has no run to share one object with, so addressing the project's
      # own container is the whole of the claim. (Where there IS one object -- a
      # chat's -- identity is asserted with `be`, in `cli/wiring_spec.rb`.)
      it "hands its spawned children the project's own attachment store, never the unwired Null" do
        store = pair.role_spawn.seam.attachments

        expect(store).not_to be(Lain::Middleware::ResolveAttachments::Unwired)
        expect(store.root).to eq(Lain::Attachment::Store.for(root:, paths:).root)
      end
    end

    # The guard is the one seam member the pair takes, and it takes it by name,
    # on EVERY path: a guard that was only required once some stage was
    # adjudicated would be missed on the night it mattered.
    describe "the tool middleware it requires" do
      it "refuses a pair built with no tool middleware, even when nothing is adjudicated" do
        expect do
          described_class.pair(config: config(interactive), paths:, root:, backend: -> { raise "built a backend" })
        end.to raise_error(ArgumentError, /tool_middleware/)
      end

      it "refuses a misspelt keyword even when nothing is adjudicated" do
        expect { pair(interactive, backend: -> { raise "built a backend" }, tool_middlewere: :guard) }
          .to raise_error(ArgumentError, /tool_middlewere/)
      end

      %i[provider context_factory parent].each do |member|
        it "takes no #{member}, which is not the pair's to be handed" do
          expect { pair(member => :smuggled) }.to raise_error(ArgumentError, /#{member}/)
        end
      end
    end

    # The researcher reads files; nothing on the gate's artifact duck maps a
    # digest to a path, so the brief is what tells the spike where to look.
    describe Lain::CLI::EpicSubmit::Adjudication::Brief do
      subject(:brief) { described_class.new(config: config(adjudicating), paths:, root:) }

      def home = Lain::Epic::Home.resolve(config: config(adjudicating), paths:, root:, slug: "demo")

      it "sends a research spike to the research document" do
        prompt = brief.call(Lain::Epic::Submission.research(text: "notes\n", slug: "demo"))

        expect(prompt).to include("research", "\"demo\"", home.research.path)
      end

      it "lists every research source, in sorted order, beside the research document" do
        home.source("tts").write("b\n")
        home.source("asr").write("a\n")
        prompt = brief.call(Lain::Epic::Submission.research(text: "notes\n", slug: "demo"))
        paths = [home.research.path, home.source("asr").path, home.source("tts").path]

        expect(paths.map { prompt.index(_1) }).to all(be_a(Integer)).and eq(paths.map { prompt.index(_1) }.sort)
      end

      it "sends an issue plan's spike to the authored issue file and to the epic that holds its criteria" do
        graph = Lain::Epic::Graph.new(issues: [issue("a")])
        view = Lain::Epic::IssueView.new(issue: graph.fetch("a"), graph:, authored: "prose\n")
        submission = Lain::Epic::Submission.issue_plan(view:, slug: "demo", issue_id: "a")

        expect(brief.call(submission)).to include("issue a", home.issue("a").path, home.epic.path)
      end

      it "names an implementation's changeset by its address, beside the issue it was built to" do
        submission = Lain::Epic::Submission.implementation(slug: "demo", issue_id: "a", digest: "blake3:change")

        expect(brief.call(submission)).to include("blake3:change", home.issue("a").path)
      end

      it "tells the spike to gather rather than judge" do
        expect(brief.call(Lain::Epic::Submission.research(text: "notes\n", slug: "demo"))).to match(/do not judge/i)
      end
    end
  end
end
