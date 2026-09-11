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
