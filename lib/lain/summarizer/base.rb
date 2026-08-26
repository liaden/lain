# frozen_string_literal: true

module Lain
  module Summarizer
    # The contract every declared summarizer implements: a predicate saying what
    # it handles, and the compaction itself.
    #
    # A summarizer is PURE and SYNCHRONOUS -- text in, text out. No provider, no
    # model, no IO. That restraint IS the tier's value: it compacts a tool result
    # for no tokens and no latency, which is the whole reason to try it before
    # asking a model to summarize.
    #
    # Both methods raise {NotImplementedError} NAMING the summarizer, so a
    # declaration that implements neither fails loudly at the first result it is
    # offered rather than silently doing nothing. The name, not `self.class`,
    # does the naming: every declared summarizer is an ANONYMOUS subclass (see
    # {Builder}), so `self.class` would print an object address where the user
    # needs to read which of their declarations is at fault.
    #
    # Frozen on construction ({Freezable}), and frozen AGAIN by {Builder} after
    # construction, because a user's own `initialize` is defined on the declared
    # subclass and sits ahead of this prepend in the MRO; neither freeze is
    # redundant. Both are SHALLOW, so purity is only PARTLY mechanical: an
    # object a user assigned in their own `initialize` can still be mutated in
    # place, and such a summarizer does accumulate across calls.
    class Base
      prepend Freezable

      # The name the user declared, used to name this summarizer in errors.
      attr_reader :name

      def initialize(name)
        @name = -name.to_s
      end

      def suitable?(_result)
        raise NotImplementedError,
              "summarizer #{name.inspect} must implement #suitable?(result) -> Boolean"
      end

      def compact(_result)
        raise NotImplementedError,
              "summarizer #{name.inspect} must implement #compact(result) -> String"
      end
    end
  end
end
