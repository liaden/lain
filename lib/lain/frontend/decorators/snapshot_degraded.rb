# frozen_string_literal: true

module Lain
  module Frontend
    module Decorators
      # Tells the human that a turn's shadow snapshot store failed, so the turn
      # was recorded as the write-set scope records one: what a shell changed in
      # it cannot be undone. Without this they would learn it only when an /undo
      # could not reach the change. {ProviderRetry}'s shape and tokens -- an
      # operational notice, not the harness's own error.
      class SnapshotDegraded
        def initialize(event) = @event = event

        def line_shaped? = true

        # @param theme [Frontend::Theme]
        # @return [String] one attributed line: what cannot be undone, and why
        def render(theme)
          "#{theme.paint(:label, "[snapshot]")} #{theme.paint(:warning, detail)}"
        end

        private

        def detail
          "this turn's shell changes can't be undone -- only files lain's own tools wrote were recorded " \
            "(#{@event.reason})"
        end
      end
    end
  end
end
