# frozen_string_literal: true

module Lain
  module Compaction
    class Source
      # A completed plan step, PENDING until a compaction commits.
      #
      # {Session#plan_step_completed?} is a level that stays up until the model
      # writes its list again. Read every render, it asked for a compaction on
      # every turn in between -- a stream of cache breaks for one finished step.
      # Consumed on the first render instead, it was thrown away on the render
      # right after the completing `todo_write`, which is the next iteration of
      # the same tool loop, warm, and so a render the scheduler defers.
      #
      # So a step is pending from the write that completes it until a compaction
      # commits, whatever that render's cache: timing defers keep it pending,
      # and the first cold render compacts. A commit consumes every step
      # completed so far, and records that count on its cut
      # ({Telemetry::CompactionCut#plan_step_completions}). The pending question
      # is therefore answered from the session's record alone, which is what
      # lets a resume see a consumed step as consumed.
      #
      # A module and not an object: it holds nothing the Session does not.
      module PlanSteps
        module_function

        # @param session [Session]
        # @return [Boolean] whether a plan step completed that no commit consumed
        def pending?(session) = session.plan_step_completions > consumed(session)

        def consumed(session)
          session.compaction_cuts.inject(0) { |seen, cut| [seen, cut.plan_step_completions].max }
        end
      end
      private_constant :PlanSteps
    end
  end
end
