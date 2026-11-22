# frozen_string_literal: true

require "async"
require "fileutils"
require "monitor"
require "tmpdir"

# A REAL isolation backend, small enough to live beside the examples that drive
# it: every acquire provisions an actual directory named for the worker and
# hands back a lease whose cwd points there, and release removes it. Not a
# stand-in for the duck -- what these examples are about is the lease
# LIFECYCLE, and {Lain::Isolation::Worktree} costs five git subprocesses per
# lease to say the same thing.
#
# It keeps Worktree's one-live-lease-per-path refusal, so a worker-id allocator
# that handed two live holds one id fails as loudly here as it would there.
class LeasesSpecIsolation
  # `high_water` is how many leases were live at once at the busiest moment --
  # the only way an example can tell genuine simultaneity from N holds that
  # merely happened in one reactor, and what arms the already-leased refusal.
  attr_reader :worker_ids, :leased, :released, :high_water

  # `reclaim: :refuse` is {Lain::Isolation::Worktree}'s real teardown failure:
  # `#remove` raises rather than leave a checkout it could not reclaim standing.
  def initialize(root, reclaim: :succeed)
    @root = root
    @reclaim = reclaim
    @worker_ids = []
    @leased = []
    @released = []
    @live = []
    @high_water = 0
    @monitor = Monitor.new
  end

  def acquire(worker_id)
    path = File.join(@root, worker_id.to_s)
    @monitor.synchronize do
      raise Lain::Error, "#{path} is already leased" if @live.include?(path)

      claim(path, worker_id)
    end
    Lain::Isolation::Lease.new(worker_env: Lain::WorkerEnv.default.with(cwd: path),
                               on_release: -> { give_back(path) })
  end

  private

  def claim(path, worker_id)
    FileUtils.mkdir_p(path)
    @live << path
    @worker_ids << worker_id.to_s
    @leased << path
    @high_water = [@high_water, @live.size].max
  end

  def give_back(path)
    @monitor.synchronize do
      @live.delete(path)
      raise Lain::Error, "could not reclaim #{path}" if @reclaim == :refuse

      @released << path
    end
  end
end

# What a stopped child's dispatch raises past the lease it kept.
class LeasesSpecStopped < StandardError; end

