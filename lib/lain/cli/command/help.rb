# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/help`: one rendered String -- the registered commands (one usage line
      # each) above the skill catalog -- returned to the Repl's boundary
      # renderer (commands return text, never print). Holds the LIVE registry
      # it is registered in, so a command a later card registers appears with
      # no edit here; the catalog is the SAME snapshot SkillDispatch dispatches
      # over (Wiring threads one load into both), so the listing and the
      # dispatch can never drift.
      class Help
        def initialize(registry:, catalog:)
          @registry = registry
          @catalog = catalog
          freeze
        end

        def name = "help"

        def usage = "/help -- list commands and skills"

        def call(_args, _env)
          ["commands:", *command_lines, "", "skills:", *skill_lines].join("\n")
        end

        private

        def command_lines = @registry.map { |command| "  #{command.usage}" }

        # An empty catalog renders honestly rather than as a bare header.
        def skill_lines
          return ["  (none)"] if @catalog.all.empty?

          @catalog.all.map { |skill| "  /#{skill.name} -- #{skill.description}" }
        end
      end
    end
  end
end
