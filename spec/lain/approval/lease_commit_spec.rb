# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Approval::LeaseCommit, :seam do
  around do |example|
    Dir.mktmpdir("lain-lease-commit") do |base|
      @base = File.realpath(base)
      @home = File.join(@base, "home").tap { FileUtils.mkdir_p(_1) }
      example.run
    end
  end

  after { Array(@leases).each { _1.release(discard: true) } }

  def seeded(main)
    FileUtils.cp_r("#{SeedRepo.at(SeedRepo::SEED)}/.", main.tap { FileUtils.mkdir_p(_1) })
    SeedRepo.git(main, "branch", "-M", "main")
    # The seed turns hooks off, and these examples are about the hooks a lease runs.
    SeedRepo.git(main, "config", "--unset", "core.hooksPath")
    main
  end

  def cut(main)
    lease = Lain::CLI::IsolationBackend.resolve("worktree", root: main).acquire("lease#{Array(@leases).size}")
    @leases = [*@leases, lease]
    lease.origin.path
  end

  def main = @main ||= seeded(File.join(@base, "main"))

  def hook(dir, name: "pre-commit")
    File.join(dir, name).tap do |path|
      FileUtils.mkdir_p(dir)
      File.write(path, "#!/bin/sh\ntouch #{File.join(@base, "hook-ran")}\n")
      File.chmod(0o755, path)
    end
  end

  # The production chain over the real factory and resolver, the root a lease as the drain's chat is rooted,
  # under the workspace arm the rule is built for. Freshness is by write record alone, so a file is fresh only
  # where an example says it was written. HOME and the XDG config dir are the example's own, and the process
  # env the child env inherits is `inherited`, empty unless an example says otherwise.
  def chain(root, cwd: root, written: [], remembered: [], env: {}, inherited: {}, pass: [],
            lend: Lain::Exec::ChildEnv::Lend::None)
    fresh = Lain::Shell::Executable::Fresh.new(start: Time.now + 3600, written:, stat: Lain::Shell::Executable::Stat.new)
    resolver = Lain::Shell::Executable::Resolver.new(root:, fresh:)
    lent = { "PATH" => "/usr/bin", "HOME" => @home, "XDG_CONFIG_HOME" => File.join(@home, "xdg") }.merge(env)
    factory = Lain::CLI::Wiring::BoardBuild::Classifiers.new(
      home: @home, cwd:, root:, confinement: Lain::Approval::Root.new(root), resolver:,
      worker_env: Lain::WorkerEnv.new(cwd:, env: lent)
    )
    child_env = Lain::Exec::ChildEnv.new(pass:, env: inherited, lend:)
    Lain::Approval::Escalation::Rules.ladder(Lain::CLI::Wiring::BoardBuild.approving(remembered, factory,
                                                                                     workspace: true, child_env:))
  end

  def call_of(command, cwd:, verdict: Lain::Shell::Verdict.new)
    Lain::Approval::Rule::Call.for(tool: Lain::Tools::Bash.new(verdict:), input: { "command" => command, "cwd" => cwd })
  end

  def decided(root, command, cwd: root, verdict: Lain::Shell::Verdict.new, **)
    chain(root, cwd:, **).call(call_of(command, cwd:, verdict:)).decision
  end

  def executable(dir, name)
    File.join(dir, name).tap do |path|
      FileUtils.mkdir_p(dir)
      File.write(path, "#!/bin/sh\nexec /usr/bin/git \"$@\"\n")
      File.chmod(0o755, path)
    end
  end

  it "approves a commit in the clone lease lain cut, and the commit lands there with its installed hook run" do
    hook(File.join(main, ".git", "hooks"))
    lease = cut(main)
    File.write(File.join(lease, "chore.txt"), "done\n")
    SeedRepo.git(lease, "add", "chore.txt")
    before = SeedRepo.git(lease, "rev-parse", "HEAD").stdout

    decision = decided(lease, 'git commit -m "chore"')
    SeedRepo.git(lease, "commit", "-q", "-m", "chore")

    expect(decision).to have_attributes(verdict: :allow, rule: "lease_commit")
    expect(SeedRepo.git(lease, "rev-parse", "HEAD").stdout).not_to eq(before)
    expect(File).to exist(File.join(@base, "hook-ran"))
  end

  it "has no opinion on a commit in an ordinary project" do
    expect(decided(main, "git commit -m x")).to be_nil
  end

  it "has no opinion on a commit that skips the hooks" do
    lease = cut(main)

    expect(["git commit --no-verify -m x", "git commit -n -m x"].map { decided(lease, _1) }).to eq([nil, nil])
  end

  it "has no opinion on a commit with anything but a message and the plain switches" do
    lease = cut(main)
    commands = ["git commit", "git commit --amend -m x", "git commit -F msg", "git -c core.hooksPath=x commit -m x",
                "git commit -m x && ls", "git commit -m x file.txt"]

    expect(commands.map { decided(lease, _1) }).to all(be_nil)
  end

  it "has no opinion where the lease's own hooks path points inside the lease" do
    lease = cut(main)
    hook(File.join(lease, ".githooks"))
    SeedRepo.git(lease, "config", "core.hooksPath", File.join(lease, ".githooks"))

    expect(decided(lease, "git commit -m chore")).to be_nil
  end

  it "has no opinion where this lineage wrote the hook" do
    written = hook(File.join(main, ".git", "hooks"))

    expect(decided(cut(main), "git commit -m chore", written: [written])).to be_nil
  end

  it "has no opinion where this lineage wrote the lease's config" do
    lease = cut(main)

    expect(decided(lease, "git commit -m chore", written: [File.join(lease, ".git", "config")])).to be_nil
  end

  it "has no opinion on a lease whose git dir carries a redirecting name" do
    lease = cut(main)
    File.write(File.join(lease, ".git", "commondir"), ".\n")

    expect(decided(lease, "git commit -m chore")).to be_nil
  end

  it "is outranked by a remembered human deny of the same commit" do
    lease = cut(main)
    remembered = Lain::Approval::Remembered.new(deny: [{ "tool" => "bash",
                                                         "input" => { "command" => "git commit -m chore",
                                                                      "cwd" => lease } }])

    expect(decided(lease, "git commit -m chore", remembered: [remembered]))
      .to have_attributes(verdict: :deny, rule: "remembered")
  end

  it "has no opinion where the lease's git dir is a pointer to another repository" do
    lease = cut(main)
    FileUtils.mv(File.join(lease, ".git"), File.join(lease, ".git-moved"))
    File.write(File.join(lease, ".git"), "gitdir: #{File.join(main, ".git")}\n")

    expect(decided(lease, "git commit -m chore")).to be_nil
  ensure
    FileUtils.rm_f(File.join(lease, ".git"))
    FileUtils.mv(File.join(lease, ".git-moved"), File.join(lease, ".git"))
  end

  it "has no opinion where the env would point git at another repository" do
    lease = cut(main)
    upstream = File.join(main, ".git")
    envs = [{ "GIT_DIR" => upstream }, { "GIT_WORK_TREE" => main }, { "GIT_COMMON_DIR" => upstream }]

    expect(envs.map { decided(lease, "git commit -m chore", env: _1) }).to eq([nil, nil, nil])
  end

  it "has no opinion where this lineage wrote the user's global or XDG git config" do
    lease = cut(main)
    global = File.join(@home, ".gitconfig")
    xdg = File.join(@home, "xdg", "git", "config")
    [global, xdg].each do |config|
      FileUtils.mkdir_p(File.dirname(config))
      File.write(config, "[core]\n\tquotePath = false\n")
    end

    expect([global, xdg].map { decided(lease, "git commit -m chore", written: [_1]) }).to eq([nil, nil])
    expect(decided(lease, "git commit -m chore")).to have_attributes(verdict: :allow)
  end

  it "reads the XDG git config under HOME when XDG_CONFIG_HOME is unset" do
    lease = cut(main)
    xdg = File.join(@home, ".config", "git", "config")
    FileUtils.mkdir_p(File.dirname(xdg))
    File.write(xdg, "[core]\n\tquotePath = false\n")

    expect(decided(lease, "git commit -m chore", written: [xdg], env: { "XDG_CONFIG_HOME" => nil })).to be_nil
  end

  it "has no opinion where the root is the directory that holds the lease" do
    lease = cut(main)

    expect(decided(File.dirname(lease), "git commit -m chore", cwd: lease)).to be_nil
  end

  it "has no opinion where the root is a directory inside the lease" do
    lease = cut(main)
    inner = File.join(lease, "sub").tap { FileUtils.mkdir_p(_1) }

    expect(decided(inner, "git commit -m chore")).to be_nil
  end

  it "has no opinion where the git that would run sits inside the lease" do
    lease = cut(main)
    bin = File.dirname(executable(File.join(lease, "bin"), "git"))

    expect(decided(lease, "git commit -m chore", env: { "PATH" => "#{bin}:/usr/bin" })).to be_nil
  end

  it "has no opinion where the git that would run shadows another" do
    lease = cut(main)
    bin = File.dirname(executable(File.join(@home, "bin"), "git"))

    expect(decided(lease, "git commit -m chore", env: { "PATH" => "#{bin}:/usr/bin" })).to be_nil
    expect(decided(lease, "git commit -m chore", env: { "PATH" => bin })).to have_attributes(verdict: :allow)
  end

  describe "beside a lend to bash children" do
    let(:account) do
      Class.new do
        attr_reader :asks

        define_method(:initialize) { @asks = 0 }
        define_method(:environment) { (@asks += 1) && { "GH_TOKEN" => "lent-token-value" } }
      end.new
    end
    let(:lend) { Lain::Exec::ChildEnv::Lend.new(account) }

    it "approves without asking the lend's source" do
      expect(decided(cut(main), "git commit -m chore", lend:)).to have_attributes(verdict: :allow)
      expect(account.asks).to eq(0)
    end

    it "runs lain's own git asks without the lent token, even once a command has been lent it" do
      lease = cut(main)
      seen = File.join(@base, "seen-token")
      bin = File.join(@home, "bin").tap { FileUtils.mkdir_p(_1) }
      File.write(File.join(bin, "git"), "#!/bin/sh\nprintf '%s' \"$GH_TOKEN\" >> #{seen}\nexec /usr/bin/git \"$@\"\n")
      File.chmod(0o755, File.join(bin, "git"))
      lend.lent

      expect(decided(lease, "git commit -m chore", env: { "PATH" => bin }, lend:)).to have_attributes(verdict: :allow)
      expect(File.read(seen)).to eq("")
    end
  end

  it "never reads again a commit the session's verdict refused" do
    lease = cut(main)
    excluded = Lain::Shell::Verdict.new(capability_set: Lain::Shell::Exclusions.new(patterns: ["git"]))

    expect(excluded.call("git commit -m chore")).to be_deny
    expect(decided(lease, "git commit -m chore", verdict: excluded)).to be_nil
  end

  it "has no opinion where a directory between the cwd and the lease holds a git pointer of its own" do
    lease = cut(main)
    sub = File.join(lease, "sub").tap { FileUtils.mkdir_p(_1) }
    File.write(File.join(sub, ".git"), "gitdir: #{File.join(main, ".git")}\n")

    expect([decided(lease, "git commit -m chore", cwd: sub), decided(lease, "cd sub && git commit -m chore")])
      .to eq([nil, nil])
  end

  it "has no opinion where a directory between the cwd and the lease is a repository of its own" do
    lease = cut(main)
    nested = File.join(lease, "nested", "deeper").tap { FileUtils.mkdir_p(_1) }
    SeedRepo.git(File.dirname(nested), "init", "-q")

    clean = cut(main)

    expect(decided(lease, "git commit -m chore", cwd: nested)).to be_nil
    expect(decided(clean, "git commit -m chore", cwd: File.join(clean, "sub").tap { FileUtils.mkdir_p(_1) }))
      .to have_attributes(verdict: :allow)
  end

  it "has no opinion where the user's git config includes another file" do
    lease = cut(main)
    global = File.join(@home, ".gitconfig")
    xdg = File.join(@home, "xdg", "git", "config").tap { FileUtils.mkdir_p(File.dirname(_1)) }
    included = File.join(@base, "included.gitconfig").tap { File.write(_1, "[core]\n\tquotePath = false\n") }

    File.write(global, "[Include]\n\tpath = #{included}\n")
    by_global = decided(lease, "git commit -m chore")
    File.delete(global)
    File.write(xdg, "[includeIf \"gitdir:/\"]\n\tpath = #{included}\n")
    by_xdg = decided(lease, "git commit -m chore")
    File.delete(xdg)
    named = File.join(@base, "named.gitconfig").tap { File.write(_1, "[include]\n\tpath = #{included}\n") }
    by_named = decided(lease, "git commit -m chore", env: { "GIT_CONFIG_GLOBAL" => named })

    expect([by_global, by_xdg, by_named]).to eq([nil, nil, nil])
  end

  it "has no opinion where the env lends git any variable but where its global config is" do
    lease = cut(main)
    envs = [{ "GIT_INDEX_FILE" => File.join(@base, "index") }, { "GIT_CONFIG_PARAMETERS" => "'core.x=y'" },
            { "GIT_EXEC_PATH" => @base }, { "GIT_CONFIG_COUNT" => "1" }]

    expect(envs.map { decided(lease, "git commit -m chore", env: _1) }).to eq([nil] * envs.size)
    expect(decided(lease, "git commit -m chore", env: { "GIT_CONFIG_NOSYSTEM" => "1" }))
      .to have_attributes(verdict: :allow)
  end

  it "has no opinion where the lease's git dir is a link to a directory" do
    lease = cut(main)
    moved = File.join(@base, "moved-git")
    FileUtils.mv(File.join(lease, ".git"), moved)
    File.symlink(moved, File.join(lease, ".git"))

    expect(decided(lease, "git commit -m chore")).to be_nil
  ensure
    File.unlink(File.join(lease, ".git"))
    FileUtils.mv(moved, File.join(lease, ".git"))
  end

  it "has no opinion where this lineage wrote the file GIT_CONFIG_GLOBAL names" do
    lease = cut(main)
    named = File.join(@base, "named.gitconfig").tap { File.write(_1, "[core]\n\tquotePath = false\n") }

    expect(decided(lease, "git commit -m chore", written: [named], env: { "GIT_CONFIG_GLOBAL" => named })).to be_nil
    expect(decided(lease, "git commit -m chore", env: { "GIT_CONFIG_GLOBAL" => named }))
      .to have_attributes(verdict: :allow)
  end

  it "reads the XDG git config under HOME when XDG_CONFIG_HOME is empty" do
    lease = cut(main)
    xdg = File.join(@home, ".config", "git", "config")
    FileUtils.mkdir_p(File.dirname(xdg))
    File.write(xdg, "[core]\n\tquotePath = false\n")

    expect(decided(lease, "git commit -m chore", written: [xdg], env: { "XDG_CONFIG_HOME" => "" })).to be_nil
  end

  it "has no opinion where the user's git config lies inside the lease" do
    lease = cut(main)
    inside = File.join(lease, "user.gitconfig").tap { File.write(_1, "[core]\n\tquotePath = false\n") }

    expect(decided(lease, "git commit -m chore", env: { "GIT_CONFIG_GLOBAL" => inside })).to be_nil
  end

  describe "the env git gets, the child env applied over what the call is lent" do
    def base_env = { "PATH" => "/usr/bin", "HOME" => @home, "XDG_CONFIG_HOME" => File.join(@home, "xdg") }

    it "allows the git variables a shell exports, which the child env withholds" do
      lease = cut(main)
      exported = %w[GIT_EDITOR GIT_PAGER GIT_SSH_COMMAND GIT_ASKPASS].to_h { [_1, "true"] }

      expect(decided(lease, "git commit -m chore", env: exported, inherited: base_env.merge(exported)))
        .to have_attributes(verdict: :allow)
    end

    it "allows the editorless pair lain lends a leased worker, and only with those values" do
      lease = cut(main)
      editorless = Lain::Isolation::SelfSync::EDITORLESS

      expect(decided(lease, "git commit -m chore", env: editorless, inherited: base_env))
        .to have_attributes(verdict: :allow)
      expect(decided(lease, "git commit -m chore", env: { "GIT_EDITOR" => "vi" }, inherited: base_env)).to be_nil
    end

    it "has no opinion where a git variable survives into the child env" do
      lease = cut(main)
      upstream = { "GIT_DIR" => File.join(main, ".git") }

      expect(decided(lease, "git commit -m chore", env: upstream, inherited: base_env.merge(upstream),
                                                   pass: ["GIT_DIR"])).to be_nil
    end
  end

  it "has no opinion where the user's git config includes a file in a shape a text match misses" do
    lease = cut(main)
    global = File.join(@home, ".gitconfig")
    included = File.join(@base, "included.gitconfig").tap { File.write(_1, "[core]\n\tquotePath = false\n") }
    shapes = ["[core]\n\tquotePath = false\n[core][include]path = #{included}\n",
              "\xEF\xBB\xBF[include]\n\tpath = #{included}\n"]

    expect(shapes.map { File.write(global, _1) && decided(lease, "git commit -m chore") }).to eq([nil, nil])
    File.write(global, "[core]\n\tquotePath = false\n")
    expect(decided(lease, "git commit -m chore")).to have_attributes(verdict: :allow)
  end

  # Each link is put back before the next lease is cut, since cutting one reads every clone beside it.
  it "has no opinion where the lease's HEAD, refs, objects, packed refs or index is a link" do
    answers = %w[HEAD refs refs/heads/main objects packed-refs index].map do |name|
      lease = cut(main)
      path = File.join(lease, ".git", name)
      aside = File.join(@base, "aside-#{name.tr("/", "-")}")
      kept = File.exist?(path) && FileUtils.mv(path, aside)
      File.write(aside, "") unless kept
      File.symlink(aside, path)
      decided(lease, "git commit -m chore").tap do
        File.unlink(path)
        kept ? FileUtils.mv(aside, path) : File.delete(aside)
      end
    end

    expect(answers).to all(be_nil)
  end

  it "has no opinion on a command tool other than bash" do
    lease = cut(main)
    other = Class.new(Lain::Tools::Bash) { def name = "other_shell" }.new(verdict: Lain::Shell::Verdict.new)
    call = Lain::Approval::Rule::Call.for(tool: other, input: { "command" => "git commit -m chore", "cwd" => lease })

    expect(chain(lease).call(call).decision).to be_nil
  end

  it "reads each stage of an add then a commit without a fault" do
    lease = cut(main)
    File.write(File.join(lease, "f"), "f\n")
    outcome = chain(lease).call(call_of("git add f && git commit -m x", cwd: lease))

    expect([outcome.decision&.verdict, outcome.faults]).to eq([:allow, []])
  end

  describe "an add joined to the commit" do
    it "approves adding a file in the lease then committing it, and the file lands" do
      lease = cut(main)
      FileUtils.mkdir_p(File.join(lease, "docs"))
      File.write(File.join(lease, "docs", "new.md"), "doc\n")

      decision = decided(lease, 'git add docs/new.md && git commit -m "add doc"')
      SeedRepo.git(lease, "add", "docs/new.md")
      SeedRepo.git(lease, "commit", "-q", "-m", "add doc")

      expect(decision).to have_attributes(verdict: :allow, rule: "lease_commit")
      expect(SeedRepo.git(lease, "ls-tree", "--name-only", "-r", "HEAD").stdout.lines).to include("docs/new.md\n")
    end

    it "has no opinion on an add of a path outside the lease" do
      lease = cut(main)

      expect(decided(lease, "git add ../other && git commit -m x")).to be_nil
    end

    it "has no opinion on an add of the lease root, which stages the whole clone, but approves a subdirectory" do
      lease = cut(main)
      FileUtils.mkdir_p(File.join(lease, "docs"))
      File.write(File.join(lease, "docs", "new.md"), "doc\n")
      commands = ["git add . && git commit -m x", "git add docs/.. && git commit -m x",
                  "git add #{lease} && git commit -m x", "git add docs . && git commit -m x"]

      expect(commands.map { decided(lease, _1) }).to all(be_nil)
      expect(decided(lease, "git add docs && git add docs/new.md && git commit -m x"))
        .to have_attributes(verdict: :allow)
    end

    it "has no opinion on an add inside the lease's own git dir" do
      lease = cut(main)
      commands = ["git add .git/config && git commit -m x", "git add docs/../.git && git commit -m x"]

      expect(commands.map { decided(lease, _1) }).to all(be_nil)
    end

    it "has no opinion on an add of a directory that holds a repository of its own" do
      lease = cut(main)
      SeedRepo.git(File.join(lease, "vendored-repo").tap { FileUtils.mkdir_p(_1) }, "init", "-q")

      expect(decided(lease, "git add vendored-repo && git commit -m x")).to be_nil
    end

    it "has no opinion on an add with an option, a pathspec magic or a glob" do
      lease = cut(main)
      commands = ["git add -A && git commit -m x", "git add --pathspec-from-file=f && git commit -m x",
                  "git add ':(attr:x)' && git commit -m x", "git add '*' && git commit -m x",
                  "git add && git commit -m x", "git add 'a\\b' && git commit -m x",
                  "git status f && git commit -m x"]

      expect(commands.map { decided(lease, _1) }).to all(be_nil)
    end

    it "has no opinion on stages joined by anything but &&" do
      lease = cut(main)
      File.write(File.join(lease, "f"), "f\n")
      commands = ["git add f; git commit -m x", "git add f || git commit -m x", "git add f | git commit -m x",
                  "git commit -m x && git add f", "git commit -m x && git commit -m y"]

      expect(commands.map { decided(lease, _1) }).to all(be_nil)
    end
  end

  describe "a clone that holds a nested repository" do
    def identity = ["-c", "user.name=p", "-c", "user.email=p@x.invalid"]

    # The review's probe, through the chain: `commit -a` asks a gitlinked repository's own fsmonitor.
    it "has no opinion where a gitlinked repository's own config names a program, which commit -a runs" do
      lease = cut(main)
      sub = File.join(lease, "sub").tap { FileUtils.mkdir_p(_1) }
      SeedRepo.git(sub, "init", "-q", "-b", "main")
      File.write(File.join(sub, "s"), "s\n")
      SeedRepo.git(sub, "add", "s")
      SeedRepo.git(sub, *identity, "commit", "-q", "-m", "s")
      SeedRepo.git(lease, "add", "sub")
      helper = File.join(@base, "fsmonitor").tap { File.write(_1, "#!/bin/sh\ntouch #{@base}/fsmonitor-ran\n") }
      File.chmod(0o755, helper)
      SeedRepo.git(sub, "config", "core.fsmonitor", helper)

      expect(decided(lease, "git commit -a -m x")).to be_nil
    end

    it "has no opinion where the index holds a gitlink with no repository beneath it" do
      lease = cut(main)
      head = SeedRepo.git(lease, "rev-parse", "HEAD").stdout.strip
      SeedRepo.git(lease, "update-index", "--add", "--cacheinfo", "160000,#{head},linked")

      expect(decided(lease, "git commit -a -m x")).to be_nil
    end

    it "has no opinion where an untracked repository sits anywhere below the lease" do
      lease = cut(main)
      SeedRepo.git(File.join(lease, "deep", "er").tap { FileUtils.mkdir_p(_1) }, "init", "-q")

      expect(decided(lease, "git commit -a -m x")).to be_nil
      expect(decided(cut(main), "git commit -a -m x")).to have_attributes(verdict: :allow)
    end
  end

  it "has no opinion where a user git config does not resolve" do
    lease = cut(main)
    File.symlink(File.join(@base, "gone"), File.join(@home, ".gitconfig"))

    expect(decided(lease, "git commit -m chore")).to be_nil
  end

  # The review's shape: a driver the user's config defines, selected by a tracked attribute the chat can write.
  it "has no opinion where the config git reads defines a filter driver" do
    bin = File.join(@base, "bin").tap { FileUtils.mkdir_p(_1) }
    driver = File.join(bin, "fakefilter").tap { File.write(_1, "#!/bin/sh\ntouch #{@base}/marker-filter\ncat\n") }
    File.chmod(0o755, driver)
    lease = cut(main)
    File.write(File.join(lease, ".gitattributes"), "* filter=x\n")
    answers = %w[clean smudge process].map do |kind|
      File.write(File.join(@home, ".gitconfig"), "[filter \"x\"]\n\t#{kind} = fakefilter\n")
      decided(lease, "git commit -a -m x", env: { "PATH" => "#{bin}:/usr/bin" })
    end
    SeedRepo.git(lease, "config", "filter.y.clean", "fakefilter")
    File.delete(File.join(@home, ".gitconfig"))

    expect([*answers, decided(lease, "git commit -a -m x")]).to eq([nil] * 4)
  end

  it "has no opinion where a hook names its interpreter through env" do
    hook(File.join(main, ".git", "hooks"))
    File.write(File.join(main, ".git", "hooks", "pre-commit"), "#!/usr/bin/env sh\ntouch #{@base}/hook-ran\n")

    expect(decided(cut(main), "git commit -m chore")).to be_nil
  end

  it "has no opinion on a message option with no message" do
    expect(decided(cut(main), "git commit -m")).to be_nil
  end
end
