# frozen_string_literal: true

module Lain
  module Frontend
    # Render ergonomics for Channel {Lain::Telemetry}s: a decorator bundles color and
    # format WITH the event it presents, so {TTY#render} stays a plain dispatch
    # (event -> decorator -> bytes) instead of a growing pile of type-branched
    # private printers.
    #
    # Why a decorator and not a `Renderable` module included on {Lain::Telemetry}
    # itself: presentation knowledge (Pastel, colors) is exactly what output
    # discipline keeps OUT of `lib/` non-frontend code (see
    # spec/output_discipline_spec.rb). A `render` method on the value object would
    # move that knowledge into `lib/`, the output-discipline inverse. The event
    # stays a pure value; its presentation lives here, under frontend/, where
    # touching a terminal palette is legal.
    #
    # Two decorators now -- {Telemetry::ToolOutput} (a live tool's stdout/stderr)
    # and {Telemetry::ProviderRetry} (a provider round trip backing off or
    # giving up). ProviderRetry was originally deliberately unrendered here --
    # Journal material, not something the human needs painted mid-stream -- but
    # a human watching a stalled endpoint seeing only a blank screen is what a
    # QA finding named, and that is the evidence that reversed the decision.
    # {Telemetry::Dropped} still flows through channels and stays deliberately
    # unrendered: that half of the original call stands, because a drop count is
    # still Journal material with no live urgency. {.for} is the named seam -- when a THIRD event type earns
    # rendering, it gets its own decorator here and one more clause below, and
    # TTY does not change.
    module Decorators
      # Every decorator answers two messages: `render(theme)` for the bytes, and
      # `line_shaped?` for whether those bytes are a whole line the frontend may
      # terminate. The second is a message rather than a type check
      # upstream so that adding a decorator never means editing a list of
      # classes somewhere else.
      #
      # @param event [Object] a Channel event
      # @return [#render, #line_shaped?, nil] the decorator that presents `event`
      #   -- answering BOTH messages above, not just the first -- or nil if the
      #   frontend does not render this event type (it is silently skipped)
      def self.for(event)
        return ToolOutput.new(event) if event.is_a?(Telemetry::ToolOutput)
        return ProviderRetry.new(event) if event.is_a?(Telemetry::ProviderRetry)

        nil
      end

      # Presents a live tool-output chunk: a dim attribution label
      # (`[tool_use_id stream]`) followed by the bytes, with stderr in red so a
      # failing command reads at a glance.
      class ToolOutput
        # Which stream a chunk came from is THIS class's knowledge -- it is the
        # only object here that knows {Telemetry::ToolOutput} has streams at all.
        # The theme's vocabulary stays named for intent, so a new stream breaks
        # this map (loudly, via fetch) rather than silently missing a token.
        STREAM_TOKENS = { stdout: :tool_output, stderr: :tool_error }.freeze

        def initialize(event) = @event = event

        # A chunk is whatever the tool had written when the reader last woke:
        # {Sink::IOAdapter#write} passes those bytes through untouched, precisely
        # so a progress bar redrawing itself on one row still redraws on one row.
        # So this decorator's output is a fragment, and a frontend that
        # terminated it would break rows the command never broke.
        def line_shaped? = false

        # @param theme [Frontend::Theme] resolves the tokens named below; the
        #   decorator names intent, never a colour
        # @return [String] the attribution label followed by the chunk's styled
        #   bytes -- one whole line only when the chunk itself was one
        def render(theme)
          label = theme.paint(:label, "[#{@event.tool_use_id} #{@event.stream}]")
          "#{label} #{styled_stream(theme)}"
        end

        private

        # Both streams go through a token rather than one branch naming red and
        # the other naming nothing.
        def styled_stream(theme)
          theme.paint(STREAM_TOKENS.fetch(@event.stream), @event.bytes)
        end
      end
    end
  end
end

require_relative "decorators/provider_retry"
