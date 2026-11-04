# frozen_string_literal: true

module Lain
  module Frontend
    module Decorators
      # One line per edge of a tool call: the name and summary when it starts,
      # the same with the outcome and the time when it ends.
      class ToolCalled
        def initialize(event) = @event = event

        def line_shaped? = true

        def stamped? = true

        # @param theme [Frontend::Theme]
        # @return [String] `▸ [call tag] tool summary`, plus `  outcome 400ms` once the call ended
        def render(theme) = theme.paint(:tool_header, [head, tail].compact.join("  "))

        private

        def head = ["▸", "[#{@event.tool_use_id.to_s.chars.last(4).join}]", @event.tool, summary].compact.join(" ")

        def summary = (@event.summary unless @event.summary.empty?)

        def tail
          return unless @event.phase == "end"

          "#{@event.outcome} #{elapsed}"
        end

        def elapsed
          millis = (@event.seconds * 1000).round
          millis < 1000 ? "#{millis}ms" : format("%<seconds>.1fs", seconds: @event.seconds)
        end
      end
    end
  end
end
