# frozen_string_literal: true

require "fileutils"
require "pathname"
require "stringio"
require "tmpdir"

# A child leased into a git worktree runs its commands THERE, so the rule that
# approves a command with no human has to judge its words there too -- while
# every path the project protects stays protected, wherever the child names it
# from. Everything between the call and the ruling is real: a git worktree cut
# by {Lain::Isolation::Worktree}, the board {Lain::CLI::Wiring::BoardBuild}
# builds for a project, and the stacks {Lain::CLI::ToolGuard} assembles over it.
# Only the interpreter is canned, so an approval is an observation rather than a
# command that ran.
RSpec.describe "A leased child's shell calls are judged in its own worktree", :seam do
  let(:journal_io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io: journal_io) }
  let(:chronicle) do
    instance_double(Lain::CLI::Chronicle, record_journal: journal,
                                          instrumentation: Lain::Agent::Instrumentation.new(journal:))
  end
  let(:toolset) { Lain::Toolset.new([Lain::Tools::Bash.new]) }
  let(:key) do
    "-----BEGIN OPENSSH PRIVATE KEY-----\n" \
      "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n" \
      "-----END OPENSSH PRIVATE KEY-----\n"
  end

  # The project denies its own `vault/` by an anchored pattern, and holds one
  # untracked token there, so the child's checkout does not carry it.
  around do |example|
    Dir.mktmpdir("lain-child-worktree") do |dir|
      base = File.realpath(dir)
      @home = File.join(base, "home")
      @repo = File.join(base, "repo")
      FileUtils.mkdir_p([@home, @repo])
      FileUtils.cp_r("#{SeedRepo.at({ "README.md" => "a readme\n" })}/.", @repo)
      FileUtils.mkdir_p(File.join(@repo, "vault"))
      write_config(@repo, "sensitivity denied: %w[/vault/]\n")
      File.write(File.join(@repo, "vault", "token"), "opaque\n")
      File.chmod(0o644, File.join(@repo, "vault", "token"))
      example.run
    ensure
      @lease&.release
    end
  end

  def project = Lain::Project.new(root: @repo, cwd: @repo, kind: :project, detected_by: :git)

  def board
    @board ||= Lain::CLI::Wiring::BoardBuild.for(
      chronicle:, options: {}, model: "m", toolset:, project:, paths: Lain::Paths.new(env: { "HOME" => @home }),
      verdict: Lain::CLI::Wiring::BoardBuild.shell_verdict(project:)
    )
  end

  # The worktrees live beside the repository, never under it, as a real chat's
  # do under lain's state directory.
  def lease
    @lease ||= Lain::Isolation::Worktree.new(
      root: File.join(File.dirname(@repo), "worktrees"), repo_root: @repo,
      base: Lain::Isolation::WorkingBranch.checked_out(repo_root: @repo)
    ).acquire("child-1")
  end

  def checkout = lease.worker_env.checkout

  # A 0600 key in the child's worktree, and a link to it under an ordinary name.
  # Neither exists in the project, which is where the parent's factory looked.
  def link_a_key
    File.write(File.join(checkout, "key.txt"), key)
    File.chmod(0o600, File.join(checkout, "key.txt"))
    File.symlink("key.txt", File.join(checkout, "keylink"))
  end

  def child = Lain::CLI::ToolGuard.child_stack(chronicle, board, lease.worker_env, requester: "subagent")
  def parent = Lain::CLI::ToolGuard.stack(chronicle, board)
  def parent_env = Lain::WorkerEnv.new(cwd: @repo, env: {})

  def auto! = board.mode_switch.switch(Lain::Mode.new(approval: :auto), surface: "tty")
  def ask! = board.mode_switch.switch(Lain::Mode.new(approval: :ask), surface: "tty")

  def input(command, cwd) = cwd ? { "command" => command, "cwd" => cwd } : { "command" => command }

  def run(stack, command, cwd: nil, worker_env: lease.worker_env, answer: "the command ran")
    dispatch_call("bash", input(command, cwd), toolset:, layers: stack.to_a,
                                               context: Lain::Session.new(worker_env:),
                                               handler: Lain::Effect::Handler::Mock.new(default: answer))
  end

  def rulings = Lain::Journal.records(journal_io.string.lines, type: "escalation").to_a

  # `:approved`, `:parked`, or `[:refused, what the model was told]`. A call
  # still waiting when the window closes waits for a human, and is stopped
  # rather than answered.
  def outcome(stack, command, cwd: nil, worker_env: lease.worker_env)
    Sync do |task|
      call = task.async { run(stack, command, cwd:, worker_env:) }
      told = task.with_timeout(2) { call.wait }
      told.content == "the command ran" ? :approved : [:refused, told.content]
    rescue Async::TimeoutError
      :parked
    ensure
      call&.stop
    end
  end

  # Every deterministic rung abstained, so the call waits on the board's one
  # queue, where the pending it left is read.
  def parked(stack, command, cwd: nil)
    Sync do |task|
      call = task.async { run(stack, command, cwd:) }
      task.with_timeout(5) { board.approvals.dequeue }
    ensure
      call&.stop
    end
  end

  # Scenario: a child's symlink to a key is judged in its worktree
  describe "a child's symlink to a key" do
    before { link_a_key }

    it "is not approved automatically when the call names no cwd, and parks for a human" do
      pending_call = parked(child, "cat keylink")

      expect(pending_call).to have_attributes(tool: "bash", requester: "subagent")
      expect(rulings.last).to include("rung" => "rules", "verdict" => "abstain")
    end

    it "is not approved automatically when the call names the worktree as its cwd" do
      parked(child, "cat keylink", cwd: checkout)

      expect(rulings.last).to include("rung" => "rules", "verdict" => "abstain")
    end
  end

  # Scenario: an ordinary read in the child's worktree is approved
  describe "an ordinary read in the child's worktree" do
    it "is approved automatically when the call names the worktree as its cwd" do
      expect(outcome(child, "cat README.md", cwd: checkout)).to eq(:approved)
      expect(rulings.last).to include("rung" => "rules", "verdict" => "allow")
      expect(board.approvals.each.count).to eq(0)
    end

    it "is approved automatically when the call names no cwd" do
      expect(outcome(child, "cat README.md")).to eq(:approved)
      expect(rulings.last).to include("rung" => "rules", "verdict" => "allow")
    end
  end

  # Scenario: the parent's judgements are unchanged
  describe "the parent" do
    it "has its `cat README.md` approved against the project root" do
      expect(outcome(parent, "cat README.md", worker_env: parent_env)).to eq(:approved)
      expect(rulings.last).to include("rung" => "rules", "verdict" => "allow")
    end

    it "still confines its own calls to the project, so the child's worktree parks for a human" do
      pending_call = parked(parent, "cat README.md", cwd: checkout)

      expect(pending_call).to have_attributes(tool: "bash")
      expect(rulings.last).to include("rung" => "rules", "verdict" => "abstain")
    end
  end

  # A pattern anchored on the project root denies against BOTH roots for a
  # child: its own checkout carries a copy of the tracked tree, and the
  # project's is one absolute word away.
  describe "a project-anchored denial" do
    # The refusal names the path, and a long absolute one can scan as a
    # high-entropy token; a refusal is not output, so it reaches the model as
    # written and bars nothing.
    def expect_refused_as_protected(stack, command, **)
      told = outcome(stack, command, **)

      expect(told).to match([:refused, a_string_starting_with(%(refused tool "bash": the command names a path ) +
                                                              "this session protects")])
      expect(rulings.last).to include("rung" => "triage", "verdict" => "deny", "final" => true)
      expect(board.guard_inputs.bar.include?(command)).to be(false)
    end

    it "refuses the parent's own vault under auto" do
      auto!

      expect_refused_as_protected(parent, "cat #{@repo}/vault/token", worker_env: parent_env)
    end

    it "refuses a child's relative read of its own worktree's vault under auto" do
      auto!
      FileUtils.mkdir_p(File.join(checkout, "vault"))
      File.write(File.join(checkout, "vault", "token"), "opaque\n")

      expect_refused_as_protected(child, "cat vault/token")
    end

    it "refuses the project's vault to a child that names it absolutely under auto, as it does the parent" do
      auto!

      expect_refused_as_protected(child, "cat #{@repo}/vault/token")
      expect_refused_as_protected(parent, "cat #{@repo}/vault/token", worker_env: parent_env)
    end

    it "refuses the project's vault to a child under ask, rather than parking it as an ordinary approval" do
      expect_refused_as_protected(child, "cat #{@repo}/vault/token")
    end
  end

  # Confinement stays the checkout: nothing outside it is approved automatically,
  # however the word reaches the parent's tree.
  describe "a child reaching into the parent's checkout" do
    it "parks a read naming the parent's checkout absolutely" do
      expect(outcome(child, "cat #{@repo}/README.md")).to eq(:parked)
    end

    it "parks a call whose cwd is the parent's checkout" do
      expect(outcome(child, "cat README.md", cwd: @repo)).to eq(:parked)
    end

    it "parks a relative walk up to the parent's checkout" do
      walk = Pathname.new(@repo).relative_path_from(Pathname.new(checkout)).to_s

      expect(outcome(child, "cat #{walk}/README.md")).to eq(:parked)
    end

    it "parks a file symlink in the worktree escaping to the parent's checkout" do
      File.symlink(File.join(@repo, "README.md"), File.join(checkout, "escape"))

      expect(outcome(child, "cat escape")).to eq(:parked)
    end

    it "parks a directory symlink in the worktree escaping to the parent's checkout" do
      File.symlink(@repo, File.join(checkout, "up"))

      expect(outcome(child, "cat up/README.md")).to eq(:parked)
    end
  end

  describe "the approval level a child is judged at" do
    it "follows the session through a flip made after the child was built" do
      stack = child
      before = outcome(stack, "cat #{@repo}/README.md")
      auto!
      flipped = outcome(stack, "cat #{@repo}/README.md")
      ask!

      expect([before, flipped, outcome(stack, "cat #{@repo}/README.md")]).to eq(%i[parked approved parked])
    end

    it "keeps a call parked under ask waiting across a flip to auto, as the parent's does" do
      stack = child
      Sync do |task|
        call = task.async { run(stack, "cat #{@repo}/README.md") }
        task.with_timeout(2) { board.approvals.dequeue }
        auto!

        expect { task.with_timeout(1) { call.wait } }.to raise_error(Async::TimeoutError)
      ensure
        call&.stop
      end
    end
  end

  describe "what a child shares with its parent" do
    def layer(stack, kind) = stack.to_a.grep(kind).first

    it "holds the parent's bar and path policy" do
      child_stack = child

      expect(layer(child_stack, Lain::Middleware::WithholdAutomaticOutput).bar)
        .to be(layer(parent, Lain::Middleware::WithholdAutomaticOutput).bar)
      expect(layer(child_stack, Lain::Middleware::Sensitivity).instance_variable_get(:@sensitivity))
        .to be(board.sensitivity)
    end

    it "bars a command for the parent once a child's automatically approved output was withheld" do
      told = Sync { run(child, "cat README.md", answer: key) }

      expect(told.content).to include("withheld")
      expect(outcome(parent, "cat README.md", worker_env: parent_env)).to eq(:parked)
    end
  end

  # The parent's reasons for confining nothing carry over to its workers.
  describe "a project the parent refuses to confine" do
    def project = Lain::Project.new(root: @repo, cwd: @repo, kind: :home, detected_by: :git)

    it "parks an ordinary read for the parent and for a leased child alike" do
      expect(outcome(parent, "cat README.md", worker_env: parent_env)).to eq(:parked)
      expect(outcome(child, "cat README.md")).to eq(:parked)
    end
  end
end
