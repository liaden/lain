# frozen_string_literal: true

require "English"
require "fileutils"
require "json"
require "tmpdir"

RSpec.describe Lain::Isolation::MergeCoordinator::Spool do
  around do |example|
    Dir.mktmpdir("lain-spool") do |dir|
      @home = Lain::Isolation::MergeCoordinator::Home.new(git_dir: dir, key: "main-0123456789ab")
      example.run
    end
  end

  def spool = described_class.new(@home, refs: unheld)

  # These examples are about the files, and their shas name no commit, so no
  # ref is held for them; the git-backed examples below hold real ones.
  def unheld
    Class.new do
      def hold(_id, _sha) = nil
      def release(_id) = nil
    end.new
  end

  def worker(id) = Lain::Isolation::LandingQueue::Worker.new(id:, ref: "refs/lain/worker/#{id}", sha: "a" * 40)

  def report(detail: "landed", paths: ["f"])
    Lain::Isolation::WorkerHandoff::Report.new(kind: :merged, ref: "refs/lain/worker/w", sha: "b" * 40, paths:,
                                               detail:)
  end

  def verification = Lain::Isolation::LandingQueue::Verification.new(outcome: :passed, tip: "c" * 40, detail: "ok")

  def result_for(id, **report_fields)
    described_class::Result.new(id:, report: report(**report_fields), verification:, batch: 1)
  end

  def entry_file(id) = File.join(@home.entries, "#{id}.json")

  # Fork rather than threads: the contention the spool serves is between processes.
  def in_child
    Process.fork do
      yield
      exit!(0)
    ensure
      exit!(1)
    end
  end

  def reap(pids) = pids.map { |pid| Process.wait2(pid).last.exitstatus }

  it "answers entries from many processes oldest first, each process's in the order it wrote them" do
    pids = Array.new(8) do |process|
      in_child do
        25.times do |n|
          described_class.new(@home, refs: unheld).enqueue(worker("p#{process}-w#{n.to_s.rjust(2, "0")}"))
        end
      end
    end

    expect(reap(pids)).to all(eq(0))
    ids = spool.pending.map { |entry| entry.worker.id }
    expect(ids.size).to eq(200)
    expect(ids.group_by { |id| id[/\Ap\d/] }.values).to all(satisfy { |each| each == each.sort })
  end

  it "keeps what was enqueued: the worker, its ref and sha, and the wall-clock time" do
    stamp = Time.at(1_700_000_000, 250, :millisecond)
    entry = described_class.new(@home, refs: unheld, wall_clock: -> { stamp }).enqueue(worker("w1"))

    expect(spool.pending).to eq([entry])
    expect(entry.worker).to eq(worker("w1"))
    expect(entry.enqueued_at).to eq(stamp.to_f)
  end

  it "keeps enqueue order inside one process even when the clock does not move" do
    still = described_class.new(@home, refs: unheld, clock: -> { 1_000.0 })
    ids = Array.new(10) { |n| "w#{n}" }
    ids.each { |id| still.enqueue(worker(id)) }

    expect(spool.pending.map { |entry| entry.worker.id }).to eq(ids)
  end

  it "answers a completed entry's result, and deletes the entry" do
    entry = spool.enqueue(worker("w1"))

    spool.complete(entry.id, result_for(entry.id))

    expect(File.exist?(entry_file(entry.id))).to be(false)
    expect(spool.result(entry.id)).to eq(result_for(entry.id))
    expect(spool.pending).to be_empty
  end

  it "reads back a result equal to the one written, its report and verification rebuilt" do
    entry = spool.enqueue(worker("w1"))
    written = result_for(entry.id)

    spool.complete(entry.id, written)

    read = spool.result(entry.id)
    expect(read).to eq(written)
    expect(read.report).to be_moved
    expect(read.verification.outcome).to eq(:passed)
  end

  it "reads back a result with no verification and no batch" do
    entry = spool.enqueue(worker("w1"))
    written = described_class::Result.new(id: entry.id, report:, verification: nil, batch: nil)

    spool.complete(entry.id, written)

    expect(spool.result(entry.id)).to eq(written)
  end

  it "refuses a result whose report, verification or batch is the wrong type" do
    expect { described_class::Result.new(id: "x", report: report.to_h, verification: nil, batch: nil) }
      .to raise_error(ArgumentError, /report/)
    expect { described_class::Result.new(id: "x", report:, verification: "passed", batch: nil) }
      .to raise_error(ArgumentError, /verification/)
    expect { described_class::Result.new(id: "x", report:, verification: nil, batch: "1") }
      .to raise_error(ArgumentError, /batch/)
  end

  it "keeps a result whose detail and paths are not valid UTF-8, scrubbed" do
    entry = spool.enqueue(worker("w1"))

    verification = Lain::Isolation::LandingQueue::Verification.new(outcome: :failed, tip: "c" * 40, detail: "x\xFE".b)
    garbled = report(detail: "said \xFF".b, paths: ["caf\xE9.txt".b])
    spool.complete(entry.id, described_class::Result.new(id: entry.id, report: garbled, verification:, batch: 1))

    read = spool.result(entry.id)
    expect([read.report.detail, *read.report.paths, read.verification.detail]).to all(satisfy(&:valid_encoding?))
    expect(read.report.detail).to start_with("said ")
  end

  it "reads its files as UTF-8 whatever the locale says" do
    entry = spool.enqueue(worker("wörker"))
    original = Encoding.default_external
    begin
      Encoding.default_external = Encoding::US_ASCII
      waiting = spool.pending.map { |each| each.worker.id }
      spool.complete(entry.id, result_for(entry.id, detail: "12 examples ✓"))
      read = spool.result(entry.id)
    ensure
      Encoding.default_external = original
    end

    expect(waiting).to eq(["wörker"])
    expect(read.report.detail).to eq("12 examples ✓")
  end

  it "answers nil for an entry with no result yet" do
    expect(spool.result(spool.enqueue(worker("w1")).id)).to be_nil
  end

  it "does not list, and deletes, an entry whose result was written before a crash could delete it" do
    crashed = spool.enqueue(worker("w1"))
    waiting = spool.enqueue(worker("w2"))
    survivor = File.read(entry_file(crashed.id))
    spool.complete(crashed.id, result_for(crashed.id))
    File.write(entry_file(crashed.id), survivor)

    expect(spool.pending).to eq([waiting])
    expect(File.exist?(entry_file(crashed.id))).to be(false)
  end

  it "takes an entry's id from its file name, not its body" do
    id = "00000000000000000001-1-abcd"
    FileUtils.mkdir_p(@home.entries)
    File.write(entry_file(id), JSON.generate(worker: worker("w1").to_h, enqueued_at: 1.0))

    expect(spool.pending.map(&:id)).to eq([id])
  end

  it "refuses a corrupt result, naming its file" do
    id = spool.enqueue(worker("w1")).id
    FileUtils.mkdir_p(@home.results)
    File.write(File.join(@home.results, "#{id}.json"), "{nope")

    expect { spool.result(id) }.to raise_error(Lain::Error, /#{Regexp.escape(File.join(@home.results, "#{id}.json"))}/)
  end

  it "refuses an entry file whose name is not a minted id, naming it" do
    FileUtils.mkdir_p(@home.entries)
    File.write(entry_file("foreign"), JSON.generate(worker: worker("w1").to_h, enqueued_at: 1.0))

    expect { spool.pending }.to raise_error(Lain::Error, /#{Regexp.escape(entry_file("foreign"))}/)
  end

  it "refuses a corrupt entry, naming its file" do
    FileUtils.mkdir_p(@home.entries)
    File.write(entry_file("00000000000000000001-1-abcd"), "{not json")

    expect { spool.pending }.to raise_error(Lain::Error, /#{Regexp.escape(entry_file("00000000000000000001-1-abcd"))}/)
  end

  it "lets another process poll pending while every entry is completed" do
    entries = Array.new(100) { |n| spool.enqueue(worker("w#{n}")) }
    ready = File.join(@home.dir, "ready")
    done = File.join(@home.dir, "done")
    reader = in_child do
      File.write(ready, "")
      described_class.new(@home, refs: unheld).pending until File.exist?(done)
    end
    begin
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      Thread.pass until File.exist?(ready) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      entries.each { |entry| spool.complete(entry.id, result_for(entry.id)) }
    ensure
      File.write(done, "")
    end

    expect(reap([reader])).to eq([0])
  end

  it "refuses a result filed under another entry's id" do
    entry = spool.enqueue(worker("w1"))

    expect { spool.complete(entry.id, result_for("other")) }.to raise_error(ArgumentError, /other/)
  end

  it "refuses an id that wraps a minted one before touching the filesystem" do
    minted = spool.enqueue(worker("w1")).id
    FileUtils.rm_rf(@home.entries)

    ["../x", "a/b", "../#{minted}"].each do |id|
      expect { spool.result(id) }.to raise_error(Lain::Error, /#{Regexp.escape(id)}/)
      expect { spool.complete(id, result_for(id)) }.to raise_error(Lain::Error, /#{Regexp.escape(id)}/)
    end
    expect(Dir.children(@home.dir)).to be_empty
  end

  describe "the ref each queued commit is held under" do
    around do |example|
      Dir.mktmpdir("lain-spool-repo") do |repo|
        @repo = File.realpath(repo)
        FileUtils.cp_r("#{SeedRepo.at({ "f" => "a\n" })}/.", @repo)
        @home = Lain::Isolation::MergeCoordinator::Home.for(repo_root: @repo, branch: "main")
        example.run
      end
    end

    def held = SeedRepo.git(@repo, "for-each-ref", "--format=%(refname) %(objectname)", "refs/lain/queued/").stdout
    def seed = SeedRepo.git(@repo, "rev-parse", "HEAD").stdout.strip
    def queued(id) = Lain::Isolation::MergeCoordinator::Spool.new(@home).enqueue(worker(id).with(sha: seed))

    it "holds the commit under a ref named for the branch and the entry, from enqueue until complete" do
      entry = queued("w1")
      held_while_queued = held

      described_class.new(@home).complete(entry.id, result_for(entry.id))

      expect(held_while_queued).to eq("refs/lain/queued/#{@home.key}/#{entry.id} #{seed}\n")
      expect(held).to be_empty
    end

    it "lets the ref go when pending deletes an entry a stopped drainer completed" do
      entry = queued("w1")
      FileUtils.mkdir_p(@home.results)
      File.write(File.join(@home.results, "#{entry.id}.json"), "{}")

      expect(described_class.new(@home).pending).to be_empty
      expect(held).to be_empty
    end

    it "refuses, writing no entry, when git will not write the ref" do
      missing = "1" * 40

      expect { described_class.new(@home).enqueue(worker("w1").with(sha: missing)) }
        .to raise_error(Lain::Error, /could not hold #{missing}/)
      expect(Dir.glob("*", base: @home.entries)).to be_empty
      expect(held).to be_empty
    end

    it "refuses, writing no entry, when the ref already exists" do
      Lain::Isolation::MergeCoordinator::Spool::QueuedRefs.for(@home).tap do |refs|
        allow(refs).to receive(:ref).and_return("refs/lain/queued/#{@home.key}/taken")
        refs.hold("taken", seed)
        spool = described_class.new(@home, refs:)

        expect { spool.enqueue(worker("w1").with(sha: seed)) }.to raise_error(Lain::Error, /could not hold/)
      end
      expect(Dir.glob("*", base: @home.entries)).to be_empty
    end

    it "holds no ref for an entry that could not be written" do
      FileUtils.mkdir_p(@home.dir)
      File.write(@home.entries, "a file where the entries directory goes")

      expect { queued("w1") }.to raise_error(SystemCallError)
      expect(held).to be_empty
    end
  end

  it "never lets a reader see half a result" do
    entry = spool.enqueue(worker("w1"))
    whole = result_for(entry.id, detail: "x" * 4_000_000)
    writer = in_child { described_class.new(@home, refs: unheld).complete(entry.id, whole) }

    reads = []
    reads << spool.result(entry.id) until Process.wait(writer, Process::WNOHANG)
    reads << spool.result(entry.id)

    expect($CHILD_STATUS).to be_success
    expect(reads.last).to eq(whole)
    expect(reads.compact.uniq).to eq([whole])
  end
end
