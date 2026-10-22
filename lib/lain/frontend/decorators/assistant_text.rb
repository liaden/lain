# frozen_string_literal: true

module Lain
  module Frontend
    module Decorators
      # Text a turn wrote beside its tool calls, painted as a response so it
      # reads the same as the reply that ends the run.
      class AssistantText
        def initialize(event) = @event = event

        def line_shaped? = true

        def stamped? = false

        # @param theme [Frontend::Theme]
        # @return [String] the text under the response token
        def render(theme) = theme.paint(:response, @event.text)
      end
    end
  end
end
