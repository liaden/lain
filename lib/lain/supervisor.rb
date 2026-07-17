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

    # @param journal [#<<] where a bounded {Drain}'s timeout record lands;
    #   the Null channel by default.
    def initialize(journal: Channel::Null.instance)
      @journal = journal
      # An Array, not an address-keyed Hash: an address is the :spawn event's
      # CONTENT digest, and two spawns of the same arm from the same head
      # legitimately share one -- the registry records ADOPTIONS, in adoption
      # order, so a colliding address must not silently drop a live actor.
      @registry = []
      @task = nil
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
    # @param role [String] what this actor is for -- the registry's label
    # @yieldreturn [Tools::Subagent::Actor] the launched actor
    # @return [Tools::Subagent::Actor]
    def adopt(role:, &launch)
      raise NotRunning, "no reactor task is running; #run this supervisor under an orchestration reactor first" unless
        running?

      @task.async do
        launch.call.tap { |actor| @registry << Registration.new(role:, actor:) }
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
    # @return [self]
    def stop
      return self unless running?

      each { |registration| registration.actor.stop }
      @task.stop
      @task.wait
      self
    end
  end

  # Reopened rather than nested mid-body -- the shutdown.rb idiom: each of
  # these is its own responsibility, and the split keeps every class body
  # within Metrics/ClassLength instead of loosening it.
  class Supervisor
    # One registry row: the role the adoption named, and the live actor it
    # holds. State is DERIVED from the actor's own predicates on every read --
    # a stored status field would go stale the moment a fiber failed.
    Registration = Data.define(:role, :actor) do
      def address = actor.address

      def head_digest = actor.timeline.head_digest

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
