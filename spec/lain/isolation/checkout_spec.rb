# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "mixlib/shellout"

# Operates on a THROWAWAY repo copied from {SeedRepo}, never the lain repo.
RSpec.describe Lain::Isolation::Checkout, :seam do
  subject(:checkout) { described_class.new(@dir) }

  around do |example|
    Dir.mktmpdir("lain-checkout") do |dir|
      @dir = File.realpath(dir)
      FileUtils.cp_r("#{SeedRepo.at({ "README" => "seed\n" })}/.", @dir)
      example.run
    end
  end

  def run_git(*args)
    shell = Mixlib::ShellOut.new("git", "-C", @dir, *args, environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
    shell.run_command.error!
    shell.stdout.strip
  end

  describe "#symbolic_head" do
    it "names the branch HEAD is on" do
      expect(checkout.symbolic_head).to eq("refs/heads/#{run_git("branch", "--show-current")}")
    end

    it "answers empty for a detached HEAD, never a nil to guard" do
      run_git("switch", "-q", "--detach", "HEAD")

      expect(checkout.symbolic_head).to eq("")
    end
  end

  describe "#update_ref" do
    it "writes a ref only over the value it expects, and stamps its reflog" do
      head = run_git("rev-parse", "HEAD")

      first = checkout.update_ref("refs/lain/probe", head, "", reason: "lain probe")
      second = checkout.update_ref("refs/lain/probe", head, "", reason: "lain probe")

      expect([first.exitstatus, second.exitstatus.zero?]).to eq([0, false])
      expect(run_git("reflog", "refs/lain/probe")).to include("lain probe")
    end
  end

  # Every shape of "git is half way through something", because a reader that
  # only knew about merges answered false for four of the five and read a
  # partial or empty diff as the truth.
  describe "#operation_in_progress?" do
    # Two commits touching the same line from a common base, which is what a
    # merge, a rebase, a cherry-pick and a revert each need in order to stop.
    def diverge!
      seed = run_git("rev-parse", "HEAD")
      trunk = run_git("branch", "--show-current")
      commit!("ours")
      run_git("checkout", "-q", "-b", "other", seed)
      commit!("theirs")
      run_git("checkout", "-q", trunk)
      [trunk, seed]
    end

    def commit!(body)
      File.write(File.join(@dir, "a.rb"), body)
      run_git("add", "-A")
      run_git("commit", "-q", "-m", body)
    end

    # Each of these STOPS on a conflict, so a nonzero status is the point of
    # the call rather than a failure of the example.
    def attempt(*args, **environment)
      Mixlib::ShellOut.new("git", "-C", @dir, *args,
                           environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB.merge(environment)).run_command
    end

    it "answers false for a checkout git has finished with" do
      expect(checkout.operation_in_progress?).to be(false)
    end

    # The one in-between state that is NOT a refusal: a commit-to-commit diff
    # cannot see the working tree, so uncommitted edits cannot change it.
    it "answers false for a tree that is merely dirty" do
      File.write(File.join(@dir, "a.rb"), "uncommitted\n")

      expect(checkout.operation_in_progress?).to be(false)
    end

    it "answers true for a conflicted merge" do
      diverge!
      attempt("merge", "other")

      expect(checkout.operation_in_progress?).to be(true)
    end

    it "answers true for a conflicted rebase" do
      trunk, = diverge!
      run_git("checkout", "-q", "other")
      attempt("rebase", trunk)

      expect(checkout.operation_in_progress?).to be(true)
    end

    # The state with no pseudo-ref of any kind: nothing conflicted, HEAD simply
    # parked, and the diff it would answer with is empty.
    it "answers true for a rebase stopped at a break, which leaves no pseudo-ref to find" do
      seed = run_git("rev-parse", "HEAD")
      commit!("two")
      attempt("rebase", "-i", seed, "GIT_SEQUENCE_EDITOR" => "sed -i '1i break'")

      expect(checkout.operation_in_progress?).to be(true)
    end

    it "answers true for a conflicted cherry-pick" do
      diverge!
      attempt("cherry-pick", "other")

      expect(checkout.operation_in_progress?).to be(true)
    end

    it "answers true for a conflicted revert" do
      commit!("one")
      commit!("two")
      attempt("revert", "--no-edit", "HEAD~1")

      expect(checkout.operation_in_progress?).to be(true)
    end

    it "answers true for a patch series git am stopped on" do
      diverge!
      patches = File.join(@dir, "patches")
      run_git("format-patch", "-q", "-1", "-o", patches, "other")
      attempt("am", *Dir[File.join(patches, "*.patch")])

      expect(checkout.operation_in_progress?).to be(true)
    end

    it "answers true during a bisect, whose HEAD is some commit nobody asked about" do
      seed = run_git("rev-parse", "HEAD")
      commit!("one")
      commit!("two")
      run_git("bisect", "start")
      run_git("bisect", "bad", "HEAD")
      run_git("bisect", "good", seed)

      expect(checkout.operation_in_progress?).to be(true)
    end
  end

  # A git hook exports `-c` config to its children as GIT_CONFIG_PARAMETERS, and
  # GIT_CONFIG_COUNT/KEY_n/VALUE_n carry the same thing another way. Either
  # would let the hook's settings steer every git call lain makes.
  describe "under a hook's exported config" do
    around do |example|
      polluted = { "GIT_CONFIG_PARAMETERS" => "'lain.probe'='leaked'", "GIT_CONFIG_COUNT" => "1",
                   "GIT_CONFIG_KEY_0" => "lain.other", "GIT_CONFIG_VALUE_0" => "leaked" }
      saved = ENV.to_h.slice(*polluted.keys)
      ENV.update(polluted)
      example.run
    ensure
      polluted.each_key { |key| ENV.delete(key) }
      ENV.update(saved)
    end

    it "reaches none of its git calls" do
      probes = %w[lain.probe lain.other].map { |key| checkout.run("config", "--get", key).exitstatus }

      expect(probes).to eq([1, 1])
    end
  end
end
