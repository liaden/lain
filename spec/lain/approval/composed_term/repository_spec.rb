# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "tmpdir"

# Whether the repository git finds from a directory has a config that could
# make a read run something: the question the composed term asks before it
# approves a git stage.
RSpec.describe Lain::Approval::ComposedTerm::Repository do
  def in_tree
    Dir.mktmpdir("lain-repository") { |dir| yield File.realpath(dir) }
  end

  def git(dir, *args)
    out, status = Open3.capture2e(SeedRepo::SCRUB, "git", "-c", "user.name=x", "-c", "user.email=x@x",
                                  "-c", "protocol.file.allow=always", *args, chdir: dir)
    raise "git #{args.first} failed: #{out}" unless status.success?

    out
  end

  # A real repository, as `git init` writes it, so the config read is the one git would.
  def git_repo(root, config: nil)
    FileUtils.mkdir_p(root)
    git(root, "init", "-q")
    File.write(File.join(root, ".git", "config"), config, mode: "a") if config
    root
  end

  def write(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  # MEASURED: `git status` and `git diff --stat` both ran this hook, with
  # .gitmodules naming the submodule and without it; `git log` did not.
  # The submodule's repository is its own `.git`, not one under `modules`.
  def non_absorbed(dir, gitmodules:)
    root = git_repo(File.join(dir, "repo"))
    write(File.join(root, "a.md"), "a\n")
    sub = git_repo(File.join(root, "sub"))
    write(File.join(sub, "s.md"), "s\n")
    git(sub, "add", "s.md")
    git(sub, "commit", "-qm", "s")
    write(File.join(root, ".gitmodules"), "[submodule \"sub\"]\n\tpath = sub\n\turl = ./sub\n") if gitmodules
    git(root, "add", "-A")
    git(root, "commit", "-qm", "init")
    [root, sub]
  end

  describe ".quiet?" do
    it "holds for a repository as git init writes it, and where no repository is found" do
      in_tree do |dir|
        expect(described_class.quiet?(git_repo(File.join(dir, "repo")))).to be(true)
        expect(described_class.quiet?(dir)).to be(true)
      end
    end

    it "refuses a config that names a program, includes a file or moves the tree, however it is spelled" do
      configs = ["[core]\n\tfsmonitor = id\n", "[core]\n\tpager = sh\n", "[diff]\n\texternal = id\n",
                 "[diff \"x\"]\n\ttextconv = id\n", "[filter \"x\"]\n\tclean = id\n", "[include]\n\tpath = x\n",
                 "[includeIf \"gitdir:/\"]\n\tpath = x\n", "[Core]\n\tFsMonitor = id\n", "[core] fsmonitor = id\n",
                 "[core]\n\tworktree = /\n", "[core]\n\tfsmonitor\n"]
      configs.each do |config|
        in_tree do |dir|
          expect(described_class.quiet?(git_repo(File.join(dir, "repo"), config:))).to be(false), config
        end
      end
    end

    # git reads a value ending in a backslash on into the next line, so a line
    # read alone may not be what git reads; refusing costs a prompt.
    it "refuses a value continued onto the next line, which a line-by-line reading cannot place" do
      in_tree do |dir|
        repo = git_repo(File.join(dir, "repo"), config: "[user]\n\tname = x \\\n\ty\n")

        expect(described_class.quiet?(repo)).to be(false)
      end
    end

    it "refuses a config larger than it reads, though every line it would read is plain" do
      in_tree do |dir|
        repo = git_repo(File.join(dir, "repo"), config: "# plain\n" * 9000)

        expect(File.size(File.join(repo, ".git", "config"))).to be > 64 * 1024
        expect(described_class.quiet?(repo)).to be(false)
      end
    end

    it "reads the config a linked worktree shares through its commondir" do
      in_tree do |dir|
        common = git_repo(File.join(dir, "main"), config: "[core]\n\tfsmonitor = id\n")
        write(File.join(common, ".git", "worktrees", "wt", "commondir"), "../..\n")
        root = File.join(dir, "wt")
        write(File.join(root, ".git"), "gitdir: #{common}/.git/worktrees/wt\n")

        expect(described_class.quiet?(root)).to be(false)
      end
    end

    # git takes a directory holding a HEAD for a repository itself, before it
    # looks further up; the plain repository above must not answer for it.
    it "reads the config of a directory git takes for a repository, not the plain one above it" do
      in_tree do |dir|
        root = git_repo(File.join(dir, "repo"))
        fake = File.join(root, "fake")
        write(File.join(fake, "HEAD"), "ref: refs/heads/main\n")
        write(File.join(fake, "config"), "[core]\n\tfsmonitor = id\n")

        expect(described_class.quiet?(root)).to be(true)
        expect(described_class.quiet?(fake)).to be(false)
      end
    end

    # git status and diff recurse into each submodule, reading that
    # repository's own config, whose `core.worktree` git itself writes.
    it "reads each absorbed submodule's own config, a nested one under a slashed name included" do
      in_tree do |dir|
        root = git_repo(File.join(dir, "repo"))
        lib = File.join(root, ".git", "modules", "vendor", "lib")
        write(File.join(lib, "HEAD"), "ref: refs/heads/main\n")
        write(File.join(lib, "config"), "[core]\n\tbare = false\n\tworktree = ../../../../vendor/lib\n")
        expect(described_class.quiet?(root)).to be(true)

        inner = File.join(lib, "modules", "inner")
        write(File.join(inner, "HEAD"), "ref: refs/heads/main\n")
        write(File.join(inner, "config"), "[core]\n\tfsmonitor = id\n")
        expect(described_class.quiet?(root)).to be(false)
      end
    end

    it "refuses a submodule whose repository is its own .git, with or without .gitmodules naming it" do
      [true, false].each do |gitmodules|
        in_tree do |dir|
          root, = non_absorbed(dir, gitmodules:)

          expect(described_class.quiet?(root)).to be(false), "gitmodules: #{gitmodules}"
        end
      end
    end

    it "refuses a submodule whose pointer leads anywhere but under the repository's modules" do
      in_tree do |dir|
        root, sub = non_absorbed(dir, gitmodules: true)
        elsewhere = File.join(dir, "elsewhere.git")
        FileUtils.mv(File.join(sub, ".git"), elsewhere)
        write(File.join(sub, ".git"), "gitdir: #{elsewhere}\n")

        expect(described_class.quiet?(root)).to be(false)
      end
    end

    # MEASURED in review: with a split index the gitlink lives in the shared
    # index, so a reader of `.git/index` alone found none and git ran the hook.
    it "refuses a non-absorbed gitlink kept in a split index's shared half" do
      in_tree do |dir|
        root, = non_absorbed(dir, gitmodules: true)
        git(root, "update-index", "--split-index")

        expect(Dir.glob(File.join(root, ".git", "sharedindex.*"))).not_to be_empty
        expect(described_class.quiet?(root)).to be(false)
      end
    end

    # MEASURED in review: git reads an entry's name length from its flags, so
    # an index git accepts can show a byte reader a different entry list, the
    # gitlink's tail hidden in an extension git drops. So git lists them.
    it "refuses a gitlink git sees in an index crafted to hide it from a byte reader" do
      in_tree do |dir|
        root, sub = non_absorbed(dir, gitmodules: false)
        head = git(sub, "rev-parse", "HEAD").strip
        index = File.join(root, ".git", "index")
        expect(git(root, "ls-files", "-s").lines.map { _1.split.first }).to eq(%w[100644 160000])
        expect(head).to match(/\A\h{40}\z/)

        File.binwrite(index, crafted(File.binread(index)))

        expect(git(root, "ls-files", "-s")).to include("160000 #{head} 0\tsub")
        expect(described_class.quiet?(root)).to be(false)
      end
    end

    # The reviewer's shape: padding and the gitlink's leading fields carry no
    # NUL, so a reader scanning for one runs past a.md's name to the gitlink's
    # mode, and the rest sits inside an UNTR extension git ignores.
    def crafted(real)
      first = real.byteslice(12, 72).dup
      gitlink = real.byteslice(84, 72).dup
      first[66, 6] = "x" * 6
      gitlink[0, 24] = "A" * 24
      data = "#{"z" * 12}#{[0x0001].pack("n")}q\0"
      body = "DIRC#{[2, 2].pack("NN")}#{first}#{gitlink}UNTR#{[data.bytesize].pack("N")}#{data}"
      body + Digest::SHA1.digest(body)
    end

    it "holds for a submodule git absorbed into modules, and for one never checked out" do
      in_tree do |dir|
        root, sub = non_absorbed(dir, gitmodules: true)
        git(root, "submodule", "absorbgitdirs")
        expect(File.file?(File.join(sub, ".git"))).to be(true)
        expect(described_class.quiet?(root)).to be(true)

        FileUtils.rm_rf(sub)
        expect(described_class.quiet?(root)).to be(true)
      end
    end
  end

  # The gitlinks are git's own `ls-files`, so each shape here is one git wrote,
  # or one git cannot read.
  describe "the gitlinks git lists" do
    def absorbed(dir)
      root, sub = non_absorbed(dir, gitmodules: true)
      git(root, "submodule", "absorbgitdirs")
      [root, sub]
    end

    # MEASURED: without the overrides, `git ls-files -s` ran the hook a
    # global core.fsmonitor named, in every shape tried. The check is asked
    # before any approval, so it must run nothing itself.
    it "runs no hook the user's own config names while it lists them" do
      in_tree do |dir|
        root, = absorbed(dir)
        marker = File.join(dir, "ran")
        hook = File.join(dir, "hook.sh")
        write(hook, "#!/bin/sh\ntouch #{marker}\n")
        File.chmod(0o755, hook)
        global = File.join(dir, "global.gitconfig")
        write(global, "[core]\n\tfsmonitor = #{hook}\n\tuntrackedCache = true\n")
        write(File.join(root, "a.md"), "changed\n")

        expect(with_global_config(global) { described_class.quiet?(root) }).to be(true)
        expect(File.exist?(marker)).to be(false)
      end
    end

    def with_global_config(path)
      kept = ENV.fetch("GIT_CONFIG_GLOBAL", nil)
      ENV["GIT_CONFIG_GLOBAL"] = path
      yield
    ensure
      ENV["GIT_CONFIG_GLOBAL"] = kept
    end

    # The caller's own git variables would point git at another index or
    # repository, whose list need not hold the gitlink the command will meet.
    it "lists the gitlinks of the repository found, whatever git variables this process carries" do
      in_tree do |dir|
        root, = non_absorbed(dir, gitmodules: true)
        other = git_repo(File.join(dir, "other"))
        pointed = { "GIT_DIR" => File.join(other, ".git"), "GIT_INDEX_FILE" => File.join(other, ".git", "index") }

        expect(with_env(pointed) { described_class.quiet?(root) }).to be(false)
      end
    end

    def with_env(variables)
      kept = variables.keys.to_h { [_1, ENV.fetch(_1, nil)] }
      variables.each { |name, value| ENV[name] = value }
      yield
    ensure
      kept.each { |name, value| ENV[name] = value }
    end

    it "refuses a clean exit whose output it cannot read as index records" do
      in_tree do |dir|
        root, = absorbed(dir)
        unreadable = instance_double(Lain::Shell::Out, stdout: +"not a record\0", exitstatus: 0)
        allow(unreadable).to receive(:run_command).and_return(unreadable)
        allow(Lain::Shell::Out).to receive(:new).and_return(unreadable)

        expect(described_class.quiet?(root)).to be(false)
      end
    end

    it "refuses an index git cannot read, rather than reading it as holding no gitlink" do
      in_tree do |dir|
        root, = absorbed(dir)
        File.binwrite(File.join(root, ".git", "index"), "DIRC#{[2, 3].pack("NN")}short")

        expect(described_class.quiet?(root)).to be(false)
      end
    end

    it "reads an absorbed submodule's own gitlinks, refusing one checked out as a repository of its own" do
      in_tree do |dir|
        root, sub = absorbed(dir)
        head = git(sub, "rev-parse", "HEAD").strip
        git(sub, "update-index", "--add", "--cacheinfo", "160000,#{head},nested")
        expect(described_class.quiet?(root)).to be(true)

        git_repo(File.join(sub, "nested"))
        expect(described_class.quiet?(root)).to be(false)
      end
    end

    it "refuses a submodule's .git that is a link, even one to a pointer into modules" do
      in_tree do |dir|
        root, sub = absorbed(dir)
        pointer = File.join(dir, "pointer")
        File.write(pointer, File.read(File.join(sub, ".git")).sub(/\Agitdir: (.+)$/) do
          "gitdir: #{File.expand_path(Regexp.last_match(1), sub)}"
        end)
        File.delete(File.join(sub, ".git"))
        File.symlink(pointer, File.join(sub, ".git"))

        expect(described_class.quiet?(root)).to be(false)
      end
    end
  end
end
