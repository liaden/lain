# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Drives a throwaway repository and a linked worktree of it; never the lain
# repository it runs in.
RSpec.describe Lain::Isolation::MergeCoordinator::Home, :seam do
  around do |example|
    Dir.mktmpdir("lain-coordinator-home") do |base|
      @repo = File.join(File.realpath(base), "repo")
      @linked = File.join(File.realpath(base), "linked")
      FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", FileUtils.mkdir_p(@repo).first)
      example.run
    end
  end

  def add_linked_worktree
    Lain::Isolation::Checkout.new(@repo).run("worktree", "add", "--detach", @linked)
  end

  def home(root, branch) = described_class.for(repo_root: root, branch:)

  it "names the same directory and the same lock from every worktree of a repository" do
    add_linked_worktree

    from_main = home(@repo, "main")
    from_linked = home(@linked, "main")
    result = nil
    from_main.drain_lock.hold { result = from_linked.drain_lock.try { raise "must not run" } }

    expect(from_linked.dir).to eq(from_main.dir)
    expect(result).to be(false)
  end

  it "resolves the same home from a directory deep inside the repository" do
    FileUtils.mkdir_p(File.join(@repo, "sub", "deep"))

    expect(home(File.join(@repo, "sub", "deep"), "main").dir).to eq(home(@repo, "main").dir)
  end

  it "keeps its directory under the repository's common git dir" do
    expect(home(@repo, "main").dir).to start_with(File.join(@repo, ".git", "lain-coordinator") + File::SEPARATOR)
  end

  it "lets the lock be taken again once it is released" do
    entered = home(@repo, "main").drain_lock.try { :ran }

    expect(entered).to be(true)
  end

  it "names entries and results beside the lock inside the home" do
    resolved = home(@repo, "main")

    expect([resolved.entries,
            resolved.results]).to eq([File.join(resolved.dir, "entries"), File.join(resolved.dir, "results")])
  end

  it "gives two branches two homes, none named with a slash from the branch" do
    plain = home(@repo, "main")
    nested = home(@repo, "epic/demo")

    expect(nested.dir).not_to eq(plain.dir)
    expect(File.basename(nested.dir)).not_to include("/")
    expect(File.dirname(nested.dir)).to eq(File.dirname(plain.dir))
  end

  it "keeps branches that slug alike apart" do
    expect(home(@repo, "a/b").dir).not_to eq(home(@repo, "a-b").dir)
  end

  it "keys a branch the way a handback's ref names it" do
    key = File.basename(Lain::Isolation::Worktree::Handback::Naming.new("epic/demo").ref)

    expect(File.basename(home(@repo, "epic/demo").dir)).to eq(key)
  end

  it "refuses a directory in no repository, naming it" do
    Dir.mktmpdir("lain-coordinator-bare") do |bare|
      expect { home(bare, "main") }.to raise_error(Lain::Error, /#{Regexp.escape(bare)}/)
    end
  end
end
