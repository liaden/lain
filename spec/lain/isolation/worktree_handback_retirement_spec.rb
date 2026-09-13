# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "mixlib/shellout"

# The half of a handback that a RETIREMENT does: the ref is written and nothing
# else. Driven directly rather than through {Lain::Supervisor}, which is what
# supervisor_spec.rb drives -- there the subject is the decision to retire a row,
# here it is what happens to the checkout afterwards.
#
# Operates on a THROWAWAY repo copied per example ({SeedRepo}), never the lain
# repo it runs in -- the posture worktree_handback_spec.rb takes, and the reason
# the git half of this file stays in the default suite.
RSpec.describe Lain::Isolation::Worktree::Handback::Retirement do
  describe "a lease that was already given up" do
    # The refusal Retirement holds for ITSELF. {Lain::Supervisor#retire} refuses
    # the same case one layer up, so nothing in production reaches this raise --
    # which is exactly why it needs a spec of its own: a direct caller (the epic
    # driver builds its own Retirement) gets the same sentence, by name.
    it "refuses by name before it asks the anchor anything" do
      anchor = instance_spy(Lain::Isolation::Worktree::Handback::Retirement::Anchor)
      lease = instance_double(Lain::Isolation::Lease, released?: true)
      retirement = described_class.new(sync: Lain::Isolation::SelfSync::Null, anchor:)

      expect { retirement.surrender(lease, worker_id: "worker-1") }
        .to raise_error(Lain::Supervisor::AlreadyReleased, /worker-1's lease was already released/)
      expect(anchor).not_to have_received(:standing)
    end
  end

  describe Lain::Isolation::Worktree::Handback::Retirement::Null do
    it "answers the whole duck with nothing synced and nothing anchored" do
      env = Lain::WorkerEnv.new(cwd: "/leased/checkout", env: {})

      expect(described_class.editorless(env)).to equal(env)
      expect(described_class.settled(nil, worker: nil, worker_id: "w")).to have_attributes(
        kind: :declined, detail: described_class::UNWIRED
      )
      expect(described_class.surrender(nil, worker_id: "w").kind).to eq(:declined)
    end
  end

  describe "against a real repository", :seam do
    subject(:retirement) { described_class.over(isolation: backend, journal:) }

    around do |example|
      Dir.mktmpdir("lain-retire-repo") do |repo|
        Dir.mktmpdir("lain-retire-worktrees") do |worktrees|
          @repo_root = File.realpath(repo)
          @root = File.realpath(worktrees)
          FileUtils.cp_r("#{SeedRepo.at({ "README" => "seed\n" })}/.", @repo_root)
          example.run
        end
      end
    end

    let(:journal) { [] }
    let(:backend) do
      Lain::Isolation::Worktree.new(repo_root: @repo_root, root: @root,
                                    base: Lain::Isolation::WorkingBranch.checked_out(repo_root: @repo_root))
    end

    # The spec's own git scrubs the inherited git context exactly as the subject
    # does, so it is hermetic under a pre-commit hook's GIT_* environment.
    def run_git(dir, *args)
      shell = Mixlib::ShellOut.new("git", "-C", dir, *args,
                                   environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
      shell.run_command.error!
      shell.stdout.strip
    end

    def commit_in(dir, contents, message)
      File.write(File.join(dir, "worker.txt"), contents)
      run_git(dir, "add", "-A")
      run_git(dir, "commit", "-q", "-m", message)
      run_git(dir, "rev-parse", "HEAD")
    end

    def parent_state = [run_git(@repo_root, "rev-parse", "HEAD"), run_git(@repo_root, "status", "--porcelain")]

    # Asked of the object that decides it, never reconstructed here: a parallel
    # copy of the slug-plus-fingerprint rule would drift green.
    def worker_ref(worker_id) = Lain::Isolation::Worktree::Handback::Naming.new(worker_id).ref

    # Retirement never merges, so the worker is never asked to resolve one.
    def settle(lease, worker_id:)
      retirement.settled(lease, worker: Lain::Isolation::SelfSync::Unaskable, worker_id:)
    end

    it "anchors a settled worker's commit under its ref, and merges nothing into the working branch" do
      lease = backend.acquire("worker-1")
      commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")
      before = parent_state

      report = settle(lease, worker_id: "worker-1")

      expect(report.sha).to eq(commit)
      expect(report.ref).to eq(worker_ref("worker-1"))
      expect(run_git(@repo_root, "rev-parse", report.ref)).to eq(commit)
      # ANCHOR-ONLY is the whole promise: the branch a human stands on is
      # byte-for-byte where it was, and the commit reaches it through a gate.
      expect(parent_state).to eq(before)
      expect(report.detail).to include(Lain::Isolation::Worktree::Handback::ANCHOR_ONLY)
    ensure
      lease&.release
    end

    it "reads a worker that committed nothing as nothing to do, writing no ref" do
      lease = backend.acquire("worker-2")

      report = settle(lease, worker_id: "worker-2")

      expect(report.kind).to eq(:nothing_to_do)
      expect(run_git(@repo_root, "for-each-ref", "--format=%(refname)", "refs/lain")).to eq("")
    ensure
      lease&.release
    end

    it "journals one handback record per retirement, carrying what the self-sync did" do
      lease = backend.acquire("worker-3")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      settle(lease, worker_id: "worker-3")

      records = journal.grep(Lain::Telemetry::Handback)
      expect(records.map(&:outcome)).to eq([:declined])
      expect(records.first).to have_attributes(worker_key: "worker-3", ref: worker_ref("worker-3"))
      expect(records.first.sync).not_to be_nil
    ensure
      lease&.release
    end

    it "is idempotent over one checkout: a second retirement finds its own work already anchored" do
      lease = backend.acquire("worker-4")
      commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      first = settle(lease, worker_id: "worker-4")
      second = settle(lease, worker_id: "worker-4")

      expect([first.kind, second.kind]).to eq(%i[declined declined])
      expect(second.sha).to eq(commit)
      expect(run_git(@repo_root, "rev-parse", worker_ref("worker-4"))).to eq(commit)
    ensure
      lease&.release
    end

    # The line a bare compare-and-swap cannot hold: another run's only anchor is
    # never moved off the work it holds, and the refusal says where the commit
    # that lost went.
    it "refuses rather than move an anchor off work the retiring checkout does not contain" do
      squatter = backend.acquire("worker-5")
      held = commit_in(squatter.worker_env.cwd, "earlier\n", "an earlier run's work")
      run_git(@repo_root, "update-ref", worker_ref("worker-5"), held)
      squatter.release

      lease = backend.acquire("worker-5")
      mine = commit_in(lease.worker_env.cwd, "later\n", "a later run's work")

      report = settle(lease, worker_id: "worker-5")

      expect(report.kind).to eq(:failed)
      expect(report.detail).to include("an anchor is never moved off work it holds")
      expect(run_git(@repo_root, "rev-parse", worker_ref("worker-5"))).to eq(held)
      expect(run_git(@repo_root, "rev-parse", worker_ref("worker-5 refused #{mine}"))).to eq(mine)
    ensure
      lease&.release
    end
  end
end
