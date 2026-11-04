# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/held`: the lines typed while nothing read them, waiting for `you>`;
      # `/held clear` drops them. A held line is otherwise invisible until its
      # turn comes, which reads as swallowed.
      class Held
        CLEAR = "clear"

        # The chat with no rail to ask: nothing is ever held.
        module NoRail
          def self.held_lines = []
          def self.clear_held = []
        end

        # @param rail [#held_lines, #clear_held, nil] the chat's {Frontend::Intake}; nil until a chat has built one
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
          lines = @rail.held_lines
          return "nothing held" if lines.empty?

          ["held for you>:", *lines.each_with_index.map { |line, index| "  #{index + 1}. #{line}" }].join("\n")
        end

        def cleared
          dropped = @rail.clear_held.size
          "dropped #{dropped} held #{dropped == 1 ? "line" : "lines"}"
        end
      end
    end
  end
end
