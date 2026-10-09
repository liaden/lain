# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Lain::Isolation::VerifyCheckout, :seam do
  around do |example|
    Dir.mktmpdir("lain-repo") do |repo|
      Dir.mktmpdir("lain-state") do |state|
        @repo = File.realpath(repo)
        @state = File.realpath(state)
        FileUtils.cp_r("#{SeedRepo.at({ "README" => "seed\n" })}/.", @repo)
        example.run
      end
    end
  end

  let(:paths) { Lain::Paths.new(env: { "XDG_RUNTIME_DIR" => @state, "XDG_STATE_HOME" => @state }) }
  let(:keep) { [] }
  let(:checkout) { described_class.for(repo_root: @repo, branch: "main", paths:, keep:) }

  def git(*args) = SeedRepo.git(@repo, *args).stdout.strip

  def commit(name)
    File.write(File.join(@repo, name), "#{name}\n")
    git("add", name)
    git("commit", "-m", name)
    git("rev-parse", "HEAD")
  end

  def listed = git("worktree", "list", "--porcelain")

  def head_at(dir) = SeedRepo.git(dir, "rev-parse", "HEAD").stdout.strip

  describe "#at" do
    it "adds a detached, locked worktree on first use and reuses it after" do
      first = commit("one")
      second = commit("two")
      checkout.at(first)
      candidate = checkout.at(second)
      block = listed.split("\n\n").find { |entry| entry.include?(checkout.path) }

      expect([candidate.sha, candidate.path, head_at(checkout.path), block]).to match(
        [second, checkout.path, second, a_string_including("detached", "locked")]
      )
    end

    it "never lists the verify worktree as holding a branch" do
      checkout.at(commit("one"))

      expect(listed.scan(/^branch (.+)$/).flatten).to eq(["refs/heads/#{git("branch", "--show-current")}"])
    end

    it "keeps one worktree across uses, beside the main checkout" do
      checkout.at(commit("one"))
      checkout.at(commit("two"))

      expect(listed.scan(/^worktree /).size).to eq(2)
    end

    context "with a cache path to keep" do
      let(:keep) { ["target/"] }

      it "removes untracked files and keeps the cache paths" do
        checkout.at(commit("one"))
        FileUtils.mkdir_p(File.join(checkout.path, "target"))
        File.write(File.join(checkout.path, "target", "obj"), "cached")
        File.write(File.join(checkout.path, "junk.log"), "junk")
        checkout.at(commit("two"))

        expect([File.exist?(File.join(checkout.path, "junk.log")),
                File.exist?(File.join(checkout.path, "target", "obj"))])
          .to eq([false, true])
      end
    end

    it "resets over a dirty tracked file" do
      checkout.at(commit("one"))
      File.write(File.join(checkout.path, "README"), "edited\n")
      second = commit("two")
      checkout.at(second)

      expect([head_at(checkout.path), SeedRepo.git(checkout.path, "status", "--porcelain").stdout]).to eq([second, ""])
    end

    it "reuses the worktree across fresh instances" do
      checkout.at(commit("one"))
      second = commit("two")
      described_class.for(repo_root: @repo, branch: "main", paths:, keep:).at(second)

      expect([listed.scan(/^worktree /).size, head_at(checkout.path)]).to eq([2, second])
    end

    it "re-adds a worktree whose directory was deleted while its lock was live" do
      checkout.at(commit("one"))
      FileUtils.rm_rf(checkout.path)
      second = commit("two")
      checkout.at(second)

      expect([listed.scan(/^worktree /).size, head_at(checkout.path)]).to eq([2, second])
    end

    it "takes a dead drainer's lock over on reuse, so gc leaves the tree" do
      sha = commit("one")
      dead = Process.spawn("true").tap { |pid| Process.wait(pid) }
      built = lambda { |table|
        described_class.new(repo_root: @repo, path: checkout.path, keep:, process_table: table,
                            shell_out_factory: Lain::Shell::Out.public_method(:new))
      }
      built.call(Lain::Isolation::LeaseLock::ProcessTable.new(pid: dead)).at(sha)
      built.call(Lain::Isolation::LeaseLock::ProcessTable.new).at(sha)
      root = Lain::CLI::IsolationBackend.worktree_root(@repo, paths:)
      Lain::Isolation::Gc.new(repo_root: @repo, root:, retain_days: 7).call

      expect(Dir.exist?(checkout.path)).to be(true)
    end

    it "raises when git cannot reset to the sha" do
      checkout.at(commit("one"))

      expect { checkout.at("0" * 40) }.to raise_error(Lain::Error, /verify/)
    end
  end

  describe "#path" do
    it "differs per branch" do
      other = described_class.for(repo_root: @repo, branch: "epic/x", paths:, keep:)

      expect(other.path).not_to eq(checkout.path)
    end
  end
end
