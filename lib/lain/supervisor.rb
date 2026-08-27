# frozen_string_literal: true

require "async"
require "async/notification"

module Lain
  # The orchestration reactor ABOVE the Agent, and the constraint it exists to
  # satisfy: an actor's fiber spawns on `Async::Task.current`, so launched inside
  # Agent#ask's per-call `Sync` it would park as that ask's own child and
  # structured concurrency would never let the ask return. The Supervisor owns a
  # task that OUTLIVES each ask, and {#adopt} runs every launch under THAT task,
  # so an actor is a sibling of every ask rather than a captive of one. Its
  # presence is also what unrefuses the model-dispatched `mode: :actor` tool call;
  # {Null} is the wired-nothing default that keeps the refusal as it was.
  #
  # It is the fleet's registry too: each adoption is recorded with its role, and
  # the Supervisor enumerates {Registration}s -- what a HUD lists, and what
  # {CLI::Shutdown}'s graceful drain settles.
  class Supervisor
    include Enumerable

    # With no task for the launch to spawn under, the fiber lands on whatever task
    # happens to be current -- the wedge the actor refusal exists to prevent. So:
    # refuse first, launch nothing.
    class NotRunning < Error; end

    # A second #run would strand the first task's actors under an abandoned
    # handle, and a run-after-stop would carry the first life's dead registry
    # rows into the second.
    class AlreadyRunning < Error; end

    # @param journal [#<<] where a bounded {Drain}'s timeout record and every
    #   reap's {WorkerReaped} land; the Null channel by default.
    # @param isolation [#acquire] the isolation backend each adoption leases a
    #   {WorkerEnv} from; the shared-process {Isolation::Null} by default, whose
    #   lease is {WorkerEnv.default} and whose release is a no-op, so a supervisor
    #   with no isolation wired writes no `if isolation` anywhere.
    # @param handoff [#surrender] how a CRASHED worker's lease is given up
    #   ({#reap_crashed}, {#stop}); pairing {Isolation::WorkerHandoff} with an
    #   {Isolation::Worktree} backend is what makes the reap safe, and the default
    #   {Retain} declines instead. `#surrender` SHOULD be total, but this is an
    #   injected collaborator and totality is not enforceable from here, so {#reap}
    #   tolerates a raise: a reap's failure belongs to the reap, and must refuse no
    #   unrelated adoption and wedge no teardown.
    def initialize(journal: Channel::Null.instance, isolation: Isolation::Null.new, handoff: Retain)
      @journal = journal
      @isolation = isolation
      @handoff = handoff
      # An Array, not an address-keyed Hash: an address is the :spawn event's
      # CONTENT digest, and two spawns of the same arm from the same head
      # legitimately share one, so a collision must not drop a live actor.
      @registry = []
      @task = nil
      # Distinct per adoption even when two share a role: a Worktree backend keys
      # its checkout path on this, and two live leases at one path is a refusal.
      @worker_seq = 0
      # Which registrations have had their one reap attempt, claimed
      # SYNCHRONOUSLY (see {#claim}). The ROW is the key, not its worker_id,
      # because a caller may supply a worker_id a later adoption reuses.
      @reaped = Set.new
    end

    # The park is the suspend point {#stop}'s cancellation lands on; the task's
    # only job while parked is to BE the parent every adopted launch runs under.
    #
    # @param task [Async::Task] the orchestration task that outlives the asks
    # @return [self]
    def run(task = Async::Task.current)
      raise AlreadyRunning, "this supervisor already ran; one reactor per life -- build another Supervisor" unless
        @task.nil?

      @task = task.async { Async::Notification.new.wait }
      self
    end

    # `|| false` because Async::Task#running? answers nil (not false) once the
    # task's fiber is gone -- a stopped supervisor must read false, not nil.
    def running? = @task&.running? || false

    # The block runs EAGERLY on a fresh child of the reactor task (async's
    # depth-first start), so the handle is available the moment the launch's
    # synchronous prefix completes, while the actor's own fiber persists under
    # this supervisor's tree after the adopting caller has long returned.
    #
    # The registry append rides INSIDE the adopted task, not on the calling fiber
    # after `.wait`: a launch that awaits plus an adopter cancelled in that window
    # would otherwise leave a live actor the registry never heard of -- invisible
    # to the HUD, skipped by the drain, torn down by {#stop} without a farewell.
    #
    # Any CRASHED worker is reaped first, so a fleet does not accumulate one
    # orphan checkout per crash while the replacements run.
    #
    # A lease is acquired FIRST, inside the adopted task, and its {WorkerEnv} is
    # handed to the launch block. The block may ignore it -- a Proc drops the
    # extra arg -- which is the byte-identical no-isolation path. A launch that
    # raises OR is cancelled after the acquire releases the lease before
    # unwinding, so a refused adoption leaks no resource.
    #
    # @param role [String] what this actor is for -- the registry's label
    # @param worker_id [Object] the isolation key; a distinct per-adoption id by
    #   default, so same-role workers never collide on one leased path
    # @yieldparam worker_env [WorkerEnv] the leased cwd/env the child runs under
    # @yieldreturn [Tools::Subagent::Actor] the launched actor
    # @return [Tools::Subagent::Actor]
    def adopt(role:, worker_id: nil, &launch)
      raise NotRunning, "no reactor task is running; #run this supervisor under an orchestration reactor first" unless
        running?

      @task.async do
        reap_crashed
        register(role, worker_id || next_worker_id(role), launch)
      end.wait
    end

    # One {Drain} capping the WHOLE fleet's settling at `within` seconds.
    # Unbounded, a hung actor wedges wait_responses forever with the sigquit
    # escape hatch queued unread behind the blocked coordinator fiber.
    #
    # @param within [Numeric] seconds the fleet's settle may take, in total
    # @return [Array<Drain>]
    def drain(within:) = [Drain.new(supervisor: self, within:, journal: @journal)]

    # @yield [Registration] each adoption, in adoption order
    def each(&block)
      return enum_for(:each) unless block_given?

      @registry.each(&block)
      self
    end

    # Children first, so no fiber is torn down by the parent's cancellation while
    # a farewell is still in flight. A crashed worker's lease is SURRENDERED
    # rather than bare-released -- see {#farewell}.
    #
    # @return [self]
    def stop
      return self unless running?

      each { |registration| farewell(registration) }
      @task.stop
      @task.wait
      self
    end

    private

    # A CRASHED row is surrendered rather than released because the release
    # force-removes a `--detach`ed checkout, destroying the commits of the one
    # worker nothing else holds. This is the likelier of the two reap paths: the
    # adoption-path reap fires only when a later adoption happens, while every
    # supervised fleet eventually shuts down.
    #
    # The reap runs BEFORE the farewell because #stop is what makes an actor
    # `stopped?`, and a stopped row no longer reads :failed -- asking afterwards
    # would find nothing to reap, ever. The release still runs under a surrender:
    # it is idempotent, and it is what stops a declining handoff ({Retain}) or a
    # broken one from leaving a provisioned checkout standing past teardown.
    def farewell(registration)
      reap(registration) if reapable?(registration)
      registration.actor.stop
      registration.release
    end

    # Surrender one crashed row and SAY what came back. Discarding the Report
    # drops {Isolation::WorkerHandoff::STRANDED} on the floor -- a parent checkout
    # left mid-merge, which declines every later handback forever and leaves
    # conflict markers standing in a real person's working tree -- and the Report
    # is the only place that state is ever named.
    #
    # The rescue is for the injected duck, not for {Isolation::WorkerHandoff},
    # which answers a Report on every StandardError path: a collaborator that
    # raises anyway took an unrelated adoption down with it (measured -- every
    # LATER adoption raised, permanently). `StandardError` and not `Exception`,
    # because an `Async::Stop` or an `Interrupt` climbing through a reap is a
    # cancellation that must keep climbing.
    def reap(registration)
      record(WorkerReaped.from(registration, registration.surrender(@handoff)))
    rescue StandardError => e
      record(WorkerReaped.raised(registration, e))
    end

    # `:nothing_to_do` is the answer an already-surrendered lease gives, and
    # {#reap_crashed} runs over every failed row at every adoption -- journaling
    # it would put one noise line per adoption into the experiment record.
    def record(reaped)
      @journal << reaped unless reaped.quiet?
    end

    # The DECISION is inside the tolerance, not just the surrender under it,
    # because asking WIDENS the duck an actor owes: `failed?` reaches through to
    # `stopped?` and `dead?`, which a registration holding a stand-in that owed
    # only `#stop` cannot answer -- and #stop is what every reactor-owning caller
    # runs from an `ensure`, where a raise during teardown leaves the root task
    # never completing and the process HANGS in epoll instead of failing
    # (measured, cli/wiring_spec).
    #
    # Answering FALSE and journaling nothing: "I cannot tell whether this row
    # crashed" is not "it crashed". A record here would put a failed reap of a
    # healthy worker into the experiment record, and surrendering on a guess would
    # hand a live worker's checkout away. The opposite verdict from {#reap}'s
    # rescue, where a reap was genuinely attempted and genuinely failed.
    #
    # @return [Boolean]
    def reapable?(registration)
      registration.failed? && !claim(registration).nil?
    rescue StandardError
      false
    end

    # `Set#add?` answers nil for a member already present and a fiber cannot
    # switch inside it, so the claim is taken before the handoff reaches its first
    # suspension point -- which is what makes two concurrent adoptions (or an
    # adoption racing {#stop}) surrender one row exactly once. The real
    # {Isolation::WorkerHandoff}'s released?-then-anchor guard is check-then-act
    # and survives only because Mixlib::ShellOut blocks the whole reactor; that is
    # a property of that collaborator, and a fiber-aware handoff
    # double-surrenders without this (measured).
    #
    # NOT handed back on failure: one attempt, then the record says what happened,
    # which keeps a broken handoff from journaling once per adoption forever.
    #
    # @return [Registration, nil] the row when THIS call took its attempt, nil
    #   when an earlier one already had it
    def claim(registration) = @reaped.add?(registration) && registration

    # Minted through {Isolation::WorkerId} rather than spelled here: the spawn
    # path numbers its own workers off a sequence this one cannot see, and a
    # backend keys a checkout path on whichever id it is handed -- so the two
    # lanes' disjointness belongs to one object that can prove it, not to two
    # format strings that happen to differ.
    def next_worker_id(role)
      @worker_seq += 1
      Isolation::WorkerId.adopted(role:, ordinal: @worker_seq).to_s
    end

    # A crashed worker's lease outlives its actor: {Restart} replays it under a
    # NEW worker_id, so nothing reclaims the dead one and a multi-day epic run
    # accumulates one orphan worktree per crash. A bare `lease.release` would be
    # worse than the leak -- {Isolation::Worktree} reclaims a `--detach`ed
    # checkout with `--force`, so an unanchored commit goes unreachable the
    # instant it is released, and a crashed worker is exactly the one holding
    # commits nothing else has. The handoff anchors under `refs/lain/worker/`
    # first, spawning no resolver, because an unbounded provider round trip has
    # no business inside a restart.
    #
    # BEFORE the acquire under it, so the dead worker's work is on its ref while
    # the replacement's checkout is still to be cut. A reaped row STAYS in the
    # registry as the honest history of the first life, so this runs over it again
    # at every later adoption, and {#claim} is what makes the repeat cost one set
    # lookup instead of a second surrender.
    #
    # Claiming the whole batch before reaping any of it is deliberate, not an
    # accident of `select`-then-`each`: the claims land in one unbroken stretch of
    # this fiber, so no concurrent adoption can slip between them.
    def reap_crashed
      select { |registration| reapable?(registration) }.each { |registration| reap(registration) }
    end

    # `registered` guards the reclaim: any exit that did NOT reach a live
    # registration -- a launch that raised, OR the adopted task CANCELLED after
    # the acquire (Async::Stop is an Exception, not a StandardError, so a `rescue
    # StandardError` would miss it and strand an orphan worktree invisible to
    # #stop) -- releases the lease on the way out. `ensure` is the only exit that
    # runs on cancellation too; `&.` covers the acquire itself raising, which
    # provisioned nothing to reclaim.
    def register(role, worker_id, launch)
      registered = false
      lease = @isolation.acquire(worker_id)
      actor = launch.call(lease.worker_env)
      @registry << Registration.new(role:, actor:, lease:, worker_id:)
      registered = true
      actor
    ensure
      lease&.release unless registered
    end
  end

  class Supervisor
    # Reopened rather than nested mid-body: each of these is its own
    # responsibility, and the split keeps every class body within
    # Metrics/ClassLength instead of loosening it.

    # One registry row. State is DERIVED from the actor's own predicates on every
    # read -- a stored status field would go stale the moment a fiber failed.
    Registration = Data.define(:role, :actor, :lease, :worker_id) do
      def address = actor.address

      def head_digest = actor.timeline.head_digest

      # A no-op on the shared-process {Isolation::Null} lease, so releasing one
      # worker's lease never tears down state a still-running sibling shares; a
      # Worktree lease removes exactly this worker's own checkout.
      def release = lease.release

      # Through the handoff, which anchors the commits before the release under it
      # destroys the checkout. `worker_id` rides along because it is what names
      # the ref, so a human finds the work under the id the registry showed.
      def surrender(handoff) = handoff.surrender(lease, worker_id:)

      # An operator's own #stop is deliberate and is reclaimed with the rest of
      # the fleet, so it is not reaped out from under them here.
      def failed? = state == :failed

      # :running covers parked-and-serviceable, and :stopped wins over :failed
      # because the operator's stop is the later, deliberate fact.
      def state
        return :stopped if actor.stopped?

        actor.dead? ? :failed : :running
      end

      # Draining awaits QUIESCENCE. A dead actor is already quiescent, and
      # re-raising its captured failure would tear down the very drain that is
      # closing the session record -- that failure belongs to whoever awaits the
      # actor through #settle directly, not to shutdown.
      #
      # The rescue closes the check-then-wait hole: an actor LIVE at the dead?
      # check can fail DURING the await, and must be absorbed the same way. It
      # stays loud for direct callers because {Tools::Subagent::Actor#settle}
      # re-raises on every call. {Drain}'s own timeout is the one exception -- it
      # must reach the Drain that armed it, or one swallowed expiry lets the
      # settle loop run unbounded again.
      def settle
        actor.settle unless actor.dead?
        self
      rescue Async::TimeoutError
        raise
      rescue StandardError
        self
      end
    end

    # Deliberately NOT {Isolation::WorkerHandoff::Null}, which releases: with no
    # handoff wired there is nothing that can anchor, and releasing a crashed
    # worker's `--detach`ed checkout with nothing anchored makes its commits
    # unreachable. So the wired-nothing answer is KEEP IT -- one idle worktree
    # until #stop, rather than the work.
    #
    # It answers the one message the reap sends, not the whole WorkerHandoff duck:
    # a Supervisor never reclaims a SETTLED worker, so a `#reclaim` here would be
    # a method with no caller.
    module Retain
      def self.surrender(_lease, **) = Isolation::WorkerHandoff::Report.nothing
    end

    # The wired-nothing default: not running, nothing registered, adoption
    # refused, so no caller writes `if supervisor`. A module, because there is no
    # per-instance state.
    #
    # "The whole duck" IS THE CONTRACT, and it was untrue for two of the six
    # messages until that was found: {CLI::Repl} defaults `supervisor:` to this
    # module and {Repl::ConversationScope} opens with `@supervisor.run(task)`, so
    # every Repl built without an explicit supervisor died on NoMethodError at the
    # first line of the conversation -- inert only because {CLI::Wiring} always
    # passes a real one. A Null that answers most of a duck is worse than no
    # default: the gap is invisible at the call site.
    module Null
      extend Enumerable

      def self.running? = false

      # Answers `self`, like the real Supervisor, so a caller may chain. `run`
      # IGNORES the orchestrating task, which is the honest no-op: with nothing
      # wired there is nothing to park and nothing that will ever adopt. It does
      # NOT refuse a second `run` -- AlreadyRunning guards a reactor that can only
      # be had once, and there is no reactor here to lose.
      def self.run(_task = nil) = self

      # Nothing to farewell and no reactor to close.
      def self.stop = self

      def self.each
        return enum_for(:each) unless block_given?

        self
      end

      # As loud as adopting before {Supervisor#run}: a silently-current-task
      # launch is the wedge.
      def self.adopt(role:, &_launch)
        raise NotRunning, "no supervisor is wired; construct a Supervisor and #run it (adopting role: #{role})"
      end

      def self.drain(**) = []
    end
  end

  class Supervisor
    # Journaled when a bounded {Drain} gives up, never silently dropped. `roles`
    # is the whole fleet at expiry: which registration was mid-settle is not
    # knowable from outside the loop, and the honest record is "these were being
    # drained when the window closed".
    DrainTimedOut = Data.define(:within, :roles) do
      include Telemetry::Journalable
    end

    # What a crashed worker's reap did, in the experiment record. The Report it
    # carries is the ONLY thing that ever names
    # {Isolation::WorkerHandoff::STRANDED} -- a parent checkout left mid-merge,
    # whose remedy is a person running `git merge --abort` and whose cost until
    # they do is that every later handback declines, silently, around conflict
    # markers standing in their working tree. `stranded` lifts that one
    # act-on-me state out of the Report's prose so a HUD or bench query can filter
    # on it, and `worker_key` is the STRING worker_id, the join key
    # {Telemetry::Handback} and {Telemetry::IsolationLease} already share.
    WorkerReaped = Data.define(:role, :worker_key, :kind, :ref, :stranded, :summary) do
      include Telemetry::Journalable

      # STRANDED has no kind of its own -- a stranded restoration is escalated by
      # APPENDING that sentence to the Report's existing detail, so matching is
      # the only way to read it back out. The constant, not a copy of its text,
      # so the two cannot drift apart in silence.
      def self.from(registration, report)
        new(role: registration.role, worker_key: registration.worker_id, kind: report.kind, ref: report.ref,
            stranded: report.detail.include?(Isolation::WorkerHandoff::STRANDED), summary: report.summary)
      end

      # A handoff that raised where its contract answers a Report. With no Report,
      # `stranded` is false in the honest sense of "nothing reported it" -- the
      # raise is what a reader acts on.
      def self.raised(registration, error)
        new(role: registration.role, worker_key: registration.worker_id, kind: :failed, ref: nil,
            stranded: false, summary: "#{error.class}: #{error.message}")
      end

      def initialize(role:, worker_key:, kind:, ref:, stranded:, summary:)
        super(role: role.to_s.dup.freeze, worker_key: worker_key.to_s.dup.freeze, kind: kind.to_sym,
              ref: ref&.dup&.freeze, stranded: stranded ? true : false, summary: summary.to_s.dup.freeze)
      end

      # @return [Boolean] whether this record says nothing worth a journal line
      def quiet? = kind == :nothing_to_do
    end

    # `with_timeout`'s expiry raises at whichever parked settle is in flight, and
    # {Registration#settle} deliberately re-raises exactly that class, so the
    # bound cannot be swallowed by the same rescue that absorbs actor failures.
    class Drain
      def initialize(supervisor:, within:, journal:)
        @supervisor = supervisor
        @within = within
        @journal = journal
      end

      def settle
        Async::Task.current.with_timeout(@within) { @supervisor.each(&:settle) }
        self
      rescue Async::TimeoutError
        @journal << DrainTimedOut.new(within: @within, roles: @supervisor.map(&:role))
        self
      end
    end
  end

  class Supervisor
    # {Context::Mailbox} binds its frozen snapshot at construction, but a pipeline
    # is built ONCE while the snapshot must be per-turn -- an Agent whose pipeline
    # held a constructed Mailbox would fold the same stale snapshot forever. This
    # object is both sides of that seam: the Agent's `mailbox:` duck ({#capture},
    # the ONE live read of the mutable log, at turn start) and a pipeline
    # combinator ({#call}) folding whatever {#capture} pinned. The Agent captures
    # BEFORE it renders and commits from the SAME returned snapshot, so render and
    # commit consume one frozen value by construction.
    #
    # Deliberately NOT frozen, unlike every other combinator: the per-turn
    # snapshot slot is the point. Purity holds per snapshot, and the slot has a
    # single writer -- the Agent's own fiber, writing strictly before the render
    # that reads it. That write-then-read is one synchronous stretch: the only
    # yield inside a turn is the provider round trip, which comes AFTER the
    # render, so no message arrival can slip between capture and fold.
    class TurnMailbox < Context::Combinator
      def initialize(source:)
        super()
        @source = source
        @snapshot = Context::Mailbox::Null
      end

      # Capture THIS turn's snapshot and remember it for the render that follows.
      #
      # @param timeline [Timeline] the head this turn renders from
      # @return [Context::Mailbox::Snapshot]
      def capture(timeline)
        @snapshot = @source.capture(timeline)
      end

      # Before the first capture the slot holds {Context::Mailbox::Null}, whose
      # empty pending set makes this the identity: a seam with no turn in flight
      # changes nothing.
      def call(messages)
        Context::Mailbox.new(snapshot: @snapshot).call(messages)
      end
    end
  end
end

# Restart reopens Supervisor and its records mix in Telemetry::Journalable, so it
# loads after the class body; supervisor.rb is this subtree's index.
require_relative "supervisor/restart"
