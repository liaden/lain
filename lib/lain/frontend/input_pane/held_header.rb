# frozen_string_literal: true

module Lain
  module Frontend
    class InputPane
      # A new header for the prompt the pane has drawn, held while the pane
      # cannot draw it -- a draft in the editor, a window that moved -- and
      # released on a later tick, the way {Geometry}'s latch holds a repaint.
      #
      # Held rather than dropped because the decline also covers the moment
      # between a prompt's draw and its read opening, when a read not yet open
      # reads as touched, and the chat says nothing more for as long as the
      # header stays true. Measured: a header sent just after a redraw and never
      # sent again stayed off the pane.
      class HeldHeader
        # Whether `frame` only changes the header under the prompt `drawn`
        # shows. A prompt drawn with no header has no rows to rewrite, so it
        # redraws instead.
        #
        # @param drawn [Hash] the prompt frame on the screen
        # @param frame [Hash] the prompt frame just received
        # @return [Boolean]
        def self.change?(drawn, frame)
          frame["kind"] != "countdown" && drawn["generation"] == frame["generation"] &&
            frame["header"] != drawn["header"] && !drawn["header"].to_s.empty?
        end

        def initialize = @frame = nil

        # @param frame [Hash] the prompt frame the pane declined to draw
        def hold(frame) = @frame = frame

        def drop = @frame = nil

        # @param drawn [Hash] the prompt frame on the screen
        # @return [Hash] the held frame, so a repaint draws the newest header
        def over(drawn) = @frame || drawn

        # @param ready [Boolean] whether the pane can draw a header now
        # @yieldparam frame [Hash] the held frame, once, after which nothing is held
        def release(ready:)
          return if @frame.nil? || !ready

          frame = @frame
          drop
          yield frame
        end
      end
    end
  end
end
