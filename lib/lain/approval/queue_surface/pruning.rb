# frozen_string_literal: true

module Lain
  module Approval
    class QueueSurface
      # A {QueueSurface}'s seen-set pruner. `@adjudicated` exists so a pending
      # already asked about is never asked twice (see `sweep`'s filter) -- but
      # once a pending SETTLES (this surface decided it, a sibling surface
      # raced it, or the queue's own clock denied it), `sweep`'s `mine?` check
      # already excludes it from every future pass, so its `@adjudicated`
      # entry has no remaining purpose. Left in place across a long watch over
      # many settling pendings, that entry -- and everything the Pending
      # closes over -- accumulates without bound. This is the release: a
      # stateless collaborator, not a method on the surface itself, because
      # "when is a seen-set entry garbage" is its own small question with its
      # own spec (a growing-hash heuristic on a surface's private state would
      # be the wrong test).
      #
      # It lives under {QueueSurface} rather than under {AutoSurface}, where it
      # was first written, because both surfaces keep the same seen-set for the
      # same reason -- and a default reaching sideways into a sibling class was
      # the tell that it belonged to neither of them in particular.
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
