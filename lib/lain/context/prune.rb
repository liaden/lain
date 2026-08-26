# frozen_string_literal: true

module Lain
  class Context
    # Drop turns before they ever reach the Provider: either the last N
    # messages, or whichever match a predicate. The client-side arm of the
    # trimming-vs-server-context-editing comparison -- the combinator interface
    # must not assume client-side, which is why this is one strategy among
    # several rather than baked into Context#render.
    #
    # `#requires` is the inherited {Combinator} default: pure client-side
    # trimming needs nothing from the Provider.
    class Prune < Combinator
      include Declarative

      # EXACTLY ONE way to trim: a `keep_last:` count or a predicate block,
      # never both and never neither. The cross-field rule is a `validate` on
      # :base because no single attribute is at fault.
      #
      # `predicate` arrives as a Proc built from a BLOCK, so the check is
      # {Lain::Declarative::ClassMethods#check!} and can never be `settle!` --
      # a Proc has no frozen copy.
      declare do
        attribute :keep_last
        attribute :predicate
        validate do
          errors.add(:base, "provide keep_last: or a predicate block, not both") if keep_last && predicate
          errors.add(:base, "provide keep_last: or a predicate block") if keep_last.nil? && predicate.nil?
        end
      end

      # @param keep_last [Integer, nil] keep only the trailing N messages
      # @param predicate [#call, nil] keep messages it returns true for, via a
      #   block; (Hash) -> Boolean
      # @param protected_patterns [ProtectedPatterns] spans that survive
      #   regardless of keep_last:/predicate -- defaults to {ProtectedPatterns::NONE},
      #   the no-op policy, so an unconfigured Prune behaves exactly as it
      #   did before this parameter existed.
      def initialize(keep_last: nil, protected_patterns: ProtectedPatterns::NONE, &predicate)
        self.class.check!(keep_last:, predicate:)

        super()
        @keep_last = keep_last
        @predicate = predicate
        @protected_patterns = protected_patterns
        freeze
      end

      def call(messages)
        base = base_indices(messages)
        return messages.values_at(*base) if @protected_patterns.none?

        messages.values_at(*(base | protected_indices(messages)).sort)
      end

      private

      # Survivorship is tracked by POSITION, not by `Array#include?` on the
      # Hash values: two messages that happen to be value-equal (a repeated tool
      # result, a duplicated turn) are NOT the same survivor, and
      # `survivors.include?(message)` would resurrect an older, non-surviving
      # twin whenever `protected_patterns:` is configured at all -- silently
      # breaking `keep_last:`'s count guarantee even when no pattern matches.
      def base_indices(messages)
        return keep_last_indices(messages) if @keep_last

        messages.each_index.select { |index| @predicate.call(messages[index]) }
      end

      def keep_last_indices(messages)
        start = [messages.size - @keep_last, 0].max
        (start...messages.size).to_a
      end

      def protected_indices(messages)
        messages.each_index.select { |index| @protected_patterns.protects?(Canonical.dump(messages[index])) }
      end
    end
  end
end
