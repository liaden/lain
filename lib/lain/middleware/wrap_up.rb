# frozen_string_literal: true

module Lain
  module Middleware
    # Tells an agent, once, that its own iteration ceiling is near. A loop
    # stopped by the ceiling hands back only what it already wrote down, so the
    # warning is its one chance to finish the step and say where it stands.
    #
    # It runs in the turn phase, before the step captures the agent's inbox,
    # so the note posted here is folded into the very request it precedes.
    class WrapUp < Base
      FLOOR = 3
      FRACTION = 0.2

      PARENT_NOTE = lambda do |left:, ceiling:|
        "#{left} of #{ceiling} iterations remain. Finish the step you are on and report where you are, " \
          "so the work can be picked up after the ceiling."
      end

      # @param mailbox [#post] the agent's inbox
      # @param ceiling [#call] `() -> Integer, nil`, read on every turn because an ask can raise it
      # @param note [#call] `(left:, ceiling:) -> String`, the words of the warning
      def initialize(mailbox:, ceiling:, note: PARENT_NOTE)
        super()
        @mailbox = mailbox
        @ceiling = ceiling
        @note = note
        @warned = false
      end

      def call(env, &app)
        iteration = env.fetch(:iteration)
        @warned = false if iteration.zero?
        warn_of(@ceiling.call, iteration) unless @warned
        downstream(env, &app)
      end

      private

      def warn_of(ceiling, iteration)
        return if ceiling.nil?

        left = ceiling - iteration
        return if left > [ceiling * FRACTION, FLOOR].max

        @warned = true
        @mailbox.post(from: "lain", text: @note.call(left:, ceiling:))
      end
    end
  end
end
