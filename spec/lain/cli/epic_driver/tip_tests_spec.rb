# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"

# The tip's own suite, run on the sha an implementation gate is about to name:
# checked out detached in a throwaway worktree, never in the checkout the actor
# held, because retirement rebased that one. Real git and a real rspec child,
# over a copy of layout_mini.
RSpec.describe Lain::CLI::EpicDriver::TipTests, :seam do
  around do |example|
    Dir.mktmpdir("lain-tip-tests") do |dir|
      @root = File.realpath(dir)
      FileUtils.mkdir_p(repo)
      SeedRepo.with_layout(layout_mini, into: repo)
      example.run
    end
  end

  let(:layout_mini) { File.expand_path("../../../fixtures/projects/layout_mini", __dir__) }
  let(:io) { StringIO.new }
  let(:journal) { Lain::Journal.new(io:) }
  let(:rspec) { ->(root) { Lain::Grader::TestHarness.new(root, adapter: Lain::Grader::TestHarness::Adapter::Rspec.new) } }
  let(:target) { "spec/unit/models/order_spec.rb" }

  def repo = File.join(@root, "repo")

  def tmp = File.join(@root, "tips")

  def git(*) = SeedRepo.git(repo, *).stdout.strip

  def commit(message, files)
    files.each do |path, body|
      FileUtils.mkdir_p(File.dirname(File.join(repo, path)))
      File.write(File.join(repo, path), body)
    end
    git("add", "-A")
    git("commit", "-q", "-m", message)
    git("rev-parse", "HEAD")
  end

  def tip_tests(harness: rspec) = described_class.new(repo_root: repo, harness:, journal:, tmp:)

  def journaled = Lain::Journal.records(io.string.lines, type: "tests_ran").to_a

  def worktrees = git("worktree", "list", "--porcelain").scan(/^worktree (.+)$/).flatten

  # Loading the spec file raises before any example is defined, which rspec
  # counts outside the examples.
  def broken = "# frozen_string_literal: true\n\nUndefinedOrderHelper.install\n"

  def passing
    <<~RUBY
      # frozen_string_literal: true

      require_relative "../../../app/models/order"

      RSpec.describe Order do
        it("starts empty") { expect(Order.new.total).to eq(0) }
      end
    RUBY
  end

  it "journals a red tip's run against the sha it was given, not the branch's newer head" do
    red = commit("break the suite", target => broken)
    commit("mend the suite", target => passing)

    record = tip_tests.call("a", red)

    expect(record).to have_attributes(issue_id: "a", sha: red, ran: true, errors: 1, passed: 0)
    expect(journaled.map { |row| row.slice(*record.to_journal.keys) }).to eq([record.to_journal])
  end

  it "counts a green tip's passing examples" do
    green = commit("a passing suite", target => passing)

    expect(tip_tests.call("a", green)).to have_attributes(ran: true, passed: 1, failed: 0, errors: 0)
  end

  it "leaves no worktree behind for the sha it tested" do
    red = commit("break the suite", target => broken)

    tip_tests.call("a", red)

    expect(worktrees).to eq([repo])
    expect(Dir.children(tmp)).to be_empty
  end

  it "says the tests were not run, and why, when the project declares no tests preset" do
    sha = commit("a passing suite", target => passing)

    record = tip_tests(harness: Lain::CLI::EpicDriver::DeclaredHarness.for(Lain::TestLayout::None)).call("a", sha)

    expect(record).to have_attributes(issue_id: "a", sha:, ran: false)
    expect(record.why).to include("no tests preset")
    expect(journaled.map { |row| row["ran"] }).to eq([false])
    expect(worktrees).to eq([repo])
  end

  # A run never touches registrations it did not make: pruning would drop a
  # human's worktree whose directory is gone, and the commits only it held.
  it "leaves another worktree's registration standing when that tree's directory is gone" do
    other = File.join(@root, "elsewhere", "human-tree")
    git("worktree", "add", "-q", "--detach", other, "HEAD")
    FileUtils.rm_rf(other)

    tip_tests.call("a", commit("a passing suite", target => passing))

    expect(worktrees).to include(other)
  end

  it "says the tests were not run, naming git's refusal, when the sha is not in the repository" do
    record = tip_tests.call("a", "0" * 40)

    expect(record).to have_attributes(ran: false, why: include("0" * 40, "could not check out"))
    expect(worktrees).to eq([repo])
    expect(Dir.children(tmp)).to be_empty
  end

  # A commit hook exports git's own context; the suite under test is a
  # different repository and must not inherit it.
  it "runs the suite without the git context of the process that called it" do
    seen = File.join(@root, "seen.txt")
    suite = "File.write(#{seen.inspect}, [ENV[\"GIT_INDEX_FILE\"], ENV[\"GIT_DIR\"]].inspect)\n"
    sha = commit("a suite that reports its env", target => suite)

    with_env("GIT_INDEX_FILE" => File.join(@root, "hook-index"), "GIT_DIR" => File.join(@root, "hook-git")) do
      tip_tests.call("a", sha)
    end

    expect(File.read(seen)).to eq([nil, nil].inspect)
  end

  def with_env(vars)
    saved = ENV.to_h.slice(*vars.keys)
    ENV.update(vars)
    yield
  ensure
    vars.each_key { |key| ENV.delete(key) }
    ENV.update(saved)
  end

  it "says the tests were not run, naming the harness's refusal, and removes the worktree, when the harness raises" do
    sha = commit("a passing suite", target => passing)
    refusing = ->(_root) { raise Lain::Grader::TestHarness::Timeout, "test command exceeded the 300s timeout" }

    record = tip_tests(harness: refusing).call("a", sha)

    expect(record).to have_attributes(ran: false, why: include("exceeded the 300s timeout"))
    expect(worktrees).to eq([repo])
    expect(Dir.children(tmp)).to be_empty
  end
end
