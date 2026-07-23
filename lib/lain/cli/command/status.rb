# frozen_string_literal: true

require "time"

module Lain
  module CLI
    module Command
      # `/status` (T13): the live {Lain::StatusFeed}'s own derivation
      # (`#state`), rendered inline -- never `.lain/state.json`. Command::Env's
      # `status` reader IS the one StatusFeed instance {ChatLaunch} threads
      # through both the tee (when one exists) and {Wiring}, so this renders
      # truthfully under --no-journal too: no tee ever fed it an event, so
      # `#state` answers its honest zero/empty struct rather than erroring on
      # a file that was never written.
      #
      # Presentation only -- the warm/cold glyph decision mirrors
      # {Frontend::TTY::Warmth}'s (same glyphs, same "deadline > now" rule),
      # duplicated rather than shared because that class reads the PUBLISHED
      # FILE by design (a separate process may render it) while this reads
      # the in-process instance directly; the two are different collaborators
      # answering the same question from different data, not one reused.
      class Status
        WARM = "●" # filled circle -- cache_deadline is still ahead of the clock
        COLD = "○" # hollow circle -- past deadline, or no cache activity observed yet

        # @param clock [#call] wall-clock source for the warm/cold comparison,
        #   injectable so a spec never races a real deadline (matches Warmth's
        #   own seam)
        def initialize(clock: -> { Time.now })
          @clock = clock
          freeze
        end

        def name = "status"

        def usage = "/status -- cache warmth, fleet size, inbox count"

        def call(_args, env)
          state = env.status.state
          ["status:", "  cache #{warmth(state["cache_deadline"])}",
           "  fleet #{state["fleet"].size}", "  inbox #{state["inbox_count"]}"].join("\n")
        end

        private

        def warmth(deadline)
          return "#{COLD} cold (no cache activity yet)" if deadline.nil?

          Time.iso8601(deadline) > @clock.call ? "#{WARM} warm" : "#{COLD} cold"
        end
      end
    end
  end
end
