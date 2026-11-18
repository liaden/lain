# frozen_string_literal: true

require "open3"
require "tmpdir"
require "fileutils"

RSpec.describe "bin/prune-merged-worktrees" do
  let(:script) { File.expand_path("../../bin/prune-merged-worktrees", __dir__) }
  let(:repo) { File.realpath(Dir.mktmpdir("lain-prune")) }
  let(:spawned) { [] }
  let(:shims) { [] }

  after do
    spawned.each { |pid| Process.kill("KILL", pid) && Process.wait(pid) }
    FileUtils.rm_rf([repo, *shims])
  end

  def git(*args, dir: repo)
    out, err, status = Open3.capture3(SeedRepo::SCRUB, "git", "-C", dir, *args)
    raise "git #{args.join(" ")}: #{err}" unless status.success?

    out
  end

  def seed_repo
    git("init", "-q", "-b", "main")
    %w[user.name user.email].each { |key| git("config", key, "t") }
    git("config", "commit.gpgsign", "false")
    File.write(File.join(repo, "tracked.txt"), "one\n")
    File.write(File.join(repo, ".git", "info", "exclude"), "/tmp/\n.handback*.md\n")
    git("add", "tracked.txt")
    git("commit", "-q", "-m", "seed")
  end

  def worktree(name, branch: "card/#{name}")
    path = File.join(repo, "tmp", "worktrees", name)
    git("worktree", "add", "-q", "-b", branch, path)
    path
  end

  def prune(*flags, env: {})
    Open3.capture2e(SeedRepo::SCRUB.merge(env), script, *flags, "--repo", repo)
  end

  def branches = git("branch", "--format=%(refname:short)").split

  def worktrees = git("worktree", "list", "--porcelain").scan(/^worktree (.*)$/).flatten

  before { seed_repo }

  context "with a merged worktree holding uncommitted work" do
    let!(:path) { worktree("T1") }
    let(:archive) { File.join(repo, "tmp", "worktree-archive", "T1") }

    before do
      File.write(File.join(path, "tracked.txt"), "two\n")
      File.write(File.join(path, "fresh.txt"), "new\n")
      File.write(File.join(path, ".handback-T1.md"), "report\n")
    end

    it "archives a patch that applies at the recorded base, then removes the worktree and branch" do
      out, status = prune("--apply")
      expect([status.success?, out]).to match([true, /T1/])

      base = File.read(File.join(archive, "base.txt")).strip
      check = File.join(repo, "tmp", "check")
      git("worktree", "add", "-q", "--detach", check, base)
      git("apply", "--check", File.join(archive, "diff.patch"), dir: check)

      listed, = Open3.capture2("tar", "-tf", File.join(archive, "untracked.tar"))
      expect(listed.split).to contain_exactly("fresh.txt", ".handback-T1.md")
      expect([File.exist?(path), branches]).to eq([false, ["main"]])
    end
  end

  context "with changes a plain diff would lose" do
    def apply_at_base(name)
      archive = File.join(repo, "tmp", "worktree-archive", name)
      check = File.join(repo, "tmp", "check-#{name}")
      git("worktree", "add", "-q", "--detach", check, File.read(File.join(archive, "base.txt")).strip)
      git("apply", File.join(archive, "diff.patch"), dir: check)
      check
    end

    it "restores the bytes of a modified binary file" do
      File.binwrite(File.join(repo, "blob.bin"), "\x00\x01\xff".b)
      git("add", "blob.bin")
      git("commit", "-q", "-m", "binary")
      File.binwrite(File.join(worktree("T6"), "blob.bin"), "\x00\x02\xfe\xff".b)

      prune("--apply")

      expect(File.binread(File.join(apply_at_base("T6"), "blob.bin"))).to eq("\x00\x02\xfe\xff".b)
    end

    it "keeps a staged new file" do
      path = worktree("T7")
      File.write(File.join(path, "staged.txt"), "staged\n")
      git("add", "staged.txt", dir: path)

      prune("--apply")

      expect(File.read(File.join(apply_at_base("T7"), "staged.txt"))).to eq("staged\n")
    end

    it "archives an untracked file whose name starts with a dash" do
      File.write(File.join(worktree("T8"), "-weird.txt"), "w\n")

      prune("--apply")

      listed, = Open3.capture2("tar", "-tf", File.join(repo, "tmp", "worktree-archive", "T8", "untracked.tar"))
      expect(listed.split).to eq(["-weird.txt"])
    end
  end

  it "leaves a worktree in place when an archive of that name already exists" do
    path = worktree("T9")
    FileUtils.mkdir_p(File.join(repo, "tmp", "worktree-archive", "T9"))

    out, = prune("--apply")

    expect([File.directory?(path), out]).to match([true, /T9.*archive exists/])
  end

  it "skips a worktree whose directory was deleted by hand, leaving no archive" do
    path = worktree("T10")
    FileUtils.rm_rf(path)

    out, status = prune("--apply")

    expect([status.success?, out, File.exist?(File.join(repo, "tmp", "worktree-archive", "T10"))])
      .to match([true, /T10.*(missing|prunable)/, false])
  end

  it "replaces a leftover partial archive and leaves no partial behind" do
    path = worktree("T12")
    File.write(File.join(path, "fresh.txt"), "new\n")
    stale = File.join(repo, "tmp", "worktree-archive", "T12.partial")
    FileUtils.mkdir_p(stale)
    File.write(File.join(stale, "junk"), "x")

    out, = prune("--apply")

    archive = File.join(repo, "tmp", "worktree-archive")
    expect([out, Dir.children(archive), Dir.children(File.join(archive, "T12")).sort])
      .to match([/partial.*T12/, ["T12"], %w[base.txt diff.patch untracked.tar]])
  end

  it "names the failing worktree and keeps it, with no trusted archive, when tar fails" do
    path = worktree("T11")
    fake = Dir.mktmpdir("lain-prune-tar")
    File.write(File.join(fake, "tar"),
               "#!/bin/sh\n[ \"$1\" = --version ] && echo \"tar (GNU tar) 1.35\"\n[ \"$1\" = --version ] || exit 1\n")
    File.chmod(0o755, File.join(fake, "tar"))

    out, status = prune("--apply", env: { "PATH" => "#{fake}:#{ENV.fetch("PATH")}" })

    expect([status.success?, out, File.directory?(path),
            File.exist?(File.join(repo, "tmp", "worktree-archive", "T11"))])
      .to match([false, /failed on T11/, true, false])
  ensure
    FileUtils.rm_rf(fake)
  end

  def shim(name, body)
    dir = Dir.mktmpdir("lain-prune-shim")
    shims << dir
    File.write(File.join(dir, name), "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, File.join(dir, name))
    { "PATH" => "#{dir}:#{ENV.fetch("PATH")}" }
  end

  def real_git = Open3.capture2("which", "git").first.strip

  def archive_dir(name) = File.join(repo, "tmp", "worktree-archive", name)

  it "refuses to run when tar is not GNU tar, before touching anything" do
    path = worktree("T13")
    env = shim("tar", 'echo "bsdtar 3.5.3"')

    out, status = prune("--apply", env:)

    expect([status.exitstatus, out, File.directory?(path), File.exist?(archive_dir("T13"))])
      .to match([2, /Linux.*GNU tar/, true, false])
  end

  it "keeps a worktree whose ignored-file listing failed, rather than dropping the handbacks" do
    path = worktree("T14")
    File.write(File.join(path, ".handback-T14.md"), "report\n")
    env = shim("git", %[case "$*" in *--ignored*) exit 1 ;; esac\nexec #{real_git} "$@"])

    out, status = prune("--apply", env:)

    expect([status.success?, out, File.directory?(path), File.exist?(archive_dir("T14"))])
      .to match([false, /failed on T14/, true, false])
  end

  it "says the archive is kept and how to finish when the worktree cannot be removed" do
    worktree("T15")
    env = shim("git", %[case "$*" in *"worktree remove"*) exit 1 ;; esac\nexec #{real_git} "$@"])

    out, status = prune("--apply", env:)

    expect([status.success?, out, File.exist?(File.join(archive_dir("T15"), "diff.patch"))])
      .to match([false, /archive kept.*worktree remove/m, true])
  end

  it "says so when no worktree is found" do
    out, = prune("--dry-run")

    expect(out).to include("no worktrees")
  end

  it "leaves an unmerged worktree alone and says why" do
    path = worktree("T2")
    File.write(File.join(path, "extra.txt"), "x\n")
    git("add", "extra.txt", dir: path)
    git("commit", "-q", "-m", "ahead", dir: path)

    out, = prune("--apply")

    expect([File.directory?(path), branches, out]).to match([true, include("card/T2"), /T2.*not merged/])
  end

  it "skips this plan's cards, a locked worktree and one a process is standing in, naming each reason" do
    plan = worktree("S3")
    locked = worktree("T5")
    git("worktree", "lock", locked)
    busy = worktree("T4")
    spawned << Process.spawn("sleep", "60", chdir: busy)

    out, = prune("--apply")

    expect([plan, locked, busy].map { |path| File.directory?(path) }).to eq([true, true, true])
    expect(out).to match(/S3.*plan/).and match(/T5.*locked/).and match(/T4.*in use/)
  end

  it "changes nothing on a dry run" do
    worktree("T1")
    before_listing = worktrees

    out, = prune("--dry-run")

    expect([worktrees, File.exist?(File.join(repo, "tmp", "worktree-archive")), out])
      .to match([before_listing, false, /would.*T1/])
  end

  it "prints usage and exits 2 without a mode flag" do
    out, status = prune

    expect([status.exitstatus, out]).to match([2, %r{usage.*card/S.*discard}im])
  end
end
