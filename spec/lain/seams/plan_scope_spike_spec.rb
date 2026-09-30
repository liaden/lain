# frozen_string_literal: true

require "async"
require "fileutils"
require "mixlib/shellout"
require "stringio"
require "tmpdir"

# Plan scope end to end: `/mode plan` typed at the command, the board a real
# chat builds for its project, the tool stack the tool guard builds over that
# board, and a session whose tools run for real -- in a spike worktree cut by
# real git, or a scratch directory where there is no git at all.
RSpec.describe "Plan scope confines a session to a spike", :seam do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:chronicle) do
    instance_double(Lain::CLI::Chronicle, record_journal: journal,
                                          instrumentation: Lain::Agent::Instrumentation.new(journal:))
  end
  let(:toolset) { Lain::Toolset.new([Lain::Tools::WriteFile.new, Lain::Tools::Bash.new]) }

  around do |example|
    Dir.mktmpdir("lain-plan-scope") do |dir|
      @base = File.realpath(dir)
      @home = File.join(@base, "home").tap { FileUtils.mkdir_p(_1) }
      @repo = File.join(@base, "repo").tap { FileUtils.mkdir_p(_1) }
      example.run
    ensure
      @board&.mode_switch&.switch(Lain::Mode.new, surface: "spec")
    end
  end

  def seed_repo
    FileUtils.cp_r("#{SeedRepo.at({ "README.md" => "a readme\n" })}/.", @repo)
    FileUtils.mkdir_p(File.join(@repo, "lib"))
    File.write(File.join(@repo, "lib", "a.rb"), "committed\n")
    git("add", "lib/a.rb")
    git("commit", "-q", "-m", "lib")
  end

  # Scrubbed of any inherited GIT_INDEX_FILE, so a run inside a git hook reads
  # this repository's index and not the hook's.
  def git(*args, dir: @repo)
    Mixlib::ShellOut.new("git", "-C", dir, *args, environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
                    .run_command.tap(&:error!).stdout
  end

  def paths = Lain::Paths.new(env: { "HOME" => @home, "XDG_STATE_HOME" => File.join(@base, "state") })

  def project = Lain::Project.new(root: @repo, cwd:, kind: :project, detected_by: @detected_by || :git)

  def cwd = @cwd || @repo

  def session = @session ||= Lain::Session.new(worker_env: Lain::WorkerEnv.default.with(cwd:))

  def slot = @slot ||= Lain::Agent::SnapshotSlot.new(root: @repo, scope: :write_set)

  def board
    @board ||= Lain::CLI::Wiring::BoardBuild.for(
      chronicle:, options: {}, model: "m", toolset:, project:, paths:,
      verdict: Lain::CLI::Wiring::BoardBuild.shell_verdict(project:)
    ).bind_session(session).tap { _1.bind_snapshots(slot) }
  end

  def mode(args, dispatching: false)
    env = instance_double(Lain::CLI::Command::Env, mode_switch: board.mode_switch,
                                                   agent: instance_double(Lain::Agent, dispatching?: dispatching))
    Lain::CLI::Command::Mode.new.call(args, env)
  end

  def stack = Lain::CLI::ToolGuard.stack(chronicle, board).to_a

  def dispatch(name, input) = dispatch_call(name, input, toolset:, layers: stack, context: session)

  def spike = session.scope.root

  # A command every rung left open waits on the board's queue: the human
  # answers `verdict`, and what the call returned comes back.
  def answered(name, input, verdict)
    Sync do |task|
      call = task.async { dispatch(name, input) }
      pending = task.with_timeout(10) { board.approvals.dequeue }
      verdict == :approve ? pending.approve(surface: "tty") : pending.deny(surface: "tty")
      [pending, call.wait]
    end
  end

  def rulings = Lain::Journal.records(journal_io.string.lines, type: "escalation").to_a

  def plan_branches
    git("for-each-ref", "--format=%(refname)", "refs/heads/lain/plan/",
        "refs/lain/owned/heads/lain/plan/").split
  end

  # The spawn wiring a chat builds over this board, with a child that writes
  # what `provider` scripts.
  def role_spawn(provider)
    backend = Lain::CLI::Backend.new({ provider: "ollama", model: nil, max_tokens: 64 }, root: Dir.pwd)
    the_board = board
    build = Lain::CLI::Wiring::ToolsetBuild.new(
      backend:, provider:, chronicle: Lain::CLI::Chronicle::Null.new, options: {}, parent: -> { Lain::Timeline.empty },
      supervisor: Lain::Supervisor.new(journal:), journal:, library: backend.library, root: @repo,
      epic: Lain::CLI::EpicMount::NoEpic, switchboard: -> { the_board }, askers: SpecNulls::UnwiredAskers.build
    )
    build.build(Lain::Memory::Recorder.new, ask_human: Lain::Tools::AskHuman.new(parent: -> { Lain::Timeline.empty }))
    build.role_spawn
  end

  describe "in a git project with an uncommitted edit" do
    before do
      seed_repo
      File.write(File.join(@repo, "lib", "a.rb"), "edited, not committed\n")
    end

    # Scenario: a spike in plan scope leaves the checkout untouched
    it "writes and runs in the spike, leaving the checkout's status as it was" do
      status = git("status", "--porcelain")
      mode("plan")

      written = dispatch("write_file", { "path" => "notes.md", "content" => "spike notes\n" })
      _pending, ran = answered("bash", { "command" => %(ruby -e 'File.write("x", 1)') }, :approve)

      expect([written.is_error, ran.is_error]).to eq([false, false])
      expect(git("status", "--porcelain")).to eq(status)
      expect(File.read(File.join(spike, "notes.md"))).to eq("spike notes\n")
      expect(File.read(File.join(spike, "x"))).to eq("1")
      expect(File.read(File.join(spike, "lib", "a.rb"))).to eq("edited, not committed\n")
    end

    it "cuts the spike without writing the checkout's index, its stash list or its reflog" do
      git("status", "--porcelain")
      index = File.join(@repo, ".git", "index")
      before = [File.mtime(index), git("stash", "list"), git("reflog")]

      mode("plan")

      expect([File.mtime(index), git("stash", "list"), git("reflog")]).to eq(before)
    end

    it "stands the spike on a lain-owned plan branch, and roots the snapshots and the reminder there" do
      mode("plan")
      marked = git("for-each-ref", "--format=%(refname)", "refs/lain/owned/heads/lain/plan/").split

      expect(marked).to contain_exactly(start_with("refs/lain/owned/heads/lain/plan/"))
      expect(git("worktree", "list", "--porcelain")).to include("worktree #{spike}\n")
      expect(slot.root).to eq(spike)
      expect(session.reminders.last).to include(spike, "Untracked files were not copied")
    end

    # Scenario: a write aimed at the checkout refuses
    it "refuses a write_file aimed inside the checkout, naming the scope root" do
      mode("plan")

      refused = dispatch("write_file", { "path" => File.join(@repo, "lib", "b.rb"), "content" => "b\n" })

      expect(refused.is_error).to be(true)
      expect(refused.content).to include(spike)
      expect(File.exist?(File.join(@repo, "lib", "b.rb"))).to be(false)
    end

    # Scenario: an unconfinable command asks a human even under auto
    it "parks a command it cannot confine for a human under auto, with the plan-scope wording" do
      mode("plan auto")

      pending, refused = answered("bash", { "command" => "cd #{@repo} && touch y" }, :deny)

      expect(pending).to have_attributes(tool: "bash")
      expect(pending).to be_humans_only
      expect(refused.is_error).to be(true)
      expect(rulings.last).to include("reason" => start_with("plan scope cannot confine this command to #{spike}"))
      expect(File.exist?(File.join(@repo, "y"))).to be(false)
    end

    # A human's `@dev/<skill>` spawns through the role spawn, not through a
    # tool call, and its child must be confined like any other.
    it "confines a child a role skill spawns under plan auto, however it names the checkout" do
      mode("plan auto")
      relative = { "path" => "child.md", "content" => "c" }
      into_checkout = { "path" => File.join(@repo, "lib", "child.rb"), "content" => "c" }
      writes = tool_response(["c1", "write_file", relative], ["c2", "write_file", into_checkout])
      provider = Lain::Provider::Mock.new(responses: [writes, text_response("done")])

      role_spawn(provider).call(:dev, :fresh, "go")

      expect(File.read(File.join(spike, "child.md"))).to eq("c")
      expect(File.exist?(File.join(@repo, "lib", "child.rb"))).to be(false)
    end

    # The shape any child spawned around the scope would have: a session
    # still standing in the checkout, judged through the board's stack.
    it "refuses a checkout write from a session the flip never moved" do
      mode("plan auto")
      stranded = Lain::Session.new(worker_env: Lain::WorkerEnv.default.with(cwd: @repo))

      refused = dispatch_call("write_file", { "path" => File.join(@repo, "lib", "stranded.rb"), "content" => "s" },
                              toolset:, layers: stack, context: stranded)

      expect(refused.is_error).to be(true)
      expect(File.exist?(File.join(@repo, "lib", "stranded.rb"))).to be(false)
    end

    it "parks a command a human remembered in the checkout, rather than running it in plan auto" do
      command = "touch #{@repo}/remembered"
      remembered = Lain::Approval::Remembered.new(allow: [{ "tool" => "bash", "input" => { "command" => command } }])
      allow(Lain::Approval::Remembered).to receive(:from).and_return(remembered)
      mode("plan auto")

      pending, = answered("bash", { "command" => command }, :deny)

      expect(pending).to be_humans_only
      expect(File.exist?(File.join(@repo, "remembered"))).to be(false)
    end

    it "deletes the spike's branch and its marker on leaving, when the spike committed nothing" do
      mode("plan")
      told = mode("checkout")

      expect(plan_branches).to be_empty
      expect(told).not_to include("lain/plan/")
    end

    it "keeps the branch at the spike's commits on leaving, and names it" do
      mode("plan")
      File.write(File.join(spike, "notes.md"), "kept\n")
      git("add", "notes.md", dir: spike)
      git("-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-q", "-m", "spike work", dir: spike)
      head = git("rev-parse", "HEAD", dir: spike).strip

      told = mode("checkout")
      branch = plan_branches.find { _1.start_with?("refs/heads/") }

      expect(git("rev-parse", branch).strip).to eq(head)
      expect(told).to include(branch.delete_prefix("refs/heads/"))
    end

    it "names the kept worktree on leaving a spike with uncommitted work" do
      mode("plan")
      left = spike
      File.write(File.join(left, "notes.md"), "plan work\n")

      told = mode("checkout")

      expect(told).to include(left, "uncommitted changes")
      expect(File.read(File.join(left, "notes.md"))).to eq("plan work\n")
    end

    it "drops auto and its layers on a reset mid-turn, leaving the scope move for later" do
      mode("auto +auto_approve")

      told = mode("!", dispatching: true)

      expect(board.mode_switch.current).to eq(Lain::Mode.new)
      expect(told).to include("plan scope waits until the turn in flight ends")
      expect(plan_branches).to be_empty
    end

    # A critic reading a reviewed head is lent that checkout on purpose.
    it "keeps an explicitly lent checkout under plan, rather than the spike" do
      mode("plan")
      review = Dir.mktmpdir("review-head", @base)
      lent = Lain::Isolation::Leases::InPlace.new(worker_env: Lain::WorkerEnv.new(cwd: review, env: {},
                                                                                  checkout: review))

      ran_in = board.guard_inputs.scope.current.lend(lent).hold("diff_critic") { |env, _sync| env.cwd }.value

      expect(ran_in).to eq(review)
    end

    # Scenario: leaving plan restores the checkout
    it "runs bash in the project cwd again once the checkout is back, and lets the spike go" do
      File.write(File.join(@repo, "only-in-the-checkout.txt"), "untracked\n")
      mode("plan")
      left = spike
      mode("checkout auto")
      ran = dispatch("bash", { "command" => "ls" })

      expect(session.worker_env.cwd).to eq(@repo)
      expect(ran.content).to include("only-in-the-checkout.txt")
      expect([session.scope, slot.root]).to eq([Lain::Session::Unconfined, @repo])
      expect(git("worktree", "list", "--porcelain")).not_to include("worktree #{left}\n")
    end
  end

  describe "started from a directory git does not track" do
    before do
      seed_repo
      @cwd = File.join(@repo, "build").tap { FileUtils.mkdir_p(_1) }
      File.write(File.join(@cwd, "out.log"), "ignored\n")
    end

    it "makes that directory in the spike, so a relative write and a command resolve, and says so" do
      mode("plan")

      written = dispatch("write_file", { "path" => "n.md", "content" => "n" })

      expect([written.is_error, session.worker_env.cwd]).to eq([false, File.join(spike, "build")])
      expect(File.read(File.join(spike, "build", "n.md"))).to eq("n")
      expect(session.reminders.last).to include("build", "made empty")
    end
  end

  # The reset is a safety step before it is a scope: an empty repository has
  # no commit to cut a spike from, and the reset must still take auto away.
  describe "a reset in a repository with no commit yet" do
    before { git("init", "-q") }

    it "lowers approval to ask and drops the layers, staying in the checkout, and says why" do
      mode("auto +auto_approve")

      told = mode("!")

      expect(board.mode_switch.current).to eq(Lain::Mode.new)
      expect(told).to include("plan scope could not be entered")
      expect(git("worktree", "list", "--porcelain").scan(/^worktree /).size).to eq(1)
    end
  end

  # Scenario: plan scope outside git uses a scratch directory
  describe "in a project that is not a git repository" do
    before { @detected_by = :none }
    after { FileUtils.rm_rf(@scratch) if @scratch }

    it "confines the worker to a scratch directory under lain's temporary root" do
      mode("plan")
      @scratch = session.worker_env.cwd

      expect(@scratch).to start_with(File.join(File.realpath(Dir.tmpdir), "lain", "scratch", ""))
      expect(session.worker_env.checkout).to eq(@scratch)
      expect(session.reminders.last).to include(@scratch, "scratch directory")
    end
  end
end
