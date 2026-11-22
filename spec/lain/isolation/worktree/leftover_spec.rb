# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# A leftover a new lease set aside stays readable to that lease: the reaper
# keeps it while the lease lives, and ages it from its first retention once
# the lease ends or its process dies, never from the move. Real git and the
# real reaper over a throwaway repository and worktree root.
RSpec.describe Lain::Isolation::Worktree::Leftover, :seam do
  around do |example|
    Dir.mktmpdir("lain-leftover-repo") do |repo|
      Dir.mktmpdir("lain-leftover-root") do |root|
        @repo_root = File.realpath(repo)
        @root = File.realpath(root)
        FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", @repo_root)
        run_git(@repo_root, "branch", "-M", "main")
        example.run
      end
    end
  end

  let(:day) { 86_400 }
  let(:cut) { Time.utc(2026, 9, 1, 12) }
  let(:base) do
    Lain::Isolation::WorkingBranch.new("main", repo_root: @repo_root, git: Lain::Isolation::Checkout.new(@repo_root))
  end

  def run_git(dir, *) = SeedRepo.git(dir, *).stdout

  def lock_line(path)
    run_git(@repo_root, "worktree", "list", "--porcelain").split("\n\n")
                                                          .find { |entry| entry.include?("worktree #{path}\n") }
                                                          .to_s[/^locked.*$/].to_s
  end

  def dead_table
    Lain::Isolation::LeaseLock::ProcessTable.new(pid: Process.spawn("true").tap { |pid| Process.wait(pid) })
  end

  def backend(table: Lain::Isolation::LeaseLock::ProcessTable.new)
    Lain::Isolation::Worktree.new(repo_root: @repo_root, root: @root, base:, process_table: table,
                                  clock: -> { cut + (13 * day) })
  end

  def gc(at:) = Lain::Isolation::Gc.new(repo_root: @repo_root, root: @root, retain_days: 7, clock: -> { at }).call

  def record_for(records, path) = records.find { |record| record.name == path }

  def aside = Dir.glob(File.join(@root, Lain::Isolation::Worktree::RETAINED, "*")).first

  # An attempt that crashed leaving spike/ and tools/ uncommitted, its cut
  # stamped on the day it was made.
  before do
    crashed = backend(table: dead_table).acquire("issue.demo.a.1").worker_env.cwd
    FileUtils.mkdir_p([File.join(crashed, "spike"), File.join(crashed, "tools")])
    File.write(File.join(crashed, "spike", "probe.rb"), "probe\n")
    File.write(File.join(crashed, "tools", "run.sh"), "run\n")
    File.utime(cut, cut, File.join(crashed, ".git"))
  end

  it "keeps a tree set aside while the lease that set it aside lives, past its first retention's week" do
    lease = backend.acquire("issue.demo.a.1")
    kept = aside

    record = record_for(gc(at: cut + (8 * day)), kept)

    expect([record.action, record.reason])
      .to eq([:kept, "leased by live process #{Process.pid} on #{Socket.gethostname}"])
    expect(File.read(File.join(kept, "spike", "probe.rb"))).to eq("probe\n")
  ensure
    lease&.release
  end

  it "expires the tree past its first retention's week once the lease that set it aside is released" do
    backend.acquire("issue.demo.a.1").release
    kept = aside

    record = record_for(gc(at: cut + (8 * day)), kept)

    expect([record.action, File.exist?(kept)]).to eq([:kept, false])
    expect(record.reason).to start_with("expired after 7 days")
  end

  it "ages the tree from its first retention when the lease that set it aside dies holding it" do
    backend(table: dead_table).acquire("issue.demo.a.1")
    kept = aside
    held = lock_line(kept)

    young = record_for(gc(at: cut + (6 * day)), kept)
    expired = record_for(gc(at: cut + (8 * day)), kept)

    expect(held).to start_with("locked lain-lease ").and end_with(" since=2026-09-01T12:00:00Z")
    expect([young.action, young.reason]).to eq([:kept, "uncommitted changes; retained until 2026-09-08T12:00:00Z"])
    expect([expired.action, File.exist?(kept)]).to eq([:kept, false])
  end
end
