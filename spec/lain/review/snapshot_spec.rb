# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Lain::Review::Snapshot, :seam do
  around do |example|
    Dir.mktmpdir("lain-review-snapshot") do |repo|
      @repo = File.realpath(repo)
      FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", @repo)
      example.run
    end
  end

  def git(*, env: {}) = SeedRepo.git(@repo, *, env:).stdout.strip

  def snapshot(**) = described_class.new(repo_root: @repo, **).take

  context "with a modified tracked file and a new untracked one" do
    before do
      File.write(File.join(@repo, "README"), "changed\n")
      File.write(File.join(@repo, "fresh.rb"), "puts 1\n")
    end

    it "returns a commit whose only parent is HEAD and whose tree holds both changes" do
      sha = snapshot

      expect(git("rev-list", "--parents", "-n1", sha)).to eq("#{sha} #{git("rev-parse", "HEAD")}")
      expect(git("show", "#{sha}:README")).to eq("changed")
      expect(git("show", "#{sha}:fresh.rb")).to eq("puts 1")
    end

    it "leaves the index, HEAD and refs unchanged" do
      before = [git("status", "--porcelain"), git("rev-parse", "HEAD"), git("for-each-ref")]

      snapshot

      expect([git("status", "--porcelain"), git("rev-parse", "HEAD"), git("for-each-ref")]).to eq(before)
    end

    it "builds from the target repository when a hook's index and git dir are exported" do
      other = Dir.mktmpdir("lain-review-other")
      stale = File.join(other, "index")
      exported = { "GIT_INDEX_FILE" => stale, "GIT_DIR" => File.join(other, "nowhere") }
      saved = exported.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
      ENV.update(exported)

      sha = snapshot

      expect(git("show", "#{sha}:fresh.rb")).to eq("puts 1")
      expect(File).not_to exist(stale)
    ensure
      ENV.update(saved)
      FileUtils.rm_rf(other)
    end

    it "lists exactly 1 commit at the commits scope of a LocalBranch review against HEAD" do
      sha = snapshot
      source = Lain::Review::Source::LocalBranch.new(base: "HEAD", head: sha, repo_root: @repo)

      expect(source.commits.size).to eq(1)
    end
  end

  it "keeps an ignored file out of the tree" do
    File.write(File.join(@repo, ".gitignore"), "*.log\n")
    File.write(File.join(@repo, "debug.log"), "noise\n")

    expect(git("ls-tree", "-r", "--name-only", snapshot)).not_to include("debug.log")
  end

  it "keeps a tracked file that is also ignored" do
    File.write(File.join(@repo, "kept.log"), "tracked\n")
    git("add", "-f", "kept.log")
    git("commit", "-q", "-m", "track a log")
    File.write(File.join(@repo, ".gitignore"), "*.log\n")
    File.write(File.join(@repo, "kept.log"), "edited\n")

    expect(git("show", "#{snapshot}:kept.log")).to eq("edited")
  end

  it "leaves a deleted tracked file out of the tree" do
    File.write(File.join(@repo, "extra.rb"), "1\n")
    git("add", "extra.rb")
    git("commit", "-q", "-m", "add extra")
    File.delete(File.join(@repo, "extra.rb"))

    expect(git("ls-tree", "-r", "--name-only", snapshot).split("\n")).to eq(%w[README])
  end

  it "raises when HEAD is unborn" do
    Dir.mktmpdir("lain-review-unborn") do |dir|
      SeedRepo.git(dir, "init", "-q")

      expect { described_class.new(repo_root: dir).take }.to raise_error(Lain::Isolation::Checkout::Failed)
    end
  end

  it "returns nil for a clean work tree" do
    expect(snapshot).to be_nil
  end
end
