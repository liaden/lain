# frozen_string_literal: true

module Lain
  module Frontend
    module Decorators
      # Presents a transport-level retry live (F15): a human watching a stalled
      # provider round trip used to watch a blank screen while every
      # {Telemetry::ProviderRetry} landed only in the Journal. Same shape as
      # {ToolOutput} -- a dim attribution label followed by a styled detail --
      # so repeated waiting stays legible without inventing a second render
      # pattern. `:label` and `:warning` are both already-registered tokens
      # (see {Theme::DEFAULT_TOKENS}): a retry is an operational notice, not
      # the harness's own error and not unstyled prose, so it earns no new
      # token of its own.
      class ProviderRetry
        def initialize(event) = @event = event

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
          @event.will_retry_in ? ", retrying in #{@event.will_retry_in}s" : ", giving up"
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
