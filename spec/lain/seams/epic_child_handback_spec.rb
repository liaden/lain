# frozen_string_literal: true

require "fileutils"
require "json"
require "mixlib/shellout"
require "tmpdir"

# An issue orchestrator's children lease from the ISSUE's isolation, hand back
# into the issue's checkout, and anchor under ids no other lane can spell.
# Real git end to end, over one repository with two issue checkouts: an
# orchestrator actor standing in an issue's checkout spawns a dev child, which
# commits in a worktree cut from that issue's branch, and the commit comes
# home onto that branch while the chat's branch never moves.
RSpec.describe Lain::CLI::Wiring::ToolsetBuild, "an issue orchestrator's children", :seam do
  around do |example|
    Dir.mktmpdir("lain-epic-child") do |dir|
      @root = File.realpath(dir)
      @repo = File.join(@root, "repo")
      FileUtils.mkdir_p(@repo)
      FileUtils.cp_r("#{SeedRepo.at({ "seed.txt" => "seed\n" })}/.", @repo)
      %w[a b].each { |id| git(@repo, "worktree", "add", "-q", "-b", "issue-#{id}", checkout(id)) }
      example.run
    end
  end

  let(:backend) { Lain::CLI::Backend.new({ provider: "ollama", model: nil, max_tokens: 64 }) }
  let(:recorder) { Lain::Memory::Recorder.new }
  let(:ask_human) { Lain::Tools::AskHuman.new(parent: -> { Lain::Timeline.new }) }
  let(:provider) { Lain::Provider::Mock.new(responses: %w[a b].flat_map { |id| plan_turns(id) }) }
  let(:build) do
    described_class.new(backend:, provider:, chronicle: Lain::CLI::Chronicle::Null.new, options: {},
                        supervisor: Lain::Supervisor.new, parent: -> { Lain::Timeline.empty(store: Lain::Store.new) },
                        journal: Lain::Channel::Null.instance, library: backend.library,
                        epic: Lain::CLI::EpicMount::NoEpic, root: @repo,
                        switchboard: -> { SpecNulls::NoSwitchboard }, askers: SpecNulls::UnwiredAskers.build)
  end

  def git(dir, *args)
    shell = Mixlib::ShellOut.new("git", "-C", dir, *args, environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
    shell.run_command.error!
    shell.stdout.strip
  end

  def checkout(id) = File.join(@root, "issue-#{id}")

  def children(name) = File.join(@root, "children-#{name}").tap { |dir| FileUtils.mkdir_p(dir) }

  # What the issue-actor card hands in: a Worktree cut from the issue's branch,
  # and a handoff into the issue's checkout, both over that one branch.
  def issue_lane(id)
    branch = Lain::Isolation::WorkingBranch.checked_out(repo_root: checkout(id))
    { isolation: Lain::Isolation::Worktree.new(root: children(id), repo_root: checkout(id), base: branch),
      handoff: Lain::Isolation::WorkerHandoff.over(repo_root: checkout(id), base: branch) }
  end

  def anchors
    git(@repo, "for-each-ref", "--format=%(refname) %(objectname)", "refs/lain/worker/").split("\n").to_h(&:split)
  end

  def plan_turns(id)
    [tool_response(["o1", "subagent", { "prompt" => "implement it", "role" => "dev" }]),
     tool_response(["b1", "bash", { "command" => guarded_commit(id) }]),
     text_response("dev done"), text_response("plan done")]
  end

  # The dev child's shell command. It refuses outside the fixture's temp tree,
  # so a child leased from the wrong lane -- the process's own cwd, which is
  # the repository running this suite -- fails instead of committing there.
  # The git context is scrubbed for the hook's GIT_INDEX_FILE reason.
  def guarded_commit(id)
    "case \"$(pwd -P)\" in #{@root}/*) ;; *) echo \"refusing outside the fixture: $(pwd -P)\" >&2; exit 1;; esac; " \
      "printf 'dev #{id}\\n' > dev.txt && " \
      "env -u GIT_INDEX_FILE -u GIT_DIR -u GIT_WORK_TREE sh -c 'git add dev.txt && git commit -q -m \"dev work #{id}\"'"
  end

  def run_plan(id)
    epic = build.epic_subagent(**issue_lane(id), lane: "issue.demo.#{id}")
    Sync do
      actor = epic.launch_actor("run the plan", worker_env: Lain::WorkerEnv.default.with(cwd: checkout(id)))
      actor.settle
    ensure
      actor&.stop
    end
  end

  # The same guard as the dev child's: this spec's own commits land only in
  # the fixture's temp tree.
  def commit_in(dir, name)
    raise "refusing to commit in #{dir}" unless dir.start_with?("#{@root}/")

    File.write(File.join(dir, "#{name}.txt"), "#{name}\n")
    git(dir, "add", "#{name}.txt")
    git(dir, "commit", "-q", "-m", "#{name} work")
    git(dir, "rev-parse", "HEAD")
  end

  def fleet_of(messages)
    path = File.join(@root, "state.json")
    feed = Lain::StatusFeed.new(path:)
    messages.each { |message| feed << message }
    JSON.parse(File.read(path))["fleet"]
  end

  # Both actors are launched from the chat's one head by two writers, so only
  # the lane tells their spawns apart; sharing an address, retiring one would
  # take its live sibling out of the fleet too.
  it "gives two issues' actors, launched from one chat head, two places in the fleet" do
    journal = Lain::Channel.new
    replies = Lain::Provider::Mock.new(responses: [text_response("a"), text_response("b")])
    fleet = described_class.new(backend:, provider: replies,
                                chronicle: Lain::CLI::Chronicle::Null.new, options: {}, supervisor: Lain::Supervisor.new,
                                parent: -> { Lain::Timeline.empty(store: Lain::Store.new) }, journal:,
                                library: backend.library, epic: Lain::CLI::EpicMount::NoEpic, root: @repo,
                                switchboard: -> { SpecNulls::NoSwitchboard },
                                askers: SpecNulls::UnwiredAskers.build)
    fleet.build(recorder, ask_human:)
    epics = %w[a b].map { |id| fleet.epic_subagent(**issue_lane(id), lane: "issue.demo.#{id}") }

    Sync do |task|
      supervisor = Lain::Supervisor.new(journal:).run(task)
      a, b = epics.map do |epic|
        supervisor.adopt(role: "issue_orchestrator") { |worker_env| epic.launch_actor("run", worker_env:) }
      end
      supervisor.retire(supervisor.find { |row| row.actor.equal?(a) })

      expect(a.address).not_to eq(b.address)
      expect(fleet_of(journal.drain.grep(Lain::Telemetry::Message))).to eq([b.address])
    ensure
      supervisor&.stop
    end
  end

  it "lands a grandchild's commit on the issue's branch, and never moves the chat's" do
    chat_tip = git(@repo, "rev-parse", "HEAD")
    build.build(recorder, ask_human:)

    run_plan("a")

    expect(git(checkout("a"), "log", "-1", "--format=%s")).to eq("dev work a")
    expect(git(checkout("a"), "show", "issue-a:dev.txt")).to eq("dev a")
    expect(git(@repo, "rev-parse", "HEAD")).to eq(chat_tip)
    expect(git(@repo, "status", "--porcelain")).to eq("")
  end

  # Each issue's dev child is worker 1 of its own lane, and every worktree of
  # the repository shares one refs/lain/worker/ namespace.
  it "anchors two issues' worker 1 under distinct refs, and both survive" do
    build.build(recorder, ask_human:)

    run_plan("a")
    run_plan("b")

    expect(anchors.values).to contain_exactly(git(@repo, "rev-parse", "issue-a"), git(@repo, "rev-parse", "issue-b"))
    expect(anchors.keys).to all(include("issue.demo."))
  end

  it "gives a chat child and an epic child, both worker 1, distinct anchors that both survive" do
    chat_branch = Lain::Isolation::WorkingBranch.checked_out(repo_root: @repo)
    chat = Lain::Tools::Subagent::Leases.new(
      backend: Lain::Isolation::Worktree.new(root: children("chat"), repo_root: @repo, base: chat_branch),
      handoff: Lain::Isolation::WorkerHandoff.over(repo_root: @repo, base: chat_branch)
    )
    lane = issue_lane("a")
    epic = Lain::Tools::Subagent::Leases.new(backend: lane[:isolation], handoff: lane[:handoff],
                                             lane: Lain::Tools::Subagent::Leases::Lane.named("issue.demo.a"))

    commits = [[chat, "chat"], [epic, "epic"]].map do |leases, name|
      leases.hold("subagent", journal: Lain::Channel::Null.instance) { |worker_env, _sync| commit_in(worker_env.cwd, name) }
            .value
    end

    expect(anchors.values).to match_array(commits)
  end
end
