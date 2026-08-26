# frozen_string_literal: true

module Lain
  module Frontend
    module Decorators
      # Presents a transport-level retry live, because a human watching a stalled
      # provider round trip otherwise watches a blank screen. {ToolOutput}'s
      # shape -- a dim attribution label followed by a styled detail. `:label`
      # and `:warning` are already-registered tokens: a retry is an operational
      # notice, not the harness's own error and not unstyled prose, so it earns
      # no token of its own.
      class ProviderRetry
        # Below this, a rounded value reads "0s" -- indistinguishable from no
        # wait at all, though a real backoff is happening.
        FLOOR_SECONDS = 0.01

        def initialize(event) = @event = event

        # Composed whole and rendered once, which is what lets the frontend
        # terminate it: four of these in a row must reach the screen as four
        # rows, not as one run-together string.
        def line_shaped? = true

        # @param theme [Frontend::Theme]
        # @return [String] one attributed line naming this attempt, whether it
        #   is backing off or exhausted, and what triggered it
        def render(theme)
          label = theme.paint(:label, "[retry]")
          "#{label} #{theme.paint(:warning, detail)}"
        end

        private

        def detail
          "attempt #{@event.attempt}#{outcome}#{status_detail}#{reason_detail}"
        end

        # `will_retry_in` is nil exactly when {Provider::*::RetryTap} has given
        # up (see `exhausted_block`), so its presence is the whole test.
        def outcome
          @event.will_retry_in ? ", retrying in #{formatted_backoff}" : ", giving up"
        end

        # The retry middleware hands back a raw Float second count (observed:
        # 0.14368744774438316), precision nobody reads at, and -- rarely, via a
        # misbehaving server's oversized Retry-After header parsed to
        # Float::INFINITY -- a non-finite one `Float#round` cannot take at all.
        # So: two places, with the decimal tail dropped for a whole-second
        # backoff so `2.0` does not masquerade as measured to the millisecond,
        # and for either edge an honest bound instead of a number this render
        # cannot stand behind.
        def formatted_backoff
          backoff = @event.will_retry_in
          return "a while" unless backoff.finite?
          return "under #{FLOOR_SECONDS}s" if backoff.positive? && backoff < FLOOR_SECONDS

          rounded = backoff.round(2)
          "#{rounded == rounded.to_i ? rounded.to_i.to_s : rounded.to_s}s"
        end

        def status_detail
          @event.status ? " (status #{@event.status})" : ""
        end

        def reason_detail
          @event.reason ? " -- #{@event.reason}" : ""
        end
      end
    end
  end
end
