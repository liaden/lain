# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/inbox` (T13): reuses {HumanReplies}'s OWN drain object at `you>` --
      # `#drain_at_prompt`, the same TTY drain UX and the same @ask_human
      # resolution `/inbox` at `human>` already uses (`read_drained_answer`).
      # Never a second listing, never a second reply path.
      class Inbox
        def initialize = freeze

        def name = "inbox"

        def usage = "/inbox -- list and answer pending human questions (same drain as human>)"

        # THIS command reads the human's answer itself, so no second reply
        # surface may be opened around the line that invokes it
        # ({Repl::LineScope#serve} is what asks, through
        # {Registry#serves_replies?}). It is the only command in the set that
        # says this, and it is the whole reason the message exists: `/inbox` is
        # the manual watcher for the stretches when no reply loop runs, so a
        # loop started around it would race the drain for one stdin and the
        # answer would land on whichever fiber won the dequeue -- against
        # `Pending#oldest`, which by then is the loop's own item rather than the
        # one the human just read.
        def serves_replies? = true

        # Nil, always: `#drain_at_prompt` already delivers everything a human
        # needs to see through the SAME TTY calls `human>`'s drain uses (the
        # listing, the empty state, the arrival line) -- returning text here
        # too would render a second, redundant confirmation over the one the
        # drain already printed. `nil` is the Repl's documented "already
        # delivered" outcome (the same one the middleware fallthrough uses),
        # not a missing-response bug.
        def call(_args, env)
          env.replies.drain_at_prompt
          nil
        end
      end
    end
  end
end
