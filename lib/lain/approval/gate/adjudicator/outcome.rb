# frozen_string_literal: true

module Lain
  module Approval
    class Gate
      class Adjudicator
        # WHAT a verdict does, as two objects rather than a branch at the call
        # site: both answer `#asker`, `#policy`, `#reason`, `#park`, and
        # `#remember`, and {Adjudicator#settle} sends all five without ever
        # asking which one it holds.
        #
        # This class IS the terminal outcome (APPROVE or DENY): it settles the
        # address and parks nothing. {Deferral} is the other half and inverts
        # both. Splitting them this way rather than testing a symbol is what
        # keeps "a deferral never settles" and "a terminal verdict never parks"
        # single statements instead of two conditionals that could disagree.
        class Outcome
          attr_reader :policy, :reason

          def initialize(answer:, policy:, reason:)
            @answer = answer
            @policy = policy
            @reason = reason
          end

          # The gate's asker duck. The answer is already known, so reusing
          # {Policy::StandingAnswer} resolves the promise up front and no fiber
          # parks -- one object that already does this, not a second copy.
          def asker = Policy::StandingAnswer.new(@answer)

          # The null park: a terminal verdict has nothing awaiting sign-off, so
          # the caller never asks whether to enqueue.
          def park(_queue, **) = nil

          # A settled address, remembered so a second adjudication over it is
          # refused ({AlreadyDecided}).
          def remember(terminal, digest, approved) = terminal[digest] = approved
        end

        # Doubt, in every form it arrives in. Journaled under the fold's own
        # `deferred` label and parked with whatever evidence WAS gathered.
        #
        # It parks, and it settles NOTHING: a deferral is an invitation to come
        # back, so re-running the same address later must stay allowed -- which
        # is exactly the case {AlreadyDecided} must not catch.
        class Deferral < Outcome
          def park(queue, **attributes) = queue.park(**attributes)

          def remember(_terminal, _digest, _approved) = nil
        end
      end
    end
  end
end
