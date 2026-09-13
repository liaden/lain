# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"

load File.expand_path("../../../exe/lain", __dir__) unless defined?(LainCLI::Worktrees)

RSpec.describe Lain::CLI::Worktrees do
  around do |example|
    Dir.mktmpdir("lain-worktrees-cli") do |dir|
      @state = File.join(dir, "state")
      @repo = File.join(dir, "repo")
      FileUtils.mkdir_p(File.join(@repo, ".git"))
      example.run
    end
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => @state }) }
  let(:at) { Time.utc(2026, 9, 11, 12) }

  def record(action, subject, name, reason) = Lain::Telemetry::WorktreeReap.new(action:, subject:, name:, reason:)

  def worktrees(gc_factory:, root: @repo)
    described_class.new(root:, paths:, home: Dir.home, gc_factory:, clock: -> { at })
  end

  # A reaper double whose run lands its records on the journal it was given,
  # as the real one does, and remembers what it was built with.
  def reaper(records, seen = {})
    lambda do |**kwargs|
      seen.merge!(kwargs)
      Struct.new(:journal, :records) do
        def call
          records.each do |each|
            journal << each
          end
        end
      end.new(kwargs[:journal], records)
    end
  end

  def unreached(name) = record(:kept, :anchor, name, "no branch reaches 0123456789ab")

  it "heads the run with when and where, says what it reaped and kept and why, then counts them" do
    records = [record(:reaped, :worktree, "/state/wt/a", "landed on main"), unreached("refs/lain/worker/w")]

    expect(worktrees(gc_factory: reaper(records)).gc).to eq(<<~REPORT.chomp)
      lain worktrees gc at 2026-09-11T12:00:00Z in #{@repo}
      reaped worktree /state/wt/a: landed on main
      kept 1 anchor no branch reaches, 1 new since the last run:
        refs/lain/worker/w
      1 reaped, 1 kept
    REPORT
  end

  # Kept anchors are kept indefinitely, so a daily log that re-listed every
  # one would bury the day's news under the same lines each morning.
  it "summarises the anchors it has already reported rather than re-listing them" do
    worktrees(gc_factory: reaper([unreached("refs/lain/worker/a")])).gc

    report = worktrees(gc_factory: reaper([unreached("refs/lain/worker/a"), unreached("refs/lain/worker/b")])).gc

    expect(report.lines.map(&:chomp)).to include("kept 2 anchors no branch reaches, 1 new since the last run:",
                                                 "  refs/lain/worker/b")
    expect(report).not_to include("  refs/lain/worker/a")
  end

  it "says so when there was nothing to reap or keep" do
    expect(worktrees(gc_factory: reaper([])).gc)
      .to eq("lain worktrees gc at 2026-09-11T12:00:00Z in #{@repo}\nnothing to reap or keep")
  end

  it "hands the reaper the root chat leases under, the configured retain_days, and a journal under state_home" do
    FileUtils.mkdir_p(File.join(@repo, ".lain"))
    File.write(File.join(@repo, ".lain", "config.toml"), "[isolation]\nretain_days = 3\n")
    seen = {}

    worktrees(gc_factory: reaper([record(:kept, :worktree, "/x", "live")], seen)).gc
    journal = Dir.glob(File.join(paths.state_home, "gc", "*.ndjson"))

    expect(seen.slice(:repo_root, :root, :retain_days))
      .to eq(repo_root: @repo, root: File.join(paths.state_home, "worktrees", paths.project_hash(@repo)),
             retain_days: 3)
    expect(journal.size).to eq(1)
    expect(File.readlines(journal.first).map { |line| JSON.parse(line)["type"] }).to eq(["worktree_reap"])
  end

  # Two runs over one repository would race each other's compare-and-swaps
  # and report each other's removals as git refusals. A second run has
  # nothing to add, so it stops at once rather than waiting.
  it "does nothing, and says so, while another gc holds this repository" do
    lock = File.join(paths.state_home, "gc", "worktrees-#{paths.project_hash(@repo)}.lock")
    FileUtils.mkdir_p(File.dirname(lock))
    built = []

    report = File.open(lock, File::RDWR | File::CREAT) do |held|
      held.flock(File::LOCK_EX)
      worktrees(gc_factory: ->(**kwargs) { built << kwargs }).gc
    end

    expect(report).to eq("another lain worktrees gc is running for #{@repo}; this run did nothing")
    expect(built).to be_empty
  end

  it "refuses outside a git repository, naming what it needs" do
    Dir.mktmpdir("lain-not-a-repo") do |elsewhere|
      expect { worktrees(gc_factory: reaper([]), root: elsewhere).gc }
        .to raise_error(Lain::Error, /lain worktrees gc needs a git repository/)
    end
  end

  # Through the DEFAULT, not an injected override: `home:` is left unpassed,
  # so `initialize`'s own `home: paths.home_or_nil` runs, against a `paths`
  # double standing in for a box with no home available at all -- neither
  # env nor `Dir.home` resolving is exactly what {Paths#home_or_nil} answers
  # nil for. Doubled rather than driven through real `Dir.home`/`$HOME`
  # because whether the real box has a passwd entry for its uid is
  # nondeterministic and not what this scenario is about.
  it "reports that no home is available, rather than an unnamed refusal" do
    allow(paths).to receive(:home_or_nil).and_return(nil)

    expect { described_class.new(root: @repo, paths:, gc_factory: reaper([]), clock: -> { at }).gc }
      .to raise_error(Lain::Error, /lain worktrees gc stops its repository search at \$HOME/)
  end

  # The reaper and the chat backend must agree on where a repository's
  # worktrees live, or the reaper would sweep an empty directory forever.
  it "reaps under the very root a chat leases its workers from", :seam do
    Dir.mktmpdir("lain-worktrees-seam") do |dir|
      repo = File.realpath(dir)
      FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", repo)
      lease = Lain::CLI::IsolationBackend.resolve("worktree", root: repo, paths:, home: Dir.home).acquire("worker-1")

      report = described_class.new(root: repo, paths:, home: Dir.home).gc

      expect(report).to include("kept worktree #{lease.worker_env.cwd}: leased by live process #{Process.pid}")
    ensure
      lease&.release
    end
  end

  describe "lain worktrees gc" do
    # The project root, as chat resolves it: config is read from there, and a
    # bare working directory is what the tree forbids as a default.
    it "is registered beside epic, and hands the reaper the resolved project's root" do
      allow(described_class).to receive(:new).and_return(instance_double(described_class, gc: "1 reaped, 0 kept"))

      expect { LainCLI.start(%w[worktrees gc], debug: true) }.to output("1 reaped, 0 kept\n").to_stdout
      expect(described_class).to have_received(:new).with(root: Lain::Project::Resolver.default_project.root)
    end
  end
end
