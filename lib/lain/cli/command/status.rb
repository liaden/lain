# frozen_string_literal: true

require "time"

module Lain
  module CLI
    module Command
      # `/status`: the live {Lain::StatusFeed}'s own derivation
      # (`#state`), rendered inline -- never the published file. Command::Env's
      # `status` reader IS the one StatusFeed instance {ChatLaunch} threads
      # through both the tee (when one exists) and {Wiring}, so this renders
      # truthfully under --no-journal too: no tee ever fed it an event, so
      # `#state` answers its honest zero/empty struct rather than erroring on
      # a file that was never written.
      #
      # Presentation only. The warm/cold DECISION and the two glyphs belong to
      # {Lain::StatusFeed::Reading}, which reads a published file for
      # {Frontend::TTY::Warmth} and the live struct here -- one object over
      # either source, so the two surfaces cannot come to disagree about a
      # deadline. What is left here is which of the three answers gets which
      # words, and that is genuinely this command's own.
      class Status
        # @param clock [#call] wall-clock source for the warm/cold comparison,
        #   injectable so a spec never races a real deadline (matches Warmth's
        #   own seam)
        def initialize(clock: -> { Time.now })
          @clock = clock
          freeze
        end

        def name = "status"

        def usage = "/status -- cache warmth, fleet size, inbox count"

        # A {Lain::Renderable}, not a String -- the same words, with the
        # cache marker naming its own token so the theme can show warmth
        # without the whole listing taking that colour. Only the three keys
        # named here are read, so a {StatusFeed} that publishes MORE renders
        # exactly as it does today.
        def call(_args, env)
          reading = Lain::StatusFeed::Reading.new(env.status.state)
          counts(reading).inject(cache_line(reading)) { |rendered, (name, value)| metric(rendered, name, value) }
        end

        private

        # The rows that are only a name and a number. The cache row is NOT one
        # of them -- its value names a warm/cold token rather than counting
        # something -- so it is built on its own and these follow it.
        def counts(reading) = { "fleet" => reading.fleet_size, "inbox" => reading.inbox_count }

        def cache_line(reading)
          Lain::Renderable.new.with(:label, "status:").plain("\n")
                          .with(:label, "  cache ").with(*warmth(reading))
        end

        def metric(rendered, name, value)
          rendered.plain("\n").with(:label, "  #{name} ").plain(value.to_s)
        end

        # `[token, words]` -- exactly the pair {Renderable#with} takes, so the
        # token and the words that show one answer are chosen together.
        #
        # THREE answers, not two: a feed that has published no deadline at all
        # is not a cache that went cold, and only this surface has the room to
        # say which it is in words.
        def warmth(reading)
          glyphs = Lain::StatusFeed::Reading
          case reading.warmth(now: @clock.call)
          when :warm then [:warm, "#{glyphs::WARM} warm"]
          when :cold then [:cold, "#{glyphs::COLD} cold"]
          else [:cold, "#{glyphs::COLD} cold (no cache activity yet)"]
          end
        end
      end
    end
  end
end
