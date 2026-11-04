# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Lain::Approval::Judgement do
  around do |example|
    Dir.mktmpdir("lain-judgement") do |dir|
      @base = File.realpath(dir)
      example.run
    end
  end

  let(:home) { File.join(@base, "home") }
  let(:root) { File.join(home, "project") }
  let(:policy) do
    Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: root, root:), home:, root:)
  end
  let(:context) { Data.define(:worker_env).new(worker_env: Lain::WorkerEnv.new(cwd: root, env: {})) }
  let(:mask_list) { Lain::Confine::MaskList.new(root:, policy: -> { policy }) }
  let(:masking) { described_class::Masking.new(mask_list) }

  before do
    FileUtils.mkdir_p(home)
    FileUtils.cp_r("#{SeedRepo.at({ "README" => "seed\n" })}/.", root)
    FileUtils.mkdir_p([File.join(root, "src"), File.join(root, ".lain-views")])
    File.write(File.join(root, "src", "a.rb"), "1\n")
    File.write(File.join(root, ".lain-views", "x.md"), "Given a view\n")
  end

  def bash(command) = Lain::Effect::ToolCall.new(tool_use_id: "tu_1", name: "bash", input: { "command" => command })

  def judged(command, masks: described_class::Unmasked, facts: -> { Lain::Approval::Judge::Facts::NONE }, at: root,
             env: {})
    effect = bash(command)
    within = Data.define(:worker_env).new(worker_env: Lain::WorkerEnv.new(cwd: at, env:))
    described_class.of(effect, bounds: Lain::Sensitivity::Policy.confined_at(policy, within),
                               named: Lain::Shell::Named.for_call(effect, within, home:), facts:, masks:,
                               env: within.worker_env.env,
                               verdict: ->(path) { policy.judge(path, cwd: at) })
  end

  def reasons(commands, **)
    commands.to_h { [_1, judged(_1, **).then { |judgement| judgement.respond_to?(:reason) && judgement.reason }] }
  end

  def repo(dir, *files)
    FileUtils.mkdir_p(dir)
    FileUtils.cp_r("#{SeedRepo.at({ "README" => "seed\n" })}/.", dir)
    files.each { File.write(File.join(dir, _1), "x\n") }
    dir
  end

  describe "a git read of the project's own history under the workspace masks" do
    it "is weighed, and the judge is told the history is masked" do
      judgement = judged("git status && git log && git branch -a", masks: masking)

      expect(judgement).to be_a(described_class::Weighable)
      expect(judgement.facts.to_s).to include(Lain::Approval::Judge::Facts::HISTORY)
    end

    it "is weighed for a diff between 2 commits, every ref and reflog, and a stash that names no object" do
      commands = ["git diff HEAD~1..HEAD -- crates/store", "git log -p --all", "git log -p -g",
                  "git log -p --all --reflog", "git stash show -p", "git stash list -p", "git show --stat"]

      expect(reasons(commands, masks: masking)).to eq(commands.to_h { [_1, false] })
    end

    it "is weighed in a detached worktree of the project, whose objects are the project's" do
      worktree = File.join(@base, "wt")
      SeedRepo.git(root, "worktree", "add", "-q", "--detach", worktree)

      expect(reasons(["git -C #{worktree} log -p", "git log -p"], masks: masking, at: worktree).values)
        .to eq([false, false])
    end

    it "names the git store when nothing masks the output" do
      expect(judged("git log")).to eq(described_class::Unweighable.new(reason: :git_store))
    end
  end

  describe "a git read the history mask does not cover" do
    it "walks a read of the working tree, which prints a tracked secret deeper than the mask lists" do
      deep = File.join(root, "vendor", "pkg", ".env")
      FileUtils.mkdir_p(File.dirname(deep))
      File.write(deep, "APP_COLOUR=committed\n")
      SeedRepo.git(root, "add", "-f", deep)
      SeedRepo.git(root, "commit", "-q", "-m", "deep env")
      File.write(deep, "APP_COLOUR=edited\n")
      commands = ["git diff", "git grep -n APP_COLOUR", "git diff HEAD~1 -- crates/store", "git diff --cached",
                  "git blame README", "git grep -n APP_COLOUR HEAD", "git status -v && git log",
                  "git log -p | git apply"]

      expect(reasons(commands, masks: masking).values).to all(be_a(Symbol))
    end

    it "walks a read whose environment could point git at another repository" do
      expect(judged("git log -p", masks: masking, env: { "GIT_DIR" => File.join(@base, "other", ".git") }).reason)
        .to eq(:git_store)
      config = { "GIT_CONFIG_COUNT" => "1", "GIT_CONFIG_KEY_0" => "core.worktree", "GIT_CONFIG_VALUE_0" => "/etc" }
      expect(judged("git log -p", masks: masking, env: config).reason).to eq(:git_store)
      expect(judged("git log -p", masks: masking, env: { "GIT_TRACE_SETUP" => "1" }).reason).to eq(:git_store)
    end

    it "still weighs a read whose environment names only an editor, a pager, an identity or the config pair" do
      harmless = { "GIT_EDITOR" => "true", "GIT_PAGER" => "cat", "GIT_AUTHOR_NAME" => "x", "GIT_OPTIONAL_LOCKS" => "0",
                   "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1" }

      expect(judged("git log -p", masks: masking, env: harmless)).to be_a(described_class::Weighable)
    end

    it "walks a branch, tag or reflog that writes, and weighs one that only lists" do
      writes = ["git branch -D x", "git tag -d x", "git reflog expire --all --expire=now",
                "git branch --edit-description", "git branch topic", "git tag v1", "git reflog delete HEAD@{1}"]
      lists = ["git branch -a", "git branch --list", "git tag -l", "git tag", "git reflog", "git reflog show",
               "git branch -a && git log -p"]

      expect(reasons(writes, masks: masking).values).to all(be_a(Symbol))
      expect(reasons(lists, masks: masking)).to eq(lists.to_h { [_1, false] })
    end

    describe "a git config the call would read" do
      def config(body) = File.join(@base, "gitconfig").tap { File.write(_1, body) }

      def under(file) = { "GIT_CONFIG_GLOBAL" => file, "GIT_CONFIG_NOSYSTEM" => "1" }

      it "walks a read when a diff driver could print a file no mask covers" do
        drivers = ["[diff \"leak\"]\n\ttextconv = cat\n", "[diff \"leak\"]\n\tcommand = cat\n",
                   "[diff]\n\texternal = cat\n"]

        expect(drivers.map { judged("git log -p", masks: masking, env: under(config(_1))).reason })
          .to all(eq(:git_store))
      end

      it "walks a read when git cannot read the config, which might name one" do
        expect(judged("git log -p", masks: masking, env: under(config("[diff \"leak\"\n"))).reason).to eq(:git_store)
      end

      it "walks a read when git cannot even be started to ask" do
        expect(with_env("PATH" => File.join(@base, "no-git")) { judged("git log -p", masks: masking).reason })
          .to eq(:git_store)
      end

      it "weighs a read when the config names no diff driver" do
        expect(judged("git log -p", masks: masking, env: under(config("[core]\n\tpager = cat\n"))))
          .to be_a(described_class::Weighable)
      end
    end

    it "walks a nested repository, a submodule and a repository outside the project" do
      repo(File.join(root, "lib", "pkg"), "x")
      repo(File.join(@base, "other"), "x")
      FileUtils.mkdir_p([File.join(root, "sub"), File.join(root, ".git", "modules", "sub", "objects")])
      File.write(File.join(root, "sub", ".git"), "gitdir: ../.git/modules/sub\n")
      commands = ["git -C lib/pkg log -p", "cd lib/pkg && git log -p", "git -C #{@base}/other log -p",
                  "cd #{@base}/other && git log -p", "git -C sub log -p"]

      expect(reasons(commands, masks: masking)).to eq(commands.to_h { [_1, :git_store] })
    end

    it "walks a read that names an object, a FETCH_HEAD, or reads objects the refs may not reach" do
      commands = ["git show 5ee71863", "git stash show -p feedb37a08e21bc72da45180c231af79a1237341",
                  "git log -p FETCH_HEAD", "git cat-file -p HEAD", "git fsck --unreachable --no-reflogs",
                  "git grep --no-index needle", "git log -p --stdin", "git --git-dir=.git log -p"]

      expect(reasons(commands, masks: masking).values).to all(be_a(Symbol))
    end

    it "walks a git write, which the history mask was never about" do
      commands = ["git add -A", "git stash", "git checkout -- ."]

      expect(reasons(commands, masks: masking).values).to all(be_a(Symbol))
    end
  end

  it "weighs a grep run from a directory the command changes into" do
    expect(judged("cd .lain-views && grep -c Given x.md")).to be_a(described_class::Weighable)
  end

  describe "a recursive grep over a tree holding a secret" do
    let(:tree) { File.join(root, "tree") }

    before do
      FileUtils.mkdir_p(tree)
      File.write(File.join(tree, "a.rb"), "1\n")
    end

    it "weighs it when the session's mask list hides the secret, and its facts say so" do
      File.write(File.join(tree, ".env"), "TOKEN=1\n")

      judgement = judged("grep -rn needle tree", masks: masking)

      expect(judgement).to be_a(described_class::Weighable)
      expect(judgement.facts.to_s)
        .to include(format(Lain::Approval::Judge::Facts::MASKED, paths: File.join(tree, ".env")))
    end

    it "does not weigh it when the call runs unconfined" do
      File.write(File.join(tree, ".env"), "TOKEN=1\n")

      expect(judged("grep -rn needle tree")).to eq(
        described_class::Unweighable.new(reason: :protected_target, details: [File.join(tree, ".env")])
      )
    end

    it "does not weigh a secret deeper than the mask lists" do
      deep = File.join(tree, "vendor", "pkg", ".env")
      FileUtils.mkdir_p(File.dirname(deep))
      File.write(deep, "TOKEN=1\n")

      expect(judged("grep -rn needle tree", masks: masking))
        .to eq(described_class::Unweighable.new(reason: :protected_target, details: [deep]))
    end

    it "weighs a secret at the top level of a pruned directory, which the mask still lists" do
      FileUtils.mkdir_p(File.join(tree, "vendor"))
      File.write(File.join(tree, "vendor", ".env"), "TOKEN=1\n")

      expect(judged("grep -rn needle tree", masks: masking)).to be_a(described_class::Weighable)
    end

    it "does not weigh a secret reached through a link out of the project, which no listing names" do
      elsewhere = File.join(@base, "elsewhere")
      FileUtils.mkdir_p(elsewhere)
      File.write(File.join(elsewhere, ".env"), "TOKEN=1\n")
      File.symlink(elsewhere, File.join(tree, "out"))

      expect(judged("grep -Rn needle tree", masks: masking).reason).to eq(:protected_target)
    end

    it "does not weigh it when the mask list's listing failed, so it masks nothing" do
      File.write(File.join(tree, ".env"), "TOKEN=1\n")
      failing = Lain::Confine::MaskList.new(root:, policy: -> { policy }, shell_out: ->(*, **) { raise Errno::ENOENT })

      expect(judged("grep -rn needle tree", masks: described_class::Masking.new(failing)).reason)
        .to eq(:protected_target)
    end

    # The sandbox hides the file on disk, never the index or an object a rev-path reads.
    it "does not weigh a git rev-path to a secret, though the mask hides the file on disk" do
      File.write(File.join(root, ".env"), "TOKEN=1\n")
      SeedRepo.git(root, "add", "-f", ".env")

      expect(reasons(["git show :.env", "git show :0:.env", "git show HEAD:.env"], masks: masking).values)
        .to all(be_a(Symbol))
    end

    it "does not weigh a secret it names outright, though the mask hides it" do
      File.write(File.join(tree, ".env"), "TOKEN=1\n")

      expect(judged("grep -n needle tree/.env", masks: masking).reason).to eq(:protected_target)
    end
  end

  it "does not weigh a grep over a secret in a project that is not a repository, which the mask cannot list" do
    plain = File.join(@base, "plain")
    FileUtils.mkdir_p(File.join(plain, "tree"))
    File.write(File.join(plain, "tree", ".env"), "TOKEN=1\n")
    unlisted = Lain::Sensitivity::Policy.new(sensitivity: Lain::Sensitivity.new(home:, cwd: plain, root: plain),
                                             home:, root: plain)
    within = Data.define(:worker_env).new(worker_env: Lain::WorkerEnv.new(cwd: plain, env: {}))
    effect = bash("grep -rn needle tree")

    judgement = described_class.of(
      effect, bounds: Lain::Sensitivity::Policy.confined_at(unlisted, within),
              named: Lain::Shell::Named.for_call(effect, within, home:),
              facts: -> { Lain::Approval::Judge::Facts::NONE },
              masks: described_class::Masking.new(Lain::Confine::MaskList.new(root: plain, policy: -> { unlisted })),
              verdict: ->(path) { unlisted.judge(path, cwd: plain) }
    )

    expect(judgement.reason).to eq(:protected_target)
  end

  it "does not weigh a walk past its bound, and asks for no facts" do
    wide = File.join(root, "wide")
    FileUtils.mkdir_p(wide)
    (Lain::Approval::Judged::Reach::ENTRIES + 1).times { File.write(File.join(wide, "f#{_1}"), "") }

    expect(judged("grep -rn needle wide", masks: masking, facts: -> { raise "asked for facts" }))
      .to eq(described_class::Unweighable.new(reason: :too_many))
  end

  it "does not weigh a call whose resolved stages bar an automatic approval, naming each reason" do
    facts = Lain::Approval::Judge::Facts.new([Lain::Shell::Executable.unresolved("make test")])

    expect(judged("make test", facts: -> { facts }))
      .to eq(described_class::Unweighable.new(reason: :barred, details: facts.bar))
  end

  it "does not weigh a command whose paths cannot be named, and asks for no facts" do
    expect(judged("eval \"$x\"", facts: -> { raise "asked for facts" }))
      .to eq(described_class::Unweighable.new(reason: :opaque))
  end

  it "refuses a reason outside its enumerated set" do
    expect { described_class::Unweighable.new(reason: :tired) }.to raise_error(ArgumentError, /tired/)
  end

  it "is shareable across ractors either way" do
    expect([judged("cat src/a.rb"), judged("eval \"$x\"")]).to all(satisfy { Ractor.shareable?(_1) })
  end
end
