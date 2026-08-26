# frozen_string_literal: true

module Lain
  module CLI
    class Resume
      # What a session-loading door says when the head it was handed is an
      # assistant `tool_use` still awaiting results AND the repair cannot answer
      # it. Its own unit because {Resume} is about resolving a selector into a
      # {Resume::Result}, not about how a refusal reads.
      #
      # THE BACKSTOP, and a SENTENCE rather than a gate. A torn head no longer
      # refuses at all: {Resume#settled} projects a {Cancellation} and the
      # session resumes. What still reaches here is the one shape that
      # projection cannot answer -- a stranded `tool_use` naming no id. It comes
      # from {Resume#cancellation}'s rescue arm, which already KNOWS both facts,
      # so nothing is re-asked: re-deriving either would put a second copy of a
      # predicate beside the one that just answered, free to disagree with it.
      #
      # `/fork` does not come through here. It used to run this gate
      # parent-side against a LIVE timeline, which stopped being the same
      # question once these doors began to repair: on disk an unanswered
      # tool_use is stranded, live it may be in flight.
      # {CLI::Command::Fork#anchor!} keeps its own gate over the same
      # {Event.pending_tool_use?}, narrowed by `env.replies.pending?` -- a
      # reader a loading door has no use for, because nothing of its own is
      # running -- and builds its sentence with the same {Resume::Door}.
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

          # The remedy has to be one the human can reach FROM HERE, which rules
          # out the obvious `/rewind`: {CLI::Command::Rewind#call} reads
          # `env.timeline` and `env.agent` -- a live REPL -- while this fires
          # during a load, before one exists. `--fork` is reachable because
          # {Resume#fork} checks out BEFORE it refuses.
          def remedy(file)
            "Fork an earlier, settled turn instead: lain chat --fork #{file}@<digest-prefix>, taking " \
              "the digest from a turn record below the tear in that file"
          end
        end
      end
    end
  end
end
