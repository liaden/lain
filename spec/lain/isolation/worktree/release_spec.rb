# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "mixlib/shellout"

RSpec.describe Lain::Isolation::Worktree::Release, :seam do
  around do |example|
    Dir.mktmpdir("lain-repo") do |repo|
      Dir.mktmpdir("lain-worktrees") do |worktrees|
        @repo_root = File.realpath(repo)
        @root = File.realpath(worktrees)
        FileUtils.cp_r("#{SeedRepo.at({ "README" => "seed\n" })}/.", @repo_root)
        example.run
      end
    end
  end

  let(:base) { Lain::Isolation::WorkingBranch.checked_out(repo_root: @repo_root) }
  let(:backend) { Lain::Isolation::Worktree.new(repo_root: @repo_root, root: @root, base:) }
  let(:registry) { Lain::Isolation::Worktree::Registry.new(repo_root: @repo_root, shell_out_factory: Lain::Shell::Out.public_method(:new)) }
  let(:release) { described_class.new(registry:, clock: -> { Time.utc(2026, 9, 1) }) }

  def checkout_with_uncommitted_work
    lease = backend.acquire("worker-1")
    path = lease.origin.path
    File.write(File.join(path, "README"), "modified\n")
    File.write(File.join(path, "new.txt"), "written\n")
    path
  end

  describe "#call" do
    it "retains a checkout with uncommitted work by default" do
      path = checkout_with_uncommitted_work

      expect([release.call(path), File.exist?(File.join(path, "new.txt"))]).to eq([:retained, true])
    end

    it "removes a checkout with uncommitted work when told to discard it" do
      path = checkout_with_uncommitted_work

      expect([release.call(path, discard: true), File.exist?(path)]).to eq([:removed, false])
    end

    it "deregisters a discarded checkout from git" do
      path = checkout_with_uncommitted_work
      release.call(path, discard: true)

      listed = Mixlib::ShellOut.new("git", "-C", @repo_root, "worktree", "list", "--porcelain",
                                    environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB).run_command.stdout

      expect(listed).not_to include(path)
    end
  end
end
