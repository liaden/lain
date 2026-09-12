# frozen_string_literal: true

require "fileutils"

# Every fixture here is a plain directory holding a hand-written `.git` FILE.
# None of them is a real worktree, and none may become one: producing the tree
# this guard refuses means `git worktree add` followed by `cp -a`, and a suite
# run from such a copy once deleted the copy. The pointer file is the whole
# mechanism, so a hand-written one reproduces it exactly and destroys nothing.
#
# The guard is loaded here as well as from spec_helper, so this file still runs
# on its own and still fails if the suite ever stops booting it.
require_relative "worktree_identity"

RSpec.describe WorktreeIdentity do
  around do |example|
    Dir.mktmpdir("worktree-identity") do |dir|
      @sandbox = File.realpath(dir)
      example.run
    end
  end

  attr_reader :sandbox

  def checkout(name, gitdir:)
    File.join(sandbox, name).tap do |dir|
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, ".git"), "gitdir: #{gitdir}\n")
    end
  end

  # A linked worktree's admin stub: a `gitdir` file naming the checkout's own
  # `.git`, and no `config`.
  def admin(name, gitdir:)
    File.join(sandbox, name).tap do |dir|
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "gitdir"), "#{gitdir}\n")
    end
  end

  # A submodule's admin directory, in the layout git really writes: a `config`
  # naming the checkout in `core.worktree`, and no `gitdir`.
  def module_admin(name, worktree:)
    config_admin(name, body: <<~CONFIG)
      [core]
      \trepositoryformatversion = 0
      \tbare = false
      \tworktree = #{worktree}
    CONFIG
  end

  def config_admin(name, body:)
    File.join(sandbox, name).tap do |dir|
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "config"), body)
    end
  end

  # The message is the whole product of a refusal, so the shape of it is asserted
  # rather than only the class it arrives as.
  def refusal(tree)
    described_class.verify!(tree)
    "nothing was refused for #{tree}"
  rescue described_class::Foreign => e
    e.message
  end

  it "accepts a linked worktree whose admin directory names it back" do
    tree = checkout("worktree", gitdir: File.join(sandbox, "admin"))
    admin("admin", gitdir: File.join(tree, ".git"))

    expect(described_class.verify!(tree)).to eq(tree)
  end

  it "accepts the checkout the suite is itself running from", :seam do
    expect(described_class.verify!).to eq(File.expand_path("..", __dir__))
  end

  it "refuses a copy whose pointer names another checkout's admin directory, naming both" do
    original = checkout("original", gitdir: File.join(sandbox, "admin"))
    copy = checkout("copy", gitdir: File.join(sandbox, "admin"))
    admin("admin", gitdir: File.join(original, ".git"))

    expect { described_class.verify!(copy) }.to raise_error(
      described_class::Foreign, a_string_including(File.join(sandbox, "admin")).and(a_string_including(copy))
    )
  end

  it "accepts a submodule, whose admin directory names it in core.worktree" do
    tree = checkout("super/sub", gitdir: File.join(sandbox, "super/.git/modules/sub"))
    module_admin("super/.git/modules/sub", worktree: "../../../sub")

    expect(described_class.verify!(tree)).to eq(tree)
  end

  it "refuses a copied submodule, whose admin directory names the original" do
    original = checkout("super/sub", gitdir: File.join(sandbox, "super/.git/modules/sub"))
    copy = checkout("elsewhere/sub", gitdir: File.join(sandbox, "super/.git/modules/sub"))
    module_admin("super/.git/modules/sub", worktree: original)

    expect { described_class.verify!(copy) }.to raise_error(
      described_class::Foreign, a_string_including(original).and(a_string_including(copy))
    )
  end

  it "refuses a truncated pointer file by saying so, with no blank where a path belongs" do
    tree = File.join(sandbox, "interrupted")
    FileUtils.mkdir_p(tree)
    File.write(File.join(tree, ".git"), "gitdi")

    expect(refusal(tree)).to include(File.join(tree, ".git"), "holds no readable")
    expect(refusal(tree)).not_to include("admin directory")
  end

  it "refuses an unreadable pointer file with the same sentence rather than a bare Errno" do
    skip("root reads a mode-000 file") if Process.uid.zero?
    tree = checkout("unreadable", gitdir: File.join(sandbox, "admin"))
    File.chmod(0, File.join(tree, ".git"))

    expect { described_class.verify!(tree) }.to raise_error(described_class::Foreign, /holds no readable/)
  end

  # `git init --separate-git-dir` writes exactly this: a pointer file, and an
  # admin `config` whose `[core]` names no worktree at all.
  it "refuses an admin directory registering no checkout, naming the shape and advising no deletion" do
    tree = checkout("puzzling", gitdir: File.join(sandbox, "separate-admin"))
    config_admin("separate-admin", body: "[core]\n\trepositoryformatversion = 0\n\tbare = false\n")

    expect(refusal(tree)).to include(File.join(sandbox, "separate-admin"), "registers no checkout",
                                     "--separate-git-dir")
    expect(refusal(tree)).not_to include("Delete")
  end

  it "reads core.worktree from the [core] section wherever that section sits" do
    tree = checkout("late-core", gitdir: File.join(sandbox, "late-admin"))
    config_admin("late-admin", body: "[alias]\n\tworktree = worktree list\n[core]\n\tworktree = ../late-core\n")

    expect(described_class.verify!(tree)).to eq(tree)
  end

  it "ignores a `worktree =` outside [core] rather than advising a deletion over a misparse" do
    tree = checkout("aliased", gitdir: File.join(sandbox, "alias-admin"))
    config_admin("alias-admin", body: "[alias]\n\tworktree = worktree list\n")

    expect(refusal(tree)).to include("registers no checkout")
    expect(refusal(tree)).not_to include("worktree list", "Delete")
  end

  it "refuses a pointer file of invalid UTF-8 with its own sentence, not an encoding error" do
    tree = File.join(sandbox, "corrupt")
    FileUtils.mkdir_p(tree)
    File.binwrite(File.join(tree, ".git"), "gitdir: \xFF\xFE/nowhere\n")

    expect(refusal(tree)).to include(File.join(tree, ".git"))
  end

  it "refuses an admin config of invalid UTF-8 with its own sentence, not an encoding error" do
    tree = checkout("corrupt-config", gitdir: File.join(sandbox, "corrupt-admin"))
    FileUtils.mkdir_p(File.join(sandbox, "corrupt-admin"))
    File.binwrite(File.join(sandbox, "corrupt-admin", "config"), "[core]\n\tfilemode = \xFF\xFE\n")

    expect(refusal(tree)).to include("registers no checkout")
  end

  it "refuses a pointer into an admin directory that no longer exists" do
    orphan = checkout("orphan", gitdir: File.join(sandbox, "gone"))

    expect { described_class.verify!(orphan) }.to raise_error(
      described_class::Foreign, a_string_including(File.join(sandbox, "gone"))
    )
  end

  it "accepts a primary checkout, whose .git is a directory" do
    primary = File.join(sandbox, "primary")
    FileUtils.mkdir_p(File.join(primary, ".git"))

    expect(described_class.verify!(primary)).to eq(primary)
  end

  # `worktree.useRelativePaths` writes both files relative to themselves, so
  # neither side can be compared without being resolved against its own directory.
  it "accepts a linked worktree whose two pointers are relative" do
    tree = checkout("wt/foo", gitdir: "../../repo/.git/worktrees/foo")
    admin("repo/.git/worktrees/foo", gitdir: "../../../../wt/foo/.git")

    expect(described_class.verify!(tree)).to eq(tree)
  end
end
