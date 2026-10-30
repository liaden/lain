# frozen_string_literal: true

module Lain
  module Frontend
    module Decorators
      # Text a turn wrote beside its tool calls, painted as a response so it
      # reads the same as the reply that ends the run, markdown included.
      class AssistantText
        def initialize(event) = @event = event

        def line_shaped? = true

        def stamped? = false

        # @param theme [Frontend::Theme]
        # @return [String] the text under the response token, its markdown painted
        def render(theme) = segments.paint(theme)

        # @return [Array<Integer>] the rows {Wrap} must not break
        def verbatim_rows = Markdown.verbatim_rows(segments)

        private

        def segments = @segments ||= Markdown.segments(@event.text, prose: :response)
      end
    end
  end
end
