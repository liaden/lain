# frozen_string_literal: true

module Lain
  module CLI
    module Command
      # `/inbox` reuses {HumanReplies}'s OWN drain object at `you>` --
      # `#drain_at_prompt`, the same TTY drain UX and the same ask_human
      # resolution `/inbox` at `human>` already uses (`read_drained_answer`).
      # Never a second listing, never a second reply path.
      class Inbox
        def initialize = freeze

        def name = "inbox"

        def usage = "/inbox -- list and answer pending human questions (same drain as human>)"

        # THIS command reads the human's answer itself, which is how a reply
        # prompt recognises it as the drain it detours into
        # ({Registry#serves_replies?}).
        def serves_replies? = true

        # Nil, always: `#drain_at_prompt` already delivers everything a human
        # needs to see through the SAME TTY calls `human>`'s drain uses, so text
        # here would render a second, redundant confirmation over the one the
        # drain already printed. `nil` is the Repl's documented "already
        # delivered" outcome, not a missing-response bug.
        def call(_args, env)
          env.replies.drain_at_prompt
          nil
        end
      end
    end
  end
end
