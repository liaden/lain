# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# The half of a handback that a RETIREMENT does: the ref is written and nothing
# else. Driven directly rather than through {Lain::Supervisor}, which is what
# supervisor_spec.rb drives -- there the subject is the decision to retire a row,
# here it is what happens to the checkout afterwards.
#
# Operates on a THROWAWAY repo copied per example ({SeedRepo}), never the lain
# repo it runs in -- the posture worktree_handback_spec.rb takes, and the reason
# the git half of this file stays in the default suite.
RSpec.describe Lain::Isolation::Worktree::Handback::Retirement do
  describe ".reused_head?" do
    it "reads journaled string values like the symbols the retirement itself sees" do
      record = { "sync" => "current", "attempts" => [], "checks" => { "outcome" => "passed", "attempts" => [] } }

      expect([described_class.reused_head?(record), described_class.reused_head?(record.merge("sync" => "synced"))])
        .to eq([true, false])
    end

    it "answers the negation of what the retirement's own sync result moves" do
      result = Lain::Isolation::SelfSync::Result.new(outcome: :synced)

      expect(described_class.reused_head?(result.to_record)).to be(false)
    end
  end

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
        .to raise_error(Lain::Error, /worker-1's lease was already released/)
      expect(anchor).not_to have_received(:standing)
    end
  end

  describe Lain::Isolation::Worktree::Handback::Retirement::Anchor, :seam do
    it "fails the outcome with SelfSync::Failed naming the commit and the source when the fetch fails" do
      Dir.mktmpdir("lain-retire-repo") do |repo|
        FileUtils.cp_r("#{SeedRepo.at({ "README" => "seed\n" })}/.", repo)
        unknown = "0" * 40
        head = Struct.new(:exitstatus, :stdout, :stderr) do
          def run_command = self
        end.new(0, "#{unknown}\n", "")
        factory = ->(*argv, **kwargs) { argv.include?("rev-parse") ? head : Lain::Shell::Out.new(*argv, **kwargs) }
        base = instance_double(Lain::Isolation::WorkingBranch, name: "", tip: "")
        anchor = described_class.new(parent: Lain::Isolation::Checkout.new(repo), base:, shell_out_factory: factory)
        lease = Struct.new(:worker_env).new(Struct.new(:cwd).new(repo))

        outcome = anchor.anchor(lease, worker_id: "w", from: nil)

        sentence = "#{unknown} could not be fetched from #{Regexp.escape(repo)}: .+"
        expect([outcome.kind, outcome.detail])
          .to match([:failed, /\ALain::Isolation::SelfSync::Failed: #{sentence}/])
      end
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
    def run_git(dir, *args) = SeedRepo.git(dir, *args).stdout.strip

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

    context "with a shared clone lease, whose commits upstream lacks until they are fetched" do
      # Under lain's lease container, the one tree whose records lain trusts.
      let(:lease_root) { File.join(Lain::Paths.new.state_home, "worktrees", Lain::Paths.new.project_hash(@repo_root)) }
      let(:backend) do
        Lain::Isolation::Clone.new(repo_root: @repo_root, root: lease_root,
                                   base: Lain::Isolation::WorkingBranch.checked_out(repo_root: @repo_root))
      end

      after { FileUtils.rm_rf(lease_root) }

      def commit_in(dir, contents, message)
        File.write(File.join(dir, "worker.txt"), contents)
        run_git(dir, "add", "-A")
        run_git(dir, "-c", "user.name=w", "-c", "user.email=w@e", "commit", "-q", "-m", message)
        run_git(dir, "rev-parse", "HEAD")
      end

      it "fetches the worker's commit into upstream and anchors it there" do
        lease = backend.acquire("worker-1")
        commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")

        report = settle(lease, worker_id: "worker-1")

        expect([report.kind, report.sha, run_git(@repo_root, "rev-parse", worker_ref("worker-1"))])
          .to eq([:declined, commit, commit])
      ensure
        lease&.release
      end

      it "moves its own earlier anchor forward onto work that contains it" do
        lease = backend.acquire("worker-2")
        settle(lease, worker_id: "worker-2") if commit_in(lease.worker_env.cwd, "one\n", "one")
        later = commit_in(lease.worker_env.cwd, "two\n", "two")

        report = settle(lease, worker_id: "worker-2")

        expect([report.kind, run_git(@repo_root, "rev-parse", worker_ref("worker-2"))]).to eq([:declined, later])
      ensure
        lease&.release
      end
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
      expect(records.first.checks).to be_nil
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

    context "when counting the HEAD reads in the worker's checkout" do
      let(:reads) { [] }
      let(:factory) do
        lambda do |*argv, **kwargs|
          reads << argv[2] if argv.last(2) == %w[rev-parse HEAD]
          Lain::Shell::Out.new(*argv, **kwargs)
        end
      end
      let(:counted) do
        anchor = Lain::Isolation::Worktree::Handback::Retirement::Anchor.new(
          parent: Lain::Isolation::Checkout.new(@repo_root), base: backend.base, shell_out_factory: factory
        )
        described_class.new(sync:, anchor:, journal:)
      end

      def sync_reporting(outcome, &on_call)
        Class.new do
          define_method(:editorless) { |env| env }
          define_method(:call) do |lease, **|
            on_call&.call(lease)
            Lain::Isolation::SelfSync::Result.new(outcome:)
          end
        end.new
      end

      context "with a self-sync that rewrote nothing" do
        let(:sync) { sync_reporting(:current) }

        it "reads HEAD once and anchors that commit" do
          lease = backend.acquire("worker-7")
          commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")

          report = counted.settled(lease, worker: Lain::Isolation::SelfSync::Unaskable, worker_id: "worker-7")

          expect([reads.size, report.sha]).to eq([1, commit])
        ensure
          lease&.release
        end
      end

      context "with a self-sync that rebased the worker" do
        let(:sync) do
          sync_reporting(:synced) { |lease| @rebased = commit_in(lease.worker_env.cwd, "rebased\n", "rebased") }
        end

        it "reads HEAD again and anchors the rebased commit" do
          lease = backend.acquire("worker-8")
          commit_in(lease.worker_env.cwd, "worker\n", "worker work")

          report = counted.settled(lease, worker: Lain::Isolation::SelfSync::Unaskable, worker_id: "worker-8")

          expect([reads.size, report.sha]).to eq([2, @rebased])
        ensure
          lease&.release
        end
      end
    end

    it "anchors the commit of a worker left mid-rebase, though no further rebase is allowed" do
      lease = backend.acquire("worker-9")
      dir = lease.worker_env.cwd
      commit = commit_in(dir, "worker\n", "worker work")
      File.write(File.join(@repo_root, "worker.txt"), "tip\n")
      run_git(@repo_root, "add", "-A")
      run_git(@repo_root, "commit", "-q", "-m", "tip conflicts")
      expect { run_git(dir, "rebase", run_git(@repo_root, "rev-parse", "--abbrev-ref", "HEAD")) }
        .to raise_error(SeedRepo::GitFailed)

      report = described_class.over(isolation: backend, journal:, retries: 0)
                              .settled(lease, worker: Lain::Isolation::SelfSync::Unaskable, worker_id: "worker-9")

      expect([report.kind, report.sha]).to eq([:declined, commit])
    ensure
      lease&.release
    end

    it "anchors the commit a worker made while the checks ran, though the sync rewrote nothing" do
      lease = backend.acquire("worker-10")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")
      fixed = nil
      fixing = lambda do |checked, **|
        fixed = commit_in(checked.worker_env.cwd, "fix\n", "fix")
        Lain::Isolation::WorkerChecks::Result.new(outcome: :fixed, attempts: [{ "by" => "lain" }])
      end
      sync = Lain::Isolation::Checked.new(checks: fixing, sync: Lain::Isolation::SelfSync.new(base: backend.base))
      anchor = described_class::Anchor.new(parent: Lain::Isolation::Checkout.new(@repo_root), base: backend.base)

      report = described_class.new(sync:, anchor:, journal:)
                              .settled(lease, worker: Lain::Isolation::SelfSync::Unaskable, worker_id: "worker-10")

      expect(report.sha).to eq(fixed)
    ensure
      lease&.release
    end

    # Built as the epic driver builds it: the project's `isolation` lint, run
    # in the actor's own checkout before the anchor.
    it "carries the actor's checks onto its retirement record" do
      Dir.mktmpdir("lain-retire-lint") do |logs|
        log = File.join(logs, "lint.log")
        settings = Lain::Config::Isolation.from({ "lint" => ["sh", "-c", "pwd > #{log}"] }, path: nil)
        checks = Lain::Isolation::Checked.configured(base: backend.base, layout: Lain::TestLayout::None, settings:)
        checked = described_class.over(isolation: backend, journal:, checks:)
        lease = backend.acquire("worker-6")
        commit_in(lease.worker_env.cwd, "worker\n", "worker work")

        checked.settled(lease, worker: Lain::Isolation::SelfSync::Unaskable, worker_id: "worker-6")

        expect(journal.grep(Lain::Telemetry::Handback).first.checks).to include("outcome" => "passed")
        expect(File.read(log).strip).to eq(File.realpath(lease.worker_env.cwd))
      ensure
        lease&.release
      end
    end
  end
end
