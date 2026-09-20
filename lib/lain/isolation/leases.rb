# frozen_string_literal: true

require "async"
require "monitor"

module Lain
  module Isolation
    # A lease a dispatch could not give back. Its own record because the
    # tolerance below must not be silent: the checkout is still on disk, it
    # will defeat the next acquire at that path, and `worker_key` is how a
    # human finds it. {Tools::Subagent::Stagger}'s records are the shape -- a
    # small Data on whatever journal the dispatch was handed.
    LeaseNotReclaimed = Data.define(:worker_key, :error) do
      include Telemetry::Journalable

      def initialize(worker_key:, error:)
        super(worker_key: worker_key.to_s.dup.freeze, error: error.to_s.dup.freeze)
      end
    end

    # Where a child's execution environment is leased FROM, and how the
    # workers leasing it are named. The two travel as one object because the
    # NAME is what a backend keys its resource on: {Worktree} derives a
    # checkout path from the worker id and refuses a path a live lease already
    # holds, so an id handed out twice is a refused spawn or a shared working
    # tree, depending on which backend the run wired. The backend arrives
    # INJECTED -- a run resolves exactly one, and the {Lain::Supervisor} is
    # handed that same instance -- because two backends over one project each
    # allocate from state the other cannot see.
    #
    # ONE PER SEAM, which is one per run, and that is what makes the sequence
    # correct rather than merely monotonic. A nested spawn's tool is a
    # {Tools::Subagent#descend} copy built from `Seam#with`, and
    # {Skill::RoleSpawn} builds a FRESH Subagent per call over the seam it
    # holds -- so parent, child, grandchild and two concurrent role spawns all
    # draw from this one sequence. A counter owned by the tool instead would
    # hand two of them the same number, since each of those tools is a
    # different object that never meets the others.
    #
    # The SPELLING of the id is not here: {Lain::Supervisor} numbers the actors
    # an operator adopts off a sequence this one cannot see, and the two lanes
    # must not be able to name one resource, so {WorkerId} owns both spellings
    # and the proof that they cannot meet. This object owns only the sequence
    # its own lane counts along.
    #
    # Monitor-guarded, and NOT because any caller in lib/ needs it today.
    # {Tools::Subagent#fan_out} dispatches its siblings as Async tasks, so two
    # fibers really are inside `#hold` at once -- but a fiber scheduler offers
    # no suspension point between the read and the write of `@count += 1`, so
    # none of them can lose an increment. The guard is for the caller this
    # class does not get to refuse: `#hold` is public, nothing in its signature
    # says "fibers only", and a threaded caller would hand two live workers one
    # id -- which a backend keying a checkout on that id turns into a refused
    # spawn or a shared working tree. Removing it is green on every spec here,
    # which is why the reason is written down instead of pinned.
    class Leases
      # What one dispatch's lease came to: the block's own value, the
      # {SelfSync::Result} of the sync before its handback, and the
      # {WorkerHandoff::Report} of the handback itself.
      Held = Data.define(:value, :report, :sync) do
        # What the parent is given: the child's answer with every block of it
        # untouched, then one block per thing a human acts on -- where the
        # work went, and uncommitted work the handback did not carry. The
        # result and the record of what the parent was given are then the
        # same text.
        def delivered(response)
          notes = [report.summary, sync.note].reject(&:empty?)
          return response if notes.empty?

          blocks = notes.map { |note| { "type" => "text", "text" => "\n\n[#{note}]" } }
          response.with(content: response.content + blocks)
        end
      end

      Lane = Data.define(:name)

      # The lane a Leases numbers its workers in. A named lane prefixes each
      # worker id with its name, because every worktree of one repository
      # anchors under the one `refs/lain/worker/` namespace: two lanes that
      # each count from 1 would spell one ref, and the second handback would
      # move the first lane's only anchor. The run's own lane is unnamed and
      # keeps the bare ids it always had.
      #
      # Reopened for the constants, since one declared inside a
      # `Data.define` block lands in the enclosing module.
      class Lane
        # A name git would refuse in a ref, raised by the one check every
        # caller-named worker name passes.
        Refused = WorkerId::Refused

        def initialize(name:) = super(name: -name.to_s)

        UNNAMED = new(name: "")

        # @param name [String] e.g. `issue.<slug>.<id>`
        # @return [Lane]
        # @raise [Refused] when git would not accept it in a ref
        def self.named(name) = new(name: WorkerId.checked(name))

        # @return [String] the id a backend keys the worker on
        def worker(role:, ordinal:)
          id = WorkerId.spawned(role:, ordinal:).to_s
          name.empty? ? id : "#{name}.#{id}"
        end
      end

      # A lease its caller already holds, lent to one dispatch in place of a
      # new one. The child runs in that checkout, and what it leaves there is
      # the holder's to commit and hand back, so nothing here acquires, syncs
      # or reclaims: a second lease for the same work would be a second
      # checkout, and the child's writes would land where the holder never
      # reads them.
      #
      # ONE DISPATCH AT A TIME, for the reason a handback into a parent
      # checkout is serialized: two children writing in one tree at once each
      # see the other's half-written state, and neither the order of calls
      # nor the privacy of the lender is a guard -- {Skill::RoleSpawn#within}
      # is public, and a caller may lend the same lease to as many spawns as
      # it likes.
      class InPlace
        # The environment as lent, and where its caller numbers workers -- a
        # lent child's lineage names the lane it served rather than reading
        # as the run's own.
        attr_reader :worker_env, :lane

        # @param worker_env [WorkerEnv] the held checkout's environment
        # @param lane [Lane] the caller's own lane; the run's unnamed one by
        #   default, which is what a lender outside any lane has
        def initialize(worker_env:, lane: Lane::UNNAMED)
          @worker_env = worker_env
          @lane = lane
          @monitor = Monitor.new
        end

        # @param _role [String] unused: no worker is minted for a lent lease
        # @yieldparam worker_env [WorkerEnv] the held environment, as lent
        # @yieldparam sync [#call] a sync that rebases nothing
        # @yieldparam worker [nil] no worker key: this lease was cut for the
        #   LENDER, and naming the lender's worker as the child's would put a
        #   checkout on a record beside a child that was never given one
        # @return [Held] the block's value, with nothing synced or handed back
        def hold(_role, **)
          none = SelfSync::Result::NONE
          @monitor.synchronize do
            Held.new(value: yield(worker_env, ->(_worker) { none }, nil), sync: none,
                     report: WorkerHandoff::Report.nothing)
          end
        end
      end

      # Where its workers are numbered, which an actor's spawn names too so
      # two lanes' actors from one head never share an address.
      attr_reader :lane

      # @param backend [#acquire] the {Isolation} backend a dispatch leases
      #   from; the shared-process baseline by default, whose lease is
      #   {WorkerEnv.default} and whose release reclaims nothing -- which is
      #   what lets every spawn lease unconditionally
      # @param handoff [#reclaim, #surrender] how a lease is given back. A
      #   worker's commits are never optional, and a bare release deletes a
      #   checkout's unanchored commits, so the run's {WorkerHandoff} hands
      #   them back first. The default only releases, which is all a backend
      #   that cuts no checkout needs.
      # @param sync [#call, #editorless] the {SelfSync} a worker is rebased
      #   onto its working branch with before that handback; the default syncs
      #   nothing
      # @param lane [Lane] where its workers are numbered; the run's own,
      #   unnamed, by default
      def initialize(backend: Null.new, handoff: WorkerHandoff::Null,
                     sync: SelfSync::Null, lane: Lane::UNNAMED)
        @backend = backend
        @handoff = handoff
        @sync = sync
        @lane = lane
        @monitor = Monitor.new
        @count = 0
      end

      # One dispatch's whole lease lifetime: mint a worker, acquire, run the
      # block under the leased environment, give it back.
      #
      # A block that RETURNED is reclaimed: its work is handed back, and a
      # conflict may spawn a resolver. Every other exit is SURRENDERED from
      # the `ensure` -- anchored, with nothing spawned while an exception
      # climbs. `ensure` and not `rescue StandardError`, because a cancelled
      # dispatch raises `Async::Stop`, which is not a StandardError, and a
      # child cancelled mid-ask has left its checkout as unreachable as one
      # that returned. The lease is how the two are told apart: a reclaim
      # always releases it, and an acquire that refused left none.
      #
      # A surrendered checkout is synced first when its block never did, with
      # nobody to ask, so uncommitted work a failed child left behind is named
      # on the record rather than read as a clean tree.
      #
      # @param role [String] what this worker is for, so a checkout left
      #   behind names the spawn it belonged to
      # @param journal [#<<] where a failed reclaim is recorded
      # @yieldparam worker_env [WorkerEnv] the leased cwd and env, with no
      #   editor for git to open
      # @yieldparam sync [#call] `sync.call(worker)` rebases the checkout
      #   onto the working branch; the block calls it with the still-live
      #   child, between its answer and the reclaim here
      # @yieldparam worker [String] the key this worker's resource is named
      #   under, so a dispatch can say on its own record which checkout its
      #   work is in -- the same key {Telemetry::IsolationLease} carries
      # @return [Held] the block's value and the handback's report
      def hold(role, journal:)
        worker = @lane.worker(role:, ordinal: next_ordinal)
        synced = nil
        lease = @backend.acquire(worker)
        value = yield(@sync.editorless(lease.worker_env),
                      ->(asked) { synced = @sync.call(lease, worker: asked, worker_id: worker) }, worker)
        synced ||= SelfSync::Result::NONE
        Held.new(value:, sync: synced, report: reclaim(lease, worker, journal, synced))
      ensure
        surrender(lease, worker, journal, synced) unless lease.nil? || lease.released?
      end

      private

      def reclaim(lease, worker, journal, synced)
        tolerated(worker, journal) { @handoff.reclaim(lease, worker_id: worker, sync: synced) }
      end

      # A dispatch that raised after its sync ran still says what the sync
      # did, on the record of the surrender.
      #
      # The sync and the handoff are ONE shielded region, the
      # {Agent::ToolDelivery#cancel} precedent: this runs while the task is
      # already unwinding, the sync is git subprocesses and so a suspension
      # point, and a further stop landing there -- a reactor teardown, an
      # ancestor task -- would skip the handoff, leaving the checkout on disk,
      # the lease unreleased and nothing on the record. `defer_stop` holds off
      # that one cancel.
      def surrender(lease, worker, journal, synced)
        shielded do
          synced ||= unasked(lease, worker)
          tolerated(worker, journal) { @handoff.surrender(lease, worker_id: worker, sync: synced) }
        end
      end

      def shielded(&block)
        task = Async::Task.current?
        task ? task.defer_stop(&block) : yield
      end

      # The sync a dispatch that never reached its own gets on the way out. It
      # runs while an exception climbs, so a failure of its own reads as no
      # sync rather than replacing that exception.
      def unasked(lease, worker)
        @sync.call(lease, worker: SelfSync::Unaskable, worker_id: worker)
      rescue StandardError
        SelfSync::Result::NONE
      end

      # A teardown that cannot reclaim must not eat a completed child's
      # answer. {Worktree#remove} raises deliberately rather than leave a
      # checkout standing, and a handoff releases on its way out, so the raise
      # arrives through it -- and `Tool#call` does not rescue, so it would hand
      # the parent the teardown failure in place of work it has already paid
      # for. {Lain::Supervisor#reap} carries the same tolerance at the same
      # shape of seam: attempt it, then let the record say what happened.
      def tolerated(worker, journal)
        yield
      rescue StandardError => e
        journal << LeaseNotReclaimed.new(worker_key: worker, error: e.message)
        WorkerHandoff::Report.nothing
      end

      # Guarded for the threaded caller `#hold`'s signature does not forbid,
      # rather than for the fiber ones it has; the class docstring measures why
      # no spec can tell the difference.
      def next_ordinal = @monitor.synchronize { @count += 1 }
    end
  end
end
