# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # Whether a chat's LIVE head may still be answered by a call already
      # running -- the one question `/rewind`, `/undo`, `/fork` and `/btw` all
      # ask before they move or open anything, off the SAME agent's dispatch
      # lock, so the four commands cannot come to disagree about what "in
      # flight" means.
      #
      # `/rewind` and `/undo` ask the narrower {.dispatching?}: any live
      # dispatch is reason enough to refuse a move a settling turn could land
      # over. `/fork` and `/btw` ask the wider {.mid_tool?}, because their
      # hedge names a SPECIFIC shape -- the live head IS the parked call --
      # and a plain reply still streaming, with no `tool_use` yet on the head,
      # is not that shape.
      class InFlight
        # A run holds the dispatch lock right now, so its own commit -- or a
        # tool call it dispatched -- may still land after a caller acts.
        def self.dispatching?(env) = env.agent.dispatching?

        # The live head is itself the parked call.
        def self.mid_tool?(env) = dispatching?(env) && Event.pending_tool_use?(env.timeline.head)
      end
    end
  end
end
