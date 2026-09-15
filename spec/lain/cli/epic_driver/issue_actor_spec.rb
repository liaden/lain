# frozen_string_literal: true

require "fileutils"
require "mixlib/shellout"
require "tmpdir"

# The chat's asker, as the earlier-branches question meets it: every question
# is kept, and each is answered at once with the words given -- or never, for
# a human who walked away. A named question is one the record lists, so the
# asker hands back a promise answering its digest.
class IssueActorSpecAsker
  # A question the record lists: what the chat's own asker hands back.
  class Named < Lain::Promise
    def digest = "blake3:earlier-branches-question"
  end

  attr_reader :asked, :withdrawn

  def initialize(words, answers: true, named: false)
    @words = words
    @answers = answers
    @promise = named ? Named : Lain::Promise
    @asked = []
    @withdrawn = []
  end

  def ask(question)
    @asked << question
    @promise.new.tap { |promise| promise.resolve(@words) if @answers }
  end

  def withdraw(promise) = @withdrawn << promise
end

# Every record a journal was handed, in order.
class IssueActorSpecJournal
  attr_reader :records

  def initialize = @records = []

  def record(event) = @records << event
end

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
      library: backend.library, epic: Lain::CLI::EpicMount::NoEpic, root: repo,
      switchboard: -> { SpecNulls::NoSwitchboard }, askers: SpecNulls::UnwiredAskers.build
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
    Lain::CLI::EpicDriver::IssueTests.new(renderer:, role_spawn: build.role_spawn,
                                          layout: Lain::Config.test_layout(root: repo), harness: failing)
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
      expect { launch(supervisor, "c") }.to raise_error(Lain::Error, /issue c/)
      expect(supervisor.to_a).to be_empty
    end
  end

  it "refuses an attempt whose anchor still stands, naming the ref, and launches the next attempt" do
    anchor = Lain::Isolation::Worktree::Handback::Naming.new("issue.demo.a.1").ref
    git(repo, "update-ref", anchor, epic_tip)

    supervising do |supervisor|
      expect { launch(supervisor, "a") }.to raise_error(Lain::Error, /#{Regexp.escape(anchor)}/)
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

  # A delete running in a sibling reads checkouts once its marker is gone, so a
  # lease taken just after that read is one it cannot see. The launch that
  # took it is the side that must stop, before the red step or a first turn.
  it "refuses a launch whose branch lost lain's marker as it was checked out, spawning nothing" do
    git(repo, "branch", "lain/issue/demo/a", "main")
    git(repo, "update-ref", "refs/lain/owned/heads/lain/issue/demo/a", git(repo, "rev-parse", "main"))
    deleting = lambda do |*args, **options|
      git(repo, "update-ref", "-d", "refs/lain/owned/heads/lain/issue/demo/a") if args.include?("switch")
      Lain::Shell::Out.new(*args, **options)
    end
    renderer = backend.library.renderer

    supervising do |supervisor|
      actor = described_class.new(slug: "demo", supervisor:, subagent: build.method(:epic_subagent), renderer:, home:,
                                  plan:, repo_root: repo, tests: red_step(renderer), lanes: child_lanes,
                                  shell_out_factory: deleting)

      expect { actor.call("a", subject: "app/models/order.rb") }
        .to raise_error(Lain::Isolation::WorkingBranch::Refused, /another run is deleting it/)
    end
    expect(provider.call_count).to eq(0)
  end

  # A re-run of the epic finds what an earlier run left: issue a's lain-owned
  # branch, cut at main before the epic moved on, carrying its red step's commit.
  context "when an earlier run left issue a's branch carrying its red commit" do
    def earlier(asker, journal: Lain::CLI::Chronicle::Null.new.record_journal, **)
      described_class::Earlier.new(slug: "demo", repo_root: repo, asker:, journal:, **)
    end

    def owned_branch(id)
      git(repo, "branch", "lain/issue/demo/#{id}", "main")
      git(repo, "update-ref", "refs/lain/owned/heads/lain/issue/demo/#{id}", git(repo, "rev-parse", "main"))
    end

    def standing?(id)
      shell(repo, "rev-parse", "--verify", "--quiet", "refs/heads/lain/issue/demo/#{id}").exitstatus.zero?
    end

    def deletes?(words)
      owned_branch("a") unless standing?("a")
      Sync { earlier(IssueActorSpecAsker.new(words)).call(resumed: false) }
      !standing?("a")
    end

    def earlier_red
      git(repo, "branch", "lain/issue/demo/a", "main")
      git(repo, "update-ref", "refs/lain/owned/heads/lain/issue/demo/a", git(repo, "rev-parse", "main"))
      git(repo, "switch", "-q", "lain/issue/demo/a")
      red_committed
      git(repo, "switch", "-q", "main")
      git(repo, "rev-parse", "lain/issue/demo/a")
    end

    def red_committed
      FileUtils.mkdir_p(File.join(repo, File.dirname(target)))
      File.write(File.join(repo, target), "RSpec.describe Order do\nend\n")
      git(repo, "add", "--", target)
      git(repo, "commit", "--no-verify", "-q", "-m",
          "test: failing tests at #{target}, from criteria #{Lain::Gherkin::Criteria.parse(criteria_a).digest}")
    end

    def anchors_at(commit)
      git(repo, "for-each-ref", "--points-at", commit, "--format=%(refname)", "refs/lain/worker/")
    end

    it "deletes on the human's word: the branch is cut fresh at epic/demo's tip, the old tip kept on an anchor" do
      old = earlier_red
      asker = IssueActorSpecAsker.new("delete")

      discarded = nil
      supervising do |supervisor|
        discarded = earlier(asker).call(resumed: false)
        checkout = launch(supervisor, "a").actor.tap(&:settle).session.worker_env.cwd

        expect(git(checkout, "rev-parse", "HEAD^")).to eq(epic_tip)
        expect(git(repo, "rev-parse", "refs/lain/owned/heads/lain/issue/demo/a")).to eq(epic_tip)
      end

      expect(asker.asked.size).to eq(1)
      expect(asker.asked.first).to include("lain/issue/demo/a", "keep", "delete")
      expect(anchors_at(old)).to start_with("refs/lain/worker/")
      expect(discarded.map { |gone| [gone.branch, gone.anchor] }).to eq([["lain/issue/demo/a", anchors_at(old)]])
      expect(first_prompt(provider.requests.last)).to include("cut from the tip of `epic/demo`")
    end

    context "when the branch is kept" do
      # The orchestrator's one round trip, and no test_engineer: the red step
      # spawns nothing over a commit it carries forward.
      let(:script) { [text_response("plan done")] }

      it "keeps on the human's word: the red step passes on the existing red commit and the actor continues" do
        old = earlier_red
        asker = IssueActorSpecAsker.new("keep")

        supervising do |supervisor|
          earlier(asker).call(resumed: false)
          launched = launch(supervisor, "a").tap { |row| row.actor.settle }

          expect(launched.tests.sha).to eq(old)
          expect(git(launched.actor.session.worker_env.cwd, "rev-parse", "HEAD")).to eq(old)
        end

        expect(asker.asked.size).to eq(1)
        expect(provider.call_count).to eq(1)
        brief = first_prompt(provider.requests.last)
        expect(brief).to include("reused", old)
        expect(brief).not_to match(%r{stands on `lain/issue/demo/a`,\s+cut from the tip})
      end

      it "keeps without asking when the chat carrying the run was resumed" do
        old = earlier_red
        asker = IssueActorSpecAsker.new("delete")

        supervising do |supervisor|
          earlier(asker).call(resumed: true)

          expect(launch(supervisor, "a").tap { |row| row.actor.settle }.tests.sha).to eq(old)
        end

        expect(asker.asked).to be_empty
        expect(git(repo, "rev-parse", "lain/issue/demo/a")).to eq(old)
        expect(anchors_at(old)).to eq("")
      end
    end

    # Deleting is the one answer a second answer cannot take back, so only the
    # word itself deletes: spoken in any case, with a closing full stop or
    # exclamation mark, the way a gate reads a reply.
    it "deletes on delete in any case with trailing punctuation, and keeps on every other reply" do
      deleting = ["delete", "Delete", " DELETE!\n", "delete."].map { |words| deletes?(words) }
      replies = ["keep", "d", "del", "yes", "delete it", "delete?", "don't delete", "", nil]
      keeping = replies.map { |words| deletes?(words) }

      expect(deleting).to all(be(true))
      expect(keeping).to all(be(false))
    end

    it "keeps once the question goes unanswered past its timeout, withdrawing it" do
      owned_branch("a")
      asker = IssueActorSpecAsker.new(nil, answers: false)

      kept = Sync { earlier(asker, timeout: 0.2).call(resumed: false) }

      expect([kept, standing?("a")]).to eq([[], true])
      expect(asker.withdrawn.size).to eq(1)
    end

    # An asker admits one outstanding question, and an inbox lists a question
    # until the record retires it.
    it "withdraws the question it asked and retires it in the record once answered" do
      owned_branch("a")
      asker = IssueActorSpecAsker.new("keep", named: true)
      journal = IssueActorSpecJournal.new

      Sync { earlier(asker, journal:).call(resumed: false) }

      expect(asker.withdrawn.size).to eq(1)
      expect(journal.records.map(&:class)).to eq([Lain::Telemetry::QuestionsConsumed])
      expect(journal.records.first.digests).to eq([IssueActorSpecAsker::Named.new.digest])
    end

    it "says in its question that delete removes every earlier branch it lists" do
      %w[a b].each { |id| owned_branch(id) }
      asker = IssueActorSpecAsker.new("keep")

      Sync { earlier(asker).call(resumed: false) }

      expect(asker.asked.first).to include("lain/issue/demo/a", "lain/issue/demo/b")
      expect(asker.asked.first).to match(/delete removes all \d+ of these earlier branches/)
    end

    it "deletes none of the branches when any one of them cannot be deleted" do
      %w[a b].each { |id| owned_branch(id) }
      held = File.join(@root, "held-b")
      git(repo, "worktree", "add", "-q", held, "lain/issue/demo/b")

      expect { Sync { earlier(IssueActorSpecAsker.new("delete")).call(resumed: false) } }
        .to raise_error(Lain::Isolation::WorkingBranch::Refused, %r{lain/issue/demo/b.*#{Regexp.escape(held)}}m)
      expect([standing?("a"), standing?("b")]).to eq([true, true])
      expect(git(repo, "for-each-ref", "refs/lain/worker/")).to eq("")
    end

    # Judged whole, a branch can still move before its own delete: a sibling
    # committing to it then. What was deleted already is gone, so the refusal
    # has to say where those tips went.
    it "names each branch already deleted and its anchor when a later delete loses its race" do
      %w[a b].each { |id| owned_branch(id) }
      moving = lambda do |*args, **options|
        if args.include?("-d") && args.include?("refs/lain/owned/heads/lain/issue/demo/b")
          git(repo, "update-ref", "refs/heads/lain/issue/demo/b",
              git(repo, "commit-tree", git(repo, "rev-parse", "main^{tree}"), "-p", "main", "-m", "a sibling's"))
        end
        Lain::Shell::Out.new(*args, **options)
      end
      main = git(repo, "rev-parse", "main")
      a_anchor = Lain::Isolation::Worktree::Handback::Naming.new("lain/issue/demo/a #{main}").ref

      expect { Sync { earlier(IssueActorSpecAsker.new("delete"), shell_out_factory: moving).call(resumed: false) } }
        .to raise_error(Lain::Isolation::WorkingBranch::Refused) { |error|
          expect(error.message).to include("deleted lain/issue/demo/a, its old tip kept at #{a_anchor}")
          expect(error.message).to include("refs/heads/lain/issue/demo/b could not be deleted")
          expect(error.message).to include("still marked")
        }
      expect([standing?("a"), standing?("b")]).to eq([false, true])
    end

    it "lists a delete an earlier run left unfinished, and finishes it on delete" do
      owned_branch("a")
      tip = git(repo, "rev-parse", "lain/issue/demo/a")
      anchor = Lain::Isolation::Worktree::Handback::Naming.new("lain/issue/demo/a #{tip}").ref
      git(repo, "update-ref", anchor, tip)
      git(repo, "update-ref", "-d", "refs/lain/owned/heads/lain/issue/demo/a")
      asker = IssueActorSpecAsker.new("delete")

      gone = Sync { earlier(asker).call(resumed: false) }

      expect(asker.asked.first).to include("lain/issue/demo/a at #{tip} (a delete lain left unfinished)")
      expect([gone.map(&:anchor), standing?("a")]).to eq([[anchor], false])
    end

    it "asks nothing over an epic no earlier run left a branch in" do
      asker = IssueActorSpecAsker.new("delete")

      Sync { earlier(asker).call(resumed: false) }

      expect(asker.asked).to be_empty
    end

    it "never offers a branch lain did not create, and the launch still refuses naming it" do
      git(repo, "branch", "lain/issue/demo/a", "main")
      held = git(repo, "rev-parse", "lain/issue/demo/a")
      asker = IssueActorSpecAsker.new("delete")

      supervising do |supervisor|
        earlier(asker).call(resumed: false)

        expect { launch(supervisor, "a") }
          .to raise_error(Lain::Isolation::WorkingBranch::Refused, %r{lain/issue/demo/a})
      end

      expect(asker.asked).to be_empty
      expect(git(repo, "rev-parse", "lain/issue/demo/a")).to eq(held)
    end
  end
end
