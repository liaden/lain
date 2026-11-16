# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "digest"

RSpec.describe Lain::Review::Queue::LocalChanges, :seam do
  around do |example|
    Dir.mktmpdir("lain-local-changes") do |repo|
      @repo = File.realpath(repo)
      FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", @repo)
      example.run
    end
  end

  def git(*, env: {}) = SeedRepo.git(@repo, *, env:).stdout.strip

  def commit(name, env: {})
    File.write(File.join(@repo, name), "#{name}\n")
    git("add", name)
    git("commit", "-q", "-m", name, env:)
  end

  def branch_with(name, file)
    git("checkout", "-q", "-b", name)
    commit(file)
    git("checkout", "-q", "-")
  end

  def rows(**) = described_class.new(repo_root: @repo, **).call

  def by_rank(kind) = rows.select { |row| row.rank == kind }

  it "lists an unmerged branch and leaves a merged one out" do
    branch_with("a", "a.txt")
    git("branch", "b")

    expect(by_rank(:branch).map { |row| row.request.head }).to eq(["a"])
  end

  it "makes a dirty tree 1 row, and writes no commit, index or stash to list it" do
    commit("kept.txt")
    File.write(File.join(@repo, "README"), "changed\n")
    File.write(File.join(@repo, "fresh.rb"), "puts 1\n")
    File.utime(Time.now + 60, Time.now + 60, File.join(@repo, "kept.txt"))
    state = -> { [git("rev-parse", "HEAD"), git("for-each-ref"), git("count-objects", "-v"), git("stash", "list"), Digest::SHA1.file(File.join(@repo, ".git", "index")).hexdigest] }
    before = state.call

    listed = by_rank(:dirty)

    expect(listed.map(&:id)).to eq(["dirty:#{@repo}"])
    expect(listed.first.request.kind).to eq(:dirty)
    expect(state.call).to eq(before)
  end

  it "moves a dirty row's head when a renamed file is edited" do
    git("mv", "README", "moved.md")
    File.write(File.join(@repo, "moved.md"), "edited\n")
    first = by_rank(:dirty).first.head_sha
    File.write(File.join(@repo, "moved.md"), "edited again, longer\n")

    expect(by_rank(:dirty).first.head_sha).not_to eq(first)
  end

  it "moves a dirty row's head when a file with a non-ASCII name is edited" do
    File.write(File.join(@repo, "café.txt"), "one\n")
    first = by_rank(:dirty).first.head_sha
    File.write(File.join(@repo, "café.txt"), "two!\n")

    expect(by_rank(:dirty).first.head_sha).not_to eq(first)
  end

  it "changes a dirty row's head when the dirt changes" do
    File.write(File.join(@repo, "README"), "one\n")
    first = by_rank(:dirty).first.head_sha
    File.write(File.join(@repo, "README"), "two\n")

    expect(by_rank(:dirty).first.head_sha).not_to eq(first)
  end

  it "has no dirty row for a clean tree" do
    expect(by_rank(:dirty)).to eq([])
  end

  it "lists recent commits as single-commit ranges, below branches, and skips old ones" do
    old = { "GIT_AUTHOR_DATE" => "2020-01-01T00:00:00Z", "GIT_COMMITTER_DATE" => "2020-01-01T00:00:00Z" }
    commit("old.txt", env: old)
    %w[c1 c2 c3].each { |name| commit(name) }
    branch_with("a", "a.txt")

    commits = by_rank(:commit)

    expect(commits.size).to eq(3)
    expect(commits.map { |row| [row.request.base, row.request.head] })
      .to all(satisfy { |base, head| git("rev-parse", "#{head}^") == base })
    expect(rows.map(&:rank).uniq).to eq(%i[branch commit])
  end

  it "answers nothing for a repository with no commit yet" do
    Dir.mktmpdir("lain-unborn") do |empty|
      SeedRepo.git(empty, "init", "-q")
      File.write(File.join(empty, "f"), "x")

      expect(described_class.new(repo_root: empty).call).to eq([])
    end
  end
end
