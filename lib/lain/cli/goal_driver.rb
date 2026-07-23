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
        # (the command reads `active?` back before it confirms).
        def self.start(_goal) = self

        def self.stop = self

        def self.goal = nil
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
      def start(goal)
        @current = Run.new(goal:, journal: @journal, cap: @cap)
        self
      end

      # `/goal off`: retire to idle. The delegate becomes the Null, so the next
      # poll drives nothing; the command renders the confirmation.
      def stop
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
      def poll(timeline, &notice)
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
        attr_reader :goal

        def initialize(goal:, journal:, cap:)
          @goal = goal
          @journal = journal
          @budget = Agent::Budget.new(max_iterations: cap)
          @iterations = 0
          @active = true
          @interrupted = false
        end

        def active? = @active

        def interrupt
          @interrupted = true
          self
        end

        # A stop reason retires the Run and yields its notice; otherwise it
        # drives one more turn. `return` guards (not next/break) read as the
        # cascade they are.
        def poll(timeline)
          reason = stop_reason(timeline)
          return drive if reason.nil?

          @active = false
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

        # Only a turn the driver itself drove can carry the marker (the first
        # poll has driven nothing yet), and only the settled assistant head
        # speaks it.
        def reached?(timeline)
          @iterations.positive? && head_text(timeline).include?(DONE)
        end

        def head_text(timeline)
          head = timeline.head
          head && head.role == "assistant" ? text_of(head.content) : ""
        end

        def text_of(content)
          content.select { |block| block.is_a?(Hash) && block["type"] == "text" }
                 .map { |block| block["text"] }.join
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
    end
  end
end
