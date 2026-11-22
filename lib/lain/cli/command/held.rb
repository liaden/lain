# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/held`: the lines typed while nothing read them, waiting for `you>`;
      # `/held clear` drops them. A held line is otherwise invisible until its
      # turn comes, which reads as swallowed.
      class Held
        CLEAR = "clear"

        WHERE = { nil => "with no prompt open", offer: "at a review offer" }.freeze
        private_constant :WHERE

        # The chat with no rail to ask: nothing is ever held.
        module NoRail
          def self.held_entries = []
          def self.clear_held = []
        end

        # @param rail [#held_entries, #clear_held, nil] the chat's {Frontend::Intake}; nil until a chat has built one
        def initialize(rail:)
          @rail = rail || NoRail
          freeze
        end

        def name = "held"

        def usage = "/held -- list the lines held for you>, or /held clear to drop them"

        # Held behind a run, `/held clear` would wait in the very list it clears.
        def disposition = :control

        def call(args, _env)
          case args.to_s.strip
          when "" then listing
          when CLEAR then cleared
          else raise Error, "/held takes no argument but #{CLEAR}"
          end
        end

        private

        def listing
          lines = @rail.held_entries
          return "nothing held" if lines.empty?

          ["held for you>:", *lines.each_with_index.map { |line, index| "  #{index + 1}. #{entry(line)}" }].join("\n")
        end

        def entry(line) = "#{line.text} (typed #{where(line.kind)}, #{age(line.age)} ago)"

        def where(kind) = WHERE.fetch(kind) { "at the #{kind} prompt" }

        def age(seconds) = seconds < 60 ? "#{seconds.floor}s" : "#{(seconds / 60).floor}m"

        def cleared
          Frontend::Intake::HeldLines.dropped(@rail.clear_held.size)
        end
      end
    end
  end
end
