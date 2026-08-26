# frozen_string_literal: true

module Lain
  class Context
    # Injects Workspace state (todos, a file-staleness ledger, a remaining-
    # budget countdown) at the tail of the last user message.
    #
    # Workspace is SENT, never STORED (see {Lain::Workspace}): the reminder
    # rides the UNCACHED SUFFIX, since the tail of the final message is exactly
    # where the last cache breakpoint goes. Injecting into `system` instead
    # would rewrite the cached prefix on every turn; appending to the Timeline
    # would accrete a stale copy per turn.
    class Reminder < Combinator
      include TailInjection

      # Constructed WITH the Workspace because it renders workspace *content*
      # into the tail. {Recall} takes only a memory index and still recognizes
      # workspace blocks, through the `Workspace::WORKSPACE_MARKER` structural
      # key -- the asymmetry is real: one produces workspace content, the other
      # only has to recognize it.
      def initialize(workspace:)
        super()
        @workspace = workspace
        freeze
      end

      def call(messages)
        return messages if @workspace.empty? || messages.empty?
        return messages unless MessageEnvelope.wrap(messages.last).user?

        append_to_last(messages, @workspace.to_blocks)
      end
    end
  end
end
