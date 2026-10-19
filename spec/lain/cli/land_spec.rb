# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "securerandom"
require "tmpdir"

load File.expand_path("../../../exe/lain", __dir__) unless defined?(LainCLI)

RSpec.describe Lain::CLI::Land, :seam do
  around do |example|
    Dir.mktmpdir("lain-land") do |repo|
      Dir.mktmpdir("lain-land-state") do |state|
        @repo = File.realpath(repo)
        @state = File.realpath(state)
        FileUtils.cp_r("#{SeedRepo.at({ "f" => "a\n" })}/.", @repo)
        git(@repo, "branch", "-M", "main")
        File.write(File.join(@repo, ".git", "info", "exclude"), ".lain/\n", mode: "a")
        @worktree = File.join(@state, "w-alpha")
        @outside = File.join(@state, "outside")
        FileUtils.mkdir_p(@outside)
        git(@repo, "worktree", "add", "-q", "--detach", @worktree)
        File.write(File.join(@worktree, "alpha"), "alpha\n")
        git(@worktree, "add", "alpha")
        git(@worktree, "commit", "-q", "-m", "alpha work")
        example.run
      end
    end
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => @state, "XDG_STATE_HOME" => @state }) }
  let(:spawned) { [] }
  let(:recording) { ->(argv, **options) { spawned << [argv, options] } }
  let(:program) { "/opt/lain/exe/lain" }
  let(:spawner) { Lain::Isolation::MergeCoordinator::Spawner.new(spawn: recording, program:) }
  let(:sink) { StringIO.new }

  def land(cwd: @worktree, **) = described_class.new(cwd:, paths:, spawner:, sink:, **)

  def git(dir, *) = SeedRepo.git(dir, *).stdout.strip

  def home = Lain::Isolation::MergeCoordinator::Home.for(repo_root: @repo, branch: "main")

  def spool = Lain::Isolation::MergeCoordinator::Spool.new(home)

  def ref_for(id) = Lain::Isolation::Worktree::Handback::Naming.new(id).ref

  def commit = git(@worktree, "rev-parse", "HEAD")

  def queued(id = "w-alpha")
    spool.enqueue(Lain::Isolation::LandingQueue::Worker.new(id:, ref: ref_for(id), sha: commit))
  end

  def complete(entry, kind:)
    report = Lain::Isolation::WorkerHandoff::Report.new(kind:, ref: entry.worker.ref, sha: entry.worker.sha)
    result = Lain::Isolation::MergeCoordinator::Spool::Result.new(id: entry.id, report:, verification: nil, batch: 1)
    spool.complete(entry.id, result)
  end

  def exit_of
    yield
    nil
  rescue SystemExit => e
    e.status
  end

  describe "#enqueue" do
    it "anchors HEAD under the worktree's name, queues it, starts a drainer and says the entry id" do
      said = land.enqueue(branch: "main")

      expect(git(@repo, "rev-parse", ref_for("w-alpha"))).to eq(commit)
      expect(spool.pending.map { |entry| entry.worker.to_h })
        .to eq([{ id: "w-alpha", ref: ref_for("w-alpha"), sha: commit }])
      argv, options = spawned.sole
      expect(argv).to eq([RbConfig.ruby, program, "land", "drain", "--branch", "main", "--project", @repo])
      expect(options).to include(chdir: @repo, pgroup: true, in: File::NULL)
      expect(said).to include(spool.pending.sole.id, "position 1")
    end

    it "takes the ref and the id when given, and counts its place behind what is already queued" do
      queued("w-earlier")
      git(@worktree, "branch", "topic")

      said = land.enqueue("topic", branch: "main", id: "named")

      expect(git(@repo, "rev-parse", ref_for("named"))).to eq(commit)
      expect(spool.pending.map { |entry| entry.worker.id }).to eq(%w[w-earlier named])
      expect(said).to include("position 2")
    end

    it "lands on the branch the main worktree has checked out when none is named" do
      land.enqueue

      expect(spawned.sole.first).to include("--branch", "main")
      expect(spool.pending.size).to eq(1)
    end

    it "refuses to guess a branch when the main worktree is detached, and queues nothing" do
      git(@repo, "switch", "-q", "--detach")

      expect { land.enqueue }.to raise_error(Lain::Error, /detached HEAD/)
      expect(spool.pending).to be_empty
      expect(spawned).to be_empty
    end

    it "spawns the drainer with no lock of this process still held" do
      free = nil
      spawn = lambda do |argv, **options|
        free = home.drain_lock.try { nil }
        spawned << [argv, options]
      end

      land(spawner: Lain::Isolation::MergeCoordinator::Spawner.new(spawn:, program:)).enqueue(branch: "main")

      expect(spawned.size).to eq(1)
      expect(free).to be(true)
    end

    it "names the worker after the checkout, not the subdirectory it ran from" do
      sub = File.join(@worktree, "deep", "er")
      FileUtils.mkdir_p(sub)

      land(cwd: sub).enqueue(branch: "main")

      expect(spool.pending.sole.worker.id).to eq("w-alpha")
    end

    it "names the command to run when the drainer cannot be started" do
      failing = Lain::Isolation::MergeCoordinator::Spawner.new(spawn: ->(*, **) { raise Errno::EACCES, "lain" },
                                                               program:)

      said = land(spawner: failing).enqueue(branch: "main")

      expect(said).to include("lain land drain --branch main")
      expect(spool.pending.size).to eq(1)
    end

    it "names the command to run when this process cannot start a drainer" do
      quiet = Lain::Isolation::MergeCoordinator::Spawner.new(spawn: recording, program: "/usr/bin/rspec")

      said = land(spawner: quiet).enqueue(branch: "main")

      expect(spawned).to be_empty
      expect(said).to include("lain land drain --branch main")
    end
  end

  describe "#enqueue with an untrusted project config" do
    before do
      FileUtils.mkdir_p(File.join(@repo, ".lain"))
      File.write(File.join(@repo, ".lain", "config.rb"), "# #{SecureRandom.hex}\nshell exclude: %w[curl]\n")
    end

    it "refuses naming the file and lain trust, anchoring, queuing and spawning nothing" do
      config = Regexp.escape(File.join(@repo, ".lain", "config.rb"))

      expect { land.enqueue(branch: "main") }
        .to raise_error(Lain::Project::Trust::Untrusted, /#{config}.*lain trust/m)
      expect(spawned).to be_empty
      expect(spool.pending).to be_empty
      expect(git(@repo, "for-each-ref", ref_for("w-alpha"))).to be_empty
    end
  end

  describe "#drain" do
    it "drains the named project's queue through the production drainer" do
      write_config(@repo, "isolation verify: #{%w[sh -c true].inspect}\n")
      land.enqueue(branch: "main")
      entry_id = spool.pending.sole.id

      said = land(cwd: @state).drain(branch: "main", project: @repo)

      expect(spool.result(entry_id).report).to have_attributes(kind: :merged)
      expect(git(@repo, "merge-base", "--is-ancestor", commit, "main")).to eq("")
      expect(said).to include("1 batch", "main")
    end

    it "hands the drainer the notice it was given" do
      seen = {}
      drain_for = lambda do |**kwargs|
        seen.merge!(kwargs)
        Struct.new(:call).new(0)
      end
      notice = ->(_text) {}

      land(cwd: @state, drain_for:, notice:).drain(branch: "main", project: @repo)

      expect(seen).to include(notice:)
    end

    it "hands the drainer the project root it was given, never its own directory" do
      seen = {}
      drain_for = lambda do |**kwargs|
        seen.merge!(kwargs)
        Struct.new(:call).new(0)
      end

      land(cwd: @state, drain_for:).drain(branch: "main", project: @repo)

      expect(seen).to include(repo_root: @repo, branch: "main", paths:)
    end
  end

  describe "#wait" do
    it "prints the landed sha and exits 0 through the command line" do
      entry = queued
      complete(entry, kind: :merged)

      status = nil
      Dir.chdir(@worktree) do
        expect { status = exit_of { LainCLI.start(["land", "wait", entry.id, "--branch", "main"], debug: true) } }
          .to output(/#{commit}/).to_stdout
      end
      expect(status).to eq(0)
    end

    it "refuses an id the spool has neither queued nor answered, naming it and the branch" do
      unknown = "#{"0" * 19}1-1-abcd"

      expect { land.wait(unknown, branch: "main") }.to raise_error(Lain::Error, /#{unknown}.*main|main.*#{unknown}/)
    end

    it "refuses an entry queued for another branch than the one named" do
      entry = queued

      expect { land.wait(entry.id, branch: "other") }.to raise_error(Lain::Error, /#{entry.id}.*other/)
    end

    {
      "a malformed id" => -> { ["bogus", @worktree] },
      "an unknown id" => -> { ["#{"0" * 19}1-1-abcd", @worktree] },
      "a directory in no repository" => -> { ["#{"0" * 19}1-1-abcd", @outside] }
    }.each do |refusal, args|
      it "exits 64, not a landing verdict, on #{refusal}" do
        id, dir = instance_exec(&args)
        status = nil
        Dir.chdir(dir) do
          expect { status = exit_of { LainCLI.start(["land", "wait", id, "--branch", "main"], debug: true) } }
            .to output(/\S/).to_stderr
        end
        expect(status).to eq(64)
      end
    end

    it "exits 64 when no branch is named and the main worktree is detached" do
      git(@repo, "switch", "-q", "--detach")
      status = nil
      Dir.chdir(@worktree) do
        expect { status = exit_of { LainCLI.start(["land", "wait", "#{"0" * 19}1-1-abcd"], debug: true) } }
          .to output(/detached/).to_stderr
      end
      expect(status).to eq(64)
    end

    it "answers 1 and says what happened when the work did not land" do
      entry = queued
      complete(entry, kind: :declined)

      expect(land.wait(entry.id, branch: "main")).to eq(1)
      expect(sink.string).to include(entry.id, "declined")
    end

    it "answers 0 when the work was already on the branch" do
      entry = queued
      complete(entry, kind: :nothing_to_do)

      expect(land.wait(entry.id, branch: "main")).to eq(0)
      expect(sink.string).to include(entry.id, "already on main")
    end

    it "answers 130, never a landing, when interrupted while waiting" do
      entry = queued

      status = land(sleeper: ->(_) { raise Interrupt }).wait(entry.id, branch: "main")

      expect(status).to eq(130)
      expect(sink.string).to include("interrupted", entry.id)
    end

    it "polls every 50ms and answers 2 naming the entry as still queued once the timeout passes" do
      entry = queued
      now = 0.0
      naps = []
      waiting = land(clock: -> { now }, sleeper: lambda { |seconds|
        naps << seconds
        now += seconds
      })

      expect(waiting.wait(entry.id, branch: "main", timeout: 1)).to eq(2)
      expect(naps.uniq).to eq([0.05])
      expect(naps.sum).to be_within(0.06).of(1.0)
      expect(sink.string).to include(entry.id, "still queued")
    end
  end

  describe "#wait with no drainer" do
    def ticking
      now = 0.0
      { clock: -> { now }, sleeper: ->(seconds) { now += seconds } }
    end

    def dead_pid
      pid = Process.spawn("true")
      Process.wait(pid)
      pid
    end

    it "answers 3 and names the command to run once no live drainer has held the lock for 5 seconds" do
      entry = queued

      expect(land(**ticking).wait(entry.id, branch: "main")).to eq(3)
      expect(sink.string).to include(entry.id, "lain land drain --branch main")
    end

    it "answers 3 naming the pid a killed drainer left in its holder line" do
      entry = queued
      pid = dead_pid
      FileUtils.mkdir_p(home.dir)
      File.write(File.join(home.dir, "drain.lock"), "pid=#{pid} command=lain land drain\n")

      expect(land(**ticking).wait(entry.id, branch: "main")).to eq(3)
      expect(sink.string).to include("pid #{pid}", "lain land drain --branch main")
    end

    it "keeps waiting while a live drainer holds the lock" do
      entry = queued
      FileUtils.mkdir_p(home.dir)
      File.write(File.join(home.dir, "drain.lock"), "pid=#{Process.pid} command=lain land drain\n")

      expect(land(**ticking).wait(entry.id, branch: "main", timeout: 20)).to eq(2)
    end
  end

  describe "an unopenable drain lock" do
    def lock_file = File.join(home.dir, "drain.lock")

    around do |example|
      FileUtils.mkdir_p(home.dir)
      File.write(lock_file, "")
      File.chmod(0o000, lock_file)
      example.run
    ensure
      File.chmod(0o600, lock_file)
    end

    it "refuses enqueue over a lock that is readable but not writable, queuing and spawning nothing" do
      File.chmod(0o400, lock_file)

      expect { land.enqueue(branch: "main") }.to raise_error(Lain::Error, /#{Regexp.escape(lock_file)}/)
      expect(spawned).to be_empty
      expect(spool.pending).to be_empty
    end

    it "refuses enqueue by the lock's name rather than promising a drainer" do
      expect { land.enqueue(branch: "main") }.to raise_error(Lain::Error, /#{Regexp.escape(lock_file)}/)
      expect(spawned).to be_empty
    end

    it "makes status say one line naming the lock, as a refusal and not a backtrace" do
      Dir.chdir(@worktree) do
        expect { LainCLI.start(["land", "status", "--branch", "main"], debug: true) }
          .to raise_error(Thor::Error, /\A[^\n]*#{Regexp.escape(lock_file)}[^\n]*\z/)
      end
    end
  end

  it "must be told its directory" do
    expect { described_class.new(paths:) }.to raise_error(ArgumentError, /cwd/)
  end

  describe "#status" do
    def dead_pid
      pid = Process.spawn("true")
      Process.wait(pid)
      pid
    end

    def lock_file = File.join(home.dir, "drain.lock")

    it "lists the pending entries and names a live holder with how long it has held the lock" do
      entry = queued
      said = home.drain_lock.hold { land(wall_clock: -> { File.mtime(lock_file) + 7 }).status(branch: "main") }

      expect(said).to include(entry.id, "w-alpha", commit[0, 12])
      expect(said).to match(/drain lock held by pid=#{Process.pid} command=\S+.* for 7s/)
    end

    it "says no drainer is running when the lock names no holder" do
      said = land.status(branch: "main")

      expect(said).to include("nothing queued", "no drainer running")
      expect(said).not_to include("held by")
    end

    it "takes a pid it may not signal for a live one" do
      expect(described_class::ALIVE.call(1)).to be(true)
    end

    # A drainer killed with SIGKILL never empties its holder line, and status
    # must never take the lock to find out: a drainer starting in that
    # instant would fail its try and strand its entry.
    it "names a dead holder's line as stale, without taking the lock" do
      pid = dead_pid
      FileUtils.mkdir_p(home.dir)
      File.write(lock_file, "pid=#{pid} command=lain land drain\n")

      said = land.status(branch: "main")

      expect(said).to include("no drainer running; a stale holder line from pid #{pid} was left")
      expect(said).not_to include("held by")
      expect(File.read(lock_file)).to eq("pid=#{pid} command=lain land drain\n")
    end
  end
end
