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

        # The at-rest projection (see {Neovim#prime_views}): the journal exists
        # from attach in the SAME one-empty-line state a fresh buffer holds, so
        # runtime.lua's first-append-replaces check still sees a fresh buffer
        # and the journal never leads with a blank.
        # @return [Hash{String=>Array<String>}]
        def initial
          { NAME => [""] }
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
