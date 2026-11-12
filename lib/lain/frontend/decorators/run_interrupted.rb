# frozen_string_literal: true

module Lain
  module Frontend
    module Decorators
      # An ask that ended without a reply. It prints nothing, because the error line already said why;
      # it exists so the terminal can ring for a failure the human was not there to see.
      class RunInterrupted
        def initialize(event) = @event = event

        # @return [String, nil] the failure, or nil for a stop the human made themselves
        def note = @event.human? ? nil : "ask failed: #{@event.reason}"

        def render(_theme) = nil

        def stamped? = false

        def line_shaped? = false
      end
    end
  end
end
