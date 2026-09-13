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

  # A lane names where this pool's workers are numbered. Every worktree of one
  # repository shares refs/lain/worker/, so two lanes' worker 1 must not spell
  # one id.
  describe "the lane it numbers its workers in" do
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

    it "numbers a lent lease's children in the lane its caller was numbering in" do
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
end
