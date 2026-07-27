# frozen_string_literal: true

require "active_support"
require "active_support/concern"

module Lain
  module Algebra
    # A monoid whose operation also ignores operand order. Kept separate from
    # {Monoid} for the same reason the shared example groups are: not every
    # monoid here is commutative, and {Middleware} composition is order-sensitive
    # BY DESIGN -- asking it to satisfy this law would be asking it to stop being
    # a middleware stack. {Usage} satisfies both.
    #
    # Declaring one files BOTH claims, because every commutative monoid is a
    # monoid and the registry should say so outright: a walk over it then holds
    # `#+` to identity, associativity AND commutativity without having to know
    # which structures contain which. So `registry.about(Usage)` answers with
    # TWO declarations for one line, and the implicit one carries
    # `implied_by: :commutative_monoid` -- which is what keeps a collision from
    # reporting a `monoid` line the author never wrote.
    #
    # Includes {Monoid} so the class also gains the plain verb -- that is the
    # dependency ordering ActiveSupport::Concern exists for. Like {Monoid},
    # `is_a?` is not the classification; the registry is.
    module CommutativeMonoid
      extend ActiveSupport::Concern

      include Monoid

      class_methods do
        def commutative_monoid(on:, identity:, registry: Algebra.registry)
          registry.declare(subject: self, operation: on, structure: :monoid, identity:,
                           implied_by: :commutative_monoid)
          registry.declare(subject: self, operation: on, structure: :commutative_monoid, identity:)
        end

        def not_a_commutative_monoid(on:, because:, registry: Algebra.registry)
          registry.refute(subject: self, operation: on, structure: :commutative_monoid, reason: because)
        end
      end
    end
  end
end
