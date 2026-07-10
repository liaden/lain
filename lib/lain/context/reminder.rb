# frozen_string_literal: true

require_relative "base"

module Lain
  class Context
    # Injects Workspace state (todos, a file-staleness ledger, a remaining-
    # budget countdown) at the tail of the last user message.
    #
    # This is the relocated body of what used to be Context#inject_workspace
    # -- moved here rather than duplicated. Workspace is SENT, never STORED
    # (see Lain::Workspace): the reminder rides the UNCACHED SUFFIX, since
    # the tail of the final message is exactly where the last cache
    # breakpoint goes. Injecting into `system` instead would rewrite the
    # cached prefix on every turn; appending to the Timeline would accrete a
    # stale copy per turn.
    class Reminder < Base
      def initialize(workspace:)
        super()
        @workspace = workspace
        freeze
      end

      def call(messages)
        return messages if @workspace.empty? || messages.empty?

        last = messages.last
        return messages unless last["role"] == "user"

        rest = messages[0..-2]
        rest + [{ "role" => "user", "content" => last["content"] + @workspace.to_blocks }]
      end

      # Plain text injection -- no Provider capability is needed.
      def requires
        [].freeze
      end
    end
  end
end
