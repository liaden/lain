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
