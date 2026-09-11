# frozen_string_literal: true

require "async"
require "fileutils"
require "tmpdir"

# The one lock on a parent checkout, taken by everything that merges into it:
# a chat's handback and a landing queue, in this process or another. Drives a
# throwaway repository; never the lain repository it runs in.
RSpec.describe Lain::Isolation::ParentLock, :seam do
  include HeldParentLock

  around do |example|
    Dir.mktmpdir("lain-parent-lock") do |repo|
      @repo = File.realpath(repo)
      FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", @repo)
      example.run
    end
  end

  let(:lock) { described_class.for(repo_root: @repo) }

  def free?(path = lock.path)
    File.open(path, File::RDWR | File::CREAT) { |file| file.flock(File::LOCK_EX | File::LOCK_NB) }
  end

  it "is one object per repository, whichever directory inside it names it" do
    FileUtils.mkdir_p(File.join(@repo, "sub"))

    expect(described_class.for(repo_root: File.join(@repo, "sub"))).to be(lock)
    expect(lock.path).to eq(File.join(@repo, ".git", described_class::NAME))
  end

  it "holds the file lock for the block, and takes it once when re-entered" do
    inner = outer = nil

    lock.hold do
      lock.hold { inner = free? }
      outer = free?
    end

    expect([inner, outer]).to eq([false, false])
    expect(free?).to be_truthy
  end

  it "answers the block's value" do
    expect(lock.hold { :merged }).to eq(:merged)
  end

  # A waiter has to be able to say who it is waiting on.
  it "names its holder in the lock file while held, and clears it after" do
    during = lock.hold { File.read(lock.path) }

    expect(during).to include("pid=#{Process.pid}")
    expect(File.read(lock.path)).to be_empty
  end

  it "tells a waiter who holds it, once, through its notice, when its patience runs out" do
    notices = []
    patient = described_class.new(path: lock.path, interval: 0.01, patience: 0.05)
    holder = nil

    while_held_elsewhere(@repo) do |pid|
      holder = pid
      waiting = Thread.new { patient.hold(notice: ->(text) { notices << text }) { :entered } }
      deadline = Time.now + 5
      sleep(0.01) until notices.any? || Time.now > deadline
      expect(waiting).to be_alive
    end

    expect(notices.size).to eq(1)
    expect(notices.first).to include("pid=#{holder}")
  end

  it "waits while another process holds it, then proceeds" do
    entered = nil

    while_held_elsewhere(@repo) do
      entered = Thread.new { lock.hold { :entered } }
      expect(entered.join(0.5)).to be_nil
    end

    expect(entered.value).to eq(:entered)
  end

  # Polling with Kernel#sleep rather than a blocking flock, so a fiber waiting
  # on another process yields to the reactor instead of stalling it.
  it "polls through its sleeper rather than blocking the thread" do
    path = File.join(@repo, ".git", described_class::NAME)
    slept = []

    File.open(path, File::RDWR | File::CREAT) do |blocker|
      blocker.flock(File::LOCK_EX)
      polling = described_class.new(path:, sleeper: lambda { |seconds|
        slept << seconds
        blocker.flock(File::LOCK_UN)
      })

      expect(polling.hold { :entered }).to eq(:entered)
    end
    expect(slept.size).to eq(1)
  end

  it "lets one fiber in at a time" do
    log = []
    Sync do |task|
      %i[first second].map do |name|
        task.async do
          lock.hold do
            log << [name, :in]
            sleep(0.01)
            log << [name, :out]
          end
        end
      end.each(&:wait)
    end

    expect(log).to eq([%i[first in], %i[first out], %i[second in], %i[second out]])
  end

  it "guards within this process only, for a directory in no repository" do
    failing = lambda do |*_argv, **|
      Struct.new(:stdout, :stderr, :exitstatus) { def run_command = self }.new("", "not a git repository", 128)
    end
    outside = described_class.for(repo_root: File.join(@repo, "elsewhere"), shell_out_factory: failing)

    expect(outside.path).to be_nil
    expect(outside.hold { :ran }).to eq(:ran)
  end
end
