# frozen_string_literal: true

module Lain
  class Context
    # Throwaway {Lain::Guard} carriers for the combinators that take one (see
    # {Lain::Guard} for why validation lives off the frozen value). Reopened by
    # each combinator's file so the carrier sits beside the class it guards.
    module Guards
      # Prune selects EXACTLY ONE way to trim: a `keep_last:` count or a
      # predicate block, never both and never neither. The cross-field rule is
      # a `validate` on :base because no single attribute is at fault.
      class Prune < Guard
        attribute :keep_last
        attribute :predicate
        validate :exactly_one_selector

        private

        def exactly_one_selector
          errors.add(:base, "provide keep_last: or a predicate block, not both") if keep_last && predicate
          errors.add(:base, "provide keep_last: or a predicate block") if keep_last.nil? && predicate.nil?
        end
      end
    end

    # Drop turns before they ever reach the Provider: either the last N
    # messages, or whichever match a predicate. This is the client-side arm
    # of the Prune/Compact-vs-server-context-editing comparison (open
    # decision #3, remaining-work.md) -- the combinator interface must not
    # assume client-side, which is exactly why this is one strategy among
    # several rather than baked into Context#render.
    #
    # `#requires` is inherited from {Combinator}: pure client-side trimming
    # needs nothing from the Provider, which is the base default.
    class Prune < Combinator
      # @param keep_last [Integer, nil] keep only the trailing N messages
      # @param predicate [#call(Hash) -> bool, nil] keep messages it returns
      #   true for, via a block
      def initialize(keep_last: nil, &predicate)
        Guards::Prune.check!(keep_last:, predicate:)

        super()
        @keep_last = keep_last
        @predicate = predicate
        freeze
      end

      def call(messages)
        @keep_last ? messages.last(@keep_last) : messages.select(&@predicate)
      end
    end
  end
end
