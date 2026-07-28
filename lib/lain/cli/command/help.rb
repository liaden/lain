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

        # T9: a {Lain::Renderable}, not a String -- the same words, with each
        # section HEADER naming a token so the listing beneath it reads as
        # content rather than as one flat colour.
        def call(_args, _env)
          section("commands:", command_lines).plain("\n\n") + section("skills:", skill_lines)
        end

        private

        # A header and its lines: the header names `:label`, every entry is the
        # renderable's own plain token, and the newlines belong to the entries
        # so no style ever wraps a line ending.
        def section(header, lines)
          lines.inject(Lain::Renderable.new.with(:label, header)) do |rendered, line|
            rendered.plain("\n#{line}")
          end
        end

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
