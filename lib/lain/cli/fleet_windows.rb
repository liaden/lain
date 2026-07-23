# frozen_string_literal: true

require "async"

module Lain
  module CLI
    # A `#<<` sink on the live-view tee ({JournalTee}) that gives each spawned
    # subagent a tmux window running `lain watch <spawn-digest>` (T7's
    # read-only tail), and marks the window title done when that actor's
    # lineage closes -- an actor's "stopped" farewell, or a one-shot's result
    # message. The window is never killed: the human closes it, after reading
    # whatever the watch showed.
    #
    # The sink ONLY enqueues. Its `#<<` runs inside the tee fan-out -- the
    # path every telemetry record traverses -- so a synchronous shell-out
    # there would put tmux's process-spawn latency on every record. This
    # class owns OBSERVATION (what a record means: a window owed, a done
    # marker owed, a cap notice owed); the nested {Pump} owns EXECUTION (the
    # queue, the fiber that drains it, the {TmuxSurface} the commands run
    # against), and the two never share a stack.
    #
    # Spawns can burst (`fan_out`), so windows are capped per turn
    # (CAP_PER_TURN, the pre-made orchestrator ruling). Beyond the cap
    # nothing is silently dropped: the un-windowed actors are collected and,
    # at the next turn boundary ({Telemetry::TurnUsage} on the happy path,
    # the RunInterrupted/SessionClosed closers on the failure paths -- see
    # {#boundary?}) or at latest on the teardown {#drain_pending}, ONE
    # {WindowsCapped} record lands on the pump's `notice` sink naming each
    # actor and the exact `lain watch <digest>` command that window would
    # have run.
    #
    # The spawn record carries no role name (its payload is the spawn
    # policy's prefix/posture/only), so "named for its role" rides the
    # injected `role_for:` seam; unwired, windows fall back to the
    # {Tools::Subagent} tool's own default name plus the digest short form.
    class FleetWindows
      # The orchestrator's pre-made ruling for spawn bursts: at most this
      # many windows open per turn; the rest are named in a WindowsCapped
      # notice instead.
      CAP_PER_TURN = 4

      # Appended to a window's title when its actor's lineage closes.
      DONE_MARK = "[done]"

      # The digest-hex width a window name carries -- enough to disambiguate
      # siblings, short enough for a tmux status line.
      SHORT = 8

      # The window name when no `role_for:` seam is wired -- the
      # {Tools::Subagent} tool's own default name, restated rather than
      # imported (the {StatusFeed::INBOX_RECIPIENT} reasoning: reaching into
      # the Tools tree from the CLI would invert a dependency this class
      # does not have).
      FALLBACK_ROLE = "subagent"

      # No role seam wired: every spawn falls back to {FALLBACK_ROLE}.
      ROLELESS = ->(_record) {}

      # The same duck with nothing behind it -- the AC's Null sink: outside
      # tmux, or without --windows, no window machinery constructs and spawn
      # behavior is unchanged.
      class Null
        def <<(_event) = self
        def notice=(sink); end
        def drain_pending = self
      end

      # The one attributed record for a capped burst: `actors` names each
      # un-windowed actor -- its spawn digest, its role (nil when no seam
      # resolves one), and the `lain watch <digest>` command the human can
      # run by hand -- so the watch capability is never silently dropped.
      WindowsCapped = Data.define(:actors) do
        include Telemetry::Journalable

        def initialize(actors:) = super(actors: Canonical.normalize(actors))
      end

      # The execution half: the command queue, the transient fiber draining
      # it, and the collaborators queued commands run against. Everything
      # here happens OFF the tee fan-out path -- that separation is this
      # object's whole reason to exist apart from the sink.
      class Pump
        # The pump fiber, transient under whatever task first fed the sink
        # -- the reactor stops it at its queue park when that parent
        # finishes, so an idle pump can never hang shutdown. Outside any
        # reactor there is nothing to spawn onto; commands stay queued and
        # the next enqueue under a reactor retries (see {#ensure_task}).
        DEFAULT_SPAWNER = lambda do |&pump|
          Async::Task.current?&.async(transient: true, &pump)
        end

        # One queued window-open.
        Open = Data.define(:command, :name, :session) do
          def perform(pump) = pump.surface.window(command:, name:, target_session: session)
        end

        # One queued done-marker rename. A vanished target means the human
        # already closed the window -- the marker has nowhere to land, and
        # that is fine, so the loud {TmuxSurface::TmuxUnavailable} is caught
        # HERE, where "already gone" is known to be benign.
        Mark = Data.define(:target, :title) do
          def perform(pump)
            pump.surface.rename_window(target:, name: title)
          rescue TmuxSurface::TmuxUnavailable
            self
          end
        end

        # One queued {WindowsCapped} emission. Queued like the shell-outs:
        # the notice sink is a journal (fsync) or channel, and neither
        # write belongs on the tee fan-out path either.
        Notice = Data.define(:record) do
          def perform(pump) = pump.notice << record
        end

        attr_reader :surface

        # Readable for the commands; writable because the tee this sink
        # rides is built around it -- {LiveViews} wires the sink into the
        # tee, then points `notice` at the session journal the tee wraps.
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

        # Perform everything queued, on the CALLER's stack: the
        # deterministic seam a spec (or a teardown flush) drives instead of
        # racing the fiber.
        #
        # The `empty?`-guarded blocking `pop` is FIBER-only safe, and that
        # is the whole deployment: both consumers (this caller and the pump
        # fiber) share one reactor thread, and fibers interleave only at
        # await points -- there is none between the `empty?` check and the
        # `pop`, so the pop can never block on an item another consumer
        # stole. A second OS thread consuming this queue would reintroduce
        # exactly that race; do not add one.
        #
        # @return [self]
        def drain_pending
          perform(@queue.pop) until @queue.empty?
          self
        end

        private

        # Spawned lazily (construction happens before any reactor exists)
        # and respawned when a prior task finished (it is transient under
        # the task that first fed the sink, so it ends with that ask). Safe
        # to call mid-fan-out: {#drain} yields before its first pop, so the
        # eager depth-first start of `.async` parks instead of performing.
        def ensure_task
          @task = @spawner.call { drain } if @task.nil? || @task.finished?
        end

        # The fiber's whole life. `sleep(0)` FIRST: `.async` runs a new
        # task eagerly on the caller's stack up to its first await (the
        # {Tools::Subagent::Actor#launch} note), and the caller here is the
        # tee fan-out -- yielding before the first pop is what keeps every
        # perform on this fiber. `loop` needs no break: the reactor stops a
        # transient task at its queue park when the parent finishes (the
        # {Conductor} ticker's idiom).
        def drain
          sleep(0)
          loop { perform(@queue.pop) }
        end

        def perform(command) = command.perform(self)
      end

      # A Null-or-live factory for the wiring one-liner: live only when the
      # operator asked (--windows) AND there is a tmux to open windows in.
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
        # Every spawn digest ever observed, windowed or capped, open or
        # closed -- membership, not state, so it never shrinks. @windows
        # (below) holds only the OPEN windows and their names.
        @seen = Set.new
        @windows = {}
        @overflow = []
        @opened = 0
      end

      # The tee leg: duck-typed recognition exactly like {StatusFeed} --
      # `#kind` is a lineage record to observe; a boundary record (see
      # {#boundary?}) resets the window budget and releases any pending
      # {WindowsCapped} notice. Anything else is inert. Never blocks, never
      # shells out.
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

      # The teardown flush: release any still-held {WindowsCapped} notice
      # FIRST -- a session can end without any boundary record reaching this
      # sink at all (the closers land in the raw session journal, not the
      # tee), and the cap notice must never be stranded (the panel's
      # F-notice-loss probe) -- then perform everything queued, on the
      # caller. See {Pump#drain_pending} for why the drain itself is safe
      # beside a live pump fiber.
      #
      # @return [self]
      def drain_pending
        release_notice
        @pump.drain_pending
        self
      end

      private

      # A turn ends in exactly one of three records, and only the first is
      # the happy path: the {Telemetry::TurnUsage} a successful round trip
      # journals, or the closers a failure path writes instead --
      # {Telemetry::RunInterrupted} (Ctrl-C / grace expiry) and
      # {Telemetry::SessionClosed}, the two `#head`-anchoring records.
      # Waiting for TurnUsage alone stranded the held notice on every
      # interrupted turn (F-notice-loss).
      def boundary?(event) = event.respond_to?(:usage) || event.respond_to?(:head)

      def observe(event)
        case event.kind
        when :spawn then observe_spawn(event)
        when :message then observe_close(event)
        end
      end

      # A distinct spawn either earns a window (under the cap) or joins the
      # held-back list for the boundary notice. Keyed by the standing @seen
      # set, NOT by open-window membership: a redelivered spawn -- the tee
      # replaying, a record landing again after its terminal already closed
      # the window, or a future StatusFeed-style warm start feeding recorded
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
        @windows[digest] = name
        @opened += 1
        @pump.enqueue(Pump::Open.new(command: "#{@watch_command} #{digest}", name:, session: @session))
      end

      def hold_back(record, digest)
        @overflow << { "digest" => digest, "role" => @role_for.call(record),
                       "watch" => "#{@watch_command} #{digest}" }
      end

      # A lineage closes on a terminal message -- the actor farewell's
      # machine-readable `lifecycle: "stopped"` marker, or a one-shot's
      # `result` body ({Tools::Subagent::Lineage#message}) -- and the closed
      # spawn is whichever windowed digest the record's causal_parents name.
      # Deleting the window entry makes a redelivered terminal a no-op, so
      # the rename never fires twice at a title that no longer matches.
      def observe_close(record)
        return unless terminal?(record)

        digest = Array(record.causal_parents).find { |parent| @windows.key?(parent) }
        released = digest && @windows.delete(digest)
        @pump.enqueue(Pump::Mark.new(target: mark_target(released), title: "#{released} #{DONE_MARK}")) if released
      end

      def terminal?(record)
        payload = record.payload
        payload.is_a?(Hash) && (payload.key?("result") || payload["lifecycle"] == "stopped")
      end

      def turn_boundary
        @opened = 0
        release_notice
      end

      def release_notice
        return if @overflow.empty?

        @pump.enqueue(Pump::Notice.new(record: WindowsCapped.new(actors: @overflow)))
        @overflow = []
      end

      def role_of(record) = @role_for.call(record) || FALLBACK_ROLE

      # The role's contribution to a window name, allowlisted to
      # [A-Za-z0-9 _-]: tmux format-expands `new-window -n` names (a role
      # "#{pane_pid}" would render as a PID in the status line), and `.` /
      # `:` are pane/window separators inside the `=name` rename target --
      # either would silently swallow the done marker (panel naming probe).
      def window_role(record) = role_of(record).gsub(/[^A-Za-z0-9 _-]/, "-")

      # "blake3:5aaa1111…" -> "5aaa1111": the algorithm prefix earns nothing
      # in a status line; the watch COMMAND keeps the full digest.
      def short(digest) = digest.to_s.split(":").last.to_s[0, SHORT]

      # tmux's `=` target syntax pins an exact window-name match; prefix
      # matching would let "researcher-5aaa" rename "researcher-5aaa1111".
      def mark_target(name) = [@session, "=#{name}"].compact.join(":")
    end
  end
end
