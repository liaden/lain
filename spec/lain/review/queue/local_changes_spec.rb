# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "digest"
require "json"
require "shellwords"
require "stringio"

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

  let(:notes) { StringIO.new }

  def rows(repo_root: @repo, **) = described_class.new(repo_root:, notes:, **).call

  def trunk = git("symbolic-ref", "--short", "HEAD")

  def by_rank(kind) = rows.select { |row| row.rank == kind }

  it "lists an unmerged branch and leaves a merged one out" do
    branch_with("a", "a.txt")
    git("branch", "b")

    expect(by_rank(:branch).map { |row| row.request.review_line })
      .to eq(["/review refs/heads/a --base refs/heads/#{trunk}"])
  end

  it "names a branch by its own ref when a tag shares its name" do
    branch_with("v1", "v1.txt")
    git("tag", "v1", trunk)

    expect(by_rank(:branch).map { |row| row.request.to_h["branch"] }).to eq(["v1"])
  end

  it "lists a branch whose line /review resolves when the trunk is master" do
    git("branch", "-M", "master")
    branch_with("feature", "feature.txt")
    _, target, _, base = Shellwords.split(by_rank(:branch).first.request.review_line)

    resolved = Lain::Review::Target.new(repo_root: @repo, shell_out_factory: Lain::Shell::Out.public_method(:new))
                                   .resolve(target, base:)

    expect([resolved.label, base]).to eq(["branch refs/heads/feature", "refs/heads/master"])
  end

  it "keeps a non-ASCII branch name and commit subject through JSON" do
    branch_with("f\u00e9", "fe.txt")
    commit("r\u00e9sum\u00e9")

    expect(by_rank(:commit).map { |row| JSON.parse(JSON.generate(row.reason)) })
      .to eq(["recent commit: r\u00e9sum\u00e9"])

    listed = by_rank(:branch)

    expect(listed.map { |row| JSON.parse(JSON.generate(row.request.to_h))["branch"] }).to eq(["f\u00e9"])
    expect(listed.map { |row| JSON.parse(JSON.generate([row.id, row.reason])) })
      .to eq([["branch:#{@repo}:f\u00e9", "unmerged branch f\u00e9"]])
  end

  it "skips a branch git would not take as a branch, with 1 note, and lists the rest" do
    branch_with("a", "a.txt")
    git("update-ref", "refs/heads/-odd", "refs/heads/a")
    File.write(File.join(@repo, "README"), "dirty\n")

    listed = rows

    expect(listed.map { |row| [row.rank, row.request.to_h["branch"]] }).to eq([[:branch, "a"], [:dirty, nil]])
    expect(notes.string.lines.grep(/-odd/).size).to eq(1)
  end

  it "lists a subdirectory or a symlink as the work tree it belongs to" do
    branch_with("a", "a.txt")
    FileUtils.mkdir_p(File.join(@repo, "sub"))
    link = File.join(Dir.mktmpdir("lain-local-link"), "repo")
    File.symlink(@repo, link)

    roots = [File.join(@repo, "sub"), link].map { |root| rows(repo_root: root).map { |row| row.request.repo_root } }

    expect(roots).to eq([[@repo], [@repo]])
  ensure
    FileUtils.rm_rf(File.dirname(link)) if link
  end

  it "skips the commits of a sha256 repository, 1 note each, and lists its branches" do
    Dir.mktmpdir("lain-sha256") do |raw|
      repo = File.realpath(raw)
      sh = ->(*args) { SeedRepo.git(repo, "-c", "user.name=t", "-c", "user.email=t@example.com", *args) }
      sh.call("init", "-q", "--object-format=sha256", "-b", "main")
      2.times { |i| sh.call("commit", "-q", "--allow-empty", "-m", "c#{i}") }
      sh.call("checkout", "-q", "-b", "b")
      sh.call("commit", "-q", "--allow-empty", "-m", "on b")
      sh.call("checkout", "-q", "main")

      expect(rows(repo_root: repo).map(&:rank)).to eq([:branch])
      expect(notes.string.lines.size).to eq(1)
    end
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
    expect(listed.first.request.to_h).to eq("kind" => "dirty", "repo_root" => @repo)
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

  it "lists a dirty tree under a non-ASCII root with a non-ASCII changed file" do
    accented = File.join(@repo, "caf\u00e9")
    FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", FileUtils.mkdir_p(accented).first)
    File.write(File.join(accented, "\u00e9t\u00e9.txt"), "one\n")

    expect(rows(repo_root: accented).map(&:id)).to eq(["dirty:#{accented}"])
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
    expect(commits.map { |row| row.request.to_h.values_at("kind", "base", "head") })
      .to all(satisfy { |kind, base, head| kind == "range" && git("rev-parse", "#{head}^") == base })
    expect(rows.map(&:rank).uniq).to eq(%i[branch commit])
  end

  it "lists no commit row for a recent root commit, which has no parent to range from" do
    Dir.mktmpdir("lain-root-commit") do |fresh|
      SeedRepo.git(fresh, "init", "-q")
      File.write(File.join(fresh, "f"), "x")
      SeedRepo.git(fresh, "add", "f")
      SeedRepo.git(fresh, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "root")

      expect(rows(repo_root: fresh).map(&:rank)).not_to include(:commit)
    end
  end

  it "answers nothing for a repository with no commit yet" do
    Dir.mktmpdir("lain-unborn") do |empty|
      SeedRepo.git(empty, "init", "-q")
      File.write(File.join(empty, "f"), "x")

      expect(rows(repo_root: empty)).to eq([])
    end
  end
end
