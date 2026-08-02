# frozen_string_literal: true

require "active_support"
require "active_support/concern"

module Lain
  module Algebra
    # A PARTIAL, idempotent, order-decreasing operation and its dual: two ways
    # of naming the same smaller thing, one by what survives and one by what
    # goes. {Toolset} is the instance -- `#only` keeps the named capabilities,
    # `#except` drops them -- and the claim is per-operation like every other
    # here:
    #
    #   include Algebra::Attenuation
    #
    #   def only(*names) = ...
    #   def except(*names) = ...
    #
    #   attenuation on: :only, dual: :except
    #
    # == Why the dual is evidence and not a second declaration
    #
    # The two operations are not independent claims about which the registry
    # could sensibly disagree: `except(x)` IS `only(names - x)`, and that
    # equation is one of the laws. A declaration per operation would let a
    # reader delete one and leave the other standing as a coherent-looking
    # half-claim, which the duality law is precisely the refusal of. So one
    # claim, carrying the name of its dual -- and the dual is held to the same
    # `answers?` check {Registry#refuse_unanswered} applies to the operation,
    # because a typo'd `dual:` that registered quietly would fail somewhere far
    # from the line that caused it.
    #
    # == The structure is a meet-semilattice ACTION, not a lattice
    #
    # Attenuations of one subject order by inclusion and compose downward:
    # `only(a).only(b) == only(b)` whenever `b` is inside `a`. Outside it, the
    # chain RAISES -- the operation is partial, and that partiality is the
    # structure rather than a rough edge on it. Which is why there is no join
    # here and no `:join_semilattice` to refute: a join would let a holder
    # recover a capability it had dropped, and the whole point of an attenuation
    # is that it cannot. Union exists, but only at CONSTRUCTION, below the trust
    # boundary -- {Tools::Subagent} builds a child's union from tools it already
    # holds, before there is a holder to attenuate from.
    #
    # Monotonicity is what makes the absent join checkable rather than merely
    # asserted: no message on an attenuated subject may name a capability the
    # receiver lacked.
    #
    # Like {Monoid} and unlike {Elementwise}, including this module grants the
    # verbs and asserts nothing -- `is_a?(Attenuation)` is not the
    # classification, the registry is.
    module Attenuation
      extend ActiveSupport::Concern

      class_methods do
        def attenuation(on:, dual:, registry: Algebra.registry)
          registry.refuse_sealed(subject: self, operation: on)
          Attenuation.refuse_unanswered_dual(self, on, dual)
          registry.declare(subject: self, operation: on, structure: :attenuation, dual:)
        end

        def not_an_attenuation(on:, because:, registry: Algebra.registry)
          registry.refuse_sealed(subject: self, operation: on)
          registry.refute(subject: self, operation: on, structure: :attenuation, reason: because)
        end
      end

      # The same refusal {Registry#refuse_unanswered} makes about the operation,
      # made here about the dual, and for the same reason: every claim in this
      # vocabulary is refused at load or not at all.
      #
      # `respond_to?(:to_sym)` first, so `dual: "except"` is accepted exactly as
      # {Registry#declare} accepts a String operation, while `dual: nil` and
      # `dual: 42` fail as this vocabulary's own named error rather than as a
      # raw TypeError out of `method_defined?`.
      def self.refuse_unanswered_dual(subject, operation, dual)
        return if dual.respond_to?(:to_sym) && Algebra.answers?(subject, dual.to_sym)

        raise Unanswered, "#{subject} names #{dual.inspect} as the dual of the attenuation ##{operation}, " \
                          "but does not answer it; declare a structure after BOTH methods that carry it"
      end
    end
  end
end
