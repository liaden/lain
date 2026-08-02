# frozen_string_literal: true

require "async"
require "async/notification"

module Lain
  # The orchestration reactor ABOVE the Agent (OM-6). {Tools::Subagent::Actor}
  # pins the constraint this class exists to satisfy: an actor's fiber spawns on
  # `Async::Task.current`, so launched inside Agent#ask's per-call `Sync` it
  # would park as that ask's own child and structured concurrency would never
  # let the ask return. The Supervisor owns a task that OUTLIVES each ask --
  # {#run} spawns it under an orchestration reactor the caller holds (the exe's
  # chat loop, a bench script) -- and {#adopt} runs each launch under THAT
  # task, so an actor is a sibling of every ask rather than a captive of one.
  # Its presence is also what unrefuses the model-dispatched `mode: :actor`
  # tool call ({Tools::Subagent#perform}); {Null} is the wired-nothing default
  # that keeps the refusal exactly as it was.
  #
  # It is the fleet's registry too: each adoption is recorded with its role,
  # and the Supervisor enumerates {Registration}s (role, state, head digest) --
  # what a HUD lists, and what {CLI::Shutdown}'s graceful drain settles
  # ({CLI::Conductor} hands this object straight to that `actors:` seam).
  class Supervisor
    include Enumerable

    # Adopting with no reactor task is a caller bug, loudly: there is no task
    # for the launch to spawn under, so the fiber would land on whatever task
    # happens to be current -- exactly the wedge the actor refusal exists to
    # prevent. Refuse first, launch nothing.
    class NotRunning < Error; end

    # One reactor per Supervisor's LIFE, enforced (a second #run would strand
    # the first task's actors under an abandoned handle, and a run-after-stop
    # would carry the first life's dead registry rows into the second).
    class AlreadyRunning < Error; end

    # @param journal [#<<] where a bounded {Drain}'s timeout record and every
    #   reap's {WorkerReaped} land; the Null channel by default.
    # @param isolation [#acquire] the isolation backend each adoption leases a
    #   {WorkerEnv} from; the shared-process {Isolation::Null} by default, whose
    #   lease is {WorkerEnv.default} and whose release is a no-op -- so a
    #   supervisor with no isolation wired behaves byte-identically to before
    #   the lease seam existed (Null Object, no `if isolation` anywhere).
    # @param handoff [#surrender] how a CRASHED worker's lease is given up
    #   ({#reap_crashed}, {#stop}); {Isolation::WorkerHandoff} is the one that
    #   exists, and pairing it with a {Isolation::Worktree} backend is what makes
    #   the reap safe. The default {Retain} declines instead -- see its own note
    #   for why the wired-nothing answer here is "keep it" rather than "release
    #   it". `#surrender` SHOULD be total (a {Isolation::WorkerHandoff::Report}
    #   on every StandardError path, which the real one guarantees), but this is
    #   an injected collaborator and totality is not enforceable from here, so
    #   {#reap} tolerates a raise instead of demanding one -- a reap's failure
    #   belongs to the reap, and must refuse no unrelated adoption and wedge no
    #   teardown.
    def initialize(journal: Channel::Null.instance, isolation: Isolation::Null.new, handoff: Retain)
      @journal = journal
      @isolation = isolation
      @handoff = handoff
      # An Array, not an address-keyed Hash: an address is the :spawn event's
      # CONTENT digest, and two spawns of the same arm from the same head
      # legitimately share one -- the registry records ADOPTIONS, in adoption
      # order, so a colliding address must not silently drop a live actor.
      @registry = []
      @task = nil
      # A per-supervisor monotonic counter so each adoption gets a distinct
      # worker id even when two share a role -- a Worktree backend keys its
      # checkout path on this, and two live leases at one path is a refusal.
      @worker_seq = 0
      # Which registrations have had their one reap attempt. Claimed
      # SYNCHRONOUSLY, which is what makes two concurrent adoptions surrender a
      # crashed row exactly once (see {#claim}); the ROW is the key, not its
      # worker_id, because a caller may supply a worker_id a later adoption
      # reuses.
      @reaped = Set.new
    end

    # Spawn the long-lived reactor task under `task` and park it. The park is
    # the suspend point {#stop}'s cancellation lands on; the task's only job
    # while parked is to BE the parent every adopted launch runs under.
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

    # Run `launch` under the supervisor's task and register the actor it
    # returns. The block runs EAGERLY on a fresh child of the reactor task
    # (async's depth-first start), so the handle is available the moment the
    # launch's synchronous prefix completes -- while the actor's own fiber, a
    # child of that child, persists under this supervisor's tree after the
    # adopting caller (a tool dispatch, an ask) has long returned.
    #
    # The registry append rides INSIDE the adopted task, not on the calling
    # fiber after `.wait`: a launch that awaits plus an adopter cancelled in
    # that window would otherwise leave a live actor the registry never heard
    # of -- invisible to the HUD, skipped by the drain, torn down by {#stop}
    # without a farewell (review fix 2).
    #
    # Any CRASHED worker is reaped first ({#reap_crashed}), so a fleet does not
    # accumulate one orphan checkout per crash while the replacements run.
    #
    # A lease is acquired FIRST, inside the adopted task, and its {WorkerEnv} is
    # handed to the launch block so the actor's child runs its tools under the
    # leased cwd/env. The block may ignore it (a non-isolation launch is a
    # zero-arg block, and a Proc drops the extra arg) -- that is the byte-
    # identical default path. The lease rides the {Registration}, released on
    # {#stop}. A launch that raises OR is cancelled after the acquire releases
    # the lease before unwinding, so a refused adoption leaks no resource.
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

    # The bounded drain view {CLI::Conductor} hands {CLI::Shutdown}'s
    # `actors:`: one {Drain} whose #settle caps the WHOLE fleet's settling at
    # `within` seconds. Unbounded, a hung actor wedges wait_responses forever
    # with the sigquit escape hatch queued unread behind the blocked
    # coordinator fiber (review fix 3).
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

    # Structured teardown, children first: farewell every actor (their own
    # #stop lands the final attributed :message and cancels their fiber), then
    # cancel the reactor task -- so no fiber is torn down by the parent's
    # cancellation while a farewell is still in flight.
    #
    # A crashed worker's lease is SURRENDERED here, not bare-released; see
    # {#farewell}, which is the other half of {#reap_crashed} and the likelier
    # of the two paths a crash actually leaves by.
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

    # One row's teardown. A CRASHED row is surrendered here for the same reason
    # {#reap_crashed} surrenders one: the release below force-removes a
    # `--detach`ed checkout, so bare-releasing the one worker holding commits
    # nothing else has destroys them. This is the LIKELIER path of the two --
    # the reap on the adoption path only fires when a later adoption happens,
    # while every supervised fleet eventually shuts down.
    #
    # The reap runs BEFORE the farewell because #stop is what makes an actor
    # `stopped?`, and a stopped row no longer reads :failed ({Registration#state}
    # ranks the operator's deliberate stop over the crash) -- asking afterwards
    # would find nothing to reap, ever. The release still runs under a
    # surrender: it is idempotent, so it is a no-op once the handoff gave the
    # lease up, and it is what stops a DECLINING handoff ({Retain}) or a broken
    # one from leaving a provisioned checkout standing past teardown.
    def farewell(registration)
      reap(registration) if reapable?(registration)
      registration.actor.stop
      registration.release
    end

    # Surrender one crashed row and SAY what came back. Discarding the Report
    # drops {Isolation::WorkerHandoff::STRANDED} on the floor -- a parent
    # checkout left mid-merge, which declines every later handback forever and
    # leaves conflict markers standing in a real person's working tree -- and
    # the Report is the only place that state is ever named.
    #
    # The rescue is for the injected duck, not for {Isolation::WorkerHandoff},
    # which answers a Report on every StandardError path: a collaborator that
    # raises anyway would otherwise take an unrelated adoption down with it
    # (measured: every LATER adoption raised, permanently) or skip the rest of a
    # teardown. `StandardError` and not `Exception`, because an `Async::Stop` or
    # an `Interrupt` climbing through a reap is a cancellation that must keep
    # climbing -- the same line {Isolation::WorkerHandoff} draws.
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

    # Whether this row is a crash whose one reap attempt is still unclaimed.
    #
    # The DECISION is inside the tolerance, not just the surrender under it
    # ({#reap}), because asking it WIDENS the duck an actor owes: `failed?`
    # reaches through to `stopped?` and `dead?`, which a registration holding a
    # stand-in that owed only `#stop` cannot answer -- and #stop is what every
    # reactor-owning caller runs from an `ensure`, where a raise during teardown
    # leaves the root task never completing and the process HANGS in epoll
    # instead of failing (measured, cli/wiring_spec). A guarantee that a reap
    # cannot wedge the fleet has to cover the question as well as the answer.
    #
    # Answering FALSE, and journaling nothing: "I cannot tell whether this row
    # crashed" is not "it crashed". A {WorkerReaped} here would put a failed
    # reap of a healthy worker into the experiment record, and surrendering on a
    # guess would hand a live worker's checkout away -- so the row falls through
    # to exactly the plain release it got before the reap existed. That is the
    # opposite verdict from {#reap}'s rescue, which records because there a reap
    # was genuinely attempted and genuinely failed.
    #
    # @return [Boolean]
    def reapable?(registration)
      registration.failed? && !claim(registration).nil?
    rescue StandardError
      false
    end

    # The reap claim. `Set#add?` answers nil for a member already present, and a
    # fiber cannot switch inside it -- so the claim is taken before the handoff
    # can reach its first suspension point, which is what makes two concurrent
    # adoptions (or an adoption racing {#stop}) surrender one row exactly once.
    # The real {Isolation::WorkerHandoff}'s own released?-then-anchor guard is
    # check-then-act and survives only because Mixlib::ShellOut blocks the whole
    # reactor; that is a property of that collaborator, not of this loop, and a
    # fiber-aware handoff double-surrenders without this (measured).
    #
    # NOT handed back on failure: one attempt, then the record says what
    # happened -- {Isolation::WorkerHandoff}'s own posture on a refusal it
    # cannot retry, and what keeps a broken handoff from journaling once per
    # adoption forever.
    #
    # @return [Registration, nil] the row when THIS call took its attempt, nil
    #   when an earlier one already had it
    def claim(registration) = @reaped.add?(registration) && registration

    def next_worker_id(role)
      @worker_seq += 1
      "#{role}-#{@worker_seq}"
    end

    # A crashed worker's lease outlives its actor: {Restart} replays it under a
    # NEW worker_id, so nothing else ever reclaims the dead one and a multi-day
    # epic run accumulates one orphan worktree per crash. A bare `lease.release`
    # would be worse than the leak -- {Isolation::Worktree} reclaims a
    # `--detach`ed checkout with `--force`, so the instant it is released an
    # unanchored commit is unreachable, and a crashed worker is exactly the one
    # holding commits nothing else has. The handoff is what makes giving it up
    # safe: anchor under `refs/lain/worker/`, then release, spawning no resolver
    # (an unbounded provider round trip has no business inside a restart).
    #
    # BEFORE the acquire under it, so the dead worker's work is on its ref -- and
    # offered to the parent -- while the replacement's checkout is still to be
    # cut. A reaped row STAYS in the registry, since it is the honest history of
    # the first life ({Restart}'s "Identity" note), so this runs over it again at
    # every later adoption; {#claim} is what makes the repeat cost one set
    # lookup instead of a second surrender.
    #
    # Claiming the whole batch before reaping any of it is deliberate, not an
    # accident of `select`-then-`each`: the claims land in one unbroken stretch
    # of this fiber, so no concurrent adoption can slip between them.
    def reap_crashed
      select { |registration| reapable?(registration) }.each { |registration| reap(registration) }
    end

    # The acquire and the registration append both ride INSIDE the adopted task
    # (review fix 2). `registered` guards the reclaim: any exit that did NOT
    # reach a live registration -- a launch that raised, OR the adopted task
    # CANCELLED after the acquire (Async::Stop is an Exception, not a
    # StandardError, so a `rescue StandardError` would miss it and strand an
    # orphan worktree invisible to #stop) -- releases the lease on the way out.
    # `ensure` is the only exit that runs on cancellation too, so it is the one
    # place the reclaim cannot be skipped; `&.` covers the acquire itself
    # raising, which provisioned nothing to reclaim.
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

  # Reopened rather than nested mid-body -- the shutdown.rb idiom: each of
  # these is its own responsibility, and the split keeps every class body
  # within Metrics/ClassLength instead of loosening it.
  class Supervisor
    # One registry row: the role the adoption named, the live actor it holds,
    # the isolation {Isolation::Lease} that actor runs under, and the worker_id
    # that lease was taken under. State is DERIVED from the actor's own
    # predicates on every read -- a stored status field would go stale the
    # moment a fiber failed.
    Registration = Data.define(:role, :actor, :lease, :worker_id) do
      def address = actor.address

      def head_digest = actor.timeline.head_digest

      # Reclaim the worker's leased environment. A no-op on the shared-process
      # {Isolation::Null} lease (its on_release does nothing), so releasing one
      # worker's lease never tears down state a still-running sibling shares;
      # a Worktree lease removes exactly this worker's own checkout.
      def release = lease.release

      # Give the lease up the way a worker that CRASHED has to have it given up:
      # through the handoff, which anchors the commits before the release under
      # it destroys the checkout ({Supervisor#reap_crashed}). `worker_id` rides
      # along because it is what {Isolation::Worktree::Handback} names the ref
      # from -- so a human finds the work under the id the registry showed.
      def surrender(handoff) = handoff.surrender(lease, worker_id:)

      # Dead but never stopped -- {Registration#state}'s :failed, which is the
      # crash. An operator's own #stop is deliberate and is reclaimed with the
      # rest of the fleet, so it is not reaped out from under them here.
      def failed? = state == :failed

      # :running covers parked-and-serviceable; :failed is dead-but-not-stopped
      # ({Tools::Subagent::Actor#dead?}'s distinction); :stopped wins over
      # :failed because the operator's stop is the later, deliberate fact.
      def state
        return :stopped if actor.stopped?

        actor.dead? ? :failed : :running
      end

      # The {CLI::Shutdown} drain duck. Draining awaits QUIESCENCE: a live
      # actor is awaited through its own #settle; a dead one (stopped, or
      # failed its turn) is already quiescent, and re-raising its captured
      # failure here would tear down the very drain that is closing the
      # session record -- the failure belongs to whoever awaits the actor
      # through #settle directly, not to shutdown.
      #
      # The rescue is the second half of that rule (review fix 1, the
      # check-then-wait hole): an actor LIVE at the dead? check can fail
      # DURING the await, and that failure must be absorbed the same way --
      # it stays loud for direct callers because {Tools::Subagent::Actor#settle}
      # re-raises the captured failure on every call. {Drain}'s own timeout is
      # the one exception: it must pass through to the Drain that armed it,
      # or one swallowed expiry would let the settle loop run unbounded again.
      def settle
        actor.settle unless actor.dead?
        self
      rescue Async::TimeoutError
        raise
      rescue StandardError
        self
      end
    end

    # The wired-nothing handoff ({#reap_crashed}'s default), and deliberately
    # NOT {Isolation::WorkerHandoff::Null}, which releases: with no handoff
    # wired there is nothing here that can anchor, and releasing a crashed
    # worker's `--detach`ed checkout with nothing anchored is what makes its
    # commits unreachable. So the wired-nothing answer is KEEP IT -- one idle
    # worktree until #stop, which is what a crash costs today, rather than the
    # work. Wire an {Isolation::WorkerHandoff} to make the reap happen.
    #
    # It answers the one message the reap sends, not the whole WorkerHandoff
    # duck: a Supervisor never reclaims a SETTLED worker (an actor's completion
    # is its own #stop), so a `#reclaim` here would be a method with no caller.
    module Retain
      def self.surrender(_lease, **) = Isolation::WorkerHandoff::Report.nothing
    end

    # The wired-nothing default ({Tools::Subagent}, {CLI::Conductor}): answers
    # the whole duck -- not running, nothing registered, adoption refused --
    # so no caller writes `if supervisor`. A module, like
    # {Tools::Subagent::Log::Null}: there is no per-instance state.
    module Null
      extend Enumerable

      def self.running? = false

      def self.each
        return enum_for(:each) unless block_given?

        self
      end

      # As loud as adopting before {Supervisor#run}: with no supervisor there
      # is no reactor task, and a silently-current-task launch is the wedge.
      def self.adopt(role:, &_launch)
        raise NotRunning, "no supervisor is wired; construct a Supervisor and #run it (adopting role: #{role})"
      end

      # Nothing to drain -- the bounded view of an empty fleet is empty.
      def self.drain(**) = []
    end
  end

  class Supervisor
    # Journaled when a bounded {Drain} gives up: the timeout is in the record
    # ("drain_timed_out" on the wire), never silently dropped. `roles` is the
    # whole fleet at expiry -- which registration was mid-settle is not
    # knowable from outside the loop, and the honest record is "these were
    # being drained when the window closed".
    DrainTimedOut = Data.define(:within, :roles) do
      include Telemetry::Journalable
    end

    # What a crashed worker's reap did, in the experiment record ({#reap}). The
    # {Isolation::WorkerHandoff::Report} it carries is the ONLY thing that ever
    # names {Isolation::WorkerHandoff::STRANDED} -- a parent checkout left
    # mid-merge, whose remedy is a person running `git merge --abort` and whose
    # cost until they do is that every later handback declines, silently, around
    # `<<<<<<<` markers standing in their working tree. `summary` is the
    # Report's own one-line answer (it names the ref the work is on); `stranded`
    # lifts the one state a human must act on out of that prose so a HUD or a
    # bench query can filter on it. `worker_key` is the STRING worker_id, the
    # join key {Telemetry::Handback} and {Telemetry::IsolationLease} already
    # share. Journals as "worker_reaped".
    WorkerReaped = Data.define(:role, :worker_key, :kind, :ref, :stranded, :summary) do
      include Telemetry::Journalable

      # STRANDED has no kind of its own: {Isolation::WorkerHandoff#told}
      # escalates a stranded restoration by APPENDING that sentence to whatever
      # detail the Report already carried, so matching the constant is the only
      # way to read it back out. The constant and not a copy of its text, so the
      # two cannot drift apart in silence.
      def self.from(registration, report)
        new(role: registration.role, worker_key: registration.worker_id, kind: report.kind, ref: report.ref,
            stranded: report.detail.include?(Isolation::WorkerHandoff::STRANDED), summary: report.summary)
      end

      # A handoff that raised where its own contract answers a Report. There is
      # no Report, so `stranded` is false in the honest sense of "nothing
      # reported it" -- the raise is what a reader acts on here.
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

    # The one settle {Supervisor#drain} hands Shutdown: the whole fleet,
    # bounded. `with_timeout`'s expiry raises at whichever parked settle is in
    # flight; {Registration#settle} deliberately re-raises exactly that class
    # (see its comment), so the bound cannot be swallowed by the same rescue
    # that absorbs actor failures.
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
    # The OM-6 render seam (the chunk-fixes T6 residual): {Context::Mailbox}
    # binds its frozen {Context::Mailbox::Snapshot} at construction, but a
    # pipeline is built ONCE while the snapshot must be per-turn -- an Agent
    # whose pipeline held a constructed Mailbox would fold the same stale
    # snapshot forever. This object is both sides of the seam at once: the
    # Agent's `mailbox:` duck ({#capture}, the ONE live read of the mutable
    # log, at turn start) and a pipeline combinator ({#call}) folding whatever
    # {#capture} pinned for the in-flight turn. The Agent captures BEFORE it
    # renders (Agent#step) and commits from the SAME returned snapshot, so
    # render and commit consume one frozen value by construction -- the
    # frozen-log-snapshot-per-turn ruling, with the pipeline now reading the
    # per-turn binding instead of a construction-time one.
    #
    # Deliberately NOT frozen, unlike every other combinator: the per-turn
    # snapshot slot is the point. Purity holds per snapshot -- renders between
    # captures fold byte-identically -- and the slot has a single writer, the
    # Agent's own fiber, which writes strictly before the render that reads it.
    # That write-then-read is one synchronous stretch of that fiber: the only
    # yield inside a turn is the provider round trip, which comes AFTER the
    # render, so no message arrival can slip between capture and fold.
    class TurnMailbox < Context::Combinator
      def initialize(source:)
        super()
        @source = source
        @snapshot = Context::Mailbox::Null
      end

      # The Agent's mailbox duck: capture THIS turn's snapshot, and remember
      # it for the render that follows within the same turn.
      #
      # @param timeline [Timeline] the head this turn renders from
      # @return [Context::Mailbox::Snapshot]
      def capture(timeline)
        @snapshot = @source.capture(timeline)
      end

      # The pipeline stage: fold the pinned snapshot. Before the first capture
      # the slot holds {Context::Mailbox::Null}, whose empty pending set makes
      # this the identity -- a seam with no turn in flight changes nothing.
      def call(messages)
        Context::Mailbox.new(snapshot: @snapshot).call(messages)
      end
    end
  end
end

# Restart reopens Supervisor and its records mix in Telemetry::Journalable
# (long loaded), so it loads after the class body -- supervisor.rb is this
# subtree's index, the effect/handler.rb convention.
require_relative "supervisor/restart"
