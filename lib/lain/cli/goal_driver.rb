# frozen_string_literal: true

module Lain
  module CLI
    # The standing-goal driver (T21): a live, mutable seam the Repl polls
    # between asks and `/goal` writes. It re-prompts the agent toward one
    # objective after each settled turn -- goal plus a continue/done
    # instruction -- and halts on the agent's own done marker, an iteration
    # cap, a `/goal off`, or a budget interrupt. No LLM judge decides
    # termination in this version; the marker is a literal token match.
    #
    # Same delegating-slot shape as {Approval::PolicySwitch} and
    # {Context::ModelSwitch}: the Repl holds this ONE object for the session and
    # polls it every loop, `/goal` swaps the delegate INSIDE it (a real {Run}
    # while driving, {Null} when idle), and each iteration lands in the Journal
    # attributed to the `goal` surface -- "which turns the driver drove, toward
    # what" is evidence on a study bench. Deliberately MUTABLE coordination
    # state, unlike the frozen value objects: it exists to be switched.
    #
    # `quiescent:` is the sequencing guard: the driver drives NOTHING while the
    # fleet is unquiet (a parked approval, a pending human question), so a driven
    # turn never races a decision the human still owes. Only the observable half
    # is wired today -- see the handback: parked approvals are readable from the
    # Repl, but the human-question inbox has no public predicate, so that half is
    # escalated rather than reached for through internals. The default is
    # always-quiescent, so an unwired driver drives freely.
    class GoalDriver
      DEFAULT_CAP = 5

      # The literal token the agent replies with to signal the goal is met. A
      # marker, not a judge: v1 termination is explicit by design.
      DONE = "GOAL_COMPLETE"

      SURFACE = "goal"

      # The text a turn's content spells. Shared because the done-marker read
      # and the objective match are the same question asked of different turns,
      # and the two must not drift on what "the text of a turn" means.
      module TurnText
        private

        def text_of(content)
          content.select { |block| block.is_a?(Hash) && block["type"] == "text" }
                 .map { |block| block["text"] }.join
        end
      end

      # A genuine Null Object -- the exemplar, not a fail-loud placeholder: the
      # idle delegate the Repl polls when no goal is set answers "nothing to
      # drive" cheaply and silently, with no journal write and no notice. It
      # satisfies the same duck a {Run} does, so the poll site never guards on a
      # goal being present.
      module Null
        def self.active? = false

        def self.poll(_timeline) = nil

        def self.interrupt = self

        # The write duck too, so the command surface degrades cleanly where no
        # live driver is wired (a headless assembly): starting a goal is a
        # no-op that honestly stays idle, never a NoMethodError and never a lie
        # (the command reads `active?` back before it confirms). The `session:`
        # a live driver would auto-pin the objective on (B3) is accepted and
        # dropped -- an idle driver drives nothing, so it has nothing to pin.
        def self.start(_goal, **) = self

        def self.stop = self

        def self.goal = nil

        # The B3 pin duck: an idle delegate has driven nothing, so it has no
        # objective to protect and nothing to report about failing to.
        def self.settle_pin(_timeline) = self

        def self.close = self
      end

      # @param journal [#record] where each driven iteration lands as evidence
      # @param cap [Integer] the iteration ceiling, reused through {Agent::Budget}
      # @param quiescent [#call] answers whether the fleet is quiet enough to drive
      def initialize(journal:, cap: DEFAULT_CAP, quiescent: -> { true })
        @journal = journal
        @cap = cap
        @quiescent = quiescent
        @current = Null
      end

      def active? = @current.active?

      # Begin driving toward `goal`, replacing whatever the delegate was (a
      # fresh objective resets the iteration count). Answers self so the command
      # can chain a confirmation read.
      #
      # `session:` is the run's pin-set, threaded in by the WRITER rather than
      # held for the driver's life: {Wiring} memoizes one driver before it can
      # name a session, and `/goal` is the only caller that has both. It
      # defaults to {Session::Null}, so a driver started without one drives
      # exactly as before and pins nowhere.
      def start(goal, session: Session::Null.instance)
        @current = Run.new(goal:, journal: @journal, cap: @cap, session:)
        self
      end

      # `/goal off`: retire to idle. The delegate becomes the Null, so the next
      # poll drives nothing; the command renders the confirmation. `close` first
      # -- this is the LAST moment the retiring Run can say whether its
      # objective ever got protected, and after the swap there is no one to ask.
      def stop
        @current.close
        @current = Null
        self
      end

      def goal = @current.goal

      # A harness halt, the {Agent::Budget#interrupt} vocabulary: a Ctrl-C or a
      # supervising timeout stops the driving from outside. The delegate records
      # it and reports it on the next poll.
      def interrupt
        @current.interrupt
        self
      end

      # Polled by the Repl between asks. Yields an inline stop NOTICE (for the
      # Repl to render) when a driven goal ends, and returns the next goal-prompt
      # to feed the agent -- or nil when there is nothing to drive (idle, just
      # stopped, or deferring while the fleet is unquiet). A finished Run retires
      # to Null so the next idle poll stays cheap.
      #
      # The B3 pin settles FIRST, ahead of both the quiescence gate and the
      # delegate's own poll, and that placement is load-bearing twice over. A
      # DEFERRED poll is exactly when the Repl hands the human back `you>`
      # (repl.rb:106), so `/goal off` can land on one -- gate the pin and an
      # unquiet fleet strands the objective unprotected forever. And a poll that
      # RETIRES the Run swaps the delegate for the Null below, so a pin after it
      # would find nobody left to pin. Idempotent, so calling it every poll is free.
      def poll(timeline, &notice)
        @current.settle_pin(timeline)
        return nil unless @quiescent.call

        prompt = @current.poll(timeline, &notice)
        @current = Null unless @current.active?
        prompt
      end

      # The active delegate: one objective, its own iteration budget, and the
      # marker read off the settled head. Kept apart from the switch because
      # "drive toward a goal" is a different responsibility from "which delegate
      # is current" -- the switch swaps it, the Run decides.
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

        # Offer the chain to the pin, but only once this Run has actually
        # driven: before that there is no objective turn on it to find.
        def settle_pin(timeline)
          @pin.settle(timeline) if driven?
        end

        # Last words: whatever retired this Run -- a stop reason here, or a
        # `/goal off` swapping the delegate out -- the pin gets to report an
        # objective it never managed to protect. Only a Run that actually DROVE
        # is owed one: until then no objective turn was ever put on the chain,
        # so there is nothing to have failed to protect.
        def close
          @pin.close if driven?
        end

        # A stop reason retires the Run and yields its notice; otherwise it
        # drives one more turn. `return` guards (not next/break) read as the
        # cascade they are.
        def poll(timeline)
          reason = stop_reason(timeline)
          return drive if reason.nil?

          @active = false
          close
          yield reason if block_given?
          nil
        end

        private

        # The three halts the driver decides, in priority order: a harness
        # interrupt, the agent's own done marker, then the iteration ceiling.
        # nil means "keep driving".
        def stop_reason(timeline)
          return "goal stopped: budget interrupt" if @interrupted
          return "goal reached: the agent signalled #{DONE}" if reached?(timeline)

          cap_reason
        end

        # The ceiling is reused straight from {Agent::Budget}: check before the
        # iteration runs, so `cap` is the number of turns driven. Its raise is
        # the stop notice, turned back into a reason string.
        def cap_reason
          @budget.check_iterations!(@iterations)
          nil
        rescue Agent::Budget::Exceeded => e
          "goal stopped: #{e.message}"
        end

        # Whether this Run has put anything on the chain yet. Three questions
        # turn on it -- the done marker, the pin's search, and the pin's last
        # words -- and all three mean the same thing by it.
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

        # One driven iteration: count it, journal it attributed to the goal
        # surface, and hand back the re-prompt.
        def drive
          @iterations += 1
          @journal.record({ "type" => "goal_iteration", "goal" => @goal,
                            "iteration" => @iterations, "surface" => SURFACE })
          prompt
        end

        # The goal plus a continue/done instruction -- one message the agent
        # reads each settled turn, telling it how to signal completion.
        def prompt
          "Standing goal: #{@goal}\n\n" \
            "Continue working toward this goal. When it is fully achieved, reply with the " \
            "single token #{DONE} on its own line. Otherwise, take the next step."
        end
      end

      # B3: keeps ONE objective's turn out of compaction, and says so on the
      # bench. Its own object because "is the objective safe" is a different
      # question from "should we keep driving" -- the {Run} decides the second,
      # this decides the first, and only this one touches the pin-set.
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
          # Built ONCE, not per candidate per poll: the walk below runs on every
          # poll until it settles, and rebuilding this string inside the
          # predicate made that O(n) comparisons AND O(n) string builds.
          @prompt = prompt
          @session = session
          @journal = journal
          @settled = false
        end

        # Idempotent, and safe on a poll that drives nothing: the first call
        # that finds the turn settles it for the life of the Run.
        def settle(timeline)
          return if @settled

          turn = timeline.ancestors.find { |candidate| objective_turn?(candidate) }
          # Never speculative: {Session#record_pin} refuses a blank digest
          # loudly, and a torn ask leaves nothing to name. No turn means no pin
          # -- not a rescue, and not a guess.
          return if turn.nil?

          record_pin(turn.digest)
        end

        # The Run is over. Pinning nothing on a rewritten prompt is the safe
        # direction, but it must not also be a silent one: the Journal is the
        # experiment record, so an objective that went unprotected says so here.
        # Settling on the way out is what keeps it to ONE line -- a retiring
        # poll and a following `/goal off` both close the same pin.
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

        # Identity by CONTENT, never by position -- the naive positional read is
        # exactly the one that names the wrong topic, so a second positional
        # assumption gets the same suspicion. Two properties carry it, and
        # neither is incidental:
        #
        # `ancestors` is HEAD-FIRST (root-first would find an older decoy: a
        # human turn typed with the verbatim re-prompt, or the previous run of
        # this same objective after a `/goal off`), and the match is EQUALITY,
        # not a substring (a tool_result turn spells no text and so cannot
        # collide, and a prompt some middleware rewrote pins NOTHING rather than
        # pinning the wrong turn).
        def objective_turn?(turn)
          turn.role == "user" && text_of(turn.content) == @prompt
        end
      end
    end
  end
end
