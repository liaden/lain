# frozen_string_literal: true

require "active_support"
require "active_support/concern"

module Lain
  module Algebra
    # An idempotent, commutative, associative binary meet with a bottom element,
    # ordered so that a meet sits below both its operands -- the four laws the
    # "a meet semilattice under ancestry" shared example group asserts.
    #
    # This is the structure whose per-operation shape is load-bearing. Timeline
    # declares it twice and refutes it once:
    #
    #   meet_semilattice on: :meet, bottom: "the empty Timeline, per store"
    #   meet_semilattice on: :dominator_meet, bottom: "the empty Timeline, per store"
    #   not_a_meet_semilattice on: :causal_meets,
    #                          because: "a criss-cross fan-in leaves incomparable ..."
    #
    # `include MeetSemilattice` on that class, with no operation named, would be
    # a lie about `#causal_meets` -- and `is_a?` is not the classification here
    # for exactly that reason. The registry is.
    #
    # == Why the bottom is prose and not a value
    #
    # The bottom is what makes the meet TOTAL: the empty Timeline is the answer
    # for two members that share no history. But there is no one empty Timeline
    # to record. `Timeline.empty` mints a fresh {Store}, so a stored bottom would
    # raise CrossStore against every real operand, and a lazy one would mint a
    # different store on every read. The bottom is relative to a store, which
    # makes it a fact about the structure rather than a value the structure
    # holds. So it is recorded as a short description: the card asks the
    # declaration to name its identity or bottom for a READER, and a String does
    # that while being unusable as data by construction -- nobody can wire it
    # into a law group wrongly. The law group agrees: it takes a `population:`
    # and never asks for a bottom.
    module MeetSemilattice
      extend ActiveSupport::Concern

      class_methods do
        def meet_semilattice(on:, bottom:, registry: Algebra.registry)
          MeetSemilattice.refuse_unnamed_bottom(self, on, bottom)
          registry.declare(subject: self, operation: on, structure: :meet_semilattice, bottom:)
        end

        def not_a_meet_semilattice(on:, because:, registry: Algebra.registry)
          registry.refute(subject: self, operation: on, structure: :meet_semilattice, reason: because)
        end
      end

      # A value passed where prose belongs is the mistake this refuses: it looks
      # like it works, and it is wrong in a way that only surfaces as a
      # CrossStore far from the declaration.
      def self.refuse_unnamed_bottom(subject, operation, bottom)
        return if bottom.is_a?(String) && !bottom.strip.empty?

        raise Unexplained, "#{subject} declares a meet semilattice on ##{operation} without naming its " \
                           "bottom; `bottom:` takes a short description (\"the empty Timeline, per store\"), " \
                           "not a value -- a bottom is relative to a store, so there is no one value to record"
      end
    end
  end
end
