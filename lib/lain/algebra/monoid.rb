# frozen_string_literal: true

require "active_support"
require "active_support/concern"

module Lain
  module Algebra
    # An associative operation with a two-sided identity. {Middleware} composes
    # under `#call`, {Context::Combinator} under `#>>`, {Usage} under `#+`; the
    # "a monoid" shared example group already property-tests exactly those two
    # laws, and this is how an operation says it expects to be held to them.
    #
    # Including the module grants the verbs and nothing else -- `is_a?(Monoid)`
    # says only that they were granted, never that a claim was made. The
    # registry is the classification. The claim itself is per-operation:
    #
    #   include Algebra::Monoid
    #   monoid on: :>>, identity: Algebra.later { Context::Identity }
    #
    # {Context::Identity} is an INSTANCE built after the Combinator class body
    # closes (`context/base.rb:64`), so it cannot be named where the declaration
    # is written -- hence {Algebra.later}, which is the only spelling of
    # laziness this vocabulary accepts. A unit that needs no deferral is passed
    # directly: `identity: Usage::ZERO`.
    #
    # A refutation is the same shape with a mandatory reason, so a negative
    # stays visible rather than living in a comment that rots.
    module Monoid
      extend ActiveSupport::Concern

      class_methods do
        def monoid(on:, identity:, registry: Algebra.registry)
          registry.refuse_sealed(subject: self, operation: on)
          registry.declare(subject: self, operation: on, structure: :monoid, identity:)
        end

        def not_a_monoid(on:, because:, registry: Algebra.registry)
          registry.refuse_sealed(subject: self, operation: on)
          registry.refute(subject: self, operation: on, structure: :monoid, reason: because)
        end
      end
    end
  end
end
