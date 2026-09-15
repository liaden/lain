# frozen_string_literal: true

require "fileutils"
require "mixlib/shellout"
require "socket"
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

# Scripted actors: each leases a real checkout from the epic's own supervisor,
# makes a red commit there the way the red step does, and commits its work on
# top -- which is what gives the loop something real to anchor, gate and land.
# An issue named in `idle` commits nothing past its red commit.
class FactorySpecActors
  Launch = Data.define(:actor, :worker_id, :branch, :tests)

  def initialize(fleet, log, repo, scrub, files: {}, idle: [])
    @fleet = fleet
    @log = log
    @repo = repo
    @scrub = scrub
    @files = files
    @idle = idle
  end

  def call(issue_id, subject:, level: nil, attempt: 1) # rubocop:disable Lint/UnusedMethodArgument
    @log << [:launched, issue_id, attempt, git(@repo, "rev-parse", "refs/heads/epic/demo")]
    red = nil
    actor = @fleet.adopt(role: "factory-spec", worker_id: "issue.demo.#{issue_id}.#{attempt}") do |worker_env|
      @log << [:leased, issue_id, git(worker_env.cwd, "rev-parse", "HEAD")]
      red = commit(worker_env.cwd, "red for #{issue_id}", "red_#{issue_id}.txt" => "red for #{issue_id}\n")
      commit(worker_env.cwd, "work for #{issue_id}", "#{issue_id}.txt" => "work for #{issue_id}\n", **@files) unless
        @idle.include?(issue_id)
      FactorySpecActor.new(worker_env)
    end
    Launch.new(actor:, worker_id: "issue.demo.#{issue_id}.#{attempt}", branch: "lain/issue/demo/#{issue_id}",
               tests: Lain::CLI::EpicDriver::IssueTests::Red.new(record: nil, run: nil, sha: red))
  end

  private

  def commit(dir, message, files)
    files.each do |path, body|
      FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
      File.write(File.join(dir, path), body)
    end
    git(dir, "add", "-A")
    git(dir, "commit", "-q", "-m", message)
    git(dir, "rev-parse", "HEAD")
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
  let(:provider) { Lain::Provider::Mock.new(responses: []) }

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
      backend:, provider:, chronicle: Lain::CLI::Chronicle::Null.new,
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
  def driven(width: 2, grading: nil, files: {}, idle: [])
    factory_over(mount, actors: ->(fleet) { FactorySpecActors.new(fleet, log, repo, scrub, files:, idle:) },
                        record: chronicle, grading:).run(width:)
  end

  def worktree_root = Lain::CLI::IsolationBackend.worktree_root(repo, paths:)

  def landing_checkout = File.join(worktree_root, described_class::LANDING)

  # The lock line git reports for a registered checkout, "" when it holds none.
  def lock_of(dir)
    git(repo, "worktree", "list", "--porcelain").split("\n\n")
                                                .find { |entry| entry.start_with?("worktree #{dir}\n") }
                                                .to_s[/^locked.*$/].to_s
  end

  # The project's config, untracked and ignored the way a project keeping its
  # lain settings out of history would: no checkout git cuts carries it.
  def ignore_config
    File.write(File.join(repo, ".gitignore"), ".lain/config.toml\n")
    git(repo, "rm", "-q", "--cached", ".lain/config.toml")
    git(repo, "add", ".gitignore")
    git(repo, "commit", "-q", "-m", "keep the lain config out of history")
  end

  def journaled_decisions
    Lain::Journal.records(File.readlines(File.join(paths.sessions_dir, "chat.ndjson")),
                          type: Lain::Approval::SignoffQueue::JOURNAL_TYPE).to_a
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

    # THE LAYOUT IS THE PROJECT'S. Lain's landing checkout is cut by git, so a
    # gitignored .lain/config.toml never reaches it -- and read there, the
    # layout guard checked nothing and a misplaced test landed.
    it "refuses at landing a misplaced test, under a layout only the gitignored project config declares" do
      ignore_config
      write_epic([issue("a")])
      approve_plan("a")

      result = driven(width: 1, files: { "spec/order_extra_spec.rb" => "RSpec.describe Order do\nend\n" })

      expect(result.landed).to be_empty
      expect(result.reported.map(&:issue_id)).to eq(["a"])
      expect(result.reported.first.reason).to include("spec/order_extra_spec.rb", "spec/unit/models/order_spec.rb")
      expect(git(repo, "ls-tree", "-r", "--name-only", "refs/heads/epic/demo")).not_to include("order_extra_spec")
    end

    # A live landing checkout is lain's to merge in, and the lock is how gc
    # outside this process knows it: judged unlocked, a checkout whose HEAD the
    # queue moved reads as work folded into the epic, and is reaped mid-run.
    it "holds its landing checkout locked while it runs, so gc keeps it, and releases it when the run ends" do
      write_epic([issue("a")])
      approve_plan("a")
      judged = []
      seam = lambda do |_issue_id, _row|
        judged.concat(Lain::Isolation::Gc.new(repo_root: repo, root: worktree_root, retain_days: 7).call.to_a)
      end

      result = driven(width: 1, grading: seam)

      expect(result.landed.map(&:issue_id)).to eq(["a"])
      landing = judged.find { |record| record.name == landing_checkout }
      expect(landing).to have_attributes(action: :kept,
                                         reason: "leased by live process #{Process.pid} on #{Socket.gethostname}")
      expect(lock_of(landing_checkout)).to eq("")
    end

    # Ctrl-C arrives as an Interrupt wherever the run happens to be, which no
    # issue's rescue catches: the lock is dropped on the way out all the same.
    it "releases its landing checkout's lock when the run is interrupted" do
      write_epic([issue("a")])
      approve_plan("a")

      expect { driven(width: 1, grading: ->(*) { raise Interrupt }) }.to raise_error(Interrupt)
      expect(Dir.exist?(landing_checkout)).to be(true)
      expect(lock_of(landing_checkout)).to eq("")
    end

    it "reuses an earlier run's landing checkout, locking it again for the run that takes it" do
      write_epic([issue("a"), issue("b")])
      approve_plan("a")
      locks = []
      seam = ->(*) { locks << lock_of(landing_checkout) }

      driven(width: 1, grading: seam)
      approve_plan("b")
      driven(width: 1, grading: seam)

      expect(locks.size).to eq(2)
      expect(locks).to all(include("lain-lease pid=#{Process.pid}"))
      expect(lock_of(landing_checkout)).to eq("")
    end

    # Retirement rebases an actor's branch onto the epic's tip, and at width 2
    # a sibling can land first: the red commit comes back under a new SHA, so
    # only its content can say the actor added nothing to it.
    it "reports an issue that committed nothing past its red commit, even rebased past a sibling's landing" do
      write_epic([issue("a"), issue("b")])
      %w[a b].each { |id| approve_plan(id) }

      result = driven(width: 2, idle: ["b"])

      expect(result.landed.map(&:issue_id)).to eq(["a"])
      expect(result.reported.map(&:issue_id)).to eq(["b"])
      expect(result.reported.first.reason).to include("committed no work")
      expect(journaled_decisions.select { |decision| decision["stage"] == "implementation" }
                                .map { |decision| decision["issue_id"] }).to eq(["a"])
      expect(git(repo, "ls-tree", "-r", "--name-only", "refs/heads/epic/demo").split("\n")).not_to include("red_b.txt")
    end

    # The same rebase, over an issue that did commit work: its rebased red
    # commit matches, its work does not, and the work is what lands.
    it "still gates and lands a rebased issue whose work goes past its red commit" do
      write_epic([issue("a"), issue("b")])
      %w[a b].each { |id| approve_plan(id) }

      result = driven(width: 2)

      expect(result.reported).to be_empty
      expect(result.landed.map(&:issue_id)).to eq(%w[a b])
      expect(git(repo, "ls-tree", "-r", "--name-only", "refs/heads/epic/demo").split("\n"))
        .to include("a.txt", "b.txt", "red_b.txt")
    end

    # A config edited between two issues must not judge the second issue's plan
    # under a layout its red step never wrote under.
    it "resolves the project's layout once per run, however many issues it carries" do
      write_epic([issue("a"), issue("b")])
      %w[a b].each { |id| approve_plan(id) }
      allow(Lain::Config).to receive(:test_layout).and_call_original

      result = driven(width: 1)

      expect(result.landed.map(&:issue_id)).to eq(%w[a b])
      expect(Lain::Config).to have_received(:test_layout).once
    end

    # A lock that still holds is somebody else's run, or a human's: breaking
    # it would put two landings in one checkout.
    it "refuses to merge in a landing checkout something else still holds, and leaves that lock alone" do
      write_epic([issue("a")])
      approve_plan("a")
      driven(width: 1)
      git(repo, "worktree", "lock", "--reason", "a human's", landing_checkout)

      expect { driven(width: 1) }.to raise_error(Lain::Error, /landing checkout .*a human's/)
      expect(lock_of(landing_checkout)).to eq("locked a human's")
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

    # Scenario: the driver will not start issues over an unreadable sign-off.
    # Torn after the chat mounted: a mount over the torn line already costs
    # the chat its epic, and says which line, at startup.
    it "refuses to start over a torn issue_plan sign-off, naming the file, and launches nothing" do
      write_epic([issue("a")])
      approve_plan("a")
      git(repo, "switch", "-q", "main")
      factory = factory_over(mount, actors: ->(fleet) { FactorySpecActors.new(fleet, log, repo, scrub) },
                                    record: chronicle)
      path = File.join(paths.sessions_dir, "fixture.ndjson")
      File.write(path, File.read(path).then { |line| line[0, line.size / 2] })

      expect { factory.run(width: 1) }
        .to raise_error(Lain::CLI::SessionJournals::Unreadable, /fixture\.ndjson.*line 1/)
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

  # The production launch: the real IssueActor, whose red step's test_engineer
  # and whose actor share one scripted provider. The actor answers once and
  # commits nothing, so the red step's commit is all its retirement anchors.
  describe "the red step, over a gitignored project config" do
    let(:target) { "spec/unit/models/order_spec.rb" }
    let(:red) do
      "# frozen_string_literal: true\n\nrequire_relative \"../../../app/models/order\"\n\n" \
        "RSpec.describe Order do\n  it(\"totals its lines\") { expect(Order.new.total).to eq(3) }\nend\n"
    end
    let(:provider) do
      Lain::Provider::Mock.new(responses: [
                                 tool_response(["m1", "bash", { "command" => guarded("mkdir -p spec/unit/models") }]),
                                 tool_response(["w1", "write_file", { "path" => target, "content" => red }]),
                                 text_response("wrote the spec"), text_response("plan done")
                               ])
    end

    def guarded(command)
      "case \"$(pwd -P)\" in #{@root}/*) ;; *) echo \"refusing outside the fixture: $(pwd -P)\" >&2; exit 1;; " \
        "esac; #{command}"
    end

    # A Gemfile, so the suite runner the red step detects is rspec's.
    it "writes the generated tests, and reports an actor that committed nothing past them without a gate" do
      File.write(File.join(repo, "Gemfile"), "source \"https://rubygems.org\"\n")
      git(repo, "add", "Gemfile")
      ignore_config
      write_epic([issue("a")])
      approve_plan("a")
      git(repo, "switch", "-q", "main")

      result = factory_over(mount, record: chronicle).run(width: 1)

      anchor = Lain::Isolation::Worktree::Handback::Naming.new("issue.demo.a.1").ref
      expect(git(repo, "show", "--name-only", "--format=", anchor).split("\n")).to eq([target])
      expect(result.landed).to be_empty
      expect(result.reported.map(&:issue_id)).to eq(["a"])
      expect(result.reported.first.reason).to include("committed no work")
      expect(journaled_decisions.map { |decision| decision["stage"] }).not_to include("implementation")
    end
  end

  # WHETHER AN ACTOR COMMITTED WORK IS A QUESTION ABOUT THE NET DIFF. b makes
  # its red commit at launch and then, while graded after a has landed, does
  # one thing to its branch; the answer has to follow what the branch would
  # change on the epic, not how its history happens to be shaped.
  describe "judging whether an actor committed work past its red commit" do
    def sh(dir, *) = git(dir, *)

    def red_b = "red for b\n"

    def retired_b(width: 2, files_a: {}, &behaviour)
      write_epic([issue("a"), issue("b")])
      %w[a b].each { |id| approve_plan(id) }
      seam = ->(issue_id, row) { yield(row.lease.worker_env.cwd) if issue_id == "b" }
      result = driven(width:, grading: seam, idle: ["b"], files: files_a)
      [result, journaled_decisions.select { |decision| decision["stage"] == "implementation" }
                                  .map { |decision| decision["issue_id"] }]
    end

    def epic_files = git(repo, "ls-tree", "-r", "--name-only", "refs/heads/epic/demo").split("\n")

    def expect_no_work(result, gated)
      expect(result.reported.map(&:issue_id)).to eq(["b"])
      expect(result.reported.first.reason).to include("committed no work")
      expect(gated).to eq(["a"])
      expect(epic_files).not_to include("red_b.txt")
    end

    def expect_gated(gated) = expect(gated).to eq(%w[a b])

    it "calls a revert of the red commit followed by the same patch again no work" do
      result, gated = retired_b do |dir|
        sh(dir, "revert", "--no-edit", "HEAD")
        File.write(File.join(dir, "red_b.txt"), red_b)
        sh(dir, "add", "-A")
        sh(dir, "commit", "-q", "-m", "re-add red")
      end

      expect_no_work(result, gated)
    end

    it "calls an empty commit on top of the red commit no work" do
      result, gated = retired_b { |dir| sh(dir, "commit", "-q", "--allow-empty", "-m", "nothing") }

      expect_no_work(result, gated)
    end

    it "calls a red commit amended in its message alone no work" do
      result, gated = retired_b { |dir| sh(dir, "commit", "-q", "--amend", "-m", "renamed red") }

      expect_no_work(result, gated)
    end

    # a's landing writes red_b.txt differently, so b's rebase conflicts and its
    # unrebased red commit is what retirement anchors.
    it "calls an idle actor whose rebase conflicted on its red file no work" do
      result, gated = retired_b(files_a: { "red_b.txt" => "a's conflicting content\n" }) { |_dir| nil }

      expect(result.reported.map(&:issue_id)).to eq(["b"])
      expect(result.reported.first.reason).to include("committed no work")
      expect(gated).to eq(["a"])
    end

    it "gates and lands real work committed inside a merge of the epic's tip" do
      result, gated = retired_b do |dir|
        sh(dir, "merge", "-q", "--no-ff", "--no-commit", "refs/heads/epic/demo")
        File.write(File.join(dir, "merged.txt"), "work done in the merge\n")
        sh(dir, "add", "-A")
        sh(dir, "commit", "-q", "-m", "merge with work")
      end

      expect_gated(gated)
      expect(result.landed.map(&:issue_id)).to eq(%w[a b])
      expect(epic_files).to include("merged.txt")
    end

    it "gates work squashed into the red commit" do
      result, gated = retired_b do |dir|
        File.write(File.join(dir, "b.txt"), "b's work\n")
        sh(dir, "add", "-A")
        sh(dir, "commit", "-q", "--amend", "-m", "red for b")
      end

      expect_gated(gated)
      expect(result.landed.map(&:issue_id)).to eq(%w[a b])
    end

    # Rewriting the failing tests is not an implementation, but it is a change
    # a human has to see: the gate is where they see it.
    it "gates a red commit amended to rewrite its tests" do
      _result, gated = retired_b do |dir|
        File.write(File.join(dir, "red_b.txt"), "weakened\n")
        sh(dir, "commit", "-q", "-a", "--amend", "-m", "red for b")
      end

      expect_gated(gated)
    end

    it "gates work committed past a red file whose rebase conflicted" do
      _result, gated = retired_b(files_a: { "red_b.txt" => "a's conflicting content\n" }) do |dir|
        File.write(File.join(dir, "b.txt"), "b's work\n")
        sh(dir, "add", "-A")
        sh(dir, "commit", "-q", "-m", "b work")
      end

      expect_gated(gated)
    end
  end

  # Two runs starting together after a crash both find the dead run's lock.
  # Taking it over has to be a compare-and-swap, or the one that judged it
  # second unlocks the first one's live lock and both merge in one checkout.
  describe "LandingCheckout taking over a dead lock" do
    let(:branch) { Lain::Isolation::WorkingBranch.epic("demo", repo_root: repo) }
    let(:sleepers) { Array.new(2) { Process.spawn("sleep", "60") } }

    after { sleepers.each { |pid| Process.kill("KILL", pid).then { Process.wait(pid) } } }

    def held_by(pid, shell_out_factory: Lain::Shell::Out.public_method(:new))
      described_class::LandingCheckout.new(repo_root: repo, path: landing_checkout, branch:, shell_out_factory:,
                                           process_table: Lain::Isolation::LeaseLock::ProcessTable.new(pid:))
    end

    # Runs `act` once, just after the first `git worktree list` the subject
    # reads, so the other run acts between this one's look and its take-over.
    def after_first_listing(&act)
      pending = [act]
      lambda do |*argv, **options|
        shell = Lain::Shell::Out.new(*argv, **options)
        interleaved = argv.include?("list") && pending.shift
        interleaved ? then_acting(shell, interleaved) : shell
      end
    end

    def then_acting(shell, act)
      shell.tap { |out| out.define_singleton_method(:run_command) { super().tap { act.call } } }
    end

    it "lets exactly one of two runs take it, and leaves the winner's lock standing" do
      described_class::LandingCheckout.new(repo_root: repo, path: landing_checkout, branch:).cut.release
      dead = Process.spawn("true").tap { |pid| Process.wait(pid) }
      git(repo, "worktree", "lock", "--reason", "lain-lease pid=#{dead} start=1 host=#{Socket.gethostname}",
          landing_checkout)
      second = held_by(sleepers.last)
      first = held_by(sleepers.first, shell_out_factory: after_first_listing { second.cut })

      expect { first.cut }.to raise_error(Lain::Error, /landing checkout/)
      expect(lock_of(landing_checkout)).to include("lain-lease pid=#{sleepers.last} ")
    end
  end
end
