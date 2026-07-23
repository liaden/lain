# frozen_string_literal: true

module Lain
  module Approval
    class AutoSurface
      # {AutoSurface}'s seen-set pruner. `@adjudicated` exists so a pending
      # already asked about is never asked twice (see `sweep`'s reject
      # filter) -- but once a pending SETTLES (this surface decided it, a
      # sibling surface raced it, or the queue's own clock denied it),
      # `sweep`'s `pending.decided?` check already excludes it from every
      # future pass, so its `@adjudicated` entry has no remaining purpose.
      # Left in place across a long watch over many settling pendings, that
      # entry -- and everything the Pending closes over -- accumulates
      # without bound. This is the release: a stateless collaborator, not a
      # method on AutoSurface itself, because "when is a seen-set entry
      # garbage" is its own small question with its own spec (a growing-hash
      # heuristic on AutoSurface's private state would be the wrong test).
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
