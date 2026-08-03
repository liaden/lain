# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "delegate"
require "async"
require "mixlib/shellout"

# The resolver spawn seam's duck -- `Skill::RoleSpawn#call(role_name,
# context_mode, prompt)`, answering a `Tool::Result`. It RECORDS every spawn (so
# a spec can read the role, the context mode, and the prompt the resolver was
# actually given) and runs an injected action over the paths the PROMPT named,
# standing in for what the model would have edited.
class RecordingResolver
  Spawn = Struct.new(:role, :mode, :prompt)

  # The escapes `String#inspect` emits for a filename. NOT `String#undump`,
  # which is the inverse of `#dump`, not of `#inspect`: `#dump` escapes
  # non-ASCII to `\u{...}` and `#undump` REFUSES a literal one
  # ("non-ASCII character detected"), so a `föö bär.txt` bullet would blow the
  # stand-in up on a path production handles fine.
  ESCAPES = { "n" => "\n", "t" => "\t", "r" => "\r", "e" => "\e", "0" => "\0", "s" => " ",
              "\\" => "\\", '"' => '"', "#" => "#" }.freeze

  # Every conflicted path the prompt named, unquoted. The prompt quotes with
  # `String#inspect` so a filename carrying a newline survives as one bullet.
  def self.named_paths(prompt)
    prompt.lines.grep(/\A- "/).map { |line| unquote(line.strip.delete_prefix("- ")) }
  end

  def self.unquote(token)
    token[1..-2].gsub(/\\(.)/) { ESCAPES.fetch(Regexp.last_match(1), Regexp.last_match(1)) }
  end

  attr_reader :spawns

  def initialize(reply: Lain::Tool::Result.ok("resolved"), &action)
    @spawns = []
    @reply = reply
    @action = action || ->(_paths) {}
  end

  def call(role, mode, prompt)
    @spawns << Spawn.new(role, mode, prompt)
    @action.call(self.class.named_paths(prompt))
    @reply
  end
end

# Operates on a THROWAWAY repo it creates itself (git init in a mktmpdir), never
# the lain repo it runs in -- the posture worktree_spec.rb and the D4 handback
# spec both take, and the reason this stays in the default suite: git is always
# present, a model is not.
RSpec.describe Lain::Isolation::WorkerHandoff, :seam do
  subject(:handoff) { described_class.new(handback:, repo_root: @repo_root, resolver:) }

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

  let(:journal) { [] }
  let(:handback) { Lain::Isolation::Worktree::Handback.new(repo_root: @repo_root, journal:) }
  let(:backend) { Lain::Isolation::Worktree.new(repo_root: @repo_root, root: @root) }
  let(:resolver) { RecordingResolver.new }

  # The spec's OWN git calls scrub the git-context env, so building and
  # inspecting the throwaway repo is hermetic under an ambient GIT_*-polluted
  # env (a pre-commit hook) exactly as the subject is.
  def run_git(dir, *args)
    shell = Mixlib::ShellOut.new("git", "-C", dir, *args,
                                 environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
    shell.run_command.error!
    shell.stdout
  end

  # For the git calls a fixture EXPECTS to fail -- a merge staged deliberately to
  # conflict, so the parent sits mid-merge from someone other than the subject.
  def try_git(dir, *args)
    Mixlib::ShellOut.new("git", "-C", dir, *args,
                         environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB).run_command
  end

  # Copied, not rebuilt: five git subprocesses per example for a directory that
  # is identical every time (see {SeedRepo}).
  def init_repo(dir) = FileUtils.cp_r("#{SeedRepo.at(seed_files)}/.", dir)

  # A method, not a constant: a constant assigned inside a top-level
  # `RSpec.describe do ... end` is lexically scoped to Object, so a second
  # spec file spelling the same name silently clobbers this one -- the trap
  # CLAUDE.md records for `Data.define` blocks, in a new costume.
  def seed_files = { "alpha.txt" => "seed\n", "beta.txt" => "seed\n" }

  def commit_all(dir, message)
    run_git(dir, "add", "-A")
    run_git(dir, "commit", "-q", "-m", message)
  end

  def write_all(dir, files, body)
    files.each { |file| File.write(File.join(dir, file), "#{body} #{file}\n") }
  end

  # A live lease whose worker committed work that CONFLICTS with the parent: both
  # sides rewrite the same tracked files, and the parent's own change is
  # committed so the handback is not declined for a dirty checkout.
  def conflicting_lease(*files, worker_id: "worker-1")
    backend.acquire(worker_id).tap do |lease|
      write_all(lease.worker_env.cwd, files, "worker")
      commit_all(lease.worker_env.cwd, "worker work")
      write_all(@repo_root, files, "parent")
      commit_all(@repo_root, "parent work")
    end
  end

  # A live lease whose worker committed work that merges cleanly: it touches a
  # file the parent never moved.
  def clean_lease
    backend.acquire("worker-1").tap do |lease|
      File.write(File.join(lease.worker_env.cwd, "alpha.txt"), "worker alpha\n")
      commit_all(lease.worker_env.cwd, "worker work")
    end
  end

  # Models the REAL resolver's reach: `read_file`/`write_file` resolve a relative
  # path against `session.worker_env.cwd`, which is NEVER the parent checkout, so
  # a stand-in that quietly rewrote repo-relative paths under @repo_root would be
  # more permissive than the object it stands for.
  def resolving_resolver(reply: Lain::Tool::Result.ok("kept the worker's side of both files"))
    RecordingResolver.new(reply:) do |paths|
      paths.each do |path|
        raise "resolver was handed the relative path #{path.inspect}" unless File.absolute_path?(path)

        File.write(path, "reconciled #{File.basename(path)}\n")
      end
    end
  end

  def merge_head = File.join(@repo_root, ".git", "MERGE_HEAD")
  def merging? = File.exist?(merge_head)
  def registered_worktrees = run_git(@repo_root, "worktree", "list", "--porcelain")
  def parent_body(file) = File.read(File.join(@repo_root, file))
  def markers? = %w[alpha.txt beta.txt].any? { |file| parent_body(file).include?("<<<<<<<") }
  def ref_resolves?(ref) = !run_git(@repo_root, "rev-parse", "--verify", ref).strip.empty?
  def worker_refs = run_git(@repo_root, "for-each-ref", "--format=%(refname)", "refs/lain").split("\n")

  describe "a clean handback spawns nothing" do
    it "merges, spawns no resolver, and releases the lease" do
      lease = clean_lease

      report = handoff.reclaim(lease, worker_id: "worker-1")

      expect(report.kind).to eq(:merged)
      expect(resolver.spawns).to be_empty
      expect(lease).to be_released
      expect(parent_body("alpha.txt")).to eq("worker alpha\n")
    ensure
      lease&.release
    end
  end

  describe "a conflicted handback spawns a resolver over a fresh root" do
    it "spawns exactly one merge_resolver under the :fresh context mode" do
      lease = conflicting_lease("alpha.txt")

      handoff.reclaim(lease, worker_id: "worker-1")

      expect(resolver.spawns.size).to eq(1)
      expect(resolver.spawns.first.role).to eq(:merge_resolver)
      expect(resolver.spawns.first.mode).to eq(:fresh)
    ensure
      lease&.release
    end

    # The conflict transcript is what the child sees; the ORCHESTRATOR sees only
    # the Report, whose summary carries no marker text and no prompt body. The
    # `:fresh` mode above is the mechanism (the child gets its own root); this is
    # the observable consequence at the seam the arm folds into its own result.
    it "hands back a summary carrying the resolver's result, never the conflict transcript" do
      lease = conflicting_lease("alpha.txt")

      report = handoff.reclaim(lease, worker_id: "worker-1")

      expect(report.summary).not_to include("<<<<<<<")
      expect(report.summary).not_to include(resolver.spawns.first.prompt)
    ensure
      lease&.release
    end
  end

  describe "the resolver is told which files conflict and which ref holds the work" do
    it "names both conflicted paths and the ref in the prompt" do
      lease = conflicting_lease("alpha.txt", "beta.txt")

      report = handoff.reclaim(lease, worker_id: "worker-1")
      prompt = resolver.spawns.first.prompt

      expect(prompt).to include("alpha.txt")
      expect(prompt).to include("beta.txt")
      expect(prompt).to include(report.ref)
      expect(report.ref).to start_with("refs/lain/worker/worker-1-")
    ensure
      lease&.release
    end

    # A spawned child resolves a relative path against its OWN worker_env cwd
    # (tools/read_file.rb), which is never the parent checkout -- so a
    # repo-relative path names some other file, or none.
    it "names ABSOLUTE paths under the handback's repo_root, never repo-relative ones" do
      lease = conflicting_lease("alpha.txt", "beta.txt")

      handoff.reclaim(lease, worker_id: "worker-1")
      named = RecordingResolver.named_paths(resolver.spawns.first.prompt)

      expect(named).to contain_exactly(File.join(@repo_root, "alpha.txt"), File.join(@repo_root, "beta.txt"))
      expect(named).to all(satisfy { |path| File.absolute_path?(path) && File.exist?(path) })
    ensure
      lease&.release
    end

    # D4 used `-z` and re-tagged the path encoding precisely so BOTH of these
    # still open: a bare `- #{path}` bullet shears the newline-bearing one across
    # two lines and names a file that does not exist, and the non-ASCII one is
    # the shape that catches a decoder which is not the true inverse of the
    # encoder the prompt used.
    it "quotes each path, so a newline-bearing and a non-ASCII filename each survive as ONE bullet" do
      awkward = ["with\nnewline.txt", "föö bär.txt"]
      awkward.each { |name| File.write(File.join(@repo_root, name), "seed\n") }
      commit_all(@repo_root, "seed the awkward filenames")
      lease = conflicting_lease(*awkward)

      handoff.reclaim(lease, worker_id: "worker-1")
      prompt = resolver.spawns.first.prompt

      expect(prompt.lines.grep(/\A- /).size).to eq(2)
      awkward.each { |name| expect(prompt).to include(File.join(@repo_root, name).inspect) }
      expect(RecordingResolver.named_paths(prompt))
        .to match_array(awkward.map { |name| File.join(@repo_root, name) })
    ensure
      lease&.release
    end

    # The stand-in has to be able to OPEN what it decodes, or it is once again
    # more permissive than the object it stands for.
    it "hands the resolver awkward paths it can actually open" do
      awkward = ["föö bär.txt", "plain.txt"]
      File.write(File.join(@repo_root, "föö bär.txt"), "seed\n")
      commit_all(@repo_root, "seed the non-ASCII filename")
      lease = conflicting_lease(*awkward)

      described_class.new(handback:, repo_root: @repo_root, resolver: resolving_resolver)
                     .reclaim(lease, worker_id: "worker-1")

      expect(File.read(File.join(@repo_root, "föö bär.txt"))).to eq("reconciled föö bär.txt\n")
    ensure
      lease&.release
    end
  end

  describe "the resolver holds no shell capability" do
    let(:role) { Lain::Role::Catalog.fetch(:merge_resolver) }

    it "carries file-editing capabilities and does not carry bash" do
      expect(role.only).to include(:read_file, :edit_file, :write_file, :grep)
      expect(role.only).not_to include(:bash)
    end

    it "attenuates a union holding bash down to a toolset without it" do
      union = Lain::Toolset.new(
        %i[read_file edit_file write_file grep bash].map do |named|
          Class.new(Lain::Tool) do
            define_method(:name) { named.to_s }
            define_method(:description) { "the #{named} capability" }
            define_method(:input_schema) { { type: :object, properties: {} } }
            define_method(:perform) { |_input, _invocation| Lain::Tool::Result.ok("ok") }
          end.new
        end
      )

      expect(role.spawn_policy(prefix: :fresh).attenuate(union).names).not_to include("bash")
    end
  end

  describe "a resolved conflict reports what it changed" do
    let(:resolver) { resolving_resolver }

    it "merges and names the files it resolved" do
      lease = conflicting_lease("alpha.txt", "beta.txt")

      report = handoff.reclaim(lease, worker_id: "worker-1")

      expect(report.kind).to eq(:resolved)
      expect(report.paths).to contain_exactly("alpha.txt", "beta.txt")
      expect(report.summary).to include("alpha.txt").and include("beta.txt")
      expect(parent_body("alpha.txt")).to eq("reconciled alpha.txt\n")
      expect(merging?).to be(false)
    ensure
      lease&.release
    end

    # The role template PROMISES the child a place to say what it dropped. A
    # Report that discards the reply breaks that promise, and makes a resolver
    # that made a judgement call indistinguishable from one that said nothing.
    it "carries the resolver's own words onto the report" do
      lease = conflicting_lease("alpha.txt")

      report = handoff.reclaim(lease, worker_id: "worker-1")

      expect(report.detail).to eq("kept the worker's side of both files")
      expect(report.summary).to include("kept the worker's side of both files")
    ensure
      lease&.release
    end

    it "squeezes a long, multi-line reply into one truncated line" do
      chatty = resolving_resolver(reply: Lain::Tool::Result.ok("a\n\nb#{"x" * 500}"))
      lease = conflicting_lease("alpha.txt")

      verbose = described_class.new(handback:, repo_root: @repo_root, resolver: chatty)
      report = verbose.reclaim(lease, worker_id: "worker-1")

      expect(report.detail.lines.size).to eq(1)
      expect(report.detail.length).to eq(Lain::Isolation::WorkerHandoff::Reply::LIMIT + 3)
      expect(report.detail).to end_with("...")
    ensure
      lease&.release
    end
  end

  describe "a spawn that never ran is not the same failure as one that mis-edited" do
    # `Subagent#run` answers the depth ceiling with an ERROR Tool::Result, not a
    # raise, so a refused spawn arrives looking exactly like a completed one.
    let(:resolver) { RecordingResolver.new(reply: Lain::Tool::Result.error("subagent depth limit reached")) }

    it "says the resolver never ran, and quotes why" do
      lease = conflicting_lease("alpha.txt")

      report = handoff.reclaim(lease, worker_id: "worker-1")

      expect(report.kind).to eq(:conflicted)
      expect(report.summary).to include("the resolver never ran")
      expect(report.summary).to include("subagent depth limit reached")
    ensure
      lease&.release
    end

    it "reads differently from a resolver that ran and left the markers" do
      lease = conflicting_lease("alpha.txt")
      refused = handoff.reclaim(lease, worker_id: "worker-1").summary
      lease.release

      ran = described_class.new(handback:, repo_root: @repo_root,
                                resolver: RecordingResolver.new(reply: Lain::Tool::Result.ok("done")))
      other = conflicting_lease("beta.txt", worker_id: "worker-2")
      mis_edited = ran.reclaim(other, worker_id: "worker-2").summary

      expect(refused).not_to eq(mis_edited)
      expect(mis_edited).to include("the resolver said: done")
    ensure
      lease&.release
      other&.release
    end

    it "names the Null resolver when none is wired at all" do
      lease = conflicting_lease("alpha.txt")

      report = described_class.new(handback:, repo_root: @repo_root).reclaim(lease, worker_id: "worker-1")

      expect(report.summary).to include("no merge resolver is wired")
    ensure
      lease&.release
    end
  end

  describe "an unresolved conflict is reported, not swallowed" do
    # A resolver that "finishes" without touching a marker -- the case D4's
    # #continue refuses rather than committing corruption.
    let(:resolver) { RecordingResolver.new }

    it "says the conflict stands, names the ref, and leaves no merge in progress" do
      lease = conflicting_lease("alpha.txt")

      report = handoff.reclaim(lease, worker_id: "worker-1")

      expect(report.kind).to eq(:conflicted)
      expect(report.summary).to include(report.ref)
      expect(report.summary).to match(/stands/i)
      expect(merging?).to be(false)
      expect(ref_resolves?(report.ref)).to be(true)
    ensure
      lease&.release
    end

    it "spawns the resolver exactly once -- a marker refusal is not retried" do
      lease = conflicting_lease("alpha.txt")

      handoff.reclaim(lease, worker_id: "worker-1")

      expect(resolver.spawns.size).to eq(1)
    ensure
      lease&.release
    end
  end

  describe "the lease is released whatever the resolver did" do
    let(:resolver) { RecordingResolver.new { raise "resolver exploded" } }

    it "releases the lease, reclaims the worktree, and never raises" do
      lease = conflicting_lease("alpha.txt")
      path = lease.worker_env.cwd

      report = nil
      expect { report = handoff.reclaim(lease, worker_id: "worker-1") }.not_to raise_error

      expect(report.kind).to eq(:conflicted)
      expect(report.summary).to include(report.ref)
      expect(lease).to be_released
      expect(registered_worktrees).not_to include(path)
      expect(merging?).to be(false)
    ensure
      lease&.release
    end
  end

  # Async::Cancel and Interrupt are `< Exception`, NOT `< StandardError`, so no
  # rescue in this object sees them -- and one worker's failed `acquire` cancels
  # its siblings mid-resolve through the arm's `Sync { ...Async... }` fan-out.
  # The parent checkout must not be left holding MERGE_HEAD and conflict markers.
  describe "an Exception climbing out mid-resolve still leaves the parent usable" do
    def suppress(klass)
      yield
    rescue klass
      nil
    end

    [Async::Cancel, Interrupt].each do |klass|
      context "when the resolver raises #{klass}" do
        let(:resolver) { RecordingResolver.new { raise klass } }

        it "lets it climb, but restores the parent and releases the lease first" do
          lease = conflicting_lease("alpha.txt", "beta.txt")
          path = lease.worker_env.cwd

          expect { handoff.reclaim(lease, worker_id: "worker-1") }.to raise_error(klass)

          expect(merging?).to be(false)
          expect(markers?).to be(false)
          expect(lease).to be_released
          expect(registered_worktrees).not_to include(path)
        ensure
          lease&.release
        end

        it "keeps the worker's work on its ref, so nothing is lost to the unwind" do
          lease = conflicting_lease("alpha.txt")
          worker_commit = run_git(lease.worker_env.cwd, "rev-parse", "HEAD").strip

          suppress(klass) { handoff.reclaim(lease, worker_id: "worker-1") }

          expect(worker_refs.first).to start_with("refs/lain/worker/worker-1-")
          expect(run_git(@repo_root, "rev-parse", worker_refs.first).strip).to eq(worker_commit)
        ensure
          lease&.release
        end
      end
    end
  end

  # `#reclaim` never runs when a non-StandardError takes the worker out before
  # it. Releasing a `--detach`ed worktree DESTROYS unanchored commits, so no
  # path may release without FIRST trying to anchor: `#surrender` is the arm's
  # `ensure`-position attempt.
  describe "#surrender anchors the work before the reclaim destroys it" do
    it "writes the ref and releases, even when the parent will not take the merge" do
      lease = clean_lease
      worker_commit = run_git(lease.worker_env.cwd, "rev-parse", "HEAD").strip
      File.write(File.join(@repo_root, "beta.txt"), "uncommitted parent edit\n")
      path = lease.worker_env.cwd

      report = handoff.surrender(lease, worker_id: "worker-1")

      expect(report.kind).to eq(:declined)
      expect(run_git(@repo_root, "rev-parse", report.ref).strip).to eq(worker_commit)
      expect(lease).to be_released
      expect(registered_worktrees).not_to include(path)
    ensure
      lease&.release
    end

    it "spawns NO resolver on a conflict, and leaves the parent clean" do
      lease = conflicting_lease("alpha.txt")

      report = handoff.surrender(lease, worker_id: "worker-1")

      expect(resolver.spawns).to be_empty
      expect(report.kind).to eq(:conflicted)
      expect(report.summary).to include("no resolver is spawned while a worker is unwinding")
      expect(merging?).to be(false)
      expect(markers?).to be(false)
      expect(ref_resolves?(report.ref)).to be(true)
    ensure
      lease&.release
    end

    it "no-ops once the lease is already released, so reclaim-then-surrender is one handback" do
      lease = clean_lease

      handoff.reclaim(lease, worker_id: "worker-1")
      second = handoff.surrender(lease, worker_id: "worker-1")

      expect(second.kind).to eq(:nothing_to_do)
      expect(journal.size).to eq(1)
    ensure
      lease&.release
    end
  end

  # The recorded data-loss hole. The `update-ref` lives INSIDE `Handback#call`,
  # so a raise anywhere in that method used to release the lease over a worktree
  # no ref reached -- and releasing a `--detach`ed worktree makes its commits
  # unreachable and gc-able. `Handback#anchor` is the ref without the merge, and
  # the `ensure` calls it whenever the body left nothing anchored.
  describe "a raise mid-handback no longer loses the worker's commits" do
    # Raises exactly where the hole was: before any ref is written.
    def exploding_call(error, message = "the index is unwritable")
      Class.new(SimpleDelegator) do
        define_method(:call) { |*, **| raise(error, message) }
      end.new(Lain::Isolation::Worktree::Handback.new(repo_root: @repo_root, journal:))
    end

    def over(broken) = described_class.new(handback: broken, repo_root: @repo_root, resolver:)

    it "anchors the commit and names the ref on the report it failed with" do
      lease = clean_lease
      worker_commit = run_git(lease.worker_env.cwd, "rev-parse", "HEAD").strip
      path = lease.worker_env.cwd

      report = over(exploding_call(IOError)).reclaim(lease, worker_id: "worker-1")

      expect(report.kind).to eq(:failed)
      expect(report.ref).to start_with("refs/lain/worker/worker-1-")
      expect(run_git(@repo_root, "rev-parse", report.ref).strip).to eq(worker_commit)
      expect(lease).to be_released
      expect(registered_worktrees).not_to include(path)
    ensure
      lease&.release
    end

    # `Async::Cancel` and `Interrupt` are `< Exception`, so no rescue in the
    # object sees them: only the `ensure` runs, and it must anchor before the
    # release under it.
    [Async::Cancel, Interrupt].each do |klass|
      it "anchors from the ensure when #{klass} climbs out of the handback" do
        lease = clean_lease
        worker_commit = run_git(lease.worker_env.cwd, "rev-parse", "HEAD").strip

        expect { over(exploding_call(klass)).reclaim(lease, worker_id: "worker-1") }.to raise_error(klass)

        expect(worker_refs).to contain_exactly(a_string_starting_with("refs/lain/worker/worker-1-"))
        expect(run_git(@repo_root, "rev-parse", worker_refs.first).strip).to eq(worker_commit)
        expect(lease).to be_released
      ensure
        lease&.release
      end
    end

    # #surrender is the arm's `ensure`-position call, so it is the one that runs
    # while an exception is already climbing somewhere above.
    it "anchors from #surrender too, and spawns nothing" do
      lease = clean_lease
      worker_commit = run_git(lease.worker_env.cwd, "rev-parse", "HEAD").strip

      report = over(exploding_call(IOError)).surrender(lease, worker_id: "worker-1")

      expect(run_git(@repo_root, "rev-parse", report.ref).strip).to eq(worker_commit)
      expect(resolver.spawns).to be_empty
      expect(lease).to be_released
    ensure
      lease&.release
    end

    # ONE attempt, never a loop: the anchor runs while an exception climbs, and a
    # retry with no bound would hold the worktree for as long as git kept
    # failing. A raise from the anchor must not replace the climbing exception
    # nor skip the release under it.
    it "tries the anchor once and still releases when the anchor itself raises" do
      attempts = 0
      broken = Class.new(SimpleDelegator) do
        define_method(:call) { |*, **| raise(Interrupt, "interrupted") }
        define_method(:anchor) do |*, **|
          attempts += 1
          raise(Interrupt, "the anchor is broken too")
        end
      end.new(handback)
      lease = clean_lease

      expect { over(broken).reclaim(lease, worker_id: "worker-1") }.to raise_error(Interrupt, "interrupted")

      expect(attempts).to eq(1)
      expect(lease).to be_released
    ensure
      lease&.release
    end

    # The guard is what keeps the experiment record honest: a handback that
    # already anchored gets no second `update-ref` and no second journal line.
    it "adds no anchor of its own when the handback already wrote the ref" do
      lease = clean_lease

      handoff.reclaim(lease, worker_id: "worker-1")

      expect(journal.map(&:outcome)).to eq([:merged])
    ensure
      lease&.release
    end

    # Raises ONE git subcommand rather than exiting nonzero -- an exhausted fd
    # table, a killed spawn, a Ctrl-C mid-call.
    def raising_at(subcommand, error = Errno::EMFILE)
      real = Mixlib::ShellOut.public_method(:new)
      factory = lambda do |*args, **kwargs|
        raise(error, "git #{subcommand}") if args.include?(subcommand)

        real.call(*args, **kwargs)
      end
      Lain::Isolation::Worktree::Handback.new(repo_root: @repo_root, journal:, shell_out_factory: factory)
    end

    # The summary is the ONE line an arm folds into a worker's result. A `:failed`
    # that renders "handback failed ()" tells a human the work is gone when it is
    # sitting on a ref two commands away.
    it "names the ref in the summary when the merge raises after the anchor" do
      lease = clean_lease
      worker_commit = run_git(lease.worker_env.cwd, "rev-parse", "HEAD").strip

      report = over(raising_at("merge")).reclaim(lease, worker_id: "worker-1")

      expect(report.kind).to eq(:failed)
      expect(report.ref).to start_with("refs/lain/worker/worker-1-")
      expect(report.summary).to include(report.ref)
      expect(report.summary).not_to include("()")
      expect(run_git(@repo_root, "rev-parse", report.ref).strip).to eq(worker_commit)
    ensure
      lease&.release
    end

    # A worktree is force-removed moments after this, so an anchor that failed
    # ENTIRELY is the one event the record must not lose. `Interrupt` is the
    # shape that went silent: `< Exception`, so it slipped past the journalling
    # on its way to being swallowed.
    it "leaves a journal line when the ensure's anchor fails totally" do
      lease = clean_lease

      expect { over(raising_at("rev-parse", Interrupt)).reclaim(lease, worker_id: "worker-1") }
        .to raise_error(Interrupt)

      expect(journal.map(&:outcome)).to eq([:failed])
      expect(journal.first.worker_key).to eq("worker-1")
      expect(lease).to be_released
    ensure
      lease&.release
    end
  end

  # Fix 1 corrected the ref VALUE where nil was wrong. This is the rendering of a
  # nil that is right: a CAS loss, an already-released lease and a pre-write
  # raise all legitimately anchor nothing, and "handback failed ()" reads as "the
  # work is gone" rather than "there was never a ref to name".
  describe "a summary never renders an empty pair of parens" do
    it "omits the parens when there is no ref to name" do
      report = described_class::Report.new(kind: :failed, detail: "git update-ref failed")

      expect(report.summary).to eq("handback failed -- git update-ref failed")
      expect(report.summary).not_to include("()")
    end

    it "still names the ref in parens when there is one" do
      report = described_class::Report.new(kind: :failed, ref: "refs/lain/worker/w-1", detail: "boom")

      expect(report.summary).to eq("handback failed (refs/lain/worker/w-1) -- boom")
    end

    it "omits them on a :merged with no ref, and keeps them when it has one" do
      expect(described_class::Report.new(kind: :merged).summary).to eq("handback merged the worker's commits")
      expect(described_class::Report.new(kind: :merged, ref: "refs/lain/worker/w-1").summary)
        .to eq("handback merged the worker's commits (refs/lain/worker/w-1)")
    end

    # The real path that produces one: the compare-and-swap loses, so nothing is
    # anchored and there is genuinely no ref to name.
    it "reads cleanly for a CAS loss, which anchors nothing" do
      lease = clean_lease
      ref = Lain::Isolation::Worktree::Handback::Naming.new("worker-1").ref
      other = run_git(@repo_root, "rev-parse", "HEAD").strip
      real = Mixlib::ShellOut.public_method(:new)
      racing = lambda do |*args, **kwargs|
        run_git(@repo_root, "update-ref", ref, other) if args.include?("update-ref")
        real.call(*args, **kwargs)
      end
      losing = Lain::Isolation::Worktree::Handback.new(repo_root: @repo_root, journal:, shell_out_factory: racing)

      report = described_class.new(handback: losing, repo_root: @repo_root, resolver:)
                              .reclaim(lease, worker_id: "worker-1")

      expect(report.kind).to eq(:failed)
      expect(report.ref).to be_nil
      expect(report.summary).not_to include("()")
      expect(report.summary).to start_with("handback failed -- ")
    ensure
      lease&.release
    end
  end

  # Unwinding a merge needs git, and on this path git is what failed -- there is
  # no second mechanism to try. What is left is to SAY it, loudly, naming the ref
  # and the one command that fixes the checkout. Silence here means the next
  # handback into this parent declines forever.
  describe "a parent that could not be unwound is escalated, not swallowed" do
    # The unwind runs from an `ensure`, so it has to survive EVERY class its
    # collaborator can raise. `Async::Cancel` and `Interrupt` are `< Exception`:
    # a `rescue StandardError` here lets one out of the `ensure`, where it
    # REPLACES the exception already climbing and skips the release below it --
    # round 1's blocker, one level down.
    def exploding(error, message)
      Class.new(SimpleDelegator) do
        define_method(:abandon) { |*, **| raise(error, message) }
      end.new(Lain::Isolation::Worktree::Handback.new(repo_root: @repo_root, journal:))
    end

    [[IOError, "the index is unwritable"], [Async::Cancel, "cancelled"], [Interrupt, "interrupted"]].each do
      |error, message|
      context "when #abandon raises #{error}" do
        let(:handback) { exploding(error, message) }

        it "reports :failed, names the ref that holds the work, and names the fix" do
          lease = conflicting_lease("alpha.txt")

          report = handoff.reclaim(lease, worker_id: "worker-1")

          expect(report.kind).to eq(:failed)
          expect(report.ref).to start_with("refs/lain/worker/worker-1-")
          expect(report.summary).to include(report.ref)
          expect(report.summary).to include("STILL MID-MERGE")
          expect(report.summary).to include("git merge --abort")
          expect(merging?).to be(true)
        ensure
          lease&.release
          try_git(@repo_root, "merge", "--abort")
        end

        it "still releases the lease -- the unwind never escapes into the ensure" do
          lease = conflicting_lease("alpha.txt")

          expect { handoff.reclaim(lease, worker_id: "worker-1") }.not_to raise_error

          expect(lease).to be_released
        ensure
          lease&.release
          try_git(@repo_root, "merge", "--abort")
        end
      end
    end
  end

  # The prompt's absolute paths and the merge itself must name ONE checkout: two
  # roots would tell the resolver to open files that are not the ones on disk.
  describe ".over builds both halves from a single root" do
    it "hands the resolver paths under the same checkout the merge landed in" do
      lease = conflicting_lease("alpha.txt")
      built = described_class.over(repo_root: @repo_root, journal:, resolver: resolving_resolver)

      report = built.reclaim(lease, worker_id: "worker-1")

      expect(report.kind).to eq(:resolved)
      expect(parent_body("alpha.txt")).to eq("reconciled alpha.txt\n")
    ensure
      lease&.release
    end
  end

  describe "the Null handoff releases and hands back nothing" do
    it "keeps the pre-wiring behaviour byte-for-byte: release, no handback, no spawn" do
      lease = clean_lease

      report = described_class::Null.reclaim(lease, worker_id: "worker-1")

      expect(report.kind).to eq(:nothing_to_do)
      expect(report.summary).to be_empty
      expect(lease).to be_released
      expect(parent_body("alpha.txt")).to eq("seed\n")
    ensure
      lease&.release
    end

    it "answers #surrender the same way, so an arm's ensure needs no nil guard" do
      lease = clean_lease

      expect(described_class::Null.surrender(lease, worker_id: "worker-1").kind).to eq(:nothing_to_do)
      expect(lease).to be_released
    ensure
      lease&.release
    end

    it "tolerates a lease that was never acquired" do
      expect(described_class::Null.reclaim(nil, worker_id: "worker-1").kind).to eq(:nothing_to_do)
      expect(handoff.reclaim(nil, worker_id: "worker-1").kind).to eq(:nothing_to_do)
      expect(handoff.surrender(nil, worker_id: "worker-1").kind).to eq(:nothing_to_do)
    end
  end

  describe "a handback the parent declines is reported, and nothing is spawned" do
    it "reports :declined without a resolver when the parent is dirty" do
      lease = clean_lease
      File.write(File.join(@repo_root, "beta.txt"), "uncommitted parent edit\n")

      report = handoff.reclaim(lease, worker_id: "worker-1")

      expect(report.kind).to eq(:declined)
      expect(resolver.spawns).to be_empty
      expect(report.summary).to include(report.ref)
    ensure
      lease&.release
    end

    # A parent already mid-merge from SOMEONE ELSE is D4's MID_MERGE decline, and
    # #restore must not abort it: that merge belongs to a sibling worker, and
    # unwinding it would be real damage.
    it "never aborts a merge it did not start" do
      first = conflicting_lease("alpha.txt")
      handoff.surrender(first, worker_id: "worker-1")
      first.release
      try_git(@repo_root, "merge", "--no-commit", "--no-ff", worker_refs.first)
      expect(merging?).to be(true)

      second = backend.acquire("worker-2")
      File.write(File.join(second.worker_env.cwd, "beta.txt"), "second worker\n")
      commit_all(second.worker_env.cwd, "second work")

      report = handoff.reclaim(second, worker_id: "worker-2")

      expect(report.kind).to eq(:declined)
      expect(merging?).to be(true)
    ensure
      first&.release
      second&.release
      run_git(@repo_root, "merge", "--abort")
    end
  end
end
