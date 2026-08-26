# frozen_string_literal: true

module Lain
  module Approval
    class QueueSurface
      # A {QueueSurface}'s seen-set pruner. Once a pending SETTLES, `mine?`
      # already excludes it from every future pass, so its `@adjudicated` entry
      # has no remaining purpose -- and left in place across a long watch, that
      # entry and everything the Pending closes over accumulate WITHOUT BOUND.
      #
      # A stateless collaborator rather than a method on the surface, because
      # "when is a seen-set entry garbage" is its own small question with its
      # own spec: a growing-hash heuristic over a surface's private state would
      # be the wrong test.
      class Pruning
        # @param adjudicated [Hash] the identity-keyed seen-set, mutated in
        #   place.
        # @return [Hash] the same object, pruned -- so a caller can chain or
        #   ignore the return at will.
        def call(adjudicated)
          adjudicated.reject! { |pending, _| pending.decided? }
          adjudicated
        end
      end
    end
  end
end
