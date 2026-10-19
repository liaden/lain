# frozen_string_literal: true

require "fileutils"
require "json"
require "rbconfig"
require "tmpdir"

RSpec.describe Lain::Isolation::MergeCoordinator::Drain, :seam do
  around do |example|
    Dir.mktmpdir("lain-drain") do |repo|
      Dir.mktmpdir("lain-drain-state") do |state|
        @repo = File.realpath(repo)
        @state = File.realpath(state)
        FileUtils.cp_r("#{SeedRepo.at({ "f" => "a\n" })}/.", @repo)
        git("branch", "-M", "main")
        File.write(File.join(@repo, ".git", "info", "exclude"), ".lain/\n", mode: "a")
        example.run
      end
    end
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => @state, "XDG_STATE_HOME" => @state }) }
  let(:passing) { ["sh", "-c", "exit 0"] }

  def home = Lain::Isolation::MergeCoordinator::Home.for(repo_root: @repo, branch: "main")

  def spool = Lain::Isolation::MergeCoordinator::Spool.new(home)

  def configure(verify:, **settings)
    table = { verify:, **settings }.map { |key, value| "#{key}: #{value.inspect}" }.join(", ")
    write_config(@repo, "isolation #{table}\n")
  end

  def drain(**) = described_class.for(repo_root: @repo, branch: "main", paths:, **)

  def git(*) = SeedRepo.git(@repo, *).stdout.strip

  def tip = git("rev-parse", "refs/heads/main")

  def on_branch?(sha)
    Lain::Shell::Out.new("git", "-C", @repo, "merge-base", "--is-ancestor", sha, "refs/heads/main",
                         environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB).run_command.exitstatus.zero?
  end

  # Each worker writes a file of its own, so a second landing of the same
  # work would be a second first-parent commit touching it.
  def landings_of(file) = git("log", "--format=%H", "--first-parent", "refs/heads/main", "--", file).lines.size

  def worker(id, from: tip, file: id)
    git("switch", "-q", "--detach", from)
    File.write(File.join(@repo, file), "#{id}\n")
    git("add", file)
    git("commit", "-q", "-m", "#{id} work")
    sha = git("rev-parse", "HEAD")
    ref = Lain::Isolation::Worktree::Handback::Naming.new(id).ref
    git("update-ref", ref, sha)
    git("switch", "-q", "main")
    Lain::Isolation::LandingQueue::Worker.new(id:, ref:, sha:)
  end

  def key(worker) = Lain::Isolation::Worktree::Handback::Naming.new(worker.id).key

  def records(type)
    Dir.glob(File.join(paths.sessions_dir(project: paths.project_hash(@repo)), "*.ndjson"))
       .flat_map { |file| File.readlines(file).map { |line| JSON.parse(line) } }
       .select { |record| record["type"] == type }
  end

  def batch_records = records("landing_batch")

  def drainer_script
    File.join(@state, "drain-child.rb").tap do |script|
      File.write(script, <<~RUBY)
        require "lain"
        File.write(ARGV[2], Process.pid.to_s) if ARGV[2]
        paths = Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => ARGV[1], "XDG_STATE_HOME" => ARGV[1] })
        Lain::Isolation::MergeCoordinator::Drain.for(repo_root: ARGV[0], branch: "main", paths:).call
      RUBY
    end
  end

  def spawn_drainer(*ready)
    log = File.join(@state, "drainer.log")
    Process.spawn(RbConfig.ruby, "-I", File.expand_path("../../../../lib", __dir__), drainer_script, @repo, @state,
                  *ready, pgroup: true, out: log, err: log)
  end

  def await(path)
    deadline = Lain::RunClock::MONOTONIC.call + 20
    sleep 0.05 until File.size?(path) || Lain::RunClock::MONOTONIC.call > deadline
    raise "the drainer never got there: #{File.read(File.join(@state, "drainer.log"))}" unless File.size?(path)
  end

  def reaped(pid)
    deadline = Lain::RunClock::MONOTONIC.call + 20
    sleep 0.05 until Process.wait(pid, Process::WNOHANG) || Lain::RunClock::MONOTONIC.call > deadline
    return if Lain::RunClock::MONOTONIC.call <= deadline

    Process.kill(:KILL, -pid)
    Process.wait(pid)
    raise "the drainer #{pid} did not exit within 20s: #{File.read(File.join(@state, "drainer.log"))}"
  end

  describe "the production construction" do
    it "lands a queued worker, completes its entry as merged, and journals one landing_batch for the project" do
      configure(verify: passing)
      w1 = worker("w1")
      entry = spool.enqueue(w1)

      landed = drain.call

      expect(landed).to eq(1)
      expect(on_branch?(w1.sha)).to be(true)
      expect(spool.result(entry.id).report).to have_attributes(kind: :merged, ref: w1.ref)
      expect(spool.pending).to be_empty
      expect(batch_records.size).to eq(1)
      expect(batch_records.first).to include("branch" => "main", "desk" => "candidate",
                                             "worker_keys" => [key(w1)], "landed" => [key(w1)],
                                             "outcome" => "landed", "verifies" => 1)
    end

    it "journals under the main worktree's project and verifies in its tree when it drains from a linked worktree" do
      configure(verify: passing)
      linked = File.join(@state, "linked")
      git("worktree", "add", "-q", "--detach", linked)
      w1 = worker("w1")
      spool.enqueue(w1)

      described_class.for(repo_root: linked, branch: "main", paths:).call

      expect(on_branch?(w1.sha)).to be(true)
      shared = Lain::Isolation::VerifyCheckout.for(repo_root: @repo, branch: "main", paths:, keep: []).path
      expect(Dir.exist?(shared)).to be(true)
      expect(batch_records.size).to eq(1)
      expect(Dir.exist?(paths.container("sessions", key: paths.project_hash(linked)))).to be(false)
    end

    it "reads the main worktree's config when it drains from a linked worktree, so main's failing verify holds" do
      configure(verify: ["sh", "-c", "exit 1"])
      linked = File.join(@state, "linked")
      git("worktree", "add", "-q", "--detach", linked)
      w1 = worker("w1")
      entry = spool.enqueue(w1)

      described_class.for(repo_root: linked, branch: "main", paths:).call

      expect(on_branch?(w1.sha)).to be(false)
      expect(spool.result(entry.id).verification.outcome).to eq(:failed)
    end

    it "leaves no session file behind when nothing was pending" do
      configure(verify: passing)

      drain.call

      expect(Dir.children(paths.sessions_dir(project: paths.project_hash(@repo)))).to be_empty
    end

    it "records a wait of 0 rather than a negative one when the wall clock stepped back" do
      isolation = Lain::Config::Isolation.from({ "verify" => passing }, path: nil)
      base = Lain::Isolation::WorkingBranch.new("main", repo_root: @repo, git: Lain::Isolation::Checkout.new(@repo))
      journal = []
      journal.define_singleton_method(:close) { nil }
      w1 = worker("w1")
      spool.enqueue(w1)
      queue_for = lambda do |journal:, verify:|
        Lain::Isolation::LandingQueue.candidate(root: @repo, base:, journal:, isolation:, paths:, verify:,
                                                lock: described_class::AlreadyHeld)
      end

      described_class.new(lock: home.drain_lock, branch: "main", spool:, isolation:, journal: -> { journal },
                          verify: Lain::Isolation::Verifier.from(isolation, paths:), queue_for:,
                          wall_clock: -> { Time.at(0) }).call

      expect(journal.grep(Lain::Telemetry::LandingBatch).first.queue_wait_s).to eq(key(w1) => 0.0)
    end

    it "times the verifier into verify_wall_s" do
      configure(verify: ["sh", "-c", "sleep 0.2"])
      spool.enqueue(worker("w1"))

      drain.call

      expect(batch_records.first["verify_wall_s"]).to be >= 0.2
    end

    it "counts a worker already on main as landed" do
      configure(verify: passing)
      w1 = worker("w1")
      git("merge", "-q", "--ff-only", w1.sha)
      entry = spool.enqueue(w1)

      drain.call

      expect(spool.result(entry.id).report.kind).to eq(:nothing_to_do)
      expect(batch_records.first).to include("landed" => [key(w1)], "outcome" => "landed")
    end

    it "hands the queue the configured rebase_retries and merge strategy" do
      configure(verify: passing, rebase_retries: 3, conflict_style: "diff3", diff_algorithm: "patience")
      allow(Lain::Isolation::LandingQueue).to receive(:new).and_call_original
      spool.enqueue(worker("w1"))

      drain.call

      expect(Lain::Isolation::LandingQueue).to have_received(:new).with(hash_including(retries: 3))
      strategy = Lain::Isolation::MergeStrategy.new(conflict_style: "diff3", diff_algorithm: "patience").to_s
      expect(records("handback").map { |record| record["strategy"] }).to eq([strategy])
    end

    it "builds a batch again only rebuild_cap times while the branch keeps moving" do
      counter = File.join(@state, "verifies")
      racing = "echo run >> #{counter}; git -C #{@repo} update-ref refs/heads/main " \
               "$(git -C #{@repo} commit-tree 'main^{tree}' -p main -m racing)"
      configure(verify: ["sh", "-c", racing], rebuild_cap: 1)
      entry = spool.enqueue(worker("w1"))

      drain.call

      expect(File.readlines(counter).size).to eq(2)
      expect(spool.result(entry.id).report).to have_attributes(kind: :declined,
                                                               detail: a_string_including("moved 2 times"))
    end

    it "ejects the worker that fails verification, naming each worker's verdict and batch" do
      configure(verify: ["sh", "-c", "test ! -e w2 || { echo w2 breaks it; exit 1; }"])
      w1 = worker("w1")
      w2 = worker("w2")
      entries = [w1, w2].map { |each| spool.enqueue(each) }

      drain.call

      results = entries.map { |entry| spool.result(entry.id) }
      expect(results.map { |each| [each.report.kind, each.verification.outcome, each.batch] })
        .to eq([%i[merged passed].push(1), %i[declined failed].push(1)])
      expect(results.last.report.detail).to include("w2 breaks it")
      expect(batch_records.first).to include("landed" => [key(w1)], "ejected" => [key(w2)], "declined" => [],
                                             "outcome" => "partial", "verifies" => 3, "rebuilds" => 0)
      expect(batch_records.first["queue_wait_s"].keys).to eq([key(w1), key(w2)])
    end

    it "counts a worker that conflicts as declined, not ejected" do
      configure(verify: passing)
      git("switch", "-q", "--detach", tip)
      File.write(File.join(@repo, "f"), "theirs\n")
      git("commit", "-q", "-am", "w1 edits f")
      w1sha = git("rev-parse", "HEAD")
      w1ref = Lain::Isolation::Worktree::Handback::Naming.new("w1").ref
      git("update-ref", w1ref, w1sha)
      git("switch", "-q", "main")
      File.write(File.join(@repo, "f"), "ours\n")
      git("commit", "-q", "-am", "main edits f")
      w1 = Lain::Isolation::LandingQueue::Worker.new(id: "w1", ref: w1ref, sha: w1sha)
      spool.enqueue(w1)

      drain.call

      expect(batch_records.first).to include("landed" => [], "ejected" => [], "declined" => [key(w1)],
                                             "outcome" => "none")
    end
  end

  describe "an entry enqueued while the drainer finishes" do
    it "is landed by the recheck after the lock is released, not stranded" do
      configure(verify: passing)
      first = worker("w1")
      late = worker("w2")
      spool.enqueue(first)
      locked_out = []
      late_entry = nil
      allow(Lain::Isolation::MergeCoordinator::Spool).to receive(:new).and_wrap_original do |original, *args, **kw|
        real = original.call(*args, **kw)
        allow(real).to receive(:pending).and_wrap_original do |listing|
          listed = listing.call
          if listed.empty? && late_entry.nil?
            late_entry = spool.enqueue(late)
            locked_out << !home.drain_lock.try { nil }
          end
          listed
        end
        real
      end

      drain.call

      expect(locked_out).to eq([true])
      expect(spool.result(late_entry.id).report).to have_attributes(kind: :merged)
      expect(on_branch?(late.sha)).to be(true)
    end
  end

  describe "two entries for one worker" do
    it "lands them in separate batches, the later waiting for the next" do
      configure(verify: passing)
      w1 = worker("w1")
      again = worker("w1", from: w1.sha, file: "w1-more")
      entries = [w1, again].map { |each| spool.enqueue(each) }

      drain.call

      expect(entries.map { |entry| spool.result(entry.id).batch }).to eq([1, 2])
      expect(batch_records.map { |record| record["worker_keys"] }).to eq([[key(w1)], [key(w1)]])
      expect([on_branch?(w1.sha), on_branch?(again.sha)]).to eq([true, true])
    end
  end

  describe "a drainer that finds the lock held" do
    it "answers at once when nothing is pending" do
      configure(verify: passing)

      expect(home.drain_lock.try { expect(drain.call).to eq(0) }).to be(true)
    end

    it "keeps trying while entries are pending, and lands them once the holder releases" do
      configure(verify: passing)
      ready = File.join(@state, "drainer.pid")
      entry = nil
      drainer = nil
      home.drain_lock.try do
        entry = spool.enqueue(worker("w1"))
        drainer = spawn_drainer(ready)
        await(ready)
        sleep 0.3
      end

      reaped(drainer)

      expect(spool.result(entry.id)&.report&.kind).to eq(:merged)
    end
  end

  describe "the notice" do
    it "reaches the verify, which says when it leaves a dead holder's verify group running" do
      configure(verify: passing)
      spool.enqueue(worker("w1"))
      orphan = Process.spawn({ "TMPDIR" => @state }, "sleep", "60", pgroup: true)
      lock = File.join(paths.state_home, "locks", "suite.lock")
      FileUtils.mkdir_p(File.dirname(lock))
      File.write(lock, "pid=999999999 command=lain land drain verify_pgid=#{orphan} start=-\n")
      notices = []

      drain(notice: notices.method(:<<)).call

      expect(notices).to contain_exactly(a_string_including("verify group #{orphan}", "left it running"))
    ensure
      Process.kill(:KILL, orphan)
      Process.wait(orphan)
    end
  end

  describe "a drainer killed mid-batch" do
    let(:marker) { File.join(@state, "verifying.pid") }

    it "leaves work a second drainer finishes, with one result per entry and each commit landed once" do
      configure(verify: ["sh", "-c", "echo $$ > #{marker}; exec sleep 60"])
      workers = %w[w1 w2].map { |id| worker(id) }
      entries = workers.map { |each| spool.enqueue(each) }
      drainer = spawn_drainer
      await(marker)
      verifier = Integer(File.read(marker))
      begin
        Process.kill(:KILL, -drainer)
        Process.wait(drainer)
      ensure
        Process.kill(:KILL, verifier)
      end

      configure(verify: passing)
      drain.call

      expect(entries.map { |entry| spool.result(entry.id)&.report&.kind }).to eq(%i[merged merged])
      expect(Dir.children(home.results).sort).to eq(entries.map { |entry| "#{entry.id}.json" }.sort)
      expect(workers.map { |each| on_branch?(each.sha) }).to eq([true, true])
      expect(workers.map { |each| landings_of(each.id) }).to eq([1, 1])
    end
  end

  describe "batch_cap" do
    it "drains five entries as batches of 2, 2 and 1" do
      configure(verify: passing, batch_cap: 2)
      workers = %w[w1 w2 w3 w4 w5].map { |id| worker(id) }
      entries = workers.map { |each| spool.enqueue(each) }

      landed = drain.call

      expect(landed).to eq(3)
      expected = workers.map { |each| key(each) }.each_slice(2).to_a
      expect(batch_records.map { |record| record["worker_keys"] }).to eq(expected)
      expect(batch_records.map { |record| record["verifier"] }).to eq(%w[command] * 3)
      expect(entries.map { |entry| spool.result(entry.id).batch }).to eq([1, 1, 2, 2, 3])
      expect(workers.map { |each| on_branch?(each.sha) }).to all(be(true))
    end
  end
end
