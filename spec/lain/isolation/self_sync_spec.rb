# frozen_string_literal: true

require "fileutils"
require "mixlib/shellout"
require "tmpdir"

# The worker lain asks to rebase: it records every prompt and runs an injected
# action in its checkout -- what the model would have done with its shell.
class SelfSyncSpecWorker
  attr_reader :prompts

  def initialize(&action)
    @prompts = []
    @action = action || ->(_prompt) {}
  end

  def ask(text)
    @prompts << text
    @action.call(text)
    Lain::Response.new(content: [{ "type" => "text", "text" => "tried" }], stop_reason: :end_turn)
  end
end

# Runs every git call for real, and raises an Interrupt the moment lain's own
# rebase has run: a cancel landing at that suspension point, before the abort
# that would otherwise have followed it.
class SelfSyncSpecCancel
  Cancelling = Struct.new(:shell, :armed) do
    def run_command
      shell.run_command
      raise Interrupt, "cancelled mid-rebase" if armed

      shell
    end

    def stdout = shell.stdout
    def stderr = shell.stderr
    def exitstatus = shell.exitstatus
  end

  def initialize
    @armed = true
  end

  def call(*argv, **)
    armed = @armed && argv.include?("rebase") && !argv.include?("--abort")
    @armed = false if armed
    Cancelling.new(Lain::Shell::Out.new(*argv, **), armed)
  end
end

