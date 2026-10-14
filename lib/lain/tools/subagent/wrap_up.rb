# frozen_string_literal: true

module Lain
  module Tools
    class Subagent < Tool
      # Tells a one-shot child, once, that its iteration ceiling is near. A
      # child stopped by the ceiling hands its parent only the files it read and
      # its last text block, so the warning is the child's one chance to write
      # its findings down.
      #
      # It runs in the turn phase, before the step captures the child's inbox,
      # so the note posted here is folded into the very request it precedes.
      class WrapUp < Middleware::Base
        REMAINING = 5

        # @param mailbox [#post] the child's inbox
        # @param ceiling [Integer] the child's iteration ceiling
        def initialize(mailbox:, ceiling:)
          super()
          @mailbox = mailbox
          @ceiling = ceiling
          @warned = false
        end

        def call(env, &app)
          warn_of(@ceiling - env.fetch(:iteration)) unless @warned
          downstream(env, &app)
        end

        private

        def warn_of(left)
          return if left > REMAINING

          @warned = true
          @mailbox.post(from: "lain", text: note(left))
        end

        def note(left)
          "#{left} of #{@ceiling} iterations remain. A child stopped at its ceiling hands back only the " \
            "files it read and its last text block, so write your findings as text now."
        end
      end
    end
  end
end
