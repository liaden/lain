# frozen_string_literal: true

module Lain
  module CLI
    class Resume
      # The load-side repair of a torn head: {Tool::Cancellation} over the
      # loaded head, in the one sentence a load can honestly say. At load there
      # is no way to know whether a stranded tool ran, so every call is answered
      # as `:unknown` -- the same words an in-process {Agent#ask} uses when it
      # meets a stranded head, and for the same reason.
      #
      # It is a PROJECTION, never a record: {Resume#settled} commits it onto the
      # rebuilt in-memory Timeline and the journal that witnessed the tear is
      # left exactly as it was. Nothing here claims the tool produced output,
      # which is what separates it from the fabrication the backstop was right
      # to refuse ({Resume::MidTool}).
      class Cancellation < Tool::Cancellation
        # @param head [Lain::Event] an assistant turn {Event.pending_tool_use?}
        #   answers true for
        # @raise [Tool::Cancellation::Unpairable] when a stranded call names no
        #   tool_use id
        def initialize(head)
          super(head, kind: :unknown)
        end
      end
    end
  end
end
