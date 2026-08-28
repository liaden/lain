# frozen_string_literal: true

require "async"

module Lain
  module CLI
    # A `#<<` sink on the live-view tee ({JournalTee}) that gives each spawned
    # subagent a tmux window running `lain watch <spawn-digest>`, and marks the
    # window title done when that actor's lineage closes. The window is never
    # killed: the human closes it, after reading whatever the watch showed.
    #
    # The sink ONLY enqueues. Its `#<<` runs inside the tee fan-out -- the path
    # every telemetry record traverses -- so a synchronous shell-out there
    # would put tmux's process-spawn latency on every record. This class owns
    # OBSERVATION (what a record means); the nested {Pump} owns EXECUTION (the
    # queue, the fiber that drains it, the {TmuxSurface}), and the two never
    # share a stack.
    #
    # Spawns can burst (`fan_out`), so windows are capped per turn. Beyond the
    # cap nothing is silently dropped: the un-windowed actors are collected
    # and, at the next turn boundary (see {#boundary?}) or at latest on the
    # teardown {#drain_pending}, ONE {WindowsCapped} record lands on the pump's
    # `notice` sink naming each actor and the exact `lain watch <digest>`
    # command that window would have run.
    #
    # Opening a window is not the same as the window working. tmux answers the
    # instant its SERVER accepts `new-window`, so a watch command a pane cannot
    # run leaves a window that blinks out with the client told nothing -- how a
    # `lain` absent from a pane's non-interactive `$SHELL -c` PATH went
    # unreported for the life of this feature. Each opened window is therefore
    # asked about once, a turn later, and a {WindowDied} record names the ones
    # that did not survive.
    #
    # That readability is bought with screen space, and the bill lands on the
    # human named above as the one who closes windows. A watch command that
    # fails now leaves its pane on screen reading `Pane is dead (status ...)`
    # instead of vanishing, and nothing here reaps it: one corpse per FAILED
    # spawn, up to {CAP_PER_TURN} a turn and unbounded across a session, all
    # of it cleared by hand. `failed` and not `on` is what keeps the bill
    # proportional -- a watch that exits cleanly still closes its own window,
    # so a healthy fleet accumulates nothing and only a broken one litters.
    #
    # The spawn record carries no role name, so "named for its role" rides the
    # injected `role_for:` seam; unwired, windows fall back to
    # {FALLBACK_ROLE} plus the digest short form.
    class FleetWindows
      # At most this many windows open per turn; the rest are named in a
      # {WindowsCapped} notice instead.
      CAP_PER_TURN = 4

      # Appended to a window's title when its actor's lineage closes.
      DONE_MARK = "[done]"

      # The digest-hex width a window name carries -- enough to disambiguate
      # siblings, short enough for a tmux status line.
      SHORT = 8

      # The {Tools::Subagent} tool's own default name, restated rather than
      # imported: reaching into the Tools tree from the CLI would invert a
      # dependency this class does not have.
      FALLBACK_ROLE = "subagent"

      # No role seam wired: every spawn falls back to {FALLBACK_ROLE}.
      ROLELESS = ->(_record) {}

      # The same duck with nothing behind it: outside tmux, or without
      # --windows, no window machinery constructs and spawn behavior is
      # unchanged.
      class Null
        def <<(_event) = self
        def notice=(sink); end
        def drain_pending = self
      end

      # The one attributed record for a capped burst: `actors` names each
      # un-windowed actor -- spawn digest, role (nil when no seam resolves
      # one), and the `lain watch <digest>` command the human can run by hand
      # -- so the watch capability is never silently dropped.
      WindowsCapped = Data.define(:actors) do
        include Telemetry::Journalable

        def initialize(actors:) = super(actors: Canonical.normalize(actors))
      end

      # The one attributed record for a window that did not outlive its own
      # opening: the spawn it was for, the window name that carried the role,
      # the command tmux was asked to run, and the status the pane died with.
      # Written only when there IS a status -- see {Pump::Check} for why that
      # is the whole evidence. Without this record, a `lain` missing from a
      # pane's non-interactive `$SHELL -c` PATH is a window that blinks out
      # with nobody told.
      WindowDied = Data.define(:digest, :window, :command, :status) do
        include Telemetry::Journalable

        def initialize(**fields) = super(**fields.transform_values { |value| Canonical.normalize(value) })
      end

      # The execution half. Everything here happens OFF the tee fan-out path
      # -- that separation is this object's whole reason to exist apart from
      # the sink.
      class Pump
        # Transient under whatever task first fed the sink: the reactor stops
        # it at its queue park when that parent finishes, so an idle pump can
        # never hang shutdown. Outside any reactor there is nothing to spawn
        # onto; commands stay queued and the next enqueue under a reactor
        # retries (see {#ensure_task}).
        DEFAULT_SPAWNER = lambda do |&pump|
          Async::Task.current?&.async(transient: true, &pump)
        end

        # One queued window-open, asking the surface to hold the pane if its
        # command exits non-zero -- a pane that cannot start is destroyed in
        # milliseconds, and holding it is the only thing that leaves {Check}
        # anything to read.
        Open = Data.define(:command, :name, :session) do
          def perform(pump)
            pump.surface.window(command:, name:, target_session: session, keep_failed: true)
          end
        end

        # One queued liveness question, and the record it may produce. Held
        # back a whole turn by {FleetWindows#release_checks} before it is
        # queued -- see there for why the wait is a turn and not a timer.
        #
        # The evidence is the STATUS, never the window's presence. A pane held
        # by `remain-on-exit failed` always leaves a status behind when its
        # command died, so a window merely gone is a clean exit or a human who
        # closed it -- and journalling either as a death would put a lie in
        # the experiment record, which is worse there than a gap. Keying on
        # the status is also what lets a done-marked window still be asked
        # about: a `[done]` title sitting over a dead pane is exactly the case
        # presence cannot tell apart and a status can.
        #
        # {Mark}'s rescue, for {Mark}'s reason, and here it is load-bearing
        # twice over: a check that cannot ask tmux anything has no evidence,
        # which is the same as no record -- and {FleetWindows#drain_pending}
        # performs on the CALLER's stack, which at teardown is an `ensure`
        # that may already be unwinding another exception.
        Check = Data.define(:target, :digest, :window, :command) do
          def perform(pump)
            status = pump.surface.window_state(target:).status
            pump.notice << WindowDied.new(digest:, window:, command:, status:) if status
            self
          rescue TmuxSurface::TmuxUnavailable
            self
          end
        end

        # One queued done-marker rename. A vanished target means the human
        # already closed the window, so the loud
        # {TmuxSurface::TmuxUnavailable} is caught HERE, the one place
        # "already gone" is known to be benign.
        Mark = Data.define(:target, :title) do
          def perform(pump)
            pump.surface.rename_window(target:, name: title)
          rescue TmuxSurface::TmuxUnavailable
            self
          end
        end

        # Queued like the shell-outs: the notice sink is a journal (fsync) or
        # a channel, and neither write belongs on the tee fan-out path.
        Notice = Data.define(:record) do
          def perform(pump) = pump.notice << record
        end

        attr_reader :surface

        # Writable because the tee this sink rides is built around it:
        # {LiveViews} wires the sink into the tee, then points `notice` at the
        # session journal the tee wraps.
        attr_accessor :notice

        def initialize(surface:, notice:, spawner:)
          @surface = surface
          @notice = notice
          @spawner = spawner
          @queue = Thread::Queue.new
          @task = nil
        end

        # @return [self]
        def enqueue(command)
          @queue << command
          ensure_task
          self
        end

        # Perform everything queued, on the CALLER's stack: the deterministic
        # seam a spec (or a teardown flush) drives instead of racing the fiber.
        #
        # The `empty?`-guarded blocking `pop` is FIBER-only safe, and that is
        # the whole deployment: both consumers share one reactor thread, and
        # fibers interleave only at await points -- there is none between the
        # `empty?` check and the `pop`, so the pop can never block on an item
        # another consumer stole. A second OS thread consuming this queue would
        # reintroduce exactly that race; do not add one.
        #
        # @return [self]
        def drain_pending
          perform(@queue.pop) until @queue.empty?
          self
        end

        private

        # Spawned lazily (construction happens before any reactor exists) and
        # respawned when a prior task finished. Safe to call mid-fan-out:
        # {#drain} yields before its first pop, so the eager depth-first start
        # of `.async` parks instead of performing.
        def ensure_task
          @task = @spawner.call { drain } if @task.nil? || @task.finished?
        end

        # `sleep(0)` FIRST: `.async` runs a new task eagerly on the caller's
        # stack up to its first await, and the caller here is the tee fan-out
        # -- yielding before the first pop is what keeps every perform on this
        # fiber. `loop` needs no break: the reactor stops a transient task at
        # its queue park when the parent finishes.
        def drain
          sleep(0)
          loop { perform(@queue.pop) }
        end

        def perform(command) = command.perform(self)
      end

      # Live only when the operator asked (--windows) AND there is a tmux to
      # open windows in.
      #
      # @param options [Hash] the invoked command's parsed flags
      # @param env [Hash] the process environment, read for TMUX
      # @option options [Boolean] :windows whether the operator asked for windows
      # @return [FleetWindows, Null]
      def self.for(options, env: ENV)
        return Null.new if !options[:windows] || env["TMUX"].to_s.empty?

        new(surface: TmuxSurface.new)
      end

      # @param surface [TmuxSurface] the one object that shells out to tmux
      # @param watch_command [String] the command prefix a window runs; the
      #   spawn digest is appended
      # @param cap [Integer] windows allowed per turn before capping
      # @param role_for [#call] record -> role name (nil for no role); the
      #   seam a roster-aware wiring can fill later
      # @param notice [#<<] where a {WindowsCapped} record lands
      # @param session [String, nil] tmux session to open windows in; nil
      #   lets tmux pick the current one (the production case -- this sink
      #   only constructs live inside $TMUX)
      # @param spawner [#call] takes the pump block, answers a task duck
      #   (#finished?) or nil; injectable so specs drain deterministically
      def initialize(surface:, watch_command: "lain watch", cap: CAP_PER_TURN, role_for: ROLELESS,
                     notice: Channel::Null.instance, session: nil, spawner: Pump::DEFAULT_SPAWNER)
        @watch_command = watch_command
        @cap = cap
        @role_for = role_for
        @session = session
        @pump = Pump.new(surface:, notice:, spawner:)
        # Every spawn digest ever observed, windowed or capped, open or closed
        # -- membership, not state, so it never shrinks. @windows holds only
        # the OPEN windows and their names.
        @seen = Set.new
        @windows = {}
        @overflow = []
        @unverified = []
        @opened = 0
      end

      # The tee leg: duck-typed recognition exactly like {StatusFeed}.
      # Anything unrecognized is inert. Never blocks, never shells out.
      #
      # @return [self]
      def <<(event)
        turn_boundary if boundary?(event)
        observe(event) if event.respond_to?(:kind)
        self
      end

      # See {Pump#notice=} -- the wiring's late-binding seam.
      def notice=(sink)
        @pump.notice = sink
      end

      # The teardown flush: release any still-held {WindowsCapped} notice and
      # any held liveness check FIRST, because a session can end without any
      # boundary record reaching this sink at all (the closers land in the raw
      # session journal, not the tee) and neither must be stranded. A session
      # that ends between a window opening and the next boundary would
      # otherwise lose the death record permanently, leaving an operator whose
      # only signal is a corpse pane they may never look at. See
      # {Pump#drain_pending} for why the drain is safe beside a live pump
      # fiber.
      #
      # @return [self]
      def drain_pending
        release_notice
        release_checks
        @pump.drain_pending
        self
      end

      private

      # A turn ends in one of three records: the {Telemetry::TurnUsage} a
      # successful round trip journals, or the `#head`-anchoring closers a
      # failure path writes instead ({Telemetry::RunInterrupted} for Ctrl-C or
      # grace expiry, {Telemetry::SessionClosed}). Waiting for TurnUsage alone
      # stranded the held notice on every interrupted turn.
      def boundary?(event) = event.respond_to?(:usage) || event.respond_to?(:head)

      def observe(event)
        case event.kind
        when :spawn then observe_spawn(event)
        when :message then observe_close(event)
        end
      end

      # Keyed by the standing @seen set, NOT by open-window membership: a
      # redelivered spawn -- the tee replaying, a record landing again after
      # its terminal already closed the window, a warm start feeding recorded
      # history back through the sinks -- must never re-window an actor this
      # process has already seen, done-marked or not.
      def observe_spawn(record)
        digest = record.digest
        return if @seen.include?(digest)

        @seen << digest
        @opened < @cap ? open_window(record, digest) : hold_back(record, digest)
      end

      def open_window(record, digest)
        name = "#{window_role(record)}-#{short(digest)}"
        command = "#{@watch_command} #{digest}"
        @windows[digest] = name
        @opened += 1
        @pump.enqueue(Pump::Open.new(command:, name:, session: @session))
        @unverified << Pump::Check.new(target: window_target(name), digest:, window: name, command:)
      end

      def hold_back(record, digest)
        @overflow << { "digest" => digest, "role" => @role_for.call(record),
                       "watch" => "#{@watch_command} #{digest}" }
      end

      # A lineage closes on a terminal message -- the actor farewell's
      # `lifecycle: "stopped"` marker, or a one-shot's `result` body -- and the
      # closed spawn is whichever windowed digest the record's causal_parents
      # name. Deleting the window entry makes a redelivered terminal a no-op,
      # so the rename never fires twice at a title that no longer matches.
      # {Telemetry::SpawnLifecycle} is asked rather than tested inline, so
      # {StatusFeed} can ask the same question of the same records instead of
      # growing its own copy of it.
      def observe_close(record)
        return unless Telemetry::SpawnLifecycle.new(record).terminal?

        digest = Array(record.causal_parents).find { |parent| @windows.key?(parent) }
        released = digest && @windows.delete(digest)
        @pump.enqueue(Pump::Mark.new(target: window_target(released), title: "#{released} #{DONE_MARK}")) if released
      end

      def turn_boundary
        @opened = 0
        release_notice
        release_checks
      end

      def release_notice
        return if @overflow.empty?

        @pump.enqueue(Pump::Notice.new(record: WindowsCapped.new(actors: @overflow)))
        @overflow = []
      end

      # A window is asked about ONCE, and not until the turn that opened it
      # has ended. The tmux server reaps a pane asynchronously to the client
      # that opened it, so a question issued straight behind the open reads a
      # pane that has not died yet -- measured at roughly one miss in eight
      # against a real server. A turn is slack enough, and it is slack the
      # sink already has: no timer, no second fiber, and nothing that polls.
      #
      # Every held check is released, none filtered. Asking too soon cannot
      # lie -- an undead pane reads alive and writes nothing -- while not
      # asking loses the record permanently, and these windows outlive the
      # sink that opened them, so there is no teardown during which the
      # question stops being fair.
      def release_checks
        @unverified.each { |check| @pump.enqueue(check) }
        @unverified = []
      end

      def role_of(record) = @role_for.call(record) || FALLBACK_ROLE

      # Allowlisted to [A-Za-z0-9 _-] because tmux format-expands `new-window
      # -n` names (a role spelling `#{pane_pid}` would render as a PID in the
      # status line), and `.` / `:` are pane/window separators inside the
      # `=name` rename target -- either silently swallows the done marker.
      def window_role(record) = role_of(record).gsub(/[^A-Za-z0-9 _-]/, "-")

      # "blake3:5aaa1111…" -> "5aaa1111": the algorithm prefix earns nothing
      # in a status line; the watch COMMAND keeps the full digest.
      def short(digest) = digest.to_s.split(":").last.to_s[0, SHORT]

      # One spelling for every question this sink asks about a window it
      # opened -- the done-marker rename and the liveness check both. See
      # {TmuxSurface.exact_window} for why the match has to be exact.
      def window_target(name) = TmuxSurface.exact_window(name, session: @session)
    end
  end
end
