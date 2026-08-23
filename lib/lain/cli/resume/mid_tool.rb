# frozen_string_literal: true

module Lain
  module CLI
    class Resume
      # What a session-loading door says when the head it was handed is an
      # assistant `tool_use` still awaiting results AND the repair cannot
      # answer it. Its own unit because it is its own responsibility -- the
      # reason and the remedy are one sentence's worth of judgement, and
      # {Resume} is about resolving a selector into a {Resume::Result}, not
      # about how a refusal reads.
      #
      # THE BACKSTOP, since T3, and a SENTENCE rather than a gate. A torn head
      # no longer refuses at all: {Resume#settled} projects a {Cancellation}
      # onto the rebuilt timeline and the session resumes. What still reaches
      # here is the one shape that projection cannot answer -- a stranded
      # `tool_use` naming no id, which {Tool::ResultBlock}'s gate 4 refuses to
      # build a result for and which no projection makes valid. It is reached
      # from {Resume#cancellation}'s rescue arm, which already KNOWS both facts:
      # the head is torn and it is unanswerable. So nothing is re-asked here.
      # Re-deriving either would put a second copy of a predicate beside the
      # one that just answered, free to disagree with it.
      #
      # `/fork` does not come through here (T5). It used to run this gate
      # parent-side against a LIVE timeline (F1), which stopped being the same
      # question when T3 made these doors repair: on disk an unanswered
      # tool_use is stranded, live it may be in flight.
      # {CLI::Command::Fork#anchor!} keeps a gate of its own over the same
      # {Event.pending_tool_use?}, narrowed by `env.replies.pending?` -- the
      # reader that tells a live door whether anything is actually outstanding,
      # which a loading door has no use for because nothing of its own is
      # running. It builds its sentence with the same {Resume::Door}. One
      # value, one shape, and the reason differs exactly where the fact does.
      module MidTool
        # The reason, and the ONE wording both doors of {Resume} share. Only
        # the verb differs, so a reader meeting this from `--fork` and from
        # `--resume` reads the same sentence about the same fact.
        REASON = "its head is an assistant tool_use turn still awaiting tool results, and that " \
                 "call names no tool_use id -- nothing can pair a cancellation result with it, " \
                 "so the head cannot be repaired"

        class << self
          # @param door [Resume::Door] which door the human came through and
          #   the file they named -- the only two things that vary
          # @return [Resume::Refusal] built, never raised: the caller is a
          #   `rescue` arm, and `raise` there is what makes it structurally
          #   unable to fall through and hand the Agent a nil timeline.
          def refusal(door) = door.refuse("#{REASON}. #{remedy(door.file)}")

          private

          # The remedy has to be one the human can reach FROM HERE, and that is
          # what rules `/rewind` out despite it being the obvious answer:
          # {CLI::Command::Rewind#call} reads `env.timeline` and `env.agent` --
          # a live REPL -- while this fires during a load, before one exists.
          # `--fork` is reachable, because {Resume#fork} checks out BEFORE it
          # refuses, so an earlier, settled digest opens clean today.
          def remedy(file)
            "Fork an earlier, settled turn instead: lain chat --fork #{file}@<digest-prefix>, taking " \
              "the digest from a turn record below the tear in that file"
          end
        end
      end
    end
  end
end
