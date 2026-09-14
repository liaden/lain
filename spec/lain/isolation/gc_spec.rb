# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "mixlib/shellout"
require "open3"

# Operates on a THROWAWAY repo copied per example ({SeedRepo}) and a throwaway
# worktree root, never the lain repo it runs in or the real state dir.
RSpec.describe Lain::Isolation::Gc, :seam do
  around do |example|
    Dir.mktmpdir("lain-gc-repo") do |repo|
      Dir.mktmpdir("lain-gc-root") do |root|
        @repo_root = File.realpath(repo)
        @root = File.realpath(root)
        FileUtils.cp_r("#{SeedRepo.at("README" => "seed\n")}/.", @repo_root)
        run_git(@repo_root, "branch", "-M", "main")
        example.run
      end
    end
  end

  let(:now) { Time.now }
  let(:day) { 86_400 }

  def gc(retain_days: 7, at: now, journal: [], shell_out_factory: Lain::Shell::Out.public_method(:new))
    described_class.new(repo_root: @repo_root, root: @root, retain_days:, clock: -> { at }, journal:,
                        shell_out_factory:).call
  end

  def lock_of(dir)
    run_git(@repo_root, "worktree", "list", "--porcelain").split("\n\n")
                                                          .find { |entry| entry.start_with?("worktree #{dir}\n") }
                                                          .to_s[/^locked.*$/].to_s
  end

  # Runs `act` once, the first time gc shells out with `marker` in its argv:
  # another process acting between gc's look and gc's act.
  def interleaved(marker, &act)
    pending = [act]
    lambda do |*argv, **kwargs|
      pending.shift&.call if argv.include?(marker)
      Lain::Shell::Out.new(*argv, **kwargs)
    end
  end

  # Scrubbed exactly as the subject scrubs, so a pre-commit hook's exported
  # GIT_INDEX_FILE cannot point these at lain's own index.
  def run_git(dir, *args)
    shell = Mixlib::ShellOut.new("git", "-C", dir, *args, environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
    shell.run_command.error!
    shell.stdout
  end

  def try_git(dir, *args)
    Mixlib::ShellOut.new("git", "-C", dir, *args, environment: Lain::Isolation::Worktree::GIT_CONTEXT_SCRUB)
                    .run_command
  end

  def sha(rev, dir: @repo_root) = run_git(dir, "rev-parse", rev).strip

  def ref?(ref) = try_git(@repo_root, "rev-parse", "--verify", "--quiet", ref).exitstatus.zero?

  def refs(prefix) = run_git(@repo_root, "for-each-ref", "--format=%(refname)", prefix).split("\n")

  def registered = run_git(@repo_root, "worktree", "list", "--porcelain").scan(/^worktree (.*)$/).flatten

  def dead_pid = Process.spawn("true").tap { |pid| Process.wait(pid) }

  def dead_table = Lain::Isolation::LeaseLock::ProcessTable.new(pid: dead_pid)

  def branch(name)
    Lain::Isolation::WorkingBranch.new(name, repo_root: @repo_root,
                                             git: Lain::Isolation::Checkout.new(@repo_root))
  end

  # A worker checkout exactly as lain cuts one, whose lease lock names a
  # process that has already exited: what a crash leaves behind.
  def backend(base: branch("main"), table: dead_table)
    Lain::Isolation::Worktree.new(repo_root: @repo_root, root: @root, base:, process_table: table)
  end

  def lease(worker, **) = backend(**).acquire(worker).worker_env.cwd

  def commit_in(dir, file, content)
    File.write(File.join(dir, file), content)
    run_git(dir, "add", file)
    run_git(dir, "commit", "-q", "-m", "#{file} in #{File.basename(dir)}")
    sha("HEAD", dir:)
  end

  # A leased checkout whose own commit main has since taken: work that landed,
  # rather than a checkout still standing where it was cut.
  def landed_lease(worker, **)
    lease(worker, **).tap { |dir| run_git(@repo_root, "merge", "-q", "--ff-only", commit_in(dir, "landed.txt", "l\n")) }
  end

  def record_for(records, name) = records.find { |record| record.name == name }

  def summary(record) = [record.action, record.subject, record.reason]

  describe "a folded worker" do
    it "reaps its anchor and its worktree, recording that both folded into the working branch" do
      run_git(@repo_root, "switch", "-q", "-c", "feat")
      dir = lease("w1", base: branch("feat"))
      work = commit_in(dir, "work.txt", "w1\n")
      run_git(@repo_root, "update-ref", "refs/lain/worker/w1", work)
      run_git(@repo_root, "merge", "-q", "--ff-only", work)

      records = gc

      expect([File.exist?(dir), ref?("refs/lain/worker/w1")]).to eq([false, false])
      expect(summary(record_for(records, dir))).to eq([:reaped, :worktree, "folded into feat"])
      expect(summary(record_for(records, "refs/lain/worker/w1"))).to eq([:reaped, :anchor, "folded into feat"])
    end

    it "calls work reachable from main landed" do
      dir = landed_lease("w1")

      expect(summary(record_for(gc, dir))).to eq([:reaped, :worktree, "landed on main"])
    end
  end

  # lain's landing checkout is cut on the epic's branch at main's tip, and
  # main reaching its HEAD says nothing about whether it is still in use.
  describe "a checkout still at the commit it was cut at" do
    def fresh_checkout
      Lain::Isolation::WorkingBranch.epic("fresh", repo_root: @repo_root)
      File.join(@root, "landing").tap { |dir| run_git(@repo_root, "worktree", "add", "-q", dir, "epic/fresh") }
    end

    it "is kept, and the report says nothing has landed since it was cut" do
      dir = fresh_checkout

      record = record_for(gc, dir)

      expect(File.directory?(dir)).to be(true)
      expect(summary(record)).to match([:kept, :worktree,
                                        a_string_starting_with("nothing has landed since it was cut")])
    end

    it "is kept after a detached HEAD moves nowhere, and reaped as landed once HEAD moves on" do
      dir = lease("w1")
      run_git(dir, "switch", "-q", "--detach")

      kept = record_for(gc, dir)
      commit_in(dir, "moved.txt", "moved\n").then { |moved| run_git(@repo_root, "merge", "-q", "--ff-only", moved) }
      reaped = record_for(gc, dir)

      expect(summary(kept)).to match([:kept, :worktree, a_string_starting_with("nothing has landed since it was cut")])
      expect(summary(reaped)).to eq([:reaped, :worktree, "landed on main"])
    end

    # gc keeps what it cannot judge: with no reflog, nothing shows HEAD moved.
    # Detached, so git has no branch reflog to answer in its place.
    it "is kept when its HEAD reflog is gone, rather than reaped as landed" do
      dir = lease("w1")
      FileUtils.rm_f(File.join(admin_of(dir), "logs", "HEAD"))

      record = record_for(gc, dir)

      expect(File.directory?(dir)).to be(true)
      expect(summary(record)).to match([:kept, :worktree, a_string_including("retained until")])
      expect(record.reason).not_to include("landed on")
    end

    it "is kept when the repository keeps no reflogs at all" do
      run_git(@repo_root, "config", "core.logAllRefUpdates", "false")
      dir = lease("w1")

      record = record_for(gc, dir)

      expect([File.directory?(dir), record.action]).to eq([true, :kept])
    end

    it "is reaped once it expires, without being called landed" do
      dir = fresh_checkout

      record = record_for(gc(at: now + (8 * day)), dir)

      expect(File.exist?(dir)).to be(false)
      expect(summary(record)).to eq([:reaped, :worktree, "expired after 7 days with nothing landed since it was cut"])
    end
  end

  describe "an expired worktree" do
    it "is removed only after an anchor keeps the commit nothing else reaches" do
      dir = lease("w1")
      lost = commit_in(dir, "lost.txt", "only here\n")

      records = gc(at: now + (8 * day))
      record = record_for(records, dir)

      expect(File.exist?(dir)).to be(false)
      expect(record.action).to eq(:kept)
      expect(record.anchors.map { |ref| sha(ref) }).to eq([lost])
      expect(record.anchors).to all(start_with("refs/lain/worker/"))
    end

    it "is kept, with its unmerged commits, while it is younger than retain_days" do
      dir = lease("w1")
      commit_in(dir, "young.txt", "young\n")

      record = record_for(gc(at: now + (6 * day)), dir)

      expect(File.directory?(dir)).to be(true)
      expect([record.action, record.reason]).to match([:kept, a_string_starting_with("unmerged commits")])
    end
  end

  describe "uncommitted work" do
    it "keeps a young dirty worktree, whatever its commits" do
      dir = lease("w1")
      File.write(File.join(dir, "README"), "edited\n")

      record = record_for(gc(at: now + day), dir)

      expect(File.read(File.join(dir, "README"))).to eq("edited\n")
      expect([record.action, record.reason]).to match([:kept, a_string_starting_with("uncommitted changes")])
    end

    # The snapshot covers tracked AND untracked files, built through a
    # temporary index so neither the checkout's own index nor the shared stash
    # stack is touched.
    it "anchors the committed HEAD and a snapshot of the whole working state before removing an expired one" do
      dir = lease("w1")
      head = commit_in(dir, "committed.txt", "committed\n")
      File.write(File.join(dir, "README"), "edited\n")
      File.write(File.join(dir, "untracked.txt"), "untracked\n")
      stashes = refs("refs/stash")

      record = record_for(gc(at: now + (8 * day)), dir)
      snapshot = record.anchors.find { |ref| sha(ref) != head }

      expect(File.exist?(dir)).to be(false)
      expect(record.action).to eq(:kept)
      expect(record.anchors.map { |ref| sha(ref) }).to include(head)
      expect(sha("#{snapshot}^")).to eq(head)
      expect(run_git(@repo_root, "show", "#{snapshot}:untracked.txt")).to eq("untracked\n")
      expect(run_git(@repo_root, "show", "#{snapshot}:README")).to eq("edited\n")
      expect(refs("refs/stash")).to eq(stashes)
    end

    it "ages a checkout retained on release from the moment it was retained" do
      retaining = backend(table: Lain::Isolation::LeaseLock::ProcessTable.new)
      lease = retaining.acquire("w1")
      dir = lease.worker_env.cwd
      File.write(File.join(dir, "README"), "edited\n")
      lease.release

      young = record_for(gc(at: now + (6 * day)), dir)
      expired = record_for(gc(at: now + (8 * day)), dir)

      expect([young.action, young.reason]).to match([:kept, a_string_starting_with("uncommitted changes")])
      expect([expired.action, File.exist?(dir)]).to eq([:kept, false])
      expect(run_git(@repo_root, "show", "#{expired.anchors.last}:README")).to eq("edited\n")
    end
  end

  describe "liveness" do
    it "never touches a worktree whose lease names a live process, and reaps a dead one's" do
      live = lease("w-live", table: Lain::Isolation::LeaseLock::ProcessTable.new)
      dead = lease("w-dead")

      records = gc(at: now + (30 * day))

      expect([File.directory?(live), File.exist?(dead)]).to eq([true, false])
      expect(summary(record_for(records, live)))
        .to eq([:kept, :worktree, "leased by live process #{Process.pid} on #{Socket.gethostname}"])
      expect(record_for(records, dead).action).to eq(:reaped)
    end

    it "keeps a worktree locked by something lain did not write, or leased on another host" do
      foreign = File.join(@root, "foreign")
      elsewhere = File.join(@root, "elsewhere")
      run_git(@repo_root, "worktree", "add", "-q", "--lock", "--reason", "someone else's", "--detach", foreign, "main")
      run_git(@repo_root, "worktree", "add", "-q", "--lock", "--reason", "lain-lease pid=1 start=- host=far.invalid",
              "--detach", elsewhere, "main")

      records = gc(at: now + (30 * day))

      expect([File.directory?(foreign), File.directory?(elsewhere)]).to eq([true, true])
      expect(summary(record_for(records, foreign)))
        .to eq([:kept, :worktree, "locked by something lain did not write (\"someone else's\")"])
      expect(summary(record_for(records, elsewhere))).to eq([:kept, :worktree, "leased on another host (far.invalid)"])
    end

    it "reaps an unlocked worktree under its root as a crash's leftover" do
      legacy = File.join(@root, "legacy")
      run_git(@repo_root, "worktree", "add", "-q", "--detach", legacy, "main")
      run_git(@repo_root, "merge", "-q", "--ff-only", commit_in(legacy, "legacy.txt", "legacy\n"))

      expect(summary(record_for(gc, legacy))).to eq([:reaped, :worktree, "landed on main"])
      expect(File.exist?(legacy)).to be(false)
    end
  end

  describe "scope" do
    it "never touches, or reports, a worktree outside lain's root" do
      Dir.mktmpdir("lain-gc-outside") do |outside|
        foreign = File.join(File.realpath(outside), "human")
        run_git(@repo_root, "worktree", "add", "-q", "--detach", foreign, "main")

        records = gc(at: now + (30 * day))

        expect(registered).to include(foreign)
        expect(record_for(records, foreign)).to be_nil
      ensure
        try_git(@repo_root, "worktree", "remove", "--force", foreign)
      end
    end

    it "keeps an anchor whose commit no branch reaches" do
      tree = sha("main^{tree}")
      orphan = run_git(@repo_root, "commit-tree", tree, "-p", "main", "-m", "orphan").strip
      run_git(@repo_root, "update-ref", "refs/lain/worker/lonely", orphan)

      record = record_for(gc(at: now + (30 * day)), "refs/lain/worker/lonely")

      expect(ref?("refs/lain/worker/lonely")).to be(true)
      expect(summary(record)).to eq([:kept, :anchor, "no branch reaches #{orphan[0, 12]}"])
    end
  end

  describe "working branches" do
    def land_on(name, file)
      run_git(@repo_root, "switch", "-q", name)
      File.write(File.join(@repo_root, file), "#{file}\n")
      run_git(@repo_root, "add", file)
      run_git(@repo_root, "commit", "-q", "-m", file)
      run_git(@repo_root, "switch", "-q", "main")
      run_git(@repo_root, "merge", "-q", "--no-edit", name)
    end

    it "deletes a merged epic branch only if lain created it, marker with it" do
      Lain::Isolation::WorkingBranch.epic("demo", repo_root: @repo_root)
      run_git(@repo_root, "branch", "topic/x")
      land_on("epic/demo", "epic.txt")
      land_on("topic/x", "topic.txt")

      records = gc

      expect([ref?("refs/heads/epic/demo"), ref?("refs/lain/owned/heads/epic/demo")]).to eq([false, false])
      expect(ref?("refs/heads/topic/x")).to be(true)
      expect(summary(record_for(records, "refs/heads/epic/demo"))).to eq([:reaped, :branch, "merged into main"])
      expect(record_for(records, "refs/heads/topic/x")).to be_nil
    end

    # A new epic branch starts at main's tip, so it is an ancestor of main the
    # moment it exists; the marker's recorded SHA is what tells the two apart.
    it "keeps an epic branch nothing has landed on since lain created it" do
      Lain::Isolation::WorkingBranch.epic("fresh", repo_root: @repo_root)

      record = record_for(gc, "refs/heads/epic/fresh")

      expect(ref?("refs/heads/epic/fresh")).to be(true)
      expect(summary(record)).to eq([:kept, :branch, "nothing has landed on it since lain created it"])
    end

    it "keeps a merged epic branch that is checked out" do
      Lain::Isolation::WorkingBranch.epic("busy", repo_root: @repo_root)
      land_on("epic/busy", "busy.txt")
      run_git(@repo_root, "switch", "-q", "epic/busy")

      record = record_for(gc, "refs/heads/epic/busy")

      expect(ref?("refs/heads/epic/busy")).to be(true)
      expect(summary(record)).to eq([:kept, :branch, "checked out at #{@repo_root}"])
    end

    it "keeps an epic branch that has not been merged into main" do
      Lain::Isolation::WorkingBranch.epic("open", repo_root: @repo_root)
      run_git(@repo_root, "switch", "-q", "epic/open")
      commit_in(@repo_root, "open.txt", "open\n")
      run_git(@repo_root, "switch", "-q", "main")

      expect(summary(record_for(gc, "refs/heads/epic/open"))).to eq([:kept, :branch, "not merged into main"])
    end

    it "drops a marker whose branch a human already deleted" do
      Lain::Isolation::WorkingBranch.epic("gone", repo_root: @repo_root)
      run_git(@repo_root, "branch", "-D", "epic/gone")

      record = record_for(gc, "refs/lain/owned/heads/epic/gone")

      expect(ref?("refs/lain/owned/heads/epic/gone")).to be(false)
      expect(summary(record)).to eq([:reaped, :branch, "its branch no longer exists"])
    end
  end

  describe "a judgement gone stale before gc acts" do
    it "keeps a checkout whose lock changed after it was judged, and leaves the new holder's tree alone" do
      dir = lease("w1")
      live = backend(table: Lain::Isolation::LeaseLock::ProcessTable.new)
      factory = interleaved("--contains") do
        live.acquire("w1")
        File.write(File.join(dir, "live-work.txt"), "a live worker's file\n")
      end

      record = record_for(gc(at: now + (8 * day), shell_out_factory: factory), dir)

      expect(File.read(File.join(dir, "live-work.txt"))).to eq("a live worker's file\n")
      expect(lock_of(dir)).to start_with("locked lain-lease pid=#{Process.pid} ")
      expect(summary(record)).to eq([:kept, :worktree, "its lock changed while gc ran"])
    end

    it "never unlocks a tree it judged unlocked" do
      legacy = File.join(@root, "legacy")
      run_git(@repo_root, "worktree", "add", "-q", "--detach", legacy, "main")
      run_git(@repo_root, "merge", "-q", "--ff-only", commit_in(legacy, "legacy.txt", "legacy\n"))
      factory = interleaved("--contains") { run_git(@repo_root, "worktree", "lock", "--reason", "a human's", legacy) }

      record = record_for(gc(shell_out_factory: factory), legacy)

      expect([File.directory?(legacy), lock_of(legacy), record.action]).to eq([true, "locked a human's", :kept])
    end

    it "keeps a vanished checkout's registration when a live lease takes its path meanwhile" do
      dir = lease("w1")
      FileUtils.rm_rf(dir)
      live = backend(table: Lain::Isolation::LeaseLock::ProcessTable.new)
      factory = interleaved("--contains") { live.acquire("w1") }

      record = record_for(gc(shell_out_factory: factory), dir)

      expect(File.directory?(dir)).to be(true)
      expect(lock_of(dir)).to start_with("locked lain-lease pid=#{Process.pid} ")
      expect(record.action).to eq(:kept)
    end
  end

  # git's own admin directory for a checkout, read off the checkout's `.git`
  # pointer, which may be relative.
  def admin_of(dir) = File.expand_path(File.read(File.join(dir, ".git"))[/\Agitdir: (.+)$/, 1], dir)

  describe "the lock itself" do
    # Nothing but git stands between the claim and the removal: a lock taken
    # in that moment makes `worktree remove` refuse, and the tree stays.
    it "is what git refuses to remove over, so a lock taken after the claim still guards the tree" do
      dir = landed_lease("w1")
      factory = interleaved("remove") { run_git(@repo_root, "worktree", "lock", "--reason", "after the claim", dir) }

      record = record_for(gc(shell_out_factory: factory), dir)

      expect([File.directory?(dir), lock_of(dir)]).to eq([true, "locked after the claim"])
      expect(record.reason).to start_with("git would not remove it: fatal: cannot remove a locked working tree")
      expect(record.reason).not_to include("\n")
    end

    it "is found under worktree.useRelativePaths, where git records the paths relative to each other" do
      run_git(@repo_root, "config", "worktree.useRelativePaths", "true")
      dir = landed_lease("w1")

      expect(File.read(File.join(dir, ".git"))).to start_with("gitdir: ..")
      expect(summary(record_for(gc, dir))).to eq([:reaped, :worktree, "landed on main"])
    end

    # A crash between taking a lock and putting it back leaves the taken file
    # and no `locked`: the tree would read as unlocked, and be reaped live.
    it "keeps a checkout beside an interrupted claim, putting the taken lock back where none stands" do
      dir = lease("w1", table: Lain::Isolation::LeaseLock::ProcessTable.new)
      admin = admin_of(dir)
      File.rename(File.join(admin, "locked"), File.join(admin, "locked.lain-claim-deadbeef0000"))

      record = record_for(gc, dir)

      expect([File.directory?(dir), lock_of(dir)]).to match([true, a_string_starting_with("locked lain-lease pid=")])
      reason = "an interrupted lock claim (locked.lain-claim-deadbeef0000) was put back as its lock"
      expect(summary(record)).to eq([:kept, :worktree, reason])
    end

    it "leaves an interrupted claim and a newer lock both alone, and keeps the checkout" do
      dir = lease("w1")
      admin = admin_of(dir)
      FileUtils.cp(File.join(admin, "locked"), File.join(admin, "locked.lain-claim-deadbeef0000"))

      record = record_for(gc, dir)

      expect(Dir.children(admin)).to include("locked", "locked.lain-claim-deadbeef0000")
      expect([File.directory?(dir), record.action]).to eq([true, :kept])
      expect(record.reason).to include("sits beside a newer lock")
    end

    it "says a multi-line git refusal on one line" do
      dir = lease("w1")
      blob = run_git(@repo_root, "rev-parse", "HEAD:README").strip
      stages = (1..3).map { |stage| "100644 #{blob} #{stage}\tREADME\n" }.join
      Open3.capture3({ "GIT_INDEX_FILE" => nil }, "git", "-C", dir, "update-index", "--index-info", stdin_data: stages)

      record = record_for(gc(at: now + (8 * day)), dir)

      expect(File.directory?(dir)).to be(true)
      expect(record.reason).to start_with("expired, but left on disk: git write-tree failed")
      expect(record.reason).not_to include("\n")
    end
  end

  describe "a checkout whose directory is gone" do
    it "anchors its unreached HEAD before dropping its registration" do
      dir = lease("w1")
      head = commit_in(dir, "only.txt", "only here\n")
      FileUtils.rm_rf(dir)

      record = record_for(gc, dir)

      expect(registered).not_to include(dir)
      expect([record.action, record.anchors.map { |ref| sha(ref) }]).to eq([:kept, [head]])
    end

    it "drops the registration of one whose HEAD a branch reaches" do
      dir = lease("w1")
      FileUtils.rm_rf(dir)

      expect(record_for(gc, dir).action).to eq(:reaped)
      expect(registered).not_to include(dir)
    end
  end

  describe "a checkout git cannot read" do
    it "counts as holding uncommitted work, so it is kept" do
      dir = lease("w1")
      File.write(File.join(dir, "untracked.txt"), "worker output\n")
      File.write(run_git(dir, "rev-parse", "--path-format=absolute", "--git-path", "index").strip, "garbage")

      record = record_for(gc, dir)

      expect([File.exist?(File.join(dir, "untracked.txt")), record.action]).to eq([true, :kept])
    end
  end

  describe "the snapshot" do
    it "records the index as a second parent, so staged content the working copy moved past survives" do
      dir = lease("w1")
      File.write(File.join(dir, "README"), "staged\n")
      run_git(dir, "add", "README")
      File.write(File.join(dir, "README"), "working\n")

      snapshot = record_for(gc(at: now + (8 * day)), dir).anchors.last

      expect(run_git(@repo_root, "show", "#{snapshot}:README")).to eq("working\n")
      expect(run_git(@repo_root, "show", "#{snapshot}^2:README")).to eq("staged\n")
    end

    it "keeps on disk, and says why, a checkout holding a nested repository" do
      dir = lease("w1")
      nested = File.join(dir, "vendor", "nested")
      FileUtils.mkdir_p(nested)
      run_git(nested, "init", "-q", "-b", "main")
      File.write(File.join(nested, "inner.txt"), "inner work\n")
      run_git(nested, "add", "inner.txt")
      run_git(nested, "-c", "user.name=p", "-c", "user.email=p@p", "commit", "-q", "-m", "inner")

      record = record_for(gc(at: now + (8 * day)), dir)

      expect(File.read(File.join(nested, "inner.txt"))).to eq("inner work\n")
      expect(summary(record)).to match([:kept, :worktree, a_string_including("nested repository at vendor/nested")])
    end

    it "leaves ignored files out, and says so" do
      File.write(File.join(@repo_root, ".gitignore"), "*.log\n")
      run_git(@repo_root, "add", ".gitignore")
      run_git(@repo_root, "commit", "-q", "-m", "ignore logs")
      dir = lease("w1")
      File.write(File.join(dir, "notes.log"), "ignored\n")
      File.write(File.join(dir, "kept.txt"), "kept\n")

      record = record_for(gc(at: now + (8 * day)), dir)

      expect(record.reason).to include("ignored files are not kept")
      expect(try_git(@repo_root, "cat-file", "-e", "#{record.anchors.last}:notes.log").exitstatus).not_to eq(0)
    end
  end

  describe "a branch in use elsewhere" do
    it "keeps a merged epic branch that another worktree is part-way through rebasing" do
      Lain::Isolation::WorkingBranch.epic("r", repo_root: @repo_root)
      run_git(@repo_root, "switch", "-q", "epic/r")
      commit_in(@repo_root, "one.txt", "one\n")
      run_git(@repo_root, "switch", "-q", "main")
      run_git(@repo_root, "merge", "-q", "--ff-only", "epic/r")
      run_git(@repo_root, "switch", "-q", "-c", "up")
      commit_in(@repo_root, "up.txt", "up\n")
      run_git(@repo_root, "switch", "-q", "main")
      Dir.mktmpdir("lain-gc-rebase") do |outside|
        wt = File.join(File.realpath(outside), "rebase-wt")
        run_git(@repo_root, "worktree", "add", "-q", wt, "epic/r")
        commit_in(wt, "two.txt", "two\n")
        run_git(@repo_root, "merge", "-q", "--ff-only", "epic/r")
        try_git(wt, "-c", "core.editor=true", "rebase", "-q", "-x", "false", "up")

        record = record_for(gc, "refs/heads/epic/r")

        expect(ref?("refs/heads/epic/r")).to be(true)
        expect(summary(record)).to eq([:kept, :branch, "being rebased at #{wt}"])
      ensure
        try_git(@repo_root, "worktree", "remove", "--force", wt)
      end
    end

    it "judges merged against the trunk branch, never a tag of the same name" do
      Lain::Isolation::WorkingBranch.epic("tagged", repo_root: @repo_root)
      run_git(@repo_root, "switch", "-q", "epic/tagged")
      commit_in(@repo_root, "t.txt", "t\n")
      run_git(@repo_root, "switch", "-q", "main")
      run_git(@repo_root, "tag", "main", "epic/tagged")

      expect(summary(record_for(gc, "refs/heads/epic/tagged"))).to eq([:kept, :branch, "not merged into main"])
    end
  end

  describe "running twice" do
    it "reaps nothing the second time" do
      run_git(@repo_root, "switch", "-q", "-c", "feat")
      folded = lease("folded", base: branch("feat"))
      run_git(@repo_root, "merge", "-q", "--ff-only", commit_in(folded, "f.txt", "f\n"))
      commit_in(lease("expired", base: branch("feat")), "e.txt", "e\n")
      run_git(@repo_root, "switch", "-q", "main")
      Lain::Isolation::WorkingBranch.epic("demo", repo_root: @repo_root)

      gc(at: now + (8 * day))
      before = [registered, refs("refs/")]
      again = gc(at: now + (8 * day))

      expect(again.map(&:action)).to all(eq(:kept))
      expect([registered, refs("refs/")]).to eq(before)
    end
  end

  it "journals every reap and keep it answers" do
    lease("w1")
    journal = []

    records = gc(journal:)

    expect(journal).to eq(records)
    expect(journal).to all(be_a(Lain::Telemetry::WorktreeReap))
  end
end
