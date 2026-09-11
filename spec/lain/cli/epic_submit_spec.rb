# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

module EpicSubmitSpecSupport
  # A {Lain::Skill::RoleSpawn} stand-in scripted per role: an adjudicated gate
  # spawns the evidence spike and the verdict as two roles in one decision.
  class ScriptedRoleSpawn
    def initialize(answers)
      @answers = answers
    end

    def call(role, _context_mode, _prompt) = Lain::Tool::Result.ok(@answers.fetch(role))
  end

  # The three things the adjudication pair reads off a backend.
  FakeBackend = Data.define(:provider, :context, :slots)
end

# `lain epic submit` is the one verb that puts an epic's artifact in front of a
# gate. Everything it does is assembled from objects that already carry their
# own specs -- {Lain::Epic::Submission} addresses the artifact,
# {Lain::Approval::Gate::Policies} chooses HOW the verdict is reached,
# {Lain::Approval::Gate.from_journal} remembers what was already approved, and
# {Lain::Epic::Scribe} is the only writer of a stage transition -- so what is
# pinned here is the WIRING, and the three ways it must refuse.
#
# The refusals are the point. A submit whose policy cannot be built must fail at
# WIRING time naming the seam, not hours in; a submit that crosses a stage
# boundary with sign-offs still parked must journal nothing at all; and a
# re-submit of a digest that already carries an approval must decide nothing a
# second time, because {Approval::Gate}'s registry is add-only and a second
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

  def config(gates = {}) = Lain::Config.new(epics: Lain::Config::Epics.new(home: :xdg, gates:))

  # Every stage gated the same way, so an example that is about ONE stage does
  # not have to keep the other three buildable by hand. `for_all` resolves the
  # whole pipeline at wiring time, which is the behaviour under test in the
  # missing-seam example below -- and the reason a stage nobody is submitting
  # still has to name a policy this session can construct.
  def hands_off = Lain::Epic::STAGES.to_h { |stage| [stage, "hands_off"] }

  # A terminal a human answers. `instance_double(IO)` is what makes
  # `respond_to?(:tty?)` true without a pty, which is the one question the
  # command asks before it decides it has an asker at all.
  def tty(reply = "y\n") = instance_double(IO, tty?: true, gets: reply)

  def command(gates: hands_off, input: tty, output: StringIO.new)
    described_class.new(root:, paths:, config: config(gates), input:, output:)
  end

  def home(slug = "alpha") = Lain::Epic::Home.resolve(config:, paths:, root:, slug:)

  def research_text = "the research, such as it is\n"

  def write_research(text = research_text, slug: "alpha") = home(slug).research.write(text)
  def write_epic(slug: "alpha") = home(slug).write_epic(chain)

  def issue(id, **overrides) = Lain::Epic::Issue.new(id:, title: "the #{id} issue", **overrides)
  def chain = Lain::Epic::Graph.new(issues: [issue("a", blocks: ["b"]), issue("b")])

  def sessions_dir = paths.sessions_dir

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
  def journal_records
    Dir.children(sessions_dir).select { |name| name.end_with?(".ndjson") }.sort
       .flat_map { |name| Lain::Journal.records(File.foreach(File.join(sessions_dir, name))).to_a }
       .sort_by { |record| record["ts"].to_s }
  end

  def gate_decisions = journal_records.select { |record| record["type"] == "gate_decision" }
  def stage_transitions = journal_records.select { |record| record["type"] == "stage_transition" }
  def stage_events = stage_transitions.map { |record| [record["stage"], record["event"]] }

  def progress(slug = "alpha")
    Lain::Epic::Progress.fold(journal_records, graph: home(slug).read_epic, epic_slug: slug)
  end

  # Built through the real producers, so no fixture can drift from the wire
  # shape the live path writes.
  def decision(digest:, stage:, approved: false, policy: "deferred", slug: "alpha")
    Lain::Approval::GateDecision.new(artifact_digest: digest, epic_slug: slug, stage:, approved:,
                                     answered_by: policy, policy:, latency: 1.0)
  end

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
      said = command(gates: { "research" => "hands_off" }).submit("research")

      expect(said).to include("approved", research_digest, "research", "alpha")
    end

    it "journals one approving gate_decision under the configured policy" do
      command(gates: { "research" => "hands_off" }).submit("research")

      expect(gate_decisions.map { |record| record.values_at("approved", "policy", "stage") })
        .to eq([[true, "hands_off", "research"]])
    end

    it "completes the gated stage and starts its successor" do
      command(gates: { "research" => "hands_off" }).submit("research")

      expect(stage_events).to eq([%w[research completed], %w[epic_plan started]])
      expect(progress.stage.name).to eq("epic_plan")
    end

    # An issue's implementation is ONE issue's; approving it says nothing about
    # the epic's other issues, so it moves no epic-wide stage.
    it "moves no epic-wide stage when one issue's implementation is approved" do
      session("started.ndjson", stage_event("issue_plan"))
      home.plan("a").write("the plan for a\n")
      command.submit("issue_plan", issue: "a")

      command.submit("implementation", issue: "a", digest: "blake3:#{"f" * 64}")

      expect(stage_events).to eq([%w[issue_plan started]])
      expect(gate_decisions.map { |record| record.values_at("stage", "issue_id", "approved") })
        .to eq([["issue_plan", "a", true], ["implementation", "a", true]])
    end

    # `Bench::EpicMetrics` folds round trips on the record's `issue_id`, and an
    # epic-wide decision is the nil member of that key -- present, not absent.
    it "journals an epic-wide decision with a nil issue" do
      command(gates: { "research" => "hands_off" }).submit("research")

      expect(gate_decisions.first).to include("issue_id" => nil)
    end
  end

  # Scenarios: a parked issue does not block a sibling; approving an issue's
  # plan puts that issue in flight, and only it.
  describe "issue-scoped gates" do
    before do
      write_epic
      session("started.ndjson", stage_event("issue_plan"))
      home.plan("a").write("the plan for a\n")
      home.plan("b").write("the plan for b\n")
    end

    def deferring = command(gates: hands_off.merge("issue_plan" => "deferred"))
    def changeset = "blake3:#{"e" * 64}"
    def parked_plans = Lain::Approval::SignoffQueue.from_journal(journal_records).parked("alpha", "issue_plan")

    it "opens b's implementation gate while a's issue_plan is parked" do
      deferring.submit("issue_plan", issue: "a")
      command.submit("issue_plan", issue: "b")

      said = command.submit("implementation", issue: "b", digest: changeset)

      expect(said).to start_with("approved")
      expect(parked_plans.map(&:issue_id)).to eq(["a"])
    end

    it "still refuses a's own implementation while a's plan is parked" do
      deferring.submit("issue_plan", issue: "a")

      expect { command.submit("implementation", issue: "a", digest: changeset) }
        .to raise_error(Lain::Error, /"a".*issue_plan/m)
    end

    it "puts a in flight when a's plan is approved, leaves b pending, and takes a out of the ready set" do
      expect(progress.ready.map(&:id)).to eq(["a"])

      said = command.submit("issue_plan", issue: "a")

      expect(said).to include("issue a moved pending -> in_flight")
      expect([progress.status("a"), progress.status("b")]).to eq(%w[in_flight pending])
      expect(progress.ready.map(&:id)).not_to include("a")
    end

    it "moves an issue only once -- re-approving a revised plan for an issue in flight moves nothing" do
      command.submit("issue_plan", issue: "a")
      home.plan("a").write("the plan for a, revised\n")

      command.submit("issue_plan", issue: "a")

      expect(journal_records.count { |record| record["type"] == "issue_transition" }).to eq(1)
    end

    # A plan the adjudicator would not call parks, and a human approves it
    # from the queue -- the designed path. The driver launches only issues in
    # flight, so the queue's approval must move the issue exactly as a verdict
    # here would.
    it "puts a in flight when a's parked plan is approved from the queue" do
      deferring.submit("issue_plan", issue: "a")
      queue = Lain::CLI::EpicQueue.new(paths:, epics: Lain::CLI::Epic.new(root:, paths:, config: config(hands_off)))

      said = queue.approve(parked_plans.first.artifact_digest)

      expect(said).to include("issue a moved pending -> in_flight")
      expect([progress.status("a"), progress.status("b")]).to eq(%w[in_flight pending])
    end

    it "names the issue's own partition when its plan parks" do
      expect(deferring.submit("issue_plan", issue: "a")).to include("parked in alpha/issue_plan/a")
    end

    it "moves no epic-wide stage for one issue's plan" do
      command.submit("issue_plan", issue: "a")

      expect(stage_events).to eq([%w[issue_plan started]])
    end

    it "journals the issue on the decision and on the park" do
      deferring.submit("issue_plan", issue: "a")

      expect(gate_decisions.map { |record| record["issue_id"] }).to eq(["a"])
      expect(parked_plans.map(&:issue_id)).to eq(["a"])
    end
  end

  # Scenario: a deferred submit parks and does not advance
  describe "a deferred submit" do
    before do
      write_research
      write_epic
      session("started.ndjson", stage_event("epic_plan"))
    end

    # Asserted on the DEFERRAL's own rendering, not on tokens it shares with a
    # plain denial. The first pass matched only the digest, the stage and the
    # slug -- all three of which the denied branch prints too, so deleting the
    # deferral rendering entirely left the suite green.
    it "prints the parked digest and the stage it is parked in" do
      said = command(gates: hands_off.merge("epic_plan" => "deferred")).submit("epic_plan")

      expect(said).to start_with("deferred #{epic_plan_digest}")
      expect(said).to include("parked in alpha/epic_plan", "lain epic queue alpha")
    end

    it "advances nothing" do
      command(gates: hands_off.merge("epic_plan" => "deferred")).submit("epic_plan")

      expect(stage_events).to eq([%w[epic_plan started]])
      expect(progress.stage.name).to eq("epic_plan")
    end

    it "leaves the artifact parked for sign-off" do
      command(gates: hands_off.merge("epic_plan" => "deferred")).submit("epic_plan")

      expect(Lain::Approval::SignoffQueue.from_journal(journal_records).drained?("alpha", "epic_plan")).to be(false)
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
      before_records = journal_records

      expect { command.submit("epic_plan") }.to raise_error(Lain::Epic::StageBlocked)

      expect(journal_records).to eq(before_records)
    end
  end

  # Scenario: an unconstructable policy refuses loudly.
  #
  # The seam exercised here is the `interactive` recipe's `asker`, which a
  # session with no TTY does not have. An `adjudicated` stage in a session that
  # wired no role spawn and brief refuses the same way -- the last example --
  # and in both cases it is {Policies::MissingSeam}, raised by `for_all` at
  # WIRING time, naming the stage, the policy, and the seam.
  describe "a policy this session cannot construct" do
    before do
      write_research
      write_epic
    end

    def unaskable = command(gates: hands_off.merge("epic_plan" => "interactive"), input: nil)

    it "names the stage, the policy, and the missing seam" do
      expect { unaskable.submit("epic_plan") }
        .to raise_error(Lain::Approval::Gate::Policies::MissingSeam, /epic_plan.*interactive.*asker/m)
    end

    # Refused at wiring, so it refuses for a stage nobody is submitting too.
    it "refuses even when the stage being submitted is buildable" do
      expect { unaskable.submit("research") }
        .to raise_error(Lain::Approval::Gate::Policies::MissingSeam, /epic_plan/)
    end

    it "journals no gate_decision" do
      expect { unaskable.submit("epic_plan") }.to raise_error(Lain::Approval::Gate::Policies::MissingSeam)

      expect(gate_decisions).to be_empty
    end

    # The CLI always wires the pair when a stage wants it; an in-process
    # caller that constructs this command without one is refused by name.
    it "refuses an adjudicated stage in a session that wired no role spawn or brief" do
      expect { command(gates: hands_off.merge("implementation" => "adjudicated")).submit("research") }
        .to raise_error(Lain::Approval::Gate::Policies::MissingSeam, /implementation.*adjudicated.*role_spawn, brief/m)
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
        researcher: "the research names its sources, its method and two open questions", gate_adjudicator: verdict
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
        provider: Lain::Provider::Mock.new(responses: answers.map { |answer| text_response(answer) }),
        context: Lain::Context.new(model: "judge", max_tokens: 256), slots: Lain::Prompt::Slots.load(root:)
      )
    end

    it "decides a clear artifact, journaling the evidence and a terminal adjudicated decision" do
      said = adjudicated("APPROVE").submit("research")

      expect(said).to start_with("approved")
      expect(journal_records.map { |record| record["type"] }).to include("gate_evidence")
      expect(gate_decisions.last).to include("policy" => "adjudicated", "approved" => true)
    end

    it "parks an artifact the adjudicator will not call, for a human" do
      said = adjudicated("It is one sentence -- I cannot tell whether it covers the epic.").submit("research")

      expect(said).to start_with("deferred")
      expect(Lain::Approval::SignoffQueue.from_journal(journal_records).drained?("alpha", "research")).to be(false)
    end

    it "builds its own pair from the backend flags and decides through a real spawn" do
      said = from_options(adjudicating, backend: -> { real_backend("the evidence, gathered", "APPROVE") })
             .submit("research")

      expect(said).to start_with("approved")
      expect(gate_decisions.last).to include("policy" => "adjudicated")
    end

    it "builds no backend when every stage is interactive" do
      interactive = Lain::Epic::STAGES.to_h { |stage| [stage, "interactive"] }

      said = from_options(interactive, backend: -> { raise "built a backend with nothing to adjudicate" })
             .submit("research")

      expect(said).to start_with("approved")
    end
  end

  # The driver runs this command in-process, so everything it would otherwise
  # build for itself can be handed in instead.
  describe "injected collaborators" do
    before do
      write_research
      write_epic
    end

    it "asks through an injected asker, with no terminal at all" do
      asker = Lain::Approval::Gate::Policy::StandingAnswer.new(Lain::Approval::Gate::Answer.approve("driver"))

      described_class.new(root:, paths:, config: config(hands_off.merge("research" => "interactive")), asker:)
                     .submit("research")

      expect(gate_decisions.last).to include("answered_by" => "driver", "approved" => true)
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
  end

  # Re-submitting a digest that already carries an approval. The Gate's registry
  # is add-only, so a second decision could never revoke or strengthen the first
  # -- it could only add a record nobody asked for.
  describe "a re-submit of an already-approved artifact" do
    before do
      write_research
      write_epic
      session("approved.ndjson", decision(digest: research_digest, stage: "research", approved: true,
                                          policy: "hands_off"))
    end

    it "says so and decides nothing" do
      said = command(gates: { "research" => "hands_off" }).submit("research")

      expect(said).to include("already approved", research_digest)
      expect(gate_decisions.size).to eq(1)
    end

    it "journals no further stage transition" do
      command(gates: { "research" => "hands_off" }).submit("research")

      expect(stage_transitions).to be_empty
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
    said = reused.submit("research")

    expect(said).to include("already approved")
    expect(gate_decisions.size).to eq(1)
    expect(stage_events).to eq([%w[research completed], %w[epic_plan started]])
  end

  # The interactive asker: a y/n prompt on the INJECTED streams. Nothing here
  # may touch $stdout -- `spec/output_discipline_spec.rb` parses lib/ for that
  # -- so the question is written to the stream the command was handed.
  describe "the TTY prompt" do
    before do
      write_research
      write_epic
    end

    it "writes the artifact's own question to the injected output" do
      screen = StringIO.new

      command(gates: hands_off.merge("research" => "interactive"), output: screen).submit("research")

      expect(screen.string).to include("Approve the research stage", "alpha")
    end

    it "denies on anything but an affirmative reply, and advances nothing" do
      said = command(gates: hands_off.merge("research" => "interactive"), input: tty("n\n")).submit("research")

      expect(said).to include("denied")
      expect(stage_transitions).to be_empty
      expect(gate_decisions.map { |record| record["approved"] }).to eq([false])
    end

    # An asker that cannot speak is not an asker. A TTY input with nowhere to
    # write the question used to reach `nil.write` from inside the reactor --
    # a NoMethodError, not a {Lain::Error}, so it escaped `exe/lain`'s rescue
    # and printed a backtrace at a user standing at a half-answered gate.
    it "refuses a half-wired terminal as a missing seam, not a NoMethodError" do
      expect { command(gates: hands_off.merge("research" => "interactive"), output: nil).submit("research") }
        .to raise_error(Lain::Approval::Gate::Policies::MissingSeam, /research.*interactive.*asker/m)
    end

    it "fails closed on end of input" do
      said = command(gates: hands_off.merge("research" => "interactive"), input: tty(nil)).submit("research")

      expect(said).to include("denied")
    end
  end

  # Which epic a bare `lain epic submit STAGE` means. It must be the SAME
  # question `lain epic status` answers, or the two commands report on
  # different work without either of them raising.
  describe "choosing the epic" do
    it "resolves the sole epic in the home when no slug is given" do
      write_research
      write_epic

      expect(command.submit("research")).to include("alpha")
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

      said = command.submit("research", "beta")

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
    def changeset = "blake3:#{"c" * 64}"

    def plan_digest(outcome)
      Lain::Epic::Submission.issue_plan(text: "the plan for a\n", slug: "alpha", issue_id: "a",
                                        criteria_digest: criteria_digest_of(outcome)).digest
    end

    before do
      home.write_epic(graph_with("it works"))
      session("started.ndjson", stage_event("issue_plan"))
      home.plan("a").write("the plan for a\n")
    end

    it "journals the criteria the plan was approved with" do
      command.submit("issue_plan", issue: "a")

      expect(gate_decisions.last).to include("artifact_digest" => plan_digest("it works"), "issue_id" => "a",
                                             "criteria_digest" => criteria_digest_of("it works"))
    end

    it "refuses the implementation once a criterion is edited, naming the un-approved plan digest" do
      command.submit("issue_plan", issue: "a")
      home.write_epic(graph_with("it works, and says so"))

      expect { command.submit("implementation", issue: "a", digest: changeset) }
        .to raise_error(described_class::PlanNotApproved, /"a".*issue_plan.*#{plan_digest("it works, and says so")}/m)
    end

    it "journals nothing when it refuses" do
      command.submit("issue_plan", issue: "a")
      home.write_epic(graph_with("it works, and says so"))
      before_records = journal_records

      expect { command.submit("implementation", issue: "a", digest: changeset) }
        .to raise_error(described_class::PlanNotApproved)

      expect(journal_records).to eq(before_records)
    end

    it "opens the implementation again once the edited plan is approved" do
      command.submit("issue_plan", issue: "a")
      home.write_epic(graph_with("it works, and says so"))
      command.submit("issue_plan", issue: "a")

      expect(command.submit("implementation", issue: "a", digest: changeset)).to start_with("approved")
    end

    it "refuses an implementation for an issue whose plan was never approved" do
      expect { command.submit("implementation", issue: "a", digest: changeset) }
        .to raise_error(described_class::PlanNotApproved, /lain epic submit issue_plan --issue a/)
    end

    it "refuses a plan for an issue the epic does not hold, before anything is journaled" do
      home.plan("ghost").write("a plan for nothing\n")

      expect { command.submit("issue_plan", issue: "ghost") }.to raise_error(Lain::Epic::UnknownIssue, /ghost/)
      expect(gate_decisions).to be_empty
    end
  end

  # The stages whose artifact is not one of the epic's own two documents have to
  # be told WHICH issue. Refused by name rather than left to build a Submission
  # for an unnamed issue.
  describe "the issue-scoped stages" do
    before do
      write_epic
      session("started.ndjson", stage_event("issue_plan"))
    end

    it "submits the plan written for one issue" do
      home.plan("a").write("the plan for a\n")

      said = command.submit("issue_plan", issue: "a")

      expect(said).to include("approved", "issue_plan")
    end

    it "refuses when no issue is named" do
      expect { command.submit("issue_plan") }.to raise_error(described_class::NeedsIssue, /issue_plan/)
    end

    it "refuses an implementation with no changeset address" do
      expect { command.submit("implementation", issue: "a") }
        .to raise_error(described_class::NeedsDigest, /implementation/)
    end
  end

  it "refuses a stage outside the pipeline" do
    write_research
    write_epic

    expect { command.submit("reserch") }.to raise_error(Lain::Epic::UnknownStage, /reserch/)
  end
end
