# frozen_string_literal: true

module Lain
  module Frontend
    module Decorators
      # A call the judge approved or denied, or the human's earlier yes let run, as one line the frontend stamps.
      class JudgeRuled
        # A model-written command can run to kilobytes; the line is a reminder, not a copy.
        WIDTH = 120
        UNSAFE = /[[:cntrl:]\p{Cf}]/
        SAID = { "approved" => "the judge approved", "denied" => "the judge denied",
                 "remembered" => "the judge approved this earlier:",
                 "human_remembered" => "you approved this earlier:" }.freeze
        REMINDERS = %w[remembered human_remembered].freeze

        def initialize(event) = @event = event

        def line_shaped? = true

        def stamped? = true

        # @param theme [Frontend::Theme] dims a remembered approval, which is a reminder rather than news
        # @return [String] `the judge approved tool(input)`, `the judge denied tool(input)`, or the dim
        #   `the judge approved this earlier: tool(input)` or `you approved this earlier: tool(input)`
        def render(theme)
          line = "#{SAID.fetch(@event.verdict)} #{@event.call.gsub(UNSAFE, " ").truncate(WIDTH)}"
          REMINDERS.include?(@event.verdict) ? theme.paint(:label, line) : line
        end
      end
    end
  end
end
