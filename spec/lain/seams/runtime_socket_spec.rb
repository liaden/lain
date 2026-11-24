# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

# ABI 8 Landlock cannot refuse a Unix connect, so what keeps a confined call off the host's sockets is that
# bwrap leaves them out of its view. Listings run under bwrap alone, because the fence would refuse the read
# and an empty answer would then prove nothing.
RSpec.describe "A confined call's view of the runtime sockets", :seam do
  let(:fence) { Lain::Confine::Bwrap.fence_binary }
  let(:journal) { RecordingChannel.new }

  around do |example|
    Dir.mktmpdir("r") do |dir|
      @base = File.realpath(dir)
      @repo, @home, @tmp = %w[repo home tmp].map { File.join(@base, _1) }
      FileUtils.mkdir_p([@repo, @home, @tmp])
      SeedRepo.git(@repo, "init", "-q")
      example.run
    end
  end

  before do
    skip("bwrap or strace is not installed") unless %w[/usr/bin/bwrap /usr/bin/strace /usr/bin/python3]
                                                    .all? { File.executable?(_1) }
    skip("lain-fence is not built at #{fence}") unless File.executable?(fence)
    skip("bwrap cannot make a user namespace on this host") unless
      system("/usr/bin/bwrap", "--ro-bind", "/", "/", "--", "true", %i[out err] => File::NULL)
  end

  def wrapped(profile, argv, env)
    launcher = Lain::Confine::Bwrap.on_path(fence:, env:)
    bound = launcher.masked(profile).bind(stages: 1, first_fd: 4)
    yield launcher.wrap(Lain::Shell::Term.of(argv), profile, trace_fd: 3, bound:).stages.first.argv, bound.fds
  ensure
    bound&.close
  end

  def confined(profile, *argv, env: ENV.to_h)
    wrapped(profile, argv, env) do |full, fds|
      Open3.capture3("timeout", "20", *full, chdir: @repo, **fds)
    end
  end

  describe "git state a call wrote, read back by the next call" do
    let(:script) { File.expand_path("../../../bin/workspace-run", __dir__) }
    let(:run_env) do
      ENV.to_h.merge("XDG_STATE_HOME" => File.join(@base, "state"), "XDG_CACHE_HOME" => File.join(@base, "cache"))
    end

    before { FileUtils.rm_rf(File.join(@repo, ".git")) }

    def workspace_run(*argv, root: @repo, env: run_env)
      Open3.capture3(env, "timeout", "30", RbConfig.ruby, script, "--root", root, "--", *argv, chdir: root)
    end

    def forged_git_dir(hooks)
      plant("mkdir -p .git/objects .git/refs/heads; echo ref: refs/heads/main > .git/HEAD; " \
            "printf '[core]\\n\\trepositoryformatversion = 0\\n\\thooksPath = #{hooks}\\n' > .git/config")
    end

    def hook_at(dir)
      FileUtils.mkdir_p(dir)
      File.write(hook = File.join(dir, "pre-commit"), "#!/bin/sh\ntouch hook-ran\n")
      File.chmod(0o755, hook)
    end

    def plant(shell) = workspace_run("/usr/bin/bash", "-c", shell).tap { expect(_1.last.success?).to be(true), _1[1] }

    describe "a forged pointer at another real repository" do
      let(:other) { File.join(@base, "other") }
      let(:description) { File.join(other, ".git", "description") }

      before { SeedRepo.git(@base, "init", "-q", other) }

      def expect_no_write(forge)
        before = File.read(description)
        plant(forge)

        out, err, = workspace_run("/usr/bin/bash", "-c", "echo planted > #{description}")

        expect(out + err).to match(/Permission denied|Read-only file system|REFUSED/)
        expect(File.read(description)).to eq(before)
      end

      it "gets no write into it through a .git file" do
        expect_no_write("echo 'gitdir: #{other}/.git' > .git")
      end

      it "gets no write into it through a .git directory naming it as commondir" do
        expect_no_write("mkdir -p .git/objects .git/refs; echo ref: refs/heads/main > .git/HEAD; " \
                        "echo #{other}/.git > .git/commondir")
      end

      it "gets no write into it through a .git link" do
        expect_no_write("ln -s #{other}/.git .git")
      end
    end

    describe "a planted git layout beside a victim repository" do
      let(:victim) { File.join(@base, "victim") }
      let(:refs_plant) { File.join(victim, ".git", "refs", "planted") }
      let(:identity) { %w[-c user.email=spec@example.invalid -c user.name=spec] }

      before do
        SeedRepo.git(@base, "init", "-q", victim)
        SeedRepo.git(victim, *identity, "commit", "-q", "--allow-empty", "-m", "first")
        File.write(File.join(victim, ".git", "description"), "zq_victim_mark\n")
      end

      it "runs git status, log, diff and rev-parse in a project inside a repository" do
        parent = File.join(@base, "parent")
        FileUtils.mkdir_p(inner = File.join(parent, "inner"))
        SeedRepo.git(parent, "init", "-q")
        File.write(File.join(inner, "f"), "x\n")
        SeedRepo.git(parent, "add", "-A")
        SeedRepo.git(parent, *identity, "commit", "-q", "-m", "zq_parent_commit")
        File.write(File.join(inner, "f"), "y\n")
        script = "git status --short && git log --oneline -1 && git diff --stat && git rev-parse --show-toplevel"

        out, err, status = workspace_run("/usr/bin/bash", "-c", script, root: inner)

        expect(status.success?).to be(true), err
        expect(out).to include("M f").and include("zq_parent_commit").and include("1 file changed")
        expect(out.lines.last.strip).to eq(parent)
      end

      it "gives a project inside a repository no write through a planted parent commondir" do
        parent = File.join(@base, "parent")
        FileUtils.mkdir_p(inner = File.join(parent, "inner"))
        SeedRepo.git(parent, "init", "-q")
        File.write(File.join(parent, ".git", "commondir"), "#{victim}/.git\n")

        workspace_run("/usr/bin/bash", "-c", "echo x > #{refs_plant}", root: inner)

        expect(File).not_to exist(refs_plant)
      end

      it "stops a project inside a repository rewriting the parent's HEAD" do
        parent = File.join(@base, "parent")
        FileUtils.mkdir_p(inner = File.join(parent, "inner"))
        SeedRepo.git(parent, "init", "-q")
        head = File.join(parent, ".git", "HEAD")
        before = File.read(head)

        workspace_run("/usr/bin/bash", "-c", "echo planted >> #{head}", root: inner)

        expect(File.read(head)).to eq(before)
      end

      it "gives an unrelated project nothing from a config planted in a worktree's admin dir" do
        linked = File.join(@base, "linked")
        SeedRepo.git(victim, "worktree", "add", "-q", linked)
        admin = File.join(victim, ".git", "worktrees", "linked")
        File.write(File.join(admin, "config"), "[core]\n\tworktree = #{@repo}\n")
        File.write(File.join(@repo, ".git"), "gitdir: #{admin}\n")

        out, = workspace_run("/usr/bin/bash", "-c", "cat #{victim}/.git/description; echo x > #{refs_plant}")

        expect(out).not_to include("zq_victim_mark")
        expect(File).not_to exist(refs_plant)
      end

      it "reads nothing through an admin dir in the project swapped for a link after the check" do
        FileUtils.mkdir_p(admin = File.join(@repo, ".f"))
        File.write(File.join(@repo, ".git"), "gitdir: .f\n")
        File.write(File.join(admin, "gitdir"), "#{@repo}/.git\n")
        reader = Lain::Confine::Profile.reader(root: @repo, home: @home, trace: false)
        File.rename(admin, "#{admin}2")
        File.symlink("#{victim}/.git", admin)

        out, = confined(reader, "/usr/bin/cat", "#{victim}/.git/description")

        expect(out).not_to include("zq_victim_mark")
      end
    end

    describe "a hooks path in a config the call wrote" do
      it "grants no read of a host directory" do
        FileUtils.mkdir_p(host = File.join(@base, "host"))
        File.write(note = File.join(host, "note"), "fixture-private\n")
        forged_git_dir(host)

        out, err, = workspace_run("/usr/bin/cat", note)

        expect(out).not_to include("fixture-private")
        expect(err).to include("Permission denied")
      end
    end

    context "with a real repository" do
      let(:identity) { %w[-c user.email=spec@example.invalid -c user.name=spec] }

      before do
        SeedRepo.git(@repo, "init", "-q")
        SeedRepo.git(@repo, *identity, "commit", "-q", "--allow-empty", "-m", "first")
      end

      it "keeps git working in a real linked worktree, commits included" do
        linked = File.join(@base, "linked")
        SeedRepo.git(@repo, "worktree", "add", "-q", linked)

        out, err, status = workspace_run("/usr/bin/git", *identity, "commit", "-q", "--allow-empty", "-m", "second",
                                         root: linked)

        expect(status.success?).to be(true), out + err
        expect(SeedRepo.git(linked, "log", "-1", "--format=%s").stdout).to include("second")
      end

      it "still answers and seals a hooks path inside the project" do
        hook_at(File.join(@repo, ".githooks"))
        SeedRepo.git(@repo, "config", "core.hooksPath", ".githooks")

        out, = workspace_run("/usr/bin/git", "rev-parse", "--git-path", "hooks")
        _, err, = workspace_run("/usr/bin/bash", "-c", "echo planted > .githooks/pre-commit")

        expect(out).to include(".githooks")
        expect(err).to match(/Read-only file system|Permission denied/)
        expect(File.read(File.join(@repo, ".githooks", "pre-commit"))).not_to include("planted")
      end

      it "runs a hooks path outside the project that global config names" do
        hook_at(hooks = File.join(@base, "global-hooks"))
        File.write(File.join(@home, ".gitconfig"), "[core]\n\thooksPath = #{hooks}\n")
        env = run_env.except("GIT_CONFIG_GLOBAL").merge("HOME" => @home, "TMPDIR" => @tmp, "GIT_CONFIG_GLOBAL" => nil)

        _, err, status = workspace_run("/usr/bin/git", *identity, "commit", "-q", "--allow-empty", "-m", "hooked", env:)

        expect(status.success?).to be(true), err
        expect(File).to exist(File.join(@repo, "hook-ran"))
      end

      it "keeps git reading a real submodule used as the project" do
        upstream = File.join(@base, "upstream")
        SeedRepo.git(@base, "init", "-q", upstream)
        SeedRepo.git(upstream, *identity, "commit", "-q", "--allow-empty", "-m", "upstream")
        SeedRepo.git(@repo, *identity, "-c", "protocol.file.allow=always", "submodule", "add", "-q", upstream, "sub")

        out, err, status = workspace_run("/usr/bin/git", "log", "-1", "--format=%s", root: File.join(@repo, "sub"))

        expect(status.success?).to be(true), err
        expect(out).to include("upstream")
      end
    end
  end
end
