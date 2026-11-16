# frozen_string_literal: true

module Lain
  module Frontend
    class Intake
      # A queued review put to the human as a `:human` prompt. The line is
      # rebuilt once, here, so the line shown is the line that runs: a dirty
      # tree's request takes a new snapshot on every rebuild.
      class Offer
        OPEN = ""
        DROP = "x"

        # @param line [String] the `/review` line, already rebuilt from a checked request
        def initialize(line)
          @line = String.new(line).freeze
          @stamped = "lain queue: #{@line}  (Enter opens, #{DROP} drops)".freeze
          @withheld = []
        end

        # @return [String] the prompt's words
        attr_reader :stamped

        alias to_s stamped

        # Only these answer it, so a stray line never opens or drops a review.
        def takes?(text) = [OPEN, DROP].include?(text.strip)

        # @yieldparam note [String] what does answer the offer
        def refused = yield("lain queue: Enter opens #{@line}, #{DROP} drops it; what you typed waits at you>")

        # @yieldparam note [String] the line saying this offer waits its turn
        def queued = yield("lain queue: a review offer waits behind the prompt in front of you")

        # Text typed at the offer goes back to `you>` unsent, since the human
        # typed it at a question and never asked for it to reach the model.
        #
        # @param text [String]
        def withhold(text) = @withheld << text

        # @return [String] what was typed at the offer, as 1 draft
        def draft = @withheld.join(" ")

        # @param answer [String, nil] what the prompt took; nil when the stream ended
        # @yieldparam line [String] the line to send on as if typed, given only on Enter
        # @return [String, nil] that line, or nil when the offer was dropped
        def opened(answer)
          return nil unless answer&.strip == OPEN

          yield @line
          @line
        end
      end
    end
  end
end
