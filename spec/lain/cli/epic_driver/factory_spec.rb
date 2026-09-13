# frozen_string_literal: true

require "fileutils"
require "mixlib/shellout"
require "tmpdir"

# An actor, as the Supervisor and the anchor-only retirement see one.
class FactorySpecActor
  Session = Data.define(:worker_env)

  def initialize(worker_env) = @worker_env = worker_env
  def session = Session.new(worker_env: @worker_env)
  def settle = nil
  def stopped? = false
  def dead? = false
  def stop = self
  def worker = self
  def address = "factory-spec"
end

# Scripted actors: each leases a real checkout from the epic's own supervisor
# and commits in it, which is what gives the loop something real to anchor,
# gate and land.
class FactorySpecActors
  Launch = Data.define(:actor, :worker_id, :branch, :tests)

  def initialize(fleet, log, repo, scrub)
    @fleet = fleet
    @log = log
    @repo = repo
    @scrub = scrub
  end

  def call(issue_id, subject:, level: nil, attempt: 1) # rubocop:disable Lint/UnusedMethodArgument
    @log << [:launched, issue_id, attempt, git(@repo, "rev-parse", "refs/heads/epic/demo")]
    actor = @fleet.adopt(role: "factory-spec", worker_id: "issue.demo.#{issue_id}.#{attempt}") do |worker_env|
      commit(worker_env, issue_id)
      FactorySpecActor.new(worker_env)
    end
    Launch.new(actor:, worker_id: "issue.demo.#{issue_id}.#{attempt}", branch: "lain/issue/demo/#{issue_id}",
               tests: nil)
  end

  private

  def commit(worker_env, issue_id)
    dir = worker_env.cwd
    @log << [:leased, issue_id, git(dir, "rev-parse", "HEAD")]
    File.write(File.join(dir, "#{issue_id}.txt"), "work for #{issue_id}\n")
    git(dir, "add", "-A")
    git(dir, "commit", "-q", "-m", "work for #{issue_id}")
  end

  def git(dir, *)
    Mixlib::ShellOut.new("git", "-C", dir, *, environment: @scrub).run_command.tap(&:error!).stdout.strip
  end
end

