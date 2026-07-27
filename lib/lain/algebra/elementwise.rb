# frozen_string_literal: true

require "active_support"
require "active_support/concern"

module Lain
  module Algebra
    # An operation over a span that is the concatenation of an operation over
    # each element -- so the whole-span map is *derived* from the per-element
    # one rather than written twice:
    #
    #   include Algebra::Elementwise
    #
    #   private
    #
    #   def stale_tool_use_ids(messages) = ...
    #   def without_stale(message, stale_ids) = ...
    #
    #   elementwise on: :call, each: :without_stale, given: :stale_tool_use_ids
    #
    # == The declaration goes BELOW the helpers it names
    #
    # Load-bearing, not a style note. `each:` and `given:` are checked when the
    # declaration runs, exactly like {Monoid}'s `on:` -- every claim in this
    # vocabulary is refused at load or not at all, and a typo'd helper that
    # surfaced as a NoMethodError on first call would surface inside
    # {Context#render}, mid-turn. Placing the declaration above the methods it
    # names therefore fails loudly, naming them.
    #
    # == Two shapes, both from real combinators
    #
    # The per-element map is `M -> [M]`, zero or more, NOT `M -> M`.
    # {Context::DedupeToolCalls} drops a whole message when removing a stale
    # tool_use empties its content, so "map" has to be able to answer nothing.
    # Concatenation is what makes that a drop rather than a hole.
    #
    # And elementwise is often relative to a fixed ANALYSIS of the whole span
    # rather than unconditional: DedupeToolCalls must know every stale tool_use
    # id, and {Context::PurgeFailedInputs} every failed one, before either can
    # map a single message -- a tool_use's failure is recorded on its answering
    # tool_result, which may live anywhere in the list. `given:` names that
    # analysis, it runs once per span, and its result is passed to each
    # per-element call. Saying so is the point: an unconditional elementwise
    # claim about either of those two would be false.
    #
    # == This one IS structural, unlike the other four
    #
    # The generated method IS the concatenation, so an includer cannot be
    # non-elementwise through that door: `is_a?(Elementwise)` is the
    # classification, with no separate label to drift from it. That is why
    # {ClassMethods#not_elementwise} refuses rather than files -- the refutation
    # of elementwise-ness is an absence, not a verb. A class that wants the
    # negative RECORDED does not include the module and files it directly:
    #
    #   Algebra.registry.refute(subject: Summarize, operation: :call,
    #                           structure: :elementwise,
    #                           reason: "a summary of a span is not a map over it")
    #
    # == The generated method's shape
    #
    # Exactly one positional argument, no keywords, and a block is swallowed
    # rather than forwarded -- a per-element map has nowhere to send one. It
    # overwrites an INHERITED method silently (that is ordinary subclassing, and
    # {Context::Combinator#call} is inherited by every combinator that will
    # carry this declaration) but refuses to overwrite one the class wrote
    # itself, which would delete a working implementation with no warning.
    module Elementwise
      extend ActiveSupport::Concern

      # Unconditionally elementwise: an element maps knowing only itself.
      Alone = Data.define(:per_element) do
        def helpers = [per_element]

        def map(subject, span) = span.flat_map { |element| subject.send(per_element, element) }
      end

      # Elementwise given a whole-span analysis, computed once and handed to
      # every element. A Null-Object pair with {Alone} rather than a `given ?`
      # branch inside the generated method, so the per-element call's arity is
      # settled once, at declaration, instead of at every element.
      GivenAnalysis = Data.define(:per_element, :analysis) do
        def helpers = [per_element, analysis]

        def map(subject, span)
          found = subject.send(analysis, span)
          span.flat_map { |element| subject.send(per_element, element, found) }
        end
      end

      class_methods do
        def elementwise(on:, each:, given: nil, registry: Algebra.registry)
          mapper = given.nil? ? Alone.new(per_element: each) : GivenAnalysis.new(per_element: each, analysis: given)
          Elementwise.refuse_occupied(self, on)
          Elementwise.refuse_unanswered_helpers(self, on, mapper)
          # `send`, so the per-element map and the analysis may stay private --
          # they are helpers of the whole-span operation, not surface of their own.
          define_method(on) { |span| mapper.map(self, span) }
          registry.declare(subject: self, operation: on, structure: :elementwise, analysis: given)
        end

        def not_elementwise(on:, because:)
          raise Contradiction, "#{self} includes Algebra::Elementwise, so ##{on} is a per-element map by " \
                               "construction and is_a?(Elementwise) already classifies it; refuting it " \
                               "(#{because.inspect}) would contradict that. To record the negative, do not " \
                               "include the module and call Algebra.registry.refute directly"
        end
      end

      def self.refuse_occupied(subject, operation)
        own = subject.instance_methods(false) + subject.private_instance_methods(false)
        return unless own.include?(operation.to_sym)

        raise Occupied, "#{subject} already defines ##{operation} itself, and generating over it would " \
                        "delete that implementation silently; remove the method, or declare a different " \
                        "operation (overriding an INHERITED method is fine and stays silent)"
      end

      def self.refuse_unanswered_helpers(subject, operation, mapper)
        missing = mapper.helpers.reject { |helper| Algebra.answers?(subject, helper) }
        return if missing.empty?

        raise Unanswered, "#{subject} declares ##{operation} elementwise over " \
                          "#{missing.map { |helper| "##{helper}" }.join(", ")}, which it does not answer; " \
                          "the declaration goes BELOW the helpers it names"
      end
    end
  end
end
