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

    # A row retires once; a second retirement is a caller holding a stale row.
    class AlreadyRetired < Error; end

    # A row whose lease was already released has no checkout left to rebase or
    # anchor, and "nothing to do" would read as an actor that committed
    # nothing.
    class AlreadyReleased < Error; end

    # An actor launched anywhere but its lease's checkout runs its tools in
    # whatever directory it was handed -- the run's own tree, if that.
    class OutsideLease < Error; end

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
    # @param retirement [Retirement, Retirement::Null] how a SETTLED actor's
    #   checkout is given up by {#retire}, and the environment every adopted
    #   actor is handed so that giving it up can ask it to rebase
    def initialize(journal: Channel::Null.instance, isolation: Isolation::Null.new, handoff: Retain,
                   retirement: Retirement::Null)
      @journal = journal
      @isolation = isolation
      @handoff = handoff
      @retirement = retirement
      @retired = Set.new
      # An Array, not an address-keyed Hash: an address is the :spawn event's
      # CONTENT digest. An adopted actor's spawn carries a per-adoption ordinal,
      # so two live twins launched through ONE {Tools::Subagent::Lineage} no
      # longer share an address -- but that count's scope is the WRITER. A
      # second writer over the same head starts the count again, and a resumed
      # run does too. A collision is rarer than it was and is not gone, and it
      # must never drop a live actor.
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
    # @param worker_id [#to_s, nil] the isolation key, and the name the
    #   worker's anchor takes under `refs/lain/worker/`. Minted per adoption by
    #   default, which keeps same-role workers apart on one leased path but
    #   restarts with every Supervisor, so two runs mint the same one. A caller
    #   whose work must stay apart across runs names it -- the epic path passes
    #   the issue's lane, `issue.<slug>.<id>` -- and a name git would not
    #   accept in a ref is refused ({Isolation::WorkerId::Refused}) before
    #   anything is leased.
    # @yieldparam worker_env [WorkerEnv] the leased cwd/env the child runs under
    # @yieldreturn [Tools::Subagent::Actor] the launched actor
    # @return [Tools::Subagent::Actor]
    def adopt(role:, worker_id: nil, &launch)
      raise NotRunning, "no reactor task is running; #run this supervisor under an orchestration reactor first" unless
        running?

      named = Isolation::WorkerId.checked(worker_id) unless worker_id.nil?
      @task.async do
        reap_crashed
        register(role, named || next_worker_id(role), launch)
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

      reject { |registration| retired?(registration) }.each { |registration| farewell(registration) }
      @task.stop
      @task.wait
      self
    end

    # Give up one actor whose work is done: await its first turn, rebase its
    # checkout while it can still be asked, anchor its commits, then stop it
    # and release its lease. It NEVER merges -- the work waits on its ref for
    # whatever lands it, so nothing reaches the working branch ahead of the
    # gate that is meant to stand before it. A failed actor cannot be asked,
    # so its checkout is anchored as it stands.
    #
    # Claimed synchronously, as a reap is ({#claim}), so a retirement and an
    # adoption's reap of the same crashed row cannot both hand it back. The
    # row stays in the registry as the honest history of that life, reads
    # `:stopped`, and {#stop} passes it by.
    #
    # @param registration [Registration] a row this supervisor adopted
    # @return [Isolation::WorkerHandoff::Report] the anchored ref and the full
    #   SHA it holds; `:nothing_to_do` only for an actor that committed
    #   nothing its working branch lacks
    # @raise [AlreadyRetired] for a row already retired
    # @raise [AlreadyReleased] for a row whose lease was already released
    def retire(registration)
      retirable!(registration)
      @retired << registration
      @reaped << registration
      registration.retire(@retirement)
    end

    # @return [Boolean] whether {#retire} has taken this row
    def retired?(registration) = @retired.include?(registration)

    private

    # Every check reads state no fiber can change mid-way, so the claim that
    # follows is as synchronous as a reap's.
    def retirable!(registration)
      worker = registration.worker_id
      raise ArgumentError, "this supervisor never adopted #{registration.role} (#{worker})" unless
        @registry.include?(registration)
      raise AlreadyRetired, "#{worker} was already retired" if retired?(registration)
      # A reap is not a release: {Retain}'s anchors and releases nothing, so a
      # row it reaped still holds its checkout, and is still retirable.
      raise AlreadyReleased, "#{worker}'s lease was already released, so nothing is left to anchor" if
        registration.lease.released?
    end

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
      actor = launch.call(@retirement.editorless(lease.worker_env))
      confine(actor, lease)
      @registry << Registration.new(role:, actor:, lease:, worker_id:)
      registered = true
      actor
    ensure
      lease&.release unless registered
    end

    # A lease that cut a checkout is where its actor's tools must run.
    #
    # A BACKSTOP, behind `launch_actor`'s required `worker_env:`, which is
    # the prevention. An actor's first turn runs eagerly inside its launch,
    # so a tool it calls there has already run by the time this can ask
    # where it stands. What this adds is that such an actor is stopped and
    # never registered, and the `ensure` above releases the lease. An actor
    # that answers no `session` cannot say where it stands, so it is refused
    # by name rather than admitted on trust.
    def confine(actor, lease)
      leased = lease.worker_env
      return if leased.checkout.nil?

      refuse(actor, leased, "answers no session, so it cannot say where it stands") unless
        actor.respond_to?(:session)

      standing = actor.session.worker_env.cwd
      return if File.expand_path(standing) == File.expand_path(leased.cwd)

      refuse(actor, leased, "stands in #{standing}; launch it with the worker_env its adopt block is handed")
    end

    def refuse(actor, leased, why)
      actor.stop
      raise OutsideLease, "the actor adopted into #{leased.cwd} #{why}"
    end
  end

  class Supervisor
    # Reopened rather than nested mid-body: each of these is its own
    # responsibility, and the split keeps every class body within
    # Metrics/ClassLength instead of loosening it.

    # What a retirement's report says of an actor stopped before its first
    # turn settled.
    STOPPED_MIDTURN = "the actor was stopped before its turn settled, so its checkout was anchored as it stood"

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

      # The actor is stopped, its farewell journaled, and its lease released
      # however the retirement ended; the retirement anchors before either.
      def retire(retirement)
        unsettled = unsettled_turn
        return retirement.surrender(lease, worker_id:, detail: unsettled) unless unsettled.empty?

        retirement.settled(lease, worker: actor.worker, worker_id:)
      ensure
        actor.stop
        release
      end

      # Its first turn, awaited: empty once it settled, else why it did not. A
      # cancelled turn resolves `settle` with no failure, so a stop read after
      # it is what says the turn never finished. A drain's own bound still
      # climbs, for {#settle}'s reason.
      def unsettled_turn
        actor.settle
        actor.stopped? ? STOPPED_MIDTURN : ""
      rescue Async::TimeoutError
        raise
      rescue StandardError => e
        "the actor's turn raised #{e.class}: #{e.message}"
      end

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
    # How an actor whose work is done gives its checkout up: rebased onto the
    # working branch while the actor can still be asked, then its commits
    # anchored under `refs/lain/worker/` -- and nothing more. The shape is
    # {Isolation::WorkerHandoff#surrender}'s with the merge left out, because a
    # retired worker's work lands through a gate, never here: the ref is
    # written before the lease under it is released, and nothing that runs a
    # model is spawned.
    #
    # Isolation loads after this file, so its constants are named only inside
    # methods.
    class Retirement
      # One root for the anchor and for reading back what it holds, so the two
      # cannot name different repositories.
      #
      # @param isolation [#base, #repo_root] the backend the actors lease from
      # @param journal [#<<] where each retirement's handback record lands
      # @param strategy [MergeStrategy] the conflict style a rebase is spelled
      #   with, so an actor resolves the markers a merge would have shown it
      # @param retries [Integer] how often a conflicted actor is asked to
      #   rebase its own work; 0 rebases nothing
      def self.over(isolation:, journal: Channel::Null.instance, strategy: Isolation::MergeStrategy::DEFAULT,
                    retries: 1)
        base = isolation.base
        new(sync: Isolation::SelfSync.new(base:, strategy:, retries:), journal:, strategy:,
            anchor: Anchor.new(parent: Isolation::Checkout.new(isolation.repo_root), base:))
      end

      # @param sync [#call, #editorless] {Isolation::SelfSync}
      # @param anchor [#standing, #anchor] {Anchor}: what the worker's ref holds
      #   before any sync, and the anchoring after it
      # @param journal [#<<] where the {Telemetry::Handback} record lands
      # @param strategy [MergeStrategy] named on that record
      def initialize(sync:, anchor:, journal: Channel::Null.instance, strategy: Isolation::MergeStrategy::DEFAULT)
        @sync = sync
        @anchor = anchor
        @journal = journal
        @strategy = strategy
      end

      # What an adopted actor's own shell runs under, so a rebase it is asked
      # to finish never opens an editor it has no terminal to show.
      def editorless(worker_env) = @sync.editorless(worker_env)

      # A settled actor: rebased, asking it through `worker` on a conflict,
      # then anchored.
      #
      # @return [Isolation::WorkerHandoff::Report]
      def settled(lease, worker:, worker_id:)
        kept(lease, worker_id) { @sync.call(lease, worker:, worker_id:) }
      end

      # An actor that did not settle -- its turn raised, or it was stopped
      # mid-turn -- cannot be asked, so its checkout is anchored as it stands,
      # and `detail` carries why onto the report.
      #
      # @return [Isolation::WorkerHandoff::Report]
      def surrender(lease, worker_id:, detail: "")
        kept(lease, worker_id, detail) { Isolation::SelfSync::Result::NONE }
      end

      private

      # A ref already holding work this checkout lacks is refused BEFORE the
      # sync, whose own anchor-first write would move it too. A cancel landing
      # mid-sync still gets its anchor, from the `ensure`, because the release
      # after this reclaims the checkout.
      def kept(lease, worker_id, detail = "")
        raise AlreadyReleased, "#{worker_id}'s lease was already released, so nothing is left to anchor" if
          lease.released?

        standing = @anchor.standing(lease, worker_id:)
        return reported(standing.refusal, Isolation::SelfSync::Result::NONE, detail) if standing.taken?

        outcome = nil
        synced = yield
        outcome = @anchor.anchor(lease, worker_id:, from: standing.head)
        reported(outcome, synced, detail)
      ensure
        unwound(lease, worker_id, standing) unless outcome || standing.nil? || standing.taken? || lease.released?
      end

      # Total, because it runs while a cancel climbs and a raise here would
      # replace it.
      def unwound(lease, worker_id, standing)
        journaled(@anchor.anchor(lease, worker_id:, from: standing.head), Isolation::SelfSync::Result::NONE)
      rescue Exception # rubocop:disable Lint/RescueException
        nil
      end

      def reported(outcome, synced, detail)
        report = Isolation::WorkerHandoff::Report.from(outcome)
        report.with(detail: [report.detail, detail, journaled(outcome, synced)].reject(&:empty?).join("; "))
      end

      # One record per retirement, the sync's facts riding the anchor's. Its
      # `sha` stays nil: on that record a SHA names what landed in the parent,
      # and nothing did. Landing reads this record, so a write that fails is
      # said on the report rather than swallowed.
      #
      # @return [String] empty once journaled, else what the report must carry
      def journaled(outcome, synced)
        @journal << Telemetry::Handback.new(worker_key: outcome.worker_key, outcome: outcome.kind, ref: outcome.ref,
                                            strategy: @strategy.to_s, **synced.to_record)
        ""
      rescue StandardError => e
        "the handback record was not journaled: #{e.class}: #{e.message}"
      end
    end

    class Retirement
      # What a worker's ref holds before its sync, judged against the
      # checkout's own HEAD. `refusal` is the outcome that stops the
      # retirement when the ref already anchors work this checkout lacks.
      Standing = Data.define(:head, :refusal) do
        def taken? = !refusal.nil?
      end

      # Anchors a retired worker's commits under its ref, holding two lines a
      # bare compare-and-swap cannot:
      #
      # - COMMITTED NOTHING READS AS NOTHING, judged against the working
      #   branch's tip and never the parent checkout's HEAD. An epic branch
      #   runs ahead of the checkout a human stands in, so a worker cut from
      #   its tip that committed nothing would otherwise anchor that tip as
      #   its work.
      # - AN ANCHOR IS NEVER MOVED OFF WORK IT HOLDS. The ref moves only to a
      #   commit containing what it holds, or off the value this worker's own
      #   self-sync wrote before rebasing. Anything else is another run's only
      #   anchor, and the retirement is refused. The write is compare-and-
      #   swapped against the value judged.
      #
      # Every failure answers a `:failed` outcome rather than raising.
      class Anchor
        ANCHORED = "lain retirement: anchored"

        KEPT = "lain retirement: kept a commit its worker's ref could not take"

        TAKEN = "%<ref>s already anchors %<held>s, which %<head>s does not contain; an anchor is never moved " \
                "off work it holds, so the refused commit %<head>s is %<kept>s"

        # @param parent [Isolation::Checkout] the repository the refs live in
        # @param base [#tip, #name] the working branch the workers are cut from
        # @param shell_out_factory [#call] builds the subprocess runner for a
        #   worker's own checkout
        def initialize(parent:, base:, shell_out_factory: Lain::Shell::Out.public_method(:new))
          @parent = parent
          @base = base
          @shell_out_factory = shell_out_factory
        end

        # @return [Standing]
        def standing(lease, worker_id:)
          named = Isolation::Worktree::Handback::Naming.new(worker_id)
          head = head_of(lease)
          held = @parent.target(named.ref)
          free = held.empty? || nothing?(head) || within?(held, head)
          Standing.new(head:, refusal: (taken(named, held, head) unless free))
        rescue StandardError => e
          Standing.new(head: nil, refusal: broke(named, e))
        end

        # @param lease [#worker_env] the live lease whose checkout holds the
        #   commits
        # @param worker_id [Object] names the ref
        # @param from [String, nil] the HEAD {#standing} read, which the
        #   self-sync may have anchored before its rebase
        # @return [Isolation::Worktree::Handback::Outcome]
        def anchor(lease, worker_id:, from:)
          named = Isolation::Worktree::Handback::Naming.new(worker_id)
          commit = head_of(lease)
          return outcome(:nothing_to_do, named) if nothing?(commit)

          held = @parent.target(named.ref)
          return anchored(named, commit) if held == commit
          return taken(named, held, commit) unless held.empty? || held == from || within?(held, commit)

          written(named, commit, @parent.update_ref(named.ref, commit, held, reason: ANCHORED))
        rescue StandardError => e
          broke(named, e)
        end

        private

        def head_of(lease)
          head = Isolation::Checkout.new(lease.worker_env.cwd, shell_out_factory: @shell_out_factory).head
          raise Isolation::SelfSync::Failed, "git rev-parse HEAD failed in #{lease.worker_env.cwd}" unless
            head.exitstatus.zero?

          head.stdout.strip
        end

        # Everything the worker has, its working branch already has.
        def nothing?(commit) = @base.name.empty? ? @parent.ancestor?(commit) : within?(commit, @base.tip)

        # Whether `ancestor` is `commit` or reachable from it.
        def within?(ancestor, commit) = ancestor == commit || @parent.ancestor?(ancestor, commit)

        def written(named, commit, shell)
          return anchored(named, commit) if shell.exitstatus.zero?

          Isolation::Worktree::Handback::Outcome.git_failed(named.key, "update-ref #{named.ref}", shell)
        end

        def anchored(named, commit)
          outcome(:declined, named, ref: named.ref, sha: commit, detail: Isolation::Worktree::Handback::ANCHOR_ONLY)
        end

        def taken(named, held, head)
          outcome(:failed, named, detail: format(TAKEN, ref: named.ref, held:, head:, kept: keep_refused(named, head)))
        end

        # The refused commit, on a ref of its own named for the worker and
        # the commit, so the report can say where an operator finds it.
        #
        # @return [String] where it was kept, as the end of the refusal
        def keep_refused(named, head)
          ref = Isolation::Worktree::Handback::Naming.new("#{named.key} refused #{head}").ref
          return "kept on #{ref}" if @parent.target(ref) == head

          written = @parent.update_ref(ref, head, "", reason: KEPT)
          return "kept on #{ref}" if written.exitstatus.zero?

          "not kept on a ref of its own (#{written.stderr.strip}); a release still keeps unreached commits"
        end

        def broke(named, error) = outcome(:failed, named, detail: "#{error.class}: #{error.message}")

        def outcome(kind, named, **) = Isolation::Worktree::Handback::Outcome.new(kind:, worker_key: named.key, **)
      end
    end

    class Retirement
      # No retirement wired: nothing is synced or anchored, so a retired actor
      # is stopped and its lease released exactly as {Supervisor#stop} would,
      # and the environment it is handed is the one it was leased. Its report
      # says exactly that, since whether anything was committed is not a
      # question it asked.
      module Null
        UNWIRED = "no retirement is wired, so nothing was synced or anchored"

        def self.editorless(worker_env) = worker_env
        def self.settled(_lease, **) = Isolation::WorkerHandoff::Report.new(kind: :declined, detail: UNWIRED)
        def self.surrender(_lease, **) = settled(nil)
      end
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
