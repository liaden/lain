# frozen_string_literal: true

module Lain
  module Frontend
    # Render ergonomics for Channel {Lain::Telemetry}s: a decorator bundles color
    # and format WITH the event it presents, so {TTY#render} stays a plain
    # dispatch (event -> decorator -> bytes) instead of a growing pile of
    # type-branched private printers.
    #
    # A decorator and not a `Renderable` module on {Lain::Telemetry} itself,
    # because presentation knowledge (Pastel, colors) is exactly what output
    # discipline keeps OUT of `lib/` non-frontend code. The event stays a pure
    # value; its presentation lives here, under frontend/, where touching a
    # terminal palette is legal.
    #
    # {Telemetry::Dropped} flows through channels and stays deliberately
    # unrendered -- a drop count is Journal material with no live urgency.
    # {.for} is the named seam: a third event type that earns rendering gets its
    # own decorator here and one more clause below, and TTY does not change.
    module Decorators
      # Every decorator answers two messages: `render(theme)` for the bytes, and
      # `line_shaped?` for whether those bytes are a whole line the frontend may
      # terminate. The second is a MESSAGE rather than a type check upstream, so
      # adding a decorator never means editing a list of classes elsewhere.
      #
      # @param event [Object] a Channel event
      # @return [#render, #line_shaped?, nil] the decorator that presents `event`
      #   -- answering BOTH messages above, not just the first -- or nil if the
      #   frontend does not render this event type (it is silently skipped)
      def self.for(event)
        return ToolOutput.new(event) if event.is_a?(Telemetry::ToolOutput)
        return ProviderRetry.new(event) if event.is_a?(Telemetry::ProviderRetry)
        return SnapshotDegraded.new(event) if event.is_a?(::Lain::Agent::SnapshotSlot::SnapshotDegraded)

        nil
      end

      # A dim attribution label (`[tool_use_id stream]`) followed by the bytes,
      # with stderr in red so a failing command reads at a glance.
      class ToolOutput
        # Which stream a chunk came from is THIS class's knowledge -- the theme's
        # vocabulary stays named for intent, so a new stream breaks this map
        # loudly, via fetch, rather than silently missing a token.
        STREAM_TOKENS = { stdout: :tool_output, stderr: :tool_error }.freeze

        def initialize(event) = @event = event

        # A chunk is whatever the tool had written when the reader last woke, and
        # {Sink::IOAdapter#write} passes those bytes through untouched precisely
        # so a progress bar redrawing itself on one row still does. The output
        # is a FRAGMENT; a frontend that terminated it would break rows the
        # command never broke.
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

        # Both streams go through a token, rather than one branch naming red and
        # the other naming nothing.
        def styled_stream(theme)
          theme.paint(STREAM_TOKENS.fetch(@event.stream), @event.bytes)
        end
      end
    end
  end
end
