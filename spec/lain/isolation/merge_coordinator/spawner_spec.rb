# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "tmpdir"

RSpec.describe Lain::Isolation::MergeCoordinator::Spawner do
  around do |example|
    Dir.mktmpdir("lain-spawner") do |dir|
      @dir = File.realpath(dir)
      example.run
    end
  end

  let(:spawned) { [] }
  let(:recording) { ->(argv, **options) { spawned << [argv, options] } }
  let(:log) { File.join(@dir, Lain::Isolation::MergeCoordinator::DIRECTORY, "home", "drain.log") }

  def spawner(program: "/opt/lain/exe/lain", spawn: recording) = described_class.new(spawn:, program:)

  it "composes the launching binary under the running ruby, never a `lain` looked up on PATH" do
    spawner.call(%w[land drain --branch main], chdir: @dir, log:)

    expect(spawned.first.first).to eq([RbConfig.ruby, "/opt/lain/exe/lain", "land", "drain", "--branch", "main"])
  end

  it "starts the child in its own process group, reading nothing and appending both streams to the log" do
    expect(spawner.call(%w[land drain], chdir: @dir, log:)).to be(true)

    expect(spawned.first.last).to eq(chdir: @dir, in: File::NULL, out: [log, "a"], err: [log, "a"], pgroup: true)
    expect(Dir.exist?(File.dirname(log))).to be(true)
  end

  it "defaults to a detached spawn of its own tier, not the CLI's" do
    expect(described_class::SPAWN).not_to equal(Lain::CLI::GcSchedule::SPAWN)
  end

  it "expands a relative program against the submitter's directory" do
    Dir.chdir(@dir) { spawner(program: "exe/lain").call(%w[land drain], chdir: @dir, log:) }

    expect(spawned.first.first[1]).to eq(File.join(@dir, "exe", "lain"))
  end

  it "answers false, starting nothing, when the spawn itself fails" do
    expect(spawner(spawn: ->(*, **) { raise Errno::ENOENT, "ruby" }).call(%w[land drain], chdir: @dir, log:))
      .to be(false)
  end

  it "spawns nothing from a launcher that is not lain" do
    expect(spawner(program: "/usr/bin/rspec").call(%w[land drain], chdir: @dir, log:)).to be(false)
    expect(spawned).to be_empty
  end

  # The default spawn, so no double stands between the spawner and a real
  # child: a stand-in program named lain records how it was started.
  describe "#drain" do
    let(:home) { Lain::Isolation::MergeCoordinator::Home.new(git_dir: @dir, key: "home") }

    it "starts `lain land drain` for the branch and project, from the project, logging into the home" do
      started = spawner.drain(branch: "feat", root: "/repo", home:)

      expect(started).to be(true)
      expect(spawned.sole).to eq([[RbConfig.ruby, "/opt/lain/exe/lain", "land", "drain", "--branch", "feat",
                                   "--project", "/repo"],
                                  { chdir: "/repo", in: File::NULL, out: [log, "a"], err: [log, "a"], pgroup: true }])
    end

    it "answers false when nothing was started, and BY_HAND says how to drain instead" do
      expect(spawner(program: "/usr/bin/rspec").drain(branch: "feat", root: "/repo", home:)).to be(false)
      expect(format(described_class::BY_HAND, branch: "feat")).to eq("run `lain land drain --branch feat` to land it")
    end
  end

  it "runs a real detached child with the arguments, in the directory, leading its own group" do
    program = File.join(@dir, "lain")
    seen = File.join(@dir, "seen")
    File.write(program, <<~RUBY)
      File.write(#{seen.dump} + ".partial", [Dir.pwd, Process.getpgid(0) == Process.pid, *ARGV].join("\\n"))
      File.rename(#{seen.dump} + ".partial", #{seen.dump})
    RUBY

    expect(described_class.new(program:).call(%w[land drain --branch main], chdir: @dir, log:)).to be(true)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    sleep 0.02 until File.exist?(seen) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    expect(File.read(seen).split("\n")).to eq([@dir, "true", "land", "drain", "--branch", "main"])
  end
end
