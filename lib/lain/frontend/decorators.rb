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
    # One decorator today -- {Telemetry::ToolOutput} is the only event the frontend
    # Channel actually renders (a live tool's stdout/stderr). Other events do
    # flow through channels ({Telemetry::ProviderRetry}, {Telemetry::Dropped}) and are
    # deliberately unrendered here -- a decision, not a gap: they are Journal
    # material, not something the human needs painted mid-stream. So this is
    # deliberately NOT a decorator-per-type registry yet: a one-member family
    # earns no lookup table. {.for} is the named seam -- when a second event type
    # earns rendering, it gets its own decorator here and one more clause below,
    # and TTY does not change.
    module Decorators
      # @param event [Object] a Channel event
      # @return [#render, nil] the decorator that presents `event`, or nil if the
      #   frontend does not render this event type (it is silently skipped)
      def self.for(event)
        ToolOutput.new(event) if event.is_a?(Telemetry::ToolOutput)
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

        # @param theme [Frontend::Theme] resolves the tokens named below; the
        #   decorator names intent, never a colour
        # @return [String] one attributed, styled line ready for the terminal
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
