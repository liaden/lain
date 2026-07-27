# frozen_string_literal: true

require "active_support"
require "active_support/concern"

module Lain
  module Algebra
    # An operation that is a function of its arguments alone -- it consults no
    # mutable collaborator, reads no clock, and touches no I/O, so running it
    # twice on the same input gives the same answer forever.
    #
    # That is worth naming rather than assuming: `Context#render` is pure
    # because purity and prompt-cache stability are the same constraint, and a
    # compaction Strategy's purity decides whether a journalled edge alone is
    # enough to re-derive its output or whether the output has to be stored.
    #
    # == One notion, asked per operation
    #
    # `pure on: :call` classifies an OPERATION, so {#pure?} answers about an
    # operation too. A class may hold a pure `#call` and an impure `#reload`,
    # and an object-level predicate could only ever give one answer for both --
    # which would make the claim and the check two separate notions free to
    # disagree. Asking the registry is also what keeps the declaration
    # load-bearing in `lib/` rather than decoration a spec alone reads.
    #
    # Like {Monoid}, `is_a?(Pure)` is not the classification -- it says only
    # that the verbs were granted.
    #
    # == The mechanical proxy, and what an includer must do to pass it
    #
    # `Ractor.shareable?` is what CLAUDE.md already calls "the mechanical
    # statement of 'no reachable mutable state'", and that is exactly the
    # premise re-derivation needs: nothing reachable can differ between two
    # calls. A frozen collaborator graph therefore passes -- deep immutability
    # is the property, not an empty ivar list.
    #
    # **An includer must freeze itself to answer true.** The base
    # {Context::Combinator} does not freeze and its subclasses do, so a
    # downstream Strategy binding to this has to freeze in its constructor the
    # way every combinator already does. It is a proxy and not a proof --
    # nothing stops a method body from reading a global -- but it catches the
    # failure that actually happens, which is a mutable collaborator quietly
    # injected into a class that claimed to have none.
    module Pure
      extend ActiveSupport::Concern

      class_methods do
        def pure(on:, registry: Algebra.registry)
          registry.declare(subject: self, operation: on, structure: :pure)
        end

        def not_pure(on:, because:, registry: Algebra.registry)
          registry.refute(subject: self, operation: on, structure: :pure, reason: because)
        end
      end

      def pure?(operation, registry: Algebra.registry)
        registry.declares?(subject: self.class, operation:, structure: :pure) && Ractor.shareable?(self)
      end
    end
  end
end
