# frozen_string_literal: true

require "fileutils"
require "tmpdir"

# A finished epic's branch merged into the checked-out default branch of a
# repository with no remote. Real git, no network.
RSpec.describe Lain::Forge::LocalFinish, :seam do
  around do |example|
    Dir.mktmpdir do |tmp|
      @root = File.join(File.realpath(tmp), "project")
      FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", @root)
      git("branch", "-M", "main")
      git("switch", "-q", "-c", "epic/frugirl-mvp")
      commit("README" => "the epic's work\n", "NEW" => "added by the epic\n")
      git("switch", "-q", "main")
      example.run
    end
  end

  attr_reader :root

  def git(*) = SeedRepo.git(root, *).stdout.strip

  def commit(files)
    files.each { |path, body| File.write(File.join(root, path), body) }
    git("add", *files.keys)
    git("commit", "-q", "-m", "work")
  end

  def head(ref = "main") = git("rev-parse", ref)

  let(:calls) { [] }
  let(:recording) do
    lambda do |*argv, **options|
      calls << argv
      Lain::Shell::Out.new(*argv, **options)
    end
  end

  def finish(sha: head("epic/frugirl-mvp"), shell_out_factory: recording)
    described_class.new(root:, shell_out_factory:).call(slug: "frugirl-mvp", base: "main", sha:)
  end

  def worktrees = git("worktree", "list", "--porcelain").lines.grep(/\Aworktree /)

  describe "a finished epic" do
    it "lands on main as a merge commit of the epic branch, and nothing else is touched" do
      before = head
      epic = head("epic/frugirl-mvp")

      answer = finish

      expect(answer).to be_ok
      expect(git("rev-list", "--parents", "-n", "1", "main").split.drop(1)).to eq([before, epic])
      expect(answer.value).to eq(head)
      expect(answer.detail).to include("remote" => false, "base" => "main", "head" => "epic/frugirl-mvp")
      expect(File.read(File.join(root, "NEW"))).to eq("added by the epic\n")
      expect(git("status", "--porcelain")).to be_empty
      expect(worktrees.size).to eq(1)
    end

    it "pushes nothing, runs no forge command and checks out no second worktree" do
      finish

      expect(calls.map(&:first).uniq).to eq(["git"])
      expect(calls.flatten).not_to include("push", "worktree")
    end

    it "merges exactly the sha it was given, not wherever the branch has since moved" do
      given = head("epic/frugirl-mvp")
      git("switch", "-q", "epic/frugirl-mvp")
      commit("LATER" => "after the finish was asked for\n")
      git("switch", "-q", "main")

      finish(sha: given)

      expect(git("rev-list", "--parents", "-n", "1", "main").split.last).to eq(given)
      expect(File).not_to exist(File.join(root, "LATER"))
    end

    it "does not count an untracked file the epic does not touch as dirty" do
      File.write(File.join(root, "notes"), "mine\n")

      expect(finish).to be_ok
      expect(File.read(File.join(root, "notes"))).to eq("mine\n")
    end

    it "observes a merge already in place rather than merging twice" do
      finish
      merged = head

      answer = finish

      expect(answer).to be_ok.and be_observed
      expect(head).to eq(merged)
    end
  end

  describe "a conflicting merge" do
    it "refuses naming the conflicting paths, leaving main's head and working tree as they were" do
      commit("README" => "main moved\n")
      before = head

      answer = finish

      expect(answer).not_to be_ok
      expect(answer.detail["message"]).to include("README")
      expect(head).to eq(before)
      expect(File.read(File.join(root, "README"))).to eq("main moved\n")
      expect(git("status", "--porcelain")).to be_empty
      expect(worktrees.size).to eq(1)
    end
  end

  describe "main moving between the merge and the fast-forward" do
    it "refuses not_fast_forward and leaves the moved main and its tree alone" do
      moved = nil
      racing = lambda do |*argv, **options|
        if argv.include?("--ff-only") && moved.nil?
          commit("MAIN" => "moved\n")
          moved = head
        end
        Lain::Shell::Out.new(*argv, **options)
      end

      answer = finish(shell_out_factory: racing)

      expect(answer).not_to be_ok
      expect(answer.detail["reason"]).to eq("not_fast_forward")
      expect(head).to eq(moved)
      expect(git("status", "--porcelain")).to be_empty
    end
  end

  describe "refusals before any merge" do
    it "refuses untracked files the epic would add, listing them, and leaves them alone" do
      File.write(File.join(root, "NEW"), "mine\n")
      before = head

      expect { finish }.to raise_error(described_class::Refused, /untracked.*NEW/m)
      expect(head).to eq(before)
      expect(File.read(File.join(root, "NEW"))).to eq("mine\n")
    end

    it "refuses a dirty worktree, naming it" do
      File.write(File.join(root, "README"), "uncommitted\n")
      before = head

      expect { finish }.to raise_error(described_class::Refused, /#{Regexp.escape(root)}.*uncommitted/m)
      expect(head).to eq(before)
      expect(calls.flatten).not_to include("merge")
    end

    it "lists untracked files from the repository root when the project is a subdirectory of it" do
      Dir.mktmpdir do |tmp|
        repo = File.join(File.realpath(tmp), "repo")
        FileUtils.mkdir_p(File.join(repo, "app"))
        SeedRepo.git(tmp, "init", "-q", "-b", "main", repo)
        %w[user.name user.email commit.gpgsign].zip(%w[p p@x false]).each do |key, value|
          SeedRepo.git(repo, "config", key, value)
        end
        File.write(File.join(repo, "app", "README"), "seed\n")
        SeedRepo.git(repo, "add", ".")
        SeedRepo.git(repo, "commit", "-q", "-m", "seed")
        SeedRepo.git(repo, "switch", "-q", "-c", "epic/frugirl-mvp")
        File.write(File.join(repo, "app", "NEW"), "epic\n")
        SeedRepo.git(repo, "add", ".")
        SeedRepo.git(repo, "commit", "-q", "-m", "work")
        sha = SeedRepo.git(repo, "rev-parse", "HEAD").stdout.strip
        SeedRepo.git(repo, "switch", "-q", "main")
        app = File.join(repo, "app")
        File.write(File.join(app, "NEW"), "mine\n")

        expect { described_class.new(root: app).call(slug: "frugirl-mvp", base: "main", sha:) }
          .to raise_error(described_class::Refused, %r{untracked.*app/NEW}m)
        expect(File.read(File.join(app, "NEW"))).to eq("mine\n")
      end
    end

    it "refuses when the default branch is not the one checked out, naming the branch it expected" do
      git("switch", "-q", "epic/frugirl-mvp")

      expect { finish }.to raise_error(described_class::Refused, %r{main.*epic/frugirl-mvp}m)
      expect(calls.flatten).not_to include("merge")
    end
  end
end
