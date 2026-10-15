# frozen_string_literal: true

module Lain
  module Frontend
    module Decorators
      # The files one tool round wrote, as a single line the frontend stamps:
      # the first few paths by name, the rest counted. A child's line starts
      # with its role so the human sees whose write it was.
      class FilesWritten
        NAMED = 3

        def initialize(event) = @event = event

        def line_shaped? = true

        # The time belongs to the frontend's clock, so the line leaves it to
        # {TTY#render}.
        def stamped? = true

        # @param _theme [Frontend::Theme] unused; the line carries no styling
        # @return [String] `[role ]wrote path`, or `[role ]wrote N files: a, b, c (+M more)`
        def render(_theme) = [*role, "wrote", detail].join(" ")

        private

        def role = (@event.role unless @event.role == "lain")

        def detail
          paths = @event.paths
          return paths.first if paths.one?

          "#{paths.size} files: #{paths.first(NAMED).join(", ")}#{remainder(paths.size)}"
        end

        def remainder(count) = (" (+#{count - NAMED} more)" if count > NAMED)
      end
    end
  end
end
