# frozen_string_literal: true

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
    class Reminder < Combinator
      include TailInjection

      # Reminder is constructed WITH the Workspace because it renders workspace
      # *content* into the tail (`@workspace.to_blocks`) -- it needs the object.
      # Recall, by contrast, takes only a memory index: it consults (via
      # MessageEnvelope#workspace_tagged?) the `Workspace::WORKSPACE_MARKER`
      # structural key purely to *exclude* already-injected workspace blocks
      # from its query, so it never needs the instance. The asymmetry the
      # review asked about is real -- one produces workspace content, the
      # other only has to recognize it.
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
