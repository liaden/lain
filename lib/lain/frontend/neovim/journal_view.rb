# frozen_string_literal: true

module Lain
  module Frontend
    class Neovim
      # The journal's presentation -- the third projection, sibling of
      # {Buffers} and {RequestBuffer}, but APPEND-shaped: it turns one Channel
      # event into plain lines for the append-only lain://journal, never a
      # whole-buffer replacement. Deliberately NOT the pastel {Decorators} the
      # TTY uses, because a buffer wants text, not ANSI escapes. (The bytes
      # themselves may still carry a tool's own raw ANSI; stripping or
      # highlighting them is the rendering follow-up card's concern.) Only
      # {Telemetry::ToolOutput} renders today, matching the TTY's one-member
      # set; other events stay Journal-only.
      class JournalView
        NAME = "lain://journal"

        # An idle journal that shows nothing reads as "broken" -- the same
        # principle {Surfaces#prime}'s own docstring states for every sibling
        # view (`(no reminders)`, `(no questions pending)`, `(no approvals
        # pending)`, `(no requests yet)` -- buffers.rb:260-269). This was the
        # one view with no placeholder.
        #
        # `40_journal.lua`'s append entry point (`_G.__lain.render`) decides
        # replace-vs-append off a STRUCTURAL flag (`b:lain_journal_rendered`),
        # not off the buffer's literal text, precisely so this placeholder
        # (unlike the old bare `[""]`) does not get stuck as a permanent
        # header once real output starts appending below it.
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
