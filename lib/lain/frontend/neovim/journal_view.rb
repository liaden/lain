# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # The journal's presentation -- sibling of {Buffers} and {RequestBuffer},
      # but APPEND-shaped: one Channel event into plain lines for the
      # append-only lain://journal, never a whole-buffer replacement.
      # Deliberately NOT the pastel {Decorators} the TTY uses, because a buffer
      # wants text, not ANSI escapes. The bytes themselves may still carry a
      # tool's own raw ANSI.
      class JournalView
        NAME = "lain://journal"

        # An idle journal that shows nothing reads as "broken", the principle
        # every sibling view's placeholder follows.
        #
        # `40_journal.lua`'s append entry point decides replace-vs-append off a
        # STRUCTURAL flag (`b:lain_journal_rendered`), not off the buffer's
        # literal text, precisely so this placeholder does not get stuck as a
        # permanent header once real output starts appending below it.
        # @return [Hash{String=>Array<String>}]
        def initial
          { NAME => ["(no streamed tool output yet)"] }
        end

        # @param event [Object] one Channel event
        # @return [Array<String>] lines to append -- empty for events the
        #   journal buffer does not present
        def lines(event)
          case event
          when Telemetry::ToolOutput
            attribute_lines(event)
          else
            []
          end
        end

        private

        # `chomp` strips only the trailing-newline artifact of line-oriented
        # output; interior blank lines are real lines and survive (a blank
        # renders as the bare attribution prefix).
        def attribute_lines(event)
          prefix = "[#{event.tool_use_id} #{event.stream}]"
          event.bytes.chomp.split("\n", -1).map { |line| line.empty? ? prefix : "#{prefix} #{line}" }
        end
      end
    end
  end
end
