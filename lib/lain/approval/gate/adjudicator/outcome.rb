# frozen_string_literal: true

module Lain
  module Approval
    class Gate
      class Adjudicator
        # WHAT a verdict does, as two objects rather than a branch at the call
        # site. This class IS the terminal outcome: it settles the address and
        # parks nothing; {Deferral} inverts both. Splitting them rather than
        # testing a symbol keeps "a deferral never settles" and "a terminal
        # verdict never parks" single statements instead of two conditionals
        # that could disagree.
        class Outcome
          attr_reader :policy, :reason

          def initialize(answer:, policy:, reason:)
            @answer = answer
            @policy = policy
            @reason = reason
          end

          # The answer is already known, so {Policy::StandingAnswer} resolves
          # the promise up front and no fiber parks.
          def asker = Policy::StandingAnswer.new(@answer)

          # A terminal verdict has nothing awaiting sign-off, so the caller
          # never asks whether to enqueue.
          def park(_queue, **) = nil

          # Remembered, so a second adjudication over this address is refused.
          def remember(terminal, digest, approved) = terminal[digest] = approved
        end

        # Doubt, in every form it arrives in. It parks and settles NOTHING: a
        # deferral is an invitation to come back, so re-running the same address
        # later must stay allowed -- exactly the case {AlreadyDecided} must not
        # catch.
        class Deferral < Outcome
          def park(queue, **attributes) = queue.park(**attributes)

          def remember(_terminal, _digest, _approved) = nil
        end
      end
    end
  end
end
