# frozen_string_literal: true

require_relative "base"

module Lain
  class Context
    # Drop turns before they ever reach the Provider: either the last N
    # messages, or whichever match a predicate. This is the client-side arm
    # of the Prune/Compact-vs-server-context-editing comparison (open
    # decision #3, remaining-work.md) -- the combinator interface must not
    # assume client-side, which is exactly why this is one strategy among
    # several rather than baked into Context#render.
    class Prune < Base
      # @param keep_last [Integer, nil] keep only the trailing N messages
      # @param predicate [#call(Hash) -> bool, nil] keep messages it returns
      #   true for, via a block
      def initialize(keep_last: nil, &predicate)
        raise ArgumentError, "provide keep_last: or a predicate block, not both" if keep_last && predicate
        raise ArgumentError, "provide keep_last: or a predicate block" if keep_last.nil? && predicate.nil?

        super()
        @keep_last = keep_last
        @predicate = predicate
        freeze
      end

      def call(messages)
        @keep_last ? messages.last(@keep_last) : messages.select(&@predicate)
      end

      # Pure client-side trimming needs nothing from the Provider.
      def requires
        [].freeze
      end
    end
  end
end
