# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Isolation::Clone::Registry, :seam do
  subject(:registry) do
    described_class.new(repo_root: @upstream, root: @root, shell_out_factory: Lain::Shell::Out.public_method(:new))
  end

  around do |example|
    Dir.mktmpdir("lain-clone-registry") do |dir|
      @upstream = File.join(File.realpath(dir), "upstream")
      @base = File.realpath(dir)
      @root = File.join(Lain::Paths.new.state_home, "worktrees", Lain::Paths.new.project_hash(@upstream))
      FileUtils.mkdir_p([@upstream, @root])
      FileUtils.cp_r("#{SeedRepo.at(SeedRepo::SEED)}/.", @upstream)
      example.run
    ensure
      FileUtils.rm_rf([@root, "#{@root}-other"]) if @root
    end
  end

  def tip = SeedRepo.git(@upstream, "rev-parse", "HEAD").stdout.strip
  def path = File.join(@root, "a")
  def pins = SeedRepo.git(@upstream, "for-each-ref", "--format=%(refname)", "refs/lain/lease/").stdout.split("\n")
  def entry = registry.entries.find { _1.path == path }
  def root_key = Lain::Paths.new.project_hash(@root)
  def marker = File.join(@base, "fsmonitor-ran")

  # What a sandboxed call can do to a clone's git dir: an absent `commondir` naming a git dir it wrote, whose
  # config runs a program as core.fsmonitor whenever git reads the index.
  def plant_commondir
    evil = File.join(path, "evil")
    FileUtils.mkdir_p(evil)
    FileUtils.cp_r([File.join(path, ".git", "objects"), File.join(path, ".git", "refs")], evil)
    File.write(File.join(evil, "config"),
               "[core]\n\trepositoryformatversion = 0\n\tfsmonitor = \"touch #{marker}; false\"\n")
    File.write(File.join(path, ".git", "commondir"), "../evil\n")
  end

  it "lists each clone under the root with its HEAD, branch and lock, and nothing that is not a clone" do
    registry.add(path, tip, reason: "lain-retained since=2026-09-01T00:00:00Z")
    FileUtils.mkdir_p(File.join(@root, "verify", "k"))

    expect(registry.entries.map { [_1.path, _1.head, _1.branch, _1.seal] })
      .to eq([[path, tip, "", "lain-retained since=2026-09-01T00:00:00Z"]])
    expect(entry.lock).to be_a(Lain::Isolation::LeaseLock::Retained)
  end

  it "reads an unlocked clone as unlocked, and refuses a second lock as git refuses one" do
    registry.add(path, tip, reason: "first")
    registry.unlock(path)

    unlocked_again = Lain::Shell::Out.ok?(registry.unlock(path))

    expect([entry.lock, unlocked_again]).to eq([Lain::Isolation::LeaseLock::UNLOCKED, false])
    expect([registry.lock(path, "a"), registry.lock(path, "b")].map { Lain::Shell::Out.ok?(_1) }).to eq([true, false])
  end

  it "refuses to remove a locked clone, and removes an unlocked one with its pin" do
    registry.add(path, tip, reason: "held")
    refused = registry.remove(path)
    registry.unlock(path)
    removed = registry.remove(path)

    expect([Lain::Shell::Out.ok?(refused), Lain::Shell::Out.ok?(removed), File.exist?(path), pins])
      .to eq([false, true, false, []])
  end

  it "keys its base pins by its root, so two roots of one repository never share a pin" do
    registry.add(path, tip, reason: "held")

    expect(pins).to eq(["refs/lain/lease/#{root_key}/a"])
  end

  it "prunes only its own root's pins whose clone is gone" do
    other = described_class.new(repo_root: @upstream, root: "#{@root}-other",
                                shell_out_factory: Lain::Shell::Out.public_method(:new))
    FileUtils.mkdir_p("#{@root}-other")
    other.add(File.join("#{@root}-other", "b"), tip, reason: "held")
    registry.add(path, tip, reason: "held")
    FileUtils.rm_rf(path)
    registry.prune

    expect(pins.map { File.basename(_1) }).to eq(["b"])
  end

  it "lists a lock whose clone is gone, so a claim can clear it" do
    registry.add(path, tip, reason: "held")
    FileUtils.rm_rf(path)

    expect(registry.entries.map { [_1.path, _1.head, _1.seal] }).to eq([[path, "", "held"]])
  end

  it "dates a clone from when it was cut, not from the last write to its git dir" do
    registry.add(path, tip, reason: "held")
    cut = registry.cut_at(path, -> { Time.at(0) })
    FileUtils.touch(File.join(path, ".git"), mtime: cut + 3600)

    expect(cut).to be_within(60).of(Time.now)
    expect(registry.cut_at(path, -> { Time.at(0) })).to eq(cut)
  end

  it "runs no fsmonitor a clone's config names, outside any sandbox" do
    registry.add(path, tip, reason: "held")
    SeedRepo.git(path, "config", "core.fsmonitor", "touch #{marker}; false")
    File.write(File.join(path, "README"), "dirty\n")

    expect([registry.uncommitted?(path), File.exist?(marker)]).to eq([true, false])
  end

  it "runs no git in a clone whose git dir holds a planted commondir, and keeps it for a human" do
    registry.add(path, tip, reason: "held")
    plant_commondir
    registry.unlock(path)

    expect(registry.uncommitted?(path)).to be(true)
    expect(entry.lock.held?(nil)).to be(true)
    expect(entry.lock.why(nil)).to include("commondir")
    expect([Lain::Shell::Out.ok?(registry.remove(path)), File.directory?(path), File.exist?(marker)])
      .to eq([false, true, false])
  end

  # Spelled out rather than read from the guard, so dropping a name from it fails here.
  %w[commondir config.worktree worktrees modules].each do |name|
    it "runs no git in a clone whose git dir holds #{name}, and names it" do
      registry.add(path, tip, reason: "held")
      FileUtils.mkdir_p(File.join(path, ".git", name))

      expect([registry.uncommitted?(path), entry.lock.why(nil)]).to match([true, /#{Regexp.escape(name)}/])
    end
  end

  # Inside a clone, git would otherwise find a nested repository a call made and read its config.
  it "reads a directory inside the clone through the clone's own git dir, never a nested repository's" do
    registry.add(path, tip, reason: "held")
    nested = File.join(path, "sub")
    SeedRepo.git(path, "init", "-q", nested)
    File.write(File.join(nested, "ignore-all"), "*\n")
    SeedRepo.git(nested, "config", "core.excludesFile", File.join(nested, "ignore-all"))
    File.write(File.join(nested, "new.txt"), "work\n")

    expect(Lain::Isolation::Checkout.of(nested).run("status", "--porcelain", "--untracked-files=all").stdout)
      .to include("sub/")
  end

  it "guards a tampered clone reached through a link from outside the container" do
    registry.add(path, tip, reason: "held")
    plant_commondir
    File.symlink(path, link = File.join(@base, "link"))
    File.write(File.join(path, "README"), "dirty\n")

    expect(Lain::Isolation::Checkout.of(link).run("status", "--porcelain").stderr).to include("commondir")
    expect(File.exist?(marker)).to be(false)
  end

  # A linked worktree reads upstream's own config; a clone has its own, so the identity a commit needs comes along.
  # A commit hook exports its own author and committer, which outrank any config, so the spec's commit drops them.
  it "carries upstream's own commit identity, so a commit in the clone needs none of its own" do
    registry.add(path, tip, reason: "held")
    File.write(File.join(path, "README"), "work\n")
    from_config = %w[GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL].to_h { [_1, nil] }
    SeedRepo.git(path, "commit", "-q", "-am", "work", env: from_config)

    expect(SeedRepo.git(path, "log", "-1", "--format=%an <%ae>").stdout.strip).to eq("Test <test@example.com>")
  end

  it "moves a clone with its lock and its pin" do
    registry.add(path, tip, reason: "held")
    aside = File.join(@root, "retained", "a-1")
    FileUtils.mkdir_p(File.dirname(aside))
    moved = registry.move(path, aside)

    expect([Lain::Shell::Out.ok?(moved), registry.entries.map { [_1.path, _1.seal] }, pins])
      .to eq([true, [[aside, "held"]], ["refs/lain/lease/#{root_key}/a-1"]])
  end

  it "claims the lock it judged, and refuses one that changed since" do
    registry.add(path, tip, reason: "judged")
    judged = entry
    registry.unlock(path)
    registry.lock(path, "changed")

    expect([registry.claim(judged), entry.seal]).to eq([false, "changed"])
    expect(registry.claim(entry)).to be(true)
    expect(entry.lock).to eq(Lain::Isolation::LeaseLock::UNLOCKED)
  end

  it "names an interrupted claim and puts its lock back" do
    registry.add(path, tip, reason: "held")
    locked = Dir.glob(File.join(@root, ".*locked")).sole
    File.rename(locked, "#{locked}.lain-claim-deadbeef0000")

    expect(registry.interrupted(path)).to match(/interrupted lock claim .* was put back as its lock/)
    expect(File.read(locked)).to eq("held\n")
  end

  it "leaves no lock or clone behind when the clone fails" do
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "foreign"), "x")
    shell = registry.add(path, tip, reason: "held")

    expect([Lain::Shell::Out.ok?(shell), Dir.children(path), Dir.glob(File.join(@root, ".*locked")), pins])
      .to eq([false, ["foreign"], [], []])
  end

  it "folds a clone's commit into upstream before anchoring it" do
    registry.add(path, tip, reason: "held")
    File.write(File.join(path, "README"), "work\n")
    SeedRepo.git(path, "-c", "user.name=w", "-c", "user.email=w@e", "commit", "-q", "-am", "work")
    anchor = registry.anchorage.keep(entry, reason: "spec")

    expect(SeedRepo.git(@upstream, "rev-parse", anchor).stdout.strip).to eq(entry.head)
  end
end
