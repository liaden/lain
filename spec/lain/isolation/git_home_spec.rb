# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# Drives throwaway repositories; never the lain repository it runs in.
RSpec.describe Lain::Isolation::GitHome, :seam do
  around do |example|
    Dir.mktmpdir("lain-git-home") do |base|
      @base = File.realpath(base)
      example.run
    end
  end

  let(:asked) { [] }
  let(:counting) do
    lambda do |*argv, **options|
      asked << argv
      Lain::Shell::Out.new(*argv, **options)
    end
  end

  def seeded_repo(name)
    FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", FileUtils.mkdir_p(File.join(@base, name)).first)
    File.join(@base, name)
  end

  def common_dir(root) = described_class.common_dir(root, shell_out_factory: counting)

  it "answers the absolute common git dir, from a linked worktree too" do
    repo = seeded_repo("repo")
    linked = File.join(@base, "linked")
    Lain::Isolation::Checkout.new(repo).run("worktree", "add", "--detach", linked)

    expect([common_dir(repo), common_dir(linked)]).to eq([File.join(repo, ".git")] * 2)
  end

  it "asks git once for a repository however often it is asked" do
    repo = seeded_repo("repo")

    3.times { common_dir(repo) }

    expect(asked.size).to eq(1)
  end

  it "sees a directory that becomes a repository, and never remembers the absence" do
    plain = FileUtils.mkdir_p(File.join(@base, "plain")).first

    first = common_dir(plain)
    Lain::Isolation::Checkout.new(plain).run("init", "-q")

    expect([first, common_dir(plain)]).to eq([nil, File.join(plain, ".git")])
  end

  it "asks again when a linked worktree's root is recreated as another repository" do
    repo = seeded_repo("repo")
    linked = File.join(@base, "linked")
    Lain::Isolation::Checkout.new(repo).run("worktree", "add", "--detach", linked)
    stale = common_dir(linked)
    FileUtils.rm_rf(linked)
    Lain::Isolation::Checkout.new(FileUtils.mkdir_p(linked).first).run("init", "-q")

    expect([stale, common_dir(linked)]).to eq([File.join(repo, ".git"), File.join(linked, ".git")])
  end

  it "asks again when a linked worktree's .git file is rewritten to name another repository, inode kept" do
    first = seeded_repo("first")
    second = seeded_repo("second")
    linked = File.join(@base, "linked")
    Lain::Isolation::Checkout.new(first).run("worktree", "add", "--detach", linked)
    stale = common_dir(linked)
    Lain::Isolation::Checkout.new(second).run("worktree", "add", "--detach", File.join(@base, "other"))
    other_gitdir = File.read(File.join(@base, "other", ".git"))
    File.write(File.join(linked, ".git"), other_gitdir)

    expect([stale, common_dir(linked)]).to eq([File.join(first, ".git"), File.join(second, ".git")])
  end

  it "asks git each time for a subdirectory, which has no .git of its own to tell a change by" do
    repo = seeded_repo("repo")
    sub = FileUtils.mkdir_p(File.join(repo, "sub")).first

    2.times { common_dir(sub) }

    expect(asked.size).to eq(2)
  end

  it "asks again when a repository's config is rewritten in place, as a re-init of a recreated root does" do
    repo = seeded_repo("repo")
    common_dir(repo)
    sleep 0.01
    File.write(File.join(repo, ".git", "config"), File.read(File.join(repo, ".git", "config")))

    common_dir(repo)

    expect(asked.size).to eq(2)
  end

  it "does not take a failing factory's answer for a repository" do
    repo = seeded_repo("repo")
    failing = lambda do |*_argv, **|
      Struct.new(:stdout, :stderr, :exitstatus) { def run_command = self }.new("", "no", 128)
    end

    expect(described_class.common_dir(repo, shell_out_factory: failing)).to be_nil
    expect(common_dir(repo)).to eq(File.join(repo, ".git"))
  end
end