# What a chat seated in an epic can drive, built from the ONE mount the seat
# resolved. The factory owns the collaborators an epic run may not share with
# the chat: its own Supervisor, leasing worktrees cut from `epic/<slug>`
# whatever `--isolation` says, the anchor-only retirement that keeps a settled
# actor's work off the working branch until its gate has stood in front of it,
# and the checkout the landing queue merges in -- which is lain's own, never
# the human's.
RSpec.describe Lain::CLI::EpicDriver::Factory, :seam do
  around do |example|
    Dir.mktmpdir("lain-epic-factory") do |dir|
      @root = File.realpath(dir)
      FileUtils.mkdir_p(repo)
      FileUtils.cp_r("#{SeedRepo.at({ "README" => "seed\n" })}/.", repo)
      FileUtils.cp_r(File.join(layout_mini, "."), repo)
      git(repo, "add", "-A")
      git(repo, "commit", "-q", "-m", "layout")
      git(repo, "branch", "-M", "main")
      FileUtils.mkdir_p(paths.sessions_dir)
      example.run
    end
  end

  let(:layout_mini) { File.expand_path("../../../fixtures/projects/layout_mini", __dir__) }
  let(:backend) { Lain::CLI::Backend.new({ provider: "ollama", model: nil, max_tokens: 64 }) }
  let(:hands_off) { Lain::Epic::STAGES.to_h { |stage| [stage, "hands_off"] } }
  let(:config) { Lain::Config.new(epics: Lain::Config::Epics.new(home: :xdg, gates: hands_off)) }
  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(@root, "state"), "HOME" => @root }) }
  let(:home) { Lain::Epic::Home.resolve(config:, paths:, root: repo, slug: "demo") }
  let(:log) { [] }
  let(:scrub) { Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB }

  def repo = File.join(@root, "repo")

  def shell(dir, *args)
    raise "refusing to run git outside the fixture: #{dir}" unless dir.start_with?("#{@root}/")

    Mixlib::ShellOut.new("git", "-C", dir, *args, environment: scrub).run_command
  end

  def git(dir, *) = shell(dir, *).tap(&:error!).stdout.strip

  def epic_branch = Lain::Isolation::WorkingBranch.epic("demo", repo_root: repo)

  def epic_tip = git(repo, "rev-parse", "refs/heads/epic/demo")

  def contains?(sha) = shell(repo, "merge-base", "--is-ancestor", sha, "refs/heads/epic/demo").exitstatus.zero?

  def issue(id, blocks: [], status: "in_flight")
    Lain::Epic::Issue.new(id:, title: "the #{id} issue", blocks:, status:,
                          criteria: "```gherkin\nScenario: s\n  Given g\n  When w\n  Then t\n```\n")
  end

  def write_epic(issues)
    home.write_epic(Lain::Epic::Graph.new(issues:))
    issues.each { |each| home.plan(each.id).write("Subject: app/models/order.rb\n\nthe plan for #{each.id}\n") }
  end

  def approve_plan(id)
    journaled(Lain::Approval::GateDecision.new(artifact_digest: approved_plan(id).digest, epic_slug: "demo",
                                               stage: "issue_plan", approved: true, answered_by: "human",
                                               policy: "hands_off", latency: 0.0, issue_id: id))
  end

  def approved_plan(id)
    Lain::Epic::Submission.issue_plan(text: home.plan(id).read, slug: "demo", issue_id: id,
                                      criteria_digest: home.read_epic.fetch(id).criteria_digest)
  end

  def journaled(decision)
    File.open(File.join(paths.sessions_dir, "fixture.ndjson"), "a") do |io|
      Lain::Journal.new(io:, clock: -> { "2026-01-01T00:00:00Z" }).record(decision)
    end
  end

  def chronicle
    @chronicle ||= Lain::CLI::Chronicle.new(
      journal: Lain::Journal.new(io: File.open(File.join(paths.sessions_dir, "chat.ndjson"), "ab"))
    )
  end

  def toolset_build = built(unbuilt)

  def unbuilt
    Lain::CLI::Wiring::ToolsetBuild.new(
      backend:, provider: Lain::Provider::Mock.new(responses: []), chronicle: Lain::CLI::Chronicle::Null.new,
      options: {}, supervisor: Lain::Supervisor.new, parent: -> { Lain::Timeline.empty(store: Lain::Store.new) },
      journal: Lain::Channel::Null.instance, library: backend.library, epic: Lain::CLI::EpicMount::NoEpic,
      root: repo, switchboard: -> { SpecNulls::NoSwitchboard }, askers: SpecNulls::UnwiredAskers.build
    )
  end

  def built(build)
    build.tap do |unbuilt|
      unbuilt.build(Lain::Memory::Recorder.new,
                    ask_human: Lain::Tools::AskHuman.new(parent: -> { Lain::Timeline.new }))
    end
  end

  def mount
    Lain::CLI::EpicMount.for(chronicle: Lain::CLI::Chronicle::Null.new, options: { epic: "demo" },
                             told: ->(_text) {}, root: repo, paths:, config:)
  end

  def factory_over(mounted, actors: nil, record: Lain::CLI::Chronicle::Null.new, grading: nil)
    described_class.for(mount: mounted, chronicle: record, paths:, root: repo, library: backend.library,
                        journal: Lain::Channel::Null.instance, toolset_build:, asker: nil, config:, actors:,
                        **(grading ? { grading: } : {}))
  end

  # The loop, over real git, with scripted actors in real leased checkouts.
  def driven(width: 2, grading: nil)
    factory_over(mount, actors: ->(fleet) { FactorySpecActors.new(fleet, log, repo, scrub) },
                        record: chronicle, grading:).run(width:)
  end

  # What a chat lends the epic it is seated in. The grading hook has to ride
  # these seams, or the hook the driver now owns is unreachable from the one
  # object a caller outside the chat actually holds.
  describe "Seams#driver" do
    let(:conductor) { Class.new { def closed? = false }.new }

    # The epic has to exist before the seams resolve one: an unmounted seat
    # answers Factory::Unmounted, which carries no seams to inspect.
    before { write_epic([issue("a")]) }

    def seams_with(**over)
      Lain::CLI::EpicDriver::Seams.new(mount:, paths:, journal: Lain::Channel::Null.instance,
                                       toolset_build:, asker: nil, conductor:, **over)
    end

    def driver_from(seams)
      seams.driver(root: repo, library: backend.library, chronicle: Lain::CLI::Chronicle::Null.new)
    end

    it "carries a grading seam through to the factory it builds" do
      seam = ->(_issue_id, _row) { :graded }

      factory = driver_from(seams_with(grading: seam))

      expect(factory.instance_variable_get(:@optional).fetch(:grading)).to be(seam)
    end

    # An ordinary chat lends no grader, and must stay byte-identical: the
    # driver's own Null is what grades nothing.
    it "lends no grading seam by default" do
      factory = driver_from(seams_with)

      expect(factory.instance_variable_get(:@optional).fetch(:grading)).to be_nil
    end
  end

  describe "with no epic mounted" do
    # A refusing Null, never nil: no command ever writes `if env.epic_driver`.
    it "answers a Null that refuses by name, telling the human to mount one" do
      driver = factory_over(Lain::CLI::EpicMount::NoEpic)

      expect(driver).not_to be_mounted
      expect { driver.run }.to raise_error(Lain::Error, /this chat is in no epic/)
    end

    # The Null answers the WHOLE published surface. A caller reaching for the
    # isolation or the supervisor must hear the same named refusal as one
    # reaching for #run, never a NoMethodError.
    it "refuses every published reader by name, rather than answering none of them" do
      driver = factory_over(Lain::CLI::EpicMount::NoEpic)

      %i[isolation retirement supervisor attempts].each do |reader|
        expect { driver.public_send(reader) }.to raise_error(Lain::Error, /this chat is in no epic/)
      end
      expect(driver.slug).to be_nil
    end
  end

  describe "with an epic mounted" do
    before { write_epic([issue("a")]) }

    it "names the epic the seat resolved" do
      expect(factory_over(mount)).to be_mounted.and(have_attributes(slug: "demo"))
    end

    it "leases from a worktree backend cut from the epic's working branch" do
      isolation = factory_over(mount).isolation

      expect(isolation).to be_a(Lain::Isolation::Worktree)
      expect(isolation.base.name).to eq("epic/demo")
      expect(isolation.repo_root).to eq(repo)
      expect(git(repo, "rev-parse", "refs/lain/owned/heads/epic/demo")).to eq(git(repo, "rev-parse", "main"))
    end

    it "cuts no working branch until it is asked for one" do
      factory_over(mount)

      expect(shell(repo, "rev-parse", "--verify", "--quiet", "refs/heads/epic/demo").exitstatus).not_to eq(0)
    end

    it "retires actors through an anchor-only retirement over that same backend" do
      factory = factory_over(mount)

      expect(factory.retirement).to be_a(Lain::Isolation::Worktree::Handback::Retirement)
      expect(factory.supervisor).to be_a(Lain::Supervisor)
      expect(factory.supervisor).not_to be_running
    end

    it "builds a fresh supervisor per run" do
      expect(factory_over(mount).supervisor).not_to equal(factory_over(mount).supervisor)
    end
  end

  # THE ATTEMPT IS DERIVED FROM THE REPOSITORY, not carried between runs: the
  # next attempt is one past the highest anchor an earlier attempt left
  # standing, so a retry after a failed run launches instead of being refused.
  describe "the attempt an issue's next launch takes" do
    before { write_epic([issue("a")]) }

    it "is the first with no anchor standing" do
      expect(factory_over(mount).attempts.call("a")).to eq(1)
    end

    it "steps past every attempt whose anchor still stands" do
      %w[1 2].each do |n|
        ref = Lain::Isolation::Worktree::Handback::Naming.new("issue.demo.a.#{n}").ref
        git(repo, "update-ref", ref, git(repo, "rev-parse", "main"))
      end

      expect(factory_over(mount).attempts.call("a")).to eq(3)
    end
  end

  # THE DRIVER LANDS IN ITS OWN CHECKOUT. The landing queue refuses unless the
  # checkout it merges in stands on the epic's branch, and a human's chat
  # stands wherever they left it -- so lain cuts a worktree of its own rather
  # than switching the branch under somebody's feet.
  describe "the whole loop over real git" do
    it "lands a two-issue chain in order, from a chat standing on main" do
      write_epic([issue("a", blocks: ["b"]), issue("b")])
      %w[a b].each { |id| approve_plan(id) }
      git(repo, "switch", "-q", "main")
      head = git(repo, "rev-parse", "HEAD")

      result = driven

      expect(result.reported).to be_empty
      expect(result.landed.map(&:issue_id)).to eq(%w[a b])
      result.landed.each { |landed| expect(contains?(landed.sha)).to be(true) }
      expect(log.select { |row| row.first == :launched }.map { |row| row[1] }).to eq(%w[a b])
      # The human's checkout is untouched: same branch, same commit, clean.
      expect(git(repo, "symbolic-ref", "HEAD")).to eq("refs/heads/main")
      expect(git(repo, "rev-parse", "HEAD")).to eq(head)
      expect(git(repo, "status", "--porcelain")).to eq("")
    end

    # b is cut from the epic's tip AFTER a landed, so the second issue's worker
    # actually builds on the first's work rather than beside it.
    it "cuts the second issue's checkout from the tip the first one landed on" do
      write_epic([issue("a", blocks: ["b"]), issue("b")])
      %w[a b].each { |id| approve_plan(id) }
      git(repo, "switch", "-q", "main")

      result = driven

      leased = log.select { |row| row.first == :leased }.find { |row| row[1] == "b" }
      expect(leased[2]).to eq(result.landed.first.sha).or eq(epic_tip)
    end

    it "still lands when the chat's checkout already stands on the epic branch" do
      write_epic([issue("a")])
      approve_plan("a")
      epic_branch
      git(repo, "switch", "-q", "epic/demo")

      result = driven(width: 1)

      expect(result.landed.map(&:issue_id)).to eq(["a"])
      expect(contains?(result.landed.first.sha)).to be(true)
    end

    # The hook a bench binds its grader to, over real leases. Retirement
    # anchors, stops the actor and releases its lease -- which REMOVES the
    # checkout -- so a grader that runs the subject's own suite has exactly one
    # moment: after the actor settled, before it is retired. Asserting the
    # actor's own committed file is readable at that moment proves both halves,
    # the work being visible and the checkout still being there.
    it "grades each issue in its own leased checkout, before retirement releases it" do
      write_epic([issue("a", blocks: ["b"]), issue("b")])
      %w[a b].each { |id| approve_plan(id) }
      git(repo, "switch", "-q", "main")
      graded = []
      seam = lambda do |issue_id, row|
        checkout = row.lease.worker_env.cwd
        graded << { issue: issue_id, standing: Dir.exist?(checkout),
                    work: File.exist?(File.join(checkout, "#{issue_id}.txt")) }
      end

      result = driven(grading: seam)

      expect(result.landed.map(&:issue_id)).to eq(%w[a b])
      expect(graded.map { |row| row[:issue] }).to eq(%w[a b])
      expect(graded.map { |row| row[:standing] }).to all(be(true))
      expect(graded.map { |row| row[:work] }).to all(be(true))
    end

    # NOTHING IS LEASED FOR AN ISSUE THAT CANNOT HAVE FAILING TESTS. The red
    # step writes tests for the ONE source file the plan names, so a plan that
    # names none is refused where the plan is read -- before an actor, a
    # checkout or a branch exists. The refusal is the issue's, and the run goes
    # on carrying whatever else it can.
    it "refuses an issue whose plan declares no subject, and spawns no actor for it" do
      write_epic([issue("a")])
      home.plan("a").write("the plan for a, with no subject line\n")
      approve_plan("a")
      git(repo, "switch", "-q", "main")

      result = driven(width: 1)

      expect(result.landed).to be_empty
      expect(result.reported.map(&:issue_id)).to eq(["a"])
      expect(result.reported.first.reason).to include("declares no test subject")
      expect(log).to be_empty
    end

    # One writer for pending -> in_flight, and it is the plan approval. An
    # issue the fold still calls pending is reported, never launched -- the
    # landing would refuse it anyway.
    it "reports a pending issue and launches nothing for it" do
      write_epic([issue("a", status: "pending")])
      approve_plan("a")
      git(repo, "switch", "-q", "main")

      result = driven(width: 1)

      expect(result.landed).to be_empty
      expect(result.reported.map(&:issue_id)).to eq(["a"])
      expect(log).to be_empty
    end
  end
end
