# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "mixlib/shellout"

RSpec.describe Lain::Workspace::Snapshot::Scope::ShadowGit do
  # Two roots, always: the project the scope watches, and the XDG state home the
  # lain-owned repo lives under. An example that reached the real
  # `~/.local/state` would also be an example that git-added the developer's
  # whole home directory, so the injected Paths is not optional here.
  around do |example|
    Dir.mktmpdir("lain-shadow-project") do |project|
      Dir.mktmpdir("lain-shadow-state") do |state|
        @project = File.realpath(project)
        @state = File.realpath(state)
        example.run
      end
    end
  end

  attr_reader :project, :state

  let(:paths) { Lain::Paths.new(env: { "XDG_STATE_HOME" => state, "HOME" => state }) }

  # Primed with the root, which is what {Snapshot#initialize} does for real: the
  # baseline is the project as the session found it, so the FIRST turn is
  # already measured against something.
  def shadow(root: project, **)
    described_class.new(paths:, **).tap { |scope| scope.baseline(root) unless root.nil? }
  end

  def changed(scope, write_set: [], root: project) = scope.paths(write_set:, root:)

  def in_project(*names) = File.join(project, *names)

  # The premise of the whole card: a shell did this, and no lain tool recorded
  # it. Every mutation below goes through here rather than through Ruby's File,
  # so the specs read as the scenarios do.
  def bash(script)
    shell = Mixlib::ShellOut.new("bash", "-c", script,
                                 cwd: project, environment: described_class::GIT_CONTEXT_SCRUB)
    shell.run_command
    raise "bash -c #{script.inspect} failed: #{shell.stderr}" unless shell.exitstatus.zero?
  end

  # The USER's git, run in the user's own repository -- never the shadow one.
  # The identity is pinned so a machine without a global git identity can still
  # commit, and the git context is scrubbed so a run under a git hook (which
  # exports GIT_DIR and GIT_INDEX_FILE) builds the fixture in the tmpdir it
  # names rather than in this repository.
  def attempt_git(*argv)
    Mixlib::ShellOut.new("git", "-c", "user.email=spec@lain.test", "-c", "user.name=lain spec", *argv,
                         cwd: project, environment: described_class::GIT_CONTEXT_SCRUB).tap(&:run_command)
  end

  def git(*argv)
    attempt_git(*argv).tap do |shell|
      raise "git #{argv.join(" ")} failed: #{shell.stderr}" unless shell.exitstatus.zero?
    end
  end

  # Process-wide, and restored afterwards: mixlib merges its `environment:` onto
  # the PARENT's env, so the scrub can only be exercised by a parent that really
  # carries a hook's variables. This is the shape `pre-commit` hands any process
  # it launches, this repository included.
  def under_a_git_hook
    polluted = { "GIT_DIR" => in_project(".git"), "GIT_INDEX_FILE" => in_project(".git", "index"),
                 "GIT_WORK_TREE" => project, "GIT_OBJECT_DIRECTORY" => in_project(".git", "objects") }
    original = ENV.to_h.slice(*polluted.keys)
    ENV.update(polluted)
    yield
  ensure
    polluted.each_key { |key| ENV.delete(key) }
    ENV.update(original)
  end

  # A git whose named subcommand exits nonzero with a real-looking message,
  # every other invocation succeeding, so an example can aim the failure at the
  # invocation it is about.
  def stub_git(fail_on:, stderr: "fatal: unable to read tree")
    lambda do |*argv, **|
      failed = argv.include?(fail_on)
      instance_double(Mixlib::ShellOut, run_command: nil, stdout: "",
                                        exitstatus: failed ? 128 : 0, stderr: failed ? stderr : "")
    end
  end

  describe "detecting what no tool recorded" do
    it "sees a file a shell command created" do
      scope = shadow
      bash("echo made-by-bash > loose.txt")

      expect(changed(scope)).to contain_exactly(in_project("loose.txt"))
    end

    it "sees a file a shell command deleted" do
      File.binwrite(in_project("doomed.txt"), "here for now\n")
      scope = shadow
      bash("rm doomed.txt")

      expect(changed(scope)).to contain_exactly(in_project("doomed.txt"))
    end

    # Rename detection would report only the destination, silently dropping the
    # path that vanished -- exactly the deletion a restore has to know about.
    it "sees both ends of a move as changed" do
      File.binwrite(in_project("before.txt"), "content\n")
      scope = shadow
      bash("mv before.txt after.txt")

      expect(changed(scope)).to contain_exactly(in_project("before.txt"), in_project("after.txt"))
    end

    it "sees a file a shell command edited in place" do
      File.binwrite(in_project("edited.txt"), "first\n")
      scope = shadow
      bash("echo second > edited.txt")

      expect(changed(scope)).to contain_exactly(in_project("edited.txt"))
    end

    it "hands back absolute paths, so the snapshot writer can read them" do
      scope = shadow
      bash("mkdir -p nested && echo deep > nested/file.txt")

      expect(changed(scope)).to all(start_with("#{project}/"))
    end

    it "measures each turn against the previous one, not against the session start" do
      scope = shadow
      bash("echo one > first.txt")
      changed(scope)
      bash("echo two > second.txt")

      expect(changed(scope)).to contain_exactly(in_project("second.txt"))
    end
  end

  describe "the write-set the structured tools recorded" do
    # The swap from WriteSet to ShadowGit must never capture LESS: a posture
    # that buys its safety from reversibility cannot lose a path by widening.
    it "unions the write-set in, so a gitignored recorded path is still captured" do
      File.binwrite(in_project(".gitignore"), "artifacts/\n")
      scope = shadow
      recorded = in_project("artifacts", "report.txt")
      FileUtils.mkdir_p(File.dirname(recorded))
      File.binwrite(recorded, "written by write_file\n")

      expect(changed(scope, write_set: [recorded])).to include(recorded)
    end

    it "reports a path once when both halves name it" do
      scope = shadow
      bash("echo both > shared.txt")

      expect(changed(scope, write_set: [in_project("shared.txt")])).to eq([in_project("shared.txt")])
    end
  end

  describe "the project's own .gitignore" do
    it "does not capture what a shell command wrote into an ignored directory" do
      File.binwrite(in_project(".gitignore"), "build/\n")
      scope = shadow
      bash("mkdir -p build && echo object > build/thing.o && echo kept > src.txt")

      expect(changed(scope)).to contain_exactly(in_project("src.txt"))
    end
  end

  describe "a turn that changed nothing" do
    it "yields an empty set" do
      File.binwrite(in_project("read-only.txt"), "nobody writes me\n")
      scope = shadow
      File.binread(in_project("read-only.txt"))

      expect(changed(scope)).to be_empty
    end

    # UNPRIMED on purpose, here and below: the writer's own baseline call is
    # what has to cover turn 1.
    it "writes no snapshot, through the real writer" do
      events = []
      writer = Lain::Workspace::Snapshot.new(observer: ->(event) { events << event },
                                             root: project, scope: described_class.new(paths:))
      timeline = Lain::Timeline.empty(store: Lain::Store.new)
                               .commit(role: :user, content: [{ "type" => "text", "text" => "go" }])

      expect(writer.write(timeline:, paths: [])).to be_nil
      expect(events).to be_empty
    end

    it "snapshots what bash did, through the real writer" do
      events = []
      writer = Lain::Workspace::Snapshot.new(observer: ->(event) { events << event },
                                             root: project, scope: described_class.new(paths:))
      timeline = Lain::Timeline.empty(store: Lain::Store.new)
                               .commit(role: :user, content: [{ "type" => "text", "text" => "go" }])
      bash("echo unrecorded > sneaky.txt")

      event = writer.write(timeline:, paths: [])

      expect(event.body.fetch("files").keys).to eq(["sneaky.txt"])
      expect(event.body.fetch("snapshot_scope")).to eq(described_class::NOTE)
    end
  end

  describe "a project that is not a git repository" do
    it "still detects changes, against the lain-owned store" do
      scope = shadow
      bash("echo no repo here > plain.txt")

      expect(changed(scope)).to contain_exactly(in_project("plain.txt"))
    end

    it "never creates a repository in the project" do
      scope = shadow
      bash("echo a > a.txt")
      changed(scope)

      expect(Dir.children(project)).to contain_exactly("a.txt")
      expect(Dir.children(File.join(state, "lain", "workspace")).length).to eq(1)
    end
  end

  # The scenario a bug in makes lain destroy a real user's work. Asserted three
  # ways, because "no new object" and "the porcelain still reads the same" fail
  # independently: a stray write into their object store leaves status alone,
  # and a refreshed or rewritten index leaves the object store alone.
  describe "the user's own repository" do
    def objects = Dir.glob("**/*", base: in_project(".git", "objects")).sort

    def index_bytes = File.binread(in_project(".git", "index"))

    # A repository with a commit behind it, one staged change, one unstaged
    # change, and an untracked file -- every kind of pending state a status
    # comparison could lose. The final status warms the index, so a later
    # identical status has nothing to refresh and rewrites nothing.
    def repository_with_pending_work
      git("init", "--quiet", "-b", "main")
      File.binwrite(in_project("tracked.txt"), "one\n")
      File.binwrite(in_project("staged.txt"), "staged\n")
      git("add", ".")
      git("commit", "--quiet", "-m", "first")
      File.binwrite(in_project("tracked.txt"), "unstaged edit\n")
      File.binwrite(in_project("staged.txt"), "restaged\n")
      git("add", "staged.txt")
      File.binwrite(in_project("untracked.txt"), "loose\n")
      git("status", "--porcelain").stdout
    end

    it "is untouched by turns that changed nothing" do
      before_status = repository_with_pending_work
      before_objects = objects
      before_index = index_bytes
      scope = shadow

      3.times { changed(scope) }

      expect(objects).to eq(before_objects)
      expect(index_bytes).to eq(before_index)
      expect(git("status", "--porcelain").stdout).to eq(before_status)
    end

    it "keeps its staged and unstaged state while the agent writes" do
      before_status = repository_with_pending_work
      before_objects = objects
      before_index = index_bytes
      scope = shadow

      3.times do |turn|
        bash("echo turn#{turn} > agent#{turn}.txt")
        changed(scope)
      end

      expect(objects).to eq(before_objects)
      expect(index_bytes).to eq(before_index)
      expect(git("status", "--porcelain").stdout.lines).to include(*before_status.lines)
    end

    # The reason every invocation scrubs before it sets its own context: a lain
    # launched from a git hook inherits GIT_DIR and GIT_INDEX_FILE aimed at the
    # repository being hooked, and an unscrubbed `add --all` would stage the
    # agent's work straight into THEIR index.
    it "is untouched when the inherited environment points git straight at it" do
      before_status = repository_with_pending_work
      before_objects = objects
      before_index = index_bytes

      under_a_git_hook do
        scope = shadow
        bash("echo hook-time > agent.txt")

        expect(changed(scope)).to contain_exactly(in_project("agent.txt"))
      end

      expect(objects).to eq(before_objects)
      expect(index_bytes).to eq(before_index)
      expect(git("status", "--porcelain").stdout.lines).to include(*before_status.lines)
    end

    # `-c` overrides an invoking git passes down transiently, which is the same
    # inheritance class as GIT_DIR and can rewrite core.worktree, core.bare or
    # the exclude file under us. Their persistent siblings GIT_CONFIG_GLOBAL and
    # GIT_CONFIG_SYSTEM are deliberately left alone: honouring the user's real
    # global config is what makes their own core.excludesFile apply.
    it "ignores config an invoking git passed down as -c overrides" do
      hostile = File.join(state, "exclude-everything")
      File.binwrite(hostile, "*\n")
      polluted = { "GIT_CONFIG_COUNT" => "1", "GIT_CONFIG_KEY_0" => "core.excludesFile",
                   "GIT_CONFIG_VALUE_0" => hostile }
      original = ENV.to_h.slice(*polluted.keys)
      ENV.update(polluted)
      scope = shadow
      bash("echo still seen > seen.txt")

      expect(changed(scope)).to contain_exactly(in_project("seen.txt"))
    ensure
      polluted.each_key { |key| ENV.delete(key) }
      ENV.update(original)
    end

    it "leaves an in-progress rebase in progress" do
      git("init", "--quiet", "-b", "main")
      File.binwrite(in_project("conflicted.txt"), "base\n")
      git("add", ".")
      git("commit", "--quiet", "-m", "base")
      git("checkout", "--quiet", "-b", "topic")
      File.binwrite(in_project("conflicted.txt"), "topic\n")
      git("commit", "--quiet", "-am", "topic")
      git("checkout", "--quiet", "main")
      File.binwrite(in_project("conflicted.txt"), "main\n")
      git("commit", "--quiet", "-am", "main")
      git("checkout", "--quiet", "topic")
      attempt_git("rebase", "main")
      rebase_state = Dir.glob("rebase-*/**/*", base: in_project(".git")).sort
      before_objects = objects
      before_status = git("status", "--porcelain").stdout
      scope = shadow

      3.times do |turn|
        bash("echo turn#{turn} > agent#{turn}.txt")
        changed(scope)
      end

      expect(rebase_state).not_to be_empty
      expect(Dir.glob("rebase-*/**/*", base: in_project(".git")).sort).to eq(rebase_state)
      expect(objects).to eq(before_objects)
      expect(git("status", "--porcelain").stdout.lines).to include(*before_status.lines)
    end
  end

  # Git's stat cache trusts size and timestamps. A rewrite inside the same
  # second at the SAME size is the case that would slip past it, and the file
  # this leaves unsnapshotted is a file undo silently cannot restore -- so the
  # content compare that catches it is pinned here rather than assumed.
  describe "a rewrite within the same second at the same size" do
    it "is still detected" do
      path = in_project("racy.txt")
      File.binwrite(path, "AAAA")
      scope = shadow
      File.binwrite(path, "BBBB")

      expect(changed(scope)).to contain_exactly(path)
      expect(File.stat(path).size).to eq(4)

      File.binwrite(path, "CCCC")

      expect(changed(scope)).to contain_exactly(path)
    end
  end

  # Every one of these four exits raises rather than degrading to "nothing
  # changed" -- the silence that would leave a turn unsnapshotted and undo
  # unable to restore it.
  describe "when git does not deliver an answer" do
    it "raises a Lain::Error naming git's stderr, rather than reporting no changes" do
      scope = shadow(root: nil, shell_out_factory: stub_git(fail_on: "add", stderr: "fatal: index file corrupt"))

      expect { changed(scope) }
        .to raise_error(Lain::Error, /shadow git add failed \(exit 128\): fatal: index file corrupt/)
    end

    it "raises when the store itself cannot be created" do
      expect { shadow(shell_out_factory: stub_git(fail_on: "init", stderr: "fatal: cannot mkdir")) }
        .to raise_error(Lain::Error, /shadow git init failed \(exit 128\): fatal: cannot mkdir/)
    end

    # Mixlib reports a NIL exit status for a child killed by a signal, and the
    # OOM killer reaping `add --all` on a large tree is the realistic way to get
    # one. `nil.zero?` would be a NoMethodError in place of the refusal.
    it "names a signal death rather than raising NoMethodError on a nil exit" do
      # An empty stderr on purpose: a SIGKILLed git says nothing, so the
      # message has to carry the signal itself or it carries nothing at all.
      killed = lambda do |*argv, **|
        instance_double(Mixlib::ShellOut, run_command: nil, stdout: "", stderr: "",
                                          exitstatus: argv.include?("add") ? nil : 0)
      end
      scope = shadow(root: nil, shell_out_factory: killed)

      expect { changed(scope) }.to raise_error(Lain::Error, /shadow git add failed \(killed by signal\)/)
    end

    it "raises when git is not on PATH at all" do
      absent = ->(*, **) { raise Errno::ENOENT, "No such file or directory - git" }

      expect { shadow(shell_out_factory: absent) }
        .to raise_error(Lain::Error, /shadow git init failed \(Errno::ENOENT\).*No such file or directory/)
    end

    it "raises when git outruns mixlib's timeout" do
      slow = ->(*, **) { raise Mixlib::ShellOut::CommandTimeout, "command timed out after 600s" }

      expect { shadow(shell_out_factory: slow) }
        .to raise_error(Lain::Error, /shadow git init failed \(Mixlib::ShellOut::CommandTimeout\).*600s/)
    end

    # Paths::Unwritable is the refusal Paths raises for every other XDG
    # directory it creates, so an unwritable state home reads the same here as
    # it does for a session file.
    it "raises Paths::Unwritable when the state home cannot be created" do
      unwritable = File.join(state, "sealed")
      FileUtils.mkdir_p(unwritable)
      FileUtils.chmod(0o500, unwritable)
      sealed = Lain::Paths.new(env: { "XDG_STATE_HOME" => File.join(unwritable, "state"), "HOME" => state })

      expect { described_class.new(paths: sealed).baseline(project) }
        .to raise_error(Lain::Paths::Unwritable, /cannot create/)
    ensure
      FileUtils.chmod(0o700, unwritable)
    end
  end

  describe "the scope duck" do
    it "declares itself in the payload, and not as the write-set scope does" do
      expect(shadow.note).to eq(described_class::NOTE)
      expect(shadow.note).not_to eq(Lain::Workspace::Snapshot::Scope::WriteSet::NOTE)
    end

    it "names itself for journals and bench arms" do
      expect(shadow.label).to eq("shadow_git")
    end

    # Registered under a short name, and INERT until it is primed, so resolving
    # the name touches no filesystem and shells no git.
    it "resolves from its short name without touching a repository" do
      expect(Lain::Workspace::Snapshot::Scope.resolve(:shadow_git)).to be_a(described_class)
      expect(described_class.new(paths:)).to be_a(described_class)
      expect(Dir.children(state)).to be_empty
    end

    it "takes its baseline on the first turn when nobody primed it" do
      scope = described_class.new(paths:)
      bash("echo before the baseline > early.txt")

      expect(changed(scope)).to be_empty

      bash("echo after the baseline > late.txt")

      expect(changed(scope)).to contain_exactly(in_project("late.txt"))
    end

    it "primes idempotently, so a second call moves the baseline forward and no further" do
      scope = shadow
      bash("echo one > first.txt")
      scope.baseline(project)

      expect(changed(scope)).to be_empty
    end

    # There is no constructor root to disagree with a per-call one: the baseline
    # is keyed by root, so two roots hold two baselines and neither is silently
    # measured against the other.
    it "keeps a baseline per root" do
      Dir.mktmpdir("lain-shadow-other") do |other|
        scope = shadow
        scope.baseline(other)
        File.binwrite(File.join(other, "elsewhere.txt"), "written\n")
        bash("echo here > here.txt")

        expect(scope.paths(write_set: [], root: other)).to contain_exactly(File.join(other, "elsewhere.txt"))
        expect(changed(scope)).to contain_exactly(in_project("here.txt"))
      end
    end
  end

  # FIX 5's whole point: a posture may hand the scope through as an inert
  # Symbol, and the writer's priming still covers turn 1. Scope.fetch takes a
  # name and nothing else, so without the prime this path could never see a
  # first-turn change at all.
  describe "named by symbol, end to end through the writer" do
    around do |example|
      original = ENV.to_h.slice("XDG_STATE_HOME")
      ENV["XDG_STATE_HOME"] = state
      example.run
    ensure
      ENV.delete("XDG_STATE_HOME")
      ENV.update(original)
    end

    it "covers the first turn of a session" do
      events = []
      writer = Lain::Workspace::Snapshot.new(observer: ->(event) { events << event },
                                             root: project, scope: :shadow_git)
      timeline = Lain::Timeline.empty(store: Lain::Store.new)
                               .commit(role: :user, content: [{ "type" => "text", "text" => "go" }])
      bash("echo first turn > turn-one.txt")

      event = writer.write(timeline:, paths: [])

      expect(event.body.fetch("files").keys).to eq(["turn-one.txt"])
      expect(event.body.fetch("snapshot_scope")).to eq(described_class::NOTE)
    end
  end
end
