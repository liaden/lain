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

  # Approvals of the named stages, as the stages before an epic's later gates
  # carry them: a boundary opens only over an approved earlier stage. Their
  # digests are not any artifact's here, so no submit reads one as standing.
  def approvals(*stages, slug: "alpha")
    stages.map do |stage|
      decision(digest: "blake3:#{stage}-approved", stage:, approved: true, policy: "hands_off", slug:)
    end
  end

  def epic_approved(slug: "alpha") = approvals("research", "epic_plan", slug:)

  # What the examples decided, past the approvals a fixture stamped before them.
  def submitted_decisions = gate_decisions.drop(epic_approved.size)

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
      session("started.ndjson", *epic_approved, stage_event("issue_plan"))
      home.plan("a").write("the plan for a\n")
      command.submit("issue_plan", issue: "a")

      command.submit("implementation", issue: "a", digest: "blake3:#{"f" * 64}")

      expect(stage_events).to eq([%w[issue_plan started]])
      expect(submitted_decisions.map { |record| record.values_at("stage", "issue_id", "approved") })
        .to eq([["issue_plan", "a", true], ["implementation", "a", true]])
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
      said = command(gates: { "research" => "hands_off" }).submit("research")

      expect(said).to start_with("approved #{research_digest}")
      expect(said).to include("research completed, epic_plan started")
      expect(gate_decisions.map { |record| record.values_at("approved", "stage") }).to eq([[true, "research"]])
      expect(stage_events).to eq([%w[research completed], %w[epic_plan started]])
      expect(home.epic.exist?).to be(false)
    end

    it "repairs a standing research approval that never advanced the epic" do
      session("approved.ndjson", decision(digest: research_digest, stage: "research", approved: true,
                                          policy: "hands_off"))

      said = command(gates: { "research" => "hands_off" }).submit("research")

      expect(said).to include("already approved", "research completed, epic_plan started")
      expect(stage_events).to eq([%w[research completed], %w[epic_plan started]])
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
      session("started.ndjson", *epic_approved, stage_event("issue_plan"))
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

    # An implementation's address names its issue, so an approval of a's commit
    # opens no other issue's gate over that same commit.
    it "does not read a's implementation approval as b's, over the same commit" do
      command.submit("issue_plan", issue: "a")
      command.submit("issue_plan", issue: "b")
      command.submit("implementation", issue: "a", digest: changeset)

      said = command.submit("implementation", issue: "b", digest: changeset)

      expect(said).not_to start_with("already approved")
      implementations = gate_decisions.select { |record| record["stage"] == "implementation" }
      expect(implementations.map { |record| record.values_at("issue_id", "approved") })
        .to eq([["a", true], ["b", true]])
      expect(implementations.map { |record| record["artifact_digest"] }.uniq.size).to eq(2)
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

      expect(submitted_decisions.map { |record| record["issue_id"] }).to eq(["a"])
      expect(parked_plans.map(&:issue_id)).to eq(["a"])
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

      expect(command.submit("research")).to start_with("approved #{research_digest("v1\n")}")
      expect(command.submit("epic_plan")).to start_with("approved")
    end
  end

  describe "a stage never approved" do
    before do
      write_research(slug: "plans")
      write_epic(slug: "plans")
      home("plans").plan("a").write("the plan for a\n")
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

      expect(command.submit("epic_plan", "plans")).to start_with("approved")
    end

    it "does not read another epic's approvals as this one's" do
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

      said = command(gates: { "research" => "hands_off" }).submit("research")

      expect(said).to include("approved", research_digest)
      expect(gate_decisions.map { |record| record["stage"] }).to eq(["research"])
    end

    # Scenario: a malformed but parseable gate_decision refuses by name
    it "refuses a gate_decision whose approved field is \"maybe\" in one line naming the record" do
      File.write(File.join(sessions_dir, "damaged.ndjson"),
                 "#{JSON.generate(decision(digest: research_digest, stage: "research").to_journal
                                    .merge("ts" => "2026-01-01T00:00:00Z", "approved" => "maybe"))}\n")

      expect { command.submit("epic_plan") }.to raise_error(Lain::Error) { |error|
        expect(error).to be_a(Lain::Approval::SignoffQueue::UnreadableRecord)
        expect(error.message).to include("gate_decision", research_digest, "approved")
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
      home.plan("a").write("the plan for a\n")
      File.write(File.join(sessions_dir, "damaged.ndjson"),
                 "#{JSON.generate(decision(digest: "blake3:damaged", stage: "issue_plan").to_journal
                                    .merge("ts" => "2026-01-01T00:00:00Z", "approved" => "maybe"))}\n")

      expect { command.ensure_plan_approved!("a") }.to raise_error(Lain::Error) { |error|
        expect(error).to be_a(Lain::Approval::SignoffQueue::UnreadableRecord)
        expect(error.message).to include("gate_decision", "blake3:damaged", "approved")
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

    # Scenario: an unattended submit of an interactive stage refuses in words
    it "says stdin is not a terminal, naming the stage and the policies that would proceed" do
      expect { unaskable.submit("epic_plan") }.to raise_error(Lain::Error) { |error|
        expect(error).to be_a(Lain::Approval::Gate::Policies::Refusal)
        expect(error.kind).to eq(:missing_seam)
        expect(error.message).to match(/epic_plan.*interactive.*stdin is not a terminal/)
        expect(error.message)
          .to include("`gate :epic_plan, :hands_off`", ":deferred", "`epics` block of .lain/config.rb")
        expect(error.message).not_to include("adjudicated", "\n")
      }
    end

    # Scenario: an unattended submit of a hands-off stage proceeds
    it "decides a hands_off stage while the stages it is not submitting are left interactive" do
      said = command(gates: { "research" => "hands_off" }, input: nil).submit("research")

      expect(said).to include("approved", research_digest)
      expect(gate_decisions.map { |record| record.values_at("stage", "policy") }).to eq([%w[research hands_off]])
    end

    # No wired path builds one, but the sentence must not depend on that: a
    # caller that hands over live streams and still no asker gets a reason.
    it "names the missing asker itself when the streams could have carried a question" do
      askerless = described_class.new(root:, paths:, config: config(hands_off.merge("epic_plan" => "interactive")),
                                      input: tty, output: StringIO.new, asker: nil)

      expect { askerless.submit("epic_plan") }
        .to raise_error(Lain::Approval::Gate::Policies::Refusal, /epic_plan.*but this session wired no asker, so/)
    end

    it "journals no gate_decision" do
      # The regex is the discriminator, and it is load-bearing: `Refusal` is now
      # EVERY refusal this factory makes, so a bare class match would be
      # satisfied by an unknown-policy or unknown-seam refusal too.
      expect { unaskable.submit("epic_plan") }
        .to raise_error(Lain::Approval::Gate::Policies::Refusal, /epic_plan.*interactive.*not a terminal/m)

      expect(gate_decisions).to be_empty
    end

    # The CLI always wires the pair when a stage wants it; an in-process
    # caller that constructs this command without one is refused by name.
    it "refuses an adjudicated stage in a session that wired no role spawn or brief" do
      expect { command(gates: hands_off.merge("implementation" => "adjudicated")).submit("research") }
        .to raise_error(Lain::Approval::Gate::Policies::Refusal, /implementation.*adjudicated.*role_spawn, brief/m)
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
      profile = with_env("LAIN_NUM_BATCH" => "2048") { LainCLI::ModelFlags.profile(options) }

      described_class.from_options(options, profile:, input: tty, output: StringIO.new, root:, paths:,
                                            config: config(adjudicating)).submit("research")

      expect(chat).to have_been_requested.at_least_twice
      expect(a_request(:post, "http://localhost:11434/api/chat")
               .with { |req| JSON.parse(req.body).dig("options", "num_batch") != 2048 }).not_to have_been_made
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
          chronicle.start(context: Lain::Context.new(model: "m", max_tokens: 64), toolset: Lain::Toolset.new)
        end
      end
      let(:asker) do
        Lain::Tools::AskHuman.new(parent: Lain::Timeline.empty(store: Lain::Store.new), observer: chronicle.observer)
      end

      after { session_journal.close }

      def inbox_count = JSON.parse(File.read(feed_path)).fetch("inbox_count")

      def seat
        described_class.new(root:, paths:, config: config(hands_off.merge("research" => "interactive")), asker:,
                            journal: chronicle.record_journal)
      end

      # The human's side of the gate, run beside the submit the way the chat's
      # drain runs beside the driver: it waits for the question, then acts.
      def submitted_while
        Sync do |task|
          task.async do
            task.yield until asker.pending?
            yield asker.last_question
          end
          seat.submit("research")
        end
      end

      def verdicts = gate_decisions.map { |record| record.values_at("approved", "answered_by") }

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
        # A window short enough that a reply that never arrives fails the example
        # rather than hanging it.
        def written_and_saved(reply)
          stub_const("Lain::Approval::Gate::DEFAULT_TIMEOUT", 5)
          Sync do |task|
            surfaces = replies.session_surfaces(task)
            task.async do
              task.yield until asker.pending?
              write_beneath(asker.last_question, reply)
            end
            seat.submit("research").tap { surfaces.each(&:stop) }
          end
        end

        # <CR> opens the set; the human writes; `:w` hands it on.
        def write_beneath(question, reply)
          expect(question_view.open(Lain::Question::Set.from_body(question.body), question.digest)).to be_nil
          expect(question_view.wrote([*editor.opened.last.first, "", "  #{reply}"], question.digest)).to be_nil
        end

        it "approves when the human writes approve and saves" do
          expect(written_and_saved("approve")).to include("approved")

          expect(verdicts).to eq([[true, "human"]])
        end

        it "denies as the human's own denial when the human writes deny and saves" do
          expect(written_and_saved("deny")).to include("denied")

          expect(verdicts).to eq([[false, "human"]])
        end
      end

      # Scenario: a reply is classified, and only a word the question names is a
      # human's verdict. Typed at `human>` or sent by `:LainReply`, the reply
      # reaches the asker as the words themselves.
      describe "a reply in words" do
        {
          "approve" => true, "approved" => true, "y" => true, "yes" => true,
          "  YES \n" => true, "Approve." => true, "approved!" => true,
          "deny" => false, "denied" => false, "n" => false, "No." => false
        }.each do |reply, approved|
          it "reads #{reply.inspect} as the human #{approved ? "approving" : "denying"}" do
            submitted_while { |question| asker.reply(reply, question.digest) }

            expect(verdicts).to eq([[approved, "human"]])
          end
        end

        ["lgtm", "approve it", "", "approve?", "yes?"].each do |reply|
          it "denies #{reply.inspect} as unrecognised, carrying the reply in the reason" do
            said = submitted_while { |question| asker.reply(reply, question.digest) }

            expect(said).to include("denied")
            expect(verdicts).to eq([[false, "unrecognised"]])
            expect(gate_decisions.first["reason"]).to include(reply.inspect)
          end
        end

        # Scenario: end of input is not a human's answer
        it "records end of input at the reply prompt as eof" do
          submitted_while { |question| asker.reply(Lain::Tools::AskHuman::Unanswered.new, question.digest) }

          expect(verdicts).to eq([[false, "eof"]])
        end
      end

      it "counts the gate's question while it waits and none once its window closes" do
        stub_const("Lain::Approval::Gate::DEFAULT_TIMEOUT", 0.2)
        while_waiting = nil

        said = Sync do |task|
          task.async do
            task.yield until asker.pending?
            while_waiting = inbox_count
          end
          seat.submit("research")
        end

        expect(said).to include("denied")
        expect(while_waiting).to eq(1)
        expect(inbox_count).to eq(0)
      end
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

    # Scenario: a standing approval with no transition is repaired. An approval
    # whose process died, or whose surface never advanced the epic, left the
    # epic reading research; re-submitting is how the operator repairs it.
    it "repairs an approval that never advanced the epic" do
      said = command(gates: { "research" => "hands_off" }).submit("research")

      expect(said).to include("already approved", "research completed, epic_plan started")
      expect(stage_events).to eq([%w[research completed], %w[epic_plan started]])
      expect(progress.stage.name).to eq("epic_plan")
    end

    it "writes the repair once, however often the approval is re-submitted" do
      2.times { command(gates: { "research" => "hands_off" }).submit("research") }

      expect(stage_events).to eq([%w[research completed], %w[epic_plan started]])
    end

    it "journals no further stage transition over an approval that already advanced the epic" do
      session("advanced.ndjson", stage_event("research", event: "completed"), stage_event("epic_plan"),
              at: "2026-01-01T00:00:01Z")

      said = command(gates: { "research" => "hands_off" }).submit("research")

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
        .to raise_error(Lain::Approval::Gate::Policies::Refusal, /research.*interactive.*nowhere to write/m)
    end

    it "denies an unrecognised reply as unrecognised, never as the human's denial" do
      said = command(gates: hands_off.merge("research" => "interactive"), input: tty("maybe\n")).submit("research")

      expect(said).to include("denied")
      expect(gate_decisions.map { |record| record.values_at("approved", "answered_by") })
        .to eq([[false, "unrecognised"]])
    end

    # Scenario: end of input is not a human's answer
    it "fails closed on end of input, and records nobody's answer as eof" do
      said = command(gates: hands_off.merge("research" => "interactive"), input: tty(nil)).submit("research")

      expect(said).to include("denied")
      expect(gate_decisions.map { |record| record.values_at("approved", "answered_by") }).to eq([[false, "eof"]])
    end

    # Scenario: latency is measured from the question's write, not from
    # before it. {Prompt#ask} used to resolve synchronously, so
    # {Approval::Gate#await}'s clock only ever started after a human had
    # already answered -- every journaled latency read as instant no matter
    # how long the read actually took.
    it "measures at least as long as the terminal read actually takes" do
      slow = instance_double(IO, tty?: true)
      allow(slow).to receive(:gets) do
        sleep 2
        "y\n"
      end

      command(gates: hands_off.merge("research" => "interactive"), input: slow).submit("research")

      expect(gate_decisions.first["latency"]).to be >= 2
    end

    # Mentally revert to always answering `Approval::Gate::DEFAULT_TIMEOUT`
    # and this fails: with the window shrunk small enough for the read to
    # outlast it, a bounded gate would deny with `answered_by: "timeout"`
    # before the human ever got to type.
    it "keeps no timeout: a read that outlasts DEFAULT_TIMEOUT still answers" do
      stub_const("Lain::Approval::Gate::DEFAULT_TIMEOUT", 0.05)
      slow = instance_double(IO, tty?: true)
      allow(slow).to receive(:gets) do
        sleep 0.2
        "y\n"
      end

      said = command(gates: hands_off.merge("research" => "interactive"), input: slow).submit("research")

      expect(said).to include("approved")
      expect(gate_decisions.map { |record| record["answered_by"] }).to eq(["human"])
    end
  end

  # Ctrl-C at an unanswered prompt unwinds the whole reactor before the plain
  # `Interrupt` the human sent re-emerges outside {Approval::Gate}'s own Sync
  # boundary -- see that class's own `Async::Cancel` handling, which journals
  # the fail-closed refusal before letting the cancellation through.
  # {Verdict#call} is where the boundary this command owns sits, so this
  # drives it directly with a policy that raises the same way, rather than
  # fighting a real terminal and a real signal inside an example -- RSpec
  # traps SIGINT for its own graceful shutdown, so a self-sent one here would
  # be caught by the RUNNER, not by this class.
  describe Lain::CLI::EpicSubmit::Verdict do
    # NOT translated. {Approval::Gate} has already journaled the fail-closed
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
                                    queue: nil, advance: nil)

      expect { verdict.call }.to raise_error(Interrupt)
    end
  end

  # A REAL Ctrl-C through a REAL `lain epic submit`, in its own PROCESS: a PTY
  # so the child has a real controlling terminal (`Prompt.on` refuses without
  # one) and a real line discipline (^C on the master is what actually sends
  # SIGINT to the child's foreground process group -- the same delivery path
  # an operator's terminal uses, and the one no in-process trick reproduces).
  # `Approval::Gate` journals the fail-closed decision from its own
  # `Async::Cancel` handling, and the plain `Interrupt` that re-emerges once
  # the child's reactor unwinds is what `render`'s own Ctrl-C rescue turns
  # into "interrupted", exit 130 -- pinning that neither half of that
  # contract silently drops the other.
  describe "Ctrl-C through the real CLI", :seam do
    # Polled with a DEADLINE, never a bare `loop`: a prompt that never
    # arrives (a regression that makes the child exit, or hang, before it
    # ever asks) must fail this example, not wedge the suite. `screen` grows
    # from a background reader so the deadline poll never itself blocks on
    # the child's own output.
    def await_prompt(screen, mutex, deadline_at)
      sleep 0.02 until mutex.synchronize { screen.include?("[y/N]") } ||
                       Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline_at
    end

    it "exits 130, with the fail-closed decision already journaled" do
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

        await_prompt(screen, mutex, Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10)
        raise "timed out waiting for the [y/N] prompt; got: #{mutex.synchronize { screen }.inspect}" \
          unless mutex.synchronize { screen.include?("[y/N]") }

        inp.write("\x03")
        _, status = Process.wait2(pid)
        reader.join(2)
      end

      paths = Lain::Paths.new(env: { "XDG_STATE_HOME" => state_home })
      written_to = paths.sessions_dir(project: paths.project_hash(root))
      written = Dir.children(written_to).select { |name| name.end_with?(".ndjson") }
                   .flat_map { |name| Lain::Journal.records(File.foreach(File.join(written_to, name))).to_a }
      decisions = written.select { |record| record["type"] == "gate_decision" }

      expect(status.exitstatus).to eq(130)
      expect(screen).to include("interrupted")
      expect(decisions.map { |record| record.values_at("approved", "answered_by") }).to eq([[false, "interrupted"]])
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
      session("started.ndjson", *epic_approved, stage_event("issue_plan"))
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
      session("started.ndjson", *epic_approved, stage_event("issue_plan"))
    end

    it "submits the plan written for one issue" do
      home.plan("a").write("the plan for a\n")

      said = command.submit("issue_plan", issue: "a")

      expect(said).to include("approved", "issue_plan")
    end

    it "refuses when no issue is named" do
      expect { command.submit("issue_plan") }.to raise_error(Lain::Error, /issue_plan/)
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
  describe Lain::CLI::EpicSubmit::Adjudication do
    def interactive = Lain::Epic::STAGES.to_h { |stage| [stage, "interactive"] }
    def adjudicating = interactive.merge("research" => "adjudicated")

    def spike_backend(*answers)
      EpicSubmitSpecSupport::FakeBackend.new(
        provider: Lain::Provider::Mock.new(responses: answers.map { |answer| text_response(answer) }),
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
        result = pair.role_spawn.call(:researcher, :fresh, "gather evidence on the research")

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
        guard = ->(_worker_env) { Lain::Middleware::Stack.new }

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

      it "sends an issue plan's spike to the plan and to the epic that holds its criteria" do
        submission = Lain::Epic::Submission.issue_plan(text: "plan\n", slug: "demo", issue_id: "a",
                                                       criteria_digest: nil)

        expect(brief.call(submission)).to include("issue a", home.plan("a").path, home.epic.path)
      end

      it "names an implementation's changeset by its address, beside the plan it was built to" do
        submission = Lain::Epic::Submission.implementation(slug: "demo", issue_id: "a", digest: "blake3:change")

        expect(brief.call(submission)).to include("blake3:change", home.plan("a").path)
      end

      it "tells the spike to gather rather than judge" do
        expect(brief.call(Lain::Epic::Submission.research(text: "notes\n", slug: "demo"))).to match(/do not judge/i)
      end
    end
  end
end
