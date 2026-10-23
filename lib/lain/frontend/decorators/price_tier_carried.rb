# frozen_string_literal: true

require "active_support/number_helper"

module Lain
  module Frontend
    module Decorators
      # Tells the human that a request crossing its model's price tier went out
      # unasked, because they approved that model's tier earlier in the chat.
      # Without it the approval's reach would show only in the journal.
      # {SnapshotDegraded}'s shape and tokens.
      class PriceTierCarried
        def initialize(event) = @event = event

        def line_shaped? = true

        def stamped? = false

        # @param theme [Frontend::Theme]
        # @return [String] one attributed line: the model, its tokens, and the rate they were sent at
        def render(theme)
          "#{theme.paint(:label, "[price tier]")} #{theme.paint(:warning, detail)}"
        end

        private

        def detail
          "#{@event.model}: #{ActiveSupport::NumberHelper.number_to_delimited(@event.prompt_tokens)} prompt " \
            "tokens sent, $#{@event.tier_cost} at the tier rate, under your earlier approval"
        end
      end
    end
  end
end
