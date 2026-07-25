# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "mixlib/shellout"

# Operates on a THROWAWAY repo it creates itself (git init in a mktmpdir), never
# the lain repo it runs in -- the same posture worktree_spec.rb takes, and the
# reason this stays in the default suite: git is always present, docker is not.
RSpec.describe Lain::Isolation::Worktree::Handback do
  around do |example|
    Dir.mktmpdir("lain-repo") do |repo|
      Dir.mktmpdir("lain-worktrees") do |worktrees|
        @repo_root = File.realpath(repo)
        @root = File.realpath(worktrees)
        init_repo(@repo_root)
        example.run
      end
    end
  end

  subject(:handback) { described_class.new(repo_root: @repo_root, journal:) }

  let(:journal) { [] }
  let(:backend) { Lain::Isolation::Worktree.new(repo_root: @repo_root, root: @root) }

  def init_repo(dir)
    run_git(dir, "init", "-q")
    run_git(dir, "config", "user.email", "test@example.com")
    run_git(dir, "config", "user.name", "Test")
    File.write(File.join(dir, "README"), "seed\n")
    run_git(dir, "add", "README")
    run_git(dir, "commit", "-q", "-m", "seed")
  end

  # The spec's OWN git calls scrub the git-context env too, so building and
  # inspecting the throwaway repo is hermetic under an ambient GIT_*-polluted
  # env (a pre-commit hook) exactly as the subject is -- reusing the pinned
  # scrub set rather than a parallel copy.
  def run_git(dir, *args)
    shell = Mixlib::ShellOut.new("git", "-C", dir, *args,
                                 environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
    shell.run_command.error!
    shell.stdout
  end

  def try_git(dir, *args)
    shell = Mixlib::ShellOut.new("git", "-C", dir, *args,
                                 environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
    shell.run_command
    shell
  end

  def commit_in(dir, contents, message, file: "README")
    File.write(File.join(dir, file), contents)
    run_git(dir, "add", file)
    run_git(dir, "commit", "-q", "-m", message)
    head_commit(dir)
  end

  # Fails ONE git subcommand without running it, so a failure git will not
  # produce on demand (a broken `commit`, a broken `merge --abort`) still gets
  # pinned. Everything else runs for real.
  def factory_failing(subcommand)
    real = Mixlib::ShellOut.public_method(:new)
    broken = Struct.new(:stdout, :stderr, :exitstatus) do
      def run_command = self
    end
    lambda do |*args, **kwargs|
      args.include?(subcommand) ? broken.new("", "forced failure", 1) : real.call(*args, **kwargs)
    end
  end

  def head_commit(dir) = run_git(dir, "rev-parse", "HEAD").strip

  def registered_worktrees = run_git(@repo_root, "worktree", "list", "--porcelain")

  def head_refs = run_git(@repo_root, "for-each-ref", "--format=%(refname)", "refs/heads").split("\n")

  def reachable_from_head?(commit)
    try_git(@repo_root, "merge-base", "--is-ancestor", commit, "HEAD").exitstatus.zero?
  end

  def ref_target(ref) = try_git(@repo_root, "rev-parse", "--verify", "--quiet", ref)

  def worker_refs = run_git(@repo_root, "for-each-ref", "--format=%(refname)", "refs/lain").split("\n")

  def merging? = File.exist?(File.join(@repo_root, ".git", "MERGE_HEAD"))

  describe "a worker's commit is preserved as a ref" do
    it "makes the commit reachable from a lain worker ref outside refs/heads" do
      lease = backend.acquire("worker-1")
      commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      outcome = handback.call(lease, worker_id: "worker-1")

      expect(outcome.ref).to start_with("refs/lain/worker/worker-1-")
      expect(ref_target(outcome.ref).stdout.strip).to eq(commit)
      expect(head_refs).not_to include(a_string_including("worker-1"))
    ensure
      lease&.release
    end

    # The ref lives outside refs/heads/ precisely so this cannot happen. A
    # DECLINED handback is the case that proves it: the commit is anchored and
    # the parent never moved, so a successor that saw it could only have seen it
    # through a leaked branch.
    it "leaves no branch a later acquire could check out (the crash-restart invariant)" do
      lease = backend.acquire("worker-1")
      worker_commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")
      File.write(File.join(@repo_root, "README"), "uncommitted parent edit\n")
      expect(handback.call(lease, worker_id: "worker-1").kind).to eq(:declined)
      lease.release

      successor = backend.acquire("worker-1")

      expect(head_refs).to eq(["refs/heads/#{run_git(@repo_root, "branch", "--show-current").strip}"])
      expect(head_commit(successor.worker_env.cwd)).not_to eq(worker_commit)
      expect(head_commit(successor.worker_env.cwd)).to eq(head_commit(@repo_root))
    ensure
      successor&.release
    end
  end

  describe "a clean parent receives the merge" do
    it "merges the commit into the parent checkout's head" do
      lease = backend.acquire("worker-1")
      commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      outcome = handback.call(lease, worker_id: "worker-1")

      expect(outcome.kind).to eq(:merged)
      expect(outcome.parent_state).to eq(:merged)
      expect(reachable_from_head?(commit)).to be(true)
    ensure
      lease&.release
    end
  end

  describe "a conflict is reported with its paths and its ref" do
    # The worker and the parent both move README off the SAME base commit, so
    # the merge cannot fast-forward and cannot auto-resolve.
    def diverge
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker's line\n", "worker work")
      commit_in(@repo_root, "parent's line\n", "parent work")
      lease
    end

    it "names the conflicting paths and the ref, raising nothing" do
      lease = diverge

      outcome = nil
      expect { outcome = handback.call(lease, worker_id: "worker-1") }.not_to raise_error

      expect(outcome.kind).to eq(:conflicted)
      expect(outcome.paths).to eq(["README"])
      expect(outcome.ref).to start_with("refs/lain/worker/worker-1-")
    ensure
      lease&.release
    end

    it "leaves the merge IN PROGRESS, with conflict markers a resolver can edit" do
      lease = diverge

      outcome = handback.call(lease, worker_id: "worker-1")

      expect(outcome.parent_state).to eq(:merging)
      expect(outcome).to be_merge_in_progress
      expect(File.exist?(File.join(@repo_root, ".git", "MERGE_HEAD"))).to be(true)
      expect(File.read(File.join(@repo_root, "README"))).to include("<<<<<<<", "worker's line")
    ensure
      lease&.release
    end
  end

  describe "a dirty parent is never merged into" do
    it "declines, leaving the parent untouched and the work on the ref" do
      lease = backend.acquire("worker-1")
      commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")
      File.write(File.join(@repo_root, "README"), "uncommitted parent edit\n")
      parent_head = head_commit(@repo_root)

      outcome = handback.call(lease, worker_id: "worker-1")

      expect(outcome.kind).to eq(:declined)
      expect(outcome.parent_state).to eq(:untouched)
      expect(outcome.ref).to start_with("refs/lain/worker/worker-1-")
      expect(ref_target(outcome.ref).stdout.strip).to eq(commit)
      expect(head_commit(@repo_root)).to eq(parent_head)
      expect(File.read(File.join(@repo_root, "README"))).to eq("uncommitted parent edit\n")
      expect(File.exist?(File.join(@repo_root, ".git", "MERGE_HEAD"))).to be(false)
    ensure
      lease&.release
    end
  end

  describe "an unmoved worktree hands nothing back" do
    it "writes no ref, attempts no merge, and reports nothing-to-do" do
      lease = backend.acquire("worker-1")
      parent_head = head_commit(@repo_root)

      outcome = handback.call(lease, worker_id: "worker-1")

      expect(outcome.kind).to eq(:nothing_to_do)
      expect(outcome.ref).to be_nil
      expect(worker_refs).to be_empty
      expect(head_commit(@repo_root)).to eq(parent_head)
    ensure
      lease&.release
    end

    it "reports nothing-to-do when the worker's commits are already in the parent" do
      lease = backend.acquire("worker-1")
      commit_in(@repo_root, "parent moved on\n", "parent work")

      outcome = handback.call(lease, worker_id: "worker-1")

      expect(outcome.kind).to eq(:nothing_to_do)
      expect(worker_refs).to be_empty
    ensure
      lease&.release
    end
  end

  describe "handback never removes the worktree" do
    it "leaves the checkout on disk and registered with git after a merge" do
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      handback.call(lease, worker_id: "worker-1")

      expect(File.directory?(lease.worker_env.cwd)).to be(true)
      expect(registered_worktrees).to include(lease.worker_env.cwd)
      expect(lease).not_to be_released
    ensure
      lease&.release
    end

    it "leaves the checkout on disk and registered with git after a conflict" do
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker's line\n", "worker work")
      commit_in(@repo_root, "parent's line\n", "parent work")

      handback.call(lease, worker_id: "worker-1")

      expect(File.directory?(lease.worker_env.cwd)).to be(true)
      expect(registered_worktrees).to include(lease.worker_env.cwd)
    ensure
      lease&.release
    end
  end

  describe "a git failure is reported, not raised" do
    it "reports a failed ref write as an outcome, propagating nothing" do
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")
      # A ref BELOW the one we are about to write is a real git F/D conflict:
      # update-ref cannot lock the worker's ref while a child of it exists.
      run_git(@repo_root, "update-ref", "#{handback.send(:ref_for, "worker-1")}/child", head_commit(@repo_root))
      parent_head = head_commit(@repo_root)

      outcome = nil
      expect { outcome = handback.call(lease, worker_id: "worker-1") }.not_to raise_error

      expect(outcome.kind).to eq(:failed)
      expect(outcome.detail).not_to be_empty
      expect(head_commit(@repo_root)).to eq(parent_head)
    ensure
      lease&.release
    end

    it "reports a raise from the git invocation itself as an outcome" do
      exploding = ->(*, **) { raise Errno::ENOENT, "git" }
      handback = described_class.new(repo_root: @repo_root, journal:, shell_out_factory: exploding)
      lease = backend.acquire("worker-1")

      outcome = nil
      expect { outcome = handback.call(lease, worker_id: "worker-1") }.not_to raise_error

      expect(outcome.kind).to eq(:failed)
      expect(outcome.detail).to include("git")
    ensure
      lease&.release
    end
  end

  describe "an arbitrary worker_id" do
    it "slugs into a valid refname rather than trusting the caller's bytes" do
      lease = backend.acquire("arm 1/spawn..x")
      commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      outcome = handback.call(lease, worker_id: "arm 1/spawn..x")

      expect(try_git(@repo_root, "check-ref-format", outcome.ref).exitstatus).to eq(0)
      expect(ref_target(outcome.ref).stdout.strip).to eq(commit)
    ensure
      lease&.release
    end
  end

  describe "the journal record" do
    it "records one handback outcome, carrying the worker key, the outcome, and the ref" do
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      outcome = handback.call(lease, worker_id: "worker-1")

      expect(journal.size).to eq(1)
      expect(journal.first.to_journal).to eq(
        "type" => "handback", "worker_key" => "worker-1",
        "outcome" => :merged, "ref" => outcome.ref
      )
    ensure
      lease&.release
    end

    it "records the outcome even when nothing was handed back" do
      lease = backend.acquire("worker-1")

      handback.call(lease, worker_id: "worker-1")

      expect(journal.map(&:outcome)).to eq([:nothing_to_do])
      expect(journal.first.ref).to be_nil
    ensure
      lease&.release
    end
  end

  # FIX 1. The card's load-bearing invariant, defended against the one caller
  # that can reach past every git guard: this object's OWN journalling. D5 runs
  # `#call` inside a gathered fiber, where a raise takes out the worker's result.
  describe "journalling can never overturn an outcome" do
    it "answers with an outcome for a worker_id the telemetry guard rejects" do
      [nil, "", "   "].each do |blank|
        lease = backend.acquire("blank-#{blank.inspect}")
        commit_in(lease.worker_env.cwd, "worker #{blank.inspect}\n", "worker work")

        outcome = nil
        expect { outcome = handback.call(lease, worker_id: blank) }.not_to raise_error
        expect(outcome.kind).to eq(:merged)
        lease.release
      end
    end

    it "answers with an outcome when the journal sink itself raises" do
      sink = Object.new
      def sink.<<(_record) = raise(IOError, "journal is closed")
      handback = described_class.new(repo_root: @repo_root, journal: sink)
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      outcome = nil
      expect { outcome = handback.call(lease, worker_id: "worker-1") }.not_to raise_error

      expect(outcome.kind).to eq(:merged)
    ensure
      lease&.release
    end

    it "names an unnamed worker rather than losing the record" do
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      outcome = handback.call(lease, worker_id: nil)

      expect(outcome.worker_key).to eq("unnamed-worker")
      expect(journal.map(&:worker_key)).to eq(["unnamed-worker"])
    ensure
      lease&.release
    end
  end

  # FIX 2. Leaving the markers is only right if this object also owns the way
  # out: the resolver has no `bash`, so `git add` + `merge --continue` has to
  # live here or nowhere.
  describe "#continue" do
    def conflict_and_resolve
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker's line\n", "worker work")
      commit_in(@repo_root, "parent's line\n", "parent work")
      outcome = handback.call(lease, worker_id: "worker-1")
      # What a write_file-only resolver can do, and all it can do.
      File.write(File.join(@repo_root, "README"), "both lines, reconciled\n")
      [lease, outcome]
    end

    it "stages the resolution and concludes the merge the resolver could not" do
      lease, conflicted = conflict_and_resolve
      worker_commit = ref_target(conflicted.ref).stdout.strip

      outcome = handback.continue(conflicted.ref, worker_id: "worker-1")

      expect(outcome.kind).to eq(:merged)
      expect(outcome.parent_state).to eq(:merged)
      expect(merging?).to be(false)
      expect(reachable_from_head?(worker_commit)).to be(true)
      expect(File.read(File.join(@repo_root, "README"))).to eq("both lines, reconciled\n")
      expect(run_git(@repo_root, "status", "--porcelain").strip).to be_empty
    ensure
      lease&.release
    end

    it "reports nothing-to-do when no merge is in progress, touching nothing" do
      parent_head = head_commit(@repo_root)

      outcome = handback.continue("refs/lain/worker/nobody")

      expect(outcome.kind).to eq(:nothing_to_do)
      expect(outcome.parent_state).to eq(:untouched)
      expect(head_commit(@repo_root)).to eq(parent_head)
    end

    it "reports a git failure as an outcome, saying the merge is still in progress" do
      lease, conflicted = conflict_and_resolve
      handback = described_class.new(repo_root: @repo_root, journal:,
                                     shell_out_factory: factory_failing("commit"))

      outcome = nil
      expect { outcome = handback.continue(conflicted.ref, worker_id: "worker-1") }.not_to raise_error

      expect(outcome.kind).to eq(:failed)
      expect(outcome.parent_state).to eq(:merging)
      expect(merging?).to be(true)
    ensure
      lease&.release
    end

    it "journals the outcome it concluded with" do
      lease, conflicted = conflict_and_resolve
      journal.clear

      handback.continue(conflicted.ref, worker_id: "worker-1")

      expect(journal.map(&:outcome)).to eq([:merged])
    ensure
      lease&.release
    end
  end

  # An LLM resolver has no way to check its own work, so a leftover marker block
  # would be committed into Joel's own history under the one outcome that means
  # "all fine". The false positive (a diff fixture; this very spec file) is
  # accepted deliberately: a false refuse costs one round trip and #abandon is
  # always there, a false accept costs markers in git history.
  describe "#continue refuses a resolution that is not one" do
    def conflicted
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker's line\n", "worker work")
      commit_in(@repo_root, "parent's line\n", "parent work")
      [lease, handback.call(lease, worker_id: "worker-1")]
    end

    # The three shapes git leaves behind, in order.
    def unresolved_text
      ["<<<<<<< HEAD", "parent's line", "=======", "worker's line", ">>>>>>> theirs", ""].join("\n")
    end

    it "reports the paths still carrying markers, committing nothing" do
      lease, conflict = conflicted
      File.write(File.join(@repo_root, "README"), unresolved_text)
      parent_head = head_commit(@repo_root)

      outcome = handback.continue(conflict.ref, worker_id: "worker-1")

      expect(outcome.kind).to eq(:conflicted)
      expect(outcome.paths).to eq(["README"])
      expect(outcome.parent_state).to eq(:merging)
      expect(outcome.detail).to include("marker")
      expect(head_commit(@repo_root)).to eq(parent_head)
      expect(merging?).to be(true)
    ensure
      lease&.release
    end

    it "can be retried, and concludes once the markers are gone" do
      lease, conflict = conflicted
      File.write(File.join(@repo_root, "README"), unresolved_text)
      handback.continue(conflict.ref, worker_id: "worker-1")

      File.write(File.join(@repo_root, "README"), "reconciled\n")
      outcome = handback.continue(conflict.ref, worker_id: "worker-1")

      expect(outcome.kind).to eq(:merged)
      expect(merging?).to be(false)
    ensure
      lease&.release
    end

    it "wants all three shapes in order, not any marker-shaped line" do
      lease, conflict = conflicted
      File.write(File.join(@repo_root, "README"), "<<<<<<< quoted in prose, not a conflict\n")

      expect(handback.continue(conflict.ref, worker_id: "worker-1").kind).to eq(:merged)
    ensure
      lease&.release
    end
  end

  # `git diff --name-only` applies core.quotePath, so a conflict on föö.txt
  # reports "f\303\266\303\266.txt": the resolver read_files a path that does not
  # exist and #continue dies on `pathspec did not match`, leaving the parent
  # stuck mid-merge with only #abandon as an exit.
  describe "a conflicted path git would otherwise quote" do
    ["föö.txt", "sp ace.txt", "we\nird.txt"].each do |name|
      it "names #{name.inspect} as it is on disk, and can conclude it" do
        lease = backend.acquire("worker-1")
        commit_in(@repo_root, "base\n", "base", file: name)
        run_git(lease.worker_env.cwd, "merge", "--ff-only", head_commit(@repo_root))
        commit_in(lease.worker_env.cwd, "worker's line\n", "worker work", file: name)
        commit_in(@repo_root, "parent's line\n", "parent work", file: name)

        outcome = handback.call(lease, worker_id: "worker-1")

        expect(outcome.paths).to eq([name])
        File.write(File.join(@repo_root, name), "reconciled\n")
        expect(handback.continue(outcome.ref, worker_id: "worker-1").kind).to eq(:merged)
      ensure
        lease&.release
      end
    end
  end

  # #key_for runs in the rescue handler as well as the body, so a raise there is
  # the round-1 double-fault again: the handler re-raises what it was called to
  # contain. Not reachable from a String worker_id, but the class doc promises
  # no raise "from a caller's nonsense".
  describe "a worker_id whose own #to_s is hostile" do
    let(:hostile) do
      { "raises" => Class.new { def to_s = raise("no name for you") }.new,
        "answers nil" => Class.new { def to_s = nil }.new,
        "is a BasicObject" => BasicObject.new }
    end

    it "still answers every operation with an outcome" do
      hostile.each_value do |id|
        lease = backend.acquire("hostile-#{id.__id__}")
        commit_in(lease.worker_env.cwd, "worker #{id.__id__}\n", "worker work")

        expect { handback.call(lease, worker_id: id) }.not_to raise_error
        expect { handback.continue("refs/lain/worker/x", worker_id: id) }.not_to raise_error
        expect { handback.abandon("refs/lain/worker/x", worker_id: id) }.not_to raise_error
        lease.release
      end
    end

    it "names the unnameable rather than journalling a blank" do
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      outcome = handback.call(lease, worker_id: hostile["raises"])

      expect(outcome.kind).to eq(:merged)
      expect(outcome.worker_key).to eq("unnamed-worker")
    ensure
      lease&.release
    end
  end

  describe "#abandon" do
    def conflict
      lease = backend.acquire("worker-1")
      commit_in(lease.worker_env.cwd, "worker's line\n", "worker work")
      commit_in(@repo_root, "parent's line\n", "parent work")
      [lease, handback.call(lease, worker_id: "worker-1")]
    end

    it "restores the parent and leaves the work on the ref" do
      lease, conflicted = conflict
      worker_commit = ref_target(conflicted.ref).stdout.strip

      outcome = handback.abandon(conflicted.ref, worker_id: "worker-1")

      expect(outcome.kind).to eq(:declined)
      expect(outcome.parent_state).to eq(:untouched)
      expect(merging?).to be(false)
      expect(File.read(File.join(@repo_root, "README"))).to eq("parent's line\n")
      expect(ref_target(conflicted.ref).stdout.strip).to eq(worker_commit)
    ensure
      lease&.release
    end

    it "reports nothing-to-do when no merge is in progress" do
      expect(handback.abandon("refs/lain/worker/nobody").kind).to eq(:nothing_to_do)
    end

    it "reports a failed abort as an outcome that still says :merging" do
      lease, conflicted = conflict
      handback = described_class.new(repo_root: @repo_root, journal:,
                                     shell_out_factory: factory_failing("--abort"))

      outcome = nil
      expect { outcome = handback.abandon(conflicted.ref, worker_id: "worker-1") }.not_to raise_error

      expect(outcome.kind).to eq(:failed)
      expect(outcome.parent_state).to eq(:merging)
    ensure
      lease&.release
    end
  end

  # FIX 3/4. update-ref overwrites unconditionally, so on a declined or
  # conflicted handback -- where the ref is the ONLY anchor -- two ids that slug
  # alike would orphan one worker's commits.
  describe "the ref is one per worker, not one per slug" do
    it "gives two ids that slug alike two distinct refs, both still anchored" do
      first = backend.acquire("a/b")
      one = commit_in(first.worker_env.cwd, "one\n", "one")
      File.write(File.join(@repo_root, "README"), "parent is dirty\n") # so both DECLINE
      declined_one = handback.call(first, worker_id: "a/b")
      first.release

      second = backend.acquire("a-b")
      two = commit_in(second.worker_env.cwd, "two\n", "two")
      declined_two = handback.call(second, worker_id: "a-b")

      expect(declined_one.ref).not_to eq(declined_two.ref)
      expect(ref_target(declined_one.ref).stdout.strip).to eq(one)
      expect(ref_target(declined_two.ref).stdout.strip).to eq(two)
    ensure
      second&.release
    end

    # Both are NAMED unnamed-worker, which is a display decision; they are still
    # two workers, so the fingerprint is taken of the original id, not the name.
    it "gives two unnameable ids two refs rather than one they overwrite" do
      first = backend.acquire("blank")
      one = commit_in(first.worker_env.cwd, "one\n", "one")
      File.write(File.join(@repo_root, "README"), "parent is dirty\n") # so both DECLINE
      blank = handback.call(first, worker_id: "")
      first.release

      second = backend.acquire("whitespace")
      two = commit_in(second.worker_env.cwd, "two\n", "two")
      spaces = handback.call(second, worker_id: "   ")

      expect(blank.ref).not_to eq(spaces.ref)
      expect(ref_target(blank.ref).stdout.strip).to eq(one)
      expect(ref_target(spaces.ref).stdout.strip).to eq(two)
    ensure
      second&.release
    end

    it "keeps the caller's id readable in the ref it can be found by" do
      lease = backend.acquire("arm-3")
      commit_in(lease.worker_env.cwd, "worker\n", "worker work")

      expect(handback.call(lease, worker_id: "arm-3").ref).to start_with("refs/lain/worker/arm-3-")
    ensure
      lease&.release
    end

    # Every one of these slugged to a refname git rejects, or (for the empty id)
    # to `blake3:<hex>`, which check-ref-format rejects for the colon.
    hostile = { "empty" => "", "whitespace" => "   ", "dots" => "..", "unicode" => "ärm-あ",
                "dot-lock" => "job.lock.", "double-lock" => "w.lock.lock", "leading dot" => ".hidden",
                "long" => "x" * 500, "at-brace" => "a@{0}", "metachars" => "a; rm -rf /|$(id)" }
    hostile.each do |name, id|
      it "writes a refname git accepts for a #{name} worker_id" do
        lease = backend.acquire("hostile-#{name}")
        commit = commit_in(lease.worker_env.cwd, "worker\n", "worker work")

        outcome = handback.call(lease, worker_id: id)

        expect(try_git(@repo_root, "check-ref-format", outcome.ref.to_s).exitstatus).to eq(0)
        expect(outcome.kind).not_to eq(:failed)
        expect(ref_target(outcome.ref).stdout.strip).to eq(commit)
      ensure
        lease&.release
      end
    end
  end

  # FIX 6. "uncommitted changes" names the wrong fix for a mid-merge parent: a
  # caller retries and a human hunts for edits that are not there.
  describe "a parent already mid-merge" do
    it "is reported as mid-merge, naming the way out, not as a dirty checkout" do
      first = backend.acquire("worker-1")
      commit_in(first.worker_env.cwd, "worker's line\n", "worker work")
      commit_in(@repo_root, "parent's line\n", "parent work")
      handback.call(first, worker_id: "worker-1")

      second = backend.acquire("worker-2")
      commit_in(second.worker_env.cwd, "second\n", "second work", file: "SECOND")
      outcome = handback.call(second, worker_id: "worker-2")

      expect(outcome.kind).to eq(:declined)
      expect(outcome.detail).to include("mid-merge")
      expect(outcome.detail).not_to include("uncommitted changes")
      expect(merging?).to be(true)
    ensure
      first&.release
      second&.release
    end
  end

  # FIX 7. The only case reachable today (an untracked file the merge would
  # clobber, where no merge ever started) really is untouched -- but the claim
  # has to be measured, not assumed.
  describe "a merge that fails without conflicting" do
    it "restores the parent and says so" do
      lease = backend.acquire("worker-1")
      commit = commit_in(lease.worker_env.cwd, "worker\n", "adds NEW", file: "NEW")
      File.write(File.join(@repo_root, "NEW"), "precious untracked bytes\n")

      outcome = handback.call(lease, worker_id: "worker-1")

      expect(outcome.kind).to eq(:failed)
      expect(outcome.parent_state).to eq(:untouched)
      expect(merging?).to be(false)
      expect(File.read(File.join(@repo_root, "NEW"))).to eq("precious untracked bytes\n")
      expect(ref_target(outcome.ref).stdout.strip).to eq(commit)
    ensure
      lease&.release
    end
  end

  describe Lain::Isolation::Worktree::Handback::Outcome do
    it "is deeply frozen, so an outcome crosses a Ractor boundary" do
      outcome = described_class.new(kind: :conflicted, worker_key: "w", ref: "refs/lain/worker/w",
                                    paths: ["a.rb"], parent_state: :merging, detail: "conflict")

      expect(Ractor.shareable?(outcome)).to be(true)
    end

    it "refuses a kind no caller can act on" do
      expect { described_class.new(kind: :probably_fine, worker_key: "w") }
        .to raise_error(ArgumentError, /kind must be one of/)
    end

    it "defaults to the untouched-parent, nothing-carried shape" do
      outcome = described_class.new(kind: :nothing_to_do, worker_key: "w")

      expect(outcome.ref).to be_nil
      expect(outcome.paths).to eq([])
      expect(outcome.parent_state).to eq(:untouched)
      expect(outcome.detail).to eq("")
      expect(outcome).not_to be_merge_in_progress
    end
  end
end
