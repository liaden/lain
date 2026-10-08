# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/help`. Holds the LIVE registry it is registered in, so a later
      # command appears with no edit here; the catalog is the same snapshot
      # SkillDispatch dispatches over, so listing and dispatch cannot drift.
      class Help
        SEPARATOR = " -- "
        INDENT = 2
        GUTTER = 2
        FALLBACK_WIDTH = 80

        # @param registry [#map] the live command registry
        # @param catalog [#all] the skill catalog
        # @param width [#call] the terminal width in columns; read at render
        #   time so a resized terminal is honoured
        def initialize(registry:, catalog:, width: method(:terminal_width))
          @registry = registry
          @catalog = catalog
          @width = width
          freeze
        end

        def name = "help"

        def usage = "/help -- list commands and skills"

        def call(_args, _env)
          columns = @width.call
          section("commands:", command_entries, columns).plain("\n\n") + section("skills:", skill_entries, columns)
        end

        private

        # No tty (a pipe, a captured stdout) cannot answer an ioctl, and /help
        # must still render there.
        def terminal_width
          ::TTY::Screen.width
        rescue StandardError
          FALLBACK_WIDTH
        end

        def section(header, entries, columns)
          start = Lain::Renderable.new.with(:heading, header)
          return start.plain("\n#{" " * INDENT}(none)") if entries.empty?

          name_width = [entries.map { |name, _| name.length }.max, columns / 3].min
          entries.inject(start) { |rendered, (name, text)| row(rendered, name, text, name_width, columns) }
        end

        def row(rendered, name, text, name_width, columns)
          lead = INDENT + name_width + GUTTER
          lines = wrap(text, [columns - lead, 1].max)
          named = rendered.plain("\n#{" " * INDENT}").with(:command_name, name)
          return named + continuation(lines, lead) if name.length > name_width

          padding = " " * (name_width - name.length + GUTTER)
          named.plain("#{padding}#{lines.first}") + continuation(lines.drop(1), lead)
        end

        def continuation(lines, lead)
          lines.inject(Lain::Renderable.new) { |rendered, line| rendered.plain("\n#{" " * lead}#{line}") }
        end

        def wrap(text, limit)
          text.scan(/\S.{0,#{limit - 1}}(?=\s|\z)|\S+/).presence || [""]
        end

        def command_entries = @registry.map { |command| command.usage.split(SEPARATOR, 2).then { |n, d| [n, d.to_s] } }

        def skill_entries
          @catalog.all.map { |skill| ["/#{skill.name}", skill.description] }
        end
      end
    end
  end
end
