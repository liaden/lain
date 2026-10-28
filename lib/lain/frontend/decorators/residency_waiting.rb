# frozen_string_literal: true

module Lain
  module Frontend
    module Decorators
      # Tells the human that a local request is waiting for another model to
      # finish on the same endpoint, so a quiet turn reads as queued rather than
      # hung. {SnapshotDegraded}'s shape and tokens: an operational notice.
      class ResidencyWaiting
        def initialize(event) = @event = event

        def line_shaped? = true

        def stamped? = false

        # @param theme [Frontend::Theme]
        # @return [String] one attributed line: which model holds the endpoint, and which one waits
        def render(theme)
          "#{theme.paint(:label, "[residency]")} #{theme.paint(:warning, detail)}"
        end

        private

        def detail
          "waiting for #{@event.resident} to finish on #{@event.endpoint} before loading #{@event.model}"
        end
      end
    end
  end
end
