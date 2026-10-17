# frozen_string_literal: true

require "async"
require "fileutils"
require "tmpdir"

RSpec.describe Lain::Isolation::Worktree::RepoLock, :seam do
  around do |example|
    Dir.mktmpdir("lain-repo-lock") do |dir|
      @dir = File.realpath(dir)
      @repo = File.join(@dir, "repo")
      FileUtils.mkdir_p(@repo)
      FileUtils.cp_r("#{SeedRepo.at({ "README" => "seed\n" })}/.", @repo)
      example.run
    end
  end

  def holding(lock, log, name)
    lock.synchronize do
      log << "#{name}:in"
      yield
      log << "#{name}:out"
    end
  end

  def one_at_a_time?(entries)
    entries.each_slice(2).all? { |pair| pair.map { |entry| entry.split(":").first }.uniq.size == 1 }
  end

  it "is one lock for a repository however its path is spelled" do
    link = File.join(@dir, "link")
    File.symlink(@repo, link)

    expect(described_class.for(link)).to equal(described_class.for(@repo))
  end

  it "keys a path that does not exist by its expanded spelling" do
    missing = File.join(@dir, "nope", "..", "gone")

    expect(described_class.for(missing)).to equal(described_class.for(File.join(@dir, "gone")))
  end

  it "keeps 2 fibers on one thread out of each other's critical section" do
    lock = described_class.for(@repo)
    log = []
    Sync do |task|
      %w[a b].map { |n| task.async { holding(lock, log, n) { sleep 0.05 } } }.each(&:wait)
    end

    expect(one_at_a_time?(log)).to be(true)
  end

  it "keeps 2 threads out of each other's critical section" do
    lock = described_class.for(@repo)
    log = Queue.new
    Array.new(2) { |i| Thread.new { holding(lock, log, i) { sleep 0.05 } } }.each(&:join)
    entries = Array.new(log.size) { log.pop }

    expect(one_at_a_time?(entries)).to be(true)
  end

  it "keeps 2 processes out of each other's critical section" do
    log = File.join(@dir, "log")
    pids = Array.new(2) do |i|
      fork do
        described_class.for(@repo).synchronize do
          File.open(log, "a") { |f| f.puts "#{i}:in" }
          sleep 0.3
          File.open(log, "a") { |f| f.puts "#{i}:out" }
        end
        exit!(0)
      end
    end
    pids.each { |pid| Process.wait(pid) }

    expect(one_at_a_time?(File.readlines(log, chomp: true))).to be(true)
  end

  it "can be taken again by the holder without deadlocking" do
    lock = described_class.for(@repo)

    expect(lock.synchronize { lock.synchronize { :inner } }).to eq(:inner)
  end

  it "does not wait on a lock held for another repository" do
    other = File.join(@dir, "other")
    FileUtils.mkdir_p(other)
    FileUtils.cp_r("#{SeedRepo.at({ "README" => "seed\n" })}/.", other)
    reached = nil
    described_class.for(@repo).synchronize do
      Thread.new { described_class.for(other).synchronize { reached = true } }.join(2)
    end

    expect(reached).to be(true)
  end

  it "works from a linked worktree of the repository, taking the shared lock" do
    linked = File.join(@dir, "linked")
    SeedRepo.git(@repo, "worktree", "add", "--detach", linked, "HEAD")
    done = false
    described_class.for(@repo).synchronize do
      t = Thread.new { described_class.for(linked).synchronize { done = true } }
      sleep 0.2
      expect(done).to be(false)
      t.kill
    end
  end
end
