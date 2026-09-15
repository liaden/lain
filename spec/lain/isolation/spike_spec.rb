# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "mixlib/shellout"

RSpec.describe Lain::Isolation::Spike, :seam do
  around do |example|
    Dir.mktmpdir("lain-spike-spec") do |dir|
      base = File.realpath(dir)
      @repo = File.join(base, "repo")
      @root = File.join(base, "worktrees")
      FileUtils.mkdir_p(@repo)
      FileUtils.cp_r("#{SeedRepo.at({ "a.rb" => "one\n", "lib.rb" => "lib\n" })}/.", @repo)
      example.run
    ensure
      @leases&.each(&:release)
    end
  end

  def git(*args, dir: @repo)
    Mixlib::ShellOut.new("git", "-C", dir, *args, environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
                    .run_command.tap(&:error!).stdout.strip
  end

  def spike(cwd: @repo) = described_class.new(repo_root: @repo, root: @root, cwd:)

  def lease(cwd: @repo) = spike(cwd:).acquire.tap { |taken| (@leases ||= []) << taken }

  def checkout = lease.worker_env.checkout

  it "cuts a checkout carrying the tracked edit nobody committed" do
    File.write(File.join(@repo, "a.rb"), "edited\n")

    expect(File.read(File.join(checkout, "a.rb"))).to eq("edited\n")
  end

  # The spike copies what git tracks. A file the human never added is theirs
  # alone, and the workspace tells the model it is missing.
  it "leaves an untracked file behind" do
    File.write(File.join(@repo, "scratch.txt"), "mine\n")

    expect(File.exist?(File.join(checkout, "scratch.txt"))).to be(false)
  end

  it "cuts a clean tree at HEAD itself" do
    head = git("rev-parse", "HEAD")

    expect(git("rev-parse", "HEAD", dir: checkout)).to eq(head)
  end

  it "commits a dirty tree once, on top of HEAD alone" do
    head = git("rev-parse", "HEAD")
    File.write(File.join(@repo, "a.rb"), "edited\n")

    expect(git("rev-list", "--parents", "-n", "1", "HEAD", dir: checkout).split.drop(1)).to eq([head])
  end

  # Everything the snapshot does happens in a temporary index, so the human's
  # checkout reads afterwards exactly as it did before.
  it "writes neither the checkout's index, nor its stash list, nor its reflog" do
    File.write(File.join(@repo, "a.rb"), "edited\n")
    index = File.join(@repo, ".git", "index")
    # `status` refreshes the index itself, so it settles before the stamp is
    # read, and the stamp is read again before anything else asks.
    status = git("status", "--porcelain")
    before = [File.mtime(index), git("stash", "list"), git("reflog")]

    lease

    expect([File.mtime(index), git("stash", "list"), git("reflog")]).to eq(before)
    expect(git("status", "--porcelain")).to eq(status)
  end

  it "stands the checkout on a branch lain marks as its own, under lain/plan" do
    taken = lease
    branch = taken.origin.branch

    expect(branch).to start_with("lain/plan/")
    expect(git("rev-parse", "refs/lain/owned/heads/#{branch}")).to eq(git("rev-parse", "refs/heads/#{branch}"))
    expect(taken.origin.path).to start_with("#{@root}/")
  end

  it "starts the worker where the session stands, mirrored inside the spike" do
    FileUtils.mkdir_p(File.join(@repo, "lib"))
    File.write(File.join(@repo, "lib", "b.rb"), "b\n")
    git("add", "lib/b.rb")
    git("commit", "-q", "-m", "lib")

    taken = lease(cwd: File.join(@repo, "lib"))

    expect(taken.worker_env.cwd).to eq(File.join(taken.worker_env.checkout, "lib"))
  end

  it "refuses in words when the checkout has no commit to cut from" do
    empty = File.join(File.dirname(@repo), "empty")
    FileUtils.mkdir_p(empty)
    git("init", "-q", dir: empty)

    expect { described_class.new(repo_root: empty, root: @root, cwd: empty).acquire }
      .to raise_error(described_class::Refused, /tracked state/)
  end

  it "tells the model where it is, and that untracked files were not copied" do
    taken = lease
    expect(spike.reminder(taken)).to include(taken.worker_env.checkout, "spike worktree",
                                             "Untracked files were not copied")
  end

  describe "#release" do
    def branch_of(taken) = taken.origin.branch

    def refs(taken)
      git("for-each-ref", "--format=%(refname)", "refs/heads/#{branch_of(taken)}",
          "refs/lain/owned/heads/#{branch_of(taken)}").split
    end

    def commit_in(checkout)
      File.write(File.join(checkout, "spiked.md"), "work\n")
      git("add", "spiked.md", dir: checkout)
      git("-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-q", "-m", "work", dir: checkout)
      git("rev-parse", "HEAD", dir: checkout)
    end

    it "deletes the branch and lain's marker when the spike committed nothing, saying nothing" do
      taken = spike.acquire

      expect(spike.release(taken)).to eq("")
      expect([refs(taken), taken]).to match([[], be_released])
    end

    it "moves the branch forward to the spike's commits and names it" do
      taken = spike.acquire
      head = commit_in(taken.worker_env.checkout)

      told = spike.release(taken)

      expect(git("rev-parse", "refs/heads/#{branch_of(taken)}")).to eq(head)
      expect(told).to include(branch_of(taken), head[0, 12])
    end

    # Uncommitted work is kept in the spike's worktree, and the human has to
    # be told where.
    it "names the kept worktree when the spike holds uncommitted changes" do
      taken = spike.acquire
      File.write(File.join(taken.worker_env.checkout, "notes.md"), "plan work\n")

      told = spike.release(taken)

      expect(told).to include(taken.worker_env.checkout, "uncommitted changes")
      expect(File.read(File.join(taken.worker_env.checkout, "notes.md"))).to eq("plan work\n")
    end

    # Another run moved the branch after the spike was cut: it is not the
    # spike's to move, and the words must not blame the spike's history.
    it "leaves a branch another run moved where it is, and says it was moved" do
      taken = spike.acquire
      commit_in(taken.worker_env.checkout)
      File.write(File.join(@repo, "elsewhere.md"), "x\n")
      git("add", "elsewhere.md")
      git("-c", "user.email=t@example.com", "-c", "user.name=T", "commit", "-q", "-m", "elsewhere")
      other = git("rev-parse", "HEAD")
      git("update-ref", "refs/heads/#{branch_of(taken)}", other)

      told = spike.release(taken)

      expect(git("rev-parse", "refs/heads/#{branch_of(taken)}")).to eq(other)
      expect(told).to include(branch_of(taken), "was moved since the spike was cut")
      expect(told).not_to include("no longer descends")
    end

    # The marker is the only licence to delete: without it the branch is not
    # lain's to take away.
    it "never deletes a branch lain's marker does not name" do
      taken = spike.acquire
      git("update-ref", "-d", "refs/lain/owned/heads/#{branch_of(taken)}")

      told = spike.release(taken)

      expect(git("rev-parse", "--verify", "refs/heads/#{branch_of(taken)}")).not_to be_empty
      expect(told).to include("could not be deleted")
    end
  end

  it "makes a session cwd the snapshot did not carry, and says so" do
    FileUtils.mkdir_p(File.join(@repo, "build"))
    taken = lease(cwd: File.join(@repo, "build"))

    expect(File.directory?(taken.worker_env.cwd)).to be(true)
    expect(spike.reminder(taken)).to include("build holds nothing git tracks")
  end
end
