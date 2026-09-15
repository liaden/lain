# frozen_string_literal: true

require "active_support/core_ext/module/delegation"

module Lain
  module CLI
    # The standing-goal driver: a live, mutable seam the Repl polls between asks
    # and `/goal` writes. It re-prompts the agent toward one objective after
    # each settled turn and halts on the agent's own done marker, an iteration
    # cap, a `/goal off`, or a budget interrupt. No LLM judge decides
    # termination; the marker is a literal token match.
    #
    # Same delegating-slot shape as {Approval::PolicySwitch} and
    # {Context::ModelSwitch}: the Repl holds this ONE object for the session,
    # `/goal` swaps the delegate INSIDE it, and each iteration lands in the
    # Journal attributed to the `goal` surface -- "which turns the driver
    # drove, toward what" is evidence on a study bench. Deliberately MUTABLE
    # coordination state, unlike the frozen value objects: it exists to be
    # switched.
    #
    # `quiescent:` is the sequencing guard: the driver drives NOTHING while the
    # fleet is unquiet (a parked approval, a pending human question), so a
    # driven turn never races a decision the human still owes. {Wiring} answers
    # both halves; the default is always-quiescent, so an unwired driver drives
    # freely.
    #
    # The driver owns the mode's `goal` layer ({Layer}): up while a goal
    # stands, down however it ends. So the layer is never raised by hand -- the
    # switch `/mode` writes through is {#guarding}'s, which refuses it with no
    # goal standing and ends the goal when it is lowered.
    class GoalDriver
      DEFAULT_CAP = 5

      # The literal token the agent replies with to signal the goal is met. A
      # marker, not a judge: termination is explicit by design.
      DONE = "GOAL_COMPLETE"

      SURFACE = "goal"

      # Shared because the done-marker read and the objective match are the
      # same question asked of different turns, and the two must not drift on
      # what "the text of a turn" means.
      module TurnText
        private

        def text_of(content)
          content.select { |block| block.is_a?(Hash) && block["type"] == "text" }
                 .map { |block| block["text"] }.join
        end
      end

      # The idle delegate the Repl polls when no goal is set: "nothing to
      # drive", cheaply and silently, with no journal write and no notice. It
      # satisfies the same duck a {Run} does, so the poll site never guards on
      # a goal being present.
      module Null
        def self.active? = false

        def self.poll(_timeline) = nil

        def self.interrupt = self

        # The write duck too, so the command surface degrades cleanly where no
        # live driver is wired: starting a goal is a no-op that honestly stays
        # idle, never a NoMethodError and never a lie (the command reads
        # `active?` back before it confirms). The `session:` a live driver
        # would pin on is accepted and dropped.
        def self.start(_goal, **) = self

        def self.stop = self

        def self.goal = nil

        # An idle delegate has driven nothing, so it has no objective to
        # protect and nothing to report about failing to.
        def self.settle_pin(_timeline) = self

        def self.close = self

        # A session with no live driver still refuses a `goal` layer nothing drives.
        def self.guarding(switch) = Guard.new(switch:, driver: self)
      end

      # The mode's `goal` layer, moved by the driver through the session's mode
      # switch and attributed to the goal surface. A reader of the switch rather
      # than the switch, because {Wiring} memoizes the driver before a chat's
      # board exists. A flip the layer is already at is not written: a goal
      # ending is every poll's question, and the Journal would carry a flip per
      # idle prompt.
      class Layer
        NAME = :goal

        # The layer of a driver no mode switch was handed: nothing to move.
        module Unswitched
          def self.enable = nil

          def self.disable = nil
        end

        # @param switch [#call] answers the mode switch, which answers
        #   `#current` and `#switch(mode, surface:)`
        def initialize(switch) = @switch = switch

        def enable = move(:enable)

        def disable = move(:disable)

        private

        def move(toggle)
          switch = @switch.call
          before = switch.current
          after = before.with(layers: before.layers.public_send(toggle, NAME))
          switch.switch(after, surface: SURFACE) unless after == before
        end
      end

      # The mode switch as the human writes it, over the one the driver moves.
      # The `goal` layer says a goal is standing, so raising it with none would
      # be a lighter that lies, and lowering it is the human saying stop. It
      # decides on the whole folded mode, so `/mode plan +goal` is refused whole
      # and `/mode !` stops the goal as `-goal` does.
      class Guard
        REFUSAL = "the goal layer shows a standing goal, and none is set -- /goal <objective> sets one and raises it"

        delegate :current, :posture, :layers, :describe, to: :@switch

        def initialize(switch:, driver:)
          @switch = switch
          @driver = driver
        end

        def switch(mode, surface:)
          lowering = standing?(current) && !standing?(mode)
          raise Lain::Error, REFUSAL if standing?(mode) && !standing?(current) && !@driver.active?

          @switch.switch(mode, surface:).tap { @driver.stop if lowering }
        end

        private

        def standing?(mode) = mode.layers.include?(Layer::NAME)
      end

      # @param journal [#record] where each driven iteration lands as evidence
      # @param cap [Integer] the iteration ceiling, reused through {Agent::Budget}
      # @param quiescent [#call] answers whether the fleet is quiet enough to drive
      # @param layer [#enable, #disable] the `goal` mode layer this driver moves
      def initialize(journal:, cap: DEFAULT_CAP, quiescent: -> { true }, layer: Layer::Unswitched)
        @journal = journal
        @cap = cap
        @quiescent = quiescent
        @layer = layer
        @current = Null
        @stopped = []
      end

      def active? = @current.active?

      # Begin driving toward `goal`, replacing whatever the delegate was (a
      # fresh objective resets the iteration count).
      #
      # `session:` is the run's pin-set, threaded in by the WRITER rather than
      # held for the driver's life: {Wiring} memoizes one driver before it can
      # name a session, and `/goal` is the only caller that has both. Defaults
      # to {Session::Null}, so a driver started without one pins nowhere.
      def start(goal, session: Session::Null.instance)
        @current = Run.new(goal:, journal: @journal, cap: @cap, session:)
        @layer.enable
        self
      end

      # `/goal off`, `:LainGoalOff`, `/mode -goal`: retire to idle. The Run is
      # kept for its last words rather than closed here, because a stop carries
      # no timeline and can land before any look at one has found the
      # objective's turn -- mid-iteration, from the editor -- and closing then
      # would journal an objective that went unprotected while it was on the
      # chain all along. {#settle_pin} says them.
      def stop
        @stopped << @current if @current.active?
        retire
      end

      def goal = @current.goal

      # The mode switch the human's `/mode` writes through ({Guard}).
      def guarding(switch) = Guard.new(switch:, driver: self)

      # A Ctrl-C or a supervising timeout stops the driving from outside; the
      # delegate records it and reports it on the next poll.
      def interrupt
        @current.interrupt
        self
      end

      # Polled by the Repl between asks. Yields an inline stop NOTICE when a
      # driven goal ends and returns the next goal-prompt, or nil when there is
      # nothing to drive (idle, just stopped, or deferring while the fleet is
      # unquiet).
      #
      # The objective pin settles FIRST, ahead of both the quiescence gate and
      # the delegate's own poll, and that placement is load-bearing twice over.
      # A DEFERRED poll is exactly when the Repl hands the human back `you>`, so
      # `/goal off` can land on one -- gate the pin and an unquiet fleet strands
      # the objective unprotected forever. And a poll that RETIRES the Run swaps
      # the delegate for the Null, so a pin after it would find nobody left to
      # pin. Idempotent, so calling it every poll is free.
      def poll(timeline, &notice)
        settle_pin(timeline)
        return nil unless @quiescent.call

        prompt = @current.poll(timeline, &notice)
        retire unless @current.equal?(Null) || @current.active?
        prompt
      end

      # One look at the timeline for the objective's turn: the standing Run's,
      # and the last words of every Run stopped since the last look. The Repl
      # takes it before a held line can run, since that line may be the stop.
      def settle_pin(timeline)
        @stopped.each { |run| run.last_look(timeline) }
        @stopped = []
        @current.settle_pin(timeline)
        self
      end

      # The active delegate: one objective, its own iteration budget, and the
      # marker read off the settled head. Kept apart from the switch because
      # "drive toward a goal" is a different responsibility from "which
      # delegate is current".
      class Run
        include TurnText

        attr_reader :goal

        def initialize(goal:, journal:, cap:, session:)
          @goal = goal
          @journal = journal
          @budget = Agent::Budget.new(max_iterations: cap)
          @iterations = 0
          @active = true
          @interrupted = false
          @pin = ObjectivePin.new(goal:, prompt:, session:, journal:)
        end

        def active? = @active

        def interrupt
          @interrupted = true
          self
        end

        # Only once this Run has actually driven: before that there is no
        # objective turn on the chain to find.
        def settle_pin(timeline)
          @pin.settle(timeline) if driven?
        end

        # Whatever retired this Run, the pin gets to report an objective it
        # never managed to protect. Only a Run that actually DROVE is owed one:
        # until then no objective turn was ever put on the chain, so there is
        # nothing to have failed to protect.
        def close
          @pin.close if driven?
        end

        # A stopped Run's pin, settled if its turn is on `timeline` and closed
        # either way.
        def last_look(timeline)
          settle_pin(timeline)
          close
        end

        # A stop reason retires the Run and yields its notice; otherwise it
        # drives one more turn.
        def poll(timeline)
          reason = stop_reason(timeline)
          return drive if reason.nil?

          @active = false
          close
          yield reason if block_given?
          nil
        end

        private

        # The three halts, in priority order. nil means "keep driving".
        def stop_reason(timeline)
          return "goal stopped: budget interrupt" if @interrupted
          return "goal reached: the agent signalled #{DONE}" if reached?(timeline)

          cap_reason
        end

        # Reused straight from {Agent::Budget}: checked before the iteration
        # runs, so `cap` is the number of turns driven. Its raise is the stop
        # notice, turned back into a reason string.
        def cap_reason
          @budget.check_iterations!(@iterations)
          nil
        rescue Agent::Budget::Exceeded => e
          "goal stopped: #{e.message}"
        end

        # Whether this Run has put anything on the chain yet. The done marker,
        # the pin's search and the pin's last words all turn on it, and all
        # three mean the same thing by it.
        def driven? = @iterations.positive?

        # Only a turn the driver itself drove can carry the marker (the first
        # poll has driven nothing yet), and only the settled assistant head
        # speaks it.
        def reached?(timeline)
          driven? && head_text(timeline).include?(DONE)
        end

        def head_text(timeline)
          head = timeline.head
          head && head.role == "assistant" ? text_of(head.content) : ""
        end

        def drive
          @iterations += 1
          @journal.record({ "type" => "goal_iteration", "goal" => @goal,
                            "iteration" => @iterations, "surface" => SURFACE })
          prompt
        end

        def prompt
          "Standing goal: #{@goal}\n\n" \
            "Continue working toward this goal. When it is fully achieved, reply with the " \
            "single token #{DONE} on its own line. Otherwise, take the next step."
        end
      end

      # Keeps ONE objective's turn out of compaction, and says so on the bench.
      # Its own object because "is the objective safe" is a different question
      # from "should we keep driving", and only this one touches the pin-set.
      #
      # The turn cannot be pinned when `/goal` runs: that command dispatches
      # lib-side with ZERO Timeline commits, so the head then names the PREVIOUS
      # topic's turn. The objective reaches the chain only when the Repl feeds
      # the Run's prompt back through `Agent#ask`, so this watches for it and
      # settles on a later poll.
      #
      # Quiet while the goal is active, deliberately: the re-prompt re-sends the
      # whole objective every iteration, so compaction eliding an older copy
      # costs nothing then. The pin earns its place AFTER `/goal off`, when the
      # re-sending stops and that turn is the objective's only carrier left.
      class ObjectivePin
        include TurnText

        def initialize(goal:, prompt:, session:, journal:)
          @goal = goal
          # Built ONCE, not per candidate per poll: the walk below runs on
          # every poll until it settles, and rebuilding this string inside the
          # predicate made that O(n) comparisons AND O(n) string builds.
          @prompt = prompt
          @session = session
          @journal = journal
          @settled = false
        end

        # Idempotent: the first call that finds the turn settles it for the
        # life of the Run.
        def settle(timeline)
          return if @settled

          turn = timeline.ancestors.find { |candidate| objective_turn?(candidate) }
          # Never speculative: {Session#record_pin} refuses a blank digest
          # loudly, and a torn ask leaves nothing to name. No turn means no
          # pin -- not a rescue, and not a guess.
          return if turn.nil?

          record_pin(turn.digest)
        end

        # Pinning nothing on a rewritten prompt is the safe direction, but it
        # must not also be a silent one: the Journal is the experiment record,
        # so an objective that went unprotected says so here. Settling on the
        # way out keeps it to ONE line -- a retiring poll and a following
        # `/goal off` both close the same pin.
        def close
          return if @settled

          @settled = true
          @journal.record({ "type" => "goal_pin_missed", "goal" => @goal, "surface" => SURFACE })
        end

        private

        def record_pin(digest)
          @session.record_pin(digest)
          @settled = true
          @journal.record({ "type" => "goal_pin", "goal" => @goal, "digest" => digest, "surface" => SURFACE })
        end

        # Identity by CONTENT, never by position -- the naive positional read
        # is exactly the one that names the wrong topic. Two properties carry
        # it: `ancestors` is HEAD-FIRST (root-first would find an older decoy,
        # a human turn typed with the verbatim re-prompt or the previous run of
        # this same objective), and the match is EQUALITY, not a substring (a
        # prompt some middleware rewrote pins NOTHING rather than pinning the
        # wrong turn).
        def objective_turn?(turn)
          turn.role == "user" && text_of(turn.content) == @prompt
        end
      end

      private

      def retire
        @current = Null
        @layer.disable
        self
      end
    end
  end
end
