# frozen_string_literal: true

require "fileutils"
require "mixlib/shellout"
require "tmpdir"

# An issue launched as an actor running execute-plan: refused unless its plan is
# approved, then adopted into a checkout the epic's supervisor cut at
# epic/demo's tip, switched onto a branch of its own, given its failing tests,
# and only then handed its first turn. Real git end to end: one repository
# whose epic branch is ahead of main, an epic home with three issues, and a
# session journal approving the plans of two.
RSpec.describe Lain::CLI::EpicDriver::IssueActor, :seam do
  around do |example|
    Dir.mktmpdir("lain-issue-actor") do |dir|
      @root = File.realpath(dir)
      FileUtils.mkdir_p(repo)
      FileUtils.cp_r("#{SeedRepo.at({ "README" => "seed\n" })}/.", repo)
      FileUtils.cp_r(File.join(layout_mini, "."), repo)
      git(repo, "add", "-A")
      git(repo, "commit", "-q", "-m", "layout_mini")
      git(repo, "branch", "-M", "main")
      @epic = Lain::Isolation::WorkingBranch.epic("demo", repo_root: repo)
      advance_epic
      FileUtils.mkdir_p(paths.sessions_dir)
      write_epic
      %w[a c].each { |id| approve_plan(id) }
      example.run
    end
  end

  let(:layout_mini) { File.expand_path("../../../fixtures/projects/layout_mini", __dir__) }
  let(:target) { "spec/unit/models/order_spec.rb" }
  let(:backend) { Lain::CLI::Backend.new({ provider: "ollama", model: nil, max_tokens: 64 }) }
  let(:config) { Lain::Config.new(epics: Lain::Config::Epics.new(home: :xdg, gates: {})) }
  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@root, "state"), "HOME" => @root }) }
  let(:home) { Lain::Epic::Home.resolve(config:, paths:, root: repo, slug: "demo") }
  let(:plan) { ->(id) { Lain::CLI::EpicSubmit.new(root: repo, paths:, config:).ensure_plan_approved!(id, "demo") } }
  let(:standing) { [] }
  let(:criteria_a) do
    <<~MD
      ```gherkin
      Scenario: an order totals its lines
        Given an order with lines of 1 and 2
        When it is totalled
        Then the total is 3

      Scenario: an order can be refunded
        Given a totalled order
        When it is refunded
        Then its total is 0
      ```
    MD
  end
  let(:criteria_b) do
    <<~MD
      ```gherkin
      Scenario: an order can be cancelled
        Given an open order
        When it is cancelled
        Then it is closed
      ```
    MD
  end

  # The suite, as the red step reads it: the generated tests fail.
  let(:failing) do
    red = Lain::Grader::TestHarness::Run.new(passed: [], failed: ["Order totals its lines"], errors: [], stderr: "")
    suite = Object.new.tap { |runner| runner.define_singleton_method(:run) { |*, **| red } }
    ->(_root) { suite }
  end

  # Before every round trip, the subject of the commit the leased checkout
  # stands on: which is how the red commit preceding the actor's first turn
  # becomes an assertion rather than an ordering the code happens to have.
  let(:provider) do
    probe = ->(_request) { standing << git(leased_checkout, "log", "-1", "--format=%s") }
    Class.new(Lain::Provider::Mock) do
      define_method(:complete) do |request, **options|
        probe.call(request)
        super(request, **options)
      end
    end.new(responses: script)
  end

  # The test_engineer's two round trips, then the orchestrator's one.
  let(:script) { [*test_engineer, text_response("plan done")] }

  let(:build) do
    Lain::CLI::Wiring::ToolsetBuild.new(
      backend:, provider:, chronicle: Lain::CLI::Chronicle::Null.new, options: {}, supervisor: Lain::Supervisor.new,
      parent: -> { Lain::Timeline.empty(store: Lain::Store.new) }, journal: Lain::Channel::Null.instance,
      library: backend.library, epic: Lain::CLI::EpicMount::NoEpic, root: repo
    ).tap do |toolset|
      toolset.build(Lain::Memory::Recorder.new, ask_human: Lain::Tools::AskHuman.new(parent: -> { Lain::Timeline.new }))
    end
  end

  def repo = File.join(@root, "repo")
  def worktrees = File.join(@root, "worktrees")

  # The checkout the epic's supervisor cut: the one registered under its root.
  def leased_checkout = File.dirname(Dir.glob(File.join(worktrees, "*", ".git")).first)

  def epic_tip = git(repo, "rev-parse", "refs/heads/epic/demo")

  # This spec's own git runs only inside the fixture's temp tree; the scrub is
  # for the hook's GIT_INDEX_FILE reason.
  def shell(dir, *args)
    raise "refusing to run git outside the fixture: #{dir}" unless dir.start_with?("#{@root}/")

    Mixlib::ShellOut.new("git", "-C", dir, *args, environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB).run_command
  end

  def git(dir, *) = shell(dir, *).tap(&:error!).stdout.strip

  def ancestor?(dir, commit) = shell(dir, "merge-base", "--is-ancestor", commit, "HEAD").exitstatus.zero?

  def advance_epic
    git(repo, "switch", "-q", "epic/demo")
    File.write(File.join(repo, "epic.txt"), "landed on the epic\n")
    git(repo, "add", "epic.txt")
    git(repo, "commit", "-q", "-m", "epic work")
    git(repo, "switch", "-q", "main")
  end

  def issue(id, criteria = nil) = Lain::Epic::Issue.new(id:, title: "the #{id} issue", status: "in_flight", criteria:)

  def write_epic
    home.write_epic(Lain::Epic::Graph.new(issues: [issue("a", criteria_a), issue("b", criteria_b), issue("c")]))
    %w[a b c].each { |id| home.plan(id).write("the plan for #{id}\n") }
  end

  def approve_plan(id)
    plan = Lain::Epic::Submission.issue_plan(text: "the plan for #{id}\n", slug: "demo", issue_id: id,
                                             criteria_digest: home.read_epic.fetch(id).criteria_digest)
    decision = Lain::Approval::GateDecision.new(artifact_digest: plan.digest, epic_slug: "demo", stage: "issue_plan",
                                                approved: true, answered_by: "human", policy: "hands_off",
                                                latency: 0.0, issue_id: id)
    File.open(File.join(paths.sessions_dir, "fixture.ndjson"), "a") do |io|
      Lain::Journal.new(io:, clock: -> { "2026-01-01T00:00:00Z" }).record(decision)
    end
  end

  # The test_engineer child writes its tests through the real write_file tool.
  # write_file makes no directories and git carries none, so the child's own
  # first call makes them, through a shell that refuses outside the fixture.
  def test_engineer
    [tool_response(["m1", "bash", { "command" => guarded("mkdir -p spec/unit/models") }]),
     tool_response(["w1", "write_file", { "path" => target, "content" => "RSpec.describe Order do\nend\n" }]),
     text_response("wrote the spec")]
  end

  def guarded(command)
    "case \"$(pwd -P)\" in #{@root}/*) ;; *) echo \"refusing outside the fixture: $(pwd -P)\" >&2; exit 1;; esac; " \
      "#{command}"
  end

  def issue_actor(supervisor)
    renderer = backend.library.renderer
    described_class.new(slug: "demo", supervisor:, subagent: build.method(:epic_subagent), renderer:, home:, plan:,
                        repo_root: repo, tests: red_step(renderer), lanes: child_lanes)
  end

  def red_step(renderer)
    Lain::CLI::EpicDriver::IssueTests.new(renderer:, role_spawn: build.role_spawn, harness: failing)
  end

  def child_lanes = described_class::Lanes.new(root: File.join(@root, "children"), role_spawn: build.role_spawn)

  # The epic's supervisor, as the driver builds it: its checkouts are cut from
  # epic/demo, never from the chat's branch.
  def supervising
    Sync do |task|
      supervisor = Lain::Supervisor.new(isolation: Lain::Isolation::Worktree.new(root: worktrees, repo_root: repo,
                                                                                 base: @epic)).run(task)
      yield supervisor
    ensure
      supervisor&.stop
    end
  end

  def launch(supervisor, id, **) = issue_actor(supervisor).call(id, subject: "app/models/order.rb", **)

  def first_prompt(request) = request.messages.first["content"].first["text"]

  it "starts on epic/demo's tip, on a branch of its own, with its plan and criteria, after its tests are committed" do
    supervising do |supervisor|
      launched = launch(supervisor, "a").tap { |row| row.actor.settle }
      checkout = launched.actor.session.worker_env.cwd

      expect(supervisor.find { |row| row.actor.equal?(launched.actor) }.role).to eq("issue_orchestrator")
      expect([launched.worker_id, launched.branch]).to eq(["issue.demo.a.1", "lain/issue/demo/a"])
      expect(git(checkout, "symbolic-ref", "HEAD")).to eq("refs/heads/lain/issue/demo/a")
      expect(ancestor?(checkout, epic_tip)).to be(true)
      expect(git(repo, "rev-parse", "refs/lain/owned/heads/lain/issue/demo/a")).to eq(epic_tip)
      expect(launched.tests.record.target).to eq(target)
      expect(git(checkout, "rev-parse", "HEAD")).to eq(launched.tests.sha)
    end

    expect(standing.first).to eq("epic work")
    expect(standing.last).to start_with("test: failing tests at #{target}")
    orchestrator = provider.requests.last
    expect(first_prompt(orchestrator)).to include(home.plan("a").path, "an order totals its lines",
                                                  "an order can be refunded", target, "epic/demo")
    expect(orchestrator.system.last["text"]).to eq(backend.library.slots.render_role(:issue_orchestrator))
  end

  context "when the orchestrator hands the implementing to a dev child" do
    let(:script) do
      [*test_engineer,
       tool_response(["o1", "subagent", { "prompt" => "implement it", "role" => "dev" }]),
       tool_response(["d1", "bash", { "command" => guarded(dev_commit) }]),
       text_response("dev done"), text_response("plan done")]
    end

    def dev_commit
      "printf 'refund\\n' > refund.txt && " \
        "env -u GIT_INDEX_FILE -u GIT_DIR -u GIT_WORK_TREE sh -c 'git add refund.txt && git commit -q -m \"dev work\"'"
    end

    it "brings the child's work home onto the issue's branch, never onto epic/demo or the chat's checkout" do
      before = [epic_tip, git(repo, "rev-parse", "HEAD")]

      supervising do |supervisor|
        checkout = launch(supervisor, "a").actor.tap(&:settle).session.worker_env.cwd

        expect(git(checkout, "log", "-3", "--format=%s").split("\n").first(2))
          .to eq(["dev work", "test: failing tests at #{target}, from criteria " \
                              "#{Lain::Gherkin::Criteria.parse(criteria_a).digest}"])
        expect(git(checkout, "show", "lain/issue/demo/a:refund.txt")).to eq("refund")
        # The children's lane carries the attempt, as the actor's own id does,
        # so a later attempt's children cannot swap this one's anchors away.
        expect(git(repo, "for-each-ref", "--format=%(refname)", "refs/lain/worker/"))
          .to include("issue.demo.a.1.subagent-spawn")
      end

      expect([epic_tip, git(repo, "rev-parse", "HEAD")]).to eq(before)
      expect(git(repo, "status", "--porcelain")).to eq("")
    end
  end

  it "refuses an issue whose plan is not approved, naming its issue_plan, and leases nothing" do
    supervising do |supervisor|
      expect { launch(supervisor, "b") }
        .to raise_error(Lain::CLI::EpicSubmit::PlanNotApproved, /issue "b".*issue_plan/m)
      expect(supervisor.to_a).to be_empty
    end

    expect(provider.call_count).to eq(0)
    expect(shell(repo, "rev-parse", "--verify", "--quiet", "refs/heads/lain/issue/demo/b").exitstatus).not_to eq(0)
  end

  it "refuses an issue with no acceptance criteria, before anything is leased" do
    supervising do |supervisor|
      expect { launch(supervisor, "c") }.to raise_error(described_class::NoCriteria, /issue c/)
      expect(supervisor.to_a).to be_empty
    end
  end

  it "refuses an attempt whose anchor still stands, naming the ref, and launches the next attempt" do
    anchor = Lain::Isolation::Worktree::Handback::Naming.new("issue.demo.a.1").ref
    git(repo, "update-ref", anchor, epic_tip)

    supervising do |supervisor|
      expect { launch(supervisor, "a") }.to raise_error(described_class::AttemptStands, /#{Regexp.escape(anchor)}/)
      expect(provider.call_count).to eq(0)

      expect(launch(supervisor, "a", attempt: 2).worker_id).to eq("issue.demo.a.2")
    end
  end

  # A branch lain did not create is somebody's, and the owned marker is the
  # only licence anything has to delete one later.
  it "refuses to claim an issue branch lain did not create, and leaves it unmarked where it was" do
    git(repo, "switch", "-q", "-c", "lain/issue/demo/a", "main")
    File.write(File.join(repo, "stray.txt"), "somebody's work\n")
    git(repo, "add", "stray.txt")
    git(repo, "commit", "-q", "-m", "somebody's work")
    git(repo, "switch", "-q", "main")
    held = git(repo, "rev-parse", "lain/issue/demo/a")

    supervising do |supervisor|
      expect { launch(supervisor, "a") }
        .to raise_error(Lain::Isolation::WorkingBranch::Refused, %r{lain/issue/demo/a})
      expect(supervisor.to_a).to be_empty
    end

    expect(git(repo, "rev-parse", "lain/issue/demo/a")).to eq(held)
    expect(shell(repo, "rev-parse", "--verify", "--quiet",
                 "refs/lain/owned/heads/lain/issue/demo/a").exitstatus).not_to eq(0)
    expect(provider.call_count).to eq(0)
  end

  # A retry finds the branch its first attempt made. It is reused where it
  # stands, never reset onto the epic's newer tip.
  it "reuses an issue branch lain owns where it stands, moving neither it nor its marker" do
    git(repo, "branch", "lain/issue/demo/a", "main")
    main = git(repo, "rev-parse", "main")
    git(repo, "update-ref", "refs/lain/owned/heads/lain/issue/demo/a", main)

    supervising do |supervisor|
      checkout = launch(supervisor, "a").actor.tap(&:settle).session.worker_env.cwd

      expect(git(checkout, "rev-parse", "HEAD^")).to eq(main)
      expect(git(repo, "rev-parse", "refs/lain/owned/heads/lain/issue/demo/a")).to eq(main)
    end
  end
end
