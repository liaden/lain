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

        # T9: a {Lain::Renderable}, not a String -- the same words, with the
        # cache marker naming its own token so the theme can show warmth
        # without the whole listing taking that colour. Only the three keys
        # named here are read, so a {StatusFeed} that publishes MORE renders
        # exactly as it does today.
        def call(_args, env)
          state = env.status.state
          counts(state).inject(cache_line(state)) { |rendered, (name, value)| metric(rendered, name, value) }
        end

        private

        # The rows that are only a name and a number. The cache row is NOT one
        # of them -- its value names a warm/cold token rather than counting
        # something -- so it is built on its own and these follow it.
        def counts(state) = { "fleet" => state["fleet"].size, "inbox" => state["inbox_count"] }

        def cache_line(state)
          Lain::Renderable.new.with(:label, "status:").plain("\n")
                          .with(:label, "  cache ").with(*warmth(state["cache_deadline"]))
        end

        def metric(rendered, name, value)
          rendered.plain("\n").with(:label, "  #{name} ").plain(value.to_s)
        end

        # `[token, words]` -- exactly the pair {Renderable#with} takes, so the
        # warm/cold DECISION and the token that shows it are made in one place
        # rather than derived twice.
        def warmth(deadline)
          return [:cold, "#{COLD} cold (no cache activity yet)"] if deadline.nil?

          Time.iso8601(deadline) > @clock.call ? [:warm, "#{WARM} warm"] : [:cold, "#{COLD} cold"]
        end
      end
    end
  end
end
