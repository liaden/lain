# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "rbconfig"

# The spawner is always injected here: nothing in this file starts a lain
# process, and the state dir is a throwaway, never the real one.
RSpec.describe Lain::CLI::GcSchedule do
  around do |example|
    Dir.mktmpdir("lain-gc-schedule") do |dir|
      @state = File.join(dir, "state")
      @project = File.join(dir, "project")
      FileUtils.mkdir_p(@project)
      example.run
    end
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => @state }) }
  let(:now) { Time.utc(2026, 9, 11, 12) }
  let(:spawned) { [] }
  let(:spawner) { ->(argv, **options) { spawned << [argv, options] } }
  let(:program) { "/opt/lain/exe/lain" }

  def schedule(program: self.program, spawner: self.spawner)
    described_class.new(root: @project, paths:, clock: -> { now }, spawner:, program:)
  end

  def stamp = schedule.stamp_path

  def stamp_aged(hours)
    FileUtils.mkdir_p(File.dirname(stamp))
    File.write(stamp, "stamped\n")
    File.utime(now - (hours * 3600), now - (hours * 3600), stamp)
  end

  it "spawns exactly one detached run when the stamp is 25 hours old, and renews the stamp" do
    stamp_aged(25)

    expect(schedule.call).to be(true)
    expect(spawned.size).to eq(1)
    expect(File.mtime(stamp)).to eq(now)
  end

  it "spawns nothing while the stamp is fresh, and leaves it alone" do
    stamp_aged(2)

    expect(schedule.call).to be(false)
    expect(spawned).to be_empty
    expect(File.mtime(stamp)).to eq(now - (2 * 3600))
  end

  it "spawns on the first launch ever, when there is no stamp yet" do
    expect(schedule.call).to be(true)
    expect(File.mtime(stamp)).to eq(now)
  end

  # The tmux-pane trap in another shape: `lain` resolved from PATH finds
  # whatever `bundle exec` or the shell put there, which production may not
  # have. The launching binary, run by the running interpreter, is the one
  # command that is certainly this lain.
  it "composes the launching binary under the running ruby, never a `lain` looked up on PATH" do
    schedule.call

    argv = spawned.first.first
    expect(argv).to eq([RbConfig.ruby, program, "worktrees", "gc"])
    expect(argv).not_to include("lain")
  end

  it "runs detached in the project, reading nothing from the terminal and writing only to a log under state_home" do
    schedule.call

    options = spawned.first.last
    expect(options).to include(chdir: @project, in: File::NULL, pgroup: true)
    expect([options[:out], options[:err]]).to eq([[schedule.log_path, "a"], [schedule.log_path, "a"]])
    expect(schedule.log_path).to start_with(paths.state_home)
  end

  it "spawns nothing, and writes no stamp, from a launcher that is not lain" do
    expect(schedule(program: "/usr/bin/rspec").call).to be(false)
    expect([spawned, File.exist?(stamp)]).to eq([[], false])
  end

  it "spawns nothing while another launch holds the stamp" do
    FileUtils.mkdir_p(File.dirname(stamp))
    File.open(stamp, File::RDWR | File::CREAT) do |held|
      held.flock(File::LOCK_EX)

      expect(schedule.call).to be(false)
    end
    expect(spawned).to be_empty
  end

  it "leaves a stale stamp stale when the spawn fails, so the next launch tries again" do
    stamp_aged(25)
    failing = ->(*, **) { raise Errno::ENOENT, "ruby" }

    expect(schedule(spawner: failing).call).to be(false)
    expect(File.mtime(stamp)).to eq(now - (25 * 3600))
  end

  it "never lets housekeeping abort a launch: an unwritable state dir spawns nothing" do
    FileUtils.mkdir_p(@state)
    File.write(File.join(@state, "lain"), "a file where the state dir should be")

    expect(schedule.call).to be(false)
    expect(spawned).to be_empty
  end

  describe ".for" do
    it "keys the stamp on the project a directory resolves to, not the directory itself" do
      project = File.realpath(@project)
      FileUtils.mkdir_p(File.join(project, ".git"))
      sub = File.join(project, "a", "b")
      FileUtils.mkdir_p(sub)

      expect(described_class.for(cwd: sub, paths:).stamp_path)
        .to eq(described_class.new(root: project, paths:).stamp_path)
    end

    it "schedules nothing when the directory resolves to no project" do
      expect(described_class.for(cwd: File.join(@project, "missing"), paths:).call).to be(false)
    end
  end

  it "keeps one stamp per project" do
    expect(stamp).to eq(File.join(paths.state_home, "gc", "worktrees-#{paths.project_hash(@project)}.stamp"))
  end

  it "detaches what the real spawner starts, so no launch waits on it" do
    waiter = described_class::SPAWN.call(["true"], in: File::NULL, out: File::NULL, err: File::NULL)

    expect(waiter.value).to be_success
  end
end
