# frozen_string_literal: true

module Lain
  module Frontend
    module Decorators
      # A call the judge approved, as one line the frontend stamps.
      class JudgeApproved
        # A model-written command can run to kilobytes; the line is a reminder, not a copy.
        WIDTH = 120
        UNSAFE = /[[:cntrl:]\p{Cf}]/

        def initialize(event) = @event = event

        def line_shaped? = true

        def stamped? = true

        # @param _theme [Frontend::Theme] unused; the line carries no styling
        # @return [String] `the judge approved tool(input)`
        def render(_theme) = "the judge approved #{@event.call.gsub(UNSAFE, " ").truncate(WIDTH)}"
      end
    end
  end
end
