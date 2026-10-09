# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Isolation::MergeCoordinator::Handoff, :seam do
  subject(:handoff) do
    described_class.new(handback: Lain::Isolation::Worktree::Handback.new(
      repo_root: @repo, base: Lain::Isolation::WorkingBranch::NONE
    ), repo_root: @repo, branch: "feat", journal:, spawner:)
  end

  around do |example|
    Dir.mktmpdir("lain-handoff-repo") do |repo|
      Dir.mktmpdir("lain-handoff-trees") do |trees|
        Dir.mktmpdir("lain-handoff-state") do |state|
          @repo = File.realpath(repo)
          @trees = File.realpath(trees)
          @state = File.realpath(state)
          FileUtils.cp_r("#{SeedRepo.at({ "f" => "seed\n" })}/.", @repo)
          git("switch", "-q", "-c", "feat")
          File.write(File.join(@repo, ".git", "info", "exclude"), ".lain/\n", mode: "a")
          example.run
        end
      end
    end
  end

  # Records each drainer the handoff asks for, and starts nothing.
  let(:spawner_class) do
    Class.new do
      attr_reader :calls

      def initialize(started: true)
        @calls = []
        @started = started
      end

      def drain(branch:, root:, home:)
        @calls << { branch:, root:, home: home.dir }
        @started
      end
    end
  end

  let(:spawner) { spawner_class.new }
  let(:journal) { [] }
  let(:paths) { Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => @state, "XDG_STATE_HOME" => @state }) }
  let(:backend) do
    Lain::Isolation::Worktree.new(repo_root: @repo, root: @trees,
                                  base: Lain::Isolation::WorkingBranch.checked_out(repo_root: @repo))
  end

  def git(*args, dir: @repo) = SeedRepo.git(dir, *args).stdout.strip

  def tip = git("rev-parse", "refs/heads/feat")

  def contains?(sha)
    Lain::Shell::Out.new("git", "-C", @repo, "merge-base", "--is-ancestor", sha, "refs/heads/feat",
                         environment: SeedRepo::SCRUB).run_command.exitstatus.zero?
  end

  def home = Lain::Isolation::MergeCoordinator::Home.for(repo_root: @repo, branch: "feat")

  def spool = Lain::Isolation::MergeCoordinator::Spool.new(home)

  def ref_for(worker_id) = Lain::Isolation::Worktree::Handback::Naming.new(worker_id).ref

  # Each queued ref, as "<entry id> <commit>".
  def queued_refs
    git("for-each-ref", "--format=%(refname:lstrip=-1) %(objectname)", "refs/lain/queued/").lines.map(&:strip)
  end

  # A live lease whose worker committed one commit, changing f; @c1 names it.
  def committed_lease(worker_id = "dev-1", body: "worker\n")
    backend.acquire(worker_id).tap do |lease|
      File.write(File.join(lease.worker_env.cwd, "f"), body)
      git("commit", "-q", "-am", "c1", dir: lease.worker_env.cwd)
      @c1 = git("rev-parse", "HEAD", dir: lease.worker_env.cwd)
    end
  end

  def failed_checks
    Lain::Isolation::Checked::Result.new(
      checks: Lain::Isolation::WorkerChecks::Result.new(outcome: :failed, detail: "lint said: f is wrong"),
      sync: Lain::Isolation::SelfSync::Result::NONE
    )
  end

  def entry_id(report) = report.detail[/queued as (\S+);/, 1]

  def handbacks = journal.grep(Lain::Telemetry::Handback)

  def landed(id)
    Lain::Isolation::MergeCoordinator::Spool::Result.new(
      id:, report: Lain::Isolation::WorkerHandoff::Report.new(kind: :merged), verification: nil, batch: 1
    )
  end

  describe "a child that committed and returned" do
    it "is queued, not merged: the branch is unchanged and the spool holds one entry for its commit" do
      before = tip
      lease = committed_lease

      report = handoff.reclaim(lease, worker_id: "dev-1")

      expect(tip).to eq(before)
      expect(git("rev-parse", ref_for("dev-1"))).to eq(@c1)
      expect(spool.pending.map { |entry| [entry.id, entry.worker.sha, entry.worker.ref] })
        .to eq([[entry_id(report), @c1, ref_for("dev-1")]])
      expect(report).to have_attributes(kind: :queued, ref: ref_for("dev-1"), sha: @c1)
      expect(lease.released?).to be(true)
    end

    it "tells the model the entry id and how to wait on it" do
      report = handoff.reclaim(committed_lease, worker_id: "dev-1")

      expect(report.detail).to eq("queued as #{entry_id(report)}; lain land wait #{entry_id(report)} --branch feat")
      expect(report.summary).to include(entry_id(report)).and include("lain land wait")
    end

    it "asks for a drainer of the branch, run from the main worktree, homed beside the spool" do
      handoff.reclaim(committed_lease, worker_id: "dev-1")

      expect(spawner.calls).to eq([{ branch: "feat", root: @repo, home: home.dir }])
    end

    it "journals one handback record, queued, carrying what the sync did" do
      sync = Lain::Isolation::SelfSync::Result.new(outcome: :current)

      handoff.reclaim(committed_lease, worker_id: "dev-1", sync:)

      expect(handbacks.map { |record| [record.outcome, record.ref, record.sync] })
        .to eq([[:queued, ref_for("dev-1"), :current]])
    end

    it "says how to drain by hand when no drainer could be started" do
      refusing = described_class.new(handback: Lain::Isolation::Worktree::Handback.new(
        repo_root: @repo, base: Lain::Isolation::WorkingBranch::NONE
      ), repo_root: @repo, branch: "feat", spawner: spawner_class.new(started: false))

      report = refusing.reclaim(committed_lease, worker_id: "dev-1")

      expect(report.kind).to eq(:queued)
      expect(report.detail).to end_with(
        "; #{format(Lain::Isolation::MergeCoordinator::Spawner::BY_HAND, branch: "feat")}"
      )
    end

    it "keeps a journal that raises from overturning the report" do
      raising = Object.new.tap { |journal| def journal.<<(_record) = raise(IOError, "closed stream") }
      handing = described_class.new(handback: Lain::Isolation::Worktree::Handback.new(
        repo_root: @repo, base: Lain::Isolation::WorkingBranch::NONE
      ), repo_root: @repo, branch: "feat", journal: raising, spawner:)

      report = handing.reclaim(committed_lease, worker_id: "dev-1")

      expect(report).to have_attributes(kind: :queued, ref: ref_for("dev-1"), sha: @c1)
      expect(spool.pending.size).to eq(1)
    end
  end

  describe "the commit that is queued" do
    # The anchor's answer is what is queued, never the ref read back by name,
    # which another handback under the same worker id may already have moved.
    it "is the one the anchor answered, whatever the worker ref holds by then" do
      lease = committed_lease
      git("update-ref", ref_for("dev-1"), git("rev-parse", "feat"))
      anchor = Lain::Isolation::Worktree::Handback::Outcome.new(
        kind: :declined, worker_key: "dev-1", ref: ref_for("dev-1"), sha: @c1,
        detail: Lain::Isolation::Worktree::Handback::ANCHOR_ONLY
      )
      handback = instance_double(Lain::Isolation::Worktree::Handback, anchor:)

      described_class.new(handback:, repo_root: @repo, branch: "feat", spawner:).reclaim(lease, worker_id: "dev-1")

      expect(spool.pending.map { |entry| entry.worker.sha }).to eq([@c1])
      expect(queued_refs.map { |line| line.split.last }).to eq([@c1])
    end

    it "stays reachable from its own queued ref after a second chat reuses the worker id, until its entry completes" do
      first = handoff.reclaim(committed_lease("dev-1", body: "first\n"), worker_id: "dev-1")
      c1 = @c1
      second = handoff.reclaim(committed_lease("dev-1", body: "second\n"), worker_id: "dev-1")
      c2 = @c1

      while_queued = queued_refs
      spool.complete(entry_id(first), landed(entry_id(first)))

      expect(git("rev-parse", ref_for("dev-1"))).to eq(c2)
      expect(while_queued).to contain_exactly("#{entry_id(first)} #{c1}", "#{entry_id(second)} #{c2}")
      expect(queued_refs).to eq(["#{entry_id(second)} #{c2}"])
    end
  end

  describe "a drained entry" do
    it "lands on the chat's branch, and lain land wait for its id exits 0" do
      write_config(@repo, %(isolation verify: ["sh", "-c", "exit 0"]\n))
      report = handoff.reclaim(committed_lease, worker_id: "dev-1")

      Lain::Isolation::MergeCoordinator::Drain.for(repo_root: @repo, branch: "feat", paths:).call
      status = Lain::CLI::Land.new(cwd: @repo, paths:).wait(entry_id(report), branch: "feat", timeout: 5)

      expect(contains?(@c1)).to be(true)
      expect(status).to eq(0)
      expect(queued_refs).to be_empty
    end
  end

  describe "a child whose checks still fail after their retries" do
    it "is anchored and not queued, and nothing is spawned" do
      report = handoff.reclaim(committed_lease, worker_id: "dev-1", sync: failed_checks)

      expect(git("rev-parse", ref_for("dev-1"))).to eq(@c1)
      expect(spool.pending).to be_empty
      expect(spawner.calls).to be_empty
      expect(report).to have_attributes(kind: :declined, ref: ref_for("dev-1"), sha: @c1)
      expect(handbacks.map(&:outcome)).to eq([:declined])
    end

    it "gives the parent the ref, that the checks failed, and their output" do
      report = handoff.reclaim(committed_lease, worker_id: "dev-1", sync: failed_checks)
      answer = Lain::Response.new(content: [{ "type" => "text", "text" => "done" }], stop_reason: :end_turn)

      given = Lain::Isolation::Leases::Held.new(value: nil, report:, sync: failed_checks).delivered(answer)

      told = given.content.map { |block| block["text"] }.join
      expect(told).to include(ref_for("dev-1")).and include("not queued because the checks failed")
        .and include("lint said: f is wrong")
    end
  end

  describe "a dirty parent" do
    it "no longer blocks a handback, and the human's edits stay as they were" do
      lease = committed_lease
      File.write(File.join(@repo, "f"), "human edit\n")

      report = handoff.reclaim(lease, worker_id: "dev-1")

      expect(report.kind).to eq(:queued)
      expect(File.read(File.join(@repo, "f"))).to eq("human edit\n")
      expect(git("status", "--porcelain")).to eq("M f")
    end
  end

  describe "a coordinator home that cannot be written" do
    it "answers failed, naming the ref the work is anchored on, and holds no queued ref" do
      FileUtils.mkdir_p(File.join(@repo, ".git"))
      File.write(File.join(@repo, ".git", Lain::Isolation::MergeCoordinator::DIRECTORY), "not a directory")

      report = handoff.reclaim(committed_lease, worker_id: "dev-1")

      expect(report).to have_attributes(kind: :failed, ref: ref_for("dev-1"))
      expect(report.detail).to start_with("anchored but not queued")
      expect(git("rev-parse", ref_for("dev-1"))).to eq(@c1)
      expect(queued_refs).to be_empty
    end
  end

  describe "#surrender" do
    it "anchors only: the commit stays on its ref, the spool stays empty, and nothing is spawned" do
      lease = committed_lease

      report = handoff.surrender(lease, worker_id: "dev-1")

      expect(git("rev-parse", ref_for("dev-1"))).to eq(@c1)
      expect(spool.pending).to be_empty
      expect(queued_refs).to be_empty
      expect(spawner.calls).to be_empty
      expect(report).to have_attributes(kind: :declined, ref: ref_for("dev-1"), sha: @c1)
      expect(lease.released?).to be(true)
    end

    it "says how to queue the anchored work by hand" do
      report = handoff.surrender(committed_lease, worker_id: "dev-1")

      expect(report.detail).to include(ref_for("dev-1"))
        .and include("lain land enqueue #{ref_for("dev-1")} --branch feat --id dev-1")
    end
  end

  describe "nothing to hand back" do
    it "answers nothing to do for a child that committed nothing, and queues nothing" do
      lease = backend.acquire("dev-1")

      report = handoff.reclaim(lease, worker_id: "dev-1")

      expect(report.kind).to eq(:nothing_to_do)
      expect(spool.pending).to be_empty
      expect(spawner.calls).to be_empty
      expect(lease.released?).to be(true)
    end

    it "answers nothing to do for no lease, or one already released" do
      released = backend.acquire("dev-1").tap(&:release)

      expect([handoff.reclaim(nil, worker_id: "dev-1").kind, handoff.surrender(released, worker_id: "dev-1").kind])
        .to eq(%i[nothing_to_do nothing_to_do])
    end
  end

  describe ".over, the production construction" do
    it "queues into the main worktree's spool for the branch, and names the repository it anchors in" do
      built = described_class.over(repo_root: @repo, branch: "feat")

      report = built.reclaim(committed_lease, worker_id: "dev-1")

      expect(built.repo_root).to eq(@repo)
      expect(report.kind).to eq(:queued)
      expect(spool.pending.map { |entry| entry.worker.sha }).to eq([@c1])
    end
  end
end