# Drives real git in a throwaway repository it creates itself, never the lain
# repository it runs in: a leased worktree cut from `feat`, a working branch
# that moves under it, and a rebase that either lands or is given back.
RSpec.describe Lain::Isolation::SelfSync, :seam do
  subject(:sync) { described_class.new(base:, retries:) }

  around do |example|
    Dir.mktmpdir("lain-sync-repo") do |repo|
      Dir.mktmpdir("lain-sync-worktrees") do |root|
        @repo = File.realpath(repo)
        @root = File.realpath(root)
        FileUtils.cp_r("#{SeedRepo.at(seed_files)}/.", @repo)
        git(@repo, "switch", "-q", "-c", "feat")
        example.run
      ensure
        @lease&.release
      end
    end
  end

  let(:retries) { 1 }
  let(:base) { Lain::Isolation::WorkingBranch.checked_out(repo_root: @repo) }
  let(:backend) { Lain::Isolation::Worktree.new(repo_root: @repo, root: @root, base:) }
  let(:lease) { @lease = backend.acquire("worker-1") }
  let(:tree) { lease.worker_env.cwd }
  let(:anchor) { Lain::Isolation::Worktree::Handback::Naming.new("worker-1").ref }

  def seed_files = { "README" => "seed\n", "notes.txt" => "seed\n" }

  # Scrubbed exactly as the subject scrubs, so a pre-commit hook's
  # GIT_INDEX_FILE never points these calls at lain's own index.
  def shell(dir, *args, env: {})
    Mixlib::ShellOut.new("git", "-C", dir, *args,
                         environment: env.merge(Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)).run_command
  end

  def git(dir, *, env: {}) = shell(dir, *, env:).tap(&:error!).stdout.strip

  def commit(dir, file, body)
    File.write(File.join(dir, file), body)
    git(dir, "add", file)
    git(dir, "commit", "-q", "-m", "#{file}: #{body.strip}")
    git(dir, "rev-parse", "HEAD")
  end

  def head = git(tree, "rev-parse", "HEAD")

  def rebasing? = File.directory?(File.expand_path(git(tree, "rev-parse", "--git-path", "rebase-merge"), tree))

  def anchored = shell(@repo, "rev-parse", "--verify", "--quiet", anchor).stdout.strip

  def reachable?(commit) = !git(@repo, "for-each-ref", "--contains", commit, "--format=%(refname)").empty?

  def askable(worker) = described_class.worker(worker, tools: %w[read_file bash])

  def synced(worker = SelfSyncSpecWorker.new) = sync.call(lease, worker: askable(worker), worker_id: "worker-1")

  def attempt(by, conflicts, outcome) = { "by" => by, "conflicts" => conflicts, "outcome" => outcome }

  # The worker's own resolution: rebase, keep both sides, continue.
  def resolves(env: {})
    SelfSyncSpecWorker.new do |_prompt|
      shell(tree, "rebase", base.tip, env:)
      File.write(File.join(tree, "README"), "both\n")
      git(tree, "add", "README", env:)
      git(tree, "rebase", "--continue", env: { "GIT_EDITOR" => "true" }.merge(env))
    end
  end

  describe "a worker whose working branch moved on without touching its files" do
    it "anchors the worker's commit, then rebases it onto the tip so its handback can fast-forward" do
      c1 = commit(tree, "work.txt", "c1\n")
      tip = commit(@repo, "notes.txt", "tip moved\n")

      result = synced

      expect(result.outcome).to eq(:synced)
      expect(result.attempts).to eq([attempt("lain", 0, "landed")])
      expect(git(tree, "rev-parse", "HEAD^")).to eq(tip)
      expect(git(tree, "show", "HEAD:work.txt")).to eq("c1")
      expect(head).not_to eq(c1)
      expect(anchored).to eq(c1)
    end
  end

  describe "a worker with nothing to rebase" do
    it "leaves a worker the tip has not moved under exactly where it is, anchoring nothing" do
      c1 = commit(tree, "work.txt", "c1\n")

      result = synced

      expect(result.outcome).to eq(:current)
      expect(result.attempts).to eq([])
      expect(head).to eq(c1)
      expect(anchored).to eq("")
    end

    it "leaves a worker that committed nothing where it was cut, however far the tip moved" do
      cut = head
      commit(@repo, "notes.txt", "tip moved\n")

      expect(synced.outcome).to eq(:current)
      expect(head).to eq(cut)
    end
  end

  describe "a rebase that conflicts" do
    let!(:c1) { commit(tree, "README", "worker\n") }
    let!(:tip) { commit(@repo, "README", "tip\n") }

    it "anchors the worker's commit before lain's first rebase" do
      sync.call(lease, worker: described_class::Unaskable, worker_id: "worker-1")

      expect(anchored).to eq(c1)
    end

    it "asks the still-live worker once, then gives up with each attempt's count and outcome, and its words" do
      worker = SelfSyncSpecWorker.new

      result = synced(worker)

      expect(worker.prompts.size).to eq(1)
      expect(worker.prompts.first).to include(tree, tip, "feat", "GIT_EDITOR=true git rebase --continue")
      expect(result.outcome).to eq(:conflicted)
      expect(result.attempts).to eq([attempt("lain", 1, "conflicted"), attempt("worker", 1, "conflicted")])
      expect(result.detail).to eq("tried")
      expect(head).to eq(c1)
      expect(rebasing?).to be(false)
    end

    context "with rebase_retries = 2" do
      let(:retries) { 2 }

      it "asks as many times as the retries allow" do
        worker = SelfSyncSpecWorker.new

        result = synced(worker)

        expect(worker.prompts.size).to eq(2)
        expect(result.attempts.map { |entry| entry["by"] }).to eq(%w[lain worker worker])
      end
    end

    # The resolution rewrites the patch, so the commit is found again by what a
    # rebase keeps and a skip or a reset does not: its author, author date and
    # subject.
    it "takes the worker's own rebase when it resolves the conflict" do
      result = synced(resolves)

      expect(result.outcome).to eq(:synced)
      expect(result.attempts).to eq([attempt("lain", 1, "conflicted"), attempt("worker", 0, "landed")])
      expect(result.detail).to eq("")
      expect(git(tree, "rev-parse", "HEAD^")).to eq(tip)
      expect(File.read(File.join(tree, "README"))).to eq("both\n")
    end

    # The model's plausible "I could not resolve it" drops its own commit, and
    # the checkout then stands level with the tip. Level is not landed.
    it "restores a worker whose `rebase --skip` dropped its commit, and never calls that synced" do
      worker = SelfSyncSpecWorker.new do |_prompt|
        shell(tree, "rebase", tip)
        shell(tree, "rebase", "--skip")
      end

      result = synced(worker)

      expect(result.outcome).to eq(:lost)
      expect(result.attempts.last).to eq(attempt("worker", 0, "lost"))
      expect(head).to eq(c1)
    end

    it "restores a worker that reset itself onto the tip, and never calls that synced" do
      worker = SelfSyncSpecWorker.new { |_prompt| shell(tree, "reset", "--hard", tip) }

      result = synced(worker)

      expect(result.outcome).to eq(:lost)
      expect(result.attempts.last).to eq(attempt("worker", 0, "lost"))
      expect(head).to eq(c1)
    end

    it "keeps a dropped commit reachable through the handback and the release after it" do
      synced(SelfSyncSpecWorker.new { |_prompt| shell(tree, "reset", "--hard", tip) })

      Lain::Isolation::WorkerHandoff.over(repo_root: @repo, base:).reclaim(lease, worker_id: "worker-1")

      expect(reachable?(c1)).to be(true)
    end

    it "does not ask a worker that holds no shell" do
      worker = SelfSyncSpecWorker.new

      result = sync.call(lease, worker: described_class.worker(worker, tools: %w[read_file edit_file]),
                                worker_id: "worker-1")

      expect(worker.prompts).to be_empty
      expect(result.outcome).to eq(:conflicted)
      expect(result.attempts).to eq([attempt("lain", 1, "conflicted")])
    end

    # The follow-up ask is a provider round trip, and one that fails -- a 529,
    # a spent token ceiling -- resolved nothing. What it must not do is leave
    # the worker's checkout mid-rebase for the handback to anchor.
    it "gives the checkout back as the worker left it when the follow-up ask raises mid-rebase" do
      worker = SelfSyncSpecWorker.new do |_prompt|
        shell(tree, "rebase", tip)
        raise "the provider went away"
      end

      result = synced(worker)

      expect(result.outcome).to eq(:conflicted)
      expect(result.detail).to include("the provider went away")
      expect(rebasing?).to be(false)
      expect(head).to eq(c1)
    end

    # A cancel climbs past every rescue, so only an `ensure` gives the
    # checkout back -- and mid-rebase, HEAD is the tip, which is what the
    # surrender after it would otherwise anchor.
    it "abandons lain's own rebase when a cancel lands mid-rebase, so the surrender anchors the worker's commit" do
      cancelling = described_class.new(base:, retries:, shell_out_factory: SelfSyncSpecCancel.new)

      expect { cancelling.call(lease, worker: described_class::Unaskable, worker_id: "worker-1") }
        .to raise_error(Interrupt)
      expect(rebasing?).to be(false)
      expect(head).to eq(c1)

      Lain::Isolation::WorkerHandoff.over(repo_root: @repo, base:).surrender(lease, worker_id: "worker-1")

      expect(reachable?(c1)).to be(true)
    end

    # Mid-rebase, HEAD is the tip and the worker's own commits live only in
    # the rebase's state; a handback that anchored HEAD would anchor the tip.
    it "aborts a rebase the worker's own turn left in progress, records that, and syncs from its commits" do
      shell(tree, "rebase", tip, env: { "GIT_EDITOR" => "true" })

      result = sync.call(lease, worker: described_class::Unaskable, worker_id: "worker-1")

      expect(result.attempts.first).to eq(attempt("worker", 1, "abandoned"))
      expect(result.outcome).to eq(:conflicted)
      expect(rebasing?).to be(false)
      expect(head).to eq(c1)
      expect(anchored).to eq(c1)
    end

    context "with rebase_retries = 0" do
      let(:retries) { 0 }

      it "runs no rebase and asks for none" do
        worker = SelfSyncSpecWorker.new

        result = synced(worker)

        expect(result.outcome).to eq(:disabled)
        expect(result.attempts).to eq([])
        expect(worker.prompts).to be_empty
        expect(head).to eq(c1)
      end
    end
  end

  describe "a worker with three commits, only the first of which conflicts" do
    let!(:worker_head) do
      commit(tree, "README", "worker\n")
      commit(tree, "work.txt", "c2\n")
      commit(tree, "more.txt", "c3\n")
    end
    let!(:tip) { commit(@repo, "README", "tip\n") }

    def resolves_all
      shell(tree, "rebase", tip)
      File.write(File.join(tree, "README"), "tip\nworker\n")
      git(tree, "add", "README")
      git(tree, "rebase", "--continue", env: { "GIT_EDITOR" => "true" })
    end

    it "takes a resolution that keeps every commit" do
      result = synced(SelfSyncSpecWorker.new { |_prompt| resolves_all })

      expect(result.outcome).to eq(:synced)
      expect(git(tree, "show", "HEAD:more.txt")).to eq("c3")
    end

    # c3 touched no path that conflicted, so no resolution could have rewritten
    # it: it must survive by its patch, and an amend that guts it does not.
    it "restores a worker that gutted a commit the conflict never touched, and never calls that synced" do
      worker = SelfSyncSpecWorker.new do |_prompt|
        resolves_all
        File.write(File.join(tree, "more.txt"), "gutted\n")
        git(tree, "commit", "-q", "-a", "--amend", "--no-edit")
      end

      result = synced(worker)

      expect(result.outcome).to eq(:lost)
      expect(head).to eq(worker_head)
    end

    # The worker's attempt ends still conflicting, so lain's next attempt
    # conflicts and the asks are spent -- and the checkout it would then hand
    # back is the worker's truncated one.
    it "restores a worker that dropped a commit and left the conflict for lain" do
      result = synced(SelfSyncSpecWorker.new { |_prompt| shell(tree, "reset", "--hard", "HEAD~1") })

      expect(result.outcome).to eq(:lost)
      expect(head).to eq(worker_head)
    end
  end

  describe "a worker that left uncommitted work" do
    let!(:c1) { commit(tree, "work.txt", "c1\n") }

    before do
      File.write(File.join(tree, "scratch.txt"), "never committed\n")
      commit(@repo, "notes.txt", "tip moved\n")
    end

    it "is not rebased, and the result names the tree dirty, with its path" do
      worker = SelfSyncSpecWorker.new

      result = synced(worker)

      expect(result.outcome).to eq(:dirty)
      expect(result.dirty).to be(true)
      expect(result.path).to eq(tree)
      expect(head).to eq(c1)
      expect(worker.prompts).to be_empty
    end

    # What becomes of the checkout is release's decision, not this object's,
    # so the parent is told only what the handback did not carry.
    it "tells the parent the uncommitted changes were not handed back" do
      expect(synced.note).to eq("the worker left uncommitted changes at #{tree}; they were not handed back")
    end

    context "with rebase_retries = 0" do
      let(:retries) { 0 }

      it "is still recorded dirty, since the path is what a human needs to find it" do
        result = synced

        expect(result.outcome).to eq(:dirty)
        expect(result.path).to eq(tree)
      end
    end
  end

  # `git rebase --continue` is the one step that opens an editor, and the
  # worker is the one who runs it -- through its shell, in the environment its
  # lease hands it. An ambient GIT_EDITOR that writes a marker is the proof.
  describe "the editor" do
    let(:marker) { File.join(@root, "an-editor-opened") }
    let(:editor) do
      File.join(@root, "editor.sh").tap do |script|
        File.write(script, "#!/bin/sh\ntouch #{marker}\n")
        File.chmod(0o755, script)
      end
    end

    it "is never opened, by lain's rebase or by a worker continuing one in the environment it is handed" do
      commit(tree, "README", "worker\n")
      commit(@repo, "README", "tip\n")

      with_env("GIT_EDITOR" => editor) do
        handed = sync.editorless(lease.worker_env).env
        worker = SelfSyncSpecWorker.new do |_prompt|
          shell(tree, "rebase", base.tip, env: handed)
          File.write(File.join(tree, "README"), "both\n")
          git(tree, "add", "README", env: handed)
          git(tree, "rebase", "--continue", env: handed)
        end

        expect(synced(worker).outcome).to eq(:synced)
        expect(File).not_to exist(marker)

        # The control: the same ambient editor DOES open for a git that was
        # not handed that environment, so the absence above is not an accident.
        git(tree, "commit", "--amend", env: ENV.to_h)
        expect(File).to exist(marker)
      end
    end
  end

  describe "a lease that cut no checkout" do
    it "syncs nothing, which is the result that says no sync ran" do
      bare = Lain::Isolation::Lease.new(worker_env: Lain::WorkerEnv.default)

      expect(sync.call(bare, worker: askable(SelfSyncSpecWorker.new), worker_id: "worker-1"))
        .to be(described_class::Result::NONE)
    end
  end

  describe "a working branch that names no commit" do
    let(:sync) { described_class.new(base: Lain::Isolation::WorkingBranch::NONE, retries:) }

    it "is recorded as failed, with the reason, never raised" do
      commit(tree, "work.txt", "c1\n")

      result = synced

      expect(result.outcome).to eq(:failed)
      expect(result.detail).to include("no working branch")
    end
  end

  describe ".worker" do
    it "may be asked only when the child holds a shell" do
      agent = SelfSyncSpecWorker.new

      expect(described_class.worker(agent, tools: %w[read_file bash])).to be_askable
      expect(described_class.worker(agent, tools: %w[read_file edit_file])).not_to be_askable
    end
  end

  # The sync journals nothing of its own: what it did rides the handback
  # record, so the one record a reader opens says a rebase ran.
  describe "the result" do
    it "is deeply frozen and spells the handback record's sync fields" do
      commit(tree, "README", "worker\n")
      commit(@repo, "README", "tip\n")

      result = synced

      expect(Ractor.shareable?(result)).to be(true)
      expect(result.to_record)
        .to eq(sync: :conflicted, attempts: [attempt("lain", 1, "conflicted"), attempt("worker", 1, "conflicted")],
               dirty: false, path: nil, detail: "tried")
    end

    it "says nothing to the parent, and adds nothing to the record, when no sync ran" do
      expect(described_class::Result::NONE.note).to eq("")
      expect(described_class::Result::NONE.to_record)
        .to eq(sync: nil, attempts: [], dirty: false, path: nil, detail: "")
    end
  end

  # Named in full: inside `describe described_class::Null`, `described_class`
  # would BE the Null, and every helper reading it would ask the wrong object.
  describe "the sync a run with no working branch holds" do
    let(:null) { Lain::Isolation::SelfSync::Null }

    it "syncs nothing and hands the child its environment untouched" do
      env = Lain::WorkerEnv.default

      expect(null.call(lease, worker: askable(SelfSyncSpecWorker.new), worker_id: "w"))
        .to be(described_class::Result::NONE)
      expect(null.editorless(env)).to be(env)
    end
  end
end
