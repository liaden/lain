# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/goal <objective>` sets a standing goal the Repl drives the agent
      # toward after each settled turn (T21); `/goal off` clears it; bare
      # `/goal` reports what is in force. The driving, the done marker, the
      # iteration cap and the journaling all live in {GoalDriver} -- this command
      # is only the write surface over it, injected the SAME way {Help} takes its
      # registry and {Approve} its prompt (no {Env} reader: the Repl and this
      # command share the one driver Wiring built).
      #
      # No LLM judge decides termination in this version -- the driver stops on
      # the agent's explicit marker, the cap, or `/goal off`.
      class Goal
        def initialize(driver:)
          @driver = driver
          freeze
        end

        def name = "goal"

        def usage = "/goal <objective> | off -- drive the agent toward a standing goal until it signals done"

        def call(args, _env)
          objective = args.strip
          return report if objective.empty?
          return turn_off if objective.casecmp?("off")

          @driver.start(objective)
          confirm(objective)
        end

        private

        # Reads the driver's state back before confirming, so a session with no
        # live driver (the Null) reports the truth instead of claiming a goal it
        # cannot drive.
        def confirm(objective)
          return "goal driving is unavailable in this session" unless @driver.active?

          "goal set: #{objective} -- driving after each turn until #{GoalDriver::DONE}, the cap, or /goal off"
        end

        def turn_off
          @driver.stop
          "goal off -- the driver stops re-prompting; type your next line at you>"
        end

        # Bare `/goal`: name the objective in force, or say there is none.
        def report
          @driver.active? ? "goal: #{@driver.goal}" : "no standing goal -- /goal <objective> to set one"
        end
      end
    end
  end
end