# Where a child's execution environment is leased FROM, driven directly. The
# same object reached through a spawn is spec/lain/tools/subagent_spec.rb's
# subject: what is here is the lease LIFECYCLE and the worker-id sequence, which
# a dispatch is only one caller of.
RSpec.describe Lain::Isolation::Leases do
  around do |example|
    Dir.mktmpdir("lain-leases") do |dir|
      @leases_root = dir
      example.run
    end
  end

  attr_reader :leases_root

  let(:backend) { LeasesSpecIsolation.new(leases_root) }
  let(:leases) { described_class.new(backend:) }
  let(:journal) { Lain::Channel.new }

  # The whole lifetime, with nothing else in the way: one acquire, the block
  # under the leased environment, one release. The lease is taken
  # UNCONDITIONALLY -- {Lain::Isolation::Null} hands back WorkerEnv.default and
  # reclaims nothing -- so there is no `if isolation` anywhere to get backwards.
  it "leases an environment for the block, and gives it back once" do
    held = leases.hold("subagent", journal:) { |worker_env, _sync| worker_env.cwd }

    expect(held.value).to eq(backend.leased.first)
    expect(backend.released).to eq(backend.leased)
    expect(backend.leased.size).to eq(1)
    expect(journal.drain).to be_empty
  end

  # A reviewer's record is keyed by the commit its checkout was cut from, which only the lease knows.
  it "hands the block the origin its lease was cut from" do
    origin = Lain::Isolation::Lease::Origin.new(path: leases_root, base: "c0ffee", branch: "lain/issue/demo/a")
    cut = Object.new
    cut.define_singleton_method(:acquire) do |_worker|
      Lain::Isolation::Lease.new(worker_env: Lain::WorkerEnv.default.with(cwd: origin.path), origin:)
    end

    held = described_class.new(backend: cut).hold("subagent", journal:) { |*, origin_seen| origin_seen }

    expect(held.value).to eq(origin)
  end

  # The teardown that FAILS. {Lain::Isolation::Worktree#remove} raises rather
  # than leave a checkout it could not reclaim standing, and `Tool#call` does
  # not rescue -- so a bare `ensure lease.release` would hand a caller the
  # teardown failure instead of the answer its block already paid for. The
  # failure is journaled rather than swallowed, because a checkout that outlived
  # its lease is a real leak and the record is where its key is found.
  it "reports a lease it could not reclaim, and still answers with the block's value" do
    refusing = described_class.new(backend: LeasesSpecIsolation.new(leases_root, reclaim: :refuse))

    held = refusing.hold("subagent", journal:) { "the block's answer" }

    expect(held.value).to eq("the block's answer")
    leaks = journal.drain.grep(Lain::Isolation::LeaseNotReclaimed)
    expect(leaks.map(&:worker_key)).to eq([Lain::Isolation::WorkerId.spawned(role: "subagent", ordinal: 1).to_s])
    # `error` is the half a human can act on: the worker key is hashed into the
    # path, so what names the directory still standing is the backend's own
    # message.
    expect(leaks.map(&:error)).to all(include(leases_root))
  end

  # A dispatch that raised is surrendered, and what the sync reads off the
  # checkout rides that surrender as it rides a reclaim: a worker that wrote a
  # file and then hit its ceiling left uncommitted work, and a surrender told
  # nothing synced would record the checkout as clean. Nobody is asked -- the
  # child that would be asked is the one that just failed.
  describe "the sync on a dispatch that did not return" do
    let(:calls) { [] }
    let(:outcome) { Lain::Isolation::SelfSync::Result.new(outcome: :dirty, dirty: true, path: "/checkout") }
    let(:sync) do
      recorded = calls
      found = outcome
      Class.new do
        define_method(:call) do |_lease, worker:, worker_id:|
          recorded << [:sync, worker_id, worker.askable?]
          found
        end
        define_method(:unasked) do |_lease, worker_id:|
          recorded << [:unasked, worker_id]
          found
        end
        define_method(:editorless) { |worker_env| worker_env }
      end.new
    end
    let(:handoff) do
      recorded = calls
      Class.new do
        define_method(:surrender) do |lease, worker_id:, sync:|
          recorded << [:surrender, worker_id, sync]
          lease.release
          Lain::Isolation::WorkerHandoff::Report.nothing
        end
      end.new
    end
    let(:syncing) { described_class.new(backend:, handoff:, sync:) }
    let(:worker) { Lain::Isolation::WorkerId.spawned(role: "subagent", ordinal: 1).to_s }

    it "syncs the checkout of a block that raised, asking nobody, and surrenders with what it found" do
      expect { syncing.hold("subagent", journal:) { raise Lain::Error, "the ceiling" } }
        .to raise_error(Lain::Error, "the ceiling")

      expect(calls).to eq([[:unasked, worker], [:surrender, worker, outcome]])
    end

    it "syncs a stopped block's checkout too" do
      Sync do |task|
        parked = task.async { syncing.hold("subagent", journal:) { sleep } }
        task.yield
        parked.stop
      end

      expect(calls).to eq([[:unasked, worker], [:surrender, worker, outcome]])
    end

    # The fast checks ask the worker to fix its red, and run for as long as
    # the project's check takes: neither belongs in a teardown.
    it "never runs the checks for a dispatch that did not return" do
      checks = Class.new do
        attr_reader :ran

        def call(*, **) = (@ran = true)
      end.new
      checked = described_class.new(backend:, handoff:, sync: Lain::Isolation::Checked.new(checks:, sync:))

      expect { checked.hold("subagent", journal:) { raise Lain::Error, "the ceiling" } }
        .to raise_error(Lain::Error, "the ceiling")

      expect(checks.ran).to be_nil
      expect(calls).to eq([[:unasked, worker], [:surrender, worker, outcome]])
    end

    # The sync is git subprocesses, so a suspension point, and a second stop --
    # an ancestor task or a reactor teardown landing on a run already
    # unwinding -- used to land in it and skip the handoff, leaving the lease
    # unreleased and no handback on the record.
    it "still surrenders when a second stop lands while the unasked sync runs" do
      entered = false
      recorded = calls
      slow = Class.new do
        define_method(:unasked) do |_lease, worker_id:|
          entered = true
          sleep 0.2
          recorded << [:sync, worker_id]
          Lain::Isolation::SelfSync::Result::NONE
        end
        define_method(:editorless) { |worker_env| worker_env }
      end.new
      leases = described_class.new(backend:, handoff:, sync: slow)

      Sync do |task|
        held = task.async { leases.hold("subagent", journal:) { sleep } }
        task.yield
        held.stop
        pumped_until(task, timeout: 2) { entered }
        held.stop
        task.sleep(0.4)
      end

      expect(calls.map(&:first)).to eq(%i[sync surrender])
      expect(backend.released).to eq(backend.leased)
    end

    it "does not sync again a block that synced before it raised" do
      expect do
        syncing.hold("subagent", journal:) do |_worker_env, synced|
          synced.call(Lain::Isolation::SelfSync::Unaskable)
          raise Lain::Error, "after the sync"
        end
      end.to raise_error(Lain::Error, "after the sync")

      expect(calls.map(&:first)).to eq(%i[sync surrender])
    end

    it "syncs nothing and surrenders nothing when the acquire itself refused" do
      refused = described_class.new(backend: Class.new { def acquire(_id) = raise(Lain::Error, "refused") }.new,
                                    handoff:, sync:)

      expect { refused.hold("subagent", journal:) { :unreached } }.to raise_error(Lain::Error, "refused")
      expect(calls).to eq([])
    end
  end

  # The surrender is the one place that knows where a failed worker's commits
  # went, and the parent is reading the error, so the error carries it.
  describe "the handback of a dispatch that raised" do
    let(:calls) { [] }
    let(:report) do
      Lain::Isolation::WorkerHandoff::Report.new(kind: :queued, ref: "refs/lain/worker/subagent-spawn.1")
    end
    let(:handoff) do
      recorded = calls
      told = report
      Class.new do
        define_method(:surrender) do |lease, worker_id:, sync:|
          recorded << [:surrender, worker_id, sync]
          lease.release
          told
        end
      end.new
    end
    let(:leases) { described_class.new(backend:, handoff:) }

    def ceiling = Lain::Budget::Exceeded.new("loop ran 2 iterations, ceiling is 2", kind: :iterations)

    it "appends where the commits went, keeping the error's class and kind" do
      expect { leases.hold("subagent", journal:) { raise ceiling } }.to raise_error do |error|
        expect(error).to be_a(Lain::Budget::Exceeded)
        expect(error.kind).to eq(:iterations)
        expect(error.message).to eq("loop ran 2 iterations, ceiling is 2\n\n" \
                                    "[the worker's commits are on refs/lain/worker/subagent-spawn.1, " \
                                    "not yet on the branch]")
      end
    end

    it "surrenders once" do
      expect { leases.hold("subagent", journal:) { raise ceiling } }.to raise_error(Lain::Budget::Exceeded)

      expect(calls.map(&:first)).to eq([:surrender])
    end

    it "leaves the message alone when nothing was handed back" do
      nothing = described_class.new(backend:, handoff: Class.new do
        def surrender(lease, **) = lease.release.then { Lain::Isolation::WorkerHandoff::Report.nothing }
      end.new)

      expect { nothing.hold("subagent", journal:) { raise ceiling } }
        .to raise_error(Lain::Budget::Exceeded, "loop ran 2 iterations, ceiling is 2")
    end
  end

  # A lane names where this pool's workers are numbered. Every worktree of one
  # repository shares refs/lain/worker/, so two lanes' worker 1 must not spell
  # one id.
  describe "the lane it numbers its workers in", :seam do
    let(:lane) { described_class::Lane }

    it "prefixes a named lane's worker ids, and leaves the unnamed lane's bare" do
      expect(lane.named("issue.demo.a").worker(role: "subagent", ordinal: 1)).to eq("issue.demo.a.subagent-spawn.1")
      expect(lane::UNNAMED.worker(role: "subagent", ordinal: 1)).to eq("subagent-spawn.1")
    end

    it "refuses a name git would not accept in a ref, rather than escaping it" do
      ["bad lane", "a..b", "issue.lock", "", "x~1", ".hidden"].each do |name|
        expect { lane.named(name) }.to raise_error(lane::Refused, /cannot name a ref/)
      end
    end
  end

  # A lease its caller already holds, lent to one dispatch in place of a new
  # one: nothing here acquires, syncs or reclaims, because the holder hands
  # the checkout back when its own work is done.
  describe "a lease lent in place" do
    # A lent lease admits ONE dispatch at a time: two children writing in one
    # checkout at once each see the other's half-written tree, and `within` is
    # public, so call order is not a guarantee anything can rest on.
    it "admits one dispatch at a time, so two children never hold the checkout together" do
      place = described_class::InPlace.new(worker_env: Lain::WorkerEnv.default.with(cwd: leases_root))
      inside = []

      [0, 1].map do |number|
        Thread.new do
          place.hold("dev", journal: Lain::Channel::Null.instance) do |_worker_env, _sync|
            inside << [number, :enter]
            sleep(0.02)
            inside << [number, :leave]
          end
        end
      end.each(&:join)

      expect(inside.map(&:last)).to eq(%i[enter leave enter leave])
      expect(inside.map(&:first).chunk_while { |a, b| a == b }.map(&:size)).to eq([2, 2])
    end

    it "numbers a lent lease's children in the lane its caller was numbering in", :seam do
      lane = described_class::Lane.named("issue.demo.a.1")
      lent = described_class::InPlace.new(worker_env: Lain::WorkerEnv.default, lane:)

      expect(lent.lane).to eq(lane)
      expect(described_class::InPlace.new(worker_env: Lain::WorkerEnv.default).lane)
        .to eq(described_class::Lane::UNNAMED)
    end

    it "lends its environment and a sync that does nothing, and reports nothing handed back" do
      held = Lain::WorkerEnv.default.with(cwd: leases_root)
      place = described_class::InPlace.new(worker_env: held)

      lent = place.hold("subagent", journal: Lain::Channel::Null.instance) do |worker_env, sync|
        [worker_env, sync.call(:the_child)]
      end

      expect(lent.value).to eq([held, Lain::Isolation::SelfSync::Result::NONE])
      expect([lent.report.kind, lent.sync, place.lane])
        .to eq([:nothing_to_do, Lain::Isolation::SelfSync::Result::NONE, described_class::Lane::UNNAMED])
    end

    it "hands the block an origin naming no commit, since it cut no checkout for the child" do
      place = described_class::InPlace.new(worker_env: Lain::WorkerEnv.default.with(cwd: leases_root))

      lent = place.hold("subagent", journal: Lain::Channel::Null.instance) { |*, origin| origin }

      expect(lent.value).to eq(Lain::Isolation::Lease::Origin.new)
    end
  end

  # The allocator under real contention, driven directly rather than through a
  # spawn: `+= 1` is a read and a write with a suspension point available
  # between them, and a lost increment is two workers sent to one checkout
  # path. 64 rather than a handful because a dropped increment under a Monitor
  # is not a failure a three-way race reproduces.
  #
  # The block PARKS until every sibling holds its own lease, and that park is
  # what makes the example honest: a block with no suspension point runs to
  # completion before the next task starts, so 64 tasks would be 64 SEQUENTIAL
  # holds, the live high-water mark would be one, and the backend's
  # already-leased refusal would never be armed at all.
  it "keeps every concurrently held lease on a path of its own" do
    Sync do
      arrived = 0
      Array.new(64) do
        Async do
          leases.hold("hammer", journal: Lain::Channel::Null.instance) do
            arrived += 1
            Async::Task.current.yield while arrived < 64
          end
        end
      end.each(&:wait)
    end

    expect(backend.high_water).to eq(64)
    expect(backend.worker_ids.uniq.size).to eq(64)
    expect(backend.released.sort).to eq(backend.leased.sort)
  end

  # What the parent is given: the child's own answer, untouched, and after it
  # one block per thing a human has to act on.
  describe "the lease a dispatch held" do
    let(:thinking) { { "type" => "thinking", "thinking" => "weighing it" } }
    let(:answer) do
      Lain::Response.new(content: [thinking, { "type" => "text", "text" => "child answer" }], stop_reason: :end_turn)
    end
    let(:merged) { Lain::Isolation::WorkerHandoff::Report.new(kind: :merged, ref: "refs/lain/worker/w-1") }
    let(:dirty) do
      Lain::Isolation::SelfSync::Result.new(outcome: :dirty, dirty: true, path: "/state/worktrees/w-1")
    end

    def held(report: Lain::Isolation::WorkerHandoff::Report.nothing,
             sync: Lain::Isolation::SelfSync::Result::NONE)
      described_class::Held.new(value: nil, report:, sync:)
    end

    it "appends each note as a block of its own, leaving every block the child answered with in place" do
      delivered = held(report: merged, sync: dirty).delivered(answer)

      expect(delivered.content.take(2)).to eq(answer.content)
      expect(delivered.content.drop(2).map { |block| block["text"] })
        .to eq(["\n\n[#{merged.summary}]", "\n\n[#{dirty.note}]"])
    end

    it "tells the parent uncommitted work was not handed back" do
      expect(held(sync: dirty).delivered(answer).text)
        .to include("the worker left uncommitted changes at /state/worktrees/w-1; they were not handed back")
    end

    it "hands the answer back as it was when there is nothing to say" do
      expect(held.delivered(answer)).to be(answer)
    end
  end

  # A stopped child can be resumed, and its work is in its checkout: a stop
  # keeps the lease live rather than surrendering it, until the resumed child
  # ends or the run closes.
  describe "a lease its block keeps" do
    def kept_by(leases)
      kept = nil
      expect do
        leases.hold("dev", journal:) do |_worker_env, _sync, _worker, keep|
          kept = keep.call
          raise LeasesSpecStopped, "ceiling"
        end
      end.to raise_error(LeasesSpecStopped, "ceiling")
      kept
    end

    it "is neither surrendered nor released when the block raises" do
      handoff = Class.new do
        attr_reader :calls

        def initialize = @calls = []

        def reclaim(lease, **) = given_back(:reclaim, lease)

        def surrender(lease, **) = given_back(:surrender, lease)

        def given_back(how, lease)
          @calls << how
          lease.release
          Lain::Isolation::WorkerHandoff::Report.nothing
        end
      end.new

      kept_by(described_class.new(backend:, handoff:))

      expect(handoff.calls).to be_empty
      expect(backend.released).to be_empty
    end

    it "is held again in the same directory, and given back once that hold returns" do
      kept = kept_by(leases)

      held = kept.hold("dev", journal:) { |worker_env, _sync| worker_env.cwd }

      expect(held.value).to eq(backend.leased.first)
      expect(backend.leased.size).to eq(1)
      expect(backend.released).to eq(backend.leased)
    end

    it "stays kept when the hold that resumed it is stopped again" do
      kept = kept_by(leases)

      again = nil
      expect do
        kept.hold("dev", journal:) do |_worker_env, _sync, _worker, keep|
          again = keep.call
          raise LeasesSpecStopped, "ceiling again"
        end
      end.to raise_error(LeasesSpecStopped)

      expect(again.lease).to be(kept.lease)
      expect(backend.released).to be_empty
    end

    it "is surrendered when the run closes, once" do
      kept_by(leases)

      leases.close
      leases.close

      expect(backend.released).to eq(backend.leased)
    end

    it "is not surrendered at close while a resumed child still runs in it" do
      released_inside = kept_by(leases).hold("dev", journal:) do
        leases.close
        backend.released.dup
      end

      expect(released_inside.value).to be_empty
    end

    it "is not surrendered at close once a resumed hold gave it back" do
      kept_by(leases).hold("dev", journal:) { "done" }

      expect { leases.close }.not_to(change { backend.released.size })
    end

    it "lends nothing to keep from a lease lent in place" do
      place = described_class::InPlace.new(worker_env: Lain::WorkerEnv.default)

      kept = place.hold("dev", journal:) { |_worker_env, _sync, _worker, keep| keep.call }

      expect(kept.value).to be_nil
    end
  end

  # After a run that never closed, a stopped child's checkout may be gone, so
  # what it left is snapshotted when it stops and a resume cuts a fresh
  # checkout carrying it.
  describe "a kept git checkout", :seam do
    let(:repo) { File.join(leases_root, "repo") }
    let(:git_backend) do
      Class.new do
        def initialize(repo, root)
          @repo = repo
          @root = root
        end

        def repo_root = @repo

        def acquire(worker_id)
          path = File.join(@root, worker_id.to_s)
          SeedRepo.git(@repo, "worktree", "add", "--detach", "--quiet", path, "HEAD")
          Lain::Isolation::Lease.new(worker_env: Lain::WorkerEnv.default.with(cwd: path),
                                     on_release: ->(**) { SeedRepo.git(@repo, "worktree", "remove", "--force", path) },
                                     origin: Lain::Isolation::Lease::Origin.new(path:))
        end
      end.new(repo, File.join(leases_root, "children"))
    end
    let(:git_leases) { described_class.new(backend: git_backend) }

    before { FileUtils.cp_r("#{SeedRepo.at(SeedRepo::SEED)}/.", FileUtils.mkdir_p(repo).first) }

    def stopped_with_work(lasting: true, skeleton: "class Skeleton; end\n")
      kept = nil
      expect do
        git_leases.hold("dev", journal:) do |worker_env, _sync, _worker, keep|
          SeedRepo.git(worker_env.cwd, "commit", "--allow-empty", "--quiet", "-m", "committed by the dev")
          File.write(File.join(worker_env.cwd, "skeleton.rb"), skeleton)
          File.write(File.join(worker_env.cwd, "README"), "changed\n")
          kept = keep.call(lasting:)
          raise LeasesSpecStopped, "ceiling"
        end
      end.to raise_error(LeasesSpecStopped)
      kept
    end

    def pins = SeedRepo.git(repo, "for-each-ref", "--format=%(refname)", "refs/lain/stopped/").stdout.split

    it "pins the snapshot in the repository its checkouts are cut from, so a later checkout reaches it" do
      snapshot = stopped_with_work.snapshot

      expect(SeedRepo.git(repo, "rev-parse", "refs/lain/stopped/#{snapshot}").stdout.strip).to eq(snapshot)
    end

    it "puts the uncommitted work back uncommitted" do
      snapshot = stopped_with_work.snapshot
      git_leases.close

      held = git_leases.restoring(snapshot).hold("dev", journal:) do |worker_env|
        SeedRepo.git(worker_env.cwd, "status", "--porcelain").stdout.lines.map(&:chomp).sort
      end

      expect(held.value).to eq([" M README", "?? skeleton.rb"])
    end

    it "drops the pin once a resume restored from it" do
      snapshot = stopped_with_work.snapshot
      git_leases.close

      git_leases.restoring(snapshot).hold("dev", journal:) { "resumed" }

      expect(pins).to be_empty
    end

    it "drops the pin once a resume holds the kept checkout again" do
      stopped_with_work.hold("dev", journal:) { "resumed" }

      expect(pins).to be_empty
    end

    it "keeps the pin at close for a stop a later run can resume, and drops it for one none can" do
      lasting = stopped_with_work.snapshot
      passing = stopped_with_work(lasting: false, skeleton: "class Other; end\n").snapshot

      git_leases.close

      expect(pins).to eq(["refs/lain/stopped/#{lasting}"])
      expect(passing).not_to eq(lasting)
    end

    it "snapshots the work the stopped child left, committed and not" do
      kept = stopped_with_work

      expect(kept.snapshot).to match(/\A\h{40}\z/)
      expect(SeedRepo.git(repo, "show", "#{kept.snapshot}:skeleton.rb").stdout).to eq("class Skeleton; end\n")
    end

    it "resumes in a fresh checkout holding that work when the old one is gone" do
      snapshot = stopped_with_work.snapshot
      git_leases.close

      held = git_leases.restoring(snapshot).hold("dev", journal:) do |worker_env|
        dir = worker_env.cwd
        [dir, File.read(File.join(dir, "skeleton.rb")), File.read(File.join(dir, "README")),
         SeedRepo.git(dir, "log", "-1", "--format=%s").stdout.strip]
      end

      dir, skeleton, readme, subject = held.value
      expect(dir).not_to be_nil
      expect([skeleton, readme, subject]).to eq(["class Skeleton; end\n", "changed\n", "committed by the dev"])
    end

    it "resumes in a fresh checkout when nothing was snapshotted" do
      held = git_leases.restoring(nil).hold("dev", journal:) do |worker_env|
        File.read(File.join(worker_env.cwd, "README"))
      end

      expect(held.value).to eq("seed\n")
    end
  end

  # `--isolation worktree` cuts each checkout as a shared clone, whose own
  # objects upstream never sees, so a snapshot made in one is pinned upstream
  # where the next clone reads it.
  describe "a stop on the backend --isolation worktree resolves to", :seam do
    let(:repo) { File.join(leases_root, "proj") }

    def resolved
      Lain::CLI::IsolationBackend.resolve("worktree", root: repo, journal: Lain::Channel::Null.instance,
                                                      cwd: repo)
    end

    before do
      FileUtils.cp_r("#{SeedRepo.at(SeedRepo::SEED)}/.", FileUtils.mkdir_p(repo).first)
      SeedRepo.git(repo, "branch", "-M", "main")
    end

    it "comes back with its uncommitted file in a fresh checkout after the run closed" do
      leases = described_class.new(backend: resolved)
      kept = nil
      expect do
        leases.hold("dev", journal:) do |worker_env, _sync, _worker, keep|
          File.write(File.join(worker_env.cwd, "skeleton.rb"), "class Skeleton; end\n")
          kept = keep.call
          raise LeasesSpecStopped, "ceiling"
        end
      end.to raise_error(LeasesSpecStopped)
      leases.close

      held = described_class.new(backend: resolved).restoring(kept.snapshot).hold("dev", journal:) do |worker_env|
        File.read(File.join(worker_env.cwd, "skeleton.rb"))
      end

      expect(held.value).to eq("class Skeleton; end\n")
    end
  end
end
