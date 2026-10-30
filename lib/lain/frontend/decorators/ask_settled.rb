# frozen_string_literal: true

module Lain
  module Frontend
    module Decorators
      # An ask that ran to its reply, as one dim line the frontend stamps.
      class AskSettled
        def initialize(event) = @event = event

        def line_shaped? = true

        def stamped? = true

        # @return [String] the line unpainted and unstamped, for a notification
        def note
          turns = "#{@event.turns} #{"turn".pluralize(@event.turns)}"
          "ask settled: #{@event.stop_reason} after #{turns} in #{format("%.1f", @event.seconds)}s"
        end

        # @param theme [Frontend::Theme]
        # @return [String] {#note} in the dim label token
        def render(theme) = theme.paint(:label, note)
      end
    end
  end
end
